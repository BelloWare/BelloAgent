import AppKit
import Combine

/// ⌘P's list over the window: a field, the files found, and a line saying
/// what the list is (and what the keys do). A click outside closes it; the
/// keys it answers are taken before anything else in the window
/// (`WorkspaceModel.quickOpenKey`).
@MainActor final class QuickOpenOverlay: NSView {
    let quickOpen: QuickOpen
    let panel: QuickOpenPanel
    private var observation: AnyCancellable?
    init(quickOpen: QuickOpen, open: @escaping (String?) -> Void) {
        self.quickOpen = quickOpen
        panel = QuickOpenPanel(quickOpen: quickOpen, open: open)
        super.init(frame: .zero)
        addSubview(panel)
        setAccessibilityElement(false)
        observation = quickOpen.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    private var wasOpen = false
    func refresh() {
        isHidden = !quickOpen.isOpen
        if quickOpen.isOpen {
            panel.refresh()
            if !wasOpen { panel.focusField() }
        }
        wasOpen = quickOpen.isOpen
        needsLayout = true
    }
    /// Everywhere outside the panel: a click there closes the list.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard quickOpen.isOpen, !isHidden else { return nil }
        if let hit = super.hitTest(point), hit !== self { return hit }
        // Below the title bar, as SwiftUI's layer lay inside the safe area.
        let local = convert(point, from: superview)
        return frame.contains(point) && local.y >= safeAreaInsets.top ? self : nil
    }
    override func mouseDown(with event: NSEvent) { quickOpen.close(restoringFocus: true) }
    override func layout() {
        super.layout()
        let width = min(QuickOpenPanel.width, max(320, bounds.width - 80))
        let height = panel.height(forWidth: width)
        // Inside the safe area, under the title bar, as SwiftUI placed it.
        panel.frame = CGRect(x: PiKit.round((bounds.width - width) / 2, piScale), y: safeAreaInsets.top + QuickOpenPanel.top, width: width, height: height)
    }
}

@MainActor final class QuickOpenPanel: NSView, NSTextFieldDelegate {
    let quickOpen: QuickOpen
    let open: (String?) -> Void
    static let width: CGFloat = 640
    static let top: CGFloat = 56
    static let rowHeight: CGFloat = 32
    static let visibleRows = 12

    private let chrome = PiKit.elevated(NSView(), radius: 14)
    private let content = FlippedView()
    private let magnifier = PiKit.SymbolView(PiKit.Symbol("magnifyingglass", size: 14, weight: .medium), color: .piInkTertiary)
    let field = NSTextField()
    private let spinner = piSpinner(size: 12)
    private let rule = HairlineView()
    private let list = LazyStackView()
    private let footerBox = FillView(.piSurfaceSunken)
    private let footerRule = HairlineView()
    private let footerLine = TextBlock("", font: PiKit.Font.caption, color: .piInkSecondary, maximumLines: 2)
    private let warningLine = TextBlock("", font: PiKit.Font.caption, color: .piWarning, maximumLines: 2)
    private var hovered: String?
    private var shownSelection: String?

    init(quickOpen: QuickOpen, open: @escaping (String?) -> Void) {
        self.quickOpen = quickOpen; self.open = open
        super.init(frame: .zero)
        PiKit.configurePlain(field, font: .systemFont(ofSize: 15), placeholder: "Find a file")
        field.delegate = self
        field.setAccessibilityLabel("Find a file")
        field.setAccessibilityIdentifier("quickOpenField")
        list.overscan = 64
        list.insets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        footerBox.setAccessibilityElement(true); footerBox.setAccessibilityRole(.staticText)
        footerBox.setAccessibilityIdentifier("quickOpenStatus")
        footerBox.addSubview(footerLine); footerBox.addSubview(warningLine)
        chrome.content = content
        for view in [magnifier, field, spinner, rule, list, footerBox, footerRule] as [NSView] { content.addSubview(view) }
        addSubview(chrome)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("Open File"); setAccessibilityIdentifier("quickOpen")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func focusField() {
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated {
            guard let self, self.quickOpen.isOpen, let window = self.window else { return }
            window.makeFirstResponder(self.field)
        } }
    }
    func controlTextDidChange(_ notification: Notification) { quickOpen.query = field.stringValue }

