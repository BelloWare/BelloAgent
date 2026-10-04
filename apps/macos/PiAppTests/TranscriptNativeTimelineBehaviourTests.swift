import XCTest
import AppKit
@testable import PiApp

/// What the native response rows and turn fold do that a still capture
/// cannot show: clicks and keys, the keyboard's ring, what VoiceOver hears
/// and can do, a pane that takes no input, and a right-to-left reader.
final class TranscriptNativeTimelineBehaviourTests: XCTestCase {
    typealias Stage = TranscriptNativeMessageKindBehaviourTests.Stage

    static func fold(_ group: String = "g1") -> TranscriptItem {
        var block = TranscriptNativeRowParityTests.block("fold:" + group, .turnFold)
        block.foldControl = group
        block.foldSummary = TurnFoldSpec(group: group, answerResponseID: "a", toolCalls: 3, messages: 1)
        return .block(block)
    }
    static func header(_ id: String = "r1", foldable: Bool = true, live: Bool = false) -> TranscriptItem {
        var message = TranscriptMessage(id: id, role: "assistant", text: "")
        message.state = live ? "streaming" : "complete"
        var block = TranscriptNativeRowParityTests.block("response:" + id, .response, message: message, live: live)
        block.responseID = id
        block.responseSummary = ResponseLine(work: foldable ? "Reasoned, ran 2 commands" : "Answered", duration: "3.2s", figures: nil, parts: 3, foldable: foldable)
        return .block(block)
    }

    // MARK: The turn's fold

    @MainActor func testTheFoldOpensByClickSpaceAndReturn() throws {
        let stage = Stage(Self.fold()); defer { stage.close() }
        XCTAssertEqual(stage.row.frame.height, 40, "a closed fold is its line, its hairline and eight points")
        let control = try XCTUnwrap(stage.views(TranscriptNativeTurnFoldControl.self).first)
        try stage.click(control)
        XCTAssertTrue(stage.disclosure.isOpen(.turnFold("g1")), "a click opens the turn")
        stage.refresh()
        XCTAssertEqual(stage.row.frame.height, 36, "an open fold keeps four points under its line")
        XCTAssertTrue(stage.window.makeFirstResponder(control))
        try stage.key(" ", code: 49)
        XCTAssertFalse(stage.disclosure.isOpen(.turnFold("g1")), "Space closes it")
        try stage.key("\r", code: 36)
        XCTAssertTrue(stage.disclosure.isOpen(.turnFold("g1")), "Return opens it")
        try stage.key("a", code: 0)
        XCTAssertTrue(stage.disclosure.isOpen(.turnFold("g1")), "other keys are the conversation's")
    }

    @MainActor func testTheFoldShowsItsRingOnlyForTheKeyboard() throws {
        let stage = Stage(Self.fold()); defer { stage.close() }
        let control = try XCTUnwrap(stage.views(TranscriptNativeTurnFoldControl.self).first)
        XCTAssertTrue(control.canBecomeKeyView, "the fold is in the key loop, as `.focusable()` put it")
        XCTAssertTrue(stage.window.makeFirstResponder(control))
        XCTAssertTrue(control.isRingShown)
        XCTAssertFalse(stage.views(TranscriptFocusMarkerView.self).isEmpty, "the ring's marker is where checks look for it")
        XCTAssertTrue(stage.window.makeFirstResponder(nil))
        XCTAssertFalse(control.isRingShown)
        XCTAssertTrue(stage.views(TranscriptFocusMarkerView.self).isEmpty)
        // A click focuses nothing new and leaves no ring.
        try stage.click(control)
        XCTAssertFalse(control.isRingShown)
    }

    @MainActor func testTheFoldSpeaksAndTurns() async throws {
        let stage = Stage(Self.fold()); defer { stage.close() }
        let control = try XCTUnwrap(stage.views(TranscriptNativeTurnFoldControl.self).first)
        XCTAssertEqual(control.accessibilityRole(), .button)
        XCTAssertEqual(control.accessibilityIdentifier(), "turn-fold")
        XCTAssertEqual(control.accessibilityLabel(), "3 tool calls · 1 message")
        XCTAssertEqual(control.accessibilityValue() as? String, "Closed")
        XCTAssertEqual(control.toolTip, "Show this turn's work")
        let chevron = try XCTUnwrap(control.subviews.compactMap { $0 as? TranscriptSymbol }.first)
        XCTAssertEqual(chevron.rotation, -90)
        XCTAssertTrue(control.accessibilityPerformPress())
        stage.refresh()
        XCTAssertEqual(control.accessibilityValue() as? String, "Open")
        XCTAssertEqual(control.toolTip, "Hide this turn's work")
        try await eventually("the chevron turns open") { abs(chevron.rotation) < 0.01 }
        XCTAssertFalse(stage.content.isAccessibilityElement(), "the control is the row's one element")
    }

