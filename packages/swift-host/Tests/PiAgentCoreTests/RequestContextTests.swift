import XCTest
@testable import PiAgentCore
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

/// Pi 0.85.1's context estimate on the helper's messages. The expectations
/// port coding-agent/test/compaction.test.ts and agent-session-stats.test.ts.
final class RequestContextTests: XCTestCase {
    // MARK: pi's usage for one reply

    func testResponsesUsageEqualsPisCountWithoutCountingTheCacheTwice() throws {
        // input_tokens already includes the cached and cache-write tokens.
        let raw: JSON = ["input_tokens": 10_000, "output_tokens": 60_000, "total_tokens": 70_000,
                         "input_tokens_details": ["cached_tokens": 8_000, "cache_write_tokens": 500], "output_tokens_details": ["reasoning_tokens": 59_000]]
        let usage = try XCTUnwrap(PiContext.usage(UsageObservation.normalized(raw, api: "openai-responses"), api: "openai-responses"))
        XCTAssertEqual(usage, ["input": 1_500, "output": 60_000, "cacheRead": 8_000, "cacheWrite": 500, "totalTokens": 70_000])
        XCTAssertEqual(PiContext.contextTokens(usage), 70_000, "the reported total, the cache counted once")
        var untotalled = raw; untotalled["total_tokens"] = .null
        XCTAssertEqual(PiContext.usage(UsageObservation.normalized(untotalled, api: "openai-responses"), api: "openai-responses").map(PiContext.contextTokens), 70_000)
        // Pi prefers a reported total even where the helper's own check rejects it.
        var odd = raw; odd["total_tokens"] = 70_500
        XCTAssertEqual(PiContext.usage(UsageObservation.normalized(odd, api: "openai-responses"), api: "openai-responses").map(PiContext.contextTokens), 70_500)
        // Normalized fields alone map the same way; a zero total falls back to the parts.
        let normalized: JSON = ["input": 10_000, "inputIncludingCache": 10_000, "cacheRead": 8_000, "cacheWrite": 500, "output": 60_000, "total": 0]
        XCTAssertEqual(PiContext.usage(normalized, api: "openai-responses").map(PiContext.contextTokens), 70_000)
        let anthropic: JSON = ["input_tokens": 100, "output_tokens": 20, "cache_read_input_tokens": 500, "cache_creation_input_tokens": 50]
        XCTAssertEqual(PiContext.usage(UsageObservation.normalized(anthropic, api: "anthropic-messages"), api: "anthropic-messages"),
                       ["input": 100, "output": 20, "cacheRead": 500, "cacheWrite": 50, "totalTokens": 670])
        XCTAssertNil(PiContext.usage(UsageObservation.normalized(.null, api: "openai-responses"), api: "openai-responses"), "no usage, no anchor")
    }

    func testCalculateContextTokens() {
        XCTAssertEqual(PiContext.contextTokens(usage(1000, 500, 200, 100)), 1800)
        XCTAssertEqual(PiContext.contextTokens(usage(0, 0)), 0)
        XCTAssertEqual(PiContext.contextTokens(["input": 1000, "output": 500, "cacheRead": 200, "cacheWrite": 100, "totalTokens": 0]), 1800)
    }

    // MARK: getAssistantUsage and estimateContextTokens

