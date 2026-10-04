import AppKit

// The rows the conversation adds around its messages, drawn by AppKit: a
// compaction's card, a response's own accounting line and a tool result the
// planner could not attach to its call. Each reads and measures as the
// SwiftUI row `MessageRowView` drew for the same message.

/// A line the reader opens and closes with a click, Space or Return, as a
/// plain SwiftUI `Button` did: no ring of its own (the rows disable SwiftUI's
/// focus effect), focus only where keyboard navigation reaches it, and a
/// click that leaves the keyboard where it was.
@MainActor class TranscriptNativeToggle: NSView {
    var toggle: () -> Void = {}
    private(set) var enabled = true
    private(set) var rightToLeft = false
    private var hover: TranscriptHoverTracker!
    private(set) var hovering = false
    private var pressing = false
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        hover = TranscriptHoverTracker(view: self) { [weak self] inside in self?.setHovering(inside) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { nil }

    func set(environment: TranscriptRowEnvironment, toggle: @escaping () -> Void) {
        self.toggle = toggle
        let rtl = environment.layoutDirection == .rightToLeft
        if enabled != environment.isEnabled || rightToLeft != rtl { needsLayout = true }
        enabled = environment.isEnabled
        rightToLeft = rtl
        if !enabled, window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }
    /// Called when the pointer arrives or leaves.
    func hoverChanged() {}
    private func setHovering(_ value: Bool) {
        guard value != hovering else { return }
        hovering = value
        hoverChanged()
    }
    /// The part of the line the pointer counts over.
    var hoverRect: CGRect { bounds }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.update(rect: hoverRect)
    }
    override func mouseEntered(with event: NSEvent) { hover.set(true) }
    override func mouseExited(with event: NSEvent) { hover.set(false) }

    /// Who had the keyboard when the pointer came down: a click acts and
    /// leaves focus where it was, as a button's click does.
    private weak var responderBeforeClick: NSResponder?
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self, let current = window?.firstResponder, current !== self {
            if let editor = current as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder {
                responderBeforeClick = field
            } else {
                responderBeforeClick = current
            }
        }
        return hit
    }
    override func mouseDown(with event: NSEvent) {
        pressing = true
        if window?.firstResponder === self, let before = responderBeforeClick, before !== self { window?.makeFirstResponder(before) }
        responderBeforeClick = nil
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressing = false }
        guard pressing, bounds.contains(convert(event.locationInWindow, from: nil)), enabled else { return }
        toggle()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var acceptsFirstResponder: Bool { enabled }
    override var canBecomeKeyView: Bool { enabled && NSApp.isFullKeyboardAccessEnabled }
    override func keyDown(with event: NSEvent) {
        guard enabled, [" ", "\r"].contains(event.charactersIgnoringModifiers ?? "") else { return super.keyDown(with: event) }
        toggle()
    }
    override func accessibilityPerformPress() -> Bool {
        guard enabled else { return false }
        toggle(); return true
    }
    override func isAccessibilityEnabled() -> Bool { enabled }
}

/// The transcript's own disclosure line, as `TranscriptFoldHeader` drew it:
/// a chevron in an 18 by 16 box that lights under the pointer, turned a
/// quarter while closed, then the title, the whole line one button.
@MainActor final class TranscriptNativeFoldHeader: TranscriptNativeToggle {
    static let height: CGFloat = 16
    static let box = CGSize(width: 18, height: 16)
    private let panel = TranscriptPanel()
    private let chevron = TranscriptSymbol()
    private let title = TranscriptLabel()
    private(set) var open = false
    private var help = (open: "Hide", closed: "Show")
    override init(frame: NSRect) {
        super.init(frame: frame)
        panel.cornerRadius = 5
        chevron.show("chevron.down", size: 10, weight: .semibold)
        chevron.square = true
        for view in [panel, chevron, title] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }

