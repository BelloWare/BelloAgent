import XCTest
import AppKit
@testable import PiApp

/// How long Edit on a message the reader can see takes to put that message in
/// the composer (EDIT-1, 0.1.131: "Even though I can see the message, it still
/// takes very long to load"). A long chat with a compaction every so many turns
/// is written through the packaged helper and the synthetic gateway; the app
/// is then launched over it as the reader launches it, the chat is opened in
/// the real window, and Edit is pressed on an earlier question on screen, by
/// its row's own pill. Each case is timed from the press to the composer
/// showing that question under its banner, ready for typing, and to the
/// complete original being read, which Send waits for; the steps of the
/// preparation (`messageEditStep`) are timed with it, so the log says what
/// the composer waited on. A Release run's figures are in
/// docs/validation/a131-edit-0.1.131.md.
///
/// Opt-in: `PI_EDIT_LATENCY_TURNS` (pass `TEST_RUNNER_…`). `PI_EDIT_LATENCY_REPLY_KB`
/// sizes each reply (40), `PI_EDIT_LATENCY_COMPACT_EVERY` spaces the compactions
/// (25), and `PI_EDIT_LATENCY_ROOT` keeps the written chat in a folder of its
/// own to measure again without writing it again. Timings mean something only
/// in a Release build-for-testing.
final class MessageEditLatencyTests: XCTestCase, SerialTestLane {
    private let chatID = "edit-latency-chat"
    private let shortTail = 4

    @MainActor private final class Launched {
        let model: WorkspaceModel, window: NSWindow, root: NSView
        init(model: WorkspaceModel, window: NSWindow, root: NSView) { self.model = model; self.window = window; self.root = root }
        func views<T: NSView>(_ type: T.Type, in view: NSView? = nil) -> [T] {
            let view = view ?? root
            return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
        }
        var scroll: NSScrollView? { views(TranscriptSurfaceMarker.self).first?.enclosingScrollView }
        var document: TranscriptNativeDocument? { scroll?.documentView as? TranscriptNativeDocument }
        func composer(_ id: String) -> ComposerInputView? { views(ComposerInputView.self).first { $0.session?.id == id } }
        func editor(_ id: String) -> ComposerTextView? { composer(id)?.field?.documentView as? ComposerTextView }
        func banner(_ id: String) -> ComposerEditBanner? {
            composer(id).flatMap { views(ComposerEditBanner.self, in: $0).first { $0.accessibilityLabel() == "Editing an earlier message" && !$0.isHidden } }
        }
        func draw() { root.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        /// The question's row, when it is laid out on screen.
        func userRow(_ id: String) -> TranscriptNativeUserRow? {
            guard let document, let scroll else { return nil }
            for row in document.retainedRows where row.contentItem.messageIDs.contains(id) {
                let frame = row.convert(row.bounds, to: scroll.contentView)
                guard frame.intersects(scroll.contentView.bounds) else { continue }
                if let user = views(TranscriptNativeUserRow.self, in: row).first { return user }
            }
            return nil
        }
    }

    private struct Setup {
        let root: URL, state: URL
        let vault: ConfigurationVault
        let workspace: WorkspaceRecord, profile: ProfileRecord
        let gateway: SyntheticGateway
    }

