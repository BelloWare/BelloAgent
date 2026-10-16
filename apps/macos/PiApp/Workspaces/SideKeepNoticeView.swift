import AppKit

/// One bounded notice for all pending copies. Only metadata is measured;
/// journal inspection happens through the file viewer after an explicit click.
@MainActor final class SideKeepNoticeView: NSView, PiKit.WidthSizing {
    let issues: [SideKeepIssue]
    private let heading: ShellStack
    private let rows: ShellStack
    private let scroll = NSScrollView()
    private let document = FlippedDocument()
    private let retry = PiKit.Button("Check again", style: .ghost, compact: true)
    private var buttons: [PiKit.Button] = []
    var inheritedEnabled = true {
        didSet { guard oldValue != inheritedEnabled else { return }; for button in buttons { button.isEnabled = inheritedEnabled } }
    }
    init(issues: [SideKeepIssue], open: @escaping (SideKeepIssue) -> Void,
         reveal: @escaping (SideKeepIssue) -> Void, dismiss: @escaping (SideKeepIssue, NSWindow) -> Void,
         retry: @escaping () -> Void) {
        self.issues = issues
        let title = ShellText(issues.count == 1 ? "A saved chat needs review" : "\(issues.count) saved chats need review", font: PiKit.Font.title(14), color: .piInk)
        let detail = ShellText("Files are unchanged. Open anyway shows the file read-only.", font: PiKit.Font.caption, color: .piInkSecondary)
        heading = ShellStack(.vertical, spacing: 4, [.view(title, .fill), .view(detail, .fill)])
        rows = ShellStack(.vertical, spacing: 12)
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = PiRadius.md; layer?.borderWidth = 1
        addSubview(heading); addSubview(self.retry); addSubview(scroll)
        self.retry.onPress = retry; self.retry.setAccessibilityIdentifier("side-keep-retry")
        self.retry.setAccessibilityLabel("Check saved chats again")
        buttons = [self.retry]
        rows.items = issues.enumerated().flatMap { index, issue -> [ShellItem] in
            let row = SideKeepNoticeRow(issue: issue, open: { open(issue) }, reveal: { reveal(issue) }, dismiss: { [weak self] in
                if let window = self?.window { dismiss(issue, window) }
            })
            buttons += row.buttons.filter(\.isEnabled)
            return (index == 0 ? [] : [.view(ShellHairline(), .fill)]) + [.view(row, .fill)]
        }
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = document; document.addSubview(rows)
        setAccessibilityElement(false); setAccessibilityIdentifier("side-keep-notice")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    private func headerHeight(_ width: CGFloat) -> CGFloat { heading.height(forWidth: max(0, width - 24 - retry.intrinsicContentSize.width - 12)) }
    func height(forWidth width: CGFloat) -> CGFloat {
        12 + max(headerHeight(width), retry.intrinsicContentSize.height) + 12 + min(210, rows.height(forWidth: max(0, width - 36))) + 12
    }
    override func layout() {
        super.layout()
        let size = retry.intrinsicContentSize, top = max(headerHeight(bounds.width), size.height)
        heading.frame = CGRect(x: 12, y: 12, width: max(0, bounds.width - 36 - size.width), height: top)
        retry.frame = CGRect(x: bounds.width - 12 - size.width, y: 12, width: size.width, height: size.height)
        scroll.frame = CGRect(x: 12, y: 24 + top, width: max(0, bounds.width - 24), height: max(0, bounds.height - 36 - top))
        scroll.shellFit(document) { self.rows.height(forWidth: max(0, $0 - 12)) }
        rows.frame = CGRect(x: 0, y: 0, width: max(0, document.bounds.width - 12), height: document.bounds.height)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = piCGColor(.piSurface)
        layer?.borderColor = piCGColor(NSColor.piWarning.withAlphaComponent(0.5))
    }
}

@MainActor private final class SideKeepNoticeRow: NSView, PiKit.WidthSizing {
    let buttons = [PiKit.Button("Open anyway", style: .secondary, compact: true),
                   PiKit.Button("Show file in Finder", style: .ghost, compact: true),
                   PiKit.Button("Dismiss", style: .ghost, compact: true)]
    private let text: ShellStack
    init(issue: SideKeepIssue, open: @escaping () -> Void, reveal: @escaping () -> Void, dismiss: @escaping () -> Void) {
        let title = ShellText(String(issue.chat.title.prefix(160)), font: PiKit.Font.body, color: .piInk)
        title.toolTip = issue.chat.title; title.setAccessibilityLabel(issue.chat.title)
        let reason = ShellText(issue.reason, font: PiKit.Font.caption, color: .piInkSecondary)
        let path = PiKit.TextLine(PiKit.Line(issue.chat.path ?? "No file location saved", font: PiKit.Font.micro, color: .piInkTertiary))
        path.truncation = .middle; path.toolTip = issue.chat.path
        var items: [ShellItem] = [.view(title, .fill)]
        if let parent = issue.parentTitle {
            let label = ShellText("From: " + String(parent.prefix(160)), font: PiKit.Font.caption, color: .piInkSecondary)
            label.toolTip = parent; label.setAccessibilityLabel("From: " + parent)
            items.append(.view(label, .fill))
        }
        items += [.view(reason, .fill), .view(path, .fill)]
        text = ShellStack(.vertical, spacing: 3, items)
        super.init(frame: .zero)
        addSubview(text)
        for (index, button) in buttons.enumerated() {
            addSubview(button)
            button.setAccessibilityIdentifier("side-keep-\(["open", "finder", "dismiss"][index])-\(issue.id)")
            button.setAccessibilityLabel(button.title + ": " + issue.chat.title)
            if index < 2, issue.chat.path == nil { button.isEnabled = false; button.toolTip = "No file location was saved." }
        }
        buttons[0].toolTip = issue.chat.path == nil ? "No file location was saved." : "Inspect the unchanged file read-only; does not start a chat."
        buttons[0].onPress = open; buttons[1].onPress = reveal; buttons[2].onPress = dismiss
        buttons[0].nextKeyView = buttons[1]; buttons[1].nextKeyView = buttons[2]
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    private var rowWidth: CGFloat { buttons.reduce(12) { $0 + $1.intrinsicContentSize.width } }
    private func actionHeight(_ width: CGFloat) -> CGFloat {
        width >= rowWidth ? buttons[0].intrinsicContentSize.height : buttons.reduce(12) { $0 + $1.intrinsicContentSize.height }
    }
    func height(forWidth width: CGFloat) -> CGFloat { text.height(forWidth: width) + 8 + actionHeight(width) }
    override func layout() {
        super.layout()
        let height = text.height(forWidth: bounds.width)
        text.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        var x: CGFloat = 0, y = height + 8
        for button in buttons {
            let size = button.intrinsicContentSize
            button.frame = CGRect(x: x, y: y, width: min(bounds.width, size.width), height: size.height)
            if bounds.width >= rowWidth { x += size.width + 6 } else { y += size.height + 6 }
        }
    }
}

@MainActor final class SideKeepDismissSheet: NSView {
    let sheet: PiKit.Sheet
    let cancel = PiKit.Button("Cancel")
    let confirm = PiKit.Button("Dismiss", style: .danger)
    private let answer: (Bool) -> Void
    init(issue: SideKeepIssue, parentSize: NSSize, answer: @escaping (Bool) -> Void) {
        self.answer = answer
        let width = min(480, max(240, parentSize.width - 24))
        let name = ShellText(String(issue.chat.title.prefix(160)), font: PiKit.Font.body, color: .piInk)
        name.setAccessibilityLabel(issue.chat.title)
        let detail = ShellText("Only this reminder is removed. Any existing file stays on disk. Bello will stop trying to add this chat automatically.", font: PiKit.Font.body, color: .piInkSecondary)
        let body = ShellStack(.vertical, spacing: 12, padding: NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24), [.view(name, .fill), .view(detail, .fill)])
        body.frame.size.width = width
        sheet = PiKit.Sheet("Dismiss this notice?", content: body, footer: SheetFooterRow(trailing: [cancel, confirm]))
        sheet.width = width
        super.init(frame: .zero)
        addSubview(sheet)
        cancel.keyEquivalent = "\r"; confirm.keyEquivalent = ""
        cancel.onPress = { answer(false) }; confirm.onPress = { answer(true) }
        cancel.nextKeyView = confirm; confirm.nextKeyView = cancel
        cancel.setAccessibilityIdentifier("side-keep-dismiss-cancel"); confirm.setAccessibilityIdentifier("side-keep-dismiss-confirm")
        sheet.onCancel = { answer(false) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { sheet.intrinsicContentSize }
    override var fittingSize: NSSize { intrinsicContentSize }
    override func layout() { super.layout(); sheet.frame = bounds }
    override func cancelOperation(_ sender: Any?) { answer(false) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty, [UInt16(53), 36, 76].contains(event.keyCode) {
            answer(false); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
