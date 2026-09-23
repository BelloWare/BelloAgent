import XCTest
@testable import PiApp

final class SideTests: XCTestCase {
    @MainActor func testExactSideAndForkEnterUsePackagedHelperWithoutSendingAndClosedSideSurvivesRestart() async throws {
        let root = try scratch()
        let workspace = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "p"; profile.baseUrl = "http://127.0.0.1:9/v1"; profile.modelId = "router"
        let connection = VaultProfile(profile: profile, apiKey: "synthetic-unused-key")
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [workspace]; $0.profiles = [connection]
            $0.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)])
        }
        let state = root.appendingPathComponent("state"), model = WorkspaceModel(stateRoot: state, vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        let parent = ChatRecord(id: "parent", workspaceID: workspace.id, title: "Source", path: nil, profileID: profile.id, model: "selected-model", thinkingLevel: "high", contextWindow: 64_000, maxOutputTokens: 8_000)
        try await model.store?.put(parent, kind: "chat", id: parent.id); model.chats = [parent]
        await model.select(parent.id)
        let view = try XCTUnwrap(model.selected)
        view.draft = "/side"; view.directCommand = true; view.completionVisible = true
        view.completionToken = SlashCompletionToken.local(in: view.draft as NSString, at: ComposerLocation(sessionID: view.id, editorGeneration: UUID(), draftRevision: 1, selectedRangeUTF16: NSRange(location: 5, length: 0), markedRangeUTF16: nil), directInput: true)
        model.updateCompletionSelection(view)
        XCTAssertTrue(model.completionKey(36, view: view), "Exact /side should execute on the first Return")
        XCTAssertEqual(view.draft, "")
        // An empty side is only on screen until its first message: no helper session, no chat record.
        let pending = try XCTUnwrap(model.sides[parent.id])
        XCTAssertTrue(pending.pending); XCTAssertTrue(model.hosts.isEmpty); XCTAssertNil(model.chats.first { $0.id == pending.id })
        XCTAssertEqual(model.focusedSessionID, pending.id)
        // The first message publishes it through the packaged helper (send() does this before submitting).
        try await model.publishPendingSide(pending, view: try XCTUnwrap(model.displays[pending.id]))
        for _ in 0..<500 {
            if let side = model.sides[parent.id], side.kept, model.displays[side.id]?.loading == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let side = try XCTUnwrap(model.sides[parent.id]), saved = try XCTUnwrap(model.chats.first { $0.id == side.id })
        XCTAssertTrue(side.kept); XCTAssertEqual(saved.parentSessionID, parent.id)
        XCTAssertEqual(saved.model, parent.model); XCTAssertEqual(saved.thinkingLevel, parent.thinkingLevel)
        XCTAssertEqual(saved.contextWindow, parent.contextWindow); XCTAssertEqual(saved.maxOutputTokens, parent.maxOutputTokens)
        XCTAssertEqual(model.displays[side.id]?.captureMode, "persist")
        let host = try XCTUnwrap(model.hosts[workspace.id])
        let initial = try await host.request("session.snapshot", sessionID: side.id).object ?? [:]
        XCTAssertTrue(initial["messages"]?.array?.isEmpty == true)
        let attempts = try await host.request("debug.list", sessionID: side.id).object ?? [:]
        XCTAssertEqual(attempts["total"]?.number, 0, "Opening /side never sends a provider request")
        model.displays[side.id]?.draft = "Saved unfinished question"
        let parentFocus = view.composerFocusRequest
        model.closeSide(side.id)
        for _ in 0..<200 where model.sides[parent.id] != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.sides[parent.id]); XCTAssertNotNil(model.record(side.id))
        XCTAssertEqual(model.focusedSessionID, parent.id); XCTAssertGreaterThan(view.composerFocusRequest, parentFocus, "Closing the side puts the cursor back in the parent's composer")
        let draft = try await model.store?.get(DraftRecord.self, kind: "draft", id: side.id)
        XCTAssertEqual(draft?.text, "Saved unfinished question")

        view.draft = "/fork"; view.directCommand = true; view.completionVisible = true
        view.completionToken = SlashCompletionToken.local(in: view.draft as NSString, at: ComposerLocation(sessionID: view.id, editorGeneration: UUID(), draftRevision: 2, selectedRangeUTF16: NSRange(location: 5, length: 0), markedRangeUTF16: nil), directInput: true)
        model.updateCompletionSelection(view)
        XCTAssertTrue(model.completionKey(36, view: view), "Exact /fork should also execute on the first Return")
        for _ in 0..<500 where view.loading { try await Task.sleep(for: .milliseconds(10)) }
        let fork = try XCTUnwrap(model.chats.first { $0.id != parent.id && $0.id != side.id })
        XCTAssertNil(fork.parentSessionID); XCTAssertEqual(fork.toolMode, "editing")
        XCTAssertEqual(fork.model, parent.model); XCTAssertEqual(fork.thinkingLevel, parent.thinkingLevel)
        XCTAssertEqual(fork.contextWindow, parent.contextWindow); XCTAssertEqual(fork.maxOutputTokens, parent.maxOutputTokens)
        let forkAttempts = try await host.request("debug.list", sessionID: fork.id).object ?? [:]
        XCTAssertEqual(forkAttempts["total"]?.number, 0)
        model.shutdown(); try await host.shutdownAndWait(); try await model.traces.close(); await model.store?.close()

        let restored = WorkspaceModel(stateRoot: state, vault: vault)
        registerWorkspaceFixtureTeardown(restored, root: root)
        await restored.restore()
        XCTAssertEqual(restored.chats.first { $0.id == side.id }?.parentSessionID, parent.id)
        XCTAssertNotNil(restored.chats.first { $0.id == fork.id && $0.parentSessionID == nil })
        await restored.select(side.id); XCTAssertEqual(restored.selected?.draft, "Saved unfinished question")
        XCTAssertTrue(restored.hosts.isEmpty, "Reading a saved child after restart does not open a gateway")
    }
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("native-side-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    @MainActor func testEphemeralDraftsAndAnchorsNeverEnterSQLiteAndBringBackDoesNotSubmit() async throws {
        let root = try scratch()
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage())), parent = SessionDisplay(id: "main"), side = SessionDisplay(id: "side")
        registerWorkspaceFixtureTeardown(model, root: root)
        parent.draft = "original draft"; parent.state = "running"; side.draft = "ephemeral secret"
        model.displays = ["main": parent, "side": side]
        model.sides["main"] = SideRecord(id: "side", parentID: "main", workspaceID: "w", profileID: "p", title: "side")
        model.draftChanged(side); model.anchorChanged(side)
        try await Task.sleep(for: .milliseconds(200))
        let draft = try await model.store?.get(DraftRecord.self, kind: "draft", id: "side")
        XCTAssertNil(draft); XCTAssertTrue(model.hasActiveWork)
        try model.bringBack("edited summary", from: "side", replace: false)
        XCTAssertEqual(parent.draft, "original draft\n\nedited summary"); XCTAssertEqual(parent.state, "running"); XCTAssertFalse(parent.directCommand)
        try model.bringBack("replacement", from: "side", replace: true); XCTAssertEqual(parent.draft, "replacement")
        XCTAssertTrue(model.hosts.isEmpty)
        let intents = try await model.store?.list(CommandIntent.self, kind: "pending:main")
        XCTAssertEqual(intents?.count, 0)
        XCTAssertThrowsError(try model.bringBack(String(repeating: "x", count: 262_145), from: "side", replace: true))
    }
    @MainActor func testLostKeepAcknowledgementRecoversFileWithoutStartingAHostAndRetainsReadOnlyMode() async throws {
        let root = try scratch()
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let path = root.appendingPathComponent("Workspaces/w/Sessions/side_side.jsonl")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("{\"type\":\"session\",\"version\":3,\"id\":\"side\"}\n{\"type\":\"message\",\"id\":\"a\",\"parentId\":null,\"message\":{\"role\":\"user\",\"content\":\"retained 🌍\"}}\n".utf8)
        try bytes.write(to: path)
        let chat = ChatRecord(id: "side", workspaceID: "w", title: "Kept side", path: path.path, profileID: "p", toolMode: "read-only")
        try await model.store?.put(SideKeepIntent(chat: chat), kind: "side-keep", id: "side")
        await model.reconcileSideKeeps()
        XCTAssertEqual(model.chats.first?.toolMode, "read-only"); XCTAssertEqual(model.chats.first?.path, path.path)
        XCTAssertTrue(model.hosts.isEmpty); XCTAssertEqual(try Data(contentsOf: path), bytes)
        let intent = try await model.store?.get(SideKeepIntent.self, kind: "side-keep", id: "side")
        XCTAssertNil(intent)
        await model.reconcileSideKeeps(); XCTAssertEqual(model.chats.count, 1)
    }
    @MainActor func testFailedKeepValidationPreservesRecoveryIntentAndHostLossDiscardsOnlyUnkeptMemory() async throws {
        let root = try scratch()
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage())), path = root.appendingPathComponent("side.jsonl")
        registerWorkspaceFixtureTeardown(model, root: root)
        try Data("{\"type\":\"session\",\"version\":3,\"id\":\"wrong\"}\n".utf8).write(to: path)
        let chat = ChatRecord(id: "side", workspaceID: "w", title: "side", path: path.path, profileID: "p", toolMode: "read-only")
        try await model.store?.put(SideKeepIntent(chat: chat), kind: "side-keep", id: "side")
        await model.reconcileSideKeeps(); XCTAssertNotNil(model.error); XCTAssertTrue(model.chats.isEmpty)
        let intent = try await model.store?.get(SideKeepIntent.self, kind: "side-keep", id: "side"); XCTAssertNotNil(intent)
        model.sides["parent"] = SideRecord(id: "ephemeral", parentID: "parent", workspaceID: "w", profileID: "p", title: "side")
        model.displays["parent"] = SessionDisplay(id: "parent"); model.displays["ephemeral"] = SessionDisplay(id: "ephemeral")
        model.discardLostSides(workspaceID: "w"); XCTAssertTrue(model.sides.isEmpty); XCTAssertNil(model.displays["ephemeral"]); XCTAssertNotNil(model.displays["parent"])
    }

    // MARK: A draft side's first message, against a helper this test answers

    @MainActor private final class FrameLog { var frames: [[String: WireValue]] = [] }
    @MainActor private final class ScriptedSide {
        let root: URL
        let model: WorkspaceModel
        let parent: ChatRecord
        let parentView: SessionDisplay
        let host: HostSupervisor
        let log: FrameLog
        var frames: [[String: WireValue]] { log.frames }
        init(root: URL, model: WorkspaceModel, parent: ChatRecord, parentView: SessionDisplay, host: HostSupervisor, log: FrameLog) {
            self.root = root; self.model = model; self.parent = parent; self.parentView = parentView; self.host = host; self.log = log
        }
        func frame(_ method: String) -> [String: WireValue]? { frames.first { $0["method"]?.string == method } }
        func count(_ method: String) -> Int { frames.filter { $0["method"]?.string == method }.count }
        func reply(_ frame: [String: WireValue], result: [String: WireValue], ok: Bool = true) throws {
            let connection = try XCTUnwrap(host.connectionID), epoch = try XCTUnwrap(host.epoch)
            host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(epoch),
                "commandId": try XCTUnwrap(frame["commandId"]), "ok": .bool(ok), "result": .object(result)]), connectionID: connection)
        }
        func until(_ what: String, _ condition: () -> Bool) async throws {
            for _ in 0..<1_000 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(condition(), what)
            if !condition() { throw HostError.failure(what) }
        }
    }

    /// A parent chat that is open on a helper whose commands the test answers.
    @MainActor private func scriptedSide() async throws -> ScriptedSide {
        let root = try scratch()
        let workspace = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "p"; profile.baseUrl = "http://127.0.0.1:9/v1"; profile.modelId = "router"
        let vault = ConfigurationVault(storage: MemoryVaultStorage()), saved = profile
        _ = try await vault.update(expectedRevision: 0) { $0.workspaces = [workspace]; $0.profiles = [.init(profile: saved, apiKey: "synthetic-unused-key")] }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        let parent = ChatRecord(id: "parent", workspaceID: workspace.id, title: "Parent", path: nil, profileID: profile.id)
        try await model.store?.put(parent, kind: "chat", id: parent.id); model.chats = [parent]
        let view = SessionDisplay(id: parent.id); view.historyState = .ready; view.selectionMetadataLoaded = true
        model.displays[parent.id] = view; model.selectedID = parent.id; model.selected = view; model.focusedSessionID = parent.id
        let log = FrameLog()
        let host = HostSupervisor(commandSender: { log.frames.append($0) })
        try await host.connect(cwd: root, state: root.appendingPathComponent("host"))
        model.hosts[workspace.id] = host; model.opened.insert(parent.id)
        let scripted = ScriptedSide(root: root, model: model, parent: parent, parentView: view, host: host, log: log)
        addTeardownBlock { @MainActor in try? await host.shutdownAndWait() }
        return scripted
    }

    /// The first message of a draft side creates it on the helper. When the
    /// helper refuses, nothing was created and the side is still a draft: it
    /// can be sent again or closed. It used to be left half-open, neither a
    /// draft nor a saved side, which nothing could close, keep or replace,
    /// and which refused quitting and every update while it existed.
    @MainActor func testAFailedFirstMessageLeavesTheSideADraftThatCanBeClosed() async throws {
        let f = try await scriptedSide()
        f.model.openSide(parentID: f.parent.id)
        let info = try XCTUnwrap(f.model.sides[f.parent.id]); XCTAssertTrue(info.pending)
        let side = try XCTUnwrap(f.model.displays[info.id])
        side.draft = "A question for the side"
        f.model.send(sessionID: info.id)
        try await f.until("side.open was never sent") { f.frame("side.open") != nil }
        try f.reply(try XCTUnwrap(f.frame("side.open")), result: ["code": .string("parent_busy"), "message": .string("The parent is busy")], ok: false)
        try await f.until("the send never finished") { !side.loading }
        let after = try XCTUnwrap(f.model.sides[f.parent.id])
        XCTAssertTrue(after.pending, "Nothing was created: the side is still a draft")
        XCTAssertFalse(f.model.hasActiveWork, "A draft side never blocks quitting or updating")
        XCTAssertFalse(f.host.isBusy, "Nor does it keep the helper from going idle")
        XCTAssertEqual(side.draft, "A question for the side", "What was typed is still there")
        let stored = try await f.model.store?.get(DraftRecord.self, kind: "draft", id: info.id)
        let intent = try await f.model.store?.get(SideKeepIntent.self, kind: "side-keep", id: info.id)
        XCTAssertNil(stored, "A draft side's text is not left in the store"); XCTAssertNil(intent, "Nor a recovery intent for a side that was never created")
        f.model.closeSide(info.id)
        XCTAssertNil(f.model.sides[f.parent.id], "It closes")
        XCTAssertEqual(f.parentView.draft, "A question for the side", "Its text goes back to the parent, as for any draft side")
    }

    /// The side's first message is one submission. Creating the side used to
    /// clear the busy flag the send had set while the message itself was
    /// still on its way, so Send worked again and submitted it twice.
    @MainActor func testADraftSideFirstMessageIsSubmittedOnce() async throws {
        let f = try await scriptedSide()
        f.model.openSide(parentID: f.parent.id)
        let info = try XCTUnwrap(f.model.sides[f.parent.id])
        let side = try XCTUnwrap(f.model.displays[info.id])
        side.draft = "A question for the side"
        // The journal the helper writes for the side.
        let path = f.model.root.appendingPathComponent("Workspaces/project/Sessions/side_\(info.id).jsonl")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"type\":\"session\",\"version\":3,\"id\":\"\(info.id)\"}\n".utf8).write(to: path)
        f.model.send(sessionID: info.id)
        var loadingWhenSubmitted: Bool?
        var answered = 0
        for _ in 0..<2_000 {
            while answered < f.frames.count {
                let frame = f.frames[answered]; answered += 1
                switch frame["method"]?.string {
                case "side.open": try f.reply(frame, result: ["sessionId": .string(info.id), "path": .string(path.path), "side": .object(["parentSessionId": .string(f.parent.id)])])
                case "debug.mode", "session.status": try f.reply(frame, result: [:])
                case "turn.submit":
                    loadingWhenSubmitted = side.loading
                    // The reader presses Send again while the first message is on its way.
                    f.model.send(sessionID: info.id)
                default: break
                }
            }
            if loadingWhenSubmitted != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(loadingWhenSubmitted, true, "The side is still sending its first message")
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(f.count("turn.submit"), 1, "The first message is submitted once")
    }

    /// The "Interrupted submissions" banner in a side acts on the side: its
    /// Insert puts the text in the side's composer and its Dismiss removes the
    /// side's record. Both used to act on the main chat.
    @MainActor func testASidesInterruptedSubmissionIsRecoveredIntoTheSide() async throws {
        let root = try scratch()
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let parent = SessionDisplay(id: "parent"), side = SessionDisplay(id: "side")
        parent.draft = "Parent draft"
        model.chats = [ChatRecord(id: "parent", workspaceID: "w", title: "Parent", path: nil, profileID: "p"),
                       ChatRecord(id: "side", workspaceID: "w", title: "Side", path: nil, profileID: "p", toolMode: "read-only", parentSessionID: "parent")]
        model.displays = ["parent": parent, "side": side]; model.selectedID = "parent"; model.selected = parent
        model.sides["parent"] = SideRecord(id: "side", parentID: "parent", workspaceID: "w", profileID: "p", title: "Side", kept: true)
        let parentIntent = CommandIntent(id: "parent-command", sessionID: "parent", turnID: "t0", text: "Parent question", state: "intent", epoch: nil)
        let intent = CommandIntent(id: "side-command", sessionID: "side", turnID: "t1", text: "Interrupted side question", state: "intent", epoch: nil)
        try await model.store?.put(parentIntent, kind: "pending:parent", id: parentIntent.id)
        try await model.store?.put(intent, kind: "pending:side", id: intent.id)
        parent.recovered = [parentIntent]; parent.uncertain = true
        side.recovered = [intent]; side.uncertain = true
        model.recoverDraft(intent, insert: true)
        XCTAssertEqual(side.draft, "Interrupted side question", "The text goes into the side's composer")
        XCTAssertEqual(parent.draft, "Parent draft", "The parent's draft is untouched")
        for _ in 0..<200 where !side.recovered.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(side.recovered.isEmpty); XCTAssertFalse(side.uncertain)
        XCTAssertEqual(parent.recovered.map(\.id), ["parent-command"], "The parent's own interrupted submission stays")
        let left = try await model.store?.list(CommandIntent.self, kind: "pending:side")
        XCTAssertEqual(left?.count, 0, "The side's record is the one removed")
        let parentLeft = try await model.store?.list(CommandIntent.self, kind: "pending:parent")
        XCTAssertEqual(parentLeft?.count, 1)
    }
}

