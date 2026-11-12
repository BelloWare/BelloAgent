import XCTest
@testable import PiAgentCore

/// The provider texts that mean "the reasoning sent back from earlier replies
/// was refused", as a LiteLLM 1.108.0 gateway passes them on, and the ones
/// that do not. Every body below is verbatim from the live and stand-in
/// probes of 2026-11-12 (`docs/Reasoning-Replay.md`), item ids shortened.
final class ReasoningRejectionTests: HelperTestCase {
    private func http(_ body: String, status: Int = 400) throws -> ProviderFailure {
        ProviderFailure.classify(body: Data(body.utf8), status: status)
    }
    private func event(_ data: String) throws -> JSON { try JSON.parse(Data(data.utf8)) }
    private let help = #"\n\n This error occurs when load balancing Responses API across deployments with different API keys.\n   Encrypted content is tied to the organization that created it and cannot be decrypted by other organizations.\n\n   Solution: Enable 'encrypted_content_affinity' to route follow-up requests to the correct deployment:\n\n   router_settings:\n     enable_pre_call_checks: true\n     optional_pre_call_checks:\n       - encrypted_content_affinity\n\n   Learn more: https://docs.litellm.ai/docs/response_api#encrypted-content-affinity-multi-region-load-balancing"#

    // MARK: HTTP 400 bodies

    func testAnOpenAIRouteNamesTheOrganizationAndCarriesLiteLLMsHelp() throws {
        for provider in ["OpenAIException", "AzureException"] {
            let body = #"{"error":{"message":"litellm.BadRequestError: "# + provider + #" - {\"error\": {\"message\": \"The encrypted content for item rs_0d09 could not be verified. Reason: Encrypted content organization_id did not match the target organization.\", \"type\": \"invalid_request_error\", \"param\": null, \"code\": \"invalid_encrypted_content\"}}"# + help + #"","type":"invalid_request_error","param":null,"code":"400"}}"#
            XCTAssertEqual(try http(body), .reasoningRejected, provider)
            let found = try XCTUnwrap(ReasoningRejection.match(body: Data(body.utf8)), provider)
            XCTAssertEqual(found.rule, .organization); XCTAssertTrue(found.routeChanged); XCTAssertTrue(found.affinity)
            XCTAssertEqual(found.sentence, "The encrypted content for item rs_0d09 could not be verified. Reason: Encrypted content organization_id did not match the target organization.")
        }
    }

    func testOpenRoutersTwiceEscapedProviderBodyIsRead() throws {
        let body = #"{"error":{"message":"litellm.BadRequestError: OpenrouterException - {\"error\":{\"message\":\"Provider returned error\",\"code\":400,\"metadata\":{\"raw\":\"{\\n  \\\"error\\\": {\\n    \\\"message\\\": \\\"The encrypted content for item rs_0ec7 could not be verified. Reason: Encrypted content could not be decrypted or parsed.\\\",\\n    \\\"type\\\": \\\"invalid_request_error\\\",\\n    \\\"param\\\": null,\\n    \\\"code\\\": \\\"invalid_encrypted_content\\\"\\n  }\\n}\",\"provider_name\":\"OpenAI\",\"is_byok\":false,\"provider_error_code\":\"invalid_encrypted_content\"}},\"user_id\":\"user_[REDACTED]\"}","type":"invalid_request_error","param":null,"code":"400"}}"#
        XCTAssertEqual(try http(body), .reasoningRejected)
        let found = try XCTUnwrap(ReasoningRejection.match(body: Data(body.utf8)))
        XCTAssertEqual(found.rule, .undecryptable); XCTAssertFalse(found.routeChanged)
        XCTAssertEqual(found.sentence, "The encrypted content for item rs_0ec7 could not be verified. Reason: Encrypted content could not be decrypted or parsed.")
    }

    func testAGeminiRouteRefusesAThoughtSignature() throws {
        for (text, sentence) in [("Corrupted thought signature.", "Corrupted thought signature."), ("Invalid thought signature.", "Invalid thought signature.")] {
            let body = #"{"error":{"message":"litellm.BadRequestError: GeminiException BadRequestError - {\"error\": {\"code\": 400, \"message\": \""# + text + #"\", \"status\": \"INVALID_ARGUMENT\"}}","type":"invalid_request_error","param":null,"code":"400"}}"#
            XCTAssertEqual(try http(body), .reasoningRejected, text)
            let found = try XCTUnwrap(ReasoningRejection.match(body: Data(body.utf8)), text)
            XCTAssertEqual(found.rule, .thoughtSignature); XCTAssertEqual(found.sentence, sentence); XCTAssertFalse(found.routeChanged)
        }
    }

