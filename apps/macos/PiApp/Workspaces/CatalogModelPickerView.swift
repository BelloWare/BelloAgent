import AppKit
import Combine

/// A live native catalog view. Unlike a tracking NSMenu snapshot, its contents
/// update while a fetch is in flight. Opening it always checks the source's TTL,
/// whether invoked with the pointer or keyboard. Search includes every model,
/// not just a first menu page.
@MainActor final class CatalogModelPickerView: NSView, PiKit.WidthSizing, PiKit.SizeObserver {
    /// A connection as the Settings sheet edits it: listed on its own, with the key typed there.
    struct DraftListing: Equatable { var profile: ProfileRecord; var key: String }
    static let width: CGFloat = 390
    static let rowsHeight: CGFloat = 340

    let model: WorkspaceModel
    private(set) var profile: ProfileRecord
    private(set) var current: String?
    private(set) var draft: DraftListing?
    private(set) var allowsCatalogSelection: Bool
    private(set) var defaultTitle: String?
    private(set) var defaultSelected: Bool
    private(set) var useDefault: (() -> Void)?
    /// Called with an alias typed into the picker; empty means the connection default.
    private(set) var manualEntry: ((String) -> Void)?
    private(set) var choose: (ModelDescriptor) -> Void
    /// Its height changed (a popover follows it).
    var sizeChanged: (() -> Void)?
    /// The enabled state of what hosts it (`.disabled` on the SwiftUI around it).
    var inheritedEnabled = true { didSet { if oldValue != inheritedEnabled { shown = nil; refresh() } } }

    private let refreshState = ModelCatalogRefreshState()
    private var observer: ShellObserver!
    private var query = ""
    private var enteringAlias = false
    private var loadKey: [String]?
    private var loadTask: Task<Void, Never>?
    private var shownSource: String?
    private var shownProfile: String?
    /// What the picker shows: unchanged, a model notification changes nothing.
    private var shown: Shown?
    private struct Shown: Equatable {
        var sourceID: String, sourceName: String, sourceLabel: String, configured: Bool, loading: Bool, enabled: Bool
        var repairs: [String]?, sourceChoices: [String]?, defaultTitle: String?, defaultSelected: Bool, error: String?
        var offeredCount: Int, matches: [ModelDescriptor], chosen: String?, notListed: String?, updated: Date?
        var manual: Bool, enteringAlias: Bool
    }
    private var sourceList: PiKit.ChoiceList<String>?
    /// The open source chooser (a test seam).
    var sourceChooser: NSPopover? { sourcePopover?.isShown == true ? sourcePopover : nil }

