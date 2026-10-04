import AppKit

/// What every native row drawing one message shares: the inputs it is given,
/// the room the hosted row left above and below a message that is not the
/// reader's, a whole number of points of height with the content in its
/// middle, and nothing at all once its turn's fold has emptied it.
///
/// A subclass says what it draws (`configure`), how tall that is at a width
/// (`contentHeight`) and where it goes (`place`).
@MainActor class TranscriptNativeMessageRow: NSView, TranscriptRowContent {
    /// The hosted row's room above and below a message that is not the reader's.
    class var rowTop: CGFloat { 4 }
    class var rowBottom: CGFloat { 10 }

    weak var owner: TranscriptRowContainer?
    private(set) var inputs: TranscriptRowInputs
    override var isFlipped: Bool { true }

    init(inputs: TranscriptRowInputs) {
        self.inputs = inputs
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { nil }

    /// The message this row draws, when it can draw `item`.
    class func message(of item: TranscriptItem) -> TranscriptMessage? { nil }
    class func draws(_ item: TranscriptItem) -> Bool { message(of: item) != nil }
    func accepts(_ item: TranscriptItem) -> Bool { Self.draws(item) }
    var message: TranscriptMessage { Self.message(of: inputs.item) ?? TranscriptMessage(id: "", role: "system", text: "") }
    /// A row its turn's fold has emptied draws nothing and says nothing.
    var drawsNothing: Bool { inputs.disclosure.foldedAway }
    var rightToLeft: Bool { inputs.environment.layoutDirection == .rightToLeft }

    /// Anything that says this content's size changed tells the row, as the
    /// SwiftUI host's intrinsic size did.
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        owner?.contentSizeChanged()
    }

    func apply(_ inputs: TranscriptRowInputs) {
        self.inputs = inputs
        TranscriptAppearance.apply(inputs.environment, to: self)
        configure()
        setAccessibilityElement(!drawsNothing)
        for view in subviews { view.isHidden = drawsNothing || hides(view) }
        needsLayout = true
    }
    /// Sets the row's pieces from `inputs`.
    func configure() {}
    /// Whether a piece stays hidden while the row draws.
    func hides(_ view: NSView) -> Bool { false }
    /// The content's height at `width`, without the row's own room.
    func contentHeight(width: CGFloat) -> CGFloat { 0 }
    /// Places the content in `rect`, laid out left to right; the row mirrors
    /// it for a right-to-left reader.
    func place(in rect: CGRect) {}

    private func height(width: CGFloat) -> (height: CGFloat, top: CGFloat) {
        guard !drawsNothing else { return (0, 0) }
        let content = Self.rowTop + contentHeight(width: width) + Self.rowBottom
        // A whole number of points tall, the content in the middle, as SwiftUI placed it.
        let height = ceil(content)
        return (height, (height - content) / 2 + Self.rowTop)
    }
    func settle() -> (height: CGFloat, passes: Int) {
        let height = height(width: bounds.width > 0 ? bounds.width : inputs.width).height
        layoutSubtreeIfNeeded()
        return (max(1, height), 1)
    }
    func confirmHeight() -> CGFloat { max(1, height(width: bounds.width > 0 ? bounds.width : inputs.width).height) }

    override func layout() {
        super.layout()
        guard !drawsNothing else { return }
        let (_, top) = height(width: bounds.width)
        place(in: CGRect(x: 0, y: top, width: bounds.width, height: contentHeight(width: bounds.width)))
        // A pill fading out keeps the place it was given; only what was just placed mirrors.
        if rightToLeft { for view in subviews where view.identifier != TranscriptMotion.leaving { view.frame = TranscriptMotion.mirrored(view.frame, width: bounds.width, true) } }
    }
    /// `rect` on the pixel grid, as SwiftUI places a shape.
    func pixelAligned(_ rect: CGRect) -> CGRect {
        TranscriptMotion.pixelAligned(rect, scale: window?.backingScaleFactor ?? 2)
    }
}

