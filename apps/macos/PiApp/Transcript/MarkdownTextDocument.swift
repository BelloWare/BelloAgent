import AppKit
import SwiftUI

// A rendered reply as one text. Every block of it — paragraphs, headings,
// lists, quotes, tables and code — is laid out by TextKit in a single text
// view, so a selection runs from one block into the next the way it runs from
// one line into the next, and a copy is the text the selection covers.
//
// The blocks come from `StreamingMarkdownState`, which never shows markup a
// later token would take back: a block still arriving is read as the finished
// reply will read it. This file only turns those blocks into text: each block
// into paragraphs dressed for their place (indents, spacing, the list marker,
// the quote's bar, the code's panel), and the paragraphs into one attributed
// string. The panels, bars and table outlines are drawn behind the text by
// `MarkdownTextLayoutManager`; the controls that sit on them (copy buttons,
// the code's toolbar) are the surface's overlays.

extension NSAttributedString.Key {
    /// A code block's characters, its line breaks included: the panel behind
    /// them and what its copy button copies (`MarkdownCodeMark`).
    static let piCodeBlock = NSAttributedString.Key("PiMarkdownCodeBlock")
    /// A quoted paragraph: where the bars of the quotes it sits in are drawn.
    static let piQuote = NSAttributedString.Key("PiMarkdownQuote")
    /// A heading: which heading of the reply it is, for its copy button.
    static let piHeading = NSAttributedString.Key("PiMarkdownHeading")
    /// A list item's marker, as it is drawn ("\t•\t"): the text a copy puts
    /// in its place ("- ", "2. ").
    static let piListMarker = NSAttributedString.Key("PiMarkdownListMarker")
    /// A table's cells: the outline drawn around them (`MarkdownTableMark`).
    static let piTable = NSAttributedString.Key("PiMarkdownTable")
    /// The line break that ends a table cell that is not the last of its row:
    /// a copy puts a tab there.
    static let piCellBreak = NSAttributedString.Key("PiMarkdownCellBreak")
    /// Text that is the page's own and not the reply's: a large table's
    /// preview line. A copy leaves it out.
    static let piChrome = NSAttributedString.Key("PiMarkdownChrome")
    /// The line break between two blocks: what a copy puts there instead
    /// ("\n\n" between blocks, "\n" between list items).
    static let piBlockBreak = NSAttributedString.Key("PiMarkdownBlockBreak")
}

/// The face a run of inline text is set in, as the parser chose it: a value
/// an `AttributedString` can carry across threads, made into a font when the
/// run becomes TextKit text.
struct MarkdownFontSpec: Hashable, Sendable {
    var size: CGFloat
    var semibold = false
    var monospaced = false
    var serif = false
    var italic = false
    var font: NSFont { MarkdownTextFonts.font(size: size, weight: semibold ? .semibold : .regular, monospaced: monospaced, serif: serif, italic: italic) }
}
enum MarkdownFontAttribute: AttributedStringKey {
    typealias Value = MarkdownFontSpec
    static let name = "PiMarkdownFont"
}

/// One code block in the text. The same object stays with the block while it
/// grows, so its characters keep equal attributes from token to token.
final class MarkdownCodeMark: NSObject {
    var code: String
    var language: String?
    /// Where its panel begins, from the text's leading edge.
    var indent: CGFloat
    init(code: String, language: String?, indent: CGFloat) { self.code = code; self.language = language; self.indent = indent }
}

/// The bars of the quotes a paragraph sits in, outermost first, as x offsets.
final class MarkdownQuoteMark: NSObject {
    let bars: [CGFloat]
    init(bars: [CGFloat]) { self.bars = bars }
}

/// One table in the text: the outline around its cells, and, for a table too
/// large to show whole, what "Open full table" opens.
final class MarkdownTableMark: NSObject {
    let header: [AttributedString]
    let rows: [[AttributedString]]
    let large: Bool
    init(header: [AttributedString], rows: [[AttributedString]], large: Bool) { self.header = header; self.rows = rows; self.large = large }
}

