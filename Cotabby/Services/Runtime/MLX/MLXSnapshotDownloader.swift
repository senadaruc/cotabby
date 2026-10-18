import Foundation

/// File overview:
/// Downloads one Hugging Face model snapshot into the shared cache in Swift, laid out exactly as
/// huggingface_hub lays it out, so models downloaded by Cotabby, by Python tools and by earlier
/// Cotabby versions are interchangeable:
///
///     <root>/models--<owner>--<name>/blobs/<blob id>[.incomplete]
///     <root>/models--<owner>--<name>/snapshots/<revision>/<path> -> ../../blobs/<blob id>
///     <root>/models--<owner>--<name>/refs/main = <revision>
///
/// A file downloads into `<blob id>.incomplete` and is renamed when it has its full size, so an
/// interrupted download resumes where it stopped (also one huggingface_hub started). The snapshot
/// links and `refs/main` are written only after every blob is complete: until then the cache
/// scanner sees an unfinished repo and does not list it.

/// One snapshot of a repo as the Hugging Face API describes it.
nonisolated struct MLXRemoteSnapshot: Equatable, Sendable {
    nonisolated struct File: Equatable, Sendable {
        let path: String
        let size: Int64
        /// The blob's cache name: the LFS sha256 for large files, the git object id otherwise
        /// (the ETag huggingface_hub names blobs by).
        let blobID: String
    }

    /// The commit the files belong to; downloads use it so every file comes from one revision.
    let revision: String
    let files: [File]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

nonisolated enum MLXSnapshotDownloadError: LocalizedError, Equatable {
    case http(statusCode: Int)
    case sizeMismatch(path: String, expected: Int64, actual: Int64)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .http(let statusCode): return "Hugging Face returned HTTP \(statusCode)."
        case .sizeMismatch(let path, let expected, let actual):
            return "\(path) arrived with \(actual) of \(expected) bytes. Try again."
        case .unsafePath(let path): return "The repo lists an unusable file path: \(path)"
        }
    }
}

