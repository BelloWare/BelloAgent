import Foundation

struct MarkdownBlockIdentity: Hashable {
    let generation: UInt64
    let sourceOffset: Int
    var component = 0
}

struct StreamingMarkdownRecord {
    let id: MarkdownBlockIdentity
    let range: Range<Int>
    let block: MarkdownBlock
    let provisional: Bool
}

/// One mounted message owns this state. Parsing is synchronous and bounded by
/// the existing display page/prefix; no token creates a task or parser queue.
/// Settled fragments are reused on append. A replacement/retry starts a new
/// generation, and completion reconciles with one full canonical parse so late
/// reference definitions are interpreted at document scope.
final class StreamingMarkdownState {
    private(set) var source = ""
    private(set) var generation: UInt64 = 0
    private(set) var revision: UInt64 = 0
    private(set) var records: [StreamingMarkdownRecord] = []
    private(set) var usesNative = false
    private var messageID = ""
    private var style: MarkdownStyle?
    private var wasStreaming: Bool?
    private var settled: [(range: Range<Int>, records: [StreamingMarkdownRecord])] = []
    /// The last reading of the still-arriving tail: the blocks of it that have
    /// closed already, and where the one still open begins. A token can only
    /// change the open block, so only that block is read again.
    private struct OpenTail {
        var source: String
        var offset: Int
        var closed: [StreamingMarkdownRecord]
        var openStart: Int
    }
    private var openTail: OpenTail?
    /// How many closed blocks of a tail this has been able to keep, and how
    /// many tails it has had to read whole: the evidence that a token's cost
    /// does not grow with the reply.
    private(set) var tailReuseCount = 0
    private(set) var tailFullReadCount = 0

    func update(_ next: String, style: MarkdownStyle, streaming: Bool, identity: String = "") -> [StreamingMarkdownRecord] {
        guard next != source || self.style != style || streaming != wasStreaming || identity != messageID else { return records }
        let restarted = identity != messageID || (streaming && (wasStreaming == false || !next.hasPrefix(source)))
        let terminalReplacement = wasStreaming == true && !streaming && !next.hasPrefix(source)
        let replacement = restarted || self.style != style || !next.hasPrefix(source)
        if replacement { generation &+= 1; settled.removeAll(keepingCapacity: true); openTail = nil }
        // A terminal payload can replace, rather than extend, the streamed
        // source. Equal text or equal offsets in that new source are not the
        // old blocks. Already-canonical editable/detail views still reconcile
        // their existing containers (e.g. an edit inside a selected code fence).
        if restarted || terminalReplacement { records = [] }
        source = next; self.style = style; messageID = identity; wasStreaming = streaming; revision &+= 1
        if streaming {
            var nextSettled: [(range: Range<Int>, records: [StreamingMarkdownRecord])] = []
            var start = next.startIndex, offset = 0
            var result: [StreamingMarkdownRecord] = []
            let cached = Dictionary(uniqueKeysWithValues: settled.map { ($0.range, $0.records) })
            for cut in TranscriptMarkdown.settledCuts(in: next) {
                let fragment = String(next[start..<cut]), end = offset + fragment.utf8.count
                let range = offset..<end
                let retained = cached[range]
                let parsed = retained ?? Self.canonical(fragment, at: offset, generation: generation, style: style).enumerated().map { index, value in
                    guard index == 0, let prior = records.first(where: { $0.provisional && $0.range.lowerBound == offset && Self.sameContainer($0.block, value.block) }) else { return value }
                    return StreamingMarkdownRecord(id: prior.id, range: value.range, block: value.block, provisional: false)
                }
                nextSettled.append((range, parsed)); result.append(contentsOf: parsed)
                start = cut; offset = end
            }
            result += tailRecords(String(next[start...]), at: offset, style: style)
            settled = nextSettled; records = result
        } else {
            openTail = nil
            let canonical = Self.canonical(next, at: 0, generation: generation, style: style)
            // A fence's first source run may start inside its opening line in
            // Foundation. Retain the streaming leaf when canonical source
            // positions differ only by the opening syntax, without matching
            // unrelated blocks by a hash of growing text.
            var used = Set<MarkdownBlockIdentity>()
            records = canonical.map { value in
                let prior = records.first { !used.contains($0.id) &&
                    ($0.id.sourceOffset == value.id.sourceOffset || ($0.range.contains(value.id.sourceOffset) && Self.sameContainer($0.block, value.block))) }
                var id = prior?.id ?? value.id
                while !used.insert(id).inserted { id.component += 1 }
                return StreamingMarkdownRecord(id: id, range: value.range, block: value.block, provisional: false)
            }
            settled.removeAll(keepingCapacity: false)
        }
        usesNative = usesNative || streaming || records.count >= NativeMarkdownSurface.minimumBlockCount
        return records
    }

