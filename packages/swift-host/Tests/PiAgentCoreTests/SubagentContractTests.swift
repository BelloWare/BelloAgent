import XCTest
@testable import PiAgentCore

final class SubagentContractTests: XCTestCase {
    func testCallIdentityIncludesSessionAndAssistantMessage() {
        let a = SubagentCallKey(parentSessionID: "a", assistantMessageID: "reply", toolCallID: "call")
        let b = SubagentCallKey(parentSessionID: "b", assistantMessageID: "reply", toolCallID: "call")
        let c = SubagentCallKey(parentSessionID: "a", assistantMessageID: "next", toolCallID: "call")
        XCTAssertEqual(Set([a, b, c]).count, 3)
    }

    func testProductionAvailabilityRemainsHidden() {
        XCTAssertFalse(SubagentPolicy.enabled)
        XCTAssertTrue(SubagentPolicy.capabilities.isEmpty)
        XCTAssertEqual(SubagentPolicy.maximumActiveChildren, 16)
    }

    func testChildCannotChangeItsBudgetOwnerOrNest() {
        var link = SubagentLink(delegationID: "d", childSessionID: "child", budgetOwnerSessionID: "parent",
                                call: .init(parentSessionID: "parent", assistantMessageID: "reply", toolCallID: "call"),
                                parentTurnID: "turn", parentExecutionID: "execution")
        XCTAssertTrue(link.valid)
        link.budgetOwnerSessionID = "another"
        XCTAssertFalse(link.valid)
        link.budgetOwnerSessionID = "parent"; link.depth = 2
        XCTAssertFalse(link.valid)
    }
}