    private var recentHeader: Bool { quickOpen.query.trimmingCharacters(in: .whitespaces).isEmpty }
    private enum Row: Hashable { case header, file(String) }
    func refresh() {
        if field.stringValue != quickOpen.query { field.stringValue = quickOpen.query }
        field.placeholderString = quickOpen.project.map { "Find a file in \($0.name)" } ?? "Find a file"
        spinner.isHidden = quickOpen.status != .listing
        let rows = quickOpen.rows
        var items: [Row] = []
        if !rows.isEmpty {
            if recentHeader { items.append(.header) }
            items += rows.map { .file($0.id) }
        }
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let selection = quickOpen.selection
        list.reload(LazyStackView.Source(count: items.count, key: { AnyHashable(items[$0]) }, height: { index, _ in
            if case .header = items[index] { return QuickOpenHeaderRow.height }
            return QuickOpenPanel.rowHeight
        }, view: { [weak self] index, existing in
            switch items[index] {
            case .header: return existing ?? QuickOpenHeaderRow()
            case .file(let id):
                guard let self, let row = byID[id] else { return existing ?? NSView() }
                let view = existing as? QuickOpenRowView ?? QuickOpenRowView()
                view.apply(row, selected: row.id == selection, hovered: row.id == self.hovered)
                view.press = { [weak self] in self?.open(row.id) }
                view.hover = { [weak self] inside in self?.setHovered(inside ? row.id : (self?.hovered == row.id ? nil : self?.hovered)) }
                return view
            }
        }))
        footerLine.text = footerText; footerLine.color = footerTone
        let warning = warningText
        warningLine.text = warning ?? ""; warningLine.isHidden = warning == nil
        warningLine.toolTip = quickOpen.warnings.joined(separator: "\n")
        footerBox.setAccessibilityLabel([footerText, warning].compactMap { $0 }.joined(separator: ", "))
        footerRule.isHidden = rows.isEmpty
        if selection != shownSelection {
            shownSelection = selection
            if let selection, let index = items.firstIndex(of: .file(selection)) { list.scrollToRow(index) }
        }
        needsLayout = true
    }
    private func setHovered(_ id: String?) {
        guard hovered != id else { return }
        hovered = id
        refresh()
    }

    // MARK: Layout

    private var listHeight: CGFloat {
        let rows = quickOpen.rows.count
        guard rows > 0 else { return 0 }
        return min(CGFloat(rows), CGFloat(Self.visibleRows)) * Self.rowHeight + 12 + (recentHeader ? 26 : 0)
    }
    private func footerHeight(_ width: CGFloat) -> CGFloat {
        let inner = width - 28
        var height = footerLine.height(forWidth: inner)
        if !warningLine.isHidden { height += 3 + warningLine.height(forWidth: inner) }
        return height + 18
    }
    func height(forWidth width: CGFloat) -> CGFloat { 46 + 1 + listHeight + footerHeight(width) }
    override func layout() {
        super.layout()
        let width = bounds.width, scale = piScale
        chrome.frame = bounds
        content.frame = bounds
        var items: [StackLayout.Item] = [.fixed(magnifier), .view(field, .flexible(height: { _ in PiKit.Line("", font: .systemFont(ofSize: 15), color: .black).lineHeight }))]
        if !spinner.isHidden { items.append(.fixed(spinner)) }
        let frames = StackLayout.place(items, spacing: 10, in: CGRect(x: 14, y: 0, width: width - 28, height: 46), scale: scale)
        field.frame = frames[1].insetBy(dx: -PiKit.fieldInset, dy: 0)
        rule.frame = CGRect(x: 0, y: 46, width: width, height: 1)
        let listHeight = listHeight
        list.isHidden = listHeight == 0
        list.frame = CGRect(x: 0, y: 47, width: width, height: listHeight)
        let footerY = 47 + listHeight, footer = footerHeight(width)
        footerBox.frame = CGRect(x: 0, y: footerY, width: width, height: footer)
        footerRule.frame = CGRect(x: 0, y: footerY, width: width, height: 1)
        let inner = width - 28
        let lineHeight = footerLine.height(forWidth: inner)
        footerLine.frame = CGRect(x: 14, y: 9, width: inner, height: lineHeight)
        warningLine.frame = CGRect(x: 14, y: 9 + lineHeight + 3, width: inner, height: warningLine.height(forWidth: inner))
    }

