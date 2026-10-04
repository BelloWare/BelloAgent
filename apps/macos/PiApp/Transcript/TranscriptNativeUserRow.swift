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
    /// How a send that failed ended, over the bubble.
    private var failedLabel: TranscriptLabel?
    static let failedFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    /// The skills the message used, leading its bubble.
    private var skills: TranscriptNativeSkillPills?
    /// Between the skills and the text.
    static let skillGap = TranscriptMessageRows.skillGap
    /// Under a saved fragment whose text was not kept whole.
    private var truncatedText: TranscriptPlainTextView?
    /// The edit's versions, in the band.
    private var switcher: TranscriptNativeVersionSwitcher?
    /// What the message's requests reported, at the band's trailing end.
    private var accounting: TranscriptNativeAccounting?
    private lazy var band = TranscriptPillBand(host: self)
    private var hover: TranscriptHoverTracker!
    private var hovering = false
    private var sendingShown = false
    private var sendingTimer: Timer?
    private var message: TranscriptMessage {
        if case .message(let message) = inputs.item { return message }
        return TranscriptMessage(id: "", role: "user", text: "")
    }
    override var isFlipped: Bool { true }

    /// Whether this row can draw `item`: a message the reader typed.
    static func draws(_ item: TranscriptItem) -> Bool {
        guard case .message(let message) = item else { return false }
        return message.role == "user" && message.kind == nil
    }

    init(inputs: TranscriptRowInputs) {
        self.inputs = inputs
        super.init(frame: .zero)
        clipsToBounds = false
        bubble.cornerRadius = 14
        text.snapsToPixels = false
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
                    swiftUILines: !TranscriptPlainTextView.usesTextKit(message.text))
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
        configureParts(message)
        setAccessibilityLabel("\(message.role) message")
        // A row its turn's fold has emptied draws nothing and says nothing.
        setAccessibilityElement(!inputs.disclosure.foldedAway)
        setAccessibilityCustomActions(TranscriptRowAction.all(message, inputs.actions, forks: inputs.environment.forks)
            .map { action in NSAccessibilityCustomAction(name: action.name) { [weak self] in
                // A row in a pane that takes no input acts on nothing, as its pills do.
                guard self?.inputs.environment.isEnabled == true else { return false }
                action.perform(); return true
            } })
        if before.width != inputs.width || before.item != inputs.item || before.disclosure.foldedAway != inputs.disclosure.foldedAway
            || before.environment != inputs.environment {
            needsLayout = true
        }
        refreshBand()
    }

    /// Builds the parts this message has and lets go of the ones it has not.
    private func configureParts(_ message: TranscriptMessage) {
        let environment = inputs.environment, actions = inputs.actions, id = message.id
        if let failed = message.failedEnd {
            let label = failedLabel ?? { let label = TranscriptLabel(); label.font = Self.failedFont; addSubview(label); failedLabel = label; return label }()
            label.text = failed; label.color = TranscriptNSPalette.danger
            label.speak(failed)
        } else if let failedLabel {
            failedLabel.removeFromSuperview(); self.failedLabel = nil
        }
        if let uses = message.skills, !uses.isEmpty {
            let pills = skills ?? { let pills = TranscriptNativeSkillPills(); addSubview(pills); skills = pills; return pills }()
            pills.update(messageID: id, skills: uses, actions: actions, environment: environment)
        } else if let skills {
            skills.removeFromSuperview(); self.skills = nil
        }
        if message.truncated == true {
            let text = truncatedText ?? { let text = TranscriptPlainTextView(); text.isSelectable = false; addSubview(text); truncatedText = text; return text }()
            text.update(text: TranscriptNativeReplyRow.truncatedNote, face: TranscriptNativeReplyRow.truncatedFace, environment: environment,
                        swiftUILines: true, color: TranscriptNSPalette.muted)
        } else if let truncatedText {
            truncatedText.removeFromSuperview(); self.truncatedText = nil
        }
        if let mark = message.versions, mark.usable, let step = actions.switchVersion {
            let view = switcher ?? { let view = TranscriptNativeVersionSwitcher(); addSubview(view); switcher = view; return view }()
            view.update(messageID: id, mark: mark, environment: environment) { step(id, $0) }
        } else if let switcher {
            switcher.removeFromSuperview(); self.switcher = nil
        }
        if let totals = message.accounting, totals.requests > 0 {
            let view = accounting ?? { let view = TranscriptNativeAccounting(); view.trailing = true; view.lineLimit = 1; addSubview(view); accounting = view; return view }()
            view.update(totals, environment: environment) { actions.inspect(id) }
        } else if let accounting {
            accounting.removeFromSuperview(); self.accounting = nil
        }
    }
    /// Whether the bubble shows the text: always, unless the message is only skills.
    private var showsText: Bool { (message.skills ?? []).isEmpty || !message.text.isEmpty }

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
            ? TranscriptRowPills.pills(message, actions: inputs.actions, forks: inputs.environment.forks, source: nil) : []
        band.show(wanted, enabled: inputs.environment.isEnabled)
    }

    // MARK: Geometry

    /// Where everything goes at `width`, and the height that needs.
    private struct Plan {
        var failed: CGRect = .zero
        var bubble: CGRect = .zero
        var skills: CGRect = .zero
        var text: CGRect = .zero
        var truncated: CGRect = .zero
        var band: CGRect = .zero
        var height: CGFloat = 0
    }
    private func plan(width: CGFloat) -> Plan {
        guard !inputs.disclosure.foldedAway else { return Plan() }
        var plan = Plan()
        let message = message
        let bubbleWidth = max(0, min(TranscriptMetrics.proseWidth, width - Self.leadingRoom))
        let textWidth = max(1, bubbleWidth - 2 * Self.padding.width)
        // The stack, top down: how a failed send ended, the bubble, the note
        // under an incomplete fragment, the band; six points between them.
        var y = Self.top
        if let failedLabel {
            let size = failedLabel.intrinsicSize
            plan.failed = CGRect(x: 0, y: y, width: size.width, height: size.height)
            y = plan.failed.maxY + Self.gap
        }
        let skillsHeight = skills?.height(width: textWidth) ?? 0
        let textHeight = showsText && !message.text.isEmpty ? text.exactHeight(width: textWidth) : 0
        var inner = skillsHeight
        if skills != nil, showsText { inner += Self.skillGap }
        if showsText { inner += textHeight }
        plan.bubble = CGRect(x: width - bubbleWidth, y: y, width: bubbleWidth, height: inner + 2 * Self.padding.height)
        plan.skills = CGRect(x: plan.bubble.minX + Self.padding.width, y: plan.bubble.minY + Self.padding.height, width: textWidth, height: skillsHeight)
        plan.text = CGRect(x: plan.skills.minX, y: plan.bubble.maxY - Self.padding.height - textHeight, width: textWidth, height: ceil(textHeight))
        y = plan.bubble.maxY + Self.gap
        if let truncatedText {
            let used = truncatedText.usedWidth(width: width), height = truncatedText.exactHeight(width: width)
            plan.truncated = CGRect(x: width - used, y: y, width: used, height: height)
            y = plan.truncated.maxY + Self.gap
        }
        plan.band = CGRect(x: 0, y: y, width: width, height: Self.bandHeight)
        let content = plan.band.maxY + Self.bottom
        // The row is a whole number of points tall, and its content sits in
        // the middle of it, as SwiftUI placed it.
        plan.height = ceil(content)
        let shift = (plan.height - content) / 2
        for keyPath in [\Plan.failed, \Plan.bubble, \Plan.skills, \Plan.text, \Plan.truncated, \Plan.band] {
            plan[keyPath: keyPath] = plan[keyPath: keyPath].offsetBy(dx: 0, dy: shift)
        }
        return plan
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
        let hidden = inputs.disclosure.foldedAway
        let message = message
        bubble.isHidden = hidden; text.isHidden = hidden || !showsText || message.text.isEmpty; clock.isHidden = hidden
        for view in [failedLabel, skills, truncatedText, switcher, accounting] as [NSView?] { view?.isHidden = hidden }
        guard !hidden else { return }
        // Frames on the pixel grid, as SwiftUI places views.
        let width = bounds.width
        let rtl = inputs.environment.layoutDirection == .rightToLeft
        func mirrored(_ rect: CGRect) -> CGRect { TranscriptMotion.mirrored(rect, width: width, rtl) }
        bubble.frame = pixelAligned(mirrored(plan.bubble))
        // The text keeps its exact place: SwiftUI does not round a text's origin.
        text.frame = mirrored(plan.text)
        skills?.frame = mirrored(plan.skills)
        if let failedLabel { failedLabel.frame = TranscriptMotion.mirrored(plan.failed, of: failedLabel, width: width, rtl) }
        truncatedText?.frame = mirrored(CGRect(x: plan.truncated.minX, y: plan.truncated.minY, width: plan.truncated.width, height: ceil(plan.truncated.height)))
        // The band, as its `HStack` lays it out ten points apart: the versions,
        // the time, the pills, and the accounting taking the rest from the
        // trailing edge. Without accounting the band ends at the trailing edge.
        var pieces: [(view: NSView?, width: CGFloat)] = []
        if let switcher { pieces.append((switcher, switcher.width)) }
        let clockShown = message.isSending || message.at != nil
        if clockShown { pieces.append((clock, clock.intrinsicSize.width)) }
        let pillsWidth = band.pills.reduce(0) { $0 + $1.pillSize.width } + 4 * CGFloat(max(0, band.pills.count - 1))
        pieces.append((nil, pillsWidth))
        let fixed = pieces.reduce(0) { $0 + $1.width } + 10 * CGFloat(pieces.count - 1)
        let flexible = accounting.map { !$0.isEmpty } ?? false
        var x = flexible ? 0 : width - fixed
        let midY = plan.band.midY
        for piece in pieces {
            if let view = piece.view as? TranscriptLabel {
                let size = view.intrinsicSize
                view.frame = TranscriptMotion.mirrored(CGRect(x: x, y: midY - size.height / 2, width: size.width, height: size.height), of: view, width: width, rtl)
            } else if let view = piece.view {
                view.frame = mirrored(CGRect(x: x, y: midY - TranscriptNativeVersionSwitcher.height / 2, width: piece.width, height: TranscriptNativeVersionSwitcher.height))
            } else {
                band.place(maxX: x + piece.width, midY: midY, width: width, rightToLeft: rtl)
            }
            x += piece.width + 10
        }
        if let accounting, flexible {
            let room = max(0, width - x), height = accounting.height(width: room)
            accounting.frame = mirrored(CGRect(x: x, y: midY - height / 2, width: room, height: height))
        }
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
