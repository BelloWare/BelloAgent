import XCTest
import AppKit
import ImageIO
@testable import PiApp

final class TranscriptImageLoadingTests: XCTestCase {
    struct Journal {
        let root: URL, path: URL
        init(root: URL = scratchRoot("transcript-images"), sessionID: String = "chat") throws {
            self.root = root; path = root.appendingPathComponent("images.jsonl")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var rows: [WireValue] = [.object(["type": .string("session"), "id": .string(sessionID), "version": .number(3)]),
                                     .object(["type": .string("custom"), "id": .string("native"), "customType": .string("pi-app.native.v1"), "data": .object(["version": .number(1)])])]
            var parent = "native"
            for (id, role, caption) in [("caption", "user", "Compare these two images."), ("answer", "assistant", "The first image is warm; the second is blue."),
                                         ("image-only", "user", ""), ("answer2", "assistant", "Both images are attached to your message.")] {
                let body: [String: WireValue] = role == "user" ? try TranscriptImageTests.body(text: caption, count: 2) : ["role": .string(role), "content": .string(caption)]
                rows.append(.object(["type": .string("message"), "id": .string(id), "parentId": .string(parent), "message": .object(body)])); parent = id
            }
            var bytes = Data()
            for row in rows { bytes.append(try JSONEncoder().encode(row)); bytes.append(10) }
            try bytes.write(to: path)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    func testHistoryKeepsOffsetsAndLoadsOnlyTheRequestedImage() async throws {
        let journal = try Journal(); defer { journal.remove() }
        let reader = HistoryReader(), cache = TranscriptImageCache()
        let page = try await reader.read(path: journal.path.path)
        let question = try XCTUnwrap(page.messages.first { $0.id == "caption" })
        XCTAssertEqual(question.imageCount, 2)
        let reference = try XCTUnwrap(question.imageReference)
        XCTAssertLessThan(try JSONEncoder().encode(page.messages).count, 4_096)
        let decoded = await reader.decodedRecords
        let resolved = try await reader.imageReference(path: journal.path.path, id: question.id)
        XCTAssertEqual(resolved, reference)
        let afterReference = await reader.decodedRecords
        XCTAssertEqual(decoded, afterReference, "Resolving an offset must not decode the image record")
        let first = try await cache.image(source: .journal(reference), index: 1, pixels: 128)
        XCTAssertEqual(first.image.width, 128); XCTAssertLessThanOrEqual(first.image.height, 128)
        let afterThumbnail = await reader.decodedRecords
        XCTAssertEqual(decoded, afterThumbnail, "Thumbnail work is independent of the history-page reader")
        let again = try await cache.image(source: .journal(reference), index: 1, pixels: 128)
        XCTAssertTrue(first === again)
        let count = await cache.decodeCount
        XCTAssertEqual(count, 1)
    }

    func testALiveImageRemainsReadableWhenTheJournalGrowsDuringLookup() async throws {
        let journal = try Journal(); defer { journal.remove() }
        let reader = HistoryReader(), file = journal.path
        await reader.observeImageReference {
            let writer = try FileHandle(forWritingTo: file); defer { try? writer.close() }
            try writer.seekToEnd(); try writer.write(contentsOf: Data("{\"type\":\"custom\",\"id\":\"next-state\"".utf8))
        }
        var reference: TranscriptImageReference?
        do { reference = try await reader.imageReference(path: file.path, id: "caption") }
        catch { XCTFail("A later append must not hide a complete image record: \(error)") }
        guard let reference else { return }
        let bitmap = try await TranscriptImageCache().image(source: .journal(reference), index: 0, pixels: 128)
        XCTAssertEqual(bitmap.image.width, 128)
    }

    func testACompleteImageBeforeAnUnfinishedTailCanBePreviewed() async throws {
        let journal = try Journal(); defer { journal.remove() }
        let writer = try FileHandle(forWritingTo: journal.path)
        try writer.seekToEnd(); try writer.write(contentsOf: Data("{\"type\":\"custom\",\"id\":\"next-state\"".utf8)); try writer.close()
        var reference: TranscriptImageReference?
        do { reference = try await HistoryReader().imageReference(path: journal.path.path, id: "caption") }
        catch { XCTFail("An unfinished later record must not hide a complete image: \(error)") }
        guard let reference else { return }
        let bitmap = try await TranscriptImageCache().image(source: .journal(reference), index: 1, pixels: 128)
        XCTAssertEqual(bitmap.image.width, 128)
    }

    func testTheCacheHasAHardByteBoundAndEvictsTheLeastRecentlyUsedImage() async throws {
        let journal = try Journal(); defer { journal.remove() }
        let reference = try await HistoryReader().imageReference(path: journal.path.path, id: "caption")
        let probe = try await TranscriptImageCache().image(source: .journal(reference), index: 0, pixels: 128)
        let cache = TranscriptImageCache(byteLimit: probe.cost)
        let first = try await cache.image(source: .journal(reference), index: 0, pixels: 128)
        _ = try await cache.image(source: .journal(reference), index: 1, pixels: 128)
        let second = try await cache.image(source: .journal(reference), index: 0, pixels: 128)
        XCTAssertFalse(first === second, "The first bitmap was evicted, not retained outside the bound")
        let bytes = await cache.retainedBytes, count = await cache.decodeCount
        XCTAssertLessThanOrEqual(bytes, probe.cost); XCTAssertEqual(count, 3)
        let uncached = TranscriptImageCache(byteLimit: 0)
        _ = try await uncached.image(source: .journal(reference), index: 0, pixels: 128)
        let empty = await uncached.retainedBytes
        XCTAssertEqual(empty, 0, "An image larger than the budget is returned without caching")
    }

    func testTinyImagesCannotAccumulateUnboundedCacheEntries() async throws {
        let root = scratchRoot("tiny-image-cache"); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("pixel.png")
        try TranscriptImageTests.image(width: 1, height: 1).write(to: file)
        let original = try AttachmentRecord.inspect(file), cache = TranscriptImageCache()
        func source(_ index: Int) -> TranscriptImageSource {
            .attachment(AttachmentRecord(id: "image-\(index)", path: original.path, sha256: original.sha256, bytes: original.bytes, mimeType: original.mimeType))
        }
        for index in 0...512 { _ = try await cache.image(source: source(index), index: 0, pixels: 1) }
        let before = await cache.decodeCount
        _ = try await cache.image(source: source(0), index: 0, pixels: 1)
        let after = await cache.decodeCount
        XCTAssertEqual(after, before + 1, "The oldest tiny image must leave the 512-entry cache even when its pixels use almost no memory")
    }

    func testOffsetsRejectAReplacedFileAndWrongMessageOrImage() async throws {
        let journal = try Journal(); defer { journal.remove() }
        let reference = try await HistoryReader().imageReference(path: journal.path.path, id: "caption")
        let cache = TranscriptImageCache()
        let wrong = TranscriptImageReference(path: reference.path, id: "another-message", offset: reference.offset, length: reference.length,
                                             device: reference.device, inode: reference.inode)
        for (source, index) in [(wrong, 0), (reference, -1), (reference, 2)] {
            do { _ = try await cache.image(source: .journal(source), index: index, pixels: 128); XCTFail("Wrong occurrence was read") }
            catch { XCTAssertFalse(error is CancellationError) }
        }
        let contents = try Data(contentsOf: journal.path)
        try contents.write(to: journal.path, options: .atomic)
        do { _ = try await cache.image(source: .journal(reference), index: 0, pixels: 128); XCTFail("A replacement cannot inherit old offsets") }
        catch { XCTAssertFalse(error is CancellationError) }
        let fresh = try await HistoryReader().imageReference(path: journal.path.path, id: "caption")
        _ = try await cache.image(source: .journal(fresh), index: 0, pixels: 128)
    }

    func testDownsamplingAppliesImageOrientation() async throws {
        let root = scratchRoot("image-orientation"); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try TranscriptImageTests.image(width: 400, height: 200)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let jpeg = NSMutableData(), image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let file = root.appendingPathComponent("rotated.jpg"); try (jpeg as Data).write(to: file)
        let attachment = try AttachmentRecord.inspect(file)
        let bitmap = try await TranscriptImageCache().image(source: .attachment(attachment), index: 0, pixels: 128)
        XCTAssertEqual(bitmap.image.width, 64); XCTAssertEqual(bitmap.image.height, 128, "The thumbnail is upright before reaching AppKit")
    }

    private final class Observation: @unchecked Sendable {
        let lock = NSLock()
        private var values: [Bool] = []
        func append(_ value: Bool) { lock.lock(); values.append(value); lock.unlock() }
        var mainThreads: [Bool] { lock.lock(); defer { lock.unlock() }; return values }
    }
    @MainActor func testDecodeIsOffTheMainThreadAndTheViewerUsesItsOwnLargerBitmap() async throws {
        let journal = try Journal(); defer { journal.remove() }
        let reference = try await HistoryReader().imageReference(path: journal.path.path, id: "caption")
        let cache = TranscriptImageCache(), observation = Observation()
        await cache.observeDecodes { observation.append($0) }
        let small = try await cache.image(source: .journal(reference), index: 0, pixels: 128)
        let preview = FilePreview(imageName: "Image 1 of 2", load: { try await cache.image(source: .journal(reference), index: 0, pixels: 2_048) })
        preview.load(); await preview.readingTask?.value
        XCTAssertNotNil(preview.image); XCTAssertNil(preview.error)
        XCTAssertGreaterThan(preview.image?.size.width ?? 0, CGFloat(small.image.width))
        XCTAssertEqual(observation.mainThreads, [false, false], "Read, base64 conversion and ImageIO decoding use the image actor")
        preview.close(); XCTAssertNil(preview.image)
    }

    func testHistoryCopyAndFindKeepTheCaptionAndImageOnlyDescription() async throws {
        let journal = try Journal(); defer { journal.remove() }
        let reader = HistoryReader(), page = try await reader.read(path: journal.path.path)
        XCTAssertEqual(ConversationContent.transcriptText(try XCTUnwrap(page.messages.first { $0.id == "caption" })), "Compare these two images.")
        XCTAssertEqual(ConversationContent.transcriptText(try XCTUnwrap(page.messages.first { $0.id == "image-only" })), "2 images")
        let caption = try await reader.searchContent(path: journal.path.path, query: "Compare these", start: 0, renderedAgentProse: true)
        XCTAssertEqual(caption.hits.map(\.id), ["caption"])
        let images = try await reader.searchContent(path: journal.path.path, query: "2 images", start: 0, renderedAgentProse: true)
        XCTAssertTrue(images.hits.contains { $0.id == "image-only" })
        let exported = try await reader.copyContentPage(path: journal.path.path, first: 1, last: page.total,
                                                       cursor: ContentCursor(index: 1, offset: 0), revision: try XCTUnwrap(page.revision?.stamp))
        XCTAssertTrue(exported.text.contains("Compare these two images."))
        XCTAssertFalse(exported.text.contains("iVBOR"), "Text copy/export never includes the encoded image payload")
    }

    @MainActor func testLiveMainAndSideRowsResolveTheirJournalAndSendingRowsUseFileReferences() async throws {
        let root = scratchRoot("image-workspace"), fixture = try ConversationPaneTests.workbench(root: root, chats: ["main", "side"], imageModel: true)
        defer { fixture.model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let journal = try Journal(root: root.appendingPathComponent("journal"))
        for chat in fixture.chats {
            let position = try XCTUnwrap(fixture.model.chats.firstIndex { $0.id == chat.id })
            fixture.model.chats[position].path = journal.path.path
            let row = try XCTUnwrap(TranscriptMessage.page(.array([.object(["id": .string("caption"), "role": .string("user"), "text": .string("Compare these two images."), "imageCount": .number(2)])])).first)
            let bitmap = try await fixture.model.transcriptImage(row, sessionID: chat.id, index: 1, pixels: 128)
            XCTAssertEqual(bitmap.image.width, 128)
        }
        let file = root.appendingPathComponent("sending.png")
        try TranscriptImageTests.image().write(to: file)
        let attachment = try AttachmentRecord.inspect(file)
        var row = TranscriptMessage(id: "sending", role: "user", text: "Image", state: TranscriptMessage.sendingState)
        row.imageOnly = true; row.imageCount = 1; row.imageAttachments = [attachment]
        let bitmap = try await fixture.model.transcriptImage(row, sessionID: "new-chat", index: 0, pixels: 128)
        XCTAssertEqual(bitmap.image.width, 128)
        try Data("changed".utf8).write(to: file)
        do { _ = try await TranscriptImageCache().image(source: .attachment(attachment), index: 0, pixels: 128); XCTFail("A changed original was read") }
        catch { XCTAssertFalse(error is CancellationError) }
    }
}

final class TranscriptImageLifecycleTests: XCTestCase {
    @MainActor func testAnOffscreenImageStartsLoadingWhenScrolledIntoView() async throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try TranscriptImageTests.image() as CFData, nil))
        let bitmap = TranscriptImageBitmap(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        var loads = 0, actions = TranscriptActions()
        actions.loadImage = { _, _, _ in loads += 1; return bitmap }
        let row = TranscriptRowContainer(item: .message(try TranscriptImageTests.message(count: 1)), fresh: false, actions: actions)
        let height = row.measure(width: 500).height
        let canvas = TranscriptNativeRowParityTests.ParityCanvas(frame: CGRect(x: 0, y: 0, width: 500, height: 1_400))
        row.frame = CGRect(x: 0, y: 900, width: 500, height: height); canvas.addSubview(row)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        scroll.documentView = canvas; scroll.contentView.postsBoundsChangedNotifications = true
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.contentView = nil; window.close() }
        row.layoutForViewport(); scroll.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(loads, 0, "An offscreen row does not read its images")
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 900)); scroll.reflectScrolledClipView(scroll.contentView)
        try await eventually("scrolling into view starts the lazy read") { loads == 1 }
        XCTAssertEqual(row.hostedFittingHeight, height)
    }

    @MainActor func testLoadingIsLazyAndArrivingPixelsCannotMoveRows() async throws {
        let journal = try TranscriptImageLoadingTests.Journal(); defer { journal.remove() }
        let page = try await HistoryReader().read(path: journal.path.path)
        let message = try XCTUnwrap(page.messages.first { $0.id == "caption" })
        let cache = TranscriptImageCache()
        var actions = TranscriptActions(), loads = 0
        var release: CheckedContinuation<Void, Never>?
        actions.loadImage = { message, index, pixels in
            loads += 1
            if index == 0 { await withCheckedContinuation { release = $0 } }
            return try await cache.image(source: .journal(try XCTUnwrap(message.imageReference)), index: index, pixels: pixels)
        }
        let row = TranscriptRowContainer(item: .message(message), fresh: false, actions: actions)
        let height = row.measure(width: 500).height
        row.frame = CGRect(x: 0, y: 0, width: 500, height: height); row.layoutForViewport()
        XCTAssertEqual(row.hostedFittingHeight, height)
        XCTAssertEqual(loads, 0, "Measuring an unmounted row must not start an image read")
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: height + 50), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.contentView = nil; window.close() }
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(row); row.layoutSubtreeIfNeeded()
        try await eventually("visible thumbnails ask for pixels") { loads == 2 }
        let frames = TranscriptImageRowTests.views(TranscriptImageButton.self, in: row).map(\.frame)
        release?.resume(); release = nil
        try await eventually("both thumbnails arrive") { TranscriptImageRowTests.views(TranscriptImageButton.self, in: row).allSatisfy { $0.bitmap != nil } }
        XCTAssertEqual(row.measure(width: 500).height, height)
        XCTAssertEqual(row.hostedFittingHeight, height, "The native row's actual height stays fixed too")
        XCTAssertEqual(TranscriptImageRowTests.views(TranscriptImageButton.self, in: row).map(\.frame), frames)
        window.contentView = nil
        XCTAssertTrue(TranscriptImageRowTests.views(TranscriptImageButton.self, in: row).allSatisfy { $0.bitmap == nil }, "Unmounted rows release pixels to the bounded cache")
    }

    @MainActor func testAnUnmountedRowIgnoresALateImageAndNarrowRowsWrapBeforeLoading() async throws {
        var release: CheckedContinuation<Void, Never>?
        var finished = false
        let data = try TranscriptImageTests.image(), source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let bitmap = TranscriptImageBitmap(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        var actions = TranscriptActions()
        actions.loadImage = { _, _, _ in await withCheckedContinuation { release = $0 }; finished = true; return bitmap }
        let message = try TranscriptImageTests.message(count: 1)
        let row = TranscriptRowContainer(item: .message(message), fresh: false, actions: actions)
        let height = row.measure(width: 200).height
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.contentView = nil; window.close() }
        row.frame = CGRect(x: 0, y: 0, width: 200, height: height); window.contentView?.addSubview(row); row.layoutForViewport(); row.layoutSubtreeIfNeeded()
        try await eventually("read started") { release != nil }
        row.removeFromSuperview(); release?.resume(); release = nil
        try await eventually("the cancelled loader returns") { finished }
        XCTAssertNil(TranscriptImageRowTests.views(TranscriptImageButton.self, in: row).first?.bitmap)
        XCTAssertEqual(TranscriptImageMetrics.height(count: 4, width: 140), 134)
        XCTAssertEqual(TranscriptImageMetrics.height(count: 4, width: 64), 274)
    }

    @MainActor func testAReadFailureKeepsTheSlotAndExplainsItInTheOwnViewer() async throws {
        let message = try TranscriptImageTests.message(count: 1)
        var actions = TranscriptActions()
        actions.loadImage = { _, _, _ in throw HostError.failure("The generated image is missing.") }
        let row = TranscriptRowContainer(item: .message(message), fresh: false, actions: actions)
        let height = row.measure(width: 500).height
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.contentView = nil; window.close() }
        row.frame = CGRect(x: 0, y: 0, width: 500, height: height); window.contentView?.addSubview(row); row.layoutForViewport()
        let button = try XCTUnwrap(TranscriptImageRowTests.views(TranscriptImageButton.self, in: row).first)
        try await eventually("failure is explained") { button.toolTip?.contains("generated image is missing") == true }
        XCTAssertEqual(row.hostedFittingHeight, height)
        XCTAssertEqual(button.accessibilityLabel(), "Image 1 of 1")
        let preview = FilePreview(imageName: "Image 1 of 1", load: { throw HostError.failure("The generated image is missing.") })
        preview.load(); await preview.readingTask?.value
        XCTAssertEqual(preview.error, "The generated image is missing."); XCTAssertNil(preview.image)
        preview.close()
    }

    @MainActor func testTheOwnViewerRequestsALargerBitmap() async throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try TranscriptImageTests.image() as CFData, nil))
        let bitmap = TranscriptImageBitmap(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        var requested: [Int] = []
        let viewer = TranscriptImageViewer(label: "Image 2 of 2", load: { pixels in requested.append(pixels); return bitmap }, dismiss: {})
        viewer.preview.load(); await viewer.preview.readingTask?.value
        XCTAssertEqual(requested, [2_048])
        XCTAssertNotNil(viewer.preview.image)
        XCTAssertEqual(TranscriptImageRowTests.views(FilePreviewView.self, in: viewer).count, 1)
        viewer.preview.close()
    }
}
