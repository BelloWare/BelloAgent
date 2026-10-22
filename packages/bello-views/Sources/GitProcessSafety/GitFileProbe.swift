import Foundation

/// A kernel filesystem call cannot be cancelled. Keep it off the read worker,
/// bound its wait, and never start another probe for a path still in flight.
/// Results are not cached: each completed probe belongs only to its caller.
public enum GitFileProbe {
    private final class Pending<Value>: @unchecked Sendable {
        let condition = NSCondition()
        var result: Result<Value, Error>?
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: [Data: TimeInterval] = [:]
    nonisolated(unsafe) private static var running = 0
    private static let queue = DispatchQueue(label: "Bello.git.filesystem", qos: .userInitiated, attributes: .concurrent)

    private static func claim(_ keys: Set<Data>, invocation: GitInvocation, deadline: TimeInterval, worker: Bool) throws {
        while true {
            try invocation.check()
            let acquired = try lock.withLock {
                let overlaps = keys.compactMap { paths[$0] }
                guard overlaps.isEmpty else {
                    if overlaps.contains(where: { ProcessInfo.processInfo.systemUptime >= $0 }) { throw GitConfiguration.ConfinementRequired() }
                    return false
                }
                guard !worker || running < 8 else { throw GitConfiguration.ConfinementRequired() }
                for key in keys { paths[key] = deadline }
                if worker { running += 1 }; return true
            }
            if acquired { return }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw GitConfiguration.ConfinementRequired() }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
    private static func release(_ keys: Set<Data>, worker: Bool) {
        lock.withLock {
            for key in keys { paths.removeValue(forKey: key) }
            if worker { running -= 1 }
        }
    }

    /// One worker validates a warm inventory. Register only the stamp being
    /// checked, so a stalled include does not reserve common ancestors such
    /// as "/" and force unrelated repositories into confinement.
    static func allSatisfy<Value: Sendable>(_ values: [Value], path: @escaping @Sendable (Value) -> String,
                                           invocation: GitInvocation, check: @escaping @Sendable (Value) throws -> Bool) throws -> Bool {
        let deadline = min(ProcessInfo.processInfo.systemUptime + 0.1, invocation.deadline)
        return try run(paths: [], invocation: invocation) {
            for value in values {
                try invocation.check()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw GitConfiguration.ConfinementRequired() }
                let key: Set<Data> = [Data(path(value).utf8)]
                try claim(key, invocation: invocation, deadline: deadline, worker: false)
                let matches: Bool
                do { matches = try check(value) }
                catch { release(key, worker: false); throw error }
                release(key, worker: false)
                if !matches { return false }
            }
            return true
        }
    }

    public static func run<Value>(paths names: [String], invocation: GitInvocation,
                                   _ body: @escaping @Sendable () throws -> Value) throws -> Value {
        try invocation.check()
        let keys = Set(names.map { Data($0.utf8) })
        let now = ProcessInfo.processInfo.systemUptime
        // Leave time for the confined command within the same read deadline.
        let deadline = now + min(0.1, max(0, (invocation.deadline - now) / 2))
        try claim(keys, invocation: invocation, deadline: deadline, worker: true)
        let pending = Pending<Value>()
        queue.async {
            let result = Result { () throws -> Value in
                try invocation.check()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw GitConfiguration.ConfinementRequired() }
                return try body()
            }
            release(keys, worker: true)
            pending.condition.lock(); pending.result = result; pending.condition.broadcast(); pending.condition.unlock()
        }
        while true {
            try invocation.check()
            pending.condition.lock()
            let result = pending.result
            if result == nil, ProcessInfo.processInfo.systemUptime < deadline {
                _ = pending.condition.wait(until: Date(timeIntervalSinceNow: 0.005))
                pending.condition.unlock(); continue
            }
            pending.condition.unlock()
            try invocation.check()
            guard let result else { throw GitConfiguration.ConfinementRequired() }
            return try result.get()
        }
    }
}
