import XCTest
import Darwin
@testable import PiApp

/// A process source's exit event can fire before the kernel lets the child be
/// reaped, and it fires once. A terminal that gave up on the first "not yet"
/// never reported the exit: the shell, and any tool waiting on it, stayed
/// running for ever.
final class PseudoTerminalReapTests: XCTestCase {
    @MainActor private func refusedDirectory(_ directory: URL) async throws {
        let process = PseudoTerminal()
        defer { PseudoTerminal.endForQuit([process]) }
        XCTAssertThrowsError(try process.start(executable: "/bin/sh", arguments: ["sh", "-c", "printf WRONG_FOLDER"],
                                              environment: ["PATH": "/usr/bin:/bin"], directory: directory.path, columns: 40, rows: 10)) {
            XCTAssertTrue($0.localizedDescription.contains(directory.path), $0.localizedDescription)
        }
        XCTAssertFalse(process.running, "Failure to enter the requested folder is a launch failure")
        PseudoTerminal.endForQuit([process])
        try await eventually("the failed launch leaves no live child") { !process.running }
    }

    @MainActor func testMissingWorkingDirectoryFailsLaunch() async throws {
        try await refusedDirectory(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-terminal-" + UUID().uuidString))
    }

    @MainActor func testWorkingDirectoryWithoutSearchPermissionFailsLaunch() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Root can enter a mode-000 folder") }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("denied-terminal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { chmod(directory.path, 0o700); try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(chmod(directory.path, 0), 0)
        try await refusedDirectory(directory)
    }

    @MainActor func testExecFailureAndAProgramExiting127RemainDistinct() async throws {
        let process = PseudoTerminal(), missing = NSTemporaryDirectory() + "/no-executable-" + UUID().uuidString
        defer { PseudoTerminal.endForQuit([process]) }
        XCTAssertThrowsError(try process.start(executable: missing, arguments: [missing], environment: [:],
                                              directory: NSTemporaryDirectory(), columns: 40, rows: 10))
        XCTAssertFalse(process.running)
        var exit: Int32?
        process.onExit = { exit = $0 }
        try process.start(executable: "/bin/sh", arguments: ["sh", "-c", "exit 127"], environment: ["PATH": "/usr/bin:/bin"],
                          directory: NSTemporaryDirectory(), columns: 40, rows: 10)
        try await eventually("the executed program reports its own exit") { exit != nil }
        XCTAssertEqual(exit, 127)
    }

    @MainActor private func run(notYet: Int) async throws -> (exits: [Int32], asked: Int, running: Bool) {
        let process = PseudoTerminal()
        var asked = 0, exits: [Int32] = []
        process.reap = { pid, status in
            asked += 1
            return asked <= notYet ? 0 : PseudoTerminal.reapNow(pid, status)
        }
        process.onExit = { exits.append($0) }
        try process.start(executable: "/bin/sh", arguments: ["sh", "-c", "exit 3"], environment: ["PATH": "/usr/bin:/bin"],
                          directory: NSTemporaryDirectory(), columns: 40, rows: 10)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, exits.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        return (exits, asked, process.running)
    }

    /// The first answer is "not yet": the terminal asks again and reports the
    /// child's own exit code, once.
    @MainActor func testAnExitReportedBeforeTheChildCanBeReapedStillEnds() async throws {
        let result = try await run(notYet: 1)
        XCTAssertEqual(result.exits, [3], "The exit is reported with the child's own code, once")
        XCTAssertFalse(result.running)
        XCTAssertEqual(result.asked, 2)
    }

    /// Every quick retry is too early: the terminal waits for the child off
    /// the main thread, then reaps it on the main actor and reports the exit.
    @MainActor func testAChildThatStaysUnreapableThroughTheRetriesIsStillReported() async throws {
        let result = try await run(notYet: PseudoTerminal.reapBackoff.count + 1)
        XCTAssertEqual(result.exits, [3], "The exit is reported after the retries run out")
        XCTAssertFalse(result.running)
        XCTAssertEqual(result.asked, PseudoTerminal.reapBackoff.count + 2)
    }
}
