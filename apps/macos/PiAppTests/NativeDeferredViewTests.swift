import XCTest
import AppKit
@testable import PiApp

final class NativeDeferredViewTests: XCTestCase {
    @MainActor private func outline(_ coordinator: JSONOutlineView.Coordinator) -> NSScrollView {
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.dataSource = coordinator; outline.delegate = coordinator
        let scroll = NSScrollView(); scroll.documentView = outline
        outline.reloadData(); outline.expandItem(coordinator.root)
        return scroll
    }

    @MainActor private func drainDeferredUpdates() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor func testOutlinePublishesOnlyTheLatestSelectionAfterTheNativeUpdate() async throws {
        var selection = "", writes: [String] = []
        let coordinator = JSONOutlineView.Coordinator(onSelection: { selection = $0; writes.append($0) })
        coordinator.documentID = UUID()
        coordinator.root = JSONOutlineNode(key: "$", value: ["first": "one", "second": "two"])
        let scroll = outline(coordinator), view = try XCTUnwrap(scroll.documentView as? NSOutlineView)
        view.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        view.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertTrue(writes.isEmpty, "Native selection must not publish during a native update")
        await drainDeferredUpdates()
        try await eventually("The final outline selection is published", timeout: .seconds(1)) { !writes.isEmpty }
        XCTAssertEqual(writes, ["two"], "Superseded selections must not briefly replace the current detail")
        XCTAssertEqual(selection, "two")
    }

    @MainActor func testReplacingTheBodyDiscardsTheOldSelectionCallback() async throws {
        var oldSelection = "", oldWrites: [String] = [], currentSelection = ""
        let coordinator = JSONOutlineView.Coordinator(onSelection: { oldSelection = $0; oldWrites.append($0) })
        coordinator.documentID = UUID()
        coordinator.root = JSONOutlineNode(key: "$", value: ["old": "old body"])
        let scroll = outline(coordinator), view = try XCTUnwrap(scroll.documentView as? NSOutlineView)
        view.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        // The view replaces the callback and immutable root before reloading.
        coordinator.selection = currentSelection
        coordinator.onSelection = { currentSelection = $0 }
        coordinator.documentID = UUID()
        coordinator.root = JSONOutlineNode(key: "$", value: ["new": "new body"])
        view.reloadData(); view.expandItem(coordinator.root)
        await drainDeferredUpdates()
        XCTAssertTrue(oldWrites.isEmpty, "A selection from the previous body must not write through its old callback")
        XCTAssertEqual(oldSelection, "", "Replacing the body leaves the old selection untouched")
        XCTAssertEqual(currentSelection, "")
    }

    @MainActor func testRemovingTheOutlineCancelsItsPendingSelection() async throws {
        var selection = "", writes: [String] = []
        let coordinator = JSONOutlineView.Coordinator(onSelection: { selection = $0; writes.append($0) })
        coordinator.root = JSONOutlineNode(key: "$", value: ["value": "previous format"])
        let scroll = outline(coordinator), view = try XCTUnwrap(scroll.documentView as? NSOutlineView)
        view.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        coordinator.stopObserving()
        view.delegate = nil; view.dataSource = nil
        await drainDeferredUpdates()
        XCTAssertTrue(writes.isEmpty, "Changing to UTF-8/Hex or leaving the inspector must not restore stale JSON detail")
        XCTAssertEqual(selection, "", "A detached outline must not publish its pending detail")
    }
}
