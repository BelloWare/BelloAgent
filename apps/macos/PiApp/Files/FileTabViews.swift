import AppKit
import Combine
import FileView
import GitView
import PDFKit

/// A file tab's content: its header over its text, or what it shows instead.
/// Above whatever the file shows, and apart from it, the find or go-to-line
/// bar and the blame bar: a reload that finds the file gone, or not text,
/// leaves the bar, its field and its keys as they were.
@MainActor final class FileTabContent: NSView, PiKit.SizeObserver {
    private weak var tab: FileTab?
    private let header: FileTabHeader
    private let findBar: FileFindBar
    private let lineBar: FileGoToLineBar
    private let blameBar: FileBlameBar
    private let missing: FileTabNotice
    private let notText: FileTabNotice
    private var preview: FilePreviewView?
    /// The text's scroll view as placed here (the tab keeps it).
    private weak var placedScroll: NSView?
    private var observations: [AnyCancellable] = []
    private var refreshScheduled = false
    private enum Shown { case missing, preview, notText, text, nothing }
    private var shown = Shown.nothing

    init(tab: FileTab) {
        self.tab = tab
        header = FileTabHeader(tab: tab)
        findBar = FileFindBar(tab: tab)
        lineBar = FileGoToLineBar(tab: tab)
        blameBar = FileBlameBar(blame: tab.blame)
        missing = FileTabNotice(symbol: "questionmark.folder", title: "Missing", url: tab.url)
        notText = FileTabNotice(symbol: "doc", title: "Not text", url: tab.url)
        super.init(frame: .zero)
        wantsLayer = true
        for view in [header, findBar, lineBar, blameBar, missing, notText] as [NSView] { addSubview(view) }
        observations.append(tab.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() })
        observations.append(tab.blame.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() })
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piContent) }
    func contentSizeChanged() { needsLayout = true }

    private func scheduleRefresh() {
        needsLayout = true
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { if self?.refreshScheduled == true { self?.refresh() } } }
    }

    func refresh() {
        refreshScheduled = false
        guard let tab else { return }
        header.refresh()
        let bars = tab.readable && tab.previewKind == nil
        findBar.setShown(bars && tab.bar == .find)
        lineBar.setShown(bars && tab.bar == .goToLine)
        blameBar.isHidden = !(bars && tab.blame.isOn)
        if !blameBar.isHidden { blameBar.refresh() }
        let next: Shown
        if let reason = tab.missingReason {
            missing.set(detail: reason); next = .missing
        } else if tab.previewKind != nil {
            // The tab's preview, as it is now: one made again after trust
            // came back is another.
            let model = tab.preview
            if preview?.preview !== model {
                preview?.removeFromSuperview()
                let made = FilePreviewView(preview: model)
                addSubview(made); preview = made
            }
            next = .preview
        } else if tab.status == .binary {
            notText.set(detail: FileTabNotice.describe(tab.url)); next = .notText
        } else if let scroll = tab.scroll {
            if let old = placedScroll, old !== scroll, old.superview === self { old.removeFromSuperview() }
            if scroll.superview !== self { scroll.removeFromSuperview(); addSubview(scroll, positioned: .below, relativeTo: header) }
            placedScroll = scroll
            next = .text
        } else {
            next = .nothing
        }
        // A text the tab let go of (trust withdrawn) leaves with it.
        if let old = placedScroll, old !== tab.scrollIfMade, old.superview === self { old.removeFromSuperview(); placedScroll = nil }
        if next != .preview, preview != nil, !tab.readable { preview?.removeFromSuperview(); preview = nil }
        shown = next
        missing.isHidden = next != .missing
        notText.isHidden = next != .notText
        preview?.isHidden = next != .preview
        // Not text: the text view leaves, as SwiftUI took its host away, so
        // nothing gives it the keys while it cannot be seen.
        if next != .text, let scroll = placedScroll, scroll.superview === self { scroll.removeFromSuperview(); placedScroll = nil }
        needsLayout = true
    }

    override func layout() {
        if refreshScheduled { refresh() }
        super.layout()
        let width = bounds.width
        header.frame = CGRect(x: 0, y: 0, width: width, height: 32)
        var y: CGFloat = 32
        for bar in [findBar, lineBar, blameBar] as [NSView] where !bar.isHidden {
            bar.frame = CGRect(x: 0, y: y, width: width, height: 36); y += 36
        }
        let content = CGRect(x: 0, y: y, width: width, height: max(0, bounds.height - y))
        missing.frame = content; notText.frame = content; preview?.frame = content
        if let scroll = placedScroll, scroll.superview === self { scroll.frame = content }
    }
}

