import AppKit
import GitView

/// The commit's files as chips; one narrows the diff to that file, "All"
/// widens it again. The chips are drawn by one native view: two hundred
/// buttons, each with its tooltip, menu and pointer, took a fifth of a second
/// to build every time a commit that touched them opened. The first two
/// hundred are shown, then a chip that adds the next step.
@MainActor enum GitCommitFileChips {
    static var step: Int { GitController.commitFilesStep }

    /// Shows `detail`'s files in `view`: `selected` is the file the diff is
    /// narrowed to, `shown` how many are listed.
    static func show(_ detail: GitCommitDetail, selected: String?, shown: Int, in view: GitFileChipsView,
                     select: @escaping (String?) -> Void, showMore: @escaping () -> Void, showHistory: @escaping (String) -> Void) {
        let files = detail.files.count <= shown ? detail.files[...] : detail.files[..<shown]
        var chips: [GitFileChip] = [GitFileChip(kind: .all, text: "All \(detail.files.count) files", icon: selected == nil ? "checkmark" : nil)]
        for file in files {
            let stat = detail.stats[file.path]
            let counts = stat.map { $0.binary ? " · binary" : " · +\($0.added) −\($0.removed)" } ?? ""
            let tone: PiTone = selected == file.path ? .accent : file.badge == "D" ? .danger : file.badge == "A" ? .success : .neutral
            chips.append(GitFileChip(kind: .file(file.path), text: "\(file.badge) \((file.path as NSString).lastPathComponent)" + counts,
                                     help: file.path + counts, tone: tone))
        }
        if detail.files.count > shown {
            chips.append(GitFileChip(kind: .more, text: "\(detail.files.count - shown) more files", icon: "ellipsis"))
        }
        view.show(chips) { chip in
            switch chip.kind {
            case .all: select(nil)
            case .file(let path): select(selected == path ? nil : path)
            case .more: showMore()
            }
        } history: { showHistory($0) }
    }
}

/// One chip: "All", a file, or "N more files".
struct GitFileChip: Equatable {
    enum Kind: Equatable { case all, file(String), more }
    let kind: Kind
    let text: String
    var icon: String? = nil
    var help: String? = nil
    var tone: PiTone = .neutral

    /// "All" and "more" are drawn as `PiChip`, the files as `PiBadge`.
    var isBadge: Bool { if case .file = kind { return true } else { return false } }
    var identifier: String? {
        switch kind {
        case .file(let path): return "git-commit-file-" + path
        case .more: return "git-commit-more-files"
        case .all: return nil
        }
    }
}

/// The chips, laid out as `PiFlow` lays them out: left to right, 6 points
/// apart, a new row 6 points down when the next does not fit, each row as tall
/// as its tallest chip and every chip at its top.
final class GitFileChipsView: NSView, NSViewToolTipOwner, PiKit.WidthSizing {
    private var chips: [GitFileChip] = []
    private var press: (GitFileChip) -> Void = { _ in }
    private var history: (String) -> Void = { _ in }
    private var sizes: [CGSize] = []
    private var sizedScale: CGFloat = 0
    private var frames: [CGRect] = []
    private var framesWidth: CGFloat = -1
    private var pressed: Int?
    private var elements: [GitFileChipElement] = []

