import XCTest
@testable import PiAgentCore

final class CheckpointRefreshPerformanceTests: HelperTestCase {
    func testTurnEndSchedulingCost() async throws {
        guard ProcessInfo.processInfo.environment["PI_CHECKPOINT_REFRESH_PERF"] == "1" else {
            throw XCTSkip("Set PI_CHECKPOINT_REFRESH_PERF=1 under the Release perf lane")
        }
        #if DEBUG
        throw XCTSkip("Release measurements only")
        #else
        let root = try temporaryDirectory(), profile = try fixtureProfile()
        defer { try? FileManager.default.removeItem(at:root) }
        let session = try AgentSession(id:"refresh", profile:profile, apiKey:"synthetic-only", cwd:root, directory:root,
            readOnly:true, resources:Resources(cwd:root, home:root), client:ScriptClient([]), tools:RecordingTools(), traces:TraceStore(), autoCompaction:false)
        try await session.prepareRefreshCostFixture()
        for enabled in [false, true, false, true] {
            let samples = await session.measureRefreshScheduling(enabled:enabled, count:500).sorted()
            let row: JSON = ["enabled":JSON(enabled), "count":JSON(samples.count), "medianMs":JSON(samples[samples.count / 2]),
                "p95Ms":JSON(samples[Int(Double(samples.count) * 0.95)]), "maxMs":JSON(samples.last!),
                "meanMs":JSON(samples.reduce(0,+) / Double(samples.count))]
            print("CHECKPOINT136 " + row.encoded())
        }
        await session.close()
        #endif
    }
}

private extension AgentSession {
    func prepareRefreshCostFixture() throws {
        try journal?.append(["type":"message", "message":ChatMessage(role:"assistant", content:[textBlock(String(repeating:"ordinary tool diagnostic\n", count:500_000))]).pi])
        try persistState(active:false, durable:true)
    }
    func measureRefreshScheduling(enabled: Bool, count: Int) async -> [Double] {
        checkpointRefreshPolicy.bytes = enabled ? 1 : .max
        checkpointRefreshPolicy.seconds = .infinity
        var samples: [Double] = []; samples.reserveCapacity(count)
        for _ in 0..<count {
            // The same fixed, flushed suffix is eligible each time. Only the
            // synchronous work added after persistState is timed. The worker
            // is cancelled and joined outside the measured interval.
            checkpointPublishedThrough = 0; checkpointRefreshAttemptedThrough = 0
            let start = DispatchTime.now().uptimeNanoseconds
            scheduleCheckpointRefresh()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            await stopCheckpointRefresh()
        }
        return samples
    }
}
