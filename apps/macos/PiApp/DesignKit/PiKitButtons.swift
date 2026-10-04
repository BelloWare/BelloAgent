import AppKit
import QuartzCore

extension PiKit {
    /// What every clickable Pi control shares. It is an `NSButton`, so target
    /// and action, Space and Return, key equivalents (a sheet's default and
    /// cancel buttons), keyboard focus under Full Keyboard Access and the
    /// accessibility button with its press all come from AppKit; what it
    /// draws is its own.
    ///
    /// Its face is a layer centred in it, so a press can shrink it to 97 per
    /// cent about its centre as SwiftUI's button styles do. Under the face's
    /// content sits its fill; a shadow, when it has one, may fall outside the
    /// control as SwiftUI's does. Nothing is drawn per frame: hover, press,
    /// focus and enabled each set the layers once, eased by Core Animation.
    @MainActor class ButtonBase: NSButton {
        /// What moves on a press: the fill and the content.
        let face = CALayer()
        /// The control's fill, under its content.
        let fill = CALayer()
        /// The content: a label, a symbol, both.
        let content = DrawingLayer()
        /// An outline over the fill, as `.overlay(shape.stroke(...))`: centred
        /// on the edge, half of it outside, as a SwiftUI stroke is.
        let stroke = CALayer()
        /// A tint over the fill (the primary button's hover and press shade).
        let shade = CALayer()

        private(set) var hovering = false
        /// Shows the pointing hand while enabled, as `piPointer()`.
        var showsPointer = true { didSet { window?.invalidateCursorRects(for: self) } }
        /// Whether a press shrinks the face.
        var pressScales = true
        /// The opacity of the whole control while disabled.
        var disabledOpacity: Float = 0.4
        /// Called with the new hover state, for a face drawn elsewhere.
        var onHover: ((Bool) -> Void)?
        var onPress: (() -> Void)?
        private var tracking: NSTrackingArea?
        private var shownPressed = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            let cell = Cell(); cell.owner = self
            self.cell = cell
            title = ""; isBordered = false; imagePosition = .noImage
            setButtonType(.momentaryPushIn)
            focusRingType = .exterior
            target = self; action = #selector(pressed(_:))
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
            layer?.masksToBounds = false
            face.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            // SwiftUI's opacity fades each layer on its own, not the
            // composite: a label fades over its already faded fill.
            face.allowsGroupOpacity = false
            face.addSublayer(fill)
            face.addSublayer(shade)
            face.addSublayer(stroke)
            face.addSublayer(content)
            for layer in [fill, shade, stroke] { layer.cornerCurve = .continuous }
            content.drawer = { [weak self] rect in self?.drawContent(in: rect) }
            layer?.addSublayer(face)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }

        /// The cell owns the highlight during a press's tracking loop; this
        /// one tells the control, which shows it.
        final class Cell: NSButtonCell {
            weak var owner: ButtonBase?
            override var isHighlighted: Bool {
                didSet { if oldValue != isHighlighted { MainActor.assumeIsolated { owner?.refreshFace() } } }
            }
            // The control draws itself; the cell draws nothing.
            override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {}
            override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {}
        }

        @objc private func pressed(_ sender: Any?) { onPress?() }

        /// Whether the press is down now.
        var isPressedDown: Bool { cell?.isHighlighted ?? false }

        // MARK: To override

        /// Draws the content, in the face's flipped coordinates.
        func drawContent(in rect: CGRect) {}
        /// Sets the fill, stroke and shadow for the state; called inside an
        /// eased transaction.
        func styleFace() {}
        /// The face's corner radius for `size`: a capsule's unless a subclass says.
        func cornerRadius(for size: CGSize) -> CGFloat { min(size.width, size.height) / 2 }
        /// Whether the corners are a circle's arc (an icon button's circle)
        /// rather than SwiftUI's continuous capsule curve.
        var circularCorners = false
        /// The width of the outline, when it has one.
        var strokeWidth: CGFloat = 1
        func shape(in rect: CGRect) -> CGPath {
            let radius = cornerRadius(for: rect.size)
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }

        // MARK: State

        override var isEnabled: Bool {
            didSet { if oldValue != isEnabled { refreshFace(); window?.invalidateCursorRects(for: self) } }
        }

