import Foundation
import SwiftUI

// Markdown for the transcript, parsed by Foundation's own CommonMark parser
// and laid out by us as native blocks: paragraphs, headings, lists, quotes,
// tables and code. No HTML is ever interpreted; images become a note; links
// are kept only when they are plain http(s) URLs without credentials.

/// One block of a rendered message, in reading order.
indirect enum MarkdownBlock: Equatable, Sendable {
    case paragraph(AttributedString)
    case heading(level: Int, AttributedString, plain: String)
    case code(language: String?, code: String)
    case list(ordered: Bool, start: Int, items: [[MarkdownBlock]])
    case quote([MarkdownBlock])
    case table(alignments: [MarkdownAlignment], header: [AttributedString], rows: [[AttributedString]])
}

enum MarkdownAlignment: Sendable, Equatable { case left, center, right }

/// How inline text is dressed: the base size, whether soft line breaks stay
/// as typed (user messages) or become spaces (prose), and the palette.
struct MarkdownStyle: Sendable {
    /// Names the style in the parse cache key.
    var id = "prose"
    var baseSize: CGFloat = 14.5
    var keepsSoftBreaks = false
    var textColor: Color = TranscriptPalette.text
    var codeBackground: Color = TranscriptPalette.panelStrong
    var linkColor: Color = TranscriptPalette.accent
    static let prose = MarkdownStyle()
    static let user = MarkdownStyle(id: "user", keepsSoftBreaks: true)
    static let reasoning = MarkdownStyle(id: "reasoning", baseSize: 13, textColor: TranscriptPalette.muted)
    static let summary = MarkdownStyle(id: "summary", baseSize: 13, textColor: TranscriptPalette.muted)
}