nonisolated enum MLXSnapshotDownloader {
    /// Appends the bytes of `remote` from `offset` on to the file at `local`, creating it when
    /// `offset` is 0. Injected so tests run without a network.
    typealias Transfer = @Sendable (_ remote: URL, _ local: URL, _ offset: Int64) async throws -> Void

    static func fileURL(repo: MLXRepoID, revision: String, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repo.value)/resolve/\(revision)/\(path)"
        return components.url
    }

    /// The link target for `path` inside `snapshots/<revision>/`: one `..` per folder level back
    /// to the repo folder, then `blobs/<blob id>`.
    static func linkDestination(path: String, blobID: String) -> String {
        let depth = path.split(separator: "/").count - 1
        return String(repeating: "../", count: depth + 2) + "blobs/\(blobID)"
    }

    /// Downloads every file of `snapshot` that the cache does not already hold, then links the
    /// snapshot and points `refs/main` at it. Throws `CancellationError` when cancelled; the
    /// partial file stays for the next attempt.
    static func download(
        _ snapshot: MLXRemoteSnapshot,
        repo: MLXRepoID,
        cacheRoot: URL,
        transfer: Transfer,
        fileManager: FileManager = .default
    ) async throws {
        let repoFolder = cacheRoot.appendingPathComponent(repo.cacheFolderName, isDirectory: true)
        let blobs = repoFolder.appendingPathComponent("blobs", isDirectory: true)
        try fileManager.createDirectory(at: blobs, withIntermediateDirectories: true)
        for file in snapshot.files {
            guard isSafe(file.path), isSafe(file.blobID), !file.blobID.contains("/") else {
                throw MLXSnapshotDownloadError.unsafePath(file.path)
            }
        }

        for file in snapshot.files {
            try Task.checkCancellation()
            let blob = blobs.appendingPathComponent(file.blobID)
            if size(of: blob, fileManager) == file.size { continue }
            let partial = blobs.appendingPathComponent(file.blobID + ".incomplete")
            var offset = size(of: partial, fileManager) ?? 0
            if offset > file.size {
                try? fileManager.removeItem(at: partial)
                offset = 0
            }
            if offset < file.size || file.size == 0 {
                guard let remote = fileURL(repo: repo, revision: snapshot.revision, path: file.path) else {
                    throw MLXSnapshotDownloadError.unsafePath(file.path)
                }
                try await transfer(remote, partial, offset)
            }
            let actual = size(of: partial, fileManager) ?? 0
            guard actual == file.size else {
                // A short file resumes next time; a long one is corrupt and starts over.
                if actual > file.size { try? fileManager.removeItem(at: partial) }
                throw MLXSnapshotDownloadError.sizeMismatch(path: file.path, expected: file.size, actual: actual)
            }
            try? fileManager.removeItem(at: blob)
            try fileManager.moveItem(at: partial, to: blob)
        }

        let snapshotFolder = repoFolder.appendingPathComponent("snapshots/\(snapshot.revision)", isDirectory: true)
        for file in snapshot.files {
            let link = snapshotFolder.appendingPathComponent(file.path)
            try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.removeItem(at: link)
            try fileManager.createSymbolicLink(
                atPath: link.path, withDestinationPath: linkDestination(path: file.path, blobID: file.blobID))
        }
        let refs = repoFolder.appendingPathComponent("refs", isDirectory: true)
        try fileManager.createDirectory(at: refs, withIntermediateDirectories: true)
        try Data(snapshot.revision.utf8).write(to: refs.appendingPathComponent("main"), options: .atomic)
    }

    /// A relative path that stays inside its folder: no absolute paths, no `..` or empty parts.
    private static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == ".." || $0 == "." }
    }

    private static func size(of url: URL, _ fileManager: FileManager) -> Int64? {
        ((try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value
    }
}

/// The live `MLXSnapshotDownloader.Transfer`: one HTTP request per file, streamed to disk as it
/// arrives so the progress poller sees the partial file grow, resumed with a `Range` header.
nonisolated final class MLXHTTPFileTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let local: URL
    private let offset: Int64
    private let lock = NSLock()
    private var handle: FileHandle?
    private var failure: Error?
    /// Set when the server answers 416: the partial file already holds every byte.
    private var alreadyComplete = false
    private var continuation: CheckedContinuation<Void, Error>?

    private init(local: URL, offset: Int64) {
        self.local = local
        self.offset = offset
    }

    static func transfer(remote: URL, local: URL, offset: Int64) async throws {
        let delegate = MLXHTTPFileTransfer(local: local, offset: offset)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: remote)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.lock.withLock { delegate.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        do {
            switch status {
            case 206 where offset > 0:
                handle = try openHandle(truncatingTo: offset)
            case 200:
                // The server sent the whole file (no range support): start the file over.
                handle = try openHandle(truncatingTo: 0)
            case 416:
                // Nothing past the offset: the partial file is already complete.
                lock.withLock { alreadyComplete = true }
                completionHandler(.cancel)
                return
            default:
                throw MLXSnapshotDownloadError.http(statusCode: status)
            }
            completionHandler(.allow)
        } catch {
            lock.withLock { failure = error }
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            lock.withLock { failure = error }
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let (continuation, failure, complete) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Error?, Bool) in
            defer { self.continuation = nil }
            return (self.continuation, self.failure, self.alreadyComplete)
        }
        if let failure {
            continuation?.resume(throwing: failure)
        } else if complete {
            continuation?.resume()
        } else if let error = error as? URLError, error.code == .cancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    private func openHandle(truncatingTo length: Int64) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: local.path) {
            FileManager.default.createFile(atPath: local.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: local)
        try handle.truncate(atOffset: UInt64(length))
        try handle.seekToEnd()
        return handle
    }
}
