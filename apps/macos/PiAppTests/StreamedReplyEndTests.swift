import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// A reply streamed into the open chat ends on screen whole. The owner saw a
/// reply stop growing halfway while its chat's content was complete, and
/// leaving the chat and coming back showed all of it.
final class StreamedReplyEndTests: XCTestCase, SerialTestLane {
    @MainActor private struct Setup {
        let root: URL, state: URL
        let vault: ConfigurationVault
        let workspace: WorkspaceRecord, profile: ProfileRecord
    }

    @MainActor private func setup() async throws -> Setup {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let script = repository.appendingPathComponent("fixtures/native/ui-gateway.py")
        guard FileManager.default.isReadableFile(atPath: script.path) else { throw XCTSkip("The synthetic gateway fixture is unavailable") }
        let root = scratchRoot("streamed-reply-end")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let gateway = Process(), pipe = Pipe()
        gateway.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        gateway.arguments = ["-u", script.path]
        gateway.currentDirectoryURL = root; gateway.standardOutput = pipe; gateway.standardError = FileHandle.nullDevice
        gateway.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": root.path]
        try gateway.run()
        addTeardownBlock { gateway.terminate(); gateway.waitUntilExit() }
        let handle = pipe.fileHandleForReading
        let greeting = await Task.detached { handle.availableData }.value
        let port = try XCTUnwrap(try JSONDecoder().decode([String: Int].self, from: greeting)["port"])
        let base = "http://127.0.0.1:\(port)"
        let workspace = WorkspaceRecord(id: "streamed-reply-project", path: root.appendingPathComponent("project").path, trusted: true)
        try FileManager.default.createDirectory(atPath: workspace.path, withIntermediateDirectories: true)
        try Data("Synthetic UI fixture file: read-tool round trip verified.\n".utf8).write(to: URL(fileURLWithPath: workspace.path).appendingPathComponent("README.md"))
        var profile = ProfileRecord()
        profile.api = "openai-responses"; profile.baseUrl = base; profile.modelId = "ui-fixture"; profile.catalogUrl = base + "/catalog"
        profile.name = "Fixture"; profile.contextWindow = 2_000_000; profile.maxOutputTokens = 300_000; profile.modelOutputLimit = 300_000
        var configuration = VaultConfiguration()
        configuration.workspaces = [workspace]
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-loopback-only-key")]
        configuration.automaticUpdateChecks = false
        configuration.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)])
        let vault = ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration)))
        return Setup(root: root, state: root.appendingPathComponent("app-state"), vault: vault, workspace: workspace, profile: profile)
    }

    @MainActor private final class Launched {
        let model: WorkspaceModel, window: NSWindow, hosted: NSView
        init(model: WorkspaceModel, window: NSWindow, hosted: NSView) { self.model = model; self.window = window; self.hosted = hosted }
        func views<T: NSView>(_ type: T.Type, in view: NSView? = nil) -> [T] {
            let view = view ?? hosted
            return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
        }
        var marker: TranscriptSurfaceMarker? { views(TranscriptSurfaceMarker.self).first }
        var scroll: NSScrollView? { marker?.enclosingScrollView }
        var document: TranscriptNativeDocument? { scroll?.documentView as? TranscriptNativeDocument }
        var page: TranscriptPage? { marker?.page }
        func draw() { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
    }

    @MainActor private func launch(_ setup: Setup) -> Launched {
        let model = WorkspaceModel(stateRoot: setup.state, vault: setup.vault)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil; window.close()
            model.report.suspend(); model.shutdown()
            for host in model.hosts.values { try? await host.shutdownAndWait() }
            try? await model.traces.close(); await model.store?.close()
        }
        return Launched(model: model, window: window, hosted: hosted)
    }

    @MainActor private func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @MainActor private func quiet(_ view: SessionDisplay?) -> Bool {
        guard let view else { return false }
        return !view.hasWork && !view.loading && !view.busy && view.state == "idle" && view.taskPresentation?.active == nil
            && view.sendingRows.isEmpty && view.queue.isEmpty && view.messages.last?.role == "assistant" && view.messages.last?.isStreaming == false
    }

    /// The reply as each layer holds it once the turn is over: the helper, the
    /// chat's display, the page, the document's row and the drawn text.
    private struct Layers: CustomStringConvertible {
        var helper: String?, display: String?, page: String?, row: String?, drawn: String?
        var rowHosted = false
        var description: String {
            func length(_ text: String?) -> String { text.map { "\($0.utf8.count)" } ?? "nil" }
            return "helper \(length(helper)), display \(length(display)), page \(length(page)), row \(length(row)), drawn \(length(drawn))\(rowHosted ? "" : " (row has no tree)")"
        }
    }

    @MainActor private func layers(_ launched: Launched, chat: String) async -> Layers {
        var found = Layers()
        let model = launched.model
        if let item = model.record(chat), let host = model.hosts[item.workspaceID],
           let result = try? await host.request("session.snapshot", sessionID: chat, params: ["includeMessages": .bool(true)]).object,
           let page = result["messages"], let rows = try? TranscriptMessage.page(page) {
            found.helper = rows.last(where: { $0.role == "assistant" })?.text
        }
        let reply = model.displays[chat]?.messages.last(where: { $0.role == "assistant" })
        found.display = reply?.text
        found.page = launched.page?.snapshot?.messages.last(where: { $0.role == "assistant" })?.text
        if let reply, let document = launched.document {
            // A reply is drawn as its response's part rows: its prose is in
            // the text parts, each drawn by its own markdown surface.
            var texts: [String] = [], drawn: [String] = [], hosted = false
            for row in document.retainedRows {
                let belongs: Bool
                switch row.item {
                case .message(let message) where message.id == reply.id:
                    belongs = true; texts.append(message.text)
                case .block(let block) where block.message?.id == reply.id || block.responseID == reply.id:
                    belongs = true
                    if let part = block.part { if ["text", "refusal"].contains(part.part.kind) { texts.append(part.text) } }
                    else if let text = block.message?.text { texts.append(text) }
                default: belongs = false
                }
                guard belongs else { continue }
                let surfaces = launched.views(NativeMarkdownContainer.self, in: row)
                if !surfaces.isEmpty { hosted = true }
                drawn += surfaces.map(\.textView.string)
            }
            found.row = texts.isEmpty ? nil : texts.joined()
            found.rowHosted = hosted
            found.drawn = hosted ? drawn.joined(separator: "\n") : nil
        }
        return found
    }

    private struct SplitMix64 { var state: UInt64
        mutating func next() -> UInt64 { state &+= 0x9E3779B97F4A7C15; var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func pick(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    /// Long replies streamed while the reader does what a reader does:
    /// scrolls, starts a gesture that never ends, switches chats and back,
    /// lets the window go to the back. After each reply the helper, the
    /// display, the page, the document's row and the drawn text must agree.
    /// Opt-in: `PI_STREAM_STRESS_SECONDS` (pass TEST_RUNNER_…).
    @MainActor func testAStreamedReplyEndsWholeOnScreenUnderInterference() async throws {
        guard let seconds = testEnvironment("PI_STREAM_STRESS_SECONDS").flatMap(Double.init) else { throw XCTSkip("Set PI_STREAM_STRESS_SECONDS to run the streamed-reply stress") }
        let seed = testEnvironment("PI_STREAM_STRESS_SEED").flatMap(UInt64.init) ?? UInt64(Date().timeIntervalSince1970 * 1000)
        print("STREAM seed \(seed)")
        var random = SplitMix64(state: seed)
        let setup = try await setup()
        let launched = launch(setup)
        let model = launched.model
        await model.restore()
        model.selectedWorkspaceID = setup.workspace.id; model.profileChoice = setup.profile.id
        let main = ChatRecord(id: "chat-main-" + UUID().uuidString, workspaceID: setup.workspace.id, title: "Streams", path: nil, profileID: setup.profile.id)
        let other = ChatRecord(id: "chat-other-" + UUID().uuidString, workspaceID: setup.workspace.id, title: "Other", path: nil, profileID: setup.profile.id)
        model.chats = [main, other]
        try await model.store?.put(main, kind: "chat", id: main.id); try await model.store?.put(other, kind: "chat", id: other.id)
        await model.select(other.id)
        model.displays[other.id]?.draft = "And a short one"; model.send(sessionID: other.id)
        _ = await wait(60) { self.quiet(model.displays[other.id]) }
        await model.select(main.id)
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var turns = 0, mismatches: [String] = []
        while ProcessInfo.processInfo.systemUptime < deadline {
            turns += 1
            if model.selectedID != main.id { await model.select(main.id) }
            _ = await wait(10) { model.displays[main.id]?.historyState == .ready || model.displays[main.id]?.historyState == .empty }
            let prompts = ["A large answer, please", "A large answer, please", "Write bulk 96 of history", "Please read fixture README.md"]
            let prompt = prompts[random.pick(prompts.count)]
            model.displays[main.id]?.draft = prompt; model.send(sessionID: main.id)
            var actions: [String] = []
            var gestureOpen = false
            _ = await wait(15) { model.displays[main.id]?.busy == true }
            while model.displays[main.id]?.busy == true || model.displays[main.id]?.hasWork == true {
                try await Task.sleep(for: .milliseconds(Int(40 + random.unit() * 400)))
                guard let scroll = launched.scroll else { continue }
                switch random.pick(9) {
                case 0:
                    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
                    gestureOpen = true; actions.append("gesture begins")
                case 1:
                    if gestureOpen { NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll); gestureOpen = false; actions.append("gesture ends") }
                case 2:
                    let clip = scroll.contentView, up = CGFloat(100 + random.unit() * 2000)
                    clip.scroll(to: NSPoint(x: 0, y: max(-scroll.contentInsets.top, clip.bounds.minY - up))); scroll.reflectScrolledClipView(clip)
                    actions.append(String(format: "scroll up %.0f", up))
                case 3:
                    let clip = scroll.contentView, height = scroll.documentView?.frame.height ?? 0
                    clip.scroll(to: NSPoint(x: 0, y: max(-scroll.contentInsets.top, height - clip.bounds.height))); scroll.reflectScrolledClipView(clip)
                    actions.append("scroll to bottom")
                case 4:
                    await model.select(other.id); actions.append("switch away")
                    try await Task.sleep(for: .milliseconds(Int(50 + random.unit() * 700)))
                    await model.select(main.id); actions.append("switch back")
                case 5:
                    launched.window.orderOut(nil); actions.append("window out")
                    try await Task.sleep(for: .milliseconds(Int(50 + random.unit() * 600)))
                    launched.window.makeKeyAndOrderFront(nil); actions.append("window in")
                case 6:
                    launched.window.resignKey(); actions.append("resign key")
                case 7:
                    model.error = model.error == nil ? "A notice elsewhere" : nil; actions.append("model change")
                default:
                    launched.draw()
                }
                if actions.count > 400 { break }
            }
            if gestureOpen, random.unit() < 0.5, let scroll = launched.scroll {
                NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll); gestureOpen = false; actions.append("gesture ends after the turn")
            }
            launched.window.makeKeyAndOrderFront(nil)
            _ = await wait(60) { self.quiet(model.displays[main.id]) }
            try await Task.sleep(for: .milliseconds(1500))
            launched.draw()
            let found = await layers(launched, chat: main.id)
            let whole = found.helper
            var wrong: [String] = []
            if found.display != whole { wrong.append("display") }
            if model.selectedID == main.id {
                if found.page != whole { wrong.append("page") }
                if found.row != nil, found.row != whole { wrong.append("row") }
                if found.rowHosted, let drawn = found.drawn, whole?.contains("paragraph 100") == true, !drawn.contains("paragraph 100") { wrong.append("drawn") }
            }
            let line = "turn \(turns) (\(prompt)): \(found)\(gestureOpen ? ", gesture left open" : "")"
            print("STREAM " + line)
            if !wrong.isEmpty {
                let summary = "turn \(turns): \(wrong.joined(separator: ", ")) short of the helper — \(found); last actions: \(actions.suffix(12).joined(separator: " · "))"
                print("STREAM MISMATCH " + summary)
                mismatches.append(summary)
            }
            if gestureOpen, let scroll = launched.scroll { NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll) }
            // Start the next turn from a chat shown as it now is.
            if !wrong.isEmpty { await model.select(other.id); await model.select(main.id) }
        }
        print("STREAM \(turns) turns, \(mismatches.count) mismatches, seed \(seed)")
        XCTAssertEqual(mismatches, [], "Every streamed reply ends on screen whole")
    }

    /// The reader holds text in a reply further up — the cursor in it after
    /// a click, or a selection to copy — while a reply streams into a chat
    /// whose window of rows is full. The reply goes on arriving and ends
    /// whole, and the row the reader holds stays on the page.
    @MainActor func testAReplyKeepsArrivingWhileTheReaderHoldsTextInAnOlderRow() async throws {
        let caps = TranscriptPaging.residentCaps
        TranscriptPaging.residentCaps = (rows: 8, bytes: caps.bytes)
        addTeardownBlock { TranscriptPaging.residentCaps = caps }
        let setup = try await setup()
        let launched = launch(setup)
        let model = launched.model
        await model.restore()
        model.selectedWorkspaceID = setup.workspace.id; model.profileChoice = setup.profile.id
        let chat = ChatRecord(id: "chat-held-" + UUID().uuidString, workspaceID: setup.workspace.id, title: "Held", path: nil, profileID: setup.profile.id)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.select(chat.id)
        // Four short turns: a page of eight rows, the window's whole budget.
        for index in 1...4 {
            model.displays[chat.id]?.draft = "And a short one \(index)"; model.send(sessionID: chat.id)
            let settled = await wait(60) { self.quiet(model.displays[chat.id]) && model.displays[chat.id]?.messages.last?.text.contains("short one \(index)") == true }
            XCTAssertTrue(settled, "Turn \(index) never settled")
        }
        let view = try XCTUnwrap(model.displays[chat.id])
        XCTAssertGreaterThanOrEqual(view.messages.count, 8, "The window is full")
        // The reader clicks into the first reply's text, as they do to select
        // and copy some of it: that row holds the cursor.
        let first = try XCTUnwrap(view.messages.first(where: { $0.role == "assistant" }))
        launched.draw()
        let held = try XCTUnwrap(launched.views(NativeMarkdownContainer.self).first { $0.readingIdentity == first.id || $0.textView.string.contains(first.text.prefix(20)) },
                                 "The first reply is drawn")
        launched.window.makeFirstResponder(held.textView)
        launched.draw()
        _ = await wait(2) { view.pinnedHistoryIDs.contains(first.id) }
        XCTAssertTrue(view.pinnedHistoryIDs.contains(first.id), "The row holding the cursor is kept on the page")
        // A long reply streams in: its turn's two rows need the window's room.
        launched.window.makeFirstResponder(held.textView)
        view.draft = "A large answer, please"
        model.send(sessionID: chat.id)
        launched.window.makeFirstResponder(held.textView)
        let finished = await wait(90) { self.quiet(model.displays[chat.id]) && model.displays[chat.id]?.messages.last?.text.contains("paragraph 100") == true }
        let found = await layers(launched, chat: chat.id)
        XCTAssertTrue(finished, "The reply ended on the page whole (\(found); browsing history \(view.browsingHistory))")
        XCTAssertEqual(found.display, found.helper, "The chat holds the reply the helper finished")
        XCTAssertEqual(found.page, found.helper, "The page draws the reply the helper finished")
        XCTAssertEqual(found.row, found.helper, "The reply's row holds all of it")
        XCTAssertFalse(view.browsingHistory, "The chat is still on its live tail")
        XCTAssertTrue(view.messages.contains { $0.id == first.id }, "The row the reader holds is still on the page")
        // Letting go of it trims the window back to its budget.
        launched.window.makeFirstResponder(nil); launched.draw()
        _ = await wait(2) { view.pinnedHistoryIDs.isEmpty }
        model.refresh(chat.id)
        _ = await wait(5) { !view.snapshotInFlight }
    }
}
