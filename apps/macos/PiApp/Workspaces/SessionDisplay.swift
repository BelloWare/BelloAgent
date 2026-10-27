import Foundation
import Combine

// One open chat as the screen sees it: its rows, its run state, its queue,
// its draft and the figures its footer shows. A `SessionDisplay` exists for
// as long as someone is reading or running that chat; `WorkspaceModel` owns
// the table of them and lets go of the ones nobody is looking at.

@MainActor final class SessionMetrics: ObservableObject {
    @Published var context: [String: WireValue] = [:]
    @Published var requestObservation: [String: WireValue] = [:]
    @Published var lastRequestObservation: [String: WireValue] = [:]
    var contextObservationRevision: String?
    @Published var contextState: [String: WireValue] = [:]
    var contextStateRevision: String?
    @Published var pendingContextSubmission: String?
    var contextSubmissionAcknowledged=false
    var contextInputIdentity: ContextInputIdentity? { ContextInputIdentity(contextState) }
    @Published var preparedContext: PreparedContextMetrics?
    @Published var preparingContext = false
    /// The reading this chat's pill showed when it was last counted, while it
    /// still stands (`ContextReading`).
    @Published var retainedContext: ContextReading?
    /// The room the context pill keeps for this showing of the chat
    /// (`ContextPillSlot`). Not published; nothing is drawn again for it.
    var contextSlot: ContextPillSlot?
    let activityChanges = PassthroughSubject<Void, Never>()
    @Published var metrics: [String: WireValue] = [:] { didSet { if metrics != oldValue { activityChanges.send() } } }
    @Published var turnTiming: [String: WireValue] = [:] { didSet { if turnTiming != oldValue { activityChanges.send() } } }
    @Published var timing = SessionTimingHistory() { didSet { if timing != oldValue { activityChanges.send() } } }
    @Published var gateway = GatewayTotals() { didSet { if gateway != oldValue { activityChanges.send() } } }
    @Published var gatewayNotice = ""
    /// The chat's spend against its cost limit: the limit the app runs it
    /// under and what its helper counted (`SessionCostReading`).
    @Published var cost = SessionCostReading()
}
@MainActor final class ComposerDraft: ObservableObject { @Published var text = "" }

/// An earlier version of an edited message, on screen in place of the latest
/// one: which version, the rows read of it so far, and the tasks their turn
/// cards read.
struct TranscriptVersionView: Equatable, Sendable {
    /// In-memory ownership of this version read, including same-index retries.
    var loadID = UUID()
    /// The latest version's message: the row of `messages` whose switcher was used.
    var latestID: String
    /// The version shown, 1-based, of `count`; every version's message id,
    /// oldest first; and which of them `latestID` is, the one the chat holds.
    var index: Int
    var count: Int
    var ids: [String]
    var live: Int
    var rows: [TranscriptMessage] = []
    var tasks: [TaskPresentationRecord] = []
    var loading = true
    var failure: String? = nil
    var shownID: String { ids[index - 1] }
    /// The quiet banner above the version, then its rows: the first carries
    /// the switcher, every one is read-only.
    var presented: [TranscriptMessage] {
        var banner = TranscriptMessage(id: "version-banner:" + latestID, role: "system", text: "Earlier version", kind: "versionBanner")
        banner.detail = "replies from before your edit"
        var shown = [banner]
        if rows.isEmpty {
            var placeholder = TranscriptMessage(id: "version-reading:" + shownID, role: "system", text: failure ?? "Reading this version…", kind: "notice")
            placeholder.earlierVersion = true
            shown.append(placeholder)
        } else { shown += rows }
        return shown
    }
    /// A page of the helper's rows as this view shows them.
    /// `first`: the page that starts the version, whose first row, the
    /// version's own message, carries the switcher.
    static func readOnly(_ rows: [TranscriptMessage], index: Int, count: Int, ids: [String], first: Bool = true) -> [TranscriptMessage] {
        rows.enumerated().map { offset, row in
            var row = row
            row.earlierVersion = true
            row.versions = first && offset == 0 && row.role == "user" ? MessageVersionMark(index: index, count: count, ids: ids) : nil
            return row
        }
    }
}

