import Foundation

/// Provider call IDs are opaque wire values, not local session or file names.
/// LiteLLM can append Gemini's thought signature to an ID; keep every byte so
/// tool results and subsequent requests return the same signature. This is an
/// application resource bound, not a provider's advertised maximum: a
/// signature follows the amount of thinking, and one measured in the field
/// made a 278,100-byte ID.
public enum ProviderToolCallID {
    public static let maximumUTF8Bytes = 1024 * 1024

    public static func isValid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumUTF8Bytes
            && !value.utf8.contains { $0 < 32 || $0 == 127 }
    }
}
