import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// The Changes sheet as the reader meets it: presented over a window, on a
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
final class ChangesSheetFrameTests: GitPanelTestCase, SerialTestLane {
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

    @MainActor func testTheChangesSheetOverABigRepository() async throws {
        let root = try bigRepository()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let controller = GitController(roots: [root.path])
        let presenter = ChangesSheetPresenter()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ChangesSheetHost(presenter: presenter, controller: controller))
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in presenter.showing = false; window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(500))
        let sheet = { window.attachedSheet }
        let before = footprint()

        // Opened: the list of changes, and the first file's diff.
        let open = try await step("open", sheet, settle: 1.5, { presenter.showing = true }) {
            controller.status.entries.count == Self.changedFiles + 2 && !controller.diff.isEmpty && !controller.diffLoading && window.attachedSheet != nil
        }
        print("PERF changes sheet: open \(open)")

        // The long file: 1,500 of its 10,000 rows until the whole diff is asked for.
        let long = try await step("long", sheet, { controller.selection = GitController.Selection(path: "b-long.swift", staged: false) }) {
            controller.diff.first?.path == "b-long.swift" && !controller.diffLoading
        }
        print("PERF changes sheet: choose the long file \(long)")
        let scrolls = try XCTUnwrap(sheet().map { descendants(NSScrollView.self, in: $0.contentView ?? NSView()) })
        let diffScroll = try XCTUnwrap(scrolls.max { $0.frame.width < $1.frame.width }, "The diff scrolls")
        let sheetWindow = try XCTUnwrap(sheet())
        let first = try await scroll(diffScroll, in: sheetWindow, from: 0, through: 3_000)
        print(String(format: "PERF changes sheet: scrolling the long diff %.2f ms a step, worst %.1f ms, %d cycles, %d rows built", first.mean, first.worst, first.cycles, first.rows))

        // A file ticked and unticked twenty times.
        let ticks = try await step("ticks", sheet, settle: 0.3, {
            for index in 0..<20 {
                if index.isMultiple(of: 2) { controller.checked.insert("a-first.swift") } else { controller.checked.remove("a-first.swift") }
                sheetWindow.contentView?.layoutSubtreeIfNeeded(); sheetWindow.displayIfNeeded()
            }
        }) { true }
        print("PERF changes sheet: 20 ticks \(ticks)")

        // Typing a commit message.
        let typing = try await step("typing", sheet, settle: 0.3, {
            for character in "Rewrite the long file" {
                controller.commitMessage.append(character)
                sheetWindow.contentView?.layoutSubtreeIfNeeded(); sheetWindow.displayIfNeeded()
            }
        }) { true }
        print("PERF changes sheet: typing 21 characters \(typing)")

        // The whole diff.
        let whole = try await step("whole", sheet, { controller.wholeDiffShown = GitController.diffIdentity(path: "b-long.swift", staged: false) }) { true }
        print("PERF changes sheet: the whole long diff \(whole)")
        let deep = try await scroll(diffScroll, in: sheetWindow, from: 60_000, through: 3_000)
        print(String(format: "PERF changes sheet: scrolling deep in the whole diff %.2f ms a step, worst %.1f ms, %d cycles, %d rows built", deep.mean, deep.worst, deep.cycles, deep.rows))
        // The tabs glide for some 300 ms after the switch, and every frame of
        // it laid the sheet out: the toolbar's fetch, pull and push symbols,
        // measured and not shown, were built afresh each time.
        RedrawCounter.reset(); RedrawCounter.recording = true
        let split = try await step("split", sheet, { controller.splitDiff = true }) { true }
        let glide = RedrawCounter.counts; RedrawCounter.recording = false; RedrawCounter.reset()
        print("PERF changes sheet: side by side \(split), panel parts drawn \(glide)")
        controller.splitDiff = false
        let withWhole = footprint()

        // Another file, then the history.
        let other = try await step("other", sheet, { controller.selection = GitController.Selection(path: "Sources/Module0/File1.swift", staged: false) }) {
            controller.diff.first?.path == "Sources/Module0/File1.swift" && !controller.diffLoading
        }
        print("PERF changes sheet: choose a short file \(other)")
        let history = try await step("history", sheet, { controller.panel = .history }) { controller.commits.count == 30 }
        print("PERF changes sheet: the history \(history)")
        let revised = try XCTUnwrap(controller.commits.first)
        let medium = try await step("medium", sheet, { controller.selectedCommit = revised }) {
            controller.detail?.commit == revised && !controller.commitLoading && !controller.detailDiff.isEmpty
        }
        print("PERF changes sheet: a commit of 25 files \(medium)")
        let seed = try XCTUnwrap(controller.commits.last)
        let big = try await step("big", sheet, { controller.selectedCommit = seed }) { controller.detail?.commit == seed && !controller.commitLoading }
        print("PERF changes sheet: the seed commit's chips \(big) deferred \(controller.detailDiffDeferred) files \(controller.detail?.files.count ?? 0)")
        let chip = try await step("chip", sheet, { controller.detailFile = "b-long.swift" }) { !controller.detailFileDiff.isEmpty && !controller.commitLoading }
        print("PERF changes sheet: the long file in the seed commit \(chip)")
        let historyScroll = try XCTUnwrap(descendants(NSScrollView.self, in: sheetWindow.contentView ?? NSView()).max { $0.frame.width < $1.frame.width })
        let embedded = try await scroll(historyScroll, in: sheetWindow, from: 0, through: 3_000)
        print(String(format: "PERF changes sheet: scrolling the commit's long file %.2f ms a step, worst %.1f ms, %d cycles, %d rows built", embedded.mean, embedded.worst, embedded.cycles, embedded.rows))
        let atHistory = footprint()

        let close = try await step("close", { window }, settle: 1.0, { presenter.showing = false }) { window.attachedSheet == nil }
        print("PERF changes sheet: close \(close)")
        try await Task.sleep(for: .milliseconds(500))
        print(String(format: "PERF changes sheet memory: before %.1f MB, whole long diff %.1f MB, history %.1f MB, closed %.1f MB", before, withWhole, atHistory, footprint()))

        // One layout-cycle report as a sheet with a lazy list opens, and none after.
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

    /// The sheet as the reader opens it, from the workspace window, twice,
    /// on the project's own folder, where the app keeps its state as it runs.
    /// Its first frame said "Not a git repository", in the moment before its
    /// first read; once the panel took that message's place, every update of
    /// the sheet reported layout cycles until it closed: 44 for each opening
    /// and 8 for each closing. What is left is the one report SwiftUI makes as
    /// a sheet with a lazy list opens.
    @MainActor func testTheSheetFromTheWorkspaceWindowLaysOutWithoutCycles() async throws {
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
        await model.restore()
        let chat = ChatRecord(id: "changes-chat", workspaceID: workspace.id, title: "Changes", path: nil, profileID: profile.id)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.select(chat.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceView(model: model))
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil; window.close()
            model.report.suspend(); model.shutdown()
            try? await model.traces.close(); await model.store?.close()
        }
        try await Task.sleep(for: .milliseconds(800))
        for pass in 1...2 {
            var shown = false
            let open = try await layoutCycles {
                model.showChanges(in: workspace.id); try await Task.sleep(for: .milliseconds(2_200))
                shown = window.attachedSheet != nil
            }
            let close = try await layoutCycles { model.showGit = false; try await Task.sleep(for: .milliseconds(800)) }
            print("PERF changes sheet from the workspace window, pass \(pass): \(open) cycles opening, \(close) closing")
            XCTAssertTrue(shown, "The Changes sheet opened")
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

    /// A closed Changes sheet lets go of everything it had, before the test
    /// returns. XCTest keeps whatever AppKit autoreleases until a test
    /// returns, and here SwiftUI's own sheets kept each closed Changes sheet's
    /// window, views and controller, with the diff, the history and the
    /// commits it had read: three closes took the process from 38 to 187 MB.
    /// Emptying the controller brought that to 137 MB; about 20 MB of views a
    /// close stayed. The workspace now presents the sheet in a window of its
    /// own (`piSheetWindow`): opened as the workspace window opens it, a new
    /// controller each time, and closed three times over the whole long diff
    /// and two commits, nothing of any of the three sheets is left: not its
    /// views, not its controller. The window and its hosting view are the next
    /// sheet's, and show none of it. The footprint is printed, not held:
    /// nothing separates it reliably enough to assert.
    @MainActor func testAClosedSheetLetsGoOfWhatItRead() async throws {
        let root = try bigRepository()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let made = MadeControllers(), presenter = ChangesSheetPresenter()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FreshChangesSheetHost(presenter: presenter, root: root.path, made: made.add))
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in presenter.showing = false; window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(500))
        let before = footprint()
        var closed: [Double] = []
        var everything: [() -> NSView?] = []
        for pass in 1...3 {
            presenter.showing = true
            try await eventually("opening \(pass)") { made.newest?.status.entries.count == Self.changedFiles + 2 && window.attachedSheet != nil }
            // Held weakly, as nothing but the sheet should hold them.
            weak var sheet = window.attachedSheet, controller = made.newest
            let host = try XCTUnwrap(window.attachedSheet?.contentView)
            XCTAssertTrue(sheet === PiSheetWindow.newest, "Opening \(pass): the sheet is a window of the app's own")
            controller?.selection = GitController.Selection(path: "b-long.swift", staged: false)
            try await eventually("the long diff") { controller?.diff.first?.path == "b-long.swift" && controller?.diffLoading == false }
            controller?.wholeDiffShown = GitController.diffIdentity(path: "b-long.swift", staged: false)
            sheet?.contentView?.layoutSubtreeIfNeeded(); sheet?.displayIfNeeded()
            controller?.panel = .history
            try await eventually("the history") { controller?.commits.count == 30 }
            let revised = try XCTUnwrap(controller?.commits.first), seed = try XCTUnwrap(controller?.commits.last)
            controller?.selectedCommit = revised
            try await eventually("a commit's diff") { controller?.detail?.commit == revised && controller?.detailDiff.isEmpty == false && controller?.commitLoading == false }
            controller?.selectedCommit = seed
            try await eventually("the seed commit") { controller?.detail?.commit == seed && controller?.commitLoading == false }
            controller?.detailFile = "b-long.swift"
            try await eventually("its long file") { controller?.detailFileDiff.isEmpty == false && controller?.commitLoading == false }
            sheet?.contentView?.layoutSubtreeIfNeeded(); sheet?.displayIfNeeded()
            // Every view the panel shows, held weakly.
            let shown = descendants(NSView.self, in: host).filter { $0 !== host }.map { view in { [weak view] in view } }
            XCTAssertGreaterThan(shown.count, 50, "Opening \(pass): the panel's views are in the sheet")
            presenter.showing = false
            try await eventually("closing \(pass)") { window.attachedSheet == nil }
            // Once off screen, nothing of the sheet is left: its controller
            // goes, and none of its views is in a window or in the hosting
            // view, which with the window opens the next sheet, empty.
            try await eventually("the closed sheet \(pass)'s controller to be let go of") { controller == nil }
            try await eventually("the closed sheet \(pass)'s views to be out of every window") {
                shown.allSatisfy { $0().map { $0.window == nil && !$0.isDescendant(of: host) } ?? true }
            }
            XCTAssertTrue(descendants(NSScrollView.self, in: host).isEmpty, "Closed sheet \(pass): its hosting view shows nothing")
            everything += shown
            try await Task.sleep(for: .milliseconds(800))
            closed.append(footprint())
        }
        let alive = made.all.compactMap { $0() }
        print(String(format: "PERF closed Changes sheets: footprint %.1f MB before, %@ MB after each of three closes; %d of %d controllers alive",
                     before, closed.map { String(format: "%.1f", $0) }.joined(separator: ", "), alive.count, made.all.count))
        XCTAssertEqual(made.all.count, 3, "A controller for each opening, as the workspace window makes them")
        XCTAssertEqual(alive.count, 0, "No closed sheet's controller is left")
        // The window and hosting view kept for the next sheet go with what
        // presents them, and no view of any of the three sheets is left.
        window.contentView = NSView()
        try await eventually("every closed sheet's views to be let go of") { everything.allSatisfy { $0() == nil } }
    }

    /// A panel opened again over the controller of a sheet that closed reads
    /// everything afresh, as a first open does: the first file chosen, every
    /// file ticked, no message, the Changes tab, and what changed meanwhile.
    /// While closed it reads nothing.
    @MainActor func testASheetOpenedAgainReadsAfresh() async throws {
        let folder = try repository("changes-reopen")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try start(folder)
        try "one\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "two\n".write(to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: folder); try git(["commit", "-q", "-m", "Seed"], in: folder)
        try "one!\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "two!\n".write(to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let controller = GitController(roots: [folder.path]), presenter = ChangesSheetPresenter()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ChangesSheetHost(presenter: presenter, controller: controller))
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in presenter.showing = false; window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(500))

        presenter.showing = true
        try await eventually("the first read") { controller.status.entries.count == 2 && !controller.diff.isEmpty && !controller.diffLoading }
        controller.selection = GitController.Selection(path: "b.txt", staged: false)
        controller.checked.remove("a.txt"); controller.commitMessage = "Draft"
        try await eventually("b.txt's diff") { controller.diff.first?.path == "b.txt" && !controller.diffLoading }
        controller.panel = .history
        try await eventually("the history") { controller.commits.count == 1 }
        presenter.showing = false
        try await eventually("the closed sheet to let go") { window.attachedSheet == nil && controller.status.entries.isEmpty && controller.diff.isEmpty }
        XCTAssertFalse(controller.statusRead); XCTAssertNil(controller.repositoryRoot); XCTAssertTrue(controller.commits.isEmpty)
        XCTAssertFalse(controller.isWatching)

        try "three\n".write(to: folder.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        await controller.refresh()
        XCTAssertTrue(controller.status.entries.isEmpty, "A closed sheet's controller reads nothing")

        presenter.showing = true
        try await eventually("the second read") { controller.status.entries.count == 3 && !controller.diff.isEmpty && !controller.diffLoading }
        XCTAssertEqual(controller.selection?.path, "a.txt", "The first file, as a first open chooses it")
        XCTAssertEqual(controller.checkedCount, 3, "Every file ticked")
        XCTAssertEqual(controller.commitMessage, "")
        XCTAssertEqual(controller.panel, .changes)
        XCTAssertTrue(controller.isWatching, "Watching again")
    }

    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }
}

