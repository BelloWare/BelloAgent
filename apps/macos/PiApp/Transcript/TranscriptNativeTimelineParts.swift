import AppKit

// One part of a response at the position it arrived at, drawn by AppKit as
// `TimelinePartRow` drew it: the reply's words, the card of a call it made,
// or a work row (a thought, arguments being prepared, a provider's opaque
// item, a status) opening what it holds. Also a code block's small fence
// (`CodeBlockView`) and an execution record (`ExecutionTimelineRow`).

/// One response part, as a view another row places: its height at a width,
/// and a word when that height changed from inside.
@MainActor final class TranscriptNativePartView: NSView {
    struct Model {
        var part: ResponseTimeline.Segment
        var message: TranscriptMessage
        var actions: TranscriptActions
        var open: Bool
        var toggle: () -> Void
        var card: ToolView? = nil
        var cardOpen = false
        var fetched: ToolInputDocument? = nil
        var toggleCard: () -> Void = {}
        var raw = false
        /// The row's way to switch the reply to its source; nil where no
        /// conversation disclosure is reachable.
        var toggleRow: ((TranscriptDisclosure.Part) -> Void)? = nil
        /// The response's fold, first in the words' menu.
        var fold: (title: String, perform: () -> Void)? = nil
        var environment: TranscriptRowEnvironment
    }
    enum Kind { case words, card, work }
    static let evidenceFace = TranscriptPlainTextFace(size: 10.5, monospaced: false, lineSpacing: 0, label: "Evidence")
    static let warningFace = TranscriptPlainTextFace(size: 11, monospaced: false, lineSpacing: 0, label: "Warning")
    static let detailsFont = NSFont.systemFont(ofSize: 11)

    var sizeChanged: () -> Void = {}
    private(set) var kind: Kind = .work
    private(set) var reply: TranscriptNativeReplyRow?
    private(set) var action: TranscriptNativeActionRow?
    private(set) var line: TranscriptNativeWorkLine?
    private var code: TranscriptNativeCodeBlock?
    private var markdown: NativeMarkdownContainer?
    private var dots: TranscriptWaitingDots?
    private var evidence: TranscriptPlainTextView?
    private var truncatedNote: TranscriptPlainTextView?
    private(set) var details: TranscriptLinkButton?
    private var model: Model?
    override var isFlipped: Bool { true }

    static func kind(of part: ResponseTimeline.Segment, card: ToolView?) -> Kind {
        ["text", "refusal"].contains(part.part.kind) ? .words : card != nil ? .card : .work
    }
    /// What the part's words read as: the reply's prose block.
    static func wordsItem(_ source: TranscriptMessage) -> TranscriptItem {
        var block = TranscriptBlock(id: source.id, key: "part-words:" + source.id, turnID: nil, message: source, activity: [], tools: [],
                                    accounting: TurnAccounting(), startedAt: nil, endedAt: nil, modelMs: 0, toolMs: 0, live: source.isStreaming, turn: nil)
        block.presentation = .body
        return .block(block)
    }

    func update(_ model: Model) {
        self.model = model
        TranscriptAppearance.apply(model.environment, to: self)
        let row = TranscriptTimelinePart(part: model.part, message: model.message)
        let kind = Self.kind(of: model.part, card: model.card)
        if kind != self.kind { clear() }
        self.kind = kind
        switch kind {
        case .words:
            let inputs = TranscriptRowInputs(item: Self.wordsItem(row.source), fresh: false, actions: model.actions, width: bounds.width,
                                             environment: model.environment, disclosure: TranscriptRowDisclosure(raw: model.raw),
                                             toggle: model.toggleRow ?? { _ in })
            let reply = self.reply ?? {
                let reply = TranscriptNativeReplyRow(inputs: inputs)
                reply.sizeChanged = { [weak self] in self?.changed() }
                addSubview(reply); self.reply = reply
                return reply
            }()
            reply.offersSource = model.toggleRow != nil
            reply.fold = model.fold
            reply.apply(inputs)
        case .card:
            let action = self.action ?? {
                let action = TranscriptNativeActionRow()
                action.sizeChanged = { [weak self] in self?.changed() }
                addSubview(action); self.action = action
                return action
            }()
            action.update(tool: model.card!, open: model.cardOpen, fetched: model.fetched, environment: model.environment,
                          toggle: model.toggleCard, openFile: model.actions.openFile)
        case .work:
            configureWork(row, model)
        }
        needsLayout = true
    }
    private func clear() {
        for view in [reply, action, line, code, markdown, dots, evidence, truncatedNote, details] as [NSView?] { view?.removeFromSuperview() }
        reply = nil; action = nil; line = nil; code = nil; markdown = nil; dots = nil; evidence = nil; truncatedNote = nil; details = nil
    }
    private func changed() { needsLayout = true; sizeChanged() }

