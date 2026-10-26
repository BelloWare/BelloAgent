import AppKit


/// A compact preview card that appears after the pointer has rested on a
/// control for a moment and goes away the moment it leaves: a richer tooltip.
///
/// It lives in its own borderless panel over the window, so it can overhang
/// the edge of whatever it describes, but the panel never becomes key or main
/// and ignores the mouse: it takes no focus and never stands between the
/// pointer and the control. A press, a scroll or a key anywhere hides it, and
/// at most one card is up at a time.
///
/// An `interactive` card (opt-in) takes the pointer instead, so a button on
/// it can be pressed: moving from the control onto the card keeps it up, and
/// it goes once the pointer has been off both for `leaveGrace`, or at a
/// press elsewhere, a scroll or a key. It still never takes focus.
@MainActor final class PiHoverCardPresenter {
    /// How long the pointer rests on a control before its card appears.
    nonisolated static let delay: Duration = .milliseconds(450)
    /// The card's shadow needs room inside its panel.
    nonisolated static let shadowMargin: CGFloat = 14
    /// Between the control and the card.
    nonisolated static let gap: CGFloat = 6
    private static weak var current: PiHoverCardPresenter?

    private(set) var panel: PiHoverCardPanel?
    private weak var anchor: NSView?
    private var pending: Task<Void, Never>?
    private var monitor: Any?
    private var resignation: NSObjectProtocol?
    /// Test seam: how long the pointer must rest.
    var delay = PiHoverCardPresenter.delay
    /// The app's motion policy for the next card: it fades in unless reduced.
    var reducesMotion = PiKit.Motion.reduced
    /// The card takes the pointer (see above). Off for every card but those
    /// that offer an action.
    var interactive = false
    /// How long an interactive card waits for the pointer to come back
    /// before it goes.
    var leaveGrace: Duration = .milliseconds(300)
    /// Above or below the control, or beside its trailing edge: what a
    /// pointer reaches without crossing the controls above or below.
    var placement: Placement = .vertical
    enum Placement: Sendable { case vertical, trailing }
    private var leaving: Task<Void, Never>?
    private var tracker: CardTracker?
    /// Test seam: where the pointer is, in screen space.
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }

    var isShown: Bool { panel?.isVisible == true }
    var isWaiting: Bool { pending != nil }
    /// The control the card is showing for, or waiting to show for.
    var anchorView: NSView? { anchor }

    /// A native card opens after the pointer rests and closes on leaving.
    func hover(_ inside: Bool, over anchor: NSView, width: CGFloat, view: @escaping @MainActor () -> NSView) {
        if inside {
            if self.anchor === anchor, isShown || pending != nil { leaving?.cancel(); leaving = nil; return }
            hide()
            self.anchor = anchor
            let delay = delay
            pending = Task { [weak self, weak anchor] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.pending = nil
                guard let anchor, anchor.window != nil, !anchor.isHiddenOrHasHiddenAncestor else { self.anchor = nil; return }
                self.show(over: anchor, width: width, view: view())
            }
        } else if self.anchor === anchor {
            if interactive, isShown { leave() } else { hide() }
        }
    }

    /// The card shown for `anchor`, built again from `view` at once: what it
    /// says changed while it was up.
    func refresh(over anchor: NSView, width: CGFloat, view: () -> NSView) {
        guard self.anchor === anchor, isShown else { return }
        // A card on its way out stays on its way out: the pointer has left it
        // and the control, and no exit comes from a card it is not on.
        let wasLeaving = leaving != nil
        hide()
        self.anchor = anchor
        show(over: anchor, width: width, view: view(), fades: false)
        if wasLeaving { leave() }
    }

    /// The pointer left the control or the card: the card goes unless the
    /// pointer is back on one of them by the end of the grace.
    private func leave() {
        leaving?.cancel()
        let grace = leaveGrace
        leaving = Task { [weak self] in
            do { try await Task.sleep(for: grace) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.leaving = nil
            if !self.pointerIsOver { self.hide() }
        }
    }
    /// Whether the pointer is on the control or on the card itself (not its shadow).
    private var pointerIsOver: Bool {
        let point = pointerLocation()
        if let panel, panel.frame.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin).contains(point) { return true }
        guard let anchor, let window = anchor.window else { return false }
        return window.convertToScreen(anchor.convert(anchor.bounds, to: nil)).contains(point)
    }

    func hide() {
        pending?.cancel(); pending = nil
        leaving?.cancel(); leaving = nil
        tracker = nil
        anchor = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let resignation { NotificationCenter.default.removeObserver(resignation); self.resignation = nil }
        guard let panel else { return }
        self.panel = nil
        if Self.current === self { Self.current = nil }
        if let host = panel.contentView { for area in host.trackingAreas { host.removeTrackingArea(area) } }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        // A press on the card's own button can hide it: the panel outlives
        // the event it is handling.
        DispatchQueue.main.async { withExtendedLifetime(panel) {} }
    }

    /// Above the control when its window has the room there, else below it
    /// when the window has the room there, else whichever side the screen
    /// allows; its leading edge on the control's, kept on the screen.
    /// Rectangles are in AppKit's bottom-left screen space; `size` includes
    /// the shadow margin, which may overhang.
    nonisolated static func frame(size: CGSize, anchor: CGRect, window: CGRect, visible: CGRect) -> CGRect {
        let margin = shadowMargin
        let above = anchor.maxY + gap - margin
        let below = anchor.minY - gap + margin - size.height
        let fitsAbove = { (bounds: CGRect) in above + size.height - margin <= bounds.maxY }
        let fitsBelow = { (bounds: CGRect) in below + margin >= bounds.minY }
        let y: CGFloat
        if fitsAbove(window) { y = above }
        else if fitsBelow(window) { y = below }
        else { y = fitsAbove(visible) || !fitsBelow(visible) ? above : below }
        let x = min(max(anchor.minX - margin, visible.minX), visible.maxX - size.width)
        return CGRect(x: x.rounded(), y: min(max(y, visible.minY), visible.maxY - size.height).rounded(), width: size.width, height: size.height)
    }
    /// Beside the control's trailing edge with its top level with the
    /// control's, or before its leading edge when the screen has no room
    /// after it; kept on the screen.
    nonisolated static func trailingFrame(size: CGSize, anchor: CGRect, visible: CGRect) -> CGRect {
        let margin = shadowMargin
        var x = anchor.maxX + gap - margin
        if x + size.width - margin > visible.maxX { x = anchor.minX - gap + margin - size.width }
        let y = anchor.maxY + margin - size.height
        return CGRect(x: min(max(x, visible.minX), visible.maxX - size.width).rounded(),
                      y: min(max(y, visible.minY), visible.maxY - size.height).rounded(), width: size.width, height: size.height)
    }

    private func show(over anchor: NSView, width: CGFloat, view: NSView, fades: Bool = true) {
        let card = PiKit.Box(fill: .piSurface, stroke: .piHairlineStrong, cornerRadius: PiRadius.md, content: view)
        card.shadowColor = .piShadow; card.shadowRadius = 10; card.shadowOffsetY = 3
        let height = PiKit.height(of: view, width: width)
        card.frame = NSRect(x: Self.shadowMargin, y: Self.shadowMargin, width: width, height: height)
        let host = PiKit.Box.ClipView(frame: NSRect(x: 0, y: 0, width: width + Self.shadowMargin * 2, height: height + Self.shadowMargin * 2))
        host.addSubview(card)
        host.setAccessibilityElement(false)
        present(over: anchor, host: host, fades: fades)
    }

    private func present(over anchor: NSView, host: NSView, fades: Bool) {
        guard let window = anchor.window else { return }
        if let current = Self.current, current !== self { current.hide() }
        host.appearance = anchor.effectiveAppearance
        let size = host.frame.size
        let onScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? onScreen.insetBy(dx: -2_000, dy: -2_000)
        let frame = placement == .trailing ? Self.trailingFrame(size: size, anchor: onScreen, visible: visible)
            : Self.frame(size: size, anchor: onScreen, window: window.frame, visible: visible)
        let panel = PiHoverCardPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = !interactive
        if interactive {
            // The pointer on the card keeps it up; off it, the grace begins.
            let tracker = CardTracker { [weak self] inside in
                guard let self else { return }
                if inside { self.leaving?.cancel(); self.leaving = nil } else { self.leave() }
            }
            host.addTrackingArea(NSTrackingArea(rect: host.bounds.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin),
                                                options: [.mouseEnteredAndExited, .activeInActiveApp], owner: tracker))
            self.tracker = tracker
        }
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.appearance = anchor.effectiveAppearance
        panel.contentView = host
        panel.setAccessibilityElement(false)
        let reduce = reducesMotion || !fades
        panel.alphaValue = reduce ? 1 : 0
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        if !reduce {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Double(PiKit.Motion.quickMilliseconds) / 1_000
                panel.animator().alphaValue = 1
            }
        }
        self.panel = panel; Self.current = self
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A press on an interactive card is the card's own.
                if self.interactive, let panel = self.panel, event.window === panel,
                   [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) { return }
                self.hide()
            }
            return event
        }
        // Switching to another app takes the card away; it would otherwise
        // stay over a window that is no longer being pointed at.
        resignation = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }
}

/// The card's panel: never key, never main, never in the window cycle.
final class PiHoverCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Whether the pointer is on an interactive card: the owner of its tracking area.
@MainActor private final class CardTracker: NSResponder {
    private let changed: (Bool) -> Void
    init(_ changed: @escaping (Bool) -> Void) { self.changed = changed; super.init() }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override func mouseEntered(with event: NSEvent) { changed(true) }
    override func mouseExited(with event: NSEvent) { changed(false) }
}
