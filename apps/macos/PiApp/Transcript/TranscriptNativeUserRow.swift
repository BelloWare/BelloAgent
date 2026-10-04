import AppKit

/// A message the reader sent, drawn by AppKit: the text exactly as typed in
/// its bubble at the trailing edge, and under it one quiet band with the time
/// it was sent and, under the pointer, its actions. It reads and measures as
/// `MessageRowView` did for the same message.
@MainActor final class TranscriptNativeUserRow: NSView, TranscriptRowContent {
    /// Above the bubble and below the band, as the hosted row padded it.
    static let top: CGFloat = 14
    static let bottom: CGFloat = 4
    /// Between the bubble and the band.
    static let gap: CGFloat = 6
    static let bandHeight: CGFloat = 22
    /// The room the bubble always leaves on its leading side.
    static let leadingRoom: CGFloat = 40
    static let padding = CGSize(width: 14, height: 9)
    static let clockFont = NSFont.systemFont(ofSize: 10.5)

    weak var owner: TranscriptRowContainer?
    private var inputs: TranscriptRowInputs
    private let bubble = TranscriptPanel()
    private let text = TranscriptPlainTextView()
    private let clock = TranscriptLabel()
    private var pills: [TranscriptPillButton] = []
    private var hover: TranscriptHoverTracker!
    private var hovering = false
    private var sendingShown = false
    private var sendingTimer: Timer?
    private var message: TranscriptMessage {
        if case .message(let message) = inputs.item { return message }
        return TranscriptMessage(id: "", role: "user", text: "")
    }
    override var isFlipped: Bool { true }

    /// Whether this row can draw `item`: a message the reader typed, with
    /// none of the parts not ported yet.
    static func draws(_ item: TranscriptItem) -> Bool {
        guard case .message(let message) = item else { return false }
        return message.role == "user" && message.kind == nil && (message.skills ?? []).isEmpty
            && message.versions?.usable != true && message.truncated != true && message.failedEnd == nil
            && (message.accounting?.requests ?? 0) == 0
    }

    init(inputs: TranscriptRowInputs) {
        self.inputs = inputs
        super.init(frame: .zero)
        clipsToBounds = false
        bubble.cornerRadius = 14
        addSubview(bubble)
        addSubview(text)
        clock.font = Self.clockFont; clock.monospacedDigits = true
        // Hidden until the pointer arrives; a new row does not fade out.
        clock.alphaValue = 0
        addSubview(clock)
        hover = TranscriptHoverTracker(view: self) { [weak self] inside in self?.setHovering(inside) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        apply(inputs)
    }
    required init?(coder: NSCoder) { nil }
    deinit { MainActor.assumeIsolated { sendingTimer?.invalidate() } }

    func accepts(_ item: TranscriptItem) -> Bool { Self.draws(item) }
    /// Anything that says this content's size changed tells the row, as the
    /// SwiftUI host's intrinsic size did.
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        owner?.contentSizeChanged()
    }

