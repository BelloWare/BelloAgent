import Combine
import XCTest
@testable import GitView

final class GitRepositoryStateTests: XCTestCase {
    private func repository() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("git-state-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try git(["init", "-qb", "main"], in: root)
        try git(["config", "core.hooksPath", "/dev/null"], in: root)
        try "base\n".write(to: root.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-qm", "Initial"], in: root)
        try "changed\n".write(to: root.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        return URL(fileURLWithPath: try git(["rev-parse", "--show-toplevel"], in: root).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    @discardableResult private func git(_ arguments: [String], in root: URL) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments
        process.currentDirectoryURL = root
        let out = Pipe(); process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self)
    }
    @MainActor private func read(_ roots: [URL]) async throws -> GitController {
        let controller = GitController(roots: roots.map(\.path))
        addTeardownBlock { @MainActor in controller.letGo(); GitController.statusReadDelay = .zero }
        controller.setShown(true)
        try await wait { controller.statusRead && !controller.loading }
        return controller
    }
    @MainActor private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < end else { XCTFail("The expected state never came", file: file, line: line); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor func testHidingDuringPublicationDoesNotRestartTheWatcherOrDiff() async throws {
        let root = try repository(), controller = try await read([root])
        try "new\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        var hidden = false, restarted = false
        let diff = controller.$diffLoading.sink { if hidden && $0 { restarted = true } }
        let watch = controller.$repository.dropFirst().sink { _ in hidden = true; controller.setShown(false) }
        defer { watch.cancel(); diff.cancel() }
        await controller.refresh()
        XCTAssertFalse(controller.isShown)
        XCTAssertFalse(controller.isWatching, "a stopped refresh cannot start a new watch after notifying observers")
        XCTAssertFalse(controller.diffLoading)
        XCTAssertFalse(restarted, "no new diff read starts after the observer hid the panel")
    }

    @MainActor func testSwitchingAgainDuringResetDoesNotRearmTheSupersededRepository() async throws {
        let first = try repository(), second = try repository(), third = try repository()
        let controller = try await read([first, second, third])
        XCTAssertNotNil(controller.selection)
        let watch = controller.$selection.dropFirst().sink { selection in
            if selection == nil { GitController.statusReadDelay = .seconds(2); controller.root = third.path }
        }
        defer { watch.cancel() }
        controller.root = second.path
        try await wait { controller.root == third.path }
        XCTAssertFalse(controller.accepts(controller.repositoryContext), "the superseded reset cannot give B a token for C's generation")
        await controller.stage(["same.txt"], context: controller.repositoryContext)
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"], in: second), "")
    }

    @MainActor func testSlowAndFailedSwitchesKeepTheSnapshotAndRejectItsActions() async throws {
        for failure in [false, true] {
            let first = try repository(), second = try repository(), controller = try await read([first, second])
            let snapshot = controller.repository, context = controller.repositoryContext
            GitController.statusReadDelay = .milliseconds(500)
            if failure { try Data("broken index".utf8).write(to: second.appendingPathComponent(".git/index")) }
            controller.root = second.path
            try await wait { controller.loading }
            XCTAssertEqual(controller.repository, snapshot)
            XCTAssertFalse(controller.accepts(context))
            await controller.stage(["same.txt"], context: context)
            try await wait { !controller.loading }
            if failure {
                XCTAssertEqual(controller.repository, snapshot)
                try FileManager.default.removeItem(at: second.appendingPathComponent(".git/index"))
                try git(["reset", "--mixed", "HEAD"], in: second)
            } else { XCTAssertEqual(controller.repositoryRoot, second.path) }
            await controller.discard(snapshot.status.entries, context: context)
            XCTAssertEqual(try git(["diff", "--cached", "--name-only"], in: first), "")
            XCTAssertEqual(try git(["diff", "--cached", "--name-only"], in: second), "")
            XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("same.txt"), encoding: .utf8), "changed\n")
            XCTAssertEqual(try String(contentsOf: second.appendingPathComponent("same.txt"), encoding: .utf8), "changed\n")
            controller.letGo(); GitController.statusReadDelay = .zero
        }
    }
}
