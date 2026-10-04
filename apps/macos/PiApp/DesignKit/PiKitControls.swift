import AppKit
import QuartzCore

extension PiKit {
    // MARK: - Switch and checkbox

    /// AppKit's switch track per control size, which the stock switch takes
    /// whole (`PiSwitchMetrics`).
    static func switchTrack(_ size: NSControl.ControlSize) -> CGSize {
        switch size {
        case .mini: return CGSize(width: 26, height: 15)
        case .small: return CGSize(width: 32, height: 18)
        default: return CGSize(width: 38, height: 22)
        }
    }

    /// The app's switch: an accent track when on, a quiet one when off, and a
    /// white knob, as large as AppKit's switch at the same control size and 8
    /// points after its label. To accessibility it is a switch with its
    /// label and state; Space toggles it.
    @MainActor final class Switch: ButtonBase {
        /// Set from outside without calling `onChange`.
        var isOn: Bool { didSet { if oldValue != isOn { moveKnob(animated: window != nil) } } }
        var label: String { didSet { invalidateIntrinsicContentSize(); redrawContent(); setAccessibilityLabel(label) } }
        var size: NSControl.ControlSize { didSet { invalidateIntrinsicContentSize(); needsLayout = true } }
        /// Called once with the new value when the reader toggles it.
        var onChange: ((Bool) -> Void)?
        private let track = CALayer()
        private let knob = CALayer()

        init(isOn: Bool, label: String = "", size: NSControl.ControlSize = .regular, onChange: ((Bool) -> Void)? = nil) {
            self.isOn = isOn; self.label = label; self.size = size; self.onChange = onChange
            super.init(frame: .zero)
            pressScales = false
            // Only the track fades when disabled; the label keeps its ink.
            disabledOpacity = 1
            track.allowsGroupOpacity = false
            track.cornerCurve = .continuous
            track.borderWidth = 1
            knob.backgroundColor = NSColor.white.cgColor
            knob.shadowColor = NSColor.black.cgColor; knob.shadowOpacity = 0.18
            knob.shadowRadius = PiKit.shadowRadius(1); knob.shadowOffset = CGSize(width: 0, height: 0.5)
            face.addSublayer(track); track.addSublayer(knob)
            onPress = { [weak self] in guard let self else { return }; self.isOn.toggle(); self.onChange?(self.isOn) }
            setAccessibilityRole(.checkBox); setAccessibilityRoleDescription(nil)
            setAccessibilitySubrole(.switch)
            setAccessibilityLabel(label)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }

