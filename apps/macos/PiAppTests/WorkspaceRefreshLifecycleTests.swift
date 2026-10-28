import XCTest
@testable import PiApp

@MainActor private final class RefreshCommandLog {
    var frames: [[String: WireValue]] = []
}

@MainActor private final class WeakRefreshDisplay {
    weak var value: SessionDisplay?
    init(_ value: SessionDisplay) { self.value = value }
}

@MainActor private struct RefreshFixture {
    let root: URL
    let model: WorkspaceModel
    let chat: ChatRecord
    let view: SessionDisplay
    let host: HostSupervisor
    let commands: RefreshCommandLog
}

final class WorkspaceRefreshLifecycleTests: XCTestCase {
    @MainActor func testAnOpeningFillReachingTheLiveTailRefreshesAReplyFinishedDuringItsRead() async throws {
        let f = try await fixture(), gate = HistoryReadGate()
        defer { Task { await gate.release() } }
        var rows = try XCTUnwrap(wireRows(0..<400).array)
        rows[399] = .object(["id": .string("m399"), "role": .string("assistant"), "text": .string("Partial"), "state": .string("streaming")])
        let cursor: WireValue = .object(["incarnation": .string("runtime"), "lineage": .string("root"), "entry": .string("m1")])
        var opening = try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("runtime"), "lineage": .string("root"),
            "messages": .array(Array(rows.prefix(2))), "older": .null, "newer": cursor, "start": .number(0), "total": .number(400)]))
        opening.opening = true; opening.openingAround = "m0"
        f.model.adoptPage(opening, into: f.view, presenting: false)
        f.view.historyState = .ready; f.view.state = "running"; f.view.runStatus = "running"
        f.view.projectedRows = try TranscriptMessage.page(.array(Array(rows.suffix(4))))
        f.view.projectionRevision = "runtime:1"
        let stale = try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("runtime"), "lineage": .string("root"),
            "messages": .array(Array(rows.dropFirst(2))), "older": .object(["incarnation": .string("runtime"), "lineage": .string("root"), "entry": .string("m2")]),
            "newer": .null, "start": .number(2), "total": .number(400)]))
        f.model.historyWindowLoader = { _, _, newer, _ in
            guard newer else { throw HostError.failure("The saved opening must fill forward") }
            await gate.read()
            return stale
        }
        f.model.startOpeningFill(f.chat.id)
        let fill = try XCTUnwrap(f.view.presentation.openingFill)
        try await eventually("The opening fill never read its stale page", until: { await gate.reads == 1 })
        rows[399] = .object(["id": .string("m399"), "role": .string("assistant"), "text": .string("Finished reply"), "state": .string("complete")])
        var finished = liveSnapshot(2, .array(Array(rows.suffix(4)) + [
            .object(["id": .string("final-part"), "role": .string("assistant"), "text": .string("Final part")])]))
        try await exchange(f, finished)
        XCTAssertEqual(f.commands.frames[0]["params"]?.object?["includeMessages"]?.bool, false)
        XCTAssertEqual(f.view.state, "idle")
        XCTAssertEqual(f.view.messages.count, 2, "The completion's rows were omitted while browsing history")
        let answered = f.commands.frames.count
        await gate.release(); await fill.value
        XCTAssertFalse(f.view.browsingHistory); XCTAssertNil(f.view.newerPage.cursor)
        try await eventually("Closing the opening's newer gap did not request fresh live rows", timeout: .seconds(2)) {
            f.commands.frames.count > answered
        }
        let request = f.commands.frames[answered]
        XCTAssertEqual(request["params"]?.object?["includeMessages"]?.bool, true)
        XCTAssertNil(request["params"]?.object?["displayRevision"], "The retained projection missed the completion")
        XCTAssertNil(request["params"]?.object?["messageDelta"])
        finished["seq"] = .number(3); finished["displayRevision"] = .string("runtime:3")
        try reply(request, on: f.host, result: finished)
        try await wait { !f.view.snapshotInFlight }
        XCTAssertEqual(f.view.messages.first(where: { $0.id == "m399" })?.text, "Finished reply")
        XCTAssertEqual(f.view.messages.last?.id, "final-part", "The reply's final part arrives without another event or reopening")
        try await f.host.shutdownAndWait()
    }

    @MainActor func testAStreamingDeltaLetsGoOfTurnsBeforeTheReadersNewHeldTurn() async throws {
        let caps = TranscriptPaging.residentCaps
        TranscriptPaging.residentCaps = (rows: 8, bytes: caps.bytes)
        defer { TranscriptPaging.residentCaps = caps }
        for selection in [false, true] {
            let f = try await fixture()
            let initial = try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("runtime"), "lineage": .string("root"),
                "messages": wireRows(0..<8), "older": .null, "newer": .null, "start": .number(0), "total": .number(8)]))
            f.model.adoptPage(initial, into: f.view, presenting: false)
            f.view.historyState = .ready
            func hold(_ index: Int) {
                if selection { f.view.pinnedHistoryIDs = ["m\(index)"] }
                else {
                    f.view.scrollAnchor = .init(id: "m\(index)", offset: 17, followsBottom: false)
                    f.model.anchorChanged(f.view)
                }
            }
            hold(1)
            var growing = liveSnapshot(2, wireRows(6..<14))
            growing["state"] = .string("running"); growing["runStatus"] = .string("running")
            try await exchange(f, growing)
            try await wait { f.model.accountingTasks.isEmpty }
            XCTAssertEqual(f.view.messages.map(\.id), (0..<14).map { "m\($0)" })
            _ = f.view.presentedMessages
            for (sequence, held) in [(3, 3), (4, 5)] {
                hold(held)
                f.model.releaseHeldWindow(f.view)
                XCTAssertGreaterThan(f.view.messages.count, 8, "The held row is still outside the newest bounded window")
                var delta = liveSnapshot(Double(sequence), .array([]))
                delta["state"] = .string("running"); delta["runStatus"] = .string("running")
                delta["messages"] = nil
                delta["messageDelta"] = .object(["base": .string("runtime:\(sequence - 1)"), "rows": .array([]), "appends": .array([
                    .object(["id": .string("m13"), "text": .string(" token\(sequence)"), "thinking": .string("")])])])
                try await exchange(f, delta)
                try await wait { f.model.accountingTasks.isEmpty }
                XCTAssertEqual(f.view.messages.map(\.id), ((held - 1)..<14).map { "m\($0)" }, "Released turns leave while the held turn and live tail stay")
                XCTAssertEqual(f.view.olderPage.cursor?.entry, "m\(held - 1)")
                XCTAssertTrue(f.view.messages.contains { $0.id == "m\(held)" })
                XCTAssertTrue(f.view.messages.last?.text.hasSuffix(" token\(sequence)") == true)
            }
            try await f.host.shutdownAndWait()
        }
    }

    @MainActor func testReplacementRuntimeRebindsHeldRevealAndPositionBoundaries() async throws {
        for operation in ["reveal", "home", "position"] {
            let f = try await fixture()
            f.view.historyState = .ready; f.view.draftReady = true; f.view.browsingHistory = true
            f.view.snapshotEpoch = "old"; f.view.presentation.identity = ("old", "root")
            f.view.olderPage.cursor = .init(incarnation: "old", lineage: "root", entry: "question")
            XCTAssertTrue(f.view.adoptSnapshotEpoch("new"))
            let read = Task {
                switch operation {
                case "reveal": _ = await f.model.revealInTranscript(sessionID: f.chat.id, messageID: "destination")
                case "home": _ = await f.model.revealStartOfChat(sessionID: f.chat.id)
                default:
                    f.model.jumpToHistoryPosition(f.chat.id, position: 0, offset: 19)
                    await f.view.jumpTask?.value
                }
            }
            try await wait { f.commands.frames.contains { $0["method"]?.string == "session.history" } }
            let command = try XCTUnwrap(f.commands.frames.first { $0["method"]?.string == "session.history" })
            XCTAssertEqual(command["params"]?.object?["entry"], .string("question"))
            XCTAssertEqual(command["params"]?.object?["lineage"], .string("root"))
            try reply(command, on: f.host, result: ["version": .number(2), "incarnation": .string("new"), "lineage": .string("root"),
                "messages": .array([.object(["id": .string("destination"), "role": .string("user"), "text": .string("Requested page")])]),
                "older": .null, "newer": .null, "start": .number(0), "total": .number(1)])
            await read.value
            XCTAssertEqual(f.view.messages.map(\.id), ["destination"], operation)
            XCTAssertEqual(f.view.presentation.identity?.incarnation, "new", operation)
            XCTAssertNil(f.view.newerPage.error, operation)
            try await f.host.shutdownAndWait()
        }
    }

    @MainActor func testRuntimeReplacementRejectsAnUntrackedRevealRead() async throws {
        let f = try await fixture(), gate = HistoryReadGate()
        defer { Task { await gate.release() } }
        f.view.historyState = .ready; f.view.draftReady = true; f.view.browsingHistory = true
        f.view.snapshotEpoch = "old"
        f.model.historyWindowLoader = { _, _, _, _ in
            await gate.read()
            return try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("old"), "lineage": .string("root"),
                "messages": .array([.object(["id": .string("retired"), "role": .string("user"), "text": .string("Retired page")])]), "older": .null, "newer": .null]))
        }
        let read = Task { await f.model.revealInTranscript(sessionID: f.chat.id, messageID: "retired") }
        try await eventually("The reveal is reading the retired runtime") { await gate.reads == 1 }
        XCTAssertTrue(f.view.adoptSnapshotEpoch("new"))
        await gate.release()
        let revealed = await read.value
        XCTAssertFalse(revealed, "An uncancelled caller still needs the runtime read fence")
        XCTAssertEqual(f.view.messages.map(\.id), ["question"])
        XCTAssertNil(f.view.revealRead)
        try await f.host.shutdownAndWait()
    }

    @MainActor func testRuntimeReplacementRestartsVisibleInitialAndReloadReads() async throws {
        for reload in [false, true] {
            let f = try await fixture(), gate = HistoryReadGate()
            defer { Task { await gate.release() } }
            f.view.draftReady = true; f.view.snapshotEpoch = "old"
            f.view.scrollAnchor = .init(id: "held", offset: 17, followsBottom: false)
            f.model.historyWindowLoader = { _, _, _, around in
                let read = await gate.readFirstOnly()
                let message = around ?? "held"
                return try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("new"), "lineage": .string("root"),
                    "messages": .array([.object(["id": .string(message), "role": .string("user"), "text": .string(read == 1 ? "Retired page" : "Replacement page")])]), "older": .null, "newer": .null]))
            }
            if reload { f.model.reloadHistory(f.chat.id, around: "destination") }
            else {
                let held = f.view.beginHistoryPresentation(), generation = f.view.presentationGeneration
                f.view.browsingHistory = true
                f.view.presentation.navigation = Task {
                    await f.model.loadSelectedChat(f.chat.id, item: f.chat, into: f.view, selection: f.model.selectionRevision,
                        generation: generation, heldRows: held, focusesComposer: false)
                }
            }
            try await eventually("The first read is held", until: { await gate.reads == 1 })
            let navigation = f.model.transcriptNavigation(f.chat.id)
            let oldRead = f.view.presentation.navigation
            var next = snapshot(sequence: 1, revision: "new:1")
            next["monitoring"] = .object(["epoch": .string("new")])
            let count = f.commands.frames.count
            f.model.refresh(f.chat.id)
            try await wait { f.commands.frames.count > count }
            try reply(f.commands.frames[count], on: f.host, result: next)
            for _ in 0..<100 { if await gate.reads >= 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
            let reads = await gate.reads
            XCTAssertGreaterThan(reads, 1, "A visible reader must restart when its runtime retires (reload=\(reload))")
            XCTAssertNotEqual(f.view.historyState, .loading)
            await gate.release(); await oldRead?.value
            XCTAssertEqual(f.view.messages.first?.text, "Replacement page")
            XCTAssertEqual(f.view.scrollAnchor?.id, reload ? "destination" : "held")
            XCTAssertEqual(f.view.scrollAnchor?.offset, reload ? 0 : 17)
            XCTAssertTrue(navigation.isCurrent(in: f.model), "Recovery must not create a new navigation intent")
            try await f.host.shutdownAndWait()
        }
    }

    @MainActor func testHistoryBoundaryRebindsAcrossSameIDRuntimeReplacement() async throws {
        let f = try await fixture()
        f.view.historyState = .ready; f.view.browsingHistory = true
        f.view.presentation.identity = ("old", "root")
        f.view.messages = [TranscriptMessage(id: "held", role: "user", text: "Held message")]
        f.view.scrollAnchor = .init(id: "held", offset: 23, followsBottom: false)
        f.view.olderPage.cursor = .init(incarnation: "old", lineage: "root", entry: "held")
        f.view.newerPage.cursor = .init(incarnation: "old", lineage: "root", entry: "held")
        let read = Task { await f.model.loadHistoryPage(f.chat.id, newer: false) }
        try await wait { f.commands.frames.contains { $0["method"]?.string == "session.history" } }
        let command = try XCTUnwrap(f.commands.frames.first { $0["method"]?.string == "session.history" })
        XCTAssertEqual(command["params"]?.object?["rebind"], .bool(true))
        try reply(command, on: f.host, result: ["version": .number(2), "incarnation": .string("new"), "lineage": .string("root"),
            "messages": .array([.object(["id": .string("earlier"), "role": .string("user"), "text": .string("Earlier message")])]), "older": .null,
            "newer": .object(["incarnation": .string("new"), "lineage": .string("root"), "entry": .string("earlier")])])
        let loaded = await read.value
        XCTAssertTrue(loaded)
        XCTAssertEqual(f.view.messages.map(\.id), ["earlier", "held"])
        XCTAssertEqual(f.view.newerPage.cursor?.incarnation, "new")
        XCTAssertEqual(f.view.presentation.identity?.incarnation, "new")
        XCTAssertEqual(f.view.scrollAnchor?.id, "held"); XCTAssertEqual(f.view.scrollAnchor?.offset, 23)
        XCTAssertNil(f.view.olderPage.error)
        try await f.host.shutdownAndWait()
    }

    @MainActor private func fixture() async throws -> RefreshFixture {
        let root=URL(fileURLWithPath:scratchBase())
            .appendingPathComponent("refresh-lifecycle-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let model=WorkspaceModel(stateRoot:root.appendingPathComponent("state"),vault:ConfigurationVault(storage:MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model,root:root)
        try await model.reloadConfiguration()
        let chat=ChatRecord(id:"chat",workspaceID:"project",title:"Chat",path:nil,profileID:"profile")
        let view=SessionDisplay(id:chat.id)
        view.messages=[TranscriptMessage(id:"question",role:"user",text:"Question")]
        view.projectionRevision="old-runtime:1"
        model.chats=[chat]; model.displays[chat.id]=view; model.selectedID=chat.id; model.selected=view
        let commands=RefreshCommandLog(), host=HostSupervisor(commandSender:{ commands.frames.append($0) })
        try await host.connect(cwd:root,state:root.appendingPathComponent("host"))
        model.hosts[chat.workspaceID]=host; model.opened.insert(chat.id)
        host.onLoss={ [weak model, weak view, weak host] in
            guard let model, let host, model.hosts[chat.workspaceID] === host else { return }
            model.opened.remove(chat.id)
            view?.lastSequence = -1; view?.state="interrupted"; view?.runStatus="interrupted"
            view?.notice="Host interrupted. No command was replayed."
        }
        return RefreshFixture(root:root,model:model,chat:chat,view:view,host:host,commands:commands)
    }

    @MainActor private func wait(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await eventually("Refresh did not reach the expected state", timeout: .seconds(60), file: file, line: line, condition)
    }

    @MainActor private func reply(_ frame: [String: WireValue], on host: HostSupervisor,
                                  result: [String: WireValue], ok: Bool = true) throws {
        let connection=try XCTUnwrap(host.connectionID), epoch=try XCTUnwrap(host.epoch)
        host.receive(.frame(["v":.number(1),"kind":.string("reply"),"hostEpoch":.string(epoch),
            "commandId":try XCTUnwrap(frame["commandId"]),"ok":.bool(ok),"result":.object(result)]),connectionID:connection)
    }

    private func snapshot(sequence: Double, revision: String, text: String? = nil) -> [String: WireValue] {
        var value: [String: WireValue]=["seq":.number(sequence),"state":.string("idle"),"runStatus":.string("idle"),
            "displayRevision":.string(revision),"commands":.array([])]
        if let text {
            value["messages"] = .array([.object(["id":.string("question"),"role":.string("user"),"text":.string(text)])])
        }
        return value
    }

    @MainActor func testReplacementRuntimeAcceptsLowerSequenceAndRejectsRetiredSnapshots() async throws {
        let f = try await fixture()
        f.view.historyState = .ready
        func value(_ epoch: String, _ sequence: Double, _ text: String) -> [String: WireValue] {
            var value = streamed(sequence: sequence, answer: text)
            value["monitoring"] = .object(["epoch": .string(epoch)])
            value["historyIncarnation"] = .string(epoch)
            value["displayRevision"] = .string("\(epoch):\(Int(sequence))")
            value["state"] = .string("idle"); value["runStatus"] = .string("idle")
            return value
        }
        try await exchange(f, value("first-child-turn", 500, "First reply"))
        XCTAssertEqual(f.view.lastSequence, 500)
        try await exchange(f, value("second-child-turn", 1, "Follow-up starts"))
        XCTAssertEqual(f.view.lastSequence, 1)
        XCTAssertEqual(f.view.messages.last?.text, "Follow-up starts")
        try await exchange(f, value("second-child-turn", 3, "Follow-up complete"))
        XCTAssertEqual(f.view.messages.last?.text, "Follow-up complete")
        try await exchange(f, value("first-child-turn", 501, "Retired reply"))
        XCTAssertEqual(f.view.lastSequence, 3)
        XCTAssertEqual(f.view.messages.last?.text, "Follow-up complete")
        try await f.host.shutdownAndWait()
    }

    @MainActor private func showNoticeSnapshot(_ f: RefreshFixture, preflight: String?, state: String = "paused") async throws {
        let index = f.commands.frames.count
        f.model.refresh(f.chat.id)
        try await wait { f.commands.frames.count == index + 1 }
        var result = snapshot(sequence: Double(index + 1), revision: "notice:\(index + 1)", text: "Question")
        result["state"] = .string(state); result["runStatus"] = .string(state)
        if let preflight { result["preflightError"] = .string(preflight) }
        try reply(f.commands.frames[index], on: f.host, result: result)
        try await wait { !f.view.snapshotInFlight }
    }

    @MainActor func testPreflightUncertaintyWaitsForTheReconciledInputInventory() async throws {
        for retained in [false, true] {
            let f = try await fixture(), store = try XCTUnwrap(f.model.store)
            if retained {
                try await store.recordSubmission(.init(id: "unanswered", sessionID: f.chat.id, turnID: "turn", text: "Retained input", state: "intent",
                                                       submissionOwner: try f.model.inputPublicationOwner()), draft: nil)
            }
            let gate = DraftBaselineGate(expectation(description: "Snapshot input inventory held"))
            let blocker = Task { await store.holdDraftBaseline(gate) }
            await fulfillment(of: [gate.entered], timeout: 3)
            defer { gate.resume.signal() }
            f.model.refresh(f.chat.id)
            try await wait { !f.commands.frames.isEmpty }
            var result = snapshot(sequence: 1, revision: "paused:1", text: "Question")
            result["state"] = .string("paused"); result["runStatus"] = .string("paused")
            result["queuePaused"] = .bool(true); result["preflightError"] = .string("Run stopped.")
            try reply(f.commands.frames[0], on: f.host, result: result)
            try await wait { f.view.queuePaused }
            XCTAssertFalse(f.view.uncertain, "A provisional notice cannot publish a resend gate before its input inventory is known")
            XCTAssertTrue(f.view.recovered.isEmpty)
            gate.resume.signal(); await blocker.value
            try await wait { !f.view.snapshotInFlight }
            XCTAssertEqual(f.view.uncertain, retained)
            XCTAssertEqual(f.view.recovered.map(\.text), retained ? ["Retained input"] : [])
            XCTAssertEqual(f.view.notice, "Run stopped.", "The explanation remains visible independently of recovery")
            try await f.host.shutdownAndWait()
        }
    }

    @MainActor func testClearingQueueEditNoticeImmediatelyKeepsThePreflightPart() async throws {
        let f = try await fixture()
        f.view.queueEditNotice = "Cancellation is not confirmed."
        try await showNoticeSnapshot(f, preflight: "Run stopped.")
        XCTAssertEqual(f.view.notice, "Cancellation is not confirmed.\nRun stopped.")
        let requests = f.commands.frames.count
        f.view.queueEditNotice = ""
        XCTAssertEqual(f.view.notice, "Run stopped.", "A cleared component must not await another snapshot")
        XCTAssertEqual(f.commands.frames.count, requests)
    }

    @MainActor func testReplacingQueueEditNoticeImmediatelyKeepsThePreflightPart() async throws {
        let f = try await fixture()
        f.view.queueEditNotice = "Cancellation is not confirmed."
        try await showNoticeSnapshot(f, preflight: "Run stopped.")
        f.view.queueEditNotice = "The rewrite is in the composer."
        XCTAssertEqual(f.view.notice, "The rewrite is in the composer.\nRun stopped.")
        try await showNoticeSnapshot(f, preflight: nil)
        XCTAssertEqual(f.view.notice, "The rewrite is in the composer.", "Removing preflight keeps the queued-edit component")
        f.view.queueEditNotice = ""
        XCTAssertEqual(f.view.notice, "", "Removing both parts leaves no stale composition")
    }

    @MainActor func testClearingPreflightThenQueueEditNoticeRemovesBothParts() async throws {
        let f = try await fixture()
        f.view.queueEditNotice = "Keep the rewrite."
        try await showNoticeSnapshot(f, preflight: "Run stopped.")
        try await showNoticeSnapshot(f, preflight: nil)
        XCTAssertEqual(f.view.notice, "Keep the rewrite.")
        f.view.queueEditNotice = ""
        XCTAssertEqual(f.view.notice, "")
    }

    @MainActor func testFailedRunNoticeIsNotDuplicatedInTheComposerComposition() async throws {
        let f = try await fixture()
        f.view.queueEditNotice = "Keep the rewrite."
        try await showNoticeSnapshot(f, preflight: "Provider failed.", state: "failed")
        XCTAssertEqual(f.view.failureMessage, "Provider failed.")
        XCTAssertEqual(f.view.notice, "Keep the rewrite.", "The transcript already presents a failed run's explanation")
        try await showNoticeSnapshot(f, preflight: "Run stopped.")
        XCTAssertNil(f.view.failureMessage)
        f.view.queueEditNotice = ""
        XCTAssertEqual(f.view.notice, "Run stopped.")
    }

    @MainActor func testCompletionFetchesFinalMetricsEvenInsideTheLiveThrottle() async throws {
        let f = try await fixture()
        defer { f.host.shutdown() }
        f.view.state = "running"; f.view.runStatus = "running"
        f.view.turnTiming = ["startedAt": .number(1000), "elapsedMs": .number(100)]
        f.view.footerUpdatedAt = ProcessInfo.processInfo.systemUptime
        f.model.refresh(f.chat.id)
        try await wait { f.commands.frames.count == 1 }
        XCTAssertEqual(f.commands.frames[0]["params"]?.object?["includeMetrics"]?.bool, false)
        // The helper honors includeMetrics=false, then settles before another
        // event arrives. The UI must ask once for final accounting itself.
        try reply(f.commands.frames[0], on: f.host, result: snapshot(sequence: 2, revision: "runtime:2"))
        try await wait { f.commands.frames.count == 2 }
        XCTAssertEqual(f.commands.frames[1]["params"]?.object?["includeMetrics"]?.bool, true)
        var final = snapshot(sequence: 2, revision: "runtime:2")
        final["turnMetrics"] = .object(["startedAt": .number(1000), "endedAt": .number(1250), "elapsedMs": .number(250)])
        final["latestAttempt"] = .object(["outcome": .string("completed")])
        try reply(f.commands.frames[1], on: f.host, result: final)
        try await wait { !f.view.snapshotInFlight }
        XCTAssertEqual(f.view.turnTiming["endedAt"]?.number, 1250)
        XCTAssertEqual(f.view.turnTiming["elapsedMs"]?.number, 250)
        XCTAssertEqual(f.view.metrics["outcome"]?.string, "completed")
        XCTAssertEqual(f.commands.frames.count, 2, "The final read must not create a refresh loop")
    }

    @MainActor func testAcceptedReplyCannotEraseHostLossBeforeItsContinuationRuns() async throws {
        let f=try await fixture()
        f.model.refresh(f.chat.id)
        try await wait { f.commands.frames.count==1 }
        let connection=try XCTUnwrap(f.host.connectionID)
        // Do not yield between accepting the reply and losing the connection:
        // the queued refresh continuation belongs to the retired connection.
        try reply(f.commands.frames[0],on:f.host,result:snapshot(sequence:99,revision:"retired:99",text:"Stale reply"))
        f.host.receive(.failed("Synthetic lost connection"),connectionID:connection)
        try await wait { !f.view.snapshotInFlight }
        XCTAssertEqual(f.view.state,"interrupted")
        XCTAssertEqual(f.view.notice,"Host interrupted. No command was replayed.")
        XCTAssertEqual(f.view.lastSequence,-1)
        XCTAssertEqual(f.view.messages.first?.text,"Question")
        XCTAssertEqual(f.view.projectionRevision,"old-runtime:1")
        XCTAssertFalse(f.view.dirty)
        try await f.host.shutdownAndWait()
    }

    @MainActor func testReplacementHostRefreshSurvivesOldSameViewRequestUnwinding() async throws {
        let f=try await fixture(), freshCommands=RefreshCommandLog()
        let freshHost=HostSupervisor(commandSender:{ freshCommands.frames.append($0) })
        try await freshHost.connect(cwd:f.root,state:f.root.appendingPathComponent("replacement-host"))
        defer { freshHost.shutdown() }
        f.model.refresh(f.chat.id)
        try await wait { f.commands.frames.count==1 }
        let connection=try XCTUnwrap(f.host.connectionID)
        try reply(f.commands.frames[0],on:f.host,result:snapshot(sequence:99,revision:"retired:99",text:"Stale reply"))
        f.host.receive(.failed("Synthetic lost connection"),connectionID:connection)
        f.model.hosts[f.chat.workspaceID]=freshHost; f.model.opened.insert(f.chat.id)
        f.view.state="idle"; f.view.runStatus="idle"; f.view.notice="Replacement is ready"
        f.model.refresh(f.chat.id)
        XCTAssertTrue(f.view.snapshotInFlight); XCTAssertTrue(f.view.dirty)
        try await wait { freshCommands.frames.count==1 }
        XCTAssertEqual(f.view.messages.first?.text,"Question")
        XCTAssertEqual(f.view.lastSequence,-1)
        XCTAssertEqual(f.view.notice,"Replacement is ready")
        try reply(freshCommands.frames[0],on:freshHost,result:snapshot(sequence:1,revision:"replacement:1",text:"Fresh reply"))
        try await wait { !f.view.snapshotInFlight }
        XCTAssertEqual(f.view.messages.first?.text,"Fresh reply")
        XCTAssertEqual(f.view.lastSequence,1)
        XCTAssertEqual(f.view.projectionRevision,"replacement:1")
        XCTAssertFalse(f.view.dirty)
        try await f.host.shutdownAndWait(); try await freshHost.shutdownAndWait()
    }

    @MainActor func testRetiredFailureCannotOverwriteReplacementDisplayNotice() async throws {
        let f=try await fixture()
        f.model.refresh(f.chat.id)
        try await wait { f.commands.frames.count==1 }
        let replacement=SessionDisplay(id:f.chat.id)
        replacement.messages=[TranscriptMessage(id:"replacement",role:"user",text:"Replacement")]
        replacement.notice="Current view notice"
        f.model.displays[f.chat.id]=replacement; f.model.selected=replacement
        f.view.notice="Retired view notice"
        try reply(f.commands.frames[0],on:f.host,result:["code":.string("fixture"),"message":.string("Stale failure")],ok:false)
        try await wait { !f.view.snapshotInFlight }
        XCTAssertEqual(replacement.notice,"Current view notice")
        XCTAssertEqual(f.view.notice,"Retired view notice")
        XCTAssertEqual(replacement.messages.first?.text,"Replacement")
        XCTAssertEqual(f.commands.frames.count,1)
        XCTAssertFalse(f.view.dirty)
        try await f.host.shutdownAndWait()
    }

    @MainActor func testSelectingDuringBackgroundStatusGetsFullOpaqueRevisionAndKeepsCursor() async throws {
        let f=try await fixture()
        f.model.selectedID="other"; f.model.selected=nil; f.view.hostBefore=12
        f.model.refresh(f.chat.id)
        try await wait { f.commands.frames.count==1 }
        XCTAssertEqual(f.commands.frames[0]["method"]?.string,"session.status")
        f.model.selectedID=f.chat.id; f.model.selected=f.view; f.model.refresh(f.chat.id)
        try reply(f.commands.frames[0],on:f.host,result:snapshot(sequence:2,revision:"same-runtime:2"))
        try await wait { f.commands.frames.count==2 }
        XCTAssertEqual(f.commands.frames[1]["method"]?.string,"session.snapshot")
        XCTAssertEqual(f.commands.frames[1]["params"]?.object?["displayRevision"]?.string,"old-runtime:1",
                       "A status token is not proof that its transcript was received")
        XCTAssertEqual(f.view.hostBefore,12,"Omitted status cursor must not erase the visible page cursor")
        var full=snapshot(sequence:2,revision:"same-runtime:2",text:"Current transcript"); full["before"] = .number(6)
        try reply(f.commands.frames[1],on:f.host,result:full)
        try await wait { !f.view.snapshotInFlight }
        XCTAssertEqual(f.view.messages.first?.text,"Current transcript")
        XCTAssertEqual(f.view.projectionRevision,"same-runtime:2")
        XCTAssertEqual(f.view.hostBefore,6)
        XCTAssertFalse(f.view.dirty)
        try await f.host.shutdownAndWait()
    }

    @MainActor func testFillingOlderHistoryKeepsLiveMessagesUpdatingWithoutReselecting() async throws {
        let f = try await fixture()
        let cursor = ConversationCursor(incarnation: "runtime", lineage: "root", entry: "question")
        f.view.historyState = .ready
        f.view.presentation.identity = ("runtime", "root")
        f.view.olderPage = .init(cursor: cursor)
        f.view.scrollAnchor = .init(id: "question", offset: -20, followsBottom: false)
        let earlier = try ConversationHistoryPage(.object([
            "version": .number(2), "incarnation": .string("runtime"), "lineage": .string("root"),
            "messages": .array([.object(["id": .string("earlier"), "role": .string("user"), "text": .string("Earlier question")])]),
            "older": .null, "newer": .object(["incarnation": .string("runtime"), "lineage": .string("root"), "entry": .string("earlier")])]))
        f.model.historyWindowLoader = { _, _, _, _ in earlier }
        let loaded = await f.model.loadEarlierPage(sessionID: f.chat.id)
        XCTAssertTrue(loaded)
        XCTAssertFalse(f.view.browsingHistory, "Prepending history did not remove the live tail; automatic viewport filling must not stop streaming")
        f.model.refresh(f.chat.id)
        try await wait { f.commands.frames.count == 1 }
        XCTAssertEqual(f.commands.frames[0]["params"]?.object?["includeMessages"]?.bool, true)
        var value = snapshot(sequence: 2, revision: "runtime:2", text: "Question")
        value["messages"] = .array((value["messages"]?.array ?? []) + [
            .object(["id": .string("answer"), "role": .string("assistant"), "text": .string("New answer"), "state": .string("streaming")])])
        value["historyIncarnation"] = .string("runtime"); value["historyLineage"] = .string("root")
        try reply(f.commands.frames[0], on: f.host, result: value)
        try await wait { !f.view.snapshotInFlight }
        XCTAssertEqual(f.model.selectedID, f.chat.id)
        XCTAssertEqual(f.view.messages.map(\.id), ["earlier", "question", "answer"])
        XCTAssertEqual(f.view.transcriptChanges.value.last?.text, "New answer", "The visible transcript must receive the update without a tab switch")
        XCTAssertEqual(f.view.scrollAnchor?.id, "question", "Receiving output must not move the reading anchor")
        XCTAssertEqual(f.view.scrollAnchor?.offset, -20)
        try await f.host.shutdownAndWait()
    }

    @MainActor func testPagingNewerToTheLiveTailResumesSnapshots() async throws {
        let f = try await fixture()
        f.view.historyState = .ready; f.view.browsingHistory = true
        f.view.presentation.identity = ("runtime", "root")
        f.view.newerPage = .init(cursor: .init(incarnation: "runtime", lineage: "root", entry: "question"))
        let latest = try ConversationHistoryPage(.object([
            "version": .number(2), "incarnation": .string("runtime"), "lineage": .string("root"),
            "messages": .array([.object(["id": .string("answer"), "role": .string("assistant"), "text": .string("Saved answer")])]),
            "older": .object(["incarnation": .string("runtime"), "lineage": .string("root"), "entry": .string("answer")]), "newer": .null]))
        f.model.historyWindowLoader = { _, _, _, _ in latest }
        let loaded = await f.model.loadHistoryPage(f.chat.id, newer: true)
        XCTAssertTrue(loaded); XCTAssertNil(f.view.newerPage.cursor); XCTAssertFalse(f.view.browsingHistory)
        try await wait { f.commands.frames.count == 1 }
        XCTAssertEqual(f.commands.frames[0]["params"]?.object?["includeMessages"]?.bool, true)
        XCTAssertNil(f.commands.frames[0]["params"]?.object?["displayRevision"], "Reaching the tail requests fresh rows, not a stale projection delta")
        try reply(f.commands.frames[0], on: f.host, result: snapshot(sequence: 3, revision: "runtime:3"))
        try await wait { !f.view.snapshotInFlight }
        try await f.host.shutdownAndWait()
    }

    /// The reader has scrolled up to the first row of a full window while a
    /// reply arrives. The row stays, and so does the live tail: the window
    /// runs past its budget from the reader's row until they let go of it.
    /// Before, the live page was set aside and the chat disconnected from it,
    /// and the reply stopped arriving.
    @MainActor func testLiveUpdatesDoNotEvictTheReadingAnchorAtTheResidentLimit() async throws {
        let f = try await fixture()
        f.view.historyState = .ready
        f.view.presentation.identity = ("runtime", "root")
        f.view.messages = (0..<HistoryWindowPolicy.residentRows).map { TranscriptMessage(id: "m\($0)", role: "user", text: "Message \($0)") }
        f.view.scrollAnchor = .init(id: "m0", offset: -8, followsBottom: false)
        f.model.refresh(f.chat.id)
        try await wait { f.commands.frames.count == 1 }
        var value = snapshot(sequence: 2, revision: "runtime:2")
        value["messages"] = .array((HistoryWindowPolicy.residentRows - 3...HistoryWindowPolicy.residentRows).map {
            .object(["id": .string("m\($0)"), "role": .string("user"), "text": .string("Message \($0)")])
        })
        value["historyIncarnation"] = .string("runtime"); value["historyLineage"] = .string("root")
        try reply(f.commands.frames[0], on: f.host, result: value)
        try await wait { !f.view.snapshotInFlight }
        XCTAssertEqual(f.view.messages.first?.id, "m0", "The reader's row stays")
        XCTAssertEqual(f.view.messages.last?.id, "m\(HistoryWindowPolicy.residentRows)", "The live tail arrives")
        XCTAssertEqual(f.view.messages.count, HistoryWindowPolicy.residentRows + 1)
        XCTAssertEqual(f.view.scrollAnchor?.offset, -8)
        XCTAssertNil(f.view.newerPage.cursor)
        XCTAssertFalse(f.view.browsingHistory, "Holding a row does not disconnect the live window")
        try await f.host.shutdownAndWait()
    }

    /// A chat read from its first row, whose window then fills as it grows:
    /// the rows that leave its start are reached again by scrolling up,
    /// through the earlier edge, as any earlier rows are. Before, a window
    /// that had every row kept no edge, and rows that left it came back only
    /// when the chat was opened again.
    @MainActor func testRowsThatLeaveAWholeChatsWindowCanBeScrolledBackTo() async throws {
        let caps = TranscriptPaging.residentCaps
        TranscriptPaging.residentCaps = (rows: 8, bytes: caps.bytes)
        defer { TranscriptPaging.residentCaps = caps }
        let f = try await fixture()
        f.view.historyState = .ready
        f.view.presentation.identity = ("runtime", "root")
        let role = { (index: Int) in index % 2 == 0 ? "user" : "assistant" }
        let wire = { (index: Int) -> WireValue in .object(["id": .string("m\(index)"), "role": .string(role(index)), "text": .string("Message \(index)")]) }
        // Every row of the chat, from its first: there is nothing before it.
        f.view.messages = (0..<8).map { TranscriptMessage(id: "m\($0)", role: role($0), text: "Message \($0)") }
        XCTAssertNil(f.view.olderPage.cursor)
        f.model.refresh(f.chat.id)
        try await wait { f.commands.frames.count == 1 }
        // Two more turns; the helper's page holds its newest rows.
        var value = snapshot(sequence: 2, revision: "runtime:2")
        value["messages"] = .array((6..<12).map(wire))
        value["historyIncarnation"] = .string("runtime"); value["historyLineage"] = .string("root")
        value["historyOlder"] = .object(["incarnation": .string("runtime"), "lineage": .string("root"), "entry": .string("m6")])
        try reply(f.commands.frames[0], on: f.host, result: value)
        try await wait { !f.view.snapshotInFlight }
        XCTAssertEqual(f.view.messages.map(\.id), (4..<12).map { "m\($0)" }, "The window keeps the newest rows")
        XCTAssertEqual(f.view.olderPage.cursor?.entry, "m4", "The rows that left it have an earlier edge, at its first row")
        XCTAssertEqual(f.view.olderPage.cursor?.incarnation, "runtime")
        XCTAssertFalse(f.view.browsingHistory, "The chat stays on its live tail")
        // Scrolling up reads them back, from that edge.
        let earlier: WireValue = .array((0..<4).map(wire))
        f.model.historyWindowLoader = { _, cursor, newer, _ in
            guard !newer, cursor?.entry == "m4" else { throw HostError.failure("Read from the wrong edge") }
            return try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("runtime"), "lineage": .string("root"),
                "older": .null, "newer": .object(["incarnation": .string("runtime"), "lineage": .string("root"), "entry": .string("m3")]),
                "messages": earlier]))
        }
        let loaded = await f.model.loadEarlierPage(sessionID: f.chat.id)
        XCTAssertTrue(loaded, "The earlier edge reads")
        XCTAssertEqual(f.view.messages.first?.id, "m0", "Every row of the chat can be scrolled back to")
        XCTAssertNil(f.view.olderPage.cursor, "The chat's first row is reached")
        try await f.host.shutdownAndWait()
    }

    @MainActor func testRealHelperUpdatesReopenedAndEarlierWindowsWithoutSwitchingTabs() async throws {
        // The journal pages three turns (a question, its request record and
        // its reply) at a time, as the 0.1.71 plan did, so the reopened chat
        // has earlier rows to read.
        usePlanPages(rows: 9)
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("reopened-gateway-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var repository = URL(fileURLWithPath: #filePath); for _ in 0..<4 { repository.deleteLastPathComponent() }
        let gateway = Process(), pipe = Pipe(); gateway.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        gateway.arguments = ["-u", repository.appendingPathComponent("scripts/test-native-host.py").path, "--serve"]
        gateway.standardOutput = pipe; gateway.standardError = FileHandle.nullDevice
        try gateway.run(); defer { if gateway.isRunning { gateway.terminate(); gateway.waitUntilExit() } }
        let handle = pipe.fileHandleForReading, greeting = await Task.detached { handle.availableData }.value
        let port = try XCTUnwrap(try JSONDecoder().decode([String: Int].self, from: greeting)["port"])
        let project = WorkspaceRecord(id: "reopened", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.baseUrl = "http://127.0.0.1:\(port)/v1"; profile.modelId = "billing-json"
        profile.advancedJSON = #"{"routing":{"replayPolicy":"portable"}}"#
        let vault = ConfigurationVault(storage: MemoryVaultStorage()), savedProfile = profile
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [project]; $0.profiles = [.init(profile: savedProfile, apiKey: "fixture-secret")]
            $0.resources[project.id] = .object(["codexHome": .string(root.appendingPathComponent("empty").path), "skills": .bool(false)])
            $0.playsCompletionSound = false
        }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root); try await model.reloadConfiguration()
        let chat = ChatRecord(id: "retained", workspaceID: project.id, title: "Retained chat", path: nil, profileID: profile.id)
        model.chats = [chat]
        let host = try await model.open(chat)
        for index in 0..<8 {
            _ = try await host.request("turn.submit", sessionID: chat.id,
                params: ["text": .string("Saved question \(index)"), "clientTurnId": .string("saved-\(index)")])
            try await eventually("Fixture seed \(index) finished", timeout: .seconds(60), until: {
                let state = try await host.request("session.status", sessionID: chat.id).object ?? [:]
                if state["state"]?.string == "error" {
                    throw HostError.failure("Fixture seed \(index) failed: " + (state["preflightError"]?.string ?? "missing error"))
                }
                return state["state"]?.string == "idle"
            })
        }
        // Retire the display and helper session to exercise real disk hydration,
        // not a retained in-memory projection from the seed requests.
        try await wait { model.displays[chat.id]?.snapshotInFlight != true }
        _ = try await host.request("session.close", sessionID: chat.id)
        model.opened.remove(chat.id); model.displays.removeValue(forKey: chat.id)
        await model.select(chat.id)
        let view = try XCTUnwrap(model.selected)
        XCTAssertTrue(view.presentation.identity?.incarnation.hasPrefix("file:") == true)
        XCTAssertEqual(view.messages.filter { $0.role == "user" }.count, 3)
        // A cold page's automatic earlier read can still be in flight when
        // the viewport is ready. Hold that real read to exercise the overlap.
        let earlierGate = HistoryReadGate()
        addTeardownBlock { await earlierGate.release() }
        model.historyWindowLoader = { [weak model] id, cursor, newer, around in
            guard let model else { throw CancellationError() }
            XCTAssertNotNil(cursor); XCTAssertFalse(newer); XCTAssertNil(around)
            await MainActor.run { model.historyWindowLoader = nil }
            await earlierGate.read()
            let record = await model.record(id)
            let item = try XCTUnwrap(record)
            return try await model.readConversationWindow(item, cursor: cursor, newer: newer, around: around)
        }
        let pane = TranscriptFrameBudgetTests.Pane(view, height: 1600, onReady: { _, generation in
            guard generation == view.presentationGeneration else { return }
            view.historyState = .ready; view.presentation.readyAt = PerformanceProbe.now
        }, onEarlier: { model.loadEarlier(sessionID: $0) })
        defer { pane.close() }
        try await eventually("The reopened viewport is ready", timeout: .seconds(60)) {
            pane.hosted.layoutSubtreeIfNeeded(); pane.window.displayIfNeeded()
            return view.historyState == .ready
        }
        model.loadEarlier(sessionID: chat.id)
        try await eventually("The earlier read is in flight", timeout: .seconds(60), until: { await earlierGate.reads > 0 })
        // Join the owned read. A second loadEarlierPage while it is in
        // flight correctly returns false, even though the first will succeed.
        let earlierTask = try XCTUnwrap(view.presentation.olderTask)
        await earlierGate.release()
        let loaded = await earlierTask.value
        XCTAssertTrue(loaded)
        XCTAssertGreaterThan(view.messages.filter { $0.role == "user" }.count, 3)
        XCTAssertFalse(view.browsingHistory)

        for (index, text) in ["Continue the reopened chat", "Continue from the earlier window"].enumerated() {
            if index == 1 {
                // The helper pages whole turns, 250 rows of them: this
                // short chat is one page of its. The earlier window is read
                // from the journal, three turns of it, with the session closed
                // as the reopen above was; sending opens it again.
                try await wait { view.snapshotInFlight != true }
                _ = try await host.request("session.close", sessionID: chat.id)
                model.opened.remove(chat.id)
                let earlierID = try XCTUnwrap(view.messages.first(where: { $0.role == "user" })?.id)
                model.reloadHistory(chat.id, around: earlierID); await view.presentation.navigation?.value
                try await eventually("The earlier viewport is ready", timeout: .seconds(60)) {
                    pane.hosted.layoutSubtreeIfNeeded(); pane.window.displayIfNeeded()
                    return view.historyState == .ready
                }
                XCTAssertNotNil(view.newerPage.cursor); XCTAssertTrue(view.browsingHistory)
                // The second continuation uses fragmented Responses SSE,
                // while the cold reopen above exercises a fast JSON reply.
                model.chats[0].model = "route-late"
            }
            view.draft = text; model.send(sessionID: chat.id)
            func isSubmittedReply(_ message: TranscriptMessage) -> Bool {
                guard let submitted = view.messages.first(where: { $0.role == "user" && $0.text == text }) else { return false }
                return message.role == "assistant" && !message.isStreaming && message.text.contains("Hello") &&
                    (message.taskRootID ?? message.turn) == (submitted.taskRootID ?? submitted.id)
            }
            try await wait {
                !view.loading && !view.busy && view.messages.contains { $0.role == "user" && $0.text == text } &&
                    view.messages.contains { isSubmittedReply($0) }
            }
            try await eventually("The mounted transcript shows this submitted turn's reply", timeout: .seconds(60)) {
                pane.hosted.layoutSubtreeIfNeeded(); pane.window.displayIfNeeded()
                return pane.page?.snapshot?.messages.contains { isSubmittedReply($0) } == true &&
                    pane.page?.snapshot?.messages.contains { $0.role == "user" && $0.text == text } == true
            }
            XCTAssertNil(view.sendFailure); XCTAssertNil(view.failureMessage)
            XCTAssertEqual(model.selectedID, chat.id); XCTAssertTrue(model.selected === view)
            XCTAssertFalse(view.browsingHistory); XCTAssertNil(view.newerPage.cursor)
            XCTAssertTrue(pane.page?.snapshot?.messages.contains { $0.role == "user" && $0.text == text } == true,
                          "The mounted native transcript must show the new input without being recreated")
            XCTAssertTrue(pane.page?.snapshot?.messages.contains { isSubmittedReply($0) } == true)
            XCTAssertEqual(view.messages.last?.isStreaming, false)
        }
    }
}