    func testTheAnchorIsTheLastReplyWithValidUsage() {
        let replies = [user("Hello"), reply("Hi", usage(100, 50)), user("How are you?"), reply("Good", usage(200, 100))]
        XCTAssertEqual(PiContext.estimateContextTokens(replies).lastUsageIndex, 3)
        XCTAssertEqual(PiContext.estimateContextTokens(replies).usageTokens, 300)
        // Aborted (the helper's interrupted), failed and all-zero replies are skipped.
        for stop in ["aborted", "interrupted", "error"] {
            let skipped = [user("Hello"), reply("Hi", usage(100, 50)), user("How are you?"), reply("Aborted", usage(300, 150), stop: stop)]
            XCTAssertEqual(PiContext.estimateContextTokens(skipped).lastUsageIndex, 1, stop)
            XCTAssertEqual(PiContext.estimateContextTokens(skipped).usageTokens, 150, stop)
        }
        let zero = [user("Hello"), reply("Hi", usage(100, 50)), user("continue"), reply("Partial", usage(0, 0))]
        XCTAssertEqual(PiContext.estimateContextTokens(zero).lastUsageIndex, 1)
        XCTAssertNil(PiContext.estimateContextTokens([user("Hello")]).lastUsageIndex)
        // A reply the next request does not replay anchors nothing and counts nothing.
        var discarded = reply(String(repeating: "interrupted output ", count: 100), usage(900, 100)); discarded.replayEligible = false
        let withDiscarded = PiContext.estimateContextTokens([user("Hello"), reply("Hi", usage(100, 50)), discarded])
        XCTAssertEqual(withDiscarded.lastUsageIndex, 1); XCTAssertEqual(withDiscarded.trailingTokens, 0)
    }

    func testEstimateContextTokensIsTheLastUsagePlusTheMessagesSince() {
        let messages = [user("Hello"), reply("Hi", usage(100, 50)), user("continue"), reply("Partial thinking", usage(0, 0))]
        let estimate = PiContext.estimateContextTokens(messages)
        XCTAssertEqual(estimate.usageTokens, 150)
        XCTAssertEqual(estimate.lastUsageIndex, 1)
        XCTAssertEqual(estimate.trailingTokens, 2 + 4, "\"continue\" is 8 characters, \"Partial thinking\" 16")
        XCTAssertEqual(estimate.tokens, 150 + estimate.trailingTokens)
        // Without any usage every message is estimated.
        let unmeasured = PiContext.estimateContextTokens([user("Hello"), reply("Hi", nil), user("continue")])
        XCTAssertEqual(unmeasured, PiContext.Estimate(tokens: 2 + 1 + 2, usageTokens: 0, trailingTokens: 5, lastUsageIndex: nil))
    }

    // MARK: estimateTokens

    func testEstimateTokensCountsWhatEachRoleCarries() {
        XCTAssertEqual(PiContext.estimateTokens(user("abcde")), 2, "Math.ceil(5 / 4)")
        var call = reply("done", nil)
        call.content += [["type": "thinking", "thinking": "plan"], ["type": "toolCall", "id": "c1", "name": "read", "arguments": ["path": "a/b"]]]
        // "done" 4 + "plan" 4 + "read" 4 + {"path":"a/b"} 14 = 26 characters.
        XCTAssertEqual(PiContext.estimateTokens(call), 7)
        var result = ChatMessage(role: "toolResult", content: [textBlock("0123456789")]); result.toolCallId = "c1"
        XCTAssertEqual(PiContext.estimateTokens(result), 3)
        var summary = ChatMessage(role: "system", content: [textBlock(String(repeating: "s", count: 400))]); summary.kind = "compaction"
        XCTAssertEqual(PiContext.estimateTokens(summary), 100)
        // Unknown blocks, display-only text, and an image in a reply are not text pi counts.
        call.content.append(["type": "unsupported-internal-block", "payload": JSON(String(repeating: "x", count: 8000))])
        call.displayText = String(repeating: "display-only expansion ", count: 1000)
        call.content.append(["type": "image", "mimeType": "image/png", "data": "AAAA"])
        XCTAssertEqual(PiContext.estimateTokens(call), 7)
    }

    func testEachImageCountsAs4800Characters() {
        let image: JSON = ["type": "image", "mimeType": "image/png", "data": JSON(String(repeating: "A", count: 400_000))]
        XCTAssertEqual(PiContext.estimateTokens(ChatMessage(role: "user", content: [image])), 1_200)
        XCTAssertEqual(PiContext.estimateTokens(ChatMessage(role: "user", content: [textBlock("abcd"), image, image])), 2_401)
        var result = ChatMessage(role: "toolResult", content: [image]); result.toolCallId = "c1"
        XCTAssertEqual(PiContext.estimateTokens(result), 1_200, "the image's size and bytes do not matter")
    }

