import Foundation
import Darwin

public enum GitToolLookupError: LocalizedError {
    case unavailable, timedOut
    public var errorDescription: String? {
        switch self {
        case .unavailable: "The system Git could not be located for a read-only query."
        case .timedOut: "Git tool discovery timed out; no repository command was run."
        }
    }
}

/// One lookup serves all readers. Waiters keep their own cancellation/deadline;
/// a stuck worker stays registered until it actually exits. Only success is
/// cached indefinitely; failures cool down before another reader may retry.
final class GitToolLookup: @unchecked Sendable {
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var shared = GitToolLookup()
    static var current: GitToolLookup {
        get { stateLock.withLock { shared } }
        set { stateLock.withLock { shared = newValue } }
    }
    private let condition = NSCondition()
    private var cached: Result<URL, Error>?
    private var pending = false, retryAfter: TimeInterval = 0
    private let lookup: @Sendable (GitInvocation) throws -> URL
    init(lookup: @escaping @Sendable (GitInvocation) throws -> URL = GitToolLookup.discover) { self.lookup = lookup }

    func get(invocation: GitInvocation) throws -> URL {
        while true {
            do { try invocation.check() }
            catch is CancellationError { throw CancellationError() }
            catch { throw GitToolLookupError.timedOut }
            condition.lock()
            if let cached {
                if case .failure = cached, ProcessInfo.processInfo.systemUptime >= retryAfter { self.cached = nil }
                else { condition.unlock(); return try cached.get() }
            }
            if !pending {
                pending = true
                let lookupInvocation = GitInvocation(timeout: 20)
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    let result = Result { try lookup(lookupInvocation) }
                    condition.lock()
                    cached = result; retryAfter = ProcessInfo.processInfo.systemUptime + 1
                    pending = false; condition.broadcast(); condition.unlock()
                }
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.01)); condition.unlock()
        }
    }

    /// xcrun uses selected developer tools, never PATH or repository config.
    /// Resolve before sandboxing; never substitute Apple's /usr/bin/git shim.
    static func discover(_ invocation: GitInvocation) throws -> URL {
        try invocation.check()
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun", isDirectory: false)
        process.arguments = ["--find", "git"]; process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let reader = output.fileHandleForReading, child = GitChildProcess(process)
        defer { try? reader.close() }
        guard invocation.adopt(child) else { throw CancellationError() }
        do { try child.run() } catch { throw GitToolLookupError.unavailable }
        defer { child.killIfRunning(); child.waitUntilExit() }
        let descriptor = reader.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096), ended = false
        while !ended || child.isRunning {
            do { try invocation.check() } catch { throw GitToolLookupError.timedOut }
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
            else if count == 0 { ended = true }
            else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw GitToolLookupError.unavailable }
            guard data.count <= 65_536 else { throw GitToolLookupError.unavailable }
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            _ = poll(&poller, 1, 10)
        }
        let bytes = data.last == 10 ? data.dropLast() : data
        guard child.terminationStatus == 0, let path = String(data: bytes, encoding: .utf8),
              path.gitHasPrefix("/"), !path.utf8.contains(0) else { throw GitToolLookupError.unavailable }
        do {
            return try GitFileProbe.run(paths: [path], invocation: invocation) {
                guard FileManager.default.isExecutableFile(atPath: path) else { throw GitToolLookupError.unavailable }
                let resolved = URL(fileURLWithPath: path, isDirectory: false).resolvingSymlinksInPath()
                guard resolved.path != "/usr/bin/git" else { throw GitToolLookupError.unavailable }
                return resolved
            }
        } catch is GitConfiguration.ConfinementRequired { throw GitToolLookupError.timedOut }
    }
}