/// A transient status line inside the conversation, such as a retry in
/// progress: a dashed rule each side of a turning ring and the words, as
/// `NoticeRowView` drew it.
@MainActor final class TranscriptNativeNoticeRow: TranscriptNativeMessageRow {
    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private let leadingRule = TranscriptDashedLine()
    private let trailingRule = TranscriptDashedLine()
    private let spinner = TranscriptSpinner()
    private let label = TranscriptLabel()
    override class func message(of item: TranscriptItem) -> TranscriptMessage? {
        guard case .message(let message) = item, message.kind == "notice" else { return nil }
        return message
    }
    override init(inputs: TranscriptRowInputs) {
        super.init(inputs: inputs)
        label.font = Self.font
        for view in [leadingRule, spinner, label, trailingRule] { addSubview(view) }
        apply(inputs)
    }
    required init?(coder: NSCoder) { nil }
    override func configure() {
        label.text = message.text; label.color = TranscriptNSPalette.muted
        setAccessibilityLabel("Status: \(message.text)")
    }
    private let spacing: [CGFloat] = [8, 8, 8]
    private func line(width: CGFloat) -> [CGSize] {
        let text = label.intrinsicSize
        return TranscriptLineLayout.sizes([.flexible(height: 1), .fixed(CGSize(width: TranscriptSpinner.size, height: TranscriptSpinner.size)),
                                           .fixed(text), .flexible(height: 1)], spacing: spacing, width: width)
    }
    /// The line, and six points of room above and below it.
    override func contentHeight(width: CGFloat) -> CGFloat { 6 + (line(width: width).map(\.height).max() ?? 0) + 6 }
    override func place(in rect: CGRect) {
        let sizes = line(width: rect.width)
        let frames = TranscriptLineLayout.frames(sizes, spacing: spacing, x: rect.minX, midY: rect.minY + 6 + (sizes.map(\.height).max() ?? 0) / 2)
        for (view, frame) in zip([leadingRule, spinner, label, trailingRule] as [NSView], frames) { view.frame = frame }
        spinner.frame = pixelAligned(spinner.frame)
    }
}

/// Where an edit branched the conversation: "Edited from here" between two
/// dashed rules, with what the edit said, as `BranchRowView` drew it.
@MainActor final class TranscriptNativeBranchRow: TranscriptNativeMessageRow {
    static let titleFont = NSFont.systemFont(ofSize: 12)
    static let detailFace = TranscriptPlainTextFace(size: 11.5, monospaced: false, lineSpacing: 0, label: "Edit")
    private let leadingRule = TranscriptDashedLine()
    private let trailingRule = TranscriptDashedLine()
    private let title = TranscriptLabel()
    private let detail = TranscriptPlainTextView()
    override class func message(of item: TranscriptItem) -> TranscriptMessage? {
        guard case .message(let message) = item, message.kind == "branch" else { return nil }
        return message
    }
    override init(inputs: TranscriptRowInputs) {
        super.init(inputs: inputs)
        title.font = Self.titleFont; title.text = "Edited from here"
        detail.isSelectable = false; detail.maximumLines = 2
        for view in [leadingRule, title, detail, trailingRule] { addSubview(view) }
        apply(inputs)
    }
    required init?(coder: NSCoder) { nil }
    private var detailText: String? { message.detail ?? (message.text.isEmpty ? nil : message.text) }
    override func configure() {
        title.color = TranscriptNSPalette.muted
        detail.update(text: detailText ?? "", face: Self.detailFace, environment: inputs.environment, swiftUILines: true, color: TranscriptNSPalette.faint)
        setAccessibilityLabel("Edited from here")
    }
    override func hides(_ view: NSView) -> Bool { view === detail && detailText == nil }
    private func line(width: CGFloat) -> (sizes: [CGSize], spacing: [CGFloat], views: [NSView]) {
        var pieces: [TranscriptLinePiece] = [.flexible(height: 1), .fixed(title.intrinsicSize)]
        var views: [NSView] = [leadingRule, title]
        if detailText != nil {
            let detail = detail
            pieces.append(.text(ideal: detail.idealWidth, used: { detail.usedWidth(width: $0) }, height: { detail.exactHeight(width: $0) }))
            views.append(detail)
        }
        pieces.append(.flexible(height: 1)); views.append(trailingRule)
        let spacing = [CGFloat](repeating: 8, count: pieces.count - 1)
        return (TranscriptLineLayout.sizes(pieces, spacing: spacing, width: width), spacing, views)
    }
    override func contentHeight(width: CGFloat) -> CGFloat { 8 + (line(width: width).sizes.map(\.height).max() ?? 0) + 8 }
    override func place(in rect: CGRect) {
        let line = line(width: rect.width)
        let height = line.sizes.map(\.height).max() ?? 0
        let frames = TranscriptLineLayout.frames(line.sizes, spacing: line.spacing, x: rect.minX, midY: rect.minY + 8 + height / 2)
        for (view, frame) in zip(line.views, frames) { view.frame = frame }
    }
}

