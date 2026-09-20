import SwiftUI

// The bridge between which page the window shows and what AppKit does about
// first responders and visibility. Opacity and SwiftUI hit testing do not
// resign an NSTextView's first-responder status by themselves.

/// Opacity and SwiftUI hit testing do not resign an NSTextView's first
/// responder. Hide the existing native surfaces without dismantling them, and
/// move keyboard focus onto the report's responder chain. Only page/window
/// transitions walk the native view tree; streaming does not trigger scans.
struct ConversationPageVisibility: NSViewRepresentable {
    let reportVisible: Bool
    let focusIdentity: String?
    let closeReport: () -> Void
    func makeNSView(context: Context) -> ConversationPageVisibilityView { ConversationPageVisibilityView() }
    func updateNSView(_ view: ConversationPageVisibilityView, context: Context) {
        view.closeReport = closeReport
        view.update(reportVisible: reportVisible, focusIdentity: focusIdentity)
    }
    static func dismantleNSView(_ view: ConversationPageVisibilityView, coordinator: ()) { view.restoreNativeViews(restoreFocus: false) }
}

@MainActor final class ConversationPageVisibilityView: NSView {
    private struct HiddenView { weak var view: NSView?; let wasHidden: Bool }
    private var hiddenViews: [HiddenView] = []
    private weak var previousResponder: NSResponder?
    private weak var appliedWindow: NSWindow?
    private var previousFocusIdentity: String?
    private var focusIdentity: String?
    private var reportVisible = false
    private var appliedReportVisible: Bool?
    private var revision = 0
    var closeReport: (() -> Void)?
    override var acceptsFirstResponder: Bool { reportVisible }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyVisibility() }
    func update(reportVisible: Bool, focusIdentity: String?) {
        self.reportVisible = reportVisible; self.focusIdentity = focusIdentity
        applyVisibility()
    }
    private func applyVisibility() {
        guard appliedReportVisible != reportVisible || appliedWindow !== window else { return }
        revision += 1
        if appliedWindow !== window { restoreNativeViews(restoreFocus: false) }
        appliedWindow = window; appliedReportVisible = reportVisible
        guard let window else { return }
        if reportVisible {
            previousFocusIdentity = focusIdentity
            hideNativeViews(in: window, takeFocus: true)
            let expected = revision
            // The initial SwiftUI mount may attach this background before its
            // native siblings. One deferred pass captures those same instances.
            Task { @MainActor [weak self, weak window] in
                await Task.yield()
                guard let self, let window, self.revision == expected, self.reportVisible else { return }
                self.hideNativeViews(in: window, takeFocus: false)
            }
        } else { restoreNativeViews(restoreFocus: true) }
    }
    private func hideNativeViews(in window: NSWindow, takeFocus: Bool) {
        guard let content = window.contentView else { return }
        func nativeViews(_ view: NSView) -> [NSView] {
            if view is ComposerTextView || view is TranscriptNativeScrollView { return [view] }
            return view.subviews.flatMap { nativeViews($0) }
        }
        let views = nativeViews(content)
        let responderView = window.firstResponder as? NSView
        let hasConversationFocus = responderView.map { responder in views.contains { responder === $0 || responder.isDescendant(of: $0) } } ?? false
        if hasConversationFocus {
            previousResponder = window.firstResponder
            window.makeFirstResponder(self)
        } else if takeFocus, window.attachedSheet == nil { window.makeFirstResponder(self) }
        for view in views where !hiddenViews.contains(where: { $0.view === view }) {
            hiddenViews.append(HiddenView(view: view, wasHidden: view.isHidden))
            view.isHidden = true
        }
    }
    func restoreNativeViews(restoreFocus: Bool) {
        for hidden in hiddenViews { hidden.view?.isHidden = hidden.wasHidden }
        let restoredConversation = hiddenViews.contains { !$0.wasHidden }
        hiddenViews.removeAll()
        if restoreFocus, previousFocusIdentity == focusIdentity, let responder = previousResponder as? NSView,
           responder.window === window, !responder.isHiddenOrHasHiddenAncestor, window?.attachedSheet == nil {
            window?.makeFirstResponder(responder)
        } else if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        previousResponder = nil; previousFocusIdentity = nil
        if restoredConversation {
            let restored = window
            DispatchQueue.main.async { NotificationCenter.default.post(name: TranscriptReadVisibility.didRestoreNativeView, object: restored) }
        }
    }
    override func cancelOperation(_ sender: Any?) {
        if reportVisible { closeReport?() } else { super.cancelOperation(sender) }
    }
    override func keyDown(with event: NSEvent) {
        if reportVisible, event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty { cancelOperation(nil) }
        else { super.keyDown(with: event) }
    }
}
