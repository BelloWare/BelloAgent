import AppKit
import ApplicationServices
import XCTest
@testable import PiApp

/// What the AppKit Pi components (DesignKit/) do: their actions, their
/// state contract (an assignment from outside is silent, a reader's action
/// calls back once), their keyboard, and what VoiceOver is told — read
/// through the accessibility client API, as A1's tests read the SwiftUI ones.
@MainActor final class PiKitControlTests: XCTestCase {
    private var assistive = false
    override func setUp() async throws { assistive = HostedAccessibility.begin(); PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws { HostedAccessibility.end(restoring: assistive); PiKit.Motion.reducedOverride = nil }

    /// `view` in a window of its own, inside a named group as a hosting view
    /// would be, front but not key; taken down after the test.
    private func hosted(_ view: NSView, size: CGSize = CGSize(width: 520, height: 260)) async throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "ax-" + UUID().uuidString
        let group = PiKit.Box.ClipView(frame: NSRect(origin: .zero, size: size))
        group.setAccessibilityElement(true); group.setAccessibilityRole(.group)
        window.contentView = group
        let fit = view.intrinsicContentSize
        view.frame = NSRect(x: 20, y: 20, width: fit.width == NSView.noIntrinsicMetric ? size.width - 40 : fit.width,
                            height: fit.height == NSView.noIntrinsicMetric ? 40 : fit.height)
        group.addSubview(view)
        window.orderFront(nil)
        group.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        addTeardownBlock { @MainActor in window.orderOut(nil); window.contentView = nil }
        return window
    }

    // MARK: Buttons

    func testAButtonRunsItsActionOncePerPressAndNotWhileDisabled() {
        var presses = 0
        let button = PiKit.Button("Save", style: .primary) { presses += 1 }
        button.performClick(nil)
        XCTAssertEqual(presses, 1)
        button.isEnabled = false
        button.performClick(nil)
        XCTAssertEqual(presses, 1, "a disabled button does nothing")
    }

    func testAButtonTakesItsSheetsReturnKey() {
        var presses = 0
        let button = PiKit.Button("Save", style: .primary) { presses += 1 }
        button.keyEquivalent = "\r"
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        XCTAssertTrue(button.performKeyEquivalent(with: event))
        XCTAssertEqual(presses, 1)
    }

    func testOnlyPillButtonsShrinkWhenPressed() {
        XCTAssertTrue(PiKit.Button("Save", style: .secondary).pressScales)
        XCTAssertFalse(PiKit.IconButton(symbol: "xmark", label: "Close").pressScales)
        XCTAssertFalse(PiKit.Switch(isOn: true).pressScales)
        XCTAssertFalse(PiKit.SelectableRow(content: NSView()).pressScales)
    }

    /// Under the pointer each style takes its SwiftUI twin's hover fill (the
    /// twins' own hover is compared in `PiKitParityTests.testHoverStates`
    /// where the runner may post pointer events).
    func testHoverTakesEachStylesHoverFill() {
        let probe = NSView()
        func fill(_ button: PiKit.ButtonBase, hovering: Bool) -> CGColor? { button.setHovering(hovering); return button.fill.backgroundColor }
        let secondary = PiKit.Button("Reload", style: .secondary)
        XCTAssertEqual(fill(secondary, hovering: false), probe.piCGColor(.piFill))
        XCTAssertEqual(fill(secondary, hovering: true), probe.piCGColor(.piFillStrong))
        let ghost = PiKit.Button("More", style: .ghost)
        XCTAssertEqual(fill(ghost, hovering: true), probe.piCGColor(.piFill))
        let danger = PiKit.Button("Delete", style: .danger)
        XCTAssertEqual(fill(danger, hovering: true), probe.piCGColor(NSColor.piDanger.withAlphaComponent(0.17)))
        let primary = PiKit.Button("Save", style: .primary)
        primary.setHovering(true)
        XCTAssertEqual(primary.shade.backgroundColor, probe.piCGColor(NSColor.black.withAlphaComponent(0.05)))
        let icon = PiKit.IconButton(symbol: "xmark", label: "Close")
        XCTAssertEqual(fill(icon, hovering: true), probe.piCGColor(.piFillStrong))
        let row = PiKit.SelectableRow(content: NSView())
        XCTAssertEqual(fill(row, hovering: true), probe.piCGColor(.piFill))
        let menu = PiKit.MenuButton(title: "Branches") { PiMenuEntry.button("main") {} }
        XCTAssertEqual(fill(menu, hovering: true), probe.piCGColor(.piFill))
        menu.isEnabled = false
        XCTAssertEqual(fill(menu, hovering: true), probe.piCGColor(.piSurface), "a disabled menu does not light up")
    }