/// A status message from the app itself: "Status" over its words in a quiet
/// capsule, and the band whose actions show under the pointer, as
/// `MessageRowView` drew a system message.
@MainActor final class TranscriptNativeStatusRow: TranscriptNativeMessageRow {
    static let headerFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let failedFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let face = TranscriptPlainTextFace(size: 12, monospaced: false, lineSpacing: 0, label: "Status")
    static let capsulePadding = CGSize(width: 14, height: 6)
    static let spacing: CGFloat = 6
    static let bandHeight: CGFloat = 22
    private let header = TranscriptLabel()
    private let failed = TranscriptLabel()
    private let capsule = TranscriptPanel()
    private let words = TranscriptPlainTextView()
    private let truncated = TranscriptPlainTextView()
    private lazy var band = TranscriptPillBand(host: self)
    private var hover: TranscriptHoverTracker!
    private var hovering = false
    override class func message(of item: TranscriptItem) -> TranscriptMessage? {
        guard case .message(let message) = item, message.role == "system", message.kind == nil,
              (message.accounting?.requests ?? 0) == 0 else { return nil }
        return message
    }
    override init(inputs: TranscriptRowInputs) {
        super.init(inputs: inputs)
        header.font = Self.headerFont; header.text = "Status"
        failed.font = Self.failedFont
        capsule.cornerRadius = nil
        words.isSelectable = false; words.centred = true
        truncated.isSelectable = false
        for view in [header, failed, capsule, words, truncated] as [NSView] { addSubview(view) }
        hover = TranscriptHoverTracker(view: self) { [weak self] inside in self?.hovering = inside; self?.refreshBand() }
        apply(inputs)
    }
    required init?(coder: NSCoder) { nil }
    override func configure() {
        let message = message
        header.color = TranscriptNSPalette.muted
        failed.text = message.failedEnd ?? ""; failed.color = TranscriptNSPalette.danger
        failed.speak(message.failedEnd)
        capsule.fill = TranscriptNSPalette.statusBackground
        words.update(text: message.text, face: Self.face, environment: inputs.environment, swiftUILines: true, color: TranscriptNSPalette.muted)
        truncated.update(text: TranscriptNativeReplyRow.truncatedNote, face: TranscriptNativeReplyRow.truncatedFace, environment: inputs.environment,
                         swiftUILines: true, color: TranscriptNSPalette.muted)
        setAccessibilityLabel("\(message.role) message")
        setAccessibilityCustomActions(TranscriptRowAction.all(message, inputs.actions, forks: inputs.environment.forks)
            .map { action in NSAccessibilityCustomAction(name: action.name) { [weak self] in
                guard self?.inputs.environment.isEnabled == true else { return false }
                action.perform(); return true
            } })
        refreshBand()
    }
    override func hides(_ view: NSView) -> Bool {
        (view === failed && message.failedEnd == nil) || (view === truncated && message.truncated != true)
    }
    private func refreshBand() {
        let wanted = hovering && !drawsNothing ? RowActionsView.pills(message, actions: inputs.actions, forks: inputs.environment.forks, source: nil) : []
        band.show(wanted, enabled: inputs.environment.isEnabled)
    }
    private struct Plan { var header: CGFloat; var capsule: CGSize; var words: CGSize; var truncated: CGFloat; var height: CGFloat }
    private func plan(width: CGFloat) -> Plan {
        let headerHeight = max(header.intrinsicSize.height, message.failedEnd == nil ? 0 : failed.intrinsicSize.height)
        let inner = max(1, width - 2 * Self.capsulePadding.width)
        let wordsSize = message.text.isEmpty ? CGSize.zero : CGSize(width: words.usedWidth(width: inner), height: words.exactHeight(width: inner))
        let capsule = CGSize(width: wordsSize.width + 2 * Self.capsulePadding.width, height: wordsSize.height + 2 * Self.capsulePadding.height)
        let truncatedHeight = message.truncated == true ? truncated.exactHeight(width: width) : 0
        var height = headerHeight + Self.spacing + capsule.height + Self.spacing
        if message.truncated == true { height += truncatedHeight + Self.spacing }
        return Plan(header: headerHeight, capsule: capsule, words: wordsSize, truncated: truncatedHeight, height: height + Self.bandHeight)
    }
    override func contentHeight(width: CGFloat) -> CGFloat { plan(width: width).height }
    override func place(in rect: CGRect) {
        let plan = plan(width: rect.width)
        // The header's words, together, in the middle of the line.
        let headerSize = header.intrinsicSize, failedSize = message.failedEnd == nil ? .zero : failed.intrinsicSize
        let headerWidth = headerSize.width + (message.failedEnd == nil ? 0 : 8 + failedSize.width)
        var x = rect.midX - headerWidth / 2
        header.frame = CGRect(x: x, y: rect.minY + (plan.header - headerSize.height) / 2, width: headerSize.width, height: headerSize.height)
        x += headerSize.width + 8
        failed.frame = CGRect(x: x, y: rect.minY + (plan.header - failedSize.height) / 2, width: failedSize.width, height: failedSize.height)
        var y = rect.minY + plan.header + Self.spacing
        let capsuleFrame = CGRect(x: rect.midX - plan.capsule.width / 2, y: y, width: plan.capsule.width, height: plan.capsule.height)
        capsule.frame = pixelAligned(capsuleFrame)
        words.frame = CGRect(x: capsuleFrame.minX + Self.capsulePadding.width, y: capsuleFrame.minY + Self.capsulePadding.height,
                             width: plan.words.width, height: ceil(plan.words.height))
        y = capsuleFrame.maxY + Self.spacing
        if message.truncated == true {
            truncated.frame = CGRect(x: rect.minX, y: y, width: rect.width, height: ceil(plan.truncated))
            y += plan.truncated + Self.spacing
        }
        // Placed left to right like the rest; the row mirrors them with it.
        band.place(maxX: rect.maxX, midY: y + Self.bandHeight / 2, width: bounds.width, rightToLeft: false)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.update(rect: CGRect(x: 0, y: Self.rowTop, width: bounds.width, height: max(0, bounds.height - Self.rowTop - Self.rowBottom)))
    }
    override func mouseEntered(with event: NSEvent) { hover.set(true) }
    override func mouseExited(with event: NSEvent) { hover.set(false) }
}

