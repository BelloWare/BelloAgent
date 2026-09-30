import XCTest
import SwiftUI
import AppKit
@testable import PiApp
@testable import GitView

/// The Changes tab as the reader meets it: opened in a pane of tabs, on a
/// repository with four hundred changed files, a 5,000-line file rewritten
/// from end to end, and thirty commits, the first of which added all of it.
/// Each step is timed on the main thread's own clock, its longest step is the
/// hitch a reader would see, SwiftUI's layout cycles are counted, and so are
/// the diff rows built. Serial: the figures are timed.
///
/// With the diff drawn by SwiftUI (Debug), switching the whole long diff to
/// side by side held the main thread for 209 to 230 ms in one step, a jump
/// 60,000 points into it 122 to 132 ms, the next file after it 125 to 145 ms,
/// and a commit of four hundred files 192 to 204 ms. Drawn by a native table,
/// with the commit's file chips drawn natively too, they take about 24, 6, 47
/// and 52 ms; the last two are mostly the rest of the panel drawn again.
final class ChangesTabFrameTests: GitPanelTestCase, SerialTestLane {
    static let changedFiles = 400

    /// `a-first.swift`, a one-line change the sheet opens on; `b-long.swift`,
    /// 5,000 lines with every one rewritten; four hundred Swift files with
    /// every third line changed. The history: the seed, twenty-eight notes
    /// and a commit that revised twenty-five of the files.
    func bigRepository() throws -> URL {
        let root = try repository("changes-frames")
        try start(root)
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: false, encoding: .utf8)
        }
        func source(_ index: Int, pass: Int) -> String {
            (0..<60).map { line in
                pass > 0 && line % 3 == 0 ? "    let value\(line) = compute(\(index), \(line), pass: \(pass)) // revised in pass \(pass)"
                    : "    let value\(line) = compute(\(index), \(line))"
            }.joined(separator: "\n") + "\n"
        }
        func path(_ index: Int) -> String { "Sources/Module\(index / 20)/File\(index).swift" }
        try write("a-first.swift", "let first = 1\nlet second = 2\n")
        try write("b-long.swift", (0..<5_000).map { "let original\($0) = \($0) // the first version of line \($0)" }.joined(separator: "\n") + "\n")
        for index in 0..<Self.changedFiles { try write(path(index), source(index, pass: 0)) }
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed the project"], in: root)
        for index in 0..<28 {
            try write("NOTES.md", (0...index).map { "Note \($0)" }.joined(separator: "\n") + "\n")
            if index == 0 { try git(["add", "NOTES.md"], in: root) }
            try git(["commit", "-q", "-am", "Note \(index)"], in: root)
        }
        for index in 0..<25 { try write(path(index), source(index, pass: 1)) }
        try git(["commit", "-q", "-am", "Revise twenty-five files"], in: root)
        try write("a-first.swift", "let first = 1\nlet second = 3\n")
        try write("b-long.swift", (0..<5_000).map { "let rewritten\($0) = \($0 * 2) // every line of this file changed" }.joined(separator: "\n") + "\n")
        for index in 0..<Self.changedFiles { try write(path(index), source(index, pass: 2)) }
        return root
    }

    /// What one step cost: until the sheet showed what it was asked for, and
    /// the main thread's work over that and a short settle after it.
    struct Step: CustomStringConvertible {
        var ready = 0.0, cpu = 0.0, longest = 0.0, cycles = 0, rows = 0
        var description: String { String(format: "ready %.0f ms, main thread %.0f ms, longest step %.1f ms, %d cycles, %d diff rows built", ready, cpu, longest, cycles, rows) }
    }

    @MainActor private func mainThreadMilliseconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000 }

    /// Runs `change`, waits until `ready` holds and the window has drawn it,
    /// then lets it settle.
    @MainActor private func step(_ name: String, _ window: @escaping () -> NSWindow?, settle: Double = 0.6, _ change: () -> Void,
                                 until ready: () -> Bool) async throws -> Step {
        var result = Step()
        let probe = MainThreadStepProbe()
        // Opt-in (PI_CHANGES_SAMPLE=<step>=<file>): where the main thread spends one step, as `sample` sees it.
        var sampler: Process?
        if let request = testEnvironment("PI_CHANGES_SAMPLE"), request.hasPrefix(name + "=") {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "\(Int(settle) + 5)", "1", "-mayDie", "-file", String(request.dropFirst(name.count + 1))]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); sampler = process
            try await Task.sleep(for: .milliseconds(1_500))
        }
        defer { if let sampler { sampler.waitUntilExit() } }
        GitDiffRenderCount.reset()
        result.cycles = try await layoutCycles {
            probe.start()
            let cpu = mainThreadMilliseconds(), started = ProcessInfo.processInfo.systemUptime
            change()
            while !ready() {
                guard ProcessInfo.processInfo.systemUptime - started < 60 else { XCTFail("Timed out"); break }
                try await Task.sleep(for: .milliseconds(2))
            }
            window()?.contentView?.layoutSubtreeIfNeeded(); window()?.displayIfNeeded()
            result.ready = (ProcessInfo.processInfo.systemUptime - started) * 1000
            try await Task.sleep(for: .milliseconds(Int(settle * 1000)))
            result.cpu = mainThreadMilliseconds() - cpu
            probe.stop()
        }
        result.longest = probe.longest
        result.rows = GitDiffRenderCount.rows
        return result
    }

    /// A trackpad's scroll through `distance` points of the diff: ten points a
    /// step, each laid out and drawn.
    @MainActor private func scroll(_ scroll: NSScrollView, in window: NSWindow, from start: CGFloat, through distance: CGFloat) async throws -> (mean: Double, worst: Double, cycles: Int, rows: Int) {
        var total = 0.0, worst = 0.0, steps = 0
        GitDiffRenderCount.reset()
        let cycles = try await layoutCycles {
            var y = start
            while y < start + distance {
                let started = mainThreadMilliseconds()
                scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let cost = mainThreadMilliseconds() - started
                total += cost; worst = max(worst, cost); steps += 1
                y += 10
                await Task.yield()
                if steps % 16 == 0 { try await Task.sleep(for: .milliseconds(1)) }
            }
        }
        return (total / Double(max(1, steps)), worst, cycles, GitDiffRenderCount.rows)
    }

    @MainActor private func footprint() -> Double {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) }
        }
        return result == 0 ? Double(usage.ri_phys_footprint) / 1_048_576 : 0
    }

    @MainActor func testTheChangesTabOverABigRepository() async throws {
        let root = try bigRepository()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let harness = ChangesTabHarness()
        addTeardownBlock { @MainActor in harness.tearDown() }
        try await Task.sleep(for: .milliseconds(500))
        let window = harness.window
        let sheet: () -> NSWindow? = { window }
        let before = footprint()

        // Opened: the list of changes, and the first file's diff.
        var tab: ChangesTab?
        let open = try await step("open", sheet, settle: 1.5, { tab = harness.open(root.path) }) {
            guard let tab, tab.hasController else { return false }
            return tab.controller.status.entries.count == Self.changedFiles + 2 && !tab.controller.diff.isEmpty && !tab.controller.diffLoading
        }
        let controller = try XCTUnwrap(tab).controller
        print("PERF changes tab: open \(open)")

        // The long file: 1,500 of its 10,000 rows until the whole diff is asked for.
        let long = try await step("long", sheet, { controller.selection = GitController.Selection(path: "b-long.swift", staged: false) }) {
            controller.diff.first?.path == "b-long.swift" && !controller.diffLoading
        }
        print("PERF changes tab: choose the long file \(long)")
        let diffScroll = try XCTUnwrap(diff(in: window), "The diff scrolls")
        let sheetWindow = window
        let first = try await scroll(diffScroll, in: sheetWindow, from: 0, through: 3_000)
        print(String(format: "PERF changes tab: scrolling the long diff %.2f ms a step, worst %.1f ms, %d cycles, %d rows built", first.mean, first.worst, first.cycles, first.rows))

        // A file ticked and unticked twenty times.
        let ticks = try await step("ticks", sheet, settle: 0.3, {
            for index in 0..<20 {
                if index.isMultiple(of: 2) { controller.checked.insert("a-first.swift") } else { controller.checked.remove("a-first.swift") }
                sheetWindow.contentView?.layoutSubtreeIfNeeded(); sheetWindow.displayIfNeeded()
            }
        }) { true }
        print("PERF changes tab: 20 ticks \(ticks)")

        // Typing a commit message.
        let typing = try await step("typing", sheet, settle: 0.3, {
            for character in "Rewrite the long file" {
                controller.commitMessage.append(character)
                sheetWindow.contentView?.layoutSubtreeIfNeeded(); sheetWindow.displayIfNeeded()
            }
        }) { true }
        print("PERF changes tab: typing 21 characters \(typing)")

        // The whole diff.
        let whole = try await step("whole", sheet, { controller.wholeDiffShown = GitController.diffIdentity(path: "b-long.swift", staged: false) }) { true }
        print("PERF changes tab: the whole long diff \(whole)")
        let deep = try await scroll(diffScroll, in: sheetWindow, from: 60_000, through: 3_000)
        print(String(format: "PERF changes tab: scrolling deep in the whole diff %.2f ms a step, worst %.1f ms, %d cycles, %d rows built", deep.mean, deep.worst, deep.cycles, deep.rows))
        // The tabs glide for some 300 ms after the switch, and every frame of
        // it laid the sheet out: the toolbar's fetch, pull and push symbols,
        // measured and not shown, were built afresh each time.
        RedrawCounter.reset(); RedrawCounter.recording = true
        let split = try await step("split", sheet, { controller.splitDiff = true }) { true }
        let glide = RedrawCounter.counts; RedrawCounter.recording = false; RedrawCounter.reset()
        print("PERF changes tab: side by side \(split), panel parts drawn \(glide)")
        controller.splitDiff = false
        let withWhole = footprint()

        // Another file, then the history.
        let other = try await step("other", sheet, { controller.selection = GitController.Selection(path: "Sources/Module0/File1.swift", staged: false) }) {
            controller.diff.first?.path == "Sources/Module0/File1.swift" && !controller.diffLoading
        }
        print("PERF changes tab: choose a short file \(other)")
        let history = try await step("history", sheet, { controller.panel = .history }) { controller.commits.count == 30 }
        print("PERF changes tab: the history \(history)")
        let revised = try XCTUnwrap(controller.commits.first)
        let medium = try await step("medium", sheet, { controller.selectedCommit = revised }) {
            controller.detail?.commit == revised && !controller.commitLoading && !controller.detailDiff.isEmpty
        }
        print("PERF changes tab: a commit of 25 files \(medium)")
        let seed = try XCTUnwrap(controller.commits.last)
        let big = try await step("big", sheet, { controller.selectedCommit = seed }) { controller.detail?.commit == seed && !controller.commitLoading }
        print("PERF changes tab: the seed commit's chips \(big) deferred \(controller.detailDiffDeferred) files \(controller.detail?.files.count ?? 0)")
        let chip = try await step("chip", sheet, { controller.detailFile = "b-long.swift" }) { !controller.detailFileDiff.isEmpty && !controller.commitLoading }
        print("PERF changes tab: the long file in the seed commit \(chip)")
        let historyScroll = try XCTUnwrap(diff(in: window), "The commit's diff scrolls")
        let embedded = try await scroll(historyScroll, in: sheetWindow, from: 0, through: 3_000)
        print(String(format: "PERF changes tab: scrolling the commit's long file %.2f ms a step, worst %.1f ms, %d cycles, %d rows built", embedded.mean, embedded.worst, embedded.cycles, embedded.rows))
        let atHistory = footprint()

        let shown = try XCTUnwrap(tab)
        let close = try await step("close", { window }, settle: 1.0, { harness.host.close(shown) }) { harness.host.pane.tabs.isEmpty }
        print("PERF changes tab: close \(close)")
        try await Task.sleep(for: .milliseconds(500))
        print(String(format: "PERF changes tab memory: before %.1f MB, whole long diff %.1f MB, history %.1f MB, closed %.1f MB", before, withWhole, atHistory, footprint()))

        // One layout-cycle report at most as a panel with a lazy list opens, and none after.
        XCTAssertLessThanOrEqual(open.cycles, 1, "Opening")
        let steps = [("the long file", long.cycles), ("ticks", ticks.cycles), ("typing", typing.cycles), ("the whole diff", whole.cycles),
                     ("side by side", split.cycles), ("another file", other.cycles), ("the history", history.cycles),
                     ("a commit", medium.cycles), ("a big commit", big.cycles), ("its long file", chip.cycles), ("closing", close.cycles),
                     ("scrolling", first.cycles + deep.cycles + embedded.cycles)]
        for (name, cycles) in steps { XCTAssertEqual(cycles, 0, "Layout cycles: \(name)") }
        // Rows are built as they come into view: of the 1,500 the diff shows
        // before "Show the whole diff", the ones on screen; scrolling builds
        // the ones it reaches; the commit box builds none.
        XCTAssertLessThan(long.rows, 300, "Choosing the long file builds the rows on screen")
        XCTAssertLessThan(first.rows, 1_000, "Scrolling 3,000 points builds the rows it reaches")
        XCTAssertEqual(ticks.rows, 0, "Ticking a file builds no diff row")
        XCTAssertEqual(typing.rows, 0, "Typing a commit message builds no diff row")
        // Generous Debug bounds on the main thread's own clock, several times
        // what the table costs and under what SwiftUI's rows cost (above).
        // The panel's parts draw only for what they show: the next file and
        // a commit of four hundred files take some 10 to 20 ms, a keystroke
        // 5, where the whole panel drawn again for each took 40 to 50.
        XCTAssertLessThan(split.longest, 100, String(format: "Side by side took a %.0f ms step", split.longest))
        for part in ["GitPanelToolbar", "GitRemoteIconButtons", "GitChangesList", "GitCommitBox", "GitPanelDetail"] {
            XCTAssertEqual(glide[part, default: 0], 0, "Side by side and its glide draw no \(part): \(glide)")
        }
        XCTAssertLessThan(deep.worst, 50, String(format: "A jump deep into the whole diff took %.0f ms", deep.worst))
        XCTAssertLessThan(other.longest, 50, String(format: "The next file after the whole diff took a %.0f ms step", other.longest))
        XCTAssertLessThan(big.longest, 50, String(format: "A commit of four hundred files took a %.0f ms step", big.longest))
        XCTAssertLessThan(first.mean, 3, String(format: "A scroll step through the long diff costs %.1f ms", first.mean))
        XCTAssertLessThan(deep.mean, 3, String(format: "A scroll step deep in the whole diff costs %.1f ms", deep.mean))
        XCTAssertLessThan(embedded.mean, 6, String(format: "A scroll step through a commit's long file costs %.1f ms", embedded.mean))
        XCTAssertLessThan(typing.longest, 30, String(format: "A keystroke beside the long diff costs up to %.0f ms", typing.longest))
    }

    /// The tab as the reader opens it, from the workspace window, twice, on
    /// the project's own folder, where the app keeps its state as it runs.
    /// The sheet it replaced said "Not a git repository" in its first frame,
    /// in the moment before its first read; once the panel took that
    /// message's place, every update reported layout cycles until it closed:
    /// 44 for each opening and 8 for each closing.
    @MainActor func testTheTabFromTheWorkspaceWindowLaysOutWithoutCycles() async throws {
        let folder = try repository("changes-cycles")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try start(folder)
        try Data("func charge() {}\n".utf8).write(to: folder.appendingPathComponent("PaymentClient.swift"))
        try git(["add", "."], in: folder); try git(["commit", "-q", "-m", "Add the payment client"], in: folder)
        try Data("func charge() { retry() }\n".utf8).write(to: folder.appendingPathComponent("PaymentClient.swift"))
        try Data("# Retry notes\n".utf8).write(to: folder.appendingPathComponent("NOTES.md"))
        let workspace = WorkspaceRecord(id: "changes-project", path: folder.path, trusted: true)
        var profile = ProfileRecord(); profile.id = "changes-profile"; profile.name = "Changes"
        profile.baseUrl = "http://127.0.0.1:9/v1"; profile.modelId = "changes-model"
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        let saved = profile
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [workspace]; $0.profiles = [VaultProfile(profile: saved, apiKey: "synthetic-changes-key")]
            $0.automaticUpdateChecks = false
        }
        let model = WorkspaceModel(stateRoot: folder.appendingPathComponent("app-state"), vault: vault)
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        model.tabs.showsWindows = false
        await model.restore()
        let chat = ChatRecord(id: "changes-chat", workspaceID: workspace.id, title: "Changes", path: nil, profileID: profile.id)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.select(chat.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceView(model: model))
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            model.tabs.tearDown()
            window.contentView = nil; window.close()
            model.report.suspend(); model.shutdown()
            try? await model.traces.close(); await model.store?.close()
        }
        try await Task.sleep(for: .milliseconds(800))
        for pass in 1...2 {
            var shown = false
            let open = try await layoutCycles {
                model.showChanges(in: workspace.id); try await Task.sleep(for: .milliseconds(2_200))
                shown = (model.tabs.tab(kind: ChangesTab.kind, key: workspace.id) as? ChangesTab)?.controller.statusRead == true
            }
            let tab = try XCTUnwrap(model.tabs.tab(kind: ChangesTab.kind, key: workspace.id))
            let close = try await layoutCycles { model.tabs.close(tab); try await Task.sleep(for: .milliseconds(800)) }
            print("PERF changes tab from the workspace window, pass \(pass): \(open) cycles opening, \(close) closing")
            XCTAssertTrue(shown, "The Changes tab opened and read")
            XCTAssertLessThanOrEqual(open, 1, "Opening \(pass): the lazy list's one report at most")
            XCTAssertEqual(close, 0, "Closing \(pass)")
        }
    }

    /// Until its first read has answered, the panel says nothing about the
    /// folder; then it says what the read found.
    @MainActor func testThePanelWaitsForItsFirstReadBeforeNamingTheFolder() async throws {
        let folder = try repository("changes-first-read"), plain = try repository("changes-plain")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: plain) }
        try start(folder)
        // A controller starts reading as it is made.
        let repository = GitController(roots: [folder.path]), notOne = GitController(roots: [plain.path])
        XCTAssertFalse(repository.statusRead); XCTAssertFalse(notOne.statusRead)
        XCTAssertNil(repository.repositoryRoot); XCTAssertFalse(repository.loading, "Nothing has answered yet")
        try await eventually("read both folders") { repository.statusRead && notOne.statusRead && !repository.loading && !notOne.loading }
        XCTAssertNotNil(repository.repositoryRoot)
        XCTAssertTrue(repository.status.entries.isEmpty, "A new repository has no changes")
        XCTAssertNil(notOne.repositoryRoot, "A plain folder is no repository")
    }

    /// A closed Changes tab lets go of everything it had, before the test
    /// returns: its controller, with the diff, the history and the commits it
    /// had read, and every view of its panel. Opened three times, each over
    /// the whole long diff and two commits, and closed, nothing of any of the
    /// three is left. The footprint is printed, not held: nothing separates
    /// it reliably enough to assert.
    @MainActor func testAClosedTabLetsGoOfWhatItRead() async throws {
        let root = try bigRepository()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let harness = ChangesTabHarness()
        addTeardownBlock { @MainActor in harness.tearDown() }
        try await Task.sleep(for: .milliseconds(500))
        let before = footprint()
        var closed: [Double] = []
        var everything: [() -> NSView?] = [], controllers: [() -> GitController?] = []
        for pass in 1...3 {
            // Held weakly, as nothing but the tab should hold them.
            weak var tab = autoreleasepool { harness.open(root.path) }
            try await eventually("opening \(pass)") { tab?.hasController == true && tab?.controller.status.entries.count == Self.changedFiles + 2 }
            weak var controller = tab?.controller
            controllers.append { [weak controller] in controller }
            autoreleasepool { controller?.selection = GitController.Selection(path: "b-long.swift", staged: false) }
            try await eventually("the long diff") { controller?.diff.first?.path == "b-long.swift" && controller?.diffLoading == false }
            autoreleasepool {
                controller?.wholeDiffShown = GitController.diffIdentity(path: "b-long.swift", staged: false)
                harness.draw()
                controller?.panel = .history
            }
            try await eventually("the history") { controller?.commits.count == 30 }
            let revised = try XCTUnwrap(controller?.commits.first), seed = try XCTUnwrap(controller?.commits.last)
            autoreleasepool { controller?.selectedCommit = revised }
            try await eventually("a commit's diff") { controller?.detail?.commit == revised && controller?.detailDiff.isEmpty == false && controller?.commitLoading == false }
            autoreleasepool { controller?.selectedCommit = seed }
            try await eventually("the seed commit") { controller?.detail?.commit == seed && controller?.commitLoading == false }
            autoreleasepool { controller?.detailFile = "b-long.swift" }
            try await eventually("its long file") { controller?.detailFileDiff.isEmpty == false && controller?.commitLoading == false }
            // Every view the panel shows, held weakly.
            let shown = autoreleasepool { () -> [() -> NSView?] in
                harness.draw()
                let content = harness.window.contentView ?? NSView()
                return descendants(NSView.self, in: content).filter { $0 !== content }.map { view in { [weak view] in view } }
            }
            XCTAssertGreaterThan(shown.count, 50, "Opening \(pass): the panel's views are in the window")
            autoreleasepool { if let tab { harness.host.close(tab) } }
            try await eventually("closing \(pass)") { harness.host.pane.tabs.isEmpty }
            try await eventually("the closed tab \(pass) to be let go of") { autoreleasepool { tab == nil } }
            try await eventually("the closed tab \(pass)'s controller to be let go of") { autoreleasepool { controller == nil } }
            try await eventually("the closed tab \(pass)'s panel to be out of every window") {
                autoreleasepool { descendants(GitDiffTableView.self, in: harness.window.contentView ?? NSView()).isEmpty }
            }
            everything += shown
            try await Task.sleep(for: .milliseconds(800))
            closed.append(footprint())
        }
        print(String(format: "PERF closed Changes tabs: footprint %.1f MB before, %@ MB after each of three closes",
                     before, closed.map { String(format: "%.1f", $0) }.joined(separator: ", ")))
        XCTAssertEqual(controllers.compactMap { $0() }.count, 0, "No closed tab's controller is left")
        // The window's own views go with it: nothing of any closed tab is left
        // but the few views AppKit keeps of a text view after it has gone.
        autoreleasepool { harness.window.contentView = NSView() }
        try await eventually("every closed tab's views to be let go of") {
            autoreleasepool { everything.allSatisfy { view in view().map { String(describing: type(of: $0)).hasPrefix("_NS") } ?? true } }
        }
    }

    /// A tab hidden under another reads nothing; shown again it reads what
    /// changed, and keeps the reader's place. Closed and opened again, it is
    /// a new tab and reads everything afresh, as a first open does: the first
    /// file chosen, every file ticked, no message, the Changes tab.
    @MainActor func testATabHiddenReadsNothingAndATabOpenedAgainReadsAfresh() async throws {
        let folder = try repository("changes-reopen")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try start(folder)
        try "one\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "two\n".write(to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: folder); try git(["commit", "-q", "-m", "Seed"], in: folder)
        try "one!\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "two!\n".write(to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let harness = ChangesTabHarness()
        addTeardownBlock { @MainActor in harness.tearDown() }
        let tab = harness.open(folder.path)
        try await eventually("the first read") { tab.hasController && tab.controller.status.entries.count == 2 && !tab.controller.diff.isEmpty && !tab.controller.diffLoading }
        let controller = tab.controller
        controller.selection = GitController.Selection(path: "b.txt", staged: false)
        controller.checked.remove("a.txt"); controller.commitMessage = "Draft"
        try await eventually("b.txt's diff") { controller.diff.first?.path == "b.txt" && !controller.diffLoading }

        // Another tab over it: hidden, it reads nothing.
        let other = harness.host.open(kind: FileTab.kind, key: FileTab.key(for: folder.appendingPathComponent("a.txt"))) {
            FileTab(url: folder.appendingPathComponent("a.txt"), projectID: nil)
        }
        try await eventually("hidden") { controller.suspended && !controller.isWatching }
        try "three\n".write(to: folder.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertEqual(controller.status.entries.count, 2, "A hidden tab reads nothing")
        harness.host.activate(tab)
        try await eventually("shown again, what changed read") { controller.status.entries.count == 3 && controller.isWatching }
        XCTAssertEqual(controller.selection?.path, "b.txt"); XCTAssertEqual(controller.commitMessage, "Draft")
        XCTAssertEqual(controller.checkedCount, 1, "b.txt ticked, a.txt unticked, c.txt not ticked for the reader")

        harness.host.close(tab); harness.host.close(other)
        let again = harness.open(folder.path)
        XCTAssertFalse(again === tab, "A new tab")
        try await eventually("the new tab's read") { again.hasController && again.controller.status.entries.count == 3 && !again.controller.diff.isEmpty && !again.controller.diffLoading }
        XCTAssertEqual(again.controller.selection?.path, "a.txt", "The first file, as a first open chooses it")
        XCTAssertEqual(again.controller.checkedCount, 3, "Every file ticked")
        XCTAssertEqual(again.controller.commitMessage, "")
        XCTAssertEqual(again.controller.panel, .changes)
        XCTAssertTrue(again.controller.isWatching)
    }

    /// The diff table's scroll view, whichever panel shows it.
    @MainActor private func diff(in window: NSWindow) -> NSScrollView? {
        descendants(GitDiffTableView.self, in: window.contentView ?? NSView()).first?.enclosingScrollView
    }

    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }
}

/// A Changes tab as the app shows one, in a window of the test's own: a tab
/// host that keeps nothing across launches and shows no windows of its own,
/// its pane's tabs drawn as a window of tabs draws them (`TabWindowRoot`).
@MainActor final class ChangesTabHarness {
    let host = TabHost(defaults: nil)
    let window: NSWindow
    init(width: CGFloat = 1280, height: CGFloat = 820) {
        host.showsWindows = false
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TabWindowRoot(host: host, container: host.pane).piTabRoot())
        window.makeKeyAndOrderFront(nil)
    }
    /// Opens a project's Changes tab over one folder, or shows it.
    @discardableResult func open(_ root: String, project: String = "changes-project") -> ChangesTab {
        let tab = host.open(kind: ChangesTab.kind, key: project) { ChangesTab(projectID: project, name: "project", roots: [root]) }
        draw()
        return tab as! ChangesTab
    }
    func draw() { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
    func tearDown() {
        host.tearDown()
        window.contentView = nil; window.close()
    }
}
