import XCTest
import AppKit
import SwiftUI
import Combine
@testable import PiApp

/// A chat on the packaged helper, talking to the synthetic wire gateway
/// (`fixtures/native/wire_gateway.py`), with the real pane on screen. Every
/// request the app makes is recorded with its result exactly as the snapshot
/// loop received it, so a test can say what crossed the wire and what the
/// transcript made of it.
@MainActor final class WireChat {
    struct Reply { let method: String; let params: [String: WireValue]; let result: WireValue }
    let model: WorkspaceModel
    let session: SessionDisplay
    let chat: ChatRecord
    let root: URL
    let window: NSWindow
    let hosted: NSHostingView<ConversationPane>
    private let gateway: Process
    /// The gateway's stdin: it exits when this closes, with the test process
    /// at the latest, so a failed run never leaves it serving.
    private let lifeline = Pipe()
    var replies: [Reply] = []

    init() async throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let script = repository.appendingPathComponent("fixtures/native/wire_gateway.py")
        guard FileManager.default.isReadableFile(atPath: script.path) else { throw XCTSkip("The wire gateway fixture is unavailable") }
        root = scratchRoot("wire-contract")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        gateway = Process()
        let pipe = Pipe()
        gateway.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        gateway.arguments = ["-u", script.path, "--exit-on-eof"]
        gateway.currentDirectoryURL = root; gateway.standardOutput = pipe; gateway.standardError = FileHandle.nullDevice
        gateway.standardInput = lifeline
        gateway.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": root.path]
        try gateway.run()
        let handle = pipe.fileHandleForReading
        let greeting = await Task.detached { handle.availableData }.value
        let port = try XCTUnwrap(try JSONDecoder().decode([String: Int].self, from: greeting)["port"])
        let base = "http://127.0.0.1:\(port)"
        let workspace = WorkspaceRecord(id: "wire-project", path: root.path, trusted: true)
        var profile = ProfileRecord()
        profile.api = "openai-responses"; profile.baseUrl = base; profile.modelId = "wire-fixture"; profile.catalogUrl = base + "/catalog"
        profile.name = "Wire fixture"; profile.contextWindow = 2_000_000; profile.maxOutputTokens = 300_000; profile.modelOutputLimit = 300_000
        var configuration = VaultConfiguration()
        configuration.workspaces = [workspace]
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-wire-key")]
        configuration.automaticUpdateChecks = false
        configuration.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)])
        model = WorkspaceModel(stateRoot: root.appendingPathComponent("app-state"),
                               vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
        await model.restore()
        model.selectedWorkspaceID = workspace.id; model.profileChoice = profile.id
        chat = ChatRecord(id: UUID().uuidString, workspaceID: workspace.id, title: "Wire", path: nil, profileID: profile.id)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.select(chat.id)
        session = try XCTUnwrap(model.displays[chat.id])
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted = NSHostingView(rootView: ConversationPane(model: model, session: session, chat: chat, paneWidth: 1000))
        window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        let host = try await model.open(chat)
        host.requestObserver = { [weak self] method, params, result in self?.replies.append(Reply(method: method, params: params, result: result)) }
        model.refresh(chat.id)
    }

    var host: HostSupervisor? { model.hosts[chat.workspaceID] }
    var id: String { chat.id }
    var transcript: TranscriptPage? { ConversationPaneTests.views(TranscriptSurfaceMarker.self, in: hosted).first?.page }
    func draw() { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
    func send(_ text: String) { session.draft = text; model.send(sessionID: chat.id) }
    /// Waits for a condition, drawing the pane between checks.
    func waitUntil(_ what: String, seconds: Double = 45, file: StaticString = #filePath, line: UInt = #line,
                   _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await condition() { draw(); return }
            draw(); try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out: \(what) (state \(session.state), notice “\(session.notice)”)", file: file, line: line)
        throw CancellationError()
    }
    /// The assistant rows the chat shows.
    var replyRows: [TranscriptMessage] { session.messages.filter { $0.role == "assistant" } }
    /// The last card for a call made with `tool`, as the chat holds it.
    func card(_ tool: String) -> ToolView? { replyRows.last { $0.tools?.contains { $0.name == tool } == true }?.tools?.last { $0.name == tool } }
    /// Sends a message and waits until its run has ended with a reply for which `finished` holds.
    func sendAndWait(_ text: String, file: StaticString = #filePath, line: UInt = #line, finished: @escaping ([TranscriptMessage]) -> Bool) async throws {
        send(text)
        try await waitUntil("“\(text)” finished", file: file, line: line) {
            !session.loading && !session.busy && session.queueCount == 0 && finished(replyRows)
        }
    }
    func pending() async throws -> [CommandIntent] { try await model.store?.list(CommandIntent.self, kind: "pending:\(chat.id)") ?? [] }
    func settled() async throws -> [CommandIntent] { try await model.store?.list(CommandIntent.self, kind: "receipt:\(chat.id)") ?? [] }
    /// The snapshot and status replies the snapshot loop received.
    var snapshots: [Reply] { replies.filter { ["session.snapshot", "session.status"].contains($0.method) } }
    static func bytes(_ value: WireValue) -> Int {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(value).count) ?? 0
    }
    func close() async {
        host?.requestObserver = nil
        for host in model.hosts.values { try? await host.shutdownAndWait() }
        try? await model.traces.close(); await model.store?.close()
        model.shutdown(); window.contentView = nil; window.close()
        if gateway.isRunning { gateway.terminate(); gateway.waitUntilExit() }
        try? FileManager.default.removeItem(at: root)
    }
}

/// What the app does with what the 0.1.85 helper sends: tool outcomes it
/// cannot know, replies the provider ended early, a decode span too short to
/// be a rate, receipts and task records sent only when they change, and tool
/// arguments that grow in place. Each is driven through the packaged helper
/// where it crosses the wire.
final class WireContractTests: XCTestCase {

