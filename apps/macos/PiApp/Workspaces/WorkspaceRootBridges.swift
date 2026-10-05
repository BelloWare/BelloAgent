import AppKit

extension ConversationContentView: PiSheetWindowContent {
    func inherit(_ values: PiSheetWindowInherited) { inheritedEnabled = values.enabled }
}

extension ResourceInspector: PiSheetWindowContent {
    func inherit(_ values: PiSheetWindowInherited) { inheritedEnabled = values.enabled }
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

/// The workspace's sheets, each in its native sheet window while the
/// model asks for it, closed again when it stops asking.
@MainActor final class WorkspaceSheetPresenter {
    let model: WorkspaceModel
    @MainActor private struct Sheet {
        let coordinator = PiSheetWindowCoordinator()
        let wanted: @MainActor (WorkspaceModel) -> AnyHashable?
        let dismiss: @MainActor (WorkspaceModel, AnyHashable) -> Void
        let content: @MainActor (WorkspaceModel, AnyHashable) -> NSView?
    }
    private let sheets: [Sheet]
    init(model: WorkspaceModel) {
        self.model = model
        func flag(_ get: @escaping @MainActor (WorkspaceModel) -> Bool, _ clear: @escaping @MainActor (WorkspaceModel) -> Void,
                  _ content: @escaping @MainActor (WorkspaceModel) -> NSView?) -> Sheet {
            Sheet(wanted: { get($0) ? AnyHashable(true) : nil }, dismiss: { model, _ in clear(model) }, content: { model, _ in content(model) })
        }
        func item<Item: Identifiable>(_ get: @escaping @MainActor (WorkspaceModel) -> Item?, _ clear: @escaping @MainActor (WorkspaceModel) -> Void,
                                      _ content: @escaping @MainActor (WorkspaceModel, Item) -> NSView) -> Sheet {
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
                ProfileSettingsView(model: model, controller: model.settingsSheetEditor(), windowChrome: false, dismiss: { [weak model] in model?.showProfiles = false })
            },
            flag({ $0.showConversationContent }, { $0.showConversationContent = false }) { model in
                model.contentSessionID.map { ConversationContentView(model: model, sessionID: $0, dismiss: { [weak model] in model?.showConversationContent = false }) }
            },
            flag({ $0.showResources }, { $0.showResources = false }) { model in ResourceInspector(model: model, dismiss: { [weak model] in model?.showResources = false }) },
            flag({ $0.showWorkspaceManager }, { $0.showWorkspaceManager = false }) { model in WorkspaceManagerSheetView(model: model, dismiss: { [weak model] in model?.showWorkspaceManager = false }) },
            item({ $0.renameTarget }, { $0.renameTarget = nil }) { model, target in RenameChatSheetView(model: model, chatID: target.id, dismiss: { [weak model] in if model?.renameTarget?.id == target.id { model?.renameTarget = nil } }) },
            item({ $0.topicEditor }, { $0.topicEditor = nil }) { model, target in TopicSheetView(model: model, target: target, dismiss: { [weak model] in if model?.topicEditor?.id == target.id { model?.topicEditor = nil } }) },
            item({ $0.webhookPreviewTarget }, { $0.webhookPreviewTarget = nil }) { model, target in WebhookPreviewSheetView(model: model, chatID: target.id, dismiss: { [weak model] in if model?.webhookPreviewTarget?.id == target.id { model?.webhookPreviewTarget = nil } }) },
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