    /// What the listing left out, when it did: the first thing, and how many more.
    private var warningText: String? {
        guard let first = quickOpen.warnings.first, quickOpen.status == .ready || quickOpen.status == .listing else { return nil }
        let more = quickOpen.warnings.count - 1
        return more > 0 ? first + " (and \(more) more)" : first
    }

    private var footerTone: NSColor {
        switch quickOpen.status {
        case .failed, .untrusted: return .piWarning
        default: return .piInkSecondary
        }
    }

    /// What the list is, or why it is empty, and what the keys do.
    var footerText: String {
        let name = quickOpen.project?.name ?? "the project"
        let coverage = quickOpen.truncated ? " Only the first \(quickOpen.searchedFileCount.formatted()) files are searched." : ""
        switch quickOpen.status {
        case .untrusted: return "\(name) is not trusted, so its files are not listed."
        case .failed(let reason):
            return (quickOpen.hasListing ? "List as last read. Refresh failed: \(reason)" : "The files in \(name) could not be listed: \(reason)") + coverage
        case .listing where quickOpen.rows.isEmpty: return "Finding the files in \(name)…" + coverage
        default: break
        }
        let typed = quickOpen.query.trimmingCharacters(in: .whitespaces)
        if quickOpen.rows.isEmpty {
            if typed.isEmpty { return "Type part of a file's name to find it in \(name). End with :N to open at line N." + coverage }
            return (quickOpen.searched ? "No file in \(name) matches “\(typed)”." : "Finding…") + coverage
        }
        var parts = ["↑↓ to choose", "↩ to open" + (quickOpen.line.map { " at line \($0)" } ?? ""), "esc to close"]
        if quickOpen.truncated { parts.append("only the first \(quickOpen.searchedFileCount.formatted()) files are searched") }
        return parts.joined(separator: " · ")
    }
}

/// "Opened lately", over the recent files.
@MainActor final class QuickOpenHeaderRow: NSView {
    static let height: CGFloat = 8 + 13 + 4
    private let text = PiKit.TextLine(PiKit.Line("Opened lately", font: PiKit.Font.micro, color: .piInkTertiary, tracking: 0.4, uppercased: true))
    override init(frame: NSRect) { super.init(frame: frame); addSubview(text) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let size = text.intrinsicContentSize
        text.frame = CGRect(x: 14, y: 8, width: min(size.width, bounds.width - 28), height: size.height)
    }
}

