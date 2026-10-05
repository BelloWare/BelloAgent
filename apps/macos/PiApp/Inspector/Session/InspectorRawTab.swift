import AppKit

/// Retained capture views stay mounted while filters and payload pages change.
@MainActor final class InspectorRawTab: DashView {
    let inspector: SessionInspectorModel
    let request: InspectorRequestModel
    var compact: Bool { didSet { if compact != oldValue { if toolbar != nil { rebuildToolbar() }; needsLayout = true } } }
    private var copySource: CapturedBodyCopySource?
    private var notice = "" { didSet { refreshNotice() } }
    private var pageText = "", pageTotal = 0, pageOffset = 0, pageLoading = false
    private var lastPart: InspectorRequestModel.RawPart?
    private var lastRow: String?
    private var lastFocus = 0
    private var bodyKey: String?
    private var bodyRoute: InspectorBodyRoute?
    private var body: CapturedBodyView?
    private var displayed: NSView?
    private var textView: PagedTextView?
    private var textKey: String?
    private var footer: NSView?
    private var toolbar: ShellStack?
    private var status: PiKit.Note?
    private lazy var parts = PiKit.Tabs(selection: request.raw, items: [(InspectorRequestModel.RawPart.request, "Request"), (.response, "Response"), (.headers, "Headers"), (.metadata, "Metadata"), (.links, "Links"), (.events, "Events")]) { [weak request] in request?.raw = $0 }
    private lazy var search = InspectorSearchField(text: request.query) { [weak request] in request?.query = $0 }
    private lazy var copy = PiKit.Button("Copy", symbol: "doc.on.doc", style: .ghost) { [weak self] in self?.copyView() }
    private lazy var captureMenu: PiKit.MenuControl = {
        let face = InspectorCaptureMenuFace()
        return PiKit.MenuControl(label: "Capture settings and exports", identifier: "inspector-raw-menu", help: "Capture settings and exports", face: face, onHover: { face.hovering = $0 }) { [weak self] in self?.menuEntries() ?? [] }
    }()
    private lazy var observer = ShellObserver { [weak self] in self?.refresh() }
    private var pageTask: Task<Void, Never>?
    private var currentPage: PageKey?
    private struct PageKey: Equatable { let attempt: String; let part: InspectorRequestModel.RawPart; let offset: Int }
    private var row: InspectorRequestRow? { request.row }
    private var showsBody: Bool { request.raw == .request || request.raw == .response }

