import AppKit
import SwiftUI
import XCTest
@testable import PiApp

/// The workspace's own sheets in AppKit: Return submits, as `onSubmit` did,
/// and leaving the field does not.
final class ShellSheetTests: XCTestCase {
    @MainActor func testReturnCreatesTheTopicAndLeavingTheFieldDoesNot() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("sheet-topic-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.workspaces = [WorkspaceRecord(id: "p", path: root.path, trusted: true)]
        var dismissed = 0
        let sheet = TopicSheetView(model: model, target: TopicEditorTarget(projectID: "p"), dismiss: { dismissed += 1 })
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: TopicSheetView.size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sheet
        defer { window.contentView = nil; window.close() }
        XCTAssertTrue(window.makeFirstResponder(sheet.field.field))
        let editor = try XCTUnwrap(sheet.field.field.currentEditor() as? NSTextView)
        editor.insertText("Payments", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(sheet.save.isEnabled)
        // Leaving the field is not Return.
        window.makeFirstResponder(nil)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(model.topics.isEmpty, "leaving the field created nothing")
        XCTAssertEqual(dismissed, 0)
        XCTAssertTrue(window.makeFirstResponder(sheet.field.field))
        try XCTUnwrap(sheet.field.field.currentEditor() as? NSTextView).insertNewline(nil)
        try await eventually("Return created the topic and closed the sheet") { model.topics.contains { $0.title == "Payments" } && dismissed == 1 }
    }

    /// Bring Back in a side's header opens the handoff sheet over the window,
    /// with the side's last answer to edit; Insert puts it in the parent's
    /// draft and the sheet goes.
    @MainActor func testBringBackOpensTheHandoffAndInsertsInTheParentDraft() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("sheet-handoff-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.workspaces = [WorkspaceRecord(id: "w", path: root.path, trusted: true)]
        let parentChat = ChatRecord(id: "parent", workspaceID: "w", title: "Parent", path: nil, profileID: "p")
        model.chats = [parentChat]
        let parent = SessionDisplay(id: "parent"), side = SessionDisplay(id: "side")
        parent.draft = "Draft so far"
        side.messages = [TranscriptMessage(id: "a1", role: "assistant", text: "What the side found")]
        model.displays = ["parent": parent, "side": side]
        let info = SideRecord(id: "side", parentID: "parent", workspaceID: "w", profileID: "p", title: "Side")
        model.sides["parent"] = info
        let pane = SidePaneView(model: model, session: side, info: info, paneWidth: 600)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        window.makeKeyAndOrderFront(nil)
        defer { window.attachedSheet.map { window.endSheet($0) }; window.contentView = nil; window.close() }
        pane.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let bringBack = try XCTUnwrap(descendants(pane).compactMap { $0 as? PiKit.IconButton }.first { $0.label == "Bring Back to Parent Draft…" })
        bringBack.performClick(nil)
        try await eventually("the handoff sheet is up") { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet?.contentView)
        try await eventually("its AppKit content") { descendants(sheet).contains { $0 is SideHandoffView } }
        let handoff = try XCTUnwrap(descendants(sheet).compactMap { $0 as? SideHandoffView }.first)
        XCTAssertEqual(handoff.editor.text, "What the side found")
        // The window disabled while the sheet is up (from SwiftUI's update,
        // as the right pane sets it): its actions and editor follow.
        let host = NSHostingView(rootView: SidePaneDisabler(pane: pane, enabled: false))
        host.frame = NSRect(x: 0, y: 0, width: 10, height: 10); host.layoutSubtreeIfNeeded()
        try await eventually("the open handoff is disabled") { !handoff.insert.isEnabled && !handoff.editor.editor.isEditable }
        host.rootView = SidePaneDisabler(pane: pane, enabled: true); host.layoutSubtreeIfNeeded()
        try await eventually("and enabled again") { handoff.insert.isEnabled && handoff.editor.editor.isEditable }
        handoff.insert.performClick(nil)
        XCTAssertEqual(parent.draft, "Draft so far\n\nWhat the side found")
        try await eventually("the sheet went") { window.attachedSheet == nil }
        // Open again, then the side leaves the window: its sheet goes with it.
        bringBack.performClick(nil)
        try await eventually("the handoff sheet is up again") { window.attachedSheet != nil }
        window.contentView = NSView()
        try await eventually("the side's sheet went with it") { window.attachedSheet == nil }
    }

    /// Disabled with the window, a sheet's field and buttons are off; enabled
    /// again, they are as its own state says.
    @MainActor func testASheetFollowsTheWindowsDisabledState() throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("sheet-disabled-" + UUID().uuidString)
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.topics = [TopicRecord(id: "t", workspaceID: "p", title: "Payments")]
        let sheet = TopicSheetView(model: model, target: TopicEditorTarget(projectID: "p", topicID: "t"), dismiss: {})
        XCTAssertTrue(sheet.save.isEnabled); XCTAssertTrue(sheet.cancel.isEnabled); XCTAssertTrue(sheet.field.field.isEnabled)
        let hosted = NSHostingView(rootView: AppKitSheet { sheet }.disabled(true))
        hosted.frame = NSRect(origin: .zero, size: TopicSheetView.size)
        hosted.layoutSubtreeIfNeeded()
        XCTAssertFalse(sheet.save.isEnabled, "disabled through the SwiftUI around it")
        XCTAssertFalse(sheet.cancel.isEnabled); XCTAssertFalse(sheet.field.field.isEnabled)
        // Escape does not leave a disabled sheet either.
        var dismissed = 0
        let escaping = TopicSheetView(model: model, target: TopicEditorTarget(projectID: "p", topicID: "t"), dismiss: { dismissed += 1 })
        escaping.frame = NSRect(origin: .zero, size: TopicSheetView.size); escaping.layoutSubtreeIfNeeded()
        escaping.inheritedEnabled = false
        func sheetView(_ view: NSView) -> PiKit.Sheet? { (view as? PiKit.Sheet) ?? view.subviews.lazy.compactMap { sheetView($0) }.first }
        let chrome = try XCTUnwrap(sheetView(escaping))
        chrome.cancelOperation(nil)
        XCTAssertEqual(dismissed, 0, "disabled, Escape stays")
        escaping.inheritedEnabled = true
        chrome.cancelOperation(nil)
        XCTAssertEqual(dismissed, 1, "enabled, Escape leaves")
        hosted.rootView = AppKitSheet { sheet }.disabled(false)
        hosted.layoutSubtreeIfNeeded()
        XCTAssertTrue(sheet.save.isEnabled); XCTAssertTrue(sheet.field.field.isEnabled)
    }
}

/// Sets a side pane's inherited state from inside a SwiftUI update, as the right pane's representable does.
private struct SidePaneDisabler: NSViewRepresentable {
    let pane: SidePaneView
    let enabled: Bool
    func makeNSView(context: Context) -> NSView { pane.inheritedEnabled = enabled; return NSView() }
    func updateNSView(_ view: NSView, context: Context) { pane.inheritedEnabled = enabled }
}
