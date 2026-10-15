import AppKit

/// Sub-agent prose uses the same native Markdown reader as assistant replies.
/// The viewport and initial native text are bounded; the cached parse and
/// searchable text retain the complete source.
@MainActor final class TranscriptAgentMarkdown: NSView, PiKit.WidthSizing {
    static let previewHeight: CGFloat = 168
    let markdown = NativeMarkdownContainer()
    let more = PiKit.Button("Show more", style: .ghost, compact: true)
    let copy = PiKit.Button("Copy", symbol: "doc.on.doc", style: .ghost, compact: true)
    private let label = TranscriptLabel()
    private let clip = PiKit.Box.ClipView()
    private let controls = PiKit.FlowView()
    private(set) var expanded = false
    private(set) var source = ""
    var changed: () -> Void = {}
    var isToolInput = false
    var accessibilityName: String?
    var title: String { get { label.text } set { label.text = newValue; label.speak(newValue) } }
    private var environment: TranscriptRowEnvironment?
    private var preparation: Task<Void, Never>?
    private var generation = UUID()
    private(set) var prepared = false
    private var reading: AgentMarkdownReading?
    private var visibleCharacters = 1_200
    private var expansion: Task<Void, Never>?
    var isComplete: Bool { reading.map { visibleCharacters >= $0.characters } ?? false }
    var awaitingFindText: Bool { !prepared || expanded && !isComplete }
    override var isFlipped: Bool { true }
    init(label title: String, identity: String) {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11.5, weight: .medium); label.color = TranscriptNSPalette.faint
        self.title = title
        clip.wantsLayer = true; clip.clipsToBounds = true
        clip.addSubview(markdown)
        controls.spacing = 8; controls.addSubview(more); controls.addSubview(copy)
        for view in [label, clip, controls] { addSubview(view) }
        setAccessibilityIdentifier("agent-markdown-" + identity)
        markdown.textView.setAccessibilityLabel(title)
        more.setAccessibilityIdentifier("agent-markdown-toggle-" + identity)
        copy.setAccessibilityIdentifier("agent-markdown-copy-" + identity)
        more.onPress = { [weak self] in guard let self else { return }; self.setExpanded(!self.expanded) }
        copy.onPress = { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(self.source, forType: .string)
        }
        markdown.textView.sourceCopy = { [weak self] ranges in
            guard let self else { return nil }
            return MarkdownSourceCopy.copy(self.source, rendered: self.markdown.textView.string, ranges: ranges)
        }
        markdown.onSizeInvalidated = { [weak self] in self?.sizeChanged() }
    }
    required init?(coder: NSCoder) { nil }
    deinit { preparation?.cancel(); expansion?.cancel() }
    func update(_ text: String, environment: TranscriptRowEnvironment, actions: TranscriptActions = .init()) {
        markdown.textView.resolveFile = actions.resolveReplyFile
        markdown.textView.openFile = actions.openFile.map { open in { path, lines in open(path, lines) } }
        markdown.textView.fileLinkIdentity = accessibilityIdentifier()
        copy.isEnabled = environment.isEnabled; more.isEnabled = environment.isEnabled
        copy.setAccessibilityLabel("Copy " + (accessibilityName ?? title).lowercased() + " as Markdown")
        guard text != source || self.environment != environment else { return }
        let replaced = text != source
        if replaced { expanded = false; reading = nil; visibleCharacters = 1_200 }
        source = text; self.environment = environment
        preparation?.cancel(); expansion?.cancel(); generation = UUID(); let generation = generation
        if let reading { adopt(reading); if expanded { finishExpansion() }; return }
        if text.utf8.count >= 16_384 {
            prepared = false; markdown.isHidden = true
            preparation = Task { [weak self] in
                let work = Task.detached(priority: .userInitiated) { AgentMarkdownReading.make(text) }
                let reading = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.adopt(reading); self.preparation = nil; self.sizeChanged()
                if self.expanded { self.finishExpansion() }
            }
        } else { adopt(AgentMarkdownReading.make(text)) }
    }
    private func adopt(_ reading: AgentMarkdownReading) {
        self.reading = reading
        guard let environment else { return }
        markdown.update(blocks: reading.prefix(visibleCharacters), style: .prose, capsWidth: true, streaming: false,
                        headings: reading.headings, environment: environment, sourceText: source)
        prepared = true; markdown.isHidden = false; needsLayout = true
    }
    func contains(_ query: String, flexible: Bool) -> Bool {
        guard let reading else { return false }
        return !transcriptRanges(of: query, in: reading.searchText as NSString, flexible: flexible).isEmpty
    }
    func setExpanded(_ value: Bool) {
        guard value != expanded else { return }
        expanded = value; expansion?.cancel()
        more.title = value ? "Show less" : "Show more"
        more.setAccessibilityLabel(more.title + " " + (accessibilityName ?? title).lowercased())
        if value { finishExpansion() }
        else if let reading { visibleCharacters = 1_200; adopt(reading) }
        sizeChanged()
    }
    private func finishExpansion() {
        guard let reading, !isComplete else { return }
        let generation = generation
        expansion = Task { [weak self] in
            // One surface and text storage retain selection and native Find;
            // only the additional blocks are built on each main-loop turn.
            while !Task.isCancelled {
                guard let self, self.expanded, self.generation == generation else { return }
                self.visibleCharacters += 1_200; self.adopt(reading); self.sizeChanged()
                if self.isComplete { self.expansion = nil; return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }
    private func sizeChanged() {
        needsLayout = true; PiKit.sizeChanged(self); changed()
    }
    private func plan(_ width: CGFloat) -> (text: CGFloat, shown: CGFloat, label: CGFloat, buttons: CGFloat) {
        let text = prepared ? markdown.measure(width: max(1, width)).height : 22
        let label = title.isEmpty ? 0 : self.label.intrinsicSize.height + 4
        return (text, expanded ? text : min(Self.previewHeight, text), label, controls.height(forWidth: max(1, width)))
    }
    func height(forWidth width: CGFloat) -> CGFloat {
        let p = plan(width); return p.label + p.shown + 4 + p.buttons
    }
    func height(width: CGFloat) -> CGFloat { height(forWidth: width) }
    override func layout() {
        super.layout()
        let p = plan(bounds.width)
        label.isHidden = title.isEmpty
        label.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, p.label - 4))
        clip.frame = CGRect(x: 0, y: p.label, width: bounds.width, height: p.shown)
        markdown.frame = CGRect(x: 0, y: 0, width: bounds.width, height: p.text)
        more.isHidden = p.text <= Self.previewHeight && isComplete
        more.title = expanded ? "Show less" : "Show more"
        more.setAccessibilityLabel(more.title + " " + (accessibilityName ?? title).lowercased())
        controls.frame = CGRect(x: 0, y: clip.frame.maxY + 4, width: bounds.width, height: p.buttons)
    }
}

