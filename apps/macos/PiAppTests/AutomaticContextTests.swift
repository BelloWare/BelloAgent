import Combine
import XCTest
@testable import PiApp

final class AutomaticContextTests: XCTestCase {
    @MainActor func testSelectingTabCalculatesSavedDraftAndReusesMatchingPreview() async throws {
        let model = try await fixture(); defer { model.shutdown() }
        var calls = 0
        model.automaticContextOperation = { item, params in
            calls += 1
            XCTAssertEqual(item.id, "a"); XCTAssertEqual(params["text"], .string("Saved unsent draft"))
            return Self.summary(tokens: 321)
        }
        try await model.store?.put(DraftRecord(id: "a", text: "Saved unsent draft"), kind: "draft", id: "a")
        await model.select("a"); await presentationReady(model)
        let pending = try XCTUnwrap(model.automaticContextTask)
        let display = try XCTUnwrap(model.selected)
        XCTAssertTrue(display.footer.preparingContext)
        model.scheduleAutomaticContext("a")
        XCTAssertEqual(model.automaticContextTask?.token, pending.token, "Repeated view activation shares the same work")
        await pending.task.value
        XCTAssertEqual(model.displayedContext(try XCTUnwrap(model.selected))["tokens"], .number(321))
        XCTAssertFalse(display.footer.preparingContext)
        XCTAssertEqual(display.draft, "Saved unsent draft")
        await model.select("a"); await presentationReady(model)
        XCTAssertNil(model.automaticContextTask, "Reopening a tab reuses its matching fresh estimate")
        XCTAssertEqual(calls, 1); XCTAssertTrue(model.hosts.isEmpty)
        try await close(model)
    }

    /// Every keystroke restarts the pending estimate. Restarting it used to
    /// clear the footer's "calculating" flag and set it again, two publishes
    /// of the footer per key, each redrawing the composer's context pill, the
    /// cost-limit control and the chat's sidebar row with nothing changed.
    @MainActor func testTypingDoesNotRepublishTheFooterForEveryKeystroke() async throws {
        let model = try await fixture(); defer { model.shutdown() }
        model.automaticContextOperation = { _, _ in Self.summary(tokens: 400) }
        await model.select("a"); await presentationReady(model)
        if let pending = model.automaticContextTask { await pending.task.value }
        let display = try XCTUnwrap(model.selected)
        XCTAssertFalse(display.footer.preparingContext)
        var publishes = 0
        let observation = display.footer.objectWillChange.sink { publishes += 1 }
        defer { observation.cancel() }
        let keystrokes = 40
        for index in 0..<keystrokes {
            display.draft += String(index % 10)
            model.draftChanged(display)
            XCTAssertTrue(display.footer.preparingContext, "The estimate stays pending while the draft changes")
        }
        let pending = try XCTUnwrap(model.automaticContextTask)
        XCTAssertEqual(pending.signature.params["text"], .string(display.draft), "The pending estimate is for the latest draft")
        print("PERF footerPublishesPerKeystroke \(Double(publishes) / Double(keystrokes)) (\(publishes) for \(keystrokes) keystrokes)")
        XCTAssertLessThanOrEqual(publishes, 1, "Only the first keystroke turns the estimate on")
        model.cancelAutomaticContext()
        XCTAssertFalse(display.footer.preparingContext, "Cancelling still clears it")
        try await close(model)
    }

    @MainActor func testChangingTabsCancelsAndRejectsThePreviousLateResult() async throws {
        let model = try await fixture(); defer { model.shutdown() }
        var continuation: CheckedContinuation<Void, Never>?
        model.automaticContextOperation = { item, _ in
            if item.id == "a" { await withCheckedContinuation { continuation = $0 } }
            return Self.summary(tokens: item.id == "a" ? 111 : 222)
        }
        await model.select("a"); await presentationReady(model)
        let first = try XCTUnwrap(model.automaticContextTask)
        let deadline = Date().addingTimeInterval(3)
        while continuation == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let release = try XCTUnwrap(continuation)
        await model.select("b"); await presentationReady(model)
        let second = try XCTUnwrap(model.automaticContextTask)
        release.resume()
        await first.task.value; await second.task.value
        XCTAssertNil(model.displays["a"]?.footer.preparedContext)
        XCTAssertEqual(model.displays["a"]?.footer.preparingContext, false)
        XCTAssertEqual(model.displayedContext(try XCTUnwrap(model.selected))["tokens"], .number(222))
        XCTAssertEqual(model.selectedID, "b"); XCTAssertTrue(model.hosts.isEmpty)
        try await close(model)
    }

