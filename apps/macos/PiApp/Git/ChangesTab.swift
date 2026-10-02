import AppKit
import SwiftUI
import GitView

// A project's changes and history, as a tab beside the chats or in a window
// of its own (`TabHost`). One tab a project:
// the panel reads the project's folders, and its folder menu chooses among
// them. Its controller is made the first time the tab is shown, and reads
// and watches only while the panel is on screen (`GitController.setShown`).
// Closed, the tab lets go of everything it read.

@MainActor final class ChangesTab: HostedTab {
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

    override func makeContent() -> AnyView { AnyView(ChangesTabContent(tab: self)) }
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
struct ChangesTabContent: View {
    @ObservedObject var tab: ChangesTab
    var body: some View {
        if tab.removed {
            VStack(spacing: PiSpacing.md) {
                Image(systemName: "questionmark.folder").font(.system(size: 30, weight: .light)).foregroundStyle(Color.piInkTertiary)
                Text("Missing").font(PiFont.heading).foregroundStyle(Color.piInk)
                Text("Its project, \(tab.name), was removed from Bello Agent.").font(PiFont.body).foregroundStyle(Color.piInkSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 360)
            }
            .padding(PiSpacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.piContent)
            .accessibilityElement(children: .combine)
        } else {
            VStack(spacing: 0) {
                if let name = tab.returnName, tab.canGoBack {
                    HStack(spacing: PiSpacing.sm) {
                        Button { tab.goBack() } label: { Label("Back to \(name)", systemImage: "chevron.left") }
                            .buttonStyle(.piSecondaryCompact).fixedSize()
                            .accessibilityIdentifier("changes-back-to-file")
                        Text("Opened from its blame").font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
                            .lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                        Spacer()
                    }
                    .padding(.horizontal, PiSpacing.md).padding(.vertical, 6)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.piHairline).frame(height: 1) }
                }
                GitPanelView(controller: tab.controller, place: tab.place, questions: tab.questions, project: tab.name,
                             openFile: { [weak tab] path, line in tab?.openFile(path: path, line: line) })
            }
        }
    }
}
