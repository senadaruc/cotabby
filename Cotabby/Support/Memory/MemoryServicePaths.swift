import Foundation

/// File overview:
/// Where the conversation memory service's files live, as pure path arithmetic.
///
/// Everything the service owns sits under `Application Support/<app name>/Memory/`, named per app
/// (like the llama runtime and typing history), so the dev build and the released app never share
/// a venv, an index or a socket:
///
/// ```
/// Memory/
///   venv/          Python virtual environment with LEANN (created by Cotabby with uv)
///   data/          the service's data dir: config.json, messages.sqlite, indexes/, logs/  (0700)
///   data/memory.sock
///   pycache/       Python bytecode, redirected here because writing .pyc files into the signed
///                  app bundle would invalidate its code signature
///   install.log    output of the last install
/// ```
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

    var venv: URL { root.appendingPathComponent("venv", isDirectory: true) }
    var python: URL { venv.appendingPathComponent("bin/python") }
    var dataDirectory: URL { root.appendingPathComponent("data", isDirectory: true) }
    var socket: URL { dataDirectory.appendingPathComponent("memory.sock") }
    var pycache: URL { root.appendingPathComponent("pycache", isDirectory: true) }
    var installLog: URL { root.appendingPathComponent("install.log") }
    /// Written after a successful install with the requirements it installed, so an app update that
    /// pins a newer LEANN reinstalls instead of running against stale packages.
    var installedRequirements: URL { root.appendingPathComponent("installed-requirements.txt") }

    /// Unix socket paths are limited to 104 bytes on macOS; a longer home directory path would make
    /// the service unreachable, so the supervisor checks this before starting.
    var isSocketPathUsable: Bool { socket.path.utf8.count < 100 }

    /// Where `uv` is commonly installed, in the order a user's own install is most likely: the
    /// official installer's location, Homebrew on Apple Silicon and Intel, and Cargo.
    static func uvCandidates(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
            "\(home)/.cargo/bin/uv"
        ]
    }

    /// The bundled service source (`Contents/Resources/cotabby_memory`) and pinned requirements.
    struct BundledService: Equatable, Sendable {
        /// The directory to put on `PYTHONPATH` (the parent of the `cotabby_memory` package).
        let pythonPath: URL
        let requirements: URL
    }

    static func bundledService(bundle: Bundle = .main) -> BundledService? {
        guard let resources = bundle.resourceURL else { return nil }
        let package = resources.appendingPathComponent("cotabby_memory", isDirectory: true)
        let requirements = resources.appendingPathComponent("memory-requirements.txt")
        guard FileManager.default.fileExists(atPath: package.appendingPathComponent("server.py").path),
              FileManager.default.fileExists(atPath: requirements.path) else { return nil }
        return BundledService(pythonPath: resources, requirements: requirements)
    }
}
