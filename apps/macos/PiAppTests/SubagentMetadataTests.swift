import XCTest
@testable import PiApp

final class SubagentMetadataTests: XCTestCase {
    private let child = """
    {"id":"child","workspaceID":"project","title":"Task","profileID":"profile","parentSessionID":"parent",
     "delegation":{"version":1,"delegationID":"delegation","childSessionID":"child","budgetOwnerSessionID":"parent",
       "call":{"parentSessionID":"parent","assistantMessageID":"reply","toolCallID":"call"},
       "parentTurnID":"turn","parentExecutionID":"execution","depth":1}}
    """

    func testManagedIdentitySurvivesMetadataRoundTrip() throws {
        let record = try JSONDecoder().decode(ChatRecord.self, from: Data(child.utf8))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        let link = try XCTUnwrap(saved["delegation"] as? [String: Any])
        XCTAssertEqual(link["budgetOwnerSessionID"] as? String, "parent")
        XCTAssertEqual(link["childSessionID"] as? String, "child")
    }

    func testOldMetadataUpdateCannotEraseManagedIdentity() throws {
        let previous = try JSONDecoder().decode(ChatRecord.self, from: Data(child.utf8))
        let old = ChatRecord(id: "child", workspaceID: "project", title: "Task", profileID: "profile")
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old.merged(over: previous))) as? [String: Any])
        XCTAssertNotNil(saved["delegation"])
    }
}