    // MARK: H4 — a call stopped while it ran

    /// Stopping a chat while its command runs leaves a call that began and
    /// never reported: it may have had effects, so it is neither "Ran",
    /// "Failed" nor "Skipped". The row is amber and says so, live, after the
    /// app reads the chat back from its journal, and after a new helper
    /// replays that journal.
    @MainActor func testACallStoppedWhileRunningReadsStoppedWithItsOutcomeUnknownLiveAndAfterReopening() async throws {
        let chat = try await WireChat()
        addTeardownBlock { @MainActor in await chat.close() }
        chat.send("wire bash 30")
        try await chat.waitUntil("the command is running") { chat.card("bash")?.state == "running" }
        chat.model.stop(sessionID: chat.id)
        try await chat.waitUntil("the stop settles") {
            !chat.session.busy && !chat.session.loading && !["running", "preparing", "prepared"].contains(chat.card("bash")?.state ?? "running")
        }
        func check(_ card: ToolView?, _ when: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let card = try XCTUnwrap(card, when, file: file, line: line)
            XCTAssertEqual(card.state, "unknown", "\(when): the helper reports a call that began and was stopped as unknown", file: file, line: line)
            XCTAssertEqual(ActionRowView.state(of: card), .stopped, "\(when): amber, not red — nothing failed", file: file, line: line)
            XCTAssertEqual(ActionRowView.title(of: card), "Stopped running", "\(when): never “Ran”, which claims it finished", file: file, line: line)
            XCTAssertEqual(ActionRowView.summary(of: card), "sleep 30; echo wire-bash-done", "\(when): the command it was running", file: file, line: line)
            XCTAssertEqual(ActionRowView.suffix(of: card), "· outcome unknown", "\(when): what the reader must check", file: file, line: line)
            XCTAssertEqual(ToolCallSummary(tools: [card]).label, "1 tool call · 1 outcome unknown", "\(when): never “skipped”", file: file, line: line)
        }
        try check(chat.card("bash"), "live")
        // The mounted pane draws the same card.
        let shown = chat.transcript?.snapshot?.items.compactMap { item -> ToolView? in
            if case .block(let block) = item { return block.message?.tools?.first { $0.name == "bash" } }
            return nil
        }.last
        try check(shown, "live, on the mounted page")

        // Read back from the journal by the app itself, with no helper.
        let path = try XCTUnwrap(chat.model.record(chat.id)?.path)
        try await XCTUnwrap(chat.host).shutdownAndWait()
        try await chat.waitUntil("the helper is gone") { !chat.model.opened.contains(chat.id) }
        chat.model.selectedID = nil; chat.model.selected = nil
        await chat.model.select(chat.id)
        try await chat.waitUntil("the journal page is shown") { chat.session.historyState != .loading && chat.card("bash") != nil }
        XCTAssertTrue(chat.session.projectedRows.isEmpty, "This page came from the journal, not a helper")
        try check(chat.card("bash"), "reopened from the journal")
        let cold = try await HistoryReader().window(path: path)
        try check(cold.messages.last { $0.tools?.contains { $0.name == "bash" } == true }?.tools?.last, "read by the history reader")

        // Replayed by a new helper.
        _ = try await chat.model.open(try XCTUnwrap(chat.model.record(chat.id)))
        chat.model.refresh(chat.id)
        try await chat.waitUntil("the new helper's page") { chat.session.projectedRows.contains { $0.tools?.contains { $0.name == "bash" } == true } }
        try check(chat.session.projectedRows.last { $0.tools?.contains { $0.name == "bash" } == true }?.tools?.last, "replayed by a new helper")
        try check(chat.card("bash"), "reopened on a new helper")
    }

