import XCTest
@testable import PiApp

extension CommittedHistoryTests {
    func testReplayedIncompletePresentationsMatchTheHelper() async throws {
        var progress = ResponseTimeline()
        progress.consume(.init(attemptID: "interrupted", ordinal: 0, itemID: "progress", kind: "reasoningText", update: "append", text: "Retained progress"))
        let timeline = try JSONSerialization.jsonObject(with: JSONEncoder().encode(progress))
        let f = try await fixture(rows: [row("u", "user", "Earlier task"),
            ["type": "message", "id": "ledger", "message": ["role": "system", "content": [], "nativeKind": "requestLedger",
                "nativeDetail": "Requesting an answer", "nativeResponseTimeline": timeline, "nativeReplayEligible": false]],
            ["type": "message", "id": "operation", "message": ["role": "system", "content": [], "nativeKind": "execution",
                "nativeOperationID": "interrupted-compaction", "nativeDetail": "Preparing a summary", "nativeResponseTimeline": timeline, "nativeReplayEligible": false]],
            row("next", "user", "A later completed task"), row("answer", "assistant", "Done")])
        try await assertParity(f, params: ["edge": .string("start")])
    }

    func testLiveTailKeepsHelperAuthorityWhileOlderCommittedRowsUseFile() async throws {
        let gatewayRoot = URL(fileURLWithPath: scratchBase()).appendingPathComponent("history-gateway-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: gatewayRoot, withIntermediateDirectories: true)
        var repository = URL(fileURLWithPath: #filePath); for _ in 0..<4 { repository.deleteLastPathComponent() }
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [repository.appendingPathComponent("fixtures/native/history_stream.py").path, gatewayRoot.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() }; try? FileManager.default.removeItem(at: gatewayRoot) }
        let ready = gatewayRoot.appendingPathComponent("ready.json")
        try await eventually("Generated history gateway did not start") { FileManager.default.fileExists(atPath: ready.path) }
        let port = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as? [String: Int])?["port"])
        var profile = ProfileRecord(); profile.modelId = "fixture"; profile.baseUrl = "http://127.0.0.1:\(port)/v1"; profile.advancedJSON = #"{"routing":{"replayPolicy":"portable"}}"#
        let f = try await fixture(rows: (0..<2400).map { row("m\($0)", $0.isMultiple(of: 2) ? "user" : "assistant", "Row \($0)") }, profile: profile)
        _ = try await f.host.request("turn.submit", sessionID: "history", params: ["clientTurnId": .string("live-input"), "text": .string("Generated streaming gate")])
        try await eventually("The generated partial reply did not arrive", timeout: .seconds(30)) {
            let snapshot = try await f.host.request("session.snapshot", sessionID: "history")
            return snapshot.object?["messages"]?.array?.contains { $0.object?["text"]?.string == "Live partial response" } == true
        }
        let source = try await description(f); XCTAssertNotNil(source.liveTail)
        let model = WorkspaceModel(stateRoot: f.root.appendingPathComponent("app"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: f.root.appendingPathComponent("app"))
        let item = ChatRecord(id: "history", workspaceID: "fixture", title: "History", path: f.path, profileID: profile.id)
        model.chats = [item]; model.hosts[item.workspaceID] = f.host; model.opened.insert(item.id)
        let old = try await model.readConversationWindow(item, cursor: nil, start: true, followsNavigation: false, opening: true)
        XCTAssertTrue(old.incarnation.hasPrefix("file:")); XCTAssertEqual(old.messages.count, 250)
        let live = try await model.readConversationWindow(item, cursor: nil, around: try XCTUnwrap(source.liveTail?.entry), followsNavigation: false)
        XCTAssertFalse(live.incarnation.hasPrefix("file:")); XCTAssertFalse(live.messages.contains { $0.text == "Live partial response" }, "Streaming text belongs to the snapshot overlay")
        let helper = try ConversationHistoryPage(await f.host.request("session.history", sessionID: "history", params: ["version": .number(2), "edge": .string("start"), "opening": .bool(true)]))
        try assertRows(old.messages, helper.messages)
        let jumped = try await model.readConversationWindow(item, cursor: nil, position: try XCTUnwrap(source.liveTail?.position), validating: old.newer, followsNavigation: false)
        XCTAssertEqual(jumped.messages.map(\.id), live.messages.map(\.id), "A file-to-live jump must preserve the target through its stable entry")
        XCTAssertGreaterThan(live.messages.count, 1)
        if live.messages.count > 1 {
            var target: String?
            f.host.requestObserver = { method, params, _ in if method == "session.history" { target = params["around"]?.string } }
            _ = try await model.readConversationWindow(item, cursor: nil, position: try XCTUnwrap(source.liveTail?.position) + 1, validating: old.newer, followsNavigation: false)
            XCTAssertEqual(target, live.messages[1].id, "The helper must reanchor at the requested row even if its live byte weight changes")
            f.host.requestObserver = nil
        }
        let view = SessionDisplay(id: item.id)
        model.displays[item.id] = view; model.selectedID = item.id; model.selected = view
        model.adoptPage(old, into: view, presenting: false)
        XCTAssertTrue(view.browsingHistory)
        model.refresh(item.id)
        try await eventually("The historical page snapshot did not settle") { !view.snapshotInFlight }
        XCTAssertEqual(view.messages.map(\.id), old.messages.map(\.id), "A live snapshot must preserve the older file page")
        model.adoptPage(live, into: view, presenting: false)
        XCTAssertFalse(view.browsingHistory)
        model.refresh(item.id)
        try await eventually("The file-to-helper handoff lost the live snapshot") { view.messages.contains { $0.text == "Live partial response" } }
        FileManager.default.createFile(atPath: gatewayRoot.appendingPathComponent("finish").path, contents: Data())
        try await eventually("The fixture did not finish", timeout: .seconds(30)) {
            let snapshot = try await f.host.request("session.snapshot", sessionID: "history")
            return snapshot.object?["state"]?.string == "idle"
        }
        model.refresh(item.id)
        try await eventually("The adopted live page did not finish") { !view.snapshotInFlight && !view.busy }
        XCTAssertTrue(view.messages.contains { $0.text == "Live partial response" })
    }
    func testRealHelperCutCrashEdgesNeverExposeHalfAProjection() async throws {
        for projected in -1...2 {
            let cut: [String: Any] = ["version": 1, "cutId": "cut", "attemptId": "attempt", "responseId": "response", "itemId": "item"]
            var assistant: [String: Any] = ["role": "assistant", "content": [
                ["type": "text", "text": "Retained prefix"], ["type": "toolCall", "id": "call", "name": "bash", "arguments": ["command": "never"]]],
                "timestamp": 123, "nativeReplayEligible": true, "isError": false, "nativeTurn": "turn", "nativeRequestAttemptIds": ["attempt"], "nativeMailboxCut": cut]
            var result: [String: Any] = ["role": "toolResult", "content": [["type": "text", "text": "Not executed: agent message arrived before dispatch."]],
                "timestamp": 123, "nativeReplayEligible": true, "isError": true, "nativeTurn": "turn", "toolName": "bash", "toolCallId": "call",
                "nativeToolStats": ["outcome": "not_executed"], "nativeAgentCallCancellation": ["version": 1, "cutId": "cut", "reason": "agent_message"]]
            // These are the optional JSON fields emitted by ChatMessage.pi
            // after the helper normalizes a reserved cut row.
            for key in ["nativeSubagent", "nativeProviderIdentity", "nativeProviderBinding", "nativeToolStats", "nativeCompaction", "usage"] {
                if assistant[key] == nil { assistant[key] = NSNull() }
                if result[key] == nil { result[key] = NSNull() }
            }
            let reserved: [[String: Any]] = [["id": "prefix", "message": assistant], ["id": "cancelled", "message": result]]
            var preparation: [String: Any] = ["version": 1, "cutId": "cut", "attemptId": "attempt", "turnId": "turn", "branchId": "turn", "generation": 0,
                "recipientSessionId": "history", "eventIds": ["mail"], "rows": reserved]
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let prepared = try JSONDecoder().decode(WireValue.self, from: JSONSerialization.data(withJSONObject: preparation))
            preparation["digest"] = JournalCheckpoint.digest(try encoder.encode(prepared))
            let commit = preparation.filter { !["turnId", "branchId", "generation", "eventIds", "rows"].contains($0.key) }
            let scope = RequestScope(sourceSessionID: "history", budgetOwnerSessionID: "history", turnID: "turn", executionID: "execution", purpose: "turn", ownerGeneration: 0, delegation: nil)
            var rows = [row("turn", "user", "Generated task")]
            rows.append(["id": "family", "type": "custom", "customType": "pi-app.family-run.v1", "ownerID": "history", "data": ["epoch": "execution", "closed": false, "heldChildren": [], "reportContinuations": 0, "rateTimes": [:]]])
            rows.append(["id": "admission", "type": "custom", "customType": "pi-app.budget-attempt.v1", "data": ["attemptId": "attempt", "sourceSessionId": "history", "budgetOwnerSessionId": "history", "purpose": "turn", "state": "dispatched", "scope": try JSONSerialization.jsonObject(with: encoder.encode(scope)), "accountingRevision": 1]])
            rows.append(["id": "prepared", "type": "custom", "customType": "agent_cut_prepared", "ownerID": "history", "data": preparation])
            if projected >= 0 {
                rows.append(["id": "committed", "type": "custom", "customType": "agent_cut_committed", "ownerID": "history", "data": commit])
                rows += reserved.prefix(projected).map { $0.merging(["type": "message"]) { _, new in new } }
            }
            let f = try await fixture(rows: rows, marker: projected >= 0 ? "pi-app.native.v5" : "pi-app.native.v4")
            try await assertParity(f, params: ["edge": .string("start")])
            let page = try ConversationHistoryPage(await f.host.request("session.history", sessionID: "history", params: ["version": .number(2)]))
            let ids = page.messages.map(\.id)
            XCTAssertEqual(ids.contains("prefix"), projected >= 0); XCTAssertEqual(ids.contains("cancelled"), projected >= 0)
            if projected >= 0 { XCTAssertEqual(page.messages.first { $0.id == "prefix" }?.tools?.first?.state, "cancelled") }
        }
    }
    func testCommittedPrefixSurvivesAnAppendDuringIndexing() async throws {
        let f = try await fixture(rows: (0..<40).map { row("m\($0)", $0.isMultiple(of: 2) ? "user" : "assistant", "Row \($0)") })
        let source = try await description(f), reader = HistoryReader(indexDirectory: f.root)
        let suffix = try appendedLine(id: "outside", parent: source.lastID, body: row("outside", "user", "Not in the captured display transaction"))
        // The helper is the writer in production. This deterministic append
        // happens after capture, while the reader has an open descriptor.
        let once = HistoryAppendOnce()
        await reader.observeIndexChunks { [path = f.path] _ in
            guard once.take() else { return }
            let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? writer.close() }
            try writer.seekToEnd(); try writer.write(contentsOf: suffix)
        }
        let page = try await reader.window(path: f.path, start: true, source: source)
        XCTAssertEqual(page.messages.map(\.id), (0..<40).map { "m\($0)" })
        XCTAssertEqual(page.total, source.total)
        XCTAssertFalse(page.messages.contains { $0.id == "outside" })
    }

    func testReplacedPathAndLineageAreRejectedBeforePublication() async throws {
        let f = try await fixture(rows: [row("u", "user", "Question"), row("a", "assistant", "Answer")])
        let source = try await description(f), reader = HistoryReader(indexDirectory: f.root)
        var edited = source; edited.lineage = "other-branch"
        do { _ = try await reader.window(path: f.path, source: edited); XCTFail("Source lineage must match the indexed display") } catch { }
        let replacement = f.root.appendingPathComponent("replacement")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: f.path), to: replacement)
        XCTAssertEqual(rename(replacement.path, f.path), 0)
        do { _ = try await reader.window(path: f.path, source: source); XCTFail("The same bytes at a replacement inode are not the captured source") } catch { }
    }
    func testReplacementRebindsAtStableEntryInsteadOfOldNumericPosition() async throws {
        let f = try await fixture(rows: (0..<80).map { row("m\($0)", $0.isMultiple(of: 2) ? "user" : "assistant", "Row \($0)") })
        let source = try await description(f), reader = HistoryReader(indexDirectory: f.root)
        let held = try await reader.window(path: f.path, around: "m40", source: source)
        let boundary = try XCTUnwrap(held.older)
        _ = try await f.host.request("session.close", sessionID: "history")
        let copy = f.root.appendingPathComponent("replaced.jsonl")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: f.path), to: copy)
        XCTAssertEqual(rename(copy.path, f.path), 0)
        _ = try await f.host.request("session.open", sessionID: "history", params: ["profile": f.profile.wire, "apiKey": .string("synthetic-only"), "path": .string(f.path), "connectionTest": .bool(true)])
        let replacement = try await description(f)
        XCTAssertNotEqual(source.inode, replacement.inode)
        let page = try await reader.window(path: f.path, position: 0, validating: boundary, source: replacement)
        XCTAssertEqual(page.messages.first?.id, "m40", "A new inode must reanchor at the held entry, never reuse position zero")
        var missing = boundary; missing.entry = "not-retained"
        do { _ = try await reader.window(path: f.path, position: 0, validating: missing, source: replacement); XCTFail("Missing stable entry rebound") } catch { }
    }

    func testRealHelperParityAcrossEditsCompactionTasksMailAndLargeTransfers() async throws {
        var rows: [[String: Any]] = []
        for turn in 0..<8 {
            var input = row("u\(turn)", "user", "Question \(turn)"), answer = row("a\(turn)", "assistant", "Answer \(turn)")
            for key in ["nativeTaskRoot", "nativeTurn"] {
                var message = input["message"] as! [String: Any]; message[key] = "u\(turn)"; input["message"] = message
                message = answer["message"] as! [String: Any]; message[key] = "u\(turn)"; answer["message"] = message
            }
            var message = answer["message"] as! [String: Any]; message["nativeTaskExecution"] = "task\(turn)"; answer["message"] = message
            rows += [input, answer]
            var task = TaskPresentationRecord(rootID: "u\(turn)", executionID: "task\(turn)", startedAt: 100)
            task.phase = "terminal"; task.outcome = "completed"; task.endedAt = 200; task.lastSourceID = "a\(turn)"; task.replies = 1
            rows.append(["type": "custom", "customType": "pi-app.task-terminal.v1", "id": "task-end-\(turn)", "data": try JSONSerialization.jsonObject(with: JSONEncoder().encode(task))])
        }
        rows.append(["type": "compaction", "id": "compact", "summary": "Earlier answers", "nativeKeptIDs": ["u6", "a6", "u7", "a7"], "tokensBefore": 100])
        rows.append(["type": "branch", "id": "edit", "fromMessageId": "u7", "keptIds": ["compact", "u6", "a6"]])
        rows += [row("u7b", "user", "Revised question"), row("a7b", "assistant", "Revised answer")]
        let event: [String: Any] = ["event_id": "mail", "family_sequence": 1, "type": "MESSAGE", "sender": "/root/audit", "recipient": "/root", "turn": 1, "text": "The retained result is complete."]
        rows.append(["type": "message", "id": "delivery", "message": ["role": "user", "content": "Message Type: MESSAGE\nTask name: /root\nSender: /root/audit\nPayload:\n  The retained result is complete.", "nativeAgentDelivery": ["version": 2, "eventIds": ["mail"], "events": [event]], "nativeInputLane": "agent"]])
        rows.append(row("large", "assistant", String(repeating: "Full retained response 🙂\u{0001}\n", count: 50_000) + "FINAL"))
        let f = try await fixture(rows: rows)
        for params: [String: WireValue] in [[:], ["edge": .string("start")], ["around": .string("u6")], ["around": .string("u7b")], ["position": .number(4)]] {
            try await assertParity(f, params: params)
        }
    }

    func testNewRouteUsesFileAndLegacyHelperStillUsesHistory() async throws {
        let f = try await fixture(rows: (0..<80).map { row("m\($0)", $0.isMultiple(of: 2) ? "user" : "assistant", "Row \($0)") })
        let model = WorkspaceModel(stateRoot: f.root.appendingPathComponent("app"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: f.root.appendingPathComponent("app"))
        let item = ChatRecord(id: "history", workspaceID: "fixture", title: "History", path: f.path, profileID: "fixture")
        model.chats = [item]; model.hosts[item.workspaceID] = f.host; model.opened.insert(item.id)
        var calls: [String] = []
        f.host.requestObserver = { method, _, _ in calls.append(method) }
        let page = try await model.readConversationWindow(item, cursor: nil, start: true, followsNavigation: false)
        XCTAssertTrue(page.incarnation.hasPrefix("file:")); XCTAssertFalse(page.fromJournal)
        XCTAssertEqual(calls, ["session.history.source", "session.history.source"])
        XCTAssertNil(page.retainedRun)
        // The old ready shape deliberately omits the additive capability.
        f.host.receive(.frame(["v": .number(1), "kind": .string("ready"), "major": .number(1), "engine": .string("swift"), "engineVersion": .string("1.0.0"),
            "hostEpoch": .string(try XCTUnwrap(f.host.epoch)), "capabilities": .array(["responses", "mcp", "steering", "transport-capture"].map(WireValue.string))]), connectionID: try XCTUnwrap(f.host.connectionID))
        calls.removeAll()
        let fallback = try await model.readConversationWindow(item, cursor: nil, start: true, followsNavigation: false)
        XCTAssertFalse(fallback.incarnation.hasPrefix("file:")); XCTAssertEqual(calls, ["session.history"])
        try assertRows(fallback.messages, page.messages)
    }

    func testTaskReceiptsAndProjectionFieldsMatchWhenByteBudgetCutsTheCandidateRange() async throws {
        var rows: [[String: Any]] = []
        for turn in 0..<6 {
            let root = "u\(turn)", execution = "e\(turn)", answer = "a\(turn)"
            rows.append(row(root, "user", "Question \(turn)"))
            rows.append(["type": "message", "id": answer, "message": ["role": "assistant", "content": String(repeating: "x", count: 750_000),
                "nativeTaskRoot": root, "nativeTaskExecution": execution, "nativeDetail": String(repeating: "Detail 🙂 ", count: 200)]])
            var task = TaskPresentationRecord(rootID: root, executionID: execution, startedAt: 100)
            task.phase = "terminal"; task.outcome = "completed"; task.endedAt = 200; task.lastSourceID = answer; task.assistantID = answer
            rows.append(["type": "custom", "customType": "pi-app.task-terminal.v1", "id": "task-\(turn)", "data": try JSONSerialization.jsonObject(with: JSONEncoder().encode(task))])
        }
        let f = try await fixture(rows: rows)
        try await assertParity(f, params: ["edge": .string("start")])
        try await assertParity(f, params: [:])
    }

    func testReusedToolIDsBranchesAndTransferredResultsMatch() async throws {
        func call(_ id: String) -> [String: Any] {
            ["type": "message", "id": id, "message": ["role": "assistant", "content": [["type": "toolCall", "id": "same-call", "name": "read", "arguments": ["path": id + ".txt"]]]]]
        }
        func result(_ id: String, _ text: String) -> [String: Any] {
            ["type": "message", "id": id, "message": ["role": "toolResult", "toolCallId": "same-call", "toolName": "read", "content": [["type": "text", "text": text]],
                "nativeToolStats": ["outcome": "completed", "path": id + ".txt", "line": 1, "lastLine": 500, "durationMs": 17]]]
        }
        let large = String(repeating: "Complete retained tool output. ", count: 30_000) + "🙂\u{0001}FINAL"
        let f = try await fixture(rows: [row("u0", "user", "First"), call("first"), result("r0", large),
            row("u1", "user", "Abandoned"), call("abandoned"), result("discarded", "Wrong branch"),
            ["type": "branch", "id": "edit", "fromMessageId": "u1", "keptIds": ["u0", "first", "r0"]],
            row("u1b", "user", "Revised"), call("latest"), result("r1", "Latest result")])
        for params: [String: WireValue] in [["edge": .string("start")], ["around": .string("latest")], ["position": .number(1)]] {
            try await assertParity(f, params: params)
        }
    }

    func testEncodedBudgetIncludesRetainedUsageMetadata() async throws {
        var rows: [[String: Any]] = []
        for index in 0..<100 {
            rows.append(row("u\(index)", "user", "Question"))
            rows.append(["type": "message", "id": "a\(index)", "message": ["role": "assistant", "content": [["type": "text", "text": "Answer"]],
                "usage": ["input": 1, "output": 1, "recordedDetail": String(repeating: "retained", count: 5_000)]]])
        }
        let f = try await fixture(rows: rows)
        try await assertParity(f, params: ["edge": .string("start"), "opening": .bool(true)])
    }

    func testNativeCompactionPreservesItsHistoricalContextCaption() async throws {
        let f = try await fixture(rows: [row("u0", "user", "Question"), row("a0", "assistant", "Answer"),
            ["type": "compaction", "id": "compact", "summary": "Native checkpoint", "tokensBefore": 100,
             "nativeKeptIDs": ["u0", "a0"], "nativeCompactionVersion": 2,
             "nativeCompaction": ["version": 2, "operationId": "op", "taskRootId": "u0", "sourceIDs": ["u0", "a0"], "protectedIDs": ["u0"], "keptIDs": ["u0", "a0"]]],
            row("u1", "user", "Continue")])
        try await assertParity(f, params: ["edge": .string("start")])
    }

    func testImagesAndInheritedPrefixMatchTheHelper() async throws {
        let inherited: [String: Any] = ["from": "parent", "cutoffEntryId": "a0"]
        let f = try await fixture(rows: [
            ["type": "message", "id": "u0", "message": ["role": "user", "content": [["type": "image", "mimeType": "image/png",
                "data": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=="]], "nativeInherited": inherited]],
            ["type": "message", "id": "a0", "message": ["role": "assistant", "content": "Inherited answer", "nativeInherited": inherited]],
            row("u1", "user", "Next task")], marker: "pi-app.native.v4")
        try await assertParity(f, params: ["edge": .string("start")])
    }

    func testOpeningAnAlreadyLoadedRuntimeDoesNotBuildAColdFullFileIndex() async throws {
        for count in [0, 80, 400] {
            let f = try await fixture(rows: (0..<count).map { row("m\($0)", $0.isMultiple(of: 2) ? "user" : "assistant", "Row \($0)") })
            let model = WorkspaceModel(stateRoot: f.root.appendingPathComponent("app"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
            registerWorkspaceFixtureTeardown(model, root: f.root.appendingPathComponent("app"))
            let item = ChatRecord(id: "history", workspaceID: "fixture", title: "History", path: f.path, profileID: "fixture")
            model.chats = [item]; model.hosts[item.workspaceID] = f.host; model.opened.insert(item.id)
            for opening in [true, false] {
                var calls: [String] = []
                f.host.requestObserver = { method, _, _ in calls.append(method) }
                let page = try await model.readConversationWindow(item, cursor: nil, followsNavigation: false, opening: opening)
                XCTAssertFalse(page.incarnation.hasPrefix("file:"), "Latest reads retain the helper's live attachment")
                XCTAssertEqual(page.messages.count, min(count, opening ? 250 : 1000))
                XCTAssertEqual(calls, ["session.history"])
                let indexed = await model.history.indexedRecordCount
                XCTAssertEqual(indexed, 0, "The helper already holds these rows")
            }
        }
    }

    func testCheckpointTailAndCursorHandoffsMatchAfterAFullFileRead() async throws {
        var rows = (0..<80).map { row("m\($0)", $0.isMultiple(of: 2) ? "user" : "assistant", "Row \($0)") }
        rows.append(["type": "compaction", "id": "compact", "summary": "Earlier work", "tokensBefore": 100, "nativeKeptIDs": ["m76", "m77", "m78", "m79"]])
        rows += [row("u", "user", "Next"), row("a", "assistant", "Answer")]
        let f = try await fixture(rows: rows)
        _ = try await f.host.request("session.close", sessionID: "history")
        _ = try await f.host.request("session.open", sessionID: "history", params: ["profile": f.profile.wire, "apiKey": .string("synthetic-only"), "path": .string(f.path), "connectionTest": .bool(true)])
        let source = try await description(f), reader = HistoryReader(indexDirectory: f.root)
        XCTAssertGreaterThan(source.availableFrom, 0)
        _ = try await reader.window(path: f.path, start: true, source: source)
        let tail = try await reader.window(path: f.path, source: source)
        let expected = try ConversationHistoryPage(await f.host.request("session.history", sessionID: "history", params: ["version": .number(2)]))
        XCTAssertEqual(tail.start, expected.start); try assertRows(tail.messages, expected.messages)
        let cursor = try XCTUnwrap(tail.older)
        let older = try await reader.window(path: f.path, cursor: cursor, source: source)
        let helperOlder = try ConversationHistoryPage(await f.host.request("session.history", sessionID: "history", params: ["version": .number(2), "entry": .string(cursor.entry), "lineage": .string(cursor.lineage)]))
        try assertRows(older.messages, helperOlder.messages); XCTAssertEqual(older.start, helperOlder.start)
        let current = try await description(f); XCTAssertEqual(current.availableFrom, 0)
        let next = try XCTUnwrap(older.newer)
        let newer = try await reader.window(path: f.path, cursor: next, newer: true, source: current)
        let helperNewer = try ConversationHistoryPage(await f.host.request("session.history", sessionID: "history", params: ["version": .number(2), "entry": .string(next.entry), "lineage": .string(next.lineage), "direction": .string("newer")]))
        try assertRows(newer.messages, helperNewer.messages); XCTAssertEqual(newer.start, helperNewer.start)
    }

    func testDurablePresentationUpdatesMatchTheHelper() async throws {
        var timeline = ResponseTimeline(); timeline.finish("completed")
        let ledger: [String: Any] = ["role": "system", "content": [], "nativeKind": "requestLedger", "nativeReplayEligible": false,
            "nativeDetail": "Request completed", "nativeTaskRoot": "u", "nativeTaskExecution": "task", "nativePresentationSourceID": "a",
            "nativeResponseTimeline": try JSONSerialization.jsonObject(with: JSONEncoder().encode(timeline))]
        let f = try await fixture(rows: [row("u", "user", "Question"),
            ["type": "message", "id": "ledger", "message": ["role": "system", "content": [], "nativeKind": "requestLedger", "nativeReplayEligible": false]],
            row("a", "assistant", "Answer"),
            ["type": "custom", "id": "updated", "customType": "pi-app.presentation.update.v1", "data": ["id": "ledger"], "message": ledger]])
        try await assertParity(f, params: ["edge": .string("start")])
    }

    func description(_ fixture: Fixture) async throws -> CommittedHistorySource {
        let wire = try await fixture.host.request("session.history.source", sessionID: "history", params: ["version": .number(1)])
        let source = try JSONDecoder().decode(CommittedHistorySource.self, from: JSONEncoder().encode(wire))
        XCTAssertTrue(source.valid); return source
    }
    func assertParity(_ f: Fixture, params: [String: WireValue], file: StaticString = #filePath, line: UInt = #line) async throws {
        var params = params; params["version"] = .number(2)
        let expected = try ConversationHistoryPage(await f.host.request("session.history", sessionID: "history", params: params))
        let source = try await description(f)
        let actual = try await HistoryReader(indexDirectory: f.root).window(path: f.path, around: params["around"]?.string, start: params["edge"]?.string == "start", position: params["position"]?.nonnegativeInteger,
            limits: params["opening"]?.bool == true ? TranscriptPaging.pageLimits.opening : nil, source: source)
        XCTAssertEqual(actual.messages.map(\.id), expected.messages.map(\.id), file: file, line: line)
        XCTAssertEqual(actual.start, expected.start, file: file, line: line); XCTAssertEqual(actual.total, expected.total, file: file, line: line)
        try assertRows(actual.messages, expected.messages, file: file, line: line)
        XCTAssertEqual(actual.lineage, expected.lineage, file: file, line: line)
        XCTAssertEqual(actual.older?.entry, expected.older?.entry, file: file, line: line); XCTAssertEqual(actual.newer?.entry, expected.newer?.entry, file: file, line: line)
        XCTAssertEqual(actual.endsTurn, expected.endsTurn, file: file, line: line)
        XCTAssertEqual(actual.partialTurnInput, expected.partialTurnInput, file: file, line: line)
        XCTAssertEqual(actual.taskRecords, expected.taskRecords, file: file, line: line)
    }
    func assertRows(_ actual: [TranscriptMessage], _ expected: [TranscriptMessage], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(actual.map(\.id), expected.map(\.id), file: file, line: line)
        for (original, b) in zip(actual, expected) where original.id == b.id {
            var a = original
            // A file page can carry an image's local locator. It is transport
            // metadata; every displayed image field is still compared.
            if let reference = a.imageReference { XCTAssertEqual(reference.id, a.id, file: file, line: line) }
            a.imageReference = nil
            if a != b {
                let encoder = JSONEncoder(), decoder = JSONDecoder()
                let left = try decoder.decode(WireValue.self, from: encoder.encode(a)).object ?? [:]
                let right = try decoder.decode(WireValue.self, from: encoder.encode(b)).object ?? [:]
                let fields = Set(left.keys).union(right.keys).filter { left[$0] != right[$0] }.sorted()
                let values = fields.map { "\($0): file=\((left[$0]?.pretty ?? "nil").prefix(350)); helper=\((right[$0]?.pretty ?? "nil").prefix(350))" }
                XCTFail("Different projection for \(a.id): \(values.joined(separator: " | "))", file: file, line: line)
            }
        }
    }
    func appendedLine(id: String, parent: String, body: [String: Any]) throws -> Data {
        var record = body; record["id"] = id; record["parentId"] = parent
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]); data.append(10); return data
    }
}

private final class HistoryAppendOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool { lock.withLock { if used { return false }; used = true; return true } }
}
