// Shims for the types TranscriptMarkdown.swift (0.1.122, 6319e368) refers to.
import AppKit

// MarkdownTextDocument.swift lines 45-60, without the NSFont accessor.
struct MarkdownFontSpec: Hashable, Sendable {
    var size: CGFloat
    var semibold = false
    var monospaced = false
    var serif = false
    var italic = false
}
enum MarkdownFontAttribute: AttributedStringKey {
    typealias Value = MarkdownFontSpec
    static let name = "PiMarkdownFont"
}
enum MarkdownInlineCodeAttribute: AttributedStringKey {
    typealias Value = Bool
    static let name = "PiMarkdownInlineCode"
}
// Only `parse` is exercised; the streaming preview is not.
enum StreamingMarkdownState {
    static func preview(_ source: String, style: MarkdownStyle) -> [(offset: Int, block: MarkdownBlock)] { [] }
}
