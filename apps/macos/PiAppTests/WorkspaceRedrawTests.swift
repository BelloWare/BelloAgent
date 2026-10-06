import XCTest
import SwiftUI
import AppKit
import Combine
@testable import PiApp

/// A change to the workspace redraws what shows it, not the whole window.
/// The transcript, its live bar and the footer's figures keep to their own
/// inputs: before, every change to the model — a notice, a selection
/// elsewhere, a sidebar fold — laid them out again, which was most of the
/// 5.8 ms a change cost in a Release build (3.2 ms after).
final class WorkspaceRedrawTests: XCTestCase {
    @MainActor private func window(_ model: WorkspaceModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WorkspaceRootView(model: model)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// SwiftUI takes a change on its next pass, not in the turn that made
    /// it: the change is given that pass, then the window is drawn.
    @MainActor private func draw(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(15))
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    }

    @MainActor func testAChangeElsewhereLeavesTheTranscriptAndItsFiguresAlone() async throws {
        let root = scratchRoot("workspace-redraw")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceRecord(id: "redraw-project", path: project.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "redraw-profile"; profile.name = "Redraw"; profile.baseUrl = "http://127.0.0.1:9/v1"; profile.modelId = "redraw-model"
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        let saved = profile
        _ = try await vault.update(expectedRevision: 0) { $0.workspaces = [workspace]; $0.profiles = [VaultProfile(profile: saved, apiKey: "synthetic-redraw-key")]; $0.automaticUpdateChecks = false }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        await model.restore()
        let chat = ChatRecord(id: "redraw-chat", workspaceID: workspace.id, title: "Redraw", path: nil, profileID: profile.id)
        let other = ChatRecord(id: "redraw-other", workspaceID: workspace.id, title: "Other", path: nil, profileID: profile.id)
        model.chats = [chat, other]
        try await model.store?.put(chat, kind: "chat", id: chat.id); try await model.store?.put(other, kind: "chat", id: other.id)
        await model.select(chat.id)
        let display = try XCTUnwrap(model.displays[chat.id])
        let window = window(model)
        addTeardownBlock { @MainActor in
            RedrawCounter.recording = false; RedrawCounter.reset()
            window.contentView = nil; window.close(); model.report.suspend(); model.shutdown(); try? await model.traces.close(); await model.store?.close()
        }
        // Whatever the selection still had in flight lands before counting.
        let deadline = Date().addingTimeInterval(10)
        while display.historyState.loading && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        for _ in 0..<5 { try await draw(window); try await Task.sleep(for: .milliseconds(60)) }

        // Whatever the chat itself changes meanwhile is counted too, and
        // allowed for: it would draw both, rightly.
        var chatChanges = 0, figureChanges = 0
        var watching: Set<AnyCancellable> = []
        display.objectWillChange.sink { _ in chatChanges += 1 }.store(in: &watching)
        display.footer.objectWillChange.sink { _ in figureChanges += 1 }.store(in: &watching)
        RedrawCounter.reset(); RedrawCounter.recording = true
        for index in 0..<10 {
            model.objectWillChange.send(); try await draw(window)
            model.error = index.isMultiple(of: 2) ? "A notice elsewhere" : nil; try await draw(window)
        }
        model.error = nil; try await draw(window)
        model.setSidebarSideFolded(other.id, folded: true); try await draw(window)
        XCTAssertLessThanOrEqual(RedrawCounter.counts["transcript", default: 0], chatChanges,
                                 "The transcript is not drawn for a change it does not show (the chat itself changed \(chatChanges) times)")
        XCTAssertLessThanOrEqual(RedrawCounter.counts["statsPills", default: 0], chatChanges + figureChanges,
                                 "The footer's figures are not drawn for a change they do not show (the chat and its figures changed \(chatChanges + figureChanges) times)")

        // What the chat itself changes still reaches both.
        RedrawCounter.reset()
        display.objectWillChange.send(); try await draw(window)
        XCTAssertGreaterThan(RedrawCounter.counts["transcript", default: 0], 0, "A change to the chat draws its transcript")
        XCTAssertGreaterThan(RedrawCounter.counts["statsPills", default: 0], 0, "A change to the chat draws its figures")
        // The live bar keeps to its own turn and run state, which that change
        // left as they were.
        XCTAssertEqual(RedrawCounter.counts["liveTurnBar", default: 0], 0, "The live bar is drawn only for its own turn")
        RedrawCounter.reset()
        display.footer.objectWillChange.send(); try await draw(window)
        XCTAssertGreaterThan(RedrawCounter.counts["statsPills", default: 0], 0, "A change to the chat's figures draws them")
        RedrawCounter.recording = false
        withExtendedLifetime(watching) {}
    }
}
