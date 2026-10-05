import AppKit

/// The Settings window. The window is kept after it closes, to show it
/// again, and a form left in it went on following every change to the
/// model for the rest of the launch. The form is taken down while the
/// window is closed and put back when it opens; its edits wait in the
/// controller kept here, so a closed window still opens on what the reader
/// left unsaved.
@MainActor final class SettingsWindowView: NSView {
    let model: WorkspaceModel
    let controller: ConnectionSettingsController
    private var form: ProfileSettingsView?
    private let guardian: SettingsCloseGuard
    private var open = true

    init(model: WorkspaceModel) {
        self.model = model
        controller = ConnectionSettingsController(model: model)
        guardian = SettingsCloseGuard(controller)
        super.init(frame: NSRect(x: 0, y: 0, width: 880, height: 780))
        showForm()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 880, height: 780) }

    private func showForm() {
        guard form == nil else { return }
        // The window closes itself; nothing else does.
        let form = ProfileSettingsView(model: model, controller: controller, windowChrome: true, dismiss: { [weak self] in self?.window?.performClose(nil) })
        form.frame = bounds; form.autoresizingMask = [.width, .height]
        addSubview(form)
        self.form = form
    }
    private func hideForm() { form?.removeFromSuperview(); form = nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        // Outside the form, which is taken down while the window is closed.
        guardian.attach(window)
        guard let window else { return }
        // The window's own title bar gives way to the sheet's header, once the
        // scene has set the window up (it does so after its content arrives).
        window.applyPiWindowChrome()
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.window?.applyPiWindowChrome() } }
        NotificationCenter.default.addObserver(self, selector: #selector(closing), name: NSWindow.willCloseNotification, object: window)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didChangeOcclusionStateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(shown), name: name, object: window)
        }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    // Covered or minimised, a window is still open: only its close takes the
    // form down. Changed on the next turn, out of AppKit's own window handling.
    @objc private func closing() {
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated {
            guard let self, self.window?.isVisible != true else { return }
            self.setOpen(false)
        } }
    }
    @objc private func shown() {
        guard window?.isVisible == true else { return }
        window?.applyPiWindowChrome()
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.setOpen(true) } }
    }
    private func setOpen(_ value: Bool) {
        guard open != value else { return }
        open = value
        if value { showForm() } else { hideForm() }
    }
}

/// The Settings window's close button and ⌘W: unsaved edits ask Save All,
/// Discard Changes or Keep Editing first, and a save under way keeps the
/// window open. The window's own delegate still decides after.
@MainActor final class SettingsCloseGuard: NSObject, NSWindowDelegate {
    let controller: ConnectionSettingsController
    // AppKit sets and reads delegates on the main thread; forwarding only reads this.
    nonisolated(unsafe) weak var previous: NSWindowDelegate?
    weak var window: NSWindow?
    /// The one close this guard has already agreed to, for that window.
    private weak var approved: NSWindow?
    init(_ controller: ConnectionSettingsController) { self.controller = controller }
    func attach(_ window: NSWindow?) {
        guard let window, window.delegate !== self else { return }
        detach()
        self.window = window; previous = window.delegate; window.delegate = self
    }
    func detach() {
        if let window, window.delegate === self { window.delegate = previous }
        window = nil; previous = nil
    }
    nonisolated override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || previous?.responds(to: selector) == true }
    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? { previous }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if approved === sender { approved = nil; return previous?.windowShouldClose?(sender) ?? true }
        // Clean and idle: close as before, without a turn of the run loop.
        if !controller.saving, !controller.deciding, !controller.isDirty { return previous?.windowShouldClose?(sender) ?? true }
        // AppKit is inside its close decision: refuse now, ask on a sheet,
        // and close again once the reader has chosen.
        Task { @MainActor [weak self, weak sender] in
            guard let self, let sender, await self.controller.requestClose(), sender.isVisible else { return }
            self.approved = sender
            sender.performClose(nil)
        }
        return false
    }
}
