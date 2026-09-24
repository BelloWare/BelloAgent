import Foundation

// Tool execution and the live tool cards it retains.

/// Index durable tool results by their assistant message, not only call ID.
/// Providers can reuse a call ID on a later turn; each historical card must
/// continue to show its own paired result. Body previews are built only for the
/// bounded page being displayed, rather than copying every result into memory.
struct ToolHistoryIndex {
    var owners: [String: String] = [:]
    var results: [String: [String: Int]] = [:]
    init(_ messages: [ChatMessage] = []) {
        for (index, message) in messages.enumerated() { append(message, at: index) }
    }
    mutating func append(_ message: ChatMessage, at index: Int) {
        if message.role == "assistant" {
            for call in message.content where call["type"].text == "toolCall" {
                if let id = call["id"].text { owners[id] = message.id }
            }
        } else if message.role == "toolResult", let id = message.toolCallId, let owner = owners[id] {
            results[owner, default: [:]][id] = index
        }
    }
}

extension AgentSession {
    /// Tools that change the workspace. Sessions of one workspace run their
    /// model requests concurrently; only these invocations take turns, so two
    /// chats never edit or run commands at the same moment.
    static let editingTools: Set<String> = ["write", "edit", "bash"]
    static func isEditing(_ call: ToolCall) -> Bool { editingTools.contains(call.name) || (call.name == "mcp" && call.arguments["action"].text == "invoke") }
    /// Errors a tool raises before it has done anything: arguments it cannot
    /// accept, a tool that is unavailable, an edit whose text does not match,
    /// a file it cannot use, a command that could not start, an MCP tool that
    /// is unknown, blocked or rejected the call outright. A call that failed
    /// this way failed; any other error from an editing tool that had begun
    /// may have left effects behind, so its outcome is unknown.
    static let rejectionCodes: Set<String> = ["tool_arguments", "invalid_params", "invalid_range", "invalid_identity", "tool_unavailable", "read_only",
        "edit_match", "file_unavailable", "not_regular_file", "file_too_large", "binary_file", "missing_path", "tool_output", "missing_executable",
        "mcp_arguments", "mcp_tool", "mcp_server", "mcp_config", "mcp_version", "mcp_schema", "mcp_cursor", "mcp_outcome_unknown", "mcp_rejected", "mcp_session_expired", "mcp_unavailable"]
    static func isRejection(_ error: Error) -> Bool { (error as? AgentError).map { rejectionCodes.contains($0.code) } ?? false }
    /// The state a tool card shows for a recorded outcome: `unknown` when the
    /// call was interrupted or failed after it began (effects may exist),
    /// `cancelled` when it never ran, otherwise what it reported. A result
    /// from a journal older than recorded outcomes keeps its isError reading.
    static func cardState(outcome: String?, isError: Bool) -> String {
        switch outcome {
        case "completed"?: return "completed"
        case "unknown"?: return "unknown"
        case "not_executed"?: return "cancelled"
        case "failed"?: return "failed"
        default: return isError ? "failed" : "completed"
        }
    }
    /// Pi's validateToolArguments prepares a call's arguments before the tool
    /// sees them: converted to the tool's schema where pi converts them.
    func piPrepared(_ call: ToolCall) async -> ToolCall {
        guard let schema=await sessionDefinitions().first(where: { $0.name == call.name })?.schema else { return call }
        return ToolCall(id:call.id,name:call.name,arguments:PiProviderRules.coerceArguments(call.arguments,schema:schema))
    }
    /// The tools a request offers: the session's own, as pi offers its tools.
    func sessionDefinitions() async -> [ToolDefinition] { await tools.definitions(readOnly:readOnly) }
    func invokeTool(_ call: ToolCall) async throws -> JSON {
        let prepared=await piPrepared(call)
        let update: @Sendable (JSON) async -> Void = { [weak self] update in await self?.toolUpdate(call.id,update) }
        guard !readOnly, Self.isEditing(call) else { showToolInvocation(call); toolInvocationsBegan.insert(call.id); return try await tools.invoke(prepared,readOnly:readOnly,onUpdate:update) }
        try await editingGate.acquire()
        showToolInvocation(call)
        toolInvocationsBegan.insert(call.id)
        do { let result=try await tools.invoke(prepared,readOnly:readOnly,onUpdate:update); await editingGate.release(); return result }
        catch { await editingGate.release(); throw error }
    }
    func toolUpdate(_ id:String,_ update:JSON) {
        guard var view=toolStates[id], view["state"].text=="running" else { return }
        let observedAt = displayClock(), previous = view
        let text=update["content"].list.compactMap{$0["text"].text}.joined(separator:"\n")
        let kept=text
        view["output"]=JSON(kept);view["truncated"]=JSON((view["inputTruncated"].flag ?? false) || kept.utf8.count<text.utf8.count)
        // Nothing new on the card is nothing to tell a reader.
        guard view != previous else { return }
        setToolState(id,view)
        recordDisplayChange(toolStateOwners[id], at: observedAt)
        event("tool_execution_update")
    }
    /// Records a call's result row and its card's final state. With
    /// `appendNow` false the card updates now and the caller appends the row
    /// later, so a batch's rows keep call order; `countsTime` false leaves the
    /// tool time to the caller, which counts a batch's wall time once.
    @discardableResult
    func recordTool(_ call: ToolCall, result: JSON, started: Double?, state: String, uncertain: Bool = false,
                    appendNow: Bool = true, countsTime: Bool = true) throws -> (message: ChatMessage, observedAt: Double) {
        let observedAt = displayClock()
        var blocks=result["content"].list
        if blocks.isEmpty { blocks=[textBlock(result.encoded())] }
        // Preserve structured MCP data in the returned text as well as text blocks.
        if !result["structuredContent"].isNull { blocks.append(textBlock("Structured content:\n"+result["structuredContent"].encoded())) }
        // Pi hands a tool's images to the model, processed as pi processes
        // them (normalizeToolResultImages); the request decides per model.
        blocks=PiImage.normalize(blocks)
        let images=blocks.filter { $0["type"].text == "image" }
        func describe(_ block: JSON) -> String {
            let kind = block["type"].text ?? "content"
            let payload = block["data"].text.flatMap { Data(base64Encoded: $0)?.count }
            return "[" + (block["mimeType"].text ?? kind) + " result" + (payload.map { ", \($0) bytes" } ?? "") + "]"
        }
        // Text blocks as they are; an audio or other block as a short
        // description, never its base64 payload in the model's context.
        var text=blocks.compactMap { block -> String? in
            if let text = block["text"].text { return text }
            let kind = block["type"].text ?? "content"
            guard !["text","image"].contains(kind) else { return nil }
            return describe(block)
        }.joined(separator:"\n")
        if text.isEmpty && images.isEmpty { text=result.encoded() }
        // Pi's agent loop takes a tool's result whole; pi's own tools cut
        // theirs and name the file that holds the rest. Ours do the same, so
        // this cut is for a tool that returns more (an MCP server): the text
        // is saved whole, and pi's note names the file the model can read.
        if text.utf8.count > 65536 {
            let folder=directory.appendingPathComponent("tool-output"); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let file=folder.appendingPathComponent(UUID().uuidString+".txt"), bytes=Data(text.utf8)
            guard bytes.count <= 16*1024*1024 else { throw AgentError("tool_output_limit", "Tool result exceeds 16 MiB; remote effects may have completed") }
            try bytes.write(to:file); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            text=preview(text,bytes:32768)+"\n\n[Output truncated. Full output: \(file.path)]"
        }
        // An image-only result carries only its images, as the tool returned it.
        var message=ChatMessage(role:"toolResult",content:(text.isEmpty && !images.isEmpty ? [] : [textBlock(text)])+images); message.toolCallId=call.id; message.toolName=call.name; message.isError=result["isError"].flag ?? false
        // The card names each image the model receives beside the text.
        let shown=images.isEmpty ? text : ([text]+images.map(describe)).filter { !$0.isEmpty }.joined(separator:"\n")
        if !images.isEmpty { message.displayText=shown }
        message.requestAttemptIDs=currentAttemptIDs
        let durationMs=started.map { nowMS()-$0 }
        if countsTime, let durationMs { turnToolMs += durationMs; cumulativeToolMs = ObservedDuration.adding(cumulativeToolMs, durationMs) }
        let stats=result["stats"]
        message.toolStats=["durationMs":durationMs.map { JSON($0) } ?? .null,"path":stats["path"],"added":stats["added"],"removed":stats["removed"]]
        let outcome = uncertain || (state == "cancelled" && started != nil) ? "unknown" : started == nil ? "not_executed" : state
        message.toolStats?["outcome"]=JSON(outcome)
        if appendNow { try append(message, observedAt: observedAt) }
        // A batch's card that retired while its call ran stays retired.
        guard appendNow || toolStates[call.id] != nil else { return (message, observedAt) }
        setToolStateOwner(call.id)
        let fields=toolInputFields(call.arguments), keptOutput=shown
        let inputTruncated=fields.first(where: { $0.0 == "inputTruncated" })?.1.flag ?? false
        setToolState(call.id,merging(["id":JSON(call.id),"name":JSON(call.name),"state":JSON(reportsUnknownToolOutcomes ? Self.cardState(outcome:outcome,isError:message.isError) : state),"output":JSON(keptOutput),"durationMs":durationMs.map { JSON($0) } ?? .null,"truncated":JSON(inputTruncated || keptOutput.utf8.count < text.utf8.count),"path":stats["path"],"added":stats["added"],"removed":stats["removed"]],fields))
        recordDisplayChange(toolStateOwners[call.id], at: observedAt)
        event("tool_execution_end")
        return (message, observedAt)
    }
    /// One call of a batch: its result row, held until the batch appends the
    /// rows in call order, and whether it was cancelled.
    struct ToolOutcome: Sendable {
        let index: Int
        let message: ChatMessage
        let observedAt: Double
        let cancelled: Bool
    }

