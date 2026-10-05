import AppKit

/// The quiet receipt under one request, drawn by AppKit as
/// `MessageAccountingView` drew it: which model answered (a link to the
/// request's details) and what the request reported, in one line of
/// fixed-width figures that wraps like a sentence in a narrow row. The rows
/// that carry a request's accounting — a sent message, a compaction, a
/// response's own line — all draw it with this.
@MainActor final class TranscriptNativeAccounting: NSView {
    static let font = NSFont.systemFont(ofSize: 10.5)
    /// The usage when it wraps.
    static let face = TranscriptPlainTextFace(size: 10.5, monospaced: false, lineSpacing: 0, label: "Usage", monospacedDigits: true)
    private let model = TranscriptLinkButton()
    private let dot = TranscriptLabel()
    private let usage = TranscriptLabel()
    /// The usage over several lines, built only when a row is too narrow for its one line.
    private var wrapped: TranscriptPlainTextView?
    /// The model's name over several lines, likewise; the link stays over it.
    private var wrappedModelText: TranscriptPlainTextView?
    static let modelFace = TranscriptPlainTextFace(size: 10.5, monospaced: false, lineSpacing: 0, label: "Model")
    private var environment = TranscriptRowEnvironment()
    private(set) var presentation = TranscriptActivity.AccountingPresentation(summary: "", detail: "", modelLabel: nil, usage: "")
    /// Laid out from the trailing edge, as a sent message's band sets it.
    var trailing = false { didSet { if trailing != oldValue { needsLayout = true } } }
    /// At most this many lines, the last cut short; zero for no limit. A text
    /// offered less height than all its lines keeps the lines that fit: a
    /// sent message's band is 22 points tall, so its line keeps one.
    var lineLimit = 0 {
        didSet {
            guard lineLimit != oldValue else { return }
            model.label.truncation = singleLine ? .tail : nil; usage.truncation = singleLine ? .tail : nil
            for text in [wrapped, wrappedModelText] { text?.maximumLines = lineLimit }
            needsLayout = true
        }
    }
    private var singleLine: Bool { lineLimit == 1 }
    /// Keeps the lines that fit in `height`.
    func limit(toHeight height: CGFloat) { lineLimit = max(1, Int((height / TranscriptLabel.lineHeight(Self.font) + 0.001).rounded(.down))) }
    /// Whether there is anything to draw: a request that reported nothing
    /// has no line at all, and takes no room or spacing.
    var isEmpty: Bool { presentation.summary.isEmpty }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        model.label.font = Self.font
        // `underline(true, color: .clear)`: the model never shows a line.
        model.underlinesOnHover = false
        model.toolTip = "View response-body and header models"
        dot.font = Self.font; dot.text = " · "
        usage.font = Self.font; usage.monospacedDigits = true
        for view in [model, dot, usage] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { nil }

    func update(_ accounting: GatewayTotals, environment: TranscriptRowEnvironment, inspect: @escaping () -> Void) {
        let next = TranscriptActivity.accountingPresentation(accounting)
        if next != presentation || environment != self.environment { needsLayout = true }
        presentation = next
        self.environment = environment
        let muted = TranscriptNSPalette.muted
        model.label.text = next.modelLabel ?? ""; model.label.color = muted
        model.setAccessibilityLabel(next.modelLabel.map { "View model reports: \($0)" })
        model.perform = inspect
        model.enabled = environment.isEnabled
        model.isHidden = next.modelLabel == nil
        dot.color = muted
        dot.isHidden = next.modelLabel == nil || next.usage.isEmpty
        usage.text = next.usage; usage.color = muted
        wrappedModelText?.update(text: next.modelLabel ?? "", face: Self.modelFace, environment: environment, swiftUILines: true, color: muted)
        wrapped?.update(text: next.usage, face: Self.face, environment: environment, swiftUILines: true, color: muted)
        toolTip = next.detail.isEmpty ? nil : next.detail
        setAccessibilityLabel(next.summary.isEmpty ? nil : "\(next.summary). \(next.detail)")
        setAccessibilityElement(!next.summary.isEmpty)
    }

    private var wrappedUsage: TranscriptPlainTextView {
        if let wrapped { return wrapped }
        let text = TranscriptPlainTextView()
        text.isSelectable = false
        text.setAccessibilityElement(false)
        text.maximumLines = lineLimit
        text.update(text: presentation.usage, face: Self.face, environment: environment, swiftUILines: true, color: TranscriptNSPalette.muted)
        addSubview(text); wrapped = text
        return text
    }

