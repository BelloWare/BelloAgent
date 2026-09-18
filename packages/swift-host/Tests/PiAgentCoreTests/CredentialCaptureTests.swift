import Foundation
import XCTest
@testable import PiAgentCore

private actor CredentialPackets {
    var values: [JSON] = []
    func append(_ packet: JSON) -> Bool { values.append(packet); return true }
}

final class CredentialCaptureTests: XCTestCase {
    func testHeaderCaptureKeepsOrdinaryResponseFieldsAndMasksShortTokensCookiesAndCustomSecrets() {
        let headers = ["Authorization": "Bearer small", "Cookie": "session=private-cookie-value", "X-Custom-Credential": "custom-private-key", "X-Session-Id": "session-123"]
        let privacy = CaptureCredentials(headers: headers, configuredNames: ["X-Custom-Credential"])
        let request = privacy.requestHeaders(headers)
        XCTAssertEqual(request["authorization"].text, "Bearer ********")
        XCTAssertEqual(request["cookie"].text, "********")
        XCTAssertEqual(request["x-custom-credential"].text, "********-key")
        XCTAssertEqual(request["x-session-id"].text, "session-123")
        let ordinary = ["date": "Wed, 16 Sep 2026 01:23:24 GMT", "content-length": "5105",
                        "x-provider-build": "v1.99.0", "x-litellm-cache-key": "cache-fixture-key", "x-litellm-key-spend": "12.345",
                        "x-litellm-response-cost-reasoning": "0.0011385", "cache-control": "no-cache"]
        var response = ordinary
        response["Set-Cookie"] = "new-session=fresh-secret"
        response["Authorization"] = "Bearer fresh-private-key"
        response["x-custom-credential"] = "another-private-value"
        response["x-echo"] = "echo: custom-private-key"
        let captured = privacy.responseHeaders(response, metadataHeaders: [])
        for (name, value) in ordinary { XCTAssertEqual(captured[name].text, value) }
        for name in ["set-cookie", "authorization", "x-custom-credential", "x-echo"] { XCTAssertEqual(captured[name].text, "********") }
        for secret in ["small", "private-cookie-value", "custom-private-key", "fresh-secret", "fresh-private-key", "another-private-value"] {
            XCTAssertFalse(request.encoded().contains(secret)); XCTAssertFalse(captured.encoded().contains(secret))
        }
        let excessive = privacy.responseHeaders(["x-debug": String(repeating: "x", count: 16_385)], metadataHeaders: [])
        XCTAssertEqual(excessive["x-debug"].text, "[omitted: header exceeds capture safety limits]")
    }
    func testMaskingNeverRevealsShortTokensAndPreservesSchemeWithoutChangingWireHeaders() {
        for size in 0...16 {
            let token = String(repeating: "a", count: size)
            XCTAssertEqual(CaptureCredentials.masked(token), size < 12 ? "********" : "********aaaa")
        }
        let headers = ["Authorization": "Token original-private-token"]
        let privacy = CaptureCredentials(headers: headers, configuredNames: [])
        XCTAssertEqual(privacy.requestHeaders(headers)["authorization"].text, "Token ********oken")
        XCTAssertEqual(headers["Authorization"], "Token original-private-token")
        XCTAssertEqual(privacy.requestBody(Data("original-private-token".utf8)).bytes,
                       Data(CaptureCredentials.fingerprint("original-private-token").utf8))
    }
    func testCredentialsAreMaskedAtHeaderBoundaryAndSafeHeadersRemainReadable() {
        let headers = ["aUtHoRiZaTiOn": "Bearer fixture-secret", "x-api-key": "fixture-secret", "X-Organization-Key": "custom-secret", "Content-Type": "application/json", "Accept": "custom-secret"]
        let privacy = CaptureCredentials(headers: headers, configuredNames: ["X-Organization-Key", "Accept"])
        let retained = privacy.requestHeaders(headers)
        XCTAssertEqual(retained["authorization"].text, "Bearer ********cret")
        XCTAssertEqual(retained["x-api-key"].text, "********cret")
        XCTAssertEqual(retained["x-organization-key"].text, "********cret")
        XCTAssertEqual(retained["accept"].text, "********cret")
        XCTAssertEqual(retained["content-type"].text, "application/json")
        XCTAssertFalse(retained.encoded().contains("fixture-secret")); XCTAssertFalse(retained.encoded().contains("custom-secret"))
        let response = privacy.responseHeaders(["x-request-id":"echo-fixture-secret", "x-model":"custom-secret", "set-cookie":"unknown-secret", "content-type":"text/event-stream"], metadataHeaders: ["x-model"])
        XCTAssertEqual(response["x-request-id"].text,"********"); XCTAssertEqual(response["x-model"].text,"********")
        XCTAssertEqual(response["set-cookie"].text,"********"); XCTAssertEqual(response["content-type"].text,"text/event-stream")
    }
    func testByteReplacementPreservesFormattingUnicodeAndEscapedCredentials() throws {
        let secret = "secret-\"quoted\\path/🙂", other = "custom-token"
        let privacy = CaptureCredentials(headers: ["Authorization":"Bearer " + secret,"x-custom":other], configuredNames: ["x-custom"])
        let quoted = JSON(secret).encoded()
        let original = Data(("{ \"p\" : " + quoted + ",\n\"q\":\"custom-token\",\"z\":\"中文\" }\n").utf8)
        let retained = privacy.requestBody(original)
        let expected = Data(("{ \"p\" : \"" + CaptureCredentials.fingerprint(secret) + "\",\n\"q\":\"" + CaptureCredentials.fingerprint(other) + "\",\"z\":\"中文\" }\n").utf8)
        XCTAssertEqual(retained.bytes,expected); XCTAssertEqual(retained.replacements,2); XCTAssertFalse(retained.omitted)
        let ordinary = Data("{ \"unrelated\" : \"中文🙂\" }".utf8)
        XCTAssertEqual(privacy.requestBody(ordinary).bytes,ordinary)
    }
    func testReplacementFloodIsExplicitlyOmittedWithoutLeakingBody() async throws {
        let privacy = CaptureCredentials(headers:["Authorization":"Bearer x"],configuredNames:[])
        let result = privacy.requestBody(Data(repeating:120,count:65_537))
        XCTAssertTrue(result.omitted); XCTAssertTrue(result.bytes.isEmpty)
        let packets = CredentialPackets()
        let traces = TraceStore { await packets.append($0) }
        _ = try await traces.command("debug.mode",session:"s",params:["mode":"persist"])
        let profile = try Profile(["id":"p","api":"openai-responses","providerId":"litellm","modelId":"alias","baseUrl":"http://127.0.0.1","contextWindow":100000,"maxOutputTokens":4096])
        let id = await traces.begin(session:"s",turn:"t",profile:profile,purpose:"turn",body:Data(repeating:120,count:65_537),headers:["Authorization":"Bearer x"])
        let body = try await traces.command("debug.body",session:"s",params:["attemptId":JSON(id),"body":"request"])
        XCTAssertEqual(body["state"].text,"credential-omitted"); XCTAssertEqual(body["captureBytes"].int,0); XCTAssertEqual(body["bytes"].text,"")
        XCTAssertTrue(body["transformations"].list.first?.text?.contains("No request-body bytes were retained") == true)
        let retained = await packets.values
        XCTAssertFalse(retained.contains { $0["type"].text == "bytes" })
    }
    func testDurablePacketsAndMetadataDistinguishHashedRequestFromOriginalResponse() async throws {
        let key = "private-fixture-key", packets = CredentialPackets()
        let traces = TraceStore { await packets.append($0) }
        _ = try await traces.command("debug.mode",session:"s",params:["mode":"persist"])
        let profile = try Profile(["id":"p","api":"openai-responses","providerId":"litellm","modelId":"alias","baseUrl":JSON("http://127.0.0.1/" + key),"contextWindow":100000,"maxOutputTokens":4096,"routing":["replayPolicy":"portable","reference":"fixture-v1","modelHeader":"x-actual-model"]])
        let original = Data(("{\"prompt\":\"" + key + "\"}").utf8)
        let id = await traces.begin(session:"s",turn:"t",profile:profile,purpose:"turn",body:original,headers:["Authorization":"Bearer " + key])
        await traces.head(id,status:200,headers:["x-request-id":key,"x-actual-model":key])
        await traces.reported(id,value:["model":JSON(key)],streaming:false)
        // Ordinary response bytes remain raw. Only known credential echoes are
        // an explicit, length-preserving capture exception.
        let response = Data("data: {\"ok\":true}\n\n".utf8)
        await traces.append(id,data:response)
        await traces.transport(id,observation:["transportOutcome":"eof"])
        await traces.finish(id,outcome:"completed",modelOutcome:"completed")
        let metadata = try await traces.command("debug.attempt",session:"s",params:["attemptId":JSON(id)])
        XCTAssertFalse(metadata.encoded().contains(key)); XCTAssertEqual(metadata["request"]["state"].text,"credential-hashed")
        XCTAssertEqual(metadata["request"]["observedBytes"].int,original.count); XCTAssertEqual(metadata["request"]["credentialRedactions"].int,1)
        XCTAssertEqual(metadata["request"]["byteExact"].flag,false); XCTAssertEqual(metadata["identity"]["status"].text,"incomplete")
        let all = await packets.values
        let requestBytes = all.filter { $0["type"].text == "bytes" && $0["body"].text == "request" }.reduce(into:Data()) { $0.append(Data(base64Encoded:$1["bytes"].text!)!) }
        XCTAssertEqual(String(decoding:requestBytes,as:UTF8.self),"{\"prompt\":\"" + CaptureCredentials.fingerprint(key) + "\"}")
        XCTAssertEqual(metadata["requestHash"]["sha256"].text,sha256(requestBytes))
        for packet in all where packet["type"].text != "bytes" { XCTAssertFalse(packet.encoded().contains(key)) }
        let capturedResponse = try await traces.command("debug.body",session:"s",params:["attemptId":JSON(id),"body":"response"])
        XCTAssertEqual(Data(base64Encoded:capturedResponse["bytes"].text!),response)
        XCTAssertEqual(capturedResponse["byteExact"].flag, true)
    }

