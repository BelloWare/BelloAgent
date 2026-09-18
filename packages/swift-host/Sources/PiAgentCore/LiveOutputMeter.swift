import Foundation

/// A bounded observation of exposed model output, never provider billing usage.
/// Full incremental bytes survive transcript preview truncation. Tool execution
/// output and opaque reasoning are intentionally absent from this estimate.
struct LiveOutputMeter: Sendable {
    private struct Bucket: Sendable { let start: Double; var bytes: Int }
    private var buckets: [Bucket] = []
    private(set) var active = false
    private(set) var bytes = 0
    private var observed = false
    static let windowMS = 2_000.0

    mutating func begin() { active = true; bytes = 0; observed = false; buckets.removeAll(keepingCapacity: true) }
    mutating func end() { active = false; buckets.removeAll(keepingCapacity: true) }
    mutating func record(_ delta: StreamDelta, at now: Double) {
        guard active, now.isFinite else { return }
        let count: Int
        switch delta {
        case .text(let text), .thinking(let text): count = text.utf8.count
        case .tool(_, _, let arguments): count = arguments.utf8.count
        }
        guard count > 0 else { return }
        bytes += count; observed = true
        let bucket = floor(now / 250) * 250
        buckets.removeAll { $0.start < bucket - Self.windowMS || $0.start > bucket }
        if buckets.last?.start == bucket { buckets[buckets.count - 1].bytes += count }
        else { buckets.append(Bucket(start: bucket, bytes: count)) }
    }
    func rate(at now: Double) -> Double? {
        guard active, observed, now.isFinite else { return nil }
        // Fixed two-second window avoids treating a just-arrived first chunk
        // as an infinite rate. Old samples age out even if the provider stalls.
        let recent = buckets.filter { $0.start > now - Self.windowMS && $0.start <= now }.reduce(0) { $0 + $1.bytes }
        return Double(recent) / 4 / (Self.windowMS / 1000)
    }
}
