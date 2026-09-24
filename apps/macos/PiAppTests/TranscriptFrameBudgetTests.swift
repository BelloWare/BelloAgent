import XCTest
import SwiftUI
import Darwin
import Darwin.libproc
@testable import PiApp

/// The conversation page exactly as the app builds it — the real
/// `NativeTranscriptView` inside a hosting view inside a window — driven one
/// frame at a time. Every frame is split into its parts (the model update, the
/// SwiftUI/AppKit layout pass, the document's own reconciliation, measurement
/// and layout inside it, and the display pass) so a number can be explained
/// rather than merely quoted.
///
/// The numbers are printed as PERF lines and the ceilings are the targets the
/// pane is held to. Release is the configuration that counts; a Debug run of
/// the same code is ten to twenty times slower in the Swift parts, which is
/// why the ceilings here only fail on the shapes that are framework-bound or
/// grossly out of budget.
final class TranscriptFrameBudgetTests: XCTestCase {

    // MARK: A frame and its parts

    struct Frame {
        /// Applying the change to the session and publishing the snapshot.
        var model = 0.0
        /// SwiftUI's update plus AppKit's layout of the whole pane.
        var layout = 0.0
        /// The window's display pass.
        var display = 0.0
        /// Inside `layout`: the document reconciling rows against the snapshot.
        var documentUpdate = 0.0
        /// Inside `layout`: the document placing the rows.
        var documentLayout = 0.0
        /// Inside the document's layout: native measurement of row hosts.
        var measure = 0.0
        var measuredRows = 0
        var mountedRows = 0
        var total: Double { model + layout + display }
        var line: String {
            String(format: "total %.1f ms (model %.1f, swiftui+appkit %.1f [document update %.1f, document layout %.1f, measuring %d rows %.1f], display %.1f, mounted %d)",
                   total * 1000, model * 1000, layout * 1000, documentUpdate * 1000, documentLayout * 1000,
                   measuredRows, measure * 1000, display * 1000, mountedRows)
        }
        static func + (a: Frame, b: Frame) -> Frame {
            Frame(model: a.model + b.model, layout: a.layout + b.layout, display: a.display + b.display,
                  documentUpdate: a.documentUpdate + b.documentUpdate, documentLayout: a.documentLayout + b.documentLayout,
                  measure: a.measure + b.measure, measuredRows: a.measuredRows + b.measuredRows,
                  mountedRows: a.mountedRows + b.mountedRows)
        }
        func scaled(by factor: Double) -> Frame {
            Frame(model: model * factor, layout: layout * factor, display: display * factor,
                  documentUpdate: documentUpdate * factor, documentLayout: documentLayout * factor,
                  measure: measure * factor, measuredRows: measuredRows, mountedRows: mountedRows)
        }
    }

    /// The pane the app puts on screen. Nothing here is a stand-in: the view
    /// under test is `NativeTranscriptView`, hosted the way `ConversationPane`
    /// hosts it, in a real key window of the real size.
    @MainActor final class Pane {
        let window: NSWindow
        let hosted: NSHostingView<NativeTranscriptView>
        let session: SessionDisplay

        init(_ session: SessionDisplay, state: String = "idle", width: CGFloat = 900, height: CGFloat = 700,
             onReady: @escaping (String, UUID) -> Void = { _, _ in }, onEarlier: @escaping (String) -> Void = { _ in }) {
            self.session = session
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            hosted = NSHostingView(rootView: NativeTranscriptView(session: session, state: state, actions: TranscriptActions(), onLoadEarlier: onEarlier, onViewportReady: onReady))
            window.contentView = hosted
            window.makeKeyAndOrderFront(nil)
        }
        func close() { window.contentView = nil; window.close() }

        func descendants<T: NSView>(_ type: T.Type, in view: NSView? = nil) -> [T] {
            let root = view ?? hosted
            return (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants(type, in: $0) }
        }
        var marker: TranscriptSurfaceMarker? { descendants(TranscriptSurfaceMarker.self).first }
        var page: TranscriptPage? { marker?.page }
        var scroll: NSScrollView? { marker?.enclosingScrollView }
        var document: TranscriptNativeDocument? { scroll?.documentView as? TranscriptNativeDocument }
        var rows: [TranscriptRowContainer] { document?.retainedRows ?? [] }
        var viewCount: Int {
            func walk(_ view: NSView) -> Int { 1 + view.subviews.reduce(0) { $0 + walk($1) } }
            return walk(hosted)
        }
        var viewCensus: [String: Int] {
            var classes: [String: Int] = [:]
            func walk(_ view: NSView) { classes[String(describing: type(of: view)), default: 0] += 1; for child in view.subviews { walk(child) } }
            walk(hosted)
            return classes
        }

