import AppKit
import GitView

// Drawing a diff: its heading, and the unified or side-by-side cards the
// hunks become (`GitDiffTable`). A commit's file chips are `GitFileChipsView`.

/// Unified or side-by-side diff rendered as file cards with hunk headers,
/// old/new line numbers and tinted added/removed rows. The heading scrolls
/// away with the cards in the table's first row; the cards are a native
/// table (`GitDiffTable`).
@MainActor final class DiffView: NSView {
    let table = GitDiffTable()
    private let heading = DiffHeading()
    private let more = DiffMore()
    /// Wrapped lines: the view's own, kept while it is (`@State`).
    private(set) var wrap = false
    private var shown: Shown?
    /// What the view was last asked to show, to show again when the wrap changes.
    private struct Shown {
        var files: [GitDiffFile], title: String?, subtitle: String?, identity: String, loading: Bool, embedded: Bool
        var lead: (NSView & PiKit.WidthSizing)?, leadKey: AnyHashable, split: Bool, expanded: String?
        var setSplit: (Bool) -> Void, setExpanded: (String?) -> Void
        var openFile: ((String, Int) -> Void)?, reveal: GitDiffReveal?, revealed: ((GitDiffReveal, GitDiffRevealOutcome) -> Void)?
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(table)
        heading.wrapChanged = { [weak self] in self?.setWrap($0) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piContent) }
    override func layout() { super.layout(); table.frame = bounds }

    private static let rowLimit = GitDiffMetrics.rowLimit

    /// Shows a diff. `identity` names it: the file selected, or the commit
    /// and the file chosen inside it; the "whole diff" gate is remembered
    /// against it (`expanded`). `lead` scrolls above the heading (a commit's
    /// own header); `leadKey` changes whenever its height may.
    func show(files: [GitDiffFile], title: String?, subtitle: String?, identity: String, loading: Bool = false, embedded: Bool = false,
              lead: (NSView & PiKit.WidthSizing)? = nil, leadKey: AnyHashable = 0, split: Bool, setSplit: @escaping (Bool) -> Void,
              expanded: String?, setExpanded: @escaping (String?) -> Void, openFile: ((String, Int) -> Void)? = nil,
              reveal: GitDiffReveal? = nil, revealed: ((GitDiffReveal, GitDiffRevealOutcome) -> Void)? = nil) {
        shown = Shown(files: files, title: title, subtitle: subtitle, identity: identity, loading: loading, embedded: embedded, lead: lead,
                      leadKey: leadKey, split: split, expanded: expanded, setSplit: setSplit, setExpanded: setExpanded,
                      openFile: openFile, reveal: reveal, revealed: revealed)
        apply()
    }

    private func setWrap(_ value: Bool) {
        guard wrap != value else { return }
        wrap = value
        apply()
    }

    private func apply() {
        guard let shown else { return }
        let showAll = shown.expanded == shown.identity
        heading.update(title: shown.title, subtitle: shown.subtitle, loading: shown.loading, empty: shown.files.isEmpty,
                       embedded: shown.embedded, lead: shown.lead, split: shown.split, wrap: wrap, setSplit: shown.setSplit)
        // Counted from what the parser already totalled, not by walking the lines again.
        let totalRows = shown.files.reduce(0) { $0 + $1.lineCount }
        let hasMore = totalRows > Self.rowLimit && !showAll
        let identity = shown.identity, setExpanded = shown.setExpanded
        more.press = { setExpanded(identity) }
        table.update(files: shown.files, split: shown.split, wrap: wrap, showAll: showAll, identity: shown.identity, top: heading,
                     topHeightKey: TopHeightKey(title: shown.title != nil, subtitle: shown.subtitle != nil, note: shown.files.isEmpty && !shown.loading,
                                                embedded: shown.embedded, lead: shown.leadKey),
                     loading: shown.loading, more: hasMore ? more : nil, colors: .pi, menu: GitDiffPiMenu.builder(openFile: shown.openFile),
                     reveal: shown.reveal, revealed: shown.revealed)
    }