    func testResponseMaskingAtEveryByteBoundaryKeepsUnicodeFormattingAndEscapedKeys() throws {
        let secret = "secret-\"quoted\\path/🙂", other = "private-api-key"
        let credentials = CaptureCredentials(headers: ["Authorization": "Bearer " + secret, "x-key": other], configuredNames: [])
        let escaped = String(JSON(secret).encoded().dropFirst().dropLast()).replacingOccurrences(of: "/", with: "\\/")
        let before = "data: {\"text\":\"中文🙂 ", middle = "\",\"other\":\"", after = "\"}\r\n\r\n"
        let original = Data((before + escaped + middle + other + after).utf8)
        let expected = Data((before + String(repeating: "*", count: escaped.utf8.count) + middle + String(repeating: "*", count: other.utf8.count) + after).utf8)
        for split in 0...original.count {
            var masker = CaptureCredentials.ResponseMasker(credentials)
            var captured = masker.feed(Data(original.prefix(split)))
            captured.append(masker.feed(Data(original.dropFirst(split))))
            captured.append(masker.feed(Data(), final: true))
            XCTAssertEqual(captured, expected, "split \(split)")
            XCTAssertEqual(masker.replacements, 2)
            XCTAssertEqual(captured.count, original.count, "SSE offsets must remain valid")
        }
        var oneByte = CaptureCredentials.ResponseMasker(credentials), captured = Data()
        for byte in original { captured.append(oneByte.feed(Data([byte]))) }
        captured.append(oneByte.feed(Data(), final: true))
        XCTAssertEqual(captured, expected)
    }