    func testAnIconButtonCanSayWhichItemItActsOn() async throws {
        let window = try await hosted(PiKit.IconButton(symbol: "xmark", label: "Remove", spokenLabel: "Remove follow-up 2"))
        let button = try await AXClient.find(in: window) { $0.label == "Remove follow-up 2" }
        XCTAssertEqual(button.role, "AXButton")
        XCTAssertEqual(button.help, "Remove", "the tooltip stays short")
    }

    // MARK: Switch and checkbox

    func testASwitchTogglesOnAPressAndIsSilentWhenSetFromOutside() async throws {
        var changes: [Bool] = []
        let toggle = PiKit.Switch(isOn: false, label: "Show tokens") { changes.append($0) }
        toggle.isOn = true
        XCTAssertEqual(changes, [], "an assignment from outside does not call back")
        toggle.performClick(nil)
        XCTAssertEqual(changes, [false]); XCTAssertFalse(toggle.isOn)
        let window = try await hosted(toggle)
        let node = try await AXClient.find(in: window) { $0.label == "Show tokens" }
        XCTAssertEqual(node.role, "AXCheckBox")
        XCTAssertEqual(node.value, "0")
        XCTAssertTrue(AXClient.press(node))
        XCTAssertEqual(changes, [false, true])
        _ = try await AXClient.find(in: window, "the switch reads on") { $0.label == "Show tokens" && $0.value == "1" }
    }

    func testACheckboxIsACheckboxToVoiceOver() async throws {
        var changes: [Bool] = []
        let box = PiKit.Checkbox(isOn: true, label: "Include untracked") { changes.append($0) }
        let window = try await hosted(box)
        let node = try await AXClient.find(in: window) { $0.label == "Include untracked" }
        XCTAssertEqual(node.role, "AXCheckBox"); XCTAssertEqual(node.value, "1")
        XCTAssertTrue(AXClient.press(node))
        XCTAssertEqual(changes, [false])
    }

    // MARK: Tabs

    func testTabsMarkTheChosenTabSelectedAndNameTheirRow() async throws {
        var chosen: [Int] = []
        let tabs = PiKit.Tabs(selection: 2, items: [(1, "One"), (2, "Two")], accessibilityName: "Commit scope") { chosen.append($0) }
        let window = try await hosted(tabs)
        let row = try await AXClient.find(in: window) { $0.label == "Commit scope" }
        XCTAssertEqual(row.role, "AXGroup")
        XCTAssertEqual(row.children.map(\.label), ["One", "Two"])
        XCTAssertEqual(row.children.map(\.role), ["AXButton", "AXButton"])
        XCTAssertEqual(row.children.map(\.selected), [false, true])
        tabs.selection = 1
        XCTAssertEqual(chosen, [], "setting the selection from outside is silent")
        _ = try await AXClient.find(in: window, "the chosen tab follows") { $0.label == "Commit scope" && $0.children.map(\.selected) == [true, false] }
        tabs.tab(2)?.performClick(nil)
        XCTAssertEqual(chosen, [2]); XCTAssertEqual(tabs.selection, 2)
        tabs.tab(2)?.performClick(nil)
        XCTAssertEqual(chosen, [2], "choosing the chosen tab again calls nothing")
    }