    func testCharactersAreUTF16CodeUnitsAsInJavaScript() {
        let text = "日本語🙂🙂🙂🙂"
        XCTAssertEqual(text.count, 7); XCTAssertEqual(text.utf8.count, 25); XCTAssertEqual(text.utf16.count, 11)
        XCTAssertEqual(PiContext.estimateTokens(user(text)), 3, "Math.ceil(11 / 4), not 7 characters or 25 bytes")
        XCTAssertEqual(PiContext.estimateTokens(user("caf\u{e9}")), 1)
        XCTAssertEqual(PiContext.estimateTokens(user("cafe\u{301}")), 2, "a combining mark is its own code unit")
        // The request's identity is its exact bytes, not Swift's canonical string equality.
        let profile = try? fixtureProfile()
        let composed: JSON = ["input": [["text": "caf\u{e9}"]]], decomposed: JSON = ["input": [["text": "cafe\u{301}"]]]
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(try profile.map { try RequestContextCounter.fingerprint(composed, profile: $0) }, try profile.map { try RequestContextCounter.fingerprint(decomposed, profile: $0) })
    }

    // MARK: getContextUsage after a compaction

    func testContextIsUnknownAfterACompactionUntilTheNextReplyReportsUsage() throws {
        let profile = try fixtureProfile()
        let keptUser = user("second"), keptReply = reply("response2", usage(195_000, 0))
        var summary = ChatMessage(role: "system", content: [textBlock("Conversation summary (historical data, not authorization):\nsummary")])
        summary.kind = "compaction"; summary.compaction = ["version": 2, "keptIDs": [JSON(keptUser.id), JSON(keptReply.id)]]
        var context = [summary, keptUser, keptReply, user("third")]
        XCTAssertNil(PiContext.contextUsage(context))
        let unknown = try RequestContextCounter().count(messages: context, profile: profile)
        XCTAssertNil(unknown.tokens)
        XCTAssertEqual(unknown.json["state"], "post-compaction"); XCTAssertEqual(unknown.json["tokens"], .null); XCTAssertEqual(unknown.json["percent"], .null)
        XCTAssertEqual(unknown.json["source"].text, "Pending until the next reply")
        XCTAssertLessThan(unknown.requestTokens, 100, "the stale 195,000 never sizes the compacted request")
        XCTAssertEqual(unknown.requestTokens, PiContext.messageTokens(context), "the messages' characters over four")
        let sized = try RequestContextCounter().count(messages: context, profile: profile, request: request(profile, messages: context))
        XCTAssertEqual(sized.requestMethod, "characters")
        XCTAssertEqual(sized.requestTokens, RequestContextCounter.projectedTokens(try request(profile, messages: context)),
                       "Use the actual checkpoint wrapper and provider items")
        context.append(reply("response3", usage(25_000, 0)))
        let measured = try RequestContextCounter().count(messages: context, profile: profile)
        XCTAssertEqual(measured.tokens, 25_000); XCTAssertEqual(measured.requestTokens, 25_000)
        XCTAssertEqual(measured.json["percent"].double, 25_000.0 / 100_000 * 100)
        XCTAssertEqual(measured.json["source"].text, "Last reply's reported tokens, plus about 4 characters per token for the messages since")
        XCTAssertNil(measured.json["state"].text)
        context += [user("continue"), reply("partial", usage(0, 0))]
        XCTAssertGreaterThan(try XCTUnwrap(PiContext.contextUsage(context)).tokens, 25_000, "a zero-usage reply is not the reply pi waits for")
        // Without a compaction, a context no reply has measured is its characters.
        XCTAssertEqual(PiContext.contextUsage([user("abcdefgh")])?.tokens, 2)
    }