    /// What the heading's height depends on: its title and subtitle are one
    /// line each whatever they say, and the spinner is shorter than the tabs.
    private struct TopHeightKey: Hashable {
        let title: Bool, subtitle: Bool, note: Bool, embedded: Bool, lead: AnyHashable
    }
}

/// The lead, the heading and "No textual changes.", 12 points apart: the
/// table's first row.
@MainActor final class DiffHeading: NSView, GitDiffAccessory {
    private var lead: (NSView & PiKit.WidthSizing)?
    private let title = SelectableLine("", font: PiKit.Font.heading, color: .piInk, truncation: .byTruncatingMiddle)
    private let subtitle = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.micro, color: .piInkTertiary))
    private let spinner = PiKit.spinner(controlSize: .small)
    private let layoutTabs = PiKit.Tabs(selection: false, items: [(false, "Unified"), (true, "Split")])
    private let wrapSwitch = PiKit.Switch(isOn: false, label: "Wrap", size: .mini)
    private let note = PiKit.TextLine(PiKit.Line("No textual changes.", font: PiKit.Font.caption, color: .piInkSecondary))
    private var hasTitle = false, hasSubtitle = false, loading = false, showsNote = false, embedded = false
    var wrapChanged: ((Bool) -> Void)?
    private var setSplit: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        layoutTabs.setAccessibilityIdentifier("git-diff-layout")
        layoutTabs.onSelect = { [weak self] in self?.setSplit?($0) }
        wrapSwitch.labelFont = PiKit.Font.micro
        wrapSwitch.onChange = { [weak self] in self?.wrapChanged?($0) }
        for view in [title, subtitle, spinner, layoutTabs, wrapSwitch, note] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func update(title: String?, subtitle: String?, loading: Bool, empty: Bool, embedded: Bool, lead: (NSView & PiKit.WidthSizing)?,
                split: Bool, wrap: Bool, setSplit: @escaping (Bool) -> Void) {
        self.setSplit = setSplit
        if lead !== self.lead || lead?.superview !== self {
            if self.lead !== lead { self.lead?.removeFromSuperview() }
            self.lead = lead
            if let lead { addSubview(lead) }
        }
        hasTitle = title != nil; hasSubtitle = subtitle != nil
        self.title.text = title ?? ""; self.title.isHidden = title == nil
        self.subtitle.line.text = subtitle ?? ""; self.subtitle.isHidden = subtitle == nil
        self.loading = loading; spinner.isHidden = !loading
        showsNote = empty && !loading; note.isHidden = !showsNote
        self.embedded = embedded
        layoutTabs.selection = split
        wrapSwitch.isOn = wrap
        needsLayout = true
    }

    // MARK: Layout

    private var titleBlockHeight: CGFloat {
        (hasTitle ? title.textSize.height : 0) + (hasTitle && hasSubtitle ? 2 : 0) + (hasSubtitle ? subtitle.intrinsicContentSize.height : 0)
    }
    /// The heading's row: the title and subtitle, the spinner, the layout
    /// tabs and Wrap, on the title's baseline.
    private func headItems() -> [StackLayout.Item] {
        let scale = piScale
        let titleSize = title.textSize, subtitleSize = subtitle.intrinsicContentSize
        let blockWidth: @MainActor (CGFloat) -> CGFloat = { proposal in
            min(max(self.hasTitle ? titleSize.width : 0, self.hasSubtitle ? subtitleSize.width : 0), max(0, proposal))
        }
        let titleBaseline = hasTitle ? PiKit.Line("", font: PiKit.Font.heading, color: .black).baseline(scale: scale)
            : PiKit.Line("", font: PiKit.Font.micro, color: .black).baseline(scale: scale)
        var block = StackLayout.Sizing(width: blockWidth, height: { _ in self.titleBlockHeight })
        block.baseline = { (_: CGFloat) in titleBaseline }
        var items: [StackLayout.Item] = [StackLayout.Item(view: nil, sizing: block), .spacer()]
        if loading { items.append(.fixed(spinner)) }
        var tabs = StackLayout.Sizing.intrinsic(layoutTabs)
        tabs.baseline = { _ in PiKit.Tabs<Bool>.inset + 5 + PiKit.Line("", font: .systemFont(ofSize: 12, weight: .medium), color: .black).baseline(scale: scale) }
        items.append(.view(layoutTabs, tabs))
        var toggle = StackLayout.Sizing.intrinsic(wrapSwitch)
        toggle.baseline = { _ in
            let height = self.wrapSwitch.intrinsicContentSize.height, text = PiKit.Line("Wrap", font: PiKit.Font.micro, color: .black)
            return PiKit.round((height - text.lineHeight) / 2, scale) + text.baseline(scale: scale)
        }
        items.append(.view(wrapSwitch, toggle))
        return items
    }
    private var headInset: CGFloat { embedded ? 0 : PiSpacing.lg }

    func gitDiffHeight(forWidth width: CGFloat) -> CGFloat {
        var height: CGFloat = 0
        if let lead { height += lead.height(forWidth: width) + PiSpacing.md }
        height += headInset + StackLayout.baselineHeight(headItems(), spacing: StackLayout.system, width: width - PiSpacing.lg * 2)
        if showsNote { height += PiSpacing.md + note.intrinsicContentSize.height }
        return height
    }

    override func layout() {
        super.layout()
        let scale = piScale, width = bounds.width
        var y: CGFloat = 0
        if let lead {
            let height = lead.height(forWidth: width)
            lead.frame = CGRect(x: 0, y: 0, width: width, height: height)
            y = height + PiSpacing.md
        }
        y += headInset
        let items = headItems()
        let rowHeight = StackLayout.baselineHeight(items, spacing: StackLayout.system, width: width - PiSpacing.lg * 2)
        let row = CGRect(x: PiSpacing.lg, y: y, width: width - PiSpacing.lg * 2, height: rowHeight)
        StackLayout.placeOnBaseline(items, spacing: StackLayout.system, in: row, scale: scale)
        // The block's own frame: its title over its subtitle, 2 apart.
        let titleSize = title.textSize
        let blockOrigin = blockFrame(items: items, in: row, scale: scale)
        if hasTitle { title.place(CGRect(x: blockOrigin.minX, y: blockOrigin.minY, width: min(titleSize.width, blockOrigin.width), height: titleSize.height)) }
        if hasSubtitle {
            let size = subtitle.intrinsicContentSize
            subtitle.frame = CGRect(x: blockOrigin.minX, y: blockOrigin.minY + (hasTitle ? titleSize.height + 2 : 0), width: min(size.width, blockOrigin.width), height: size.height)
        }
        y += rowHeight
        if showsNote {
            let size = note.intrinsicContentSize
            note.frame = CGRect(x: PiSpacing.lg, y: y + PiSpacing.md, width: min(size.width, width - PiSpacing.lg * 2), height: size.height)
        }
    }
    /// Where the title block went in the row (its item has no view of its own).
    private func blockFrame(items: [StackLayout.Item], in row: CGRect, scale: CGFloat) -> CGRect {
        let widths = StackLayout.widths(items, spacing: StackLayout.system, proposal: row.width)
        let baselines = items.map { $0.sizing.baseline?(0) ?? 0 }
        let above = zip(items, zip(widths, baselines)).map { item, pair in item.sizing.baseline?(pair.0) ?? item.sizing.height(pair.0) }.max() ?? 0
        return CGRect(x: row.minX, y: PiKit.round(row.minY + above - baselines[0], scale), width: widths[0], height: titleBlockHeight)
    }
}

/// "Show the whole diff", after the cards.
@MainActor final class DiffMore: NSView, GitDiffAccessory {
    let button = PiKit.Button("Show the whole diff", style: .secondary, compact: true)
    var press: (() -> Void)?
    init() {
        super.init(frame: .zero)
        button.setAccessibilityIdentifier("git-diff-show-all")
        button.onPress = { [weak self] in self?.press?() }
        addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func gitDiffHeight(forWidth width: CGFloat) -> CGFloat { button.intrinsicContentSize.height }
    override func layout() {
        super.layout()
        let size = button.intrinsicContentSize
        button.frame = CGRect(x: PiSpacing.lg, y: 0, width: min(size.width, max(0, bounds.width - PiSpacing.lg * 2)), height: size.height)
    }
}
