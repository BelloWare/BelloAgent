import Foundation
import AppKit

// Opt-in fixture instrumentation. It records durations/counts only, never chat
// text, requests, credentials or filesystem contents. Normal releases are inert.
@MainActor final class PerformanceProbe {
    static let shared = PerformanceProbe()
    let output: URL?
    var enabled: Bool { output != nil }
    private var samples: [String: [Double]] = [:]
    private var totals: [String: Int] = [:]
    private var selections: [String: Double] = [:]
    private var visibleSince: [String: Double] = [:]
    private var lastWrite = 0.0
    private var wroteShell = false
    private var flushTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var pendingWrite = false
    private init() {
        output = ProcessInfo.processInfo.environment["PI_APP_BENCHMARK_OUTPUT"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
    }
    static var now: Double { ProcessInfo.processInfo.systemUptime * 1000 }
    func observe(_ metric: String, milliseconds: Double) {
        guard enabled, milliseconds.isFinite, milliseconds >= 0 else { return }
        totals[metric, default: 0] += 1
        if samples[metric, default: []].count == 8192 { samples[metric]?.removeFirst(4096) }
        samples[metric, default: []].append(milliseconds)
        if Self.now - lastWrite > 1000 { flush() }
        else if flushTask == nil { flushTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            self?.flushTask = nil; self?.flush()
        } }
    }
    func shellReady() {
        guard enabled, !wroteShell, let launch = NSRunningApplication.current.launchDate else { return }
        wroteShell = true; observe("coldShellLaunchToFirstDrawMs", milliseconds: Date().timeIntervalSince(launch) * 1000)
    }
    func beginSelection(_ id: String, hasHistory: Bool) {
        guard enabled else { return }
        if selections.count > 128 { selections.removeAll() }
        if visibleSince.count > 128 { visibleSince.removeAll() }
        if hasHistory { selections[id] = Self.now }; visibleSince[id] = Self.now
    }
    /// Called when the native transcript applies a snapshot, before SwiftUI's
    /// deferred layout/display work. It is deliberately not a paint metric.
    func transcriptSnapshotApplied(_ id: String, deltaAt: Double?) {
        guard enabled else { return }
        if let start = selections.removeValue(forKey: id) { observe("chatSelectionToSnapshotMs", milliseconds: Self.now - start) }
        if let deltaAt, deltaAt >= (visibleSince[id] ?? 0) {
            observe("oldestForegroundDeltaToSnapshotMs", milliseconds: Self.now - deltaAt)
        }
    }
    func flush() {
        guard let output else { return }; flushTask?.cancel(); flushTask = nil
        guard writeTask == nil else { pendingWrite = true; return }
        lastWrite = Self.now; pendingWrite = false
        let snapshot = samples, totals = totals, pid = ProcessInfo.processInfo.processIdentifier
        let build = ReleaseConfiguration.current.build, version = ReleaseConfiguration.current.version
        writeTask = Task {
          await Task.detached(priority: .utility) {
          let reports = snapshot.mapValues { values -> [String: Double] in
            let sorted = values.sorted(); func percentile(_ fraction: Double) -> Double { sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))] }
            return ["retainedSamples": Double(sorted.count), "p50": percentile(0.5), "p95": percentile(0.95), "p99": percentile(0.99), "max": sorted.last ?? 0]
        }
        let value: [String: Any] = ["pid": pid, "build": build, "version": version,
                                   "metrics": reports, "samples": snapshot, "totalSamples": totals, "method": "Native edit event timestamp to NSTextView draw (Send is excluded); chat selection and oldest unsent host delta to native transcript snapshot application. Snapshot metrics end before deferred SwiftUI layout/display and must not be treated as visible paint. Native draw is a paint opportunity, not physical scanout. Bounded off-main statistics; no content logged."]
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? bytes.write(to: output, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
          }.value
          self.writeTask = nil
          if self.pendingWrite { self.flush() }
        }
    }
}
