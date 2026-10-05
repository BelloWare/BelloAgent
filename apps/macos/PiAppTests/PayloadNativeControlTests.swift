import AppKit
import XCTest
@testable import PiApp

@MainActor final class PayloadNativeControlTests: XCTestCase, SerialTestLane {
    private func body(_ bytes: @escaping () -> Data, reads: @escaping () -> Void = {}) -> CapturedBodySource {
        CapturedBodySource(metadata: {
            let value = bytes()
            return CapturedBodyMetadata(body: ["state": .string("partial"), "retainedBytes": .number(Double(value.count)), "observedBytes": .number(Double(value.count))], hash: nil)
        }, page: { offset in reads(); let value = bytes(); return (value.subdata(in: offset..<min(offset + 32768, value.count)), value.count) })
    }
    private func attach(_ view: NSView, size: CGSize = CGSize(width: 700, height: 460)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil); window.contentView = nil; window.close() }
        return window
    }
    func testPagedTextReusesStorageAndSelectionForAnUnchangedRead() {
        let view = PagedTextView(text: "Line one\nLine two 🌍")
        let storage = view.editor.textStorage
        let selected = NSRange(location: 5, length: 3)
        view.editor.setSelectedRange(selected)
        view.text = view.text
        XCTAssertTrue(view.editor.textStorage === storage)
        XCTAssertEqual(view.editor.selectedRange(), selected)
        XCTAssertFalse(view.editor.isEditable); XCTAssertTrue(view.editor.isSelectable)
        XCTAssertEqual(view.editor.accessibilityLabel(), "Read-only payload text")
    }
    func testRefinedSearchReplacesHighlightsWithoutReplacingTextStorage() throws {
        let initial = try PayloadSearchResult.find(text: "answer and another", query: "a")
        let view = PayloadSearchTextView(result: initial, selected: 0)
        let storage = view.editor.textStorage
        let refined = try PayloadSearchResult.find(text: initial.text, query: "another", textID: initial.textID)
        view.update(result: refined, selected: 0)
        XCTAssertTrue(view.editor.textStorage === storage)
        XCTAssertEqual(view.editor.string, initial.text)
        XCTAssertEqual(view.editor.selectedRange(), refined.matches[0])
        XCTAssertNil(view.editor.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil))
        XCTAssertNotNil(view.editor.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: refined.matches[0].location, effectiveRange: nil))
    }
    func testGrowthAndSearchDoNotReadAgainUntilLoadLatest() async throws {
        var bytes = Data(#"{"message":"first retained body"}"#.utf8), reads = 0
        var copy: CapturedBodyCopySource?
        let view = CapturedBodyView(source: body({ bytes }, reads: { reads += 1 }), sessionID: "s", attemptID: "a", kind: "request", retained: false,
                                    onCopySource: { copy = $0 })
        let window = attach(view)
        try await eventually("The complete first body is loaded", timeout: .seconds(3)) { view.controller.document != nil && copy != nil }
        let before = reads
        bytes = Data(#"{"message":"the newer retained body"}"#.utf8)
        view.update(growingBytes: bytes.count + 10)
        view.update(searchQuery: "retained", searchHeaders: ["content-type": .string("application/json")], growingBytes: bytes.count + 10)
        try await eventually("The retained body search finishes", timeout: .seconds(3)) { view.search.result != nil && !view.search.loading }
        XCTAssertEqual(reads, before, "Polling growth and refining a query must never reread the retained bytes")
        view.update(growingBytes: bytes.count + 10)
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        view.latestButton.onPress?()
        try await eventually("Load latest replaces the body", timeout: .seconds(3)) { view.controller.document?.bytes == bytes && copy?.id == view.controller.document?.id && !view.controller.loading }
        XCTAssertEqual(reads, before + 1)
        let copied = try await XCTUnwrap(copy).render()
        XCTAssertTrue(copied.contains("newer retained"))
    }
    func testAReadInPlaceKeepsItsOpenJSONSections() async throws {
        var bytes = Data(#"{"nested":{"old":1},"text":"first"}"#.utf8)
        let view = CapturedBodyView(source: body({ bytes }), sessionID: "s", attemptID: "a", kind: "request", retained: false)
        _ = attach(view)
        try await eventually("The initial JSON outline is ready", timeout: .seconds(3)) { view.controller.document != nil }
        view.layoutSubtreeIfNeeded()
        func outline(in view: NSView) -> NSOutlineView? { if let value = view as? NSOutlineView { return value }; return view.subviews.compactMap { outline(in: $0) }.first }
        let original = try XCTUnwrap(outline(in: view))
        let firstRoot = try XCTUnwrap(original.item(atRow: 0) as? JSONOutlineNode)
        original.expandItem(firstRoot.child(0))
        let id = try XCTUnwrap(view.controller.document?.id)
        bytes = Data(#"{"nested":{"new":2,"old":1},"text":"first"}"#.utf8)
        view.update(revision: 1)
        try await eventually("The same body's newer read is installed", timeout: .seconds(3)) { view.controller.document?.replaces == id && !view.controller.loading }
        view.layoutSubtreeIfNeeded()
        let updated = try XCTUnwrap(outline(in: view)), root = try XCTUnwrap(updated.item(atRow: 0) as? JSONOutlineNode)
        XCTAssertTrue(updated === original)
        XCTAssertTrue(updated.isItemExpanded(root.child(0)))
        XCTAssertEqual(root.child(0).count, 2)
    }
    func testLeavingTheBodyReleasesCopySourceAndCancelsTheReader() async throws {
        let bytes = Data(#"{"value":"retained"}"#.utf8)
        var copy: CapturedBodyCopySource?
        let view = CapturedBodyView(source: body({ bytes }), sessionID: "s", attemptID: "a", kind: "request", retained: false,
                                    onCopySource: { copy = $0 })
        let window = attach(view)
        try await eventually("The copy source is ready", timeout: .seconds(3)) { copy != nil }
        window.contentView = nil
        XCTAssertNil(copy); XCTAssertNil(view.controller.document); XCTAssertFalse(view.controller.loading)
    }
    func testMCPRemovalStateAndInheritedDisablingDoNotStartAHelper() async throws {
        let root = scratchRoot("native-mcp-controls")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        model.selectedWorkspaceID = "project"
        model.configuration.mcp["project"] = .object(["servers": .object(["local": .object(["command": .string("fixture-command")])])])
        let view = NativeMCPInspector(model: model)
        XCTAssertTrue(view.remove.isEnabled)
        XCTAssertNil(view.window)
        view.inheritedEnabled = false
        XCTAssertFalse(view.remove.isEnabled); XCTAssertFalse(view.refresh.isEnabled)
        XCTAssertFalse(view.configurationEditor.editor.isEditable)
        view.inheritedEnabled = true
        XCTAssertTrue(view.remove.isEnabled)
        model.mcpRemovalInProgress = true
        try await eventually("MCP removal holds the native control disabled", timeout: .seconds(1)) { !view.remove.isEnabled }
        model.mcpRemovalInProgress = false
        model.configuration.mcp["project"] = .object(["servers": .object([:])])
        try await eventually("The empty configuration reaches the native controls", timeout: .seconds(1)) { view.refresh.isEnabled }
        XCTAssertFalse(view.remove.isEnabled)
        XCTAssertEqual(model.mcpServerCount("project"), 0)
    }
}
