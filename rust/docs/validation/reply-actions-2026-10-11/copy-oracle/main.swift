// Builds each reply's text with Swift's own builder and assembler (as the
// table oracle does), then copies ranges of it with `MarkdownTextView.copyText`
// (NativeMarkdownSurface.swift lines 150-176, unchanged but for taking the
// storage as an argument): `oracle <corpus.json> > copies.json`.
//
// For every document it prints the text (as UTF-16 code units, so positions
// are unambiguous), and the copy of: the whole text, every range from one
// paragraph break to another, and a fixed set of pseudo-random ranges whose
// ends do not split a surrogate pair.
import AppKit

func copyText(_ storage: NSTextStorage, _ ranges: [NSRange]) -> String {
    let text = storage.string as NSString
    var result = ""
    for range in ranges {
        let clipped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard clipped.length > 0 else { continue }
        if !result.isEmpty { result += "\n" }
        var skippedMarker = NSRange(location: NSNotFound, length: 0)
        storage.enumerateAttributes(in: clipped) { attributes, run, _ in
            if attributes[.piChrome] != nil { return }
            if let marker = attributes[.piListMarker] as? String {
                // A marker counts once, however the selection cuts it.
                var whole = NSRange()
                _ = storage.attribute(.piListMarker, at: run.location, effectiveRange: &whole)
                guard whole != skippedMarker else { return }
                skippedMarker = whole
                result += marker
                return
            }
            let piece = text.substring(with: run)
            if piece == "\n", let copy = attributes[.piBlockBreak] as? String { result += copy; return }
            result += piece
        }
    }
    return result
}

let corpus = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String]
var seed: UInt64 = 0x5eed
func next(_ bound: Int) -> Int {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Int((seed >> 33) % UInt64(max(bound, 1)))
}

let output: [[String: Any]] = MainActor.assumeIsolated {
    corpus.map { source in
        let blocks = TranscriptMarkdown.parse(source, style: .prose)
        let builder = MarkdownTextBuilder()
        let context = MarkdownTextContext(style: .prose, capsWidth: true)
        let text = NSMutableAttributedString()
        var tail: MarkdownTextTail?
        var leadingBreak: String?
        var leadingAttributes: [NSAttributedString.Key: Any] = [:]
        for (index, block) in blocks.enumerated() {
            let identity = MarkdownBlockIdentity(generation: 1, sourceOffset: index)
            let paragraphs = builder.paragraphs(block, identity: identity, context: context,
                                                gap: text.length == 0 ? 0 : MarkdownTextLayout.blockGap, headingIndex: nil)
            // A block with nothing to show keeps the break of the one before.
            guard !paragraphs.isEmpty else { continue }
            let (part, next) = MarkdownTextAssembler.text(paragraphs, after: tail, leadingBreak: leadingBreak,
                                                           leadingAttributes: leadingAttributes)
            text.append(part)
            tail = next ?? tail
            leadingBreak = paragraphs.last?.breakCopy ?? "\n\n"
            let last = paragraphs[paragraphs.count - 1]
            var attributes = last.marks
            if part.length > 0 {
                for key in [NSAttributedString.Key.font, .paragraphStyle] {
                    if let value = part.attribute(key, at: part.length - 1, effectiveRange: nil) { attributes[key] = value }
                }
            }
            leadingAttributes = attributes
        }
        let storage = NSTextStorage(attributedString: text)
        let units = Array((storage.string as NSString).description.utf16)
        let length = storage.length
        func cut(_ at: Int) -> Bool { at > 0 && at < length && UTF16.isTrailSurrogate(units[at]) }
        var ranges: [NSRange] = [NSRange(location: 0, length: length)]
        var breaks: [Int] = [0]
        for (index, unit) in units.enumerated() where unit == 10 { breaks.append(index); breaks.append(index + 1) }
        breaks.append(length)
        for a in breaks { for b in breaks where b > a { ranges.append(NSRange(location: a, length: b - a)) } }
        if ranges.count > 400 { ranges = Array(ranges.prefix(400)) }
        for _ in 0..<60 where length > 0 {
            var a = next(length + 1), b = next(length + 1)
            if a > b { swap(&a, &b) }
            guard a < b, !cut(a), !cut(b) else { continue }
            ranges.append(NSRange(location: a, length: b - a))
        }
        let copies: [[Any]] = ranges.map { [$0.location, NSMaxRange($0), copyText(storage, [$0])] }
        return ["source": source, "text": units.map { Int($0) }, "copies": copies]
    }
}
let data = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
