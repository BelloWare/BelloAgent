import Foundation

// The git commands a listing runs (`FileListing`): on a queue of their own,
// where a blocking wait costs no Swift thread; both pipes drained so neither
// can stall the other; a deadline and a cap on what is kept; and stopped
// when the listing is no longer wanted. GitView's GitService runs git the
// same way; this module knows nothing of it, so the two can meet in one
// place once neither is being changed.

enum FinderProcess {
    struct Output: Sendable {
        let stdout: Data
        let status: Int32
    }
    struct Failure: Error, Equatable, CustomStringConvertible {
        let description: String
    }

    /// Git's environment: no prompts, no optional locks, a known language,
    /// and the user's own home (so their global ignores apply, as in git).
    static let environment = gitEnvironment(from: ProcessInfo.processInfo.environment)

    /// Git's environment, given the app's: where the user's git keeps its
    /// global configuration and ignore file, when they moved it, too.
    static func gitEnvironment(from app: [String: String]) -> [String: String] {
        var environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8",
                           "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"]
        if let config = app["XDG_CONFIG_HOME"], !config.isEmpty { environment["XDG_CONFIG_HOME"] = config }
        return environment
    }

    /// Runs `/usr/bin/git` with `arguments` in `directory`: its standard
    /// output, at most `limit` bytes (more is a failure, never a cut list).
    static func git(_ arguments: [String], in directory: String, limit: Int, timeout: TimeInterval = 60,
                    environment: [String: String] = FinderProcess.environment) async throws -> Output {
        let handle = Running()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, any Error>) in
                queue.async {
                    do { continuation.resume(returning: try execute(arguments, in: directory, limit: limit, timeout: timeout,
                                                                    environment: environment, handle: handle)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { handle.stop() }
    }

    private static let queue = DispatchQueue(label: "BelloViews.finder.git", qos: .userInitiated, attributes: .concurrent)

    /// The process a listing runs, so a listing no longer wanted stops it.
    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var stopped = false
        var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        /// False when the listing was already given up: nothing is started.
        func adopt(_ value: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { return false }
            process = value; return true
        }
        func stop() {
            lock.lock(); stopped = true
            let running = process; lock.unlock()
            guard let running, running.isRunning else { return }
            running.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if running.isRunning { kill(running.processIdentifier, SIGKILL) }
            }
        }
    }

    private static func execute(_ arguments: [String], in directory: String, limit: Int, timeout: TimeInterval,
                                environment: [String: String], handle: Running) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.quotepath=off"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr; process.standardInput = FileHandle.nullDevice
        let out = stdout.fileHandleForReading, err = stderr.fileHandleForReading
        defer { try? out.close(); try? err.close() }
        guard handle.adopt(process) else { throw CancellationError() }
        do { try process.run() } catch { throw Failure(description: "git could not start: \(error.localizedDescription)") }
        let descriptors = [out.fileDescriptor, err.fileDescriptor]
        for descriptor in descriptors { _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) }
        var kept = Data(), ended = [false, false]
        var failure: String?, exitedAt: TimeInterval?
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.01, timeout)
        var scratch = [UInt8](repeating: 0, count: 65_536)
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if now >= deadline, failure == nil { failure = "git took too long"; handle.stop() }
            if handle.isStopped, process.isRunning { handle.stop() }
            if !process.isRunning {
                if exitedAt == nil { exitedAt = now }
                if ended.allSatisfy({ $0 }) { break }
                if now - (exitedAt ?? now) >= 0.25 { failure = failure ?? "git's output did not end"; break }
            }
            for index in 0..<2 where !ended[index] {
                let count = read(descriptors[index], &scratch, scratch.count)
                if count > 0 {
                    // Diagnostics are read and dropped: only the list is kept.
                    guard index == 0, failure == nil else { continue }
                    if count > limit - kept.count { failure = "the list is longer than \(limit / 1_048_576) MiB"; handle.stop() }
                    else { kept.append(contentsOf: scratch.prefix(count)) }
                } else if count == 0 {
                    ended[index] = true
                } else if errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                    ended[index] = true; failure = failure ?? "git's output could not be read"; handle.stop()
                }
            }
            var polls = descriptors.enumerated().map { pollfd(fd: ended[$0.offset] ? -1 : $0.element, events: Int16(POLLIN), revents: 0) }
            _ = poll(&polls, nfds_t(polls.count), 20)
        }
        process.waitUntilExit()
        if handle.isStopped, failure == nil { throw CancellationError() }
        if let failure { throw Failure(description: failure) }
        return Output(stdout: kept, status: process.terminationStatus)
    }
}
