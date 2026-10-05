import AppKit

/// Complete retained-body presentation shared by both Inspector entry points.
/// Expiry and prefix states remain visible; only "Load latest" reads growth.
@MainActor final class CapturedBodyView: DashView, PiKit.WidthSizing {
    let source: CapturedBodySource
    let sessionID: String, attemptID: String, kind: String
    let retained: Bool
    private(set) var revision: Int
    private(set) var searchQuery: String
    private(set) var searchHeaders: [String: WireValue]
    private(set) var growingBytes: Int?
    var onDisplayedText: ((String) -> Void)?
    var onCopySource: ((CapturedBodyCopySource?) -> Void)?
    let controller = CapturedBodyController()
    let search = PayloadSearchController()
    private lazy var observer = ShellObserver { [weak self] in self?.refresh() }
    private var loadTask: Task<Void, Never>?, formatTask: Task<Void, Never>?, searchTask: Task<Void, Never>?
    private var previousSelection: Selection?
    private(set) var format: CapturedBodyFormat
    private var selection = "", expandRevision = 0, expandAll = false
    private var outlineCommand: JSONOutlineCommand?
    private var hex = "", utf8 = ""
    private var hexDocument: UUID?, utf8Document: UUID?
    private var shown: FormatSelection?, searched: SearchSelection?
    private var latestRequests = 0
    private let column = PayloadColumn()
    private var outline: JSONOutlineView?
    private let text = PagedTextView(text: "", accessibilityLabel: "Complete retained HTTP body")
    private let selectionText = PagedTextView(text: "", accessibilityLabel: "Selected JSON value")
    private var searchText: PayloadSearchTextView?
    private lazy var tabs = PiKit.Tabs(selection: .json, items: [(CapturedBodyFormat.json, "JSON"), (.text, "UTF-8"), (.hex, "Hex")], accessibilityName: "Captured body format") { [weak self] in self?.setFormat($0) }
    private lazy var tabsRow = ShellStack(.horizontal, spacing: PiSpacing.sm, [.view(tabs), .spacer(8)])
    private let note = ShellText("", font: PiKit.Font.micro, color: .piInkTertiary)
    private let summary = ShellSelectableText("", font: PiKit.Font.micro, color: .piInkSecondary)
    private let warning = ShellText("", font: PiKit.Font.micro, color: .piWarning)
    private let empty = ShellText("", font: PiKit.Font.caption, color: .piInkSecondary)
    private let progress = PiKit.ProgressBar(value: 0, total: 1)
    private let loadingText = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInkSecondary))
    private lazy var loading = PayloadCentered(ShellStack(.vertical, spacing: PiSpacing.sm, alignment: .center, [.view(progress, .fixed(300)), .view(loadingText)]))
    private lazy var combining = PayloadCentered(ShellStack(.vertical, spacing: PiSpacing.sm, alignment: .center, [.view(PiKit.spinner(controlSize: .regular)), .view(PiKit.TextLine(PiKit.Line("Combining captured response events…", font: PiKit.Font.caption, color: .piInk)))]))
    let expandButton = PiKit.Button("Expand all", style: .ghost)
    let sectionButton = PiKit.Button("Collapse section", style: .ghost)
    let collapseButton = PiKit.Button("Collapse all", style: .ghost)
    let topButton = PiKit.Button("Top", symbol: "arrow.up.to.line", style: .ghost)
    private lazy var controls = ShellStack(.horizontal, spacing: PiSpacing.sm, [.view(expandButton), .view(sectionButton), .view(collapseButton), .spacer(0), .view(topButton)])
    private let growthText = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.monospacedDigits(PiKit.Font.micro), color: .piInkSecondary))
    let latestButton = PiKit.Button("Load latest", style: .ghost, compact: true)
    private let updating = PiKit.TextLine(PiKit.Line("Loading…", font: PiKit.Font.micro, color: .piInkTertiary))
    private lazy var growth = ShellStack(.horizontal, spacing: PiSpacing.sm, [.view(growthText, .flexible), .view(updating), .view(latestButton), .spacer(0)])
    private let searchCount = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInk))
    private let searchUpdating = PiKit.TextLine(PiKit.Line("Updating…", font: PiKit.Font.micro, color: .piInkTertiary))
    let previousMatch = PiKit.Button("", symbol: "chevron.up", style: .ghost)
    let nextMatch = PiKit.Button("", symbol: "chevron.down", style: .ghost)
    private let searchLoading = PiKit.ShimmerText("Searching body and headers…", size: 11)
    private lazy var searchBar = ShellStack(.horizontal, spacing: 8, [.view(searchCount), .view(searchLoading), .spacer(8), .view(searchUpdating), .view(previousMatch), .view(nextMatch)])
    private var textBox: PiKit.Box?, outlineBox: PiKit.Box?, searchBox: PiKit.Box?
    private lazy var selectionBox = PiKit.inset(selectionText, sunken: true)

    private struct Selection: Equatable {
        let session: String, attempt: String, kind: String
        let retained: Bool
        let revision: Int, latest: Int
    }
    private struct FormatSelection: Equatable { let format: CapturedBodyFormat; let document: UUID? }
    private struct SearchSelection: Equatable {
        let query: String; let document: UUID?; let format: CapturedBodyFormat
        let combined: Bool; let headers: [String: WireValue]
    }
    convenience init(model: WorkspaceModel, sessionID: String, attemptID: String, kind: String, retained: Bool,
                     revision: Int = 0, initialFormat: CapturedBodyFormat = .json,
                     onDisplayedText: ((String) -> Void)? = nil, onCopySource: ((CapturedBodyCopySource?) -> Void)? = nil) {
        self.init(source: retained ? .archive(model.traces, attemptID: attemptID, kind: kind) : .live(model, sessionID: sessionID, attemptID: attemptID, kind: kind),
                  sessionID: sessionID, attemptID: attemptID, kind: kind, retained: retained, revision: revision, initialFormat: initialFormat,
                  onDisplayedText: onDisplayedText, onCopySource: onCopySource)
    }
    init(source: CapturedBodySource, sessionID: String, attemptID: String, kind: String, retained: Bool,
         revision: Int = 0, initialFormat: CapturedBodyFormat = .json, searchQuery: String = "", searchHeaders: [String: WireValue] = [:],
         growingBytes: Int? = nil, onDisplayedText: ((String) -> Void)? = nil, onCopySource: ((CapturedBodyCopySource?) -> Void)? = nil) {
        self.source = source; self.sessionID = sessionID; self.attemptID = attemptID; self.kind = kind; self.retained = retained
        self.revision = revision; format = initialFormat; self.searchQuery = searchQuery; self.searchHeaders = searchHeaders; self.growingBytes = growingBytes
        self.onDisplayedText = onDisplayedText; self.onCopySource = onCopySource
        super.init(frame: .zero); addSubview(column)
        setAccessibilityIdentifier("captured-body-view")
        controls.setAccessibilityIdentifier("payload-outline-controls")
        expandButton.setAccessibilityIdentifier("payload-expand-all")
        sectionButton.setAccessibilityIdentifier("payload-collapse-section")
        collapseButton.setAccessibilityIdentifier("payload-collapse-all")
        topButton.setAccessibilityIdentifier("payload-scroll-top")
        latestButton.setAccessibilityIdentifier("payload-load-latest")
        searchCount.setAccessibilityIdentifier("payload-search-count")
        sectionButton.toolTip = "Collapse the selected section, or the section at your current scroll position"
        topButton.toolTip = "Back to the start of this request or response"
        previousMatch.setAccessibilityLabel("Previous match"); previousMatch.toolTip = "Previous match"
        nextMatch.setAccessibilityLabel("Next match"); nextMatch.toolTip = "Next match"
        expandButton.onPress = { [weak self] in self?.expandAll = true; self?.expandRevision += 1; self?.refresh() }
        collapseButton.onPress = { [weak self] in self?.selection = ""; self?.expandAll = false; self?.expandRevision += 1; self?.refresh() }
        sectionButton.onPress = { [weak self] in self?.outlineCommand = JSONOutlineCommand(action: .collapseSection); self?.refresh() }
        topButton.onPress = { [weak self] in self?.outlineCommand = JSONOutlineCommand(action: .top); self?.refresh() }
        latestButton.onPress = { [weak self] in self?.latestRequests += 1; self?.startLoad() }
        previousMatch.onPress = { [weak self] in self?.search.move(-1) }
        nextMatch.onPress = { [weak self] in self?.search.move(1) }
        observer.observe(controller); observer.observe(search)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    private var identity: Selection { Selection(session: sessionID, attempt: attemptID, kind: kind, retained: retained, revision: revision, latest: latestRequests) }
    private var activeFormat: CapturedBodyFormat { controller.document?.resolvedFormat(format, kind: kind) ?? .json }
    func update(revision: Int? = nil, searchQuery: String = "", searchHeaders: [String: WireValue] = [:], growingBytes: Int? = nil) {
        let changed = revision.map { $0 != self.revision } ?? false
        if let revision { self.revision = revision }; self.searchQuery = searchQuery; self.searchHeaders = searchHeaders; self.growingBytes = growingBytes
        if changed, window != nil { startLoad() }
        refresh()
    }
    func setFormat(_ value: CapturedBodyFormat) { guard format != value else { return }; format = value; refresh() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startLoad(); refresh() }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, window != nil { stop() }
        super.viewWillMove(toWindow: newWindow)
    }
    func stop() {
        loadTask?.cancel(); formatTask?.cancel(); searchTask?.cancel()
        loadTask = nil; formatTask = nil; searchTask = nil
        outline?.stop(); outline = nil; outlineBox = nil
        controller.cancel(); search.cancel(); previousSelection = nil; shown = nil; searched = nil
        onCopySource?(nil)
    }
    private func startLoad() {
        let id = identity
        guard previousSelection != id else { return }
        loadTask?.cancel()
        let preserve = previousSelection.map { $0.session == id.session && $0.attempt == id.attempt && $0.kind == id.kind } ?? false
        previousSelection = id
        if !preserve {
            onDisplayedText?(""); onCopySource?(nil); selection = ""; hex = ""; utf8 = ""
            hexDocument = nil; utf8Document = nil; expandAll = false; expandRevision = 0; outlineCommand = nil
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.controller.load(kind: self.kind, source: self.source, preservingDocument: preserve, combine: preserve && self.activeFormat == .combined)
            guard !Task.isCancelled, self.identity == id else { return }
            self.refresh()
        }
    }
    private func startFormatIfNeeded() {
        let current = FormatSelection(format: activeFormat, document: controller.document?.id)
        guard shown != current else { return }
        let inPlace = controller.document?.replaces != nil && shown == FormatSelection(format: activeFormat, document: controller.document?.replaces)
        if shown?.format != current.format { outline?.stop(); outline = nil; outlineBox = nil }
        shown = current
        if !inPlace { selection = ""; expandAll = false; expandRevision = 0; outlineCommand = nil }
        formatTask?.cancel()
        formatTask = Task { [weak self] in
            guard let self else { return }
            if self.activeFormat == .combined { await self.controller.prepareCombined() }
            guard !Task.isCancelled, self.shown == current else { return }
            await self.updateHexIfNeeded(); await self.updateUTF8IfNeeded(); await self.updateDisplayedText()
            guard !Task.isCancelled else { return }; self.refresh()
        }
    }
    private func startSearchIfNeeded() {
        let current = SearchSelection(query: searchQuery, document: controller.document?.id, format: activeFormat,
                                      combined: controller.document?.combinationFinished ?? false, headers: searchHeaders)
        guard searched != current else { return }; searched = current
        searchTask?.cancel()
        guard !searchQuery.isEmpty else { search.cancel(); return }
        outline?.coordinator.cancelPendingSelection()
        guard activeFormat != .combined || controller.document?.combinationFinished != false else { return }
        searchTask = Task { [weak self] in
            guard let self else { return }
            await self.search.search(document: self.controller.document, format: current.format, headers: current.headers, kind: self.kind, query: current.query)
        }
    }
    private func refresh() {
        startFormatIfNeeded(); startSearchIfNeeded()
        tabs.items = controller.document?.availableFormats(kind: kind) ?? [(.json, "JSON"), (.text, "UTF-8"), (.hex, "Hex")]
        tabs.selection = activeFormat
        var items: [PayloadColumn.Item] = [.view(tabsRow)]
        if !searchQuery.isEmpty {
            if let result = search.result {
                searchCount.line.text = result.matches.isEmpty ? "No matches in body or headers" : "\(search.selected + 1) of \(result.matches.count)\(result.limited ? "+" : "") matches"
                searchCount.isHidden = false; searchLoading.isHidden = true
                searchUpdating.isHidden = !search.loading
                previousMatch.isHidden = false; nextMatch.isHidden = false
                previousMatch.isEnabled = !result.matches.isEmpty; nextMatch.isEnabled = !result.matches.isEmpty
                if let searchText { searchText.update(result: result, selected: search.selected) }
                else { searchText = PayloadSearchTextView(result: result, selected: search.selected); searchBox = PiKit.inset(searchText!, sunken: true) }
                items += [.view(searchBar), .flexible(searchBox!)]
            } else {
                searchCount.isHidden = true; searchLoading.isHidden = !search.loading
                searchUpdating.isHidden = true; previousMatch.isHidden = true; nextMatch.isHidden = true
                empty.set(search.notice, color: .piInkSecondary)
                items += [.view(searchBar), .flexible(PayloadCentered(empty))]
            }
        } else if let document = controller.document {
            if let json = document.structured(format: activeFormat) {
                let key = "\(sessionID):\(attemptID):\(kind):\(activeFormat.rawValue)"
                if let outline {
                    outline.update(json: json, selection: selection, expandRevision: expandRevision, expandAll: expandAll, command: outlineCommand, stateKey: key)
                } else {
                    let view = JSONOutlineView(json: json, selection: selection, expandRevision: expandRevision, expandAll: expandAll, command: outlineCommand, stateKey: key) { [weak self] value in
                        guard let self, self.selection != value else { return }; self.selection = value; self.refresh()
                    }
                    outline = view; outlineBox = PiKit.inset(view, sunken: true)
                }
                items += [.flexible(outlineBox!), .view(controls)]
                if !selection.isEmpty { selectionText.text = selection; items.append(.fixed(selectionBox, 100)) }
                note.set(activeFormat == .combined ? document.combinedResponse?.notice ?? "" : document.eventStream == nil
                         ? "Select a value to see its full contents. Formatting is a derived view; retained bytes are unchanged."
                         : "Events appear in captured order. Expand a frame and its data to inspect JSON. This is a formatted view; UTF-8, Hex and exports preserve the retained bytes.", color: .piInkTertiary)
                items.append(.view(note))
            } else if activeFormat == .combined { items.append(.flexible(combining)) }
            else {
                text.text = activeFormat == .hex ? hex : utf8
                if textBox == nil { textBox = PiKit.inset(text, sunken: true) }
                items.append(.flexible(textBox!))
                if activeFormat == .json { note.set("Not a JSON document or UTF-8 event stream · showing retained UTF-8.", color: .piInkTertiary); items.append(.view(note)) }
            }
        } else if controller.loading {
            progress.value = Double(controller.loaded); progress.total = Double(max(1, controller.total))
            loadingText.line.text = "Loading all retained bytes · \(controller.loaded.formatted()) / \(controller.total.formatted())"
            items.append(.flexible(loading))
        } else {
            empty.set(controller.notice.isEmpty ? "No retained body" : controller.notice, color: .piInkSecondary)
            items.append(.flexible(empty))
        }
        if let document = controller.document {
            summary.text = document.metadata.summary; items.append(.view(summary))
            if searchQuery.isEmpty, let growingBytes, growingBytes > document.bytes.count {
                growthText.line.text = "\(growingBytes.formatted()) bytes so far · showing the first \(document.bytes.count.formatted())"
                updating.isHidden = !controller.loading; latestButton.isHidden = controller.loading
                items.append(.view(growth))
            }
            if !controller.notice.isEmpty { warning.set(controller.notice, color: .piWarning); items.append(.view(warning)) }
        }
        column.items = items
        invalidateIntrinsicContentSize(); needsLayout = true; PiKit.sizeChanged(self)
    }
    func height(forWidth width: CGFloat) -> CGFloat { column.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 700)) }
    override func layout() { super.layout(); column.frame = bounds }
    private func updateDisplayedText() async {
        guard let document = controller.document else { onDisplayedText?(""); onCopySource?(nil); return }
        let id = identity, requested = activeFormat
        let source = CapturedBodyCopySource(id: document.id, document: document, format: requested, hex: hex, plain: utf8)
        onCopySource?(source)
        if let onDisplayedText, let value = try? await source.render(), !Task.isCancelled,
           id == identity, controller.document?.id == document.id, requested == activeFormat { onDisplayedText(value) }
    }
    private func updateUTF8IfNeeded() async {
        guard activeFormat != .hex, let document = controller.document, utf8Document != document.id,
              document.structured(format: activeFormat) == nil, !document.bytes.isEmpty else { return }
        let identity = identity, bytes = document.bytes, requested = activeFormat
        let decoding = Task.detached(priority: .userInitiated) { String(decoding: bytes, as: UTF8.self) }
        let value = await withTaskCancellationHandler(operation: { await decoding.value }, onCancel: { decoding.cancel() })
        guard !Task.isCancelled, identity == self.identity, activeFormat == requested, controller.document?.id == document.id else { return }
        utf8 = value; utf8Document = document.id
    }
    private func updateHexIfNeeded() async {
        guard activeFormat == .hex, let document = controller.document, hexDocument != document.id else { return }
        let identity = identity, bytes = document.bytes
        let rendering = Task.detached(priority: .userInitiated) { try CapturedBodyHex.render(bytes) }
        do {
            let value = try await withTaskCancellationHandler(operation: { try await rendering.value }, onCancel: { rendering.cancel() })
            guard !Task.isCancelled, identity == self.identity, format == .hex, controller.document?.id == document.id else { return }
            hex = value; hexDocument = document.id
        } catch { /* Leaving the view or format cancels expensive rendering. */ }
    }
}

