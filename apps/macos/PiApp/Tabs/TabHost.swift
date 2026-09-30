import AppKit
import SwiftUI
import Combine

// Tabs beside the chats: files, and later a repository's changes, shown as
// tabs in the pane beside the chat or popped out into windows of their own.
// The pane and each window hold tabs of their own (a `TabContainer`); a tab
// moves between them, by "Open in Window" and "Move to Pane" or by dragging
// it, and they all come back after a relaunch, windows where they were.
//
// The host knows no kind of tab. Each kind is a subclass of `HostedTab`
// that makes its own content, saves what it needs to come back, and says
// how it comes back (`TabHost.kinds`). In the pane the chat's side is a tab
// too, beside these, but it belongs to its chat, not to the host.

/// One tab of some kind. A kind subclasses it: its content, what it saves,
/// how it comes back (`restore`), and what it does when shown, hidden or
/// closed.
@MainActor class HostedTab: ObservableObject, Identifiable {
    let id = UUID()
    /// The kind, saved with the tab to bring it back: "file", "changes".
    class var kind: String { "" }
    var kind: String { type(of: self).kind }
    /// What opening the same thing again finds: one tab a key and kind,
    /// whichever pane or window it is in (a file's path, a repository).
    let key: String
    @Published var title: String
    @Published var symbol: String
    /// Said when the pointer rests on the tab.
    @Published var help = ""
    /// Where the tab is: the pane or a window.
    fileprivate(set) weak var container: TabContainer? { didSet { if container !== oldValue { placement &+= 1 } } }
    /// Bumped whenever the tab goes to another pane or window: where it is
    /// shown takes its content in again, even if SwiftUI kept that view.
    private(set) var placement = 0

    init(key: String, title: String, symbol: String) {
        self.key = key; self.title = title; self.symbol = symbol
    }

    // MARK: What a kind gives

    /// The tab's content, made once, when it is first shown, and kept while
    /// the tab is open: its state survives other tabs being shown and the tab
    /// moving between the pane and windows.
    func makeContent() -> AnyView { AnyView(EmptyView()) }
    /// What the tab needs to come back after a relaunch, beside its key.
    func savedState() -> Data? { nil }
    /// A tab of this kind, as saved; nil if it cannot come back.
    class func restore(key: String, state: Data?) -> HostedTab? { nil }
    /// Shown, or no longer shown: a kind may let go of what it can make
    /// again while hidden.
    func didShow() {}
    func didHide() {}
    /// Closed for good.
    func willClose() {}
    /// The projects changed (added, removed, trusted or not).
    func projectsChanged() {}
    /// The kind's own entries in the tab's menu, after the host's.
    func menuEntries() -> [PiMenuEntry] { [] }
    /// The view that takes the keys when the tab is shown, if any.
    var focusView: NSView? { nil }

    // MARK: Kept content

    private var madeContent: TabContentView?
    /// The content, in a view of its own the host moves between the pane
    /// and windows.
    var contentView: TabContentView {
        if let madeContent { return madeContent }
        let view = TabContentView(rootView: AnyView(makeContent().piTabRoot()))
        madeContent = view
        return view
    }
    var hasContent: Bool { madeContent != nil }
    /// Whether keyboard focus was in the tab's content when it was last
    /// moved: where it goes, it takes focus again. Asked once.
    private var focusedWhenMoved = false
    fileprivate func noteFocusBeforeMove() {
        guard let content = madeContent, let responder = content.window?.firstResponder as? NSView else { return }
        focusedWhenMoved = responder === content || responder.isDescendant(of: content)
    }
    func takeFocusAfterMove() -> Bool {
        defer { focusedWhenMoved = false }
        return focusedWhenMoved
    }
    fileprivate func letGoOfContent() {
        madeContent?.removeFromSuperview()
        madeContent = nil
    }
}

/// A tab's content, kept by the tab: a hosting view of its own, so its state
/// lives while the tab is open, wherever it is shown.
final class TabContentView: NSHostingView<AnyView> {}

