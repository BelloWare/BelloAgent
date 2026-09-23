import XCTest
import SwiftUI
@testable import PiApp

final class TurnInfoTests: XCTestCase {
    @MainActor func testLiveDurationUsesUptimeAndCalendarStampsRemainSeparate() throws {
        let wall = 1_789_992_600_000.0, uptime = 432_100_000.0
        var task = TaskPresentationRecord(rootID:"u", executionID:"e", startedAt:uptime, startedAtUnixMs:wall)
        task.phase = "model"
        let turn = TaskTranscriptPlan.summary([],task:task)
        // The old code subtracted uptime from epoch time (about 497,139 h).
        for date in [wall + 12500, wall - 86_400_000, wall + 86_400_000] {
            let live = TurnInfoPresentation.live(turn,at:Date(timeIntervalSince1970:date/1000),uptimeMs:uptime+12500)
            XCTAssertEqual(live.elapsedMs,12500)
            XCTAssertEqual(TranscriptActivity.formatDuration(try XCTUnwrap(live.elapsedMs)),"13s")
            XCTAssertEqual(live.startedAt,wall)
        }
        task.endedAt = uptime + 12500; task.endedAtUnixMs = wall + 12500; task.outcome = "completed"
        let completed = TaskTranscriptPlan.summary([],task:task)
        XCTAssertEqual(completed.elapsedMs,12500); XCTAssertEqual(completed.endedAt,wall+12500)
        XCTAssertNil(completed.liveStartedUptimeMs)
        // Legacy receipts have the same uptime duration but no calendar stamps.
        task.startedAtUnixMs = nil; task.endedAtUnixMs = nil
        let legacy = TaskTranscriptPlan.summary([],task:task)
        XCTAssertEqual(legacy.elapsedMs,12500); XCTAssertNil(legacy.startedAt); XCTAssertNil(legacy.endedAt)
        XCTAssertFalse(TurnInfoPresentation.rows(legacy).contains { $0.name == "Started" || $0.name == "Finished" })
    }
    @MainActor func testInterruptedTurnDoesNotInventDurationOrFinishTime() throws {
        let session = SessionDisplay(id:"s")
        let active = TaskPresentationRecord(rootID:"u",executionID:"e",startedAt:432_100_000,startedAtUnixMs:1_789_992_600_000)
        session.taskPresentation = TaskPresentationProjection(sessionID:"s",epoch:"epoch",timeline:"root",sequence:1,sourceRevision:"1",active:active,recent:[])
        session.settleInterruptedRows()
        let settled = try XCTUnwrap(session.taskPresentation?.recent.last)
        XCTAssertTrue(settled.valid); XCTAssertEqual(settled.outcome,"interrupted")
        let turn = TaskTranscriptPlan.summary([],task:settled)
        XCTAssertNil(turn.elapsedMs); XCTAssertNil(turn.endedAt)
        XCTAssertEqual(TurnInfoPresentation.rows(turn).first { $0.name == "Duration" }?.value,"Unavailable")
        // Existing interrupted receipts may already have the mixed-clock end.
        var old = settled; old.endedAt = 1_789_992_600_000
        XCTAssertNil(TaskTranscriptPlan.summary([],task:old).elapsedMs)
    }
    private func record() -> TaskPresentationRecord {
        TaskPresentationRecord(rootID:"u",executionID:"e",startedAt:1000)
    }
    private func message(_ id: String, role: String = "assistant", execution: String = "e", cost: Double = 0.000001) -> TranscriptMessage {
        var value = TranscriptMessage(id:id,role:role,text:"Answer",state:"complete",turn:"u",taskRootID:"u",taskExecutionID:execution)
        var a = GatewayTotals(); a.requests = 1; a.costSamples = 1; a.costUSD = cost
        a.tokens = GatewayTokenTotals(input:38,output:302,total:340,inputSamples:1,outputSamples:1,samples:1,reasoning:253,reasoningSamples:1)
        a.cacheReadTokens = 0; a.cacheReadSamples = 1; a.reasoningCostUSD = 0; a.reasoningCostSamples = 1
        a.cacheHits = 1; value.accounting = a; value.modelMs = 2000
        return value
    }
    func testLiveAccountingFollowsExactExecutionAndMovesFromUserToAssistantOnce() throws {
        var task = record(); task.phase = "model"
        let projection = TaskPresentationProjection(sessionID:"s",epoch:"epoch",timeline:"root",sequence:1,sourceRevision:"1",active:task,recent:[])
        var user = message("u",role:"user")
        let old = message("old",execution:"earlier",cost:999)
        let before = try XCTUnwrap(TaskTranscriptPlan.live(projection,messages:[old,user]))
        XCTAssertEqual(before.accounting.costUSD,0.000001); XCTAssertEqual(before.accounting.total,340)
        user.accounting = nil
        var reply = message("a"); reply.state = "streaming"
        let after = try XCTUnwrap(TaskTranscriptPlan.live(projection,messages:[old,user,reply]))
        XCTAssertEqual(after.accounting.costUSD,before.accounting.costUSD); XCTAssertEqual(after.accounting.total,340)
        let next = message("b",cost:0)
        let round = try XCTUnwrap(TaskTranscriptPlan.live(projection,messages:[old,user,reply,next]))
        XCTAssertEqual(round.accounting.total,680); XCTAssertEqual(round.accounting.reasoning,506)
        XCTAssertEqual(round.accounting.costUSD,0.000001); XCTAssertEqual(round.accounting.costSamples,2)
        let missing = try XCTUnwrap(TaskTranscriptPlan.live(projection,messages:[old]))
        XCTAssertNil(missing.accounting.costUSD); XCTAssertEqual(TurnInfoPresentation.costLabel(missing),"Pending")
    }
    @MainActor func testInlineAndTableKeepZeroMicroCostCoverageAndTokenSubsets() throws {
        var task = record(); task.outcome = "completed"; task.phase = "terminal"; task.endedAt = 4000; task.replies = 1
        let turn = TaskTranscriptPlan.summary([message("u",role:"user",cost:0)],task:task)
        XCTAssertEqual(TurnInfoPresentation.costLabel(turn),"$0")
        XCTAssertTrue(TurnInfoPresentation.inlineFigures(turn).contains("In 38"))
        XCTAssertTrue(TurnInfoPresentation.inlineFigures(turn).contains("Out 302"))
        XCTAssertTrue(TurnInfoPresentation.inlineFigures(turn).contains("Cached 0"))
        XCTAssertTrue(TurnInfoPresentation.inlineFigures(turn).contains("Reasoning 253"))
        let rows = Dictionary(uniqueKeysWithValues:TurnInfoPresentation.rows(turn).map { ($0.name,$0) })
        XCTAssertEqual(rows["Total tokens"]?.value,"340")
        XCTAssertEqual(rows["Reasoning tokens (in output)"]?.value,"253")
        XCTAssertEqual(rows["Total cost"]?.value,"$0 USD")
        XCTAssertEqual(rows["Reasoning cost (in total)"]?.value,"$0 USD")
        XCTAssertEqual(rows["Total cost"]?.coverage,"1/1 requests")
        XCTAssertEqual(rows["Cache-write tokens"]?.value,"Unreported")
        let micro = TaskTranscriptPlan.summary([message("a")],task:task)
        XCTAssertTrue(TurnInfoPresentation.inlineFigures(micro).contains("Cost $0.000001"))
        XCTAssertTrue(TurnLineView.copyText(micro).contains("$0.000001"))
        var partial = micro; partial.accounting.requests = 2
        XCTAssertTrue(TurnInfoPresentation.inlineFigures(partial).contains("Cost $0.000001 (1/2 reported)"))
    }
    /// A failed turn's error is said once: on the card at the foot of the
    /// chat, which offers Retry. The turn's report above that card used to
    /// repeat the same words. An older failed turn, whose error no longer has
    /// a card, keeps the words in its report — and Copy Turn Info keeps them
    /// either way.
    @MainActor func testAFailedTurnSaysItsErrorOnce() throws {
        let error = "Provider returned HTTP 500: upstream overloaded"
        let session = SessionDisplay(id: "failing")
        var task = TaskPresentationRecord(rootID: "u1", executionID: "e1", startedAt: 1_000)
        task.outcome = "failed"; task.phase = "terminal"; task.endedAt = 4_000; task.detail = error
        task.lastSourceID = "a1"; task.replies = 1
        session.messages = [TranscriptMessage(id: "u1", role: "user", text: "Run the tests", state: "complete", turn: "u1", taskRootID: "u1", taskExecutionID: "e1"),
                            TranscriptMessage(id: "a1", role: "assistant", text: "Running them now.", state: "complete", turn: "u1", taskRootID: "u1", taskExecutionID: "e1")]
        session.taskPresentation = TaskPresentationProjection(sessionID: "failing", epoch: "epoch", timeline: "root", sequence: 1,
                                                              sourceRevision: "1", active: nil, recent: [task])
        session.observeRunState(["state": .string("error"), "runStatus": .string("failed"), "preflightError": .string(error)])
        func shown(_ items: [TranscriptItem]) -> [String] {
            items.compactMap { item in
                switch item {
                case .message(let message): return message.text == error ? "card " + message.id : nil
                case .block(let block):
                    guard let turn = block.turn, StableTurnSummaryView.shownNotice(turn) == error else { return nil }
                    return "report " + block.key
                }
            }
        }
        let failed = TranscriptActivity.blocks(of: session.presentedMessages, lifecycle: session.taskPresentation)
        XCTAssertEqual(shown(failed), ["card failure:run:failing"], "The error is said once, on the card that offers Retry")
        let summary = try XCTUnwrap(failed.lazy.compactMap { item -> TurnSummary? in if case .block(let block) = item { return block.turn }; return nil }.first)
        XCTAssertTrue(TurnLineView.copyText(summary).contains(error), "Copy Turn Info still carries the turn's error")
        // The next run clears the card; the turn's report is then where the
        // error of that turn is read.
        session.observeRunState(["state": .string("idle"), "runStatus": .string("idle")])
        let later = TranscriptActivity.blocks(of: session.presentedMessages, lifecycle: session.taskPresentation)
        XCTAssertEqual(shown(later).count, 1)
        XCTAssertTrue(shown(later).first?.hasPrefix("report ") == true, "\(shown(later))")
    }