extension SideTests {
    /// A question typed into a side that was never sent went with the app at
    /// quit: side drafts are never saved under the side (the policy), and the
    /// only rescue, moving the text into the parent, ran on host loss alone.
    @MainActor func testQuitMovesAnUnsentSideDraftIntoItsParentAndWritesNothingForTheSide() async throws {
        let root = try scratch()
        func makeModel() async throws -> WorkspaceModel {
            let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
            try await model.reloadConfiguration()
            model.chats = [ChatRecord(id: "parent", workspaceID: "project", title: "Parent", path: nil, profileID: "p")]
            return model
        }
        let model = try await makeModel()
        try await model.store?.put(DraftRecord(id: "parent", text: "Parent draft"), kind: "draft", id: "parent")
        await model.select("parent")
        model.openSide(parentID: "parent")
        let side = try XCTUnwrap(model.sides["parent"]); XCTAssertTrue(side.pending)
        model.displays[side.id]?.draft = "check the migration"
        XCTAssertFalse(model.hasActiveWork, "An unsent side asks nothing at quit")
        let lifecycle = ApplicationLifecycle(); lifecycle.model = model
        var answers: [Bool] = []
        lifecycle.answerTermination = { answers.append($0) }
        XCTAssertEqual(lifecycle.applicationShouldTerminate(NSApp), .terminateLater)
        for _ in 0..<500 where answers.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(answers, [true])
        let sideDraft = try await model.store?.get(DraftRecord.self, kind: "draft", id: side.id)
        XCTAssertNil(sideDraft, "Nothing is written under the side's id")
        try await model.traces.close(); await model.store?.close()

        let relaunched = try await makeModel()
        registerWorkspaceFixtureTeardown(relaunched, root: root)
        await relaunched.select("parent")
        XCTAssertEqual(relaunched.selected?.draft, "Parent draft\n\ncheck the migration")
    }
}