    init(inspector: SessionInspectorModel, request: InspectorRequestModel, compact: Bool) {
        self.inspector = inspector; self.request = request; self.compact = compact
        super.init(frame: .zero)
        setAccessibilityIdentifier("inspector-raw"); copy.setAccessibilityIdentifier("inspector-raw-copy")
        observer.observe(request); refresh()
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { pageTask?.cancel(); pageTask = nil; currentPage = nil }
        else { refresh() }
    }
    func refresh() {
        if lastRow != row?.id || lastPart != request.raw {
            copySource = nil; pageOffset = 0; pageText = ""; pageTotal = 0
            pageTask?.cancel(); pageTask = nil; currentPage = nil
            if lastRow != row?.id { notice = "" }
            lastRow = row?.id; lastPart = request.raw
            rebuildToolbar()
        }
        search.text = request.query
        if lastFocus != request.searchFocus {
            lastFocus = request.searchFocus
            if !showsBody { request.raw = .request; refresh() }
            DispatchQueue.main.async { [weak self] in guard let self else { return }; self.window?.makeFirstResponder(self.search.field) }
        }
        refreshContent(); refreshNotice(); refreshCopy(); needsLayout = true
    }
    private func rebuildToolbar() {
        parts.selection = request.raw
        parts.setAccessibilityIdentifier("inspector-raw-parts")
        var items: [ShellItem] = [.view(parts), .spacer(4)]
        if showsBody { items.append(.view(search, .fixed(compact ? 180 : 250))) }
        items += [.view(copy), .view(captureMenu, .fixed(28))]
        if let toolbar { toolbar.items = items }
        else { toolbar = inspectorRow(items, spacing: PiSpacing.sm); addSubview(toolbar!) }
    }
    private func show(_ view: NSView) { if displayed !== view { displayed?.removeFromSuperview(); displayed = view; addSubview(view) } }
    private func refreshContent() {
        let focus = InspectorButtonFocus(in: self); defer { focus?.restore(in: self) }
        footer?.removeFromSuperview(); footer = nil
        guard let row else { return }
        switch request.raw {
        case .request, .response:
            let kind = request.raw == .request ? "request" : "response"
            let key = row.id + ":" + kind
            let route = InspectorBodyRoute.resolve(row: row, kind: kind, metadata: request.metadata, hasWorkspace: inspector.workspace != nil)
            if bodyKey != key {
                bodyKey = key; bodyRoute = route
                body = CapturedBodyView(source: route.source(inspector: inspector, request: request, row: row, kind: kind), sessionID: inspector.scope.sessionID, attemptID: row.id, kind: kind, retained: route == .archive, initialFormat: kind == "response" ? .combined : .json, searchQuery: request.query, searchHeaders: request.metadata[kind + "Headers"]?.object ?? [:], growingBytes: kind == "response" ? request.growingBytes : nil, onCopySource: { [weak self] in self?.copySource = $0; self?.refreshCopy() })
            } else if bodyRoute != route {
                bodyRoute = route
                body?.update(source: route.source(inspector: inspector, request: request, row: row, kind: kind), retained: route == .archive)
            }
            body?.update(searchQuery: request.query, searchHeaders: request.metadata[kind + "Headers"]?.object ?? [:], growingBytes: kind == "response" ? request.growingBytes : nil)
            if let body { show(body) }
        case .headers:
            let column = inspectorColumn([InspectorSectionTitle("Request headers", subtitle: "authentication values are masked"), CapturedHeadersView(headers: request.metadata["requestHeaders"]?.object ?? [:]), InspectorSectionTitle("Response headers"), CapturedHeadersView(headers: request.metadata["responseHeaders"]?.object ?? [:])], spacing: 14)
            let scroll = PageScrollView(column: column); scroll.setAccessibilityIdentifier("inspector-raw-headers"); show(scroll)
        case .metadata:
            showText(request.metadataText, empty: request.metadataLoaded ? "No metadata record." : "Reading the metadata record…", label: "Request metadata", key: row.id + ":metadata")
        case .links, .events:
            showText(pageText, empty: pageLoading ? "Reading…" : "Nothing recorded.", label: request.raw == .links ? "Message links" : "Event index", key: row.id + ":" + request.raw.rawValue)
            var items: [ShellItem] = []
            if pageTotal > 128 {
                items.append(.view(PiKit.Pager(center: inspectorText("\(pageOffset + 1)–\(min(pageTotal, pageOffset + 128)) of \(pageTotal)"), canPrevious: pageOffset > 0, canNext: pageOffset + 128 < pageTotal, previous: { [weak self] in guard let self else { return }; self.pageOffset = max(0, self.pageOffset - 128); self.refreshContent() }, next: { [weak self] in guard let self else { return }; self.pageOffset += 128; self.refreshContent() })))
            }
            items += [.spacer(0), .view(inspectorText(request.raw == .links ? "Messages this request used (context) and produced (output)." : "Server-sent event offsets into the retained response.", font: PiKit.Font.micro, color: .piInkTertiary), .flexible)]
            footer = inspectorRow(items); addSubview(footer!)
            let key = PageKey(attempt: row.id, part: request.raw, offset: pageOffset)
            if currentPage != key, window != nil {
                currentPage = key; pageTask?.cancel()
                pageTask = Task { [weak self] in await self?.loadPage(row, key: key) }
            }
        }
        needsLayout = true; refreshCopy()
    }
    private func showText(_ text: String, empty: String, label: String, key: String) {
        if textKey != key { textKey = key; textView = PagedTextView(text: text, accessibilityLabel: label) }
        else { textView?.text = text }
        guard let textView else { return }
        let host = InspectorContentHost(content: PiKit.inset(textView))
        if text.isEmpty { host.cover(InspectorPlaceholder(symbol: "", title: empty)) }
        show(host)
    }
    private func refreshCopy() { copy.isEnabled = showsBody ? copySource != nil : !request.metadataText.isEmpty || !pageText.isEmpty }
    private func refreshNotice() {
        status?.removeFromSuperview(); status = nil
        if !notice.isEmpty { status = PiKit.Note(notice, tone: .warning); addSubview(status!) }
        needsLayout = true
    }
    private func loadPage(_ row: InspectorRequestRow, key: PageKey) async {
        guard currentPage == key, !Task.isCancelled else { return }
        pageLoading = true; pageText = ""
        defer { if currentPage == key { pageLoading = false; refreshContent() } }
        refreshContent()
        do {
            let value: [String: WireValue]
            if key.part == .links {
                value = try await inspector.archive.messageLinks(attemptID: row.id, offset: key.offset)
            } else if row.source != .live || request.metadata["response"]?.object?["savedToLog"]?.bool == true,
                      let retained = try? await inspector.archive.eventIndices(attemptID: row.id, offset: key.offset) {
                // A request the log saved is read there, also while the index still shows the helper's row.
                value = retained
            } else if let workspace = inspector.workspace {
                value = try await workspace.debugRequest("debug.raw-events", sessionID: inspector.scope.sessionID, params: ["attemptId": .string(row.id), "offset": .number(Double(key.offset))])
            } else { throw HostError.failure("No event index was retained for this request.") }
            try Task.checkCancellation()
            let text = await Task.detached(priority: .userInitiated) { () -> String in
                if let links = value["links"]?.array {
                    return links.compactMap(\.object).map { ($0["relationship"]?.string ?? "").padding(toLength: 9, withPad: " ", startingAt: 0) + ($0["messageId"]?.string ?? "") }.joined(separator: "\n")
                }
                return WireValue.object(value).pretty
            }.value
            try Task.checkCancellation()
            guard currentPage == key else { return }
            pageText = text; pageTotal = Int(value["total"]?.number ?? 0)
        } catch is CancellationError {
        } catch { if currentPage == key { pageText = ""; notice = error.localizedDescription } }
    }

