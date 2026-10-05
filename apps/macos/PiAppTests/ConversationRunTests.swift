import XCTest
import SwiftUI
import AppKit
@testable import PiApp

// MARK: - The run as the user sees it

extension ConversationPaneTests {
    /// Stop always resolves what is on screen. When the helper that was running
    /// the chat is gone, the bar and its Stop button must not stay up for ever.
    @MainActor func testStopResolvesTheRunEvenWhenTheHelperIsGone() async throws {
        let pane = try Pane(messages: [TranscriptMessage(id: "u1", role: "user", text: "Go", at: 1000, turn: "u1")])
        defer { pane.close() }
        pane.session.state = "running"
        await pane.settle(16)
        let page = try XCTUnwrap(pane.transcript)
        // The bar is up (the pane was built while the chat was already busy is
        // covered separately); drive the state change the way a snapshot does.
        pane.session.state = "queued"; await pane.settle(4)
        pane.session.state = "running"; await pane.settle(6)
        XCTAssertNotNil(page.liveTurn, "The run shows its live bar")
        XCTAssertTrue(pane.session.busy, "The composer offers Stop while the chat is busy")
        // No helper is running this chat: pressing Stop must still end it.
        XCTAssertTrue(pane.model.hosts.isEmpty)
        pane.model.stop(sessionID: pane.session.id)
        await pane.settle(10)
        XCTAssertFalse(pane.session.busy, "Stop must resolve the run when its helper is gone")
        XCTAssertEqual(pane.session.state, "interrupted")
        XCTAssertFalse(pane.session.notice.isEmpty, "Stopping a chat whose helper is gone says so")
        XCTAssertNil(page.liveTurn, "The live bar leaves with the run")
        // Only a press resolves it: a stop the app merely forwards, such as
        // archiving a chat, must not invent an interruption it cannot see.
        pane.session.state = "running"; pane.session.notice = ""
        await pane.settle(6)
        pane.model.stop(sessionID: pane.session.id, userInitiated: false)
        await pane.settle(6)
        XCTAssertEqual(pane.session.state, "running", "A forwarded stop leaves a run the app cannot reach alone")
        XCTAssertTrue(pane.session.notice.isEmpty)
        pane.session.state = "idle"
        await pane.settle(4)
    }

    /// The draft belongs to the chat: switching away and back brings it back,
    /// and a reload of the pane restores what was typed.
    @MainActor func testDraftBelongsToItsChatAcrossSwitchesAndReloads() async throws {
        let scratch = scratchBase()
        let root = URL(fileURLWithPath: scratch).appendingPathComponent("pane-draft-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bench = try Self.workbench(root: root, chats: ["First", "Second"])
        let model = bench.model
        let a = bench.chats[0], b = bench.chats[1]
        for chat in bench.chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        func draw() { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        func settle(_ turns: Int = 14) async { for _ in 0..<turns { draw(); await Task.yield(); try? await Task.sleep(for: .milliseconds(15)) }; draw() }
        func composer() -> ComposerTextView? { Self.views(ComposerTextView.self, in: hosted).first }
        await model.select(a.id); await settle(20)
        let editor = try XCTUnwrap(composer())
        window.makeFirstResponder(editor)
        for character in "half written thought" { type(String(character), into: editor) }
        await settle(20)
        XCTAssertEqual(model.displays[a.id]?.draft, "half written thought")
        await model.select(b.id); await settle(20)
        XCTAssertEqual(composer()?.string, "", "The second chat starts with an empty composer")
        await model.select(a.id); await settle(20)
        XCTAssertEqual(composer()?.string, "half written thought", "Coming back shows the draft that was left")
        // A relaunch: a fresh model over the same store restores the draft.
        try await model.flushDrafts()
        model.shutdown()
        await model.store?.close()
        let restarted = WorkspaceModel(stateRoot: root.appendingPathComponent("app-state"),
                                       vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode({
                                           var configuration = VaultConfiguration()
                                           configuration.workspaces = [bench.workspace]
                                           configuration.profiles = [VaultProfile(profile: bench.profile, apiKey: "synthetic-pane-key")]
                                           return configuration
                                       }()))))
        defer { restarted.shutdown() }
        await restarted.restore()
        await restarted.select(a.id)
        let reopened = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        reopened.isReleasedWhenClosed = false
        let second = NSHostingView(rootView: WorkspaceView(model: restarted))
        reopened.contentView = second; reopened.makeKeyAndOrderFront(nil)
        defer { reopened.contentView = nil; reopened.close() }
        for _ in 0..<30 { second.layoutSubtreeIfNeeded(); reopened.displayIfNeeded(); await Task.yield(); try? await Task.sleep(for: .milliseconds(15)) }
        XCTAssertEqual(Self.views(ComposerTextView.self, in: second).first?.string, "half written thought",
                       "A relaunch puts the unsent draft back in the composer")
        await restarted.store?.close()
    }

