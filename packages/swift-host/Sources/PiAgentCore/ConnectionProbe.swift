import Foundation

/// A single provider request, deliberately independent of session resources,
/// tool executors, history, skills and automatic compaction.
public enum ConnectionProbe {
    static let prompt = "Reply with OK to confirm this connection."
    static let instructions = "This is a connection test. Reply briefly with OK."

    public static func run(profile original: Profile, apiKey: String, sessionID: String,
                           client: any ModelClient, timeout: Duration = .seconds(25)) async throws -> JSON {
        guard !apiKey.isEmpty, !apiKey.contains(where: { $0.isNewline }) else {
            throw AgentError("connection_test_key", "Enter a valid API key before testing this connection.")
        }
        var raw = original.raw
        raw["maxOutputTokens"] = JSON(min(256, original.maxOutput))
        raw["thinkingLevel"] = "default"
        raw["reasoning"] = false
        // A probe always has a finite output budget, including when an imported
        // compatibility setting omitted that field on ordinary requests.
        raw["compat"]["supportsMaxOutputTokens"] = true
        let profile = try Profile(raw)
        do {
            let reply = try await withThrowingTaskGroup(of: ModelReply.self) { group in
                group.addTask {
                    try await client.complete(profile: profile, apiKey: apiKey,
                        messages: [ChatMessage(role: "user", content: [textBlock(prompt)])],
                        instructions: instructions, tools: [], sessionID: sessionID,
                        turnID: UUID().uuidString, purpose: "connection-test", onDelta: { _ in })
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw AgentError("connection_test_timeout", "The gateway did not finish the small connection test in time. Check its availability or try a faster model, then test again.")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            try Task.checkCancellation()
            guard !reply.truncated else {
                throw AgentError("connection_test_truncated", "The model reached the connection test's output limit. Choose a model that can return a short answer, then test again.")
            }
            guard reply.calls.isEmpty, !reply.message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentError("connection_test_empty", "The gateway returned no usable answer. Check that this model supports Responses text generation, then test again.")
            }
            return ["verified": true, "model": JSON(profile.model), "attemptId": reply.message.requestAttemptIDs?.first.map { JSON($0) } ?? .null]
        } catch is CancellationError { throw CancellationError() }
        catch let error as AgentError {
            if error.code.hasPrefix("connection_test_") { throw error }
            if error.code == "provider_http" {
                let detail: String
                if error.message.contains("HTTP 401") || error.message.contains("HTTP 403") { detail = "The gateway rejected authentication. Check the API key and this model's access permissions." }
                else if error.message.contains("HTTP 404") { detail = "The gateway could not find the Responses endpoint or model. Check the URL and model alias." }
                else if error.message.contains("HTTP 429") { detail = "The gateway rate limit or quota was reached. Check its quota and retry when available." }
                else if error.message.range(of: "HTTP 3[0-9][0-9]", options: .regularExpression) != nil { detail = "The gateway redirected the request. Use its final Responses URL; redirects are not followed." }
                else { detail = "The gateway rejected the test request. Check its Responses endpoint, model alias and request settings." }
                throw AgentError("connection_test_http", detail + " Details are available in Requests; the test was not retried.")
            }
            throw AgentError("connection_test_failed", "The gateway did not complete a valid Responses answer. Check its URL and model support, then retry. Details are available in Requests.")
        } catch {
            throw AgentError("connection_test_failed", "The connection test failed. Check that the gateway is reachable, then retry. Details are available in Requests.")
        }
    }
}
