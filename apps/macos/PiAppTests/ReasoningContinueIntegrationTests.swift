import AppKit
import SwiftUI
import XCTest
@testable import PiApp

/// "Continue without earlier reasoning", the whole way in the built app
/// (0.1.138): the app's model, the real helper and a loopback gateway whose
/// providers refuse each other's reasoning as a LiteLLM gateway relays it
/// (`fixtures/native/reasoning_refusal_gateway.py`, the helper tests' own).
/// The owner's steps: a reply from one model, a message to another, the
/// refusal's notice in the transcript, and its one button pressed in the row.
///
/// Why: the first on-screen gate of 0.1.138 found the button dead. The action
/// was not forwarded from a row to the pane, and nothing had ever pressed it
/// in the app; the live runs drove the helper's command.
@MainActor final class ReasoningChat {
    struct Reply { let method: String; let params: [String: WireValue] }
    let root: URL, stateRoot: URL
    private let gateway: Process, configuration: Data
    private(set) var model: WorkspaceModel!, session: SessionDisplay!, window: NSWindow!, hosted: NSHostingView<ConversationPane>!
    let chatID = UUID().uuidString
    var replies: [Reply] = []

    init(mode: String) async throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let script = repository.appendingPathComponent("fixtures/native/reasoning_refusal_gateway.py")
        root = scratchRoot("reasoning-continue"); stateRoot = root.appendingPathComponent("app-state")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        gateway = Process()
        gateway.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        gateway.arguments = ["-u", script.path, root.path, mode]
        gateway.standardOutput = FileHandle.nullDevice; gateway.standardError = FileHandle.nullDevice
        gateway.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": root.path]
        try gateway.run()
        let ready = root.appendingPathComponent("ready.json")
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: ready.path) { try await Task.sleep(for: .milliseconds(10)) }
        let port = try XCTUnwrap(try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: ready))["port"])
        let workspace = WorkspaceRecord(id: "reasoning-project", path: root.path, trusted: true)
        var profile = ProfileRecord()
        profile.api = "openai-responses"; profile.baseUrl = "http://127.0.0.1:\(port)/v1"; profile.modelId = "fixture-model"
        profile.name = "Refusing gateway"; profile.contextWindow = 100_000; profile.maxOutputTokens = 4_096
        // The default since 0.1.138: reasoning is sent back.
        profile.advancedJSON = #"{"reasoning":true,"thinkingLevel":"low"}"#
        var saved = VaultConfiguration()
        saved.workspaces = [workspace]
        saved.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-loopback-key")]
        saved.automaticUpdateChecks = false
        saved.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("codex").path), "skills": .bool(false)])
        configuration = try JSONEncoder().encode(saved)
        try await launch()
        let chat = ChatRecord(id: chatID, workspaceID: workspace.id, title: "Reasoning", path: nil, profileID: profile.id)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        try await show()
        let host = try await model.open(chat)
        host.requestObserver = { [weak self] method, params, _ in self?.replies.append(Reply(method: method, params: params)) }
        model.refresh(chatID)
    }
    /// The app's model over the saved state, as a launch builds it.
    private func launch() async throws {
        model = WorkspaceModel(stateRoot: stateRoot, vault: ConfigurationVault(storage: MemoryVaultStorage(configuration)))
        await model.restore()
        model.selectedWorkspaceID = "reasoning-project"
    }
    /// The chat selected and drawn in a window, as the owner has it.
    private func show() async throws {
        let chat = try XCTUnwrap(model.record(chatID))
        await model.select(chatID)
        session = try XCTUnwrap(model.displays[chatID])
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted = NSHostingView(rootView: ConversationPane(model: model, session: session, chat: chat, paneWidth: 1000))
        window.contentView = hosted; window.makeKeyAndOrderFront(nil)
    }
    /// Quit and reopen: the helpers stop, the model and its window go, and a
    /// new model reads the same state. The chat is shown from its journal;
    /// nothing here opens its helper.
    func relaunch() async throws {
        await close(stopGateway: false)
        replies = []
        try await launch()
        try await show()
    }
    func draw() { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
    /// The chat's model is chosen and saved, as the picker saves it, so a
    /// relaunch reads the same choice; then the message is sent.
    func send(_ text: String, model name: String) async throws {
        if let index = model.chats.firstIndex(where: { $0.id == chatID }), model.chats[index].model != name {
            model.chats[index].model = name
            try await model.store?.put(model.chats[index], kind: "chat", id: chatID)
        }
        session.draft = text; model.send(sessionID: chatID)
    }
    func waitUntil(_ what: String, seconds: Double = 45, file: StaticString = #filePath, line: UInt = #line, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await condition() { draw(); return }
            draw(); try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out: \(what) (state \(session.state), failure \(session.failureCode ?? "none"): “\(session.failureMessage ?? "")”, error \(model.error ?? "none"))", file: file, line: line)
        throw CancellationError()
    }
    var replyTexts: [String] { session.messages.filter { $0.role == "assistant" }.map(\.text).filter { !$0.isEmpty } }
    var refused: Bool { session.failureCode == SessionDisplay.reasoningRejectedCode && session.presentedMessages.contains { $0.failureCode == SessionDisplay.reasoningRejectedCode } }
    var quietLines: [String] { session.presentedMessages.filter { $0.kind == "notice" }.map(\.text) }
    /// Sends and waits for the reply that makes `count` answers.
    func ask(_ text: String, model name: String, answers count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await send(text, model: name)
        try await waitUntil("“\(text)” answered", file: file, line: line) { !session.loading && !session.busy && session.failureCode == nil && replyTexts.count == count }
    }
    /// Sends and waits for the refusal's notice.
    func askAndBeRefused(_ text: String, model name: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await send(text, model: name)
        try await waitUntil("“\(text)” refused", file: file, line: line) { !session.busy && refused }
    }
    /// The notice's row as the transcript draws it, and its one button.
    func notice(file: StaticString = #filePath, line: UInt = #line) async throws -> (row: TranscriptNativeFailureRow, button: TranscriptPillButton) {
        var row: TranscriptNativeFailureRow?, button: TranscriptPillButton?
        try await waitUntil("the transcript draws the notice with its button", file: file, line: line) {
            row = ConversationPaneTests.views(TranscriptNativeFailureRow.self, in: hosted).first { $0.accessibilityIdentifier() == "reasoning-refused-notice" }
            button = ConversationPaneTests.views(TranscriptPillButton.self, in: hosted).first { $0.accessibilityIdentifier() == "continue-without-reasoning" }
            return row != nil && button != nil
        }
        return (try XCTUnwrap(row), try XCTUnwrap(button))
    }
    /// The request bodies the gateway received, in order.
    func requests() throws -> [[String: Any]] {
        let file = root.appendingPathComponent("requests.jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
    /// The encrypted reasoning a request carried, by the model that made it.
    static func reasoning(_ request: [String: Any]) -> [String] {
        (request["input"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "reasoning" }.compactMap { $0["encrypted_content"] as? String }
    }
    func journal() throws -> String {
        try String(contentsOfFile: try XCTUnwrap(model.record(chatID)?.path), encoding: .utf8)
    }
    func close(stopGateway: Bool = true) async {
        for host in model.hosts.values { host.requestObserver = nil; try? await host.shutdownAndWait() }
        try? await model.flushDrafts()
        try? await model.traces.close(); await model.store?.close()
        model.shutdown(); window.contentView = nil; window.close()
        if stopGateway {
            if gateway.isRunning { gateway.terminate() }
            try? FileManager.default.removeItem(at: root)
        }
    }
}

final class ReasoningContinueIntegrationTests: XCTestCase, SerialTestLane {
    /// One model answers with reasoning; the next message goes to another
    /// model, whose provider refuses that reasoning. The notice is in the
    /// transcript with its button; pressed in the row, the question's answer
    /// reaches the helper, the request goes again without the reasoning, the
    /// reply arrives, and the notice has become a quiet line. Once with the
    /// OpenAI organization refusal over HTTP 400, once with the Gemini
    /// bridge's failure inside a stream.
    @MainActor func testTheNoticesButtonPressedInTheRowSendsTheRequestAgainWithoutTheReasoning() async throws {
        for mode in ["http", "sse"] {
            let chat = try await ReasoningChat(mode: mode)
            do {
                try await chat.ask("Hello", model: "fixture-model", answers: 1)
                try await chat.askAndBeRefused("Next", model: "other-model")
                let question = try XCTUnwrap(chat.session.reasoningRejection, mode)
                XCTAssertEqual(question.title, "other-model can't use the earlier reasoning", mode)
                let (row, button) = try await chat.notice()
                XCTAssertEqual(row.accessibilityLabel()?.hasPrefix(question.title), true, mode)
                XCTAssertFalse(chat.replies.contains { $0.method == "turn.retry" }, "Nothing was sent again before the owner said so")
                // The owner presses the notice's button.
                XCTAssertTrue(button.accessibilityPerformPress(), mode)
                try await chat.waitUntil("\(mode): the request went again and was answered") {
                    !chat.session.loading && !chat.session.busy && chat.session.failureCode == nil && chat.replyTexts.count == 2
                }
                let retries = chat.replies.filter { $0.method == "turn.retry" }
                XCTAssertEqual(retries.count, 1, mode)
                XCTAssertEqual(retries.first?.params["withoutEarlierReasoning"]?.object?["rejection"]?.string, question.id, "\(mode): the answer names the question it was asked")
                XCTAssertEqual(retries.first?.params["model"]?.string, "other-model", mode)
                let sent = try chat.requests()
                XCTAssertEqual(sent.map { $0["model"] as? String }, ["fixture-model", "other-model", "other-model"], mode)
                XCTAssertEqual(ReasoningChat.reasoning(sent[1]), ["ENC-fixture-model"], "\(mode): what was refused")
                XCTAssertEqual(ReasoningChat.reasoning(sent[2]), [], "\(mode): the request the button sent carries none of it")
                XCTAssertEqual(chat.replyTexts.last, "Answer 2.", mode)
                XCTAssertEqual(chat.quietLines, ["Continued without earlier reasoning · other-model"], mode)
                XCTAssertNil(chat.session.reasoningRejection, mode); XCTAssertFalse(chat.refused, mode)
                XCTAssertEqual(chat.session.state, "idle", mode)
                chat.draw()
                XCTAssertTrue(ConversationPaneTests.views(TranscriptNativeFailureRow.self, in: chat.hosted).isEmpty, "\(mode): the notice is gone from the transcript")
                // Nothing was deleted: back on the first model, its request
                // carries its own reasoning again and the second model's new
                // reasoning. This gateway's first provider refuses the
                // latter in turn, and that is a question of its own (the
                // known round trip between two providers that refuse each other).
                try await chat.askAndBeRefused("Back", model: "fixture-model")
                XCTAssertEqual(ReasoningChat.reasoning(try XCTUnwrap(try chat.requests().last)), ["ENC-fixture-model", "ENC-other-model"], "\(mode): the first model is still sent everything")
                XCTAssertEqual(chat.session.reasoningRejection?.title, "fixture-model can't use the earlier reasoning", mode)
                XCTAssertNotEqual(chat.session.reasoningRejection?.id, question.id, mode)
            } catch { await chat.close(); throw error }
            await chat.close()
        }
    }

    /// The app is quit while the notice stands and opened again: the chat is
    /// read from its journal before the helper has it. The notice is there
    /// with its button, and pressing it goes the same way: the question is
    /// fetched from the helper and answered.
    @MainActor func testAfterARelaunchTheNoticeIsThereAndItsButtonStillAnswers() async throws {
        let chat = try await ReasoningChat(mode: "http")
        do {
            try await chat.ask("Hello", model: "fixture-model", answers: 1)
            try await chat.askAndBeRefused("Next", model: "other-model")
            let asked = try XCTUnwrap(chat.session.reasoningRejection?.id)
            try await chat.relaunch()
            try await chat.waitUntil("the reopened chat shows the notice") { chat.refused }
            print("REASONING-RELAUNCH question held by the app before the press: \(chat.session.reasoningRejection?.id ?? "none (read from the journal)")")
            let (_, button) = try await chat.notice()
            XCTAssertEqual(try chat.requests().count, 2, "Reopening sent nothing")
            XCTAssertTrue(button.accessibilityPerformPress())
            try await chat.waitUntil("the request went again and was answered") {
                !chat.session.loading && !chat.session.busy && chat.session.failureCode == nil && chat.replyTexts.count == 2
            }
            let sent = try chat.requests()
            XCTAssertEqual(sent.map { $0["model"] as? String }, ["fixture-model", "other-model", "other-model"], "The retry goes to the model the chat was on")
            XCTAssertEqual(ReasoningChat.reasoning(sent[2]), [], "without the reasoning its provider refused")
            XCTAssertEqual(chat.replyTexts.last, "Answer 2.")
            XCTAssertEqual(chat.quietLines, ["Continued without earlier reasoning · other-model"])
            let journal = try chat.journal()
            XCTAssertTrue(journal.contains("pi-app.reasoning-withheld.v1") && journal.contains(asked), "The answer is in the journal under the question asked before the relaunch")
            XCTAssertEqual(chat.session.state, "idle")
        } catch { await chat.close(); throw error }
        await chat.close()
    }

    /// The other model's provider takes no earlier reasoning at all. The
    /// first Continue covers the first model's; later the request the button
    /// sends is refused again for the model's own, and goes once more without
    /// it, with no second question: one press, and a second quiet line.
    @MainActor func testOnePressCoversTheModelsOwnReasoningWhenTheRetryIsRefusedToo() async throws {
        let chat = try await ReasoningChat(mode: "strict")
        do {
            try await chat.ask("Hello", model: "fixture-model", answers: 1)
            try await chat.askAndBeRefused("Next", model: "other-model")
            let pressed = try await chat.notice().button.accessibilityPerformPress()
            XCTAssertTrue(pressed)
            try await chat.waitUntil("the first Continue was answered") { !chat.session.busy && chat.session.failureCode == nil && chat.replyTexts.count == 2 }
            try await chat.ask("Back", model: "fixture-model", answers: 3)
            try await chat.askAndBeRefused("And again", model: "other-model")
            let before = try chat.requests().count
            let again = try await chat.notice().button.accessibilityPerformPress()
            XCTAssertTrue(again)
            try await chat.waitUntil("the second Continue was answered") { !chat.session.busy && chat.session.failureCode == nil && chat.replyTexts.count == 4 }
            let sent = try chat.requests()
            XCTAssertEqual(sent.count, before + 2, "Refused once more, then accepted")
            XCTAssertEqual(ReasoningChat.reasoning(sent[before]), ["ENC-other-model"], "First without the others': its own stays in")
            XCTAssertEqual(ReasoningChat.reasoning(sent[before + 1]), [], "Then without its own")
            XCTAssertEqual(chat.replies.filter { $0.method == "turn.retry" }.count, 2, "One press, one answer each time")
            XCTAssertEqual(chat.quietLines, ["Continued without earlier reasoning · other-model", "Continued without earlier reasoning · other-model",
                                             "Continued without its own earlier reasoning too · other-model"])
            XCTAssertEqual(chat.session.state, "idle"); XCTAssertFalse(chat.refused)
        } catch { await chat.close(); throw error }
        await chat.close()
    }
}
