import AppKit
import SwiftUI
@testable import PiApp

extension PiPopoverPresenter {
    func toggle(from anchor: NSView, width: CGFloat, maximumHeight: CGFloat, animates: Bool, within wait: Duration,
                isReady: @escaping @MainActor () -> Bool, content: @escaping @MainActor () -> AnyView) {
        toggle(from: anchor, width: width, maximumHeight: maximumHeight, animates: animates, within: wait, isReady: isReady,
               view: { NSHostingView(rootView: content().frame(width: width)) })
    }

    func show(from anchor: NSView, width: CGFloat, maximumHeight: CGFloat, animates: Bool, content: () -> AnyView) {
        present(from: anchor, maximumHeight: maximumHeight, animates: animates) { height in
            let host = NSHostingController(rootView: AnyView(content().frame(width: width).frame(maxHeight: height, alignment: .top)))
            host.sizingOptions = [.preferredContentSize]
            return host
        }
    }
}

/// `PiPopoverTriggerButton` in a SwiftUI layout, sized to the face it covers.
struct PiPopoverTrigger: NSViewRepresentable {
    let label: String
    var identifier: String?
    var help: String
    let onHover: (Bool) -> Void
    let onPress: (NSView) -> Void

    func makeNSView(context: Context) -> PiPopoverTriggerButton {
        let button = PiPopoverTriggerButton(frame: .zero)
        apply(to: button)
        return button
    }
    func updateNSView(_ button: PiPopoverTriggerButton, context: Context) { apply(to: button) }
    private func apply(to button: PiPopoverTriggerButton) {
        button.onHover = onHover; button.onPress = onPress
        if button.toolTip != help { button.toolTip = help.isEmpty ? nil : help }
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
        if button.accessibilityIdentifier() != (identifier ?? "") { button.setAccessibilityIdentifier(identifier) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PiPopoverTriggerButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// A stat pill whose dialog is an app-owned popover: the pill's own face, an
/// AppKit press target over it, and a panel sized to the screen around it.
/// The face reads exactly as the composer's pills (`PiStatPillFace`); only the popover is different.
struct PiStatPopoverPill<Content: View>: View {
    let symbol: String
    let label: String
    /// A last figure in warning ink (see `PiStatPillFace.warningTail`).
    var warningTail: String? = nil
    var accessibility: String? = nil
    var identifier: String? = nil
    var help: String = ""
    @ObservedObject var presenter: PiPopoverPresenter
    var width: CGFloat = PiPopoverPanel.width
    var maximumHeight: CGFloat = PiPopoverPanel.maximumHeight
    /// Called on the press that opens the popover, before its content is built.
    var willOpen: () -> Void = {}
    /// Whether the content has what it needs to open whole; the popover waits
    /// up to `readyWithin` for it.
    var isReady: @MainActor () -> Bool = { true }
    var readyWithin: Duration = .milliseconds(250)
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    @Environment(\.piReduceMotion) private var reduceMotion

    var body: some View {
        PiStatPillFace(symbol: symbol, label: label, highlighted: hovering || presenter.isShown, warningTail: warningTail)
            .accessibilityElement(children: .ignore).accessibilityHidden(true)
            .overlay {
                PiPopoverTrigger(label: accessibility ?? label, identifier: identifier, help: help.isEmpty ? label : help,
                                 onHover: { hovering = $0 },
                                 onPress: { anchor in
                                     let opening = !presenter.isShown && !presenter.isOpening
                                     if opening { willOpen() }
                                     let reduce = reduceMotion, content = content
                                     presenter.toggle(from: anchor, width: width, maximumHeight: maximumHeight, animates: !reduce,
                                                      within: readyWithin, isReady: isReady) {
                                         AnyView(content().environment(\.piReduceMotion, reduce).tint(Color.piAccent))
                                     }
                                 })
            }
            // A pill that leaves the screen (another chat, a narrower pane)
            // takes its popover with it, one turn after SwiftUI's teardown.
            .onDisappear { [presenter] in Task { @MainActor in presenter.close() } }
    }
}

