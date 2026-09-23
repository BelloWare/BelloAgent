import AppKit
import SwiftUI

/// The sidebar reserves this row for native traffic lights and window dragging.
/// Conversation/report headers start at the window top alongside it, avoiding
/// an empty full-width strip above the chat title.
struct WindowChrome: NSViewRepresentable {
    static let height: CGFloat = 36
    /// Default and bounds of the user-adjustable sidebar.
    static let sidebarWidth: CGFloat = 300
    static let minimumSidebarWidth: CGFloat = 200
    static let maximumSidebarWidth: CGFloat = 420
    static func clampSidebarWidth(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return sidebarWidth }
        return min(maximumSidebarWidth, max(minimumSidebarWidth, value))
    }
    var sidebarWidth: CGFloat = WindowChrome.sidebarWidth
    /// The chat whose composer should receive typing that lands nowhere.
    var focusedSessionID: String? = nil
    func makeCoordinator() -> WindowPresentationController { WindowPresentationController(defaults: .standard) }
    func makeNSView(context: Context) -> WindowChromeView {
        let view = WindowChromeView()
        view.controller = context.coordinator
        view.sidebarWidth = sidebarWidth
        return view
    }
    func updateNSView(_ view: WindowChromeView, context: Context) {
        if view.sidebarWidth != sidebarWidth { view.sidebarWidth = sidebarWidth; view.needsDisplay = true }
        context.coordinator.focusedSessionID = focusedSessionID
        context.coordinator.attach(view.window, chrome: view)
    }
    static func dismantleNSView(_ view: WindowChromeView, coordinator: WindowPresentationController) { coordinator.detach() }
}

/// Every window of the app wears its own chrome instead of the system title
/// bar. Dropping a `PiWindowBar` into a window's content hides that bar and
/// stands in for it: the strip drags the window, a double click zooms it, and
/// `trafficLightInset` keeps the content clear of the close/minimise/zoom
/// buttons, which stay native. A sheet has no title bar to replace, so the
/// bar leaves sheet windows untouched.
struct PiWindowBar: NSViewRepresentable {
    /// Leading room for the native window buttons.
    static let trafficLightInset: CGFloat = 78
    func makeNSView(context: Context) -> PiWindowBarView { PiWindowBarView(frame: .zero) }
    func updateNSView(_ view: PiWindowBarView, context: Context) {}
}

@MainActor final class PiWindowBarView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("piWindowBar")
        setAccessibilityLabel("Window drag area")
    }
    required init?(coder: NSCoder) { return nil }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.applyPiWindowChrome()
    }
    override func mouseDown(with event: NSEvent) {
        guard let window, window.attachedSheet == nil, !window.styleMask.contains(.fullScreen), !window.isSheet else { return }
        if event.clickCount == 2 { window.zoom(nil) } else { window.performDrag(with: event) }
    }
}

extension NSWindow {
    /// Hides the system title bar while keeping `.titled` for native key
    /// handling and window buttons, and paints the app's own canvas behind
    /// the content so no grey strip shows through. Sheets are left alone.
    func applyPiWindowChrome() {
        guard !isSheet, styleMask.contains(.titled) else { return }
        styleMask.insert(.fullSizeContentView)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        toolbar = nil
        tabbingMode = .disallowed
        backgroundColor = NSColor(Color.piWindow)
    }
}

struct ConversationHeaderLayoutMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> ConversationHeaderMarkerView { ConversationHeaderMarkerView() }
    func updateNSView(_ view: ConversationHeaderMarkerView, context: Context) {}
}
final class ConversationHeaderMarkerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor final class WindowChromeView: NSView {
    weak var controller: WindowPresentationController?
    var sidebarWidth: CGFloat = WindowChrome.sidebarWidth
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: WindowChrome.height) }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("workspaceWindowChrome")
        setAccessibilityLabel("Window controls and drag area")
    }
    required init?(coder: NSCoder) { return nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); controller?.attach(window, chrome: self)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(Color.piContent).setFill(); bounds.fill()
        NSColor(Color.piWindow).setFill()
        NSRect(x: 0, y: 0, width: min(sidebarWidth, bounds.width), height: bounds.height).fill()
        NSColor(Color.piHairline).setFill()
        NSRect(x: sidebarWidth, y: 0, width: 1, height: bounds.height).fill()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window, window.attachedSheet == nil, !window.styleMask.contains(.fullScreen) else { return }
        if event.clickCount == 2 { _ = controller?.handle(event) }
        else { window.performDrag(with: event) }
    }
}

