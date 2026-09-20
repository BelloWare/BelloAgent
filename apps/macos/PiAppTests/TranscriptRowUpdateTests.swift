import XCTest
@testable import PiApp

@MainActor private final class RowUpdateCommandLog { var frames: [[String: WireValue]] = [] }

/// The app's side of the helper's row updates: what it asks for, what it does
/// with what comes back, and how it recovers when an update does not fit.
final class TranscriptRowUpdateTests: XCTestCase {
    private func page(_ count: Int, streaming: String? = nil) -> [TranscriptMessage] {
        var rows = (0..<count).map { TranscriptMessage(id: "m\($0)", role: $0.isMultiple(of: 2) ? "user" : "assistant", text: "Row \($0)") }
        if let streaming { rows.append(TranscriptMessage(id: "stream:live", role: "assistant", text: streaming, thinking: "", state: "streaming")) }
        return rows
    }

    func testAppendedTokensExtendTheRowTheDisplayAlreadyHolds() throws {
        let held = page(3, streaming: "Partial")
        let applied = try XCTUnwrap(TranscriptRowUpdates.apply(.object(["base": .string("r:1"), "rows": .array([]),
            "appends": .array([.object(["id": .string("stream:live"), "text": .string(" answer"), "thinking": .string("why")])])]), to: held))
        XCTAssertEqual(applied.count, 4)
        XCTAssertEqual(applied.last?.text, "Partial answer")
        XCTAssertEqual(applied.last?.thinking, "why")
        XCTAssertEqual(applied.dropLast().map(\.text), held.dropLast().map(\.text), "Settled rows must be reused, not rebuilt")
    }

    func testChangedRowsAndANewOrderReplaceOnlyWhatMoved() throws {
        let held = page(3, streaming: "Partial")
        let settled: WireValue = .object(["id": .string("a1"), "role": .string("assistant"), "text": .string("Partial answer"),
                                          "thinking": .string(""), "tools": .array([]), "state": .string("complete"), "truncated": .bool(false)])
        let applied = try XCTUnwrap(TranscriptRowUpdates.apply(.object(["base": .string("r:1"), "appends": .array([]),
            "rows": .array([settled]), "order": .array([.string("m0"), .string("m1"), .string("m2"), .string("a1")])]), to: held))
        XCTAssertEqual(applied.map(\.id), ["m0", "m1", "m2", "a1"])
        XCTAssertEqual(applied.last?.text, "Partial answer")
        XCTAssertEqual(applied.last?.state, "complete")
    }

    func testAnUpdateThatDoesNotFitTheHeldPageAsksForAResync() {
        let held = page(3)
        XCTAssertNil(TranscriptRowUpdates.apply(.object(["appends": .array([.object(["id": .string("missing"), "text": .string("x")])])]), to: held),
                     "Appending to a row this display never received cannot be guessed")
        XCTAssertNil(TranscriptRowUpdates.apply(.object(["order": .array([.string("m0"), .string("unknown")])]), to: held),
                     "An order naming a row this display never received cannot be assembled")
        XCTAssertNil(TranscriptRowUpdates.apply(.string("not an update"), to: held))
    }

    @MainActor func testRefreshAsksForUpdatesOnlyWithAHeldPageAndResyncsWhenOneDoesNotFit() async throws {
        let root = URL(fileURLWithPath: scratchBase())
            .appendingPathComponent("row-updates-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "chat", workspaceID: "project", title: "Chat", path: nil, profileID: "profile")
        let view = SessionDisplay(id: chat.id)
        view.pageStartEnsured = true
        model.chats = [chat]; model.displays[chat.id] = view; model.selectedID = chat.id; model.selected = view
        let commands = RowUpdateCommandLog(), host = HostSupervisor(commandSender: { commands.frames.append($0) })
        try await host.connect(cwd: root, state: root.appendingPathComponent("host"))
        model.hosts[chat.workspaceID] = host; model.opened.insert(chat.id)
        defer { host.shutdown() }
        func wait(_ condition: @escaping () -> Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) async throws {
            for _ in 0..<4000 { if condition() { return }; try await Task.sleep(for: .milliseconds(1)) }
            XCTFail("Timed out waiting for " + what, file: file, line: line)
        }
        func reply(_ index: Int, _ result: [String: WireValue]) throws {
            let connection = try XCTUnwrap(host.connectionID), epoch = try XCTUnwrap(host.epoch)
            host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(epoch),
                                 "commandId": try XCTUnwrap(commands.frames[index]["commandId"]), "ok": .bool(true), "result": .object(result)]),
                         connectionID: connection)
        }
        func params(_ index: Int) -> [String: WireValue] { commands.frames[index]["params"]?.object ?? [:] }
        let status: [String: WireValue] = ["state": .string("running"), "runStatus": .string("running"), "commands": .array([])]

        model.refresh(chat.id)
        try await wait({ commands.frames.count == 1 }, "the first read")
        XCTAssertNil(params(0)["messageDelta"], "Nothing to update before a page has arrived")
        var result = status
        result["seq"] = .number(1); result["displayRevision"] = .string("host:1")
        result["messages"] = .array([.object(["id": .string("m0"), "role": .string("user"), "text": .string("Question"), "thinking": .string(""), "tools": .array([]), "state": .string("complete"), "truncated": .bool(false)]),
                                     .object(["id": .string("stream:live"), "role": .string("assistant"), "text": .string("Part"), "thinking": .string(""), "tools": .array([]), "state": .string("streaming"), "truncated": .bool(false)])])
        try reply(0, result)
        try await wait({ view.projectionRevision == "host:1" }, "the first page")
        XCTAssertEqual(view.messages.map(\.id), ["m0", "stream:live"])

        model.refresh(chat.id)
        try await wait({ commands.frames.count == 2 }, "the second read")
        XCTAssertEqual(params(1)["messageDelta"], .bool(true), "A held page is asked about, not asked for")
        XCTAssertEqual(params(1)["displayRevision"], .string("host:1"))
        var update = status
        update["seq"] = .number(2); update["displayRevision"] = .string("host:2")
        update["messageDelta"] = .object(["base": .string("host:1"), "rows": .array([]),
                                          "appends": .array([.object(["id": .string("stream:live"), "text": .string("ial answer"), "thinking": .string("")])])])
        try reply(1, update)
        try await wait({ view.messages.last?.text == "Partial answer" }, "the applied update")
        XCTAssertEqual(view.messages.first?.text, "Question", "A settled row must survive an update that does not name it")
        XCTAssertEqual(view.projectionRevision, "host:2")

        model.refresh(chat.id)
        try await wait({ commands.frames.count == 3 }, "the third read")
        var broken = status
        broken["seq"] = .number(3); broken["displayRevision"] = .string("host:3")
        broken["messageDelta"] = .object(["base": .string("host:2"), "rows": .array([]),
                                          "appends": .array([.object(["id": .string("never-seen"), "text": .string("!")])])])
        try reply(2, broken)
        try await wait({ commands.frames.count == 4 }, "the resync read")
        XCTAssertNil(params(3)["displayRevision"], "A page that could not be updated must be asked for in full")
        XCTAssertNil(params(3)["messageDelta"])
        XCTAssertEqual(view.messages.last?.text, "Partial answer", "The page on screen stays until the resync lands")
        try await host.shutdownAndWait()
    }
}