    @MainActor func testADisabledFoldRefuses() throws {
        let stage = Stage(Self.fold(), enabled: false); defer { stage.close() }
        let control = try XCTUnwrap(stage.views(TranscriptNativeTurnFoldControl.self).first)
        XCTAssertFalse(control.accessibilityPerformPress())
        XCTAssertFalse(control.isAccessibilityEnabled())
        try stage.click(control)
        XCTAssertFalse(stage.disclosure.isOpen(.turnFold("g1")))
        XCTAssertFalse(control.canBecomeKeyView)
    }

    @MainActor func testARightToLeftFoldReadsFromTheRight() throws {
        let stage = Stage(Self.fold(), rightToLeft: true); defer { stage.close() }
        let control = try XCTUnwrap(stage.views(TranscriptNativeTurnFoldControl.self).first)
        let label = try XCTUnwrap(control.subviews.compactMap { $0 as? TranscriptLabel }.first)
        let chevron = try XCTUnwrap(control.subviews.compactMap { $0 as? TranscriptSymbol }.first)
        XCTAssertGreaterThan(label.frame.minX, control.bounds.midX, "the words start at the right")
        XCTAssertLessThan(chevron.frame.maxX, label.frame.minX, "the chevron follows them leftward")
        XCTAssertTrue(chevron.mirroredAcross)
    }

    // MARK: A response's header line

    @MainActor func testTheWholeStripFoldsTheResponse() throws {
        let stage = Stage(Self.header()); defer { stage.close() }
        let row = try XCTUnwrap(stage.content as? TranscriptNativeResponseRow)
        try stage.click(row)
        XCTAssertTrue(stage.disclosure.isOpen(.responseLine("r1")), "a click on the line folds the response")
        stage.refresh()
        XCTAssertEqual(stage.row.frame.height, 4 + 20 + 10, "a folded response keeps ten points under its line")
        try stage.click(row)
        XCTAssertFalse(stage.disclosure.isOpen(.responseLine("r1")))
    }

    @MainActor func testTheFoldButtonSpeaksAndActs() throws {
        let stage = Stage(Self.header()); defer { stage.close() }
        let button = try XCTUnwrap(stage.views(TranscriptNativeResponseFoldButton.self).first)
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertEqual(button.accessibilityLabel(), "Fold this response to one line")
        XCTAssertEqual(button.toolTip, "Fold this response to one line")
        XCTAssertEqual(button.alphaValue, 0, "the button waits for the pointer while the response is open")
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertTrue(stage.disclosure.isOpen(.responseLine("r1")))
        stage.refresh()
        XCTAssertEqual(button.accessibilityLabel(), "Show this response")
        XCTAssertEqual(button.alphaValue, 1, "a folded response shows its button")
        XCTAssertEqual(stage.content.accessibilityLabel(), "Response · Reasoned, ran 2 commands · 3.2s · 3 parts folded")
    }

    @MainActor func testAQuietLineSpeaksUnderThePointer() throws {
        let stage = Stage(Self.header(foldable: false)); defer { stage.close() }
        let row = try XCTUnwrap(stage.content as? TranscriptNativeResponseRow)
        XCTAssertEqual(stage.row.frame.height, 14, "a plain answer's strip is paragraph spacing")
        XCTAssertEqual(row.summary, "")
        try stage.hover(row, true)
        XCTAssertEqual(row.summary, "Answered · 3.2s")
        XCTAssertEqual(stage.views(TranscriptNativeResponseFoldButton.self).first?.alphaValue, 1)
        stage.refresh()
        XCTAssertEqual(stage.row.frame.height, 14, "hovering moves nothing")
        try stage.hover(row, false)
        XCTAssertEqual(row.summary, "")
    }