    /// Compaction is not shown in the input box: the composer keeps its size
    /// while one runs and after it lands. The run line under the composer says
    /// what the chat is doing, and the transcript shows the finished compaction.
    @MainActor func testCompactionLeavesTheInputBoxAlone() async throws {
        let pane = try Pane(messages: [TranscriptMessage(id: "u1", role: "user", text: "Go", at: 1000, turn: "u1")])
        defer { pane.close() }
        await pane.settle(16)
        let editor = try XCTUnwrap(pane.editor)
        let card = try XCTUnwrap(editor.enclosingScrollView?.superview?.superview)
        let idle = card.convert(card.bounds, to: nil)
        pane.session.state = "compacting"; pane.session.runStatus = "compacting"
        pane.session.compactionProgress = "Summarizing earlier work"
        await pane.settle(12)
        XCTAssertEqual(card.convert(card.bounds, to: nil).height, idle.height, accuracy: 0.5, "Nothing about the compaction goes into the input box")
        XCTAssertEqual(try XCTUnwrap(editor.enclosingScrollView).frame.height, 44, accuracy: 0.5, "The field keeps its height")
        XCTAssertEqual(SessionRunLine.action(pane.session), "Summarizing earlier work…",
                       "The run line under the composer says what the chat is doing")
        pane.session.state = "idle"; pane.session.runStatus = "idle"; pane.session.compactionProgress = nil
        await pane.settle(12)
        XCTAssertEqual(card.convert(card.bounds, to: nil).height, idle.height, accuracy: 0.5)
        // The composer still takes typing afterwards.
        pane.window.makeFirstResponder(editor)
        type("x", into: editor)
        await pane.settle(6)
        XCTAssertEqual(pane.session.draft, "x", "The composer still works after a compaction")
    }

    /// The starter card is the empty chat's welcome; it leaves as soon as the
    /// chat has something in it and never covers the composer.
    @MainActor func testStarterCardLeavesWhenTheChatHasContent() async throws {
        let pane = try Pane(); defer { pane.close() }
        await pane.settle(16)
        func starter() -> NSView? {
            Self.views(NSView.self, in: pane.hosted).first { $0.accessibilityIdentifier() == "starterPanel" }
        }
        let editor = try XCTUnwrap(pane.editor)
        let field = try XCTUnwrap(editor.enclosingScrollView)
        let surface = try XCTUnwrap(Self.views(TranscriptNativeScrollView.self, in: pane.hosted).first)
        XCTAssertTrue(surface.convert(surface.bounds, to: nil).maxY <= pane.window.contentView.map { $0.bounds.height } ?? 0)
        XCTAssertFalse(field.convert(field.bounds, to: nil).intersects(surface.convert(surface.bounds, to: nil)),
                       "The starter card sits over the transcript, never over the composer")
        pane.session.state = "running"
        await pane.settle(8)
        XCTAssertNil(starter(), "A chat that is working shows its work, not the starter card")
        pane.session.state = "idle"
        pane.session.messages = [TranscriptMessage(id: "u1", role: "user", text: "First question", at: 1000, turn: "u1")]
        await pane.settle(12)
        XCTAssertNil(starter(), "A chat with messages never shows the starter card again")
    }
}

