import XCTest
@testable import PiApp

@MainActor private final class RefreshCommandLog {
    var frames: [[String: WireValue]] = []
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
        view.projectionRevision="old-runtime:1"; view.pageStartEnsured=true
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

    @MainActor private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(for:.milliseconds(1))
        }
        XCTFail("Refresh did not reach the expected state",file:file,line:line)
        throw HostError.failure("Timed out waiting for refresh")
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
        XCTAssertEqual(f.view.messages.first?.id, "m0")
        XCTAssertEqual(f.view.messages.count, HistoryWindowPolicy.residentRows)
        XCTAssertEqual(f.view.scrollAnchor?.offset, -8)
        XCTAssertEqual(f.view.newerPage.cursor?.entry, f.view.messages.last?.id)
        XCTAssertTrue(f.view.browsingHistory, "Only an actual evicted tail gap disconnects the live window")
        try await f.host.shutdownAndWait()
    }

    @MainActor func testRealHelperUpdatesReopenedAndEarlierWindowsWithoutSwitchingTabs() async throws {
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
            var finished = false
            for _ in 0..<500 {
                let state = try await host.request("session.status", sessionID: chat.id).object ?? [:]
                if state["state"]?.string == "idle" { finished = true; break }
                if state["state"]?.string == "error" {
                    throw HostError.failure("Fixture seed \(index) failed: " + (state["preflightError"]?.string ?? "missing error"))
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(finished)
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
        let pane = TranscriptFrameBudgetTests.Pane(view, height: 1600, onReady: { _, generation in
            guard generation == view.presentationGeneration else { return }
            view.historyState = .ready; view.presentation.readyAt = PerformanceProbe.now
        }, onEarlier: { model.loadEarlier(sessionID: $0) })
        defer { pane.close() }
        await pane.settle(turns: 30)
        if view.messages.filter({ $0.role == "user" }).count == 3 {
            let loaded = await model.loadEarlierPage(sessionID: chat.id); XCTAssertTrue(loaded)
        }
        XCTAssertFalse(view.browsingHistory)

        for (index, text) in ["Continue the reopened chat", "Continue from the earlier window"].enumerated() {
            if index == 1 {
                let earlierID = try XCTUnwrap(view.messages.first(where: { $0.role == "user" })?.id)
                model.reloadHistory(chat.id, around: earlierID); await view.presentation.navigation?.value
                await pane.settle(turns: 15)
                XCTAssertNotNil(view.newerPage.cursor); XCTAssertTrue(view.browsingHistory)
                // The second continuation uses fragmented Responses SSE,
                // while the cold reopen above exercises a fast JSON reply.
                model.chats[0].model = "route-late"
            }
            let before = Set(view.messages.map(\.id))
            view.draft = text; model.send(sessionID: chat.id)
            try await wait {
                !view.loading && !view.busy && view.messages.contains { $0.role == "user" && $0.text == text } &&
                    view.messages.contains { $0.role == "assistant" && !before.contains($0.id) }
            }
            await pane.settle(turns: 20)
            XCTAssertNil(view.sendFailure); XCTAssertNil(view.failureMessage)
            XCTAssertEqual(model.selectedID, chat.id); XCTAssertTrue(model.selected === view)
            XCTAssertFalse(view.browsingHistory); XCTAssertNil(view.newerPage.cursor)
            XCTAssertTrue(pane.page?.snapshot?.messages.contains { $0.role == "user" && $0.text == text } == true,
                          "The mounted native transcript must show the new input without being recreated")
            XCTAssertTrue(pane.page?.snapshot?.messages.contains { $0.role == "assistant" && !before.contains($0.id) && $0.text.contains("Hello") } == true)
            XCTAssertEqual(view.messages.last?.isStreaming, false)
        }
    }
}

/// Suspends a history read until the test lets it go, and counts the reads.
private actor HistoryReadGate {
    private(set) var reads = 0
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
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
        XCTAssertEqual(f.model.opened, Set([f.chat.id] + (1...8).filter { $0 != 2 }.map { "other-\($0)" }))
        let reopened = RefreshCommandLog(), other = try XCTUnwrap(f.model.record("other-0"))
        let reopen = Task { @MainActor in _ = try? await f.model.open(other); reopened.frames.append([:]) }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(reopened.frames.isEmpty, "The open waits for the close in flight")
        XCTAssertFalse(f.commands.frames.contains { $0["method"]?.string == "session.open" })
        try reply(closes[0], on: f.host, result: ["accepted": .bool(true)])
        try await wait { !reopened.frames.isEmpty }
        await reopen.value
        XCTAssertNil(f.model.sessionClosings["other-0"])
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
        XCTAssertEqual(f.view.recovered.map(\.id), ["command"], "The submission is still pending while its run streams")
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
