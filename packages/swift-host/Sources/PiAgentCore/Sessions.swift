import Foundation

public struct Submission: Codable, Sendable {
    public var commandID: String, turnID: String, text: String, attachments: [JSON], skills: [FrozenSkill]
    /// Per-turn overrides of model alias, thinking level and declared limits. They
    /// apply to every request of this turn only and survive a queued restart.
    public var model: String? = nil, thinkingLevel: String? = nil
    public var contextWindow: Int? = nil, maxOutputTokens: Int? = nil, modelOutputLimit: Int? = nil
    public init(commandID: String, turnID: String, text: String, attachments: [JSON] = [], skills: [FrozenSkill] = [], model: String? = nil, thinkingLevel: String? = nil, contextWindow: Int? = nil, maxOutputTokens: Int? = nil, modelOutputLimit: Int? = nil) { self.commandID=commandID; self.turnID=turnID; self.text=text; self.attachments=attachments; self.skills=skills; self.model=model; self.thinkingLevel=thinkingLevel; self.contextWindow=contextWindow; self.maxOutputTokens=maxOutputTokens; self.modelOutputLimit=modelOutputLimit }
    /// The whole submission, as the durable queue record keeps it.
    var savedValue: JSON { (try? JSON.parse(JSONEncoder().encode(self))) ?? [:] }
    /// The queue row the app shows. `text` is a bounded preview, so the app
    /// must not write it back as an edit: `queue.read` returns the whole
    /// submission text, and `textTruncated` says when that read is needed.
    var previewValue: JSON {
        let kept = encodedPreview(text,bytes:1024)
        var value: JSON = ["turnId":JSON(turnID),"commandId":JSON(commandID),"text":JSON(kept),
                           "textBytes":JSON(text.utf8.count),"textTruncated":JSON(kept.utf8.count < text.utf8.count)]
        if let model { value["model"]=JSON(model) }; if let thinkingLevel { value["thinkingLevel"]=JSON(thinkingLevel) }
        if let contextWindow { value["contextWindow"]=JSON(contextWindow) }; if let maxOutputTokens { value["maxOutputTokens"]=JSON(maxOutputTokens) }; if let modelOutputLimit { value["modelOutputLimit"]=JSON(modelOutputLimit) }
        return value
    }
}

