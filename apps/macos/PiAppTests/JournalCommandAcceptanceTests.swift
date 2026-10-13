import XCTest
@testable import PiApp

final class JournalCommandAcceptanceTests: XCTestCase {
    func testLargeRecordsSearchEachByteOnlyOnce() async throws {
        let root = scratchRoot("acceptance-scan"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("chat.jsonl")
        let large: WireValue = .object(["type": .string("message"), "id": .string("image"), "message": .object(["role": .string("assistant"), "content": .string(String(repeating: "x", count: 8 * 1024 * 1024))])])
        var bytes = try JSONEncoder().encode(large); bytes.append(10)
        bytes.append(Data("{\"type\":\"message\",\"id\":\"turn\",\"message\":{\"role\":\"user\"}}\n".utf8)); try bytes.write(to: path)
        let reader = HistoryReader(), intent = CommandIntent(id: "command", sessionID: "chat", turnID: "turn", text: "", state: "intent")
        let accepted = try await reader.acceptedCommands(in: path.path, intents: [intent])
        XCTAssertEqual(accepted, [intent.id])
        let searched = await reader.acceptanceScannedBytes
        XCTAssertLessThanOrEqual(searched, bytes.count * 2, "A large JSONL record must not rescan its prefix for every 64 KiB chunk")
    }
    func testChunkBoundaryNewlinesAndIncompleteTail() async throws {
        let root = scratchRoot("acceptance-boundaries"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("chat.jsonl"), reader = HistoryReader()
        let intents = ["a", "b", "c"].map { CommandIntent(id: $0, sessionID: "chat", turnID: $0, text: "", state: "intent") }
        func row(_ id: String) -> Data { Data("{\"type\":\"message\",\"id\":\"\(id)\",\"message\":{\"role\":\"user\"}}".utf8) }
        for offset in [65_535, 65_536, 65_537] {
            var bytes = row("a"); bytes.append(Data(repeating: 32, count: offset - bytes.count)); bytes.append(10)
            bytes.append(10); bytes.append(row("b")); bytes.append(10); bytes.append(row("c"))
            try bytes.write(to: path)
            let accepted = try await reader.acceptedCommands(in: path.path, intents: intents)
            let searched = await reader.acceptanceScannedBytes
            XCTAssertEqual(accepted, ["a", "b"], "A partial final record is not durable acceptance")
            XCTAssertEqual(searched, bytes.count)
        }
    }
}
