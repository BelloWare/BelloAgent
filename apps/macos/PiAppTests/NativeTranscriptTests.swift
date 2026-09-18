import XCTest
import SwiftUI
@testable import PiApp

/// The native conversation page: what it shows, how it follows the newest
/// message, when it asks for earlier rows, and what it remembers.
final class NativeTranscriptTests: XCTestCase {
    private func message(_ id: String, _ role: String = "assistant", _ text: String = "text") -> TranscriptMessage { TranscriptMessage(id: id, role: role, text: text) }

    func testDisplayPageKeepsTheNewestRowsWithinTheRowAndByteLimits() {
        let many = (0..<620).map { message("m\($0)", "user", "row \($0)") }
        let page = TranscriptPage.displayPage(many)
        XCTAssertEqual(page.count, 500); XCTAssertEqual(page.first?.id, "m120"); XCTAssertEqual(page.last?.id, "m619")
        let heavy = (0..<40).map { message("h\($0)", "assistant", String(repeating: "x", count: 200_000)) }
        let bounded = TranscriptPage.displayPage(heavy)
        XCTAssertLessThan(bounded.count, 40, "about 4 MB of text fits, the oldest rows go first")
        XCTAssertEqual(bounded.last?.id, "h39")
        XCTAssertGreaterThanOrEqual(bounded.count, 15)
        XCTAssertEqual(TranscriptPage.displayPage([]), [])
    }

    @MainActor func testPageFollowsItsSessionAndMarksOnlyRowsThatArriveLaterAsFresh() {
        let session = SessionDisplay(id: "chat")
        session.messages = [message("u1", "user", "hello"), message("a1", "assistant", "hi")]
        let page = TranscriptPage()
        page.bind(session)
        XCTAssertEqual(page.snapshot?.sessionID, "chat")
        XCTAssertEqual(page.snapshot?.items.map(\.id), ["u1", "block:a1"], "a reply becomes a block keyed by its first row")
        XCTAssertTrue(page.snapshot?.fresh.isEmpty == true, "a restored page arrives settled")
        XCTAssertNil(page.liveTurn)
        session.messages.append(TranscriptMessage(id: "stream:a2", role: "assistant", text: "", state: "streaming", turn: "u1"))
        XCTAssertEqual(page.snapshot?.fresh, ["stream:a2"], "rows absent at the previous paint are fresh")
        XCTAssertNotNil(page.liveTurn, "a streaming reply makes the turn live and docks the bar")
        session.messages[2] = TranscriptMessage(id: "stream:a2", role: "assistant", text: "partial", state: "streaming", turn: "u1")
        XCTAssertTrue(page.snapshot?.fresh.isEmpty == true, "a delta to a known row is not fresh")
        session.messages[2] = TranscriptMessage(id: "a2", role: "assistant", text: "done", turn: "u1")
        XCTAssertNil(page.liveTurn)
        XCTAssertEqual(page.snapshot?.fresh, ["a2"], "the settled row has a new id and arrives with motion")
        let second = SessionDisplay(id: "other")
        second.messages = [message("x", "user", "elsewhere")]
        page.bind(second)
        XCTAssertEqual(page.snapshot?.sessionID, "other"); XCTAssertEqual(page.snapshot?.items.map(\.id), ["x"])
        session.messages = []
        XCTAssertEqual(page.snapshot?.sessionID, "other", "the old session no longer reaches the page")
    }

