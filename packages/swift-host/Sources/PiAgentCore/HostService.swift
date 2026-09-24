import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct NDJSONDecoder {
    private var buffer=Data()
    public init() {}
    public mutating func feed(_ bytes: Data) throws -> [JSON] {
        buffer.append(bytes); var result:[JSON]=[]
        while let nl=buffer.firstIndex(of:10) {
            guard nl > 0, nl <= 1048576 else { throw AgentError("invalid_frame", "Protocol frame exceeds limit or is empty") }
            let data=Data(buffer[..<nl]); buffer.removeSubrange(...nl)
            guard String(data:data,encoding:.utf8) != nil else { throw AgentError("invalid_frame", "Protocol frame is not UTF-8") }
            let value=try JSON.parse(data); guard value.isObject else { throw AgentError("invalid_frame", "Protocol frame must be an object") }; result.append(value)
        }
        guard buffer.count <= 1048576 else { throw AgentError("invalid_frame", "Protocol frame exceeds 1 MiB") }; return result
    }
    public func finish() throws { if !buffer.isEmpty { throw AgentError("invalid_frame", "Incomplete protocol frame at EOF") } }
}

/// All commands enter one actor; model calls run in independent session actors.
/// A command ID is content-bound for this host epoch and replay never repeats it.
public actor NativeHostService {
    public let epoch=UUID().uuidString
    private let emit: @Sendable (JSON)->Void
    private var hello=false, closing=false, quiesced=false, opening=false
    private var displayTransfers = DisplayResultTransfers()
    private var allowsDisplayTransfers = false
    /// Set by a reader whose hello says it shows the `unknown` tool card state.
    private var unknownToolOutcomes = false
    private var cwd: URL?, roots: [URL]=[], directory: URL?, resources: Resources?, mcp: MCPManager?, nativeTools: NativeTools?
    private let traces: TraceStore, capture: CaptureDelivery
    private let editingGate=AsyncGate(), runtimeGate=AsyncGate()
    private var sessions:[String:AgentSession]=[:], profiles:[String:(Profile,String)]=[:], sideParents:[String:String]=[:], recency:[String]=[]
    private var tasks:[String:Task<Void,Never>]=[:], fingerprints:[String:String]=[:], replies:[String:JSON]=[:], replyOrder:[String]=[]
    private var mutationLedger = MutationLedger()
    private var dirty:[String:Int]=[:], flushTask:Task<Void,Never>?
    public init(emit: @escaping @Sendable (JSON)->Void) {
        self.emit=emit
        let delivery = CaptureDelivery(epoch: epoch, emit: emit)
        capture=delivery; traces=TraceStore(sink: { await delivery.send($0) })
    }
    public func receive(_ frame: JSON) {
        guard !closing else { return }
        if frame["kind"].text == "capture.ack" {
            guard hello, frame["v"].int == 1, frame["hostEpoch"].text == epoch, let id = frame["transferId"].text, id.utf8.count <= 128 else { return }
            // Detached on purpose: `receive` is synchronous on this actor, and
            // an acknowledgment must reach the delivery actor even while the
            // helper is shutting down — cancelling it would strand the producer
            // that is waiting on this packet until its own deadline.
            Task { await capture.acknowledge(id, accepted: frame["accepted"].flag == true) }; return
        }
        if frame["kind"].text == "hello" {
            guard !hello, frame["v"].int == 1, frame["major"].int == 1 else { emit(["v":1,"kind":"incompatible","message":"Unsupported or repeated handshake"]); return }
            hello=true; allowsDisplayTransfers = frame["displayTransfers"].flag == true; unknownToolOutcomes = frame["unknownToolOutcomes"].flag == true
            emit(["v":1,"kind":"ready","hostEpoch":JSON(epoch),"major":1,"minor":1,"engine":"swift","engineVersion":"1.0.0","piBehaviorReference":"0.85.1","limits":["frameBytes":1048576,"captureBytes":134217728],"capabilities":["runtime.info","sessions","queued-turns","steering","native-host","mcp","responses","transport-capture","workspace-roots","turn-overrides","turn.edit","session.edit.prepare","native-branch-v2","queue.edit","tool-input","queue.read","tool-outcome-unknown","receipt-revisions","tool-input-appends","session-recover","cost-limit","message-versions","fork-at-message"]]); return
        }
        let id=frame["commandId"].text ?? ""
        guard hello, frame["v"].int == 1, frame["kind"].text == "command", frame["hostEpoch"].text == epoch, !id.isEmpty, id.utf8.count <= 128, let method=frame["method"].text, frame["params"].isNull || frame["params"].isObject else { reply(id,.failure(AgentError("invalid_command", "Invalid command or stale host epoch"))); return }
        let fingerprint=sha256(Data(frame.removing(["commandId"]).encoded().utf8))
        let readOnly = method == "display.result.read" || method == "clock.sync" || method == "runtime.info" || method == "resources.inspect" || method == "resources.skill.read" || method.hasPrefix("session.content.") || ["session.status","session.snapshot","session.history","session.versions","session.version.page","session.message.read","session.edit.prepare","session.tool.input","queue.read","session.events","session.event-page","context.info","context.preview","context.preview.read","context.preview.clear","mcp.list","mcp.describe","debug.list","debug.body","debug.attempt","debug.raw-events","session.portable.preview","session.import.inspect"].contains(method)
        if fingerprints[id] == nil {
            if let previous = mutationLedger.fingerprint(for: id) {
                reply(id,.failure(AgentError(previous == fingerprint ? "command_result_expired" : "command_conflict", "Previously observed mutation will not be replayed; reconcile session state"))); return
            }
            if mutationLedger.mayHaveExpired(id) {
                reply(id,.failure(AgentError("command_result_expired", "Command identity matches an expired mutation tombstone (or a conservative hash collision); reconcile session state before any new action"))); return
            }
        }
        if let previous=fingerprints[id] {
            guard previous == fingerprint else { reply(id,.failure(AgentError("command_conflict", "Command identity reused with different arguments"))); return }
            if let cached=replies[id] { emit(cached) }; return
        }
        guard tasks.count<32 || method == "turn.stop" else { reply(id,.failure(AgentError("host_busy", "Too many concurrent commands"))); return }
        if !readOnly {
            mutationLedger.record(id, fingerprint: fingerprint)
        }
        fingerprints[id]=fingerprint
        tasks[id]=Task { [weak self] in
            guard let self else { return }
            do { let result=try await self.command(method,sessionID:frame["sessionId"].text,params:frame["params"].isNull ? [:] : frame["params"],commandID:id); await self.finish(id,.success(result),retain:!readOnly) }
            catch { await self.finish(id,.failure(error as? AgentError ?? AgentError("command_failed", "Command failed: \(error.localizedDescription)")),retain:!readOnly) }
        }
    }
    /// The reply frame for one command. `error` and `result` carry the same
    /// value on a failure: readers written against either field see the error.
    private func replyFrame(_ id: String, _ result: Result<JSON,AgentError>) -> JSON {
        var message: JSON=["v":1,"kind":"reply","hostEpoch":JSON(epoch),"commandId":JSON(id)]
        switch result { case .success(let value): message["ok"]=true; message["result"]=value
        case .failure(let error): message["ok"]=false; message["error"]=error.json;message["result"]=error.json }
        return message
    }
    /// Refuses a command before it starts: nothing is cached, because the
    /// command identity was never accepted.
    private func reply(_ id: String,_ result: Result<JSON,AgentError>) { emit(replyFrame(id,result)) }
    /// Completes an accepted command: the frame is bounded and emitted. A
    /// command that changes something keeps its reply for an identical retry
    /// of the same identity, which must never run it twice. A read keeps
    /// nothing: a retried read simply runs again, so a snapshot page or a
    /// display-transfer chunk (up to 1 MiB each) is not held for 512 replies.
    private func finish(_ id:String,_ result:Result<JSON,AgentError>,retain:Bool) {
        var message=replyFrame(id,result)
        if ((try? message.data().count) ?? 1048577)>1048576 {
            if allowsDisplayTransfers, case .success(let value) = result {
                do { message = replyFrame(id, .success(try displayTransfers.insert(value.data()))) }
                catch { message = replyFrame(id, .failure(error as? AgentError ?? AgentError("display_failed", "Could not prepare the complete display result"))) }
            } else { message = replyFrame(id, .failure(AgentError("reply_limit", "Result exceeds the IPC frame limit; request a smaller range"))) }
        }
        tasks.removeValue(forKey:id)
        if retain {
            replies[id]=message; replyOrder.append(id)
            while replyOrder.count > 512 { let old=replyOrder.removeFirst(); replies.removeValue(forKey:old); fingerprints.removeValue(forKey:old) }
        } else { fingerprints.removeValue(forKey:id) }
        emit(message)
    }
    /// Test seam: the replies kept for an identical retry, and their size.
    var cachedReplies: (count: Int, bytes: Int) { (replies.count, replies.values.reduce(0) { $0 + ((try? $1.data().count) ?? 0) }) }
    /// Test seam: a loaded session.
    func loadedSession(_ id: String) -> AgentSession? { sessions[id] }
    private func mark(_ id:String,_ seq:Int) async {
        // Only a side chat can stop being one (it was kept); every other
        // session's events skip the hop to its actor, once per streamed token.
        if sideParents[id] != nil, let session=sessions[id], !(await session.isEphemeral) { sideParents.removeValue(forKey:id) }
        dirty[id]=max(seq,dirty[id] ?? 0)
        // Owned by `flushTask` and cancelled by `shutdown`, which then flushes
        // once itself, so a pending coalescing window cannot outlive the host.
        if flushTask == nil { flushTask=Task { try? await Task.sleep(nanoseconds:16_000_000); self.flush() } }
    }
    private func flush() { for (id,seq) in dirty { emit(["v":1,"kind":"event","hostEpoch":JSON(epoch),"sessionId":JSON(id),"seq":JSON(seq),"type":"session.changed","payload":[:]]) }; dirty.removeAll(); flushTask=nil }
    /// The callback a session calls on every event. Detached on purpose: the
    /// session is inside its own actor and must not wait on this one. It is
    /// bounded instead of owned — `mark` only records a sequence number, holds
    /// no resource, and drops itself once the host is gone (`weak self`);
    /// retaining one handle per event would cost more than the work it tracks.
    private func notification() -> @Sendable (String,Int)->Void { { [weak self] id, seq in Task { await self?.mark(id,seq) } } }
    private func touch(_ id:String) { recency.removeAll{$0==id}; recency.append(id) }
    public func command(_ method:String, sessionID:String?, params:JSON, commandID:String=UUID().uuidString) async throws -> JSON {
        if method == "display.result.read" { return try displayTransfers.read(required(params["id"],"transfer id"),offset:boundedInt(params["offset"],maximum:DisplayResultTransfers.maximumBytes)) }
        guard !closing else { throw AgentError("closing","Host is shutting down") }
        if method == "runtime.info" { return ["engine":"swift","engineVersion":"1.0.0","piBehaviorReference":"0.85.1","bundledNode":false,"protocolMajor":1,"protocolMinor":1] }
        if method == "clock.sync" { return ["monotonic":JSON(nowMS()),"monotonicMs":JSON(nowMS()),"hostMonotonicMs":JSON(nowMS()),"wallTime":JSON(isoNow())] }
        if method == "workspace.open" {
            guard !opening else { throw AgentError("workspace_busy", "Workspace initialization is already in progress") }
            opening=true; defer { opening=false }
            let requestedRoots=try Self.workspaceRoots(params)
            guard let requested=requestedRoots.first else { throw AgentError("invalid_params", "Workspace roots must list 1 to 16 directories") }
            var state=canonical(try required(params["directory"],"session directory"))
            guard params["resources"]["mcpConfigPath"].isNull, params["resources"]["mcpConfigSHA256"].isNull else {
                throw AgentError("vault_configuration_required", "External MCP configuration files are retired. Configure servers in the native vault.")
            }
            if let cwd { guard cwd == requested, roots.map(\.path) == requestedRoots.map(\.path), directory == state else { throw AgentError("workspace_conflict", "Host is already bound to a different workspace") }; return ["opened":true,"cwd":JSON(cwd.path),"roots":.array(roots.map { JSON($0.path) }),"directory":directory.map { JSON($0.path) } ?? .null] }
            for root in requestedRoots {
                var isDir: ObjCBool=false; guard FileManager.default.fileExists(atPath:root.path,isDirectory:&isDir),isDir.boolValue else { throw AgentError("workspace_missing", "Workspace directory does not exist: \(root.path)") }
            }
            try FileManager.default.createDirectory(at:state,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            // Symlinked prefixes (/var → /private/var) resolve only once the
            // directory exists; bind the resolved path so a repeated open matches.
            state=canonical(state.path)
            let extra=Array(requestedRoots.dropFirst())
            let manager=MCPManager(cwd:requested,roots:extra,outcomeMarker:state.appendingPathComponent(".mcp-outcome-unknown.json"))
            try await manager.configure(params["mcp"].isNull ? ["servers":[:]] : params["mcp"])
            if params["captureProtocol"].int == 1 { await capture.enable() }
            cwd=requested; roots=requestedRoots; directory=state; mcp=manager
            resources=Resources(cwd:requested,roots:extra,options:params["resources"].isNull ? [:] : params["resources"])
            nativeTools=NativeTools(cwd:requested,roots:extra,outputs:state.appendingPathComponent("tool-output"),mcp:manager)
            return ["opened":true,"cwd":JSON(requested.path),"roots":.array(requestedRoots.map { JSON($0.path) }),"directory":JSON(state.path)]
        }
        guard let cwd, let directory, let resources, let mcp, let nativeTools else { throw AgentError("workspace_required", "Open a workspace first") }
        if method == "workspace.quiesce" {
            quiesced=true
            for s in sessions.values { let idle=await s.isIdle, ephemeral=await s.isEphemeral; if !idle || ephemeral { quiesced=false; throw AgentError("session_busy", "A run is active; stop it before updating") } }
            return ["quiesced":true]
        }
        if method == "workspace.resume" { quiesced=false; return ["resumed":true] }
        if method == "resources.configure" {
            try await resources.configure(params["options"].isNull ? [:] : params["options"])
            for session in sessions.values { await session.resourcesChanged() }
            return try await resources.inspect(["refresh":true])
        }
        if method == "resources.inspect" {
            var applied: String?; if let id=sessionID, let session=sessions[id] { applied=await session.resourceRevision }
            let available=await nativeTools.capabilityIDs(readOnly:sessionID.flatMap { sessions[$0]?.readOnly } ?? params["readOnly"].flag ?? false)
            return try await resources.inspect(params,applied:applied,tools:available)
        }
        if method == "resources.skill.read" { return try await resources.readSkill(required(params["skillId"],"skill id"),offset:boundedInt(params["offset"],maximum:262144)) }
        if method == "mcp.configure" {
            for s in sessions.values { guard !(await s.isRunning) else { throw AgentError("session_busy", "Stop active runs before changing MCP connections") } }
            guard params["path"].isNull, params["config"].isObject else { throw AgentError("vault_configuration_required", "MCP configuration must come from the native vault over private IPC.") }
            try await mcp.configure(params["config"])
            for session in sessions.values { await session.resourcesChanged() }
            var result=try await mcp.perform(["action":"list"]);result["configurationSource"]="native vault via private IPC";return result
        }
        if ["mcp.list","mcp.describe"].contains(method) {
            var args=params;args["action"]=JSON(method == "mcp.list" ? "list":"describe");var result=try await mcp.perform(args,readOnly:true)
            result["configurationSource"]="native vault via private IPC";return result
        }
        if method == "mcp.acknowledgeUnknown" { guard params["confirmed"].flag == true else { throw AgentError("confirmation_required","Confirm that the previous invocation outcome has been checked") }; try await mcp.acknowledgeUnknown(); return ["acknowledged":true] }
        if method == "connection.test" {
            guard !quiesced else { throw AgentError("quiesced", "Workspace is quiesced for update") }
            let id = try identity(sessionID.map { JSON($0) } ?? params["sessionId"])
            // Credentials are supplied by the native vault. No profile file,
            // workspace instruction, skill or MCP connection participates.
            let original = try Profile(params["profile"]), (profile, key) = try ProfileFiles.credentials(profile: original, supplied: params["apiKey"].text)
            return try await ConnectionProbe.run(profile: profile, apiKey: key, sessionID: id, client: ProviderClient(traces: traces))
        }
        if method == "session.open" {
            guard !quiesced else { throw AgentError("quiesced", "Workspace is quiesced for update") }
            let id=try identity(sessionID.map { JSON($0) } ?? params["sessionId"])
            // The chat's cost limit, and the spend the app counted for a chat
            // whose journal predates cost records (adopted at most once).
            let costLimit=try AgentSession.costLimit(params["costLimit"]), costSeed=try AgentSession.costSeed(params["costSeed"])
            // The chat's capture mode rides on the open, which saves the app a
            // `debug.mode` round trip before its first turn. The reply names
            // the mode it applied; without one the app sends `debug.mode` itself.
            let captureMode=params["captureMode"].text
            if let captureMode { _=try await traces.command("debug.mode",session:id,params:["mode":JSON(captureMode)]) }
            func withMode(_ snapshot:JSON)->JSON {
                guard let captureMode, case .object(var fields)=snapshot else { return snapshot }
                fields["captureMode"]=JSON(captureMode); return .object(fields)
            }
            try await runtimeGate.acquire()
            do {
                if let existing=sessions[id] {
                    if let costLimit { await existing.setCostLimit(costLimit) }
                    await runtimeGate.release(); return withMode(await existing.snapshot())
                }
                let original=try Profile(params["profile"]), (profile,key)=try ProfileFiles.credentials(profile:original,supplied:params["apiKey"].text)
                let mode=params["toolMode"].text ?? "editing"; guard ["editing","read-only"].contains(mode) else { throw AgentError("tool_mode", "Unknown tool mode") }
                let titleTask = params["backgroundTask"].text == "session-title"
                guard params["backgroundTask"].isNull || titleTask else { throw AgentError("invalid_params", "Unknown background task") }
                let sessionResources = titleTask ? Resources(cwd: cwd, titleTask: true) : resources
                // Opening parses and replays the whole journal. Do it off this
                // actor, which every other chat's commands go through; the
                // runtime gate still serializes opens and closes.
                let tools: any ToolExecuting = titleTask || params["connectionTest"].flag == true ? DisabledTools() : nativeTools
                let client=ProviderClient(traces:traces), traces=traces, gate=editingGate, changed=notification(), resume=params["path"].text, readOnly=titleTask || mode == "read-only", outcomes=unknownToolOutcomes
                let session=try await Task.detached(priority:.userInitiated) {
                    try AgentSession(id:id,profile:profile,apiKey:key,cwd:cwd,directory:directory,readOnly:readOnly,resources:sessionResources,client:client,tools:tools,traces:traces,editingGate:gate,resumePath:resume,autoCompaction:!titleTask,titleTask:titleTask,unknownToolOutcomes:outcomes,changed:changed)
                }.value
                sessions[id]=session; profiles[id]=(profile,key); touch(id)
                if let handoff=params["handoff"]["text"].text, !handoff.isEmpty { try await session.addHandoff(handoff) }
                if let costLimit { await session.setCostLimit(costLimit) }
                if let costSeed { await session.adoptSpendSeed(costSeed) }
                await runtimeGate.release(); return withMode(await session.snapshot())
            } catch { await runtimeGate.release(); throw error }
        }
        if method == "session.portable.preview" || method == "session.import.inspect" { return try portable(params) }
        if method == "session.recover" { return try recoverCopy(params) }
        if method == "session.import.continue" || method == "session.import.recover" { throw AgentError("portable_handoff_required", "Pi journals are preserved read-only. Preview and explicitly create a native portable handoff rather than replaying incompatible provider state.") }
        let id=try identity(sessionID.map { JSON($0) } ?? params["sessionId"])
        if method.hasPrefix("debug.") { return try await traces.command(method,session:id,params:params) }
        if method == "session.forget" {
            if let existing=sessions[id] {
                guard sideParents[id] == nil, !sideParents.values.contains(id), await existing.unloadIfIdle() else { throw AgentError("session_busy","Stop work and close/keep side chats before forgetting") }
                sessions.removeValue(forKey:id);profiles.removeValue(forKey:id);recency.removeAll{$0==id}
            }
            _=try await traces.command("debug.clear",session:id,params:[:]); return ["accepted":true]
        }
        guard let session=sessions[id] else { throw AgentError("session_missing", "Session runtime is not loaded") }; touch(id)
        if method == "turn.stop" { await session.stop(); return ["accepted":true] }
        if method == "session.status" {
            var statusParams = params; statusParams["includeMessages"] = false
            return await session.snapshot(statusParams)
        }
        if method == "session.edit.prepare" { return try await session.prepareEdit(identity(params["messageId"]),offset:boundedInt(params["offset"],maximum:262144),expectedTimeline:params["sourceTimeline"].text,expectedTextDigest:params["sourceTextDigest"].text) }
        if method == "session.snapshot" { return await session.snapshot(params) }
        if method == "context.info" { return await session.inspectContext() }
        if method == "context.preview" { return try await session.prepareContext(params) }
        if method == "context.preview.read" { return try await session.readPreparedContext(params) }
        if method == "context.preview.clear" { await session.clearPreparedContext(params["revision"].text); return ["accepted":true] }
        if method == "session.history" {
            if params["version"].int == 2 { return try await session.historyWindow(params) }
            return await session.historyPage(before:params["before"].int)
        }
        if method == "session.message.read" { return try await session.messageRead(id:required(params["messageId"],"message id"),field:params["field"].text ?? "text",offset:boundedInt(params["offset"],maximum:128*1024*1024)) }
        if method == "session.tool.input" { return try await session.toolInput(messageID:required(params["messageId"],"message id"),callID:required(params["callId"],"tool call id",maximum:256)) }
        if method == "session.content.search" { return try await session.contentSearch(params) }
        if method == "session.content.page" { return try await session.contentPage(params) }
        if method == "session.event-page" || method == "session.events" { return await session.eventPage(since:params["since"].int) }
        // An edited message's versions, and the rows of one of them.
        if method == "session.versions" { return try await session.messageVersions(params) }
        if method == "session.version.page" { return try await session.versionPage(params) }
        if method == "session.fork" {
            guard !quiesced else { throw AgentError("quiesced", "Workspace is quiesced for update") }
            let forkID=try identity(params["forkSessionId"]), costLimit=try AgentSession.costLimit(params["costLimit"])
            // Fork at one assistant reply rather than at the end: the journal up to it.
            let point=params["atMessageId"].isNull ? nil : try identity(params["atMessageId"])
            try await runtimeGate.acquire()
            do {
                guard sessions[forkID] == nil, let (profile,key)=profiles[id] else { throw AgentError("session_conflict", "Fork identity is already in use") }
                let result=try await session.fork(to:forkID,at:point)
                let fork=try await AgentSession(id:forkID,profile:profile,apiKey:key,cwd:cwd,directory:directory,readOnly:session.readOnly,resources:resources,client:ProviderClient(traces:traces),tools:session.isConnectionTest ? DisabledTools() : nativeTools,traces:traces,editingGate:editingGate,resumePath:result["path"].text,unknownToolOutcomes:unknownToolOutcomes,changed:notification())
                sessions[forkID]=fork; profiles[forkID]=(profile,key); touch(forkID)
                // A fork is a chat of its own, with its own limit.
                if let costLimit { await fork.setCostLimit(costLimit) }
                _=try await traces.command("debug.mode",session:forkID,params:["mode":JSON(await traces.mode(id))])
                await runtimeGate.release(); return result
            } catch { await runtimeGate.release(); throw error }
        }
        if method == "side.open" {
            guard !quiesced else { throw AgentError("quiesced", "Workspace is quiesced for update") }
            guard sideParents[id] == nil else { throw AgentError("nested_side", "Nested side chats are not supported") }
            let sideID=try identity(params["sideSessionId"]), costLimit=try AgentSession.costLimit(params["costLimit"])
            try await runtimeGate.acquire()
            do {
                if let existing=sideParents.first(where:{$0.value==id})?.key, let side=sessions[existing] { await runtimeGate.release(); return ["accepted":true,"sessionId":JSON(existing),"side":await side.snapshot()["side"],"ephemeral":true] }
                guard sessions[sideID] == nil, let (profile,key)=profiles[id] else { throw AgentError("side_conflict", "Side identity is already in use") }
                let seed=await session.sideSeed()
                let side=try AgentSession(id:sideID,profile:profile,apiKey:key,cwd:cwd,directory:directory,readOnly:true,resources:resources,client:ProviderClient(traces:traces),tools:nativeTools,traces:traces,editingGate:editingGate,seed:seed.messages,parent:seed.info,unknownToolOutcomes:unknownToolOutcomes,changed:notification())
                // A side is a session of its own: its own spend and limit.
                if let costLimit { await side.setCostLimit(costLimit) }
                let saved=try await side.preserveSide()
                sessions[sideID]=side; profiles[sideID]=(profile,key); touch(sideID)
                _=try await traces.command("debug.mode",session:sideID,params:["mode":JSON(await traces.mode(id))])
                await runtimeGate.release(); return ["accepted":true,"sessionId":JSON(sideID),"side":seed.info,"ephemeral":false,"path":saved["path"]]
            } catch { await runtimeGate.release(); throw error }
        }
        if method == "side.keep" { let result=try await session.keep(whenFinished:params["whenFinished"].flag == true); if !(await session.isEphemeral) { sideParents.removeValue(forKey:id) }; return result }
        if method == "side.close" {
            let saved=try await session.preserveSide(); sideParents.removeValue(forKey:id)
            // This closes presentation only. The durable runtime and any active
            // work stay available as an ordinary saved child conversation.
            return saved
        }
        guard !quiesced, !closing else { throw AgentError("closing", "Host is closing or quiesced") }
        if method == "turn.submit" || method == "turn.steer" || method == "turn.edit" {
            let text=params["text"].text ?? "", tools=await nativeTools.capabilityIDs(readOnly:session.readOnly)
            let selected=try await resources.freeze(params["skills"].list,text:text,tools:tools)
            let overrides=try Self.turnOverrides(params)
            let input=Submission(commandID:commandID,turnID:try identity(params["clientTurnId"]),text:text,attachments:params["attachments"].list,skills:selected,model:overrides.model,thinkingLevel:overrides.thinkingLevel,contextWindow:overrides.contextWindow,maxOutputTokens:overrides.maxOutputTokens,modelOutputLimit:overrides.modelOutputLimit)
            if method == "turn.edit" { return try await session.edit(fromMessageID:try identity(params["messageId"]),input:input,expectedTimeline:params["editSourceTimeline"].text,expectedTextDigest:params["editSourceTextDigest"].text) }
            return try await session.submit(input,steer:method == "turn.steer")
        }
        if method == "queue.remove" { try await session.removeQueued(required(params["turnId"],"turn id")); return ["accepted":true] }
        if method == "queue.reorder" {
            let order=try params["turnIds"].list.map { try required($0,"turn id") }
            try await session.reorderQueue(order); return ["accepted":true]
        }
        if method == "queue.read" { return try await session.queuedText(required(params["turnId"],"turn id")) }
        if method == "queue.update" { try await session.updateQueued(required(params["turnId"],"turn id"),text:params["text"].text ?? ""); return ["accepted":true] }
        if method == "queue.steer" { try await session.steerQueued(required(params["turnId"],"turn id")); return ["accepted":true] }
        if method == "queue.resume" { try await session.resumeQueue(); return ["accepted":true] }
        if method == "turn.retry" { try await session.retryRun(overrides: params); return ["accepted":true] }
        if method == "queue.configure" { try await session.configureQueue(params); return ["accepted":true] }
        if method == "context.compact" { try await session.compact(commandID:commandID,overrides:params.removing(["focus"]),focus:params["focus"].text); return ["accepted":true] }
        if method == "mcp.invoke" { var args=params; args["action"]="invoke"; return try await mcp.perform(args,readOnly:session.readOnly) }
        if method == "session.configure" {
            // The chat's cost limit applies at once, also to a running session:
            // its next model request is checked against it. A configure that
            // carries only the limit leaves the connection as it is.
            let costLimit=try AgentSession.costLimit(params["costLimit"])
            if costLimit != nil, params["profile"].isNull {
                if let costLimit { await session.setCostLimit(costLimit) }
                return ["accepted":true,"applied":true]
            }
            // A saved connection reaches its open sessions without a close: an idle
            // one switches now, a running one when its run ends.
            let original=try Profile(params["profile"]), (profile,key)=try ProfileFiles.credentials(profile:original,supplied:params["apiKey"].text)
            let applied=try await session.configure(profile:profile,apiKey:key)
            profiles[id]=(profile,key)
            if let costLimit { await session.setCostLimit(costLimit) }
            return ["accepted":true,"applied":JSON(applied)]
        }
        if method == "session.close" {
            guard sideParents[id] == nil, !sideParents.values.contains(id), await session.unloadIfIdle() else { throw AgentError("session_busy", "Stop work and close/keep side chats before unloading") }
            sessions.removeValue(forKey:id); profiles.removeValue(forKey:id); recency.removeAll{$0==id}; return ["accepted":true]
        }
        throw AgentError("unsupported_command", "Unsupported native host command: \(method)")
    }
    /// `roots` (1…16 absolute directories, primary first) or the legacy single
    /// `cwd`. Duplicates collapse after canonicalization; order is preserved.
    static func workspaceRoots(_ params: JSON) throws -> [URL] {
        if params["roots"].isNull { return [canonical(try required(params["cwd"],"workspace"))] }
        let list=params["roots"].list
        guard !list.isEmpty, list.count <= 16 else { throw AgentError("invalid_params", "Workspace roots must list 1 to 16 directories") }
        var result: [URL]=[], seen=Set<String>()
        for item in list {
            let path=try required(item,"workspace root")
            guard path.hasPrefix("/") else { throw AgentError("invalid_params", "Workspace roots must be absolute paths") }
            let url=canonical(path); if seen.insert(url.path).inserted { result.append(url) }
        }
        if let cwd=params["cwd"].text, !cwd.isEmpty, canonical(cwd) != result.first { throw AgentError("invalid_params", "cwd must be the primary workspace root") }
        return result
    }
    /// Optional per-turn model, thinking and model-specific capacity overrides.
    static func turnOverrides(_ params: JSON) throws -> (model: String?, thinkingLevel: String?, contextWindow: Int?, maxOutputTokens: Int?, modelOutputLimit: Int?) {
        var model: String?, level: String?
        if !params["model"].isNull {
            guard let text=params["model"].text, !text.isEmpty, text.utf8.count <= 200, !text.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw AgentError("invalid_params", "Invalid model override") }
            model=text
        }
        if !params["thinkingLevel"].isNull {
            guard let text=params["thinkingLevel"].text, Profile.thinkingLevels.contains(text) else { throw AgentError("invalid_params", "Invalid thinking level override") }
            level=text
        }
        func limit(_ name: String, maximum: Int) throws -> Int? {
            if params[name].isNull { return nil }
            guard let value=params[name].int, value > 0, value <= maximum else { throw AgentError("invalid_params", "Invalid turn \(name) override") }
            return value
        }
        return (model,level,try limit("contextWindow",maximum:10_000_000),try limit("maxOutputTokens",maximum:1_000_000),try limit("modelOutputLimit",maximum:1_000_000))
    }
    /// A journal whose last record was cut off (a power loss or a full disk
    /// mid-write) cannot be reopened. This copies every complete record,
    /// checked to be one intact native branch, to a new journal under a new
    /// session id in the same project, and leaves the original untouched.
    /// Anything wrong before the last record is still refused.
    private func recoverCopy(_ params:JSON) throws -> JSON {
        guard let directory else { throw AgentError("workspace_closed","Open the project before recovering a chat") }
        let sessions=canonical(directory.path), source=canonical(try required(params["path"],"session path"))
        guard within(source,sessions) else { throw AgentError("invalid_path","Only this project's own chats can be recovered") }
        let id=try identity(params["newSessionId"]), destination=sessions.appendingPathComponent(id+".jsonl")
        let data=try readBounded(source,maximum:128*1024*1024)
        guard let end=data.lastIndex(of:10) else { throw AgentError("session_damaged","No complete record to recover") }
        var records:[JSON]=[], last:String?, seen=Set<String>()
        for line in data[..<end].split(separator:10) {
            guard line.count <= 32*1024*1024 else { throw AgentError("session_damaged","Journal record exceeds limit") }
            records.append(try JSON.parse(Data(line)))
        }
        guard var header=records.first, header["type"].text == "session", header["version"].int == 3,
              records.contains(where:{ $0["customType"].text == "pi-app.native.v1" }) else { throw AgentError("legacy_session","Only a native chat can be recovered this way") }
        for item in records.dropFirst() {
            let rid=try identity(item["id"])
            guard seen.insert(rid).inserted, item["parentId"].text == last else { throw AgentError("session_damaged","The journal is damaged before its last record; nothing was recovered") }
            last=rid
        }
        header["id"]=JSON(id)
        var copy=try header.data(); copy.append(10)
        if let first=data[..<end].firstIndex(of:10), first < end { copy.append(data[data.index(after:first)...end]) }
        // Written beside the destination, then linked into place: an existing
        // chat of that id is never replaced and a failed write leaves nothing.
        let temporary=sessions.appendingPathComponent(".recover-\(UUID().uuidString).jsonl")
        let fd=open(temporary.path,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw AgentError("session_write","Cannot create the recovered copy") }
        let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer { try? FileManager.default.removeItem(at:temporary) }
        try file.write(contentsOf:copy); try file.synchronize(); try file.close()
        guard link(temporary.path,destination.path) == 0 else { throw AgentError("session_exists","A chat with that identity already exists") }
        return ["sessionId":JSON(id),"sessionFile":JSON(destination.path),"records":JSON(records.count-1),"omittedBytes":JSON(data.count-end-1)]
    }
    private func portable(_ params:JSON) throws -> JSON {
        let file=canonical(try required(params["path"],"session path")), data=try readBounded(file,maximum:128*1024*1024)
        var records:[String:JSON]=[:], leaf:String?, header:JSON=[:]
        guard data.last==10 else { throw AgentError("incomplete_history","History has an incomplete tail. Preserve and review it before making a portable handoff.") }
        for (i,line) in data.split(separator:10).enumerated() {
            let item=try JSON.parse(Data(line))
            if i==0 { guard item["type"].text=="session" else { throw AgentError("invalid_history","Expected session header") };header=item;continue }
            guard records.count<100000,let id=item["id"].text,records[id]==nil else { throw AgentError("invalid_history","Invalid or duplicate journal identity") }
            if let parent=item["parentId"].text,records[parent]==nil { throw AgentError("invalid_history","Journal parent is missing") }
            records[id]=item;leaf=id
        }
        var chain:[JSON]=[],cursor=leaf
        while let id=cursor,let record=records[id] { chain.append(record);cursor=record["parentId"].text }
        chain.reverse()
        if chain.contains(where: { $0["customType"].text == "pi-app.native.v1" }) {
            let replay = try ConversationReplay(chain)
            let messages = replay.context.map { "[\($0.role)]\n" + ($0.displayText ?? $0.text) }
            let text = messages.suffix(40).joined(separator: "\n\n"), retained = preview(text, bytes: 65536)
            return ["path":JSON(file.path),"sessionId":header["id"],"nativeReplay":false,"damaged":false,"text":JSON(retained),"draft":JSON(retained),"truncated":JSON(retained.utf8.count < text.utf8.count || messages.count > 40),"provenance":["sourcePath":JSON(file.path),"sourceSHA256":JSON(sha256(data)),"portable":true],"notice":"Portable text of the selected branch. Original unchanged. Review before sending.","sha256":JSON(sha256(data))]
        }
        // Select the active leaf only, then replay compaction and branch
        // boundaries in order so the preview shows the live context.
        var active:[JSON]=[]
        for item in chain {
            if item["type"].text=="compaction" {
                var kept:[JSON]=[]
                if !item["nativeKeptIDs"].isNull {
                    let ids=try CompactionCheckpoint.identities(item["nativeKeptIDs"])
                    let candidates=active.filter { ["message","compaction"].contains($0["type"].text ?? "") }
                    let messages=try candidates.map { record -> ChatMessage in
                        if record["type"].text=="message" { return try ChatMessage(id:identity(record["id"]),pi:record["message"]) }
                        var message=ChatMessage(role:"system",content:[textBlock(record["summary"].text ?? "")]); message.id=try identity(record["id"]); return message
                    }
                    _=try CompactionCheckpoint.restore(item,context:messages)
                    let byID=Dictionary(candidates.map { ($0["id"].text ?? "",$0) },uniquingKeysWith:{_,b in b})
                    kept=ids.compactMap { byID[$0] }
                } else if let first=item["firstKeptEntryId"].text,let index=active.firstIndex(where:{$0["id"].text==first}) { kept=Array(active[index...]) }
                active=[item]+kept
            } else if item["type"].text=="branch" {
                let ids=Set(item["keptIds"].list.compactMap(\.text));active=active.filter{ids.contains($0["id"].text ?? "")}
            } else if item["customType"].text=="pi-app.native.context.v1" {
                let ids=try CompactionCheckpoint.identities(item["data"]["ids"])
                active=try ids.map { id in guard let record=records[id] else { throw AgentError("session_damaged","Missing context reference") }; return record }
            } else { active.append(item) }
        }
        var messages:[String]=[]
        for item in active {
            if item["type"].text=="message",let message=try? ChatMessage(id:item["id"].text ?? UUID().uuidString,pi:item["message"]) { messages.append("[\(message.role)]\n"+(message.displayText ?? message.text)) }
            if item["type"].text=="compaction" { messages.append("[summary]\n"+(item["summary"].text ?? "")) }
        }
        let text=messages.suffix(40).joined(separator:"\n\n"),retained=preview(text,bytes:65536)
        return ["path":JSON(file.path),"sessionId":header["id"],"nativeReplay":false,"damaged":false,"text":JSON(retained),"draft":JSON(retained),"truncated":JSON(retained.utf8.count<text.utf8.count || messages.count>40),"provenance":["sourcePath":JSON(file.path),"sourceSHA256":JSON(sha256(data)),"portable":true],"notice":"Portable text only, active branch and latest compaction. Opaque reasoning, executable state and permissions are not transferred. Original unchanged. Review before sending.","sha256":JSON(sha256(data))]
    }
    public func shutdown() async {
        // Acknowledgments are dropped from here on (see `receive`): a capture
        // must not hold a stopped run's partial reply and final state.
        closing=true; await capture.close(); flushTask?.cancel(); for t in tasks.values { t.cancel() }
        for s in sessions.values { await s.stop() }; for s in sessions.values { await s.close() }; await mcp?.close(); sessions.removeAll(); profiles.removeAll(); flush()
    }
}
