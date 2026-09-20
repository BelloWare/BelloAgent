import XCTest
@testable import PiAgentCore
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

final class RequestContextTests: XCTestCase {
    func testCacheUsesExactUTF8AndInvalidatesEveryRequestAndProfileChange() throws {
        let profile = try fixtureProfile()
        let first: JSON = ["input": [["text": "caf\u{e9}"], ["text": "second"]], "tools": [["name": "read"]]]
        let canonicallyEqual: JSON = ["input": [["text": "cafe\u{301}"], ["text": "second"]], "tools": [["name": "read"]]]
        XCTAssertEqual(first, canonicallyEqual, "Swift String equality is deliberately insufficient for byte fingerprints")
        var counter = RequestContextCounter()
        let old = try counter.count(request: first, profile: profile)
        let changed = try counter.count(request: canonicallyEqual, profile: profile)
        XCTAssertNotEqual(old.requestFingerprint, changed.requestFingerprint)
        XCTAssertEqual(changed.requestFingerprint, try RequestContextCounter.fingerprint(canonicallyEqual, profile: profile))
        var reordered = first; reordered["input"] = .array(first["input"].list.reversed())
        var instructions = first; instructions["instructions"] = "new rules"
        var image = first; image["input"] = [["type": "input_image", "image_url": "data:image/png;base64,fixture"]]
        for value in [reordered, instructions, image] {
            let reused = try counter.count(request: value, profile: profile)
            var oracle = RequestContextCounter()
            let fresh = try oracle.count(request: value, profile: profile)
            XCTAssertEqual(reused.json, fresh.json)
            XCTAssertNotEqual(reused.requestFingerprint, old.requestFingerprint)
        }
        for name in ["revision", "headers", "routing", "modelId"] {
            var raw = profile.raw
            raw[name] = name == "headers" ? ["x-route": "new"] : name == "routing" ? ["replayPolicy": "portable"] : "changed"
            let changedProfile = try Profile(raw)
            XCTAssertNotEqual(try RequestContextCounter.cacheIdentity(request: first, profile: changedProfile), try RequestContextCounter.cacheIdentity(request: first, profile: profile))
        }
    }

    func testCountsTheBuiltRequestAndIgnoresDiscardedInternalBlocks() throws {
        let profile = try fixtureProfile()
        let user = ChatMessage(role: "user", content: [textBlock("Keep this input.")])
        let clean = ChatMessage(role: "assistant", content: [textBlock("A short answer.")])
        var projected = clean
        projected.content.append(["type": "thinking", "thinking": JSON(String(repeating: "display-only thought ", count: 1000))])
        projected.content.append(["type": "unsupported-internal-block", "payload": JSON(String(repeating: "x", count: 8000))])
        projected.displayText = String(repeating: "display-only expansion ", count: 1000)
        var discarded = ChatMessage(role: "assistant", content: [textBlock(String(repeating: "interrupted output ", count: 1000))])
        discarded.replayEligible = false
        let expected = try request(profile, messages: [user, clean])
        let actual = try request(profile, messages: [user, projected, discarded])
        XCTAssertEqual(actual, expected, "Only replayed provider input belongs in the count")
        var counter = RequestContextCounter()
        let first = try counter.count(request: expected, profile: profile)
        let second = try counter.count(request: actual, profile: profile)
        XCTAssertEqual(first.tokens, second.tokens)
        XCTAssertEqual(first.requestFingerprint, second.requestFingerprint)
        XCTAssertLessThan(first.tokens, 200)
    }

    func testActualInstructionsAndToolSchemasChangeCountAndFingerprint() throws {
        let profile = try fixtureProfile(), messages = [ChatMessage(role: "user", content: [textBlock("Read the file.")])]
        let basic = try request(profile, messages: messages)
        let instructed = try request(profile, messages: messages, instructions: String(repeating: "Follow this additional instruction. ", count: 100))
        let compactTool = ToolDefinition("read", "Read a file", ["type": "object", "properties": ["path": ["type": "string"]]])
        let detailedTool = ToolDefinition("read", "Read a file", ["type": "object", "properties": ["path": ["type": "string", "description": JSON(String(repeating: "A detailed path requirement. ", count: 100))]]])
        let withTool = try request(profile, messages: messages, tools: [compactTool])
        let withLargeSchema = try request(profile, messages: messages, tools: [detailedTool])
        var counter = RequestContextCounter()
        let counts = try [basic, instructed, withTool, withLargeSchema].map { try counter.count(request: $0, profile: profile) }
        XCTAssertEqual(Set(counts.map(\.requestFingerprint)).count, 4)
        XCTAssertGreaterThan(counts[1].tokens, counts[0].tokens + 500)
        XCTAssertGreaterThan(counts[2].tokens, counts[0].tokens)
        XCTAssertGreaterThan(counts[3].tokens, counts[2].tokens + 500)
    }

