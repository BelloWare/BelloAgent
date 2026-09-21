import XCTest
import SwiftUI
@testable import PiApp

/// Exercise the actual AppKit clip view after the transcript has loaded. These
/// are CPU/layout/display timings, not a claim about display refresh rate or
/// physical trackpad delivery on the remote machine's inactive desktop.
final class NativeTranscriptScrollingPerformanceTests: XCTestCase {
    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    private static func section(_ index: Int) -> String {
        """
        ## Result \(index)

        A long reply needs **readable paragraphs**, `inlineCode`, and [a reference](https://example.com/\(index)). The transcript must keep this complete content selectable while the reader scrolls through earlier findings and returns to this section.

        - First finding with enough explanation to wrap naturally at the viewport width.
        - Second finding with **emphasis** and additional context.

        ```swift
        let result\(index) = analyze(input: \(index))
        if result\(index).isValid { print("complete") }
        ```

        | Check | Result |
        | --- | --- |
        | Input \(index) | Passed |
        | Output | Preserved |
        """
    }

    @MainActor func testScrollAThreeHundredRowRichHistory() async throws {
        let messages = (0..<300).map { index in
            TranscriptMessage(id: "m\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant",
                              text: index.isMultiple(of: 2) ? "Please inspect result \(index) and explain the findings in detail." : Self.section(index),
                              turn: "m\(index - index % 2)")
        }
        try await measureScrolling(messages: messages, label: "300 rich rows")
    }

    @MainActor func testScrollOneVeryLongMarkdownAnswer() async throws {
        let answer = (0..<160).map(Self.section).joined(separator: "\n\n")
        XCTAssertGreaterThan(answer.utf8.count, 90_000, "This fixture exercises one genuinely large rendered message, not only many small rows")
        let messages = [TranscriptMessage(id: "question", role: "user", text: "Give a complete report.", turn: "question"),
                        TranscriptMessage(id: "answer", role: "assistant", text: answer, turn: "question")]
        try await measureScrolling(messages: messages, label: "single \(answer.utf8.count / 1024) KB Markdown answer")
    }

