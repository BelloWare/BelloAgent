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
    func invokeTool(_ call: ToolCall) async throws -> JSON {
        if call.name == "history_read", !titleTask, !(tools is DisabledTools) { showToolInvocation(call); return try historyRead(call.arguments) }
        let update: @Sendable (JSON) async -> Void = { [weak self] update in await self?.toolUpdate(call.id,update) }
        guard !readOnly, Self.isEditing(call) else { showToolInvocation(call); return try await tools.invoke(call,readOnly:readOnly,onUpdate:update) }
        try await editingGate.acquire()
        showToolInvocation(call)
        do { let result=try await tools.invoke(call,readOnly:readOnly,onUpdate:update); await editingGate.release(); return result }
        catch { await editingGate.release(); throw error }
    }
    func toolUpdate(_ id:String,_ update:JSON) {
        guard var view=toolStates[id], view["state"].text=="running" else { return }
        let observedAt = displayClock(), previous = view
        let text=update["content"].list.compactMap{$0["text"].text}.joined(separator:"\n")
        let kept=text
        view["output"]=JSON(kept);view["truncated"]=JSON((view["inputTruncated"].flag ?? false) || kept.utf8.count<text.utf8.count);setToolState(id,view)
        if view != previous { recordDisplayChange(toolStateOwners[id], at: observedAt) }
        event("tool_execution_update")
    }
    func recordTool(_ call: ToolCall, result: JSON, started: Double?, state: String, uncertain: Bool = false) throws {
        let observedAt = displayClock()
        var blocks=result["content"].list
        if blocks.isEmpty { blocks=[textBlock(result.encoded())] }
        // Preserve structured MCP data in the returned text as well as text blocks.
        if !result["structuredContent"].isNull { blocks.append(textBlock("Structured content:\n"+result["structuredContent"].encoded())) }
        var text=blocks.compactMap { $0["text"].text }.joined(separator:"\n")
        if text.isEmpty { text=result.encoded() }
        var retained: String?
        if text.utf8.count > 65536 {
            let folder=directory.appendingPathComponent("tool-output"); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let file=folder.appendingPathComponent(UUID().uuidString+".json"); let bytes=try result.data(); guard bytes.count <= 16*1024*1024 else { throw AgentError("tool_output_limit", "Tool result exceeds 16 MiB; remote effects may have completed") }
            try bytes.write(to:file); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            retained=file.lastPathComponent
            text=preview(text,bytes:32768)+"\n[Large result retained. Invocation already completed; use history_read with its retained reference for bounded pages.]"
        }
        var message=ChatMessage(role:"toolResult",content:[textBlock(text)]); message.toolCallId=call.id; message.toolName=call.name; message.isError=result["isError"].flag ?? false
        message.retainedOutput=retained
        if retained != nil { message.content.append(textBlock("Retained reference: "+CompactionSourceBuilder.reference(message))) }
        message.requestAttemptIDs=currentAttemptIDs
        let durationMs=started.map { nowMS()-$0 }
        if let durationMs { turnToolMs += durationMs; cumulativeToolMs = ObservedDuration.adding(cumulativeToolMs, durationMs) }
        let stats=result["stats"]
        message.toolStats=["durationMs":durationMs.map { JSON($0) } ?? .null,"path":stats["path"],"added":stats["added"],"removed":stats["removed"]]
        message.toolStats?["outcome"]=JSON(uncertain || (state == "cancelled" && started != nil) ? "unknown" : started == nil ? "not_executed" : state)
        try append(message, observedAt: observedAt)
        setToolStateOwner(call.id)
        let fields=toolInputFields(call.arguments), keptOutput=text
        let inputTruncated=fields.first(where: { $0.0 == "inputTruncated" })?.1.flag ?? false
        setToolState(call.id,merging(["id":JSON(call.id),"name":JSON(call.name),"state":JSON(state),"output":JSON(keptOutput),"durationMs":durationMs.map { JSON($0) } ?? .null,"truncated":JSON(inputTruncated || keptOutput.utf8.count < text.utf8.count),"path":stats["path"],"added":stats["added"],"removed":stats["removed"]],fields))
        recordDisplayChange(toolStateOwners[call.id], at: observedAt)
        event("tool_execution_end")
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
