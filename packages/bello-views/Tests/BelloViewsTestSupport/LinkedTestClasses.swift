import XCTest

/// The test classes linked into the bundle that holds a given test class,
/// read from the Objective-C runtime, for the guards checking that every test
/// class derives from ViewsTestCase.
///
/// SwiftPM links the package's test targets into one bundle, but Xcode builds
/// each into a bundle of its own and runs it alone, where a guard sees only
/// its own target. So each test target has a guard of its own, which checks
/// the classes linked beside it, and expects every target only where it
/// finds more than one.
public struct LinkedTestClasses {
    /// The package's test targets, which SwiftPM links into one bundle.
    public static let packageTargets: Set<String> = ["FileViewTests", "GitViewTests", "FileFinderTests"]

    /// The test targets whose test classes were found, by module name.
    public let targets: Set<String>
    /// The test classes that derive from XCTestCase but not ViewsTestCase.
    public let outside: [String]

    /// Reads the classes of the bundle that defines `testClass`.
    public init(beside testClass: AnyClass) throws {
        let image = try XCTUnwrap(class_getImageName(testClass))
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
        self.targets = targets
        self.outside = outside
    }
}
