import AppKit
import GitView

/// The immutable operation being reviewed, in the app's own sheet chrome.
/// Long messages/checks scroll inside the body; Cancel and the action remain
/// visible even in a narrow pane. Return and Escape always choose Cancel.
@MainActor final class GitOperationSheet: NSView {
    private let sheet: PiKit.Sheet
    private let review: GitQuestionScroll
    private let cancel = PiKit.Button("Cancel")
    private let answer: (Bool) -> Void

    init(request: GitCommitRequest, preflight: GitCommitPreflight, repositoryName: String?,
         parentSize: NSSize, answer: @escaping (Bool) -> Void) {
        self.answer = answer
        let width = min(520, max(240, parentSize.width - 24))
        let name = repositoryName.flatMap { $0.isEmpty ? nil : $0 } ?? URL(fileURLWithPath: request.root).lastPathComponent
        let repository = Self.line(name, id: "repository")
        repository.toolTip = name
        let path = Self.line(request.root, id: "path", font: PiKit.Font.micro, color: .piInkTertiary)
        path.truncation = .middle; path.toolTip = request.root
        let identity = ShellStack(.vertical, spacing: 3, [.view(repository, .fill), .view(path, .fill)])
        var rows: [NSView] = [GitQuestionRow("Repository", value: identity)]
        if let target = request.target {
            let value = Self.line(target.description, id: "target")
            let full = "\(target.branch == "(detached)" ? "Detached HEAD" : target.branch) · \(target.head)"
            value.truncation = .middle; value.toolTip = full
            value.setAccessibilityLabel("Target: " + full)
            rows.append(GitQuestionRow("Target", value: value))
        }
        rows.append(GitQuestionRow("Scope", value: Self.text(request.scopeDescription, id: "scope")))
        let message = Self.text(String(request.message.prefix(500)) + (request.message.count > 500 ? "…" : ""), id: "message")
        message.toolTip = request.message; message.setAccessibilityLabel("Message: " + request.message)
        rows.append(GitQuestionRow("Message", value: message))
        if request.signOff {
            rows.append(GitQuestionRow("Sign off", value: Self.text("Add Signed-off-by using the Git committer identity.", id: "sign-off")))
        }
        if preflight.hasWarnings {
            rows.append(GitQuestionRow("Git check", value: Self.text(String(preflight.detail.prefix(1_500)), id: "check")))
        }
        let body = ShellStack(.vertical, spacing: 14,
            padding: NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24), rows.map { .view($0, .fill) })
        let action = PiKit.Button(request.kind.title, style: request.kind == .commit ? .primary : .danger)
        action.keyEquivalent = ""; action.onPress = { answer(true) }
        action.setAccessibilityIdentifier("git-question-confirm")
        cancel.keyEquivalent = "\r"; cancel.onPress = { answer(false) }
        cancel.setAccessibilityIdentifier("git-question-cancel")
        cancel.nextKeyView = action; action.nextKeyView = cancel
        let warning = request.kind != .commit
            ? "Replaces the last commit. Coordinate any published history with collaborators."
            : "Review the Git check warnings before committing."
        let footer = GitQuestionFooter(warning: Self.text(warning, id: "warning", color: .piWarning), buttons: [cancel, action], width: width - 48)
        let maximumBody = max(160, min(440, parentSize.height - footer.height(forWidth: width - 48) - 112))
        let scroll = GitQuestionScroll(body: body, width: width, maximumHeight: maximumBody)
        review = scroll
        let title = request.kind == .commit ? "Commit with warnings?" : "\(request.kind.title) last commit?"
        sheet = PiKit.Sheet(title, content: scroll, footer: footer)
        sheet.width = width; sheet.onCancel = { answer(false) }
        super.init(frame: .zero)
        addSubview(sheet)
        setAccessibilityElement(false)
        setAccessibilityIdentifier("git-operation-question")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { sheet.intrinsicContentSize }
    override var fittingSize: NSSize { intrinsicContentSize }
    override func layout() { super.layout(); sheet.frame = bounds }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.defaultButtonCell = cancel.cell as? NSButtonCell
    }
    override func cancelOperation(_ sender: Any?) { answer(false) }
    override func keyDown(with event: NSEvent) {
        if handleKey(event) { return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        if [UInt16(53), 36, 76].contains(event.keyCode) {
            answer(false); return true
        }
        return review.scroll(key: event.keyCode)
    }
    // Text-navigation commands travel up from whichever footer button has
    // focus; the review scroll view is its sibling, not its next responder.
    override func pageDown(_ sender: Any?) { review.scroll(key: KeyCode.pageDown) }
    override func pageUp(_ sender: Any?) { review.scroll(key: KeyCode.pageUp) }
    override func scrollPageDown(_ sender: Any?) { review.scroll(key: KeyCode.pageDown) }
    override func scrollPageUp(_ sender: Any?) { review.scroll(key: KeyCode.pageUp) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { review.scroll(key: KeyCode.home) }
    override func scrollToEndOfDocument(_ sender: Any?) { review.scroll(key: KeyCode.end) }

    private static func line(_ value: String, id: String, font: NSFont = PiKit.Font.body, color: NSColor = .piInk) -> PiKit.TextLine {
        let text = PiKit.TextLine(PiKit.Line(value, font: font, color: color))
        text.setAccessibilityIdentifier("git-question-" + id)
        return text
    }
    private static func text(_ value: String, id: String, color: NSColor = .piInk) -> ShellText {
        let text = ShellText(value, font: PiKit.Font.caption, color: color)
        text.setAccessibilityIdentifier("git-question-" + id)
        return text
    }
}

/// Keep the warning beside the action, even when the reviewed message scrolls.
@MainActor private final class GitQuestionFooter: NSView, PiKit.WidthSizing {
    private let column: ShellStack
    private let width: CGFloat
    init(warning: NSView, buttons: [NSView], width: CGFloat) {
        self.width = width
        column = ShellStack(.vertical, spacing: 12, [.view(warning, .fill), .view(SheetFooterRow(trailing: buttons), .fill)])
        super.init(frame: .zero)
        addSubview(column)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: width)) }
    func height(forWidth width: CGFloat) -> CGFloat { column.height(forWidth: width) }
    override func layout() { super.layout(); column.frame = bounds }
}