    func update(title text: String, font: NSFont, open: Bool, help: (open: String, closed: String),
                environment: TranscriptRowEnvironment, toggle: @escaping () -> Void) {
        let turning = open != self.open && window != nil
        self.open = open
        self.help = help
        title.text = text; title.font = font
        set(environment: environment, toggle: toggle)
        // Closed, it points to where the line reads from: SwiftUI mirrors the turned chevron with the row.
        chevron.mirroredAcross = environment.layoutDirection == .rightToLeft
        chevron.setRotation(open ? 0 : -90, animated: turning && !PiMotion.reducesMotion)
        toolTip = open ? help.open : help.closed
        setAccessibilityLabel(open ? "Hide \(text)" : "Show \(text)")
        refresh()
        needsLayout = true
    }
    override func hoverChanged() { refresh() }
    private func refresh() {
        chevron.contentTintColor = hovering ? TranscriptNSPalette.text : TranscriptNSPalette.faint
        panel.fill = hovering ? TranscriptNSPalette.panel : nil
        title.color = hovering ? TranscriptNSPalette.muted : TranscriptNSPalette.faint
    }
    override func layout() {
        super.layout()
        let box = CGRect(x: 0, y: (bounds.height - Self.box.height) / 2, width: Self.box.width, height: Self.box.height)
        panel.frame = pixelAligned(box)
        let size = chevron.swiftUIFrame ?? chevron.image?.size ?? .zero
        chevron.place(in: pixelAligned(CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)))
        let text = title.intrinsicSize
        title.frame = CGRect(x: box.maxX + 4, y: (bounds.height - text.height) / 2, width: text.width, height: text.height)
        if rightToLeft {
            for view in [panel, chevron] as [NSView] { view.frame = TranscriptMotion.mirrored(view.frame, width: bounds.width, true) }
            title.frame = TranscriptMotion.mirrored(title.frame, of: title, width: bounds.width, true)
        }
    }
    override func resetCursorRects() {
        // The pointer turns into a hand over the chevron, as `piPointer` set it there.
        if enabled { addCursorRect(TranscriptMotion.mirrored(CGRect(origin: .zero, size: Self.box), width: bounds.width, rightToLeft), cursor: .pointingHand) }
    }
    private func pixelAligned(_ rect: CGRect) -> CGRect { TranscriptMotion.pixelAligned(rect, scale: window?.backingScaleFactor ?? 2) }
}

/// A compaction: a card between two short rules saying the context was
/// compacted and how, its actions under the pointer, the summary it kept
/// behind a disclosure line, and what the summary request cost, as
/// `CompactionRowView` drew it.
@MainActor final class TranscriptNativeCompactionRow: TranscriptNativeMessageRow {
    static let ruleWidth: CGFloat = 24
    static let maximumCardWidth: CGFloat = 620
    static let padding = CGSize(width: 14, height: 10)
    static let headerHeight: CGFloat = 22
    static let markFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    /// The title, which wraps rather than truncates in a narrow card.
    static let titleFace = TranscriptPlainTextFace(size: 13, monospaced: false, lineSpacing: 0, label: "Context compacted",
                                                   weight: NSFont.Weight.semibold.rawValue, serif: true)
    static let titleFont = titleFace.nsFont
    static let detailFont = NSFont.systemFont(ofSize: 11.5)
    static let foldFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    static let summaryTitle = "Summary kept in context"
    private let leadingRule = TranscriptPanel()
    private let trailingRule = TranscriptPanel()
    private let card = TranscriptPanel()
    private let circle = TranscriptPanel()
    private let mark = TranscriptLabel()
    private let title = TranscriptLabel()
    private var wrappedTitle: TranscriptPlainTextView?
    /// The header was placed less tall than its wrapped title: the title
    /// keeps one line, cut short (see `TranscriptStackLayout`).
    private var titleSqueezed = false
    private let detail = TranscriptLabel()
    private let hair = TranscriptPanel()
    private let fold = TranscriptNativeFoldHeader()
    private var markdown: NativeMarkdownContainer?
    private let accounting = TranscriptNativeAccounting()
    private lazy var band = TranscriptPillBand(host: self)
    private var hover: TranscriptHoverTracker!
    private var hovering = false

    override class func message(of item: TranscriptItem) -> TranscriptMessage? {
        guard case .message(let message) = item, message.kind == "compaction" else { return nil }
        return message
    }
    override init(inputs: TranscriptRowInputs) {
        super.init(inputs: inputs)
        for rule in [leadingRule, trailingRule, hair] { rule.cornerRadius = 0 }
        card.cornerRadius = 14
        circle.cornerRadius = nil; circle.circular = true
        mark.font = Self.markFont; mark.text = "⇣"; mark.mirrorsByFrame = true
        title.font = Self.titleFont; title.text = "Context compacted"; title.truncation = .tail
        detail.font = Self.detailFont; detail.monospacedDigits = true; detail.truncation = .tail
        for view in [leadingRule, trailingRule, card, circle, mark, title, detail, hair, fold, accounting] as [NSView] { addSubview(view) }
        hover = TranscriptHoverTracker(view: self) { [weak self] inside in self?.hovering = inside; self?.refreshBand() }
        apply(inputs)
    }
    required init?(coder: NSCoder) { nil }

