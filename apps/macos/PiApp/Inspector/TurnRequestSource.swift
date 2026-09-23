import Foundation

/// Output ownership and the task's dispatch interval, never arbitrary context
/// links: a later turn may replay every message in this turn.
struct TurnRequestScope: Equatable, Sendable {
    var taskKey: String?
    var turnIDs: [String]
    var outputIDs: [String]
    var started: Double?
    var ended: Double?
    var activeCompaction: Bool

    init(_ turn: TurnSummary) {
        taskKey = turn.taskKey
        turnIDs = Array(Set(turn.requests.compactMap(\.turn) + (turn.taskRootID.map { [$0] } ?? []))).sorted()
        outputIDs = turn.requests.filter { $0.role == "assistant" && !$0.id.hasPrefix("stream:") }.map(\.id)
        started = turn.startedAt.flatMap { $0.isFinite && $0 > 0 ? $0 / 1000 : nil }
        ended = turn.endedAt.flatMap { $0.isFinite && $0 > 0 ? $0 / 1000 : nil }
        activeCompaction = turn.isRunning && turn.phase == "compacting" && turn.taskKey?.hasPrefix("utility:") == true
    }
    func contains(_ metadata: [String: WireValue], sessionID: String) -> Bool {
        guard metadata["sessionId"]?.string == sessionID else { return false }
        let owned = activeCompaction && metadata["purpose"]?.string == "compaction" && metadata["outcome"]?.string == "running"
            || metadata["turnId"]?.string.map(turnIDs.contains) == true
            || (metadata["outputMessageIds"]?.array ?? []).contains { $0.string.map(outputIDs.contains) == true }
        guard owned else { return false }
        if let wall = metadata["wallTimestamp"]?.number {
            if let started, wall < started { return false }
            if let ended, wall > ended { return false }
        }
        return true
    }
}

struct TurnRequestRecord: Equatable, Identifiable, Sendable {
    let metadata: [String: WireValue]
    var liveOnly = false
    var id: String { metadata["attemptId"]?.string ?? "" }
    var sessionID: String { metadata["sessionId"]?.string ?? "" }
    var running: Bool { ["running", "streaming"].contains(metadata["outcome"]?.string ?? "") }
    var wall: Double { metadata["wallTimestamp"]?.number ?? 0 }
    var purpose: String { metadata["purpose"]?.string ?? "turn" }
    var route: String {
        GatewayModelRoute(requested: GatewayModelIdentity.modelName(metadata["requestedModel"]?.string),
                          responded: GatewayModelIdentity(metadata: metadata).displayName).label
    }
    var endpoint: String {
        let path = metadata["url"]?.string.flatMap(URL.init(string:))?.path
        return (metadata["method"]?.string ?? "POST") + " " + (path?.isEmpty == false ? path! : "/v1/responses")
    }
    func retained(_ kind: String) -> Bool {
        !liveOnly && MessageBodyReader.canReadRetained(metadata[kind]?.object?["state"]?.string ?? "")
    }
    /// What the body viewer reloads for. A running request's descriptor
    /// changes on every poll only because its byte counters grow; the viewer
    /// offers the newer bytes instead of re-reading the whole body each time.
    /// Its state, and every field once the request has finished, still count.
    func revision(_ kind: String) -> Int {
        var hasher = Hasher()
        hasher.combine(running)
        if running { hasher.combine(metadata[kind]?.object?["state"]?.string) }
        else { hasher.combine(metadata[kind]?.pretty); hasher.combine(metadata[kind + "Hash"]?.pretty) }
        return hasher.finalize()
    }
    /// Retained bytes the latest poll reported for a still-running body.
    func growingBytes(_ kind: String) -> Int? {
        guard running else { return nil }
        return metadata[kind]?.object?["retainedBytes"]?.nonnegativeInteger
    }
}

struct TurnRequestPage: Sendable {
    var records: [TurnRequestRecord]
    var notice = ""
}

@MainActor struct TurnRequestSource {
    let sessionID: String
    let list: (TurnRequestScope) async throws -> TurnRequestPage
    let body: (TurnRequestRecord, String) -> CapturedBodySource
    /// How often an open popup re-reads the list while its turn runs.
    var pollInterval: Duration = .seconds(2)