    func testAnUnnamedTabRowAddsNoGroup() async throws {
        let window = try await hosted(PiKit.Tabs(selection: 1, items: [(1, "One"), (2, "Two")]))
        _ = try await AXClient.find(in: window) { $0.label == "One" }
        let content = try await AXClient.content(of: window)
        XCTAssertEqual(content.map(\.role), ["AXButton", "AXButton"])
        XCTAssertEqual(content.map(\.selected), [true, false])
    }

    // MARK: Stepper

    func testStepperButtonsNameTheirSettingWithItsValueAndBounds() async throws {
        var values: [Int64] = []
        let stepper = PiKit.Stepper(name: "Idle helper grace", unit: "seconds", value: 10, range: 10...600, step: 10) { values.append($0) }
        let window = try await hosted(stepper)
        _ = try await AXClient.find(in: window) { $0.label == "Decrease Idle helper grace" }
        let content = try await AXClient.all(in: window).filter { $0.role == "AXButton" }
        XCTAssertEqual(content.map(\.label), ["Decrease Idle helper grace", "Increase Idle helper grace"])
        XCTAssertEqual(content[0].value, "10 seconds")
        XCTAssertEqual(content[0].help, "From 10 to 600 seconds, in steps of 10")
        XCTAssertFalse(content[0].enabled, "at its lower bound"); XCTAssertTrue(content[1].enabled)
        XCTAssertTrue(AXClient.press(content[1]))
        XCTAssertEqual(values, [20])
        _ = try await AXClient.find(in: window, "the value follows a press") { $0.label == "Decrease Idle helper grace" && $0.value == "20 seconds" && $0.enabled }
        stepper.value = 600
        XCTAssertEqual(values, [20], "an assignment from outside is silent")
        XCTAssertFalse(stepper.increase.isEnabled, "at its upper bound")
    }

    // MARK: Dropdown and choice list

    func testADropdownIsNamedForWhatItChoosesAndReadsTheChoiceAsItsValue() async throws {
        let dropdown = PiKit.Dropdown(selection: "PUT", items: [("POST", "POST"), ("PUT", "PUT")], compact: true, accessibilityName: "Webhook method")
        let window = try await hosted(dropdown)
        let button = try await AXClient.find(in: window) { $0.label == "Webhook method" }
        XCTAssertEqual(button.role, "AXButton"); XCTAssertEqual(button.value, "PUT")
    }

    func testTheChoiceListMovesWithoutChoosingAndChoosesOnReturn() {
        var chosen: [Int] = [], cancelled = 0
        let list = PiKit.ChoiceList(title: "Model", selection: 2,
                                    choices: [PiKit.Choice(id: 1, title: "A"), PiKit.Choice(id: 2, title: "B"), PiKit.Choice(id: 3, title: "C", enabled: false), PiKit.Choice(id: 4, title: "D")],
                                    choose: { chosen.append($0) }, cancel: { cancelled += 1 })
        XCTAssertEqual(list.highlighted, 2, "it starts on the current choice")
        list.move(1)
        XCTAssertEqual(list.highlighted, 4, "a disabled choice is skipped")
        XCTAssertEqual(chosen, [], "moving chooses nothing")
        list.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        XCTAssertEqual(chosen, [4])
        list.commit(3)
        XCTAssertEqual(chosen, [4], "a disabled choice cannot be chosen")
        list.cancelOperation(nil)
        XCTAssertEqual(cancelled, 1)
    }

    // MARK: Menus

    func testAMenuButtonBuildsItsMenuOnlyWhenPressed() {
        var built = 0, ran = 0
        let button = PiKit.MenuButton(title: "Branches", identifier: "branches") {
            PiMenuEntry.button("main", identifier: "main") { ran += 1 }
        }
        XCTAssertEqual(button.accessibilityRole(), .menuButton)
        var menu: NSMenu?
        PiMenus.intercept = { (built_menu: NSMenu, _: NSView) in built += 1; menu = built_menu }
        defer { PiMenus.intercept = nil }
        XCTAssertEqual(built, 0)
        button.performClick(nil)
        XCTAssertEqual(built, 1)
        XCTAssertTrue(PiMenus.perform("main", in: try! XCTUnwrap(menu)))
        XCTAssertEqual(ran, 1)
    }

    // MARK: Rows