@MainActor final class WindowPresentationController {
    private weak var window: NSWindow?
    private weak var chrome: WindowChromeView?
    private var eventMonitor: Any?
    private var keyMonitor: Any?
    /// The frame a double-click zoom replaced, which the next one restores.
    /// Kept in the defaults as well: the window's zoomed frame is autosaved,
    /// and without this a relaunch or a reopened window could not be unzoomed.
    private var restoreFrame: NSRect? {
        didSet {
            guard let defaults, restoreFrame != oldValue else { return }
            if let restoreFrame { defaults.set(NSStringFromRect(restoreFrame), forKey: Self.restoreFrameKey) }
            else { defaults.removeObject(forKey: Self.restoreFrameKey) }
        }
    }
    private let defaults: UserDefaults?
    static let restoreFrameKey = "mainWindowZoomRestoreFrame"
    /// The size the window group opens at (`PiApp`), used to unzoom a window
    /// with no remembered frame.
    static let defaultSize = NSSize(width: 1240, height: 800)
    private var consumesSecondMouseUp = false
    /// The chat whose composer takes stray typing; set from the workspace view.
    var focusedSessionID: String?
    /// The composer found for the focused chat, kept so repeated typing outside
    /// a text view does not walk the window's view tree — with a long chat open
    /// that tree holds thousands of rows. Tests pin the count.
    private var resolvedComposer: (sessionID: String, editor: ComposerTextView)?
    private(set) var composerLookups = 0