    private func configureWork(_ row: TranscriptTimelinePart, _ model: Model) {
        let part = model.part, running = row.source.isStreaming
        let line = self.line ?? { let line = TranscriptNativeWorkLine(); addSubview(line); self.line = line; return line }()
        let summary = row.reasoning ? TranscriptTimelineText.thinkSummary(part.text, running: running)
            : (part.part.kind == "status" ? "" : TranscriptActivity.firstLine(part.text))
        line.update(TranscriptNativeWorkLine.Content(icon: row.icon, title: row.title, summary: summary, state: row.state,
                                                     expandable: true, open: model.open, follow: row.reasoning && running),
                    link: nil, toggle: model.toggle, environment: model.environment)
        // What a closed row opens costs nothing: it is not built at all.
        guard model.open else {
            for view in [code, markdown, dots, evidence, truncatedNote, details] as [NSView?] { view?.removeFromSuperview() }
            code = nil; markdown = nil; dots = nil; evidence = nil; truncatedNote = nil; details = nil
            return
        }
        if part.part.kind == "toolArguments" {
            let code = self.code ?? {
                let code = TranscriptNativeCodeBlock(usesTextKit: TranscriptCodeTextView.enabled && (running || part.text.utf8.count >= TranscriptCodeTextView.minimumBytes))
                code.sizeChanged = { [weak self] in self?.changed() }
                addSubview(code); self.code = code
                return code
            }()
            code.update(code: part.text, language: "json", streaming: running, environment: model.environment)
        } else if let code { code.removeFromSuperview(); self.code = nil }
        if part.part.kind != "toolArguments", part.part.kind != "status" {
            let markdown = self.markdown ?? {
                let markdown = NativeMarkdownContainer()
                markdown.onSizeInvalidated = { [weak self] in self?.changed() }
                addSubview(markdown); self.markdown = markdown
                return markdown
            }()
            markdown.read(source: part.text, style: row.reasoning ? .reasoning : .prose, capsWidth: false, streaming: running, headings: [],
                          environment: model.environment, identity: "")
            let waiting = part.text.isEmpty && running
            if waiting, dots == nil { let dots = TranscriptWaitingDots(); addSubview(dots); self.dots = dots }
            dots?.running = waiting
            if !waiting, let dots { dots.running = false; dots.removeFromSuperview(); self.dots = nil }
        } else {
            markdown?.removeFromSuperview(); markdown = nil
            dots?.running = false; dots?.removeFromSuperview(); dots = nil
        }
        let evidence = self.evidence ?? { let text = TranscriptPlainTextView(); text.isSelectable = false; addSubview(text); self.evidence = text; return text }()
        let evidenceText = part.part.evidence == "observed" ? "Observed delivery order" : "\(part.part.evidence) · arrival timing unavailable"
        evidence.update(text: evidenceText, face: Self.evidenceFace, environment: model.environment, swiftUILines: true, color: TranscriptNSPalette.faint)
        evidence.setAccessibilityLabel(evidenceText)
        if part.truncated {
            let note = truncatedNote ?? { let text = TranscriptPlainTextView(); text.isSelectable = false; addSubview(text); self.truncatedNote = text; return text }()
            let text = "This older timeline fragment was saved without its remaining text."
            note.update(text: text, face: Self.warningFace, environment: model.environment, swiftUILines: true, color: TranscriptNSPalette.warning)
            note.setAccessibilityLabel(text)
        } else if let truncatedNote { truncatedNote.removeFromSuperview(); self.truncatedNote = nil }
        let details = self.details ?? {
            let button = TranscriptLinkButton()
            button.label.font = Self.detailsFont
            button.underlinesOnHover = false; button.pointsOnHover = false
            addSubview(button); self.details = button
            return button
        }()
        details.label.text = "Request details"
        details.label.color = TranscriptNSPalette.faint
        details.enabled = model.environment.isEnabled
        let actions = model.actions, id = model.message.id
        details.perform = { actions.inspect(id) }
    }

