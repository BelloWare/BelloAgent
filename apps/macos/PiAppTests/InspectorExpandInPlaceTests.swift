import XCTest
import AppKit
import SwiftUI
@testable import PiApp

/// Request bodies with a long tool result among short messages.
enum InspectorExpandBodies {
    /// `lines` numbered lines of about ninety characters: a monospaced tool
    /// result, each line shorter than the preview's hundred columns.
    static func toolResult(lines: Int) -> String {
        (0..<lines).map { String(format: "%06d", $0) + " | " + String(repeating: "result text ", count: 7) }.joined(separator: "\n")
    }
    static let systemPrompt = (0..<60).map { "Rule \($0): keep the answer short, cite the file you read, and never invent a path that was not listed." }
        .joined(separator: "\n")

    /// A Responses request: instructions, two tools, and `count` items, the
    /// item at `longAt` the result of a read whose call comes just before it.
    static func request(items count: Int = 48, longAt: Int = 3, result: String) -> Data {
        var input: [[String: Any]] = []
        for index in 0..<count {
            if index == longAt - 1 {
                input.append(["type": "function_call", "name": "read", "call_id": "call-1", "arguments": #"{"path":"build.log"}"#])
            } else if index == longAt {
                input.append(["type": "function_call_output", "call_id": "call-1", "output": result])
            } else {
                let user = index % 2 == 0
                input.append(["type": "message", "role": user ? "user" : "assistant",
                              "content": [["type": user ? "input_text" : "output_text", "text": "Message \(index): a short line of the conversation."]]])
            }
        }
        let tools: [[String: Any]] = ["read", "bash"].map { name in
            ["type": "function", "name": name, "description": "The \(name) tool.",
             "parameters": ["type": "object", "properties": ["path": ["type": "string"]]]]
        }
        return try! JSONSerialization.data(withJSONObject: ["model": "gpt-5.4", "instructions": systemPrompt, "tools": tools,
                                                            "input": input, "stream": true])
    }
}

/// The request page on screen, reading one body, with its outline at hand.
@MainActor final class InspectorExpandFixture {
    let window: NSWindow
    let inspector: SessionInspectorModel
    private let root: URL
    var request: InspectorRequestModel { inspector.request }

    init(body: Data, width: CGFloat = 1_100, height: CGFloat = 820) async throws {
        root = scratchRoot("inspector-expand")
        inspector = SessionInspectorModel(scope: SessionUsageScope(sessionID: "session", workspaceID: "project"), title: "Expand",
                                          archive: PayloadArchive(root: root), workspace: nil,
                                          usageLoader: { _, _, _ in throw CaptureFailure.unavailable }, cache: InspectorDocumentCache())
        let request = inspector.request
        request.metadataOverride = { _ in ["outcome": .string("completed")] }
        request.sourceOverride = { _, kind in
            guard kind == "request" else { return nil }
            return CapturedBodySource(metadata: { CapturedBodyMetadata(body: ["state": .string("complete"), "retainedBytes": .number(Double(body.count))], hash: nil) },
                                      page: { _ in throw CaptureFailure.unavailable },
                                      whole: { progress in
                let data = await Task.detached { body }.value
                progress(data.count, data.count)
                return data
            })
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: InspectorRequestPage(inspector: inspector, request: request, compact: false))
        window.orderFront(nil)
        request.setActive(true)
        request.open(InspectorRequestRow(id: "r", wall: 1, turn: "t", purpose: "turn", api: "openai-responses", alias: "ui-fixture",
                                         model: "gpt-5.4", outcome: "completed"), predecessor: nil, previousLabel: nil)
        try await wait("the request's outline", seconds: 60) { self.request.conversation.value != nil && (self.outlineView?.numberOfRows ?? 0) > 3 }
        await settle()
    }

    func close() {
        request.setActive(false)
        window.contentView = nil
        window.close()
        try? FileManager.default.removeItem(at: root)
    }

    static func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }
    var outlineView: InspectorOutlineView? { window.contentView.flatMap { Self.descendants(InspectorOutlineView.self, in: $0).first } }
    var outline: InspectorOutlineView { outlineView! }
    var coordinator: InspectorItemsOutline.Coordinator { outline.coordinator! }
    var clip: NSClipView { outline.enclosingScrollView!.contentView }

    /// The row with this path, if it is in the outline.
    func node(_ path: String) -> InspectorItemsOutline.Node? {
        (0..<outline.numberOfRows).lazy.compactMap { self.outline.item(atRow: $0) as? InspectorItemsOutline.Node }.first { $0.path == path }
    }
    func row(_ path: String) -> Int { node(path).map { outline.row(forItem: $0) } ?? -1 }
    /// The paths of an item's or section's rows.
    func children(_ path: String) -> [String] {
        guard let node = node(path) else { return [] }
        return (0..<outline.numberOfChildren(ofItem: node)).compactMap { (outline.child($0, ofItem: node) as? InspectorItemsOutline.Node)?.path }
    }
    /// The whole text's view in the row `path` + ":text", once it is on screen.
    func textView(_ path: String) -> InspectorTextView? {
        let row = row(path + ":text")
        guard row >= 0 else { return nil }
        return (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? InspectorFullTextCell)?.textView
    }
    /// Where rows `0...last` sit in the document.
    func frames(through last: Int) -> [NSRect] { (0...last).map { outline.rect(ofRow: $0) } }

    func scroll(to y: CGFloat) {
        let scroll = outline.enclosingScrollView!
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    /// Opens an item and shows its whole text by pressing its "Show all", as a click does.
    func showAll(_ path: String) async throws {
        if let node = node(path), !outline.isItemExpanded(node) { outline.expandItem(node); await settle() }
        let more = try XCTUnwrap(node(path + ":more"), "\(path) has a Show all link")
        coordinator.activate(more, in: outline)
        try await wait("\(path) shown whole") { self.node(path + ":text") != nil && self.textView(path) != nil }
        await settle()
    }

    func settle(_ frames: Int = 6) async {
        for _ in 0..<frames {
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    func wait(_ what: String, seconds: Double = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out waiting for " + what); throw CancellationError() }
            if case .failed(let message) = request.conversation { XCTFail(message); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// "Show all" in the Inspector opens a text in place: the item grows in the
/// outline, its whole text where its preview was, selectable, with "Show
/// less" to fold it; nothing above it moves and the view keeps its place.
final class InspectorExpandInPlaceTests: XCTestCase {
    static let result = InspectorExpandBodies.toolResult(lines: 400)

    @MainActor func testShowAllPutsTheWholeTextWhereThePreviewWasAndShowLessFoldsItBack() async throws {
        let fixture = try await InspectorExpandFixture(body: InspectorExpandBodies.request(result: Self.result))
        defer { fixture.close() }
        let outline = fixture.outline
        let item = try XCTUnwrap(fixture.node("item:3"), "The tool result is listed")
        outline.expandItem(item); await fixture.settle()
        let preview = fixture.children("item:3")
        XCTAssertEqual(preview.count, RequestDocument.wrap(RequestDocument.prefix(Self.result as NSString, limit: RequestDocument.previewLimit)).count + 1,
                       "The preview's lines, then Show all")
        XCTAssertEqual(preview.last, "item:3:more")
        let header = outline.row(forItem: item)
        let above = fixture.frames(through: header)
        let origin = fixture.clip.bounds.origin
        let rows = outline.numberOfRows

        try await fixture.showAll("item:3")
        XCTAssertEqual(fixture.children("item:3"), ["item:3:text", "item:3:less"], "The whole text in place of the preview, then Show less")
        XCTAssertEqual(fixture.frames(through: header), above, "Nothing above the item moved")
        XCTAssertEqual(fixture.clip.bounds.origin, origin, "The view kept its place")
        XCTAssertEqual(outline.numberOfRows, rows - preview.count + 2, "The item's rows are the text and its link; no other row changed")
        let view = try XCTUnwrap(fixture.textView("item:3"))
        XCTAssertEqual(view.string, Self.result, "The whole text, every character")
        XCTAssertTrue(view.attached, "The text view holds its layout while it is on screen")
        let textRow = fixture.row("item:3:text")
        XCTAssertEqual(outline.rect(ofRow: textRow).height, view.laidOut.height + InspectorFullTextCell.bottom, "The row is as tall as the text")
        XCTAssertEqual(view.laidOut.height, CGFloat(400) * InspectorTextStyle.lineHeight, accuracy: 0.5, "One 18 pt line per line of the result, as the preview drew them")
        XCTAssertEqual(outline.rect(ofRow: textRow).minY, outline.rect(ofRow: header).maxY, "The text starts where the preview's first line did")

        // Show less: the preview and Show all again, in the same place.
        let less = try XCTUnwrap(fixture.node("item:3:less"))
        fixture.coordinator.activate(less, in: outline)
        await fixture.settle()
        XCTAssertEqual(fixture.children("item:3"), preview, "The preview is back")
        XCTAssertEqual(fixture.frames(through: header), above, "Nothing above the item moved")
        XCTAssertEqual(fixture.clip.bounds.origin, origin)
        XCTAssertNil(fixture.coordinator.expansion(for: .item(3)))
        XCTAssertFalse(view.attached, "The text view let go of its layout")

        // A section's whole text, the same way: the system prompt.
        try await fixture.showAll("section:system")
        XCTAssertEqual(fixture.textView("section:system")?.string, InspectorExpandBodies.systemPrompt)
        XCTAssertEqual(fixture.children("section:system"), ["section:system:text", "section:system:less"])
    }

    /// The whole text selects like any text: a drag across lines selects
    /// them, and copying gives one text with its line breaks.
    @MainActor func testTheWholeTextSelectsAcrossLinesAndCopiesAsOneText() async throws {
        let fixture = try await InspectorExpandFixture(body: InspectorExpandBodies.request(result: Self.result))
        defer { fixture.close() }
        try await fixture.showAll("item:3")
        let view = try XCTUnwrap(fixture.textView("item:3"))
        XCTAssertTrue(view.isSelectable); XCTAssertFalse(view.isEditable)
        XCTAssertTrue(fixture.outline.validateProposedFirstResponder(view, for: nil), "A press in the text goes to the text, not to the row")
        XCTAssertTrue(fixture.window.makeFirstResponder(view))

        // A drag from the middle of line 2 to the middle of line 5.
        let line = InspectorTextStyle.lineHeight
        let start = NSPoint(x: 120, y: line * 2.5), end = NSPoint(x: 300, y: line * 5.5)
        var time = ProcessInfo.processInfo.systemUptime
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            time += 0.05
            return NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: time,
                                      windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                      pressure: type == .leftMouseUp ? 0 : 1)!
        }
        let down = mouse(.leftMouseDown, start)
        NSApp.postEvent(mouse(.leftMouseDragged, NSPoint(x: 200, y: line * 4)), atStart: false)
        NSApp.postEvent(mouse(.leftMouseDragged, end), atStart: false)
        NSApp.postEvent(mouse(.leftMouseUp, end), atStart: false)
        // Should the drag's own loop miss the posted events, a release ends it.
        let windowNumber = fixture.window.windowNumber, location = view.convert(end, to: nil), when = time + 1
        let safety = Timer(timeInterval: 3, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let release = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: when, windowNumber: windowNumber,
                                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { return }
                NSApp.postEvent(release, atStart: false)
            }
        }
        RunLoop.main.add(safety, forMode: .common)
        view.mouseDown(with: down)
        safety.invalidate()

        let selected = view.selectedRange()
        XCTAssertGreaterThan(selected.length, 0, "The drag selected text")
        let expected = (Self.result as NSString).substring(with: selected)
        XCTAssertEqual(expected.components(separatedBy: "\n").count, 4, "The selection spans four lines: \(expected)")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("inspector-expand-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        // As Copy writes it: every type the text view writes.
        XCTAssertTrue(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), expected, "Copy gives the lines as one text")

        // Select All selects every character.
        view.selectAll(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: (Self.result as NSString).length))
        // Its menu: Copy, the whole text, Select All and Show Less.
        let menu = view.menuEntries()
        let titles = menu.compactMap { entry -> String? in if case .item(let item) = entry { return item.title } else { return nil } }
        XCTAssertEqual(titles, ["Copy", "Copy All 35,999 Characters", "Select All", "Show Less"].map { $0.replacingOccurrences(of: "35,999", with: TranscriptActivity.grouped(Double((Self.result as NSString).length))) })
        XCTAssertTrue(PiMenus.perform("inspector-text-show-less", in: PiMenus.menu(menu)))
        await fixture.settle()
        XCTAssertEqual(fixture.children("item:3").last, "item:3:more", "Show Less folded it")
    }

    /// Opening keeps the view where it was; folding from the end of a long
    /// text keeps the link under the pointer; a new width keeps the line at
    /// the top of the view.
    @MainActor func testTheReadersPlaceIsKept() async throws {
        let fixture = try await InspectorExpandFixture(body: InspectorExpandBodies.request(result: Self.result))
        defer { fixture.close() }
        let outline = fixture.outline, clip = fixture.clip
        let item = try XCTUnwrap(fixture.node("item:3"))
        outline.expandItem(item); await fixture.settle()
        // The item's heading halfway down the view.
        let header = outline.row(forItem: item)
        fixture.scroll(to: max(0, outline.rect(ofRow: header).minY - 150)); await fixture.settle()
        let origin = clip.bounds.origin
        XCTAssertGreaterThan(origin.y, 0, "The view is scrolled")
        let above = fixture.frames(through: header)
        try await fixture.showAll("item:3")
        XCTAssertEqual(clip.bounds.origin, origin, "Opening kept the view's place")
        XCTAssertEqual(fixture.frames(through: header), above)

        // Deep in the text, its heading scrolled away: Show less 300 pt down the view.
        let lessRow = fixture.row("item:3:less")
        fixture.scroll(to: outline.rect(ofRow: lessRow).minY - 300); await fixture.settle()
        XCTAssertLessThan(outline.rect(ofRow: header).maxY, clip.bounds.minY, "The item's heading is above the view")
        let place = outline.rect(ofRow: lessRow).minY - clip.bounds.minY
        fixture.coordinator.activate(try XCTUnwrap(fixture.node("item:3:less")), in: outline)
        await fixture.settle()
        let moreRow = fixture.row("item:3:more")
        XCTAssertGreaterThanOrEqual(moreRow, 0)
        XCTAssertEqual(outline.rect(ofRow: moreRow).minY - clip.bounds.minY, place, accuracy: 1, "Show all is where Show less was")
        XCTAssertEqual(fixture.frames(through: header), above, "Nothing above the item moved")

        // A narrower window: the text is laid out again, off the main thread,
        // and the line at the top of the view stays at the top.
        try await fixture.showAll("item:3")
        let expansion = try XCTUnwrap(fixture.coordinator.expansion(for: .item(3)))
        let wide = try XCTUnwrap(expansion.layout)
        let textRow = fixture.row("item:3:text")
        fixture.scroll(to: outline.rect(ofRow: textRow).minY + 150 * InspectorTextStyle.lineHeight + 4); await fixture.settle()
        let top = clip.bounds.minY - outline.rect(ofRow: textRow).minY
        let anchor = wide.manager.characterIndexForGlyph(at: wide.manager.glyphIndex(for: NSPoint(x: 0, y: top), in: wide.container))
        fixture.window.setContentSize(NSSize(width: 640, height: 820))
        try await fixture.wait("the text laid out to the new width") { expansion.layout !== wide && !expansion.laying }
        await fixture.settle()
        let narrow = try XCTUnwrap(expansion.layout)
        XCTAssertLessThan(narrow.width, wide.width, "The text wraps to the narrower width")
        XCTAssertGreaterThan(narrow.height, wide.height, "and is taller for it")
        XCTAssertEqual(fixture.textView("item:3")?.laidOut === narrow, true, "The row shows the new layout")
        XCTAssertEqual(outline.rect(ofRow: fixture.row("item:3:text")).height, narrow.height + InspectorFullTextCell.bottom)
        let newTop = clip.bounds.minY - outline.rect(ofRow: fixture.row("item:3:text")).minY
        let glyph = narrow.manager.glyphIndex(for: NSPoint(x: 0, y: newTop), in: narrow.container)
        var line = NSRange()
        _ = narrow.manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
        let characters = narrow.manager.characterRange(forGlyphRange: line, actualGlyphRange: nil)
        XCTAssertTrue(NSLocationInRange(anchor, characters), "The line at the top of the view still holds character \(anchor): \(characters)")
    }

    /// Return on "Show all" opens the text and selects "Show less"; Return
    /// there folds it and selects "Show all". VoiceOver presses the links; the
    /// row's menu has Show All and Show Less.
    @MainActor func testTheKeyboardVoiceOverAndTheMenuReachShowAllAndShowLess() async throws {
        let fixture = try await InspectorExpandFixture(body: InspectorExpandBodies.request(result: Self.result))
        defer { fixture.close() }
        let outline = fixture.outline, coordinator = fixture.coordinator
        let item = try XCTUnwrap(fixture.node("item:3"))
        outline.expandItem(item); await fixture.settle()
        func returnKey() -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
                             context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        }
        outline.selectRowIndexes(IndexSet(integer: fixture.row("item:3:more")), byExtendingSelection: false)
        outline.keyDown(with: returnKey())
        try await fixture.wait("the text in place") { fixture.node("item:3:text") != nil }
        await fixture.settle()
        XCTAssertEqual(outline.selectedRow, fixture.row("item:3:less"), "Show less is selected, so Return folds the text again")
        outline.keyDown(with: returnKey())
        await fixture.settle()
        XCTAssertEqual(fixture.children("item:3").last, "item:3:more")
        XCTAssertEqual(outline.selectedRow, fixture.row("item:3:more"), "Show all is selected again")

        // VoiceOver: the link is a button it can press.
        let link = try XCTUnwrap(outline.view(atColumn: 0, row: fixture.row("item:3:more"), makeIfNecessary: true) as? InspectorRowCell)
        XCTAssertEqual(link.accessibilityRole(), .button)
        XCTAssertTrue(link.accessibilityLabel()?.hasPrefix("Show all") == true)
        XCTAssertTrue(link.accessibilityPerformPress())
        try await fixture.wait("the text in place") { fixture.textView("item:3") != nil }
        await fixture.settle()
        let view = try XCTUnwrap(fixture.textView("item:3"))
        XCTAssertEqual(view.accessibilityRole(), .textArea)
        XCTAssertEqual(view.accessibilityLabel(), "4. Result of read, whole text")
        let less = try XCTUnwrap(outline.view(atColumn: 0, row: fixture.row("item:3:less"), makeIfNecessary: true) as? InspectorRowCell)
        XCTAssertEqual(less.accessibilityRole(), .button)
        XCTAssertEqual(less.accessibilityLabel(), "Show less")
        // Return on the text gives it the keyboard.
        outline.selectRowIndexes(IndexSet(integer: fixture.row("item:3:text")), byExtendingSelection: false)
        outline.keyDown(with: returnKey())
        XCTAssertTrue(fixture.window.firstResponder === view)
        XCTAssertTrue(less.accessibilityPerformPress())
        await fixture.settle()
        XCTAssertEqual(fixture.children("item:3").last, "item:3:more")

        // The right-click menu: Show All, then Show Less.
        func titles(_ node: InspectorItemsOutline.Node) -> [String] {
            coordinator.menuEntries(for: node).compactMap { if case .item(let item) = $0 { return item.title } else { return nil } }
        }
        XCTAssertEqual(titles(item), ["Copy", "Show All"])
        XCTAssertTrue(PiMenus.perform("inspector-show-all", in: coordinator.menu(for: item)))
        try await fixture.wait("the text in place") { fixture.node("item:3:text") != nil }
        XCTAssertEqual(titles(item), ["Copy", "Show Less"])
        XCTAssertEqual(coordinator.copyText(item), Self.result, "Copy on an item shown whole copies all of it")
        XCTAssertTrue(PiMenus.perform("inspector-show-less", in: coordinator.menu(for: item)))
        await fixture.settle()
        XCTAssertEqual(fixture.children("item:3").last, "item:3:more")
    }

    /// Opening a text measures the item's own rows, not the outline's.
    @MainActor func testOpeningATextMeasuresOnlyItsOwnRows() async throws {
        let fixture = try await InspectorExpandFixture(body: InspectorExpandBodies.request(items: 260, result: Self.result))
        defer { fixture.close() }
        let outline = fixture.outline
        let item = try XCTUnwrap(fixture.node("item:3"))
        outline.expandItem(item); await fixture.settle()
        XCTAssertGreaterThan(outline.numberOfRows, 250)
        let before = fixture.coordinator.heightQueries
        try await fixture.showAll("item:3")
        let opened = fixture.coordinator.heightQueries - before
        XCTAssertLessThanOrEqual(opened, 8, "Opening the text asked for \(opened) row heights, of \(outline.numberOfRows) rows")
        let folded = fixture.coordinator.heightQueries
        fixture.coordinator.showLess(.item(3))
        await fixture.settle()
        let asked = fixture.coordinator.heightQueries - folded
        XCTAssertLessThanOrEqual(asked, RequestDocument.lineLimit + 8, "Folding it asked for \(asked) row heights, of \(outline.numberOfRows) rows")
    }

    /// A text longer than a step shows a step and says so, and each "Show
    /// more" lays out the next.
    @MainActor func testALongTextShowsAStepAtATimeAndSaysSo() async throws {
        let step = InspectorExpansion.step
        InspectorExpansion.step = 20_000
        defer { InspectorExpansion.step = step }
        let fixture = try await InspectorExpandFixture(body: InspectorExpandBodies.request(result: Self.result))
        defer { fixture.close() }
        try await fixture.showAll("item:3")
        let expansion = try XCTUnwrap(fixture.coordinator.expansion(for: .item(3)))
        let length = (Self.result as NSString).length
        XCTAssertEqual(expansion.length, length)
        XCTAssertLessThanOrEqual(expansion.shown, 20_000)
        XCTAssertGreaterThan(expansion.shown, 19_000, "A step ends on a line break near its limit")
        XCTAssertEqual(fixture.children("item:3"), ["item:3:text", "item:3:reveal", "item:3:less"])
        let reveal = try XCTUnwrap(fixture.outline.view(atColumn: 0, row: fixture.row("item:3:reveal"), makeIfNecessary: true) as? InspectorRowCell)
        XCTAssertEqual(expansion.nextStep, min(20_000, length - expansion.shown))
        XCTAssertEqual(reveal.accessibilityLabel(), "Show " + MetricFormat.tokens(Double(expansion.nextStep)) + " more characters, Showing the first " + MetricFormat.tokens(Double(expansion.shown))
                       + " of " + MetricFormat.tokens(Double(length)) + " characters", "The screen says how much is shown")
        XCTAssertTrue((fixture.textView("item:3")?.string ?? "").hasSuffix("\n") || expansion.shown == length)
        XCTAssertTrue(reveal.accessibilityPerformPress())
        try await fixture.wait("the rest laid out") { expansion.shown == length }
        await fixture.settle()
        XCTAssertEqual(fixture.children("item:3"), ["item:3:text", "item:3:less"], "All of it is shown: no more step")
        XCTAssertEqual(fixture.textView("item:3")?.string, Self.result)
    }

    /// The Turn page's prompt opens whole in its card, and folds back.
    @MainActor func testATurnsPromptOpensWholeInItsCard() async throws {
        let whole = (0..<300).map { "Line \($0) of a long prompt, pasted whole into the composer." }.joined(separator: "\n")
        let preview = RequestDocument.prefix(whole as NSString, limit: RequestDocument.previewLimit)
        let model = InspectorPromptExpansion()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScrollView { InspectorPromptCard(preview: preview, model: model, showAll: {}).padding(24) })
        window.orderFront(nil)
        defer { model.collapse(); window.contentView = nil; window.close() }
        func settle() async { for _ in 0..<6 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try? await Task.sleep(for: .milliseconds(20)) } }
        func views<T: NSView>(_ type: T.Type) -> [T] { InspectorExpandFixture.descendants(type, in: window.contentView!) }
        await settle()
        XCTAssertTrue(views(InspectorTextView.self).isEmpty, "The card shows the preview")
        var reads = 0
        model.show {
            reads += 1
            return (whole, (whole as NSString).length, (whole as NSString).length)
        }
        // Laid out to the card's width, which can narrow once the page has a
        // scroller: then laid out again, on the worker.
        func settled() -> Bool {
            guard let expansion = model.expansion, let layout = expansion.layout, !expansion.laying,
                  let view = views(InspectorTextView.self).first, view.window != nil, view.laidOut === layout,
                  let block = views(InspectorTextBlockView.self).first else { return false }
            return abs(layout.width - block.frame.width) < 1 && abs(block.frame.height - layout.height) < 1
        }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !settled() {
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let view = try XCTUnwrap(views(InspectorTextView.self).first, "The whole prompt is in the card")
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(view.string, whole)
        XCTAssertTrue(view.isSelectable)
        let block = try XCTUnwrap(views(InspectorTextBlockView.self).first)
        let layout = try XCTUnwrap(model.expansion?.layout)
        XCTAssertEqual(block.frame.height, layout.height, accuracy: 1, "The card grew to the whole text")
        XCTAssertEqual(layout.width, block.frame.width, accuracy: 1, "laid out to the card's width")
        XCTAssertGreaterThan(layout.height, 300 * 14)
        model.collapse()
        await settle()
        XCTAssertTrue(views(InspectorTextView.self).isEmpty, "Show less: the preview again")
    }
}

/// A text of megabytes opens in place without holding the main thread: it is
/// read, parsed and laid out on workers, and the main thread only swaps rows.
/// Serial: the step budget is a timing assertion.
final class InspectorExpandPerformanceTests: XCTestCase, SerialTestLane {
    #if PI_RELEASE_TESTS
    static let budget = 16.0
    #else
    static let budget = 100.0
    #endif

