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
            // AgentSession receives source-canonical roots in production. A raw
            // URL here concealed the Darwin root-spelling gap in old fixtures.
            let cwd = canonical(item["cwd"].text!)
            let roots = item["roots"].list.compactMap { $0.text.map { canonical($0) } }
            let home = URL(fileURLWithPath: item["home"].text!)
            var options: JSON = ["codexHome": JSON(home.appendingPathComponent("codex").path)]
            if !item["instructionLimit"].isNull { options["maxInstructionBytes"] = item["instructionLimit"] }
            let resources = Resources(cwd: cwd, roots: roots, options: options, home: home)
            let snapshot = try await resources.resolve()
            let tools = ["ls", "mcp:docs"]
            var selections = snapshot.skills.map { skill -> JSON in
                var s = skill; s["intent"] = "picker"; s["arguments"] = "literal \"args\"\n/never-a-command"; return s
            }
            var result: JSON = ["case": item["case"], "skills": .array(snapshot.skills), "instructions": JSON(AgentSession.requestInstructions(snapshot.prompt)),
                "prompt": JSON(snapshot.prompt), "sources": .array(snapshot.sources),
                "diagnostics": .array(snapshot.diagnostics.map { JSON($0) }), "includedBytes": JSON(snapshot.includedBytes)]
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
        var instructions: [JSON] = []
        for item in input["instructions"].list {
            let roots = item["roots"].list.map { canonical($0.text!) }
            let options: JSON = ["codexHome": item["codexHome"], "maxInstructionBytes": item["limit"],
                "piInstructionPaths": item["additionalPaths"], "fallbackNames": item["fallbackNames"]]
            let resources = Resources(cwd: roots[0], roots: Array(roots.dropFirst()), options: options,
                home: URL(fileURLWithPath: item["home"].text!))
            let snapshot = try await resources.resolve()
            guard snapshot.skills.isEmpty else { fatalError("instruction-only fixture unexpectedly has skills") }
            // Resources exposes the complete prompt. Select its verbatim instruction
            // section; do not rebuild headers, replace aliases, or normalize bytes.
            let start = snapshot.prompt.range(of: "Never claim an action succeeded without its tool result.\n")!
            let end = snapshot.prompt.range(of: "\nAvailable implicit skills (load full SKILL.md with read when relevant):\n", options: .backwards)!
            instructions.append(["case": item["case"], "instructions": JSON(String(snapshot.prompt[start.upperBound..<end.lowerBound])),
                "promptRoots": .array(snapshot.roots.map { JSON($0) }), "sources": .array(snapshot.sources),
                "diagnostics": .array(snapshot.diagnostics.map { JSON($0) }), "includedBytes": JSON(snapshot.includedBytes),
                "limit": JSON(snapshot.limit)])
        }
        let output: JSON = ["skills": .array(results), "compaction": .array(compaction), "instructions": .array(instructions)]
        FileHandle.standardOutput.write(try output.data())
    }
}