enum TranscriptMarkdown {
    /// Only plain web links survive: no scripts, files, data URLs, protocol-relative hosts or embedded credentials.
    static func safeURL(_ value: String) -> URL? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private final class CachedBlocks: Sendable {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }
    nonisolated(unsafe) private static let cache: NSCache<NSString, CachedBlocks> = {
        let cache = NSCache<NSString, CachedBlocks>(); cache.countLimit = 6_000; cache.totalCostLimit = 64 << 20; return cache
    }()
    /// The document as blocks, remembered per source and style so a settled row never parses twice.
    static func blocks(_ source: String, style: MarkdownStyle = .prose) -> [MarkdownBlock] {
        let key = (style.id + "\u{0}" + source) as NSString
        if let cached = cache.object(forKey: key) { return cached.blocks }
        let blocks = parse(source, style: style)
        cache.setObject(CachedBlocks(blocks), forKey: key, cost: source.utf8.count)
        return blocks
    }
    /// Blocks for a reply that is still arriving. The text is cut wherever a
    /// delta can no longer change how the parts parse; each settled part is
    /// remembered by the cache, so a delta parses only the tail still growing.
    static func streamingBlocks(_ source: String, style: MarkdownStyle = .prose) -> [MarkdownBlock] {
        let cuts = settledCuts(in: source)
        guard !cuts.isEmpty else { return parse(source, style: style) }
        var result: [MarkdownBlock] = []
        var start = source.startIndex
        for cut in cuts {
            result.append(contentsOf: blocks(String(source[start..<cut]), style: style))
            start = cut
        }
        result.append(contentsOf: parse(String(source[start...]), style: style))
        return result
    }
    /// Where the document splits into parts that parse the same alone as together:
    /// after a blank line outside any code fence, before a line that starts at the
    /// margin and is not a list item, so lists, fences, quotes and tables stay whole.
    static func settledCuts(in source: String) -> [String.Index] {
        var cuts: [String.Index] = []
        let utf8 = source.utf8
        var lineStart = utf8.startIndex
        var previousBlank = false
        var fence: (marker: UInt8, length: Int)? = nil
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }
        while lineStart < utf8.endIndex {
            var lineEnd = lineStart
            while lineEnd < utf8.endIndex, utf8[lineEnd] != 0x0a { lineEnd = utf8.index(after: lineEnd) }
            var index = lineStart, indent = 0
            while index < lineEnd, isSpace(utf8[index]) { indent += utf8[index] == 0x09 ? 4 : 1; index = utf8.index(after: index) }
            let blank = index == lineEnd
            if let open = fence {
                // The closing fence: the same marker, at least as long, nothing else on the line.
                var run = 0, cursor = index
                while cursor < lineEnd, utf8[cursor] == open.marker { run += 1; cursor = utf8.index(after: cursor) }
                while cursor < lineEnd, isSpace(utf8[cursor]) { cursor = utf8.index(after: cursor) }
                if indent <= 3, run >= open.length, cursor == lineEnd { fence = nil }
                previousBlank = false
            } else if blank {
                previousBlank = true
            } else {
                let first = utf8[index]
                var listItem = false
                if first == 0x2d || first == 0x2b || first == 0x2a {
                    let next = utf8.index(after: index); listItem = next == lineEnd || isSpace(utf8[next])
                } else if first >= 0x30, first <= 0x39 {
                    var cursor = index, digits = 0
                    while cursor < lineEnd, utf8[cursor] >= 0x30, utf8[cursor] <= 0x39, digits < 10 { digits += 1; cursor = utf8.index(after: cursor) }
                    if cursor < lineEnd, utf8[cursor] == 0x2e || utf8[cursor] == 0x29 {
                        let next = utf8.index(after: cursor); listItem = next == lineEnd || isSpace(utf8[next])
                    }
                }
                if previousBlank, indent == 0, !listItem, lineStart > utf8.startIndex { cuts.append(lineStart) }
                previousBlank = false
                if indent <= 3, first == 0x60 || first == 0x7e {
                    var run = 0, cursor = index
                    while cursor < lineEnd, utf8[cursor] == first { run += 1; cursor = utf8.index(after: cursor) }
                    // A backtick fence's info string may not contain a backtick.
                    var infoHasMarker = false
                    if first == 0x60 { var scan = cursor; while scan < lineEnd { if utf8[scan] == 0x60 { infoHasMarker = true; break }; scan = utf8.index(after: scan) } }
                    if run >= 3, !infoHasMarker { fence = (first, run) }
                }
            }
            lineStart = lineEnd < utf8.endIndex ? utf8.index(after: lineEnd) : lineEnd
        }
        return cuts
    }
    /// The document as blocks. A source the parser rejects outright renders as one plain paragraph.
    static func parse(_ source: String, style: MarkdownStyle = .prose) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: true, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return source.isEmpty ? [] : [.paragraph(inline(AttributedString(source), style: style, size: style.baseSize))]
        }
        var leaves: [Leaf] = []
        let characters = parsed.characters
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            // Foundation lists the innermost intent first; the builder walks from the outside in.
            var path = components.reversed().map { Component(kind: $0.kind, identity: $0.identity) }
            if path.isEmpty { path = [Component(kind: .paragraph, identity: -1)] }
            let plain = String(characters[run.range])
            // Inline text is dressed here, once: the path already says whether it sits in a heading, a table cell or code.
            var size = style.baseSize, heading = false, code = false
            for component in path {
                switch component.kind {
                case .header(let level): size = style.baseSize * (level == 1 ? 1.5 : level == 2 ? 1.3 : level == 3 ? 1.12 : 1); heading = true
                case .tableCell: size = style.baseSize * 0.9
                case .codeBlock: code = true
                default: break
                }
            }
            leaves.append(Leaf(path: path, fragment: code ? AttributedString() : inline(run, text: plain, style: style, size: size, heading: heading), plain: plain))
        }
        return build(leaves[...], depth: 0, style: style)
    }

    /// One level of a run's block nesting: what kind of block, and which one.
    private struct Component {
        let kind: PresentationIntent.Kind
        let identity: Int
    }
    private struct Leaf {
        var path: [Component]
        /// The run dressed for its block.
        var fragment: AttributedString
        var plain: String
        func component(at depth: Int) -> Component? { depth < path.count ? path[depth] : nil }
    }

    private static func build(_ leaves: ArraySlice<Leaf>, depth: Int, style: MarkdownStyle) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var index = leaves.startIndex
        while index < leaves.endIndex {
            guard let component = leaves[index].component(at: depth) else { index += 1; continue }
            var end = index
            while end < leaves.endIndex, let next = leaves[end].component(at: depth), next.identity == component.identity { end += 1 }
            let group = leaves[index..<end]
            switch component.kind {
            case .paragraph:
                blocks.append(.paragraph(merged(group)))
            case .header(let level):
                blocks.append(.heading(level: level, merged(group), plain: group.map(\.plain).joined()))
            case .codeBlock(let language):
                var code = group.map(\.plain).joined()
                if code.hasSuffix("\n") { code.removeLast() }
                let hint = language?.trimmingCharacters(in: .whitespaces).lowercased()
                blocks.append(.code(language: hint?.isEmpty == false ? hint : nil, code: code))
            case .unorderedList, .orderedList:
                var items: [[MarkdownBlock]] = []
                var start = 1
                var itemIndex = group.startIndex
                while itemIndex < group.endIndex {
                    guard let item = group[itemIndex].component(at: depth + 1) else { itemIndex += 1; continue }
                    var itemEnd = itemIndex
                    while itemEnd < group.endIndex, let next = group[itemEnd].component(at: depth + 1), next.identity == item.identity { itemEnd += 1 }
                    if case .listItem(let ordinal) = item.kind, items.isEmpty { start = ordinal }
                    items.append(build(group[itemIndex..<itemEnd], depth: depth + 2, style: style))
                    itemIndex = itemEnd
                }
                if case .orderedList = component.kind { blocks.append(.list(ordered: true, start: start, items: items)) }
                else { blocks.append(.list(ordered: false, start: 1, items: items)) }
            case .blockQuote:
                blocks.append(.quote(build(group, depth: depth + 1, style: style)))
            case .table(let columns):
                var header: [AttributedString] = [], rows: [[AttributedString]] = []
                var rowIndex = group.startIndex
                while rowIndex < group.endIndex {
                    guard let row = group[rowIndex].component(at: depth + 1) else { rowIndex += 1; continue }
                    var rowEnd = rowIndex
                    while rowEnd < group.endIndex, let next = group[rowEnd].component(at: depth + 1), next.identity == row.identity { rowEnd += 1 }
                    var cells: [AttributedString] = []
                    var cellIndex = rowIndex
                    while cellIndex < rowEnd {
                        guard let cell = group[cellIndex].component(at: depth + 2) else { cellIndex += 1; continue }
                        var cellEnd = cellIndex
                        while cellEnd < rowEnd, let next = group[cellEnd].component(at: depth + 2), next.identity == cell.identity { cellEnd += 1 }
                        cells.append(merged(group[cellIndex..<cellEnd]))
                        cellIndex = cellEnd
                    }
                    if case .tableHeaderRow = row.kind { header = cells } else { rows.append(cells) }
                    rowIndex = rowEnd
                }
                let alignments: [MarkdownAlignment] = columns.map { column in
                    switch column.alignment { case .center: return .center; case .right: return .right; default: return .left }
                }
                blocks.append(.table(alignments: alignments, header: header, rows: rows))
            case .listItem, .tableHeaderRow, .tableRow, .tableCell, .thematicBreak:
                // A stray container without its parent renders its content plainly.
                blocks.append(contentsOf: build(group, depth: depth + 1, style: style))
            default:
                blocks.append(.paragraph(merged(group)))
            }
            index = end
        }
        return blocks
    }

    private static func merged(_ leaves: ArraySlice<Leaf>) -> AttributedString {
        var result = AttributedString()
        for leaf in leaves { result.append(leaf.fragment) }
        return result
    }

    /// Dresses one run of inline text: emphasis, code spans, strikethrough,
    /// safe links, and images replaced by a note. Presentation attributes from
    /// the parser are removed so only ours reach the view.
    static func inline(_ piece: AttributedString, style: MarkdownStyle, size: CGFloat, heading: Bool = false) -> AttributedString {
        var result = AttributedString()
        let characters = piece.characters
        for run in piece.runs { result.append(inline(run, text: String(characters[run.range]), style: style, size: size, heading: heading)) }
        return result
    }
    private static func inline(_ run: AttributedString.Runs.Run, text: String, style: MarkdownStyle, size: CGFloat, heading: Bool) -> AttributedString {
            var text = text
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.softBreak) { text = style.keepsSoftBreaks ? "\n" : " " }
            if intent.contains(.lineBreak) { text = "\n" }
            if run.imageURL != nil { text = "[Image not loaded" + (text.isEmpty ? "]" : ": \(text)]") }
            var fragment = AttributedString(text)
            let weight: Font.Weight = heading || intent.contains(.stronglyEmphasized) ? .semibold : .regular
            if intent.contains(.code) {
                fragment.font = .system(size: size * 0.9, weight: weight, design: .monospaced)
                fragment.backgroundColor = style.codeBackground
            } else if heading {
                fragment.font = .system(size: size, weight: weight, design: .serif)
            } else {
                fragment.font = intent.contains(.emphasized) ? .system(size: size, weight: weight).italic() : .system(size: size, weight: weight)
            }
            if intent.contains(.emphasized) && intent.contains(.code) { fragment.font = .system(size: size * 0.9, weight: weight, design: .monospaced).italic() }
            fragment.foregroundColor = style.textColor
            if intent.contains(.strikethrough) { fragment.strikethroughStyle = .single }
            if run.imageURL == nil, let link = run.link, let safe = safeURL(link.absoluteString) {
                fragment.link = safe
                fragment.foregroundColor = style.linkColor
            }
            return fragment
    }

    /// The document's text with markdown removed, for accessibility labels and search.
    static func plainText(_ source: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: source, options: options) else { return source }
        return String(parsed.characters)
    }
}

