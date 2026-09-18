import Foundation

// Copy targets for a markdown message: the introduction, each heading's
// section (through its nested subsections, not its peers) and each code
// block's exact source without fences or container prefixes. A line scanner
// finds them in the source itself, so what reaches the clipboard is the
// author's bytes, never a re-rendering.

struct MarkdownCopyTarget: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case introduction, whole, section(level: Int), code }
    let kind: Kind
    let label: String
    let text: String
}

enum TranscriptCopy {
    static let maximumBytes = 65_536

    private struct Line {
        let start: String.Index
        let end: String.Index        // Start of the line ending
        let next: String.Index       // Start of the following line
        let text: Substring
    }
    private struct Heading {
        let level: Int
        let title: String
        let start: String.Index
    }

    private static func lines(of source: String) -> [Line] {
        var lines: [Line] = []
        var cursor = source.startIndex
        while cursor < source.endIndex {
            var end = cursor
            // A CRLF pair is one Character in Swift, so each ending is a single step.
            while end < source.endIndex, source[end] != "\n", source[end] != "\r", source[end] != "\r\n" { end = source.index(after: end) }
            let next = end < source.endIndex ? source.index(after: end) : end
            lines.append(Line(start: cursor, end: end, next: next, text: source[cursor..<end]))
            cursor = next
        }
        return lines
    }
    private static func indentation(_ text: Substring) -> Int { text.prefix { $0 == " " }.count }
    /// A fence opener at up to three spaces of indentation: the container prefix, the fence character and its length.
    private static func fence(_ text: Substring) -> (prefix: Substring, character: Character, length: Int, rest: Substring)? {
        var body = text
        var prefix = text.startIndex
        // Quote and list markers are container prefixes the fence sits inside.
        while true {
            let trimmed = body.drop { $0 == " " || $0 == "\t" }
            if trimmed.first == ">" { body = trimmed.dropFirst(); if body.first == " " { body = body.dropFirst() }; prefix = body.startIndex; continue }
            if let first = trimmed.first, first == "-" || first == "*" || first == "+", trimmed.dropFirst().first == " " { body = trimmed.dropFirst(2); prefix = body.startIndex; continue }
            break
        }
        let indent = indentation(body)
        guard indent <= 3 else { return nil }
        let candidate = body.dropFirst(indent)
        guard let character = candidate.first, character == "`" || character == "~" else { return nil }
        let length = candidate.prefix { $0 == character }.count
        guard length >= 3 else { return nil }
        let rest = candidate.dropFirst(length)
        if character == "`", rest.contains("`") { return nil }
        return (text[text.startIndex..<prefix] + Substring(String(repeating: " ", count: indent)), character, length, rest)
    }
    private static func strippingPrefix(_ text: Substring, _ prefix: Substring) -> Substring {
        var remaining = text, expected = prefix[...]
        while let p = expected.first, let t = remaining.first, p == t || (p == " " && t == "\t") { expected = expected.dropFirst(); remaining = remaining.dropFirst() }
        return remaining
    }
    private static func atxHeading(_ text: Substring) -> (level: Int, title: String)? {
        let body = text.dropFirst(min(3, indentation(text)))
        let level = body.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let after = body.dropFirst(level)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        var title = after.trimmingCharacters(in: .whitespaces)
        while title.hasSuffix("#") { title.removeLast() }
        return (level, title.trimmingCharacters(in: .whitespaces))
    }
    private static func setextUnderline(_ text: Substring) -> Int? {
        let body = text.dropFirst(min(3, indentation(text))).trimmingCharacters(in: .whitespaces)
        guard let first = body.first, first == "=" || first == "-", body.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }
    private static func isContainerLine(_ text: Substring) -> Bool {
        let trimmed = text.drop { $0 == " " }
        if trimmed.first == ">" { return true }
        if let first = trimmed.first, first == "-" || first == "*" || first == "+", trimmed.dropFirst().first == " " { return true }
        if let digits = trimmed.firstIndex(where: { !$0.isNumber }), digits > trimmed.startIndex, digits < trimmed.endIndex, trimmed[digits] == "." || trimmed[digits] == ")", trimmed.index(after: digits) < trimmed.endIndex, trimmed[trimmed.index(after: digits)] == " " { return true }
        return false
    }

