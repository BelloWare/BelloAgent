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
        markdown.bindCodeCopyTargets(reading.codeCopyTargets)
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
    var codeCopyTargets: [String]
    var searchText: String
    var characters: Int
    static func make(_ source: String) -> Self {
        let blocks = TranscriptMarkdown.blocks(source)
        let text = TranscriptMarkdown.plainText(blocks)
        var codes: [String] = []
        func collectCodes(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                switch block {
                case .code(_, let code): codes.append(code)
                case .quote(let nested): collectCodes(nested)
                case .list(_, _, let items): for item in items { collectCodes(item) }
                default: break
                }
            }
        }
        collectCodes(blocks)
        return .init(blocks: blocks, headings: TranscriptCopy.targets(in: source).filter { if case .section = $0.kind { return true }; return false },
                     codeCopyTargets: codes, searchText: text, characters: max(1, text.utf16.count))
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
