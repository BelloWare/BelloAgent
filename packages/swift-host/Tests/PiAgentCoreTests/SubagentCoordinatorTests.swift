import XCTest
@testable import PiAgentCore

final class SubagentCoordinatorTests: XCTestCase {
    func testEighteenCallsUseSixteenSlotsAndQueuedCallsAdvanceInOrder() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DelegationClient(count: 18), registered = DelegationRegistry()
        let coordinator = SubagentCoordinator(register: { child, _, _, _ in await registered.add(child) })
        let parent = try await makeParent(root, client: client, coordinator: coordinator)
        _ = try await parent.submit(Submission(commandID: "command", turnID: "turn", text: "PRIVATE PARENT CONTEXT"), steer: false)
        try await eventually { await client.started["parent"]?.count == 16 }
        let first = await client.started["parent"] ?? []
        XCTAssertEqual(Set(first), Set(0..<16))
        let pending = await coordinator.list(parent: parent)
        XCTAssertEqual(pending["children"].list.count, 18); XCTAssertEqual(pending["active"].int, 16)
        let page1 = await coordinator.list(parent: parent, limit: 7)
        let page2 = await coordinator.list(parent: parent, cursor: try XCTUnwrap(page1["cursor"].int), limit: 7)
        let page3 = await coordinator.list(parent: parent, cursor: try XCTUnwrap(page2["cursor"].int), limit: 7)
        XCTAssertEqual((page1["children"].list + page2["children"].list + page3["children"].list).compactMap { $0["description"].text }, (0..<18).map(String.init))
        XCTAssertTrue(page3["cursor"].isNull); XCTAssertEqual(page1["total"].int, 18)
        await client.release(0, owner: "parent")
        try await eventually { await client.started["parent"]?.count == 17 }
        let next = await client.started["parent"]?.last
        XCTAssertEqual(next, 16)
        await client.release(1, owner: "parent")
        try await eventually { await client.started["parent"]?.count == 18 }
        let last = await client.started["parent"]?.last
        XCTAssertEqual(last, 17)
        await client.releaseAll()
        try await eventually { !(await parent.isRunning) }
        let retained = await coordinator.retainedJobCount
        XCTAssertEqual(retained, 0)
        let rows = await parent.history, results = rows.filter { $0.toolName == "subagent" }
        XCTAssertEqual(results.count, 18)
        XCTAssertEqual(results.map(\.toolCallId), (0..<18).map { "call-\($0)" })
        XCTAssertTrue(results.allSatisfy { (try? JSON.parse(Data($0.text.utf8)))?["status"].text == "completed" })
        let total = await parent.spend, maximum = await client.maximumActive
        XCTAssertEqual(total.reported, 20); XCTAssertEqual(total.usd, 0.20, accuracy: 1e-8); XCTAssertEqual(maximum, 16)
        let children = await registered.children
        XCTAssertEqual(children.count, 18)
        for child in children {
            let history = await child.history, own = await child.spend, origin = await child.subagents.origin
            XCTAssertEqual(history.filter { $0.role == "user" }.count, 1)
            XCTAssertFalse(history.contains { $0.text.contains("PRIVATE PARENT CONTEXT") })
            XCTAssertEqual(own.reported, 1); XCTAssertEqual(origin?.tools, ["first", "second"])
            await child.enableSubagents(coordinator)
            let definitions = await child.sessionDefinitions()
            XCTAssertFalse(definitions.contains { $0.name == "subagent" }, "Depth one applies even when a coordinator is attached")
            let terminal = await child.subagents.terminal
            let result = try XCTUnwrap(results.first { $0.nativeSubagent?["sessionId"].text == origin?.link.childSessionID })
            XCTAssertEqual(terminal?["result"]["metadata"], result.nativeSubagent)
            XCTAssertEqual(terminal?["result"]["envelope"].encoded(), result.text)
            await child.close()
        }
        let body = await client.lastParentBody["parent"] ?? ""
        for result in results {
            XCTAssertFalse(body.contains(result.nativeSubagent?["sessionId"].text ?? "missing"))
            XCTAssertFalse(body.contains(result.nativeSubagent?["delegationId"].text ?? "missing"))
        }
        let plans = await parent.subagents.plans.values, path = await parent.path
        XCTAssertEqual(plans.filter { $0.adoptionSeed != nil }.count, 1)
        XCTAssertEqual(plans.compactMap(\.adoptionSeed).first?["usd"].double, 0.01)
        await parent.close()
        let restored = try AgentSession(id: "parent", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root,
            readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), resumePath: path)
        let spend = await restored.spend, enabled = await restored.familyBudgetEnabled
        XCTAssertEqual(spend, total); XCTAssertTrue(enabled)
        await restored.close()
    }

    func testTwoOwnersHaveIndependentLimitsWithoutAHelperWideCap() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DelegationClient(count: 17), registry = DelegationRegistry()
        let coordinator = SubagentCoordinator(register: { child, _, _, _ in await registry.add(child) })
        let a = try await makeParent(root, id: "owner-a", client: client, coordinator: coordinator)
        let b = try await makeParent(root, id: "owner-b", client: client, coordinator: coordinator)
        _ = try await a.submit(Submission(commandID: "a", turnID: "a", text: "tasks"), steer: false)
        _ = try await b.submit(Submission(commandID: "b", turnID: "b", text: "tasks"), steer: false)
        try await eventually { await client.active == 32 }
        let activeA = await coordinator.list(parent: a), activeB = await coordinator.list(parent: b)
        XCTAssertEqual(activeA["active"].int, 16); XCTAssertEqual(activeB["active"].int, 16)
        await client.releaseAll()
        try await eventually { let runningA = await a.isRunning, runningB = await b.isRunning; return !runningA && !runningB }
        for child in await registry.children { await child.close() }
        await a.close(); await b.close()
    }

    func testParentStopSettlesRunningAndQueuedChildrenWithoutAutomaticReplay() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DelegationClient(count: 18), registry = DelegationRegistry()
        let coordinator = SubagentCoordinator(register: { child, _, _, _ in await registry.add(child) })
        let parent = try await makeParent(root, client: client, coordinator: coordinator)
        _ = try await parent.submit(Submission(commandID: "command", turnID: "turn", text: "tasks"), steer: false)
        try await eventually { await client.active == 16 }
        await parent.stop()
        try await eventually { !(await parent.isRunning) }
        let results = await parent.history.filter { $0.toolName == "subagent" }
        XCTAssertEqual(results.count, 18)
        let statuses = results.compactMap { (try? JSON.parse(Data($0.text.utf8)))?["status"].text }
        XCTAssertEqual(statuses.filter { $0 == "not_executed" }.count, 2)
        XCTAssertEqual(statuses.filter { $0 == "interrupted" }.count, 16)
        let before = await client.started["parent"]?.count
        XCTAssertEqual(before, 16)
        _ = try await parent.continueRun(commandID: "resume")
        try await eventually { !(await parent.isRunning) }
        let after = await client.started["parent"]?.count
        XCTAssertEqual(after, before, "Resume asks the parent model, never replays the cut-off delegations")
        for child in await registry.children { let running = await child.isRunning; XCTAssertFalse(running); await child.close() }
        await parent.close()
    }

    func testEscapedLargeResultRemainsInlineAndItsLocalIDsStayOutOfModelText() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DelegationClient(count: 1, text: String(repeating: "\"", count: 70_000)), registry = DelegationRegistry()
        await client.releaseAll()
        let coordinator = SubagentCoordinator(register: { child, _, _, _ in await registry.add(child) })
        let parent = try await makeParent(root, client: client, coordinator: coordinator)
        _ = try await parent.submit(Submission(commandID: "command", turnID: "turn", text: "task"), steer: false)
        try await eventually { !(await parent.isRunning) }
        let row = await parent.history.first { $0.toolName == "subagent" }
        let result = try XCTUnwrap(row), envelope = try JSON.parse(Data(result.text.utf8))
        XCTAssertEqual(envelope["text"].text?.utf8.count, 65_536); XCTAssertEqual(envelope["truncated"].flag, true)
        XCTAssertGreaterThan(result.text.utf8.count, 65_536, "JSON escaping must not trigger generic file offloading")
        XCTAssertFalse(result.text.contains("Full output:"))
        for child in await registry.children { await child.close() }
        await parent.close()
    }

    func testCompletedJobsReleaseTheirParentAndConnectionEnvironment() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DelegationClient(count: 1), coordinator = SubagentCoordinator()
        await client.releaseAll()
        weak var owner: AgentSession?
        do {
            let parent = try await makeParent(root, client: client, coordinator: coordinator); owner = parent
            _ = try await parent.submit(Submission(commandID: "command", turnID: "turn", text: "task"), steer: false)
            try await eventually { !(await parent.isRunning) }
            await parent.close()
        }
        try await eventually { owner == nil }
        let parent = try AgentSession(id: "parent", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root,
            readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), resumePath: root.appendingPathComponent("parent.jsonl").path)
        let saved = await coordinator.list(parent: parent), retained = await coordinator.retainedJobCount
        XCTAssertEqual(saved["children"].list.count, 1, "Summaries survive runtime release")
        XCTAssertEqual(saved["children"].list.first?["status"].text, "completed")
        XCTAssertEqual(retained, 0, "Consumed jobs and plans must leave coordinator memory")
        await parent.close()
    }

    func testOneChildStopLeavesItsSiblingAndParentRunning() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DelegationClient(count: 2), registry = DelegationRegistry()
        let coordinator = SubagentCoordinator(register: { child, _, _, _ in await registry.add(child) })
        let parent = try await makeParent(root, client: client, coordinator: coordinator)
        _ = try await parent.submit(Submission(commandID: "command", turnID: "turn", text: "tasks"), steer: false)
        try await eventually { await client.active == 2 }
        let first = await registry.children.first, child = try XCTUnwrap(first)
        let origin = await child.subagents.origin, link = try XCTUnwrap(origin?.link)
        do { try await coordinator.stop(owner: "unrelated", delegationID: link.delegationID); XCTFail("Another owner cannot stop this child") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "subagent_scope") }
        try await coordinator.stop(owner: "parent", delegationID: link.delegationID)
        try await eventually { await client.active == 1 }
        let running = await parent.isRunning, paused = await parent.queuePaused
        XCTAssertTrue(running); XCTAssertFalse(paused)
        await client.releaseAll()
        try await eventually { !(await parent.isRunning) }
        let results = await parent.history.filter { $0.toolName == "subagent" }
        XCTAssertEqual(results.filter { $0.nativeSubagent?["status"].text == "interrupted" }.count, 1)
        XCTAssertEqual(results.filter { $0.nativeSubagent?["status"].text == "completed" }.count, 1)
        for child in await registry.children { await child.close() }
        await parent.close()
    }

    func testChildSettlementAtTheLimitStopsTheFamilyAndDoesNotDispatchQueuedCalls() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DelegationClient(count: 18), registry = DelegationRegistry()
        let coordinator = SubagentCoordinator(register: { child, _, _, _ in await registry.add(child) })
        let parent = try await makeParent(root, client: client, coordinator: coordinator)
        await parent.setCostLimit(0.02)
        _ = try await parent.submit(Submission(commandID: "command", turnID: "turn", text: "tasks"), steer: false)
        try await eventually { await client.active == 16 }
        await client.release(0, owner: "parent")
        try await eventually { !(await parent.isRunning) }
        let total = await parent.spend, count = await client.started["parent"]?.count, requests = await client.parents["parent"]
        XCTAssertEqual(count, 16); XCTAssertEqual(requests, 1)
        XCTAssertEqual(total.usd, 0.02, accuracy: 1e-8); XCTAssertEqual(total.reported, 2); XCTAssertEqual(total.unreported, 15)
        let results = await parent.history.filter { $0.toolName == "subagent" }, reason = await parent.familyStopReason
        XCTAssertEqual(results.count, 18); XCTAssertEqual(reason?.code, "cost_limit")
        XCTAssertEqual(results.filter { $0.nativeSubagent?["status"].text == "not_executed" }.count, 2)
        for child in await registry.children { let running = await child.isRunning; XCTAssertFalse(running); await child.close() }
        await parent.close()
    }

    func testInvalidGrantsCreateNoChildrenOrDelegationPlans() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DelegationClient(count: 2, arguments: [["task":"0","model":"not-offered"], ["task":"1","tools":["forbidden"]]])
        let coordinator = SubagentCoordinator(), parent = try await makeParent(root, client: client, coordinator: coordinator)
        _ = try await parent.submit(Submission(commandID: "command", turnID: "turn", text: "tasks"), steer: false)
        try await eventually { !(await parent.isRunning) }
        let listed = await coordinator.list(parent: parent), plans = await parent.subagents.plans, active = await client.active
        XCTAssertTrue(listed["children"].list.isEmpty); XCTAssertTrue(plans.isEmpty); XCTAssertEqual(active, 0)
        let results = await parent.history.filter { $0.toolName == "subagent" }
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(try results.map { try JSON.parse(Data($0.text.utf8))["error"]["code"].text }, ["subagent_model", "subagent_tools"])
        await parent.close()
    }

    func testAClosedChildJournalCannotPretendItsTerminalResultWasSaved() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DelegationClient(count: 1), registry = DelegationRegistry()
        let coordinator = SubagentCoordinator(register: { child, _, _, _ in
            await registry.add(child); await child.close()
        })
        let parent = try await makeParent(root, client: client, coordinator: coordinator)
        _ = try await parent.submit(Submission(commandID: "command", turnID: "turn", text: "task"), steer: false)
        try await eventually { !(await parent.isRunning) }
        let failure = await parent.familyStopReason, requests = await client.parents["parent"]
        XCTAssertEqual(failure?.code, "subagent_persistence"); XCTAssertEqual(requests, 1)
        for child in await registry.children {
            let terminal = await child.subagents.terminal
            XCTAssertNil(terminal, "No in-memory terminal result may pretend to be durable")
        }
        await parent.close()
    }

    func testChildrenFollowTheParentsFutureCaptureModeWithoutIndependentPolicy() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DelegationClient(count: 1), registry = DelegationRegistry(), traces = TraceStore()
        _ = try await traces.command("debug.mode", session: "parent", params: ["mode":"off"])
        let coordinator = SubagentCoordinator(register: { child, _, _, _ in await registry.add(child) })
        let parent = try await makeParent(root, client: client, coordinator: coordinator, traces: traces)
        _ = try await parent.submit(Submission(commandID: "command", turnID: "turn", text: "task"), steer: false)
        try await eventually { await client.active == 1 }
        let children = await registry.children, child = try XCTUnwrap(children.first)
        let initial = await traces.mode(child.id)
        XCTAssertEqual(initial, "off")
        _ = try await traces.command("debug.mode", session: "parent", params: ["mode":"persist"])
        let inherited = await traces.mode(child.id)
        XCTAssertEqual(inherited, "persist")
        do { _ = try await traces.command("debug.mode", session: child.id, params: ["mode":"memory"]); XCTFail("A managed child changed capture policy independently") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "managed_subagent") }
        await client.releaseAll(); try await eventually { !(await parent.isRunning) }
        for child in children { await child.close() }; await parent.close()
    }

    func testEnabledOrdinaryChatKeepsLegacyAccountingAndWriteFailureBehavior() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        for failWrite in [false, true] {
            let id = failWrite ? "failing" : "ordinary"
            let parent = try AgentSession(id: id, profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root,
                readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(),
                beforeJournalAppend: { record in
                    if failWrite && record["customType"].text == JournalRecordKind.cost { throw AgentError("fixture_io", "No space") }
                })
            await parent.enableSubagents(SubagentCoordinator())
            let lifecycle = try await parent.requestLifecycle(turnID: "turn", purpose: "turn")
            XCTAssertNil(lifecycle, "Offering delegation must not activate family accounting")
            await parent.countAttempt(billingObservation(profile: try fixtureProfile(), session: id, attempt: "physical", cost: 0.25))
            let spend = await parent.spend, failure = await parent.accountingFailure
            XCTAssertEqual(spend.usd, 0.25); XCTAssertNil(failure)
            try await parent.enforceCostLimit()
            let savedPath = await parent.path, path = try XCTUnwrap(savedPath)
            await parent.close()
            let records = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map { try JSON.parse(Data($0.utf8)) }
            XCTAssertFalse(records.contains { $0["customType"].text == JournalRecordKind.budgetAttempt })
            if !failWrite {
                let cost = try XCTUnwrap(records.first { $0["customType"].text == JournalRecordKind.cost })
                XCTAssertEqual(cost["data"], ["attemptId":"physical","purpose":"turn","outcome":"completed","usd":0.25,"reported":1])
            }
        }
    }

    func testOrdinaryRequestWithToolOfferedWritesNoBudgetAttemptRecords() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DelegationClient(count: 0), parent = try await makeParent(root, client: client, coordinator: SubagentCoordinator())
        _ = try await parent.submit(Submission(commandID: "ordinary", turnID: "ordinary", text: "no delegation"), steer: false)
        try await eventually { !(await parent.isRunning) }
        let path = await parent.path, spend = await parent.spend
        XCTAssertEqual(spend.usd, 0.01)
        await parent.close()
        let records = try String(contentsOfFile: XCTUnwrap(path), encoding: .utf8).split(separator: "\n").map { try JSON.parse(Data($0.utf8)) }
        XCTAssertFalse(records.contains { $0["customType"].text == JournalRecordKind.budgetAttempt })
        XCTAssertFalse(records.contains { $0["customType"].text == JournalRecordKind.subagentCall })
        XCTAssertEqual(records.filter { $0["customType"].text == JournalRecordKind.cost }.count, 1)
    }

    func testDirectStopOfQueuedChildPreventsLaterSubmissionAndPinsItsJournal() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DelegationClient(count: 18), registry = DelegationRegistry()
        let coordinator = SubagentCoordinator(register: { child, _, _, _ in await registry.add(child) })
        let parent = try await makeParent(root, client: client, coordinator: coordinator)
        _ = try await parent.submit(Submission(commandID: "command", turnID: "turn", text: "tasks"), steer: false)
        try await eventually { await client.active == 16 }
        let children = await registry.children, queued = try XCTUnwrap(children.last)
        let unloaded = await queued.unloadIfIdle()
        XCTAssertFalse(unloaded, "A coordinator-owned queued child must keep its journal")
        if unloaded { await parent.stop() } else {
            await queued.stop()
            try await eventually { await queued.subagents.terminal != nil }
            let status = await queued.subagents.status
            XCTAssertEqual(status, .notExecuted, "Queued Stop settles immediately, without waiting for a free slot")
            await client.releaseAll()
        }
        try await eventually { !(await parent.isRunning) }
        let started = await client.started["parent"] ?? []
        XCTAssertFalse(started.contains(17), "Stop must survive the queued-to-running transition")
        for child in children { await child.close() }; await parent.close()
    }

    func testReopenedParentRuntimeCanDelegateAfterTheOldRuntimeWasStopped() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = SubagentCoordinator(), firstClient = DelegationClient(count: 1)
        let parent = try await makeParent(root, client: firstClient, coordinator: coordinator)
        _ = try await parent.submit(Submission(commandID: "first", turnID: "first", text: "tasks"), steer: false)
        try await eventually { await firstClient.active == 1 }
        let path = await parent.path, oldRuntimeID = await parent.displayEpoch
        await parent.stop(); await parent.close()
        let client = DelegationClient(count: 1)
        let reopened = try AgentSession(id: "parent", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root,
            readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), resumePath: path)
        await reopened.enableSubagents(coordinator)
        _ = try await reopened.submit(Submission(commandID: "second", turnID: "second", text: "new task"), steer: false)
        try await eventually { let active = await client.active, running = await reopened.isRunning; return active == 1 || !running }
        await coordinator.cancel(owner: "parent", runtimeID: oldRuntimeID, through: Int.max)
        let active = await client.active, paused = await reopened.queuePaused
        XCTAssertEqual(active, 1); XCTAssertFalse(paused)
        await client.releaseAll()
        try await eventually { !(await reopened.isRunning) }
        let count = await client.started["parent"]?.count ?? 0
        XCTAssertEqual(count, 1, "Old runtime cancellation cannot cancel a new accepted turn")
        let result = await reopened.history.last { $0.toolName == "subagent" }
        XCTAssertEqual(result?.nativeSubagent?["status"].text, "completed", "Late callbacks from the old runtime cannot interrupt its replacement")
        await reopened.close()
    }

    func testDurableSideAdoptsItsOwnBudgetOnFirstDelegation() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DelegationClient(count: 1); await client.releaseAll()
        let side = try AgentSession(id: "side", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root,
            readOnly: true, resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: TraceStore(), seed: [], parent: ["parentSessionId":"original"])
        await side.enableSubagents(SubagentCoordinator())
        _ = try await side.preserveSide()
        _ = try await side.submit(Submission(commandID: "side", turnID: "side", text: "task"), steer: false)
        try await eventually { !(await side.isRunning) }
        let total = await side.spend, started = await client.started["side"]?.count ?? 0
        XCTAssertEqual(started, 1); XCTAssertEqual(total.usd, 0.03, accuracy: 1e-8)
        await side.close()
    }

    private func makeParent(_ root: URL, id: String = "parent", client: any ModelClient, coordinator: SubagentCoordinator, traces: TraceStore = TraceStore()) async throws -> AgentSession {
        let parent = try AgentSession(id: id, profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root, readOnly: true,
                                      resources: Resources(cwd: root, home: root), client: client, tools: RecordingTools(), traces: traces)
        await parent.enableSubagents(coordinator)
        return parent
    }
    func testExplicitFixtureCoordinatorOffersToolWhileProductionStaysHidden() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = try AgentSession(id: "parent", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root,
                                      readOnly: true, resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore())
        XCTAssertFalse(SubagentPolicy.enabled)
        let before = await parent.sessionDefinitions()
        XCTAssertFalse(before.contains { $0.name == "subagent" })
        await parent.enableSubagents(SubagentCoordinator())
        let after = await parent.sessionDefinitions()
        XCTAssertTrue(after.contains { $0.name == "subagent" })
        await parent.close()
    }
}

