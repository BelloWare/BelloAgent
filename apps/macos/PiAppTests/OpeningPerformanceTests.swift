import AppKit
import Darwin
import Darwin.libproc
import XCTest
@testable import PiApp

/// Opt-in generated journals, the actual supervisor's production 30-second
/// deadline, and a packaged Release helper. The external runner owns load
/// rejection and the shared full-lane lock.
final class OpeningPerformanceTests: XCTestCase, SerialTestLane {
    @MainActor func testProductionOpeningDeadlineAndCancellation() async throws {
        #if PI_RELEASE_TESTS
        guard let path = testEnvironment("PI_PERF_JOURNAL"), let root = testEnvironment("PI_PERF_ROOT") else {
            throw XCTSkip("Use a generated fixture under PI_BUILD_ROOT")
        }
        let journal = URL(fileURLWithPath: path), directory = journal.deletingLastPathComponent()
        XCTAssertTrue(path.hasPrefix(root + "/"))
        let mode = testEnvironment("PI_OPENING_PROBE") ?? "progress", cancel = mode == "cancel"
        let host = HostSupervisor(commandProgress: mode != "quiet")
        defer { host.shutdown() }
        try await host.connect(cwd: directory, state: directory.appendingPathComponent("app-state"))
        let pid = try XCTUnwrap(host.helperProcessIdentifier)
        if let pidfile = testEnvironment("PI_PERF_PID_FILE") {
            try JSONSerialization.data(withJSONObject: ["host":getpid(),"helper":pid]).write(to: URL(fileURLWithPath: pidfile))
        }
        _ = try await host.request("workspace.open", params: ["cwd":.string(directory.path),"directory":.string(directory.path),"mcp":.object(["servers":.object([:])])])
        let profile: WireValue = .object(["id":.string("fixture"),"revision":.string("1"),"providerId":.string("litellm"),"modelId":.string("fixture"),
            "api":.string("openai-responses"),"baseUrl":.string("http://127.0.0.1:1/v1"),"contextWindow":.number(100000),"maxOutputTokens":.number(4096),
            "reasoning":.bool(true),"thinkingLevel":.string("default"),"routing":.object(["replayPolicy":.string("portable")])])
        var observations: [[String:Double]] = [], cancelledAt: Double?
        let before = Self.usage(pid), start = ProcessInfo.processInfo.systemUptime
        var opening: Task<WireValue, Error>?
        opening = Task {
            try await host.request("session.open", sessionID: "long", params: ["profile":profile,"apiKey":.string("synthetic-only"),
                "path":.string(path),"connectionTest":.bool(true)], commandID: "measured-open") { work in
                let now = ProcessInfo.processInfo.systemUptime
                observations.append(["ms":(now-start)*1000,"completed":Double(work.completed),"total":Double(work.total)])
                if cancel, cancelledAt == nil, work.fraction >= 0.65 {
                    cancelledAt = now; opening?.cancel()
                }
            }
        }
        let result = await opening!.result
        if cancel {
            if case .failure(let error) = result { XCTAssertTrue(error is CancellationError) }
            else { XCTFail("The mid-replay cancellation succeeded") }
            XCTAssertNotNil(cancelledAt)
            await host.waitForCommandSettlement("measured-open")
            let descriptor = Darwin.open(path + ".lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            if descriptor >= 0 {
                XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0, "Reply follows worker unwind and writer-lock release")
                _ = flock(descriptor, LOCK_UN); _ = Darwin.close(descriptor)
            }
        } else { _ = try result.get() }
        let end = ProcessInfo.processInfo.systemUptime, after = Self.usage(pid)
        let record: [String:Any] = ["mode":mode,"wallMs":(end-start)*1000,"cpuSeconds":after.cpu-before.cpu,"peakMiB":after.peak,
            "cancelMs":cancelledAt.map { (end-$0)*1000 } ?? 0,"progress":observations,"productionDeadlineSeconds":30]
        print("OPENING136 " + String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self))
        if !cancel { _ = try await host.request("session.close", sessionID: "long") }
        try await host.shutdownAndWait()
        #else
        throw XCTSkip("Opening measurements require Release build-for-testing")
        #endif
    }

    private static func usage(_ pid: Int32) -> (cpu: Double, peak: Double) {
        var value = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return (0,0) }
        var base = mach_timebase_info_data_t(); mach_timebase_info(&base)
        return (Double(value.ri_user_time + value.ri_system_time) * Double(base.numer) / Double(base.denom) / 1e9,
                Double(value.ri_lifetime_max_phys_footprint) / 1_048_576)
    }
}
