import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PiAgentCore

/// Pi's read tool returns an image file as an image (read.ts), found by its
/// bytes the way pi's detectSupportedImageMimeType finds it.
final class PiReadImageTests: XCTestCase {
    private func png(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); CGImageDestinationFinalize(destination)
        return data as Data
    }
    private func chunk(_ type: String, _ length: Int) -> Data {
        var bytes = Data([UInt8(length >> 24 & 0xff), UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff), UInt8(length & 0xff)])
        bytes.append(Data(type.utf8)); bytes.append(Data(count: length + 4))
        return bytes
    }

    func testReadingAnImageFileReturnsTheImageWithPisNote() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let tools = NativeTools(cwd: root, outputs: root.appendingPathComponent("out"), mcp: MCPManager(cwd: root))
        try png(width: 40, height: 30).write(to: root.appendingPathComponent("shot.png"))
        let read = try await tools.invoke(ToolCall(id: "r", name: "read", arguments: ["path": "shot.png"]), readOnly: true)
        let content = read["content"].list
        XCTAssertEqual(content.first?["text"].text, "Read image file [image/png]")
        XCTAssertEqual(content.last?["type"].text, "image"); XCTAssertEqual(content.last?["mimeType"].text, "image/png")
        XCTAssertNotNil(Data(base64Encoded: content.last?["data"].text ?? ""))
        // A large image comes back within pi's 2000 × 2000 bound, with pi's hint.
        try png(width: 3000, height: 1500).write(to: root.appendingPathComponent("big.png"))
        let big = try await tools.invoke(ToolCall(id: "b", name: "read", arguments: ["path": "big.png"]), readOnly: true)
        XCTAssertTrue(big["content"].list.first?["text"].text?.contains("original 3000x1500, displayed at 2000x1000") == true, String(big.encoded().prefix(300)))
        // Any other binary file is still refused.
        try Data([0, 159, 146, 150, 0, 1]).write(to: root.appendingPathComponent("blob.bin"))
        do { _ = try await tools.invoke(ToolCall(id: "x", name: "read", arguments: ["path": "blob.bin"]), readOnly: true); XCTFail("A binary file was read as text") }
        catch let error as AgentError { XCTAssertEqual(error.code, "binary_file") }
    }

    func testImageTypesAreFoundByTheirBytesAsPiFindsThem() {
        XCTAssertEqual(PiImage.sniff(png(width: 2, height: 2)), "image/png")
        XCTAssertEqual(PiImage.sniff(Data([0xff, 0xd8, 0xff, 0xe0, 0, 0])), "image/jpeg")
        XCTAssertNil(PiImage.sniff(Data([0xff, 0xd8, 0xff, 0xf7, 0, 0])), "JPEG-LS is not a supported image")
        XCTAssertEqual(PiImage.sniff(Data("GIF89a".utf8)), "image/gif")
        XCTAssertEqual(PiImage.sniff(Data("RIFF\0\0\0\0WEBPVP8 ".utf8)), "image/webp")
        XCTAssertNil(PiImage.sniff(Data("hello".utf8)))
        // An animated PNG (acTL before IDAT) is not a supported image.
        let signature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        XCTAssertNil(PiImage.sniff(signature + chunk("IHDR", 13) + chunk("acTL", 8) + chunk("IDAT", 1)))
        XCTAssertEqual(PiImage.sniff(signature + chunk("IHDR", 13) + chunk("IDAT", 1)), "image/png")
        // A BMP with a sound header, and one whose pixel data overlaps its header.
        func bmp(pixels: UInt32) -> Data {
            var bytes = Data("BM".utf8)
            for value: UInt32 in [70, 0, pixels, 40, 2, 2] { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
            for value: UInt16 in [1, 24] { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
            return bytes + Data(count: 24)
        }
        XCTAssertEqual(PiImage.sniff(bmp(pixels: 54)), "image/bmp")
        XCTAssertNil(PiImage.sniff(bmp(pixels: 20)))
    }
}
