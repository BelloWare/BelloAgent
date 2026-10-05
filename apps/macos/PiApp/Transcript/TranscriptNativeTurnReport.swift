import AppKit

// A turn's report drawn by AppKit, as `CompactTurnReport` drew it: what the
// turn came to and what it cost on one line, its duration and its token
// shares under it, and a note when the figures are incomplete. The live dock
// over the composer, a finished turn's summary row and a legacy reply's turn
// line all draw this one view. Only the clock ticks, and only while the turn
// runs; nothing in it is laid out per streamed token.

/// The faces the report sets its words in.
@MainActor enum TranscriptTurnFaces {
    static let state = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let working = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let model = NSFont.systemFont(ofSize: 10.5)
    static let cost = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let reading = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let split = NSFont.systemFont(ofSize: 10)
    static let legend = NSFont.systemFont(ofSize: 9.5)
    static let note = NSFont.systemFont(ofSize: 9.5)
    /// A settled turn's note and its AI and tool times, when they wrap.
    static let noteFace = TranscriptPlainTextFace(size: 9.5, monospaced: false, lineSpacing: 0, label: "Note")
    static let splitFace = TranscriptPlainTextFace(size: 10, monospaced: false, lineSpacing: 0, label: "AI and tool time", monospacedDigits: true)
    /// The notice under a finished turn's report.
    static let noticeFace = TranscriptPlainTextFace(size: 12, monospaced: false, lineSpacing: 0, label: "Notice")
}

/// The report's colours that are not the transcript's own inks.
@MainActor enum TranscriptTurnColors {
    /// `Color.monitorModel(2)`: an output's reasoning share.
    static let reasoning = NSColor.piDynamic(light: NSColor(srgbRed: 0.48, green: 0.34, blue: 0.72, alpha: 1),
                                             dark: NSColor(srgbRed: 0.70, green: 0.61, blue: 0.96, alpha: 1))
}

/// A line of words with a slow highlight crossing it, as `PiShimmerText`
/// draws the working indicator. The highlight is a gradient masked by the
/// words and moved by the render server: a tick lays nothing out and draws
/// nothing on the main thread. Reduced motion leaves the words still.
@MainActor final class TranscriptShimmerLabel: NSView {
    let label = TranscriptLabel()
    private let band = CAGradientLayer()
    private let glow = CALayer()
    private let mask = CALayer()
    var reduceMotion = PiMotion.reducesMotion { didSet { if reduceMotion != oldValue { needsLayout = true } } }
    var text: String {
        get { label.text }
        set { guard newValue != label.text else { return }; label.text = newValue; setAccessibilityLabel(newValue); needsLayout = true }
    }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = TranscriptTurnFaces.working
        label.truncation = .tail
        addSubview(label)
        band.startPoint = CGPoint(x: 0, y: 0.5); band.endPoint = CGPoint(x: 1, y: 0.5)
        glow.addSublayer(band)
        glow.mask = mask
        layer?.addSublayer(glow)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("workingIndicator")
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var intrinsicSize: CGSize { label.intrinsicSize }
    /// Whether the highlight is moving, for tests.
    var sweeping: Bool { band.animation(forKey: "sweep") != nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }
    override func layout() {
        super.layout()
        label.frame = bounds
        label.color = TranscriptNSPalette.muted
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glow.frame = bounds; mask.frame = bounds
        glow.isHidden = reduceMotion || bounds.width <= 0
        let width = max(24, bounds.width * PiShimmerText.band)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            band.colors = [NSColor.clear.cgColor, TranscriptNSPalette.text.withAlphaComponent(0.9).cgColor, NSColor.clear.cgColor]
        }
        band.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        band.position = CGPoint(x: -width / 2, y: bounds.height / 2)
        // The words, as the highlight's mask.
        if !glow.isHidden, let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) {
            label.cacheDisplay(in: label.bounds, to: rep)
            mask.contents = rep.cgImage
            mask.contentsScale = window?.backingScaleFactor ?? 2
        }
        CATransaction.commit()
        sweep(width: width)
    }
    private func sweep(width: CGFloat) {
        let key = "sweep", to = bounds.width + width / 2
        guard !reduceMotion, window != nil, bounds.width > 0 else { band.removeAnimation(forKey: key); return }
        if let running = band.animation(forKey: key) as? CABasicAnimation, (running.toValue as? CGFloat) == to { return }
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = -width / 2; animation.toValue = to
        animation.duration = PiShimmerText.period; animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        // On the clock, as the SwiftUI line's timeline is.
        animation.beginTime = CACurrentMediaTime() - Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: PiShimmerText.period)
        band.add(animation, forKey: key)
    }
}