    func testAnAnthropicRouteRefusesAThinkingSignatureInBothSpellings() throws {
        let plain = #"{"error":{"message":"litellm.BadRequestError: AnthropicException - {\"type\": \"error\", \"error\": {\"type\": \"invalid_request_error\", \"message\": \"messages.1.content.0: Invalid `signature` in `thinking` block\"}, \"request_id\": \"req_011\"}","type":"invalid_request_error","param":null,"code":"400"}}"#
        // A streamed request's text carries Python's bytes spelling.
        let bytes = #"{"error":{"message":"litellm.BadRequestError: AnthropicException - b'{\"type\": \"error\", \"error\": {\"type\": \"invalid_request_error\", \"message\": \"messages.1.content.0: Invalid `signature` in `thinking` block\"}, \"request_id\": \"req_011\"}'","type":"invalid_request_error","param":null,"code":"400"}}"#
        for body in [plain, bytes] {
            XCTAssertEqual(try http(body), .reasoningRejected)
            let found = try XCTUnwrap(ReasoningRejection.match(body: Data(body.utf8)))
            XCTAssertEqual(found.rule, .thinkingSignature)
            XCTAssertEqual(found.sentence, "messages.1.content.0: Invalid `signature` in `thinking` block")
        }
        XCTAssertEqual(ReasoningRejection.match(message: "messages.3.content.0: Invalid 'signature' in 'thinking' block")?.rule, .thinkingSignature, "Other quoting")
    }

    func testABodyCutOffByTheSizeLimitIsStillRead() throws {
        // 64 KiB of a body is kept: one that does not parse is read as text.
        let cut = #"{"error":{"message":"litellm.BadRequestError: OpenAIException - {\"error\": {\"message\": \"The encrypted content for item rs_1 could not be verified. Reason: Encrypted content could not be decrypted or parsed.\", \"type\": \"invalid_requ"#
        XCTAssertEqual(try http(cut), .reasoningRejected)
        XCTAssertEqual(ReasoningRejection.match(body: Data(cut.utf8))?.rule, .undecryptable)
    }

    // MARK: HTTP 200, then a failure event

