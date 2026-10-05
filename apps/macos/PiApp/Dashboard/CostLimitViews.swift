import AppKit

// The cost limit on screen: a chat's spend against its limit, the editor for
// the chat's own limit (in its usage popover, Session info and the stop
// notice's Raise limit… popover), and the Settings default.

enum CostLimitText {
    /// What a limit does, under every editor.
    static let explanation = "A chat stops before its next model request once the spend the gateway reported for it reaches the limit; a request already running always finishes. Title and name suggestions run as separate small tasks and don't count toward a chat's spend."
    /// A preset's chip: "$5.00", "$25.00".
    static func preset(_ amount: Double) -> String { CostLimit.dollars(amount) }
}

/// "$4.12 of $25.00", the share of the limit and a thin meter, in warning ink
/// from 80% of the limit on. Requests that reported no cost are named: their
/// spend cannot be counted. Read as one element (`children: .combine`).
@MainActor final class CostLimitMeter: DashView, PiKit.WidthSizing {
    var reading: SessionCostReading { didSet { if oldValue != reading { apply() } } }
    private let figure = Figure()
    private let bar = Bar()
    private let unreported = Note()
    static let spacing: CGFloat = 6

    init(reading: SessionCostReading) {
        self.reading = reading
        super.init(frame: .zero)
        for view in [figure, bar, unreported] as [NSView] { addSubview(view) }
        figure.setAccessibilityIdentifier("cost-limit-figure")
        unreported.setAccessibilityIdentifier("cost-limit-unreported")
        bar.setAccessibilityElement(false)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        apply()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }

    /// The share of the limit spent, past 100% too: a limit lowered below the spend reads as over it.
    nonisolated static func percent(_ fraction: Double) -> String {
        let value = fraction * 100
        return value > 0 && value < 1 ? "<1%" : "\(Int(value.rounded()))%"
    }
    private var headline: String {
        if let figure = reading.figure { return figure }
        return reading.limit.usd == nil ? "No limit" : "Limit " + reading.limit.label
    }
    private var unreportedText: String? { reading.unreportedNote.map { $0 + "; their cost can't be counted." } }

