import AppKit
import Combine
import GitView

// A project's changes and history, as a tab beside the chats or in a window
// of its own (`TabHost`). One tab a project:
// the panel reads the project's folders, and its folder menu chooses among
// them. Its controller is made the first time the tab is shown, and reads
// and watches only while the panel is on screen (`GitController.setShown`).
// Closed, the tab lets go of everything it read.

@MainActor final class ChangesTab: AppKitHostedTab {
    override class var kind: String { "changes" }
    override var preferredWindowSize: NSSize { NSSize(width: 1040, height: 720) }
    let projectID: String
    /// The project's folder name, and what the panel reads: its folders.
    @Published private(set) var name: String
    private(set) var roots: [String]
    /// The project was removed from Bello Agent: the tab says so, and reads nothing.
    @Published private(set) var removed = false
    /// Where the panel is and the discard question it has up, and its asker:
    /// the tab's, so closing the tab takes the question down.
    let place = GitPanelPlace()
    let questions = PiQuestion()
    /// What the app knows of a project: its folder name and folders, or nil
    /// once it was removed. Set once by the app.
    static var resolveProject: (String) -> (name: String, roots: [String])? = { _ in nil }
    static var openLocation: (URL, Int) -> Void = { _, _ in }
    /// Brings a tab to the front: set once by the app.
    static var activate: (HostedTab) -> Void = { _ in }
    /// The file whose blame opened a change here, to go back to: held
    /// weakly, and offered only while its tab is still open.
    private(set) weak var returnTab: FileTab?
    @Published private(set) var returnName: String?
    func cameFrom(_ tab: FileTab) { returnTab = tab; returnName = tab.title }
    /// Back to that file's tab, as it was: its place, its selection, its
    /// find bar and keys.
    func goBack() {
        guard let tab = returnTab, tab.container != nil else { returnTab = nil; returnName = nil; return }
        Self.activate(tab)
    }
    var canGoBack: Bool { returnTab?.container != nil }
    /// The navigation to a blamed line under way: one at a time, cancelled
    /// by the next and when the tab closes.
    private var navigation: Task<Void, Never>?
    func navigate(_ work: @escaping @MainActor () async -> Bool) {
        navigation?.cancel()
        navigation = Task { @MainActor in _ = await work() }
    }

    func openFile(path: String, line: Int) {
        guard !removed, line > 0, let root = controller.repositoryRoot else { return }
        Self.openLocation(URL(fileURLWithPath: root).appendingPathComponent(path), line)
    }

    init(projectID: String, name: String, roots: [String]) {
        self.projectID = projectID; self.name = name; self.roots = roots
        super.init(key: projectID, title: Self.title(name), symbol: "arrow.left.arrow.right")
        help = Self.help(name)
    }
    static func title(_ name: String) -> String { "Changes · " + name }
    static func help(_ name: String) -> String { "Changes and history of " + name }

    private var madeController: GitController?
    /// Made the first time the panel is shown: a controller starts reading
    /// as it is made, and a tab brought back but not shown reads nothing.
    var controller: GitController {
        if let madeController { return madeController }
        let controller = GitController(roots: roots)
        madeController = controller
        return controller
    }
    var hasController: Bool { madeController != nil }

    override func makeAppKitContent() -> NSView { ChangesTabContent(tab: self) }
    override class func restore(key: String, state: Data?) -> HostedTab? {
        guard let project = resolveProject(key) else { return nil }
        return ChangesTab(projectID: key, name: project.name, roots: project.roots)
    }
    override func projectsChanged() {
        guard let project = Self.resolveProject(projectID) else {
            guard !removed else { return }
            // Nothing to read any more: the question goes down, and what
            // was read goes with the panel.
            removed = true
            place.cancelQuestion()
            madeController?.letGo()
            return
        }
        if project.name != name { name = project.name; title = Self.title(project.name); help = Self.help(project.name) }
        if project.roots != roots {
            roots = project.roots
            if let madeController {
                madeController.roots = project.roots
                if madeController.root.map({ !project.roots.contains($0) }) ?? true { madeController.root = project.roots.first }
            }
        }
        if removed {
            removed = false
            // Back before its notice was drawn, the panel never left the
            // screen and nothing will say it is shown again: it reads afresh.
            if let madeController, madeController.isShown { madeController.setShown(true) }
        }
    }
    /// Hidden after it was shown: a navigation still on its way stops (the
    /// first wait, for a tab just brought forward, is the controller's).
    override func didHide() {
        super.didHide()
        navigation?.cancel(); navigation = nil
    }
    override func willClose() {
        navigation?.cancel(); navigation = nil
        place.cancelQuestion()
        madeController?.letGo()
    }
}

/// A Changes tab's content: the panel over the tab's controller, or what it
/// says once its project was removed.
@MainActor final class ChangesTabContent: NSView, PiKit.SizeObserver {
    private weak var tab: ChangesTab?
    private let notice: NoticeView
    private let backBar = FlippedView()
    private let backButton = PiKit.Button("", symbol: "chevron.left", style: .secondary, compact: true)
    private let backNote = PiKit.TextLine(PiKit.Line("Opened from its blame", font: PiKit.Font.micro, color: .piInkTertiary))
    private let backRule = HairlineView()
    let panel: GitPanelView
    private var observation: AnyCancellable?

    init(tab: ChangesTab) {
        self.tab = tab
        notice = NoticeView(symbol: PiKit.Symbol("questionmark.folder", size: 30, weight: .light), title: "Missing", detail: "")
        panel = GitPanelView(controller: tab.controller, place: tab.place, questions: tab.questions, project: tab.name,
                             openFile: { [weak tab] path, line in tab?.openFile(path: path, line: line) })
        super.init(frame: .zero)
        wantsLayer = true
        backButton.setAccessibilityIdentifier("changes-back-to-file")
        backButton.onPress = { [weak tab] in tab?.goBack() }
        for view in [backButton, backNote, backRule] as [NSView] { backBar.addSubview(view) }
        for view in [notice, backBar, panel] as [NSView] { addSubview(view) }
        observation = tab.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piContent) }

    func contentSizeChanged() { needsLayout = true }
    private var showsBack: Bool { tab.map { $0.returnName != nil && $0.canGoBack } ?? false }
    func refresh() {
        guard let tab else { return }
        notice.set(title: "Missing", detail: "Its project, \(tab.name), was removed from Bello Agent.")
        notice.isHidden = !tab.removed
        panel.isHidden = tab.removed
        backBar.isHidden = tab.removed || !showsBack
        if let name = tab.returnName { backButton.title = "Back to \(name)" }
        panel.setProject(tab.name)
        needsLayout = true
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
    override func layout() {
        super.layout()
        notice.frame = bounds
        var y: CGFloat = 0
        if !backBar.isHidden {
            let button = backButton.intrinsicContentSize
            let height = max(button.height, backNote.intrinsicContentSize.height) + 12
            backBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
            StackLayout.place([.fixed(backButton), .view(backNote, .line(backNote, priority: -1)), .spacer()], spacing: PiSpacing.sm,
                              in: CGRect(x: PiSpacing.md, y: 6, width: bounds.width - PiSpacing.md * 2, height: height - 12), scale: piScale)
            backRule.frame = CGRect(x: 0, y: height - 1, width: bounds.width, height: 1)
            y = height
        }
        panel.frame = CGRect(x: 0, y: y, width: bounds.width, height: max(0, bounds.height - y))
    }
}