/// A paragraph as the builder lays it out: its text, and how it sits among
/// the paragraphs around it.
struct MarkdownTextParagraph {
    var text: NSMutableAttributedString
    var firstIndent: CGFloat
    var indent: CGFloat
    /// Positive: where lines end, from the leading edge (the prose measure).
    /// Zero or negative: from the trailing edge.
    var tailIndent: CGFloat
    var lineSpacing: CGFloat
    /// The least a line is tall: its face's natural height rounded up to a
    /// whole point, as SwiftUI sets it (TextKit rounds 14.5 pt text to 17,
    /// SwiftUI to 18). Zero leaves TextKit's own.
    var lineHeight: CGFloat = 0
    /// Space between the previous paragraph's text (or panel) and this one's.
    var gap: CGFloat
    /// Room inside a panel above the first line and below the last.
    var topPad: CGFloat = 0
    var bottomPad: CGFloat = 0
    /// Holds several of TextKit's paragraphs (a code block's lines); only the
    /// first of them takes `gap`.
    var multiline = false
    var tabStops: [NSTextTab] = []
    var textBlocks: [NSTextBlock] = []
    var alignment: NSTextAlignment = .natural
    /// Marks for the whole paragraph, its closing line break included.
    var marks: [NSAttributedString.Key: Any] = [:]
    /// What a copy puts in place of the line break that ends the block this
    /// paragraph closes.
    var breakCopy = "\n\n"
}

/// How the paragraph before a block ended, which decides how far below it
/// the block begins.
struct MarkdownTextTail: Equatable {
    var lineSpacing: CGFloat
    var bottomPad: CGFloat
}

/// Where a block sits: its leading edge, the quotes around it, the style it
/// is dressed in and the list depth, for a copy's markers.
struct MarkdownTextContext {
    var indent: CGFloat = 0
    var quoteBars: [CGFloat] = []
    var style: MarkdownStyle
    var capsWidth: Bool
    var listDepth = 0
}

/// Fonts are made once per face. The parser dresses text off the main
/// thread too, so the cache is locked.
enum MarkdownTextFonts {
    nonisolated(unsafe) private static var cache: [String: NSFont] = [:]
    private static let lock = NSLock()
    static func font(size: CGFloat, weight: NSFont.Weight = .regular, monospaced: Bool = false, serif: Bool = false, italic: Bool = false) -> NSFont {
        let key = "\(size)|\(weight.rawValue)|\(monospaced)|\(serif)|\(italic)"
        lock.lock(); defer { lock.unlock() }
        if let font = cache[key] { return font }
        var font = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        if serif, let descriptor = font.fontDescriptor.withDesign(.serif), let serifFont = NSFont(descriptor: descriptor, size: size) { font = serifFont }
        if italic {
            let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        cache[key] = font
        return font
    }
}

/// Turns the reading's blocks into the text: the geometry the rows had when
/// each block was a view of its own — the same measures, gaps and paddings.
enum MarkdownTextLayout {
    static let blockGap: CGFloat = 10
    static let listItemGap: CGFloat = 4
    static let innerGap: CGFloat = 6
    static let headingTop: CGFloat = 6
    static let codeTop: CGFloat = 31
    static let codeBottom: CGFloat = 10
    static let codeInset: CGFloat = 14
    static let tablePad: CGFloat = 2
    static let listLeading: CGFloat = 4
    static let markerWidth: CGFloat = 16
    static let markerGap: CGFloat = 8
    static let quoteBar: CGFloat = 3
    static let quoteGap: CGFloat = 12

    static func prose(_ style: MarkdownStyle) -> CGFloat { style.baseSize * 0.35 }
    static func codeSize(_ style: MarkdownStyle) -> CGFloat { style.baseSize * 0.86 }
    /// A face's line as SwiftUI sets it: its natural height, rounded up.
    static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }
    /// The line height for a text, from the face it opens in.
    static func lineHeight(_ text: NSAttributedString) -> CGFloat {
        guard text.length > 0, let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return 0 }
        return lineHeight(font)
    }
}

/// Builds one block's paragraphs. A code block's colouring is kept per block
/// and resumed where the scanner last stood in a neutral state, so a token
/// on a long fence colours what it adds, not the whole fence again.
@MainActor final class MarkdownTextBuilder {
    struct CodeReading {
        var code: String
        var language: String?
        var size: CGFloat
        var text: NSMutableAttributedString
        var checkpoint: (utf8: Int, utf16: Int)
        var mark: MarkdownCodeMark
        /// Where this reading's colouring began: the code before it reads,
        /// and is coloured, as it was.
        var recolorFrom = 0
    }
    private var codeReadings: [MarkdownBlockIdentity: CodeReading] = [:]
    /// Code scanned for colour, in all: a token's share should not grow with the fence.
    private(set) var highlightedScalarVisits = 0

    /// Drops what the builder remembers of blocks no longer in the reply. A
    /// fence inside a list or quote is known by its block's place in the
    /// source, so it is kept with that block.
    func retain(_ identities: [MarkdownBlockIdentity]) {
        struct Place: Hashable { var generation: UInt64; var offset: Int }
        let places = Set(identities.map { Place(generation: $0.generation, offset: $0.sourceOffset) })
        codeReadings = codeReadings.filter { places.contains(Place(generation: $0.key.generation, offset: $0.key.sourceOffset)) }
    }

