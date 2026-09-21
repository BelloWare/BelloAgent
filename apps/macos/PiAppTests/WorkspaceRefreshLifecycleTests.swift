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
