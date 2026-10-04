import AppKit
import XCTest
@testable import PiApp

/// The AppKit catalog picker: rows made as they scroll into view, a search
/// that starts over for another source, and inputs that change in place.
final class CatalogModelPickerTests: XCTestCase {
    @MainActor private final class Fixture {
        let gateway: ModelListGateway
        let model: WorkspaceModel
        let root: URL
        var profile = ProfileRecord(), other = ProfileRecord()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 422, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        init(count: Int) async throws {
            let list: @Sendable (String) -> String = { prefix in
                "{\"models\":[" + (0..<count).map { "{\"id\":\"\(prefix)\($0)\",\"name\":\"\(prefix.capitalized) model \($0)\",\"description\":\"Fixture model number \($0).\"}" }
                    .joined(separator: ",") + "]}"
            }
            let mainList = list("main"), otherList = list("other")
            gateway = try ModelListGateway { request in
                request.hasPrefix("GET /other ") ? .json(otherList) : .json(mainList)
            }
            let base = try await gateway.start()
            root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("catalog-picker-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
            profile.id = "main"; profile.name = "Main"; profile.modelId = "main0"; profile.baseUrl = "https://main.invalid"; profile.catalogUrl = base + "/main"
            other.id = "other"; other.name = "Other"; other.modelId = "other0"; other.baseUrl = "https://other.invalid"; other.catalogUrl = base + "/other"
            model.profiles = [profile, other]
            window.isReleasedWhenClosed = false
        }
        func show(_ picker: CatalogModelPickerView) {
            window.contentView = picker
            window.makeKeyAndOrderFront(nil)
        }
        func close() { window.contentView = nil; window.close(); model.shutdown(); gateway.stop(); try? FileManager.default.removeItem(at: root) }
    }

    @MainActor private func rows(_ view: NSView) -> [CatalogModelRow] {
        view.subviews.flatMap { ($0 as? CatalogModelRow).map { [$0] } ?? [] } + view.subviews.flatMap { rows($0) }
    }
    @MainActor private func shownRows(_ picker: NSView) -> [CatalogModelRow] { rows(picker).filter { !$0.isHidden && $0.superview != nil } }
    @MainActor private func scrollView(_ view: NSView) -> NSScrollView? {
        for child in view.subviews {
            if let scroll = child as? NSScrollView, scroll.documentView.map({ !rows($0).isEmpty }) == true { return scroll }
            if let found = scrollView(child) { return found }
        }
        return nil
    }

    /// A long catalog makes rows only for what is in view (`LazyVStack`), and
    /// scrolling to its end brings the last model's row.
    @MainActor func testALongCatalogMakesRowsOnlyAsTheyScrollIntoView() async throws {
        let fixture = try await Fixture(count: 400); defer { fixture.close() }
        let picker = CatalogModelPickerView(model: fixture.model, profile: fixture.profile, current: nil) { _ in }
        fixture.show(picker)
        try await eventually("the catalog's rows") { picker.layoutSubtreeIfNeeded(); return !self.shownRows(picker).isEmpty }
        let first = shownRows(picker)
        XCTAssertLessThan(first.count, 40, "only the rows in view and a screen either side are made, not 400")
        XCTAssertTrue(first.contains { $0.accessibilityIdentifier() == "catalog-choice-main0" })
        let scroll = try XCTUnwrap(scrollView(picker))
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.height, 400 * 60, "the document is as tall as every row")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await eventually("the last model's row after scrolling") { self.shownRows(picker).contains { $0.accessibilityIdentifier() == "catalog-choice-main399" } }
        let last = shownRows(picker)
        XCTAssertLessThan(last.count, 40)
        XCTAssertFalse(last.contains { $0.accessibilityIdentifier() == "catalog-choice-main0" }, "rows out of view are put by")
        // Rows sit one after another, in order, without overlapping.
        let ordered = last.sorted { $0.frame.minY < $1.frame.minY }
        for (above, below) in zip(ordered, ordered.dropFirst()) { XCTAssertEqual(below.frame.minY, above.frame.maxY + 2, accuracy: 0.01) }
    }

