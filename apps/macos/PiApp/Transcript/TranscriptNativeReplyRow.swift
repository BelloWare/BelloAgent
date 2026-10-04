import AppKit

/// A reply's words, drawn by AppKit: the rendered markdown (or, when the
/// reader asked, its source exactly as it arrived), and under it one quiet
/// band whose actions show under the pointer. It reads and measures as
/// `MessageRowView` did inside a reply's body block.
@MainActor final class TranscriptNativeReplyRow: NSView, TranscriptRowContent {
    static let gap: CGFloat = 6
    static let bandHeight: CGFloat = 22
    static let bottom: CGFloat = 10
    /// Before the first token: three dots on a line of their own.
    static let waitingHeight: CGFloat = 22
    static let sourcePadding = CGSize(width: 14, height: 12)

    weak var owner: TranscriptRowContainer?
    private var inputs: TranscriptRowInputs
    private let markdown = NativeMarkdownContainer()
    private let quoteRegion = TranscriptQuoteRegionView()
    private var source: (panel: TranscriptPanel, text: TranscriptPlainTextView)?
    private let dots = TranscriptWaitingDots()
    /// The line under a reply that ended early: at the output limit, or for
    /// a reason the provider gave.
    /// Built only for a reply that ended early, so every other reply has one text.
    private var noticeText: TranscriptPlainTextView?
    private var notice: TranscriptPlainTextView {
        if let noticeText { return noticeText }
        let text = TranscriptPlainTextView(); text.isSelectable = false
        addSubview(text); noticeText = text
        return text
    }
    static let noticeFace = TranscriptPlainTextFace(size: 12, monospaced: false, lineSpacing: 0, label: "Notice")
    private let noticeIcon = TranscriptSymbol()
    /// The notice symbol's width as SwiftUI lays it out: its outline's.
    private var noticeIconWidth: CGFloat { noticeIcon.image?.alignmentRect.width ?? 0 }
    /// How much higher SwiftUI's row centres the symbol than the line's middle (measured).
    static let noticeIconLift: CGFloat = 0.625
    static let noticeFont = NSFont.systemFont(ofSize: 12)
    /// How a reply that failed or was stopped ended, over its words.
    private var failedLabel: TranscriptLabel?
    static let failedFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    /// Under a saved fragment whose text was not kept whole.
    private var truncatedText: TranscriptPlainTextView?
    static let truncatedNote = "This older saved fragment is incomplete; the original text was not retained."
    static let truncatedFace = TranscriptPlainTextFace(size: 12, monospaced: false, lineSpacing: 0, label: "Note")
    private lazy var band = TranscriptPillBand(host: self)
    private var hover: TranscriptHoverTracker!
    private var hovering = false
    /// The pointer over the reply's words, where its Copy shows.
    private var bodyHover: TranscriptHoverTracker!
    private var copy: TranscriptCopyButton?
    override var isFlipped: Bool { true }

    static func reply(of item: TranscriptItem) -> TranscriptMessage? {
        guard case .block(let block) = item, block.presentation == .body, let message = block.message else { return nil }
        return message
    }
    /// Whether this row can draw `item`: a reply's body with none of the
    /// parts not ported yet.
    static func draws(_ item: TranscriptItem) -> Bool {
        guard let message = reply(of: item) else { return false }
        return message.role == "assistant" && message.kind == nil
    }

    init(inputs: TranscriptRowInputs) {
        self.inputs = inputs
        super.init(frame: .zero)
        addSubview(quoteRegion)
        addSubview(markdown)
        addSubview(dots)
        addSubview(noticeIcon)
        noticeIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        noticeIcon.setAccessibilityElement(false)
        markdown.onSizeInvalidated = { [weak self] in self?.owner?.contentSizeChanged() }
        hover = TranscriptHoverTracker(view: self) { [weak self] inside in self?.hovering = inside; self?.refreshBand() }
        bodyHover = TranscriptHoverTracker(view: self) { [weak self] _ in self?.refreshCopy() }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        apply(inputs)
    }
    required init?(coder: NSCoder) { nil }