/// A compact key/value block, stacked when two columns would squeeze the
/// value. Width measurement handles text only, never Git reads or parsing.
@MainActor private final class GitQuestionRow: NSView, PiKit.WidthSizing {
    private let label: PiKit.TextLine
    private let value: NSView
    init(_ title: String, value: NSView) {
        label = PiKit.TextLine(PiKit.Line(title, font: PiKit.Font.caption, color: .piInkSecondary))
        self.value = value
        super.init(frame: .zero)
        addSubview(label); addSubview(value)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func height(forWidth width: CGFloat) -> CGFloat {
        width < 300 ? label.intrinsicContentSize.height + 4 + PiKit.height(of: value, width: width)
            : max(label.intrinsicContentSize.height, PiKit.height(of: value, width: width - 88))
    }
    override func layout() {
        super.layout()
        let stacked = bounds.width < 300
        label.frame = CGRect(x: 0, y: 0, width: stacked ? bounds.width : 76, height: label.intrinsicContentSize.height)
        let x: CGFloat = stacked ? 0 : 88, y: CGFloat = stacked ? label.frame.maxY + 4 : 0
        value.frame = CGRect(x: x, y: y, width: max(0, bounds.width - x), height: max(0, bounds.height - y))
    }
}

@MainActor private final class GitQuestionScroll: NSScrollView {
    private let body: ShellStack
    private let size: NSSize
    init(body: ShellStack, width: CGFloat, maximumHeight: CGFloat) {
        self.body = body
        size = NSSize(width: width, height: min(maximumHeight, body.height(forWidth: width)))
        super.init(frame: .zero)
        drawsBackground = false; borderType = .noBorder
        hasVerticalScroller = true; autohidesScrollers = true; scrollerStyle = .overlay
        documentView = body
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { size }
    override var fittingSize: NSSize { size }
    override func layout() {
        super.layout()
        let width = max(1, contentSize.width)
        body.setFrameSize(NSSize(width: width, height: max(contentSize.height, body.height(forWidth: width))))
    }
    @discardableResult func scroll(key: UInt16) -> Bool {
        let clip = contentView
        let last = max(0, body.bounds.height - clip.bounds.height)
        let page = max(40, clip.bounds.height - 32)
        let target: CGFloat
        switch key {
        case KeyCode.pageDown: target = clip.bounds.minY + page
        case KeyCode.pageUp: target = clip.bounds.minY - page
        case KeyCode.home: target = 0
        case KeyCode.end: target = last
        case KeyCode.downArrow: target = clip.bounds.minY + 20
        case KeyCode.upArrow: target = clip.bounds.minY - 20
        default: return false
        }
        clip.scroll(to: NSPoint(x: 0, y: min(last, max(0, target))))
        reflectScrolledClipView(clip)
        return true
    }
}