    // MARK: Copy, capture settings and exports

    private func copyView() {
        if showsBody {
            guard let copySource else { return }
            Task {
                do { let text = try await copySource.render(); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); notice = "" }
                catch { if !(error is CancellationError) { notice = error.localizedDescription } }
            }
        } else {
            let text = request.raw == .metadata ? request.metadataText : pageText
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// Built when the menu opens: the capture mode as it is then, and what can be exported.
    private func menuEntries() -> [PiMenuEntry] {
        guard let workspace = inspector.workspace, let row else { return [] }
        let sessionID = inspector.scope.sessionID
        let mode = workspace.displays[sessionID]?.captureMode ?? "persist"
        var modes = [("off", "Off"), ("memory", "Session memory")]
        if !workspace.isEphemeral(sessionID) { modes.append(("persist", "Persist locally")) }
        var entries: [PiMenuEntry] = [.note("Future body capture")]
        for (value, title) in modes {
            entries.append(.button(title, checked: mode == value, identifier: "inspector-capture-" + value) { Task { await self.setMode(value) } })
        }
        entries.append(.divider)
        entries.append(.button("Export Metadata…", enabled: row.source != .record, identifier: "inspector-export-metadata") { Task { await self.exportMetadata(row) } })
        entries.append(.button("Export Retained Body Bytes…", enabled: row.source != .record, identifier: "inspector-export-bodies") { Task { await self.exportBodies(row) } })
        entries.append(.button("Export a Redacted View…", enabled: showsBody && copySource != nil, identifier: "inspector-export-redacted") { Task { await self.exportRedacted(row) } })
        entries.append(.divider)
        entries.append(.button("Clear This Chat's Captures…", destructive: true, identifier: "inspector-clear-captures") { Task { await self.clear() } })
        return entries
    }

    private func setMode(_ mode: String) async {
        guard let workspace = inspector.workspace else { return }
        do { try await workspace.setCaptureMode(mode, sessionID: inspector.scope.sessionID); notice = "" } catch { notice = error.localizedDescription }
    }

    private func clear() async {
        guard let workspace = inspector.workspace else { return }
        guard await PiQuestion.shared.confirm("Clear this chat's capture bodies?", "Remove current memory bodies and this chat's retained payload references. Request metrics, message links, conversation history and exported copies stay.", action: "Clear", destructive: true) else { return }
        do { try await workspace.clearCaptures(sessionID: inspector.scope.sessionID); inspector.refresh() } catch { notice = error.localizedDescription }
    }

    private func exportMetadata(_ row: InspectorRequestRow) async {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "BelloAgent-request-metadata.json"
        guard let url = await PiQuestion.shared.save(panel) else { return }
        do { try Data(request.metadataText.utf8).write(to: url, options: .atomic); notice = "" } catch { notice = error.localizedDescription }
    }

    private func exportBodies(_ row: InspectorRequestRow) async {
        guard await PiQuestion.shared.confirm("Export sensitive retained body bytes?", "This exports request.bin, response.bin and a manifest of their completeness and hashes, including every retained byte and any secret in them. Prefixes and expired captures are labeled. Nothing is sent again.") else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "Choose where to put a new trace folder."
        guard let destination = await PiQuestion.shared.open(panel).first else { return }
        do {
            let saved: URL
            if row.source != .live {
                saved = try await inspector.archive.exportRetained(sessionID: inspector.scope.sessionID, attemptID: row.id, destination: destination)
            } else if let workspace = inspector.workspace {
                saved = try await workspace.persistAttempt(sessionID: inspector.scope.sessionID, attemptID: row.id, destination: destination)
            } else { throw HostError.failure("This request's bytes are not available.") }
            notice = "Exported " + saved.path
        } catch { notice = error.localizedDescription }
    }

    /// Replaces a literal the reader names with [REDACTED] in the view on
    /// screen, shows the result, then saves it with a manifest that says so.
    private func exportRedacted(_ row: InspectorRequestRow) async {
        guard let copySource else { return }
        let ask = NSAlert(); ask.messageText = "Which literal should be redacted?"
        ask.informativeText = "Every occurrence is replaced with [REDACTED] in a copy of the view on screen. This is not a secret detector."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24)); ask.accessoryView = field
        ask.addButton(withTitle: "Preview"); ask.addButton(withTitle: "Cancel")
        guard await PiQuestion.shared.ask(ask) == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        let literal = field.stringValue
        do {
            let text = try await copySource.render()
            let transformed = await Task.detached(priority: .userInitiated) { text.replacingOccurrences(of: literal, with: "[REDACTED]") }.value
            let preview = NSAlert(); preview.messageText = "Redacted view"
            preview.informativeText = "Only the literal you named is replaced. Check the preview before exporting."
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300)); let view = NSTextView(frame: scroll.bounds)
            view.isEditable = false; view.string = String(transformed.prefix(200_000)); scroll.documentView = view; scroll.hasVerticalScroller = true
            preview.accessoryView = scroll
            preview.addButton(withTitle: "Export…"); preview.addButton(withTitle: "Cancel")
            guard await PiQuestion.shared.ask(preview) == .alertFirstButtonReturn else { return }
            let panel = NSSavePanel(); panel.nameFieldStringValue = "BelloAgent-redacted-view.json"
            guard let url = await PiQuestion.shared.save(panel) else { return }
            let manifest: WireValue = .object(["attemptId": .string(row.id), "sourceView": .string(request.raw.rawValue), "byteExact": .bool(false),
                                               "transformations": .array([.string("The displayed view with a reader-named literal replaced by [REDACTED]. Other sensitive data may remain.")]),
                                               "view": .string(transformed)])
            try Data(manifest.pretty.utf8).write(to: url, options: .atomic)
        } catch { if !(error is CancellationError) { notice = error.localizedDescription } }
    }
    override func layout() {
        super.layout()
        let inset = compact ? PiSpacing.lg : PiSpacing.xl
        let width = max(0, bounds.width - 2 * inset)
        if let toolbar {
            if let index = toolbar.items.firstIndex(where: { $0.view === search }) { toolbar.items[index].size = .fixed(compact ? 180 : 250) }
            let height = toolbar.height(forWidth: width); toolbar.frame = CGRect(x: inset, y: 12, width: width, height: height)
        }
        let top = (toolbar?.frame.maxY ?? 12) + 10
        let noteHeight = status.map { PiKit.height(of: $0, width: width) + 10 } ?? 0
        let footHeight = footer.map { PiKit.height(of: $0, width: width) + 8 } ?? 0
        let height = max(0, bounds.height - top - 12 - noteHeight - footHeight)
        displayed?.frame = CGRect(x: inset, y: top, width: width, height: height)
        footer?.frame = CGRect(x: inset, y: top + height + 8, width: width, height: max(0, footHeight - 8))
        status?.frame = CGRect(x: inset, y: bounds.height - 12 - max(0, noteHeight - 10), width: width, height: max(0, noteHeight - 10))
    }
}

