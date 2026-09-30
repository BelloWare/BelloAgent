import AppKit
import FileView

actor FileSyntaxReader {
    struct Ink: Sendable { let range: Range<Int>; let kind: SyntaxHighlighter.TokenKind }
    private var checkpoints: [Int: SyntaxHighlighter.State] = [0: .init()]
    private var building: [Int: Task<SyntaxHighlighter.State?, Never>] = [:]
    private(set) var colouredLines = Set<Int>()
    typealias Load = @MainActor @Sendable (ClosedRange<Int>) async -> String?

    private func checkpoint(_ block: Int, language: SyntaxHighlighter.Language, load: @escaping Load) async -> SyntaxHighlighter.State? {
        if let state = checkpoints[block] { return state }
        if let task = building[block] { return await task.value }
        let task = Task { [weak self] () -> SyntaxHighlighter.State? in
            guard let self, var state = await self.checkpoint(block - 1, language: language, load: load),
                  let text = await load(((block - 1) * 128)...(block * 128 - 1)) else { return nil }
            state = SyntaxHighlighter.resume(text + "\n", language: language, state: state, collect: false).state
            return state
        }
        building[block] = task
        let state = await task.value
        building[block] = nil
        if let state { checkpoints[block] = state }
        return state
    }

    func tokens(line: Int, text: String, language: SyntaxHighlighter.Language, load: @escaping Load) async -> [Ink] {
        guard var state = await checkpoint(line / 128, language: language, load: load) else { return [] }
        let first = line / 128 * 128
        if line > first {
            guard let prefix = await load(first...(line - 1)) else { return [] }
            state = SyntaxHighlighter.resume(prefix + "\n", language: language, state: state, collect: false).state
        }
        let tokens = SyntaxHighlighter.resume(text, language: language, state: state).tokens
        colouredLines.insert(line)
        var offsets = [0]
        for scalar in text.unicodeScalars { offsets.append(offsets.last! + (scalar.value > 0xffff ? 2 : 1)) }
        return tokens.map { Ink(range: offsets[$0.range.lowerBound]..<offsets[$0.range.upperBound], kind: $0.kind) }
    }
}

/// Keeps token data for a small set of drawn lines. Loading checkpoint
/// text uses FileDocument's asynchronous, bounded reader; lexing runs on
/// the reader actor. CoreText receives colours only for the piece drawn.
@MainActor final class FileSyntax {
    private let source: FileDocument
    private let language: SyntaxHighlighter.Language
    private var reader = FileSyntaxReader()
    private var generation: Int
    private var pending = Set<Int>()
    private var cache: [Int: (text: String, ink: [FileSyntaxReader.Ink])] = [:]
    private weak var view: FileTextView?
    init?(source: FileDocument, view: FileTextView, extension name: String) {
        guard let language = SyntaxHighlighter.language(named: name) else { return nil }
        self.source = source; self.view = view; self.language = language; generation = source.generation
    }

    func colors(line: Int, piece: Range<Int>, text: String) -> [FileTextColorRun] {
        if generation != source.generation { generation = source.generation; reader = FileSyntaxReader(); cache = [:]; pending = [] }
        if let cached = cache[line] {
            return cached.ink.compactMap { token in
                let low = max(token.range.lowerBound, piece.lowerBound), high = min(token.range.upperBound, piece.upperBound)
                guard high > low else { return nil }
                let color: NSColor
                switch token.kind {
                case .keyword: color = NSColor(TranscriptPalette.keyword)
                case .string: color = NSColor(TranscriptPalette.string)
                case .number, .title: color = NSColor(TranscriptPalette.number)
                case .comment: color = NSColor(TranscriptPalette.comment)
                }
                return FileTextColorRun(range: NSRange(location: low - piece.lowerBound, length: high - low), color: color)
            }
        }
        let length = source.utf16Length(ofLine: line)
        guard length <= SyntaxHighlighter.limit, !pending.contains(line), let whole = source.text(ofLine: line, range: 0..<length) else { return [] }
        pending.insert(line)
        let reader = reader, asked = generation, language = language
        let load: FileSyntaxReader.Load = { [weak source] lines in
            guard let source, source.generation == asked else { return nil }
            return await withCheckedContinuation { continuation in
                source.fetch(from: FileTextPosition(line: lines.lowerBound, column: 0),
                             to: FileTextPosition(line: lines.upperBound, column: source.utf16Length(ofLine: lines.upperBound))) {
                    continuation.resume(returning: $0)
                }
            }
        }
        Task { [weak self] in
            let ink = await reader.tokens(line: line, text: whole, language: language, load: load)
            guard let self, self.source.generation == asked else { return }
            self.pending.remove(line)
            if self.cache.count >= 256, let oldest = self.cache.keys.min() { self.cache[oldest] = nil }
            self.cache[line] = (whole, ink)
            self.view?.invalidateSyntax(inLine: line)
        }
        return []
    }
}
