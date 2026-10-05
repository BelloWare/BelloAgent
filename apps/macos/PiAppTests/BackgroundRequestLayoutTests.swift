import AppKit
import SwiftUI
import XCTest
@testable import PiApp

@MainActor private enum BackgroundRequestLayoutFixture {
    static let minute = Date(timeIntervalSince1970: 1_790_000_000)
    static var caption: String {
        var summary = BackgroundRequestSummary()
        summary.requests = 4; summary.failed = 1; summary.tokens = 232; summary.cost = 0.00125
        return BackgroundRequestsPage.caption(summary)
    }
    static func row(failed: Bool = false, timed: Bool = true) -> BackgroundRequestRow {
        BackgroundRequestRow(id: "same-request", kind: failed ? .suggestions : .titles, startedAt: minute,
            endedAt: timed ? minute.addingTimeInterval(1.5) : nil,
            status: failed ? .failed("The suggestion request did not complete: Provider rejected request 01234567-89ab-cdef-0123-456789abcdef") : .completed,
            result: "Fixture reply: Generate a concise session title, preferably 3–7 words and at most one line, that describes the work.",
            sourceID: nil, sourceTitle: nil, project: nil, connection: nil, model: nil, path: nil, totals: nil)
    }
    static func caption(in page: BackgroundRequestsPage) throws -> PiKit.TextLine {
        try XCTUnwrap(page.subviews.compactMap { $0 as? PiKit.TextLine }.first { $0.line.text.hasPrefix("Asked of the mini model") })
    }
    static func headline(in content: BackgroundRequestRowContent) throws -> PiKit.TextLine {
        let help = content.row.result ?? content.row.status.reason ?? ""
        return try XCTUnwrap(content.subviews.compactMap { $0 as? PiKit.TextLine }.first { $0.toolTip == help })
    }
}

/// Plain native geometry: no window or test-host focus is needed.
@MainActor final class BackgroundRequestLayoutTests: XCTestCase {
    func testHeaderKeepsItsSpacerAtBothResponsiveLayoutsWithoutReplacingViews() throws {
        let root = scratchRoot("background-header-layout")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let page = BackgroundRequestsPage(model: model)
        let caption = try BackgroundRequestLayoutFixture.caption(in: page)
        let tabs = try XCTUnwrap(page.subviews.compactMap { $0 as? PiKit.Tabs<BackgroundRequestFilter> }.first)
        let identities = page.subviews.map(ObjectIdentifier.init)
        caption.line.text = BackgroundRequestLayoutFixture.caption

        for width in [580.0, 640, 759, 760, 900, 1200, 640] {
            page.frame = CGRect(x: 0, y: 0, width: width, height: 700)
            page.layoutSubtreeIfNeeded()
            let edge = width < 760 ? width - PiSpacing.lg : tabs.frame.minX
            let minimum: CGFloat = width < 760 ? 20 : 32
            XCTAssertGreaterThanOrEqual(edge - caption.frame.maxX, minimum, "The title column leaves the original spacer and surrounding gaps at \(width) points")
            XCTAssertEqual(page.subviews.map(ObjectIdentifier.init), identities, "Responsive layout keeps the existing controls")
            XCTAssertEqual(caption.line.text, BackgroundRequestLayoutFixture.caption, "Truncation changes the drawn line, never the accessible text")
        }
    }

    func testLongHeadlineKeepsItsSpacerBeforeDurationOrStatusWhileUpdatingInPlace() throws {
        let content = BackgroundRequestRowContent(row: BackgroundRequestLayoutFixture.row(), minute: BackgroundRequestLayoutFixture.minute, openSource: {})
        let headline = try BackgroundRequestLayoutFixture.headline(in: content)
        let duration = try XCTUnwrap(content.subviews.compactMap { $0 as? PiKit.TextLine }.first { $0.toolTip == "From sent to answered" })
        let badge = try XCTUnwrap(content.subviews.compactMap { $0 as? PiKit.Badge }.first)
        let identities = content.subviews.map(ObjectIdentifier.init)
        for timed in [true, false, true] {
            content.update(row: BackgroundRequestLayoutFixture.row(timed: timed), minute: BackgroundRequestLayoutFixture.minute)
            for width in [360.0, 510, 680] {
                content.frame = CGRect(x: 0, y: 0, width: width, height: BackgroundRequestRowContent.height)
                content.layoutSubtreeIfNeeded()
                let next: NSView = timed ? duration : badge
                XCTAssertEqual(next.frame.minX - headline.frame.maxX, 24, accuracy: 0.01, "A clipped headline keeps both gaps and the minimum spacer")
                XCTAssertLessThan(headline.frame.width, headline.intrinsicContentSize.width, "The fixture must exercise truncation")
                XCTAssertEqual(content.subviews.map(ObjectIdentifier.init), identities, "Settling and resizing retain each row child")
            }
        }
    }
}