/// Suspends a history read until the test lets it go, and counts the reads.
private actor HistoryReadGate {
    private(set) var reads = 0
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func readFirstOnly() async -> Int {
        reads += 1; let read = reads
        if read == 1, !open { await withCheckedContinuation { waiting.append($0) } }
        return read
    }
    func read() async {
        reads += 1
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() { open = true; waiting.forEach { $0.resume() }; waiting = [] }
}

extension WorkspaceRefreshLifecycleTests {
    /// A live page whose rows stream while its boundaries stay put.
    private func streamed(sequence: Double, answer: String) -> [String: WireValue] {
        var value = snapshot(sequence: sequence, revision: "runtime:\(Int(sequence))")
        value["state"] = .string("running"); value["runStatus"] = .string("running")
        value["messages"] = .array([
            .object(["id": .string("question"), "role": .string("user"), "text": .string("Question")]),
            .object(["id": .string("answer"), "role": .string("assistant"), "text": .string(answer), "state": .string("streaming")])])
        value["historyIncarnation"] = .string("runtime"); value["historyLineage"] = .string("root")
        value["before"] = .number(4)
        value["historyOlder"] = .object(["incarnation": .string("runtime"), "lineage": .string("root"), "entry": .string("question")])
        return value
    }

    /// One snapshot round trip: ask, answer, and wait for it to be applied.
    @MainActor private func exchange(_ f: RefreshFixture, _ result: [String: WireValue]) async throws {
        let count = f.commands.frames.count
        f.model.refresh(f.chat.id)
        try await wait { f.commands.frames.count > count }
        try reply(f.commands.frames[count], on: f.host, result: result)
        try await wait { !f.view.snapshotInFlight }
    }

    /// Rows as the helper sends them.
    private func wireRows(_ range: Range<Int>, text: (Int) -> String = { "Message \($0)" }) -> WireValue {
        .array(range.map { .object(["id": .string("m\($0)"), "role": .string($0 % 2 == 0 ? "user" : "assistant"), "text": .string(text($0))]) })
    }
    private func liveSnapshot(_ sequence: Double, _ rows: WireValue) -> [String: WireValue] {
        var value = snapshot(sequence: sequence, revision: "runtime:\(Int(sequence))")
        value["messages"] = rows
        value["historyIncarnation"] = .string("runtime"); value["historyLineage"] = .string("root")
        return value
    }

    /// The display owns the resident window: it keeps the newest rows that
    /// fit both of its caps, rows and bytes, whatever the helper sends, and
    /// the rows it lets go of stay reachable through the earlier edge. The
    /// page draws what it holds (`TranscriptPageStressTests`).
    @MainActor func testSnapshotsKeepADisplayWithinBothOfItsCaps() async throws {
        let f = try await fixture()
        f.view.historyState = .ready
        f.view.presentation.identity = ("runtime", "root")
        let limit = HistoryWindowPolicy.residentRows
        // Rows: a whole chat of `limit` rows, and sixty more arrive.
        f.view.messages = (0..<limit).map { TranscriptMessage(id: "m\($0)", role: $0 % 2 == 0 ? "user" : "assistant", text: "Message \($0)") }
        try await exchange(f, liveSnapshot(2, wireRows(limit - 40..<limit + 60)))
        XCTAssertEqual(f.view.messages.count, limit, "The row cap holds")
        XCTAssertEqual(f.view.messages.first?.id, "m60"); XCTAssertEqual(f.view.messages.last?.id, "m\(limit + 59)")
        XCTAssertEqual(f.view.olderPage.cursor?.entry, "m60", "The rows let go of stay reachable")
        // Bytes: a megabyte a row, four rows past a budget of four million
        // bytes in all. The window keeps whole turns of them.
        let caps = TranscriptPaging.residentCaps
        TranscriptPaging.residentCaps = (rows: caps.rows, bytes: 4_000_000)
        defer { TranscriptPaging.residentCaps = caps }
        let big = String(repeating: "x", count: 1 << 20)
        try await exchange(f, liveSnapshot(3, wireRows(limit + 50..<limit + 64, text: { $0 >= limit + 60 ? big + " \($0)" : "Message \($0)" })))
        let bytes = f.view.messages.reduce(0) { $0 + TranscriptPaging.size($1) }
        XCTAssertLessThanOrEqual(bytes, TranscriptPaging.residentCaps.bytes, "The byte cap holds")
        XCTAssertEqual(f.view.messages.last?.id, "m\(limit + 63)", "The newest rows are the ones kept")
        XCTAssertLessThan(f.view.messages.count, 5)
        XCTAssertEqual(f.view.messages.first?.role, "user", "From the question of the newest turn that fits")
        XCTAssertEqual(f.view.olderPage.cursor?.entry, f.view.messages.first?.id)
        try await f.host.shutdownAndWait()
    }

    /// A held row stretches the window past its budget only for as long as it
    /// is held. Let go of, the window goes back to its budget at once, even
    /// with nothing more arriving, and the rows it lets go of stay reachable:
    /// with nothing held, a display never keeps more than its window.
    @MainActor func testAWindowAHeldRowStretchedGoesBackToItsBudgetWhenLetGo() async throws {
        let caps = TranscriptPaging.residentCaps
        TranscriptPaging.residentCaps = (rows: 8, bytes: caps.bytes)
        defer { TranscriptPaging.residentCaps = caps }
        let f = try await fixture()
        f.view.historyState = .ready
        f.view.presentation.identity = ("runtime", "root")
        f.view.messages = (0..<8).map { TranscriptMessage(id: "m\($0)", role: $0 % 2 == 0 ? "user" : "assistant", text: "Message \($0)") }
        // A selection in the second row, then two rows more.
        f.view.pinnedHistoryIDs = ["m1"]
        try await exchange(f, liveSnapshot(2, wireRows(6..<10)))
        XCTAssertEqual(f.view.messages.map(\.id), (0..<10).map { "m\($0)" }, "The held row stays with its whole turn, and the live tail arrives")
        // Let go of: back to eight rows, with nothing more arriving.
        f.view.pinnedHistoryIDs = []
        try await wait { f.view.messages.count == 8 }
        XCTAssertEqual(f.view.messages.map(\.id), (2..<10).map { "m\($0)" })
        XCTAssertEqual(f.view.olderPage.cursor?.entry, "m2", "The rows let go of stay reachable")
        // The row the reader reads from holds it the same way, until they
        // return to the newest row.
        f.view.scrollAnchor = .init(id: "m2", offset: -8, followsBottom: false)
        try await exchange(f, liveSnapshot(3, wireRows(8..<12)))
        XCTAssertEqual(f.view.messages.first?.id, "m2"); XCTAssertEqual(f.view.messages.last?.id, "m11")
        XCTAssertEqual(f.view.messages.count, 10)
        f.view.scrollAnchor = .init(id: "", offset: 0, followsBottom: true)
        f.model.anchorChanged(f.view)
        try await wait { f.view.messages.count == 8 }
        XCTAssertEqual(f.view.messages.map(\.id), (4..<12).map { "m\($0)" })
        XCTAssertEqual(f.view.olderPage.cursor?.entry, "m4")
        // A window within its budget is left as it is.
        f.view.pinnedHistoryIDs = ["m5"]; f.view.pinnedHistoryIDs = []
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(f.view.messages.count, 8)
        try await f.host.shutdownAndWait()
    }

    /// A stretched window that stops taking updates goes back to its budget
    /// as well once let go of: no next update is coming to cut it. Here the
    /// chat moved onto another branch elsewhere, and waits for Reload.
    @MainActor func testAStretchedWindowThatStoppedTakingUpdatesGoesBackToItsBudgetWhenLetGo() async throws {
        let caps = TranscriptPaging.residentCaps
        TranscriptPaging.residentCaps = (rows: 8, bytes: caps.bytes)
        defer { TranscriptPaging.residentCaps = caps }
        let f = try await fixture()
        f.view.historyState = .ready
        f.view.presentation.identity = ("runtime", "root")
        f.view.messages = (0..<8).map { TranscriptMessage(id: "m\($0)", role: $0 % 2 == 0 ? "user" : "assistant", text: "Message \($0)") }
        f.view.pinnedHistoryIDs = ["m1"]
        try await exchange(f, liveSnapshot(2, wireRows(6..<10)))
        XCTAssertEqual(f.view.messages.map(\.id), (0..<10).map { "m\($0)" })
        // The branch changes elsewhere: the rows stay as they were, the chat
        // says why, and it takes no more of the helper's rows.
        var moved = liveSnapshot(3, wireRows(6..<12))
        moved["historyLineage"] = .string("elsewhere")
        try await exchange(f, moved)
        XCTAssertTrue(f.view.browsingHistory)
        XCTAssertEqual(f.view.newerPage.error, WorkspaceModel.branchChangedElsewhere)
        XCTAssertEqual(f.view.messages.map(\.id), (0..<10).map { "m\($0)" })
        f.view.pinnedHistoryIDs = []
        try await wait { f.view.messages.count == 8 }
        XCTAssertEqual(f.view.messages.map(\.id), (2..<10).map { "m\($0)" })
        XCTAssertEqual(f.view.olderPage.cursor?.entry, "m2", "The rows let go of stay reachable")
        XCTAssertEqual(f.view.newerPage.error, WorkspaceModel.branchChangedElsewhere, "It still says what happened")
        try await f.host.shutdownAndWait()
    }

    /// A streamed token changes the rows and nothing else the pane shows. The
    /// page cursor, the helper's row count and the older boundary stay where
    /// they were, so the display must not announce a change of its own: that
    /// re-evaluates the conversation pane, its composer, its footer and the
    /// actions menu once per token, which the transcript's separate channel
    /// exists to avoid.
    @MainActor func testStreamedSnapshotsDoNotRepublishTheWholeDisplay() async throws {
        let f = try await fixture()
        f.view.historyState = .ready
        f.view.presentation.identity = ("runtime", "root")
        var answer = "A"
        try await exchange(f, streamed(sequence: 2, answer: answer))
        var publications = 0, transcripts = 0
        let shell = f.view.objectWillChange.sink { publications += 1 }
        let rows = f.view.transcriptChanges.dropFirst().sink { _ in transcripts += 1 }
        defer { shell.cancel(); rows.cancel() }
        for index in 0..<12 {
            answer += " token\(index)"
            try await exchange(f, streamed(sequence: Double(3 + index), answer: answer))
        }
        print("PERF whole-display publications for 12 streamed snapshots: \(publications); transcript publications: \(transcripts)")
        XCTAssertEqual(transcripts, 12, "Every token reaches the transcript")
        XCTAssertEqual(f.view.messages.last?.text, answer)
        XCTAssertEqual(f.view.hostBefore, 4); XCTAssertEqual(f.view.before, "question")
        XCTAssertEqual(publications, 0, "A streamed token must not republish the whole conversation display")
        try await f.host.shutdownAndWait()
    }

    /// Scrolling to the top while a reply streams asks for the earlier page
    /// once. The snapshots that keep arriving must leave that request alone:
    /// resetting the boundary put "Load earlier" back, started a second read
    /// of the same page and then reported that the window had moved, which
    /// also stopped earlier rows from loading on their own.
    @MainActor func testStreamingDoesNotResetAnInFlightLoadOfEarlierRows() async throws {
        let f = try await fixture()
        f.view.historyState = .ready
        f.view.presentation.identity = ("runtime", "root")
        try await exchange(f, streamed(sequence: 2, answer: "First"))
        let cursor = try XCTUnwrap(f.view.olderPage.cursor)
        XCTAssertEqual(cursor.entry, "question")
        let earlier = try ConversationHistoryPage(.object([
            "version": .number(2), "incarnation": .string("runtime"), "lineage": .string("root"),
            "messages": .array([.object(["id": .string("earlier"), "role": .string("user"), "text": .string("Earlier question")])]),
            "older": .null, "newer": .object(["incarnation": .string("runtime"), "lineage": .string("root"), "entry": .string("earlier")])]))
        let gate = HistoryReadGate()
        f.model.historyWindowLoader = { _, _, _, _ in await gate.read(); return earlier }
        let first = Task { await f.model.loadHistoryPage(f.chat.id, newer: false) }
        for _ in 0..<500 { if await gate.reads == 1 { break }; await Task.yield() }
        XCTAssertTrue(f.view.olderPage.loading)
        try await exchange(f, streamed(sequence: 3, answer: "First token"))
        XCTAssertTrue(f.view.olderPage.loading, "A streamed token must not end the load in progress")
        let second = Task { await f.model.loadHistoryPage(f.chat.id, newer: false) }
        for _ in 0..<50 { await Task.yield() }
        let reads = await gate.reads
        XCTAssertEqual(reads, 1, "The same earlier page is read once")
        await gate.release()
        let loaded = await first.value, repeated = await second.value
        XCTAssertTrue(loaded); XCTAssertFalse(repeated)
        XCTAssertNil(f.view.olderPage.error, "No false \"window moved\" error")
        XCTAssertFalse(f.view.olderPage.loading)
        XCTAssertEqual(f.view.messages.map(\.id), ["earlier", "question", "answer"])
        try await f.host.shutdownAndWait()
    }

    /// When the window's first row really is let go of while an earlier page
    /// is on its way (new output filled the resident budget), that page no
    /// longer joins the window. It is dropped without an error, and without a
    /// gap in the conversation; the boundary the window has now is the one
    /// the next read asks for.
    @MainActor func testAnEarlierPageThatNoLongerJoinsTheWindowIsDroppedQuietly() async throws {
        let f = try await fixture()
        f.view.historyState = .ready
        f.view.presentation.identity = ("runtime", "root")
        let limit = HistoryWindowPolicy.residentRows
        f.view.messages = (0..<limit).map { TranscriptMessage(id: "m\($0)", role: "user", text: "Message \($0)") }
        f.view.olderPage = .init(cursor: .init(incarnation: "runtime", lineage: "root", entry: "m0"))
        let earlier = try ConversationHistoryPage(.object([
            "version": .number(2), "incarnation": .string("runtime"), "lineage": .string("root"),
            "messages": .array([.object(["id": .string("e0"), "role": .string("user"), "text": .string("Earlier")])]),
            "older": .null, "newer": .object(["incarnation": .string("runtime"), "lineage": .string("root"), "entry": .string("e0")])]))
        let gate = HistoryReadGate()
        f.model.historyWindowLoader = { _, _, _, _ in await gate.read(); return earlier }
        let first = Task { await f.model.loadHistoryPage(f.chat.id, newer: false) }
        for _ in 0..<500 { if await gate.reads == 1 { break }; await Task.yield() }
        var value = snapshot(sequence: 2, revision: "runtime:2")
        value["messages"] = .array((limit - 3..<limit + 3).map {
            .object(["id": .string("m\($0)"), "role": .string("user"), "text": .string("Message \($0)")])
        })
        value["historyIncarnation"] = .string("runtime"); value["historyLineage"] = .string("root")
        try await exchange(f, value)
        XCTAssertEqual(f.view.messages.first?.id, "m3", "New output let the first rows go")
        XCTAssertTrue(f.view.olderPage.loading, "The read in flight is not ended by the snapshot")
        await gate.release()
        let loaded = await first.value
        XCTAssertFalse(loaded, "The page that no longer joins the window is not added")
        XCTAssertNil(f.view.olderPage.error, "Nothing went wrong that the reader has to act on")
        XCTAssertFalse(f.view.olderPage.loading)
        XCTAssertEqual(f.view.olderPage.cursor?.entry, "m3", "The next read starts from the window as it is")
        XCTAssertFalse(f.view.messages.contains { $0.id == "e0" }, "No gap: the earlier page was not joined to the moved window")
        try await f.host.shutdownAndWait()
    }

    /// A steer sent as the run ends reaches a helper with nothing running and
    /// is refused. The chat is idle by then, and must stay idle: restoring the
    /// "running" it had when the steer was pressed left the live bar, the
    /// clock and the Stop button up with no run behind them.
    @MainActor func testASteerThatLosesTheRaceWithTheEndOfTheRunLeavesTheChatIdle() async throws {
        let f = try await fixture()
        var profile = ProfileRecord(); profile.id = "profile"; profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "fixture"
        f.model.profiles = [profile]
        try await f.model.store?.put(f.chat, kind: "chat", id: f.chat.id)
        f.view.state = "running"; f.view.runStatus = "running"
        f.view.draft = "Also check the tests"
        f.model.send(steer: true, sessionID: f.chat.id)
        try await wait { f.commands.frames.contains { $0["method"]?.string == "turn.steer" } }
        let steer = try XCTUnwrap(f.commands.frames.first { $0["method"]?.string == "turn.steer" })
        // The run ends before the helper reads the steer.
        try await exchange(f, snapshot(sequence: 5, revision: "runtime:5"))
        XCTAssertEqual(f.view.state, "idle")
        try reply(steer, on: f.host, result: ["code": .string("not_running"), "message": .string("No run is active")], ok: false)
        try await wait { !f.view.loading }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(f.view.state, "idle", "The refused steer must not bring back the finished run")
        XCTAssertFalse(f.view.hasWork)
        XCTAssertEqual(f.view.sendFailure, "The run finished. Press Return to send this as a new message.")
        XCTAssertEqual(f.view.draft, "Also check the tests", "The text stays, ready to send as a new message")
        try await f.host.shutdownAndWait()
    }

    /// A reply longer than the page comes in a page that starts after the
    /// message it answers. A chat that sent that message a moment ago may not
    /// have its row yet, so the page does not join the rows it shows. A
    /// reader at the live end has the gap read in and the chat goes on live;
    /// before, it stopped at the last reply behind a "newer" edge, and the
    /// reply being written never appeared (the gallery's scene 20, 2 runs in 4).
    @MainActor func testALivePageThatLeavesAGapIsFilledForAReaderAtTheLiveEnd() async throws {
        let f = try await fixture()
        let reads = RefreshCommandLog()
        f.model.historyWindowLoader = { _, cursor, newer, _ in
            await MainActor.run { reads.frames.append(["newer": .bool(newer), "entry": .string(cursor?.entry ?? "")]) }
            return try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("runtime"), "lineage": .string("root"),
                "older": .null, "newer": .null, "messages": .array(Self.rows(["turn-2": "user", "ledger-2": "system", "answer-2": "assistant"]))]))
        }
        f.view.messages = try TranscriptMessage.page(.array(Self.rows(["question": "user", "ledger-1": "system", "answer-1": "assistant"])))
        f.model.refresh(f.chat.id)
        try await wait { f.commands.frames.count == 1 }
        try reply(f.commands.frames[0], on: f.host, result: gapPage(sequence: 4))
        // The rows this refresh brought are not on screen yet: the gap waits
        // for them, as a newer read always has.
        try await wait { f.view.browsingHistory }
        XCTAssertEqual(f.view.historyState, .preparing)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(reads.frames.isEmpty)
        f.model.historyViewportReady(f.chat.id, generation: f.view.presentationGeneration)
        try await wait { !f.view.browsingHistory && f.view.messages.count == 6 }
        XCTAssertEqual(f.view.messages.map(\.id), ["question", "ledger-1", "answer-1", "turn-2", "ledger-2", "answer-2"])
        XCTAssertEqual(reads.frames.map { $0["entry"]?.string }, ["answer-1"], "The gap after the last row shown is read once")
        try await wait { f.commands.frames.count == 2 }
        XCTAssertEqual(f.commands.frames[1]["method"]?.string, "session.snapshot", "Back at the live tail, it asks for the live page again")
        try await f.host.shutdownAndWait()
    }

    /// A reader who scrolled up keeps their place: the gap waits behind the
    /// "newer" edge, as it did.
    @MainActor func testALivePageThatLeavesAGapWaitsForAReaderWhoScrolledUp() async throws {
        let f = try await fixture()
        let reads = RefreshCommandLog()
        f.model.historyWindowLoader = { _, _, _, _ in
            await MainActor.run { reads.frames.append([:]) }
            throw HostError.failure("not read")
        }
        f.view.messages = try TranscriptMessage.page(.array(Self.rows(["question": "user", "ledger-1": "system", "answer-1": "assistant"])))
        f.view.scrollAnchor = TranscriptAnchor(id: "question", offset: 0, followsBottom: false)
        f.model.refresh(f.chat.id)
        try await wait { f.commands.frames.count == 1 }
        try reply(f.commands.frames[0], on: f.host, result: gapPage(sequence: 4))
        try await wait { f.view.browsingHistory }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(reads.frames.isEmpty)
        XCTAssertEqual(f.view.newerPage.cursor?.entry, "answer-1", "The newer edge offers the rest")
        XCTAssertEqual(f.view.messages.map(\.id), ["question", "ledger-1", "answer-1"])
        try await f.host.shutdownAndWait()
    }

    /// Rows in order, as a page carries them.
    private static func rows(_ ordered: KeyValuePairs<String, String>) -> [WireValue] {
        ordered.map { .object(["id": .string($0.key), "role": .string($0.value), "text": .string($0.key)]) }
    }
    /// A live page holding only a long reply and its ledger: no room was left
    /// for the message they answer, the row it says it follows.
    private func gapPage(sequence: Double) -> [String: WireValue] {
        var value = snapshot(sequence: sequence, revision: "runtime:\(Int(sequence))")
        value["messages"] = .array(Self.rows(["ledger-2": "system", "answer-2": "assistant"]))
        value["historyFollows"] = .string("turn-2")
        value["historyIncarnation"] = .string("runtime"); value["historyLineage"] = .string("root")
        return value
    }

    /// A chat whose display is let go of has its idle helper session closed
    /// too: the helper kept every chat visited loaded for as long as it ran.
    /// A busy chat keeps its session, and a closed chat's next open waits for
    /// the close before it asks for the session again.
    @MainActor func testEvictingAnIdleDisplayClosesItsHelperSessionBeforeItOpensAgain() async throws {
        let f = try await fixture()
        var profile = ProfileRecord(); profile.id = "profile"; profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "fixture"
        f.model.profiles = [profile]
        for index in 0..<9 {
            let id = "other-\(index)"
            f.model.chats.append(ChatRecord(id: id, workspaceID: "project", title: id, path: nil, profileID: "profile"))
            let display = SessionDisplay(id: id); display.used = Date(timeIntervalSince1970: Double(index))
            f.model.displays[id] = display; f.model.opened.insert(id)
        }
        f.model.displays["other-1"]?.state = "running"
        let selection = Task { await f.model.select("other-8") }
        defer { selection.cancel() }
        try await wait { f.commands.frames.filter { $0["method"]?.string == "session.close" }.count == 2 }
        let closes = f.commands.frames.filter { $0["method"]?.string == "session.close" }
        XCTAssertEqual(closes.map { $0["sessionId"]?.string }, ["other-0", "other-2"], "The two oldest idle chats are let go of; the running one is not")
        XCTAssertEqual(f.model.opened, Set([f.chat.id] + (0..<9).map { "other-\($0)" }), "A close can be rejected; loaded state remains until acknowledgement")
        let reopened = RefreshCommandLog(), other = try XCTUnwrap(f.model.record("other-0"))
        let reopen = Task { @MainActor in _ = try? await f.model.open(other); reopened.frames.append([:]) }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(reopened.frames.isEmpty, "The open waits for the close in flight")
        XCTAssertFalse(f.commands.frames.contains { $0["method"]?.string == "session.open" })
        try reply(closes[0], on: f.host, result: ["accepted": .bool(true)])
        try await wait { !reopened.frames.isEmpty }
        await reopen.value
        XCTAssertNil(f.model.sessionClosings["other-0"])
        try reply(closes[1], on: f.host, result: ["accepted": .bool(true)])
        try await wait { f.model.sessionClosings["other-2"] == nil }
        XCTAssertEqual(f.model.opened, Set([f.chat.id] + (1...8).filter { $0 != 2 }.map { "other-\($0)" }), "Acknowledged closes release their loaded state")
        try await f.host.shutdownAndWait()
    }

    @MainActor func testEightDisplayCacheAlsoReleasesEvictedSideBudgetWriters() async throws {
        let f = try await fixture()
        for index in 0..<9 {
            let parent = "owner-\(index)", side = "side-\(index)"
            f.model.chats.append(ChatRecord(id: parent, workspaceID: "project", title: parent, profileID: "profile"))
            f.model.chats.append(ChatRecord(id: side, workspaceID: "project", title: side, path: "/fixture/side_" + side + ".jsonl", profileID: "profile", parentSessionID: parent))
            let display = SessionDisplay(id: side); display.used = Date(timeIntervalSince1970: Double(index))
            f.model.displays[side] = display; f.model.opened.formUnion([parent, side]); f.model.budgetDependencySessions.insert(parent)
        }
        let selection = Task { await f.model.select("side-8", reopensSide: false) }
        defer { selection.cancel() }
        try await wait { f.commands.frames.filter { $0["method"]?.string == "session.close" }.count == 2 }
        let sides = f.commands.frames.filter { $0["method"]?.string == "session.close" }
        XCTAssertEqual(Set(sides.compactMap { $0["sessionId"]?.string }), ["side-0", "side-1"])
        for frame in sides { try reply(frame, on: f.host, result: ["accepted": .bool(true)]) }
        try await wait { f.commands.frames.filter { $0["method"]?.string == "session.close" }.count == 4 }
        let owners = f.commands.frames.filter { $0["method"]?.string == "session.close" && $0["sessionId"]?.string?.hasPrefix("owner-") == true }
        XCTAssertEqual(Set(owners.compactMap { $0["sessionId"]?.string }), ["owner-0", "owner-1"])
        for frame in owners { try reply(frame, on: f.host, result: ["accepted": .bool(true)]) }
        try await wait { f.model.sessionClosings.isEmpty }
        XCTAssertEqual(f.model.displays.count, 8)
        XCTAssertEqual(f.model.opened.count, 15, "Seven retained sides, their seven writers, and the original directly opened chat")
        XCTAssertEqual(f.model.budgetDependencySessions.count, 7)
        try await f.host.shutdownAndWait()
    }

    @MainActor func testEvictedOwnerStaysDisplayFreeUntilItsRunningSideCloses() async throws {
        let f = try await fixture(), ownerID = "owner", sideID = "saved-side"
        let owner = ChatRecord(id:ownerID,workspaceID:"project",title:"Owner",profileID:"profile",costLimit:.usd(1))
        let side = ChatRecord(id:sideID,workspaceID:"project",title:"Side",path:"/fixture/side_saved-side.jsonl",profileID:"profile",parentSessionID:ownerID)
        f.model.chats += [owner,side]
        // A directly opened owner has no dependency-only marker. Closing its
        // side pane leaves the running saved side and both runtimes loaded.
        f.model.displays[ownerID] = SessionDisplay(id:ownerID)
        f.model.displays[ownerID]?.used = Date(timeIntervalSince1970:0)
        f.model.opened.formUnion([ownerID,sideID])
        _ = f.model.mountSide(side,beside:ownerID)
        f.model.displays[sideID]?.loading = false
        f.model.displays[sideID]?.runState = .running
        f.model.displays[sideID]?.used = Date(timeIntervalSince1970:1)
        for index in 0..<6 {
            let id = "other-\(index)"
            f.model.chats.append(ChatRecord(id:id,workspaceID:"project",title:id,profileID:"profile"))
            let display = SessionDisplay(id:id); display.used = Date(timeIntervalSince1970:Double(index + 2))
            f.model.displays[id] = display
        }
        var tracked: [ObjectIdentifier:WeakRefreshDisplay] = [:]
        func assertLiveDisplays(_ expected: Int, _ phase: String, file: StaticString = #filePath, line: UInt = #line) {
            for view in f.model.displays.values { tracked[ObjectIdentifier(view)] = WeakRefreshDisplay(view) }
            XCTAssertEqual(f.model.displays.count,expected,phase,file:file,line:line)
            XCTAssertEqual(tracked.values.filter { $0.value != nil }.count,expected,"Live SessionDisplays: \(phase)",file:file,line:line)
        }
        let departedOwner = WeakRefreshDisplay(try XCTUnwrap(f.model.displays[ownerID]))
        let departedSide = WeakRefreshDisplay(try XCTUnwrap(f.model.displays[sideID]))
        assertLiveDisplays(9,"before eviction")
        f.model.closeSide(sideID)
        try await wait { f.model.sides[ownerID] == nil && f.model.displays[sideID]?.loading == false }
        XCTAssertTrue(f.model.displays[sideID]?.hasWork == true)
        await f.model.select("other-5",reopensSide:false)
        try await wait { departedOwner.value == nil }
        assertLiveDisplays(8,"owner evicted while its side runs")
        XCTAssertNil(f.model.displays[ownerID])
        XCTAssertTrue(f.model.opened.contains(ownerID))
        XCTAssertTrue(f.model.releasedHelperSessions.contains(ownerID))
        XCTAssertFalse(f.model.budgetDependencySessions.contains(ownerID))
        XCTAssertTrue(f.commands.frames.isEmpty,"The dependent pins the owner; the closed pane does not unpin it")

        for (index, spend) in [0.4,0.9,1.2].enumerated() {
            // Each side settlement emits a session.changed event for its
            // authoritative owner, entering this same refresh method.
            let count = f.commands.frames.count
            f.model.refresh(ownerID)
            try await wait { f.commands.frames.count > count }
            let frame = f.commands.frames[count]
            XCTAssertEqual(frame["method"]?.string,"session.status")
            XCTAssertEqual(frame["params"]?.object,["budgetOnly":.bool(true)],"No transcript, context, task or metrics read for a released owner")
            assertLiveDisplays(8,"side settlement \(index), before reply")
            var value = snapshot(sequence:Double(index + 1),revision:"runtime:\(index + 1)")
            value["cost"] = .object(["spentUSD":.number(spend),"limitUSD":.number(1),"reportedRequests":.number(Double(index + 1))])
            try reply(frame,on:f.host,result:value)
            try await wait {
                f.model.costReading(for:sideID).budgetSpentUSD == spend &&
                    f.model.budgetStates[ownerID]?.readTask == nil && f.model.displays[ownerID]?.snapshotInFlight != true
            }
            XCTAssertEqual(f.model.budgetStates[ownerID]?.reading.spentUSD,spend)
            XCTAssertEqual(f.model.displays[sideID]?.footer.cost.budgetSpentUSD,spend)
            XCTAssertNil(f.model.displays[ownerID])
            assertLiveDisplays(8,"side settlement \(index), after reply")
        }
        XCTAssertTrue(f.model.displays[sideID]?.costLimitHeld == true)

        // The side finishes and another selection evicts its now-idle display.
        // Its acknowledged close must release the owner, deepest member first.
        f.model.displays[sideID]?.runState = .idle
        f.model.chats.append(ChatRecord(id:"next",workspaceID:"project",title:"Next",profileID:"profile"))
        await f.model.select("next",reopensSide:false)
        try await wait { departedSide.value == nil && f.commands.frames.contains { $0["method"]?.string == "session.close" && $0["sessionId"]?.string == sideID } }
        let closeSide = try XCTUnwrap(f.commands.frames.first { $0["method"]?.string == "session.close" && $0["sessionId"]?.string == sideID })
        XCTAssertFalse(f.commands.frames.contains { $0["method"]?.string == "session.close" && $0["sessionId"]?.string == ownerID })
        assertLiveDisplays(8,"side display evicted")
        try reply(closeSide,on:f.host,result:["accepted":.bool(true)])
        try await wait { f.commands.frames.contains { $0["method"]?.string == "session.close" && $0["sessionId"]?.string == ownerID } }
        let closeOwner = try XCTUnwrap(f.commands.frames.first { $0["method"]?.string == "session.close" && $0["sessionId"]?.string == ownerID })
        // A late accounting notification during the owner's close still must
        // not rebuild it, and its reply cannot outlive that runtime.
        let count = f.commands.frames.count
        f.model.refresh(ownerID)
        try await wait { f.commands.frames.count > count }
        let late = f.commands.frames[count]
        XCTAssertEqual(late["params"]?.object,["budgetOnly":.bool(true)])
        assertLiveDisplays(8,"owner close in flight")
        try reply(closeOwner,on:f.host,result:["accepted":.bool(true)])
        try await wait { !f.model.opened.contains(ownerID) && f.model.sessionClosings.isEmpty }
        try reply(late,on:f.host,result:["cost":.object(["spentUSD":.number(99)])])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(f.model.budgetStates[ownerID]?.reading.spentUSD,1.2)
        XCTAssertFalse(f.model.opened.contains(sideID))
        XCTAssertFalse(f.model.releasedHelperSessions.contains(ownerID))
        XCTAssertNil(f.model.displays[ownerID]); XCTAssertNil(f.model.displays[sideID])
        assertLiveDisplays(8,"both runtimes closed")
        try await f.host.shutdownAndWait()
    }

    /// ⌘. on a chat with nothing running has nothing to stop. It used to show
    /// "Stopping" and ask the helper anyway, which left the chat "Paused".
    @MainActor func testStopOnAnIdleChatAsksNothingAndLeavesItIdle() async throws {
        let f = try await fixture()
        XCTAssertFalse(f.view.hasWork)
        f.model.stop(sessionID: f.chat.id)
        XCTAssertEqual(f.view.state, "idle")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(f.commands.frames.contains { $0["method"]?.string == "turn.stop" }, "Nothing is sent for an idle chat")
        XCTAssertEqual(f.view.state, "idle")
        try await f.host.shutdownAndWait()
    }

    /// A running chat's snapshots carry the task presentation, up to 64
    /// finished tasks with details of up to 8 KB each, and nearly all of it is
    /// unchanged from one token to the next. It used to go through a JSON
    /// encode and decode on the main actor for every snapshot.
    @MainActor func testTaskPresentationIsDecodedOnlyWhenItChanges() async throws {
        let f = try await fixture()
        f.view.historyState = .ready
        f.view.presentation.identity = ("runtime", "root")
        let detail = String(repeating: "A long tool result line that the task list keeps. ", count: 150)
        let recent: [WireValue] = (0..<64).map { index in
            .object(["rootID": .string("root-\(index)"), "executionID": .string("execution-\(index)"),
                     "startedAt": .number(Double(index) * 1_000), "endedAt": .number(Double(index) * 1_000 + 500),
                     "outcome": .string("completed"), "phase": .string("terminal"), "anchorSourceID": .string("root-\(index)"),
                     "issuedCalls": .number(1), "preparingCalls": .number(0), "replies": .number(1),
                     "modelMs": .number(300), "toolMs": .number(200), "detail": .string(detail)])
        }
        func presented(_ sequence: Double, answer: String) -> [String: WireValue] {
            var value = streamed(sequence: sequence, answer: answer)
            value["taskPresentation"] = .object(["version": .number(1), "sessionID": .string(f.chat.id), "epoch": .string("epoch"),
                "timeline": .string("root"), "sequence": .number(sequence), "sourceRevision": .string("runtime:\(Int(sequence))"),
                "recent": .array(recent)])
            value["monitoring"] = .object(["epoch": .string("epoch")])
            return value
        }
        // What the main actor used to pay for each of these snapshots.
        let sample = try XCTUnwrap(presented(2, answer: "x")["taskPresentation"])
        var started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<10 { _ = try JSONDecoder().decode(TaskPresentationProjection.self, from: JSONEncoder().encode(sample)) }
        let roundTrip = (ProcessInfo.processInfo.systemUptime - started) * 100
        var answer = "A"
        started = ProcessInfo.processInfo.systemUptime
        for index in 0..<50 {
            answer += " token\(index)"
            try await exchange(f, presented(Double(2 + index), answer: answer))
        }
        let loop = (ProcessInfo.processInfo.systemUptime - started) * 1_000 / 50
        print(String(format: "PERF task presentation JSON round trip per snapshot (64 records): %.2f ms; snapshot loop per snapshot: %.2f ms; full decodes: %d of 50",
                     roundTrip, loop, f.view.taskPresentationDecodes))
        XCTAssertEqual(f.view.taskPresentation?.recent.count, 64, "The presentation is still applied")
        XCTAssertEqual(f.view.taskPresentation?.sequence, 51)
        XCTAssertEqual(f.view.taskPresentationDecodes, 1, "Unchanged finished tasks are decoded once, not once per token")
        try await f.host.shutdownAndWait()
    }

    /// Every snapshot used to read the chat's pending submissions from SQLite
    /// twice, and scan every chat for its path, before the next one could be
    /// asked for. While nothing about them can have changed, neither is needed.
    @MainActor func testStreamedSnapshotsReadPendingSubmissionsOnlyWhenTheyCanChange() async throws {
        let f = try await fixture()
        f.view.historyState = .ready
        f.view.presentation.identity = ("runtime", "root")
        let intent = CommandIntent(id: "command", sessionID: f.chat.id, turnID: "turn", text: "Question", state: "acknowledged", epoch: nil)
        try await f.model.store?.put(intent, kind: "pending:\(f.chat.id)", id: intent.id)
        var answer = "A"
        func receipted(_ sequence: Double, state: String) -> [String: WireValue] {
            var value = streamed(sequence: sequence, answer: answer)
            value["commands"] = .array([.object(["commandId": .string("command"), "turnId": .string("turn"), "state": .string(state)])])
            return value
        }
        try await exchange(f, receipted(2, state: "dispatched"))
        XCTAssertTrue(f.view.recovered.isEmpty, "An accepted submission is pending, but must never be offered as unsent input")
        let before = f.view.intentReads
        let started = ProcessInfo.processInfo.systemUptime
        for index in 0..<20 {
            answer += " token\(index)"
            try await exchange(f, receipted(Double(3 + index), state: "dispatched"))
        }
        let perSnapshot = (ProcessInfo.processInfo.systemUptime - started) * 1_000 / 20
        let streamingReads = f.view.intentReads - before
        print(String(format: "PERF pending-submission store reads for 20 streamed snapshots: %d; snapshot loop per snapshot: %.2f ms", streamingReads, perSnapshot))
        XCTAssertEqual(streamingReads, 0, "Nothing about the pending submission changed while the reply streamed")
        // The run completes: its receipt moves the submission out of pending.
        try await exchange(f, receipted(30, state: "completed"))
        XCTAssertTrue(f.view.recovered.isEmpty, "A completed submission leaves the recovered list")
        let left = try await f.model.store?.list(CommandIntent.self, kind: "pending:\(f.chat.id)")
        XCTAssertEqual(left?.count, 0)
        let receipt = try await f.model.store?.get(CommandIntent.self, kind: "receipt:\(f.chat.id)", id: "command")
        XCTAssertEqual(receipt?.state, "completed")
        // A new submission written by the app is read on the next snapshot.
        let next = CommandIntent(id: "second", sessionID: f.chat.id, turnID: "turn-2", text: "Next", state: "intent", epoch: nil)
        try await f.model.store?.put(next, kind: "pending:\(f.chat.id)", id: next.id)
        f.model.pendingIntentsChanged(f.chat.id)
        try await exchange(f, receipted(31, state: "completed"))
        XCTAssertEqual(f.view.recovered.map(\.id), ["second"])
        try await f.host.shutdownAndWait()
    }
}