    /// Pi 0.85.1's executeToolCallsParallel: a reply's calls run together, each
    /// card ends as its call ends, and the result rows join the context in call
    /// order once every call has finished. Calls that change the workspace
    /// (write, edit, bash, MCP invocations) run one after another in call order
    /// beside the rest, as pi serializes the mutations of a file; the workspace
    /// editing gate still keeps two chats from editing at once.
    func runToolBatch(_ calls: [ToolCall]) async throws {
        toolInvocationsBegan.removeAll(); runStatus="waitingTool"
        for call in calls {
            setToolStateOwner(call.id)
            let fields=toolInputFields(call.arguments)
            setToolState(call.id,merging(["id":JSON(call.id),"name":JSON(call.name),"state":"running","output":"","durationMs":.null,"truncated":JSON(fields.first(where: { $0.0 == "inputTruncated" })?.1.flag ?? false)],fields))
            recordDisplayChange(toolStateOwners[call.id], at: displayClock())
            event("tool_execution_queued")
        }
        let began=nowMS()
        let ordered=calls.enumerated().map { (index: $0.offset, call: $0.element) }
        let editing=ordered.filter { !readOnly && Self.isEditing($0.call) }, others=ordered.filter { readOnly || !Self.isEditing($0.call) }
        var outcomes=[ToolOutcome?](repeating: nil, count: calls.count)
        await withTaskGroup(of: [ToolOutcome].self) { group in
            for entry in others { group.addTask { [self] in [await runToolCall(entry.call, index: entry.index)] } }
            if !editing.isEmpty {
                group.addTask { [self] in
                    var done: [ToolOutcome]=[]
                    for entry in editing { done.append(await runToolCall(entry.call, index: entry.index)) }
                    return done
                }
            }
            for await finished in group { for outcome in finished { outcomes[outcome.index]=outcome } }
        }
        let wall=nowMS()-began
        turnToolMs += wall; cumulativeToolMs = ObservedDuration.adding(cumulativeToolMs, wall)
        for outcome in outcomes.compactMap({ $0 }) { try append(outcome.message, observedAt: outcome.observedAt) }
        if Task.isCancelled || outcomes.contains(where: { $0?.cancelled == true }) { throw CancellationError() }
    }

