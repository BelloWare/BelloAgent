// Stubs for the types MarkdownTextDocument.swift and TranscriptMarkdown.swift
// (0.1.122, 6319e368) refer to and this layout oracle does not exercise.
import AppKit

// StreamingMarkdownState.swift lines 3-20.
struct MarkdownBlockIdentity: Hashable {
    let generation: UInt64
    let sourceOffset: Int
    var component = 0
    var segment = 0
    var path: [MarkdownChildStep] = []
}
enum MarkdownChildStep: Hashable {
    case quoteChild(Int), listItem(Int), itemBlock(Int)
}
// Only `parse` is used; the streaming preview is not.
final class StreamingMarkdownState {
    static func preview(_ source: String, style: MarkdownStyle) -> [(offset: Int, block: MarkdownBlock)] { [] }
}
// TranscriptRows.swift lines 8-16.
enum TranscriptMetrics {
    static let proseWidth: CGFloat = 640
    static let pageWidth: CGFloat = 840
    static let pageTopInset: CGFloat = 12
    static let pageBottomInset: CGFloat = 13
    static let pageGutter: CGFloat = 48
}
// LargeMarkdownTable.swift lines 5-18.
enum MarkdownTablePresentation {
    static let previewRows = 20
    static let previewColumns = 8
    static func isLarge(header: [AttributedString], rows: [[AttributedString]]) -> Bool {
        rows.count > 40 || header.count > previewColumns || rows.contains { $0.count > previewColumns }
    }
    static func plain(_ row: [AttributedString]) -> [String] { row.map { String($0.characters) } }
}