    func paragraphs(_ block: MarkdownBlock, identity: MarkdownBlockIdentity, context: MarkdownTextContext, gap: CGFloat,
                    headingIndex: Int?) -> [MarkdownTextParagraph] {
        switch block {
        case .paragraph(let text):
            return [prose(text, context: context, gap: gap)]
        case .heading(_, let text, _):
            var paragraph = prose(text, context: context, gap: gap + MarkdownTextLayout.headingTop)
            if let headingIndex { paragraph.marks[.piHeading] = headingIndex }
            return [paragraph]
        case .code(let language, let code):
            return [codeBlock(language: language, code: code, identity: identity, context: context, gap: gap)]
        case .list(let ordered, let start, let items):
            return list(ordered: ordered, start: start, items: items, identity: identity, context: context, gap: gap)
        case .quote(let inner):
            var nested = context
            nested.quoteBars.append(context.indent)
            nested.indent += MarkdownTextLayout.quoteBar + MarkdownTextLayout.quoteGap
            let mark = MarkdownQuoteMark(bars: nested.quoteBars)
            var result: [MarkdownTextParagraph] = []
            for (index, child) in inner.enumerated() {
                var id = identity; id.component = 1_000 + index
                var parts = paragraphs(child, identity: id, context: nested, gap: index == 0 ? gap : MarkdownTextLayout.innerGap, headingIndex: nil)
                for part in parts.indices where parts[part].marks[.piQuote] == nil { parts[part].marks[.piQuote] = mark }
                result += parts
            }
            return result
        case .table(let alignments, let header, let rows):
            return table(alignments: alignments, header: header, rows: rows, context: context, gap: gap)
        }
    }

    // MARK: Blocks

    private func prose(_ text: AttributedString, context: MarkdownTextContext, gap: CGFloat) -> MarkdownTextParagraph {
        let converted = Self.appKit(text)
        return MarkdownTextParagraph(text: converted, firstIndent: context.indent, indent: context.indent,
                                     tailIndent: context.capsWidth ? TranscriptMetrics.proseWidth : 0,
                                     lineSpacing: MarkdownTextLayout.prose(context.style),
                                     lineHeight: max(MarkdownTextLayout.lineHeight(converted), MarkdownTextLayout.lineHeight(MarkdownTextFonts.font(size: context.style.baseSize))),
                                     gap: gap)
    }

