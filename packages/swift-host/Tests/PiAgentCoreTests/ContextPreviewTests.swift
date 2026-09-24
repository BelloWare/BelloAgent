import XCTest
@testable import PiAgentCore

final class ContextPreviewTests: XCTestCase {
    func testPreviewUsesDispatchInputsIncludingDraftWithoutSendingOrChangingJournal() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        try Data("Follow the fixture instructions.".utf8).write(to:root.appendingPathComponent("AGENTS.md"))
        let client = ScriptClient([answer("done")]), tools = RecordingTools(), resources = Resources(cwd:root,home:root)
        let session = try AgentSession(id:"preview",profile:fixtureProfile(),apiKey:"synthetic-secret-for-preview",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:resources,client:client,tools:tools,traces:TraceStore(),autoCompaction:false)
        let path = await session.path!, before = try Data(contentsOf:URL(fileURLWithPath:path))
        let params: JSON = ["text":"An unsent question 🙂", "model":"selected-model", "thinkingLevel":"low", "contextWindow":16000, "maxOutputTokens":2048]
        let preview = try await session.prepareContext(params)
        XCTAssertEqual(preview["mode"].text,"prepared-next-request"); XCTAssertEqual(preview["draftIncluded"].flag,true)
        XCTAssertEqual(preview["model"].text,"selected-model"); XCTAssertEqual(preview["contextWindow"].int,16000)
        XCTAssertEqual(preview["seq"].int,0,"A preview is bound to the unchanged conversation for native meter invalidation")
        let read = try await session.readPreparedContext(["revision":preview["revision"],"section":"request"])
        let body = try JSON.parse(Data(read["text"].text!.utf8))
        XCTAssertTrue(RequestContextCounter.systemPrompt(body)!.contains("Follow the fixture instructions."))
        XCTAssertEqual(body["input"].list.last?["content"].list.first?["text"].text,"An unsent question 🙂")
        XCTAssertEqual(body["tools"].list.map { $0["name"].text! },["first","second"])
        let beforeCount = await client.count, beforeTools = await tools.calls, status = await session.snapshot()
        XCTAssertEqual(beforeCount,0); XCTAssertTrue(beforeTools.isEmpty); XCTAssertEqual(status["queueCount"].int,0)
        XCTAssertEqual(status["seq"].int,0); XCTAssertEqual(status["messages"].list.count,0)
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:path)),before)
        _ = try await session.submit(Submission(commandID:"send",turnID:"turn",text:"An unsent question 🙂",model:"selected-model",thinkingLevel:"low",contextWindow:16000,maxOutputTokens:2048),steer:false)
        try await eventually { !(await session.isRunning) }
        let requests = await client.requests, instructions = await client.instructions, profiles = await client.profiles
        let actual = try ProviderClient.requestBody(profile:profiles[0],messages:requests[0],instructions:instructions[0],tools:await session.sessionDefinitions(),sessionID:"preview")
        XCTAssertEqual(body,actual,"Prepared inputs must follow the actual provider request builder, not transcript previews")
        await session.close()
    }

    func testActivePreviewExcludesUnsentAndQueuedTurnsAndKeepsFrozenResources() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let instructions = root.appendingPathComponent("AGENTS.md")
        try Data("Original instructions.".utf8).write(to:instructions)
        let client = ScriptClient([answer("done")],holdFirst:true)
        let session = try AgentSession(id:"active",profile:fixtureProfile(),apiKey:"synthetic-secret-for-preview",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore(),autoCompaction:false)
        _ = try await session.submit(Submission(commandID:"start",turnID:"start",text:"Running input",model:"active-model"),steer:false)
        try await eventually { await client.count == 1 }
        _ = try await session.submit(Submission(commandID:"pending",turnID:"pending",text:"Future queued input"),steer:false)
        try Data("New instructions not applied to the active turn.".utf8).write(to:instructions)
        let before = await session.contextInfo()
        let preview = try await session.prepareContext(["text":"Unsent draft", "model":"future-model"])
        let after = await session.contextInfo()
        XCTAssertEqual(before, after, "Inspection must not replace preflight state")
        let page = try await session.readPreparedContext(["revision":preview["revision"],"section":"request"])
        XCTAssertEqual(preview["mode"].text,"active-context"); XCTAssertEqual(preview["model"].text,"active-model")
        let status = await session.snapshot()
        XCTAssertEqual(preview["seq"],status["seq"])
        XCTAssertEqual(preview["draftDeferred"].flag,true); XCTAssertEqual(preview["draftIncluded"].flag,false); XCTAssertEqual(preview["queueCount"].int,1)
        XCTAssertTrue(page["text"].text!.contains("Original instructions."))
        for omitted in ["Future queued input", "Unsent draft", "New instructions not applied"] { XCTAssertFalse(page["text"].text!.contains(omitted)) }
        await session.stop(); try await eventually { !(await session.isRunning) }; await session.close()
    }

    func testAllContextPagesAndOpaqueProviderStateRemainInspectableWithStaleSnapshotRejection() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        var raw = try fixtureProfile().raw; raw["routing"] = ["replayPolicy":"pinned","expectedModel":"fixture-model","replayContract":"fixture-stable"]
        let profile = try Profile(raw)
        var messages = (0..<70).map { ChatMessage(role:"user",content:[textBlock("retained \($0)")]) }
        var assistant = ChatMessage(role:"assistant",content:[textBlock("Visible answer")])
        assistant.providerItems = [["type":"reasoning","id":"reason","encrypted_content":"opaque-provider-state","summary":[]],["type":"message","role":"assistant","content":[["type":"output_text","text":"Visible answer"]]]]
        assistant.providerBinding = try ProviderClient.replayBinding(profile)
        assistant.providerIdentity = ["status":"reported","effectiveModel":"fixture-model"]
        messages.append(assistant)
        let session = try AgentSession(id:"paged",profile:profile,apiKey:"synthetic-secret-for-preview",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:ScriptClient([]),tools:RecordingTools(),traces:TraceStore(),seed:messages,autoCompaction:false)
        let preview = try await session.prepareContext([:]); var ids: [String] = [], cursor = preview
        while true {
            ids += cursor["items"].list.map { $0["id"].text! }
            guard let offset = cursor["next"].int else { break }
            cursor = try await session.readPreparedContext(["revision":preview["revision"],"itemOffset":JSON(offset)])
        }
        XCTAssertEqual(ids.count,76); XCTAssertTrue(ids.contains("input:71"))
        let opaque = try await session.readPreparedContext(["revision":preview["revision"],"section":"input:70"])
        XCTAssertTrue(opaque["text"].text!.contains("opaque-provider-state"))
        let newer = try await session.prepareContext(["text":"Changed preview"])
        do { _ = try await session.readPreparedContext(["revision":preview["revision"],"section":"request"]); XCTFail("Superseded preview was readable") }
        catch let error as AgentError { XCTAssertEqual(error.code,"context_preview_expired") }
        let fresh = try await session.readPreparedContext(["revision":newer["revision"],"section":"input:72"])
        XCTAssertTrue(fresh["text"].text!.contains("Changed preview"),"A stale reader must not invalidate the newer immutable snapshot")
        await session.close()
    }

    func testKnownCredentialsStayOutOfPreparedContextAndDisabledSkillsDoNotAuthorize() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let codex = root.appendingPathComponent(".codex"), folder = codex.appendingPathComponent("skills/example")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let source = folder.appendingPathComponent("SKILL.md"), content = Data("---\nname: example\ndescription: Fixture example\n---\nSkill body with Unicode 🙂".utf8)
        try content.write(to:source)
        let config = codex.appendingPathComponent("config.toml"), configData = Data("project_doc_max_bytes = 8192\n".utf8); try configData.write(to:config)
        let resources = Resources(cwd:root,home:root), catalog = try await resources.inspect([:])
        let skill = try XCTUnwrap(catalog["skills"].list.first), selection: JSON = ["id":skill["id"],"contentHash":skill["contentHash"],"metadataHash":skill["metadataHash"],"intent":"picker","arguments":"explain"]
        let frozen = try await resources.freeze([selection],text:"",tools:[])
        try await resources.configure(["disabled":[skill["id"]]])
        let disabled = try await resources.inspect([:]); XCTAssertEqual(disabled["skills"].list.first?["policy"].text,"disabled")
        let snapshot = try await resources.resolve(); XCTAssertFalse(snapshot.prompt.contains("Fixture example"))
        do { _ = try await resources.freeze([selection],text:"",tools:[]); XCTFail("Disabled skill selected") } catch {}
        do { try await resources.validate(frozen); XCTFail("Queued disabled skill delivered") } catch {}
        XCTAssertEqual(try Data(contentsOf:source),content); XCTAssertEqual(try Data(contentsOf:config),configData)
        let session = try AgentSession(id:"private",profile:fixtureProfile(),apiKey:"synthetic-secret-for-preview",cwd:root,directory:root.appendingPathComponent("state"),readOnly:true,resources:resources,client:ScriptClient([]),tools:RecordingTools(),traces:TraceStore(),autoCompaction:false)
        let preview = try await session.prepareContext(["text":"Do not expose synthetic-secret-for-preview"])
        let page = try await session.readPreparedContext(["revision":preview["revision"],"section":"request"])
        XCTAssertEqual(preview["credentialsRedacted"].flag,true)
        XCTAssertFalse(page["text"].text!.contains("synthetic-secret-for-preview")); XCTAssertTrue(page["text"].text!.contains("sha256:"))
        await session.close()
    }
}