    // The parts, made once and updated in place.
    private let column = ShellStack(.vertical, spacing: 12, alignment: .leading, padding: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
    private let heading = PiKit.TextLine()
    private let sourceName = PiKit.TextLine()
    private let sourceLabelLine = ShellText("", font: PiKit.Font.caption, color: .piInkTertiary, maximumLines: 2)
    private let spinner = PiKit.spinner(controlSize: .small)
    let refreshButton = CatalogRefreshButton()
    private let header: ShellStack
    private let repair = CatalogRepairNotice()
    let sourceSelector = CatalogSourceButton()
    let search = PiKit.TextField(placeholder: "Search model names or aliases", icon: "magnifyingglass")
    private let defaultRow = CatalogDefaultRow()
    private let errorHeading = ShellText("Refresh failed · showing the last list", font: .systemFont(ofSize: PiKit.Font.captionSize, weight: .medium), color: .piWarning)
    private let errorText = ShellText("", font: PiKit.Font.caption, color: .piWarning)
    private lazy var errorStack = ShellStack(.vertical, spacing: 3, alignment: .leading, [.view(errorHeading, .fill), .view(errorText, .fill)])
    private let emptyText = PiKit.TextLine()
    private let emptyHolder = CatalogCentredLine()
    private let rowsScroll = NSScrollView()
    private let rowsHolder = CatalogRowsHolder()
    private let rowsDocument = FlippedDocument()
    /// The rows on screen, made as they scroll into view (`LazyVStack`), and
    /// the ones put by to reuse.
    private var rowViews: [String: CatalogModelRow] = [:]
    private var spareRows: [CatalogModelRow] = []
    private var rowItems: [ModelDescriptor] = []
    private var rowTops: [CGFloat] = []
    private var rowHeights: [CGFloat] = []
    private var rowsWidth: CGFloat = -1
    /// Each model's measured height at a width, kept while it is unchanged.
    private var heightCache: [String: (item: ModelDescriptor, chosen: Bool, width: CGFloat, height: CGFloat)] = [:]
    private let measuringRow = CatalogModelRow()
    private static let rowSpacing: CGFloat = 2
    private let notListed = ShellText("", font: PiKit.Font.caption, color: .piInkSecondary)
    private let countLine = PiKit.TextLine()
    private let updatedLine = PiKit.TextLine()
    let aliasToggle = CatalogLinkButton(title: "Enter alias…")
    private let footerRow: ShellStack
    let aliasField: PiKit.TextField
    let useAlias = PiKit.Button("Use", style: .primary, compact: true)
    private let aliasRow: ShellStack
    private let includedNote = ShellText("Included models change with app updates. Choose a saved custom catalog above or set its URL in Settings.",
                                         font: PiKit.Font.caption, color: .piInkTertiary)
    private var sourcePopover: NSPopover?

    init(model: WorkspaceModel, profile: ProfileRecord, current: String?, draft: DraftListing? = nil, allowsCatalogSelection: Bool = false,
         defaultTitle: String? = nil, defaultSelected: Bool = false,
         useDefault: (() -> Void)? = nil, manualEntry: ((String) -> Void)? = nil, choose: @escaping (ModelDescriptor) -> Void) {
        self.model = model; self.profile = profile; self.current = current; self.draft = draft
        self.allowsCatalogSelection = allowsCatalogSelection; self.defaultTitle = defaultTitle; self.defaultSelected = defaultSelected
        self.useDefault = useDefault; self.manualEntry = manualEntry; self.choose = choose
        let titles = ShellStack(.vertical, spacing: 3, alignment: .leading, [.view(heading), .view(sourceName, .flexible), .view(sourceLabelLine, .fill)])
        // The titles take all but the button and one gap (measured against the SwiftUI header).
        header = ShellStack(.horizontal, spacing: 0, [.view(titles, .flexible), .spacer(8),
                                                      .view(spinner, insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)), .view(refreshButton)])
        footerRow = ShellStack(.horizontal, spacing: 8, alignment: .firstBaseline, [.view(countLine), .view(updatedLine), .spacer(8), .view(aliasToggle)])
        aliasField = PiKit.TextField(placeholder: profile.modelId, icon: "cpu", mono: true)
        aliasRow = ShellStack(.horizontal, spacing: 6, [.view(aliasField, .fill), .view(useAlias)])
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        wantsLayer = true
        addSubview(column)
        rowsScroll.drawsBackground = false; rowsScroll.automaticallyAdjustsContentInsets = false
        rowsScroll.hasVerticalScroller = true; rowsScroll.autohidesScrollers = true; rowsScroll.borderType = .noBorder
        rowsScroll.documentView = rowsDocument
        rowsHolder.addSubview(rowsScroll)
        rowsHolder.didLayout = { [weak self] in self?.layoutRows() }
        rowsScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(rowsScrolled), name: NSView.boundsDidChangeNotification, object: rowsScroll.contentView)
        sourceLabelLine.setAccessibilityIdentifier("model-picker-source")
        search.field.setAccessibilityIdentifier("model-catalog-search")
        search.onChange = { [weak self] text in guard let self, self.query != text else { return }; self.query = text; self.refresh() }
        refreshButton.onPress = { [weak self] in self?.refreshCatalog() }
        sourceSelector.toolTip = "Choose the model list for chats using this connection. The request connection, credentials and selected model stay the same."
        sourceSelector.setAccessibilityIdentifier("select-model-catalog-source")
        sourceSelector.onPress = { [weak self] in self?.showSources() }
        repair.choose = { [weak self] id in self?.selectSource(id) }
        defaultRow.onPress = { [weak self] in self?.useDefault?() }
        updatedLine.setAccessibilityIdentifier("model-catalog-refreshed-at")
        aliasToggle.setAccessibilityIdentifier("model-enter-alias")
        aliasToggle.onPress = { [weak self] in guard let self else { return }; self.enteringAlias.toggle(); self.refresh(); if self.enteringAlias, self.window != nil { PiKit.arrive(self.aliasRow) } }
        aliasField.field.setAccessibilityIdentifier("model-alias-field")
        aliasField.field.cell?.sendsActionOnEndEditing = false
        aliasField.onSubmit = { [weak self] in self?.submitAlias() }
        useAlias.onPress = { [weak self] in self?.submitAlias() }
        emptyHolder.line = emptyText
        observer = ShellObserver { [weak self] in self?.refresh() }
        observer.observe(model)
        observer.observe(model.modelCatalog)
        observer.observe(refreshState)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    deinit { loadTask?.cancel() }

