import XCTest
import SwiftUI
import AppKit
@testable import PiApp

extension GitPanelAuditTests {
    // MARK: Layout

    /// Nothing about drawing a diff may walk its lines: pairing a side-by-side
    /// hunk used to happen once per pass over the view's body.
    func testSplitRowsAreBuiltOnlyAsFarAsTheyAreDrawn() {
        let lines = (0..<20_000).map { $0 % 3 == 0 ? "-old \($0)" : ($0 % 3 == 1 ? "+new \($0)" : " context \($0)") }
        let patch = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,20000 +1,20000 @@\n" + lines.joined(separator: "\n") + "\n"
        let file = try! XCTUnwrap(GitDiffParser.parse(patch).first)
        let hunk = try! XCTUnwrap(file.hunks.first)
        XCTAssertEqual(file.lineCount, hunk.lines.count, "the parser counted the lines once")
        let limited = hunk.splitRows(limit: 1_500)
        XCTAssertEqual(limited.count, 1_500)
        XCTAssertEqual(Array(limited.prefix(3)).map { $0.left?.text ?? "" }, hunk.splitRows().prefix(3).map { $0.left?.text ?? "" })
        let whole = milliseconds { _ = hunk.splitRows() }
        let capped = milliseconds { _ = hunk.splitRows(limit: 1_500) }
        print(String(format: "PERF split rows: whole hunk %.1f ms, the 1500 rows a card draws %.1f ms", whole, capped))
        XCTAssertLessThan(capped, whole, "a card that draws 1500 rows must not pair 20000")
    }

    /// A commit that touches thousands of files: the chip row is a flow layout,
    /// which measures every chip it is given, twice, on the main thread.
    @MainActor func testACommitTouchingThousandsOfFilesListsThemInSteps() throws {
        let commit = GitCommit(hash: String(repeating: "a", count: 40), shortHash: "aaaaaaa", author: "Fixture", date: Date(), subject: "A very wide commit", parents: [])
        let files = (0..<3_000).map { GitStatusEntry(path: "src/module-\($0)/File\($0).swift", originalPath: nil, indexState: "M", worktreeState: ".", untracked: false) }
        var stats: [String: GitDiffStat] = [:]
        for file in files { stats[file.path] = GitDiffStat(added: 3, removed: 1, binary: false) }
        let detail = GitCommitDetail(commit: commit, message: "A very wide commit", files: files, stats: stats)
        XCTAssertTrue(detail.isLarge, "its patch waits to be asked for")

        func cost(shown: Int) -> Double {
            let holder = ChipHolder(); holder.shown = shown
            let view = GitCommitFileChips(detail: detail, selected: Binding(get: { holder.selected }, set: { holder.selected = $0 }),
                                          shown: Binding(get: { holder.shown }, set: { holder.shown = $0 }), showHistory: { _ in })
            var window: NSWindow!
            let elapsed = milliseconds {
                window = host(view, width: 760, height: 620)
                window.contentView?.layoutSubtreeIfNeeded()
                window.contentView?.displayIfNeeded()
            }
            window.contentView = nil; window.close()
            return elapsed
        }
        let capped = cost(shown: GitCommitFileChips.step)
        // Four times as many chips, to show what the cap is holding back.
        // (All three thousand at once takes about fifty seconds.)
        let quadruple = cost(shown: 4 * GitCommitFileChips.step)
        print(String(format: "PERF commit chips: first %d of 3000 in %.0f ms, %d of them in %.0f ms", GitCommitFileChips.step, capped, 4 * GitCommitFileChips.step, quadruple))
        // An absolute budget is a Release figure: in Debug, on a machine
        // running other builds, it measures the machine. The shape check
        // below holds in every configuration.
        XCTAssertLessThan(capped, releaseBudget(1.0) * 1_000, "opening a commit that touches thousands of files must not stall the pane")
        XCTAssertLessThan(capped * 3, quadruple, "and it is the cap that makes the difference")

        // The reader can still ask for more, a step at a time.
        let holder = ChipHolder()
        XCTAssertEqual(holder.shown, GitCommitFileChips.step)
        holder.shown += GitCommitFileChips.step
        XCTAssertEqual(holder.shown, 2 * GitCommitFileChips.step)
    }