    func apply(_ inputs: TranscriptRowInputs) {
        let before = self.inputs
        self.inputs = inputs
        TranscriptAppearance.apply(inputs.environment, to: self)
        let message = message
        bubble.fill = TranscriptNSPalette.userBackground
        text.update(text: message.text, face: .user, environment: inputs.environment,
                    swiftUILines: !TranscriptPlainText.usesTextKit(message.text))
        text.isHidden = message.text.isEmpty
        clock.color = TranscriptNSPalette.faint
        if message.isSending {
            clock.text = "Sending…"
            if !sendingShown, sendingTimer == nil {
                // A send the helper takes within a frame or two shows no mark.
                sendingTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.sendingTimer = nil; self.sendingShown = true; self.refreshBand()
                    }
                }
            }
        } else {
            sendingTimer?.invalidate(); sendingTimer = nil; sendingShown = false
            clock.text = message.at.map(TranscriptActivity.formatClock) ?? ""
        }
        setAccessibilityLabel("\(message.role) message")
        // A row its turn's fold has emptied draws nothing and says nothing.
        setAccessibilityElement(!inputs.disclosure.foldedAway)
        setAccessibilityCustomActions(TranscriptRowAction.all(message, inputs.actions, forks: inputs.environment.forks)
            .map { action in NSAccessibilityCustomAction(name: action.name) { action.perform(); return true } })
        if before.width != inputs.width || before.item != inputs.item || before.disclosure.foldedAway != inputs.disclosure.foldedAway {
            needsLayout = true
        }
        refreshBand()
    }

    private func setHovering(_ inside: Bool) {
        hovering = inside
        refreshBand()
    }
    /// The band's figures and pills for where the pointer is.
    private func refreshBand() {
        let message = message
        TranscriptMotion.fade(clock, to: message.isSending ? (sendingShown ? 1 : 0) : (hovering ? 1 : 0))
        if message.isSending { clock.speak("Sending", identifier: "messageSending") }
        else { clock.speak(clock.text.isEmpty ? nil : "Sent at \(clock.text)") }
        let wanted = hovering && !message.isSending
            ? RowActionsView.pills(message, actions: inputs.actions, forks: inputs.environment.forks, source: nil) : []
        if pills.map(\.title) != wanted.map(\.title) {
            // Leaving pills fade out as they used to, then go.
            for old in pills { TranscriptMotion.leave(old) }
            pills = wanted.map { pill in
                let button = TranscriptPillButton(title: pill.title, accent: pill.accent, perform: pill.perform)
                button.enabled = inputs.environment.isEnabled
                addSubview(button)
                return button
            }
            needsLayout = true
            layoutSubtreeIfNeeded()
            pills.forEach(TranscriptMotion.arrive)
        } else {
            for (button, pill) in zip(pills, wanted) { button.perform = pill.perform; button.enabled = inputs.environment.isEnabled }
        }
    }

    // MARK: Geometry

    /// Where everything goes at `width`, and the height that needs.
    private struct Plan {
        var bubble: CGRect
        var text: CGRect
        var band: CGRect
        var height: CGFloat
    }
    private func plan(width: CGFloat) -> Plan {
        if inputs.disclosure.foldedAway {
            return Plan(bubble: .zero, text: .zero, band: .zero, height: 0)
        }
        let bubbleWidth = max(0, min(TranscriptMetrics.proseWidth, width - Self.leadingRoom))
        let textWidth = max(1, bubbleWidth - 2 * Self.padding.width)
        let textHeight = message.text.isEmpty ? 0 : text.exactHeight(width: textWidth)
        let bubbleHeight = textHeight + 2 * Self.padding.height
        let content = Self.top + bubbleHeight + Self.gap + Self.bandHeight + Self.bottom
        // The row is a whole number of points tall, and its content sits in
        // the middle of it, as SwiftUI placed it.
        let height = ceil(content), y = (height - content) / 2
        let bubble = CGRect(x: width - bubbleWidth, y: y + Self.top, width: bubbleWidth, height: bubbleHeight)
        let textFrame = CGRect(x: bubble.minX + Self.padding.width, y: bubble.minY + Self.padding.height, width: textWidth, height: ceil(textHeight))
        let band = CGRect(x: 0, y: bubble.maxY + Self.gap, width: width, height: Self.bandHeight)
        return Plan(bubble: bubble, text: textFrame, band: band, height: height)
    }
    func settle() -> (height: CGFloat, passes: Int) {
        let plan = plan(width: bounds.width > 0 ? bounds.width : inputs.width)
        layoutSubtreeIfNeeded()
        return (max(1, ceil(plan.height)), 1)
    }
    func confirmHeight() -> CGFloat { max(1, ceil(plan(width: bounds.width > 0 ? bounds.width : inputs.width).height)) }

    override func layout() {
        super.layout()
        let planned = plan(width: bounds.width)
        let hidden = inputs.disclosure.foldedAway
        bubble.isHidden = hidden; text.isHidden = hidden || message.text.isEmpty; clock.isHidden = hidden
        // Frames on the pixel grid, as SwiftUI places views.
        let rtl = inputs.environment.layoutDirection == .rightToLeft
        let plan = Plan(bubble: TranscriptMotion.mirrored(planned.bubble, width: bounds.width, rtl),
                        text: TranscriptMotion.mirrored(planned.text, width: bounds.width, rtl),
                        band: planned.band, height: planned.height)
        bubble.frame = pixelAligned(plan.bubble)
        // The text keeps its exact place: SwiftUI does not round a text's origin.
        text.frame = plan.text
        // The band reads from its trailing edge: the time, then the pills.
        var x = plan.band.maxX
        var placed: [CGRect] = []
        for button in pills.reversed() {
            let size = button.pillSize
            x -= size.width
            placed.append(CGRect(x: x, y: plan.band.midY - size.height / 2, width: size.width, height: size.height))
            x -= 4
        }
        for (button, frame) in zip(pills.reversed(), placed) { button.frame = TranscriptMotion.mirrored(frame, width: bounds.width, rtl) }
        if !pills.isEmpty { x += 4 }
        x -= 10
        let size = clock.intrinsicSize
        clock.frame = TranscriptMotion.mirrored(CGRect(x: x - size.width, y: plan.band.midY - size.height / 2, width: size.width, height: size.height),
                                                width: bounds.width, rtl)
    }
    private func pixelAligned(_ rect: CGRect) -> CGRect {
        let scale = window?.backingScaleFactor ?? 2
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        // The origin to the nearest pixel, the size up to a whole pixel.
        let minY = snap(rect.minY), minX = snap(rect.minX)
        return CGRect(x: minX, y: minY, width: snap(rect.maxX) - minX, height: ceil(rect.height * scale) / scale)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // The pointer counts over the message and its band, not the padding.
        hover.update(rect: CGRect(x: 0, y: Self.top, width: bounds.width, height: max(0, bounds.height - Self.top - Self.bottom)))
    }
    override func mouseEntered(with event: NSEvent) { hover.set(true) }
    override func mouseExited(with event: NSEvent) { hover.set(false) }
}