    @MainActor func testAMultiMegabyteItemOpensInPlaceWithoutHoldingTheMainThread() async throws {
        let result = InspectorExpandBodies.toolResult(lines: 48_000)
        let length = (result as NSString).length
        XCTAssertGreaterThan(length, 4_000_000)
        let fixture = try await InspectorExpandFixture(body: InspectorExpandBodies.request(result: result))
        defer { fixture.close() }
        let item = try XCTUnwrap(fixture.node("item:3"))
        fixture.outline.expandItem(item); await fixture.settle()
        try await Task.sleep(for: .milliseconds(300))

        let probe = MainThreadStepProbe()
        probe.start()
        let started = Date()
        fixture.coordinator.activate(try XCTUnwrap(fixture.node("item:3:more")), in: fixture.outline)
        try await fixture.wait("the first step in place", seconds: 120) { fixture.textView("item:3") != nil }
        let opened = Date().timeIntervalSince(started)
        await fixture.settle()
        probe.stop()
        let expansion = try XCTUnwrap(fixture.coordinator.expansion(for: .item(3)))
        print(String(format: "PERF inspector show all %.1fM chars: longest main-thread step %.2f ms over %d steps (next %@), %.2f s to the text",
                     Double(expansion.shown) / 1e6, probe.longest, probe.steps, probe.top.dropFirst().map { String(format: "%.1f", $0) }.joined(separator: ", "), opened))
        XCTAssertEqual(expansion.length, length)
        XCTAssertLessThan(expansion.shown, length, "A step at a time")
        XCTAssertEqual(fixture.children("item:3"), ["item:3:text", "item:3:reveal", "item:3:less"], "The screen says how much of it is shown")
        XCTAssertGreaterThan(probe.steps, 10, "The main thread kept answering while the text was read and laid out")
        XCTAssertLessThan(probe.longest, Self.budget, "No main-thread step of opening the text takes more than \(Self.budget) ms")

        // The next step, laid out the same way while the reader keeps the first.
        let shown = expansion.shown
        let next = MainThreadStepProbe()
        next.start()
        let revealed = Date()
        fixture.coordinator.activate(try XCTUnwrap(fixture.node("item:3:reveal")), in: fixture.outline)
        try await fixture.wait("the next step", seconds: 120) { expansion.shown > shown && !expansion.laying }
        let more = Date().timeIntervalSince(revealed)
        await fixture.settle()
        next.stop()
        print(String(format: "PERF inspector show more to %.1fM chars: longest main-thread step %.2f ms over %d steps, %.2f s",
                     Double(expansion.shown) / 1e6, next.longest, next.steps, more))
        XCTAssertEqual(fixture.textView("item:3")?.laidOut.characters, expansion.shown)
        XCTAssertLessThan(next.longest, Self.budget, "No main-thread step of the next step takes more than \(Self.budget) ms")

        // Folding it is as cheap: the text view lets go of its layout first.
        let fold = MainThreadStepProbe()
        fold.start()
        fixture.coordinator.showLess(.item(3))
        await fixture.settle()
        fold.stop()
        print(String(format: "PERF inspector show less: longest main-thread step %.2f ms", fold.longest))
        XCTAssertLessThan(fold.longest, Self.budget)
    }