/// The file's path and state, blame, and Open in its app.
@MainActor final class FileTabHeader: NSView {
    private weak var tab: FileTab?
    private let project = PiKit.TextLine(PiKit.Line("", font: .systemFont(ofSize: PiKit.Font.captionSize, weight: .medium), color: .piInkSecondary))
    private let chevron = PiKit.SymbolView(PiKit.Symbol("chevron.right", size: 8, weight: .semibold), color: .piInkTertiary)
    private let rest = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInkSecondary))
    private let pathGroup = NSView()
    private var badge: PiKit.Badge?
    private let blameToggle: PiKit.IconButton
    private let openButton: PiKit.IconButton
    private let rule = HairlineView()
    private var hasProject = false

    init(tab: FileTab) {
        self.tab = tab
        blameToggle = PiKit.IconButton(symbol: "person.text.rectangle", label: "Show Blame", size: 26) { [weak tab] in tab?.blame.toggle() }
        openButton = PiKit.IconButton(symbol: "arrow.up.forward.app", label: "Open in \(Self.appName(for: tab.url))", size: 26) { [weak tab] in
            if let url = tab?.url { NSWorkspace.shared.open(url) }
        }
        super.init(frame: .zero)
        rest.truncation = .start
        blameToggle.setAccessibilityIdentifier("file-blame-toggle")
        openButton.setAccessibilityIdentifier("file-open-in-app")
        for view in [project, chevron, rest] as [NSView] { pathGroup.addSubview(view) }
        pathGroup.setAccessibilityElement(true); pathGroup.setAccessibilityRole(.staticText)
        for view in [pathGroup, blameToggle, openButton, rule] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func refresh() {
        guard let tab else { return }
        let (name, path) = shownPath(tab)
        hasProject = name != nil
        project.line.text = name ?? ""; project.isHidden = name == nil; chevron.isHidden = name == nil
        rest.line.text = path
        pathGroup.toolTip = tab.help
        pathGroup.setAccessibilityLabel([name, path].compactMap { $0 }.joined(separator: ", "))
        setBadge(Self.badge(tab))
        blameToggle.isHidden = !(tab.readable && tab.previewKind == nil)
        let on = tab.blame.isOn
        blameToggle.label = on ? "Hide Blame" : "Show Blame"
        blameToggle.tone = on ? .accent : .neutral
        blameToggle.filled = on
        needsLayout = true
    }
    private struct BadgeSpec: Equatable { var text: String, tone: PiTone, icon: String, help: String? }
    private var badgeSpec: BadgeSpec?
    private func setBadge(_ spec: BadgeSpec?) {
        guard spec != badgeSpec else { return }
        badgeSpec = spec
        badge?.removeFromSuperview(); badge = nil
        guard let spec else { return }
        let made = PiKit.Badge(text: spec.text, tone: spec.tone, icon: spec.icon)
        made.toolTip = spec.help
        addSubview(made); badge = made
    }
    private static func badge(_ tab: FileTab) -> BadgeSpec? {
        if tab.missingReason != nil { return BadgeSpec(text: "Missing", tone: .danger, icon: "exclamationmark.triangle", help: nil) }
        switch tab.status {
        case .indexing: return BadgeSpec(text: "Reading…", tone: .neutral, icon: "hourglass", help: nil)
        case .ready: return tab.fellBack ? BadgeSpec(text: "Latin-1", tone: .warning, icon: "textformat", help: "Not valid UTF-8: shown a byte a character") : nil
        case .binary: return BadgeSpec(text: "Not text", tone: .neutral, icon: "doc", help: nil)
        case .changed: return BadgeSpec(text: "Changed on disk", tone: .warning, icon: "arrow.triangle.2.circlepath", help: "Shown as it was when opened")
        case .truncated(let limit): return BadgeSpec(text: "First \(limit.formatted()) lines", tone: .warning, icon: "scissors", help: nil)
        case .failed: return nil
        }
    }

    /// The project's name and the path within it, or the path from home.
    private func shownPath(_ tab: FileTab) -> (String?, String) {
        let path = tab.url.path
        switch tab.project {
        case .trusted(let name, let root):
            let root = root.hasSuffix("/") ? String(root.dropLast()) : root
            if path.hasPrefix(root + "/") { return (name, String(path.dropFirst(root.count + 1))) }
            return (name, Self.abbreviated(path))
        case .untrusted(let name): return (name, Self.abbreviated(path))
        case .none, .removed: return (nil, Self.abbreviated(path))
        }
    }
    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    /// The app a file opens in, for the button that opens it there.
    static func appName(for url: URL) -> String {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return "Default App" }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    private var pathItems: [StackLayout.Item] {
        var items: [StackLayout.Item] = []
        if hasProject { items.append(.fixed(project)); items.append(.fixed(chevron)) }
        items.append(.line(rest))
        return items
    }
    override func layout() {
        super.layout()
        var items: [StackLayout.Item] = [.row(pathItems, spacing: 4)]
        if let badge { items.append(.fixed(badge)) }
        items.append(.spacer(PiSpacing.sm))
        if !blameToggle.isHidden { items.append(.fixed(blameToggle)) }
        items.append(.fixed(openButton))
        let frames = StackLayout.place(items, spacing: PiSpacing.sm, in: CGRect(x: PiSpacing.md, y: 0, width: bounds.width - PiSpacing.md * 2, height: 32), scale: piScale)
        pathGroup.frame = frames[0]
        StackLayout.place(pathItems, spacing: 4, in: CGRect(origin: .zero, size: frames[0].size), scale: piScale)
        rule.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }
}