    /// Inline text as TextKit draws it, run by run, from the dress the
    /// parser gave it (`TranscriptMarkdown.inline`). A colour converts to
    /// the same AppKit colour every time, so equal runs stay equal text.
    static func appKit(_ text: AttributedString) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let characters = text.characters
        for run in text.runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: (run[MarkdownFontAttribute.self] ?? MarkdownFontSpec(size: MarkdownStyle.prose.baseSize)).font
            ]
            if let color = run.swiftUI.foregroundColor { attributes[.foregroundColor] = NSColor(color) }
            else { attributes[.foregroundColor] = NSColor(TranscriptPalette.text) }
            if let color = run.swiftUI.backgroundColor { attributes[.backgroundColor] = NSColor(color) }
            if run.swiftUI.strikethroughStyle != nil { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(characters[run.range]), attributes: attributes))
        }
        return result
    }

    /// A fence's paragraph, and the reading it was coloured in.
    func code(language: String?, code: String, identity: MarkdownBlockIdentity, context: MarkdownTextContext, gap: CGFloat) -> (MarkdownTextParagraph, CodeReading) {
        let size = MarkdownTextLayout.codeSize(context.style)
        let reading = highlighted(code, language: language, size: size, identity: identity, indent: context.indent)
        return (codeParagraph(reading.text, mark: reading.mark, context: context, gap: gap), reading)
    }
    private func codeBlock(language: String?, code: String, identity: MarkdownBlockIdentity, context: MarkdownTextContext, gap: CGFloat) -> MarkdownTextParagraph {
        self.code(language: language, code: code, identity: identity, context: context, gap: gap).0
    }
    private func codeParagraph(_ text: NSMutableAttributedString, mark: MarkdownCodeMark, context: MarkdownTextContext, gap: CGFloat) -> MarkdownTextParagraph {
        let size = MarkdownTextLayout.codeSize(context.style)
        // The reading's own text: the assembler copies what it dresses.
        return MarkdownTextParagraph(text: text,
                                     firstIndent: context.indent + MarkdownTextLayout.codeInset,
                                     indent: context.indent + MarkdownTextLayout.codeInset,
                                     tailIndent: -MarkdownTextLayout.codeInset, lineSpacing: size * 0.4,
                                     lineHeight: MarkdownTextLayout.lineHeight(MarkdownTextFonts.font(size: size, monospaced: true)), gap: gap,
                                     topPad: MarkdownTextLayout.codeTop, bottomPad: MarkdownTextLayout.codeBottom,
                                     multiline: true, marks: [.piCodeBlock: mark])
    }

    /// The fence's code, coloured. A fence that grew by a suffix is coloured
    /// again only from the last neutral point the scanner found in it.
    private func highlighted(_ code: String, language: String?, size: CGFloat, identity: MarkdownBlockIdentity, indent: CGFloat) -> CodeReading {
        let font = MarkdownTextFonts.font(size: size, monospaced: true)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(TranscriptPalette.text)]
        let previous = codeReadings[identity]
        let append = previous.map { $0.language == language && $0.size == size && code.hasUTF8Prefix($0.code) } ?? false
        let mark = previous?.mark ?? MarkdownCodeMark(code: code, language: language, indent: indent)
        mark.code = code; mark.language = language; mark.indent = indent
        let text: NSMutableAttributedString
        var resume = (utf8: 0, utf16: 0)
        let previousLength = previous?.text.length ?? 0
        var scanned = false
        if append, let previous {
            text = previous.text
            if code.utf8.count > previous.code.utf8.count {
                let suffix = String(decoding: code.utf8.dropFirst(previous.code.utf8.count), as: UTF8.self)
                text.append(NSAttributedString(string: suffix, attributes: base))
            }
            resume = previous.checkpoint
        } else {
            text = NSMutableAttributedString(string: code, attributes: base)
        }
        var checkpoint = resume
        // Once the code reaches the colouring limit, what a token adds lies
        // past it: there is nothing more to colour.
        if let name = language, let grammar = SyntaxHighlighter.language(named: name), resume.utf8 < SyntaxHighlighter.limit,
           !append || (previous?.code.utf8.count ?? 0) < SyntaxHighlighter.limit {
            let tail: String = code.withUTF8Bytes { bytes in
                var bound = min(bytes.count, SyntaxHighlighter.limit)
                while bound > 0, bound < bytes.count, bytes[bound] & 0xC0 == 0x80 { bound -= 1 }
                return String(decoding: UnsafeBufferPointer(rebasing: bytes[min(resume.utf8, bound)..<bound]), as: UTF8.self)
            }
            let scan = SyntaxHighlighter.scan(tail, language: grammar)
            scanned = true
            var utf16 = [resume.utf16], utf8 = [resume.utf8]
            utf16.reserveCapacity(tail.utf8.count + 1); utf8.reserveCapacity(tail.utf8.count + 1)
            for scalar in tail.unicodeScalars {
                utf16.append(utf16[utf16.count - 1] + (scalar.value > 0xffff ? 2 : 1))
                utf8.append(utf8[utf8.count - 1] + UTF8.width(scalar))
            }
            highlightedScalarVisits += utf16.count - 1
            let start = min(resume.utf16, text.length)
            text.setAttributes(base, range: NSRange(location: start, length: text.length - start))
            for token in scan.tokens {
                let range = NSRange(location: utf16[token.range.lowerBound], length: utf16[token.range.upperBound] - utf16[token.range.lowerBound])
                guard NSMaxRange(range) <= text.length else { continue }
                let color: Color
                switch token.kind {
                case .keyword: color = TranscriptPalette.keyword
                case .string: color = TranscriptPalette.string
                case .number, .title: color = TranscriptPalette.number
                case .comment:
                    color = TranscriptPalette.comment
                    text.addAttribute(.font, value: MarkdownTextFonts.font(size: size, monospaced: true, italic: true), range: range)
                }
                text.addAttribute(.foregroundColor, value: NSColor(color), range: range)
            }
            if let last = scan.checkpoints.last(where: { $0 < utf16.count - 1 }) { checkpoint = (utf8[last], utf16[last]) }
        } else if !append {
            checkpoint = (0, 0)
        }
        // Code past the colouring limit, or in a language with no colours,
        // is plain: a token changes only what it adds.
        let reading = CodeReading(code: code, language: language, size: size, text: text, checkpoint: checkpoint, mark: mark,
                                  recolorFrom: append ? (scanned ? resume.utf16 : previousLength) : 0)
        codeReadings[identity] = reading
        return reading
    }

    /// The width of a list's marker column: its widest marker, and at least
    /// the width the rows gave the column. Worked out from the last number's
    /// width, not by measuring every marker of a long list.
    func markerColumn(ordered: Bool, start: Int, count: Int, style: MarkdownStyle) -> CGFloat {
        guard ordered, count > 0 else { return MarkdownTextLayout.markerWidth }
        let font = MarkdownTextFonts.font(size: style.baseSize)
        let last = start + count - 1, digits = String(max(abs(start), abs(last))).count
        let widest = max(("\(last)." as NSString).size(withAttributes: [.font: font]).width,
                         ((String(repeating: "8", count: digits) + ".") as NSString).size(withAttributes: [.font: font]).width)
        return max(MarkdownTextLayout.markerWidth, ceil(widest))
    }

    /// One item of a list: its marker, and its blocks at the item's text.
    /// Inside an item a copy puts one line break between lines; the break
    /// after its last line is the list's to decide.
    func listItem(_ item: [MarkdownBlock], number: Int, ordered: Bool, column: CGFloat, identity: MarkdownBlockIdentity,
                  context: MarkdownTextContext, gap: CGFloat) -> [MarkdownTextParagraph] {
        let markerFont = MarkdownTextFonts.font(size: context.style.baseSize)
        let marker = ordered ? "\(number)." : "•"
        let markerRight = context.indent + MarkdownTextLayout.listLeading + column
        var inner = context
        inner.indent = markerRight + MarkdownTextLayout.markerGap
        inner.listDepth += 1
        var parts: [MarkdownTextParagraph] = []
        for (blockIndex, block) in item.enumerated() {
            var id = identity; id.component = identity.component &* 131 &+ 10_007 &+ blockIndex
            parts += paragraphs(block, identity: id, context: inner, gap: blockIndex == 0 ? gap : MarkdownTextLayout.innerGap, headingIndex: nil)
        }
        let markerText = NSMutableAttributedString(string: "\t" + marker + "\t", attributes: [
            .font: markerFont, .foregroundColor: NSColor(context.style.textColor),
            .piListMarker: String(repeating: "  ", count: context.listDepth) + (ordered ? marker + " " : "- ")
        ])
        let tabs = [NSTextTab(textAlignment: .right, location: markerRight), NSTextTab(textAlignment: .left, location: inner.indent)]
        if let first = parts.first, !first.multiline, first.textBlocks.isEmpty, first.marks[.piCodeBlock] == nil {
            // The marker leads the item's first line; its other lines hang at the item's text.
            var paragraph = first
            markerText.append(paragraph.text)
            paragraph.text = markerText
            paragraph.firstIndent = context.indent
            paragraph.tabStops = tabs
            parts[0] = paragraph
        } else {
            // An item that opens with a fence, a table or nothing has its marker on a line of its own.
            let line = MarkdownTextParagraph(text: markerText, firstIndent: context.indent, indent: inner.indent,
                                             tailIndent: 0, lineSpacing: MarkdownTextLayout.prose(context.style),
                                             lineHeight: MarkdownTextLayout.lineHeight(markerFont), gap: gap, tabStops: tabs)
            if !parts.isEmpty { parts[0].gap = MarkdownTextLayout.innerGap }
            parts.insert(line, at: 0)
        }
        for index in parts.indices.dropLast() where parts[index].breakCopy == "\n\n" { parts[index].breakCopy = "\n" }
        return parts
    }

    private func list(ordered: Bool, start: Int, items: [[MarkdownBlock]], identity: MarkdownBlockIdentity,
                      context: MarkdownTextContext, gap: CGFloat) -> [MarkdownTextParagraph] {
        let column = markerColumn(ordered: ordered, start: start, count: items.count, style: context.style)
        var result: [MarkdownTextParagraph] = []
        for (index, item) in items.enumerated() {
            var id = identity; id.component = identity.component &* 131 &+ 20_011 &+ index
            var parts = listItem(item, number: start + index, ordered: ordered, column: column, identity: id, context: context,
                                 gap: index == 0 ? gap : MarkdownTextLayout.listItemGap)
            // Between two items a copy puts one line break, not a blank line.
            if index + 1 < items.count, !parts.isEmpty { parts[parts.count - 1].breakCopy = "\n" }
            result += parts
        }
        return result
    }

    private func table(alignments: [MarkdownAlignment], header: [AttributedString], rows: [[AttributedString]],
                       context: MarkdownTextContext, gap: CGFloat) -> [MarkdownTextParagraph] {
        let large = MarkdownTablePresentation.isLarge(header: header, rows: rows)
        let columnsShown = large ? MarkdownTablePresentation.previewColumns : Int.max
        let shownHeader = Array(header.prefix(columnsShown))
        let shownRows = (large ? Array(rows.prefix(MarkdownTablePresentation.previewRows)) : rows).map { Array($0.prefix(columnsShown)) }
        let columns = max(shownHeader.count, shownRows.map(\.count).max() ?? 0)
        guard columns > 0 else { return [] }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        let mark = MarkdownTableMark(header: header, rows: rows, large: large)
        let hair = NSColor(TranscriptPalette.hair)
        let headerFont = MarkdownTextFonts.font(size: 13, weight: .semibold)
        var cells: [[NSMutableAttributedString]] = []
        if !shownHeader.isEmpty {
            cells.append(shownHeader.map { cell in
                let text = Self.appKit(cell)
                text.addAttribute(.font, value: headerFont, range: NSRange(location: 0, length: text.length))
                return text
            })
        }
        for row in shownRows { cells.append(row.map { Self.appKit($0) }) }
        // Each column is as wide as its widest cell on one line; a table wider
        // than the page has TextKit narrow its columns in proportion and wrap.
        var widths = Array(repeating: CGFloat(0), count: columns)
        for row in cells {
            for (column, cell) in row.enumerated() {
                let natural = ceil(cell.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).width) + 1
                widths[column] = max(widths[column], min(natural, large ? 320 : 100_000))
            }
        }
        table.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
        var result: [MarkdownTextParagraph] = []
        if large {
            let note = "Preview · first \(min(rows.count, MarkdownTablePresentation.previewRows)) of \(rows.count.formatted()) rows · up to \(MarkdownTablePresentation.previewColumns) columns"
            let text = NSMutableAttributedString(string: note, attributes: [
                .font: MarkdownTextFonts.font(size: 11), .foregroundColor: NSColor(TranscriptPalette.muted), .piChrome: true
            ])
            result.append(MarkdownTextParagraph(text: text, firstIndent: context.indent, indent: context.indent, tailIndent: 0,
                                                lineSpacing: 0, gap: gap, marks: [.piChrome: true, .piTable: mark], breakCopy: ""))
        }
        for (rowIndex, row) in cells.enumerated() {
            for column in 0..<columns {
                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setValue(max(1, widths[column]), type: .absoluteValueType, for: .width)
                block.setBorderColor(hair)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
                block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
                if rowIndex == 0, !shownHeader.isEmpty { block.backgroundColor = NSColor(TranscriptPalette.panel) }
                let text = column < row.count ? row[column] : NSMutableAttributedString()
                let alignment: NSTextAlignment
                switch alignments.indices.contains(column) ? alignments[column] : .left {
                case .center: alignment = .center
                case .right: alignment = .right
                case .left: alignment = .natural
                }
                var paragraph = MarkdownTextParagraph(text: text, firstIndent: 0, indent: 0, tailIndent: 0, lineSpacing: 0,
                                                      gap: 0, textBlocks: [block], alignment: alignment, marks: [.piTable: mark])
                // Above the table: the block gap, or under a preview line the
                // gap the rows kept between that line and the table.
                if rowIndex == 0 && column == 0 { paragraph.gap = (large ? MarkdownTextLayout.innerGap : gap) + MarkdownTextLayout.tablePad }
                paragraph.breakCopy = column + 1 < columns ? "\t" : "\n"
                if rowIndex == cells.count - 1, column == columns - 1 { paragraph.bottomPad = MarkdownTextLayout.tablePad; paragraph.breakCopy = "\n\n" }
                result.append(paragraph)
            }
        }
        return result
    }
}

