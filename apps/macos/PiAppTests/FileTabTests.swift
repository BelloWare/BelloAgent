import XCTest
import AppKit
import FileView
import PDFKit
@testable import PiApp

/// A file as a tab (`FileTab`): read only in a trusted project or outside
/// any, missing with the reason otherwise, or when the file is gone; one tab
/// a file whichever path reached it; and nothing read before it is shown.
final class FileTabTests: XCTestCase {
    @MainActor func testLiveFollowDoesNotReadASymlinkReplacementUnderTheOriginalTrust() async throws {
        let url = try file("trusted.txt", Data("original".utf8)), secret = try file("private.txt", Data("private replacement".utf8))
        let tab = FileTab(url: url, projectID: nil)
        tab.didShow()
        defer { tab.willClose() }
        let old = try XCTUnwrap(tab.document)
        try await eventually("the original read and watch") { old.status == .ready && tab.isWatching }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: secret)
        try await eventually("the replacement is refused") { tab.missingReason != nil }
        XCTAssertTrue(tab.document === old, "no reading of the new target replaces the approved file")
        // Explicit opening resolves the new target to a different tab key,
        // where the workspace checks its project trust afresh.
        XCTAssertNotEqual(FileTab.key(for: url), tab.key)
    }

    @MainActor func testAPreviewDoesNotDecodeARedirectedPath() async throws {
        let image = NSImage(size: NSSize(width: 100, height: 100))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 100, height: 100).fill(); image.unlockFocus()
        let pdf = PDFDocument(); pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let bytes = try XCTUnwrap(pdf.dataRepresentation()), url = try file("preview.pdf", bytes), target = try file("other.pdf", bytes)
        let preview = FilePreview(url: url)
        defer { preview.close() }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        preview.load()
        try await eventually("the redirected preview is refused") { preview.error != nil }
        XCTAssertNil(preview.pdf)
    }

    @MainActor func testLiveFollowKeepsTheViewScrollAndSelectionAcrossAnAtomicSaveAndRecreation() async throws {
        let source = (0..<200).map { "Line \($0)" }.joined(separator: "\n")
        let url = try file("follow.txt", Data(source.utf8))
        let tab = FileTab(url: url, projectID: nil)
        tab.didShow()
        defer { tab.willClose() }
        let scroll = try XCTUnwrap(tab.scroll)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.contentView = nil; window.close() }
        let old = try XCTUnwrap(tab.document)
        try await eventually("read and watching") { old.status == .ready && tab.isWatching }
        let view = scroll.textView
        view.select(from: FileTextPosition(line: 10, column: 1), to: FileTextPosition(line: 12, column: 2))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 600)); scroll.reflectScrolledClipView(scroll.contentView)
        let origin = scroll.contentView.bounds.origin
        let selection = view.selectedRange
        try (source + "\nAn appended line").write(to: url, atomically: true, encoding: .utf8)
        try await eventually("the replacement is read") { tab.document !== old && tab.status == .ready }
        XCTAssertTrue(tab.scroll === scroll)
        XCTAssertTrue(scroll.textView === view)
        XCTAssertEqual(view.selectedRange.start, selection.start); XCTAssertEqual(view.selectedRange.end, selection.end)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, origin.y, accuracy: 1)
        try FileManager.default.removeItem(at: url)
        try await eventually("deletion is shown") { tab.missingReason != nil }
        try source.write(to: url, atomically: true, encoding: .utf8)
        try await eventually("the recreated file is followed") { tab.missingReason == nil && tab.status == .ready }
        XCTAssertTrue(tab.scroll === scroll)
        tab.didHide()
        XCTAssertFalse(tab.isWatching)
        let hidden = tab.document
        try (source + "\nSaved while hidden").write(to: url, atomically: true, encoding: .utf8)
        tab.didShow()
        try await eventually("showing again follows the hidden save") { tab.document !== hidden && tab.status == .ready }
    }

    @MainActor func testImagePreviewDownsamplesAndTrustRevocationDropsIt() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 6_000, pixelsHigh: 40,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let url = try file("wide.png", try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
        var trusted = true
        FileTab.resolveProject = { _ in trusted ? .trusted(name: "images", root: url.deletingLastPathComponent().path) : .untrusted(name: "images") }
        let tab = FileTab(url: url, projectID: "images")
        defer { tab.willClose() }
        let preview = tab.preview
        preview.load()
        try await eventually("the image preview") { preview.image != nil }
        let representation = try XCTUnwrap(preview.image?.representations.first as? NSBitmapImageRep)
        XCTAssertLessThanOrEqual(representation.pixelsWide, 2_048)
        XCTAssertLessThanOrEqual(representation.pixelsHigh, 2_048)
        let decoded = try XCTUnwrap(representation.cgImage)
        XCTAssertEqual(decoded.width, representation.pixelsWide)
        XCTAssertEqual(decoded.height, representation.pixelsHigh)
        XCTAssertNil(tab.document, "an image is not read as text")
        trusted = false; tab.projectsChanged()
        XCTAssertNil(preview.image)
        XCTAssertFalse(tab.isWatching)
    }

    @MainActor func testPDFPreviewUsesPDFKitAndKeepsItsViewAcrossReloads() async throws {
        let image = NSImage(size: NSSize(width: 200, height: 300))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 200, height: 300).fill(); image.unlockFocus()
        let document = PDFDocument()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let url = try file("document.pdf", try XCTUnwrap(document.dataRepresentation()))
        let preview = FilePreview(url: url)
        defer { preview.close() }
        preview.load()
        try await eventually("the PDF preview") { preview.pdf != nil }
        let view = preview.pdfView
        view.document = preview.pdf
        XCTAssertEqual(preview.pdf?.pageCount, 1)
        let first = preview.pdf
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 1)
        try XCTUnwrap(document.dataRepresentation()).write(to: url, options: .atomic)
        preview.load()
        try await eventually("the changed PDF is read") { preview.pdf !== first && preview.pdf?.pageCount == 2 }
        XCTAssertTrue(preview.pdfView === view)
        XCTAssertTrue(view.document === preview.pdf)
    }

    @MainActor func testPreviewRetriesAnUnreadableFileWithoutRequiringItsMetadataToChange() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = try file("retry.png", Data(repeating: 0, count: png.count)), preview = FilePreview(url: url)
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        defer { preview.close() }
        preview.load()
        try await eventually("preview failure") { preview.error != nil && !preview.loading }
        // Replace invalid bytes with a valid image, retaining every field
        // of the cached fingerprint. A failure must never cache a no-op.
        try png.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, stamp)
        XCTAssertEqual(attributes[.systemFileNumber] as? NSNumber, inode)
        preview.load()
        try await eventually("the retry decodes the image") { preview.image != nil && preview.error == nil }
    }

    private var folder: URL!
    @MainActor override func setUp() async throws {
        folder = scratchRoot("file-tab")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folder = folder!
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        addTeardownBlock { @MainActor in FileTab.resolveProject = { $0 == nil ? .none : .removed } }
    }
    private func file(_ name: String, _ data: Data = Data("one\ntwo".utf8)) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @MainActor func testAFileIsReadOnlyInATrustedProject() async throws {
        var trusted = false
        FileTab.resolveProject = { id in id == nil ? .none : trusted ? .trusted(name: "proj", root: "/x") : .untrusted(name: "proj") }
        let tab = FileTab(url: try file("a.txt"), projectID: "p")
        XCTAssertNil(tab.document, "not read in a project not trusted")
        XCTAssertEqual(tab.missingReason, "Its project, proj, is not trusted.")
        XCTAssertEqual(tab.symbol, "doc.text")
        tab.projectsChanged()
        trusted = true
        tab.projectsChanged()
        XCTAssertNil(tab.missingReason)
        let document = try XCTUnwrap(tab.document, "read once trusted")
        try await eventually("read") { document.status == .ready }
        trusted = false
        tab.projectsChanged()
        XCTAssertFalse(document.isReading, "and let go of when no longer trusted")
        XCTAssertFalse(tab.hasDocument)
        XCTAssertEqual(tab.symbol, "exclamationmark.triangle")
    }

    @MainActor func testARemovedProjectAndAFileGoneAreMissing() async throws {
        FileTab.resolveProject = { $0 == nil ? .none : .removed }
        XCTAssertEqual(FileTab(url: try file("b.txt"), projectID: "gone").missingReason, "Its project was removed from Bello Agent.")
        let gone = FileTab(url: folder.appendingPathComponent("nowhere.txt"), projectID: nil)
        _ = gone.document
        try await eventually("found missing") { gone.missingReason != nil }
        XCTAssertEqual(gone.missingReason, "It is not there any more, or can't be opened.")
    }

    @MainActor func testOneTabAFileWhicheverPathReachedIt() throws {
        let url = try file("c.txt")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.txt"), withDestinationURL: url)
        let direct = FileTab.key(for: url)
        XCTAssertEqual(FileTab.key(for: folder.appendingPathComponent("sub/../c.txt")), direct)
        XCTAssertEqual(FileTab.key(for: folder.appendingPathComponent("link.txt")), direct)
    }

    /// A file found not to be text, whose project stops and starts being
    /// trusted, is read again from the start: what was known of it goes with
    /// the reading.
    @MainActor func testTrustComingBackReadsTheFileAgain() async throws {
        var trusted = true
        FileTab.resolveProject = { id in id == nil ? .none : trusted ? .trusted(name: "proj", root: "/x") : .untrusted(name: "proj") }
        let url = try file("e.bin", Data([0x00, 0x01, 0x02]))
        let tab = FileTab(url: url, projectID: "p")
        _ = tab.document
        try await eventually("known not to be text") { tab.status == .binary }
        trusted = false; tab.projectsChanged()
        XCTAssertEqual(tab.status, .indexing, "what was known went with the reading")
        try Data("now text".utf8).write(to: url)
        trusted = true; tab.projectsChanged()
        let document = try XCTUnwrap(tab.document)
        try await eventually("read again") { document.status == .ready }
        try await eventually("its text, read again") { document.text(ofLine: 0, range: 0..<8) == "now text" }
    }

    /// Lines asked for in a tab not shown yet are shown when it is.
    @MainActor func testLinesAskedForBeforeATabIsShownAreShownWhenItIs() async throws {
        let root = scratchRoot("file-tab-model")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.tabs.showsWindows = false
        let url = try file("f.txt", Data((0..<300).map { "row \($0)" }.joined(separator: "\n").utf8))
        let tab = model.openFile(url)
        _ = model.openFile(try file("g.txt"))
        XCTAssertTrue(model.openFile(url, lines: 200...201) === tab, "the tab already open")
        let scroll = try XCTUnwrap(tab.scroll)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = scroll
        try await eventually("shown at the lines") { scroll.textView.emphasized == 200...201 }
    }

    /// The workspace going closes its tabs and their files.
    @MainActor func testTheWorkspaceGoingClosesItsTabs() async throws {
        let root = scratchRoot("file-tab-shutdown")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.tabs.showsWindows = false
        let tab = model.openFile(try file("h.txt"))
        let document = try XCTUnwrap(tab.document)
        _ = model.tabs.popOut(model.openFile(try file("i.txt")))
        model.shutdown()
        XCTAssertTrue(model.tabs.allTabs.isEmpty)
        XCTAssertTrue(model.tabs.windows.isEmpty)
        XCTAssertFalse(document.isReading, "its file closed")
        XCTAssertFalse(tab.hasContent)
    }

    @MainActor func testNothingIsReadBeforeTheTabIsShownAndABinaryIsSaidToBe() async throws {
        let tab = FileTab(url: try file("d.bin", Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])), projectID: nil)
        XCTAssertFalse(tab.hasDocument)
        XCTAssertFalse(tab.hasContent)
        _ = tab.document
        try await eventually("known") { tab.status == .binary }
        XCTAssertNil(tab.missingReason)
    }
}
