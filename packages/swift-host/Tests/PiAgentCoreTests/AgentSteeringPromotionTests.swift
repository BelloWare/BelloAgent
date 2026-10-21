import XCTest
@testable import PiAgentCore

/// BUG-003 (review 2026-10-16): a parent in its final family wait sleeps on
/// the coordinator's wake signal (60 s by default). Steering it directly
/// wakes it; promoting a queued follow-up to steering must too. The child's
/// request is held for the whole check, so nothing else wakes the parent.
final class AgentSteeringPromotionTests: HelperTestCase {
    private func waitingParent(_ root: URL, _ client: AgentBoundaryClient, _ coordinator: AgentSteeringCoordinator) async throws -> AgentSession {
        let parent = try AgentSession(id:"parent",profile:fixtureProfile(),apiKey:"fixture",cwd:root,directory:root,readOnly:true,resources:Resources(cwd:root,home:root),client:client,tools:RecordingTools(),traces:TraceStore())
        await parent.enableSubagents(SubagentCoordinator()); await parent.enableAgentSteering(coordinator)
        _ = try await parent.submit(Submission(commandID:"command",turnID:"user",text:"Delegate then synthesize"),steer:false)
        try await eventually { let p = await client.parentCount, c = await client.childCount; return p >= 2 && c >= 1 }
        try await eventually { await parent.familyWaiting }
        // The wait is registered once the parent sleeps on the signal; give the
        // loop its turn so the steering arrives after it, not before.
        try await Task.sleep(for:.milliseconds(100))
        let count = await client.parentCount
        XCTAssertEqual(count, 2, "The parent sleeps in its final wait")
        return parent
    }
    private func assertWokeWith(_ text: String, _ client: AgentBoundaryClient, _ parent: AgentSession, _ coordinator: AgentSteeringCoordinator) async throws {
        try await eventually(timeout:.seconds(5)) { await client.parentCount >= 3 }
        let requests = await client.parentRequests, children = await client.childCount
        XCTAssertTrue(requests[2].contains { $0.text.contains(text) }, "The next parent request carries the steering")
        XCTAssertEqual(children, 1, "The child is still held: the steering, not the child, woke the parent")
        await client.release()
        try await eventually { !(await parent.isRunning) }
        await coordinator.drain(); await parent.close()
    }

    func testPromotingAQueuedMessageWakesAParentInItsFamilyWait() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AgentBoundaryClient(), coordinator = AgentSteeringCoordinator()
        let parent = try await waitingParent(root, client, coordinator)
        _ = try await parent.submit(Submission(commandID:"follow",turnID:"follow",text:"Promoted guidance"),steer:false)
        try await Task.sleep(for:.milliseconds(100))
        let queued = await client.parentCount
        XCTAssertEqual(queued, 2, "A follow-up waits for the run to end")
        try await parent.steerQueued("follow")
        try await assertWokeWith("Promoted guidance", client, parent, coordinator)
    }

    /// The control: direct steering already woke the parent.
    func testDirectSteeringWakesAParentInItsFamilyWait() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let client = AgentBoundaryClient(), coordinator = AgentSteeringCoordinator()
        let parent = try await waitingParent(root, client, coordinator)
        _ = try await parent.submit(Submission(commandID:"steer",turnID:"steer",text:"Direct guidance"),steer:true)
        try await assertWokeWith("Direct guidance", client, parent, coordinator)
    }
}