    private var open: Bool { inputs.disclosure.compaction }
    private var hasSummary: Bool { !message.text.isEmpty }
    private var hasAccounting: Bool { (message.accounting?.requests ?? 0) > 0 && !accounting.isEmpty }

    override func configure() {
        let message = message, environment = inputs.environment, actions = inputs.actions
        for rule in [leadingRule, trailingRule] { rule.fill = TranscriptNSPalette.hairStrong }
        card.fill = TranscriptNSPalette.surface; card.stroke = TranscriptNSPalette.hairStrong
        circle.fill = TranscriptNSPalette.accentSoft
        mark.color = TranscriptNSPalette.accent
        title.color = TranscriptNSPalette.text
        detail.text = message.detail ?? ""; detail.color = TranscriptNSPalette.muted
        hair.fill = TranscriptNSPalette.hair
        let id = message.id, toggle = inputs.toggle
        fold.update(title: Self.summaryTitle, font: Self.foldFont, open: open,
                    help: ("Hide the summary this compaction kept in context", "Show the summary this compaction kept in context"),
                    environment: environment, toggle: { toggle(.compaction(id)) })
        if open, hasSummary {
            let surface = markdown ?? {
                let surface = NativeMarkdownContainer()
                surface.onSizeInvalidated = { [weak self] in self?.owner?.contentSizeChanged() }
                addSubview(surface); markdown = surface
                return surface
            }()
            surface.read(source: message.text, style: .summary, capsWidth: false, streaming: false, headings: [],
                         environment: environment, identity: "")
        } else if let markdown {
            // A closed summary keeps nothing laid out.
            markdown.removeFromSuperview(); self.markdown = nil
        }
        if let totals = message.accounting, totals.requests > 0 {
            accounting.update(totals, environment: environment) { actions.inspect(id) }
        }
        setAccessibilityLabel("Context compacted")
        setAccessibilityCustomActions(TranscriptRowAction.all(message, actions)
            .map { action in NSAccessibilityCustomAction(name: action.name) { [weak self] in
                guard self?.inputs.environment.isEnabled == true else { return false }
                action.perform(); return true
            } })
        refreshBand()
    }
    override func hides(_ view: NSView) -> Bool {
        (view === detail && message.detail == nil) || ((view === hair || view === fold) && !hasSummary)
            || (view === accounting && !hasAccounting)
    }
    private func refreshBand() {
        let wanted = hovering && !drawsNothing ? RowActionsView.pills(message, actions: inputs.actions, forks: false, source: nil) : []
        band.show(wanted, enabled: inputs.environment.isEnabled)
    }

    // MARK: Geometry

