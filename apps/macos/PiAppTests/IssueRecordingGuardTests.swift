import ObjectiveC
import XCTest

/// IssueRecordingGuard.m records a failure that XCTest would drop because it
/// arrived while another was being recorded; scripts/tests runs that against
/// XCTest. This checks the guard is installed in this test process.
final class IssueRecordingGuardTests: XCTestCase {
    func testNestedIssueRecordingIsInstalled() {
        XCTAssertTrue(class_respondsToSelector(XCTestCase.self, NSSelectorFromString("belloTestIssueRecordingInstalled")),
                      "IssueRecordingGuard.m is not linked into PiAppTests")
    }
}
