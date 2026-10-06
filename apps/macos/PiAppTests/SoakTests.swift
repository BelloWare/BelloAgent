import XCTest
import SwiftUI
import AppKit
import Darwin
@testable import PiApp

/// A long run of what a reader does, at random moments: launch, open and
/// switch chats, send while a helper is still starting, quit and launch
/// again. Two things were each seen once and never again in the focused
/// tests: a launch whose sidebar stayed empty for 30 s, and a conversation
/// that jumped 112 pt when its helper started late. This runs until
/// `PI_SOAK_SECONDS` have passed (opt-in; pass `TEST_RUNNER_PI_SOAK_SECONDS`
/// to xcodebuild) and fails on:
/// - a pause of the main thread over 250 ms (`PI_SOAK_STALL_MS`), with the
///   main thread's stack captured while it lasted;
/// - a row of an idle chat that moves or resizes once it is on screen;
/// - a launch whose sidebar takes over 2 s (`PI_SOAK_LAUNCH_MS`).
///
/// `PI_SOAK_SEED` replays a run. The report goes to `PI_SOAK_REPORT`, or
/// beside the run's scratch folder, and `scripts/soak-symbolicate.py`
/// finishes its stacks. Run it in a Release build on a quiet machine:
/// docs/Soak-Test.md has the command.
final class SoakTests: XCTestCase, SerialTestLane {
    // MARK: Setup, as ChatLoadStabilityTests sets it up

    private typealias Setup = GatewayWorkspace

    @MainActor private func setup() async throws -> Setup {
        // Titles are asked of the mini model after each first message, as
        // for a reader whose connection has one.
        try await gatewayWorkspace("soak", projectID: "soak-project", readme: true, miniModel: "fixture-fast")
    }

    @MainActor private final class Launched {
        let model: WorkspaceModel, window: NSWindow, hosted: NSView
        private weak var cachedScroll: NSScrollView?
        init(model: WorkspaceModel, window: NSWindow, hosted: NSView) { self.model = model; self.window = window; self.hosted = hosted }
        func views<T: NSView>(_ type: T.Type, in view: NSView? = nil) -> [T] {
            let view = view ?? hosted
            return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
        }
        /// Found once and kept: the pane, and so its transcript, is kept
        /// across chats, and walking the whole window every few
        /// milliseconds would be the run's own stall.
        var scroll: NSScrollView? {
            if let cachedScroll, cachedScroll.window != nil { return cachedScroll }
            cachedScroll = views(TranscriptSurfaceMarker.self).first?.enclosingScrollView
            return cachedScroll
        }
        var document: TranscriptNativeDocument? { scroll?.documentView as? TranscriptNativeDocument }
        private weak var cachedMarker: TranscriptSurfaceMarker?
        /// The transcript's page, found once for the same reason.
        var page: TranscriptPage? {
            if let cachedMarker, cachedMarker.window != nil { return cachedMarker.page }
            cachedMarker = views(TranscriptSurfaceMarker.self).first
            return cachedMarker?.page
        }
        /// The footer's press targets by identifier (the context pill, the
        /// capture badge), found once each and kept while on screen.
        /// One not found is looked for again a quarter of a second later at
        /// the earliest: walking the window every sample would be the run's
        /// own stall.
        private var cachedTargets: [String: WeakTarget] = [:]
        private struct WeakTarget { weak var view: NSView?; var lookedAt: Double }
        func target(_ identifier: String) -> NSView? {
            let now = ProcessInfo.processInfo.systemUptime
            if let held = cachedTargets[identifier] {
                if let view = held.view, view.window != nil { return view }
                if held.view == nil, now - held.lookedAt < 0.25 { return nil }
            }
            // A plain loop: a lazy compactMap(...).first runs the search twice
            // on the path it finds, which doubles with every level.
            func find(_ view: NSView) -> NSView? {
                if view.accessibilityIdentifier() == identifier { return view }
                for child in view.subviews { if let found = find(child) { return found } }
                return nil
            }
            let found = find(hosted)
            cachedTargets[identifier] = WeakTarget(view: found, lookedAt: now)
            return found
        }
        private weak var cachedComposer: ComposerTextView?
        /// The open chat's composer, found once per chat for the same reason.
        func composer(for chat: String?) -> ComposerTextView? {
            if let cachedComposer, cachedComposer.window != nil, cachedComposer.sessionID == chat { return cachedComposer }
            cachedComposer = views(ComposerTextView.self).first { $0.sessionID == chat }
            return cachedComposer
        }
        func draw() { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
    }