/// A symbol that acts when clicked, as a plain SwiftUI `Button` around an
/// `Image` in a fixed frame does: no face, dimmed while pressed, reachable
/// from the keyboard.
@MainActor final class TranscriptIconButton: NSView {
    let icon = TranscriptSymbol()
    var perform: () -> Void = {}
    var enabled = true
    private var pressed = false { didSet { icon.alphaValue = pressed ? 0.7 : 1 } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(icon)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); icon.place(in: bounds) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInActiveApp, .inVisibleRect, .cursorUpdate], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
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
        pressed = true
        if window?.firstResponder === self, let before = responderBeforeClick, before !== self { window?.makeFirstResponder(before) }
        responderBeforeClick = nil
    }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)), enabled { perform() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        guard enabled else { return false }
        perform(); return true
    }
    override func isAccessibilityEnabled() -> Bool { enabled }
    override var acceptsFirstResponder: Bool { enabled }
    override var canBecomeKeyView: Bool { enabled && NSApp.isFullKeyboardAccessEnabled }
    override func keyDown(with event: NSEvent) {
        guard enabled, [" ", "\r"].contains(event.charactersIgnoringModifiers ?? "") else { return super.keyDown(with: event) }
        perform()
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill() }
}

/// One of a turn's token shares, as `TurnTokenBar` drew it: the title and
/// the total, a four-point track split into its two shares, and a legend
/// line for each share. Read out as one element.
@MainActor final class TranscriptNativeTokenBar: NSView {
    private let title = TranscriptLabel()
    private let total = TranscriptLabel()
    private let track = Track()
    private let dots = [TranscriptPanel(), TranscriptPanel()]
    private let legends = [TranscriptLabel(), TranscriptLabel()]
    private(set) var partition: TurnTokenPartition?
    var rightToLeft = false { didSet { if rightToLeft != oldValue { needsLayout = true } } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = TranscriptTurnFaces.reading; total.font = TranscriptTurnFaces.reading
        for label in [title, total] { label.monospacedDigits = true; label.truncation = .tail }
        for label in legends { label.font = TranscriptTurnFaces.legend; label.monospacedDigits = true }
        for dot in dots { dot.cornerRadius = nil; dot.circular = true }
        for view in [title, total, track] as [NSView] { addSubview(view) }
        for view in dots as [NSView] + legends as [NSView] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }

    func update(_ partition: TurnTokenPartition) {
        guard partition != self.partition else { return }
        self.partition = partition
        title.text = partition.title; title.color = TranscriptNSPalette.faint
        total.text = partition.totalLabel; total.color = TranscriptNSPalette.text
        let primary = partition.title == "Input" ? NSColor.piSuccess : TranscriptTurnColors.reasoning
        track.primary = primary; track.fill = partition.fill
        for (index, label) in legends.enumerated() {
            label.text = partition.label(part: index == 0); label.color = TranscriptNSPalette.muted
            dots[index].fill = index == 0 ? primary : NSColor.piAccent
        }
        toolTip = partition.help
        setAccessibilityLabel(partition.help)
        needsLayout = true
    }
    static let trackHeight: CGFloat = 4
    private var headerHeight: CGFloat { TranscriptLabel.lineHeight(TranscriptTurnFaces.reading) }
    private var legendHeight: CGFloat { TranscriptLabel.lineHeight(TranscriptTurnFaces.legend) }
    /// As tall at every width: its lines never wrap.
    var height: CGFloat { headerHeight + 3 + Self.trackHeight + 3 + legendHeight + 2 + legendHeight }

    override func layout() {
        super.layout()
        let width = bounds.width
        func put(_ view: NSView, _ rect: CGRect) {
            view.frame = TranscriptMotion.mirrored(TranscriptMotion.pixelAligned(rect, scale: window?.backingScaleFactor ?? 2), of: view, width: width, rightToLeft)
        }
        // The title and the total share one line, each cut short rather than wrapped.
        let sizes = TranscriptLineLayout.sizes([piece(title), piece(total)], spacing: [5], width: width)
        put(title, CGRect(x: 0, y: (headerHeight - sizes[0].height) / 2, width: sizes[0].width, height: sizes[0].height))
        put(total, CGRect(x: sizes[0].width + 5, y: (headerHeight - sizes[1].height) / 2, width: sizes[1].width, height: sizes[1].height))
        put(track, CGRect(x: 0, y: headerHeight + 3, width: width, height: Self.trackHeight))
        var y = headerHeight + 3 + Self.trackHeight + 3
        for (dot, label) in zip(dots, legends) {
            let size = label.intrinsicSize
            put(dot, CGRect(x: 0, y: y + (legendHeight - 4) / 2, width: 4, height: 4))
            put(label, CGRect(x: 7, y: y + (legendHeight - size.height) / 2, width: size.width, height: size.height))
            y += legendHeight + 2
        }
        // SwiftUI's Canvas draws its shares from the left in either direction.
    }
    private func piece(_ label: TranscriptLabel) -> TranscriptLinePiece {
        let ideal = label.intrinsicSize
        return TranscriptLinePiece(minWidth: 0, maxWidth: ideal.width, size: { offered in
            CGSize(width: label.width(truncatedTo: min(ideal.width, max(0, offered))), height: ideal.height)
        })
    }

