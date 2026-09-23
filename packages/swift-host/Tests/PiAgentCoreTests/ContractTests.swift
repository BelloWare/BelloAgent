import XCTest
@testable import PiAgentCore

/// Host contract H1–H5: correlation headers/body metadata, multi-root
/// workspaces, per-turn overrides, turn.edit branches and display kinds.
final class ContractTests: XCTestCase {
    // MARK: H1
    func testResponsesBodyCarriesSessionMetadataAndMessagesCannotOpen() async throws {
        let user=ChatMessage(role:"user",content:[textBlock("hello")])
        let responses=try ProviderClient.requestBody(profile:fixtureProfile(),messages:[user],instructions:"i",tools:[],sessionID:"session-1")
        XCTAssertEqual(responses["metadata"],["session_id":"session-1"])
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let host=NativeHostService(emit:{_ in})
        _=try await host.command("workspace.open",sessionID:nil,params:["cwd":JSON(root.path),"directory":JSON(root.appendingPathComponent("state").path),"mcp":["servers":[:]]])
        var legacy=try fixtureProfile().raw;legacy["api"]="anthropic-messages"
        do { _=try await host.command("session.open",sessionID:"legacy",params:["profile":legacy,"apiKey":"synthetic"]);XCTFail("Retired API must fail before a session can make HTTP requests") }
        catch let error as AgentError { XCTAssertEqual(error.code,"unsupported_api") }
        await host.shutdown()
    }
    func testCorrelationHeadersAreTransportOwnedAndNeverCredentials() async throws {
        XCTAssertTrue(ProviderClient.transportOwnedHeaders.isSuperset(of:["x-session-id","x-turn-id","authorization","x-api-key"]))
        XCTAssertEqual(ProviderClient.correlationValue("compaction:abc-1.2_x"),"compaction:abc-1.2_x")
        XCTAssertEqual(ProviderClient.correlationValue("bad\r\nInjected: yes"),"badInjected:yes")
        XCTAssertEqual(ProviderClient.correlationValue("\u{7f}\n"),"unknown")
        XCTAssertEqual(ProviderClient.correlationValue(String(repeating:"a",count:300)).count,128)
        // A profile cannot override the correlation headers.
        var raw=try fixtureProfile().raw; raw["headers"]=["X-Session-Id":"spoofed"]
        let spoofed=try Profile(raw)
        do { _=try await ProviderClient(traces:TraceStore()).complete(profile:spoofed,apiKey:"k",messages:[ChatMessage(role:"user",content:[textBlock("x")])],instructions:"",tools:[],sessionID:"s",turnID:"t",purpose:"turn",onDelta:{_ in}); XCTFail("Spoofed header accepted") }
        catch let error as AgentError { XCTAssertEqual(error.code,"invalid_header") }
        // Captured metadata keeps the identities readable and the body byte-exact.
        let body=try ProviderClient.requestBody(profile:fixtureProfile(),messages:[ChatMessage(role:"user",content:[textBlock("x")])],instructions:"",tools:[],sessionID:"session-1").data()
        let traces=TraceStore()
        let id=await traces.begin(session:"session-1",turn:"turn-1",profile:try fixtureProfile(),purpose:"turn",body:body,headers:["Authorization":"Bearer secret","x-session-id":"session-1","x-turn-id":"turn-1"])
        let metadata=try await traces.command("debug.attempt",session:"session-1",params:["attemptId":JSON(id)])
        XCTAssertEqual(metadata["requestHeaders"]["x-session-id"].text,"session-1"); XCTAssertEqual(metadata["requestHeaders"]["x-turn-id"].text,"turn-1")
        XCTAssertEqual(metadata["request"]["byteExact"].flag,true); XCTAssertEqual(metadata["requestHash"]["sha256"].text,sha256(body))
    }
    // MARK: H2
    func testMultiRootWorkspaceDiscoveryResolutionAndConflict() async throws {
        let base=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:base) }
        let primary=base.appendingPathComponent("primary"), second=base.appendingPathComponent("second"), home=base.appendingPathComponent("home")
        for dir in [primary,second,home,second.appendingPathComponent(".agents/skills/deploy"),second.appendingPathComponent("lib")] { try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true) }
        try Data("PRIMARY-GUIDE".utf8).write(to:primary.appendingPathComponent("AGENTS.md"))
        try Data("SECOND-GUIDE".utf8).write(to:second.appendingPathComponent("AGENTS.md"))
        try Data("---\nname: deploy\ndescription: Deploy things\n---\nDeploy.".utf8).write(to:second.appendingPathComponent(".agents/skills/deploy/SKILL.md"))
        try Data("in second".utf8).write(to:second.appendingPathComponent("lib/only.txt"))
        let resources=Resources(cwd:primary,roots:[second,primary],home:home), snapshot=try await resources.resolve()
        XCTAssertEqual(snapshot.roots,[primary.path,second.path])
        XCTAssertTrue(snapshot.prompt.contains("PRIMARY-GUIDE")); XCTAssertTrue(snapshot.prompt.contains("SECOND-GUIDE"))
        XCTAssertTrue(snapshot.prompt.contains(second.path)); XCTAssertTrue(snapshot.prompt.contains("relative paths resolve against the primary root"))
        XCTAssertEqual(snapshot.skills.map { $0["name"].text },["deploy"])
        let inspected=try await resources.inspect([:]); XCTAssertEqual(inspected["roots"].list.count,2)
        let tools=NativeTools(cwd:primary,roots:[second],outputs:base.appendingPathComponent("out"),mcp:MCPManager(cwd:primary,roots:[second]))
        let read=try await tools.invoke(ToolCall(id:"r",name:"read",arguments:["path":"lib/only.txt"]),readOnly:true)
        XCTAssertTrue(read.encoded().contains("in second"),"An existing relative path under exactly one other root resolves there")
        let grep=try await tools.invoke(ToolCall(id:"g",name:"grep",arguments:["pattern":"second","path":"lib","literal":true]),readOnly:true)
        XCTAssertTrue(grep.encoded().contains("only.txt:1"))
        _=try await tools.invoke(ToolCall(id:"w",name:"write",arguments:["path":"lib/new.txt","content":"x"]),readOnly:false)
        XCTAssertTrue(FileManager.default.fileExists(atPath:primary.appendingPathComponent("lib/new.txt").path),"Writes of new files stay in the primary root")
        let host=NativeHostService(emit:{_ in})
        let state=base.appendingPathComponent("state")
        do { _=try await host.command("workspace.open",sessionID:nil,params:["roots":[JSON(primary.path),"relative"],"directory":JSON(state.path)]); XCTFail("Relative roots must be rejected") } catch let error as AgentError { XCTAssertEqual(error.code,"invalid_params") }
        do { _=try await host.command("workspace.open",sessionID:nil,params:["roots":[JSON(primary.path),JSON(base.appendingPathComponent("missing").path)],"directory":JSON(state.path)]); XCTFail("Missing roots must be rejected") } catch let error as AgentError { XCTAssertEqual(error.code,"workspace_missing") }
        let opened=try await host.command("workspace.open",sessionID:nil,params:["roots":[JSON(primary.path),JSON(second.path),JSON(primary.path)],"directory":JSON(state.path)])
        XCTAssertEqual(opened["cwd"].text,primary.path); XCTAssertEqual(opened["roots"].list.compactMap(\.text),[primary.path,second.path])
        let again=try await host.command("workspace.open",sessionID:nil,params:["roots":[JSON(primary.path),JSON(second.path)],"directory":JSON(state.path)])
        XCTAssertEqual(again["roots"].list.count,2)
        do { _=try await host.command("workspace.open",sessionID:nil,params:["roots":[JSON(primary.path)],"directory":JSON(state.path)]); XCTFail("Different root sets must conflict") } catch let error as AgentError { XCTAssertEqual(error.code,"workspace_conflict") }
        do { _=try await host.command("workspace.open",sessionID:nil,params:["cwd":JSON(primary.path),"directory":JSON(state.path)]); XCTFail("Legacy single cwd differs from the bound root set") } catch let error as AgentError { XCTAssertEqual(error.code,"workspace_conflict") }
        await host.shutdown()
        let legacy=NativeHostService(emit:{_ in})
        let single=try await legacy.command("workspace.open",sessionID:nil,params:["cwd":JSON(primary.path),"directory":JSON(base.appendingPathComponent("legacy-state").path)])
        XCTAssertEqual(single["roots"].list.compactMap(\.text),[primary.path]); await legacy.shutdown()
    }
    // MARK: H3
    func testPerTurnOverridesReachRequestsJournalTracesAndReopen() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let state=root.appendingPathComponent("state"), traces=TraceStore(), resources=Resources(cwd:root,home:root)
        var raw=try fixtureProfile().raw; raw["routing"]=["replayPolicy":"pinned","expectedModel":"fixture-actual","replayContract":"fixed"]
        let profile=try Profile(raw)
        let client=ScriptClient([answer("base"),answer("override"),answer("after")])
        let s=try AgentSession(id:"overrides",profile:profile,apiKey:"k",cwd:root,directory:state,readOnly:true,resources:resources,client:client,tools:RecordingTools(),traces:traces,autoCompaction:false)
        _=try await s.submit(Submission(commandID:"c1",turnID:"t1",text:"plain"),steer:false); try await eventually { !(await s.isRunning) }
        do { _=try await s.submit(Submission(commandID:"bad",turnID:"bad",text:"x",thinkingLevel:"extreme"),steer:false); XCTFail("Invalid level accepted") } catch let error as AgentError { XCTAssertEqual(error.code,"invalid_params") }
        _=try await s.submit(Submission(commandID:"c2",turnID:"t2",text:"switched",model:"other-alias",thinkingLevel:"high"),steer:false); try await eventually { !(await s.isRunning) }
        _=try await s.submit(Submission(commandID:"c3",turnID:"t3",text:"back"),steer:false); try await eventually { !(await s.isRunning) }
        let profiles=await client.profiles
        XCTAssertEqual(profiles.map(\.model),["fixture-model","other-alias","fixture-model"])
        XCTAssertEqual(profiles.map { $0.raw["thinkingLevel"].text },["default","high","default"])
        XCTAssertEqual(profiles[1].raw["routing"]["replayPolicy"].text,"portable","A different alias leaves the pinned route for that turn")
        XCTAssertEqual(profiles[2].raw["routing"]["replayPolicy"].text,"pinned")
        XCTAssertEqual(profiles[1].contextWindow,profile.contextWindow); XCTAssertEqual(profiles[1].maxOutput,profile.maxOutput)
        let info=await s.inspectContext(); XCTAssertEqual(info["effectiveModel"].text,"fixture-model")
        // Trace metadata reports the alias actually requested.
        let attempt=await traces.begin(session:"overrides",turn:"t2",profile:profiles[1],purpose:"turn",body:Data(),headers:[:])
        let latest=await traces.latest("overrides"); XCTAssertEqual(latest["attemptId"].text,attempt); XCTAssertEqual(latest["requestedModel"].text,"other-alias")
        let path=await s.path!; await s.close()
        let records=try String(contentsOf:URL(fileURLWithPath:path),encoding:.utf8).split(separator:"\n").map { try JSON.parse(Data($0.utf8)) }
        let user=records.first { $0["id"].text=="t2" }!
        XCTAssertEqual(user["modelOverride"].text,"other-alias"); XCTAssertEqual(user["thinkingLevel"].text,"high")
        XCTAssertTrue(records.first { $0["id"].text=="t1" }!["modelOverride"].isNull)
        let reopened=try AgentSession(id:"overrides",profile:profile,apiKey:"k",cwd:root,directory:state,readOnly:true,resources:resources,client:ScriptClient([answer("again")]),tools:RecordingTools(),traces:traces,resumePath:path,autoCompaction:false)
        let snapshot=await reopened.snapshot(); XCTAssertEqual(snapshot["total"].int,6); await reopened.close()
        // Messages recorded under another alias replay portably under the pinned route.
        var foreign=ChatMessage(role:"assistant",content:[textBlock("x")]); foreign.providerItems=[["type":"reasoning","id":"r","summary":[],"encrypted_content":"opaque"],["type":"message","role":"assistant","content":[["type":"output_text","text":"x"]]]]
        foreign.providerBinding=try ProviderClient.replayBinding(profiles[1])
        XCTAssertNil(try ProviderClient.replayItems(foreign,profile:profile))
    }
    // MARK: H4 + H5
    func testEditBranchHidesTailKeepsJournalAndReplaysAfterReload() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let state=root.appendingPathComponent("state"), traces=TraceStore(), resources=Resources(cwd:root,home:root), profile=try fixtureProfile()
        let client=ScriptClient([answer("A1"),answer("A2"),answer("A3"),answer("A4")])
        let s=try AgentSession(id:"edit",profile:profile,apiKey:"k",cwd:root,directory:state,readOnly:true,resources:resources,client:client,tools:RecordingTools(),traces:traces,autoCompaction:false)
        _=try await s.submit(Submission(commandID:"c1",turnID:"t1",text:"first"),steer:false); try await eventually { !(await s.isRunning) }
        _=try await s.submit(Submission(commandID:"c2",turnID:"t2",text:"second"),steer:false); try await eventually { !(await s.isRunning) }
        _=try await s.submit(Submission(commandID:"c3",turnID:"t3",text:"third"),steer:false); try await eventually { !(await s.isRunning) }
        do { _=try await s.edit(fromMessageID:"missing",input:Submission(commandID:"e0",turnID:"e0",text:"x")); XCTFail("Unknown message accepted") } catch let error as AgentError { XCTAssertEqual(error.code,"edit_target") }
        do { _=try await s.edit(fromMessageID:"t2",input:Submission(commandID:"e0",turnID:"e0",text:"")); XCTFail("Empty edit accepted") } catch let error as AgentError { XCTAssertEqual(error.code,"empty_message") }
        let accepted=try await s.edit(fromMessageID:"t2",input:Submission(commandID:"e1",turnID:"e1",text:"second, edited"))
        XCTAssertEqual(accepted["accepted"].flag,true); try await eventually { !(await s.isRunning) }
        let requests=await client.requests
        let a1=requests[1][1].id
        XCTAssertEqual(requests[3].map(\.id),["t1",a1,"e1"],"Context is exactly the kept ids plus the new turn")
        XCTAssertEqual(requests[3].map(\.text),["first","A1","second, edited"])
        let snapshot=await s.snapshot(), messages=snapshot["messages"].list
        XCTAssertEqual(messages.map { $0["text"].text },["first","A1",branchMarkerText,"second, edited","A4"])
        XCTAssertEqual(messages.map { $0["kind"].text },[nil,nil,"branch",nil,nil]); XCTAssertEqual(messages[2]["role"].text,"system")
        XCTAssertEqual(snapshot["total"].int,5)
        let page=await s.historyPage(before:nil); XCTAssertEqual(page["total"].int,5); XCTAssertEqual(page["messages"].list.count,5)
        let search=try await s.contentSearch(["query":"third"]); XCTAssertEqual(search["hits"].list.count,0,"Abandoned tail is not displayed")
        let readable=try await s.messageRead(id:"t3",field:"text",offset:0); XCTAssertEqual(readable["text"].text,"third","Abandoned messages remain readable by identity")
        do { _=try await s.edit(fromMessageID:"t3",input:Submission(commandID:"e2",turnID:"e2",text:"x")); XCTFail("Abandoned message is not in the current context") } catch let error as AgentError { XCTAssertEqual(error.code,"edit_target") }
        let path=await s.path!; await s.close()
        let records=try String(contentsOf:URL(fileURLWithPath:path),encoding:.utf8).split(separator:"\n").map { try JSON.parse(Data($0.utf8)) }
        let branch=records.first { $0["type"].text=="branch" }!
        XCTAssertEqual(branch["fromMessageId"].text,"t2"); XCTAssertEqual(branch["keptIds"].list.compactMap(\.text),["t1",a1])
        XCTAssertEqual(records.filter { $0["type"].text=="message" && $0["message"]["role"].text=="user" }.count,4,"Nothing is deleted from the journal")
        XCTAssertTrue(records[1]["parentId"].isNull); for index in 2..<records.count { XCTAssertEqual(records[index]["parentId"].text,records[index-1]["id"].text,"Single parent chain") }
        let next=ScriptClient([answer("A5")])
        let reopened=try AgentSession(id:"edit",profile:profile,apiKey:"k",cwd:root,directory:state,readOnly:true,resources:resources,client:next,tools:RecordingTools(),traces:traces,resumePath:path,autoCompaction:false)
        let replayed=await reopened.snapshot()
        XCTAssertEqual(replayed["messages"].list.map { $0["text"].text },["first","A1",branchMarkerText,"second, edited","A4"])
        XCTAssertEqual(replayed["messages"].list[2]["kind"].text,"branch"); XCTAssertEqual(replayed["messages"].list[2]["id"].text,branch["id"].text)
        _=try await reopened.submit(Submission(commandID:"c5",turnID:"t5",text:"fifth"),steer:false); try await eventually { !(await reopened.isRunning) }
        let request=await next.requests[0]
        XCTAssertEqual(request.map(\.text),["first","A1","second, edited","A4","fifth"],"Replayed context excludes the abandoned tail and the marker")
        await reopened.close()
    }
    func testEditIsRefusedWhileRunningOrQueued() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client=ScriptClient([answer("held"),answer("next")],holdFirst:true)
        let s=try AgentSession(id:"busy",profile:fixtureProfile(),apiKey:"k",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),autoCompaction:false)
        _=try await s.submit(Submission(commandID:"c1",turnID:"t1",text:"first"),steer:false); try await eventually { await client.count==1 }
        do { _=try await s.edit(fromMessageID:"t1",input:Submission(commandID:"e1",turnID:"e1",text:"x")); XCTFail("Edit during a run accepted") } catch let error as AgentError { XCTAssertEqual(error.code,"session_busy") }
        await client.release(); try await eventually { !(await s.isRunning) }
        let path=await s.path
        XCTAssertNotNil(path); await s.close()
    }
    func testCompactionSummaryCarriesKindAndDetailAcrossReload() async throws {
        let root=try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let state=root.appendingPathComponent("state"), profile=try fixtureProfile(), resources=Resources(cwd:root,home:root), traces=TraceStore()
        // Pi's split turn: the history summary, then the second request's turn-prefix summary.
        let client=ScriptClient([answer(String(repeating:"Completed first task evidence. ",count:80)),answer("second answer"),answer("Summary: done."),answer("Prefix: the second question.")])
        let s=try AgentSession(id:"kinds",profile:profile,apiKey:"k",cwd:root,directory:state,readOnly:true,resources:resources,client:client,tools:RecordingTools(),traces:traces,autoCompaction:false,compactionPolicy:{ var policy=CompactionPolicy();policy.keepRecentTokens=1;return policy }())
        _=try await s.submit(Submission(commandID:"c1",turnID:"t1",text:"first question"),steer:false); try await eventually { !(await s.isRunning) }
        _=try await s.submit(Submission(commandID:"c2",turnID:"t2",text:"second question"),steer:false); try await eventually { !(await s.isRunning) }
        try await s.compact(commandID:"compact"); try await eventually { !(await s.isRunning) }
        let summary=await s.snapshot()["messages"].list.first { $0["kind"].text=="compaction" }!
        XCTAssertEqual(summary["role"].text,"system"); XCTAssertTrue(summary["text"].text!.contains("Summary: done."))
        XCTAssertNotNil(summary["detail"].text?.range(of:"^Compacted [0-9]+ estimated input tokens · 1 messages kept$",options:.regularExpression),summary["detail"].encoded())
        let status = await s.snapshot(["includeMessages": false])
        let evidence: JSON = ["id": summary["id"], "detail": summary["detail"], "operation": status["compaction"]]
        XCTAssertEqual(status["latestSuccessfulCompaction"], evidence)
        XCTAssertTrue(status["messages"].isNull, "Background and scrollback notices need no transcript projection")
        let unchanged = await s.snapshot(["displayRevision": status["displayRevision"]])
        XCTAssertTrue(unchanged["messages"].isNull); XCTAssertEqual(unchanged["latestSuccessfulCompaction"], evidence)
        let first=await s.snapshot()["messages"].list[0]; XCTAssertNil(first["kind"].text)
        let path=await s.path!; await s.close()
        let reopened=try AgentSession(id:"kinds",profile:profile,apiKey:"k",cwd:root,directory:state,readOnly:true,resources:resources,client:ScriptClient([]),tools:RecordingTools(),traces:traces,resumePath:path,autoCompaction:false)
        let replayed=await reopened.snapshot()["messages"].list.first { $0["kind"].text=="compaction" }!
        XCTAssertEqual(replayed["detail"].text,summary["detail"].text); XCTAssertEqual(replayed["id"].text,summary["id"].text)
        let reopenedStatus = await reopened.snapshot(["includeMessages": false])
        XCTAssertEqual(reopenedStatus["latestSuccessfulCompaction"], evidence, "First-open callers can baseline retained success without a false new notice")
        let page=await reopened.historyPage(before:nil)
        XCTAssertEqual(page["messages"].list.filter { $0["kind"].text == "compaction" }.count,1)
        XCTAssertEqual(page["messages"].list.filter { $0["kind"].text == "execution" }.count,1)
        await reopened.close()
    }

    /// There is no cap on loaded chats: a workspace keeps every opened session
    /// and side runtime, and never refuses one or unloads another to make room.
    func testAWorkspaceKeepsEveryOpenedSessionLoaded() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let recorder=UnloadedSessionRecorder()
        let host=NativeHostService(emit:{ frame in if frame["type"].text == "session.unloaded" { recorder.append(frame["sessionId"].text ?? "") } })
        _=try await host.command("workspace.open",sessionID:nil,params:["cwd":JSON(root.path),"directory":JSON(root.appendingPathComponent("state").path),"mcp":["servers":[:]]])
        let profile=try fixtureProfile().raw
        for index in 1...6 {
            let snapshot=try await host.command("session.open",sessionID:"chat-\(index)",params:["profile":profile,"apiKey":"synthetic"])
            XCTAssertEqual(snapshot["state"].text,"idle","chat \(index) opened without a capacity refusal")
        }
        for index in 1...6 {
            let snapshot=try await host.command("session.snapshot",sessionID:"chat-\(index)",params:[:])
            XCTAssertEqual(snapshot["state"].text,"idle","chat \(index) is still loaded")
        }
        let unloaded = recorder.values
        XCTAssertTrue(unloaded.isEmpty,"no chat was unloaded to make room: \(unloaded)")
        await host.shutdown()
    }
}

private final class UnloadedSessionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; stored.append(value) }
}
