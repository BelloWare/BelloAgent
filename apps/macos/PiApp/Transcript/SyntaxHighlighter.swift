import Foundation
import SwiftUI

// Syntax colouring for code blocks, written here rather than taken from a
// library: a small scanner per language family that finds comments, strings,
// numbers, keywords and declared names. Anything it does not recognise stays
// plain, and code beyond the size limit is not coloured at all.

enum SyntaxHighlighter {
    static let limit = 16_384

    enum Language: String, CaseIterable, Sendable { case swift, typescript, javascript, python, json, bash }
    enum TokenKind: Sendable, Equatable { case keyword, string, number, comment, title }
    struct Token: Equatable, Sendable {
        let range: Range<Int>
        let kind: TokenKind
    }

    /// The language for a fence label, honouring the short aliases people type.
    static func language(named name: String) -> Language? {
        switch name.lowercased() {
        case "ts": return .typescript
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "py": return .python
        case "sh", "shell", "zsh": return .bash
        default: return Language(rawValue: name.lowercased())
        }
    }

    private struct Grammar {
        var lineComment: [String] = []
        var blockComment: (String, String)? = nil
        var quotes: [Character] = ["\""]
        var tripleQuotes = false
        var keywords: Set<String> = []
        var literals: Set<String> = []
        var declarations: Set<String> = []
        var hashComments: Bool { lineComment.contains("#") }
    }
    private static func grammar(_ language: Language) -> Grammar {
        switch language {
        case .swift:
            return Grammar(lineComment: ["//"], blockComment: ("/*", "*/"), quotes: ["\""],
                           keywords: ["func", "let", "var", "if", "else", "guard", "return", "for", "in", "while", "repeat", "switch", "case", "default", "break", "continue", "struct", "class", "enum", "protocol", "extension", "import", "init", "deinit", "self", "Self", "super", "throw", "throws", "try", "catch", "async", "await", "actor", "static", "private", "public", "internal", "fileprivate", "open", "final", "override", "mutating", "inout", "where", "as", "is", "some", "any", "defer", "do", "typealias", "associatedtype", "subscript", "get", "set", "willSet", "didSet", "lazy", "weak", "unowned", "convenience", "required", "indirect", "rethrows", "fallthrough", "operator", "precedencegroup", "nonisolated", "isolated", "consuming", "borrowing"],
                           literals: ["true", "false", "nil"], declarations: ["func", "class", "struct", "enum", "protocol", "extension", "actor", "typealias"])
        case .typescript, .javascript:
            return Grammar(lineComment: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"],
                           keywords: ["function", "const", "let", "var", "if", "else", "return", "for", "of", "in", "while", "do", "switch", "case", "default", "break", "continue", "class", "extends", "new", "this", "super", "import", "export", "from", "as", "throw", "try", "catch", "finally", "async", "await", "yield", "typeof", "instanceof", "void", "delete", "interface", "type", "enum", "implements", "public", "private", "protected", "readonly", "static", "declare", "namespace", "abstract", "keyof", "satisfies", "with"],
                           literals: ["true", "false", "null", "undefined", "NaN", "Infinity"], declarations: ["function", "class", "interface", "type", "enum", "namespace"])
        case .python:
            return Grammar(lineComment: ["#"], quotes: ["\"", "'"], tripleQuotes: true,
                           keywords: ["def", "class", "if", "elif", "else", "return", "for", "in", "while", "break", "continue", "pass", "import", "from", "as", "with", "try", "except", "finally", "raise", "lambda", "yield", "async", "await", "global", "nonlocal", "del", "assert", "and", "or", "not", "is", "match", "case"],
                           literals: ["True", "False", "None"], declarations: ["def", "class"])
        case .json:
            return Grammar(quotes: ["\""], literals: ["true", "false", "null"])
        case .bash:
            return Grammar(lineComment: ["#"], quotes: ["\"", "'"],
                           keywords: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function", "return", "local", "export", "set", "unset", "readonly", "declare", "shift", "exit", "source", "alias", "select"],
                           literals: ["true", "false"], declarations: ["function"])
        }
    }

