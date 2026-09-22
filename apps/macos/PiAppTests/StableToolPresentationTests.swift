import XCTest
import SwiftUI
import Combine
@testable import PiApp

final class StableToolPresentationTests: XCTestCase {
    @MainActor func testPackagedHelperGatewayAndTwoMountedPanesPreserveCapturesAndTaskTopology() async throws {
        let root = URL(fileURLWithPath:scratchBase()).appendingPathComponent("stable-tool-gateway-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var repo = URL(fileURLWithPath:#filePath); for _ in 0..<4 { repo.deleteLastPathComponent() }
        let server = Process(); server.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        server.arguments = [repo.appendingPathComponent("fixtures/native/tool_phases.py").path,root.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate() } }
        let ready = root.appendingPathComponent("ready.json")
        for _ in 0..<500 where !FileManager.default.fileExists(atPath:ready.path) { try await Task.sleep(for:.milliseconds(10)) }
        let port = try XCTUnwrap(try JSONDecoder().decode([String:Int].self,from:Data(contentsOf:ready))["port"])
        let workspace = WorkspaceRecord(id:"phases",path:root.path,trusted:true)
        var profile = ProfileRecord(); profile.baseUrl = "http://127.0.0.1:\(port)/v1"; profile.modelId = "phase-fixture"
        profile.advancedJSON = #"{"routing":{"replayPolicy":"portable"}}"#
        let vault = ConfigurationVault(storage:MemoryVaultStorage()), savedProfile = profile
        _ = try await vault.update(expectedRevision:0) {
            $0.workspaces = [workspace]; $0.profiles = [.init(profile:savedProfile,apiKey:"synthetic-phase-key")]
            $0.resources[workspace.id] = .object(["codexHome":.string(root.appendingPathComponent("empty").path),"skills":.bool(false)])
        }
        let model = WorkspaceModel(stateRoot:root.appendingPathComponent("state"),vault:vault)
        registerWorkspaceFixtureTeardown(model,root:root); try await model.reloadConfiguration()
        let chat = ChatRecord(id:"phase-fixture",workspaceID:workspace.id,title:"Phases",profileID:profile.id)
        let view = SessionDisplay(id:chat.id); model.chats = [chat]; model.displays[chat.id] = view
        model.selectedID = chat.id; model.selected = view; model.focusedSessionID = chat.id
        _ = try await model.open(chat)
        let main = TranscriptStreamingStressTests.Stage(view), narrow = TranscriptStreamingStressTests.Stage(view,width:320)
        defer { main.window.close(); narrow.window.close() }
        var falseFooters = 0, sawTools = false, sawPreparing = false, publications = 0
        let subscription = view.presentationChanges.sink { input in
            publications += 1
            let items = TaskTranscriptPlan.items(input.messages,lifecycle:input.lifecycle)
            if let active = input.lifecycle?.active {
                let live = TurnInfoPresentation.live(TaskTranscriptPlan.summary(input.messages,task:active),at:Date())
                XCTAssertNotNil(active.startedAtUnixMs,"The packaged helper supplies calendar stamps separately from uptime")
                XCTAssertLessThan(live.elapsedMs ?? .infinity,60000,"A real gateway turn must not display an epoch-sized duration")
                sawTools = sawTools || active.phase == "tools"
                sawPreparing = sawPreparing || active.preparingCalls > 0
                falseFooters += items.filter { if case .block(let b) = $0 { return b.presentation == .summary && b.task?.key == active.key }; return false }.count
            }
        }
        view.draft = "Run the deterministic tool presentation task"; model.send(sessionID:chat.id)
        for _ in 0..<1500 {
            if !view.loading && !view.busy && view.taskPresentation?.recent.isEmpty == false { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        subscription.cancel(); main.refresh(); narrow.refresh()
        XCTAssertNil(view.failureMessage); XCTAssertNil(view.sendFailure)
        XCTAssertTrue(sawTools); XCTAssertTrue(sawPreparing); XCTAssertEqual(falseFooters,0)
        for stage in [main,narrow] {
            XCTAssertTrue(work(stage.page.snapshot?.items ?? []).isEmpty, "Ordered responses never become a task-wide work group")
            XCTAssertEqual(cards(stage.page.snapshot?.items ?? []).count, 2, "Each call is one card at its own position")
            XCTAssertTrue(cards(stage.page.snapshot?.items ?? []).allSatisfy { $0.message?.tools?.count == 1 },
                          "A card carries only the call made there")
            XCTAssertEqual(terminal(stage.page.snapshot?.items ?? []).count,1)
            XCTAssertNil(stage.page.liveTurn)
            XCTAssertEqual(stage.page.snapshot?.items.filter { if case .block(let b) = $0 { return b.presentation == .timeline && b.part?.part.kind == "text" }; return false }.count,2)
        }
        XCTAssertEqual(view.taskPresentation?.recent.last?.issuedCalls,2)
        let completed = try XCTUnwrap(view.taskPresentation?.recent.last)
        XCTAssertNotNil(completed.endedAtUnixMs)
        XCTAssertLessThan(try XCTUnwrap(completed.elapsedMilliseconds()),60000)
        var attempts: [[String:WireValue]] = []
        for _ in 0..<500 {
            attempts = try await model.traces.list(sessionID:chat.id)
            if attempts.count == 3 { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTAssertEqual(attempts.count,3)
        let records = try String(contentsOf:root.appendingPathComponent("records.jsonl")).split(separator:"\n").map { try JSONDecoder().decode([String:WireValue].self,from:Data($0.utf8)) }
        XCTAssertEqual(records.count,3)
        for attempt in attempts {
            let id = try XCTUnwrap(attempt["attemptId"]?.string)
            let request = try await model.traces.completeBody(attemptID:id,body:"request")
            let response = try await model.traces.completeBody(attemptID:id,body:"response")
            XCTAssertTrue(records.contains { Data(base64Encoded:$0["request"]?.string ?? "") == request && Data(base64Encoded:$0["response"]?.string ?? "") == response })
        }
        let path = try XCTUnwrap(model.record(chat.id)?.path)
        let retained = try await HistoryReader().read(path:path,targetTurns:3)
        XCTAssertEqual(retained.taskRecords.count,1)
        let restored = TaskTranscriptPlan.items(retained.messages,lifecycle:projection(nil,recent:retained.taskRecords))
        XCTAssertTrue(work(restored).isEmpty); XCTAssertEqual(terminal(restored).count,1)
        let liveParts = main.page.snapshot!.items.compactMap { if case .block(let b) = $0 { return b.part }; return nil }
        let savedParts = restored.compactMap { if case .block(let b) = $0 { return b.part }; return nil }
        XCTAssertEqual(savedParts, liveParts, "Observed IDs, order and scope survive native history loading")
        print("TOOL_GATEWAY_NATIVE panes=2 requests=\(attempts.count) issuedCalls=\(view.taskPresentation?.recent.last?.issuedCalls ?? -1) falseTerminal=\(falseFooters) publications=\(publications) checkedBodies=\(attempts.count * 2)")
    }
    private func task(_ root: String = "u", execution: String = "e", phase: String = "model", outcome: String? = nil, last: String? = nil) -> TaskPresentationRecord {
        var value = TaskPresentationRecord(rootID:root, executionID:execution, startedAt:1000)
        value.phase = phase; value.outcome = outcome; value.endedAt = outcome == nil ? nil : 4000
        value.lastSourceID = last; return value
    }
    private func row(_ id: String, _ text: String, role: String = "assistant", state: String = "streaming", root: String = "u", execution: String = "e") -> TranscriptMessage {
        TranscriptMessage(id:id, role:role, text:text, state:state, turn:root, taskRootID:root, taskExecutionID:execution)
    }
    private func projection(_ active: TaskPresentationRecord?, recent: [TaskPresentationRecord] = [], epoch: String = "epoch") -> TaskPresentationProjection {
        .init(sessionID:"phase-fixture", epoch:epoch, timeline:"root", sequence:1, sourceRevision:"epoch:1", active:active, recent:recent)
    }
    /// The work groups of a page: a task-wide or legacy group, never a single
    /// call's card. Since 0.1.79 a card is a work row placed at the position
    /// its call was made, so it carries that part and is not a group.
    private func work(_ items: [TranscriptItem]) -> [TranscriptBlock] { items.compactMap { if case .block(let b) = $0, b.presentation == .work, b.part == nil { return b }; return nil } }
    /// The cards of a page, each at its own call's position.
    private func cards(_ items: [TranscriptItem]) -> [TranscriptBlock] { items.compactMap { if case .block(let b) = $0, b.part?.part.kind == "toolArguments" { return b }; return nil } }
    private func terminal(_ items: [TranscriptItem]) -> [TranscriptBlock] { items.compactMap { if case .block(let b) = $0, b.presentation == .summary { return b }; return nil } }

    @MainActor func testMountedPhaseSequence() async throws {
        let session = SessionDisplay(id:"phase-fixture")
        session.taskPresentation = projection(task())
        session.messages = [row("u", "Fixture task", role:"user", state:"complete"), row("a", "Visible prose")]
        session.messages[1].tools = [ToolView(id:"call",name:"read",state:"preparing",input:"",output:"",truncated:false)]
        let stage = TranscriptStreamingStressTests.Stage(session)
        defer { stage.window.close() }
        stage.page.presentationInterval = 0; stage.page.state = "running"; stage.refresh()
        let body = try XCTUnwrap(stage.row("block:a")), header = try XCTUnwrap(stage.row("legacy:a"))
        let height = header.measure(width:640).height, proseHeight = body.measure(width:640).height
        let measurements = body.measurementCount
        for index in 0..<1000 {
            session.messages[1].tools = [ToolView(id:"call", name:"read", state:"preparing", input:String(repeating:"x",count:index), output:"", truncated:false)]
        }
        stage.refresh()
        XCTAssertTrue(stage.row("block:a") === body)
        XCTAssertEqual(body.measure(width:640).height,proseHeight)
        XCTAssertEqual(body.measurementCount, measurements,"Hidden arguments never remeasure prose")
        XCTAssertEqual(header.measure(width:640).height,height)
        session.beginTranscriptBatch()
        session.messages[1].state = "complete"; session.messages[1].tools?[0].state = "running"
        session.taskPresentation = projection(task(phase:"tools"))
        session.endTranscriptBatch(); stage.refresh()
        XCTAssertEqual(terminal(stage.page.snapshot!.items).count,0)
        XCTAssertEqual(stage.page.liveTurn?.phase,"tools")
        session.messages.append(row("next","")); stage.refresh()
        XCTAssertNil(stage.row("block:next"))
        session.messages[2].thinking = "Reasoning"; stage.refresh()
        XCTAssertNil(stage.row("block:next"))
        session.messages[2].tools = [ToolView(id:"call",name:"read",state:"completed",input:"{}",output:"ok",truncated:false)]
        session.messages[2].state = "complete"; stage.refresh()
        XCTAssertEqual(work(stage.page.snapshot!.items).map(\.key),["legacy:a", "legacy:next"])
        session.messages.append(row("final","Final prose",state:"complete"))
        let end = task(phase:"terminal", outcome:"completed",last:"final")
        session.taskPresentation = projection(nil,recent:[end]); stage.refresh()
        XCTAssertEqual(terminal(stage.page.snapshot!.items).count,1); XCTAssertNil(stage.page.liveTurn)
        XCTAssertTrue(stage.row("block:a") === body)
        print("TOOL_PRESENTATION_NATIVE falseTerminal=0 hiddenArgumentProseRemeasures=0 closedHeaderHeightDelta=0")
    }

    func testFifteenRoundsSteeringFollowUpAndHistoricalWindowHaveIndependentScope() {
        var rows = [row("u","Task",role:"user",state:"complete")]
        for index in 0..<15 {
            var reply = row("a\(index)",index % 2 == 0 ? "Prose \(index)" : "",state:"complete")
            reply.tools = [ToolView(id:"reused",name:"read",state:"completed",input:"{}",output:"ok",truncated:false)]
            reply.toolCallCount = 1; rows.append(reply)
        }
        var steering = row("steer","Steering",role:"user",state:"complete"); steering.turn = "steer"; rows.insert(steering,at:8)
        var active = task(phase:"tools"); active.issuedCalls = 15
        let items = TaskTranscriptPlan.items(rows,lifecycle:projection(active))
        XCTAssertEqual(work(items).map(\.key),(0..<15).map { "legacy:a\($0)" })
        XCTAssertEqual(TaskTranscriptPlan.summary(rows,task:active).tools,15); XCTAssertTrue(terminal(items).isEmpty)
        var ended = active; ended.outcome = "completed"; ended.endedAt = 5000; ended.lastSourceID = "a14"
        let next = task("next",execution:"e2")
        rows.append(row("next","Follow up",role:"user",state:"complete",root:"next",execution:"e2"))
        let chained = TaskTranscriptPlan.items(rows,lifecycle:projection(next,recent:[ended]))
        XCTAssertEqual(work(chained).count,16); XCTAssertEqual(terminal(chained).count,1)
        let historyOnly = TaskTranscriptPlan.items(Array(rows.prefix(4)),lifecycle:projection(next,recent:[ended]))
        XCTAssertTrue(terminal(historyOnly).isEmpty,"A suffix outside the loaded window cannot move its footer here")
        XCTAssertEqual(TaskTranscriptPlan.live(projection(next,recent:[ended]))?.taskKey,"4:nexte2")
        XCTAssertEqual(work(TaskTranscriptPlan.items(rows,lifecycle:nil)).first?.task?.outcome,nil,"Legacy history is unresolved")
    }

    @MainActor func testCoherentAdoptionCosmeticCoalescingTrailingFlushAndEpochBinding() async throws {
        let session = SessionDisplay(id:"phase-fixture"), page = TranscriptPage()
        session.taskPresentation = projection(task()); session.messages = [row("u","Task",role:"user"),row("a","Text")]
        page.bind(session); page.presentationInterval = 0.1
        var delivered = 0
        let observer = session.presentationChanges.sink { _ in delivered += 1 }
        session.beginTranscriptBatch()
        session.retryNotice = "Retrying"
        session.taskPresentation = projection(task(phase:"retrying"))
        XCTAssertEqual(delivered,1)
        session.messages[1].thinking = "Reasoning"; session.retryNotice = nil
        session.endTranscriptBatch(); XCTAssertEqual(delivered,2)
        XCTAssertEqual(page.snapshot?.lifecycle?.active?.phase,"retrying")
        session.messages[1].tools = [ToolView(id:"call",name:"read",state:"preparing",input:"{",output:"",truncated:false)]
        let leading = page.snapshot!.sequence
        for index in 0..<1000 { session.messages[1].tools?[0].input = "{\(index)" }
        XCTAssertEqual(page.pendingPresentationCount,1)
        XCTAssertLessThanOrEqual(page.snapshot!.sequence, leading+1)
        try await Task.sleep(for:.milliseconds(150))
        XCTAssertEqual(page.snapshot?.messages[1].tools?[0].input,"{999")
        session.taskPresentation = projection(nil,recent:[task(phase:"terminal",outcome:"failed",last:"a")])
        XCTAssertNil(page.liveTurn); XCTAssertEqual(terminal(page.snapshot!.items).count,1)
        let other = SessionDisplay(id:"other"); page.bind(other)
        session.messages[1].text = "late"; try await Task.sleep(for:.milliseconds(150))
        XCTAssertEqual(page.snapshot?.sessionID,"other"); XCTAssertNil(page.liveTurn)
        observer.cancel()
    }

    @MainActor func testDockHeightAndOpenDisclosureDoNotFollowMetadataLength() {
        var turn = TaskTranscriptPlan.summary([],task:task())
        let host = NSHostingView(rootView:LiveTurnBar(turn:turn).frame(width:280))
        host.safeAreaRegions = []; let before = host.fittingSize.height
        turn.notice = String(repeating:"Long message ",count:100); turn.tools = 150; turn.accounting.costUSD = 0.000001
        turn.phase = "tools"; turn.current = ToolView(id:"x",name:String(repeating:"long name",count:40),state:"running",input:"",output:"",truncated:false)
        host.rootView = LiveTurnBar(turn:turn).frame(width:280)
        XCTAssertEqual(host.fittingSize.height,before)
        let store = TranscriptDisclosure(); store.setOpen(true,.tool(ToolOccurrence.key("a","call")))
        var first = row("a", "Text"), second = row("b", "")
        let call = ToolView(id:"call",name:"read",state:"completed",input:"{}",output:"ok",truncated:false)
        first.tools = [call]; second.tools = [call]
        let item = TaskTranscriptPlan.items([first,second],lifecycle:projection(task())).first!
        let disclosure = TranscriptRowDisclosure.of(item,in:store)
        XCTAssertEqual(disclosure.openTools,[ToolOccurrence.key("a","call")])
        XCTAssertFalse(disclosure.openTools.contains(ToolOccurrence.key("b","call")))
    }

    @MainActor func testRetryWithoutContentAndSkippedPhasesKeepOneTerminalPerExecution() {
        let rows = [row("u","Task",role:"user",state:"complete")]
        let failed = task(phase:"terminal",outcome:"failed",last:"u")
        var retry = task(execution:"retry",phase:"retrying"); retry.anchorSourceID = "u"
        let live = TaskTranscriptPlan.items(rows,lifecycle:projection(retry,recent:[failed]))
        XCTAssertEqual(work(live).map(\.key),["work:1:uretry"])
        XCTAssertEqual(terminal(live).count,1)
        retry.outcome = "failed"; retry.endedAt = 5000; retry.lastSourceID = "u"
        let done = TaskTranscriptPlan.items(rows,lifecycle:projection(nil,recent:[failed,retry]))
        XCTAssertTrue(work(done).isEmpty, "Terminal receipts do not invent missing response parts")
        XCTAssertEqual(terminal(done).count,2)
        XCTAssertEqual(TaskTranscriptPlan.items(rows,lifecycle:projection(nil,recent:[failed,retry,retry])),done,"Duplicate receipts never duplicate chrome")
        var summary = TaskTranscriptPlan.summary(rows,task:retry); summary.accounting.costUSD = 0.000001
        XCTAssertTrue(TurnLineView.copyText(summary).contains("failed"))
        let restored = TranscriptMessage.project(id:"interrupted",message:["role":.string("assistant"),"content":.string("Retained partial"),"nativeStopReason":.string("interrupted")])
        XCTAssertEqual(restored.stopReason,"interrupted","The file reader preserves the same partial-attempt warning as live snapshots")
    }

    @MainActor func testToolDocumentFetchesAreScopedAndRejectRetiredOwners() async throws {
        let inputs = TranscriptToolInputs()
        var pending: [CheckedContinuation<ToolInputDocument,Never>] = []
        inputs.load = { _,_ in await withCheckedContinuation { pending.append($0) } }
        let a = ToolOccurrence.key("a","call"), b = ToolOccurrence.key("b","call")
        inputs.request(messageID:"a",callID:"call"); inputs.request(messageID:"b",callID:"call")
        for _ in 0..<100 where pending.count < 2 { await Task.yield() }
        XCTAssertEqual(pending.count,2)
        inputs.forget([a]); inputs.request(messageID:"a",callID:"call")
        for _ in 0..<100 where pending.count < 3 { await Task.yield() }
        let retired = ToolInputDocument(input:"retired",truncated:false,bytes:7,streaming:false)
        let current = ToolInputDocument(input:"current",truncated:false,bytes:7,streaming:false)
        pending[0].resume(returning:retired); pending[1].resume(returning:current)
        for _ in 0..<100 where inputs.document(b) == nil { await Task.yield() }
        XCTAssertNil(inputs.document(a)); XCTAssertTrue(inputs.isLoading(a))
        XCTAssertEqual(inputs.document(b),current); XCTAssertNil(inputs.document("call"),"A reused raw ID is ambiguous")
        pending[2].resume(returning:current)
        for _ in 0..<100 where inputs.document(a) == nil { await Task.yield() }
        XCTAssertEqual(inputs.document(a),current); XCTAssertEqual(inputs.count,2)
    }

    @MainActor func testNativeSelectionAndDrawGeometrySurviveToolFragmentsAndLateAccounting() async throws {
        func fields(_ view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField { return [field] }
            var result: [NSTextField] = []
            for child in view.subviews { result += fields(child) }
            return result
        }
        let session = SessionDisplay(id:"phase-fixture")
        session.taskPresentation = projection(task())
        session.messages = [row("u","Task",role:"user",state:"complete"),row("a","Stable selectable prose.")]
        session.messages[1].tools = [ToolView(id:"call",name:"read",state:"preparing",input:"{",output:"",truncated:false)]
        let stage = TranscriptStreamingStressTests.Stage(session)
        defer { stage.close() }
        stage.page.presentationInterval = 0; await stage.settle()
        let body = try XCTUnwrap(stage.row("block:a"))
        let field = try XCTUnwrap(fields(body).first { $0.isSelectable && $0.stringValue == "Stable selectable prose." })
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor()); editor.selectedRange = NSRange(location:0,length:6)
        let origin = body.frame.origin, measures = body.measurementCount, header = try XCTUnwrap(stage.workRow)
        let headerHeight = header.frame.height
        var samples: [Double] = []
        for frame in 0..<30 {
            let start = ProcessInfo.processInfo.systemUptime
            session.messages[1].tools?[0].input = String(repeating:"x",count:frame * 30 + 1)
            var cost = GatewayTotals(); cost.costUSD = frame == 0 ? 0 : 0.000001
            session.messages[1].accounting = cost
            stage.refresh() // Includes native row layout and NSWindow.displayIfNeeded.
            samples.append((ProcessInfo.processInfo.systemUptime-start)*1000)
            XCTAssertTrue(stage.row("block:a") === body)
            XCTAssertEqual(body.frame.origin,origin); XCTAssertEqual(body.measurementCount,measures)
            XCTAssertEqual(header.frame.height,headerHeight)
            XCTAssertTrue(field.currentEditor() === editor); XCTAssertEqual(editor.selectedRange,NSRange(location:0,length:6))
            try await Task.sleep(for:.milliseconds(16))
        }
        XCTAssertEqual((editor.string as NSString).substring(with:editor.selectedRange),"Stable")
        let sorted = samples.sorted()
        print("TOOL_NATIVE_DRAW samples=\(samples.count) medianMs=\(sorted[15]) p95Ms=\(sorted[28]) maxMs=\(sorted.last ?? 0) proseOriginChanges=0 proseRemeasures=0 selectionPreserved=1")
    }

    @MainActor func testIndependentMountedPanesAndCompletionAnnouncementsFollowTaskScope() async throws {
        let main = SessionDisplay(id:"phase-fixture"), side = SessionDisplay(id:"side")
        main.taskPresentation = projection(task())
        var sideProjection = projection(task("side-input",execution:"side-execution",phase:"tools"))
        sideProjection.sessionID = side.id; side.taskPresentation = sideProjection
        main.messages = [row("u","Task",role:"user",state:"complete"),row("a","Main prose")]
        side.messages = [row("side-input","Child task",role:"user",state:"complete",root:"side-input",execution:"side-execution"),row("a","Side prose",root:"side-input",execution:"side-execution")]
        let first = TranscriptStreamingStressTests.Stage(main), second = TranscriptStreamingStressTests.Stage(side,width:320)
        defer { first.close(); second.close() }
        var announcements = 0; first.page.announceCompletion = { announcements += 1 }
        main.messages[1].state = "complete"; first.refresh(); second.refresh()
        XCTAssertEqual(announcements,0,"A completed assistant with pending continuation is not a completed task")
        var end = task(phase:"terminal",outcome:"completed",last:"a")
        end.endedAtUnixMs = Date().timeIntervalSince1970 * 1000
        main.taskPresentation = projection(nil,recent:[end]); first.refresh()
        XCTAssertNil(first.page.liveTurn); XCTAssertEqual(second.page.liveTurn?.phase,"tools")
        XCTAssertEqual(second.page.liveTurn?.taskKey,sideProjection.active?.key)
        XCTAssertEqual(announcements,1)
        main.taskPresentation?.sequence += 1; first.refresh()
        main.messages[1].accounting = GatewayTotals(); first.refresh()
        XCTAssertEqual(announcements,1,"Late metrics and duplicate terminal state do not repeat announcements")
        XCTAssertTrue(terminal(second.page.snapshot!.items).isEmpty)
        var old = end; old.executionID = "old"; old.endedAt = 4000; old.endedAtUnixMs = nil
        main.taskPresentation?.recent.insert(old,at:0)
        XCTAssertEqual(announcements,1,"Loading historical terminal evidence is silent")
        second.show(SessionDisplay(id:"idle"))
        side.taskPresentation?.active?.phase = "retrying"
        try await Task.sleep(for:.milliseconds(60))
        XCTAssertNil(second.page.liveTurn); XCTAssertEqual(second.page.snapshot?.sessionID,"idle")
    }
}