@MainActor private final class PayloadCentered: DashView {
    let content: NSView
    init(_ content: NSView) { self.content = content; super.init(frame: .zero); addSubview(content) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override func layout() {
        super.layout()
        let height = min(bounds.height, PiKit.height(of: content, width: bounds.width))
        content.frame = CGRect(x: 0, y: max(0, PiKit.round((bounds.height - height) / 2, piScale)), width: bounds.width, height: height)
    }
}
enum CapturedBodyHex {
    /// One byte buffer for the whole dump. `String(format:)` per sixteen bytes
    /// meant four million formatter calls, and as many intermediate strings,
    /// for a large body.
    static func render(_ bytes: Data) throws -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8](); out.reserveCapacity(bytes.count * 4 + 16)
        for start in stride(from: 0, to: bytes.count, by: 16) {
            if start % 32_768 == 0 { try Task.checkCancellation() }
            for shift in stride(from: 28, through: 0, by: -4) { out.append(digits[(start >> shift) & 15]) }
            out.append(32); out.append(32)
            for byte in bytes[start..<min(start + 16, bytes.count)] { out.append(digits[Int(byte >> 4)]); out.append(digits[Int(byte & 15)]); out.append(32) }
            out.append(10)
        }
        return String(decoding: out, as: UTF8.self)
    }
}
