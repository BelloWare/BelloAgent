#if PI_TEST_HOST
import Foundation

/// Phase-A measurements exist only in the isolated test host. Shipping
/// builds contain neither this type nor its call sites.
struct Perf136Span {
    private static let enabled = ProcessInfo.processInfo.environment["TEST_RUNNER_PI_PERF_TRACE"] == "1"
    private let name: String
    private let started: Double?
    init(_ name: String) {
        self.name = name
        started = Self.enabled ? ProcessInfo.processInfo.systemUptime : nil
    }
    func end(_ fields: [String: String] = [:]) {
        guard let started else { return }
        var value = fields
        value["event"] = name
        value["start"] = String(started)
        value["ms"] = String((ProcessInfo.processInfo.systemUptime - started) * 1000)
        value["main"] = String(Thread.isMainThread)
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            print("PERF136_TRACE " + String(decoding: data, as: UTF8.self))
        }
    }
}

/// Demand begins when unread room reaches the viewport, even if a read-ahead
/// is already running. The frame harness ends it only after new rows draw.
/// Unlike request-to-visible, this excludes the reader's travel to a prefetch.
@MainActor enum Perf136Demand {
    private static let enabled = ProcessInfo.processInfo.environment["TEST_RUNNER_PI_PERF_TRACE"] == "1"
    private struct Demand { var started: Double; var rows: Set<String> }
    private static var pending: [String: Demand] = [:]
    static func begin(_ session: SessionDisplay) {
        guard enabled, pending[session.id] == nil else { return }
        pending[session.id] = .init(started: ProcessInfo.processInfo.systemUptime, rows: Set(session.messages.map(\.id)))
    }
    static func drawn(_ session: SessionDisplay, visible: Set<String>, useful: Bool) -> Double? {
        guard let demand = pending[session.id], useful, !visible.isSubset(of: demand.rows) else { return nil }
        pending[session.id] = nil
        return (ProcessInfo.processInfo.systemUptime - demand.started) * 1000
    }
    static func reset(_ id: String) -> Double? {
        pending.removeValue(forKey: id).map { (ProcessInfo.processInfo.systemUptime - $0.started) * 1000 }
    }
}
#endif