    private func apply() {
        let warning = reading.warning
        figure.headline = PiKit.Line(headline, font: PiKit.Font.monospacedDigits(.systemFont(ofSize: 15, weight: .semibold)), color: warning ? .piWarning : .piInk)
        figure.percent = reading.fraction.map { PiKit.Line(Self.percent($0), font: PiKit.Font.monospacedDigits(.systemFont(ofSize: PiKit.Font.captionSize, weight: .medium)), color: warning ? .piWarning : .piInkSecondary) }
        figure.setAccessibilityLabel(headline)
        bar.isHidden = reading.fraction == nil
        bar.fraction = reading.fraction ?? 0
        bar.warning = warning
        unreported.isHidden = unreportedText == nil
        unreported.text = unreportedText ?? ""
        setAccessibilityLabel([headline, figure.percent?.text, unreportedText].compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
        PiKit.sizeChanged(self)
    }

    private func parts(_ width: CGFloat) -> [(NSView, CGFloat)] {
        var parts: [(NSView, CGFloat)] = [(figure, figure.height)]
        if !bar.isHidden { parts.append((bar, 6)) }
        if !unreported.isHidden { parts.append((unreported, unreported.height(forWidth: width))) }
        return parts
    }
    func height(forWidth width: CGFloat) -> CGFloat {
        let parts = parts(width)
        return parts.reduce(0) { $0 + $1.1 } + CGFloat(max(0, parts.count - 1)) * Self.spacing
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 320)) }
    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for (view, height) in parts(bounds.width) {
            view.frame = CGRect(x: 0, y: y, width: bounds.width, height: height)
            y += height + Self.spacing
        }
    }

    /// The figure and, on its baseline at the trailing edge, the share.
    final class Figure: DashView {
        var headline = PiKit.Line("", font: .systemFont(ofSize: 15), color: .piInk) { didSet { needsDisplay = true } }
        var percent: PiKit.Line? { didSet { needsDisplay = true } }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
        var height: CGFloat {
            guard let percent else { return headline.lineHeight }
            let top = max(0, headline.baseline(scale: piScale) - percent.baseline(scale: piScale))
            return max(headline.lineHeight, top + percent.lineHeight)
        }
        override func draw(_ dirtyRect: NSRect) {
            let scale = piScale
            var room = bounds.width
            if let percent {
                let size = percent.size(scale: scale)
                let top = PiKit.round(headline.baseline(scale: scale) - percent.baseline(scale: scale), scale)
                percent.draw(at: CGPoint(x: bounds.width - size.width, y: top), scale: scale)
                room = max(0, bounds.width - size.width - PiSpacing.sm)
            }
            // `.minimumScaleFactor(0.8)`, then cut.
            PiKit.drawScaled(headline, in: CGRect(x: 0, y: 0, width: room, height: headline.lineHeight), minimumScale: 0.8, scale: scale)
        }
    }

    /// `Label(note, systemImage: "exclamationmark.circle")` in the micro font,
    /// wrapping. Measured against SwiftUI: the label's first line is 13.2
    /// points tall (the symbol set by its baseline, not centred), its words
    /// half a point lower and the symbol half a point higher than centred in
    /// a 13-point line.
    final class Note: DashView, PiKit.WidthSizing {
        private let block = TextBlock("", font: PiKit.Font.micro, color: .piWarning)
        private let glyph = PiKit.Symbol("exclamationmark.circle", size: PiKit.Font.micro.pointSize, weight: PiKit.Font.micro.piWeight)
        var text: String { get { block.text } set { block.text = newValue; setAccessibilityLabel(newValue); needsLayout = true; needsDisplay = true } }
        static let firstLineExtra: CGFloat = 0.2
        override init(frame: NSRect) {
            super.init(frame: frame)
            addSubview(block)
            setAccessibilityElement(true); setAccessibilityRole(.staticText)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        private var indent: CGFloat { glyph.layoutSize.width + LabelView.spacing }
        func height(forWidth width: CGFloat) -> CGFloat {
            max(block.height(forWidth: max(0, width - indent)), glyph.layoutSize.height) + Self.firstLineExtra
        }
        override func layout() {
            super.layout()
            let width = max(0, bounds.width - indent)
            block.frame = CGRect(x: indent, y: 0.5, width: width, height: block.height(forWidth: width))
            needsDisplay = true
        }
        override func draw(_ dirtyRect: NSRect) {
            let line = PiKit.Line("Ag", font: PiKit.Font.micro, color: .black).lineHeight
            glyph.draw(centredIn: CGRect(x: 0, y: -0.5, width: glyph.layoutSize.width, height: line), color: .piWarning, scale: piScale)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// The spend's share of the limit: a track, and the part used.
    final class Bar: DashView {
        var fraction: Double = 0 { didSet { if oldValue != fraction { needsDisplay = true } } }
        var warning = false { didSet { if oldValue != warning { needsDisplay = true } } }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let track = CGPath(roundedRect: bounds, cornerWidth: bounds.height / 2, cornerHeight: bounds.height / 2, transform: nil)
            context.addPath(track); context.setFillColor(NSColor.piFillStrong.cgColor); context.fillPath()
            let used = max(0, min(1, fraction)) * bounds.width
            guard used > 0 else { return }
            context.addPath(track); context.clip()
            context.setFillColor((warning ? NSColor.piWarning : NSColor.piBrandOrange).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: max(bounds.height, used), height: bounds.height))
        }
    }
}

