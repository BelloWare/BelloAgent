import AppKit
import XCTest
@testable import PiApp

@MainActor final class PayloadNativeControlTests: XCTestCase, SerialTestLane {
    private func workspace(_ name: String) -> WorkspaceModel {
        let root = scratchRoot(name)
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        addTeardownBlock { @MainActor in model.shutdown(); try? FileManager.default.removeItem(at: root) }
        return model
    }
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
    func testReaderSplitKeepsTheDraggedDividerAndItsLimitsWhileResizing() {
        let split = PayloadSplit(leading: NSView(), trailing: NSView(), minimum: 290, ideal: 340, maximum: 430, trailingMinimum: 480)
        func resize(_ width: CGFloat) {
            split.frame = NSRect(x: 0, y: 0, width: width, height: 400)
            split.needsLayout = true; split.layoutSubtreeIfNeeded()
        }
        resize(1052)
        split.setPosition(380, ofDividerAt: 0)
        split.needsLayout = true; split.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, 380, accuracy: 0.5, "Refreshing layout must preserve the reader's divider")
        resize(3200)
        XCTAssertLessThanOrEqual(split.arrangedSubviews[0].frame.width, 438.5, "The list must keep its maximum width as the sheet grows")
        resize(800)
        XCTAssertGreaterThanOrEqual(split.arrangedSubviews[0].frame.width, 297.5, "The list must retain its minimum width")
        XCTAssertGreaterThanOrEqual(split.arrangedSubviews[1].frame.width, 487.5, "The payload must retain its minimum width")
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
        func outline(in view: NSView) -> NSOutlineView? { if let value = view as? NSOutlineView { return value }; return view.subviews.compactMap { outline(in: $0) }.first }
        try await eventually("The initial JSON outline is ready", timeout: .seconds(3)) {
            view.layoutSubtreeIfNeeded()
            return (outline(in: view)?.item(atRow: 0) as? JSONOutlineNode)?.count == 2
        }
        let original = try XCTUnwrap(outline(in: view))
        let firstRoot = try XCTUnwrap(original.item(atRow: 0) as? JSONOutlineNode)
        original.expandItem(firstRoot.child(0))
        let id = try XCTUnwrap(view.controller.document?.id)
        bytes = Data(#"{"nested":{"new":2,"old":1},"text":"first"}"#.utf8)
        view.update(revision: 1)
        try await eventually("The same body's newer read is installed", timeout: .seconds(3)) {
            view.layoutSubtreeIfNeeded()
            return view.controller.document?.replaces == id && !view.controller.loading
                && (outline(in: view)?.item(atRow: 0) as? JSONOutlineNode)?.child(0).count == 2
        }
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
        XCTAssertNil(view.window); XCTAssertTrue(model.hosts.isEmpty)
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
        XCTAssertTrue(model.hosts.isEmpty, "Removing configuration must never reconnect a helper while refreshing controls")
    }
    func testClosingDuringConversationSearchReleasesItsViewBeforeTheReadReturns() async throws {
        let model = workspace("conversation-search-release"), gate = PayloadReadGate<ContentSearch>()
        let empty = ContentSearch(hits: [], total: 0, next: nil, revision: "r")
        defer { gate.finish(empty) }
        let source = ConversationContentSource(search: { _, _ in await gate.read() }, page: { _, _, _, _ in .init(text: "", next: nil) }, reveal: { _ in })
        var view: ConversationContentView? = ConversationContentView(model: model, sessionID: "s", source: source)
        weak var released = view
        let window = attach(try XCTUnwrap(view), size: ConversationContentView.size)
        try await eventually("The conversation search has started") { gate.started }
        window.makeFirstResponder(nil); window.contentView = nil; view = nil
        try await eventually("The closed conversation sheet releases while search is still pending") { autoreleasepool { released == nil } }
        gate.finish(empty)
        try await eventually("The cancelled search has returned") { gate.returned }
        XCTAssertTrue(model.hosts.isEmpty)
    }
    func testClosingDuringResourceOptionsDoesNotStartDiscoveryAfterTheAnswer() async throws {
        let model = workspace("resource-options-release"), gate = PayloadReadGate<[String: WireValue]>()
        model.selectedWorkspaceID = "project"
        var catalogReads = 0, requestReads = 0
        defer { gate.finish([:]) }
        let source = ResourceInspectorSource(options: { _ in await gate.read() }, catalog: { _ in catalogReads += 1 }, request: { _, _, _ in requestReads += 1; return [:] })
        var view: ResourceInspector? = ResourceInspector(model: model, source: source)
        weak var released = view
        let window = attach(try XCTUnwrap(view), size: ResourceInspector.size)
        try await eventually("The resource options read has started") { gate.started }
        window.makeFirstResponder(nil); window.contentView = nil; view = nil
        try await eventually("The closed resource sheet releases while options are still pending") { autoreleasepool { released == nil } }
        gate.finish([:])
        try await eventually("The cancelled options read has returned") { gate.returned }
        XCTAssertEqual(catalogReads, 0); XCTAssertEqual(requestReads, 0)
        XCTAssertTrue(model.hosts.isEmpty, "An options answer from a closed sheet must not start resource helpers")
    }
    func testClosingDuringMCPDiscoveryReleasesItsViewBeforeTheHelperAnswers() async throws {
        let model = workspace("mcp-discovery-release"), gate = PayloadReadGate<[String: WireValue]>()
        defer { gate.finish([:]) }
        let source = ResourceInspectorSource(options: { _ in [:] }, catalog: { _ in }, request: { _, _, _ in await gate.read() })
        var view: NativeMCPInspector? = NativeMCPInspector(model: model, source: source)
        weak var released = view
        let window = attach(try XCTUnwrap(view))
        try await eventually("MCP discovery has started") { gate.started }
        window.makeFirstResponder(nil); window.contentView = nil; view = nil
        try await eventually("The closed MCP view releases while discovery is still pending") { autoreleasepool { released == nil } }
        gate.finish(["servers": .array([.object(["server": .string("late")])])])
        try await eventually("The cancelled discovery has returned") { gate.returned }
    }
    func testClosingDuringRetainedCopyPreservesTheClipboard() async throws {
        let model = workspace("conversation-copy-release"), gate = PayloadReadGate<ContentPage>()
        let page = ContentPage(text: "Late retained text", next: nil)
        defer { gate.finish(page) }
        let source = ConversationContentSource(search: { _, _ in .init(hits: [], total: 1, next: nil, revision: "r") }, page: { _, _, _, _ in await gate.read() }, reveal: { _ in })
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep the current clipboard", forType: .string)
        let before = pasteboard.changeCount
        var view: ConversationContentView? = ConversationContentView(model: model, sessionID: "s", source: source, pasteboard: pasteboard)
        weak var released = view
        let window = attach(try XCTUnwrap(view), size: ConversationContentView.size)
        try await eventually("The retained range is ready to copy") { view?.copyAll.isEnabled == true }
        view?.copyAll.onPress?()
        try await eventually("Copy is reading retained text") { gate.started }
        window.makeFirstResponder(nil); window.contentView = nil; view = nil
        try await eventually("Copy does not retain a closed conversation view") { autoreleasepool { released == nil } }
        gate.finish(page)
        try await eventually("The cancelled copy read has returned") { gate.returned }
        XCTAssertEqual(pasteboard.string(forType: .string), "Keep the current clipboard")
        XCTAssertEqual(pasteboard.changeCount, before)
    }
    func testClosingDuringRetainedExportDoesNotWriteAFile() async throws {
        let model = workspace("conversation-export-release"), gate = PayloadReadGate<ContentPage>()
        let page = ContentPage(text: "Late retained export", next: nil), root = scratchRoot("closed-export")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { gate.finish(page); try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("conversation.md"), oldChooser = PiQuestion.shared.chooseFiles
        PiQuestion.shared.chooseFiles = { [url] }
        defer { PiQuestion.shared.chooseFiles = oldChooser }
        let source = ConversationContentSource(search: { _, _ in .init(hits: [], total: 1, next: nil, revision: "r") }, page: { _, _, _, _ in await gate.read() }, reveal: { _ in })
        var view: ConversationContentView? = ConversationContentView(model: model, sessionID: "s", source: source)
        weak var released = view
        let window = attach(try XCTUnwrap(view), size: ConversationContentView.size)
        try await eventually("The retained conversation is ready to export") { view?.exportButton.isEnabled == true }
        view?.exportButton.onPress?()
        try await eventually("Export is reading retained text") { gate.started }
        window.makeFirstResponder(nil); window.contentView = nil; view = nil
        try await eventually("Export does not retain a closed conversation view") { autoreleasepool { released == nil } }
        gate.finish(page)
        try await eventually("The cancelled export read has returned") { gate.returned }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testClosingDuringMCPConfirmationRejectsTheLateAcceptedInvocation() async throws {
        let model = workspace("mcp-confirmation-release")
        model.chats = [ChatRecord(id: "editing", workspaceID: "project", title: "Editing", path: nil, profileID: "p")]
        model.resourceTargetSessionID = "editing"
        var requests: [String] = [], answer: ((NSApplication.ModalResponse) -> Void)?
        let oldPresenter = PiQuestion.shared.present
        PiQuestion.shared.present = { _, _, completion in answer = completion }
        defer { answer?(.alertSecondButtonReturn); PiQuestion.shared.present = oldPresenter; PiQuestion.shared.cancel() }
        let source = ResourceInspectorSource(options: { _ in [:] }, catalog: { _ in }, request: { method, _, _ in requests.append(method); return [:] })
        var view: NativeMCPInspector? = NativeMCPInspector(model: model, source: source)
        weak var released = view
        let window = attach(try XCTUnwrap(view))
        try await eventually("The initial MCP discovery is complete") { view?.refresh.isEnabled == true }
        view?.serverField.onChange?("preview-server"); view?.toolField.onChange?("preview-tool")
        view?.invokeButton.onPress?()
        try await eventually("The invocation confirmation is waiting") { answer != nil }
        window.makeFirstResponder(nil); window.contentView = nil; view = nil
        try await eventually("The pending confirmation does not retain the closed MCP view") { autoreleasepool { released == nil } }
        let completion = try XCTUnwrap(answer); answer = nil; completion(.alertFirstButtonReturn)
        try await eventually("The cancelled confirmation has completed") { !PiQuestion.shared.asking }
        XCTAssertEqual(requests, ["mcp.list"], "A late accepted question must not invoke a tool after its owning view closes")
        XCTAssertTrue(model.hosts.isEmpty)
    }
}

@MainActor private final class PayloadReadGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    var started: Bool { continuation != nil }
    private(set) var returned = false
    func read() async -> Value {
        let value = await withCheckedContinuation { continuation = $0 }
        returned = true; return value
    }
    func finish(_ value: Value) { let pending = continuation; continuation = nil; pending?.resume(returning: value) }
}
