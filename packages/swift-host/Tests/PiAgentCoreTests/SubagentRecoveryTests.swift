import XCTest
@testable import PiAgentCore

final class SubagentRecoveryTests: HelperTestCase {
    func testNativeCostsAllowAnUnstartedLegacyChildWithoutAJournal() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try fixture.write()
        let host = NativeHostService(emit:{ _ in })
        _ = try await host.command("workspace.open",sessionID:nil,params:["cwd":JSON(fixture.root.path),"directory":JSON(fixture.root.path),"resources":["codexHome":JSON(fixture.root.appendingPathComponent("codex").path)]])
        _ = try await host.command("session.open",sessionID:"parent",params:["profile":fixture.profile.raw,"apiKey":"fixture","path":JSON(fixture.root.appendingPathComponent("parent.jsonl").path)])
        let page = try await host.command("subagent.list",sessionID:"parent",params:["includeCosts":true])
        XCTAssertEqual(page["children"].list.first?["status"].text,"not_executed")
        XCTAssertTrue(page["costs"]["child"].isNull,"No child ledger exists; do not fabricate a zero snapshot")
        XCTAssertFalse(FileManager.default.fileExists(atPath:fixture.root.appendingPathComponent("child.jsonl").path))
        try Data("damaged existing journal\n".utf8).write(to:fixture.root.appendingPathComponent("child.jsonl"))
        do {
            _ = try await host.command("subagent.list",sessionID:"parent",params:["includeCosts":true])
            XCTFail("The optional absent ledger must not hide damaged existing history")
        } catch {}
        await host.shutdown()
    }

    func testCapturedTerminalCostRepairsOwnerAndMirrorExactlyOnceBeforeResume() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try fixture.write(childStatus: .running, admission: "dispatched")
        do {
            let journal = try SessionJournal(url: fixture.root.appendingPathComponent("parent.jsonl"), id: "parent", cwd: fixture.root, binding: nil, create: false)
            try journal.append(["type":"custom", "customType":JSON(JournalRecordKind.cost), "data":["usd":0.9,"reported":1,"unreported":0,"source":"family-adoption"]])
        }
        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd":JSON(fixture.root.path),"directory":JSON(fixture.root.path)])
        _ = try await host.command("session.open", sessionID: "parent", params: ["profile":fixture.profile.raw,"apiKey":"fixture","costLimit":["usd":1],"path":JSON(fixture.root.appendingPathComponent("parent.jsonl").path)])
        do {
            let attempts = try await host.command("budget.attempts", sessionID: "parent", params: [:])
            XCTAssertEqual(attempts["attemptIds"].list.compactMap(\.text), ["physical"])
            let evidence: JSON = ["attemptId":"physical", "sessionId":"child", "turnId":"turn", "purpose":"turn", "outcome":"completed",
                "requestScope":try subagentJSON(fixture.scope), "gateway":["cost":["status":"reported","usd":0.2]], "usage":["inputIncludingCache":20,"output":5]]
            for _ in 0..<2 { _ = try await host.command("budget.reconcile", sessionID: "parent", params: ["evidence":.array([evidence])]) }
            let loaded = await host.loadedSession("parent"), parent = try XCTUnwrap(loaded), spend = await parent.spend
            XCTAssertEqual(spend.usd, 1.1, accuracy: 0.000001); XCTAssertEqual(spend.reported, 2); XCTAssertEqual(spend.unreported, 0)
            _ = try await host.command("run.continue", sessionID: "parent", params: [:], commandID: "resume")
            try await eventually { !(await parent.isRunning) }
            let state = await parent.snapshot()
            XCTAssertEqual(state["errorCode"].text, "cost_limit", "Resume must stop before dispatch against the repaired total")
            let child = try fixture.openChild(), mirrored = await child.spend
            XCTAssertEqual(mirrored.usd, 0.2); XCTAssertEqual(mirrored.reported, 1)
            await child.close()
            var foreign = evidence; foreign["sessionId"] = "other"
            do { _ = try await host.command("budget.reconcile", sessionID: "parent", params: ["evidence":.array([foreign])]); XCTFail("Foreign evidence accepted") } catch { }
        } catch { XCTFail("Retained terminal capture cannot reconcile the ledger: \(error)") }
        await host.shutdown()
        let restored = try fixture.open(), spend = await restored.spend
        XCTAssertEqual(spend.usd, 1.1, accuracy: 0.000001)
        await restored.close()
    }

    func testCapturedEvidenceCannotImportUnregisteredForeignOrUndispatchedCharges() async throws {
        for kind in ["unregistered", "source", "turn", "owner", "scope", "running", "admitted", "unknown"] {
            let fixture = try RecoveryFixture(); defer { fixture.remove() }
            try fixture.write(childStatus: .running, admission: kind == "admitted" ? "admitted" : "dispatched")
            let parent = try fixture.open()
            var evidence: JSON = ["attemptId":"physical", "sessionId":"child", "turnId":"turn", "purpose":"turn", "outcome":"completed",
                "requestScope":try subagentJSON(fixture.scope), "gateway":["cost":["status":"reported","usd":0.2]]]
            switch kind {
            case "unregistered": evidence["attemptId"] = "other"
            case "source": evidence["sessionId"] = "other"
            case "turn": evidence["turnId"] = "other"
            case "owner": evidence["requestScope"]["budgetOwnerSessionID"] = "other"
            case "scope": evidence["requestScope"]["executionID"] = "other"
            case "running": evidence["outcome"] = "running"
            case "unknown": evidence["gateway"]["cost"] = ["status":"unreported"]
            default: break
            }
            do { _ = try await parent.reconcileCapturedAccounting([evidence]); XCTAssertEqual(kind, "unknown", "Invalid evidence was accepted: " + kind) }
            catch { XCTAssertNotEqual(kind, "unknown") }
            let spend = await parent.spend
            XCTAssertEqual(spend.usd, 0); XCTAssertEqual(spend.unreported, kind == "admitted" ? 0 : 1)
            await parent.close()
        }
    }

    func testFailedCapturedCostMirrorKeepsTheOwnerChargeAndRepairsOnReopen() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try fixture.write(childStatus: .running, admission: "dispatched")
        let parent = try fixture.open(), locked = try fixture.openChild()
        let evidence: JSON = ["attemptId":"physical", "sessionId":"child", "turnId":"turn", "purpose":"turn", "outcome":"completed",
            "requestScope":try subagentJSON(fixture.scope), "gateway":["cost":["status":"reported","usd":0.2]]]
        do { _ = try await parent.reconcileCapturedAccounting([evidence]); XCTFail("An unavailable mirror cannot report successful settlement") } catch { }
        let charged = await parent.spend, failure = await parent.accountingFailure
        XCTAssertEqual(charged.usd, 0.2); XCTAssertNotNil(failure)
        await parent.close(); await locked.close()
        let restored = try fixture.open(), repaired = try fixture.openChild()
        let ownerSpend = await restored.spend, childSpend = await repaired.spend
        XCTAssertEqual(ownerSpend.usd, 0.2); XCTAssertEqual(ownerSpend.reported, 1)
        XCTAssertEqual(childSpend.usd, 0.2); XCTAssertEqual(childSpend.reported, 1)
        await restored.close(); await repaired.close()
    }

    func testParentOpenReleasesEveryRestoredFamilyReaderAndInvalidatesTheViewers() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try fixtureProfile(), frames = RecoveryUnloadFrames()
        try writeReaderFamily(root, profile: profile, owner: "parent", children: ["first", "second"])
        try writeReaderFamily(root, profile: profile, owner: "other", children: ["unrelated"])
        let host = NativeHostService(emit: { frames.append($0) })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd":JSON(root.path), "directory":JSON(root.path), "resources":["codexHome":JSON(root.appendingPathComponent("codex").path)]])
        func open(_ id: String) async throws -> JSON {
            try await host.command("session.open", sessionID: id, params: ["profile":profile.raw, "apiKey":"fixture", "path":JSON(root.appendingPathComponent(id + ".jsonl").path)])
        }
        for id in ["first", "second", "unrelated"] { _ = try await open(id) }
        let first = await host.loadedSession("first"), second = await host.loadedSession("second"), unrelated = await host.loadedSession("unrelated")
        do {
            let parent = try await open("parent")
            XCTAssertEqual(parent["state"].text, "paused")
            XCTAssertEqual(Set(frames.unloaded), ["first", "second"], "Every detached reader must invalidate the app's opened set")
            for id in ["first", "second"] {
                let released = await host.loadedSession(id)
                XCTAssertNil(released)
                _ = try await open(id)
                let child = await host.loadedSession(id), status = await child?.subagents.status
                XCTAssertEqual(status, .notExecuted, "Reopening reads the owner's repaired terminal record")
                XCTAssertFalse(child === first); XCTAssertFalse(child === second)
            }
            let untouched = await host.loadedSession("unrelated")
            XCTAssertTrue(untouched === unrelated, "Another budget owner's reader stays attached")
            _ = try await open("parent")
            let attached = await host.loadedSession("first")
            XCTAssertNotNil(attached, "An already loaded owner does not recover or evict its viewers again")
        } catch { XCTFail("Parent recovery failed with open child readers: \(error)") }
        await host.shutdown()
    }

    func testParentRecoveryCannotDetachAnUnsettledManagedChild() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try fixtureProfile(), frames = RecoveryUnloadFrames()
        try writeReaderFamily(root, profile: profile, owner: "parent", children: ["child"])
        let host = NativeHostService(emit: { frames.append($0) })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd":JSON(root.path), "directory":JSON(root.path), "resources":["codexHome":JSON(root.appendingPathComponent("codex").path)]])
        _ = try await host.command("session.open", sessionID: "child", params: ["profile":profile.raw, "apiKey":"fixture", "path":JSON(root.appendingPathComponent("child.jsonl").path)])
        let loaded = await host.loadedSession("child"), child = try XCTUnwrap(loaded)
        let origin = await child.subagents.origin
        await child.installManagedCancellation(SubagentCoordinator(), key: try XCTUnwrap(origin).link.call)
        do {
            _ = try await host.command("session.open", sessionID: "parent", params: ["profile":profile.raw, "apiKey":"fixture", "path":JSON(root.appendingPathComponent("parent.jsonl").path)])
            XCTFail("Unsettled live work cannot be detached for recovery")
        } catch let error as AgentError { XCTAssertEqual(error.code, "session_busy") }
        let retained = await host.loadedSession("child"), journal = await child.journal
        XCTAssertTrue(retained === child); XCTAssertNotNil(journal); XCTAssertTrue(frames.unloaded.isEmpty)
        await host.shutdown()
    }

    func testSavedChildTerminalIsAdoptedExactlyOnceWithoutRunningAnything() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        let expected = SubagentToolResult(plan: fixture.plan, status: .completed, text: "durable answer", messageIDs: ["final"], began: true)
        try fixture.write(childStatus: .running, terminal: expected)
        for _ in 0..<2 {
            let parent = try fixture.open(), rows = await parent.history.filter { $0.toolName == "subagent" }
            XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.id, "result")
            XCTAssertEqual(rows.first?.text, expected.envelope.encoded()); XCTAssertEqual(rows.first?.nativeSubagent, expected.metadata)
            let paused = await parent.queuePaused, running = await parent.isRunning, continuable = await parent.canContinue
            XCTAssertTrue(paused); XCTAssertFalse(running); XCTAssertTrue(continuable)
            await parent.close()
        }
    }

    func testEachCreationBoundaryBecomesAnExplicitNonReplayableResult() async throws {
        for stage in ["no-plan", "plan-only", "queued", "running", "admitted", "dispatched"] {
            let fixture = try RecoveryFixture(); defer { fixture.remove() }
            try fixture.write(plan: stage != "no-plan", childStatus: ["queued", "running", "admitted", "dispatched"].contains(stage) ? (stage == "queued" ? .queued : .running) : nil,
                              admission: stage == "admitted" || stage == "dispatched" ? stage : nil)
            let parent = try fixture.open(), rows = await parent.history.filter { $0.toolName == "subagent" }
            let result = try XCTUnwrap(rows.first), envelope = try JSON.parse(Data(result.text.utf8))
            XCTAssertEqual(envelope["status"].text, ["no-plan", "plan-only", "queued"].contains(stage) ? "not_executed" : "interrupted", stage)
            let spend = await parent.spend
            XCTAssertEqual(spend.unreported, stage == "dispatched" ? 1 : 0, stage)
            await parent.close()
        }
    }

    func testMissingExecutedChildBlocksRecoveryButNeverDispatchedChildDoesNot() async throws {
        for state in ["admitted", "dispatched"] {
            let fixture = try RecoveryFixture(); defer { fixture.remove() }
            try fixture.write(childStatus: .running, admission: state)
            try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("child.jsonl"))
            if state == "dispatched" {
                XCTAssertThrowsError(try fixture.open()) { XCTAssertEqual(($0 as? AgentError)?.code, "subagent_recovery") }
                let records = try String(contentsOf: fixture.root.appendingPathComponent("parent.jsonl"), encoding: .utf8)
                XCTAssertTrue(records.contains("toolCall"), "Saved history remains inspectable")
            } else {
                let parent = try fixture.open(), result = await parent.history.first { $0.toolName == "subagent" }
                XCTAssertEqual(result?.nativeSubagent?["status"].text, "not_executed")
                await parent.close()
            }
        }
    }

    func testMarkerOnlyChildCreationIsCompletedFromTheDurableParentPlan() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try fixture.write(childStatus: .queued, damage: "incomplete-origin")
        let parent = try fixture.open(), result = await parent.history.first { $0.toolName == "subagent" }
        XCTAssertEqual(result?.nativeSubagent?["status"].text, "not_executed")
        await parent.close()
        let child = try fixture.openChild(), origin = await child.subagents.origin, status = await child.subagents.status
        XCTAssertEqual(origin, fixture.plan.origin); XCTAssertEqual(status, .notExecuted)
        await child.close()
    }

    func testReciprocalIdentityAndSavedResultIdentityAreRequired() async throws {
        for damaged in ["origin", "result", "marker", "result-status", "result-ref"] {
            let fixture = try RecoveryFixture(); defer { fixture.remove() }
            var terminal = SubagentToolResult(plan: fixture.plan, status: .completed, text: "answer")
            if damaged == "result" { terminal.metadata["sessionId"] = "unrelated" }
            if damaged == "result-status" { terminal.metadata["status"] = "failed" }
            if damaged == "result-ref" { terminal.metadata["resultRef"] = ["messageIds":["missing"]] }
            try fixture.write(childStatus: .running, terminal: terminal, damage: damaged)
            XCTAssertThrowsError(try fixture.open(), damaged)
        }
    }

    func testRecoveredChildCostUsesOnlyTheOwnersRegisteredPhysicalAttempt() async throws {
        for ownerHasCost in [false, true] {
            let fixture = try RecoveryFixture(); defer { fixture.remove() }
            try fixture.write(childStatus: .running, admission: "dispatched", ownerCost: ownerHasCost, childCost: !ownerHasCost)
            for _ in 0..<2 {
                let parent = try fixture.open(), total = await parent.spend
                XCTAssertEqual(total.usd, 0.75); XCTAssertEqual(total.reported, 1); XCTAssertEqual(total.unreported, 0)
                await parent.close()
            }
            let child = try fixture.openChild(), total = await child.spend
            XCTAssertEqual(total.usd, 0.75); XCTAssertEqual(total.reported, 1)
            await child.close()
        }
    }

    func testRecoveredChildReaderCanUnloadBeforeOpeningItsParent() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try fixture.write(childStatus: .queued)
        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd":JSON(fixture.root.path),"directory":JSON(fixture.root.path),"resources":["codexHome":JSON(fixture.root.appendingPathComponent("codex").path)]])
        _ = try await host.command("session.open", sessionID: "child", params: ["profile":fixture.profile.raw,"apiKey":"fixture","path":JSON(fixture.root.appendingPathComponent("child.jsonl").path)])
        _ = try await host.command("session.close", sessionID: "child", params: [:])
        for id in ["parent", "child"] {
            _ = try await host.command("session.open", sessionID: id, params: ["profile":fixture.profile.raw,"apiKey":"fixture","path":JSON(fixture.root.appendingPathComponent(id + ".jsonl").path)])
        }
        let state = try await host.command("session.snapshot", sessionID: "parent", params: [:])
        XCTAssertEqual(state["state"].text, "paused")
        await host.shutdown()
    }

    func testReopenedChildKeepsItsParentsCapturePolicy() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try fixture.write(childStatus: .queued)
        let host = NativeHostService(emit: { _ in })
        _ = try await host.command("workspace.open", sessionID: nil, params: ["cwd":JSON(fixture.root.path),"directory":JSON(fixture.root.path)])
        _ = try await host.command("session.open", sessionID: "parent", params: ["profile":fixture.profile.raw,"apiKey":"fixture","captureMode":"off","path":JSON(fixture.root.appendingPathComponent("parent.jsonl").path)])
        let child = try await host.command("session.open", sessionID: "child", params: ["profile":fixture.profile.raw,"apiKey":"fixture","captureMode":"persist","path":JSON(fixture.root.appendingPathComponent("child.jsonl").path)])
        XCTAssertEqual(child["captureMode"].text, "off")
        do { _ = try await host.command("debug.mode", sessionID: "child", params: ["mode":"memory"]); XCTFail("Child policy changed") }
        catch let error as AgentError { XCTAssertEqual(error.code, "managed_subagent") }
        await host.shutdown()
    }

    func testTerminalRecordIsSynchronizedBeforeReturningTheResult() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try fixture.write(childStatus: .queued)
        let child = try fixture.openChild(), before = await child.journal?.synchronizations
        try await child.saveSubagentTerminal(SubagentToolResult(plan: fixture.plan, status: .notExecuted))
        let after = await child.journal?.synchronizations
        XCTAssertEqual(after, (before ?? 0) + 1)
        await child.close()
    }

    func testUnregisteredChildCostCannotBeImported() throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try fixture.write(childStatus: .running, childCost: true)
        XCTAssertThrowsError(try fixture.open())
    }

    func testOldHelpersExistingResultIsPreservedDuringReupgrade() async throws {
        let fixture = try RecoveryFixture(); defer { fixture.remove() }
        try fixture.write(childStatus: .running, terminal: SubagentToolResult(plan: fixture.plan, status: .completed, text: "child complete"), oldResult: true)
        let parent = try fixture.open(), rows = await parent.history.filter { $0.toolName == "subagent" }
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.id, "old-result"); XCTAssertEqual(rows.first?.text, "Old helper: outcome unknown")
        let savedAssistant = await parent.history.first { $0.id == "reply" }
        let assistant = try XCTUnwrap(savedAssistant)
        let displayed = await parent.displayMessage(assistant)
        XCTAssertEqual(displayed["tools"].list.first?["subagent"]["link"]["childSessionID"].text, "child")
        XCTAssertEqual(displayed["tools"].list.first?["subagent"]["status"].text, "interrupted")
        let listed = await SubagentCoordinator().list(parent: parent)
        XCTAssertEqual(listed["children"].list.first?["status"].text, "interrupted", "A recovered old-helper result is not an in-flight preparation")
        await parent.close()
    }
}

