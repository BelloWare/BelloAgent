import AppKit
import Combine

// The pane beside the chat: the chat's side and the window's tabs, in one
// place whatever is shown. The side is mounted where it always is, under the
// tab shown over it, so its transcript, draft and running reply are there
// when its tab is chosen again; it is hidden while covered
// (`ConversationPageVisibility` moves focus off it). With no tabs, the pane
// is the side alone, as it always was.

@MainActor final class RightPaneView: NSView, PiKit.SizeObserver {
    let model: WorkspaceModel
    let host: TabHost
    let pane: TabContainer
    /// The chat's side, if it has one shown, in a view the side's owner
    /// makes (`sideView`) and keeps per side.
    private(set) var side: (info: SideRecord, session: SessionDisplay)?
    private var width: CGFloat = 0
    /// Makes the view of a side (until the side pane is AppKit, a bridge).
    var makeSideView: ((SideRecord, SessionDisplay, CGFloat) -> NSView)?
    /// Hands a side's view its new width.
    var updateSideView: ((NSView, SideRecord, SessionDisplay, CGFloat) -> Void)?
    private var sideView: NSView?
    private var sideKey: (id: String, session: ObjectIdentifier)?
    private(set) var strip: TabStripView?
    private let content = TabContentContainer()
    private var watches: [AnyCancellable] = []
    private var scheduled = false

    init(model: WorkspaceModel, host: TabHost, pane: TabContainer) {
        self.model = model; self.host = host; self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(content)
        watches = [pane.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.schedule() } },
                   model.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.schedule() } }]
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func contentSizeChanged() { needsLayout = true }

    /// The window's disabled state: no tab is chosen, closed or dragged.
    var inheritedEnabled = true { didSet { if oldValue != inheritedEnabled { strip?.inheritedEnabled = inheritedEnabled } } }

    func update(side: (info: SideRecord, session: SessionDisplay)?, width: CGFloat, force: Bool = false) {
        let key = side.map { ($0.info.id, ObjectIdentifier($0.session)) }
        if key?.0 != sideKey?.id || key?.1 != sideKey?.session {
            sideView?.removeFromSuperview(); sideView = nil
            if let side, let made = makeSideView?(side.info, side.session, width) {
                addSubview(made, positioned: .below, relativeTo: content)
                sideView = made
            }
            sideKey = key.map { (id: $0.0, session: $0.1) }
        } else if let side, let sideView, force || width != self.width || side.info != self.side?.info {
            updateSideView?(sideView, side.info, side.session, width)
        }
        self.side = side; self.width = width
        refresh()
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.flush() } }
    }
    private func flush() { guard scheduled else { return }; scheduled = false; refresh() }

    /// What the pane shows, compared before anything is changed.
    private struct Shown: Equatable {
        var hasTabs: Bool
        var shownTab: HostedTab.ID?
        var placement: Int?
        var side: SideTabItem?
        var sideView: ObjectIdentifier?
    }
    private var shown: Shown?

    private func refresh() {
        let shown = pane.shownTab(sideAvailable: side != nil)
        let new = Shown(hasTabs: !pane.tabs.isEmpty, shownTab: shown?.id, placement: shown?.placement, side: sideItem, sideView: sideView.map(ObjectIdentifier.init))
        guard new != self.shown else { return }
        self.shown = new
        if pane.tabs.isEmpty {
            strip?.removeFromSuperview(); strip = nil
        } else if strip == nil {
            let made = TabStripView(host: host, container: pane, side: sideItem)
            made.inheritedEnabled = inheritedEnabled
            addSubview(made)
            strip = made
        }
        strip?.side = sideItem
        // Covered, the side is see-through rather than hidden, as SwiftUI's
        // opacity left it: the page's visibility owner moves its focus and
        // hides its native views (`ConversationPageVisibility`), and the
        // report hides the tab's content without this pane undoing it.
        sideView?.alphaValue = shown != nil ? 0 : 1
        if let shown { content.show(shown, for: pane) } else { content.letGo() }
        needsLayout = true
        // Laid out now, as SwiftUI laid the pane out in the same pass: the
        // tab's content is there, at its size, before what moves focus into
        // it looks for it.
        if window != nil { layoutSubtreeIfNeeded() }
    }
    private var sideItem: SideTabItem? {
        side.map { side in
            SideTabItem(title: side.info.kept ? (model.record(side.info.id)?.title ?? side.info.title) : "Side conversation",
                        help: side.info.kept ? "The saved side conversation" : "The side conversation")
        }
    }
    override func layout() {
        flush()
        super.layout()
        var top: CGFloat = 0
        if let strip { strip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: TabStripView.height); top = TabStripView.height }
        let body = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        // The visible side's flexible transcript keeps its enclosing
        // allocation; fixed header/composer controls may overflow it.
        sideView?.frame = body
        // Opacity kept those controls in the released ZStack's minimum,
        // which is proposed to the covered tab's representable sibling.
        let contentWidth = max(body.width, (sideView as? SidePaneView)?.minimumWidth ?? 0)
        content.frame = CGRect(x: (body.width - contentWidth) / 2, y: body.minY, width: contentWidth, height: body.height)
    }
    /// A covered side takes no clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let sideView, sideView.alphaValue == 0, let hit, hit === sideView || hit.isDescendant(of: sideView) { return nil }
        return hit
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piContent) }
}
