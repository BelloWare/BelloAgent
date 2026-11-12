import Foundation

public enum ProviderFailure: String, Sendable {
    case inputContextExceeded, inputPlusOutputContextExceeded, outputLimitInvalid
    case requestBodyTooLarge, rateLimited, authentication, transientTransport, other
    /// The provider refused reasoning replayed from earlier replies (`ReasoningRejection`).
    case reasoningRejected
    public var contextRejection: Bool { self == .inputContextExceeded || self == .inputPlusOutputContextExceeded }
    /// An HTTP error body. At most 64 KiB of it is kept, so one that does
    /// not parse is still read as text for a refusal of reasoning.
    static func classify(body: Data, status: Int) -> ProviderFailure {
        let kind = classify((try? JSON.parse(body)) ?? .null, status: status)
        return kind == .other && status == 400 && ReasoningRejection.match(body: body) != nil ? .reasoningRejected : kind
    }
    /// `status` is nil for a failure frame of a stream that began with HTTP 200.
    static func classify(_ value: JSON, status: Int? = nil) -> ProviderFailure {
        if status == 401 || status == 403 { return .authentication }
        if status == 429 { return .rateLimited }
        if status == 413 { return .requestBodyTooLarge }
        // A refusal is a 400 or a failed response; the same words in a
        // server error are not one (Gemini 2.5 answers a damaged signature
        // with an internal error that nothing tells from an outage).
        if status == nil || status == 400, ReasoningRejection.match(value) != nil { return .reasoningRejected }
        let detail=value["response"]["error"].isNull ? value["error"] : value["response"]["error"]
        let codes=[detail["code"].text, detail["type"].text, value["code"].text].compactMap { $0?.lowercased() }
        if codes.contains(where: { ["invalid_max_output_tokens","max_output_tokens_exceeded","invalid_max_tokens"].contains($0) }) { return .outputLimitInvalid }
        if codes.contains("input_plus_output_context_exceeded") { return .inputPlusOutputContextExceeded }
        if codes.contains(where: { ["context_length_exceeded","context_window_exceeded","input_too_long","contextwindowexceedederror"].contains($0) }) { return .inputContextExceeded }
        return .other
    }
}
