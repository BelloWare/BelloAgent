import XCTest
@testable import GitView

/// What a commit takes is always said: the checked files' working-tree state,
/// or the index as staged; neither is inferred from the other. Reword Last
/// Commit changes the message and nothing else. Real repositories throughout.
final class GitCommitScopeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("git-scope-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.name", "Fixture"]); try git(["config", "user.email", "fixture@example.com"])
        try git(["config", "commit.gpgsign", "false"])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func git(_ arguments: [String], expect: Int32? = 0, environment: [String: String] = [:]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.quotepath=off"] + arguments
        process.currentDirectoryURL = root
        if !environment.isEmpty { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        let out = Pipe(); process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        if let expect { XCTAssertEqual(process.terminationStatus, expect, "git \(arguments.joined(separator: " "))") }
        return String(decoding: data, as: UTF8.self)
    }
    private func write(_ name: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    private func read(_ name: String) -> String? { try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
    private func head() throws -> String { try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines) }
    private func show(_ spec: String) throws -> String { try git(["show", spec]) }
    private func hook(_ name: String, _ script: String) throws {
        let url = root.appendingPathComponent(".git/hooks/" + name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    private func commitAll(_ message: String) throws { try git(["add", "-A"]); try git(["commit", "-q", "-m", message]) }
    /// Everything a reword must leave alone: the index entries and their
    /// content, and the bytes of the working tree's files.
    private func untouched(_ names: [String]) throws -> [String] {
        [try git(["ls-files", "-s"]), try git(["diff", "--cached", "--binary"]), try git(["diff", "--binary"])] + names.map { read($0) ?? "<gone>" }
    }

    /// A controller that has read the repository: it reads on its own when
    /// made, and a refresh asked for meanwhile would be superseded by it.
    @MainActor private func controller() async throws -> GitController {
        let controller = GitController(roots: [root.path])
        try await settled(controller)
        return controller
    }
    @MainActor private func settled(_ controller: GitController, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            if controller.statusRead, !controller.loading, !controller.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the controller never read the repository", file: file, line: line)
    }

    // MARK: Scope

    /// Staged A and unstaged B, every file unticked: Commit Checked Files has
    /// nothing to commit and commits nothing; it never falls back to the index.
    /// Commit Staged Changes, chosen on its own, takes A and leaves B alone.
    @MainActor func testUntickingEveryFileIsNotConsentToCommitTheIndex() async throws {
        try write("a.txt", "a1\n"); try write("b.txt", "b1\n"); try commitAll("Initial")
        try write("a.txt", "a2\n"); try write("b.txt", "b2\n"); try git(["add", "a.txt"])
        let controller = try await controller(); defer { controller.letGo() }
        let before = try head()
        controller.checked = []
        controller.commitMessage = "Only what I asked for"
        XCTAssertEqual(controller.commitScope, .checkedFiles, "checked files is the starting scope")
        await controller.commitInScope()
        XCTAssertEqual(try head(), before, "no checked file, no commit")
        XCTAssertEqual(controller.commitMessage, "Only what I asked for", "the message waits")
        XCTAssertEqual(controller.commitScope, .checkedFiles, "and the scope is not switched behind the reader's back")
        XCTAssertFalse(controller.notice.isEmpty)

        controller.commitScope = .stagedChanges
        await controller.commitInScope()
        XCTAssertNotEqual(try head(), before)
        XCTAssertEqual(try show("HEAD:a.txt"), "a2\n", "the staged file is committed")
        XCTAssertEqual(try show("HEAD:b.txt"), "b1\n", "the unstaged one is not")
        XCTAssertEqual(read("b.txt"), "b2\n"); XCTAssertEqual(try git(["diff", "--name-only"]), "b.txt\n", "and stays changed, unstaged")
        XCTAssertEqual(controller.commitMessage, "")
    }

    /// One file with a staged edit and a further unstaged one: each scope
    /// commits what it says.
    func testEachScopeCommitsWhatItSays() async throws {
        try write("f.txt", "base\n"); try commitAll("Initial")
        try write("f.txt", "staged\n"); try git(["add", "f.txt"]); try write("f.txt", "worktree\n")
        let service = GitService()
        _ = try await service.commit(message: "Staged", in: root.path, content: .staged)
        XCTAssertEqual(try show("HEAD:f.txt"), "staged\n", "staged changes: the index as staged")
        XCTAssertEqual(read("f.txt"), "worktree\n"); XCTAssertEqual(try git(["diff", "--name-only"]), "f.txt\n")

        try write("f.txt", "staged again\n"); try git(["add", "f.txt"]); try write("f.txt", "worktree again\n")
        _ = try await service.commit(message: "Checked", in: root.path, content: .files(paths: ["f.txt"], staging: []))
        XCTAssertEqual(try show("HEAD:f.txt"), "worktree again\n", "checked files: the whole working-tree state")
        XCTAssertEqual(try git(["status", "--porcelain"]), "", "nothing is left staged or changed")
    }

    func testAnEmptyScopeIsRefusedNotWidened() async throws {
        try write("a.txt", "a\n"); try commitAll("Initial")
        try write("a.txt", "a2\n")
        let service = GitService(), before = try head()
        do { _ = try await service.commit(message: "x", in: root.path, content: .files(paths: [], staging: [])); XCTFail("no paths") }
        catch { XCTAssertEqual(error.localizedDescription, "Tick the files to commit.") }
        do { _ = try await service.commit(message: "x", in: root.path, content: .staged); XCTFail("nothing staged") }
        catch { XCTAssertEqual(error.localizedDescription, "Nothing to commit: nothing is staged.") }
        // An amend of an unchanged index would only reword: refused here, Reword's job.
        do { _ = try await service.commit(message: "x", in: root.path, content: .staged, amend: true); XCTFail("amend of nothing") }
        catch { XCTAssertEqual(error.localizedDescription, "Nothing to commit: nothing is staged.") }
        XCTAssertEqual(try head(), before)
        XCTAssertEqual(read("a.txt"), "a2\n")
    }

    /// Amend keeps its scope: with staged changes it folds in the index only,
    /// with checked files only those files.
    func testAmendKeepsItsScope() async throws {
        try write("a.txt", "a\n"); try write("b.txt", "b\n"); try commitAll("Initial")
        try write("a.txt", "a2\n"); try write("b.txt", "b2\n"); try git(["add", "a.txt"])
        let service = GitService()
        _ = try await service.commit(message: "Initial, with a", in: root.path, content: .staged, amend: true)
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"]), "1\n")
        XCTAssertEqual(try show("HEAD:a.txt"), "a2\n"); XCTAssertEqual(try show("HEAD:b.txt"), "b\n")
        try write("a.txt", "a3\n"); try git(["add", "a.txt"])
        _ = try await service.commit(message: "Initial, with b", in: root.path, content: .files(paths: ["b.txt"], staging: []), amend: true)
        XCTAssertEqual(try show("HEAD:b.txt"), "b2\n"); XCTAssertEqual(try show("HEAD:a.txt"), "a2\n", "the staged a3 stays out")
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]), "a.txt\n", "and stays staged")
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "Initial, with b\n")
    }

    /// Two commits asked for at once (a double click) make one commit.
    @MainActor func testADoubleClickCommitsOnce() async throws {
        try write("a.txt", "a\n"); try commitAll("Initial")
        try write("a.txt", "a2\n")
        let controller = try await controller(); defer { controller.letGo() }
        controller.commitMessage = "Once"
        async let first: Void = controller.commitChecked()
        async let second: Void = controller.commitChecked()
        _ = await (first, second)
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"]), "2\n", "one commit, not two")
        XCTAssertEqual(controller.notice, "", "the second click is not tried and failed: it never starts")
        XCTAssertNotNil(controller.lastCommit)
    }

    /// A failed commit keeps the message, the ticks and the scope.
    @MainActor func testAFailedCommitKeepsTheMessageAndTheTicks() async throws {
        try write("a.txt", "a\n"); try write("b.txt", "b\n"); try commitAll("Initial")
        try write("a.txt", "a2\n"); try write("b.txt", "b2\n")
        try hook("pre-commit", "#!/bin/sh\nexit 1\n")
        let controller = try await controller(); defer { controller.letGo() }
        controller.checked = ["a.txt"]
        controller.commitMessage = "Will fail"
        await controller.commitChecked()
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"]), "1\n")
        XCTAssertEqual(controller.commitMessage, "Will fail")
        XCTAssertEqual(controller.checked, ["a.txt"])
        XCTAssertTrue(controller.notice.hasPrefix("Commit"), controller.notice)
    }

    // MARK: Reword

    /// Unrelated staged and unstaged work, an untracked file: the reword
    /// changes the message and the hash; the tree, the parents, the author,
    /// the index and the working tree stay exactly as they were.
    func testRewordChangesTheMessageAndNothingElse() async throws {
        try write("a.txt", "a\n"); try commitAll("Initial")
        try write("a.txt", "a2\n"); try write("b.txt", "b\n")
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "Tpyo in the message"], environment: ["GIT_AUTHOR_NAME": "Original Author", "GIT_AUTHOR_EMAIL": "author@example.com", "GIT_AUTHOR_DATE": "1700000000 +0130"])
        try write("a.txt", "a3 staged\n"); try git(["add", "a.txt"]); try write("a.txt", "a4 unstaged\n")
        try write("b.txt", "b unstaged\n"); try write("u.txt", "untracked\n")
        let oldHead = try head(), oldTree = try git(["rev-parse", "HEAD^{tree}"]), oldParents = try git(["rev-parse", "HEAD^@"])
        let oldAuthor = try git(["log", "-1", "--format=%an <%ae> %ad", "--date=raw"])
        let before = try untouched(["a.txt", "b.txt", "u.txt"])

        let short = try await GitService().reword(message: "Typo fixed\n\nWith a body.", in: root.path, expectedHead: oldHead)
        XCTAssertNotEqual(try head(), oldHead, "a new commit")
        XCTAssertTrue(try head().hasPrefix(short))
        XCTAssertEqual(try git(["log", "-1", "--format=%B"]), "Typo fixed\n\nWith a body.\n\n")
        XCTAssertEqual(try git(["rev-parse", "HEAD^{tree}"]), oldTree, "the same files")
        XCTAssertEqual(try git(["rev-parse", "HEAD^@"]), oldParents, "the same parents")
        XCTAssertEqual(try git(["log", "-1", "--format=%an <%ae> %ad", "--date=raw"]), oldAuthor, "the same author and date")
        XCTAssertEqual(try untouched(["a.txt", "b.txt", "u.txt"]), before, "index entries, staged and unstaged content, and files on disk unchanged")
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"]), "2\n", "rewritten, not added")
        XCTAssertEqual(try git(["symbolic-ref", "HEAD"]), "refs/heads/main\n", "the branch moved, HEAD still on it")
        XCTAssertTrue(try git(["reflog", "-1", "--format=%gs"]).hasPrefix("commit (amend): Typo fixed"))
    }

    func testRewordNeedsACommitAndTheOneThePanelSaw() async throws {
        let service = GitService()
        do { _ = try await service.reword(message: "x", in: root.path, expectedHead: nil); XCTFail("no HEAD") }
        catch { XCTAssertEqual(error.localizedDescription, "There is no commit to reword yet.") }
        try write("a.txt", "a\n"); try commitAll("First")
        let seen = try head()
        try write("a.txt", "a2\n"); try commitAll("Second, made elsewhere")
        let moved = try head()
        do { _ = try await service.reword(message: "Reworded", in: root.path, expectedHead: seen); XCTFail("HEAD moved") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed since"), error.localizedDescription) }
        XCTAssertEqual(try head(), moved, "the newer commit is not reworded in its place")
        do { _ = try await service.reword(message: "  \n", in: root.path, expectedHead: moved); XCTFail("empty message") } catch {}
        XCTAssertEqual(try head(), moved)
    }

    /// HEAD moving after the checks (a hook makes a commit) is caught at the
    /// ref update itself: the reword does not land on top of it.
    func testHeadMovingDuringTheRewordIsCaughtAtTheUpdate() async throws {
        try write("a.txt", "a\n"); try commitAll("First")
        let seen = try head()
        try hook("pre-commit", "#!/bin/sh\nunset GIT_INDEX_FILE\nmoved=$(git commit-tree HEAD^{tree} -p HEAD -m moved)\ngit update-ref HEAD $moved\n")
        do { _ = try await GitService().reword(message: "Reworded", in: root.path, expectedHead: seen); XCTFail("raced") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed while rewording"), error.localizedDescription) }
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "moved\n", "the newer commit stays")
        XCTAssertEqual(try git(["rev-parse", "HEAD^"]).trimmingCharacters(in: .whitespacesAndNewlines), seen)
    }

    func testRewordWaitsForAMergeInProgress() async throws {
        try write("c.txt", "base\n"); try commitAll("Base")
        try git(["checkout", "-q", "-b", "side"]); try write("c.txt", "side\n"); try commitAll("Side")
        try git(["checkout", "-q", "main"]); try write("c.txt", "main\n"); try commitAll("Main")
        try git(["merge", "side"], expect: 1)
        let before = try head()
        do { _ = try await GitService().reword(message: "Reworded", in: root.path, expectedHead: before); XCTFail("merging") }
        catch { XCTAssertTrue(error.localizedDescription.contains("merge"), error.localizedDescription) }
        XCTAssertEqual(try head(), before)
    }

    /// A finished merge commit keeps both parents, in order; a root commit
    /// stays a root; an empty commit can be reworded too.
    func testMergeRootAndEmptyCommitsKeepTheirShape() async throws {
        try write("a.txt", "a\n"); try commitAll("Root")
        let service = GitService()
        _ = try await service.reword(message: "Root, reworded", in: root.path, expectedHead: try head())
        XCTAssertEqual(try git(["rev-list", "--parents", "-n", "1", "HEAD"]).split(separator: " ").count, 1, "still a root commit")
        try git(["checkout", "-q", "-b", "side"]); try write("s.txt", "s\n"); try commitAll("Side")
        try git(["checkout", "-q", "main"]); try write("m.txt", "m\n"); try commitAll("Main")
        try git(["merge", "-q", "--no-ff", "-m", "Merge side", "side"])
        let parents = try git(["rev-parse", "HEAD^@"])
        _ = try await service.reword(message: "Merge the side branch", in: root.path, expectedHead: try head())
        XCTAssertEqual(try git(["rev-parse", "HEAD^@"]), parents, "both parents, first parent first")
        try git(["commit", "-q", "--allow-empty", "-m", "Empty"])
        _ = try await service.reword(message: "Empty, reworded", in: root.path, expectedHead: try head())
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "Empty, reworded\n")
    }

    /// The hooks git commit --amend runs still run, against an index of the
    /// commit's own tree. A hook that changes the commit's files, or the
    /// working tree, refuses the reword; prepare-commit-msg and commit-msg
    /// can edit or reject the message; post-rewrite hears "old new".
    func testHooksRunAndCannotChangeTheFiles() async throws {
        try write("a.txt", "a\n"); try write("s.txt", "s\n"); try commitAll("First")
        try write("s.txt", "s staged\n"); try git(["add", "s.txt"])
        let service = GitService(), first = try head()
        let before = try untouched(["a.txt", "s.txt"])

        // A git add in a hook goes to the reword's own index: the commit's
        // files would change, so it is refused; the reader's index is as it was.
        try hook("pre-commit", "#!/bin/sh\ngit update-index --add --cacheinfo 100644,$(echo x | git hash-object -w --stdin),hook.txt\n")
        do { _ = try await service.reword(message: "Reworded", in: root.path, expectedHead: first); XCTFail("hook changed files") }
        catch { XCTAssertTrue(error.localizedDescription.contains("A hook changed the commit's files"), error.localizedDescription) }
        XCTAssertEqual(try head(), first)
        XCTAssertEqual(try untouched(["a.txt", "s.txt"]), before, "the reader's index and files untouched")

        // A hook writing into the working tree: refused, and said.
        try hook("pre-commit", "#!/bin/sh\necho changed > a.txt\n")
        do { _ = try await service.reword(message: "Reworded", in: root.path, expectedHead: first); XCTFail("hook changed the worktree") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed files in the working tree"), error.localizedDescription) }
        XCTAssertEqual(try head(), first)
        try write("a.txt", "a\n")

        // An untracked file the hook overwrites counts too; thousands of
        // untracked files are compared without the hashing pipe stalling.
        let many = root.appendingPathComponent("many")
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        for index in 0..<3_000 { try "\(index)\n".write(to: many.appendingPathComponent("untracked-file-\(index).txt"), atomically: false, encoding: .utf8) }
        try write("u.txt", "untracked\n")
        try hook("pre-commit", "#!/bin/sh\necho changed > u.txt\n")
        do { _ = try await service.reword(message: "Reworded", in: root.path, expectedHead: first); XCTFail("hook changed an untracked file") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed files in the working tree"), error.localizedDescription) }
        XCTAssertEqual(try head(), first)
        try FileManager.default.removeItem(at: many); try FileManager.default.removeItem(at: root.appendingPathComponent("u.txt"))

        // Untracked names git would quote or split, a dangling link and a
        // link to a folder: none stops a reword the hooks leave alone, and a
        // link turned to another target is noticed.
        try write("line\nbreak.txt", "x\n"); try write("\"quoted.txt", "x\n")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: "nowhere")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try "x\n".write(to: root.appendingPathComponent("folder/inside.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("to-folder").path, withDestinationPath: "folder")
        try write("same-a.txt", "same\n"); try write("same-b.txt", "same\n")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "same-a.txt")
        try hook("pre-commit", "#!/bin/sh\nrm link && ln -s same-b.txt link\n")
        do { _ = try await service.reword(message: "Reworded", in: root.path, expectedHead: first); XCTFail("hook retargeted a link") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed files in the working tree"), error.localizedDescription) }
        XCTAssertEqual(try head(), first)
        try hook("pre-commit", "#!/bin/sh\nexit 0\n")
        _ = try await service.reword(message: "Odd names around", in: root.path, expectedHead: first)
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "Odd names around\n", "odd untracked names and links do not stop a reword")
        try git(["update-ref", "HEAD", first])
        for name in ["line\nbreak.txt", "\"quoted.txt", "dangling", "to-folder", "folder", "same-a.txt", "same-b.txt", "link"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }

        // Written and staged: the files on disk are what the reader is told of.
        try hook("pre-commit", "#!/bin/sh\necho changed > a.txt\ngit add a.txt\n")
        do { _ = try await service.reword(message: "Reworded", in: root.path, expectedHead: first); XCTFail("hook wrote and staged") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed files in the working tree"), error.localizedDescription) }
        try write("a.txt", "a\n")

        // A commit-msg hook staging something stages it in the reword's index,
        // not the reader's (and that changes the commit's files: refused).
        try hook("pre-commit", "#!/bin/sh\nexit 0\n")
        try hook("commit-msg", "#!/bin/sh\ngit rm -q --cached a.txt\n")
        do { _ = try await service.reword(message: "Reworded", in: root.path, expectedHead: first); XCTFail("commit-msg changed files") } catch {}
        XCTAssertEqual(try untouched(["a.txt", "s.txt"]), before, "a.txt still in the reader's index, s.txt still staged")

        try hook("prepare-commit-msg", "#!/bin/sh\nexit 1\n")
        try hook("commit-msg", "#!/bin/sh\nexit 0\n")
        do { _ = try await service.reword(message: "Reworded", in: root.path, expectedHead: first); XCTFail("prepare-commit-msg refused") } catch {}
        XCTAssertEqual(try head(), first, "prepare-commit-msg is not bypassed")

        try hook("prepare-commit-msg", "#!/bin/sh\necho \"[$2]\" >> \"$1\"\n")
        try hook("commit-msg", "#!/bin/sh\necho 'Reviewed-by: Hook' >> \"$1\"\n")
        try hook("post-rewrite", "#!/bin/sh\ncat > .git/rewritten\necho \"$1\" >> .git/rewritten\n")
        _ = try await service.reword(message: "Reworded", in: root.path, expectedHead: first)
        XCTAssertEqual(try git(["log", "-1", "--format=%B"]), "Reworded\n[message]\nReviewed-by: Hook\n\n")
        XCTAssertEqual(read(".git/rewritten"), "\(first) \(try head())\namend\n")
        XCTAssertEqual(try untouched(["a.txt", "s.txt"]), before, "and after a reword that went through, still as they were")

        try hook("commit-msg", "#!/bin/sh\necho 'No.' >&2\nexit 1\n")
        let second = try head()
        do { _ = try await service.reword(message: "Again", in: root.path, expectedHead: second); XCTFail("rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("No."), error.localizedDescription) }
        XCTAssertEqual(try head(), second)
    }

    /// A tracked file whose bytes change in a way git normalises away (CRLF
    /// to LF under autocrlf) is still a change on disk: refused.
    func testAHookRewritingLineEndingsIsNoticed() async throws {
        try git(["config", "core.autocrlf", "true"])
        try write("crlf.txt", "one\r\ntwo\r\n"); try write("b.txt", "b\n"); try commitAll("First")
        try write("b.txt", "b2\n"); try git(["add", "b.txt"])
        let first = try head()
        try hook("pre-commit", "#!/bin/sh\nprintf 'one\\ntwo\\n' > crlf.txt\n")
        do { _ = try await GitService().reword(message: "Reworded", in: root.path, expectedHead: first); XCTFail("line endings rewritten") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed files in the working tree"), error.localizedDescription) }
        XCTAssertEqual(try head(), first)
    }

    /// HEAD switched to another branch while a hook ran: the branch it was
    /// on still names the commit, but it is not the reader's HEAD any more.
    func testABranchSwitchDuringTheRewordIsRefused() async throws {
        try write("a.txt", "a\n"); try commitAll("First")
        try git(["branch", "other"])
        let first = try head()
        try hook("pre-commit", "#!/bin/sh\ngit symbolic-ref HEAD refs/heads/other\n")
        do { _ = try await GitService().reword(message: "Reworded", in: root.path, expectedHead: first); XCTFail("switched") }
        catch { XCTAssertTrue(error.localizedDescription.contains("another branch"), error.localizedDescription) }
        XCTAssertEqual(try git(["rev-parse", "main"]).trimmingCharacters(in: .whitespacesAndNewlines), first, "main is not rewritten behind the reader")
        XCTAssertEqual(try head(), first, "nor the branch HEAD is on now")
    }

    /// A shallow clone's HEAD records a parent the clone does not have: the
    /// reword is refused, and HEAD never becomes a new root.
    func testAShallowHeadKeepsItsParent() async throws {
        try write("a.txt", "a\n"); try commitAll("First")
        try write("a.txt", "a2\n"); try commitAll("Second")
        let clone = root.deletingLastPathComponent().appendingPathComponent("git-shallow-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: clone) }
        try git(["clone", "-q", "--depth", "1", "file://" + root.path, clone.path])
        let origin = root!; root = clone; defer { root = origin }
        try git(["config", "user.name", "Fixture"]); try git(["config", "user.email", "fixture@example.com"]); try git(["config", "commit.gpgsign", "false"])
        let parent = try git(["cat-file", "commit", "HEAD"]).split(separator: "\n").first { $0.hasPrefix("parent ") }.map(String.init)
        XCTAssertNotNil(parent)
        let before = try head()
        do { _ = try await GitService().reword(message: "Second, reworded", in: clone.path, expectedHead: before); XCTFail("shallow edge") }
        catch { XCTAssertTrue(error.localizedDescription.contains("shallow"), error.localizedDescription) }
        XCTAssertEqual(try head(), before)
        XCTAssertEqual(try git(["cat-file", "commit", "HEAD"]).split(separator: "\n").first { $0.hasPrefix("parent ") }.map(String.init), parent)
    }

    func testAnUnreadableSigningSettingStopsTheReword() async throws {
        try write("a.txt", "a\n"); try commitAll("First")
        try git(["config", "commit.gpgSign", "perhaps"])
        let first = try head()
        do { _ = try await GitService().reword(message: "Reworded", in: root.path, expectedHead: first); XCTFail("bad setting") } catch {}
        XCTAssertEqual(try head(), first, "never quietly unsigned")
    }

    /// Signing configured and failing: nothing changes.
    func testASigningFailureLeavesTheCommitAlone() async throws {
        try write("a.txt", "a\n"); try commitAll("First")
        try git(["config", "commit.gpgSign", "true"]); try git(["config", "gpg.program", "/usr/bin/false"])
        let first = try head()
        do { _ = try await GitService().reword(message: "Reworded", in: root.path, expectedHead: first); XCTFail("signing failed") } catch {}
        XCTAssertEqual(try head(), first)
    }

    /// The panel rewords the commit it read; a commit made elsewhere since is
    /// refused, and the message waits.
    @MainActor func testThePanelRewordsOnlyTheCommitItRead() async throws {
        try write("a.txt", "a\n"); try commitAll("First")
        try write("a.txt", "a2\n"); try git(["add", "a.txt"]); try write("b.txt", "untracked\n")
        let controller = try await controller(); defer { controller.letGo() }
        controller.commitMessage = "First, reworded"
        await controller.rewordLastCommit()
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "First, reworded\n")
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"]), "1\n")
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]), "a.txt\n", "the staged edit stays staged, out of the commit")
        XCTAssertEqual(controller.commitMessage, "")

        try git(["commit", "-q", "-m", "Made elsewhere"])
        controller.commitMessage = "Not this one"
        await controller.rewordLastCommit()
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "Made elsewhere\n")
        XCTAssertTrue(controller.notice.contains("changed since"), controller.notice)
        XCTAssertEqual(controller.commitMessage, "Not this one")
    }
}