/// A bar's field: as the inspector's search field is drawn, a symbol and
/// plain text on the surface, its outline accented while it has the keys;
/// at most 280 points wide.
@MainActor final class FileBarField: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    private let symbol: PiKit.SymbolView
    private let box = PiKit.Box(fill: .piSurface, stroke: .piHairline, cornerRadius: 8)
    var onChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    private(set) var focused = false { didSet { box.strokeColor = focused ? NSColor.piAccent.withAlphaComponent(0.5) : .piHairline } }
    static let maximumWidth: CGFloat = 280
    init(symbol: String, placeholder: String, identifier: String) {
        self.symbol = PiKit.SymbolView(PiKit.Symbol(symbol, size: 11, weight: .medium), color: .piInkTertiary)
        super.init(frame: .zero)
        PiKit.configurePlain(field, font: PiKit.Font.caption, placeholder: placeholder)
        field.delegate = self
        field.setAccessibilityIdentifier(identifier)
        for view in [box, self.symbol, field] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    var text: String {
        get { field.stringValue }
        set { if field.stringValue != newValue { field.stringValue = newValue } }
    }
    private var textHeight: CGFloat { PiKit.Line("", font: PiKit.Font.caption, color: .black).lineHeight }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: textHeight + 12) }
    override func layout() {
        super.layout()
        box.frame = bounds
        let size = symbol.intrinsicContentSize, scale = piScale
        symbol.frame = CGRect(x: 9, y: PiKit.round((bounds.height - size.height) / 2, scale), width: size.width, height: size.height)
        let x = 9 + size.width + 6
        field.frame = CGRect(x: x - PiKit.fieldInset, y: 6, width: max(0, bounds.width - x - 9) + PiKit.fieldInset * 2, height: textHeight)
    }
    /// Puts the keys in the field.
    func focus() { window?.makeFirstResponder(field) }
    func controlTextDidBeginEditing(_ notification: Notification) { focused = true }
    func controlTextDidEndEditing(_ notification: Notification) { focused = false }
    func controlTextDidChange(_ notification: Notification) { onChange?(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): onSubmit?(); return true
        case #selector(NSResponder.cancelOperation(_:)): onEscape?(); return true
        default: return false
        }
    }
    private var responderObservation: NSKeyValueObservation?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Whether the field has the keys, as the window's first responder
        // changes (`@FocusState`): not only once editing begins.
        responderObservation = window?.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.keyChanged() } }
        }
    }
    /// Whether the field still has the keys (focus can leave without an end of editing).
    private func keyChanged() {
        let has = (window?.firstResponder as? NSTextView).map { $0.isFieldEditor && ($0.delegate as? NSTextField) === field } ?? false
        if has != focused { focused = has }
    }
}