    func testResponseMaskingCoversOverlappingCredentialsAndLeavesUnrelatedBytesExact() {
        let credentials = CaptureCredentials(headers: ["Authorization": "Bearer ababa", "x-key": "bababa"], configuredNames: [])
        var masker = CaptureCredentials.ResponseMasker(credentials), captured = Data()
        for byte in Data("prefix ababababa suffix🙂".utf8) { captured.append(masker.feed(Data([byte]))) }
        captured.append(masker.feed(Data(), final: true))
        XCTAssertEqual(captured, Data("prefix ********* suffix🙂".utf8))
        XCTAssertEqual(masker.replacements, 5)
        var ordinary = CaptureCredentials.ResponseMasker(credentials)
        XCTAssertEqual(ordinary.feed(Data("中文 without credentials".utf8), final: true), Data("中文 without credentials".utf8))
        XCTAssertEqual(ordinary.replacements, 0)
    }

    func testCancelledAndFailedResponseCaptureFlushesMaskedTailWithContiguousDurableOffsets() async throws {
        for outcome in ["cancelled", "failed"] {
            let key = "private-fixture-key", packets = CredentialPackets()
            let traces = TraceStore { await packets.append($0) }
            _ = try await traces.command("debug.mode", session: "s", params: ["mode": "persist"])
            let id = await traces.begin(session: "s", turn: "t", profile: try fixtureProfile(), purpose: "turn", body: Data(), headers: ["Authorization": "Bearer " + key])
            let before = Data("{\"error\":\"Rejected ".utf8), response = before + Data(key.utf8)
            for byte in response { await traces.append(id, data: Data([byte])) }
            await traces.transport(id, observation: ["transportOutcome": JSON(outcome == "cancelled" ? "cancelled" : "error")])
            await traces.finish(id, outcome: outcome, modelOutcome: "interrupted")
            let captured = try await traces.command("debug.body", session: "s", params: ["attemptId": JSON(id), "body": "response"])
            let expected = before + Data(repeating: 42, count: key.utf8.count)
            XCTAssertEqual(Data(base64Encoded: captured["bytes"].text!), expected)
            XCTAssertEqual(captured["state"].text, "partial"); XCTAssertEqual(captured["byteExact"].flag, false)
            XCTAssertEqual(captured["credentialRedactions"].int, 1)
            XCTAssertEqual(captured["observedBytes"].int, response.count)
            XCTAssertEqual(captured["captureBytes"].int, response.count)
            let emitted = await packets.values
            var durable = Data()
            for packet in emitted where packet["type"].text == "bytes" && packet["body"].text == "response" {
                XCTAssertEqual(packet["offset"].int, durable.count)
                durable.append(Data(base64Encoded: packet["bytes"].text!)!)
                XCTAssertFalse(String(decoding: durable, as: UTF8.self).contains(key))
            }
            XCTAssertEqual(durable, expected)
            let finish = try XCTUnwrap(emitted.last { $0["type"].text == "finish" })
            XCTAssertEqual(finish["metadata"]["response"]["byteExact"].flag, false)
            XCTAssertFalse(finish["metadata"]["response"]["transformations"].list.isEmpty)
            let announcement = try XCTUnwrap(emitted.firstIndex { $0["type"].text == "metadata" && $0["metadata"]["response"]["byteExact"].flag == false })
            let maskedPacket = try XCTUnwrap(emitted.firstIndex { $0["body"].text == "response" && (Data(base64Encoded: $0["bytes"].text ?? "")?.contains(42) ?? false) })
            XCTAssertLessThan(announcement, maskedPacket, "The live inspector must learn the exception before receiving transformed bytes")
        }
    }