    static func preview(_ source: String, style: MarkdownStyle) -> [StreamingMarkdownRecord] {
        let state = StreamingMarkdownState()
        return state.update(source, style: style, streaming: true)
    }
    private static func sameContainer(_ a: MarkdownBlock, _ b: MarkdownBlock) -> Bool {
        switch (a,b) {
        case (.paragraph,.paragraph),(.heading,.heading),(.code,.code),(.list,.list),(.quote,.quote),(.table,.table): true
        default: false
        }
    }
    private static func canonical(_ source: String, at offset: Int, generation: UInt64, style: MarkdownStyle) -> [StreamingMarkdownRecord] {
        records(TranscriptMarkdown.locatedBlocks(source, style: style), of: source, at: offset, generation: generation)
    }
    /// The same records for text that is still growing, parsed without
    /// remembering the answer: a tail makes a new cache key per token.
    private static func live(_ source: String, at offset: Int, generation: UInt64, style: MarkdownStyle) -> [StreamingMarkdownRecord] {
        records(TranscriptMarkdown.liveBlocks(source, style: style), of: source, at: offset, generation: generation)
    }
    private static func records(_ located: [(offset: Int, block: MarkdownBlock)], of source: String, at offset: Int, generation: UInt64) -> [StreamingMarkdownRecord] {
        var components: [Int:Int] = [:]
        return located.enumerated().map { index, value in
            let start = offset + value.offset, component = components[start, default: 0]
            components[start] = component + 1
            let end = index+1 < located.count ? offset+located[index+1].offset : offset+source.utf8.count
            return StreamingMarkdownRecord(id: .init(generation: generation, sourceOffset: start, component: component),
                range: start..<max(start,end), block: value.block, provisional: false)
        }
    }
    /// How much still-open text is read again for each token. One block this
    /// long without closing keeps the literal reading until it does close:
    /// re-reading it every token would cost more the longer it grew. The
    /// blocks that closed before it keep their canonical reading either way.
    static let tailParseLimit = 8_192

