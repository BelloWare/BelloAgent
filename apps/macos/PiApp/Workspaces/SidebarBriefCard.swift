import AppKit
import Combine

/// The card a sidebar row brings up when the pointer rests on it while chat
/// briefs are on (`WorkspaceChatBriefs.swift`): the chat's brief, its
/// keywords, when it was written, and the line the row's tooltip says
/// otherwise; for a chat without a brief, Write Brief in its place. One card
/// at a time for the whole sidebar, beside the row so it covers no other
/// row. It takes no focus; the pointer can move onto it to press Write Brief
/// (`PiHoverCardPresenter.interactive`).
@MainActor enum SidebarBriefCard {
    static let presenter: PiHoverCardPresenter = {
        let presenter = PiHoverCardPresenter()
        presenter.interactive = true
        presenter.placement = .trailing
        return presenter
    }()
    static let width: CGFloat = 300

    /// What a row's card shows.
    struct Content {
        var brief: ChatBrief?
        var help: String
        /// The chat's brief is being written.
        var writing = false
        /// Why its last request wrote none (`ChatBriefs.lastProblem`).
        var problem: String?
        /// Write Brief, for a chat without a brief.
        var write: (() -> Void)?
    }

    static func hover(_ inside: Bool, anchor: NSView, content: (() -> Content)? = nil) {
        guard inside, let content else { presenter.hover(false, over: anchor, width: width) { NSView() }; return }
        shown = content
        presenter.hover(true, over: anchor, width: width) { view(content()) }
    }
    /// What the card shown for `anchor` says changed while it is up.
    static func refresh(_ anchor: NSView, content: () -> Content) {
        presenter.refresh(over: anchor, width: width) { view(content()) }
    }
    /// The card up says whether its chat's brief is being written: it says
    /// so again whenever that changes (`ChatBriefs.writing`).
    static func watch(_ briefs: ChatBriefs) {
        guard watched !== briefs else { return }
        watched = briefs
        writingWatch = briefs.$writing.removeDuplicates().dropFirst().sink { _ in
            MainActor.assumeIsolated {
                guard presenter.isShown, let anchor = presenter.anchorView, let shown else { return }
                presenter.refresh(over: anchor, width: width) { view(shown()) }
            }
        }
    }
    private static var shown: (() -> Content)?
    private static weak var watched: ChatBriefs?
    private static var writingWatch: AnyCancellable?
    /// A row was reused for another chat or left the window: its card goes.
    static func anchorLeft(_ anchor: NSView) {
        if presenter.anchorView === anchor { presenter.hide() }
    }
    private static func view(_ content: Content) -> NSView {
        SidebarBriefCardView(brief: content.brief, help: content.help, writing: content.writing, problem: content.problem, write: content.write.map { write in
            { write(); presenter.hide() }
        })
    }
}

/// What the card shows: a heading with when the brief was written, the
/// brief, its keywords, and the row's state and figures; or, without a
/// brief, Write Brief (or that it is being written).
@MainActor final class SidebarBriefCardView: NSView, PiKit.WidthSizing {
    private let stack: ShellStack
    let brief: ChatBrief?
    /// Write Brief, on a card for a chat without a brief.
    private(set) var writeButton: PiKit.Button?

    init(brief: ChatBrief?, help: String, writing: Bool = false, problem: String? = nil, write: (() -> Void)? = nil, now: Date = Date()) {
        self.brief = brief
        var items: [ShellItem] = []
        let heading = brief.map { $0.at > .distantPast ? "Brief · updated " + ChatRowStats.relative($0.at, now: now) : "Brief" } ?? "Brief"
        items.append(.view(ShellStack(.horizontal, spacing: 5, alignment: .center, [
            .view(PiKit.SymbolView(PiKit.Symbol("text.magnifyingglass", size: 10, weight: .semibold), color: .piAccent)),
            .view(SkillHoverCardView.line(heading, font: PiKit.Font.micro, color: .piInkTertiary), .flexible),
        ]), .fill))
        if let brief {
            items.append(.view(ShellText(brief.text, font: .systemFont(ofSize: 12), color: .piInk, maximumLines: 7), .fill))
            if !brief.keywords.isEmpty {
                items.append(.view(ShellText(runs: [.init(text: "Keywords  ", color: .piInkTertiary),
                                                    .init(text: brief.keywords.joined(separator: " · "), color: .piInkSecondary)],
                                             font: PiKit.Font.caption, maximumLines: 2), .fill))
            }
        } else if writing {
            items.append(.view(ShellText("Writing the brief…", font: .systemFont(ofSize: 12), color: .piInkSecondary, maximumLines: 1), .fill))
        } else {
            items.append(.view(ShellText("No brief yet. Its connection's mini model can sum this chat up in a sentence or two, with a few keywords.",
                                         font: .systemFont(ofSize: 12), color: .piInkSecondary, maximumLines: 4), .fill))
            if let problem {
                items.append(.view(ShellText(problem, font: PiKit.Font.caption, color: .piDanger, maximumLines: 3), .fill))
            }
            if let write {
                let button = PiKit.Button("Write Brief", symbol: "text.magnifyingglass", style: .secondary, compact: true, action: write)
                button.setAccessibilityIdentifier("sidebar-brief-write")
                writeButton = button
                items.append(.view(button, insets: NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)))
            }
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
