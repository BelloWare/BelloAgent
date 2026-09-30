import XCTest
import AppKit
import FileView
@testable import PiApp

/// A file as a tab (`FileTab`): read only in a trusted project or outside
/// any, missing with the reason otherwise, or when the file is gone; one tab
/// a file whichever path reached it; and nothing read before it is shown.
final class FileTabTests: XCTestCase {
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