    /// New inputs from what hosts it; the search, the alias field and the
    /// scroll position stay.
    func update(profile: ProfileRecord, current: String?, draft: DraftListing?, allowsCatalogSelection: Bool, defaultTitle: String?,
                defaultSelected: Bool, useDefault: (() -> Void)?, manualEntry: ((String) -> Void)?, choose: @escaping (ModelDescriptor) -> Void) {
        self.profile = profile; self.current = current; self.draft = draft; self.allowsCatalogSelection = allowsCatalogSelection
        self.defaultTitle = defaultTitle; self.defaultSelected = defaultSelected
        self.useDefault = useDefault; self.manualEntry = manualEntry; self.choose = choose
        if aliasField.field.placeholderString != profile.modelId { aliasField.field.placeholderString = profile.modelId }
        // What changed shows through the snapshot; the actions are read when used.
        refresh()
    }
    override var isFlipped: Bool { true }
    func contentSizeChanged() { needsLayout = true; sizeChanged?() }

    // MARK: State

    /// The profile it lists for: a popover can outlive a Settings or vault
    /// reload, so only its own saved ID is resolved again; a draft is as given.
    private var liveProfile: ProfileRecord { draft == nil ? (model.profiles.first { $0.id == profile.id } ?? profile) : profile }
    private var source: ProfileRecord { draft == nil ? model.catalogProfile(for: liveProfile) : profile }

    func refresh() {
        let profile = liveProfile, source = self.source
        // A list for another source starts its search over, and is read for it.
        // `.onChange(of: profile.id)` and `.onChange(of: source.id)`.
        if shownSource != nil, shownSource != source.id || shownProfile != profile.id, !query.isEmpty { query = ""; search.text = "" }
        shownSource = source.id; shownProfile = profile.id
        load(source: source, profile: profile)
        let entry = model.modelCatalog.entry(for: source)
        let offered = entry.offered(current: current)
        let matches = Self.filtered(offered, query: query)
        let loading = refreshState.loading || entry.loading
        let enabled = inheritedEnabled
        let selecting = allowsCatalogSelection && model.profiles.filter({ $0.api == LiteLLMConfiguration.supportedAPI }).count > 1
        let repairs = selecting ? model.catalogRepairChoices(for: profile) : []
        let choices = selecting ? sourceChoices(profile) : []
        let notListed = current.flatMap { current in
            !current.isEmpty && !offered.contains(where: { $0.id == current }) && entry.fetchedAt != nil ? current : nil
        }
        let next = Shown(sourceID: source.id, sourceName: source.name, sourceLabel: Self.sourceLabel(source), configured: ModelCatalog.catalogConfigured(source),
                         loading: loading, enabled: enabled,
                         repairs: selecting ? repairs.map { $0.id + "|" + $0.name + "|" + Self.sourceLabel($0) } : nil,
                         sourceChoices: selecting ? choices.map { $0.id + "|" + $0.title + "|" + ($0.subtitle ?? "") } + [source.id] : nil,
                         defaultTitle: useDefault != nil ? defaultTitle : nil, defaultSelected: defaultSelected,
                         error: refreshState.error ?? entry.error, offeredCount: offered.count, matches: matches,
                         chosen: defaultSelected ? nil : current, notListed: notListed,
                         updated: !loading && entry.error == nil ? entry.fetchedAt : nil,
                         manual: manualEntry != nil, enteringAlias: enteringAlias)
        guard next != shown else { return }
        let previous = shown
        shown = next

        heading.line = PiKit.Line(next.configured ? "Model catalog" : "Bello model catalog", font: .systemFont(ofSize: 13, weight: .bold), color: .piInk)
        sourceName.line = PiKit.Line(source.name, font: PiKit.Font.caption, color: .piInkSecondary)
        sourceLabelLine.set(next.sourceLabel, color: .piInkTertiary)
        spinner.isHidden = !loading
        refreshButton.isEnabled = !loading && enabled
        var items: [ShellItem] = [.view(header, .fill)]
        if selecting {
            if !repairs.isEmpty {
                repair.update(choices: repairs, loading: loading || !enabled)
                items.append(.view(repair, .fill))
            }
            sourceSelector.isEnabled = !loading && enabled
            items.append(.view(sourceSelector, .fill))
            if let sourceList, let sourcePopover, sourcePopover.isShown {
                // An open chooser follows, disabled with the picker, at its new size.
                let usable = !loading && enabled
                sourceList.update(selection: source.id, choices: choices.map { var choice = $0; choice.enabled = choice.enabled && usable; return choice })
                // The size the list gave itself, read before the popover lays
                // its root out again at the size it has now.
                let size = sourceList.frame.size
                sourcePopover.contentViewController?.preferredContentSize = size
                if sourcePopover.contentSize != size { sourcePopover.contentSize = size }
            }
        } else if sourcePopover != nil { sourcePopover?.close() }
        search.field.isEnabled = enabled
        items.append(.view(search, .fill))
        if let defaultTitle = next.defaultTitle {
            defaultRow.update(title: defaultTitle, selected: defaultSelected)
            defaultRow.isEnabled = enabled
            items.append(.view(defaultRow, .fill))
        }
        if let error = next.error {
            errorHeading.isHidden = offered.isEmpty
            errorText.set(error, color: .piWarning)
            errorStack.relayoutAll()
            items.append(.view(errorStack, .fill))
        }
        if matches.isEmpty {
            emptyText.line = PiKit.Line(loading ? "Loading models…" : offered.isEmpty ? "No models are listed by this connection." : "No matching models.",
                                       font: PiKit.Font.body, color: .piInkSecondary)
            items.append(.view(emptyHolder, .fill))
            setRows([])
        } else {
            if previous?.matches != matches || previous?.chosen != next.chosen || previous?.enabled != enabled { setRows(matches) }
            rowsHolder.height = min(Self.rowsHeight, CGFloat(matches.count) * 68)
            items.append(.view(rowsHolder, .fill))
        }
        if let notListed {
            self.notListed.set("Current selection “\(notListed)” is not listed by this source. It remains selected until you choose another model.", color: .piInkSecondary)
            items.append(.view(self.notListed, .fill))
        }
        countLine.line = PiKit.Line("\(offered.count) models", font: PiKit.Font.caption, color: .piInkTertiary)
        if let date = next.updated {
            updatedLine.isHidden = false
            updatedLine.line = PiKit.Line("Updated \(date.formatted(date: .omitted, time: .standard))", font: PiKit.Font.caption, color: .piInkTertiary)
        } else { updatedLine.isHidden = true }
        aliasToggle.isHidden = manualEntry == nil
        aliasToggle.isEnabled = enabled
        aliasToggle.title = enteringAlias ? "Hide alias field" : "Enter alias…"
        items.append(.view(footerRow, .fill))
        if manualEntry != nil, enteringAlias {
            aliasField.field.isEnabled = enabled; useAlias.isEnabled = enabled
            items.append(.view(aliasRow, .fill))
        }
        if !next.configured { items.append(.view(includedNote, .fill)) }
        column.items = items
        header.relayoutAll(); footerRow.relayoutAll(); column.relayoutAll()
        needsLayout = true
        sizeChanged?()
    }