    /// A launch: a new model over the same state, in a window. Torn down by
    /// `close`, not at the end of the test, so a run of hundreds of launches
    /// holds only the one it is in.
    @MainActor private func launch(_ setup: Setup) -> Launched {
        let model = WorkspaceModel(stateRoot: setup.state, vault: setup.vault)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = WorkspaceRootView(model: model)
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        return Launched(model: model, window: window, hosted: hosted)
    }

    @MainActor private func close(_ launched: Launched) async {
        launched.window.contentView = nil; launched.window.close()
        launched.model.report.suspend(); launched.model.shutdown()
        for host in launched.model.hosts.values { try? await host.shutdownAndWait() }
        try? await launched.model.traces.close(); await launched.model.store?.close()
    }

    /// Quits as the app does, once nothing is in flight. False when work was
    /// still running after `seconds` or quitting never answered.
    @MainActor private func quit(_ model: WorkspaceModel, seconds: Double = 90) async -> Bool {
        guard await wait(seconds, { !model.hasActiveWork }) else { return false }
        let lifecycle = ApplicationLifecycle()
        lifecycle.model = model
        var answers: [Bool] = []
        lifecycle.answerTermination = { answers.append($0) }
        guard lifecycle.applicationShouldTerminate(NSApp) == .terminateLater else { return false }
        return await wait(30) { !answers.isEmpty }
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

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    // MARK: The run

    /// What happened, for the report.
    @MainActor private final class Log {
        struct Jump {
            var at: Double, label: String, chat: String
            var sinceFirstPaint: Double?, rows: Int, largest: CGFloat
            var detail: [String]
            var helperOpened: String
            var recent: [String]
        }
        var launches: [(cycle: Int, seconds: Double?)] = []
        var jumps: [Jump] = []
        var actions: [String: Int] = [:]
        var footprints: [(cycle: Int, megabytes: Double)] = []
        /// Each closed launch, held weakly: a model still alive long after its
        /// launch closed is kept by something. (In a 17-launch run, each model
        /// went within five launches; every closed window stayed alive in the
        /// test runner, which the app, with its one window, never sees.)
        var closed: [ClosedLaunch] = []
        var quitFailures: [Int] = []
        var recent: [String] = []
        func did(_ action: String, _ label: String) {
            actions[action, default: 0] += 1
            recent.append(label); if recent.count > 6 { recent.removeFirst() }
        }
    }

    private struct Place { var y: CGFloat; var height: CGFloat; var item: TranscriptItem }
    private struct ClosedLaunch { weak var model: WorkspaceModel?; weak var window: NSWindow?; weak var view: NSView? }

    /// The fields that differ between two values, by path, for a row whose
    /// height changed: what came in that changed it.
    private static func differences(_ lhs: Any, _ rhs: Any, path: String = "", into found: inout [String], depth: Int = 0) {
        guard found.count < 6 else { return }
        let left = Mirror(reflecting: lhs), right = Mirror(reflecting: rhs)
        let leftChildren = Array(left.children), rightChildren = Array(right.children)
        if depth < 6, !leftChildren.isEmpty, leftChildren.count == rightChildren.count, left.subjectType == right.subjectType {
            for (index, (a, b)) in zip(leftChildren, rightChildren).enumerated() {
                let name = a.label ?? "[\(index)]"
                if String(describing: a.value) != String(describing: b.value) {
                    differences(a.value, b.value, path: path.isEmpty ? name : path + "." + name, into: &found, depth: depth + 1)
                }
            }
            return
        }
        let a = String(describing: lhs), b = String(describing: rhs)
        found.append("\(path): \(a.prefix(60)) → \(b.prefix(60))")
    }

    @MainActor func testTheAppStaysStillAndResponsiveOverALongRun() async throws {
        guard let seconds = testEnvironment("PI_SOAK_SECONDS").flatMap(Double.init), seconds > 0 else {
            throw XCTSkip("Set PI_SOAK_SECONDS (TEST_RUNNER_PI_SOAK_SECONDS) to run the soak")
        }
        executionTimeAllowance = seconds + 1_200
        let stallLimit = (testEnvironment("PI_SOAK_STALL_MS").flatMap(Double.init) ?? 250) / 1_000
        let launchLimit = (testEnvironment("PI_SOAK_LAUNCH_MS").flatMap(Double.init) ?? 2_000) / 1_000
        let seed = testEnvironment("PI_SOAK_SEED").flatMap(UInt64.init) ?? UInt64(Date().timeIntervalSince1970 * 1_000)
        var random = SoakRandom(seed: seed)
        print("SOAK seed \(seed), \(Int(seconds)) s, stall limit \(Int(stallLimit * 1_000)) ms, launch limit \(Int(launchLimit * 1_000)) ms")

        let drawReport = testEnvironment("PI_SOAK_DRAW_REPORT") != nil, switchesOnly = testEnvironment("PI_SOAK_SWITCHES") != nil
        RedrawCounter.recording = drawReport
        let setup = try await setup()
        let watchdog = SoakStallWatchdog(threshold: stallLimit)
        watchdog.start()
        defer { watchdog.stop() }
        let log = Log()
        let started = Self.now

        // Six chats, each with a tool round trip, a long reply and a short one.
        watchdog.label("seed")
        let first = launch(setup)
        await first.model.restore()
        first.model.selectedWorkspaceID = setup.workspace.id; first.model.profileChoice = setup.profile.id
        var chatIDs: [String] = []
        for index in 0..<6 {
            let chat = ChatRecord(id: "soak-\(index)-" + UUID().uuidString, workspaceID: setup.workspace.id, title: "Soak chat \(index + 1)", path: nil, profileID: setup.profile.id)
            first.model.chats.append(chat); try await first.model.store?.put(chat, kind: "chat", id: chat.id)
            await first.model.select(chat.id)
            for text in ["Please read fixture README.md", "Please write bulk \(8 + 4 * index) now", "And a short one"] {
                first.model.displays[chat.id]?.draft = text; first.model.send(sessionID: chat.id)
                let done = await wait(120) { self.quiet(first.model.displays[chat.id]) }
                XCTAssertTrue(done, "Seeding: “\(text)” never finished")
            }
            chatIDs.append(chat.id)
        }
        let seeded = await quit(first.model)
        XCTAssertTrue(seeded, "Seeding: the first launch never quit")
        await close(first)
        print(String(format: "SOAK seeded %d chats in %.1f s", chatIDs.count, Self.now - started))

        var cycle = 0
        while Self.now - started < seconds {
            cycle += 1
            watchdog.label("cycle \(cycle): launch")
            let launchStart = Self.now
            let launched = launch(setup)
            let model = launched.model
            let restoring = Task { @MainActor in await model.restore() }
            var launchSeconds: Double?
            while Self.now - launchStart < 60 {
                launched.draw()
                if !model.launching, model.chats.filter({ !$0.isBackgroundTask }).count >= chatIDs.count { launchSeconds = Self.now - launchStart; break }
                try await Task.sleep(for: .milliseconds(5))
            }
            log.launches.append((cycle, launchSeconds))
            log.did("launch", "cycle \(cycle): launch")

            // The chat the launch reopened, from its first rows.
            var lastSend: [String: Double] = [:], lastBusy: [String: Double] = [:]
            func noteBusy() {
                let now = Self.now
                for (id, view) in model.displays where view.busy || view.loading || !view.sendingRows.isEmpty || !view.queue.isEmpty
                    || view.taskPresentation?.active != nil { lastBusy[id] = now }
            }
            func observe(_ label: String, for duration: Double) async throws {
                watchdog.label(label)
                if drawReport {
                    SoakDrawLedger.begin(launched.window, adding: true)
                    SoakDrawLedger.phase = ["switch", "select", "send", "helper", "wait", "idle", "launch"].first { label.contains($0) } ?? "other"
                }
                // The chat shown is read at every sample: a click selects in a
                // task of its own, so the chat changes during the window.
                var chat = "", helperAtStart = false
                var helperOpenedAt: Double?
                var previous: [String: Place]?, previousClean = false, previousViewport = ""
                var firstPaint: Double?
                let windowStart = Self.now
                repeat {
                    let now = Self.now
                    if let shown = model.selectedID, shown != chat {
                        chat = shown; helperAtStart = model.opened.contains(chat); helperOpenedAt = nil
                        firstPaint = nil; previous = nil; previousClean = false
                    }
                    // Every chat, not only the one shown: a run that ended
                    // while its chat was in the background still changes that
                    // chat's last rows when it is opened a moment later.
                    noteBusy()
                    if helperOpenedAt == nil, !helperAtStart, model.opened.contains(chat) { helperOpenedAt = now - windowStart }
                    let rows = visibleRows(launched)
                    let viewport = lastViewport
                    if firstPaint == nil, !rows.isEmpty { firstPaint = now }
                    let clean = self.clean(launched, chat: chat, now: now, lastSend: lastSend, lastBusy: lastBusy)
                    if let previous, previousClean, clean {
                        var moved: [String] = [], largest: CGFloat = 0
                        for (id, place) in rows {
                            guard let was = previous[id] else { continue }
                            let dy = place.y - was.y, dh = place.height - was.height
                            guard abs(dy) > 0.5 || abs(dh) > 0.5 else { continue }
                            largest = max(largest, abs(dy), abs(dh))
                            if moved.count < 4 { moved.append(String(format: "%@ y %.1f→%.1f h %.1f→%.1f", String(id.prefix(12)), was.y, place.y, was.height, place.height)) }
                            else if moved.count == 4 { moved.append("…") }
                            if abs(dh) > 0.5 {
                                var changed: [String] = []
                                Self.differences(was.item, place.item, into: &changed)
                                moved.append("\(id.prefix(12)) changed: " + (changed.isEmpty ? "nothing in its item" : changed.joined(separator: "; ")))
                            }
                        }
                        if !moved.isEmpty {
                            let count = rows.keys.filter { id in previous[id].map { was in abs(rows[id]!.y - was.y) > 0.5 || abs(rows[id]!.height - was.height) > 0.5 } ?? false }.count
                            if let view = model.displays[chat] {
                                moved.append("history \(view.historyState), cached rows \(view.refreshingCachedRows), anchor \(view.scrollAnchor.map { "\($0.id.prefix(8))@\(Int($0.offset))\($0.followsBottom ? " following" : "")" } ?? "none")")
                            }
                            moved.append("before: " + previousViewport + "; after: " + viewport)
                            log.jumps.append(.init(at: now - started, label: label, chat: String(chat.prefix(12)),
                                                   sinceFirstPaint: firstPaint.map { now - $0 }, rows: count, largest: largest, detail: moved,
                                                   helperOpened: helperAtStart ? "open before" : helperOpenedAt.map { String(format: "opened +%.0f ms", $0 * 1_000) } ?? "not open",
                                                   recent: log.recent))
                        }
                    }
                    previous = rows; previousClean = clean; previousViewport = viewport
                    try await Task.sleep(for: .milliseconds(4))
                } while Self.now - windowStart < duration
            }
            try await observe("cycle \(cycle): after launch", for: 1.5)

            let steps = Int.random(in: 20...40, using: &random)
            for step in 1...steps {
                let pause = Double.random(in: 0...0.6, using: &random)
                // `PI_SOAK_SWITCHES` aims a run at selecting and switching chats.
                let roll = Double.random(in: 0..<1, using: &random) * (switchesOnly ? 0.55 : 1)
                let target = chatIDs.randomElement(using: &random)!
                let name = "chat \((chatIDs.firstIndex(of: target) ?? 0) + 1)"
                let prefix = "cycle \(cycle) step \(step)"
                switch roll {
                case ..<0.45:
                    let label = "\(prefix): select \(name)"
                    watchdog.label(label); log.did("select", label)
                    Task { @MainActor in await model.select(target) }
                    try await observe(label, for: pause + 0.3)
                case ..<0.55:
                    let other = chatIDs.randomElement(using: &random)!
                    let label = "\(prefix): switch \(name) then chat \((chatIDs.firstIndex(of: other) ?? 0) + 1)"
                    watchdog.label(label); log.did("switch", label)
                    Task { @MainActor in await model.select(target) }
                    try await Task.sleep(for: .milliseconds(Int.random(in: 0...50, using: &random)))
                    Task { @MainActor in await model.select(other) }
                    try await observe(label, for: pause + 0.3)
                case ..<0.70:
                    let large = Double.random(in: 0..<1, using: &random) < 0.2
                    guard let id = model.selectedID, let view = model.displays[id], !view.busy, view.draftReady, view.draft.isEmpty else { continue }
                    let label = "\(prefix): send \(large ? "a long streamed reply" : "a short one") in the open chat"
                    watchdog.label(label); log.did(large ? "send long" : "send", label)
                    view.draft = large ? "A large answer, please" : "And a short one"
                    model.send(sessionID: id); lastSend[id] = Self.now
                    try await observe(label, for: pause)
                case ..<0.78:
                    guard let id = model.selectedID, let item = model.record(id), !model.opened.contains(id) else { continue }
                    let label = "\(prefix): the helper opens for the open chat"
                    watchdog.label(label); log.did("helper", label)
                    Task { @MainActor in
                        _ = try? await model.open(item)
                        model.refresh(id)
                    }
                    try await observe(label, for: pause + 0.5)
                case ..<0.85:
                    let label = "\(prefix): wait for the open chat to settle"
                    watchdog.label(label); log.did("wait", label)
                    let id = model.selectedID
                    _ = await wait(30) { noteBusy(); return id.map { !(model.displays[$0]?.hasWork ?? false) } ?? true }
                    try await observe(label, for: pause)
                default:
                    let label = "\(prefix): idle"
                    log.did("idle", label)
                    try await observe(label, for: pause + 0.5)
                }
            }

            watchdog.label("cycle \(cycle): quit")
            await restoring.value
            if !(await quit(model)) { log.quitFailures.append(cycle) }
            await close(launched)
            log.closed.append(ClosedLaunch(model: launched.model, window: launched.window, view: launched.hosted))
            try await Task.sleep(for: .milliseconds(300))
            log.footprints.append((cycle, Double(Self.footprint()) / 1_048_576))
        }

        if drawReport {
            SoakDrawLedger.end()
            for line in SoakDrawLedger.report() { print(line) }
            print("SOAK redraws: " + RedrawCounter.counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        report(log, stalls: watchdog.recorded, slowAnswers: watchdog.slowAnswers, seed: seed, seconds: Self.now - started, stallLimit: stallLimit, launchLimit: launchLimit, root: setup.root)
        let slow = log.launches.filter { ($0.seconds ?? .infinity) > launchLimit }
        XCTAssertTrue(watchdog.recorded.isEmpty, "The main thread paused over \(Int(stallLimit * 1_000)) ms \(watchdog.recorded.count) times (see the SOAK lines)")
        XCTAssertTrue(log.jumps.isEmpty, "Rows of an idle chat moved \(log.jumps.count) times (see the SOAK lines)")
        XCTAssertTrue(slow.isEmpty, "\(slow.count) launches took over \(launchLimit) s to list the chats")
        XCTAssertTrue(log.quitFailures.isEmpty, "Quitting failed in cycles \(log.quitFailures)")
    }

    /// Whether a movement in this chat's rows would be a jump: the chat is
    /// the one shown, it is not running or sending, the live bar has had
    /// time to leave after a run, and nothing was sent to it just now.
    @MainActor private func clean(_ launched: Launched, chat: String, now: Double, lastSend: [String: Double], lastBusy: [String: Double]) -> Bool {
        let model = launched.model
        guard !chat.isEmpty, model.selectedID == chat, let view = model.displays[chat] else { return false }
        // The window is drawn a moment after the selection changes: until the
        // page shows the chat, the rows on screen are the chat before's.
        guard launched.page?.sessionID == chat else { return false }
        if view.busy || view.loading || !view.sendingRows.isEmpty || !view.queue.isEmpty { return false }
        // Rows under the loading cover are not on screen.
        if view.historyState.loading && !view.refreshingCachedRows { return false }
        if now - (lastSend[chat] ?? -.infinity) < 3 || now - (lastBusy[chat] ?? -.infinity) < 1.5 { return false }
        return true
    }

    /// The rows on screen and where they sit in the viewport. Frames only:
    /// this runs every few milliseconds on the thread the watchdog watches.
    /// The viewport's height and where the scroll view sits in the window,
    /// at the last `visibleRows`: a viewport that changes height moves the
    /// rows of a page following its end.
    @MainActor private var lastViewport = ""
    @MainActor private func visibleRows(_ launched: Launched) -> [String: Place] {
        guard let document = launched.document, let scroll = launched.scroll else { return [:] }
        let clip = scroll.contentView
        let visible = document.convert(clip.bounds, from: clip)
        let frame = scroll.convert(scroll.bounds, to: nil)
        lastViewport = String(format: "viewport %.0f pt at y %.0f, document %.0f, clip %.0f", clip.bounds.height, frame.minY, document.frame.height, clip.bounds.minY)
        if let composer = launched.composer(for: launched.model.selectedID) {
            let box = composer.convert(composer.bounds, to: nil)
            lastViewport += String(format: ", composer %.0f pt at y %.0f", box.height, box.minY)
        }
        // What the footer said: a label that changes there changes its rows.
        for (name, identifier) in [("context", "session-stats-context"), ("capture", "capture-badge")] {
            guard let target = launched.target(identifier) else { continue }
            let box = target.convert(target.bounds, to: nil)
            lastViewport += String(format: ", %@ “%@” at y %.0f", name, target.accessibilityLabel() ?? "", box.minY)
        }
        if let shown = launched.model.selectedID.flatMap({ launched.model.displays[$0] }) {
            lastViewport += shown.captureAvailable ? ", capture on" : ", capture next"
            if !shown.notice.isEmpty { lastViewport += ", notice “\(shown.notice)”" }
        }
        var shown: [String: Place] = [:]
        for row in document.retainedRows where row.superview === document && row.isHosted && !row.isHidden && row.frame.intersects(visible) {
            shown[row.itemID] = Place(y: row.frame.minY - visible.minY, height: row.frame.height, item: row.contentItem)
        }
        return shown
    }

    // MARK: Report

    /// The footprint Activity Monitor shows, as AppShellPerformanceTests reads it.
    private static func footprint() -> UInt64 {
        var info = rusage_info_current()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) }
        }
        return status == 0 ? info.ri_phys_footprint : 0
    }

