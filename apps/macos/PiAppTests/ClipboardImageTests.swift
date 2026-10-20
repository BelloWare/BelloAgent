import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PiApp

final class ClipboardImageTests: XCTestCase {
    static func image(width: Int = 80, height: Int = 48, type: UTType = .png, orientation: Int = 1) throws -> Data {
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            var random: UInt32 = 0x12345678
            for y in 0..<height {
                for x in 0..<width {
                    random ^= random << 13; random ^= random >> 17; random ^= random << 5
                    let i = (y * width + x) * 4
                    // A detailed photo/gradient area beside flat editor panels.
                    if x > width / 4 {
                        p[i] = UInt8(truncatingIfNeeded: x + Int(random & 127))
                        p[i + 1] = UInt8(truncatingIfNeeded: y + Int((random >> 8) & 127))
                        p[i + 2] = UInt8(truncatingIfNeeded: (x + y) / 4 + Int((random >> 16) & 127))
                    } else {
                        let ink: UInt8 = y % 32 < 4 && x % 160 > 16 ? 150 : 35
                        p[i] = ink; p[i + 1] = ink; p[i + 2] = ink
                    }
                    p[i + 3] = 255
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    @MainActor private func board() -> NSPasteboard {
        let board = NSPasteboard(name: .init("clipboard-image-" + UUID().uuidString))
        addTeardownBlock { board.releaseGlobally() }
        return board
    }

    @MainActor private func paste(_ board: NSPasteboard, label: String) async throws -> URL? {
        let root = scratchRoot("clipboard-image")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var attached: [URL] = [], rejection: String?
        let field = NativeComposer(text: "Keep this draft", send: { _ in }, inputRejected: { rejection = $0 },
            attachFiles: { attached += $0 }, pastedImages: .init(root: root)).makeView()
        let editor = try XCTUnwrap(field.documentView as? ComposerTextView)
        let accepted = editor.pasteAttachments(from: board)
        XCTAssertTrue(accepted, label)
        guard accepted else { return nil }
        try await eventually(label, timeout: .seconds(20)) { !attached.isEmpty || rejection != nil }
        XCTAssertNil(rejection, "\(label): \(rejection ?? "")")
        XCTAssertEqual(attached.count, 1, label)
        XCTAssertEqual(editor.string, "Keep this draft")
        return attached.first
    }

    @MainActor func testScreenshotPreviewAndPhotosRepresentations() async throws {
        for type: UTType in [.png, .tiff, .jpeg, .heic, .gif, .bmp] {
            let board = board()
            let bytes = try Self.image(type: type)
            board.setData(bytes, forType: .init(type.identifier))
            print("PASTE \(type.identifier) board types: \((board.types ?? []).map(\.rawValue))")
            let read = try XCTUnwrap(ComposerTextView.pastedImage(on: board))
            XCTAssertEqual(read.data, bytes, "\(type.identifier): copy the advertised bytes; do not ask AppKit to transcode on the main thread")
            XCTAssertEqual(read.isPNG, type == .png)
            guard let file = try await paste(board, label: type.identifier) else { continue }
            let record = try AttachmentRecord.inspect(file)
            XCTAssertEqual(record.mimeType, "image/png")
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
    }

    @MainActor func testImageCopiesWithURLHTMLAndTextKeepTheirImage() async throws {
        let png = try Self.image()
        let variants: [(String, [NSPasteboard.PasteboardType])] = [
            ("Safari image and URL", [.tiff, .URL, .html, .string]),
            ("Safari image without URL", [.tiff, .rtfd]),
            ("Chrome image and HTML", [.png, .html, .string]),
            ("Firefox PNG and TIFF with URL", [.png, .tiff, .URL, .html, .string]),
            ("chat image and alt text", [.png, .string]),
            ("office image-only HTML", [.string, .html, .png]),
            ("office image-only HTML with rich representation", [.string, .rtf, .html, .png]),
        ]
        for (name, types) in variants {
            let board = board(), item = NSPasteboardItem()
            for type in types {
                switch type {
                case .png: item.setData(png, forType: type)
                case .tiff: item.setData(try Self.image(type: .tiff), forType: type)
                case .URL: item.setString("https://fixture.invalid/photo", forType: type)
                case .html: item.setString("<meta charset='utf-8'><!--StartFragment--><a href='https://fixture.invalid'><img src='https://fixture.invalid/photo' alt='Generated photo'></a><!--EndFragment-->", forType: type)
                case .rtfd: item.setData(Data(), forType: type)
                case .rtf: item.setString("{\\rtf1 \\u65532?}", forType: type)
                default: item.setString("Generated photo", forType: type)
                }
            }
            board.writeObjects([item])
            _ = try await paste(board, label: name)
        }
    }

    @MainActor func testTextDocumentsAndFinderIconsRemainText() throws {
        let png = try Self.image(), editor = ComposerTextView()
        editor.attachFiles = { _ in XCTFail("A text document's rendering is not its input") }
        for type: NSPasteboard.PasteboardType in [.rtf, .html, .string, .fileURL] {
            let board = board(), item = NSPasteboardItem()
            item.setString("Quarterly totals: 1,204", forType: .string)
            if type == .rtf { item.setString("{\\rtf1 Quarterly totals: 1,204}", forType: type) }
            if type == .html { item.setString("<p>Quarterly <b>totals</b>: 1,204</p><img src='https://fixture.invalid/icon'>", forType: type) }
            if type == .fileURL { item.setString("file:///generated/notes.txt", forType: type) }
            item.setData(png, forType: .png); board.writeObjects([item])
            XCTAssertFalse(editor.pasteAttachments(from: board), type.rawValue)
        }
    }

    @MainActor func testLargeDataURLHTMLCannotVetoAnImageCopy() async throws {
        let png = try Self.image(width: 384, height: 256)
        var html = "<img src='data:image/png;base64,\(png.base64EncodedString())'>"
        html += String(repeating: " ", count: max(0, 300 * 1024 - html.utf8.count))
        XCTAssertGreaterThanOrEqual(html.utf8.count, 300 * 1024)
        print("PASTE data-URL HTML: \(html.utf8.count) bytes")
        for imageFirst in [true, false] {
            let board = board(), item = NSPasteboardItem()
            if imageFirst { item.setData(png, forType: .png) }
            item.setString(imageFirst ? "Generated caption" : " \n\t", forType: .string)
            item.setString(html, forType: .html)
            if !imageFirst { item.setData(png, forType: .png) }
            board.writeObjects([item])
            _ = try await paste(board, label: "300 KiB HTML, image first: \(imageFirst)")
        }
    }

    private final class DeferredFlavors: NSObject, NSPasteboardItemDataProvider {
        let data: [NSPasteboard.PasteboardType: Data]
        private let lock = NSLock()
        private var requested: [NSPasteboard.PasteboardType] = []
        var requests: [NSPasteboard.PasteboardType] { lock.lock(); defer { lock.unlock() }; return requested }
        init(_ data: [NSPasteboard.PasteboardType: Data]) { self.data = data }
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            lock.lock(); requested.append(type); lock.unlock()
            item.setData(data[type] ?? Data(), forType: type)
        }
    }

    @MainActor func testClearTextDoesNotRequestPromisedImageRendering() throws {
        let png = try Self.image(), editor = ComposerTextView()
        editor.attachFiles = { _ in XCTFail("A text copy must not attach its rendering") }
        editor.imageRejected = { XCTFail("Keep ordinary text paste: \($0)") }
        for richText in [false, true] {
            let board = board(), item = NSPasteboardItem(), provider = DeferredFlavors([.png: png])
            item.setString("Generated document text", forType: .string)
            if richText { item.setString("{\\rtf1 Generated document text}", forType: .rtf) }
            item.setDataProvider(provider, forTypes: [.png])
            board.writeObjects([item])
            XCTAssertEqual(board.types?.first, .string)
            XCTAssertTrue(provider.requests.isEmpty, "Advertising a rendering must not generate it")
            XCTAssertFalse(editor.pasteAttachments(from: board))
            XCTAssertTrue(provider.requests.isEmpty, "An ordinary text paste must never request the promised image")
        }
    }

    @MainActor func testHTMLIsReadOnlyAfterImageBytesAndCheapSignals() async throws {
        let png = try Self.image(), html = Data("<img src='https://fixture.invalid/image'>".utf8)
        for advertisedImage in [false, true] {
            let board = board(), item = NSPasteboardItem(), provider = DeferredFlavors([.html: html])
            item.setString("Generated caption", forType: .string)
            item.setDataProvider(provider, forTypes: advertisedImage ? [.html, .png] : [.html])
            board.writeObjects([item])
            let editor = ComposerTextView(); editor.attachFiles = { _ in XCTFail("No image bytes") }
            _ = editor.pasteAttachments(from: board)
            XCTAssertFalse(provider.requests.contains(.html), "No image bytes: do not request HTML")
        }
        for imageFirst in [true, false] {
            let board = board(), item = NSPasteboardItem()
            let provider = DeferredFlavors([.png: png, .html: html, .string: Data("Generated caption".utf8)])
            if imageFirst { item.setDataProvider(provider, forTypes: [.png]) }
            item.setDataProvider(provider, forTypes: [.string])
            item.setDataProvider(provider, forTypes: imageFirst ? [.html] : [.html, .png])
            board.writeObjects([item])
            _ = try await paste(board, label: "Deferred HTML, image first: \(imageFirst)")
            XCTAssertEqual(provider.requests, imageFirst ? [.png] : [.string, .png, .html],
                           "Use flavor order, then cheap text, image bytes and optional HTML; omit unneeded reads")
        }
    }

    @MainActor func testHTMLConfidenceIsConservativeAndNeverVetoesFlavorOrder() throws {
        let png = try Self.image()
        let cases: [(String, Bool)] = [
            ("<!DOCTYPE html><HTML><HEAD><TITLE>Generated</TITLE><STYLE>.x { color: red; }</STYLE></HEAD><BODY><IMG src='fixture'>&nbsp;&#160;&#xA0;\u{00a0}\u{fffc}</BODY></HTML>", true),
            ("<!-- <img> --><a href='fixture'><img alt='angles > and < stay quoted'></a>", true),
            ("<p>Generated document</p><img src='fixture'>", false),
            ("<!-- <img> -->", false),
            ("<span title='<img>'></span>", false),
            ("<script>const image = '<img>';</script>", false),
            ("<img src='unterminated>", false),
            ("<img><!-- unfinished", false),
            ("<img><style>unfinished", false),
            ("<img src='fixture'><unexpected>", false),
            ("<image src='fixture'>", false),
            ("<img src='" + String(repeating: "a", count: 300 * 1024) + "'>", false),
        ]
        for (index, fixture) in cases.enumerated() {
            for imageFirst in [false, true] {
                let board = board(), item = NSPasteboardItem()
                if imageFirst { item.setData(png, forType: .png) }
                item.setString("Generated caption", forType: .string); item.setString(fixture.0, forType: .html)
                if !imageFirst { item.setData(png, forType: .png) }
                board.writeObjects([item])
                XCTAssertEqual(ComposerTextView.imageIsWhatWasCopied(on: board, hasImageBytes: { true }), imageFirst || fixture.1,
                               "HTML case \(index), image first: \(imageFirst)")
            }
        }
    }

    @MainActor func testFilePromisesDoNotOverrideDocumentTextOrFinderFileURLs() throws {
        let editor = ComposerTextView()
        editor.attachFiles = { _ in XCTFail("Keep the document or file-name paste") }
        editor.imageRejected = { XCTFail("This is a text paste: \($0)") }
        for file in [false, true] {
            let board = board(), item = NSPasteboardItem()
            item.setString("Generated document", forType: .string)
            item.setString(UTType.png.identifier, forType: .init("com.apple.filepromise"))
            if file { item.setString("file:///generated/notes.txt", forType: .fileURL) }
            else { item.setString("{\\rtf1 Generated document}", forType: .rtf) }
            item.setData(try Self.image(), forType: .png)
            board.writeObjects([item])
            XCTAssertFalse(editor.pasteAttachments(from: board))
        }
    }

    @MainActor func testRichTextBeforeItsRenderingDoesNotRequireAPlainTextFlavor() throws {
        let editor = ComposerTextView()
        editor.attachFiles = { _ in XCTFail("A rendered document must remain text") }
        editor.imageRejected = { XCTFail("Use ordinary rich-text paste: \($0)") }
        let board = board(), item = NSPasteboardItem()
        item.setString("{\\rtf1 Generated document}", forType: .rtf)
        item.setData(try Self.image(), forType: .png)
        board.writeObjects([item])
        XCTAssertFalse(editor.pasteAttachments(from: board))
    }

    @MainActor func testRetinaScreenshotOverEightMiBAttachesWithinHelperLimits() async throws {
        let png = try Self.image(width: 5120, height: 2880)
        XCTAssertGreaterThan(png.count, 8 * 1024 * 1024)
        print("PASTE generated 5120x2880 screenshot: \(png.count) bytes")
        let board = board(); board.setData(png, forType: .png)
        guard let file = try await paste(board, label: "Retina screenshot") else { return }
        let bytes = try Data(contentsOf: file), record = try AttachmentRecord.inspect(file)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(record.mimeType, "image/png")
        XCTAssertLessThanOrEqual(max(image.width, image.height), 2000)
        XCTAssertLessThan((bytes.count + 2) / 3 * 4, 4_718_592)
        XCTAssertEqual(Double(image.width) / Double(image.height), 5120.0 / 2880, accuracy: 0.01)
        print("PASTE normalized screenshot: \(image.width)x\(image.height), \(bytes.count) bytes")
    }

    @MainActor func testOrientedJPEGIsConvertedUpright() async throws {
        let board = board()
        board.setData(try Self.image(width: 80, height: 48, type: .jpeg, orientation: 6), forType: .init(UTType.jpeg.identifier))
        guard let file = try await paste(board, label: "Oriented JPEG") else { return }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 48); XCTAssertEqual(image.height, 80)
    }

    @MainActor func testFinderImageFilesIncludeHEICAndTIFF() async throws {
        let root = scratchRoot("finder-images")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for type: UTType in [.png, .jpeg, .heic, .tiff] {
            let file = root.appendingPathComponent("photo." + type.preferredFilenameExtension!)
            let bytes = try Self.image(type: type)
            try bytes.write(to: file)
            let board = board(); board.writeObjects([file as NSURL])
            guard let attached = try await paste(board, label: "Finder \(type.identifier)") else { continue }
            XCTAssertNoThrow(try AttachmentRecord.inspect(attached))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    @MainActor func testMultipleFinderFilesNeverAttachANonImageIcon() async throws {
        let board = board(), editor = ComposerTextView()
        let root = scratchRoot("finder-multiple")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["a.png", "b.jpg", "notes.txt"].map { root.appendingPathComponent($0) }
        try Self.image().write(to: files[0]); try Self.image(type: .jpeg).write(to: files[1])
        try Data("Generated notes".utf8).write(to: files[2])
        var received: [URL] = []; editor.attachFiles = { received = $0 }
        editor.imageRejected = { XCTFail($0) }
        board.writeObjects(files.map { $0 as NSURL })
        XCTAssertTrue(editor.pasteAttachments(from: board))
        try await eventually("Finder image files attached") { received.count == 2 }
        XCTAssertEqual(received, Array(files.prefix(2)))
    }

    @MainActor func testNativeFileInspectionRefusalsAreNotRetriedAsConversion() async throws {
        let root = scratchRoot("paste-file-refusal")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = makeWorkspaceModel(stateRoot: root)
        var profile = ProfileRecord(); profile.id = "images"; profile.advancedJSON = "{\"input\":[\"text\",\"image\"]}"
        let chat = ChatRecord(id: "chat", workspaceID: "fixture", title: "Generated", profileID: profile.id)
        let session = SessionDisplay(id: chat.id)
        model.profiles = [profile]; model.chats = [chat]; model.displays[chat.id] = session
        let composer = ComposerInputView(model: model); composer.show(session)
        let editor = try XCTUnwrap(composer.field?.documentView as? ComposerTextView)
        let file = root.appendingPathComponent("changed.png"), bytes = try Self.image(type: .tiff)
        try bytes.write(to: file)
        let board = board(); board.writeObjects([file as NSURL])
        XCTAssertTrue(editor.pasteAttachments(from: board))
        try await eventually("file inspection settled") { model.attachmentImports == 0 }
        XCTAssertTrue(session.attachments.isEmpty, "The ordinary file inspector's refusal must remain a refusal")
        XCTAssertTrue(model.error?.contains("formats") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.pastedImages.directory.path))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    @MainActor func testMissingAttachmentDestinationAndFailedPromisesAreVisible() async throws {
        let board = board(), editor = ComposerTextView()
        var rejection: String?
        editor.imageRejected = { rejection = $0 }
        board.setData(try Self.image(), forType: .png)
        XCTAssertTrue(editor.pasteAttachments(from: board))
        XCTAssertNotNil(rejection, "An unwired composer must explain instead of silently falling through")
        rejection = nil; editor.attachFiles = { _ in XCTFail("No file was supplied") }
        board.clearContents()
        board.setString(UTType.png.identifier, forType: .init("com.apple.filepromise"))
        XCTAssertTrue(editor.pasteAttachments(from: board))
        XCTAssertTrue(rejection?.contains("file") == true)
    }

    @MainActor func testDefaultComposerDoesNotSilentlyDiscardAnImage() async throws {
        let board = board(); board.setData(try Self.image(), forType: .png)
        let root = scratchRoot("unwired-paste")
        defer { try? FileManager.default.removeItem(at: root) }
        var rejection: String?
        let field = NativeComposer(text: "", send: { _ in }, inputRejected: { rejection = $0 }, pastedImages: .init(root: root)).makeView()
        let editor = try XCTUnwrap(field.documentView as? ComposerTextView)
        XCTAssertTrue(editor.pasteAttachments(from: board))
        try await eventually("unwired composer refuses") { rejection != nil }
        XCTAssertTrue(rejection?.contains("composer") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("PastedImages").path))
    }

    @MainActor func testMissingAndUnwritableStorageLeaveTheDraftIntact() async throws {
        let root = scratchRoot("unwritable-paste")
        try Data("A file, not a storage directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        for storage in [nil, PastedImageStorage(root: root)] {
            var rejection: String?
            let field = NativeComposer(text: "Keep this", send: { _ in }, inputRejected: { rejection = $0 },
                attachFiles: { _ in XCTFail("Storage failed") }, pastedImages: storage).makeView()
            let editor = try XCTUnwrap(field.documentView as? ComposerTextView)
            let board = board(); board.setData(try Self.image(), forType: .png)
            XCTAssertTrue(editor.pasteAttachments(from: board))
            try await eventually("storage refusal") { rejection != nil }
            XCTAssertEqual(editor.string, "Keep this")
            XCTAssertTrue(rejection?.contains(storage == nil ? "storage" : "saved") == true)
        }
    }

    @MainActor func testMalformedImageHasAVisiblePersistentRejection() async throws {
        let root = scratchRoot("clipboard-rejection"), model = makeWorkspaceModel(stateRoot: root)
        let session = SessionDisplay(id: "paste"); session.draft = "Keep this"
        model.displays[session.id] = session
        let composer = ComposerInputView(model: model); composer.show(session)
        let editor = try XCTUnwrap(composer.field?.documentView as? ComposerTextView)
        let board = board(); board.setData(Data([1, 2, 3]), forType: .tiff)
        XCTAssertTrue(editor.pasteAttachments(from: board))
        try await eventually("invalid image rejected") { session.imageImports == 0 }
        XCTAssertTrue(session.notice.contains("image"))
        XCTAssertEqual(model.error, session.notice, "A streaming snapshot must not erase the only refusal")
        XCTAssertEqual(session.draft, "Keep this"); XCTAssertTrue(session.attachments.isEmpty)
    }

    @MainActor func testReadOnlyComposerDoesNotAttach() throws {
        let board = board(), editor = ComposerTextView()
        board.setData(try Self.image(), forType: .png)
        editor.attachFiles = { _ in XCTFail("A locked composer must not accept attachments") }
        editor.isEditable = false
        XCTAssertFalse(editor.pasteAttachments(from: board))
    }
}

final class ClipboardHTMLPerformanceTests: XCTestCase, SerialTestLane {
    @MainActor func testMalformedHTMLInspectionStaysBelowFiftyMilliseconds() async throws {
        let png = try ClipboardImageTests.image(), html = "<img>" + String(repeating: "<", count: 16_000)
        let root = scratchRoot("clipboard-html-timing")
        defer { try? FileManager.default.removeItem(at: root) }
        for imageFirst in [false, true] {
            let board = NSPasteboard(name: .init("clipboard-html-timing-" + UUID().uuidString))
            defer { board.releaseGlobally() }
            let item = NSPasteboardItem()
            if imageFirst { item.setData(png, forType: .png) }
            item.setString("Generated caption", forType: .string); item.setString(html, forType: .html)
            if !imageFirst { item.setData(png, forType: .png) }
            board.writeObjects([item])
            var attached = false
            let field = NativeComposer(text: "", send: { _ in }, inputRejected: { XCTFail($0) },
                attachFiles: { _ in attached = true }, pastedImages: .init(root: root)).makeView()
            let editor = try XCTUnwrap(field.documentView as? ComposerTextView)
            let start = ProcessInfo.processInfo.systemUptime
            let handled = editor.pasteAttachments(from: board)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            print(String(format: "PASTE 16,000 '<', image first %@: %.3f ms", String(imageFirst), elapsed * 1000))
            XCTAssertLessThan(elapsed, 0.050)
            XCTAssertEqual(handled, imageFirst, "Malformed HTML is inconclusive; preserve the other signals")
            if handled { try await eventually("malformed HTML image fallback") { attached } }
        }
    }
}
