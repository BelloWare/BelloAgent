import AppKit
import Combine
import Darwin
import SwiftUI
import XCTest
@testable import PiApp

/// Everything on the main thread outside the transcript, measured end to end in
/// a real window over a real `WorkspaceModel` on a scratch store: launch to the
/// first painted sidebar row, a chat switch, a sidebar change, a streamed
/// delta's effect on the shell, a settings sheet, the report page over a year
/// of retained requests, and the process footprint after a long session.
///
/// Timings print as `PERF` lines and are asserted only against ceilings a
/// loaded machine still clears; what is asserted tightly is structural — how
/// many rows a change rebuilds, how many times the workspace publishes, how
/// many objects survive — because that is what regresses and what a stopwatch
/// on a shared machine cannot see.
final class AppShellPerformanceTests: XCTestCase {
    /// Chats in the launch fixture; the owner's workspace is this size.
    private static let launchChats = 400
    /// Chats in the sidebar fixture, spread over three projects.
    private static let sidebarChats = 540

    // MARK: Measurement helpers

    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    /// The process footprint Activity Monitor shows, from `proc_pid_rusage`.
    /// Sizes are only ever printed: what a leak test asserts is whether an
    /// object is still alive, never how many bytes it took.
    private func footprintBytes() -> UInt64 {
        var info = rusage_info_current()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        return status == 0 ? info.ri_phys_footprint : 0
    }

    private func megabytes(_ bytes: UInt64) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

    /// Mean and worst of a repeated main-thread operation, printed as one PERF line.
    @MainActor @discardableResult
    private func time(_ label: String, repeats: Int = 12, _ body: (Int) -> Void) -> Double {
        body(0)
        var worst = 0.0, total = 0.0
        for index in 0..<repeats {
            let start = ProcessInfo.processInfo.systemUptime
            body(index)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            worst = max(worst, elapsed); total += elapsed
        }
        let mean = total / Double(repeats)
        print(String(format: "PERF shell %@: mean %.2f ms, worst %.2f ms over %d", label, mean * 1_000, worst * 1_000, repeats))
        return mean
    }

    /// A per-chat request history the size the archive would hand back; the
    /// archive caps it at `SessionTimingHistory.limit`, and so must anything
    /// that keeps one per visited chat.
    private static func timingHistory(samples: Int) -> SessionTimingHistory {
        let kept = min(samples, SessionTimingHistory.limit)
        var values: [SessionTimingSample] = []
        values.reserveCapacity(kept)
        for index in 0..<kept {
            let offset = Double(index)
            let wall = Date(timeIntervalSince1970: 1_700_000_000 + offset)
            let ttft: Double = 80 + Double(index % 50)
            let streaming: Double = 500 + Double(index % 1_500)
            let output: Double = 100 + Double(index % 900)
            let request: Double = 600 + Double(index % 1_600)
            values.append(SessionTimingSample(id: "s\(index)", wall: wall, ttftMilliseconds: ttft,
                                              streamingMilliseconds: streaming, outputTokens: output,
                                              costUSD: 0.01, requestMilliseconds: request))
        }
        return SessionTimingHistory(samples: values, completedRequests: samples)
    }

    // MARK: Fixtures