    @MainActor private func report(_ log: Log, stalls: [SoakStallWatchdog.Stall], slowAnswers: [Double], seed: UInt64, seconds: Double, stallLimit: Double, launchLimit: Double, root: URL) {
        var lines: [String] = []
        func say(_ line: String) { lines.append(line); print(line) }
        let launchTimes = log.launches.compactMap(\.seconds).sorted()
        let median = launchTimes.isEmpty ? 0 : launchTimes[launchTimes.count / 2]
        let actions = log.actions.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        say(String(format: "SOAK ran %.0f s, seed %llu: %ld launches (sidebar listed: median %.0f ms, max %.0f ms, %ld over %.0f ms, %ld never), actions: %@",
                   seconds, seed, log.launches.count, median * 1_000, (launchTimes.last ?? 0) * 1_000,
                   log.launches.filter { ($0.seconds ?? 0) > launchLimit }.count, launchLimit * 1_000,
                   log.launches.filter { $0.seconds == nil }.count, actions))
        say("SOAK stalls over \(Int(stallLimit * 1_000)) ms: \(stalls.count)")
        let slow = slowAnswers.sorted()
        say("SOAK main thread answers over 100 / 150 / 200 ms: \(slow.count) / \(slow.filter { $0 > 0.15 }.count) / \(slow.filter { $0 > 0.2 }.count); longest "
            + slow.suffix(5).reversed().map { String(format: "%.0f", $0 * 1_000) }.joined(separator: ", ") + " ms")
        var frames: [UInt: String] = [:]
        for stall in stalls.sorted(by: { $0.duration > $1.duration }) {
            say(String(format: "SOAK stall %.0f ms at %.1f s during “%@” (%ld stacks)", stall.duration * 1_000, stall.at, stall.label, stall.stacks.count))
            // The frames the stacks share first, then where the first one was.
            for address in SoakStallWatchdog.summary(of: stall.stacks).prefix(48) {
                let text = frames[address] ?? SoakStallWatchdog.describe(address)
                frames[address] = text
                say("SOAK     " + text)
            }
            // The other threads that were doing something: not parked in a
            // work queue or a run loop's wait.
            let busy = stall.others.filter { stack in
                let top = stack.prefix(8).map { SoakStallWatchdog.describe($0) }.joined(separator: " ")
                let parked = top.contains("__workq_kernreturn") || top.contains("__CFRunLoopServiceMachPort")
                return !parked
            }
            say("SOAK   other threads: \(stall.others.count), \(busy.count) not idle")
            for stack in busy.prefix(12) {
                say("SOAK   thread")
                for address in stack.prefix(12) {
                    let text = frames[address] ?? SoakStallWatchdog.describe(address)
                    frames[address] = text
                    say("SOAK       " + text)
                }
            }
        }
        say("SOAK jumps of an idle chat's rows: \(log.jumps.count)")
        for jump in log.jumps.prefix(60) {
            say(String(format: "SOAK jump at %.1f s during “%@”, chat %@, %@ after its first rows: %ld rows, largest %.1f pt; helper %@",
                       jump.at, jump.label, jump.chat, jump.sinceFirstPaint.map { String(format: "%.0f ms", $0 * 1_000) } ?? "before", jump.rows, jump.largest, jump.helperOpened))
            say("SOAK     " + jump.detail.joined(separator: "; "))
            say("SOAK     after: " + jump.recent.suffix(4).joined(separator: " | "))
        }
        if let first = log.footprints.first, let last = log.footprints.last {
            let peak = log.footprints.map(\.megabytes).max() ?? 0
            say(String(format: "SOAK footprint after each launch: first %.0f MB (cycle %ld), last %.0f MB (cycle %ld), peak %.0f MB; %.2f MB per cycle",
                       first.megabytes, first.cycle, last.megabytes, last.cycle, peak,
                       log.footprints.count > 1 ? (last.megabytes - first.megabytes) / Double(last.cycle - first.cycle) : 0))
        }
        // Every launch, the last one too: which ones is what tells a model
        // let go late from one that is kept.
        let closed = log.closed
        say("SOAK closed launches still alive: \(closed.filter { $0.model != nil }.count) models, \(closed.filter { $0.window != nil }.count) windows, "
            + "\(closed.filter { $0.view != nil }.count) views, of \(closed.count); models of cycles "
            + closed.enumerated().filter { $0.element.model != nil }.map { String($0.offset + 1) }.joined(separator: " "))
        if !log.quitFailures.isEmpty { say("SOAK quit failed in cycles \(log.quitFailures)") }
        // Every frame again, with its image and load address, for atos.
        lines.append("## frames")
        for stall in stalls { for stack in stall.stacks + stall.others { for address in stack { lines.append(SoakStallWatchdog.imageLine(address)) } } }
        let path = testEnvironment("PI_SOAK_REPORT") ?? root.deletingLastPathComponent().appendingPathComponent("soak-report-\(seed).txt").path
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        print("SOAK report: " + path)
    }
}

/// SplitMix64: a whole run follows from its seed.
private struct SoakRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Watches the main thread from a thread of its own. Every 16 ms it asks the
/// main queue to answer; an answer later than the threshold is a stall. While
/// one lasts, it suspends the main thread for the microseconds it takes to
/// read its registers and walk its frame pointers, and resumes it. Nothing
/// is allocated or locked while the main thread is suspended: it may hold the
/// allocator's lock. (`MainThreadWatchdog` is the other kind: it notices a
/// window frozen for seconds and ends the run.)
private final class SoakStallWatchdog: @unchecked Sendable {
    struct Stall: Sendable {
        var at: Double; var duration: Double; var label: String; var stacks: [[UInt]]
        /// Every other thread's stack, once, as the stall began: what the main
        /// thread waits on (a lock another thread holds) shows there.
        var others: [[UInt]] = []
    }
    private let lock = NSLock()
    private var current = "setup"
    private var stalls: [Stall] = []
    private var running = true
    private let threshold: Double
    private let started = ProcessInfo.processInfo.systemUptime
    private let mainThread: thread_act_t
    private let stackLow: UInt, stackHigh: UInt
    private static let depth = 192
    private let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: SoakStallWatchdog.depth)
    private static let otherThreads = 96, otherDepth = 48
    private let othersBuffer = UnsafeMutablePointer<UInt>.allocate(capacity: SoakStallWatchdog.otherThreads * SoakStallWatchdog.otherDepth)
    /// Pointer authentication bits above the 47 a user address uses.
    private static let addressMask: UInt = (1 << 47) - 1

