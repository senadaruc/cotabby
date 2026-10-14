import Combine
import Foundation
import Logging

/// File overview:
/// The app's single source of truth for "is mlx-lm usable here, and where". It checks the known
/// install places, probes each candidate's version, and runs at most one install at a time, so
/// Settings and the server wiring observe one `state`. Owned by `CotabbyAppEnvironment` for the
/// app's lifetime. The server manager never installs anything; it only reads `state.toolchain`.
@MainActor
final class MLXToolchainProvisioner: ObservableObject {
    typealias VersionProbe = (URL) async -> String?

    @Published private(set) var state: MLXToolchainState = .checking

    private let paths: MLXPaths
    private let home: URL
    private let fileManager: FileManager
    private let probeVersion: VersionProbe
    private let installer: MLXToolchainInstalling
    private var installTask: Task<Void, Never>?

    init(
        paths: MLXPaths,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        probeVersion: @escaping VersionProbe,
        installer: MLXToolchainInstalling
    ) {
        self.paths = paths
        self.home = home
        self.fileManager = fileManager
        self.probeVersion = probeVersion
        self.installer = installer
    }

    static func live(paths: MLXPaths) -> MLXToolchainProvisioner {
        MLXToolchainProvisioner(
            paths: paths,
            probeVersion: { python in
                guard let result = try? await MLXProcessRunner.run(
                    executable: python,
                    arguments: ["-I", "-c", MLXToolchainRules.versionProbeScript],
                    environment: MLXToolchainRules.sanitizedEnvironment(ProcessInfo.processInfo.environment),
                    timeout: .seconds(5)
                ), result.status == 0 else { return nil }
                let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                return version.isEmpty ? nil : version
            },
            installer: MLXToolchainInstaller.live(paths: paths)
        )
    }

    /// Re-checks the install places unless an install is running (its own completion re-checks).
    func refresh() async {
        guard installTask == nil else { return }
        state = .checking
        let located = await locate()
        guard installTask == nil else { return }
        state = located
    }

    /// First candidate with a parseable launcher and a version at or above the minimum wins. A
    /// candidate whose Python does not answer (a half-written install) is skipped, never "ready".
    func locate() async -> MLXToolchainState {
        var tooOld: MLXToolchainState?
        for candidate in MLXToolchainRules.serverCandidates(paths: paths, home: home) {
            guard fileManager.isExecutableFile(atPath: candidate.path),
                  let python = interpreter(of: candidate),
                  let version = await probeVersion(python)
            else { continue }
            if MLXToolchainRules.isVersion(version, atLeast: MLXToolchainRules.minimumVersion) {
                return .ready(MLXToolchain(
                    serverExecutable: candidate,
                    pythonExecutable: python,
                    version: version,
                    isCotabbyInstall: candidate.standardizedFileURL == paths.ownServerExecutable.standardizedFileURL
                ))
            }
            tooOld = tooOld ?? .tooOld(version: version, path: candidate.path)
        }
        return tooOld ?? .notInstalled
    }

    /// Starts Cotabby's own install. A second call while one runs is ignored, so every caller
    /// shares the one install.
    func install() {
        guard installTask == nil else { return }
        CotabbyLogger.runtime.info("MLX install started")
        installTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.installer.install { [weak self] phase in
                    self?.state = .installing(phase)
                }
                let located = await self.locate()
                self.state = located.toolchain != nil
                    ? located
                    : .failed(reason: "MLX was installed but does not start.", logTail: [])
            } catch is CancellationError {
                self.state = await self.locate()
            } catch let error as MLXInstallError {
                CotabbyLogger.runtime.error("MLX install failed: \(error.localizedDescription)")
                self.state = .failed(reason: error.localizedDescription, logTail: error.logTail)
            } catch {
                CotabbyLogger.runtime.error("MLX install failed: \(error.localizedDescription)")
                self.state = .failed(reason: error.localizedDescription, logTail: [])
            }
            self.installTask = nil
        }
    }

    func cancelInstall() {
        installTask?.cancel()
    }

    /// Deletes Cotabby's own MLX folder (models in the Hugging Face cache are kept), then
    /// re-checks: an external install may still be usable.
    func remove() async {
        installTask?.cancel()
        installTask = nil
        try? fileManager.removeItem(at: paths.root)
        CotabbyLogger.runtime.info("Removed Cotabby's MLX install")
        state = await locate()
    }

    /// Reads the launcher's first lines through any symlink (uv's bin entries are symlinks).
    private func interpreter(of script: URL) -> URL? {
        guard let handle = try? FileHandle(forReadingFrom: script.resolvingSymlinksInPath()) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 1024)) ?? Data()
        return MLXToolchainRules.interpreter(fromScript: String(decoding: head, as: UTF8.self))
    }
}
