import AppKit

// A reply whose recorded order is unavailable, and a task's aggregate, drawn
// by AppKit as `BlockRowView` drew them: one local work group under its
// header line, the reply's words, its figures and the turn's line.

/// A legacy reply's exposed reasoning on the Think row, as `ReasoningView`
/// drew it: closed by default even while it streams, opening its markdown.
@MainActor final class TranscriptNativeThink: NSView {
    let line = TranscriptNativeWorkLine()
    private(set) var markdown: NativeMarkdownContainer?
    var sizeChanged: () -> Void = {}
    private var open = false
    private var rightToLeft = false
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(line)
    }
    required init?(coder: NSCoder) { nil }
    func update(thinking: String, streaming: Bool, open: Bool, toggle: @escaping () -> Void, environment: TranscriptRowEnvironment) {
        self.open = open
        rightToLeft = environment.layoutDirection == .rightToLeft
        line.update(TranscriptNativeWorkLine.Content(icon: "brain", title: "Think", summary: TimelinePartRow.thinkSummary(thinking, running: streaming),
                                                     state: streaming ? .running : .ok, expandable: true, open: open, follow: streaming),
                    link: nil, toggle: toggle, environment: environment)
        if open {
            let markdown = self.markdown ?? {
                let markdown = NativeMarkdownContainer()
                markdown.onSizeInvalidated = { [weak self] in self?.needsLayout = true; self?.sizeChanged() }
                addSubview(markdown); self.markdown = markdown
                return markdown
            }()
            markdown.read(source: thinking, style: .reasoning, capsWidth: false, streaming: streaming, headings: [], environment: environment, identity: "")
        } else if let markdown {
            markdown.removeFromSuperview(); self.markdown = nil
        }
        needsLayout = true
    }
    private var inner: CGFloat { TranscriptRowChrome.indent }
    func height(width: CGFloat) -> CGFloat {
        guard let markdown else { return TranscriptRowChrome.height }
        return TranscriptRowChrome.height + 4 + markdown.measure(width: max(1, width - inner)).height + 4
    }
    override func layout() {
        super.layout()
        line.frame = CGRect(x: 0, y: 0, width: bounds.width, height: TranscriptRowChrome.height)
        if let markdown {
            let width = max(1, bounds.width - inner)
            markdown.frame = TranscriptMotion.mirrored(CGRect(x: inner, y: TranscriptRowChrome.height + 4, width: width, height: markdown.measure(width: width).height),
                                                       width: bounds.width, rightToLeft)
        }
    }
}

/// One run of tool calls, as `ActivityGroupView` drew it: a short run as a
/// stack of rows, a long one through `NativeWorkListContainer`, which lays
/// out only the cards near the viewport.
@MainActor final class TranscriptNativeActivity: NSView {
    private var rows: [TranscriptNativeActionRow] = []
    private var list: NativeWorkListContainer?
    var sizeChanged: () -> Void = {}
    private var rightToLeft = false
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Tool activity")
    }
    required init?(coder: NSCoder) { nil }
    var builtRows: [TranscriptNativeActionRow] { rows }
    var workList: NativeWorkListContainer? { list }
    func update(tools: [ToolView], openTools: Set<String>, fetched: [String: ToolInputDocument], toggle: @escaping (String) -> Void,
                openFile: ((String, ClosedRange<Int>?) -> Void)?, environment: TranscriptRowEnvironment) {
        rightToLeft = environment.layoutDirection == .rightToLeft
        if tools.count >= NativeWorkListSurface.minimumRowCount {
            for row in rows { row.removeFromSuperview() }
            rows = []
            let list = self.list ?? {
                let list = NativeWorkListContainer()
                list.sizeChanged = { [weak self] in self?.needsLayout = true; self?.sizeChanged() }
                addSubview(list); self.list = list
                return list
            }()
            list.update(tools: tools, openTools: openTools, fetched: fetched, toggle: toggle, openFile: openFile, environment: environment)
        } else {
            list?.removeFromSuperview(); list = nil
            while rows.count > tools.count { rows.removeLast().removeFromSuperview() }
            while rows.count < tools.count {
                let row = TranscriptNativeActionRow()
                row.sizeChanged = { [weak self] in self?.needsLayout = true; self?.sizeChanged() }
                addSubview(row); rows.append(row)
            }
            for (row, tool) in zip(rows, tools) {
                let id = tool.id
                row.update(tool: tool, open: openTools.contains(id), fetched: fetched[id], environment: environment, toggle: { toggle(id) }, openFile: openFile)
            }
        }
        needsLayout = true
    }
    /// Four points in, two above and below.
    func height(width: CGFloat) -> CGFloat {
        let inner = max(0, width - 4)
        if let list { return 2 + list.measure(width: inner).height + 2 }
        return 2 + rows.reduce(0) { $0 + $1.height(width: inner) } + 2
    }
    override func layout() {
        super.layout()
        let inner = max(0, bounds.width - 4)
        if let list {
            list.frame = TranscriptMotion.mirrored(CGRect(x: 4, y: 2, width: inner, height: list.measure(width: inner).height), width: bounds.width, rightToLeft)
            return
        }
        var y: CGFloat = 2
        for row in rows {
            let height = row.height(width: inner)
            row.frame = TranscriptMotion.mirrored(CGRect(x: 4, y: y, width: inner, height: height), width: bounds.width, rightToLeft)
            y += height
        }
    }
}