@MainActor final class SessionDisplay: ObservableObject {
    var subagentsRevision: String?
    var isManagedSubagent = false
    var supportsCodexAgents = false { didSet { if supportsCodexAgents != oldValue { publishTranscript() } } }
    var inheritedContextMessages: Int?
    var inheritedContextFolded: Bool {
        guard supportsCodexAgents, let first = messages.first, let group = TaskTranscriptPlan.inheritedGroup(first) else { return false }
        return !disclosure.isOpen(.turnFold(group))
    }
    var subagentNames: [String: String] = [:] { didSet { if subagentNames != oldValue { publishTranscript() } } }
    @Published var subagentStatus: SubagentStatus?
    @Published var subagentTurn: Int?
    var agentSourceEvents: [String: AgentCoordinationEntry] = [:]
    var agentCoordination: [String: AgentCoordinationEntry] = [:] {
        didSet {
            guard agentCoordination != oldValue else { return }
            agentSourceEvents = Dictionary(agentCoordination.values.compactMap { entry in
                guard entry.sourceSessionID == id, let message = entry.sourceMessageID, let call = entry.sourceToolCallID else { return nil }
                return (ToolOccurrence.key(message, call), entry)
            }, uniquingKeysWith: { first, _ in first })
            publishTranscript()
        }
    }
    @Published var heldAgentChildren: Set<String> = [] { didSet { if heldAgentChildren != oldValue { publishTranscript() } } }
    var childSummaries: [String: SubagentSummary] = [:] { didSet { if childSummaries != oldValue { publishTranscript() } } }
    var subagentCosts: [String: SubagentCostPresentation] = [:] { didSet { if subagentCosts != oldValue { publishTranscript() } } }
    var originalSubagentAvailability: [String: OriginalSubagentAvailability] = [:] { didSet { if originalSubagentAvailability != oldValue { publishTranscript() } } }
    var subagentNumbers: [String: Int] = [:] { didSet { if subagentNumbers != oldValue { publishTranscript() } } }
    var subagentEfforts: [String: SubagentEffort] = [:] { didSet { if subagentEfforts != oldValue { publishTranscript() } } }
    @Published var familyWaiting = false { didSet { if familyWaiting != oldValue { publishTranscript() } } }
    @Published var agentInboxPending = 0 { didSet { if agentInboxPending != oldValue { publishTranscript() } } }
    @Published var delegatedTask: String?
    /// Committed activity only: text, draft, selection and context rendering do not enter this stream.
    let activityChanges = PassthroughSubject<Void, Never>()
    let id: String
    let presentation = ConversationPresentation()
    @Published var presentationGeneration = UUID()
    @Published var historyState: ConversationLoadState = .dormant
    /// A revisit of a chat whose rows were already on the page: they stay
    /// there, uncovered, while its fresh page is read and placed, instead of
    /// fading a loading cover over them for the length of the read.
    @Published var refreshingCachedRows = false
    /// Rows this display has presented, which a revisit keeps on the page.
    var hasPresentedRows: Bool { !messages.isEmpty && (presentation.identity != nil || refreshingCachedRows) }
    /// The rows held here are from a run that has finished since: a chat in
    /// the background is asked for its status, not its rows, so they stopped
    /// where the reader left them — a reply still arriving, its turn still
    /// live. Kept on the page, they changed under the reader as soon as the
    /// finished page replaced them.
    /// So are rows read out of sight once the helper's rows have moved past
    /// them: another run has come and gone since they were read.
    var heldRowsOutlived: Bool {
        !busy && !loading && runState == .idle && sendingRows.isEmpty
            && (taskPresentation?.active != nil || messages.contains { $0.isStreaming || $0.isSending }
                || heldRowsRevision.map { $0 != helperDisplayRevision } == true)
    }
    /// The read that brings such rows up to date while the chat is still out
    /// of sight (`WorkspaceModel.catchUpFinishedRows`).
    var finishedRowsRead: Task<Void, Never>?
    /// A status asked for that read while one was under way: the chat is
    /// looked at again once it is done.
    var finishedRowsAgain = false
    /// The helper's revision of this chat's rows, as its last snapshot gave
    /// it: also for a chat out of sight, which is sent its status, not its rows.
    var helperDisplayRevision: String?
    /// The helper's revision the rows held here were read at, when the chat
    /// read them for itself out of sight (`catchUpFinishedRows`); nil for
    /// rows from anywhere else.
    var heldRowsRevision: String?
    @Published var historyProgress: String?
    @Published var olderPage = ConversationPageBoundary()
    /// Where the window stands in the whole chat, for the room the transcript
    /// keeps for the rows it has not read (`HistoryExtent`).
    let historyPositions = HistoryPositions()
    /// The page read for where the reader dragged or scrolled to, in rows the
    /// window does not hold (`WorkspaceModel.jumpToHistoryPosition`).
    var jumpRead: Int?
    var jumpTask: Task<Void, Never>?
    var jumpWanted: (position: Int, offset: Double)?
    /// The reader went somewhere else (a reveal, Back to bottom, Latest, back
    /// into the rows the window holds): a page read for where they were
    /// does not land.
    func abandonJump() { jumpTask?.cancel(); jumpTask = nil; jumpRead = nil; jumpWanted = nil; jumpRetry = nil; jumpReading = nil; jumpOffset = nil; jumpFailedAt = nil; jumpUnreadable = 0 }
    /// Where the reader is now within the row being read for.
    var jumpOffset: Double?
    /// The position the read under way is for.
    var jumpReading: Int?
    /// Position reads in a row that found the journal unreadable as it was.
    var jumpUnreadable = 0
    /// The generation and timeline last asked for missing positions
    /// (`WorkspaceModel.reacquireHistoryPositions`).
    var positionsReadFor: String?
    /// A read that failed, to be tried again where the reader still is.
    var jumpRetry: (position: Int, offset: Double)?
    /// When such a read last failed: the next waits a moment, then reads
    /// where the reader is again.
    var jumpFailedAt: TimeInterval?
    /// The place the transcript was last asked to show (`revealInTranscript`):
    /// the page lands on it and marks its range.
    @Published var reveal: TranscriptReveal?
    /// ⌘F, ⌘G and ⇧⌘G for this chat's find bar (`TranscriptFindCommand`).
    @Published var findCommand: TranscriptFindCommand?
    /// The pane that last opened this chat's find bar.
    weak var findHost: (any TranscriptFindHost)?
    /// The messages of the rows on the reader's screen right now, from
    /// the page showing this chat. A page read in at an edge never lets go of
    /// them, whatever the last reported anchor says.
    var visibleMessageIDs: (@MainActor () -> Set<String>)?
    /// The reveal whose read is under way; a newer one, or the reader moving,
    /// supersedes it.
    var revealRead: Int?
    /// Why the last reveal's read failed, for whoever asked for it.
    var revealFailure: String?
    /// The reader went somewhere else (a key, Back to bottom, Latest, their
    /// own scroll): a reveal still reading its page or waiting for presentation
    /// is let go of, so a queued refresh cannot take them back to its mark.
    func abandonReveal() {
        guard revealRead != nil || reveal != nil else { return }
        revealRead = nil
        reveal = nil
    }
    @Published var newerPage = ConversationPageBoundary()
    @Published var draftReady = true
    @Published var recoveringDraft = false
    var completionTracker = SessionCompletionTracker()
    /// Every run's end, failed, stopped or retried too: what updates the
    /// chat's brief.
    var runEndTracker = RunEndTracker()
    var webhookTracker = WebhookFinishTracker()
    var monitoringEpoch: String?
    var monitoringCursor: Double?
    let transcriptChanges = CurrentValueSubject<[TranscriptMessage], Never>([])
    let presentationChanges = CurrentValueSubject<TranscriptPresentationInput, Never>(.init(messages:[], lifecycle:nil))
    /// The chat's tasks as the helper last presented them. Any write that
    /// is not the snapshot loop adopting a presentation (`adoptTaskPresentation`)
    /// forgets its revision, so the next snapshot carries the helper's whole
    /// presentation again, as every snapshot did before 0.1.85.
    var taskPresentation: TaskPresentationProjection? { didSet { taskPresentationRevision = nil; if oldValue != taskPresentation { publishTranscript(invalidateProjection: false) } } }
    /// The helper's revision of `taskPresentation`, sent back with the next
    /// snapshot so an unchanged presentation is left out of the reply.
    var taskPresentationRevision: String?
    func adoptTaskPresentation(_ value: TaskPresentationProjection, revision: String?) {
        taskPresentation = value; taskPresentationRevision = revision
    }
    private var transcriptBatchDepth = 0
    func beginTranscriptBatch() { transcriptBatchDepth += 1 }
    func endTranscriptBatch() { transcriptBatchDepth -= 1; if transcriptBatchDepth == 0 { publishTranscript(invalidateProjection: false) } }
    var messages: [TranscriptMessage] = [] {
        didSet {
            projectionRevision = nil; messagesRevision = UUID()
            if !replacingMessages {
                messagePositions = Dictionary(messages.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
                messageBytes = messages.reduce(0) { $0 + TranscriptPaging.size($1) }
            }
            adoptDeliveredSending()
            publishTranscript(invalidateProjection: !replacingMessages)
        }
    }
    var messagesRevision = UUID()
    var messagePositions: [String: Int] = [:]
    var messageBytes = 0
    var replacingMessages = false
    var messageProjection = TranscriptMessageProjection()
    var presentedMessageVisits = 0
    func replaceMessage(at index: Int, with row: TranscriptMessage) {
        var next = messages; next[index] = row
        if !replaceMessages(next, at: [index]) { messages = next }
    }
    /// Messages this chat has sent that the helper has not shown yet. Each is
    /// drawn on Return, at the foot of the conversation, and the helper's own
    /// row for it — the same id, the submission's `clientTurnId` — takes its
    /// place when a snapshot brings it: the same row of the page, in the same
    /// place, never a second copy. Held in memory only; the durable record of
    /// a submission is its `CommandIntent`.
    @Published private(set) var sendingRows: [TranscriptMessage] = []
    func showSending(_ row: TranscriptMessage) {
        guard !sendingRows.contains(where: { $0.id == row.id }), !messages.contains(where: { $0.id == row.id }) else { return }
        sendingRows.append(row); publishTranscript()
    }
    func dropSending(_ id: String) {
        guard let index = sendingRows.firstIndex(where: { $0.id == id }) else { return }
        sendingRows.remove(at: index); publishTranscript()
    }
    func dropAllSending() {
        guard !sendingRows.isEmpty else { return }
        sendingRows = []; publishTranscript()
    }
    func isSending(_ turnID: String?) -> Bool { turnID.map { id in sendingRows.contains { $0.id == id } } ?? false }
    /// A sent message whose row the helper has now shown stops being drawn
    /// by the app: from here on the helper's row is the message.
    private func adoptDeliveredSending() {
        guard !sendingRows.isEmpty else { return }
        let shown = sendingRows.filter { row in messages.reversed().contains { $0.id == row.id } }
        if !shown.isEmpty { sendingRows.removeAll { row in shown.contains { $0.id == row.id } } }
    }
    /// Sent messages the helper has taken somewhere other than the
    /// conversation: a delivery it refused or a removal (the receipts), or a
    /// paused queue that holds it once nothing is running any more. The queue
    /// panel shows those; the transcript stops drawing them.
    @discardableResult func settleSending(receipts: [[String: WireValue]], queued: Set<String>) -> Bool {
        guard !sendingRows.isEmpty else { return false }
        let settled = sendingRows.filter { row in
            let receipt = receipts.last { $0["turnId"]?.string == row.id }?["state"]?.string ?? ""
            // Only a paused queue holds it: an idle helper that has queued a
            // message it has not dispatched yet is about to run it, and taking
            // the row out for that one snapshot made it vanish and come back.
            return ["failed", "cancelled", "removed"].contains(receipt) || (!loading && !busy && (queuePaused || queueEditHold != nil) && queued.contains(row.id))
        }
        guard !settled.isEmpty else { return false }
        sendingRows.removeAll { row in settled.contains { $0.id == row.id } }
        publishTranscript()
        return true
    }
    /// The helper's queue as the panel shows it: a message drawn on Return
    /// shows once, in the transcript, not also in the panel while the helper
    /// picks it up.
    func panelQueue(_ helperQueue: [[String: WireValue]]) -> [[String: WireValue]] {
        sendingRows.isEmpty ? helperQueue : helperQueue.filter { !isSending($0["turnId"]?.string) }
    }
    /// What the conversation page shows: the messages, then the messages sent
    /// that the helper has not shown yet, then a retry notice while the helper
    /// retries a failed request, then the run failure or the last send failure
    /// where the conversation stopped. Errors live in the flow of the chat,
    /// not in a strip pinned above it.
    var presentedMessages: [TranscriptMessage] {
        let context = TranscriptMessageProjection.Context(self)
        if messageProjection.context != context { messageProjection.invalidate() }
        if let rows = messageProjection.rows { return rows }
        let rows = makePresentedMessages()
        messageProjection.install(rows, context: context, sources: messagePositions)
        return rows
    }
    private func makePresentedMessages() -> [TranscriptMessage] {
        if historyState == .loading && !refreshingCachedRows { return [] }
        // An earlier version of an edited message, read-only, in place of the
        // latest one and everything after it.
        if let version = versionView {
            let latest = Self.hidingBranchMarkers(messages)
            if let at = latest.firstIndex(where: { $0.id == version.latestID }) { return (Array(latest[..<at]) + version.presented).map(presentAgentState) }
        }
        var rows = Self.hidingBranchMarkers(messages).map(presentAgentState)
        if isManagedSubagent, messages.isEmpty, let delegatedTask, !delegatedTask.isEmpty {
            rows.append(parentAuthoredTask(TranscriptMessage(id: "subagent-task:" + id, role: "user", text: delegatedTask)))
        }
        if isManagedSubagent, let index = rows.firstIndex(where: { $0.role == "user" && $0.nativeInherited == nil }), rows[index].nativeAgentDelivery == nil {
            rows[index] = parentAuthoredTask(rows[index])
        }
        if supportsCodexAgents, let first = rows.first, first.nativeInherited != nil {
            let count = rows.prefix { $0.nativeInherited != nil }.count
            let known = (historyPositions.position(of: first.id) ?? 0) + count
            if count < rows.count { inheritedContextMessages = known }
            rows[0].inheritedCount = first.inheritedCount ?? inheritedContextMessages ?? known
        }
        if familyWaiting && busy { rows.append(TranscriptMessage(id: "family-wait:" + id, role: "system", text: "Waiting for sub-agents", kind: "notice")) }
        else if agentInboxPending > 0 && !busy { rows.append(TranscriptMessage(id: "family-pending:" + id, role: "system", text: "Pending for parent Resume · \(agentInboxPending) agent message\(agentInboxPending == 1 ? "" : "s")", kind: "notice")) }
        for row in sendingRows where !messages.reversed().contains(where: { $0.id == row.id }) { rows.append(row) }
        if let retryNotice { rows.append(TranscriptMessage(id: "notice:retry:" + id, role: "system", text: retryNotice, kind: "notice")) }
        if let failureMessage {
            let paused = queuePaused && !queue.isEmpty
            var row = TranscriptMessage(id: "failure:run:" + id, role: "system", text: failureMessage, kind: "failure",
                                        detail: paused ? "Queued follow-ups are paused. Resume when you’re ready." : nil)
            if failureCode == "coordination_limit" {
                row.failureCode = resuming ? Self.pausedResumingCode : "coordination_limit"
                row.detail = "Accepted messages are saved. Resume opens a new coordination allowance; completed work is not replayed."
            }
            if failureCode == Self.skillUpdatedCode {
                // The queued message's skill was pinned to its current
                // version: the notice says so and offers the run's Resume,
                // which sends it (going on first with a run it stopped). The
                // helper (and a journal read) report this code only while
                // that message waits, so it is not checked against the queue
                // shown here, which can trail the snapshot by a moment. Its
                // button goes while a Resume is on its way.
                row.failureCode = resuming ? Self.skillResumingCode : Self.skillUpdatedCode; row.detail = nil
            }
            if failureCode == Self.costLimitCode {
                // The run stopped at the chat's cost limit: the notice offers to
                // raise it, and once it is above the spend, to continue.
                row.failureCode = costLimitHeld ? Self.costLimitCode : Self.costLimitRaised
                row.detail = costLimitHeld
                    ? [paused ? "Queued follow-ups stay paused." : nil, footer.cost.unreportedNote.map { $0 + ", so the spend may be higher." }].compactMap { $0 }.joined(separator: " ").nilIfEmpty
                    : (footer.cost.limit.usd == nil ? "This chat has no limit now." : "The limit is now \(footer.cost.limit.label).")
                        + " Continue picks up where the run stopped" + (paused ? "; queued follow-ups go on after it." : ".")
            }
            // A run cut off by a restart, read from the journal before its
            // helper has the chat: Resume goes on with it.
            if runState == .interrupted && failureCode == nil && continuable != false {
                // Its button goes while a Resume is on its way: no Retry in its place.
                row.failureCode = resuming ? Self.resumingCode : Self.interruptedCode; row.detail = Self.resumeDetail(paused)
            }
            rows.append(row)
        } else if costPaused && !busy && !loading {
            rows.append(costPausedRow)
        } else if showsPausedRun {
            // Stopped, or paused by a quit or an update: one row says so
            // where the run stopped, with Resume.
            var row = TranscriptMessage(id: "paused:run:" + id, role: "system", text: Self.pausedText, kind: "failure",
                                        detail: Self.resumeDetail(queuePaused && !queue.isEmpty))
            row.failureCode = resuming ? Self.pausedResumingCode : Self.pausedCode
            rows.append(row)
        }
        // A skill refreshed after a refused send shows even below a run
        // failure, so the Send that confirms it never goes unexplained.
        if let sendFailure, failureMessage == nil || sendFailureCode == Self.skillRefreshedCode {
            var row = TranscriptMessage(id: "failure:send:" + id, role: "system", text: sendFailure, kind: "failure")
            if sendFailureCode == Self.costLimitCode {
                row.failureCode = Self.costLimitCode
                row.detail = "Your message is back in the composer. Raise the limit, then send it again."
            }
            // A skill that changed since it was chosen: its chip holds the
            // current version now, and the next Send uses it.
            if sendFailureCode == Self.skillRefreshedCode { row.failureCode = Self.skillRefreshedCode }
            rows.append(row)
        }
        return rows
    }
    /// The helper's code for a run stopped, or a message refused, at the
    /// chat's cost limit; and the notice's state once the limit is raised.
    nonisolated static let costLimitCode = "cost_limit", costLimitRaised = "cost_limit_raised"
    /// The family's pause at its shared limit: held (Raise limit…), raised
    /// (Resume), a Resume on its way, and a sub-agent's (no action of its own).
    nonisolated static let costPausedCode = "cost_paused", costPausedRaisedCode = "cost_paused_raised",
                           costPausedResumingCode = "cost_paused_resuming", costPausedChildCode = "cost_paused_child",
                           costPausedEditingCode = "cost_paused_editing"
    /// The pause's card, with the live spend and the limit it waits under.
    var costPausedRow: TranscriptMessage {
        let reading = footer.cost, spent = reading.budgetOwnerID == nil ? reading.spentUSD : reading.budgetSpentUSD
        let shared = reading.budgetOwnerID != nil || isManagedSubagent
        let limit = reading.limit.usd.map(CostLimit.dollars), owner = shared ? "the main chat’s " : "the "
        // The card's title says it is paused; its text gives the figures.
        var text = spent.map { amount in compactGatewayUSD(amount) + (limit.map { " spent of " + owner + $0 + " limit." } ?? " spent; there is no limit now.") }
            ?? limit.map { "The " + (shared ? "main chat’s " : "") + "limit is " + $0 + "." } ?? "There is no limit now."
        if isManagedSubagent { text += " This sub-agent goes on when the main chat resumes." }
        var row = TranscriptMessage(id: "paused:run:" + id, role: "system", text: text, kind: "failure")
        let queued = queuePaused && !queue.isEmpty
        if isManagedSubagent { row.failureCode = Self.costPausedChildCode }
        else if resuming { row.failureCode = Self.costPausedResumingCode }
        else if (queueEditHold != nil || continuable == false) && !(costLimitHeld && spent != nil) {
            // Resume waits as `showsPausedRun` does: a queued message's edit
            // holds the chat until it is finished or cancelled.
            row.failureCode = Self.costPausedEditingCode
            row.detail = "Finish or cancel the message edit, then choose Resume."
        } else if spent == nil {
            // Before the helper reads the spend (a chat read from its journal):
            // Resume is offered, and the helper refuses it at the limit.
            row.failureCode = Self.costPausedRaisedCode
            row.detail = "Resume goes on from where the work stopped, with any paused sides and sub-agents, once the limit is above the spend."
        } else if costLimitHeld {
            row.failureCode = Self.costPausedCode
            row.detail = [(shared ? "Raise the main chat’s limit above the spend." : "Raise the limit above the spend.") + " Nothing resumes until you choose Resume.",
                          reading.unreportedNote.map { $0 + ", so the spend may be higher." }].compactMap { $0 }.joined(separator: " ")
        } else {
            row.failureCode = Self.costPausedRaisedCode
            row.detail = (reading.limit.usd == nil ? "There is no limit now." : "The limit is now \(reading.limit.label).")
                + " Resume goes on from where the work stopped, with any paused sides and sub-agents" + (queued ? "; queued messages go after it." : ".")
        }
        return row
    }
    /// The row of a run stopped before it finished, which offers Resume; and
    /// the failure row's code for a run a restart cut off, which offers it too.
    nonisolated static let pausedCode = "run_paused", interruptedCode = "run_interrupted"
    /// The same two rows while their Resume is on its way: no button.
    nonisolated static let pausedResumingCode = "run_paused_resuming", resumingCode = "run_interrupted_resuming"
    nonisolated static let pausedText = "The run stopped before it finished. Resume picks up from here; a tool call that was cut off is not run again, and the model sees how it ended."
    nonisolated static func resumeDetail(_ queued: Bool) -> String? { queued ? "Queued follow-ups go on after it." : nil }
    /// A refused message's skills, read again and re-pinned in the composer
    /// (`refreshRefusedSkills`); and a paused queued message's, re-pinned by
    /// the helper (`skill_updated`), which the run's Resume sends; and that notice while its Resume is on its way.
    nonisolated static let skillRefreshedCode = "skill_refreshed", skillUpdatedCode = "skill_updated", skillResumingCode = "skill_updated_resuming"
    /// Whether the chat's reported spend is still at its limit, as the stop
    /// notice last read it: it offers Raise limit… until it is not.
    private(set) var costLimitHeld = true
    /// Takes the chat's cost reading: the footer's figures, and the stop
    /// notice's state.
    func applyCostReading(_ reading: SessionCostReading) {
        let changed = footer.cost != reading
        if changed { footer.cost = reading }
        let held = reading.held
        // The pause's card shows the figures themselves: it follows them.
        if held != costLimitHeld {
            costLimitHeld = held
            if failureCode == Self.costLimitCode || costPaused { publishTranscript() }
        } else if changed && costPaused { publishTranscript() }
        if changed, costPaused, !preflightNotice.isEmpty { updateComposedNotice() }
    }
    /// The owner changed the limit this chat runs under. A message refused
    /// at the old one is a draft to send again, so its notice goes: sent
    /// under a limit still too low, the helper refuses it with the new figures.
    func costLimitChanged() {
        if sendFailureCode == Self.costLimitCode { sendFailure = nil }
    }
    /// The limit carried by an open, or acknowledged by a configure.
    var costLimitSent: CostLimit?
    /// The marker an edit leaves is drawn by the edited message's version
    /// switcher instead, once the helper numbers its versions. A marker
    /// with no numbered message after it (an older helper, or an edit not
    /// delivered yet) still shows.
    nonisolated static func hidingBranchMarkers(_ rows: [TranscriptMessage]) -> [TranscriptMessage] {
        guard rows.contains(where: { $0.kind == "branch" }) else { return rows }
        var kept: [TranscriptMessage] = []
        kept.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            if row.kind == "branch", let next = rows[(index + 1)...].first(where: { $0.kind != "branch" }), next.role == "user", next.versions != nil { continue }
            kept.append(row)
        }
        return kept
    }
    /// An earlier version of an edited message shown in place of the latest,
    /// read-only; nil shows the latest. The composer and the model's context
    /// always stay on the latest version.
    @Published var versionView: TranscriptVersionView? { didSet { if versionView != oldValue { publishTranscript() } } }
    /// The edited message ⌥← and ⌥→ act on: the one whose switcher was used last.
    var versionFocus: String?
    /// The read of the version on screen.
    var versionLoad: Task<Void, Never>?
    func publishTranscript(invalidateProjection: Bool = true) {
        if invalidateProjection { messageProjection.invalidate() }
        guard transcriptBatchDepth == 0 else { return }
        let rows = presentedMessages
        var lifecycle = taskPresentation
        // The turn cards of an earlier version read its own tasks.
        if let version = versionView, !version.tasks.isEmpty, var merged = lifecycle {
            let held = Set(merged.recent.map(\.key))
            merged.recent += version.tasks.filter { !held.contains($0.key) }
            lifecycle = merged
        }
        let changes = messageProjection.changes
        let previous = presentationChanges.value
        let changed = changes.indices(since: previous.changes).map { !$0.isEmpty }
            ?? changes.tailStart(since: previous.changes).map { _ in true } ?? (previous.messages != rows)
        let input = TranscriptPresentationInput(messages: rows, lifecycle: lifecycle, changes: changes)
        if changed || previous.lifecycle != lifecycle { presentationChanges.send(input) }
        if changed { transcriptChanges.send(rows) }
    }
    /// "Retrying (attempt 2 of 6) after: …" while the helper waits to retry a transient failure.
    @Published var retryNotice: String? { didSet { if retryNotice != oldValue { publishTranscript() } } }
    private(set) var retryAttempt: Int? { didSet { if retryAttempt != oldValue { activityChanges.send() } } }
    private(set) var retryLimit: Int? { didSet { if retryLimit != oldValue { activityChanges.send() } } }
    /// A submission the host or app refused; cleared by the next send.
    @Published var sendFailure: String? { didSet { if sendFailure == nil { sendFailureCode = nil }; if sendFailure != oldValue { publishTranscript() } } }
    /// The helper's code for the refusal shown; `cost_limit` draws the cost-limit notice.
    var sendFailureCode: String? { didSet { if sendFailureCode != oldValue { publishTranscript() } } }
    /// The pins (`WorkspaceModel.skillPin`) this composer's chips were given
    /// after a refused send, by skill id, so a chip refused again once
    /// re-pinned reads as a skill that keeps changing. Cleared once the
    /// helper takes a message.
    var skillRepins: [String: String] = [:]
    func observeRetry(_ snapshot: [String: WireValue]) {
        let retry = snapshot["retry"]?.object
        retryAttempt = nil; retryLimit = nil
        let notice: String? = retry.flatMap { value in
            guard let rawAttempt = value["attempt"]?.number, let rawOf = value["of"]?.number,
                  let attempt = Int(exactly: rawAttempt), let of = Int(exactly: rawOf), attempt > 0, of >= attempt else { return nil }
            retryAttempt = attempt; retryLimit = of
            let reason = value["reason"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "Retrying (attempt \(attempt) of \(of))" + (reason.isEmpty ? "…" : " after: " + reason)
        }
        if retryNotice != notice { retryNotice = notice }
    }
    let composerDraft = ComposerDraft()
    /// What the reader opened or closed in this conversation's transcript.
    let disclosure = TranscriptDisclosure()
    /// Tool-call arguments this conversation has fetched in full, for cards
    /// whose inline document the host had to cut.
    let toolInputs = TranscriptToolInputs()
    var draft: String { get { composerDraft.text } set { if composerDraft.text != newValue { composerDraft.text = newValue } } }
    @Published var attachments: [AttachmentRecord] = []
    /// Imports register before conversion or inspection yields. Send is
    /// disabled until all finish; completing an import never submits.
    @Published var imageImports = 0
    @Published var skills: [SkillChip] = []
    @Published var directCommand = false
    @Published var completionVisible = false
    @Published var completionSelectionID: String?
    @Published var skillCatalog = SkillCatalog()
    var completionToken: SlashCompletionToken?
    var composerLocation: ComposerLocation?
    weak var composerEditor: ComposerTextView?
    var completionParse: Task<Void, Never>?
    /// What `SlashCompletionToken.outsideCode` said about the draft `text`
    /// before the slash at `offset`. The answer depends on that prefix alone,
    /// so it stands for every later edit that leaves the prefix unchanged.
    var codeClassification: (generation: UUID, revision: UInt64, offset: Int, text: String, outside: Bool)?
    @Published var state = "idle" { didSet { if state != oldValue { activityChanges.send() } } }
    /// `state` as a `RunState`, to read and to write.
    var runState: RunState { get { RunState(rawValue: state) } set { state = newValue.rawValue } }
    @Published var runStatus = "idle" { didSet { if runStatus != oldValue { activityChanges.send() } } }
    /// Bumped when the pane should move keyboard focus into the composer.
    @Published var composerFocusRequest = 0
    /// Requests up to this one are not for a composer made from now on, which
    /// otherwise acts on the last one it finds, even an earlier visit's
    /// (`NativeComposer.settledFocusToken`). Set as a chat opens for its side
    /// to take the cursor, and as a side comes back beside its chat.
    var composerFocusSettled = 0
    @Published var failureMessage: String? { didSet { if failureMessage != oldValue { publishTranscript() } } }
    /// The helper's code for the run failure shown; `cost_limit` draws the stop notice.
    @Published var failureCode: String? { didSet { if failureCode != oldValue { publishTranscript() } } }
    @Published var queuePaused = false { didSet { if queuePaused != oldValue { publishTranscript() } } }
    /// Work here stopped at the family's shared cost limit and waits for
    /// Resume (the helper's `costPaused`). Raising the limit resumes nothing.
    @Published var costPaused = false { didSet { if costPaused != oldValue { publishTranscript(); activityChanges.send() } } }
    /// The chat's journal ends in a record cut off mid-write: its complete
    /// records are shown read-only and Recover Copy is offered instead of the composer.
    @Published var damagedTail = false
    var canResumeQueue: Bool { !isManagedSubagent && !busy && (!queue.isEmpty || queuePaused || runState.holdsQueue) }
    /// Whether the helper would run the model on Resume (`run.continue`): the
    /// chat's context ends with something the model has not answered — a user
    /// message, or tool results a stop cut off. Nil until a snapshot says
    /// (a chat read only from its journal, or whose helper stopped for an
    /// update): Resume is offered, and the helper decides.
    @Published var continuable: Bool? { didSet { if continuable != oldValue { publishTranscript() } } }
    /// A Resume of this chat is on its way to the helper: the row's Resume and
    /// the menu's are off until it is answered, so a double click sends one.
    @Published var resuming = false { didSet { if resuming != oldValue {
        publishTranscript()
        if costPaused, !preflightNotice.isEmpty { updateComposedNotice() }
    } } }
    /// The chat's run stopped before it finished (Stop, a quit, a restart or
    /// an update paused it) and Resume would go on with it.
    /// A family paused at its limit offers it only once the limit is raised.
    var offersResume: Bool { !isManagedSubagent && showsPausedRun && !resuming && !(costPaused && costPausedAtLimit) }
    /// The family's spend is known to be at its limit: Raise limit…, not Resume.
    var costPausedAtLimit: Bool { costLimitHeld && (footer.cost.budgetOwnerID == nil ? footer.cost.spentUSD : footer.cost.budgetSpentUSD) != nil }
    /// The Paused row is drawn: while a Resume is on its way it stays, without its button.
    var showsPausedRun: Bool { !busy && !loading && runState.holdsQueue && continuable != false && queueEditHold == nil }
    func observeRunState(_ snapshot: [String: WireValue]) {
        beginTranscriptBatch(); defer {
            endTranscriptBatch()
            if costPaused, !preflightNotice.isEmpty { updateComposedNotice() }
        }
        let waiting = snapshot["familyWaiting"]?.bool ?? false
        if familyWaiting != waiting { familyWaiting = waiting }
        let pending = snapshot["agentInboxPending"]?.nonnegativeInteger ?? 0
        if agentInboxPending != pending { agentInboxPending = pending }
        let childTurn = snapshot["subagentTurn"]?.nonnegativeInteger
        if subagentTurn != childTurn { subagentTurn = childTurn }
        let rawState = snapshot["state"]?.string ?? "idle", run = snapshot["runStatus"]?.string ?? rawState
        // Older helpers reported failed runs as paused. Keep the run's outcome
        // separate from whether its remaining follow-ups require Resume.
        let nextState = run == "failed" && !RunState(rawValue: rawState).isBusy ? RunState.error.rawValue : rawState
        if state != nextState { state = nextState }
        if runStatus != run { runStatus = run }
        let paused = snapshot["queuePaused"]?.bool ?? RunState(rawValue: rawState).holdsQueue
        if queuePaused != paused { queuePaused = paused }
        // A helper before 0.1.125 does not say; Resume then stays offered.
        let continues = snapshot["continuable"]?.bool
        if continuable != continues { continuable = continues }
        let pausedAtLimit = snapshot["costPaused"]?.bool ?? false
        costPausePreflight = pausedAtLimit && snapshot["errorCode"]?.string == Self.costLimitCode
        if costPaused != pausedAtLimit { costPaused = pausedAtLimit }
        let detail = snapshot["preflightError"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let failure = RunState(rawValue: nextState) == .error ? (detail?.isEmpty == false ? detail : "Run failed.") : nil
        let code = failure == nil ? nil : snapshot["errorCode"]?.string
        // Both change before the notice is drawn again, so it never shows one failure's words with another's actions.
        if failureMessage != failure || failureCode != code {
            beginTranscriptBatch(); defer { endTranscriptBatch() }
            // The helper just said the chat is at its limit: the notice reads
            // so until a reading of the spend says otherwise.
            if code == Self.costLimitCode, failureCode != code { costLimitHeld = true }
            if failureCode != code { failureCode = code }
            if failureMessage != failure { failureMessage = failure }
        }
    }
    /// A run whose helper disappeared leaves half-streamed rows behind that
    /// nothing will ever finish. They must stop presenting themselves as a live
    /// turn, or the bar above the composer keeps a spinner, a running clock and
    /// a Stop button for a run that is over.
    func settleInterruptedRows() {
        beginTranscriptBatch(); defer { endTranscriptBatch() }
        if var lifecycle = taskPresentation {
            lifecycle.utilityPhase = nil
            if var active = lifecycle.active {
                active.outcome = "interrupted"; active.phase = "terminal"; active.endedAt = active.startedAt
                active.endedAtUnixMs = nil
                active.detail = "Connection ended without a terminal receipt. Inspect tool effects before continuing."
                active.lastSourceID = messages.last(where: { $0.taskExecutionID == active.executionID })?.id ?? active.lastSourceID ?? active.anchorSourceID
                lifecycle.active = nil; lifecycle.recent.append(active)
                lifecycle.recent = Array(lifecycle.recent.suffix(64))
            }
            taskPresentation = lifecycle
        }
        guard messages.contains(where: \.isStreaming) else { return }
        var rows = messages
        for index in rows.indices where rows[index].isStreaming {
            rows[index].state = "aborted"
        }
        messages = rows
    }
    func observeRetainedFailure(_ message: String?, code: String? = nil) {
        guard !busy, !loading else { return }
        if let message {
            // The code goes first, so the notice is drawn once, with its
            // action. A source that names no code (a helper's page) leaves
            // the code already known for the same failure.
            if failureCode != code, code != nil || failureMessage != message { failureCode = code }
            runState = .error; runStatus = "failed"; failureMessage = message
        } else if runState == .error {
            runState = .idle; runStatus = "idle"; failureMessage = nil; failureCode = nil
        }
    }
    /// What a running compaction is doing, for the run line under the
    /// composer. A finished compaction shows as its row in the transcript.
    @Published var compactionProgress: String?
    func observeCompaction(_ snapshot: [String: WireValue]) {
        let operation=snapshot["compaction"]?.object
        // A compaction is one summary request, retried as any request is.
        let progress: String?
        switch operation?["phase"]?.string {
        case "summarizing": progress="Summarizing earlier work"
        case "retrying": progress="Retrying summary request"
        case "planning": progress="Preparing complete tool history"
        default: progress=nil
        }
        // Published on the whole display: written only when it changes, not
        // once per snapshot for as long as a compaction runs.
        if compactionProgress != progress { compactionProgress=progress }
    }
    var activity: [String: WireValue] = [:] { didSet { if activity != oldValue { activityChanges.send() } } }
    var activityObservedAt: Double = 0
    @Published var queue: [[String: WireValue]] = [] {
        // A message the helper holds for its edit can't be sent; a row gone
        // from a snapshot (a lost helper, a restart) doesn't end the edit,
        // which only the helper's answer to Save or Cancel does.
        didSet { if let editing = queueEditingID, queueEditID == nil, !queue.contains(where: { $0["turnId"]?.string == editing }) { queueEditLeft() } }
    }
    /// The queued message being rewritten in this chat's composer. It belongs
    /// to the chat, not to the queue panel, which is rebuilt for each chat and
    /// leaves the page when the queue empties.
    @Published var queueEditingID: String?
    /// The helper's identity for that edit: while it is open the helper
    /// holds every pending message in the chat (handoff D2).
    var queueEditID: String?
    /// A Save or Cancel sent and not yet answered: the editor stays, and
    /// another press does nothing until the helper says how it ended.
    @Published var queueEditResolving = false
    /// Kept separately from streaming/tool status until the next explicit
    /// edit action or submission. A refresh must not hide why Save failed.
    @Published var queueEditNotice = "" {
        didSet { if queueEditNotice != oldValue { updateComposedNotice() } }
    }
    private var costPausePreflight = false
    /// The preflight explanation last shown below the composer. A run
    /// failure already shown in the transcript does not contribute a part.
    var preflightNotice = "" {
        didSet { if preflightNotice != oldValue { updateComposedNotice() } }
    }
    /// Keep the rendered value cached, but derive it only from its parts.
    /// Clearing either part must work without another helper snapshot.
    func updateComposedNotice() {
        let preflight = costPaused && costPausePreflight && !costLimitHeld && !preflightNotice.isEmpty ? raisedCostPauseNotice : preflightNotice
        let composed = [queueEditNotice, preflight].filter { !$0.isEmpty }.joined(separator: "\n")
        if notice != composed { notice = composed }
    }
    /// The helper retains the pause-time figures until Resume. The composer,
    /// like the card, follows the chat's live limit and the shared spend.
    private var raisedCostPauseNotice: String {
        let reading = footer.cost, shared = reading.budgetOwnerID != nil || isManagedSubagent
        let limit = reading.limit.usd == nil ? "There is no limit now." : "The \(shared ? "main chat’s " : "")limit is now \(reading.limit.label)."
        if isManagedSubagent { return limit + " This sub-agent goes on when the main chat resumes." }
        if resuming { return limit + " Resuming…" }
        if queueEditHold != nil || continuable == false { return limit + " Finish or cancel the message edit, then choose Resume." }
        return limit + " Choose Resume to continue."
    }
    /// The message being rewritten keeps images in the helper, so its text may be empty.
    var queueEditKeepsInput = false
    var queueEditOriginalSkills: [SkillChip]?
    /// A Save, Cancel or Remove sent and not answered, and the text a Save
    /// sent: kept in the saved draft until the helper's answer is known.
    var queueEditPendingOperation: String?
    var queueEditSentDigest: String?
    /// An edit being cancelled by its identity (one this composer doesn't
    /// hold): it can't be resumed until that Cancel is settled.
    @Published var queueEditCancelling: String?
    /// A Begin sent and not yet answered, by its edit identity.
    var queueEditBeginning: String?
    /// The helper's hold on this chat's pending input, as its snapshots
    /// report it, newest revision first: shown in every view of the chat,
    /// also one this composer does not own (after a restart, say).
    @Published var queueEditHold: QueueEditHold?
    /// The queue panel shows only its header. Presentation only: the queue
    /// goes on, or waits, exactly as it would.
    @Published var queueCollapsed = false
    /// The waiting message whose detail is open, and what that detail shows.
    @Published var queueDetailID: String? { didSet { if queueDetailID == nil { queueDetailShowing = nil } } }
    var queueDetailShowing: String?
    var queueEditHoldRevision = -1
    var queuePresentedEditRevision = -1
    /// A rewrite saved with the draft whose edit has not been reconciled
    /// with the helper yet; kept in the saved draft until it is.
    var unreconciledQueuedEdit: QueuedEditDraft?
    func observeQueueEdit(_ snapshot: [String: WireValue]) {
        guard let revision = snapshot["queueEditRevision"]?.number.map(Int.init) else { return }
        adoptQueueEditHold(QueueEditHold(snapshot["queueEdit"]?.object), revision: revision)
    }
    /// A report of the hold older than one already taken is ignored, so a
    /// snapshot read before a Save's answer can't bring the hold back.
    @discardableResult func adoptQueueEditHold(_ hold: QueueEditHold?, revision: Int) -> Bool {
        guard revision >= queueEditHoldRevision else { return false }
        queueEditHoldRevision = revision
        if queueEditHold != hold { queueEditHold = hold }
        return true
    }
    /// The queued message's text as it was when the composer took it.
    var queueEditOriginal = ""
    /// The composer's draft, set aside while it holds the queued message: it
    /// comes back when the rewrite is saved or cancelled, and it is the draft
    /// saved for the chat meanwhile.
    var draftBeforeQueueEdit: DraftRecord?
    /// The queued message whose whole text is being read before the composer
    /// takes it, and which read that is.
    @Published var queueEditPreparing: String?
    var queueEditRead = UUID()
    /// The queued message being rewritten left the queue (it was sent, or
    /// the helper stopped). An untouched rewrite gives back the set-aside
    /// draft; a changed one stays, ahead of that draft, so nothing typed is lost.
    private func queueEditLeft() {
        let before = draftBeforeQueueEdit ?? DraftRecord(id: id, text: "")
        let rewrite = draft, trimmed = rewrite.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = !trimmed.isEmpty && trimmed != queueEditOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        queueEditingID = nil; queueEditOriginal = ""; draftBeforeQueueEdit = nil
        restoreDraft(before)
        guard changed else { return }
        draft = before.text.isEmpty ? rewrite : rewrite + "\n\n" + before.text
        notice = "That queued message left the queue before your rewrite was saved. The rewrite is in the composer."
    }
    var queueCount = 0 { didSet { if queueCount != oldValue { activityChanges.send() } } }
    @Published var notice = ""
    @Published var before: String?
    @Published var hostBefore: Double?
    var loadingEarlier = false
    @Published var loading = false { didSet { if loading != oldValue { activityChanges.send() } } }
    /// The rows holding the reader's cursor or selection, which the resident
    /// window does not let go of. A change is announced (`heldChanges`), so a
    /// window they stretched goes back to its budget once let go of.
    var pinnedHistoryIDs: Set<String> = [] { didSet { if pinnedHistoryIDs != oldValue { heldChanges.send() } } }
    let heldChanges = PassthroughSubject<Void, Never>()
    var scrollAnchor: TranscriptAnchor?
    var anchorVersion = AnchorVersion()
    var anchorWrite: Task<Void, Never>?
    var anchorWriteToken: UUID?
    @Published var viewportRequest = 0
    /// Whether the newest `viewportRequest` opens the chat — its first page
    /// read in, or its rows shown again on a revisit — rather than taking
    /// the reader somewhere they asked to go. An opening starts where any
    /// chat the reader opens starts (at the question of its last turn, when
    /// that turn is taller than the pane); a jump lands where it was asked
    /// to. Every site that asks sets it, just before asking.
    var viewportRequestOpens = false
    let footer = SessionMetrics()
    var context: [String: WireValue] { get { footer.context } set { footer.context = newValue } }
    func observeContext(_ snapshot: [String: WireValue], baseline: Bool = false) {
        if baseline {
            footer.preparedContext=nil; footer.context=[:]; footer.contextState=[:]
            footer.requestObservation=[:]; footer.lastRequestObservation=[:]
            footer.contextObservationRevision=nil; footer.contextStateRevision=nil
            // A chat opened again, or on a new helper, is sent its receipts and
            // tasks whole: nothing held here describes that helper's state.
            commandsRevision=nil; taskPresentationRevision=nil
        }
        if let revision=snapshot["contextStateRevision"]?.string, let payload=snapshot["contextState"] {
            if var state=payload.object, state["version"]?.number == 1,
               state["sessionID"]?.string == id, let incoming=ContextInputIdentity(state),
               let generation=state["generation"]?.number, generation.isFinite, generation >= 0, generation.rounded() == generation {
                if let held=footer.contextInputIdentity {
                    guard incoming.epoch == held.epoch, incoming.revision >= held.revision,
                          generation >= (footer.contextState["generation"]?.number ?? -1) else { return }
                    if incoming == held, generation == footer.contextState["generation"]?.number {
                        for key in ["currentRequest","lastRequest","count"] where state[key] == nil { state[key]=footer.contextState[key] }
                    }
                }
                if incoming != footer.contextInputIdentity { footer.preparedContext=nil }
                footer.contextStateRevision=revision
                if footer.contextState != state { footer.contextState=state }
                if let supplied=state["count"], supplied.object ?? [:] != footer.context { footer.context=supplied.object ?? [:] }
                for (key,current) in [("currentRequest",true),("lastRequest",false)] {
                    if let supplied=state[key] {
                        let value=supplied.object ?? [:]
                        if current, footer.requestObservation != value { footer.requestObservation=value }
                        if !current, footer.lastRequestObservation != value { footer.lastRequestObservation=value }
                    }
                }
                if let pending=footer.pendingContextSubmission, state["turnID"]?.string == pending || (footer.contextSubmissionAcknowledged && !busy) {
                    footer.pendingContextSubmission=nil
                }
            }
            // A reset must carry a versioned epoch/revision envelope with a
            // null currentRequest. An unkeyed null cannot retire live state.
        }
        if let revision=snapshot["contextObservationRevision"]?.string, revision != footer.contextObservationRevision {
            footer.contextObservationRevision=revision
            if footer.contextState.isEmpty {
                // An omitted field is unchanged; an explicit null is a reset.
                if let supplied=snapshot["requestObservation"] { footer.requestObservation=supplied.object ?? [:] }
                if let supplied=snapshot["lastRequestObservation"] { footer.lastRequestObservation=supplied.object ?? [:] }
            }
        }
        if footer.contextState.isEmpty, let supplied=snapshot["context"] {
            let context=supplied.object ?? [:]
            if context != self.context { self.context=context }
        }
    }
    /// Only idle submissions establish a new request. Follow-ups/steering leave
    /// an already dispatched request and its capacity untouched.
    func beginContextSubmission(_ turnID: String) {
        guard !busy else { return }
        footer.pendingContextSubmission=turnID; footer.contextSubmissionAcknowledged=false
    }
    func acknowledgeContextSubmission(_ turnID: String) {
        guard footer.pendingContextSubmission == turnID else { return }
        footer.contextSubmissionAcknowledged=true
        if !busy { footer.pendingContextSubmission=nil }
    }
    func rejectContextSubmission(_ turnID: String) {
        if footer.pendingContextSubmission == turnID { footer.pendingContextSubmission=nil }
    }
    var metrics: [String: WireValue] { get { footer.metrics } set { footer.metrics = newValue } }
    var turnTiming: [String: WireValue] { get { footer.turnTiming } set { footer.turnTiming = newValue } }
    @Published var captureMode = "persist"
    @Published var captureAvailable = false
    @Published var recovered: [CommandIntent] = []
    /// Captured submissions belong to their task until it settles. Their
    /// durable/pinned records are crash recovery, never live recovery actions.
    @Published var submittingCommands: Set<String> = []
    var settlingSubmissions: [String: CommandIntent] = [:]
    var sideInputPendingTransfer = false
    var recoverableSubmissions: [CommandIntent] { recovered.filter { !submittingCommands.contains($0.id) } }
    /// Edit-and-resend: the user message whose text is loaded in the composer, and the draft it replaced.
    @Published var editingMessageID: String?
    var draftBeforeEdit: DraftRecord?
    var editGeneration = UUID()
    /// Which read of the edited message's original is current: Edit again on
    /// the same edit starts another read without making a new edit, so an
    /// image import into it keeps its place (`editGeneration` stays).
    var editPreparation = UUID()
    @Published var editPreparing = false
    @Published var editSubmitting = false
    @Published var editInputReviewRequired = false
    @Published var editMissingAttachments: Set<String> = []
    @Published var editNotice = ""
    /// The question in the composer came from its row on screen, and its
    /// complete original — its images and skills, what Send is checked
    /// against — is not read yet (`WorkspaceModel.editMessage`). Saved with
    /// the draft (`MessageEditDraft.inputPending`), so a restart reads it again.
    @Published var editInputPending = false
    var editSourceTimeline: String?
    var editSourceTextDigest: String?
    /// What Send checks the edit against: the conversation through the edited
    /// message, from the read of its original (`turn.edit`'s `editSourcePrefix`).
    var editSourcePrefix: String?
    /// The branch this reader's edit is making (`sendEdit`), until the
    /// snapshot that first carries it is adopted (`adoptOwnBranch`).
    var pendingBranch: PendingBranch?
    /// The one rule every send path shares (handoff A2): text, a skill or
    /// an image makes a message; a draft of none of them is empty. Whether
    /// the model takes images is checked where the message goes out.
    var hasSubmittableInput: Bool { draft.contains { !$0.isWhitespace } || !skills.isEmpty || !attachments.isEmpty }
    var submissionReviews: Set<String> = []
    var reconciledSubmissionReviews: Set<String> = []
    var savedDraft: DraftRecord {
        if queueEditingID != nil, var saved = draftBeforeQueueEdit {
            if let editID = queueEditID, let turnID = queueEditingID {
                var record = QueuedEditDraft(editID: editID, turnID: turnID, rewrite: draft, original: queueEditOriginal, pending: queueEditPendingOperation)
                record.sentDigest = queueEditSentDigest
                record.skills = skills; record.originalSkills = queueEditOriginalSkills
                saved.queuedEdit = record
            }
            return saved
        }
        if let unreconciledQueuedEdit {
            var saved = DraftRecord(id: id, text: draft, attachments: attachments, skills: skills, submissionReviews: submissionReviews.isEmpty ? nil : submissionReviews); saved.queuedEdit = unreconciledQueuedEdit
            return saved
        }
        let edit = editingMessageID.map { MessageEditDraft(messageID: $0, originalText: draftBeforeEdit?.text ?? "", originalAttachments: draftBeforeEdit?.attachments, originalSkills: draftBeforeEdit?.skills, sourceTimeline: editSourceTimeline, sourceTextDigest: editSourceTextDigest, inputReviewRequired: editInputReviewRequired, originalSubmissionReviews: draftBeforeEdit?.submissionReviews, inputPending: editInputPending ? true : nil, sourcePrefix: editSourcePrefix) }
        return DraftRecord(id: id, text: draft, attachments: attachments, skills: skills, edit: edit, submissionReviews: submissionReviews.isEmpty ? nil : submissionReviews)
    }
    func restoreDraft(_ saved: DraftRecord) {
        draft = saved.text; attachments = saved.attachments ?? []; skills = saved.skills ?? []; directCommand = false
        submissionReviews = saved.submissionReviews ?? []
        editingMessageID = saved.edit?.messageID
        editSourceTimeline = saved.edit?.sourceTimeline; editSourceTextDigest = saved.edit?.sourceTextDigest; editSourcePrefix = saved.edit?.sourcePrefix
        editInputReviewRequired = saved.edit?.inputReviewRequired ?? false; editInputPending = saved.edit?.inputPending == true
        editGeneration = UUID(); editPreparing = false; editSubmitting = false; editNotice = ""; editMissingAttachments = []
        draftBeforeEdit = saved.edit.map { DraftRecord(id: id, text: $0.originalText, attachments: $0.originalAttachments, skills: $0.originalSkills, submissionReviews: $0.originalSubmissionReviews) }
    }
    var displayObservedAt: Double?
    var projectionRevision: String?
    /// The helper's page exactly as it sent it, before paging merge and
    /// accounting. The next read is a list of changes to this, and the rows it
    /// does not change are reused by identity, so every later comparison of a
    /// settled row is a pointer check rather than a string compare.
    var projectedPage = TranscriptRowUpdates.Page([])
    var projectedRows: [TranscriptMessage] {
        get { projectedPage.rows }
        set { projectedPage = TranscriptRowUpdates.Page(newValue) }
    }
    var historyRevision: HistoryRevision?
    /// The rows of the page last read in, by count and ends: while the rows
    /// are still those, the page is what a fresh read of an unchanged journal
    /// returns. Paging in or out changes them.
    struct PageRows: Equatable { var count: Int; var first: String?; var last: String? }
    var adoptedPage: PageRows?
    var pageRows: PageRows { PageRows(count: messages.count, first: messages.first?.id, last: messages.last?.id) }
    /// Once hydrated, the live draft/anchor remain authoritative while their
    /// debounced writes catch up. A warm tab must not restore old saved text.
    var hasUnsavedDraft: Bool {
        draftWritePending || draftVersion.hasUnsavedConflict || !savedDraft.hasSameContents(as: draftVersion.snapshot.draft ?? DraftRecord(id: id, text: ""))
    }
    var draftVersion = DraftVersion() {
        didSet {
            pendingIntents = nil
            // Hydration and side transfer replace the composer baseline, not
            // independent input still awaiting its own durable record.
            for intent in oldValue.unsavedSubmissions { draftVersion.preservingSubmission(intent) }
        }
    }
    @Published var draftConflicts: [SavedDraftConflict] = []
    var selectionMetadataLoaded = false
    /// Edits admitted while the baseline is unread, including a cleared field
    /// or reading position. Hydration reschedules them against that baseline.
    var draftWritePending = false
    var anchorWritePending = false
    /// This window is detached from the helper's live tail (a newer gap,
    /// source load or explicit retained-message inspection). Earlier rows
    /// alone do not detach it or suppress live transcript updates.
    var browsingHistory = false
    var footerUpdatedAt = 0.0
    var accountingRevision = 0
    /// The presentation whose rows' cost and usage were read before they were
    /// shown (`withAccounting`): its refresh after it is ready reads only the
    /// chat's totals and timing.
    var accountingReadFor: UUID?
    var messageAccounting: [String: GatewayTotals] = [:]
    var lastSequence: Double = -1
    var snapshotEpoch: String?
    private var retiredSnapshotEpochs: Set<String> = []
    /// Follow-ups can replace a child's runtime under the same session ID.
    /// Sequence numbers and projection revisions belong to that runtime only.
    func adoptSnapshotEpoch(_ epoch: String?) -> Bool {
        guard let epoch else { return true }
        guard !retiredSnapshotEpochs.contains(epoch) else { return false }
        if let previous = snapshotEpoch, previous != epoch {
            retiredSnapshotEpochs.insert(previous)
            lastSequence = -1; projectionRevision = nil; projectedRows = []
            receipts = []; commandsRevision = nil
            taskPresentation = nil; taskPresentationDecoder = TaskPresentationDecoder()
            monitoringEpoch = nil; monitoringCursor = nil
            footer.contextStateRevision = nil; footer.contextObservationRevision = nil; footerUpdatedAt = 0
            queueEditHoldRevision = -1; queuePresentedEditRevision = -1
            presentation.cancel(); finishHistoryPresentation(presentation.readGeneration)
            presentation.readGeneration = UUID()
            olderPage.loading = false; newerPage.loading = false; loadingEarlier = false
        }
        snapshotEpoch = epoch
        return true
    }
    /// The finished tasks of the last task presentation, decoded once.
    var taskPresentationDecoder = TaskPresentationDecoder()
    /// The command receipts of the last snapshot that carried them, and the
    /// helper's revision of them. A snapshot that leaves them out had none
    /// that changed; pending submissions settle against these.
    var receipts: [[String: WireValue]] = []
    var commandsRevision: String?
    /// Test seams: whether the snapshot loop asks the helper to leave out
    /// the receipts and tasks this display holds unchanged, and to send tool
    /// arguments still streaming as appends. Off, every reply carries them
    /// whole, as before 0.1.85.
    var leavesOutHeldState = true
    var takesToolInputAppends = true
    /// Bumped by every write of this chat's pending submissions
    /// (`WorkspaceModel.pendingIntentsChanged`).
    var pendingIntentRevision = 0
    var pendingSubmissionRevision = -1
    var pendingExternalRevision: MetadataStore.ExternalRevision?
    /// What the snapshot loop last read of them, and at which revision.
    var pendingIntents: (revision: Int, intents: [CommandIntent])?
    /// A successful helper reply is enough to suppress draft recovery even
    /// if its local acknowledgement could not be written.
    var acceptedCommands: Set<String> = []
    // Test seams: what the snapshot loop did for this chat.
    /// Reads of this chat's pending submissions from the store.
    var intentReads = 0
    /// Full decodes of the task presentation's finished tasks.
    var taskPresentationDecodes: Int { taskPresentationDecoder.decodes }
    var snapshotInFlight = false
    var dirty = false
    var uncertain = false { didSet { if uncertain != oldValue { activityChanges.send() } } }
    /// Whether the run state here is the chat's own: a helper snapshot or its
    /// journal has been adopted. Until then a new display reads idle, and the
    /// chat's saved hold (`WorkspaceRunHolds.swift`) is what its row shows.
    var runStateKnown = false
    @Published var contextSelectionReady = false
    var used = Date()
    init(id: String) {
        self.id = id
    }
    var busy: Bool { runState.isBusy || familyWaiting && !queuePaused && !runState.holdsQueue && runState != .error }
    /// A Resume on its way counts from the press: the chat keeps its display
    /// and helper session while its continuation starts.
    var hasWork: Bool { busy || resuming || queueCount > 0 }
    /// Work that runs without the reader: a run, or follow-ups not held for Resume.
    /// A Resume on its way to the helper counts: an update must not stop
    /// the helper under it.
    var hasActiveWork: Bool { busy || resuming || (queueCount > 0 && !queuePaused) }
}

extension SessionDisplay {
    /// What the chat is doing, in the one vocabulary the menu bar, the live
    /// monitor and the activity graph share: "error", "paused", "stopping",
    /// "starting", "model", "tool", "compacting", "queued" or "idle".
    ///
    /// In the order the helper gives its own activity phase, a stopped run
    /// before a busy one: a failed run, then a run whose queue waits for
    /// Resume (paused or interrupted, or one whose last command's outcome is
    /// uncertain), then a stop not yet landed, then a message the app is
    /// still sending, then what the running turn reports it is doing.
    var activityPhase: String {
        if runState == .error { return "error" }
        if runState.holdsQueue || uncertain { return "paused" }
        if runState == .stopping { return "stopping" }
        if loading { return "starting" }
        if busy {
            let reported = activity["phase"]?.string ?? ""
            return ["starting", "model", "tool", "compacting", "queued"].contains(reported) ? reported : runState == .queued ? "queued" : "starting"
        }
        return "idle"
    }
}