/// Joins paragraphs into the reply's text. Each paragraph after the first is
/// preceded by the line break that ends the one before it; the break carries
/// the marks of the paragraph it ends, so a panel runs to its last line.
@MainActor enum MarkdownTextAssembler {
    /// How far below the previous paragraph's text a paragraph's text begins,
    /// less the line spacing TextKit already leaves below that paragraph.
    static func spacing(_ paragraph: MarkdownTextParagraph, after tail: MarkdownTextTail) -> CGFloat {
        max(0, paragraph.gap + tail.bottomPad + paragraph.topPad - tail.lineSpacing)
    }

    /// The paragraph style for a paragraph that follows `tail` (nil for the
    /// reply's first paragraph, which TextKit sets at the very top).
    static func style(_ paragraph: MarkdownTextParagraph, after tail: MarkdownTextTail?, firstLine: Bool) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = firstLine ? paragraph.firstIndent : paragraph.indent
        style.headIndent = paragraph.indent
        style.tailIndent = paragraph.tailIndent
        style.lineSpacing = paragraph.lineSpacing
        if paragraph.lineHeight > 0 { style.minimumLineHeight = paragraph.lineHeight }
        style.alignment = paragraph.alignment
        style.lineBreakMode = .byWordWrapping
        if !paragraph.tabStops.isEmpty { style.tabStops = paragraph.tabStops; style.defaultTabInterval = 0 }
        if !paragraph.textBlocks.isEmpty {
            style.textBlocks = paragraph.textBlocks
            // A table's cells keep their spacing inside them; the space above
            // the table is the table's own margin.
            if firstLine, let tail, let cell = paragraph.textBlocks.first as? NSTextTableBlock, cell.startingRow == 0, cell.startingColumn == 0 {
                cell.table.setWidth(spacing(paragraph, after: tail), type: .absoluteValueType, for: .margin, edge: .minY)
            }
        } else if firstLine, let tail {
            style.paragraphSpacingBefore = spacing(paragraph, after: tail)
        }
        return style
    }

    /// One block's paragraphs as text, following a block whose last paragraph
    /// ended as `tail` and whose line break a copy gives as `leadingBreak`.
    static func text(_ paragraphs: [MarkdownTextParagraph], after tail: MarkdownTextTail?, leadingBreak: String?,
                     leadingAttributes: [NSAttributedString.Key: Any]) -> (NSMutableAttributedString, MarkdownTextTail?) {
        let result = NSMutableAttributedString()
        var tail = tail
        var pendingBreak = leadingBreak
        var breakAttributes = leadingAttributes
        for paragraph in paragraphs {
            if let copy = pendingBreak {
                // The break ends the paragraph before: it takes that paragraph's dress.
                var attributes = breakAttributes
                attributes[.piBlockBreak] = copy
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            // A copy: the builder keeps some texts (a fence's reading) to extend.
            let text = NSMutableAttributedString(attributedString: paragraph.text)
            let full = NSRange(location: 0, length: text.length)
            if paragraph.multiline, let firstBreak = (text.string as NSString).range(of: "\n").toOptional {
                let firstLength = firstBreak.location + 1
                text.addAttribute(.paragraphStyle, value: style(paragraph, after: tail, firstLine: true), range: NSRange(location: 0, length: firstLength))
                text.addAttribute(.paragraphStyle, value: style(paragraph, after: nil, firstLine: false), range: NSRange(location: firstLength, length: text.length - firstLength))
            } else if text.length > 0 {
                text.addAttribute(.paragraphStyle, value: style(paragraph, after: tail, firstLine: true), range: full)
            }
            for (key, value) in paragraph.marks { text.addAttribute(key, value: value, range: full) }
            if text.length == 0 {
                // An empty paragraph (an empty cell, an empty fence) is still a
                // line: its style rides on the break that ends it.
                breakAttributes = paragraph.marks
                breakAttributes[.paragraphStyle] = style(paragraph, after: tail, firstLine: true)
                breakAttributes[.font] = MarkdownTextFonts.font(size: paragraph.multiline ? 12.5 : 14.5, monospaced: paragraph.multiline)
            } else {
                breakAttributes = paragraph.marks
                for key in [NSAttributedString.Key.font, .paragraphStyle, .foregroundColor] {
                    if let value = text.attribute(key, at: text.length - 1, effectiveRange: nil) { breakAttributes[key] = value }
                }
            }
            result.append(text)
            pendingBreak = paragraph.breakCopy
            tail = MarkdownTextTail(lineSpacing: paragraph.lineSpacing, bottomPad: paragraph.bottomPad)
        }
        return (result, tail)
    }
}