    @MainActor func testAutomaticPreviewPublishesTheHelperCountAndItsProvenanceTogether() async throws {
        let model = try await fixture(); defer { model.shutdown() }
        let count: [String: WireValue] = ["tokens": .number(1234), "method": .string("heuristic"), "estimated": .bool(true),
            "requestedModel": .string("auto-router"), "requestFingerprint": .string("automatic-request"),
            "source": .string("Prepared request structure"), "warnings": .array([.string("Route is not bound")]),
            "outputBudget": .number(2048), "safetyMargin": .number(1024)]
        model.automaticContextOperation = { _, _ in
            var summary = Self.summary(tokens: 9999); summary["count"] = .object(count); return summary
        }
        await model.select("a"); await presentationReady(model)
        let pending = try XCTUnwrap(model.automaticContextTask)
        await pending.task.value
        let display = try XCTUnwrap(model.selected)
        let visible = model.displayedContext(display)
        for (key, value) in count { XCTAssertEqual(visible[key], value) }
        let prepared=try XCTUnwrap(PreparedContextMetrics.context(from:display.footer.preparedContext?.summary ?? [:]))
        for (key,value) in prepared { XCTAssertEqual(visible[key],value) }
        XCTAssertEqual(visible["scope"]?.string,"next-input")
        XCTAssertEqual(ContextMeterPresentation(context: visible).warnings, ["Route is not bound"])
        XCTAssertTrue(model.hosts.isEmpty)
        try await close(model)
    }

    @MainActor func testRapidDraftEditsCoalesceAndReplaceStaleContextWithoutCountingInactiveOrBusyChats() async throws {
        let model = try await fixture(); defer { model.shutdown() }
        var countedDrafts: [String] = []
        model.automaticContextOperation = { _, params in
            let text = params["text"]?.string ?? ""
            countedDrafts.append(text)
            return Self.summary(tokens: Double(100 + text.utf8.count))
        }
        await model.select("a"); await presentationReady(model)
        let initial = try XCTUnwrap(model.automaticContextTask)
        await initial.task.value
        let active = try XCTUnwrap(model.selected)
        active.context = ["tokens": .number(9000), "contextWindow": .number(16000)]
        XCTAssertEqual(model.displayedContext(active)["tokens"], .number(100))

        var superseded: [Task<Void, Never>] = []
        for text in ["D", "Draft", "The final unsent draft"] {
            if let pending = model.automaticContextTask { superseded.append(pending.task) }
            active.draft = text; model.draftChanged(active)
            XCTAssertTrue(active.footer.preparingContext)
            XCTAssertEqual(model.displayedContext(active)["state"], .string("pending"))
            XCTAssertEqual(model.displayedContext(active)["tokens"], .null, "Never replace a pending draft count with old conversation tokens")
        }
        let final = try XCTUnwrap(model.automaticContextTask)
        let inactive = SessionDisplay(id: "b"); inactive.contextSelectionReady = true
        model.displays[inactive.id] = inactive
        inactive.draft = "An inactive draft"; model.draftChanged(inactive)
        XCTAssertEqual(model.automaticContextTask?.token, final.token, "An inactive draft must not cancel or replace focused work")
        for task in superseded { await task.value }
        await final.task.value
        XCTAssertEqual(countedDrafts, ["", "The final unsent draft"])
        XCTAssertEqual(model.displayedContext(active)["tokens"], .number(Double(100 + active.draft.utf8.count)))
        XCTAssertFalse(active.footer.preparingContext)

        active.state = "running"; active.draft = "Queued draft during generation"; model.draftChanged(active)
        XCTAssertNil(model.automaticContextTask)
        XCTAssertEqual(countedDrafts.count, 2)
        XCTAssertTrue(model.hosts.isEmpty, "The injected read-only preview never dispatches a generation request")
        try await close(model)
    }

