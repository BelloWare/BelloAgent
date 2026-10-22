import XCTest
import Darwin
@testable import GitView
@testable import GitProcessSafety

final class GitByteParsingTests: ViewsTestCase {
    func testUnicodeArgumentsKeepPathsAcrossReadsAndWrites() async throws {
        try git(["config", "core.precomposeUnicode", "false"])
        let service = GitService(environment: environment, trusted: true)
        for name in ["caf\u{e9}-nfc.txt", "cafe\u{301}-nfd.txt"] {
            let path = root.path + "/" + name
            let descriptor = path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            if descriptor >= 0 { _ = "base\n".withCString { Darwin.write(descriptor, $0, 5) }; close(descriptor) }
            try git(["add", "."]); try git(["commit", "-qm", "Fixture"])
            let listed = try await service.run(["ls-files", "-z", "--", name], in: root.path)
            XCTAssertEqual(listed.stdout, Data((name + "\0").utf8))
            for args in [["show", "HEAD:" + name], ["blame", "--porcelain", "--", name], ["log", "--format=%s", "--", name]] {
                let read = try await service.run(args, in: root.path)
                XCTAssertEqual(read.status, 0, args.debugDescription); XCTAssertFalse(read.stdout.isEmpty, args.debugDescription)
            }
            try Data("changed\n".utf8).write(to: URL(fileURLWithPath: path))
            let diff = try await service.run(["diff", "--numstat", "--", name], in: root.path)
            XCTAssertFalse(diff.stdout.isEmpty)
            try await service.stage([name], in: root.path)
            let staged = try await service.run(["diff", "--cached", "--numstat", "--", name], in: root.path)
            XCTAssertFalse(staged.stdout.isEmpty)
            try await service.unstage([name], in: root.path)
            _ = try await service.run(["restore", "--worktree", "--", name], in: root.path, readOnly: false)
            let restored = try await service.run(["diff", "--numstat", "--", name], in: root.path)
            XCTAssertTrue(restored.stdout.isEmpty)
        }
    }

