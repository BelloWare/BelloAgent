import AppKit
import SwiftUI

/// A popover the app owns at the AppKit boundary, anchored to the control that
/// opened it. SwiftUI's own `.popover` sizes itself to its content wherever
/// that lands; this one is given the room the screen has above (or below) its
/// anchor, so a tall panel of charts scrolls inside itself instead of running
/// off the display when the window is small or low on the screen.
///
/// At most one app-owned popover is open at a time: opening one closes the
/// other. Escape and a click anywhere outside close it (`.transient`); a press
/// on the control that opened it is that control's to handle, and closes it.
@MainActor final class PiPopoverPresenter: NSObject, ObservableObject, NSPopoverDelegate {
    private static weak var current: PiPopoverPresenter?
    @Published private(set) var isShown = false
    private(set) var popover: NSPopover?
    private weak var anchor: NSView?
    /// The control the open popover points at.
    var anchorView: NSView? { anchor }

    /// The arrow and a margin, kept clear between the popover and the edge of the screen.
    static let screenMargin: CGFloat = 34
    /// Never squeezed below this, however little room there is.
    static let minimumHeight: CGFloat = 180

    /// Where a popover of up to `maximumHeight` points goes, and how tall it
    /// may be: above the anchor when that side has the room, else whichever
    /// side has more. Screen rectangles are in AppKit's bottom-left space.
    struct Placement: Equatable {
        let above: Bool
        let height: CGFloat
    }
    static func placement(anchor: CGRect, visible: CGRect, maximumHeight: CGFloat) -> Placement {
        let above = visible.maxY - anchor.maxY - screenMargin
        let below = anchor.minY - visible.minY - screenMargin
        let up = above >= maximumHeight || above >= below
        return Placement(above: up, height: max(minimumHeight, min(maximumHeight, up ? above : below)))
    }

    /// A press waiting for its content to be ready before the popover shows.
    private var pending: Task<Void, Never>?
    var isOpening: Bool { pending != nil }

    /// Opens once the content says it is ready, or after `wait` whatever it
    /// says — a popover that opens whole reads better than one that grows a
    /// beat after it appears, and a slow read still opens promptly. A press
    /// while it waits, or on the open popover, closes it.
    func toggle(from anchor: NSView, width: CGFloat, maximumHeight: CGFloat, animates: Bool, within wait: Duration,
                isReady: @escaping @MainActor () -> Bool, content: @escaping @MainActor () -> AnyView) {
        if isShown || pending != nil { close(); return }
        guard wait > .zero, !isReady() else {
            show(from: anchor, width: width, maximumHeight: maximumHeight, animates: animates, content: content); return
        }
        pending = Task { [weak self, weak anchor] in
            let deadline = ContinuousClock.now.advanced(by: wait)
            while !isReady(), ContinuousClock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(8)) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            guard let anchor else { return }
            self.show(from: anchor, width: width, maximumHeight: maximumHeight, animates: animates, content: content)
        }
    }

    func show(from anchor: NSView, width: CGFloat, maximumHeight: CGFloat, animates: Bool, content: () -> AnyView) {
        guard let window = anchor.window else { return }
        if let current = Self.current, current !== self { current.close() }
        close()
        let onScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? onScreen.insetBy(dx: -2_000, dy: -2_000)
        let placement = Self.placement(anchor: onScreen, visible: visible, maximumHeight: maximumHeight)
        // The panel is as tall as its content up to the room it was given; a
        // scroll view inside reports that height, so it never grows past it.
        let host = NSHostingController(rootView: AnyView(content().frame(width: width).frame(maxHeight: placement.height, alignment: .top)))
        host.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = animates
        popover.delegate = self
        popover.contentViewController = host
        self.popover = popover; self.anchor = anchor; Self.current = self
        let edge: NSRectEdge = placement.above == !anchor.isFlipped ? .maxY : .minY
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: edge)
        PiPopoverSurface.install(under: host.view)
        isShown = true
    }

    func close() {
        pending?.cancel(); pending = nil
        guard let popover else { return }
        self.popover = nil; anchor = nil
        if Self.current === self { Self.current = nil }
        popover.delegate = nil
        popover.close()
        if isShown { isShown = false }
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        // The press that lands on the opening control closes the popover
        // through that control. Closing it here as well would reopen it on
        // the release.
        guard let anchor, let event = NSApp.currentEvent, event.type == .leftMouseDown, event.window === anchor.window else { return true }
        return !anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        self.popover = nil; anchor = nil
        if Self.current === self { Self.current = nil }
        if isShown { isShown = false }
    }
}

