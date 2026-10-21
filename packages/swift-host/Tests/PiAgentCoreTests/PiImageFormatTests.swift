import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PiAgentCore

/// Generated image fixtures for formats beyond pi's own. ImageIO encodes
/// most of them; it cannot encode WebP or AVIF, so those are built from
/// bytes here and checked against ImageIO before a test relies on them.
enum ImageFormatFixtures {
    /// A frame of noise tinted by `red`/`blue`, so a first frame is told
    /// from a second one and no fixture's bytes happen to be valid UTF-8.
    static func frame(width: Int, height: Int, red: Bool = true) -> CGImage {
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        pixels.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: p.count, by: 4) {
                p[i] = red ? 200 + p[i] % 56 : p[i] % 40
                p[i + 2] = red ? p[i + 2] % 40 : 200 + p[i + 2] % 56
                p[i + 3] = 255
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
    /// `frames` encoded as `type`, or nil when this macOS cannot encode it.
    static func encoded(_ type: String, _ frames: [CGImage], properties: [CFString: Any]? = nil,
                        frameProperties: [CFString: Any]? = nil) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, frames.count, nil) else { return nil }
        if let properties { CGImageDestinationSetProperties(destination, properties as CFDictionary) }
        for frame in frames { CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary?) }
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
    static func still(_ type: UTType, width: Int = 48, height: Int = 32) -> Data? {
        encoded(type.identifier, [frame(width: width, height: height)])
    }
    static func animatedGIF(width: Int = 24, height: Int = 16) -> Data {
        encoded(UTType.gif.identifier, [frame(width: width, height: height), frame(width: width, height: height, red: false)],
                properties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]],
                frameProperties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]])!
    }
    static func animatedPNG(width: Int = 24, height: Int = 16) -> Data {
        encoded(UTType.png.identifier, [frame(width: width, height: height), frame(width: width, height: height, red: false)],
                properties: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]],
                frameProperties: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1]])!
    }
    /// A 1 × 1 lossless WebP (VP8L).
    static let stillWebP = Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")!
    /// The same pixel as a two-frame animation: VP8X with the animation
    /// flag, ANIM, and two ANMF frames carrying the VP8L bitstream.
    static var animatedWebP: Data {
        func le(_ value: Int, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }) }
        func chunk(_ name: String, _ payload: Data) -> Data {
            Data(name.utf8) + le(payload.count, 4) + payload + (payload.count % 2 == 1 ? Data([0]) : Data())
        }
        let vp8l = stillWebP.subdata(in: 12..<stillWebP.count)
        let frame = chunk("ANMF", le(0, 3) + le(0, 3) + le(0, 3) + le(0, 3) + le(100, 3) + Data([0]) + vp8l)
        let body = Data("WEBP".utf8) + chunk("VP8X", Data([0x12, 0, 0, 0]) + le(0, 3) + le(0, 3))
            + chunk("ANIM", Data([255, 255, 255, 255, 0, 0])) + frame + frame
        return Data("RIFF".utf8) + le(body.count, 4) + body
    }
    /// A 2 × 2 AVIF; ImageIO decodes AVIF but cannot encode it.
    static let avif = Data(base64Encoded: "AAAAIGZ0eXBhdmlmAAAAAGF2aWZtaWYxbWlhZk1BMUIAAADybWV0YQAAAAAAAAAoaGRscgAAAAAAAAAAcGljdAAAAAAAAAAAAAAAAGxpYmF2aWYAAAAADnBpdG0AAAAAAAEAAAAeaWxvYwAAAABEAAABAAEAAAABAAABGgAAAB0AAAAoaWluZgAAAAAAAQAAABppbmZlAgAAAAABAABhdjAxQ29sb3IAAAAAamlwcnAAAABLaXBjbwAAABRpc3BlAAAAAAAAAAIAAAACAAAAEHBpeGkAAAAAAwgICAAAAAxhdjFDgQ0MAAAAABNjb2xybmNseAACAAIAAYAAAAAXaXBtYQAAAAAAAAABAAEEAQKDBAAAACVtZGF0EgAKCBgANogQEAwgMg8f8D///8WfhwB8+ErK42A=")!

    /// What ImageIO reads: type, frame count, first frame size.
    static func read(_ data: Data) -> (type: String, frames: Int, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (type, CGImageSourceGetCount(source), width, height)
    }
    /// The first frame's mean red and blue, 0–255.
    static func tint(_ data: Data) -> (red: Double, blue: Double)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var red = 0.0, blue = 0.0, count = image.width * image.height
        for i in 0..<count { red += Double(pixels[i * 4]); blue += Double(pixels[i * 4 + 2]) }
        count = max(1, count)
        return (red / Double(count), blue / Double(count))
    }
}

