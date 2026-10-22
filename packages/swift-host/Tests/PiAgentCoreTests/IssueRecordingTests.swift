import XCTest

#if canImport(Darwin)
final class IssueRecordingTests: HelperTestCase {
    /// XCTest drops an issue that reaches it while it records another
    /// (HelperTestCase says how), so every test class here derives from
    /// HelperTestCase, which records both. scripts/tests runs the recording
    /// itself against XCTest.
    func testEveryTestClassRecordsIssuesThroughHelperTestCase() throws {
        let image = try XCTUnwrap(class_getImageName(HelperTestCase.self))
        var count: UInt32 = 0
        let names = try XCTUnwrap(objc_copyClassNamesForImage(image, &count))
        defer { free(names) }
        var tests = 0, outside: [String] = []
        for index in 0..<Int(count) {
            guard let type = objc_getClass(names[index]) as? AnyClass, type != HelperTestCase.self else { continue }
            var ancestor: AnyClass? = class_getSuperclass(type), kept = false
            while let next = ancestor, next != XCTestCase.self {
                kept = kept || next == HelperTestCase.self
                ancestor = class_getSuperclass(next)
            }
            guard ancestor != nil else { continue }
            tests += 1
            if !kept { outside.append(NSStringFromClass(type)) }
        }
        XCTAssertGreaterThan(tests, 100, "The test classes were not found")
        XCTAssertEqual(outside, [], "Derive these from HelperTestCase, or XCTest can drop their failures")
    }
}
#endif
