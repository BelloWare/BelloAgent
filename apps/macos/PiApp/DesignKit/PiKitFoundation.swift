import AppKit
import QuartzCore

// What every AppKit Pi component is built from: the motion policy, one line
// of text measured and drawn as SwiftUI's `Text` draws it, a symbol drawn as
// `Image(systemName:)` draws it, and shapes on layers.

extension PiKit {
    /// Motion tokens: three eased durations for state changes and two springs
    /// for things that move. App-owned motion stays on whatever macOS's Reduce
    /// Motion says (the owner's policy since 0.1.67); a fixture can still turn
    /// it off.
    @MainActor enum Motion {
        nonisolated static let reducesMotion = false
        nonisolated static let quickMilliseconds = 140
        nonisolated static let baseMilliseconds = 220
        nonisolated static let slowMilliseconds = 320
        static var quick: CFTimeInterval { Double(quickMilliseconds) / 1_000 }
        static var base: CFTimeInterval { Double(baseMilliseconds) / 1_000 }
        static var slow: CFTimeInterval { Double(slowMilliseconds) / 1_000 }
        /// A test seam: true stills every Pi component's motion.
        static var reducedOverride: Bool?
        static var reduced: Bool { reducedOverride ?? reducesMotion }

        enum Curve { case easeOut, easeInOut }
        static func timing(_ curve: Curve) -> CAMediaTimingFunction {
            CAMediaTimingFunction(name: curve == .easeOut ? .easeOut : .easeInEaseOut)
        }

        /// Runs `changes` to layer properties as one eased transition of
        /// `duration`, or at once when motion is reduced or `animated` is false.
        static func layers(_ duration: CFTimeInterval, _ curve: Curve = .easeOut, animated: Bool = true, _ changes: () -> Void) {
            CATransaction.begin()
            if reduced || !animated {
                CATransaction.setDisableActions(true)
            } else {
                CATransaction.setAnimationDuration(duration)
                CATransaction.setAnimationTimingFunction(timing(curve))
            }
            changes()
            CATransaction.commit()
        }

        /// SwiftUI's `spring(response:dampingFraction:)` as a Core Animation
        /// spring on `keyPath`.
        static func spring(_ keyPath: String, response: Double, damping: Double) -> CASpringAnimation {
            let animation = CASpringAnimation(keyPath: keyPath)
            animation.mass = 1
            animation.stiffness = pow(2 * .pi / response, 2)
            animation.damping = 4 * .pi * damping / response
            animation.duration = animation.settlingDuration
            return animation
        }
        /// A short spring with a small overshoot, for things that pop in.
        static func pop(_ keyPath: String) -> CASpringAnimation { spring(keyPath, response: 0.34, damping: 0.78) }
        /// A tighter spring for things that slide: a selection highlight, a panel.
        static func glide(_ keyPath: String) -> CASpringAnimation { spring(keyPath, response: 0.3, damping: 0.88) }
    }

    /// One line of text in one font and color, measured and drawn as
    /// SwiftUI's `Text` lays it out: its width rounded up to the pixel, its
    /// height the font's line height rounded up to the pixel, the glyphs on
    /// the font's ascender from the top.
    struct Line {
        var text: String
        var font: NSFont
        var color: NSColor
        /// Tracking, in points, as `.tracking(_:)`.
        var tracking: CGFloat = 0
        var uppercased = false

        init(_ text: String, font: NSFont, color: NSColor, tracking: CGFloat = 0, uppercased: Bool = false) {
            self.text = text; self.font = font; self.color = color; self.tracking = tracking; self.uppercased = uppercased
        }

