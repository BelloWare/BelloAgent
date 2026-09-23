import XCTest
@testable import PiApp

/// How the Conversation tab reads a request body, and what it says is new
/// since the request before it.
final class RequestDocumentTests: XCTestCase {
    /// A Responses request as the helper builds one: instructions, tools,
    /// settings and a tool round.
    private func responsesBody(extra: [[String: Any]] = [], instructions: String = "You are Bello Agent. Work in the project.",
                               tools: [[String: Any]]? = nil, output: String = "Synthetic UI fixture file: read-tool round trip verified.\n") throws -> Data {
        var input: [[String: Any]] = [
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Please read fixture README.md first."]]],
            ["type": "function_call", "call_id": "call_1", "name": "read", "arguments": "{\"path\":\"README.md\"}"],
            ["type": "function_call_output", "call_id": "call_1", "output": output],
            ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "The README describes the fixture."]]]
        ]
        input += extra
        let body: [String: Any] = [
            "model": "gpt-5.4", "stream": true, "store": false, "instructions": instructions,
            "metadata": ["session_id": "s"], "disable_fallbacks": true, "max_output_tokens": 300_000,
            "input": input,
            "tools": tools ?? [["type": "function", "name": "read", "description": "Read a file from the project.\nReturns its text.",
                                "parameters": ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]], "strict": false],
                               ["type": "function", "name": "bash", "description": "Run a command.",
                                "parameters": ["type": "object", "properties": ["command": ["type": "string"], "timeout": ["type": "number"]]], "strict": false]],
            "parallel_tool_calls": false, "include": ["reasoning.encrypted_content"], "reasoning": ["effort": "high", "summary": "auto"]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    func testAResponsesBodyReadsAsSectionsThenTheConversation() throws {
        let document = try RequestDocument.parse(try responsesBody())
        XCTAssertEqual(document.api, .responses)
        XCTAssertEqual(document.model, "gpt-5.4")
        XCTAssertNil(document.notice)
        XCTAssertEqual(document.sections.map(\.id), [.system, .tools, .settings])
        let system = try XCTUnwrap(document.section(.system))
        XCTAssertEqual(system.title, "System prompt")
        XCTAssertEqual(system.lines, ["You are Bello Agent. Work in the project."])
        XCTAssertEqual(system.summary, "41 chars")
        let tools = try XCTUnwrap(document.section(.tools))
        XCTAssertEqual(tools.title, "Tools")
        XCTAssertEqual(tools.summary, "2 tools", "The size stands at the row's end, once")
        XCTAssertEqual(tools.entries.map(\.name), ["read", "bash"])
        XCTAssertEqual(tools.entries.first?.value, "Read a file from the project.", "A tool reads as its description's first line")
        XCTAssertEqual(tools.entries.first?.detail, "1 parameter")
        XCTAssertEqual(tools.entries.last?.detail, "2 parameters")
        let settings = try XCTUnwrap(document.section(.settings))
        XCTAssertEqual(settings.summary, "gpt-5.4 · reasoning high · max output 300,000")
        XCTAssertTrue(settings.entries.contains { $0.name == "reasoning" && $0.value == "{\"effort\":\"high\",\"summary\":\"auto\"}" })
        XCTAssertTrue(settings.entries.contains { $0.name == "stream" && $0.value == "true" })
        XCTAssertFalse(settings.entries.contains { ["input", "instructions", "tools"].contains($0.name) }, "Settings hold everything but the conversation")

        XCTAssertEqual(document.items.map(\.kind), [.user, .toolCall, .toolResult, .assistant])
        guard document.items.count == 4 else { return XCTFail("Four items expected") }
        XCTAssertEqual(document.items.map(\.title), ["User", "read", "Result of read", "Assistant"])
        XCTAssertEqual(document.items[0].preview, "Please read fixture README.md first.")
        XCTAssertEqual(document.items[1].detail, "path: README.md", "A call names its first argument")
        XCTAssertEqual(document.items[1].callID, "call_1")
        XCTAssertTrue(document.items[1].monospaced)
        XCTAssertEqual(document.items[1].lines, ["{", "  \"path\" : \"README.md\"", "}"], "Arguments read as formatted JSON")
        XCTAssertNil(document.items[2].detail, "A result's row reads its first line; its size stands at the row's end")
        XCTAssertTrue(document.items[2].monospaced)
        XCTAssertEqual(document.items[3].preview, "The README describes the fixture.")
        XCTAssertEqual(document.items.map(\.id), [0, 1, 2, 3])
        XCTAssertEqual(document.digests.items, document.items.map(\.digest))
        XCTAssertEqual(document.digests.instructions, system.digest)
        XCTAssertEqual(document.digests.tools, tools.digest)
        XCTAssertEqual(document.bytes, try responsesBody().count)
        XCTAssertEqual(try document.fullText(item: 3), "The README describes the fixture.")
        XCTAssertEqual(try document.fullText(section: .system), "You are Bello Agent. Work in the project.")
    }

    /// Pi puts its system prompt first in the input (a developer message to a
    /// reasoning model): it reads as the System section, not as an item, in
    /// the document, its digests and Show all alike.
    func testPisLeadingSystemPromptIsTheSystemSection() throws {
        for role in ["system", "developer"] {
            let body: [String: Any] = ["model": "gpt-5.4", "stream": true, "input": [
                ["role": role, "content": "You are Bello Agent. Work in the project."],
                ["role": "user", "content": [["type": "input_text", "text": "Please read README.md."]]],
            ]]
            let data = try JSONSerialization.data(withJSONObject: body)
            let document = try RequestDocument.parse(data)
            XCTAssertEqual(document.sections.first?.id, .system, role)
            XCTAssertEqual(document.section(.system)?.lines, ["You are Bello Agent. Work in the project."])
            XCTAssertEqual(document.items.map(\.kind), [.user], "The prompt is not a conversation item")
            XCTAssertEqual(try document.fullText(item: 0), "Please read README.md.")
            XCTAssertEqual(try document.fullText(section: .system), "You are Bello Agent. Work in the project.")
            let digests = try XCTUnwrap(try RequestDocument.digests(data))
            XCTAssertEqual(digests.items, document.digests.items)
            XCTAssertEqual(digests.instructions, document.digests.instructions)
            XCTAssertNotNil(digests.instructions)
        }
        // A developer message with parts is a conversation item as before.
        let parts = try JSONSerialization.data(withJSONObject: ["model": "m", "input": [
            ["type": "message", "role": "developer", "content": [["type": "input_text", "text": "A note."]]]]])
        XCTAssertEqual(try RequestDocument.parse(parts).items.count, 1)
    }

    func testEveryItemCarriesItsSizeABoundedPreviewAndACanonicalDigest() throws {
        let long = String(repeating: "0123456789", count: 1_000)
        let document = try RequestDocument.parse(try responsesBody(output: long))
        guard document.items.count == 4 else { return XCTFail("Four items expected") }
        let result = document.items[2]
        XCTAssertEqual(result.characters, 10_000)
        XCTAssertEqual((result.preview as NSString).length, RequestDocument.previewLimit)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(RequestDocument.charactersLabel(result.characters), "10K chars")
        XCTAssertLessThanOrEqual(result.lines.count, RequestDocument.lineLimit)
        XCTAssertTrue(result.lines.allSatisfy { ($0 as NSString).length <= RequestDocument.wrapColumns })
        XCTAssertGreaterThan(result.size, 10_000)
        XCTAssertEqual(try document.fullText(item: 2), long, "Show all reads the whole text, not the preview")

        // The same item, keys in another order, has the same digest.
        let reordered = try JSONSerialization.data(withJSONObject: ["input": [["output": long, "call_id": "call_1", "type": "function_call_output"]]])
        let direct = try JSONSerialization.data(withJSONObject: ["input": [["type": "function_call_output", "call_id": "call_1", "output": long]]])
        XCTAssertEqual(try RequestDocument.parse(reordered).items.first?.digest, try RequestDocument.parse(direct).items.first?.digest)
        let other = try RequestDocument.parse(try responsesBody(output: long + "!"))
        guard other.items.count == 4 else { return XCTFail("Four items expected") }
        XCTAssertNotEqual(other.items[2].digest, result.digest)
        XCTAssertEqual(other.items[0].digest, document.items[0].digest)
    }

    func testReasoningImagesAndUnknownItemsKeepTheirPlace() throws {
        let body: [String: Any] = ["model": "m", "input": [
            ["type": "reasoning", "id": "rs_1", "summary": [["type": "summary_text", "text": "Checked the README first."]], "encrypted_content": String(repeating: "x", count: 12_300)],
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": "What is in this picture?"],
                                                            ["type": "input_image", "image_url": "data:image/png;base64,AAAA"]]],
            ["role": "developer", "content": "Answer briefly."],
            ["type": "web_search_call", "id": "ws_1", "status": "completed"]
        ]]
        let document = try RequestDocument.parse(try JSONSerialization.data(withJSONObject: body))
        XCTAssertEqual(document.items.map(\.kind), [.reasoning, .user, .developer, .other])
        guard document.items.count == 4 else { return XCTFail("Four items expected") }
        XCTAssertEqual(document.items[0].title, "Reasoning")
        XCTAssertEqual(document.items[0].preview, "Checked the README first.")
        XCTAssertEqual(document.items[0].detail, "summary · encrypted 12.3K")
        XCTAssertEqual(document.items[1].preview, "What is in this picture?")
        XCTAssertEqual(document.items[1].detail, "1 image")
        XCTAssertEqual(document.items[2].title, "Developer")
        XCTAssertEqual(document.items[2].preview, "Answer briefly.")
        XCTAssertEqual(document.items[3].title, "web_search_call")
        XCTAssertTrue(document.items[3].monospaced)
        XCTAssertEqual(document.sections.map(\.id), [.settings], "A body without instructions or tools has only its settings")
    }

    func testAMessagesBodyReadsBlockByBlock() throws {
        let body: [String: Any] = [
            "model": "claude-x", "max_tokens": 8_192, "stream": true,
            "system": [["type": "text", "text": "You are Bello Agent."]],
            "tools": [["name": "read", "description": "Read a file.", "input_schema": ["type": "object", "properties": ["path": ["type": "string"]]]]],
            "messages": [
                ["role": "user", "content": "Read the README."],
                ["role": "assistant", "content": [["type": "thinking", "thinking": "Use the read tool."],
                                                  ["type": "text", "text": "Reading it now."],
                                                  ["type": "tool_use", "id": "toolu_1", "name": "read", "input": ["path": "README.md"]]]],
                ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "Fixture notes.", "is_error": false]]]
            ]]
        let document = try RequestDocument.parse(try JSONSerialization.data(withJSONObject: body))
        XCTAssertEqual(document.api, .messages)
        XCTAssertEqual(document.model, "claude-x")
        XCTAssertEqual(document.section(.system)?.lines, ["You are Bello Agent."])
        XCTAssertEqual(document.section(.tools)?.entries.first?.detail, "1 parameter")
        XCTAssertEqual(document.section(.settings)?.summary, "claude-x · max output 8,192")
        XCTAssertEqual(document.items.map(\.kind), [.user, .reasoning, .assistant, .toolCall, .toolResult])
        guard document.items.count == 5 else { return XCTFail("Five items expected") }
        XCTAssertEqual(document.items.map(\.title), ["User", "Reasoning", "Assistant", "read", "Result of read"])
        XCTAssertEqual(document.items[3].detail, "path: README.md")
        XCTAssertEqual(document.items[4].preview, "Fixture notes.")
    }

    func testABodyThatIsNotJSONSaysSoInsteadOfFailing() throws {
        let document = try RequestDocument.parse(Data("not json at all".utf8))
        XCTAssertEqual(document.api, .unknown)
        XCTAssertTrue(document.items.isEmpty)
        XCTAssertEqual(document.notice, "This body is not a JSON request. Raw shows its bytes.")
        let array = try RequestDocument.parse(Data("[1,2]".utf8))
        XCTAssertEqual(array.notice, "This body is not a JSON request. Raw shows its bytes.")
    }

    func testWrappingBreaksBetweenWordsKeepsLineBreaksAndStopsAtItsLimit() {
        XCTAssertEqual(RequestDocument.wrap("alpha beta gamma delta", columns: 11, limit: 10), ["alpha beta", "gamma delta"])
        XCTAssertEqual(RequestDocument.wrap("one\n\ntwo", columns: 20, limit: 10), ["one", "", "two"])
        XCTAssertEqual(RequestDocument.wrap("abcdefghijkl", columns: 5, limit: 10), ["abcde", "fghij", "kl"], "A word longer than a line is cut")
        XCTAssertEqual(RequestDocument.wrap("a b c d e f", columns: 1, limit: 3), ["a", "b", "c"])
        XCTAssertEqual(RequestDocument.wrap("", columns: 10, limit: 3), [])
        XCTAssertEqual(RequestDocument.wrap("tab\there", columns: 20, limit: 3), ["tab    here"], "Tabs read as spaces")
    }

    func testParsingStopsWhenItsTaskIsCancelled() async throws {
        let many = (0..<5_000).map { ["type": "message", "role": "user", "content": [["type": "input_text", "text": "item \($0) " + String(repeating: "x", count: 200)]]] }
        let data = try JSONSerialization.data(withJSONObject: ["input": many])
        let task = Task.detached { () throws -> RequestDocument in
            withUnsafeCurrentTask { $0?.cancel() }
            return try RequestDocument.parse(data)
        }
        do { _ = try await task.value; XCTFail("A cancelled parse must not finish") } catch is CancellationError { }
    }

    // MARK: - What is new since the request before

    func testAToolRoundAddsOnlyWhatFollowsTheSharedItems() throws {
        let first = try RequestDocument.parse(try responsesBody())
        let second = try RequestDocument.parse(try responsesBody(extra: [
            ["type": "function_call", "call_id": "call_2", "name": "bash", "arguments": "{\"command\":\"ls\"}"],
            ["type": "function_call_output", "call_id": "call_2", "output": String(repeating: "f", count: 3_100)]]))
        let delta = RequestDelta.between(second.digests, previous: first.digests)
        guard second.items.count == 6 else { return XCTFail("Six items expected") }
        XCTAssertEqual(delta.shared, 4); XCTAssertEqual(delta.added, 2); XCTAssertEqual(delta.dropped, 0)
        XCTAssertFalse(delta.rewritten); XCTAssertFalse(delta.first)
        XCTAssertFalse(delta.instructionsChanged); XCTAssertFalse(delta.toolsChanged)
        XCTAssertFalse(delta.isNew(3)); XCTAssertTrue(delta.isNew(4)); XCTAssertTrue(delta.isNew(5))
        XCTAssertEqual(delta.addedCharacters, second.items[4].characters + second.items[5].characters)
        XCTAssertEqual(delta.banner(previous: "request 1", cachedShare: 0.8312), "New since request 1: +2 items, 3.1K chars · 83% of input cached")
        XCTAssertEqual(delta.banner(previous: "request 1", cachedShare: nil), "New since request 1: +2 items, 3.1K chars")
        XCTAssertTrue(delta.notes.isEmpty)
    }

    func testACompactionRewritesTheHistoryBeforeIt() throws {
        let before = RequestDigests(items: ["a", "b", "c", "d"], characters: [10, 20, 30, 40], instructions: "i", tools: "t")
        let after = RequestDigests(items: ["summary", "e"], characters: [500, 25], instructions: "i", tools: "t")
        let delta = RequestDelta.between(after, previous: before)
        XCTAssertEqual(delta.shared, 0); XCTAssertEqual(delta.added, 2); XCTAssertEqual(delta.dropped, 4)
        XCTAssertTrue(delta.rewritten)
        XCTAssertEqual(delta.banner(previous: "request 4", cachedShare: nil), "History rewritten since request 4: 4 earlier items replaced · +2 items, 525 chars")
        XCTAssertEqual(delta.notes, ["History rewritten: 4 earlier items are no longer sent; a compaction or an edit replaced them."])
        let edited = RequestDelta.between(RequestDigests(items: ["a", "x", "y"], characters: [10, 5, 5]), previous: before)
        XCTAssertEqual(edited.shared, 1); XCTAssertEqual(edited.dropped, 3); XCTAssertEqual(edited.added, 2)
    }

    func testTheFirstRequestIsAllNewAndARetryAddsNothing() {
        let digests = RequestDigests(items: ["a", "b"], characters: [1_000, 1_100], instructions: "i", tools: "t")
        let first = RequestDelta.between(digests, previous: nil)
        XCTAssertTrue(first.first); XCTAssertEqual(first.shared, 0); XCTAssertEqual(first.added, 2)
        XCTAssertTrue(first.isNew(0))
        XCTAssertEqual(first.banner(previous: nil, cachedShare: nil), "First request: 2 items, 2.1K chars")
        let retry = RequestDelta.between(digests, previous: digests)
        XCTAssertEqual(retry.added, 0); XCTAssertEqual(retry.shared, 2)
        XCTAssertEqual(retry.banner(previous: "request 2", cachedShare: 1), "Same input as request 2 · 100% of input cached")
    }

    func testChangedInstructionsAndToolsAreNamed() {
        let before = RequestDigests(items: ["a"], characters: [1], instructions: "i1", tools: "t1")
        let delta = RequestDelta.between(RequestDigests(items: ["a", "b"], characters: [1, 2], instructions: "i2", tools: "t2"), previous: before)
        XCTAssertTrue(delta.instructionsChanged); XCTAssertTrue(delta.toolsChanged)
        XCTAssertEqual(delta.notes, ["The system prompt changed.", "The tools changed."])
    }

    func testMessagesBlocksShareTheirPrefixAcrossATurn() throws {
        func body(_ messages: [[String: Any]]) throws -> RequestDocument {
            try RequestDocument.parse(try JSONSerialization.data(withJSONObject: ["model": "claude-x", "messages": messages]))
        }
        let user: [String: Any] = ["role": "user", "content": "Read the README."]
        let call: [String: Any] = ["role": "assistant", "content": [["type": "tool_use", "id": "t1", "name": "read", "input": ["path": "README.md"]]]]
        let result: [String: Any] = ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "notes"]]]
        let first = try body([user]), second = try body([user, call, result])
        let delta = RequestDelta.between(second.digests, previous: first.digests)
        XCTAssertEqual(delta.shared, 1); XCTAssertEqual(delta.added, 2); XCTAssertFalse(delta.rewritten)
    }
}
