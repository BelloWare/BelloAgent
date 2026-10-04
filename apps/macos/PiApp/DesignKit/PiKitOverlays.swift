import AppKit
import Combine
import QuartzCore

extension PiKit {
    // MARK: - Stat pill

    /// What a stat pill looks like: its glyph or context ring, its reading
    /// (a last figure in warning ink when it needs attention), and a soft
    /// fill while the pointer is on it or its dialog is open. A figure that
    /// changes rolls to its new value character by character, as SwiftUI's
    /// `contentTransition(.numericText())`: what stayed the same stays put,
    /// the changed characters roll up out and in, and what follows them
    /// slides to its new place. Figures of another `scope` (another chat)
    /// replace the old ones at once.
    @MainActor class StatPill: ButtonBase {
        /// What the glyph slot shows: the symbol, or a context ring (with no
        /// reading yet, an empty ring).
        enum Glyph: Equatable { case symbol(String), ring(Double?) }
        private(set) var symbol: String
        private(set) var ring: Double??
        private(set) var label: String
        private(set) var warningTail: String?
        private(set) var scope: AnyHashable?
        /// Whether a change is rolling in now, for tests.
        var isRolling: Bool { roll != nil }
        /// The characters rolling out and in now, for tests.
        var rollingChange: (from: String, to: String)? { roll.map { ($0.from, $0.to) } }
        /// Shown highlighted whatever the pointer does (its dialog is open).
        var open = false { didSet { refreshFace() } }
        private let ringView: Ring
        /// The reading, a layer of its own so a roll moves the figures only.
        let readingLayer = DrawingLayer()
        /// A roll in progress: the old characters going out, the new ones
        /// coming in, and the characters after them sliding (each a layer
        /// over the reading, which leaves their place empty meanwhile).
        private struct Roll {
            let from: String, to: String
            let layers: [DrawingLayer]
            /// What the reading leaves empty while the roll lasts (UTF-16).
            let hidden: NSRange
            let token: Int
        }
        private var roll: Roll?
        private var rollCount = 0
        /// A name for VoiceOver other than the reading itself, kept across updates.
        var accessibilityName: String? { didSet { setAccessibilityLabel(accessibilityName ?? label) } }

        init(symbol: String, ring: Double?? = nil, label: String, warningTail: String? = nil, scope: AnyHashable? = nil) {
            self.symbol = symbol; self.ring = ring; self.label = label; self.warningTail = warningTail; self.scope = scope
            ringView = Ring.context(ring.flatMap { $0 } ?? 0, size: 14)
            super.init(frame: .zero)
            pressScales = false
            addSubview(ringView)
            ringView.isHidden = ring == nil
            face.addSublayer(readingLayer)
            readingLayer.drawer = { [weak self] rect in self?.drawReading(in: rect) }
            setAccessibilityLabel(label)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }

        /// Updates the reading. Within one scope a change rolls; a new scope
        /// replaces it at once. Set together, so a switch never rolls.
        func update(glyph: Glyph? = nil, label: String, warningTail: String? = nil, scope: AnyHashable?) {
            let sameScope = scope == self.scope
            let oldLabel = self.label, oldTail = self.warningTail
            // Not before the pill has been laid out: the rolling layers take the reading's place.
            let rolls = sameScope && (label != self.label || warningTail != self.warningTail) && window != nil && !Motion.reduced && !readingLayer.bounds.isEmpty
            switch glyph {
            case .symbol(let name)?: symbol = name; ring = nil; ringView.isHidden = true
            case .ring(let value)?: ring = .some(value); ringView.isHidden = false; ringView.fraction = value ?? 0
            case nil: break
            }
            self.label = label; self.warningTail = warningTail; self.scope = scope
            if accessibilityName == nil { setAccessibilityLabel(label) }
            invalidateIntrinsicContentSize(); needsLayout = true
            // Another chat's figures replace the old ones at once, a roll in
            // progress included; a new change in the same chat starts from
            // where the last one was going. An unchanged reading leaves a
            // roll in progress alone.
            if !sameScope || label != oldLabel || warningTail != oldTail { endRoll() }
            if rolls { startRoll(from: Self.reading(oldLabel, oldTail), to: reading) }
            redrawContent(); readingLayer.setNeedsDisplay()
        }