/// Figures that flow like a sentence, as `FigureFlow` drew a reply's: each
/// figure and the dot after it on one line, wrapping between figures, and
/// the model a control that opens its reports.
@MainActor final class TranscriptNativeFigures: NSView {
    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private struct Item { let views: [NSView]; let size: CGSize; let widths: [CGFloat] }
    private var items: [Item] = []
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    private var shown: (texts: [String], model: String?, enabled: Bool)?
    func update(texts: [String], model: (name: String, open: () -> Void)?, help: String?, environment: TranscriptRowEnvironment) {
        toolTip = (help?.isEmpty ?? true) ? nil : help
        // The same figures keep their views; only the model's action is new.
        if let shown, shown.texts == texts, shown.model == model?.name, shown.enabled == environment.isEnabled {
            if let model, let button = subviews.compactMap({ $0 as? TranscriptNativeModelButton }).first {
                button.update(model: model.name, environment: environment, open: model.open)
            }
            return
        }
        shown = (texts, model?.name, environment.isEnabled)
        for view in subviews { view.removeFromSuperview() }
        items = []
        let count = texts.count + (model == nil ? 0 : 1)
        func dotLabel() -> TranscriptLabel {
            let dot = TranscriptLabel(); dot.font = Self.font; dot.text = " · "; dot.color = TranscriptNSPalette.faint
            return dot
        }
        for (index, text) in texts.enumerated() {
            let label = TranscriptLabel(); label.font = Self.font; label.monospacedDigits = true; label.text = text; label.color = TranscriptNSPalette.faint
            // Each figure is read out, as each `Text` of the flow was.
            label.speak(text)
            var views: [NSView] = [label], widths = [label.intrinsicSize.width]
            var height = label.intrinsicSize.height
            if index + 1 < count { let dot = dotLabel(); views.append(dot); widths.append(dot.intrinsicSize.width); height = max(height, dot.intrinsicSize.height) }
            for view in views { addSubview(view) }
            items.append(Item(views: views, size: CGSize(width: widths.reduce(0, +), height: height), widths: widths))
        }
        if let model {
            let button = TranscriptNativeModelButton()
            button.update(model: model.name, environment: environment, open: model.open)
            addSubview(button)
            items.append(Item(views: [button], size: button.size, widths: [button.size.width]))
        }
        toolTip = (help?.isEmpty ?? true) ? nil : help
        needsLayout = true
    }
    var isEmpty: Bool { items.isEmpty }
    /// Where each figure goes at `width`: rows of figures, three points apart.
    private func flow(width: CGFloat) -> (origins: [CGPoint], rowHeights: [CGFloat], height: CGFloat) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var origins: [CGPoint] = []
        for item in items {
            if x > 0, x + item.size.width > width { x = 0; y += rowHeight + 3; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += item.size.width; rowHeight = max(rowHeight, item.size.height)
        }
        return (origins, [], y + rowHeight)
    }
    func height(width: CGFloat) -> CGFloat { items.isEmpty ? 0 : flow(width: width).height }
    var rightToLeft = false { didSet { if rightToLeft != oldValue { needsLayout = true } } }
    override func layout() {
        super.layout()
        let placed = flow(width: bounds.width)
        for (item, origin) in zip(items, placed.origins) {
            var x = origin.x
            for (view, width) in zip(item.views, item.widths) {
                let height = (view as? TranscriptLabel)?.intrinsicSize.height ?? item.size.height
                let frame = CGRect(x: x, y: origin.y + (item.size.height - height) / 2, width: width, height: height)
                view.frame = TranscriptMotion.mirrored(frame, of: view, width: bounds.width, rightToLeft)
                x += width
            }
        }
    }
}

