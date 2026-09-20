import XCTest
import SwiftUI
import AppKit
@testable import PiApp


/// The conversation pane as the user meets it: real `ConversationPane` and
/// `WorkspaceView` views in a real window, typed into through the native
/// editor, with the composer bar, the follow-up queue, the live turn bar and
/// the metrics footer all mounted. Every check here is something the reader
/// would see, not a model value.
/// A latch a test closes and opens, so a slow host answer can be observed
/// while it is still in flight.
actor AsyncGate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func open() { opened = true; for continuation in waiting { continuation.resume() }; waiting = [] }
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}

final class ConversationPaneTests: XCTestCase {

    // MARK: Fixture

    /// A seeded project and connection, so the pane renders its composer
    /// instead of the "project unavailable" footer once the vault is read.
    @MainActor static func workbench(root: URL, chats: [String], imageModel: Bool = false) throws -> (model: WorkspaceModel, workspace: WorkspaceRecord, profile: ProfileRecord, chats: [ChatRecord]) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = WorkspaceRecord(id: "pane-project", path: root.path, trusted: true)
        var profile = ProfileRecord()
        profile.name = "Pane connection"; profile.api = LiteLLMConfiguration.supportedAPI
        profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "pane-model"
        profile.contextWindow = 200_000; profile.maxOutputTokens = 32_000
        if imageModel { profile.advancedJSON = "{\"input\":[\"text\",\"image\"]}" }
        var configuration = VaultConfiguration()
        configuration.workspaces = [workspace]
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-pane-key")]
        let vault = ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration)))
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("app-state"), vault: vault)
        let records = chats.map { ChatRecord(id: "chat-" + $0, workspaceID: workspace.id, title: $0, path: nil, profileID: profile.id) }
        model.workspaces = [workspace]; model.profiles = [profile]; model.chats = records
        model.selectedWorkspaceID = workspace.id; model.profileChoice = profile.id
        return (model, workspace, profile, records)
    }

    /// One conversation pane hosted on its own.
    @MainActor final class Pane {
        let model: WorkspaceModel
        let session: SessionDisplay
        var chat: ChatRecord
        let window: NSWindow
        let hosted: NSHostingView<ConversationPane>
        private let root: URL

        init(messages: [TranscriptMessage] = [], width: CGFloat = 900, height: CGFloat = 700, imageModel: Bool = false) throws {
            let scratch = scratchBase()
            root = URL(fileURLWithPath: scratch).appendingPathComponent("conversation-pane-" + UUID().uuidString)
            let bench = try ConversationPaneTests.workbench(root: root, chats: ["pane"], imageModel: imageModel)
            model = bench.model; chat = bench.chats[0]
            session = SessionDisplay(id: chat.id)
            session.messages = messages
            model.displays[chat.id] = session; model.selectedID = chat.id; model.selected = session
            model.focusedSessionID = chat.id
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            hosted = NSHostingView(rootView: ConversationPane(model: model, session: session, chat: chat, paneWidth: width))
            window.contentView = hosted
            window.makeKeyAndOrderFront(nil)
            draw()
        }
        func draw() { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        func settle(_ turns: Int = 8) async {
            for _ in 0..<turns { draw(); await Task.yield(); try? await Task.sleep(for: .milliseconds(10)) }
            draw()
        }
        var editor: ComposerTextView? { ConversationPaneTests.views(ComposerTextView.self, in: hosted).first }
        var transcript: TranscriptPage? { ConversationPaneTests.views(TranscriptSurfaceMarker.self, in: hosted).first?.page }
        func close() {
            model.shutdown(); window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }
    /// Every view with its window-space frame, for geometry checks.
    @MainActor static func tree(_ view: NSView, depth: Int = 0) -> [(name: String, frame: CGRect, depth: Int)] {
        [(String(describing: Swift.type(of: view)), view.convert(view.bounds, to: nil), depth)]
            + view.subviews.flatMap { tree($0, depth: depth + 1) }
    }

    /// One keystroke through the real responder path.
    @MainActor func type(_ text: String, into editor: ComposerTextView, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: editor.window?.windowNumber ?? 0, context: nil,
                                     characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: keyCode)
        if let event { editor.keyDown(with: event) } else { editor.insertText(text, replacementRange: editor.selectedRange()) }
    }

    @MainActor func waitFor(_ what: String, seconds: Double = 20, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTFail(what, file: file, line: line)
    }

    private static let paragraph = "Some **bold** text with `code`, a [link](https://example.com) and a list:\n\n- one\n- two\n\n```swift\nfunc charge(_ order: Order) async throws -> Receipt { for attempt in 1...3 { } }\n```\n\n"

    @MainActor func longChat(rows: Int) -> [TranscriptMessage] {
        (0..<rows).map { index in
            var message = TranscriptMessage(id: "m\(index)", role: index % 2 == 0 ? "user" : "assistant",
                                            text: Self.paragraph + "Row \(index).", turn: "m\(index - index % 2)")
            message.at = Double(index) * 1000
            return message
        }
    }
}
