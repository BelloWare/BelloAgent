import Foundation

struct MarkdownBlockIdentity: Hashable {
    let generation: UInt64
    let sourceOffset: Int
    var component = 0
    /// Which segment of a long list this is: a list is drawn a few items to
    /// a host, and each of those hosts is a block of its own.
    var segment = 0
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
///
/// A token costs what it adds, not what the reply already holds: the cuts are
/// found by a scanner that resumes at the line it has not seen the end of, a
/// settled fragment is read once, and a fence still arriving is read a line at
/// a time, so the only work that grows with the reply is copying the open
/// block's text into the block the page draws.
final class StreamingMarkdownState {
    private(set) var source = ""
    private(set) var generation: UInt64 = 0
    private(set) var revision: UInt64 = 0
    private(set) var records: [StreamingMarkdownRecord] = []
    /// How many of `records`, from the first, are exactly the records the last
    /// update returned: same identities, ranges and blocks. A token changes
    /// the reply's end, so a surface redraws from here and never walks the
    /// blocks before it.
    private(set) var unchangedPrefix = 0
    private(set) var usesNative = false
    private var messageID = ""
    private var style: MarkdownStyle?
    private var wasStreaming: Bool?
    /// The settled fragments, in order, each ending at a cut. A cut stays one
    /// however the reply grows, so while it arrives these are only added to,
    /// and their records stay at the front of `records`, where a token leaves
    /// them: it replaces only what follows them.
    private var settled: [Range<Int>] = []
    private var settledRecordCount = 0
    private var cuts = TranscriptMarkdown.CutScanner()
    /// The last reading of the still-arriving tail: its blocks, and where the
    /// part a token can change begins. A token can only change the block still
    /// open, so only that block is read again.
    private struct OpenTail {
        /// Where the tail begins, and how much of the reply it had.
        var offset: Int
        var end: Int
        var records: [StreamingMarkdownRecord]
        var openStart: Int
        /// The open block when it is a fence: its lines read so far.
        var fence: FenceReading?
        /// The open block once it has outgrown the parse limit: the reading it
        /// had when it got there.
        var frozen: FrozenReading?
        /// The open block when it is a list or a table: the items or rows that
        /// can no longer change, and where the one still arriving begins.
        var list: ListReading?
        var table: TableReading?
    }
    private var openTail: OpenTail?
    /// How many closed blocks of a tail this has been able to keep, and how
    /// many tails it has had to read whole: the evidence that a token's cost
    /// does not grow with the reply.
    private(set) var tailReuseCount = 0
    private(set) var tailFullReadCount = 0
    /// How many records at the tail's start the last reading kept as they were.
    private var tailKept = 0
    /// Bytes the cut scanner and the fence reader have looked at, in all.
    var cutBytesRead: Int { cuts.bytesRead }
    private(set) var fenceBytesRead = 0
    /// Tokens that read an open list or table an entry at a time, and the
    /// bytes those readings parsed: what a token on a long list costs.
    private(set) var entryReadCount = 0
    private(set) var entryBytesRead = 0

    func update(_ next: String, style: MarkdownStyle, streaming: Bool, identity: String = "") -> [StreamingMarkdownRecord] {
        guard !next.hasSameUTF8(as: source) || self.style != style || streaming != wasStreaming || identity != messageID else {
            unchangedPrefix = records.count
            return records
        }
        unchangedPrefix = 0
        // Bytes, not characters: a token only ever appends, and asking by
        // character walks the whole reply whenever it holds anything but ASCII.
        let extends = next.hasUTF8Prefix(source)
        let restarted = identity != messageID || (streaming && (wasStreaming == false || !extends))
        let terminalReplacement = wasStreaming == true && !streaming && !extends
        let replacement = restarted || self.style != style || !extends
        if replacement { generation &+= 1; settled.removeAll(keepingCapacity: true); settledRecordCount = 0; cuts = .init(); openTail = nil }
        // A terminal payload can replace, rather than extend, the streamed
        // source. Equal text or equal offsets in that new source are not the
        // old blocks. Already-canonical editable/detail views still reconcile
        // their existing containers (e.g. an edit inside a selected code fence).
        if restarted || terminalReplacement { records = [] }
        source = next; self.style = style; messageID = identity; wasStreaming = streaming; revision &+= 1
        if streaming {
            next.withUTF8Bytes { streamingRecords($0, style: style) }
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
            settledRecordCount = 0
            cuts = .init()
        }
        usesNative = usesNative || streaming || records.count >= NativeMarkdownSurface.minimumBlockCount
        return records
    }