    @MainActor func testMountedBannerKeepsMetricsHeightAndTerminalFiguresWrapInNarrowPane() throws {
        var task = record(); task.replies = 1
        var turn = TaskTranscriptPlan.summary([message("u",role:"user",cost:0)],task:task)
        for width: CGFloat in [280,640] {
            let host = NSHostingView(rootView:LiveTurnBar(turn:turn).frame(width:width))
            host.safeAreaRegions = []
            let before = host.fittingSize.height
            turn.accounting.total = 123456789; turn.accounting.costUSD = 0.000001
            host.rootView = LiveTurnBar(turn:turn).frame(width:width)
            XCTAssertEqual(host.fittingSize.height,before,accuracy:0.5)
        }
        task.phase = "terminal"; task.outcome = "completed"; task.endedAt = 4000
        task.modelMs = 2000
        var input = message("u",role:"user"); input.accounting = nil
        turn = TaskTranscriptPlan.summary([input,message("a")],task:task)
        let narrow = NSHostingView(rootView:StableTurnSummaryView(turn:turn,actions:TranscriptActions()).frame(width:280))
        let wide = NSHostingView(rootView:StableTurnSummaryView(turn:turn,actions:TranscriptActions()).frame(width:640))
        narrow.safeAreaRegions = []; wide.safeAreaRegions = []
        XCTAssertGreaterThan(narrow.fittingSize.height,wide.fittingSize.height,"Figures wrap rather than truncate behind a click")
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:620,height:480),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil); defer { window.close() }
        var running = turn; running.live = true; running.phase = "model"; running.outcome = nil
        running.startedAt = Date().timeIntervalSince1970 * 1000 - 12500; running.endedAt = nil
        running.liveStartedUptimeMs = ProcessInfo.processInfo.systemUptime * 1000 - 12500
        let overview = NSHostingView(rootView:VStack(alignment:.leading,spacing:20) {
            LiveTurnBar(turn:running)
            StableTurnSummaryView(turn:turn,actions:TranscriptActions())
        }.padding(16).frame(width:640).background(TranscriptPalette.surface))
        overview.safeAreaRegions = []; overview.frame.size = overview.fittingSize
        window.contentView = overview; overview.layoutSubtreeIfNeeded()
        if let bitmap = overview.bitmapImageRepForCachingDisplay(in:overview.bounds) {
            overview.cacheDisplay(in:overview.bounds,to:bitmap)
            let path = URL(fileURLWithPath:ProcessInfo.processInfo.environment["PI_APP_SCRATCH_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent("turn-info-overview.png")
            try bitmap.representation(using:.png,properties:[:])?.write(to:path)
        }
    }

    /// Moved from the Turn Info popup's tests: the live dock and the turn
    /// report still name a compaction and a retry the way the run line does.
    func testLiveLabelsUseExistingCompactionAndRetryStyle() {
        var value = TurnSummary(replies: 1, tools: 1, startedAt: 1_000_000, endedAt: nil, elapsedMs: nil, modelMs: 0, toolMs: 0, live: true,
                                files: 0, partial: false, accounting: TurnAccounting(), requests: [], current: nil, notice: nil)
        value.phase = "compacting"
        XCTAssertEqual(TurnInfoPresentation.workingLabel(value), "Compacting context…")
        value.phase = "retrying"
        XCTAssertEqual(TurnInfoPresentation.workingLabel(value), "Waiting to retry…")
    }
}
