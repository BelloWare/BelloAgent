import AppKit

@MainActor final class SubagentHeaderView: NSView, PiKit.WidthSizing {
    private let back = PiKit.Button("Back to Parent", symbol: "chevron.left", style: .ghost, compact: true)
    private let title = shellLine("", font: PiKit.Font.caption, color: .piInkSecondary)
    private let provenance = shellLine("", font: PiKit.Font.caption, color: .piInkSecondary)
    private let effort = shellLine("", font: PiKit.Font.caption, color: .piInkSecondary)
    private lazy var stack = ShellStack(.horizontal, spacing: 12, padding: NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16), [.view(back), .view(title, .flexible)])
    override init(frame: NSRect) {
        super.init(frame: frame); addSubview(stack); addSubview(provenance)
        back.setAccessibilityIdentifier("back-to-subagent-parent")
        back.toolTip = "Back to the issuing tool call (⌘[)"
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func update(chat: ChatRecord, parent: ChatRecord?, effort level: String? = nil, original: String? = nil, backTitle: String? = nil, back action: @escaping () -> Void) {
        provenance.line.text = original ?? ""; provenance.isHidden = original == nil
        provenance.setAccessibilityIdentifier("original-chat-provenance"); provenance.setAccessibilityLabel(original); provenance.toolTip = original
        back.isEnabled = parent != nil || original != nil; back.onPress = action
        // Bound the compact button; its tooltip and VoiceOver keep the full
        // destination even when the fork has a long title.
        if let backTitle {
            var name = String(backTitle.prefix(26))
            func label() -> String { "Back to " + name + (name == backTitle ? "" : "…") }
            // At most 26 short measurements on a header update, never layout.
            while !name.isEmpty, PiKit.Line(label(), font: back.titleFont, color: .piInkSecondary).size(scale: piScale).width > 180 { name.removeLast() }
            back.title = label()
        } else { back.title = "Back to Parent" }
        let unavailable = parent == nil ? " · Parent unavailable" : ""
        title.line.text = (original == nil ? chat.displayTitle : chat.subagentShortTitle) + unavailable
        let full = chat.displayTitle + unavailable + (level.map { " · " + $0 } ?? "")
        title.toolTip = parent.map { $0.displayTitle + " › " + full } ?? full
        title.setAccessibilityLabel(title.toolTip)
        effort.line.text = level.map { "· " + $0 } ?? ""
        effort.toolTip = level.map { "Thinking effort: " + $0 }; effort.setAccessibilityLabel(effort.toolTip)
        // Keep the level visible when a long task title has to truncate.
        stack.items = [.view(back), .view(title, .flexible)] + (level == nil ? [] : [.view(effort)])
        back.toolTip = (backTitle.map { "Back to " + $0 } ?? "Back to Parent") + " from " + chat.displayTitle + " (⌘[)"
        back.setAccessibilityLabel(back.toolTip)
        stack.relayoutAll(); needsLayout = true
    }
    func height(forWidth width: CGFloat) -> CGFloat { stack.height(forWidth: width) + (provenance.isHidden ? 0 : 24) }
    override func layout() { super.layout(); stack.frame = CGRect(x:0,y:0,width:bounds.width,height:bounds.height - (provenance.isHidden ? 0 : 24))
        provenance.frame = CGRect(x:16,y:stack.frame.maxY,width:max(0,bounds.width - 32),height:20) }
}
