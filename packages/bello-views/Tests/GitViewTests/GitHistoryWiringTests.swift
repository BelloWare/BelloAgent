import XCTest
@testable import GitView

/// Included in the stream-1 handoff patch; compiled against its controller API.
final class GitHistoryWiringTests: XCTestCase {
    @MainActor func testOpeningTheSameHashRetiresAnOlderBlameReveal() async throws {
        let repo = try HistoryWiringFixture(); defer { repo.close() }
        let older = try repo.git(["rev-parse", "HEAD"])
        try repo.git(["commit", "--allow-empty", "-qm", "Newer"])
        let controller = GitController(roots: [repo.root.path]); defer { controller.letGo() }
        await controller.refresh()
        try await wait { controller.commits.count == 2 && !controller.loading }
        let current = try XCTUnwrap(controller.commits.first)
        controller.openHistoryCommit(current)
        try await wait { !controller.commitLoading }
        var choseAgain = false
        let revealed = await controller.revealHistory(.init(commit: older, path: "file-0.txt", line: 1), in: try XCTUnwrap(controller.repositoryRoot)) {
            if !choseAgain { choseAgain = true; controller.openHistoryCommit(current) }
            return true
        }
        XCTAssertTrue(choseAgain)
        XCTAssertFalse(revealed)
        XCTAssertEqual(controller.selectedCommit?.hash, current.hash)
        XCTAssertNil(controller.revealTarget)
    }

    @MainActor func testClosingReleasesHistoryAndReopeningRestoresDefaultFilters() async throws {
        let repo = try HistoryWiringFixture(); defer { repo.close() }
        try repo.git(["branch", "feature/fixture"])
        let controller = GitController(roots: [repo.root.path]); defer { controller.letGo() }
        await controller.refresh()
        try await wait { controller.repositoryRoot != nil && !controller.loading }
        controller.historyOptions = .init(reference: "refs/heads/feature/fixture", dates: .init(from: "2026-01-01"))
        try await wait { controller.history.reading.query.scope == .reference("refs/heads/feature/fixture") && !controller.history.reading.loading }
        XCTAssertFalse(controller.history.reading.commits.isEmpty)
        controller.letGo()
        XCTAssertEqual(controller.history.reading, GitHistoryState.Reading())
        XCTAssertEqual(controller.historyOptions, GitHistoryOptions())
        XCTAssertTrue(controller.commits.isEmpty)
        controller.opened(); await controller.refresh()
        try await wait { controller.history.reading.snapshot != nil && !controller.history.reading.loading }
        XCTAssertEqual(controller.history.reading.query, GitHistoryQuery())
        XCTAssertEqual(controller.commits.count, 1)
    }

    @MainActor func testHashPinSurvivesFilterRefreshAndKeepsTheLargeDiffGate() async throws {
        let repo = try HistoryWiringFixture(files: 40); defer { repo.close() }
        let controller = GitController(roots: [repo.root.path]); defer { controller.letGo() }
        await controller.refresh()
        try await wait { controller.repositoryRoot != nil && !controller.loading }
        controller.logFilter.text = "no matching message"
        try await wait { controller.history.reading.query.message == "no matching message" && !controller.history.reading.loading }
        XCTAssertTrue(controller.commits.isEmpty)
        let hash = try repo.git(["rev-parse", "HEAD"])
        let commit = try await GitService().historyCommit(hash, in: repo.root.path)
        controller.openHistoryCommit(commit)
        try await wait { controller.detail != nil && !controller.commitLoading }
        XCTAssertEqual(controller.detail?.files.count, 40)
        XCTAssertTrue(controller.detailDiffDeferred); XCTAssertTrue(controller.detailDiff.isEmpty)
        await controller.refresh()
        try await wait { !controller.loading && !controller.history.reading.loading }
        XCTAssertEqual(controller.selectedCommit?.hash, hash)
        XCTAssertTrue(controller.commits.isEmpty)
        XCTAssertEqual(controller.logFilter.text, "no matching message")
    }

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(30))
        while !condition() {
            guard ContinuousClock.now < end else { throw NSError(domain: "HistoryWiringWait", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class HistoryWiringFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-wiring-" + UUID().uuidString)
    init(files: Int = 1) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-qb", "main"])
        for (key, value) in [("user.name", "History Fixture"), ("user.email", "history@example.invalid"),
                             ("commit.gpgsign", "false"), ("tag.gpgsign", "false"), ("core.hooksPath", "/dev/null"),
                             ("credential.helper", ""), ("core.fsmonitor", "false")] { try git(["config", key, value]) }
        for i in 0..<files { try "fixture\n".write(to: root.appendingPathComponent("file-\(i).txt"), atomically: true, encoding: .utf8) }
        try git(["add", "."]); try git(["commit", "-qm", "Fixture commit"])
    }
    @discardableResult func git(_ args: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args; process.currentDirectoryURL = root
        process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
                               "GIT_AUTHOR_DATE": "2026-01-01T12:00:00Z", "GIT_COMMITTER_DATE": "2026-10-14T12:00:00Z"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "HistoryWiringGit", code: Int(process.terminationStatus)) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    func close() { try? FileManager.default.removeItem(at: root) }
}