    /// Every place a call is read agrees on the unknown outcome, and nothing
    /// else changes: a call that never ran is still "Skipped", a failed one
    /// still "Failed".
    func testTheUnknownOutcomeReadsTheSameWhereverACallIsShown() throws {
        let bash = ToolView(id: "b", name: "bash", state: "unknown", input: #"{"command":"npm test"}"#, output: "", durationMs: 1_200, truncated: false)
        XCTAssertEqual(TranscriptActivity.outcome(of: bash), .unknown)
        XCTAssertEqual(TranscriptActivity.describe(bash).verb, "Stopped running")
        XCTAssertEqual(ActionRowView.title(of: bash), "Stopped running")
        XCTAssertEqual(ActionRowView.summary(of: bash), "npm test", "Not replaced by an output line, as a failure's is")
        XCTAssertEqual(ActionRowView.suffix(of: bash), "· outcome unknown")
        XCTAssertEqual(ActionRowView.state(of: bash), .stopped)
        XCTAssertEqual(ActionRowView.elapsed(of: bash), "1s", "It ran for as long as it ran")
        XCTAssertEqual(TranscriptActivity.state(of: [bash]), .failed, "A run holding an unknown call did not simply complete")
        XCTAssertEqual(TranscriptActivity.changedFiles([bash]), 0)
        var skipped = bash; skipped.state = "cancelled"
        XCTAssertEqual(TranscriptActivity.describe(skipped).verb, "Skipped running", "A call that never ran keeps reading as skipped")
        XCTAssertEqual(ActionRowView.title(of: skipped), "Skipped running", "The row never says “Ran” for a call that never ran")
        XCTAssertEqual(ActionRowView.state(of: skipped), .stopped)
        XCTAssertNil(ActionRowView.suffix(of: skipped))
        XCTAssertEqual(ToolCallSummary(tools: [skipped]).label, "1 tool call · 1 skipped")
        var failed = bash; failed.state = "failed"; failed.output = "exit 1"
        XCTAssertEqual(ActionRowView.state(of: failed), .failed)
        XCTAssertEqual(ActionRowView.title(of: failed), "Ran")
        XCTAssertEqual(ToolCallSummary(tools: [bash, skipped, failed]).label, "3 tool calls · 1 failed · 1 skipped · 1 outcome unknown")
        // An edit stopped mid-call may already have written.
        let edit = ToolView(id: "e", name: "edit", state: "unknown", input: #"{"path":"a.swift","oldText":"a","newText":"b"}"#,
                            output: "", durationMs: nil, truncated: false, added: 1, removed: 1)
        XCTAssertEqual(ActionRowView.title(of: edit), "Stopped editing")
        XCTAssertEqual(ActionRowView.suffix(of: edit), "+1 −1 · outcome unknown")
        XCTAssertNotNil(TranscriptActivity.editRequest(edit), "Its card still shows what was asked")
        // Read back from a journal: the recorded outcome decides, as the helper reads it.
        func state(_ outcome: String?, error: Bool) -> String { ToolResultRecord(output: "", isError: error, outcome: outcome).cardState }
        XCTAssertEqual(state("unknown", error: true), "unknown")
        XCTAssertEqual(state("not_executed", error: true), "cancelled")
        XCTAssertEqual(state("failed", error: true), "failed")
        XCTAssertEqual(state("completed", error: false), "completed")
        XCTAssertEqual(state(nil, error: true), "failed", "A journal from before outcomes were recorded keeps its reading")
        XCTAssertEqual(state(nil, error: false), "completed")
        let record: [String: WireValue] = ["role": .string("toolResult"), "toolCallId": .string("b"), "isError": .bool(true),
                                           "content": .array([.object(["type": .string("text"), "text": .string("Tool interrupted.")])]),
                                           "nativeToolStats": .object(["durationMs": .number(1_200), "outcome": .string("unknown")])]
        XCTAssertEqual(try XCTUnwrap(ToolResultRecord.of(record)).record.cardState, "unknown")
    }

    // MARK: H14 — a reply the provider ended early

    /// Pi's mapStopReason: a reply the provider ended for any reason but the
    /// output budget is an error. The run fails with pi's text, and the words
    /// that arrived stay on screen without being replayed. A row an earlier
    /// helper recorded with the content filter's reason still says why on a
    /// line under itself, as the output limit does.
    @MainActor func testAReplyTheContentFilterStoppedFailsTheRunAsPiDoes() async throws {
        let chat = try await WireChat()
        addTeardownBlock { @MainActor in await chat.close() }
        chat.send("wire filter")
        try await chat.waitUntil("“wire filter” failed") { !chat.session.loading && !chat.session.busy && chat.session.state == "error" }
        XCTAssertEqual(chat.session.failureMessage, "Response incomplete: content_filter")
        let partial = try XCTUnwrap(chat.replyRows.last)
        XCTAssertEqual(partial.text, "Partial answer before the provider stopped.")
        XCTAssertNotEqual(partial.stopReason, "length", "Only the output budget is the output limit")
        // The row as drawn: the notice is one more line under the reply.
        var row = partial; row.stopReason = "content_filter"
        func height(_ message: TranscriptMessage) -> CGFloat {
            let host = NSHostingView(rootView: MessageRowView(message: message, actions: TranscriptActions(), inlineAccounting: false).frame(width: 640))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        var plain = row; plain.stopReason = nil
        var limited = row; limited.stopReason = "length"
        let filtered = height(row), ended = height(plain), outputLimit = height(limited)
        XCTAssertGreaterThan(outputLimit, ended + 8, "The output limit has its line")
        XCTAssertGreaterThan(filtered, ended + 8, "A reply the content filter stopped says so on a line of its own")
        XCTAssertEqual(filtered, outputLimit, accuracy: 1, "One line, like the output limit's")
    }

    /// Only "length" is the output limit. The content filter is named; any
    /// other reason the provider gave is quoted; the reader's own stop and the
    /// ends an older journal records for a finished reply say nothing.
    func testOnlyLengthIsTheOutputLimitAndAnyOtherEarlyEndNamesItsReason() {
        XCTAssertEqual(TranscriptActivity.earlyEnd("length"), "Output limit reached")
        XCTAssertEqual(TranscriptActivity.earlyEnd("content_filter"), "Stopped by the provider's content filter")
        XCTAssertEqual(TranscriptActivity.earlyEnd("safety_block"), "The provider ended this reply early (safety_block)")
        XCTAssertEqual(TranscriptActivity.earlyEnd("length", toolArguments: true), "Output limit reached; tool arguments may be incomplete.")
        XCTAssertEqual(TranscriptActivity.earlyEnd("content_filter", toolArguments: true),
                       "Stopped by the provider's content filter; tool arguments may be incomplete.")
        XCTAssertEqual(TranscriptActivity.earlyEnd("pause_turn", toolArguments: true),
                       "The provider ended this reply early (pause_turn); tool arguments may be incomplete.")
        for ordinary in [nil, "", "interrupted", "stop", "toolUse", "tool_use", "end_turn", "stop_sequence", "completed", "aborted", "error"] {
            XCTAssertNil(TranscriptActivity.earlyEnd(ordinary), "\(ordinary ?? "nil") is not an early end")
            XCTAssertNil(MessageRowView.earlyEnd(ordinary))
        }
        XCTAssertEqual(MessageRowView.earlyEnd("length"), "The reply reached the output limit. Ask the model to continue.")
        XCTAssertEqual(MessageRowView.earlyEnd("content_filter"), "Stopped by the provider's content filter")
        XCTAssertEqual(MessageRowView.earlyEnd("other"), "The provider ended this reply early (other)")
    }

    /// A reply that ended early for any reason draws its notice line, so its
    /// estimate holds that line too: estimated one line short, the row would
    /// move the page when it is measured.
    func testAnyEarlyEndIsEstimatedWithItsNoticeLine() {
        func estimate(_ stopReason: String?) -> CGFloat {
            var reply = TranscriptMessage(id: "a1", role: "assistant", text: "Here is the start of an answer.", at: 1_000)
            reply.stopReason = stopReason
            return TranscriptRowEstimate.height(of: .message(reply), width: 640)
        }
        let plain = estimate(nil)
        XCTAssertGreaterThan(estimate("length"), plain)
        XCTAssertEqual(estimate("content_filter"), estimate("length"), "a content-filter end draws one notice line, like the output limit")
        XCTAssertEqual(estimate("pause_turn"), estimate("length"))
        XCTAssertEqual(estimate("end_turn"), plain, "an ordinary end draws nothing")
        XCTAssertEqual(estimate("interrupted"), plain)
    }

    // MARK: H7 — a decode span too short to be a rate

    /// A reply delivered in one burst spans a few milliseconds from its first
    /// output to its last; dividing its tokens by that read as 100,000 tok/s.
    /// A request contributes a settled rate only across 250 ms or more — the
    /// helper's `metrics.minimumDecodeSpanMs` — and still counts as a request
    /// considered. A measured request contributes its tokens after the first.
    func testAOneBurstReplyContributesNoSettledRateAndASecondStillDoes() async throws {
        var burst = SettledThroughput()
        burst.add(decodeMilliseconds: 100, outputTokens: 300)
        XCTAssertEqual(burst.samples, 0, "100 ms is one burst, not a measurement")
        XCTAssertEqual(burst.requests, 1, "It is still a request considered")
        XCTAssertNil(burst.tokensPerSecond)
        XCTAssertEqual(burst.coverage, "0/1 requests measured")
        var second = SettledThroughput()
        second.add(decodeMilliseconds: 1_000, outputTokens: 301)
        XCTAssertEqual(second.tokensPerSecond, 300, "the 300 tokens after the first over one second")
        var floor = SettledThroughput()
        floor.add(decodeMilliseconds: 250, outputTokens: 51)
        XCTAssertEqual(floor.tokensPerSecond, 200, "The floor itself is a measurement")

        // The archive's settled rate, which the report, the dashboard and the
        // turn figures read, applies the same floor in SQL.
        let root = scratchRoot("wire-decode-floor")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root, now: { Date(timeIntervalSince1970: 2000) })
        try await archive.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        func attempt(ttft: Double, decode: Double, output: Double, wall: Double) -> [String: WireValue] {
            ["attemptId": .string(UUID().uuidString), "sessionId": .string("s"), "turnId": .string("t"), "purpose": .string("turn"),
             "api": .string("openai-responses"), "requestedModel": .string("router"), "mode": .string("off"), "outcome": .string("completed"),
             "wallTimestamp": .number(wall), "dispatchWallTimestamp": .number(wall), "timingVersion": .number(2),
             "timings": .object(["dispatch": .number(100), "firstContent": .number(100 + ttft), "modelComplete": .number(100 + ttft + decode),
                                 "httpEnd": .number(110 + ttft + decode)]),
             "messageIds": .array([.string("t")]), "outputMessageIds": .array([.string("a-\(wall)")]),
             "usage": .object(["inputIncludingCache": .number(100), "output": .number(output)])]
        }
        for value in [attempt(ttft: 400, decode: 100, output: 301, wall: 1990), attempt(ttft: 400, decode: 1_000, output: 301, wall: 1995)] {
            try await archive.begin(value, workspace: "w"); try await archive.finish(value)
        }
        let window = try await archive.dashboard(DashboardFilter(from: Date(timeIntervalSince1970: 1900), until: Date(timeIntervalSince1970: 2001), bucketCount: 2))
        let settled = window.gateway.settledThroughput
        XCTAssertEqual(settled.samples, 1, "Only the one-second span is a measurement")
        XCTAssertEqual(settled.decodeMilliseconds, 1_000)
        XCTAssertEqual(settled.tokensPerSecond, 300, "Never (300 + 300) / 1.1 s, and never 3,000 tok/s")
        try await archive.close()
    }

    // MARK: A held terminal event is not decode time

    /// A gateway can hold `response.completed` while it computes usage and
    /// cost. This reply generated its 101 tokens over one second, and the
    /// wire gateway held the terminal event two seconds more. It decoded at
    /// (101 − 1) / 1 s: the session pill, the sidebar's latest rate and
    /// Session info all quote that, never 101 over the three seconds from the
    /// first token to the terminal event.
    @MainActor func testAHeldTerminalEventDilutesNeitherTheSessionPillNorTheSidebarNorSessionInfo() async throws {
        let chat = try await WireChat()
        addTeardownBlock { @MainActor in await chat.close() }
        try await chat.sendAndWait("wire decode 2000") { rows in rows.contains { $0.text.contains("decoded-12") } }
        try await chat.waitUntil("the request's settled accounting") {
            chat.session.footer.timing.latest?.outputTokens == 101 && chat.session.footer.gateway.settledThroughput.samples == 1
                && chat.session.metrics["timings"]?.object?["lastContent"]?.number != nil
        }
        // What the helper observed, and what the archive made of it.
        let timings = try XCTUnwrap(chat.session.metrics["timings"]?.object)
        let first = try XCTUnwrap(timings["firstContent"]?.number), last = try XCTUnwrap(timings["lastContent"]?.number)
        let terminal = try XCTUnwrap(timings["modelComplete"]?.number)
        let span = try XCTUnwrap(chat.session.footer.timing.latest?.streamingMilliseconds)
        XCTAssertEqual(span, last - first, accuracy: 1e-6, "The archived decode span is first → last output")
        // About the one second the model generated. Under the gate's parallel
        // load its events can arrive half a second early or late; the span still
        // stops short of the two seconds the gateway held the terminal event.
        XCTAssertGreaterThanOrEqual(span, 500); XCTAssertLessThan(span, 1_900, "The model generated for one second, never the held two")
        XCTAssertGreaterThanOrEqual(terminal - last, 1_900, "The gateway held the terminal event two seconds after the last token")
        let decode = 100 / (span / 1_000), diluted = 101 / ((terminal - first) / 1_000)
        print("PERF held-terminal decodeTokPerSec=\(String(format: "%.1f", decode)) dividedToTerminal=\(String(format: "%.1f", diluted)) spanMs=\(Int(span)) heldMs=\(Int(terminal - last))")
        XCTAssertEqual(try XCTUnwrap(chat.session.metrics["metrics"]?.object?["decodeTokensPerSecond"]?.number), decode, accuracy: 1e-6,
                       "The helper's own figure for the attempt is the app's")
        XCTAssertGreaterThan(decode, diluted * 2)

        // The session pill under the composer.
        let pill = SessionStatsPresentation(gateway: chat.session.footer.gateway, work: WorkSplit(timing: chat.session.footer.turnTiming))
        XCTAssertEqual(try XCTUnwrap(pill.throughput.tokensPerSecond), decode, accuracy: 1e-6)
        XCTAssertTrue(pill.gaugeLabel.hasSuffix(" · " + MetricFormat.throughput(decode)), pill.gaugeLabel)
        // The sidebar's latest rate.
        let row = ChatRowStats(totals: chat.session.footer.gateway, timing: chat.session.footer.timing)
        XCTAssertEqual(row.rateLabel, "Latest " + SessionRatePresentation.compactRate(decode))
        XCTAssertEqual(try XCTUnwrap(SessionRatePresentation(history: chat.session.footer.timing).latest), decode, accuracy: 1e-6)
        // Session info: the latest request, the session figure and the session tile.
        let info = SessionInfoTiming(history: chat.session.footer.timing, work: [:])
        XCTAssertEqual(try XCTUnwrap(info.latestRate), decode, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(info.averageRate), decode, accuracy: 1e-6)
        let usage = try await chat.model.traces.sessionMetrics(sessionID: chat.id, workspaceID: chat.chat.workspaceID)
        XCTAssertEqual(try XCTUnwrap(usage.gateway.settledThroughput.tokensPerSecond), decode, accuracy: 1e-6)

        // One span for the request everywhere a duration is quoted: the
        // Inspector's Stream (the attempt's retained metadata, as the Inspector
        // lists it), the ledger's Generation and the report's Streaming.
        let recorded = try await chat.model.traces.list(sessionID: chat.id)
        let attempt = try XCTUnwrap(recorded.first { $0["usage"]?.object?["output"]?.number == 101 })
        XCTAssertEqual(try XCTUnwrap(attempt["metrics"]?.object?["streamDurationMs"]?.number), span, accuracy: 1e-6, "Inspector Stream = the decode span")
        XCTAssertNil(attempt["metrics"]?.object?["outputTokensPerSecond"], "No round-trip rate is recorded beside it")
        let ledger = SessionRequestLedger(history: chat.session.footer.timing)
        XCTAssertEqual(ledger.rows.last?.generation, MetricFormat.latency(span), "Ledger Generation = the decode span")
        let report = try await chat.model.traces.dashboard(DashboardFilter(from: Date().addingTimeInterval(-600), until: Date().addingTimeInterval(1),
                                                                         sessionID: chat.id, status: "all", bucketCount: 2))
        let reported = try XCTUnwrap(report.requests.first { $0.id == attempt["attemptId"]?.string })
        XCTAssertEqual(try XCTUnwrap(reported.streaming), span, accuracy: 1e-6, "Report Streaming = the decode span")

        // On screen: the gauge pill in the chat's own pane, read off its pixels.
        let rendered = try await SessionTimingTests.recognizedText(in: chat.window)
        XCTAssertTrue(rendered.contains(MetricFormat.throughput(decode)), "The pill quotes the decode rate. OCR: \(rendered)")
        XCTAssertFalse(rendered.contains(MetricFormat.throughput(diluted)), "No figure divides by the held terminal. OCR: \(rendered)")
    }

    // MARK: H10 — receipts and finished tasks only when they change

    /// Every snapshot used to carry the chat's command receipts (up to 128)
    /// and finished tasks (up to 64), once per streamed token. The display
    /// now sends back the revisions it holds and keeps what it holds when the
    /// helper leaves it out — and a receipt it already holds still settles a
    /// pending submission.
    @MainActor func testReceiptsSettleWhileSnapshotsLeaveOutReceiptsAndTasksThatDidNotChange() async throws {
        let chat = try await WireChat()
        addTeardownBlock { @MainActor in await chat.close() }
        for turn in 0..<3 {
            try await chat.sendAndWait("wire reply \(turn)") { rows in rows.filter { $0.text == "Wire reply." }.count == turn + 1 }
        }
        try await chat.waitUntil("every submission settled") { try await chat.pending().isEmpty }
        let receipts = try await chat.settled()
        XCTAssertEqual(receipts.count, 3, "Each submission's pending record became a receipt")
        try await chat.waitUntil("three finished tasks") { chat.session.taskPresentation?.recent.count == 3 }
        // H7's floor is the helper's: its latest attempt says which it applied.
        try await chat.waitUntil("the latest attempt's metrics") { chat.session.metrics["metrics"]?.object?["minimumDecodeSpanMs"] != nil }
        XCTAssertEqual(chat.session.metrics["metrics"]?.object?["minimumDecodeSpanMs"]?.number, SettledThroughput.minimumDecodeMilliseconds)

        chat.replies.removeAll()
        try await chat.sendAndWait("wire stream 60") { rows in rows.contains { $0.text.hasSuffix("token-059 ") } }
        let perToken = chat.snapshots.filter { !($0.result.object?["messageDelta"]?.object?["appends"]?.array ?? []).isEmpty }
        XCTAssertFalse(perToken.isEmpty, "The reply streamed as appends")
        let carrying = perToken.filter { $0.result.object?["commands"] != nil || $0.result.object?["taskPresentation"] != nil }
        let sizes = perToken.map { WireChat.bytes($0.result) }.sorted()
        print("PERF wire per-token snapshot (3 finished turns): frames=\(perToken.count) carryingReceiptsOrTasks=\(carrying.count) medianBytes=\(sizes.isEmpty ? 0 : sizes[sizes.count / 2]) maxBytes=\(sizes.last ?? 0)")
        for reply in perToken {
            // The display sends back what it holds, every time; the helper
            // then sends either only when it changed since.
            let sent = reply.params, result = reply.result.object ?? [:]
            XCTAssertNotNil(sent["commandsRevision"], "The receipts held are named by revision")
            XCTAssertNotNil(sent["taskPresentationRevision"], "The tasks held are named by revision")
            if result["commands"] != nil { XCTAssertNotEqual(result["commandsRevision"], sent["commandsRevision"], "Receipts travel only when they changed") }
            if result["taskPresentation"] != nil { XCTAssertNotEqual(result["taskPresentationRevision"], sent["taskPresentationRevision"], "Tasks travel only when they changed") }
        }
        try await chat.waitUntil("the finished task still arrives when it changed") { chat.session.taskPresentation?.recent.count == 4 }
        try await chat.waitUntil("the stream's submission settled") { try await chat.pending().isEmpty }

        // A settle cut short after the receipt was held: the pending record
        // is still there, and the helper has no new receipt to send.
        let receipt = try XCTUnwrap(receipts.first)
        try await chat.model.store?.put(CommandIntent(id: receipt.id, sessionID: chat.id, turnID: receipt.turnID, text: "", state: "acknowledged", epoch: nil),
                                        kind: "pending:\(chat.id)", id: receipt.id)
        chat.model.pendingIntentsChanged(chat.id)
        chat.replies.removeAll()
        chat.model.refresh(chat.id)
        try await chat.waitUntil("the held receipt settles the pending record") { try await chat.pending().isEmpty }
        XCTAssertFalse(chat.snapshots.isEmpty)
        XCTAssertTrue(chat.snapshots.allSatisfy { $0.result.object?["commands"] == nil },
                      "The snapshot that settled it left the unchanged receipts out")

        // A chat opened again on a new helper is sent both whole.
        try await XCTUnwrap(chat.host).shutdownAndWait()
        try await chat.waitUntil("the helper is gone") { !chat.model.opened.contains(chat.id) }
        _ = try await chat.model.open(try XCTUnwrap(chat.model.record(chat.id)))
        chat.replies.removeAll()
        chat.model.refresh(chat.id)
        try await chat.waitUntil("a snapshot from the new helper") { !chat.snapshots.isEmpty }
        let first = try XCTUnwrap(chat.snapshots.first?.result.object)
        XCTAssertNotNil(first["commands"], "A re-bound chat is sent its receipts")
        XCTAssertNotNil(first["taskPresentation"], "A re-bound chat is sent its tasks")
        try await chat.waitUntil("the tasks are held again") { chat.session.taskPresentation?.recent.count == 4 }
    }

    // MARK: H8 — tool arguments that grow in place

    /// A write streams its whole file as arguments. Each delta used to resend
    /// the streaming row — every argument byte so far, twice (the card and its
    /// timeline part). The display takes the arguments as appends and ends
    /// with exactly the bytes the provider sent, the bytes the whole-row path
    /// ends with too.
    @MainActor func testStreamedToolArgumentsArriveAsAppendsAndEndByteIdentical() async throws {
        let chat = try await WireChat()
        addTeardownBlock { @MainActor in await chat.close() }
        var streamed: ToolView?
        let watch = chat.session.transcriptChanges.sink { rows in
            if let card = rows.last(where: { $0.state == "streaming" })?.tools?.first(where: { $0.name == "write" }) { streamed = card }
        }
        defer { watch.cancel() }
        struct Run { var card: ToolView; var snapshots: Int; var wholeRows: Int; var appendFrames: Int; var argumentBytesSent: Int
                     var heldArgumentBytes: Int; var resyncPages: Int; var wholeAfterAppends: Int
                     var meanDeltaBytes: Int; var maxDeltaBytes: Int; var meanBytes: Int; var maxBytes: Int; var largest: String }
        func write(_ turn: Int) async throws -> Run {
            streamed = nil; chat.replies.removeAll()
            try await chat.sendAndWait("wire write 200") { rows in rows.filter { $0.text == "Tool round finished." }.count == turn }
            let card = try XCTUnwrap(streamed, "The write card was shown while its arguments streamed")
            // The replies that carried the streaming row: whole (in a page or
            // a row update) or as appends to its call's arguments.
            func streamingRow(_ rows: [WireValue]?) -> [String: WireValue]? {
                (rows ?? []).compactMap(\.object).first { $0["state"]?.string == "streaming" && ($0["tools"]?.array ?? []).contains { $0.object?["name"]?.string == "write" } }
            }
            var argumentBytesSent = 0, wholeRows = 0, appendFrames = 0
            // What the display holds: the appends build on the last whole row
            // it was sent before the first of them. A page it did not apply —
            // the reader's viewport or the presentation generation moved while
            // the page was on its way — comes again whole: that resync is the
            // documented recovery, at most one page per send, and only before
            // the appends begin. Once they have, nothing is sent whole again.
            var heldBeforeAppends = 0, appendedBytes = 0, carriersBeforeAppends = 0, resyncPages = 0, wholeAfterAppends = 0
            var streaming: [WireChat.Reply] = []
            for reply in chat.snapshots {
                let result = reply.result.object ?? [:], delta = result["messageDelta"]?.object
                let page = streamingRow(result["messages"]?.array)
                let whole = page ?? streamingRow(delta?["rows"]?.array)
                let inputs = delta?["toolInputs"]?.array ?? []
                guard whole != nil || !inputs.isEmpty else { continue }
                streaming.append(reply)
                if let whole {
                    if delta != nil { wholeRows += 1 }
                    let call = (whole["tools"]?.array ?? []).compactMap(\.object).first { $0["name"]?.string == "write" }
                    let bytes = call?["input"]?.string?.utf8.count ?? 0
                    argumentBytesSent += bytes
                    if appendFrames == 0 {
                        // The card's first appearance, or a page sent again.
                        if carriersBeforeAppends > 0, page != nil { resyncPages += 1 }
                        carriersBeforeAppends += 1; heldBeforeAppends = bytes
                    } else { wholeAfterAppends += 1 }
                }
                if !inputs.isEmpty { appendFrames += 1 }
                let added = inputs.compactMap { $0.object?["text"]?.string?.utf8.count }.reduce(0, +)
                argumentBytesSent += added; appendedBytes += added
            }
            let bytes = streaming.map { WireChat.bytes($0.result) }
            // The row update alone — what H8 changes. The rest of a frame is
            // the run's other state (metrics every quarter second, a new
            // request's context), the same on both paths.
            let deltaBytes = streaming.map { WireChat.bytes($0.result.object?["messageDelta"] ?? $0.result.object?["messages"] ?? .null) }
            let biggest = streaming.max { WireChat.bytes($0.result) < WireChat.bytes($1.result) }?.result.object ?? [:]
            let largest = biggest.map { ($0.key, WireChat.bytes($0.value)) }.sorted { $0.1 > $1.1 }.prefix(3).map { "\($0.0)=\($0.1)" }.joined(separator: ",")
            return Run(card: card, snapshots: streaming.count, wholeRows: wholeRows, appendFrames: appendFrames, argumentBytesSent: argumentBytesSent,
                       heldArgumentBytes: heldBeforeAppends + appendedBytes, resyncPages: resyncPages, wholeAfterAppends: wholeAfterAppends,
                       meanDeltaBytes: deltaBytes.isEmpty ? 0 : deltaBytes.reduce(0, +) / deltaBytes.count, maxDeltaBytes: deltaBytes.max() ?? 0,
                       meanBytes: bytes.isEmpty ? 0 : bytes.reduce(0, +) / bytes.count, maxBytes: bytes.max() ?? 0, largest: largest)
        }
        let appended = try await write(1)
        let expected = try Data(contentsOf: chat.root.appendingPathComponent("wire-write-arguments.txt"))
        XCTAssertEqual(Data(appended.card.input.utf8), expected, "The card ends with exactly the arguments the provider streamed")
        XCTAssertEqual(appended.card.inputBytes, expected.count)
        XCTAssertLessThanOrEqual(appended.wholeRows, 1, "Only the card's first appearance sends the row whole")
        XCTAssertGreaterThanOrEqual(appended.appendFrames, 1, "The arguments grew as appends")
        XCTAssertLessThanOrEqual(appended.resyncPages, 1, "At most one page is sent again before the appends begin")
        XCTAssertEqual(appended.wholeAfterAppends, 0, "Once the appends begin, the row is never sent whole again")
        XCTAssertEqual(appended.heldArgumentBytes, expected.count, "Each argument byte crossed the wire once: the page the display holds, then the appends")
        XCTAssertTrue(FileManager.default.fileExists(atPath: chat.root.appendingPathComponent("wire-notes.txt").path), "The call then ran")
        // The same write on the whole-row path, as every reader before 0.1.85 took it.
        chat.session.takesToolInputAppends = false
        let whole = try await write(2)
        XCTAssertEqual(Data(whole.card.input.utf8), expected)
        XCTAssertEqual(Data(appended.card.input.utf8), Data(whole.card.input.utf8), "Byte-identical to the whole-row path")
        XCTAssertEqual(appended.card.inputBytes, whole.card.inputBytes)
        XCTAssertEqual(whole.appendFrames, 0)
        XCTAssertGreaterThan(whole.argumentBytesSent, expected.count, "The whole-row path sends the arguments so far again with every row")
        for (name, run) in [("appends", appended), ("whole rows", whole)] {
            print("PERF wire streamed write (200 deltas, \(expected.count) argument bytes), \(name): snapshots=\(run.snapshots) wholeRowResends=\(run.wholeRows) resyncPages=\(run.resyncPages) appendFrames=\(run.appendFrames) argumentBytesSent=\(run.argumentBytesSent) rowUpdate meanBytes=\(run.meanDeltaBytes) maxBytes=\(run.maxDeltaBytes) frame meanBytes=\(run.meanBytes) maxBytes=\(run.maxBytes) (largest fields \(run.largest))")
        }
    }

    /// The row update itself: text appended to one call's input, checked
    /// against the size of the whole input. A row or card the update does not
    /// fit, or a size that does not add up, asks for the whole page.
    func testAToolInputAppendGrowsTheCardInPlaceOrAsksForTheWholePage() throws {
        let card = ToolView(id: "call", name: "write", state: "preparing", input: #"{"path":"a.txt","content":"héllo"#, output: "",
                            durationMs: nil, truncated: false, inputTruncated: false, inputBytes: 31)
        let streaming = TranscriptMessage(id: "stream", role: "assistant", text: "", tools: [card], state: "streaming")
        let held = [TranscriptMessage(id: "u", role: "user", text: "Write it"), streaming]
        func patch(id: String = "stream", call: String = "call", text: String, bytes: Int) -> WireValue {
            .object(["base": .string("r1"), "rows": .array([]), "appends": .array([]), "parts": .array([]),
                     "toolInputs": .array([.object(["id": .string(id), "callID": .string(call), "text": .string(text), "inputBytes": .number(Double(bytes))])])])
        }
        let tail = " wörld 中文🙂 \\\"quoted\\\"\"}"
        let total = card.input.utf8.count + tail.utf8.count
        let applied = try XCTUnwrap(TranscriptRowUpdates.apply(patch(text: tail, bytes: total), to: held))
        XCTAssertEqual(applied.map(\.id), ["u", "stream"])
        XCTAssertEqual(applied[1].tools?.first?.input, card.input + tail)
        XCTAssertEqual(applied[1].tools?.first?.inputBytes, total)
        XCTAssertEqual(applied[0], held[0], "Other rows are the rows held")
        XCTAssertEqual(applied[1].tools?.first?.state, "preparing")
        XCTAssertNil(TranscriptRowUpdates.apply(patch(id: "gone", text: tail, bytes: total), to: held), "A row not held")
        XCTAssertNil(TranscriptRowUpdates.apply(patch(call: "other", text: tail, bytes: total), to: held), "A card not held")
        XCTAssertNil(TranscriptRowUpdates.apply(patch(text: tail, bytes: total + 1), to: held), "Held input plus the append is not the whole")
        // Two hundred appends end exactly where the whole input does.
        let document = String(repeating: "line · 中文🙂 café \\\"q\\\" \\\\ end\\n", count: 120)
        let scalars = Array(document.unicodeScalars)
        var page = [TranscriptMessage(id: "stream", role: "assistant", text: "", tools: [ToolView(id: "call", name: "write", state: "preparing", input: "", output: "", durationMs: nil, truncated: false)], state: "streaming")]
        var sent = 0
        for index in 1...200 {
            let cut = scalars.count * index / 200
            var piece = String.UnicodeScalarView(); piece.append(contentsOf: scalars[sent..<cut]); sent = cut
            let prefix = String(String.UnicodeScalarView(scalars[0..<cut]))
            page = try XCTUnwrap(TranscriptRowUpdates.apply(patch(text: String(piece), bytes: prefix.utf8.count), to: page), "append \(index)")
        }
        XCTAssertEqual(Data(try XCTUnwrap(page.first?.tools?.first?.input).utf8), Data(document.utf8))
    }

    /// Opt-in (PI_PERF_WIRE=1): the per-token snapshot of a chat with 70
    /// finished turns — 70 receipts and the 64 finished tasks the helper
    /// keeps — with the revisions sent back, and without, as before 0.1.85.
    @MainActor func testPerTokenSnapshotWithSeventyFinishedTurns() async throws {
        try XCTSkipUnless(testEnvironment("PI_PERF_WIRE") != nil, "Set PI_PERF_WIRE=1 to measure the per-token snapshot with 70 finished turns")
        let chat = try await WireChat()
        addTeardownBlock { @MainActor in await chat.close() }
        let host = try XCTUnwrap(chat.host)
        for turn in 0..<70 {
            let command = UUID().uuidString
            _ = try await host.request("turn.submit", sessionID: chat.id, params: ["text": .string("wire reply \(turn)"), "clientTurnId": .string(UUID().uuidString)], commandID: command)
            try await chat.waitUntil("turn \(turn) finished") {
                let status = try await host.request("session.status", sessionID: chat.id).object ?? [:]
                return status["state"]?.string == "idle" && (status["commands"]?.array ?? []).contains { $0.object?["commandId"]?.string == command && $0.object?["state"]?.string == "completed" }
            }
        }
        func stream(_ turn: Int, leavingOut: Bool) async throws -> (frames: Int, median: Int, max: Int, carrying: Int, heldBytes: Int, fields: String) {
            chat.session.leavesOutHeldState = leavingOut
            chat.replies.removeAll()
            try await chat.sendAndWait("wire stream 60") { rows in rows.filter { $0.text.hasSuffix("token-059 ") }.count == turn }
            let perToken = chat.snapshots.filter { !($0.result.object?["messageDelta"]?.object?["appends"]?.array ?? []).isEmpty }
                .sorted { WireChat.bytes($0.result) < WireChat.bytes($1.result) }
            let sizes = perToken.map { WireChat.bytes($0.result) }
            let carrying = perToken.filter { $0.result.object?["commands"] != nil || $0.result.object?["taskPresentation"] != nil }.count
            // The receipts and tasks the tokens carried, in all.
            let heldBytes = perToken.map { reply in
                ["commands", "taskPresentation"].compactMap { reply.result.object?[$0] }.map(WireChat.bytes).reduce(0, +)
            }.reduce(0, +)
            // What the median frame is made of, largest first.
            let median = perToken.isEmpty ? [:] : perToken[perToken.count / 2].result.object ?? [:]
            let fields = median.map { ($0.key, WireChat.bytes($0.value)) }.sorted { $0.1 > $1.1 }.prefix(6).map { "\($0.0)=\($0.1)" }.joined(separator: ",")
            return (perToken.count, sizes.isEmpty ? 0 : sizes[sizes.count / 2], sizes.last ?? 0, carrying, heldBytes, fields)
        }
        let with = try await stream(1, leavingOut: true)
        let without = try await stream(2, leavingOut: false)
        print("PERF wire per-token snapshot (70 finished turns): revisions sent back frames=\(with.frames) medianBytes=\(with.median) maxBytes=\(with.max) carrying=\(with.carrying) receiptAndTaskBytes=\(with.heldBytes) (median frame \(with.fields)); not sent frames=\(without.frames) medianBytes=\(without.median) maxBytes=\(without.max) carrying=\(without.carrying) receiptAndTaskBytes=\(without.heldBytes) (median frame \(without.fields))")
        // Shapes only: a frame's size also depends on how often the quarter-
        // second metrics ride along, which is the machine's load.
        XCTAssertFalse(with.frames == 0 || without.frames == 0, "Both replies streamed as appends")
        XCTAssertLessThan(with.heldBytes * 20, without.heldBytes, "A token carries neither the receipts nor the finished tasks")
        XCTAssertLessThan(with.median * 4, without.median)
    }
}
