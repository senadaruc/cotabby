import Foundation

/// File overview:
/// Hands the new Teams client's local message cache to the memory service.
///
/// Why staging instead of a reader like WhatsApp's: Teams is a web app and keeps the chats it has
/// shown in Chromium IndexedDB (LevelDB files holding V8-serialized objects), a format only the
/// service parses (`connectors/teams.py`). The cache sits in Teams' sandbox container, which macOS
/// protects and the service, running without Cotabby's permissions, cannot open. So Cotabby copies
/// the IndexedDB folders into a new folder inside the service's private `staging/` directory
/// (0700, inside the 0700 data folder), the service reads the copy with `records.import_staged`,
/// and the copy is deleted by the service as soon as it is read and again by `MemoryHistorySync`
/// when the job ends; the service also clears `staging/` at every start, in case Cotabby quit
/// mid-import.
///
/// Only the Teams origin's IndexedDB is copied (its `.leveldb` and `.blob` folders, per account
/// profile `WV2Profile_*`), never cookies, local storage or tokens.
nonisolated protocol MemoryCacheStaging: Sendable {
    /// The service's source id (`teams`).
    var sourceID: String { get }
    func readiness() -> MemorySourceReadiness
    /// Something that changes whenever the cache does, so an unchanged cache is not copied again.
    func signature() -> String?
    /// Copies the cache into a new folder directly inside `stagingRoot` and returns that folder.
    func stage(into stagingRoot: URL) throws -> URL
}

nonisolated struct TeamsCacheStager: MemoryCacheStaging {
    let sourceID = "teams"
    let webViewRoot: String

    static let originFolder = "https_teams.microsoft.com_0.indexeddb"

    init(webViewRoot: String = NSHomeDirectory()
        + "/Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/EBWebView") {
        self.webViewRoot = webViewRoot
    }

    /// One IndexedDB folder per signed-in Teams profile (work and personal accounts are separate).
    func profileFolders() throws -> [(profile: String, leveldb: String, blob: String)] {
        let profiles = try FileManager.default.contentsOfDirectory(atPath: webViewRoot)
            .filter { $0.hasPrefix("WV2Profile_") }
            .sorted()
        return profiles.compactMap { profile in
            let base = "\(webViewRoot)/\(profile)/IndexedDB/\(Self.originFolder)"
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: base + ".leveldb", isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return (profile, base + ".leveldb", base + ".blob")
        }
    }

    func readiness() -> MemorySourceReadiness {
        guard FileManager.default.fileExists(atPath: webViewRoot) else {
            return .notFound("No Teams cache on this Mac. Open the new Teams app once.")
        }
        let folders: [(profile: String, leveldb: String, blob: String)]
        do {
            folders = try profileFolders()
        } catch {
            return Self.isPermissionError(error) ? .needsFullDiskAccess : .failed(error.localizedDescription)
        }
        guard let first = folders.first else {
            return .notFound("Teams has not cached any chats yet.")
        }
        // Listing can be allowed while reading is not; open one file to be sure.
        let descriptor = open(first.leveldb + "/CURRENT", O_RDONLY)
        if descriptor >= 0 {
            close(descriptor)
            return .ready
        }
        return errno == EPERM || errno == EACCES ? .needsFullDiskAccess : .failed("Cannot read the Teams cache.")
    }

    /// The newest modification time and total size of the cache files: LevelDB writes a new log or
    /// table file for every change, so either moves when anything was cached.
    func signature() -> String? {
        guard let folders = try? profileFolders(), !folders.isEmpty else { return nil }
        var newest: TimeInterval = 0
        var total: Int64 = 0
        for folder in folders {
            for path in [folder.leveldb, folder.blob] {
                guard let enumerator = FileManager.default.enumerator(
                    at: URL(fileURLWithPath: path),
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
                ) else { continue }
                for case let url as URL in enumerator {
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    newest = max(newest, values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
                    total += Int64(values?.fileSize ?? 0)
                }
            }
        }
        return "\(Int(newest))-\(total)"
    }

    func stage(into stagingRoot: URL) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: stagingRoot, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let target = stagingRoot.appendingPathComponent("teams-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: target, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        do {
            for folder in try profileFolders() {
                let profileTarget = target.appendingPathComponent(folder.profile, isDirectory: true)
                try manager.createDirectory(at: profileTarget, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
                try manager.copyItem(atPath: folder.leveldb,
                                     toPath: profileTarget.appendingPathComponent(Self.originFolder + ".leveldb").path)
                if manager.fileExists(atPath: folder.blob) {
                    try manager.copyItem(atPath: folder.blob,
                                         toPath: profileTarget.appendingPathComponent(Self.originFolder + ".blob").path)
                }
            }
        } catch {
            // A partial copy is still a plaintext copy; never leave it behind.
            try? manager.removeItem(at: target)
            throw error
        }
        return target
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError { return true }
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        return underlying?.domain == NSPOSIXErrorDomain
            && (underlying?.code == Int(EPERM) || underlying?.code == Int(EACCES))
    }
}
