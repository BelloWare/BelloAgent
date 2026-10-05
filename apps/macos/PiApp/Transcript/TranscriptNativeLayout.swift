import AppKit

// How the native rows share out a line's width the way SwiftUI's stacks did,
// so a row ported from an `HStack` puts every piece where it stood.

/// One piece of a horizontal line: how narrow and how wide it can be, and the
/// size it takes when offered a width.
struct TranscriptLinePiece {
    /// The narrowest and widest it can be; a spacer or a rule has no widest.
    var minWidth: CGFloat
    var maxWidth: CGFloat
    var size: (CGFloat) -> CGSize
    /// A `Spacer`: it takes its least while the others share the line, and
    /// what they leave.
    var isSpacer = false
    /// A piece that is always this size.
    static func fixed(_ size: CGSize) -> TranscriptLinePiece {
        TranscriptLinePiece(minWidth: size.width, maxWidth: size.width, size: { _ in size })
    }
    /// A piece that takes whatever it is offered, at least `minWidth`: a
    /// `Spacer`, or a rule drawn across the room it is given.
    static func flexible(minWidth: CGFloat = 0, height: CGFloat = 0) -> TranscriptLinePiece {
        TranscriptLinePiece(minWidth: minWidth, maxWidth: .infinity, size: { CGSize(width: max(minWidth, $0), height: height) })
    }
    /// SwiftUI's `Spacer(minLength:)`.
    static func spacer(minLength: CGFloat = 0) -> TranscriptLinePiece {
        TranscriptLinePiece(minWidth: minLength, maxWidth: .infinity, size: { CGSize(width: max(minLength, $0), height: 0) }, isSpacer: true)
    }
    /// Text that wraps or truncates: as wide as its one line at most, and the
    /// height `height(width)` gives at the width it takes.
    /// Text that wraps or truncates: as wide as its one line at most, and as
    /// wide as its widest line (`used`) and as tall as `height` gives at the
    /// width it is offered.
    static func text(ideal: CGFloat, used: @escaping (CGFloat) -> CGFloat, height: @escaping (CGFloat) -> CGFloat) -> TranscriptLinePiece {
        TranscriptLinePiece(minWidth: 0, maxWidth: ideal, size: { offered in
            let width = min(ideal, max(0, offered))
            return CGSize(width: width >= ideal ? ideal : used(width), height: height(width))
        })
    }
}

enum TranscriptLineLayout {
    /// The sizes SwiftUI's `HStack` gives `pieces` in `width`, with `spacing`
    /// between neighbours: the least flexible piece is offered its share of
    /// what is left first, and the most flexible takes what remains.
    static func sizes(_ pieces: [TranscriptLinePiece], spacing: [CGFloat], width: CGFloat) -> [CGSize] {
        var remaining = width - spacing.reduce(0, +)
        var sizes = [CGSize](repeating: .zero, count: pieces.count)
        // Spacers last: the views share the line first.
        let order = pieces.indices.sorted { a, b in
            if pieces[a].isSpacer != pieces[b].isSpacer { return !pieces[a].isSpacer }
            let fa = pieces[a].maxWidth - pieces[a].minWidth, fb = pieces[b].maxWidth - pieces[b].minWidth
            return fa == fb ? a < b : fa < fb
        }
        // Every piece is first counted at its narrowest, as SwiftUI does.
        remaining -= pieces.reduce(0) { $0 + $1.minWidth }
        var left = pieces.filter { !$0.isSpacer }.count
        var spacersLeft = pieces.count - left
        for index in order {
            if pieces[index].isSpacer, left == 0 { left = spacersLeft; spacersLeft = 0 }
            let piece = pieces[index]
            remaining += piece.minWidth
            let offer = max(0, remaining / CGFloat(left))
            let size = piece.size(max(piece.minWidth, offer))
            sizes[index] = size
            remaining -= size.width
            left -= 1
        }
        return sizes
    }
    /// Frames for `sizes` along a line from `x`, `spacing` apart, each centred
    /// on the line's middle `midY`.
    static func frames(_ sizes: [CGSize], spacing: [CGFloat], x: CGFloat, midY: CGFloat) -> [CGRect] {
        var x = x
        var frames: [CGRect] = []
        for (index, size) in sizes.enumerated() {
            frames.append(CGRect(x: x, y: midY - size.height / 2, width: size.width, height: size.height))
            x += size.width + (index < spacing.count ? spacing[index] : 0)
        }
        return frames
    }
}