    /// Reads the source's list when it changes (`.task(id:)`), as the open picker asks.
    private func load(source: ProfileRecord, profile: ProfileRecord) {
        let key = [source.id, source.baseUrl, source.catalogUrl ?? "", draft?.key ?? ""]
        guard key != loadKey else { return }
        loadKey = key
        loadTask?.cancel()
        let model = self.model, draft = self.draft
        loadTask = Task {
            if let draft { _ = await model.listModels(forDraft: draft.profile, typedKey: draft.key) } else { _ = await model.listModels(for: profile) }
        }
    }

    /// The list's models; their rows are made in `placeRows` as they show.
    private func setRows(_ matches: [ModelDescriptor]) {
        rowItems = matches
        rowsWidth = -1
        let ids = Set(matches.map(\.id))
        for (id, row) in rowViews where !ids.contains(id) { putAway(row); rowViews[id] = nil }
        if heightCache.count > max(256, matches.count * 2) { heightCache = heightCache.filter { ids.contains($0.key) } }
        rowsHolder.needsLayout = true
    }
    private func chosen(_ item: ModelDescriptor) -> Bool { !defaultSelected && current == item.id }
    private func rowHeight(_ item: ModelDescriptor, width: CGFloat) -> CGFloat {
        let chosen = chosen(item)
        if let cached = heightCache[item.id], cached.item == item, cached.chosen == chosen, cached.width == width { return cached.height }
        measuringRow.update(item, chosen: chosen)
        let height = measuringRow.height(forWidth: width)
        heightCache[item.id] = (item, chosen, width, height)
        return height
    }
    /// Heights and places at `width`; the document's height.
    private func measureRows(width: CGFloat) -> CGFloat {
        guard width != rowsWidth else { return rowTops.last.map { $0 + (rowHeights.last ?? 0) } ?? 0 }
        rowsWidth = width
        rowHeights = rowItems.map { rowHeight($0, width: width) }
        rowTops = []; rowTops.reserveCapacity(rowHeights.count)
        var y: CGFloat = 0
        for (index, height) in rowHeights.enumerated() { rowTops.append(y); y += height + (index < rowHeights.count - 1 ? Self.rowSpacing : 0) }
        return y
    }
    @objc private func rowsScrolled() { placeRows() }
    /// The rows in view and a screen's worth either side; the others are put by.
    private func placeRows() {
        let visible = rowsScroll.contentView.bounds.insetBy(dx: 0, dy: -rowsScroll.contentView.bounds.height)
        var keep = Set<String>()
        // The first row whose bottom reaches the visible band.
        var low = 0, high = rowTops.count
        while low < high {
            let middle = (low + high) / 2
            if rowTops[middle] + rowHeights[middle] < visible.minY { low = middle + 1 } else { high = middle }
        }
        var index = low
        while index < rowItems.count, index < rowTops.count, rowTops[index] < visible.maxY {
            let item = rowItems[index]
            let frame = CGRect(x: 0, y: rowTops[index], width: rowsWidth, height: rowHeights[index])
            keep.insert(item.id)
            let row = rowViews[item.id] ?? takeRow()
            rowViews[item.id] = row
            row.update(item, chosen: chosen(item))
            row.onPress = { [weak self] in self?.choose(item) }
            if row.isEnabled != inheritedEnabled { row.isEnabled = inheritedEnabled }
            if row.superview !== rowsDocument { rowsDocument.addSubview(row) }
            row.isHidden = false
            if row.frame != frame { row.frame = frame }
            index += 1
        }
        for (id, row) in rowViews where !keep.contains(id) { putAway(row); rowViews[id] = nil }
        // VoiceOver reads the rows in the list's order, not the order they were made in.
        let ordered = rowsDocument.subviews.sorted { ($0.isHidden ? 1 : 0, $0.frame.minY) < ($1.isHidden ? 1 : 0, $1.frame.minY) }
        if ordered != rowsDocument.subviews { rowsDocument.subviews = ordered }
    }
    private func takeRow() -> CatalogModelRow { spareRows.popLast() ?? CatalogModelRow() }
    private func putAway(_ row: CatalogModelRow) { row.isHidden = true; row.onPress = nil; spareRows.append(row) }