    @MainActor func testOpenEphemeralSideDraftAlsoSchedulesContextBeforePersistenceEarlyReturn() async throws {
        let model = try await fixture(); defer { model.shutdown() }
        let parent = try XCTUnwrap(model.chats.first)
        let child = SideRecord(id: "side", parentID: parent.id, workspaceID: parent.workspaceID, profileID: parent.profileID, title: "Side")
        model.sides[parent.id] = child
        let display = SessionDisplay(id: child.id); model.displays[child.id] = display
        model.opened.insert(child.id); model.selectedID = parent.id; model.focusedSessionID = child.id
        model.page = .chats
        var calls = 0
        model.automaticContextOperation = { item, params in
            calls += 1; XCTAssertEqual(item.id, child.id); XCTAssertEqual(params["text"], .string("Unsent side draft"))
            return Self.summary(tokens: 246)
        }
        XCTAssertTrue(model.isEphemeral(child.id))
        display.draft = "Unsent side draft"; model.draftChanged(display)
        let pending = try XCTUnwrap(model.automaticContextTask)
        await pending.task.value
        XCTAssertEqual(calls, 1); XCTAssertEqual(model.displayedContext(display)["tokens"], .number(246))
        let saved = try await model.store?.get(DraftRecord.self, kind: "draft", id: child.id)
        XCTAssertNil(saved, "Preparing an ephemeral side must not change draft persistence policy")
        XCTAssertTrue(model.hosts.isEmpty)
        try await close(model)
    }

    @MainActor func testAutomaticPreviewSkipsUntrustedImportedRunningAndInterruptedChats() async throws {
        let model = try await fixture(); defer { model.shutdown() }
        model.automaticContextOperation = { _, _ in XCTFail("An unsafe chat must not prepare automatically"); return Self.summary(tokens: 1) }
        model.workspaces[0].trusted = false
        await model.select("a"); await presentationReady(model); XCTAssertNil(model.automaticContextTask)
        model.workspaces[0].trusted = true; model.chats[0].imported = true
        await model.select("a"); await presentationReady(model); XCTAssertNil(model.automaticContextTask)
        model.chats[0].imported = false
        model.displays["a"]?.state = "running"
        await model.select("a"); await presentationReady(model); XCTAssertNil(model.automaticContextTask)
        model.displays["a"]?.state = "interrupted"
        await model.select("a"); await presentationReady(model); XCTAssertNil(model.automaticContextTask)
        XCTAssertTrue(model.hosts.isEmpty)
        try await close(model)
    }