/// One choice among the limits: a capsule that reads as selected with the
/// accent wash and a check.
@MainActor final class CostLimitChip: PiKit.ButtonBase {
    var label: String { didSet { if oldValue != label { invalidateIntrinsicContentSize(); redrawContent(); setAccessibilityLabel(label) } } }
    var selected: Bool { didSet { if oldValue != selected { invalidateIntrinsicContentSize(); refreshFace(); redrawContent() } } }
    init(_ label: String, selected: Bool, action: @escaping () -> Void) {
        self.label = label; self.selected = selected
        super.init(frame: .zero)
        pressScales = false
        onPress = action
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override func isAccessibilitySelected() -> Bool { selected }
    private var line: PiKit.Line { PiKit.Line(label, font: PiKit.Font.monospacedDigits(.systemFont(ofSize: 12, weight: .medium)), color: selected ? .piAccent : .piInk) }
    private var check: PiKit.Symbol { PiKit.Symbol("checkmark", size: 9, weight: .bold) }
    override var intrinsicContentSize: NSSize {
        let text = line.size(scale: piScale)
        var width = text.width, height = text.height
        if selected { width += check.layoutSize.width + 4; height = max(height, check.layoutSize.height) }
        return NSSize(width: width + 20, height: height + 10)
    }
    override func drawContent(in rect: CGRect) {
        let scale = piScale, text = line.size(scale: scale)
        var x: CGFloat = 10
        let inner = CGRect(x: 0, y: 5, width: rect.width, height: rect.height - 10)
        if selected {
            let box = check.layoutSize
            check.draw(centredIn: CGRect(x: x, y: inner.minY, width: box.width, height: inner.height), color: .piAccent, scale: scale)
            x += box.width + 4
        }
        line.draw(at: CGPoint(x: x, y: inner.minY + PiKit.round((inner.height - text.height) / 2, scale)), scale: scale)
    }
    override func styleFace() {
        fill.backgroundColor = piCGColor(selected ? .piAccentSoft : hovering && isEffectivelyEnabled ? .piFill : .piSurface)
        stroke.borderColor = piCGColor(selected ? NSColor.piAccent.piOpacity(0.55) : .piHairlineStrong)
        // `.opacity(configuration.isPressed ? 0.75 : 1)`, each layer on its own.
        let opacity: Float = isPressedDown ? 0.75 : 1
        fill.opacity = opacity; stroke.opacity = opacity; content.opacity = opacity
    }
}

/// The limits to choose from — the default (in a chat's editor), No limit,
/// the presets and a custom amount — as one row of chips that wraps, and the
/// custom amount's field under them when it is open.
@MainActor final class CostLimitChoices: DashView, PiKit.WidthSizing, ProposedWidthSizing {
    /// The choice shown as selected; nil is the default.
    var selection: CostLimit? { didSet { if oldValue != selection { refreshChips() } } }
    /// Offer "Default ($25.00)" first: a chat's editor does, Settings does not.
    var defaultLimit: CostLimit? { didSet { if oldValue != defaultLimit { defaultChip?.label = defaultLabel; refreshChips() } } }
    var choose: (CostLimit?) -> Void
    let idPrefix: String
    /// SwiftUI's `.disabled` over the choices.
    var inheritedEnabled = true { didSet { if oldValue != inheritedEnabled { applyEnabled() } } }
    /// A form that sets its controls enabled itself (Settings): told the Set
    /// button's own state, so the form's pass keeps an invalid amount's disabled.
    weak var enabledState: EnabledState? { didSet { refreshCustom() } }
    private let flow = PiKit.FlowView()
    private var defaultChip: CostLimitChip?
    private var noneChip: CostLimitChip!
    private var presetChips: [(Double, CostLimitChip)] = []
    private var customChip: CostLimitChip!
    private(set) var customOpen = false
    private let field: PiKit.TextField
    private let setButton: PiKit.Button
    private let invalidText = TextBlock("Enter an amount above $0.00, up to $1,000,000.00.", font: PiKit.Font.micro, color: .piDanger)
    private var invalid = false