/// The model among a reply's figures: its name and an info mark, a plain
/// button opening the response's model reports.
@MainActor final class TranscriptNativeModelButton: NSView {
    private let label = TranscriptLabel()
    private let icon = TranscriptSymbol()
    private var open: () -> Void = {}
    private var enabled = true
    private var pressing = false
    private var rightToLeft = false
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = TranscriptNativeFigures.font
        icon.show("info.circle", size: 11, weight: .regular)
        addSubview(label); addSubview(icon)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        toolTip = "View response-body and header models"
    }
    required init?(coder: NSCoder) { nil }
    private var iconSize: CGSize { icon.swiftUIFrame ?? icon.image?.size ?? .zero }
    var size: CGSize {
        let text = label.intrinsicSize
        return CGSize(width: text.width + 3 + iconSize.width, height: max(text.height, iconSize.height))
    }
    func update(model: String, environment: TranscriptRowEnvironment, open: @escaping () -> Void) {
        label.text = model; label.color = TranscriptNSPalette.faint
        icon.contentTintColor = TranscriptNSPalette.faint
        self.open = open; enabled = environment.isEnabled
        rightToLeft = environment.layoutDirection == .rightToLeft
        setAccessibilityLabel("View model reports: \(model)")
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let size = size, text = label.intrinsicSize
        label.frame = TranscriptMotion.mirrored(CGRect(x: 0, y: (size.height - text.height) / 2, width: text.width, height: text.height), of: label, width: bounds.width, rightToLeft)
        icon.place(in: TranscriptMotion.pixelAligned(TranscriptMotion.mirrored(CGRect(x: text.width + 3, y: (size.height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height), width: bounds.width, rightToLeft),
                                                     scale: window?.backingScaleFactor ?? 2))
    }
    override func resetCursorRects() { if enabled { addCursorRect(bounds, cursor: .pointingHand) } }
    /// Who had the keyboard when the pointer came down: a click acts and
    /// leaves focus where it was, as a SwiftUI button's click does.
    private weak var responderBeforeClick: NSResponder?
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point) == nil ? nil : self as NSView?
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
        if pressing, enabled, bounds.contains(convert(event.locationInWindow, from: nil)) { open() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        guard enabled else { return false }
        open(); return true
    }
    override func isAccessibilityEnabled() -> Bool { enabled }
    // A plain button: in the key loop where keyboard navigation reaches
    // buttons, and Space or Return presses it.
    override var acceptsFirstResponder: Bool { enabled }
    override var canBecomeKeyView: Bool { enabled && NSApp.isFullKeyboardAccessEnabled }
    override func keyDown(with event: NSEvent) {
        guard enabled, [" ", "\r"].contains(event.charactersIgnoringModifiers ?? "") else { return super.keyDown(with: event) }
        open()
    }
}

