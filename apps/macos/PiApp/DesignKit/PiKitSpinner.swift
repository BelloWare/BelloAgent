import AppKit
import QuartzCore

/// A small ring turning while something runs: a shape layer turned by Core
/// Animation, so it costs the main thread nothing per frame and never changes
/// its size. Reduced motion leaves it still.
@MainActor final class PiSpinnerView: NSView {
    /// One turn of the ring, in seconds.
    static let period: CFTimeInterval = 0.9
    private let ring = CAShapeLayer()
    private var lineWidth: CGFloat = 1.6
    private(set) var turning = true
    /// Its size in a layout: the control size's ring, never stretched.
    var fixedSize: CGSize? { didSet { invalidateIntrinsicContentSize() } }
    override var intrinsicContentSize: NSSize { fixedSize ?? NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ring.fillColor = nil; ring.lineCap = .round
        ring.strokeStart = 0.1; ring.strokeEnd = 0.78
        layer?.addSublayer(ring)
        setAccessibilityElement(true); setAccessibilityRole(.progressIndicator); setAccessibilityLabel("In progress")
    }
    required init?(coder: NSCoder) { return nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(lineWidth: CGFloat, turning: Bool) {
        guard lineWidth != self.lineWidth || turning != self.turning else { return }
        self.lineWidth = lineWidth; self.turning = turning
        shape(); animate()
    }
    override func layout() { super.layout(); shape() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); animate() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }

    private func shape() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.lineWidth = lineWidth
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), transform: nil)
        CATransaction.commit()
        paint()
    }
    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.strokeColor = NSColor.piInkSecondary.cgColor
        }
    }
    /// Spinning is the layer's own animation: added once while the view is
    /// in a window, removed when motion is reduced.
    private func animate() {
        guard turning, window != nil else { ring.removeAnimation(forKey: "turn"); return }
        guard ring.animation(forKey: "turn") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0; turn.toValue = 2 * Double.pi
        turn.duration = Self.period; turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        ring.add(turn, forKey: "turn")
    }
    /// Whether the ring is turning now, for tests.
    var isAnimating: Bool { ring.animation(forKey: "turn") != nil }
}

