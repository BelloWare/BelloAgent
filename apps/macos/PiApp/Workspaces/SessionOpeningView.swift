import AppKit

/// A delayed status strip, floated above the composer without taking room
/// from the transcript. It fills only a loading cover that was already due.
@MainActor final class SessionOpeningView: NSView {
    static let stripHeight: CGFloat = 60
    private let title = shellLine("Opening chat…", font: PiKit.Font.body, color: .piInk)
    let progress = PiKit.ProgressBar(value: 0)
    let action = PiKit.Button("Cancel", style: .secondary, compact: true)
    var visibilityChanged: (() -> Void)?
    var inCover = false { didSet { if inCover != oldValue { needsLayout = true; needsDisplay = true } } }
    private var state: SessionOpeningState?
    private var sessionID: String?
    private var delay: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        wantsLayer = true; isHidden = true
        for view in [title, progress, action] as [NSView] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityIdentifier("sessionOpening")
        progress.setAccessibilityLabel("Opening chat")
        action.setAccessibilityIdentifier("cancelSessionOpening")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = piCGColor(inCover ? .piContent : .piSurface)
        layer?.cornerRadius = inCover ? 0 : PiRadius.sm
        layer?.borderWidth = inCover ? 0 : 1 / piScale
        layer?.borderColor = piCGColor(.piHairline)
    }

    func update(_ next: SessionOpeningState?, sessionID: String, cancel: @escaping () -> Void) {
        let beginning = self.sessionID != sessionID || state == nil
        self.sessionID = sessionID
        state = next?.active == true ? next : nil
        guard let state else {
            delay?.cancel(); delay = nil; isHidden = true
            return
        }
        progress.value = state.progress?.fraction ?? 0
        title.line.text = state.cancelling ? "Cancelling opening…" : "Opening chat…" + (state.progress.map { " \(Int($0.fraction * 100))%" } ?? "")
        action.isEnabled = !state.cancelling; action.onPress = cancel
        if beginning {
            delay?.cancel(); isHidden = true
            delay = Task { [weak self] in
                try? await Task.sleep(for: ConversationPaneView.coverDelay)
                guard let self, !Task.isCancelled, self.state?.active == true else { return }
                self.isHidden = false; self.visibilityChanged?()
            }
        }
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() {
        super.layout()
        let width = inCover ? min(360, max(0, bounds.width - PiSpacing.lg * 2)) : bounds.width
        let x = (bounds.width - width) / 2 + PiSpacing.md
        let y = inCover ? max(0, (bounds.height - Self.stripHeight) / 2) : 0
        let button = action.intrinsicContentSize, row = max(28, button.height)
        action.frame = CGRect(x: x + width - PiSpacing.md * 2 - button.width, y: y + PiSpacing.sm, width: button.width, height: row)
        title.frame = CGRect(x: x, y: y + PiSpacing.sm + (row - title.intrinsicContentSize.height) / 2,
            width: max(0, action.frame.minX - x - PiSpacing.sm), height: title.intrinsicContentSize.height)
        progress.frame = CGRect(x: x, y: y + PiSpacing.sm + row, width: max(0, width - PiSpacing.md * 2), height: PiKit.ProgressBar.room)
    }
}