/// One reply's work inside a legacy group: its thought, its calls, what its
/// request cost and, in a task's aggregate, how the request ended and the
/// reply's two actions.
@MainActor final class TranscriptNativeReplyWork: NSView {
    static let warningFace = TranscriptPlainTextFace(size: 11, monospaced: false, lineSpacing: 0, label: "Warning")
    static let noticeFace = TranscriptPlainTextFace(size: 12, monospaced: false, lineSpacing: 0, label: "Notice")
    private(set) var think: TranscriptNativeThink?
    private(set) var activity: TranscriptNativeActivity?
    private var accounting: TranscriptNativeAccounting?
    private var truncatedText: TranscriptPlainTextView?
    private var modelText: TranscriptPlainTextView?
    private var noticeText: TranscriptPlainTextView?
    private(set) var details: TranscriptLinkButton?
    private(set) var copyReply: TranscriptLinkButton?
    var sizeChanged: () -> Void = {}
    private var rightToLeft = false
    private var showsAccounting = false
    override var isFlipped: Bool { true }

    private func text(_ existing: inout TranscriptPlainTextView?, _ value: String?, face: TranscriptPlainTextFace, color: NSColor, environment: TranscriptRowEnvironment) {
        guard let value else { existing?.removeFromSuperview(); existing = nil; return }
        let view = existing ?? { let view = TranscriptPlainTextView(); view.isSelectable = false; addSubview(view); return view }()
        view.update(text: value, face: face, environment: environment, swiftUILines: true, color: color)
        view.setAccessibilityLabel(value)
        existing = view
    }
    private func button(_ existing: inout TranscriptLinkButton?, _ title: String?, environment: TranscriptRowEnvironment, perform: @escaping () -> Void) {
        guard let title else { existing?.removeFromSuperview(); existing = nil; return }
        let button = existing ?? {
            let button = TranscriptLinkButton()
            button.label.font = TranscriptNativePartView.detailsFont
            button.underlinesOnHover = false; button.pointsOnHover = false
            addSubview(button)
            return button
        }()
        button.label.text = title; button.label.color = TranscriptNSPalette.faint
        button.enabled = environment.isEnabled
        button.perform = perform
        existing = button
    }

    func update(reply: TranscriptMessage, block: TranscriptBlock, disclosure: TranscriptRowDisclosure, actions: TranscriptActions,
                toggle: @escaping (TranscriptDisclosure.Part) -> Void, environment: TranscriptRowEnvironment) {
        rightToLeft = environment.layoutDirection == .rightToLeft
        let thinking = reply.thinking ?? ""
        if TranscriptActivity.hasVisibleText(thinking) {
            let think = self.think ?? {
                let think = TranscriptNativeThink()
                think.sizeChanged = { [weak self] in self?.needsLayout = true; self?.sizeChanged() }
                addSubview(think); self.think = think
                return think
            }()
            let id = reply.id
            think.update(thinking: thinking, streaming: reply.isStreaming, open: disclosure.openReasoning.contains(id),
                         toggle: { toggle(.reasoning(id)) }, environment: environment)
        } else if let think { think.removeFromSuperview(); self.think = nil }
        if let tools = reply.tools, !tools.isEmpty {
            let activity = self.activity ?? {
                let activity = TranscriptNativeActivity()
                activity.sizeChanged = { [weak self] in self?.needsLayout = true; self?.sizeChanged() }
                addSubview(activity); self.activity = activity
                return activity
            }()
            let scoped = block.presentation == .work, id = reply.id
            func key(_ tool: String) -> String { scoped ? ToolOccurrence.key(id, tool) : tool }
            activity.update(tools: tools, openTools: Set(tools.filter { disclosure.openTools.contains(key($0.id)) }.map(\.id)),
                            fetched: Dictionary(tools.compactMap { tool in disclosure.toolInputs[key(tool.id)].map { (tool.id, $0) } }, uniquingKeysWith: { _, last in last }),
                            toggle: { toggle(.tool(key($0))) }, openFile: actions.openFile, environment: environment)
        } else if let activity { activity.removeFromSuperview(); self.activity = nil }
        showsAccounting = (reply.accounting?.requests ?? 0) > 0
            && (!(reply.tools ?? []).isEmpty || !(reply.thinking ?? "").isEmpty || reply.id != block.message?.id)
        if showsAccounting, let totals = reply.accounting {
            let view = accounting ?? { let view = TranscriptNativeAccounting(); addSubview(view); accounting = view; return view }()
            let id = reply.id
            view.update(totals, environment: environment) { actions.inspect(id) }
            if view.isEmpty { view.removeFromSuperview(); accounting = nil }
        } else if let accounting { accounting.removeFromSuperview(); self.accounting = nil }
        let task = block.presentation == .work
        text(&truncatedText, task && reply.truncated == true ? "Partial preview · Open Request details for retained content" : nil,
             face: Self.warningFace, color: TranscriptNSPalette.warning, environment: environment)
        text(&modelText, task ? reply.modelMs.map { "Model request: " + TranscriptActivity.formatDuration($0) } : nil,
             face: Self.warningFace, color: TranscriptNSPalette.faint, environment: environment)
        text(&noticeText, task ? TranscriptActivity.earlyEnd(reply.stopReason, toolArguments: true) : nil,
             face: Self.noticeFace, color: TranscriptNSPalette.warning, environment: environment)
        let id = reply.id
        button(&details, task ? "Request details" : nil, environment: environment) { actions.inspect(id) }
        button(&copyReply, task ? "Copy reply" : nil, environment: environment) { actions.copyMessage(id) }
        needsLayout = true
    }