    @MainActor private func nextMainTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    @MainActor private func waitForTranscript(_ hosted: NSView, window: NSWindow, lastID: String, label: String) async throws -> Bool {
        let began = ProcessInfo.processInfo.systemUptime, deadline = began + 60
        var nextDiagnostic = began + 1
        while ProcessInfo.processInfo.systemUptime < deadline {
            let layoutStarted = ProcessInfo.processInfo.systemUptime
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if let marker = descendants(TranscriptSurfaceMarker.self, in: hosted).first,
               let page = marker.page, let scroll = marker.enclosingScrollView,
               (page.rowFrame(of: lastID) ?? page.rowFrame(of: "block:" + lastID)) != nil,
               (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height * 4 { return true }
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextDiagnostic {
                let marker = descendants(TranscriptSurfaceMarker.self, in: hosted).first
                let page = marker?.page, scroll = marker?.enclosingScrollView
                print(String(format: "SCROLL SETUP %@ after %.2f ms, last layout %.2f ms: marker=%@ page=%@ row=%@ document=%@ viewport=%@ items=%@", label, (now - began) * 1000, (now - layoutStarted) * 1000,
                             marker == nil ? "missing" : "attached", page == nil ? "missing" : "attached",
                             String(describing: page?.rowFrame(of: lastID) ?? page?.rowFrame(of: "block:" + lastID)),
                             String(describing: scroll?.documentView?.frame.size), String(describing: scroll?.contentView.bounds.size),
                             String(describing: page?.snapshot?.items.suffix(2).map(\.id))))
                nextDiagnostic = now + 15
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The real transcript never produced complete row geometry")
        return false
    }

    @MainActor private func viewCounts(in view: NSView) -> (all: Int, selectable: Int) {
        var count = 1, selectable = (view as? NSTextField).map { $0.isSelectable ? 1 : 0 }
            ?? (view as? NSTextView).map { $0.isSelectable ? 1 : 0 } ?? 0
        for child in view.subviews {
            let children = viewCounts(in: child)
            count += children.all; selectable += children.selectable
        }
        return (count, selectable)
    }

    @MainActor private func measureScrolling(messages: [TranscriptMessage], label: String) async throws {
        let session = SessionDisplay(id: "scroll-benchmark-\(messages.count)")
        session.messages = messages
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: NativeTranscriptView(session: session, actions: TranscriptActions()))
        window.contentView = hosted
        defer { window.contentView = nil; window.close() }
        let openedAt = ProcessInfo.processInfo.systemUptime
        window.makeKeyAndOrderFront(nil)
        let initiallyReady = try await waitForTranscript(hosted, window: window, lastID: try XCTUnwrap(messages.last?.id), label: label)
        print(String(format: "SCROLL PERF %@ open %@: %.2f ms", label, initiallyReady ? "complete geometry" : "TIMED OUT awaiting complete geometry", (ProcessInfo.processInfo.systemUptime - openedAt) * 1000))
        // Allow the first native text layouts' deferred invalidations to settle
        // before measuring scrolling of already loaded, unchanged content.
        try await Task.sleep(for: .milliseconds(100))
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let marker = try XCTUnwrap(descendants(TranscriptSurfaceMarker.self, in: hosted).first)
        let scroll = try XCTUnwrap(marker.enclosingScrollView), page = try XCTUnwrap(marker.page)
        let document = try XCTUnwrap(scroll.documentView)
        // A long chat comes up with its viewport exact and measures the rest
        // in idle slices. This measures scrolling through content that is
        // already loaded, so it waits for the last slice first.
        let exactBy = ProcessInfo.processInfo.systemUptime + 120
        while let native = document as? TranscriptNativeDocument, native.approximateRowCount > 0,
              ProcessInfo.processInfo.systemUptime < exactBy {
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual((document as? TranscriptNativeDocument)?.approximateRowCount ?? 0, 0,
                       "\(label): the page never finished measuring itself")
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        XCTAssertTrue(document.isFlipped, "Positions in this fixture use the transcript's top-down AppKit coordinates")
        let documentHeight = document.frame.height
        let bottom = documentHeight - scroll.contentView.bounds.height
        XCTAssertGreaterThan(bottom, 4_000)

        @MainActor func step(to requested: CGFloat) async -> (total: Double, sync: Double, prepared: Int) {
            let start = ProcessInfo.processInfo.systemUptime
            let provisionalBefore = descendants(NativeMarkdownContainer.self, in: hosted).reduce(0) { $0 + $1.provisionalBlockCount }
            page.readerWillNavigate(upward: requested < scroll.contentView.bounds.minY)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: requested))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            var synchronous = ProcessInfo.processInfo.systemUptime - start
            await nextMainTurn()
            let resumedAt = ProcessInfo.processInfo.systemUptime
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            synchronous += ProcessInfo.processInfo.systemUptime - resumedAt
            let provisionalAfter = descendants(NativeMarkdownContainer.self, in: hosted).reduce(0) { $0 + $1.provisionalBlockCount }
            return ((ProcessInfo.processInfo.systemUptime - start) * 1000, synchronous * 1000,
                    max(0, provisionalBefore - provisionalAfter))
        }

        // Both directions and widely separated positions warm the same exact
        // layout. This must not turn into a test of only the initially visible row.
        for fraction in [0.25, 0.5, 0.75, 0.95, 0.5, 0.05] { _ = await step(to: bottom * fraction) }
        // A row can have exact outer geometry while its large Markdown
        // surface still has provisional inner blocks. Warm the actual measured
        // traversal, not just six isolated destinations. Cold preparation is
        // allowed to correct estimates; steady scrolling must reuse exact text.
        let warmStart = ProcessInfo.processInfo.systemUptime
        var prepared = 0, warmPasses = 0
        repeat {
            prepared = 0; warmPasses += 1
            for fraction in [0.08, 0.45, 0.83] {
                let start = min(bottom - 4_000, max(0, bottom * fraction))
                for index in 0..<40 {
                    let displacement = CGFloat(index < 20 ? index : 39 - index) * 96
                    prepared += await step(to: min(bottom, max(0, start + displacement))).prepared
                }
            }
            // Estimates can expose an additional edge block on the return
            // pass. Require convergence before claiming this is a steady-layout
            // benchmark. Cold preparation's source stability has separate,
            // draw-time assertions in StableReadingTests.
        } while prepared > 0 && warmPasses < 5
        XCTAssertEqual(prepared, 0, "The measured traversal must have finished provisional preparation")
        print(String(format: "SCROLL PREPARE %@ actual-traversal %d passes, %.3f ms", label, warmPasses,
                     (ProcessInfo.processInfo.systemUptime - warmStart) * 1000))
        let rowsBefore = (document as? TranscriptNativeDocument)?.retainedRows ?? descendants(TranscriptRowContainer.self, in: hosted)
        let measurementsBefore = Dictionary(uniqueKeysWithValues: rowsBefore.map { ($0.itemID, $0.measurementCount) })
        let validationsBefore = rowsBefore.reduce(0) { $0 + $1.intrinsicValidationCount }
        let ids = [messages.first!.id, messages[messages.count / 2].id, messages.last!.id]
        let anchors = try ids.map { id -> (String, CGRect) in
            let key = page.rowFrame(of: id) != nil ? id : "block:" + id
            return (key, try XCTUnwrap(page.rowFrame(of: key)))
        }
        let viewsBefore = viewCounts(in: hosted)
        TranscriptLayoutClock.reset(); TranscriptLayoutClock.recording = true
        defer { TranscriptLayoutClock.recording = false }
        var times: [Double] = [], synchronousTimes: [Double] = []
        // Three smooth 40-step traversals in different parts of the document.
        // 96-point increments are closer to actual continuous scrolling than a
        // series of full-document jumps. The backward passes test both directions.
        for startFraction in [0.08, 0.45, 0.83] {
            let start = min(bottom - 4_000, max(0, bottom * startFraction))
            for index in 0..<40 {
                let displacement = CGFloat(index < 20 ? index : 39 - index) * 96
                let target = min(bottom, max(0, start + displacement))
                let time = await step(to: target)
                times.append(time.total); synchronousTimes.append(time.sync)
                XCTAssertEqual(time.prepared, 0, "Steady scrolling must not still be measuring provisional blocks")
                XCTAssertEqual(scroll.contentView.bounds.origin.y, target, accuracy: 0.5, "Scrolling unchanged content must land where the reader moved")
                XCTAssertEqual(document.frame.height, documentHeight, accuracy: 0.5, "Scrolling must not change the height of already loaded content")
            }
            XCTAssertEqual(scroll.contentView.bounds.origin.y, start, accuracy: 0.5, "A down/up traversal returns to the exact same reading position")
        }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        await nextMainTurn()
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        for (id, frame) in anchors {
            XCTAssertEqual(try XCTUnwrap(page.rowFrame(of: id)), frame, "The exact position of settled row \(id) must survive scrolling")
        }
        let rowsAfter = (document as? TranscriptNativeDocument)?.retainedRows ?? descendants(TranscriptRowContainer.self, in: hosted)
        var remeasurements = 0
        for row in rowsAfter {
            if let before = measurementsBefore[row.itemID] {
                remeasurements += max(0, row.measurementCount - before)
                XCTAssertEqual(row.measurementCount, before, "Pure scrolling must reuse the unchanged content's exact row layout: \(row.itemID)")
            }
        }
        let viewsAfter = viewCounts(in: hosted), ordered = times.sorted()
        XCTAssertLessThan(viewsBefore.all, 2_000, "Loaded history must not mount every offscreen native text field")
        XCTAssertLessThan(viewsAfter.all, 2_000, "Scrolling into another region must keep the native view tree bounded")
        let p95 = ordered[Int(Double(ordered.count - 1) * 0.95)]
        print(String(format: "SCROLL PERCENTILES %@ p50=%.3f p95=%.3f p99=%.3f maxSync=%.3f ms", label,
                     ordered[Int(Double(ordered.count - 1) * 0.50)], p95,
                     ordered[Int(Double(ordered.count - 1) * 0.99)], synchronousTimes.max() ?? 0))
        print(String(format: "SCROLL PHASES %@ mount=%.2f build=%.2f placement=%.2f validation=%.2f rowSizing=%.2f markdownUpdate=%.2f markdownLayout=%.2f viewportLayout=%.2f release=%.2f attach=%.2f detach=%.2f ms; builds=%d mounts=%d sizing=%d", label,
                     TranscriptLayoutClock.mountSeconds * 1000, TranscriptLayoutClock.hostBuildSeconds * 1000,
                     TranscriptLayoutClock.placementSeconds * 1000, TranscriptLayoutClock.validationSeconds * 1000,
                     TranscriptLayoutClock.rowSizingSeconds * 1000, TranscriptLayoutClock.markdownUpdateSeconds * 1000,
                     TranscriptLayoutClock.markdownLayoutSeconds * 1000, TranscriptLayoutClock.viewportLayoutSeconds * 1000,
                     TranscriptLayoutClock.hostReleaseSeconds * 1000, TranscriptLayoutClock.rowAttachmentSeconds * 1000,
                     TranscriptLayoutClock.rowDetachmentSeconds * 1000, TranscriptLayoutClock.hostBuilds,
                     TranscriptLayoutClock.mountedRows, TranscriptLayoutClock.rowSizingPasses))
        let validations = rowsAfter.reduce(0) { $0 + $1.intrinsicValidationCount } - validationsBefore
        print(String(format: "SCROLL PERF %@: %d steps, total mean %.3f ms, p95 %.3f ms, max %.3f ms; synchronous mean %.3f ms; exact-width cache misses %d; intrinsic validations %d; NSViews %d -> %d; selectable fields %d -> %d; row hosts %d -> %d; document %.0f pt", label, times.count, times.reduce(0, +) / Double(times.count), p95, ordered.last ?? 0, synchronousTimes.reduce(0, +) / Double(synchronousTimes.count), remeasurements, validations, viewsBefore.all, viewsAfter.all, viewsBefore.selectable, viewsAfter.selectable, rowsBefore.count, rowsAfter.count, documentHeight))
    }
}
