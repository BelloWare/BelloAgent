import XCTest
import AppKit
@testable import PiApp

final class HistoricalEditFocusTests: XCTestCase {
    @MainActor func testDelayedHistoricalEditDoesNotTakeFocusFromSearchInTheSameChat() async throws {
        let root = scratchRoot("edit-focus")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let view = SessionDisplay(id: "chat"); view.draft = "Unsent draft"
        model.chats = [ChatRecord(id: view.id, workspaceID: "w", title: "Chat", profileID: "p")]
        model.displays[view.id] = view; model.selectedID = view.id; model.focusedSessionID = view.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let content = NSView(frame: window.contentView!.bounds); window.contentView = content
        func composer() -> NativeComposer { NativeComposer(text: view.draft, send: { _ in }, sessionID: view.id, focusToken: view.composerFocusRequest) }
        let scroll = composer().makeView(); scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 100); content.addSubview(scroll)
        let search = NSTextField(frame: NSRect(x: 0, y: 150, width: 260, height: 28)); content.addSubview(search)
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await eventually("fixture owns focus") { NSApp.keyWindow === window }
        XCTAssertTrue(window.makeFirstResponder(scroll.documentView))
        var pending: CheckedContinuation<Void, Never>?
        model.editTargetRead = { _, id in
            await withCheckedContinuation { pending = $0 }
            return ["messageId": .string(id), "text": .string("Historical message")]
        }
        model.editMessage("old", sessionID: view.id)
        try await eventually("target read held") { pending != nil }
        search.selectText(nil)
        let responder = try XCTUnwrap(search.currentEditor())
        let focusRequest = view.composerFocusRequest
        pending?.resume(); pending = nil
        try await eventually("target read completed") { !view.editPreparing }
        composer().apply(to: scroll)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(view.editingMessageID, "old", "Preparation still completes")
        XCTAssertEqual(view.composerFocusRequest, focusRequest)
        XCTAssertTrue(window.firstResponder === responder, "Typing must remain in search")
    }
}