    /// The pieces top down, two points apart; the two actions share a line.
    private func stack(width: CGFloat) -> [(views: [NSView], size: CGSize)] {
        var pieces: [(views: [NSView], size: CGSize)] = []
        // The thought's place is kept even without a thought: SwiftUI's stack
        // spaces the empty `ReasoningView` like any other child.
        pieces.append((think.map { [$0] } ?? [], CGSize(width: width, height: think?.height(width: width) ?? 0)))
        if let activity { pieces.append(([activity], CGSize(width: width, height: activity.height(width: width)))) }
        // So is the usage's, when the request reported nothing it can say.
        if showsAccounting { pieces.append((accounting.map { [$0] } ?? [], CGSize(width: width, height: accounting?.height(width: width) ?? 0))) }
        for text in [truncatedText, modelText, noticeText] {
            if let text { pieces.append(([text], CGSize(width: text.usedWidth(width: width), height: text.exactHeight(width: width)))) }
        }
        if let details, let copyReply {
            pieces.append(([details, copyReply], CGSize(width: details.size.width + Self.buttonSpacing + copyReply.size.width,
                                                       height: max(details.size.height, copyReply.size.height))))
        }
        return pieces
    }
    /// Between the two plain buttons, as an `HStack` spaces two buttons.
    static let buttonSpacing: CGFloat = 8
    func height(width: CGFloat) -> CGFloat {
        let pieces = stack(width: width)
        return pieces.reduce(0) { $0 + $1.size.height } + 2 * CGFloat(max(0, pieces.count - 1))
    }
    override func layout() {
        super.layout()
        let width = bounds.width, scale = window?.backingScaleFactor ?? 2
        var y: CGFloat = 0
        for (views, size) in stack(width: width) {
            if views.count == 2 {
                var x: CGFloat = 0
                for case let button as TranscriptLinkButton in views {
                    let frame = TranscriptMotion.pixelAligned(CGRect(x: x, y: y + (size.height - button.size.height) / 2, width: button.size.width, height: button.size.height), scale: scale)
                    button.frame = TranscriptMotion.mirrored(frame, width: width, rightToLeft)
                    x += button.size.width + Self.buttonSpacing
                }
            } else if let view = views.first {
                var frame = CGRect(x: 0, y: y, width: size.width, height: size.height)
                if view is TranscriptPlainTextView { frame.size.height = ceil(size.height) }
                view.frame = TranscriptMotion.mirrored(frame, width: width, rightToLeft)
            }
            y += size.height + 2
        }
    }
}