    @MainActor func testTheMenuFoldsAndShowsTheResponse() throws {
        var actions = TranscriptActions()
        var copied: String?
        actions.copyMessage = { copied = $0 }
        let stage = Stage(Self.header(), actions: actions); defer { stage.close() }
        let row = try XCTUnwrap(stage.content as? TranscriptNativeResponseRow)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: row.convert(CGPoint(x: 20, y: 10), to: nil), modifierFlags: [],
                                                     timestamp: 0, windowNumber: stage.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(row.menu(for: event))
        XCTAssertEqual(menu.items.first?.title, "Fold This Response to One Line")
        XCTAssertNotNil(menu.items.first { $0.title == "Copy Reply" })
        let fold = try XCTUnwrap(menu.items.first)
        _ = (fold.target as AnyObject).perform(fold.action, with: fold)
        XCTAssertTrue(stage.disclosure.isOpen(.responseLine("r1")))
        stage.refresh()
        XCTAssertEqual(try XCTUnwrap(row.menu(for: event)).items.first?.title, "Show This Response")
        let copy = try XCTUnwrap(menu.items.first { $0.title == "Copy Reply" })
        _ = (copy.target as AnyObject).perform(copy.action, with: copy)
        XCTAssertEqual(copied, "r1")
    }

    @MainActor func testADisabledHeaderRefuses() throws {
        let stage = Stage(Self.header(), enabled: false); defer { stage.close() }
        let row = try XCTUnwrap(stage.content as? TranscriptNativeResponseRow)
        try stage.click(row)
        XCTAssertFalse(stage.disclosure.isOpen(.responseLine("r1")))
        XCTAssertFalse(try XCTUnwrap(stage.views(TranscriptNativeResponseFoldButton.self).first).accessibilityPerformPress())
        try stage.hover(row, true)
        XCTAssertEqual(stage.views(TranscriptNativeResponseFoldButton.self).first?.alphaValue, 0, "a pane that takes no input lights nothing")
    }

    @MainActor func testALiveResponseTurnsItsRing() throws {
        let stage = Stage(Self.header(live: true)); defer { stage.close() }
        XCTAssertEqual(stage.views(TranscriptSpinner.self).count, 1)
        let still = Stage(Self.header(live: false)); defer { still.close() }
        XCTAssertEqual(still.views(TranscriptSpinner.self).count, 0)
    }

    // MARK: A response's parts

    typealias P = TranscriptNativeRowParityTests

    @MainActor func testAThoughtOpensAndItsDetailsAct() throws {
        var actions = TranscriptActions()
        var inspected: String?
        actions.inspect = { inspected = $0 }
        let stage = Stage(P.partItem(P.segment("k1", "reasoningSummary", P.thought)), actions: actions); defer { stage.close() }
        XCTAssertEqual(stage.row.frame.height, 24, "a closed thought is its line")
        let line = try XCTUnwrap(stage.views(TranscriptNativeWorkLine.self).first)
        XCTAssertEqual(line.accessibilityLabel(), "Think, Planning the change. The fixture reads the README first.")
        XCTAssertEqual(line.accessibilityValue() as? String, "Closed")
        try stage.click(line)
        XCTAssertTrue(stage.disclosure.isOpen(.work("part:k1")))
        stage.refresh()
        XCTAssertGreaterThan(stage.row.frame.height, 60, "an open thought shows what it thought")
        XCTAssertFalse(stage.views(NativeMarkdownContainer.self).isEmpty)
        let details = try XCTUnwrap(stage.views(TranscriptLinkButton.self).first { $0.label.text == "Request details" })
        XCTAssertTrue(details.accessibilityPerformPress())
        XCTAssertEqual(inspected, "resp")
        let open = try XCTUnwrap(stage.views(TranscriptNativeWorkLine.self).first)
        XCTAssertTrue(stage.window.makeFirstResponder(open))
        try stage.key(" ", code: 49)
        XCTAssertFalse(stage.disclosure.isOpen(.work("part:k1")), "Space closes it")
    }

    @MainActor func testADisabledPartRefuses() throws {
        let stage = Stage(P.partItem(P.segment("k1", "reasoningSummary", P.thought)), enabled: false, opened: [.work("part:k1")]); defer { stage.close() }
        let details = try XCTUnwrap(stage.views(TranscriptLinkButton.self).first { $0.label.text == "Request details" })
        XCTAssertFalse(details.accessibilityPerformPress())
        let line = try XCTUnwrap(stage.views(TranscriptNativeWorkLine.self).first)
        XCTAssertFalse(line.accessibilityPerformPress())
        try stage.click(line)
        XCTAssertTrue(stage.disclosure.isOpen(.work("part:k1")), "a pane that takes no input folds nothing")
    }

