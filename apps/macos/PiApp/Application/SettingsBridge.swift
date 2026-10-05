import AppKit
import SwiftUI

// Temporary (0.1.120): where the settings and onboarding screens, now
// AppKit, meet SwiftUI. Their SwiftUI hosts (the sheet `WorkspaceView`
// presents, the `Settings` scene in PiApp) take them through the
// representables below, and they host two SwiftUI views other workstreams
// own (`CatalogModelPicker`, `WorkspaceFolderList`).
// Each goes when its other side is AppKit.

/// The Settings sheet's content, as `WorkspaceView` presents it.
struct ProfileSettings: View {
    let model: WorkspaceModel
    var windowChrome = false
    @StateObject private var controller: ConnectionSettingsController
    @PiDismiss private var dismiss
    init(model: WorkspaceModel, windowChrome: Bool = false) {
        self.init(model: model, controller: ConnectionSettingsController(model: model), windowChrome: windowChrome)
    }
    /// With the edits a caller keeps (`SettingsWindowContent`).
    init(model: WorkspaceModel, controller: @autoclosure @escaping () -> ConnectionSettingsController, windowChrome: Bool) {
        self.model = model; self.windowChrome = windowChrome
        _controller = StateObject(wrappedValue: controller())
    }
    var body: some View {
        let dismiss = dismiss
        ProfileSettingsHost(model: model, controller: controller, windowChrome: windowChrome, dismiss: { dismiss() })
    }
}

private struct ProfileSettingsHost: NSViewRepresentable {
    let model: WorkspaceModel
    let controller: ConnectionSettingsController
    let windowChrome: Bool
    let dismiss: () -> Void
    func makeNSView(context: Context) -> ProfileSettingsView {
        ProfileSettingsView(model: model, controller: controller, windowChrome: windowChrome, dismiss: dismiss)
    }
    func updateNSView(_ view: ProfileSettingsView, context: Context) {}
}

/// The Settings window's content, as the `Settings` scene shows it.
struct SettingsWindowContent: View {
    let model: WorkspaceModel
    var body: some View { SettingsWindowHost(model: model).frame(width: 880, height: 780) }
}
private struct SettingsWindowHost: NSViewRepresentable {
    let model: WorkspaceModel
    func makeNSView(context: Context) -> SettingsWindowView { SettingsWindowView(model: model) }
    func updateNSView(_ view: SettingsWindowView, context: Context) {}
}

/// The first-launch flow, as `WorkspaceView` shows it.
struct OnboardingView: View {
    let model: WorkspaceModel
    /// Under the title bar too, as the SwiftUI flow's scroll view reached.
    var body: some View { OnboardingHost(model: model).ignoresSafeArea() }
}
private struct OnboardingHost: NSViewRepresentable {
    let model: WorkspaceModel
    func makeNSView(context: Context) -> OnboardingContentView { OnboardingContentView(model: model) }
    func updateNSView(_ view: OnboardingContentView, context: Context) {}
}

/// Hands the window this view is in to `found`, as it moves between windows.
@MainActor struct HostingWindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> ReaderView { let view = ReaderView(); view.found = found; return view }
    func updateNSView(_ view: ReaderView, context: Context) { view.found = found }
    @MainActor final class ReaderView: NSView {
        var found: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); found?(window) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A hosted SwiftUI view, as the AppKit screens hold it.
typealias HostedSwiftUI = SettingsBridges.Hosted<AnyView>

/// SwiftUI views other workstreams own, hosted in the AppKit screens.
@MainActor enum SettingsBridges {
    /// A hosted SwiftUI view, sized to the width it is given; `update`
    /// shows it again with what its closures read now.
    final class Hosted<Content: View>: NSView, PiKit.WidthSizing, ProposedWidthSizing {
        private let host: NSHostingController<AnyView>
        private let make: () -> Content
        private var observation: NSKeyValueObservation?
        /// The form's state: SwiftUI's `.disabled` over the hosted view.
        var disabled = false { didSet { if oldValue != disabled { update() } } }
        init(_ make: @escaping () -> Content) {
            self.make = make
            host = NSHostingController(rootView: AnyView(make()))
            super.init(frame: .zero)
            // The hosted view's own size, as it changes (an editor opening):
            // the AppKit layout around it asks again.
            host.sizingOptions = [.preferredContentSize]
            observation = host.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { guard let self else { return }; self.invalidateIntrinsicContentSize(); PiKit.sizeChanged(self) } }
            }
            addSubview(host.view)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var isFlipped: Bool { true }
        func update() { host.rootView = AnyView(make().disabled(disabled)); invalidateIntrinsicContentSize(); PiKit.sizeChanged(self) }
        /// Measured on the view on screen, with its own state (an open editor).
        private func size(_ width: CGFloat) -> CGSize { host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)) }
        func height(forWidth width: CGFloat) -> CGFloat { ceil(size(width).height) }
        /// Its own width when offered `proposal`, as SwiftUI sizes it: a flow is
        /// as wide as its widest row there.
        func width(forProposal proposal: CGFloat) -> CGFloat { ceil(size(proposal).width) }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 380)) }
        override func layout() { super.layout(); host.view.frame = bounds }
    }

    /// The catalog's models in a popover: `CatalogModelPicker` (workspace shell).
    static func catalogPicker(model: WorkspaceModel, profile: ProfileRecord, current: String?, draft: CatalogModelPicker.DraftListing?,
                              defaultTitle: String?, defaultSelected: Bool, useDefault: (() -> Void)?,
                              choose: @escaping (ModelDescriptor) -> Void) -> NSViewController {
        NSHostingController(rootView: CatalogModelPicker(model: model, profile: profile, current: current, draft: draft, defaultTitle: defaultTitle,
                                                         defaultSelected: defaultSelected, useDefault: useDefault, choose: choose))
    }

    /// A project's folders: `WorkspaceFolderList` (workspace shell).
    static func folderList(model: WorkspaceModel, workspace: @escaping () -> WorkspaceRecord?, onError: @escaping (String) -> Void) -> Hosted<AnyView> {
        Hosted {
            guard let current = workspace() else { return AnyView(EmptyView()) }
            return AnyView(WorkspaceFolderList(model: model, workspace: current, onError: onError).buttonStyle(.piSecondary))
        }
    }
}
