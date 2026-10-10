import Foundation

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

    /// The lexical state at a line boundary, or wherever a chunked advance
    /// stopped, independent of any UI. File viewers keep these checkpoints
    /// and colour only the lines requested.
    struct State: Equatable, Sendable {
        var commentDepth = 0
        var delimiter: String?
        var multiline = false
        var raw = false
        var previousWord = ""
        /// Inside a line comment that a chunk ended before its line did.
        var lineComment = false
        /// Inside a word longer than any keyword that a chunk ended in: the
        /// rest of it is skipped, and it names nothing.
        var longWord = false
    }
    /// A word longer than this is no keyword or declaration, so a chunked
    /// advance need not hold it whole.
    static let longestWord = 32

    static func resume(_ code: String, language: Language, state initial: State, collect: Bool = true) -> (tokens: [Token], state: State) {
        let run = lex(Array(code.unicodeScalars), from: 0, language: language, state: initial, collect: collect, final: true)
        return (run.tokens, run.state)
    }

    /// Lexes `scalars[from...]`; the scalars before `from` are only looked
    /// back at. Not final, it stops (`stop`) where a decision would need a
    /// scalar past the end — a delimiter, an escape or a word that may go
    /// on — so that lexing on from `stop` with what follows, in the state
    /// returned, gives the state lexing everything at once gives.
    static func lex(_ scalars: [Unicode.Scalar], from: Int, language: Language, state initial: State, collect: Bool,
                    final: Bool) -> (tokens: [Token], state: State, stop: Int) {
        let grammar = grammar(language), count = scalars.count
        var state = initial, index = from, tokens: [Token] = []
        func matches(_ text: String, _ at: Int) -> Bool {
            var position = at
            for scalar in text.unicodeScalars {
                guard position < count, scalars[position] == scalar else { return false }
                position += 1
            }
            return true
        }
        /// Whether deciding at `at` needs `width` scalars that have not come yet.
        func short(_ width: Int, _ at: Int) -> Bool { !final && at + width > count }
        func word(_ scalar: Unicode.Scalar) -> Bool { CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$" }
        func emit(_ start: Int, _ end: Int, _ kind: TokenKind) { if collect && end > start { tokens.append(Token(range: start..<end, kind: kind)) } }
        /// The rest of a block comment; false when the chunk ended first.
        func blockComment() -> Bool {
            while index < count {
                if short(2, index) { return false }
                if language == .swift, matches("/*", index) { state.commentDepth += 1; index += 2 }
                else if matches("*/", index) { state.commentDepth -= 1; index += 2; if state.commentDepth == 0 { return true } }
                else { index += 1 }
            }
            return true
        }
        /// The rest of a string; false when the chunk ended first.
        func string(escapes: Bool) -> Bool {
            guard let delimiter = state.delimiter else { return true }
            let width = max(2, delimiter.unicodeScalars.count)
            while index < count {
                if short(width, index) { return false }
                if matches(delimiter, index) { index += delimiter.unicodeScalars.count; state.delimiter = nil; return true }
                if escapes, scalars[index] == "\\" { index = min(count, index + 2); continue }
                if !state.multiline, scalars[index] == "\n" { state.delimiter = nil; return true }
                index += 1
            }
            return true
        }
        while index < count {
            let start = index
            if state.lineComment {
                while index < count, scalars[index] != "\n" { index += 1 }
                emit(start, index, .comment)
                if index == count, !final { break }
                state.lineComment = false; state.previousWord = ""; continue
            }
            if state.longWord {
                while index < count, word(scalars[index]) { index += 1 }
                if index == count, !final { break }
                state.longWord = false; state.previousWord = ""; continue
            }
            if state.commentDepth > 0 {
                let done = blockComment()
                emit(start, index, .comment); if !done { break }; continue
            }
            if state.delimiter != nil {
                let done = string(escapes: !state.raw)
                emit(start, index, .string); if !done { break }; continue
            }
            // A marker or a delimiter is at most three scalars.
            if short(3, index) { break }
            if let marker = grammar.lineComment.first(where: { matches($0, index) }), !(marker == "#" && language == .bash && index > 0 && scalars[index - 1] == "$") {
                while index < count, scalars[index] != "\n" { index += 1 }
                emit(start, index, .comment); state.previousWord = ""
                if index == count, !final { state.lineComment = true; break }
                continue
            }
            if grammar.blockComment != nil, matches("/*", index) {
                state.commentDepth = 1; index += 2
                let done = blockComment()
                emit(start, index, .comment); state.previousWord = ""; if !done { break }; continue
            }
            if grammar.quotes.contains(Character(scalars[index])) {
                let quote = String(scalars[index])
                let triple = (grammar.tripleQuotes || language == .swift) && matches(String(repeating: quote, count: 3), index)
                let delimiter = String(repeating: quote, count: triple ? 3 : 1)
                state.delimiter = delimiter; state.multiline = triple || quote == "`" || language == .bash
                index += delimiter.unicodeScalars.count
                let done = string(escapes: true)
                emit(start, index, .string); state.previousWord = ""; if !done { break }; continue
            }
            if word(scalars[index]) {
                index += 1
                while index < count, word(scalars[index]) { index += 1 }
                if index == count, !final {
                    // The word may go on in the next chunk: held back while it
                    // could still be a keyword, skipped once it cannot.
                    if index - start <= longestWord { index = start; break }
                    state.longWord = true; state.previousWord = ""; break
                }
                let value = String(String.UnicodeScalarView(scalars[start..<index]))
                if CharacterSet.decimalDigits.contains(scalars[start]) { emit(start, index, .number) }
                else if grammar.keywords.contains(value) || grammar.literals.contains(value) { emit(start, index, .keyword) }
                else if grammar.declarations.contains(state.previousWord) { emit(start, index, .title) }
                // Only a declaration keyword is ever looked back at.
                state.previousWord = index - start > longestWord ? "" : value; continue
            }
            if !scalars[index].properties.isWhitespace { state.previousWord = "" }
            index += 1
        }
        return (tokens, state, index)
    }

    /// Lexical state carried through text that arrives a chunk at a time,
    /// however the chunks cut it: the state after each line is the state
    /// `resume` gives the whole text. Only the few scalars a decision
    /// waits on are held between chunks.
    struct Advance {
        let language: Language
        private(set) var state: State
        private var held: [Unicode.Scalar] = []
        private var before: Unicode.Scalar?
        /// The most scalars one lex was given: the chunk and what was held.
        private(set) var largestInput = 0
        init(language: Language, state: State) { self.language = language; self.state = state }
        /// Lexes `text`; `endsLine` when a line break ends it, after which
        /// `state` is the state at the next line's start.
        mutating func feed(_ text: String, endsLine: Bool) {
            var scalars: [Unicode.Scalar] = []
            scalars.reserveCapacity(held.count + text.unicodeScalars.count + 2)
            if let before { scalars.append(before) }
            let from = scalars.count
            scalars += held; scalars += text.unicodeScalars
            if endsLine { scalars.append("\n") }
            largestInput = max(largestInput, scalars.count - from)
            let run = SyntaxHighlighter.lex(scalars, from: from, language: language, state: state, collect: false, final: endsLine)
            state = run.state
            if endsLine { held = []; before = nil; return }
            held = Array(scalars[run.stop...])
            if run.stop > from { before = scalars[run.stop - 1] }
        }
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
        scan(code, language: language).tokens
    }
    struct Scan { var tokens: [Token]; var checkpoints: [Int] }
    /// A checkpoint is outside a string/comment and has no pending declaration
    /// word. Re-entering here has the same lexical state as scanning the prefix.
    static func scan(_ code: String, language: Language, from start: Int = 0) -> Scan {
        guard code.utf8.count <= limit else { return Scan(tokens: [], checkpoints: []) }
        let grammar = grammar(language)
        let scalars = Array(code.unicodeScalars)
        var tokens: [Token] = []
        var index = start, checkpoints = [start]
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
            // The word before a line's end is read again only to ask whether
            // it declares the name that follows, so the line after any other
            // word is as neutral a place to resume as one after punctuation:
            // most code ends its lines in a word.
            if scalar == "\n", !grammar.declarations.contains(previousWord) { checkpoints.append(index) }
        }
        return Scan(tokens: tokens, checkpoints: checkpoints)
    }
}