    // MARK: Geometry

    private var rightToLeft: Bool { model?.environment.layoutDirection == .rightToLeft }
    /// The work row's opened content, top down, at the content's width.
    private func stack(width: CGFloat) -> [(NSView, CGSize)] {
        var pieces: [(NSView, CGSize)] = []
        if let code { pieces.append((code, CGSize(width: width, height: code.height(width: width)))) }
        if let markdown {
            let measured = markdown.measure(width: width).height
            let waiting = (model?.part.text.isEmpty ?? false) && dots != nil
            pieces.append((markdown, CGSize(width: width, height: waiting ? max(TranscriptNativeReplyRow.waitingHeight, measured) : measured)))
        }
        for text in [evidence, truncatedNote] {
            if let text { pieces.append((text, CGSize(width: text.usedWidth(width: width), height: text.exactHeight(width: width)))) }
        }
        if let details { pieces.append((details, details.size)) }
        return pieces
    }
    /// The part's height at `width`, unrounded.
    func height(width: CGFloat) -> CGFloat {
        switch kind {
        case .words: return reply?.height(width: width) ?? 0
        case .card: return action?.height(width: max(0, width - 4)) ?? 0
        case .work:
            guard model?.open == true else { return TranscriptRowChrome.height }
            let pieces = stack(width: max(1, width - 4 - TranscriptRowChrome.indent))
            return TranscriptRowChrome.height + 4 + pieces.reduce(0) { $0 + $1.1.height } + 6 * CGFloat(max(0, pieces.count - 1)) + 4
        }
    }
    override func layout() {
        super.layout()
        let width = bounds.width
        switch kind {
        case .words: reply?.frame = bounds
        case .card:
            if let action { action.frame = TranscriptMotion.mirrored(CGRect(x: 4, y: 0, width: max(0, width - 4), height: action.height(width: max(0, width - 4))), width: width, rightToLeft) }
        case .work:
            line?.frame = TranscriptMotion.mirrored(CGRect(x: 4, y: 0, width: max(0, width - 4), height: TranscriptRowChrome.height), width: width, rightToLeft)
            guard model?.open == true else { return }
            let x = 4 + TranscriptRowChrome.indent, inner = max(1, width - x)
            var y = TranscriptRowChrome.height + 4
            for (view, size) in stack(width: inner) {
                var frame = CGRect(x: x, y: y, width: size.width, height: size.height)
                if view is TranscriptPlainTextView { frame.size.height = ceil(size.height) }
                if view === details { frame = pixelAligned(frame) }
                view.frame = TranscriptMotion.mirrored(frame, width: width, rightToLeft)
                if view === markdown, let dots {
                    dots.frame = TranscriptMotion.mirrored(CGRect(x: x, y: y, width: TranscriptWaitingDots.width, height: TranscriptNativeReplyRow.waitingHeight), width: width, rightToLeft)
                }
                y += size.height + 6
            }
        }
    }
    private func pixelAligned(_ rect: CGRect) -> CGRect { TranscriptMotion.pixelAligned(rect, scale: window?.backingScaleFactor ?? 2) }
}