    /// The track: the fill colour, then the reported share or the two shares.
    final class Track: NSView {
        var fill = TurnTokenPartition.Fill.empty { didSet { if fill != oldValue { needsDisplay = true } } }
        var primary: NSColor = .piSuccess { didSet { needsDisplay = true } }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(false) }
        required init?(coder: NSCoder) { nil }
        override func draw(_ dirtyRect: NSRect) {
            let shape = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
            NSColor.piFillStrong.setFill(); shape.fill()
            let secondary = NSColor.piAccent.withAlphaComponent(0.75)
            switch fill {
            case .empty: break
            case .reported:
                secondary.setFill(); shape.fill()
            case .split(let fraction):
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                secondary.setFill(); bounds.fill()
                let width = bounds.width * fraction
                primary.setFill()
                CGRect(x: 0, y: 0, width: width, height: bounds.height).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}

/// How long the turn ran, and its AI and tool time, as `TurnDurationMetrics`
/// drew them. Its clock ticks every half second while the turn runs and
/// never once it has settled; a tick changes words in lines that never wrap.
@MainActor final class TranscriptNativeDurationMetrics: NSView {
    private let title = TranscriptLabel()
    private let clockLabel = TranscriptLabel()
    private let split = TranscriptLabel()
    /// A settled turn's AI and tool time over several lines, when its slot is too narrow.
    private var wrapped: TranscriptPlainTextView?
    private(set) var clock: TurnDurationClock?
    private var input: TurnDurationInput?
    private var environment = TranscriptRowEnvironment()
    var rightToLeft: Bool { environment.layoutDirection == .rightToLeft }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = TranscriptTurnFaces.reading; clockLabel.font = TranscriptTurnFaces.reading
        split.font = TranscriptTurnFaces.split
        for label in [title, clockLabel, split] { label.monospacedDigits = true; addSubview(label) }
        title.text = "Duration"
        title.speak("Duration")
        clockLabel.speak(nil, identifier: "elapsedClock")
        split.toolTip = "Recorded AI and tool time, rounded. The Session Inspector has each request's exact time."
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    deinit { MainActor.assumeIsolated { clock?.stop() } }

    func update(_ turn: TurnSummary, environment: TranscriptRowEnvironment) {
        let next = TurnDurationInput(turn)
        self.environment = environment
        if let clock {
            // A new task starts a clock of its own, as a new SwiftUI view's did.
            if let input, !next.isSameTask(as: input), !(input.terminal && next.live) {
                clock.stop(); self.clock = nil
            } else { clock.update(next) }
        }
        input = next
        let clock = self.clock ?? {
            let made = TurnDurationClock(input: next)
            made.changed = { [weak self] _ in self?.show() }
            self.clock = made
            return made
        }()
        show()
        if clock.live, window != nil { clock.start() } else { clock.stop() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Ticks only while on screen.
        if window == nil { clock?.stop() } else if clock?.live == true { clock?.start() }
    }
    private var live: Bool { input?.live ?? false }
    private func show() {
        guard let reading = clock?.reading else { return }
        let live = self.live
        let elapsed = reading.elapsedMs.map { TurnDurationText.label($0, live: live) } ?? "—"
        let text = "AI \(TurnDurationText.label(reading.modelMs, live: live)) · Tools \(TurnDurationText.label(reading.toolMs, live: live))"
        let changedLines = split.text != text && !live
        title.color = TranscriptNSPalette.faint
        clockLabel.text = elapsed; clockLabel.color = TranscriptNSPalette.text
        clockLabel.speak(elapsed, identifier: "elapsedClock")
        split.text = text; split.color = TranscriptNSPalette.muted
        split.speak(text)
        for label in [title, clockLabel, split] { label.truncation = live ? .tail : nil }
        wrapped?.update(text: text, face: TranscriptTurnFaces.splitFace, environment: environment, swiftUILines: true, color: TranscriptNSPalette.muted)
        wrapped?.setAccessibilityLabel(text)
        if changedLines { superview?.needsLayout = true }
        needsLayout = true
    }
    private var wrappedSplit: TranscriptPlainTextView {
        if let wrapped { return wrapped }
        // Read out in the line's place while it stands in for it.
        let text = TranscriptPlainTextView(); text.isSelectable = false
        text.setAccessibilityRole(.staticText)
        text.toolTip = split.toolTip
        text.update(text: split.text, face: TranscriptTurnFaces.splitFace, environment: environment, swiftUILines: true, color: TranscriptNSPalette.muted)
        text.setAccessibilityLabel(split.text)
        addSubview(text); wrapped = text
        return text
    }
    private var lineHeight: CGFloat { TranscriptLabel.lineHeight(TranscriptTurnFaces.reading) }
    /// Whether the AI and tool time wraps at `width`: settled only.
    private func wraps(_ width: CGFloat) -> Bool { !live && width + 0.25 < split.intrinsicSize.width }
    func height(width: CGFloat) -> CGFloat {
        lineHeight + 4 + (wraps(width) ? wrappedSplit.exactHeight(width: width) : split.intrinsicSize.height)
    }
    override func layout() {
        super.layout()
        let width = bounds.width, scale = window?.backingScaleFactor ?? 2
        func put(_ view: NSView, _ rect: CGRect) {
            view.frame = TranscriptMotion.mirrored(TranscriptMotion.pixelAligned(rect, scale: scale), of: view, width: width, rightToLeft)
        }
        let first = TranscriptLineLayout.sizes([piece(title), piece(clockLabel)], spacing: [5], width: width)
        put(title, CGRect(x: 0, y: (lineHeight - first[0].height) / 2, width: first[0].width, height: first[0].height))
        put(clockLabel, CGRect(x: first[0].width + 5, y: (lineHeight - first[1].height) / 2, width: first[1].width, height: first[1].height))
        let top = lineHeight + 4
        if wraps(width) {
            split.isHidden = true
            let text = wrappedSplit
            text.isHidden = false
            let height = text.exactHeight(width: width)
            put(text, CGRect(x: 0, y: top, width: text.usedWidth(width: width), height: ceil(height)))
        } else {
            split.isHidden = false; wrapped?.isHidden = true
            let size = split.intrinsicSize
            put(split, CGRect(x: 0, y: top, width: min(size.width, width), height: size.height))
        }
    }
    private func piece(_ label: TranscriptLabel) -> TranscriptLinePiece {
        let ideal = label.intrinsicSize
        return TranscriptLinePiece(minWidth: 0, maxWidth: ideal.width, size: { offered in
            CGSize(width: label.width(truncatedTo: min(ideal.width, max(0, offered))), height: ideal.height)
        })
    }
}

/// The report itself: `CompactTurnReport`, drawn by AppKit.
@MainActor final class TranscriptNativeTurnReport: NSView {
    /// What the report shows, compared whole so an unchanged turn costs nothing.
    struct Content: Equatable {
        var turn: TurnSummary
        var model: String?
        var status: String?
        var showsInfo: Bool
    }
    private(set) var content: Content?
    private var actions = TranscriptActions()
    private(set) var environment = TranscriptRowEnvironment()
    private let panel = TranscriptPanel()
    private let stateIcon = TranscriptSymbol()
    private let stateLabel = TranscriptLabel()
    private var shimmer: TranscriptShimmerLabel?
    private let modelLabel = TranscriptLabel()
    private let costLabel = TranscriptLabel()
    private let info = TurnInfoNSButton()
    private let copyButton = TranscriptIconButton()
    let duration = TranscriptNativeDurationMetrics()
    let input = TranscriptNativeTokenBar()
    let output = TranscriptNativeTokenBar()
    /// The live note on one line; a settled one over up to four.
    private let noteLabel = TranscriptLabel()
    private var noteText: TranscriptPlainTextView?
    /// Whether the working line's highlight stands still.
    var reduceMotion = PiMotion.reducesMotion { didSet { shimmer?.reduceMotion = reduceMotion } }
    /// Told when the report's height may have changed without new content.
    var heightChanged: () -> Void = {}
    override var isFlipped: Bool { true }

    static let padding = CGSize(width: 10, height: 7)
    static let spacing: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        panel.cornerRadius = 8
        stateLabel.font = TranscriptTurnFaces.state; stateLabel.truncation = .tail
        modelLabel.font = TranscriptTurnFaces.model; modelLabel.truncation = .middle
        modelLabel.speak(nil, identifier: "turn-report-model")
        costLabel.font = TranscriptTurnFaces.cost; costLabel.monospacedDigits = true
        copyButton.icon.show("doc.on.doc", size: 11, weight: .regular)
        copyButton.toolTip = "Copy Turn Info"; copyButton.setAccessibilityLabel("Copy Turn Info")
        copyButton.perform = { [weak self] in self?.copyTurnInfo() }
        noteLabel.font = TranscriptTurnFaces.note; noteLabel.truncation = .tail
        noteLabel.speak(nil, identifier: "turn-coverage-notice")
        for view in [panel, stateIcon, stateLabel, modelLabel, costLabel, info, copyButton, duration, input, output, noteLabel] as [NSView] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityIdentifier("compact-turn-report")
    }
    required init?(coder: NSCoder) { nil }

    private var rightToLeft: Bool { environment.layoutDirection == .rightToLeft }
    private var running: Bool { content?.turn.isRunning ?? false }

    func update(turn: TurnSummary, actions: TranscriptActions, model: String? = nil, status: String? = nil, showsInfo: Bool = true,
                environment: TranscriptRowEnvironment) {
        self.actions = actions
        let next = Content(turn: turn, model: model, status: status, showsInfo: showsInfo)
        info.turn = turn; info.actions = actions; info.isEnabled = environment.isEnabled
        copyButton.enabled = environment.isEnabled
        guard next != content || environment != self.environment else { return }
        content = next; self.environment = environment
        TranscriptAppearance.apply(environment, to: self)
        panel.fill = TranscriptNSPalette.surface.withAlphaComponent(0.55); panel.stroke = TranscriptNSPalette.hair
        if turn.isRunning {
            let shimmer = self.shimmer ?? {
                let made = TranscriptShimmerLabel()
                addSubview(made); self.shimmer = made
                return made
            }()
            shimmer.reduceMotion = reduceMotion
            shimmer.text = status ?? "Working…"
            shimmer.isHidden = false
            stateIcon.isHidden = true; stateLabel.isHidden = true
        } else {
            shimmer?.removeFromSuperview(); shimmer = nil
            let completed = turn.outcome == "completed"
            stateIcon.show(completed ? "checkmark.circle" : "exclamationmark.circle", size: 11, weight: .medium)
            stateIcon.contentTintColor = completed ? .piSuccess : .piWarning
            stateLabel.text = "Turn · " + TurnInfoPresentation.outcome(turn); stateLabel.color = TranscriptNSPalette.muted
            stateLabel.speak(stateLabel.text)
            stateIcon.isHidden = false; stateLabel.isHidden = false
        }
        let models = turn.accounting.answeredModels.isEmpty ? model.map { [$0] } ?? [] : turn.accounting.answeredModels
        modelLabel.text = TurnInfoPresentation.modelLabel(turn, fallback: model); modelLabel.color = TranscriptNSPalette.muted
        modelLabel.toolTip = turn.accounting.modelRoutes.isEmpty ? models.joined(separator: "\n") : turn.accounting.modelRoutes.map(\.detail).joined(separator: "\n")
        modelLabel.setAccessibilityLabel(modelLabel.text); modelLabel.setAccessibilityElement(true)
        costLabel.text = TurnInfoPresentation.costLabel(turn); costLabel.color = TranscriptNSPalette.text
        costLabel.toolTip = "Gateway-reported cost" + (turn.isRunning ? " so far" : "")
        costLabel.speak(costLabel.text)
        info.isHidden = !showsInfo; copyButton.isHidden = !showsInfo
        copyButton.icon.contentTintColor = TranscriptNSPalette.faint
        duration.update(turn, environment: environment)
        input.update(TurnTokenPartition(turn.accounting, input: true, running: turn.isRunning))
        output.update(TurnTokenPartition(turn.accounting, input: false, running: turn.isRunning))
        for bar in [input, output] { bar.rightToLeft = rightToLeft }
        if let note = TurnInfoPresentation.cardNote(turn) {
            noteLabel.text = note; noteLabel.color = TranscriptNSPalette.faint; noteLabel.toolTip = note
            noteLabel.speak(note, identifier: "turn-coverage-notice")
            noteText?.update(text: note, face: TranscriptTurnFaces.noteFace, environment: environment, swiftUILines: true, color: TranscriptNSPalette.faint)
            noteText?.toolTip = note; noteText?.setAccessibilityLabel(note)
        }
        needsLayout = true
    }

    // MARK: Copy Turn Info

    func copyTurnInfo() {
        guard let content else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TurnPillsPresentation.copyText(TurnInfoPresentation.live(content.turn, at: .now), model: content.model), forType: .string)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Copy Turn Info", action: #selector(copyFromMenu(_:)), keyEquivalent: "")
        item.target = self
        // A pane that takes no input offers the command and refuses it.
        menu.autoenablesItems = false
        item.isEnabled = environment.isEnabled
        menu.addItem(item)
        return menu
    }
    @objc private func copyFromMenu(_ sender: Any?) { if environment.isEnabled { copyTurnInfo() } }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: "Copy Turn Info") { [weak self] in
            guard let self, self.environment.isEnabled else { return false }
            self.copyTurnInfo(); return true
        }]
    }

    // MARK: Measuring

    /// The note's lines when the turn has settled: up to four, wrapped.
    private var wrappedNote: TranscriptPlainTextView {
        if let noteText { return noteText }
        // Read out, and its whole note shown under the pointer, as the line's is.
        let text = TranscriptPlainTextView(); text.isSelectable = false
        text.setAccessibilityRole(.staticText); text.setAccessibilityIdentifier("turn-coverage-notice")
        text.toolTip = noteLabel.text
        text.maximumLines = 4
        text.update(text: noteLabel.text, face: TranscriptTurnFaces.noteFace, environment: environment, swiftUILines: true, color: TranscriptNSPalette.faint)
        text.setAccessibilityLabel(noteLabel.text)
        addSubview(text); noteText = text
        return text
    }
    private var hasNote: Bool { content.map { TurnInfoPresentation.cardNote($0.turn) != nil } ?? false }
    private func noteHeight(width: CGFloat) -> CGFloat {
        guard hasNote else { return 0 }
        return running ? noteLabel.intrinsicSize.height : wrappedNote.exactHeight(width: width)
    }

    /// The state's pieces: the working line, or the outcome's symbol and words.
    private var stateIdeal: CGSize {
        if let shimmer { return shimmer.intrinsicSize }
        let symbol = stateSymbolFrame, text = stateLabel.intrinsicSize
        return CGSize(width: symbol.width + 6 + text.width, height: max(symbol.height, text.height))
    }
    private var stateSymbolFrame: CGSize {
        stateIcon.swiftUIFrame ?? stateIcon.image.map { CGSize(width: $0.alignmentRect.width, height: $0.size.height) } ?? .zero
    }
    private func stateSize(offered width: CGFloat) -> CGSize {
        let ideal = stateIdeal
        guard width < ideal.width else { return ideal }
        if let shimmer { return CGSize(width: shimmer.label.width(truncatedTo: max(0, width)), height: ideal.height) }
        let symbol = stateSymbolFrame
        let text = stateLabel.width(truncatedTo: max(0, width - symbol.width - 6))
        return CGSize(width: symbol.width + 6 + text, height: ideal.height)
    }
    private var showsInfo: Bool { content?.showsInfo ?? false }
    /// The identity's fixed pieces after the model, with their spacing.
    private var identityFixed: CGFloat { 7 + costLabel.intrinsicSize.width + (showsInfo ? 7 + TurnInfoNSButton.size.width + 7 + 18 : 0) }
    private var identityHeight: CGFloat { showsInfo ? 20 : max(modelLabel.intrinsicSize.height, costLabel.intrinsicSize.height) }
    private var identityIdeal: CGFloat { modelLabel.intrinsicSize.width + identityFixed }
    private func identityWidth(offered width: CGFloat) -> CGFloat {
        guard width < identityIdeal else { return identityIdeal }
        return modelLabel.width(truncatedTo: max(0, width - identityFixed)) + identityFixed
    }
    static let oneLineWidth: CGFloat = 420, stateMinimum: CGFloat = 130

    private struct Header { var state: CGRect; var identity: CGRect; var height: CGFloat }
    private func header(width: CGFloat) -> Header {
        if width >= Self.oneLineWidth {
            let identity = identityWidth(offered: min(identityIdeal, width - Self.stateMinimum - 8))
            let state = stateSize(offered: max(0, width - identity - 8))
            let height = max(state.height, identityHeight)
            return Header(state: CGRect(x: 0, y: (height - state.height) / 2, width: state.width, height: state.height),
                          identity: CGRect(x: width - identity, y: (height - identityHeight) / 2, width: identity, height: identityHeight),
                          height: height)
        }
        let state = stateSize(offered: width), identity = identityWidth(offered: width)
        return Header(state: CGRect(origin: .zero, size: state),
                      identity: CGRect(x: 0, y: state.height + 3, width: identity, height: identityHeight),
                      height: state.height + 3 + identityHeight)
    }

    static let durationColumn: CGFloat = 150, tokenColumn: CGFloat = 185
    private func metrics(width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let spacing: CGFloat = 14, rowSpacing: CGFloat = 6
        let bar = input.height
        if width >= Self.durationColumn + 2 * Self.tokenColumn + 2 * spacing {
            let durationWidth = (width - 2 * spacing) * Self.durationColumn / (Self.durationColumn + 2 * Self.tokenColumn)
            let tokenWidth = (width - 2 * spacing - durationWidth) / 2
            let heights = [duration.height(width: durationWidth), bar, bar]
            return ([CGRect(x: 0, y: 0, width: durationWidth, height: heights[0]),
                     CGRect(x: durationWidth + spacing, y: 0, width: tokenWidth, height: bar),
                     CGRect(x: durationWidth + tokenWidth + 2 * spacing, y: 0, width: tokenWidth, height: bar)], heights.max() ?? 0)
        }
        let durationHeight = duration.height(width: width)
        if width >= 2 * Self.tokenColumn + spacing {
            let tokenWidth = (width - spacing) / 2, top = durationHeight + rowSpacing
            return ([CGRect(x: 0, y: 0, width: width, height: durationHeight),
                     CGRect(x: 0, y: top, width: tokenWidth, height: bar),
                     CGRect(x: tokenWidth + spacing, y: top, width: tokenWidth, height: bar)], top + bar)
        }
        return ([CGRect(x: 0, y: 0, width: width, height: durationHeight),
                 CGRect(x: 0, y: durationHeight + rowSpacing, width: width, height: bar),
                 CGRect(x: 0, y: durationHeight + bar + 2 * rowSpacing, width: width, height: bar)],
                durationHeight + 2 * bar + 2 * rowSpacing)
    }

    /// The report's height at `width`, unrounded, as SwiftUI sizes it.
    func height(width: CGFloat) -> CGFloat {
        let inner = max(0, width - 2 * Self.padding.width)
        var height = Self.padding.height * 2 + header(width: inner).height + Self.spacing + metrics(width: inner).height
        if hasNote { height += Self.spacing + noteHeight(width: inner) }
        return height
    }

    override func layout() {
        super.layout()
        guard content != nil else { return }
        let width = bounds.width, scale = window?.backingScaleFactor ?? 2
        let inner = max(0, width - 2 * Self.padding.width)
        let origin = CGPoint(x: Self.padding.width, y: Self.padding.height)
        func put(_ view: NSView, _ rect: CGRect) {
            let placed = TranscriptMotion.pixelAligned(rect.offsetBy(dx: origin.x, dy: origin.y), scale: scale)
            view.frame = TranscriptMotion.mirrored(placed, of: view, width: width, rightToLeft)
        }
        panel.frame = bounds
        let head = header(width: inner)
        // The state: the working line, or the symbol and the outcome.
        if let shimmer {
            put(shimmer, head.state)
        } else {
            let symbol = stateSymbolFrame
            let rect = CGRect(x: head.state.minX, y: head.state.minY + (head.state.height - symbol.height) / 2, width: symbol.width, height: symbol.height)
            let placed = TranscriptMotion.mirrored(rect.offsetBy(dx: origin.x, dy: origin.y), width: width, rightToLeft)
            stateIcon.place(in: placed)
            let text = stateLabel.intrinsicSize
            let textWidth = max(0, head.state.width - symbol.width - 6)
            put(stateLabel, CGRect(x: head.state.minX + symbol.width + 6, y: head.state.minY + (head.state.height - text.height) / 2,
                                   width: textWidth, height: text.height))
        }
        // The identity: the model, the cost, Info and Copy, centred on its line.
        let identity = head.identity
        let modelWidth = max(0, identity.width - identityFixed)
        var x = identity.minX
        let model = modelLabel.intrinsicSize
        put(modelLabel, CGRect(x: x, y: identity.minY + (identity.height - model.height) / 2, width: modelWidth, height: model.height))
        x += modelWidth + 7
        let cost = costLabel.intrinsicSize
        put(costLabel, CGRect(x: x, y: identity.minY + (identity.height - cost.height) / 2, width: cost.width, height: cost.height))
        x += cost.width + 7
        if showsInfo {
            put(info, CGRect(x: x, y: identity.minY + (identity.height - 20) / 2, width: 20, height: 20))
            x += 20 + 7
            put(copyButton, CGRect(x: x, y: identity.minY + (identity.height - 18) / 2, width: 18, height: 18))
        }
        // The readings.
        let top = head.height + Self.spacing
        let readings = metrics(width: inner)
        for (view, frame) in zip([duration, input, output] as [NSView], readings.frames) { put(view, frame.offsetBy(dx: 0, dy: top)) }
        // The note.
        let noteTop = top + readings.height + Self.spacing
        if hasNote, running {
            noteText?.isHidden = true; noteLabel.isHidden = false
            let size = noteLabel.intrinsicSize
            put(noteLabel, CGRect(x: 0, y: noteTop, width: min(size.width, noteLabel.width(truncatedTo: inner)), height: size.height))
        } else if hasNote {
            noteLabel.isHidden = true
            let text = wrappedNote
            text.isHidden = false
            put(text, CGRect(x: 0, y: noteTop, width: text.usedWidth(width: inner), height: ceil(text.exactHeight(width: inner))))
        } else {
            noteLabel.isHidden = true; noteText?.isHidden = true
        }
    }
}