    private var titleText: TranscriptPlainTextView {
        if let wrappedTitle { return wrappedTitle }
        let text = TranscriptPlainTextView(); text.isSelectable = false; text.setAccessibilityElement(false)
        text.update(text: "Context compacted", face: Self.titleFace, environment: inputs.environment, swiftUILines: true, color: TranscriptNSPalette.text)
        addSubview(text); wrappedTitle = text
        return text
    }
    /// The header's pieces at the inner width `width`, as its `HStack` shares them out.
    private func header(width: CGFloat) -> (pieces: [TranscriptLinePiece], sizes: [CGSize], spacing: [CGFloat]) {
        let titleIdeal = title.intrinsicSize
        let squeezed = titleSqueezed, label = title
        var pieces: [TranscriptLinePiece] = [.fixed(CGSize(width: 20, height: 20)),
                                             TranscriptLinePiece(minWidth: 0, maxWidth: titleIdeal.width, size: { [unowned self] offered in
            let width = min(titleIdeal.width, max(0, offered))
            guard width < titleIdeal.width else { return titleIdeal }
            if squeezed { return CGSize(width: label.width(truncatedTo: width), height: titleIdeal.height) }
            return CGSize(width: titleText.usedWidth(width: width), height: titleText.exactHeight(width: width))
        })]
        if message.detail != nil {
            let ideal = detail.intrinsicSize, label = detail
            pieces.append(TranscriptLinePiece(minWidth: 0, maxWidth: ideal.width, size: { CGSize(width: label.width(truncatedTo: $0), height: ideal.height) }))
        }
        let pillsWidth = band.pills.reduce(0) { $0 + $1.pillSize.width } + 4 * CGFloat(max(0, band.pills.count - 1))
        pieces.append(.spacer(minLength: 0))
        pieces.append(.fixed(CGSize(width: pillsWidth, height: Self.headerHeight)))
        let spacing = [CGFloat](repeating: 8, count: pieces.count - 1)
        return (pieces, TranscriptLineLayout.sizes(pieces, spacing: spacing, width: width), spacing)
    }
    private struct Plan {
        var card: CGRect
        var inner: CGRect
        var header: CGFloat
        var section: CGFloat
        var markdown: CGFloat
        var accounting: CGFloat
        /// How much less tall the pieces were placed than measured: the
        /// card's face ends above it (its background is the size its content
        /// was placed at), while the rules stay at the measured card's middle.
        var leftover: CGFloat
        var height: CGFloat
    }
    private func plan(width: CGFloat) -> Plan {
        let cardWidth = max(0, min(Self.maximumCardWidth, width - 2 * (Self.ruleWidth + 8)))
        let innerWidth = max(0, cardWidth - 2 * Self.padding.width)
        titleSqueezed = false
        accounting.lineLimit = 0
        let headerIdeal = header(width: innerWidth).sizes.map(\.height).max() ?? Self.headerHeight
        var pieces: [TranscriptStackPiece] = [TranscriptStackPiece(minHeight: Self.headerHeight, idealHeight: headerIdeal, height: { [unowned self] _ in
            titleSqueezed = true
            return header(width: innerWidth).sizes.map(\.height).max() ?? Self.headerHeight
        })]
        var section: CGFloat = 0, markdownHeight: CGFloat = 0
        if hasSummary {
            if open, let markdown { markdownHeight = markdown.measure(width: max(1, innerWidth - 22)).height }
            section = 6 + TranscriptNativeFoldHeader.height + (open && markdown != nil ? 6 + markdownHeight : 0)
            pieces.append(.fixed(section))
        }
        if hasAccounting {
            let accounting = accounting
            pieces.append(TranscriptStackPiece(minHeight: TranscriptLabel.lineHeight(TranscriptNativeAccounting.font), idealHeight: accounting.height(width: innerWidth),
                                               height: { offered in accounting.limit(toHeight: offered); return accounting.height(width: innerWidth) }))
        }
        // The card is as tall as its pieces want; SwiftUI then places them
        // as its stack shares that height out.
        let inner = pieces.reduce(0) { $0 + $1.idealHeight } + 6 * CGFloat(pieces.count - 1)
        let heights = TranscriptStackLayout.heights(pieces)
        let cardHeight = inner + 2 * Self.padding.height
        let total = 2 * (Self.ruleWidth + 8) + cardWidth
        let card = CGRect(x: (width - total) / 2 + Self.ruleWidth + 8, y: 12, width: cardWidth, height: cardHeight)
        return Plan(card: card, inner: card.insetBy(dx: Self.padding.width, dy: Self.padding.height), header: heights[0], section: section,
                    markdown: markdownHeight, accounting: hasAccounting ? heights[heights.count - 1] : 0,
                    leftover: max(0, pieces.reduce(0) { $0 + $1.idealHeight } - heights.reduce(0, +)), height: 12 + cardHeight + 12)
    }
    override func contentHeight(width: CGFloat) -> CGFloat { plan(width: width).height }
    override func place(in rect: CGRect) {
        var plan = plan(width: rect.width)
        plan.card = plan.card.offsetBy(dx: rect.minX, dy: rect.minY)
        plan.inner = plan.inner.offsetBy(dx: rect.minX, dy: rect.minY)
        card.frame = pixelAligned(CGRect(x: plan.card.minX, y: plan.card.minY, width: plan.card.width, height: plan.card.height - plan.leftover))
        for (rule, x) in [(leadingRule, plan.card.minX - 8 - Self.ruleWidth), (trailingRule, plan.card.maxX + 8)] {
            rule.frame = pixelAligned(CGRect(x: x, y: plan.card.midY - 0.5, width: Self.ruleWidth, height: 1))
        }
        // The header: the mark in its circle, the title, the detail cut short,
        // and the pills from the trailing edge.
        let inner = plan.inner
        let (_, sizes, spacing) = self.header(width: inner.width)
        let titleIdeal = title.intrinsicSize
        let line = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: plan.header)
        let frames = TranscriptLineLayout.frames(sizes, spacing: spacing, x: line.minX, midY: line.midY)
        circle.frame = pixelAligned(frames[0])
        let markSize = mark.intrinsicSize
        mark.frame = CGRect(x: frames[0].midX - markSize.width / 2, y: frames[0].midY - markSize.height / 2, width: markSize.width, height: markSize.height)
        let titleWraps = !titleSqueezed && sizes[1].width < titleIdeal.width
        title.isHidden = drawsNothing || titleWraps
        wrappedTitle?.isHidden = drawsNothing || !titleWraps
        if titleWraps { self.titleText.frame = CGRect(x: frames[1].minX, y: frames[1].minY, width: frames[1].width, height: ceil(frames[1].height)) }
        else { title.frame = frames[1] }
        if message.detail != nil {
            detail.frame = frames[2]
        }
        band.place(maxX: frames[frames.count - 1].maxX, midY: line.midY, width: bounds.width, rightToLeft: false)
        var y = line.maxY
        if hasSummary {
            y += 6
            hair.frame = pixelAligned(CGRect(x: inner.minX, y: y, width: inner.width, height: 1))
            fold.frame = CGRect(x: inner.minX, y: y + 6, width: inner.width, height: TranscriptNativeFoldHeader.height)
            if let markdown {
                markdown.frame = CGRect(x: inner.minX + 22, y: fold.frame.maxY + 6, width: max(1, inner.width - 22), height: plan.markdown)
                markdown.isHidden = drawsNothing
            }
            y += plan.section
        }
        if hasAccounting {
            y += 6
            accounting.frame = CGRect(x: inner.minX, y: y, width: inner.width, height: plan.accounting)
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // The pointer counts over the card's line, not the room above and below it.
        hover.update(rect: CGRect(x: 0, y: Self.rowTop + 12, width: bounds.width, height: max(0, bounds.height - Self.rowTop - Self.rowBottom - 24)))
    }
    override func mouseEntered(with event: NSEvent) { hover.set(true) }
    override func mouseExited(with event: NSEvent) { hover.set(false) }
}

