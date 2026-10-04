import XCTest
import AppKit
@testable import PiApp

/// What the native rows do that a still capture cannot show: what the pointer
/// brings up, and what a resize does to text set in SwiftUI's line box.
final class TranscriptNativeRowBehaviourTests: XCTestCase {
    @MainActor private func mounted(_ item: TranscriptItem, width: CGFloat = 600, actions: TranscriptActions = TranscriptActions()) -> (TranscriptRowContainer, NSWindow) {
        let row = TranscriptRowContainer(item: item, fresh: false, actions: actions)
        let height = row.measure(width: width).height
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = TranscriptNativeRowParityTests.ParityCanvas(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.contentView?.addSubview(row)
        row.frame = CGRect(x: 0, y: 0, width: width, height: height)
        row.layoutForViewport()
        window.contentView?.layoutSubtreeIfNeeded()
        return (row, window)
    }

    /// The pointer arriving over a laid-out row brings its pills up at their
    /// size, ready to click — not as zero-sized views nobody laid out.
    @MainActor func testPillsUnderThePointerAreLaidOut() throws {
        let (row, window) = mounted(.message(TranscriptMessage(id: "u1", role: "user", text: "Hello", at: 1_000)))
        defer { window.contentView = nil }
        let content = try XCTUnwrap(row.subviews.first as? TranscriptNativeUserRow)
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                         trackingNumber: 0, userData: nil))
        content.mouseEntered(with: event)
        let pills = content.subviews.compactMap { $0 as? TranscriptPillButton }
        XCTAssertEqual(pills.map(\.title), ["Edit", "Copy", "Details"])
        for pill in pills { XCTAssertGreaterThan(pill.frame.width, 20, "\(pill.title) was laid out"); XCTAssertGreaterThan(pill.frame.height, 15) }
    }

    /// A row on screen follows a change of writing direction: its bubble moves
    /// to the other side without anything else changing.
    @MainActor func testAMountedRowMirrorsWhenTheDirectionChanges() throws {
        let item = TranscriptItem.message(TranscriptMessage(id: "u1", role: "user", text: "Hello", at: 1_000))
        let (row, window) = mounted(item)
        defer { window.contentView = nil }
        let content = try XCTUnwrap(row.subviews.first as? TranscriptNativeUserRow)
        let bubble = { content.subviews.compactMap { $0 as? TranscriptPanel }.first?.frame ?? .zero }
        let before = bubble()
        var environment = TranscriptRowEnvironment(); environment.layoutDirection = .rightToLeft
        row.update(item: item, fresh: false, actions: TranscriptActions(), environment: environment)
        row.layoutSubtreeIfNeeded(); content.layoutSubtreeIfNeeded()
        XCTAssertEqual(bubble().minX, row.bounds.width - before.maxX, accuracy: 0.5, "the bubble stands at the other edge")
    }

    /// VoiceOver's press on a pill does what a click does, and nothing while
    /// the row takes no input.
    @MainActor func testAPillPressedByVoiceOverActs() {
        var pressed = 0
        let pill = TranscriptPillButton(title: "Retry request", accent: true, perform: { pressed += 1 })
        XCTAssertTrue(pill.accessibilityPerformPress())
        pill.enabled = false
        XCTAssertFalse(pill.accessibilityPerformPress())
        XCTAssertEqual(pressed, 1)
    }

    /// Glyphs sit for the width the text is drawn at: a text whose height
    /// changes with its width is set again for each, and set as before once
    /// it is back at a width measured before.
    @MainActor func testGlyphsFollowTheWidthTheTextIsDrawnAt() throws {
        let text = TranscriptPlainTextView()
        text.update(text: "A short question that wraps only when narrow", face: .user, environment: TranscriptRowEnvironment(), swiftUILines: true)
        func offset(drawnAt width: CGFloat) -> CGFloat? {
            _ = text.measure(width: width)
            text.frame = CGRect(x: 0, y: 0, width: width, height: 200)
            text.layoutSubtreeIfNeeded(); text.layout()
            return text.textStorage?.attribute(.baselineOffset, at: 0, effectiveRange: nil) as? CGFloat
        }
        let wide = offset(drawnAt: 600)
        let narrow = offset(drawnAt: 120)
        XCTAssertEqual(wide, TranscriptPlainTextView.glyphOffset(TranscriptPlainTextFace.user.nsFont, height: text.exactHeight(width: 600), scale: 2))
        XCTAssertEqual(narrow, TranscriptPlainTextView.glyphOffset(TranscriptPlainTextFace.user.nsFont, height: text.exactHeight(width: 120), scale: 2))
        XCTAssertNotEqual(wide, narrow, "one line and three wrapped lines sit differently")
        XCTAssertEqual(offset(drawnAt: 600), wide, "back at a width measured before, the glyphs sit as they did there")
    }

    /// A run that failed offers its retry, natively, as a button VoiceOver
    /// can press; a refused send offers none.
    @MainActor func testARunFailureOffersItsRetry() throws {
        var retried = 0
        var actions = TranscriptActions(); actions.retry = { retried += 1 }
        func failure(_ id: String) -> TranscriptItem {
            var message = TranscriptMessage(id: id, role: "system", text: "The gateway closed the connection.")
            message.kind = "failure"
            return .message(message)
        }
        let (row, window) = mounted(failure("failure:run:1"), actions: actions)
        defer { window.contentView = nil }
        let content = try XCTUnwrap(row.subviews.first as? TranscriptNativeFailureRow, "a failure card draws natively")
        let pills = content.subviews.compactMap { $0 as? TranscriptPillButton }
        XCTAssertEqual(pills.map(\.title), ["Retry request"])
        let retry = try XCTUnwrap(pills.first)
        XCTAssertEqual(retry.accessibilityIdentifier(), "retry-run")
        XCTAssertEqual(retry.accessibilityRole(), .button)
        XCTAssertGreaterThan(retry.frame.width, 60, "the pill was laid out")
        XCTAssertTrue(retry.accessibilityPerformPress())
        XCTAssertEqual(retried, 1)
        XCTAssertEqual(content.accessibilityLabel(), "Error: The gateway closed the connection.")

        let (sent, sentWindow) = mounted(failure("failure:send:2"), actions: actions)
        defer { sentWindow.contentView = nil }
        let refused = try XCTUnwrap(sent.subviews.first as? TranscriptNativeFailureRow)
        XCTAssertTrue(refused.subviews.compactMap { $0 as? TranscriptPillButton }.isEmpty, "a refused send is retyped, not retried")
    }

    /// A reply whose stream is interrupted keeps the surface it was drawn
    /// on — and the reader's selection in it — while it gains its ending.
    @MainActor func testAnInterruptedReplyKeepsItsSurface() throws {
        func body(_ state: String?) throws -> TranscriptItem {
            var question = TranscriptMessage(id: "q", role: "user", text: "Question"); question.at = 1_000
            var reply = TranscriptMessage(id: "r", role: "assistant", text: "Words that were arriving"); reply.turn = "q"; reply.state = state
            return try XCTUnwrap(TaskTranscriptPlan.items([question, reply], lifecycle: nil, display: .normal)
                .first { TranscriptNativeReplyRow.reply(of: $0) != nil })
        }
        let (row, window) = mounted(try body("streaming"))
        defer { window.contentView = nil }
        let before = try XCTUnwrap(row.subviews.first as? TranscriptNativeReplyRow)
        _ = row.update(item: try body("aborted"), fresh: false, actions: TranscriptActions())
        XCTAssertTrue(row.subviews.first === before, "the stopped reply is drawn by the same content")
        row.layoutSubtreeIfNeeded()
        let words = before.subviews.compactMap { $0 as? TranscriptLabel }.map(\.text)
        XCTAssertEqual(words, ["aborted"], "the ending is said over the words")
    }

    /// A row in a pane that takes no input acts on nothing through VoiceOver
    /// either, as its pills do.
    @MainActor func testRowActionsRefuseWhileDisabled() throws {
        var copied = 0
        var actions = TranscriptActions(); actions.copyMessage = { _ in copied += 1 }
        var environment = TranscriptRowEnvironment(); environment.isEnabled = false
        let item = TranscriptItem.message(TranscriptMessage(id: "u1", role: "user", text: "Hello", at: 1_000))
        let row = TranscriptRowContainer(item: item, fresh: false, actions: actions, environment: environment)
        _ = row.measure(width: 600)
        let content = try XCTUnwrap(row.subviews.first as? TranscriptNativeUserRow)
        let copy = try XCTUnwrap(content.accessibilityCustomActions()?.first { $0.name == "Copy" })
        XCTAssertFalse(copy.handler?() ?? true)
        XCTAssertEqual(copied, 0)
        environment.isEnabled = true
        _ = row.update(item: item, fresh: false, actions: actions, environment: environment)
        XCTAssertTrue(try XCTUnwrap(content.accessibilityCustomActions()?.first { $0.name == "Copy" }).handler?() ?? false)
        XCTAssertEqual(copied, 1)
    }

    /// Copy reads right to left in a right-to-left row: its word before its icon.
    @MainActor func testCopyMirrorsRightToLeft() {
        let button = TranscriptCopyButton(frame: CGRect(origin: .zero, size: TranscriptCopyButton.size))
        button.layoutSubtreeIfNeeded()
        func order() -> Bool {
            let icon = button.subviews.first { $0 is TranscriptSymbol }!, label = button.subviews.first { $0 is TranscriptLabel }!
            return icon.frame.minX < label.frame.minX
        }
        XCTAssertTrue(order(), "left to right: the icon leads")
        button.rightToLeft = true
        button.layoutSubtreeIfNeeded()
        XCTAssertFalse(order(), "right to left: the word leads")
    }

    /// Retry is a button the keyboard reaches and presses with Space or
    /// Return; a hover pill takes no focus.
    @MainActor func testRetryTakesTheKeyboard() throws {
        var pressed = 0
        let retry = TranscriptPillButton(title: "Retry request", accent: true, symbol: "arrow.clockwise", perform: { pressed += 1 })
        retry.focusable = true
        XCTAssertTrue(retry.acceptsFirstResponder)
        for key in [" ", "\r"] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                       context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
            retry.keyDown(with: event)
        }
        XCTAssertEqual(pressed, 2)
        retry.enabled = false
        XCTAssertFalse(retry.acceptsFirstResponder, "a pane that takes no input gives its pills no focus")
        let hover = TranscriptPillButton(title: "Copy", accent: false, perform: {})
        XCTAssertFalse(hover.acceptsFirstResponder)
    }

    /// A pill reads right to left in a right-to-left row: its title before its symbol.
    @MainActor func testPillMirrorsRightToLeft() {
        let pill = TranscriptPillButton(title: "Retry request", accent: true, symbol: "arrow.clockwise", perform: {})
        pill.frame = CGRect(origin: .zero, size: pill.pillSize)
        pill.layoutSubtreeIfNeeded()
        func symbolLeads() -> Bool {
            let symbol = pill.subviews.first { $0 is TranscriptSymbol }!, title = pill.subviews.first { $0 is TranscriptLabel }!
            return symbol.frame.minX < title.frame.minX
        }
        XCTAssertTrue(symbolLeads())
        pill.rightToLeft = true
        pill.layoutSubtreeIfNeeded()
        XCTAssertFalse(symbolLeads())
    }

    /// A card, notice or status row its turn's fold has emptied draws
    /// nothing, takes no room and says nothing, as the SwiftUI row did.
    @MainActor func testFoldedAwayMessageRowsDrawNothing() throws {
        var failure = TranscriptMessage(id: "failure:run:1", role: "system", text: "The gateway closed the connection.")
        failure.kind = "failure"
        var notice = TranscriptMessage(id: "n1", role: "system", text: "Retrying")
        notice.kind = "notice"
        let status = TranscriptMessage(id: "s1", role: "system", text: "Model changed")
        for message in [failure, notice, status] {
            var disclosure = TranscriptRowDisclosure.default
            disclosure.foldedAway = true
            let inputs = TranscriptRowInputs(item: .message(message), fresh: false, actions: TranscriptActions(), width: 600,
                                             environment: TranscriptRowEnvironment(), disclosure: disclosure)
            let content = TranscriptRowRenderer.content(for: .message(message), inputs: inputs)
            XCTAssertTrue(content is TranscriptNativeMessageRow, "\(message.id) draws natively")
            content.frame = CGRect(x: 0, y: 0, width: 600, height: 1)
            XCTAssertEqual(content.confirmHeight(), 1, "\(message.id) takes no room")
            XCTAssertFalse(content.isAccessibilityElement(), "\(message.id) says nothing")
            XCTAssertTrue(content.subviews.allSatisfy(\.isHidden), "\(message.id) draws nothing")
        }
    }

    /// VoiceOver hears a control as enabled while it acts, and disabled while
    /// the pane takes no input.
    @MainActor func testControlsReportWhetherTheyAct() {
        let pill = TranscriptPillButton(title: "Retry request", accent: true, perform: {})
        let link = TranscriptLinkButton()
        XCTAssertTrue(pill.isAccessibilityEnabled()); XCTAssertTrue(link.isAccessibilityEnabled())
        pill.enabled = false; link.enabled = false
        XCTAssertFalse(pill.isAccessibilityEnabled()); XCTAssertFalse(link.isAccessibilityEnabled())
    }

    /// A status message that failed says how it ended to VoiceOver.
    @MainActor func testAFailedStatusSaysHowItEnded() throws {
        var message = TranscriptMessage(id: "s1", role: "system", text: "The request stopped")
        message.state = "error"
        let (row, window) = mounted(.message(message))
        defer { window.contentView = nil }
        let content = try XCTUnwrap(row.subviews.first as? TranscriptNativeStatusRow)
        let spoken = content.subviews.filter { $0.isAccessibilityElement() }.compactMap { $0.accessibilityLabel() }
        XCTAssertTrue(spoken.contains("error"), "spoken: \(spoken)")
    }

    /// The notice's ring turns clockwise, as SwiftUI's did.
    @MainActor func testTheNoticeRingTurnsClockwise() throws {
        var notice = TranscriptMessage(id: "n1", role: "system", text: "Retrying")
        notice.kind = "notice"
        let (row, window) = mounted(.message(notice))
        defer { window.contentView = nil }
        let spinner = try XCTUnwrap(row.subviews.first?.subviews.compactMap { $0 as? TranscriptSpinner }.first)
        spinner.layoutSubtreeIfNeeded(); spinner.displayIfNeeded()
        let spin = try XCTUnwrap(spinner.layer?.sublayers?.compactMap { $0.animation(forKey: "turn") as? CABasicAnimation }.first)
        XCTAssertGreaterThan((spin.toValue as? Double) ?? 0, 0, "a rising angle turns clockwise in the flipped layer")
    }
}