/// How a legacy reply's turn ends, as `TurnLineView` drew it: the report
/// under a hairline, eight points below what comes before. A turn that has
/// just settled glows for a moment; hovering says when it started and finished.
@MainActor final class TranscriptNativeTurnLine: NSView {
    let report = TranscriptNativeTurnReport()
    private let hair = TranscriptPanel()
    private let glow = TranscriptPanel()
    private var environment = TranscriptRowEnvironment()
    override var isFlipped: Bool { true }
    static let gap: CGFloat = 8, inset: CGFloat = 6
    override init(frame: NSRect) {
        super.init(frame: frame)
        for panel in [hair, glow] { panel.cornerRadius = 0 }
        addSubview(glow); addSubview(hair); addSubview(report)
        report.setAccessibilityIdentifier("turn-pills")
        setAccessibilityElement(true); setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { nil }
    func update(turn: TurnSummary, settled: Bool, actions: TranscriptActions, model: String?, environment: TranscriptRowEnvironment) {
        self.environment = environment
        TranscriptAppearance.apply(environment, to: self)
        report.update(turn: turn, actions: actions, model: model, showsInfo: true, environment: environment)
        hair.fill = settled ? TranscriptNSPalette.accent.withAlphaComponent(0.55) : TranscriptNSPalette.hair
        glow.fill = settled ? TranscriptNSPalette.accent.withAlphaComponent(0.07) : nil
        let stamps = [turn.startedAt.map { "Started " + TranscriptActivity.formatClock($0) },
                      turn.isRunning ? nil : turn.endedAt.map { "finished " + TranscriptActivity.formatClock($0) }].compactMap { $0 }.joined(separator: " · ")
        toolTip = stamps.isEmpty ? nil : stamps
        setAccessibilityLabel("Turn: \(TurnPillsPresentation.counts(turn))")
        needsLayout = true
    }
    func height(width: CGFloat) -> CGFloat { Self.gap + Self.inset + report.height(width: width) }
    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        let body = CGRect(x: 0, y: Self.gap, width: bounds.width, height: Self.inset + report.height(width: bounds.width))
        glow.frame = TranscriptMotion.pixelAligned(body, scale: scale)
        hair.frame = TranscriptMotion.pixelAligned(CGRect(x: 0, y: Self.gap, width: bounds.width, height: 1), scale: scale)
        report.frame = TranscriptMotion.pixelAligned(CGRect(x: 0, y: Self.gap + Self.inset, width: bounds.width, height: report.height(width: bounds.width)), scale: scale)
    }
}