    @MainActor func testAMultiMegabytePromptOpensInItsCardWithoutHoldingTheMainThread() async throws {
        let whole = InspectorExpandBodies.toolResult(lines: 24_000)
        let model = InspectorPromptExpansion()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScrollView {
            InspectorPromptCard(preview: RequestDocument.prefix(whole as NSString, limit: RequestDocument.previewLimit), model: model, showAll: {}).padding(24)
        })
        window.orderFront(nil)
        defer { model.collapse(); window.contentView = nil; window.close() }
        for _ in 0..<10 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let probe = MainThreadStepProbe()
        probe.start()
        model.show {
            let length = await Task.detached { (whole as NSString).length }.value
            return (whole, length, length)
        }
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, model.expansion?.layout == nil { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<10 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        probe.stop()
        let expansion = try XCTUnwrap(model.expansion)
        XCTAssertNotNil(expansion.layout, "The prompt was laid out")
        print(String(format: "PERF inspector prompt %.1fM chars: longest main-thread step %.2f ms over %d steps",
                     Double(expansion.shown) / 1e6, probe.longest, probe.steps))
        XCTAssertGreaterThan(probe.steps, 10)
        XCTAssertLessThan(probe.longest, Self.budget, "No main-thread step of opening the prompt takes more than \(Self.budget) ms")
    }
}