        /// One frame: apply the change, let SwiftUI and AppKit lay the pane out,
        /// then display it, timing each part and the document's work inside.
        /// One frame of the pane. A disclosure's motion is landed inside it,
        /// so what this measures is the click and the page it settles on; the
        /// tests that watch the motion drive its ticks instead.
        func frame(reset: Bool = true, _ change: () -> Void) -> Frame {
            var result = Frame()
            let carried = (TranscriptLayoutClock.markdownUpdateSeconds, TranscriptLayoutClock.markdownLayoutSeconds, TranscriptLayoutClock.markdownBlocksMeasured)
            let carriedPage = (TranscriptLayoutClock.rowLoopSeconds, TranscriptLayoutClock.mountSeconds)
            let carriedSizing = (TranscriptLayoutClock.rowSizingPasses, TranscriptLayoutClock.rowSizingSeconds)
            TranscriptLayoutClock.recording = true
            TranscriptLayoutClock.reset()
            if !reset {
                TranscriptLayoutClock.markdownUpdateSeconds = carried.0
                TranscriptLayoutClock.markdownLayoutSeconds = carried.1
                TranscriptLayoutClock.markdownBlocksMeasured = carried.2
                TranscriptLayoutClock.rowLoopSeconds = carriedPage.0
                TranscriptLayoutClock.mountSeconds = carriedPage.1
                TranscriptLayoutClock.rowSizingPasses = carriedSizing.0
                TranscriptLayoutClock.rowSizingSeconds = carriedSizing.1
            }
            var start = TranscriptLayoutClock.now
            change()
            result.model = TranscriptLayoutClock.now - start
            start = TranscriptLayoutClock.now
            document?.finishDisclosureMotion()
            hosted.layoutSubtreeIfNeeded()
            result.layout = TranscriptLayoutClock.now - start
            start = TranscriptLayoutClock.now
            window.displayIfNeeded()
            result.display = TranscriptLayoutClock.now - start
            result.documentUpdate = TranscriptLayoutClock.updateSeconds
            result.documentLayout = TranscriptLayoutClock.layoutSeconds
            result.measure = TranscriptLayoutClock.measureSeconds
            result.measuredRows = TranscriptLayoutClock.measuredRows
            result.mountedRows = TranscriptLayoutClock.mountedRows
            return result
        }
        /// Everything the run loop still owes the pane: deferred validation,
        /// scheduled layout, idle measurement slices.
        func settle(turns: Int = 8) async {
            document?.finishDisclosureMotion()
            for _ in 0..<turns {
                hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(10))
            }
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        }
        /// A long chat comes up with its viewport exact and measures the rest
        /// in idle slices. This waits for the last of them, as a reader who
        /// leaves the chat open does, with the slices run back to back
        /// (`unpacedIdleWork`).
        func settleUntilExact(seconds: Double = 120) async {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            await unpacedIdleWork {
                while (document?.approximateRowCount ?? 0) > 0, ProcessInfo.processInfo.systemUptime < deadline {
                    hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    await Task.yield()
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
            await settle(turns: 8)
        }
        /// Waits until a row is on the page, the way the reader waits for the
        /// chat to appear.
        func waitForRow(_ id: String, seconds: Double = 30) async -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while ProcessInfo.processInfo.systemUptime < deadline {
                hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                if let page, page.rowFrame(of: id) != nil || page.rowFrame(of: "block:" + id) != nil { return true }
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(1))
            }
            return false
        }
    }

    // MARK: Fixtures

    static let paragraph = "Some **bold** text with `code`, a [link](https://example.com) and a list:\n\n- one\n- two\n\n```swift\nfunc charge(_ order: Order) async throws -> Receipt { for attempt in 1...3 { } }\n```\n\n"

    @MainActor static func chat(_ id: String, rows: Int) -> SessionDisplay {
        let session = SessionDisplay(id: id)
        session.messages = (0..<rows).map { index in
            var message = TranscriptMessage(id: "m\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant",
                                            text: paragraph + "Row \(index).", turn: "m\(index - index % 2)")
            message.at = Double(index) * 1000
            return message
        }
        return session
    }
    static func lastUserID(rows: Int) -> String { "m\(rows - (rows.isMultiple(of: 2) ? 2 : 1))" }

    /// The process's real memory, the figure Activity Monitor shows.
    static func footprintBytes() -> UInt64 {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        return result == 0 ? usage.ri_phys_footprint : 0
    }

    // MARK: 1 — Opening a long chat

    /// Opening a 300-row chat: how long before the reader can read, and what
    /// the first frame is spent on.
    @MainActor func testWhereOpeningALongChatSpendsItsTime() async throws {
        let rows = Int(testEnvironment("PI_PERF_ROWS") ?? "") ?? 300
        let session = Self.chat("open-budget", rows: rows)
        TranscriptLayoutClock.recording = true
        TranscriptLayoutClock.reset()
        defer { TranscriptLayoutClock.recording = false }
        let started = ProcessInfo.processInfo.systemUptime
        let pane = Pane(session); defer { pane.close() }
        pane.hosted.layoutSubtreeIfNeeded(); pane.window.displayIfNeeded()
        let shell = ProcessInfo.processInfo.systemUptime - started
        // First paint: the reader can read the rows in the viewport.
        var paint = 0.0
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            pane.hosted.layoutSubtreeIfNeeded(); pane.window.displayIfNeeded()
            if let scroll = pane.scroll, let document = pane.document,
               document.frame.height > scroll.contentView.bounds.height,
               pane.rows.contains(where: { $0.superview != nil }) { break }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        paint = ProcessInfo.processInfo.systemUptime - started
        let mountedAtPaint = pane.rows.filter { $0.superview != nil }.count
        let hostedAtPaint = pane.document?.hostedRowCount ?? rows
        let viewsAtPaint = pane.viewCount
        print(String(format: "PERF open %d rows, at first paint: document update %.0f ms, document layout %.0f ms, measuring %d rows %.0f ms, %d row hosts built, %d rows still estimated, %d mounts",
                     rows, TranscriptLayoutClock.updateSeconds * 1000, TranscriptLayoutClock.layoutSeconds * 1000,
                     TranscriptLayoutClock.measuredRows, TranscriptLayoutClock.measureSeconds * 1000,
                     pane.document?.rowsBuiltCount ?? 0, pane.document?.estimatedRowCount ?? 0, TranscriptLayoutClock.mountedRows))
        print("PERF open \(rows) rows: \(hostedAtPaint) SwiftUI row trees built for the first paint")
        let ready = await pane.waitForRow(Self.lastUserID(rows: rows))
        XCTAssertTrue(ready, "the chat never laid its last row out")
        let exact = ProcessInfo.processInfo.systemUptime - started
        await pane.settle(turns: 40)
        let settled = ProcessInfo.processInfo.systemUptime - started
        let census = pane.viewCensus
        print(String(format: "PERF open %d rows: shell %.0f ms, first paint %.0f ms (%d rows mounted, %d views), last row placed %.0f ms, fully settled %.0f ms",
                     rows, shell * 1000, paint * 1000, mountedAtPaint, viewsAtPaint, exact * 1000, settled * 1000))
        print("PERF views held by a settled \(rows)-row page: \(census.values.reduce(0, +)) — \(census.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        // The target is 100 ms; this is the ceiling that catches a return to
        // measuring the whole page before the reader sees anything.
        XCTAssertLessThan(paint, releaseBudget(0.400), "the reader waited \(Int(paint * 1000)) ms for the first paint of a \(rows)-row chat")
        XCTAssertLessThan(pane.rows.filter { $0.superview != nil }.count, 40,
                          "a settled \(rows)-row page keeps too many rows mounted")
        XCTAssertLessThan(hostedAtPaint, 40,
                          "the first paint of a \(rows)-row chat built \(hostedAtPaint) SwiftUI row trees")
        XCTAssertLessThan(pane.document?.hostedRowCount ?? rows, 120,
                          "a settled \(rows)-row page holds \(pane.document?.hostedRowCount ?? 0) SwiftUI row trees")
    }

    /// The document on its own, without the pane around it: one pass over a
    /// long chat must measure the rows it is about to draw and no more.
    @MainActor func testTheOpeningPassMeasuresOnlyTheRowsItDraws() async throws {
        let rows = 300
        let session = Self.chat("slice-unit", rows: rows)
        let page = TranscriptPage()
        let scroll = TranscriptNativeScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        scroll.hasVerticalScroller = true
        let document = TranscriptNativeDocument(page: page, geometryCache: TranscriptGeometryCache())
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        page.bind(session)
        TranscriptLayoutClock.recording = true
        TranscriptLayoutClock.reset()
        defer { TranscriptLayoutClock.recording = false }
        let started = ProcessInfo.processInfo.systemUptime
        document.update(snapshot: page.snapshot, actions: TranscriptActions(), environment: TranscriptRowEnvironment(),
                        disclosure: session.disclosure, toolInputs: session.toolInputs)
        document.layoutRows(width: scroll.contentSize.width)
        let cost = ProcessInfo.processInfo.systemUptime - started
        print(String(format: "PERF one opening pass over %d rows: %.0f ms, %d layout passes, band %d rows, measured %d, %d standing now (%d ever), %d corrections, document %.0f points",
                     rows, cost * 1000, document.layoutPassCount, document.lastBandCount, TranscriptLayoutClock.measuredRows,
                     document.estimatedRowCount, document.estimatedEver, document.correctionRounds, document.frame.height))
        XCTAssertGreaterThan(document.estimatedRowCount, rows / 2,
                             "the opening pass measured \(TranscriptLayoutClock.measuredRows) of \(rows) rows")
        XCTAssertLessThan(cost, releaseBudget(0.300), "the opening pass took \(Int(cost * 1000)) ms")
        XCTAssertGreaterThan(document.frame.height, 700, "an estimated page still has a height to scroll")
        // Every row is placed, in order, with no gaps and no overlaps.
        var expected: CGFloat = 12
        for row in document.retainedRows {
            XCTAssertEqual(row.frame.minY, expected, accuracy: 0.5, "row \(row.itemID) is not stacked")
            expected = row.frame.maxY
            if document.isEstimated(row.itemID) { XCTAssertNil(row.superview, "an estimated row must never be in the view tree") }
        }
    }

    // MARK: 2 — A streaming delta

    @MainActor func testWhereAStreamingDeltaSpendsItsTime() async throws {
        let rows = Int(testEnvironment("PI_PERF_ROWS") ?? "") ?? 300
        let session = Self.chat("delta-budget", rows: rows)
        let last = Self.lastUserID(rows: rows)
        let pane = Pane(session, state: "running"); defer { pane.close() }
        let ready = await pane.waitForRow(last)
        XCTAssertTrue(ready)
        await pane.settleUntilExact()
        // The page does not exist until the native hierarchy mounts. Disable
        // coalescing only after that boundary, and check each presented prefix
        // so the benchmark cannot mistake skipped work for faster layout.
        // Production cadence is exercised separately by the two-pane workload.
        let measuredPage = try XCTUnwrap(pane.page)
        measuredPage.presentationInterval = 0
        let reply = (0..<40).map {
            "## Step \($0)\n\nHere is what changed in `file\($0).swift`: the handler now **retries** twice and logs the reason.\n\n1. First point with detail.\n2. Second point with more detail.\n\n```swift\nlet value = compute(index: \($0))\n```\n"
        }.joined(separator: "\n")
        let bytes = Array(reply.utf8)
        var framesBefore: [String: CGRect] = [:]
        var deltas = 0
        var sum = Frame()
        var worst = Frame()
        var durations: [Double] = []
        var roots: [Double] = []
        var placements: [Double] = []
        var validationDurations: [Double] = []
        var invalidations = 0
        let step = max(32, Int(testEnvironment("PI_PERF_DELTA_BYTES") ?? "") ?? 300)
        var offset = step
        while offset <= bytes.count {
            let text = String(decoding: bytes[0..<offset], as: UTF8.self)
            let row = TranscriptMessage(id: "stream:x", role: "assistant", text: text, state: "streaming", turn: last)
            let frame = pane.frame(reset: deltas == 0) {
                if deltas > 0 { session.messages[session.messages.count - 1] = row } else { session.messages.append(row) }
            }
            XCTAssertEqual(measuredPage.snapshot?.messages.last?.text, text,
                           "Every measured delta must reach the presented page")
            XCTAssertEqual(measuredPage.pendingPresentationCount, 0)
            if frame.total > worst.total { worst = frame }
            durations.append(frame.total)
            roots.append(TranscriptLayoutClock.rootUpdateSeconds)
            placements.append(TranscriptLayoutClock.placementSeconds)
            sum = sum + frame
            deltas += 1; offset += step
            await Task.yield()
            validationDurations.append(TranscriptLayoutClock.validationSeconds)
            invalidations += TranscriptLayoutClock.intrinsicInvalidations
            // Every row above the turn the reply joins, taken once the
            // arriving row exists, so every later delta can be held to
            // touching nothing else. The last block of a turn carries the
            // turn's own line, so the block before the arriving one moves for
            // a reason; everything above it must not move at all.
            if deltas == 1, let page = pane.page {
                framesBefore = Dictionary(uniqueKeysWithValues: pane.rows.dropLast(2).compactMap { row in
                    page.rowFrame(of: row.itemID).map { (row.itemID, $0) }
                })
            }
        }
        let mean = sum.scaled(by: 1 / Double(deltas))
        XCTAssertLessThanOrEqual(sum.measuredRows, deltas + 2,
                                 "a delta measured \(sum.measuredRows) rows over \(deltas) deltas; only the streaming row may be measured")
        XCTAssertGreaterThan(framesBefore.count, rows / 2)
        for (id, frame) in framesBefore {
            XCTAssertEqual(pane.page?.rowFrame(of: id), frame, "row \(id), above the arriving turn, moved while the reply arrived")
        }
        let container = pane.descendants(NativeMarkdownContainer.self).first
        print("PERF streaming delta into \(rows) rows, \(deltas) deltas — mean \(mean.line)")
        let validations = pane.rows.reduce(0) { $0 + $1.intrinsicValidationCount }
        print(String(format: "PERF streaming row: %d deferred intrinsic validations over %d deltas, %d layout passes in total (%d placed only the part below what changed); the page's own row loop %.1f ms and mounting %.1f ms per delta",
                     validations, deltas, pane.document?.layoutPassCount ?? 0, pane.document?.partialPassCount ?? 0,
                     TranscriptLayoutClock.rowLoopSeconds * 1000 / Double(deltas),
                     TranscriptLayoutClock.mountSeconds * 1000 / Double(deltas)))
        print(String(format: "PERF streaming row: %.1f SwiftUI sizing passes per delta costing %.1f ms",
                     Double(TranscriptLayoutClock.rowSizingPasses) / Double(deltas),
                     TranscriptLayoutClock.rowSizingSeconds * 1000 / Double(deltas)))
        print(String(format: "PERF streaming row's markdown: %d blocks, %d full text layouts, %d block measurements over %d deltas, container update %.1f ms, text layout %.1f ms per delta",
                     container?.retainedBlockCount ?? 0, container?.layoutPasses ?? 0, TranscriptLayoutClock.markdownBlocksMeasured,
                     deltas, TranscriptLayoutClock.markdownUpdateSeconds * 1000 / Double(deltas),
                     TranscriptLayoutClock.markdownLayoutSeconds * 1000 / Double(deltas)))
        print("PERF streaming delta into \(rows) rows — worst \(worst.line)")
        func distribution(_ values: [Double]) -> String {
            let ordered = values.sorted()
            func percentile(_ p: Double) -> Double { ordered[max(0, Int(ceil(Double(ordered.count) * p)) - 1)] * 1000 }
            return String(format: "p50 %.2f / p95 %.2f / p99 %.2f / max %.2f ms",
                          percentile(0.5), percentile(0.95), percentile(0.99), (ordered.last ?? 0) * 1000)
        }
        print("REVIEW delta \(distribution(durations)); root assignment \(distribution(roots)); placement \(distribution(placements)); deferred validation \(distribution(validationDurations)); \(invalidations) intrinsic invalidations")
        // The target is 8 ms. What is left is the arriving row's own native
        // layout — the Markdown blocks the delta actually added — plus one
        // pass over the page; this is the ceiling that catches a delta going
        // back to work proportional to the whole chat.
        // The arriving row is sized and laid out once; a second pass for the
        // same content is the thing this is here to catch.
        XCTAssertLessThan(Double(TranscriptLayoutClock.rowSizingPasses) / Double(deltas), 2.2,
                          "a delta put the arriving row through \(TranscriptLayoutClock.rowSizingPasses) SwiftUI sizing passes over \(deltas) deltas")
        // What is left is the arriving row itself: SwiftUI sizes its tree
        // once and lays it out once at the frame that follows, and each of
        // those is about ten milliseconds for an eleven-kilobyte reply. The
        // count above is what holds it to those two.
        // 27-32 ms measured on a quiet machine, 40 ms beside a build. A
        // Release ceiling with no room for a loaded machine measures the
        // machine, not the code; the pass count above is the real guard.
        XCTAssertLessThan(mean.total, releaseBudget(0.050), "a streamed delta costs \(Int(mean.total * 1000)) ms in a \(rows)-row chat")
    }

    // MARK: 3 — Folding a long turn

    @MainActor func testWhereFoldingSixtyToolCallsSpendsItsTime() async throws {
        let session = SessionDisplay(id: "fold-budget")
        var reply = TranscriptMessage(id: "a1", role: "assistant",
                                      text: String(repeating: "Here is what changed and why it matters for the next step. ", count: 12),
                                      at: 2_000, turn: "u1")
        reply.thinking = String(repeating: "Considering the order of the edits. ", count: 6)
        reply.tools = (0..<60).map { index in
            ToolView(id: "t\(index)", name: index % 3 == 0 ? "bash" : "read", state: "completed",
                     input: "{\"path\":\"apps/macos/PiApp/Sources/File\(index).swift\"}",
                     output: String(repeating: "line \(index) of tool output that wraps across the card. ", count: 8),
                     durationMs: 12 + Double(index), truncated: false, path: "apps/macos/PiApp/Sources/File\(index).swift")
        }
        session.messages = [TranscriptMessage(id: "u1", role: "user", text: "Work through the whole change.", at: 1_000, turn: "u1"), reply]
        session.messages += (0..<20).map { index in
            TranscriptMessage(id: "tail\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant",
                              text: String(repeating: "Tail row \(index) with enough text to wrap. ", count: 6),
                              at: 3_000 + Double(index), turn: "tail\(index - index % 2)")
        }
        let pane = Pane(session); defer { pane.close() }
        let ready = await pane.waitForRow("tail19")
        XCTAssertTrue(ready)
        await pane.settle(turns: 20)
        let row = try XCTUnwrap(pane.rows.first { if case .block = $0.item { return true }; return false })
        guard case .block(let block) = row.item else { return XCTFail("no block row") }
        let part = TranscriptDisclosure.Part.work(block.key)
        // The reader is looking at the turn they are folding: a chevron they
        // cannot see is one they cannot click.
        if let scroll = pane.scroll {
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: max(0, row.frame.minY - 40)))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        }
        await pane.settle(turns: 6)
        let open = row.frame.height
        var fold = Frame(), unfold = Frame()
        let rounds = 6
        for _ in 0..<rounds {
            fold = fold + pane.frame { row.toggleDisclosure(part) }
            await pane.settle(turns: 2)
            unfold = unfold + pane.frame { row.toggleDisclosure(part) }
            await pane.settle(turns: 2)
        }
        XCTAssertEqual(row.frame.height, open, accuracy: 1, "folding and unfolding must return the turn to its own height")
        let cachedBeforeProse = row.workListReuses
        let measuredBeforeProse = row.measurementCount
        let cardsBeforeProse = TranscriptLayoutClock.workListCardsMeasured
        let original = session.messages[1]
        for index in 0..<12 {
            _ = pane.frame {
                session.messages[1].text = original.text + String(repeating: " New prose only.", count: index + 1)
            }
            await pane.settle(turns: 2)
        }
        // A reply's prose and the work that produced it are separate rows
        // since the chronology pass, so a prose-only delta must not reach the
        // work row at all: it neither rebuilds it nor measures it, which is
        // stronger than the work list reusing a height it kept.
        XCTAssertEqual(row.measurementCount, measuredBeforeProse, "Prose must not re-measure the work row")
        XCTAssertEqual(row.workListReuses, cachedBeforeProse, "Prose must not rebuild the work list at all")
        XCTAssertEqual(TranscriptLayoutClock.workListCardsMeasured, cardsBeforeProse, "Unchanged tools must not be remeasured for a prose-only delta")

        print("PERF folding a 60-tool turn — \(fold.scaled(by: 1 / Double(rounds)).line)")
        print("PERF the turn's work list reused its measured height \(row.workListReuses) times over \(rounds * 2) clicks")
        print("PERF unfolding a 60-tool turn — \(unfold.scaled(by: 1 / Double(rounds)).line)")
        // The target is 8 ms. The row itself now costs about 1.5 ms either
        // way; what is left is laying out the rows the fold brings into view,
        // and on an unfold the work list's own placement. These are the
        // ceilings that catch a click going back to measuring sixty rows.
        XCTAssertLessThan(fold.scaled(by: 1 / Double(rounds)).total, releaseBudget(0.025), "folding a 60-tool turn took too long")
        XCTAssertLessThan(unfold.scaled(by: 1 / Double(rounds)).total, releaseBudget(0.025), "unfolding a 60-tool turn took too long")
    }


    /// The chat the reader leaves is let go of. The pane is kept across
    /// chats now, so anything under it that captured the conversation when
    /// it was bound would hold it for the window's lifetime. The actions are
    /// the shape the real pane hands down: closures that capture the session.
    @MainActor func testRebindingReleasesTheChatTheReaderLeft() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        weak var left: SessionDisplay?
        var hosted: NSHostingView<NativeTranscriptView>!
        do {
            let first = Self.chat("leak-first", rows: 20)
            left = first
            hosted = NSHostingView(rootView: NativeTranscriptView(
                session: first, actions: TranscriptActions(inspect: { _ in _ = first.id }, edit: { _ in _ = first.id }),
                onAnchorChanged: { _ in _ = first.id }))
            window.contentView = hosted
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<60 {
                hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                await Task.yield(); try? await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertNotNil(left)
        }
        do {
            let second = Self.chat("leak-second", rows: 20)
            hosted.rootView = NativeTranscriptView(
                session: second, actions: TranscriptActions(inspect: { _ in _ = second.id }, edit: { _ in _ = second.id }),
                onAnchorChanged: { _ in _ = second.id })
            for _ in 0..<80 {
                hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                await Task.yield(); try? await Task.sleep(for: .milliseconds(5))
            }
        }
        for _ in 0..<40 { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(left, "the chat the reader left is still in memory")
    }


    // MARK: 5 — Memory over a session of use

    @MainActor func testVisitingManyLongChatsDoesNotGrowTheProcess() async throws {
        // Fifty chats is the target; the suite visits fewer by default and
        // PI_PERF_VISITS asks for the whole run.
        let visits = Int(testEnvironment("PI_PERF_VISITS") ?? "") ?? 30
        let rows = Int(testEnvironment("PI_PERF_VISIT_ROWS") ?? "") ?? 60
        // The pane is built once and shown one chat after another, as the app
        // does when the reader clicks through the sidebar.
        let sessions = (0..<visits).map { Self.chat("visit-\($0)", rows: rows) }
        let pane = Pane(sessions[0]); defer { pane.close() }
        let ready = await pane.waitForRow(Self.lastUserID(rows: rows), seconds: 60)
        XCTAssertTrue(ready)
        await pane.settle(turns: 20)
        // Warm up: the first handful of visits pay for fonts, text engines and
        // the caches that are meant to stay warm.
        for session in sessions.prefix(5) {
            pane.hosted.rootView = NativeTranscriptView(session: session, actions: TranscriptActions())
            _ = await pane.waitForRow(Self.lastUserID(rows: rows), seconds: 60)
            await pane.settle(turns: 6)
        }
        let before = Self.footprintBytes()
        let remaining = sessions.dropFirst(5)
        // Where the visits are half done, so the second half can be compared
        // with the first: what "bounded" means is that the page stops costing
        // more, not that it costs nothing.
        var middle = before
        for (index, session) in remaining.enumerated() {
            pane.hosted.rootView = NativeTranscriptView(session: session, actions: TranscriptActions())
            _ = await pane.waitForRow(Self.lastUserID(rows: rows), seconds: 60)
            await pane.settle(turns: 4)
            if index == remaining.count / 2 - 1 { await pane.settle(turns: 8); middle = Self.footprintBytes() }
        }
        await pane.settle(turns: 20)
        let after = Self.footprintBytes()
        let grown = Double(after) - Double(before)
        let visited = visits - 5
        let firstHalf = Double(middle) - Double(before), secondHalf = Double(after) - Double(middle)
        print(String(format: "PERF visiting %d chats of %d rows: %.1f MB before, %.1f MB after, %+.0f KB per chat visited (first half %+.1f MB, second half %+.1f MB)",
                     visited, rows, Double(before) / 1_048_576, Double(after) / 1_048_576, grown / 1024 / Double(visited),
                     firstHalf / 1_048_576, secondHalf / 1_048_576))
        // The transcript's own caches are bounded — the shared geometry cache
        // by count and bytes, the Markdown and highlighter caches by NSCache
        // limits that also yield under memory pressure — so what the page
        // costs is the caches filling, and filling stops. That is the shape
        // this holds to, in any configuration: the second half of the visits
        // must cost less than the first. Something retained per chat would
        // cost the same for every one of them. Debug views are heavy enough
        // that twenty-five visits do not fill the caches, so the claim is a
        // Release one; retention itself is proved by the weak-reference tests.
        XCTAssertLessThan(secondHalf, releaseBudget(max(firstHalf, 4 * 1_048_576)),
                          String(format: "the page kept growing: %.1f MB over the first %d chats, %.1f MB over the next %d",
                                 firstHalf / 1_048_576, visited / 2, secondHalf / 1_048_576, visited - visited / 2))
        XCTAssertLessThan(grown / Double(visited), releaseBudget(1_500_000),
                          "each visited chat left \(Int(grown / Double(visited) / 1024)) KB behind")
    }
}

