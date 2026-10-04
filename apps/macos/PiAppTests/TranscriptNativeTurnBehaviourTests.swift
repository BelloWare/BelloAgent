import XCTest
import AppKit
@testable import PiApp

/// The native turn report behaves as the SwiftUI one did: Copy Turn Info from
/// its button, its menu and assistive technology, all refused in a pane that
/// takes no input; Info opens the turn; the clock ticks only while the turn
/// runs and on screen; the dock keeps one height while its words change; and
/// a finished turn's row is drawn natively.
final class TranscriptNativeTurnBehaviourTests: XCTestCase {
    typealias Fixtures = TranscriptNativeTurnParityTests

    @MainActor private func mounted(_ report: NSView, width: CGFloat = 600) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = report
        report.frame = CGRect(x: 0, y: 0, width: width, height: 300)
        report.layoutSubtreeIfNeeded()
        return window
    }
    @MainActor private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }
    private func environment(enabled: Bool = true) -> TranscriptRowEnvironment {
        var environment = TranscriptRowEnvironment(); environment.isEnabled = enabled
        return environment
    }

    @MainActor func testCopyTurnInfoFromTheButtonTheMenuAndAssistiveTechnology() throws {
        let turn = Fixtures.turn(), report = TranscriptNativeTurnReport()
        report.update(turn: turn, actions: TranscriptActions(), model: "fallback-model", environment: environment())
        let window = mounted(report); defer { window.contentView = nil }
        let expected = TurnLineView.copyText(TurnInfoPresentation.live(turn, at: .now), model: "fallback-model")
        let copy = try XCTUnwrap(views(TranscriptIconButton.self, in: report).first)
        XCTAssertEqual(copy.accessibilityLabel(), "Copy Turn Info")
        XCTAssertEqual(copy.accessibilityRole(), .button)
        NSPasteboard.general.clearContents()
        XCTAssertTrue(copy.accessibilityPerformPress())
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), expected)

        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(report.menu(for: event))
        XCTAssertEqual(menu.items.map(\.title), ["Copy Turn Info"])
        NSPasteboard.general.clearContents()
        let item = try XCTUnwrap(menu.items.first)
        XCTAssertTrue(item.isEnabled)
        _ = (item.target as AnyObject).perform(item.action, with: item)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), expected)

        let action = try XCTUnwrap(report.accessibilityCustomActions()?.first { $0.name == "Copy Turn Info" })
        NSPasteboard.general.clearContents()
        XCTAssertTrue(action.handler?() ?? false)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), expected)

        // A pane that takes no input refuses every one of them.
        report.update(turn: turn, actions: TranscriptActions(), model: "fallback-model", environment: environment(enabled: false))
        NSPasteboard.general.clearContents()
        XCTAssertFalse(copy.accessibilityPerformPress())
        XCTAssertFalse(copy.isAccessibilityEnabled())
        XCTAssertFalse(try XCTUnwrap(report.menu(for: event)?.items.first).isEnabled)
        XCTAssertFalse(try XCTUnwrap(report.accessibilityCustomActions()?.first).handler?() ?? true)
        XCTAssertNil(NSPasteboard.general.string(forType: .string))
    }

    @MainActor func testInfoOpensTheTurnAndIsRefusedWhenThePaneTakesNoInput() throws {
        let turn = Fixtures.turn(), report = TranscriptNativeTurnReport()
        var opened: [TurnSummary] = []
        var actions = TranscriptActions(); actions.inspectTurn = { opened.append($0) }
        report.update(turn: turn, actions: actions, environment: environment())
        let window = mounted(report); defer { window.contentView = nil }
        let info = try XCTUnwrap(views(NSButton.self, in: report).first { $0.accessibilityIdentifier() == "turn-info-button" })
        XCTAssertEqual(info.frame.size, CGSize(width: 20, height: 20))
        info.performClick(nil)
        XCTAssertEqual(opened, [turn])
        report.update(turn: turn, actions: actions, environment: environment(enabled: false))
        XCTAssertFalse(info.isEnabled)
        info.performClick(nil)
        XCTAssertEqual(opened.count, 1)
    }

    @MainActor func testTheClockTicksOnlyWhileTheTurnRunsOnScreen() async throws {
        var turn = Fixtures.running()
        turn.startedAt = nil; turn.liveStartedUptimeMs = ProcessInfo.processInfo.systemUptime * 1000 - 3_000
        let report = TranscriptNativeTurnReport()
        report.update(turn: turn, actions: TranscriptActions(), status: "Working…", environment: environment())
        XCTAssertFalse(report.duration.clock?.ticking ?? true, "Off screen nothing ticks")
        let window = mounted(report)
        report.update(turn: turn, actions: TranscriptActions(), status: "Working…", environment: environment())
        XCTAssertTrue(report.duration.clock?.ticking ?? false)
        let clock = try XCTUnwrap(views(TranscriptLabel.self, in: report).first { $0.accessibilityIdentifier() == "elapsedClock" })
        let first = clock.text
        try await eventually("the clock ticks", timeout: .seconds(4)) { clock.text != first }
        var settled = turn; settled.live = false; settled.outcome = "completed"; settled.elapsedMs = 4_200
        report.update(turn: settled, actions: TranscriptActions(), environment: environment())
        XCTAssertFalse(report.duration.clock?.ticking ?? true, "A settled turn's clock stops")
        XCTAssertEqual(clock.text, TurnDurationMetrics.label(4_200, live: false))
        report.update(turn: turn, actions: TranscriptActions(), status: "Working…", environment: environment())
        window.contentView = nil
        XCTAssertFalse(report.duration.clock?.ticking ?? true, "A report taken off screen stops its clock")
    }

    /// The live dock is a slot the conversation gives up once; what changes
    /// while the run goes on is new text in that slot, never a new line.
    @MainActor func testTheLiveDockKeepsOneHeightWhileItsWordsChange() {
        let mini = GatewayModelRoute(requested: "auto-router", responded: "gpt-5.4-mini", latestWall: 1)
        let large = GatewayModelRoute(requested: "bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0-extended-thinking-router",
                                      responded: "bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0", latestWall: 2)
        func live(_ phase: String, tool: String? = nil, routes: [GatewayModelRoute] = [], cost: Double? = nil, usage: Bool = false,
                  elapsed: Double = 900, model: Double = 0, tools: Double = 0, notice: String? = nil) -> TurnSummary {
            var value = Fixtures.running(phase: phase, accounting: TurnAccounting(requests: usage ? 3 : 1))
            value.startedAt = nil; value.elapsedMs = elapsed; value.modelMs = model; value.toolMs = tools; value.notice = notice
            value.current = tool.map { ToolView(id: "current", name: $0, state: "running", input: "", output: "", truncated: false) }
            value.accounting.modelRoutes = routes
            if let cost { value.accounting.costUSD = cost; value.accounting.costSamples = 1 }
            if usage {
                value.accounting.input = 123_456_789; value.accounting.inputSamples = 2
                value.accounting.output = 9_876_543; value.accounting.outputSamples = 2
                value.accounting.inputSplit = GatewayTokenSplit(total: 123_456_789, part: 98_765_432, samples: 2)
                value.accounting.outputSplit = GatewayTokenSplit(total: 9_876_543, part: 1_234_567, samples: 2)
            }
            return value
        }
        let states = [
            live("preparing"), live("model", routes: [mini]),
            live("tools", tool: "bash", routes: [mini], cost: 0.0000012345, usage: true, elapsed: 9_000, model: 7_500, tools: 1_500),
            live("tools", tool: "an_unusually_long_mcp_tool_name_for_the_status", routes: [mini, large], cost: 12.3456789, usage: true,
                 elapsed: 3_700_000, model: 3_662_345, tools: 37_655, notice: String(repeating: "Long message ", count: 100)),
            live("compacting", routes: [large], cost: 0.25), live("retrying", routes: [large, mini], cost: 0.000001),
        ]
        let reports = states.map { state -> TranscriptNativeTurnReport in
            let report = TranscriptNativeTurnReport()
            report.update(turn: state, actions: TranscriptActions(), status: TurnInfoPresentation.workingLabel(state), environment: environment())
            return report
        }
        var moved: [String] = []
        for width in stride(from: CGFloat(240), through: 920, by: 20) {
            let heights = reports.map { $0.height(width: width) }
            if let low = heights.min(), let high = heights.max(), high - low > 0.01 { moved.append("\(Int(width)) pt: \(heights)") }
        }
        XCTAssertTrue(moved.isEmpty, "The dock changed height as its words changed:\n" + moved.joined(separator: "\n"))
    }

    @MainActor func testTheWorkingLineSweepsUnlessMotionIsReduced() throws {
        let report = TranscriptNativeTurnReport()
        report.reduceMotion = false
        report.update(turn: Fixtures.running(), actions: TranscriptActions(), status: "Running bash…", environment: environment())
        let window = mounted(report); defer { window.contentView = nil }
        let line = try XCTUnwrap(views(TranscriptShimmerLabel.self, in: report).first)
        XCTAssertEqual(line.accessibilityIdentifier(), "workingIndicator")
        XCTAssertEqual(line.accessibilityLabel(), "Running bash…")
        line.layoutSubtreeIfNeeded()
        XCTAssertTrue(line.sweeping)
        report.reduceMotion = true
        line.layoutSubtreeIfNeeded()
        XCTAssertFalse(line.sweeping, "Reduced motion leaves the words still")
        report.update(turn: Fixtures.turn(), actions: TranscriptActions(), environment: environment())
        XCTAssertTrue(views(TranscriptShimmerLabel.self, in: report).isEmpty, "A settled turn has no working line")
    }

    @MainActor func testAFinishedTurnsRowIsNativeAndReadsAsBefore() throws {
        var block = TranscriptBlock(id: "summary:t", key: "summary:t", turnID: nil, message: nil, activity: [], tools: [], accounting: TurnAccounting(),
                                    startedAt: nil, endedAt: nil, modelMs: 0, toolMs: 0, live: false, turn: Fixtures.settledFixtures[2].turn)
        block.presentation = .summary
        let row = TranscriptRowContainer(item: .block(block), fresh: false, actions: TranscriptActions(), environment: environment(), disclosure: TranscriptDisclosure())
        _ = row.measure(width: 600)
        let content = try XCTUnwrap(row.subviews.first as? TranscriptNativeTurnSummaryRow)
        XCTAssertEqual(content.report.accessibilityIdentifier(), "turn-pills")
        let bars = views(TranscriptNativeTokenBar.self, in: content)
        XCTAssertEqual(bars.map { $0.accessibilityLabel() }, [TurnTokenPartition(block.turn!.accounting, input: true).help,
                                                             TurnTokenPartition(block.turn!.accounting, input: false).help])
        let notice = try XCTUnwrap(views(TranscriptPlainTextView.self, in: content).first { $0.text == StableTurnSummaryView.shownNotice(block.turn!) })
        XCTAssertTrue(notice.isSelectable, "The notice under the card is selectable, as it was")
        // Folded away with its turn, it draws nothing.
        var inputs = TranscriptRowInputs(item: .block(block), fresh: false, actions: TranscriptActions(), width: 600, environment: environment())
        inputs.disclosure.foldedAway = true
        content.apply(inputs)
        XCTAssertEqual(content.confirmHeight(), 1)
    }

    @MainActor func testASettledTurnLineGlowsAndSaysWhenItRan() throws {
        let line = TranscriptNativeTurnLine()
        line.update(turn: Fixtures.turn(), settled: true, actions: TranscriptActions(), model: nil, environment: environment())
        XCTAssertEqual(line.accessibilityLabel(), "Turn: \(TurnLineView.counts(Fixtures.turn()))")
        XCTAssertTrue(line.toolTip?.hasPrefix("Started ") ?? false)
        let panels = line.subviews.compactMap { $0 as? TranscriptPanel }
        XCTAssertEqual(panels.map { $0.fill }, [TranscriptNSPalette.accent.withAlphaComponent(0.07), TranscriptNSPalette.accent.withAlphaComponent(0.55)])
        line.update(turn: Fixtures.turn(), settled: false, actions: TranscriptActions(), model: nil, environment: environment())
        XCTAssertEqual(panels.map { $0.fill }, [nil, TranscriptNSPalette.hair])
    }

    /// A model name too long for the header gives way first, cut in its
    /// middle so both its ends still show, and never pushes the cost, Info or
    /// Copy out of the report.
    @MainActor func testALongModelGivesWayInItsMiddle() throws {
        let turn = Fixtures.settledFixtures.first { $0.name == "long-model" }!.turn
        for width: CGFloat in [300, 460] {
            let report = TranscriptNativeTurnReport()
            report.update(turn: turn, actions: TranscriptActions(), environment: environment())
            let window = mounted(report, width: width); defer { window.contentView = nil }
            let model = try XCTUnwrap(views(TranscriptLabel.self, in: report).first { $0.accessibilityIdentifier() == "turn-report-model" })
            XCTAssertEqual(model.truncation, .middle)
            XCTAssertLessThan(model.frame.width, model.intrinsicSize.width, "\(width): the model is cut short")
            let copy = try XCTUnwrap(views(TranscriptIconButton.self, in: report).first)
            XCTAssertLessThanOrEqual(copy.frame.maxX, width - 10 + 0.01, "\(width): Copy stays inside the report")
        }
    }

    /// What the report says is read out wherever it is drawn: the clock, a
    /// settled turn's note over several lines (with its whole text under the
    /// pointer), and AI and tool time that wraps.
    @MainActor func testTheReadingsAndTheNoteAreReadOut() throws {
        var turn = Fixtures.settledFixtures.first { $0.name == "wordy" }!.turn
        turn.modelMs = 36_620_000; turn.toolMs = 36_000_000
        let report = TranscriptNativeTurnReport()
        report.update(turn: turn, actions: TranscriptActions(), environment: environment())
        let window = mounted(report, width: 580); defer { window.contentView = nil }
        func shown(_ identifier: String) -> [NSView] {
            views(NSView.self, in: report).filter { $0.accessibilityIdentifier() == identifier && !$0.isHiddenOrHasHiddenAncestor }
        }
        let clock = try XCTUnwrap(shown("elapsedClock").first)
        XCTAssertTrue(clock.isAccessibilityElement())
        XCTAssertEqual(clock.accessibilityLabel(), TurnDurationMetrics.label(turn.elapsedMs!, live: false))
        let note = try XCTUnwrap(shown("turn-coverage-notice").first)
        let expected = TurnInfoPresentation.cardNote(turn)
        XCTAssertTrue(note is TranscriptPlainTextView, "a settled note wraps")
        XCTAssertTrue(note.isAccessibilityElement())
        XCTAssertEqual(note.accessibilityLabel(), expected)
        XCTAssertEqual(note.toolTip, expected)
        let split = "AI \(TurnDurationMetrics.label(turn.modelMs, live: false)) · Tools \(TurnDurationMetrics.label(turn.toolMs, live: false))"
        let wrapped = try XCTUnwrap(views(TranscriptPlainTextView.self, in: report.duration).first { !$0.isHidden }, "the AI and tool time wraps here")
        XCTAssertTrue(wrapped.isAccessibilityElement())
        XCTAssertEqual(wrapped.accessibilityLabel(), split)
    }

    /// A click on Copy copies and leaves the keyboard where it was.
    @MainActor func testClickingCopyLeavesTheKeyboardWhereItWas() throws {
        let report = TranscriptNativeTurnReport()
        report.update(turn: Fixtures.turn(), actions: TranscriptActions(), environment: environment())
        let container = TranscriptNativeRowParityTests.ParityCanvas(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = container
        defer { window.contentView = nil; window.close() }
        report.frame = CGRect(x: 0, y: 0, width: 600, height: report.height(width: 600))
        container.addSubview(report)
        let field = NSTextField(frame: CGRect(x: 0, y: 260, width: 200, height: 22))
        container.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        container.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(field))
        let copy = try XCTUnwrap(views(TranscriptIconButton.self, in: report).first)
        NSPasteboard.general.clearContents()
        let location = copy.convert(CGPoint(x: copy.bounds.midX, y: copy.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        XCTAssertNotNil(NSPasteboard.general.string(forType: .string), "the click copied")
        let responder = window.firstResponder
        XCTAssertTrue(responder === field || (responder as? NSTextView)?.delegate === field, "the field keeps the keyboard: \(String(describing: responder))")
    }

    /// A line cut in its middle draws what it is now: an underline that comes
    /// or goes (a file link under the pointer) shows.
    @MainActor func testAMiddleCutRedrawsItsUnderline() throws {
        let label = TranscriptLabel()
        label.text = "Sources/App/Networking/Deeply/Nested/RetryPolicy.swift"; label.font = .systemFont(ofSize: 12); label.truncation = .middle
        label.frame = CGRect(x: 0, y: 0, width: label.width(truncatedTo: 140), height: label.intrinsicSize.height)
        func drawn() -> Data? {
            let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds)!
            label.cacheDisplay(in: label.bounds, to: rep)
            return rep.tiffRepresentation
        }
        let plain = drawn()
        label.underlined = true
        XCTAssertNotEqual(drawn(), plain, "the underline shows on the cut line")
        label.underlined = false
        XCTAssertEqual(drawn(), plain)
    }
}
