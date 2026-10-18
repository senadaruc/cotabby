import Foundation

/// Stateless client for the HuggingFace public REST API.
/// Each call creates an ephemeral URLSession — matching the existing networking pattern
/// in ModelDownloadManager — so no shared state or cookies persist between requests.
enum HuggingFaceAPIClient {

    enum APIError: LocalizedError {
        case invalidURL
        case httpError(statusCode: Int)
        case rateLimited
        case decodingFailed(Error)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid HuggingFace API URL."
            case .httpError(let statusCode):
                return "HuggingFace returned HTTP \(statusCode)."
            case .rateLimited:
                return "Too many requests — please wait a moment and try again."
            case .decodingFailed(let error):
                return "Failed to parse HuggingFace response: \(error.localizedDescription)"
            }
        }
    }

    /// Search for GGUF model repositories sorted by download count.
    static func searchModels(query: String, limit: Int = 20, offset: Int = 0) async throws -> [HFModelSearchResult] {
        guard var components = URLComponents(string: "https://huggingface.co/api/models") else {
            throw APIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        guard let url = components.url else {
            throw APIError.invalidURL
        }

        let data = try await performRequest(url: url)
        do {
            return try JSONDecoder().decode([HFModelSearchResult].self, from: data)
        } catch {
            throw APIError.decodingFailed(error)
        }
    }

    /// Fetch the file tree for a repository, including exact file sizes from LFS metadata.
    static func fetchRepoFiles(repoId: String) async throws -> [HFRepoFile] {
        guard var components = URLComponents(string: "https://huggingface.co") else {
            throw APIError.invalidURL
        }
        components.path = "/api/models/\(repoId)/tree/main"
        guard let url = components.url else {
            throw APIError.invalidURL
        }

        let data = try await performRequest(url: url)
        do {
            return try JSONDecoder().decode([HFRepoFile].self, from: data)
        } catch {
            throw APIError.decodingFailed(error)
        }
    }

    /// The repo's current commit and every file in it (nested folders too), with the blob names
    /// the cache stores them under. Used by the MLX downloader, which names blobs and the
    /// snapshot folder the way huggingface_hub does.
    static func fetchSnapshot(repoId: String) async throws -> MLXRemoteSnapshot {
        guard var components = URLComponents(string: "https://huggingface.co") else { throw APIError.invalidURL }
        components.path = "/api/models/\(repoId)/revision/main"
        guard let infoURL = components.url else { throw APIError.invalidURL }
        let info = try await performRequest(url: infoURL)
        guard let object = try? JSONSerialization.jsonObject(with: info) as? [String: Any],
              let revision = object["sha"] as? String, !revision.isEmpty
        else { throw APIError.decodingFailed(URLError(.cannotParseResponse)) }

        components.path = "/api/models/\(repoId)/tree/\(revision)"
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        guard let treeURL = components.url else { throw APIError.invalidURL }
        let tree = try await performRequest(url: treeURL)
        do {
            let entries = try JSONDecoder().decode([HFTreeEntry].self, from: tree)
            let files = entries.filter { $0.type == "file" }.map {
                MLXRemoteSnapshot.File(path: $0.path, size: $0.lfs?.size ?? $0.size, blobID: $0.lfs?.oid ?? $0.oid)
            }
            return MLXRemoteSnapshot(revision: revision, files: files)
        } catch {
            throw APIError.decodingFailed(error)
        }
    }

    /// One entry of `GET /api/models/<repoId>/tree/<revision>`: `oid` is the git object id,
    /// `lfs.oid` the sha256 of a large file.
    private struct HFTreeEntry: Decodable {
        struct LFS: Decodable {
            let oid: String
            let size: Int64
        }

        let type: String
        let path: String
        let oid: String
        let size: Int64
        let lfs: LFS?
    }

    /// Whether downloading the repo needs an accepted license and a token. The model-info API
    /// reports `gated` as `false`, `"auto"` or `"manual"`.
    static func isGated(repoId: String) async throws -> Bool {
        guard var components = URLComponents(string: "https://huggingface.co") else {
            throw APIError.invalidURL
        }
        components.path = "/api/models/\(repoId)"
        guard let url = components.url else { throw APIError.invalidURL }
        let data = try await performRequest(url: url)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decodingFailed(URLError(.cannotParseResponse))
        }
        if let gated = object["gated"] as? Bool { return gated }
        return object["gated"] is String
    }

    /// One file of a repo at `main` (`resolve` redirects LFS files to the CDN; URLSession follows).
    /// Used for small files such as `config.json`; a missing file surfaces as `httpError(404)`.
    static func fetchFileData(repoId: String, path: String) async throws -> Data {
        guard var components = URLComponents(string: "https://huggingface.co") else {
            throw APIError.invalidURL
        }
        components.path = "/\(repoId)/resolve/main/\(path)"
        guard let url = components.url else { throw APIError.invalidURL }
        return try await performRequest(url: url)
    }

    private static func performRequest(url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            return data
        }

        if httpResponse.statusCode == 429 {
            throw APIError.rateLimited
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return data
    }
}
