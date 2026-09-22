import XCTest
import SwiftUI
@testable import PiApp

final class TurnRequestPopupTests: XCTestCase {
    @MainActor func testNativePopupLoadsWithoutConstraintFeedback() async throws {
        let record = TurnRequestRecord(metadata: metadata("layout"))
        let bytes = Data("event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[],\"model\":\"auto-router\"}}\n\n".utf8)
        let source = TurnRequestSource(sessionID: "session", list: { _ in TurnRequestPage(records: [record]) }, body: { _, _ in
            CapturedBodySource(metadata: { CapturedBodyMetadata(body: ["state": .string("complete"), "retainedBytes": .number(Double(bytes.count))], hash: nil) }, page: { _ in (bytes, bytes.count) })
        })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800)); window.contentView = anchor
        window.makeKeyAndOrderFront(nil)
        let button = NSButton(frame: NSRect(x: 600, y: 500, width: 20, height: 20)); anchor.addSubview(button)
        var running = turn(); running.live = true; running.outcome = nil; running.endedAt = nil
        running.taskKey = "popup-task"; running.startedAt = Date().timeIntervalSince1970 * 1000 - 1000
        running.liveStartedUptimeMs = ProcessInfo.processInfo.systemUptime * 1000 - 1000
        let actions = TranscriptActions(turnRequestSource: { source })
        let presenter = TurnInfoButton.Coordinator(turn: running, actions: actions)
        presenter.toggle(button)
        let popup = try XCTUnwrap(presenter.popover)
        defer { presenter.close(); window.orderOut(nil) }
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(popup.isShown)
        XCTAssertEqual(popup.contentSize.width, 680, accuracy: 1)
        XCTAssertEqual(popup.contentSize.height, 640, accuracy: 1)
        var finished = running; finished.live = false; finished.outcome = "completed"
        finished.elapsedMs = 3_123.456; finished.endedAt = (running.startedAt ?? 0) + 3_123.456
        presenter.update(turn: finished, actions: actions)
        try await Task.sleep(for: .milliseconds(100))
        let content = try XCTUnwrap(popup.contentViewController as? NSHostingController<TurnInfoView>)
        XCTAssertFalse(content.rootView.turn.isRunning, "An already-open Info popup must receive the terminal turn")
        let later = TurnInfoPresentation.live(content.rootView.turn, at: .now.addingTimeInterval(60),
                                             uptimeMs: ProcessInfo.processInfo.systemUptime * 1000 + 60_000)
        XCTAssertEqual(later.elapsedMs, 3_123.456)
        XCTAssertTrue(popup.isShown, "Updating completed metrics must not destroy a retained popup")
        popup.animates = false
        presenter.close(); XCTAssertFalse(popup.isShown)
    }
    private func turn() -> TurnSummary {
        var result = TurnSummary(replies: 1, tools: 1, startedAt: 1_000_000, endedAt: 1_010_000, elapsedMs: 10_000,
                                 modelMs: 8000, toolMs: 2000, live: false, files: 0, partial: false,
                                 accounting: TurnAccounting(), requests: [TranscriptMessage(id: "answer", role: "assistant", text: "Done", turn: "turn")], current: nil, notice: nil)
        result.taskRootID = "turn"
        return result
    }
    private func metadata(_ id: String, turn: String = "turn", session: String = "session", wall: Double = 1002) -> [String: WireValue] {
        ["attemptId": .string(id), "sessionId": .string(session), "turnId": .string(turn), "wallTimestamp": .number(wall),
         "mode": .string("off"), "purpose": .string("turn"), "api": .string("openai-responses"), "requestedModel": .string("auto-router"),
         "outcome": .string("running"), "messageIds": .array([.string("answer")])]
    }
    func testTurnScopeExcludesLaterContextReusePriorRetriesAndOtherWorkspaces() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let archive = PayloadArchive(root: folder, now: { Date(timeIntervalSince1970: 1005) })
        try await archive.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 86400)
        let owned = UUID().uuidString, prior = UUID().uuidString, reused = UUID().uuidString, unrelated = UUID().uuidString
        let origin = UUID().uuidString
        try await archive.begin(metadata(owned), workspace: "workspace")
        try await archive.begin(metadata(prior, wall: 900), workspace: "workspace")
        try await archive.begin(metadata(reused, turn: "later", wall: 1004), workspace: "workspace")
        try await archive.begin(metadata(unrelated), workspace: "different")
        var inherited = metadata(origin, turn: "parent-turn", session: "parent", wall: 1001)
        inherited["outputMessageIds"] = .array([.string("answer")])
        try await archive.begin(inherited, workspace: "workspace")
        let rows = try await archive.turnRequests(sessionID: "session", workspaceID: "workspace", scope: TurnRequestScope(turn()))
        XCTAssertEqual(rows.compactMap { $0["attemptId"]?.string }, [origin, owned])
        let general = try await archive.list(sessionID: "session", messageID: "answer", workspaceID: "workspace")
        XCTAssertTrue(general.contains { $0["attemptId"]?.string == reused }, "General inspection still follows context reuse")
        try await archive.close(); try FileManager.default.removeItem(at: folder)
    }
    func testTurnRequestPagesCoverAllRequestsInChronologicalOrder() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let archive = PayloadArchive(root: folder, now: { Date(timeIntervalSince1970: 1005) })
        try await archive.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 86400)
        var ids: [String] = []
        for i in 0..<130 {
            let id = UUID().uuidString; ids.append(id)
            try await archive.begin(metadata(id, wall: 1001 + Double(i) / 100), workspace: "workspace")
        }
        let first = try await archive.turnRequests(sessionID: "session", workspaceID: "workspace", scope: TurnRequestScope(turn()))
        let next = try await archive.turnRequests(sessionID: "session", workspaceID: "workspace", scope: TurnRequestScope(turn()), offset: 128)
        XCTAssertEqual((first + next).compactMap { $0["attemptId"]?.string }, ids)
        try await archive.close(); try FileManager.default.removeItem(at: folder)
    }
    @MainActor func testLiveMergeKeepsLatestMetadataWithoutDuplicatingAttempts() {
        let id = UUID().uuidString
        let durable = TurnRequestRecord(metadata: metadata(id))
        var complete = metadata(id); complete["outcome"] = .string("completed"); complete["status"] = .number(200)
        let live = TurnRequestRecord(metadata: complete, liveOnly: true)
        XCTAssertEqual(TurnRequestSource.merge(durable: [durable], live: [live]), [live])
        let saved = TurnRequestRecord(metadata: complete)
        XCTAssertEqual(TurnRequestSource.merge(durable: [saved], live: [live]), [saved])
        var scope = TurnRequestScope(turn()); scope.outputIDs = []
        XCTAssertFalse(scope.contains(metadata(id, turn: "later"), sessionID: "session"))
        XCTAssertFalse(scope.contains(metadata(id, wall: 900), sessionID: "session"))
        XCTAssertFalse(scope.contains(metadata(id, session: "another"), sessionID: "session"))
    }
    func testManualCompactionShowsOnlyItsRunningUtilityRequest() async throws {
        var compact = turn(); compact.live = true; compact.phase = "compacting"; compact.taskKey = "utility:epoch"
        compact.taskRootID = nil; compact.requests = []; compact.startedAt = nil; compact.endedAt = nil
        let scope = TurnRequestScope(compact)
        var capture = metadata(UUID().uuidString, turn: "old-context-turn"); capture["purpose"] = .string("compaction")
        XCTAssertTrue(scope.contains(capture, sessionID: "session"))
        var completed = capture; completed["attemptId"] = .string(UUID().uuidString); completed["outcome"] = .string("completed")
        XCTAssertFalse(scope.contains(completed, sessionID: "session"))
        XCTAssertFalse(scope.contains(metadata("normal"), sessionID: "session"))
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let archive = PayloadArchive(root: folder, now: { Date(timeIntervalSince1970: 1005) })
        try await archive.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 86400)
        try await archive.begin(capture, workspace: "workspace")
        try await archive.begin(completed, workspace: "workspace")
        try await archive.finish(completed)
        let rows = try await archive.turnRequests(sessionID: "session", workspaceID: "workspace", scope: scope)
        XCTAssertEqual(rows.compactMap { $0["attemptId"]?.string }, [capture["attemptId"]!.string!])
        try await archive.close(); try FileManager.default.removeItem(at: folder)
    }
    @MainActor func testRefreshPreservesSelectedRequestAndRelayCarriesSource() async throws {
        var records = [TurnRequestRecord(metadata: metadata("first", wall: 1001)), TurnRequestRecord(metadata: metadata("second", wall: 1002))]
        let source = TurnRequestSource(sessionID: "session", list: { _ in TurnRequestPage(records: records) }, body: { _, _ in
            CapturedBodySource(metadata: { throw CaptureFailure.unavailable }, page: { _ in throw CaptureFailure.unavailable })
        })
        let controller = TurnRequestController(), scope = TurnRequestScope(turn())
        await controller.load(scope, source: source)
        XCTAssertEqual(controller.selectedID, "second")
        controller.move(-1)
        records.append(TurnRequestRecord(metadata: metadata("third", wall: 1003)))
        await controller.load(scope, source: source)
        XCTAssertEqual(controller.selectedID, "first")
        controller.move(-1); XCTAssertEqual(controller.selectedID, "first")
        controller.move(1); XCTAssertEqual(controller.selectedID, "second")
        let relay = TranscriptActionRelay()
        relay.current = TranscriptActions(turnRequestSource: { source })
        XCTAssertEqual(relay.forwarded.turnRequestSource?()?.sessionID, "session")
    }
    @MainActor func testSupersededRequestLookupCannotReplaceNewSelection() async {
        var finish: CheckedContinuation<TurnRequestPage, Never>?
        let old = TurnRequestSource(sessionID: "old", list: { _ in await withCheckedContinuation { finish = $0 } }, body: { _, _ in
            CapturedBodySource(metadata: { throw CaptureFailure.unavailable }, page: { _ in throw CaptureFailure.unavailable })
        })
        let record = TurnRequestRecord(metadata: metadata("new"))
        let fresh = TurnRequestSource(sessionID: "new", list: { _ in TurnRequestPage(records: [record]) }, body: old.body)
        let controller = TurnRequestController(), scope = TurnRequestScope(turn())
        let slow = Task { await controller.load(scope, source: old) }
        while finish == nil { await Task.yield() }
        await controller.load(scope, source: fresh)
        finish?.resume(returning: TurnRequestPage(records: [])); await slow.value
        XCTAssertEqual(controller.selectedID, "new")
    }
    func testSearchFindsCaseInsensitiveUnicodeAndEndOfLargeBody() throws {
        let text = String(repeating: "ordinary payload ", count: 50_000) + "🌍 CACHED-token 🌍 cached-TOKEN"
        let result = try PayloadSearchResult.find(text: text, query: "cached-token")
        XCTAssertEqual(result.matches.count, 2)
        XCTAssertEqual((text as NSString).substring(with: result.matches[1]), "cached-TOKEN")
        XCTAssertTrue(try PayloadSearchResult.find(text: text, query: "missing-query").matches.isEmpty)
        let capped = try PayloadSearchResult.find(text: String(repeating: "a", count: 100), query: "a", limit: 3)
        XCTAssertEqual(capped.matches.count, 3); XCTAssertTrue(capped.limited)
    }
    @MainActor func testSearchIncludesHeadersNestedJSONAndCombinedStreamingResponse() async throws {
        let bytes = Data("event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"model\":\"gpt-5.4-mini\",\"output\":[{\"content\":[{\"text\":\"deeply nested answer\"}]}]}}\n\n".utf8)
        let descriptor = CapturedBodyMetadata(body: ["state": .string("complete"), "retainedBytes": .number(Double(bytes.count))], hash: nil)
        let document = try CapturedBodyDocument.parse(bytes: bytes, metadata: descriptor)
        let controller = PayloadSearchController()
        let headers: [String: WireValue] = ["x-litellm-model-name": .string("openai/gpt-5.4-mini"), "authorization": .string("Bearer ********-key")]
        await controller.search(document: document, format: .combined, headers: headers, kind: "response", query: "LITELLM")
        XCTAssertEqual(controller.result?.matches.count, 1)
        await controller.search(document: document, format: .combined, headers: headers, kind: "response", query: "deeply nested answer")
        XCTAssertEqual(controller.result?.matches.count, 1)
        XCTAssertTrue(controller.result?.text.contains("Response headers") == true)
        XCTAssertTrue(controller.result?.text.contains("Response body") == true)
        await controller.search(document: nil, format: .json, headers: headers, kind: "request", query: "authorization")
        XCTAssertEqual(controller.result?.matches.count, 1, "Headers remain searchable when the body expired")
    }
    func testLiveLabelsUseExistingCompactionAndRetryStyle() {
        var value = turn(); value.live = true; value.phase = "compacting"
        XCTAssertEqual(TurnInfoPresentation.workingLabel(value), "Compacting context…")
        value.phase = "retrying"
        XCTAssertEqual(TurnInfoPresentation.workingLabel(value), "Waiting to retry…")
    }
}