/// A reply whose recorded order is unavailable, or a task's aggregate: one
/// local work group under its header, its words, its figures and the line
/// that closes its turn, as `BlockRowView`'s reply drew them. The work list
/// keeps its views while folded: folding is a frame change.
@MainActor final class TranscriptNativeLegacyRow: TranscriptNativeBlockRow {
    let header = TranscriptNativeWorkLine()
    /// Clips the list to the height the fold gives it.
    private let clip = TranscriptClipView()
    private let list = TranscriptClipView()
    private let rule = TranscriptPanel()
    private(set) var works: [TranscriptNativeReplyWork] = []
    private(set) var body: TranscriptNativeReplyRow?
    private var figures: TranscriptNativeFigures?
    private(set) var turnLine: TranscriptNativeTurnLine?
    /// The list changed its own height (a card opened inside it) since the
    /// row last measured it: the container's kept height is stale.
    private var listChanged = false
    private var listMeasured: (width: CGFloat, height: CGFloat)?

    override class func draws(_ item: TranscriptItem) -> Bool {
        guard case .block(let block) = item else { return false }
        if TranscriptNativeTurnFoldRow.draws(item) || TranscriptNativeResponseRow.draws(item) || TranscriptNativePartRow.draws(item)
            || TranscriptNativeTurnSummaryRow.draws(item) { return false }
        if block.presentation == .turnFold, block.foldSummary != nil, block.foldControl != nil { return false }
        if block.presentation == .body, block.message != nil { return false }
        return true
    }
    override var drawsNothing: Bool { inputs.disclosure.foldedAway || inputs.disclosure.responseLine }
    override init(inputs: TranscriptRowInputs) {
        super.init(inputs: inputs)
        clip.clipsToBounds = true
        list.clipsToBounds = false
        rule.cornerRadius = 0
        addSubview(header); addSubview(clip)
        clip.addSubview(list); list.addSubview(rule)
        apply(inputs)
    }
    required init?(coder: NSCoder) { nil }

