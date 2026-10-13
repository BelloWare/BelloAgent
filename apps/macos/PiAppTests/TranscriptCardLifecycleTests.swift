import AppKit
import XCTest
@testable import PiApp

/// These checks need an otherwise idle scheduler and window server: another
/// owner's wakeup would hide a missing lifecycle notification.
final class TranscriptCardLifecycleTests: XCTestCase, SerialTestLane {
    @MainActor private final class Canvas: NSView {
        override var isFlipped: Bool { true }
    }
    @MainActor private final class Stage {
        let card = TranscriptNativeDiffCard()
        let canvas = Canvas()
        let window: NSWindow
        var scroll: TranscriptCappedLines { LongChatScroll.views(TranscriptCappedLines.self, in: card).first! }
        var lines: TranscriptCardLines { scroll.lines }

        init() {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = canvas
            canvas.addSubview(card)
            replace(count: 400, prefix: "original")
            card.setExpanded(true)
            draw()
            window.orderFront(nil)
        }
        func replace(count: Int, prefix: String) {
            let rows = (0..<count).map { DiffRow(kind: .added, text: "\(prefix) \($0) " + String(repeating: "wrapped text ", count: 30)) }
            let request = TranscriptActivity.EditRequest(before: "", after: rows.map(\.text).joined(separator: "\n"), mode: "write", rows: rows,
                hiddenRows: 0, complete: true, tooLarge: false, lines: rows.count)
            card.update(.diff(request, path: "Fixture.txt", outcome: .done, added: count, removed: 0), link: nil, environment: .init())
        }
        func draw(width: CGFloat? = nil) {
            if let width { window.setContentSize(NSSize(width: width, height: 500)) }
            let width = canvas.bounds.width
            card.frame = NSRect(x: 0, y: 0, width: width, height: card.height(width: width))
            card.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        func close() { window.contentView = nil; window.close() }
    }

    @MainActor private func settled(_ stage: Stage, _ transition: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = stage.lines.unmeasuredLineCount
        defer { print("DIFF-LIFECYCLE \(transition) pending=\(before)->\(stage.lines.unmeasuredLineCount)") }
        try await unpacedIdleWork {
            // Reading a counter is deliberate. No draw, input, runReady(), or
            // visibilityChanged() here may rescue a sleeping job.
            try await eventually("Deferred geometry stalled after \(transition)", timeout: .seconds(5), file: file, line: line) {
                stage.lines.unmeasuredLineCount == 0
            }
        }
        let reference = TranscriptCardLines(style: .diff)
        reference.update(stage.lines.lines, environment: .init())
        XCTAssertEqual(stage.lines.frame.height, reference.height(width: stage.lines.bounds.width), accuracy: 0.5,
                       "Deferred geometry must equal synchronous geometry at the current width", file: file, line: line)
    }

    @MainActor func testAnIdleDiffResumesMeasurementAfterCollapseAndReopen() async throws {
        let stage = Stage(); defer { stage.close() }
        try await settled(stage, "initial expansion")
        stage.card.setExpanded(false); stage.draw()
        XCTAssertTrue(stage.scroll.isHidden)
        stage.card.setExpanded(true); stage.draw()
        XCTAssertFalse(stage.scroll.isHidden)
        XCTAssertGreaterThan(stage.lines.unmeasuredLineCount, 200)
        try await settled(stage, "collapse/reopen")
    }

    @MainActor func testHiddenAncestorsPauseAndUnhideResumesMeasurement() async throws {
        let stage = Stage(); defer { stage.close() }
        stage.canvas.isHidden = true
        let pending = stage.lines.unmeasuredLineCount
        XCTAssertGreaterThan(pending, 200)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(stage.lines.unmeasuredLineCount, pending, "Hidden descendants must not measure offscreen lines")
        stage.canvas.isHidden = false
        try await settled(stage, "ancestor unhide")
    }

    @MainActor func testReopeningAtNewWidthsFinishesTheCurrentGeometry() async throws {
        let stage = Stage(); defer { stage.close() }
        try await settled(stage, "initial width")
        for width: CGFloat in [380, 640, 420, 560, 520] {
            stage.card.setExpanded(false); stage.draw(width: width)
            stage.card.setExpanded(true); stage.draw()
            XCTAssertGreaterThan(stage.lines.unmeasuredLineCount, 200)
            try await settled(stage, "reopen at \(width)")
        }
    }

    @MainActor func testHiddenContentAndWidthChangesFinishAfterShowing() async throws {
        let stage = Stage(); defer { stage.close() }
        try await settled(stage, "before hidden replacement")
        stage.canvas.isHidden = true
        stage.replace(count: 300, prefix: "hidden-replacement"); stage.draw(width: 380)
        XCTAssertGreaterThan(stage.lines.unmeasuredLineCount, 200)
        stage.canvas.isHidden = false
        try await settled(stage, "hidden content and width replacement")
        XCTAssertTrue(stage.lines.lines.allSatisfy { $0.text.hasPrefix("hidden-replacement ") })
    }

