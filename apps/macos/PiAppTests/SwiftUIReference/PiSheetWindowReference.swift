import SwiftUI
import AppKit
@testable import PiApp

/// Closes the sheet a view is in when the app presented it in a window of its
/// own (`piSheetWindow`). Nil in SwiftUI's own sheets, where `dismiss` does.
private struct PiSheetCloseKey: EnvironmentKey { static let defaultValue: (@MainActor () -> Void)? = nil }
extension EnvironmentValues {
    var piSheetClose: (@MainActor () -> Void)? {
        get { self[PiSheetCloseKey.self] }
        set { self[PiSheetCloseKey.self] = newValue }
    }
}

/// Closes the sheet a view is in, however it was presented: through the
/// window's own close in a `piSheetWindow`, and through SwiftUI's `dismiss`
/// in a `.sheet` or a window of its own (the ⌘, Settings window). A sheet
/// declares `@PiDismiss private var dismiss` and calls `dismiss()` as before.
@propertyWrapper struct PiDismiss: DynamicProperty {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.piSheetClose) private var sheetClose
    init() {}
    var wrappedValue: PiDismissAction { PiDismissAction(dismiss: dismiss, sheetClose: sheetClose) }
}
struct PiDismissAction {
    fileprivate let dismiss: DismissAction
    fileprivate let sheetClose: (@MainActor () -> Void)?
    @MainActor func callAsFunction() { if let sheetClose { sheetClose() } else { dismiss() } }
}

extension View {
    /// `.sheet(isPresented:)`, in a sheet window the app makes and lets go of
    /// whole once the sheet has closed. The sheet looks and closes as SwiftUI's
    /// does: the same window, sized to its content, on the same AppKit sheet.
    /// Its content is made as it opens; what it shows after that comes from
    /// what the content itself observes. (SwiftUI's own sheets seemed to keep
    /// every closed sheet's window and views, still observing the model, but
    /// only in tests: XCTest keeps whatever AppKit autoreleases until a test
    /// returns. In the app their windows go as they close, and at most the
    /// last closed sheet's views stay, no longer updated.)
    func piSheetWindow<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        background(PiSheetWindowAnchor(wanted: isPresented.wrappedValue ? AnyHashable(true) : nil,
                                       dismiss: { _ in isPresented.wrappedValue = false },
                                       content: { _ in AnyView(content()) }))
    }
    /// `.sheet(item:)`, in a sheet window of the app's own (see above): up
    /// while the item is set, closed and presented again for another item
    /// when its identity changes, and the item set to nil when the sheet
    /// closes itself.
    func piSheetWindow<Item: Identifiable, Content: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        background(PiSheetWindowAnchor(wanted: item.wrappedValue.map { AnyHashable($0.id) },
                                       dismiss: { identity in
                                           // Only the sheet still asked for: a closing one never clears its successor.
                                           if let current = item.wrappedValue, AnyHashable(current.id) == identity { item.wrappedValue = nil }
                                       },
                                       content: { identity in
                                           guard let current = item.wrappedValue, AnyHashable(current.id) == identity else { return nil }
                                           return AnyView(content(current))
                                       }))
    }
}

/// Where a `piSheetWindow` is presented from: the window it is in, and the
/// environment the sheet inherits, as a SwiftUI sheet inherits it from the
/// view that presents it.
private struct PiSheetWindowAnchor: NSViewRepresentable {
    /// Which sheet is asked for: its identity, or nil for none.
    let wanted: AnyHashable?
    let dismiss: (AnyHashable) -> Void
    let content: (AnyHashable) -> AnyView?

    func makeCoordinator() -> PiSheetWindowCoordinator { PiSheetWindowCoordinator() }
    func makeNSView(context: Context) -> PiSheetWindowAnchorView {
        let view = PiSheetWindowAnchorView()
        view.coordinator = context.coordinator
        return view
    }
    func updateNSView(_ view: PiSheetWindowAnchorView, context: Context) {
        context.coordinator.update(wanted: wanted,
                                   inherited: PiSheetWindowInherited(reduceMotion: context.environment.piReduceMotion, enabled: context.environment.isEnabled),
                                   dismiss: dismiss, content: { identity in content(identity).map { PiSheetWindowReferenceContent(content: $0) } })
    }
    static func dismantleNSView(_ view: PiSheetWindowAnchorView, coordinator: PiSheetWindowCoordinator) {
        coordinator.anchorGone()
    }
}


/// The values a presented sheet inherits and follows while it is up.
@MainActor final class PiSheetWindowSettings: ObservableObject {
    @Published var reduceMotion: Bool
    @Published var enabled: Bool
    init(_ inherited: PiSheetWindowInherited) { reduceMotion = inherited.reduceMotion; enabled = inherited.enabled }
}

/// The sheet's content with what it inherits from the view that presented it,
/// and the close action its Done and Escape use in place of `dismiss`.
struct PiSheetWindowRoot: View {
    let content: AnyView
    @ObservedObject var settings: PiSheetWindowSettings
    let close: @MainActor () -> Void
    var body: some View {
        content
            .environment(\.piReduceMotion, settings.reduceMotion)
            .disabled(!settings.enabled)
            .environment(\.piSheetClose, close)
    }
}

/// A test-only adapter lets the original SwiftUI fixtures exercise the native presenter.
@MainActor private final class PiSheetWindowReferenceContent: NSView, PiSheetWindowContent {
    private let settings = PiSheetWindowSettings(.init(reduceMotion: false, enabled: true))
    private let host: NSHostingView<PiSheetWindowRoot>
    init(content: AnyView) {
        host = NSHostingView(rootView: PiSheetWindowRoot(content: content, settings: settings, close: {}))
        super.init(frame: .zero)
        addSubview(host)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { host.fittingSize }
    override func layout() { super.layout(); host.frame = bounds }
    func inherit(_ values: PiSheetWindowInherited) {
        if settings.reduceMotion != values.reduceMotion { settings.reduceMotion = values.reduceMotion }
        if settings.enabled != values.enabled { settings.enabled = values.enabled }
    }
    func setClose(_ close: @escaping @MainActor () -> Void) {
        let root = host.rootView
        host.rootView = PiSheetWindowRoot(content: root.content, settings: settings, close: close)
    }
    func prepareForRelease() {
        host.rootView = PiSheetWindowRoot(content: AnyView(EmptyView()), settings: settings, close: {})
        host.layoutSubtreeIfNeeded(); host.display()
    }
}