    func testPinnedUsageBaselineCountsOnlyNewlyReplayedInputAndNeverAllPreviousOutput() throws {
        let profile = try pinnedProfile()
        let user = ChatMessage(role: "user", content: [textBlock("First question")])
        let initial = try request(profile, messages: [user])
        var reply = reportedReply(input: 10_000, output: 60_000)
        reply.usage["cacheRead"] = 8000
        reply.usage["cacheWrite"] = 500
        reply.usage["reasoning"] = 59_000
        let baseline = try XCTUnwrap(RequestUsageBaseline(request: initial, profile: profile, reply: reply))
        let next = try request(profile, messages: [user, reply.message, ChatMessage(role: "user", content: [textBlock("Next question")])])
        var counter = RequestContextCounter()
        let unchanged = try counter.count(request: initial, profile: profile, baseline: baseline)
        let expanded = try counter.count(request: next, profile: profile, baseline: baseline)
        XCTAssertEqual(unchanged.tokens, 10_000, "Responses input already includes cache reads and writes")
        XCTAssertEqual(expanded.method, "usage-baseline")
        XCTAssertEqual(expanded.countedModel, "openai/gpt-4o-mini")
        XCTAssertGreaterThan(expanded.tokens, 10_000)
        XCTAssertLessThan(expanded.tokens, 10_200, "Only the short replayed answer and appended question contribute, not 60,000 output tokens")
        XCTAssertEqual(expanded.json["estimated"], true)
    }

    func testBaselineRequiresPinnedMatchingReportedIdentityAndUsableInputUsage() throws {
        let pinned = try pinnedProfile(), body = try request(pinned)
        let reply = reportedReply(input: 1000)
        XCTAssertNotNil(try RequestUsageBaseline(request: body, profile: pinned, reply: reply))
        var raw = pinned.raw; raw["routing"] = ["replayPolicy": "portable"]
        XCTAssertNil(try RequestUsageBaseline(request: body, profile: Profile(raw), reply: reply))
        XCTAssertNil(try RequestUsageBaseline(request: body, profile: fixtureProfile(), reply: reply))
        for identity: JSON in [[:], ["status": "conflict", "effectiveModel": "gpt-4o-mini"], ["status": "unreported", "effectiveModel": "gpt-4o-mini"], ["status": "reported", "effectiveModel": "another-backend"]] {
            var changed = reply; changed.message.providerIdentity = identity
            XCTAssertNil(try RequestUsageBaseline(request: body, profile: pinned, reply: changed))
        }
        for usage: JSON in [[:], ["output": 1000], ["input": -1]] {
            var changed = reply; changed.usage = usage
            XCTAssertNil(try RequestUsageBaseline(request: body, profile: pinned, reply: changed))
        }
    }

