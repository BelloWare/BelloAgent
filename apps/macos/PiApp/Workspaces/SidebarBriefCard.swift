import AppKit

/// The card a sidebar row brings up when the pointer rests on it and its
/// chat has a brief (`WorkspaceChatBriefs.swift`): the brief, its keywords,
/// when it was written, and the line the row's tooltip says otherwise. One
/// card at a time for the whole sidebar; it takes no focus and never stands
/// between the pointer and the rows (`PiHoverCardPresenter`).
@MainActor enum SidebarBriefCard {
    static let presenter = PiHoverCardPresenter()
    static let width: CGFloat = 300

    static func hover(_ inside: Bool, anchor: NSView, brief: ChatBrief? = nil, help: String = "") {
        guard inside, let brief else { presenter.hover(false, over: anchor, width: width) { NSView() }; return }
        presenter.hover(true, over: anchor, width: width) { SidebarBriefCardView(brief: brief, help: help) }
    }
    /// A row was reused for another chat or left the window: its card goes.
    static func anchorLeft(_ anchor: NSView) {
        if presenter.anchorView === anchor { presenter.hide() }
    }
}

/// What the card shows: a heading with when the brief was written, the
/// brief, its keywords, and the row's state and figures.
@MainActor final class SidebarBriefCardView: NSView, PiKit.WidthSizing {
    private let stack: ShellStack
    let brief: ChatBrief

    init(brief: ChatBrief, help: String, now: Date = Date()) {
        self.brief = brief
        var items: [ShellItem] = []
        let updated = brief.at > .distantPast ? "Brief · updated " + ChatRowStats.relative(brief.at, now: now) : "Brief"
        items.append(.view(ShellStack(.horizontal, spacing: 5, alignment: .center, [
            .view(PiKit.SymbolView(PiKit.Symbol("text.magnifyingglass", size: 10, weight: .semibold), color: .piAccent)),
            .view(SkillHoverCardView.line(updated, font: PiKit.Font.micro, color: .piInkTertiary), .flexible),
        ]), .fill))
        items.append(.view(ShellText(brief.text, font: .systemFont(ofSize: 12), color: .piInk, maximumLines: 7), .fill))
        if !brief.keywords.isEmpty {
            items.append(.view(ShellText(runs: [.init(text: "Keywords  ", color: .piInkTertiary),
                                                .init(text: brief.keywords.joined(separator: " · "), color: .piInkSecondary)],
                                         font: PiKit.Font.caption, maximumLines: 2), .fill))
        }
        let state = help.trimmingCharacters(in: .whitespaces)
        if !state.isEmpty { items.append(.view(ShellText(state, font: PiKit.Font.caption, color: .piInkTertiary, maximumLines: 2), .fill)) }
        stack = ShellStack(.vertical, spacing: 5, padding: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12), items)
        super.init(frame: .zero)
        addSubview(stack)
        setAccessibilityIdentifier("sidebar-brief-card")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func height(forWidth width: CGFloat) -> CGFloat { stack.height(forWidth: width) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() { super.layout(); stack.frame = bounds }
}
