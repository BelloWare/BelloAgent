import AppKit
import GitView

/// A reusable, width-bounded row. Ref names and subjects keep their full
/// accessibility/tool-tip text even when a narrow pane abbreviates them.
@MainActor final class GitHistoryRow: NSView {
    private let content = GitHistoryRowContent()
    let button: PiKit.SelectableRow
    private var commit: GitCommit?
    var onKey: ((NSEvent) -> Void)?
    init() {
        button = PiKit.SelectableRow(content: content)
        super.init(frame: .zero)
        addSubview(button)
        setAccessibilityElement(true); setAccessibilityRole(.row)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { if let onKey { onKey(event) } else { super.keyDown(with: event) } }
    override func accessibilityChildren() -> [Any]? { [] }
    override func isAccessibilitySelected() -> Bool { button.selected }
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
    override func setAccessibilityFocused(_ focused: Bool) { if focused { window?.makeFirstResponder(self) } }
    override func accessibilityPerformPress() -> Bool { button.performClick(nil); return true }
    override func layout() { super.layout(); button.frame = bounds }
    static func height(_ commit: GitCommit) -> CGFloat { commit.refs.isEmpty ? 68 : 92 }
    func show(_ commit: GitCommit, selected: Bool, open: @escaping () -> Void) {
        if self.commit != commit { self.commit = commit; content.show(commit) }
        button.selected = selected; button.onPress = open
        button.setAccessibilityIdentifier("git-commit-" + commit.shortHash)
        button.setAccessibilityLabel("\(commit.subject), \(commit.shortHash), \(commit.author), committed \(GitHistoryRowContent.stamp(commit.date)) UTC" +
                                     (commit.refs.isEmpty ? "" : ", " + commit.refs.joined(separator: ", ")))
        setAccessibilityLabel(button.accessibilityLabel()); setAccessibilityIdentifier("git-commit-" + commit.shortHash)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let commit else { return nil }
        return PiMenus.menu([
            .button("Copy Hash") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commit.hash, forType: .string) },
            .button("Copy Subject") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commit.subject, forType: .string) },
        ])
    }
}

@MainActor private final class GitHistoryRowContent: NSView {
    private let subject = TextBlock("", font: PiKit.Font.body, color: .piInk, maximumLines: 2)
    private let refs = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.micro, color: .piAccent))
    private let refFill = PiKit.Box(fill: .piAccentSoft, cornerRadius: 9)
    private let hashLine = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.mono, color: .piAccent))
    private let author = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.micro, color: .piInkSecondary))
    private let date = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.micro, color: .piInkTertiary))
    private var hasRefs = false
    private static let formatter: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.timeZone = TimeZone(secondsFromGMT: 0)
        value.dateFormat = "yyyy-MM-dd HH:mm:ss"; return value
    }()
    static func stamp(_ value: Date) -> String { formatter.string(from: value) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        refs.truncation = .middle; author.truncation = .end
        for view in [subject, refFill, refs, hashLine, author, date] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func show(_ commit: GitCommit) {
        subject.text = commit.subject; subject.toolTip = commit.subject
        hasRefs = !commit.refs.isEmpty; refs.isHidden = !hasRefs; refFill.isHidden = !hasRefs
        refs.line.text = commit.refs.joined(separator: " · "); refs.toolTip = refs.line.text
        hashLine.line.text = commit.shortHash; author.line.text = commit.author
        date.line.text = String(Self.stamp(commit.date).prefix(10))
        date.toolTip = "Committed " + Self.stamp(commit.date) + " UTC"; needsLayout = true
    }
    override func layout() {
        super.layout()
        let width = max(0, bounds.width)
        subject.frame = CGRect(x: 0, y: 0, width: width, height: 34)
        var y: CGFloat = 35
        if hasRefs {
            refFill.frame = CGRect(x: 0, y: y, width: width, height: 19)
            refs.frame = CGRect(x: 7, y: y + 2, width: max(0, width - 14), height: 15)
            y += 24
        }
        StackLayout.place([.fixed(hashLine), .line(author), .fixed(date)], spacing: 6,
                          in: CGRect(x: 0, y: y, width: width, height: 16), scale: piScale)
    }
}

/// Pi chip styling with a truncating label and an always reachable remove
/// control. A 200-character ref cannot push the remove action off the pane.
@MainActor final class GitHistoryFilterChip: PiKit.Box {
    private let label: PiKit.TextLine
    let remove = PiKit.IconButton(symbol: "xmark", label: "Remove filter", size: 20)
    init(_ text: String, remove action: @escaping () -> Void) {
        label = PiKit.TextLine(PiKit.Line(text, font: PiKit.Font.caption, color: .piInk))
        super.init(fill: .piSurface, stroke: .piHairlineStrong, cornerRadius: 13)
        label.truncation = .middle; toolTip = text
        remove.onPress = action; remove.setAccessibilityLabel("Remove " + text)
        addSubview(label); addSubview(remove)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: label.intrinsicContentSize.width + 40, height: 26) }
    override func layout() {
        super.layout()
        label.frame = CGRect(x: 9, y: 6, width: max(0, bounds.width - 36), height: 15)
        remove.frame = CGRect(x: max(0, bounds.width - 25), y: 3, width: 20, height: 20)
    }
}
