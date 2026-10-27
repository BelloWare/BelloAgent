import XCTest
@testable import PiAgentCore

final class AgentMailboxPolicyTests: HelperTestCase {
    func operation(_ index: Int, author: String = "subagent", at: Double = 100) -> AgentOperation {
        let message = AgentFamilyMessage(id:"message-\(index)",sequence:index+1,childID:"child",turn:1,author:author,kind:"note",text:"Useful discovery",task:"Task",epoch:"epoch")
        var op = AgentOperation(key:.init(parentSessionID:author == "parent" ? "parent" : "child",assistantMessageID:"a\(index)",toolCallID:"c\(index)"),digest:"d",receipt:["accepted":true],message:message,epoch:"epoch")
        op.acceptedAt = at; return op
    }
    func testPendingReportsAndRateHaveNoSmallLimits() throws {
        var state = AgentFamilyState(ownerID:"parent")
        for i in 0..<300 { let op = operation(i,at:100); try AgentMailboxPolicy.validate(op,state:state); try state.operation(op) }
        let restored = try JSONDecoder().decode(AgentFamilyState.self,from:subagentJSON(state).data())
        XCTAssertNoThrow(try AgentMailboxPolicy.validate(operation(301,at:99),state:restored))
        XCTAssertEqual(restored.messages.count,300)
        var oversized = operation(302); oversized.message?.text = String(repeating:"x",count:262145)
        XCTAssertThrowsError(try AgentMailboxPolicy.validate(oversized,state:state))
    }
    func testTwoWayMessagesHaveNoEpochAllowance() throws {
        var state = AgentFamilyState(ownerID:"parent")
        for i in 0..<300 {
            var op = operation(i,author:i % 2 == 0 ? "parent" : "subagent",at:Double(100+i*10))
            op.message?.disposition = "delivered"
            try AgentMailboxPolicy.validate(op,state:state); try state.operation(op)
        }
        XCTAssertNoThrow(try AgentMailboxPolicy.validate(operation(300,author:"parent",at:4000),state:state), "No cap on messages (owner, 2026-10-26)")
    }
    func testClockGoingBackwardsDoesNotRefillBucket() throws {
        let accepted = [operation(0,at:100),operation(1,at:100)]
        XCTAssertEqual(AgentMailboxPolicy.tokens(accepted,at:99,burst:2,refill:0.1),0)
        XCTAssertEqual(AgentMailboxPolicy.tokens(accepted,at:105,burst:2,refill:0.1),0.5)
    }
}
