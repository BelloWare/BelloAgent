import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PiApp

/// Owner request (0.1.130): "support jpg and more image format, and if openai
/// model does not support, just convert to a supported format". Attach
/// Images…, paste and drag-and-drop take any still image ImageIO reads and
/// decide by its bytes: a PNG, JPEG, GIF or WebP within 8 MiB stays as it is,
/// anything else (HEIC, TIFF, AVIF, a large photo, a mislabeled file)
/// becomes a PNG within the helper's limits. All fixtures are generated.
final class ImageFormatImportTests: XCTestCase {
    enum Entry: String, CaseIterable { case chooser, paste, drop }

    /// Noise in `type`, so neither PNG nor JPEG can compress it away; nil
    /// when this macOS cannot encode the type.
    static func image(_ type: UTType, width: Int = 64, height: Int = 40, quality: Double? = nil) -> Data? {
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary })
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
    /// A phone-sized photo: a smooth scene of gradients and shapes under
    /// `grain` of sensor-like noise, at quality 0.9.
    static func photo(grain: CGFloat, type: UTType, width: Int = 4032, height: Int = 3024) -> Data? {
        let rgb = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let gradient = CGGradient(colorsSpace: rgb, colors: [CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1),
                                                                   CGColor(red: 0.9, green: 0.7, blue: 0.4, alpha: 1)] as CFArray, locations: [0, 1])
        else { return nil }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        for index in 0..<40 {
            context.setFillColor(CGColor(red: CGFloat(index % 7) / 7, green: CGFloat(index % 5) / 5, blue: CGFloat(index % 3) / 3, alpha: 0.6))
            context.fillEllipse(in: CGRect(x: index * 397 % width, y: index * 211 % height, width: 300 + index * 13, height: 200 + index * 9))
        }
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let noise = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: rgb,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        context.setAlpha(grain); context.draw(noise, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
    static func animatedGIF() -> Data? {
        guard let first = image(.png, width: 24, height: 16), let second = image(.png, width: 24, height: 16),
              let frames = [first, second].map({ CGImageSourceCreateWithData($0 as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } }) as? [CGImage]
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, 2, nil) else { return nil }
        for frame in frames { CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary) }
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
    /// A 1 × 1 lossless WebP; ImageIO reads WebP but cannot write it.
    static let webP = Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")!
    /// A 2 × 2 AVIF; ImageIO reads AVIF but cannot write it.
    static let avif = Data(base64Encoded: "AAAAIGZ0eXBhdmlmAAAAAGF2aWZtaWYxbWlhZk1BMUIAAADybWV0YQAAAAAAAAAoaGRscgAAAAAAAAAAcGljdAAAAAAAAAAAAAAAAGxpYmF2aWYAAAAADnBpdG0AAAAAAAEAAAAeaWxvYwAAAABEAAABAAEAAAABAAABGgAAAB0AAAAoaWluZgAAAAAAAQAAABppbmZlAgAAAAABAABhdjAxQ29sb3IAAAAAamlwcnAAAABLaXBjbwAAABRpc3BlAAAAAAAAAAIAAAACAAAAEHBpeGkAAAAAAwgICAAAAAxhdjFDgQ0MAAAAABNjb2xybmNseAACAAIAAYAAAAAXaXBtYQAAAAAAAAABAAEEAQKDBAAAACVtZGF0EgAKCBgANogQEAwgMg8f8D///8WfhwB8+ErK42A=")!

    /// What ImageIO reads from a file: its type and upright size.
    static func read(_ file: URL) -> (type: String, width: Int, height: Int, frames: Int)? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let quarterTurn = (properties[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
        return (type, quarterTurn ? height : width, quarterTurn ? width : height, CGImageSourceGetCount(source))
    }

    /// A chat whose model takes images, its composer wired as in the app.
    @MainActor final class Workbench {
        let root: URL, model: WorkspaceModel, session: SessionDisplay, editor: ComposerTextView
        private let composer: ComposerInputView
        init(root: URL, model: WorkspaceModel) throws {
            self.root = root; self.model = model
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var profile = ProfileRecord(); profile.id = "images"; profile.advancedJSON = "{\"input\":[\"text\",\"image\"]}"
            let chat = ChatRecord(id: "chat", workspaceID: "fixture", title: "Generated", profileID: profile.id)
            session = SessionDisplay(id: chat.id); session.draft = "Keep this draft"
            model.profiles = [profile]; model.chats = [chat]; model.displays[chat.id] = session
            composer = ComposerInputView(model: model); composer.show(session)
            guard let editor = composer.field?.documentView as? ComposerTextView else { throw XCTSkip("The composer has no editor") }
            self.editor = editor
        }
        func file(_ name: String, _ data: Data) throws -> URL {
            let folder = root.appendingPathComponent("chosen", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name); try data.write(to: url); return url
        }
        /// The labels of the composer's image chips.
        func chipLabels() -> [String] {
            composer.refresh()
            var labels: [String] = [], pending: [NSView] = [composer]
            while let view = pending.popLast() {
                if let chip = view as? PiKit.Chip { labels.append(chip.main.text) } else { pending += view.subviews.reversed() }
            }
            return labels
        }
        /// Attaches `files` as `entry` does, waits until the import settles,
        /// and returns what the draft gained (clearing it for the next call
        /// unless `keep`).
        func attach(_ files: [URL], via entry: Entry, timeout: Duration = .seconds(30), keep: Bool = false) async throws -> [AttachmentRecord] {
            session.attachments = []; session.notice = ""; model.error = nil
            switch entry {
            case .chooser:
                model.questions.chooseFiles = { files }
                model.attachImages(sessionID: session.id)
            case .paste:
                let board = NSPasteboard(name: .init("image-formats-paste-" + UUID().uuidString))
                defer { board.releaseGlobally() }
                board.clearContents(); board.writeObjects(files.map { $0 as NSURL })
                XCTAssertTrue(editor.pasteAttachments(from: board), "paste is handled")
            case .drop:
                let drop = ImageFileDrop(files)
                defer { drop.draggingPasteboard.releaseGlobally() }
                XCTAssertEqual(editor.draggingEntered(drop), .copy, "the composer takes the drop")
                XCTAssertTrue(editor.performDragOperation(drop), "the drop is handled")
            }
            try await eventually("\(entry) import settled", timeout: timeout) { model.attachmentImports == 0 && session.imageImports == 0 }
            let attached = session.attachments
            if !keep { session.attachments = [] }
            return attached
        }
    }

    @MainActor private func workbench(_ name: String) throws -> Workbench {
        let root = scratchRoot("image-formats-" + name)
        return try Workbench(root: root, model: makeWorkspaceModel(stateRoot: root))
    }

    /// The private copy a conversion made: a PNG in the app's own storage,
    /// named so the pasted-image sweep keeps it while a draft or journal
    /// refers to it.
    @MainActor private func assertConverted(_ record: AttachmentRecord?, from original: URL, bytes: Data, width: Int, height: Int,
                                            in bench: Workbench, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let record else { return XCTFail("\(label): nothing attached; \(bench.model.error ?? "no error")", file: file, line: line) }
        let copy = URL(fileURLWithPath: record.path)
        XCTAssertEqual(record.mimeType, "image/png", label, file: file, line: line)
        XCTAssertEqual(copy.deletingLastPathComponent().resolvingSymlinksInPath().path,
                       bench.model.pastedImages.directory.resolvingSymlinksInPath().path, "\(label): stored with the app's pasted images", file: file, line: line)
        XCTAssertEqual(PastedImageStorage.names(in: Data(copy.lastPathComponent.utf8)), [copy.lastPathComponent], "\(label): the sweep recognizes it", file: file, line: line)
        let read = Self.read(copy)
        XCTAssertEqual(read?.type, UTType.png.identifier, label, file: file, line: line)
        XCTAssertEqual(read.map { [$0.width, $0.height] }, [width, height], label, file: file, line: line)
        XCTAssertEqual(read?.frames, 1, label, file: file, line: line)
        XCTAssertEqual(try? Data(contentsOf: original), bytes, "\(label): the original is untouched", file: file, line: line)
    }

    @MainActor func testEveryEntryPointConvertsFormatsTheModelCannotTakeByContent() async throws {
        let bench = try workbench("convert")
        var cases: [(name: String, data: Data, width: Int, height: Int)] = []
        for (type, name) in [(UTType.heic, "photo.heic"), (.tiff, "scan.tiff"), (.bmp, "legacy.bmp"), (UTType("public.jpeg-2000")!, "art.jp2"),
                             (UTType("com.microsoft.ico")!, "icon.ico")] {
            guard let data = Self.image(type, width: name == "icon.ico" ? 32 : 64, height: name == "icon.ico" ? 32 : 40) else {
                print("SKIP \(name): this macOS cannot encode \(type.identifier)"); continue
            }
            cases.append((name, data, name == "icon.ico" ? 32 : 64, name == "icon.ico" ? 32 : 40))
        }
        if CGImageSourceCreateWithData(Self.avif as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) != nil {
            cases.append(("still.avif", Self.avif, 2, 2))
        } else { print("SKIP still.avif: this macOS cannot decode AVIF") }
        // The bytes decide, not the name: HEIC called .jpg and TIFF called .png.
        cases.append(("camera.jpg", try XCTUnwrap(Self.image(.heic)), 64, 40))
        cases.append(("screen.png", try XCTUnwrap(Self.image(.tiff)), 64, 40))
        XCTAssertGreaterThanOrEqual(cases.count, 7)
        let files = try cases.map { try bench.file($0.name, $0.data) }
        for entry in Entry.allCases {
            // A submission holds four images.
            for start in stride(from: 0, to: files.count, by: 4) {
                let batch = Array(start..<min(start + 4, files.count))
                let attached = try await bench.attach(batch.map { files[$0] }, via: entry)
                XCTAssertNil(bench.model.error, "\(entry): \(bench.model.error ?? "")")
                XCTAssertEqual(attached.count, batch.count, "\(entry): every image attaches")
                for (offset, index) in batch.enumerated() {
                    assertConverted(attached.count > offset ? attached[offset] : nil, from: files[index], bytes: cases[index].data,
                                    width: cases[index].width, height: cases[index].height, in: bench, "\(entry) \(cases[index].name)")
                }
            }
        }
        XCTAssertEqual(bench.session.draft, "Keep this draft")
    }

    @MainActor func testEveryEntryPointKeepsWhatTheModelTakesAsItIs() async throws {
        let bench = try workbench("native")
        let animated = try XCTUnwrap(Self.animatedGIF())
        let natives: [(String, Data, String)] = [("photo.png", try XCTUnwrap(Self.image(.png)), "image/png"),
                                                 ("photo.jpeg", try XCTUnwrap(Self.image(.jpeg)), "image/jpeg"),
                                                 ("tiny.webp", Self.webP, "image/webp"),
                                                 // The helper sends an animation's first frame.
                                                 ("moving.gif", animated, "image/gif")]
        let files = try natives.map { try bench.file($0.0, $0.1) }
        for entry in Entry.allCases {
            let attached = try await bench.attach(files, via: entry)
            XCTAssertNil(bench.model.error, "\(entry): \(bench.model.error ?? "")")
            XCTAssertEqual(attached.map(\.path), files.map { $0.resolvingSymlinksInPath().path }, "\(entry): the originals themselves")
            XCTAssertEqual(attached.map(\.mimeType), natives.map(\.2), "\(entry)")
            XCTAssertEqual(attached.map(\.bytes), natives.map(\.1.count), "\(entry)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bench.model.pastedImages.directory.path), "Nothing needed a private copy")
    }

    /// A photo the model cannot take as it is reaches the helper as large as
    /// its 8 MiB gate allows, up to the 2,000 pixels it sends; the helper then
    /// chooses PNG or JPEG as pi does. Even pure noise, PNG's worst case,
    /// fits at 2,000 pixels (about 7.7 MB).
    @MainActor func testLargePhotosAttachThroughEveryEntryPointWithinHelperLimits() async throws {
        let bench = try workbench("large")
        var photos: [(String, Data)] = [("large.jpg", try XCTUnwrap(Self.image(.jpeg, width: 4000, height: 3000, quality: 0.9)))]
        if let heic = Self.image(.heic, width: 4000, height: 3000, quality: 0.9) { photos.append(("large.heic", heic)) }
        else { print("SKIP large.heic: this macOS cannot encode HEIC") }
        for (name, data) in photos {
            XCTAssertGreaterThan(data.count, 12 * 1000 * 1000, "\(name): a 12–25 MB photo")
            XCTAssertLessThan(data.count, 25 * 1000 * 1000, name)
            let file = try bench.file(name, data)
            for entry in Entry.allCases {
                let started = ContinuousClock.now
                let attached = try await bench.attach([file], via: entry, timeout: .seconds(120))
                XCTAssertNil(bench.model.error, "\(entry) \(name): \(bench.model.error ?? "")")
                guard let record = attached.first else { XCTFail("\(entry) \(name): nothing attached"); continue }
                let copy = URL(fileURLWithPath: record.path), read = try XCTUnwrap(Self.read(copy))
                let size = try XCTUnwrap(try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                print("IMAGE \(entry) \(name) \(data.count) bytes → \(read.width)x\(read.height) PNG, \(size) bytes in \(ContinuousClock.now - started)")
                XCTAssertEqual(record.mimeType, "image/png")
                XCTAssertLessThanOrEqual(record.bytes, 8 * 1024 * 1024, "the helper's per-image limit")
                XCTAssertEqual([read.width, read.height], [2000, 1500], "the helper's 2,000 pixels within its 8 MiB gate, not pi's base64 bound")
                XCTAssertEqual(try Data(contentsOf: file), data)
            }
        }
    }

    /// A converted file starts at the helper's 2,000 pixels, even when a PNG
    /// of all its pixels would fit in 8 MiB: the helper sends no more.
    @MainActor func testConvertedFilesStartAtTheHelpersBound() async throws {
        let bench = try workbench("bound")
        let context = try XCTUnwrap(CGContext(data: nil, width: 3000, height: 1500, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500))
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 1500))
        let image = try XCTUnwrap(context.makeImage())
        func encoded(_ type: UTType) throws -> Data {
            let output = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return output as Data
        }
        let scan = try encoded(.bmp), photo = try encoded(.heic)
        XCTAssertGreaterThan(scan.count, 8 * 1024 * 1024, "an uncompressed scan over 8 MiB")
        XCTAssertLessThan(photo.count, 8 * 1024 * 1024, "a small HEIC")
        for (name, data) in [("scan.bmp", scan), ("flat.heic", photo)] {
            let file = try bench.file(name, data)
            for entry in Entry.allCases {
                let attached = try await bench.attach([file], via: entry)
                XCTAssertNil(bench.model.error, "\(entry): \(bench.model.error ?? "")")
                assertConverted(attached.first, from: file, bytes: data, width: 2000, height: 1000, in: bench, "\(entry) \(name)")
            }
        }
    }

    /// One with transparency stays within pi's 4.5 MB of base64, so the
    /// helper sends it as PNG rather than flattening it into a JPEG.
    @MainActor func testTransparentConversionsStayPNG() async throws {
        let bench = try workbench("transparent")
        let width = 1650, height = 1200
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                          provider: try XCTUnwrap(CGDataProvider(data: pixels as CFData)), decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertLessThanOrEqual(output.length, 8 * 1024 * 1024, "a TIFF the 8 MiB gate alone would keep at full size")
        let file = try bench.file("overlay.tiff", output as Data)
        for entry in Entry.allCases {
            let attached = try await bench.attach([file], via: entry)
            XCTAssertNil(bench.model.error, "\(entry): \(bench.model.error ?? "")")
            let record = try XCTUnwrap(attached.first, "\(entry)")
            let copy = URL(fileURLWithPath: record.path)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(copy as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyHasAlpha] as? Bool, true, "\(entry): transparency kept")
            XCTAssertLessThan((record.bytes + 2) / 3 * 4, 4_718_592, "\(entry): the helper sends it as PNG")
            XCTAssertEqual(record.mimeType, "image/png")
        }
    }

    /// Converted files keep the name they had on the composer's chip; a
    /// clipboard image, which has none, keeps its stored name.
    @MainActor func testConvertedFilesKeepTheirNameOnTheChip() async throws {
        let bench = try workbench("names")
        let heic = try bench.file("IMG_2041.HEIC", try XCTUnwrap(Self.image(.heic)))
        let png = try bench.file("diagram.png", try XCTUnwrap(Self.image(.png)))
        for entry in Entry.allCases {
            let attached = try await bench.attach([heic, png], via: entry, keep: true)
            XCTAssertEqual(attached.count, 2, "\(entry)")
            XCTAssertEqual(bench.chipLabels(), ["IMG_2041.HEIC", "diagram.png"], "\(entry)")
            bench.session.attachments = []
        }
        let board = NSPasteboard(name: .init("image-formats-bytes-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setData(try XCTUnwrap(Self.image(.tiff)), forType: .tiff)
        XCTAssertTrue(bench.editor.pasteAttachments(from: board))
        try await eventually("clipboard image attached") { bench.model.attachmentImports == 0 && !bench.session.attachments.isEmpty }
        let pasted = try XCTUnwrap(bench.session.attachments.first)
        XCTAssertEqual(bench.chipLabels(), [URL(fileURLWithPath: pasted.path).lastPathComponent])
        XCTAssertTrue(bench.chipLabels().first?.hasPrefix("pasted-") == true)
    }

    /// The chip's name is presentation: saved with the draft (and read from
    /// drafts saved before it existed), never sent to the helper, and no
    /// part of the attachment's identity.
    @MainActor func testAChipNameIsSavedWithTheDraftButNeverSent() async throws {
        var named = AttachmentRecord(id: "image", path: "/fixture/pasted-copy.png", sha256: "digest", bytes: 10, mimeType: "image/png")
        named.name = "IMG_2041.HEIC"
        var unnamed = named; unnamed.name = nil
        XCTAssertEqual(named, unnamed); XCTAssertEqual(named.hashValue, unnamed.hashValue)
        XCTAssertEqual(named.wire, unnamed.wire, "never on the wire")
        let params = WorkspaceModel.editTurnParams(messageID: "m", text: "t", turnID: "turn", attachments: [named], skills: [])
        XCTAssertEqual(params["attachments"], .array([unnamed.wire]))
        let draft = DraftRecord(id: "chat", text: "Draft", attachments: [named])
        let decoded = try JSONDecoder().decode(DraftRecord.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(decoded.attachments?.first?.name, "IMG_2041.HEIC")
        let older = Data(#"{"id":"chat","text":"Draft","attachments":[{"id":"image","path":"/fixture/pasted-copy.png","sha256":"digest","bytes":10,"mimeType":"image/png"}]}"#.utf8)
        let legacy = try JSONDecoder().decode(DraftRecord.self, from: older)
        XCTAssertNil(legacy.attachments?.first?.name)
        XCTAssertEqual(legacy, draft, "A draft without the name is the same draft")
        XCTAssertTrue(legacy.holds(draft) && draft.holds(legacy))
        XCTAssertEqual(DraftRecord(id: "chat", text: "").merging(draft).attachments?.first?.name, "IMG_2041.HEIC", "copies keep it")
        // A queued message's rewrite parks a chosen image in the draft set
        // aside for it, name and all.
        let bench = try workbench("parked")
        bench.session.queueEditingID = "queued"; bench.session.queueEditID = "edit"
        bench.session.draftBeforeQueueEdit = DraftRecord(id: bench.session.id, text: "Parked draft")
        let heic = try bench.file("IMG_2041.HEIC", try XCTUnwrap(Self.image(.heic)))
        _ = try await bench.attach([heic], via: .chooser, keep: true)
        XCTAssertTrue(bench.session.attachments.isEmpty, "the rewrite takes no images")
        XCTAssertEqual(bench.session.draftBeforeQueueEdit?.attachments?.map(\.name), ["IMG_2041.HEIC"])
    }

    /// For the record, on demand: four photos through Attach Images…, each
    /// converted copy saved where `PiImageFormatTests.testMeasureWhatTheHelperSends`
    /// reads it.
    @MainActor func testMeasureConvertedPhotos() async throws {
        guard let path = testEnvironment("PI_APP_IMAGE_MEASURE") else { throw XCTSkip("Set PI_APP_IMAGE_MEASURE") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bench = try workbench("measure")
        let photos: [(String, Data?)] = [("smooth-12mp.heic", Self.photo(grain: 0.05, type: .heic)), ("noisy-12mp.heic", Self.photo(grain: 0.25, type: .heic)),
                                         ("noise-14mb.jpg", Self.image(.jpeg, width: 4000, height: 3000, quality: 0.9)),
                                         ("noise-14mb.heic", Self.image(.heic, width: 4000, height: 3000, quality: 0.9))]
        for (name, data) in photos {
            let data = try XCTUnwrap(data, name), file = try bench.file(name, data)
            let started = ContinuousClock.now
            let attached = try await bench.attach([file], via: .chooser, timeout: .seconds(120))
            let elapsed = ContinuousClock.now - started
            let record = try XCTUnwrap(attached.first, bench.model.error ?? name)
            let copy = URL(fileURLWithPath: record.path), read = try XCTUnwrap(Self.read(copy))
            print("MEASURE \(name): \(data.count) bytes → stored \(read.width)x\(read.height) \(record.mimeType), \(record.bytes) bytes, in \(elapsed)")
            let saved = folder.appendingPathComponent(name + ".stored.png")
            try? FileManager.default.removeItem(at: saved); try FileManager.default.copyItem(at: copy, to: saved)
        }
    }

    /// Converted copies count against the submission's four images and
    /// 16 MiB like any other, on every entry point.
    @MainActor func testConvertedImagesKeepTheSubmissionLimits() async throws {
        let bench = try workbench("limits")
        let small = try (0..<5).map { try bench.file("photo-\($0).heic", try XCTUnwrap(Self.image(.heic))) }
        // Noise TIFFs within 8 MiB whose PNGs are each over a third of 16 MiB.
        let scans = try (0..<3).map { try bench.file("scan-\($0).tiff", try XCTUnwrap(Self.image(.tiff, width: 1650, height: 1200))) }
        for entry in Entry.allCases {
            for (files, limit) in [(small, "five images"), (scans, "over 16 MiB")] {
                let attached = try await bench.attach(files, via: entry)
                XCTAssertTrue(attached.isEmpty, "\(entry), \(limit)")
                XCTAssertEqual(bench.model.error, "The images could not be attached: a submission supports four images and 16 MiB in total.", "\(entry), \(limit)")
            }
            let one = try await bench.attach([scans[0]], via: entry)
            XCTAssertEqual(one.map(\.mimeType), ["image/png"], "\(entry)")
            XCTAssertGreaterThan(one.first?.bytes ?? 0, 16 * 1024 * 1024 / 3, "\(entry): the fixture's copy is large enough")
            XCTAssertLessThanOrEqual(one.first?.bytes ?? .max, 8 * 1024 * 1024, "\(entry): within the helper's per-image limit")
        }
    }

    /// A chosen image that is still being converted when the reader starts
    /// editing an earlier message is refused rather than joining that edit,
    /// as a pasted one is.
    @MainActor func testAChosenImageFollowsTheDraftItWasChosenFor() async throws {
        let bench = try workbench("moved")
        let file = try bench.file("photo.heic", try XCTUnwrap(Self.image(.heic)))
        bench.model.questions.chooseFiles = { [file] }
        bench.model.attachImages(sessionID: bench.session.id)
        XCTAssertEqual(bench.model.attachmentImports, 1, "The import counts from the choice")
        bench.session.editingMessageID = "earlier"
        try await eventually("chosen import settled") { bench.model.attachmentImports == 0 }
        XCTAssertTrue(bench.session.attachments.isEmpty)
        XCTAssertEqual(bench.model.error, "The draft changed while its image was being prepared. Attach it again.")
    }

    @MainActor func testAttachImagesPanelOffersEveryImageType() throws {
        let panel = PiQuestion.imageFilesPanel()
        XCTAssertTrue(panel.allowsMultipleSelection); XCTAssertFalse(panel.canChooseDirectories)
        let allowed = panel.allowedContentTypes
        for identifier in ["public.jpeg", "public.png", "com.compuserve.gif", "org.webmproject.webp", "public.heic", "public.heif",
                           "public.tiff", "public.avif", "com.microsoft.bmp", "public.jpeg-2000", "com.microsoft.ico", "com.canon.cr2-raw-image"] {
            let type = try XCTUnwrap(UTType(identifier), identifier)
            XCTAssertTrue(allowed.contains { type.conforms(to: $0) }, "\(identifier) can be chosen")
        }
        for type in [UTType.pdf, .plainText, .movie, .folder] {
            XCTAssertFalse(allowed.contains { type.conforms(to: $0) }, "\(type.identifier) is not an image")
        }
    }

    @MainActor func testUnreadableFilesAreRefusedClearlyOnEveryEntryPoint() async throws {
        let bench = try workbench("refusal")
        let unreadable = [try bench.file("notes.png", Data(String(repeating: "Generated notes, not pixels.\n", count: 40).utf8)),
                          try bench.file("fake.heic", Data("Not an image".utf8)),
                          try bench.file("broken.jpg", Data([0xff, 0xd8, 0xff, 0xe0]) + Data("Generated bytes that are not a JPEG".utf8))]
        let originals = try unreadable.map { try Data(contentsOf: $0) }
        for entry in Entry.allCases {
            for file in unreadable {
                let attached = try await bench.attach([file], via: entry)
                XCTAssertTrue(attached.isEmpty, "\(entry) \(file.lastPathComponent)")
                let message = bench.model.error ?? ""
                XCTAssertTrue(message.contains("“\(file.lastPathComponent)” could not be read as an image"), "\(entry): \(message)")
                XCTAssertTrue(message.contains("HEIC"), "\(entry): the refusal names what can be attached: \(message)")
                XCTAssertEqual(bench.session.notice, message, "\(entry): the composer shows it too")
            }
        }
        XCTAssertEqual(bench.session.draft, "Keep this draft")
        XCTAssertEqual(try unreadable.map { try Data(contentsOf: $0) }, originals)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bench.model.pastedImages.directory.path), "A refusal leaves no private copy")
    }
}

/// A drag of image files onto the composer, on a pasteboard of its own so
/// the class stays in the parallel lane.
@MainActor final class ImageFileDrop: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard(name: .init("image-formats-drop-" + UUID().uuidString))
    init(_ files: [URL]) { draggingPasteboard.clearContents(); draggingPasteboard.writeObjects(files.map { $0 as NSURL }) }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic] }
    var draggedImageLocation: NSPoint { .zero }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) { }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) { }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() { }
}