        /// Sets every layer for the current state; eased unless `animated` is false.
        func refreshFace(animated: Bool = true) {
            let pressedNow = isPressedDown
            let changedPress = pressedNow != shownPressed
            shownPressed = pressedNow
            effectiveAppearance.performAsCurrentDrawingAppearance {
                Motion.layers(Motion.quick, animated: animated && window != nil) {
                    styleFace()
                    face.opacity = isEnabled ? 1 : disabledOpacity
                    let scale: CGFloat = pressedNow && pressScales && !Motion.reduced ? 0.97 : 1
                    if changedPress || !animated { face.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale)) }
                }
            }
        }

        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let transform = face.affineTransform()
            face.setAffineTransform(.identity)
            face.bounds = bounds
            face.position = CGPoint(x: bounds.midX, y: bounds.midY)
            face.setAffineTransform(transform)
            for layer in [fill, shade, content] as [CALayer] { layer.frame = face.bounds }
            stroke.frame = face.bounds.insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2)
            let radius = cornerRadius(for: face.bounds.size)
            fill.cornerRadius = radius; shade.cornerRadius = radius
            stroke.cornerRadius = radius + strokeWidth / 2; stroke.borderWidth = strokeWidth
            for layer in [fill, shade, stroke] { layer.cornerCurve = circularCorners ? .circular : .continuous }
            content.contentsScale = piScale
            CATransaction.commit()
            content.setNeedsDisplay()
        }
        override var isFlipped: Bool { true }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            content.appearance = effectiveAppearance
            content.setNeedsDisplay()
            refreshFace(animated: false)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            content.contentsScale = piScale
            content.appearance = effectiveAppearance
            content.setNeedsDisplay()
            refreshFace(animated: false)
            if window == nil, hovering { setHovering(false) }
        }
        /// Redraws the content (a label or a symbol changed).
        func redrawContent() { content.setNeedsDisplay() }

        // The cell draws nothing; the layers are the control.
        override func draw(_ dirtyRect: NSRect) {}

        // MARK: Pointer

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
            addTrackingArea(area); tracking = area
        }
        override func mouseEntered(with event: NSEvent) { setHovering(true) }
        override func mouseExited(with event: NSEvent) { setHovering(false) }
        func setHovering(_ value: Bool) {
            guard hovering != value else { return }
            hovering = value
            onHover?(value)
            refreshFace()
        }
        override func resetCursorRects() {
            if showsPointer && isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
        }

        // MARK: Focus

        override var focusRingMaskBounds: NSRect { bounds }
        override func drawFocusRingMask() { NSBezierPath(cgPath: shape(in: bounds)).fill() }
    }

    /// The further dimming SwiftUI gives the label of a disabled
    /// `.buttonStyle(.plain)` button, on top of any opacity of its own.
    nonisolated static let plainDisabledDimming: Float = 0.5

    /// What a SwiftUI shadow radius is as a Core Animation shadow radius.
    nonisolated static func shadowRadius(_ swiftUI: CGFloat) -> CGFloat { swiftUI * shadowScale }
    nonisolated(unsafe) static var shadowScale: CGFloat = 1

    /// A pill button in one of the app's four styles, as the SwiftUI
    /// `.piPrimary`, `.piSecondary`, `.piGhost` (and its danger tone) and
    /// `.piDanger` button styles draw it: a label, optionally after a symbol.
    @MainActor final class Button: ButtonBase {
        enum Style: Equatable { case primary, secondary, ghost, ghostDanger, danger }
        var style: Style { didSet { invalidate() } }
        var compact: Bool { didSet { invalidate() } }
        /// The label.
        override var title: String { didSet { if oldValue != title { invalidate() } } }
        /// A symbol before the label, as `Label(_:systemImage:)`.
        var symbol: String? { didSet { invalidate() } }
        /// The symbol after the label instead, as the pager's Next.
        var symbolTrailing = false { didSet { invalidate() } }

        init(_ title: String, symbol: String? = nil, style: Style = .secondary, compact: Bool = false, action: (() -> Void)? = nil) {
            self.style = style; self.compact = compact; self.symbol = symbol
            super.init(frame: .zero)
            self.title = title
            onPress = action
            setAccessibilityLabel(nil)
            invalidate()
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }

        private func invalidate() {
            invalidateIntrinsicContentSize(); needsLayout = true
            redrawContent(); refreshFace(animated: false)
        }

        private var fontSize: CGFloat {
            switch style {
            case .primary, .secondary: return compact ? 12 : 13
            case .ghost, .ghostDanger: return 12.5
            case .danger: return 12
            }
        }
        private var weight: NSFont.Weight {
            switch style {
            case .primary, .danger: return .semibold
            case .secondary, .ghost, .ghostDanger: return .medium
            }
        }
        private var padding: (h: CGFloat, v: CGFloat) {
            switch style {
            case .primary: return compact ? (12, 6) : (16, 8)
            case .secondary: return compact ? (11, 5) : (14, 7)
            case .ghost, .ghostDanger: return (10, 6)
            case .danger: return (12, 6)
            }
        }
        var ink: NSColor {
            switch style {
            case .primary: return .piOnAccent
            case .secondary: return .piInk
            case .ghost: return .piInkSecondary
            case .ghostDanger, .danger: return .piDanger
            }
        }
        private var line: Line { Line(title, font: .systemFont(ofSize: fontSize, weight: weight), color: ink) }
        /// The symbol in a label: the label's font at the same size and weight.
        private var glyph: Symbol? { symbol.map { Symbol($0, size: fontSize, weight: weight) } }
        /// Between a label's symbol and its title.
        /// Between a label's symbol and its title: SwiftUI's `Label` puts 8
        /// points, the trailing-icon label style 4.
        static let labelSpacing: CGFloat = 8
        static let trailingSpacing: CGFloat = 4
        private var spacing: CGFloat { symbolTrailing ? Self.trailingSpacing : Self.labelSpacing }
        private var labelSize: CGSize {
            let text = line.size(scale: piScale)
            guard let glyph else { return text }
            let image = glyph.layoutSize
            return CGSize(width: text.width + (title.isEmpty ? 0 : spacing) + image.width, height: max(text.height, image.height))
        }
        override var intrinsicContentSize: NSSize {
            let label = labelSize
            return NSSize(width: label.width + padding.h * 2, height: label.height + padding.v * 2)
        }

        override func drawContent(in rect: CGRect) {
            let label = labelSize
            var x = ((rect.width - label.width) / 2), y = ((rect.height - label.height) / 2)
            x = PiKit.round(x, piScale); y = PiKit.round(y, piScale)
            let text = line.size(scale: piScale)
            if let glyph {
                let image = glyph.layoutSize
                let imageX = symbolTrailing ? x + text.width + spacing : x
                glyph.draw(centredIn: CGRect(x: imageX, y: y, width: image.width, height: label.height), color: ink, scale: piScale)
                let textX = symbolTrailing ? x : x + image.width + (title.isEmpty ? 0 : spacing)
                line.draw(at: CGPoint(x: textX, y: y + (label.height - text.height) / 2), scale: piScale)
            } else {
                line.draw(at: CGPoint(x: x, y: y), scale: piScale)
            }
        }

        override func styleFace() {
            let pressed = isPressedDown
            switch style {
            case .primary:
                // Shade the flat fill on interaction without fading its label.
                fill.backgroundColor = piCGColor(.piBrandOrange)
                shade.backgroundColor = piCGColor(NSColor.black.withAlphaComponent(pressed ? 0.10 : hovering ? 0.05 : 0))
                stroke.borderColor = CGColor.clear
                fill.shadowColor = piCGColor(.piBrandOrange); fill.shadowOpacity = 0.22
                fill.shadowRadius = PiKit.shadowRadius(5); fill.shadowOffset = CGSize(width: 0, height: 2)
            case .secondary:
                fill.backgroundColor = piCGColor(pressed || hovering ? .piFillStrong : .piFill)
                stroke.borderColor = piCGColor(.piHairline)
                fill.shadowOpacity = 0
            case .ghost, .ghostDanger:
                fill.backgroundColor = piCGColor(pressed ? .piFillStrong : hovering ? .piFill : .clear)
                stroke.borderColor = CGColor.clear
                fill.shadowOpacity = 0
            case .danger:
                fill.backgroundColor = piCGColor(NSColor.piDanger.withAlphaComponent(pressed ? 0.22 : hovering ? 0.17 : 0.12))
                stroke.borderColor = CGColor.clear
                fill.shadowOpacity = 0
            }
        }
    }

    /// A symbol-only button with a soft circle under the pointer, as
    /// `PiIconButton`. Its tooltip is `label`; VoiceOver says `spokenLabel`
    /// when it names the item acted on ("Remove follow-up 2").
    @MainActor final class IconButton: ButtonBase {
        var symbol: String { didSet { redrawContent() } }
        var label: String { didSet { applyLabels() } }
        var spokenLabel: String? { didSet { applyLabels() } }
        var tone: PiTone { didSet { redrawContent() } }
        var size: CGFloat { didSet { invalidateIntrinsicContentSize(); redrawContent() } }
        var filled: Bool { didSet { refreshFace() } }

        init(symbol: String, label: String, tone: PiTone = .neutral, size: CGFloat = 28, filled: Bool = false,
             spokenLabel: String? = nil, action: (() -> Void)? = nil) {
            self.symbol = symbol; self.label = label; self.tone = tone; self.size = size; self.filled = filled; self.spokenLabel = spokenLabel
            super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
            disabledOpacity = 0.35 * PiKit.plainDisabledDimming
            pressScales = false
            circularCorners = true
            onPress = action
            applyLabels()
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        private func applyLabels() {
            toolTip = label
            setAccessibilityLabel(spokenLabel ?? label)
        }
        override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }

        override func drawContent(in rect: CGRect) {
            Symbol(symbol, size: size * 0.46, weight: .medium)
                .draw(centredIn: rect, color: tone == .neutral ? .piInkSecondary : tone.nsColor, scale: piScale)
        }
        override func styleFace() {
            fill.backgroundColor = piCGColor(filled || hovering ? .piFillStrong : .clear)
            stroke.borderColor = CGColor.clear
        }
    }
}