/// A response's own line of figures: what the request cost, how the
/// response's parts were recorded, and how it ended early, as
/// `RequestTimelineInfo` drew it. A response folded to its header line says
/// these there, and this row draws nothing.
@MainActor final class TranscriptNativeRequestInfoRow: TranscriptNativeMessageRow {
    static let detailFace = TranscriptPlainTextFace(size: 11, monospaced: false, lineSpacing: 0, label: "Detail")
    static let noticeFace = TranscriptPlainTextFace(size: 12, monospaced: false, lineSpacing: 0, label: "Notice")
    private let accounting = TranscriptNativeAccounting()
    private let detail = TranscriptPlainTextView()
    private let notice = TranscriptPlainTextView()
    override class func message(of item: TranscriptItem) -> TranscriptMessage? {
        guard case .message(let message) = item, message.kind == "requestInfo" else { return nil }
        return message
    }
    override var drawsNothing: Bool { inputs.disclosure.foldedAway || inputs.disclosure.responseFolded }
    override init(inputs: TranscriptRowInputs) {
        super.init(inputs: inputs)
        detail.isSelectable = false; notice.isSelectable = false
        for view in [accounting, detail, notice] as [NSView] { addSubview(view) }
        apply(inputs)
    }
    required init?(coder: NSCoder) { nil }
    private var hasAccounting: Bool { (message.accounting?.requests ?? 0) > 0 && !accounting.isEmpty }
    private var noticeText: String? { TranscriptActivity.earlyEnd(message.stopReason) }
    override func configure() {
        let message = message, actions = inputs.actions, id = message.id
        if let totals = message.accounting, totals.requests > 0 {
            accounting.update(totals, environment: inputs.environment) { actions.inspect(id) }
        }
        detail.update(text: message.detail ?? "", face: Self.detailFace, environment: inputs.environment, swiftUILines: true, color: TranscriptNSPalette.faint)
        notice.update(text: noticeText ?? "", face: Self.noticeFace, environment: inputs.environment, swiftUILines: true, color: TranscriptNSPalette.warning)
        setAccessibilityLabel(nil)
    }
    override func hides(_ view: NSView) -> Bool {
        (view === accounting && !hasAccounting) || (view === detail && message.detail == nil) || (view === notice && noticeText == nil)
    }
    /// The pieces present, top to bottom, with their sizes at `width` as the
    /// stack places them (`TranscriptStackLayout`: a text offered less than
    /// all its lines keeps the lines that fit), and how tall it measured.
    private func stack(width: CGFloat) -> (pieces: [(NSView, CGSize)], measured: CGFloat) {
        var views: [NSView] = [], pieces: [TranscriptStackPiece] = []
        accounting.lineLimit = 0
        if hasAccounting {
            let accounting = accounting
            views.append(accounting)
            pieces.append(TranscriptStackPiece(minHeight: TranscriptLabel.lineHeight(TranscriptNativeAccounting.font), idealHeight: accounting.height(width: width),
                                               height: { offered in accounting.limit(toHeight: offered); return accounting.height(width: width) }))
        }
        for (text, present) in [(detail, message.detail != nil), (notice, noticeText != nil)] where present {
            text.maximumLines = 0
            let line = TranscriptLabel.lineHeight(text === detail ? Self.detailFace.nsFont : Self.noticeFace.nsFont)
            views.append(text)
            pieces.append(TranscriptStackPiece(minHeight: line, idealHeight: text.exactHeight(width: width), height: { offered in
                text.maximumLines = max(1, Int((offered / line + 0.001).rounded(.down)))
                return text.exactHeight(width: width)
            }))
        }
        let heights = TranscriptStackLayout.heights(pieces)
        let sized = zip(views, heights).map { view, height in
            (view, CGSize(width: view === accounting ? width : (view as! TranscriptPlainTextView).usedWidth(width: width), height: height))
        }
        return (sized, pieces.reduce(0) { $0 + $1.idealHeight })
    }
    /// Four points between the pieces, six below the last.
    override func contentHeight(width: CGFloat) -> CGFloat {
        let stack = stack(width: width)
        return stack.measured + 4 * CGFloat(max(0, stack.pieces.count - 1)) + 6
    }
    override func place(in rect: CGRect) {
        var y = rect.minY
        for (view, size) in stack(width: rect.width).pieces {
            view.frame = CGRect(x: rect.minX, y: y, width: size.width, height: view === accounting ? size.height : ceil(size.height))
            y += size.height + 4
        }
    }
}