/// One part of a chronological response as a row of its own: what
/// `BlockRowView` drew for a `.timeline` part, or a `.work` part carrying
/// its call's card. A folded turn or a response folded to its line empties it.
@MainActor final class TranscriptNativePartRow: TranscriptNativeBlockRow {
    let part = TranscriptNativePartView()
    static func parts(of item: TranscriptItem) -> (block: TranscriptBlock, part: ResponseTimeline.Segment, message: TranscriptMessage)? {
        guard case .block(let block) = item, block.presentation == .timeline || block.presentation == .work,
              let part = block.part, let message = block.message else { return nil }
        return (block, part, message)
    }
    override class func draws(_ item: TranscriptItem) -> Bool { parts(of: item) != nil }
    override var drawsNothing: Bool { inputs.disclosure.foldedAway || inputs.disclosure.responseLine }
    override init(inputs: TranscriptRowInputs) {
        super.init(inputs: inputs)
        part.sizeChanged = { [weak self] in self?.needsLayout = true; self?.owner?.contentSizeChanged() }
        addSubview(part)
        apply(inputs)
    }
    required init?(coder: NSCoder) { nil }
    override func configure() {
        guard let (block, segment, message) = Self.parts(of: inputs.item) else { return }
        let disclosure = inputs.disclosure, toggle = inputs.toggle
        // A card's fold is keyed by the reply that made the call.
        let card = (message.tools ?? []).first
        let key = card.map { ToolOccurrence.key(message.id, $0.id) }
        let response = block.responseID
        let fold: (title: String, perform: () -> Void)? = response.map { response in ("Fold This Response to One Line", { toggle(.responseLine(response)) }) }
        part.update(TranscriptNativePartView.Model(
            part: segment, message: message, actions: inputs.actions,
            open: disclosure.work && !disclosure.responseFolded, toggle: { toggle(.work(block.key)) },
            card: card, cardOpen: key.map { disclosure.openTools.contains($0) && !disclosure.responseFolded } ?? false,
            fetched: key.flatMap { disclosure.toolInputs[$0] }, toggleCard: { if let key { toggle(.tool(key)) } },
            raw: disclosure.raw, toggleRow: toggle, fold: fold, environment: inputs.environment))
        // The words are their own element (the reply's); a work row's line is.
        setAccessibilityElement(false)
    }
    override func apply(_ inputs: TranscriptRowInputs) {
        super.apply(inputs)
        setAccessibilityElement(false)
    }
    override func contentHeight(width: CGFloat) -> CGFloat { part.height(width: width) }
    override func place(in rect: CGRect) { part.frame = rect }
}

// MARK: - A code block's small fence

/// A code block as `CodeBlockView` draws it: the code in the transcript's
/// code face on its panel, coloured, and under the pointer its language and
/// a Copy. A small fence is set in SwiftUI's line boxes (`TranscriptPlainTextView`);
/// a large or streaming one is TextKit's own (`TranscriptCodeTextView`).
@MainActor final class TranscriptNativeCodeBlock: NSView {
    static let size: CGFloat = 12.5
    static let face = TranscriptPlainTextFace(size: size, monospaced: true, lineSpacing: size * 0.4, label: "Code")
    static let languageFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
    static let padding = (horizontal: CGFloat(14), top: CGFloat(31), bottom: CGFloat(10))
    let usesTextKit: Bool
    private let panel = TranscriptPanel()
    private var plain: TranscriptPlainTextView?
    private var native: TranscriptCodeTextView?
    private let language = TranscriptLabel()
    private let copy = TranscriptCopyButton()
    private var hover: TranscriptHoverTracker!
    private(set) var code = ""
    private var languageName: String?
    private var rightToLeft = false
    private var environment = TranscriptRowEnvironment()
    /// A long finished fence reads a section at a time (`CodeBlockSections`);
    /// Copy still takes all of it.
    private(set) var sections: [Range<Int>] = []
    private(set) var section = 0
    private var streaming = false
    private var navigation: TranscriptCodeSections?
    override var isFlipped: Bool { true }