/// A bar under the header, 36 points tall with a hairline under it; Escape
/// anywhere in it closes it.
@MainActor class FileBar: NSView {
    let rule = HairlineView()
    weak var tab: FileTab?
    private var lastFocus = -1
    init(tab: FileTab) {
        self.tab = tab
        super.init(frame: .zero)
        addSubview(rule)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override func cancelOperation(_ sender: Any?) { tab?.closeBar() }
    var field: FileBarField { fatalError("A bar has a field") }
    /// Shown or hidden; shown, the keys go to the field when first shown and
    /// whenever the tab asks again (`barFocus`).
    func setShown(_ shown: Bool) {
        let appearing = shown && isHidden
        isHidden = !shown
        guard shown, let tab else { return }
        update()
        if appearing || tab.barFocus != lastFocus {
            lastFocus = tab.barFocus
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated {
                guard let self, !self.isHiddenOrHasHiddenAncestor else { return }
                if (self.window?.firstResponder as? NSTextView)?.delegate as? NSTextField !== self.field.field { self.field.focus() }
            } }
        }
    }
    func update() {}
    override func layout() { super.layout(); rule.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1) }
}

/// A file's find bar, under its header: the query, where the match shown is
/// among them all, match case, previous and next, and close.
@MainActor final class FileFindBar: FileBar {
    private let input = FileBarField(symbol: "magnifyingglass", placeholder: "Find in file", identifier: "file-find-field")
    override var field: FileBarField { input }
    private let count = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInkSecondary))
    private let matchCase: PiKit.IconButton
    private let previous = PiKit.Button("", symbol: "chevron.up", style: .ghost)
    private let next = PiKit.Button("", symbol: "chevron.down", style: .ghost)
    private let close: PiKit.IconButton
    override init(tab: FileTab) {
        matchCase = PiKit.IconButton(symbol: "textformat", label: "Match Case: Off", size: 24) { [weak tab] in tab?.matchCase.toggle() }
        close = PiKit.IconButton(symbol: "xmark", label: "Close Find", size: 24) { [weak tab] in tab?.closeBar() }
        super.init(tab: tab)
        input.onChange = { [weak tab] in tab?.findQuery = $0 }
        input.onSubmit = { [weak tab] in
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { tab?.findPrevious() } else { tab?.findNext() }
        }
        input.onEscape = { [weak tab] in tab?.closeBar() }
        count.setAccessibilityIdentifier("file-find-count")
        matchCase.setAccessibilityIdentifier("file-find-match-case")
        previous.toolTip = "Previous match"; previous.setAccessibilityLabel("Previous match")
        next.toolTip = "Next match"; next.setAccessibilityLabel("Next match")
        previous.onPress = { [weak tab] in tab?.findPrevious() }
        next.onPress = { [weak tab] in tab?.findNext() }
        setAccessibilityElement(false); setAccessibilityIdentifier("file-find-bar")
        for view in [input, count, matchCase, previous, next, close] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override func update() {
        guard let tab else { return }
        input.text = tab.findQuery
        count.line.text = tab.findLabel
        matchCase.label = tab.matchCase ? "Match Case: On" : "Match Case: Off"
        matchCase.tone = tab.matchCase ? .accent : .neutral
        matchCase.filled = tab.matchCase
        previous.isEnabled = tab.canStep; next.isEnabled = tab.canStep
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let fieldHeight = input.intrinsicContentSize.height
        let items: [StackLayout.Item] = [.view(input, .flexible(max: FileBarField.maximumWidth, height: { _ in fieldHeight })), .line(count), .spacer(0),
                                         .fixed(matchCase), .fixed(previous), .fixed(next), .fixed(close)]
        StackLayout.place(items, spacing: PiSpacing.sm, in: CGRect(x: PiSpacing.md, y: 0, width: bounds.width - PiSpacing.md * 2, height: 36), scale: piScale)
    }
}