    private var wrappedModel: TranscriptPlainTextView {
        if let wrappedModelText { return wrappedModelText }
        let text = TranscriptPlainTextView()
        text.isSelectable = false
        text.setAccessibilityElement(false)
        text.maximumLines = lineLimit
        text.update(text: presentation.modelLabel ?? "", face: Self.modelFace, environment: environment, swiftUILines: true, color: TranscriptNSPalette.muted)
        // Under the link, which takes the click.
        addSubview(text, positioned: .below, relativeTo: model); wrappedModelText = text
        return text
    }
    /// A text piece: its one line when it fits, else wrapped in what it is offered.
    private func piece(_ label: TranscriptLabel, wrapped: @escaping () -> TranscriptPlainTextView) -> TranscriptLinePiece {
        // An empty `Text` (the usage of a request that reported only its
        // model) is no line of its font: SwiftUI gives it its own height.
        let ideal = label.text.isEmpty ? CGSize(width: 0, height: TranscriptLabel.emptyTextHeight) : label.intrinsicSize, single = singleLine
        return TranscriptLinePiece(minWidth: 0, maxWidth: ideal.width, size: { offered in
            let width = min(ideal.width, max(0, offered))
            guard width < ideal.width else { return ideal }
            if single { return CGSize(width: label.width(truncatedTo: width), height: ideal.height) }
            let text = wrapped()
            return CGSize(width: text.usedWidth(width: width), height: text.exactHeight(width: width))
        })
    }
    /// The line's pieces as SwiftUI's `HStack` shares `width` out: the dot
    /// keeps its one line, the model and the usage wrap in what is left.
    private func line(width: CGFloat) -> (sizes: [CGSize], views: [NSView]) {
        var pieces: [TranscriptLinePiece] = [], views: [NSView] = []
        if presentation.modelLabel != nil {
            pieces.append(piece(model.label) { [unowned self] in wrappedModel }); views.append(model)
            if !presentation.usage.isEmpty { pieces.append(.fixed(dot.intrinsicSize)); views.append(dot) }
        }
        pieces.append(piece(usage) { [unowned self] in wrappedUsage })
        views.append(usage)
        return (TranscriptLineLayout.sizes(pieces, spacing: [CGFloat](repeating: 0, count: pieces.count - 1), width: width), views)
    }
    /// How tall the line is at `width`: nothing when there is nothing to say.
    func height(width: CGFloat) -> CGFloat {
        guard !isEmpty else { return 0 }
        return line(width: width).sizes.map(\.height).max() ?? 0
    }

    override func layout() {
        super.layout()
        guard !isEmpty else { return }
        let (sizes, views) = line(width: bounds.width)
        let total = sizes.reduce(0) { $0 + $1.width }
        let frames = TranscriptLineLayout.frames(sizes, spacing: [CGFloat](repeating: 0, count: max(0, sizes.count - 1)),
                                                 x: trailing ? bounds.width - total : 0, midY: bounds.height / 2)
        let rtl = environment.layoutDirection == .rightToLeft
        let usageWraps = !singleLine && (sizes.last?.width ?? 0) < usage.intrinsicSize.width
        let modelWraps = !singleLine && presentation.modelLabel != nil && sizes[0].width < model.label.intrinsicSize.width
        usage.isHidden = usageWraps
        wrapped?.isHidden = !usageWraps
        wrappedModelText?.isHidden = !modelWraps
        model.label.isHidden = modelWraps
        for (view, frame) in zip(views, frames) {
            let wraps = (view === usage && usageWraps) || (view === model && modelWraps)
            let rect = wraps ? CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: ceil(frame.height)) : frame
            if view === model, modelWraps { wrappedModel.frame = TranscriptMotion.mirrored(rect, width: bounds.width, rtl) }
            let target = view === usage && usageWraps ? wrappedUsage : view
            let placed = rect
            if target === model {
                // The link draws its name as a label does, from the right in a right-to-left row.
                model.frame = TranscriptMotion.mirrored(placed, of: model.label, width: bounds.width, rtl)
            } else {
                target.frame = TranscriptMotion.mirrored(placed, of: target, width: bounds.width, rtl)
            }
        }
    }
}