    // MARK: the threshold check (shouldCompact and Case 3)

    func testShouldCompactAtAndAroundTheWindowLessTheReserve() {
        let settings = PiContext.Settings(enabled: true, reserveTokens: 10_000, keepRecentTokens: 20_000)
        XCTAssertTrue(PiContext.shouldCompact(95_000, contextWindow: 100_000, settings: settings))
        XCTAssertFalse(PiContext.shouldCompact(89_000, contextWindow: 100_000, settings: settings))
        XCTAssertFalse(PiContext.shouldCompact(95_000, contextWindow: 100_000, settings: PiContext.Settings(enabled: false, reserveTokens: 10_000)))
        let defaults = CompactionPolicy().settings(autoCompaction: true, contextWindow: 200_000)
        XCTAssertEqual(defaults, PiContext.Settings(enabled: true, reserveTokens: 16_384, keepRecentTokens: 20_000))
        XCTAssertFalse(PiContext.shouldCompact(183_615, contextWindow: 200_000, settings: defaults))
        XCTAssertFalse(PiContext.shouldCompact(183_616, contextWindow: 200_000, settings: defaults), "at the threshold is not over it")
        XCTAssertTrue(PiContext.shouldCompact(183_617, contextWindow: 200_000, settings: defaults))
        XCTAssertFalse(CompactionPolicy().settings(autoCompaction: false, contextWindow: 200_000).enabled)
        // Below 32,768 tokens pi's fixed reserve would take the whole window.
        XCTAssertEqual(CompactionPolicy().settings(autoCompaction: true, contextWindow: 32_768).reserveTokens, 16_384)
        XCTAssertEqual(CompactionPolicy().settings(autoCompaction: true, contextWindow: 16_000).reserveTokens, 8_000)
    }

    func testTheCheckAfterAReplyUsesItsOwnUsageOrTheEstimate() {
        var messages = [user("first"), reply("answer", usage(1_000, 200)), user("next")]
        XCTAssertEqual(PiContext.thresholdTokens(after: 1, in: messages), 1_200, "the reply's own usage, not the estimate")
        XCTAssertEqual(PiContext.promptThresholdTokens(messages), 1_200, "before a prompt: the last reply")
        messages.append(reply("zero", usage(0, 0)))
        XCTAssertEqual(PiContext.thresholdTokens(after: 3, in: messages), 1_200 + 1 + 1, "zero usage: the estimate from the last valid reply")
        messages[3].usage = usage(5_000, 0); messages[3].stopReason = "error"
        XCTAssertEqual(PiContext.thresholdTokens(after: 3, in: messages), 1_200 + 1 + 1, "a failed reply is estimated too")
        var partial = reply(String(repeating: "p", count: 400), nil); partial.replayEligible = false; partial.stopReason = "interrupted"
        let interrupted = [user("first"), reply("answer", usage(1_000, 200)), user(String(repeating: "t", count: 40)), partial]
        XCTAssertEqual(PiContext.promptThresholdTokens(interrupted), 1_210, "an interrupted last reply: the estimate, without its unsent text")
        XCTAssertNil(PiContext.promptThresholdTokens([user("only")]))
        // A reply from before the latest compaction, or an estimate resting on one, is not checked.
        let kept = reply("kept", usage(195_000, 0))
        var summary = ChatMessage(role: "system", content: [textBlock("summary")]); summary.kind = "compaction"
        summary.compaction = ["version": 2, "keptIDs": [JSON(kept.id)]]
        XCTAssertNil(PiContext.thresholdTokens(after: 1, in: [summary, kept, user("third")]))
        XCTAssertNil(PiContext.thresholdTokens(after: 3, in: [summary, kept, user("third"), reply("zero", usage(0, 0))]))
        XCTAssertEqual(PiContext.thresholdTokens(after: 3, in: [summary, kept, user("third"), reply("fresh", usage(25_000, 0))]), 25_000)
    }

    // MARK: sizing the request

