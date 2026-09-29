import SwiftUI
import AppKit

/// Closes the sheet a view is in when the app presented it in a window of its
/// own (`piSheetWindow`). Nil in SwiftUI's own sheets, where `dismiss` does.
private struct PiSheetCloseKey: EnvironmentKey { static let defaultValue: (@MainActor () -> Void)? = nil }
extension EnvironmentValues {
    var piSheetClose: (@MainActor () -> Void)? {
        get { self[PiSheetCloseKey.self] }
        set { self[PiSheetCloseKey.self] = newValue }
    }
}

/// Closes the sheet a view is in, however it was presented: through the
/// window's own close in a `piSheetWindow`, and through SwiftUI's `dismiss`
/// in a `.sheet` or a window of its own (the ⌘, Settings window). A sheet
/// declares `@PiDismiss private var dismiss` and calls `dismiss()` as before.
@propertyWrapper struct PiDismiss: DynamicProperty {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.piSheetClose) private var sheetClose
    init() {}
    var wrappedValue: PiDismissAction { PiDismissAction(dismiss: dismiss, sheetClose: sheetClose) }
}
struct PiDismissAction {
    fileprivate let dismiss: DismissAction
    fileprivate let sheetClose: (@MainActor () -> Void)?
    @MainActor func callAsFunction() { if let sheetClose { sheetClose() } else { dismiss() } }
}

extension View {
    /// `.sheet(isPresented:)`, in a sheet window the app makes and lets go of
    /// whole once the sheet has closed. SwiftUI keeps every sheet window it
    /// has presented (macOS 14), hidden, and with it the sheet's views and
    /// state, which went on observing the model: ten closed Settings sheets
    /// made a model change cost five times what it did, and emptying those
    /// windows (0.1.113) still left SwiftUI's own references keeping each
    /// sheet's view graph, about 20 MB for a Changes sheet closed over a big
    /// diff and 1 to 7 MB for the others. The sheet looks and closes as SwiftUI's does:
    /// the same window, sized to its content, on the same AppKit sheet. Its
    /// content is made as it opens; what it shows after that comes from what
    /// the content itself observes.
    func piSheetWindow<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        background(PiSheetWindowAnchor(wanted: isPresented.wrappedValue ? AnyHashable(true) : nil,
                                       dismiss: { _ in isPresented.wrappedValue = false },
                                       content: { _ in AnyView(content()) }))
    }
    /// `.sheet(item:)`, in a sheet window of the app's own (see above): up
    /// while the item is set, closed and presented again for another item
    /// when its identity changes, and the item set to nil when the sheet
    /// closes itself.
    func piSheetWindow<Item: Identifiable, Content: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        background(PiSheetWindowAnchor(wanted: item.wrappedValue.map { AnyHashable($0.id) },
                                       dismiss: { identity in
                                           // Only the sheet still asked for: a closing one never clears its successor.
                                           if let current = item.wrappedValue, AnyHashable(current.id) == identity { item.wrappedValue = nil }
                                       },
                                       content: { identity in
                                           guard let current = item.wrappedValue, AnyHashable(current.id) == identity else { return nil }
                                           return AnyView(content(current))
                                       }))
    }
}

/// Where a `piSheetWindow` is presented from: the window it is in, and the
/// environment the sheet inherits, as a SwiftUI sheet inherits it from the
/// view that presents it.
private struct PiSheetWindowAnchor: NSViewRepresentable {
    /// Which sheet is asked for: its identity, or nil for none.
    let wanted: AnyHashable?
    let dismiss: (AnyHashable) -> Void
    let content: (AnyHashable) -> AnyView?

    func makeCoordinator() -> PiSheetWindowCoordinator { PiSheetWindowCoordinator() }
    func makeNSView(context: Context) -> PiSheetWindowAnchorView {
        let view = PiSheetWindowAnchorView()
        view.coordinator = context.coordinator
        return view
    }
    func updateNSView(_ view: PiSheetWindowAnchorView, context: Context) {
        context.coordinator.update(wanted: wanted,
                                   inherited: PiSheetWindowInherited(reduceMotion: context.environment.piReduceMotion, enabled: context.environment.isEnabled),
                                   dismiss: dismiss, content: content)
    }
    static func dismantleNSView(_ view: PiSheetWindowAnchorView, coordinator: PiSheetWindowCoordinator) {
        coordinator.anchorGone()
    }
}

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

/// Presents and closes one sheet as its binding says, on the next turn of the
/// run loop: SwiftUI calls `updateNSView` inside its own update, and a sheet
/// window shown from there would lay out and draw within it.
@MainActor final class PiSheetWindowCoordinator {
    private var wanted: AnyHashable?
    private var inherited = PiSheetWindowInherited(reduceMotion: false, enabled: true)
    private var dismiss: (AnyHashable) -> Void = { _ in }
    private var content: (AnyHashable) -> AnyView? = { _ in nil }
    private weak var parent: NSWindow?
    private var presented: (identity: AnyHashable, sheet: PiSheetWindow)?
    private var scheduled = false
    /// The window and hosting view the last sheet was in, emptied, for the
    /// next one. AppKit keeps every window that has been on screen, closed or
    /// not, a couple of megabytes each, and SwiftUI can keep a hosting view it
    /// last saw the pointer over (`PiSheetWindow.release`): one of each a
    /// sheet, filled again each time it opens, instead of new ones for every
    /// opening.
    private var spare: PiSheetWindow.Reusable?

