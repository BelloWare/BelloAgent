import AppKit
import SwiftUI
import XCTest
@testable import PiApp

final class WorkspaceMotionTests: XCTestCase {
    @MainActor private final class MotionState: ObservableObject {
        @Published var revision = 0
        var observations: [String: (revision: Int, animated: Bool)] = [:]
    }

    private struct TransactionProbe: NSViewRepresentable {
        let name: String
        let revision: Int
        let state: MotionState
        func makeNSView(context: Context) -> NSView { NSView() }
        func updateNSView(_ view: NSView, context: Context) {
            state.observations[name] = (revision, context.transaction.animation != nil)
        }
    }

    private struct MotionFixture: View {
        @ObservedObject var state: MotionState
        let reduceMotion: Bool
        var body: some View {
            VStack {
                TransactionProbe(name: "native", revision: state.revision, state: state).piStableLayout(reduceMotion: reduceMotion)
                TransactionProbe(name: "feedback", revision: state.revision, state: state)
                    .animation(PiMotion.quick, value: state.revision)
                    .piStableLayout(reduceMotion: reduceMotion)
            }.animation(.linear(duration: 1), value: state.revision)
        }
    }

    @MainActor private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The native workspace did not settle")
    }

    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    @MainActor private func assertMotionBoundary(reduceMotion: Bool) async throws {
        let state = MotionState()
        let hosted = NSHostingView(rootView: MotionFixture(state: state, reduceMotion: reduceMotion))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosted
        defer { window.contentView = nil; window.close() }
        hosted.layoutSubtreeIfNeeded()
        try await waitFor { state.observations.count == 2 }
        state.revision = 1
        try await waitFor {
            hosted.layoutSubtreeIfNeeded()
            return state.observations.values.allSatisfy { $0.revision == 1 }
        }
        XCTAssertEqual(state.observations["native"]?.animated, false, "A sibling's transition must not interpolate native editor or scroll geometry")
        XCTAssertEqual(state.observations["feedback"]?.animated, !reduceMotion, "Ordinary control feedback remains local; Reduce Motion removes it")
    }

    @MainActor func testNativeLayoutRejectsParentAnimationWhileKeepingLocalFeedback() async throws {
        try await assertMotionBoundary(reduceMotion: false)
    }

    @MainActor func testReduceMotionRemovesBothInheritedAndLocalFeedbackAnimation() async throws {
        try await assertMotionBoundary(reduceMotion: true)
    }

    @MainActor func testChatReplacementDoesNotRetainAnOutgoingPaneOrMoveTheNewComposerOffscreen() async throws {
        let root = URL(fileURLWithPath: scratchBase())
            .appendingPathComponent("workspace-motion-" + UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        addTeardownBlock { @MainActor in
            // Dismantling the hosted view can enqueue a final draft/anchor or
            // read-state write. Drain those before closing and unlinking SQLite.
            model.shutdown()
            try? await model.flushDrafts()
            await model.flushReadStates(); await model.flushProjectSidebarState()
            try? await model.traces.close(); await model.store?.close()
            try? FileManager.default.removeItem(at: root)
        }
        try await model.reloadConfiguration()
        var profile = ProfileRecord(); profile.modelId = "fixture"; profile.baseUrl = "https://fixture.invalid"
        let project = WorkspaceRecord(id: "motion-project", path: root.path, trusted: true)
        let chats = ["one", "two"].map { ChatRecord(id: $0, workspaceID: project.id, title: $0, path: nil, profileID: profile.id) }
        let sessions = chats.map { chat in
            let session = SessionDisplay(id: chat.id)
            session.draft = "Unsent draft for " + chat.id
            session.messages = [TranscriptMessage(id: chat.id + "-user", role: "user", text: "Keep the conversation visible."), TranscriptMessage(id: chat.id + "-answer", role: "assistant", text: "A retained answer.")]
            return session
        }
        model.profiles = [profile]; model.workspaces = [project]; model.chats = chats
        model.displays = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        model.selectedID = chats[0].id; model.selected = sessions[0]; model.focusedSessionID = chats[0].id
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosted
        defer { window.contentView = nil; window.close() }
        try await waitFor {
            hosted.layoutSubtreeIfNeeded()
            return (self.descendants(ComposerTextView.self, in: hosted).first?.enclosingScrollView?.frame.width ?? 0) > 500
        }
        let initial = try XCTUnwrap(descendants(ComposerTextView.self, in: hosted).first?.enclosingScrollView)
        let fullFrame = initial.convert(initial.bounds, to: hosted)

        model.selectedID = chats[1].id; model.selected = sessions[1]; model.focusedSessionID = chats[1].id
        try await waitFor {
            hosted.layoutSubtreeIfNeeded()
            return self.descendants(ComposerTextView.self, in: hosted).contains { $0.sessionID == chats[1].id }
        }
        let editors = descendants(ComposerTextView.self, in: hosted)
        XCTAssertEqual(editors.map(\.sessionID), [chats[1].id], "A replaced chat must not coexist in the split HStack while its removal animation runs")
        let editor = try XCTUnwrap(editors.first), scroll = try XCTUnwrap(editor.enclosingScrollView)
        XCTAssertEqual(scroll.convert(scroll.bounds, to: hosted).minX, fullFrame.minX, accuracy: 1, "The incoming full-width pane must start at its final position")
        XCTAssertEqual(scroll.frame.width, fullFrame.width, accuracy: 1)
        XCTAssertEqual(editor.string, sessions[1].draft)

        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 2, length: 5))
        let selectedRange = editor.selectedRange()
        let side = SessionDisplay(id: "side"); side.draft = "Unsent side draft"
        model.displays[side.id] = side
        model.sides[chats[1].id] = SideRecord(id: side.id, parentID: chats[1].id, workspaceID: project.id, profileID: profile.id, title: "Side")
        try await waitFor {
            hosted.layoutSubtreeIfNeeded()
            return self.descendants(ComposerTextView.self, in: hosted).count == 2
        }
        XCTAssertTrue(descendants(ComposerTextView.self, in: hosted).contains { $0 === editor }, "Opening a side keeps the main native editor instance")
        XCTAssertTrue(window.firstResponder === editor); XCTAssertEqual(editor.selectedRange(), selectedRange)

        sessions[1].queue = [["turnId": .string("queued"), "text": .string("Follow-up")]]
        sessions[1].loading = true; model.error = "A background operation could not be saved."
        model.sides.removeValue(forKey: chats[1].id)
        try await waitFor {
            hosted.layoutSubtreeIfNeeded()
            return self.descendants(ComposerTextView.self, in: hosted).count == 1 && abs(scroll.frame.width - fullFrame.width) < 1
        }
        XCTAssertTrue(descendants(ComposerTextView.self, in: hosted).first === editor)
        XCTAssertTrue(window.firstResponder === editor); XCTAssertEqual(editor.selectedRange(), selectedRange)
        XCTAssertEqual(editor.string, "Unsent draft for two")
        XCTAssertEqual(side.draft, "Unsent side draft")
    }
}