    // MARK: Actions

    private func refreshCatalog() {
        let model = self.model, draft = self.draft, profileID = liveProfile.id, state = refreshState
        Task {
            if let draft { _ = await model.listModels(forDraft: draft.profile, typedKey: draft.key, force: true) }
            else { await state.refresh(model: model, profileID: profileID) }
        }
    }
    private func selectSource(_ id: String) {
        guard inheritedEnabled, !refreshState.loading else { return }
        let model = self.model, profileID = liveProfile.id, state = refreshState
        Task { await state.selectSource(model: model, sourceID: id, profileID: profileID) }
    }
    private func sourceChoices(_ profile: ProfileRecord) -> [PiKit.Choice<String>] {
        [PiKit.Choice(id: profile.id, title: "Saved with this connection", subtitle: Self.sourceLabel(profile))] +
            model.profiles.filter { $0.id != profile.id && $0.api == LiteLLMConfiguration.supportedAPI && model.catalogProfile(for: $0).id == $0.id }
                .map { PiKit.Choice(id: $0.id, title: $0.name, subtitle: Self.sourceLabel($0)) }
    }
    /// The source chooser, kept up to date while it is open.
    private func showSources() {
        if let sourcePopover, sourcePopover.isShown { sourcePopover.close(); return }
        let list = PiKit.ChoiceList(title: "Catalog source", selection: source.id, choices: sourceChoices(liveProfile),
                                    choose: { [weak self] id in self?.sourcePopover?.close(); self?.selectSource(id) },
                                    cancel: { [weak self] in self?.sourcePopover?.close() })
        let popover = PiKit.popover(list)
        sourcePopover = popover; sourceList = list
        popover.show(relativeTo: sourceSelector.bounds, of: sourceSelector, preferredEdge: .minY)
    }
    private func submitAlias() {
        manualEntry?(aliasField.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Layout

    func height(forWidth width: CGFloat) -> CGFloat { column.height(forWidth: Self.width) }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: height(forWidth: Self.width)) }
    override var fittingSize: NSSize { intrinsicContentSize }
    override func layout() {
        super.layout()
        column.frame = CGRect(x: 0, y: 0, width: Self.width, height: height(forWidth: Self.width))
        column.layoutSubtreeIfNeeded()
        layoutRows()
    }
    /// The rows fill the clip view's width, which narrows when a legacy
    /// scroller appears once the rows outgrow the box: lay out, retile, and
    /// lay out again at the narrower width.
    private func layoutRows() {
        for _ in 0..<2 {
            rowsScroll.tile()
            let width = rowsScroll.contentSize.width > 0 ? rowsScroll.contentSize.width : rowsScroll.bounds.width
            let size = CGSize(width: width, height: measureRows(width: width))
            if rowsDocument.frame.size != size { rowsDocument.frame = CGRect(origin: .zero, size: size) }
            rowsScroll.tile()
            if rowsScroll.contentSize.width == width || rowsScroll.contentSize.width <= 0 { break }
        }
        placeRows()
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piSurface) }

    // MARK: Words

    static func filtered(_ models: [ModelDescriptor], query: String) -> [ModelDescriptor] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return models }
        return models.filter {
            $0.id.localizedCaseInsensitiveContains(query) || $0.displayName.localizedCaseInsensitiveContains(query) ||
            $0.description.localizedCaseInsensitiveContains(query)
        }
    }
    /// Deliberately omit query values: catalog URLs may contain access tokens.
    static func sourceLabel(_ profile: ProfileRecord) -> String {
        guard ModelCatalog.catalogConfigured(profile) else { return "Included with Bello Agent" }
        let value = profile.catalogUrl ?? ""
        guard let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host else { return "Saved connection source" }
        return host + (parts.port.map { ":\($0)" } ?? "") + parts.path
    }
}