extension WorkspaceRefreshLifecycleTests {
    /// An idle project's helper is stopped after the grace period. That is a
    /// deliberate stop, not a crash: an unsent side needs no helper, and the
    /// figures the chat's footer shows are still true. The stop used to run
    /// the crash path, which closed the side, moved its text into the parent
    /// composer with "The host stopped…" and blanked the context meter.
    @MainActor func testStoppingAnIdleHelperKeepsAnUnsentSideAndTheContextMeter() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("idle-stop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = WorkspaceRecord(id: "idle-project", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "idle-profile"; profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "fixture"
        let vault = ConfigurationVault(storage: MemoryVaultStorage()), saved = profile
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [project]; $0.profiles = [.init(profile: saved, apiKey: "synthetic-idle-key")]
            $0.resources[project.id] = .object(["codexHome": .string(root.appendingPathComponent("codex").path), "skills": .bool(false)])
        }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "idle-chat", workspaceID: project.id, title: "Idle chat", path: nil, profileID: profile.id)
        try await model.store?.put(chat, kind: "chat", id: chat.id); model.chats = [chat]
        let view = SessionDisplay(id: chat.id); view.historyState = .ready; view.draft = "Parent draft"
        model.displays[chat.id] = view; model.selectedID = chat.id; model.selected = view; model.focusedSessionID = chat.id
        // The production start, over a helper whose commands this test answers.
        let commands = RefreshCommandLog()
        let host = HostSupervisor(commandSender: { commands.frames.append($0) })
        model.hosts[project.id] = host
        @MainActor func settle(_ condition: () -> Bool) async throws {
            // A helper process starts and stops here, which takes longer than a reply.
            for _ in 0..<1_000 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(condition(), "The helper did not reach the expected state")
        }
        let started = Task { try await model.host(for: project) }
        try await settle { commands.frames.contains { $0["method"]?.string == "workspace.open" } }
        try reply(try XCTUnwrap(commands.frames.first { $0["method"]?.string == "workspace.open" }), on: host, result: [:])
        _ = try await started.value
        model.opened.insert(chat.id)
        // The footer's figures, as the last snapshot left them.
        let state: [String: WireValue] = ["version": .number(1), "sessionID": .string(chat.id), "epoch": .string("e"), "revision": .number(3), "generation": .number(1)]
        view.footer.contextState = state; view.footer.context = ["tokens": .number(48_000)]
        // A side the reader opened and is typing into, not sent yet.
        model.openSide(parentID: chat.id)
        let side = try XCTUnwrap(model.sides[chat.id]); XCTAssertTrue(side.pending)
        model.displays[side.id]?.draft = "A side question I am still writing"
        model.configuration.runtime.idleGraceSeconds = 0
        model.updateHostActivity(workspaceID: project.id)
        XCTAssertFalse(host.isBusy, "An unsent side does not keep the helper")
        model.scheduleIdle(workspaceID: project.id, host: host)
        try await settle { !host.isReady && host.connectionID == nil }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.sides[chat.id]?.id, side.id, "The side is still open")
        XCTAssertEqual(model.sides[chat.id]?.pending, true)
        XCTAssertEqual(model.displays[side.id]?.draft, "A side question I am still writing")
        XCTAssertEqual(view.draft, "Parent draft", "Nothing was moved into the parent composer")
        XCTAssertEqual(view.notice, "", "A deliberate stop is not reported as a lost host")
        XCTAssertEqual(view.footer.contextState, state, "The context meter keeps its figures")
        XCTAssertEqual(view.footer.context["tokens"]?.number, 48_000)
        XCTAssertFalse(model.opened.contains(chat.id), "The chat reopens on its next use")
    }
}