private final class RecoveryUnloadFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [JSON] = []
    func append(_ frame: JSON) { lock.lock(); defer { lock.unlock() }; frames.append(frame) }
    var unloaded: [String] { lock.lock(); defer { lock.unlock() }; return frames.filter { $0["type"].text == "session.unloaded" }.compactMap { $0["sessionId"].text } }
}

private func writeReaderFamily(_ root: URL, profile: Profile, owner: String, children: [String]) throws {
    let parent = try SessionJournal(url: root.appendingPathComponent(owner + ".jsonl"), id: owner, cwd: root, binding: profile.binding, create: true)
    var task = ChatMessage(role: "user", content: [textBlock("task")]); task.id = "turn"
    try parent.append(["type":"message", "message":task.pi], id: task.id)
    var assistant = ChatMessage(role: "assistant", content: children.map { ["type":"toolCall", "id":JSON($0), "name":"subagent", "arguments":["task":"task"]] })
    assistant.id = "reply"; assistant.turn = "turn"
    try parent.append(["type":"message", "message":assistant.pi], id: assistant.id)
    for id in children {
        var origin = subagentFixtureOrigin(child: id, parent: owner, call: id); origin.link.delegationID = "delegation-" + id
        let plan = SubagentPlan(origin: origin, task: "task", resultMessageID: "result-" + id)
        try parent.append(["type":"custom", "customType":JSON(JournalRecordKind.subagentCall), "data":try subagentJSON(plan)])
        let child = try SessionJournal(url: root.appendingPathComponent(id + ".jsonl"), id: id, cwd: root, binding: profile.binding, create: true, managedChild: true)
        try child.append(["type":"custom", "customType":JSON(JournalRecordKind.subagentOrigin), "data":try subagentJSON(origin)])
        try child.append(["type":"custom", "customType":JSON(JournalRecordKind.subagentState), "data":["delegationID":JSON(origin.link.delegationID), "status":"queued"]])
    }
    try parent.append(["type":"custom", "customType":JSON(JournalRecordKind.state), "data":["active":true,"queue":[],"steering":[],"commands":[]]])
}

