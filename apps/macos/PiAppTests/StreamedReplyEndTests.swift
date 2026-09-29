import XCTest
import SwiftUI
import AppKit
import Combine
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

    /// `slowWords`: how long a "slow" reply is (`PI_APP_UI_FIXTURE_SLOW_WORDS`),
    /// streamed at a word or so every 0.8 s.
    @MainActor private func setup(slowWords: Int? = nil) async throws -> Setup {
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
        if let slowWords { gateway.environment?["PI_APP_UI_FIXTURE_SLOW_WORDS"] = String(slowWords) }
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
        // A smaller window fills in a few turns: PI_STREAM_STRESS_CAP_ROWS.
        if let rows = testEnvironment("PI_STREAM_STRESS_CAP_ROWS").flatMap(Int.init) {
            let caps = TranscriptPaging.residentCaps
            TranscriptPaging.residentCaps = (rows: rows, bytes: caps.bytes)
            addTeardownBlock { TranscriptPaging.residentCaps = caps }
            print("STREAM window of \(rows) rows")
        }
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
        var turns = 0, mismatches: [String] = [], readBack = 0, filled = 0
        var firstRow: String?
        while ProcessInfo.processInfo.systemUptime < deadline {
            turns += 1
            if model.selectedID != main.id { await model.select(main.id) }
            _ = await wait(10) { model.displays[main.id]?.historyState == .ready || model.displays[main.id]?.historyState == .empty }
            let prompts = ["A large answer, please", "A large answer, please", "Write bulk 96 of history", "Please read fixture README.md"]
            let prompt = prompts[random.pick(prompts.count)]
            model.displays[main.id]?.draft = prompt; model.send(sessionID: main.id)
            var actions: [String] = []
            var gestureOpen = false
            // Whether the reader read earlier rows during the turn: only such a
            // read may leave the chat reading back past its window's start.
            var readEarlier = false
            var watching: Set<AnyCancellable> = []
            model.displays[main.id]?.$olderPage.sink { if $0.loading { readEarlier = true } }.store(in: &watching)
            _ = await wait(15) { model.displays[main.id]?.busy == true }
            while model.displays[main.id]?.busy == true || model.displays[main.id]?.hasWork == true {
                try await Task.sleep(for: .milliseconds(Int(40 + random.unit() * 400)))
                guard let scroll = launched.scroll else { continue }
                switch random.pick(12) {
                case 11:
                    // The reader reads near the window's start, clear of the
                    // band that reads earlier rows: the rows the next turn
                    // pushes out of a full window are the ones they are on.
                    let into = CGFloat(300 + random.unit() * 400)
                    readerScrolls(launched, to: -scroll.contentInsets.top + into)
                    actions.append(String(format: "read %.0f from the window's start", into))
                case 9:
                    // The reader clicks into an earlier reply's text, as to
                    // select and copy some of it.
                    let streaming = model.displays[main.id]?.messages.last(where: { $0.role == "assistant" })?.id
                    let surfaces = launched.views(NativeMarkdownContainer.self).filter { $0.readingIdentity != nil && $0.readingIdentity != streaming }
                    if !surfaces.isEmpty {
                        launched.window.makeFirstResponder(surfaces[random.pick(surfaces.count)].textView); actions.append("hold an earlier reply")
                    }
                case 10:
                    launched.window.makeFirstResponder(nil); actions.append("let go")
                case 0:
                    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
                    gestureOpen = true; actions.append("gesture begins")
                case 1:
                    if gestureOpen { NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll); gestureOpen = false; actions.append("gesture ends") }
                case 2:
                    let up = CGFloat(100 + random.unit() * 2000)
                    readerScrolls(launched, to: max(-scroll.contentInsets.top, scroll.contentView.bounds.minY - up))
                    actions.append(String(format: "scroll up %.0f", up))
                case 3:
                    let height = scroll.documentView?.frame.height ?? 0
                    readerScrolls(launched, to: max(-scroll.contentInsets.top, height - scroll.contentView.bounds.height))
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
            let view = model.displays[main.id]
            if firstRow == nil { firstRow = view?.messages.first?.id }
            if let view, view.browsingHistory {
                // Only a reader who read back past the window's start leaves
                // its live tail: the newest rows made room for the earlier
                // ones, and wait behind the newer edge. A chat that stopped
                // taking the helper's rows without that is the bug.
                if readEarlier && view.newerPage.available { readBack += 1 }
                else { wrong.append("live tail disconnected\(readEarlier ? " with no newer edge" : "")") }
            } else {
                if found.display != whole { wrong.append("display") }
                if model.selectedID == main.id {
                    if found.page != whole { wrong.append("page") }
                    if found.row != nil, found.row != whole { wrong.append("row") }
                    if found.rowHosted, let drawn = found.drawn, whole?.contains("paragraph 100") == true, !drawn.contains("paragraph 100") { wrong.append("drawn") }
                }
            }
            // Every row of the chat can be scrolled back to.
            if let view, let firstRow, !view.messages.contains(where: { $0.id == firstRow }) {
                filled += 1
                if !view.olderPage.available { wrong.append("earlier rows unreachable") }
            }
            let line = "turn \(turns) (\(prompt)): \(found), rows \(view?.messages.count ?? 0)\(view?.browsingHistory == true ? ", read back" : "")\(gestureOpen ? ", gesture left open" : "")"
            print("STREAM " + line)
            if !wrong.isEmpty {
                let summary = "turn \(turns): \(wrong.joined(separator: ", ")) short of the helper — \(found); last actions: \(actions.suffix(12).joined(separator: " · "))"
                print("STREAM MISMATCH " + summary)
                mismatches.append(summary)
            }
            withExtendedLifetime(watching) {}
            if gestureOpen, let scroll = launched.scroll { NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll) }
            // Start the next turn from a chat shown as it now is: a reader
            // who read back returns to the latest reply, as Jump to latest does.
            if !wrong.isEmpty { await model.select(other.id); await model.select(main.id) }
            else if view?.browsingHistory == true {
                launched.window.makeFirstResponder(nil)
                model.latest(sessionID: main.id)
                _ = await wait(15) { model.displays[main.id]?.historyState == .ready && model.displays[main.id]?.browsingHistory == false }
            }
        }
        print("STREAM \(turns) turns, \(mismatches.count) mismatches, \(filled) turns with rows past the window's start, \(readBack) read back past it, seed \(seed)")
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

    /// What the display and the helper say about a chat, when a turn will not settle.
    @MainActor private func diagnose(_ model: WorkspaceModel, chat: String) async -> String {
        guard let view = model.displays[chat] else { return "no display" }
        let last = view.messages.last
        var helper = "helper ?"
        if let item = model.record(chat), let host = model.hosts[item.workspaceID],
           let result = try? await host.request("session.status", sessionID: chat, params: [:]).object {
            helper = "helper state \(result["state"]?.string ?? "?"), run \(result["runStatus"]?.string ?? "?"), seq \(result["seq"]?.number ?? -1), queue \(result["queueCount"]?.number ?? -1)"
        }
        return "display state \(view.state), busy \(view.busy), loading \(view.loading), hasWork \(view.hasWork), sending \(view.sendingRows.count), queue \(view.queue.count), active task \(view.taskPresentation?.active != nil), last \(last?.role ?? "-")/\(last?.state ?? "-") \"\(String((last?.text ?? "").prefix(40)))\", rows \(view.messages.count), browsing \(view.browsingHistory), inFlight \(view.snapshotInFlight), lastSeq \(view.lastSequence), opened \(model.opened.contains(chat)); \(helper); pinned \(view.pinnedHistoryIDs), anchor \(String(describing: view.scrollAnchor))"
    }

    /// Where each row on screen sits in the viewport.
    @MainActor private func placesOnScreen(_ launched: Launched) -> [String: CGFloat] {
        guard let document = launched.document, let clip = launched.scroll?.contentView else { return [:] }
        let visible = document.convert(clip.bounds, from: clip)
        var places: [String: CGFloat] = [:]
        for row in document.retainedRows where row.superview === document && row.isHosted && !row.isHidden && row.frame.intersects(visible) {
            places[row.itemID] = row.frame.minY - visible.minY
        }
        return places
    }

    /// The reader scrolls: a gesture that begins, moves the page and ends,
    /// as a trackpad's does.
    @MainActor private func readerScrolls(_ launched: Launched, to y: CGFloat) {
        guard let scroll = launched.scroll as? TranscriptNativeScrollView else { return }
        let clip = scroll.contentView
        scroll.readerWillNavigate(upward: y < clip.bounds.minY)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        clip.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    }

    /// Sends `prompt` in `chat` and waits for its turn to settle on a new
    /// reply that reads as `whole` says.
    @MainActor private func turn(_ model: WorkspaceModel, chat: String, _ prompt: String, whole: @escaping (String) -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let previous = model.displays[chat]?.messages.last(where: { $0.role == "assistant" })?.id
        model.displays[chat]?.draft = prompt; model.send(sessionID: chat)
        let settled = await wait(60) {
            guard self.quiet(model.displays[chat]), let reply = model.displays[chat]?.messages.last(where: { $0.role == "assistant" }) else { return false }
            return reply.id != previous && whole(reply.text)
        }
        if !settled { XCTFail("“\(prompt)” never settled: \(await diagnose(model, chat: chat))", file: file, line: line) }
    }

    @MainActor private func chat(_ setup: Setup, _ model: WorkspaceModel, title: String) async throws -> ChatRecord {
        await model.restore()
        model.selectedWorkspaceID = setup.workspace.id; model.profileChoice = setup.profile.id
        let chat = ChatRecord(id: "chat-" + title.lowercased() + "-" + UUID().uuidString, workspaceID: setup.workspace.id, title: title, path: nil, profileID: setup.profile.id)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.select(chat.id)
        return chat
    }

    /// A chat read from its first row grows past its window while the reader
    /// follows it, on a page too short to scroll. The rows that leave the
    /// window's start wait behind the earlier edge's control, and the chat
    /// stays on its live tail: filling a full window with them on its own
    /// would push out the rows on screen, the reply being written among them.
    @MainActor func testAShortPageThatLostRowsOffersThemAndStaysLive() async throws {
        let caps = TranscriptPaging.residentCaps
        TranscriptPaging.residentCaps = (rows: 8, bytes: caps.bytes)
        addTeardownBlock { TranscriptPaging.residentCaps = caps }
        let setup = try await setup()
        let launched = launch(setup)
        let model = launched.model
        let chat = try await chat(setup, model, title: "Short")
        for index in 1...6 { await turn(model, chat: chat.id, "And a short one \(index)", whole: { $0.contains("short one \(index)") && $0.hasSuffix("café.") }) }
        let view = try XCTUnwrap(model.displays[chat.id])
        let firstQuestion = { (rows: [TranscriptMessage]) in rows.contains { $0.role == "user" && $0.text.hasSuffix("short one 1") } }
        XCTAssertTrue(view.messages.last(where: { $0.role == "assistant" })?.text.contains("short one 6") == true, "Every reply arrived")
        XCTAssertFalse(view.browsingHistory, "The chat stayed on its live tail")
        XCTAssertFalse(firstQuestion(view.messages), "The first turn has left the window")
        XCTAssertNotNil(view.olderPage.cursor, "The rows that left have an earlier edge")
        launched.draw()
        _ = await wait(2) { launched.page?.earlierWaitsForReader == true }
        XCTAssertTrue(launched.page?.earlierWaitsForReader == true, "The edge offers them to the reader")
        // The reader presses the edge's control until the chat's first turn
        // is back: each press reads one page, a few turns, before the edge.
        for _ in 0..<6 where !firstQuestion(view.messages) {
            guard view.olderPage.cursor != nil, view.olderPage.error == nil else { break }
            _ = await model.loadEarlierPage(sessionID: chat.id)
        }
        if !firstQuestion(view.messages) { XCTFail("The edge reads the first turn back: \(await diagnose(model, chat: chat.id)); error \(view.olderPage.error ?? "none")") }
        XCTAssertNil(view.olderPage.cursor, "The chat's first row is reached")
    }

    /// A long chat read from its first row grows past its window while the
    /// reader follows it. Scrolling up to the top reads the rows that left
    /// the window's start back through the earlier edge, and doing so does
    /// not move the rows on screen. Before, a window that had held every row
    /// kept no edge, and those rows came back only when the chat was opened
    /// again.
    @MainActor func testRowsThatLeaveTheWindowAsAChatGrowsCanBeScrolledBackTo() async throws {
        let caps = TranscriptPaging.residentCaps
        TranscriptPaging.residentCaps = (rows: 6, bytes: caps.bytes)
        addTeardownBlock { TranscriptPaging.residentCaps = caps }
        let setup = try await setup()
        let launched = launch(setup)
        let model = launched.model
        let chat = try await chat(setup, model, title: "Tall")
        // Three long replies: a page taller than the window, nine rows
        // through a window of six.
        for _ in 1...3 { await turn(model, chat: chat.id, "Write bulk 24 of history", whole: { $0.hasPrefix("Fixture bulk reply.") && $0.utf8.count >= 24 * 1024 }) }
        let view = try XCTUnwrap(model.displays[chat.id])
        let firstRows = view.messages.map(\.id)
        XCTAssertEqual(firstRows.count, 6, "The window holds its six newest rows")
        XCTAssertNotNil(view.olderPage.cursor, "The rows that left have an earlier edge")
        XCTAssertFalse(view.browsingHistory, "The chat is on its live tail")
        // The reader scrolls up to the top; the edge reads the rows back.
        launched.draw()
        readerScrolls(launched, to: -(launched.scroll?.contentInsets.top ?? 0))
        launched.draw()
        try await Task.sleep(for: .milliseconds(100)); launched.draw()
        let before = placesOnScreen(launched)
        let read = await wait(15) { view.messages.first?.id != firstRows.first && !view.olderPage.loading && view.olderPage.cursor == nil }
        if !read { XCTFail("Scrolling up reads the first turn back (edge \(String(describing: view.olderPage.cursor?.entry)), error \(view.olderPage.error ?? "none")): \(await diagnose(model, chat: chat.id))") }
        XCTAssertTrue(view.messages.contains { $0.role == "user" } && view.messages.first?.role == "user", "The chat's first question is back at the top")
        try await Task.sleep(for: .milliseconds(400))
        launched.draw()
        let after = placesOnScreen(launched)
        var moved: [String] = []
        for (id, y) in before { if let now = after[id], abs(now - y) > 0.5 { moved.append(String(format: "%@ %.1f → %.1f", String(id.prefix(12)), y, now)) } }
        XCTAssertFalse(before.isEmpty, "Rows were on screen at the top")
        XCTAssertEqual(moved, [], "Reading the earlier rows back does not move the rows on screen")
        XCTAssertEqual(Set(before.keys).subtracting(after.keys), [], "The rows on screen stay on screen")
    }

    /// The reader reads back past a full window's start while a reply is
    /// being written, and the newest rows, the reply among them, make room
    /// for the earlier ones. Coming back to the end reads the rows after the
    /// window in, below the reader, and the reply joins them and goes on
    /// arriving where they are reading: nothing pressed, and no row on screen
    /// moving while the rows join. Before, the end offered "Load newer
    /// messages", and the reply looked as if it had stopped until it was
    /// pressed or the chat was opened again.
    @MainActor func testAReplyReadBackPastTheWindowGoesOnWhenTheReaderComesBack() async throws {
        let caps = TranscriptPaging.residentCaps
        TranscriptPaging.residentCaps = (rows: 24, bytes: caps.bytes)
        addTeardownBlock { TranscriptPaging.residentCaps = caps }
        let setup = try await setup(slowWords: 160)
        let launched = launch(setup)
        let model = launched.model
        let chat = try await chat(setup, model, title: "Back")
        for index in 1...10 { await turn(model, chat: chat.id, "And a short one \(index)", whole: { $0.contains("short one \(index)") && $0.hasSuffix("café.") }) }
        let view = try XCTUnwrap(model.displays[chat.id])
        XCTAssertNotNil(view.olderPage.cursor, "The window is full")
        // A slow reply starts, and is being written.
        view.draft = "slow: walk through it"; model.send(sessionID: chat.id)
        let started = await wait(30) { view.messages.last?.role == "assistant" && view.messages.last?.isStreaming == true && (view.messages.last?.text.count ?? 0) > 60 }
        if !started { XCTFail("The slow reply started: \(await diagnose(model, chat: chat.id))") }
        let reply = try XCTUnwrap(view.messages.last).id
        // The reader reads back to the window's start: the page reads the rows
        // before it, and the reply makes room for them.
        launched.draw()
        for _ in 0..<6 where !view.browsingHistory {
            readerScrolls(launched, to: -(launched.scroll?.contentInsets.top ?? 0))
            _ = await wait(5) { view.browsingHistory }
            launched.draw()
        }
        if !view.browsingHistory { XCTFail("Reading back past the window's start left the live tail: \(await diagnose(model, chat: chat.id))") }
        XCTAssertFalse(view.messages.contains { $0.id == reply }, "The reply being written made room")
        XCTAssertTrue(view.busy, "The reply is still being written")
        // The reader comes back to the end, pressing nothing, as often as it
        // takes. What is on screen as each read starts stays where it is as
        // its rows join.
        var moved: [String] = [], returns = 0
        while (view.browsingHistory || !view.messages.contains(where: { $0.id == reply })) && returns < 12 {
            returns += 1
            let last = view.messages.last?.id
            let bottom = max(0, (launched.scroll?.documentView?.frame.height ?? 0) - (launched.scroll?.contentView.bounds.height ?? 0))
            readerScrolls(launched, to: bottom)
            launched.draw()
            let before = placesOnScreen(launched)
            _ = await wait(10) { view.messages.last?.id != last || view.newerPage.error != nil }
            try await Task.sleep(for: .milliseconds(200)); launched.draw()
            let after = placesOnScreen(launched)
            for (id, y) in before {
                if let now = after[id] { if abs(now - y) > 0.5 { moved.append(String(format: "return %d: %@ %.1f → %.1f", returns, String(id.prefix(12)), y, now)) } }
                else { moved.append("return \(returns): \(id.prefix(12)) left the screen") }
            }
            if let error = view.newerPage.error { XCTFail("A newer read failed: \(error)"); break }
        }
        if view.browsingHistory { XCTFail("Coming back to the end rejoined the live tail (\(returns) returns): \(await diagnose(model, chat: chat.id))") }
        XCTAssertTrue(view.messages.contains { $0.id == reply }, "The reply is back in the window")
        XCTAssertEqual(moved, [], "No row on screen moves while the rows after it join")
        // The reply goes on arriving where the reader is.
        let now = view.messages.first { $0.id == reply }?.text.count ?? 0
        let grew = await wait(20) { (view.messages.first { $0.id == reply }?.text.count ?? 0) > now }
        if !grew { XCTFail("The reply goes on arriving: \(await diagnose(model, chat: chat.id))") }
        let ended = await wait(90) { self.quiet(model.displays[chat.id]) }
        if !ended { XCTFail("The reply ended: \(await diagnose(model, chat: chat.id))") }
        let found = await layers(launched, chat: chat.id)
        XCTAssertEqual(found.display, found.helper, "The chat holds the whole reply: \(found)")
        XCTAssertEqual(found.page, found.helper, "The page draws the whole reply: \(found)")
    }
}