    /// The reply while it arrives: its settled fragments, each read once, and
    /// the tail after the last cut.
    private func streamingRecords(_ bytes: UnsafeBufferPointer<UInt8>, style: MarkdownStyle) {
        cuts.advance(over: bytes)
        var offset = settled.last?.upperBound ?? 0
        var settling: [StreamingMarkdownRecord] = []
        for cut in cuts.offsets.dropFirst(settled.count) {
            let parsed = Self.canonical(Self.text(bytes, offset..<cut), at: offset, generation: generation, style: style).enumerated().map { index, value in
                // A block that was provisional keeps its identity as it settles,
                // and with it the reader's selection inside it.
                guard index == 0, let prior = records.first(where: { $0.provisional && $0.range.lowerBound == offset && Self.sameContainer($0.block, value.block) }) else { return value }
                return StreamingMarkdownRecord(id: prior.id, range: value.range, block: value.block, provisional: false)
            }
            settled.append(offset..<cut)
            settling += parsed
            offset = cut
        }
        let tail = tailRecords(bytes, from: offset, style: style)
        // Settled records stay where they are; so do the closed blocks of the
        // tail a token kept, unless a cut has just settled some of it anew.
        let kept = min(settledRecordCount, records.count)
        unchangedPrefix = kept + (settling.isEmpty ? min(tailKept, records.count - kept) : 0)
        records.removeSubrange(kept...)
        records += settling
        settledRecordCount = records.count
        records += tail
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
    private static func text(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: bytes[range]), as: UTF8.self)
    }
    private static func canonical(_ source: String, at offset: Int, generation: UInt64, style: MarkdownStyle) -> [StreamingMarkdownRecord] {
        records(TranscriptMarkdown.locatedBlocks(source, style: style), of: source, at: offset, generation: generation)
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
    /// Text that is still growing, parsed without remembering the answer: a
    /// tail makes a new cache key per token. Nothing in it is settled: a block
    /// that has closed keeps its reading from token to token, but only a cut —
    /// a blank line the reply has moved past — promises it can never change.
    private func live(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, style: MarkdownStyle) -> [StreamingMarkdownRecord] {
        let text = Self.text(bytes, range)
        return Self.records(TranscriptMarkdown.liveBlocks(text, style: style), of: text, at: range.lowerBound, generation: generation)
            .map { .init(id: $0.id, range: $0.range, block: $0.block, provisional: true) }
    }
    /// `live`, with where each item of each top-level list begins, in the reply.
    private func liveWithItems(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, style: MarkdownStyle) -> (records: [StreamingMarkdownRecord], items: [[Int]]) {
        let reading = TranscriptMarkdown.liveBlocksWithItems(Self.text(bytes, range), style: style)
        return (provisional(reading.blocks[...], end: range.upperBound) { range.lowerBound + $0 },
                reading.items.map { $0.map { range.lowerBound + $0 } })
    }
    /// Provisional records for blocks read from text that sits in the reply
    /// at `place(offset)`, the last of them running to `end`.
    private func provisional(_ located: ArraySlice<(offset: Int, block: MarkdownBlock)>, end: Int, place: (Int) -> Int) -> [StreamingMarkdownRecord] {
        var components: [Int: Int] = [:], result: [StreamingMarkdownRecord] = []
        var index = located.startIndex
        while index < located.endIndex {
            let start = place(located[index].offset), component = components[start, default: 0]
            components[start] = component + 1
            let next = located.index(after: index)
            let stop = next < located.endIndex ? place(located[next].offset) : end
            result.append(.init(id: .init(generation: generation, sourceOffset: start, component: component),
                                range: start..<max(start, stop), block: located[index].block, provisional: true))
            index = next
        }
        return result
    }
    /// Text shown as it is, unread.
    private func literal(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, style: MarkdownStyle) -> StreamingMarkdownRecord {
        .init(id: .init(generation: generation, sourceOffset: range.lowerBound), range: range,
              block: .paragraph(TranscriptMarkdown.inline(AttributedString(Self.text(bytes, range)), style: style, size: style.baseSize)),
              provisional: true)
    }

    /// How much still-open text is read again for each token. One block that
    /// grows longer than this without closing is not read again: it keeps the
    /// reading it had, and what arrives after it waits unread until it closes.
    /// The blocks that closed before it keep their canonical reading either way.
    static let tailParseLimit = 8_192

    /// The part of the reply that is still arriving, read again for this
    /// token. Everything in it that has closed is kept from the last reading —
    /// a token cannot change a block that a later block has already followed —
    /// so what is read again is one block, not the whole tail.
    private func tailRecords(_ bytes: UnsafeBufferPointer<UInt8>, from offset: Int, style: MarkdownStyle) -> [StreamingMarkdownRecord] {
        let end = bytes.count
        let previous = openTail
        openTail = nil
        tailKept = 0
        guard offset < end else { return [] }
        if var tail = previous, tail.offset == offset, end > tail.end {
            // A table is the one block that reaches forward: a line that is
            // only "|" so far reads as a paragraph and becomes a row of the
            // table above it as it grows. A table read a row at a time takes
            // that line itself (`readTable`); one that is not is read again
            // from the table while the block after it is still on the line
            // that was arriving.
            var from = tail.openStart
            var head = tail.records.filter { $0.range.lowerBound < from }
            if tail.frozen == nil, case .table = head.last?.block, from < tail.end, !bytes[from..<tail.end].contains(0x0a) {
                from = head.removeLast().range.lowerBound
            }
            let reading = read(bytes, from: from, style: style, tail: &tail, previous: tail.records.filter { $0.range.lowerBound >= from })
            if !reading.records.isEmpty {
                tailReuseCount += 1
                tailKept = head.count
                tail.records = head + reading.records; tail.end = end; tail.openStart = reading.open
                openTail = tail
                return tail.records
            }
        }
        tailFullReadCount += 1
        tailKept = 0
        var tail = OpenTail(offset: offset, end: end, records: [], openStart: offset)
        var reading = read(bytes, from: offset, style: style, tail: &tail, previous: nil)
        if reading.records.isEmpty, !bytes[offset..<end].allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0a || $0 == 0x0d }) {
            // A tail that reads as nothing yet — "#", "1.", "---" on their
            // own — is shown as it is, rather than as a gap.
            reading = ([literal(bytes, offset..<end, style: style)], offset)
        }
        guard !reading.records.isEmpty else { return [] }
        tail.records = reading.records; tail.openStart = reading.open
        openTail = tail
        return reading.records
    }

    /// The reply from `start` to its end, and where the part of it the next
    /// token can change begins. Everything that has closed reads exactly as
    /// the finished reply will — a heading is a heading, a list item is a list
    /// item, `**bold**` is bold the moment its second marker lands — so the
    /// page never shows raw markup that then jumps. Only the one block still
    /// open is provisional, and the one thing Foundation must not be asked
    /// about is an unterminated fence: its opening line may still be arriving,
    /// and a partly arrived closing marker would be folded into the code.
    private func read(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, style: MarkdownStyle, tail: inout OpenTail,
                      previous: [StreamingMarkdownRecord]?) -> (records: [StreamingMarkdownRecord], open: Int) {
        let end = bytes.count
        guard start < end else { return ([], start) }
        if let opening = Self.fenceOpening(bytes, at: start) {
            // "```sw" is not yet a fence: its info string is still arriving.
            guard let bodyStart = opening.bodyStart else { return ([literal(bytes, start..<end, style: style)], start) }
            let fence = readFence(bytes, opening: opening, start: start, bodyStart: bodyStart, tail: &tail)
            let id = MarkdownBlockIdentity(generation: generation, sourceOffset: start)
            guard let close = fence.close, close < end else {
                return ([.init(id: id, range: start..<end, block: fence.block, provisional: true)], start)
            }
            // A closed fence keeps the provisional flag it had while it was
            // arriving: that is what lets the settling cut adopt this very
            // block — and with it the reader's selection inside the code —
            // rather than build a new one at whichever source position
            // Foundation reports. What follows the close is read after it.
            let rest = read(bytes, from: close, style: style, tail: &tail, previous: previous?.filter { $0.range.lowerBound >= close })
            return ([.init(id: id, range: start..<close, block: fence.block, provisional: true)] + rest.records, rest.open)
        }
        // A block kept past the parse limit searches only what arrived since.
        if let frozen = tail.frozen, frozen.start == start, frozen.end <= end {
            return readPastLimit(bytes, from: start, frozen: frozen, style: style, tail: &tail)
        }
        // A list or table read an entry at a time reads the entry still arriving.
        if let list = tail.list, list.start == start, list.openItem < end, let reading = readList(bytes, list, style: style, tail: &tail) {
            return reading
        }
        if let table = tail.table, table.start == start, table.scanned <= end, let reading = readTable(bytes, table, style: style, tail: &tail) {
            return reading
        }
        tail.list = nil; tail.table = nil
        // A fence further down is read the same way: what comes before it is
        // complete — a fence at the margin ends whatever block it follows —
        // and Foundation is never asked about an unterminated one.
        var searched: Int?
        if let first = Self.newline(in: bytes, from: start, to: end) {
            let search = Self.fenceLine(bytes, from: first + 1)
            if let split = search.found {
                let rest = read(bytes, from: split, style: style, tail: &tail, previous: previous?.filter { $0.range.lowerBound >= split })
                return (live(bytes, start..<split, style: style) + rest.records, rest.open)
            }
            searched = search.resume
        }
        guard end - start <= Self.tailParseLimit else {
            let frozen: FrozenReading
            if let previous, previous.first?.range.lowerBound == start, let covered = previous.last?.range.upperBound,
               covered > start, covered <= end {
                // The block as it was drawn at the last token, exactly.
                frozen = FrozenReading(start: start, end: covered, records: previous, searched: searched)
            } else if let line = Self.lastNewline(in: bytes, from: start, to: min(end, start + Self.tailParseLimit)),
                      case let parsed = liveWithItems(bytes, start..<(line + 1), style: style), !parsed.records.isEmpty {
                // Nothing drawn yet: what fits within the limit, to a line's
                // end. A list or table that runs on past it is read on from
                // there an entry at a time, the whole of it formatted.
                if let open = beginStructure(bytes, parsed, lastLine: line + 1, end: line + 1, style: style, tail: &tail) {
                    let reading: (records: [StreamingMarkdownRecord], open: Int)?
                    if let list = tail.list { reading = readList(bytes, list, style: style, tail: &tail) }
                    else if let table = tail.table { reading = readTable(bytes, table, style: style, tail: &tail) }
                    else { reading = nil }
                    if let reading { return (parsed.records.filter { $0.range.lowerBound < open } + reading.records, reading.open) }
                    tail.list = nil; tail.table = nil
                }
                // Several blocks: every one but the last has closed — a later
                // block follows it on a line that has ended — so the reading
                // goes on from the last, as reading token by token would have.
                if let last = parsed.records.last?.range.lowerBound, last > start {
                    let rest = read(bytes, from: last, style: style, tail: &tail, previous: nil)
                    return (parsed.records.filter { $0.range.lowerBound < last } + rest.records, rest.open)
                }
                frozen = FrozenReading(start: start, end: line + 1, records: parsed.records, searched: searched)
            } else {
                return ([literal(bytes, start..<end, style: style)], start)
            }
            return readPastLimit(bytes, from: start, frozen: frozen, style: style, tail: &tail)
        }
        // Text Foundation reads as nothing — the blank lines after a closed
        // fence, an ordered item's number with nothing after it yet — is no
        // block here either: the whole tail read at once would not draw it,
        // and the finished reply does not. Only a tail that reads as nothing
        // at all is shown as it is (see `tailRecords`).
        let parsed = liveWithItems(bytes, start..<end, style: style)
        guard let last = parsed.records.last else { return ([], start) }
        // A list or table still open — the last block, or followed by nothing
        // but the line still arriving — is read from now on an entry at a time.
        let lastLine = Self.lastNewline(in: bytes, from: start, to: end).map { $0 + 1 } ?? start
        if let open = beginStructure(bytes, parsed, lastLine: lastLine, end: end, style: style, tail: &tail) {
            return (parsed.records, open)
        }
        return (parsed.records, last.range.lowerBound)
    }

    // MARK: A block past the parse limit

    /// An open block that has outgrown the parse limit, as it read when it
    /// got there, and the start of the first line after it not yet searched
    /// for a fence (nil until the block has a second line).
    private struct FrozenReading {
        let start: Int
        let end: Int
        let records: [StreamingMarkdownRecord]
        var searched: Int?
    }

    /// Re-reading an open block for every token would cost more the longer it
    /// grew, so one past the limit is not read again. It keeps the reading it
    /// last had — nothing already drawn formatted turns back into raw "- " or
    /// "**" — and what arrived after that reading is shown as it is until the
    /// block closes and its settled reading replaces both. A fence at the
    /// margin still ends it, and is read as a fence.
    private func readPastLimit(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, frozen: FrozenReading, style: MarkdownStyle,
                               tail: inout OpenTail) -> (records: [StreamingMarkdownRecord], open: Int) {
        let end = bytes.count
        var frozen = frozen
        tail.frozen = nil
        if let from = frozen.searched ?? Self.newline(in: bytes, from: start, to: end).map({ $0 + 1 }), from < end {
            let search = Self.fenceLine(bytes, from: from)
            frozen.searched = search.resume
            if let split = search.found {
                // A fence ends the block. One that opens on the line the kept
                // reading ended in takes that line from it: the block is read
                // again up to the fence, which is within the limit.
                let rest = read(bytes, from: split, style: style, tail: &tail, previous: nil)
                if split < frozen.end { return (live(bytes, start..<split, style: style) + rest.records, rest.open) }
                let unread = split > frozen.end ? [literal(bytes, frozen.end..<split, style: style)] : []
                return (frozen.records + unread + rest.records, rest.open)
            }
        }
        tail.frozen = frozen
        return (frozen.end < end ? frozen.records + [literal(bytes, frozen.end..<end, style: style)] : frozen.records, start)
    }

    // MARK: Lists and tables, an entry at a time

    /// The open block when it is a list: the items a later sibling has
    /// already followed, which can no longer change, and where the item still
    /// arriving begins. A token reads that item again, not the list. An item
    /// reads the same on its own as among its siblings — its lines decide it,
    /// and none of its siblings' do — so the list this draws is the list the
    /// whole text parses to.
    private struct ListReading {
        let start: Int
        let ordered: Bool
        let number: Int
        var items: [[MarkdownBlock]]
        var openItem: Int
    }

    /// The open block when it is a table: its header, the rows whose lines
    /// have ended — a row is one line, so those can no longer change — and
    /// where the row still arriving begins. A token reads the header and that
    /// row again, not the table.
    private struct TableReading {
        let start: Int
        /// Where the line after the delimiter row begins.
        let body: Int
        let alignments: [MarkdownAlignment]
        let header: [AttributedString]
        var rows: [[AttributedString]]
        var scanned: Int
    }

    /// Whether an item's text, read on its own from `start`, is the item
    /// `item` of a list of the same kind: that is what makes it safe to read
    /// it on its own from now on. An item whose first line is blank begins
    /// on a line before its first text, and does not pass.
    private static func readsAlone(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, ordered: Bool,
                                   as item: [MarkdownBlock], style: MarkdownStyle) -> Bool {
        guard !range.isEmpty else { return false }
        let located = TranscriptMarkdown.liveBlocks(text(bytes, range), style: style)
        guard let head = located.first, head.offset == 0, case .list(let kind, _, let items) = head.block, kind == ordered else { return false }
        return items == [item]
    }

    /// Where, from what the whole tail parsed to, a list or table can be read
    /// on an entry at a time: the last block, or the one before the blocks
    /// the line still arriving holds. Returns where it begins, which is where
    /// the next token's reading starts, or nil if there is none.
    private func beginStructure(_ bytes: UnsafeBufferPointer<UInt8>, _ parsed: (records: [StreamingMarkdownRecord], items: [[Int]]),
                                lastLine: Int, end: Int, style: MarkdownStyle, tail: inout OpenTail) -> Int? {
        var index = parsed.records.count - 1
        while index > 0, parsed.records[index].range.lowerBound >= lastLine { index -= 1 }
        guard index >= 0, parsed.items.count == parsed.records.count else { return nil }
        let record = parsed.records[index]
        let following = parsed.records.count > index + 1 ? parsed.records[index + 1].range.lowerBound : end
        switch record.block {
        case .list(let ordered, let number, let items):
            let starts = parsed.items[index]
            guard let last = starts.last, starts.count == items.count, starts.first == record.range.lowerBound,
                  Self.readsAlone(bytes, last..<end, ordered: ordered, as: items[items.count - 1], style: style) else { return nil }
            tail.list = ListReading(start: record.range.lowerBound, ordered: ordered, number: number, items: Array(items.dropLast()), openItem: last)
            return record.range.lowerBound
        case .table(let alignments, let header, let rows):
            // The header and delimiter rows are lines of their own, both ended.
            guard let headerEnd = Self.newline(in: bytes, from: record.range.lowerBound, to: following),
                  let delimiterEnd = Self.newline(in: bytes, from: headerEnd + 1, to: following) else { return nil }
            let body = delimiterEnd + 1
            var complete = 0, lineStart = body
            while let newline = Self.newline(in: bytes, from: lineStart, to: following) { complete += 1; lineStart = newline + 1 }
            if following < end {
                // Only the line still arriving follows: every row has ended.
                guard rows.count == complete else { return nil }
            } else {
                guard rows.count == complete || rows.count == complete + 1 else { return nil }
            }
            tail.table = TableReading(start: record.range.lowerBound, body: body, alignments: alignments, header: header,
                                      rows: Array(rows.prefix(complete)), scanned: lineStart)
            return record.range.lowerBound
        default:
            return nil
        }
    }

    /// The list, reading only the item still arriving. Nil when that item no
    /// longer reads as one of this list's — the list is then read whole.
    private func readList(_ bytes: UnsafeBufferPointer<UInt8>, _ list: ListReading, style: MarkdownStyle,
                          tail: inout OpenTail) -> (records: [StreamingMarkdownRecord], open: Int)? {
        let end = bytes.count
        var list = list
        tail.list = nil
        // A fence at the margin ends the list, and is read as a fence.
        var regionEnd = end
        if let first = Self.newline(in: bytes, from: list.openItem, to: end), let split = Self.fenceLine(bytes, from: first + 1).found { regionEnd = split }
        while true {
            // A reading that has to catch up does so a piece at a time, each
            // within the parse limit and ending at a line's end.
            var stop = regionEnd
            if stop - list.openItem > Self.tailParseLimit {
                guard let line = Self.lastNewline(in: bytes, from: list.openItem, to: list.openItem + Self.tailParseLimit) else { return nil }
                stop = line + 1
            }
            let base = list.openItem
            entryBytesRead += stop - base
            let parsed = TranscriptMarkdown.liveBlocksWithItems(Self.text(bytes, base..<stop), style: style)
            guard let head = parsed.blocks.first, head.offset == 0, case .list(let ordered, _, let items) = head.block, ordered == list.ordered,
                  let starts = parsed.items.first, starts.count == items.count, starts.first == 0 else { return nil }
            // Every item a later sibling has followed is settled, once the
            // last sibling reads on its own as it reads here.
            var settle = 0
            if items.count > 1, let last = starts.last,
               Self.readsAlone(bytes, (base + last)..<stop, ordered: ordered, as: items[items.count - 1], style: style) { settle = items.count - 1 }
            if settle > 0 { list.items += items[0..<settle]; list.openItem = base + starts[settle] }
            let after = parsed.blocks.dropFirst()
            let listEnd = after.first.map { base + $0.offset } ?? stop
            let block = MarkdownBlock.list(ordered: list.ordered, start: list.number, items: list.items + items[settle...])
            var records = [StreamingMarkdownRecord(id: .init(generation: generation, sourceOffset: list.start), range: list.start..<listEnd,
                                                   block: block, provisional: true)]
            if stop < regionEnd {
                if after.isEmpty {
                    // One item longer than the limit cannot be read a piece at a time.
                    guard settle > 0 else { return nil }
                    continue
                }
                // The list ended inside this piece: what follows it is read on its own.
                let rest = read(bytes, from: listEnd, style: style, tail: &tail, previous: nil)
                return (records + rest.records, rest.open)
            }
            records += provisional(after, end: stop) { base + $0 }
            if regionEnd < end {
                let rest = read(bytes, from: regionEnd, style: style, tail: &tail, previous: nil)
                return (records + rest.records, rest.open)
            }
            // Still open, or followed only by the line still arriving, which
            // can yet become part of it: the next token reads it again.
            entryReadCount += 1
            if after.isEmpty || !bytes[listEnd..<end].contains(0x0a) {
                tail.list = list
                return (records, list.start)
            }
            // Closed: what follows it is read on its own, so that a list or
            // table among it is read an entry at a time in its turn.
            let rest = read(bytes, from: listEnd, style: style, tail: &tail, previous: nil)
            return ([records[0]] + rest.records, rest.open)
        }
    }

    /// The table, reading its header and the rows whose lines have not ended.
    /// Nil when those no longer read as rows of this table — it is then read
    /// whole.
    private func readTable(_ bytes: UnsafeBufferPointer<UInt8>, _ table: TableReading, style: MarkdownStyle,
                           tail: inout OpenTail) -> (records: [StreamingMarkdownRecord], open: Int)? {
        let end = bytes.count
        var table = table
        tail.table = nil
        // A blank line ends a table, and so does a fence at the margin: what
        // follows either is read on its own.
        var regionEnd = end, line = table.scanned
        while let newline = Self.newline(in: bytes, from: line, to: end) {
            if bytes[line..<newline].allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0d }) { regionEnd = line; break }
            line = newline + 1
        }
        if table.scanned < regionEnd, let split = Self.fenceLine(bytes, from: table.scanned).found, split < regionEnd { regionEnd = split }
        let header = Self.text(bytes, table.start..<table.body)
        let headerBytes = table.body - table.start
        while true {
            var stop = regionEnd
            if stop - table.scanned > Self.tailParseLimit {
                guard let line = Self.lastNewline(in: bytes, from: table.scanned, to: table.scanned + Self.tailParseLimit) else { return nil }
                stop = line + 1
            }
            let base = table.scanned
            entryBytesRead += headerBytes + stop - base
            let located = TranscriptMarkdown.liveBlocks(header + Self.text(bytes, base..<stop), style: style)
            guard let head = located.first, head.offset == 0, case .table(let alignments, let cells, let rows) = head.block,
                  alignments == table.alignments, cells == table.header else { return nil }
            let place = { (offset: Int) in base + offset - headerBytes }
            let after = located.dropFirst()
            let tableEnd = after.first.map { place($0.offset) } ?? stop
            guard tableEnd >= base else { return nil }
            // A row is a line: the rows whose lines have ended are settled.
            var complete = 0, lineStart = base
            while let newline = Self.newline(in: bytes, from: lineStart, to: tableEnd) { complete += 1; lineStart = newline + 1 }
            if after.isEmpty {
                guard rows.count == complete || rows.count == complete + 1 else { return nil }
            } else {
                guard rows.count == complete else { return nil }
            }
            table.rows += rows[0..<complete]; table.scanned = lineStart
            let block = MarkdownBlock.table(alignments: alignments, header: cells, rows: table.rows + rows[complete...])
            var records = [StreamingMarkdownRecord(id: .init(generation: generation, sourceOffset: table.start), range: table.start..<tableEnd,
                                                   block: block, provisional: true)]
            if stop < regionEnd {
                if after.isEmpty {
                    guard complete > 0 else { return nil }
                    continue
                }
                // The table ended inside this piece: what follows it is read on its own.
                let rest = read(bytes, from: tableEnd, style: style, tail: &tail, previous: nil)
                return (records + rest.records, rest.open)
            }
            records += provisional(after, end: stop, place: place)
            if regionEnd < end {
                let rest = read(bytes, from: regionEnd, style: style, tail: &tail, previous: nil)
                return (records + rest.records, rest.open)
            }
            // Still open, or followed only by the line still arriving, which
            // can yet become one of its rows: the next token reads it again.
            entryReadCount += 1
            if after.isEmpty || !bytes[tableEnd..<end].contains(0x0a) {
                tail.table = table
                return (records, table.start)
            }
            let rest = read(bytes, from: tableEnd, style: style, tail: &tail, previous: nil)
            return ([records[0]] + rest.records, rest.open)
        }
    }

    // MARK: Fences

    /// The tail's first line, when it opens a fence.
    private struct FenceOpening {
        var marker: UInt8
        var length: Int
        /// The opening line's indentation, taken off every line of code.
        var indent: Int
        var language: String?
        /// Where the first line of code begins, or nil while the opening line
        /// is still arriving.
        var bodyStart: Int?

        enum Line { case close, mayClose, code }
        /// What a line inside the fence is: its close; a line still arriving
        /// that is nothing yet but up to three spaces and a run of the fence's
        /// marker too short to close it, so it may still become the close; or
        /// code.
        func line(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Line {
            var index = range.lowerBound, spaces = 0
            while index < range.upperBound, bytes[index] == 0x20 { index += 1; spaces += 1 }
            guard spaces <= 3 else { return .code }
            var run = 0
            while index < range.upperBound, bytes[index] == marker { run += 1; index += 1 }
            let markers = index
            while index < range.upperBound, bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0d { index += 1 }
            guard index == range.upperBound else { return .code }
            if run >= length { return .close }
            return markers == range.upperBound ? .mayClose : .code
        }
        /// A line of code, less the indentation the opening line had and the
        /// carriage return of a CR LF line ending.
        func code(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> String {
            var start = range.lowerBound, end = range.upperBound
            while start < end, start - range.lowerBound < indent, bytes[start] == 0x20 { start += 1 }
            if end > start, bytes[end - 1] == 0x0d { end -= 1 }
            return StreamingMarkdownState.text(bytes, start..<end)
        }
    }

    /// A fence as far as it has been read: every line before `scanned` is in
    /// `code` already, so a token reads the line it extends and any after it,
    /// not every line of a long block again. A reference, so the code it
    /// collects has one owner and grows in place.
    private final class FenceReading {
        let start: Int
        let bodyStart: Int
        var scanned: Int
        var code = ""
        /// Just past the closing line, once one has arrived whole.
        var close: Int?
        init(start: Int, bodyStart: Int) { self.start = start; self.bodyStart = bodyStart; scanned = bodyStart }
    }

    /// Only the reply's first line may open a fence from up to three spaces
    /// in: anywhere else an indented fence may belong to the list item above
    /// it, so it is left to Foundation, as a fresh reading of the whole tail
    /// leaves it (see `fenceLine`).
    private static func fenceOpening(_ bytes: UnsafeBufferPointer<UInt8>, at start: Int) -> FenceOpening? {
        let end = bytes.count
        var index = start
        while start == 0, index < end, index - start <= 3, bytes[index] == 0x20 { index += 1 }
        guard index - start <= 3, index < end, bytes[index] == 0x60 || bytes[index] == 0x7e else { return nil }
        let indent = index - start, marker = bytes[index]
        var length = 0
        while index < end, bytes[index] == marker { length += 1; index += 1 }
        guard length >= 3 else { return nil }
        let lineEnd = newline(in: bytes, from: index, to: end)
        let info = index..<(lineEnd ?? end)
        // A backtick fence's info string may not contain a backtick.
        if marker == 0x60, bytes[info].contains(0x60) { return nil }
        let language = text(bytes, info).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return FenceOpening(marker: marker, length: length, indent: indent, language: language.isEmpty ? nil : language,
                            bodyStart: lineEnd.map { $0 + 1 })
    }

    /// The fence's literal code, up to its closing line if that has arrived,
    /// and where the text after the close begins. A last line that is still
    /// arriving and may yet become the close is held back: drawing it as code
    /// grows the block by a line the next token takes away. Once its run is as
    /// long as the opening one it is the close, so the block is the one the
    /// finished reply parses to.
    private func readFence(_ bytes: UnsafeBufferPointer<UInt8>, opening: FenceOpening, start: Int, bodyStart: Int,
                           tail: inout OpenTail) -> (block: MarkdownBlock, close: Int?) {
        let end = bytes.count
        let reading: FenceReading
        if let kept = tail.fence, kept.start == start, kept.bodyStart == bodyStart, kept.scanned <= end {
            reading = kept
        } else {
            reading = FenceReading(start: start, bodyStart: bodyStart)
        }
        while reading.close == nil, let newline = Self.newline(in: bytes, from: reading.scanned, to: end) {
            fenceBytesRead += newline + 1 - reading.scanned
            let line = reading.scanned..<newline
            if opening.line(bytes, line) == .close { reading.close = newline + 1; break }
            reading.code += opening.code(bytes, line)
            reading.code += "\n"
            reading.scanned = newline + 1
        }
        var code = reading.code, close = reading.close
        if close == nil, reading.scanned < end {
            let line = reading.scanned..<end
            fenceBytesRead += end - reading.scanned
            switch opening.line(bytes, line) {
            case .close: close = end
            case .mayClose: break
            case .code: code += opening.code(bytes, line)
            }
        }
        if code.hasSuffix("\n") { code.removeLast() }
        tail.fence = reading
        return (.code(language: opening.language, code: code), close)
    }

    // MARK: Bytes

    private static func newline(in bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> Int? {
        guard start < end, let base = bytes.baseAddress, let found = memchr(base + start, 0x0a, end - start) else { return nil }
        return UnsafeRawPointer(base).distance(to: UnsafeRawPointer(found))
    }
    private static func lastNewline(in bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> Int? {
        var index = end
        while index > start { index -= 1; if bytes[index] == 0x0a { return index } }
        return nil
    }
    /// The first line from `lineStart` on that opens a fence at the margin,
    /// and where a later search can resume if there is none: the start of the
    /// last line, which may still grow into one.
    private static func fenceLine(_ bytes: UnsafeBufferPointer<UInt8>, from lineStart: Int) -> (found: Int?, resume: Int) {
        let end = bytes.count
        var lineStart = lineStart
        while lineStart < end {
            let lineEnd = newline(in: bytes, from: lineStart, to: end)
            let first = bytes[lineStart], stop = lineEnd ?? end
            if first == 0x60 || first == 0x7e {
                var index = lineStart
                while index < stop, bytes[index] == first { index += 1 }
                if index - lineStart >= 3, first != 0x60 || !bytes[index..<stop].contains(0x60) { return (lineStart, lineStart) }
            }
            guard let lineEnd else { return (nil, lineStart) }
            lineStart = lineEnd + 1
        }
        return (nil, lineStart)
    }
}
