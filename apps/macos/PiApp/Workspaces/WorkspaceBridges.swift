import SwiftUI

// TEMPORARY: where SwiftUI still hosts the workspace shell's AppKit views —
// the sheets presented in the app's SwiftUI sheet window, Settings' pieces
// (Application/SettingsBridge.swift), and the sidebar in tests that lay it
// out in SwiftUI — and the cost-limit popover that hosts the Dashboard's
// SwiftUI editor. Each goes when its other side is AppKit.

/// `WorkspaceSidebarView` where SwiftUI lays it out (TranscriptFrameBudgetTests).
struct WorkspaceSidebar: NSViewRepresentable {
    let model: WorkspaceModel
    var width: CGFloat = WindowChrome.sidebarWidth
    func makeNSView(context: Context) -> WorkspaceSidebarView {
        let view = WorkspaceSidebarView(model: model, width: width)
        view.inheritedEnabled = context.environment.isEnabled
        return view
    }
    func updateNSView(_ view: WorkspaceSidebarView, context: Context) {
        view.width = width
        view.inheritedEnabled = context.environment.isEnabled
    }
}

/// The sheets the workspace view presents (`piSheetWindow`), now AppKit.
struct RenameChatSheet: View {
    let model: WorkspaceModel
    let chatID: String
    @PiDismiss private var dismiss
    var body: some View {
        let dismiss = dismiss
        AppKitSheet { RenameChatSheetView(model: model, chatID: chatID, dismiss: { dismiss() }) }
            .frame(width: RenameChatSheetView.size.width, height: RenameChatSheetView.size.height)
    }
}
struct TopicSheet: View {
    let model: WorkspaceModel
    let target: TopicEditorTarget
    @PiDismiss private var dismiss
    var body: some View {
        let dismiss = dismiss
        AppKitSheet { TopicSheetView(model: model, target: target, dismiss: { dismiss() }) }
            .frame(width: TopicSheetView.size.width, height: TopicSheetView.size.height)
    }
}
/// An AppKit sheet's view, made once, in a sheet SwiftUI presents.
struct AppKitSheet<Sheet: NSView>: NSViewRepresentable {
    let make: () -> Sheet
    func makeNSView(context: Context) -> Sheet {
        let view = make()
        (view as? InheritsEnabled)?.inheritedEnabled = context.environment.isEnabled
        return view
    }
    func updateNSView(_ view: Sheet, context: Context) { (view as? InheritsEnabled)?.inheritedEnabled = context.environment.isEnabled }
}
struct WebhookPreviewSheet: View {
    let model: WorkspaceModel
    let chatID: String
    @PiDismiss private var dismiss
    var body: some View {
        let dismiss = dismiss
        AppKitSheet { WebhookPreviewSheetView(model: model, chatID: chatID, dismiss: { dismiss() }) }
            .frame(width: WebhookPreviewSheetView.size.width, height: WebhookPreviewSheetView.size.height)
    }
}

/// Presents an AppKit sheet's view in the app's sheet window, which still
/// takes SwiftUI content (`PiSheetWindow`, Application/).
@MainActor enum AppKitSheets {
    static func present(on parent: NSWindow, size: NSSize, enabled: Bool = true, make: @escaping (_ dismiss: @escaping () -> Void) -> NSView) -> PiSheetWindow {
        weak var shown: PiSheetWindow?
        let close: @MainActor () -> Void = { shown?.end(animated: true, requested: true) }
        let sheet = PiSheetWindow(content: AnyView(AppKitSheet { make(close) }.frame(width: size.width, height: size.height)),
                                  inherited: PiSheetWindowInherited(reduceMotion: PiKit.Motion.reduced, enabled: enabled), close: close)
        shown = sheet
        sheet.present(on: parent)
        return sheet
    }
}

