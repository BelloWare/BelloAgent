import AppKit
import SwiftUI

// TEMPORARY (0.1.120): where the AppKit workspace window (`WorkspaceRootView`)
// still meets SwiftUI.
// - The window scene (Application/PiApp.swift) takes `WorkspaceView`, a
//   SwiftUI view: it hosts the AppKit root and carries the scene's focused
//   value for the menu commands.
// - Sheets are presented in the app's sheet window (Application/PiSheetWindow),
//   which takes SwiftUI content; the Settings, Conversation Content and
//   Resources sheets are still SwiftUI (Application/, Inspector/).
// Each part goes when its other side is AppKit.

/// The workspace window's content, where the SwiftUI scene asks for it.
struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    init(model: WorkspaceModel) { self.model = model }
    var body: some View {
        Root(model: model)
            .ignoresSafeArea(.container, edges: .top)
            .frame(minWidth: 920, minHeight: 600)
            .focusedSceneValue(\.workspaceCommandModel, model)
    }
    private struct Root: NSViewRepresentable {
        let model: WorkspaceModel
        func makeNSView(context: Context) -> WorkspaceRootView {
            let view = WorkspaceRootView(model: model)
            view.inheritedEnabled = context.environment.isEnabled
            view.inheritedReduceMotion = context.environment.piReduceMotion
            return view
        }
        func updateNSView(_ view: WorkspaceRootView, context: Context) {
            view.inheritedEnabled = context.environment.isEnabled
            view.inheritedReduceMotion = context.environment.piReduceMotion
        }
    }
}

/// The pages laid over the chats.
@MainActor enum WorkspacePages {
    static func make(_ page: WorkspacePage, model: WorkspaceModel) -> NSView? {
        switch page {
        case .report: return ReportPage(model: model)
        case .background: return BackgroundRequestsPage(model: model)
        default: return nil
        }
    }
    /// The window's disabled state and motion, handed to the page.
    static func update(_ view: NSView, enabled: Bool, reduceMotion: Bool) {
        if let page = view as? ReportPage { page.inheritedEnabled = enabled; page.inheritedReduceMotion = reduceMotion }
        if let page = view as? BackgroundRequestsPage { page.inheritedEnabled = enabled; page.inheritedReduceMotion = reduceMotion }
    }
}

/// The workspace's sheets, each in the app's own sheet window while the
/// model asks for it (`piSheetWindow`), closed again when it stops asking.
@MainActor final class WorkspaceSheetPresenter {
    let model: WorkspaceModel
    @MainActor private struct Sheet {
        let coordinator = PiSheetWindowCoordinator()
        let wanted: @MainActor (WorkspaceModel) -> AnyHashable?
        let dismiss: @MainActor (WorkspaceModel, AnyHashable) -> Void
        let content: @MainActor (WorkspaceModel, AnyHashable) -> AnyView?
    }
    private let sheets: [Sheet]
    init(model: WorkspaceModel) {
        self.model = model
        func flag(_ get: @escaping @MainActor (WorkspaceModel) -> Bool, _ clear: @escaping @MainActor (WorkspaceModel) -> Void,
                  _ content: @escaping @MainActor (WorkspaceModel) -> AnyView?) -> Sheet {
            Sheet(wanted: { get($0) ? AnyHashable(true) : nil }, dismiss: { model, _ in clear(model) }, content: { model, _ in content(model) })
        }
        func item<Item: Identifiable>(_ get: @escaping @MainActor (WorkspaceModel) -> Item?, _ clear: @escaping @MainActor (WorkspaceModel) -> Void,
                                      _ content: @escaping @MainActor (WorkspaceModel, Item) -> AnyView) -> Sheet {
            Sheet(wanted: { get($0).map { AnyHashable($0.id) } },
                  // Only the sheet still asked for: a closing one never clears its successor.
                  dismiss: { model, identity in if let current = get(model), AnyHashable(current.id) == identity { clear(model) } },
                  content: { model, identity in
                      guard let current = get(model), AnyHashable(current.id) == identity else { return nil }
                      return content(model, current)
                  })
        }
        sheets = [
            flag({ $0.showProfiles }, { $0.showProfiles = false }) { model in
                AnyView(ProfileSettings(model: model, controller: model.settingsSheetEditor(), windowChrome: false).frame(width: 880, height: 780))
            },
            flag({ $0.showConversationContent }, { $0.showConversationContent = false }) { model in
                model.contentSessionID.map { AnyView(ConversationContentView(model: model, sessionID: $0)) }
            },
            flag({ $0.showResources }, { $0.showResources = false }) { model in AnyView(ResourceInspector(model: model)) },
            flag({ $0.showWorkspaceManager }, { $0.showWorkspaceManager = false }) { model in AnyView(WorkspaceManagerView(model: model)) },
            item({ $0.renameTarget }, { $0.renameTarget = nil }) { model, target in AnyView(RenameChatSheet(model: model, chatID: target.id)) },
            item({ $0.topicEditor }, { $0.topicEditor = nil }) { model, target in AnyView(TopicSheet(model: model, target: target)) },
            item({ $0.webhookPreviewTarget }, { $0.webhookPreviewTarget = nil }) { model, target in AnyView(WebhookPreviewSheet(model: model, chatID: target.id)) },
        ]
    }
    func attach(_ window: NSWindow) { for sheet in sheets { sheet.coordinator.anchorMoved(to: window) } }
    /// Out of its window: each sheet goes, and none is presented until the
    /// root is in a window again.
    func detach() { for sheet in sheets { sheet.coordinator.anchorGone(); sheet.coordinator.anchorMoved(to: nil) } }
    /// Which sheet each asks for now.
    var wanted: [AnyHashable?] { sheets.map { $0.wanted(model) } }
    /// What the model asks for now, and what the window hands each sheet.
    func update(enabled: Bool, reduceMotion: Bool) {
        let inherited = PiSheetWindowInherited(reduceMotion: reduceMotion, enabled: enabled)
        for sheet in sheets {
            let model = self.model
            // The closures hold the sheet's own parts, not the sheet (and so not its coordinator).
            let dismiss = sheet.dismiss, content = sheet.content
            sheet.coordinator.update(wanted: sheet.wanted(model), inherited: inherited,
                                     dismiss: { [weak model] identity in if let model { dismiss(model, identity) } },
                                     content: { [weak model] identity in model.flatMap { content($0, identity) } })
        }
    }
}
