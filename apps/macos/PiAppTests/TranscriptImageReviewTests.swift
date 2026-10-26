import XCTest
import AppKit
import ImageIO
@testable import PiApp

final class TranscriptImageReviewTests: XCTestCase {
    func testAColdImageIndexUsesItsSnapshotWhenAHelperAppendsDuringTheScan() async throws {
        for tail in ["{\"type\":\"custom\",\"id\":\"later\",\"parentId\":\"padding\"}\n",
                     "{\"type\":\"custom\",\"id\":\"later\""] {
            let journal = try TranscriptImageLoadingTests.Journal(); defer { journal.remove() }
            let padding = WireValue.object(["type": .string("custom"), "id": .string("padding"),
                                            "parentId": .string("answer2"), "data": .string(String(repeating: "x", count: 150_000))])
            let writer = try FileHandle(forWritingTo: journal.path)
            try writer.seekToEnd(); try writer.write(contentsOf: JSONEncoder().encode(padding)); try writer.write(contentsOf: Data([10])); try writer.close()
            let capturedBytes = try Data(contentsOf: journal.path).count
            let reader = HistoryReader(indexDirectory: journal.root), path = journal.path
            await reader.observeIndexChunks { offset in
                guard offset == 65_536 else { return }
                let helper = try FileHandle(forWritingTo: path); defer { try? helper.close() }
                try helper.seekToEnd(); try helper.write(contentsOf: Data(tail.utf8))
            }
            do {
                let reference = try await reader.imageReference(path: path.path, id: "caption")
                let bitmap = try await TranscriptImageCache().image(source: .journal(reference), index: 0, pixels: 128)
                XCTAssertEqual(bitmap.image.width, 128)
            } catch { XCTFail("Appending inside the cold index scan must preserve a complete image: \(error)") }
            let indexed = await reader.indexedRecordCount
            XCTAssertEqual(indexed, 6, "The scan must stop at its captured prefix, before the appended record")
            XCTAssertEqual(try Data(contentsOf: path).count, capturedBytes + tail.utf8.count, "The append happened during the scan and was not repaired")
        }
    }

    /// Fixed-height neighbours isolate placement and virtualization from text
    /// measuring. The image row and document use their production renderers.
    @MainActor private final class Spacer: NSView, TranscriptRowContent {
        weak var owner: TranscriptRowContainer?
        private var height: CGFloat = 0
        init(_ inputs: TranscriptRowInputs) { super.init(frame: .zero); apply(inputs) }
        required init?(coder: NSCoder) { nil }
        func accepts(_ item: TranscriptItem) -> Bool { true }
        func apply(_ inputs: TranscriptRowInputs) {
            if case .message(let message) = inputs.item { height = CGFloat(Double(message.text) ?? 1) }
        }
        func settle() -> (height: CGFloat, passes: Int) { (height, 1) }
        func confirmHeight() -> CGFloat { height }
    }

    @MainActor private final class Pane {
        let page = TranscriptPage()
        let scroll = TranscriptNativeScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let document: TranscriptNativeDocument
        let window: NSWindow
        let image: TranscriptMessage
        var actions = TranscriptActions()
        var lead: CGFloat
        private var sequence = 0
        private let previousRenderer = TranscriptRowRenderer.reference
        init(lead: CGFloat, load: @escaping @MainActor (TranscriptMessage, Int, Int) async throws -> TranscriptImageBitmap) throws {
            self.lead = lead
            image = try TranscriptImageTests.message(id: "image", count: 1)
            TranscriptRowRenderer.reference = { inputs in
                if case .message(let message) = inputs.item, message.id == "image" { return TranscriptNativeUserRow(inputs: inputs) }
                return Spacer(inputs)
            }
            actions.loadImage = load
            document = TranscriptNativeDocument(page: page, geometryCache: TranscriptGeometryCache())
            window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            scroll.documentView = document
            page.readerWillNavigate(upward: true)
            refresh()
            window.contentView = scroll
            window.makeFirstResponder(nil)
        }
        func refresh() {
            sequence += 1
            let messages = [TranscriptMessage(id: "lead", role: "assistant", text: String(Double(lead))), image,
                            TranscriptMessage(id: "streaming", role: "assistant", text: "6000", state: "streaming")]
            let snapshot = TranscriptPage.Snapshot(sessionID: "image-review", messages: messages,
                                                   items: messages.map(TranscriptItem.message), fresh: [], sequence: sequence)
            document.update(snapshot: snapshot, actions: actions, environment: TranscriptRowEnvironment())
            document.layoutRows(width: scroll.contentSize.width)
        }
        var row: TranscriptRowContainer? { document.retainedRows.first { $0.itemID == "image" } }
        func close() {
            window.close(); window.contentView = nil
            TranscriptRowRenderer.reference = previousRenderer
        }
    }

