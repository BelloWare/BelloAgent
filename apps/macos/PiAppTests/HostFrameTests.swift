import XCTest
@testable import PiApp

final class HostFrameTests: XCTestCase {
    func testSplitUnicodeAndMultipleFrames() throws {
        let bytes = Data("{\"v\":1,\"text\":\"🌍\\n漢字\"}\n{\"ok\":true}\n".utf8)
        var decoder = HostFrameDecoder()
        var frames: [[String: WireValue]] = []
        for byte in bytes { frames += try decoder.append(Data([byte])) }
        try decoder.finish()
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0]["text"]?.string, "🌍\n漢字")
        XCTAssertEqual(frames[1]["ok"], .bool(true))
    }
    func testCaptureChunksReassembleEscapesAndUnicodeOnlyAtTheFinalPage() throws {
        let packet: [String: WireValue] = ["type": .string("finish"), "metadata": .object(["raw": .string(String(repeating: "\u{01}🙂", count: 150_000))])]
        let bytes = try JSONEncoder().encode(packet), id = UUID().uuidString
        var reader = CapturePacketReader()
        for offset in stride(from: 0, to: bytes.count, by: 32 * 1024) {
            let end = min(bytes.count, offset + 32 * 1024)
            let result = try reader.accept(["chunk": .object(["packetId": .string(id), "offset": .number(Double(offset)),
                "bytes": .string(bytes.subdata(in: offset..<end).base64EncodedString()), "final": .bool(end == bytes.count)])])
            if end == bytes.count { XCTAssertEqual(result, packet) } else { XCTAssertNil(result) }
        }
        XCTAssertEqual(try reader.accept(["packet": .object(packet)]), packet)
    }
    func testCaptureChunksRejectGapsInterleavingAndMalformedFinalJSON() throws {
        let id = UUID().uuidString
        func chunk(_ offset: Int, id: String, final: Bool = false) -> [String: WireValue] {
            ["chunk": .object(["packetId": .string(id), "offset": .number(Double(offset)), "bytes": .string(Data("{".utf8).base64EncodedString()), "final": .bool(final)])]
        }
        var reader = CapturePacketReader()
        XCTAssertThrowsError(try reader.accept(chunk(1, id: id)))
        XCTAssertNil(try reader.accept(chunk(0, id: id)))
        XCTAssertThrowsError(try reader.accept(chunk(1, id: UUID().uuidString)))
        XCTAssertThrowsError(try reader.accept(["packet": .object([:])]))
        XCTAssertThrowsError(try reader.accept(chunk(1, id: id, final: true)))
        XCTAssertEqual(try reader.accept(["packet": .object([:])]), [:])
    }
    func testBoundedAndIncompleteFrames() throws {
        var decoder = HostFrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data(repeating: 32, count: HostFrameDecoder.maximum + 1)))
        decoder = HostFrameDecoder()
        _ = try decoder.append(Data("{".utf8))
        XCTAssertThrowsError(try decoder.finish())
        decoder = HostFrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([34, 255, 34, 10])))
    }
}