    @MainActor func testReaderScrollingDecidesFollowingTheJumpPillAndEarlierRequests() async throws {
        let session = SessionDisplay(id: "scroll")
        session.messages = (0..<6).map { message("m\($0)", $0 % 2 == 0 ? "user" : "assistant", "row \($0)") }
        let page = TranscriptPage()
        var earlier: [String] = [], anchors: [TranscriptAnchor?] = []
        page.onLoadEarlier = { earlier.append($0) }
        page.onAnchorChanged = { anchors.append($0) }
        page.bind(session)
        // The last turn (rows 4 and 5) fits above the bottom of this viewport, so an idle chat opens at the bottom.
        page.viewportChanged(CGSize(width: 700, height: 800))
        for (index, item) in (page.snapshot?.items ?? []).enumerated() { page.rowFrame(item.id, CGRect(x: 0, y: CGFloat(index) * 300 + 16, width: 700, height: 280)) }
        // The page lays out taller than the viewport while following: no earlier request from the bottom.
        page.contentChanged(ContentGeometry(top: 0, height: 1_900))
        XCTAssertTrue(page.followsBottom); XCTAssertFalse(page.detached); XCTAssertTrue(earlier.isEmpty)
        // Without a scroll view, a wheel scroll is what the geometry reports; following only changes on the reader's own scrolls.
        page.contentChanged(ContentGeometry(top: -1_400, height: 1_900))
        XCTAssertTrue(page.followsBottom); XCTAssertFalse(page.detached)
        page.contentChanged(ContentGeometry(top: -100, height: 1_900))
        XCTAssertTrue(page.followsBottom, "programmatic and layout moves never detach the reader")
        try await Task.sleep(for: .milliseconds(250))
        let anchor = try XCTUnwrap(anchors.last ?? nil)
        XCTAssertEqual(anchor.id, "m0"); XCTAssertEqual(anchor.offset, -84, accuracy: 0.5); XCTAssertTrue(anchor.followsBottom)
        // A short page fits the viewport: the earlier page is requested once for its first row.
        session.messages = [message("p0", "user", "earlier")] + session.messages; session.viewportRequest += 1
        page.contentChanged(ContentGeometry(top: 0, height: 400))
        XCTAssertEqual(earlier, ["scroll"])
        page.contentChanged(ContentGeometry(top: 0, height: 420))
        XCTAssertEqual(earlier, ["scroll"], "the same first row never re-requests")
        // A restored anchor that does not follow keeps the reader's place rather than jumping.
        session.scrollAnchor = TranscriptAnchor(id: "m2", offset: -30, followsBottom: false)
        session.messages = [message("q0", "user", "even earlier")] + session.messages; session.viewportRequest += 1
        XCTAssertFalse(page.followsBottom)
        page.contentChanged(ContentGeometry(top: 0, height: 440))
        XCTAssertEqual(earlier, ["scroll", "scroll"], "a new first row re-arms the request")
        page.jumpToLatest()
        XCTAssertTrue(page.followsBottom); XCTAssertFalse(page.detached)
    }

    @MainActor func testStreamingRowsSettleWithoutReannouncingAndLatestReplyDrivesReceipts() {
        let session = SessionDisplay(id: "receipts")
        session.messages = [message("u1", "user"), TranscriptMessage(id: "stream:x", role: "assistant", text: "…", state: "streaming")]
        let page = TranscriptPage()
        var reads: [String] = []
        page.onReadReply = { _, id in reads.append(id) }
        page.bind(session)
        page.viewportChanged(CGSize(width: 600, height: 400))
        page.rowFrame("u1", CGRect(x: 0, y: 0, width: 600, height: 100)); page.rowFrame("stream:x", CGRect(x: 0, y: 100, width: 600, height: 100))
        page.contentChanged(ContentGeometry(top: 0, height: 220))
        XCTAssertTrue(reads.isEmpty, "a streaming reply is never acknowledged")
        session.messages[1] = message("a1", "assistant", "done")
        page.rowFrame("a1", CGRect(x: 0, y: 100, width: 600, height: 100))
        page.contentChanged(ContentGeometry(top: 0, height: 221))
        XCTAssertTrue(reads.isEmpty, "without a key, visible window nothing counts as read")
    }
}

extension NativeTranscriptTests {
    /// A saved chat whose newest page begins inside a turn pulls earlier pages until the question that started it leads.
    @MainActor func testOpeningASavedChatStartsItsPageAtTheLastQuestion() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("page-start-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("session.jsonl")
        var bytes = Data("{\"type\":\"session\",\"version\":3,\"id\":\"fixture\"}\n".utf8)
        let question: [String: Any] = ["type": "message", "id": "q", "parentId": NSNull(), "message": ["role": "user", "content": "Please read every file and summarize."]]
        bytes.append(try JSONSerialization.data(withJSONObject: question)); bytes.append(10)
        for index in 0..<30 {
            let value: [String: Any] = ["type": "message", "id": "a\(index)", "parentId": index == 0 ? "q" : "a\(index - 1)", "message": ["role": "assistant", "content": String(repeating: "y", count: 16_000)]]
            bytes.append(try JSONSerialization.data(withJSONObject: value)); bytes.append(10)
        }
        try bytes.write(to: path)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        model.chats = [ChatRecord(id: "fixture", workspaceID: "workspace", title: "fixture", path: path.path, profileID: "profile")]
        await model.select("fixture")
        let view = try XCTUnwrap(model.selected)
        XCTAssertEqual(view.messages.first?.role, "user", "the page begins with the question that started the last turn")
        XCTAssertEqual(view.messages.first?.id, "q"); XCTAssertEqual(view.messages.last?.id, "a29")
        XCTAssertTrue(view.pageStartEnsured); XCTAssertTrue(model.hosts.isEmpty, "no helper starts for a saved chat")
        model.shutdown(); await model.store?.close()
    }
}