    @MainActor private func scratch(_ name: String) throws -> URL {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A vault holding trusted projects and one Responses connection, so the
    /// restored sidebar draws real project groups with draggable rows.
    private func seededVault(projects: [WorkspaceRecord]) throws -> ConfigurationVault {
        var configuration = VaultConfiguration()
        configuration.workspaces = projects
        return ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration)))
    }

    /// Chats written into a real desktop database, as a previous launch left
    /// them: the store the next launch has to read before it can paint.
    @MainActor private func seedChats(at root: URL, projects: [WorkspaceRecord], perProject: Int) async throws {
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        try await store.open()
        for project in projects {
            for index in 0..<perProject {
                let chat = ChatRecord(id: "\(project.id)-chat\(index)", workspaceID: project.id,
                                      title: "Chat \(index) of \(URL(fileURLWithPath: project.path).lastPathComponent)",
                                      path: nil, profileID: "fixture", sidebarOrder: Int64(100_000 - index))
                try await store.put(chat, kind: "chat", id: chat.id)
            }
        }
        await store.close()
    }

    /// The window the app puts on screen: `WorkspaceView` over the model.
    @MainActor private func window(_ model: WorkspaceModel) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 860),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceView(model: model))
        window.makeKeyAndOrderFront(nil)
        return (window, window.contentView!)
    }

    @MainActor private func draw(_ hosted: NSView, _ window: NSWindow) {
        hosted.needsLayout = true
        hosted.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    /// Drives layout until the condition holds, returning the elapsed seconds.
    @MainActor private func settle(_ hosted: NSView, _ window: NSWindow, limit: TimeInterval = 30,
                                   until condition: () -> Bool) async -> Double? {
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < limit {
            draw(hosted, window)
            if condition() { return ProcessInfo.processInfo.systemUptime - start }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return nil
    }

    /// One turn of the main run loop: AppKit tears views down and drains its
    /// autorelease pool there, and a test that only yields to Swift concurrency
    /// never reaches it.
    @MainActor private func runLoopTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    /// Every draggable chat row installs one AppKit press surface, so counting
    /// them is how a test knows the sidebar has really drawn its rows.
    @MainActor private func sidebarRowCount(in hosted: NSView) -> Int {
        descendants(TopicSessionDragSurfaceView.self, in: hosted).count
    }

    // MARK: 1. Launch to the first painted sidebar row

    @MainActor func testLaunchToFirstSidebarPaintWithFourHundredChats() async throws {
        let root = try scratch("shell-launch")
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let project = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        try await seedChats(at: state, projects: [project], perProject: Self.launchChats)

        let model = WorkspaceModel(stateRoot: state, vault: try seededVault(projects: [project]))
        registerWorkspaceFixtureTeardown(model, root: root)
        let launchedAt = ProcessInfo.processInfo.systemUptime
        let (window, hosted) = self.window(model)
        defer { window.contentView = nil; window.close() }
        let restore = Task { @MainActor in await model.restore() }
        let painted = await settle(hosted, window) { self.sidebarRowCount(in: hosted) > 0 }
        let toFirstRow = try XCTUnwrap(painted.map { _ in ProcessInfo.processInfo.systemUptime - launchedAt })
        await restore.value
        let restored = ProcessInfo.processInfo.systemUptime - launchedAt
        draw(hosted, window)

        print(String(format: "PERF shell launch (%d chats): first sidebar row painted at %.1f ms, restore() complete at %.1f ms, %d rows",
                     Self.launchChats, toFirstRow * 1_000, restored * 1_000, sidebarRowCount(in: hosted)))
        XCTAssertEqual(model.chats.count, Self.launchChats)
        XCTAssertGreaterThan(sidebarRowCount(in: hosted), 0, "the sidebar painted no chat rows at all")
        XCTAssertLessThan(toFirstRow, 3.0, "launch took \(Int(toFirstRow * 1_000)) ms to paint its first sidebar row")
    }

    // MARK: 2. A chat switch, end to end

    @MainActor func testChatSwitchBetweenTwoLongChats() async throws {
        let root = try scratch("shell-switch")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        let model = WorkspaceModel(stateRoot: root, vault: try seededVault(projects: [project]))
        registerWorkspaceFixtureTeardown(model, root: root)
        var profile = ProfileRecord(); profile.id = "fixture"; profile.modelId = "fixture-model"; profile.baseUrl = "https://fixture.invalid/v1"
        model.profiles = [profile]; model.workspaces = [project]
        model.selectedWorkspaceID = project.id; model.profileChoice = profile.id
        model.chats = (0..<40).map { ChatRecord(id: "chat-\($0)", workspaceID: project.id, title: "Chat \($0)", path: nil, profileID: profile.id) }
        // Two long chats, already loaded, as two chats the reader moves between.
        // Long in rows, plain in content: what the shell pays for is the row
        // count and the pane swap. A 300-row Markdown page's own layout is the
        // transcript's measurement, not this one.
        for id in ["chat-0", "chat-1"] {
            let display = SessionDisplay(id: id)
            display.messages = (0..<300).map {
                TranscriptMessage(id: "\(id)-m\($0)", role: $0.isMultiple(of: 2) ? "user" : "assistant",
                                  text: "Step \($0): the handler retries twice and logs the reason.", turn: "\(id)-m\($0 - $0 % 2)")
            }
            display.draft = "An unsent draft for \(id)."
            display.selectionMetadataLoaded = true
            model.displays[id] = display
        }
        model.opened = ["chat-0", "chat-1"]
        await model.select("chat-0")

        // The model's own half of a switch, with nothing mounted: store reads,
        // read state, the display swap and the retained-billing query. The
        // transcript's own layout is measured by the transcript's own tests.
        var modelOnly = 0.0
        for round in 0..<5 {
            let start = ProcessInfo.processInfo.systemUptime
            await model.select(round.isMultiple(of: 2) ? "chat-1" : "chat-0")
            if round > 0 { modelOnly += (ProcessInfo.processInfo.systemUptime - start) / 4 }
        }
        print(String(format: "PERF shell chat switch, model only (two 300-row chats): %.1f ms", modelOnly * 1_000))
        XCTAssertLessThan(modelOnly, 0.5, "model.select alone took \(Int(modelOnly * 1_000)) ms")

        let (window, hosted) = self.window(model)
        defer { window.contentView = nil; window.close() }
        _ = await settle(hosted, window) { self.descendants(ComposerTextView.self, in: hosted).count == 1 }

        var selectMean = 0.0, paintMean = 0.0
        let rounds = 6
        for round in 0..<rounds {
            let target = round.isMultiple(of: 2) ? "chat-1" : "chat-0"
            let start = ProcessInfo.processInfo.systemUptime
            await model.select(target)
            let selected = ProcessInfo.processInfo.systemUptime
            // The pane's own chrome: the composer for the new chat, laid out.
            _ = await settle(hosted, window) {
                self.descendants(ComposerTextView.self, in: hosted).first?.string.contains(target) == true
            }
            let painted = ProcessInfo.processInfo.systemUptime
            if round > 0 {
                selectMean += (selected - start) / Double(rounds - 1)
                paintMean += (painted - start) / Double(rounds - 1)
            }
        }
        // In the window these include whatever SwiftUI and the transcript do
        // between `select`'s suspensions, which is why the model-only figure
        // above is quoted separately.
        print(String(format: "PERF shell chat switch, whole window (two 300-row chats): model.select %.1f ms, composer painted with the new chat's draft %.1f ms",
                     selectMean * 1_000, paintMean * 1_000))
        // A ceiling a loaded machine still clears, not the target: the Release
        // number is what the target is read from.
        XCTAssertLessThan(paintMean, 5.0, "a chat switch took \(Int(paintMean * 1_000)) ms to show the new chat's composer")
    }

    // MARK: 3. A sidebar change at scale, in the real shell

    @MainActor private func sidebarFixture(_ root: URL) throws -> WorkspaceModel {
        let projects = (0..<3).map { WorkspaceRecord(id: "project\($0)", path: root.appendingPathComponent("p\($0)").path, trusted: true) }
        let model = WorkspaceModel(stateRoot: root, vault: try seededVault(projects: projects))
        var profile = ProfileRecord(); profile.id = "fixture"; profile.modelId = "fixture-model"; profile.baseUrl = "https://fixture.invalid/v1"
        model.profiles = [profile]; model.workspaces = projects
        model.topics = projects.flatMap { project in (0..<3).map { TopicRecord(id: "\(project.id)-topic\($0)", workspaceID: project.id, title: "Topic \($0)") } }
        var chats: [ChatRecord] = []
        for project in projects {
            for index in 0..<(Self.sidebarChats / 3) {
                var chat = ChatRecord(id: "\(project.id)-chat\(index)", workspaceID: project.id, title: "Chat \(index) of \(project.id)",
                                      path: nil, profileID: profile.id, sidebarOrder: Int64(10_000 - index))
                if index % 3 != 0 { chat.topicID = "\(project.id)-topic\(index % 3)" }
                if index % 11 == 0 { chat.archivedAt = Date() }
                if index % 17 == 5 { chat.parentSessionID = "\(project.id)-chat\(index - 1)" }
                chats.append(chat)
            }
        }
        model.chats = chats
        model.selectedWorkspaceID = "project0"
        model.profileChoice = profile.id
        // A used workspace: every row draws its metrics line, not its subtitle.
        for chat in chats {
            var totals = GatewayTotals(requests: 9, costSamples: 9, costUSD: 3.21)
            totals.tokens = GatewayTokenTotals(total: 123_456, samples: 9)
            model.chatAccounting.publish(totals, sessionID: chat.id)
        }
        return model
    }

    @MainActor func testOneSidebarChangeInTheRealShellAtFiveHundredChats() async throws {
        let root = try scratch("shell-sidebar")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try sidebarFixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        model.selectedID = "project0-chat0"
        let (window, hosted) = self.window(model)
        defer { window.contentView = nil; window.close() }
        _ = await settle(hosted, window) { self.sidebarRowCount(in: hosted) > 0 }
        let rows = sidebarRowCount(in: hosted)
        print("PERF shell sidebar fixture: \(model.chats.count) chats, \(model.workspaces.count) projects, \(rows) rows on screen")

        time("a frame with nothing changed (control)") { _ in draw(hosted, window) }
        var rebuilds: [Int] = []
        time("one selection change, whole window") { index in
            SidebarRowRenderCount.reset()
            model.selectedID = "project0-chat\(index)"
            draw(hosted, window)
            rebuilds.append(SidebarRowRenderCount.builds)
        }
        time("one unread change, whole window") { index in
            let id = "project1-chat\(index)"
            model.unreadStates[id] = SessionReadState(id: id, observedAssistantCount: 1, latestAssistantID: "m", unreadOutputs: index % 2)
            draw(hosted, window)
        }
        let worstRebuild = rebuilds.max() ?? 0
        print("PERF shell sidebar rows rebuilt for one selection change: \(worstRebuild) of \(rows) rows on screen")
        // Structural, not a stopwatch: a selection change touches two rows —
        // the one that lost it and the one that gained it — and must not
        // rebuild the rest of the sidebar with them.
        XCTAssertLessThanOrEqual(worstRebuild, 4,
                                 "a selection change rebuilt \(worstRebuild) sidebar rows; only the two whose selection changed may")
        XCTAssertGreaterThan(worstRebuild, 0, "the rows whose selection changed must redraw")
    }

    @MainActor func testBulkArchiveKeepsNativeComposerAndTwentyStreamsResponsive() async throws {
        let root = try scratch("shell-bulk-archive")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.workspaces = [WorkspaceRecord(id: "project", path: root.path, trusted: true)]
        model.chats = (0..<540).map { ChatRecord(id: "chat\($0)", workspaceID: "project", title: "Chat \($0)", path: nil, profileID: "fixture", sidebarOrder: -Int64($0)) }
        for row in model.chats { try await model.store?.put(row, kind: "chat", id: row.id) }
        model.selectedID = "chat0"; model.focusedSessionID = "chat0"; model.selectedWorkspaceID = "project"
        for index in 0..<21 {
            let view = SessionDisplay(id: "chat\(index)")
            view.state = index == 0 ? "idle" : "running"
            view.messages = [TranscriptMessage(id: "m", role: "assistant", text: "Initial answer", state: index == 0 ? "settled" : "streaming")]
            model.displays[view.id] = view
        }
        model.selected = model.displays["chat0"]
        let (window, hosted) = self.window(model)
        defer { window.contentView = nil; window.close() }
        _ = await settle(hosted, window) { self.descendants(ComposerTextView.self, in: hosted).first != nil }
        let editor = try XCTUnwrap(descendants(ComposerTextView.self, in: hosted).first)
        window.makeFirstResponder(editor)
        let store = try XCTUnwrap(model.store)
        var release: CheckedContinuation<Void, Never>?
        model.organizationWrite = { ids, change in
            await withCheckedContinuation { release = $0 }
            return try await store.updateChatOrganizations(ids: ids, change: change)
        }
        model.markedSessionIDs = Set((21..<521).map { "chat\($0)" })
        let began = ProcessInfo.processInfo.systemUptime
        model.archiveMarkedSessions(true)
        let acknowledgment = (ProcessInfo.processInfo.systemUptime - began) * 1_000
        XCTAssertTrue(model.markedSessionIDs.isEmpty)
        while release == nil { await Task.yield() }
        let indexComputations = model.sidebarIndex.computations
        var frames: [Double] = []
        for turn in 0..<120 {
            if turn == 30 {
                XCTAssertEqual(model.sidebarIndex.computations, indexComputations, "Text events cannot rebuild the structural index")
                release?.resume(); release = nil
            }
            for index in 1...20 {
                model.displays["chat\(index)"]?.messages = [TranscriptMessage(id: "m", role: "assistant", text: "Streaming answer \(turn)", state: "streaming")]
            }
            let start = ProcessInfo.processInfo.systemUptime
            editor.insertText("字", replacementRange: NSRange(location: NSNotFound, length: 0))
            draw(hosted, window)
            frames.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            await runLoopTurn()
        }
        _ = await settle(hosted, window) { model.record("chat21")?.isArchived == true }
        XCTAssertTrue(descendants(ComposerTextView.self, in: hosted).first === editor)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.string, String(repeating: "字", count: 120))
        XCTAssertEqual(model.selectionRevision, 0)
        let sorted = frames.sorted()
        print("PERF native archive500+20streams acknowledgeMs=\(acknowledgment) inputDrawOpportunityP95Ms=\(sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]) p99Ms=\(sorted[Int(ceil(Double(sorted.count) * 0.99)) - 1]) maxMs=\(sorted.last ?? 0)")
        for view in model.displays.values { view.state = "idle" }
    }

    /// Identical fixture is also run on the starting revision. Uses the public
    /// sidebar action, durable SQLite, and the real window; no delayed test writer.
    @MainActor func testBulkArchiveWholeWindowBaseline() async throws {
        let root = try scratch("shell-bulk-baseline")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.workspaces = [WorkspaceRecord(id: "project", path: root.path, trusted: true)]
        model.chats = (0..<540).map { ChatRecord(id: "chat\($0)", workspaceID: "project", title: "Chat \($0)", path: nil, profileID: "fixture", sidebarOrder: -Int64($0)) }
        for row in model.chats { try await model.store?.put(row, kind: "chat", id: row.id) }
        let selected = SessionDisplay(id: "chat0")
        model.displays[selected.id] = selected; model.selected = selected
        model.selectedID = selected.id; model.focusedSessionID = selected.id; model.selectedWorkspaceID = "project"
        let (window, hosted) = self.window(model)
        defer { window.contentView = nil; window.close() }
        _ = await settle(hosted, window) { self.descendants(ComposerTextView.self, in: hosted).first != nil }
        let editor = try XCTUnwrap(descendants(ComposerTextView.self, in: hosted).first)
        window.makeFirstResponder(editor)
        var publications = 0
        let observation = model.$chats.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        model.markedSessionIDs = Set((1...500).map { "chat\($0)" })
        draw(hosted, window)
        let began = ProcessInfo.processInfo.systemUptime
        model.archiveMarkedSessions(true)
        let acknowledged = (ProcessInfo.processInfo.systemUptime - began) * 1_000
        var frames: [Double] = [], inputs = 0
        while model.chats.filter(\.isArchived).count != 500, ProcessInfo.processInfo.systemUptime - began < 15 {
            let started = ProcessInfo.processInfo.systemUptime
            editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0)); inputs += 1
            draw(hosted, window)
            frames.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            await runLoopTurn()
        }
        draw(hosted, window)
        XCTAssertEqual(model.chats.filter(\.isArchived).count, 500)
        XCTAssertEqual(editor.string, String(repeating: "x", count: inputs))
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(descendants(ComposerTextView.self, in: hosted).first === editor)
        XCTAssertEqual(model.selectedID, "chat0")
        let sorted = frames.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
        print("PERF native archive baseline: ackMs=\(acknowledged) completeMs=\((ProcessInfo.processInfo.systemUptime-began)*1_000) publications=\(publications) inputDrawP95Ms=\(p95) maxMs=\(sorted.last ?? 0) inputs=\(inputs)")
    }

    // MARK: 4. What a streamed delta costs the shell

    @MainActor func testAStreamedDeltaDoesNotRepublishTheShell() async throws {
        let root = try scratch("shell-delta")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try sidebarFixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        model.selectedID = "project0-chat0"
        let streaming = SessionDisplay(id: "project0-chat1")
        streaming.state = "running"; streaming.runStatus = "running"
        model.displays[streaming.id] = streaming
        let (window, hosted) = self.window(model)
        defer { window.contentView = nil; window.close() }
        _ = await settle(hosted, window) { self.sidebarRowCount(in: hosted) > 0 }

        var publications = 0
        let observation = model.objectWillChange.sink { _ in publications += 1 }
        defer { observation.cancel() }
        var rebuilds = 0
        time("one streamed delta on a background chat, whole window") { index in
            SidebarRowRenderCount.reset()
            streaming.messages = [TranscriptMessage(id: "m0", role: "assistant",
                                                    text: String(repeating: "token ", count: 40 * (index + 1)), state: "streaming")]
            draw(hosted, window)
            rebuilds = max(rebuilds, SidebarRowRenderCount.builds)
        }
        print("PERF shell streamed delta: \(publications) workspace publications, \(rebuilds) sidebar rows rebuilt per delta")
        XCTAssertEqual(publications, 0, "a streamed delta must not republish the whole workspace")
        XCTAssertLessThanOrEqual(rebuilds, 2, "a delta on one chat rebuilt \(rebuilds) sidebar rows")
    }

    // MARK: 5. Opening the settings sheet

    @MainActor func testOpeningTheSettingsSheet() async throws {
        let root = try scratch("shell-settings")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try sidebarFixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 780),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        /// Opening the sheet: building it and laying it out, as a click on the
        /// gear does. The groups below the fold are lazy, so this is the
        /// connection form the sheet opens on and the sheet's own chrome.
        func open() -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            let hosted = NSHostingView(rootView: ProfileSettings(model: model).frame(width: 760, height: 780))
            window.contentView = hosted
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            window.contentView = nil
            return elapsed
        }
        // The chrome on its own, so the form's share of the cost is visible.
        let chromeStart = ProcessInfo.processInfo.systemUptime
        let chrome = NSHostingView(rootView: PiSheet("Settings", subtitle: "Measured empty", symbol: "gearshape",
                                                     content: { Color.clear }).frame(width: 760, height: 780))
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let chromeCost = ProcessInfo.processInfo.systemUptime - chromeStart
        window.contentView = nil
        let first = open(), again = open()
        print(String(format: "PERF shell settings sheet: first open %.1f ms, reopened %.1f ms, sheet chrome alone %.1f ms",
                     first * 1_000, again * 1_000, chromeCost * 1_000))
        XCTAssertLessThan(first, 2.0, "the settings sheet took \(Int(first * 1_000)) ms to appear")
    }

    // MARK: 6. The report page over a year of retained requests

    /// A year of dispatched requests, written straight into the typed
    /// projection so the measurement is of the report, not of a year of
    /// unrelated capture begin/finish operations.
    private func seedAYearOfRequests(_ root: URL, count: Int, until: Date) throws {
        let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
        let start = until.timeIntervalSince1970 - 365 * 86_400
        let step = 365 * 86_400 / Double(max(1, count))
        try db.transaction {
            try db.execute("""
            WITH RECURSIVE sequence(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM sequence WHERE n<\(count - 1))
            INSERT INTO attempts(id,session,workspace,turn,purpose,api,alias,model,outcome,wall,updated,metadata,
              metrics_retained,dispatch,ttft_ms,stream_ms,http_ms,identity_status,
              cost_usd,cost_status,cache_status,cache_read_tokens,cache_write_tokens)
            SELECT printf('00000000-0000-0000-0000-%012d',n),
              'project0-chat'||(n%180),'project0','turn-'||(n%100),'turn',
              'openai-responses','fixture-router','fixture-model','completed',
              \(start)+n*\(step), \(start)+n*\(step), X'7b7d',
              1,100,10+(n%90),20+(n%140),30+(n%400),'reported',
              0.0125,'reported',CASE n%3 WHEN 0 THEN 'hit' WHEN 1 THEN 'miss' ELSE 'unreported' END,
              8,2
            FROM sequence
            """)
        }
    }

    @MainActor func testOpeningTheReportPageOverAYearOfRequests() async throws {
        let root = try scratch("shell-report")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try sidebarFixture(root)
        registerWorkspaceFixtureTeardown(model, root: root)
        let archiveRoot = root.appendingPathComponent("Requests-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        try await model.traces.configure(quota: 1_048_576, bodyRetention: 365, metricRetention: 365)
        try await model.traces.close()
        let requests = Int(testEnvironment("PI_PERF_REPORT_ROWS") ?? "") ?? 50_000
        try seedAYearOfRequests(archiveRoot, count: requests, until: Date())
        try await model.traces.configure(quota: 1_048_576, bodyRetention: 365, metricRetention: 365)

        let (window, hosted) = self.window(model)
        defer { window.contentView = nil; window.close() }
        _ = await settle(hosted, window) { self.sidebarRowCount(in: hosted) > 0 }

        model.report.preferences.windowPreset = DashboardWindowPreset.custom.rawValue
        model.report.preferences.customUntil = Date()
        model.report.preferences.customFrom = Date().addingTimeInterval(-365 * 86_400)
        let opened = ProcessInfo.processInfo.systemUptime
        model.openReport()
        let firstPaint = await settle(hosted, window) { model.page == .report }
        let toResults = await settle(hosted, window, limit: 60) { model.report.hasResults && !model.report.loading }
        print(String(format: "PERF shell report page (%d requests over a year): page painted at %.1f ms, results at %.1f ms",
                     requests, (firstPaint ?? 0) * 1_000, (ProcessInfo.processInfo.systemUptime - opened) * 1_000))
        XCTAssertNotNil(toResults, "the report never produced results for a year of requests")
        XCTAssertNil(model.report.failure, "the report failed: \(model.report.failure ?? "")")
        XCTAssertLessThan(firstPaint ?? .infinity, 2.0, "the report page did not paint promptly")

        // The page is on screen: a frame of it must not re-run its queries.
        time("a frame of the report with nothing changed") { _ in draw(hosted, window) }
        model.closeReport()
        draw(hosted, window)
    }

    // MARK: 6b. The composer must not keep the chats it has shown

    /// `NativeComposer` handed its `ComposerTextView` closures that captured
    /// the SwiftUI coordinator strongly, and the coordinator holds the view
    /// value whose own closures hold the chat's page and the workspace. AppKit
    /// keeps a text view alive past the SwiftUI teardown, so every chat the
    /// reader opened stayed in memory — with its whole transcript — until the
    /// app quit. Proven by reference, not by size.
    @MainActor func testTheComposerDoesNotRetainTheChatsItHasShown() async throws {
        let root = try scratch("shell-composer-leak")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        let model = WorkspaceModel(stateRoot: root, vault: try seededVault(projects: [project]))
        registerWorkspaceFixtureTeardown(model, root: root)
        var profile = ProfileRecord(); profile.id = "fixture"; profile.modelId = "fixture-model"; profile.baseUrl = "https://fixture.invalid/v1"
        model.profiles = [profile]; model.workspaces = [project]
        model.selectedWorkspaceID = project.id; model.profileChoice = profile.id
        model.chats = (0..<20).map { ChatRecord(id: "chat-\($0)", workspaceID: project.id, title: "Chat \($0)", path: nil, profileID: profile.id) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ComposerOnly(model: model))
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        let hosted = try XCTUnwrap(window.contentView)

        var freed: [String: () -> Bool] = [:]
        for index in 0..<20 {
            let id = "chat-\(index)"
            await model.select(id)
            let page = try XCTUnwrap(model.displays[id])
            page.messages = [TranscriptMessage(id: "m", role: "assistant", text: String(repeating: "x", count: 4_000))]
            weak var weakPage = page
            freed[id] = { weakPage == nil }
            draw(hosted, window)
        }
        model.selected = nil
        await model.select("chat-19")
        for _ in 0..<30 { await Task.yield(); await runLoopTurn() }
        draw(hosted, window)
        let live = freed.filter { !$0.value() }.keys.sorted()
        print("PERF shell composer retention: \(live.count) of 20 visited pages still alive")
        XCTAssertLessThanOrEqual(live.count, 8, "the composer kept \(live.count) chats alive: \(live)")
    }

    // MARK: 6c. Work with nothing behind it

    /// The status-bar panel counted every chat's phase, queue and unread state
    /// once a second while it was open. It now counts when it opens and when
    /// the workspace says its rows changed, and several changes in one moment
    /// count once.
    @MainActor func testTheStatusPanelCountsOnChangeRatherThanOnATick() async throws {
        let root = try scratch("shell-menubar")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        let model = WorkspaceModel(stateRoot: root, vault: try seededVault(projects: [project]))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.workspaces = [project]
        model.chats = (0..<200).map { ChatRecord(id: "chat-\($0)", workspaceID: project.id, title: "Chat \($0)", path: nil, profileID: "fixture") }
        var counted = 0
        let controller = MenuBarMetricsController(load: { _, _, _ in throw CaptureFailure.unavailable },
                                                  activity: { counted += 1; return model.menuBarActivity() },
                                                  activityChanges: { model.menuBarActivityChanges })
        controller.setVisible(true)
        defer { controller.setVisible(false) }
        XCTAssertEqual(counted, 1, "opening the panel counts once")

        // A second and a half of an open panel with nothing happening.
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertEqual(counted, 1, "an open panel with nothing happening counted \(counted) times")

        // A burst of changes in one moment is one count.
        let page = SessionDisplay(id: "chat-0")
        model.displays["chat-0"] = page
        page.state = "running"
        model.unreadStates["chat-1"] = SessionReadState(id: "chat-1", observedAssistantCount: 1, latestAssistantID: "m", unreadOutputs: 1)
        model.noteActivityChanged()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(counted, 2, "a burst of changes in one moment must count once, not \(counted - 1) times")
        XCTAssertEqual(controller.activity.runningRows.map(\.id), ["chat-0"], "the panel has to have followed the change")

        // A phase arriving in a status snapshot publishes nothing by itself.
        page.activity = ["version": .number(2), "phase": .string("tool"), "modelActive": .bool(true), "toolNames": .array([.string("read")])]
        model.noteActivityChanged()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(counted, 3)
        XCTAssertEqual(controller.activity.rows.first { $0.id == "chat-0" }?.phase, "tool")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(counted, 3, "the panel went back to counting on a tick")
    }

    /// A draft write leaves nothing behind, and a newer write is never dropped
    /// by an older one finishing.
    @MainActor func testFinishedDraftWritesLeaveNoTasksBehind() async throws {
        let root = try scratch("shell-drafts")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        let model = WorkspaceModel(stateRoot: root, vault: try seededVault(projects: [project]))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.workspaces = [project]
        model.chats = (0..<12).map { ChatRecord(id: "chat-\($0)", workspaceID: project.id, title: "Chat \($0)", path: nil, profileID: "fixture") }
        _ = await model.prepareStore()
        for index in 0..<12 {
            let page = SessionDisplay(id: "chat-\(index)")
            model.displays[page.id] = page
            page.draft = "Something typed in chat \(index)"
            model.draftChanged(page)
        }
        XCTAssertEqual(model.pendingDraftWrites, 12, "each chat has a write in flight")
        // The last word typed in a chat is the one that is saved, even though
        // the write before it is cancelled and cleans up after itself.
        let busiest = try XCTUnwrap(model.displays["chat-3"])
        busiest.draft = "Typed again before the first write landed"
        model.draftChanged(busiest)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while model.pendingDraftWrites > 0, ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
        XCTAssertEqual(model.pendingDraftWrites, 0, "finished draft writes left \(model.pendingDraftWrites) entries behind")
        let saved = try await model.store?.get(DraftRecord.self, kind: "draft", id: "chat-3")
        XCTAssertEqual(saved?.text, "Typed again before the first write landed", "the newer write must be the one that survived")
    }

    /// The sidebar keeps one observable per chat it draws, and lets go of the
    /// ones it no longer draws.
    @MainActor func testRetainedAccountingRowsAreHeldOnlyWhileTheyAreDrawn() throws {
        let cache = SessionAccountingCache()
        var held: [CachedSessionAccounting] = []
        for index in 0..<40 { held.append(cache.row(for: "kept-\(index)")) }
        weak var transient = cache.row(for: "gone")
        XCTAssertNil(transient, "a row nothing draws must not be kept by the cache")
        for index in 0..<SessionAccountingCache.sweepThreshold + 40 { _ = cache.row(for: "passing-\(index)") }
        XCTAssertLessThanOrEqual(cache.trackedRows, SessionAccountingCache.sweepThreshold + 40 + held.count,
                                 "the table of rows grew without bound")
        // Everything still on screen keeps its own observable and its figures.
        var totals = GatewayTotals(requests: 3, costSamples: 3, costUSD: 0.5)
        totals.tokens = GatewayTokenTotals(total: 1_200, samples: 3)
        cache.publish(totals, sessionID: "kept-7")
        XCTAssertEqual(held[7].totals, totals)
        XCTAssertTrue(cache.row(for: "kept-7") === held[7])
        // A row that was let go is rebuilt with the figures the cache kept.
        held.removeAll()
        cache.publish(totals, sessionID: "kept-9")
        XCTAssertEqual(cache.row(for: "kept-9").totals, totals)
    }

    /// Asking whether a draft is a slash command used to copy the draft.
    @MainActor func testCheckingALongDraftForACommandDoesNotCopyIt() {
        let prose = String(repeating: "Some ordinary prose that is not a command at all. ", count: 4_000)   // ~200 KB
        let command = "/side " + prose
        let unterminated = "/" + String(repeating: "a", count: 200_000)
        XCTAssertTrue(LeadingCommand.begins(command, directInput: true))
        XCTAssertFalse(LeadingCommand.begins(prose, directInput: true))
        XCTAssertFalse(LeadingCommand.begins(unterminated, directInput: true), "a first word longer than a command name is prose")
        time("checking a 200 KB command draft", repeats: 200) { _ in
            _ = LeadingCommand.begins(command, directInput: true)
        }
        time("checking a 200 KB draft that is not a command", repeats: 200) { _ in
            _ = LeadingCommand.begins(prose, directInput: true)
        }
        let start = ProcessInfo.processInfo.systemUptime
        let parsed = LeadingCommand.parse(command, directInput: true)
        print(String(format: "PERF shell parsing the same draft in full (it copies the arguments): %.2f ms",
                     (ProcessInfo.processInfo.systemUptime - start) * 1_000))
        XCTAssertEqual(parsed?.name, "side")
        XCTAssertEqual(parsed?.arguments.count, prose.trimmingCharacters(in: .whitespacesAndNewlines).count)
    }

    // MARK: 7. Memory over a long session

    @MainActor func testMemoryAfterVisitingFiftyChatsAndAnHourOfStreaming() async throws {
        let root = try scratch("shell-memory")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        let model = WorkspaceModel(stateRoot: root, vault: try seededVault(projects: [project]))
        registerWorkspaceFixtureTeardown(model, root: root)
        var profile = ProfileRecord(); profile.id = "fixture"; profile.modelId = "fixture-model"; profile.baseUrl = "https://fixture.invalid/v1"
        model.profiles = [profile]; model.workspaces = [project]
        model.selectedWorkspaceID = project.id; model.profileChoice = profile.id
        model.chats = (0..<50).map { ChatRecord(id: "chat-\($0)", workspaceID: project.id, title: "Chat \($0)", path: nil, profileID: profile.id) }
        let (window, hosted) = self.window(model)
        defer { window.contentView = nil; window.close() }

        let baseline = footprintBytes()
        var freed: [String: () -> Bool] = [:]
        for index in 0..<50 {
            let id = "chat-\(index)"
            await model.select(id)
            let page = try XCTUnwrap(model.displays[id])
            page.messages = (0..<60).map {
                TranscriptMessage(id: "m\($0)", role: $0.isMultiple(of: 2) ? "user" : "assistant", text: String(repeating: "x", count: 4_000))
            }
            page.footer.timing = Self.timingHistory(samples: 40)
            weak var weakPage = page
            freed[id] = { weakPage == nil }
            draw(hosted, window)
        }
        model.selected = nil
        await model.select("chat-49")
        for _ in 0..<40 { await Task.yield(); await runLoopTurn() }
        draw(hosted, window)
        for _ in 0..<10 { await runLoopTurn() }
        // The app-owned transitions retain outgoing values until their timed
        // completion. A fixed number of queue turns can finish before even one
        // display frame in Release. Keep motion enabled and await bounded real
        // settlement; do not weaken the retained-object limit.
        let settlingAt = ProcessInfo.processInfo.systemUptime
        while freed.filter({ !$0.value() }).count > model.displays.count + 1,
              ProcessInfo.processInfo.systemUptime - settlingAt < 2 {
            draw(hosted, window)
            try await Task.sleep(for: .milliseconds(16))
            await runLoopTurn()
        }
        let afterVisits = footprintBytes()
        let live = freed.filter { !$0.value() }.keys.sorted()
        print("PERF shell memory after visiting 50 chats: \(megabytes(baseline)) → \(megabytes(afterVisits)); "
              + "\(live.count) transcript pages alive, \(model.displays.count) displays, "
              + "\(model.chatAccounting.values.count) retained accounting rows; settlement \(Int((ProcessInfo.processInfo.systemUptime - settlingAt) * 1_000)) ms")
        // The model keeps the last eight chats it showed. The window's
        // SwiftUI graph pins one more: the first chat was on screen before it
        // had any messages, and the empty-chat starter card holds its page
        // until the window's views go — one per window, not one per chat
        // visited, bisected in `ConversationPaneRetentionTests`. What must
        // not happen is a chat the reader passed through staying in memory.
        XCTAssertLessThanOrEqual(live.count, model.displays.count + 1,
                                 "visiting 50 chats kept \(live.count) transcript pages alive: \(live)")
        let passedThrough = (1..<41).map { "chat-\($0)" }.filter { freed[$0]?() == false }
        XCTAssertTrue(passedThrough.isEmpty, "chats the reader passed through are still in memory: \(passedThrough)")

        // An hour of streaming into the chat that is on screen. One delta a
        // second for an hour is 3,600; the default run does a tenth of that
        // and PI_PERF_STREAM_DELTAS runs the full hour.
        let deltas = Int(testEnvironment("PI_PERF_STREAM_DELTAS") ?? "") ?? 360
        let live49 = try XCTUnwrap(model.displays["chat-49"])
        let beforeStreaming = footprintBytes()
        for index in 0..<deltas {
            live49.state = "running"
            live49.messages = [TranscriptMessage(id: "stream:m", role: "assistant",
                                                 text: String(repeating: "token ", count: 20 + index % 400), state: "streaming")]
            live49.footer.timing = Self.timingHistory(samples: index + 1)
            var totals = GatewayTotals(requests: index + 1, costSamples: index + 1, costUSD: Double(index) * 0.001)
            totals.tokens = GatewayTokenTotals(total: Double(index) * 100, samples: index + 1)
            live49.footer.gateway = totals
            if index % 12 == 0 { draw(hosted, window) }
        }
        live49.state = "idle"
        draw(hosted, window)
        let afterStreaming = footprintBytes()
        print("PERF shell memory after \(deltas) streamed deltas: \(megabytes(beforeStreaming)) → \(megabytes(afterStreaming)); "
              + "timing history holds \(live49.footer.timing.samples.count) samples")
        // What must be bounded is the state, not the allocator's high-water mark.
        XCTAssertLessThanOrEqual(live49.footer.timing.samples.count, SessionTimingHistory.limit,
                                 "an hour of streaming grew the per-chat timing history without bound")
        XCTAssertLessThanOrEqual(model.displays.count, 8)
    }
}

/// The composer alone over whatever chat the model has selected.
private struct ComposerOnly: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        if let session = model.selected {
            ComposerInput(model: model, session: session, paneWidth: 900).id(session.id)
        } else { Color.clear }
    }
}