/// The changed truncation boundaries against the original SwiftUI stacks.
@MainActor final class BackgroundRequestLayoutParityTests: XCTestCase, SerialTestLane {
    override func setUp() async throws { PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws { PiKit.Motion.reducedOverride = nil }

    private func compare<V: View>(_ name: String, width: CGFloat, _ reference: V, _ native: NSView,
                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let result = try await PiKitParity.compare("background-\(name)-\(Int(width))-\(suffix)", appearance: appearance,
                swiftUI: reference.frame(width: width, alignment: .leading), appKit: native, width: width)
            print("BACKGROUNDPARITY " + result.description)
            XCTAssertEqual(result.swiftUIFit.height, result.appKitFit.height, accuracy: 0.5, result.description, file: file, line: line)
            XCTAssertLessThanOrEqual(Double(result.differing), Double(result.total) * MonitorParityTests.allowedShare, result.description, file: file, line: line)
            let strong = PiKitParity.difference(result.swiftUIImage, result.appKitImage, tolerance: MonitorParityTests.strongChannel).0
            XCTAssertLessThanOrEqual(Double(strong), Double(result.total) * MonitorParityTests.strongShare, "\(result.name): \(strong) strong pixels", file: file, line: line)
        }
    }

    func testCompactAndWideHeadersMatchTheirOriginalTruncation() async throws {
        let root = scratchRoot("background-header-parity")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        for width in [580.0, 640, 900] {
            let native = try HeaderCapture(model: model, width: width)
            try await compare("header", width: width, BackgroundRequestHeaderReference(caption: BackgroundRequestLayoutFixture.caption, compact: width < 760), native)
        }
    }

    func testClippedHeadlinesMatchWithAndWithoutDuration() async throws {
        for (name, row, width) in [
            ("title", BackgroundRequestLayoutFixture.row(), 465.0),
            ("failed", BackgroundRequestLayoutFixture.row(failed: true), 322.0),
            ("untimed", BackgroundRequestLayoutFixture.row(timed: false), 465.0),
        ] {
            let native = try HeadlineCapture(row: row, width: width)
            try await compare(name, width: width, BackgroundRequestHeadlineReference(row: row), native)
        }
    }

    /// Captures the actual page's existing header children. The temporary
    /// page stays off-window and releases its observer before the capture,
    /// so its queued initial publication cannot replace the fixed caption.
    private final class HeaderCapture: DashView {
        private let size: CGSize
        init(model: WorkspaceModel, width: CGFloat) throws {
            let page = BackgroundRequestsPage(model: model)
            page.frame = CGRect(x: 0, y: 0, width: width, height: 700)
            let caption = try BackgroundRequestLayoutFixture.caption(in: page)
            caption.line.text = BackgroundRequestLayoutFixture.caption
            page.layoutSubtreeIfNeeded()
            let rule = try XCTUnwrap(page.subviews.compactMap { $0 as? HairlineView }.first)
            let size = CGSize(width: width, height: rule.frame.maxY)
            self.size = size
            super.init(frame: CGRect(origin: .zero, size: size))
            for child in page.subviews where child === rule || child is PiKit.Button || child is PiKit.TextLine || child is PiKit.Tabs<BackgroundRequestFilter> {
                addSubview(child)
            }
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var intrinsicContentSize: NSSize { size }
    }

    /// Captures the production row's first-line children, without padding
    /// or the separate metadata line diluting the truncation comparison.
    private final class HeadlineCapture: DashView {
        private let content: BackgroundRequestRowContent
        private let size: CGSize
        init(row: BackgroundRequestRow, width: CGFloat) throws {
            let content = BackgroundRequestRowContent(row: row, minute: BackgroundRequestLayoutFixture.minute, openSource: {})
            content.frame = CGRect(x: 0, y: 0, width: width + 26 + PiSpacing.md, height: BackgroundRequestRowContent.height)
            content.layoutSubtreeIfNeeded()
            let headline = try BackgroundRequestLayoutFixture.headline(in: content)
            let children = content.subviews.filter { ($0 is PiKit.TextLine || $0 is PiKit.Badge) && !$0.isHidden }
            let size = CGSize(width: width, height: children.map { $0.frame.maxY }.max() ?? headline.frame.maxY)
            self.content = content; self.size = size
            super.init(frame: CGRect(origin: .zero, size: size))
            for child in children {
                child.frame.origin.x -= 26 + PiSpacing.md
                addSubview(child)
            }
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var intrinsicContentSize: NSSize { size }
    }
}
