import AppKit

/// A compact, wrapping diff toolbar. A staging result explicitly offers the
/// index review; choosing it never changes what Commit takes.
@MainActor final class GitHunkToolbar: NSView, PiKit.WidthSizing {
    let previous = PiKit.Button("Previous Change", symbol: "chevron.up", style: .secondary, compact: true)
    let next = PiKit.Button("Next Change", symbol: "chevron.down", style: .secondary, compact: true)
    let staged = PiKit.Button("Review Staged Changes", style: .secondary, compact: true)
    let message = PiKit.WrappedText("", font: PiKit.Font.micro, color: .piInkSecondary)
    private var note = ""
    init() {
        super.init(frame: .zero)
        for view in [previous, next, staged, message] as [NSView] { addSubview(view) }
        previous.toolTip = "Previous change (⇧F7)"; next.toolTip = "Next change (F7)"
        previous.setAccessibilityIdentifier("git-previous-change"); next.setAccessibilityIdentifier("git-next-change")
        staged.setAccessibilityIdentifier("git-review-staged")
        staged.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func update(hasChanges: Bool, review: GitHunkReview?) {
        previous.isEnabled = hasChanges; next.isEnabled = hasChanges
        staged.isHidden = review?.stagedPath == nil
        staged.isEnabled = review?.busy == false
        note = review?.message ?? ""
        message.text = note; message.isHidden = note.isEmpty
        message.toolTip = note
        staged.onPress = { [weak review] in review?.reviewStaged() }
        needsLayout = true
    }
    private func frames(width: CGFloat) -> ([(NSView, CGRect)], CGFloat) {
        let buttons = [previous, next] + (staged.isHidden ? [] : [staged])
        var result: [(NSView, CGRect)] = [], x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for button in buttons {
            let size = button.intrinsicContentSize
            if x > 0, x + size.width > width { x = 0; y += row + 6; row = 0 }
            result.append((button, CGRect(x: x, y: y, width: min(width, size.width), height: size.height)))
            x += size.width + 6; row = max(row, size.height)
        }
        y += row
        if !note.isEmpty {
            y += 6
            result.append((message, CGRect(x: 0, y: y, width: width, height: message.height(forWidth: width))))
            y += message.height(forWidth: width)
        }
        return (result, y)
    }
    func height(forWidth width: CGFloat) -> CGFloat { frames(width: max(0, width)).1 }
    override func layout() { super.layout(); for (view, rect) in frames(width: bounds.width).0 { view.frame = rect } }
}
