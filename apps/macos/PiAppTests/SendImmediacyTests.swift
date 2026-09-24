import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// One pass of a transcript's document: every row, where it stands in the
/// document and what it is. Comparing passes is how these tests see a jump,
/// a duplicate or a row that went missing, frame by frame.
@MainActor struct TranscriptPass {
    struct Row: Equatable {
        var id: String; var frame: CGRect; var role: String?; var text: String?; var state: String?; var drawn: Bool
        var why = ""
    }
    var rows: [Row] = []
    var scrollY: CGFloat = 0
    var visible = CGRect.zero
    init(document: TranscriptNativeDocument?, scroll: NSScrollView?) {
        guard let document, let clip = scroll?.contentView else { return }
        let visible = document.convert(clip.bounds, from: clip)
        self.visible = visible
        scrollY = clip.bounds.origin.y
        rows = document.retainedRows.map { row in
            var message: TranscriptMessage?
            if case .message(let value) = row.item { message = value }
            let why = "mounted=\(row.superview === document) hosted=\(row.isHosted) hidden=\(row.isHidden) frame=\(row.frame) visible=\(visible) doc=\(document.frame.size)"
            return Row(id: row.itemID, frame: row.frame, role: message?.role, text: message?.text, state: message?.state,
                       drawn: row.superview === document && row.isHosted && !row.isHidden && row.frame.height > 0 && row.frame.intersects(visible), why: why)
        }
    }
    /// The rows the reader's message `text` is drawn as.
    func message(_ text: String) -> [Row] { rows.filter { $0.role == "user" && $0.text == text } }

    /// Across consecutive passes: the message is never two rows; once drawn
    /// it stays drawn, at its height, whichever copy of it the row is; and
    /// neither it nor any row in sight above it moves on the screen but with
    /// the page's scroll: each keeps its place in the document, or the page
    /// scrolled with it (rows far above settling their measured heights move
    /// the document under a page that follows its end, not what is on
    /// screen). Rows in sight above the message keep their height and stay on
    /// the page. What arrives under the message — the reply, and the working
    /// line it replaces — is the run's own business.
    static func assertSteady(_ passes: [TranscriptPass], message text: String, file: StaticString = #filePath, line: UInt = #line) {
        var seen = false
        for (index, pass) in passes.enumerated() {
            let rows = pass.message(text)
            XCTAssertLessThanOrEqual(rows.count, 1, "Pass \(index) draws the message \(rows.count) times", file: file, line: line)
            if seen { XCTAssertEqual(rows.first?.drawn, true, "Pass \(index) lost the message after it was drawn: \(rows.first?.why ?? "no row")", file: file, line: line) }
            if rows.first?.drawn == true { seen = true }
        }
        for (index, (before, after)) in zip(passes, passes.dropFirst()).enumerated() {
            let old = before.message(text).first, new = after.message(text).first
            if let old, let new {
                XCTAssertEqual(old.id, new.id, "The message changed rows", file: file, line: line)
                XCTAssertEqual(old.frame.height, new.frame.height, accuracy: 0.5, "The message changed height (\(old.state ?? "") → \(new.state ?? ""))", file: file, line: line)
            }
            let scrolled = after.scrollY - before.scrollY
            for row in before.rows where row.drawn && (old.map { row.frame.maxY <= $0.frame.maxY + 0.5 } ?? true) {
                guard let now = after.rows.first(where: { $0.id == row.id }) else {
                    XCTFail("Pass \(index + 1): row \(row.id), in sight, left the page", file: file, line: line); continue
                }
                let moved = now.frame.minY - row.frame.minY
                XCTAssertTrue(abs(moved) <= 0.5 || abs(moved - scrolled) <= 0.5,
                              "Pass \(index + 1): row \(row.id), in sight, moved \(moved) in the document while the page scrolled \(scrolled)", file: file, line: line)
                if now.drawn, let old, row.frame.maxY <= old.frame.minY + 0.5 {
                    XCTAssertEqual(now.frame.height, row.frame.height, accuracy: 0.5, "Pass \(index + 1): row \(row.id) above the message changed height", file: file, line: line)
                }
            }
        }
    }
}

