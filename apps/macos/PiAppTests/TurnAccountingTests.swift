import XCTest
import AppKit
import SwiftUI
@testable import PiApp

@MainActor extension WireChat {
    /// The last finished turn's report, as the transcript planned it.
    var finishedTurn: TurnSummary? {
        transcript?.snapshot?.items.reversed().lazy.compactMap { item -> TurnSummary? in
            if case .block(let block) = item, block.presentation == .summary, let turn = block.turn, !turn.isRunning { return turn }
            return nil
        }.first
    }
    func refreshTurnAccounting() async { await model.refreshAccounting(session, workspaceID: chat.workspaceID) }
    /// Every finished request's metrics expire, as they do after the retention period.
    func expireRequestMetrics() async throws {
        try await model.traces.configure(quota: 1 << 30, bodyRetention: 86_400, metricRetention: 0.000_001)
    }
    /// The pane's text, read off its pixels; saved as `name` under PI_APP_USAGE_CAPTURE_ROOT when set.
    func rendered(_ name: String? = nil) async throws -> String { try await SessionTimingTests.recognizedText(in: window, filename: name.map { "turn-\($0).jpg" }) }
    var noLogFigures: Bool { session.messages.allSatisfy { ($0.accounting?.requests ?? 0) == 0 } }
    /// The finished turn's `count` requests are all in the log, none still running there.
    /// The finished turn counts `count` requests, none still running in the log.
    func logSettled(_ count: Int, usage: Int) -> Bool {
        guard let a = finishedTurn?.accounting else { return false }
        return a.requests == count && a.recordLines.isEmpty && a.missing.running == 0 && a.inputSamples == usage
    }
    /// What Turn Info lists for the turn: the records it loads for that turn alone.
    func requestLines(_ turn: TurnSummary) async throws -> [TurnRequestLine] {
        let page = try await TurnRequestSource.session(model, sessionID: chat.id).list(TurnRequestScope(turn))
        return TurnInfoPresentation.requestLines(turn, records: page.records)
    }
}

private final class TurnLogClock: @unchecked Sendable {
    private let lock = NSLock(); private var seconds = 2000.0
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: seconds) }
    func advance(_ value: Double) { lock.lock(); defer { lock.unlock() }; seconds += value }
}

/// What the turn report shows when the request log does not have every
/// request of a turn, and when an auto router sends one turn's requests to
/// several models. Driven through the packaged helper and the wire gateway
/// (`fixtures/native/wire_gateway.py`), with the real pane on screen.
final class TurnAccountingTests: XCTestCase {

    // MARK: H1 — the request log has no rows for a turn

    /// Capture off keeps no bodies but still logs every request's usage and
    /// model. Once those rows expire, the report used to show no input, no
    /// output and "Model unreported", though every reply had recorded its
    /// usage and model. It reads them from the replies' own records, and
    /// says so and why.
    @MainActor func testATurnWhoseRequestLogRowsExpiredReportsFromTheRepliesOwnRecords() async throws {
        let chat = try await WireChat()
        addTeardownBlock { @MainActor in await chat.close() }
        try await chat.model.setCaptureMode("off", sessionID: chat.id)
        XCTAssertEqual(chat.session.captureMode, "off", "Capture is off: no bodies are kept")
        try await chat.sendAndWait("wire route") { rows in rows.contains { $0.text.contains("Route reply") } }
        try await chat.waitUntil("the request log's figures") { chat.logSettled(3, usage: 3) }
        var turn = try XCTUnwrap(chat.finishedTurn)
        XCTAssertEqual(turn.accounting.input, 600, "Capture off still logs usage"); XCTAssertEqual(turn.accounting.output, 60)
        // BEGIN post-fix
        let kept = try await chat.requestLines(turn)
        XCTAssertEqual(kept.map(\.source), [.log, .log, .log])
        XCTAssertNil(TurnInfoPresentation.coverageNotice(turn), "Every request reported and the log has them all")
        // END post-fix

        try await chat.expireRequestMetrics()
        await chat.refreshTurnAccounting()
        let logged = turn.accounting
        try await chat.waitUntil("the turn read again without the log") { chat.noLogFigures && chat.finishedTurn.map { $0.accounting != logged } == true }
        turn = try XCTUnwrap(chat.finishedTurn)
        XCTAssertEqual(turn.accounting.requests, 3)
        XCTAssertEqual(turn.accounting.input, 600, "Input from the replies' own records"); XCTAssertEqual(turn.accounting.output, 60)
        XCTAssertEqual(turn.accounting.inputSamples, 3); XCTAssertEqual(turn.accounting.outputSamples, 3)
        XCTAssertEqual(turn.accounting.model, "route-alpha")
        let text = try await chat.rendered("expired")
        XCTAssertFalse(text.contains("Model unreported"), "OCR: \(text)")
        XCTAssertTrue(text.contains("route-alpha"), "OCR: \(text)")
        // BEGIN post-fix
        XCTAssertEqual(turn.accounting.recordLines.map(\.logMissing), [.expired, .expired, .expired])
        XCTAssertEqual(turn.accounting.recordLines.map(\.model), ["route-alpha", "route-beta", "route-alpha"])
        XCTAssertEqual(TurnInfoPresentation.coverageNotice(turn), "All from the chat’s own record")
        let listed = try await chat.requestLines(turn)
        XCTAssertEqual(listed.map(\.source), [.record, .record, .record], "Turn Info: the log's rows expired, the replies' records stand in")
        XCTAssertEqual(listed.map(TurnInfoPresentation.lineSource), Array(repeating: "chat record · log expired", count: 3))
        XCTAssertEqual(listed.map(\.input), [100, 200, 300])
        XCTAssertTrue(text.contains("own record"), "The report says where the figures came from. OCR: \(text)")
        // END post-fix
    }

