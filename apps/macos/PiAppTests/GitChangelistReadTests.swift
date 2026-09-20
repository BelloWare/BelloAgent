import XCTest
import SwiftUI
import AppKit
@testable import PiApp

extension GitPanelAuditTests {
    // MARK: Reads the panel leaves behind

    /// Clicking down a list of changed files used to leave one `git diff`
    /// running per file. Choosing another file must stop the last read.
    @MainActor func testSupersededFileDiffsAreStoppedAndLeaveNoProcess() async throws {
        let root = try repository("git-super"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        let names = (0..<16).map { "big\($0).txt" }
        let padding = String(repeating: "x", count: 40)
        let body = (0..<120_000).map { "original line \($0) \(padding)" }.joined(separator: "\n") + "\n"
        for name in names { try body.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Sixteen big files"], in: root)
        let changed = (0..<120_000).map { "changed line \($0) \(padding)" }.joined(separator: "\n") + "\n"
        for name in names { try changed.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }

        let controller = GitController(roots: [root.path])
        try await eventually("read the changes and the first diff") { controller.status.entries.count == 16 && !controller.diffLoading }
        try await eventually("go idle before the clicks start", timeout: 10) { self.gitChildren().isEmpty }
        // Clicking straight down the list, the way a reader does.
        for name in names {
            controller.selection = GitController.Selection(path: name, staged: false)
            try await Task.sleep(for: .milliseconds(6))
        }
        let alive = gitChildren().count
        print("PERF git processes alive after clicking through 16 changed files: \(alive)")
        XCTAssertLessThanOrEqual(alive, 2, "only the newest read runs: \(alive) git processes were computing patches nobody asked for")
        try await eventually("settle on the last file") { !controller.diffLoading && controller.diff.first?.path == names.last }

        // And closing the panel stops whatever is still running.
        controller.selection = GitController.Selection(path: names[0], staged: false)
        controller.stop()
        try await eventually("leave no git behind", timeout: 10) { self.gitChildren().isEmpty }
        XCTAssertTrue(gitChildren().allSatisfy { $0.state.first != "Z" }, "and no unreaped child")
    }

    /// What a diff can contain: CRLF, bytes that are not UTF-8 at all, a line
    /// thousands of characters long, and a file with no newline at the end.
    @MainActor func testDiffsSurviveCRLFForeignBytesAndVeryLongLines() async throws {
        let root = try repository("git-bytes"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try Data("first\r\nsecond\r\nthird\r\n".utf8).write(to: root.appendingPathComponent("crlf.txt"))
        try Data([0x68, 0x69, 0x0a, 0xff, 0xfe, 0x80, 0x0a, 0x62, 0x79, 0x65, 0x0a]).write(to: root.appendingPathComponent("latin.txt"))
        try Data((String(repeating: "L", count: 20_000) + "\n").utf8).write(to: root.appendingPathComponent("long.txt"))
        try Data("no trailing newline".utf8).write(to: root.appendingPathComponent("tail.txt"))
        try git(["add", "-A"], in: root); try git(["commit", "-q", "-m", "Seed odd bytes"], in: root)
        try Data("first\r\nsecond changed\r\nthird\r\n".utf8).write(to: root.appendingPathComponent("crlf.txt"))
        try Data([0x68, 0x69, 0x0a, 0xff, 0xfe, 0x81, 0x0a, 0x62, 0x79, 0x65, 0x0a]).write(to: root.appendingPathComponent("latin.txt"))
        try Data((String(repeating: "L", count: 19_000) + String(repeating: "M", count: 1_000) + "\n").utf8).write(to: root.appendingPathComponent("long.txt"))
        try Data("no trailing newline at all".utf8).write(to: root.appendingPathComponent("tail.txt"))

        let service = GitService()
        let discovered = await service.repositoryRoot(of: root.path)
        let top = try XCTUnwrap(discovered)
        let crlf = try await service.diffFiles(in: top, paths: ["crlf.txt"], staged: false)
        let lines = try XCTUnwrap(crlf.first?.hunks.first?.lines)
        XCTAssertEqual(lines.count, 4, "a file with Windows endings is four rows, not one: \(lines.map(\.text))")
        XCTAssertEqual(lines.map(\.kind), [.context, .removed, .added, .context])
        XCTAssertEqual(lines.map(\.text), ["first", "second", "second changed", "third"])
        XCTAssertEqual(lines.map(\.oldNumber), [1, 2, nil, 3])
        XCTAssertEqual(lines.map(\.newNumber), [1, nil, 2, 3])

        let latin = try await service.diffFiles(in: top, paths: ["latin.txt"], staged: false)
        XCTAssertFalse(latin.isEmpty, "bytes that are not UTF-8 still produce a readable diff")
        XCTAssertEqual(latin.first?.path, "latin.txt")

        let long = try await service.diffFiles(in: top, paths: ["long.txt"], staged: false)
        let longest = long.first?.hunks.first?.lines.map(\.text.count).max() ?? 0
        XCTAssertGreaterThan(longest, 19_000, "a very long line arrives whole")
        XCTAssertEqual(long.first?.added, 1)

        let tail = try await service.diffFiles(in: top, paths: ["tail.txt"], staged: false)
        XCTAssertTrue(tail.first?.hunks.first?.lines.contains { $0.kind == .note } == true, "the missing final newline is noted")

        // And all four render in one pane without stalling.
        let files = crlf + latin + long + tail
        let holder = DiffHolder()
        let view = DiffView(files: files, title: "Four awkward files", subtitle: nil, identity: "bytes",
                            split: Binding(get: { true }, set: { _ in }), expanded: Binding(get: { holder.expanded }, set: { holder.expanded = $0 }))
        var window: NSWindow!
        let cost = milliseconds {
            window = host(view, width: 520, height: 600)
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
        defer { window.contentView = nil; window.close() }
        print(String(format: "PERF diff pane with CRLF, foreign bytes and a 20000-character line: %.0f ms", cost))
        XCTAssertLessThan(cost, 3_000)
    }

    /// Searching history by message, by hash and by author, across branches,
    /// and the branch and tag names a commit carries.
    @MainActor func testHistorySearchAcrossBranchesAndRefBadges() async throws {
        let root = try repository("git-search"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        for index in 1...3 {
            try "line \(index)\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            try git(["add", "."], in: root)
            try git(["-c", "user.name=Ada Lovelace", "-c", "user.email=ada@example.com", "commit", "-q", "-m", "Main commit \(index)"], in: root)
        }
        try git(["tag", "v1.0"], in: root)
        try git(["checkout", "-q", "-b", "feature"], in: root)
        try "side\n".write(to: root.appendingPathComponent("side.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root)
        try git(["-c", "user.name=Grace Hopper", "-c", "user.email=grace@example.com", "commit", "-q", "-m", "Only on the feature branch"], in: root)
        try git(["checkout", "-q", "main"], in: root)
        let sideHash = try git(["rev-parse", "feature"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)

        let controller = GitController(roots: [root.path])
        try await eventually("read the history") { controller.commits.count == 3 }
        let head = try XCTUnwrap(controller.commits.first)
        XCTAssertTrue(head.refs.contains { $0.contains("HEAD") && $0.contains("main") }, head.refs.description)
        XCTAssertTrue(head.refs.contains("tag: v1.0"), "the tag is on the commit it points at: \(head.refs)")

        controller.logFilter.text = "commit 2"
        try await eventually("filter by message") { controller.commits.map(\.subject) == ["Main commit 2"] }

        controller.logFilter.text = ""
        controller.logFilter.author = "Grace"
        try await eventually("find nothing on this branch by that author") { controller.commits.isEmpty }
        controller.logFilter.allBranches = true
        try await eventually("find the other branch's commit") { controller.commits.map(\.subject) == ["Only on the feature branch"] }
        XCTAssertTrue(controller.commits.first?.refs.contains("feature") == true)

        controller.logFilter.author = ""
        controller.logFilter.allBranches = false
        controller.logFilter.text = String(sideHash.prefix(8))
        try await eventually("find a commit off this branch by its hash") { controller.commits.count >= 1 }
        XCTAssertEqual(controller.commits.first?.hash, sideHash, "a hash finds its commit even from another branch")
        XCTAssertEqual(controller.notice, "")
    }
}
