import XCTest
import SwiftUI
@testable import PiApp

final class ReportNavigationTests: XCTestCase {
    @MainActor private func model() async throws -> (WorkspaceModel, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("report-navigation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var profile = ProfileRecord(); profile.baseUrl = "https://fixture.invalid"; profile.modelId = "fixture"
        var configuration = VaultConfiguration()
        configuration.workspaces = [WorkspaceRecord(id: "w", path: root.path, trusted: true)]
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "fixture-key")]
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "main", workspaceID: "w", title: "Main", path: nil, profileID: profile.id)
        let main = SessionDisplay(id: chat.id), side = SessionDisplay(id: "side")
        main.draft = "main unsent draft"; side.draft = "side unsent draft"
        main.messages = [TranscriptMessage(id: "u1", role: "user", text: "Keep this transcript")]
        side.messages = [TranscriptMessage(id: "u2", role: "user", text: "Keep this side")]
        model.chats = [chat]; model.selectedID = chat.id; model.selected = main
        model.selectedWorkspaceID = "w"; model.profileChoice = profile.id; model.focusedSessionID = chat.id
        model.displays = [main.id: main, side.id: side]
        model.sides[chat.id] = SideRecord(id: side.id, parentID: chat.id, workspaceID: "w", profileID: profile.id, title: "Side")
        return (model, root)
    }

    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    @MainActor private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Native report navigation did not settle")
    }

    @MainActor func testReportResignsNativeFocusAndPreservesMountedConversationSurfaces() async throws {
        let (model, _) = try await model()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted
        defer {
            model.report.suspend(); window.contentView = nil; window.close()
        }
        hosted.layoutSubtreeIfNeeded()
        try await waitFor { self.descendants(ComposerTextView.self, in: hosted).count == 2 && self.descendants(TranscriptSurfaceMarker.self, in: hosted).count == 2 }
        let composers = descendants(ComposerTextView.self, in: hosted)
        let transcripts = descendants(TranscriptSurfaceMarker.self, in: hosted).compactMap(\.enclosingScrollView)
        XCTAssertEqual(transcripts.count, 2, "each conversation pane draws its own native transcript")
        let editor = try XCTUnwrap(composers.first { $0.accessibilityLabel() == "Main message composer" })
        let surfaceIDs = Set((composers as [NSView] + transcripts as [NSView]).map(ObjectIdentifier.init))
        let main = try XCTUnwrap(model.selected), side = try XCTUnwrap(model.displays["side"])
        editor.setSelectedRange(NSRange(location: 5, length: 6))
        XCTAssertTrue(window.makeFirstResponder(editor))
        let selectedRange = editor.selectedRange(), undoAvailable = editor.undoManager?.canUndo
        main.state = "running"; main.queueCount = 1; side.state = "running"

        model.openReport()
        try await waitFor { composers.allSatisfy(\.isHidden) && window.firstResponder is ConversationPageVisibilityView }
        XCTAssertTrue(transcripts.allSatisfy(\.isHidden), "Reports must also suspend native transcript preparation")
        XCTAssertFalse(model.conversationCommandsEnabled)
        XCTAssertEqual(editor.string, "main unsent draft"); XCTAssertEqual(editor.selectedRange(), selectedRange)
        XCTAssertEqual(side.draft, "side unsent draft"); XCTAssertEqual(main.state, "running"); XCTAssertEqual(main.queueCount, 1); XCTAssertEqual(side.state, "running")
        model.send(); model.send(steer: true); editor.send?()
        XCTAssertFalse(main.loading, "Neither global Send nor a stale native composer callback can submit a hidden draft")
        XCTAssertFalse(side.loading); XCTAssertTrue(model.hosts.isEmpty)
        let documents = transcripts.compactMap { $0.documentView as? TranscriptNativeDocument }
        let measurementsBefore = documents.flatMap(\.retainedRows).reduce(0) { $0 + $1.measurementCount }
        main.messages.append(TranscriptMessage(id: "a1", role: "assistant", text: "Streaming continues while Report is open"))
        for _ in 0..<4 { await Task.yield(); hosted.layoutSubtreeIfNeeded() }
        XCTAssertEqual(documents.flatMap(\.retainedRows).reduce(0) { $0 + $1.measurementCount }, measurementsBefore,
                       "A covered transcript must defer native sizing while still adopting model updates")

        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        window.firstResponder?.keyDown(with: escape)
        try await waitFor { model.page == .chats && composers.allSatisfy { !$0.isHidden } }
        XCTAssertTrue(transcripts.allSatisfy { !$0.isHidden })
        let current = descendants(ComposerTextView.self, in: hosted) as [NSView] + descendants(TranscriptSurfaceMarker.self, in: hosted).compactMap(\.enclosingScrollView) as [NSView]
        XCTAssertEqual(Set(current.map(ObjectIdentifier.init)), surfaceIDs, "Navigation must retain the actual NSTextView and transcript scroll view instances")
        XCTAssertTrue(window.firstResponder === editor); XCTAssertEqual(editor.selectedRange(), selectedRange); XCTAssertEqual(editor.undoManager?.canUndo, undoAvailable)
        XCTAssertEqual(main.messages.last?.id, "a1"); XCTAssertEqual(main.draft, "main unsent draft")
    }

    @MainActor func testSelectingAnExistingSideAndNewChatLeaveReport() async throws {
        let (model, _) = try await model()
        model.openReport()
        await model.selectSide("side")
        XCTAssertEqual(model.page, .chats); XCTAssertEqual(model.selectedID, "main"); XCTAssertEqual(model.focusedSessionID, "side")
        XCTAssertEqual(model.displays["main"]?.draft, "main unsent draft"); XCTAssertEqual(model.displays["side"]?.draft, "side unsent draft")
        model.showDashboard = true; XCTAssertEqual(model.page, .report)
        model.toggleReport(); XCTAssertEqual(model.page, .chats)
        model.openReport(); model.newChat()
        XCTAssertEqual(model.page, .chats)
        try await waitFor { model.chats.count == 2 && model.selectedID != "main" }
        XCTAssertEqual(model.displays["main"]?.draft, "main unsent draft")
    }

    @MainActor func testGlobalSendCannotResendAnEditHiddenByReport() async throws {
        let (model, _) = try await model()
        let main = try XCTUnwrap(model.selected)
        main.editingMessageID = "u1"; main.draftBeforeEdit = DraftRecord(id: main.id, text: "original draft")
        model.openReport(); model.send(); model.send(steer: true)
        XCTAssertFalse(main.loading); XCTAssertEqual(main.editingMessageID, "u1")
        XCTAssertEqual(main.draftBeforeEdit?.text, "original draft"); XCTAssertTrue(model.hosts.isEmpty)
        let intents = try await model.store?.list(CommandIntent.self, kind: "pending:main")
        XCTAssertEqual(intents, [])
    }
}
