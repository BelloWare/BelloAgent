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
#endif