    private final class CachedTargets: Sendable {
        let targets: [MarkdownCopyTarget]
        init(_ targets: [MarkdownCopyTarget]) { self.targets = targets }
    }
    nonisolated(unsafe) private static let cache: NSCache<NSString, CachedTargets> = {
        let cache = NSCache<NSString, CachedTargets>(); cache.countLimit = 1_000; cache.totalCostLimit = 32 << 20; return cache
    }()
    /// Every target in reading order: the introduction (or the whole message when it has no headings), then sections, then code blocks.
    static func targets(in source: String) -> [MarkdownCopyTarget] {
        guard source.utf8.count <= maximumBytes else { return [] }
        let key = source as NSString
        if let cached = cache.object(forKey: key) { return cached.targets }
        let targets = scan(source)
        cache.setObject(CachedTargets(targets), forKey: key, cost: source.utf8.count)
        return targets
    }
    private static func scan(_ source: String) -> [MarkdownCopyTarget] {
        let lines = lines(of: source)
        var headings: [Heading] = []
        var codes: [String] = []
        var index = 0
        var previousBlank = true
        while index < lines.count {
            let line = lines[index]
            if let fence = fence(line.text) {
                // Collect until a matching closer; an unterminated fence runs to the end.
                var bodyEnd = source.endIndex
                var close = index + 1
                while close < lines.count {
                    let stripped = strippingPrefix(lines[close].text, fence.prefix)
                    let trimmed = stripped.drop { $0 == " " }
                    if indentation(stripped) <= 3, trimmed.prefix(while: { $0 == fence.character }).count >= fence.length, trimmed.drop(while: { $0 == fence.character }).allSatisfy({ $0 == " " || $0 == "\t" }) { bodyEnd = lines[close].start; break }
                    close += 1
                }
                if close >= lines.count { close = lines.count - 1 }
                var pieces: [String] = []
                var cursor = index + 1
                while cursor < lines.count, lines[cursor].start < bodyEnd {
                    let content = lines[cursor]
                    pieces.append(String(strippingPrefix(content.text, fence.prefix)) + String(source[content.end..<min(content.next, bodyEnd)]))
                    cursor += 1
                }
                let code = pieces.joined()
                if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { codes.append(code) }
                index = close + 1
                previousBlank = false
                continue
            }
            let blank = line.text.allSatisfy { $0 == " " || $0 == "\t" }
            if indentation(line.text) >= 4, previousBlank, !blank {
                // An indented code block: every following indented line, minus four spaces.
                var pieces: [String] = []
                var cursor = index
                while cursor < lines.count, !lines[cursor].text.allSatisfy({ $0 == " " || $0 == "\t" }), indentation(lines[cursor].text) >= 4 {
                    let content = lines[cursor]
                    pieces.append(String(content.text.dropFirst(4)) + (cursor + 1 < lines.count ? String(source[content.end..<content.next]) : ""))
                    cursor += 1
                }
                codes.append(pieces.joined())
                index = cursor
                previousBlank = false
                continue
            }
            if !isContainerLine(line.text) {
                if let heading = atxHeading(line.text), !blank {
                    headings.append(Heading(level: heading.level, title: heading.title, start: line.start))
                } else if !blank, !previousBlankIsHeadingBoundary(lines, index), index + 1 < lines.count, let level = setextUnderline(lines[index + 1].text), !lines[index + 1].text.isEmpty, !isContainerLine(lines[index + 1].text) {
                    headings.append(Heading(level: level, title: line.text.trimmingCharacters(in: .whitespaces), start: line.start))
                    index += 2; previousBlank = false; continue
                }
            }
            previousBlank = blank
            index += 1
        }
        var targets: [MarkdownCopyTarget] = []
        let introductionEnd = headings.first?.start ?? source.endIndex
        let introduction = String(source[source.startIndex..<introductionEnd])
        if !introduction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            targets.append(headings.isEmpty ? MarkdownCopyTarget(kind: .whole, label: "Copy as Markdown", text: introduction) : MarkdownCopyTarget(kind: .introduction, label: "Copy introduction as Markdown", text: introduction))
        }
        for (position, heading) in headings.enumerated() {
            let end = headings.dropFirst(position + 1).first { $0.level <= heading.level }?.start ?? source.endIndex
            let title = String(heading.title.prefix(100))
            targets.append(MarkdownCopyTarget(kind: .section(level: heading.level), label: "Copy \(title.isEmpty ? "section" : title) as Markdown", text: String(source[heading.start..<end])))
        }
        for code in codes { targets.append(MarkdownCopyTarget(kind: .code, label: "Copy code", text: code)) }
        return targets
    }
    /// A setext underline needs a paragraph line right above it; a line that is itself a heading never becomes one.
    private static func previousBlankIsHeadingBoundary(_ lines: [Line], _ index: Int) -> Bool { atxHeading(lines[index].text) != nil }
}
