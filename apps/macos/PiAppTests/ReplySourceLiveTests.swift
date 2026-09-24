import XCTest
import SwiftUI
import AppKit
@testable import PiApp

// MARK: - A long reply read as its source, against the packaged helper

extension ConversationPaneTests {
    /// The reader has scrolled up into a long reply and switches it to its
    /// source, then back. Each switch re-measures the reply where it stands:
    /// the rows above do not move, before, during or after the motion, the
    /// reply keeps its top on the screen, and switching back leaves the page
    /// exactly where the reader was.
    @MainActor func testALongReplySwitchedToItsSourceAndBackKeepsTheReadersPlace() async throws {
        let live = try await LiveChat()
        var closed = false
        defer { if !closed { Task { await live.close() } } }
        await live.settle(20)
        await live.send("A short question first")
        await live.waitUntil("The first turn never finished") { !live.session.hasWork && live.session.messages.last?.role == "assistant" }
        await live.send("bulk 24")
        await live.waitUntil("The long reply never finished") {
            !live.session.hasWork && (live.session.messages.last { $0.role == "assistant" && $0.kind == nil }?.text.utf8.count ?? 0) > 20_000
        }
        await live.settle(12)
        let reply = try XCTUnwrap(live.session.messages.last { $0.role == "assistant" && $0.kind == nil })
        let document = try XCTUnwrap(Self.views(TranscriptNativeDocument.self, in: live.hosted).first)
        let scroll = try XCTUnwrap(document.enclosingScrollView)
        let page = try XCTUnwrap(live.transcript)
        let clip = scroll.contentView
        let row = try XCTUnwrap(document.retainedRows.first { ReplySource.replyID(of: $0.contentItem) == reply.id }, "The reply's text has a row")
        XCTAssertGreaterThan(row.frame.height, clip.bounds.height * 3, "The reply is several screens long")

        // The reader scrolls up, into the middle of the reply.
        let y = (row.frame.minY + row.frame.height * 0.4).rounded()
        page.readerWillNavigate(upward: y < clip.bounds.minY)
        clip.setBoundsOrigin(NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        await live.settle(10)
        let surface = try XCTUnwrap(Self.views(NativeMarkdownContainer.self, in: row).first, "The reply is rendered by its native surface")
        /// Waits until the reply's text is laid out at the width it is given.
        func settled() async {
            var passes = -1
            for _ in 0..<40 where passes != surface.layoutPasses {
                passes = surface.layoutPasses
                await live.settle(3)
            }
        }
        await settled()
        let offset = clip.bounds.minY, top = row.frame.minY - clip.bounds.minY
        let passes = surface.layoutPasses
        let above = document.retainedRows.prefix { $0 !== row }.map(\.frame)
        XCTAssertFalse(above.isEmpty, "The earlier turn is above the reply")
        func assertInPlace(_ when: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(document.retainedRows.prefix { $0 !== row }.map(\.frame), above, "\(when): the rows above moved", file: file, line: line)
            XCTAssertEqual(row.frame.minY - clip.bounds.minY, top, accuracy: 1, "\(when): the reply's top moved on the screen", file: file, line: line)
            XCTAssertEqual(clip.bounds.minY, offset, accuracy: 1, "\(when): the page moved under the reader", file: file, line: line)
        }

        // View raw: the same switch the pill, the menu and the row's
        // accessibility action make.
        row.toggleDisclosure(.source(reply.id))
        XCTAssertTrue(live.session.disclosure.isOpen(.source(reply.id)))
        if document.isMovingDisclosure {
            document.advanceDisclosureMotion(to: 0.5)
            assertInPlace("Halfway to the source")
        }
        document.finishDisclosureMotion()
        await live.settle(10)
        let leaves = Self.views(TranscriptPlainTextView.self, in: row)
        XCTAssertEqual(leaves.count, 1, "The source is one text")
        XCTAssertTrue(leaves.first?.string == reply.text, "The source is the reply exactly as it arrived")
        XCTAssertTrue(surface.isParked && surface.textView.isHidden && surface.frame.height == 0,
                      "Nothing of it is rendered: the rendered reply waits, parked, taking no room")
        XCTAssertLessThanOrEqual(row.hostedFittingHeight, row.frame.height + 0.5, "The reply was re-measured for its source")
        assertInPlace("In its source")

        // View rendered.
        row.toggleDisclosure(.source(reply.id))
        if document.isMovingDisclosure {
            document.advanceDisclosureMotion(to: 0.5)
            assertInPlace("Halfway back")
        }
        document.finishDisclosureMotion()
        await settled()
        XCTAssertFalse(live.session.disclosure.isOpen(.source(reply.id)))
        XCTAssertTrue(Self.views(TranscriptPlainTextView.self, in: row).isEmpty, "The rendered reply is back")
        XCTAssertTrue(Self.views(NativeMarkdownContainer.self, in: row).first === surface && !surface.isParked,
                      "The same surface, with everything it had measured")
        XCTAssertEqual(surface.layoutPasses, passes, "Nothing it had laid out is laid out again")
        assertInPlace("Rendered again")
        XCTAssertNil(live.model.error, live.model.error ?? "")
        closed = true
        await live.close()
    }
}