    @MainActor func testArgumentsOpenAsCodeThatCopies() throws {
        let stage = Stage(P.partItem(P.segment("a1", "toolArguments", P.arguments, name: "bash")), opened: [.work("part:a1")]); defer { stage.close() }
        let code = try XCTUnwrap(stage.views(TranscriptNativeCodeBlock.self).first)
        XCTAssertFalse(code.usesTextKit, "a small finished fence is set in SwiftUI's line boxes")
        let copy = try XCTUnwrap(code.accessibilityCustomActions()?.first { $0.name == "Copy code" })
        NSPasteboard.general.clearContents()
        XCTAssertTrue(copy.handler?() ?? false)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), P.arguments)
        let button = try XCTUnwrap(code.subviews.compactMap { $0 as? TranscriptCopyButton }.first)
        XCTAssertEqual(button.alphaValue, 0, "the toolbar waits for the pointer")
        try stage.hover(code, true)
        XCTAssertFalse(button.isHidden)
        let streaming = Stage(P.partItem(P.segment("a2", "toolArguments", P.arguments, state: "streaming", name: "bash"), streaming: true),
                              opened: [.work("part:a2")]); defer { streaming.close() }
        XCTAssertTrue(try XCTUnwrap(streaming.views(TranscriptNativeCodeBlock.self).first).usesTextKit, "arguments still arriving are TextKit's own")
        XCTAssertEqual(streaming.views(TranscriptCodeTextView.self).count, 1)
    }

    @MainActor func testALongFenceReadsASectionAtATime() throws {
        let long = "{\"lines\": [\n" + (1...1_200).map { "  \"line \($0) of a long argument document\"," }.joined(separator: "\n") + "\n]}"
        let stage = Stage(P.partItem(P.segment("a9", "toolArguments", long, name: "write")), opened: [.work("part:a9")]); defer { stage.close() }
        let code = try XCTUnwrap(stage.views(TranscriptNativeCodeBlock.self).first)
        XCTAssertGreaterThan(code.sections.count, 1)
        let navigation = try XCTUnwrap(stage.views(TranscriptCodeSections.self).first)
        XCTAssertEqual(navigation.accessibilityIdentifier(), "codeSectionNavigation")
        let buttons = navigation.subviews.compactMap { $0 as? TranscriptLinkButton }
        XCTAssertFalse(try XCTUnwrap(buttons.first { $0.label.text == "Previous section" }).accessibilityPerformPress(), "the first section has no previous")
        XCTAssertTrue(try XCTUnwrap(buttons.first { $0.label.text == "Next section" }).accessibilityPerformPress())
        XCTAssertEqual(code.section, 1)
        XCTAssertNotNil(navigation.subviews.compactMap { $0 as? TranscriptLabel }.first { $0.text.hasPrefix("Code section 2 of") })
        let text = try XCTUnwrap(stage.views(TranscriptCodeTextView.self).first)
        XCTAssertFalse(text.string.hasPrefix("{"), "the second section is shown")
        NSPasteboard.general.clearContents()
        XCTAssertTrue(try XCTUnwrap(code.accessibilityCustomActions()?.first).handler?() ?? false)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), long, "Copy takes the whole fence")
    }

    @MainActor func testACardPartOpensItsCard() throws {
        let card = TranscriptNativeWorkParityTests.tool("call1", "bash", input: TranscriptNativeWorkParityTests.json(["command": "ls"]), output: "a\nb")
        let stage = Stage(P.partItem(P.segment("c1", "toolCall", "", call: "call1"), card: card)); defer { stage.close() }
        let row = try XCTUnwrap(stage.views(TranscriptNativeActionRow.self).first)
        XCTAssertEqual(row.frame.minX, 4, "a card sits four points in")
        try stage.click(row.line)
        XCTAssertTrue(stage.disclosure.isOpen(.tool(ToolOccurrence.key("resp", "call1"))), "the card's fold is keyed by the reply that made the call")
        stage.refresh()
        XCTAssertNotNil(try XCTUnwrap(stage.views(TranscriptNativeActionRow.self).first).card)
    }

    @MainActor func testWordsCarryTheResponsesFold() throws {
        let stage = Stage(P.partItem(P.segment("t1", "text", "Words of the answer."))); defer { stage.close() }
        let reply = try XCTUnwrap(stage.views(TranscriptNativeReplyRow.self).first)
        XCTAssertTrue(reply.isAccessibilityElement())
        XCTAssertEqual(reply.accessibilityLabel(), "assistant message")
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: reply.convert(CGPoint(x: 20, y: 10), to: nil), modifierFlags: [],
                                                     timestamp: 0, windowNumber: stage.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(reply.menu(for: event))
        let fold = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(fold.title, "Fold This Response to One Line")
        _ = (fold.target as AnyObject).perform(fold.action, with: fold)
        XCTAssertTrue(stage.disclosure.isOpen(.responseLine("resp")))
        stage.refresh()
        XCTAssertLessThanOrEqual(stage.row.frame.height, 1, "a response folded to its line empties its parts")
        XCTAssertTrue(reply.isHiddenOrHasHiddenAncestor)
    }

    // MARK: An execution record

    @MainActor func testAnExecutionOpensItsParts() throws {
        let stage = Stage(P.executionFixtures[0].item); defer { stage.close() }
        let row = try XCTUnwrap(stage.content as? TranscriptNativeExecutionRow)
        XCTAssertEqual(row.line.accessibilityValue() as? String, "Closed")
        XCTAssertTrue(row.line.accessibilityPerformPress())
        XCTAssertTrue(stage.disclosure.isOpen(.compaction("e1")))
        stage.refresh()
        XCTAssertEqual(row.parts.count, 2)
        XCTAssertNotNil(stage.views(TranscriptPlainTextView.self).first { $0.string == "No terminal receipt yet" })
        XCTAssertEqual(row.parts.first?.line?.content.open, true, "an execution's parts are open")
    }

    // MARK: A legacy reply and a task's aggregate

    static var legacy: TranscriptItem { P.legacyFixtures.first { $0.name == "legacy-closed" }!.item }

    @MainActor func testTheWorkHeaderFoldsItsListByFrame() throws {
        let stage = Stage(Self.legacy); defer { stage.close() }
        let row = try XCTUnwrap(stage.content as? TranscriptNativeLegacyRow)
        XCTAssertEqual(stage.row.frame.height, 24 + 2 + 10, "a folded list takes no room")
        try stage.click(row.header)
        XCTAssertTrue(stage.disclosure.isOpen(.work("legacy:l1")))
        stage.refresh()
        let works = row.works
        XCTAssertEqual(works.count, 1)
        XCTAssertEqual(works[0].activity?.builtRows.count, 2)
        let open = stage.row.frame.height
        XCTAssertGreaterThan(open, 100)
        try stage.click(row.header)
        stage.refresh()
        XCTAssertTrue(row.works.first === works.first, "folding keeps the list's views")
        XCTAssertEqual(stage.row.frame.height, 36)
        XCTAssertTrue(works[0].isHiddenOrHasHiddenAncestor || works[0].visibleRect.isEmpty, "a folded list draws nothing")
    }

    @MainActor func testACardOpeningInsideTheListRemeasuresIt() throws {
        let stage = Stage(Self.legacy, opened: [.work("legacy:l1")]); defer { stage.close() }
        let before = stage.row.frame.height
        let row = try XCTUnwrap(stage.content as? TranscriptNativeLegacyRow)
        let action = try XCTUnwrap(row.works.first?.activity?.builtRows.last)
        try stage.click(action.line)
        XCTAssertTrue(stage.disclosure.isOpen(.tool(ToolOccurrence.key("w1", "t2"))), "a task's card is keyed by its reply")
        stage.refresh()
        XCTAssertGreaterThan(stage.row.frame.height, before + 20, "the open card is measured, not the list's kept height")
    }

    @MainActor func testATasksActionsAndFiguresAct() throws {
        var actions = TranscriptActions()
        var inspected: [String] = [], copied: [String] = []
        actions.inspect = { inspected.append($0) }; actions.copyMessage = { copied.append($0) }
        let task = P.legacyFixtures.first { $0.name == "task-open" }!
        let stage = Stage(task.item, actions: actions, opened: task.opened); defer { stage.close() }
        let buttons = stage.views(TranscriptLinkButton.self)
        XCTAssertTrue(try XCTUnwrap(buttons.first { $0.label.text == "Copy reply" }).accessibilityPerformPress())
        XCTAssertTrue(try XCTUnwrap(buttons.first { $0.label.text == "Request details" }).accessibilityPerformPress())
        XCTAssertEqual(copied, ["w1"]); XCTAssertEqual(inspected, ["w1"])
        let figures = P.legacyFixtures.first { $0.name == "reply-figures" }!
        let reply = Stage(figures.item, actions: actions); defer { reply.close() }
        let model = try XCTUnwrap(reply.views(TranscriptNativeModelButton.self).first)
        XCTAssertEqual(model.accessibilityLabel(), "View model reports: claude-sonnet-4-5")
        XCTAssertTrue(model.accessibilityPerformPress())
        XCTAssertEqual(inspected.last, "w4", "the reports of the reply that named the model")
        XCTAssertNotNil(reply.views(TranscriptNativeFigures.self).first?.toolTip, "the figures say what the usage was")
        let disabled = Stage(figures.item, actions: actions, enabled: false); defer { disabled.close() }
        XCTAssertFalse(try XCTUnwrap(disabled.views(TranscriptNativeModelButton.self).first).accessibilityPerformPress())
    }

    @MainActor func testARightToLeftListHasItsRuleOnTheRight() throws {
        let stage = Stage(Self.legacy, rightToLeft: true, opened: [.work("legacy:l1")]); defer { stage.close() }
        let row = try XCTUnwrap(stage.content as? TranscriptNativeLegacyRow)
        let work = try XCTUnwrap(row.works.first)
        XCTAssertGreaterThan(work.frame.maxX, row.bounds.width - 13, "the replies end at the right, inside the rule")
        XCTAssertLessThan(work.frame.minX, 1)
    }

    // MARK: Codex's first review

    @MainActor func testTheFoldAndModelButtonsTakeSpaceAndReturn() throws {
        let stage = Stage(Self.header()); defer { stage.close() }
        let button = try XCTUnwrap(stage.views(TranscriptNativeResponseFoldButton.self).first)
        XCTAssertTrue(stage.window.makeFirstResponder(button))
        try stage.key(" ", code: 49)
        XCTAssertTrue(stage.disclosure.isOpen(.responseLine("r1")), "Space folds the response")
        var actions = TranscriptActions()
        var inspected: String?
        actions.inspect = { inspected = $0 }
        let figures = P.legacyFixtures.first { $0.name == "reply-figures" }!
        let reply = Stage(figures.item, actions: actions); defer { reply.close() }
        let model = try XCTUnwrap(reply.views(TranscriptNativeModelButton.self).first)
        XCTAssertTrue(reply.window.makeFirstResponder(model))
        try reply.key("\r", code: 36)
        XCTAssertEqual(inspected, "w4", "Return opens the model's reports")
    }

    @MainActor func testEveryFigureIsReadOut() throws {
        let figures = P.legacyFixtures.first { $0.name == "reply-figures" }!
        let stage = Stage(figures.item); defer { stage.close() }
        let flow = try XCTUnwrap(stage.views(TranscriptNativeFigures.self).first)
        let spoken = flow.subviews.compactMap { $0 as? TranscriptLabel }.filter { $0.isAccessibilityElement() }.compactMap { $0.accessibilityLabel() }
        XCTAssertEqual(spoken.count, 3, "duration, tokens and cost: \(spoken)")
        XCTAssertTrue(spoken.contains { $0.hasSuffix("tokens") })
    }

    @MainActor func testADisabledCodeBlockCopiesNothing() throws {
        let stage = Stage(P.partItem(P.segment("a1", "toolArguments", P.arguments, name: "bash")), enabled: false, opened: [.work("part:a1")]); defer { stage.close() }
        let code = try XCTUnwrap(stage.views(TranscriptNativeCodeBlock.self).first)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("before", forType: .string)
        XCTAssertFalse(try XCTUnwrap(code.accessibilityCustomActions()?.first).handler?() ?? true)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "before")
    }

    @MainActor func testFiguresFollowAChangeOfDirection() throws {
        let figures = P.legacyFixtures.first { $0.name == "reply-figures" }!
        let stage = Stage(figures.item); defer { stage.close() }
        let flow = try XCTUnwrap(stage.views(TranscriptNativeFigures.self).first)
        let first = try XCTUnwrap(flow.subviews.first)
        XCTAssertLessThan(first.frame.minX, 1)
        stage.environment.layoutDirection = .rightToLeft
        stage.refresh()
        XCTAssertGreaterThan(first.frame.maxX, flow.bounds.width - 1, "the first figure moves to the right")
    }
}
