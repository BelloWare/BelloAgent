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
    var taskRecords: [TaskPresentationRecord] = []
    /// Read from the journal, not from a helper that has the chat open: only
    /// then is the journal's retained run what the chat's state is.
    var fromJournal = false
    var retainedRun: RetainedRun?
    /// The journal's last record was cut off: this is every complete record,
    /// shown read-only until a recovered copy is made.
    var damagedTail = false

    init(_ wire: WireValue) throws {
        guard let value = wire.object, value["version"]?.number == 2,
              let incarnation = value["incarnation"]?.string, let lineage = value["lineage"]?.string,
              let rows = value["messages"], value["older"] != nil, value["newer"] != nil else {
            throw HostError.failure("Invalid history page. Retry loading this conversation.")
        }
        messages = try TranscriptMessage.page(rows)
        guard messages.count <= HistoryWindowPolicy.rows, Set(messages.map(\.id)).count == messages.count else {
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
        if let raw = value["taskRecords"] {
            taskRecords = try JSONDecoder().decode([TaskPresentationRecord].self, from:JSONEncoder().encode(raw))
            guard taskRecords.count <= 64, taskRecords.allSatisfy({ $0.valid && $0.terminal }) else { throw HostError.failure("Invalid task history evidence") }
        }
    }
    init(_ page: HistoryPage) throws {
        guard page.notice == nil || page.incompleteTail, let incarnation = page.incarnation, let lineage = page.lineage else {
            throw HostError.failure(page.notice ?? "History is not yet available.")
        }
        messages = page.messages; older = page.older; newer = page.newer
        self.incarnation = incarnation; self.lineage = lineage; partialTurnInput = page.partialTurnInput
        notice = page.limitNotice; revision = page.revision; assistantCount = page.assistantMessageCount
        latestAssistantID = page.latestAssistantMessageID; failure = page.failureMessage
        taskRecords = page.taskRecords
        fromJournal = true; retainedRun = page.retainedRun
        if page.incompleteTail {
            damagedTail = true
            notice = "The last record of this chat was cut off while it was written. Everything before it is shown, read-only."
        }
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
    /// The read each boundary's loading flag belongs to. A read that was
    /// superseded (its page replaced under it, then read again) finishes
    /// without clearing the flag of the read that replaced it.
    var olderRead: UUID?
    var newerRead: UUID?
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

extension SessionDisplay {
    /// Shows what the journal says was unfinished when the chat's helper last
    /// stopped, the way the helper restores it when the chat is next used:
    /// a run that was cut off reads as interrupted, with its outcome uncertain
    /// and Retry offered, and follow-ups or steering waiting behind it are
    /// listed, paused, with Resume. Before, such a chat came back idle, and
    /// its first send was refused for paused messages nobody could see.
    /// The waiting rows do not count as work in progress: nothing runs until
    /// the reader resumes, so quit and update do not wait for them.
    func observeRetainedRun(_ page: ConversationHistoryPage) {
        if page.fromJournal, damagedTail != page.damagedTail { damagedTail = page.damagedTail }
        guard page.fromJournal, let run = page.retainedRun, !busy, !loading else { return }
        beginTranscriptBatch(); defer { endTranscriptBatch() }
        if queue != run.queue { queue = run.queue }
        queuePaused = run.queuePaused
        if run.active {
            state = "interrupted"; runStatus = "interrupted"; uncertain = true
            failureMessage = "The previous run was interrupted before it finished. No model or tool request was replayed. Inspect tool effects before continuing."
            notice = "Previous run interrupted. Outcome uncertain; nothing was replayed."
        } else if state != "error" {
            state = "paused"; runStatus = run.runStatus ?? "cancelled"
        }
    }
}
