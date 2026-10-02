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
        /// Answers the queued-edit commands as the helper does.
        let edits = FakeQueueEdits()
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
            model.queueEditOperation = edits.handler(session)
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


/// The helper's queued-edit hold, for panes without a helper: Begin takes
/// the hold and returns the row's text, Save writes it into the row, Cancel
/// and Remove let go; each answer can be held back or replaced by a failure.
@MainActor final class FakeQueueEdits {
    struct Hold { let editID: String, turnID: String }
    private(set) var hold: Hold?
    private(set) var calls: [(method: String, params: [String: WireValue])] = []
    private(set) var outcomes: [String: String] = [:]
    private(set) var savedDigests: [String: String] = [:]
    var revision = 0
    /// Held back until opened, per method.
    var gates: [String: AsyncGate] = [:]
    /// Thrown once, per method, instead of answering.
    var failures: [String: Error] = [:]
    /// How many status questions go unanswered, one by one.
    var unansweredStatuses = 0
    /// Done, then answered with no reply, once, per method: a lost answer.
    var lostReplies: Set<String> = []
    /// Whole texts for rows whose snapshot text is a preview.
    var wholeTexts: [String: String] = [:]
    func count(_ method: String) -> Int { calls.filter { $0.method == method }.count }
    func handler(_ session: SessionDisplay) -> (String, String, [String: WireValue]) async throws -> [String: WireValue] {
        { [weak self, weak session] method, _, params in
            guard let self, let session else { throw HostError.failure("gone") }
            return try await self.answer(method, params, session)
        }
    }
    private func answer(_ method: String, _ params: [String: WireValue], _ session: SessionDisplay) async throws -> [String: WireValue] {
        calls.append((method, params))
        if let gate = gates[method] { await gate.wait() }
        if let failure = failures.removeValue(forKey: method) { throw failure }
        if method == "queue.edit.status", unansweredStatuses > 0 { unansweredStatuses -= 1; throw HostError.failure("No answer") }
        let reply = try perform(method, params, session)
        if lostReplies.remove(method) != nil { throw HostError.failure("The helper's answer was lost.") }
        return reply
    }
    private func perform(_ method: String, _ params: [String: WireValue], _ session: SessionDisplay) throws -> [String: WireValue] {
        let editID = params["editId"]?.string ?? ""
        switch method {
        case "queue.edit.begin":
            let turnID = params["turnId"]?.string ?? ""
            if let hold, hold.editID != editID { throw HostError.rejected("queue_edit_busy", "Another queued message is being edited") }
            if let outcome = outcomes[editID] { throw HostError.rejected("queue_edit_" + outcome, "resolved") }
            guard let row = session.queue.first(where: { $0["turnId"]?.string == turnID }) else { throw HostError.rejected("queue_missing", "gone") }
            if hold == nil { revision += 1 }
            hold = Hold(editID: editID, turnID: turnID)
            var text = row["text"]?.string ?? ""
            if row["kind"]?.string == "steering", text.hasPrefix("[Steering] ") { text = String(text.dropFirst("[Steering] ".count)) }
            return ["editId": .string(editID), "turnId": .string(turnID), "text": .string(wholeTexts[turnID] ?? text), "revision": .number(Double(revision))]
        case "queue.edit.save", "queue.edit.cancel", "queue.edit.remove":
            let outcome = method == "queue.edit.save" ? "saved" : method == "queue.edit.cancel" ? "cancelled" : "removed"
            if let done = outcomes[editID] { if done == outcome { return ["accepted": .bool(true), "revision": .number(Double(revision))] }; throw HostError.rejected("queue_edit_" + done, "resolved") }
            guard let hold, hold.editID == editID else {
                // A Cancel for an edit never granted is remembered, as the helper does.
                if outcome == "cancelled" { outcomes[editID] = "cancelled"; revision += 1; return ["accepted": .bool(true), "outcome": .string("cancelled"), "revision": .number(Double(revision))] }
                throw HostError.rejected("queue_edit_missing", "That queued edit is no longer open")
            }
            if outcome == "saved", let text = params["text"]?.string, let index = session.queue.firstIndex(where: { $0["turnId"]?.string == hold.turnID }) {
                session.queue[index]["text"] = .string(text); savedDigests[editID] = WorkspaceModel.textDigest(text)
            }
            if outcome == "removed" { session.queue.removeAll { $0["turnId"]?.string == hold.turnID } }
            self.hold = nil; outcomes[editID] = outcome; revision += 1
            return ["accepted": .bool(true), "outcome": .string(outcome), "turnId": .string(hold.turnID), "revision": .number(Double(revision))]
        case "queue.reorder":
            let order = params["turnIds"]?.array?.compactMap(\.string) ?? []
            let followUps = session.queue.filter { $0["kind"]?.string != "steering" }
            guard Set(order) == Set(followUps.compactMap { $0["turnId"]?.string }), order.count == followUps.count else {
                throw HostError.rejected("queue_order", "The new order must list every pending follow-up exactly once")
            }
            let byID = Dictionary(uniqueKeysWithValues: followUps.compactMap { row in row["turnId"]?.string.map { ($0, row) } })
            session.queue = session.queue.filter { $0["kind"]?.string == "steering" } + order.compactMap { byID[$0] }
            return ["accepted": .bool(true)]
        case "queue.edit.status":
            if let hold, hold.editID == editID {
                let text = session.queue.first { $0["turnId"]?.string == hold.turnID }?["text"]?.string ?? ""
                return ["state": .string("active"), "editId": .string(editID), "turnId": .string(hold.turnID), "text": .string(text), "revision": .number(Double(revision))]
            }
            var status: [String: WireValue] = ["state": .string(outcomes[editID] ?? "unknown"), "editId": .string(editID), "revision": .number(Double(revision))]
            if let digest = savedDigests[editID] { status["textDigest"] = .string(digest) }
            return status
        default: throw HostError.rejected("unknown", method)
        }
    }
}
