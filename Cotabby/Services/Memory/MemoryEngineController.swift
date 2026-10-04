import AppKit
import Combine
import CoreGraphics
import CryptoKit
import Foundation

/// File overview:
/// Owns conversation memory's lifecycle: on or off, the embedding model download, the encryption
/// key, and the `MemoryEngine` while memory is on.
///
/// Why separate from the engine: the engine does the work off the main actor; this is the
/// main-actor face the Memory pane, the field icon and the suggestion pipeline observe (`state`,
/// `status`) and drive (`setEnabled`, `downloadModel`). It replaces the supervisor of the earlier
/// Python service and, on its first start, removes what that service left on disk. Built once by
/// `CotabbyAppEnvironment`; started by `AppDelegate`.
@MainActor
final class MemoryEngineController: ObservableObject {
    enum State: Equatable {
        case disabled
        /// The embedding model is not on this Mac yet.
        case needsModel
        case starting
        case running
        case failed(String)
        /// The store was encrypted with a key this Mac's Keychain no longer has.
        case keyMismatch
    }

    @Published private(set) var state: State = .disabled
    @Published private(set) var isEnabled: Bool
    @Published private(set) var status = MemoryEngineStatus()
    /// The running engine; nil while memory is off or starting.
    @Published private(set) var engine: MemoryEngine?

    let paths: MemoryServicePaths
    let downloads: ModelDownloadManager
    private let userDefaults: UserDefaults
    private let keyStore: any TypingHistoryKeyStore
    private let isOnACPower: @MainActor () -> Bool
    private let isGenerating: @MainActor () -> Bool
    private var cancellables: Set<AnyCancellable> = []

    static let enabledDefaultsKey = "cotabbyMemoryServiceEnabled"

    /// Qwen3-Embedding-0.6B, quantized to 8 bits by Qwen (multilingual, 1024 dimensions). Pinned by
    /// size and SHA-256, which `ModelDownloadManager` verifies before installing the file.
    static let embeddingModel = DownloadableRuntimeModel(
        filename: "Qwen3-Embedding-0.6B-Q8_0.gguf",
        displayName: "Qwen3 Embedding 0.6B",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/main/Qwen3-Embedding-0.6B-Q8_0.gguf")!,
        approximateSizeInGigabytes: 0.64,
        expectedSizeBytes: 639_150_592,
        sha256: "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439"
    )

    init(
        paths: MemoryServicePaths = .standard(),
        userDefaults: UserDefaults = .standard,
        keyStore: (any TypingHistoryKeyStore)? = nil,
        isOnACPower: @escaping @MainActor () -> Bool,
        isGenerating: @escaping @MainActor () -> Bool = { false }
    ) {
        self.paths = paths
        self.userDefaults = userDefaults
        // The store's encryption key: its own Keychain item, per app identity, so the dev build and
        // the released app never share (or overwrite) each other's key.
        self.keyStore = keyStore ?? KeychainTypingHistoryKeyStore(
            service: "\(Bundle.main.bundleIdentifier ?? "com.jacobfu.tabby").memory",
            label: "Cotabby conversation memory key"
        )
        self.isOnACPower = isOnACPower
        self.isGenerating = isGenerating
        downloads = ModelDownloadManager(runtimeDirectoryURL: paths.modelsDirectory)
        isEnabled = userDefaults.bool(forKey: Self.enabledDefaultsKey)
        // Start as soon as the model download finishes, if memory is on and waiting for it.
        downloads.$modelStates
            .map { $0[Self.embeddingModel.id] }
            .removeDuplicates()
            .sink { [weak self] modelState in
                guard let self, modelState == .downloaded, self.isEnabled, self.state == .needsModel else { return }
                self.start()
            }
            .store(in: &cancellables)
    }

    var modelURL: URL { paths.modelsDirectory.appendingPathComponent(Self.embeddingModel.filename) }

    var isModelInstalled: Bool { downloads.isModelInstalled(Self.embeddingModel) }

    // MARK: - Controls

    /// Called once at launch: brings memory up if the user left it on.
    func startIfEnabled() {
        removeObsoleteFiles()
        if isEnabled { start() } else { state = .disabled }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        userDefaults.set(enabled, forKey: Self.enabledDefaultsKey)
        if enabled { start() } else { stop() }
    }

    func downloadModel() {
        downloads.download(Self.embeddingModel)
    }

    func restart() {
        stop()
        if isEnabled { start() }
    }

    /// Stops the engine (its model and indexing). `restart` and `deleteMemoryData` start it again.
    func stop() {
        let engine = engine
        self.engine = nil
        status = MemoryEngineStatus()
        state = .disabled
        Task.detached(priority: .utility) { engine?.stop() }
    }

    /// Deletes the stored messages (after a key mismatch, or on request) and starts again. Settings stay.
    func deleteMemoryData() {
        stop()
        let store = MemoryEngine.Paths(dataDirectory: paths.dataDirectory).store
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: store.path + suffix)
        }
        if isEnabled { start() }
    }

    // MARK: - Starting

    private func start() {
        guard isEnabled else { return }
        guard isModelInstalled else {
            state = .needsModel
            return
        }
        state = .starting
        let paths = MemoryEngine.Paths(dataDirectory: self.paths.dataDirectory)
        let modelURL = modelURL
        let keyStore = keyStore
        let conditions = conditionsProvider()
        Task {
            do {
                let engine = try await Task.detached(priority: .userInitiated) { () throws -> MemoryEngine in
                    let key = try keyStore.existingKey() ?? keyStore.createKey()
                    let engine = try MemoryEngine(paths: paths, masterKey: key, modelURL: modelURL, conditions: conditions)
                    try engine.start()
                    return engine
                }.value
                guard isEnabled else {
                    Task.detached { engine.stop() }
                    return
                }
                engine.onStatusChange = { [weak self] status in
                    Task { @MainActor in self?.status = status }
                }
                status = engine.status
                self.engine = engine
                state = .running
            } catch MemoryVault.VaultError.keyMismatch {
                state = .keyMismatch
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// What the indexing policy needs, read on the main actor (the power monitor lives there).
    private func conditionsProvider() -> @Sendable () async -> EmbeddingSchedulePolicy.Conditions {
        { [weak self] in
            await MainActor.run {
                // kCGAnyInputEventType (~0): the time since any keyboard or mouse input.
                let anyInput = CGEventType(rawValue: ~0) ?? .null
                return EmbeddingSchedulePolicy.Conditions(
                    isOnACPower: self?.isOnACPower() ?? false,
                    isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                    thermalState: ProcessInfo.processInfo.thermalState,
                    userIdleSeconds: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput),
                    isGenerating: self?.isGenerating() ?? false,
                    pendingPassages: 0
                )
            }
        }
    }

    /// The Python service's virtual environment (1.4 GB), LEANN index folders, socket and logs are
    /// no longer used. Deleted once, in the background.
    private func removeObsoleteFiles() {
        let items = paths.obsoleteItems
        Task.detached(priority: .background) {
            for item in items where FileManager.default.fileExists(atPath: item.path) {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }
}