private actor DelegationRegistry {
    var children: [AgentSession] = []
    func add(_ child: AgentSession) { children.append(child) }
}

private actor DelegationClient: ModelClient {
    let count: Int, text: String?
    let arguments: [JSON]?
    var parents: [String: Int] = [:], started: [String: [Int]] = [:], lastParentBody: [String: String] = [:]
    var active = 0, maximumActive = 0, allReleased = false
    var released = Set<String>()
    init(count: Int, text: String? = nil, arguments: [JSON]? = nil) { self.count = count; self.text = text; self.arguments = arguments }
    func release(_ index: Int, owner: String) { released.insert(owner + ":\(index)") }
    func releaseAll() { allReleased = true }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        throw AgentError("fixture_unscoped", "Delegation bypassed accounting")
    }
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, cacheSessionID: String, turnID: String, purpose: String, lifecycle: RequestLifecycle?, onObservation: @escaping @Sendable (RequestObservation) async -> Void, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply {
        let hooks = lifecycle, attempt = UUID().uuidString
        let permit = try await hooks?.admitAttempt(attempt); defer { permit?.finish() }
        try await hooks?.willDispatch(attempt)
        var observation = RequestObservation(sessionID: sessionID, turnID: turnID, attemptID: attempt, purpose: purpose, fingerprint: "fixture", profile: profile)
        var reply: ModelReply
        do {
            if let link = hooks?.scope.delegation {
                XCTAssertEqual(sessionID, cacheSessionID); XCTAssertEqual(messages.filter { $0.role == "user" }.count, 1)
                XCTAssertFalse(tools.contains { $0.name == "subagent" })
                let index = Int(messages.first { $0.role == "user" }?.text ?? "") ?? -1
                started[link.budgetOwnerSessionID, default: []].append(index); active += 1; maximumActive = max(maximumActive, active)
                defer { active -= 1 }
                while !allReleased && !released.contains(link.budgetOwnerSessionID + ":\(index)") { try await Task.sleep(for: .milliseconds(5)) }
                try permit?.check(); reply = answer(text ?? "child \(index)")
            } else {
                parents[sessionID, default: 0] += 1
                if parents[sessionID] == 1 {
                    let calls = (0..<count).map { ToolCall(id: "call-\($0)", name: "subagent", arguments: arguments?[$0] ?? ["task":JSON(String($0))]) }
                    reply = ModelReply(message: ChatMessage(role: "assistant", content: calls.map { ["type":"toolCall", "id":JSON($0.id), "name":JSON($0.name), "arguments":$0.arguments] }), calls: calls)
                } else {
                    lastParentBody[sessionID] = try ProviderClient.requestBody(profile: profile, messages: messages, instructions: instructions, tools: tools, sessionID: sessionID).encoded()
                    reply = answer("Parent complete")
                }
            }
        } catch {
            observation.monitoring = ["outcome":"cancelled", "gateway":["cost":["status":"unreported"]]]
            if let hooks { try await hooks.settleAttempt(AttemptSettlement(scope: hooks.scope, observation: observation, dispatched: true)) }
        await onObservation(observation)
            throw error
        }
        observation.monitoring = ["outcome":"completed", "gateway":["cost":["status":"reported","usd":0.01]]]
        observation.fields = ["input":10,"output":2,"total":12]
        if let hooks { try await hooks.settleAttempt(AttemptSettlement(scope: hooks.scope, observation: observation, dispatched: true)) }
        await onObservation(observation)
        reply.message.requestAttemptIDs = [attempt]
        return reply
    }
}
