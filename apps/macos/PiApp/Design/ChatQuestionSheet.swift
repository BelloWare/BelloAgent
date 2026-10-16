import AppKit

/// A chat's question with a list, in the app's own sheet chrome: deleting a
/// chat names every saved side that goes with it. The detail, the list and
/// its notes scroll inside the body; Cancel and the action stay visible, and
/// Return and Escape choose Cancel for a destructive action.
@MainActor final class ChatQuestionSheet: NSView {
    let sheet: PiKit.Sheet
    let cancel = PiKit.Button("Cancel")
    let confirm: PiKit.Button
    let review: ChatQuestionScroll
    private let answer: (Bool) -> Void

    init(question: ChatQuestion, list: ChatQuestion.List, destructive: Bool, parentSize: NSSize, answer: @escaping (Bool) -> Void) {
        self.answer = answer
        let width = min(480, max(260, parentSize.width - 24))
        confirm = PiKit.Button(question.action, style: destructive ? .danger : .primary)
        var rows: [ShellItem] = [.view(Self.text(question.detail, id: "detail", font: PiKit.Font.body, color: .piInk), .fill)]
        if !list.items.isEmpty {
            var names: [ShellItem] = []
            if !list.heading.isEmpty { names.append(.view(Self.text(list.heading, id: "list-heading", font: PiKit.Font.caption, color: .piInkSecondary), .fill)) }
            for (index, item) in list.items.prefix(ChatQuestion.List.shownLimit).enumerated() {
                let name = ShellText(String(item.title.prefix(300)), font: PiKit.Font.body, color: .piInk, maximumLines: 1)
                name.setAccessibilityIdentifier("chat-question-item-\(index)")
                name.setAccessibilityLabel(item.title)
                let indent = CGFloat(min(max(0, item.depth - 1), 6)) * 14
                names.append(.view(ShellStack(.horizontal, spacing: 6, padding: NSEdgeInsets(top: 0, left: indent, bottom: 0, right: 0),
                    [.view(Self.text(item.depth > 1 ? "↳" : "•", id: "marker", font: PiKit.Font.caption, color: .piInkTertiary)), .view(name, .fill)]), .fill))
            }
            if list.items.count > ChatQuestion.List.shownLimit {
                names.append(.view(Self.text("and \(list.items.count - ChatQuestion.List.shownLimit) more", id: "list-more", font: PiKit.Font.caption, color: .piInkSecondary), .fill))
            }
            rows.append(.view(ShellStack(.vertical, spacing: 4, names), .fill))
        }
        for (index, note) in list.notes.enumerated() {
            rows.append(.view(Self.text(note, id: "note-\(index)", font: PiKit.Font.caption, color: .piWarning), .fill))
        }
        let body = ShellStack(.vertical, spacing: 14, padding: NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24), rows)
        let maximumBody = max(140, min(420, parentSize.height - 170))
        review = ChatQuestionScroll(body: body, width: width, maximumHeight: maximumBody)
        sheet = PiKit.Sheet(question.title, content: review, footer: SheetFooterRow(trailing: [cancel, confirm]))
        sheet.width = width
        super.init(frame: .zero)
        addSubview(sheet)
        if destructive { cancel.keyEquivalent = "\r"; confirm.keyEquivalent = "" }
        else { confirm.keyEquivalent = "\r"; cancel.keyEquivalent = "" }
        cancel.onPress = { answer(false) }; confirm.onPress = { answer(true) }
        cancel.nextKeyView = confirm; confirm.nextKeyView = cancel
        cancel.setAccessibilityIdentifier("chat-question-cancel"); confirm.setAccessibilityIdentifier("chat-question-confirm")
        sheet.onCancel = { answer(false) }
        setAccessibilityElement(false)
        setAccessibilityIdentifier("chat-question")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { sheet.intrinsicContentSize }
    override var fittingSize: NSSize { intrinsicContentSize }
    override func layout() { super.layout(); sheet.frame = bounds }
    override func cancelOperation(_ sender: Any?) { answer(false) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if event.keyCode == 53 { answer(false); return true }
            if [UInt16(36), 76].contains(event.keyCode) { (cancel.keyEquivalent == "\r" ? cancel : confirm).onPress?(); return true }
            if review.scroll(key: event.keyCode) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
    override func pageDown(_ sender: Any?) { review.scroll(key: KeyCode.pageDown) }
    override func pageUp(_ sender: Any?) { review.scroll(key: KeyCode.pageUp) }
    override func scrollPageDown(_ sender: Any?) { review.scroll(key: KeyCode.pageDown) }
    override func scrollPageUp(_ sender: Any?) { review.scroll(key: KeyCode.pageUp) }

    private static func text(_ value: String, id: String, font: NSFont, color: NSColor) -> ShellText {
        let text = ShellText(value, font: font, color: color)
        text.setAccessibilityIdentifier("chat-question-" + id)
        return text
    }
}

/// The question's body, as tall as its content up to `maximumHeight`.
@MainActor final class ChatQuestionScroll: NSScrollView {
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
    var scrolls: Bool { body.height(forWidth: size.width) > size.height }
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