    /// The part of the reply that is still arriving, read again for this
    /// token. Everything in it that has closed is kept from the last reading —
    /// a token cannot change a block that a later block has already followed —
    /// so what is read again is one block, not the whole tail.
    private func tailRecords(_ source: String, at offset: Int, style: MarkdownStyle) -> [StreamingMarkdownRecord] {
        if let previous = openTail, previous.offset == offset,
           source.utf8.count > previous.source.utf8.count, source.utf8.starts(with: previous.source.utf8) {
            // A table is the one block that reaches forward: a line that is
            // only "|" so far reads as a paragraph and becomes a row of the
            // table above it as it grows. So a tail whose last closed block is
            // a table is read again from that table, not from the line after it.
            var head = previous.closed
            var from = previous.openStart
            if case .table = head.last?.block {
                from = head[head.count - 1].id.sourceOffset
                head.removeLast()
            }
            let open = from > offset ? String(decoding: source.utf8.dropFirst(from - offset), as: UTF8.self) : ""
            let parsed = from > offset ? Self.tail(open, at: from, generation: generation, style: style) : []
            if let last = parsed.last {
                tailReuseCount += 1
                let records = head + parsed
                openTail = OpenTail(source: source, offset: offset, closed: Array(records.dropLast()),
                                    openStart: last.id.sourceOffset)
                return records
            }
        }
        tailFullReadCount += 1
        let records = Self.tail(source, at: offset, generation: generation, style: style)
        guard let last = records.last else { openTail = nil; return records }
        openTail = OpenTail(source: source, offset: offset, closed: Array(records.dropLast()), openStart: last.id.sourceOffset)
        return records
    }
    /// The part of the reply that is still arriving. Everything that has
    /// closed already reads exactly as the finished reply will — a heading is
    /// a heading, a list item is a list item, `**bold**` is bold the moment
    /// its second marker lands — so the page never shows raw markup that then
    /// jumps. Only the one block still open is provisional, and the one thing
    /// Foundation must not be asked about is an unterminated fence: its
    /// opening line may still be arriving, and a partly arrived closing
    /// marker would be folded into the code.
    private static func tail(_ source: String, at offset: Int, generation: UInt64, style: MarkdownStyle) -> [StreamingMarkdownRecord] {
        guard !source.isEmpty else { return [] }
        func literal() -> [StreamingMarkdownRecord] {
            [.init(id: .init(generation: generation, sourceOffset: offset), range: offset..<(offset+source.utf8.count),
                   block: .paragraph(TranscriptMarkdown.inline(AttributedString(source), style: style, size: style.baseSize)), provisional: true)]
        }
        if let opening = fenceOpening(source) {
            // "```sw" is not yet a fence: its info string is still arriving.
            guard let newline = opening.lineEnd else { return literal() }
            return fence(source, marker: opening.marker, length: opening.length, info: opening.info, after: newline,
                         at: offset, generation: generation, style: style)
        }
        // A fence further down the tail is read the same way: what comes
        // before it is complete — a fence at the margin ends whatever block it
        // follows — and Foundation is never asked about an unterminated one.
        if let split = fenceLineStart(in: source) {
            let head = String(source[..<split])
            let parsed = live(head, at: offset, generation: generation, style: style)
                .map { StreamingMarkdownRecord(id: $0.id, range: $0.range, block: $0.block, provisional: true) }
            return parsed + tail(String(source[split...]), at: offset + head.utf8.count, generation: generation, style: style)
        }
        guard source.utf8.count <= tailParseLimit else { return literal() }
        let parsed = live(source, at: offset, generation: generation, style: style)
        guard !parsed.isEmpty else { return literal() }
        // Nothing inside the tail is settled: a block that has closed keeps
        // its reading from token to token, but only a cut — a blank line the
        // reply has moved past — promises it can never change again.
        return parsed.map { .init(id: $0.id, range: $0.range, block: $0.block, provisional: true) }
    }
    /// The tail's first line, when it opens a fence.
    private struct FenceOpening {
        var marker: Character
        var length: Int
        var info: Substring
        /// The end of the opening line, or nil while the line is still arriving.
        var lineEnd: String.Index?
    }
    /// Where the first line after the first one that opens a fence at the
    /// margin begins. A fence at the margin is always its own block, whatever
    /// it follows, so the text before it can be read on its own.
    private static func fenceLineStart(in source: String) -> String.Index? {
        var lineStart = source.startIndex
        while let newline = source[lineStart...].firstIndex(of: "\n") {
            lineStart = source.index(after: newline)
            guard lineStart < source.endIndex else { return nil }
            let line = source[lineStart...]
            let end = line.firstIndex(of: "\n") ?? source.endIndex
            guard let marker = source[lineStart..<end].first, marker == "`" || marker == "~" else { continue }
            let run = source[lineStart..<end].prefix(while: { $0 == marker })
            let info = source[lineStart..<end].dropFirst(run.count)
            if run.count >= 3, marker != "`" || !info.contains("`") { return lineStart }
        }
        return nil
    }
    private static func fenceOpening(_ source: String) -> FenceOpening? {
        let lineEnd = source.firstIndex(of: "\n")
        let opening = source[..<(lineEnd ?? source.endIndex)]
        let trimmed = opening.drop(while: { $0 == " " })
        guard opening.count - trimmed.count <= 3, let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let length = trimmed.prefix(while: { $0 == marker }).count
        let info = trimmed.dropFirst(length)
        guard length >= 3, marker != "`" || !info.contains("`") else { return nil }
        return FenceOpening(marker: marker, length: length, info: info, lineEnd: lineEnd)
    }
    /// The fence's literal code, up to its closing line if that has arrived;
    /// anything after the close is read as the tail that follows it.
    private static func fence(_ source: String, marker: Character, length: Int, info: Substring, after newline: String.Index,
                              at offset: Int, generation: UInt64, style: MarkdownStyle) -> [StreamingMarkdownRecord] {
        let body = source[source.index(after: newline)...]
        var code = "", cursor = body.startIndex
        var remainder: String.Index?
        while cursor < body.endIndex {
            let end = body[cursor...].firstIndex(of: "\n") ?? body.endIndex
            let line = body[cursor..<end], clean = line.trimmingCharacters(in: .whitespaces)
            let spaces = line.prefix(while: { $0 == " " }).count
            if end != body.endIndex, spaces <= 3, clean.count >= length, clean.allSatisfy({ $0 == marker }) { remainder = body.index(after: end); break }
            code += line
            if end != body.endIndex { code += "\n"; cursor = body.index(after: end) } else { cursor = end }
        }
        if code.hasSuffix("\n") { code.removeLast() }
        let language = info.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let block = MarkdownBlock.code(language: language.isEmpty ? nil : language, code: code)
        guard let remainder, remainder < source.endIndex else {
            return [.init(id: .init(generation: generation, sourceOffset: offset), range: offset..<(offset+source.utf8.count), block: block, provisional: true)]
        }
        // A closed fence keeps the provisional flag it had while it was
        // arriving: that is what lets the settling cut adopt this very block —
        // and with it the reader's selection inside the code — rather than
        // build a new one at whichever source position Foundation reports.
        let end = offset + source[..<remainder].utf8.count
        return [.init(id: .init(generation: generation, sourceOffset: offset), range: offset..<end, block: block, provisional: true)]
            + tail(String(source[remainder...]), at: end, generation: generation, style: style)
    }
}