    init(usesTextKit: Bool) {
        self.usesTextKit = usesTextKit
        super.init(frame: .zero)
        panel.cornerRadius = 10
        addSubview(panel)
        if usesTextKit {
            let text = TranscriptCodeTextView(); addSubview(text); native = text
        } else {
            let text = TranscriptPlainTextView(); text.isSelectable = false; text.codeLanguage = nil
            addSubview(text); plain = text
        }
        language.font = Self.languageFont
        for view in [language, copy] as [NSView] { view.alphaValue = 0; view.isHidden = true; addSubview(view) }
        hover = TranscriptHoverTracker(view: self) { [weak self] inside in self?.setHovering(inside) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { nil }

    func update(code: String, language name: String?, streaming: Bool, environment: TranscriptRowEnvironment) {
        TranscriptAppearance.apply(environment, to: self)
        // A fence still arriving is one leaf; asked about on every token, it splits nothing.
        if !code.hasSameUTF8(as: self.code) || streaming != self.streaming { sections = CodeBlockSections.ranges(code, enabled: !streaming) }
        self.streaming = streaming
        self.code = code; languageName = name; self.environment = environment
        rightToLeft = environment.layoutDirection == .rightToLeft
        section = min(section, max(0, sections.count - 1))
        let shown = sections.count > 1 ? CodeBlockSections.section(code, sections[section]) : code
        panel.fill = TranscriptNSPalette.codeBackground; panel.stroke = TranscriptNSPalette.hair
        if let plain {
            plain.codeLanguage = name
            plain.update(text: shown, face: Self.face, environment: environment, swiftUILines: true, color: TranscriptNSPalette.text)
        }
        native?.update(source: shown, language: name, size: Self.size, environment: environment)
        if sections.count > 1 {
            let navigation = self.navigation ?? {
                let navigation = TranscriptCodeSections()
                navigation.step = { [weak self] delta in self?.step(delta) }
                addSubview(navigation); self.navigation = navigation
                return navigation
            }()
            navigation.update(index: section, count: sections.count, environment: environment)
        } else if let navigation { navigation.removeFromSuperview(); self.navigation = nil }
        language.text = name?.lowercased() ?? ""
        language.color = TranscriptNSPalette.faint
        language.speak(name.map { "Language \($0)" })
        copy.target = MarkdownCopyTarget(kind: .code, label: "Copy code", text: code)
        copy.enabled = environment.isEnabled
        copy.rightToLeft = rightToLeft
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Copy code") { [weak self] in
            // A pane that takes no input copies nothing, as its Copy refuses.
            guard let self, self.environment.isEnabled else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.code, forType: .string)
            return true
        }])
        needsLayout = true
    }
    private func setHovering(_ inside: Bool) {
        for view in [language, copy] as [NSView] {
            if inside { view.isHidden = view === language && language.text.isEmpty }
            TranscriptMotion.fade(view, to: inside ? 1 : 0)
        }
    }
    private func textHeight(width: CGFloat) -> CGFloat {
        if let plain { return plain.exactHeight(width: width) }
        return native?.measure(width: width).height ?? 0
    }
    /// Steps to the next or the previous section, as the navigation's buttons do.
    var sizeChanged: () -> Void = {}
    func step(_ delta: Int) {
        let next = min(max(0, section + delta), max(0, sections.count - 1))
        guard next != section else { return }
        section = next
        update(code: code, language: languageName, streaming: false, environment: environment)
        sizeChanged()
    }
    func height(width: CGFloat) -> CGFloat {
        Self.padding.top + textHeight(width: max(1, width - 2 * Self.padding.horizontal)) + Self.padding.bottom
            + (navigation?.height(width: width) ?? 0)
    }
    override func layout() {
        super.layout()
        panel.frame = bounds
        let inner = max(1, bounds.width - 2 * Self.padding.horizontal)
        let text = CGRect(x: Self.padding.horizontal, y: Self.padding.top, width: inner, height: ceil(textHeight(width: inner)))
        plain?.frame = text; native?.frame = text
        if let navigation {
            let top = Self.padding.top + textHeight(width: inner) + Self.padding.bottom
            navigation.frame = CGRect(x: 0, y: top, width: bounds.width, height: navigation.height(width: bounds.width))
        }
        // The toolbar: the language and the Copy, eight points in from the
        // trailing edge and five down, on a 20-point line.
        let copySize = TranscriptCopyButton.size, label = language.intrinsicSize
        var x = bounds.width - 8 - copySize.width
        var frames: [(NSView, CGRect)] = [(copy, CGRect(x: x, y: 5 + (20 - copySize.height) / 2, width: copySize.width, height: copySize.height))]
        if !language.text.isEmpty {
            x -= 6 + label.width
            frames.append((language, CGRect(x: x, y: 5 + (20 - label.height) / 2, width: label.width, height: label.height)))
        }
        for (view, frame) in frames { view.frame = TranscriptMotion.mirrored(frame, of: view, width: bounds.width, rightToLeft) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.update(rect: bounds)
    }
    override func mouseEntered(with event: NSEvent) { hover.set(true) }
    override func mouseExited(with event: NSEvent) { hover.set(false) }
}