/// Immutable reads use the transcript's shared parse cache. The preview cuts
/// parsed blocks, never Markdown source (which could change links or structure).
/// A large block is adopted incrementally using the same native text builder.
private struct AgentMarkdownReading: Sendable {
    var blocks: [MarkdownBlock]
    var headings: [MarkdownCopyTarget]
    var searchText: String
    var characters: Int
    static func make(_ source: String) -> Self {
        let blocks = TranscriptMarkdown.blocks(source)
        let text = TranscriptMarkdown.plainText(blocks)
        return .init(blocks: blocks, headings: TranscriptCopy.targets(in: source).filter { if case .section = $0.kind { return true }; return false },
                     searchText: text, characters: max(1, text.utf16.count))
    }
    func prefix(_ count: Int) -> [MarkdownBlock] {
        guard count < characters else { return blocks }
        var remaining = count
        func text(_ value: AttributedString) -> AttributedString {
            let end = value.characters.index(value.startIndex, offsetBy: min(remaining, value.characters.count))
            let result = AttributedString(value[..<end]); remaining = max(0, remaining - result.characters.count - 1)
            return result
        }
        func take(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
            var result: [MarkdownBlock] = []
            for block in blocks where remaining > 0 {
                switch block {
                case .paragraph(let value): result.append(.paragraph(text(value)))
                case .heading(let level, let value, let title): result.append(.heading(level: level, text(value), plain: title))
                case .code(let language, let value):
                    let part = String(value.prefix(remaining)); remaining = max(0, remaining - part.count - 1)
                    result.append(.code(language: language, code: part))
                case .quote(let nested): result.append(.quote(take(nested)))
                case .list(let ordered, let start, let items):
                    var kept: [[MarkdownBlock]] = []
                    for item in items where remaining > 0 { kept.append(take(item)) }
                    result.append(.list(ordered: ordered, start: start, items: kept))
                case .table(let alignments, let header, let rows):
                    let head = header.map { text($0) }
                    var kept: [[AttributedString]] = []
                    for row in rows where remaining > 0 { kept.append(row.map { text($0) }) }
                    result.append(.table(alignments: alignments, header: head, rows: kept))
                }
            }
            return result
        }
        return take(blocks)
    }
}