/// The transcript's palette, the same values the stylesheet carried, as
/// appearance-aware colors.
enum TranscriptPalette {
    private static func dynamic(_ light: (UInt32, Double), _ dark: (UInt32, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value.0 >> 16) & 0xff) / 255, green: CGFloat((value.0 >> 8) & 0xff) / 255, blue: CGFloat(value.0 & 0xff) / 255, alpha: value.1)
        })
    }
    static let text = dynamic((0x1d1b17, 1), (0xeceae4, 1))
    static let muted = dynamic((0x6e6a61, 1), (0xa9a59b, 1))
    static let faint = dynamic((0x9b968c, 1), (0x78746b, 1))
    static let hair = dynamic((0x000000, 0.08), (0xffffff, 0.09))
    static let hairStrong = dynamic((0x000000, 0.14), (0xffffff, 0.16))
    static let panel = dynamic((0x000000, 0.035), (0xffffff, 0.045))
    static let panelStrong = dynamic((0x000000, 0.06), (0xffffff, 0.08))
    static let surface = dynamic((0xffffff, 1), (0x2e2925, 1))
    static let canvas = dynamic((0xfcf9f5, 1), (0x26221e, 1))
    static let accent = dynamic((0x984709, 1), (0xf0a052, 1))
    static let accentSoft = dynamic((0xd67520, 0.12), (0xf0a052, 0.18))
    static let userBackground = dynamic((0xf8ecdf, 1), (0x3a3129, 1))
    static let toolBackground = dynamic((0xf9f4ee, 1), (0x2a2521, 1))
    static let codeBackground = dynamic((0xf6f1ea, 1), (0x211d1a, 1))
    static let statusBackground = dynamic((0x000000, 0.05), (0xffffff, 0.07))
    static let danger = dynamic((0xc03a3a, 1), (0xea7c7c, 1))
    static let success = dynamic((0x3d8a57, 1), (0x7cc48f, 1))
    static let warning = dynamic((0xb97a1e, 1), (0xe3b15c, 1))
    static let keyword = dynamic((0x8a3fb0, 1), (0xd7a5ee, 1))
    static let string = dynamic((0x2f6b45, 1), (0xa5d9b3, 1))
    static let number = dynamic((0x2a5aa6, 1), (0xa8c9fc, 1))
    static let comment = dynamic((0x7a766d, 1), (0x9a968d, 1))
    static let diffAdded = dynamic((0x2f8f4e, 0.12), (0x2f8f4e, 0.18))
    static let diffAddedMark = dynamic((0x2f8f4e, 1), (0x7cc48f, 1))
}