private extension NSRange {
    var toOptional: NSRange? { location == NSNotFound ? nil : self }
}

/// Draws what sits behind the text: each code block's panel, each quote's
/// bar and each table's outline, from the lines TextKit laid out.
final class MarkdownTextLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first, glyphsToShow.length > 0 else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin); return
        }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        // Panels first: inline backgrounds (a code span's) are drawn over them.
        var drawn = Set<ObjectIdentifier>()
        storage.enumerateAttribute(.piCodeBlock, in: characters) { value, _, _ in
            guard let mark = value as? MarkdownCodeMark, drawn.insert(ObjectIdentifier(mark)).inserted else { return }
            // A panel begun above the lines being drawn is still drawn whole.
            let full = Self.extent(of: mark, key: .piCodeBlock, around: characters, in: storage)
            guard let rect = panelRect(for: full, indent: mark.indent, container: container) else { return }
            let path = NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
            NSColor(TranscriptPalette.codeBackground).setFill(); path.fill()
            NSColor(TranscriptPalette.hair).setStroke(); path.lineWidth = 1; path.stroke()
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        storage.enumerateAttribute(.piTable, in: characters) { value, _, _ in
            guard let mark = value as? MarkdownTableMark, drawn.insert(ObjectIdentifier(mark)).inserted else { return }
            let full = Self.extent(of: mark, key: .piTable, around: characters, in: storage)
            // The cells' own borders are TextKit's; the rounded outline is ours.
            guard let outline = tableOutline(full) else { return }
            let path = NSBezierPath(roundedRect: outline.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            NSColor(TranscriptPalette.hair).setStroke(); path.lineWidth = 1; path.stroke()
        }
        let text = storage.string as NSString
        var location = characters.location
        NSColor(TranscriptPalette.hairStrong).setFill()
        while location < NSMaxRange(characters) {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            location = max(location + 1, NSMaxRange(paragraph))
            guard let mark = storage.attribute(.piQuote, at: paragraph.location, effectiveRange: nil) as? MarkdownQuoteMark,
                  let box = textBox(forCharacters: paragraph) else { continue }
            // A bar runs on through the gap above to the quoted paragraph
            // before, when that one sits in the same quote.
            var above: (mark: MarkdownQuoteMark, box: NSRect)?
            if paragraph.location > 0, let mark = storage.attribute(.piQuote, at: paragraph.location - 1, effectiveRange: nil) as? MarkdownQuoteMark,
               let box = textBox(forCharacters: text.paragraphRange(for: NSRange(location: paragraph.location - 1, length: 0))) { above = (mark, box) }
            for bar in mark.bars {
                let top = above.map { $0.mark.bars.contains(bar) ? $0.box.maxY : box.minY } ?? box.minY
                let rect = NSRect(x: bar, y: top, width: MarkdownTextLayout.quoteBar, height: max(0, box.maxY - top))
                NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y), xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }

    /// The characters an object marks, found from a range that reaches them.
    static func extent(of mark: AnyObject, key: NSAttributedString.Key, around characters: NSRange, in storage: NSTextStorage) -> NSRange {
        let length = storage.length
        var start = NSNotFound, end = 0
        storage.enumerateAttribute(key, in: characters) { value, range, stop in
            if value as AnyObject === mark { start = range.location; end = NSMaxRange(range); stop.pointee = true }
        }
        guard start != NSNotFound else { return NSRange(location: characters.location, length: 0) }
        var probe = NSRange()
        while start > 0, storage.attribute(key, at: start - 1, effectiveRange: &probe) as AnyObject === mark { start = probe.location }
        while end < length, storage.attribute(key, at: end, effectiveRange: &probe) as AnyObject === mark { end = NSMaxRange(probe) }
        return NSRange(location: start, length: end - start)
    }

    /// A line's text, without the line spacing TextKit leaves below every
    /// line but the reply's last.
    func lineBox(atGlyph glyph: Int) -> NSRect? {
        guard glyph >= 0, glyph < numberOfGlyphs, let storage = textStorage, storage.length > 0 else { return nil }
        var used = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        var line = NSRange()
        _ = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
        if NSMaxRange(line) < numberOfGlyphs {
            let character = min(characterIndexForGlyph(at: glyph), storage.length - 1)
            if let style = storage.attribute(.paragraphStyle, at: character, effectiveRange: nil) as? NSParagraphStyle {
                used.size.height = max(0, used.height - style.lineSpacing)
            }
        }
        return used
    }

    /// From the first line's text to the last line's, for some characters.
    func textBox(forCharacters characters: NSRange) -> NSRect? {
        guard let storage = textStorage, characters.location < storage.length else { return nil }
        let glyphs = glyphRange(forCharacterRange: NSRange(location: characters.location, length: max(1, min(characters.length, storage.length - characters.location))), actualCharacterRange: nil)
        guard glyphs.location < numberOfGlyphs, let first = lineBox(atGlyph: glyphs.location),
              let last = lineBox(atGlyph: min(max(glyphs.location, NSMaxRange(glyphs) - 1), numberOfGlyphs - 1)) else { return nil }
        return NSRect(x: min(first.minX, last.minX), y: first.minY, width: max(first.maxX, last.maxX) - min(first.minX, last.minX), height: last.maxY - first.minY)
    }

    /// A code block's panel: its lines' text with the fence's padding around
    /// it, as wide as the page from the block's own leading edge.
    func panelRect(for characters: NSRange, indent: CGFloat, container: NSTextContainer) -> NSRect? {
        guard characters.length > 0, let box = textBox(forCharacters: characters) else { return nil }
        let top = box.minY - MarkdownTextLayout.codeTop, bottom = box.maxY + MarkdownTextLayout.codeBottom
        return NSRect(x: indent, y: top, width: max(0, container.size.width - indent), height: bottom - top)
    }

    /// A table's cells, border to border.
    func tableOutline(_ characters: NSRange) -> NSRect? {
        guard let storage = textStorage else { return nil }
        var outline = NSRect.null
        storage.enumerateAttribute(.paragraphStyle, in: characters) { value, range, _ in
            guard let style = value as? NSParagraphStyle, let block = style.textBlocks.first as? NSTextTableBlock else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.location < numberOfGlyphs else { return }
            outline = outline.union(boundsRect(for: block, glyphRange: glyphs))
        }
        return outline.isNull ? nil : outline
    }
}
