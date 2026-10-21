import XCTest

final class IssueRecordingTests: ViewsTestCase {
    /// XCTest drops an issue that reaches it while it records another
    /// (ViewsTestCase says how), so every test class in this package derives
    /// from ViewsTestCase, which records both. SwiftPM links the three test
    /// targets into one bundle, so this checks them all, and fails if it
    /// stops finding one. scripts/tests runs the recording against XCTest.
    func testEveryTestClassRecordsIssuesThroughViewsTestCase() throws {
        let image = try XCTUnwrap(class_getImageName(IssueRecordingTests.self))
        var count: UInt32 = 0
        let names = try XCTUnwrap(objc_copyClassNamesForImage(image, &count))
        defer { free(names) }
        var targets = Set<String>(), outside: [String] = []
        for index in 0..<Int(count) {
            guard let type = objc_getClass(names[index]) as? AnyClass, type != ViewsTestCase.self else { continue }
            var ancestor: AnyClass? = class_getSuperclass(type), kept = false
            while let next = ancestor, next != XCTestCase.self {
                kept = kept || next == ViewsTestCase.self
                ancestor = class_getSuperclass(next)
            }
            guard ancestor != nil else { continue }
            let name = NSStringFromClass(type)
            targets.insert(String(name.prefix { $0 != "." }))
            if !kept { outside.append(name) }
        }
        XCTAssertEqual(targets, ["FileViewTests", "GitViewTests", "FileFinderTests"], "The test classes were not all found")
        XCTAssertEqual(outside, [], "Derive these from ViewsTestCase, or XCTest can drop their failures")
    }
}
