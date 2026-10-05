import AppKit

/// What the presenting view's environment hands the sheet.
struct PiSheetWindowInherited: Equatable {
    var reduceMotion: Bool
    var enabled: Bool
}

/// Takes no room, draws nothing and takes no clicks; it knows its window.
final class PiSheetWindowAnchorView: NSView {
    weak var coordinator: PiSheetWindowCoordinator?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.anchorMoved(to: window)
    }
}

/// Presents and closes one sheet as its owner asks, on the next turn of the
/// run loop: a sheet is reconciled after model changes settle.
@MainActor final class PiSheetWindowCoordinator {
    private var wanted: AnyHashable?
    private var inherited = PiSheetWindowInherited(reduceMotion: false, enabled: true)
    private var dismiss: (AnyHashable) -> Void = { _ in }
    private var content: (AnyHashable) -> NSView? = { _ in nil }
    private weak var parent: NSWindow?
    private var presented: (identity: AnyHashable, sheet: PiSheetWindow)?
    private var scheduled = false
    /// The window and content host the last sheet was in, emptied, for the
    /// next one: one of each a sheet, filled again each time it opens,
    /// instead of new ones for every opening.
    private var spare: PiSheetWindow.Reusable?

    /// Inherited state reaches the sheet after its owner has finished changing.
    func update(wanted: AnyHashable?, inherited: PiSheetWindowInherited, dismiss: @escaping (AnyHashable) -> Void, content: @escaping (AnyHashable) -> NSView?) {
        self.wanted = wanted; self.dismiss = dismiss; self.content = content; self.inherited = inherited
        schedule()
    }
    func anchorMoved(to window: NSWindow?) {
        parent = window
        schedule()
    }
    /// The presenting view has gone: its sheet goes with it, at once.
    func anchorGone() {
        wanted = nil; spare = nil
        let sheet = presented?.sheet
        presented = nil
        sheet?.recycle = nil
        sheet?.end(animated: false, requested: true)
    }
    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduled = false
                self.reconcile()
            }
        }
    }
    private func reconcile() {
        if let current = presented {
            current.sheet.inherit(inherited)
            // Another sheet, or none, is asked for: this one goes first, and
            // the next is presented once it has (`onEnded`).
            if current.identity != wanted { current.sheet.end(animated: true, requested: true) }
            return
        }
        guard let wanted, let parent else { return }
        // Another sheet on the window first: AppKit would queue this one
        // behind it, so it waits for the window to be free instead.
        guard parent.attachedSheet == nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in MainActor.assumeIsolated { self?.schedule() } }
            return
        }
        guard let view = content(wanted) else { return }
        let sheet = PiSheetWindow(reusing: spare, content: view, inherited: inherited, close: { [weak self] in self?.dismiss(wanted) })
        spare = nil
        sheet.recycle = { [weak self] reusable in self?.spare = reusable }
        presented = (wanted, sheet)
        sheet.onEnded = { [weak self, weak sheet] requested in
            guard let self, let sheet, self.presented?.sheet === sheet else { return }
            self.presented = nil
            if !requested {
                // Closed by the window it was on closing: what asked for it
                // is told, as a SwiftUI sheet's binding would be.
                if self.wanted == wanted { self.wanted = nil; self.dismiss(wanted) }
            } else {
                // Whatever is asked for now: another item, or this one again.
                self.schedule()
            }
        }
        sheet.present(on: parent)
    }
}

/// One presented sheet: the window, the content host in it, and what happens
/// once it has closed. Nothing of its content outlives the sheet; the window
/// and the content host, emptied, are the next sheet's of the same kind.
@MainActor final class PiSheetWindow {
    /// A closed sheet's window and content host, emptied, for the next sheet.
    struct Reusable {
        let window: NSWindow
        let host: PiSheetContentHost
    }
    private var window: NSWindow?
    private var host: PiSheetContentHost?
    private weak var parent: NSWindow?
    private var ending = false
    /// Whether its owner closed it, rather than the window it was on.
    private var requested = false
    private var parentObserver: NSObjectProtocol?
    /// Called once, when the sheet has closed and let go of its window, with
    /// whether its owner asked for that.
    var onEnded: ((Bool) -> Void)?
    /// Takes the window and content host back, emptied, once the sheet has
    /// closed; without it the window is closed.
    var recycle: ((Reusable) -> Void)?

    /// The sheet window of the sheet presented last, while it lives: for the
    /// tests that check nothing keeps it once it has closed.
    static weak var newest: NSWindow?

    /// Posted with a closed sheet's window, off screen, just before the window
    /// lets go of its content. Content that holds much, or keeps work going,
    /// lets go of it here, while its views can still be laid out once.
    static let willRelease = Notification.Name("PiSheetWindowWillRelease")

