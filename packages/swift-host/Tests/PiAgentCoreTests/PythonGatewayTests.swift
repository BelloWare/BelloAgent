import Foundation
import XCTest
@testable import PiAgentCore

/// The fixture server every gateway test starts (`PythonGateway`) never
/// outlives a start that failed: a server that never reports its port, or
/// reports none, is stopped before the error reaches the test.
final class PythonGatewayTests: XCTestCase {
    /// Writes its pid, then does what `after` says, then idles.
    private func server(_ after: String) -> String {
        """
        import os, pathlib, sys, time
        root = pathlib.Path(sys.argv[1])
        (root / 'pid').write_text(str(os.getpid()))
        \(after)
        time.sleep(60)
        """
    }
    private func stopped(_ root: URL) throws -> Bool {
        let pid = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8)))
        return kill(pid, 0) == -1
    }

    func testAServerThatNeverReportsItsPortIsStopped() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await PythonGateway.start(source: server("pass"), root: root, readyTimeout: .milliseconds(800)); XCTFail("It never reported a port") }
        catch let error as AgentError { XCTAssertEqual(error.code, "fixture_not_ready") }
        XCTAssertTrue(try stopped(root), "the server is gone")
    }

    func testAServerThatReportsNoPortIsStopped() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await PythonGateway.start(source: server("(root / 'ready.json').write_text('{}')"), root: root); XCTFail("It reported no port") }
        catch let error as AgentError { XCTAssertEqual(error.code, "fixture_port") }
        XCTAssertTrue(try stopped(root), "the server is gone")
    }
}