    /// Without `defaults` the zoom's restore frame lasts as long as this controller.
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let saved = defaults?.string(forKey: Self.restoreFrameKey).map(NSRectFromString), saved.width > 0, saved.height > 0 { restoreFrame = saved }
    }

    func attach(_ window: NSWindow?, chrome: WindowChromeView) {
        guard let window else { detach(); return }
        guard self.window !== window || self.chrome !== chrome else { return }
        detach(); self.window = window; self.chrome = chrome
        // Match WindowGroup.hiddenTitleBar instead of undoing SwiftUI's window
        // style after attachment. Keep .titled for native key/focus and controls.
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = nil
        window.tabbingMode = .disallowed
        window.isMovableByWindowBackground = false
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handle(event) == nil
            }
            return consumed ? nil : event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // The event is never swallowed: at most the first responder moves before it is delivered.
            _ = MainActor.assumeIsolated { self?.redirectTyping(event) != nil }
            return event
        }
    }
    func detach() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        eventMonitor = nil; keyMonitor = nil; window = nil; chrome = nil; consumesSecondMouseUp = false
        resolvedComposer = nil
    }

    // MARK: Typing lands in the composer

    /// A printable keystroke that would land nowhere useful (the transcript,
    /// a sidebar row, nothing at all) moves the cursor into the visible
    /// composer first, so typing just works after a click elsewhere. Text
    /// inputs, the terminal, sheets and shortcuts are left alone.
    func redirectTyping(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, window.attachedSheet == nil, !window.isMiniaturized,
              Self.shouldRedirectTyping(characters: event.characters, modifiers: event.modifierFlags, responderTakesText: Self.takesText(window.firstResponder)),
              let editor = composerTarget(in: window) else { return event }
        window.makeFirstResponder(editor)
        return event
    }
    /// The focused chat's composer, remembered while it stays in this window
    /// and keeps its chat. Anything else falls back to a full search.
    private func composerTarget(in window: NSWindow) -> ComposerTextView? {
        if let sessionID = focusedSessionID, let cached = resolvedComposer, cached.sessionID == sessionID,
           cached.editor.window === window, cached.editor.sessionID == sessionID, !cached.editor.isHiddenOrHasHiddenAncestor {
            return cached.editor
        }
        composerLookups += 1
        let found = Self.composerTarget(in: window, sessionID: focusedSessionID)
        if let sessionID = focusedSessionID, let found { resolvedComposer = (sessionID, found) } else { resolvedComposer = nil }
        return found
    }
    /// Only plain, printable characters redirect: no command or control shortcuts,
    /// no arrows, function keys, Escape, Tab, Return or Delete, and no space,
    /// which scrolls whatever is focused.
    static func shouldRedirectTyping(characters: String?, modifiers: NSEvent.ModifierFlags, responderTakesText: Bool) -> Bool {
        guard !responderTakesText, modifiers.intersection([.command, .control, .function]).isEmpty,
              let scalar = characters?.unicodeScalars.first, characters?.unicodeScalars.count == 1 || characters?.unicodeScalars.count == 2 else { return false }
        if scalar.value < 0x20 || scalar.value == 0x7F || (0xF700...0xF8FF).contains(scalar.value) { return false }
        return !CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
    /// Text views, field editors and the terminal already take typing.
    static func takesText(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        if view is NSText || view is NSTextField { return true }
        return String(describing: type(of: view)).contains("Terminal")
    }
    /// The visible composer of the focused chat; with one composer on screen, that one.
    static func composerTarget(in window: NSWindow, sessionID: String?) -> ComposerTextView? {
        guard let content = window.contentView else { return nil }
        func editors(_ view: NSView) -> [ComposerTextView] {
            if let editor = view as? ComposerTextView { return editor.isHiddenOrHasHiddenAncestor ? [] : [editor] }
            return view.subviews.flatMap { editors($0) }
        }
        let visible = editors(content)
        if let sessionID, let match = visible.first(where: { $0.sessionID == sessionID }) { return match }
        return visible.count == 1 ? visible[0] : nil
    }

    /// Do not intercept a control, normal click, drag, sheet, or full-screen
    /// window. Only a second click in the custom header background is ours.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, let chrome, event.window === window else { return event }
        if event.type == .leftMouseUp && consumesSecondMouseUp {
            consumesSecondMouseUp = false; return nil
        }
        guard event.type == .leftMouseDown, event.clickCount == 2,
              !window.styleMask.contains(.fullScreen), window.attachedSheet == nil,
              !window.isMiniaturized, Self.isTitleBarBackground(event.locationInWindow, in: window, chrome: chrome) else { return event }
        consumesSecondMouseUp = true
        zoomToAvailableScreen()
        return nil
    }

    static func isTitleBarBackground(_ point: NSPoint, in window: NSWindow, chrome: WindowChromeView) -> Bool {
        guard window.styleMask.contains(.titled), window.styleMask.contains(.resizable) else { return false }
        guard chrome.window === window, !chrome.isHidden,
              chrome.convert(chrome.bounds, to: nil).contains(point) else { return false }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(kind), !button.isHidden,
               button.convert(button.bounds, to: nil).insetBy(dx: -3, dy: -3).contains(point) { return false }
        }
        if let frame = window.contentView?.superview {
            var hit = frame.hitTest(frame.convert(point, from: nil))
            while let current = hit {
                if current is NSControl || current is NSTextView { return false }
                hit = current.superview
            }
        }
        return true
    }

    func zoomToAvailableScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main, !window.styleMask.contains(.fullScreen) else { return }
        let available = screen.visibleFrame
        if let previous = restoreFrame, Self.approximatelyEqual(window.frame, available) {
            restoreFrame = nil
            window.setFrame(Self.constrained(previous, to: available), display: true, animate: false)
        } else if Self.approximatelyEqual(window.frame, available) {
            // Zoomed with nothing remembered (a window from before this was
            // kept): unzoom to the size the window opens at, centred.
            let size = Self.defaultSize
            window.setFrame(Self.constrained(NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2, width: size.width, height: size.height), to: available), display: true, animate: false)
        } else {
            restoreFrame = window.frame
            window.setFrame(available, display: true, animate: false)
        }
    }

    private static func approximatelyEqual(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }
    static func constrained(_ frame: NSRect, to available: NSRect) -> NSRect {
        let size = NSSize(width: min(frame.width, available.width), height: min(frame.height, available.height))
        return NSRect(x: min(max(frame.minX, available.minX), available.maxX - size.width),
                      y: min(max(frame.minY, available.minY), available.maxY - size.height), width: size.width, height: size.height)
    }
}