    private var open: Bool { inputs.disclosure.work }
    private func hasWork(_ block: TranscriptBlock) -> Bool {
        block.presentation == .work || !block.tools.isEmpty || TranscriptActivity.blockReasoned(block)
    }
    override func configure() {
        guard let block else { return }
        let disclosure = inputs.disclosure, toggle = inputs.toggle, actions = inputs.actions, environment = inputs.environment
        let work = hasWork(block)
        // The header and its list.
        if work {
            let outcome = block.task?.outcome
            let state: TranscriptRowState = block.live ? .running : outcome == "failed" ? .failed
                : ["cancelled", "interrupted"].contains(outcome ?? "") ? .stopped : .ok
            let legacy = block.key.hasPrefix("legacy:")
            let label = Self.workLabel(block)
            let summary = legacy ? "Legacy response · part order unavailable"
                : block.presentation == .work ? label
                : ToolCallSummary(rows: block.replies).label(reasoned: TranscriptActivity.blockReasoned(block)) ?? "Working"
            let key = block.key
            header.update(TranscriptNativeWorkLine.Content(icon: "list.bullet", title: legacy ? "Work" : block.presentation == .work ? "Task" : "Work",
                                                           summary: summary, state: state, expandable: true, open: open, help: label),
                          link: nil, toggle: { toggle(.work(key)) }, environment: environment)
            let replies = block.replies
            while works.count > replies.count { works.removeLast().removeFromSuperview() }
            while works.count < replies.count {
                let view = TranscriptNativeReplyWork()
                view.sizeChanged = { [weak self] in self?.workChangedSize() }
                list.addSubview(view); works.append(view)
            }
            for (view, reply) in zip(works, replies) {
                view.update(reply: reply, block: block, disclosure: disclosure, actions: actions, toggle: toggle, environment: environment)
            }
            rule.fill = TranscriptNSPalette.hairStrong
        } else {
            for view in works { view.removeFromSuperview() }
            works = []
        }
        // A folded list takes no clicks and says nothing.
        clip.setAccessibilityElement(false)
        list.setAccessibilityElement(false)
        clip.isHidden = !work
        clip.blocksInput = !open
        clip.setAccessibilityHidden(!open)
        // The reply's words.
        if let message = block.message {
            let bodyInputs = TranscriptRowInputs(item: TranscriptNativePartView.wordsItem(message), fresh: inputs.fresh, actions: actions, width: inputs.width,
                                                 environment: environment, disclosure: TranscriptRowDisclosure(raw: disclosure.raw), toggle: toggle)
            let body = self.body ?? {
                let body = TranscriptNativeReplyRow(inputs: bodyInputs)
                body.bottom = 0
                body.sizeChanged = { [weak self] in self?.needsLayout = true; self?.owner?.contentSizeChanged() }
                addSubview(body); self.body = body
                return body
            }()
            body.apply(bodyInputs)
        } else if let body { body.removeFromSuperview(); self.body = nil }
        // Its figures: a reply inside a multi-reply turn keeps its own.
        let accounting = block.accounting
        let tokens = TranscriptActivity.tokens(of: accounting)
        let hasUsage = tokens != nil || accounting.costUSD != nil || accounting.model != nil
        let merged = block.turn != nil && block.turn!.replies == 1
        if block.presentation != .work, !block.live, !merged, hasUsage {
            var texts: [String] = []
            if let s = block.startedAt, let e = block.endedAt, e >= s { texts.append(TranscriptActivity.formatDuration(e - s)) }
            if let tokens { texts.append("\(TranscriptActivity.formatTokenCount(tokens)) tokens") }
            if let cost = accounting.costUSD {
                texts.append(TranscriptActivity.formatTurnCost(cost) + (accounting.costSamples < accounting.requests ? " (\(accounting.costSamples)/\(accounting.requests))" : ""))
            }
            let id = accounting.modelMessageID ?? block.id
            let figures = self.figures ?? { let figures = TranscriptNativeFigures(); addSubview(figures); self.figures = figures; return figures }()
            figures.rightToLeft = rightToLeft
            figures.update(texts: texts, model: accounting.model.map { name in (name, { actions.inspect(id) }) },
                           help: accounting.requests > 0 ? TranscriptActivity.usageBreakdown(accounting) : "", environment: environment)
        } else if let figures { figures.removeFromSuperview(); self.figures = nil }
        // The line that closes the turn.
        if let turn = block.turn, !turn.live {
            let line = turnLine ?? { let line = TranscriptNativeTurnLine(); addSubview(line); turnLine = line; return line }()
            line.update(turn: turn, settled: inputs.fresh && !block.live, actions: actions, model: accounting.model, environment: environment)
        } else if let turnLine { turnLine.removeFromSuperview(); self.turnLine = nil }
        setAccessibilityElement(false)
    }
    override func apply(_ inputs: TranscriptRowInputs) {
        // New inputs may open or close anything in the list: what it
        // measured before stands only through the container's kept height.
        listMeasured = nil
        super.apply(inputs)
        setAccessibilityElement(false)
    }
    override func hides(_ view: NSView) -> Bool {
        (view === clip || view === header) && !(block.map(hasWork) ?? false)
    }

    static func workLabel(_ block: TranscriptBlock) -> String {
        let status: String
        switch block.task?.outcome {
        case "completed": status = "Completed"
        case "failed": status = "Failed"
        case "cancelled": status = "Stopped"
        case "interrupted": status = "Interrupted"
        case "output-limited": status = "Output limit reached"
        default: status = block.live ? "Working" : "Work · outcome unavailable"
        }
        let summary = block.taskSummary
        let count = summary?.tools ?? ToolCallSummary(rows: block.replies).total
        return status + (count > 0 ? " · \(summary?.toolCountPartial == true ? "at least " : "")\(count) tool calls" : "") +
            (summary?.partial == true ? " · partial history" : "")
    }

