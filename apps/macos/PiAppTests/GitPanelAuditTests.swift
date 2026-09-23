import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// The Changes panel driven the way a reader drives it, against real throwaway
/// repositories: thousands of changed files, every kind of change, a repository
/// that moves under the panel, and the reads the panel leaves behind.
final class GitPanelAuditTests: XCTestCase {

    // MARK: Fixtures
    //
    // Shared by every Git* file split out of this one, so they are internal
    // rather than private: the tests that use them are extensions elsewhere.

    func repository(_ name: String = "git-audit") throws -> URL {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent(name + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @discardableResult
    func git(_ arguments: [String], in root: URL, expectSuccess: Bool = true) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgsign=false", "-c", "protocol.file.allow=always"] + arguments
        process.currentDirectoryURL = root
        let out = Pipe(); process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if expectSuccess { XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.prefix(3).joined(separator: " "))") }
        return String(decoding: data, as: UTF8.self)
    }
    func start(_ root: URL) throws {
        try git(["init", "-q", "-b", "main"], in: root)
        try git(["config", "user.name", "Fixture"], in: root)
        try git(["config", "user.email", "fixture@example.com"], in: root)
        try git(["config", "commit.gpgsign", "false"], in: root)
    }
    @MainActor func eventually(_ what: String, timeout: TimeInterval = 40, _ condition: () -> Bool,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Never \(what)", file: file, line: line)
    }
    /// Every git this process has spawned that is still alive, and whether it
    /// has been reaped. Reads that are superseded must leave neither.
    struct Child { let pid: Int32; let state: String }
    func gitChildren() -> [Child] {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "pid=,ppid=,state=,comm=", "-ax"]
        let out = Pipe(); process.standardOutput = out; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let own = String(getpid())
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 4, fields[1] == own, (fields[3] as NSString).lastPathComponent == "git" else { return nil }
            return Int32(fields[0]).map { Child(pid: $0, state: fields[2]) }
        }
    }
    @MainActor func host(_ view: some View, width: CGFloat = 1180, height: CGFloat = 780) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        return window
    }
    func milliseconds(_ work: () -> Void) -> Double {
        let start = ProcessInfo.processInfo.systemUptime
        work()
        return (ProcessInfo.processInfo.systemUptime - start) * 1000
    }

    // MARK: Argument limits

    func testPathBatchesStayInsideTheLimitsProcessImposes() {
        let many = (0..<9_000).map { "src/module-\($0)/component-with-a-fairly-long-name-\($0).swift" }
        let batches = GitService.batches(of: many, prefix: ["add", "-A", "--"])
        XCTAssertEqual(batches.reduce(0) { $0 + $1.count }, 9_000, "every path is handed to git exactly once")
        XCTAssertEqual(batches.flatMap { $0 }, many, "and in the order it was given")
        for batch in batches {
            XCTAssertLessThanOrEqual(batch.count + 3, 4_000, "Foundation raises an uncaught exception past 4096 arguments")
            XCTAssertLessThanOrEqual(batch.reduce(0) { $0 + $1.utf8.count + 1 }, 128 * 1024, "and the spawn fails past ARG_MAX bytes")
        }
        XCTAssertTrue(GitService.batches(of: [], prefix: ["add"]).isEmpty)
        XCTAssertEqual(GitService.batches(of: ["a"], prefix: ["add"]), [["a"]])
    }

    /// Staging, committing and discarding thousands of files at once. Before
    /// this was batched, "Stage all" on such a repository raised an uncaught
    /// Objective-C exception inside Foundation and took the app down.
    @MainActor func testThousandsOfChangedFilesStageCommitAndDiscardWithoutCrashing() async throws {
        let root = try repository("git-many"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try "seed\n".write(to: root.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        let count = 5_000
        for index in 0..<count {
            try "content \(index)\n".write(to: root.appendingPathComponent("generated-file-with-a-realistic-name-\(index).txt"), atomically: true, encoding: .utf8)
        }
        let controller = GitController(roots: [root.path])
        try await eventually("list every changed file") { controller.status.entries.count == count }
        XCTAssertEqual(controller.unstaged.count, count)
        XCTAssertEqual(controller.checkedCount, count, "everything arrives ticked")

        await controller.stage(controller.unstaged.map(\.path))
        XCTAssertEqual(controller.staged.count, count, "every file is staged, in as many git calls as it takes")
        XCTAssertEqual(controller.notice, "")

        controller.commitMessage = "Everything at once"
        await controller.commitChecked()
        XCTAssertEqual(controller.notice, "")
        XCTAssertNotNil(controller.lastCommit, "a commit of five thousand paths goes through a pathspec file")
        XCTAssertTrue(controller.status.entries.isEmpty, "and leaves a clean tree")

        for index in 0..<count {
            try "changed \(index)\n".write(to: root.appendingPathComponent("generated-file-with-a-realistic-name-\(index).txt"), atomically: true, encoding: .utf8)
        }
        await controller.refresh()
        XCTAssertEqual(controller.status.entries.count, count)
        await controller.discard(controller.status.entries)
        XCTAssertEqual(controller.notice, "")
        XCTAssertTrue(controller.status.entries.isEmpty, "discarding thousands of files also goes in batches")
    }

    // MARK: The changelist

    /// Unticking every file used to be undone by the next refresh, which
    /// re-armed a Commit button the reader had deliberately disarmed.
    @MainActor func testUntickingEveryFileSurvivesARefresh() async throws {
        let root = try repository("git-ticks"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try "seed\n".write(to: root.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        for name in ["a.txt", "b.txt", "c.txt"] { try "x\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let controller = GitController(roots: [root.path])
        try await eventually("read the changes") { controller.status.entries.count == 3 }
        XCTAssertEqual(controller.checkedCount, 3)

        controller.checked.removeAll()
        XCTAssertEqual(controller.checkedCount, 0)
        await controller.refresh()
        XCTAssertTrue(controller.checked.isEmpty, "a refresh must not tick the files back on")
        XCTAssertEqual(controller.checkedCount, 0)

        controller.checked.insert("b.txt")
        try "y\n".write(to: root.appendingPathComponent("d.txt"), atomically: true, encoding: .utf8)
        await controller.refresh()
        XCTAssertEqual(controller.checked, ["b.txt"], "and a new file joins unticked once the reader has chosen")
        XCTAssertEqual(controller.checkedCount, 1)
    }

    /// Every kind of change the changes list has to show, in one repository.
    @MainActor func testTheChangesListShowsEveryKindOfChange() async throws {
        let root = try repository("git-kinds"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try "one\ntwo\nthree\n".write(to: root.appendingPathComponent("modified.txt"), atomically: true, encoding: .utf8)
        try "gone\n".write(to: root.appendingPathComponent("deleted.txt"), atomically: true, encoding: .utf8)
        try "old\n".write(to: root.appendingPathComponent("before.txt"), atomically: true, encoding: .utf8)
        try Data([0x00, 0x01, 0x02, 0xff, 0xfe]).write(to: root.appendingPathComponent("picture.bin"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "modified.txt")
        try git(["add", "-A"], in: root); try git(["commit", "-q", "-m", "Seed every kind"], in: root)

        // A nested repository becomes a gitlink, which is what a submodule is on disk.
        let inner = root.appendingPathComponent("vendored")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try start(inner)
        try "lib\n".write(to: inner.appendingPathComponent("lib.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: inner); try git(["commit", "-q", "-m", "Vendored"], in: inner)
        try git(["add", "vendored"], in: root)

        try "one\ntwo\nthree\nfour\n".write(to: root.appendingPathComponent("modified.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("deleted.txt"))
        try git(["mv", "before.txt", "after.txt"], in: root)
        try Data([0x00, 0x09, 0x07, 0x01]).write(to: root.appendingPathComponent("picture.bin"))
        try "brand new\n".write(to: root.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        try git(["add", "picture.bin"], in: root)

        let controller = GitController(roots: [root.path])
        try await eventually("read every kind of change") { controller.status.entries.count >= 6 }
        var badges: [String: String] = [:], seen: [String: [GitDiffFile]] = [:]
        for entry in controller.status.entries { badges[entry.path] = entry.badge }
        XCTAssertEqual(badges["modified.txt"], "M")
        XCTAssertEqual(badges["deleted.txt"], "D")
        XCTAssertEqual(badges["after.txt"], "R")
        XCTAssertEqual(badges["untracked.txt"], "U")
        XCTAssertEqual(badges["picture.bin"], "M", "a staged binary shows its index change")
        XCTAssertEqual(badges["vendored"], "A", "a gitlink is one row, not the files inside it")
        let renamed = try XCTUnwrap(controller.status.entries.first { $0.path == "after.txt" })
        XCTAssertEqual(renamed.originalPath, "before.txt")
        XCTAssertTrue(renamed.renamed)
        XCTAssertEqual(controller.status.entries.first { $0.path == "deleted.txt" }?.summary, "Deleted")

        // Every row's diff opens without an error, including the binary and the gitlink.
        for entry in controller.status.entries {
            controller.selection = GitController.Selection(path: entry.path, staged: entry.staged && !entry.unstaged)
            try await eventually("read the diff of \(entry.path)") { !controller.diffLoading }
            XCTAssertEqual(controller.notice, "", "reading \(entry.path)")
            seen[entry.path] = controller.diff
        }
        XCTAssertEqual(seen["picture.bin"]?.first?.binary, true, "a binary file says so instead of showing bytes")
        XCTAssertEqual(seen["picture.bin"]?.first?.notes, ["Binary file changed."])
        XCTAssertEqual(seen["untracked.txt"]?.first?.added, 1, "an untracked file shows its whole content as added")
        XCTAssertEqual(seen["deleted.txt"]?.first?.removed, 1)
        XCTAssertEqual(seen["after.txt"]?.first?.renamed, true, "a renamed file is a rename, not a whole new file")
        XCTAssertEqual(seen["after.txt"]?.first?.oldPath, "before.txt")
        XCTAssertEqual(seen["after.txt"]?.first?.added, 0, "and none of its lines are shown as added")
        XCTAssertEqual(seen["modified.txt"]?.first?.added, 1)
    }

    // MARK: Renames

    static let renamedContent = "one\ntwo\nthree\nfour\nfive\n"
    /// A repository whose one commit holds `before.txt`.
    func renameFixture(_ name: String) throws -> URL {
        let root = try repository(name)
        try start(root)
        try Self.renamedContent.write(to: root.appendingPathComponent("before.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        return root
    }
    /// What git itself says about the index and the working tree, a line per path.
    func porcelain(_ root: URL) throws -> [String] {
        try git(["status", "--porcelain"], in: root).split(separator: "\n").map(String.init)
    }

    /// The rename's row arrives ticked, so Commit is one click away. It used
    /// to commit the new name alone — a copy — and leave the old name's
    /// removal staged for a second commit nobody asked for.
    @MainActor func testCommittingARenameRecordsOneRenameAndLeavesNothingBehind() async throws {
        let root = try renameFixture("git-rename-commit"); defer { try? FileManager.default.removeItem(at: root) }
        try git(["mv", "before.txt", "after.txt"], in: root)
        let controller = GitController(roots: [root.path]); defer { controller.stop() }
        try await eventually("read the rename") { controller.status.entries.count == 1 && !controller.loading }
        await controller.refresh()
        let rename = try XCTUnwrap(controller.status.entries.first)
        XCTAssertEqual(rename.path, "after.txt"); XCTAssertEqual(rename.originalPath, "before.txt")
        XCTAssertEqual(controller.checked, ["after.txt"], "the rename is one row, ticked like any other")

        controller.commitMessage = "Rename before.txt to after.txt"
        await controller.commitChecked()
        XCTAssertEqual(controller.notice, "")
        XCTAssertNotNil(controller.lastCommit)
        let recorded = try git(["show", "--name-status", "--format=", "HEAD"], in: root)
            .split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
        XCTAssertEqual(recorded.count, 1, "one change: \(recorded)")
        XCTAssertEqual(recorded.first?.first?.first, "R", "recorded as a rename, not as a new file: \(recorded)")
        XCTAssertEqual(Array(recorded.first?.dropFirst() ?? []), ["before.txt", "after.txt"])
        XCTAssertEqual(try porcelain(root), [], "nothing is left staged or changed")
        XCTAssertTrue(controller.status.entries.isEmpty)
    }

    /// "Discard Changes…" says tracked files go back to HEAD. On a rename it
    /// removed the new name from disk and left the old one deleted: the file
    /// was simply gone.
    @MainActor func testDiscardingARenamePutsTheFileBackUnderItsOldName() async throws {
        let root = try renameFixture("git-rename-discard"); defer { try? FileManager.default.removeItem(at: root) }
        let before = root.appendingPathComponent("before.txt"), after = root.appendingPathComponent("after.txt")
        let controller = GitController(roots: [root.path]); defer { controller.stop() }
        try await eventually("settle on a clean tree") { controller.repositoryRoot != nil && !controller.loading }
        // A plain rename, and one whose file was edited again after the move.
        for edit in [nil, "six\n"] as [String?] {
            try git(["mv", "before.txt", "after.txt"], in: root)
            if let edit { try (Self.renamedContent + edit).write(to: after, atomically: true, encoding: .utf8) }
            await controller.refresh()
            let rename = try XCTUnwrap(controller.status.entries.first { $0.path == "after.txt" })
            XCTAssertEqual(rename.originalPath, "before.txt")
            await controller.discard([rename])
            XCTAssertEqual(controller.notice, "")
            XCTAssertEqual(try? String(contentsOf: before, encoding: .utf8), Self.renamedContent, "the file is back under its old name, as HEAD has it")
            XCTAssertFalse(FileManager.default.fileExists(atPath: after.path), "and the new name is gone")
            XCTAssertEqual(try porcelain(root), [], "the tree matches HEAD again")
            XCTAssertTrue(controller.status.entries.isEmpty)
        }
    }

    /// Unstaging a rename used to unstage its new name alone, leaving the old
    /// name's removal staged beside an untracked file; staging a rename git
    /// saw only in the working tree staged the new file and left the removal
    /// behind. Either way one rename came apart into two unrelated changes.
    @MainActor func testStagingAndUnstagingARenameMovesBothOfItsNames() async throws {
        let root = try renameFixture("git-rename-stage"); defer { try? FileManager.default.removeItem(at: root) }
        try git(["mv", "before.txt", "after.txt"], in: root)
        try (Self.renamedContent + "six\n").write(to: root.appendingPathComponent("after.txt"), atomically: true, encoding: .utf8)
        let controller = GitController(roots: [root.path]); defer { controller.stop() }
        try await eventually("read the rename") { controller.status.entries.count == 1 && !controller.loading }
        await controller.refresh()
        XCTAssertEqual(try porcelain(root), ["RM before.txt -> after.txt"])
        XCTAssertEqual(controller.staged.map(\.path), ["after.txt"]); XCTAssertEqual(controller.unstaged.map(\.path), ["after.txt"])

        // The row's + on its unstaged side stages the edit, and it stays one rename.
        await controller.stage(["after.txt"])
        XCTAssertEqual(controller.notice, "")
        XCTAssertEqual(try porcelain(root), ["R  before.txt -> after.txt"])

        // The row's − unstages the whole rename, not half of it.
        await controller.unstage(["after.txt"])
        XCTAssertEqual(controller.notice, "")
        XCTAssertEqual(try git(["diff", "--cached", "--name-status"], in: root), "", "nothing of the rename is left staged")
        XCTAssertTrue(controller.staged.isEmpty)
        XCTAssertEqual(try porcelain(root), [" D before.txt", "?? after.txt"], "git shows an unstaged move as the old name deleted and the new one untracked")

        // Stage all puts it back together as one rename.
        await controller.stage(controller.unstaged.map(\.path))
        XCTAssertEqual(controller.notice, "")
        XCTAssertEqual(try porcelain(root), ["R  before.txt -> after.txt"])
        XCTAssertEqual(controller.status.entries.count, 1)

        // A rename git sees only in the working tree (the new file added with
        // --intent-to-add) is one row too, and staging that row stages both names.
        try git(["reset", "-q"], in: root)
        try git(["add", "--intent-to-add", "after.txt"], in: root)
        await controller.refresh()
        XCTAssertEqual(try porcelain(root), [" R before.txt -> after.txt"])
        XCTAssertEqual(controller.status.entries.first?.originalPath, "before.txt")
        XCTAssertEqual(controller.unstaged.map(\.path), ["after.txt"])
        await controller.stage(["after.txt"])
        XCTAssertEqual(controller.notice, "")
        XCTAssertEqual(try porcelain(root), ["R  before.txt -> after.txt"], "one rename, staged whole")
    }

    /// A new file saved where a renamed one used to be is a row of its own,
    /// and only that row commits or discards it: taking a rename's old name
    /// along must never commit that file unticked, or overwrite it.
    @MainActor func testARenamesOldNameHoldingANewFileIsLeftToThatFilesRow() async throws {
        let saved = "a new file where the old one was\n"
        func heldRename(_ name: String) async throws -> (URL, GitController, GitStatusEntry) {
            let root = try renameFixture(name)
            try git(["mv", "before.txt", "after.txt"], in: root)
            try saved.write(to: root.appendingPathComponent("before.txt"), atomically: true, encoding: .utf8)
            let controller = GitController(roots: [root.path])
            try await eventually("read both rows") { controller.status.entries.count == 2 && !controller.loading }
            await controller.refresh()
            XCTAssertEqual(controller.status.entries.first { $0.path == "before.txt" }?.untracked, true)
            return (root, controller, try XCTUnwrap(controller.status.entries.first { $0.path == "after.txt" && $0.originalPath == "before.txt" }))
        }

        // Discarding the rename alone undoes it, and the new file stays as it is.
        let (discarded, discarding, rename) = try await heldRename("git-rename-held-discard")
        defer { discarding.stop(); try? FileManager.default.removeItem(at: discarded) }
        await discarding.discard([rename])
        XCTAssertEqual(discarding.notice, "")
        XCTAssertEqual(try? String(contentsOf: discarded.appendingPathComponent("before.txt"), encoding: .utf8), saved, "the file saved at the old name is not overwritten")
        XCTAssertFalse(FileManager.default.fileExists(atPath: discarded.appendingPathComponent("after.txt").path))
        XCTAssertEqual(try porcelain(discarded), [" M before.txt"], "the rename is undone; what was saved there is an ordinary change to before.txt")

        // Committing the rename with that file unticked commits nothing of it.
        let (committed, committing, _) = try await heldRename("git-rename-held-commit")
        defer { committing.stop(); try? FileManager.default.removeItem(at: committed) }
        committing.checked = ["after.txt"]
        committing.commitMessage = "Move the old file aside"
        await committing.commitChecked()
        XCTAssertEqual(committing.notice, "")
        XCTAssertEqual(try git(["show", "HEAD:before.txt"], in: committed), Self.renamedContent, "the unticked file is not in the commit")
        XCTAssertEqual(try git(["show", "HEAD:after.txt"], in: committed), Self.renamedContent)
        XCTAssertEqual(try? String(contentsOf: committed.appendingPathComponent("before.txt"), encoding: .utf8), saved)
    }

    /// A copy is not a rename: its source is still there, changed, in a row
    /// of its own, and committing or discarding the copy leaves that row alone.
    @MainActor func testACopyIsCommittedAndDiscardedWithoutItsSource() async throws {
        let root = try repository("git-copy"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        let original = "a\nb\nc\nd\ne\nf\n", source = root.appendingPathComponent("src.txt")
        try original.write(to: source, atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        try git(["config", "status.renames", "copies"], in: root)
        try (original + "g\n").write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: source, to: root.appendingPathComponent("copy.txt"))
        try git(["add", "-A"], in: root)
        let controller = GitController(roots: [root.path]); defer { controller.stop() }
        try await eventually("read the copy and its source") { controller.status.entries.count == 2 && !controller.loading }
        await controller.refresh()
        XCTAssertEqual(controller.status.entries.first { $0.path == "copy.txt" }?.originalPath, "src.txt", "git reports a copy")
        XCTAssertEqual(controller.status.entries.first { $0.path == "src.txt" }?.indexState, "M", "and its source changed, in a row of its own")

        controller.checked = ["copy.txt"]
        controller.commitMessage = "Only the copy"
        await controller.commitChecked()
        XCTAssertEqual(controller.notice, "")
        XCTAssertEqual(try git(["show", "HEAD:src.txt"], in: root), original, "the unticked source is not committed with its copy")
        XCTAssertEqual(try porcelain(root), ["M  src.txt"])

        try FileManager.default.copyItem(at: source, to: root.appendingPathComponent("again.txt"))
        try git(["add", "again.txt"], in: root)
        await controller.refresh()
        let copy = try XCTUnwrap(controller.status.entries.first { $0.path == "again.txt" })
        XCTAssertEqual(copy.originalPath, "src.txt")
        await controller.discard([copy])
        XCTAssertEqual(controller.notice, "")
        XCTAssertEqual(try? String(contentsOf: source, encoding: .utf8), original + "g\n", "discarding the copy leaves its source's change alone")
        XCTAssertEqual(try porcelain(root), ["M  src.txt"])
    }

    /// A new file staged and then deleted from disk shows as deleted, and so
    /// does a rename whose new name was deleted after the move. Every row
    /// arrives ticked, and either one used to fail the whole commit ("pathspec
    /// did not match any file(s) known to git"), taking every other ticked
    /// change down with it. Each commits as its row shows: the new file never
    /// reaches a commit and nothing stays staged for it, and the rename leaves
    /// the old name's removal.
    @MainActor func testRowsDeletedSinceTheyWereStagedCommitAsTheyShowWithTheRest() async throws {
        let root = try renameFixture("git-staged-then-gone"); defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("other.txt"), fresh = root.appendingPathComponent("new.txt")
        try "keep\n".write(to: other, atomically: true, encoding: .utf8)
        try git(["add", "other.txt"], in: root); try git(["commit", "-q", "-m", "Other"], in: root)
        try "fresh\n".write(to: fresh, atomically: true, encoding: .utf8)
        try git(["add", "new.txt"], in: root)
        try FileManager.default.removeItem(at: fresh)
        try git(["mv", "before.txt", "after.txt"], in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("after.txt"))
        try "changed\n".write(to: other, atomically: true, encoding: .utf8)
        let controller = GitController(roots: [root.path]); defer { controller.stop() }
        try await eventually("read the three rows") { controller.status.entries.count == 3 && !controller.loading }
        await controller.refresh()
        XCTAssertEqual(try porcelain(root), ["RD before.txt -> after.txt", "AD new.txt", " M other.txt"])
        XCTAssertEqual(controller.status.entries.map(\.badge), ["D", "D", "M"], "both files that are gone show as deleted")
        XCTAssertEqual(controller.checked, ["after.txt", "new.txt", "other.txt"], "and every row arrives ticked")

        controller.commitMessage = "Commit around two files that are gone"
        await controller.commitChecked()
        XCTAssertNotNil(controller.lastCommit, "the commit goes through")
        XCTAssertEqual(try git(["show", "--name-status", "--format=", "HEAD"], in: root).split(separator: "\n").map(String.init),
                       ["D\tbefore.txt", "M\tother.txt"], "the old name's removal and the edit, and nothing of a file no commit ever held")
        XCTAssertEqual(try porcelain(root), [], "nothing is left staged for either file")
        XCTAssertTrue(controller.status.entries.isEmpty)
        XCTAssertEqual(controller.commitMessage, "")

        // Ticked alone, such a file is nothing to commit: no commit is made,
        // nothing changes, and git's refusal is put in words.
        try "again\n".write(to: fresh, atomically: true, encoding: .utf8)
        try git(["add", "new.txt"], in: root)
        try FileManager.default.removeItem(at: fresh)
        await controller.refresh()
        XCTAssertEqual(controller.checked, ["new.txt"])
        let head = try git(["rev-parse", "HEAD"], in: root)
        controller.commitMessage = "Nothing really"
        await controller.commitChecked()
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: root), head, "no commit is made")
        XCTAssertEqual(try porcelain(root), ["AD new.txt"], "and the row is as it was")
        XCTAssertEqual(controller.commitMessage, "Nothing really", "the message waits for another try")
        do {
            _ = try await GitService().commit(message: "Nothing really", in: root.path, paths: ["new.txt"], staging: [])
            XCTFail("a commit that changes nothing is refused")
        } catch { XCTAssertEqual(error.localizedDescription, "Nothing to commit: the chosen files on disk match HEAD.") }
    }

    /// A failed action said why for no time at all: the refresh after every
    /// action begins by clearing the notice, and it ran in the same turn, so a
    /// refused push, stage or commit left the panel as if nothing had been
    /// pressed.
    @MainActor func testAFailedActionKeepsItsMessageOnScreen() async throws {
        let root = try renameFixture("git-failure-notice"); defer { try? FileManager.default.removeItem(at: root) }
        let controller = GitController(roots: [root.path]); defer { controller.stop() }
        try await eventually("settle") { controller.repositoryRoot != nil && !controller.loading }

        await controller.push()
        XCTAssertTrue(controller.notice.hasPrefix("Push: "), "a push with nowhere to go says so: \(controller.notice)")
        XCTAssertFalse(controller.busy)
        await controller.stage(["no-such-file.txt"])
        XCTAssertTrue(controller.notice.contains("no-such-file.txt"), "so does a stage git refuses: \(controller.notice)")
        await controller.refresh()
        XCTAssertEqual(controller.notice, "", "the reader's own refresh clears it")

        let fresh = root.appendingPathComponent("new.txt")
        try "fresh\n".write(to: fresh, atomically: true, encoding: .utf8)
        try git(["add", "new.txt"], in: root)
        try FileManager.default.removeItem(at: fresh)
        await controller.refresh()
        controller.commitMessage = "Nothing really"
        await controller.commitChecked()
        XCTAssertEqual(controller.notice, "Commit: Nothing to commit: the chosen files on disk match HEAD.")
    }

    /// A repository that is not one, one with no commits at all, a detached
    /// HEAD and several roots: none of these may leave the panel stuck or
    /// showing an error for something ordinary.
    @MainActor func testUnusualRepositoriesAreHandledWithoutANotice() async throws {
        let plain = try repository("git-plain"); defer { try? FileManager.default.removeItem(at: plain) }
        try "loose\n".write(to: plain.appendingPathComponent("loose.txt"), atomically: true, encoding: .utf8)
        let notARepository = GitController(roots: [plain.path])
        try await eventually("settle on no repository") { !notARepository.loading }
        XCTAssertNil(notARepository.repositoryRoot)
        XCTAssertEqual(notARepository.notice, "", "a folder outside git is a state, not an error")
        XCTAssertTrue(notARepository.status.entries.isEmpty)

        let empty = try repository("git-empty"); defer { try? FileManager.default.removeItem(at: empty) }
        try start(empty)
        try "first\n".write(to: empty.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
        let noCommits = GitController(roots: [empty.path])
        try await eventually("read a repository with no commits") { noCommits.repositoryRoot != nil && !noCommits.loading }
        XCTAssertEqual(noCommits.notice, "", "an empty repository has no history, which is not a failure")
        XCTAssertTrue(noCommits.commits.isEmpty)
        XCTAssertEqual(noCommits.status.entries.map(\.path), ["first.txt"])
        XCTAssertEqual(noCommits.status.branch, "main")
        XCTAssertNil(noCommits.status.head)

        let detached = try repository("git-detached"); defer { try? FileManager.default.removeItem(at: detached) }
        try start(detached)
        for index in 1...2 {
            try "line \(index)\n".write(to: detached.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            try git(["add", "."], in: detached); try git(["commit", "-q", "-m", "Commit \(index)"], in: detached)
        }
        try git(["checkout", "-q", "HEAD~1"], in: detached)
        let head = GitController(roots: [detached.path])
        try await eventually("read a detached HEAD") { head.commits.count == 1 }
        XCTAssertEqual(head.notice, "")
        XCTAssertEqual(head.status.branch, "(detached)")
        XCTAssertNotNil(head.status.head)

        // Several roots: switching moves the whole panel to the other repository.
        let second = try repository("git-second"); defer { try? FileManager.default.removeItem(at: second) }
        try start(second)
        try "other\n".write(to: second.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: second); try git(["commit", "-q", "-m", "Second repository"], in: second)
        let many = GitController(roots: [detached.path, second.path])
        try await eventually("read the first root") { many.commits.count == 1 }
        many.root = second.path
        try await eventually("move to the second root") { many.commits.first?.subject == "Second repository" }
        XCTAssertEqual(many.repositoryRoot.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, second.resolvingSymlinksInPath().path)
        XCTAssertEqual(many.notice, "")
    }

    /// The reader keeps the panel open while HEAD moves underneath it.
    @MainActor func testHeadMovingUnderThePanelIsPickedUpAndStaleSelectionDropped() async throws {
        let root = try repository("git-head"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try "one\n".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "First"], in: root)
        try "one\ntwo\n".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)

        let controller = GitController(roots: [root.path])
        try await eventually("select the changed file and read the history") { controller.selection?.path == "tracked.txt" && !controller.diff.isEmpty && controller.commits.count == 1 }

        // Somebody commits from a terminal while the panel is open.
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Second, from outside"], in: root)
        try git(["checkout", "-q", "-b", "side"], in: root)
        let start = ProcessInfo.processInfo.systemUptime
        await controller.refresh()
        let cost = (ProcessInfo.processInfo.systemUptime - start) * 1000
        print(String(format: "PERF git panel refresh of a small repository: %.0f ms", cost))
        XCTAssertEqual(controller.commits.first?.subject, "Second, from outside", "the new commit is there")
        XCTAssertEqual(controller.status.branch, "side", "and so is the new branch")
        XCTAssertNil(controller.selection, "the file that is no longer changed stops being selected")
        XCTAssertTrue(controller.diff.isEmpty)
        XCTAssertEqual(controller.notice, "")

        // A file changed on disk shows up on the next refresh.
        try "one\ntwo\nthree\n".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        await controller.refresh()
        XCTAssertEqual(controller.status.entries.map(\.path), ["tracked.txt"])
        try await eventually("read the new diff") { controller.diff.first?.added == 1 }
    }
}

// Bindings the panel's views write into, so a test can read back what a
// click would have changed. Shared by every Git* file split out of this one.
@MainActor final class DiffHolder { var expanded: String? }
@MainActor final class ChipHolder { var selected: String?; var shown = GitCommitFileChips.step }