    func testBaselineInvalidatesForChangedAliasInstructionsSchemaReplayPolicyAndParameters() throws {
        let profile = try pinnedProfile()
        let user = ChatMessage(role: "user", content: [textBlock("First question")])
        let body = try request(profile, messages: [user])
        let baseline = try XCTUnwrap(RequestUsageBaseline(request: body, profile: profile, reply: reportedReply(input: 10_000)))
        var cases: [(String, Profile, JSON)] = []
        var instructions = body; instructions["instructions"] = "Different instructions"; cases.append(("instructions", profile, instructions))
        var tools = body; tools["tools"] = [["type": "function", "name": "new-tool", "parameters": ["type": "object"]]]; cases.append(("tools", profile, tools))
        var parameter = body; parameter["temperature"] = 0.5; cases.append(("sampling parameter", profile, parameter))
        var output = body; output["max_output_tokens"] = 1024; cases.append(("requested output", profile, output))
        var format = body; format["text"] = ["format": ["type": "json_object"]]; cases.append(("response format", profile, format))
        for (name, change): (String, JSON) in [("modelId", "another-alias"), ("routing", ["replayPolicy": "portable"]), ("headers", ["x-fixture-route": "another-deployment"]), ("revision", "2")] {
            var raw = profile.raw; raw[name] = change
            let changed = try Profile(raw)
            cases.append((name, changed, try request(changed, messages: [user])))
        }
        var counter = RequestContextCounter()
        let original = try counter.count(request: body, profile: profile, baseline: baseline)
        for (name, changedProfile, changedBody) in cases {
            let counted = try counter.count(request: changedBody, profile: changedProfile, baseline: baseline)
            XCTAssertEqual(counted.method, "heuristic", name)
            XCTAssertNotEqual(counted.requestFingerprint, original.requestFingerprint, name)
            XCTAssertLessThan(counted.tokens, 10_000, "\(name) must not retain an unrelated measured prefix")
        }
    }

    func testBaselineRequiresExactOrderedPrefixAndAllowsOnlyAppendedItems() throws {
        let profile = try pinnedProfile()
        let first = ChatMessage(role: "user", content: [textBlock("First")]), second = ChatMessage(role: "assistant", content: [textBlock("Second")])
        let body = try request(profile, messages: [first, second])
        let baseline = try XCTUnwrap(RequestUsageBaseline(request: body, profile: profile, reply: reportedReply(input: 1000)))
        var counter = RequestContextCounter()
        for messages in [[second, first], [first], [ChatMessage(role: "user", content: [textBlock("Changed first")]), second]] {
            let changed = try request(profile, messages: messages)
            XCTAssertEqual(try counter.count(request: changed, profile: profile, baseline: baseline).method, "heuristic")
        }
        let appended = try request(profile, messages: [first, second, ChatMessage(role: "user", content: [textBlock("Third")])])
        XCTAssertEqual(try counter.count(request: appended, profile: profile, baseline: baseline).method, "usage-baseline")
    }

