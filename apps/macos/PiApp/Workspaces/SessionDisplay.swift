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
    let activityChanges = PassthroughSubject<Void, Never>()
    @Published var metrics: [String: WireValue] = [:] { didSet { if metrics != oldValue { activityChanges.send() } } }
    @Published var turnTiming: [String: WireValue] = [:] { didSet { if turnTiming != oldValue { activityChanges.send() } } }
    @Published var timing = SessionTimingHistory() { didSet { if timing != oldValue { activityChanges.send() } } }
    @Published var gateway = GatewayTotals() { didSet { if gateway != oldValue { activityChanges.send() } } }
    @Published var gatewayNotice = ""
}
@MainActor final class ComposerDraft: ObservableObject { @Published var text = "" }

@MainActor final class SessionDisplay: ObservableObject {
    /// Committed activity only: text, draft, selection and context rendering do not enter this stream.
    let activityChanges = PassthroughSubject<Void, Never>()
    let id: String
    let presentation = ConversationPresentation()
    @Published var presentationGeneration = UUID()
    @Published var historyState: ConversationLoadState = .dormant
    @Published var historyProgress: String?
    @Published var olderPage = ConversationPageBoundary()
    @Published var newerPage = ConversationPageBoundary()
    @Published var draftReady = true
    var completionTracker = SessionCompletionTracker()
    var monitoringEpoch: String?
    var monitoringCursor: Double?
    let transcriptChanges = CurrentValueSubject<[TranscriptMessage], Never>([])
    let presentationChanges = CurrentValueSubject<TranscriptPresentationInput, Never>(.init(messages:[], lifecycle:nil))
    /// The chat's tasks as the helper last presented them. Any write that
    /// is not the snapshot loop adopting a presentation (`adoptTaskPresentation`)
    /// forgets its revision, so the next snapshot carries the helper's whole
    /// presentation again, as every snapshot did before 0.1.85.
    var taskPresentation: TaskPresentationProjection? { didSet { taskPresentationRevision = nil; if oldValue != taskPresentation { publishTranscript() } } }
    /// The helper's revision of `taskPresentation`, sent back with the next
    /// snapshot so an unchanged presentation is left out of the reply.
    var taskPresentationRevision: String?
    func adoptTaskPresentation(_ value: TaskPresentationProjection, revision: String?) {
        taskPresentation = value; taskPresentationRevision = revision
    }
    private var transcriptBatchDepth = 0
    func beginTranscriptBatch() { transcriptBatchDepth += 1 }
    func endTranscriptBatch() { transcriptBatchDepth -= 1; if transcriptBatchDepth == 0 { publishTranscript() } }
    var messages: [TranscriptMessage] = [] { didSet { projectionRevision = nil; adoptDeliveredSending(); publishTranscript() } }
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
            return ["failed", "cancelled", "removed"].contains(receipt) || (!loading && !busy && queued.contains(row.id))
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
        if historyState == .loading { return [] }
        var rows = messages
        for row in sendingRows where !messages.reversed().contains(where: { $0.id == row.id }) { rows.append(row) }
        if let retryNotice { rows.append(TranscriptMessage(id: "notice:retry:" + id, role: "system", text: retryNotice, kind: "notice")) }
        if let failureMessage {
            rows.append(TranscriptMessage(id: "failure:run:" + id, role: "system", text: failureMessage, kind: "failure",
                                          detail: queuePaused && !queue.isEmpty ? "Queued follow-ups are paused. Resume when you’re ready." : nil))
        } else if let sendFailure {
            rows.append(TranscriptMessage(id: "failure:send:" + id, role: "system", text: sendFailure, kind: "failure"))
        }
        return rows
    }
    func publishTranscript() {
        guard transcriptBatchDepth == 0 else { return }
        let rows = presentedMessages
        let input = TranscriptPresentationInput(messages:rows, lifecycle:taskPresentation)
        if presentationChanges.value != input { presentationChanges.send(input) }
        if transcriptChanges.value != rows { transcriptChanges.send(rows) }
    }
    /// "Retrying (attempt 2 of 6) after: …" while the helper waits to retry a transient failure.
    @Published var retryNotice: String? { didSet { if retryNotice != oldValue { publishTranscript() } } }
    private(set) var retryAttempt: Int? { didSet { if retryAttempt != oldValue { activityChanges.send() } } }
    private(set) var retryLimit: Int? { didSet { if retryLimit != oldValue { activityChanges.send() } } }
    /// A submission the host or app refused; cleared by the next send.
    @Published var sendFailure: String? { didSet { if sendFailure != oldValue { publishTranscript() } } }
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
    @Published var skills: [SkillChip] = []
    @Published var directCommand = false
    @Published var completionVisible = false
    @Published var completionIndex = 0
    @Published var completionSelectionID: String?
    @Published var skillCatalog = SkillCatalog()
    var completionToken: SlashCompletionToken?
    var composerLocation: ComposerLocation?
    weak var composerEditor: ComposerTextView?
    var completionParse: Task<Void, Never>?
    var codeClassification: (generation: UUID, revision: UInt64, offset: Int, outside: Bool)?
    @Published var state = "idle" { didSet { if state != oldValue { activityChanges.send() } } }
    @Published var runStatus = "idle" { didSet { if runStatus != oldValue { activityChanges.send() } } }
    /// Bumped when the pane should move keyboard focus into the composer.
    @Published var composerFocusRequest = 0
    @Published var failureMessage: String? { didSet { if failureMessage != oldValue { publishTranscript() } } }
    @Published var queuePaused = false { didSet { if queuePaused != oldValue { publishTranscript() } } }
    /// The chat's journal ends in a record cut off mid-write: its complete
    /// records are shown read-only and Recover Copy is offered instead of the composer.
    @Published var damagedTail = false
    var canResumeQueue: Bool { !busy && (!queue.isEmpty || queuePaused || ["paused", "interrupted"].contains(state)) }
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
    @Published var compactionProgress: String?
    private var compactionBaselineLoaded = false
    private var observedCompactionID: String?
    /// Status snapshots carry the successful summary that is still in active
    /// context, independently of the visible transcript page. Opening history
    /// establishes a baseline; only a new committed summary produces a notice.
    func observeCompaction(_ snapshot: [String: WireValue], baseline: Bool = false) {
        let operation=snapshot["compaction"]?.object
        let chunk=operation?["chunk"]?.number.flatMap { value in
            value.isFinite && value >= 1 && value <= 8 && value.rounded() == value ? Int(value):nil
        }
        let chunkDetail=chunk.map { " · chunk \($0)" } ?? ""
        let progress: String?
        switch operation?["phase"]?.string {
        case "summarizing": progress="Summarizing earlier work"+chunkDetail
        case "merging": progress="Combining summaries"+chunkDetail
        case "retrying": progress="Retrying summary request"
        case "retrying-output-budget": progress="Reducing summary input to leave more output space"
        case "planning": progress="Preparing complete tool history"
        default: progress=nil
        }
        if compactionProgress != progress { compactionProgress=progress }
        let summary = snapshot["latestSuccessfulCompaction"]?.object
        let id = summary?["id"]?.string
        if baseline || !compactionBaselineLoaded {
            compactionBaselineLoaded = true; observedCompactionID = id
            return
        }
        // Published on the whole display: written only when it changes, not
        // once per snapshot for as long as a compaction runs.
        if snapshot["runStatus"]?.string == "compacting", compactionNotice != nil { compactionNotice = nil }
        guard id != observedCompactionID else { return }
        observedCompactionID = id
        compactionNotice = id == nil ? nil : summary?["detail"]?.string
    }
    var activity: [String: WireValue] = [:] { didSet { if activity != oldValue { activityChanges.send() } } }
    var activityObservedAt: Double = 0
    @Published var queue: [[String: WireValue]] = []
    /// The queued follow-up being rewritten in place. This belongs to the chat,
    /// not to the panel: the queue changes underneath it while a run delivers,
    /// and the panel has to be sized for the taller row it opens.
    @Published var queueEditingID: String?
    /// What was typed into that row, kept with the chat: the panel is rebuilt
    /// for each chat, and came back showing the original message.
    var queueEditText: (id: String, text: String)?
    var queueCount = 0 { didSet { if queueCount != oldValue { activityChanges.send() } } }
    @Published var notice = ""
    @Published var before: String?
    @Published var hostBefore: Double?
    var loadingEarlier = false
    /// Set once the first page has been checked to begin at a user message.
    var pageStartEnsured = false
    @Published var loading = false { didSet { if loading != oldValue { activityChanges.send() } } }
    var pinnedHistoryIDs: Set<String> = []
    var scrollAnchor: TranscriptAnchor?
    @Published var viewportRequest = 0
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
    /// Edit-and-resend: the user message whose text is loaded in the composer, and the draft it replaced.
    @Published var editingMessageID: String?
    var draftBeforeEdit: DraftRecord?
    var editGeneration = UUID()
    @Published var editPreparing = false
    @Published var editSubmitting = false
    @Published var editInputReviewRequired = false
    @Published var editMissingAttachments: Set<String> = []
    @Published var editNotice = ""
    var editSourceTimeline: String?
    var editSourceTextDigest: String?
    /// The branch this reader's edit is making (`sendEdit`), until the
    /// snapshot that first carries it is adopted (`adoptOwnBranch`).
    var pendingBranch: PendingBranch?
    var savedDraft: DraftRecord {
        let edit = editingMessageID.map { MessageEditDraft(messageID: $0, originalText: draftBeforeEdit?.text ?? "", originalAttachments: draftBeforeEdit?.attachments, originalSkills: draftBeforeEdit?.skills, sourceTimeline: editSourceTimeline, sourceTextDigest: editSourceTextDigest, inputReviewRequired: editInputReviewRequired) }
        return DraftRecord(id: id, text: draft, attachments: attachments, skills: skills, edit: edit)
    }
    func restoreDraft(_ saved: DraftRecord) {
        draft = saved.text; attachments = saved.attachments ?? []; skills = saved.skills ?? []; directCommand = false
        editingMessageID = saved.edit?.messageID
        editSourceTimeline = saved.edit?.sourceTimeline; editSourceTextDigest = saved.edit?.sourceTextDigest
        editInputReviewRequired = saved.edit?.inputReviewRequired ?? false
        editGeneration = UUID(); editPreparing = false; editSubmitting = false; editNotice = ""; editMissingAttachments = []
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
    /// This window is detached from the helper's live tail (a newer gap,
    /// source load or explicit retained-message inspection). Earlier rows
    /// alone do not detach it or suppress live transcript updates.
    var browsingHistory = false
    var footerUpdatedAt = 0.0
    var accountingRevision = 0
    var messageAccounting: [String: GatewayTotals] = [:]
    var lastSequence: Double = -1
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
    /// What the snapshot loop last read of them, and at which revision.
    var pendingIntents: (revision: Int, intents: [CommandIntent])?
    // Test seams: what the snapshot loop did for this chat.
    /// Reads of this chat's pending submissions from the store.
    var intentReads = 0
    /// Full decodes of the task presentation's finished tasks.
    var taskPresentationDecodes: Int { taskPresentationDecoder.decodes }
    var snapshotInFlight = false
    var dirty = false
    var uncertain = false { didSet { if uncertain != oldValue { activityChanges.send() } } }
    @Published var contextSelectionReady = false
    var used = Date()
    init(id: String) {
        self.id = id
    }
    var busy: Bool { ["queued", "running", "stopping", "compacting"].contains(state) }
    var hasWork: Bool { busy || queueCount > 0 }
}