/// A tool's result the conversation could not put with its call: the line
/// that says so, and under it, once opened, what the tool returned, as
/// `ToolResultTimelineRow` drew it.
@MainActor final class TranscriptNativeToolResultRow: TranscriptNativeMessageRow {
    private let line = TranscriptNativeLabelButton()
    private var markdown: NativeMarkdownContainer?
    override class func message(of item: TranscriptItem) -> TranscriptMessage? {
        guard case .message(let message) = item, message.kind == "toolResult" else { return nil }
        return message
    }
    override init(inputs: TranscriptRowInputs) {
        super.init(inputs: inputs)
        addSubview(line)
        apply(inputs)
    }
    required init?(coder: NSCoder) { nil }
    private var open: Bool { inputs.disclosure.compaction }
    override func configure() {
        let message = message, id = message.id, toggle = inputs.toggle
        line.update(title: message.detail ?? "Tool result recorded", symbol: open ? "chevron.down" : "chevron.right",
                    environment: inputs.environment, toggle: { toggle(.compaction(id)) })
        line.setAccessibilityValue(open ? "Open" : "Closed")
        if open {
            let surface = markdown ?? {
                let surface = NativeMarkdownContainer()
                surface.onSizeInvalidated = { [weak self] in self?.owner?.contentSizeChanged() }
                addSubview(surface); markdown = surface
                return surface
            }()
            surface.read(source: message.text, style: .prose, capsWidth: true, streaming: false, headings: [],
                         environment: inputs.environment, identity: "")
        } else if let markdown {
            markdown.removeFromSuperview(); self.markdown = nil
        }
        setAccessibilityLabel(nil)
    }
    /// Six points above and below; the result six under the line.
    override func contentHeight(width: CGFloat) -> CGFloat {
        let size = line.size(offered: width)
        var height = 6 + size.height + 6
        if let markdown { height += 6 + markdown.measure(width: width).height }
        return height
    }
    override func place(in rect: CGRect) {
        let size = line.size(offered: rect.width)
        line.frame = CGRect(x: rect.minX, y: rect.minY + 6, width: size.width, height: size.height)
        if let markdown {
            markdown.frame = CGRect(x: rect.minX, y: line.frame.maxY + 6, width: rect.width, height: markdown.measure(width: rect.width).height)
        }
    }
}

