// Stubs for the two value types the extracted declarations read
// (TranscriptMessage.swift 4-18 and 19-37 at 6319e368, fields used only).
import Foundation

struct ToolView: Codable, Sendable, Equatable, Identifiable {
    var id: String; var name: String; var state: String; var input: String; var output: String; var durationMs: Double?; var truncated: Bool
    var path: String? = nil; var added: Int? = nil; var removed: Int? = nil
    var line: Int? = nil; var lastLine: Int? = nil
    var inputTruncated: Bool? = nil
    var inputBytes: Int? = nil
}
struct TranscriptMessage: Codable, Sendable, Identifiable, Equatable {
    var id: String; var role: String; var text: String
    var tools: [ToolView]? = nil
    var truncated: Bool? = nil
    var toolCallCount: Int? = nil
}