/// The catalog picker where SwiftUI still hosts it (Settings' popover,
/// Application/SettingsBridge.swift): the AppKit picker, as tall as it is.
struct CatalogModelPicker: View {
    typealias DraftListing = CatalogModelPickerView.DraftListing
    let model: WorkspaceModel
    let profile: ProfileRecord
    let current: String?
    var draft: DraftListing? = nil
    var allowsCatalogSelection = false
    var defaultTitle: String?
    var defaultSelected = false
    var useDefault: (() -> Void)?
    var manualEntry: ((String) -> Void)?
    let choose: (ModelDescriptor) -> Void
    init(model: WorkspaceModel, profile: ProfileRecord, current: String?, draft: DraftListing? = nil, allowsCatalogSelection: Bool = false,
         defaultTitle: String? = nil, defaultSelected: Bool = false,
         useDefault: (() -> Void)? = nil, manualEntry: ((String) -> Void)? = nil, choose: @escaping (ModelDescriptor) -> Void) {
        self.model = model; self.profile = profile; self.current = current; self.draft = draft
        self.allowsCatalogSelection = allowsCatalogSelection; self.defaultTitle = defaultTitle; self.defaultSelected = defaultSelected
        self.useDefault = useDefault; self.manualEntry = manualEntry; self.choose = choose
    }
    static func filtered(_ models: [ModelDescriptor], query: String) -> [ModelDescriptor] { CatalogModelPickerView.filtered(models, query: query) }
    static func sourceLabel(_ profile: ProfileRecord) -> String { CatalogModelPickerView.sourceLabel(profile) }
    var body: some View {
        Host(picker: self)
    }
    private struct Host: NSViewRepresentable {
        let picker: CatalogModelPicker
        func makeNSView(context: Context) -> CatalogModelPickerView {
            let view = CatalogModelPickerView(model: picker.model, profile: picker.profile, current: picker.current, draft: picker.draft,
                                              allowsCatalogSelection: picker.allowsCatalogSelection, defaultTitle: picker.defaultTitle,
                                              defaultSelected: picker.defaultSelected, useDefault: picker.useDefault,
                                              manualEntry: picker.manualEntry, choose: picker.choose)
            view.inheritedEnabled = context.environment.isEnabled
            view.sizeChanged = { [weak view] in view?.invalidateIntrinsicContentSize() }
            return view
        }
        /// New inputs reach the picker; its search and alias field stay.
        func updateNSView(_ view: CatalogModelPickerView, context: Context) {
            view.update(profile: picker.profile, current: picker.current, draft: picker.draft, allowsCatalogSelection: picker.allowsCatalogSelection,
                        defaultTitle: picker.defaultTitle, defaultSelected: picker.defaultSelected, useDefault: picker.useDefault,
                        manualEntry: picker.manualEntry, choose: picker.choose)
            view.inheritedEnabled = context.environment.isEnabled
        }
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: CatalogModelPickerView, context: Context) -> CGSize? { nsView.intrinsicContentSize }
    }
}

/// The Projects sheet, now AppKit, where SwiftUI presents it (`piSheetWindow`).
struct WorkspaceManagerView: View {
    let model: WorkspaceModel
    @PiDismiss private var dismiss
    var body: some View {
        let dismiss = dismiss
        AppKitSheet { WorkspaceManagerSheetView(model: model, dismiss: { dismiss() }) }
            .frame(width: WorkspaceManagerSheetView.size.width, height: WorkspaceManagerSheetView.size.height)
    }
}

/// A project's folders where SwiftUI still hosts them (Settings and onboarding,
/// Application/SettingsBridge.swift): the AppKit list, as tall as it is.
struct WorkspaceFolderList: View {
    let model: WorkspaceModel
    let workspace: WorkspaceRecord
    var onError: (String) -> Void = { _ in }
    /// Another project is another list (`.id`), bound to that project.
    var body: some View { Host(model: model, workspaceID: workspace.id, onError: onError).id(workspace.id) }
    private struct Host: NSViewRepresentable {
        let model: WorkspaceModel
        let workspaceID: String
        let onError: (String) -> Void
        func makeNSView(context: Context) -> WorkspaceFolderListView {
            let view = WorkspaceFolderListView(model: model, workspaceID: workspaceID, onError: onError)
            view.inheritedEnabled = context.environment.isEnabled
            return view
        }
        func updateNSView(_ view: WorkspaceFolderListView, context: Context) {
            view.onError = onError
            view.inheritedEnabled = context.environment.isEnabled
        }
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: WorkspaceFolderListView, context: Context) -> CGSize? {
            let width = proposal.width ?? 480
            return CGSize(width: width, height: nsView.height(forWidth: width))
        }
    }
}

// TEMPORARY: the limit editor is the Dashboard workstream's SwiftUI
// `CostLimitLiveEditor`, shown in the shared SwiftUI popover presenter. It
// moves back beside the cost-limit model code once the editor is AppKit.
/// The popover "Raise limit…" opens over its button: the chat's limit editor.
/// One app-owned popover at a time, like the stats pills' and the skills'.
@MainActor final class CostLimitPopover {
    static let shared = CostLimitPopover()
    let presenter = PiPopoverPresenter()
    /// The chat whose limit the open popover edits (a test seam).
    private(set) var sessionID: String?
    static let width: CGFloat = 380
    func toggle(model: WorkspaceModel, footer: SessionMetrics, sessionID: String, anchor: NSView) {
        if presenter.isShown, self.sessionID == sessionID { close(); return }
        self.sessionID = sessionID
        let reduce = PiMotion.reducesMotion
        presenter.show(from: anchor, width: Self.width, maximumHeight: 460, animates: !reduce) {
            AnyView(CostLimitLiveEditor(footer: footer, title: "Raise this chat's limit", choose: { limit in
                try await model.setCostLimit(limit, for: sessionID)
                // Chosen: the popover has done its job.
                CostLimitPopover.shared.close()
            })
            .padding(PiSpacing.lg)
            .environment(\.piReduceMotion, reduce).tint(Color.piAccent))
        }
    }
    func close() { presenter.close(); sessionID = nil }
}
