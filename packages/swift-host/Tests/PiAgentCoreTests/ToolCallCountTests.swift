import XCTest
@testable import PiAgentCore

final class ToolCallCountTests: XCTestCase {
    func testProjectionKeepsAllCompleteCallsThroughReopen() throws {
        let calls: [JSON] = (0..<64).map { ["type":"toolCall", "id":JSON("c\($0)"), "name":"read", "arguments":["path":"same"]] }
        let message = ChatMessage(role:"assistant", content:calls)
        let view = message.view()
        XCTAssertEqual(view["toolCallCount"].int, 64)
        XCTAssertEqual(view["tools"].list.count, 64)
        XCTAssertEqual(view["truncated"].flag, false)
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(restored.view()["toolCallCount"].int, 64)
    }
}