/// Clicking from one long chat to another, with the pane kept and with it
/// rebuilt: the frame budget of a switch. Split from `TranscriptFrameBudgetTests`
/// so the parallel lane can run the two long fixtures side by side.
final class TranscriptSwitchBudgetTests: XCTestCase {
    private typealias Pane = TranscriptFrameBudgetTests.Pane

    /// Clicking from one long chat to another. Two shapes are measured: the
    /// pane kept and rebound, which is what the transcript is built for, and
    /// the pane thrown away and rebuilt, which is what an `.id(chat.id)` on
    /// the conversation pane forces. The reader must see the new chat settled
    /// either way — never an empty pane that fills in afterwards.
    @MainActor func testSwitchingBetweenTwoLongChats() async throws {
        let rows = Int(testEnvironment("PI_PERF_ROWS") ?? "") ?? 300
        let last = TranscriptFrameBudgetTests.lastUserID(rows: rows)
        let first = TranscriptFrameBudgetTests.chat("switch-a", rows: rows)
        let second = TranscriptFrameBudgetTests.chat("switch-b", rows: rows)
        // The other chat answers at greater length, so borrowing one chat's
        // geometry for the other would show up as a wrong height.
        second.messages = second.messages.map { message in
            var copy = message
            if message.role == "assistant" { copy.text += String(repeating: "\n\nAnd a further paragraph of the other chat's answer.", count: 3) }
            return copy
        }
        let pane = Pane(first); defer { pane.close() }
        let ready = await pane.waitForRow(last, seconds: 60)
        XCTAssertTrue(ready)
        await pane.settleUntilExact()

        @MainActor func show(_ session: SessionDisplay) async -> (paint: Double, measured: Int, borrowed: Int, mounted: Int,
                                                                  reconcile: Double, layout: Double, rebind: Double, passes: Int) {
            TranscriptLayoutClock.recording = true
            TranscriptLayoutClock.reset()
            defer { TranscriptLayoutClock.recording = false }
            let passesBefore = pane.document?.layoutPassCount ?? 0
            let started = ProcessInfo.processInfo.systemUptime
            pane.hosted.rootView = NativeTranscriptView(session: session, actions: TranscriptActions())
            let rebind = ProcessInfo.processInfo.systemUptime - started
            var paint = 0.0
            let deadline = started + 30
            var shown = false
            while ProcessInfo.processInfo.systemUptime < deadline {
                pane.hosted.layoutSubtreeIfNeeded(); pane.window.displayIfNeeded()
                if let document = pane.document, document.shownSessionID == session.id,
                   document.retainedRows.count == rows,
                   document.retainedRows.contains(where: { $0.superview != nil && $0.frame.height > 1 }) { shown = true; break }
                await Task.yield()
            }
            paint = ProcessInfo.processInfo.systemUptime - started
            XCTAssertTrue(shown, "the pane never showed \(session.id)")
            let mounted = pane.rows.filter { $0.superview != nil }.count
            let borrowed = pane.rows.reduce(0) { $0 + $1.sharedMeasurementHits }
            return (paint, TranscriptLayoutClock.measuredRows, borrowed, mounted,
                    TranscriptLayoutClock.updateSeconds, TranscriptLayoutClock.layoutSeconds,
                    rebind, (pane.document?.layoutPassCount ?? 0) - passesBefore)
        }

        let cold = await show(second)
        await pane.settleUntilExact()
        let back = await show(first)
        await pane.settle(turns: 20)
        print(String(format: "PERF switching to another %d-row chat, pane kept, cold: first paint %.0f ms — %.0f ms in the rootView assignment, %.0f ms reconciling rows, %.0f ms in %d layout passes, %d rows measured",
                     rows, cold.paint * 1000, cold.rebind * 1000, cold.reconcile * 1000, cold.layout * 1000, cold.passes, cold.measured))
        print(String(format: "PERF switching back to a %d-row chat already read: first paint %.0f ms — %.0f ms in the rootView assignment, %.0f ms reconciling rows, %.0f ms in %d layout passes, %d rows measured, %d borrowed from the shared geometry",
                     rows, back.paint * 1000, back.rebind * 1000, back.reconcile * 1000, back.layout * 1000, back.passes, back.measured, back.borrowed))
        XCTAssertGreaterThan(cold.mounted, 0, "the new chat must be on screen at its first paint, not an empty pane")
        // The target is 100 ms. What is left is not measurement — returning
        // to a chat measures no row at all — but building this chat's row
        // hosts and dropping the other chat's; see the report.
        XCTAssertLessThan(cold.paint, releaseBudget(0.400), "switching to another \(rows)-row chat took \(Int(cold.paint * 1000)) ms")
        XCTAssertLessThan(back.paint, releaseBudget(0.300), "returning to a \(rows)-row chat took \(Int(back.paint * 1000)) ms")
        XCTAssertLessThan(back.measured, rows / 2, "a chat the reader has already read must come back from the shared geometry, not be measured again")

        // What the pane costs when it is rebuilt instead of rebound.
        let rebuiltStart = ProcessInfo.processInfo.systemUptime
        let rebuilt = Pane(second); defer { rebuilt.close() }
        var rebuiltPaint = 0.0
        let deadline = rebuiltStart + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            rebuilt.hosted.layoutSubtreeIfNeeded(); rebuilt.window.displayIfNeeded()
            if let document = rebuilt.document, document.retainedRows.count == rows,
               document.retainedRows.contains(where: { $0.superview != nil }) { break }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        rebuiltPaint = ProcessInfo.processInfo.systemUptime - rebuiltStart
        print(String(format: "PERF the same switch with the pane rebuilt from scratch: first paint %.0f ms", rebuiltPaint * 1000))
        XCTAssertLessThan(rebuiltPaint, releaseBudget(0.500), "rebuilding the pane for a \(rows)-row chat took \(Int(rebuiltPaint * 1000)) ms")
        XCTAssertLessThan(cold.measured, 40, "switching to another \(rows)-row chat measured \(cold.measured) rows")
    }
}