    func update(wanted: AnyHashable?, inherited: PiSheetWindowInherited, dismiss: @escaping (AnyHashable) -> Void, content: @escaping (AnyHashable) -> AnyView?) {
        self.wanted = wanted; self.dismiss = dismiss; self.content = content
        if self.inherited != inherited { self.inherited = inherited; presented?.sheet.inherit(inherited) }
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

/// One presented sheet: the window, the hosting view in it, and what happens
/// once it has closed. Nothing of its content outlives the sheet; the window
/// and the hosting view, emptied, are the next sheet's of the same kind.
@MainActor final class PiSheetWindow {
    /// A closed sheet's window and hosting view, emptied, for the next sheet.
    struct Reusable {
        let window: NSWindow
        let host: NSHostingView<PiSheetWindowRoot>
    }
    private var window: NSWindow?
    private var host: NSHostingView<PiSheetWindowRoot>?
    private let settings: PiSheetWindowSettings
    private weak var parent: NSWindow?
    private var ending = false
    /// Whether its owner closed it, rather than the window it was on.
    private var requested = false
    private var parentObserver: NSObjectProtocol?
    /// Called once, when the sheet has closed and let go of its window, with
    /// whether its owner asked for that.
    var onEnded: ((Bool) -> Void)?
    /// Takes the window and hosting view back, emptied, once the sheet has
    /// closed; without it the window is closed.
    var recycle: ((Reusable) -> Void)?

    /// The sheet window of the sheet presented last, while it lives: for the
    /// tests that check nothing keeps it once it has closed.
    static weak var newest: NSWindow?

    /// Posted with a closed sheet's window, off screen, just before the window
    /// lets go of its content. Content that holds much, or keeps work going,
    /// lets go of it here, while its views can still be laid out once.
    static let willRelease = Notification.Name("PiSheetWindowWillRelease")

    init(reusing reusable: Reusable? = nil, content: AnyView, inherited: PiSheetWindowInherited, close: @escaping @MainActor () -> Void) {
        settings = PiSheetWindowSettings(inherited)
        let root = PiSheetWindowRoot(content: content, settings: settings, close: close)
        let host: NSHostingView<PiSheetWindowRoot>
        if let reusable { host = reusable.host; host.rootView = root } else { host = NSHostingView(rootView: root) }
        let window = reusable?.window ?? Self.makeWindow()
        window.contentView = host
        window.initialFirstResponder = host
        self.host = host; self.window = window
        fitContent()
        Self.newest = window
    }
    /// SwiftUI's own sheet window: titled for the sheet's frame, document
    /// modal, resizable only between the content's own minimum and maximum,
    /// not opaque, on the window background.
    private static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable, .docModalWindow], backing: .buffered, defer: false)
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

    func inherit(_ inherited: PiSheetWindowInherited) {
        settings.reduceMotion = inherited.reduceMotion; settings.enabled = inherited.enabled
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
        // Then the content itself. SwiftUI keeps a hosting view that saw the
        // pointer over a hover region (every Pi button has one) in a key
        // window, and everything the view shows with it, until it sees the
        // pointer leave, which it never does for a view no longer on screen:
        // a Changes sheet closed with its Done button, the app in front, kept
        // its views and its controller for good. An empty root, laid out and
        // drawn while the window still holds the view, and the view then taken
        // out of the window, lets go of the content whatever SwiftUI keeps of
        // the view; the view is this sheet's again next time.
        host.rootView = PiSheetWindowRoot(content: AnyView(EmptyView()), settings: settings, close: {})
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        host.display()
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { finishRelease() } }
    }
    private func finishRelease() {
        guard let window, let host else { return }
        if let parentObserver { NotificationCenter.default.removeObserver(parentObserver) }
        parentObserver = nil
        window.orderOut(nil)
        // The window and the hosting view, emptied, hold nothing more. AppKit
        // keeps the window regardless, as it keeps any window that has been on
        // screen: the next sheet of the same kind opens in both (`recycle`),
        // or the window is closed.
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

/// The values a presented sheet inherits and follows while it is up.
@MainActor final class PiSheetWindowSettings: ObservableObject {
    @Published var reduceMotion: Bool
    @Published var enabled: Bool
    init(_ inherited: PiSheetWindowInherited) { reduceMotion = inherited.reduceMotion; enabled = inherited.enabled }
}

/// The sheet's content with what it inherits from the view that presented it,
/// and the close action its Done and Escape use in place of `dismiss`.
struct PiSheetWindowRoot: View {
    let content: AnyView
    @ObservedObject var settings: PiSheetWindowSettings
    let close: @MainActor () -> Void
    var body: some View {
        content
            .environment(\.piReduceMotion, settings.reduceMotion)
            .disabled(!settings.enabled)
            .environment(\.piSheetClose, close)
    }
}
