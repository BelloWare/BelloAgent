import AppKit
import XCTest
@testable import PiApp

final class SubagentPerformanceTests: XCTestCase, SerialTestLane {
    @MainActor func testFiftyKilobyteMarkdownResultInALongChatKeepsTheMainThreadResponsive() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("agent-markdown-performance-" + UUID().uuidString)
        let fixture = try SubagentGalleryFixture(root: root)
        registerWorkspaceFixtureTeardown(fixture.model, root: root)
        defer { fixture.close(); TranscriptLayoutClock.recording = false }
        fixture.show("completed")
        let history = (0..<200).flatMap { index in [TranscriptMessage(id: "user-\(index)", role: "user", text: "Question \(index)"),
            TranscriptMessage(id: "answer-\(index)", role: "assistant", text: "A settled reply.")] }
        fixture.parent.messages = history + fixture.parent.messages
        await fixture.settle()
        _ = await fixture.model.revealInTranscript(sessionID: fixture.parent.id, messageID: "reply", toolCallID: "call-0")
        await fixture.settle()
        let source = "# Cold result \(UUID().uuidString)\n\n" + String(repeating: "- The **parser** keeps `token` boundaries and [references](https://example.test).\n", count: 680)
        let output = WireValue.object(["status": .string("completed"), "text": .string(source)]).pretty
        XCTAssertGreaterThan(source.utf8.count, 50_000)
        let computations = fixture.model.sidebarIndex.computations
        TranscriptLayoutClock.reset(); TranscriptLayoutClock.recording = true
        var heartbeat = ProcessInfo.processInfo.systemUptime, worstGap = 0.0
        var markdownSeconds = 0.0, worstMarkdownBatch = 0.0
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2))
                let now = ProcessInfo.processInfo.systemUptime
                worstGap = max(worstGap, (now - heartbeat) * 1000); heartbeat = now
                let markdown = TranscriptLayoutClock.markdownUpdateSeconds + TranscriptLayoutClock.markdownLayoutSeconds
                worstMarkdownBatch = max(worstMarkdownBatch, (markdown - markdownSeconds) * 1000); markdownSeconds = markdown
            }
        }
        defer { monitor.cancel() }
        await Task.yield(); heartbeat = ProcessInfo.processInfo.systemUptime
        let before = ProcessInfo.processInfo.systemUptime
        var message = fixture.parent.messages.last!
        message.tools![0].output = output
        fixture.parent.messages[fixture.parent.messages.count - 1] = message
        var worst = 0.0, iterations = 0
        try await eventually("Prepared large Markdown result", timeout: .seconds(20)) {
            let start = ProcessInfo.processInfo.systemUptime
            fixture.content.layoutSubtreeIfNeeded(); fixture.window.displayIfNeeded()
            worst = max(worst, (ProcessInfo.processInfo.systemUptime - start) * 1000); iterations += 1
            return ConversationPaneTests.views(TranscriptAgentMarkdown.self, in: fixture.content.pane).contains { $0.source == source && $0.prepared }
        }
        let body = try XCTUnwrap(ConversationPaneTests.views(TranscriptAgentMarkdown.self, in: fixture.content.pane).first { $0.source == source })
        let coldUpdate = TranscriptLayoutClock.markdownUpdateSeconds * 1000
        let coldLayout = TranscriptLayoutClock.markdownLayoutSeconds * 1000
        let layouts = body.markdown.layoutPasses
        TranscriptLayoutClock.reset(); TranscriptLayoutClock.recording = true
        for _ in 0..<30 { fixture.content.needsLayout = true; fixture.content.layoutSubtreeIfNeeded(); fixture.window.displayIfNeeded() }
        XCTAssertEqual(body.markdown.layoutPasses, layouts, "A settled result keeps its width layout")
        XCTAssertEqual(fixture.model.sidebarIndex.computations, computations)
        XCTAssertLessThan(TranscriptLayoutClock.measuredRows, 5, "The 400 settled messages are not remeasured")
        XCTAssertLessThan(worstGap, 100, "The main run loop, including the fixture window, stays responsive")
        XCTAssertLessThan(worstMarkdownBatch, 50, "Markdown adoption and layout yield within the frame budget")
        XCTAssertLessThan(worst, 50, "A 50 KB result must not block a frame for parsing or full text layout")
        print("PERF agent-markdown bytes=\(source.utf8.count) coldMs=\((ProcessInfo.processInfo.systemUptime - before) * 1000) worstDrawMs=\(worst) heartbeatMs=\(worstGap) markdownBatchMs=\(worstMarkdownBatch) updateMs=\(coldUpdate) layoutMs=\(coldLayout) draws=\(iterations) measures=\(body.markdown.layoutPasses)")
        await Task.yield(); heartbeat = ProcessInfo.processInfo.systemUptime; worstGap = 0; worst = 0; worstMarkdownBatch = 0
        let expanding = ProcessInfo.processInfo.systemUptime
        body.setExpanded(true)
        try await eventually("Complete expanded Markdown", timeout: .seconds(30)) {
            let start = ProcessInfo.processInfo.systemUptime
            fixture.content.layoutSubtreeIfNeeded(); fixture.window.displayIfNeeded()
            worst = max(worst, (ProcessInfo.processInfo.systemUptime - start) * 1000)
            return body.isComplete
        }
        monitor.cancel(); await monitor.value
        XCTAssertEqual(body.markdown.textView.string, Self.rendered(source))
        XCTAssertLessThan(worstGap, 100, "Expanding the entire result must yield between native text batches")
        XCTAssertLessThan(worstMarkdownBatch, 50)
        XCTAssertLessThan(worst, 50)
        print("PERF agent-markdown-expanded ms=\((ProcessInfo.processInfo.systemUptime - expanding) * 1000) worstDrawMs=\(worst) heartbeatMs=\(worstGap) markdownBatchMs=\(worstMarkdownBatch)")
    }
    @MainActor private static func rendered(_ source: String) -> String { SubagentMarkdownTests.assistant(source).textView.string }
    @MainActor func testFourProgressCardsDoNotRebuildTheSidebarOrSettledTranscript() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("subagent-performance-" + UUID().uuidString)
        let fixture = try SubagentGalleryFixture(root: root)
        registerWorkspaceFixtureTeardown(fixture.model, root: root)
        defer { fixture.close(); TranscriptLayoutClock.recording = false }
        fixture.show("parallel-queued")
        let history = (0..<200).flatMap { index in
            [TranscriptMessage(id: "user-\(index)", role: "user", text: "Question \(index)"),
             TranscriptMessage(id: "answer-\(index)", role: "assistant", text: "A settled answer with stable geometry. It must not be measured for another task’s progress.")]
        }
        fixture.parent.messages = history + fixture.parent.messages
        await fixture.settle()
        let revealed = await fixture.model.revealInTranscript(sessionID: fixture.parent.id, messageID: "reply", toolCallID: "call-0")
        XCTAssertTrue(revealed); await fixture.settle()
        let computations = fixture.model.sidebarIndex.computations
        let sidebarIDs = fixture.content.sidebar.list.contents.entries.map(\.id)
        TranscriptLayoutClock.reset(); TranscriptLayoutClock.recording = true
        var samples: [Double] = []
        let changes = 20
        for update in 0..<changes {
            let began = ProcessInfo.processInfo.systemUptime
            var row = fixture.parent.messages.last!
            for index in row.tools!.indices {
                row.tools![index].subagent?.progress?.preview = "Stable progress \(update): checked boundary \(index)."
                row.tools![index].subagent?.progress?.elapsedMs = Double(1000 + update * 250)
            }
            fixture.parent.messages[fixture.parent.messages.count - 1] = row
            for _ in 0..<5 { await Task.yield(); fixture.content.layoutSubtreeIfNeeded(); fixture.window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(2)) }
            samples.append((ProcessInfo.processInfo.systemUptime - began) * 1000)
        }
        let measured = TranscriptLayoutClock.measuredRows, markdown = TranscriptLayoutClock.markdownMeasures
        XCTAssertEqual(fixture.model.sidebarIndex.computations, computations, "Token progress must not invalidate sidebar organization")
        XCTAssertEqual(fixture.content.sidebar.list.contents.entries.map(\.id), sidebarIDs)
        XCTAssertLessThan(measured, changes * 12, "Progress must not measure the 400 settled rows")
        XCTAssertLessThan(markdown, changes * 4, "Unchanged answer text must retain its markdown geometry")
        TranscriptLayoutClock.recording = false
        let began = ProcessInfo.processInfo.systemUptime
        fixture.model.selectedID = fixture.child.id; fixture.model.focusedSessionID = fixture.child.id; fixture.model.selected = fixture.child
        fixture.content.pane.show(session: fixture.child, chat: fixture.model.record(fixture.child.id)!)
        await fixture.settle()
        fixture.model.selectedID = fixture.parent.id; fixture.model.focusedSessionID = fixture.parent.id; fixture.model.selected = fixture.parent
        fixture.content.pane.show(session: fixture.parent, chat: fixture.model.record(fixture.parent.id)!)
        await fixture.model.revealSubagentCall(fixture.model.record(fixture.child.id)!.delegation!)
        await fixture.settle()
        let switched = (ProcessInfo.processInfo.systemUptime - began) * 1000
        let clip = fixture.content.pane.transcript.scrollView.contentView
        let card = try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeActionRow.self, in: fixture.content.pane).first { $0.tool?.id == "call-0" })
        let frame = card.convert(card.bounds, to: clip)
        XCTAssertTrue(clip.bounds.intersects(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 24)), "Back restores the originating tool card after estimated history geometry changes")
        let ordered = samples.sorted()
        print("PERF subagents progress20 p50Ms=\(ordered[ordered.count / 2]) maxMs=\(ordered[ordered.count - 1]) measuredRows=\(measured) markdownMeasures=\(markdown) sidebarComputations=\(fixture.model.sidebarIndex.computations - computations) switchRoundTripMs=\(switched)")
    }
}