/// One child of a vertical stack: the least and most it can be tall, and the
/// height it takes when offered one.
struct TranscriptStackPiece {
    var minHeight: CGFloat
    var idealHeight: CGFloat
    var height: (CGFloat) -> CGFloat
    static func fixed(_ height: CGFloat) -> TranscriptStackPiece { TranscriptStackPiece(minHeight: height, idealHeight: height, height: { _ in height }) }
}

enum TranscriptStackLayout {
    /// The heights SwiftUI's `VStack` places its children at once it is as
    /// tall as their ideal heights together: the least flexible child is
    /// offered its share first, as across a line. A text that is offered
    /// less than all its lines keeps fewer — SwiftUI's own placement gives a
    /// wrapping header less than it measured when a more flexible child
    /// follows it — and what is left over stays below the last child.
    static func heights(_ pieces: [TranscriptStackPiece]) -> [CGFloat] {
        // Unlike a line, the stack shares out the whole height: nothing is
        // first set aside for each child's least (measured: a header that
        // wraps is squeezed beside a two-line accounting, not a three-line one).
        var remaining = pieces.reduce(0) { $0 + $1.idealHeight }
        var heights = [CGFloat](repeating: 0, count: pieces.count)
        let order = pieces.indices.sorted { a, b in
            let fa = pieces[a].idealHeight - pieces[a].minHeight, fb = pieces[b].idealHeight - pieces[b].minHeight
            return fa == fb ? a < b : fa < fb
        }
        var left = pieces.count
        for index in order {
            let piece = pieces[index]
            let offer = max(piece.minHeight, remaining / CGFloat(left))
            let height = offer >= piece.idealHeight ? piece.idealHeight : piece.height(offer)
            heights[index] = height
            remaining -= height
            left -= 1
        }
        return heights
    }
}

/// A dashed rule across the room it is given, as `DashedLine` drew it: a one
/// point line of four on and four off, from its leading edge.
@MainActor final class TranscriptDashedLine: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 0, y: 0.5)); path.line(to: CGPoint(x: bounds.width, y: 0.5))
        path.lineWidth = 1
        path.setLineDash([4, 4], count: 2, phase: 0)
        TranscriptNSPalette.hairStrong.setStroke()
        path.stroke()
    }
}

/// A small ring that turns while something is under way, as `SpinnerView`
/// drew it. The turning is the render server's: nothing on the main thread
/// runs for it.
@MainActor final class TranscriptSpinner: NSView {
    static let size: CGFloat = 11
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let turn = CALayer()
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(turn)
        for (shape, from, to) in [(track, 0.2, 1.0), (arc, 0.0, 0.22)] {
            shape.fillColor = nil; shape.lineWidth = 1.5; shape.lineCap = .round
            shape.strokeStart = from; shape.strokeEnd = to
            turn.addSublayer(shape)
        }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateLayer() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        turn.frame = bounds
        // A circle from three o'clock, clockwise on screen, as SwiftUI trims one.
        let path = CGMutablePath()
        // The view's layers are flipped: rising angles turn clockwise on screen.
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 2, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = TranscriptNSPalette.hairStrong.cgColor
            arc.strokeColor = TranscriptNSPalette.accent.cgColor
        }
        for shape in [track, arc] { shape.frame = bounds; shape.path = path }
        CATransaction.commit()
        startTurning()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }
    private func startTurning() {
        guard !PiMotion.reducesMotion, window != nil, turn.animation(forKey: "turn") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        // Clockwise on screen, a turn every 0.8 s.
        spin.fromValue = 0; spin.toValue = Double.pi * 2
        spin.duration = 0.8; spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        turn.add(spin, forKey: "turn")
    }
}
