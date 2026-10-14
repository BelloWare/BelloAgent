import XCTest
@testable import PiAgentCore

final class SubagentContractTests: XCTestCase {
    func testCallIdentityIncludesSessionAndAssistantMessage() {
        let a = SubagentCallKey(parentSessionID: "a", assistantMessageID: "reply", toolCallID: "call")
        let b = SubagentCallKey(parentSessionID: "b", assistantMessageID: "reply", toolCallID: "call")
        let c = SubagentCallKey(parentSessionID: "a", assistantMessageID: "next", toolCallID: "call")
        XCTAssertEqual(Set([a, b, c]).count, 3)
    }

    func testProductionAvailabilityAdvertisesTheCompleteFeature() {
        XCTAssertTrue(SubagentPolicy.enabled)
        XCTAssertEqual(SubagentPolicy.capabilities, ["subagents-v1", "shared-budget-v1", "subagents-steering-v3"])
        XCTAssertEqual(SubagentPolicy.maximumActiveChildren, 16)
        XCTAssertEqual(SubagentPolicy.maximumDepth, 1)
    }

    func testDiscoveryCanRefreshWhileStopKeepsItsCommandReceipt() {
        XCTAssertTrue(NativeHostService.isReadOnly("subagent.list"))
        XCTAssertFalse(NativeHostService.isReadOnly("subagent.stop"))
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
