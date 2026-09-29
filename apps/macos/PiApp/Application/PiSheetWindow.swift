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

extension View {
    /// `.sheet(isPresented:)`, in a sheet window the app makes and lets go of
    /// whole once the sheet has closed. SwiftUI keeps every sheet window it
    /// has presented (macOS 14), hidden, and with it the sheet's view graph
    /// and state: `DismissedSheets` empties those windows, but SwiftUI's own
    /// references keep the graph alive, about 20 MB for each Changes sheet
    /// closed over a big diff. The sheet looks and closes as SwiftUI's does:
    /// the same window, sized to its content, on the same AppKit sheet.
    func piSheetWindow<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        background(PiSheetWindowAnchor(isPresented: isPresented, content: content))
    }
}

/// Where a `piSheetWindow` is presented from: the window it is in, and the
/// environment the sheet inherits, as a SwiftUI sheet inherits it from the
/// view that presents it.
private struct PiSheetWindowAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let content: () -> Content

    func makeCoordinator() -> PiSheetWindowCoordinator { PiSheetWindowCoordinator() }
    func makeNSView(context: Context) -> PiSheetWindowAnchorView {
        let view = PiSheetWindowAnchorView()
        view.coordinator = context.coordinator
        return view
    }
    func updateNSView(_ view: PiSheetWindowAnchorView, context: Context) {
        let binding = $isPresented, make = content
        context.coordinator.update(wanted: isPresented,
                                   inherited: PiSheetWindowInherited(reduceMotion: context.environment.piReduceMotion, enabled: context.environment.isEnabled),
                                   close: { binding.wrappedValue = false },
                                   content: { AnyView(make()) })
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
    private var wanted = false
    private var inherited = PiSheetWindowInherited(reduceMotion: false, enabled: true)
    private var close: () -> Void = {}
    private var content: () -> AnyView = { AnyView(EmptyView()) }
    private weak var parent: NSWindow?
    private var presented: PiSheetWindow?
    private var scheduled = false

    func update(wanted: Bool, inherited: PiSheetWindowInherited, close: @escaping () -> Void, content: @escaping () -> AnyView) {
        self.wanted = wanted; self.close = close; self.content = content
        if self.inherited != inherited { self.inherited = inherited; presented?.inherit(inherited) }
        schedule()
    }
    func anchorMoved(to window: NSWindow?) {
        parent = window
        schedule()
    }
    /// The presenting view has gone: its sheet goes with it, at once.
    func anchorGone() {
        wanted = false
        let sheet = presented
        presented = nil
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
        if wanted, presented == nil, let parent {
            // Another sheet on the window first: AppKit would queue this one
            // behind it, so it waits for the window to be free instead.
            guard parent.attachedSheet == nil else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in MainActor.assumeIsolated { self?.schedule() } }
                return
            }
            let sheet = PiSheetWindow(content: content(), inherited: inherited, close: { [weak self] in self?.close() })
            presented = sheet
            sheet.onEnded = { [weak self, weak sheet] requested in
                guard let self, let sheet, self.presented === sheet else { return }
                self.presented = nil
                if requested {
                    // Asked for again while it was going: it comes back.
                    self.schedule()
                } else if self.wanted {
                    // Closed by something other than its binding — the window
                    // it was on closing — the binding follows.
                    self.wanted = false; self.close()
                }
            }
            sheet.present(on: parent)
        } else if !wanted, let presented {
            presented.end(animated: true, requested: true)
        }
    }
}

/// One presented sheet: the window, the hosting view in it, and what happens
/// once it has closed. Nothing of it outlives the sheet.
@MainActor final class PiSheetWindow {
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

    /// The sheet window of the sheet presented last, while it lives: for the
    /// tests that check nothing keeps it once it has closed.
    static weak var newest: NSWindow?

    init(content: AnyView, inherited: PiSheetWindowInherited, close: @escaping @MainActor () -> Void) {
        settings = PiSheetWindowSettings(inherited)
        let host = NSHostingView(rootView: PiSheetWindowRoot(content: content, settings: settings, close: close))
        // SwiftUI's own sheet window: titled for the sheet's frame, document
        // modal, resizable only between the content's own minimum and maximum,
        // not opaque, on the window background.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled, .resizable, .docModalWindow],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.initialFirstResponder = host
        self.host = host; self.window = window
        fitContent()
        Self.newest = window
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
    private func release() {
        guard let window else { return }
        // What the content holds that is large lets go first, while its views
        // can still be laid out once, emptied (`DismissedSheets.willRelease`).
        NotificationCenter.default.post(name: DismissedSheets.willRelease, object: window)
        if let parentObserver { NotificationCenter.default.removeObserver(parentObserver) }
        parentObserver = nil
        window.orderOut(nil)
        // The window holds nothing more: AppKit may keep the window object a
        // while after it closes, as it keeps any window that has been on
        // screen, but not the sheet's views or anything they hold.
        window.contentView = nil
        window.close()
        host = nil
        self.window = nil
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