extension SendBench {
    func pass() -> TranscriptPass { TranscriptPass(document: document, scroll: scroll) }
    /// Whether the pane's loading mark covers the conversation: its spinner
    /// is the one progress indicator drawn over the transcript.
    var loadingMarkCoversTranscript: Bool {
        guard let scroll else { return false }
        let area = scroll.convert(scroll.bounds, to: nil)
        return views(NSProgressIndicator.self).contains { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil && area.intersects($0.convert($0.bounds, to: nil)) }
    }
}

/// A chat on a helper whose commands the test answers, in a real pane: the
/// send's refusals and replies arrive exactly when the test says.
@MainActor final class ScriptedSendChat {
    @MainActor final class Log { var frames: [[String: WireValue]] = [] }
    let model: WorkspaceModel
    let session: SessionDisplay
    let chat: ChatRecord
    let workspace: WorkspaceRecord
    let window: NSWindow
    let hosted: NSHostingView<ConversationPane>
    let host: HostSupervisor
    let log = Log()
    private let root: URL

    init(messages: [TranscriptMessage] = []) async throws {
        root = scratchRoot("send-scripted")
        let bench = try ConversationPaneTests.workbench(root: root, chats: ["scripted"])
        model = bench.model; chat = bench.chats[0]; workspace = bench.workspace
        try await model.store?.put(chat, kind: "chat", id: chat.id)
        session = SessionDisplay(id: chat.id)
        session.messages = messages; session.historyState = .ready; session.selectionMetadataLoaded = true
        model.displays[chat.id] = session; model.selectedID = chat.id; model.selected = session; model.focusedSessionID = chat.id
        let log = self.log
        host = HostSupervisor(commandSender: { log.frames.append($0) })
        try await host.connect(cwd: root, state: root.appendingPathComponent("host"))
        model.hosts[workspace.id] = host; model.opened.insert(chat.id)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted = NSHostingView(rootView: ConversationPane(model: model, session: session, chat: chat, paneWidth: 900))
        window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        await settle(16)
    }
    func draw() { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
    func settle(_ turns: Int = 8) async { for _ in 0..<turns { draw(); await Task.yield(); try? await Task.sleep(for: .milliseconds(10)) }; draw() }
    func frameAfterInput() async { await Task.yield(); try? await Task.sleep(for: .milliseconds(1)); draw() }
    var editor: ComposerTextView? { ConversationPaneTests.views(ComposerTextView.self, in: hosted).first }
    var scroll: NSScrollView? { ConversationPaneTests.views(TranscriptSurfaceMarker.self, in: hosted).first?.enclosingScrollView }
    var document: TranscriptNativeDocument? { scroll?.documentView as? TranscriptNativeDocument }
    func pass() -> TranscriptPass { TranscriptPass(document: document, scroll: scroll) }
    func key(_ characters: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) {
        guard let editor else { return }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
        if let event { editor.keyDown(with: event) }
    }
    func type(_ text: String) {
        if let editor { window.makeFirstResponder(editor) }
        for character in text { key(String(character)) }
    }
    func frames(_ method: String) -> [[String: WireValue]] { log.frames.filter { $0["method"]?.string == method } }
    func reply(_ frame: [String: WireValue], result: [String: WireValue], ok: Bool = true) throws {
        let connection = try XCTUnwrap(host.connectionID), epoch = try XCTUnwrap(host.epoch)
        host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(epoch),
                             "commandId": try XCTUnwrap(frame["commandId"]), "ok": .bool(ok), "result": .object(result)]), connectionID: connection)
    }
    func until(_ what: String, seconds: Double = 10, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() { await settle(1) }
        XCTAssertTrue(condition(), what, file: file, line: line)
    }
    func close() async {
        try? await host.shutdownAndWait()
        model.shutdown(); window.contentView = nil; window.close()
        try? await model.traces.close(); await model.store?.close()
        try? FileManager.default.removeItem(at: root)
    }
}

