import XCTest
import SwiftUI
import AppKit
import Combine
@testable import PiApp
@testable import GitView

/// A Changes panel reads and watches only while it is on screen. Hidden
/// (another tab shown over it, the report over the tabs), it reads nothing,
/// not even after a write of its own that finishes meanwhile; shown again,
/// it reads what changed without moving the reader: the file chosen, the
/// ticks, the history paged in, and a commit's read that hiding stopped. The
/// panel's own view says when it comes and goes, once for a move between
/// windows, and a discard question the panel has up goes down, unanswered,
/// when the panel does.
final class GitPanelShownTests: GitPanelTestCase {
    /// `a.txt` and `b.txt` changed on top of `commits` commits.
    func changedRepository(commits: Int) throws -> URL {
        let root = try repository("panel-shown")
        try start(root)
        try "one\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "two\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        if commits > 1 {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "for i in $(seq \(commits - 1)); do git -c commit.gpgsign=false commit -q --allow-empty -m \"Note $i\" || exit 1; done"]
            process.currentDirectoryURL = root
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "the history is written")
        }
        try "one!\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "two!\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        return root
    }

    @MainActor func testAHiddenPanelReadsNothingAndShownAgainKeepsTheReadersPlace() async throws {
        let root = try changedRepository(commits: 60)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let controller = GitController(roots: [root.path])
        defer { controller.letGo() }
        controller.setShown(true)
        try await eventually("the first read") { controller.statusRead && controller.status.entries.count == 2 && !controller.diff.isEmpty && !controller.diffLoading }
        XCTAssertEqual(controller.selection?.path, "a.txt", "Shown for the first time, the first file is chosen")
        // The reader's place: another file, a file unticked, the history paged in.
        controller.selection = GitController.Selection(path: "b.txt", staged: false)
        controller.checked.remove("a.txt")
        try await eventually("b.txt's diff") { controller.diff.first?.path == "b.txt" && !controller.diffLoading }
        controller.panel = .history
        try await eventually("the first page of history") { controller.commits.count == 50 }
        await controller.loadMoreHistory()
        XCTAssertEqual(controller.commits.count, 60, "Every commit, paged in")
        controller.panel = .changes

        controller.setShown(false)
        XCTAssertTrue(controller.suspended); XCTAssertFalse(controller.isWatching, "Hidden: no watch")
        try "three\n".write(to: root.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        await controller.refresh()
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertEqual(controller.status.entries.count, 2, "A hidden panel reads nothing, asked or not")

        var spinners: [Bool] = []
        let watch = controller.$loading.sink { spinners.append($0) }
        defer { watch.cancel() }
        controller.setShown(true)
        try await eventually("what changed while it was hidden") { controller.status.entries.count == 3 && controller.isWatching }
        // Another read nobody asked for, as the watch makes: awaited whole,
        // its history read included.
        await controller.refresh(automatic: true)
        XCTAssertEqual(controller.selection?.path, "b.txt", "The reader's file is still the one chosen")
        XCTAssertFalse(controller.checked.contains("a.txt"), "What they unticked stays unticked")
        XCTAssertEqual(controller.commits.count, 60, "The history paged in stays paged in")
        XCTAssertFalse(spinners.contains(true), "Read quietly: no spinner for a read nobody asked for")
    }

    /// A write started just before the panel hides still happens; its read
    /// waits for the panel to show.
    @MainActor func testAWriteThatFinishesWhileHiddenIsReadWhenShown() async throws {
        let root = try changedRepository(commits: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let controller = GitController(roots: [root.path])
        defer { controller.letGo() }
        controller.setShown(true)
        try await eventually("the first read") { controller.statusRead && controller.status.entries.count == 2 && !controller.loading }
        controller.commitMessage = "Commit both"
        let write = Task { await controller.commitChecked() }
        controller.setShown(false)
        await write.value
        XCTAssertEqual(try git(["log", "--format=%s", "-1"], in: root).trimmingCharacters(in: .whitespacesAndNewlines), "Commit both", "The write happened")
        XCTAssertNotNil(controller.lastCommit)
        XCTAssertEqual(controller.status.entries.count, 2, "Its read waits for the panel to show")
        XCTAssertFalse(controller.isWatching, "and the watch stays off")
        controller.setShown(true)
        try await eventually("the commit, read") { controller.status.entries.isEmpty && controller.isWatching }
    }

    /// A commit's read that hiding stopped is finished once the panel shows.
    @MainActor func testACommitReadThatHidingStoppedFinishesWhenShown() async throws {
        let root = try changedRepository(commits: 3)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let controller = GitController(roots: [root.path])
        defer { controller.letGo() }
        controller.setShown(true)
        try await eventually("the first read") { controller.statusRead && !controller.loading }
        controller.panel = .history
        try await eventually("the history") { controller.commits.count == 3 }
        let seed = try XCTUnwrap(controller.commits.last)
        controller.selectedCommit = seed
        XCTAssertTrue(controller.commitLoading, "Its read has started")
        controller.setShown(false)
        XCTAssertFalse(controller.commitLoading, "Hiding stopped it")
        XCTAssertNil(controller.detail)
        controller.setShown(true)
        try await eventually("the commit, read in the end") { controller.detail?.commit == seed && !controller.detailDiff.isEmpty && !controller.commitLoading }
        XCTAssertEqual(controller.selectedCommit, seed, "Still the commit the reader chose")
    }

    /// Another folder chosen while the panel is hidden is read when it shows,
    /// as choosing it on screen reads it: with a spinner, and the other
    /// folder's file no longer chosen.
    @MainActor func testAFolderChangedWhileHiddenIsReadAsChoosingItOnScreenReadsIt() async throws {
        let first = try changedRepository(commits: 1), second = try repository("panel-shown-second")
        addTeardownBlock { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        try start(second)
        try "x\n".write(to: second.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        let controller = GitController(roots: [first.path, second.path])
        defer { controller.letGo() }
        controller.setShown(true)
        try await eventually("the first folder") { controller.statusRead && controller.status.entries.count == 2 && !controller.loading && !controller.diffLoading }
        controller.selection = GitController.Selection(path: "b.txt", staged: false)
        controller.setShown(false)
        controller.root = second.path
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.status.entries.count, 2, "Nothing read while hidden")
        var spinners: [Bool] = []
        let watch = controller.$loading.sink { spinners.append($0) }
        defer { watch.cancel() }
        controller.setShown(true)
        try await eventually("the second folder") { controller.status.entries.map(\.path) == ["x.txt"] && !controller.loading }
        XCTAssertTrue(spinners.contains(true), "A read the reader asked for, by choosing the folder: with a spinner")
        XCTAssertNil(controller.selection, "The other folder's file is no longer chosen")
    }

    /// A panel hidden from its first frame (a tab made under the report page)
    /// reads nothing, not even a folder chosen meanwhile, until it is shown.
    @MainActor func testAPanelHiddenFromTheStartReadsNothingUntilShown() async throws {
        let first = try changedRepository(commits: 1), second = try changedRepository(commits: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let controller = GitController(roots: [first.path, second.path])
        defer { controller.letGo() }
        let panel = NSHostingView(rootView: GitPanelView(controller: controller))
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 1180, height: 780))
        panel.frame = holder.bounds; holder.addSubview(panel)
        holder.isHidden = true
        let window = host(Color.clear)
        defer { window.close() }
        window.contentView?.addSubview(holder)
        try await eventually("told it is hidden") { controller.suspended }
        controller.root = second.path
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(controller.statusRead, "Nothing read while hidden")
        XCTAssertFalse(controller.isWatching, "and nothing watched")
        holder.isHidden = false
        try await eventually("read once shown") { controller.isShown && controller.statusRead && !controller.loading && controller.isWatching }
        XCTAssertEqual(controller.root, second.path)
    }

    /// The panel's own view says whether it is on screen: in a window, not
    /// hidden itself or under anything hidden; and a move between windows in
    /// one turn is no hiding at all.
    @MainActor func testThePanelSaysWhenItIsOnScreen() async throws {
        let root = try changedRepository(commits: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let controller = GitController(roots: [root.path])
        defer { controller.letGo() }
        let panel = NSHostingView(rootView: GitPanelView(controller: controller))
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 1180, height: 780))
        panel.frame = holder.bounds; holder.addSubview(panel)
        let window = host(Color.clear), other = host(Color.clear)
        defer { window.close(); other.close() }
        window.contentView?.addSubview(holder)
        try await eventually("shown, and read") { controller.isShown && controller.statusRead && !controller.loading }

        holder.isHidden = true
        try await eventually("hidden under a hidden view") { controller.suspended && !controller.isWatching }
        holder.isHidden = false
        try await eventually("shown again") { controller.isShown && controller.isWatching }

        let changes = controller.shownChanges
        holder.removeFromSuperview(); other.contentView?.addSubview(holder)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.shownChanges, changes, "Moved to another window in one turn: never hidden")
        XCTAssertTrue(controller.isShown)

        holder.removeFromSuperview()
        try await eventually("out of every window: hidden") { controller.suspended }
    }

    /// A discard question goes down, unanswered, with its panel: whatever is
    /// pressed after, nothing is discarded. A second request while it is up
    /// is refused and leaves it the one to take down.
    @MainActor func testADiscardQuestionGoesDownWithItsPanel() async throws {
        let entries = [GitStatusEntry(path: "doomed.txt", originalPath: nil, indexState: ".", worktreeState: "M", untracked: false)]
        // As AppKit shows it: a sheet on the panel's window, taken down.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let questions = PiQuestion(), place = GitPanelPlace(), probe = NSView()
        window.contentView?.addSubview(probe); place.probe = probe
        var discarded = false
        place.askToDiscard(entries, questions: questions) { _ in discarded = true }
        try await eventually("the question, up") { window.attachedSheet != nil }
        let first = try XCTUnwrap(place.question)
        place.askToDiscard(entries, questions: questions) { _ in discarded = true }
        XCTAssertTrue(place.question === first, "Refused while one is up: the one up stays the one to take down")
        place.cancelQuestion()
        try await eventually("the question, down") { window.attachedSheet == nil && !questions.asking }
        XCTAssertFalse(discarded, "Taken down: nothing discarded")

        // Answered after it was taken down: still nothing.
        let held = PiQuestion()
        var answer: ((NSApplication.ModalResponse) -> Void)?
        held.present = { _, _, complete in answer = complete }
        let question = try XCTUnwrap(GitDiscard.ask(held, discarding: entries, in: window) { _ in discarded = true })
        question.cancel()
        answer?(.alertFirstButtonReturn)
        XCTAssertFalse(discarded, "A press that arrives after the question went down discards nothing")
    }

    /// A panel moved to another window takes the question it had up on the
    /// window it left down with it, and is never hidden on the way.
    @MainActor func testAPanelMovedToAnotherWindowTakesItsQuestionDown() async throws {
        let root = try changedRepository(commits: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let controller = GitController(roots: [root.path]), place = GitPanelPlace()
        defer { controller.letGo() }
        let panel = NSHostingView(rootView: GitPanelView(controller: controller, place: place))
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 1180, height: 780))
        panel.frame = holder.bounds; holder.addSubview(panel)
        let window = host(Color.clear), other = host(Color.clear)
        defer { window.close(); other.close() }
        window.contentView?.addSubview(holder)
        try await eventually("shown, and read") { controller.isShown && controller.statusRead && !controller.loading }
        let questions = PiQuestion()
        var discarded = false
        place.askToDiscard(Array(controller.status.entries.prefix(1)), questions: questions) { _ in discarded = true }
        try await eventually("the question, on the panel's window") { window.attachedSheet != nil }

        let changes = controller.shownChanges
        holder.removeFromSuperview(); other.contentView?.addSubview(holder)
        try await eventually("the question, down") { window.attachedSheet == nil && place.question == nil }
        XCTAssertFalse(discarded)
        XCTAssertEqual(controller.shownChanges, changes, "Moved in one turn: never hidden")
        XCTAssertTrue(controller.isShown)
    }

    /// A quick hide, show and hide again forgets no commit read: shown in the
    /// end, the commit is read.
    @MainActor func testACommitReadSurvivesQuickHidingAndShowing() async throws {
        let root = try changedRepository(commits: 3)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let controller = GitController(roots: [root.path])
        defer { controller.letGo() }
        controller.setShown(true)
        try await eventually("the first read") { controller.statusRead && !controller.loading }
        controller.panel = .history
        try await eventually("the history") { controller.commits.count == 3 }
        let seed = try XCTUnwrap(controller.commits.last)
        controller.selectedCommit = seed
        controller.setShown(false)
        controller.setShown(true)
        controller.setShown(false)
        XCTAssertNil(controller.detail, "Not read yet")
        controller.setShown(true)
        try await eventually("the commit, read in the end") { controller.detail?.commit == seed && !controller.detailDiff.isEmpty && !controller.commitLoading }
    }

    /// A whole patch the reader asked for, stopped by hiding the panel, is
    /// read whole once it shows: not held back again behind "Show the whole diff".
    @MainActor func testAWholePatchStoppedByHidingIsReadWholeWhenShown() async throws {
        let root = try repository("panel-shown-large")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try start(root)
        for index in 0..<31 { try "file \(index)\n".write(to: root.appendingPathComponent("f\(index).txt"), atomically: true, encoding: .utf8) }
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Thirty-one files"], in: root)
        let controller = GitController(roots: [root.path])
        defer { controller.letGo() }
        controller.setShown(true)
        try await eventually("the first read") { controller.statusRead && !controller.loading }
        controller.panel = .history
        try await eventually("the history") { controller.commits.count == 1 }
        controller.selectedCommit = controller.commits.first
        try await eventually("the commit, its patch held back") { controller.detail != nil && controller.detailDiffDeferred && !controller.commitLoading }
        controller.loadDeferredCommitDiff()
        controller.setShown(false)
        XCTAssertTrue(controller.detailDiff.isEmpty, "Stopped before it was read")
        controller.setShown(true)
        try await eventually("the whole patch") { controller.detailDiff.count == 31 && !controller.commitLoading }
        XCTAssertFalse(controller.detailDiffDeferred, "Read whole, as asked, not held back again")
    }

    /// The read that showing starts, replaced by one the watch starts,
    /// still finishes the commit read that hiding stopped.
    @MainActor func testACommitReadIsFinishedByWhicheverReadReplacesTheOneShowingStarted() async throws {
        let root = try changedRepository(commits: 3)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let controller = GitController(roots: [root.path])
        defer { controller.letGo() }
        controller.setShown(true)
        try await eventually("the first read") { controller.statusRead && !controller.loading }
        controller.panel = .history
        try await eventually("the history") { controller.commits.count == 3 }
        let seed = try XCTUnwrap(controller.commits.last)
        controller.selectedCommit = seed
        controller.setShown(false)
        controller.setShown(true)
        controller.startRefresh()   // as a change the watch saw would replace it
        try await eventually("the commit, read in the end") { controller.detail?.commit == seed && !controller.detailDiff.isEmpty && !controller.commitLoading }
    }

    /// A whole patch stopped by hiding is for the commit it was asked for:
    /// another commit chosen before it resumes is held back as ever.
    @MainActor func testAStoppedWholePatchDoesNotFollowTheReaderToAnotherCommit() async throws {
        let root = try repository("panel-shown-two-large")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try start(root)
        for pass in 0..<2 {
            for index in 0..<31 { try "file \(index) pass \(pass)\n".write(to: root.appendingPathComponent("f\(index).txt"), atomically: true, encoding: .utf8) }
            try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Pass \(pass)"], in: root)
        }
        let controller = GitController(roots: [root.path])
        defer { controller.letGo() }
        controller.setShown(true)
        try await eventually("the first read") { controller.statusRead && !controller.loading }
        controller.panel = .history
        try await eventually("the history") { controller.commits.count == 2 }
        let newer = controller.commits[0], older = controller.commits[1]
        controller.selectedCommit = newer
        try await eventually("its patch held back") { controller.detail?.commit == newer && controller.detailDiffDeferred && !controller.commitLoading }
        controller.loadDeferredCommitDiff()
        controller.setShown(false)
        let finished = controller.refreshesFinished
        controller.setShown(true)
        controller.selectedCommit = older
        // A read that finishes current: where a stopped read resumes.
        try await eventually("a read, finished") { controller.refreshesFinished > finished }
        try await eventually("the other commit") { controller.detail?.commit == older && !controller.commitLoading }
        XCTAssertTrue(controller.detailDiffDeferred, "Its patch held back, as for any large commit")
        XCTAssertTrue(controller.detailDiff.isEmpty, "Not read whole on the strength of the first commit's request")
    }

    /// A page of history read for a panel that hid meanwhile is not added
    /// behind the history it reads when shown again.
    @MainActor func testAPageOfHistoryForAHiddenPanelIsDropped() async throws {
        let root = try changedRepository(commits: 120)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let controller = GitController(roots: [root.path])
        defer { controller.letGo() }
        controller.setShown(true)
        try await eventually("the first read") { controller.statusRead && !controller.loading }
        controller.panel = .history
        try await eventually("the first page") { controller.commits.count == 50 }
        let paging = Task { await controller.loadMoreHistory() }
        await Task.yield()
        // Hidden and shown again before the page is read.
        controller.setShown(false)
        controller.setShown(true)
        await paging.value
        try await eventually("shown again") { controller.isWatching }
        await controller.refresh(automatic: true)
        XCTAssertEqual(controller.commits.count, 50, "The page for the panel as it was is not added behind the history read since")
        XCTAssertEqual(Set(controller.commits.map(\.hash)).count, 50, "No commit twice, no gap")
    }
}
