import XCTest
@testable import PiApp

/// Exercises the system git against a throwaway repository: status, diffs,
/// history, commit details, staging and committing.
final class GitToolTests: XCTestCase {
    private func repository() throws -> URL {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("git-tool-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func git(_ arguments: [String], in root: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = root; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    func testStatusDiffHistoryAndCommitAgainstARealRepository() async throws {
        let root = try repository(); defer { try? FileManager.default.removeItem(at: root) }
        try git(["init", "-q", "-b", "main"], in: root)
        // The service commits with the repository's own identity, never a fixture flag.
        try git(["config", "user.name", "Fixture"], in: root); try git(["config", "user.email", "fixture@example.com"], in: root)
        try git(["config", "commit.gpgsign", "false"], in: root)
        try "one\ntwo\nthree\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Initial notes"], in: root)
        let service = GitService()
        let top = await service.repositoryRoot(of: root.path)
        XCTAssertEqual(top.map { URL(fileURLWithPath: $0).standardizedFileURL.path }, root.standardizedFileURL.resolvingSymlinksInPath().path)
        let notRepository = await service.repositoryRoot(of: NSTemporaryDirectory())
        XCTAssertNil(notRepository)

        try "one\n2\nthree\nfour\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "fresh\n".write(to: root.appendingPathComponent("new file.md"), atomically: true, encoding: .utf8)
        var status = try await service.status(in: root.path)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.entries.map(\.path), ["new file.md", "notes.txt"])
        XCTAssertEqual(status.entries.first?.untracked, true); XCTAssertEqual(status.entries.first?.badge, "U")
        XCTAssertEqual(status.entries.last?.badge, "M"); XCTAssertEqual(status.entries.last?.unstaged, true); XCTAssertEqual(status.entries.last?.staged, false)

        let diff = try await service.diffFiles(in: root.path, paths: ["notes.txt"], staged: false)
        XCTAssertEqual(diff.count, 1); XCTAssertEqual(diff.first?.path, "notes.txt")
        XCTAssertEqual(diff.first?.added, 2); XCTAssertEqual(diff.first?.removed, 1)
        let lines = diff.first?.hunks.first?.lines ?? []
        XCTAssertEqual(lines.first { $0.kind == .removed }?.text, "two"); XCTAssertEqual(lines.first { $0.kind == .removed }?.oldNumber, 2)
        XCTAssertEqual(lines.filter { $0.kind == .added }.map(\.text), ["2", "four"]); XCTAssertEqual(lines.last { $0.kind == .added }?.newNumber, 4)
        let untracked = try await service.diffFiles(in: root.path, paths: ["new file.md"], staged: false, untracked: true)
        XCTAssertEqual(untracked.first?.path, "new file.md"); XCTAssertEqual(untracked.first?.added, 1)
        XCTAssertTrue(untracked.first?.notes.contains("New file.") == true)

        try await service.stage(["notes.txt"], in: root.path)
        status = try await service.status(in: root.path)
        XCTAssertEqual(status.entries.last?.staged, true); XCTAssertEqual(status.entries.last?.unstaged, false); XCTAssertEqual(status.stagedCount, 1)
        let stagedDiff = try await service.diffFiles(in: root.path, paths: ["notes.txt"], staged: true)
        XCTAssertEqual(stagedDiff.first?.added, 2)
        try await service.unstage(["notes.txt"], in: root.path)
        status = try await service.status(in: root.path)
        XCTAssertEqual(status.stagedCount, 0)
        try await service.stage(["notes.txt", "new file.md"], in: root.path)
        let short = try await service.commit(message: "Revise notes\n\nSecond paragraph.", in: root.path)
        XCTAssertEqual(short.count, 7)
        status = try await service.status(in: root.path)
        XCTAssertTrue(status.entries.isEmpty)

        let log = try await service.log(in: root.path)
        XCTAssertEqual(log.map(\.subject), ["Revise notes", "Initial notes"])
        XCTAssertEqual(log.first?.shortHash, short); XCTAssertEqual(log.first?.author, "Fixture"); XCTAssertEqual(log.first?.parents.count, 1)
        let detail = try await service.commitDetail(in: root.path, commit: log[0])
        XCTAssertEqual(detail.message, "Revise notes\n\nSecond paragraph.")
        XCTAssertEqual(detail.files.map(\.path), ["new file.md", "notes.txt"]); XCTAssertEqual(detail.files.map(\.badge), ["A", "M"])
        // The detail carries counts, not the patch: selecting a commit never waits for diff text.
        XCTAssertEqual(detail.stats["notes.txt"], GitDiffStat(added: 2, removed: 1, binary: false))
        XCTAssertEqual(detail.stats["new file.md"]?.added, 1)
        XCTAssertEqual(detail.insertions, 3); XCTAssertEqual(detail.deletions, 1)
        XCTAssertEqual(detail.summary, "2 files · +3 −1"); XCTAssertFalse(detail.isLarge)
        let commitDiff = try await service.commitDiffFiles(in: root.path, commit: log[0])
        XCTAssertEqual(commitDiff.count, 2)
        let oneFile = try await service.commitDiffFiles(in: root.path, commit: log[0], path: "notes.txt")
        XCTAssertEqual(oneFile.map(\.path), ["notes.txt"]); XCTAssertEqual(oneFile.first?.added, 2)
        let paged = try await service.log(in: root.path, limit: 1, skip: 1)
        XCTAssertEqual(paged.map(\.subject), ["Initial notes"])
        do { _ = try await service.commit(message: "  ", in: root.path); XCTFail("An empty message is refused") } catch {}
    }

    func testBranchesStashAmendDiscardAndFilteredHistory() async throws {
        let root = try repository(); defer { try? FileManager.default.removeItem(at: root) }
        try git(["init", "-q", "-b", "main"], in: root)
        try git(["config", "user.name", "Fixture"], in: root); try git(["config", "user.email", "fixture@example.com"], in: root)
        try git(["config", "commit.gpgsign", "false"], in: root)
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "First commit"], in: root)
        try git(["tag", "v1"], in: root)
        let service = GitService()

        // Branches: list, create (checked out), switch back.
        var branches = try await service.branches(in: root.path)
        XCTAssertEqual(branches, ["main"])
        try await service.createBranch("feature/x", in: root.path)
        var status = try await service.status(in: root.path)
        XCTAssertEqual(status.branch, "feature/x")
        branches = try await service.branches(in: root.path)
        XCTAssertEqual(branches, ["feature/x", "main"])
        do { try await service.createBranch("has space", in: root.path); XCTFail("Spaces are refused") } catch {}
        try "b\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Feature work by Fixture"], in: root)
        try await service.checkout("main", in: root.path)
        status = try await service.status(in: root.path)
        XCTAssertEqual(status.branch, "main")

        // History: refs, the all-branches switch, text and author filters.
        var log = try await service.log(in: root.path)
        XCTAssertEqual(log.map(\.subject), ["First commit"])
        XCTAssertTrue(log[0].refs.contains("HEAD -> main"), "\(log[0].refs)"); XCTAssertTrue(log[0].refs.contains("tag: v1"), "\(log[0].refs)")
        log = try await service.log(in: root.path, filter: GitLogFilter(allBranches: true))
        XCTAssertEqual(log.map(\.subject), ["Feature work by Fixture", "First commit"])
        XCTAssertTrue(log[0].refs.contains("feature/x"))
        log = try await service.log(in: root.path, filter: GitLogFilter(allBranches: true, text: "feature"))
        XCTAssertEqual(log.map(\.subject), ["Feature work by Fixture"], "Text filter is case-insensitive")
        log = try await service.log(in: root.path, filter: GitLogFilter(allBranches: true, text: String(log[0].hash.prefix(8))))
        XCTAssertEqual(log.map(\.subject), ["Feature work by Fixture"], "A hash prefix matches too")
        log = try await service.log(in: root.path, filter: GitLogFilter(allBranches: true, author: "nobody"))
        XCTAssertTrue(log.isEmpty)
        log = try await service.log(in: root.path, filter: GitLogFilter(allBranches: true, author: "fixture"))
        XCTAssertEqual(log.count, 2)

        // Per-file commit diff.
        let feature = try await service.log(in: root.path, filter: GitLogFilter(allBranches: true))[0]
        let fileDiff = try await service.commitDiffFiles(in: root.path, commit: feature, path: "b.txt")
        XCTAssertEqual(fileDiff.map(\.path), ["b.txt"]); XCTAssertEqual(fileDiff.first?.added, 1)

        // Stash: push takes everything including untracked files, list names it, pop restores it.
        try "a2\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "c\n".write(to: root.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        try await service.stashPush(message: "Work in progress", in: root.path)
        status = try await service.status(in: root.path)
        XCTAssertTrue(status.entries.isEmpty)
        let stashes = try await service.stashes(in: root.path)
        XCTAssertEqual(stashes.map(\.name), ["stash@{0}"]); XCTAssertEqual(stashes.first?.subject, "On main: Work in progress")
        try await service.stashPop("stash@{0}", in: root.path)
        status = try await service.status(in: root.path)
        XCTAssertEqual(status.entries.map(\.path), ["a.txt", "c.txt"])
        let emptied = try await service.stashes(in: root.path)
        XCTAssertTrue(emptied.isEmpty)

        // Commit only the checked file (a.txt) while c.txt stays untracked; then amend with c.txt and a new message.
        let headMessage = try await service.headMessage(in: root.path)
        XCTAssertEqual(headMessage, "First commit")
        _ = try await service.commit(message: "Change a", in: root.path, paths: ["a.txt"])
        status = try await service.status(in: root.path)
        XCTAssertEqual(status.entries.map(\.path), ["c.txt"]); XCTAssertEqual(status.entries.first?.untracked, true)
        let before = try await service.log(in: root.path)
        _ = try await service.commit(message: "Change a and add c", in: root.path, paths: ["c.txt"], amend: true)
        let after = try await service.log(in: root.path)
        XCTAssertEqual(after.map(\.subject), ["Change a and add c", "First commit"])
        XCTAssertEqual(after.count, before.count, "Amend rewrites HEAD instead of adding a commit")
        XCTAssertNotEqual(after[0].hash, before[0].hash)
        let detail = try await service.commitDetail(in: root.path, commit: after[0])
        XCTAssertEqual(detail.files.map(\.path), ["a.txt", "c.txt"])
        status = try await service.status(in: root.path)
        XCTAssertTrue(status.entries.isEmpty)

        // Discard: tracked edits revert, untracked files are deleted, staged edits go too.
        try "a3\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "d\n".write(to: root.appendingPathComponent("d.txt"), atomically: true, encoding: .utf8)
        try await service.stage(["a.txt"], in: root.path)
        status = try await service.status(in: root.path)
        XCTAssertEqual(status.entries.count, 2)
        try await service.discard(status.entries, in: root.path)
        status = try await service.status(in: root.path)
        XCTAssertTrue(status.entries.isEmpty)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8), "a2\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("d.txt").path))

        // Remotes without a remote fail with git's own message instead of hanging.
        do { try await service.push(in: root.path); XCTFail("No remote is configured") } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    func testSplitRowsPairRemovedAndAddedLines() {
        let text = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,4 +1,4 @@\n keep\n-old one\n-old two\n+new one\n keep two\n+tail\n\\ No newline at end of file\n"
        let hunk = try! XCTUnwrap(GitDiffParser.parse(text).first?.hunks.first)
        let rows = hunk.splitRows()
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows[0].left?.text, "keep"); XCTAssertEqual(rows[0].right?.text, "keep")
        XCTAssertEqual(rows[1].left?.text, "old one"); XCTAssertEqual(rows[1].right?.text, "new one")
        XCTAssertEqual(rows[2].left?.text, "old two"); XCTAssertNil(rows[2].right, "The longer side is padded")
        XCTAssertEqual(rows[3].left?.kind, .context); XCTAssertEqual(rows[3].left?.oldNumber, 4); XCTAssertEqual(rows[3].right?.newNumber, 3)
        XCTAssertNil(rows[4].left); XCTAssertEqual(rows[4].right?.text, "tail")
        XCTAssertEqual(rows[5].left?.kind, .note); XCTAssertEqual(rows[5].right?.kind, .note, "A note spans both sides")
    }

    /// Swift reads "\r\n" as one Character: splitting a patch on "\n" alone
    /// left every line of a file with Windows endings in a single row.
    func testDiffParserSplitsWindowsLineEndings() {
        let text = "diff --git a/w.txt b/w.txt\n--- a/w.txt\n+++ b/w.txt\n@@ -1,3 +1,3 @@\n one\r\n-two\r\n+two changed\r\n three\r\n"
        let hunk = try! XCTUnwrap(GitDiffParser.parse(text).first?.hunks.first)
        XCTAssertEqual(hunk.lines.map(\.text), ["one", "two", "two changed", "three"])
        XCTAssertEqual(hunk.lines.map(\.kind), [.context, .removed, .added, .context])
        let rows = hunk.splitRows()
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1].left?.text, "two"); XCTAssertEqual(rows[1].right?.text, "two changed")
        // Mixed endings in one patch still line up.
        let mixed = "diff --git a/m.txt b/m.txt\n--- a/m.txt\n+++ b/m.txt\n@@ -1,2 +1,2 @@\n-plain\n+crlf\r\n"
        let mixedHunk = try! XCTUnwrap(GitDiffParser.parse(mixed).first?.hunks.first)
        XCTAssertEqual(mixedHunk.lines.map(\.text), ["plain", "crlf"])
    }

    func testDiffParserHandlesRenamesBinariesAndMalformedInput() {
        let text = """
        diff --git a/old name.swift b/new name.swift
        similarity index 90%
        rename from old name.swift
        rename to new name.swift
        --- a/old name.swift
        +++ b/new name.swift
        @@ -1,3 +1,3 @@ struct Thing {
         let a = 1
        -let b = 2
        +let b = 3
         let c = 4
        \\ No newline at end of file
        diff --git a/image.png b/image.png
        Binary files a/image.png and b/image.png differ
        """
        let files = GitDiffParser.parse(text)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].oldPath, "old name.swift"); XCTAssertEqual(files[0].newPath, "new name.swift"); XCTAssertTrue(files[0].renamed)
        XCTAssertEqual(files[0].hunks.first?.header, "@@ -1,3 +1,3 @@ struct Thing {")
        XCTAssertEqual(files[0].hunks.first?.lines.map(\.kind), [.context, .removed, .added, .context, .note])
        XCTAssertEqual(files[0].hunks.first?.lines[3].oldNumber, 3); XCTAssertEqual(files[0].hunks.first?.lines[3].newNumber, 3)
        XCTAssertTrue(files[1].binary); XCTAssertEqual(files[1].path, "image.png"); XCTAssertTrue(files[1].hunks.isEmpty)
        XCTAssertTrue(GitDiffParser.parse("").isEmpty)
        let trailing = GitDiffParser.parse("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n")
        XCTAssertEqual(trailing.first?.hunks.first?.lines.map(\.kind), [.removed, .added], "The terminating newline adds no context row")
        XCTAssertTrue(GitDiffParser.parse("garbage without headers\n+not a hunk").isEmpty)
        let status = GitService.parseStatus(Data("# branch.oid abc\u{0}# branch.head main\u{0}# branch.upstream origin/main\u{0}# branch.ab +2 -1\u{0}1 .M N... 100644 100644 100644 h h path with space.txt\u{0}2 R. N... 100644 100644 100644 h h R100 renamed.txt\u{0}orig.txt\u{0}? untracked.txt\u{0}".utf8))
        XCTAssertEqual(status.branch, "main"); XCTAssertEqual(status.upstream, "origin/main"); XCTAssertEqual(status.ahead, 2); XCTAssertEqual(status.behind, 1)
        XCTAssertEqual(status.entries.map(\.path), ["path with space.txt", "renamed.txt", "untracked.txt"])
        XCTAssertEqual(status.entries[1].originalPath, "orig.txt"); XCTAssertEqual(status.entries[1].badge, "R"); XCTAssertTrue(status.entries[1].staged)
    }
}
