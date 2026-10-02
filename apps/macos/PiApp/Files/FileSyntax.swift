import AppKit
import FileView

/// The lexical state at line starts, found by reading the file forward in
/// bounded chunks from the nearest start already known. Every 128th start is
/// kept and the most recent others too, so the lines on screen cost a line
/// each, and lines asked for together share one pass: no read is bigger
/// than a chunk, however long the lines before them.
actor FileSyntaxReader {
    struct Ink: Sendable { let range: Range<Int>; let kind: SyntaxHighlighter.TokenKind }
    /// A bounded read from a position: its text, lines joined by "\n", where
    /// it stopped, and whether its line ends there.
    struct Chunk: Sendable { let text: String; let end: FileTextPosition; let endsLine: Bool }
    typealias Load = @MainActor @Sendable (FileTextPosition) async -> Chunk?
    /// Stops every pass of a reader no longer wanted; asked from anywhere.
    final class Stop: @unchecked Sendable {
        private let lock = NSLock(); private var stopped = false
        var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        func stop() { lock.lock(); stopped = true; lock.unlock() }
    }
    nonisolated let stop = Stop()
    static let recentLimit = 4_096
    private var blocks: [Int: SyntaxHighlighter.State] = [0: .init()]
    /// The lines of `blocks`, in order.
    private var blockLines = [0]
    private var recent: [Int: SyntaxHighlighter.State] = [:]
    private var recentOrder: [Int] = [], recentHead = 0
    private struct Pass { let from: Int; let to: Int; let task: Task<Bool, Never> }
    private var passes: [Int: Pass] = [:], passTickets = 0
    /// Test seams: lines coloured, chunks read, and the most scalars one lex was given.
    private(set) var colouredLines = Set<Int>()
    private(set) var chunkLoads = 0
    private(set) var largestLexInput = 0

    nonisolated func cancel() { stop.stop() }

    private func known(_ line: Int) -> SyntaxHighlighter.State? { line % 128 == 0 ? blocks[line] ?? recent[line] : recent[line] }
    /// The nearest line start at or before `line` whose state is known, in
    /// either cache: a line in a later block goes on from the lines last
    /// coloured, not from the start of the file.
    private func nearest(_ line: Int) -> (line: Int, state: SyntaxHighlighter.State) {
        var low = 0, high = blockLines.count - 1
        while low < high { let middle = (low + high + 1) / 2; if blockLines[middle] <= line { low = middle } else { high = middle - 1 } }
        var best = blockLines[low]
        for start in recent.keys where start <= line && start > best { best = start }
        return (best, recent[best] ?? blocks[best] ?? .init())
    }
    private func remember(_ line: Int, _ state: SyntaxHighlighter.State) {
        if line % 128 == 0, blocks.updateValue(state, forKey: line) == nil {
            var low = 0, high = blockLines.count
            while low < high { let middle = (low + high) / 2; if blockLines[middle] < line { low = middle + 1 } else { high = middle } }
            blockLines.insert(line, at: low)
        }
        if recent.updateValue(state, forKey: line) == nil {
            recentOrder.append(line)
            if recentOrder.count - recentHead > Self.recentLimit { recent[recentOrder[recentHead]] = nil; recentHead += 1 }
            if recentHead > Self.recentLimit { recentOrder.removeFirst(recentHead); recentHead = 0 }
        }
    }

    /// The state at the start of `line`: known, or found by the pass already
    /// reading through it, or by a new pass from the nearest known start.
    private func state(atLine line: Int, language: SyntaxHighlighter.Language, load: @escaping Load) async -> SyntaxHighlighter.State? {
        // Where a pass this waited for ended: a start known, though perhaps
        // in a block before the line's.
        var reached: Int?
        while !stop.isStopped {
            if let state = known(line) { return state }
            if let pass = passes.values.first(where: { $0.from < line && line <= $0.to }) {
                guard await pass.task.value else { return nil }; continue
            }
            var base = nearest(line)
            if let reached, reached > base.line, let state = known(reached) { base = (reached, state) }
            if let pass = passes.values.filter({ $0.to > base.line && $0.to < line }).max(by: { $0.to < $1.to }) {
                guard await pass.task.value else { return nil }
                reached = pass.to; continue
            }
            passTickets += 1
            let ticket = passTickets
            let task = Task { await self.pass(ticket, from: base.line, state: base.state, to: line, language: language, load: load) }
            passes[ticket] = Pass(from: base.line, to: line, task: task)
            guard await task.value else { return nil }
        }
        return nil
    }
    /// Lexes forward from the start of `from` to the start of `to`, a chunk
    /// at a time, remembering each line start it passes.
    /// A pass is forgotten as it ends, before anyone waiting on it resumes.
    private func pass(_ ticket: Int, from: Int, state: SyntaxHighlighter.State, to: Int, language: SyntaxHighlighter.Language, load: Load) async -> Bool {
        var advance = SyntaxHighlighter.Advance(language: language, state: state)
        var position = FileTextPosition(line: from, column: 0), line = from
        defer { largestLexInput = max(largestLexInput, advance.largestInput); passes[ticket] = nil }
        while line < to {
            guard !stop.isStopped, !Task.isCancelled, let chunk = await load(position), !stop.isStopped else { return false }
            guard chunk.end > position || chunk.endsLine else { return false }
            chunkLoads += 1
            let pieces = chunk.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, piece) in pieces.enumerated() {
                if index == pieces.count - 1, !chunk.endsLine { advance.feed(String(piece), endsLine: false); break }
                advance.feed(String(piece), endsLine: true)
                line += 1; remember(line, advance.state)
                if line >= to { break }
            }
            position = chunk.endsLine ? FileTextPosition(line: chunk.end.line + 1, column: 0) : chunk.end
        }
        return true
    }

    /// The line's colours. A line that is whole (`final`) also gives the
    /// state the next line starts in, so the line below costs one line; one
    /// the reading pass is still in may yet grow, and gives none.
    func tokens(line: Int, text: String, final: Bool = true, language: SyntaxHighlighter.Language, load: @escaping Load) async -> [Ink] {
        guard let state = await state(atLine: line, language: language, load: load), !stop.isStopped else { return [] }
        let tokens = SyntaxHighlighter.resume(text, language: language, state: state).tokens
        if final, known(line + 1) == nil { remember(line + 1, SyntaxHighlighter.resume(text + "\n", language: language, state: state, collect: false).state) }
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
    private(set) var reader = FileSyntaxReader()
    private var generation: Int
    private var pending = Set<Int>()
    private var cache: [Int: (text: String, ink: [FileSyntaxReader.Ink])] = [:]
    private weak var view: FileTextView?
    /// The most text one read for lexical state asks for, in UTF-16 units.
    static let chunkUnits = 64 << 10
    init?(source: FileDocument, view: FileTextView, extension name: String) {
        guard let language = SyntaxHighlighter.language(named: name) else { return nil }
        self.source = source; self.view = view; self.language = language; generation = source.generation
    }
    /// A closed tab's passes stop at their next chunk.
    deinit { reader.cancel() }

    func colors(line: Int, piece: Range<Int>, text: String) -> [FileTextColorRun] {
        if generation != source.generation { generation = source.generation; reader.cancel(); reader = FileSyntaxReader(); cache = [:]; pending = [] }
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
        let reader = reader, asked = generation, language = language, final = source.isLineFinal(line)
        let load: FileSyntaxReader.Load = { [weak source] start in
            guard let source, source.generation == asked else { return nil }
            let end = source.readEnd(from: start, units: Self.chunkUnits)
            let endsLine = end.column >= source.utf16Length(ofLine: end.line)
            guard let text = await withCheckedContinuation({ continuation in
                source.fetch(from: start, to: end) { continuation.resume(returning: $0) }
            }) else { return nil }
            return FileSyntaxReader.Chunk(text: text, end: end, endsLine: endsLine)
        }
        Task { [weak self] in
            let ink = await reader.tokens(line: line, text: whole, final: final, language: language, load: load)
            guard let self, self.source.generation == asked else { return }
            self.pending.remove(line)
            if self.cache.count >= 256, let oldest = self.cache.keys.min() { self.cache[oldest] = nil }
            self.cache[line] = (whole, ink)
            self.view?.invalidateSyntax(inLine: line)
        }
        return []
    }
}
