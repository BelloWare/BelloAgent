import Foundation

// What the session asks of a provider and of the tool executor.

public struct ToolDefinition: Sendable {
    public let name: String, description: String
    public let schema: JSON
    public init(_ name: String, _ description: String, _ schema: JSON) { self.name=name; self.description=description; self.schema=schema }
}
public struct ToolCall: Sendable {
    public let id: String, name: String
    public let arguments: JSON
    public init(id: String, name: String, arguments: JSON) { self.id=id; self.name=name; self.arguments=arguments }
}
public struct ModelReply: Sendable {
    public var message: ChatMessage
    public var calls: [ToolCall]
    public var usage: JSON
    public var truncated: Bool
    public init(message: ChatMessage, calls: [ToolCall] = [], usage: JSON = [:], truncated: Bool = false) { self.message=message; self.calls=calls; self.usage=usage; self.truncated=truncated }
}
public enum StreamDelta: Sendable { case text(String), thinking(String), tool(String, String, String) }
public protocol ModelClient: Sendable {
    func complete(profile: Profile, apiKey: String, messages: [ChatMessage], instructions: String, tools: [ToolDefinition], sessionID: String, turnID: String, purpose: String, onDelta: @escaping @Sendable (StreamDelta) async throws -> Void) async throws -> ModelReply
}
public protocol ToolExecuting: Sendable {
    func definitions(readOnly: Bool) async -> [ToolDefinition]
    func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON
    func invoke(_ call: ToolCall, readOnly: Bool, onUpdate: @escaping @Sendable (JSON) async -> Void) async throws -> JSON
    func capabilityIDs(readOnly: Bool) async -> [String]
}
public extension ToolExecuting {
    func invoke(_ call: ToolCall, readOnly: Bool, onUpdate: @escaping @Sendable (JSON) async -> Void) async throws -> JSON { try await invoke(call,readOnly:readOnly) }
    func capabilityIDs(readOnly: Bool) async -> [String] { await definitions(readOnly:readOnly).map(\.name) }
}
public struct DisabledTools: ToolExecuting {
    public init() {}
    public func definitions(readOnly: Bool) -> [ToolDefinition] { [] }
    public func invoke(_ call: ToolCall, readOnly: Bool) throws -> JSON { throw AgentError("tools_disabled","Tools are disabled for connection tests") }
}
