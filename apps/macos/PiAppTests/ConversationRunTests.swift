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

    /// Compaction shows above the composer while it runs and after it lands,
    /// and the composer keeps working throughout.
    @MainActor func testCompactionShowsAboveTheComposerWithoutDisplacingIt() async throws {
        let pane = try Pane(messages: [TranscriptMessage(id: "u1", role: "user", text: "Go", at: 1000, turn: "u1")])
        defer { pane.close() }
        await pane.settle(16)
        let editor = try XCTUnwrap(pane.editor)
        let card = try XCTUnwrap(editor.enclosingScrollView?.superview?.superview)
        let idle = card.convert(card.bounds, to: nil)
        pane.session.state = "compacting"; pane.session.runStatus = "compacting"
        await pane.settle(12)
        let compacting = card.convert(card.bounds, to: nil)
        XCTAssertGreaterThan(compacting.height, idle.height, "The compaction strip takes room inside the composer card")
        XCTAssertEqual(compacting.width, idle.width, accuracy: 0.5, "The strip must not change the composer's width")
        XCTAssertEqual(try XCTUnwrap(editor.enclosingScrollView).frame.height, 44, accuracy: 0.5, "The field itself keeps its height")
        pane.session.state = "idle"; pane.session.runStatus = "idle"
        pane.session.compactionNotice = "Summarized 40 older messages"
        await pane.settle(12)
        XCTAssertGreaterThan(card.convert(card.bounds, to: nil).height, idle.height, "The result stays until it is dismissed")
        pane.session.compactionNotice = nil
        await pane.settle(12)
        XCTAssertEqual(card.convert(card.bounds, to: nil).height, idle.height, accuracy: 0.5, "Dismissing gives the room back")
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
        private let gateway: Process
        private let root: URL

        init() async throws {
            var repository = URL(fileURLWithPath: #filePath)
            for _ in 0..<4 { repository.deleteLastPathComponent() }
            let script = repository.appendingPathComponent("fixtures/native/ui-gateway.py")
            guard FileManager.default.isReadableFile(atPath: script.path) else { throw XCTSkip("The synthetic gateway fixture is unavailable") }
            let scratch = scratchBase()
            root = URL(fileURLWithPath: scratch).appendingPathComponent("pane-live-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("Synthetic fixture file.\n".utf8).write(to: root.appendingPathComponent("README.md"))
            gateway = Process()
            let pipe = Pipe()
            gateway.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            gateway.arguments = ["-u", script.path]
            gateway.currentDirectoryURL = root; gateway.standardOutput = pipe; gateway.standardError = FileHandle.nullDevice
            gateway.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": root.path]
            try gateway.run()
            let handle = pipe.fileHandleForReading
            let greeting = await Task.detached { handle.availableData }.value
            let port = try XCTUnwrap(try JSONDecoder().decode([String: Int].self, from: greeting)["port"])
            let base = "http://127.0.0.1:\(port)"
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
        func close() async {
            for host in model.hosts.values { try? await host.shutdownAndWait() }
            try? await model.traces.close(); await model.store?.close()
            model.shutdown(); window.contentView = nil; window.close()
            if gateway.isRunning { gateway.terminate(); gateway.waitUntilExit() }
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
        live.session.draft = "slow: walk through the retry loop step by step"
        live.model.send(sessionID: live.chat.id)
        await live.waitUntil("The turn never started") { live.session.busy }
        for index in 0..<3 {
            live.session.draft = "Follow-up \(index)"
            live.model.send(sessionID: live.chat.id)
            await live.waitUntil("Follow-up \(index) never reached the queue") { QueuedMessage.from(live.session.queue).count == index + 1 }
        }
        // Promote the first one to steering, so both lanes are populated.
        let queued = QueuedMessage.from(live.session.queue)
        XCTAssertEqual(queued.map(\.text), ["Follow-up 0", "Follow-up 1", "Follow-up 2"])
        live.model.action("queue.steer", params: ["turnId": .string(queued[0].id)], sessionID: live.chat.id)
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

// MARK: - The helper dying under a running turn

extension ConversationPaneTests {
    /// The run lifecycle against the synthetic loopback gateway and the
    /// packaged helper: a turn streams, the composer keeps working under it,
    /// the helper is killed mid-turn, and the pane has to recover — the live
    /// bar leaves, the chat says what happened, the draft survives, and the
    /// next send starts a fresh helper.
    @MainActor func testAHelperKilledMidTurnLeavesThePaneUsableAndTheNextSendRecovers() async throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let gatewayScript = repository.appendingPathComponent("fixtures/native/ui-gateway.py")
        guard FileManager.default.isReadableFile(atPath: gatewayScript.path) else { throw XCTSkip("The synthetic gateway fixture is unavailable") }
        let scratch = scratchBase()
        let root = URL(fileURLWithPath: scratch).appendingPathComponent("pane-crash-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("Synthetic fixture file.\n".utf8).write(to: root.appendingPathComponent("README.md"))

        let fixture = Process(), pipe = Pipe()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = ["-u", gatewayScript.path]
        fixture.currentDirectoryURL = root; fixture.standardOutput = pipe; fixture.standardError = FileHandle.nullDevice
        fixture.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": root.path]
        try fixture.run()
        defer { if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() } }
        let handle = pipe.fileHandleForReading
        let greeting = await Task.detached { handle.availableData }.value
        let port = try XCTUnwrap(try JSONDecoder().decode([String: Int].self, from: greeting)["port"])
        let base = "http://127.0.0.1:\(port)"

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
