import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// Return, measured where the reader measures it: in the real window, with
/// the packaged helper and the synthetic gateway behind the chat, from the
/// key press to the frames that show its effects.
///
/// A timeline records, in milliseconds after Return:
/// - `cleared`: the composer on screen is empty;
/// - `drawn`: the reader's message is a drawn row of the transcript;
/// - `running`: the live turn bar is up;
/// - `helperRow`: the helper's own row for the message is the one drawn;
/// - every step the send passes (`WorkspaceModel.sendSteps`) and every
///   reply of the helper (`HostSupervisor.requestObserver`).
@MainActor final class SendBench {
    let model: WorkspaceModel
    let window: NSWindow
    let hosted: NSHostingView<WorkspaceView>
    let workspace: WorkspaceRecord
    let profile: ProfileRecord
    private(set) var chatID: String
    private let gateway: Process
    private let root: URL
    /// A 120 Hz display's frame, in seconds.
    static let frameInterval = 1.0 / 120

    init(width: CGFloat = 1280, height: CGFloat = 820, storage: ((Data) -> any VaultStorage)? = nil) async throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let script = repository.appendingPathComponent("fixtures/native/ui-gateway.py")
        guard FileManager.default.isReadableFile(atPath: script.path) else { throw XCTSkip("The synthetic gateway fixture is unavailable") }
        root = scratchRoot("send-latency")
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
        workspace = WorkspaceRecord(id: "latency-project", path: root.path, trusted: true)
        var profile = ProfileRecord()
        profile.api = "openai-responses"; profile.baseUrl = base; profile.modelId = "ui-fixture"; profile.catalogUrl = base + "/catalog"
        profile.name = "Fixture"; profile.contextWindow = 2_000_000; profile.maxOutputTokens = 300_000; profile.modelOutputLimit = 300_000
        self.profile = profile
        let makeStorage: (Data) -> any VaultStorage = storage ?? { MemoryVaultStorage($0) }
        var configuration = VaultConfiguration()
        configuration.workspaces = [workspace]
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-loopback-only-key")]
        configuration.automaticUpdateChecks = false
        configuration.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)])
        model = WorkspaceModel(stateRoot: root.appendingPathComponent("app-state"),
                               vault: ConfigurationVault(storage: makeStorage(try JSONEncoder().encode(configuration))))
        await model.restore()
        model.selectedWorkspaceID = workspace.id; model.profileChoice = profile.id
        let chat = ChatRecord(id: UUID().uuidString, workspaceID: workspace.id, title: "Latency", path: nil, profileID: profile.id)
        chatID = chat.id
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        await model.select(chat.id)
        await settle(20)
    }

    var session: SessionDisplay { model.displays[chatID] ?? SessionDisplay(id: chatID) }
    func views<T: NSView>(_ type: T.Type, in view: NSView? = nil) -> [T] {
        let view = view ?? hosted
        return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }
    var editor: ComposerTextView? { views(ComposerTextView.self).first { $0.sessionID == chatID } }
    var page: TranscriptPage? { views(TranscriptSurfaceMarker.self).first?.page }
    var scroll: NSScrollView? { views(TranscriptSurfaceMarker.self).first?.enclosingScrollView }
    var document: TranscriptNativeDocument? { scroll?.documentView as? TranscriptNativeDocument }
    var host: HostSupervisor? { model.hosts[workspace.id] }

    func draw() { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
    func settle(_ turns: Int = 12) async { for _ in 0..<turns { draw(); await Task.yield(); try? await Task.sleep(for: .milliseconds(15)) }; draw() }
    func waitUntil(_ what: String, seconds: Double = 90, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if condition() { return }; await settle(2) }
        XCTFail("\(what) (state \(session.state), notice “\(session.notice)”, failure “\(session.sendFailure ?? "")”)", file: file, line: line)
    }
    /// The chat has finished everything the last send started.
    var quiet: Bool {
        let view = session
        return !view.hasWork && !view.loading && view.messages.last?.role == "assistant" && view.messages.last?.isStreaming == false
    }
    func waitForQuiet(_ what: String = "The turn never finished", file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil(what, file: file, line: line) { quiet }
        await settle(6)
    }

    /// One keystroke through the editor's real responder path.
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
    func pressReturn(steering: Bool = false) { key("\r", keyCode: 36, modifiers: steering ? .command : []) }
    /// The frame a key press is drawn in: one pass of the run loop, where
    /// SwiftUI takes the state the press left, then layout and display.
    func frameAfterInput() async { await Task.yield(); try? await Task.sleep(for: .milliseconds(1)); draw() }

    /// Sends the way the model does when nobody is timing it, and waits for
    /// the whole turn.
    func sendAndWait(_ text: String) async {
        session.draft = text
        model.send(sessionID: chatID)
        await waitForQuiet("“\(text)” never finished")
    }

    /// Switches the bench to a chat the model has just made and selected.
    func follow(_ id: String) async {
        chatID = id
        await settle(10)
    }

    /// The row the reader's message is drawn as, if any: its container is
    /// mounted in the document and inside the visible part of the page.
    func drawnUserRow(text: String) -> (row: TranscriptRowContainer, message: TranscriptMessage)? {
        guard let document, let clip = scroll?.contentView else { return nil }
        let visible = document.convert(clip.bounds, from: clip)
        for row in document.retainedRows.reversed() {
            guard case .message(let message) = row.item, message.role == "user", message.text == text else { continue }
            guard row.superview === document, row.isHosted, !row.isHidden, row.frame.height > 0, row.frame.intersects(visible) else { return nil }
            return (row, message)
        }
        return nil
    }

    struct Timeline {
        var cleared: Double?
        var drawn: Double?
        var running: Double?
        var helperRow: Double?
        var rowInModel: Double?
        /// A new chat's sidebar row carries the message as its title.
        var titled: Double?
        /// What each frame's layout and display cost, in milliseconds: the
        /// frame after Return first.
        var frames: [Double] = []
        var steps: [String: Double] = [:]
        var replies: [(method: String, at: Double)] = []
        func reply(_ method: String) -> Double? { replies.first { $0.method == method }?.at }
        /// The snapshot that brought the helper's row: the last reply of a
        /// snapshot before the row was in the model.
        var rowSnapshot: Double? {
            guard let rowInModel else { return nil }
            return replies.filter { ["session.snapshot", "session.status"].contains($0.method) && $0.at <= rowInModel + 0.5 }.last?.at
        }
    }

    /// Types `text` into the composer, waits `pause`, presses Return, and
    /// watches every frame until the helper's own row is drawn and the turn
    /// is running (or has finished).
    func measure(_ text: String, pause: Duration = .zero, seconds: Double = 90) async -> Timeline {
        type(text)
        draw()
        if pause > .zero { let end = ContinuousClock.now + pause; while ContinuousClock.now < end { draw(); try? await Task.sleep(for: .milliseconds(15)) } }
        var timeline = Timeline()
        let newTitle = model.chatRecord(chatID)?.title == "New chat" ? String(text.prefix(60)).replacingOccurrences(of: "\n", with: " ") : nil
        let start = ProcessInfo.processInfo.systemUptime
        func now() -> Double { (ProcessInfo.processInfo.systemUptime - start) * 1000 }
        model.sendSteps = { step in if timeline.steps[step] == nil { timeline.steps[step] = now() } }
        let observed = host
        observed?.requestObserver = { method, _, _ in timeline.replies.append((method, now())) }
        defer { model.sendSteps = nil; observed?.requestObserver = nil }
        pressReturn()
        let deadline = Date().addingTimeInterval(seconds)
        // Frames on a display's cadence: the main thread is free between them,
        // as it is in the app, and a figure is the first frame that shows it.
        var frameStart = ProcessInfo.processInfo.systemUptime
        while Date() < deadline {
            let drawing = ProcessInfo.processInfo.systemUptime
            draw()
            timeline.frames.append((ProcessInfo.processInfo.systemUptime - drawing) * 1000)
            let at = now()
            if timeline.cleared == nil, editor?.string.isEmpty == true { timeline.cleared = at }
            if let shown = drawnUserRow(text: text) {
                if timeline.drawn == nil { timeline.drawn = at }
                if timeline.helperRow == nil, shown.message.state != "sending" { timeline.helperRow = at }
            }
            if timeline.running == nil, page?.liveTurn != nil { timeline.running = at }
            if timeline.titled == nil, let newTitle, model.chatRecord(chatID)?.title == newTitle { timeline.titled = at }
            if timeline.rowInModel == nil, session.messages.contains(where: { $0.role == "user" && $0.text == text }) { timeline.rowInModel = at }
            // The observer is attached to the helper that was running; a cold
            // start may have replaced the supervisor's process, not the object.
            if host !== observed, let current = host, current.requestObserver == nil {
                current.requestObserver = { method, _, _ in timeline.replies.append((method, now())) }
            }
            if timeline.cleared != nil, timeline.drawn != nil, timeline.helperRow != nil, timeline.running != nil || quiet,
               newTitle == nil || timeline.titled != nil { break }
            await Task.yield()
            let spent = ProcessInfo.processInfo.systemUptime - frameStart
            try? await Task.sleep(for: .microseconds(Int(max(0.5, SendBench.frameInterval * 1000 - spent * 1000) * 1000)))
            frameStart = ProcessInfo.processInfo.systemUptime
        }
        host?.requestObserver = nil
        return timeline
    }

    func close() async {
        for host in model.hosts.values { try? await host.shutdownAndWait() }
        try? await model.traces.close(); await model.store?.close()
        model.shutdown(); window.contentView = nil; window.close()
        if gateway.isRunning { gateway.terminate(); gateway.waitUntilExit() }
        try? FileManager.default.removeItem(at: root)
    }
}