/// The app's own surface under a popover's content. The system popover
/// material takes its tint from whatever is behind it — the wallpaper, another
/// app — so the same panel read cream over one window and mid-grey over
/// another, and the app's quieter inks lost their contrast on the grey. This
/// fills the popover's frame, arrow included, with `piSurface`, as every
/// card in the app is filled. Should a future AppKit lay the frame out
/// differently, the view is simply not installed and the material shows.
final class PiPopoverSurface: NSView {
    static func install(under content: NSView) {
        guard let frame = content.superview, frame.window === content.window,
              !frame.subviews.contains(where: { $0 is PiPopoverSurface }) else { return }
        // A point in from the frame's edge, so the popover keeps its own outline.
        let surface = PiPopoverSurface(frame: frame.bounds.insetBy(dx: 1, dy: 1))
        surface.autoresizingMask = [.width, .height]
        frame.addSubview(surface, positioned: .below, relativeTo: content)
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { super.init(coder: coder); wantsLayer = true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor(Color.piSurface).cgColor }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The press target of a control that opens an app-owned popover: an AppKit
/// button laid over the control's SwiftUI face. The press, the pointer, the
/// tooltip, the keyboard and the accessibility action all belong to one view
/// the window can hit-test, and a test can press it without an active app.
final class PiPopoverTriggerButton: NSButton {
    var onPress: ((NSView) -> Void)?
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) { super.init(frame: frame); configure() }
    required init?(coder: NSCoder) { super.init(coder: coder); configure() }
    private func configure() {
        title = ""; isBordered = false; imagePosition = .noImage
        setButtonType(.momentaryPushIn)
        focusRingType = .exterior
        target = self; action = #selector(pressed(_:))
    }
    @objc private func pressed(_ sender: Any?) { onPress?(self) }
    /// The face is SwiftUI's; this view only takes the press.
    override func draw(_ dirtyRect: NSRect) {}
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { onHover?(false) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// `PiPopoverTriggerButton` in a SwiftUI layout, sized to the face it covers.
struct PiPopoverTrigger: NSViewRepresentable {
    let label: String
    var identifier: String?
    var help: String
    let onHover: (Bool) -> Void
    let onPress: (NSView) -> Void

    func makeNSView(context: Context) -> PiPopoverTriggerButton {
        let button = PiPopoverTriggerButton(frame: .zero)
        apply(to: button)
        return button
    }
    func updateNSView(_ button: PiPopoverTriggerButton, context: Context) { apply(to: button) }
    private func apply(to button: PiPopoverTriggerButton) {
        button.onHover = onHover; button.onPress = onPress
        if button.toolTip != help { button.toolTip = help.isEmpty ? nil : help }
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
        if button.accessibilityIdentifier() != (identifier ?? "") { button.setAccessibilityIdentifier(identifier) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PiPopoverTriggerButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// A stat pill whose dialog is an app-owned popover: the pill's own face, an
/// AppKit press target over it, and a panel sized to the screen around it.
/// The face reads exactly as `PiStatPill`'s; only the popover is different.
struct PiStatPopoverPill<Content: View>: View {
    let symbol: String
    let label: String
    /// A last figure in warning ink (see `PiStatPillFace.warningTail`).
    var warningTail: String? = nil
    var accessibility: String? = nil
    var identifier: String? = nil
    var help: String = ""
    @ObservedObject var presenter: PiPopoverPresenter
    var width: CGFloat = PiPopoverPanel.width
    var maximumHeight: CGFloat = PiPopoverPanel.maximumHeight
    /// Called on the press that opens the popover, before its content is built.
    var willOpen: () -> Void = {}
    /// Whether the content has what it needs to open whole; the popover waits
    /// up to `readyWithin` for it.
    var isReady: @MainActor () -> Bool = { true }
    var readyWithin: Duration = .milliseconds(250)
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    @Environment(\.piReduceMotion) private var reduceMotion

    var body: some View {
        PiStatPillFace(symbol: symbol, label: label, highlighted: hovering || presenter.isShown, warningTail: warningTail)
            .accessibilityHidden(true)
            .overlay {
                PiPopoverTrigger(label: accessibility ?? label, identifier: identifier, help: help.isEmpty ? label : help,
                                 onHover: { hovering = $0 },
                                 onPress: { anchor in
                                     let opening = !presenter.isShown && !presenter.isOpening
                                     if opening { willOpen() }
                                     let reduce = reduceMotion, content = content
                                     presenter.toggle(from: anchor, width: width, maximumHeight: maximumHeight, animates: !reduce,
                                                      within: readyWithin, isReady: isReady) {
                                         AnyView(content().environment(\.piReduceMotion, reduce).tint(Color.piAccent))
                                     }
                                 })
            }
            // A pill that leaves the screen (another chat, a narrower pane)
            // takes its popover with it, one turn after SwiftUI's teardown.
            .onDisappear { [presenter] in Task { @MainActor in presenter.close() } }
    }
}

/// The shape every chart popover shares: its width, its ceiling, and the
/// scrolling page inside it.
enum PiPopoverPanel {
    static let width: CGFloat = 468
    static let maximumHeight: CGFloat = 600
}
