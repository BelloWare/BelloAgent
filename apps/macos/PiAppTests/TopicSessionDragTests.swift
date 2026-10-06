import XCTest
import AppKit
@testable import PiApp

final class TopicSessionDragTests: XCTestCase {
    func testPayloadIsVersionedBoundedAndRestrictedToItsProjectAndProcess() throws {
        let declarations = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
        let declaration = try XCTUnwrap(declarations.first { $0["UTTypeIdentifier"] as? String == TopicSessionDrag.type.identifier })
        XCTAssertEqual(declaration["UTTypeConformsTo"] as? [String], ["public.data"], "The drag type must be declared in the packaged application")
        let payload = TopicSessionDrag(sessionIDs: ["session", "second"], workspaceID: "project")
        let data = try XCTUnwrap(payload.encoded())
        XCTAssertEqual(TopicSessionDrag.decode(data, in: "project"), payload)
        XCTAssertEqual(TopicSessionDrag(sessionID: "session", workspaceID: "project").sessionIDs, ["session"])
        XCTAssertNil(TopicSessionDrag.decode(data, in: "other-project"))
        XCTAssertNil(TopicSessionDrag.decode(Data(repeating: 32, count: TopicSessionDrag.maximumBytes + 1), in: "project"))
        XCTAssertNil(TopicSessionDrag.decode(Data("session".utf8), in: "project"))
        XCTAssertNil(TopicSessionDrag(sessionIDs: [], workspaceID: "project").encoded())
        XCTAssertNil(TopicSessionDrag(sessionID: "", workspaceID: "project").encoded())
        XCTAssertNil(TopicSessionDrag(sessionID: String(repeating: "x", count: 513), workspaceID: "project").encoded())
        XCTAssertNil(TopicSessionDrag(sessionID: "chat\nother", workspaceID: "project").encoded())
        // A marked selection travels in one payload, bounded like a bulk action.
        let many = (0..<TopicSessionDrag.maximumSessions).map { "chat\($0)" }
        XCTAssertNotNil(TopicSessionDrag(sessionIDs: many, workspaceID: "project").encoded())
        XCTAssertNil(TopicSessionDrag(sessionIDs: many + ["one-too-many"], workspaceID: "project").encoded())
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value) in [("version", 2 as Any), ("processNonce", "different-process" as Any),
                             ("sessionIDs", [] as Any), ("sessionIDs", [""] as Any), ("sessionIDs", "session" as Any)] {
            var modified = original; modified[key] = value
            XCTAssertNil(TopicSessionDrag.decode(try JSONSerialization.data(withJSONObject: modified), in: "project"), key)
        }
    }

    @MainActor func testADragsPasteboardItemsDispatchOneDeduplicatedMove() async throws {
        let first = try XCTUnwrap(TopicSessionDrag(sessionIDs: ["first"], workspaceID: "project").pasteboardItem())
        let duplicate = TopicSessionDrag(sessionIDs: ["first", "second"], workspaceID: "project").pasteboardItem()
        let second = TopicSessionDrag(sessionID: "second", workspaceID: "project").pasteboardItem()
        XCTAssertEqual(first.types, [NSPasteboard.PasteboardType(TopicSessionDrag.type.identifier)], "Dragging is not also a text or file drop")
        let finished = expectation(description: "move called")
        var moves: [[String]] = []
        XCTAssertTrue(TopicSessionDrag.accept(dragPasteboard([first, duplicate, second]), in: "project") { ids in
            moves.append(ids); finished.fulfill()
        } failure: { message in XCTFail(message); finished.fulfill() })
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(moves, [["first", "second"]])
    }

    @MainActor func testOneCrossProjectItemRejectsWholeDropAndGenericDropsAreIgnored() async throws {
        let finished = expectation(description: "invalid drop reported")
        var moved = false
        let items = dragPasteboard([TopicSessionDrag(sessionID: "first", workspaceID: "project").pasteboardItem(),
                                    TopicSessionDrag(sessionID: "second", workspaceID: "other").pasteboardItem()])
        XCTAssertTrue(TopicSessionDrag.accept(items, in: "project") { _ in moved = true; finished.fulfill() }
                      failure: { _ in finished.fulfill() })
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertFalse(moved, "A partially valid drop must never partially move chats")
        let generic = NSPasteboardItem(); generic.setString("session", forType: .string)
        XCTAssertFalse(TopicSessionDrag.accept(dragPasteboard([generic]), in: "project", move: { _ in XCTFail("Text cannot move a chat") }, failure: { _ in XCTFail("Text is not a sidebar drag") }))
        XCTAssertFalse(TopicSessionDrag.accept(dragPasteboard([]), in: "project", move: { _ in XCTFail() }, failure: { _ in XCTFail() }))
        let oversized = (0...TopicSessionDrag.maximumItems).map { TopicSessionDrag(sessionID: "s\($0)", workspaceID: "project").pasteboardItem() }
        XCTAssertFalse(TopicSessionDrag.accept(dragPasteboard(oversized), in: "project", move: { _ in XCTFail() }, failure: { _ in XCTFail() }))
    }
}
