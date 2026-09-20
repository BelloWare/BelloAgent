import XCTest
import SwiftUI
@testable import PiApp

/// Exercises the exact AppKit document independently of SwiftUI's outer page.
/// These checks need real native layout, but no pointer or foreground desktop.
final class NativeTranscriptDocumentTests: XCTestCase {
    @MainActor private final class Fixture {
        let session: SessionDisplay
        let page: TranscriptPage
        let scroll: TranscriptNativeScrollView
        let document: TranscriptNativeDocument
        let window: NSWindow

        init(id: String = "native-document", messages: [TranscriptMessage], width: CGFloat = 760, height: CGFloat = 440) {
            let session = SessionDisplay(id: id)
            session.messages = messages
            let page = TranscriptPage()
            // Following an active chat avoids the idle last-question placement;
            // individual tests can then detach with the normal scroll signal.
            page.state = "running"
            page.bind(session)
            let scroll = TranscriptNativeScrollView(frame: CGRect(x: 0, y: 0, width: width, height: height))
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.contentView.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.horizontalScrollElasticity = .none
            let document = TranscriptNativeDocument(page: page)
            scroll.documentView = document
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            self.session = session; self.page = page; self.scroll = scroll; self.document = document; self.window = window
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            window.makeKeyAndOrderFront(nil)
            refresh()
        }

        var bottom: CGFloat { max(0, document.frame.height - scroll.contentView.bounds.height) }
        var offset: CGFloat { scroll.contentView.bounds.minY }
        var rows: [TranscriptRowContainer] { document.retainedRows }
        var mountedRows: [TranscriptRowContainer] { document.subviews.compactMap { $0 as? TranscriptRowContainer } }

        func refresh() {
            document.update(snapshot: page.snapshot, actions: TranscriptActions(), environment: TranscriptRowEnvironment())
            document.layoutRows(width: scroll.contentSize.width)
        }

        func close() { window.contentView = nil; window.close() }

        /// Require a few consecutive settled passes: delayed row invalidations
        /// and the page's deferred anchor landing must have both run.
        func settle(until ready: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            var consecutive = 0
            while ProcessInfo.processInfo.systemUptime < deadline {
                scroll.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                consecutive = ready() ? consecutive + 1 : 0
                if consecutive >= 3 { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("The native document did not settle to the expected viewport", file: file, line: line)
            throw NSError(domain: "NativeTranscriptDocumentTests", code: 1)
        }

        func detach(at rowID: String, clipped: CGFloat = 9) throws {
            let row = try XCTUnwrap(page.rowFrame(of: rowID))
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: row.minY + clipped))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            XCTAssertFalse(page.followsBottom)
        }
    }

    private func messages(count: Int = 20) -> [TranscriptMessage] {
        (0..<count).map { index in
            TranscriptMessage(id: "m\(index)", role: "user",
                              text: "Question \(index). " + String(repeating: "Long enough to wrap naturally when the reader narrows the conversation. ", count: 8))
        }
    }

