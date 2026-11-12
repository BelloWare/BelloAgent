import XCTest
@testable import PiAgentCore

/// What a request carries of a reply's reasoning (`Profile.reasoning`,
/// `ProviderClient.replay(of:profile:)`). The rule: a reply stored by a
/// connection that sends reasoning back is marked, and its reasoning goes with
/// every later request, whatever model, alias or connection reads it. Every
/// other reply (all of them before 0.1.138) goes as 0.1.137 sent it.
final class ReasoningReplayTests: HelperTestCase {
    private static let signed = "call_" + String(repeating: "a1", count: 14) + "__thought__" + String(repeating: "CiQB0e2Kb/+", count: 30) + "=="
    private func profile(_ change: (inout JSON) -> Void = { _ in }) throws -> Profile {
        var raw = try fixtureProfile().raw; change(&raw); return try Profile(raw)
    }
    /// A reply with encrypted reasoning, a message and a call, as a journal
    /// holds it: `marked` is how 0.1.138 stores one made on a sending connection.
    private func reply(_ id: String = "reply", by maker: Profile, marked: Bool, call: String = "call_1", item: String? = "fc_1") throws -> ChatMessage {
        var items: [JSON] = [["type": "reasoning", "id": "rs_1", "summary": [["type": "summary_text", "text": "Thought"]], "encrypted_content": "ENC"],
                             ["type": "message", "id": "msg_1", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": "Answer", "annotations": []]]]]
        var callItem: JSON = ["type": "function_call", "call_id": JSON(call), "name": "read", "arguments": "{\"path\":\"a\"}", "status": "completed"]
        if let item { callItem["id"] = JSON(item) }
        items.append(callItem)
        var pi: JSON = ["role": "assistant", "content": [["type": "thinking", "thinking": "Thought"], ["type": "text", "text": "Answer"], ["type": "toolCall", "id": JSON(call), "name": "read", "arguments": ["path": "a"]]],
                        "nativeProviderItems": .array(items), "nativeProviderBinding": try ProviderClient.replayBinding(maker)]
        if marked { pi["nativeReasoningReplay"] = true }
        return try ChatMessage(id: id, pi: pi)
    }
    private func result(_ call: String = "call_1") -> ChatMessage {
        var message = ChatMessage(role: "toolResult", content: [textBlock("ok")]); message.toolCallId = call; return message
    }
    private func input(_ messages: [ChatMessage], _ profile: Profile) throws -> [JSON] {
        try ProviderClient.requestBody(profile: profile, messages: messages, instructions: "", tools: [], sessionID: "s")["input"].list
    }
    private func kinds(_ items: [JSON]) -> [String] { items.map { $0["type"].text ?? $0["role"].text ?? "?" } }

    func testAMarkedReplysReasoningGoesBackAfterAModelSwitchAnOverrideAndAConnectionMove() throws {
        let home = try profile(), message = try reply(by: home, marked: true)
        let reasoning: JSON = ["type": "reasoning", "id": "rs_1", "summary": [["type": "summary_text", "text": "Thought"]], "encrypted_content": "ENC"]
        // The connection that made it, a per-turn override to another model,
        // another connection (as after `session.rebind`), and a new revision of the settings.
        let override = try home.overriding(model: "other-model", thinkingLevel: nil)
        let moved = try profile { $0["id"] = "elsewhere"; $0["baseUrl"] = "http://127.0.0.1:23456/v1"; $0["modelId"] = "moved-model" }
        let resaved = try profile { $0["revision"] = "2" }
        // A connection written before 0.1.138 said `portable` (every new one did) or nothing (`ask`): both send now.
        let portable = try profile { $0["routing"] = ["replayPolicy": "portable"] }
        for (name, target) in [("home", home), ("override", override), ("moved", moved), ("resaved", resaved), ("portable", portable)] {
            XCTAssertEqual(target.reasoning, .send, name)
            let sent = try input([message, result()], target)
            XCTAssertEqual(kinds(sent), ["reasoning", "message", "function_call", "function_call_output"], name)
            XCTAssertEqual(sent[0], reasoning, "As received (\(name))")
            XCTAssertEqual(sent[2], ["type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "read", "arguments": "{\"path\":\"a\"}"], name)
            XCTAssertFalse(sent.contains { $0["content"].list.contains { $0["text"].text == "Thought" } }, "Not also as text (\(name))")
        }
    }

    func testAReplyStoredBeforeIsSentAsItAlwaysWas() throws {
        // 0.1.137's portable history: text and calls, the reasoning left out
        // for its own model and its summary as text for another.
        let portable = try profile { $0["routing"] = ["replayPolicy": "portable"] }, old = try reply(by: portable, marked: false)
        let same = try input([old, result()], portable)
        XCTAssertEqual(same, [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Answer", "annotations": []]], "status": "completed", "id": "msg_pi_0"],
                              ["type": "function_call", "call_id": "call_1", "name": "read", "arguments": "{\"path\":\"a\"}"],
                              ["type": "function_call_output", "call_id": "call_1", "output": "ok"]])
        let other = try input([old, result()], try portable.overriding(model: "other-model", thinkingLevel: nil))
        XCTAssertEqual(kinds(other), ["message", "message", "function_call", "function_call_output"])
        XCTAssertEqual(other[0]["content"].list.first?["text"].text, "Thought")
        // A connection without a policy refused to build this request
        // (`opaque_replay_policy`). It goes from text and calls now.
        let unset = try profile(), refused = try reply(by: unset, marked: false)
        XCTAssertEqual(try input([refused, result()], unset), same)
        // Its replies without reasoning kept their own items, and still do.
        var plain = try reply(by: unset, marked: false)
        plain.providerItems = Array((plain.providerItems ?? []).dropFirst())
        XCTAssertEqual(try input([plain], unset).map { $0["id"].text }, ["msg_1", "fc_1", nil])
    }

    func testNeverSendsNoReasoningAndNoSignatureInACallID() throws {
        let never = try profile { $0["reasoningReplay"] = "never"; $0["routing"] = ["replayPolicy": "portable"] }
        XCTAssertEqual(never.reasoning, .never)
        // Marked or not, with a Gemini signature in the call's id (a LiteLLM direct route).
        for marked in [true, false] {
            let message = try reply(by: never, marked: marked, call: Self.signed, item: "fc_" + Self.signed)
            let sent = try input([message, result(Self.signed), ChatMessage(role: "user", content: [textBlock("next")])], never)
            XCTAssertEqual(kinds(sent), ["message", "function_call", "function_call_output", "user"], "\(marked)")
            let short = ProviderClient.sentCallID(Self.signed, own: false)
            XCTAssertEqual(sent[1], ["type": "function_call", "call_id": JSON(short), "name": "read", "arguments": "{\"path\":\"a\"}"], "No item id, no signature")
            XCTAssertEqual(sent[2]["call_id"].text, short, "The output answers the call under the same name")
            XCTAssertFalse(sent.contains { $0.encoded().contains("__thought__") || $0.encoded().contains("ENC") })
        }
        // A call no result came for is closed under that name too.
        let open = try input([try reply(by: never, marked: true, call: Self.signed), ChatMessage(role: "user", content: [textBlock("next")])], never)
        XCTAssertEqual(open[2], ["type": "function_call_output", "call_id": JSON(ProviderClient.sentCallID(Self.signed, own: false)), "output": "No result provided"])
        XCTAssertThrowsError(try profile { $0["reasoningReplay"] = "sometimes" })
    }

    func testAPinnedRouteIsAsItWas() throws {
        var raw = try fixtureProfile().raw
        raw["routing"] = ["replayPolicy": "pinned", "expectedModel": "actual-a", "replayContract": "Gateway fixes a compatible upstream"]
        // The new field does not override a pinned route.
        raw["reasoningReplay"] = "send"
        let pinned = try Profile(raw)
        XCTAssertEqual(pinned.reasoning, .pinned)
        var own = try reply(by: pinned, marked: false); own.providerIdentity = ["status": "reported", "effectiveModel": "actual-a"]
        XCTAssertEqual(kinds(try input([own, result()], pinned)), ["reasoning", "message", "function_call", "function_call_output"], "Its own route's state")
        // An override turn leaves the route: text and calls, as before, also
        // for a reply another connection marked.
        let override = try pinned.overriding(model: "other-model", thinkingLevel: nil)
        XCTAssertEqual(override.reasoning, .legacy)
        let foreign = try reply(by: try profile { $0["id"] = "elsewhere" }, marked: true)
        for message in [own, foreign] { XCTAssertFalse(kinds(try input([message, result()], override)).contains("reasoning")) }
        XCTAssertFalse(kinds(try input([foreign, result()], pinned)).contains("reasoning"), "A reply from outside the route is not this route's state")
        // A pinned route's own state can be refused too (its gateway's route
        // changed under it): what the owner agreed to leave out is left out here as well.
        XCTAssertEqual(kinds(try input([own, result()], pinned.withholding([own.id]))), ["message", "function_call", "function_call_output"])
        // Replies of a pinned connection are not marked: the mark is the sending connection's.
        var changed = raw; changed["revision"] = "2"
        XCTAssertThrowsError(try input([own, result()], try Profile(changed)), "The strict check stands")
    }

    func testAnotherModelGetsAShortNameForALongCallIDAndNoLongItemID() throws {
        let home = try profile(), other = try home.overriding(model: "other-model", thinkingLevel: nil)
        let message = try reply(by: home, marked: true, call: Self.signed, item: "fc_" + Self.signed)
        // Its own model: byte for byte, the signature with it.
        let own = try input([message, result(Self.signed)], home)
        XCTAssertEqual(own[2]["call_id"].text, Self.signed); XCTAssertEqual(own[2]["id"].text, "fc_" + Self.signed); XCTAssertEqual(own[3]["call_id"].text, Self.signed)
        // Another model: OpenAI refuses a call id over 64 characters, and the item id is the same string.
        let sent = try input([message, result(Self.signed)], other)
        let short = ProviderClient.sentCallID(Self.signed, own: false)
        XCTAssertEqual(kinds(sent), ["reasoning", "message", "function_call", "function_call_output"], "The reasoning item still goes")
        XCTAssertEqual(sent[2]["call_id"].text, short); XCTAssertTrue(sent[2]["id"].isNull); XCTAssertEqual(sent[3]["call_id"].text, short)
        // Another Gemini model takes the signature: the id goes whole, by the
        // model's name or, for an alias that says nothing, because that alias
        // has itself made such an id in this chat.
        let gemini = try home.overriding(model: "gemini-3.1-flash-lite", thinkingLevel: nil)
        let whole = try input([message, result(Self.signed)], gemini)
        XCTAssertEqual(whole[2]["call_id"].text, Self.signed); XCTAssertEqual(whole[2]["id"].text, "fc_" + Self.signed); XCTAssertEqual(whole[3]["call_id"].text, Self.signed)
        let alias = try home.overriding(model: "flash-31", thinkingLevel: nil), theirs = "call_" + String(repeating: "b2", count: 14) + "__thought__" + String(repeating: "Zm9v", count: 40)
        let earlier = try reply("theirs", by: alias, marked: true, call: theirs, item: nil)
        let known = try input([message, result(Self.signed), earlier, result(theirs)], alias)
        XCTAssertEqual(known.filter { $0["type"].text == "function_call" }.map { $0["call_id"].text }, [Self.signed, theirs])
        // At the limit: 64 bytes pass as they are, 65 do not; bytes, not characters.
        let fits = "call_" + String(repeating: "x", count: 59), over = fits + "x", wide = "call_" + String(repeating: "é", count: 30)
        XCTAssertEqual(fits.utf8.count, 64); XCTAssertEqual(wide.utf8.count, 65)
        for (id, kept) in [(fits, true), (over, false), (wide, false)] {
            let item = "fc_" + String(id.dropFirst(3))
            let call = try input([try reply(by: home, marked: true, call: id, item: item), result(id)], other)[2]
            XCTAssertEqual(call["call_id"].text == id, kept, id); XCTAssertEqual(call["id"].text == item, item.utf8.count <= 64, id)
        }
    }

    func testTheCarrierRuleSeesSignedCallsAsWellAsReasoningItems() throws {
        let home = try profile()
        XCTAssertTrue(ProviderClient.carriesReasoning(["type": "reasoning", "encrypted_content": "x"]))
        XCTAssertTrue(ProviderClient.carriesReasoning(["type": "reasoning", "content": [["type": "reasoning_text", "text": "t", "signature": "s"]]]))
        XCTAssertFalse(ProviderClient.carriesReasoning(["type": "reasoning", "summary": [["type": "summary_text", "text": "t"]]]), "A summary alone is nothing a provider refuses")
        XCTAssertTrue(ProviderClient.carriesReasoning(["type": "function_call", "call_id": "call_1__thought__abc"]))
        XCTAssertFalse(ProviderClient.carriesReasoning(["type": "function_call", "call_id": "call_1", "id": "fc_1"]))
        // A reply with nothing but a signed call carries reasoning; the same model gets that id back even from an old row.
        let signedOnly = try ChatMessage(id: "signed", pi: ["role": "assistant", "content": [["type": "toolCall", "id": JSON(Self.signed), "name": "read", "arguments": [:]]]])
        XCTAssertEqual(try ProviderClient.reasoningCarriers([signedOnly, result(Self.signed), try reply("plain", by: home, marked: false)], profile: home), ["signed"])
        XCTAssertEqual(try ProviderClient.reasoningCarriers([try reply("marked", by: home, marked: true)], profile: home), ["marked"])
        // Withheld: nothing of it is carried, short ids included.
        let withheld = home.withholding(["signed", "marked"])
        XCTAssertEqual(try ProviderClient.reasoningCarriers([signedOnly, result(Self.signed), try reply("marked", by: home, marked: true)], profile: withheld), [])
        let tiny = "c__thought__s"
        let sent = try input([try reply("marked", by: home, marked: true, call: tiny), result(tiny)], withheld)
        XCTAssertEqual(kinds(sent), ["message", "function_call", "function_call_output"], "No reasoning item, and no summary as text")
        XCTAssertEqual(sent[1]["call_id"].text, ProviderClient.sentCallID(tiny, .unsigned)); XCTAssertNotEqual(sent[1]["call_id"].text, tiny, "A signature goes whatever the id's length")
        XCTAssertTrue(sent[1]["id"].isNull); XCTAssertEqual(sent[2]["call_id"].text, sent[1]["call_id"].text)
    }

    func testAMoveIsAskedAboutOnlyWhereReasoningIsLeftBehind() throws {
        let home = try profile(), never = try profile { $0["id"] = "quiet"; $0["reasoningReplay"] = "never" }
        let elsewhere = try profile { $0["id"] = "elsewhere"; $0["modelId"] = "moved-model" }
        let marked = try reply(by: home, marked: true), old = try reply(by: home, marked: false)
        XCTAssertTrue(ProviderClient.replaysReasoning(marked, profile: home)); XCTAssertTrue(ProviderClient.replaysReasoning(marked, profile: elsewhere), "It goes along")
        XCTAssertFalse(ProviderClient.replaysReasoning(marked, profile: never)); XCTAssertFalse(ProviderClient.replaysReasoning(old, profile: home), "An old reply's reasoning was not being sent")
    }
}