@MainActor private final class InspectorCaptureMenuFace: DashView {
    var hovering = false { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }
    override func draw(_ dirtyRect: NSRect) {
        (hovering ? NSColor.piFillStrong : .piFill).setFill(); NSBezierPath(ovalIn: bounds).fill()
        PiKit.Symbol("ellipsis", size: 12, weight: .semibold).draw(centredIn: bounds, color: hovering ? .piInk : .piInkSecondary, scale: piScale)
    }
}

@MainActor final class InspectorSearchField: PiKit.Box, NSTextFieldDelegate {
    let field = NSTextField(string: "")
    private let search = PiKit.SymbolView(PiKit.Symbol("magnifyingglass", size: 11, weight: .medium), color: .piInkTertiary)
    private let clear = InspectorSearchClearButton(frame: .zero)
    private let changed: (String) -> Void
    var text: String { get { field.stringValue } set { if field.stringValue != newValue { field.stringValue = newValue }; clear.isHidden = newValue.isEmpty; needsLayout = true } }
    init(text: String, changed: @escaping (String) -> Void) {
        self.changed = changed
        super.init(fill: .piSurface, stroke: .piHairline, cornerRadius: 8)
        PiKit.configurePlain(field, font: PiKit.Font.caption, placeholder: "Find in body and headers")
        field.setAccessibilityIdentifier("inspector-raw-search"); field.delegate = self
        clear.onPress = { [weak self] in self?.text = ""; self?.changed("") }
        shellAdd([field, search, clear]); self.text = text
    }
    required init?(coder: NSCoder) { nil }
    func controlTextDidChange(_ notification: Notification) { clear.isHidden = field.stringValue.isEmpty; needsLayout = true; changed(field.stringValue) }
    func controlTextDidBeginEditing(_ notification: Notification) { strokeColor = NSColor.piAccent.piOpacity(0.5) }
    func controlTextDidEndEditing(_ notification: Notification) { strokeColor = .piHairline }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: PiKit.Line("Ag", font: PiKit.Font.caption, color: .black).lineHeight + 12) }
    override func layout() {
        super.layout(); let icon = search.intrinsicContentSize
        search.frame = CGRect(x: 9, y: (bounds.height - icon.height) / 2, width: icon.width, height: icon.height)
        let clearSize = clear.intrinsicContentSize
        let x = 9 + icon.width + 6, clearWidth: CGFloat = clear.isHidden ? 0 : clearSize.width + 6
        field.frame = CGRect(x: x - PiKit.fieldInset, y: 6, width: max(0, bounds.width - x - 9 - clearWidth) + 2 * PiKit.fieldInset, height: bounds.height - 12)
        clear.frame = CGRect(x: bounds.width - 9 - clearSize.width, y: (bounds.height - clearSize.height) / 2, width: clearSize.width, height: clearSize.height)
    }
}

/// The search's plain body-size symbol has no icon-button scale or hover
/// circle: it matches the original Image-only clear action.
@MainActor private final class InspectorSearchClearButton: PiKit.ButtonBase {
    private let glyph = PiKit.Symbol("xmark.circle.fill", size: 13, weight: .regular)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); pressScales = false
        setAccessibilityIdentifier("inspector-raw-search-clear")
        setAccessibilityLabel("Clear the search")
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { glyph.layoutSize }
    override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
    override func drawContent(in rect: CGRect) { glyph.drawPlaced(centredIn: rect, color: .piInkTertiary, scale: piScale) }
}
