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

    func update(_ next: String, style: MarkdownStyle, streaming: Bool, identity: String = "") -> [StreamingMarkdownRecord] {
        guard next != source || self.style != style || streaming != wasStreaming || identity != messageID else { return records }
        let restarted = identity != messageID || (streaming && (wasStreaming == false || !next.hasPrefix(source)))
        let replacement = restarted || self.style != style || !next.hasPrefix(source)
        if replacement { generation &+= 1; settled.removeAll(keepingCapacity: true) }
        // A terminal payload can replace, rather than extend, the streamed
        // source. Equal text or equal offsets in that new source are not the
        // old blocks; only append/finalization may retain their identities.
        if replacement { records = [] }
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
            result += Self.tail(String(next[start...]), at: offset, generation: generation, style: style)
            settled = nextSettled; records = result
        } else {
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
        let located = TranscriptMarkdown.locatedBlocks(source, style: style)
        var components: [Int:Int] = [:]
        return located.enumerated().map { index, value in
            let start = offset + value.offset, component = components[start, default: 0]
            components[start] = component + 1
            let end = index+1 < located.count ? offset+located[index+1].offset : offset+source.utf8.count
            return StreamingMarkdownRecord(id: .init(generation: generation, sourceOffset: start, component: component),
                range: start..<max(start,end), block: value.block, provisional: false)
        }
    }
    private static func tail(_ source: String, at offset: Int, generation: UInt64, style: MarkdownStyle) -> [StreamingMarkdownRecord] {
        guard !source.isEmpty else { return [] }
        var block: MarkdownBlock = .paragraph(TranscriptMarkdown.inline(AttributedString(source), style: style, size: style.baseSize))
        // Only commit a fence once its info line is complete. Keep unfinished
        // closing markers in the literal code until the line confirms them.
        if let newline = source.firstIndex(of: "\n") {
            let opening = source[..<newline], trimmed = opening.drop(while: { $0 == " " })
            let indent = opening.count - trimmed.count
            if indent <= 3, let marker = trimmed.first, marker == "`" || marker == "~" {
                let length = trimmed.prefix(while: { $0 == marker }).count
                let info = trimmed.dropFirst(length)
                if length >= 3, marker != "`" || !info.contains("`") {
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
                    block = .code(language: language.isEmpty ? nil : language, code: code)
                    if let remainder, remainder < source.endIndex {
                        let end = offset + source[..<remainder].utf8.count
                        return [.init(id: .init(generation: generation, sourceOffset: offset), range: offset..<end, block: block, provisional: true)] + tail(String(source[remainder...]), at: end, generation: generation, style: style)
                    }
                }
            } else {
                // A confirmed delimiter row is the only provisional rich table
                // we accept. Foundation remains the authority for table syntax.
                let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
                if lines.count >= 3, lines[0].contains("|"), lines[1].contains("-"),
                   lines[1].allSatisfy({ " |-:\t\r".contains($0) }),
                   case .table = TranscriptMarkdown.blocks(source, style: style).first {
                    let parsed = canonical(source, at: offset, generation: generation, style: style)
                    guard let table = parsed.first else { return [] }
                    block = table.block
                    if parsed.count > 1 {
                        let consumed = parsed[1].id.sourceOffset - offset
                        let remainder = String(decoding: source.utf8.dropFirst(consumed), as: UTF8.self)
                        return [.init(id: .init(generation: generation, sourceOffset: offset), range: offset..<(offset+consumed), block: block, provisional: true)] + tail(remainder, at: offset+consumed, generation: generation, style: style)
                    }
                }
            }
        }
        return [.init(id: .init(generation: generation, sourceOffset: offset), range: offset..<(offset+source.utf8.count), block: block, provisional: true)]
    }
}
