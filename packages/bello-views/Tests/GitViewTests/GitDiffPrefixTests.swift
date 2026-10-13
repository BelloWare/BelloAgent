import XCTest
@testable import GitView

/// The parser's paths must not depend on the reader's git display preferences.
final class GitDiffPrefixTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("git-prefix-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        for folder in ["a", "b"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true) }
        try git(["config", "core.hooksPath", "/dev/null"])
        try git(["config", "diff.mnemonicPrefix", "false"]); try git(["config", "diff.noprefix", "false"])
        try git(["config", "user.name", "Fixture"]); try git(["config", "user.email", "fixture@example.com"])
        try git(["config", "commit.gpgsign", "false"]); try git(["config", "core.filemode", "true"])
        try Data("#!/bin/sh\n".utf8).write(to: root.appendingPathComponent("a/mode only.sh"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent("a/mode only.sh").path)
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("b/binary file"))
        try Data("rename me\n".utf8).write(to: root.appendingPathComponent("a/old name"))
        try git(["add", "."]); try git(["commit", "-q", "-m", "Initial"])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func git(_ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments; process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    func testMnemonicPrefixes() async throws { try await check(["diff.mnemonicPrefix"]) }
    func testNoPrefixes() async throws { try await check(["diff.noprefix"]) }

    func testBothPrefixPreferences() async throws { try await check(["diff.mnemonicPrefix", "diff.noprefix"]) }

    private func check(_ configs: [String]) async throws {
        for config in configs { try git(["config", config, "true"]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("a/mode only.sh").path)
        try Data([0, 3, 4]).write(to: root.appendingPathComponent("b/binary file"))
        let service = GitService()
        checkChanges(try await service.diffFiles(in: root.path, staged: false), renamed: false)
        try git(["mv", "a/old name", "b/new name"]); try git(["add", "."])
        checkChanges(try await service.diffFiles(in: root.path, staged: true), renamed: true)
        try git(["commit", "-q", "-m", "Changes"])
        let history = try await service.log(in: root.path), commit = try XCTUnwrap(history.first)
        checkChanges(try await service.commitDiffFiles(in: root.path, commit: commit), renamed: true)
        let detail = try await service.commitDetail(in: root.path, commit: commit)
        XCTAssertEqual(Set(detail.files.map(\.path)), ["a/mode only.sh", "b/binary file", "b/new name"])
        XCTAssertEqual(Set(detail.stats.keys), ["a/mode only.sh", "b/binary file", "b/new name"])
        let rename = try await service.commitDiffFiles(in: root.path, commit: commit, path: "b/new name", renamedFrom: "a/old name")
        XCTAssertEqual(rename.map(\.oldPath), ["a/old name"]); XCTAssertEqual(rename.map(\.newPath), ["b/new name"])
        for (name, data) in [("untracked text", Data("new\n".utf8)), ("untracked binary", Data([0, 5]))] {
            try data.write(to: root.appendingPathComponent(name))
            let files = try await service.diffFiles(in: root.path, paths: [name], staged: false, untracked: true)
            XCTAssertEqual(files.map(\.path), [name], "no-index paths use the same prefixes")
            XCTAssertEqual(files.first?.binary, data.contains(0))
        }
    }
    private func checkChanges(_ files: [GitDiffFile], renamed: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(files.map(\.path)), Set(["a/mode only.sh", "b/binary file"] + (renamed ? ["b/new name"] : [])), file: file, line: line)
        let mode = files.first { $0.path == "a/mode only.sh" }
        XCTAssertEqual(mode?.notes, ["old mode 100644", "new mode 100755"], file: file, line: line)
        XCTAssertEqual(mode?.hunks, [], file: file, line: line)
        XCTAssertEqual(files.first { $0.path == "b/binary file" }?.binary, true, file: file, line: line)
        if renamed {
            let rename = files.first { $0.path == "b/new name" }
            XCTAssertEqual(rename?.oldPath, "a/old name", file: file, line: line)
            XCTAssertEqual(rename?.renamed, true, file: file, line: line)
        }
    }
}