    /// The whole-diff gate belongs to the diff on screen, not to the pane.
    @MainActor func testTheWholeDiffGateDoesNotFollowTheReaderToTheNextFile() async throws {
        let controller = GitController(roots: [])
        let first = GitController.diffIdentity(path: "src/one.swift", staged: false)
        let second = GitController.diffIdentity(path: "src/two.swift", staged: false)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, GitController.diffIdentity(path: "src/one.swift", staged: true), "staged and unstaged are different diffs")
        controller.wholeDiffShown = first
        XCTAssertEqual(controller.wholeDiffShown, first)
        XCTAssertNotEqual(controller.wholeDiffShown, second, "the next file is gated again")
        let commitA = GitController.diffIdentity(commit: "aaaa", file: nil)
        XCTAssertNotEqual(commitA, GitController.diffIdentity(commit: "bbbb", file: nil))
        XCTAssertNotEqual(commitA, GitController.diffIdentity(commit: "aaaa", file: "x.swift"))
    }

    /// The changes list of a big repository, hosted in a window: the splits the
    /// body reads must be ready, not filtered again for every pass.
    @MainActor func testABigChangesListIsSplitOnceAndLaysOutInABlink() async throws {
        let root = try repository("git-wide"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try "seed\n".write(to: root.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        for index in 0..<3_000 {
            try "content \(index)\n".write(to: root.appendingPathComponent("file-\(index).txt"), atomically: true, encoding: .utf8)
        }
        let controller = GitController(roots: [root.path])
        try await eventually("read three thousand changes") { controller.status.entries.count == 3_000 }

        let reads = milliseconds {
            for _ in 0..<200 { _ = controller.staged.count; _ = controller.unstaged.count; _ = controller.checkedCount; _ = controller.unstagedPaths.count }
        }
        print(String(format: "PERF 200 passes over a 3000-file changes list read its splits in %.1f ms", reads))
        XCTAssertLessThan(reads, 60, "the list is split when the status is read, not on every pass over the body")

        let model = WorkspaceModel(stateRoot: root.appendingPathComponent(".state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let window = host(GitPanelView(model: model, roots: [root.path]))
        defer { window.contentView = nil; window.close() }
        let layout = milliseconds {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
        print(String(format: "PERF git panel with 3000 changed files first layout: %.0f ms", layout))
        XCTAssertNotNil(window.contentView)
    }

    /// A 20,000-line patch, unified and side by side, wide and narrow.
    @MainActor func testALongPatchDrawsAtEveryWidthInBothLayouts() throws {
        let lines = (0..<20_000).map { index -> String in
            switch index % 4 {
            case 0: return "-removed \(index) " + String(repeating: "x", count: 400)
            case 1: return "+added \(index)\twith\ttabs"
            case 2: return " context \(index) 中文 🌍"
            default: return " plain \(index)"
            }
        }
        let patch = "diff --git a/long.txt b/long.txt\n--- a/long.txt\n+++ b/long.txt\n@@ -1,20000 +1,20000 @@\n" + lines.joined(separator: "\n") + "\n"
        let files = GitDiffParser.parse(patch)
        XCTAssertEqual(files.count, 1)
        for (label, width) in [("wide", CGFloat(1_180)), ("narrow", CGFloat(420))] {
            for split in [false, true] {
                let holder = DiffHolder()
                let view = DiffView(files: files, title: "long.txt", subtitle: "Working tree versus index", identity: "audit",
                                    split: Binding(get: { split }, set: { _ in }), expanded: Binding(get: { holder.expanded }, set: { holder.expanded = $0 }))
                var window: NSWindow!
                let building = milliseconds { window = host(view, width: width, height: 700) }
                let cost = milliseconds {
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.contentView?.displayIfNeeded()
                }
                // And with the gate opened: every row of the patch on screen.
                holder.expanded = "audit"
                let whole = milliseconds {
                    window.contentView?.needsLayout = true
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.contentView?.displayIfNeeded()
                }
                let closing = milliseconds { window.contentView = nil; window.close() }
                print(String(format: "PERF 20000-line patch, %@ %@: build %.0f ms, layout %.0f ms, whole diff %.0f ms, close %.0f ms",
                             label, split ? "split" : "unified", building, cost, whole, closing))
                XCTAssertLessThan(building + cost, 4_000, "opening a long patch must not stall the panel")
                XCTAssertLessThan(whole, 4_000, "and neither must asking for the whole of it")
            }
        }
    }
}
