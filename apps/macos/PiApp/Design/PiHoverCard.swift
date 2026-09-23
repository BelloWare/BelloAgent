import AppKit
import SwiftUI

/// A compact preview card that appears after the pointer has rested on a
/// control for a moment and goes away the moment it leaves: a richer tooltip.
///
/// It lives in its own borderless panel over the window, so it can overhang
/// the edge of whatever it describes, but the panel never becomes key or main
/// and ignores the mouse: it takes no focus and never stands between the
/// pointer and the control. A press, a scroll or a key anywhere hides it, and
/// at most one card is up at a time.
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
    var reducesMotion = PiMotion.reducesMotion

    var isShown: Bool { panel?.isVisible == true }
    var isWaiting: Bool { pending != nil }
    /// The control the card is showing for, or waiting to show for.
    var anchorView: NSView? { anchor }

    /// The pointer entered or left `anchor`. Entering starts the wait; leaving
    /// the control the card belongs to hides it at once.
    func hover(_ inside: Bool, over anchor: NSView, width: CGFloat, content: @escaping @MainActor () -> AnyView) {
        if inside {
            if self.anchor === anchor, isShown || pending != nil { return }
            hide()
            self.anchor = anchor
            let delay = delay
            pending = Task { [weak self, weak anchor] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.pending = nil
                guard let anchor, anchor.window != nil, !anchor.isHiddenOrHasHiddenAncestor else { self.anchor = nil; return }
                self.show(over: anchor, width: width, content: content())
            }
        } else if self.anchor === anchor {
            hide()
        }
    }

    func hide() {
        pending?.cancel(); pending = nil
        anchor = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let resignation { NotificationCenter.default.removeObserver(resignation); self.resignation = nil }
        guard let panel else { return }
        self.panel = nil
        if Self.current === self { Self.current = nil }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
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

    private func show(over anchor: NSView, width: CGFloat, content: AnyView) {
        guard let window = anchor.window else { return }
        if let current = Self.current, current !== self { current.hide() }
        let card = content
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).fill(Color.piSurface))
            .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).stroke(Color.piHairlineStrong, lineWidth: 1))
            .shadow(color: Color.piShadow, radius: 10, y: 3)
            .padding(Self.shadowMargin)
            .accessibilityHidden(true)
        let host = NSHostingView(rootView: AnyView(card))
        host.appearance = anchor.effectiveAppearance
        let size = host.fittingSize
        let onScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? onScreen.insetBy(dx: -2_000, dy: -2_000)
        let panel = PiHoverCardPanel(contentRect: Self.frame(size: size, anchor: onScreen, window: window.frame, visible: visible),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.appearance = anchor.effectiveAppearance
        panel.contentView = host
        panel.setAccessibilityElement(false)
        let reduce = reducesMotion
        panel.alphaValue = reduce ? 1 : 0
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        if !reduce {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Double(PiMotion.quickMilliseconds) / 1_000
                panel.animator().alphaValue = 1
            }
        }
        self.panel = panel; Self.current = self
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.hide() }
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
