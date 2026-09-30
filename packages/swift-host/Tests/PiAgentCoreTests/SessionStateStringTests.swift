import Foundation
import XCTest
@testable import PiAgentCore

/// A chat's run state is typed in the helper (`SessionState`, `RunStatus`,
/// `ToolRunState`) and written as the protocol's strings: in snapshots, in the
/// saved state record, and read back from it. The strings are literal here,
/// so a renamed case shows.
final class SessionStateStringTests: XCTestCase {
    func testTheStatesAreTheProtocolsStrings() {
        XCTAssertEqual([SessionState.idle, .running, .stopping, .paused, .error].map(\.rawValue), ["idle", "running", "stopping", "paused", "error"])
        XCTAssertEqual([RunStatus.idle, .running, .waitingTool, .retrying, .compacting, .failed, .cancelled].map(\.rawValue),
                       ["idle", "running", "waitingTool", "retrying", "compacting", "failed", "cancelled"])
        XCTAssertEqual([ToolRunState.completed, .failed, .cancelled].map(\.rawValue), ["completed", "failed", "cancelled"])
    }

    /// Every value reaches a snapshot's `state` and `runStatus`, and the saved
    /// record's `runStatus`, as the same string.
    func testSnapshotsAndTheSavedRecordNameEveryStateAsBefore() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(root)
        for (state, text) in [(SessionState.idle, "idle"), (.running, "running"), (.stopping, "stopping"), (.paused, "paused"), (.error, "error")] {
            await session.pin(state: state, runStatus: .idle)
            let snapshot = await session.snapshot(["includeMessages": false])
            XCTAssertEqual(snapshot["state"].text, text)
        }
        for (status, text) in [(RunStatus.idle, "idle"), (.running, "running"), (.waitingTool, "waitingTool"), (.retrying, "retrying"),
                               (.compacting, "compacting"), (.failed, "failed"), (.cancelled, "cancelled")] {
            await session.pin(state: .idle, runStatus: status)
            let snapshot = await session.snapshot(["includeMessages": false])
            XCTAssertEqual(snapshot["runStatus"].text, text)
            let saved = try await session.savedState()
            XCTAssertEqual(saved["runStatus"].text, text)
        }
        await session.pin(state: .idle, runStatus: .idle)
        await session.close()
    }

    /// Reopening: a run that was active when the helper went reads as
    /// interrupted; otherwise only a saved "failed" comes back as a failure,
    /// and any other saved status, known or not, is not restored.
    func testReopeningRestoresOnlyAFailureOrAnInterruptionAsBefore() async throws {
        func reopened(_ write: (AgentSession) async throws -> Void) async throws -> JSON {
            let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let session = try makeSession(root)
            try await write(session)
            let path = await session.path; await session.close()
            let again = try makeSession(root, resumePath: path)
            let snapshot = await again.snapshot(["includeMessages": false])
            await again.close()
            return snapshot
        }
        let failed = try await reopened { session in await session.pin(state: .error, runStatus: .failed, message: "Gateway said no."); try await session.saveState() }
        XCTAssertEqual(failed["state"].text, "error"); XCTAssertEqual(failed["runStatus"].text, "failed")
        XCTAssertEqual(failed["preflightError"].text, "Gateway said no.")

        let other = try await reopened { session in try await session.saveState(runStatus: "retrying") }
        XCTAssertEqual(other["state"].text, "idle"); XCTAssertEqual(other["runStatus"].text, "idle")
        let unknown = try await reopened { session in try await session.saveState(runStatus: "not-a-status") }
        XCTAssertEqual(unknown["state"].text, "idle"); XCTAssertEqual(unknown["runStatus"].text, "idle")

        let interrupted = try await reopened { session in await session.pin(state: .running, runStatus: .failed); try await session.saveState(active: true) }
        XCTAssertEqual(interrupted["state"].text, "paused", "an interrupted run pauses the queue")
        XCTAssertEqual(interrupted["runStatus"].text, "idle", "and is not restored as the failure it was not")
        XCTAssertEqual(interrupted["preflightError"].text, "The previous run was interrupted. No model or tool request was replayed. Inspect tool effects before continuing.")
    }

    private func makeSession(_ root: URL, resumePath: String? = nil) throws -> AgentSession {
        try AgentSession(id: "s", profile: fixtureProfile(), apiKey: "fixture", cwd: root, directory: root.appendingPathComponent("state"), readOnly: false,
                         resources: Resources(cwd: root, home: root), client: ScriptClient([]), tools: RecordingTools(), traces: TraceStore(),
                         resumePath: resumePath, autoCompaction: false)
    }
}

private extension AgentSession {
    func pin(state: SessionState, runStatus: RunStatus, message: String? = nil) {
        self.state = state; self.runStatus = runStatus; errorMessage = message
    }
    /// The state record as the session writes it, or with a `runStatus` of
    /// another helper's making.
    func saveState(active: Bool? = nil, runStatus text: String? = nil) throws {
        guard let text else { try persistState(active: active); return }
        var value = try savedState(active: active); value["runStatus"] = JSON(text)
        try journal?.append(["type": "custom", "customType": JSON(JournalRecordKind.state), "data": value], flush: true)
    }
}
