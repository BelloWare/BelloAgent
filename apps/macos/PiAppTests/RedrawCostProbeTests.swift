import XCTest
import SwiftUI
import AppKit
import Combine
@testable import PiApp

/// What the window costs the main thread: a streamed reply, typing, a chat
/// switch and a change to the workspace, with the synthetic gateway and a
/// real window. A probe, not a guard: it prints `REDRAW`, `TYPING`, `SWITCH`,
/// `CHANGE` and `WHERE` lines and asserts nothing about them, and it runs only
/// when `PI_REDRAW_PROBE=1` (pass `TEST_RUNNER_PI_REDRAW_PROBE=1`). Measure in
/// a Release build: Debug overstates the app's own code. `PI_REDRAW_SECONDS`
/// keeps a loop running long enough to sample, and `PI_PROBE_MARK` names a
/// file written when the measured part begins. `WorkspaceRedrawTests` is the
/// guard for what this found.
final class RedrawCostProbeTests: XCTestCase, SerialTestLane {
    override func setUp() async throws {
        guard testEnvironment("PI_REDRAW_PROBE") == "1" else { throw XCTSkip("Set PI_REDRAW_PROBE=1 to run the redraw cost probe") }
    }

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
        let root = scratchRoot("redraw-cost")
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
        let workspace = WorkspaceRecord(id: "chat-load-project", path: root.appendingPathComponent("project").path, trusted: true)
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
        var scroll: NSScrollView? { views(TranscriptSurfaceMarker.self).first?.enclosingScrollView }
        var document: TranscriptNativeDocument? { scroll?.documentView as? TranscriptNativeDocument }
    }

    /// A launch: a new model over the same state, in a window, restored as the app does.
    @MainActor private func launch(_ setup: Setup) async -> Launched {
        let model = WorkspaceModel(stateRoot: setup.state, vault: setup.vault)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted: NSView = testEnvironment("PI_PROBE_REDUCE_MOTION") == "1"
            ? NSHostingView(rootView: WorkspaceView(model: model).environment(\.piReduceMotion, true)) : NSHostingView(rootView: WorkspaceView(model: model))
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

    @MainActor private func waitFor(_ what: String, seconds: Double = 60, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(what, file: file, line: line)
    }

    @MainActor private func quiet(_ view: SessionDisplay?) -> Bool {
        guard let view else { return false }
        return !view.hasWork && !view.loading && !view.busy && view.state == "idle" && view.taskPresentation?.active == nil
            && view.sendingRows.isEmpty && view.queue.isEmpty && view.messages.last?.role == "assistant" && view.messages.last?.isStreaming == false
    }


    private static func mainThreadCPU() -> Double {
        var time = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
    }


    /// Every assignment to one of the model's published properties, by name.
    @MainActor private func tallyChanges(_ model: WorkspaceModel, into subscriptions: inout Set<AnyCancellable>, _ tally: @escaping (String) -> Void) {
        model.$workspaces.dropFirst().sink { _ in tally("workspaces") }.store(in: &subscriptions)
        model.$chats.dropFirst().sink { _ in tally("chats") }.store(in: &subscriptions)
        model.$unreadStates.dropFirst().sink { _ in tally("unreadStates") }.store(in: &subscriptions)
        model.$profiles.dropFirst().sink { _ in tally("profiles") }.store(in: &subscriptions)
        model.$selectedID.dropFirst().sink { _ in tally("selectedID") }.store(in: &subscriptions)
        model.$focusedSessionID.dropFirst().sink { _ in tally("focusedSessionID") }.store(in: &subscriptions)
        model.$selected.dropFirst().sink { _ in tally("selected") }.store(in: &subscriptions)
        model.$error.dropFirst().sink { _ in tally("error") }.store(in: &subscriptions)
        model.$missingProjectFolders.dropFirst().sink { _ in tally("missingProjectFolders") }.store(in: &subscriptions)
        model.$showProfiles.dropFirst().sink { _ in tally("showProfiles") }.store(in: &subscriptions)
        model.$profileChoice.dropFirst().sink { _ in tally("profileChoice") }.store(in: &subscriptions)
        model.$selectedWorkspaceID.dropFirst().sink { _ in tally("selectedWorkspaceID") }.store(in: &subscriptions)
        model.$launchReveal.dropFirst().sink { _ in tally("launchReveal") }.store(in: &subscriptions)
        model.$showArchivedSessions.dropFirst().sink { _ in tally("showArchivedSessions") }.store(in: &subscriptions)
        model.$collapsedSidebarSides.dropFirst().sink { _ in tally("collapsedSidebarSides") }.store(in: &subscriptions)
        model.$sidebarPageSizes.dropFirst().sink { _ in tally("sidebarPageSizes") }.store(in: &subscriptions)
        model.$markedSessionIDs.dropFirst().sink { _ in tally("markedSessionIDs") }.store(in: &subscriptions)
        model.$showGit.dropFirst().sink { _ in tally("showGit") }.store(in: &subscriptions)
        model.$terminalVisible.dropFirst().sink { _ in tally("terminalVisible") }.store(in: &subscriptions)
        model.$renameTarget.dropFirst().sink { _ in tally("renameTarget") }.store(in: &subscriptions)
        model.$projectSidebarStates.dropFirst().sink { _ in tally("projectSidebarStates") }.store(in: &subscriptions)
        model.$topics.dropFirst().sink { _ in tally("topics") }.store(in: &subscriptions)
        model.$topicEditor.dropFirst().sink { _ in tally("topicEditor") }.store(in: &subscriptions)
        model.$webhookPreviewTarget.dropFirst().sink { _ in tally("webhookPreviewTarget") }.store(in: &subscriptions)
        model.$settingsSection.dropFirst().sink { _ in tally("settingsSection") }.store(in: &subscriptions)
        model.$workspaceChangesInFlight.dropFirst().sink { _ in tally("workspaceChangesInFlight") }.store(in: &subscriptions)
        model.$installPreparing.dropFirst().sink { _ in tally("installPreparing") }.store(in: &subscriptions)
        model.$showConversationContent.dropFirst().sink { _ in tally("showConversationContent") }.store(in: &subscriptions)
        model.$page.dropFirst().sink { _ in tally("page") }.store(in: &subscriptions)
        model.$showResources.dropFirst().sink { _ in tally("showResources") }.store(in: &subscriptions)
        model.$showWorkspaceManager.dropFirst().sink { _ in tally("showWorkspaceManager") }.store(in: &subscriptions)
        model.$resourceCatalog.dropFirst().sink { _ in tally("resourceCatalog") }.store(in: &subscriptions)
        model.$resourceCatalogWorkspaceID.dropFirst().sink { _ in tally("resourceCatalogWorkspaceID") }.store(in: &subscriptions)
        model.$resourceCatalogSessionID.dropFirst().sink { _ in tally("resourceCatalogSessionID") }.store(in: &subscriptions)
        model.$resourceTargetSessionID.dropFirst().sink { _ in tally("resourceTargetSessionID") }.store(in: &subscriptions)
        model.$sides.dropFirst().sink { _ in tally("sides") }.store(in: &subscriptions)
        model.$resourceLoading.dropFirst().sink { _ in tally("resourceLoading") }.store(in: &subscriptions)
        model.$resourceNotice.dropFirst().sink { _ in tally("resourceNotice") }.store(in: &subscriptions)
        model.$configuration.dropFirst().sink { _ in tally("configuration") }.store(in: &subscriptions)
        model.$configurationLoaded.dropFirst().sink { _ in tally("configurationLoaded") }.store(in: &subscriptions)
        model.$launching.dropFirst().sink { _ in tally("launching") }.store(in: &subscriptions)
    }

    @MainActor func testWhatAStreamedReplyCosts() async throws {
        let setup = try await setup()
        let launched = await launch(setup)
        let model = launched.model
        await model.restore()
        model.selectedWorkspaceID = setup.workspace.id; model.profileChoice = setup.profile.id
        let chat = ChatRecord(id: "chat-" + UUID().uuidString, workspaceID: setup.workspace.id, title: "Cost", path: nil, profileID: setup.profile.id)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.select(chat.id)
        let view = try XCTUnwrap(model.displays[chat.id])
        view.draft = "A short question"; model.send(sessionID: chat.id)
        await waitFor("The first turn never finished") { quiet(model.displays[chat.id]) }
        try await Task.sleep(for: .milliseconds(800))

        var modelChanges = 0, displayChanges = 0, footerChanges = 0
        var subscriptions: Set<AnyCancellable> = []
        model.objectWillChange.sink { _ in modelChanges += 1 }.store(in: &subscriptions)
        view.objectWillChange.sink { _ in displayChanges += 1 }.store(in: &subscriptions)
        view.footer.objectWillChange.sink { _ in footerChanges += 1 }.store(in: &subscriptions)
        TranscriptLayoutClock.reset(); TranscriptLayoutClock.recording = true
        defer { TranscriptLayoutClock.recording = false }
        if let mark = testEnvironment("PI_PROBE_MARK") { FileManager.default.createFile(atPath: mark, contents: Data("start".utf8)) }
        let wall = ProcessInfo.processInfo.systemUptime, cpu = Self.mainThreadCPU()
        view.draft = "A large answer, please"; model.send(sessionID: chat.id)
        await waitFor("The large reply never finished", seconds: 120) { quiet(model.displays[chat.id]) }
        let seconds = ProcessInfo.processInfo.systemUptime - wall, busy = Self.mainThreadCPU() - cpu
        let text = view.messages.last?.text.count ?? 0
        typealias C = TranscriptLayoutClock
        print(String(format: "REDRAW transcript: update %.2f s, layout %.2f s, measure %.2f s (%d rows), markdown update %.2f s + layout %.2f s (%d blocks), row sizing %.2f s (%d passes), root updates %.2f s (%d), host builds %.2f s (%d), viewport layout %.2f s, mount %.2f s, row loop %.2f s, placement %.2f s, validation %.2f s; appends %d estimates %d rebuilds %d",
                     C.updateSeconds, C.layoutSeconds, C.measureSeconds, C.measuredRows, C.markdownUpdateSeconds, C.markdownLayoutSeconds, C.markdownBlocksMeasured,
                     C.rowSizingSeconds, C.rowSizingPasses, C.rootUpdateSeconds, C.rootUpdates, C.hostBuildSeconds, C.hostBuilds, C.viewportLayoutSeconds,
                     C.mountSeconds, C.rowLoopSeconds, C.placementSeconds, C.validationSeconds, C.streamingAppends, C.streamingEstimates, C.streamingRebuilds))
        withExtendedLifetime(subscriptions) {}
        print(String(format: "REDRAW streamed %d characters in %.1f s: main thread busy %.2f s (%.0f%%); model changes %d (%.1f/s), display changes %d (%.1f/s), footer changes %d (%.1f/s)",
                     text, seconds, busy, busy / seconds * 100, modelChanges, Double(modelChanges) / seconds, displayChanges, Double(displayChanges) / seconds, footerChanges, Double(footerChanges) / seconds))
    }

    @MainActor func testWhatTypingCosts() async throws {
        let setup = try await setup()
        let launched = await launch(setup)
        let model = launched.model
        await model.restore()
        model.selectedWorkspaceID = setup.workspace.id; model.profileChoice = setup.profile.id
        let chat = ChatRecord(id: "chat-" + UUID().uuidString, workspaceID: setup.workspace.id, title: "Typing", path: nil, profileID: setup.profile.id)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.select(chat.id)
        let view = try XCTUnwrap(model.displays[chat.id])
        view.draft = "A short question"; model.send(sessionID: chat.id)
        await waitFor("The first turn never finished") { quiet(model.displays[chat.id]) }
        try await Task.sleep(for: .milliseconds(1500))
        func editors(_ root: NSView) -> [ComposerTextView] { ((root as? ComposerTextView).map { [$0] } ?? []) + root.subviews.flatMap { editors($0) } }
        let editor = try XCTUnwrap(editors(launched.hosted).first { $0.sessionID == chat.id })
        launched.window.makeFirstResponder(editor)
        var modelChanges = 0, displayChanges = 0, footerChanges = 0
        var subscriptions: Set<AnyCancellable> = []
        model.objectWillChange.sink { _ in modelChanges += 1 }.store(in: &subscriptions)
        view.objectWillChange.sink { _ in displayChanges += 1 }.store(in: &subscriptions)
        view.footer.objectWillChange.sink { _ in footerChanges += 1 }.store(in: &subscriptions)
        let text = "The quick brown fox jumps over the lazy"
        var costs: [Double] = []
        for character in text {
            let started = Self.mainThreadCPU()
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: launched.window.windowNumber, context: nil, characters: String(character),
                                         charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0)
            if let event { editor.keyDown(with: event) }
            launched.hosted.layoutSubtreeIfNeeded(); launched.window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            launched.hosted.layoutSubtreeIfNeeded(); launched.window.displayIfNeeded()
            costs.append((Self.mainThreadCPU() - started) * 1000)
        }
        withExtendedLifetime(subscriptions) {}
        let sorted = costs.sorted()
        print(String(format: "TYPING %d keys: main thread per key median %.1f ms, p90 %.1f ms, max %.1f ms; model changes %d, display changes %d, footer changes %d",
                     costs.count, sorted[sorted.count / 2], sorted[sorted.count * 9 / 10], sorted.last ?? 0, modelChanges, displayChanges, footerChanges))
    }

    @MainActor func testWhatAChatSwitchCosts() async throws {
        let setup = try await setup()
        let launched = await launch(setup)
        let model = launched.model
        await model.restore()
        model.selectedWorkspaceID = setup.workspace.id; model.profileChoice = setup.profile.id
        var ids: [String] = []
        for title in ["First", "Second"] {
            let chat = ChatRecord(id: "chat-" + UUID().uuidString, workspaceID: setup.workspace.id, title: title, path: nil, profileID: setup.profile.id)
            model.chats.append(chat); try await model.store?.put(chat, kind: "chat", id: chat.id)
            await model.select(chat.id)
            for text in ["Please read fixture README.md", "A large answer, please"] {
                model.displays[chat.id]?.draft = text; model.send(sessionID: chat.id)
                await waitFor("“\(text)” never finished", seconds: 90) { quiet(model.displays[chat.id]) }
            }
            ids.append(chat.id)
        }
        try await Task.sleep(for: .milliseconds(1500))
        var modelChanges = 0
        var subscriptions: Set<AnyCancellable> = []
        model.objectWillChange.sink { _ in modelChanges += 1 }.store(in: &subscriptions)
        var byName: [String: Int] = [:]
        tallyChanges(model, into: &subscriptions) { byName[$0, default: 0] += 1 }
        var costs: [Double] = [], walls: [Double] = []
        let seconds = Double(testEnvironment("PI_REDRAW_SECONDS") ?? "") ?? 0
        if let mark = testEnvironment("PI_PROBE_MARK") { FileManager.default.createFile(atPath: mark, contents: Data("start".utf8)) }
        let began = ProcessInfo.processInfo.systemUptime
        TranscriptLayoutClock.reset(); TranscriptLayoutClock.recording = true
        var round = 0
        while round < 10 || ProcessInfo.processInfo.systemUptime - began < seconds {
            defer { round += 1 }
            let target = ids[round % 2 == 0 ? 0 : 1]
            let cpu = Self.mainThreadCPU(), wall = ProcessInfo.processInfo.systemUptime
            await model.select(target)
            await waitFor("The chat never became ready") {
                launched.hosted.layoutSubtreeIfNeeded(); launched.window.displayIfNeeded()
                return model.displays[target]?.historyState == .ready
            }
            launched.hosted.layoutSubtreeIfNeeded(); launched.window.displayIfNeeded()
            costs.append((Self.mainThreadCPU() - cpu) * 1000); walls.append((ProcessInfo.processInfo.systemUptime - wall) * 1000)
            try await Task.sleep(for: .milliseconds(400))
        }
        TranscriptLayoutClock.recording = false
        withExtendedLifetime(subscriptions) {}
        typealias C = TranscriptLayoutClock
        let n = Double(costs.count)
        print(String(format: "SWITCH transcript per switch: update %.1f ms, layout %.1f ms, measure %.1f ms (%.0f rows), markdown update %.1f ms + layout %.1f ms, row sizing %.1f ms, root updates %.1f ms (%.0f), host builds %.1f ms (%.0f), viewport layout %.1f ms, mount %.1f ms, row loop %.1f ms, placement %.1f ms",
                     C.updateSeconds * 1000 / n, C.layoutSeconds * 1000 / n, C.measureSeconds * 1000 / n, Double(C.measuredRows) / n, C.markdownUpdateSeconds * 1000 / n, C.markdownLayoutSeconds * 1000 / n,
                     C.rowSizingSeconds * 1000 / n, C.rootUpdateSeconds * 1000 / n, Double(C.rootUpdates) / n, C.hostBuildSeconds * 1000 / n, Double(C.hostBuilds) / n, C.viewportLayoutSeconds * 1000 / n,
                     C.mountSeconds * 1000 / n, C.rowLoopSeconds * 1000 / n, C.placementSeconds * 1000 / n))
        let c = costs.sorted(), w = walls.sorted()
        print(String(format: "SWITCH %d switches: main thread per switch median %.1f ms (max %.1f), to ready median %.1f ms (max %.1f); model changes %d (%.1f per switch)",
                     c.count, c[c.count / 2], c.last ?? 0, w[w.count / 2], w.last ?? 0, modelChanges, Double(modelChanges) / Double(c.count)))
        print("SWITCH assignments: " + byName.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    }

    /// What one change to the model costs the main thread, with a sidebar of
    /// forty chats and a chat open on a read and a long answer: every view
    /// that observes the model is asked for its body again.
    @MainActor func testWhatAModelChangeCosts() async throws {
        let setup = try await setup()
        let launched = await launch(setup)
        let model = launched.model
        await model.restore()
        model.selectedWorkspaceID = setup.workspace.id; model.profileChoice = setup.profile.id
        var chats: [ChatRecord] = []
        for index in 0..<40 {
            let chat = ChatRecord(id: String(format: "chat-%02d-", index) + UUID().uuidString, workspaceID: setup.workspace.id, title: "Earlier chat \(index)", path: nil, profileID: setup.profile.id)
            chats.append(chat); try await model.store?.put(chat, kind: "chat", id: chat.id)
        }
        let open = ChatRecord(id: "chat-open-" + UUID().uuidString, workspaceID: setup.workspace.id, title: "Open", path: nil, profileID: setup.profile.id)
        chats.append(open); try await model.store?.put(open, kind: "chat", id: open.id)
        model.chats = chats
        await model.select(open.id)
        for text in ["Please read fixture README.md", "A large answer, please"] {
            model.displays[open.id]?.draft = text; model.send(sessionID: open.id)
            await waitFor("“\(text)” never finished", seconds: 90) { quiet(model.displays[open.id]) }
        }
        try await Task.sleep(for: .milliseconds(1500))
        launched.hosted.layoutSubtreeIfNeeded(); launched.window.displayIfNeeded()
        let shown = model.displays[open.id]
        print("CHANGE live turn: \(String(describing: TaskTranscriptPlan.live(shown?.taskPresentation, messages: shown?.messages ?? []).map { "\($0.phase ?? "nil") live \($0.live)" })), utility phase \(String(describing: shown?.taskPresentation?.utilityPhase)), active \(shown?.taskPresentation?.active != nil), state \(shown?.state ?? "")")
        let seconds = Double(testEnvironment("PI_REDRAW_SECONDS") ?? "") ?? 0
        if let mark = testEnvironment("PI_PROBE_MARK") { FileManager.default.createFile(atPath: mark, contents: Data("start".utf8)) }
        var count = 0
        let cpu = Self.mainThreadCPU(), wall = ProcessInfo.processInfo.systemUptime
        while count < 200 || ProcessInfo.processInfo.systemUptime - wall < seconds {
            model.objectWillChange.send()
            launched.hosted.layoutSubtreeIfNeeded(); launched.window.displayIfNeeded()
            await Task.yield()
            count += 1
        }
        let busy = Self.mainThreadCPU() - cpu
        print(String(format: "CHANGE %d model changes: main thread %.2f ms per change", count, busy / Double(count) * 1000))
    }

    /// Which part of the window a model change costs: each part alone in the
    /// window, 300 changes each, with the same sidebar and open chat as above.
    @MainActor func testWhereAModelChangeGoes() async throws {
        let setup = try await setup()
        let launched = await launch(setup)
        let model = launched.model
        await model.restore()
        model.selectedWorkspaceID = setup.workspace.id; model.profileChoice = setup.profile.id
        var chats: [ChatRecord] = []
        for index in 0..<40 {
            let chat = ChatRecord(id: String(format: "chat-%02d-", index) + UUID().uuidString, workspaceID: setup.workspace.id, title: "Earlier chat \(index)", path: nil, profileID: setup.profile.id)
            chats.append(chat); try await model.store?.put(chat, kind: "chat", id: chat.id)
        }
        let open = ChatRecord(id: "chat-open-" + UUID().uuidString, workspaceID: setup.workspace.id, title: "Open", path: nil, profileID: setup.profile.id)
        chats.append(open); try await model.store?.put(open, kind: "chat", id: open.id)
        model.chats = chats
        await model.select(open.id)
        for text in ["Please read fixture README.md", "A large answer, please"] {
            model.displays[open.id]?.draft = text; model.send(sessionID: open.id)
            await waitFor("“\(text)” never finished", seconds: 90) { quiet(model.displays[open.id]) }
        }
        try await Task.sleep(for: .milliseconds(1500))
        let session = try XCTUnwrap(model.displays[open.id]), chat = try XCTUnwrap(model.record(open.id))
        let parts: [(String, AnyView)] = [
            ("nothing", AnyView(Color.clear)),
            ("whole window", AnyView(WorkspaceView(model: model))),
            ("sidebar", AnyView(WorkspaceSidebar(model: model, width: 300).frame(width: 300, height: 820))),
            ("chat pane", AnyView(ConversationPane(model: model, session: session, chat: chat, paneWidth: 980).frame(width: 980, height: 820))),
            ("composer", AnyView(ComposerInput(model: model, session: session, paneWidth: 980).frame(width: 980))),
            ("footer", AnyView(MetricsFooter(model: model, session: session, contextWindow: nil, outputReserve: nil, compact: false) {}.frame(width: 980))),
        ]
        var lines: [String] = []
        for (name, view) in parts {
            launched.window.contentView = NSHostingView(rootView: view)
            for _ in 0..<5 { launched.window.contentView?.layoutSubtreeIfNeeded(); launched.window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(100)) }
            try await Task.sleep(for: .milliseconds(500))
            let document = launched.views(TranscriptSurfaceMarker.self, in: launched.window.contentView).first.flatMap { $0.enclosingScrollView?.documentView as? TranscriptNativeDocument }
            let updates = document?.updateInvocationCount ?? 0, reconciled = document?.contentReconciliationCount ?? 0
            var presented = 0
            var watch: Set<AnyCancellable> = []
            session.presentationChanges.dropFirst().sink { _ in presented += 1 }.store(in: &watch)
            TranscriptLayoutClock.reset(); TranscriptLayoutClock.recording = true
            let cpu = Self.mainThreadCPU()
            for _ in 0..<300 {
                model.objectWillChange.send()
                launched.window.contentView?.layoutSubtreeIfNeeded(); launched.window.displayIfNeeded()
                await Task.yield()
            }
            TranscriptLayoutClock.recording = false
            lines.append(String(format: "%@ %.2f ms (document updates %d, reconciled %d, presentations %d, row updates %.1f ms total, root updates %d)", name, (Self.mainThreadCPU() - cpu) / 300 * 1000,
                                (document?.updateInvocationCount ?? 0) - updates, (document?.contentReconciliationCount ?? 0) - reconciled, presented,
                                TranscriptLayoutClock.updateSeconds * 1000, TranscriptLayoutClock.rootUpdates))
        }
        launched.window.contentView = launched.hosted
        print("WHERE per model change: " + lines.joined(separator: ", "))
    }
}
