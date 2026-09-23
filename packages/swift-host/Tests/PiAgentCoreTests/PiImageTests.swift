import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PiAgentCore

/// A PNG of the given size with a gradient, so it neither compresses to
/// nothing nor carries an orientation.
private func png(width: Int, height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for x in stride(from: 0, to: width, by: 50) {
        context.setFillColor(red: CGFloat(x % 255) / 255, green: CGFloat((x / 3) % 255) / 255, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: x, y: 0, width: 50, height: height))
    }
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
}
private func size(_ base64: String) -> (Int, Int)? {
    guard let data = Data(base64Encoded: base64), let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
    return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
}

/// Returns a screenshot beside its caption, as an MCP tool does.
private actor ScreenshotTool: ToolExecuting {
    let image: Data
    init(image: Data) { self.image = image }
    func definitions(readOnly: Bool) -> [ToolDefinition] { [ToolDefinition("screenshot", "Capture the screen", ["type": "object"])] }
    func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON {
        ["content": [["type": "text", "text": "Screenshot taken"], ["type": "image", "mimeType": "image/png", "data": JSON(image.base64EncodedString())]], "isError": false]
    }
}

final class PiImageTests: XCTestCase {
    func testAnAttachmentPastPiLimitsIsResizedWithPiHint() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let data = png(width: 3000, height: 1200), file = root.appendingPathComponent("wide.png")
        try data.write(to: file)
        let attachment: JSON = ["path": JSON(file.path), "bytes": JSON(data.count), "sha256": JSON(sha256(data)), "mimeType": "image/png"]
        let blocks = try loadImages([attachment])
        XCTAssertEqual(blocks.count, 2, "The image, then pi's dimension note")
        XCTAssertEqual(blocks.first?["type"].text, "image")
        let resized = try XCTUnwrap(size(XCTUnwrap(blocks.first?["data"].text)))
        XCTAssertEqual(resized.0, 2000); XCTAssertEqual(resized.1, 800)
        XCTAssertEqual(blocks.last?["text"].text, "[Image: original 3000x1200, displayed at 2000x800. Multiply coordinates by 1.50 to map to original image.]")
    }

    func testAnImageWithinPiLimitsIsSentAsItIs() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let data = png(width: 400, height: 300), file = root.appendingPathComponent("small.png")
        try data.write(to: file)
        let attachment: JSON = ["path": JSON(file.path), "bytes": JSON(data.count), "sha256": JSON(sha256(data)), "mimeType": "image/png"]
        XCTAssertEqual(try loadImages([attachment]), [["type": "image", "mimeType": "image/png", "data": JSON(data.base64EncodedString())]])
    }

    func testAToolsImageReachesTheModelAsPiSendsIt() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let image = png(width: 2400, height: 600)
        var raw = try fixtureProfile().raw; raw["input"] = ["text", "image"]
        let call = ToolCall(id: "call_1", name: "screenshot", arguments: [:])
        var first = ModelReply(message: ChatMessage(role: "assistant", content: [["type": "toolCall", "id": "call_1", "name": "screenshot", "arguments": [:]]]), calls: [call])
        first.usage = ["input": 10, "output": 5]
        let client = ScriptClient([first, answer("I see the screen.")])
        let session = try AgentSession(id: "images", profile: Profile(raw), apiKey: "k", cwd: root, directory: root.appendingPathComponent("state"), readOnly: true,
                                       resources: Resources(cwd: root, home: root), client: client, tools: ScreenshotTool(image: image), traces: TraceStore(), autoCompaction: false)
        _ = try await session.submit(Submission(commandID: "c", turnID: "t", text: "Look at the screen"), steer: false)
        try await eventually { !(await session.isRunning) }
        let requests = await client.requests
        let result = try XCTUnwrap(requests.last?.last { $0.role == "toolResult" })
        let body = try ProviderClient.requestBody(profile: Profile(raw), messages: [try XCTUnwrap(requests.last?.first { $0.role == "assistant" }), result], instructions: "", tools: [], sessionID: "s")
        let output = try XCTUnwrap(body["input"].list.last?["output"].list)
        XCTAssertEqual(output.first, ["type": "input_text", "text": "Screenshot taken\n[Image: original 2400x600, displayed at 2000x500. Multiply coordinates by 1.20 to map to original image.]"])
        XCTAssertEqual(output.last?["type"].text, "input_image"); XCTAssertEqual(output.last?["detail"].text, "auto")
        let sent = try XCTUnwrap(output.last?["image_url"].text?.split(separator: ",").last.map(String.init))
        XCTAssertEqual(size(sent)?.0, 2000)
        await session.close()
    }
}