    private let extenders = ["\u{301}", "\u{200d}", "\u{fe0f}", "\u{1f1f8}\u{1f1ec}"]
    func testCanonicalContainmentUsesBytesAndBoundaries() {
        for extender in extenders {
            let root = "/fixture/" + extender + "project", child = root + "/" + extender + "file"
            XCTAssertTrue(child.gitIsWithin(root))
            XCTAssertTrue(root.gitIsWithin(root))
            XCTAssertTrue(("/" + extender + "file").gitIsWithin("/"))
            XCTAssertFalse((root + "-sibling/file").gitIsWithin(root))
            XCTAssertFalse((root + extender + "/file").gitIsWithin(root))
        }
        XCTAssertFalse("/fixture/\u{e9}/file".gitIsWithin("/fixture/e\u{301}"), "Canonicalization belongs to the caller; the boundary compares the resulting bytes")
    }
    private var root: URL!
    private var environment: [String: String]!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("git-bytes-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        _ = try git(["init", "-q", "--template=", "-b", "main"])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    @discardableResult private func git(_ args: [String]) throws -> Data {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.currentDirectoryURL = root
        process.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.quotepath=false"] + args
        process.environment = environment; process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, args.debugDescription)
        return bytes
    }
    private func write(_ path: String, _ text: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func testGitOutputDelimiterMatrix() async throws {
        for (index, extender) in extenders.enumerated() {
            let path = extender + "file-\(index)", branch = extender + "branch-\(index)"
            let before = extender + "old\n", after = extender + "new\n"
            try write(path, before); try git(["add", "--", path]); try git(["commit", "-qm", extender + "subject"])
            try git(["branch", branch]); try write(path, after)
            let untracked = extender + "untracked-\(index)"; try write(untracked, "fixture\n")
            let status = GitService.parseStatus(try git(["status", "--porcelain=v2", "--branch", "-z"]))
            XCTAssertTrue(status.entries.contains { Data($0.path.utf8) == Data(path.utf8) }, extender.debugDescription)
            XCTAssertTrue(status.entries.contains { Data($0.path.utf8) == Data(untracked.utf8) }, extender.debugDescription)
            let stats = GitService.parseNumstat(try git(["diff", "--numstat", "-z", "--", path]))
            XCTAssertEqual(stats[path]?.added, 1)
            let raw = try git(["diff", "--full-index", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/", "--", path])
            let files = GitDiffParser.parse(String(decoding: raw, as: UTF8.self))
            XCTAssertEqual(files.map { Data($0.path.utf8) }, [Data(path.utf8)])
            XCTAssertEqual(files.flatMap(\.hunks).flatMap(\.lines).filter { $0.kind == .added }.map { Data($0.text.utf8) }, [Data((extender + "new").utf8)])
            do {
                let patch = try GitPatch(raw: raw, path: path)
                XCTAssertEqual(try patch.applying(hunk: 0, to: Data(before.utf8), reverse: false), Data(after.utf8))
            } catch { XCTFail("Git's literal patch must remain readable: \(extender.debugDescription): \(error)") }
            do {
                let blame = try GitBlameParser.parse(try git(["blame", "--porcelain", "HEAD", "--", path]))
                XCTAssertEqual(blame.lines.map { Data($0.path.utf8) }, [Data(path.utf8)])
            } catch { XCTFail("Git's literal blame must remain readable: \(extender.debugDescription): \(error)") }
            let service = GitService(environment: environment, trusted: true)
            let refs = try await service.historyReferences(in: root.path)
            XCTAssertEqual(refs.first { $0.name == "refs/heads/" + branch }?.title, branch)
            let catalog = try await service.branchCatalog(in: root.path)
            XCTAssertTrue(catalog.branches.contains { $0.name == branch && $0.remote == nil })
            let selected = try await service.log(in: root.path, limit: 1, reference: "refs/heads/" + branch)
            XCTAssertEqual(selected.first?.subject, extender + "subject")
            let parsed = GitService.parseLog(String(decoding: try git(["log", "-1", "--format=%H%x00%h%x00%an%x00%aI%x00%s%x00%P%x00%D%x1e"]), as: UTF8.self))
            XCTAssertEqual(parsed.first?.subject, extender + "subject")
        }
    }

    func testQuotedPathAndDiffMarkerMatrix() throws {
        for extender in extenders {
            let quotedName = "\"" + extender + "name\""
            XCTAssertEqual(Data(GitQuoting.unquoted(quotedName).utf8), Data((extender + "name").utf8))
            let boundary = try XCTUnwrap(GitQuoting.leading((quotedName + extender + "tail")[...]))
            XCTAssertEqual(Data(boundary.name.utf8), Data((extender + "name").utf8))
            XCTAssertEqual(Data(boundary.rest.utf8), Data((extender + "tail").utf8))
            let unquoted = try XCTUnwrap(GitQuoting.leading(("name " + extender + "tail")[...], upTo: " "))
            XCTAssertEqual(unquoted.name, "name")
            XCTAssertEqual(Data(unquoted.rest.utf8), Data((" " + extender + "tail").utf8))
            for delimiter in ["\"", "\\", "/", "\t", " "] {
                let path = delimiter + extender + "name"
                let quoted = "\"" + path.unicodeScalars.map { scalar in
                    switch scalar { case "\"": return "\\\""; case "\\": return "\\\\"; case "\t": return "\\t"; default: return String(scalar) }
                }.joined() + "\""
                XCTAssertEqual(Data(GitQuoting.unquoted(quoted).utf8), Data(path.utf8))
                let leading = try XCTUnwrap(GitQuoting.leading((quoted + " " + extender + "tail")[...]))
                XCTAssertEqual(Data(leading.name.utf8), Data(path.utf8))
                XCTAssertEqual(Data(leading.rest.utf8), Data((" " + extender + "tail").utf8))
            }
            let lines = [" " + extender + "context", "-" + extender + "old", "+" + extender + "new", "\\ " + extender + "note"]
            let raw = "diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1,2 +1,2 @@\n" + lines.joined(separator: "\r\n") + "\r\n"
            let parsed = GitDiffParser.parse(raw).flatMap(\.hunks).flatMap(\.lines)
            XCTAssertEqual(parsed.map(\.kind), [.context, .removed, .added, .note])
            XCTAssertEqual(parsed.map { Data($0.text.utf8) }, ["context", "old", "new", "note"].map { Data((extender + $0).utf8) })
        }
    }

    func testPatchPathComponentsRejectSymlinkTraversal() throws {
        for (index, extender) in extenders.enumerated() {
            let name = extender + "file", folder = "real-\(index)", link = "link-\(index)"
            try write(folder + "/" + name, "fixture\n")
            try FileManager.default.createSymbolicLink(atPath: root.path + "/" + link, withDestinationPath: folder)
            XCTAssertThrowsError(try GitPatchFile.read(in: root.path, path: link + "/" + name))
            XCTAssertEqual(try GitPatchFile.read(in: root.path, path: folder + "/" + name).bytes, Data("fixture\n".utf8))
        }
    }

    func testUntrackedCountSnapshotDelimiterMatrix() async throws {
        let service = GitService(environment: environment, trusted: true)
        for (index, extender) in extenders.enumerated() {
            let folder = "folder-\(index)", path = folder + "/" + extender + "file.bin"
            try write(folder + "/.gitattributes", "*.bin -diff\n")
            try git(["add", "--", folder + "/.gitattributes"])
            try git(["commit", "-qm", "Fixture attributes"])
            try write(path, "fixture\nsecond line\n")
            let status = try await service.status(in: root.path)
            let counts = try await service.changeStats(in: root.path, status: status)
            let reference = try await service.run(["diff", "--no-index", "--numstat", "-z", "--", "/dev/null", path], in: root.path)
            XCTAssertEqual(reference.status, 1)
            let expected = try XCTUnwrap(GitService.parseNumstat(reference.stdout)[path])
            XCTAssertTrue(expected.binary)
            XCTAssertEqual(counts[path]?.binary, expected.binary, path.debugDescription)
        }
    }

    func testResolutionChainSplitsOriginalAndReadlinkTargetBytes() throws {
        for (index, extender) in extenders.enumerated() {
            let file = extender + "config", directory = "real-\(index)", link = "link-\(index)", outer = "outer-\(index)"
            try write(directory + "/" + file, "[core]\nrepositoryformatversion = 0\n")
            try FileManager.default.createSymbolicLink(atPath: root.path + "/" + link, withDestinationPath: directory)
            try FileManager.default.createSymbolicLink(atPath: root.path + "/" + outer, withDestinationPath: link + "/" + file)
            for spelling in [link + "/" + file, outer] {
                let chain = GitFileStamp(root.path + "/" + spelling).resolution
                XCTAssertTrue(chain.complete)
                XCTAssertTrue(chain.stamps.contains { Data($0.path.utf8.suffix(("/" + link).utf8.count)) == Data(("/" + link).utf8) }, spelling.debugDescription)
            }
        }
    }

    func testWatcherMetadataAndIgnoredPathDelimiterMatrix() throws {
        for (index, extender) in extenders.enumerated() {
            let checkout = root.appendingPathComponent("checkout-\(index)"), storage = extender + "storage-\(index)"
            try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
            try write(storage + "/HEAD", "ref: refs/heads/main\n")
            try Data(("gitdir: ../" + storage + "\n").utf8).write(to: checkout.appendingPathComponent(".git"))
            XCTAssertEqual(GitWorkingTreeWatcher.gitDirectory(under: checkout.path), root.path + "/" + storage)
            XCTAssertTrue(GitWorkingTreeWatcher.isInteresting(root.path + "/.git/refs/" + extender + "branch", under: root.path, stateOnly: true))
            let ignored = GitIgnoredPaths()
            ignored.update(root: root.path, relative: ["folder/", extender + "ignored/"], scanStartedAt: 1)
            XCTAssertTrue(ignored.covers(root.path + "/folder/" + extender + "file"))
            XCTAssertTrue(ignored.covers(root.path + "/" + extender + "ignored/file"))
        }
    }

    func testGeneratedOverrideDelimiterMatrixMatchesGit() throws {
        try write("file", "fixture\n"); try git(["add", "file"]); try git(["commit", "-qm", "Fixture"])
        for extender in extenders {
            for delimiter in [".", "/", ":", "=", "\"", "\\", "[", "]", "*", "?", " ", "\t", "\n", "\0"] {
                let name = "filter." + (delimiter == "=" ? "value" : delimiter) + extender + "fixture.clean"
                let value = delimiter + extender + "value"
                do {
                    let overrides = try GitReadOverrides(gitDirectory: root.path + "/.git", options: ["-c", name + "=" + value])
                    defer { withExtendedLifetime(overrides) {} }
                    let parsed = try GitConfiguration.query(["config", "--file", overrides.directory.appendingPathComponent("config").path,
                                                            "--null", "--list"], in: root, environment: environment)
                    XCTAssertEqual(parsed.status, 0)
                    XCTAssertEqual(parsed.data, Data((name + "\n" + value + "\0").utf8))
                } catch is GitConfiguration.ConfinementRequired {
                    XCTAssertNotNil((name + value).rangeOfCharacter(from: .controlCharacters), delimiter.debugDescription)
                }
            }
        }
        for options in [["-c"], ["-c", "missing-separator"], ["-c", "missingsection=value"], ["-c", ".key=value"], ["-c", "core.=value"], ["-c", "core.\u{301}key=value"]] {
            XCTAssertThrowsError(try GitReadOverrides(gitDirectory: root.path + "/.git", options: options))
        }
    }
}
