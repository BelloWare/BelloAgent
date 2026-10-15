import AppKit

@MainActor final class SubagentHeaderView: NSView, PiKit.WidthSizing {
    private let back = PiKit.Button("Back to Parent", symbol: "chevron.left", style: .ghost, compact: true)
    private let title = shellLine("", font: PiKit.Font.caption, color: .piInkSecondary)
    private lazy var stack = ShellStack(.horizontal, spacing: 12, padding: NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16), [.view(back), .view(title, .flexible)])
    override init(frame: NSRect) {
        super.init(frame: frame); addSubview(stack)
        back.setAccessibilityIdentifier("back-to-subagent-parent")
        back.toolTip = "Back to the issuing tool call (⌘[)"
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func update(chat: ChatRecord, parent: ChatRecord?, back action: @escaping () -> Void) {
        back.isEnabled = parent != nil; back.onPress = action
        title.line.text = chat.displayTitle + (parent == nil ? " · Parent unavailable" : "")
        title.toolTip = parent.map { $0.displayTitle + " › " + chat.displayTitle } ?? title.line.text
        title.setAccessibilityLabel(title.toolTip)
        back.toolTip = "Back to Parent from " + chat.displayTitle + " (⌘[)"
        back.setAccessibilityLabel(back.toolTip)
        stack.relayoutAll(); needsLayout = true
    }
    func height(forWidth width: CGFloat) -> CGFloat { stack.height(forWidth: width) }
    override func layout() { super.layout(); stack.frame = bounds }
}