/// One chat: its journal, its live context, the run that answers a turn and
/// the bounded page a reader sees. The implementation is split across
/// `Session*.swift` extension files, so the state below is module-internal
/// rather than private; actor isolation, not access control, is what keeps
/// it consistent.
public actor AgentSession {
    public let id: String, readOnly: Bool
    /// The connection settings requests use. Saved settings replace them at
    /// once when the session is idle and when a run ends otherwise.
    public private(set) var profile: Profile
    public let resources: Resources
    let cwd: URL, directory: URL, client: any ModelClient, tools: any ToolExecuting, traces: TraceStore, editingGate: AsyncGate
    var apiKey: String
    let changed: @Sendable (String, Int) -> Void
    /// Settings saved while a run is going: they wait until it ends.
    var pendingConfiguration: (profile: Profile, apiKey: String)?
    // history: every journal message in order. context: live model context.
    // visible: the displayed timeline, i.e. history minus tails abandoned by
    // turn.edit branches. boundary: the latest complete side-chat boundary.
    var journal: SessionJournal?, history: [ChatMessage]=[], context: [ChatMessage]=[], boundary: [ChatMessage]=[], visible: [ChatMessage]=[]
    var queue: [Submission]=[], steering: [Submission]=[], commands: [JSON]=[], events: [JSON]=[]
    var runTask: Task<Void,Never>?, state="idle", runStatus="idle", errorMessage: String?, queuePaused=false
    /// While a transient gateway failure is being retried: attempt, total and the reason.
    var retryInfo: JSON = .null
    var partialTimeline = ResponseTimeline()
    var partialLedgerID: String?, compactionPresentationID: String?
    var presentationOrdinal = 0
    var sequence=0, partialID: String?, partialText="", partialThinking="", partialTools: [String:JSON]=[:], toolStates: [String:JSON]=[:]
    /// The bounded previews the projection puts in the streaming row, kept
    /// across deltas: recomputing them per token copied the whole reply so far.
    /// Bumped whenever the streamed tool cards change, so a text-only delta can
    /// be recognised as one without comparing the cards themselves.
    var partialCardsVersion: UInt64 = 0
    /// Streamed tool cards in arrival order, and how many distinct calls the
    /// reply has announced. Only the displayed prefix is retained: a reply that
    /// announces hundreds of calls must not grow the projected row without
    /// bound, because an oversized snapshot frame kills the helper process.
    var partialToolOrder: [String]=[], partialToolSeen=Set<String>()
    /// Live tool cards in arrival order, with the preview bytes each one holds.
    /// Eviction is oldest-first; a dictionary's key order is not arrival order,
    /// so sorting keys would retire a running card and keep a finished one.
    var toolStateOrder: [String]=[], toolStateBytes: [String:Int]=[:]
    var cumulativeUsage = CumulativeUsage()
    var currentTurnID="", appliedRevision: String?
    /// Where the time went: model requests versus tool execution, for the
    /// current turn and for the whole session. Session totals persist.
    var turnModelMs=0.0, turnToolMs=0.0
    var cumulativeModelMs: Double? = 0, cumulativeToolMs: Double? = 0
    var contextBaseline: RequestUsageBaseline?
    var contextMutation: UInt64 = 0
    var contextResetReason = "epoch-reset"
    var taskRootID: String?
    var activeTaskPresentation: TaskPresentationRecord?
    var recentTaskPresentations: [TaskPresentationRecord] = []
    var partialStartedAt: Double?
    var presentationUtility = false
    var cachedPresentationTimeline: String?
    var contextRecovery: JSON = .null
    var compactionState: JSON = .null
    var compactionAttemptIDs: [String] = []
    var compactionPhysicalAttempts = 0
    var compactionProgressAt = 0.0
    let compactionPolicy: CompactionPolicy
    var contextCounter = RequestContextCounter()
    var currentContextCount: RequestContextCount?
    var requestObservation: RequestObservation?
    var publishedObservation: JSON = .null, lastRequestObservation: JSON = .null, observationEstimate: JSON = .null
    var observationGeneration: UInt64 = 0, observationRevision: UInt64 = 0
    var observationPublishedAt = 0.0
    var monitoring = SessionMonitoringBuffer()
    var begin: Double?, end: Double?, parentInfo: JSON = .null, ephemeral=false, keepRequested=false
    var steeringMode="one-at-a-time", followUpMode="one-at-a-time"
    var closed=false
    var activeSubmission: Submission?
    var appliedSnapshot: ResourceSnapshot?
    var preparedContext: ContextPreview?
    var currentAttemptIDs: [String] = []
    var pendingRequestLinks: [String: [String]] = [:]
    var toolHistory = ToolHistoryIndex()
    var toolStateOwners: [String: String] = [:]
    var modelActive = false
    var assistantMessageCount = 0
    var latestAssistantMessageID: String?
    let autoCompaction: Bool
    let titleTask: Bool
    /// Test seam: the clock the display observation stamps rows with, so a
    /// test can assert when a change became visible without sleeping.
    let displayClock: @Sendable () -> Double
    // Earliest undispatched live model/tool changes, bounded to the current
    // 60-message projection window plus its partial assistant. Initial history
    // and status notifications do not constitute newly observed model deltas.
    var pendingDisplayObservations: [String: Double] = [:]
    // A hidden session needs state, not a serialization of its transcript. An
    // opaque revision is cheap to read and is unique to this loaded runtime;
    // reopening cannot accidentally validate a projection from a retired host.
    let displayEpoch = UUID().uuidString
    var displayGeneration: UInt64 = 0
    var displayRows: [String: DisplayRow] = [:]
    var displayProjection: DisplayProjection?
    var displayRowVersion: UInt64 = 0
    // The page this session last put on the wire. A reader that asks from
    // exactly that revision is sent only the rows that changed since; any
    // other revision, including none, is answered with the whole page.
    var sentRevision: String?
    var sentOrder: [String] = []
    var sentVersions: [String: UInt64] = [:]
    var sentStreaming: StreamingRowState?
    // Test seams; see SessionTestSeams.swift for the whole set and what they
    // cost. These two are stored because they count work as it happens: one
    // integer increment each, on paths that already build a page.
    var displayProjectionBuildCount = 0
    var displayRowProjectionCount = 0
    public init(id: String, profile: Profile, apiKey: String, cwd: URL, directory: URL, readOnly: Bool, resources: Resources, client: any ModelClient, tools: any ToolExecuting, traces: TraceStore, editingGate: AsyncGate = AsyncGate(), resumePath: String? = nil, seed: [ChatMessage]? = nil, parent: JSON = .null, autoCompaction: Bool = true, titleTask: Bool = false, compactionPolicy: CompactionPolicy = CompactionPolicy(), displayClock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime * 1000 }, beforeJournalAppend: @escaping @Sendable (JSON) throws -> Void = { _ in }, beforeJournalSynchronize: @escaping @Sendable () throws -> Void = {}, changed: @escaping @Sendable (String, Int) -> Void = {_,_ in}) throws {
        self.id=id; self.profile=profile; self.apiKey=apiKey; self.cwd=cwd; self.directory=directory; self.readOnly=readOnly; self.resources=resources; self.client=client; self.tools=tools; self.traces=traces; self.editingGate=editingGate; self.changed=changed; self.autoCompaction=autoCompaction; self.titleTask=titleTask; self.displayClock=displayClock; self.compactionPolicy=compactionPolicy
        if let seed {
            history=seed; context=seed; boundary=seed; visible=seed; toolHistory=ToolHistoryIndex(seed); parentInfo=parent; ephemeral=true
            taskRootID=seed.last(where: { $0.role == "user" })?.taskRootID
            let assistants=seed.filter { $0.role=="assistant" }; assistantMessageCount=assistants.count; latestAssistantMessageID=assistants.last?.id
            return
        }
        let url=resumePath.map(canonical) ?? directory.appendingPathComponent(id + ".jsonl")
        guard within(url,canonical(directory.path)) else { throw AgentError("session_scope", "Writable sessions must be in the app-managed directory") }
        let opened=try SessionJournal(url:url,id:id,cwd:cwd,binding:profile.binding,create:resumePath == nil,beforeAppend:beforeJournalAppend,beforeSynchronize:beforeJournalSynchronize); journal=opened
        var stateRecord: JSON?
        for item in opened.loaded {
            if item["type"].text == "message" {
                let message=try ChatMessage(id:required(item["id"],"message id"),pi:item["message"]); history.append(message); if !["execution","requestLedger"].contains(message.kind ?? "") { context.append(message) }; visible.append(message)
                if message.role=="assistant" { assistantMessageCount += 1; latestAssistantMessageID=message.id }
                for attempt in message.requestAttemptIDs ?? [] { pendingRequestLinks[attempt, default: []].append(message.id) }
            } else if item["type"].text == "compaction" {
                let restored=try CompactionCheckpoint.restore(item,context:context)
                let summary=restored.summary, kept=restored.kept
                for attempt in summary.requestAttemptIDs ?? [] { pendingRequestLinks[attempt, default: []].append(summary.id) }
                context=[summary]+kept; history.append(summary); visible.append(summary)
                if let operation = summary.operationID, let position = history.firstIndex(where: { $0.kind == "execution" && $0.operationID == operation }) {
                    history[position].responseTimeline?.finish("completed"); history[position].detail="Compaction · Checkpoint durably adopted"
                    let replacement=history[position]
                    if let index=visible.firstIndex(where: { $0.id == replacement.id }) { visible[index]=replacement }
                }
                compactionState=summary.compaction ?? .null
                if let recovery=summary.compaction?["recovery"], !recovery.isNull { contextRecovery=recovery }
            } else if item["type"].text == "branch" {
                // Replay an edit: the live context becomes exactly the kept ids and
                // the abandoned tail leaves the displayed timeline, never the journal.
                if !item["nativeBranchVersion"].isNull {
                    let plan = try Self.restoreBranch(item, history: history, visible: visible, context: context)
                    Self.adoptBranch(plan, history: &history, visible: &visible, context: &context, markerID: try identity(item["id"]))
                } else {
                let ordered=try CompactionCheckpoint.identities(item["keptIds"]), ids=Set(ordered)
                guard context.filter({ ids.contains($0.id) }).map(\.id)==ordered else { throw AgentError("session_damaged","Branch references missing, abandoned or reordered messages") }
                Self.branch(history:&history,context:&context,visible:&visible,from:item["fromMessageId"].text ?? "",keptIDs:ids,markerID:try identity(item["id"]))
                // New branches publish their replacement queue in the same
                // durable record. A crash before delivery restores it paused.
                }
                if !item["nativeState"].isNull { stateRecord=item["nativeState"] }
                contextRecovery = .null; compactionState = .null
            } else if item["customType"].text == "pi-app.presentation.update.v1" {
                let target = try identity(item["data"]["id"])
                if let position = history.firstIndex(where: { $0.id == target }), ["execution","requestLedger"].contains(history[position].kind ?? "") {
                    var replacement = try ChatMessage(id:target,pi:item["message"]); replacement.replayEligible=false
                    history[position]=replacement
                    if let index=visible.firstIndex(where: { $0.id == target }) { visible[index]=replacement }
                }
            } else if item["customType"].text == "pi-app.task-terminal.v1" {
                let task = try JSONDecoder().decode(TaskPresentationRecord.self, from: item["data"].data())
                guard task.valid, task.terminal else { throw AgentError("session_damaged", "Invalid task completion evidence") }
                recentTaskPresentations.removeAll { $0.key == task.key }; recentTaskPresentations.append(task)
                if recentTaskPresentations.count > 64 { recentTaskPresentations.removeFirst() }
            } else if item["customType"].text == "pi-app.native.state.v1" { stateRecord=item["data"] }
            else if item["customType"].text == "pi-app.context-recovery.v1" { contextRecovery=item["data"] }
            else if item["customType"].text == "pi-app.native.context.v1" {
                let byID=Dictionary(history.map { ($0.id,$0) },uniquingKeysWith:{_,b in b})
                let ids=try CompactionCheckpoint.identities(item["data"]["ids"])
                context=try ids.map { guard let message=byID[$0] else { throw AgentError("session_damaged","Unknown context reference") }; return message }
                let selected = EditReplayPlan.forkTimeline(visible: visible.map(\.id), boundary: ids)
                if !item["data"]["visibleIDs"].isNull, try CompactionCheckpoint.identities(item["data"]["visibleIDs"]) != selected { throw AgentError("session_damaged", "Fork timeline does not match the complete boundary") }
                visible = selected.compactMap { byID[$0] }
            } else if ["pi-app.side-origin.v1", "pi-app.fork-origin.v1"].contains(item["customType"].text ?? "") {
                parentInfo=item["data"]
                if item["customType"].text == "pi-app.fork-origin.v1" { contextRecovery = .null; compactionState = .null }
            }
        }
        // A process restart cannot manufacture terminal evidence. Retained
        // parts stay in place, with an explicit gap after the last checkpoint.
        for index in history.indices {
            let prior = history[index]
            guard ["execution","requestLedger"].contains(prior.kind ?? ""), prior.responseTimeline?.terminal == nil else { continue }
            history[index].responseTimeline?.finish("interrupted")
            history[index].responseTimeline?.coverage = "partial"
            history[index].detail = (history[index].kind == "requestLedger" ? "Request":"Compaction") + " interrupted · no terminal receipt"
            let replacement=history[index]
            if let shown = visible.firstIndex(where: { $0.id == replacement.id }) { visible[shown] = replacement }
        }
        presentationOrdinal = history.compactMap(\.responseTimeline).flatMap(\.segments).map { $0.part.sessionOrdinal ?? $0.part.ordinal }.max() ?? 0
        if let saved=stateRecord {
            if !saved["taskPresentation"].isNull,
               var task = try? JSONDecoder().decode(TaskPresentationRecord.self, from: saved["taskPresentation"].data()),
               task.valid, !task.terminal, !recentTaskPresentations.contains(where: { $0.key == task.key }) {
                task.outcome = "interrupted"; task.phase = "terminal"; task.endedAt = task.startedAt
                task.endedAtUnixMs = nil // No terminal receipt; the actual finish time is unknown.
                let retained = visible.filter { $0.taskExecutionID == task.executionID && $0.taskRootID == task.rootID }
                task.lastSourceID = retained.last?.id ?? task.anchorSourceID
                let replies = retained.filter { $0.role == "assistant" }
                task.replies = replies.count
                task.issuedCalls = replies.reduce(0) { $0 + $1.content.filter { $0["type"].text == "toolCall" }.count }
                task.modelMs = replies.reduce(0) { $0 + ($1.modelMs ?? 0) }
                task.toolMs = retained.filter { $0.role == "toolResult" }.reduce(0) { $0 + ($1.toolStats?["durationMs"].double ?? 0) }
                task.preparingCalls = 0; task.currentTool = nil
                task.detail = "Previous runtime ended without a terminal receipt. Tool effects may be unknown; no work was replayed."
                recentTaskPresentations.append(task)
                if recentTaskPresentations.count > 64 { recentTaskPresentations.removeFirst() }
            }
            queue=try JSONDecoder().decode([Submission].self,from:saved["queue"].data())
            steering=try JSONDecoder().decode([Submission].self,from:saved["steering"].data())
            commands=saved["commands"].list; let hasQueued = !queue.isEmpty; let hasSteering = !steering.isEmpty; queuePaused = hasQueued || hasSteering || saved["active"].flag == true || saved["queuePaused"].flag == true
            steeringMode=saved["steeringMode"].text ?? "one-at-a-time"; followUpMode=saved["followUpMode"].text ?? "one-at-a-time"
            if !saved["timing"].isNull {
                cumulativeModelMs=ObservedDuration.valid(saved["timing"]["modelMs"].double)
                cumulativeToolMs=ObservedDuration.valid(saved["timing"]["toolMs"].double)
            }
            if saved["active"].flag == true { errorMessage="The previous run was interrupted. No model or tool request was replayed. Inspect tool effects before continuing." }
            else if saved["runStatus"].text == "failed" {
                runStatus="failed"; errorMessage=saved["errorMessage"].text ?? "Run failed."
            }
        }
        // Never repeat a tool after a crash. Pair unresolved calls with explicit
        // unknown outcomes so future requests remain protocol-valid.
        let recoveredTools=ToolHistoryIndex(context)
        let unresolved=context.flatMap { message in
            message.content.filter { message.role == "assistant" && $0["type"].text == "toolCall" && recoveredTools.results[message.id]?[$0["id"].text ?? ""] == nil }
                .map { (call: $0, attempts: message.requestAttemptIDs, turn: message.turn) }
        }
        for pending in unresolved {
            let call=pending.call
            var result=ChatMessage(role:"toolResult",content:[textBlock("Interrupted before durable tool result. Outcome unknown; inspect effects. The application did not rerun this tool.")]); result.toolCallId=call["id"].text; result.toolName=call["name"].text; result.isError=true
            result.requestAttemptIDs=pending.attempts; result.turn=pending.turn
            try opened.append(["type":"message","message":result.pi],id:result.id); history.append(result); context.append(result); visible.append(result); queuePaused=true
            for attempt in result.requestAttemptIDs ?? [] { pendingRequestLinks[attempt, default: []].append(result.id) }
        }
        let retainedTaskSources = Set(visible.map(\.id))
        recentTaskPresentations.removeAll { $0.lastSourceID.map { !retainedTaskSources.contains($0) } ?? true }
        let deliveredIDs=Set(history.filter { $0.role == "user" }.map(\.id))
        // Journal append may succeed just before the queue-state append crashes.
        // A durably delivered user identity must never be delivered a second time.
        queue.removeAll { deliveredIDs.contains($0.turnID) }; steering.removeAll { deliveredIDs.contains($0.turnID) }
        toolHistory=ToolHistoryIndex(history)
        taskRootID=context.last(where: { $0.role == "user" })?.taskRootID
        boundary=context; state=runStatus == "failed" ? "error" : queuePaused ? "paused" : "idle"
    }
    public var isRunning: Bool { runTask != nil }
    public var isEphemeral: Bool { ephemeral }
    public var isIdle: Bool { runTask == nil && queue.isEmpty && steering.isEmpty }
    /// Takes a saved connection's new profile and key. An idle session takes
    /// them now; one with a run going keeps what it started with and switches
    /// when the run ends, so a turn in flight never changes route or key midway.
    /// Returns whether the settings are in use already.
    public func configure(profile: Profile, apiKey: String) throws -> Bool {
        guard !closed else { throw AgentError("session_closed", "Session runtime is unloaded") }
        guard profile.binding == self.profile.binding else { throw AgentError("session_conflict", "Changed API, endpoint or model requires a separately bound session") }
        guard runTask == nil else { pendingConfiguration = (profile, apiKey); event("state"); return false }
        apply(profile: profile, apiKey: apiKey); return true
    }
    func apply(profile: Profile, apiKey: String) {
        self.profile = profile; self.apiKey = apiKey; pendingConfiguration = nil
        replayInputsChanged()
        // The count and its usage baseline described requests under the old settings.
        contextBaseline = nil; currentContextCount = nil; clearRequestObservation()
        event("configured")
    }
    public var path: String? { journal?.url.path }
    public var isConnectionTest: Bool { tools is DisabledTools }
    public var resourceRevision: String? { appliedRevision }
    /// The retained event window. Trimming to an exact bound moved the whole
    /// array on every event once a long chat had filled it; dropping a batch
    /// at a slack line costs the same amortised and keeps strictly more
    /// history for a reader that has to catch up.
    static let retainedEvents = 4096, retainedEventSlack = 512
    func event(_ type: String, _ payload: JSON = [:]) {
        monitoring.activity(activityPhase, at: nowMS())
        sequence += 1; events.append(["seq":JSON(sequence),"type":JSON(type),"payload":payload])
        if events.count > Self.retainedEvents+Self.retainedEventSlack { events.removeFirst(events.count-Self.retainedEvents) }
        changed(id,sequence)
    }
    /// Set while a retry starts, so the run answers the failed turn before it
    /// looks at queued follow-ups.
    var retrying=false
    /// The submission of a turn that failed or was stopped, kept so a retry
    /// sends the same request: its model, reasoning effort and budgets.
    var retrySubmission: Submission?
    public func stop() { queuePaused=true; runTask?.cancel(); if runTask != nil { state="stopping" } else if state != "error" { state="paused" }; event("state") }
    public func unloadIfIdle() -> Bool { guard isIdle, !ephemeral else { return false }; closed=true; journal=nil; return true }
    public func close() async { closed=true; stop(); await runTask?.value; journal=nil }
}