/// A finished turn's own row (`.summary`), as `StableTurnSummaryView` drew
/// it: the report, and under it the turn's notice when the page has no
/// failure card to carry it.
@MainActor final class TranscriptNativeTurnSummaryRow: TranscriptNativeMessageRow {
    override class var rowTop: CGFloat { 6 }
    override class var rowBottom: CGFloat { 10 }
    let report = TranscriptNativeTurnReport()
    private var noticeText: TranscriptPlainTextView?
    static func turn(of item: TranscriptItem) -> TurnSummary? {
        guard case .block(let block) = item, block.presentation == .summary, let turn = block.turn else { return nil }
        return turn
    }
    override class func draws(_ item: TranscriptItem) -> Bool { turn(of: item) != nil }
    override var drawsNothing: Bool { inputs.disclosure.foldedAway || inputs.disclosure.responseLine }
    private var turn: TurnSummary? { Self.turn(of: inputs.item) }
    private var notice: String? { turn.flatMap(TurnInfoPresentation.noticeBelowCard) }

    override init(inputs: TranscriptRowInputs) {
        super.init(inputs: inputs)
        report.setAccessibilityIdentifier("turn-pills")
        addSubview(report)
        apply(inputs)
    }
    required init?(coder: NSCoder) { nil }

    override func configure() {
        guard let turn else { return }
        report.update(turn: turn, actions: inputs.actions, showsInfo: true, environment: inputs.environment)
        if let notice {
            let text = noticeText ?? {
                let text = TranscriptPlainTextView()
                addSubview(text); noticeText = text
                return text
            }()
            text.update(text: notice, face: TranscriptTurnFaces.noticeFace, environment: inputs.environment, swiftUILines: true, color: TranscriptNSPalette.warning)
        } else if let noticeText {
            noticeText.removeFromSuperview(); self.noticeText = nil
        }
        setAccessibilityLabel(nil)
    }
    override func contentHeight(width: CGFloat) -> CGFloat {
        var height = report.height(width: width)
        if let noticeText { height += 4 + noticeText.exactHeight(width: width) }
        return height
    }
    override func place(in rect: CGRect) {
        let reportHeight = report.height(width: rect.width)
        report.frame = pixelAligned(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: reportHeight))
        if let noticeText {
            let height = noticeText.exactHeight(width: rect.width)
            noticeText.frame = CGRect(x: rect.minX, y: rect.minY + reportHeight + 4, width: noticeText.usedWidth(width: rect.width), height: ceil(height))
        }
    }
}
