import AppKit

/// A run failure, drawn by AppKit where the conversation stopped: a red mark
/// and "Something went wrong", what failed, and what the helper said about it,
/// in a tinted card; a failed run offers to retry. It reads and measures as
/// `FailureRowView` did.
@MainActor final class TranscriptNativeFailureRow: NSView, TranscriptRowContent {
    /// The hosted row's room above and below a message that is not the reader's.
    static let rowTop: CGFloat = 4, rowBottom: CGFloat = 10
    /// The card's own room around it, and inside it.
    static let margin: CGFloat = 8
    static let padding = CGSize(width: 14, height: 10)
    static let spacing: CGFloat = 6
    static let markSize: CGFloat = 18
    static let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let bodyFace = TranscriptPlainTextFace(size: 13, monospaced: false, lineSpacing: 0, label: "Error")
    static let detailFace = TranscriptPlainTextFace(size: 12, monospaced: false, lineSpacing: 0, label: "Detail")

    weak var owner: TranscriptRowContainer?
    private var inputs: TranscriptRowInputs
    private let card = TranscriptPanel()
    private let mark = TranscriptPanel()
    private let bang = TranscriptLabel()
    private let title = TranscriptLabel()
    private let body = TranscriptPlainTextView()
    private let detail = TranscriptPlainTextView()
    private var retry: TranscriptPillButton?
    override var isFlipped: Bool { true }

    static func message(of item: TranscriptItem) -> TranscriptMessage? {
        guard case .message(let message) = item, message.kind == "failure",
              message.failureCode?.hasPrefix(SessionDisplay.costLimitCode) != true else { return nil }
        return message
    }
    static func draws(_ item: TranscriptItem) -> Bool { message(of: item) != nil }

