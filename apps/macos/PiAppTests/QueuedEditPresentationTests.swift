import XCTest
@testable import PiApp

final class QueuedEditPresentationTests: XCTestCase {
    private func snapshot(_ revision: Int, text: String, count: Int = 1) -> [String: WireValue] {
        ["queueEditRevision": .number(Double(revision)), "queueCount": .number(Double(count)),
         "queue": .array(count == 0 ? [] : [.object(["turnId": .string("q"), "kind": .string("steering"), "text": .string(text), "textRevision": .number(1)])])]
    }

    private func savedReply(_ revision: Int) -> [String: WireValue] {
        ["accepted": .bool(true), "outcome": .string("saved"), "turnId": .string("q"), "revision": .number(Double(revision))]
    }

    @MainActor func testNoticeComponentsCanChangeAndClearInEitherOrder() {
        let view = SessionDisplay(id: "chat")
        for queueFirst in [false, true] {
            view.queueEditNotice = "Keep the rewrite."
            view.preflightNotice = "Run stopped."
            XCTAssertEqual(view.notice, "Keep the rewrite.\nRun stopped.")
            view.preflightNotice = "Run interrupted."
            XCTAssertEqual(view.notice, "Keep the rewrite.\nRun interrupted.")
            if queueFirst {
                view.queueEditNotice = ""
                XCTAssertEqual(view.notice, "Run interrupted.")
                view.preflightNotice = ""
            } else {
                view.preflightNotice = ""
                XCTAssertEqual(view.notice, "Keep the rewrite.")
                view.queueEditNotice = ""
            }
            XCTAssertEqual(view.notice, "")
        }
    }

    @MainActor func testUnchangedEmptyNoticeComponentsLeaveOtherNoticesAlone() {
        let view = SessionDisplay(id: "chat")
        view.notice = "Host interrupted. No command was replayed."
        view.queueEditNotice = ""; view.preflightNotice = ""
        XCTAssertEqual(view.notice, "Host interrupted. No command was replayed.")
    }

    @MainActor func testASnapshotStartedBeforeSaveCannotUndoTheAcknowledgedRow() {
        let view = SessionDisplay(id: "chat")
        view.applyQueueSnapshot(snapshot(1, text: "Original"))
        view.queueEditOriginal = "Original"
        view.adoptQueueEditHold(nil, revision: 2)
        view.reflectQueuedRewrite(turnID: "q", text: "Saved", reply: savedReply(2))
        XCTAssertNil(view.applyQueueSnapshot(snapshot(1, text: "Original")), "The real snapshot revision guard rejects the stale queue")
        XCTAssertEqual(QueuedMessage.from(view.queue).first?.text, "Saved")
        XCTAssertEqual(view.queue.first?["kind"]?.string, "steering")
        XCTAssertEqual(view.queueCount, 1)
        XCTAssertNotNil(view.applyQueueSnapshot(snapshot(2, text: "Saved", count: 0)))
        XCTAssertTrue(view.queue.isEmpty); XCTAssertEqual(view.queueCount, 0)
    }

    @MainActor func testLateSaveReplyCannotResurrectDeliveredOrNewlyEditedRows() {
        let view = SessionDisplay(id: "chat")
        view.applyQueueSnapshot(snapshot(4, text: "Newer edit"))
        view.reflectQueuedRewrite(turnID: "q", text: "Older save", reply: savedReply(2))
        XCTAssertEqual(view.queue.first?["text"]?.string, "Newer edit")
        view.applyQueueSnapshot(snapshot(4, text: "", count: 0))
        view.reflectQueuedRewrite(turnID: "q", text: "Older save", reply: savedReply(4))
        XCTAssertTrue(view.queue.isEmpty)
    }

    @MainActor func testRepeatedSaveAcknowledgementCannotRollBackANewerRewrite() {
        assertHistoricalSaveKeepsNewerText(["accepted": .bool(true), "outcome": .string("saved"), "repeated": .bool(true)])
    }

    @MainActor func testSavedStatusCannotRollBackANewerRewrite() {
        assertHistoricalSaveKeepsNewerText(["state": .string("saved"), "textDigest": .string(QueuedEditDraft.digest("Older save"))])
    }

    @MainActor private func assertHistoricalSaveKeepsNewerText(_ acknowledgement: [String: WireValue], file: StaticString = #filePath, line: UInt = #line) {
        let view = SessionDisplay(id: "chat")
        view.applyQueueSnapshot(snapshot(4, text: "Newer edit"))
        let rows = view.queue
        // Historical outcomes report the helper's current revision, which
        // an unrelated edit advanced after the displayed rewrite.
        var reply = acknowledgement
        reply["turnId"] = .string("q"); reply["revision"] = .number(5)
        view.adoptQueueEditHold(nil, revision: 5)
        view.reflectQueuedRewrite(turnID: "q", text: "Older save", reply: reply)
        XCTAssertEqual(view.queue, rows, "An old acknowledgement is not current row content", file: file, line: line)
        XCTAssertEqual(view.queuePresentedEditRevision, 4, "Only verified row content advances the presented revision", file: file, line: line)
    }

    @MainActor func testEditsBeyondThePreviewAdvanceRowIdentityWithoutRetainingTheWholeDraft() {
        let view = SessionDisplay(id: "chat"), prefix = String(repeating: "é", count: 2_000)
        view.applyQueueSnapshot(snapshot(1, text: String(prefix.prefix(512))))
        view.queueEditOriginal = prefix + "A"
        view.adoptQueueEditHold(nil, revision: 2)
        let original = QueuedMessage.from(view.queue).first?.contentKey
        view.reflectQueuedRewrite(turnID: "q", text: prefix + "B", reply: savedReply(2))
        XCTAssertNotEqual(QueuedMessage.from(view.queue).first?.contentKey, original)
        XCTAssertLessThanOrEqual(QueuedMessage.from(view.queue).first?.text.utf8.count ?? .max, 1_024)
        XCTAssertEqual(view.queue.first?["textBytes"]?.number, Double((prefix + "B").utf8.count))
        XCTAssertEqual(view.queue.first?["textTruncated"]?.bool, true)
        XCTAssertEqual(view.queue.first?["textRevision"]?.number, 2)
        view.reflectQueuedRewrite(turnID: "q", text: prefix + "B", reply: savedReply(2))
        XCTAssertEqual(view.queue.first?["textRevision"]?.number, 2, "Repeated confirmation does not invent another rewrite")
    }

    @MainActor func testLegacySnapshotsStillLoadBeforeAnyRevisionIsKnown() {
        let view = SessionDisplay(id: "chat")
        var legacy = snapshot(0, text: "Legacy")
        legacy.removeValue(forKey: "queueEditRevision")
        XCTAssertNotNil(view.applyQueueSnapshot(legacy))
        XCTAssertEqual(view.queue.first?["text"]?.string, "Legacy")
    }

    @MainActor func testASteeringRewriteKeepsALiteralSteeringPrefixInItsText() {
        let view = SessionDisplay(id: "chat")
        view.applyQueueSnapshot(snapshot(1, text: "Original"))
        view.adoptQueueEditHold(nil, revision: 2)
        view.reflectQueuedRewrite(turnID: "q", text: "[Steering] literal user text", reply: savedReply(2))
        XCTAssertEqual(QueuedMessage.from(view.queue).first?.text, "[Steering] literal user text")
    }
}