    func testASelectableRowIsMarkedSelectedAndRunsItsActions() async throws {
        var clicks = 0
        let one = PiKit.SelectableRow(content: PiKit.TextLine(PiKit.Line("gpt-5", font: PiKit.Font.body, color: .piInk)), action: { clicks += 1 })
        let two = PiKit.SelectableRow(content: PiKit.TextLine(PiKit.Line("claude", font: PiKit.Font.body, color: .piInk)), selected: true)
        let stack = PiKit.Box.ClipView(frame: NSRect(x: 0, y: 0, width: 240, height: 70))
        one.frame = NSRect(x: 0, y: 0, width: 240, height: 32); two.frame = NSRect(x: 0, y: 34, width: 240, height: 32)
        stack.addSubview(one); stack.addSubview(two)
        let window = try await hosted(stack, size: CGSize(width: 300, height: 120))
        let selected = try await AXClient.find(in: window) { $0.label == "claude" }
        let other = try await AXClient.find(in: window) { $0.label == "gpt-5" }
        XCTAssertEqual(selected.role, "AXButton")
        XCTAssertTrue(selected.selected); XCTAssertFalse(other.selected)
        XCTAssertTrue(AXClient.press(other))
        XCTAssertEqual(clicks, 1)
    }

    func testAClickOnAResizeHandleIsNotADrag() async throws {
        var changes: [CGFloat] = [], ends: [CGFloat] = []
        let handle = PiKit.ResizeHandle(orientation: .vertical, label: "Sidebar width", changed: { changes.append($0) }, ended: { ends.append($0) })
        let window = try await hosted(handle)
        func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 40), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        handle.mouseDown(with: event(.leftMouseDown, x: 24)); handle.mouseUp(with: event(.leftMouseUp, x: 24))
        XCTAssertEqual(changes, []); XCTAssertEqual(ends, [], "a click alone is not a drag")
        handle.mouseDown(with: event(.leftMouseDown, x: 24))
        handle.mouseDragged(with: event(.leftMouseDragged, x: 24.5))
        XCTAssertEqual(changes, [], "under a point is not yet a drag")
        handle.mouseDragged(with: event(.leftMouseDragged, x: 30))
        handle.mouseUp(with: event(.leftMouseUp, x: 34))
        XCTAssertEqual(changes, [6]); XCTAssertEqual(ends, [10])
        XCTAssertEqual(handle.accessibilityRole(), .splitter)
    }

    func testADisabledRowDimsAndDisablesItsContent() {
        let toggle = PiKit.Switch(isOn: true)
        let content = PiKit.Box.ClipView(); content.addSubview(toggle)
        let row = PiKit.SelectableRow(content: content)
        row.isEnabled = false
        XCTAssertFalse(toggle.isEnabled, "a control inside a disabled row is disabled")
        XCTAssertEqual(content.alphaValue, CGFloat(PiKit.plainDisabledDimming), accuracy: 0.001)
        row.isEnabled = true
        XCTAssertTrue(toggle.isEnabled)
    }

    func testAnOpenDropdownOnlyCommitsAChoiceStillOffered() async throws {
        var chosen: [String] = []
        let dropdown = PiKit.Dropdown(selection: "PUT", items: [("POST", "POST"), ("PUT", "PUT")]) { chosen.append($0) }
        _ = try await hosted(dropdown)
        dropdown.toggleChoices()
        let list = try XCTUnwrap(dropdown.list)
        dropdown.items = [("PUT", "PUT")]
        list.commit("POST")
        XCTAssertEqual(chosen, [], "POST was taken away while the list was open")
        XCTAssertEqual(dropdown.accessibilityValue() as? String, "PUT")
    }

    func testANotesTextCanBeSelectedAndCopied() {
        let note = PiKit.Note("Could not save.", tone: .danger)
        let label = note.subviews.compactMap { $0 as? NSTextField }.first
        XCTAssertEqual(label?.isSelectable, true, "as `.textSelection(.enabled)` let the reader copy it")
        XCTAssertEqual(label?.isEditable, false)
        note.text = "Saved."
        XCTAssertEqual(label?.stringValue, "Saved.")
    }

    // MARK: Fields

    func testATextFieldReportsTheReadersEditsAndReturn() {
        var edits: [String] = [], submits = 0
        let field = PiKit.TextField(placeholder: "Name", onChange: { edits.append($0) }, onSubmit: { submits += 1 })
        field.text = "set"
        XCTAssertEqual(edits, [], "setting the text from outside is silent")
        field.field.stringValue = "typed"
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field.field))
        XCTAssertEqual(edits, ["typed"])
        field.field.sendAction(field.field.action, to: field.field.target)
        XCTAssertEqual(submits, 1)
    }

    // MARK: Sheet

    func testEscapeLeavesASheetUnlessAWriteHoldsIt() {
        var dismissed = 0, asked = 0
        let sheet = PiKit.Sheet("Settings", content: NSView())
        sheet.dismiss = { dismissed += 1 }
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        XCTAssertTrue(sheet.performKeyEquivalent(with: escape))
        XCTAssertEqual(dismissed, 1)
        sheet.onCancel = { asked += 1 }
        sheet.cancel()
        XCTAssertEqual(asked, 1, "a sheet with unsaved work asks instead")
        XCTAssertEqual(dismissed, 1)
        sheet.cancelDisabled = true
        sheet.cancel()
        XCTAssertEqual(asked, 1, "a write in progress holds Escape back")
        let window = PiKit.Sheet("Window", windowChrome: true, content: NSView())
        window.dismiss = { dismissed += 1 }
        XCTAssertFalse(window.performKeyEquivalent(with: escape), "a window's Escape is the window's")
        XCTAssertEqual(dismissed, 1)
    }

    // MARK: Stat pill

    func testAStatPillRollsWithinItsChatAndReplacesAcrossChats() async throws {
        PiKit.Motion.reducedOverride = false
        defer { PiKit.Motion.reducedOverride = true }
        let pill = PiKit.StatPill(symbol: "chart.pie", label: "1.0K tok", scope: "a")
        _ = try await hosted(pill)
        pill.update(label: "1.2K tok", scope: "a")
        XCTAssertTrue(pill.isRolling, "a figure that changes within a chat rolls")
        XCTAssertNil(pill.content.animation(forKey: kCATransition), "only the figures roll, not the symbol")
        pill.update(label: "9.9K tok", scope: "b")
        XCTAssertFalse(pill.isRolling, "another chat's figures replace the old ones at once, a roll in progress included")
        pill.update(label: "9.9K tok", scope: "b")
        XCTAssertFalse(pill.isRolling, "an unchanged figure does not roll")
    }

    func testAPopoverPillsHighlightFollowsItsPopover() async throws {
        let presenter = PiPopoverPresenter()
        let pill = PiKit.StatPopoverPill(symbol: "chart.pie", label: "7.3K tok", accessibility: "Usage", presenter: presenter) { PiKit.Note("Panel") }
        _ = try await hosted(pill)
        pill.performClick(nil)
        try await eventually("the popover opening") { presenter.isShown }
        XCTAssertTrue(pill.open)
        presenter.close()
        try await eventually("the highlight following a close from elsewhere") { !pill.open }
        pill.update(label: "7.4K tok", scope: nil)
        XCTAssertEqual(pill.accessibilityLabel(), "Usage", "its own name survives a new reading")
    }

    func testAStatPillCanShowAnEmptyContextRingAndGoBackToItsSymbol() {
        let pill = PiKit.StatPill(symbol: "chart.pie", label: "—")
        let ring = { pill.subviews.compactMap { $0 as? PiKit.Ring }.first }
        pill.update(glyph: .ring(nil), label: "—", scope: nil)
        XCTAssertEqual(ring()?.isHidden, false, "no reading yet is an empty ring, not the symbol")
        XCTAssertEqual(ring()?.fraction, 0)
        pill.update(glyph: .symbol("chart.pie"), label: "—", scope: nil)
        XCTAssertEqual(ring()?.isHidden, true)
    }

    func testTabsKeepTheButtonsOfTabsThatStay() {
        let tabs = PiKit.Tabs(selection: 2, items: [(1, "One"), (2, "Two")])
        let two = tabs.tab(2)
        tabs.items = [(0, "Zero"), (1, "One"), (2, "Two, renamed")]
        XCTAssertTrue(tabs.tab(2) === two, "a tab that stays keeps its button")
        XCTAssertEqual(two?.title, "Two, renamed")
        tabs.items = [(2, "Two")]
        XCTAssertTrue(tabs.tab(2) === two)
        XCTAssertNil(tabs.tab(1)?.superview)
    }

    func testEnablingARowRestoresOnlyWhatItDisabled() {
        let off = PiKit.Switch(isOn: true); off.isEnabled = false
        let on = PiKit.Switch(isOn: true)
        let content = PiKit.Box.ClipView(); content.addSubview(off); content.addSubview(on)
        let row = PiKit.SelectableRow(content: content)
        row.isEnabled = false
        XCTAssertFalse(on.isEnabled)
        row.isEnabled = true
        XCTAssertTrue(on.isEnabled)
        XCTAssertFalse(off.isEnabled, "a control that was off before stays off")
    }

    func testAnOpenDropdownFollowsItsItemsInPlace() async throws {
        let dropdown = PiKit.Dropdown(selection: "PUT", items: [("POST", "POST"), ("PUT", "PUT")])
        _ = try await hosted(dropdown)
        dropdown.toggleChoices()
        let list = try XCTUnwrap(dropdown.list)
        dropdown.items = [("POST", "POST"), ("PUT", "PUT"), ("PATCH", "PATCH")]
        XCTAssertTrue(dropdown.list === list, "the open list is updated, not replaced")
        XCTAssertEqual(list.choices.map(\.id), ["POST", "PUT", "PATCH"])
        dropdown.items = [("POST", "POST"), ("PUT", "PUT"), ("PATCH", "PATCH")]
        XCTAssertEqual(list.choices.count, 3, "an identical assignment changes nothing")
    }

    func testASpinnerKeepsItsControlSize() {
        XCTAssertEqual(PiKit.spinner(controlSize: .small).intrinsicContentSize, NSSize(width: 16, height: 16))
        XCTAssertEqual(PiKit.spinner(controlSize: .mini).intrinsicContentSize, NSSize(width: 10, height: 10))
    }

    func testAppearingRisesFromBelowInAFlippedView() {
        PiKit.Motion.reducedOverride = false
        defer { PiKit.Motion.reducedOverride = true }
        let view = PiKit.Box.ClipView(); view.wantsLayer = true
        PiKit.appear(view, index: 0)
        let group = view.layer?.animation(forKey: "appear") as? CAAnimationGroup
        let rise = group?.animations?.compactMap { $0 as? CABasicAnimation }.first { $0.keyPath == "transform.translation.y" }
        XCTAssertEqual(rise?.fromValue as? CGFloat, 4, "four points below, down being positive when flipped")
    }

    // MARK: Gauges

    func testTheContextRingWarnsAtEightyAndDangersAtNinetyFive() {
        func tint(_ fraction: Double) -> CGColor? {
            let ring = PiKit.Ring.context(fraction, size: 14)
            ring.frame = NSRect(x: 0, y: 0, width: 14, height: 14)
            ring.layoutSubtreeIfNeeded()
            return (ring.layer?.sublayers?.last as? CAShapeLayer)?.strokeColor
        }
        let view = NSView()
        XCTAssertEqual(tint(0.5), view.piCGColor(.piAccent))
        XCTAssertEqual(tint(0.8), view.piCGColor(.piWarning))
        XCTAssertEqual(tint(0.95), view.piCGColor(.piDanger))
    }

    func testAProgressBarReportsItsShare() {
        let bar = PiKit.ProgressBar(value: 3, total: 4)
        XCTAssertEqual(bar.accessibilityRole(), .progressIndicator)
        XCTAssertEqual(bar.accessibilityValue() as? Double, 0.75)
        bar.total = 0
        XCTAssertEqual(bar.fraction, 0, "no total reads as nothing done")
    }
}
