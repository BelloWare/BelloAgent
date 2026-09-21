import Foundation

enum ConversationLoadState: Equatable {
    case dormant, loading, preparing, ready, empty, failed(String)
    var loading: Bool { self == .loading || self == .preparing }
}

struct ConversationPageBoundary: Equatable {
    var cursor: ConversationCursor?
    var loading = false
    var error: String?
    var available: Bool { cursor != nil || error != nil }
}

struct ConversationHistoryPage: Sendable {
    var messages: [TranscriptMessage]
    var older: ConversationCursor?
    var newer: ConversationCursor?
    var incarnation: String
    var lineage: String
    var partialTurnInput: String?
    var notice: String?
    var revision: HistoryRevision?
    var assistantCount: Int?
    var latestAssistantID: String?
    var failure: String?

    init(_ wire: WireValue) throws {
        guard let value = wire.object, value["version"]?.number == 2,
              let incarnation = value["incarnation"]?.string, let lineage = value["lineage"]?.string,
              let rows = value["messages"], value["older"] != nil, value["newer"] != nil else {
            throw HostError.failure("Invalid history page. Retry loading this conversation.")
        }
        messages = try TranscriptMessage.page(rows)
        guard messages.count <= HistoryWindowPolicy.rows, Set(messages.map(\.id)).count == messages.count,
              try JSONEncoder().encode(wire).count + 1024 <= HistoryWindowPolicy.envelopeBytes else {
            throw HostError.failure("History page exceeds its display budget or has conflicting identities.")
        }
        self.incarnation = incarnation; self.lineage = lineage
        older = try Self.cursor(value["older"]); newer = try Self.cursor(value["newer"])
        guard (older == nil || older?.entry == messages.first?.id), (newer == nil || newer?.entry == messages.last?.id) else {
            throw HostError.failure("History cursors do not match the visible page edges.")
        }
        for boundary in [older, newer].compactMap({ $0 }) {
            guard boundary.incarnation == incarnation, boundary.lineage == lineage,
                  messages.contains(where: { $0.id == boundary.entry }) else { throw HostError.failure("Invalid history boundary. Reload history.") }
        }
        partialTurnInput = value["partialTurnInput"]?.string
    }
    init(_ page: HistoryPage) throws {
        guard page.notice == nil, let incarnation = page.incarnation, let lineage = page.lineage else {
            throw HostError.failure(page.notice ?? "History is not yet available.")
        }
        messages = page.messages; older = page.older; newer = page.newer
        self.incarnation = incarnation; self.lineage = lineage; partialTurnInput = page.partialTurnInput
        notice = page.limitNotice; revision = page.revision; assistantCount = page.assistantMessageCount
        latestAssistantID = page.latestAssistantMessageID; failure = page.failureMessage
    }
    static func cursor(_ value: WireValue?) throws -> ConversationCursor? {
        guard let value, value != .null else { return nil }
        return try JSONDecoder().decode(ConversationCursor.self, from: JSONEncoder().encode(value))
    }
}

/// Navigation owns these tasks, never the helper's agent/run tasks. The runtime
/// display and draft stay alive while each visit receives a fresh generation.
@MainActor final class ConversationPresentation {
    var generation = UUID()
    var navigation: Task<Void, Never>?
    var olderTask: Task<Bool, Never>?
    var newerTask: Task<Bool, Never>?
    var secondary: Task<Void, Never>?
    var identity: (incarnation: String, lineage: String)?
    var partialTurnInput: String?
    var automaticFills = 0
    var startedAt = PerformanceProbe.now
    var sourceReadyAt: Double?
    var drawOpportunityAt: Double?
    var readyAt: Double?
    func cancel() {
        navigation?.cancel(); navigation = nil
        olderTask?.cancel(); olderTask = nil; newerTask?.cancel(); newerTask = nil
        secondary?.cancel(); secondary = nil
    }
    func begin() {
        cancel(); generation = UUID(); identity = nil; partialTurnInput = nil
        automaticFills = 0; startedAt = PerformanceProbe.now; sourceReadyAt = nil; drawOpportunityAt = nil; readyAt = nil
    }
    deinit { navigation?.cancel(); olderTask?.cancel(); newerTask?.cancel(); secondary?.cancel() }
}
