import Foundation

/// Optional, bounded monitoring data. It never participates in replay/context,
/// billing persistence or tool authorization. Cursors disclose dropped history.
struct SessionMonitoringBuffer: Sendable {
    static let limit = 96
    var sequence = 0
    var generation = 0
    private var attempt: String?
    private var phase: String?
    private var records: [JSON] = []
    mutating func append(_ value: JSON, at: Double) {
        sequence += 1
        var record = value; record["seq"] = JSON(sequence); record["observedAt"] = JSON(at)
        records.append(record)
        if records.count > Self.limit { records.removeFirst(records.count - Self.limit) }
    }
    mutating func activity(_ next: String, at: Double) {
        guard next != phase else { return }; phase = next
        append(["kind":"phase", "phase":JSON(next)], at: at)
    }
    mutating func observation(_ value: RequestObservation) {
        if attempt != value.attemptID { generation += 1; attempt = value.attemptID }
        let source = value.json
        var record: JSON = ["kind":"request", "generation":JSON(generation)]
        for key in ["attemptID", "purpose", "requestedModel", "usage", "status", "fieldPhase", "phase", "sourceEvent", "receivedAt", "eventSequence"] { record[key] = source[key] }
        record["telemetry"] = value.monitoring
        append(record, at: nowMS())
    }
    func page(since: Int?, epoch: String, requestedEpoch: String?) -> JSON {
        let cursor = requestedEpoch == epoch ? since ?? 0 : 0
        return ["epoch":JSON(epoch), "cursor":JSON(sequence),
                "gap":JSON(cursor < (records.first?["seq"].int ?? 1) - 1),
                "events":.array(records.filter { ($0["seq"].int ?? 0) > cursor })]
    }
}

extension AgentSession {
    func monitor(_ observation: RequestObservation) {
        monitoring.observation(observation)
        event("monitoring")
    }
}