/// A long page scrolled a wheel step at a time: the frame budget of reading.
final class TranscriptScrollBudgetTests: XCTestCase {
    private typealias Pane = TranscriptFrameBudgetTests.Pane

    /// A long source history scrolled through the real bounded display page,
    /// a synthetic wheel step at a time. Report both counts: the app's 500-row
    /// cap means a 2,000-message source is not a 2,000-row rendered document.
    ///
    /// The whole page is built, measured and laid out, and the steps are
    /// taken from its top through its first hundred rows
    /// (PI_PERF_SCROLL_SAMPLE_ROWS; 0 scrolls to the end). Every row of this
    /// page is the same question or the same answer, so what a step costs
    /// depends only on where it stands against the rows it brings in, which
    /// repeats every two rows, and on the page's own length, which is the
    /// whole page's either way. A hundred rows are some 2,200 steps over
    /// thirty screens, many times the few screens of trees the page keeps
    /// ready around the reader: the stretch holds the steady state, and every
    /// kind of step in its share. Measured over the whole page in a Debug
    /// run, the first hundred rows took 3.51 ms a step with 4.6% of steps
    /// over a frame; all four hundred, 3.46 ms and 4.5%; each hundred-row
    /// band, 3.40 to 3.50 ms and 4.4 to 4.5%.
    @MainActor func testScrollingATwoThousandRowPageKeepsUpWithTheDisplay() async throws {
        // PI_PERF_SCROLL_ROWS varies the source; production paging still applies.
        let rows = Int(testEnvironment("PI_PERF_SCROLL_ROWS") ?? "") ?? 400
        let session = TranscriptFrameBudgetTests.chat("scroll-budget", rows: rows)
        let pane = Pane(session); defer { pane.close() }
        let ready = await pane.waitForRow(TranscriptFrameBudgetTests.lastUserID(rows: rows), seconds: 120)
        XCTAssertTrue(ready)
        await pane.settleUntilExact()
        let scroll = try XCTUnwrap(pane.scroll)
        let document = try XCTUnwrap(pane.document)
        let renderedRows = document.retainedRows.count
        XCTAssertEqual(renderedRows, min(rows, TranscriptPage.rowLimit))
        let travel = max(0, document.frame.height - scroll.contentView.bounds.height)
        let sampleRows = Int(testEnvironment("PI_PERF_SCROLL_SAMPLE_ROWS") ?? "") ?? 100
        let end = sampleRows > 0 && sampleRows < renderedRows ? min(travel, document.retainedRows[sampleRows].frame.minY) : travel
        // A trackpad delivers about 10 points per event at 120 Hz.
        let step: CGFloat = 10
        let budget = 1.0 / 120
        var over = 0, steps = 0, worst = 0.0, total = 0.0
        var y: CGFloat = 0
        while y < end {
            let start = ProcessInfo.processInfo.systemUptime
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            pane.hosted.layoutSubtreeIfNeeded()
            pane.window.displayIfNeeded()
            let cost = ProcessInfo.processInfo.systemUptime - start
            total += cost; worst = max(worst, cost); steps += 1
            if cost > budget { over += 1 }
            y += step
            // Real scrolling runs the run loop between events; so does this,
            // which is also what lets the page build the trees for the rows
            // the reader is about to reach.
            await Task.yield()
            if steps % 16 == 0 { try? await Task.sleep(for: .milliseconds(1)) }
        }
        print(String(format: "PERF scrolling %d rendered rows from %d source messages, from the top through %.0f of %.0f points: %d synthetic steps of %.0f points, %.2f ms mean, %.1f ms worst, %d over 8.33 ms (%.1f%%)",
                     renderedRows, rows, end, travel, steps, step, total * 1000 / Double(max(1, steps)), worst * 1000, over, Double(over) * 100 / Double(max(1, steps))))
        // Reading a chat through for the first time builds each row's
        // SwiftUI tree as the reader reaches it — the work that used to be
        // done for the whole page before the chat appeared at all. Those are
        // the steps over budget here; the mean is what the rest of a scroll
        // costs. See the report: building them ahead of the reader in the
        // page's own idle slices is what would take this back to nothing.
        XCTAssertLessThan(Double(over) / Double(max(1, steps)), releaseBudget(0.15),
                          "\(over) of \(steps) scroll steps over a 120 Hz frame")
        XCTAssertLessThan(total / Double(max(1, steps)), releaseBudget(0.006),
                          String(format: "a scroll step costs %.2f ms on average", total * 1000 / Double(max(1, steps))))
    }
}

