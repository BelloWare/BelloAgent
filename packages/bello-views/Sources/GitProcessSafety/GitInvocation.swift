import Foundation
import Darwin

/// One cancellation and deadline cover inventory, cache waits and the command.
public final class GitInvocation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    private var signalled = false
    public let deadline: TimeInterval
    public init(timeout: TimeInterval = 20) {
        deadline = ProcessInfo.processInfo.systemUptime + (timeout.isFinite ? min(600, max(0.01, timeout)) : 20)
    }
    public var isStopped: Bool { lock.withLock { stopped } }
    public func check() throws {
        if isStopped { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime >= deadline {
            stop()
            throw GitConfiguration.Failure("Git timed out; no partial output was applied.")
        }
    }
    public func adopt(_ value: Process) -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            process = value; signalled = false; return true
        }
    }
    public func stop() {
        lock.lock(); stopped = true
        guard !signalled, let running = process, running.isRunning else { lock.unlock(); return }
        signalled = true; lock.unlock()
        let pid = running.processIdentifier
        if getpgid(pid) == pid { kill(-pid, SIGTERM) } else { running.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if running.isRunning {
                if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
            }
        }
    }
}