/// A vault whose reads can be held, to see what a send does while Keychain answers.
final class GatedVaultStorage: VaultStorage, @unchecked Sendable {
    private let inner: MemoryVaultStorage
    private let lock = NSLock()
    private var gate: DispatchSemaphore?
    private var waiting = 0
    init(_ bytes: Data) { inner = MemoryVaultStorage(bytes) }
    var isHoldingRead: Bool { lock.lock(); defer { lock.unlock() }; return waiting > 0 }
    func hold() { lock.lock(); gate = DispatchSemaphore(value: 0); lock.unlock() }
    func release() { lock.lock(); let held = gate; gate = nil; lock.unlock(); held?.signal() }
    func read() throws -> Data? {
        lock.lock(); let held = gate; if held != nil { waiting += 1 }; lock.unlock()
        // Bounded: a test that never releases fails on its own assertions, not a hang.
        if let held { _ = held.wait(timeout: .now() + 20); lock.lock(); waiting -= 1; lock.unlock() }
        return try inner.read()
    }
    func replace(expected: Data?, with replacement: Data) throws { try inner.replace(expected: expected, with: replacement) }
}

final class SendLatencyTests: XCTestCase {
    /// A send to a chat whose project helper is not running starts that
    /// helper while the profile's credential is read, instead of after: the
    /// helper is up while the read is still held. The session, which is
    /// what takes the credential, opens only once the read has answered.
    @MainActor func testColdSendStartsTheHelperWhileTheCredentialIsRead() async throws {
        var gated: GatedVaultStorage?
        let bench = try await SendBench(storage: { bytes in let storage = GatedVaultStorage(bytes); gated = storage; return storage })
        let storage = try XCTUnwrap(gated)
        var closed = false
        defer { if !closed { storage.release(); Task { await bench.close() } } }
        // Nothing may be running yet: a helper started by selecting the chat
        // would make the send find it ready.
        if let host = bench.host, host.isReady { try await host.shutdownAndWait() }
        await bench.waitUntil("A previous helper never stopped", seconds: 10) { bench.host?.isReady != true && !bench.model.opened.contains(bench.chatID) }
        let item = try XCTUnwrap(bench.model.chatRecord(bench.chatID))
        storage.hold()
        let opening = Task { @MainActor in try await bench.model.open(item) }
        await bench.waitUntil("The helper did not start while the credential was read", seconds: 15) { bench.host?.isReady == true && bench.model.boundHostConnections[bench.workspace.id] != nil }
        XCTAssertTrue(storage.isHoldingRead, "The credential read was still held while the helper started")
        XCTAssertFalse(bench.model.opened.contains(bench.chatID), "No session opens before its credential is read")
        storage.release()
        _ = try await opening.value
        XCTAssertTrue(bench.model.opened.contains(bench.chatID))
        closed = true
        await bench.close()
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(); guard !sorted.isEmpty else { return .nan }
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
    private static func figure(_ values: [Double?]) -> String {
        let known = values.compactMap { $0 }
        guard !known.isEmpty else { return "n/a" }
        return String(format: "%.1f (max %.1f)", median(known), known.max() ?? 0)
    }
    private static func span(_ timeline: SendBench.Timeline, from: String?, to: String?) -> Double? {
        func point(_ name: String?) -> Double? {
            guard let name else { return 0 }
            if name.hasPrefix("reply:") { return timeline.reply(String(name.dropFirst(6))) }
            if name == "rowSnapshot" { return timeline.rowSnapshot }
            if name == "helperRow" { return timeline.helperRow }
            return timeline.steps[name]
        }
        guard let a = point(from), let b = point(to), b >= a else { return nil }
        return b - a
    }
    /// One PERF block per scenario: what the reader sees, then where the time went.
    private func report(_ scenario: String, _ samples: [SendBench.Timeline], breakdown: [(String, String?, String?)]) {
        print("PERF send.\(scenario) samples=\(samples.count) composerCleared=\(Self.figure(samples.map(\.cleared)))ms messageDrawn=\(Self.figure(samples.map(\.drawn)))ms running=\(Self.figure(samples.map(\.running)))ms helperRowDrawn=\(Self.figure(samples.map(\.helperRow)))ms")
        print("PERF send.\(scenario).frames firstFrame=\(Self.figure(samples.map(\.frames.first)))ms frame=\(Self.figure(samples.flatMap(\.frames).map { Optional($0) }))ms")
        let parts = breakdown.map { name, from, to in "\(name)=\(Self.figure(samples.map { Self.span($0, from: from, to: to) }))" }
        print("PERF send.\(scenario).steps " + parts.joined(separator: " "))
        for (index, sample) in samples.enumerated() {
            let steps = sample.steps.sorted { $0.value < $1.value }.map { String(format: "%@@%.1f", $0.key, $0.value) }.joined(separator: " ")
            let replies = sample.replies.map { String(format: "%@@%.1f", $0.method, $0.at) }.joined(separator: " ")
            print("PERF send.\(scenario).sample\(index) steps: \(steps) | replies: \(replies)")
        }
    }
    /// Where a send's milliseconds go, step by step, in every configuration
    /// of the helper a reader meets: warm with a short chat, warm with a long
    /// one, stopped for being idle, and a new chat's first message.
    ///
    /// Opt-in (`PI_PERF_SEND_LATENCY=1`): it seeds a long chat through the
    /// gateway and waits out idle stops, which takes a minute or two.
    @MainActor func testSendLatencyAcrossHelperStates() async throws {
        guard testEnvironment("PI_PERF_SEND_LATENCY") != nil else { throw XCTSkip("Set PI_PERF_SEND_LATENCY=1 to time Return in every helper state") }
        let samples = Int(testEnvironment("PI_PERF_SEND_SAMPLES") ?? "") ?? 5
        let seedTurns = Int(testEnvironment("PI_PERF_SEND_SEED_TURNS") ?? "") ?? 150
        let bench = try await SendBench()
        var closed = false
        defer { if !closed { Task { await bench.close() } } }
        print("PERF send.process pid=\(ProcessInfo.processInfo.processIdentifier)")
        let warmSteps: [(String, String?, String?)] = [
            ("materialize", "accepted", "materialized"), ("draftWrite", "materialized", "draftWritten"),
            ("open", "draftWritten", "opened"), ("intentWrite", "opened", "intentWritten"),
            ("durable", nil, "durable"), ("dispatch", nil, "dispatched"),
            ("submitRoundTrip", "intentWritten", "submitted"), ("submitRoundTrip*", "dispatched", "submitted"),
            ("ackWrite", "submitted", "acknowledged"), ("titleWrite", "acknowledged", "titled"),
            ("rowSnapshot", nil, "rowSnapshot"), ("snapshotToPaint", "rowSnapshot", "helperRow")]
        let coldSteps = warmSteps + [
            ("spawn+workspace.open", "draftWritten", "reply:workspace.open"), ("spawn+workspace.open*", "prewarm", "reply:workspace.open"),
            ("session.open", "reply:workspace.open", "reply:session.open")]

        // The first message after launch: no session, and a helper that only
        // the typing before Return has started.
        let first = await bench.measure("First message after launch")
        await bench.waitForQuiet()
        report("firstAfterLaunch", [first], breakdown: coldSteps)

        // Warm helper, short chat.
        var warm: [SendBench.Timeline] = []
        for index in 0..<samples {
            warm.append(await bench.measure("Warm short chat \(index)"))
            await bench.waitForQuiet()
        }
        report("warmSmall", warm, breakdown: warmSteps)

        // Warm helper, long chat: seeded through the gateway, then read back
        // into the page so it holds hundreds of rows.
        let seeding = ProcessInfo.processInfo.systemUptime
        for index in 0..<seedTurns { await bench.sendAndWait("Seed \(index)") }
        var loads = 0
        while bench.session.olderPage.cursor != nil, bench.session.messages.count < 2 * seedTurns, loads < 200 {
            _ = await bench.model.loadEarlierPage(sessionID: bench.chatID); loads += 1
        }
        await bench.settle(20)
        print("PERF send.largeChat seeded=\(seedTurns) turns rows=\(bench.session.messages.count) loads=\(loads) seconds=\(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - seeding))")
        var large: [SendBench.Timeline] = []
        for index in 0..<max(1, samples - 2) {
            large.append(await bench.measure("Warm long chat \(index)"))
            await bench.waitForQuiet()
        }
        report("warmLarge", large, breakdown: warmSteps)

        // Cold helper: stopped for being idle, then typed into and sent at once.
        bench.model.configuration.runtime.idleGraceSeconds = 1
        var cold: [SendBench.Timeline] = [], coldPaused: [SendBench.Timeline] = []
        for index in 0..<max(1, samples - 2) {
            for pause in [Duration.zero, .seconds(1)] {
                if let host = bench.host { bench.model.scheduleIdle(workspaceID: bench.workspace.id, host: host) }
                await bench.waitUntil("The idle helper never stopped", seconds: 30) { bench.host?.isReady != true && !bench.model.opened.contains(bench.chatID) }
                await bench.settle(4)
                let sample = await bench.measure(pause == .zero ? "Cold helper \(index)" : "Cold helper after a pause \(index)", pause: pause)
                if pause == .zero { cold.append(sample) } else { coldPaused.append(sample) }
                await bench.waitForQuiet()
            }
        }
        report("coldImmediate", cold, breakdown: coldSteps)
        report("coldAfterPause", coldPaused, breakdown: coldSteps)
        bench.model.configuration.runtime.idleGraceSeconds = 120
        if let host = bench.host { bench.model.scheduleIdle(workspaceID: bench.workspace.id, host: host) }

        // A brand-new chat's first message, with the project's helper warm.
        var fresh: [SendBench.Timeline] = []
        for index in 0..<max(1, samples - 2) {
            if bench.host?.isReady != true { await bench.sendAndWait("Rewarm \(index)") }
            let previous = bench.model.selectedID
            bench.model.newChat()
            await bench.waitUntil("New Chat never opened a pending chat", seconds: 20) {
                bench.model.selectedID != previous && bench.model.selectedID.map { bench.model.pendingChatIDs.contains($0) } == true
            }
            await bench.follow(try XCTUnwrap(bench.model.selectedID))
            fresh.append(await bench.measure("First message of a new chat \(index)"))
            await bench.waitForQuiet()
        }
        report("newChat", fresh, breakdown: warmSteps + [("session.open", "materialized", "reply:session.open")])
        print("PERF send.newChat sidebarTitle=\(Self.figure(fresh.map(\.titled)))ms")
        closed = true
        await bench.close()
    }
}
