import AppKit
import XCTest
@testable import PiApp

final class SubagentPerformanceTests: XCTestCase, SerialTestLane {
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
