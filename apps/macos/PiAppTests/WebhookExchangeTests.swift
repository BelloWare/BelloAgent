import XCTest
@testable import PiApp

/// BUG-004 (review 2026-10-16): a completion webhook's request and reply are
/// the finished task's own, read from the chat's history, whatever the
/// transcript on screen holds: a chat left mid-stream (a background chat's
/// refresh carries no rows), an older page the reader scrolled back to, or
/// a next turn that started before the webhook was prepared.
final class WebhookExchangeTests: XCTestCase {
    private func taskSnapshot(_ state: String, active: [String: WireValue]? = nil, finished: [[String: WireValue]] = [], revision: Int) -> [String: WireValue] {
        var task: [String: WireValue] = ["version": .number(1), "epoch": .string("e1"), "timeline": .string("root"),
                                         "recent": .array(finished.map { .object($0) }),
                                         "completion": .object(["revision": .number(Double(revision)), "outcome": .string("completed")])]
        if let active { task["active"] = .object(active) }
        return ["state": .string(state), "queueCount": .number(0), "monitoring": .object(["epoch": .string("e1")]), "taskPresentation": .object(task)]
    }

    @MainActor func testACompletionWebhookDescribesItsOwnTurnFromTheChatsHistory() async throws {
        let receiver = try WebhookReceiver(); defer { receiver.stop() }
        let address = try await receiver.start()
        for scenario in ["switched away mid-stream", "older page resident", "next turn already started"] {
            receiver.answer([])
            let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("webhook-exchange-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
            let journal = try SearchJournal(root.appendingPathComponent("chat.jsonl"))
            func row(_ id: String, _ role: String, _ text: String, task: String) throws {
                let content: Any = role == "user" ? text : [["type": "text", "text": text]]
                try journal.message(id, role: role, content, extra: ["nativeTaskRoot": task])
            }
            try row("u0", "user", "Old request", task: "t0"); try row("a0", "assistant", "Old answer", task: "t0")
            try row("u1", "user", "Current request", task: "t1"); try row("a1", "assistant", "Working on it.", task: "t1")
            try row("a2", "assistant", "Final answer.", task: "t1")
            if scenario == "next turn already started" {
                try row("u2", "user", "Next request", task: "t2"); try row("a3", "assistant", "Next partial reply", task: "t2")
            }
            model.chats = [ChatRecord(id: "chat", workspaceID: "project", title: "Chat", path: journal.url.path, profileID: "fixture")]
            let display = SessionDisplay(id: "chat"); model.displays["chat"] = display
            func shown(_ id: String, _ role: String, _ text: String, streaming: Bool = false) -> TranscriptMessage {
                var message = TranscriptMessage(id: id, role: role, text: text); if streaming { message.state = "streaming" }; return message
            }
            switch scenario {
            case "switched away mid-stream":
                // The rows as the reader left them; the refresh that finished the run carried none.
                display.messages = [shown("u0", "user", "Old request"), shown("a0", "assistant", "Old answer"),
                                    shown("u1", "user", "Current request"), shown("a1", "assistant", "Working on", streaming: true)]
            case "older page resident":
                display.messages = [shown("u0", "user", "Old request"), shown("a0", "assistant", "Old answer")]
            default:
                display.messages = [shown("u0", "user", "Old request"), shown("a0", "assistant", "Old answer"), shown("u1", "user", "Current request")]
            }
            var settings = WebhookSettings(); settings.enabled = true; settings.url = address + "/hook"; settings.parameters = ""
            settings.body = #"{"request": "{{last_request}}", "reply": "{{last_reply}}"}"#
            model.configuration.webhook = settings
            XCTAssertTrue(model.sendsWebhook("chat"), scenario)

            let running: [String: WireValue] = ["rootID": .string("t1"), "executionID": .string("e1")]
            var finished = running; finished["outcome"] = .string("completed"); finished["lastSourceID"] = .string("a2")
            var older: [String: WireValue] = ["rootID": .string("t0"), "executionID": .string("e0"), "outcome": .string("completed"), "lastSourceID": .string("a0")]
            older["phase"] = .string("terminal")
            model.observeWebhookFinish(sessionID: "chat", snapshot: taskSnapshot("idle", finished: [older], revision: 1), baseline: true)
            model.observeWebhookFinish(sessionID: "chat", snapshot: taskSnapshot("running", active: running, finished: [older], revision: 1), baseline: false)
            model.observeWebhookFinish(sessionID: "chat", snapshot: taskSnapshot("idle", finished: [older, finished], revision: 2), baseline: false)
            try await eventually("\(scenario): the webhook was not sent", timeout: .seconds(20)) { receiver.requests.count == 1 && model.webhookTasks.isEmpty }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(receiver.requests[0].body.utf8)) as? [String: String], scenario)
            XCTAssertEqual(body, ["request": "Current request", "reply": "Working on it.\n\nFinal answer."], scenario)
            XCTAssertFalse(display.notice.contains("Webhook"), scenario)
            model.shutdown()
        }
    }

    /// A task longer than one history page (60 rows): its request is pages
    /// back from its last row, and a later turn may have pushed that row off
    /// the latest page too. Every reply of the task is read, and nothing else.
    @MainActor func testATaskLongerThanAPageIsReadWhole() async throws {
        for later in [0, 90] {
            let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("webhook-long-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
            defer { model.shutdown() }
            let journal = try SearchJournal(root.appendingPathComponent("chat.jsonl"))
            func row(_ id: String, _ role: String, _ text: String, task: String) throws {
                let content: Any = role == "user" ? text : [["type": "text", "text": text]]
                try journal.message(id, role: role, content, extra: ["nativeTaskRoot": task])
            }
            try row("u0", "user", "Old request", task: "t0"); try row("a0", "assistant", "Old answer", task: "t0")
            try row("u1", "user", "Long request", task: "t1")
            for step in 0..<130 { try row("s\(step)", "assistant", "Step \(step)", task: "t1") }
            for step in 0..<later { try row("n\(step)", step == 0 ? "user" : "assistant", "Later \(step)", task: "t2") }
            model.chats = [ChatRecord(id: "chat", workspaceID: "project", title: "Chat", path: journal.url.path, profileID: "fixture")]
            let display = SessionDisplay(id: "chat"); model.displays["chat"] = display
            display.messages = [TranscriptMessage(id: "u1", role: "user", text: "Long request")]
            var settings = WebhookSettings(); settings.enabled = true; settings.url = "http://127.0.0.1:1/no-send"; settings.parameters = ""
            let prepared = try await model.prepareWebhook(for: "chat", settings: settings, status: "completed", task: WebhookTask(rootID: "t1", lastSourceID: "s129"))
            XCTAssertEqual(prepared.context.lastRequest, "Long request", "later rows: \(later)")
            XCTAssertEqual(prepared.context.lastReply, (0..<130).map { "Step \($0)" }.joined(separator: "\n\n"), "later rows: \(later)")
        }
    }

    /// An edit or resend can replace the finished task's branch while the
    /// webhook is prepared: its last row is then in no history the reader
    /// can reach. The replacement's rows are never sent as its exchange; the
    /// rows on screen are used only when they hold the task.
    @MainActor func testAReplacedBranchNeverLendsItsRowsToTheExchange() async throws {
        for shown in [false, true] {
            let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("webhook-replaced-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
            defer { model.shutdown() }
            let journal = try SearchJournal(root.appendingPathComponent("chat.jsonl"))
            try journal.message("u2", role: "user", "Replacement request", extra: ["nativeTaskRoot": "t2"])
            try journal.message("a2", role: "assistant", [["type": "text", "text": "Replacement reply"]], extra: ["nativeTaskRoot": "t2"])
            model.chats = [ChatRecord(id: "chat", workspaceID: "project", title: "Chat", path: journal.url.path, profileID: "fixture")]
            let display = SessionDisplay(id: "chat"); model.displays["chat"] = display
            if shown {
                var request = TranscriptMessage(id: "u1", role: "user", text: "Original request"); request.taskRootID = "t1"
                var reply = TranscriptMessage(id: "a1", role: "assistant", text: "Original reply"); reply.taskRootID = "t1"
                display.messages = [request, reply]
            }
            var settings = WebhookSettings(); settings.enabled = true; settings.url = "http://127.0.0.1:1/no-send"; settings.parameters = ""
            let prepared = try await model.prepareWebhook(for: "chat", settings: settings, status: "completed", task: WebhookTask(rootID: "t1", lastSourceID: "a1"))
            XCTAssertEqual(prepared.context.lastRequest, shown ? "Original request" : "", "shown: \(shown)")
            XCTAssertEqual(prepared.context.lastReply, shown ? "Original reply" : "", "shown: \(shown)")
        }
    }

    /// Bounded to the finished task: a later turn's rows, and earlier ones,
    /// are not its exchange. Without an identity, the last request as before.
    func testTheExchangeIsBoundedToTheFinishedTask() {
        func row(_ id: String, _ role: String, _ text: String, task: String?) -> TranscriptMessage {
            var message = TranscriptMessage(id: id, role: role, text: text); message.taskRootID = task; return message
        }
        let rows = [row("u0", "user", "Old", task: "t0"), row("a0", "assistant", "Old answer", task: "t0"),
                    row("u1", "user", "Request", task: "t1"), row("a1", "assistant", "Answer", task: "t1"),
                    row("u2", "user", "Next", task: "t2"), row("a2", "assistant", "Next answer", task: "t2")]
        let bounded = WebhookContext.exchange(in: rows, task: WebhookTask(rootID: "t1", lastSourceID: "a1"))
        XCTAssertEqual(bounded.request, "Request"); XCTAssertEqual(bounded.reply, "Answer")
        let byRoot = WebhookContext.exchange(in: rows, task: WebhookTask(rootID: "t1", lastSourceID: nil))
        XCTAssertEqual(byRoot.request, "Request"); XCTAssertEqual(byRoot.reply, "Answer")
        // Rows written before task roots were recorded: bounded by the last row.
        let legacy = rows.map { row($0.id, $0.role, $0.text, task: nil) }
        let byLast = WebhookContext.exchange(in: legacy, task: WebhookTask(rootID: "t1", lastSourceID: "a1"))
        XCTAssertEqual(byLast.request, "Request"); XCTAssertEqual(byLast.reply, "Answer")
        XCTAssertEqual(WebhookContext.exchange(in: rows, task: nil).request, "Next")
        let unrelated = WebhookContext.exchange(in: rows, task: WebhookTask(rootID: "t9", lastSourceID: "a9"))
        XCTAssertEqual(unrelated.request, "", "Rows holding none of the task's are another task's")
        XCTAssertEqual(unrelated.reply, "")
    }

    /// The tracker carries the finished task's identity out with its outcome.
    func testTheTrackerNamesTheTaskItsOutcomeIsFor() {
        var tracker = WebhookFinishTracker()
        let old: [String: WireValue] = ["rootID": .string("t0"), "executionID": .string("e0"), "outcome": .string("completed"), "lastSourceID": .string("a0")]
        let new: [String: WireValue] = ["rootID": .string("t1"), "executionID": .string("e1"), "outcome": .string("completed"), "lastSourceID": .string("a2")]
        XCTAssertNil(tracker.observe(taskSnapshot("idle", finished: [old], revision: 1), baseline: true))
        XCTAssertNil(tracker.observe(taskSnapshot("running", active: ["rootID": .string("t1"), "executionID": .string("e1")], finished: [old], revision: 1)))
        XCTAssertEqual(tracker.observe(taskSnapshot("idle", finished: [old, new], revision: 2)), "completed")
        XCTAssertEqual(tracker.finished, WebhookTask(rootID: "t1", lastSourceID: "a2"))
    }
}