extension WorkspaceRefreshLifecycleTests {
    @MainActor func testAcceptedReceiptHidesRecoveryEvenWhenItsLocalWriteFails() async throws {
        let f = try await fixture()
        f.view.historyState = .ready; f.view.presentation.identity = ("runtime", "root")
        let intent = CommandIntent(id: "command", sessionID: f.chat.id, turnID: "turn", text: "Already received", state: "intent")
        try await f.model.store?.put(intent, kind: "pending:\(f.chat.id)", id: intent.id)
        f.view.recovered = [intent]; f.view.uncertain = true
        try RecoveredDraftTests.sql("CREATE TRIGGER refuse_receipt BEFORE INSERT ON records WHEN NEW.kind='receipt:chat' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", root: f.model.root)
        var snapshot = streamed(sequence: 2, answer: "Answer")
        snapshot["commands"] = .array([.object(["commandId": .string(intent.id), "turnId": .string(intent.turnID), "state": .string("completed")])])
        try await exchange(f, snapshot)
        XCTAssertTrue(f.view.recovered.isEmpty, "The helper's evidence takes effect before local bookkeeping")
        f.model.recoverDraft(intent, insert: true)
        await f.model.draftWrites.recoveries[f.chat.id]?.value
        XCTAssertEqual(f.view.draft, "", "An old banner action cannot offer the command again")
        let pending = try await f.model.store?.get(CommandIntent.self, kind: "pending:\(f.chat.id)", id: intent.id)
        XCTAssertNotNil(pending, "The injected persistence failure actually left the intent on disk")
        try await f.host.shutdownAndWait()
    }
    @MainActor func testSnapshotCannotRetireIntentUntilReturnedDraftReviewIsSaved() async throws {
        let f = try await fixture(), store = try XCTUnwrap(f.model.store)
        f.view.historyState = .ready; f.view.presentation.identity = ("runtime", "root"); f.view.selectionMetadataLoaded = true
        let intent = CommandIntent(id: "command", sessionID: f.chat.id, turnID: "turn", text: "Returned", state: "intent")
        f.view.draft = "Returned\n\nNew typing"; f.view.recovered = [intent]; f.view.uncertain = true
        try await store.recordSubmission(intent, draft: f.view.savedDraft, draftVersion: f.view.draftVersion)
        try RecoveredDraftTests.sql("CREATE TRIGGER refuse_review BEFORE UPDATE ON records WHEN OLD.kind='draft' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", root: f.model.root)
        var snapshot = streamed(sequence: 2, answer: "Answer")
        snapshot["commands"] = .array([.object(["commandId": .string(intent.id), "turnId": .string(intent.turnID), "state": .string("completed")])])
        try await exchange(f, snapshot)
        let retained = try await store.get(CommandIntent.self, kind: "pending:chat", id: intent.id)
        XCTAssertNotNil(retained); XCTAssertEqual(f.view.submissionReviews, [intent.id])
        XCTAssertFalse(f.view.reconciledSubmissionReviews.contains(intent.id))
        try RecoveredDraftTests.sql("DROP TRIGGER refuse_review", root: f.model.root)
        snapshot["seq"] = .number(3); try await exchange(f, snapshot)
        let removed = try await store.get(CommandIntent.self, kind: "pending:chat", id: intent.id)
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: f.chat.id)
        XCTAssertNil(removed); XCTAssertEqual(saved?.submissionReviews, [intent.id]); XCTAssertEqual(saved?.text, "Returned\n\nNew typing")
        XCTAssertTrue(f.view.recovered.isEmpty); XCTAssertFalse(f.view.uncertain)
        var asked = 0; f.model.questions.answer = { _ in asked += 1; return false }
        f.model.send(sessionID: f.chat.id); XCTAssertEqual(asked, 1)
        try await f.host.shutdownAndWait()
    }
}

