import Foundation

// The seams the suite drives, in one place: how a test reads an opt-in knob,
// where it writes its fixtures, and which budgets only a Release build is
// held to. The seams inside the app itself — `SidebarRowRenderCount`,
// `PiTextWidth.measuredCount`, `HistoryReader.decodedRecords`,
// `MetadataStore.decodedChats`, `PayloadArchive`'s statement counters,
// `TranscriptLayoutClock` — each sit under a "Test seams" heading beside the
// state they measure, and cost nothing when nothing reads them.

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