        // MARK: Rolling digits

        /// Rolls the characters that changed between `old` and `new`.
        private func startRoll(from old: NSAttributedString, to new: NSAttributedString) {
            let before = Array(old.string), after = Array(new.string)
            var prefix = 0
            while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < min(before.count, after.count) - prefix, before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
            func range(_ characters: [Character], _ start: Int, _ end: Int) -> NSRange {
                let location = (String(characters[0..<start]) as NSString).length
                return NSRange(location: location, length: (String(characters[start..<end]) as NSString).length)
            }
            let outgoing = range(before, prefix, before.count - suffix), incoming = range(after, prefix, after.count - suffix)
            let trailing = range(after, after.count - suffix, after.count)
            // Where the unchanged end sat before and sits now.
            let shift = Self.offset(of: outgoing.location + outgoing.length, in: old) - Self.offset(of: incoming.location + incoming.length, in: new)
            let rise = Line("Ag", font: PiKit.Font.caption, color: .black).lineHeight
            // Up the screen whatever the layer's geometry.
            let up: CGFloat = readingLayer.contentsAreFlipped() ? -rise : rise
            var layers: [DrawingLayer] = []
            func overlay(_ text: NSAttributedString, showing: NSRange) -> DrawingLayer {
                let layer = DrawingLayer()
                // Wide enough for either reading: the pill lays itself out at
                // the new width only after this.
                var frame = readingLayer.frame
                frame.size.width = max(frame.width, 28 + max(old.size().width, new.size().width) + 16)
                layer.frame = frame; layer.contentsScale = readingLayer.contentsScale; layer.appearance = readingLayer.appearance
                layer.drawer = { [weak self] rect in self?.drawReading(text, in: rect, showing: showing) }
                face.addSublayer(layer); layer.setNeedsDisplay()
                layers.append(layer)
                return layer
            }
            CATransaction.begin()
            rollCount += 1
            let token = rollCount
            CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { if self?.roll?.token == token { self?.endRoll() } } }
            func animate(_ layer: CALayer, _ keyPath: String, from: CGFloat, to: CGFloat) {
                let animation = CABasicAnimation(keyPath: keyPath)
                animation.fromValue = from; animation.toValue = to
                animation.duration = Motion.base; animation.timingFunction = Motion.timing(.easeOut)
                animation.fillMode = .both; animation.isRemovedOnCompletion = false
                layer.add(animation, forKey: keyPath)
            }
            if outgoing.length > 0 {
                let out = overlay(old, showing: outgoing)
                animate(out, "transform.translation.y", from: 0, to: up); animate(out, "opacity", from: 1, to: 0)
            }
            if incoming.length > 0 {
                let into = overlay(new, showing: incoming)
                animate(into, "transform.translation.y", from: -up, to: 0); animate(into, "opacity", from: 0, to: 1)
            }
            var hidden = incoming
            if abs(shift) > 0.001, trailing.length > 0 {
                let slide = overlay(new, showing: trailing)
                animate(slide, "transform.translation.x", from: shift, to: 0)
                hidden = NSRange(location: incoming.location, length: incoming.length + trailing.length)
            }
            roll = Roll(from: String(before[prefix..<(before.count - suffix)]), to: String(after[prefix..<(after.count - suffix)]),
                        layers: layers, hidden: hidden, token: token)
            CATransaction.commit()
        }
        /// Ends a roll at once: the reading shows all of itself again.
        private func endRoll() {
            guard let roll else { return }
            self.roll = nil
            CATransaction.begin(); CATransaction.setDisableActions(true)
            roll.layers.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }
            CATransaction.commit()
            readingLayer.setNeedsDisplay()
        }
        /// The x offset of the character boundary at UTF-16 `index` in `text`.
        private static func offset(of index: Int, in text: NSAttributedString) -> CGFloat {
            CTLineGetOffsetForStringIndex(CTLineCreateWithAttributedString(text), index, nil)
        }

        private var reading: NSAttributedString { Self.reading(label, warningTail) }
        private static func reading(_ label: String, _ warningTail: String?) -> NSAttributedString {
            let font = PiKit.Font.monospacedDigits(PiKit.Font.caption)
            let body = NSMutableAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.piInkSecondary])
            if let warningTail {
                if !label.isEmpty { body.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: NSColor.piInkSecondary])) }
                body.append(NSAttributedString(string: warningTail, attributes: [.font: font, .foregroundColor: NSColor.piWarning]))
            }
            return body
        }
        private var readingSize: CGSize {
            let line = CTLineCreateWithAttributedString(reading)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            return CGSize(width: PiKit.ceil(width, piScale), height: Line("Ag", font: PiKit.Font.caption, color: .black).lineHeight)
        }
        override var intrinsicContentSize: NSSize {
            NSSize(width: 7 + 16 + 5 + readingSize.width + 7, height: max(16, readingSize.height) + 6)
        }
        override func layout() {
            super.layout()
            ringView.frame = CGRect(x: 7 + 1, y: (bounds.height - 14) / 2, width: 14, height: 14)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            readingLayer.frame = face.bounds; readingLayer.contentsScale = piScale; readingLayer.appearance = effectiveAppearance
            CATransaction.commit()
            readingLayer.setNeedsDisplay()
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); readingLayer.appearance = effectiveAppearance; readingLayer.setNeedsDisplay() }
        override func styleFace() {
            fill.backgroundColor = piCGColor(open || hovering ? .piFill : .clear)
            stroke.borderColor = CGColor.clear
        }
        override func drawContent(in rect: CGRect) {
            if ring == nil { Symbol(symbol, size: 11, weight: .medium).draw(centredIn: CGRect(x: 7, y: (rect.height - 16) / 2, width: 16, height: 16), color: .piInkTertiary, scale: piScale) }
        }
        private func drawReading(in rect: CGRect) {
            // During a roll the rolling (and sliding) characters are drawn by their own layers.
            let hidden = roll?.hidden
            let all = NSRange(location: 0, length: (reading.string as NSString).length)
            drawReading(reading, in: rect, showing: all, hiding: hidden)
        }
        /// Draws `text` as the reading, only the characters in `showing`
        /// and not in `hiding` visible (the rest keep their places, unseen).
        private func drawReading(_ text: NSAttributedString, in rect: CGRect, showing: NSRange, hiding: NSRange? = nil) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let size = readingSize
            context.saveGState()
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            let top = PiKit.round((rect.height - size.height) / 2, piScale)
            context.textPosition = CGPoint(x: 28, y: top + Line("", font: PiKit.Font.caption, color: .black).baseline(scale: piScale))
            let attributed = NSMutableAttributedString(attributedString: text)
            let whole = NSRange(location: 0, length: attributed.length)
            attributed.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
                if let color = value as? NSColor { attributed.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: color.cgColor, range: range) }
            }
            let clear = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
            if showing != whole {
                for range in [NSRange(location: 0, length: showing.location), NSRange(location: NSMaxRange(showing), length: whole.length - NSMaxRange(showing))] where range.length > 0 {
                    attributed.addAttribute(clear, value: CGColor.clear, range: range)
                }
            }
            if let hiding, hiding.length > 0, NSMaxRange(hiding) <= whole.length { attributed.addAttribute(clear, value: CGColor.clear, range: hiding) }
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            context.restoreGState()
        }
    }

    /// A stat pill whose dialog is an app-owned popover sized to the screen
    /// around it (`PiPopoverPresenter`).
    @MainActor final class StatPopoverPill: StatPill {
        let presenter: PiPopoverPresenter
        private var observation: AnyCancellable?
        var width: CGFloat = 468
        var maximumHeight: CGFloat = 600
        var willOpen: () -> Void = {}
        /// Whether the dialog has what it needs to open whole; it waits up to
        /// `readyWithin` for it, as the SwiftUI pill does.
        var isReady: @MainActor () -> Bool = { true }
        var readyWithin: Duration = .milliseconds(250)
        var dialog: (@MainActor () -> NSView)?
        private let help: String
        init(symbol: String, label: String, warningTail: String? = nil, accessibility: String? = nil, identifier: String? = nil,
             help: String = "", presenter: PiPopoverPresenter, dialog: @escaping @MainActor () -> NSView) {
            self.presenter = presenter; self.dialog = dialog; self.help = help
            super.init(symbol: symbol, label: label, warningTail: warningTail)
            accessibilityName = accessibility
            // Its highlight follows the popover however it closes: Escape, a
            // click outside, another popover opening.
            observation = presenter.$isShown.sink { [weak self] shown in MainActor.assumeIsolated { self?.open = shown } }
            if let identifier { setAccessibilityIdentifier(identifier) }
            toolTip = help.isEmpty ? label : help
            onPress = { [weak self] in self?.toggle() }
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        private func toggle() {
            guard let dialog else { return }
            if !presenter.isShown && !presenter.isOpening { willOpen() }
            presenter.toggle(from: self, width: width, maximumHeight: maximumHeight, animates: !Motion.reduced,
                             within: readyWithin, isReady: isReady, view: dialog)
        }
        override func update(glyph: Glyph? = nil, label: String, warningTail: String? = nil, scope: AnyHashable?) {
            super.update(glyph: glyph, label: label, warningTail: warningTail, scope: scope)
            if help.isEmpty { toolTip = label }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // A pill that leaves the screen takes its popover with it.
            if window == nil { presenter.close() }
        }
    }

    // MARK: - Working indicators

    /// A line of text with a slow highlight travelling along it: the
    /// working indicator. The travelling part is one gradient moved by Core
    /// Animation and masked by the glyphs, so nothing is laid out or drawn
    /// per frame. Reduced motion leaves the line still.
    @MainActor final class ShimmerText: NSView {
        static let period: CFTimeInterval = 1.9
        static let band: CGFloat = 0.45
        var text: String { didSet { guard oldValue != text else { return }; invalidateIntrinsicContentSize(); needsLayout = true; setAccessibilityLabel(text) } }
        let size: CGFloat, weight: NSFont.Weight
        /// The width the running sweep was started for.
        private var sweptWidth: CGFloat = -1
        /// The words' ink and the highlight's (the transcript's muted and text inks).
        let ink: NSColor, glow: NSColor
        private let words = DrawingLayer(), mask = DrawingLayer(), gradient = CAGradientLayer()

        init(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .medium,
             ink: NSColor = PiKit.transcriptMuted, glow: NSColor = PiKit.transcriptText) {
            self.text = text; self.size = size; self.weight = weight; self.ink = ink; self.glow = glow
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(words); layer?.addSublayer(gradient)
            words.drawer = { [weak self] rect in self?.line.draw(in: rect, scale: self?.piScale ?? 2) }
            mask.drawer = { [weak self] rect in guard let self else { return }; self.line.draw(in: rect, color: .black, scale: self.piScale) }
            gradient.mask = mask
            gradient.startPoint = CGPoint(x: 0, y: 0.5); gradient.endPoint = CGPoint(x: 1, y: 0.5)
            setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(text)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        private var line: Line { Line(text, font: .systemFont(ofSize: size, weight: weight), color: ink) }
        override var intrinsicContentSize: NSSize { line.size(scale: piScale) }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for layer in [words, mask] as [DrawingLayer] { layer.frame = bounds; layer.contentsScale = piScale; layer.appearance = effectiveAppearance; layer.setNeedsDisplay() }
            gradient.frame = bounds
            mask.frame = bounds
            let width = max(24, bounds.width * Self.band)
            gradient.colors = [NSColor.clear.cgColor, piCGColor(glow.withAlphaComponent(0.9)), NSColor.clear.cgColor]
            // The band: a strip `width` wide, travelling from fully left of the
            // line to fully right of it.
            let span = bounds.width + width
            gradient.locations = [0, NSNumber(value: Double(width / 2 / max(1, bounds.width))), NSNumber(value: Double(width / max(1, bounds.width)))]
            gradient.isHidden = Motion.reduced
            CATransaction.commit()
            animate(span: span, width: width)
        }
        private func animate(span: CGFloat, width: CGFloat) {
            // A sweep already running for this width keeps its phase.
            guard !(isAnimating && sweptWidth == bounds.width) else { return }
            gradient.removeAnimation(forKey: "shimmer")
            guard !Motion.reduced, window != nil, bounds.width > 0 else { return }
            sweptWidth = bounds.width
            let move = CABasicAnimation(keyPath: "locations")
            let w = Double(width / bounds.width)
            move.fromValue = [-w, -w / 2, 0]
            move.toValue = [1, 1 + w / 2, 1 + w]
            _ = span
            move.duration = Self.period; move.repeatCount = .infinity
            gradient.add(move, forKey: "shimmer")
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        /// Whether the highlight is moving, for tests.
        var isAnimating: Bool { gradient.animation(forKey: "shimmer") != nil }
    }

    /// The transcript's own inks (`TranscriptPalette`), for the indicators
    /// that sit in the conversation.
    static let transcriptText = NSColor.piDynamic(light: NSColor(srgbRed: 0x1d / 255, green: 0x1b / 255, blue: 0x17 / 255, alpha: 1),
                                                  dark: NSColor(srgbRed: 0xec / 255, green: 0xea / 255, blue: 0xe4 / 255, alpha: 1))
    static let transcriptMuted = NSColor.piDynamic(light: NSColor(srgbRed: 0x6e / 255, green: 0x6a / 255, blue: 0x61 / 255, alpha: 1),
                                                   dark: NSColor(srgbRed: 0xa9 / 255, green: 0xa5 / 255, blue: 0x9b / 255, alpha: 1))
    static let transcriptHairStrong = NSColor.piDynamic(light: NSColor(white: 0, alpha: 0.14), dark: NSColor(white: 1, alpha: 0.16))
    static let transcriptSurface = NSColor.piDynamic(light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                                                     dark: NSColor(srgbRed: 0x2e / 255, green: 0x29 / 255, blue: 0x25 / 255, alpha: 1))
    static let transcriptAccent = NSColor.piDynamic(light: NSColor(srgbRed: 0x98 / 255, green: 0x47 / 255, blue: 0x09 / 255, alpha: 1),
                                                    dark: NSColor(srgbRed: 0xf0 / 255, green: 0xa0 / 255, blue: 0x52 / 255, alpha: 1))

    /// The floating circle that takes the reader back to the newest message.
    @MainActor final class BackToBottomPill: ButtonBase {
        static let diameter: CGFloat = 34
        init(action: @escaping () -> Void) {
            super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
            pressScales = false
            circularCorners = true
            onPress = action
            toolTip = "Jump to the latest message"
            setAccessibilityLabel("Jump to the latest message")
            setAccessibilityIdentifier("backToBottom")
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var intrinsicContentSize: NSSize { NSSize(width: Self.diameter, height: Self.diameter) }
        override func setHovering(_ value: Bool) { super.setHovering(value); redrawContent() }
        override func styleFace() {
            fill.backgroundColor = piCGColor(PiKit.transcriptSurface)
            fill.shadowColor = NSColor.black.cgColor; fill.shadowOpacity = 0.22
            fill.shadowRadius = PiKit.shadowRadius(12); fill.shadowOffset = CGSize(width: 0, height: 4)
            stroke.borderColor = piCGColor(hovering ? PiKit.transcriptMuted.withAlphaComponent(0.45) : PiKit.transcriptHairStrong)
        }
        override func drawContent(in rect: CGRect) {
            Symbol("arrow.down", size: 13, weight: .bold).draw(centredIn: rect, color: hovering ? PiKit.transcriptAccent : PiKit.transcriptText, scale: piScale)
        }
    }

    // MARK: - Chart selection

    /// The item under the pointer in one chart, held by the chart and told
    /// only to the parts that follow the pointer (a rule, a band, the caption
    /// under the chart): a step within the same item tells nobody.
    @MainActor final class ChartSelection {
        private(set) var index: Int?
        var onChange: ((Int?) -> Void)?
        init() {}
        func select(_ index: Int?) { guard self.index != index else { return }; self.index = index; onChange?(index) }
    }

    // MARK: - Legend

    /// A legend line: its swatch (or a line key), its name with a detail
    /// beside it when there is room and under it when not, the exact figure
    /// and its share. Values stay in ink; the swatch carries identity.
    @MainActor final class LegendRow: NSView, WidthSizing {
        let color: NSColor, title: String, value: String, share: String?, detail: String?, line: Bool
        init(color: NSColor, title: String, value: String, share: String? = nil, detail: String? = nil, line: Bool = false) {
            self.color = color; self.title = title; self.value = value; self.share = share; self.detail = detail; self.line = line
            super.init(frame: .zero)
            setAccessibilityElement(true); setAccessibilityRole(.staticText)
            setAccessibilityLabel([title, detail, value, share].compactMap { $0 }.joined(separator: ", "))
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        private var titleLine: Line { Line(title, font: PiKit.Font.caption, color: .piInk) }
        private var valueLine: Line { Line(value, font: PiKit.Font.monospacedDigits(.systemFont(ofSize: PiKit.Font.captionSize, weight: .medium)), color: .piInk) }
        private var shareLine: Line? { share.map { Line($0, font: PiKit.Font.monospacedDigits(PiKit.Font.micro), color: .piInkTertiary) } }
        private var detailLine: Line? { detail.map { Line($0, font: PiKit.Font.micro, color: .piInkTertiary) } }
        private var trailing: CGFloat { valueLine.size().width + (shareLine != nil ? 7 + 38 : 0) }
        /// Whether the detail fits beside the title at `width`.
        private func inline(_ width: CGFloat) -> Bool {
            guard let detailLine else { return true }
            return 10 + 7 + titleLine.size().width + 7 + detailLine.size().width + PiSpacing.sm + 7 + trailing <= width
        }
        func height(forWidth width: CGFloat) -> CGFloat {
            let base = max(titleLine.size().height, valueLine.size().height)
            guard let detailLine, !inline(width) else { return base }
            let room = width - 17 - PiSpacing.sm - 7 - trailing
            return titleLine.size().height + 1 + PiKit.wrappedHeight(detailLine.text, font: PiKit.Font.micro, width: room)
        }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 300)) }
        override func draw(_ dirtyRect: NSRect) {
            let titleSize = titleLine.size()
            let baseline = titleLine.baseline()
            color.setFill()
            // The swatch's bottom one point below the title's baseline.
            if line { NSBezierPath(roundedRect: CGRect(x: 0, y: baseline + 1 - 2, width: 10, height: 2), xRadius: 1, yRadius: 1).fill() }
            else { NSBezierPath(roundedRect: CGRect(x: 0.5, y: baseline + 1 - 9, width: 9, height: 9), xRadius: 2, yRadius: 2).fill() }
            titleLine.draw(at: CGPoint(x: 17, y: 0), scale: piScale)
            if let detailLine {
                if inline(bounds.width) {
                    detailLine.draw(at: CGPoint(x: 17 + titleSize.width + 7, y: baseline - detailLine.baseline()), scale: piScale)
                } else {
                    PiKit.drawWrapped(detailLine.text, font: PiKit.Font.micro, color: .piInkTertiary,
                                      in: CGRect(x: 17, y: titleSize.height + 1, width: bounds.width - 17 - PiSpacing.sm - 7 - trailing, height: 1_000))
                }
            }
            var x = bounds.width
            if let shareLine {
                let size = shareLine.size()
                shareLine.draw(at: CGPoint(x: x - size.width, y: baseline - shareLine.baseline()), scale: piScale)
                x -= 38 + 7
            }
            let size = valueLine.size()
            valueLine.draw(at: CGPoint(x: x - size.width, y: baseline - valueLine.baseline()), scale: piScale)
        }
    }

    // MARK: - Motion helpers

    /// A chart's first appearance: it grows out of its baseline (or its
    /// leading edge) in one short, eased step, under a mask that reaches 32
    /// points past it so labels hanging outside are never cut.
    @MainActor static func reveal(_ view: NSView, horizontal: Bool, delay: CFTimeInterval = 0) {
        guard !Motion.reduced, let layer = view.layer ?? { view.wantsLayer = true; return view.layer }() else { return }
        let overhang: CGFloat = 32
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        let full = view.bounds.insetBy(dx: -overhang, dy: -overhang)
        mask.anchorPoint = horizontal ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 0.5, y: view.isFlipped ? 1 : 0)
        mask.bounds = CGRect(origin: .zero, size: full.size)
        mask.position = horizontal ? CGPoint(x: full.minX, y: full.midY) : CGPoint(x: full.midX, y: view.isFlipped ? full.maxY : full.minY)
        layer.mask = mask
        let grow = CABasicAnimation(keyPath: horizontal ? "bounds.size.width" : "bounds.size.height")
        grow.fromValue = 0; grow.toValue = horizontal ? full.width : full.height
        grow.duration = Motion.slow; grow.timingFunction = Motion.timing(.easeInOut)
        grow.beginTime = CACurrentMediaTime() + delay; grow.fillMode = .backwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak layer] in layer?.mask = nil }
        mask.add(grow, forKey: "reveal")
        CATransaction.commit()
    }

    /// Brief first-appearance feedback: a fade with four points of movement,
    /// siblings 20 ms apart, capped at 60 ms.
    @MainActor static func appear(_ view: NSView, index: Int) {
        guard !Motion.reduced, let layer = view.layer ?? { view.wantsLayer = true; return view.layer }() else { return }
        let delay = 0.02 * Double(min(3, max(0, index)))
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
        // From four points below: down is positive in a flipped view.
        let rise = CABasicAnimation(keyPath: "transform.translation.y"); rise.fromValue = view.isFlipped ? 4 : -4; rise.toValue = 0
        let group = CAAnimationGroup(); group.animations = [fade, rise]
        group.duration = Motion.quick; group.timingFunction = Motion.timing(.easeOut)
        group.beginTime = CACurrentMediaTime() + delay; group.fillMode = .backwards
        layer.add(group, forKey: "appear")
    }

    /// Something arriving in place: it comes from the edge it is attached to
    /// and fades as it comes.
    @MainActor static func arrive(_ view: NSView, fromTop: Bool = true) {
        guard !Motion.reduced, let layer = view.layer ?? { view.wantsLayer = true; return view.layer }() else { return }
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        // From its edge: above is negative in a flipped view.
        move.fromValue = (fromTop ? -1 : 1) * view.bounds.height * (view.isFlipped ? 1 : -1); move.toValue = 0
        let group = CAAnimationGroup(); group.animations = [fade, move]
        group.duration = Motion.base; group.timingFunction = Motion.timing(.easeOut)
        layer.add(group, forKey: "arrive")
    }
}
