import XCTest
import AppKit
@testable import PiApp

/// What the native compaction, request and tool-result rows and a sent
/// message's skills, versions and accounting do that a still capture cannot
/// show: clicks and keys, what VoiceOver hears and can do, a pane that takes
/// no input, and a right-to-left reader.
final class TranscriptNativeMessageKindBehaviourTests: XCTestCase {
    @MainActor final class Stage {
        let row: TranscriptRowContainer
        let window: NSWindow
        let disclosure = TranscriptDisclosure()
        var item: TranscriptItem
        var actions: TranscriptActions
        var environment: TranscriptRowEnvironment
        init(_ item: TranscriptItem, actions: TranscriptActions = TranscriptActions(), enabled: Bool = true, rightToLeft: Bool = false,
             opened: [TranscriptDisclosure.Part] = [], width: CGFloat = 600) {
            self.item = item; self.actions = actions
            environment = TranscriptRowEnvironment()
            environment.isEnabled = enabled
            environment.layoutDirection = rightToLeft ? .rightToLeft : .leftToRight
            for part in opened { disclosure.setOpen(true, part) }
            row = TranscriptRowContainer(item: item, fresh: false, actions: actions, environment: environment, disclosure: disclosure)
            window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: width, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = TranscriptNativeRowParityTests.ParityCanvas(frame: CGRect(x: 0, y: 0, width: width, height: 600))
            window.contentView?.addSubview(row)
            refresh()
            window.makeKeyAndOrderFront(nil)
        }
        /// Lays the row out again for what the disclosure says now.
        func refresh() {
            _ = row.update(item: item, fresh: false, actions: actions, environment: environment)
            let width = window.contentView!.bounds.width
            let height = row.measure(width: width).height
            row.frame = CGRect(x: 0, y: 0, width: width, height: height)
            row.layoutForViewport()
            window.contentView?.layoutSubtreeIfNeeded()
        }
        var content: NSView { row.subviews.first! }
        func views<T: NSView>(_ type: T.Type) -> [T] {
            var found: [T] = []
            func walk(_ view: NSView) {
                if let view = view as? T { found.append(view) }
                for child in view.subviews { walk(child) }
            }
            walk(content)
            return found.filter { !$0.isHiddenOrHasHiddenAncestor }
        }
        func click(_ view: NSView) throws {
            let location = view.convert(CGPoint(x: min(8, view.bounds.width / 2), y: view.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
        }
        func key(_ characters: String, code: UInt16) throws {
            window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: window.windowNumber, context: nil, characters: characters,
                                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
        }
        func hover(_ view: NSView, _ inside: Bool) throws {
            let event = try XCTUnwrap(NSEvent.enterExitEvent(with: inside ? .mouseEntered : .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            inside ? view.mouseEntered(with: event) : view.mouseExited(with: event)
        }
        func close() { window.orderOut(nil); window.contentView = nil; window.close() }
    }

    static func compaction(_ id: String = "c1", accounting: GatewayTotals? = nil) -> TranscriptItem {
        var message = TranscriptMessage(id: id, role: "system", text: "## Kept\n\nThe summary the compaction kept.")
        message.kind = "compaction"; message.detail = "Compacted 48,213 tokens · 6 messages kept"; message.accounting = accounting
        return .message(message)
    }
    static func toolResult(_ id: String = "t1") -> TranscriptItem {
        var message = TranscriptMessage(id: id, role: "tool", text: "Build **complete**.")
        message.kind = "toolResult"; message.detail = "Tool result · bash · completed"
        return .message(message)
    }
    static func user(_ id: String = "u1", skills: [TranscriptSkillUse]? = nil, mark: MessageVersionMark? = nil, accounting: GatewayTotals? = nil) -> TranscriptItem {
        var message = TranscriptMessage(id: id, role: "user", text: "Tag it.", at: 1_000)
        message.skills = skills; message.versions = mark; message.accounting = accounting
        return .message(message)
    }

    /// The summary's line opens and closes it from a click, Space and
    /// Return, and the row grows by the summary it shows.
    @MainActor func testTheSummaryLineOpensByClickSpaceAndReturn() throws {
        let stage = Stage(Self.compaction()); defer { stage.close() }
        let closed = stage.row.frame.height
        let header = try XCTUnwrap(stage.views(TranscriptNativeFoldHeader.self).first)
        try stage.click(header)
        XCTAssertTrue(stage.disclosure.isOpen(.compaction("c1")), "a click opens the summary")
        stage.refresh()
        XCTAssertFalse(stage.views(NativeMarkdownContainer.self).isEmpty, "the summary is drawn")
        XCTAssertGreaterThan(stage.row.frame.height, closed + 10)
        let open = try XCTUnwrap(stage.views(TranscriptNativeFoldHeader.self).first)
        XCTAssertTrue(stage.window.makeFirstResponder(open))
        try stage.key(" ", code: 49)
        XCTAssertFalse(stage.disclosure.isOpen(.compaction("c1")), "Space closes it")
        try stage.key("\r", code: 36)
        XCTAssertTrue(stage.disclosure.isOpen(.compaction("c1")), "Return opens it")
    }

    /// The line says what it does and turns its chevron as SwiftUI's did.
    @MainActor func testTheSummaryLineSpeaksAndTurns() async throws {
        let stage = Stage(Self.compaction()); defer { stage.close() }
        var header = try XCTUnwrap(stage.views(TranscriptNativeFoldHeader.self).first)
        XCTAssertEqual(header.accessibilityRole(), .button)
        XCTAssertEqual(header.accessibilityLabel(), "Show Summary kept in context")
        XCTAssertEqual(header.toolTip, "Show the summary this compaction kept in context")
        XCTAssertEqual(header.subviews.compactMap { $0 as? TranscriptSymbol }.first?.rotation, -90)
        XCTAssertTrue(header.accessibilityPerformPress())
        stage.refresh()
        header = try XCTUnwrap(stage.views(TranscriptNativeFoldHeader.self).first)
        XCTAssertEqual(header.accessibilityLabel(), "Hide Summary kept in context")
        let chevron = try XCTUnwrap(header.subviews.compactMap { $0 as? TranscriptSymbol }.first)
        try await eventually("the chevron turns open") { abs(chevron.rotation) < 0.01 }
        XCTAssertEqual(stage.content.accessibilityLabel(), "Context compacted")
        XCTAssertEqual(stage.content.accessibilityCustomActions()?.map(\.name), ["Copy", "Details"])
    }

    /// The pointer over a compaction brings up its Copy and Details pills.
    @MainActor func testACompactionsPillsShowUnderThePointer() throws {
        let stage = Stage(Self.compaction()); defer { stage.close() }
        XCTAssertTrue(stage.views(TranscriptPillButton.self).isEmpty)
        try stage.hover(stage.content, true)
        let pills = stage.views(TranscriptPillButton.self)
        XCTAssertEqual(pills.map(\.title), ["Copy", "Details"])
        let card = stage.content.subviews.compactMap { $0 as? TranscriptPanel }.first { $0.frame.height > 30 }
        for pill in pills { XCTAssertTrue(try XCTUnwrap(card).frame.contains(pill.frame), "\(pill.title) is in the card's header") }
    }

    /// A pane that takes no input acts on nothing: the summary line, the
    /// version chevrons, the model link and the row's actions all refuse.
    @MainActor func testADisabledPaneRefusesEverything() throws {
        var inspected: [String] = [], stepped: [Int] = []
        var actions = TranscriptActions()
        actions.inspect = { inspected.append($0) }
        actions.switchVersion = { _, step in stepped.append(step) }
        let compaction = Stage(Self.compaction(accounting: TranscriptNativeRowParityTests.totals()), actions: actions, enabled: false)
        defer { compaction.close() }
        XCTAssertFalse(try XCTUnwrap(compaction.views(TranscriptNativeFoldHeader.self).first).accessibilityPerformPress())
        XCTAssertFalse(try XCTUnwrap(compaction.views(TranscriptNativeFoldHeader.self).first).isAccessibilityEnabled())
        XCTAssertFalse(compaction.disclosure.isOpen(.compaction("c1")))
        let link = try XCTUnwrap(compaction.views(TranscriptLinkButton.self).first)
        XCTAssertFalse(link.accessibilityPerformPress())
        XCTAssertFalse(try XCTUnwrap(compaction.content.accessibilityCustomActions()?.first { $0.name == "Details" }).handler?() ?? true)
        let user = Stage(Self.user(mark: MessageVersionMark(index: 2, count: 3, ids: ["a", "b", "c"])), actions: actions, enabled: false)
        defer { user.close() }
        for chevron in user.views(TranscriptNativeVersionChevron.self) {
            XCTAssertFalse(chevron.accessibilityPerformPress()); XCTAssertFalse(chevron.isAccessibilityEnabled())
        }
        XCTAssertTrue(inspected.isEmpty); XCTAssertTrue(stepped.isEmpty)
    }

    /// The model's name opens the request's details; the line says its whole
    /// receipt to VoiceOver and as its help.
    @MainActor func testTheModelLinkOpensTheRequestsDetails() throws {
        var inspected: [String] = []
        var actions = TranscriptActions(); actions.inspect = { inspected.append($0) }
        let totals = TranscriptNativeRowParityTests.totals()
        let stage = Stage(Self.compaction(accounting: totals), actions: actions); defer { stage.close() }
        let line = try XCTUnwrap(stage.views(TranscriptNativeAccounting.self).first)
        let presentation = TranscriptActivity.accountingPresentation(totals)
        XCTAssertEqual(line.accessibilityLabel(), "\(presentation.summary). \(presentation.detail)")
        XCTAssertEqual(line.toolTip, presentation.detail)
        let link = try XCTUnwrap(stage.views(TranscriptLinkButton.self).first)
        XCTAssertEqual(link.accessibilityLabel(), "View model reports: claude-sonnet-4-5")
        XCTAssertEqual(link.toolTip, "View response-body and header models")
        try stage.click(link)
        XCTAssertEqual(inspected, ["c1"])
    }

    /// The switcher steps between versions, its ends inert, and keeps the
    /// marker the conversation's checks read.
    @MainActor func testTheVersionSwitcherStepsAndItsEndsAreInert() throws {
        var stepped: [String] = []
        var actions = TranscriptActions(); actions.switchVersion = { id, step in stepped.append("\(id) \(step)") }
        let stage = Stage(Self.user(mark: MessageVersionMark(index: 1, count: 2, ids: ["a", "b"])), actions: actions); defer { stage.close() }
        let marker = try XCTUnwrap(stage.views(VersionSwitcherMarkerView.self).first)
        XCTAssertEqual(marker.messageID, "u1"); XCTAssertEqual(marker.mark?.index, 1)
        let switcher = try XCTUnwrap(stage.views(TranscriptNativeVersionSwitcher.self).first)
        XCTAssertEqual(switcher.accessibilityLabel(), "Version 1 of 2")
        XCTAssertEqual(switcher.accessibilityIdentifier(), "version-switcher")
        let chevrons = stage.views(TranscriptNativeVersionChevron.self)
        XCTAssertEqual(chevrons.map { $0.accessibilityLabel() }, ["Earlier version", "Later version"])
        try stage.click(chevrons[0])
        XCTAssertFalse(chevrons[0].accessibilityPerformPress(), "there is no earlier version")
        try stage.click(chevrons[1])
        XCTAssertTrue(stage.window.makeFirstResponder(chevrons[1]))
        try stage.key("\r", code: 36)
        XCTAssertEqual(stepped, ["u1 1", "u1 1"])
    }

    /// The skills lead the bubble as the composer's own pill buttons: each
    /// says its skill, reports the pointer and opens its popover on a press.
    @MainActor func testSkillPillsAreTheirButtons() throws {
        var hovered: [String] = [], pressed: [String] = []
        var actions = TranscriptActions()
        actions.skillHovered = { id, use, _, inside in hovered.append("\(id) \(use.name) \(inside)") }
        actions.skillPressed = { id, use, _ in pressed.append("\(id) \(use.name)") }
        let uses = [TranscriptNativeRowParityTests.skill("release-checklist", arguments: "notarize"), TranscriptNativeRowParityTests.skill("review")]
        let stage = Stage(Self.user(skills: uses), actions: actions); defer { stage.close() }
        let group = try XCTUnwrap(stage.views(TranscriptNativeSkillPills.self).first)
        XCTAssertEqual(group.accessibilityIdentifier(), "transcript-skill-pills")
        XCTAssertEqual(group.accessibilityLabel(), "Skills used by this message")
        let buttons = stage.views(SkillPillButton.self)
        XCTAssertEqual(buttons.map { $0.accessibilityIdentifier() }, ["skill-pill-release-checklist", "skill-pill-review"])
        XCTAssertEqual(buttons.map { $0.accessibilityLabel() }, ["Skill release-checklist, explicit for this message", "Skill review, explicit for this message"])
        XCTAssertEqual(buttons[1].copiedText, "/review")
        for button in buttons { XCTAssertEqual(button.frame.height, SkillPillFace.height, accuracy: 0.01) }
        try stage.hover(buttons[0], true)
        // An NSButton tracks its own click; its press is what a click ends in.
        buttons[1].performClick(nil)
        XCTAssertEqual(hovered, ["u1 release-checklist true"])
        XCTAssertEqual(pressed, ["u1 review"])
    }

    /// A tool result opens to what the tool returned, and says whether it is open.
    @MainActor func testAToolResultOpensToItsOutput() throws {
        let stage = Stage(Self.toolResult()); defer { stage.close() }
        let line = try XCTUnwrap(stage.views(TranscriptNativeLabelButton.self).first)
        XCTAssertEqual(line.accessibilityLabel(), "Tool result · bash · completed")
        XCTAssertEqual(line.accessibilityValue() as? String, "Closed")
        let closed = stage.row.frame.height
        try stage.click(line)
        XCTAssertTrue(stage.disclosure.isOpen(.compaction("t1")))
        stage.refresh()
        XCTAssertEqual(try XCTUnwrap(stage.views(TranscriptNativeLabelButton.self).first).accessibilityValue() as? String, "Open")
        XCTAssertGreaterThan(stage.row.frame.height, closed + 10)
        XCTAssertEqual(stage.views(NativeMarkdownContainer.self).first?.textView.string.contains("complete"), true)
    }

    /// A response folded to its header line takes its figures there: its
    /// own line draws nothing and says nothing.
    @MainActor func testAFoldedResponsesLineDrawsNothing() throws {
        var message = TranscriptMessage(id: "r1", role: "assistant", text: "")
        message.kind = "requestInfo"; message.accounting = TranscriptNativeRowParityTests.totals()
        let stage = Stage(.message(message), opened: [.response("r1")]); defer { stage.close() }
        XCTAssertTrue(stage.content is TranscriptNativeRequestInfoRow)
        XCTAssertLessThanOrEqual(stage.row.frame.height, 1)
        XCTAssertFalse(stage.content.isAccessibilityElement())
    }

    /// Right to left, the switcher reads from the right and the accounting
    /// stands at the other edge.
    @MainActor func testARightToLeftMessageMirrors() throws {
        var actions = TranscriptActions(); actions.switchVersion = { _, _ in }
        let item = Self.user(mark: MessageVersionMark(index: 2, count: 3, ids: ["a", "b", "c"]), accounting: TranscriptNativeRowParityTests.totals(model: nil))
        let ltr = Stage(item, actions: actions), rtl = Stage(item, actions: actions, rightToLeft: true)
        defer { ltr.close(); rtl.close() }
        func frames(_ stage: Stage) -> [CGRect] { stage.views(TranscriptNativeVersionChevron.self).map { $0.convert($0.bounds, to: stage.content) } }
        XCTAssertLessThan(frames(ltr)[0].minX, frames(ltr)[1].minX)
        XCTAssertGreaterThan(frames(rtl)[0].minX, frames(rtl)[1].minX, "the earlier chevron is on the right")
        let width = ltr.content.bounds.width
        XCTAssertEqual(frames(rtl)[0].maxX, width - frames(ltr)[0].minX, accuracy: 0.5)
        func usage(_ stage: Stage) throws -> CGRect {
            let line = try XCTUnwrap(stage.views(TranscriptNativeAccounting.self).first)
            let label = try XCTUnwrap(line.subviews.compactMap { $0 as? TranscriptLabel }.first { !$0.isHidden && !$0.text.contains("·") || $0.text.count > 3 })
            return label.convert(label.bounds, to: stage.content)
        }
        XCTAssertGreaterThan(try usage(ltr).midX, width / 2, "the usage ends the band at the trailing edge")
        XCTAssertLessThan(try usage(rtl).midX, width / 2)
    }
}