// MARK: - An execution record

/// A local execution record: its line, and once opened, each part it
/// recorded and whether it has its terminal receipt, as `ExecutionTimelineRow` drew it.
@MainActor final class TranscriptNativeExecutionRow: TranscriptNativeMessageRow {
    static let noReceiptFace = TranscriptPlainTextFace(size: 11, monospaced: false, lineSpacing: 0, label: "Warning")
    let line = TranscriptNativeLabelButton()
    private(set) var parts: [TranscriptNativePartView] = []
    private var noReceipt: TranscriptPlainTextView?
    override class func message(of item: TranscriptItem) -> TranscriptMessage? {
        guard case .message(let message) = item, message.kind == "execution" else { return nil }
        return message
    }
    override init(inputs: TranscriptRowInputs) {
        super.init(inputs: inputs)
        line.weight = .medium
        addSubview(line)
        apply(inputs)
    }
    required init?(coder: NSCoder) { nil }
    private var open: Bool { inputs.disclosure.compaction }
    override func configure() {
        let message = message, id = message.id, toggle = inputs.toggle
        line.update(title: message.detail ?? message.text, symbol: open ? "chevron.down" : "chevron.right",
                    environment: inputs.environment, toggle: { toggle(.compaction(id)) })
        line.setAccessibilityValue(open ? "Open" : "Closed")
        let segments = open && message.responseTimeline?.supported == true ? message.responseTimeline?.segments ?? [] : []
        while parts.count > segments.count { parts.removeLast().removeFromSuperview() }
        while parts.count < segments.count {
            let view = TranscriptNativePartView()
            view.sizeChanged = { [weak self] in self?.needsLayout = true; self?.owner?.contentSizeChanged() }
            addSubview(view); parts.append(view)
        }
        for (view, segment) in zip(parts, segments) {
            view.update(TranscriptNativePartView.Model(part: segment, message: message, actions: inputs.actions, open: true, toggle: {},
                                                       environment: inputs.environment))
        }
        if open, message.responseTimeline?.supported == true, message.responseTimeline?.terminal == nil {
            let text = noReceipt ?? { let text = TranscriptPlainTextView(); text.isSelectable = false; addSubview(text); noReceipt = text; return text }()
            text.update(text: "No terminal receipt yet", face: Self.noReceiptFace, environment: inputs.environment, swiftUILines: true, color: TranscriptNSPalette.warning)
            text.setAccessibilityLabel("No terminal receipt yet")
        } else if let noReceipt { noReceipt.removeFromSuperview(); self.noReceipt = nil }
        setAccessibilityLabel(nil)
    }
    private func stack(width: CGFloat) -> [(NSView, CGSize)] {
        var pieces: [(NSView, CGSize)] = [(line, line.size(offered: width))]
        for part in parts { pieces.append((part, CGSize(width: width, height: part.height(width: width)))) }
        if let noReceipt { pieces.append((noReceipt, CGSize(width: noReceipt.usedWidth(width: width), height: noReceipt.exactHeight(width: width)))) }
        return pieces
    }
    /// Eight points above and below; six between the pieces.
    override func contentHeight(width: CGFloat) -> CGFloat {
        let pieces = stack(width: width)
        return 8 + pieces.reduce(0) { $0 + $1.1.height } + 6 * CGFloat(max(0, pieces.count - 1)) + 8
    }
    override func place(in rect: CGRect) {
        var y = rect.minY + 8
        for (view, size) in stack(width: rect.width) {
            view.frame = CGRect(x: rect.minX, y: y, width: size.width, height: view is TranscriptPlainTextView ? ceil(size.height) : size.height)
            y += size.height + 6
        }
    }
}

