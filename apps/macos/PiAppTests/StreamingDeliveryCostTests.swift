import XCTest
import Combine
@testable import PiApp

@MainActor private final class DeliveryCommandLog { var frames: [[String: WireValue]] = [] }

/// What one streamed token costs the app between the pipe and the transcript
/// document: decoding the frame, projecting the page, regrouping its blocks
/// and publishing it. Printed as PERF lines; the asserts only pin the budget
/// the main actor has, so a slow machine does not fail the suite on noise.
final class StreamingDeliveryCostTests: XCTestCase {
    static let rowCount = 300
    /// A row shaped like the helper's display projection.
    private static func row(_ index: Int) -> WireValue {
        .object(["id": .string("m\(index)"), "role": .string(index.isMultiple(of: 2) ? "user" : "assistant"),
                 "text": .string("Row \(index). " + String(repeating: "Keep this conversation's exact native layout and selectable text. ", count: 8)),
                 "thinking": .string(""), "tools": .array([]), "state": .string("complete"), "truncated": .bool(false),
                 "timestamp": .number(Double(index) * 1000), "nativeTurn": .string("m\(index - index % 2)")])
    }
    private static func page(streaming text: String?) -> [WireValue] {
        var rows = (0..<rowCount).map(row)
        if let text {
            rows.append(.object(["id": .string("stream:live"), "role": .string("assistant"), "text": .string(text),
                                 "thinking": .string(""), "tools": .array([]), "state": .string("streaming"), "truncated": .bool(false)]))
        }
        return rows
    }
    private static func decoded(_ rows: [WireValue]) -> [TranscriptMessage] {
        (try? JSONDecoder().decode([TranscriptMessage].self, from: JSONEncoder().encode(WireValue.array(rows)))) ?? []
    }

    /// The stages a delta passes through, each timed on its own.
    func testPerDeltaStageCosts() throws {
        let rounds = 60
        var text = ""
        var previous = Self.decoded(Self.page(streaming: ""))
        var items = TranscriptActivity.blocks(of: previous)
        var decode = 0.0, encodeFrame = 0.0, decodeFrame = 0.0, merge = 0.0, group = 0.0
        var patchedCount = 0
        for index in 0..<rounds {
            text += "token-\(index) "
            let rows = Self.page(streaming: text)
            let frame: [String: WireValue] = ["v": .number(1), "kind": .string("reply"), "commandId": .string("c"),
                                              "ok": .bool(true), "result": .object(["messages": .array(rows), "displayRevision": .string("r:\(index)")])]
            var start = ProcessInfo.processInfo.systemUptime
            let bytes = try JSONEncoder().encode(frame)
            encodeFrame += ProcessInfo.processInfo.systemUptime - start

            var decoder = HostFrameDecoder()
            start = ProcessInfo.processInfo.systemUptime
            _ = try decoder.append(bytes + Data([10]))
            decodeFrame += ProcessInfo.processInfo.systemUptime - start

            start = ProcessInfo.processInfo.systemUptime
            var page = Self.decoded(rows)
            decode += ProcessInfo.processInfo.systemUptime - start

            start = ProcessInfo.processInfo.systemUptime
            page = TranscriptPaging.merge(previous: previous, live: page)
            let changed = previous != page
            merge += ProcessInfo.processInfo.systemUptime - start
            XCTAssertTrue(changed)

            start = ProcessInfo.processInfo.systemUptime
            if let patch = TranscriptActivity.patched(items, from: previous, to: page) { items = patch; patchedCount += 1 }
            else { items = TranscriptActivity.blocks(of: page) }
            group += ProcessInfo.processInfo.systemUptime - start
            previous = page
        }
        let each = 1000.0 / Double(rounds)
        print(String(format: "PERF delta stages (%d rows): frame encode %.3f ms, frame decode %.3f ms, page decode %.3f ms, merge+compare %.3f ms, regroup %.3f ms, patched %d/%d",
                     Self.rowCount, encodeFrame * each, decodeFrame * each, decode * each, merge * each, group * each, patchedCount, rounds))
    }