extension WorkspaceRefreshLifecycleTests {
    /// Sixty calls, each with its result, followed by the answer: the live
    /// snapshot can first reach a new chat/branch after its question left
    /// the helper's sixty-row suffix. No scroll or reader load occurs here.
    @MainActor private func longLiveTurn(branch: Bool = false, early: Bool = false, newer: Bool = false, cap: Int? = nil) async throws {
        let f = try await fixture(), oldMode = TranscriptDisplay.mode
        let caps = TranscriptPaging.residentCaps
        if let cap { TranscriptPaging.residentCaps = (rows: cap, bytes: caps.bytes) }
        defer { TranscriptPaging.residentCaps = caps }
        TranscriptDisplay.use(.compact)
        defer { TranscriptDisplay.use(oldMode) }
        f.view.historyState = .ready
        f.view.presentation.identity = ("runtime", "root")
        if branch { f.view.pendingBranch = .init(from: "root", messageID: "question", turnID: "u0") }
        else { f.view.messages = [] }
        let lineage = branch ? "edited" : "root"
        func row(_ id: String, _ role: String, _ text: String, tools: [WireValue] = []) -> WireValue {
            .object(["id": .string(id), "role": .string(role), "text": .string(text), "turn": .string("u0"),
                     "taskRootID": .string("u0"), "tools": .array(tools)])
        }
        var all = [row("u0", "user", "Find every caller")]
        for index in 0..<60 {
            let tool: WireValue = .object(["id": .string("c\(index)"), "name": .string("read"), "state": .string("completed"),
                                          "input": .string("README.md"), "output": .string("Fixture contents"), "truncated": .bool(false)])
            all.append(row("a\(index)", "assistant", "", tools: [tool]))
            all.append(row("r\(index)", "toolResult", "Fixture contents"))
        }
        all.append(row("answer", "assistant", "The callers are fixed."))
        @Sendable func cursor(_ id: String) -> WireValue { .object(["incarnation": .string("runtime"), "lineage": .string(lineage), "entry": .string(id)]) }
        let source = all, gate = HistoryReadGate()
        await gate.release()
        f.model.historyWindowLoader = { _, boundary, forward, around in
            _ = await gate.readFirstOnly()
            let start = boundary.flatMap { edge in source.firstIndex { $0.object?["id"]?.string == edge.entry } }
            let page = start.map { Array(source[..<$0]) } ?? source
            return try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("runtime"), "lineage": .string(lineage),
                "messages": .array(page), "older": .null, "newer": start.map { _ in cursor(page.last!.object!["id"]!.string!) } ?? .null,
                "start": .number(0), "total": .number(Double(source.count))]))
        }
        func value(_ sequence: Double, _ rows: [WireValue], running: Bool) -> [String: WireValue] {
            var result = liveSnapshot(sequence, .array(rows))
            result["historyLineage"] = .string(lineage)
            result["historyOlder"] = rows.first?.object?["id"]?.string == "u0" ? .null : cursor(rows.first!.object!["id"]!.string!)
            result["state"] = .string(running ? "running" : "idle"); result["runStatus"] = result["state"]
            return result
        }
        let page = TranscriptPage(); page.presentationInterval = 0; page.bind(f.view)
        if early {
            try await exchange(f, value(1, Array(all.prefix(21)), running: true))
            try await exchange(f, value(2, Array(all[20..<80]), running: true))
        }
        var streaming = Array(all.suffix(60))
        var answer = streaming.removeLast().object!; answer["state"] = .string("streaming"); answer["text"] = .string("The callers")
        streaming.append(.object(answer))
        try await exchange(f, value(3, streaming, running: true))
        XCTAssertFalse(page.snapshot?.items.contains { if case .block(let b) = $0 { return b.presentation == .turnFold }; return false } ?? true,
                       "A running turn keeps every row")
        let streamedIDs = f.view.messages.map(\.id)
        if !early { XCTAssertFalse(streamedIDs.contains("u0"), "Reproduce a first live snapshot starting inside the turn") }
        if newer {
            all += [.object(["id": .string("u1"), "role": .string("user"), "text": .string("Next question")]),
                    .object(["id": .string("new-answer"), "role": .string("assistant"), "text": .string("Still writing"), "state": .string("streaming"), "turn": .string("u1")])]
            f.view.scrollAnchor = .init(id: "new-answer", offset: 17, followsBottom: false)
        }
        try await exchange(f, value(4, Array(all.suffix(60)), running: newer))
        // Let an automatic whole-turn read finish, without asking for one.
        for _ in 0..<100 {
            if f.view.messages.first?.id == "u0" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let folds = (page.snapshot?.items ?? []).compactMap { item -> TranscriptBlock? in
            if case .block(let block) = item, block.presentation == .turnFold { return block }; return nil
        }
        let reads = await gate.reads
        print("TURNFOLD branch=\(branch) early=\(early) newer=\(newer): first \(f.view.messages.first?.id ?? "-"), rows \(f.view.messages.count), folds \(folds.count), reads \(reads)")
        if let cap, cap < source.count {
            XCTAssertEqual(f.view.messages.map(\.id), streamedIDs, "A turn larger than the resident window stays as decided")
            XCTAssertTrue(folds.isEmpty)
        } else if let cap, cap < all.count {
            XCTAssertEqual(f.view.messages.map(\.id), ["u1", "new-answer"], "Keep the newer turn and let the completed first turn go whole")
            XCTAssertEqual(f.view.olderPage.cursor?.entry, "u1")
            XCTAssertTrue(folds.isEmpty)
        } else {
            XCTAssertEqual(f.view.messages.first?.id, "u0", "The question is present without scrolling")
            XCTAssertEqual(folds.first?.foldSummary?.toolCalls, 60, "All sixty calls fold by default")
            XCTAssertTrue((page.snapshot?.items ?? []).contains { TranscriptRowDisclosure.of($0, in: f.view.disclosure).foldedAway })
            XCTAssertTrue(Set(streamedIDs).isSubset(of: Set(f.view.messages.map(\.id))), "The running rows stay resident")
        }
        XCTAssertFalse(f.view.browsingHistory)
        XCTAssertLessThanOrEqual(reads, early ? 0 : 2, "At most the existing extent read plus one whole-turn fill")
        f.view.disclosure.setOpen(true, .turnFold("u0"))
        try await exchange(f, value(5, Array(all.suffix(60)), running: newer))
        XCTAssertTrue(f.view.disclosure.isOpen(.turnFold("u0")), "An opened fold stays open")
        try await f.host.shutdownAndWait()
    }

    @MainActor func testNewChatLongTurnFoldsWithoutReaderLoad() async throws { try await longLiveTurn() }
    @MainActor func testEditBranchLongTurnFoldsWithoutReaderLoad() async throws { try await longLiveTurn(branch: true) }
    @MainActor func testCutFinishedTurnFoldsWhileANewerTurnRuns() async throws { try await longLiveTurn(newer: true) }
    @MainActor func testLongTurnObservedFromItsQuestionFoldsWithoutReaderLoad() async throws { try await longLiveTurn(early: true) }
    @MainActor func testFinishedTurnPastTheResidentCapStaysUnfolded() async throws { try await longLiveTurn(cap: 90) }
    @MainActor func testFinishedTurnFillKeepsTheNewerTurnWhenBothDoNotFit() async throws { try await longLiveTurn(newer: true, cap: 123) }
}