    init(selection: CostLimit?, defaultLimit: CostLimit? = nil, identifier: String = "cost-limit", choose: @escaping (CostLimit?) -> Void) {
        self.selection = selection; self.defaultLimit = defaultLimit; self.idPrefix = identifier; self.choose = choose
        field = PiKit.TextField(placeholder: "Amount in US dollars", icon: "dollarsign")
        setButton = PiKit.Button("Set Limit", style: .secondary, compact: true)
        super.init(frame: .zero)
        flow.spacing = 6; flow.rowSpacing = 6
        if defaultLimit != nil {
            let chip = CostLimitChip(defaultLabel, selected: false) { [weak self] in self?.pick(nil) }
            chip.setAccessibilityIdentifier(idPrefix + "-default")
            defaultChip = chip; flow.addSubview(chip)
        }
        noneChip = CostLimitChip("No limit", selected: false) { [weak self] in self?.pick(.unlimited) }
        noneChip.setAccessibilityIdentifier(identifier + "-none"); flow.addSubview(noneChip)
        for amount in CostLimit.presets {
            let chip = CostLimitChip(CostLimitText.preset(amount), selected: false) { [weak self] in self?.pick(.usd(amount)) }
            chip.setAccessibilityIdentifier(identifier + "-\(Int(amount))")
            presetChips.append((amount, chip)); flow.addSubview(chip)
        }
        customChip = CostLimitChip("Custom…", selected: false) { [weak self] in self?.toggleCustom() }
        customChip.setAccessibilityIdentifier(identifier + "-custom"); flow.addSubview(customChip)
        field.setAccessibilityIdentifier(identifier + "-custom-amount")
        field.onChange = { [weak self] _ in self?.customChanged() }
        field.onSubmit = { [weak self] in self?.applyCustom() }
        setButton.setAccessibilityIdentifier(identifier + "-custom-set")
        setButton.onPress = { [weak self] in self?.applyCustom() }
        for view in [flow, field, setButton, invalidText] as [NSView] { addSubview(view) }
        refreshChips()
        refreshCustom()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }

    private var defaultLabel: String { "Default (\(defaultLimit?.label ?? ""))" }
    private var customSelected: Bool {
        guard let amount = selection?.usd else { return false }
        return !CostLimit.presets.contains(amount)
    }
    private func refreshChips() {
        defaultChip?.selected = selection == nil
        noneChip.selected = selection == .unlimited
        for (amount, chip) in presetChips { chip.selected = selection == .usd(amount) }
        customChip.label = customSelected ? "Custom · " + (selection?.label ?? "") : "Custom…"
        customChip.selected = customSelected || customOpen
        // Chips change width with their check and label: the flow places them again.
        flow.invalidateIntrinsicContentSize(); flow.needsLayout = true
        needsLayout = true
        PiKit.sizeChanged(self)
    }
    private func refreshCustom() {
        field.isHidden = !customOpen; setButton.isHidden = !customOpen
        invalidText.isHidden = !(customOpen && invalid)
        let valid = CostLimit.parse(field.text) != nil
        enabledState?.set(setButton, valid)
        setButton.isEnabled = inheritedEnabled && valid && (enabledState?.formEnabled ?? true)
        customChip.selected = customSelected || customOpen
        flow.invalidateIntrinsicContentSize(); flow.needsLayout = true
        invalidateIntrinsicContentSize()
        needsLayout = true
        PiKit.sizeChanged(self)
    }
    private func applyEnabled() {
        for chip in flow.subviews.compactMap({ $0 as? CostLimitChip }) { chip.isEnabled = inheritedEnabled }
        field.field.isEnabled = inheritedEnabled
        field.alphaValue = inheritedEnabled ? 1 : 0.5
        refreshCustom()
    }
    private func pick(_ limit: CostLimit?) {
        customOpen = false
        refreshCustom()
        choose(limit)
    }
    private func toggleCustom() {
        customOpen.toggle()
        if customOpen, field.text.isEmpty, let amount = selection?.usd { field.text = String(format: amount >= 0.01 ? "%.2f" : "%g", amount) }
        refreshCustom()
        if customOpen { window?.makeFirstResponder(field.field) }
    }
    private func customChanged() {
        invalid = false
        refreshCustom()
    }
    private func applyCustom() {
        guard let limit = CostLimit.parse(field.text) else { invalid = true; refreshCustom(); return }
        invalid = false; customOpen = false
        refreshCustom()
        choose(limit)
    }

