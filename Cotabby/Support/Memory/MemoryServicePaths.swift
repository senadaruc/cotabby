import Foundation

/// File overview:
/// Where conversation memory's files live, as pure path arithmetic.
///
/// Everything sits under `Application Support/<app name>/Memory/`, named per app (like the llama
/// runtime and typing history), so the dev build and the released app never share a store:
///
/// ```
/// Memory/
///   data/          config.json and messages.sqlite (the encrypted store, vectors included)  (0700)
///   Models/        the embedding model (kept apart from completion models, so it is never
///                  offered as one)
/// ```
///
/// `obsoleteItems` are what the earlier Python service left behind (its virtual environment, LEANN
/// index folders, socket, logs); the engine controller deletes them once.
struct MemoryServicePaths: Equatable, Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// The paths for the running app, keyed by its bundle name.
    static func standard(bundle: Bundle = .main) -> MemoryServicePaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let appName = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Cotabby"
        return MemoryServicePaths(root: support.appendingPathComponent(appName).appendingPathComponent("Memory"))
    }

    var dataDirectory: URL { root.appendingPathComponent("data", isDirectory: true) }
    var modelsDirectory: URL { root.appendingPathComponent("Models", isDirectory: true) }

    /// Left by the Python memory service, which the native engine replaces.
    var obsoleteItems: [URL] {
        [
            root.appendingPathComponent("venv", isDirectory: true),
            root.appendingPathComponent("pycache", isDirectory: true),
            root.appendingPathComponent("install.log"),
            root.appendingPathComponent("installed-requirements.txt"),
            dataDirectory.appendingPathComponent("indexes", isDirectory: true),
            dataDirectory.appendingPathComponent("staging", isDirectory: true),
            dataDirectory.appendingPathComponent("logs", isDirectory: true),
            dataDirectory.appendingPathComponent("memory.sock"),
            dataDirectory.appendingPathComponent("service.lock"),
        ]
    }
}