    func accepts(_ item: TranscriptItem) -> Bool { Self.draws(item) }
    /// Anything that says this content's size changed tells the row, as the
    /// SwiftUI host's intrinsic size did.
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        owner?.contentSizeChanged()
    }

    private var message: TranscriptMessage { Self.reply(of: inputs.item) ?? TranscriptMessage(id: "", role: "assistant", text: "") }
    /// Whether the reply draws a body at all: a reply that only called tools
    /// keeps its row for its anchors and receipts and shows no words.
    private var drawsBody: Bool {
        let message = message
        return !(message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(message.tools ?? []).isEmpty)
    }
    private var raw: Bool { ReplySource.shows(message, raw: inputs.disclosure.raw) }
    private var drawsNothing: Bool { inputs.disclosure.foldedAway || inputs.disclosure.responseLine }

    func apply(_ inputs: TranscriptRowInputs) {
        self.inputs = inputs
        TranscriptAppearance.apply(inputs.environment, to: self)
        let message = message
        let copyTargets = !message.isStreaming ? TranscriptCopy.targets(in: message.text) : []
        let headings = copyTargets.filter { if case .section = $0.kind { return true }; return false }
        markdown.read(source: message.text, style: .prose, capsWidth: true, streaming: message.isStreaming, headings: headings,
                      environment: inputs.environment, identity: message.id)
        markdown.park(raw)
        markdown.textView.resolveFile = inputs.actions.resolveReplyFile
        if let open = inputs.actions.openFile { markdown.textView.openFile = { path, lines in open(path, lines) } }
        else { markdown.textView.openFile = nil }
        markdown.textView.fileLinkIdentity = message.id
        quoteRegion.messageID = message.id
        if raw {
            let parts = source ?? {
                let panel = TranscriptPanel(); panel.cornerRadius = 10
                let text = TranscriptPlainTextView()
                text.setAccessibilityIdentifier("reply-source")
                addSubview(panel); addSubview(text)
                return (panel, text)
            }()
            source = parts
            parts.panel.fill = TranscriptNSPalette.codeBackground; parts.panel.stroke = TranscriptNSPalette.hair
            parts.text.update(text: message.text, face: .source, environment: inputs.environment,
                              swiftUILines: !TranscriptPlainText.usesTextKit(message.text))
        } else if let parts = source {
            parts.panel.removeFromSuperview(); parts.text.removeFromSuperview(); source = nil
        }
        dots.running = message.text.isEmpty && message.isStreaming
        let early = MessageRowView.earlyEnd(message.stopReason)
        if let early {
            notice.update(text: early, face: Self.noticeFace, environment: inputs.environment, swiftUILines: true, color: TranscriptNSPalette.warning)
            notice.setAccessibilityLabel(early)
            notice.setAccessibilityIdentifier(message.stopReason == "length" ? "reply-output-limit" : "reply-ended-early")
        } else if let noticeText {
            noticeText.removeFromSuperview(); self.noticeText = nil
        }
        noticeIcon.contentTintColor = TranscriptNSPalette.warning
        if let failed = message.failedEnd {
            let label = failedLabel ?? { let label = TranscriptLabel(); label.font = Self.failedFont; addSubview(label); failedLabel = label; return label }()
            label.text = failed; label.color = TranscriptNSPalette.danger
            label.speak(failed)
        } else if let failedLabel {
            failedLabel.removeFromSuperview(); self.failedLabel = nil
        }
        if message.truncated == true {
            let text = truncatedText ?? { let text = TranscriptPlainTextView(); text.isSelectable = false; addSubview(text); truncatedText = text; return text }()
            text.update(text: Self.truncatedNote, face: Self.truncatedFace, environment: inputs.environment, swiftUILines: true, color: TranscriptNSPalette.muted)
        } else if let truncatedText {
            truncatedText.removeFromSuperview(); self.truncatedText = nil
        }
        // A row a fold has emptied draws nothing and says nothing.
        setAccessibilityElement(!drawsNothing)
        setAccessibilityLabel("assistant message")
        setAccessibilityCustomActions(TranscriptRowAction.all(message, inputs.actions, forks: inputs.environment.forks, source: sourceToggle)
            .map { action in NSAccessibilityCustomAction(name: action.name) { [weak self] in
                // A row in a pane that takes no input acts on nothing, as its pills do.
                guard self?.inputs.environment.isEnabled == true else { return false }
                action.perform(); return true
            } })
        needsLayout = true
        refreshBand()
        refreshCopy()
    }

    /// The whole reply's Copy, over its top corner while the pointer is on its
    /// words: an overlay, so it never changes the row's layout.
    private func refreshCopy() {
        let message = message
        let introduction = message.isStreaming || raw ? nil
            : TranscriptCopy.targets(in: message.text).first { $0.kind == .introduction || $0.kind == .whole }
        if let introduction, bodyHover.inside, !drawsNothing {
            let button = copy ?? { let button = TranscriptCopyButton(); addSubview(button); copy = button; return button }()
            button.target = introduction
            button.enabled = inputs.environment.isEnabled
            button.rightToLeft = inputs.environment.layoutDirection == .rightToLeft
            needsLayout = true
        } else if let copy {
            copy.removeFromSuperview(); self.copy = nil
        }
    }

    private var sourceToggle: ReplySourceToggle? {
        let message = message
        guard ReplySource.offered(message) else { return nil }
        let id = message.id, toggle = inputs.toggle
        return ReplySourceToggle(raw: inputs.disclosure.raw) { toggle(.source(id)) }
    }
    private func refreshBand() {
        let wanted = hovering && !drawsNothing
            ? RowActionsView.pills(message, actions: inputs.actions, forks: inputs.environment.forks, source: sourceToggle) : []
        band.show(wanted, enabled: inputs.environment.isEnabled)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        PiMenus.menu(ReplyMenu.entries(message, actions: inputs.actions, forks: inputs.environment.forks, source: sourceToggle))
    }

    // MARK: Geometry

    private struct Plan {
        var failed: CGRect = .zero
        var truncated: CGRect = .zero
        var notice: CGRect = .zero
        var markdown: CGRect
        var source: CGRect
        var sourceText: CGRect
        var band: CGRect
        var height: CGFloat
    }
    private func plan(width: CGFloat) -> Plan {
        guard !drawsNothing else { return Plan(markdown: .zero, source: .zero, sourceText: .zero, band: .zero, height: 0) }
        var y: CGFloat = 0
        var markdownFrame = CGRect.zero, sourceFrame = CGRect.zero, sourceText = CGRect.zero
        var failedFrame = CGRect.zero, truncatedFrame = CGRect.zero
        if let failedLabel {
            // The ending's word on a line of its own, above the words.
            let size = failedLabel.intrinsicSize
            failedFrame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            y = failedFrame.maxY + Self.gap
        }
        if drawsBody {
            let message = message
            let measured = raw ? 0 : markdown.measure(width: width).height
            let height = message.text.isEmpty && message.isStreaming ? max(Self.waitingHeight, measured) : measured
            markdownFrame = CGRect(x: 0, y: y, width: width, height: height)
            y += height
            if raw, let parts = source {
                let inner = max(1, width - 2 * Self.sourcePadding.width)
                let text = parts.text.measure(width: inner).height
                sourceFrame = CGRect(x: 0, y: y, width: width, height: text + 2 * Self.sourcePadding.height)
                sourceText = CGRect(x: Self.sourcePadding.width, y: y + Self.sourcePadding.height, width: inner, height: text)
                y = sourceFrame.maxY
            }
            y += Self.gap
        }
        if let truncatedText {
            let height = truncatedText.exactHeight(width: width)
            truncatedFrame = CGRect(x: 0, y: y, width: width, height: height)
            y = truncatedFrame.maxY + Self.gap
        }
        var noticeFrame = CGRect.zero
        if let notice = noticeText, !notice.string.isEmpty {
            // Two points of room above it, as the notice's own padding gave;
            // the text wraps beside its icon.
            let textWidth = max(1, width - noticeIconWidth - 6)
            let line = max(notice.exactHeight(width: textWidth), noticeIcon.image?.size.height ?? 0)
            noticeFrame = CGRect(x: 0, y: y + 2, width: width, height: line)
            y = noticeFrame.maxY + Self.gap
        }
        let band = CGRect(x: 0, y: y, width: width, height: Self.bandHeight)
        return Plan(failed: failedFrame, truncated: truncatedFrame, notice: noticeFrame, markdown: markdownFrame, source: sourceFrame, sourceText: sourceText, band: band, height: band.maxY + Self.bottom)
    }
    func settle() -> (height: CGFloat, passes: Int) {
        let plan = plan(width: bounds.width > 0 ? bounds.width : inputs.width)
        layoutSubtreeIfNeeded()
        return (max(1, ceil(plan.height)), 1)
    }
    func confirmHeight() -> CGFloat { max(1, ceil(plan(width: bounds.width > 0 ? bounds.width : inputs.width).height)) }

    override func layout() {
        super.layout()
        let plan = plan(width: bounds.width)
        let hidden = drawsNothing
        markdown.isHidden = hidden || !drawsBody
        markdown.frame = plan.markdown
        quoteRegion.frame = plan.source == .zero ? plan.markdown : plan.markdown.union(plan.source)
        if let parts = source { parts.panel.frame = plan.source; parts.text.frame = plan.sourceText }
        dots.isHidden = hidden || !dots.running
        failedLabel?.isHidden = hidden; failedLabel?.frame = plan.failed
        truncatedText?.isHidden = hidden
        truncatedText.map { $0.frame = CGRect(x: plan.truncated.minX, y: plan.truncated.minY, width: plan.truncated.width, height: ceil(plan.truncated.height)) }
        noticeText?.isHidden = hidden; noticeIcon.isHidden = hidden || noticeText == nil
        if let notice = noticeText, !notice.isHidden {
            let icon = noticeIcon.image?.size ?? .zero
            let textWidth = max(1, plan.notice.width - noticeIconWidth - 6), text = notice.exactHeight(width: textWidth)
            noticeIcon.frame = CGRect(x: 0, y: plan.notice.midY - icon.height / 2 - Self.noticeIconLift, width: icon.width, height: icon.height)
            notice.frame = CGRect(x: noticeIconWidth + 6, y: plan.notice.midY - text / 2, width: textWidth, height: ceil(text))
        }
        // 4: a folded reply's source takes no room and says nothing.
        if let parts = source { parts.panel.isHidden = hidden; parts.text.isHidden = hidden }
        dots.frame = CGRect(x: 0, y: plan.markdown.minY, width: TranscriptWaitingDots.width, height: Self.waitingHeight)
        if let copy {
            copy.frame = CGRect(x: plan.markdown.maxX - TranscriptCopyButton.size.width, y: plan.markdown.minY - 3,
                                width: TranscriptCopyButton.size.width, height: TranscriptCopyButton.size.height)
        }
        let rtl = inputs.environment.layoutDirection == .rightToLeft
        band.place(maxX: plan.band.maxX, midY: plan.band.midY, width: bounds.width, rightToLeft: rtl)
        if rtl {
            copy.map { $0.frame = TranscriptMotion.mirrored($0.frame, width: bounds.width, true) }
            for view in [noticeIcon, noticeText, dots, failedLabel, truncatedText] as [NSView?] { if let view { view.frame = TranscriptMotion.mirrored(view.frame, width: bounds.width, true) } }
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.update(rect: CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - Self.bottom)))
        bodyHover.update(rect: plan(width: bounds.width).markdown)
    }
    override func mouseEntered(with event: NSEvent) { trackPointer(event) }
    override func mouseExited(with event: NSEvent) { trackPointer(event) }
    override func mouseMoved(with event: NSEvent) { trackPointer(event) }
    private func trackPointer(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hover.set(CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - Self.bottom)).contains(point))
        bodyHover.set(plan(width: bounds.width).markdown.contains(point))
    }
}

/// Three dots that fill in turn while a reply waits for its first token.
@MainActor final class TranscriptWaitingDots: NSView {
    static let width: CGFloat = 3 * 7 + 2 * 5
    private var timer: Timer?
    private var phase = 0
    var running = false {
        didSet {
            guard running != oldValue else { return }
            timer?.invalidate(); timer = nil
            if running {
                phase = Int(Date().timeIntervalSinceReferenceDate / 0.4) % 4
                timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { guard let self else { return }; self.phase = (self.phase + 1) % 4; self.needsDisplay = true }
                }
            }
            needsDisplay = true
        }
    }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel("Waiting for the reply")
    }
    required init?(coder: NSCoder) { nil }
    deinit { MainActor.assumeIsolated { timer?.invalidate() } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let color = TranscriptNSPalette.muted
        for index in 0..<3 {
            let lit = phase != 0 && index < phase
            color.withAlphaComponent(lit ? 1 : 0.25).setFill()
            NSBezierPath(ovalIn: CGRect(x: CGFloat(index) * 12, y: (bounds.height - 7) / 2, width: 7, height: 7)).fill()
        }
    }
}