final class SendImmediacyTests: XCTestCase {
    /// Return draws the message and empties the composer in the frame it is
    /// pressed in — before the helper has answered anything, here because
    /// the helper is stopped — and when the helper's own row for the message
    /// arrives it takes over in place: the same row, where it stood, at its
    /// height, never drawn twice, nothing above it moving.
    @MainActor func testReturnDrawsTheMessageAtOnceAndTheHelpersRowTakesOverInPlace() async throws {
        let bench = try await SendBench()
        var closed = false
        defer { if !closed { Task { await bench.close() } } }
        // Two finished turns above, so there are rows that must hold still.
        await bench.sendAndWait("First question, for rows above")
        await bench.sendAndWait("Second question, for rows above")
        // Let the last reply's arrival accent fade, so nothing is settling.
        let settled = Date().addingTimeInterval(1.7)
        while Date() < settled { await bench.settle(2) }
        let text = "The message whose row must hold still"
        bench.type(text)
        await bench.settle(2)
        await bench.waitUntil("The chat never settled before the helper was held") { !bench.session.snapshotInFlight && !bench.session.loading }
        let helper = try XCTUnwrap(bench.host?.helperProcessIdentifier, "The packaged helper must be running for this chat")
        var passes = [bench.pass()]
        kill(helper, SIGSTOP)
        var resumed = false
        defer { if !resumed { kill(helper, SIGCONT) } }
        bench.pressReturn()
        await bench.frameAfterInput()
        passes.append(bench.pass())
        XCTAssertEqual(bench.editor?.string, "", "The frame after Return has an empty composer")
        let first = try XCTUnwrap(passes.last?.message(text).first, "The frame after Return draws the message")
        XCTAssertTrue(first.drawn, "The message is drawn where the reader can see it")
        XCTAssertEqual(first.state, "sending", "Until the helper has it, the row is the app's own, marked as sending")
        // The helper still has not answered: the message stays, and so does the empty composer.
        let held = Date().addingTimeInterval(0.4)
        while Date() < held { await bench.settle(1); passes.append(bench.pass()) }
        XCTAssertEqual(passes.last?.message(text).first?.state, "sending")
        XCTAssertEqual(bench.editor?.string, "")
        kill(helper, SIGCONT); resumed = true
        // Every frame until the helper's row is drawn, and a few after.
        var after = 0
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, after < 12 {
            bench.draw(); passes.append(bench.pass())
            if passes.last?.message(text).first.map({ $0.drawn && $0.state != "sending" }) == true { after += 1 }
            await Task.yield(); try? await Task.sleep(for: .milliseconds(8))
        }
        XCTAssertGreaterThanOrEqual(after, 12, "The helper's row never took the message over")
        TranscriptPass.assertSteady(passes, message: text)
        XCTAssertEqual(bench.session.messages.filter { $0.role == "user" && $0.text == text }.count, 1)
        await bench.waitForQuiet()
        closed = true
        await bench.close()
    }

