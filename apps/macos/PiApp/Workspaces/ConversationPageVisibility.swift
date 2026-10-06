import AppKit

// The bridge between what the window shows and what AppKit does about first
// responders and visibility. Opacity and SwiftUI hit testing do not resign an
// NSTextView's first-responder status by themselves.
//
// Two things cover native views that stay mounted: the report page covers
// every conversation and every tab's content, and a tab shown in the pane
// covers the chat's side (`RightPane`). One owner decides both, from what is
// wanted now, so neither undoes the other.

/// Opacity and SwiftUI hit testing do not resign an NSTextView's first
/// responder. Hide the existing native surfaces without dismantling them, and
/// move keyboard focus onto the report's responder chain, or from a covered
/// side to the tab over it. Only page, window and tab changes walk the
/// native view tree; streaming does not trigger scans.
@MainActor final class ConversationPageVisibilityView: NSView {
    private struct HiddenView { weak var view: NSView?; let wasHidden: Bool }
    private var hiddenViews: [HiddenView] = []
    /// Where focus was when the report came, and when a file covered a side.
    private weak var previousResponder: NSResponder?
    private weak var coveredResponder: NSResponder?
    private weak var appliedWindow: NSWindow?
    private var previousFocusIdentity: String?
    private var focusIdentity: String?
    private var reportVisible = false
    private var appliedReportVisible: Bool?
    private var appliedCovered: Set<String> = []
    private var covered: Set<String> = []
    /// A tab's content came into the window: walk it again.
    private var rescan = false
    private var attachObserver: NSObjectProtocol?
    private var revision = 0
    var closeReport: (() -> Void)?
    var contentFocus: () -> NSView? = { nil }
    override var acceptsFirstResponder: Bool { reportVisible }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private var applyScheduled = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let attachObserver { NotificationCenter.default.removeObserver(attachObserver) }
        attachObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: TabContentContainer.didAttach, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.rescan = true
                    self.scheduleVisibility()
                }
            }
        }
        scheduleVisibility()
    }
    func update(reportVisible: Bool, focusIdentity: String?, covered: Set<String> = []) {
        self.reportVisible = reportVisible; self.focusIdentity = focusIdentity; self.covered = covered
        scheduleVisibility()
    }
    /// Both callers run inside SwiftUI's update of the window. Moving the
    /// first responder from there made the composer's text view commit a Core
    /// Animation transaction that laid the window out again in the middle of
    /// its update ("NSHostingView is being laid out reentrantly while
    /// rendering its SwiftUI content"). The page's native views are hidden
    /// and focus moves on the next turn of the run loop instead.
    private func scheduleVisibility() {
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyScheduled = false
            self.applyVisibility()
        }
    }
    private func applyVisibility() {
        let coveredNow = reportVisible ? appliedCovered : covered
        guard appliedReportVisible != reportVisible || appliedWindow !== window || appliedCovered != coveredNow || rescan else { return }
        rescan = false
        revision += 1
        if appliedWindow !== window { restoreNativeViews(restoreFocus: false) }
        let reportCame = reportVisible && appliedReportVisible != true, reportWent = !reportVisible && appliedReportVisible == true
        appliedWindow = window; appliedReportVisible = reportVisible; appliedCovered = coveredNow
        guard let window else { return }
        if reportCame { previousFocusIdentity = focusIdentity }
        apply(in: window, takeFocus: reportCame, reportWent: reportWent)
        if reportVisible || !coveredNow.isEmpty {
            // The initial SwiftUI mount may attach this background before its
            // native siblings. One deferred pass captures those same instances.
            let expected = revision
            Task { @MainActor [weak self, weak window] in
                await Task.yield()
                guard let self, let window, self.revision == expected else { return }
                self.apply(in: window, takeFocus: false, reportWent: false)
            }
        }
    }
    /// What should be hidden now: everything native under the report, and
    /// under a file the side it covers.
    private func wanted(in window: NSWindow) -> [NSView] {
        guard let content = window.contentView else { return [] }
        let report = reportVisible, covered = appliedCovered
        func find(_ view: NSView) -> [NSView] {
            if let composer = view as? ComposerTextView { return report || covered.contains(composer.sessionID) ? [composer] : [] }
            if let transcript = view as? TranscriptNativeScrollView {
                let id = (transcript.documentView as? TranscriptNativeDocument)?.shownSessionID
                return report || (id.map { covered.contains($0) } ?? false) ? [transcript] : []
            }
            // Every tab's content, of whatever kind, under the report.
            if view is TabContentContainer { return report ? [view] : [] }
            return view.subviews.flatMap { find($0) }
        }
        return find(content)
    }
    private func apply(in window: NSWindow, takeFocus: Bool, reportWent: Bool) {
        let views = wanted(in: window)
        let hiding = views.filter { view in !hiddenViews.contains { $0.view === view } }
        let responder = window.firstResponder as? NSView
        let losesFocus = responder.map { responder in hiding.contains { responder === $0 || responder.isDescendant(of: $0) } } ?? false
        if reportVisible {
            if losesFocus {
                previousResponder = window.firstResponder
                window.makeFirstResponder(self)
            } else if takeFocus, window.attachedSheet == nil { window.makeFirstResponder(self) }
        } else if losesFocus {
            // A tab came over the side being typed in: the tab takes the keys.
            coveredResponder = window.firstResponder
            if let target = contentFocus(), target.window === window, !target.isHiddenOrHasHiddenAncestor { window.makeFirstResponder(target) }
            else { window.makeFirstResponder(nil) }
        }
        for view in hiding {
            hiddenViews.append(HiddenView(view: view, wasHidden: view.isHidden))
            view.isHidden = true
        }
        // What is no longer covered shows again.
        let keep = Set(views.map(ObjectIdentifier.init))
        var shown: [NSView] = []
        hiddenViews.removeAll { hidden in
            guard let view = hidden.view else { return true }
            guard !keep.contains(ObjectIdentifier(view)) else { return false }
            view.isHidden = hidden.wasHidden
            if !hidden.wasHidden { shown.append(view) }
            return true
        }
        if reportWent { restoreFocus(from: &previousResponder, identityMatches: previousFocusIdentity == focusIdentity) }
        else if !reportVisible, !shown.isEmpty {
            // Back to the side only if focus has not gone elsewhere since:
            // it is where it was put (the tab's content, now gone), or nowhere.
            let current = window.firstResponder
            let unclaimed = current == nil || current === window || (current as? NSView).map { $0.window == nil || $0.isHiddenOrHasHiddenAncestor } == true
                || (current as? NSView).map { WindowPresentationController.inTabContent($0) } == true
            if unclaimed { restoreFocus(from: &coveredResponder, identityMatches: true) } else { coveredResponder = nil }
        }
        if reportWent { previousFocusIdentity = nil }
        if shown.contains(where: { $0 is TranscriptNativeScrollView }) {
            let restored = window
            DispatchQueue.main.async { NotificationCenter.default.post(name: TranscriptReadVisibility.didRestoreNativeView, object: restored) }
        }
    }
    private func restoreFocus(from saved: inout NSResponder?, identityMatches: Bool) {
        defer { saved = nil }
        if identityMatches, let responder = saved as? NSView, let window, responder.window === window,
           !responder.isHiddenOrHasHiddenAncestor, window.attachedSheet == nil {
            window.makeFirstResponder(responder)
        } else if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }
    func restoreNativeViews(restoreFocus: Bool) {
        for hidden in hiddenViews { hidden.view?.isHidden = hidden.wasHidden }
        let restoredConversation = hiddenViews.contains { !$0.wasHidden && $0.view is TranscriptNativeScrollView }
        hiddenViews.removeAll()
        if restoreFocus { self.restoreFocus(from: &previousResponder, identityMatches: previousFocusIdentity == focusIdentity) }
        else if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        previousResponder = nil; coveredResponder = nil; previousFocusIdentity = nil
        appliedReportVisible = nil; appliedCovered = []
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
