// Driver only. The Rust test prepends the actual checked-in Swift JSON parser,
// Support, Resources, MetadataYAML and SessionContext expansion declarations.
// No app, real home, provider, network, credential or configuration is loaded.
@main struct ProjectSkillsOracle {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("one fixture input required") }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard data.count <= 4 * 1024 * 1024 else { fatalError("fixture input too large") }
        let input = try JSON.parse(data)
        var results: [JSON] = []
        for item in input["cases"].list {
            let cwd = URL(fileURLWithPath: item["cwd"].text!)
            let home = URL(fileURLWithPath: item["home"].text!)
            let resources = Resources(cwd: cwd, options: ["codexHome": JSON(home.appendingPathComponent("codex").path)], home: home)
            let snapshot = try await resources.resolve()
            let tools = ["ls", "mcp:docs"]
            var selections = snapshot.skills.map { skill -> JSON in
                var s = skill; s["intent"] = "picker"; s["arguments"] = "literal \"args\"\n/never-a-command"; return s
            }
            var result: JSON = ["case": item["case"], "skills": .array(snapshot.skills), "instructions": JSON(AgentSession.requestInstructions(snapshot.prompt))]
            do {
                let frozen = try await resources.freeze(selections, text: "Raw /review stays literal", tools: tools)
                result["freezeAccepted"] = true
                result["expanded"] = JSON(AgentSession.userMessageText("Raw /review stays literal", skills: frozen, turnID: "fixture-turn"))
                result["recorded"] = .array(frozen.map(\.recorded))
                if let replacement = item["bodyReplacement"].text, let first = snapshot.skills.first, let path = first["path"].text {
                    let url = URL(fileURLWithPath: path), original = try Data(contentsOf: url)
                    defer { try? original.write(to: url) }
                    try Data(replacement.utf8).write(to: url)
                    do { _ = try await resources.freeze(selections, text: "", tools: tools); result["staleFreshAccepted"] = true } catch { result["staleFreshAccepted"] = false }
                    do { try await resources.validate(frozen, tools: tools); result["bodyDeliveryAccepted"] = true } catch { result["bodyDeliveryAccepted"] = false }
                    result["retainedExpansion"] = JSON(AgentSession.userMessageText("Raw /review stays literal", skills: frozen, turnID: "fixture-turn"))
                    if let revoked = item["metadataReplacement"].text {
                        try Data(revoked.utf8).write(to: url)
                        do { try await resources.validate(frozen, tools: tools); result["metadataDeliveryAccepted"] = true } catch { result["metadataDeliveryAccepted"] = false }
                    }
                }
            } catch { result["freezeAccepted"] = false }
            // No implicit selection is introduced from raw slash text.
            selections = []
            let empty = try await resources.freeze(selections, text: "/review", tools: tools)
            result["unselected"] = JSON(AgentSession.userMessageText("/review", skills: empty, turnID: "next-turn"))
            results.append(result)
        }
        var compaction: [JSON] = []
        for item in input["compaction"].list {
            let messages = item["messages"].list.map { row -> ChatMessage in
                let userInput: JSON? = row["selected"].flag == true ? ["skills": [["id": "fixture-skill"]]] : nil
                return ChatMessage(id: row["id"].text!, role: row["role"].text!, replayEligible: true,
                    content: [], toolCallId: nil, kind: nil, compaction: nil,
                    userInput: userInput, taskRootID: row["taskRoot"].text, contextNote: nil)
            }
            let source = try CompactionPlanner.source(context: messages, taskRoot: item["taskRoot"].text)
            compaction.append(["case": item["case"], "protectedIDs": .array(source.protectedIDs.sorted().map { JSON($0) })])
        }
        let output: JSON = ["skills": .array(results), "compaction": .array(compaction)]
        FileHandle.standardOutput.write(try output.data())
    }
}