    /// A search, then another catalog source: the search starts over and
    /// the new source's whole list shows.
    @MainActor func testAnotherSourceStartsTheSearchOver() async throws {
        let fixture = try await Fixture(count: 30); defer { fixture.close() }
        let picker = CatalogModelPickerView(model: fixture.model, profile: fixture.profile, current: nil) { _ in }
        fixture.show(picker)
        try await eventually("the main catalog") { picker.layoutSubtreeIfNeeded(); return self.shownRows(picker).contains { $0.accessibilityIdentifier() == "catalog-choice-main0" } }
        XCTAssertTrue(fixture.window.makeFirstResponder(picker.search.field))
        try XCTUnwrap(picker.search.field.currentEditor() as? NSTextView).insertText("model 17", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await eventually("the search narrows the list") { picker.layoutSubtreeIfNeeded(); return self.shownRows(picker).map { $0.accessibilityIdentifier() } == ["catalog-choice-main17"] }
        fixture.model.configuration.catalogSources = [fixture.profile.id: fixture.other.id]
        _ = await fixture.model.listModels(for: fixture.other)
        try await eventually("the other source's whole list") {
            picker.layoutSubtreeIfNeeded()
            return picker.search.text.isEmpty && self.shownRows(picker).contains { $0.accessibilityIdentifier() == "catalog-choice-other0" }
                && self.shownRows(picker).count > 1
        }
    }

    /// New inputs from what hosts it move the chosen mark in place.
    @MainActor func testNewInputsMoveTheChosenMark() async throws {
        let fixture = try await Fixture(count: 5); defer { fixture.close() }
        var chosen: [String] = []
        let picker = CatalogModelPickerView(model: fixture.model, profile: fixture.profile, current: "main1") { chosen.append($0.id) }
        fixture.show(picker)
        func row(_ id: String) -> CatalogModelRow? { shownRows(picker).first { $0.accessibilityIdentifier() == "catalog-choice-\(id)" } }
        try await eventually("the rows") { picker.layoutSubtreeIfNeeded(); return row("main1") != nil }
        XCTAssertEqual(row("main1")?.isChosen, true); XCTAssertEqual(row("main3")?.isChosen, false)
        picker.update(profile: fixture.profile, current: "main3", draft: nil, allowsCatalogSelection: false, defaultTitle: nil, defaultSelected: false,
                      useDefault: nil, manualEntry: nil) { chosen.append("new:" + $0.id) }
        picker.layoutSubtreeIfNeeded()
        XCTAssertEqual(row("main1")?.isChosen, false); XCTAssertEqual(row("main3")?.isChosen, true)
        row("main2")?.performClick(nil)
        XCTAssertEqual(chosen, ["new:main2"], "a row's click reaches the newest action")
    }

    /// The open source chooser grows and shrinks with the connections it offers.
    @MainActor func testTheOpenSourceChooserFollowsItsChoices() async throws {
        let fixture = try await Fixture(count: 3); defer { fixture.close() }
        let picker = CatalogModelPickerView(model: fixture.model, profile: fixture.profile, current: nil, allowsCatalogSelection: true) { _ in }
        fixture.show(picker)
        try await eventually("the rows") { picker.layoutSubtreeIfNeeded(); return !self.shownRows(picker).isEmpty }
        picker.sourceSelector.performClick(nil)
        let popover = try XCTUnwrap(picker.sourceChooser)
        let before = popover.contentSize.height
        var third = ProfileRecord(); third.id = "third"; third.name = "Third"; third.baseUrl = "https://third.invalid"
        var fourth = ProfileRecord(); fourth.id = "fourth"; fourth.name = "Fourth"; fourth.baseUrl = "https://fourth.invalid"
        fixture.model.profiles += [third, fourth]
        try await eventually("the chooser grows") { popover.contentSize.height > before + 20 }
        let grown = popover.contentSize.height
        fixture.model.profiles = [fixture.profile, fixture.other]
        try await eventually("the chooser shrinks back") { popover.contentSize.height < grown - 20 }
        XCTAssertEqual(popover.contentSize.height, before, accuracy: 1)
        popover.close()
    }
}