    /// Runs one call of a batch and ends its card; the row waits for the batch.
    func runToolCall(_ call: ToolCall, index: Int) async -> ToolOutcome {
        let start=nowMS()
        func outcome(_ result: JSON, started: Double?, state: String, uncertain: Bool = false, cancelled: Bool = false) -> ToolOutcome {
            if let recorded=try? recordTool(call,result:result,started:started,state:state,uncertain:uncertain,appendNow:false,countsTime:false) {
                return ToolOutcome(index:index,message:recorded.message,observedAt:recorded.observedAt,cancelled:cancelled)
            }
            // A result too large to retain still leaves a row in its place.
            var message=ChatMessage(role:"toolResult",content:[textBlock("Tool result could not be recorded; inspect its effects before retrying.")])
            message.toolCallId=call.id; message.toolName=call.name; message.isError=true
            return ToolOutcome(index:index,message:message,observedAt:displayClock(),cancelled:cancelled)
        }
        if Task.isCancelled { return outcome(resultText("Not executed: cancelled before invocation",error:true), started:nil, state:"cancelled", cancelled:true) }
        do {
            let result=try await invokeTool(call)
            return outcome(result, started:start, state:result["isError"].flag == true ? "failed" : "completed")
        } catch {
            let cancelled=Task.isCancelled || error is CancellationError
            // A call stopped before its tool was entered (still waiting for
            // the workspace editing gate) never ran.
            let entered=toolInvocationsBegan.contains(call.id)
            let text=cancelled ? (entered ? "Tool interrupted. Effects may already have occurred; inspect before retrying. No automatic replay." : "Not executed: cancelled before invocation") : (error as? AgentError)?.message ?? "Tool failed; inspect its effects before retrying."
            // Only an editing tool that had begun, and failed other than by
            // rejecting the call outright, may have left effects: its outcome
            // is unknown, never just failed.
            return outcome(resultText(text,error:true), started:entered ? start : nil, state:cancelled ? "cancelled" : "failed",
                           uncertain:entered && Self.isEditing(call) && !Self.isRejection(error), cancelled:cancelled)
        }
    }
    /// Records one live tool card, keeping arrival order and a running total
    /// of the preview bytes the session holds. Both the card count and the
    /// retained bytes are bounded; the oldest cards retire first.
    func setToolState(_ callID: String, _ value: JSON) {
        if toolStates[callID] == nil { toolStateOrder.append(callID) }
        toolStates[callID]=value
        toolStateBytes[callID]=(value["input"].text?.utf8.count ?? 0)+(value["output"].text?.utf8.count ?? 0)
        var retained=toolStateBytes.values.reduce(0,+)
        while toolStateOrder.count > 256 || (retained > ToolInputDisplay.retainedTotalBytes && toolStateOrder.count > 1) {
            let oldest=toolStateOrder.removeFirst()
            // The card just written is never the one that retires.
            guard oldest != callID else { toolStateOrder.append(oldest); continue }
            if let owner=toolStateOwners[oldest] { invalidateDisplay(owner) }
            retained -= toolStateBytes.removeValue(forKey:oldest) ?? 0
            toolStates.removeValue(forKey:oldest); toolStateOwners.removeValue(forKey:oldest)
        }
    }
    func setToolStateOwner(_ callID: String) {
        let owner=toolHistory.owners[callID]
        // A provider may reuse a call ID. Its earlier row now falls back to
        // the durable result; do not leave that row's former live card cached.
        if let previous=toolStateOwners[callID], previous != owner { invalidateDisplay(previous) }
        toolStateOwners[callID]=owner
    }
}