    // MARK: Layout

    private static let fieldWidth: CGFloat = 200
    private var rowHeight: CGFloat { max(PiKit.height(of: field, width: Self.fieldWidth), setButton.intrinsicContentSize.height) }
    func height(forWidth width: CGFloat) -> CGFloat {
        var height = flow.height(forWidth: width)
        if customOpen {
            height += PiSpacing.sm + rowHeight
            if invalid { height += PiSpacing.sm + invalidText.height(forWidth: width) }
        }
        return height
    }
    /// Its own width when offered `proposal`, as SwiftUI sizes it: all of it
    /// (the chips' `PiFlow` takes the width it is offered).
    func width(forProposal proposal: CGFloat) -> CGFloat { proposal }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 380)) }
    override func layout() {
        super.layout()
        let width = bounds.width
        let flowHeight = flow.height(forWidth: width)
        flow.frame = CGRect(x: 0, y: 0, width: width, height: flowHeight)
        guard customOpen else { return }
        let y = flowHeight + PiSpacing.sm, row = rowHeight
        let buttonSize = setButton.intrinsicContentSize
        let fieldWidth = max(0, min(Self.fieldWidth, width - PiSpacing.sm - buttonSize.width))
        let fieldHeight = PiKit.height(of: field, width: fieldWidth)
        field.frame = CGRect(x: 0, y: y + PiKit.round((row - fieldHeight) / 2, piScale), width: fieldWidth, height: fieldHeight)
        setButton.frame = CGRect(x: fieldWidth + PiSpacing.sm, y: y + PiKit.round((row - buttonSize.height) / 2, piScale), width: buttonSize.width, height: buttonSize.height)
        if invalid {
            invalidText.frame = CGRect(x: 0, y: y + row + PiSpacing.sm, width: width, height: invalidText.height(forWidth: width))
        }
    }
}

/// A chat's own limit: where it stands, the choices, and what a limit does.
/// Choosing saves at once; the chat's next model request is checked against it.
@MainActor class CostLimitEditor: DashView, PiKit.WidthSizing {
    var reading: SessionCostReading { didSet { if oldValue != reading { apply() } } }
    let title: String
    /// Saves a choice; nil follows the Settings default.
    let choose: @MainActor (CostLimit?) async throws -> Void
    private let symbol = PiKit.SymbolView(PiKit.Symbol("dollarsign.circle", size: 12, weight: .medium), color: .piInkTertiary)
    private let titleLine: PiKit.TextLine
    private let spinner = PiKit.spinner(controlSize: .mini)
    private let badge = PiKit.Badge(text: "")
    let meter: CostLimitMeter
    let choices: CostLimitChoices
    private let failureText = TextBlock("", font: PiKit.Font.micro, color: .piDanger)
    private let explanation = TextBlock(CostLimitText.explanation, font: PiKit.Font.micro, color: .piInkTertiary)
    private(set) var saving = false { didSet { spinner.isHidden = !saving; needsLayout = true } }
    private var failure: String? { didSet { failureText.text = failure ?? ""; failureText.isHidden = failure == nil; needsLayout = true; PiKit.sizeChanged(self) } }
    private var save: Task<Void, Never>?