    /// A send the helper refuses takes the message off the page and puts it
    /// back in the composer — its images and skills with it — ahead of what
    /// the reader typed in the meantime. The failure shows where failures
    /// show, and nothing is left on disk that would mark the chat uncertain.
    @MainActor func testARefusedSendPutsTheMessageBackInTheComposer() async throws {
        let chat = try await ScriptedSendChat(messages: [TranscriptMessage(id: "u0", role: "user", text: "Earlier question", at: 1000, turn: "u0"),
                                                        TranscriptMessage(id: "a0", role: "assistant", text: "Earlier answer", at: 2000, turn: "u0")])
        var closed = false
        defer { if !closed { Task { await chat.close() } } }
        let text = "Refactor the parser, please"
        let image = AttachmentRecord(id: "image-1", path: "/tmp/fixture-image.png", sha256: "00", bytes: 10, mimeType: "image/png")
        let skill = SkillChip(id: "skill-1", name: "fixture-skill", path: "/tmp/SKILL.md", contentHash: "content", metadataHash: "metadata")
        chat.type(text)
        chat.session.attachments = [image]; chat.session.skills = [skill]
        await chat.settle(4)
        chat.key("\r", keyCode: 36)
        await chat.frameAfterInput()
        XCTAssertEqual(chat.editor?.string, "", "The composer empties on Return")
        XCTAssertTrue(chat.session.attachments.isEmpty && chat.session.skills.isEmpty, "Its images and skills go with the message")
        XCTAssertEqual(chat.pass().message(text).first?.drawn, true, "The message is drawn at once")
        XCTAssertEqual(chat.session.sendingRows.first?.skills?.map(\.name), ["fixture-skill"],
                       "The row drawn at once carries the skills the message used, so it does not grow at the handover")
        await chat.until("The send never reached the helper") { chat.frames("turn.submit").count == 1 }
        // The reader goes on writing while the helper considers it.
        chat.type("and keep the tests green")
        await chat.settle(2)
        try chat.reply(try XCTUnwrap(chat.frames("turn.submit").first),
                       result: ["code": .string("queue_paused"), "message": .string("Resume or remove paused messages before sending another")], ok: false)
        await chat.until("The refused send never finished") { !chat.session.loading }
        await chat.settle(6)
        XCTAssertTrue(chat.pass().message(text).isEmpty, "The refused message leaves the page")
        XCTAssertEqual(chat.editor?.string, text + "\n\nand keep the tests green", "The message goes back into the composer, ahead of what was typed since")
        XCTAssertEqual(chat.session.attachments, [image], "Its image comes back")
        XCTAssertEqual(chat.session.skills, [skill], "Its skill comes back")
        let failure = try XCTUnwrap(chat.session.presentedMessages.last, "The refusal is shown")
        XCTAssertEqual(failure.kind, "failure"); XCTAssertTrue(failure.text.contains("Resume or remove"))
        XCTAssertTrue(chat.pass().rows.contains { $0.id == failure.id && $0.drawn }, "The failure is drawn in the conversation, where failures show")
        XCTAssertFalse(chat.session.uncertain, "A refused send is not an uncertain one")
        let pending = try await chat.model.store?.list(CommandIntent.self, kind: "pending:\(chat.chat.id)") ?? []
        XCTAssertTrue(pending.isEmpty, "Nothing is left to mark the chat uncertain on its next visit")
        try? await Task.sleep(for: .milliseconds(300))
        let saved = try await chat.model.store?.get(DraftRecord.self, kind: "draft", id: chat.chat.id)
        XCTAssertEqual(saved?.text, text + "\n\nand keep the tests green", "The text is on disk again, as the draft")
        XCTAssertEqual(saved?.attachments ?? [], [image]); XCTAssertEqual(saved?.skills ?? [], [skill])
        closed = true
        await chat.close()
    }

    /// While the helper is taking the message, the record that lets a crash
    /// flag it is on disk, and the draft no longer holds its text: after a
    /// crash the message is recovered once, never twice.
    @MainActor func testTheSubmissionIsDurableBeforeTheHelperCanActOnIt() async throws {
        let chat = try await ScriptedSendChat()
        var closed = false
        defer { if !closed { Task { await chat.close() } } }
        let text = "A message that must survive a crash"
        chat.type(text)
        await chat.settle(4)
        chat.key("\r", keyCode: 36)
        await chat.until("The send never reached the helper") { chat.frames("turn.submit").count == 1 }
        // The command is out; the helper has not answered. This is what a crash would leave.
        let pending = try await chat.model.store?.list(CommandIntent.self, kind: "pending:\(chat.chat.id)") ?? []
        XCTAssertEqual(pending.map(\.text), [text], "The submission's record is on disk before the helper can act on it")
        let submitted = try XCTUnwrap(chat.frames("turn.submit").first?["params"]?.object)
        XCTAssertEqual(pending.first?.turnID, submitted["clientTurnId"]?.string, "The record names the turn the helper was sent")
        let draft = try await chat.model.store?.get(DraftRecord.self, kind: "draft", id: chat.chat.id)
        XCTAssertEqual(draft?.text ?? "", "", "The draft on disk no longer holds the text: it is recovered once, from the record")
        try chat.reply(try XCTUnwrap(chat.frames("turn.submit").first), result: ["accepted": .bool(true), "turnId": submitted["clientTurnId"] ?? .null, "queued": .bool(false)])
        await chat.until("The send never finished") { !chat.session.loading }
        let acknowledged = try await chat.model.store?.list(CommandIntent.self, kind: "pending:\(chat.chat.id)") ?? []
        XCTAssertEqual(acknowledged.map(\.state), ["acknowledged"], "The helper's answer is recorded")
        XCTAssertEqual(chat.pass().message(text).first?.state, "sending", "The message stays drawn until the helper's row arrives")
        closed = true
        await chat.close()
    }