    // MARK: H2 — an auto router sends one turn to several models

    /// Three requests over two models: the header names the latest and says
    /// two models answered; Turn Info lists each request's route and figures
    /// and each model's share.
    @MainActor func testAnAutoRouterTurnSaysHowManyModelsAnsweredAndListsEachRequest() async throws {
        let chat = try await WireChat()
        addTeardownBlock { @MainActor in await chat.close() }
        try await chat.sendAndWait("wire route") { rows in rows.contains { $0.text.contains("Route reply") } }
        try await chat.waitUntil("the request log's figures") { chat.logSettled(3, usage: 3) }
        let turn = try XCTUnwrap(chat.finishedTurn)
        XCTAssertEqual(Set(turn.accounting.reportedModels), ["route-alpha", "route-beta"])
        XCTAssertEqual(turn.accounting.modelRoutes.map(\.label).sorted(), ["wire-fixture → route-alpha", "wire-fixture → route-beta"])
        let text = try await chat.rendered()
        XCTAssertTrue(text.contains("2 models"), "The header says two models answered. OCR: \(text)")
        // BEGIN post-fix
        XCTAssertEqual(TurnInfoPresentation.modelLabel(turn), "wire-fixture → route-alpha · 2 models")
        let lines = try await chat.requestLines(turn)
        XCTAssertEqual(lines.map(\.model), ["route-alpha", "route-beta", "route-alpha"])
        XCTAssertEqual(lines.map(\.requested), ["wire-fixture", "wire-fixture", "wire-fixture"])
        XCTAssertEqual(lines.map(\.input), [100, 200, 300]); XCTAssertEqual(lines.map(\.output), [10, 20, 30])
        XCTAssertEqual(lines.map(TurnInfoPresentation.routeLabel), ["wire-fixture → route-alpha", "wire-fixture → route-beta", "wire-fixture → route-alpha"])
        XCTAssertEqual(TurnInfoPresentation.subtotals(lines).map(TurnInfoPresentation.subtotalLabel),
                       ["route-alpha · 2 requests · in 400 · out 40", "route-beta · 1 request · in 200 · out 20"])
        // Turn Info itself, rendered.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var actions = TranscriptActions(); let model = chat.model, id = chat.id
        actions.turnRequestSource = { TurnRequestSource.session(model, sessionID: id) }
        window.contentView = NSHostingView(rootView: TurnInfoView(turn: turn, actions: actions))
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .seconds(1))   // Turn Info loads this turn's records when it opens.
        let info = try await SessionTimingTests.recognizedText(in: window, filename: "turn-info-router.jpg").replacingOccurrences(of: "•", with: "·")
        XCTAssertTrue(info.contains("requests · 3 · 2 models"), "OCR reads lower case: \(info)")
        XCTAssertTrue(info.contains("route-beta · 1 request"), "Per-model subtotals. OCR: \(info)")
        XCTAssertTrue(info.contains("in 200"), "Each request's figures. OCR: \(info)")
        // END post-fix
    }

    /// The gateway's header names one model and the body another: identity
    /// "conflict". The log already shows the body's model; the reply's own
    /// record used to have no name at all. Both show what answered, with the
    /// header's name as the route it reported.
    @MainActor func testAHeaderBodyMismatchShowsTheModelTheBodyNamed() async throws {
        let chat = try await WireChat()
        addTeardownBlock { @MainActor in await chat.close() }
        try await chat.sendAndWait("wire mismatch") { rows in rows.contains { $0.text.contains("Wire reply") } }
        try await chat.waitUntil("the request log's figures") { chat.logSettled(1, usage: 1) }
        var turn = try XCTUnwrap(chat.finishedTurn)
        XCTAssertEqual(turn.accounting.model, "body-model", "The log shows what the body named")
        // BEGIN post-fix
        let kept = try await chat.requestLines(turn)
        XCTAssertEqual(kept.first?.routedVia, "header-model")
        // END post-fix
        try await chat.expireRequestMetrics()
        await chat.refreshTurnAccounting()
        let logged = turn.accounting
        try await chat.waitUntil("the turn read again without the log") { chat.noLogFigures && chat.finishedTurn.map { $0.accounting != logged } == true }
        turn = try XCTUnwrap(chat.finishedTurn)
        XCTAssertEqual(turn.accounting.model, "body-model", "The reply's record names what the body named")
        let text = try await chat.rendered()
        XCTAssertFalse(text.contains("Model unreported"), "OCR: \(text)")
        XCTAssertTrue(text.contains("body-model"), "OCR: \(text)")
        // BEGIN post-fix
        let line = try XCTUnwrap(turn.accounting.recordLines.first)
        XCTAssertEqual(line.source, .record); XCTAssertEqual(line.routedVia, "header-model", "The same name the log keeps")
        XCTAssertEqual(TurnInfoPresentation.routeLabel(line), "wire-fixture → body-model (gateway header: header-model)")
        // END post-fix
    }

    // MARK: H3 — some requests reported, others did not

    /// Four requests: a stream cut before its end (retried), a reply the
    /// gateway sent no usage for, and two that reported. The figures that
    /// exist are shown, and one quiet line says what they cover and why.
    @MainActor func testAPartlyReportedTurnShowsItsFiguresAndSaysWhyTheOthersHaveNone() async throws {
        let chat = try await WireChat()
        addTeardownBlock { @MainActor in await chat.close() }
        try await chat.sendAndWait("wire partial") { rows in rows.contains { $0.text.contains("Partial reply") } }
        try await chat.waitUntil("the request log's figures") { chat.logSettled(4, usage: 2) }
        let turn = try XCTUnwrap(chat.finishedTurn)
        XCTAssertEqual(turn.accounting.input, 400); XCTAssertEqual(turn.accounting.output, 40)
        let text = try await chat.rendered("partial")
        XCTAssertTrue(text.contains("did not report usage"), "The report says why the figures are partial. OCR: \(text)")
        // BEGIN post-fix
        XCTAssertEqual(TurnInfoPresentation.coverageNotice(turn),
                       "Input and output from 2 of 4 requests; 2 did not report usage (1 failed before it finished, 1 came back with no usage from the gateway)")
        XCTAssertEqual(turn.accounting.missing, TurnMissingUsage(failed: 1, noUsage: 1))
        let lines = try await chat.requestLines(turn)
        XCTAssertEqual(lines.map(\.missing), [nil, .failed, .noUsage, nil])
        XCTAssertEqual(Array(lines.map(TurnInfoPresentation.lineFigures)[1...2]), ["failed before finishing", "no usage from the gateway"])
        // END post-fix
    }

    // MARK: H4 — a running turn

    /// The request log is closed while a routed turn runs, as it is when a
    /// turn runs before the log opens at launch: every capture is dropped.
    /// The live report shows what its settled requests reported so far, not
    /// "Model pending" with empty figures, and the finished turn keeps them.
    @MainActor func testARunningTurnWhoseCapturesAreDroppedShowsWhatItsRepliesReportedSoFar() async throws {
        let chat = try await WireChat()
        addTeardownBlock { @MainActor in await chat.close() }
        try await chat.model.traces.close()
        chat.send("wire route 4")
        try await chat.waitUntil("the second call running") {
            chat.card("bash")?.state == "running" && chat.card("bash")?.input.contains("sleep") == true && chat.transcript?.liveTurn != nil
        }
        let live = try XCTUnwrap(chat.transcript?.liveTurn)
        XCTAssertTrue(live.isRunning)
        XCTAssertEqual(live.accounting.input, 300, "The two settled requests' input"); XCTAssertEqual(live.accounting.output, 30)
        let text = try await chat.rendered("running")
        XCTAssertFalse(text.contains("Model pending") || text.contains("Model unreported"), "OCR: \(text)")
        XCTAssertTrue(text.contains("route-beta"), "The latest settled request's model. OCR: \(text)")
        // BEGIN post-fix
        XCTAssertEqual(TurnInfoPresentation.coverageNotice(live), "Reported so far · updates as requests finish",
                       "The log has not answered, so the report claims nothing about it")
        XCTAssertEqual(live.accounting.recordLines.map(TurnInfoPresentation.lineSource), ["chat record", "chat record"])
        // END post-fix
        try await chat.waitUntil("the turn finished", seconds: 30) { !chat.session.busy && chat.finishedTurn != nil }
        var turn = try XCTUnwrap(chat.finishedTurn)
        XCTAssertEqual(turn.accounting.input, 600); XCTAssertEqual(turn.accounting.output, 60)
        // BEGIN post-fix
        XCTAssertEqual(TurnInfoPresentation.modelLabel(turn), "wire-fixture → route-alpha · 2 models")
        // The log opens, as it does once launch finishes, and has no row for
        // the turn: now the report says where its figures came from.
        try await chat.model.traces.configure(quota: 1 << 30, bodyRetention: 86_400, metricRetention: 2_592_000)
        await chat.refreshTurnAccounting()
        try await chat.waitUntil("the log answered") { chat.finishedTurn?.accounting.recordLines.first?.logMissing == .notCaptured }
        turn = try XCTUnwrap(chat.finishedTurn)
        XCTAssertEqual(turn.accounting.input, 600)
        XCTAssertEqual(TurnInfoPresentation.coverageNotice(turn), "All from the chat’s own record")
        XCTAssertEqual(turn.accounting.recordLines.map(TurnInfoPresentation.lineSource), Array(repeating: "chat record · not in log", count: 3))
        let listed = try await chat.requestLines(turn)
        XCTAssertEqual(listed.map(TurnInfoPresentation.lineSource), Array(repeating: "live log", count: 3),
                       "Turn Info lists the helper's own log of the requests the durable log never got")
        // END post-fix
    }
    // BEGIN post-fix

    // MARK: The rules, without a window

    private func reply(_ id: String, attempt: String?, at: Double, input: Double? = 90, cached: Double = 10, output: Double? = 20, model: String? = "m1",
                       accounting: GatewayTotals? = nil, state: String? = nil, stopReason: String? = nil) -> TranscriptMessage {
        var row = TranscriptMessage(id: id, role: "assistant", text: "reply", state: state, stopReason: stopReason, accounting: accounting, at: at * 1000)
        var record = ReplyRecord(attempt: attempt, requested: "auto")
        if let model { record.models = [.init(name: "auto", source: "response.completed.response.model"), .init(name: model, source: "response.completed.response.router_model_name")] }
        if input != nil || output != nil { record.usage = .init(input: input, output: output, cacheRead: cached, cacheWrite: 0, totalTokens: nil) }
        row.reply = attempt == nil && model == nil && input == nil && output == nil ? nil : record
        return row
    }
    private func logged(requests: Int, input: Double? = nil, output: Double? = nil, model: String? = nil,
                        missing: GatewayMissingUsage = GatewayMissingUsage(), replyLog: ReplyLog? = nil) -> GatewayTotals {
        var totals = GatewayTotals(requests: requests)
        totals.tokens = GatewayTokenTotals(input: input, output: output, inputSamples: input == nil ? 0 : requests, outputSamples: output == nil ? 0 : requests)
        if let model { totals.models = GatewayModelSummary(names: [model], nameCount: 1, reportedRequests: requests, displayRequests: requests) }
        totals.missingUsage = missing; totals.replyLog = replyLog?.rawValue
        return totals
    }

    /// A request the log counts — here on the user row, its link to the reply
    /// not yet written — is never counted again from the reply's record; a
    /// reply the log has no row for adds its record once.
    func testARequestIsCountedOnceWhicheverSourceHasIt() {
        let user = TranscriptMessage(id: "u", role: "user", text: "hi", accounting: logged(requests: 1, input: 100, output: 20, model: "m1"))
        let first = reply("r1", attempt: "a1", at: 11, accounting: logged(requests: 0, replyLog: .counted))
        let second = reply("r2", attempt: "a2", at: 12, model: "m2", accounting: logged(requests: 0, replyLog: .absent))
        let sum = TranscriptActivity.aggregate([user, first, second])
        XCTAssertEqual(sum.requests, 2)
        XCTAssertEqual(sum.input, 200, "100 logged + 90 + 10 cached from the second reply's record")
        XCTAssertEqual(sum.output, 40); XCTAssertEqual(sum.inputSamples, 2)
        XCTAssertEqual(sum.recordLines.map(\.id), ["a2"]); XCTAssertEqual(sum.recordLines.first?.logMissing, .notCaptured)
        XCTAssertEqual(sum.answeredModels, ["m1", "m2"]); XCTAssertEqual(sum.model, "m2")
        XCTAssertEqual(sum.split(input: true)?.part, 10, "The record's cache read stays part of its input")
    }

    /// The log counts a request whose final metadata is still on the way,
    /// without usage. The reply's record fills in the figures for that same
    /// request; it is not counted a second time.
    func testALoggedRequestWithoutUsageTakesItsRepliesRecordedFigures() {
        let own = logged(requests: 1, missing: GatewayMissingUsage(running: 1), replyLog: .running)
        let sum = TranscriptActivity.aggregate([TranscriptMessage(id: "u", role: "user", text: "q"), reply("r1", attempt: "a1", at: 11, accounting: own)])
        XCTAssertEqual(sum.requests, 1); XCTAssertEqual(sum.input, 100); XCTAssertEqual(sum.output, 20); XCTAssertEqual(sum.inputSamples, 1)
        XCTAssertTrue(sum.recordLines.isEmpty); XCTAssertEqual(sum.missing, TurnMissingUsage())
        XCTAssertNil(TurnInfoPresentation.coverageNotice(TurnSummary(replies: 1, tools: 0, startedAt: nil, endedAt: nil, elapsedMs: nil, modelMs: 0, toolMs: 0,
            live: false, files: 0, partial: false, accounting: sum, requests: [], outcome: "completed")), "Nothing to say while the log catches up")
    }

    /// An older snapshot has figures but no answer for the record: its row's
    /// own figures stand for the reply, whose record is then not added.
    func testAnOlderSnapshotKeepsTheRowsOwnFigures() {
        var totals = GatewayTotals(requests: 1); totals.tokens = GatewayTokenTotals(input: 100, output: 20, inputSamples: 1, outputSamples: 1)
        let sum = TranscriptActivity.aggregate([reply("r1", attempt: "a1", at: 1, accounting: totals)])
        XCTAssertEqual(sum.requests, 1); XCTAssertEqual(sum.input, 100); XCTAssertFalse(sum.missing.known, "It cannot say why a request lacks usage")
    }

    /// A streaming reply the log has not seen is a running request; an
    /// interrupted one failed; one whose log row expired says so; a reply the
    /// log has no row for was not captured.
    func testEachMissingReasonIsNamed() throws {
        let rows = [
            reply("r1", attempt: "a1", at: 1, accounting: logged(requests: 0, replyLog: .absent)),
            reply("r2", attempt: "a2", at: 2, input: nil, output: nil, model: nil, stopReason: "interrupted"),
            reply("r3", attempt: "a3", at: 3, input: nil, output: nil, accounting: logged(requests: 0, replyLog: .expired)),
            reply("r4", attempt: "a4", at: 4, input: nil, output: nil, model: nil, accounting: logged(requests: 0, replyLog: .absent)),
            reply("stream", attempt: nil, at: 5, input: nil, output: nil, model: nil, state: "streaming"),
        ]
        let sum = TranscriptActivity.aggregate(rows)
        XCTAssertEqual(sum.requests, 5)
        XCTAssertEqual(sum.recordLines.map(\.missing), [nil, .failed, .expired, .notCaptured, .running])
        XCTAssertEqual(sum.missing, TurnMissingUsage(running: 1, failed: 1, notCaptured: 1, expired: 1))
        var turn = TurnSummary(replies: 5, tools: 0, startedAt: nil, endedAt: nil, elapsedMs: nil, modelMs: 0, toolMs: 0, live: false, files: 0,
                               partial: false, accounting: sum, requests: rows, outcome: "completed")
        XCTAssertEqual(TurnInfoPresentation.coverageNotice(turn),
                       "Input and output from 1 of 5 requests; 4 did not report usage (1 still running, 1 failed before it finished, 1 was not captured, 1 has expired from the request log) · 1 of 5 from the chat’s own record")
        XCTAssertEqual(sum.recordLines.map(TurnInfoPresentation.lineSource), ["chat record · not in log", "chat record", "chat record · log expired", "chat record · not in log", "chat record"])
        XCTAssertEqual(sum.recordLines.map(TurnInfoPresentation.lineFigures), ["in 100 (10 cached) · out 20", "failed before finishing", "metrics expired", "not captured", "running"])
        // A reply the log has not answered for yet claims nothing about the log.
        let unread = TranscriptActivity.aggregate([reply("r5", attempt: "a5", at: 6)])
        XCTAssertEqual(unread.recordLines.first?.logMissing, nil); XCTAssertEqual(unread.recordRequests, 0)
        XCTAssertEqual(TurnInfoPresentation.lineSource(try XCTUnwrap(unread.recordLines.first)), "chat record")
        turn.live = true; turn.outcome = nil
        XCTAssertTrue(TurnInfoPresentation.coverageNotice(turn)?.hasPrefix("Reported so far · input and output from 1 of 5 requests") == true)
        XCTAssertEqual(TurnInfoPresentation.modelLabel(turn), "auto → m1")
    }

    /// Turn Info's list, built from the records it loads for the one turn:
    /// a request the log kept, one whose metrics expired (its reply's record
    /// stands in), one only the helper's memory holds, and one the log never
    /// had, from its reply's record.
    func testTurnInfoListsEveryRequestFromTheRecordsItLoads() {
        func record(_ id: String, wall: Double, expired: Bool = false, live: Bool = false) -> TurnRequestRecord {
            var metadata: [String: WireValue] = ["attemptId": .string(id), "wallTimestamp": .number(wall), "requestedModel": .string("auto"), "outcome": .string("completed")]
            if expired { metadata["metricsExpired"] = .bool(true) }
            else {
                metadata["usage"] = .object(["inputIncludingCache": .number(50), "output": .number(5)])
                metadata["identity"] = .object(["status": .string("reported"), "evidence": .array([.object(["value": .string("m1"), "source": .string("body.router_model_name"), "kind": .string("model")])])])
            }
            return TurnRequestRecord(metadata: metadata, liveOnly: live)
        }
        let rows = [reply("r2", attempt: "a2", at: 2, accounting: logged(requests: 0, replyLog: .expired)),
                    reply("r4", attempt: "a4", at: 4, model: "m2", accounting: logged(requests: 0, replyLog: .absent))]
        let turn = TurnSummary(replies: 4, tools: 0, startedAt: nil, endedAt: nil, elapsedMs: nil, modelMs: 0, toolMs: 0, live: false, files: 0,
                               partial: false, accounting: TranscriptActivity.aggregate(rows), requests: rows, outcome: "completed")
        let lines = TurnInfoPresentation.requestLines(turn, records: [record("a1", wall: 1), record("a2", wall: 2, expired: true), record("a3", wall: 3, live: true)])
        XCTAssertEqual(lines.map(\.id), ["a1", "a2", "a3", "a4"])
        XCTAssertEqual(lines.map(TurnInfoPresentation.lineSource), ["request log", "chat record · log expired", "live log", "chat record · not in log"])
        XCTAssertEqual(lines.map(\.input), [50, 100, 50, 100]); XCTAssertEqual(lines.map(\.model), ["m1", "m1", "m1", "m2"])
        XCTAssertEqual(TurnInfoPresentation.subtotals(lines).map(TurnInfoPresentation.subtotalLabel), ["m1 · 3 requests · in 200 · out 30", "m2 · 1 request · in 100 · out 20"])
    }

    /// The body's router name answers over its echo of the alias; with no
    /// body report, one header name does; a header that disagrees with the
    /// body is the route, not what answered.
    func testWhatAnsweredIsTheBodysNameAndADisagreeingHeaderIsTheRoute() {
        typealias Report = GatewayModelIdentity.Report
        XCTAssertEqual(GatewayModelIdentity.answered([Report(name: "auto", source: "response.completed.response.model"),
                                                      Report(name: "gpt-b", source: "response.completed.response.router_model_name"),
                                                      Report(name: "openai/gpt-a", source: "header:x-litellm-model-name")]), "gpt-b")
        XCTAssertEqual(GatewayModelIdentity.answered([Report(name: "openai/gpt-a", source: "header:x-litellm-model-name")]), "openai/gpt-a")
        XCTAssertNil(GatewayModelIdentity.answered([Report(name: "a", source: "header:x-one"), Report(name: "b", source: "header:x-two")]))
        XCTAssertEqual(GatewayModelIdentity.routedVia(["openai/gpt-a"], answered: "gpt-b"), "gpt-a")
        XCTAssertNil(GatewayModelIdentity.routedVia(["openai/gpt-b"], answered: "gpt-b"), "openai/x and x agree")
    }

    /// The record crosses the wire in the display row and reads the same from
    /// a journal row, and the fast projector reads it as Codable does.
    func testTheReplyRecordReadsTheSameFromTheWireAndFromTheJournal() throws {
        let wire: WireValue = .array([.object(["id": .string("r1"), "role": .string("assistant"), "text": .string("hi"),
            "reply": .object(["attempt": .string("a1"), "requested": .string("auto"),
                              "models": .array([.object(["name": .string("gpt-b"), "source": .string("response.completed.response.router_model_name")]),
                                                .object(["name": .string("openai/gpt-a"), "source": .string("header:x-litellm-model-name")])]),
                              "usage": .object(["input": .number(80), "output": .number(20), "cacheRead": .number(15), "cacheWrite": .number(5), "totalTokens": .number(120)])])])])
        let projected = try TranscriptMessage.projected(wire), decoded = try JSONDecoder().decode([TranscriptMessage].self, from: JSONEncoder().encode(wire))
        XCTAssertEqual(projected, decoded)
        let record = try XCTUnwrap(projected.first?.reply)
        XCTAssertEqual(record.model, "gpt-b"); XCTAssertEqual(record.routedVia, "gpt-a")
        XCTAssertEqual(record.input, 100, "pi's input plus cache reads and writes"); XCTAssertEqual(record.cached, 15); XCTAssertEqual(record.output, 20)
        let journal = TranscriptMessage.project(id: "r1", message: [
            "role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string("hi")])]),
            "nativeRequestAttemptIds": .array([.string("a1")]),
            "nativeProviderIdentity": .object(["requestedAlias": .string("auto"), "status": .string("conflict"), "evidence": .array([
                .object(["value": .string("gpt-b"), "source": .string("response.completed.response.router_model_name"), "kind": .string("model")]),
                .object(["value": .string("auto-group"), "source": .string("header:x-litellm-model-group"), "kind": .string("group")]),
                .object(["value": .string("openai/gpt-a"), "source": .string("header:x-litellm-model-name"), "kind": .string("model")])])]),
            "usage": .object(["input": .number(80), "output": .number(20), "cacheRead": .number(15), "cacheWrite": .number(5), "totalTokens": .number(120)])])
        XCTAssertEqual(journal.reply, record)
    }

    /// The page's accounting says, for each reply's own request, whether the
    /// log counts it, has no row for it, or let its metrics expire; and how
    /// many of a message's requests lack usage, by why.
    func testTheLogSaysWhatItHoldsOfEachRepliesRequest() async throws {
        let root = URL(fileURLWithPath: testEnvironment("PI_BUILD_ROOT") ?? NSTemporaryDirectory()).appendingPathComponent("turn-lines-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TurnLogClock()
        let archive = PayloadArchive(root: root, now: { clock.now() })
        try await archive.configure(quota: 1_048_576, bodyRetention: 10, metricRetention: 100)
        func attempt(output: [String], wall: Double, outcome: String = "completed", model: String, usage: Bool = true) async throws -> String {
            let id = UUID().uuidString
            let value: [String: WireValue] = ["attemptId": .string(id), "sessionId": .string("s"), "turnId": .string("u"), "purpose": .string("turn"),
                "api": .string("openai-responses"), "requestedModel": .string("auto"), "mode": .string("off"), "outcome": .string(outcome),
                "wallTimestamp": .number(wall), "dispatchWallTimestamp": .number(wall), "timingVersion": .number(2),
                "timings": .object(["dispatch": .number(100), "firstContent": .number(110), "modelComplete": .number(120), "httpEnd": .number(130)]),
                "messageIds": .array([.string("u")]), "outputMessageIds": .array(output.map(WireValue.string)),
                "identity": .object(["requestedAlias": .string("auto"), "status": .string("reported"), "effectiveModel": .string(model),
                                     "evidence": .array([.object(["value": .string(model), "source": .string("response.completed.response.router_model_name"), "kind": .string("model")])])]),
                "usage": usage ? .object(["inputIncludingCache": .number(100), "input": .number(100), "output": .number(10)]) : .object([:])]
            try await archive.begin(value, workspace: "w"); try await archive.finish(value)
            return id
        }
        _ = try await attempt(output: [], wall: 1990, outcome: "failed", model: "m1", usage: false)
        let answered = try await attempt(output: ["r1"], wall: 1991, model: "m2")
        let bare = try await attempt(output: ["r3"], wall: 1992, model: "m2", usage: false)
        var reply = TranscriptMessage(id: "r1", role: "assistant", text: "a"); reply.reply = ReplyRecord(attempt: answered)
        var lost = TranscriptMessage(id: "r2", role: "assistant", text: "b"); lost.reply = ReplyRecord(attempt: UUID().uuidString)
        var empty = TranscriptMessage(id: "r3", role: "assistant", text: "c"); empty.reply = ReplyRecord(attempt: bare)
        let rows = [TranscriptMessage(id: "u", role: "user", text: "q"), reply, lost, empty]
        let before = try await archive.gatewayAccounting(sessionID: "s", workspaceID: "w", messages: rows)
        XCTAssertEqual(before.messages["u"]?.missingUsage, GatewayMissingUsage(failed: 1))
        XCTAssertEqual(before.messages["r1"]?.replyLog, ReplyLog.counted.rawValue); XCTAssertEqual(before.messages["r1"]?.missingUsage, GatewayMissingUsage())
        XCTAssertEqual(before.messages["r2"]?.requests, 0); XCTAssertEqual(before.messages["r2"]?.replyLog, ReplyLog.absent.rawValue)
        XCTAssertEqual(before.messages["r3"]?.replyLog, ReplyLog.noUsage.rawValue); XCTAssertEqual(before.messages["r3"]?.missingUsage, GatewayMissingUsage(noUsage: 1))
        clock.advance(1_000)
        let after = try await archive.gatewayAccounting(sessionID: "s", workspaceID: "w", messages: rows)
        XCTAssertNil(after.messages["u"]); XCTAssertEqual(after.messages["r1"]?.requests, 0)
        XCTAssertEqual(after.messages["r1"]?.replyLog, ReplyLog.expired.rawValue); _ = answered
        // The page counts all three reasons in one packed column.
        XCTAssertEqual(GatewayMissingUsage(packed: .integer(3 << 40 | 2 << 20 | 1)), GatewayMissingUsage(running: 3, failed: 2, noUsage: 1))
        XCTAssertEqual(GatewayMissingUsage(packed: .null), GatewayMissingUsage())
        try await archive.close()
    }
    // END post-fix
}