    func testAStreamThatFailsAfterHTTP200IsRead() throws {
        // LiteLLM's Gemini bridge, a streamed request.
        let gemini = try event(#"{"type":"response.failed","response":{"id":"resp_a762","created_at":1794493905,"error":{"code":"invalid_request_error","message":"litellm.BadRequestError: Vertex_ai_betaException BadRequestError - b'{\"error\": {\"code\": 400, \"message\": \"Corrupted thought signature.\", \"status\": \"INVALID_ARGUMENT\"}}'"},"object":"response","output":[],"status":"failed"},"sequence_number":0}"#)
        XCTAssertEqual(ProviderFailure.classify(gemini), .reasoningRejected)
        XCTAssertEqual(ReasoningRejection.match(gemini)?.rule, .thoughtSignature)
        XCTAssertEqual(ProviderAccumulator.failure(gemini).failure, .reasoningRejected, "As the stream loop classifies it")
        // A native route whose upstream fails inside the stream: the provider's code survives.
        let openai = try event(#"{"type":"response.failed","response":{"id":"resp_1","created_at":1,"error":{"code":"invalid_encrypted_content","message":"The encrypted content for item rs_2 could not be verified. Reason: Encrypted content organization_id did not match the target organization."},"model":"gpt-6-luna","object":"response","output":[],"status":"failed"},"sequence_number":1}"#)
        XCTAssertEqual(ProviderFailure.classify(openai), .reasoningRejected)
        XCTAssertEqual(ReasoningRejection.match(openai)?.rule, .organization)
        // The code alone, whatever the message says.
        let coded = try event(#"{"type":"response.failed","response":{"error":{"code":"invalid_encrypted_content","message":"Bad request."},"status":"failed"}}"#)
        XCTAssertEqual(ReasoningRejection.match(coded)?.rule, .encryptedContent)
        XCTAssertEqual(ReasoningRejection.match(coded)?.sentence, "Bad request.")
        // An `error` event, and LiteLLM's bare `{"error":…}` frame.
        let typed = try event(#"{"type":"error","code":"400","message":"Invalid thought signature."}"#)
        XCTAssertEqual(ProviderFailure.classify(typed), .reasoningRejected)
        let bare = try event(#"{"error":{"message":"messages.1.content.0: Invalid `signature` in `thinking` block","code":"400"}}"#)
        XCTAssertEqual(ProviderFailure.classify(bare), .reasoningRejected)
    }

    // MARK: What is not a rejection of reasoning

    func testOtherFailuresThatMentionReasoningOrIdsAreNotRejections() throws {
        let others = [
            // A2
            "Function call is missing a thought_signature in functionCall parts.",
            // A3
            #"Invalid value at 'contents[1].parts[0].thought_signature' (TYPE_BYTES), Base64 decoding failed for "not-a-real-blob""#,
            // A5: the trap of the continue-without path.
            "Item 'fc_1' of type 'function_call' was provided without its required 'reasoning' item: 'rs_1'.",
            // Unrelated 400s.
            "litellm.UnsupportedParamsError: gemini does not support parameters: ['prompt_cache_key'], for model=gemini-3.5-flash-lite.",
            "This model's maximum context length is 128000 tokens.",
            "Your organization could not be verified. Check the API key.",
            "Invalid schema for function 'read': signature of the thinking tool is not an object.",
        ]
        for text in others {
            XCTAssertNil(ReasoningRejection.match(message: text), text)
            let body = String(decoding: try JSONSerialization.data(withJSONObject: ["error": ["message": "litellm.BadRequestError: OpenAIException - " + text, "type": "invalid_request_error", "code": "400"]]), as: UTF8.self)
            XCTAssertEqual(try http(body), .other, text)
        }
    }

    /// OpenAI's refusal of a call id over 64 characters is one of reasoning
    /// when the id carried a Gemini thought signature, which the session
    /// reads from the request it sent (`AgentSession.rejectedReasoning`).
    func testACallIDRefusedForItsLengthIsRecognised() throws {
        let text = "Invalid 'input[2].call_id': string too long. Expected a string with maximum length 64, but got a string with length 146 instead."
        let found = try XCTUnwrap(ReasoningRejection.match(message: "litellm.BadRequestError: OpenAIException - {\"error\": {\"message\": \"" + text + "\", \"type\": \"invalid_request_error\", \"param\": \"input[2].call_id\", \"code\": \"string_above_max_length\"}}"))
        XCTAssertEqual(found.rule, .signedCallID); XCTAssertEqual(found.sentence, text); XCTAssertFalse(found.routeChanged)
        XCTAssertNil(ReasoningRejection.match(message: "Invalid 'input[2].content': string too long. Expected a string with maximum length 1048576."))
    }

    func testOnlyARefusedRequestCounts() throws {
        let text = #"{"error":{"message":"Corrupted thought signature.","code":"400"}}"#
        XCTAssertEqual(try http(text, status: 400), .reasoningRejected)
        // A4: Gemini 2.5 answers a damaged signature with an internal error, which nothing tells from an outage.
        XCTAssertEqual(try http(#"{"error":{"message":"litellm.APIError: APIError: OpenrouterException - An internal error has occurred. Please retry or report in https://developers.generativeai.google/guide/troubleshooting","type":"internal_server_error","code":"502"}}"#, status: 502), .other)
        XCTAssertEqual(try http(text, status: 500), .other, "The words in a server error are not a refusal")
        XCTAssertEqual(try http(text, status: 401), .authentication); XCTAssertEqual(try http(text, status: 429), .rateLimited)
        // An overflow keeps its own kind.
        XCTAssertEqual(try http(#"{"error":{"message":"too long","code":"context_length_exceeded"}}"#), .inputContextExceeded)
    }

    func testLiteLLMsHelpAloneCountsAndDoesNotSayTheRouteChanged() throws {
        // The help is appended to a deliberately damaged blob's refusal too.
        let found = try XCTUnwrap(ReasoningRejection.match(message: "litellm.BadRequestError: OpenAIException - Bad request." + help.replacingOccurrences(of: "\\n", with: "\n")))
        XCTAssertEqual(found.rule, .affinity); XCTAssertFalse(found.routeChanged); XCTAssertTrue(found.affinity)
        XCTAssertEqual(found.sentence, "This error occurs when load balancing Responses API across deployments with different API keys.")
        let damaged = try XCTUnwrap(ReasoningRejection.match(message: "The encrypted content for item rs_1 could not be verified. Reason: Encrypted content could not be decrypted or parsed." + help))
        XCTAssertEqual(damaged.rule, .undecryptable); XCTAssertFalse(damaged.routeChanged); XCTAssertTrue(damaged.affinity)
    }

    func testTheSentenceIsBoundedAndCarriesNoAccountId() throws {
        let long = "The encrypted content for item rs_" + String(repeating: "a", count: 2_000) + " could not be verified. Reason: Encrypted content could not be decrypted or parsed."
        let found = try XCTUnwrap(ReasoningRejection.match(message: long))
        XCTAssertLessThanOrEqual(found.sentence.count, 300)
        let openrouter = #"OpenrouterException - {"error":{"message":"Provider returned error","metadata":{"raw":"Corrupted thought signature."}},"user_id":"user_2abcDEF"}"#
        XCTAssertEqual(ReasoningRejection.match(message: openrouter)?.sentence, "Corrupted thought signature.")
    }
}
