import AppKit

/// The legacy History browser's removable branch filter. The History stream
/// can instead receive GitController.onShowBranchHistory and use its own chips.
@MainActor final class GitBranchHistoryChip: NSView {
    private let label = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInk))
    private let remove = PiKit.IconButton(symbol: "xmark", label: "Clear branch history filter", size: 24)
    private let fill = PiKit.Box(fill: .piAccentSoft, cornerRadius: PiRadius.sm)
    var clear: (() -> Void)?
    var reference: String? {
        didSet {
            isHidden = reference == nil
            label.line.text = "Branch · " + (reference ?? "").replacingOccurrences(of: "refs/heads/", with: "").replacingOccurrences(of: "refs/remotes/", with: "")
            label.toolTip = reference
            remove.setAccessibilityLabel("Clear history filter for " + (reference ?? "branch"))
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame); label.truncation = .middle; isHidden = true
        for view in [fill, label, remove] as [NSView] { addSubview(view) }
        remove.onPress = { [weak self] in self?.clear?() }
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout(); fill.frame = bounds
        label.frame = CGRect(x: 8, y: 6, width: max(0, bounds.width - 40), height: 18)
        remove.frame = CGRect(x: max(0, bounds.width - 28), y: 2, width: 24, height: 24)
    }
}