/// The list's scroll view at the height the picker gives it
/// (`.frame(height: min(340, rows × 68))`).
@MainActor final class CatalogRowsHolder: NSView {
    var didLayout: (() -> Void)?
    var height: CGFloat = 0 { didSet { if oldValue != height { invalidateIntrinsicContentSize() } } }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }
    override func layout() { super.layout(); for view in subviews { view.frame = bounds }; didLayout?() }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }
}

/// The picker's refresh button: `arrow.clockwise` in a 28-point square, plain.
@MainActor final class CatalogRefreshButton: PiKit.ButtonBase {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        pressScales = false; hitsShapeOnly = false
        disabledOpacity = PiKit.plainDisabledDimming
        toolTip = "Reload this saved connection and refresh its model list"
        setAccessibilityLabel("Refresh models")
        setAccessibilityIdentifier("refresh-model-catalog")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }
    override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
    override func drawContent(in rect: CGRect) {
        PiKit.Symbol("arrow.clockwise", size: 13).drawPlaced(centredIn: rect, color: .piInk, scale: piScale)
    }
}

/// A plain caption button (`Button(…).buttonStyle(.plain).font(caption)`).
@MainActor final class CatalogLinkButton: PiKit.ButtonBase, ShellBaselined {
    override var title: String { didSet { if oldValue != title { invalidateIntrinsicContentSize(); redrawContent(); PiKit.sizeChanged(self) } } }
    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        pressScales = false; hitsShapeOnly = false
        disabledOpacity = PiKit.plainDisabledDimming
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private var line: PiKit.Line { PiKit.Line(title, font: PiKit.Font.caption, color: .piInk) }
    override var intrinsicContentSize: NSSize { line.size(scale: piScale) }
    var firstBaseline: CGFloat { line.baseline(scale: piScale) }
    override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
    override func drawContent(in rect: CGRect) { line.draw(at: .zero, scale: piScale) }
}

/// "Use connection default": a circle (filled with a check while chosen)
/// and the words, at most two lines (`HStack { Image; Text.lineLimit(2); Spacer() }`).
@MainActor final class CatalogDefaultRow: PiKit.ButtonBase, PiKit.WidthSizing {
    private var words = "", selected = false
    private let text = ShellText("", font: PiKit.Font.caption, color: .piInk, maximumLines: 2)
    /// Disabled, its words dim with its face, as a plain button's label does.
    override var isEnabled: Bool {
        didSet { if oldValue != isEnabled { for view in subviews { view.alphaValue = isEnabled ? 1 : CGFloat(PiKit.plainDisabledDimming) } } }
    }
    init() {
        super.init(frame: .zero)
        pressScales = false; hitsShapeOnly = false
        disabledOpacity = PiKit.plainDisabledDimming
        addSubview(text)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func update(title: String, selected: Bool) {
        guard title != words || selected != self.selected else { return }
        words = title; self.selected = selected
        text.set(title, color: .piInk)
        setAccessibilityLabel(title); invalidateIntrinsicContentSize(); redrawContent(); needsLayout = true
        PiKit.sizeChanged(self)
    }
    private var glyph: PiKit.Symbol { PiKit.Symbol(selected ? "checkmark.circle.fill" : "circle", size: PiKit.Font.captionSize) }
    /// The glyph, the stack's gap, the words, and the gap and least length of the `Spacer()`.
    private func textWidth(_ width: CGFloat) -> CGFloat { max(0, width - glyph.layoutSize.width - 8 - 16) }
    func height(forWidth width: CGFloat) -> CGFloat { max(glyph.layoutSize.height, text.height(forWidth: textWidth(width))) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 358)) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() {
        super.layout()
        let width = textWidth(bounds.width), height = text.height(forWidth: width)
        text.frame = CGRect(x: glyph.layoutSize.width + 8, y: PiKit.round((bounds.height - height) / 2, piScale), width: width, height: height)
    }
    override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
    override func drawContent(in rect: CGRect) {
        glyph.drawPlaced(centredIn: CGRect(x: 0, y: 0, width: glyph.layoutSize.width, height: rect.height), color: selected ? .piAccent : .piInkTertiary, scale: piScale)
    }
}

