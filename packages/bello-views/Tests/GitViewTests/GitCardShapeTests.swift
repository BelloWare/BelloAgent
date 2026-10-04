import XCTest
@testable import GitView

/// The diff's cards keep SwiftUI's continuous corners without SwiftUI: the
/// path `GitDiffMetrics.continuousRoundedRect` makes is the one
/// `RoundedRectangle(cornerRadius:style: .continuous)` made, point for point.
/// The expected points were read from SwiftUI's own path (macOS 14).
final class GitCardShapeTests: XCTestCase {
    private func points(_ path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            let count: Int
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            default: count = 0
            }
            for index in 0..<count { points.append(element.pointee.points[index]) }
        }
        return points
    }
    private func assertPrefix(_ rect: CGRect, radius: CGFloat, _ expected: [(CGFloat, CGFloat)], file: StaticString = #filePath, line: UInt = #line) {
        let got = points(GitDiffMetrics.continuousRoundedRect(rect, radius: radius))
        XCTAssertEqual(got.count, 41, "a move, four lines and twelve curves", file: file, line: line)
        for (index, (x, y)) in expected.enumerated() {
            XCTAssertEqual(got[index].x, x, accuracy: 0.0001, "point \(index) x", file: file, line: line)
            XCTAssertEqual(got[index].y, y, accuracy: 0.0001, "point \(index) y", file: file, line: line)
        }
    }

    func testAFullCornerReachesOnePointFiveThreeRadiiAlongEachSide() {
        assertPrefix(CGRect(x: 0, y: 0, width: 100, height: 100), radius: 10, [
            (100, 50), (100, 84.713351),
            (100, 89.115100), (100, 91.315930), (99.250886, 93.685060),
            (98.309400, 96.271760), (96.271760, 98.309400), (93.685060, 99.250886),
            (91.315930, 100), (89.115100, 100), (84.713351, 100),
            (15.286649, 100),
        ])
    }

    func testAShortSideEndsItsCornersAtItsMiddle() {
        assertPrefix(CGRect(x: 0, y: 0, width: 100, height: 24), radius: 10, [
            (100, 12), (100, 12),
            (100, 13.913908), (100, 15.616871), (99.250886, 17.685060),
        ])
    }

    func testASideShorterThanTwoRadiiTakesTheRadiusDown() {
        assertPrefix(CGRect(x: 0, y: 0, width: 100, height: 14), radius: 10, [
            (100, 7), (100, 7),
            (100, 7.28), (100, 8.26), (99.475620, 9.579542),
            (98.816580, 11.390232), (97.390232, 12.816580), (95.579542, 13.475620),
            (93.921151, 14), (92.380570, 14), (89.299345, 14),
        ])
    }
}
