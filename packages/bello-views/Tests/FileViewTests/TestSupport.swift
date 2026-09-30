import Foundation
import XCTest

// What the package's tests share, standing alone: the apps' own test seams
// are not theirs to use.

/// A fresh directory for a test's files, under the run's scratch root if it
/// was given one (`PI_APP_SCRATCH_ROOT`, as the app's tests read it), else
/// the system's temporary directory, named after the test that asked for it
/// so a leftover says who left it.
func scratchRoot(_ name: String) -> URL {
    let environment = ProcessInfo.processInfo.environment
    let base = environment["PI_APP_SCRATCH_ROOT"] ?? environment["TEST_RUNNER_PI_APP_SCRATCH_ROOT"] ?? NSTemporaryDirectory()
    return URL(fileURLWithPath: base).appendingPathComponent(name + "-" + UUID().uuidString)
}

/// Why `eventually` stopped a test: the condition it named never held.
struct EventuallyTimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { what }
}

/// Waits on the main actor until `condition` holds, and fails the test with
/// `what` when it has not within `timeout`, read from a clock rather than
/// counted in polls. Having failed, it throws, so what follows does not run
/// against a state that never came.
@MainActor func eventually(_ what: String, timeout: Duration = .seconds(10), poll: Duration = .milliseconds(10),
                           file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
    let clock = ContinuousClock(), deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else {
            XCTFail(what, file: file, line: line)
            throw EventuallyTimedOut(what: what)
        }
        try await Task.sleep(for: poll)
    }
}
