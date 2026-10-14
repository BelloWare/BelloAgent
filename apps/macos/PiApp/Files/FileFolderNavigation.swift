import AppKit
import Combine
import FileFinder

struct FileFolderSettings: Codable, Equatable {
    var shown = false
    var width: Double = 200
}

/// User-driven local viewing only. The model/helper never receives listings.
@MainActor final class FileFolderNavigation {
    private weak var tab: FileTab?
    let browser: FolderBrowser
    let panel: FileFolderPanel
    let menuPresenter = PiPopoverPresenter()
    private(set) var menu: FileFolderMenu?
    private var menuWatch: AnyCancellable?
    private var active = false
    private var lastProjectRoot: URL?
    private var standalone = FileFolderSettings()
    var settings: FileFolderSettings { tab?.container?.fileFolders ?? standalone }
    var projectRoot: URL? {
        guard let tab, case .trusted(_, let root) = tab.project else { return nil }
        let candidate = tab.containingFolderRoot?() ?? URL(fileURLWithPath: root, isDirectory: false)
        return FileBreadcrumb.contains(tab.url, in: candidate) ? FileBreadcrumb.normalized(candidate) : nil
    }
    init(tab: FileTab) {
        self.tab = tab
        let browser = FolderBrowser(); self.browser = browser
        panel = FileFolderPanel(browser: browser)
        browser.openFile = { [weak tab] url in tab?.openNearbyFile?(url) }
        browser.changed = { [weak panel] in panel?.refresh() }
        menuWatch = menuPresenter.$isShown.sink { [weak self] shown in
            if !shown { self?.menu?.browser.stop() }
        }
    }
    func setShown(_ shown: Bool) {
        if let container = tab?.container { container.fileFolders.shown = shown }
        else { standalone.shown = shown }
        tab?.objectWillChange.send()
        refresh()
    }
    func setWidth(_ width: CGFloat) {
        let width = Double(min(420, max(140, width.isFinite ? width : 200)))
        if let container = tab?.container { container.fileFolders.width = width }
        else { standalone.width = width }
        tab?.objectWillChange.send()
    }
    func refresh() {
        guard let tab else { return }
        let shown = settings.shown && tab.isShownNow
        let root = projectRoot
        if shown, !active || lastProjectRoot != root {
            active = true; lastProjectRoot = root
            browser.show(file: tab.url, projectRoot: root)
        } else if !shown, active { browser.stop(); active = false }
        panel.refresh()
    }
    func suspend() { browser.stop(); active = false; menu?.browser.stop(); menuPresenter.close() }
    func showInTree(_ url: URL) {
        setShown(true)
        // An ancestor outside the initial root may be chosen from the path.
        // Explicit browsing can widen an unanchored tree without trusting it.
        if projectRoot == nil {
            while browser.canGoUp, let root = browser.root, !FileBreadcrumb.contains(url, in: root) { browser.goUp() }
        }
        browser.reveal(url, isDirectory: true)
        menuPresenter.close()
    }
    func showMenu(_ crumb: FileBreadcrumb, from anchor: NSView) {
        if menuPresenter.isShown, menuPresenter.anchorView === anchor { menuPresenter.close(); return }
        menu?.browser.stop(); menuPresenter.close()
        let menu = FileFolderMenu(crumb: crumb, projectRoot: projectRoot,
            open: { [weak self, weak tab] url in self?.menuPresenter.close(); tab?.openNearbyFile?(url) },
            showTree: { [weak self] url in self?.showInTree(url) })
        self.menu = menu
        menuPresenter.toggle(from: anchor, width: 300, maximumHeight: 430, animates: false) { menu }
    }
}

@MainActor final class FileFolderPanel: NSView {
    let browser: FolderBrowser
    let tree: FolderTreeView
    private let title = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInkSecondary))
    private let up: PiKit.IconButton
    private let rule = HairlineView()
    init(browser: FolderBrowser) {
        self.browser = browser; tree = FolderTreeView(browser: browser)
        up = PiKit.IconButton(symbol: "arrow.up", label: "Up to parent folder", size: 24) { [weak browser] in browser?.goUp() }
        super.init(frame: .zero)
        up.setAccessibilityIdentifier("file-folder-up")
        wantsLayer = true
        for view in [tree, title, up, rule] as [NSView] { addSubview(view) }
        var style = FolderTreeView.Style()
        style.background = .piSurface; style.ink = .piInk; style.secondary = .piInkTertiary
        style.selection = NSColor.piAccent.withAlphaComponent(0.13); style.font = PiKit.Font.caption
        tree.style = style
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piSurface) }
    func refresh() {
        title.line.text = browser.root?.lastPathComponent.isEmpty == false ? browser.root!.lastPathComponent : "/"
        title.toolTip = browser.root?.path
        up.isHidden = !browser.canGoUp
        tree.reload(); needsLayout = true
    }
    override func layout() {
        super.layout()
        up.frame = CGRect(x: max(0, bounds.width - 30), y: 4, width: 24, height: 24)
        title.frame = CGRect(x: 12, y: 8, width: max(0, bounds.width - (up.isHidden ? 24 : 46)), height: 18)
        rule.frame = CGRect(x: 0, y: 31, width: bounds.width, height: 1)
        tree.frame = CGRect(x: 0, y: 32, width: bounds.width, height: max(0, bounds.height - 32))
    }
}