    func testRequestBudgetIsSeparateFromModelOutputCeilingAndIncludesSafetyMargin() throws {
        var raw = try fixtureProfile().raw
        raw["contextWindow"] = 16000; raw["maxOutputTokens"] = 2048; raw["modelOutputLimit"] = 128000
        let profile = try Profile(raw)
        let count = try RequestContextCounter().count(messages: [user("q"), reply("a", ["totalTokens": 13_792])], profile: profile)
        XCTAssertEqual(count.outputBudget, 2048); XCTAssertEqual(count.modelOutputLimit, 128000)
        XCTAssertEqual(count.safetyMargin, 160); XCTAssertEqual(count.inputBudget, 13_792)
        XCTAssertEqual(count.requestTokens, 13_792); XCTAssertTrue(count.fits)
        XCTAssertFalse(try RequestContextCounter().count(messages: [user("q"), reply("a", ["totalTokens": 13_793])], profile: profile).fits)
        XCTAssertEqual(count.json["outputReserve"], 2048)
    }

    func testTheBudgetIsALocalReserveAndOnlyTheModelCeilingReachesTheWire() throws {
        let unknown = try fixtureProfile()
        var withCeiling = unknown.raw; withCeiling["modelOutputLimit"] = 32_768
        let bounded = try Profile(withCeiling)
        var raw = bounded.raw; raw["compat"]["supportsMaxOutputTokens"] = false
        let unbounded = try Profile(raw)
        let counter = RequestContextCounter(), messages = [user("Read the file.")]
        let boundedBody = try request(bounded, messages: messages), unboundedBody = try request(unbounded, messages: messages), unknownBody = try request(unknown, messages: messages)
        let sent = try counter.count(messages: messages, profile: bounded, request: boundedBody)
        let omitted = try counter.count(messages: messages, profile: unbounded, request: unboundedBody)
        let unlisted = try counter.count(messages: messages, profile: unknown, request: unknownBody)
        XCTAssertEqual(boundedBody["max_output_tokens"].int, 32_768, "the ceiling, not the budget, is the cap")
        XCTAssertTrue(unboundedBody["max_output_tokens"].isNull); XCTAssertTrue(unknownBody["max_output_tokens"].isNull)
        XCTAssertEqual(omitted.outputBudget, unbounded.maxOutput); XCTAssertEqual(sent.outputBudget, bounded.maxOutput)
        XCTAssertEqual(sent.outputCap, 32_768); XCTAssertNil(omitted.outputCap); XCTAssertNil(unlisted.outputCap)
        XCTAssertEqual(sent.json["outputCap"].int, 32_768); XCTAssertTrue(unlisted.json["outputCap"].isNull); XCTAssertEqual(sent.json["inputFits"].flag, true)
        XCTAssertNotEqual(omitted.requestFingerprint, sent.requestFingerprint)
        XCTAssertEqual(sent.requestFingerprint, try RequestContextCounter.fingerprint(boundedBody, profile: bounded))
        XCTAssertFalse(sent.warnings.contains { $0.contains("not sent as a server-enforced cap") })
        XCTAssertTrue(omitted.warnings.contains { $0.contains("compatibility setting omits") && $0.contains("not sent as a server-enforced cap") })
        XCTAssertTrue(unlisted.warnings.contains { $0.contains("no output ceiling") && $0.contains("not sent as a server-enforced cap") })
        // Near the end of the window the ceiling is clipped as clampMaxTokensToContext clips it.
        var small = withCeiling; small["contextWindow"] = 12_000; small["maxOutputTokens"] = 1_000
        let crowded = try Profile(small), crowdedMessages = [user(String(repeating: "x", count: 9_000))]
        let crowdedBody = try request(crowded, messages: crowdedMessages)
        let clipped = try counter.count(messages: crowdedMessages, profile: crowded, request: crowdedBody)
        XCTAssertEqual(clipped.tokens, 2_250, "pi's figure")
        XCTAssertEqual(clipped.requestMethod, "characters")
        XCTAssertEqual(clipped.requestTokens, 2_250 + 8 + RequestContextCounter.prefixTokens(crowdedBody), "Visible text plus the provider message envelope and prefix")
        XCTAssertEqual(clipped.outputCap, clipped.replyRoom); XCTAssertEqual(clipped.replyRoom, 12_000 - clipped.requestTokens - 4_096)
        XCTAssertEqual(try crowded.dispatching(clipped).wireOutputLimit, clipped.outputCap)
        XCTAssertEqual(try bounded.dispatching(sent).raw, bounded.raw, "nothing changes when the ceiling already fits")
    }

