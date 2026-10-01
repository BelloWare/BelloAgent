import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// What the helper says of itself in its ready frame, `runtime.info` and
/// `--version`, and the protocol's frame limit, which both sides keep.
public enum HostProtocol {
    /// The largest frame either side writes, without its newline: 1 MiB.
    public static let frameBytes = 1_048_576
    public static let engineVersion = "1.0.0"
    /// The pi release whose behaviour the helper follows.
    public static let piBehaviorReference = "0.85.1"
}

/// What the service hands its writer: a frame the writer encodes (every event,
/// and a refusal before a command is accepted), or a command's reply already
/// encoded, once, when its size was checked against the frame limit. Encoded
/// bytes carry no newline; the writer adds it.
public enum HostOutput: Sendable {
    case frame(JSON)
    case encoded(Data)
}

public struct NDJSONDecoder {
    private var buffer=Data()
    public init() {}
    public mutating func feed(_ bytes: Data) throws -> [JSON] {
        buffer.append(bytes); var result:[JSON]=[]
        while let nl=buffer.firstIndex(of:10) {
            guard nl > 0, nl <= HostProtocol.frameBytes else { throw AgentError("invalid_frame", "Protocol frame exceeds limit or is empty") }
            let data=Data(buffer[..<nl]); buffer.removeSubrange(...nl)
            guard String(data:data,encoding:.utf8) != nil else { throw AgentError("invalid_frame", "Protocol frame is not UTF-8") }
            let value=try JSON.parse(data); guard value.isObject else { throw AgentError("invalid_frame", "Protocol frame must be an object") }; result.append(value)
        }
        guard buffer.count <= HostProtocol.frameBytes else { throw AgentError("invalid_frame", "Protocol frame exceeds 1 MiB") }; return result
    }
    public func finish() throws { if !buffer.isEmpty { throw AgentError("invalid_frame", "Incomplete protocol frame at EOF") } }
}

