import XCTest
@testable import GitView

/// Who last changed each line (`GitService.blame`), against real
/// repositories: several authors, a rename with lines moved, the first
/// commit, a merge, lines not committed yet, odd file names, and the files
/// that have no history to show.
final class GitBlameTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("git-blame-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.name", "Fixture"]); try git(["config", "user.email", "fixture@example.com"])
        try git(["config", "commit.gpgsign", "false"])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func git(_ arguments: [String], author: String? = nil, at date: Int? = nil) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        if let author { environment["GIT_AUTHOR_NAME"] = author; environment["GIT_AUTHOR_EMAIL"] = author.lowercased() + "@example.com" }
        if let date { environment["GIT_AUTHOR_DATE"] = "\(date) +0000"; environment["GIT_COMMITTER_DATE"] = "\(date) +0000" }
        process.environment = environment
        let out = Pipe(); process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self)
    }
    /// The file's bytes, as a viewer shows them.
    private func shown(_ name: String, in folder: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(name))
    }
    private func write(_ name: String, _ text: String) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private func commit(_ message: String, author: String, at date: Int) throws -> String {
        try git(["add", "-A"]); try git(["commit", "-q", "-m", message], author: author, at: date)
        return try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// What git itself says of one line: its commit, path and line there.
    private func gitSays(_ path: String, line: Int) throws -> (String, String, Int) {
        let text = try git(["blame", "--line-porcelain", "-L", "\(line),\(line)", "--", path])
        let first = text.split(separator: "\n")[0].split(separator: " ")
        let file = text.split(separator: "\n").first { $0.hasPrefix("filename ") }.map { String($0.dropFirst(9)) } ?? ""
        return (String(first[0]), file, Int(first[1]) ?? 0)
    }

    func testEachLineNamesItsCommitAuthorAndPlaceThere() async throws {
        try write("a.txt", "one\ntwo\nthree\n")
        let first = try commit("Start the list", author: "Ada", at: 1_700_000_000)
        try write("a.txt", "one\n2\nthree\nfour\n")
        let second = try commit("Number two, and four", author: "Grace", at: 1_700_100_000)
        let blame = try await GitService().blame(path: "a.txt", contents: try shown("a.txt", in: root.path), in: root.path)
        XCTAssertEqual(blame.lines.map(\.commit), [first, second, first, second])
        XCTAssertEqual(blame.lines.map(\.line), [1, 2, 3, 4])
        XCTAssertEqual(blame.commit(ofLine: 1)?.author, "Grace")
        XCTAssertEqual(blame.commit(ofLine: 1)?.email, "grace@example.com")
        XCTAssertEqual(blame.commit(ofLine: 1)?.summary, "Number two, and four")
        XCTAssertEqual(blame.commit(ofLine: 1)?.date, Date(timeIntervalSince1970: 1_700_100_000))
        XCTAssertEqual(blame.commit(ofLine: 0)?.author, "Ada")
        for index in 0..<4 {
            let (hash, path, line) = try gitSays("a.txt", line: index + 1)
            XCTAssertEqual(blame.lines[index].commit, hash); XCTAssertEqual(blame.lines[index].path, path); XCTAssertEqual(blame.lines[index].line, line)
        }
    }

    /// Renamed, with lines added above: each old line names the commit and
    /// the name and line number it had there, not today's.
    func testARenamedFileWithLinesMovedNamesTheOldNameAndLine() async throws {
        let letters = (0..<20).map { "greek letter number \($0)" }
        try write("old/name.txt", letters.joined(separator: "\n") + "\n")
        let first = try commit("Greek letters", author: "Ada", at: 1_700_000_000)
        try git(["mv", "old/name.txt", "new name.txt"])
        try write("new name.txt", (["inserted 1", "inserted 2"] + letters).joined(separator: "\n") + "\n")
        let second = try commit("Rename and insert", author: "Grace", at: 1_700_100_000)
        let blame = try await GitService().blame(path: "new name.txt", contents: try shown("new name.txt", in: root.path), in: root.path)
        XCTAssertEqual(blame.lines[0].commit, second); XCTAssertEqual(blame.lines[0].path, "new name.txt"); XCTAssertEqual(blame.lines[0].line, 1)
        XCTAssertEqual(blame.lines[3].commit, first, "letter 1 was written in the first commit")
        XCTAssertEqual(blame.lines[3].path, "old/name.txt", "under its old name")
        XCTAssertEqual(blame.lines[3].line, 2, "on its old line")
        for index in 0..<22 {
            let (hash, path, line) = try gitSays("new name.txt", line: index + 1)
            XCTAssertEqual(blame.lines[index].commit, hash); XCTAssertEqual(blame.lines[index].path, path); XCTAssertEqual(blame.lines[index].line, line)
        }
    }

    /// Lines changed on disk and not committed have no commit; the rest do.
    func testUncommittedLinesHaveNoCommit() async throws {
        try write("a.txt", "one\ntwo\n")
        let first = try commit("Start", author: "Ada", at: 1_700_000_000)
        try write("a.txt", "one\nchanged\nadded\n")
        let blame = try await GitService().blame(path: "a.txt", contents: try shown("a.txt", in: root.path), in: root.path)
        XCTAssertEqual(blame.lines.map(\.commit), [first, nil, nil])
        XCTAssertNil(blame.commit(ofLine: 1))
    }

    func testAFileWithoutHistoryAndOneTooLongAreSaid() async throws {
        try write("a.txt", "one\n"); _ = try commit("Start", author: "Ada", at: 1_700_000_000)
        try write("new.txt", "untracked\n")
        do { _ = try await GitService().blame(path: "new.txt", contents: try shown("new.txt", in: root.path), in: root.path); XCTFail("untracked") }
        catch { XCTAssertTrue(error.localizedDescription.hasPrefix("Not committed yet"), error.localizedDescription) }
        let many = Data(repeating: 10, count: GitService.blameLineLimit + 1)
        do { _ = try await GitService().blame(path: "a.txt", contents: many, in: root.path); XCTFail("too many lines") }
        catch { XCTAssertTrue(error.localizedDescription.hasPrefix("Too long to annotate"), error.localizedDescription) }
        let wide = Data(repeating: UInt8(ascii: "x"), count: GitService.blameByteLimit + 1)
        do { _ = try await GitService().blame(path: "a.txt", contents: wide, in: root.path); XCTFail("one line too wide") }
        catch { XCTAssertTrue(error.localizedDescription.hasPrefix("Too large to annotate"), error.localizedDescription) }
    }

    /// The bytes shown are what is blamed: a line typed but not saved in git
    /// is not committed, whatever is on disk.
    func testTheBytesShownAreWhatIsBlamed() async throws {
        try write("a.txt", "one\ntwo\n")
        let first = try commit("Start", author: "Ada", at: 1_700_000_000)
        let blame = try await GitService().blame(path: "a.txt", contents: Data("one\nshown only\ntwo\n".utf8), in: root.path)
        XCTAssertEqual(blame.lines.map(\.commit), [first, nil, first])
    }

    /// Git's lines and a viewer's: CRLF lines are the same lines; a lone CR
    /// or UTF-16 is refused, not guessed; text without a final newline has
    /// its last line counted.
    func testLineEndingsGitAndAViewerCountAlike() async throws {
        XCTAssertEqual(GitBlameText.lineCount(of: Data("a\r\nb\r\n".utf8)), 2)
        XCTAssertEqual(GitBlameText.lineCount(of: Data("a\nb".utf8)), 2)
        XCTAssertEqual(GitBlameText.lineCount(of: Data()), 0)
        XCTAssertNil(GitBlameText.lineCount(of: Data("a\rb\n".utf8)), "a lone CR")
        XCTAssertNil(GitBlameText.lineCount(of: Data([0xFF, 0xFE, 0x61, 0x00])), "UTF-16")
        try write("crlf.txt", "one\r\ntwo\r\n")
        let first = try commit("CRLF", author: "Ada", at: 1_700_000_000)
        let blame = try await GitService().blame(path: "crlf.txt", contents: try shown("crlf.txt", in: root.path), in: root.path)
        XCTAssertEqual(blame.lines.map(\.commit), [first, first])
        do { _ = try await GitService().blame(path: "crlf.txt", contents: Data("one\rtwo\r".utf8), in: root.path); XCTFail("lone CR") }
        catch { XCTAssertTrue(error.localizedDescription.contains("line endings"), error.localizedDescription) }
    }

    /// A shallow clone's oldest commit is marked: the history before it is
    /// not here to compare with.
    func testAShallowEdgeIsMarked() async throws {
        try write("a.txt", "one\n"); _ = try commit("First", author: "Ada", at: 1_700_000_000)
        try write("a.txt", "one\ntwo\n"); let second = try commit("Second", author: "Grace", at: 1_700_100_000)
        let clone = root.deletingLastPathComponent().appendingPathComponent("git-blame-shallow-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: clone) }
        try git(["clone", "-q", "--depth", "1", "file://" + root.path, clone.path])
        let blame = try await GitService().blame(path: "a.txt", contents: try shown("a.txt", in: clone.path), in: clone.path)
        XCTAssertEqual(blame.lines.map(\.commit), [second, second], "the edge takes the lines before it")
        XCTAssertEqual(blame.commit(ofLine: 0)?.historyMissing, true)
        let full = try await GitService().blame(path: "a.txt", contents: try shown("a.txt", in: root.path), in: root.path)
        XCTAssertEqual(full.commit(ofLine: 1)?.historyMissing, false)
        XCTAssertEqual(full.commit(ofLine: 0)?.historyMissing, false, "a first commit is a commit like any other")
    }

    /// Names git would read as patterns or quote: blamed as written.
    func testOddNamesAreBlamedAsWritten() async throws {
        let names = ["[id].txt", "*.md", ":odd", "-dash.txt", "tab\tname.txt", "quote\"d.txt", "ünï cödé.txt"]
        for name in names { try write(name, "\(name)\n") }
        try write("i.txt", "bystander\n")
        let first = try commit("Odd names", author: "Ada", at: 1_700_000_000)
        for name in names {
            let blame = try await GitService().blame(path: name, contents: try shown(name, in: root.path), in: root.path)
            XCTAssertEqual(blame.lines.first?.commit, first, name)
            XCTAssertEqual(blame.lines.first?.path, name, "the name read back exactly")
        }
    }

    /// The first commit is blamed like any other; a merge's lines name the
    /// commit on the branch that wrote them.
    func testRootAndMergeCommits() async throws {
        try write("a.txt", "base\n")
        let root = try commit("Root", author: "Ada", at: 1_700_000_000)
        try git(["checkout", "-q", "-b", "side"]); try write("a.txt", "base\nside line\n")
        let side = try commit("Side", author: "Grace", at: 1_700_100_000)
        try git(["checkout", "-q", "main"]); try write("b.txt", "main file\n")
        _ = try commit("Main", author: "Ada", at: 1_700_200_000)
        try git(["merge", "-q", "--no-ff", "-m", "Merge side", "side"], at: 1_700_300_000)
        let blame = try await GitService().blame(path: "a.txt", contents: try shown("a.txt", in: self.root.path), in: self.root.path)
        XCTAssertEqual(blame.lines.map(\.commit), [root, side])
    }

    /// Output not read whole, or out of shape, attributes nothing.
    func testMalformedOrPartialOutputIsRefused() throws {
        let hash = String(repeating: "a", count: 40)
        let good = "\(hash) 1 1 1\nauthor A\nauthor-mail <a@x>\nauthor-time 1\nauthor-tz +0000\nsummary S\nfilename f.txt\n\tline\n"
        XCTAssertEqual(try GitBlameParser.parse(Data(good.utf8)).lines.count, 1)
        XCTAssertThrowsError(try GitBlameParser.parse(Data(good.utf8), expectedLines: 2), "a line missing")
        XCTAssertThrowsError(try GitBlameParser.parse(Data(String(good.dropLast(6)).utf8)), "cut before its line")
        XCTAssertThrowsError(try GitBlameParser.parse(Data("not a header\n".utf8)))
        XCTAssertThrowsError(try GitBlameParser.parse(Data("\(hash) 1 2 1\nfilename f\n\tline\n".utf8)), "lines out of order")
        XCTAssertEqual(GitBlameParser.unquoted("\"tab\\tname\\\"q\\303\\274.txt\""), "tab\tname\"qü.txt")
    }

    /// A commit's file diff the way a blame click reads it: the first commit
    /// against nothing whatever log.showRoot says, and a renamed file as a
    /// rename (asked for under both names), its quoted names read back.
    func testHistoricalDiffsOfRootsAndRenames() async throws {
        try git(["config", "log.showRoot", "false"])
        let letters = (0..<20).map { "greek letter number \($0)" }
        try write("old\tname.txt", letters.joined(separator: "\n") + "\n")
        let first = try commit("Root", author: "Ada", at: 1_700_000_000)
        let service = GitService()
        let root = try await XCTUnwrapAsync(await service.commit(first, in: self.root.path))
        let rootDiff = try await service.commitDiffFiles(in: self.root.path, commit: root, path: "old\tname.txt")
        XCTAssertEqual(rootDiff.first?.added, 20, "the first commit shows its lines added")
        try git(["mv", "old\tname.txt", "new \"name\".txt"])
        try write("new \"name\".txt", (["inserted"] + letters).joined(separator: "\n") + "\n")
        let second = try commit("Rename", author: "Grace", at: 1_700_100_000)
        let renamed = try await XCTUnwrapAsync(await service.commit(second, in: self.root.path))
        let diff = try await service.commitDiffFiles(in: self.root.path, commit: renamed, path: "new \"name\".txt", renamedFrom: "old\tname.txt")
        XCTAssertEqual(diff.count, 1)
        XCTAssertEqual(diff.first?.oldPath, "old\tname.txt"); XCTAssertEqual(diff.first?.newPath, "new \"name\".txt")
        XCTAssertTrue(diff.first?.renamed == true)
        XCTAssertEqual(diff.first?.added, 1, "a rename with one line added, not a whole file")
    }
    /// A clean filter that turns the file into other lines with as many of
    /// them (reversed here) is refused: the lines git blamed are not these.
    func testAFilterThatChangesTheLinesIsRefused() async throws {
        try git(["config", "filter.reverse.clean", "tail -r"])
        try git(["config", "filter.reverse.smudge", "cat"])
        try write(".gitattributes", "*.rev filter=reverse\n")
        try write("a.rev", "one\ntwo\nthree\n")
        _ = try commit("Reversed", author: "Ada", at: 1_700_000_000)
        do { _ = try await GitService().blame(path: "a.rev", contents: Data("one\ntwo\nthree\n".utf8), in: root.path); XCTFail("reordered") }
        catch { XCTAssertTrue(error.localizedDescription.contains("other lines"), error.localizedDescription) }
    }

    /// A historical patch is git's own text, not a textconv's.
    func testHistoricalPatchesIgnoreTextconv() async throws {
        try git(["config", "diff.upper.textconv", "tr a-z A-Z"])
        try write(".gitattributes", "*.up diff=upper\n")
        try write("a.up", "quiet\n")
        let hash = try commit("Quiet", author: "Ada", at: 1_700_000_000)
        let service = GitService()
        let commit = try await XCTUnwrapAsync(await service.commit(hash, in: root.path))
        let diff = try await service.commitDiffFiles(in: root.path, commit: commit, path: "a.up")
        XCTAssertEqual(diff.first?.hunks.first?.lines.first { $0.kind == .added }?.text, "quiet")
    }
    private func XCTUnwrapAsync<T>(_ value: T?) async throws -> T { try XCTUnwrap(value) }
}
