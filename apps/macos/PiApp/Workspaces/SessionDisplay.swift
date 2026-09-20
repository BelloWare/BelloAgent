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
    @Published var preparedContext: PreparedContextMetrics?
    @Published var preparingContext = false
    @Published var metrics: [String: WireValue] = [:]
    @Published var turnTiming: [String: WireValue] = [:]
    @Published var timing = SessionTimingHistory()
    @Published var gateway = GatewayTotals()
    @Published var gatewayNotice = ""
}
@MainActor final class ComposerDraft: ObservableObject { @Published var text = "" }

@MainActor final class SessionDisplay: ObservableObject {
    let id: String
    let transcriptChanges = CurrentValueSubject<[TranscriptMessage], Never>([])
    var messages: [TranscriptMessage] = [] { didSet { projectionRevision = nil; publishTranscript() } }
    /// What the conversation page shows: the messages, then a retry notice
    /// while the helper retries a failed request, then the run failure or the
    /// last send failure where the conversation stopped. Errors live in the
    /// flow of the chat, not in a strip pinned above it.
    var presentedMessages: [TranscriptMessage] {
        var rows = messages
        if let retryNotice { rows.append(TranscriptMessage(id: "notice:retry:" + id, role: "system", text: retryNotice, kind: "notice")) }
        if let failureMessage {
            rows.append(TranscriptMessage(id: "failure:run:" + id, role: "system", text: failureMessage, kind: "failure",
                                          detail: queuePaused && !queue.isEmpty ? "Queued follow-ups are paused. Resume when you’re ready." : nil))
        } else if let sendFailure {
            rows.append(TranscriptMessage(id: "failure:send:" + id, role: "system", text: sendFailure, kind: "failure"))
        }
        return rows
    }
    func publishTranscript() { transcriptChanges.send(presentedMessages) }
    /// "Retrying (attempt 2 of 3) after: …" while the helper waits to retry a transient failure.
    @Published var retryNotice: String? { didSet { if retryNotice != oldValue { publishTranscript() } } }
    /// A submission the host or app refused; cleared by the next send.
    @Published var sendFailure: String? { didSet { if sendFailure != oldValue { publishTranscript() } } }
    func observeRetry(_ snapshot: [String: WireValue]) {
        let retry = snapshot["retry"]?.object
        let notice: String? = retry.flatMap { value in
            guard let rawAttempt = value["attempt"]?.number, let rawOf = value["of"]?.number,
                  let attempt = Int(exactly: rawAttempt), let of = Int(exactly: rawOf), attempt > 0, of >= attempt else { return nil }
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
    @Published var skills: [SkillChip] = []
    @Published var directCommand = false
    @Published var completionVisible = false
    @Published var completionIndex = 0
    @Published var state = "idle"
    @Published var runStatus = "idle"
    /// Bumped when the pane should move keyboard focus into the composer.
    @Published var composerFocusRequest = 0
    @Published var failureMessage: String? { didSet { if failureMessage != oldValue { publishTranscript() } } }
    @Published var queuePaused = false { didSet { if queuePaused != oldValue { publishTranscript() } } }
    var canResumeQueue: Bool { !busy && (queuePaused || ["paused", "interrupted"].contains(state)) }
    func observeRunState(_ snapshot: [String: WireValue]) {
        let rawState = snapshot["state"]?.string ?? "idle", run = snapshot["runStatus"]?.string ?? rawState
        // Older helpers reported failed runs as paused. Keep the run's outcome
        // separate from whether its remaining follow-ups require Resume.
        let nextState = run == "failed" && !["queued", "running", "stopping", "compacting"].contains(rawState) ? "error" : rawState
        if state != nextState { state = nextState }
        if runStatus != run { runStatus = run }
        let paused = snapshot["queuePaused"]?.bool ?? ["paused", "interrupted"].contains(rawState)
        if queuePaused != paused { queuePaused = paused }
        let detail = snapshot["preflightError"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let failure = nextState == "error" ? (detail?.isEmpty == false ? detail : "Run failed.") : nil
        if failureMessage != failure { failureMessage = failure }
    }
    /// A run whose helper disappeared leaves half-streamed rows behind that
    /// nothing will ever finish. They must stop presenting themselves as a live
    /// turn, or the bar above the composer keeps a spinner, a running clock and
    /// a Stop button for a run that is over.
    func settleInterruptedRows() {
        guard messages.contains(where: \.isStreaming) else { return }
        var rows = messages
        for index in rows.indices where rows[index].isStreaming {
            rows[index].state = "aborted"
        }
        messages = rows
    }
    func observeRetainedFailure(_ message: String?) {
        guard !busy, !loading else { return }
        if let message {
            state = "error"; runStatus = "failed"; failureMessage = message
        } else if state == "error" {
            state = "idle"; runStatus = "idle"; failureMessage = nil
        }
    }
    /// Set when a compaction finishes; shown above the composer until the next send or dismissal.
    @Published var compactionNotice: String?
    private var compactionBaselineLoaded = false
    private var observedCompactionID: String?
    /// Status snapshots carry the successful summary that is still in active
    /// context, independently of the visible transcript page. Opening history
    /// establishes a baseline; only a new committed summary produces a notice.
    func observeCompaction(_ snapshot: [String: WireValue], baseline: Bool = false) {
        let summary = snapshot["latestSuccessfulCompaction"]?.object
        let id = summary?["id"]?.string
        if baseline || !compactionBaselineLoaded {
            compactionBaselineLoaded = true; observedCompactionID = id
            return
        }
        if snapshot["runStatus"]?.string == "compacting" { compactionNotice = nil }
        guard id != observedCompactionID else { return }
        observedCompactionID = id
        compactionNotice = id == nil ? nil : summary?["detail"]?.string
    }
    var activity: [String: WireValue] = [:]
    var activityObservedAt: Double = 0
    @Published var queue: [[String: WireValue]] = []
    /// The queued follow-up being rewritten in place. This belongs to the chat,
    /// not to the panel: the queue changes underneath it while a run delivers,
    /// and the panel has to be sized for the taller row it opens.
    @Published var queueEditingID: String?
    var queueCount = 0
    @Published var notice = ""
    @Published var before: String?
    @Published var hostBefore: Double?
    var loadingEarlier = false
    /// Set once the first page has been checked to begin at a user message.
    var pageStartEnsured = false
    @Published var loading = false
    var scrollAnchor: TranscriptAnchor?
    @Published var viewportRequest = 0
    let footer = SessionMetrics()
    var context: [String: WireValue] { get { footer.context } set { footer.context = newValue } }
    func observeContext(_ snapshot: [String: WireValue], baseline: Bool = false) {
        // A newly opened helper starts a new sequence epoch, even when the
        // desktop still has this session's previous prepared estimate.
        if baseline { footer.preparedContext = nil; footer.requestObservation = [:]; footer.lastRequestObservation = [:]; footer.contextObservationRevision = nil }
        if let revision = snapshot["contextObservationRevision"]?.string, revision != footer.contextObservationRevision {
            footer.contextObservationRevision = revision
            let current = snapshot["requestObservation"]?.object ?? [:], last = snapshot["lastRequestObservation"]?.object ?? [:]
            if footer.requestObservation != current { footer.requestObservation = current }
            if footer.lastRequestObservation != last { footer.lastRequestObservation = last }
        }
        if let context = snapshot["context"]?.object, context != self.context, acceptsContext(context) { self.context = context }
        if let sequence = snapshot["seq"]?.number, let preview = footer.preparedContext, sequence > preview.sequence {
            footer.preparedContext = nil
        }
    }
    /// The helper's count flickers during a run: each appended message clears
    /// it to "pending" and each prepared request replaces it with an estimate.
    /// Keep the last settled count on screen; mid-run, only a count anchored on
    /// gateway-reported usage may replace it. Compaction still resets the ring.
    func acceptsContext(_ context: [String: WireValue]) -> Bool {
        let hasCount = context["tokens"]?.number != nil
        if !hasCount { return context["state"]?.string == "post-compaction" || self.context["tokens"]?.number == nil }
        return !busy || context["method"]?.string == "usage-baseline"
    }
    var metrics: [String: WireValue] { get { footer.metrics } set { footer.metrics = newValue } }
    var turnTiming: [String: WireValue] { get { footer.turnTiming } set { footer.turnTiming = newValue } }
    @Published var captureMode = "persist"
    @Published var captureAvailable = false
    @Published var recovered: [CommandIntent] = []
    /// Edit-and-resend: the user message whose text is loaded in the composer, and the draft it replaced.
    @Published var editingMessageID: String?
    var draftBeforeEdit: DraftRecord?
    var savedDraft: DraftRecord {
        let edit = editingMessageID.map { MessageEditDraft(messageID: $0, originalText: draftBeforeEdit?.text ?? "", originalAttachments: draftBeforeEdit?.attachments, originalSkills: draftBeforeEdit?.skills) }
        return DraftRecord(id: id, text: draft, attachments: attachments, skills: skills, edit: edit)
    }
    func restoreDraft(_ saved: DraftRecord) {
        draft = saved.text; attachments = saved.attachments ?? []; skills = saved.skills ?? []; directCommand = false
        editingMessageID = saved.edit?.messageID
        draftBeforeEdit = saved.edit.map { DraftRecord(id: id, text: $0.originalText, attachments: $0.originalAttachments, skills: $0.originalSkills) }
    }
    var displayObservedAt: Double?
    var projectionRevision: String?
    /// The helper's page exactly as it sent it, before paging merge and
    /// accounting. The next read is a list of changes to this, and the rows it
    /// does not change are reused by identity, so every later comparison of a
    /// settled row is a pointer check rather than a string compare.
    var projectedRows: [TranscriptMessage] = []
    var historyRevision: HistoryRevision?
    /// Once hydrated, the live draft/anchor remain authoritative while their
    /// debounced writes catch up. A warm tab must not restore old saved text.
    var selectionMetadataLoaded = false
    var browsingHistory = false
    var footerUpdatedAt = 0.0
    var accountingRevision = 0
    var messageAccounting: [String: GatewayTotals] = [:]
    var lastSequence: Double = -1
    var snapshotInFlight = false
    var dirty = false
    var uncertain = false
    @Published var contextSelectionReady = false
    var used = Date()
    init(id: String) { self.id = id }
    var busy: Bool { ["queued", "running", "stopping", "compacting"].contains(state) }
    var hasWork: Bool { busy || queueCount > 0 }
}