/// All commands enter one actor; model calls run in independent session actors.
/// A command ID is content-bound for this host epoch and replay never repeats it.
public actor NativeHostService {
    public let epoch=UUID().uuidString
    private let output: @Sendable (HostOutput)->Void
    private var hello=false, closing=false, quiesced=false, opening=false
    private var displayTransfers = DisplayResultTransfers()
    private var allowsDisplayTransfers = false
    /// Set by a reader whose hello says it shows the `unknown` tool card state.
    private var unknownToolOutcomes = false
    private var cwd: URL?, roots: [URL]=[], directory: URL?, resources: Resources?, mcp: MCPManager?, nativeTools: NativeTools?
    private let traces: TraceStore, capture: CaptureDelivery
    private let editingGate=AsyncGate(), runtimeGate=AsyncGate()
    private var sessions:[String:AgentSession]=[:], profiles:[String:(Profile,String)]=[:]
    /// Journals being slimmed (`JournalSlimming`), by session: an open of one waits for it.
    private var slimming:[String:Task<JournalSlimming.Outcome,Error>]=[:]
    private var tasks:[String:Task<Void,Never>]=[:], fingerprints:[String:String]=[:], replies:[String:HostOutput]=[:], replyOrder:[String]=[]
    private var mutationLedger = MutationLedger()
    private var dirty:[String:Int]=[:], flushTask:Task<Void,Never>?
    public init(output: @escaping @Sendable (HostOutput)->Void) {
        self.output=output
        let delivery = CaptureDelivery(epoch: epoch, emit: { output(.frame($0)) })
        capture=delivery; traces=TraceStore(sink: { await delivery.send($0) })
    }
    /// A reader of whole frames, as the tests are: an encoded reply is handed
    /// over as the value it encodes.
    public init(emit: @escaping @Sendable (JSON)->Void) {
        self.init(output: { output in
            switch output {
            case .frame(let frame): emit(frame)
            case .encoded(let bytes):
                guard let frame = try? JSON.parse(bytes) else { preconditionFailure("An encoded reply does not parse back") }
                emit(frame)
            }
        })
    }
    private func emit(_ frame: JSON) { output(.frame(frame)) }
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
            emit(["v":1,"kind":"ready","hostEpoch":JSON(epoch),"major":1,"minor":1,"engine":"swift","engineVersion":JSON(HostProtocol.engineVersion),"piBehaviorReference":JSON(HostProtocol.piBehaviorReference),"limits":["frameBytes":JSON(HostProtocol.frameBytes)],"capabilities":["runtime.info","sessions","queued-turns","steering","native-host","mcp","responses","transport-capture","workspace-roots","turn-overrides","turn.edit","session.edit.prepare","native-branch-v2","queue.edit","tool-input","queue.read","tool-outcome-unknown","receipt-revisions","tool-input-appends","session-recover","cost-limit","message-versions","fork-at-message"]]); return
        }
        let id=frame["commandId"].text ?? ""
        guard hello, frame["v"].int == 1, frame["kind"].text == "command", frame["hostEpoch"].text == epoch, !id.isEmpty, id.utf8.count <= 128, let method=frame["method"].text, frame["params"].isNull || frame["params"].isObject else { reply(id,.failure(AgentError("invalid_command", "Invalid command or stale host epoch"))); return }
        let fingerprint=sha256(Data(frame.removing(["commandId"]).encoded().utf8))
        let readOnly = Self.isReadOnly(method)
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
            if let cached=replies[id] { output(cached) }; return
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
    static func replyFrame(epoch: String, _ id: String, _ result: Result<JSON,AgentError>) -> JSON {
        var message: JSON=["v":1,"kind":"reply","hostEpoch":JSON(epoch),"commandId":JSON(id)]
        switch result { case .success(let value): message["ok"]=true; message["result"]=value
        case .failure(let error): message["ok"]=false; message["error"]=error.json;message["result"]=error.json }
        return message
    }
    private func replyFrame(_ id: String, _ result: Result<JSON,AgentError>) -> JSON { Self.replyFrame(epoch: epoch, id, result) }
    /// A command's reply as it is written, encoded once: its bytes, when they
    /// fit the frame limit. A reply that does not fit, or does not encode (a
    /// number JSON cannot hold), becomes a display transfer (`transfer`, when
    /// the reader takes them) or an error, as before. Only a replacement that
    /// cannot be encoded either is left for the writer, which stops the helper.
    static func boundedReply(epoch: String, _ id: String, _ result: Result<JSON,AgentError>, transfer: ((Data) throws -> JSON)?) -> HostOutput {
        if let bytes = try? replyFrame(epoch: epoch, id, result).data(), bytes.count <= HostProtocol.frameBytes { return .encoded(bytes) }
        let message: JSON
        if let transfer, case .success(let value) = result {
            do { message = replyFrame(epoch: epoch, id, .success(try transfer(value.data()))) }
            catch { message = replyFrame(epoch: epoch, id, .failure(error as? AgentError ?? AgentError("display_failed", "Could not prepare the complete display result"))) }
        } else { message = replyFrame(epoch: epoch, id, .failure(AgentError("reply_limit", "Result exceeds the IPC frame limit; request a smaller range"))) }
        return (try? message.data()).map(HostOutput.encoded) ?? .frame(message)
    }
    /// Refuses a command before it starts: nothing is cached, because the
    /// command identity was never accepted.
    private func reply(_ id: String,_ result: Result<JSON,AgentError>) { emit(replyFrame(id,result)) }
    /// Completes an accepted command: the frame is bounded and emitted. A
    /// command that changes something keeps its reply for an identical retry
    /// of the same identity, which must never run it twice. A read keeps
    /// nothing: a retried read simply runs again, so a snapshot page or a
    /// display-transfer chunk (up to 1 MiB each) is not held for 512 replies.
    ///
    /// The reply is encoded once (`boundedReply`): the bytes whose size is
    /// checked are the bytes written, and a retry writes them again.
    private func finish(_ id:String,_ result:Result<JSON,AgentError>,retain:Bool) {
        let frame = Self.boundedReply(epoch: epoch, id, result, transfer: allowsDisplayTransfers ? { try self.displayTransfers.insert($0) } : nil)
        tasks.removeValue(forKey:id)
        if retain {
            replies[id]=frame; replyOrder.append(id)
            while replyOrder.count > 512 { let old=replyOrder.removeFirst(); replies.removeValue(forKey:old); fingerprints.removeValue(forKey:old) }
        } else { fingerprints.removeValue(forKey:id) }
        output(frame)
    }
    /// Test seam: the replies kept for an identical retry, and their size.
    var cachedReplies: (count: Int, bytes: Int) {
        (replies.count, replies.values.reduce(0) { total, reply in
            switch reply {
            case .encoded(let bytes): return total + bytes.count
            case .frame(let frame): return total + ((try? frame.data().count) ?? 0)
            }
        })
    }
    /// Test seam: a loaded session.
    func loadedSession(_ id: String) -> AgentSession? { sessions[id] }
    private func mark(_ id:String,_ seq:Int) {
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
    /// A chat's runtime, built off this actor, which every other chat's
    /// commands go through: opening a chat or a fork parses and replays its
    /// whole journal. (A side starts from its parent's context instead.)
    private func makeSession(_ id: String, profile: Profile, apiKey: String, readOnly: Bool, resources: Resources, tools: any ToolExecuting, resumePath: String? = nil, prepared: JournalReplayConsumer? = nil, seed: [ChatMessage]? = nil, parent: JSON = .null, titleTask: Bool = false, utilityPurpose: String = "title") async throws -> AgentSession {
        guard let cwd, let directory else { throw AgentError("workspace_required", "Open a workspace first") }
        let client=ProviderClient(traces:traces), traces=traces, gate=editingGate, outcomes=unknownToolOutcomes, changed=notification()
        return try await Task.detached(priority:.userInitiated) {
            try AgentSession(id:id,profile:profile,apiKey:apiKey,cwd:cwd,directory:directory,readOnly:readOnly,resources:resources,client:client,tools:tools,traces:traces,editingGate:gate,resumePath:resumePath,prepared:prepared,seed:seed,parent:parent,autoCompaction:!titleTask,titleTask:titleTask,utilityPurpose:utilityPurpose,unknownToolOutcomes:outcomes,changed:changed)
        }.value
    }
    /// Runs `body` holding the runtime gate, which serializes opens, forks
    /// and sides, and releases the gate however `body` ends.
    private func withRuntimeGate<T>(_ body: () async throws -> T) async throws -> T {
        try await runtimeGate.acquire()
        do { let value=try await body(); await runtimeGate.release(); return value }
        catch { await runtimeGate.release(); throw error }
    }
    /// The read-only commands: a repeat runs one again, where a command that
    /// changes something is answered from the reply it was first sent
    /// (`receive`). Every `session.content.` command reads too.
    static let readOnlyMethods: Set<String> = ["display.result.read","clock.sync","runtime.info","resources.inspect","resources.skill.read","session.status","session.snapshot","session.history","session.versions","session.version.page","session.message.read","session.edit.prepare","session.tool.input","queue.read","session.events","session.event-page","context.info","context.preview","context.preview.read","context.preview.clear","mcp.list","mcp.describe","debug.list","debug.body","debug.attempt","debug.raw-events","session.portable.preview","session.import.inspect"]
    static func isReadOnly(_ method: String) -> Bool { readOnlyMethods.contains(method) || method.hasPrefix("session.content.") }
    /// Runs one command. The host checks, in this order, that it is not
    /// closing, that a workspace is open, that the command names a session,
    /// that the session is loaded and that the workspace is not quiesced,
    /// and answers each command in the stage after the last check it needs
    /// (`HostDispatchTests`). A command no stage knows meets every check.
    public func command(_ method:String, sessionID:String?, params:JSON, commandID:String=UUID().uuidString) async throws -> JSON {
        // Read even while the host closes: the rest of a result already sent.
        if method == "display.result.read" { return try displayTransfers.read(required(params["id"],"transfer id"),offset:boundedInt(params["offset"],maximum:DisplayResultTransfers.maximumBytes)) }
        guard !closing else { throw AgentError("closing","Host is shutting down") }
        if let result=try await hostCommand(method,params:params) { return result }
        guard let cwd, let directory, let resources, let mcp, let nativeTools else { throw AgentError("workspace_required", "Open a workspace first") }
        let workspace=OpenWorkspace(cwd:cwd,directory:directory,resources:resources,mcp:mcp,nativeTools:nativeTools)
        if let result=try await workspaceCommand(method,sessionID:sessionID,params:params,in:workspace) { return result }
        let id=try identity(sessionID.map { JSON($0) } ?? params["sessionId"])
        if let result=try await namedSessionCommand(method,id:id,params:params) { return result }
        guard let session=sessions[id] else { throw AgentError(AgentErrorCode.sessionMissing, "Session runtime is not loaded") }
        if let result=try await sessionCommand(method,id:id,session:session,params:params,in:workspace) { return result }
        guard !quiesced, !closing else { throw AgentError("closing", "Host is closing or quiesced") }
        if let result=try await changeCommand(method,id:id,session:session,params:params,commandID:commandID,in:workspace) { return result }
        throw AgentError("unsupported_command", "Unsupported native host command: \(method)")
    }
    /// The background tasks a chat can be opened for, each a utility request
    /// (`AgentSession.titleTask`), and the purpose each is logged under.
    static let utilityPurposes = ["session-title": "title", "title-suggestions": "title-suggestions", "webhook": "webhook"]
    /// The open workspace, as the commands that need one see it.
    private struct OpenWorkspace { let cwd: URL, directory: URL, resources: Resources, mcp: MCPManager, nativeTools: NativeTools }
    /// Commands a host that is not closing answers without a workspace.
    private func hostCommand(_ method:String, params:JSON) async throws -> JSON? {
        switch method {
        case "runtime.info": return ["engine":"swift","engineVersion":JSON(HostProtocol.engineVersion),"piBehaviorReference":JSON(HostProtocol.piBehaviorReference),"bundledNode":false,"protocolMajor":1,"protocolMinor":1]
        case "clock.sync": return ["monotonic":JSON(nowMS()),"monotonicMs":JSON(nowMS()),"hostMonotonicMs":JSON(nowMS()),"wallTime":JSON(isoNow())]
        case "workspace.open":
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
        default: return nil
        }
    }
    /// Commands on the open workspace, and on chats that are not open here.
    private func workspaceCommand(_ method:String, sessionID:String?, params:JSON, in workspace:OpenWorkspace) async throws -> JSON? {
        let cwd=workspace.cwd, directory=workspace.directory, resources=workspace.resources, mcp=workspace.mcp, nativeTools=workspace.nativeTools
        switch method {
        case "workspace.quiesce":
            quiesced=true
            for s in sessions.values { await s.cancelHistoryFill() }
            for s in sessions.values { let idle=await s.isIdle, ephemeral=await s.isEphemeral; if !idle || ephemeral { quiesced=false; throw AgentError("session_busy", "A run is active; stop it before updating") } }
            return ["quiesced":true]
        case "workspace.resume": quiesced=false; return ["resumed":true]
        case "resources.configure":
            try await resources.configure(params["options"].isNull ? [:] : params["options"])
            for session in sessions.values { await session.resourcesChanged() }
            return try await resources.inspect(["refresh":true])
        case "resources.inspect":
            var applied: String?; if let id=sessionID, let session=sessions[id] { applied=await session.resourceRevision }
            let available=await nativeTools.capabilityIDs(readOnly:sessionID.flatMap { sessions[$0]?.readOnly } ?? params["readOnly"].flag ?? false)
            return try await resources.inspect(params,applied:applied,tools:available)
        case "resources.skill.read": return try await resources.readSkill(required(params["skillId"],"skill id"),offset:boundedInt(params["offset"],maximum:262144))
        case "mcp.configure":
            for s in sessions.values { guard !(await s.isRunning) else { throw AgentError("session_busy", "Stop active runs before changing MCP connections") } }
            guard params["path"].isNull, params["config"].isObject else { throw AgentError("vault_configuration_required", "MCP configuration must come from the native vault over private IPC.") }
            try await mcp.configure(params["config"])
            for session in sessions.values { await session.resourcesChanged() }
            var result=try await mcp.perform(["action":"list"]);result["configurationSource"]="native vault via private IPC";return result
        case "mcp.list", "mcp.describe":
            var args=params;args["action"]=JSON(method == "mcp.list" ? "list":"describe");var result=try await mcp.perform(args,readOnly:true)
            result["configurationSource"]="native vault via private IPC";return result
        case "mcp.acknowledgeUnknown": guard params["confirmed"].flag == true else { throw AgentError("confirmation_required","Confirm that the previous invocation outcome has been checked") }; try await mcp.acknowledgeUnknown(); return ["acknowledged":true]
        case "connection.test":
            guard !quiesced else { throw AgentError("quiesced", "Workspace is quiesced for update") }
            let id = try identity(sessionID.map { JSON($0) } ?? params["sessionId"])
            // Credentials are supplied by the native vault. No profile file,
            // workspace instruction, skill or MCP connection participates.
            let original = try Profile(params["profile"]), (profile, key) = try ProfileFiles.credentials(profile: original, supplied: params["apiKey"].text)
            return try await ConnectionProbe.run(profile: profile, apiKey: key, sessionID: id, client: ProviderClient(traces: traces))
        case "session.open":
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
            // A journal being slimmed is opened once its copy has taken its place, or not.
            if let slim=slimming[id] { _=await slim.result }
            // The snapshot is taken once the gate is free again.
            let session: AgentSession = try await withRuntimeGate {
                if let existing=sessions[id] {
                    // A chat moved to another connection is opened there, never
                    // answered by its session on the old one, which the app
                    // closes before the move.
                    if let requested=params["profile"]["id"].text, let loaded=profiles[id]?.0.id, requested != loaded {
                        throw AgentError("session_conflict", "This chat is open on another connection. Close it before opening it on this one.")
                    }
                    if let costLimit { await existing.setCostLimit(costLimit) }
                    return existing
                }
                let original=try Profile(params["profile"]), (profile,key)=try ProfileFiles.credentials(profile:original,supplied:params["apiKey"].text)
                let mode=params["toolMode"].text ?? "editing"; guard ["editing","read-only"].contains(mode) else { throw AgentError("tool_mode", "Unknown tool mode") }
                // Utility requests: a chat's title, titles to choose from, or a
                // webhook's notification, by the purpose the request log names.
                let background = params["backgroundTask"].text.flatMap { Self.utilityPurposes[$0] }
                let utility = background ?? "title", titleTask = background != nil
                guard params["backgroundTask"].isNull || titleTask else { throw AgentError("invalid_params", "Unknown background task") }
                let sessionResources = titleTask ? Resources(cwd: cwd, titleTask: true, utility: utility) : resources
                let tools: any ToolExecuting = titleTask || params["connectionTest"].flag == true ? DisabledTools() : nativeTools
                let session=try await makeSession(id,profile:profile,apiKey:key,readOnly:titleTask || mode == "read-only",resources:sessionResources,tools:tools,resumePath:params["path"].text,titleTask:titleTask,utilityPurpose:utility)
                sessions[id]=session; profiles[id]=(profile,key)
                if let handoff=params["handoff"]["text"].text, !handoff.isEmpty { try await session.addHandoff(handoff) }
                if let costLimit { await session.setCostLimit(costLimit) }
                if let costSeed { await session.adoptSpendSeed(costSeed) }
                return session
            }
            return withMode(await session.snapshot())
        case "session.rebind":
            // A saved chat moved to another connection: its journal is bound
            // to the new one before the app says the chat is there, so the
            // chat opens wherever its record names (`SessionJournal.rebind`).
            guard !quiesced else { throw AgentError("quiesced", "Workspace is quiesced for update") }
            let id=try identity(sessionID.map { JSON($0) } ?? params["sessionId"])
            let url=canonical(try required(params["path"],"journal path"))
            guard within(url,canonical(directory.path)), url.pathExtension == "jsonl" else { throw AgentError("session_scope", "Only this workspace's own journals move to another connection") }
            let target=try Profile(params["profile"])
            // With the connection it is on, a check first: how many replies
            // hold reasoning only that connection can be sent, which the app
            // asks about before it moves the chat; nothing is written.
            // A connection that cannot be used any more (an older API) replays nothing.
            let previous=params["previousProfile"].isNull ? nil : try? Profile(params["previousProfile"]), check=params["check"].flag == true
            if let slim=slimming[id] { _=await slim.result }
            return try await withRuntimeGate {
                guard sessions[id] == nil, slimming[id] == nil else { throw AgentError("session_busy", "Close this chat before moving it to another connection") }
                return try await Task.detached(priority:.userInitiated) { try Self.rebind(url:url, id:id, directory:directory, to:target, from:previous, check:check) }.value
            }
        case "session.portable.preview", "session.import.inspect": return try portable(params)
        case "session.recover": return try recoverCopy(params)
        case "journal.slim":
            // A chat's journal without the run-state records that repeated its
            // receipts (`JournalSlimming`), for a chat not open here.
            let id=try identity(sessionID.map { JSON($0) } ?? params["sessionId"])
            let url=canonical(try required(params["path"],"journal path"))
            guard within(url,canonical(directory.path)), url.pathExtension == "jsonl" else { throw AgentError("session_scope", "Only this workspace's own journals are slimmed") }
            guard sessions[id] == nil, slimming[id] == nil else { return JournalSlimming.Outcome(reason:"session-open").json }
            let task=Task.detached(priority:.utility) { try JournalSlimming.slim(url:url,id:id) }
            slimming[id]=task
            defer { slimming[id]=nil }
            return try await task.value.json
        case "session.import.continue", "session.import.recover": throw AgentError("portable_handoff_required", "Pi journals are preserved read-only. Preview and explicitly create a native portable handoff rather than replaying incompatible provider state.")
        default: return nil
        }
    }
    /// Commands on a chat by its id, whether it is open here or not.
    private func namedSessionCommand(_ method:String, id:String, params:JSON) async throws -> JSON? {
        if method.hasPrefix("debug.") { return try await traces.command(method,session:id,params:params) }
        switch method {
        case "session.forget":
            if let existing=sessions[id] {
                guard await existing.unloadIfIdle() else { throw AgentError("session_busy","Stop work and close/keep side chats before forgetting") }
                sessions.removeValue(forKey:id);profiles.removeValue(forKey:id)
            }
            _=try await traces.command("debug.clear",session:id,params:[:]); return ["accepted":true]
        default: return nil
        }
    }
    /// Commands on an open chat that a quiesced workspace still answers:
    /// reads, a stop, and a side kept or closed. A fork and a new side
    /// refuse a quiesced workspace themselves.
    private func sessionCommand(_ method:String, id:String, session:AgentSession, params:JSON, in workspace:OpenWorkspace) async throws -> JSON? {
        let resources=workspace.resources, nativeTools=workspace.nativeTools
        switch method {
        case "turn.stop": await session.stop(); return ["accepted":true]
        case "session.status":
            var statusParams = params; statusParams["includeMessages"] = false
            return await session.snapshot(statusParams)
        case "session.edit.prepare": return try await session.prepareEdit(identity(params["messageId"]),offset:boundedInt(params["offset"],maximum:262144),expectedTimeline:params["sourceTimeline"].text,expectedTextDigest:params["sourceTextDigest"].text)
        case "session.snapshot": return await session.snapshot(params)
        case "context.info": return await session.inspectContext()
        case "context.preview": return try await session.prepareContext(params)
        case "context.preview.read": return try await session.readPreparedContext(params)
        case "context.preview.clear": await session.clearPreparedContext(params["revision"].text); return ["accepted":true]
        case "session.history":
            if params["version"].int == 2 { return try await session.historyWindow(params) }
            return await session.historyPage(before:params["before"].int)
        case "session.message.read": return try await session.messageRead(id:required(params["messageId"],"message id"),field:params["field"].text ?? "text",offset:boundedInt(params["offset"],maximum:128*1024*1024))
        case "session.tool.input": return try await session.toolInput(messageID:required(params["messageId"],"message id"),callID:required(params["callId"],"tool call id",maximum:256))
        case "session.content.search": return try await session.contentSearch(params)
        case "session.content.page": return try await session.contentPage(params)
        case "session.event-page", "session.events": return await session.eventPage(since:params["since"].int)
        // An edited message's versions, and the rows of one of them.
        case "session.versions": return try await session.messageVersions(params)
        case "session.version.page": return try await session.versionPage(params)
        case "session.fork":
            guard !quiesced else { throw AgentError("quiesced", "Workspace is quiesced for update") }
            let forkID=try identity(params["forkSessionId"]), costLimit=try AgentSession.costLimit(params["costLimit"])
            // Fork at one assistant reply rather than at the end: the journal up to it.
            let point=params["atMessageId"].isNull ? nil : try identity(params["atMessageId"])
            return try await withRuntimeGate {
                guard sessions[forkID] == nil, let (profile,key)=profiles[id] else { throw AgentError("session_conflict", "Fork identity is already in use") }
                // The fork opens with what its journal replayed to as it was
                // written, instead of reading it all again.
                let (result,replay)=try await session.forked(to:forkID,at:point)
                let fork=try await makeSession(forkID,profile:profile,apiKey:key,readOnly:session.readOnly,resources:resources,tools:session.isConnectionTest ? DisabledTools() : nativeTools,resumePath:result["path"].text,prepared:replay)
                sessions[forkID]=fork; profiles[forkID]=(profile,key)
                // Opened with only its latest rows, the fork loads the rest in the background.
                if !quiesced, !closing { await fork.startHistoryFill() }
                // A fork is a chat of its own, with its own limit.
                if let costLimit { await fork.setCostLimit(costLimit) }
                _=try await traces.command("debug.mode",session:forkID,params:["mode":JSON(await traces.mode(id))])
                return result
            }
        case "side.open":
            guard !quiesced else { throw AgentError("quiesced", "Workspace is quiesced for update") }
            let sideID=try identity(params["sideSessionId"]), costLimit=try AgentSession.costLimit(params["costLimit"])
            return try await withRuntimeGate {
                guard sessions[sideID] == nil, let (profile,key)=profiles[id] else { throw AgentError("side_conflict", "Side identity is already in use") }
                let seed=await session.sideSeed()
                let side=try await makeSession(sideID,profile:profile,apiKey:key,readOnly:true,resources:resources,tools:nativeTools,seed:seed.messages,parent:seed.info)
                // A side is a session of its own: its own spend and limit.
                if let costLimit { await side.setCostLimit(costLimit) }
                let saved=try await side.preserveSide()
                sessions[sideID]=side; profiles[sideID]=(profile,key)
                _=try await traces.command("debug.mode",session:sideID,params:["mode":JSON(await traces.mode(id))])
                return ["accepted":true,"sessionId":JSON(sideID),"side":seed.info,"ephemeral":false,"path":saved["path"]]
            }
        case "side.keep": return try await session.keep(whenFinished:params["whenFinished"].flag == true)
        case "side.close":
            let saved=try await session.preserveSide()
            // This closes presentation only. The durable runtime and any active
            // work stay available as an ordinary saved child conversation.
            return saved
        default: return nil
        }
    }
    /// Commands that change an open chat, which a quiesced workspace refuses.
    private func changeCommand(_ method:String, id:String, session:AgentSession, params:JSON, commandID:String, in workspace:OpenWorkspace) async throws -> JSON? {
        let resources=workspace.resources, mcp=workspace.mcp, nativeTools=workspace.nativeTools
        switch method {
        case "turn.submit", "turn.steer", "turn.edit":
            let text=params["text"].text ?? "", tools=await nativeTools.capabilityIDs(readOnly:session.readOnly)
            let selected=try await resources.freeze(params["skills"].list,text:text,tools:tools)
            let overrides=try Self.turnOverrides(params)
            let input=Submission(commandID:commandID,turnID:try identity(params["clientTurnId"]),text:text,attachments:params["attachments"].list,skills:selected,model:overrides.model,thinkingLevel:overrides.thinkingLevel,contextWindow:overrides.contextWindow,maxOutputTokens:overrides.maxOutputTokens,modelOutputLimit:overrides.modelOutputLimit,input:overrides.input)
            if method == "turn.edit" { return try await session.edit(fromMessageID:try identity(params["messageId"]),input:input,expectedTimeline:params["editSourceTimeline"].text,expectedTextDigest:params["editSourceTextDigest"].text) }
            return try await session.submit(input,steer:method == "turn.steer")
        case "queue.remove": try await session.removeQueued(required(params["turnId"],"turn id")); return ["accepted":true]
        case "queue.reorder":
            let order=try params["turnIds"].list.map { try required($0,"turn id") }
            try await session.reorderQueue(order); return ["accepted":true]
        case "queue.read": return try await session.queuedText(required(params["turnId"],"turn id"))
        case "queue.update": try await session.updateQueued(required(params["turnId"],"turn id"),text:params["text"].text ?? ""); return ["accepted":true]
        case "queue.steer": try await session.steerQueued(required(params["turnId"],"turn id")); return ["accepted":true]
        case "queue.resume": try await session.resumeQueue(); return ["accepted":true]
        case "turn.retry": try await session.retryRun(overrides: params); return ["accepted":true]
        case "queue.configure": try await session.configureQueue(params); return ["accepted":true]
        case "context.compact": try await session.compact(commandID:commandID,overrides:params.removing(["focus"]),focus:params["focus"].text); return ["accepted":true]
        case "mcp.invoke": var args=params; args["action"]="invoke"; return try await mcp.perform(args,readOnly:session.readOnly)
        case "session.configure":
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
        case "session.close":
            guard await session.unloadIfIdle() else { throw AgentError("session_busy", "Stop work and close/keep side chats before unloading") }
            sessions.removeValue(forKey:id); profiles.removeValue(forKey:id); return ["accepted":true]
        default: return nil
        }
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
    /// Optional per-turn model, thinking, model-specific capacity and input overrides.
    static func turnOverrides(_ params: JSON) throws -> (model: String?, thinkingLevel: String?, contextWindow: Int?, maxOutputTokens: Int?, modelOutputLimit: Int?, input: [String]?) {
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
        return (model,level,try limit("contextWindow",maximum:10_000_000),try limit("maxOutputTokens",maximum:1_000_000),try limit("modelOutputLimit",maximum:1_000_000),try turnInput(params["input"]))
    }
    /// What the turn's model takes, as the app's catalog declares it: pi's
    /// input kinds, "text" and "image".
    static func turnInput(_ value: JSON) throws -> [String]? {
        if value.isNull { return nil }
        let kinds = value.list.compactMap(\.text)
        guard case .array(let items) = value, kinds.count == items.count, Profile.validInput(kinds) else { throw AgentError("invalid_params", "Invalid turn input override") }
        return kinds
    }
    /// A journal whose last record was cut off (a power loss or a full disk
    /// mid-write) cannot be reopened. This copies every complete record,
    /// checked to be one intact native branch, to a new journal under a new
    /// session id in the same project, and leaves the original untouched.
    /// Anything wrong before the last record is still refused.
    /// The journal at `url` bound to `target`'s connection, with the
    /// binding it had before; its metadata file names the move too, so the
    /// next open still resumes from it.
    private static func rebind(url: URL, id: String, directory: URL, to target: Profile, from previous: Profile?, check: Bool) throws -> JSON {
        let journal=try SessionJournal(url:url,id:id,cwd:directory,binding:nil,create:false,checkpoint:JournalCheckpoint.read(for:url))
        let before=journal.binding ?? .null
        if check {
            var replies=0
            if let previous, previous.id != target.id {
                let context=try AgentSession.replay(journal,url:url,id:id,binding:before,spendTracked:false,resume:true).context
                replies=context.filter { ProviderClient.replaysReasoning($0, profile: previous) }.count
            }
            return ["needsConfirmation":JSON(replies > 0),"replies":JSON(replies),"rebinds":JSON(before != target.binding)]
        }
        try journal.rebind(to:target.binding)
        if before != target.binding, var stored=journal.resumedFrom { stored.rebinds=journal.rebinds.map(\.check); try? stored.write(for:url) }
        return ["rebound":JSON(before != target.binding)]
    }
    private func recoverCopy(_ params:JSON) throws -> JSON {
        guard let directory else { throw AgentError("workspace_closed","Open the project before recovering a chat") }
        let sessions=canonical(directory.path), source=canonical(try required(params["path"],"session path"))
        guard within(source,sessions) else { throw AgentError("invalid_path","Only this project's own chats can be recovered") }
        let id=try identity(params["newSessionId"]), destination=sessions.appendingPathComponent(id+".jsonl")
        let reader=try JournalRecordReader(source,allowIncompleteTail:true)
        guard var header=try reader.next(), header["type"].text == "session", header["version"].int == 3 else { throw AgentError("legacy_session","Only a native chat can be recovered this way") }
        header["id"]=JSON(id)
        var copy=try header.data(); copy.append(10)
        // Written beside the destination, then linked into place: an existing
        // chat of that id is never replaced and a failed write leaves nothing.
        let temporary=sessions.appendingPathComponent(".recover-\(UUID().uuidString).jsonl")
        let fd=open(temporary.path,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd >= 0 else { throw AgentError("session_write","Cannot create the recovered copy") }
        let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer { try? file.close(); try? FileManager.default.removeItem(at:temporary) }
        try file.write(contentsOf:copy)
        var branch=JournalChainCheck(), count=0, native=false
        while var line=try reader.nextLine() {
            if !line.isEmpty {
                let item=try JSON.parse(line), rid=try identity(item["id"])
                guard branch.extend(rid, parent: item["parentId"].text) else { throw AgentError("session_damaged","The journal is damaged before its last record; nothing was recovered") }
                count += 1
                if item["customType"].text == JournalRecordKind.marker { native=true }
            }
            line.append(10); try file.write(contentsOf:line)
        }
        guard native else { throw AgentError("legacy_session","Only a native chat can be recovered this way") }
        try file.synchronize(); try file.close()
        guard link(temporary.path,destination.path) == 0 else { throw AgentError("session_exists","A chat with that identity already exists") }
        return ["sessionId":JSON(id),"sessionFile":JSON(destination.path),"records":JSON(count),"omittedBytes":JSON(Double(reader.omittedBytes))]
    }
    private func portable(_ params:JSON) throws -> JSON {
        let file=canonical(try required(params["path"],"session path"))
        let reader=try JournalRecordReader(file,allowIncompleteTail:true,hash:true)
        guard let header=try reader.next(), header["type"].text=="session" else { throw AgentError("invalid_history","Expected session header") }
        var next=try reader.next()
        // Native journals are linear. Replay as a stream, discarding old
        // presentation/state snapshots instead of retaining the complete file.
        if next?["customType"].text == JournalRecordKind.marker {
            var replay=try ConversationReplay(), branch=JournalChainCheck()
            while let item=next {
                let id=try identity(item["id"])
                guard branch.extend(id, parent: item["parentId"].text) else { throw AgentError("invalid_history","Native journal must be a valid single branch") }
                try replay.consume(item); next=try reader.next()
            }
            guard reader.omittedBytes==0 else { throw AgentError("incomplete_history","History has an incomplete tail. Preserve and review it before making a portable handoff.") }
            let messages=replay.context.map { "[\($0.role)]\n" + ($0.displayText ?? $0.text) }
            let text=messages.suffix(40).joined(separator:"\n\n"), retained=preview(text,bytes:65536), digest=reader.digest!
            return ["path":JSON(file.path),"sessionId":header["id"],"nativeReplay":false,"damaged":false,"text":JSON(retained),"draft":JSON(retained),"truncated":JSON(retained.utf8.count < text.utf8.count || messages.count > 40),"provenance":["sourcePath":JSON(file.path),"sourceSHA256":JSON(digest),"portable":true],"notice":"Portable text of the selected branch. Original unchanged. Review before sending.","sha256":JSON(digest)]
        }
        var records:[String:JSON]=[:], leaf:String?
        while let item=next {
            guard records.count<100000,let id=item["id"].text,records[id]==nil else { throw AgentError("invalid_history","Invalid or duplicate journal identity") }
            if let parent=item["parentId"].text,records[parent]==nil { throw AgentError("invalid_history","Journal parent is missing") }
            records[id]=item;leaf=id
            next=try reader.next()
        }
        guard reader.omittedBytes==0 else { throw AgentError("incomplete_history","History has an incomplete tail. Preserve and review it before making a portable handoff.") }
        let digest=reader.digest!
        var chain:[JSON]=[],cursor=leaf
        while let id=cursor,let record=records[id] { chain.append(record);cursor=record["parentId"].text }
        chain.reverse()
        if chain.contains(where: { $0["customType"].text == JournalRecordKind.marker }) {
            let replay = try ConversationReplay(chain)
            let messages = replay.context.map { "[\($0.role)]\n" + ($0.displayText ?? $0.text) }
            let text = messages.suffix(40).joined(separator: "\n\n"), retained = preview(text, bytes: 65536)
            return ["path":JSON(file.path),"sessionId":header["id"],"nativeReplay":false,"damaged":false,"text":JSON(retained),"draft":JSON(retained),"truncated":JSON(retained.utf8.count < text.utf8.count || messages.count > 40),"provenance":["sourcePath":JSON(file.path),"sourceSHA256":JSON(digest),"portable":true],"notice":"Portable text of the selected branch. Original unchanged. Review before sending.","sha256":JSON(digest)]
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
            } else if item["customType"].text==JournalRecordKind.context {
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
        return ["path":JSON(file.path),"sessionId":header["id"],"nativeReplay":false,"damaged":false,"text":JSON(retained),"draft":JSON(retained),"truncated":JSON(retained.utf8.count<text.utf8.count || messages.count>40),"provenance":["sourcePath":JSON(file.path),"sourceSHA256":JSON(digest),"portable":true],"notice":"Portable text only, active branch and latest compaction. Opaque reasoning, executable state and permissions are not transferred. Original unchanged. Review before sending.","sha256":JSON(digest)]
    }
    public func shutdown() async {
        // Acknowledgments are dropped from here on (see `receive`): a capture
        // must not hold a stopped run's partial reply and final state.
        closing=true; await capture.close(); flushTask?.cancel(); for t in tasks.values { t.cancel() }
        for s in sessions.values { await s.stop() }; for s in sessions.values { await s.close() }; await mcp?.close(); sessions.removeAll(); profiles.removeAll(); flush()
    }
}