    func testHistorySafetyUsesActiveContextAfterBranchCompactionAndExplicitSelection() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("safe.jsonl")
        let header: WireValue = .object(["type": .string("session"), "version": .number(3), "id": .string("a")])
        let native: WireValue = .object(["type": .string("custom"), "id": .string("native"), "parentId": .null, "customType": .string("pi-app.native.v1"), "data": .object([:])])
        let call: WireValue = .object(["type": .string("message"), "id": .string("call"), "parentId": .string("native"), "message": .object([
            "role": .string("assistant"), "content": .array([.object(["type": .string("toolCall"), "id": .string("tool-1"), "name": .string("bash"), "arguments": .object([:])])])])])
        let result: WireValue = .object(["type": .string("message"), "id": .string("result"), "parentId": .string("call"), "message": .object([
            "role": .string("toolResult"), "toolCallId": .string("tool-1"), "content": .array([.object(["type": .string("text"), "text": .string("Done")])])])])
        func write(_ records: [WireValue]) throws {
            var data = Data()
            for record in records { data.append(try JSONEncoder().encode(record)); data.append(10) }
            try data.write(to: path, options: .atomic)
        }
        let history = HistoryReader()
        try write([header, native, call, result])
        let complete = try await history.allowsAutomaticContext(path: path.path, id: "a")
        XCTAssertTrue(complete)
        try write([header, native, call])
        let unresolved = try await history.allowsAutomaticContext(path: path.path, id: "a")
        XCTAssertFalse(unresolved)
        for kind in ["branch", "compaction", "custom"] {
            for paired in [false, true] {
                let ids: WireValue = .array((paired ? ["call", "result"] : ["call"]).map(WireValue.string))
                var change: [String: WireValue] = ["type": .string(kind), "id": .string("change"), "parentId": .string("result")]
                if kind == "branch" { change["keptIds"] = ids; change["fromMessageId"] = .string("result") }
                if kind == "compaction" { change["nativeKeptIDs"] = ids; change["summary"] = .string("Summary") }
                if kind == "custom" { change["customType"] = .string("pi-app.native.context.v1"); change["data"] = .object(["ids": ids]) }
                try write([header, native, call, result, .object(change)])
                let safe = try await history.allowsAutomaticContext(path: path.path, id: "a")
                XCTAssertEqual(safe, paired, "\(kind) must check retained tool pairs, not the full journal")
            }
        }
        let pending: WireValue = .object(["type": .string("custom"), "id": .string("pending"), "parentId": .string("result"),
            "customType": .string("pi-app.native.state.v1"), "data": .object(["active": .bool(true), "queue": .array([]), "steering": .array([])])])
        try write([header, native, call, result, pending])
        let interrupted = try await history.allowsAutomaticContext(path: path.path, id: "a")
        XCTAssertFalse(interrupted)
    }

    func testVersionedCompactionValidatesOrderedActiveReferences() async throws {
        let root=try scratch();defer { try? FileManager.default.removeItem(at:root) }
        let path=root.appendingPathComponent("checkpoint.jsonl"),reader=HistoryReader()
        let records:[[String:Any]]=[
            ["type":"session","version":3,"id":"a"],
            ["type":"custom","id":"native","parentId":NSNull(),"customType":"pi-app.native.v1"],
            ["type":"message","id":"root","parentId":"native","message":["role":"user","content":"Objective"]],
            ["type":"message","id":"answer","parentId":"root","message":["role":"assistant","content":"Work"]],
            ["type":"message","id":"steer","parentId":"answer","message":["role":"user","content":"Constraint"]]
        ]
        for variant in 0..<4 {
            var metadata:[String:Any]=["version":2,"sourceIDs":["root","answer","steer"],"protectedIDs":["root","steer"],"keptIDs":["root","steer","answer"]]
            if variant==1 { metadata["version"]=99 }
            if variant==2 { metadata["sourceIDs"]=["root","abandoned","steer"] }
            if variant==3 { metadata["protectedIDs"]=["steer","root"] }
            let checkpoint:[String:Any]=["type":"compaction","id":"summary","parentId":"steer","nativeCompactionVersion":2,"nativeCompaction":metadata,"nativeKeptIDs":["root","steer","answer"],"summary":"Work summary"]
            var bytes=Data()
            for record in records+[checkpoint] { bytes.append(try JSONSerialization.data(withJSONObject:record,options:.sortedKeys));bytes.append(10) }
            try bytes.write(to:path,options:.atomic)
            let safe=try await reader.allowsAutomaticContext(path:path.path,id:"a")
            XCTAssertEqual(safe,variant==0,"Malformed, foreign or reordered checkpoint must not open automatically")
        }
    }

    @MainActor func testAutomaticPackagedPreviewPersistsNewJournalWithoutDispatchAndCanReopen() async throws {
        let model = try await fixture(); defer { model.shutdown() }
        await model.select("a"); await presentationReady(model)
        let first = try XCTUnwrap(model.automaticContextTask)
        await first.task.value
        let display = try XCTUnwrap(model.selected)
        let prepared = try XCTUnwrap(display.footer.preparedContext)
        XCTAssertEqual(prepared.summary["dispatched"], .bool(false))
        XCTAssertNotNil(ContextMeterPresentation(context: model.displayedContext(display)).fraction)
        let item = try XCTUnwrap(model.record("a")), path = try XCTUnwrap(item.path)
        let saved = try await model.store?.get(ChatRecord.self, kind: "chat", id: "a")
        XCTAssertEqual(saved?.path, path, "An unsent chat must retain the allocated journal before helper eviction")
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let host = try XCTUnwrap(model.hosts[item.workspaceID])
        let snapshot = try await host.request("session.snapshot", sessionID: item.id).object ?? [:]
        XCTAssertEqual(snapshot["messages"]?.array?.count, 0); XCTAssertEqual(snapshot["queueCount"], .number(0))
        XCTAssertEqual(snapshot["state"], .string("idle"))
        let requests = try await model.traces.list(sessionID: item.id)
        XCTAssertTrue(requests.isEmpty)
        try await host.shutdownAndWait()
        model.hosts.removeValue(forKey: item.workspaceID); model.opened.remove(item.id)
        display.footer.preparedContext = nil
        await model.select(item.id); await presentationReady(model)
        let reopened = try XCTUnwrap(model.automaticContextTask)
        await reopened.task.value
        XCTAssertNotNil(display.footer.preparedContext, "A selected saved tab calculates again after helper eviction")
        XCTAssertEqual(model.record(item.id)?.path, path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before, "Read-only context does not append messages or repair history")
        try await close(model)
    }

    @MainActor func testOptionalPreviewWaitsForUsefulDestinationGeometry() async throws {
        let model = try await fixture(); defer { model.shutdown() }
        var calls = 0
        model.automaticContextOperation = { _, _ in calls += 1; return Self.summary(tokens: 123) }
        model.historyWindowLoader = { _, _, _, _ in
            try ConversationHistoryPage(.object(["version":.number(2), "incarnation":.string("fixture"), "lineage":.string("root"),
                "older":.null, "newer":.null, "messages":.array([.object(["id":.string("u"), "role":.string("user"), "text":.string("Question")])])]))
        }
        await model.select("a")
        XCTAssertEqual(model.selected?.historyState, .preparing)
        XCTAssertNil(model.automaticContextTask); XCTAssertEqual(calls, 0)
        await presentationReady(model)
        let pending = try XCTUnwrap(model.automaticContextTask); await pending.task.value
        XCTAssertEqual(calls, 1)
        try await close(model)
    }

    @MainActor private func presentationReady(_ model: WorkspaceModel) async {
        guard let view = model.selected else { return }
        if view.presentation.readyAt == nil { model.historyViewportReady(view.id, generation: view.presentationGeneration) }
        // Simulate the native viewport callback, then allow deferred optional
        // work to be admitted. It must not run during source/layout hydration.
        await view.presentation.secondary?.value
    }

    @MainActor private func fixture() async throws -> WorkspaceModel {
        let root = try scratch(), vault = ConfigurationVault(storage: MemoryVaultStorage())
        let workspace = WorkspaceRecord(id: "context-project", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "connection"; profile.baseUrl = "http://127.0.0.1:1"
        profile.modelId = "context-fixture"; profile.contextWindow = 16_000; profile.maxOutputTokens = 2_048
        let connection = VaultProfile(profile: profile, apiKey: "synthetic-context-key")
        _ = try await vault.update(expectedRevision: 0) {
            $0.profiles = [connection]; $0.workspaces = [workspace]
            $0.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("empty-codex").path)])
        }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        // These tests answer for the helper's context preview themselves;
        // typing must not start a real helper behind them.
        model.prewarmsHelpers = false
        try await model.reloadConfiguration()
        model.chats = ["a", "b"].map { ChatRecord(id: $0, workspaceID: workspace.id, title: $0, path: nil, profileID: profile.id) }
        for item in model.chats { try await model.store?.put(item, kind: "chat", id: item.id) }
        return model
    }
    @MainActor private func close(_ model: WorkspaceModel) async throws {
        for host in model.hosts.values { try await host.shutdownAndWait() }
        model.shutdown(); try await model.traces.close(); await model.store?.close()
    }
    private static func summary(tokens: Double) -> [String: WireValue] {
        ["estimatedTokens": .number(tokens), "contextWindow": .number(16_000), "seq": .number(0),
         "draftIncluded": .bool(true), "mode": .string("next-request"), "dispatched": .bool(false)]
    }
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("automatic-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