    /// The same delta as a row update: the frame the helper now sends, the
    /// cost of decoding it and applying it to the page already held.
    func testPerDeltaStageCostsWithRowUpdates() throws {
        let rounds = 60
        var text = ""
        var held = Self.decoded(Self.page(streaming: ""))
        var previous = held
        var items = TranscriptActivity.blocks(of: previous)
        var encodeFrame = 0.0, decodeFrame = 0.0, applyUpdate = 0.0, merge = 0.0, group = 0.0
        var patchedCount = 0, frameBytes = 0
        for index in 0..<rounds {
            let token = "token-\(index) "
            text += token
            let update: WireValue = .object(["base": .string("r:\(index)"), "rows": .array([]),
                                             "appends": .array([.object(["id": .string("stream:live"), "text": .string(token), "thinking": .string("")])])])
            let frame: [String: WireValue] = ["v": .number(1), "kind": .string("reply"), "commandId": .string("c"),
                                              "ok": .bool(true), "result": .object(["messageDelta": update, "displayRevision": .string("r:\(index + 1)")])]
            var start = ProcessInfo.processInfo.systemUptime
            let bytes = try JSONEncoder().encode(frame)
            encodeFrame += ProcessInfo.processInfo.systemUptime - start
            frameBytes += bytes.count

            var decoder = HostFrameDecoder()
            start = ProcessInfo.processInfo.systemUptime
            _ = try decoder.append(bytes + Data([10]))
            decodeFrame += ProcessInfo.processInfo.systemUptime - start

            start = ProcessInfo.processInfo.systemUptime
            let applied = TranscriptRowUpdates.apply(update, to: held)
            applyUpdate += ProcessInfo.processInfo.systemUptime - start
            held = try XCTUnwrap(applied)

            start = ProcessInfo.processInfo.systemUptime
            let page = TranscriptPaging.merge(previous: previous, live: held)
            let changed = previous != page
            merge += ProcessInfo.processInfo.systemUptime - start
            XCTAssertTrue(changed)

            start = ProcessInfo.processInfo.systemUptime
            if let patch = TranscriptActivity.patched(items, from: previous, to: page) { items = patch; patchedCount += 1 }
            else { items = TranscriptActivity.blocks(of: page) }
            group += ProcessInfo.processInfo.systemUptime - start
            previous = page
        }
        let each = 1000.0 / Double(rounds)
        print(String(format: "PERF delta stages with row updates (%d rows): frame %d bytes, encode %.3f ms, decode %.3f ms, apply %.3f ms, merge+compare %.3f ms, regroup %.3f ms, patched %d/%d",
                     Self.rowCount, frameBytes / rounds, encodeFrame * each, decodeFrame * each, applyUpdate * each, merge * each, group * each, patchedCount, rounds))
        XCTAssertEqual(held.last?.text, text)
        XCTAssertLessThan((applyUpdate + merge + group) * each, releaseBudget(0.001) * 1_000,
                          "Decoding, applying and regrouping a token must stay under a millisecond in Release")
    }

    /// The real path: a reply lands on the transport and the conversation
    /// publishes its page. Measures the main actor's own occupancy.
    @MainActor func testRefreshRoundTripOccupancy() async throws {
        let root = URL(fileURLWithPath: scratchBase())
            .appendingPathComponent("delivery-cost-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "chat", workspaceID: "project", title: "Chat", path: nil, profileID: "profile")
        let view = SessionDisplay(id: chat.id)
        view.pageStartEnsured = true
        model.chats = [chat]; model.displays[chat.id] = view; model.selectedID = chat.id; model.selected = view
        let commands = DeliveryCommandLog(), host = HostSupervisor(commandSender: { commands.frames.append($0) })
        try await host.connect(cwd: root, state: root.appendingPathComponent("host"))
        model.hosts[chat.workspaceID] = host; model.opened.insert(chat.id)
        defer { host.shutdown() }

        var published: [Double] = []
        var sent = 0.0
        let token = view.transcriptChanges.dropFirst().sink { _ in published.append(ProcessInfo.processInfo.systemUptime - sent) }
        defer { token.cancel() }

        var text = ""
        var rounds = 0
        let rest = 40
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<rest {
            text += "token-\(index) "
            model.refresh(chat.id)
            for _ in 0..<4000 where commands.frames.count <= index { try await Task.sleep(for: .milliseconds(1)) }
            guard commands.frames.count > index else { break }
            let connection = try XCTUnwrap(host.connectionID), epoch = try XCTUnwrap(host.epoch)
            var result: [String: WireValue] = ["seq": .number(Double(index)), "state": .string("running"), "runStatus": .string("running"),
                                               "displayRevision": .string("r:\(index)"), "commands": .array([])]
            // The first read is a whole page; after that the helper sends the
            // tokens that arrived, exactly as the running helper does.
            if index == 0 { result["messages"] = .array(Self.page(streaming: text)) }
            else {
                result["messageDelta"] = .object(["base": .string("r:\(index - 1)"), "rows": .array([]),
                                                  "appends": .array([.object(["id": .string("stream:live"), "text": .string("token-\(index) "), "thinking": .string("")])])])
            }
            result["before"] = .null
            sent = ProcessInfo.processInfo.systemUptime
            host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(epoch),
                                 "commandId": try XCTUnwrap(commands.frames[index]["commandId"]), "ok": .bool(true), "result": .object(result)]),
                         connectionID: connection)
            for _ in 0..<4000 where published.count <= index { try await Task.sleep(for: .milliseconds(1)) }
            rounds += 1
        }
        let wall = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let latencies = published.sorted()
        print(String(format: "PERF refresh round trip (%d rows, %d deltas): reply to published median %.2f ms, max %.2f ms; wall per delta %.2f ms",
                     Self.rowCount, rounds, latencies.isEmpty ? 0 : latencies[latencies.count / 2] * 1000, (latencies.last ?? 0) * 1000, wall / Double(max(1, rounds))))
        XCTAssertEqual(rounds, rest)
        XCTAssertEqual(view.messages.last?.text, text)
    }
}