    static let spacing: CGFloat = 6
    static let caption = NSFont.systemFont(ofSize: PiKit.Font.captionSize)
    static let micro = NSFont.systemFont(ofSize: 10.5, weight: .medium)

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Files in this commit")
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); sizes = []; framesWidth = -1; needsDisplay = true }

    func show(_ next: [GitFileChip], press: @escaping (GitFileChip) -> Void, history: @escaping (String) -> Void) {
        self.press = press; self.history = history
        guard next != chips else { return }
        chips = next; sizes = []; framesWidth = -1; elements = []
        needsDisplay = true
        invalidateIntrinsicContentSize()
        window?.invalidateCursorRects(for: self)
        removeAllToolTips()
        needsLayout = true
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// Each chip's size, as SwiftUI sizes a badge (10.5-point medium text, 8
    /// points either side, 3.5 above and below) or a chip (11.5-point text
    /// after an optional symbol, 10 points either side, 5 above and below).
    private func measure() {
        guard sizes.count != chips.count || sizedScale != scale else { return }
        if sizedScale != scale { widths = [:] }
        sizedScale = scale
        sizes = chips.map { chip in
            if chip.isBadge { return CGSize(width: 16 + width(chip.text, font: Self.micro), height: 20) }
            let icon = chip.icon.map { GitFileChipsView.symbolWidth($0) + 5 } ?? 0
            return CGSize(width: 20 + icon + width(chip.text, font: Self.caption), height: 24)
        }
    }
    /// Each text's width, kept: choosing a chip changes a tone, or the "All"
    /// chip's tick, and measures only what is new.
    private var widths: [String: CGFloat] = [:]
    private func width(_ text: String, font: NSFont) -> CGFloat {
        let key = (font === Self.micro ? "m|" : "c|") + text
        if let known = widths[key] { return known }
        let measured = GitDiffText.frameWidth(text, font: font, scale: scale)
        widths[key] = measured
        return measured
    }
    static func symbolWidth(_ name: String) -> CGFloat { symbol(name)?.alignmentRect.width ?? 11 }
    /// A chip's symbol: 10-point semibold, in `color` when given. One
    /// configuration: a second one applied on top replaces the first.
    static func symbol(_ name: String, color: NSColor? = nil) -> NSImage? {
        var configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        if let color { configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [color.usingColorSpace(.sRGB) ?? color])) }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    /// Where each chip goes in a row this wide.
    private func layOut(width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        measure()
        var frames: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for var size in sizes {
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + Self.spacing; rowHeight = 0 }
            // Wider than the row, alone on it: cut to the row, its words cut in the middle.
            size.width = min(size.width, max(width, 0))
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + Self.spacing; rowHeight = max(rowHeight, size.height)
        }
        return (frames, y + rowHeight)
    }
    func height(forWidth width: CGFloat) -> CGFloat { layOut(width: width).height }
    var naturalWidth: CGFloat { measure(); return sizes.reduce(0) { $0 + $1.width + Self.spacing } - Self.spacing }
    private func currentFrames() -> [CGRect] {
        if framesWidth != bounds.width || frames.count != chips.count {
            frames = layOut(width: bounds.width).frames; framesWidth = bounds.width
            elements = []
            removeAllToolTips()
            for (index, frame) in frames.enumerated() where chips[index].help != nil || !chips[index].isBadge { addToolTip(frame, owner: self, userData: nil) }
        }
        return frames
    }
    override func layout() { super.layout(); _ = currentFrames(); window?.invalidateCursorRects(for: self) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for (index, frame) in currentFrames().enumerated() where frame.intersects(dirtyRect.insetBy(dx: -2, dy: -2)) {
            context.saveGState()
            if pressed == index { context.setAlpha(0.6) }
            if chips[index].isBadge { drawBadge(chips[index], in: frame, context: context) } else { drawChip(chips[index], in: frame, context: context) }
            context.restoreGState()
        }
    }

    private func toneColor(_ tone: PiTone) -> NSColor {
        switch tone {
        case .neutral: return .piInkSecondary
        case .accent: return .piAccent
        case .success: return .piSuccess
        case .warning: return .piWarning
        case .danger: return .piDanger
        case .info: return .piInfo
        }
    }

    /// `PiBadge`: its text in its tone on a capsule of the tone at 13 per
    /// cent, or of the quiet fill when neutral.
    private func drawBadge(_ chip: GitFileChip, in frame: CGRect, context: CGContext) {
        let capsule = CGPath(roundedRect: frame, cornerWidth: frame.height / 2, cornerHeight: frame.height / 2, transform: nil)
        context.addPath(capsule)
        context.setFillColor(chip.tone == .neutral ? GitDiffMetrics.fill(.piFill, opacity: 1) : GitDiffMetrics.fill(toneColor(chip.tone), opacity: 0.13))
        context.fillPath()
        let baseline = frame.minY + 3.5 + GitDiffMetrics.microBaseline
        if frame.width < 16 + width(chip.text, font: Self.micro) {
            GitDiffText.draw(chip.text, font: Self.micro, color: toneColor(chip.tone), x: frame.minX + 8, baseline: baseline, width: frame.width - 16, truncation: .middle, in: context)
        } else {
            GitDiffText.drawKept(chip.text, font: Self.micro, color: toneColor(chip.tone), x: frame.minX + 8, baseline: baseline, in: context)
        }
    }

    /// `PiChip`: an accent symbol and its text on the raised surface, in a
    /// capsule with the strong hairline round it.
    private func drawChip(_ chip: GitFileChip, in frame: CGRect, context: CGContext) {
        let capsule = CGPath(roundedRect: frame, cornerWidth: frame.height / 2, cornerHeight: frame.height / 2, transform: nil)
        context.addPath(capsule)
        context.setFillColor(GitDiffMetrics.fill(.piSurface, opacity: 1))
        context.fillPath()
        context.addPath(capsule)
        context.setStrokeColor(GitDiffMetrics.fill(.piHairlineStrong, opacity: 1)); context.setLineWidth(1)
        context.strokePath()
        var x = frame.minX + 10
        if let name = chip.icon, let image = Self.symbol(name, color: .piAccent) {
            let alignment = image.alignmentRect
            // The symbol's alignment rectangle, centred on the text's 14 points,
            // and half a point up, where SwiftUI's own centring puts it.
            let top = frame.minY + 5 + (14 - alignment.height) / 2 - (image.size.height - alignment.maxY) - 0.5
            image.draw(in: CGRect(x: x - alignment.minX, y: top, width: image.size.width, height: image.size.height), from: .zero, operation: .sourceOver,
                       fraction: 1, respectFlipped: true, hints: nil)
            x += alignment.width + 5
        }
        if frame.maxX - 10 < x + width(chip.text, font: Self.caption) {
            GitDiffText.draw(chip.text, font: Self.caption, color: .piInk, x: x, baseline: frame.minY + 5 + 11, width: frame.maxX - 10 - x, truncation: .middle, in: context)
        } else {
            GitDiffText.drawKept(chip.text, font: Self.caption, color: .piInk, x: x, baseline: frame.minY + 5 + 11, in: context)
        }
    }

    // MARK: Pointer, clicks, menus and tooltips

    private func chip(at point: NSPoint) -> Int? { currentFrames().firstIndex { $0.contains(point) } }

    override func resetCursorRects() {
        for frame in currentFrames() { addCursorRect(frame, cursor: .pointingHand) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = chip(at: point), let window else { return super.mouseDown(with: event) }
        pressed = index; setNeedsDisplay(currentFrames()[index].insetBy(dx: -2, dy: -2))
        var inside = true
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            inside = currentFrames()[index].contains(convert(next.locationInWindow, from: nil))
            let shown: Int? = inside ? index : nil
            if shown != pressed { pressed = shown; setNeedsDisplay(currentFrames()[index].insetBy(dx: -2, dy: -2)) }
            if next.type == .leftMouseUp { break }
        }
        pressed = nil; setNeedsDisplay(currentFrames()[index].insetBy(dx: -2, dy: -2))
        if inside { press(chips[index]) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = chip(at: convert(event.locationInWindow, from: nil)), case .file(let path) = chips[index].kind else { return nil }
        let history = history
        return PiMenus.menu([
            .button("Show History of This File", systemImage: "clock.arrow.circlepath") { history(path) },
            .button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) },
        ])
    }
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let index = chip(at: point) else { return "" }
        return chips[index].help ?? chips[index].text
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        let frames = currentFrames()
        if elements.count != chips.count {
            elements = chips.indices.map { index in
                let element = GitFileChipElement()
                element.action = { [weak self] in self?.pressChip(index) }
                element.setAccessibilityRole(.button)
                element.setAccessibilityLabel(chips[index].text)
                element.setAccessibilityParent(self)
                if let identifier = chips[index].identifier { element.setAccessibilityIdentifier(identifier) }
                return element
            }
        }
        for (index, element) in elements.enumerated() where index < frames.count { element.setAccessibilityFrameInParentSpace(frames[index]) }
        return elements
    }
    fileprivate func pressChip(_ index: Int) { if index < chips.count { press(chips[index]) } }
}

/// One chip, to assistive technology: a button with the chip's words.
final class GitFileChipElement: NSAccessibilityElement {
    nonisolated(unsafe) var action: (@MainActor @Sendable () -> Void)?
    override func accessibilityPerformPress() -> Bool {
        guard let action else { return false }
        MainActor.assumeIsolated { action() }
        return true
    }
}