/// A long fence's way between its sections, as `CodeBlockView` drew it:
/// Previous, where the reader is, Next, ten points in, the three sharing the
/// line as an `HStack` shares it and wrapping when it is short.
@MainActor final class TranscriptCodeSections: NSView {
    static let buttonFace = TranscriptPlainTextFace(size: NSFont.systemFontSize, monospaced: false, lineSpacing: 0, label: "Button")
    static let face = TranscriptPlainTextFace(size: PiKit.Font.captionSize, monospaced: false, lineSpacing: 0, label: "Code section")
    private let previous = TranscriptWrappingButton()
    private let next = TranscriptWrappingButton()
    private let label = TranscriptPlainTextView()
    var step: (Int) -> Void = { _ in }
    private var rightToLeft = false
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.isSelectable = false
        for view in [previous, label, next] as [NSView] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityIdentifier("codeSectionNavigation")
    }
    required init?(coder: NSCoder) { nil }
    var buttons: [TranscriptWrappingButton] { [previous, next] }
    func update(index: Int, count: Int, environment: TranscriptRowEnvironment) {
        rightToLeft = environment.layoutDirection == .rightToLeft
        let words = "Code section \(index + 1) of \(count) · Copy includes the full code"
        label.update(text: words, face: Self.face, environment: environment, swiftUILines: true, color: .piInkSecondary)
        label.setAccessibilityLabel(words)
        previous.update(title: "Previous section", enabled: environment.isEnabled && index > 0, environment: environment) { [weak self] in self?.step(-1) }
        next.update(title: "Next section", enabled: environment.isEnabled && index + 1 < count, environment: environment) { [weak self] in self?.step(1) }
        needsLayout = true
    }
    private func sizes(width: CGFloat) -> [CGSize] {
        let texts = [previous.text, label, next.text]
        let pieces = texts.map { text in TranscriptLinePiece.text(ideal: text.idealWidth, used: { text.usedWidth(width: max(1, $0)) },
                                                                  height: { text.exactHeight(width: max(1, $0)) }) }
        return TranscriptLineLayout.sizes(pieces, spacing: [8, 8], width: max(0, width - 20))
    }
    func height(width: CGFloat) -> CGFloat { 10 + (sizes(width: width).map(\.height).max() ?? 0) + 10 }
    override func layout() {
        super.layout()
        let sizes = sizes(width: bounds.width), line = sizes.map(\.height).max() ?? 0
        let frames = TranscriptLineLayout.frames(sizes, spacing: [8, 8], x: 10, midY: 10 + line / 2)
        for (view, frame) in zip([previous, label, next] as [NSView], frames) {
            view.frame = TranscriptMotion.mirrored(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: ceil(frame.height)), width: bounds.width, rightToLeft)
        }
    }
}

/// A plain button whose title wraps when it is offered less than its line.
@MainActor final class TranscriptWrappingButton: TranscriptNativeToggle {
    let text = TranscriptPlainTextView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        text.isSelectable = false; text.setAccessibilityElement(false)
        addSubview(text)
    }
    required init?(coder: NSCoder) { nil }
    func update(title: String, enabled: Bool, environment: TranscriptRowEnvironment, perform: @escaping () -> Void) {
        text.update(text: title, face: TranscriptCodeSections.buttonFace, environment: environment, swiftUILines: true,
                    color: enabled ? .labelColor : .tertiaryLabelColor)
        var state = environment; state.isEnabled = enabled
        set(environment: state, toggle: perform)
        setAccessibilityLabel(title)
    }
    override func layout() { super.layout(); text.frame = bounds }
}
