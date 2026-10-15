import XCTest
@testable import PiApp

final class QueuedEditPresentationTests: XCTestCase {
    private func snapshot(_ revision: Int, text: String, count: Int = 1) -> [String: WireValue] {
        ["queueEditRevision": .number(Double(revision)), "queueCount": .number(Double(count)),
         "queue": .array(count == 0 ? [] : [.object(["turnId": .string("q"), "kind": .string("steering"), "text": .string(text), "textRevision": .number(1)])])]
    }

    @MainActor func testASnapshotStartedBeforeSaveCannotUndoTheAcknowledgedRow() {
        let view = SessionDisplay(id: "chat")
        view.applyQueueSnapshot(snapshot(1, text: "Original"))
        view.queueEditOriginal = "Original"
        view.adoptQueueEditHold(nil, revision: 2)
        view.reflectQueuedRewrite(turnID: "q", text: "Saved", reply: ["revision": .number(2)])
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
        view.reflectQueuedRewrite(turnID: "q", text: "Older save", reply: ["revision": .number(2)])
        XCTAssertEqual(view.queue.first?["text"]?.string, "Newer edit")
        view.applyQueueSnapshot(snapshot(4, text: "", count: 0))
        view.reflectQueuedRewrite(turnID: "q", text: "Older save", reply: ["revision": .number(4)])
        XCTAssertTrue(view.queue.isEmpty)
    }

    @MainActor func testEditsBeyondThePreviewAdvanceRowIdentityWithoutRetainingTheWholeDraft() {
        let view = SessionDisplay(id: "chat"), prefix = String(repeating: "é", count: 2_000)
        view.applyQueueSnapshot(snapshot(1, text: String(prefix.prefix(512))))
        view.queueEditOriginal = prefix + "A"
        view.adoptQueueEditHold(nil, revision: 2)
        let original = QueuedMessage.from(view.queue).first?.contentKey
        view.reflectQueuedRewrite(turnID: "q", text: prefix + "B", reply: ["revision": .number(2)])
        XCTAssertNotEqual(QueuedMessage.from(view.queue).first?.contentKey, original)
        XCTAssertLessThanOrEqual(QueuedMessage.from(view.queue).first?.text.utf8.count ?? .max, 1_024)
        XCTAssertEqual(view.queue.first?["textBytes"]?.number, Double((prefix + "B").utf8.count))
        XCTAssertEqual(view.queue.first?["textTruncated"]?.bool, true)
        XCTAssertEqual(view.queue.first?["textRevision"]?.number, 2)
        view.reflectQueuedRewrite(turnID: "q", text: prefix + "B", reply: ["revision": .number(2)])
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
        view.reflectQueuedRewrite(turnID: "q", text: "[Steering] literal user text", reply: ["revision": .number(2)])
        XCTAssertEqual(QueuedMessage.from(view.queue).first?.text, "[Steering] literal user text")
    }
}
