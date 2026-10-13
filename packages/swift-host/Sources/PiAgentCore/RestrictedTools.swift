import Foundation

/// A delegation's immutable ceiling. Recheck the underlying executor on every
/// call, so a later workspace restriction takes effect but cannot widen a grant.
actor RestrictedTools: ToolExecuting {
    let base: any ToolExecuting
    let allowed: Set<String>
    let readOnly: Bool
    let servers: Set<String>
    let mcpPolicy: JSON?
    private var retention: [String: String] = [:]

    init(base: any ToolExecuting, allowed: Set<String>, readOnly: Bool, capabilities: [String], mcpPolicy: JSON? = nil) {
        self.base = base; self.allowed = allowed.subtracting(["subagent"]); self.readOnly = readOnly
        servers = Set(capabilities.filter { $0.hasPrefix("mcp:") }.map { String($0.dropFirst(4)) })
        self.mcpPolicy = mcpPolicy
    }
    func definitions(readOnly: Bool) async -> [ToolDefinition] {
        await base.definitions(readOnly: self.readOnly || readOnly).filter { allowed.contains($0.name) }
    }
    func capabilityIDs(readOnly: Bool) async -> [String] {
        let names = await definitions(readOnly: readOnly).map(\.name)
        let live = await base.capabilityIDs(readOnly: self.readOnly || readOnly)
        return names + (names.contains("mcp") ? live.filter { $0.hasPrefix("mcp:") && servers.contains(String($0.dropFirst(4))) } : [])
    }
    func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON { try await invoke(call, readOnly: readOnly, onUpdate: { _ in }) }
    func invoke(_ call: ToolCall, readOnly: Bool, onUpdate: @escaping @Sendable (JSON) async -> Void) async throws -> JSON {
        guard await definitions(readOnly: readOnly).contains(where: { $0.name == call.name }) else {
            throw AgentError("tool_unavailable", "Tool \(call.name) is outside this delegation's grant")
        }
        if call.name == "mcp" {
            let targets = call.arguments["targets"].list.compactMap { $0["server"].text } + [call.arguments["server"].text].compactMap { $0 }
            guard targets.allSatisfy(servers.contains) else { throw AgentError("mcp_server", "Server is outside this delegation's grant") }
            // Retention keys are physical invocations, never model call IDs
            // shared by parallel sessions. The model still sees its own ID.
            let token = UUID().uuidString; retention[call.id] = token
            var scoped = ToolCall(id: token, name: call.name, arguments: call.arguments); scoped.mcpPolicy = mcpPolicy
            var result = try await base.invoke(scoped, readOnly: self.readOnly || readOnly, onUpdate: onUpdate)
            if call.arguments["action"].text == "list", call.arguments["server"].isNull {
                result["servers"] = .array(result["servers"].list.filter { servers.contains($0["server"].text ?? "") })
            }
            return result
        }
        return try await base.invoke(call, readOnly: self.readOnly || readOnly, onUpdate: onUpdate)
    }
    func resultsRetained(_ callIDs: [String], retained: Bool) async {
        let tokens = callIDs.compactMap { retention.removeValue(forKey: $0) }
        await base.resultsRetained(tokens, retained: retained)
    }
}
