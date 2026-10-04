import Darwin
import Foundation

/// File overview:
/// Starts a child process that does NOT inherit Cotabby's privacy permissions.
///
/// Why this exists: macOS's privacy system (TCC) attributes a child process to its "responsible"
/// process, normally the app that launched it, so a child started with `Process` can use
/// everything Cotabby was granted: Accessibility, Input Monitoring, Screen Recording, Full Disk
/// Access. The memory service runs Python code from a user-writable virtual environment; if it
/// inherited those grants, anything able to write into that folder could borrow Cotabby's
/// permissions. Spawning with responsibility disclaimed makes the child responsible for itself,
/// so it has none of them; data that needs a permission is read by Cotabby's own signed code and
/// handed to the service over its socket instead.
///
/// The disclaim flag is set with `responsibility_spawnattrs_setdisclaim`, which libsystem has
/// exported since macOS 10.14 but no SDK header declares, so it is looked up at runtime. If it is
/// ever missing, spawning fails closed rather than starting a child with Cotabby's permissions.
///
/// The child also starts with only stdin (/dev/null), stdout (a pipe Cotabby reads) and stderr
/// (/dev/null): `POSIX_SPAWN_CLOEXEC_DEFAULT` keeps every other descriptor Cotabby has open
/// (sockets, files, the accept tap's ports) out of it.
enum IsolatedProcessSpawner {
    struct Child {
        let pid: pid_t
        /// The read end of the child's stdout.
        let stdout: FileHandle
    }

    enum SpawnError: LocalizedError {
        case isolationUnavailable
        case failed(Int32)

        var errorDescription: String? {
            switch self {
            case .isolationUnavailable:
                return "This macOS version does not allow starting the memory service without Cotabby's permissions."
            case .failed(let code):
                return "Could not start the memory service (\(String(cString: strerror(code))))."
            }
        }
    }

    private typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    /// `RTLD_DEFAULT` is `(void *)-2` in <dlfcn.h>; Swift does not import that macro.
    private static let setDisclaim: SetDisclaim? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetDisclaim.self)
    }()

    static var isIsolationAvailable: Bool { setDisclaim != nil }

    /// Starts `executable`. With `outputPath`, stdout and stderr are appended to that file (and
    /// `Child.stdout` reads nothing); otherwise stdout is a pipe and stderr goes to /dev/null.
    /// `stdinPayload`, when given, is written to the child's stdin and the pipe closed: the way the
    /// memory service receives its encryption key, which an argument or environment variable would
    /// expose to other processes through `ps`.
    static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        outputPath: String? = nil,
        stdinPayload: Data? = nil
    ) throws -> Child {
        guard let setDisclaim else { throw SpawnError.isolationUnavailable }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        guard setDisclaim(&attributes, 1) == 0 else { throw SpawnError.isolationUnavailable }
        // Close-on-exec for every inherited descriptor except the three set up below. The child
        // keeps Cotabby's process group so a Cotabby crash report shows them together; the
        // service exits on its own when Cotabby's pid disappears (--parent-pid).
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        var pipeDescriptors: [Int32] = [0, 0]
        guard pipe(&pipeDescriptors) == 0 else { throw SpawnError.failed(errno) }
        let readEnd = pipeDescriptors[0]
        let writeEnd = pipeDescriptors[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var stdinDescriptors: [Int32] = [-1, -1]
        if stdinPayload != nil {
            guard pipe(&stdinDescriptors) == 0 else { throw SpawnError.failed(errno) }
            posix_spawn_file_actions_adddup2(&actions, stdinDescriptors[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        if let outputPath {
            posix_spawn_file_actions_addopen(&actions, 1, outputPath, O_WRONLY | O_APPEND | O_CREAT, 0o600)
            posix_spawn_file_actions_adddup2(&actions, 1, 2)
        } else {
            posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        }

        // posix_spawn takes NULL-terminated C string arrays; strdup copies are freed after the call
        // (the child has its own copy of the image by then).
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(writeEnd)
        if stdinPayload != nil { close(stdinDescriptors[0]) }
        guard status == 0 else {
            close(readEnd)
            if stdinPayload != nil { close(stdinDescriptors[1]) }
            throw SpawnError.failed(status)
        }
        if let stdinPayload {
            // The payload is a single short line (well under the pipe buffer), so this write never
            // blocks on the child reading it.
            stdinPayload.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(stdinDescriptors[1], raw.baseAddress! + offset, raw.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
            close(stdinDescriptors[1])
        }
        return Child(pid: pid, stdout: FileHandle(fileDescriptor: readEnd, closeOnDealloc: true))
    }

    /// Spawns isolated and waits for the exit status. Blocking: call from a background task.
    static func runToCompletion(
        executable: String,
        arguments: [String],
        environment: [String: String],
        outputPath: String
    ) throws -> Int32 {
        let child = try spawn(executable: executable, arguments: arguments, environment: environment, outputPath: outputPath)
        var status: Int32 = 0
        while waitpid(child.pid, &status, 0) < 0 && errno == EINTR {}
        // Decode the wait status like WEXITSTATUS / WIFSIGNALED (macros Swift does not import).
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// The pid macOS holds responsible for `pid`'s privacy decisions (for diagnostics and tests),
    /// or nil when the lookup is unavailable.
    static func responsiblePid(for pid: pid_t) -> pid_t? {
        typealias Lookup = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        let responsible = unsafeBitCast(symbol, to: Lookup.self)(pid)
        return responsible > 0 ? responsible : nil
    }
}