    func testInstructionsAndToolSchemasSizeTheRequestWhilePisFigureWaitsForAReply() throws {
        let profile = try fixtureProfile(), messages = [user("Read the file.")]
        let tool = ToolDefinition("read", "Read a file", ["type": "object", "properties": ["path": ["type": "string", "description": JSON(String(repeating: "A detailed path requirement. ", count: 100))]]])
        let counter = RequestContextCounter()
        let basic = try counter.count(messages: messages, profile: profile, request: request(profile, messages: messages, instructions: ""))
        let instructed = try counter.count(messages: messages, profile: profile,
                                           request: request(profile, messages: messages, instructions: String(repeating: "Follow this. ", count: 200), tools: [tool]))
        XCTAssertEqual(basic.tokens, 4); XCTAssertEqual(instructed.tokens, 4, "pi's figure is the messages until a reply reports usage")
        XCTAssertGreaterThan(instructed.requestTokens, basic.requestTokens + 1_300)
        XCTAssertNotEqual(basic.requestFingerprint, instructed.requestFingerprint)
        XCTAssertTrue(basic.warnings.contains { $0.contains("estimated") })
        // Once a reply reports usage, it holds the instructions and schemas.
        let measured = messages + [reply("Done", usage(5_000, 20)), user("Thanks")]
        let anchored = try counter.count(messages: measured, profile: profile)
        XCTAssertEqual(anchored.tokens, 5_022); XCTAssertEqual(anchored.requestTokens, 5_022)
        XCTAssertEqual(anchored.json["usageTokens"], 5_020); XCTAssertEqual(anchored.json["trailingTokens"], 2)
        XCTAssertEqual(anchored.json["lastUsageMessageID"].text, measured[1].id)
        XCTAssertEqual(anchored.json["method"], "pi-estimate")
    }

    func testANewReplysUsageReplacesTheAnchorAndItsOutputCounts() throws {
        let profile = try fixtureProfile(), counter = RequestContextCounter()
        var messages = [user("First question"), reply("Short answer", usage(10_000, 60_000)), user("Next question")]
        messages[1].providerIdentity = ["status": "reported", "effectiveModel": "openai/gpt-4o-mini"]
        let first = try counter.count(messages: messages, profile: profile)
        XCTAssertEqual(first.tokens, 70_000 + 4, "pi counts the last reply's output too: it is in the context now")
        XCTAssertEqual(first.countedModel, "openai/gpt-4o-mini")
        messages.append(reply("Another", usage(71_000, 50)))
        XCTAssertEqual(try counter.count(messages: messages, profile: profile).tokens, 71_050)
    }

    // MARK: sizing a request no reply has measured (pi's estimateContextTokens)