/// Presents the Changes sheet as the workspace window does, over a
/// controller the test drives.
@MainActor final class ChangesSheetPresenter: ObservableObject {
    @Published var showing = false
}

/// Presents the Changes sheet as the workspace window does, in a sheet
/// window of the app's own, a new controller for each opening, and hands
/// each to `made`.
struct FreshChangesSheetHost: View {
    @ObservedObject var presenter: ChangesSheetPresenter
    let root: String
    let made: @MainActor (GitController) -> Void
    var body: some View {
        Color.piWindow
            .buttonStyle(.piSecondary)
            .toggleStyle(.switch)
            .piSheetWindow(isPresented: $presenter.showing) {
                GitPanelView(controller: { let controller = GitController(roots: [root]); made(controller); return controller }())
            }
    }
}

/// The controllers a `FreshChangesSheetHost` made, held weakly.
@MainActor final class MadeControllers {
    private(set) var all: [() -> GitController?] = []
    var newest: GitController? { all.last?() }
    func add(_ controller: GitController) { all.append { [weak controller] in controller } }
}

struct ChangesSheetHost: View {
    @ObservedObject var presenter: ChangesSheetPresenter
    let controller: GitController
    var body: some View {
        Color.piWindow
            .buttonStyle(.piSecondary)
            .toggleStyle(.switch)
            .piSheetWindow(isPresented: $presenter.showing) { GitPanelView(controller: controller) }
    }
}