/// Copy the original spelling, including Markdown punctuation. Full selections
/// are exact; partial selections map parser source positions, never a search for
/// repeated words in the source. This runs only for an explicit copy operation.
enum MarkdownSourceCopy {
    static func copy(_ source: String, rendered: String, ranges: [NSRange]) -> String? {
        let output = rendered as NSString, input = source as NSString
        if ranges.contains(where: { $0.location == 0 && $0.length >= output.length }) { return source }
        guard let parsed = try? AttributedString(markdown: source, options: .init(allowsExtendedAttributes: true,
            failurePolicy: .returnPartiallyParsedIfPossible, appliesSourcePositionAttributes: true)) else { return nil }
        var spans: [(output: NSRange, input: NSRange, image: Bool)] = [], cursor = 0
        for run in parsed.runs {
            guard let position = run.markdownSourcePosition, let indices = Range<String.Index>(position, in: source) else { continue }
            let raw = NSRange(indices, in: source)
            let value = run.inlinePresentationIntent?.contains(.softBreak) == true ? " " : String(parsed.characters[run.range])
            guard !value.isEmpty, cursor <= output.length else { continue }
            let found = output.range(of: value, range: NSRange(location: cursor, length: output.length - cursor))
            guard found.location != NSNotFound else { continue }
            cursor = NSMaxRange(found)
            // A code run's position includes its fence. Locate its literal body
            // within that parser-owned range, not in another occurrence.
            let literal = input.range(of: value, range: raw)
            if literal.location != NSNotFound { spans.append((found, literal, run.imageURL != nil)) }
            else if let mapped = transformedSpans(input.substring(with: raw), rendered: value) {
                spans += mapped.map { (NSRange(location: found.location + $0.output.location, length: $0.output.length),
                                        NSRange(location: raw.location + $0.input.location, length: $0.input.length), run.imageURL != nil) }
            } else { spans.append((found, raw, run.imageURL != nil)) }
        }
        var copied: [String] = []
        for selection in ranges {
            var first: Int?, end: Int?
            for span in spans {
                let common = NSIntersectionRange(selection, span.output)
                guard common.length > 0 else { continue }
                var range = span.input
                if span.input.length == span.output.length {
                    range = NSRange(location: span.input.location + common.location - span.output.location, length: common.length)
                }
                if common == span.output { range = enclosingMarks(range, in: input, image: span.image) }
                first = min(first ?? range.location, range.location); end = max(end ?? NSMaxRange(range), NSMaxRange(range))
            }
            if let first, let end { copied.append(input.substring(with: NSRange(location: first, length: end - first))) }
        }
        return copied.isEmpty ? nil : copied.joined(separator: "\n")
    }
    /// Foundation gives a whole text run one source position even when an
    /// entity/escape inside it changes length. Map those authored tokens before
    /// applying a partial selection, preserving unrelated words in that run.
    private static func transformedSpans(_ source: String, rendered: String) -> [(output: NSRange, input: NSRange)]? {
        let input = source as NSString, output = rendered as NSString
        var spans: [(output: NSRange, input: NSRange)] = [], i = 0, o = 0
        func append(_ consumed: Int, _ produced: Int) {
            let next = (output: NSRange(location: o, length: produced), input: NSRange(location: i, length: consumed))
            if let last = spans.last, last.output.length == last.input.length, consumed == produced,
               NSMaxRange(last.input) == i, NSMaxRange(last.output) == o {
                spans[spans.count - 1].input.length += consumed; spans[spans.count - 1].output.length += produced
            } else { spans.append(next) }
            i += consumed; o += produced
        }
        while i < input.length, o < output.length {
            let character = input.character(at: i), expected = output.character(at: o)
            if character == 92, i + 1 < input.length, input.character(at: i + 1) == expected,
               (33...47).contains(expected) || (58...64).contains(expected) || (91...96).contains(expected) || (123...126).contains(expected) {
                append(2, 1); continue
            }
            if character == 38 {
                let end = input.range(of: ";", range: NSRange(location: i, length: min(64, input.length - i)))
                if end.location != NSNotFound {
                    let raw = input.substring(with: NSRange(location: i, length: end.location - i + 1))
                    if let parsed = try? AttributedString(markdown: raw) {
                        let decoded = String(parsed.characters), count = decoded.utf16.count
                        if decoded != raw, count > 0, count <= output.length - o,
                           output.substring(with: NSRange(location: o, length: count)) == decoded {
                            append(raw.utf16.count, count); continue
                        }
                    }
                }
            }
            if [10, 13].contains(character), expected == 32 {
                append(character == 13 && i + 1 < input.length && input.character(at: i + 1) == 10 ? 2 : 1, 1); continue
            }
            guard character == expected else { return nil }
            append(1, 1)
        }
        return i == input.length && o == output.length ? spans : nil
    }
    private static func enclosingMarks(_ range: NSRange, in text: NSString, image: Bool) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        while start > 0, end < text.length, [42, 95, 96, 126].contains(text.character(at: start - 1)), text.character(at: start - 1) == text.character(at: end) { start -= 1; end += 1 }
        if start > 0, text.character(at: start - 1) == 91, end + 1 < text.length, text.character(at: end) == 93,
           [40, 91].contains(text.character(at: end + 1)) {
            let closing: unichar = text.character(at: end + 1) == 40 ? 41 : 93
            var cursor = end + 2, depth = 1, quote: unichar?
            while cursor < text.length {
                let character = text.character(at: cursor)
                if character == 92, cursor + 1 < text.length { cursor += 2; continue }
                if let quoted = quote {
                    if character == quoted { quote = nil }
                    cursor += 1; continue
                }
                if closing == 41, [34, 39].contains(character), cursor > 0, [9, 10, 13, 32].contains(text.character(at: cursor - 1)) {
                    quote = character; cursor += 1; continue
                }
                if character == text.character(at: end + 1) { depth += 1 }
                if character == closing { depth -= 1; if depth == 0 {
                    start -= 1; end = cursor + 1
                    if image, start > 0, text.character(at: start - 1) == 33 { start -= 1 }
                    break
                } }
                cursor += 1
            }
        }
        return NSRange(location: start, length: end - start)
    }
}