// MARK: - A real turn, against the synthetic gateway and the packaged helper

extension ConversationPaneTests {
    /// A chat wired to the synthetic loopback gateway, with the packaged
    /// helper behind it and the real pane on screen.
    @MainActor final class LiveChat {
        let model: WorkspaceModel
        let session: SessionDisplay
        let chat: ChatRecord
        let window: NSWindow
        let hosted: NSHostingView<ConversationPane>
        private let gateway: SyntheticGateway
        private let root: URL

        init() async throws {
            root = scratchRoot("pane-live")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("Synthetic fixture file.\n".utf8).write(to: root.appendingPathComponent("README.md"))
            gateway = try await SyntheticGateway.start(in: root)
            let base = gateway.base
            let workspace = WorkspaceRecord(id: "live-project", path: root.path, trusted: true)
            var profile = ProfileRecord()
            profile.api = "openai-responses"; profile.baseUrl = base; profile.modelId = "ui-fixture"; profile.catalogUrl = base + "/catalog"
            profile.name = "Fixture"; profile.contextWindow = 2_000_000; profile.maxOutputTokens = 300_000; profile.modelOutputLimit = 300_000
            var configuration = VaultConfiguration()
            configuration.workspaces = [workspace]
            configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-loopback-only-key")]
            configuration.automaticUpdateChecks = false
            configuration.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)])
            model = WorkspaceModel(stateRoot: root.appendingPathComponent("app-state"),
                                   vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
            await model.restore()
            model.selectedWorkspaceID = workspace.id; model.profileChoice = profile.id
            chat = ChatRecord(id: UUID().uuidString, workspaceID: workspace.id, title: "Live", path: nil, profileID: profile.id)
            model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
            await model.select(chat.id)
            session = try XCTUnwrap(model.displays[chat.id])
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            hosted = NSHostingView(rootView: ConversationPane(model: model, session: session, chat: chat, paneWidth: 1100))
            window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        }
        var transcript: TranscriptPage? { ConversationPaneTests.views(TranscriptSurfaceMarker.self, in: hosted).first?.page }
        func draw() { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        func settle(_ turns: Int = 12) async { for _ in 0..<turns { draw(); await Task.yield(); try? await Task.sleep(for: .milliseconds(20)) }; draw() }
        /// Keeps the chat busy across a window of draws, and leaves it busy on
        /// the caller's next line. A snapshot reply puts the helper's settled
        /// state back the moment it lands, so a test about what the transcript
        /// does *while* a chat is running has to hold that state rather than
        /// set it once and hope nothing polls inside the window.
        func holdRunning(_ turns: Int = 12) async {
            for _ in 0..<turns {
                session.taskPresentation = nil
                if session.state != "running" { session.state = "running" }
                draw(); await Task.yield(); try? await Task.sleep(for: .milliseconds(20))
            }
            if session.state != "running" { session.state = "running" }
            draw()
        }
        func waitUntil(_ what: String, seconds: Double = 60, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { if condition() { return }; await settle(2) }
            XCTFail("\(what) (state \(session.state), notice “\(session.notice)”)", file: file, line: line)
        }
        /// Sends `text` the way Return does, and returns once the helper has
        /// taken it.
        func send(_ text: String, file: StaticString = #filePath, line: UInt = #line) async {
            session.draft = text
            model.send(sessionID: chat.id)
            XCTAssertTrue(session.loading, "The composer did not take “\(text)”", file: file, line: line)
            await taken(text, file: file, line: line)
        }
        /// Waits until the helper has taken the message on its way.
        ///
        /// A message shows before it is taken: the chat shows the run the
        /// moment Send is pressed, and a follow-up shows in the queue as soon
        /// as a snapshot carries it. The composer takes nothing new until the
        /// helper's answer has been recorded (`loading`: Send is disabled and
        /// Return does nothing), so a message sent on those first signals
        /// stays in the composer, unsent, whenever that answer is slow to land.
        func taken(_ text: String, file: StaticString = #filePath, line: UInt = #line) async {
            await waitUntil("The helper never took “\(text)”", file: file, line: line) { !session.loading }
            XCTAssertNil(session.sendFailure, "“\(text)” was refused: \(session.sendFailure ?? "")", file: file, line: line)
            XCTAssertTrue(session.draft.isEmpty, "Taking “\(text)” clears the composer", file: file, line: line)
        }
        /// Stops the chat's helper process while `body` runs, so every answer
        /// it owes lands after `body` returns: the order a slow helper, or a
        /// slow write of its answer, produces now and then, made certain.
        func holdingHelper(_ body: () async -> Void) async throws {
            _ = try await model.open(chat)
            // Nothing may be on its way back: a snapshot of the idle chat
            // landing inside `body` would take down the run a send puts up.
            await waitUntil("The chat never settled before its helper was held") { !session.snapshotInFlight && !session.loading }
            let helper = try XCTUnwrap(model.hosts[chat.workspaceID]?.helperProcessIdentifier, "The packaged helper must be running for this chat")
            kill(helper, SIGSTOP)
            defer { kill(helper, SIGCONT) }
            await body()
        }
        func close() async {
            for host in model.hosts.values { try? await host.shutdownAndWait() }
            try? await model.traces.close(); await model.store?.close()
            model.shutdown(); window.contentView = nil; window.close()
            gateway.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Dragging a follow-up sends the host exactly the follow-up lane, in its
    /// new order. The host keeps steering in a lane of its own and refuses an
    /// order that is not precisely its pending follow-ups, so the payload the
    /// panel builds is pinned here against the helper's own check.
    @MainActor func testDraggingAFollowUpSendsTheHostTheFollowUpLaneOnly() async throws {
        let live = try await LiveChat()
        var closed = false
        defer { if !closed { Task { await live.close() } } }
        await live.settle(20)
        // The run shows before the helper has taken the message that starts
        // it. Its answer is held back here, so the follow-ups meet that gap
        // every time rather than on a slow run: each goes in once the message
        // before it is taken, never merely once something shows.
        let slow = "slow: walk through the retry loop step by step"
        try await live.holdingHelper {
            live.session.draft = slow
            live.model.send(sessionID: live.chat.id)
            await live.waitUntil("The turn never started") { live.session.busy }
            XCTAssertTrue(live.session.loading, "The run shows before the held helper has taken the message")
        }
        await live.taken(slow)
        for index in 0..<3 {
            await live.send("Follow-up \(index)")
            await live.waitUntil("Follow-up \(index) never reached the queue") { QueuedMessage.from(live.session.queue).count == index + 1 }
        }
        // Promote the first one to steering, so both lanes are populated.
        let queued = QueuedMessage.from(live.session.queue)
        XCTAssertEqual(queued.map(\.text), ["Follow-up 0", "Follow-up 1", "Follow-up 2"])
        // A queue that never filled has already failed above; unwrapping keeps
        // that a failure of this test instead of a crash of the whole run.
        let first = try XCTUnwrap(queued.first, "No follow-up reached the queue")
        live.model.action("queue.steer", params: ["turnId": .string(first.id)], sessionID: live.chat.id)
        await live.waitUntil("The follow-up never moved into the steering lane") {
            QueuedMessage.from(live.session.queue).contains(where: \.steering)
        }
        XCTAssertNil(live.model.error, live.model.error ?? "")
        let lanes = QueuedMessage.from(live.session.queue)
        let followUps = lanes.filter { !$0.steering }, steering = lanes.filter(\.steering)
        XCTAssertEqual(followUps.map(\.text), ["Follow-up 1", "Follow-up 2"], "The remaining follow-ups keep their order")
        XCTAssertEqual(steering.map(\.text), ["Follow-up 0"], "The promoted message shows in the steering lane, without its wire prefix")

        // What the drag sends: the follow-up lane, reordered.
        var order = followUps.map(\.id)
        order.reverse()
        live.model.action("queue.reorder", params: ["turnIds": .array(order.map(WireValue.string))], sessionID: live.chat.id)
        await live.waitUntil("The host never applied the new order") {
            QueuedMessage.from(live.session.queue).filter { !$0.steering }.map(\.text) == ["Follow-up 2", "Follow-up 1"]
        }
        XCTAssertNil(live.model.error, "The helper accepted the follow-up lane as the whole order: \(live.model.error ?? "")")
        XCTAssertEqual(QueuedMessage.from(live.session.queue).filter(\.steering).map(\.text), ["Follow-up 0"],
                       "Reordering follow-ups leaves the steering lane alone")

        // And the other reading of the contract is wrong: an order that also
        // lists the steering message is refused, so the panel must not send it.
        let withSteering = QueuedMessage.from(live.session.queue).map(\.id)
        live.model.action("queue.reorder", params: ["turnIds": .array(withSteering.map(WireValue.string))], sessionID: live.chat.id)
        await live.waitUntil("The helper accepted an order that included the steering lane") { live.model.error != nil }
        XCTAssertEqual(QueuedMessage.from(live.session.queue).filter { !$0.steering }.map(\.text), ["Follow-up 2", "Follow-up 1"],
                       "A refused order changes nothing")
        live.model.error = nil
        live.model.stop(sessionID: live.chat.id)
        await live.settle(10)
        closed = true
        await live.close()
    }
}

extension ConversationPaneTests {
    /// Rewriting a queued follow-up in the composer, against the packaged
    /// helper: Return puts the new text back in the queue in its place, and
    /// the draft set aside for it comes back.
    @MainActor func testSavingAQueuedRewriteUpdatesTheHelpersQueueInPlace() async throws {
        let live = try await LiveChat()
        var closed = false
        defer { if !closed { Task { await live.close() } } }
        await live.settle(20)
        let slow = "slow: walk through the retry loop step by step"
        try await live.holdingHelper {
            live.session.draft = slow
            live.model.send(sessionID: live.chat.id)
            await live.waitUntil("The turn never started") { live.session.busy }
        }
        await live.taken(slow)
        for index in 0..<2 {
            await live.send("Follow-up \(index)")
            await live.waitUntil("Follow-up \(index) never reached the queue") { QueuedMessage.from(live.session.queue).count == index + 1 }
        }
        live.session.draft = "unsent thought"
        let first = try XCTUnwrap(QueuedMessage.from(live.session.queue).first)
        live.model.editQueued(first.id, sessionID: live.chat.id)
        await live.waitUntil("The edit never opened") { live.session.queueEditingID == first.id }
        XCTAssertEqual(live.session.draft, "Follow-up 0")
        live.session.draft = "Follow-up 0, rewritten"
        live.model.submitComposer(intent: .followUp, sessionID: live.chat.id)
        await live.waitUntil("The helper never confirmed the save") { live.session.queueEditingID == nil }
        XCTAssertEqual(live.session.draft, "unsent thought", "The set-aside draft comes back")
        await live.waitUntil("The helper never took the rewrite") {
            QueuedMessage.from(live.session.queue).map(\.text) == ["Follow-up 0, rewritten", "Follow-up 1"]
        }
        XCTAssertEqual(QueuedMessage.from(live.session.queue).first?.id, first.id, "The rewrite keeps its place and identity")
        XCTAssertNil(live.model.error, live.model.error ?? "")
        live.model.stop(sessionID: live.chat.id)
        await live.settle(10)
        closed = true
        await live.close()
    }
}

extension ConversationPaneTests {
    /// After Stop the queue waits for Resume. A message sent meanwhile joins
    /// it, after what was waiting, instead of being refused, and Resume sends
    /// them in order.
    @MainActor func testAMessageSentWhileTheQueueIsPausedJoinsIt() async throws {
        let live = try await LiveChat()
        var closed = false
        defer { if !closed { Task { await live.close() } } }
        await live.settle(20)
        let slow = "slow: walk through the retry loop step by step"
        try await live.holdingHelper {
            live.session.draft = slow
            live.model.send(sessionID: live.chat.id)
            await live.waitUntil("The turn never started") { live.session.busy }
        }
        await live.taken(slow)
        await live.send("Follow-up 0")
        await live.waitUntil("The follow-up never reached the queue") { QueuedMessage.from(live.session.queue).count == 1 }
        live.model.stop(sessionID: live.chat.id)
        await live.waitUntil("The stopped run never paused its queue") { !live.session.busy && live.session.queuePaused }
        await live.send("Added while paused")
        await live.waitUntil("The new message never joined the paused queue") {
            QueuedMessage.from(live.session.queue).map(\.text) == ["Follow-up 0", "Added while paused"]
        }
        XCTAssertTrue(live.session.queuePaused, "It waits for Resume")
        XCTAssertNil(live.session.sendFailure, live.session.sendFailure ?? "")
        live.model.action("queue.resume", sessionID: live.chat.id)
        await live.waitUntil("Resume never sent both") {
            live.session.queue.isEmpty && !live.session.busy && live.session.messages.contains { $0.role == "user" && $0.text == "Added while paused" }
        }
        let users = live.session.messages.filter { $0.role == "user" }.map(\.text)
        XCTAssertEqual(Array(users.suffix(2)), ["Follow-up 0", "Added while paused"], "Resume sends them in order")
        XCTAssertNil(live.model.error, live.model.error ?? "")
        closed = true
        await live.close()
    }
}

extension ConversationPaneTests.LiveChat {
    /// The last finished turn's report, as the page shows it.
    var finishedTurn: TurnSummary? {
        transcript?.snapshot?.items.reversed().lazy.compactMap { item -> TurnSummary? in
            if case .block(let block) = item, block.presentation == .summary, let turn = block.turn, !turn.isRunning { return turn }
            return nil
        }.first
    }
}

extension ConversationPaneTests {
    /// Stop leaves one account of itself, against the packaged helper: the
    /// turn's card says "Stopped", counts the request as stopped rather than
    /// failed, and keeps the host's advice in its note; nothing under the card
    /// repeats it.
    @MainActor func testAStoppedTurnSaysSoOnce() async throws {
        let live = try await LiveChat()
        var closed = false
        defer { if !closed { Task { await live.close() } } }
        await live.settle(20)
        await live.send("slow: stop me part way")
        await live.waitUntil("The answer never started streaming") {
            live.session.messages.contains { $0.role == "assistant" && $0.isStreaming && !$0.text.isEmpty }
        }
        live.model.stop(sessionID: live.chat.id)
        await live.waitUntil("The run never stopped") { !live.session.busy }
        await live.waitUntil("The stopped turn's card never counted its request") {
            live.finishedTurn.map { $0.outcome == "cancelled" && $0.accounting.missing.stopped == 1 } ?? false
        }
        let turn = try XCTUnwrap(live.finishedTurn)
        XCTAssertEqual(TurnInfoPresentation.outcome(turn), "Stopped")
        XCTAssertEqual(turn.accounting.requests, 1)
        XCTAssertEqual(turn.accounting.missing.failed, 0, "A request the user stopped did not fail")
        let note = try XCTUnwrap(TurnInfoPresentation.cardNote(turn))
        XCTAssertTrue(note.hasSuffix("1 did not report usage (1 stopped)"), note)
        XCTAssertFalse(note.hasPrefix("Run cancelled"), "The header already says it stopped: \(note)")
        XCTAssertNil(StableTurnSummaryView.shownNotice(turn), "No amber line under the card")
        XCTAssertNil(live.model.error, live.model.error ?? "")
        closed = true
        await live.close()
    }
}

// MARK: - The helper dying under a running turn

extension ConversationPaneTests {
    /// The run lifecycle against the synthetic loopback gateway and the
    /// packaged helper: a turn streams, the composer keeps working under it,
    /// the helper is killed mid-turn, and the pane has to recover — the live
    /// bar leaves, the chat says what happened, the draft survives, and the
    /// next send starts a fresh helper.
    @MainActor func testAHelperKilledMidTurnLeavesThePaneUsableAndTheNextSendRecovers() async throws {
        let root = scratchRoot("pane-crash")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("Synthetic fixture file.\n".utf8).write(to: root.appendingPathComponent("README.md"))

        let fixture = try await SyntheticGateway.start(in: root)
        defer { fixture.stop() }
        let base = fixture.base

        let workspace = WorkspaceRecord(id: "crash-project", path: root.path, trusted: true)
        var profile = ProfileRecord()
        profile.api = "openai-responses"; profile.baseUrl = base; profile.modelId = "ui-fixture"; profile.catalogUrl = base + "/catalog"
        profile.name = "Fixture"; profile.contextWindow = 2_000_000; profile.maxOutputTokens = 300_000; profile.modelOutputLimit = 300_000
        var configuration = VaultConfiguration()
        configuration.workspaces = [workspace]
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-loopback-only-key")]
        configuration.automaticUpdateChecks = false
        configuration.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)])
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("app-state"),
                                   vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
        defer { model.shutdown() }
        await model.restore()
        model.selectedWorkspaceID = workspace.id; model.profileChoice = profile.id
        let chat = ChatRecord(id: UUID().uuidString, workspaceID: workspace.id, title: "Crash", path: nil, profileID: profile.id)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.select(chat.id)
        let session = try XCTUnwrap(model.displays[chat.id])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: ConversationPane(model: model, session: session, chat: chat, paneWidth: 1100))
        window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        func draw() { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        func settle(_ turns: Int = 12) async { for _ in 0..<turns { draw(); await Task.yield(); try? await Task.sleep(for: .milliseconds(20)) }; draw() }
        func waitUntil(_ what: String, seconds: Double = 60, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { if condition() { return }; await settle(2) }
            XCTFail("\(what) (state \(session.state), notice “\(session.notice)”)")
        }
        await settle(20)
        let page = try XCTUnwrap(Self.views(TranscriptSurfaceMarker.self, in: hosted).first?.page)

        session.draft = "slow: walk through the retry loop step by step"
        model.send(sessionID: chat.id)
        try await waitUntil("The turn never started") { session.busy }
        try await waitUntil("The live bar never appeared for a running turn") { page.liveTurn != nil }
        XCTAssertTrue(session.draft.isEmpty, "Sending clears the composer")
        // The composer keeps working under a running turn: this becomes a follow-up.
        let editor = try XCTUnwrap(Self.views(ComposerTextView.self, in: hosted).first)
        window.makeFirstResponder(editor)
        for character in "and then summarize" { type(String(character), into: editor) }
        await settle(6)
        XCTAssertEqual(session.draft, "and then summarize", "The composer takes a follow-up while the run streams")

        // Kill the helper that is running this turn: exactly the one this
        // model started. A `pgrep -f` here would also match the owner's own
        // running app's helper, and any shell whose script names the helper.
        let helperPID = try XCTUnwrap(model.hosts[chat.workspaceID]?.helperProcessIdentifier,
                                      "The packaged helper must be running for this chat")
        kill(helperPID, SIGKILL)

        try await waitUntil("The chat never noticed its helper had died", seconds: 60) { !session.busy }
        await settle(20)
        XCTAssertEqual(session.state, "interrupted", "A killed helper interrupts the run instead of leaving it running")
        XCTAssertNil(page.liveTurn, "The live bar must leave when the helper dies")
        XCTAssertFalse(session.notice.isEmpty, "The chat says the helper stopped")
        XCTAssertTrue(session.uncertain, "The outcome of the interrupted command is uncertain")
        XCTAssertEqual(Self.views(ComposerTextView.self, in: hosted).first?.string, "and then summarize",
                       "Nothing typed into the composer is lost when the helper dies")
        // The composer is still usable.
        window.makeFirstResponder(editor)
        type("!", into: editor)
        await settle(6)
        XCTAssertEqual(session.draft, "and then summarize!", "The composer still takes typing after the helper died")

        // Sending again starts a fresh helper. The uncertainty confirmation is
        // a modal decision the user makes; the test answers it in advance.
        session.uncertain = false
        model.send(sessionID: chat.id)
        try await waitUntil("The chat did not recover after its helper was killed", seconds: 90) {
            session.busy || session.messages.contains { $0.role == "assistant" }
        }
        XCTAssertNil(model.error, model.error ?? "")
        try await waitUntil("The recovered turn never finished", seconds: 120) { !session.hasWork && !session.loading }
        for host in model.hosts.values { try await host.shutdownAndWait() }
        try await model.traces.close(); await model.store?.close()
    }
}