    @MainActor init(threshold: Double) {
        self.threshold = threshold
        mainThread = mach_thread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        stackHigh = top; stackLow = top - UInt(pthread_get_stacksize_np(pthread_self()))
    }
    deinit { buffer.deallocate(); othersBuffer.deallocate() }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "soak.watchdog"; thread.qualityOfService = .userInteractive
        thread.start()
    }
    func stop() { lock.withLock { running = false } }
    func label(_ value: String) { lock.withLock { current = value } }
    var recorded: [Stall] { lock.withLock { stalls } }
    /// Every answer later than 100 ms, stalls or not: how close a run came.
    private var slow: [Double] = []
    var slowAnswers: [Double] { lock.withLock { slow } }

    private func run() {
        while lock.withLock({ running }) {
            let answered = DispatchSemaphore(value: 0)
            let sent = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { answered.signal() }
            var stacks: [[UInt]] = [], others: [[UInt]] = []
            var label: String?
            var stopped = false
            while answered.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
                if !lock.withLock({ running }) { stopped = true; break }
                if ProcessInfo.processInfo.systemUptime - sent > threshold {
                    if label == nil { label = lock.withLock { current }; others = captureOtherStacks() }
                    if stacks.count < 60 { stacks.append(captureMainStack()) }
                }
            }
            if stopped { break }
            let latency = ProcessInfo.processInfo.systemUptime - sent
            if latency > 0.1 { lock.withLock { slow.append(latency) } }
            if latency > threshold {
                let stall = Stall(at: sent - started, duration: latency, label: label ?? lock.withLock { current }, stacks: stacks, others: others)
                lock.withLock { stalls.append(stall) }
            }
            Thread.sleep(forTimeInterval: 0.016)
        }
    }

    private func captureMainStack() -> [UInt] {
        let count = Self.walk(mainThread, low: stackLow, high: stackHigh, into: buffer, depth: Self.depth)
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    /// Every thread's stack but the main thread's and this one's, each walked
    /// while that thread alone is suspended.
    private func captureOtherStacks() -> [[UInt]] {
        var list: thread_act_array_t?
        var listed: mach_msg_type_number_t = 0
        let task = task_self_trap()
        guard task_threads(task, &list, &listed) == KERN_SUCCESS, let list else { return [] }
        let me = mach_thread_self()
        var walked: [(at: Int, count: Int)] = []
        for index in 0..<Int(listed) where list[index] != me && list[index] != mainThread && walked.count < Self.otherThreads {
            let thread = list[index]
            guard let pthread = pthread_from_mach_thread_np(thread) else { continue }
            // A thread that has just exited answers ESRCH for its stack.
            let high = UInt(bitPattern: pthread_get_stackaddr_np(pthread)), size = UInt(pthread_get_stacksize_np(pthread))
            guard high > 0x10000, size > 0, size < high else { continue }
            let low = high - size
            let at = walked.count * Self.otherDepth
            walked.append((at, Self.walk(thread, low: low, high: high, into: othersBuffer + at, depth: Self.otherDepth)))
        }
        for index in 0..<Int(listed) { mach_port_deallocate(task, list[index]) }
        mach_port_deallocate(task, me)
        vm_deallocate(task, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(listed) * MemoryLayout<thread_act_t>.stride))
        return walked.map { Array(UnsafeBufferPointer(start: othersBuffer + $0.at, count: $0.count)) }
    }

    /// Suspends `thread`, reads its registers, walks its frame pointers within
    /// its stack into `out`, and resumes it. Nothing is allocated or locked
    /// meanwhile: the thread may hold the allocator's lock.
    private static func walk(_ thread: thread_act_t, low: UInt, high: UInt, into out: UnsafeMutablePointer<UInt>, depth: Int) -> Int {
        guard thread_suspend(thread) == KERN_SUCCESS else { return 0 }
        var count = 0
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) { thread_get_state(thread, ARM_THREAD_STATE64, $0, &stateCount) }
        }
        if result == KERN_SUCCESS {
            out[count] = UInt(state.__pc) & addressMask; count += 1
            out[count] = UInt(state.__lr) & addressMask; count += 1
            var frame = UInt(state.__fp)
            while count < depth, frame >= low, frame + 16 <= high, frame % 8 == 0 {
                let words = UnsafePointer<UInt>(bitPattern: frame)!
                let next = words[0], returnAddress = words[1] & addressMask
                guard returnAddress != 0 else { break }
                out[count] = returnAddress; count += 1
                guard next > frame else { break }
                frame = next
            }
        }
        thread_resume(thread)
        return count
    }

    /// The frames of a stall's stacks, most shared first: a stall spent in
    /// one place shows that place, whichever stack caught it.
    static func summary(of stacks: [[UInt]]) -> [UInt] {
        guard let first = stacks.first else { return [] }
        var seen: [UInt: Int] = [:]
        for stack in stacks { for address in Set(stack) { seen[address, default: 0] += 1 } }
        // In the first stack's order, keeping frames most stacks share, from
        // the innermost frame outward.
        let shared = first.filter { (seen[$0] ?? 0) * 2 >= stacks.count }
        return shared.isEmpty ? first : shared
    }

    static func describe(_ address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let file = info.dli_fname else { return String(format: "0x%lx", address) }
        let image = URL(fileURLWithPath: String(cString: file)).lastPathComponent
        let base = UInt(bitPattern: info.dli_fbase)
        var text = String(format: "[0x%lx] %@ +0x%lx", address, image, address - base)
        if let name = info.dli_sname {
            text += " " + demangle(String(cString: name)) + String(format: " + %lu", address - UInt(bitPattern: info.dli_saddr))
        }
        return text
    }

    /// `path|load address|address`, for `scripts/soak-symbolicate.py`.
    static func imageLine(_ address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let file = info.dli_fname else { return String(format: "?|0|0x%lx", address) }
        return String(format: "%@|0x%lx|0x%lx", String(cString: file), UInt(bitPattern: info.dli_fbase), address)
    }

    private static func demangle(_ name: String) -> String {
        guard name.hasPrefix("$s") || name.hasPrefix("_$s"), let result = name.withCString({ swiftDemangle($0, strlen($0), nil, nil, 0) }) else { return name }
        defer { free(result) }
        return String(cString: result)
    }
}

@_silgen_name("swift_demangle")
private func swiftDemangle(_ mangledName: UnsafePointer<CChar>?, _ mangledNameLength: Int, _ outputBuffer: UnsafeMutablePointer<CChar>?,
                           _ outputBufferSize: UnsafeMutablePointer<Int>?, _ flags: UInt32) -> UnsafeMutablePointer<CChar>?
