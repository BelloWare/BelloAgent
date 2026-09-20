import Foundation

public enum ProviderFailure: String, Sendable {
    case inputContextExceeded, inputPlusOutputContextExceeded, outputLimitInvalid
    case requestBodyTooLarge, rateLimited, authentication, transientTransport, other
    public var contextRejection: Bool { self == .inputContextExceeded || self == .inputPlusOutputContextExceeded }
    static func classify(_ value: JSON, status: Int? = nil) -> ProviderFailure {
        if status == 401 || status == 403 { return .authentication }
        if status == 429 { return .rateLimited }
        if status == 413 { return .requestBodyTooLarge }
        let detail=value["response"]["error"].isNull ? value["error"] : value["response"]["error"]
        let codes=[detail["code"].text, detail["type"].text, value["code"].text].compactMap { $0?.lowercased() }
        if codes.contains(where: { ["invalid_max_output_tokens","max_output_tokens_exceeded","invalid_max_tokens"].contains($0) }) { return .outputLimitInvalid }
        if codes.contains("input_plus_output_context_exceeded") { return .inputPlusOutputContextExceeded }
        if codes.contains(where: { ["context_length_exceeded","context_window_exceeded","input_too_long","contextwindowexceedederror"].contains($0) }) { return .inputContextExceeded }
        return .other
    }
}