/// A file's go-to-line bar, where the find bar would be.
@MainActor final class FileGoToLineBar: FileBar {
    private let input = FileBarField(symbol: "arrow.right.to.line", placeholder: "Go to line", identifier: "file-go-to-line-field")
    override var field: FileBarField { input }
    private let range = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInkSecondary))
    private let close: PiKit.IconButton
    override init(tab: FileTab) {
        close = PiKit.IconButton(symbol: "xmark", label: "Close", size: 24) { [weak tab] in tab?.closeBar() }
        super.init(tab: tab)
        input.onChange = { [weak tab] in tab?.lineQuery = $0 }
        input.onSubmit = { [weak tab] in tab?.goToLine() }
        input.onEscape = { [weak tab] in tab?.closeBar() }
        setAccessibilityElement(false); setAccessibilityIdentifier("file-go-to-line-bar")
        for view in [input, range, close] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override func update() {
        guard let tab else { return }
        input.text = tab.lineQuery
        range.line.text = tab.lineRange
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let fieldHeight = input.intrinsicContentSize.height
        let items: [StackLayout.Item] = [.view(input, .flexible(max: FileBarField.maximumWidth, height: { _ in fieldHeight })), .line(range), .spacer(0), .fixed(close)]
        StackLayout.place(items, spacing: PiSpacing.sm, in: CGRect(x: PiSpacing.md, y: 0, width: bounds.width - PiSpacing.md * 2, height: 36), scale: piScale)
    }
}

