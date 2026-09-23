import Foundation
@testable import PiApp

// The seams the suite drives, in one place: how a test reads an opt-in knob,
// where it writes its fixtures, which budgets only a Release build is held
// to, and how it waits out the transcript's idle work. The seams inside the
// app itself — `SidebarRowRenderCount`, `PiTextWidth.measuredCount`,
// `HistoryReader.decodedRecords`, `MetadataStore.decodedChats`,
// `PayloadArchive`'s statement counters, `TranscriptLayoutClock` — each sit
// under a "Test seams" heading beside the state they measure, and cost
// nothing when nothing reads them; `TranscriptPaging.residentCaps` and
// `TranscriptIdleScheduler.interval` hold the app's own values unless a
// fixture sets them.

/// One opt-in knob, read under both the names it can arrive as. xcodebuild
/// hands the test host `TEST_RUNNER_<NAME>` with the prefix kept, while the
/// scheme's own environment list sets the bare name, so every test reads
/// through here rather than reaching for `ProcessInfo` itself.
func testEnvironment(_ name: String) -> String? {
    let environment = ProcessInfo.processInfo.environment
    return environment[name] ?? environment["TEST_RUNNER_" + name]
}

/// Where a test writes its fixtures: the scratch root the run was given, else
/// the system temporary directory. A run that sets `PI_APP_SCRATCH_ROOT`
/// keeps every fixture on one volume it can clear afterwards.
func scratchBase() -> String { testEnvironment("PI_APP_SCRATCH_ROOT") ?? NSTemporaryDirectory() }

/// A test class that runs in the serial lane: alone, in one test host, with
/// nothing else on the machine (`scripts/test-lanes.py`; the rule is in
/// docs/Swift-Test-Handoff.md, "Test lanes"). Every other class runs in
/// parallel clones of the host. Most serial classes are found by what they
/// use — activation and key-window state, the standard defaults, the general
/// and drag pasteboards, an elapsed time inside an XCTAssert — and need no
/// marker. A class declares this when a timing assertion that holds in Debug
/// works through a variable the script cannot see, or when a count it
/// asserts depends on how fast the machine is.
protocol SerialTestLane {}

/// A fresh directory under `scratchBase()`, named after the test that asked
/// for it so a leftover says who left it.
func scratchRoot(_ name: String) -> URL {
    URL(fileURLWithPath: scratchBase()).appendingPathComponent(name + "-" + UUID().uuidString)
}

/// A budget in seconds that only a Release build is held to. Debug Swift is
/// ten to twenty times slower in the parts that are ours, and on a machine
/// running several builds at once an absolute millisecond count measures the
/// machine rather than the code. The shape assertions beside these — a cost
/// against one row's own layout, a cost against the same work on a shorter
/// page — hold in every configuration, which is what keeps a Debug run
/// meaningful without letting it flap.
func releaseBudget(_ seconds: Double) -> Double {
    // `PI_RELEASE_TESTS` is set on the test target's Release configuration
    // alone (project.yml); a Debug bundle, however it was built, is never
    // held to an absolute number.
    #if PI_RELEASE_TESTS
    return seconds
    #else
    return .greatestFiniteMagnitude
    #endif
}

/// Runs `body` with the transcript's optional idle work back to back instead
/// of one unit per frame. A long page comes up with its viewport exact and
/// measures the rest in those units; a fixture that waits for the last of
/// them, and then asserts on the page they leave, gets the same units in the
/// same order doing the same work, without a frame's pause after each one.
/// Not for a fixture whose subject is the pacing, or what the page does while
/// the units are still running.
@MainActor func unpacedIdleWork<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
    let paced = TranscriptIdleScheduler.interval
    TranscriptIdleScheduler.interval = 0
    defer { TranscriptIdleScheduler.interval = paced }
    return try await body()
}
