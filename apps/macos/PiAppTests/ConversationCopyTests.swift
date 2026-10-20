import AppKit
import XCTest
@testable import PiApp

@MainActor final class ConversationCopyTests: XCTestCase, SerialTestLane {
    private func fixture(omitArguments: Bool = false, streaming: Bool = false) async throws -> (WorkspaceModel, ChatRecord, HostSupervisor, String) {
        let setup = try await gatewayWorkspace("conversation-copy", projectID: "copy")
        let model = WorkspaceModel(stateRoot: setup.state, vault: setup.vault)
        registerWorkspaceFixtureTeardown(model, root: setup.root)
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        try await model.reloadConfiguration()
        model.configuration.runtime.idleGraceSeconds = 3600
        let chat = ChatRecord(id: "copy-chat", workspaceID: "copy", title: "Copy", profileID: setup.profile.id)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        let host = try await model.open(chat)
        let item = try XCTUnwrap(model.record(chat.id)), path = try XCTUnwrap(item.path)
        _ = try await host.request("session.close", sessionID: item.id)
        model.helperSessionDidUnload(item.id)
        let records = try Data(contentsOf: URL(fileURLWithPath: path)).split(separator: 10).map { try JSONDecoder().decode(WireValue.self, from: Data($0)) }
        var call: [String: WireValue] = ["type": .string("toolCall"), "id": .string("call"), "name": .string(streaming ? "read" : "echo")]
        if !omitArguments { call["arguments"] = .object([streaming ? "path" : "text": .string("COPY-ARGUMENT")]) }
        let message: WireValue = .object(["role": .string("assistant"), "content": .array([
            .object(["type": .string("text"), "text": .string("COPY-TEXT " + String(repeating: "🌍 retained text ", count: 4000))]),
            .object(["type": .string("thinking"), "thinking": .string("COPY-REASONING")]),
            .object(call)
        ])])
        let row: [String: WireValue] = ["type": .string("message"), "id": .string("answer"), "parentId": try XCTUnwrap(records.last?.object?["id"]), "message": message]
        try ContentSearchTests.append(JSONEncoder().encode(row) + Data([10]), to: path)
        for (id, parent, value) in [
            ("receipt", "answer", WireValue.object(["role": .string("toolResult"), "toolCallId": .string("call"), "toolName": .string(streaming ? "read" : "echo"), "content": .string("COPY-RESULT")])),
            ("final", "receipt", WireValue.object(["role": .string("assistant"), "content": .string("COPY-FINAL")]))
        ] {
            try ContentSearchTests.append(JSONEncoder().encode(WireValue.object(["type": .string("message"), "id": .string(id), "parentId": .string(parent), "message": value])) + Data([10]), to: path)
        }
        _ = try await model.open(item)
        return (model, item, host, ConversationContent.text(row))
    }
    private func collect(_ source: ConversationContentSource, result: ContentSearch, last: Int = 1) async throws -> String {
        var cursor: ContentCursor? = .init(index: 1, offset: 0), text = ""
        while let next = cursor {
            let page = try await source.page(1, last, next, result.revision)
            text += page.text; cursor = page.next
        }
        return text
    }
    private func retire(_ model: WorkspaceModel, chat: ChatRecord, host: HostSupervisor) async throws {
        model.configuration.runtime.idleGraceSeconds = 0
        model.scheduleIdle(workspaceID: chat.workspaceID, host: host)
        try await eventually("The idle helper retired") { !host.isReady && !model.opened.contains(chat.id) }
        try await host.shutdownAndWait()
    }
    func testCompletedRangeSurvivesStreamingAndDiskHandoffDuringTheResponse() async throws {
        try await copyDuringResponse(handoffFirst: false)
    }
    func testCompletedRangeHandsOffWithAnActiveUnselectedLedger() async throws {
        try await copyDuringResponse(handoffFirst: true)
    }
    private func copyDuringResponse(handoffFirst: Bool) async throws {
        let (model, chat, host, expected) = try await fixture(streaming: true)
        let gatewayRoot = model.root.deletingLastPathComponent()
        func waitForDelta(_ step: Int) async throws {
            try await eventually("The real gateway delta \(step) reaches the helper") {
                let snapshot = try await host.request("session.snapshot", sessionID: chat.id)
                if let failure = snapshot.object?["preflightError"]?.string { throw HostError.failure(failure) }
                return snapshot.object?["messages"]?.array?.contains { message in
                    message.object?["text"]?.string?.contains("COPY-STREAM-\(step)") == true
                } == true
            }
        }
        func release(_ step: Int) throws { try Data().write(to: gatewayRoot.appendingPathComponent("release-copy-\(step)")) }
        _ = try await host.request("turn.submit", sessionID: chat.id, params: ["text": .string("copy selection streaming fixture"), "clientTurnId": .string("copy-stream")])
        try await waitForDelta(1)
        let source = ConversationContentSource.workspace(model, sessionID: chat.id), found = try await source.search("", 0)
        if handoffFirst {
            model.opened.remove(chat.id); defer { model.opened.insert(chat.id) }
            let copied = try await collect(source, result: found)
            XCTAssertEqual(copied, expected)
            let snapshot = try await host.request("session.snapshot", sessionID: chat.id)
            XCTAssertEqual(snapshot.object?["state"], .string("running"))
            for step in 1...3 { try release(step) }
            return
        }
        try release(1); try await waitForDelta(2)
        let first = try await source.page(1, 1, .init(index: 1, offset: 0), found.revision)
        var cursor = try XCTUnwrap(first.next), copied = first.text
        try release(2); try await waitForDelta(3)
        let second = try await source.page(1, 1, cursor, found.revision)
        cursor = try XCTUnwrap(second.next); copied += second.text
        // Retire the reader's helper source while the physical response remains
        // at its final barrier. The active ledger is outside this selected row.
        model.opened.remove(chat.id); defer { model.opened.insert(chat.id) }
        while true {
            let page = try await source.page(1, 1, cursor, found.revision)
            copied += page.text
            guard let next = page.next else { break }; cursor = next
        }
        XCTAssertEqual(copied, expected)
        let snapshot = try await host.request("session.snapshot", sessionID: chat.id)
        XCTAssertEqual(snapshot.object?["state"], .string("running"))
        try release(3)
    }
    func testSavedSelectionsValidateOnlyTheirRange() async throws {
        for selected in [1, 3] {
            let (model, chat, host, answer) = try await fixture()
            try await retire(model, chat: chat, host: host)
            let source = ConversationContentSource.workspace(model, sessionID: chat.id), found = try await source.search("", 0)
            let path = URL(fileURLWithPath: try XCTUnwrap(chat.path))
            let outside = selected == 1 ? "COPY-FINAL" : "COPY-TEXT"
            var saved = try String(contentsOf: path, encoding: .utf8)
            try Data(saved.replacingOccurrences(of: outside, with: "EDIT-OTHER").utf8).write(to: path)
            var cursor: ContentCursor? = .init(index: selected, offset: 0), copied = "", appended = false
            while let next = cursor {
                let page = try await source.page(selected, selected, next, found.revision)
                copied += page.text; cursor = page.next
                if cursor != nil, !appended {
                    let records = try LifecycleHelperTests.records(path.path)
                    let row: WireValue = .object(["type": .string("message"), "id": .string("later"),
                        "parentId": records.last?["id"] ?? .null,
                        "message": .object(["role": .string("user"), "content": .string("Appended outside the selection")])])
                    try ContentSearchTests.append(JSONEncoder().encode(row) + Data([10]), to: path.path)
                    appended = true
                }
            }
            XCTAssertEqual(copied, selected == 1 ? answer : "## assistant\n\nCOPY-FINAL\n\n")
            saved = try String(contentsOf: path, encoding: .utf8)
            let inside = selected == 1 ? "COPY-TEXT" : "COPY-FINAL"
            try Data(saved.replacingOccurrences(of: inside, with: "EDIT-INSIDE").utf8).write(to: path)
            do { _ = try await source.page(selected, selected, .init(index: selected, offset: 0), found.revision); XCTFail("Accepted changed selected bytes") }
            catch { XCTAssertTrue(error.localizedDescription.contains("History changed"), error.localizedDescription) }
        }
    }
    func testLiveAndDiskCopyRetainTheSameCompleteAssistantRange() async throws {
        for omitArguments in [false, true] {
            let (model, chat, host, expected) = try await fixture(omitArguments: omitArguments)
            let live = ConversationContentSource.workspace(model, sessionID: chat.id)
            let found = try await live.search("", 0), copied = try await collect(live, result: found)
            XCTAssertEqual(copied, expected)
            for marker in ["COPY-TEXT", "COPY-REASONING", omitArguments ? "[Tool echo]\n{}" : "COPY-ARGUMENT"] {
                XCTAssertTrue(copied.contains(marker), marker)
            }
            try await retire(model, chat: chat, host: host)
            let rebound = try await collect(live, result: found)
            XCTAssertEqual(rebound, expected)
            let disk = ConversationContentSource.workspace(model, sessionID: chat.id)
            let saved = try await disk.search("", 0), diskText = try await collect(disk, result: saved)
            XCTAssertEqual(diskText, expected)
        }
    }
    func testLiveAndDiskSearchFindReasoningAndToolArguments() async throws {
        let (model, chat, host, _) = try await fixture()
        var live: [[String]] = []
        for query in ["COPY-REASONING", "COPY-ARGUMENT"] {
            let found = try await model.searchConversation(chat.id, query: query, start: 0)
            live.append(found.hits.map(\.id))
            XCTAssertEqual(found.hits.map(\.id), ["answer"], query)
        }
        try await retire(model, chat: chat, host: host)
        for (index, query) in ["COPY-REASONING", "COPY-ARGUMENT"].enumerated() {
            let found = try await model.searchConversation(chat.id, query: query, start: 0)
            XCTAssertEqual(found.hits.map(\.id), live[index], query)
        }
    }
    func testClosedRuntimePageRebindsBeforeUnloadAcknowledgement() async throws {
        for changed in [false, true] {
            let (model, chat, original, expected) = try await fixture()
            let live = try await original.request("session.content.search", sessionID: chat.id, params: ["retained": .bool(true)])
            var sent: [[String: WireValue]] = []
            let retiring = HostSupervisor(commandSender: { sent.append($0) })
            addTeardownBlock { @MainActor in try? await retiring.shutdownAndWait() }
            try await retiring.connect(cwd: model.root, state: model.root.appendingPathComponent("retiring-host"))
            let connection = try XCTUnwrap(retiring.connectionID), epoch = try XCTUnwrap(retiring.epoch)
            model.hosts[chat.workspaceID] = retiring
            defer { model.hosts[chat.workspaceID] = original }
            func reply(_ command: [String: WireValue], result: WireValue, ok: Bool) {
                retiring.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(epoch),
                    "commandId": command["commandId"] ?? .null, "ok": .bool(ok), "result": result]), connectionID: connection)
            }
            let source = ConversationContentSource.workspace(model, sessionID: chat.id)
            let searching = Task { try await source.search("", 0) }
            try await eventually("The live selection request arrived") { !sent.isEmpty }
            reply(sent.removeFirst(), result: live, ok: true)
            let found = try await searching.value
            if changed {
                let path = try XCTUnwrap(chat.path)
                let text = try String(contentsOfFile: path, encoding: .utf8).replacingOccurrences(of: "COPY-TEXT", with: "EDIT-TEXT")
                try Data(text.utf8).write(to: URL(fileURLWithPath: path))
            }
            var finished = false, rejected = 0
            let copying = Task { defer { finished = true }; return try await collect(source, result: found) }
            try await eventually("Copy settles after the retired runtime rejects its page") {
                while !sent.isEmpty {
                    let command = sent.removeFirst()
                    XCTAssertEqual(command["method"]?.string, "session.content.page")
                    XCTAssertTrue(retiring.isReady); XCTAssertTrue(model.opened.contains(chat.id))
                    rejected += 1
                    reply(command, result: .object(["code": .string("session_closed"), "message": .string("Session runtime is closed")]), ok: false)
                }
                return finished
            }
            XCTAssertGreaterThan(rejected, 0)
            if changed {
                do { _ = try await copying.value; XCTFail("Changed retained text was accepted") }
                catch { XCTAssertTrue(error.localizedDescription.contains("History changed"), error.localizedDescription) }
            } else { let copied = try await copying.value; XCTAssertEqual(copied, expected) }
        }
    }
    func testRecoveredOperationsCopyAndSearchIdenticallyAfterRetirement() async throws {
        let (model, chat, host, _) = try await fixture()
        _ = try await host.request("session.close", sessionID: chat.id)
        model.helperSessionDidUnload(chat.id)
        var parent = "final"
        for (id, kind, terminal) in [("unfinished-request", "requestLedger", Optional<String>.none),
                                      ("unfinished-compaction", "execution", nil),
                                      ("completed-request", "requestLedger", "completed"),
                                      ("failed-compaction", "execution", "failed")] {
            var timeline = ResponseTimeline.canonical([("status", id, nil, nil)], sourceID: id)
            timeline.terminal = terminal
            if terminal == nil { timeline.segments[0].state = "streaming" }
            let encoded = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(timeline))
            let row: WireValue = .object(["type": .string("message"), "id": .string(id), "parentId": .string(parent),
                "message": .object(["role": .string("system"), "content": .array([]), "nativeKind": .string(kind),
                    "nativeDetail": .string(id), "nativeReplayEligible": .bool(false), "nativeResponseTimeline": encoded])])
            try ContentSearchTests.append(JSONEncoder().encode(row) + Data([10]), to: try XCTUnwrap(chat.path))
            parent = id
        }
        _ = try await model.open(chat)
        let source = ConversationContentSource.workspace(model, sessionID: chat.id)
        let found = try await source.search("", 0), live = try await collect(source, result: found, last: found.total)
        for title in ["Request interrupted · no terminal receipt", "Compaction interrupted · no terminal receipt", "completed-request", "failed-compaction"] {
            XCTAssertTrue(live.contains("## " + title))
        }
        let query = "interrupted · no terminal receipt"
        let before = try await model.searchConversation(chat.id, query: query, start: 0)
        XCTAssertEqual(before.hits.map(\.id), ["unfinished-request", "unfinished-compaction"])
        try await retire(model, chat: chat, host: host)
        let saved = try await collect(source, result: found, last: found.total)
        XCTAssertEqual(saved, live)
        let after = try await model.searchConversation(chat.id, query: query, start: 0)
        XCTAssertEqual(after.hits.map(\.id), before.hits.map(\.id))
    }
    func testKeptCompactedSideRetainsCopyIdentityAfterRetirement() async throws {
        let (model, parent, host, _) = try await fixture()
        _ = try await host.request("session.close", sessionID: parent.id)
        model.helperSessionDidUnload(parent.id)
        let row: WireValue = .object(["type": .string("compaction"), "id": .string("summary"), "parentId": .string("final"),
            "summary": .string("INHERITED-SUMMARY"), "nativeKeptIDs": .array([.string("answer"), .string("receipt"), .string("final")]),
            "tokensBefore": .number(9000)])
        try ContentSearchTests.append(JSONEncoder().encode(row) + Data([10]), to: try XCTUnwrap(parent.path))
        _ = try await model.open(parent)
        let made = try await host.request("side.open", sessionID: parent.id, params: ["sideSessionId": .string("kept-side")])
        var side = ChatRecord(id: "kept-side", workspaceID: parent.workspaceID, title: "Side", profileID: parent.profileID)
        side.path = try XCTUnwrap(made.object?["path"]?.string)
        model.chats.append(side); try await model.store?.put(side, kind: "chat", id: side.id)
        _ = try await model.open(side)
        let journal = try String(contentsOfFile: try XCTUnwrap(side.path), encoding: .utf8)
        XCTAssertTrue(journal.contains("\"nativeKind\":\"compaction\""), "Exercise keepNow's message representation")
        let source = ConversationContentSource.workspace(model, sessionID: side.id)
        let found = try await source.search("", 0), live = try await collect(source, result: found, last: found.total)
        XCTAssertTrue(live.contains("## Compaction\n\nINHERITED-SUMMARY"))
        try await retire(model, chat: side, host: host)
        let saved = try await collect(source, result: found, last: found.total)
        XCTAssertEqual(saved, live)
    }
    func testTimelineCorpusCopiesAndHandsOffIdentically() async throws {
        let (model, chat, host, _) = try await fixture()
        _ = try await host.request("session.close", sessionID: chat.id)
        model.helperSessionDidUnload(chat.id)
        var empty = ResponseTimeline(); empty.finish("completed")
        let covered = ResponseTimeline.canonical([("text", "COVERED-ANSWER", nil, nil)], sourceID: "covered")
        var partial = covered; partial.segments[0].truncated = true; partial.omittedEvents = 1
        var unsupported = empty; unsupported.version = 99
        let corpus = [("covered", "COVERED-ANSWER", covered),
                      ("uncovered", "UNCOVERED-ANSWER", covered),
                      ("empty", "EMPTY-TIMELINE-ANSWER", empty),
                      ("partial", "FULL-PARTIAL-ANSWER", partial),
                      ("unsupported", "UNSUPPORTED-ANSWER", unsupported)]
        var parent = "final"
        for (id, answer, timeline) in corpus {
            let value = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(timeline))
            let row: WireValue = .object(["type": .string("message"), "id": .string(id), "parentId": .string(parent),
                "message": .object(["role": .string("assistant"), "content": .string(answer), "nativeResponseTimeline": value])])
            try ContentSearchTests.append(JSONEncoder().encode(row) + Data([10]), to: try XCTUnwrap(chat.path))
            parent = id
        }
        _ = try await model.open(chat)
        let source = ConversationContentSource.workspace(model, sessionID: chat.id)
        let found = try await source.search("", 0), live = try await collect(source, result: found, last: found.total)
        for (_, answer, _) in corpus { XCTAssertTrue(live.contains(answer), answer) }
        for query in ["UNCOVERED-ANSWER", "EMPTY-TIMELINE-ANSWER"] {
            let result = try await model.searchConversation(chat.id, query: query, start: 0)
            XCTAssertEqual(result.hits.count, 1, query)
        }
        try await retire(model, chat: chat, host: host)
        let saved = try await collect(source, result: found, last: found.total)
        XCTAssertEqual(saved, live)
        for query in ["UNCOVERED-ANSWER", "EMPTY-TIMELINE-ANSWER"] {
            let result = try await model.searchConversation(chat.id, query: query, start: 0)
            XCTAssertEqual(result.hits.count, 1, query)
        }
    }
    func testAdoptedCompactionProgressKeepsTheSameCopyIdentity() async throws {
        let (model, chat, host, _) = try await fixture()
        _ = try await host.request("session.close", sessionID: chat.id)
        model.helperSessionDidUnload(chat.id)
        var timeline = ResponseTimeline.canonical([("status", "CHECKPOINT-PROGRESS", nil, nil)], sourceID: "operation")
        timeline.finish("recorded")
        let encoded = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(timeline))
        let ids: WireValue = .array(["answer", "receipt", "final"].map(WireValue.string))
        let records: [WireValue] = [
            .object(["type": .string("message"), "id": .string("operation"), "parentId": .string("final"),
                "message": .object(["role": .string("system"), "content": .array([]), "nativeKind": .string("execution"),
                    "nativeOperationID": .string("operation"), "nativeDetail": .string("Compaction started"),
                    "nativeReplayEligible": .bool(false), "nativeResponseTimeline": encoded])]),
            .object(["type": .string("compaction"), "id": .string("summary"), "parentId": .string("operation"),
                "summary": .string("ADOPTED-SUMMARY"), "nativeKeptIDs": ids, "tokensBefore": .number(9000),
                "nativeCompactionVersion": .number(2), "nativeCompaction": .object(["version": .number(2),
                    "operationId": .string("operation"), "sourceIDs": ids, "keptIDs": ids, "protectedIDs": .array([])])])
        ]
        for record in records { try ContentSearchTests.append(JSONEncoder().encode(record) + Data([10]), to: try XCTUnwrap(chat.path)) }
        _ = try await model.open(chat)
        let source = ConversationContentSource.workspace(model, sessionID: chat.id)
        let found = try await source.search("", 0), live = try await collect(source, result: found, last: found.total)
        XCTAssertTrue(live.contains("Compaction · Checkpoint durably adopted"))
        try await retire(model, chat: chat, host: host)
        let saved = try await collect(source, result: found, last: found.total)
        XCTAssertEqual(saved, live)
        let matched = try await model.searchConversation(chat.id, query: "Checkpoint durably adopted", start: 0)
        XCTAssertEqual(matched.hits.map(\.id), ["operation"])
    }
    func testExistingSheetCopiesAndExportsAfterIdleRetirement() async throws {
        for exporting in [false, true] {
            let (model, chat, host, expected) = try await fixture()
            let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
            let sheet = ConversationContentView(model: model, sessionID: chat.id, pasteboard: pasteboard)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: ConversationContentView.size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = sheet; window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            try await eventually("The live selection is ready") { sheet.copyAll.isEnabled }
            let destination = model.root.appendingPathComponent("export.md"), previous = PiQuestion.shared.chooseFiles
            defer { PiQuestion.shared.chooseFiles = previous }
            if exporting {
                PiQuestion.shared.chooseFiles = { [destination] }
                // The export has captured its source, but is held before its chooser.
                let gate = AsyncGate(); var arrived = false
                model.toolOutputProducerStep = { _ in arrived = true; await gate.wait() }
                sheet.exportButton.onPress?()
                try await eventually("Export is held") { arrived }
                try await retire(model, chat: chat, host: host)
                await gate.open()
            } else {
                try await retire(model, chat: chat, host: host)
                sheet.lastField.value = 1
                sheet.copyRange.onPress?()
            }
            try await eventually("Copy/export settled") { sheet.copyAll.isEnabled }
            if exporting {
                XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
                if let bytes = try? Data(contentsOf: destination) { XCTAssertEqual(String(decoding: bytes, as: UTF8.self), expected + "## toolResult\n\nCOPY-RESULT\n\n## assistant\n\nCOPY-FINAL\n\n") }
            } else { XCTAssertEqual(pasteboard.string(forType: .string), expected) }
        }
    }
    func testIdleHandoffContinuesUnicodePagesAndRejectsChangedContent() async throws {
        for change in ["none", "content", "identity"] {
            let (model, chat, host, expected) = try await fixture()
            let source = ConversationContentSource.workspace(model, sessionID: chat.id)
            let found = try await source.search("", 0)
            let first = try await source.page(1, 1, .init(index: 1, offset: 0), found.revision)
            var cursor = try XCTUnwrap(first.next), text = first.text
            try await retire(model, chat: chat, host: host)
            let path = URL(fileURLWithPath: try XCTUnwrap(chat.path))
            if change == "content" {
                let bytes = try String(contentsOf: path, encoding: .utf8)
                try bytes.replacingOccurrences(of: "COPY-TEXT", with: "EDIT-TEXT").write(to: path, atomically: true, encoding: .utf8)
            } else if change == "identity" {
                var lines: [Data] = try Data(contentsOf: path).split(separator: UInt8(10)).map { Data($0) }
                var header = try JSONDecoder().decode(WireValue.self, from: lines[0]).object!
                header["id"] = .string("different-chat")
                lines[0] = try JSONEncoder().encode(header)
                try lines.reduce(into: Data()) { $0 += $1; $0.append(10) }.write(to: path, options: .atomic)
            }
            if change != "none" {
                do { _ = try await source.page(1, 1, cursor, found.revision); XCTFail("Accepted changed \(change)") }
                catch { }
            } else {
                while true {
                    let page = try await source.page(1, 1, cursor, found.revision)
                    text += page.text
                    guard let next = page.next else { break }; cursor = next
                }
                XCTAssertEqual(text, expected, "The handoff preserves UTF-16 offsets without duplicating a prefix")
            }
        }
    }
    func testCompactionAndEditedBranchesCopyIdenticallyAfterHandoff() async throws {
        for name in ["before", "after"] {
            let (model, chat, host, _) = try await fixture()
            let path = URL(fileURLWithPath: try XCTUnwrap(chat.path))
            _ = try await host.request("session.close", sessionID: chat.id)
            model.helperSessionDidUnload(chat.id)
            let saved = try Data(contentsOf: path).split(separator: 10).map { try JSONDecoder().decode(WireValue.self, from: Data($0)) }
            let marker = try XCTUnwrap(saved.first { $0.object?["customType"]?.string == "pi-app.native.v1" }?.object?["data"])
            var repo = URL(fileURLWithPath: #filePath); for _ in 0..<4 { repo.deleteLastPathComponent() }
            let source = try Data(contentsOf: repo.appendingPathComponent("fixtures/native/historical-edit-\(name).jsonl"))
            var rows = try source.split(separator: 10).map { try JSONDecoder().decode(WireValue.self, from: Data($0)).object! }
            rows[0]["id"] = .string(chat.id); rows[1]["data"] = marker
            var bytes = Data()
            for row in rows { bytes += try JSONEncoder().encode(row); bytes.append(10) }
            try bytes.write(to: path)
            _ = try await model.open(chat)
            let reader = ConversationContentSource.workspace(model, sessionID: chat.id)
            let found = try await reader.search("", 0), live = try await collect(reader, result: found, last: found.total)
            try await retire(model, chat: chat, host: host)
            let retained = try await collect(reader, result: found, last: found.total)
            XCTAssertEqual(retained, live, "\(name): compaction/edit and user display text must use the same copy format")
        }
    }
    func testAReplacementRuntimeCannotReuseTheSelectionsSequence() async throws {
        let (model, chat, host, _) = try await fixture()
        let reader = ConversationContentSource.workspace(model, sessionID: chat.id)
        let found = try await reader.search("", 0)
        let old = try await host.request("session.content.search", sessionID: chat.id, params: ["retained": .bool(true)])
        _ = try await host.request("session.close", sessionID: chat.id)
        model.helperSessionDidUnload(chat.id)
        let path = URL(fileURLWithPath: try XCTUnwrap(chat.path))
        let text = try String(contentsOf: path, encoding: .utf8)
        try text.replacingOccurrences(of: "COPY-TEXT", with: "EDIT-TEXT").write(to: path, atomically: true, encoding: .utf8)
        _ = try await model.open(chat)
        let current = try await host.request("session.content.search", sessionID: chat.id, params: ["retained": .bool(true)])
        XCTAssertEqual(old.object?["revision"], current.object?["revision"], "The replacement deliberately reuses counts and sequence")
        XCTAssertNotEqual(old.object?["incarnation"], current.object?["incarnation"])
        do { _ = try await collect(reader, result: found); XCTFail("A replacement runtime lent new content to the old selection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("History changed"), error.localizedDescription) }
    }
    func testCopySheetGallery() async throws {
        guard let folder = testEnvironment("PI_APP_CONVERSATION_COPY_GALLERY"), !folder.isEmpty else { throw XCTSkip("Set PI_APP_CONVERSATION_COPY_GALLERY to render copy sheets") }
        let (model, chat, _, _) = try await fixture()
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for (name, width, appearance) in [("light", 1080.0, NSAppearance.Name.aqua), ("dark", 1080.0, .darkAqua), ("narrow", 900.0, .aqua)] {
            let size = NSSize(width: width, height: 700), sheet = ConversationContentView(model: model, sessionID: chat.id)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance)
            window.contentView = sheet; window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            try await eventually("The gallery selection is ready") { sheet.copyAll.isEnabled }
            if window.firstResponder is NSText { window.makeFirstResponder(nil) }
            var previous: Data?, image: Data?
            try await eventually("The gallery frame has settled", poll: .milliseconds(60)) {
                sheet.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
                guard let data = try? PiKitParity.windowImage(window).representation(using: .png, properties: [:]) else { return false }
                defer { previous = data }
                guard data == previous else { return false }
                image = data; return true
            }
            try XCTUnwrap(image).write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }
}