    init(reading: SessionCostReading, title: String = "Cost limit", choose: @escaping @MainActor (CostLimit?) async throws -> Void) {
        self.reading = reading; self.title = title; self.choose = choose
        titleLine = PiKit.TextLine(PiKit.Line(title, font: .systemFont(ofSize: PiKit.Font.captionSize, weight: .semibold), color: .piInk))
        meter = CostLimitMeter(reading: reading)
        choices = CostLimitChoices(selection: reading.override, defaultLimit: reading.defaultLimit) { _ in }
        super.init(frame: .zero)
        choices.choose = { [weak self] limit in self?.pick(limit) }
        symbol.setAccessibilityElement(false)
        badge.setAccessibilityIdentifier("cost-limit-source")
        spinner.isHidden = true
        failureText.isHidden = true
        for view in [symbol, titleLine, spinner, badge, meter, choices, failureText, explanation] as [NSView] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityIdentifier("cost-limit-editor")
        apply()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    deinit { save?.cancel() }

    private func apply() {
        badge.text = reading.source
        badge.tone = reading.override == nil ? .neutral : .accent
        meter.reading = reading
        choices.selection = reading.override
        choices.defaultLimit = reading.defaultLimit
        needsLayout = true
        PiKit.sizeChanged(self)
    }
    private func pick(_ limit: CostLimit?) {
        failure = nil; saving = true
        let choose = self.choose
        save = Task { @MainActor [weak self] in
            do { try await choose(limit) } catch { self?.failure = error.localizedDescription }
            self?.saving = false
        }
    }

    // MARK: Layout

    private var headerHeight: CGFloat { max(titleLine.intrinsicContentSize.height, symbol.intrinsicContentSize.height, badge.intrinsicContentSize.height) }
    private func parts(_ width: CGFloat) -> [(NSView, CGFloat)] {
        // The meter's fractional height (its note's 13.2-point line) is
        // rounded up to the pixel before the next part, as SwiftUI places it.
        var parts: [(NSView, CGFloat)] = [(meter, PiKit.ceil(meter.height(forWidth: width), piScale)), (choices, choices.height(forWidth: width))]
        if failure != nil { parts.append((failureText, failureText.height(forWidth: width))) }
        parts.append((explanation, explanation.height(forWidth: width)))
        return parts
    }
    func height(forWidth width: CGFloat) -> CGFloat {
        parts(width).reduce(headerHeight) { $0 + PiSpacing.md + $1.1 }
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 348)) }
    override func layout() {
        super.layout()
        let scale = piScale, width = bounds.width, header = headerHeight
        func centred(_ view: NSView, x: CGFloat) -> CGFloat {
            let size = view.intrinsicContentSize
            view.frame = CGRect(x: x, y: PiKit.round((header - size.height) / 2, scale), width: size.width, height: size.height)
            return x + size.width
        }
        var x = centred(symbol, x: 0) + PiSpacing.sm
        let badgeWidth = badge.intrinsicContentSize.width
        let spinnerRoom = saving ? spinner.intrinsicContentSize.width + PiSpacing.sm : 0
        let titleWidth = min(titleLine.intrinsicContentSize.width, max(0, width - x - PiSpacing.sm - spinnerRoom - badgeWidth))
        titleLine.frame = CGRect(x: x, y: PiKit.round((header - titleLine.intrinsicContentSize.height) / 2, scale), width: titleWidth, height: titleLine.intrinsicContentSize.height)
        x = width - badgeWidth
        _ = centred(badge, x: x)
        if saving { _ = centred(spinner, x: x - PiSpacing.sm - spinner.intrinsicContentSize.width) }
        var y = header
        for (view, height) in parts(width) {
            y += PiSpacing.md
            view.frame = CGRect(x: 0, y: y, width: width, height: height)
            y += height
        }
    }
}

/// The editor over a chat's live reading: its figures move as requests settle.
@MainActor final class CostLimitLiveEditor: CostLimitEditor {
    private var observer: ShellObserver?
    /// The chat's figures; a replaced chat display (reopened, evicted) is followed.
    var footer: SessionMetrics { didSet { if footer !== oldValue { follow() } } }
    init(footer: SessionMetrics, title: String = "Cost limit", choose: @escaping @MainActor (CostLimit?) async throws -> Void) {
        self.footer = footer
        super.init(reading: footer.cost, title: title, choose: choose)
        follow()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private func follow() {
        reading = footer.cost
        let observer = ShellObserver { [weak self] in guard let self else { return }; self.reading = self.footer.cost }
        observer.observe(publisher: footer.$cost)
        self.observer = observer
    }
}