    /// At the foot of a long chat, the helper's row takes over the message
    /// in place, and the reply that follows arrives under it.
    @MainActor func testAtTheFootOfALongChatTheHelpersRowTakesOverInPlace() async throws {
        let rows: [TranscriptMessage] = (0..<300).map { index in
            TranscriptMessage(id: "m\(index)", role: index % 2 == 0 ? "user" : "assistant",
                              text: "Row \(index): some **bold** text, `code` and a [link](https://example.com).\n\n- one\n- two", at: Double(index) * 1000, turn: "m\(index - index % 2)")
        }
        let pane = try ConversationPaneTests.Pane(messages: rows)
        defer { pane.close() }
        pane.session.historyState = .ready
        await pane.settle(40)
        func pass() -> TranscriptPass {
            let scroll = ConversationPaneTests.views(TranscriptSurfaceMarker.self, in: pane.hosted).first?.enclosingScrollView
            return TranscriptPass(document: scroll?.documentView as? TranscriptNativeDocument, scroll: scroll)
        }
        let text = "A question at the foot of a long chat"
        var passes = [pass()]
        pane.session.showSending(TranscriptMessage(id: "turn-1", role: "user", text: text, state: TranscriptMessage.sendingState,
                                                   at: 400_000, turn: "turn-1", taskRootID: "turn-1"))
        pane.model.followSubmittedTurn(pane.session.id, refreshing: false)
        for _ in 0..<6 { await Task.yield(); try? await Task.sleep(for: .milliseconds(8)); pane.draw(); passes.append(pass()) }
        XCTAssertEqual(passes.last?.message(text).first?.drawn, true, "The message is drawn at the foot of the chat")
        // The helper's snapshot: the same message as the helper projects it.
        pane.session.messages.append(TranscriptMessage(id: "turn-1", role: "user", text: text, thinking: "", tools: [], state: "complete", truncated: false,
                                                       at: 400_120, turn: "turn-1", taskRootID: "turn-1", taskExecutionID: "execution-1"))
        for _ in 0..<6 { await Task.yield(); try? await Task.sleep(for: .milliseconds(8)); pane.draw(); passes.append(pass()) }
        XCTAssertTrue(pane.session.sendingRows.isEmpty, "The helper's row is the message now")
        XCTAssertEqual(passes.last?.message(text).first?.state, "complete")
        // Its reply arrives under it.
        pane.session.messages.append(TranscriptMessage(id: "reply-1", role: "assistant", text: "An answer that arrives below.", state: "streaming",
                                                       at: 400_500, turn: "turn-1", taskRootID: "turn-1", taskExecutionID: "execution-1"))
        for _ in 0..<6 { await Task.yield(); try? await Task.sleep(for: .milliseconds(8)); pane.draw(); passes.append(pass()) }
        TranscriptPass.assertSteady(passes, message: text)
        XCTAssertEqual(pane.session.presentedMessages.filter { $0.id == "turn-1" }.count, 1, "One row for the message in what the page is given")
    }

    /// A sent message the helper takes somewhere other than the conversation
    /// leaves the transcript: a delivery it refused, or a paused queue that
    /// holds it once nothing runs. While it is being picked up it shows once,
    /// in the transcript, not also in the queue panel.
    @MainActor func testASentMessageTheHelperHoldsElsewhereLeavesTheTranscript() {
        let display = SessionDisplay(id: "chat")
        display.historyState = .ready
        display.messages = [TranscriptMessage(id: "u0", role: "user", text: "Earlier", turn: "u0")]
        func sent(_ id: String) -> TranscriptMessage {
            TranscriptMessage(id: id, role: "user", text: "Message \(id)", state: TranscriptMessage.sendingState, turn: id, taskRootID: id)
        }
        display.showSending(sent("t1"))
        XCTAssertEqual(display.presentedMessages.map(\.id), ["u0", "t1"], "Drawn at the foot of the conversation")
        let queued: [[String: WireValue]] = [["turnId": .string("t1"), "kind": .string("follow-up"), "text": .string("Message t1")]]
        XCTAssertTrue(display.panelQueue(queued).isEmpty, "Being picked up, it is not also a queued follow-up")
        display.loading = true; display.state = "running"
        XCTAssertFalse(display.settleSending(receipts: [], queued: ["t1"]), "A queue that is about to deliver it keeps it on the page")
        // A snapshot between the helper queueing it and dispatching it: idle,
        // with the message still queued. It stays where it was drawn.
        display.loading = false; display.state = "idle"
        XCTAssertFalse(display.settleSending(receipts: [], queued: ["t1"]), "An idle helper about to dispatch it keeps it on the page")
        XCTAssertEqual(display.presentedMessages.map(\.id), ["u0", "t1"])
        display.state = "paused"; display.queuePaused = true
        XCTAssertTrue(display.settleSending(receipts: [], queued: ["t1"]), "A paused queue holding it takes it off the page")
        XCTAssertTrue(display.sendingRows.isEmpty); XCTAssertEqual(display.panelQueue(queued).count, 1, "The panel shows it instead")
        display.state = "running"
        display.showSending(sent("t2"))
        XCTAssertTrue(display.settleSending(receipts: [["commandId": .string("c2"), "turnId": .string("t2"), "state": .string("failed")]], queued: []),
                      "A delivery the helper refused takes it off the page")
        display.showSending(sent("t3"))
        display.messages.append(TranscriptMessage(id: "t3", role: "user", text: "Message t3", state: "complete", turn: "t3", taskRootID: "t3"))
        XCTAssertTrue(display.sendingRows.isEmpty, "The helper's own row takes its place")
        XCTAssertEqual(display.presentedMessages.map(\.id), ["u0", "t3"], "One row for it, where it was")
        display.showSending(sent("t3"))
        XCTAssertTrue(display.sendingRows.isEmpty, "A message the page already holds is never drawn a second time")
    }

