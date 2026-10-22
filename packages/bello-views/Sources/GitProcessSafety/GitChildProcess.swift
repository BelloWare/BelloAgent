import Foundation
import Darwin

/// Process describes the policy and pipes; posix_spawn passes its strings as
/// UTF-8, without Foundation's filesystem-representation normalization. Every
/// Git executor keeps its existing pipe limits, cancellation and deadline.
public final class GitChildProcess: @unchecked Sendable {
    private let description: Process
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var status: Int32?
    private var stopped = false
    private var started = false
#if DEBUG
    var beforeSpawn: (@Sendable () -> Void)?
#endif
    public init(_ description: Process) { self.description = description }
    public var processIdentifier: pid_t { lock.withLock { pid } }
    public var isRunning: Bool { lock.withLock { reap(); return pid > 0 && status == nil } }
    public var terminationStatus: Int32 { lock.withLock { reap(); return status ?? -1 } }
    private func reap() {
        guard pid > 0, status == nil else { return }
        var raw: Int32 = 0
        if waitpid(pid, &raw, WNOHANG) == pid {
            status = raw & 0x7f == 0 ? (raw >> 8) & 0xff : raw & 0x7f
        }
    }
    public func terminate() {
        lock.withLock {
            stopped = true; reap()
            if pid > 0, status == nil { kill(-pid, SIGTERM) }
        }
    }
    public func killIfRunning() { lock.withLock { reap(); if pid > 0, status == nil { kill(-pid, SIGKILL) } } }
    public func waitUntilExit() { while isRunning { Thread.sleep(forTimeInterval: 0.005) } }

    public func run() throws {
        let executable = try lock.withLock {
            guard !stopped else { throw CancellationError() }
            guard !started, let executable = description.executableURL?.path else {
                throw GitConfiguration.Failure("Git has no executable.")
            }
            started = true; return executable
        }
        let arguments = [executable] + (description.arguments ?? [])
        let environment = (description.environment ?? [:]).map { $0.key + "=" + $0.value }
        let directory = description.currentDirectoryURL?.path ?? "/"
        guard !(arguments + environment + [directory]).contains(where: { $0.utf8.contains(0) }) else {
            throw GitConfiguration.Failure("Git cannot represent a path or argument containing NUL.")
        }
        var argv = arguments.map { $0.withCString { strdup($0) } } + [nil]
        var envp = environment.map { $0.withCString { strdup($0) } } + [nil]
        defer { for value in argv + envp { free(value) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
        func checked(_ code: Int32) throws { if code != 0 { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) } }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the explicitly duplicated pipe ends survive. A process group
        // also lets cancellation stop allowed global programs with their Git.
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)))
        try checked(posix_spawnattr_setpgroup(&attributes, 0))
        var defaults = sigset_t(), mask = sigset_t()
        sigfillset(&defaults); sigemptyset(&mask)
        try checked(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try checked(posix_spawnattr_setsigmask(&attributes, &mask))
        try directory.withCString { try checked(posix_spawn_file_actions_addchdir_np(&actions, $0)) }
        var parentEnds: [Int32: FileHandle] = [:]
        for (destination, stream) in [(STDIN_FILENO, description.standardInput), (STDOUT_FILENO, description.standardOutput), (STDERR_FILENO, description.standardError)] {
            let file: FileHandle
            if let pipe = stream as? Pipe {
                file = destination == STDIN_FILENO ? pipe.fileHandleForReading : pipe.fileHandleForWriting
                parentEnds[file.fileDescriptor] = file
            } else { file = stream as? FileHandle ?? FileHandle.nullDevice }
            if file.fileDescriptor < 0 {
                try checked(posix_spawn_file_actions_addopen(&actions, destination, "/dev/null", destination == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0))
            } else { try checked(posix_spawn_file_actions_adddup2(&actions, file.fileDescriptor, destination)) }
        }
#if DEBUG
        beforeSpawn?()
#endif
        try lock.withLock { if stopped { throw CancellationError() } }
        var spawned: pid_t = 0
        // chdir/exec may touch a slow volume. Cancellation only marks state
        // until a PID exists; it never waits on the spawn's filesystem work.
        try executable.withCString { name in
            try argv.withUnsafeMutableBufferPointer { args in
                try envp.withUnsafeMutableBufferPointer { env in
                    try checked(posix_spawn(&spawned, name, &actions, &attributes, args.baseAddress, env.baseAddress))
                }
            }
        }
        let cancelled = lock.withLock { pid = spawned; return stopped }
        if cancelled { killIfRunning() }
        for end in parentEnds.values { try? end.close() }
    }
}