/// Owner request (0.1.130): OpenAI takes PNG, JPEG, WebP and non-animated
/// GIF, so an animated image reaches the model as its first frame, and the
/// read tool converts the still formats pi does not know.
final class PiImageFormatTests: XCTestCase {
    func testAnimatedGIFWebPAndPNGAreSentAsTheirFirstFrame() throws {
        let animations = [("image/gif", ImageFormatFixtures.animatedGIF(), true), ("image/png", ImageFormatFixtures.animatedPNG(), true),
                          ("image/webp", ImageFormatFixtures.animatedWebP, false)]
        for (mime, bytes, tinted) in animations {
            XCTAssertEqual(ImageFormatFixtures.read(bytes)?.frames, 2, "\(mime): the fixture is an animation")
            guard case .success(let processed) = PiImage.process(bytes, mimeType: mime) else { XCTFail("\(mime) was not processed"); continue }
            let sent = try XCTUnwrap(Data(base64Encoded: processed.data))
            let read = try XCTUnwrap(ImageFormatFixtures.read(sent))
            XCTAssertEqual(processed.mimeType, "image/png", mime)
            XCTAssertEqual(read.type, UTType.png.identifier, mime)
            XCTAssertEqual(read.frames, 1, "\(mime): a still image")
            XCTAssertEqual(processed.hints, ["[Image converted from animated \(mime) to image/png; only its first frame is shown.]"], mime)
            if tinted {
                let tint = try XCTUnwrap(ImageFormatFixtures.tint(sent))
                XCTAssertGreaterThan(tint.red, tint.blue + 100, "\(mime): the first (red) frame, not the second (blue) one")
            }
        }
        // Still GIF, WebP and PNG go as they are, as pi sends them.
        let stills: [(String, Data)] = [("image/gif", try XCTUnwrap(ImageFormatFixtures.still(.gif))),
                                        ("image/png", try XCTUnwrap(ImageFormatFixtures.still(.png))), ("image/webp", ImageFormatFixtures.stillWebP)]
        for (mime, bytes) in stills {
            XCTAssertEqual(PiImage.process(bytes, mimeType: mime), .success(.init(data: bytes.base64EncodedString(), mimeType: mime, hints: [])), mime)
        }
    }