    /// A follow-up to a running turn, and a steer, go to the queue panel as
    /// they always have — never drawn as a row of the conversation — and the
    /// composer empties on Return for them too.
    @MainActor func testFollowUpsAndSteersStillGoToTheQueuePanel() async throws {
        let bench = try await SendBench()
        var closed = false
        defer { if !closed { Task { await bench.close() } } }
        bench.type("slow: walk through the retry loop step by step")
        bench.pressReturn()
        await bench.waitUntil("The slow turn never started") { bench.session.busy && !bench.session.loading }
        for (text, steering) in [("A follow-up while it runs", false), ("Steer it this way", true)] {
            bench.type(text)
            await bench.settle(2)
            let pressed = ProcessInfo.processInfo.systemUptime
            bench.pressReturn(steering: steering)
            await bench.frameAfterInput()
            XCTAssertEqual(bench.editor?.string, "", "The composer empties on Return for “\(text)”")
            var shownInQueue = false
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline, !shownInQueue {
                await bench.settle(1)
                XCTAssertTrue(bench.pass().message(text).isEmpty, "“\(text)” is never drawn as a row of the conversation")
                shownInQueue = QueuedMessage.from(bench.session.queue).contains { $0.text == text && $0.steering == steering }
            }
            XCTAssertTrue(shownInQueue, "“\(text)” shows in the queue panel\(steering ? " as steering" : "")")
            print(String(format: "PERF send.%@ inQueuePanel=%.1fms", steering ? "steer" : "followUp", (ProcessInfo.processInfo.systemUptime - pressed) * 1000))
            XCTAssertNil(bench.session.sendFailure, bench.session.sendFailure ?? "")
            await bench.waitUntil("“\(text)” was never taken") { !bench.session.loading }
        }
        bench.model.stop(sessionID: bench.chatID)
        await bench.waitUntil("The run never stopped") { !bench.session.busy }
        closed = true
        await bench.close()
    }