    func testBufferedLiveResponseIsPartialNotTruncatedAndEmptyEOFFinalizes() async throws {
        let traces = TraceStore(), profile = try fixtureProfile()
        let id = await traces.begin(session: "live", turn: "t", profile: profile, purpose: "turn", body: Data(), headers: ["Authorization": "Bearer private-fixture-key"])
        let original = Data(String(repeating: "ordinary text ", count: 10).utf8)
        await traces.append(id, data: original)
        let live = try await traces.command("debug.body", session: "live", params: ["attemptId": JSON(id), "body": "response"])
        XCTAssertEqual(live["state"].text, "partial")
        XCTAssertTrue(live["reason"].isNull, "A bounded masking suffix is not an 8 MiB overflow")
        await traces.transport(id, observation: ["transportOutcome": "eof"])
        await traces.finish(id, outcome: "completed", modelOutcome: "completed")
        let finished = try await traces.command("debug.body", session: "live", params: ["attemptId": JSON(id), "body": "response"])
        XCTAssertEqual(Data(base64Encoded: finished["bytes"].text!), original)
        XCTAssertEqual(finished["state"].text, "complete")
        let empty = await traces.begin(session: "empty", turn: "t", profile: profile, purpose: "turn", body: Data(), headers: ["Authorization": "Bearer private-fixture-key"])
        await traces.transport(empty, observation: ["transportOutcome": "eof"])
        await traces.finish(empty, outcome: "failed", modelOutcome: "interrupted")
        let emptyBody = try await traces.command("debug.body", session: "empty", params: ["attemptId": JSON(empty), "body": "response"])
        XCTAssertEqual(emptyBody["state"].text, "complete"); XCTAssertEqual(emptyBody["captureBytes"].int, 0)
    }
}
