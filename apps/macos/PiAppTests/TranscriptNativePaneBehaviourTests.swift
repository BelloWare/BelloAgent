import AppKit
import XCTest
@testable import PiApp

/// How the AppKit conversation pane behaves: its edges' controls from the
/// keyboard and for VoiceOver, Back to bottom, the live bar coming and
/// going, and the pane drawing again only when what it shows changed.
@MainActor final class TranscriptNativePaneBehaviourTests: XCTestCase {
    private func key(_ character: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                       characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: character == " " ? 49 : 36))
    }

    func testAnEdgeLinkIsAButtonTheKeyboardPresses() throws {
        var presses = 0
        let link = TranscriptEdgeLinkButton(title: "Retry", perform: { presses += 1 })
        XCTAssertEqual(link.accessibilityRole(), .button)
        XCTAssertEqual(link.accessibilityLabel(), "Retry")
        XCTAssertTrue(link.acceptsFirstResponder)
        link.keyDown(with: try key(" ")); link.keyDown(with: try key("\r"))
        XCTAssertEqual(presses, 2, "Space and Return press it")
        XCTAssertTrue(link.accessibilityPerformPress())
        XCTAssertEqual(presses, 3)
        link.enabled = false
        XCTAssertFalse(link.accessibilityPerformPress())
        link.keyDown(with: try key(" "))
        XCTAssertEqual(presses, 3, "a link that is off presses nothing")
        XCTAssertFalse(link.acceptsFirstResponder)
    }

    func testAnEdgeLinkLightsUnderThePointerAndAQuietOneTurnsToTheAccent() {
        let link = TranscriptEdgeLinkButton(title: "Earlier work in this turn", quiet: true, symbol: "arrow.up.to.line", perform: {})
        let label = link.subviews.compactMap { $0 as? TranscriptLabel }.first!
        let face = link.subviews.compactMap { $0 as? TranscriptPanel }.first!
        XCTAssertEqual(label.color, TranscriptNSPalette.muted)
        XCTAssertNil(face.fill)
        link.setHovering(true)
        XCTAssertEqual(label.color, TranscriptNSPalette.accent)
        XCTAssertEqual(face.fill, TranscriptNSPalette.accentSoft)
    }

    func testTheEdgesSayWhatTheyShow() throws {
        let pane = NativeTranscriptPane()
        var loaded = 0, inspected: [String] = []
        pane.onLoadEarlier = { _ in loaded += 1 }
        pane.update(session: SessionDisplay(id: "edges"), state: "idle", actions: TranscriptActions(inspect: { inspected.append($0) }),
                    environment: TranscriptRowEnvironment(), reduceMotion: true)
        // A read that failed: one element saying so, with Retry and the way to the turn's question.
        let failed = try XCTUnwrap(pane.earlierControl(.failed("Connection reset"), partialTurnInput: "u1"))
        let problem = try XCTUnwrap(failed.view as? TranscriptEdgeProblemView)
        XCTAssertEqual(problem.accessibilityLabel(), "Couldn’t load earlier messages. Connection reset")
        XCTAssertEqual(problem.accessibilityRole(), .group)
        XCTAssertEqual(failed.marker.edge, "earlier"); XCTAssertEqual(failed.marker.kind, "failed"); XCTAssertEqual(failed.marker.text, "Connection reset")
        XCTAssertTrue(problem.action.accessibilityPerformPress())
        XCTAssertTrue(try XCTUnwrap(problem.partial).accessibilityPerformPress())
        XCTAssertEqual(loaded, 1); XCTAssertEqual(inspected, ["u1"])
        XCTAssertTrue(problem.detail.isSelectable, "the error can be selected and copied")
        // Rows the page will not read on its own.
        let waiting = try XCTUnwrap(pane.earlierControl(.waiting, partialTurnInput: nil))
        let load = try XCTUnwrap((waiting.view as? TranscriptEdgeWaitingView)?.load)
        XCTAssertEqual(load.accessibilityIdentifier(), "loadEarlierHistory")
        XCTAssertTrue(load.accessibilityPerformPress()); XCTAssertEqual(loaded, 2)
        // A slow read: the spinner says what it waits for.
        let loading = try XCTUnwrap(pane.earlierControl(.loading, partialTurnInput: nil))
        XCTAssertEqual(loading.view.accessibilityLabel(), "Loading earlier messages")
        XCTAssertNil(pane.earlierControl(.quiet, partialTurnInput: nil))
        // The way to the turn's question.
        let chip = pane.partialChip("u2")
        XCTAssertEqual(chip.view.toolTip, "Show the question this turn began with")
        XCTAssertEqual(chip.marker.kind, "partial")
        chip.marker.action?()
        XCTAssertEqual(inspected, ["u1", "u2"])
    }

    /// A pane that takes no input presses nothing at its edges or Back to bottom.
    func testAPaneThatTakesNoInputPressesNothingAtItsEdges() throws {
        let session = SessionDisplay(id: "off")
        session.olderPage = ConversationPageBoundary(cursor: ConversationCursor(incarnation: "r", lineage: "root", entry: "m1"), loading: false, error: "Connection reset")
        let pane = NativeTranscriptPane(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        var loads = 0
        pane.onLoadEarlier = { _ in loads += 1 }
        var off = TranscriptRowEnvironment(); off.isEnabled = false
        pane.update(session: session, state: "idle", actions: TranscriptActions(), environment: off, reduceMotion: true)
        let problem = try XCTUnwrap(pane.earlierSlot.shown?.view as? TranscriptEdgeProblemView)
        XCTAssertFalse(problem.action.accessibilityPerformPress())
        XCTAssertEqual(loads, 0)
        pane.latestBox.setShown(true, animated: false)
        XCTAssertEqual(pane.latestBox.pill?.isEnabled, false)
        pane.update(session: session, state: "idle", actions: TranscriptActions(), environment: TranscriptRowEnvironment(), reduceMotion: true)
        XCTAssertTrue(problem.action.accessibilityPerformPress())
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(pane.latestBox.pill?.isEnabled, true)
    }

    /// The edges act on the chat on screen now, whichever chat they were made for.
    func testEdgesActOnTheChatOnScreen() throws {
        let error = "Connection reset", cursor = ConversationCursor(incarnation: "r", lineage: "root", entry: "m1")
        let first = SessionDisplay(id: "first"), second = SessionDisplay(id: "second")
        for session in [first, second] { session.newerPage = ConversationPageBoundary(cursor: cursor, loading: false, error: error) }
        let pane = NativeTranscriptPane(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        var asked: [String] = []
        pane.onLoadNewer = { asked.append($0) }
        pane.update(session: first, state: "idle", actions: TranscriptActions(), environment: TranscriptRowEnvironment(), reduceMotion: true)
        let before = try XCTUnwrap(pane.aboveSlot.shown?.view)
        pane.update(session: second, state: "idle", actions: TranscriptActions(), environment: TranscriptRowEnvironment(), reduceMotion: true)
        let after = try XCTUnwrap(pane.aboveSlot.shown?.view as? TranscriptEdgeProblemView)
        XCTAssertFalse(before === after, "another chat's edge is made again")
        XCTAssertTrue(after.action.accessibilityPerformPress())
        XCTAssertEqual(asked, ["second"])
    }

    /// Back to bottom that sprang away comes back whole in one step.
    func testBackToBottomComesBackWholeAfterSpringingAway() throws {
        let box = TranscriptLatestBox(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
        box.setShown(true, animated: false)
        box.setShown(false, animated: true)
        box.setShown(true, animated: false)
        XCTAssertFalse(box.isHidden)
        XCTAssertNil(box.layer?.animation(forKey: "latestFade"), "nothing of its exit stays on it")
        XCTAssertEqual(box.layer?.opacity, 1)
    }

    /// Right to left, the turn's question stands at the leading (left) edge
    /// and the newer read's spinner after Back to bottom.
    func testRightToLeftTheEdgesMirror() throws {
        let session = SessionDisplay(id: "rtl")
        session.messages = TranscriptStreamingStressTests.history(turns: 2)
        session.newerPage = ConversationPageBoundary(cursor: ConversationCursor(incarnation: "r", lineage: "root", entry: "m1"), loading: true, error: nil)
        let pane = NativeTranscriptPane(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        var rtl = TranscriptRowEnvironment(); rtl.layoutDirection = .rightToLeft
        pane.update(session: session, state: "idle", actions: TranscriptActions(), environment: rtl, reduceMotion: true)
        pane.partialSlot.show(pane.partialChip("u1"), animated: false)
        pane.besideSlot.show(pane.newerControl(.loading), animated: false)
        pane.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.partialSlot.frame.minX, 18, accuracy: 0.5, "the question's way at the leading edge")
        XCTAssertEqual(pane.besideSlot.frame.minX, PiKit.BackToBottomPill.diameter + 8, accuracy: 0.5, "the spinner after the circle")
        XCTAssertTrue((pane.partialSlot.shown?.view as? TranscriptEdgeSurfaceView)?.rightToLeft == true)
    }

    /// A run that settles lets its live bar go, and the actions it held.
    func testTheLiveBarIsLetGoWhenItsRunSettles() async throws {
        let session = SessionDisplay(id: "release")
        session.messages = TranscriptStreamingStressTests.history(turns: 2)
        let pane = NativeTranscriptPane(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(contentRect: pane.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = pane
        defer { window.contentView = nil }
        weak var report: TranscriptNativeTurnReport?
        session.state = "running"
        pane.update(session: session, state: "running", actions: TranscriptActions(), environment: TranscriptRowEnvironment(), reduceMotion: true)
        try await eventually("the live bar", timeout: .seconds(5)) {
            pane.layoutSubtreeIfNeeded()
            report = pane.subviews.compactMap { $0 as? TranscriptNativeTurnReport }.first
            return report != nil
        }
        session.state = "idle"
        pane.update(session: session, state: "idle", actions: TranscriptActions(), environment: TranscriptRowEnvironment(), reduceMotion: true)
        try await eventually("the live bar let go", timeout: .seconds(5)) { pane.layoutSubtreeIfNeeded(); return report == nil }
    }

    /// Another chat takes the pane while an edge fades out: nothing of the
    /// chat it left stays, fading or not.
    func testAnotherChatLeavesNoFadingEdgeBehind() throws {
        let cursor = ConversationCursor(incarnation: "r", lineage: "root", entry: "m1")
        let first = SessionDisplay(id: "first"), second = SessionDisplay(id: "second")
        first.olderPage = ConversationPageBoundary(cursor: cursor, loading: false, error: "Connection reset")
        let pane = NativeTranscriptPane(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        pane.update(session: first, state: "idle", actions: TranscriptActions(), environment: TranscriptRowEnvironment(), reduceMotion: false)
        XCTAssertNotNil(pane.earlierSlot.shown)
        first.olderPage = ConversationPageBoundary()
        pane.update(session: first, state: "idle", actions: TranscriptActions(), environment: TranscriptRowEnvironment(), reduceMotion: false)
        XCTAssertFalse(pane.earlierSlot.isEmpty, "the error fades out")
        pane.update(session: second, state: "idle", actions: TranscriptActions(), environment: TranscriptRowEnvironment(), reduceMotion: false)
        XCTAssertTrue(pane.earlierSlot.isEmpty, "gone at once with the chat it belonged to")
        XCTAssertTrue(pane.earlierSlot.subviews.isEmpty)
    }

    /// The turn's question is offered what its trailing inset leaves, so in
    /// a pane as narrow as it is it wraps rather than leaving the pane.
    func testThePartialChipStaysInsideANarrowPane() throws {
        let session = SessionDisplay(id: "narrow")
        let chip = TranscriptPartialTurnChipView(inspect: {})
        let natural = chip.size(offered: .greatestFiniteMagnitude).width
        let pane = NativeTranscriptPane(frame: CGRect(x: 0, y: 0, width: natural, height: 300))
        pane.update(session: session, state: "idle", actions: TranscriptActions(), environment: TranscriptRowEnvironment(), reduceMotion: true)
        pane.partialSlot.show(pane.partialChip("u1"), animated: false)
        pane.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(pane.partialSlot.frame.maxX, natural - 18 + 0.5, "it keeps its inset from the trailing edge")
        XCTAssertGreaterThanOrEqual(pane.partialSlot.frame.minX, -0.5)
    }

    /// A link whose words wrap takes the click on them, as on the rest of it.
    func testAWrappedLinkTakesTheClickOnItsWords() throws {
        let link = TranscriptEdgeLinkButton(title: "Earlier work in this turn", quiet: true, perform: {})
        let size = link.size(offered: 80)
        XCTAssertGreaterThan(size.height, link.size.height, "it wraps")
        let holder = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        holder.addSubview(link)
        link.frame = CGRect(origin: .zero, size: size)
        link.layoutSubtreeIfNeeded()
        let words = try XCTUnwrap(link.subviews.first { $0 is TranscriptPlainTextView && !$0.isHidden })
        let point = link.convert(CGPoint(x: words.frame.midX, y: words.frame.midY), to: holder)
        XCTAssertTrue(holder.hitTest(point) === link)
    }

    func testAnEdgeComingAndGoingFadesAndTheSameKindUpdatesInPlace() throws {
        let slot = TranscriptEdgeSlot()
        let pane = NativeTranscriptPane()
        slot.show(pane.earlierControl(.failed("a"), partialTurnInput: nil), animated: false)
        let first = try XCTUnwrap(slot.shown?.view)
        XCTAssertEqual(first.alphaValue, 1)
        slot.show(pane.earlierControl(.loading, partialTurnInput: nil), animated: true)
        XCTAssertTrue(first.superview === slot, "the old control stays while it fades out")
        XCTAssertEqual(slot.shown?.view.alphaValue ?? 1, 0, accuracy: 1, "the new one fades in")
        slot.show(nil, animated: false)
        XCTAssertTrue(slot.subviews.allSatisfy { $0 === first || !($0 is TranscriptEdgeSpinnerView) }, "gone at once without motion")
    }

    func testBackToBottomComesAwayFromTheEndAndTakesTheReaderBack() throws {
        let box = TranscriptLatestBox()
        var pressed = 0
        box.action = { pressed += 1 }
        XCTAssertTrue(box.isHidden)
        box.setShown(true, animated: false)
        XCTAssertFalse(box.isHidden)
        let pill = try XCTUnwrap(box.pill)
        XCTAssertEqual(pill.accessibilityIdentifier(), "backToBottom")
        XCTAssertEqual(box.marker.kind, "latest"); XCTAssertEqual(box.marker.text, "Jump to the latest message")
        pill.performClick(nil)
        box.marker.action?()
        XCTAssertEqual(pressed, 2)
        box.setShown(false, animated: false)
        XCTAssertTrue(box.isHidden)
    }

    /// The live bar opens its slot when a run starts and closes it when the
    /// run settles; it is drawn again only for its own turn or run state.
    func testTheLiveBarComesWithARunAndIsDrawnOnlyForItsOwnTurn() async throws {
        let session = SessionDisplay(id: "live")
        session.messages = TranscriptStreamingStressTests.history(turns: 2)
        let pane = NativeTranscriptPane(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        let window = NSWindow(contentRect: pane.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = pane
        defer { window.contentView = nil }
        pane.update(session: session, state: "idle", actions: TranscriptActions(), environment: TranscriptRowEnvironment(), reduceMotion: true)
        pane.layoutSubtreeIfNeeded()
        func bar() -> TranscriptNativeTurnReport? { pane.subviews.compactMap { $0 as? TranscriptNativeTurnReport }.first }
        XCTAssertNil(bar())
        XCTAssertEqual(pane.scrollView.frame.height, 500)
        session.state = "running"
        pane.update(session: session, state: "running", actions: TranscriptActions(), environment: TranscriptRowEnvironment(), reduceMotion: true)
        try await eventually("the live bar", timeout: .seconds(5)) { pane.layoutSubtreeIfNeeded(); return bar() != nil }
        let shown = try XCTUnwrap(bar())
        XCTAssertLessThan(pane.scrollView.frame.height, 500, "the bar's slot takes room at the foot")
        XCTAssertEqual(shown.frame.minX, 16); XCTAssertEqual(shown.frame.maxY, 500 - 8, accuracy: 0.5)
        RedrawCounter.reset(); RedrawCounter.recording = true
        defer { RedrawCounter.recording = false; RedrawCounter.reset() }
        session.objectWillChange.send()
        try await eventually("a pass", timeout: .seconds(2)) { pane.layoutSubtreeIfNeeded(); return RedrawCounter.counts["transcript", default: 0] > 0 }
        XCTAssertEqual(RedrawCounter.counts["liveTurnBar", default: 0], 0, "the bar is not drawn again for a change that is not its own")
        session.state = "idle"
        pane.update(session: session, state: "idle", actions: TranscriptActions(), environment: TranscriptRowEnvironment(), reduceMotion: true)
        try await eventually("the bar gone", timeout: .seconds(5)) { pane.layoutSubtreeIfNeeded(); return bar() == nil }
        XCTAssertEqual(pane.scrollView.frame.height, 500, "its slot closes")
    }
}
