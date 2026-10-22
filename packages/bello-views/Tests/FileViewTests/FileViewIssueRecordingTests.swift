import XCTest
import BelloViewsTestSupport

final class FileViewIssueRecordingTests: ViewsTestCase {
    /// XCTest drops an issue that reaches it while it records another
    /// (ViewsTestCase says how), so every test class in this package derives
    /// from ViewsTestCase, which records both. Xcode runs each test target as
    /// a bundle of its own, so each checks the classes linked beside it
    /// (LinkedTestClasses says how), and fails if it stops finding its own.
    /// scripts/tests runs the recording against XCTest.
    func testEveryTestClassRecordsIssuesThroughViewsTestCase() throws {
        let linked = try LinkedTestClasses(beside: FileViewIssueRecordingTests.self)
        XCTAssertTrue(linked.targets.contains("FileViewTests"), "FileViewTests' test classes were not found")
        if linked.targets.count > 1 {
            XCTAssertEqual(linked.targets, LinkedTestClasses.packageTargets, "A test target is not linked here, or not listed in packageTargets")
        }
        XCTAssertEqual(linked.outside, [], "Derive these from ViewsTestCase, or XCTest can drop their failures")
    }
}