extension View {
    /// What a tab's content inherits in the app, being a root of its own.
    func piTabRoot() -> some View {
        buttonStyle(.piSecondary).toggleStyle(.piSwitch).background(Color.piContent)
    }
}

/// The pane beside the chats, or one window: its tabs, in order, and which
/// is shown. In the pane, the chat's side can be shown in their place.
@MainActor final class TabContainer: ObservableObject, Identifiable {
    let id: UUID
    let isPane: Bool
    @Published fileprivate(set) var tabs: [HostedTab] = []
    @Published fileprivate(set) var activeID: HostedTab.ID?
    /// In the pane: the chat's side is shown in place of the tabs, when the
    /// chat has one.
    @Published fileprivate(set) var sideShown = false

    init(id: UUID = UUID(), isPane: Bool) { self.id = id; self.isPane = isPane }

    /// The tab chosen last, or the first.
    var activeTab: HostedTab? { tabs.first { $0.id == activeID } ?? tabs.first }
    /// The tab shown: the chosen one, unless the side is shown instead.
    func shownTab(sideAvailable: Bool) -> HostedTab? { sideShown && sideAvailable ? nil : activeTab }
}

@MainActor final class TabHost: ObservableObject {
    let pane = TabContainer(isPane: true)
    /// The windows tabs were popped out into, in the order they came.
    @Published private(set) var windows: [TabContainer] = []
    private var controllers: [TabContainer.ID: TabWindowController] = [:]
    /// Where the tabs are kept across launches; nil keeps nothing (tests).
    private let defaults: UserDefaults?
    static let savedKey = "tabHost"
    private var restoring = false
    private var restored = false
    private var saveScheduled = false
    /// Quitting: saved once, and not again as windows close.
    private var terminating = false
    private var quitting: NSObjectProtocol?
    /// Test seam: windows are made but never shown.
    var showsWindows = true

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        quitting = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flush()
                self?.terminating = true
            }
        }
    }

    /// The kinds of tab there are, to bring them back (`TabKinds.swift`).
    static var kinds: [HostedTab.Type] { registeredKinds }

    /// Every tab, in the pane then the windows.
    var allTabs: [HostedTab] { ([pane] + windows).flatMap(\.tabs) }
    func tab(kind: String, key: String) -> HostedTab? { allTabs.first { $0.kind == kind && $0.key == key } }
    func container(_ id: TabContainer.ID) -> TabContainer? { ([pane] + windows).first { $0.id == id } }

    // MARK: Opening and showing

    /// Shows the tab of a kind and key if one is open, wherever it is (its
    /// window comes forward); else makes one and puts it after the tab shown
    /// in `container`, the pane unless said.
    @discardableResult func open(kind: String, key: String, in container: TabContainer? = nil, make: () -> HostedTab) -> HostedTab {
        if let open = tab(kind: kind, key: key) { activate(open); return open }
        let tab = make()
        insert(tab, into: container ?? pane, at: nil)
        activate(tab)
        return tab
    }
    /// Shows a tab in its pane or window, the window brought forward.
    func activate(_ tab: HostedTab) {
        guard let container = tab.container else { return }
        // What was shown before: nothing in a container just made.
        let shown = container.sideShown ? nil : container.tabs.first { $0.id == container.activeID }
        if container.activeID != tab.id { container.activeID = tab.id }
        if container.sideShown { container.sideShown = false }
        if shown !== tab { shown?.didHide(); tab.didShow() }
        if !container.isPane { controllers[container.id]?.bringForward() }
        save()
    }
    /// In the pane: the chat's side in place of the tabs.
    func showSide() {
        guard !pane.sideShown else { return }
        pane.shownTab(sideAvailable: true)?.didHide()
        pane.sideShown = true
        save()
    }

    // MARK: Closing

    /// Closes a tab: the one to its right is shown, else to its left; in the
    /// pane, else the side; a window whose last tab closes closes.
    func close(_ tab: HostedTab) {
        guard let container = tab.container else { return }
        remove(tab, from: container)
        tab.willClose()
        tab.letGoOfContent()
        finish(container)
        save()
    }
    func closeOthers(than tab: HostedTab) {
        guard let container = tab.container else { return }
        for other in container.tabs where other !== tab { close(other) }
        activate(tab)
    }
    /// ⌘W: closes the tab a window shows, if it shows one; the pane's only
    /// when a tab, not the chat's side, is shown there.
    func closeShownTab(in container: TabContainer, sideAvailable: Bool) -> Bool {
        guard let shown = container.shownTab(sideAvailable: sideAvailable) else { return false }
        close(shown)
        return true
    }

    // MARK: Moving

    /// Moves a tab into a pane or window, at an index or after the tab shown
    /// there, and shows it.
    func move(_ tab: HostedTab, to target: TabContainer, at index: Int? = nil) {
        guard let source = tab.container else { return }
        if source !== target { tab.noteFocusBeforeMove() }
        if source === target {
            guard let from = source.tabs.firstIndex(where: { $0 === tab }) else { return }
            var to = min(max(0, index ?? from), source.tabs.count)
            source.tabs.remove(at: from)
            if to > from { to -= 1 }
            source.tabs.insert(tab, at: min(to, source.tabs.count))
            activate(tab)
            return
        }
        remove(tab, from: source)
        insert(tab, into: target, at: index)
        finish(source)
        activate(tab)
    }
    /// Pops a tab out into a window of its own, at a point on the screen if
    /// given (where a drag let go of it).
    @discardableResult func popOut(_ tab: HostedTab, at point: NSPoint? = nil) -> TabContainer {
        if let source = tab.container, !source.isPane, source.tabs.count == 1 {
            // The only tab of a window: the window goes there instead.
            if let point { controllers[source.id]?.move(topLeftTo: point) }
            return source
        }
        let window = TabContainer(isPane: false)
        windows.append(window)
        let frame = point.map { TabWindowController.frame(topLeft: $0) }
        makeController(for: window, frame: frame)
        move(tab, to: window)
        return window
    }
    /// Moves every tab of a window into the pane, and closes the window.
    func moveToPane(_ tab: HostedTab) { move(tab, to: pane) }

    // MARK: Windows

    private func makeController(for container: TabContainer, frame: NSRect?) {
        let controller = TabWindowController(container: container, host: self, frame: frame)
        controllers[container.id] = controller
        if showsWindows { controller.showWindow(nil) }
    }
    /// The window of a container, if it is a window.
    func window(of container: TabContainer) -> NSWindow? { controllers[container.id]?.window }
    /// A window was closed by its own button: its tabs close with it.
    func windowClosed(_ container: TabContainer) {
        guard let index = windows.firstIndex(where: { $0 === container }) else { return }
        for tab in container.tabs { tab.willClose(); tab.letGoOfContent() }
        container.tabs = []
        windows.remove(at: index)
        controllers[container.id] = nil
        save()
    }
    func windowMoved() { save() }

    /// The workspace is going: every tab closes and every window with them,
    /// what is kept of them saved first. Nothing is saved after.
    func tearDown() {
        flush()
        terminating = true
        for tab in allTabs { tab.willClose(); tab.letGoOfContent() }
        // Every pane and window emptied, so nothing still drawing them makes
        // a closed tab's content again.
        for container in [pane] + windows {
            for tab in container.tabs { tab.container = nil }
            container.tabs = []; container.activeID = nil; container.sideShown = false
        }
        for window in windows { controllers[window.id]?.closeWithoutClosingTabs() }
        controllers = [:]; windows = []
    }

    // MARK: Projects

    func projectsChanged() { for tab in allTabs { tab.projectsChanged() } }

    // MARK: Bookkeeping

    private func insert(_ tab: HostedTab, into container: TabContainer, at index: Int?) {
        let after = container.tabs.firstIndex { $0.id == container.activeID }.map { $0 + 1 } ?? container.tabs.count
        container.tabs.insert(tab, at: min(max(0, index ?? after), container.tabs.count))
        tab.container = container
    }
    private func remove(_ tab: HostedTab, from container: TabContainer) {
        guard let index = container.tabs.firstIndex(where: { $0 === tab }) else { return }
        let wasShown = container.shownTab(sideAvailable: true) === tab
        container.tabs.remove(at: index)
        tab.container = nil
        if container.activeID == tab.id {
            let next = container.tabs.indices.contains(index) ? container.tabs[index] : container.tabs.last
            container.activeID = next?.id
            if wasShown { tab.didHide(); next?.didShow() }
        }
    }
    /// A window left without tabs closes; the pane left without tabs shows
    /// the side again.
    private func finish(_ container: TabContainer) {
        guard container.tabs.isEmpty else { return }
        if container.isPane { container.sideShown = false; return }
        let controller = controllers[container.id]
        windows.removeAll { $0 === container }
        controllers[container.id] = nil
        controller?.closeWithoutClosingTabs()
    }

    // MARK: Across launches

    private struct SavedTab: Codable { var kind: String; var key: String; var state: Data? }
    private struct SavedContainer: Codable { var tabs: [SavedTab]; var active: Int?; var sideShown: Bool; var frame: String? }
    private struct Saved: Codable { var pane: SavedContainer; var windows: [SavedContainer] }

    /// Saves on the next turn of the run loop, once for all that changed.
    func save() {
        guard defaults != nil, !restoring, !terminating, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.saveScheduled else { return }
                self.flush()
            }
        }
    }
    /// Saves now; nothing before the saved tabs have been brought back, so a
    /// quit before the projects are known keeps what was saved.
    func flush() {
        saveScheduled = false
        guard let defaults, restored, !restoring, !terminating else { return }
        func saved(_ container: TabContainer) -> SavedContainer {
            SavedContainer(tabs: container.tabs.map { SavedTab(kind: $0.kind, key: $0.key, state: $0.savedState()) },
                           active: container.tabs.firstIndex { $0.id == container.activeID }, sideShown: container.sideShown,
                           frame: container.isPane ? nil : controllers[container.id]?.window.map { NSStringFromRect($0.frame) })
        }
        let value = Saved(pane: saved(pane), windows: windows.map(saved))
        defaults.set(try? JSONEncoder().encode(value), forKey: Self.savedKey)
    }
    /// The tabs as they were, and the windows where they were; a tab whose
    /// kind is not known, or that cannot come back, is left out.
    func restore() {
        guard !restored else { return }
        restored = true
        guard let defaults, let data = defaults.data(forKey: Self.savedKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        restoring = true
        defer { restoring = false; save() }
        func tabs(_ saved: SavedContainer) -> [HostedTab] {
            saved.tabs.compactMap { entry in
                guard tab(kind: entry.kind, key: entry.key) == nil,
                      let kind = Self.kinds.first(where: { $0.kind == entry.kind }) else { return nil }
                return kind.restore(key: entry.key, state: entry.state)
            }
        }
        func fill(_ container: TabContainer, _ saved: SavedContainer) {
            let restored = tabs(saved)
            for tab in restored { insert(tab, into: container, at: nil) }
            let active = saved.active.flatMap { saved.tabs.indices.contains($0) ? saved.tabs[$0] : nil }
            container.activeID = restored.first { $0.kind == active?.kind && $0.key == active?.key }?.id ?? restored.first?.id
            container.sideShown = saved.sideShown && !restored.isEmpty
        }
        fill(pane, saved.pane)
        for entry in saved.windows {
            let window = TabContainer(isPane: false)
            fill(window, entry)
            guard !window.tabs.isEmpty else { continue }
            windows.append(window)
            makeController(for: window, frame: entry.frame.map(NSRectFromString))
        }
    }
}
