import XCTest
@testable import PiApp

/// Differential checks use the packaged helper and generated journals only.
@MainActor
final class CommittedHistoryTests: XCTestCase {
    func testRealHelperOffersMetadataSource() async throws {
        let fixture = try await fixture(rows: [row("u", "user", "Question"), row("a", "assistant", "Answer")])
        let source = try await fixture.host.request("session.history.source", sessionID: "history", params: ["version": .number(1)])
        XCTAssertEqual(source.object?["version"]?.number, 1)
        XCTAssertEqual(source.object?["sessionID"]?.string, "history")
        XCTAssertNil(source.object?["messages"], "The source contract carries metadata, never chat bodies")
        XCTAssertTrue(fixture.host.supportsCommittedHistory)
        try await fixture.host.shutdownAndWait()
        XCTAssertFalse(fixture.host.supportsCommittedHistory, "A retired connection cannot lend its capability to the next helper")
    }

    func testToolReceiptAcrossPageBoundaryMatchesRealHelper() async throws {
        var rows = [row("u", "user", "Question")]
        rows.append(["type": "message", "id": "issuer", "message": ["role": "assistant", "content": [
            ["type": "toolCall", "id": "call", "name": "read", "arguments": ["path": "fixture.txt"]]]]])
        for index in 0..<3000 { rows.append(row("work-\(index)", "assistant", "Work \(index)")) }
        rows.append(["type": "message", "id": "result", "message": ["role": "toolResult", "toolCallId": "call", "toolName": "read",
            "content": [["type": "text", "text": "Complete result beyond this page"]], "nativeToolStats": ["outcome": "completed", "durationMs": 12]]])
        rows.append(row("next", "user", "Next question"))
        let fixture = try await fixture(rows: rows)
        let helper = try ConversationHistoryPage(await fixture.host.request("session.history", sessionID: "history", params: ["version": .number(2), "edge": .string("start")]))
        let file = try await HistoryReader(indexDirectory: fixture.root).window(path: fixture.path, start: true)
        XCTAssertEqual(file.messages.map(\.id), helper.messages.map(\.id))
        XCTAssertFalse(helper.messages.contains { $0.id == "result" })
        XCTAssertEqual(file.messages.first { $0.id == "issuer" }?.tools, helper.messages.first { $0.id == "issuer" }?.tools)
    }

    struct Fixture { var root: URL; var host: HostSupervisor; var path: String; var profile: ProfileRecord }
    func fixture(rows: [[String: Any]], marker: String = "pi-app.native.v1", profile supplied: ProfileRecord? = nil) async throws -> Fixture {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("committed-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("state"), host = HostSupervisor()
        addTeardownBlock { try? await host.shutdownAndWait(); try? FileManager.default.removeItem(at: root) }
        var profile = supplied ?? ProfileRecord()
        if supplied == nil { profile.modelId = "fixture"; profile.baseUrl = "http://127.0.0.1:1/v1" }
        try await host.connect(cwd: root, state: state)
        _ = try await host.request("workspace.open", params: ["cwd": .string(root.path), "directory": .string(state.path), "mcp": .object(["servers": .object([:])])])
        let opened = try await host.request("session.open", sessionID: "history", params: ["profile": profile.wire, "apiKey": .string("synthetic-only"), "connectionTest": .bool(true)])
        let path = try XCTUnwrap(opened.object?["path"]?.string)
        try await host.shutdownAndWait()
        var data = try Data(contentsOf: URL(fileURLWithPath: path))
        if marker != "pi-app.native.v1" {
            data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "pi-app.native.v1", with: marker).utf8)
            try data.write(to: URL(fileURLWithPath: path))
        }
        var parent = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(data.split(separator: 10).last))) as? [String: Any])?["id"] as? String)
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); try file.seekToEnd()
        for source in rows {
            var record = source; record["parentId"] = parent
            var bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]); bytes.append(10)
            try file.write(contentsOf: bytes); parent = try XCTUnwrap(record["id"] as? String)
        }
        try file.close()
        // The parity journals are part of the index scanner's corpus.
        try HistoryIndexScanTests.assertJournalMatchesFrozenDecoding(path)
        try await host.connect(cwd: root, state: state)
        _ = try await host.request("workspace.open", params: ["cwd": .string(root.path), "directory": .string(state.path)])
        _ = try await host.request("session.open", sessionID: "history", params: ["profile": profile.wire, "apiKey": .string("synthetic-only"), "path": .string(path)])
        return Fixture(root: root, host: host, path: path, profile: profile)
    }

    func row(_ id: String, _ role: String, _ text: String) -> [String: Any] {
        ["type": "message", "id": id, "message": ["role": role, "content": [["type": "text", "text": text]]]]
    }
}