    /// Typing into a chat whose helper was stopped for being idle starts it,
    /// and opens the chat on it, while the reader is still typing; Return
    /// then draws the message at once and the turn starts without waiting for
    /// a helper to start.
    @MainActor func testTypingStartsAStoppedHelperAndReturnDoesNotWaitForIt() async throws {
        let bench = try await SendBench()
        var closed = false
        defer { if !closed { Task { await bench.close() } } }
        await bench.sendAndWait("Warm up, then go idle")
        bench.model.configuration.runtime.idleGraceSeconds = 1
        if let host = bench.host { bench.model.scheduleIdle(workspaceID: bench.workspace.id, host: host) }
        await bench.waitUntil("The idle helper never stopped", seconds: 30) { bench.host?.isReady != true && !bench.model.opened.contains(bench.chatID) }
        await bench.settle(4)
        bench.model.configuration.runtime.idleGraceSeconds = 120
        // A key every 150 ms: the context preview, which waits for a pause
        // in typing, never fires; only typing itself can start the helper.
        let text = "Is the helper up before I press Return?"
        var typed = 0
        for character in text {
            bench.type(String(character)); typed += 1
            let next = Date().addingTimeInterval(0.15)
            while Date() < next { await bench.settle(1) }
            if bench.host?.isReady == true && bench.model.opened.contains(bench.chatID) { break }
        }
        XCTAssertTrue(bench.host?.isReady == true && bench.model.opened.contains(bench.chatID), "Typing starts the helper and opens the chat on it")
        bench.type(String(text.dropFirst(typed)))
        bench.pressReturn()
        await bench.frameAfterInput()
        XCTAssertEqual(bench.editor?.string, "", "The frame after Return has an empty composer")
        XCTAssertEqual(bench.drawnUserRow(text: text)?.message.state, "sending", "The frame after Return draws the message")
        await bench.waitUntil("The turn never started", seconds: 10) { bench.page?.liveTurn != nil }
        await bench.waitForQuiet()
        closed = true
        await bench.close()
    }

    /// A draft typed in one go while the stopped helper is still starting is
    /// counted by the context meter once typing pauses: the start changes the
    /// chat's context state under the preview that typing scheduled, and the
    /// meter must count the draft all the same.
    @MainActor func testTheContextMeterCountsADraftTypedWhileTheHelperStarts() async throws {
        let bench = try await SendBench()
        var closed = false
        defer { if !closed { Task { await bench.close() } } }
        await bench.sendAndWait("Warm up, then go idle")
        bench.model.configuration.runtime.idleGraceSeconds = 1
        if let host = bench.host { bench.model.scheduleIdle(workspaceID: bench.workspace.id, host: host) }
        await bench.waitUntil("The idle helper never stopped", seconds: 30) { bench.host?.isReady != true && !bench.model.opened.contains(bench.chatID) }
        await bench.settle(4)
        bench.model.configuration.runtime.idleGraceSeconds = 120
        let draft = "A draft typed in one go while the helper starts"
        bench.type(draft)
        await bench.waitUntil("Typing never started the helper", seconds: 20) { bench.host?.isReady == true && bench.model.opened.contains(bench.chatID) }
        await bench.waitUntil("The context meter never counted the draft", seconds: 10) {
            bench.session.footer.preparedContext?.params["text"]?.string == draft
        }
        closed = true
        await bench.close()
    }

    /// A new chat's first message is drawn at once, not covered by the
    /// loading mark while its session opens, and the chat's sidebar row takes
    /// the message as its name in the same frame.
    @MainActor func testANewChatsFirstMessageShowsAtOnceWithItsName() async throws {
        let bench = try await SendBench()
        var closed = false
        defer { if !closed { Task { await bench.close() } } }
        await bench.sendAndWait("Warm the project's helper")
        let previous = bench.model.selectedID
        bench.model.newChat()
        await bench.waitUntil("New Chat never opened a pending chat", seconds: 20) {
            bench.model.selectedID != previous && bench.model.selectedID.map { bench.model.pendingChatIDs.contains($0) } == true
        }
        await bench.follow(try XCTUnwrap(bench.model.selectedID))
        let text = "First message of a brand-new chat"
        bench.type(text)
        await bench.settle(2)
        bench.pressReturn()
        await bench.frameAfterInput()
        XCTAssertEqual(bench.editor?.string, "", "The frame after Return has an empty composer")
        XCTAssertEqual(bench.drawnUserRow(text: text)?.message.state, "sending", "The frame after Return draws the message")
        XCTAssertEqual(bench.model.chatRecord(bench.chatID)?.title, text, "The sidebar row is named after the message at once")
        XCTAssertFalse(bench.loadingMarkCoversTranscript, "The loading mark does not cover the message while the chat's session opens")
        await bench.waitUntil("The helper's row never took over") { bench.drawnUserRow(text: text).map { $0.message.state != "sending" } == true }
        await bench.waitForQuiet()
        let stored = try await bench.model.store?.get(ChatRecord.self, kind: "chat", id: bench.chatID)
        XCTAssertEqual(stored?.title, text, "The name is kept once the helper has the message")
        closed = true
        await bench.close()
    }
}
