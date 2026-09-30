import AppKit
import SwiftUI
import GitView

// A project's changes and history, as a tab beside the chats or in a window
// of its own (`TabHost`), in place of the Changes sheet. One tab a project:
// the panel reads the project's folders, and its folder menu chooses among
// them. Its controller is made the first time the tab is shown, and reads
// and watches only while the panel is on screen (`GitController.setShown`).
// Closed, the tab lets go of everything it read.

@MainActor final class ChangesTab: HostedTab {
    override class var kind: String { "changes" }
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

    init(projectID: String, name: String, roots: [String]) {
        self.projectID = projectID; self.name = name; self.roots = roots
        super.init(key: projectID, title: Self.title(name), symbol: "arrow.triangle.branch")
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
    override func willClose() {
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
            GitPanelView(controller: tab.controller, place: tab.place, questions: tab.questions, project: tab.name)
        }
    }
}
