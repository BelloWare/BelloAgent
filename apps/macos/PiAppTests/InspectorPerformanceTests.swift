import XCTest
import AppKit
import SwiftUI
@testable import PiApp

/// The main thread's CPU time between two ticks of a 1 ms timer on the main
/// queue: each gap is one step of other main-thread work — a continuation, a
/// publish, a layout pass. CPU time, not wall time, so a busy machine that
/// deschedules the test process cannot pass for a slow step.
@MainActor final class MainThreadStepProbe {
    private var timer: DispatchSourceTimer?
    private var last: UInt64 = 0
    private(set) var longest: Double = 0
    private(set) var steps = 0
    /// The five longest steps, longest first.
    private(set) var top: [Double] = []
    func start() {
        last = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                let step = Double(now &- self.last) / 1_000_000
                self.longest = max(self.longest, step)
                if self.top.count < 5 || step > (self.top.last ?? 0) { self.top = Array((self.top + [step]).sorted(by: >).prefix(5)) }
                self.last = now; self.steps += 1
            }
        }
        timer.resume(); self.timer = timer
    }
    func stop() { timer?.cancel(); timer = nil }
}

/// A 30 MB request body read and parsed for the Inspector's Conversation tab
/// while the main thread stays responsive, and nothing read while the window
/// is hidden. Serial: the step budget is a timing assertion.
final class InspectorPerformanceTests: XCTestCase, SerialTestLane {
    /// About 30 MB: 3,000 user items of 10 KB each.
    static let body: Data = {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 227)
        let items = (0..<3_000).map { #"{"type":"message","role":"user","content":[{"type":"input_text","text":"item \#($0) \#(text)"}]}"# }
        return Data((#"{"model":"gpt-5.4","stream":true,"instructions":"You are Bello Agent.","input":["# + items.joined(separator: ",") + "]}").utf8)
    }()

    @MainActor func testAThirtyMegabyteBodyIsParsedOffTheMainThreadInShortSteps() async throws {
        let body = Self.body, small = InspectorRequestModelTests.requestBody(5)
        XCTAssertGreaterThan(body.count, 30_000_000)
        let root = scratchRoot("inspector-performance"); defer { try? FileManager.default.removeItem(at: root) }
        let inspector = SessionInspectorModel(scope: SessionUsageScope(sessionID: "session", workspaceID: "project"), title: "Performance",
                                              archive: PayloadArchive(root: root), workspace: nil,
                                              usageLoader: { _, _, _ in throw CaptureFailure.unavailable }, cache: InspectorDocumentCache())
        let request = inspector.request
        var reads = 0
        request.metadataOverride = { _ in ["outcome": .string("completed")] }
        request.sourceOverride = { row, kind in
            guard kind == "request" else { return nil }
            let bytes = row.id == "big" ? body : small
            return CapturedBodySource(metadata: { CapturedBodyMetadata(body: ["state": .string("complete"), "retainedBytes": .number(Double(bytes.count))], hash: nil) },
                                      page: { _ in throw CaptureFailure.unavailable },
                                      whole: { progress in
                if row.id == "big" { reads += 1 }
                // As the archive does: the bytes are assembled away from the main actor.
                let data = await Task.detached { bytes }.value
                progress(data.count, data.count)
                return data
            })
        }
        func row(_ id: String) -> InspectorRequestRow {
            InspectorRequestRow(id: id, wall: 1, turn: "t", purpose: "turn", api: "openai-responses", alias: "ui-fixture", model: "gpt-5.4", outcome: "completed")
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: InspectorRequestPage(inspector: inspector, request: request, compact: false).frame(width: 1_100, height: 820))
        window.orderFront(nil)
        defer { request.setActive(false); window.contentView = nil; window.close() }
        func outline() -> NSOutlineView? {
            func find(_ view: NSView) -> NSOutlineView? { (view as? NSOutlineView) ?? view.subviews.lazy.compactMap(find).first }
            return window.contentView.flatMap(find)
        }
        func wait(_ what: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(120)
            while !condition() {
                guard Date() < deadline else { XCTFail("Timed out waiting for " + what); throw CancellationError() }
                if case .failed(let message) = request.conversation { XCTFail(message); throw CancellationError() }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        // The page, its header and its outline drawn once for a small request:
        // what is measured is the load of a large body, not the page's first
        // appearance.
        request.setActive(true)
        request.open(row("small"), predecessor: nil, previousLabel: nil)
        try await wait("the small request") { request.conversation.value?.items.count == 5 && (outline()?.numberOfRows ?? 0) > 0 }
        try await Task.sleep(for: .milliseconds(400))

        // Opt-in (PI_INSPECTOR_SAMPLE=<file>): where the main thread spends the load, as `sample` sees it.
        var sampler: Process?
        if let path = testEnvironment("PI_INSPECTOR_SAMPLE") {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "4", "1", "-mayDie", "-file", path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); sampler = process
            try await Task.sleep(for: .milliseconds(500))
        }
        let probe = MainThreadStepProbe()
        probe.start()
        let started = Date()
        request.open(row("big"), predecessor: nil, previousLabel: nil)
        // On screen: fifteen pages of two hundred items, the last page open.
        try await wait("the 30 MB body in the outline") {
            request.conversation.value?.items.count == 3_000 && request.delta != nil && (outline()?.numberOfRows ?? 0) >= 215
        }
        // A few more frames for the rows to draw.
        try await Task.sleep(for: .milliseconds(300))
        probe.stop()
        if let sampler { await Task.detached { sampler.waitUntilExit() }.value }
        let document = try XCTUnwrap(request.conversation.value)
        XCTAssertEqual(document.items.count, 3_000)
        XCTAssertLessThan(outline()?.numberOfRows ?? .max, 400, "Thousands of items are shown a page at a time")
        XCTAssertEqual(reads, 1, "The body is read once")
        print(String(format: "PERF inspector 30 MB body: longest main-thread step %.2f ms over %d steps (next %@), %.2f s to the outline",
                     probe.longest, probe.steps, probe.top.dropFirst().map { String(format: "%.1f", $0) }.joined(separator: ", "), Date().timeIntervalSince(started)))
        XCTAssertGreaterThan(probe.steps, 10, "The main thread kept answering while the body was read and parsed")
        // A Release build (the app as shipped) is held to a frame. Debug Swift
        // draws the first rows several times slower, so it is held to what
        // still proves the point: the parse, which takes seconds, never runs
        // on the main thread (TestSeams.swift, `releaseBudget`).
        #if PI_RELEASE_TESTS
        let budget = 16.0
        #else
        let budget = 100.0
        #endif
        XCTAssertLessThan(probe.longest, budget, "No main-thread step of the load takes more than \(budget) ms: the parse is off the main thread")

        // Hidden: nothing is read, whatever the reader switches to.
        request.setActive(false)
        let hidden = reads
        request.tab = .response; request.tab = .conversation; request.loadLatest()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reads, hidden, "A hidden window reads nothing")
    }

    /// The whole window, hidden: its polls and reads stop, and they start
    /// again when it is back on screen. (Minimised or covered, the window's
    /// occlusion says the same; ordering it out is the quickest way there.)
    @MainActor func testAHiddenInspectorStopsReading() async throws {
        let root = scratchRoot("inspector-hidden"); defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root)
        try await archive.configure(quota: 1 << 20, bodyRetention: 100, metricRetention: 1_000_000)
        let inspector = SessionInspectorModel(scope: SessionUsageScope(sessionID: "session", workspaceID: "project"), title: "Hidden",
                                              archive: archive, workspace: nil, usageLoader: { _, _, _ in throw CaptureFailure.unavailable },
                                              cache: InspectorDocumentCache())
        inspector.pollInterval = .milliseconds(30); inspector.runningPollInterval = .milliseconds(30)
        let controller = SessionInspectorWindowController(inspector: inspector)
        defer { controller.close() }
        controller.present(.overview)
        func wait(_ what: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !condition() {
                guard Date() < deadline else {
                    XCTFail("Timed out waiting for " + what)
                    throw CancellationError()
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await wait("the first read") { inspector.indexReads >= 1 }
        XCTAssertNil(inspector.failure, inspector.failure ?? "")
        controller.window?.orderOut(nil)
        try await wait("the window to leave the screen") { !inspector.visible }
        let reads = inspector.indexReads
        inspector.refresh()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(inspector.indexReads, reads, "A hidden Inspector neither polls nor reads")
        controller.window?.orderFront(nil)
        try await wait("the window to come back") { inspector.visible }
        inspector.refresh()
        try await wait("a read once back on screen") { inspector.indexReads > reads }
        try await archive.close()
    }
}
