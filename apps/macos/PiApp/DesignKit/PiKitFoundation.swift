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
            if truncation == .middle, !Self.hasRightToLeft(line) {
                // SwiftUI's cut, not Core Text's: drawn as head, "…", tail
                // (right-to-left text keeps Core Text's cut, which orders it).
                guard let cut = middleCut(width: rect.width) else { return }
                var x = rect.minX
                for piece in [cut.head, "…", cut.tail] where !piece.isEmpty {
                    var part = self; part.text = piece; part.uppercased = false
                    part.draw(at: CGPoint(x: x, y: rect.minY), color: color, scale: scale)
                    x += part.width
                }
                return
            }
            // Too narrow for even the ellipsis: nothing is drawn, rather than
            // the whole line running past its room.
            guard let truncated = CTLineCreateTruncatedLine(line, Double(rect.width), truncation,
                                                            CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: coreTextAttributes(color)))) else { return }
            draw(truncated, at: rect.origin, scale: scale)
        }
        /// What a line cut in the middle keeps, as SwiftUI's
        /// `truncationMode(.middle)` keeps it: the head takes as many
        /// characters as fit in half the room the ellipsis leaves, the tail
        /// the rest of that room, and neither keeps a space beside the
        /// ellipsis. Nil when not even the ellipsis fits. Core Text's own cut
        /// favours the head and keeps one character more or fewer than
        /// SwiftUI at about half of all widths; this one matches SwiftUI at
        /// about two in three (`PiKitParityTests.testMiddleTruncation`). The
        /// rest still differ by a character: SwiftUI's own rule is not public.
        func middleCut(width: CGFloat) -> (head: String, tail: String)? {
            let characters = Array(shown)
            var probe = self; probe.uppercased = false
            func measure(_ characters: ArraySlice<Character>) -> CGFloat { probe.text = String(characters); return probe.width }
            let ellipsis = measure(["…"])
            guard ellipsis <= width + 0.001 else { return nil }
            let room = width - ellipsis
            // The most characters, up to `most`, whose width fits `limit`:
            // widths grow with the count, except where shaping joins
            // characters, so a few counts past the search are tried too.
            func fitting(_ most: Int, _ limit: CGFloat, _ slice: (Int) -> ArraySlice<Character>) -> Int {
                var low = 0, high = most
                while low < high { let mid = (low + high + 1) / 2; if measure(slice(mid)) <= limit + 0.001 { low = mid } else { high = mid - 1 } }
                for count in stride(from: min(most, low + 8), to: low, by: -1) where measure(slice(count)) <= limit + 0.001 { return count }
                return low
            }
            var head = fitting(characters.count, room / 2) { characters[0..<$0] }
            while head > 0, characters[head - 1].isWhitespace { head -= 1 }
            let left = room - measure(characters[0..<head])
            var tail = fitting(characters.count - head, left) { characters[(characters.count - $0)...] }
            while tail > 0, characters[characters.count - tail].isWhitespace { tail -= 1 }
            return (String(characters[0..<head]), String(characters[(characters.count - tail)...]))
        }
        /// Whether any of the line runs right to left.
        private static func hasRightToLeft(_ line: CTLine) -> Bool {
            (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).contains { CTRunGetStatus($0).contains(.rightToLeft) }
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
        /// How far above the image's centre SwiftUI draws the glyph when it
        /// centres a symbol in a taller frame (an icon button, a checkbox). An
        /// `NSImage` symbol is rounded up to whole points and its glyph set on
        /// the pixel grid; SwiftUI centres its own unrounded box and draws the
        /// glyph at its exact place, between 0.02 and 0.48 points higher (0.29
        /// on average over 16 symbols at icon-button sizes 20 to 28). A
        /// quarter point puts every one within a quarter point of SwiftUI's.
        /// A symbol drawn in its own box (`SymbolView` at `layoutSize`) sits
        /// where SwiftUI puts it already.
        static let lift: CGFloat = 0.25
        /// Draws the symbol centred in `rect` as SwiftUI centres it: its
        /// layout box on the pixel grid, the image's leading edge on the box's.
        func draw(centredIn rect: CGRect, color: NSColor, scale: CGFloat = 2) {
            guard let image = image(color) else { return }
            let drawn = image.size, box = layoutSize
            let x = PiKit.roundUpHalf(rect.midX - box.width / 2, scale)
            let y = rect.midY - drawn.height / 2 - (rect.height > drawn.height ? Self.lift : 0)
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

/// A page that hands down the window's reduced motion (`piReduceMotion`).
@MainActor protocol InheritsReducedMotion: AnyObject { var inheritedReduceMotion: Bool { get } }
extension NSView {
    /// Whether motion is reduced here: the system's, or the window's as the
    /// enclosing page hands it down.
    var piReducesMotion: Bool {
        if PiKit.Motion.reduced { return true }
        var view: NSView? = self
        while let current = view {
            if let page = current as? InheritsReducedMotion, page.inheritedReduceMotion { return true }
            view = current.superview
        }
        return false
    }
}