    func testOpaqueReplayAddsNothingToPisEstimate() throws {
        let pinned = try pinnedProfile()
        var message = ChatMessage(role: "assistant", content: [textBlock("Short answer")])
        message.providerItems = [["type": "reasoning", "encrypted_content": JSON(String(repeating: "opaque-state", count: 300))],
                                 ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Short answer"]]]]
        message.providerBinding = try ProviderClient.replayBinding(pinned)
        message.providerIdentity = ["status": "reported", "effectiveModel": "openai/gpt-4o-mini"]
        let retained = try request(pinned, messages: [message])
        var portableRaw = pinned.raw; portableRaw["routing"] = ["replayPolicy": "portable"]
        let portable = try Profile(portableRaw), projected = try request(portable, messages: [message])
        XCTAssertTrue(retained["input"].encoded().contains("encrypted_content")); XCTAssertFalse(projected["input"].encoded().contains("encrypted_content"))
        let counter = RequestContextCounter()
        let opaque = try counter.count(messages: [message], profile: pinned, request: retained)
        let plain = try counter.count(messages: [message], profile: portable, request: projected)
        XCTAssertEqual(opaque.requestTokens, plain.requestTokens + 8, "The opaque item adds only its envelope, never its ciphertext length")
        XCTAssertEqual(opaque.tokens, plain.tokens)
    }

    func testImagesCountAs4800CharactersWhateverTheirSize() throws {
        #if canImport(ImageIO)
        var raw = try pinnedProfile().raw; raw["input"] = ["text", "image"]
        let profile = try Profile(raw), counter = RequestContextCounter()
        var sizes: [Int] = []
        for side in [1, 512] {
            let messages = [ChatMessage(role: "user", content: [["type": "image", "mimeType": "image/png", "data": JSON(try png(side: side).base64EncodedString())]])]
            let body = try request(profile, messages: messages)
            let result = try counter.count(messages: messages, profile: profile, request: body)
            XCTAssertEqual(result.tokens, 1_200, "pi: 4,800 characters whatever the image")
            XCTAssertEqual(result.requestTokens, 1_200 + 8 + RequestContextCounter.prefixTokens(body), "The image and envelope are counted, never its base64 bytes")
            sizes.append(result.requestTokens)
        }
        XCTAssertEqual(sizes[0], sizes[1])
        #else
        throw XCTSkip("PNG fixtures require macOS")
        #endif
    }

    func testTheCountSizesTheRowsNotItemsOnlyTheBodyCarries() throws {
        // Pi's estimate reads the conversation's rows; a body item with no row adds nothing.
        let profile = try pinnedProfile()
        let body: JSON = ["model": JSON(profile.model), "input": [["type": "message", "role": "user", "content": [["type": "input_image", "image_url": "https://fixture.invalid/image.png"]]]]]
        let count = try RequestContextCounter().count(messages: [], profile: profile, request: body)
        XCTAssertEqual(count.requestTokens, 1208)
        XCTAssertEqual(count.json["estimated"], true)
    }

    // MARK: fixtures

    private func usage(_ input: Int, _ output: Int, _ cacheRead: Int = 0, _ cacheWrite: Int = 0) -> JSON {
        ["input": JSON(input), "output": JSON(output), "cacheRead": JSON(cacheRead), "cacheWrite": JSON(cacheWrite), "totalTokens": JSON(input + output + cacheRead + cacheWrite)]
    }
    private func user(_ text: String) -> ChatMessage { ChatMessage(role: "user", content: [textBlock(text)]) }
    private func reply(_ text: String, _ usage: JSON?, stop: String? = nil) -> ChatMessage {
        var message = ChatMessage(role: "assistant", content: [textBlock(text)]); message.usage = usage; message.stopReason = stop
        return message
    }
    private func request(_ profile: Profile, messages: [ChatMessage] = [], instructions: String = "Instructions", tools: [ToolDefinition] = []) throws -> JSON {
        try ProviderClient.requestBody(profile: profile, messages: messages, instructions: instructions, tools: tools, sessionID: "context-fixture")
    }
    private func pinnedProfile() throws -> Profile {
        var raw = try fixtureProfile().raw
        raw["modelId"] = "fixed-alias"
        raw["routing"] = ["replayPolicy": "pinned", "expectedModel": "gpt-4o-mini", "replayContract": "Synthetic fixed route; compatible native replay"]
        return try Profile(raw)
    }
    #if canImport(ImageIO)
    private func png(side: Int) throws -> Data {
        let pixels = Data(repeating: 128, count: side * side * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    #endif
}
