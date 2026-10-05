import AppKit

// The controls a reply's markdown surface lays over its text: a fence's
// toolbar under the pointer, a heading's Copy, and "Open full table" beside
// a large table's preview. Each is sized as the SwiftUI view it replaces was
// (a hosting view's fitting size: its content rounded up to whole points,
// the content centred in it), so the surface places them where it did.

/// A size as an `NSHostingView` reports a SwiftUI view of `content` size as
/// fitting: rounded up to whole points.
@MainActor enum TranscriptHostedSize {
    static func fitting(_ content: CGSize) -> CGSize { CGSize(width: ceil(content.width), height: ceil(content.height)) }
}

/// A fence's toolbar: its language and a Copy of its whole code, on a
/// 20-point line, as `MarkdownCodeToolbar` drew them.
@MainActor final class MarkdownCodeToolbarView: NSView {
    private let language = TranscriptLabel()
    let copy = TranscriptCopyButton()
    private(set) var code = ""
    private(set) var languageName: String?
    private var rightToLeft = false
    override var isFlipped: Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        // What it holds lands on the window's pixel grid: a move lays it out again.
        if newOrigin != frame.origin { needsLayout = true }
        super.setFrameOrigin(newOrigin)
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        language.font = TranscriptNativeCodeBlock.languageFont
        language.color = TranscriptNSPalette.faint
        addSubview(language); addSubview(copy)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    func update(language name: String?, code: String, environment: TranscriptRowEnvironment) {
        self.code = code; languageName = name
        language.text = name?.lowercased() ?? ""
        language.isHidden = name == nil
        language.speak(name.map { "Language \($0)" })
        copy.target = MarkdownCopyTarget(kind: .code, label: "Copy code", text: code)
        copy.enabled = environment.isEnabled
        rightToLeft = environment.layoutDirection == .rightToLeft
        copy.rightToLeft = rightToLeft
        needsLayout = true
    }
    /// The toolbar's own width: the language, six points, the Copy.
    private var contentWidth: CGFloat {
        TranscriptCopyButton.size.width + (language.isHidden ? 0 : language.intrinsicSize.width + 6)
    }
    override var fittingSize: NSSize { TranscriptHostedSize.fitting(CGSize(width: contentWidth, height: 20)) }
    override var intrinsicContentSize: NSSize { fittingSize }
    override func layout() {
        super.layout()
        // The line is centred in the frame, as a hosting view centres its content.
        let width = contentWidth
        var x = (bounds.width - width) / 2
        var frames: [(NSView, CGRect)] = []
        let midY = bounds.height / 2
        if !language.isHidden {
            let label = language.intrinsicSize
            frames.append((language, CGRect(x: x, y: midY - label.height / 2, width: label.width, height: label.height)))
            x += label.width + 6
        }
        let size = TranscriptCopyButton.size
        frames.append((copy, CGRect(x: x, y: midY - size.height / 2, width: size.width, height: size.height)))
        for (view, frame) in frames {
            let placed = pixelPlaced(TranscriptMotion.mirrored(frame, of: view, width: bounds.width, rightToLeft))
            view.frame = placed.frame
            if view === copy { copy.layoutOffset = placed.offset }
            if view === language, rightToLeft {
                // Set from the right, the language ends where its frame (on
                // the pixel grid) ends, its own width before that.
                let box = pixelPlaced(TranscriptMotion.mirrored(frame, width: bounds.width, true)).frame
                language.frame.origin.x = box.maxX - language.exactWidth
            }
        }
    }
}

/// A heading's Copy: its section, as markdown (`MarkdownHeadingAction`).
@MainActor final class MarkdownHeadingActionView: NSView {
    let copy = TranscriptCopyButton()
    override var isFlipped: Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        // What it holds lands on the window's pixel grid: a move lays it out again.
        if newOrigin != frame.origin { needsLayout = true }
        super.setFrameOrigin(newOrigin)
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(copy)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    var target: MarkdownCopyTarget? { copy.target }
    func update(target: MarkdownCopyTarget, environment: TranscriptRowEnvironment) {
        copy.target = target
        copy.enabled = environment.isEnabled
        copy.rightToLeft = environment.layoutDirection == .rightToLeft
    }
    override var fittingSize: NSSize { TranscriptHostedSize.fitting(TranscriptCopyButton.size) }
    override var intrinsicContentSize: NSSize { fittingSize }
    override func layout() {
        super.layout()
        let size = TranscriptCopyButton.size
        let placed = pixelPlaced(CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        copy.frame = placed.frame; copy.layoutOffset = placed.offset
    }
}

/// "Open full table" for a table shown as a preview (`MarkdownTableAction`):
/// the words in the accent, a plain button's.
@MainActor final class MarkdownTableActionView: NSView {
    let button = TranscriptLinkButton()
    private(set) var mark: MarkdownTableMark?
    override var isFlipped: Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        // What it holds lands on the window's pixel grid: a move lays it out again.
        if newOrigin != frame.origin { needsLayout = true }
        super.setFrameOrigin(newOrigin)
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        button.label.text = "Open full table"
        button.label.font = .systemFont(ofSize: 11)
        button.label.color = TranscriptNSPalette.accent
        button.underlinesOnHover = false
        button.perform = { [weak self] in
            guard let mark = self?.mark else { return }
            MarkdownTableWindow.open(header: mark.header, rows: mark.rows)
        }
        addSubview(button)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    func update(mark: MarkdownTableMark, environment: TranscriptRowEnvironment) {
        self.mark = mark
        button.enabled = environment.isEnabled
    }
    override var fittingSize: NSSize { TranscriptHostedSize.fitting(button.size) }
    override var intrinsicContentSize: NSSize { fittingSize }
    override func layout() {
        super.layout()
        let size = button.size
        button.frame = TranscriptMotion.pixelAligned(CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                                            width: size.width, height: size.height), scale: window?.backingScaleFactor ?? 2)
    }
}
