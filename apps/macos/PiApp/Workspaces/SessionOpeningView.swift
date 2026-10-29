import AppKit

/// The helper's opening state, over the same canvas as the existing loading
/// cover. Bytes remain an implementation detail; the reader sees a percentage
/// of the known work and can leave the open without losing their draft.
@MainActor final class SessionOpeningView: NSView {
    private let title = shellLine("Opening chat…", font: PiKit.Font.heading, color: .labelColor)
    private let detail = ShellSelectableText("", font: PiKit.Font.caption, color: .piInkSecondary)
    let progress = PiKit.ProgressBar(value: 0)
    let action = PiKit.Button("Cancel", style: .secondary, compact: true)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for view in [title, detail, progress, action] as [NSView] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityIdentifier("sessionOpening")
        progress.setAccessibilityLabel("Opening chat")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piContent) }

    func update(_ state: SessionOpeningState, cancel: @escaping () -> Void, retry: @escaping () -> Void) {
        progress.isHidden = state.progress == nil
        progress.value = state.progress?.fraction ?? 0
        action.isEnabled = !state.cancelling
        switch state {
        case .opening(let work):
            title.line.text = "Opening chat…"
            detail.text = work.map { "Reading saved conversation · \(Int($0.fraction * 100))%" } ?? "Preparing the saved conversation…"
            action.title = "Cancel"; action.onPress = cancel
        case .cancelling:
            title.line.text = "Cancelling opening…"
            detail.text = "Your conversation and unsent message are kept."
            action.title = "Cancel"; action.onPress = cancel
        case .cancelled:
            title.line.text = "Opening cancelled"
            detail.text = "Your conversation is saved. You can open it again."
            action.title = "Retry"; action.onPress = retry
        case .failed(let error):
            title.line.text = "Couldn’t open this chat"
            detail.text = error
            action.title = "Retry"; action.onPress = retry
        }
        action.setAccessibilityIdentifier(state.active ? "cancelSessionOpening" : "retrySessionOpening")
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() {
        super.layout()
        let width = min(360, max(0, bounds.width - PiSpacing.lg * 2)), scale = piScale
        let titleHeight = title.intrinsicContentSize.height, textHeight = detail.height(forWidth: width)
        let barHeight = progress.isHidden ? 0 : PiKit.ProgressBar.room + PiSpacing.md
        let button = action.intrinsicContentSize
        let height = titleHeight + PiSpacing.md + textHeight + PiSpacing.md + barHeight + button.height
        var y = PiKit.round(max(PiSpacing.lg, (bounds.height - height) / 2), scale)
        let x = PiKit.round((bounds.width - width) / 2, scale)
        let titleWidth = min(width, title.intrinsicContentSize.width)
        title.frame = CGRect(x: PiKit.round((bounds.width - titleWidth) / 2, scale), y: y, width: titleWidth, height: titleHeight)
        y += titleHeight + PiSpacing.md
        detail.frame = CGRect(x: x, y: y, width: width, height: textHeight)
        y += textHeight + PiSpacing.md
        if !progress.isHidden { progress.frame = CGRect(x: x, y: y, width: width, height: PiKit.ProgressBar.room); y += barHeight }
        action.frame = CGRect(x: PiKit.round((bounds.width - button.width) / 2, scale), y: y, width: button.width, height: button.height)
    }
}