    func testOpaqueReplayIsCountedOnlyWhenActuallyIncludedAndWarnsAboutUnknownContextCost() throws {
        let pinned = try pinnedProfile()
        var reply = reportedReply(input: 1000)
        reply.message.providerItems = [["type": "reasoning", "encrypted_content": JSON(String(repeating: "opaque-state", count: 300))],
                                      ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Short answer"]]]]
        reply.message.providerBinding = try ProviderClient.replayBinding(pinned)
        let retained = try request(pinned, messages: [reply.message])
        var portableRaw = pinned.raw; portableRaw["routing"] = ["replayPolicy": "portable"]
        let portable = try Profile(portableRaw), projected = try request(portable, messages: [reply.message])
        XCTAssertTrue(retained["input"].encoded().contains("encrypted_content")); XCTAssertFalse(projected["input"].encoded().contains("encrypted_content"))
        var counter = RequestContextCounter()
        let opaque = try counter.count(request: retained, profile: pinned), plain = try counter.count(request: projected, profile: portable)
        XCTAssertGreaterThan(opaque.tokens, plain.tokens + 500)
        XCTAssertTrue(opaque.warnings.contains { $0.contains("Opaque reasoning") && $0.contains("unknown") })
        XCTAssertFalse(plain.warnings.contains { $0.contains("Opaque reasoning") })
        XCTAssertTrue(plain.warnings.contains { $0.contains("routed model") })
    }

    func testRequestBudgetIsSeparateFromModelOutputCeilingAndIncludesSafetyMargin() throws {
        var raw = try pinnedProfile().raw
        raw["contextWindow"] = 16000; raw["maxOutputTokens"] = 2048; raw["modelOutputLimit"] = 128000
        let profile = try Profile(raw), body = try request(profile)
        var counter = RequestContextCounter()
        let measured = try XCTUnwrap(RequestUsageBaseline(request: body, profile: profile, reply: reportedReply(input: 13_792)))
        let count = try counter.count(request: body, profile: profile, baseline: measured)
        XCTAssertEqual(count.outputBudget, 2048); XCTAssertEqual(count.modelOutputLimit, 128000)
        XCTAssertEqual(count.safetyMargin, 160); XCTAssertEqual(count.inputBudget, 13_792)
        XCTAssertTrue(count.fits)
        let over = try XCTUnwrap(RequestUsageBaseline(request: body, profile: profile, reply: reportedReply(input: 13_793)))
        XCTAssertFalse(try counter.count(request: body, profile: profile, baseline: over).fits)
        XCTAssertEqual(count.json["outputReserve"], 2048)
    }

    func testTheBudgetIsALocalReserveAndOnlyTheModelCeilingReachesTheWire() throws {
        let unknown = try pinnedProfile()
        var withCeiling = unknown.raw; withCeiling["modelOutputLimit"] = 32_768
        let bounded = try Profile(withCeiling)
        var raw = bounded.raw; raw["compat"]["supportsMaxOutputTokens"] = false
        let unbounded = try Profile(raw)
        var counter = RequestContextCounter()
        let boundedBody = try request(bounded), unboundedBody = try request(unbounded), unknownBody = try request(unknown)
        let sent = try counter.count(request: boundedBody, profile: bounded)
        let omitted = try counter.count(request: unboundedBody, profile: unbounded)
        let unlisted = try counter.count(request: unknownBody, profile: unknown)
        XCTAssertEqual(boundedBody["max_output_tokens"].int, 32_768, "the ceiling, not the budget, is the cap")
        XCTAssertNotEqual(boundedBody["max_output_tokens"].int, bounded.maxOutput)
        XCTAssertTrue(unboundedBody["max_output_tokens"].isNull); XCTAssertTrue(unknownBody["max_output_tokens"].isNull)
        XCTAssertEqual(omitted.outputBudget, unbounded.maxOutput); XCTAssertEqual(sent.outputBudget, bounded.maxOutput)
        XCTAssertEqual(sent.outputCap, 32_768); XCTAssertNil(omitted.outputCap); XCTAssertNil(unlisted.outputCap)
        XCTAssertEqual(sent.json["outputCap"].int, 32_768); XCTAssertTrue(unlisted.json["outputCap"].isNull); XCTAssertEqual(sent.json["inputFits"].flag, true)
        XCTAssertNotEqual(omitted.requestFingerprint, sent.requestFingerprint)
        XCTAssertFalse(sent.warnings.contains { $0.contains("not sent as a server-enforced cap") })
        XCTAssertTrue(omitted.warnings.contains { $0.contains("compatibility setting omits") && $0.contains("not sent as a server-enforced cap") })
        XCTAssertTrue(unlisted.warnings.contains { $0.contains("no output ceiling") && $0.contains("not sent as a server-enforced cap") })
        // Near the end of the window the ceiling is clipped to the room the input leaves.
        var small = withCeiling; small["contextWindow"] = 6_000; small["maxOutputTokens"] = 1_000
        let crowded = try Profile(small)
        let crowdedBody = try request(crowded, messages: [ChatMessage(role: "user", content: [textBlock(String(repeating: "x", count: 9_000))])])
        let clipped = try counter.count(request: crowdedBody, profile: crowded)
        XCTAssertEqual(clipped.outputCap, clipped.replyRoom); XCTAssertEqual(clipped.replyRoom, 6_000 - clipped.tokens - 60)
        XCTAssertLessThan(try XCTUnwrap(clipped.outputCap), 32_768)
        XCTAssertEqual(try crowded.dispatching(clipped).wireOutputLimit, clipped.outputCap)
        XCTAssertEqual(try bounded.dispatching(sent).raw, bounded.raw, "nothing changes when the ceiling already fits")
    }

    func testSameRequestIsStableAndNewBaselineEvidenceInvalidatesTheCachedCount() throws {
        let profile = try pinnedProfile(), body = try request(profile)
        var counter = RequestContextCounter()
        let start = Date(timeIntervalSince1970: 1000)
        let heuristic = try counter.count(request: body, profile: profile, now: start)
        let repeated = try counter.count(request: body, profile: profile, now: start.addingTimeInterval(1))
        XCTAssertEqual(heuristic.json, repeated.json)
        let firstBaseline = try XCTUnwrap(RequestUsageBaseline(request: body, profile: profile, reply: reportedReply(input: 1234)))
        let first = try counter.count(request: body, profile: profile, baseline: firstBaseline, now: start.addingTimeInterval(2))
        let newBaseline = try XCTUnwrap(RequestUsageBaseline(request: body, profile: profile, reply: reportedReply(input: 2345)))
        let newer = try counter.count(request: body, profile: profile, baseline: newBaseline, now: start.addingTimeInterval(3))
        XCTAssertEqual(first.tokens, 1234); XCTAssertEqual(newer.tokens, 2345)
        XCTAssertEqual(first.method, "usage-baseline"); XCTAssertEqual(newer.method, "usage-baseline")
        XCTAssertEqual(heuristic.requestFingerprint, newer.requestFingerprint, "New evidence changes the count, not the actual request identity")
        XCTAssertEqual(try counter.count(request: body, profile: profile, baseline: newBaseline, now: start.addingTimeInterval(304)).json, newer.json)
    }

    func testImagesUseDimensionsAndDeclaredModelPolicyInsteadOfAFixed4096Tokens() throws {
        #if canImport(ImageIO)
        let profile = try pinnedProfile()
        var counter = RequestContextCounter()
        for side in [1, 512] {
            let image: JSON = ["type": "image", "mimeType": "image/png", "data": JSON(try png(side: side).base64EncodedString())]
            let body = try request(profile, messages: [ChatMessage(role: "user", content: [image])])
            let result = try counter.count(request: body, profile: profile)
            XCTAssertGreaterThan(result.tokens, 4096, "Pinned gpt-4o-mini high-detail accounting must not use the former fixed 4,096 allowance (\(side)×\(side))")
            XCTAssertLessThan(result.tokens, 30000, "Compressed image bytes are not counted as model-facing base64 text")
            XCTAssertFalse(result.warnings.contains { $0.contains("dimensions are unavailable") })
        }
        let tiny = try png(side: 1), large = try png(side: 512)
        let unknown = try fixtureProfile()
        let tinyRequest = try request(unknown, messages: [ChatMessage(role: "user", content: [["type": "image", "mimeType": "image/png", "data": JSON(tiny.base64EncodedString())]])])
        let largeRequest = try request(unknown, messages: [ChatMessage(role: "user", content: [["type": "image", "mimeType": "image/png", "data": JSON(large.base64EncodedString())]])])
        let smallCount = try counter.count(request: tinyRequest, profile: unknown), largeCount = try counter.count(request: largeRequest, profile: unknown)
        XCTAssertGreaterThan(largeCount.tokens, smallCount.tokens)
        XCTAssertTrue(largeCount.warnings.contains { $0.contains("unverified model policy") })
        XCTAssertEqual(largeCount.json["estimated"], true)
        #else
        throw XCTSkip("ImageIO dimension checks require macOS")
        #endif
    }

    func testUnknownRemoteImageDimensionsRemainExplicitlyUncertain() throws {
        let profile = try pinnedProfile()
        let body: JSON = ["model": JSON(profile.model), "input": [["type": "message", "role": "user", "content": [["type": "input_image", "image_url": "https://fixture.invalid/image.png"]]]]]
        var counter = RequestContextCounter()
        let count = try counter.count(request: body, profile: profile)
        XCTAssertGreaterThanOrEqual(count.tokens, 16384)
        XCTAssertTrue(count.warnings.contains { $0.contains("dimensions are unavailable") && $0.contains("not a capacity guarantee") })
        XCTAssertEqual(count.json["estimated"], true)
    }

    private func pinnedProfile() throws -> Profile {
        var raw = try fixtureProfile().raw
        raw["modelId"] = "fixed-alias"
        raw["routing"] = ["replayPolicy": "pinned", "expectedModel": "gpt-4o-mini", "replayContract": "Synthetic fixed route; compatible native replay"]
        return try Profile(raw)
    }
    private func reportedReply(input: Int, output: Int = 5) -> ModelReply {
        var reply = answer("Short answer")
        reply.usage = ["input": JSON(input), "inputIncludingCache": JSON(input), "output": JSON(output)]
        reply.message.providerIdentity = ["status": "reported", "effectiveModel": "openai/gpt-4o-mini"]
        return reply
    }
    private func request(_ profile: Profile, messages: [ChatMessage] = [], instructions: String = "Instructions", tools: [ToolDefinition] = []) throws -> JSON {
        try ProviderClient.requestBody(profile: profile, messages: messages, instructions: instructions, tools: tools, sessionID: "context-fixture")
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