    static func session(_ model: WorkspaceModel, sessionID: String) -> Self {
        let archive = model.traces
        let workspace = model.record(sessionID)?.workspaceID
        return Self(sessionID: sessionID, list: { [weak model] scope in
            guard let workspace else { throw HostError.failure("The project's retained request records are unavailable.") }
            var durable: [TurnRequestRecord] = [], offset = 0, notice = ""
            do {
                repeat {
                    try Task.checkCancellation()
                    let page = try await archive.turnRequests(sessionID: sessionID, workspaceID: workspace, scope: scope, offset: offset)
                    durable += page.map { TurnRequestRecord(metadata: $0) }; offset += page.count
                    if page.count < 128 { break }
                } while offset <= 100_000
            } catch is CancellationError { throw CancellationError() }
            catch { notice = "Some retained requests could not be loaded. " + error.localizedDescription }
            // Metadata-only polling. Reading/parsing payloads is lazy and scoped
            // to the one request whose tab is actually open.
            var live: [TurnRequestRecord] = []
            if let model {
                var next: Double? = 0
                while let start = next {
                    try Task.checkCancellation()
                    guard let page = try? await model.debugRequest("debug.list", sessionID: sessionID, params: ["offset": .number(start)]) else { break }
                    let values = page["attempts"]?.array?.compactMap(\.object) ?? []
                    live += values.filter { scope.contains($0, sessionID: sessionID) }.map { TurnRequestRecord(metadata: $0, liveOnly: true) }
                    next = page["next"]?.number.flatMap { $0 > start && $0 <= 100_000 ? $0 : nil }
                    if values.isEmpty { break }
                }
            }
            return TurnRequestPage(records: Self.merge(durable: durable, live: live), notice: notice)
        }, body: { record, kind in
            record.retained(kind) ? .archive(archive, attemptID: record.id, kind: kind)
                : .live(model, sessionID: record.sessionID, attemptID: record.id, kind: kind)
        })
    }

    static func merge(durable: [TurnRequestRecord], live: [TurnRequestRecord]) -> [TurnRequestRecord] {
        var records = Dictionary(durable.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for record in live where !record.id.isEmpty {
            if let saved = records[record.id] {
                // Durable captures carry manifests; live metadata can be ahead
                // of the archive while the stream is still being delivered.
                if saved.running && (record.running || record.metadata["outcome"] != saved.metadata["outcome"]) { records[record.id] = record }
            } else { records[record.id] = record }
        }
        return records.values.sorted { $0.wall == $1.wall ? $0.id < $1.id : $0.wall < $1.wall }
    }
}

@MainActor final class TurnRequestController: ObservableObject {
    /// A running turn can gain output owners and a finish timestamp without
    /// changing identity. A retry execution or another session cannot inherit
    /// its selected payload, including while its first lookup is pending.
    private struct Owner: Equatable {
        let sessionID: String
        let taskKey: String?
        let started: Double?
        let inputs: [String]
        init(scope: TurnRequestScope, sessionID: String) {
            self.sessionID = sessionID; taskKey = scope.taskKey
            started = taskKey == nil ? scope.started : nil
            inputs = taskKey == nil ? (scope.turnIDs.isEmpty ? scope.outputIDs : scope.turnIDs) : []
        }
    }
    @Published private(set) var records: [TurnRequestRecord] = []
    @Published var selectedID = ""
    @Published private(set) var loading = false
    @Published private(set) var notice = ""
    private var generation = 0
    private var owner: Owner?
    var selected: TurnRequestRecord? { records.first { $0.id == selectedID } }
    var index: Int? { records.firstIndex { $0.id == selectedID } }
    func load(_ scope: TurnRequestScope, source: TurnRequestSource) async {
        generation += 1; let revision = generation
        let next = Owner(scope: scope, sessionID: source.sessionID)
        if owner != next {
            owner = next; records = []; selectedID = ""; notice = ""
        }
        loading = true
        defer { if generation == revision { loading = false } }
        do {
            let page = try await source.list(scope)
            guard !Task.isCancelled, revision == generation else { return }
            if records != page.records { records = page.records }
            if !records.contains(where: { $0.id == selectedID }) { selectedID = records.last?.id ?? "" }
            notice = page.notice
        } catch {
            guard !Task.isCancelled, revision == generation else { return }
            notice = error.localizedDescription
        }
    }
    func move(_ step: Int) {
        guard let index, records.indices.contains(index + step) else { return }
        selectedID = records[index + step].id
    }
    func cancel() { generation += 1; loading = false }
}