    @MainActor private func bitmap() throws -> TranscriptImageBitmap {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try TranscriptImageTests.image() as CFData, nil))
        return TranscriptImageBitmap(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }
    /// Drain mount/position callbacks already queued by AppKit, without a timer.
    @MainActor private func mounted() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    @MainActor func testAnOriginOnlyPlacementLoadsTheImageWithoutLayingOutItsTreeAgain() async throws {
        let bitmap = try bitmap()
        var loads = 0
        let pane = try Pane(lead: 600) { _, _, _ in loads += 1; return bitmap }; defer { pane.close() }
        let row = try XCTUnwrap(pane.row)
        XCTAssertTrue(row.superview === pane.document, "The image starts in the mounted offscreen buffer")
        for placed in pane.document.retainedRows { placed.layoutForViewport() }
        await mounted()
        let button = try XCTUnwrap(TranscriptImageRowTests.views(TranscriptImageButton.self, in: row).first)
        XCTAssertEqual(loads, 0)
        let bounds = pane.scroll.contentView.bounds, size = row.frame.size
        let layouts = row.nativeSizingPasses, traversals = pane.document.rowLayoutTraversalCount
        XCTAssertFalse(button.convert(button.bounds, to: pane.document).intersects(bounds))
        pane.lead = 100; pane.refresh()
        XCTAssertTrue(pane.row === row)
        XCTAssertEqual(pane.scroll.contentView.bounds, bounds, "Collapsing an earlier row need not scroll the clip")
        XCTAssertTrue(button.convert(button.bounds, to: pane.document).intersects(bounds))
        let reading = button.readingTask
        XCTAssertNotNil(reading, "Positioning an already-mounted row must recheck thumbnail visibility")
        await reading?.value
        XCTAssertEqual(loads, 1); XCTAssertNotNil(button.bitmap)
        XCTAssertEqual(row.frame.size, size)
        XCTAssertEqual(row.nativeSizingPasses, layouts, "An origin-only move must not lay out unchanged image content")
        XCTAssertEqual(pane.document.rowLayoutTraversalCount, traversals + 1, "Only the resized neighbour needs subtree layout")
    }

    @MainActor func testTheViewerSurvivesSourceVirtualizationAndClosesWithItsWindow() async throws {
        let bitmap = try bitmap()
        let pane = try Pane(lead: 1) { _, _, _ in bitmap }; defer { pane.close() }
        let row = try XCTUnwrap(pane.row)
        row.layoutForViewport(); await mounted()
        let button = try XCTUnwrap(TranscriptImageRowTests.views(TranscriptImageButton.self, in: row).first)
        await button.readingTask?.value
        button.performClick(nil)
        let sheet = try XCTUnwrap(pane.window.attachedSheet)
        let viewer = try XCTUnwrap(TranscriptImageRowTests.views(TranscriptImageViewer.self, in: try XCTUnwrap(sheet.contentView)).first)
        await viewer.preview.readingTask?.value
        XCTAssertNotNil(viewer.preview.image)
        pane.window.makeFirstResponder(nil)
        pane.scroll.contentView.scroll(to: CGPoint(x: 0, y: pane.document.frame.height - 400))
        pane.scroll.reflectScrolledClipView(pane.scroll.contentView)
        pane.document.layoutRows(width: pane.scroll.contentSize.width)
        XCTAssertGreaterThan(pane.scroll.contentView.bounds.minY, 2_000, "The reader has followed the response beyond the source row's retention band")
        XCTAssertNil(row.superview, "Following a growing response can virtualize the source row")
        XCTAssertFalse(row.isHosted, "The source tree is released outside the retention band")
        XCTAssertTrue(pane.window.attachedSheet === sheet, "Virtualizing a transcript row must not dismiss the reader's image")
        XCTAssertTrue(sheet.sheetParent === pane.window)
        XCTAssertNotNil(viewer.preview.image, "The viewer owns its pixels independently of thumbnail lifetime")
        pane.window.close()
        XCTAssertNil(pane.window.attachedSheet)
        XCTAssertNil(viewer.preview.image, "Closing the parent must still release viewer work and pixels")
        XCTAssertNil(viewer.preview.readingTask)
    }
}
