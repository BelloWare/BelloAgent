import SwiftUI
import AppKit

// What the reader sees while a turn is running, and how they get back to it:
// the shimmering line that says the app is working, and the floating circle
// that brings them back to the newest message. Both are pure paint — a
// gradient's offset and an opacity — so neither decides any layout and
// neither costs the conversation a thing per frame.

/// A line of text with a slow highlight travelling along it. It is the
/// working indicator: no spinner, no progress, just the words moving, which
/// is what says the run is alive without claiming to know how far it has got.
///
/// The travelling part is one offset on a gradient masked by the glyphs. The
/// words themselves never change, so a tick moves a mask and decides no
/// layout: the conversation above is not touched, and neither is the bar's
/// own height. Reduce Motion leaves the line still, and the words still say
/// what the run is doing.
struct PiShimmerText: View {
    let text: String
    var size: CGFloat = 12
    var weight: Font.Weight = .medium
    /// How long the highlight takes to cross the line once.
    static let period: Double = 1.9
    /// How wide the highlight is, as a fraction of the line.
    static let band: CGFloat = 0.45
    @Environment(\.piReduceMotion) private var reduceMotion

    private var label: Text { Text(text).font(.system(size: size, weight: weight)) }

    var body: some View {
        label
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(TranscriptPalette.muted)
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        let width = max(24, proxy.size.width * Self.band)
                        // The same clock the rest of the design system's
                        // indicators run on, so the highlight advances in a
                        // detached row host and in a menu-bar popover too.
                        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                            let phase = context.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: Self.period) / Self.period
                            LinearGradient(colors: [.clear, TranscriptPalette.text.opacity(0.9), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: width)
                                .offset(x: -width + (proxy.size.width + width) * phase)
                        }
                    }
                    .mask(label.lineLimit(1).truncationMode(.tail))
                    .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(text)
    }
}

/// A small ring turning while something runs, for places that sit in a lazy
/// list such as the sidebar. It is not a `ProgressView`: that is an AppKit
/// progress indicator, a hosted view that invalidates its own size when
/// SwiftUI updates it, and inside a lazy list every such invalidation is
/// another layout pass that updates the list's items again (see PiMenu.swift).
/// The ring is a shape layer turned by Core Animation, so it costs the main
/// thread nothing per frame, and it never changes its size. Reduce Motion
/// leaves it still.
struct PiSpinner: NSViewRepresentable {
    var size: CGFloat = 12
    var lineWidth: CGFloat = 1.6
    func makeNSView(context: Context) -> PiSpinnerView {
        let view = PiSpinnerView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.configure(lineWidth: lineWidth, turning: !context.environment.piReduceMotion)
        return view
    }
    func updateNSView(_ view: PiSpinnerView, context: Context) {
        view.configure(lineWidth: lineWidth, turning: !context.environment.piReduceMotion)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PiSpinnerView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

@MainActor final class PiSpinnerView: NSView {
    /// One turn of the ring, in seconds.
    static let period: CFTimeInterval = 0.9
    private let ring = CAShapeLayer()
    private var lineWidth: CGFloat = 1.6
    private(set) var turning = true

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
            ring.strokeColor = NSColor(Color.piInkSecondary).cgColor
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

/// The floating circle above the composer that takes the reader back to the
/// newest message. It is shown whenever they are not standing at the bottom,
/// whatever took them away from it — a wheel, a page key, a restored position,
/// a jump they abandoned.
struct PiBackToBottomPill: View {
    /// How big the circle is.
    static let diameter: CGFloat = 34
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            // A circle floating over the conversation has to read as an
            // object in both appearances. The surface alone is a shade away
            // from the canvas in the dark one, so the edge and the shadow are
            // what hold it off the page, and the arrow carries full weight.
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(hovering ? TranscriptPalette.accent : TranscriptPalette.text)
                .frame(width: Self.diameter, height: Self.diameter)
                .background(TranscriptPalette.surface, in: Circle())
                .overlay(Circle().stroke(hovering ? TranscriptPalette.muted.opacity(0.45) : TranscriptPalette.hairStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain).piPointer()
        .onHover { hovering = $0 }
        .help("Jump to the latest message")
        .accessibilityLabel("Jump to the latest message")
        .accessibilityIdentifier("backToBottom")
    }
}