/// A disclosure's motion over a long page, held to a multiple of its own
/// click in Debug too: its ticks are timed, so it runs in the serial lane
/// (`scripts/test-lanes.py`).
final class TranscriptMotionTimingTests: XCTestCase, SerialTestLane {
    private typealias Pane = TranscriptFrameBudgetTests.Pane

    /// What a tick of a disclosure's motion costs over a long page. A tick
    /// is frame changes: the row that is moving keeps the tree it was
    /// measured with, every row under it shifts by the same amount, and
    /// nothing is measured, built or handed to SwiftUI.
    @MainActor func testATickOfADisclosureMotionIsFrameChangesOnly() async throws {
        let rows = Int(testEnvironment("PI_PERF_ROWS") ?? "") ?? 300
        let session = TranscriptFrameBudgetTests.chat("motion-budget", rows: rows)
        var worked = TranscriptMessage(id: "worked", role: "assistant",
                                       text: String(repeating: "Here is what changed and why. ", count: 8),
                                       at: Double(rows) * 1000 + 10, turn: TranscriptFrameBudgetTests.lastUserID(rows: rows))
        worked.tools = (0..<60).map { index in
            ToolView(id: "w\(index)", name: index % 3 == 0 ? "bash" : "read", state: "completed",
                     input: "{\"path\":\"apps/macos/PiApp/Sources/File\(index).swift\"}",
                     output: String(repeating: "line \(index) of the result. ", count: 6),
                     durationMs: 10 + Double(index), truncated: false, path: "apps/macos/PiApp/Sources/File\(index).swift")
        }
        session.messages.append(worked)
        TranscriptNativeDocument.reducesMotionOverride = false
        defer { TranscriptNativeDocument.reducesMotionOverride = nil }
        let pane = Pane(session); defer { pane.close() }
        let ready = await pane.waitForRow("worked", seconds: 60)
        XCTAssertTrue(ready)
        await pane.settleUntilExact()
        let document = try XCTUnwrap(pane.document)
        let row = try XCTUnwrap(pane.rows.first { if case .block(let block) = $0.item { return !block.tools.isEmpty }; return false })
        guard case .block(let block) = row.item else { return XCTFail("no turn with work") }
        // The reader is looking at the turn whose chevron they click.
        if let scroll = pane.scroll {
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: max(0, row.frame.minY - 40)))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        }
        await pane.settle(turns: 8)

        row.toggleDisclosure(.work(block.key))
        document.advanceDisclosureMotion(to:1)
        await pane.settleUntilExact()
        let measurementsBefore = pane.rows.reduce(0) { $0 + $1.measurementCount }
        let builtBefore = document.rowsBuiltCount
        let open = row.frame.height
        let clickStart = ProcessInfo.processInfo.systemUptime
        row.toggleDisclosure(.work(block.key))
        let click = ProcessInfo.processInfo.systemUptime - clickStart
        XCTAssertTrue(document.isMovingDisclosure, "the click must start the motion")
        // A 220 ms motion at 120 Hz.
        let ticks = 26
        var worst = 0.0
        let ticksStart = ProcessInfo.processInfo.systemUptime
        for tick in 1...ticks {
            let started = ProcessInfo.processInfo.systemUptime
            document.advanceDisclosureMotion(to: Double(tick) / Double(ticks))
            pane.window.displayIfNeeded()
            worst = max(worst, ProcessInfo.processInfo.systemUptime - started)
        }
        let ticksCost = ProcessInfo.processInfo.systemUptime - ticksStart
        print(String(format: "PERF a disclosure over %d rows: the click %.1f ms, %d ticks %.2f ms each (worst %.2f ms), %.1f ms in total; the document's own tick %.2f ms",
                     rows, click * 1000, ticks, ticksCost * 1000 / Double(ticks), worst * 1000,
                     (click + ticksCost) * 1000, document.motionTickSeconds * 1000 / Double(max(1, document.motionTickCount))))
        // The motion itself measures nothing; the row it lands on may be
        // confirmed once as it settles.
        XCTAssertLessThanOrEqual(pane.rows.reduce(0) { $0 + $1.measurementCount }, measurementsBefore + 1,
                                 "the motion measured more than the row it landed on")
        XCTAssertEqual(document.rowsBuiltCount, builtBefore, "a tick built a row host")
        XCTAssertLessThan(row.frame.height, open / 2, "the turn ends folded")
        XCTAssertLessThan(document.motionTickSeconds / Double(max(1, document.motionTickCount)), releaseBudget(0.001),
                          "a tick over \(rows) rows costs more than a millisecond")
        // The click is the one layout this transition does; every tick after
        // it moves frames that were measured then. The ticks together may
        // cost a few clicks' worth of redrawing — never a click each, which
        // is what a tick that laid the page out again would cost. Relative,
        // because an absolute ceiling here only measures how busy the
        // machine is: under a full suite the same transition takes twice as
        // long as it does on its own, and so does the click.
        XCTAssertLessThan(ticksCost, click * 8,
                          "\(ticks) ticks cost \(Int(ticksCost * 1000)) ms against a \(Int(click * 1000)) ms click: a tick is laying the page out again")
    }
}