/// The selected line's attribution, under the file's header while blame is
/// shown: what the gutter says, readable and reachable by the keys.
@MainActor final class FileBlameBar: NSView {
    private let blame: FileBlame
    private let icon = PiKit.SymbolView(PiKit.Symbol("person.text.rectangle", size: 11, weight: .medium), color: .piInkTertiary)
    private let spinner = PiKit.spinner(controlSize: .small)
    private let reading = TextBlock("Reading who changed each line…", font: PiKit.Font.caption, color: .piInkSecondary)
    private let unavailable = TextBlock("", font: PiKit.Font.caption, color: .piInkSecondary, maximumLines: 2)
    private let summary = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInkSecondary))
    private let shallow = TextBlock("Earlier history isn't in this clone", font: PiKit.Font.micro, color: .piInkTertiary)
    /// A line with no commit to show: its words, wrapping.
    private let plain = TextBlock("", font: PiKit.Font.caption, color: .piInkSecondary)
    private let showChange = PiKit.Button("Show Change", style: .secondary, compact: true)
    private let copy: PiKit.IconButton
    private let hide: PiKit.IconButton
    private let rule = HairlineView()
    private enum Mode { case off, reading, unavailable, commit(shallow: Bool), plain }
    private var mode = Mode.off

    init(blame: FileBlame) {
        self.blame = blame
        copy = PiKit.IconButton(symbol: "doc.on.doc", label: "Copy Commit ID", size: 24)
        hide = PiKit.IconButton(symbol: "xmark", label: "Hide Blame", size: 24) { [weak blame] in blame?.hide() }
        super.init(frame: .zero)
        hide.setAccessibilityIdentifier("file-blame-hide")
        unavailable.setAccessibilityIdentifier("file-blame-unavailable")
        summary.setAccessibilityIdentifier("file-blame-line")
        showChange.setAccessibilityIdentifier("file-blame-show-change")
        showChange.onPress = { [weak blame] in guard let blame else { return }; blame.openChange(ofLine: blame.line) }
        setAccessibilityElement(false); setAccessibilityIdentifier("file-blame-bar")
        plain.setAccessibilityIdentifier("file-blame-line")
        for view in [icon, spinner, reading, unavailable, summary, shallow, plain, showChange, copy, hide, rule] as [NSView] { addSubview(view) }
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func refresh() {
        for view in [spinner, reading, unavailable, summary, shallow, plain, showChange, copy] as [NSView] { view.isHidden = true }
        switch blame.state {
        case .off: mode = .off
        case .reading:
            mode = .reading; spinner.isHidden = false; reading.isHidden = false
        case .unavailable(let reason):
            mode = .unavailable; unavailable.text = reason; unavailable.isHidden = false
        case .shown:
            if let (entry, commit) = blame.entry(ofLine: blame.line) {
                if let commit {
                    summary.isHidden = false
                    let date = commit.date.formatted(date: .abbreviated, time: .omitted)
                    summary.line.text = "Line \(blame.line + 1) · \(commit.shortHash) · \(commit.author) · \(date) · \(commit.summary)"
                    summary.toolTip = FileBlame.detail(commit)
                    // Read as words, not "dot": the line, the commit and who
                    // made it, and the whole message on request.
                    summary.setAccessibilityLabel("Line \(blame.line + 1), commit \(commit.shortHash), by \(commit.author), \(date): \(commit.summary)")
                    summary.setAccessibilityHelp(FileBlame.spokenDetail(commit))
                    shallow.isHidden = !commit.historyMissing
                    showChange.isHidden = false
                    showChange.isEnabled = blame.canOpen(commit)
                    showChange.toolTip = blame.tab?.projectID == nil ? "Open the file from a project to see its history."
                        : "Open this commit's change to \(entry.path), at line \(entry.line), in Changes."
                    copy.isHidden = false
                    copy.spokenLabel = "Copy commit ID \(commit.shortHash)"
                    copy.onPress = { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commit.hash, forType: .string) }
                    mode = .commit(shallow: commit.historyMissing)
                } else {
                    plain.text = "Line \(blame.line + 1) · Not committed yet"; plain.isHidden = false
                    mode = .plain
                }
            } else {
                plain.text = "Line \(blame.line + 1) · No line here in Git's count"; plain.isHidden = false
                mode = .plain
            }
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        var items: [StackLayout.Item] = [.fixed(icon)]
        switch mode {
        case .off: break
        case .reading: items += [.fixed(spinner), Self.wrapping(reading)]
        case .unavailable: items.append(Self.wrapping(unavailable))
        case .commit(let shallow):
            items.append(.line(summary))
            if shallow { items.append(Self.wrapping(self.shallow)) }
            items += [.fixed(showChange), .fixed(copy)]
        case .plain: items.append(Self.wrapping(plain))
        }
        items += [.spacer(0), .fixed(hide)]
        StackLayout.place(items, spacing: PiSpacing.sm, in: CGRect(x: PiSpacing.md, y: 0, width: bounds.width - PiSpacing.md * 2, height: 36), scale: piScale)
        rule.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }
    /// Text that wraps in what it is offered, as an unlimited `Text` does.
    private static func wrapping(_ block: TextBlock) -> StackLayout.Item { .view(block, .wrapping(block, ideal: { block.idealWidth })) }
}