    /// Tokens as ranges over the code's unicode scalars, in order and non-overlapping.
    static func tokens(_ code: String, language: Language) -> [Token] {
        guard code.utf8.count <= limit else { return [] }
        let grammar = grammar(language)
        let scalars = Array(code.unicodeScalars)
        var tokens: [Token] = []
        var index = 0
        func startsWith(_ prefix: String, at position: Int) -> Bool {
            let needle = Array(prefix.unicodeScalars)
            guard position + needle.count <= scalars.count else { return false }
            return Array(scalars[position..<position + needle.count]) == needle
        }
        func isWord(_ scalar: Unicode.Scalar) -> Bool { CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$" }
        var previousWord = ""
        while index < scalars.count {
            let scalar = scalars[index]
            // Comments to the end of the line.
            if let marker = grammar.lineComment.first(where: { startsWith($0, at: index) }), !(marker == "#" && language == .bash && index > 0 && scalars[index - 1] == "$") {
                var end = index
                while end < scalars.count, scalars[end] != "\n" { end += 1 }
                tokens.append(Token(range: index..<end, kind: .comment)); index = end; previousWord = ""; continue
            }
            if let (open, close) = grammar.blockComment, startsWith(open, at: index) {
                var end = index + open.unicodeScalars.count
                while end < scalars.count, !startsWith(close, at: end) { end += 1 }
                end = min(scalars.count, end + (end < scalars.count ? close.unicodeScalars.count : 0))
                tokens.append(Token(range: index..<end, kind: .comment)); index = end; previousWord = ""; continue
            }
            // Strings, with backslash escapes; Python's triple quotes span lines.
            if grammar.quotes.contains(Character(scalar)) {
                let triple = grammar.tripleQuotes && index + 2 < scalars.count && scalars[index + 1] == scalar && scalars[index + 2] == scalar
                var end = index + (triple ? 3 : 1)
                while end < scalars.count {
                    if scalars[end] == "\\" { end += 2; continue }
                    if triple { if end + 2 < scalars.count, scalars[end] == scalar, scalars[end + 1] == scalar, scalars[end + 2] == scalar { end += 3; break } }
                    else if scalars[end] == scalar { end += 1; break }
                    else if scalars[end] == "\n" && scalar != "`" { break }
                    end += 1
                }
                end = min(end, scalars.count)
                tokens.append(Token(range: index..<end, kind: .string)); index = end; previousWord = ""; continue
            }
            // Numbers: decimal, fractional, exponent and hex; not the middle of a word.
            if CharacterSet.decimalDigits.contains(scalar), index == 0 || !isWord(scalars[index - 1]) {
                var end = index + 1
                if scalar == "0", end < scalars.count, scalars[end] == "x" || scalars[end] == "X" {
                    end += 1
                    while end < scalars.count, CharacterSet(charactersIn: "0123456789abcdefABCDEF_").contains(scalars[end]) { end += 1 }
                } else {
                    while end < scalars.count, CharacterSet(charactersIn: "0123456789_").contains(scalars[end]) { end += 1 }
                    if end + 1 < scalars.count, scalars[end] == ".", CharacterSet.decimalDigits.contains(scalars[end + 1]) {
                        end += 1
                        while end < scalars.count, CharacterSet(charactersIn: "0123456789_").contains(scalars[end]) { end += 1 }
                    }
                    if end < scalars.count, scalars[end] == "e" || scalars[end] == "E" {
                        var probe = end + 1
                        if probe < scalars.count, scalars[probe] == "+" || scalars[probe] == "-" { probe += 1 }
                        if probe < scalars.count, CharacterSet.decimalDigits.contains(scalars[probe]) {
                            end = probe
                            while end < scalars.count, CharacterSet.decimalDigits.contains(scalars[end]) { end += 1 }
                        }
                    }
                }
                tokens.append(Token(range: index..<end, kind: .number)); index = end; previousWord = ""; continue
            }
            // Words: keywords, literals and the name declared right after a declaration keyword.
            if isWord(scalar), !CharacterSet.decimalDigits.contains(scalar) {
                var end = index + 1
                while end < scalars.count, isWord(scalars[end]) { end += 1 }
                let word = String(String.UnicodeScalarView(scalars[index..<end]))
                if grammar.keywords.contains(word) || grammar.literals.contains(word) { tokens.append(Token(range: index..<end, kind: .keyword)) }
                else if grammar.declarations.contains(previousWord) { tokens.append(Token(range: index..<end, kind: .title)) }
                previousWord = word; index = end; continue
            }
            if !scalar.properties.isWhitespace { previousWord = "" }
            index += 1
        }
        return tokens
    }

    /// The code as styled text: a monospaced base with the palette's colours on
    /// each token. Unknown languages and oversized code come back plain.
    private final class CachedText: Sendable {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }
    nonisolated(unsafe) private static let cache: NSCache<NSString, CachedText> = {
        let cache = NSCache<NSString, CachedText>(); cache.countLimit = 1_000; cache.totalCostLimit = 32 << 20; return cache
    }()
    static func attributed(_ code: String, language name: String?, size: CGFloat = 12.5) -> AttributedString {
        let key = "\(name ?? "")\u{0}\(size)\u{0}\(code)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        let value = colour(code, language: name, size: size)
        cache.setObject(CachedText(value), forKey: key, cost: code.utf8.count)
        return value
    }
    private static func colour(_ code: String, language name: String?, size: CGFloat) -> AttributedString {
        var result = AttributedString(code)
        result.font = .system(size: size, design: .monospaced)
        result.foregroundColor = TranscriptPalette.text
        guard let name, let language = language(named: name), code.utf8.count <= limit else { return result }
        // Tokens arrive in scalar order. Walk forward once instead of rebuilding
        // and counting the entire source prefix for every coloured run. Large
        // code fences used to spend quadratic time here before their first draw.
        var cursor = result.startIndex
        var scalarOffset = 0
        for token in tokens(code, language: language) {
            guard token.range.lowerBound >= scalarOffset,
                  let lower = result.unicodeScalars.index(cursor, offsetBy: token.range.lowerBound - scalarOffset, limitedBy: result.endIndex),
                  let upper = result.unicodeScalars.index(lower, offsetBy: token.range.count, limitedBy: result.endIndex) else { continue }
            cursor = upper; scalarOffset = token.range.upperBound
            let range = lower..<upper
            switch token.kind {
            case .keyword: result[range].foregroundColor = TranscriptPalette.keyword
            case .string: result[range].foregroundColor = TranscriptPalette.string
            case .number, .title: result[range].foregroundColor = TranscriptPalette.number
            case .comment:
                result[range].foregroundColor = TranscriptPalette.comment
                result[range].font = .system(size: size, design: .monospaced).italic()
            }
        }
        return result
    }
}