extension ConversationPaneTests {
    /// A request still streaming is counted once, against the packaged
    /// helper. The helper links a request to its hidden ledger row from
    /// dispatch on, and that link kept the streaming answer from its request:
    /// the user's row took it, and the answer's own stand-in counted it again.
    /// One request read "0 of 2 requests … (2 still running)", and a turn of
    /// four read "3 of 5".
    @MainActor func testARequestStillStreamingIsCountedOnce() async throws {
        let live = try await LiveChat()
        var closed = false
        defer { if !closed { Task { await live.close() } } }
        await live.settle(20)
        let prompt = "slow: count the requests of this turn"
        await live.send(prompt)
        await live.waitUntil("The answer never started streaming") { live.session.messages.contains { $0.role == "assistant" && $0.isStreaming } }
        let ledger = try XCTUnwrap(live.session.messages.last { $0.kind == "requestLedger" }, "The helper keeps a ledger row for the request")
        let answer = try XCTUnwrap(ledger.presentationSourceID)
        // The ledger's link reaches the log with the footer's next figures.
        var linked = false
        for _ in 0..<150 where !linked {
            linked = try await !live.model.traces.list(sessionID: live.chat.id, messageID: ledger.id, workspaceID: live.chat.workspaceID).isEmpty
            if !linked { await live.settle(2) }
        }
        XCTAssertTrue(linked, "The request log links the request to its ledger while it streams")
        // Read the accounting again now that the log holds that link.
        let revision = live.session.accountingRevision
        live.model.scheduleAccounting(live.chat.id, workspaceID: live.chat.workspaceID)
        await live.waitUntil("The accounting was never read again") {
            live.session.accountingRevision > revision && live.model.accountingTasks[live.chat.id] == nil
        }
        XCTAssertTrue(live.session.messages.contains { $0.id == answer && $0.isStreaming }, "The answer is still streaming")
        XCTAssertEqual(live.session.messageAccounting[answer]?.requests, 1, "The streaming answer keeps its own request")
        let turn = Array(live.session.messages.drop { !($0.role == "user" && $0.text == prompt) })
        XCTAssertNil(live.session.messageAccounting[turn.first?.id ?? ""], "The user's row does not take the answer's request")
        let accounting = TranscriptActivity.aggregate(turn)
        XCTAssertEqual(accounting.requests, 1, "One request, counted once")
        XCTAssertEqual(accounting.missing.running, 1)
        live.model.stop(sessionID: live.chat.id)
        await live.settle(10)
        closed = true
        await live.close()
    }
}