/// Where the chat the reader left is still being held. The conversation pane
/// is kept across chats now, so anything under it that captured the
/// conversation when it was first shown holds it for the window's lifetime.
/// These narrow it down: the transcript alone, then the whole pane.
final class ConversationPaneRetentionTests: XCTestCase {
    @MainActor private func model() throws -> (WorkspaceModel, URL, WorkspaceRecord) {
        let base = testEnvironment("PI_APP_SCRATCH_ROOT") ?? NSTemporaryDirectory()
        let root = URL(fileURLWithPath: base).appendingPathComponent("pane-retention-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let workspace = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        model.workspaces = [workspace]
        return (model, root, workspace)
    }
    @MainActor private func chat(_ id: String, in workspace: WorkspaceRecord) -> (ChatRecord, SessionDisplay) {
        let record = ChatRecord(id: id, workspaceID: workspace.id, title: id, path: nil, profileID: "profile")
        let session = SessionDisplay(id: id)
        session.messages = (0..<20).map { index in
            var message = TranscriptMessage(id: "m\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant",
                                            text: "Row \(index). " + String(repeating: "some prose that wraps. ", count: 4),
                                            turn: "m\(index - index % 2)")
            message.at = Double(index) * 1000
            return message
        }
        return (record, session)
    }
    @MainActor private func settle(_ hosted: NSView, _ window: NSWindow, turns: Int = 40) async {
        for _ in 0..<turns {
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The whole window, the way the shell's own memory test drives it: the
    /// reader clicks from chat to chat in the sidebar. The model keeps the
    /// last eight chats it showed; what this pins down is that the window
    /// adds at most one to them and grows by nothing as the reader goes on.
    ///
    /// The one it adds is SwiftUI's, not ours. The foot of the pane is a
    /// chain of five — a notice for a chat whose project is gone, one for a
    /// background task, one for an archive, one for an import, and otherwise
    /// the composer — and a conditional keeps the value of a branch it has
    /// displaced. The first time that chain changes under a chat, that
    /// chat's composer is kept, and its page with it. Bisected: the
    /// transcript, the composer and the footer each let the chat go, with
    /// the pane's own callbacks and its tool-input task, and so do all three
    /// together; the pane lets it go too once the composer is not a branch
    /// of that chain, and holds it again as soon as it is. Neither the
    /// chain's identity nor the branch order changes that. It is one chat
    /// per window, not one per chat visited, and it goes with the window.
    /// (The starter card used to add a second one; it now holds the chat's
    /// id rather than its page — see the card's own test.)
    @MainActor func testTheWholeWindowKeepsAtMostOneChatBeyondItsCache() async throws {
        let (model, root, workspace) = try model()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var profile = ProfileRecord(); profile.id = "profile"; profile.modelId = "fixture-model"
        profile.baseUrl = "https://fixture.invalid/v1"
        model.profiles = [profile]; model.selectedWorkspaceID = workspace.id; model.profileChoice = profile.id
        model.chats = (0..<12).map { ChatRecord(id: "win-\($0)", workspaceID: workspace.id, title: "Chat \($0)", path: nil, profileID: profile.id) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 820),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var held: NSView? = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = held
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        var freed: [String: () -> Bool] = [:]
        for index in 0..<12 {
            let id = "win-\(index)"
            await model.select(id)
            let session = try XCTUnwrap(model.displays[id])
            session.messages = (0..<20).map { row in
                TranscriptMessage(id: "m\(row)", role: row.isMultiple(of: 2) ? "user" : "assistant",
                                  text: "Row \(row). " + String(repeating: "some prose that wraps. ", count: 4))
            }
            weak var weakSession = session
            freed[id] = { weakSession == nil }
            await settle(try XCTUnwrap(held), window, turns: 30)
        }
        model.displays["win-0"] = nil
        await settle(try XCTUnwrap(held), window, turns: 60)
        let cached = model.displays.count
        let live = freed.filter { !$0.value() }.keys.sorted()
        // Every chat the reader passed through in the middle must have gone:
        // that is what tells a page the window forgot from a page it kept.
        let middle = (1..<4).map { "win-\($0)" }.filter { freed[$0]?() == false }
        window.contentView = nil
        window.makeFirstResponder(nil)
        held = nil
        _ = held
        for _ in 0..<80 { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
        let afterViews = freed.filter { !$0.value() }.keys.sorted()
        print("PERF the window after twelve chats: \(live.count) pages alive against \(cached) the model keeps; "
              + "\(afterViews.count) once the window's views went \(afterViews)")
        XCTAssertTrue(middle.isEmpty, "chats the reader passed through are still in memory: \(middle)")
        XCTAssertLessThanOrEqual(live.count, cached + 1, "the window is holding more than the one chat its graph pins: \(live)")
        XCTAssertLessThanOrEqual(afterViews.count, cached, "a chat outlived the window's views: \(afterViews)")
    }

    /// Which part of the pane holds a chat the reader left: the transcript,
    /// the composer and the footer each on their own, and then the three of
    /// them together, driven the way the window drives them.
    @MainActor func testNoPartOfThePaneHoldsTheChatTheReaderLeft() async throws {
        let transcript = try await firstChatFreed("tr") { SelectedTranscriptOnly(model: $0) }
        let composer = try await firstChatFreed("co") { SelectedComposerOnly(model: $0) }
        let footer = try await firstChatFreed("fo") { SelectedFooterOnly(model: $0) }
        let together = try await firstChatFreed("tg") { SelectedPaneParts(model: $0) }
        print("PERF the chat the reader left, with the pane on screen: transcript \(transcript ? "frees" : "HOLDS"), "
              + "composer \(composer ? "frees" : "HOLDS"), footer \(footer ? "frees" : "HOLDS"), all three \(together ? "free" : "HOLD")")
        XCTAssertTrue(transcript, "the transcript is holding the chat the reader left")
        XCTAssertTrue(composer, "the composer is holding the chat the reader left")
        XCTAssertTrue(footer, "the footer is holding the chat the reader left")
        XCTAssertTrue(together, "the three together are holding the chat the reader left")
    }

    /// The empty-chat starter card over the transcript, the way the pane
    /// shows it. A chat is shown before it has any messages, so the card goes
    /// up and comes down again; a subtree SwiftUI has taken off screen but
    /// that still has a button in it stays alive for as long as the window's
    /// views do, so the card must hold the chat's id and reach the model, not
    /// hold the page. Bisected piece by piece: the card's badges and text let
    /// the chat go and its row of buttons does not, whether or not any of
    /// those buttons closes over the page.
    @MainActor func testTheStarterCardDoesNotHoldTheChatTheReaderLeft() async throws {
        let freed = try await firstChatFreed("sc") { SelectedTranscriptWithStarterCard(model: $0) }
        print("PERF the chat the reader left, with the starter card over the transcript: \(freed ? "freed" : "HELD")")
        XCTAssertTrue(freed, "the empty-chat starter card is holding the chat the reader left")
    }

    /// Visits twelve chats with `surface` on screen, drops the first chat's
    /// page and answers whether it went. The view is built once and driven by
    /// the model, exactly as the window drives the pane.
    @MainActor private func firstChatFreed<Surface: View>(_ prefix: String, prefilled: Bool = false, _ surface: (WorkspaceModel) -> Surface) async throws -> Bool {
        let (model, root, workspace) = try model()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var profile = ProfileRecord(); profile.id = "profile"; profile.modelId = "fixture-model"
        profile.baseUrl = "https://fixture.invalid/v1"
        model.profiles = [profile]; model.selectedWorkspaceID = workspace.id; model.profileChoice = profile.id
        model.chats = (0..<12).map { ChatRecord(id: "\(prefix)-\($0)", workspaceID: workspace.id, title: "Chat \($0)", path: nil, profileID: profile.id) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: surface(model))
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        weak var first: SessionDisplay?
        for index in 0..<12 {
            let id = "\(prefix)-\(index)"
            let rows = (0..<20).map { row in
                TranscriptMessage(id: "m\(row)", role: row.isMultiple(of: 2) ? "user" : "assistant",
                                  text: "Row \(row). " + String(repeating: "some prose that wraps. ", count: 4))
            }
            // Seeded before the chat is chosen, the pane never sees it empty,
            // so nothing on the empty-chat path is ever put up and taken down.
            if prefilled { let seeded = SessionDisplay(id: id); seeded.messages = rows; model.displays[id] = seeded }
            await model.select(id)
            let session = try XCTUnwrap(model.displays[id])
            session.messages = rows
            if index == 0 { first = session }
            await settle(hosted, window, turns: 30)
        }
        model.displays["\(prefix)-0"] = nil
        await settle(hosted, window, turns: 60)
        return first == nil
    }


    /// The other half of the window: the chrome and the sidebar, with no
    /// conversation on screen at all.
    @MainActor func testTheSidebarAloneReleasesTheChatTheReaderLeft() async throws {
        let (model, root, workspace) = try model()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var profile = ProfileRecord(); profile.id = "profile"; profile.modelId = "fixture-model"
        profile.baseUrl = "https://fixture.invalid/v1"
        model.profiles = [profile]; model.selectedWorkspaceID = workspace.id; model.profileChoice = profile.id
        model.chats = (0..<12).map { ChatRecord(id: "bar-\($0)", workspaceID: workspace.id, title: "Chat \($0)", path: nil, profileID: profile.id) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 820),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VStack(spacing: 0) {
            WindowChrome(sidebarWidth: 260, focusedSessionID: nil).frame(height: WindowChrome.height)
            WorkspaceSidebar(model: model, width: 260)
        })
        window.makeKeyAndOrderFront(nil)
        let hosted = try XCTUnwrap(window.contentView)
        defer { window.contentView = nil; window.close() }
        var freed: [String: () -> Bool] = [:]
        for index in 0..<12 {
            let id = "bar-\(index)"
            await model.select(id)
            let session = try XCTUnwrap(model.displays[id])
            session.messages = (0..<20).map { row in
                TranscriptMessage(id: "m\(row)", role: row.isMultiple(of: 2) ? "user" : "assistant", text: "Row \(row).")
            }
            weak var weakSession = session
            freed[id] = { weakSession == nil }
            await settle(hosted, window, turns: 20)
        }
        model.displays["bar-0"] = nil
        await settle(hosted, window, turns: 60)
        let live = freed.filter { !$0.value() }.keys.sorted()
        print("PERF the sidebar alone, after dropping the first chat: \(live.count) pages alive \(live)")
        XCTAssertTrue(freed["bar-0"]?() == true, "the sidebar alone is holding the chat the reader left")
    }

    /// The model's own selection, with nothing of the window on screen but
    /// the pane: this separates what `select` leaves behind from what the
    /// rest of the window holds.
    @MainActor func testSelectingChatsWithOnlyThePaneOnScreenReleasesThem() async throws {
        let (model, root, workspace) = try model()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var profile = ProfileRecord(); profile.id = "profile"; profile.modelId = "fixture-model"
        profile.baseUrl = "https://fixture.invalid/v1"
        model.profiles = [profile]; model.selectedWorkspaceID = workspace.id; model.profileChoice = profile.id
        model.chats = (0..<4).map { ChatRecord(id: "sel-\($0)", workspaceID: workspace.id, title: "Chat \($0)", path: nil, profileID: profile.id) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        var freed: (() -> Bool)?
        var hosted: NSHostingView<ConversationPane>?
        for index in 0..<4 {
            let id = "sel-\(index)"
            await model.select(id)
            let session = try XCTUnwrap(model.displays[id])
            session.messages = (0..<20).map { row in
                TranscriptMessage(id: "m\(row)", role: row.isMultiple(of: 2) ? "user" : "assistant",
                                  text: "Row \(row). " + String(repeating: "some prose that wraps. ", count: 4))
            }
            let record = try XCTUnwrap(model.chats.first { $0.id == id })
            let pane = ConversationPane(model: model, session: session, chat: record, paneWidth: 1_000)
            if let hosted { hosted.rootView = pane } else {
                hosted = NSHostingView(rootView: pane); window.contentView = hosted
            }
            if index == 0 { weak var first = session; freed = { first == nil } }
            await settle(try XCTUnwrap(hosted), window, turns: 30)
        }
        model.displays["sel-0"] = nil
        await settle(try XCTUnwrap(hosted), window, turns: 60)
        XCTAssertTrue(freed?() == true, "selecting away left the first chat held with only the pane on screen")
    }

    /// The whole pane — transcript, composer, queue panel, live bar — shown
    /// one chat after another without being rebuilt, as the shell shows it.
    @MainActor func testTheWholePaneReleasesTheChatTheReaderLeft() async throws {
        let (model, root, workspace) = try model()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        weak var left: SessionDisplay?
        var hosted: NSHostingView<ConversationPane>!
        do {
            let (record, session) = chat("pane-first", in: workspace)
            left = session
            model.chats = [record]; model.displays[record.id] = session
            hosted = NSHostingView(rootView: ConversationPane(model: model, session: session, chat: record, paneWidth: 1_000))
            window.contentView = hosted
            window.makeKeyAndOrderFront(nil)
            await settle(hosted, window)
            XCTAssertNotNil(left)
        }
        do {
            let (record, session) = chat("pane-second", in: workspace)
            model.chats.append(record); model.displays[record.id] = session
            hosted.rootView = ConversationPane(model: model, session: session, chat: record, paneWidth: 1_000)
            await settle(hosted, window, turns: 60)
        }
        model.displays["pane-first"] = nil
        model.chats.removeAll { $0.id == "pane-first" }
        await settle(hosted, window, turns: 40)
        XCTAssertNil(left, "the whole pane is still holding the chat the reader left")
    }
}


/// One part of the pane at a time, chosen by the model.
private struct SelectedTranscriptOnly: View {
    @ObservedObject var model: WorkspaceModel
    var realActions = false
    var loadsToolInputs = false
    var body: some View {
        if let session = model.selected {
            NativeTranscriptView(session: session, state: session.state,
                                 actions: realActions ? TranscriptActions(inspect: { model.showMessageDetail(session.id, messageID: $0) },
                                                                          edit: { model.editMessage($0, sessionID: session.id) },
                                                                          copyMessage: { _ in _ = session.presentedMessages.count },
                                                                          stop: { model.stop(sessionID: session.id) },
                                                                          retry: { _ = session.id })
                                                      : TranscriptActions(),
                                 onAnchorChanged: realActions ? { anchor in session.scrollAnchor = anchor } : { _ in },
                                 onReadReply: { _, _ in }, onLoadEarlier: { _ in })
                .task(id: loadsToolInputs ? session.id : "") {
                    guard loadsToolInputs else { return }
                    session.toolInputs.load = { [weak model, weak session] messageID, callID in
                        guard let model, let session else { throw HostError.failure("This conversation is gone") }
                        return try await model.toolInput(sessionID: session.id, messageID: messageID, callID: callID)
                    }
                }
        }
    }
}
private struct SelectedComposerOnly: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        if let session = model.selected { ComposerInput(model: model, session: session, paneWidth: 1_000) }
    }
}
private struct SelectedFooterOnly: View {
    @ObservedObject var model: WorkspaceModel
    var realAction = false
    var body: some View {
        if let session = model.selected {
            MetricsFooter(model: model, session: session, contextWindow: nil, outputReserve: nil, compact: false) { [model, realAction, id = session.id] in
                if realAction { model.inspect(id) }
            }
        }
    }
}

private struct SelectedPaneParts: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        if let session = model.selected {
            VStack(spacing: 0) {
                NativeTranscriptView(session: session, state: session.state, actions: TranscriptActions())
                ComposerInput(model: model, session: session, paneWidth: 1_000)
                MetricsFooter(model: model, session: session, contextWindow: nil, outputReserve: nil, compact: false) {}
            }
        }
    }
}

/// The card the pane puts over an empty chat, shown the way the pane shows
/// it: put up while the chat has no messages, taken down when they arrive.
private struct SelectedTranscriptWithStarterCard: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        if let session = model.selected, let chat = model.chat {
            NativeTranscriptView(session: session, state: session.state, actions: TranscriptActions())
                .overlay(alignment: .top) {
                    ZStack {
                        if session.messages.isEmpty {
                            StarterPanel(model: model, chat: chat, sessionID: session.id).transition(.opacity)
                        }
                    }.piAnimation(PiMotion.quick, value: session.messages.isEmpty)
                }
        }
    }
}