    // MARK: Geometry

    private func workChangedSize() {
        listChanged = true
        listMeasured = nil
        needsLayout = true
        owner?.contentSizeChanged()
    }
    /// The open list's stack of replies, six points apart, at the list's inner width.
    private func stackHeight(width: CGFloat) -> CGFloat {
        works.reduce(0) { $0 + $1.height(width: width) } + 6 * CGFloat(max(0, works.count - 1))
    }
    /// The list's own height at `width`: two above, the replies ten points
    /// in from the rule, four below.
    private func listHeight(width: CGFloat) -> CGFloat {
        if let listMeasured, listMeasured.width == width { return listMeasured.height }
        if !listChanged, let known = inputs.workListHeight { return known }
        let height = 2 + stackHeight(width: max(1, width - 12)) + 4
        listMeasured = (width, height)
        listChanged = false
        inputs.workListMeasured(height)
        return height
    }
    private struct Plan {
        var header: CGRect = .zero
        var clip: CGRect = .zero
        var list: CGFloat = 0
        var body: CGRect = .zero
        var figures: CGRect = .zero
        var turn: CGRect = .zero
        var height: CGFloat = 0
    }
    private func plan(width: CGFloat) -> Plan {
        var plan = Plan()
        var pieces: [CGFloat] = []
        var y: CGFloat = 0
        func next(_ height: CGFloat) -> CGFloat {
            if !pieces.isEmpty { y += 4 }
            let top = y
            pieces.append(height); y += height
            return top
        }
        if let block, hasWork(block) {
            // The header, two points, and the list at its height while open
            // and at nothing while folded: a folded list is never measured.
            let list = open ? listHeight(width: width) : 0
            let top = next(TranscriptRowChrome.height + 2 + list)
            plan.header = CGRect(x: 0, y: top, width: width, height: TranscriptRowChrome.height)
            plan.clip = CGRect(x: 0, y: top + TranscriptRowChrome.height + 2, width: width, height: list)
            plan.list = list
        }
        if let body {
            let height = body.height(width: width)
            plan.body = CGRect(x: 0, y: next(height), width: width, height: height)
        }
        if let figures, !figures.isEmpty {
            let height = figures.height(width: width)
            plan.figures = CGRect(x: 0, y: next(height), width: width, height: height)
        }
        if let turnLine {
            let height = turnLine.height(width: width)
            plan.turn = CGRect(x: 0, y: next(height), width: width, height: height)
        }
        plan.height = y + 10
        return plan
    }
    override func contentHeight(width: CGFloat) -> CGFloat { plan(width: width).height }
    override func place(in rect: CGRect) {
        let plan = plan(width: rect.width)
        func shifted(_ frame: CGRect) -> CGRect { frame.offsetBy(dx: rect.minX, dy: rect.minY) }
        header.frame = shifted(plan.header)
        clip.frame = shifted(plan.clip)
        if open {
            // The list at its own height inside the clip.
            let width = rect.width, inner = max(1, width - 12)
            let height = plan.list
            list.frame = CGRect(x: 0, y: 0, width: width, height: height)
            rule.frame = TranscriptMotion.mirrored(CGRect(x: 2, y: 2, width: 2, height: max(0, height - 6)), width: width, rightToLeft)
            var y: CGFloat = 2
            for view in works {
                let h = view.height(width: inner)
                view.frame = TranscriptMotion.mirrored(CGRect(x: 12, y: y, width: inner, height: h), width: width, rightToLeft)
                y += h + 6
            }
        }
        body?.frame = shifted(plan.body)
        figures?.frame = shifted(plan.figures)
        turnLine?.frame = shifted(plan.turn)
    }
}

/// A plain flipped container that can clip what it holds and refuse the
/// pointer while what it holds is folded away.
@MainActor final class TranscriptClipView: NSView {
    var blocksInput = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { blocksInput ? nil : super.hitTest(point) }
}