    func testAnAnimatedAttachmentReachesTheModelAsItsFirstFrame() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        func attachment(_ name: String, _ data: Data, _ mime: String) throws -> JSON {
            let file = root.appendingPathComponent(name); try data.write(to: file)
            return ["path": JSON(file.path), "bytes": JSON(data.count), "sha256": JSON(sha256(data)), "mimeType": JSON(mime)]
        }
        let still = try XCTUnwrap(ImageFormatFixtures.still(.gif))
        let blocks = try loadImages([try attachment("moving.gif", ImageFormatFixtures.animatedGIF(), "image/gif"), try attachment("still.gif", still, "image/gif")])
        XCTAssertEqual(blocks.map { $0["type"].text }, ["image", "text", "image"])
        guard blocks.count == 3 else { return }
        XCTAssertEqual(blocks[0]["mimeType"].text, "image/png")
        XCTAssertEqual(ImageFormatFixtures.read(try XCTUnwrap(Data(base64Encoded: blocks[0]["data"].text ?? "")))?.frames, 1)
        XCTAssertEqual(blocks[1]["text"].text, "[Image converted from animated image/gif to image/png; only its first frame is shown.]")
        XCTAssertEqual(blocks[2], ["type": "image", "mimeType": "image/gif", "data": JSON(still.base64EncodedString())], "A still GIF is unchanged")
        // The request then carries a still PNG where the animation was.
        var raw = try fixtureProfile().raw; raw["input"] = ["text", "image"]
        let user = ChatMessage(role: "user", content: blocks)
        let body = try ProviderClient.requestBody(profile: Profile(raw), messages: [user], instructions: "", tools: [], sessionID: "s")
        let content = try XCTUnwrap(body["input"].list.last?["content"].list)
        XCTAssertEqual(content.compactMap { $0["image_url"].text?.prefix(15) }.map(String.init), ["data:image/png;", "data:image/gif;"])
    }

    func testAToolsAnimatedImageIsNormalizedToItsFirstFrame() throws {
        let gif = ImageFormatFixtures.animatedGIF()
        let blocks = PiImage.normalize([["type": "image", "mimeType": "image/gif", "data": JSON(gif.base64EncodedString())]])
        XCTAssertEqual(blocks.map { $0["type"].text }, ["image", "text"])
        XCTAssertEqual(blocks.first?["mimeType"].text, "image/png")
        XCTAssertEqual(blocks.last?["text"].text, "[Image converted from animated image/gif to image/png; only its first frame is shown.]")
    }

    func testReadingFormatsPiDoesNotKnowReturnsAConvertedImage() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let tools = NativeTools(cwd: root, outputs: root.appendingPathComponent("out"), mcp: MCPManager(cwd: root))
        var fixtures: [(name: String, data: Data, from: String)] = []
        for (type, from) in [(UTType.heic, "image/heic"), (.tiff, "image/tiff"), (UTType("public.jpeg-2000")!, "image/jp2"),
                             (UTType("com.microsoft.ico")!, "image/vnd.microsoft.icon"), (UTType("com.adobe.photoshop-image")!, "image/vnd.adobe.photoshop")] {
            guard let data = ImageFormatFixtures.still(type, width: type.identifier.contains("ico") ? 32 : 48, height: 32) else {
                print("SKIP read \(type.identifier): this macOS cannot encode it"); continue
            }
            fixtures.append(("image." + (type.preferredFilenameExtension ?? "bin"), data, from))
        }
        if ImageFormatFixtures.read(ImageFormatFixtures.avif) != nil { fixtures.append(("image.avif", ImageFormatFixtures.avif, "image/avif")) }
        else { print("SKIP read AVIF: this macOS cannot decode the fixture") }
        // Content decides, not the name: HEIC bytes in a file called .png.
        if let heic = ImageFormatFixtures.still(.heic) { fixtures.append(("mislabeled.png", heic, "image/heic")) }
        XCTAssertGreaterThanOrEqual(fixtures.count, 6)
        for fixture in fixtures {
            try fixture.data.write(to: root.appendingPathComponent(fixture.name))
            let expected = try XCTUnwrap(ImageFormatFixtures.read(fixture.data))
            let read = try await tools.invoke(ToolCall(id: "r", name: "read", arguments: ["path": JSON(fixture.name)]), readOnly: true)
            let content = read["content"].list
            XCTAssertEqual(content.first?["text"].text, "Read image file [image/png]\n[Image converted from \(fixture.from) to image/png.]", fixture.name)
            XCTAssertEqual(content.last?["mimeType"].text, "image/png", fixture.name)
            let sent = try XCTUnwrap(ImageFormatFixtures.read(try XCTUnwrap(Data(base64Encoded: content.last?["data"].text ?? ""))), fixture.name)
            XCTAssertEqual(sent.type, UTType.png.identifier, fixture.name)
            XCTAssertEqual([sent.width, sent.height], [expected.width, expected.height], fixture.name)
            XCTAssertEqual(read["isError"].flag, false, fixture.name)
        }
        // A large photo comes back within pi's 2,000 × 2,000 bound, with both hints.
        let large = try XCTUnwrap(ImageFormatFixtures.still(.heic, width: 3000, height: 1500))
        try large.write(to: root.appendingPathComponent("large.heic"))
        let read = try await tools.invoke(ToolCall(id: "l", name: "read", arguments: ["path": "large.heic"]), readOnly: true)
        let note = try XCTUnwrap(read["content"].list.first?["text"].text)
        XCTAssertTrue(note.contains("[Image converted from image/heic to image/"), note)
        XCTAssertTrue(note.contains("[Image: original 3000x1500, displayed at 2000x1000."), note)
        let sent = try XCTUnwrap(ImageFormatFixtures.read(try XCTUnwrap(Data(base64Encoded: read["content"].list.last?["data"].text ?? ""))))
        XCTAssertEqual([sent.width, sent.height], [2000, 1000])
    }

    /// A TIFF whose rows are black but its last, white one: its first bytes
    /// are zero bytes, which pass as UTF-8 text. Once the text read finds its
    /// binary bytes, the file is read as the image it is; text, and binary
    /// that is no image, keep pi's result.
    func testReadFindsAnImageWhoseFirstBytesPassAsText() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let tools = NativeTools(cwd: root, outputs: root.appendingPathComponent("out"), mcp: MCPManager(cwd: root))
        func darkTIFF(_ side: Int) throws -> Data {
            let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: side, height: 1))
            return try XCTUnwrap(ImageFormatFixtures.encoded(UTType.tiff.identifier, [try XCTUnwrap(context.makeImage())]))
        }
        let tiff = try darkTIFF(256)
        XCTAssertNotNil(String(data: tiff.prefix(4100), encoding: .utf8), "The fixture's first bytes pass as text")
        XCTAssertNil(String(data: tiff, encoding: .utf8), "The whole file does not")
        try tiff.write(to: root.appendingPathComponent("dark.tiff"))
        let read = try await tools.invoke(ToolCall(id: "d", name: "read", arguments: ["path": "dark.tiff"]), readOnly: true)
        XCTAssertEqual(read["content"].list.first?["text"].text, "Read image file [image/png]\n[Image converted from image/tiff to image/png.]")
        let sent = try XCTUnwrap(ImageFormatFixtures.read(try XCTUnwrap(Data(base64Encoded: read["content"].list.last?["data"].text ?? ""))))
        XCTAssertEqual([sent.width, sent.height], [256, 256])
        // Past 16 MiB it is refused as the large image it is.
        let large = try darkTIFF(2400)
        XCTAssertGreaterThan(large.count, 16 * 1024 * 1024)
        try large.write(to: root.appendingPathComponent("large-dark.tiff"))
        do { _ = try await tools.invoke(ToolCall(id: "l", name: "read", arguments: ["path": "large-dark.tiff"]), readOnly: true); XCTFail("read past 16 MiB") }
        catch let error as AgentError { XCTAssertEqual(error.code, "file_too_large") }
        // A long text whose tail is not UTF-8, and no image, stays binary.
        let log = Data(String(repeating: "Generated log line\n", count: 2000).utf8)
        try (log + Data([0xff, 0xfe, 0x00, 0x81])).write(to: root.appendingPathComponent("log.txt"))
        do { _ = try await tools.invoke(ToolCall(id: "b", name: "read", arguments: ["path": "log.txt"]), readOnly: true); XCTFail("a binary tail was read") }
        catch let error as AgentError { XCTAssertEqual(error.code, "binary_file") }
        // And text is still text.
        try log.write(to: root.appendingPathComponent("log.txt"))
        let text = try await tools.invoke(ToolCall(id: "t", name: "read", arguments: ["path": "log.txt", "limit": 2]), readOnly: true)
        XCTAssertEqual(text["content"].list.first?["text"].text, "Generated log line\nGenerated log line\n[Truncated. 2001 total lines; read another range.]")
    }

    func testReadKeepsTextPisOwnVerdictsAndUnreadableBinaryAsTheyWere() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let tools = NativeTools(cwd: root, outputs: root.appendingPathComponent("out"), mcp: MCPManager(cwd: root))
        // Text that begins like an image signature is still text.
        for text in ["icns are the macOS icon format\n", "II*\u{0} looks like TIFF\n", "8BPS looks like Photoshop\n"] {
            try Data(text.utf8).write(to: root.appendingPathComponent("note.txt"))
            let read = try await tools.invoke(ToolCall(id: "t", name: "read", arguments: ["path": "note.txt"]), readOnly: true)
            XCTAssertEqual(read["content"].list.first?["text"].text, text, text)
        }
        // Pi refuses an animated PNG as binary, and TGA (found by heuristics)
        // and bytes ImageIO types as TIFF but cannot read stay binary too.
        var state: UInt32 = 0x2545f491
        let junk = Data((0..<4000).map { _ in state = state &* 1_664_525 &+ 1_013_904_223; return UInt8(truncatingIfNeeded: state >> 24) })
        var binaries: [(String, Data)] = [("moving.png", ImageFormatFixtures.animatedPNG()), ("tiff-header.bin", Data([0x49, 0x49, 0x2a, 0x00]) + junk)]
        if let tga = ImageFormatFixtures.still(UTType("com.truevision.tga-image")!) { binaries.append(("image.tga", tga)) }
        for (name, data) in binaries {
            try data.write(to: root.appendingPathComponent(name))
            do { _ = try await tools.invoke(ToolCall(id: "b", name: "read", arguments: ["path": JSON(name)]), readOnly: true); XCTFail("\(name) was read") }
            catch let error as AgentError { XCTAssertEqual(error.code, "binary_file", name) }
        }
    }

    /// For the record, on demand: what the helper sends for each converted
    /// copy `ImageFormatImportTests.testMeasureConvertedPhotos` saved.
    func testMeasureWhatTheHelperSends() throws {
        guard let path = ProcessInfo.processInfo.environment["PI_IMAGE_MEASURE"] else { throw XCTSkip("Set PI_IMAGE_MEASURE") }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".stored.png") }.sorted { $0.path < $1.path }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let data = try Data(contentsOf: file), started = ContinuousClock.now
            guard case .success(let sent) = PiImage.process(data, mimeType: "image/png") else { XCTFail(file.lastPathComponent); continue }
            let elapsed = ContinuousClock.now - started, image = ImageFormatFixtures.read(Data(base64Encoded: sent.data) ?? Data())
            print("SENDS \(file.lastPathComponent): \(data.count) bytes → \(sent.mimeType) \(image?.width ?? 0)x\(image?.height ?? 0), \(sent.data.utf8.count) base64 bytes, in \(elapsed); \(sent.hints)")
        }
    }
}
