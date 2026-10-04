import AppKit

/// Where a run stopped, drawn by AppKit in a tinted card: a mark and what
/// happened, the helper's own words, what it added, and the one thing to do
/// next. A failure is red, with "Something went wrong" and, for a run, Retry
/// request (`FailureRowView`); a cost limit is amber, with Raise limit… or,
/// once the limit is above the spend, Continue (`CostLimitNoticeRow`).
@MainActor final class TranscriptNativeFailureRow: TranscriptNativeMessageRow {
    /// The card's own room around it, and inside it.
    static let margin: CGFloat = 8
    static let padding = CGSize(width: 14, height: 10)
    static let spacing: CGFloat = 6
    static let markSize: CGFloat = 18
    static let titleFace = TranscriptPlainTextFace(size: 12.5, monospaced: false, lineSpacing: 0, label: "Title", weight: NSFont.Weight.semibold.rawValue)
    static let bodyFace = TranscriptPlainTextFace(size: 13, monospaced: false, lineSpacing: 0, label: "Error")
    static let detailFace = TranscriptPlainTextFace(size: 12, monospaced: false, lineSpacing: 0, label: "Detail")
    static let pillFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)

    private let card = TranscriptPanel()
    /// A failure's red disc with its "!".
    private let disc = TranscriptPanel()
    private let bang = TranscriptLabel()
    /// A cost limit's symbol.
    private let symbol = TranscriptSymbol()
    private let title = TranscriptPlainTextView()
    private let body = TranscriptPlainTextView()
    private let detail = TranscriptPlainTextView()
    private var pill: TranscriptPillButton?
    /// Raise limit… opens the chat's limit editor as a popover over itself.
    private var trigger: PiPopoverTriggerButton?

    override class func message(of item: TranscriptItem) -> TranscriptMessage? {
        guard case .message(let message) = item, message.kind == "failure" else { return nil }
        return message
    }
    override init(inputs: TranscriptRowInputs) {
        super.init(inputs: inputs)
        card.cornerRadius = 12
        disc.cornerRadius = nil; disc.circular = true
        bang.text = "!"; bang.font = .systemFont(ofSize: 11, weight: .bold); bang.color = .white
        title.isSelectable = false; title.setAccessibilityElement(false)
        detail.isSelectable = false
        for view in [card, disc, bang, symbol, title, body, detail] as [NSView] { addSubview(view) }
        apply(inputs)
    }
    required init?(coder: NSCoder) { nil }

    /// What the card says and does.
    private enum Kind: Equatable {
        case failure(retry: Bool)
        /// At the limit, or (`raised`) with the limit above the spend again;
        /// `run`: a stopped run rather than a refused message.
        case costLimit(raised: Bool, run: Bool)
    }
    private var kind: Kind {
        let message = message
        let run = message.id.hasPrefix("failure:run:")
        guard message.failureCode?.hasPrefix(SessionDisplay.costLimitCode) == true else { return .failure(retry: run) }
        return .costLimit(raised: message.failureCode == SessionDisplay.costLimitRaised, run: run)
    }
    /// The pill the header offers, if any.
    private enum Offer: Equatable { case retry, continueRun, raise }
    private var offer: Offer? {
        switch kind {
        case .failure(let retry): return retry ? .retry : nil
        case .costLimit(let raised, let run): return raised ? (run ? .continueRun : nil) : .raise
        }
    }
    private var tint: NSColor {
        switch kind {
        case .failure: return TranscriptNSPalette.danger
        case .costLimit(let raised, _): return raised ? TranscriptNSPalette.accent : TranscriptNSPalette.warning
        }
    }

    override func configure() {
        let message = message, kind = kind, environment = inputs.environment
        let titleText: String
        switch kind {
        case .failure:
            card.fill = TranscriptNSPalette.danger.withAlphaComponent(0.08)
            card.stroke = TranscriptNSPalette.danger.withAlphaComponent(0.35)
            disc.fill = TranscriptNSPalette.danger
            titleText = "Something went wrong"
            setAccessibilityLabel("Error: \(message.text)")
            setAccessibilityIdentifier(nil)
        case .costLimit(let raised, let run):
            card.fill = raised ? TranscriptNSPalette.accentSoft : TranscriptNSPalette.warning.withAlphaComponent(0.09)
            card.stroke = (raised ? TranscriptNSPalette.accent : TranscriptNSPalette.warning).withAlphaComponent(0.35)
            symbol.show(raised ? "checkmark.circle.fill" : "dollarsign.circle.fill", size: 15, weight: .semibold)
            symbol.contentTintColor = tint
            titleText = raised ? "Cost limit raised" : run ? "Stopped at this chat's cost limit" : "This chat is at its cost limit"
            setAccessibilityLabel((raised ? "Cost limit raised: " : "Cost limit reached: ") + message.text)
            setAccessibilityIdentifier("cost-limit-notice")
        }
        title.update(text: titleText, face: Self.titleFace, environment: environment, swiftUILines: true, color: tint)
        body.update(text: message.text, face: Self.bodyFace, environment: environment, swiftUILines: true)
        detail.update(text: message.detail ?? "", face: Self.detailFace, environment: environment, swiftUILines: true, color: TranscriptNSPalette.muted)
        configurePill()
    }
    override func hides(_ view: NSView) -> Bool {
        let failure: Bool
        if case .failure = kind { failure = true } else { failure = false }
        return ((view === disc || view === bang) && !failure) || (view === symbol && failure)
            || (view === body && message.text.isEmpty) || (view === detail && (message.detail ?? "").isEmpty)
    }

    private func configurePill() {
        let offer = offer, actions = inputs.actions
        if pill?.title != offer.map(Self.title) {
            pill?.removeFromSuperview(); pill = nil
            trigger?.removeFromSuperview(); trigger = nil
        }
        guard let offer else { return }
        let button = pill ?? {
            let button: TranscriptPillButton
            switch offer {
            case .retry:
                button = TranscriptPillButton(title: Self.title(offer), accent: true, symbol: "arrow.clockwise", font: Self.pillFont, perform: {})
                button.setAccessibilityIdentifier("retry-run")
                button.toolTip = "Send the failed request again from where the turn stopped, with this chat's current model and effort; queued follow-ups continue after it"
            case .continueRun:
                button = TranscriptPillButton(title: Self.title(offer), accent: true, symbol: "play.fill", font: Self.pillFont, perform: {})
                button.setAccessibilityIdentifier("cost-limit-continue")
                button.toolTip = "Send the stopped request again from where the run stopped, with this chat's current model and effort; queued follow-ups go on after it"
            case .raise:
                // Its own face, with an AppKit press target over it that the
                // limit editor's popover is anchored to.
                button = TranscriptPillButton(title: Self.title(offer), accent: true, symbol: "arrow.up.circle", font: Self.pillFont, perform: {})
                button.style = .raise; button.wraps = false
                let trigger = PiPopoverTriggerButton(frame: .zero)
                trigger.toolTip = "Choose a higher limit for this chat, or no limit"
                trigger.setAccessibilityLabel(Self.title(offer)); trigger.setAccessibilityIdentifier("cost-limit-raise")
                trigger.onHover = { [weak button] in button?.setHovering($0) }
                button.addSubview(trigger); self.trigger = trigger
            }
            if offer != .raise {
                button.setAccessibilityElement(true); button.setAccessibilityRole(.button)
                button.setAccessibilityLabel(Self.title(offer)); button.focusable = true
            }
            addSubview(button); pill = button
            return button
        }()
        switch offer {
        case .retry: button.perform = { actions.retry() }
        case .continueRun: button.perform = { actions.costLimit?(.continueRun, nil) }
        case .raise:
            button.perform = {}
            trigger?.onPress = { anchor in actions.costLimit?(.raise, anchor) }
            trigger?.isEnabled = inputs.environment.isEnabled
        }
        button.enabled = inputs.environment.isEnabled
        button.rightToLeft = rightToLeft
    }
    nonisolated private static func title(_ offer: Offer) -> String {
        switch offer {
        case .retry: return "Retry request"
        case .continueRun: return "Continue"
        case .raise: return "Raise limit…"
        }
    }

    // MARK: Geometry

    /// The mark: a failure's 18-point disc, or a cost limit's symbol as
    /// SwiftUI lays an image out, its outline's size.
    private var markSize: CGSize {
        if case .failure = kind { return CGSize(width: Self.markSize, height: Self.markSize) }
        return symbol.swiftUIFrame ?? symbol.image?.size ?? .zero
    }
    /// The header line as SwiftUI's `HStack` shares it: the mark, the title
    /// (which wraps in a narrow card), a spacer and the pill (whose title
    /// wraps too, unless it is Raise limit…, which keeps its one line).
    private func header(inner: CGFloat) -> (sizes: [CGSize], spacing: [CGFloat]) {
        let title = title
        var pieces: [TranscriptLinePiece] = [.fixed(markSize),
                                             .text(ideal: title.idealWidth, used: { title.usedWidth(width: $0) }, height: { title.exactHeight(width: $0) }),
                                             .spacer()]
        if let pill {
            pieces.append(pill.wraps ? TranscriptLinePiece(minWidth: 0, maxWidth: pill.pillSize.width, size: { pill.size(offered: $0) })
                                     : .fixed(pill.pillSize))
        }
        let spacing = [CGFloat](repeating: 8, count: pieces.count - 1)
        return (TranscriptLineLayout.sizes(pieces, spacing: spacing, width: inner), spacing)
    }
    private struct Plan { var card, mark, title, body, detail, pill: CGRect; var height: CGFloat }
    private func plan(width: CGFloat) -> Plan {
        let inner = max(1, width - 2 * Self.padding.width)
        let line = header(inner: inner)
        let header = line.sizes.map(\.height).max() ?? 0
        let hasBody = !message.text.isEmpty, hasDetail = !(message.detail ?? "").isEmpty
        let bodyHeight = hasBody ? body.exactHeight(width: inner) : 0
        let detailHeight = hasDetail ? detail.exactHeight(width: inner) : 0
        var stack = header
        if hasBody { stack += Self.spacing + bodyHeight }
        if hasDetail { stack += Self.spacing + detailHeight }
        let cardHeight = stack + 2 * Self.padding.height
        let margin = Self.margin
        let card = CGRect(x: 0, y: margin, width: width, height: cardHeight)
        let top = card.minY + Self.padding.height
        let frames = TranscriptLineLayout.frames(line.sizes, spacing: line.spacing, x: Self.padding.width, midY: top + header / 2)
        var y = top + header
        var bodyFrame = CGRect.zero, detailFrame = CGRect.zero
        let x = Self.padding.width
        if hasBody { y += Self.spacing; bodyFrame = CGRect(x: x, y: y, width: inner, height: ceil(bodyHeight)); y += bodyHeight }
        if hasDetail { y += Self.spacing; detailFrame = CGRect(x: x, y: y, width: inner, height: ceil(detailHeight)) }
        return Plan(card: card, mark: frames[0], title: frames[1], body: bodyFrame, detail: detailFrame,
                    pill: pill == nil ? .zero : frames[3], height: margin + cardHeight + margin)
    }
    override func contentHeight(width: CGFloat) -> CGFloat { plan(width: width).height }
    override func place(in rect: CGRect) {
        let plan = plan(width: rect.width)
        func shifted(_ frame: CGRect) -> CGRect { frame.offsetBy(dx: rect.minX, dy: rect.minY) }
        card.frame = pixelAligned(shifted(plan.card))
        disc.frame = pixelAligned(shifted(plan.mark))
        let bangSize = bang.intrinsicSize
        bang.frame = CGRect(x: disc.frame.midX - bangSize.width / 2, y: disc.frame.midY - bangSize.height / 2, width: bangSize.width, height: bangSize.height)
        if let image = symbol.image {
            // The image is drawn whole, in the middle of SwiftUI's frame for it.
            let mark = shifted(plan.mark)
            symbol.frame = CGRect(x: mark.midX - image.size.width / 2, y: mark.midY - image.size.height / 2, width: image.size.width, height: image.size.height)
        }
        title.frame = shifted(plan.title)
        body.frame = shifted(plan.body)
        detail.frame = shifted(plan.detail)
        pill?.frame = shifted(plan.pill)
        trigger?.frame = pill?.bounds ?? .zero
    }
}