/// "Catalog source…": a plain button, its symbol and words in the caption
/// face, across the picker (`PiChoicePicker` around a `Label`).
@MainActor final class CatalogSourceButton: PiKit.ButtonBase {
    private let label = ShellLabel("Catalog source…", symbol: "list.bullet.rectangle", font: PiKit.Font.caption, color: .piInk)
    /// Disabled, its words dim with its face, as a plain button's label does.
    override var isEnabled: Bool {
        didSet { if oldValue != isEnabled { for view in subviews { view.alphaValue = isEnabled ? 1 : CGFloat(PiKit.plainDisabledDimming) } } }
    }
    init() {
        super.init(frame: .zero)
        pressScales = false; hitsShapeOnly = false
        disabledOpacity = PiKit.plainDisabledDimming
        addSubview(label)
        setAccessibilityLabel("Catalog source…")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: label.height(forWidth: bounds.width > 0 ? bounds.width : 358)) }
    override func layout() { super.layout(); label.frame = bounds }
    override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
}

/// An empty list's words, in the middle of at least 70 points.
@MainActor final class CatalogCentredLine: NSView, PiKit.WidthSizing {
    var line: PiKit.TextLine? { didSet { oldValue?.removeFromSuperview(); if let line { addSubview(line) } } }
    override var isFlipped: Bool { true }
    func height(forWidth width: CGFloat) -> CGFloat { max(70, line?.intrinsicContentSize.height ?? 0) }
    override func layout() {
        super.layout()
        guard let line else { return }
        let size = line.intrinsicContentSize
        line.frame = CGRect(x: PiKit.round((bounds.width - size.width) / 2, piScale), y: PiKit.round((bounds.height - size.height) / 2, piScale),
                            width: min(size.width, bounds.width), height: size.height)
    }
}