/// A plain SwiftUI `Button` around a `Label`: a symbol and a title in the
/// muted colour, the label itself the button.
@MainActor final class TranscriptNativeLabelButton: TranscriptNativeToggle {
    static let font = NSFont.systemFont(ofSize: 12.5)
    private let icon = TranscriptSymbol()
    private let title = TranscriptLabel()
    private var symbol = ""
    /// The title over several lines, when the label is offered less than its one line.
    private var wrapped: TranscriptPlainTextView?
    static let face = TranscriptPlainTextFace(size: 12.5, monospaced: false, lineSpacing: 0, label: "Button")
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = Self.font
        addSubview(icon); addSubview(title)
    }
    required init?(coder: NSCoder) { nil }
    func update(title text: String, symbol: String, environment: TranscriptRowEnvironment, toggle: @escaping () -> Void) {
        if text != title.text || symbol != self.symbol { needsLayout = true }
        self.symbol = symbol
        title.text = text; title.color = TranscriptNSPalette.muted
        icon.show(symbol, size: Self.font.pointSize, weight: .regular)
        icon.contentTintColor = TranscriptNSPalette.muted
        wrapped?.update(text: text, face: Self.face, environment: environment, swiftUILines: true, color: TranscriptNSPalette.muted)
        set(environment: environment, toggle: toggle)
        setAccessibilityLabel(text)
    }
    /// SwiftUI's label: the symbol's outline, eight points, the title.
    private var glyph: CGRect { icon.image?.alignmentRect ?? .zero }
    private var iconWidth: CGFloat { glyph.width + 8 }
    /// SwiftUI's `Label` heights for the symbols, unrounded (measured,
    /// `TranscriptTextCalibrationTests.testLabelButtonsMatchSwiftUI`).
    nonisolated static let swiftUILabelHeights: [String: CGFloat] = [:]
    private var labelHeight: CGFloat {
        Self.swiftUILabelHeights[symbol] ?? max(title.intrinsicSize.height, (icon.swiftUIFrame?.height ?? icon.image?.size.height ?? 0) + 1)
    }
    private var wrappedText: TranscriptPlainTextView {
        if let wrapped { return wrapped }
        let text = TranscriptPlainTextView(); text.isSelectable = false; text.setAccessibilityElement(false)
        var environment = TranscriptRowEnvironment(); environment.layoutDirection = rightToLeft ? .rightToLeft : .leftToRight
        text.update(text: title.text, face: Self.face, environment: environment, swiftUILines: true, color: TranscriptNSPalette.muted)
        addSubview(text); wrapped = text
        return text
    }
    func size(offered width: CGFloat) -> CGSize {
        let ideal = CGSize(width: iconWidth + title.intrinsicSize.width, height: labelHeight)
        guard width < ideal.width else { return ideal }
        let room = max(1, width - iconWidth), text = wrappedText
        return CGSize(width: iconWidth + text.usedWidth(width: room), height: text.exactHeight(width: room) + labelHeight - title.intrinsicSize.height)
    }
    override func layout() {
        super.layout()
        let wraps = bounds.width + 0.25 < iconWidth + title.intrinsicSize.width
        title.isHidden = wraps
        wrapped?.isHidden = !wraps
        let titleFrame: CGRect
        if wraps {
            let room = max(1, bounds.width - iconWidth), height = ceil(wrappedText.exactHeight(width: room))
            titleFrame = CGRect(x: iconWidth, y: (bounds.height - height) / 2, width: room, height: height)
            wrappedText.frame = titleFrame
        } else {
            let text = title.intrinsicSize
            titleFrame = CGRect(x: iconWidth, y: (bounds.height - text.height) / 2, width: text.width, height: text.height)
            title.frame = titleFrame
        }
        if let image = icon.image {
            let line = wraps ? TranscriptLabel.lineHeight(Self.font) : bounds.height
            let top = wraps ? titleFrame.minY : 0
            icon.frame = CGRect(x: -glyph.minX, y: top + (line - glyph.height) / 2 - (image.size.height - glyph.maxY),
                                width: image.size.width, height: image.size.height)
        }
        if rightToLeft {
            for view in [icon, title, wrapped] as [NSView?] { if let view { view.frame = TranscriptMotion.mirrored(view.frame, of: view, width: bounds.width, true) } }
        }
    }
}
