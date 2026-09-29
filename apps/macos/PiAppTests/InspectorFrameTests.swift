import XCTest
import SwiftUI
import AppKit
import Combine
@testable import PiApp

/// The Session Inspector as the reader meets it, on a chat of three hundred
/// requests over seventy-five turns, the last of which sent a 5 MB request.
/// Each step is timed on the main thread's own clock, its longest step is the
/// hitch a reader would see, SwiftUI's layout cycles are counted, and so are
/// the Overview's ledger rows built. Serial: the figures are timed.
final class InspectorFrameTests: XCTestCase, SerialTestLane {
    struct Step: CustomStringConvertible {
        var ready = 0.0, cpu = 0.0, longest = 0.0, cycles = 0, overviews = 0, ledgerRows = 0
        var description: String {
            String(format: "ready %.0f ms, main thread %.0f ms, longest step %.1f ms, %d cycles, %d overview bodies, %d ledger rows built",
                   ready, cpu, longest, cycles, overviews, ledgerRows)
        }
    }

    @MainActor private func mainThreadMilliseconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000 }

    @MainActor private func step(_ name: String, _ window: NSWindow, settle: Double = 0.6, _ change: () -> Void, until ready: () -> Bool) async throws -> Step {
        var result = Step()
        let probe = MainThreadStepProbe()
        // Opt-in (PI_INSPECTOR_STEP_SAMPLE=<step>=<file>): where the main thread spends one step, as `sample` sees it.
        var sampler: Process?
        if let request = testEnvironment("PI_INSPECTOR_STEP_SAMPLE"), request.hasPrefix(name + "=") {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "\(Int(settle) + 3)", "1", "-mayDie", "-file", String(request.dropFirst(name.count + 1))]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); sampler = process
            try await Task.sleep(for: .milliseconds(1_500))
        }
        defer { if let sampler { sampler.waitUntilExit() } }
        SessionStatsRenderCount.reset()
        result.cycles = try await layoutCycles {
            probe.start()
            let cpu = mainThreadMilliseconds(), started = ProcessInfo.processInfo.systemUptime
            change()
            while !ready() {
                guard ProcessInfo.processInfo.systemUptime - started < 60 else { XCTFail("Timed out"); break }
                try await Task.sleep(for: .milliseconds(2))
            }
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            result.ready = (ProcessInfo.processInfo.systemUptime - started) * 1000
            try await Task.sleep(for: .milliseconds(Int(settle * 1000)))
            result.cpu = mainThreadMilliseconds() - cpu
            probe.stop()
        }
        result.longest = probe.longest
        result.overviews = SessionStatsRenderCount.panels
        result.ledgerRows = SessionStatsRenderCount.ledgerRows
        return result
    }

    @MainActor private func scroll(_ scroll: NSScrollView, in window: NSWindow, through distance: CGFloat) async throws -> (mean: Double, worst: Double, cycles: Int) {
        var total = 0.0, worst = 0.0, steps = 0
        let cycles = try await layoutCycles {
            var y: CGFloat = 0
            while y < distance {
                let started = mainThreadMilliseconds()
                scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let cost = mainThreadMilliseconds() - started
                total += cost; worst = max(worst, cost); steps += 1
                y += 10
                await Task.yield()
                if steps % 16 == 0 { try await Task.sleep(for: .milliseconds(1)) }
            }
        }
        return (total / Double(max(1, steps)), worst, cycles)
    }

    @MainActor private func footprint() -> Double {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) }
        }
        return result == 0 ? Double(usage.ri_phys_footprint) / 1_048_576 : 0
    }

    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }

    /// A request of about 5 MB: five hundred user items of 10 KB each.
    static let body: Data = {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 227)
        let items = (0..<500).map { #"{"type":"message","role":"user","content":[{"type":"input_text","text":"item \#($0) \#(text)"}]}"# }
        return Data((#"{"model":"gpt-5.4","stream":true,"instructions":"You are Bello Agent.","input":["# + items.joined(separator: ",") + "]}").utf8)
    }()

    @MainActor func testTheInspectorOverALongChat() async throws {
        SessionInspectorWindows.shared.closeAll()
        let pane = try await SessionStatsPopoverTests.seededPane(requests: 300)
        defer { SessionInspectorWindows.shared.closeAll(); pane.close() }
        // The last turn's big request, its body kept.
        let big = UUID().uuidString, body = Self.body
        let sample = SessionStatsFixture.request(301, turn: "t76", input: 1_250_000, cached: 1_000_000, output: 900)
        var metadata = SessionStatsPopoverTests.metadata(for: sample, session: pane.chat.id)
        metadata["attemptId"] = .string(big); metadata["mode"] = .string("persist")
        try await pane.model.traces.begin(metadata, workspace: pane.chat.workspaceID)
        var offset = 0
        while offset < body.count {
            let end = min(offset + 32_768, body.count)
            try await pane.model.traces.append(attempt: big, kind: "request", offset: offset, bytes: body.subdata(in: offset..<end))
            offset = end
        }
        metadata["request"] = .object(["observedBytes": .number(Double(body.count))])
        try await pane.model.traces.finish(metadata)
        try await SessionStatsPopoverTests.refreshFooter(pane)
        await pane.settle(4)
        let before = footprint()

        pane.model.openInspector(session: pane.chat.id, focus: .overview)
        let controller = try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID: pane.chat.id))
        let inspector = controller.inspector, window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1_200, height: 860))
        let open = try await step("open", window, settle: 1.0, {}) {
            inspector.indexLoaded && inspector.index.requests.count >= 301 && inspector.timeCharts.historyLoaded && inspector.usage.snapshot != nil
        }
        print("PERF inspector: open at the overview \(open), \(inspector.index.requests.count) requests in \(inspector.index.turns.count) turns")
        let scrolls = descendants(NSScrollView.self, in: window.contentView ?? NSView())
        let overviewScroll = try XCTUnwrap(scrolls.max { $0.frame.width < $1.frame.width })
        let overview = try await scroll(overviewScroll, in: window, through: max(0, (overviewScroll.documentView?.frame.height ?? 0) - overviewScroll.contentView.bounds.height))
        print(String(format: "PERF inspector: scrolling the overview %.2f ms a step, worst %.1f ms, %d cycles", overview.mean, overview.worst, overview.cycles))

        // Idle, without the step probe's own timer.
        let quiet = mainThreadMilliseconds()
        try await Task.sleep(for: .seconds(5))
        print(String(format: "PERF inspector: five idle seconds cost the main thread %.0f ms", mainThreadMilliseconds() - quiet))

        // Every turn opened in the navigator, then the navigator scrolled.
        let expand = try await step("expand", window, { for turn in inspector.index.turns where !inspector.expanded.contains(turn.id) { inspector.toggle(turn.id) } }) { true }
        print("PERF inspector: every turn opened \(expand)")
        let navigator = try XCTUnwrap(descendants(NSScrollView.self, in: window.contentView ?? NSView()).min { $0.frame.minX < $1.frame.minX })
        let listed = try await scroll(navigator, in: window, through: min(6_000, max(0, (navigator.documentView?.frame.height ?? 0) - navigator.contentView.bounds.height)))
        print(String(format: "PERF inspector: scrolling the navigator %.2f ms a step, worst %.1f ms, %d cycles (document %.0f)", listed.mean, listed.worst, listed.cycles, navigator.documentView?.frame.height ?? 0))

        // A turn, then the big request's conversation, response and raw bytes.
        let firstTurn = try XCTUnwrap(inspector.index.turns.first { !$0.isOther })
        let turn = try await step("turn", window, { inspector.select(.turn(firstTurn.id)) }) { inspector.page == .turn(firstTurn.id) }
        print("PERF inspector: a turn \(turn)")
        // Each step of the read's progress that is shown lays the page out again.
        var shownProgress = 0
        let watching = inspector.request.$conversation.sink { if case .loading(_, let total) = $0, total > 0 { shownProgress += 1 } }
        let request = try await step("request", window, settle: 1.0, { inspector.select(.request(big)); inspector.request.tab = .conversation }) {
            inspector.request.conversation.value?.items.count == 500
        }
        watching.cancel()
        print("PERF inspector: the 5 MB request's conversation \(request), \(shownProgress) progress steps shown")
        let response = try await step("response", window, { inspector.request.tab = .response }) {
            switch inspector.request.response { case .ready, .failed: true; default: false }
        }
        print("PERF inspector: its response \(response)")
        let raw = try await step("raw", window, settle: 1.5, { inspector.request.tab = .raw }) { true }
        print("PERF inspector: its raw bytes \(raw)")
        let withBody = footprint()

        // Thirty requests back, one ⌘[ at a time, on the Conversation tab.
        inspector.request.tab = .conversation
        let stepping = try await step("stepping", window, settle: 1.0, {
            for _ in 0..<30 { inspector.step(-1); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        }) { true }
        print("PERF inspector: thirty requests back \(stepping)")

        let back = try await step("back", window, { inspector.select(.overview) }) { inspector.page == .overview }
        print("PERF inspector: back to the overview \(back)")
        let close = try await step("close", window, settle: 1.0, { controller.close() }) { !window.isVisible }
        print("PERF inspector: close \(close)")
        try await Task.sleep(for: .milliseconds(500))
        print(String(format: "PERF inspector memory: before %.1f MB, with the 5 MB request %.1f MB, closed %.1f MB", before, withBody, footprint()))

        let steps = [("opening", open.cycles), ("scrolling the overview", overview.cycles), ("opening every turn", expand.cycles),
                     ("scrolling the navigator", listed.cycles), ("a turn", turn.cycles), ("the conversation", request.cycles),
                     ("the response", response.cycles), ("the raw bytes", raw.cycles), ("stepping", stepping.cycles),
                     ("back to the overview", back.cycles), ("closing", close.cycles)]
        for (name, cycles) in steps { XCTAssertEqual(cycles, 0, "Layout cycles: \(name)") }
        // The ledger's forty rows sit under the charts: none of them is
        // built until the reader scrolls down to it. Built with the page,
        // they were most of what opening the Overview cost.
        XCTAssertLessThan(open.ledgerRows, 20, "Opening the Overview builds the ledger rows on screen, not all forty")
        XCTAssertLessThan(back.ledgerRows, 20, "Coming back to the Overview builds the ledger rows on screen, not all forty")
        // A tenth of the body at a time: every step the archive reported used to be shown.
        XCTAssertLessThanOrEqual(shownProgress, 11, "Reading 5 MB shows its progress in tenths")
    }

    /// A read's progress is shown in tenths of the body, and never in steps
    /// of less than 128 KiB; its end is always shown.
    func testAReadShowsItsProgressInTenths() {
        func shown(_ total: Int, page: Int = 32_768) -> [Int] {
            var last = 0, steps: [Int] = []
            for loaded in stride(from: page, through: total + page - 1, by: page).map({ min($0, total) })
            where CapturedBodyReader.progressWorthShowing(loaded, of: total, shown: last) { steps.append(loaded); last = loaded }
            return steps
        }
        let big = shown(5_000_000)
        XCTAssertLessThanOrEqual(big.count, 10); XCTAssertEqual(big.last, 5_000_000)
        let small = shown(400_000)
        XCTAssertLessThanOrEqual(small.count, 4, "Steps of 128 KiB at least: \(small)"); XCTAssertEqual(small.last, 400_000)
        XCTAssertEqual(shown(20_000), [20_000], "A body of one page shows its end")
        XCTAssertFalse(CapturedBodyReader.progressWorthShowing(5_000_000, of: 5_000_000, shown: 5_000_000), "The end is shown once")
    }
}