    @MainActor private func setup(root: URL) async throws -> Setup {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gateway = try await startSyntheticGateway(in: root, environment: ["PI_APP_UI_FIXTURE_NO_CAPTURES": "1", "PI_APP_UI_FIXTURE_SUMMARY_DELAY": "0"])
        let workspace = WorkspaceRecord(id: "edit-latency-project", path: root.appendingPathComponent("project").path, trusted: true)
        try FileManager.default.createDirectory(atPath: workspace.path, withIntermediateDirectories: true)
        var profile = ProfileRecord()
        profile.id = "edit-latency-profile"; profile.revision = "edit-latency-profile-1"
        profile.api = "openai-responses"; profile.baseUrl = gateway.base; profile.modelId = "ui-fixture"
        profile.name = "Fixture"; profile.contextWindow = 2_000_000; profile.maxOutputTokens = 300_000; profile.modelOutputLimit = 300_000
        var configuration = VaultConfiguration()
        configuration.workspaces = [workspace]
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-loopback-only-key")]
        configuration.automaticUpdateChecks = false
        configuration.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)])
        let vault = ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration)))
        return Setup(root: root, state: root.appendingPathComponent("app-state"), vault: vault, workspace: workspace, profile: profile, gateway: gateway)
    }

    @MainActor private func settle(_ host: HostSupervisor, _ id: String) async throws {
        for _ in 0..<60_000 {
            let status = try await host.request("session.status", sessionID: id).object ?? [:]
            if ["idle", "error", "paused"].contains(status["state"]?.string ?? "") {
                XCTAssertEqual(status["state"]?.string, "idle", String(describing: status["preflightError"]))
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw HostError.failure("The long chat's turn did not settle")
    }

    /// Writes the long chat through the helper, as the reader's runs write
    /// one: questions, replies of `replyKB`, a compaction every `every`
    /// turns, and a few short turns at the end so several questions are on
    /// screen at once when the chat opens at its end.
    @MainActor private func writeLongChat(_ setup: Setup, turns: Int, replyKB: Int, every: Int) async throws {
        let model = WorkspaceModel(stateRoot: setup.state, vault: setup.vault)
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: chatID, workspaceID: setup.workspace.id, title: "Long chat", path: nil, profileID: setup.profile.id)
        try await model.store?.put(chat, kind: "chat", id: chat.id); model.chats = [chat]
        let host = try await model.open(chat)
        let began = ProcessInfo.processInfo.systemUptime
        for turn in 0..<turns {
            let short = turn >= turns - shortTail
            let text = short ? "Short question \(turn): what changed in module \(turn % 17)?"
                : "Question \(turn): summarise what changed in module \(turn % 17) and why, bulk \(replyKB) please."
            _ = try await host.request("turn.submit", sessionID: chat.id, params: ["clientTurnId": .string("t\(turn)"), "text": .string(text)])
            try await settle(host, chat.id)
            if every > 0, !short, (turn + 1) % every == 0 {
                _ = try await host.request("context.compact", sessionID: chat.id)
                try await settle(host, chat.id)
            }
            if turn % 100 == 99 { print(String(format: "EDIT-LATENCY wrote %d turns in %.1f s", turn + 1, ProcessInfo.processInfo.systemUptime - began)) }
        }
        let path = try XCTUnwrap(model.record(chat.id)?.path)
        model.shutdown()
        for host in model.hosts.values { try? await host.shutdownAndWait() }
        try? await model.traces.close(); await model.store?.close()
        let bytes = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        print(String(format: "EDIT-LATENCY journal: %d turns, %.1f MB, written in %.1f s; metadata file %@", turns, Double(bytes) / 1_048_576,
                     ProcessInfo.processInfo.systemUptime - began, FileManager.default.fileExists(atPath: path + ".meta") ? "present" : "missing"))
    }

    @MainActor private func launch(_ setup: Setup) async -> Launched {
        let model = WorkspaceModel(stateRoot: setup.state, vault: setup.vault)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = WorkspaceRootView(model: model)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil; window.close()
            model.report.suspend(); model.shutdown()
            for host in model.hosts.values { try? await host.shutdownAndWait() }
            try? await model.traces.close(); await model.store?.close()
        }
        await model.restore()
        return Launched(model: model, window: window, root: root)
    }

    private struct Timing: CustomStringConvertible {
        var label: String
        var shown: Double?
        var ready: Double?
        var accepted: Double?
        var steps: [(String, Double)] = []
        var note = ""
        var description: String {
            func ms(_ value: Double?) -> String { value.map { String(format: "%.0f ms", $0 * 1000) } ?? "never" }
            let trail = steps.map { String(format: "%@ %.0f", $0.0, $0.1 * 1000) }.joined(separator: ", ")
            return "EDIT-LATENCY \(label): composer shows the question at \(ms(shown)), original loaded at \(ms(ready))\(accepted.map { ", Send accepted at \(ms($0))" } ?? "") [steps ms: \(trail)]\(note.isEmpty ? "" : " " + note)"
        }
    }

    /// Presses Edit on `id`'s row and waits for the composer to show `text`
    /// under the banner, editable, and then for the preparation to end: the
    /// complete original loaded, which is when Send can take the edit.
    @MainActor private func edit(_ launched: Launched, _ id: String, text: String, label: String, timeout: Double = 120,
                                 typeWhileLoading: String? = nil, sendOnReady: Bool = false) async throws -> Timing {
        let model = launched.model
        let view = try XCTUnwrap(model.displays[chatID])
        let row = try XCTUnwrap(launched.userRow(id), "\(label): the question is not on screen")
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                         windowNumber: launched.window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        row.mouseEntered(with: event)
        let pill = try XCTUnwrap(launched.views(TranscriptPillButton.self, in: row).first { $0.title == "Edit" }, "\(label): no Edit pill")
        var timing = Timing(label: label)
        let start = ProcessInfo.processInfo.systemUptime
        model.messageEditStep = { step in timing.steps.append((step, ProcessInfo.processInfo.systemUptime - start)) }
        defer { model.messageEditStep = nil }
        if model.toolOutputRecycling != nil { timing.note += "(tool-output recycling under way at the press)" }
        XCTAssertTrue(pill.accessibilityPerformPress())
        if let typeWhileLoading {
            // A keystroke comes on a later turn of the run loop than the click.
            launched.draw(); await Task.yield()
            if let editor = launched.editor(chatID) { editor.insertText(typeWhileLoading, replacementRange: editor.selectedRange()) }
        }
        while ProcessInfo.processInfo.systemUptime - start < timeout {
            launched.draw()
            let now = ProcessInfo.processInfo.systemUptime - start
            if timing.shown == nil, view.editingMessageID == id, let editor = launched.editor(chatID), editor.string.hasPrefix(text),
               editor.isEditable, launched.banner(chatID) != nil {
                timing.shown = now
            }
            // Over once the preparation is (applied, dropped or failed) and
            // the composer has drawn what it gave.
            if !view.editPreparing {
                if view.editingMessageID == id, timing.ready == nil { timing.ready = now }
                if timing.shown != nil || view.editingMessageID != id || now - (timing.ready ?? now) > 2 { break }
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        if let failure = timing.steps.first(where: { $0.0.hasPrefix("failed") }) { timing.note += " (\(failure.0))" }
        if view.editingMessageID != id { timing.note += " (the composer never entered the edit; notice: \(view.notice))" }
        if sendOnReady {
            XCTAssertFalse(view.editInputPending, view.editNotice)
            view.draft += " (edited in generated latency fixture)"
            model.sendEdit(sessionID: chatID)
            try await eventually("The generated edit is accepted", timeout: .seconds(120)) { !view.editSubmitting }
            XCTAssertNil(view.editingMessageID, view.editNotice)
            timing.accepted = ProcessInfo.processInfo.systemUptime - start
        }
        print(timing)
        model.cancelEdit(sessionID: chatID)
        if typeWhileLoading != nil { view.draft = "" }
        try await eventually("\(label): the edit cancels", timeout: .seconds(30)) { view.editingMessageID == nil && !view.editPreparing }
        launched.draw()
        try await Task.sleep(for: .milliseconds(300))
        return timing
    }

    @MainActor private func quiet(_ view: SessionDisplay) -> Bool {
        !view.hasWork && !view.loading && !view.busy && view.state == "idle" && view.sendingRows.isEmpty && view.queue.isEmpty
            && view.messages.last?.role == "assistant" && view.messages.last?.isStreaming == false
    }

    /// The helper lets go of the chat and opens it again: from its metadata
    /// file, holding only its latest rows, as after a launch.
    @MainActor private func reopen(_ launched: Launched) async throws {
        let model = launched.model
        let item = try XCTUnwrap(model.record(chatID))
        if model.opened.contains(chatID), let host = model.hosts[item.workspaceID] {
            _ = try await host.request("session.close", sessionID: chatID)
            model.helperSessionDidUnload(chatID)
        }
        _ = try await model.open(item)
    }

    /// Only writes the long chat into `PI_EDIT_LATENCY_ROOT`, with no window:
    /// a run that needs no lock prepares the chat the measuring run reads.
    @MainActor func testWritingTheLongChat() async throws {
        guard let turns = testEnvironment("PI_EDIT_LATENCY_TURNS").flatMap(Int.init), turns > shortTail,
              let kept = testEnvironment("PI_EDIT_LATENCY_ROOT").map({ URL(fileURLWithPath: $0) }) else {
            throw XCTSkip("Set PI_EDIT_LATENCY_TURNS and PI_EDIT_LATENCY_ROOT to write a long chat.")
        }
        let written = kept.appendingPathComponent("written.json")
        guard !FileManager.default.fileExists(atPath: written.path) else { return }
        let setup = try await setup(root: kept)
        try await writeLongChat(setup, turns: turns, replyKB: testEnvironment("PI_EDIT_LATENCY_REPLY_KB").flatMap(Int.init) ?? 40,
                                every: testEnvironment("PI_EDIT_LATENCY_COMPACT_EVERY").flatMap(Int.init) ?? 25)
        try JSONEncoder().encode(["turns": turns]).write(to: written)
    }

    @MainActor func testEditingAQuestionOnScreenInALongChat() async throws {
        guard let turns = testEnvironment("PI_EDIT_LATENCY_TURNS").flatMap(Int.init), turns > shortTail else {
            throw XCTSkip("Set PI_EDIT_LATENCY_TURNS to measure editing a message in a long chat.")
        }
        let replyKB = testEnvironment("PI_EDIT_LATENCY_REPLY_KB").flatMap(Int.init) ?? 40
        let every = testEnvironment("PI_EDIT_LATENCY_COMPACT_EVERY").flatMap(Int.init) ?? 25
        let kept = testEnvironment("PI_EDIT_LATENCY_ROOT").map { URL(fileURLWithPath: $0) }
        let root = kept ?? scratchRoot("edit-latency")
        if kept == nil { addTeardownBlock { try? FileManager.default.removeItem(at: root) } }
        let setup = try await setup(root: root)
        let written = root.appendingPathComponent("written.json")
        if !FileManager.default.fileExists(atPath: written.path) {
            try await writeLongChat(setup, turns: turns, replyKB: replyKB, every: every)
            try JSONEncoder().encode(["turns": turns]).write(to: written)
        }
        let launched = await launch(setup)
        let model = launched.model
        // Cold: nothing opens the chat in the helper before the press: not
        // the composer's focus, and not the context pill's reading.
        model.prewarmsHelpers = false
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        model.selectedWorkspaceID = setup.workspace.id
        await model.select(chatID)
        let view = try XCTUnwrap(model.displays[chatID])
        try await eventually("The long chat opens", timeout: .seconds(120)) { launched.draw(); return view.historyState == .ready && launched.document?.retainedRows.isEmpty == false }
        for _ in 0..<30 { launched.draw(); try await Task.sleep(for: .milliseconds(20)) }
        let path = try XCTUnwrap(model.record(chatID)?.path)
        let bytes = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        print(String(format: "EDIT-LATENCY chat: %.1f MB journal, %d rows loaded in the window", Double(bytes) / 1_048_576, view.messages.count))
        // The latest question on screen before the newest one: an earlier message.
        func target() throws -> (id: String, text: String) {
            let questions = view.messages.filter { $0.role == "user" && $0.kind == nil && !$0.isStreaming }.dropLast()
            let found = try XCTUnwrap(questions.last { launched.userRow($0.id) != nil }, "no earlier question is on screen")
            return (found.id, found.text)
        }
        func measure(_ label: String, timeout: Double = 120, typeWhileLoading: String? = nil) async throws {
            let question = try target()
            _ = try await edit(launched, question.id, text: question.text, label: label, timeout: timeout, typeWhileLoading: typeWhileLoading)
        }
        XCTAssertFalse(model.opened.contains(chatID), "the chat is not open in the helper")
        let first = try target()
        print("EDIT-LATENCY first target \(first.id): \(first.text.count) characters")

        // The original's own costs, outside the composer.
        var clock = ProcessInfo.processInfo.systemUptime
        _ = try await HistoryReader().editTarget(path: path, id: first.id)
        print(String(format: "EDIT-LATENCY a fresh history reader's editTarget: %.0f ms", (ProcessInfo.processInfo.systemUptime - clock) * 1000))

        try await measure("helper cold (chat not open in the helper)")
        model.prewarmsHelpers = true; model.automaticContextOperation = nil
        try await reopen(launched)
        try await measure("helper warm, chat opened from its metadata file")
        try await measure("helper warm, cached preparation (second edit)")

        try await reopen(launched)
        let item = try XCTUnwrap(model.record(chatID)), host = try XCTUnwrap(model.hosts[item.workspaceID])
        clock = ProcessInfo.processInfo.systemUptime
        _ = try await host.request("session.edit.prepare", sessionID: chatID, params: ["messageId": .string(first.id)])
        print(String(format: "EDIT-LATENCY session.edit.prepare, chat opened from its metadata file: %.0f ms", (ProcessInfo.processInfo.systemUptime - clock) * 1000))
        clock = ProcessInfo.processInfo.systemUptime
        _ = try await host.request("session.edit.prepare", sessionID: chatID, params: ["messageId": .string(first.id)])
        print(String(format: "EDIT-LATENCY session.edit.prepare, cached preparation: %.0f ms", (ProcessInfo.processInfo.systemUptime - clock) * 1000))

        // During a run, on a chat opened from its metadata file.
        try await reopen(launched)
        view.draft = "A slow answer, please"; model.send(sessionID: chatID)
        try await eventually("The slow run streams", timeout: .seconds(30)) { launched.draw(); return view.busy && view.messages.last?.isStreaming == true }
        try await Task.sleep(for: .milliseconds(500))
        try await measure("during a run (chat opened from its metadata file)")
        model.stop(sessionID: chatID)
        try await eventually("The slow run stops", timeout: .seconds(60)) { launched.draw(); return !view.busy && !view.hasWork && !view.loading }

        // After a run, on a chat opened from its metadata file.
        try await reopen(launched)
        view.draft = "Short follow-up: anything else?"; model.send(sessionID: chatID)
        try await eventually("The follow-up finishes", timeout: .seconds(60)) { launched.draw(); return self.quiet(view) }
        for _ in 0..<20 { launched.draw(); try await Task.sleep(for: .milliseconds(20)) }
        try await measure("after a run (chat opened from its metadata file)")

        // A draft write pending at the press: typing just before it.
        try await reopen(launched)
        let editor = try XCTUnwrap(launched.editor(chatID))
        editor.insertText("draft", replacementRange: editor.selectedRange())
        launched.draw(); try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(view.draftWritePending || model.draftWrites.tasks[chatID] != nil, "a draft write is pending")
        try await measure("draft write pending (chat opened from its metadata file)")
        view.draft = ""

        // Typing while the original loads.
        try await reopen(launched)
        try await measure("typing while it loads (chat opened from its metadata file)", timeout: 60, typeWhileLoading: "x")

        try await reopen(launched)
        let sending = try target()
        _ = try await edit(launched, sending.id, text: sending.text, label: "press Edit through accepted Send, cold helper",
                           sendOnReady: true)
    }
}