/// One file of the list: its kind, its name and its folder, the query's
/// characters in accent ink.
@MainActor final class QuickOpenRowView: NSView {
    private let symbol = PiKit.SymbolView(PiKit.Symbol("doc", size: 12, weight: .medium), color: .piInkTertiary)
    private let name = HighlightedLine(font: .systemFont(ofSize: 13, weight: .medium), ink: .piInk)
    private let folder = HighlightedLine(font: .systemFont(ofSize: 12), ink: .piInkSecondary)
    private let fill = PiKit.Box(cornerRadius: PiRadius.sm)
    private var tracking: NSTrackingArea?
    private var row: QuickOpen.Row?
    private var selected = false
    var press: (() -> Void)?
    var hover: ((Bool) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        folder.truncation = .start
        for view in [fill, symbol, name, folder] as [NSView] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func apply(_ row: QuickOpen.Row, selected: Bool, hovered: Bool) {
        self.row = row; self.selected = selected
        symbol.symbol = PiKit.Symbol(row.symbol, size: 12, weight: .medium)
        symbol.color = selected ? .piAccent : .piInkTertiary
        name.set(row.name, matches: row.nameMatches)
        folder.set(row.folder, matches: row.folderMatches); folder.isHidden = row.folder.isEmpty
        fill.fillColor = selected ? .piAccentSoft : hovered ? .piFill : nil
        setAccessibilityLabel(row.label)
        needsLayout = true
    }
    override func isAccessibilitySelected() -> Bool { selected }
    override func accessibilityPerformPress() -> Bool { press?(); return true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hover?(true) }
    override func mouseExited(with event: NSEvent) { hover?(false) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { press?() } }
    override func layout() {
        super.layout()
        fill.frame = bounds.insetBy(dx: 6, dy: 0)
        var items: [StackLayout.Item] = [.view(symbol, .fixed(CGSize(width: 16, height: symbol.intrinsicContentSize.height))), .view(name, name.sizing(priority: 1))]
        if !folder.isHidden { items.append(.view(folder, folder.sizing())) }
        items.append(.spacer(0))
        StackLayout.place(items, spacing: 9, in: CGRect(x: 16, y: 0, width: bounds.width - 32, height: bounds.height), scale: piScale)
    }
}

/// A line of text with some of its characters (UTF-8 ranges) in accent
/// ink, semibold; cut at its end or start when it has less room.
@MainActor final class HighlightedLine: NSView {
    let font: NSFont, ink: NSColor
    var truncation: CTLineTruncationType = .end
    private var text = "", matches: [Range<Int>] = []
    init(font: NSFont, ink: NSColor) {
        self.font = font; self.ink = ink
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func set(_ text: String, matches: [Range<Int>]) {
        guard text != self.text || matches != self.matches else { return }
        self.text = text; self.matches = matches
        invalidateIntrinsicContentSize(); needsDisplay = true
    }
    /// The text, its matched characters in accent ink, semibold.
    private func attributed(_ ink: NSColor, _ accent: NSColor) -> NSAttributedString {
        let bold = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        let result = NSMutableAttributedString()
        let bytes = Array(text.utf8)
        var at = 0
        func piece(_ range: Range<Int>, matched: Bool) {
            let string = String(decoding: bytes[range], as: UTF8.self)
            result.append(NSAttributedString(string: string, attributes: [.font: matched ? bold : font, .foregroundColor: matched ? accent : ink,
                                                                          NSAttributedString.Key(kCTForegroundColorAttributeName as String): (matched ? accent : ink).cgColor]))
        }
        for match in matches.sorted(by: { $0.lowerBound < $1.lowerBound }) where match.lowerBound >= at && match.upperBound <= bytes.count {
            if match.lowerBound > at { piece(at..<match.lowerBound, matched: false) }
            piece(match, matched: true)
            at = match.upperBound
        }
        if at < bytes.count { piece(at..<bytes.count, matched: false) }
        return result
    }
    private var lineHeight: CGFloat { PiKit.Line("", font: font, color: .black).lineHeight }
    override var intrinsicContentSize: NSSize {
        let line = CTLineCreateWithAttributedString(attributed(.black, .black))
        return NSSize(width: PiKit.ceil(CTLineGetTypographicBounds(line, nil, nil, nil), piScale), height: lineHeight)
    }
    func sizing(priority: Double = 0) -> StackLayout.Sizing {
        StackLayout.Sizing(width: { [weak self] proposal in min(self?.intrinsicContentSize.width ?? 0, max(0, proposal)) },
                           height: { [weak self] _ in self?.lineHeight ?? 0 }, priority: priority)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, !text.isEmpty else { return }
        var resolved: (NSColor, NSColor) = (ink, .piAccent)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = (NSColor(cgColor: self.ink.cgColor) ?? self.ink, NSColor(cgColor: NSColor.piAccent.cgColor) ?? .piAccent)
        }
        var line = CTLineCreateWithAttributedString(attributed(resolved.0, resolved.1))
        if CTLineGetTypographicBounds(line, nil, nil, nil) > bounds.width + 0.01 {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [.font: font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): resolved.0.cgColor]))
            guard let cut = CTLineCreateTruncatedLine(line, Double(bounds.width), truncation, ellipsis) else { return }
            line = cut
        }
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: 0, y: PiKit.Line("", font: font, color: .black).baseline(scale: piScale))
        CTLineDraw(line, context)
        context.restoreGState()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