/// One model: its mark (a check while chosen), its name and tags, its id,
/// what it is for and its limits, on the accent wash while chosen.
@MainActor final class CatalogModelRow: PiKit.ButtonBase, PiKit.WidthSizing {
    private var item: ModelDescriptor?
    private var chosen = false
    /// On the accent wash with a check: the model in use.
    var isChosen: Bool { chosen }
    /// Disabled, its words dim with its face, as a plain button's label does.
    override var isEnabled: Bool {
        didSet { if oldValue != isEnabled { for view in subviews { view.alphaValue = isEnabled ? 1 : CGFloat(PiKit.plainDisabledDimming) } } }
    }
    private let column = ShellStack(.vertical, spacing: 3, alignment: .leading)
    private let nameRow = ShellStack(.horizontal, spacing: 5, alignment: .firstBaseline)
    private let mark = PiKit.SymbolView(PiKit.Symbol("cpu", size: 11, weight: .semibold), color: .piInkTertiary)
    init() {
        super.init(frame: .zero)
        pressScales = false; hitsShapeOnly = false
        addSubview(mark); addSubview(column)
        mark.setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func update(_ item: ModelDescriptor, chosen: Bool) {
        guard item != self.item || chosen != self.chosen else { return }
        self.item = item; self.chosen = chosen
        mark.symbol = PiKit.Symbol(chosen ? "checkmark" : "cpu", size: 11, weight: .semibold)
        mark.color = chosen ? .piAccent : .piInkTertiary
        let name = ShellText(item.displayName, font: PiKit.Font.body, color: .piInk)
        name.hugsLines = true
        var tags: [ShellItem] = [.view(name, .flexible)]
        if item.mini == true { tags.append(.view(PiKit.TextLine(PiKit.Line("Mini", font: PiKit.Font.caption, color: .piAccent)))) }
        if item.takesImages { tags.append(.view(PiKit.TextLine(PiKit.Line("Images", font: PiKit.Font.caption, color: .piInkSecondary)))) }
        if item.deprecated { tags.append(.view(PiKit.TextLine(PiKit.Line("Deprecated", font: PiKit.Font.caption, color: .piWarning)))) }
        nameRow.items = tags
        var lines: [ShellItem] = [.view(nameRow, .fill)]
        if item.displayName != item.id { lines.append(.view(ShellText(item.id, font: PiKit.Font.mono, color: .piInkSecondary), .fill)) }
        if !item.description.isEmpty { lines.append(.view(ShellText(item.description, font: PiKit.Font.caption, color: .piInkSecondary, maximumLines: 2), .fill)) }
        if let context = item.contextLabel { lines.append(.view(PiKit.TextLine(PiKit.Line(context, font: PiKit.Font.caption, color: .piInkTertiary)))) }
        if let output = item.outputLimitLabel { lines.append(.view(PiKit.TextLine(PiKit.Line(output, font: PiKit.Font.caption, color: .piInkTertiary)))) }
        column.items = lines
        setAccessibilityLabel(ModelSwitchPills.menuTitle(item))
        setAccessibilityIdentifier("catalog-choice-\(item.id)")
        refreshFace(); needsLayout = true
        PiKit.sizeChanged(self)
    }
    /// `.padding(8)` around `HStack(alignment: .top, spacing: 8)`: the 14-point
    /// mark, the words, and a `Spacer(minLength: 0)` that still costs the
    /// stack's 8-point gap before it.
    private func textWidth(_ width: CGFloat) -> CGFloat { max(0, width - 16 - 14 - 8 - 8) }
    func height(forWidth width: CGFloat) -> CGFloat { column.height(forWidth: textWidth(width)) + 16 }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 342)) }
    override func layout() {
        super.layout()
        let size = mark.intrinsicContentSize
        mark.frame = CGRect(x: 8 + PiKit.round((14 - size.width) / 2, piScale), y: 8 + 2, width: size.width, height: size.height)
        let width = textWidth(bounds.width)
        column.frame = CGRect(x: 8 + 14 + 8, y: 8, width: width, height: column.height(forWidth: width))
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }
    override func cornerRadius(for size: CGSize) -> CGFloat { 6 }
    override func styleFace() {
        fill.backgroundColor = piCGColor(chosen ? .piAccentSoft : .clear)
        stroke.borderColor = CGColor.clear
    }
}

/// "This chat uses its original model list": the saved catalogs for this
/// gateway, one to use or a menu of them, on the accent wash.
@MainActor final class CatalogRepairNotice: NSView, PiKit.WidthSizing {
    var choose: ((String) -> Void)?
    private let column = ShellStack(.vertical, spacing: 6, alignment: .leading, padding: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10))
    private var key: [String] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(column)
        toolTip = "Changes only the catalog for this connection's chats. Requests keep their existing connection, key, model and effort."
        setAccessibilityIdentifier("model-catalog-mismatch")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func update(choices: [ProfileRecord], loading: Bool) {
        let newKey = choices.map { $0.id + "|" + $0.name + "|" + CatalogModelPickerView.sourceLabel($0) } + ["\(loading)"]
        guard newKey != key else { return }
        key = newKey
        var items: [ShellItem] = [
            .view(PiKit.TextLine(PiKit.Line("This chat uses its original model list.", font: .systemFont(ofSize: PiKit.Font.captionSize, weight: .semibold), color: .piInk))),
            .view(ShellText("Another catalog is saved for this gateway. Refresh reloads the list shown above.", font: PiKit.Font.caption, color: .piInkSecondary), .fill),
        ]
        if choices.count == 1, let candidate = choices.first {
            items.append(.view(ShellText("Available: \(candidate.name) · \(CatalogModelPickerView.sourceLabel(candidate))", font: PiKit.Font.caption, color: .piInkSecondary, maximumLines: 2), .fill))
            let use = PiKit.Button("Use this catalog", style: .secondary)
            use.setAccessibilityIdentifier("repair-model-catalog")
            use.onPress = { [weak self] in self?.choose?(candidate.id) }
            use.isEnabled = !loading
            items.append(.view(use))
        } else {
            let menu = PiKit.MenuButton(title: "Choose a saved catalog", icon: "list.bullet.rectangle", identifier: "repair-model-catalog") { [weak self] in
                for candidate in choices {
                    PiMenuEntry.button("\(candidate.name) · \(CatalogModelPickerView.sourceLabel(candidate))") { self?.choose?(candidate.id) }
                }
            }
            menu.isEnabled = !loading
            items.append(.view(menu))
        }
        column.items = items
        needsLayout = true
    }
    func height(forWidth width: CGFloat) -> CGFloat { column.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 358)) }
    override func layout() { super.layout(); column.frame = bounds }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piAccentSoft); layer?.cornerRadius = 8 }
}