    @MainActor func testFindTargetSurvivesTheRemainingIdleMeasurements() async throws {
        let stage = Stage(); defer { stage.close() }
        let target = 350
        let rect = try XCTUnwrap(stage.lines.revealLine(at: target))
        let text = try XCTUnwrap(stage.lines.builtText(at: target))
        let offset = rect.minY - stage.scroll.contentView.bounds.minY
        XCTAssertGreaterThan(stage.lines.unmeasuredLineCount, 200)
        try await settled(stage, "Find followed by idle measurement")
        XCTAssertEqual(try XCTUnwrap(stage.lines.lineRect(at: target)).minY - stage.scroll.contentView.bounds.minY, offset, accuracy: 0.5)
        XCTAssertTrue(stage.lines.builtText(at: target) === text)
        XCTAssertTrue(stage.scroll.contentView.bounds.contains(NSPoint(x: rect.midX, y: stage.scroll.contentView.bounds.minY + offset + 1)))
    }

    @MainActor func testResizeRetainsTheSelectedLineAndTheBottomDestination() async throws {
        let stage = Stage(); defer { stage.close() }
        let target = 200
        let rect = try XCTUnwrap(stage.lines.revealLine(at: target))
        stage.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: rect.minY + 3))
        let text = try XCTUnwrap(stage.lines.builtText(at: target))
        text.setSelectedRange(NSRange(location: 0, length: 4))
        let offset = try XCTUnwrap(stage.lines.lineRect(at: target)).minY - stage.scroll.contentView.bounds.minY
        for width: CGFloat in [380, 640, 420, 560, 520] {
            stage.draw(width: width)
            XCTAssertEqual(try XCTUnwrap(stage.lines.lineRect(at: target)).minY - stage.scroll.contentView.bounds.minY, offset, accuracy: 0.5)
            try await settled(stage, "selected line at \(width)")
            XCTAssertEqual(try XCTUnwrap(stage.lines.lineRect(at: target)).minY - stage.scroll.contentView.bounds.minY, offset, accuracy: 0.5)
            XCTAssertTrue(stage.lines.builtText(at: target) === text)
            XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 4))
        }
        text.setSelectedRange(NSRange(location: 0, length: 0))
        stage.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: stage.lines.frame.height - stage.scroll.contentView.bounds.height))
        for width: CGFloat in [380, 620] {
            stage.draw(width: width)
            XCTAssertEqual(stage.lines.frame.maxY, stage.scroll.contentView.bounds.maxY, accuracy: 0.5)
            try await settled(stage, "bottom at \(width)")
            XCTAssertEqual(stage.lines.frame.maxY, stage.scroll.contentView.bounds.maxY, accuracy: 0.5)
        }
    }

    @MainActor func testDetachedDiffStopsAndResumesWhenReattachedAtANewWidth() async throws {
        let stage = Stage(); defer { stage.close() }
        let lines = stage.lines
        XCTAssertGreaterThan(lines.unmeasuredLineCount, 200)
        stage.card.removeFromSuperview()
        XCTAssertNil(lines.window)
        let pending = lines.unmeasuredLineCount
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(lines.unmeasuredLineCount, pending, "Removed views must have no active measurement")
        stage.canvas.addSubview(stage.card); stage.draw(width: 380)
        XCTAssertTrue(stage.lines === lines)
        try await settled(stage, "reattach at new width")
    }

    @MainActor func testMovingADiffFromAHiddenWindowResumesInAnExistingVisibleWindow() async throws {
        let source = Stage(); defer { source.close() }
        source.window.orderOut(nil)
        let destination = Stage(); defer { destination.close() }
        try await settled(destination, "destination before moving")
        destination.card.removeFromSuperview()
        XCTAssertGreaterThan(source.lines.unmeasuredLineCount, 200)
        destination.canvas.addSubview(source.card)
        source.card.layoutSubtreeIfNeeded()
        destination.window.displayIfNeeded()
        XCTAssertTrue(source.lines.window === destination.window)
        try await settled(source, "direct move from hidden window")
    }

    @MainActor func testReusingADiffDuringPendingWorkMeasuresOnlyItsCurrentRows() async throws {
        let stage = Stage(); defer { stage.close() }
        XCTAssertGreaterThan(stage.lines.unmeasuredLineCount, 200)
        for count in [37, 0, 240] {
            stage.replace(count: count, prefix: "replacement-\(count)"); stage.draw()
            XCTAssertEqual(stage.lines.lines.count, count)
            XCTAssertTrue(stage.lines.lines.allSatisfy { $0.text.hasPrefix("replacement-\(count) ") })
        }
        try await settled(stage, "replacement during pending work")
        XCTAssertTrue(stage.lines.builtTexts.allSatisfy { $0.string.hasPrefix("replacement-240 ") })
        stage.replace(count: 300, prefix: "after-completion"); stage.draw()
        try await settled(stage, "replacement after completion")
        XCTAssertTrue(stage.lines.lines.allSatisfy { $0.text.hasPrefix("after-completion ") })
    }

    @MainActor func testOrderingTheWindowOutAndBackResumesMeasurement() async throws {
        let stage = Stage(); defer { stage.close() }
        stage.window.orderOut(nil)
        let pending = stage.lines.unmeasuredLineCount
        XCTAssertGreaterThan(pending, 200)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(stage.lines.unmeasuredLineCount, pending)
        stage.window.orderFront(nil)
        try await settled(stage, "window shown again")
    }

    @MainActor func testPendingWorkDoesNotRetainADiscardedDiff() async throws {
        weak var lines: TranscriptCardLines?
        autoreleasepool {
            let stage = Stage()
            lines = stage.lines
            XCTAssertGreaterThan(stage.lines.unmeasuredLineCount, 200)
            stage.close()
        }
        try await eventually("A discarded diff was retained by deferred measurement") { lines == nil }
    }
}
