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