/// The quiet line over an earlier version of the conversation: what the
/// reader is looking at and the way back, in a capsule, as `VersionBannerRow`
/// drew it.
@MainActor final class TranscriptNativeVersionBannerRow: TranscriptNativeMessageRow {
    static let padding = CGSize(width: 12, height: 5)
    private let capsule = TranscriptPanel()
    private let marker = VersionBannerMarkerView()
    private let icon = TranscriptSymbol()
    private let title = TranscriptLabel()
    private let detail = TranscriptLabel()
    private let dots = [TranscriptPanel(), TranscriptPanel()]
    private let back = TranscriptLinkButton()
    override class func message(of item: TranscriptItem) -> TranscriptMessage? {
        guard case .message(let message) = item, message.kind == "versionBanner" else { return nil }
        return message
    }
    override init(inputs: TranscriptRowInputs) {
        super.init(inputs: inputs)
        capsule.cornerRadius = nil
        icon.show("clock.arrow.circlepath", size: 11, weight: .medium)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        detail.font = .systemFont(ofSize: 12); detail.truncation = .tail
        for dot in dots { dot.cornerRadius = 1 }
        back.label.font = .systemFont(ofSize: 12, weight: .medium); back.label.text = "Back to latest"
        back.setAccessibilityIdentifier("version-back-to-latest")
        for view in [marker, capsule, icon, title, detail] + dots as [NSView] { addSubview(view) }
        addSubview(back)
        setAccessibilityIdentifier("version-banner")
        apply(inputs)
    }
    required init?(coder: NSCoder) { nil }
    override func configure() {
        let message = message, actions = inputs.actions
        capsule.fill = TranscriptNSPalette.panel; capsule.stroke = TranscriptNSPalette.hair
        icon.contentTintColor = TranscriptNSPalette.faint
        title.text = message.text; title.color = TranscriptNSPalette.muted
        detail.text = message.detail ?? ""; detail.color = TranscriptNSPalette.faint
        for dot in dots { dot.fill = TranscriptNSPalette.faint }
        back.label.color = TranscriptNSPalette.accent
        back.perform = { actions.latestVersion?() }
        back.enabled = inputs.environment.isEnabled
        setAccessibilityLabel("Earlier version, replies from before your edit")
    }
    private func line(width: CGFloat) -> [CGSize] {
        let image = icon.image
        let iconSize = CGSize(width: image?.alignmentRect.width ?? 0, height: image?.size.height ?? 0)
        let detailIdeal = detail.intrinsicSize
        let pieces: [TranscriptLinePiece] = [
            .fixed(iconSize), .fixed(title.intrinsicSize), .fixed(CGSize(width: 2, height: 2)),
            TranscriptLinePiece(minWidth: 0, maxWidth: detailIdeal.width, size: { [detail] in CGSize(width: detail.width(truncatedTo: $0), height: detailIdeal.height) }),
            .fixed(CGSize(width: 2, height: 2)), .fixed(back.size)]
        return TranscriptLineLayout.sizes(pieces, spacing: [6, 6, 6, 6, 6], width: max(0, width - 2 * Self.padding.width))
    }
    /// Six points above the capsule and twelve below it.
    override func contentHeight(width: CGFloat) -> CGFloat {
        6 + (line(width: width).map(\.height).max() ?? 0) + 2 * Self.padding.height + 12
    }
    override func place(in rect: CGRect) {
        let sizes = line(width: rect.width)
        let height = sizes.map(\.height).max() ?? 0
        let content = sizes.reduce(0) { $0 + $1.width } + 6 * CGFloat(sizes.count - 1)
        let capsuleFrame = CGRect(x: rect.midX - (content + 2 * Self.padding.width) / 2, y: rect.minY + 6,
                                  width: content + 2 * Self.padding.width, height: height + 2 * Self.padding.height)
        capsule.frame = pixelAligned(capsuleFrame)
        marker.frame = capsule.frame
        let frames = TranscriptLineLayout.frames(sizes, spacing: [6, 6, 6, 6, 6], x: capsuleFrame.minX + Self.padding.width, midY: capsuleFrame.midY)
        if let image = icon.image {
            icon.frame = CGRect(x: frames[0].minX - image.alignmentRect.minX, y: frames[0].minY, width: image.size.width, height: image.size.height)
        }
        title.frame = frames[1]
        dots[0].frame = pixelAligned(frames[2])
        detail.frame = frames[3]
        dots[1].frame = pixelAligned(frames[4])
        back.frame = frames[5]
    }
}