        /// The label's type and ink: the body font in ink unless the place says.
        var labelFont: NSFont = PiKit.Font.body { didSet { invalidateIntrinsicContentSize(); redrawContent() } }
        var labelInk: NSColor = .piInk { didSet { redrawContent() } }
        private var labelLine: Line { Line(label, font: labelFont, color: labelInk) }
        private var gap: CGFloat { label.isEmpty ? 0 : 8 }
        /// Only the track takes clicks, as only the track is the SwiftUI
        /// switch's button.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            return isHidden || !trackPath.contains(local) ? nil : self
        }
        /// The track's capsule in the control's coordinates: its clicks,
        /// its focus ring and its pointer.
        private var trackPath: CGPath {
            let rect = track.frame
            return CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
        }
        override var focusRingMaskBounds: NSRect { track.frame }
        override func drawFocusRingMask() { NSBezierPath(cgPath: trackPath).fill() }
        override func resetCursorRects() { if showsPointer && isEnabled { addCursorRect(track.frame, cursor: .pointingHand) } }
        override var intrinsicContentSize: NSSize {
            let text = labelLine.size(scale: piScale), track = PiKit.switchTrack(size)
            return NSSize(width: text.width + gap + track.width, height: max(text.height, track.height))
        }
        override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let size = PiKit.switchTrack(self.size)
            track.frame = CGRect(x: bounds.width - size.width, y: ((bounds.height - size.height) / 2).rounded(.down), width: size.width, height: size.height)
            track.cornerRadius = size.height / 2
            let side = size.height - 4
            knob.bounds = CGRect(x: 0, y: 0, width: side, height: side); knob.cornerRadius = side / 2
            CATransaction.commit()
            moveKnob(animated: false)
        }
        private func moveKnob(animated: Bool) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                Motion.layers(Motion.quick, animated: animated) {
                    let size = track.bounds.size, side = size.height - 4
                    knob.position = CGPoint(x: isOn ? size.width - 2 - side / 2 : 2 + side / 2, y: size.height / 2)
                    styleFace()
                }
            }
        }
        override func styleFace() {
            // The track sits in a plain button: SwiftUI dims it again.
            track.opacity = isEnabled ? 1 : 0.45 * PiKit.plainDisabledDimming
            track.backgroundColor = piCGColor(isOn ? .piAccent : .piFillStrong)
            track.borderColor = isOn ? CGColor.clear : piCGColor(.piHairlineStrong)
            fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear
        }
        override func drawContent(in rect: CGRect) {
            guard !label.isEmpty else { return }
            let text = labelLine.size(scale: piScale)
            labelLine.draw(at: CGPoint(x: 0, y: PiKit.round((rect.height - text.height) / 2, piScale)), scale: piScale)
        }
    }

    /// The app's checkbox, as the Changes panel draws its ticks: a filled
    /// accent square with a check when on, an outlined one when off, 14
    /// points and 5 before its label. To accessibility it is a checkbox.
    @MainActor final class Checkbox: ButtonBase {
        var isOn: Bool { didSet { if oldValue != isOn { redrawContent() } } }
        var label: String { didSet { invalidateIntrinsicContentSize(); redrawContent(); setAccessibilityLabel(label) } }
        var onChange: ((Bool) -> Void)?

        init(isOn: Bool, label: String = "", onChange: ((Bool) -> Void)? = nil) {
            self.isOn = isOn; self.label = label; self.onChange = onChange
            super.init(frame: .zero)
            pressScales = false
            disabledOpacity = 0.45 * PiKit.plainDisabledDimming
            onPress = { [weak self] in guard let self else { return }; self.isOn.toggle(); self.onChange?(self.isOn) }
            setAccessibilityRole(.checkBox)
            setAccessibilityLabel(label)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        var labelFont: NSFont = PiKit.Font.body { didSet { invalidateIntrinsicContentSize(); redrawContent() } }
        var labelInk: NSColor = .piInk { didSet { redrawContent() } }
        private var labelLine: Line { Line(label, font: labelFont, color: labelInk) }
        override var intrinsicContentSize: NSSize {
            let text = labelLine.size(scale: piScale)
            return NSSize(width: 14 + (label.isEmpty ? 0 : 5) + text.width, height: max(14, text.height))
        }
        override func shape(in rect: CGRect) -> CGPath { CGPath(rect: rect, transform: nil) }
        override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
        override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
        override func drawContent(in rect: CGRect) {
            let mark = Symbol(isOn ? "checkmark.square.fill" : "square", size: 13, weight: .medium)
            mark.draw(centredIn: CGRect(x: 0, y: (rect.height - 14) / 2, width: 14, height: 14), color: isOn ? .piAccent : .piInkTertiary, scale: piScale)
            guard !label.isEmpty else { return }
            let text = labelLine.size(scale: piScale)
            labelLine.draw(at: CGPoint(x: 19, y: PiKit.round((rect.height - text.height) / 2, piScale)), scale: piScale)
        }
    }

    // MARK: - Progress

    /// A determinate bar: a 4-point track and the share done in the accent,
    /// in the 18 points the stock bar took. To accessibility it is a
    /// progress indicator with its value.
    @MainActor final class ProgressBar: NSView {
        var value: Double { didSet { needsLayout = true; updateAccessibility() } }
        var total: Double { didSet { needsLayout = true; updateAccessibility() } }
        static let room: CGFloat = 18
        private let track = CALayer(), bar = CALayer()
        var fraction: Double { total > 0 && value.isFinite ? min(1, max(0, value / total)) : 0 }

        init(value: Double, total: Double = 1) {
            self.value = value; self.total = total
            super.init(frame: .zero)
            wantsLayer = true
            for layer in [track, bar] { layer.cornerCurve = .continuous; self.layer?.addSublayer(layer) }
            setAccessibilityElement(true); setAccessibilityRole(.progressIndicator)
            updateAccessibility()
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        private func updateAccessibility() { setAccessibilityValue(fraction); setAccessibilityMinValue(0); setAccessibilityMaxValue(1) }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.room) }
        override var isFlipped: Bool { true }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let y = (bounds.height - 4) / 2
            track.frame = CGRect(x: 0, y: y, width: bounds.width, height: 4); track.cornerRadius = 2
            bar.frame = CGRect(x: 0, y: y, width: bounds.width * fraction, height: 4); bar.cornerRadius = 2
            CATransaction.commit()
            updateLayer()
        }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {
            track.backgroundColor = piCGColor(.piFill); bar.backgroundColor = piCGColor(.piAccent)
        }
    }

    // MARK: - Tabs

    /// The pill segmented control: tabs in a quiet capsule, the chosen one on
    /// a white capsule that glides to the next choice. With a name it is one
    /// named group of tabs to VoiceOver, the chosen tab marked selected.
    @MainActor final class Tabs<Tag: Hashable>: NSView {
        /// The tabs. The same tags in the same order keep their buttons (and
        /// focus) and only retitle; anything else rebuilds them.
        var items: [(Tag, String)] {
            didSet {
                rebuild()
            }
        }
        /// Set from outside without calling `onSelect`.
        var selection: Tag { didSet { if oldValue != selection { selectionChanged(animated: window != nil) } } }
        var onSelect: ((Tag) -> Void)?
        var accessibilityName: String? { didSet { applyName() } }
        private var buttons: [Tab] = []
        private let well = CALayer()
        private let highlight = CALayer()
        static var spacing: CGFloat { 2 }
        static var inset: CGFloat { 3 }

        init(selection: Tag, items: [(Tag, String)], accessibilityName: String? = nil, onSelect: ((Tag) -> Void)? = nil) {
            self.selection = selection; self.items = items; self.accessibilityName = accessibilityName; self.onSelect = onSelect
            super.init(frame: .zero)
            wantsLayer = true
            well.cornerCurve = .continuous; highlight.cornerCurve = .continuous
            highlight.shadowOpacity = 1; highlight.shadowRadius = PiKit.shadowRadius(3); highlight.shadowOffset = CGSize(width: 0, height: 1)
            layer?.addSublayer(well); layer?.addSublayer(highlight)
            rebuild(); applyName()
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }

        /// One tab: its title, ink by whether it is chosen.
        @MainActor final class Tab: ButtonBase {
            var chosen = false { didSet { if oldValue != chosen { redrawContent() } } }
            override var title: String { didSet { invalidateIntrinsicContentSize(); redrawContent() } }
            var line: Line { Line(title, font: .systemFont(ofSize: 12, weight: .medium), color: chosen ? .piInk : .piInkSecondary) }
            init(_ title: String) { super.init(frame: .zero); self.title = title; pressScales = false }
            required init?(coder: NSCoder) { fatalError("Not used from a nib") }
            override var intrinsicContentSize: NSSize { let text = line.size(scale: piScale); return NSSize(width: text.width + 22, height: text.height + 10) }
            override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
            override func drawContent(in rect: CGRect) { line.draw(at: CGPoint(x: 11, y: 5), scale: piScale) }
            override func isAccessibilitySelected() -> Bool { chosen }
        }

        /// Reconciles the tab buttons with `items` by tag: a tab that stays
        /// keeps its button (and its focus and accessibility identity), only
        /// retitled; new tags get buttons, gone ones lose theirs.
        private var byTag: [Tag: Tab] = [:]
        private func rebuild() {
            var kept: [Tag: Tab] = [:]
            buttons = items.map { item in
                if let tab = byTag[item.0] {
                    if tab.title != item.1 { tab.title = item.1; tab.setAccessibilityLabel(item.1) }
                    kept[item.0] = tab
                    return tab
                }
                let tab = Tab(item.1)
                kept[item.0] = tab
                tab.onPress = { [weak self] in
                    guard let self, self.selection != item.0 else { return }
                    self.selection = item.0
                    self.onSelect?(item.0)
                }
                addSubview(tab)
                return tab
            }
            for (tag, tab) in byTag where kept[tag] == nil { tab.removeFromSuperview() }
            byTag = kept
            invalidateIntrinsicContentSize(); needsLayout = true
            selectionChanged(animated: false)
        }
        private func applyName() {
            setAccessibilityElement(accessibilityName != nil)
            setAccessibilityRole(accessibilityName != nil ? .group : nil)
            setAccessibilityLabel(accessibilityName)
        }
        override var intrinsicContentSize: NSSize {
            let sizes = buttons.map(\.intrinsicContentSize)
            let width = sizes.reduce(0) { $0 + $1.width } + Self.spacing * CGFloat(max(0, sizes.count - 1)) + Self.inset * 2
            return NSSize(width: width, height: (sizes.map(\.height).max() ?? 0) + Self.inset * 2)
        }
        override func layout() {
            super.layout()
            var x = Self.inset
            for button in buttons {
                let size = button.intrinsicContentSize
                button.frame = CGRect(x: x, y: Self.inset, width: size.width, height: size.height)
                x += size.width + Self.spacing
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            well.frame = bounds; well.cornerRadius = bounds.height / 2
            CATransaction.commit()
            selectionChanged(animated: false)
            updateLayer()
        }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {
            well.backgroundColor = piCGColor(.piFillStrong)
            highlight.backgroundColor = piCGColor(.piSurface); highlight.shadowColor = piCGColor(.piShadow)
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
        private func selectionChanged(animated: Bool) {
            for (index, item) in items.enumerated() where index < buttons.count { buttons[index].chosen = item.0 == selection }
            guard let index = items.firstIndex(where: { $0.0 == selection }), index < buttons.count else { highlight.isHidden = true; return }
            highlight.isHidden = false
            let target = buttons[index].frame
            let move = { self.highlight.frame = target; self.highlight.cornerRadius = target.height / 2 }
            if animated && !Motion.reduced && !highlight.frame.isEmpty {
                let from = highlight.presentation()?.frame ?? highlight.frame
                CATransaction.begin(); CATransaction.setDisableActions(true); move(); CATransaction.commit()
                for (key, from, to) in [("position", NSValue(point: CGPoint(x: from.midX, y: from.midY)), NSValue(point: CGPoint(x: target.midX, y: target.midY))),
                                        ("bounds.size", NSValue(size: from.size), NSValue(size: target.size))] {
                    let spring = Motion.glide(key); spring.fromValue = from; spring.toValue = to
                    highlight.add(spring, forKey: key)
                }
            } else {
                CATransaction.begin(); CATransaction.setDisableActions(true); move(); CATransaction.commit()
            }
        }
        /// The tab button for `tag`, for tests.
        func tab(_ tag: Tag) -> Tab? { items.firstIndex { $0.0 == tag }.map { buttons[$0] } }
    }

    // MARK: - Stepper

    /// The value as text, then minus and plus buttons. VoiceOver names each
    /// button after the setting it changes, with the value and its bounds.
    @MainActor final class Stepper: NSView {
        let name: String, unit: String
        var value: Int64 { didSet { if oldValue != value { refresh() } } }
        var range: ClosedRange<Int64> { didSet { refresh() } }
        var step: Int64
        var onChange: ((Int64) -> Void)?
        let decrease: IconButton, increase: IconButton
        private let text = TextLine()

        init(name: String, unit: String, value: Int64, range: ClosedRange<Int64>, step: Int64 = 1, onChange: ((Int64) -> Void)? = nil) {
            self.name = name; self.unit = unit; self.value = value; self.range = range; self.step = step; self.onChange = onChange
            decrease = IconButton(symbol: "minus", label: "Decrease", size: 24, filled: true, spokenLabel: "Decrease " + name)
            increase = IconButton(symbol: "plus", label: "Increase", size: 24, filled: true, spokenLabel: "Increase " + name)
            super.init(frame: .zero)
            text.setAccessibilityElement(false)
            for view in [text, decrease, increase] as [NSView] { addSubview(view) }
            decrease.onPress = { [weak self] in self?.change(-1) }
            increase.onPress = { [weak self] in self?.change(1) }
            refresh()
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        private func change(_ direction: Int64) {
            let next = min(range.upperBound, max(range.lowerBound, value + direction * step))
            guard next != value else { return }
            value = next
            onChange?(next)
        }
        private func refresh() {
            let shown = "\(value) \(unit)"
            text.line = Line(shown, font: PiKit.Font.monospacedDigits(PiKit.Font.body), color: .piInk)
            let bounds = "From \(range.lowerBound) to \(range.upperBound) \(unit)" + (step == 1 ? "" : ", in steps of \(step)")
            for button in [decrease, increase] { button.setAccessibilityValue(shown); button.setAccessibilityHelp(bounds) }
            decrease.isEnabled = value > range.lowerBound
            increase.isEnabled = value < range.upperBound
            invalidateIntrinsicContentSize(); needsLayout = true
        }
        override var isFlipped: Bool { true }
        /// Its narrowest; it takes the width it is given, its value at the
        /// start and the buttons at the end, as the SwiftUI row's spacer does.
        var minimumWidth: CGFloat { text.intrinsicContentSize.width + 8 + 24 + 6 + 24 }
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: max(text.intrinsicContentSize.height, 24))
        }
        override func layout() {
            super.layout()
            let size = text.intrinsicContentSize
            text.frame = CGRect(x: 0, y: PiKit.round((bounds.height - size.height) / 2, piScale), width: size.width, height: size.height)
            increase.frame = CGRect(x: bounds.width - 24, y: ((bounds.height - 24) / 2).rounded(.down), width: 24, height: 24)
            decrease.frame = increase.frame.offsetBy(dx: -30, dy: 0)
        }
    }

    /// One line of text as a view: `Text`, without selection or wrapping.
    @MainActor final class TextLine: NSView {
        var line: Line { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityLabel(line.text); PiKit.sizeChanged(self) } }
        /// How it ends when it is narrower than its text.
        var truncation: CTLineTruncationType = .end
        init(_ line: Line = Line("", font: PiKit.Font.body, color: .piInk)) {
            self.line = line
            super.init(frame: .zero)
            setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(line.text)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        override var intrinsicContentSize: NSSize { line.size(scale: piScale) }
        override func draw(_ dirtyRect: NSRect) { line.draw(in: CGRect(origin: .zero, size: bounds.size), truncation: truncation, scale: piScale) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