        var shown: String { uppercased ? text.uppercased() : text }
        func attributes(_ color: NSColor? = nil) -> [NSAttributedString.Key: Any] {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color ?? self.color]
            if tracking != 0 { attributes[.kern] = tracking }
            return attributes
        }
        var attributed: NSAttributedString { NSAttributedString(string: shown, attributes: attributes()) }
        /// The typographic width, unrounded.
        var width: CGFloat {
            guard !text.isEmpty else { return 0 }
            return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
        }
        /// The line's height as AppKit and SwiftUI both lay it out (the
        /// font's ascender and descender rounded as the text system does).
        var lineHeight: CGFloat { Self.metrics(font).height }
        /// The size `Text` takes at `scale` pixels per point: its typographic
        /// width rounded up to the pixel and the text system's line height.
        func size(scale: CGFloat = 2) -> CGSize {
            CGSize(width: PiKit.ceil(width, scale), height: lineHeight)
        }
        /// Where `Text` puts the baseline below the top of its line: the text
        /// system's whole-point baseline for the font.
        func baseline(scale: CGFloat = 2) -> CGFloat { Self.metrics(font).baseline }
        /// Draws the line with its top-left at `origin` in a flipped context,
        /// its baseline where `Text` puts it. Core Text draws it: AppKit's
        /// string drawing, in a layer of a flipped view, sets it half a point low.
        func draw(at origin: CGPoint, color: NSColor? = nil, scale: CGFloat = 2) {
            guard !text.isEmpty else { return }
            draw(CTLineCreateWithAttributedString(coreText(color)), at: origin, scale: scale)
        }
        /// Draws the line in `rect` (flipped), cut with "…" at the end (or
        /// the middle) when it is wider.
        func draw(in rect: CGRect, color: NSColor? = nil, truncation: CTLineTruncationType = .end, scale: CGFloat = 2) {
            guard !text.isEmpty else { return }
            let line = CTLineCreateWithAttributedString(coreText(color))
            guard CTLineGetTypographicBounds(line, nil, nil, nil) > rect.width + 0.01 else { draw(line, at: rect.origin, scale: scale); return }
            // Too narrow for even the ellipsis: nothing is drawn, rather than
            // the whole line running past its room.
            guard let truncated = CTLineCreateTruncatedLine(line, Double(rect.width), truncation,
                                                            CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: coreTextAttributes(color)))) else { return }
            draw(truncated, at: rect.origin, scale: scale)
        }
        private func draw(_ line: CTLine, at origin: CGPoint, scale: CGFloat) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: origin.x, y: origin.y + baseline(scale: scale))
            CTLineDraw(line, context)
            context.restoreGState()
        }
        private func coreTextAttributes(_ color: NSColor?) -> [NSAttributedString.Key: Any] {
            var attributes = attributes(color)
            attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = (color ?? self.color).cgColor
            return attributes
        }
        private func coreText(_ color: NSColor?) -> NSAttributedString { NSAttributedString(string: shown, attributes: coreTextAttributes(color)) }
        private struct Metrics { let height: CGFloat; let baseline: CGFloat }
        private static let lock = NSLock()
        nonisolated(unsafe) private static var known: [NSFont: Metrics] = [:]
        private static func metrics(_ font: NSFont) -> Metrics {
            lock.lock(); defer { lock.unlock() }
            if let metrics = known[font] { return metrics }
            // Shrunk figures make fonts at every size; the table stays bounded.
            if known.count >= 256 { known.removeAll(keepingCapacity: true) }
            let metrics = Metrics(height: ("Ag" as NSString).size(withAttributes: [.font: font]).height,
                                  baseline: NSLayoutManager().defaultBaselineOffset(for: font))
            known[font] = metrics
            return metrics
        }
    }

    /// An SF Symbol at a point size and weight, as
    /// `Image(systemName:).font(.system(size:weight:))` draws it.
    struct Symbol {
        var name: String
        var size: CGFloat
        var weight: NSFont.Weight
        init(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) { self.name = name; self.size = size; self.weight = weight }
        /// The symbol in one color, as `.foregroundStyle(color)` draws it:
        /// monochrome, with its cut-outs left clear.
        func image(_ color: NSColor) -> NSImage? {
            guard let base else { return nil }
            return NSImage(size: base.size, flipped: false) { rect in
                base.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
        }
        private var base: NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
        }
        /// The image AppKit draws: its size rounded up to whole points.
        var imageSize: CGSize { base?.size ?? CGSize(width: size, height: size) }
        /// The room `Image(systemName:)` takes in a SwiftUI layout: the
        /// symbol's alignment width, and its height trimmed by the same
        /// amount (SwiftUI does not round the symbol up to whole points).
        var layoutSize: CGSize {
            guard let base else { return CGSize(width: size, height: size) }
            let trim = base.size.width - base.alignmentRect.width
            return CGSize(width: base.size.width - trim, height: base.size.height - trim)
        }
        /// Draws the symbol centred in `rect` as SwiftUI centres it: its
        /// layout box on the pixel grid, the image's leading edge on the box's.
        func draw(centredIn rect: CGRect, color: NSColor, scale: CGFloat = 2) {
            guard let image = image(color) else { return }
            let drawn = image.size, box = layoutSize
            let x = PiKit.roundUpHalf(rect.midX - box.width / 2, scale)
            let y = rect.midY - drawn.height / 2
            image.draw(in: CGRect(x: x, y: y, width: drawn.width, height: drawn.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// `value` rounded up to the next pixel at `scale`.
    static func ceil(_ value: CGFloat, _ scale: CGFloat) -> CGFloat { (value * scale).rounded(.up) / scale }
    /// `value` rounded to the nearest pixel at `scale`, halves up.
    static func roundUpHalf(_ value: CGFloat, _ scale: CGFloat) -> CGFloat { (value * scale + 0.5).rounded(.down) / scale }
    /// `value` rounded to the nearest pixel at `scale`.
    static func round(_ value: CGFloat, _ scale: CGFloat) -> CGFloat { (value * scale).rounded() / scale }

    /// A layer that draws with a closure, in a flipped AppKit graphics
    /// context, at its window's scale and appearance.
    final class DrawingLayer: CALayer {
        var drawer: ((CGRect) -> Void)?
        var appearance: NSAppearance?
        override init() { super.init(); needsDisplayOnBoundsChange = true; isGeometryFlipped = false }
        override init(layer: Any) { super.init(layer: layer) }
        required init?(coder: NSCoder) { super.init(coder: coder) }
        override func draw(in context: CGContext) {
            guard let drawer else { return }
            NSGraphicsContext.saveGraphicsState()
            let graphics = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.current = graphics
            // A layer inside a flipped view's tree draws flipped already.
            if !contentsAreFlipped() { context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1) }
            let draw = { drawer(self.bounds) }
            if let appearance { appearance.performAsCurrentDrawingAppearance(draw) } else { draw() }
            NSGraphicsContext.restoreGraphicsState()
        }
        // Drawing changes only when asked; moving or fading it does not redraw.
        override func action(forKey event: String) -> CAAction? { event == "contents" ? NSNull() : super.action(forKey: event) }
    }
}

extension NSView {
    /// Pixels per point where the view is shown, 2 before it has a window.
    var piScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    /// Resolves `color` in this view's appearance, for a layer property.
    func piCGColor(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }
}