    init(inputs: TranscriptRowInputs) {
        self.inputs = inputs
        super.init(frame: .zero)
        card.cornerRadius = 12
        mark.cornerRadius = nil
        bang.text = "!"; bang.font = .systemFont(ofSize: 11, weight: .bold); bang.color = .white
        title.text = "Something went wrong"; title.font = Self.titleFont
        detail.isSelectable = false
        for view in [card, mark, bang, title, body, detail] as [NSView] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.group)
        apply(inputs)
    }
    required init?(coder: NSCoder) { nil }

    func accepts(_ item: TranscriptItem) -> Bool { Self.draws(item) }
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        owner?.contentSizeChanged()
    }
    private var message: TranscriptMessage { Self.message(of: inputs.item) ?? TranscriptMessage(id: "", role: "system", text: "") }
    /// A run failure can be retried from where it stopped; a refused send is retyped.
    private var retryable: Bool { message.id.hasPrefix("failure:run:") }

    func apply(_ inputs: TranscriptRowInputs) {
        self.inputs = inputs
        TranscriptAppearance.apply(inputs.environment, to: self)
        let message = message
        card.fill = TranscriptNSPalette.danger.withAlphaComponent(0.08)
        card.stroke = TranscriptNSPalette.danger.withAlphaComponent(0.35)
        mark.fill = TranscriptNSPalette.danger
        title.color = TranscriptNSPalette.danger
        body.update(text: message.text, face: Self.bodyFace, environment: inputs.environment, swiftUILines: true)
        body.isHidden = message.text.isEmpty
        detail.update(text: message.detail ?? "", face: Self.detailFace, environment: inputs.environment, swiftUILines: true,
                      color: TranscriptNSPalette.muted)
        detail.isHidden = (message.detail ?? "").isEmpty
        if retryable {
            let button = retry ?? {
                let button = TranscriptPillButton(title: "Retry request", accent: true, symbol: "arrow.clockwise", font: .systemFont(ofSize: 11.5, weight: .medium),
                                                  perform: {})
                button.setAccessibilityElement(true); button.setAccessibilityRole(.button)
                button.setAccessibilityIdentifier("retry-run"); button.setAccessibilityLabel("Retry request")
                button.toolTip = "Send the failed request again from where the turn stopped, with this chat's current model and effort; queued follow-ups continue after it"
                addSubview(button); retry = button
                return button
            }()
            let actions = inputs.actions
            button.perform = { actions.retry() }
            button.enabled = inputs.environment.isEnabled
        } else if let retry {
            retry.removeFromSuperview(); self.retry = nil
        }
        setAccessibilityLabel("Error: \(message.text)")
        needsLayout = true
    }

    // MARK: Geometry

    private struct Plan { var card, mark, title, body, detail, retry: CGRect; var height: CGFloat }
    private func plan(width: CGFloat) -> Plan {
        let inner = max(1, width - 2 * Self.padding.width)
        let titleSize = title.intrinsicSize
        let pill = retry?.pillSize ?? .zero
        let header = max(Self.markSize, titleSize.height, pill.height)
        let bodyHeight = body.isHidden ? 0 : body.exactHeight(width: inner)
        let detailHeight = detail.isHidden ? 0 : detail.exactHeight(width: inner)
        var stack = header
        if !body.isHidden { stack += Self.spacing + bodyHeight }
        if !detail.isHidden { stack += Self.spacing + detailHeight }
        let cardHeight = stack + 2 * Self.padding.height
        // SwiftUI gives a card with a pill in its header a point more above
        // and below (measured: the card's own frame is the same).
        let margin = Self.margin + (retry == nil ? 0 : 1)
        let content = Self.rowTop + margin + cardHeight + margin + Self.rowBottom
        let height = ceil(content), offset = (height - content) / 2
        let card = CGRect(x: 0, y: offset + Self.rowTop + margin, width: width, height: cardHeight)
        let x = Self.padding.width, top = card.minY + Self.padding.height
        let mark = CGRect(x: x, y: top + (header - Self.markSize) / 2, width: Self.markSize, height: Self.markSize)
        let title = CGRect(x: mark.maxX + 8, y: top + (header - titleSize.height) / 2, width: titleSize.width, height: titleSize.height)
        let retry = CGRect(x: card.maxX - Self.padding.width - pill.width, y: top + (header - pill.height) / 2, width: pill.width, height: pill.height)
        var y = top + header
        var bodyFrame = CGRect.zero, detailFrame = CGRect.zero
        if !body.isHidden { y += Self.spacing; bodyFrame = CGRect(x: x, y: y, width: inner, height: ceil(bodyHeight)); y += bodyHeight }
        if !detail.isHidden { y += Self.spacing; detailFrame = CGRect(x: x, y: y, width: inner, height: ceil(detailHeight)) }
        return Plan(card: card, mark: mark, title: title, body: bodyFrame, detail: detailFrame, retry: retry, height: height)
    }
    func settle() -> (height: CGFloat, passes: Int) {
        let plan = plan(width: bounds.width > 0 ? bounds.width : inputs.width)
        layoutSubtreeIfNeeded()
        return (max(1, plan.height), 1)
    }
    func confirmHeight() -> CGFloat { max(1, plan(width: bounds.width > 0 ? bounds.width : inputs.width).height) }

    override func layout() {
        super.layout()
        let plan = plan(width: bounds.width)
        let scale = window?.backingScaleFactor ?? 2
        let rtl = inputs.environment.layoutDirection == .rightToLeft
        func place(_ rect: CGRect) -> CGRect { TranscriptMotion.mirrored(rect, width: bounds.width, rtl) }
        card.frame = TranscriptMotion.pixelAligned(place(plan.card), scale: scale)
        mark.frame = TranscriptMotion.pixelAligned(place(plan.mark), scale: scale)
        let bangSize = bang.intrinsicSize
        bang.frame = CGRect(x: mark.frame.midX - bangSize.width / 2, y: mark.frame.midY - bangSize.height / 2, width: bangSize.width, height: bangSize.height)
        title.frame = place(plan.title)
        body.frame = place(plan.body)
        detail.frame = place(plan.detail)
        retry?.frame = place(plan.retry)
    }
}