private struct RecoveryFixture {
    let root: URL, profile: Profile
    let plan = SubagentPlan(origin: subagentFixtureOrigin(), task: "task", resultMessageID: "result")
    init() throws { root = try temporaryDirectory(); profile = try fixtureProfile() }
    var scope: RequestScope { RequestScope(sourceSessionID: "child", budgetOwnerSessionID: "parent", turnID: "turn", executionID: "child-run", purpose: "turn", ownerGeneration: 0, delegation: plan.origin.link) }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func write(plan hasPlan: Bool = true, childStatus: SubagentStatus? = nil, terminal: SubagentToolResult? = nil,
               admission: String? = nil, ownerCost: Bool = false, childCost: Bool = false, damage: String? = nil, oldResult: Bool = false) throws {
        let parent = try SessionJournal(url: root.appendingPathComponent("parent.jsonl"), id: "parent", cwd: root, binding: profile.binding, create: true)
        var task = ChatMessage(role: "user", content: [textBlock("task")]); task.id = "turn"
        try parent.append(["type":"message", "message":task.pi], id: task.id)
        var assistant = toolReply([]).message
        assistant.content = [["type":"toolCall","id":"call","name":"subagent","arguments":["task":"task"]]]
        assistant.id = "reply"; assistant.turn = "turn"
        try parent.append(["type":"message", "message":assistant.pi], id: assistant.id)
        if hasPlan { try parent.append(["type":"custom","customType":JSON(JournalRecordKind.subagentCall),"data":try subagentJSON(plan)]) }
        if let admission { var record = admissionRecord("physical"); record["state"] = JSON(admission); record["scope"] = try subagentJSON(scope)
            try parent.append(["type":"custom","customType":JSON(JournalRecordKind.budgetAttempt),"data":record]) }
        let cost = costRecord("physical", usd: 0.75, revision: 2)
        if ownerCost { try parent.append(["type":"custom","customType":JSON(JournalRecordKind.cost),"data":cost]) }
        if oldResult {
            var result = ChatMessage(role: "toolResult", content: [textBlock("Old helper: outcome unknown")]); result.toolName = "subagent"; result.toolCallId = "call"; result.isError = true; result.toolStats = ["outcome":"unknown"]
            try parent.append(["type":"message","message":result.pi], id: "old-result")
        }
        try parent.append(["type":"custom","customType":JSON(JournalRecordKind.state),"data":["active":true,"queue":[],"steering":[],"commands":[]]])
        if let childStatus {
            let child = try SessionJournal(url: root.appendingPathComponent("child.jsonl"), id: "child", cwd: root, binding: profile.binding, create: true, managedChild: damage != "marker")
            if damage == "incomplete-origin" { return }
            var origin = plan.origin
            if damage == "origin" { origin.description = "forged grant" }
            try child.append(["type":"custom","customType":JSON(JournalRecordKind.subagentOrigin),"data":try subagentJSON(origin)])
            try child.append(["type":"custom","customType":JSON(JournalRecordKind.subagentState),"data":["delegationID":"delegation","status":JSON(childStatus.rawValue)]])
            if childCost { try child.append(["type":"custom","customType":JSON(JournalRecordKind.cost),"data":cost]) }
            if let terminal, damage != "result-ref" {
                for id in terminal.metadata["resultRef"]["messageIds"].list.compactMap(\.text) {
                    let reply = ChatMessage(role: "assistant", content: [textBlock(terminal.envelope["text"].text ?? "")])
                    try child.append(["type":"message","message":reply.pi], id: id)
                }
            }
            if let terminal { try child.append(["type":"custom","customType":JSON(JournalRecordKind.subagentTerminal),"data":["delegationID":"delegation","status":JSON(terminal.status.rawValue),"result":try subagentJSON(terminal)]]) }
        }
    }
    func open() throws -> AgentSession { try session("parent") }
    func openChild() throws -> AgentSession { try session("child") }
    private func session(_ id: String) throws -> AgentSession {
        try AgentSession(id: id, profile: profile, apiKey: "fixture", cwd: root, directory: root, readOnly: true,
                         resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(),
                         resumePath: root.appendingPathComponent(id + ".jsonl").path)
    }
}