    @MainActor private func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }

    @MainActor func testLongHistoryMountsOnlyBufferedRowsWhileRetainingExactGeometry() async throws {
        let fixture = Fixture(messages: messages(count: 300))
        defer { fixture.close() }
        try await fixture.settle { fixture.rows.count == 300 && abs(fixture.offset - fixture.bottom) < 0.5 }
        let identities = Dictionary(uniqueKeysWithValues: fixture.rows.map { ($0.itemID, ObjectIdentifier($0)) })
        XCTAssertLessThan(fixture.mountedRows.count, 30, "Offscreen rows must not keep the full native text hierarchy attached")
        for id in ["m0", "m100", "m200", "m280"] {
            try fixture.detach(at: id)
            try await fixture.settle { fixture.mountedRows.contains { $0.itemID == id } }
            XCTAssertGreaterThan(fixture.mountedRows.count, 0)
            XCTAssertLessThan(fixture.mountedRows.count, 30, "The drawing/tracking hierarchy must stay bounded while traversing a long history")
            XCTAssertEqual(fixture.rows.count, 300, "Unmounting a row must preserve its native host and disclosure state")
            for row in fixture.rows {
                XCTAssertEqual(ObjectIdentifier(row), identities[row.itemID], "Scrolling must not recreate row hosts")
                let frame = try XCTUnwrap(fixture.page.rowFrame(of: row.itemID))
                XCTAssertGreaterThan(frame.height, 0, "Detached rows retain exact geometry for anchors and read visibility")
                XCTAssertEqual(frame, row.frame)
            }
        }
    }

    @MainActor func testSelectedNativeFieldStaysAttachedWhenScrolledOutsideTheBuffer() async throws {
        let fixture = Fixture(messages: messages(count: 40))
        defer { fixture.close() }
        try await fixture.settle { fixture.rows.count == 40 && abs(fixture.offset - fixture.bottom) < 0.5 }
        try fixture.detach(at: "m4", clipped: 0)
        try await fixture.settle { fixture.mountedRows.contains { $0.itemID == "m4" } }
        let selectedRow = try XCTUnwrap(fixture.rows.first { $0.itemID == "m4" })
        let field = try XCTUnwrap(textFields(in: selectedRow).first { $0.isSelectable && $0.stringValue.hasPrefix("Question 4.") })
        let renderedText = field.stringValue
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor())
        let range = NSRange(location: 3, length: 12)
        editor.selectedRange = range
        XCTAssertTrue(fixture.window.firstResponder === editor)

        try fixture.detach(at: "m30", clipped: 0)
        try await fixture.settle { fixture.mountedRows.contains { $0.itemID == "m30" } }
        let buffered = fixture.scroll.contentView.bounds.insetBy(dx: 0, dy: -max(400, fixture.scroll.contentView.bounds.height))
        XCTAssertFalse(selectedRow.frame.intersects(buffered), "The selected row must really be outside the mounting buffer")
        XCTAssertTrue(selectedRow.superview === fixture.document, "The row owning AppKit's shared field editor must remain attached")
        XCTAssertTrue(fixture.window.firstResponder === editor)
        XCTAssertTrue(field.currentEditor() === editor)
        XCTAssertEqual(editor.selectedRange, range)
        XCTAssertLessThan(fixture.mountedRows.count, 30, "Keeping a selected row alive must not retain every offscreen row")

        try fixture.detach(at: "m4", clipped: 0)
        try await fixture.settle { fixture.mountedRows.contains { $0.itemID == "m4" } }
        let returned = try XCTUnwrap(fixture.rows.first { $0.itemID == "m4" })
        let returnedField = try XCTUnwrap(textFields(in: returned).first { $0.isSelectable && $0.stringValue == renderedText })
        XCTAssertTrue(returned === selectedRow)
        XCTAssertTrue(returnedField === field)
        XCTAssertTrue(field.currentEditor() === editor)
        XCTAssertEqual(editor.selectedRange, range)
    }

    @MainActor func testPendingIntrinsicHeightChangeSettlesAfterTheReaderImmediatelyScrollsAway() async throws {
        let fixture = Fixture(messages: messages(count: 40))
        defer { fixture.close() }
        try await fixture.settle { fixture.rows.count == 40 && abs(fixture.offset - fixture.bottom) < 0.5 }
        try fixture.detach(at: "m4", clipped: 0)
        try await fixture.settle { fixture.mountedRows.contains { $0.itemID == "m4" } }
        let row = try XCTUnwrap(fixture.rows.first { $0.itemID == "m4" })
        let host = try XCTUnwrap(row.subviews.first)
        let oldHeight = row.frame.height
        let oldDestination = try XCTUnwrap(fixture.page.rowFrame(of: "m30"))
        let sequence = fixture.page.snapshot?.sequence
        var expanded = fixture.session.messages[4]
        expanded.text += String(repeating: "\n\nA local expansion must finish measuring even if its row leaves the viewport immediately.", count: 14)
        row.update(item: .message(expanded), fresh: false, actions: TranscriptActions())
        host.invalidateIntrinsicContentSize()
        // Do not yield between invalidating the host and leaving the buffer.
        // Culling must not lose the pending native-size notification.
        try fixture.detach(at: "m30", clipped: 7)
        try await fixture.settle {
            guard let current = fixture.page.rowFrame(of: "m30"), let changed = fixture.page.rowFrame(of: "m4") else { return false }
            return changed.height > oldHeight + 40 && current.minY > oldDestination.minY + 40 && abs((current.minY - fixture.offset) + 7) < 0.5
        }
        let expandedFrame = try XCTUnwrap(fixture.page.rowFrame(of: "m4"))
        let destination = try XCTUnwrap(fixture.page.rowFrame(of: "m30"))
        XCTAssertEqual(destination.minY - oldDestination.minY, expandedFrame.height - oldHeight, accuracy: 1,
                       "Every later exact frame must include the offscreen row's final height")
        XCTAssertEqual(fixture.page.snapshot?.sequence, sequence, "Local native sizing must not require another transcript snapshot")

        try fixture.detach(at: "m4", clipped: 0)
        try await fixture.settle { fixture.mountedRows.contains { $0.itemID == "m4" } && abs(fixture.offset - expandedFrame.minY) < 0.5 }
        let returned = try XCTUnwrap(fixture.rows.first { $0.itemID == "m4" })
        XCTAssertTrue(returned === row)
        XCTAssertEqual(returned.frame, expandedFrame, "Returning to the changed row must not reveal a stale cached size")
    }

    @MainActor func testHeightOnlyViewportResizeKeepsFollowingWithoutRemeasuringRows() async throws {
        let fixture = Fixture(messages: messages())
        defer { fixture.close() }
        try await fixture.settle { fixture.bottom > 800 && abs(fixture.offset - fixture.bottom) < 0.5 }
        let width = fixture.scroll.contentSize.width
        let counts = Dictionary(uniqueKeysWithValues: fixture.rows.map { ($0.itemID, $0.measurementCount) })
        let documentHeight = fixture.document.frame.height

        for height in [CGFloat(660), CGFloat(320)] {
            fixture.window.setContentSize(NSSize(width: 760, height: height))
            try await fixture.settle { abs(fixture.scroll.contentView.bounds.height - height) < 1 && abs(fixture.offset - fixture.bottom) < 0.5 }
            XCTAssertTrue(fixture.page.followsBottom)
            XCTAssertEqual(fixture.scroll.contentSize.width, width, accuracy: 0.5)
            XCTAssertEqual(fixture.document.frame.height, documentHeight, accuracy: 0.5)
            for row in fixture.rows {
                XCTAssertEqual(row.measurementCount, counts[row.itemID], "Changing only viewport height must not remeasure row \(row.itemID)")
            }
        }
    }

    @MainActor func testClipScrollingReportsTheCurrentRowAndPixelOffsetWithoutRelayout() async throws {
        let fixture = Fixture(messages: messages())
        defer { fixture.close() }
        try await fixture.settle { abs(fixture.offset - fixture.bottom) < 0.5 && fixture.page.rowFrame(of: "m8") != nil }
        var reported: TranscriptAnchor?
        fixture.page.onAnchorChanged = { reported = $0 }
        let counts = Dictionary(uniqueKeysWithValues: fixture.rows.map { ($0.itemID, $0.measurementCount) })
        try fixture.detach(at: "m8", clipped: 17)
        try await fixture.settle { reported?.id == "m8" && abs((reported?.offset ?? 0) + 17) < 0.5 }
        XCTAssertEqual(fixture.page.scrollY, fixture.offset, accuracy: 0.5)
        XCTAssertEqual(reported?.followsBottom, false)
        for row in fixture.rows {
            XCTAssertEqual(row.measurementCount, counts[row.itemID], "Scrolling alone must not change exact row layout")
        }
    }

    @MainActor func testRebindingToAnotherSessionDoesNotReuseHostsForSharedMessageIDs() async throws {
        let fixture = Fixture(id: "original", messages: messages(count: 8))
        defer { fixture.close() }
        try await fixture.settle { fixture.rows.count == 8 && abs(fixture.offset - fixture.bottom) < 0.5 }
        let original = try XCTUnwrap(fixture.rows.first { $0.itemID == "m7" })
        let second = SessionDisplay(id: "fork-with-shared-history")
        second.messages = fixture.session.messages
        fixture.page.bind(second)
        fixture.refresh()
        try await fixture.settle { fixture.page.snapshot?.sessionID == second.id && fixture.rows.count == 8 }
        let rebound = try XCTUnwrap(fixture.rows.first { $0.itemID == "m7" })
        XCTAssertFalse(original === rebound, "A distinct session owns its disclosure and native selection state even when forked history shares IDs")
        XCTAssertNil(original.superview)
        XCTAssertEqual(fixture.page.sessionID, second.id)
        // A late event from the old session cannot change the rebound document.
        fixture.session.messages = []
        XCTAssertEqual(fixture.page.snapshot?.messages.count, 8)
    }

    @MainActor func testGrowingAnEarlierRowAndNarrowingKeepTheSameReadingAnchor() async throws {
        let fixture = Fixture(messages: messages())
        defer { fixture.close() }
        try await fixture.settle { fixture.page.rowFrame(of: "m9") != nil && abs(fixture.offset - fixture.bottom) < 0.5 }
        try fixture.detach(at: "m9", clipped: 13)
        let initial = try XCTUnwrap(fixture.page.rowFrame(of: "m9"))
        fixture.session.messages[2].text += String(repeating: "\n\nEarlier paragraphs grow above the reader's current position.", count: 14)
        fixture.refresh()
        try await fixture.settle {
            guard let frame = fixture.page.rowFrame(of: "m9") else { return false }
            return frame.minY > initial.minY + 40 && abs((frame.minY - fixture.offset) + 13) < 0.5
        }
        let widenedFrame = try XCTUnwrap(fixture.page.rowFrame(of: "m9"))
        fixture.window.setContentSize(NSSize(width: 520, height: 440))
        try await fixture.settle {
            guard let frame = fixture.page.rowFrame(of: "m9") else { return false }
            return frame.width < widenedFrame.width - 100 && abs((frame.minY - fixture.offset) + 13) < 0.5
        }
        XCTAssertFalse(fixture.page.followsBottom)
        XCTAssertTrue(fixture.page.detached)
    }

    @MainActor func testExplicitPrependedHistoryAnchorTakesPriorityOverOldViewport() async throws {
        let fixture = Fixture(messages: messages())
        defer { fixture.close() }
        try await fixture.settle { fixture.page.rowFrame(of: "m8") != nil && abs(fixture.offset - fixture.bottom) < 0.5 }
        try fixture.detach(at: "m8", clipped: 12)
        // Loading/searching an earlier page supplies an explicit destination.
        // Native relayout must not replace it with the currently visible row.
        fixture.session.scrollAnchor = TranscriptAnchor(id: "m4", offset: 23, followsBottom: false)
        fixture.session.messages.insert(TranscriptMessage(id: "earlier", role: "user", text: String(repeating: "Earlier context.\n\n", count: 12)), at: 0)
        fixture.session.viewportRequest += 1
        fixture.refresh()
        try await fixture.settle {
            guard let target = fixture.page.rowFrame(of: "m4") else { return false }
            return abs((target.minY - fixture.offset) - 23) < 0.5
        }
        XCTAssertFalse(fixture.page.followsBottom)
    }

    @MainActor func testHostedIntrinsicInvalidationReflowsWithoutANewPageSnapshot() async throws {
        let fixture = Fixture(messages: messages(count: 10))
        defer { fixture.close() }
        try await fixture.settle { fixture.page.rowFrame(of: "m6") != nil && abs(fixture.offset - fixture.bottom) < 0.5 }
        try fixture.detach(at: "m6", clipped: 5)
        let row = try XCTUnwrap(fixture.rows.first { $0.itemID == "m2" })
        let host = try XCTUnwrap(row.subviews.first)
        let sequence = fixture.page.snapshot?.sequence
        let before = try XCTUnwrap(fixture.page.rowFrame(of: "m6"))
        let source = fixture.session.messages[2]
        var expanded = source
        expanded.text += String(repeating: "\n\nA local view expansion changes this row's native intrinsic size.", count: 10)
        row.update(item: .message(expanded), fresh: false, actions: TranscriptActions())
        // Enter through the same NSHostingView invalidation path as a local
        // disclosure. No document update/refresh or new session event follows.
        host.invalidateIntrinsicContentSize()
        try await fixture.settle {
            guard let frame = fixture.page.rowFrame(of: "m6") else { return false }
            return frame.minY > before.minY + 40 && abs((frame.minY - fixture.offset) + 5) < 0.5
        }
        XCTAssertEqual(fixture.page.snapshot?.sequence, sequence)
        XCTAssertEqual(fixture.session.messages[2], source, "Native intrinsic reflow must not need a new session message")
    }
}