/// What a file tab shows in place of text: a file that is missing, or not text.
@MainActor final class FileTabNotice: NSView {
    private let notice: NoticeView
    private let url: URL
    private let open: PiKit.Button
    init(symbol: String, title: String, url: URL) {
        self.url = url
        open = PiKit.Button("Open in \(FileTabHeader.appName(for: url))", style: .secondary)
        notice = NoticeView(symbol: PiKit.Symbol(symbol, size: 30, weight: .light), title: title, detail: "", button: open)
        super.init(frame: .zero)
        open.onPress = { [url] in NSWorkspace.shared.open(url) }
        addSubview(notice)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func set(detail: String) {
        notice.set(detail: detail)
        open.isHidden = !FileManager.default.fileExists(atPath: url.path)
        needsLayout = true
    }
    override func layout() { super.layout(); notice.frame = bounds }
    /// A binary file: its size and its type.
    static func describe(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .localizedTypeDescriptionKey])
        let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return [values?.localizedTypeDescription, size].compactMap { $0 }.joined(separator: " · ")
    }
}

/// An image or PDF, shown natively: the image fitted inside 16 points, the
/// PDF in its kept view.
@MainActor final class FilePreviewView: NSView {
    let preview: FilePreview
    private let error = TextBlock("", font: PiKit.Font.body, color: .piInkSecondary)
    private let imageView = NSImageView()
    private let spinner: PiSpinnerView
    private var observation: AnyCancellable?
    private var loadedOnce = false
    init(preview: FilePreview) {
        self.preview = preview
        spinner = piSpinner(size: 18)
        super.init(frame: .zero)
        wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        for view in [error, imageView, spinner] as [NSView] { addSubview(view) }
        observation = preview.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piContent) }
    /// Shown: the file is read (`onAppear`); hidden and shown again, read again.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !isHiddenOrHasHiddenAncestor { preview.load() }
    }
    override func viewDidUnhide() { super.viewDidUnhide(); if window != nil { preview.load() } }
    func refresh() {
        error.isHidden = preview.error == nil
        error.text = preview.error ?? ""
        let pdf = preview.error == nil ? preview.pdf : nil
        if let pdf {
            let view = preview.pdfView
            if view.document !== pdf { view.document = pdf }
            if view.superview !== self { view.removeFromSuperview(); addSubview(view) }
            view.isHidden = false
        } else if preview.hasPDFView {
            preview.pdfView.isHidden = true
        }
        let image = preview.error == nil && pdf == nil ? preview.image : nil
        imageView.image = image; imageView.isHidden = image == nil
        imageView.setAccessibilityLabel(image == nil ? nil : preview.url.lastPathComponent)
        spinner.isHidden = !(preview.error == nil && pdf == nil && image == nil)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let scale = piScale
        let errorWidth = min(error.idealWidth, max(0, bounds.width - 32)), errorHeight = error.height(forWidth: errorWidth)
        error.frame = CGRect(x: PiKit.round((bounds.width - errorWidth) / 2, scale), y: PiKit.round((bounds.height - errorHeight) / 2, scale), width: errorWidth, height: errorHeight)
        imageView.frame = bounds.insetBy(dx: PiSpacing.lg, dy: PiSpacing.lg)
        if preview.hasPDFView, preview.pdfView.superview === self { preview.pdfView.frame = bounds }
        spinner.frame = CGRect(x: PiKit.round((bounds.width - 18) / 2, scale), y: PiKit.round((bounds.height - 18) / 2, scale), width: 18, height: 18)
    }
}