    init(reusing reusable: Reusable? = nil, content: NSView, inherited: PiSheetWindowInherited, close: @escaping @MainActor () -> Void) {
        let host = reusable?.host ?? PiSheetContentHost()
        host.show(content, inherited: inherited, close: close)
        // A native sheet knows its size before it joins a window. Laying
        // out its scroll/stack children at the zero-sized initial content
        // rect can otherwise send infinite geometry into AppKit.
        let size = host.fittingSize
        if size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
            host.setFrameSize(size)
            host.layoutSubtreeIfNeeded()
        }
        let window = reusable?.window ?? Self.makeWindow(contentSize: host.frame.size)
        window.contentView = host
        window.initialFirstResponder = host
        self.host = host; self.window = window
        fitContent()
        Self.newest = window
    }
    /// SwiftUI's own sheet window: titled for the sheet's frame, document
    /// modal, resizable only between the content's own minimum and maximum,
    /// not opaque, on the window background.
    private static func makeWindow(contentSize: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize), styleMask: [.titled, .resizable, .docModalWindow], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .windowBackgroundColor
        return window
    }

    /// The sheet takes its content's size, as SwiftUI sizes its sheets.
    private func fitContent() {
        guard let window, let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        window.setContentSize(size)
        window.contentMinSize = size
        window.contentMaxSize = size
    }

    /// Only what changed: a published setting set to the same value still
    /// redraws the sheet.
    func inherit(_ inherited: PiSheetWindowInherited) {
        host?.inherit(inherited)
    }

    func present(on parent: NSWindow) {
        guard let window else { return }
        self.parent = parent
        // A parent that closes takes its sheet with it.
        parentObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end(animated: false, requested: false) }
        }
        parent.beginSheet(window) { [weak self] _ in
            MainActor.assumeIsolated { self?.sheetEnded() }
        }
    }

    /// Closes the sheet. Animated, it slides away as AppKit's sheets do and
    /// lets go once off screen; otherwise it is taken down and let go of at
    /// once, which is what a window closing under it, or the view that
    /// presented it going away, needs: nothing may be left waiting on an
    /// animation that has no one to finish it.
    func end(animated: Bool, requested: Bool) {
        guard !ending, let window else { return }
        ending = true; self.requested = requested
        let attached = window.sheetParent
        attached?.endSheet(window)
        if !animated || attached == nil { window.orderOut(nil); release() }
    }

    /// AppKit has taken the sheet down; its window lets go once it has left
    /// the screen, its closing animation over, or it would slide away blank.
    private func sheetEnded() {
        guard window != nil else { return }
        ending = true
        releaseWhenOffScreen(attempt: 0)
    }
    private func releaseWhenOffScreen(attempt: Int) {
        guard let window else { return }
        if (window.isVisible || window.sheetParent != nil) && attempt < 100 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                MainActor.assumeIsolated { self?.releaseWhenOffScreen(attempt: attempt + 1) }
            }
            return
        }
        release()
    }
    /// The content lets go first, then, a turn later, the window.
    private var emptying = false
    private func release() {
        guard !emptying, let window, let host else { return }
        emptying = true
        // What the content holds that is large lets go first, while its views
        // can still be laid out once, emptied.
        NotificationCenter.default.post(name: Self.willRelease, object: window)
        // Then the content itself: an empty root, laid out and drawn while the
        // window still holds the view, and the view then taken out of the
        // window, lets go of the content whoever else still holds the view;
        // the view is this sheet's again next time. In a test something does:
        // XCTest keeps whatever AppKit autoreleases until the test returns,
        // and a sheet closed with the pointer over a hover region (every Pi
        // button has one), the app in front, left its content host held that
        // long, and its content's controller with it. In the app nothing
        // else holds the view once the closing turn is over.
        host.clear()
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { finishRelease() } }
    }
    private func finishRelease() {
        guard let window, let host else { return }
        if let parentObserver { NotificationCenter.default.removeObserver(parentObserver) }
        parentObserver = nil
        window.orderOut(nil)
        // The window and the content host, emptied, hold nothing more: the
        // next sheet of the same kind opens in both (`recycle`), or the window
        // is closed.
        window.initialFirstResponder = nil
        window.contentView = nil
        self.host = nil
        self.window = nil
        if let recycle, window.sheetParent == nil { recycle(Reusable(window: window, host: host)) } else { window.close() }
        recycle = nil
        let ended = onEnded
        onEnded = nil
        ended?(requested)
    }
}


/// Optional inherited state and release hooks for native sheet roots.
@MainActor protocol PiSheetWindowContent: AnyObject {
    func inherit(_ values: PiSheetWindowInherited)
    func setClose(_ close: @escaping @MainActor () -> Void)
    func prepareForRelease()
}
extension PiSheetWindowContent {
    func setClose(_ close: @escaping @MainActor () -> Void) {}
    func prepareForRelease() {}
}

/// Reused only while empty: closed content never keeps its model or tasks alive.
@MainActor final class PiSheetContentHost: NSView, InheritsReducedMotion {
    private var content: NSView?
    private(set) var inheritedReduceMotion = false
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        guard let content else { return .zero }
        let natural = content.intrinsicContentSize
        let fitting = content.fittingSize
        return NSSize(width: natural.width > 0 ? natural.width : max(fitting.width, content.bounds.width),
                      height: natural.height > 0 ? natural.height : max(fitting.height, content.bounds.height))
    }
    override var fittingSize: NSSize { intrinsicContentSize }
    func show(_ content: NSView, inherited: PiSheetWindowInherited, close: @escaping @MainActor () -> Void) {
        clear()
        self.content = content
        (content as? PiSheetWindowContent)?.setClose(close)
        inherit(inherited)
        addSubview(content)
        invalidateIntrinsicContentSize(); needsLayout = true
    }
    func inherit(_ values: PiSheetWindowInherited) {
        inheritedReduceMotion = values.reduceMotion
        (content as? InheritsEnabled)?.inheritedEnabled = values.enabled
        (content as? PiSheetWindowContent)?.inherit(values)
    }
    func clear() {
        (content as? PiSheetWindowContent)?.prepareForRelease()
        content?.removeFromSuperview(); content = nil
        inheritedReduceMotion = false
        invalidateIntrinsicContentSize()
    }
    override func layout() { super.layout(); content?.frame = bounds }
}
