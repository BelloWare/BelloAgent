import AppKit
import UniformTypeIdentifiers

/// "Next Results" follows the query whose results are currently listed,
/// even if the search field has since changed.
enum ConversationSearchPaging {
    static func next(after result: ContentSearch, searched: String, current: String) -> (query: String, start: Int)? {
        result.next.map { (searched, $0) }
    }
}

@MainActor struct ConversationContentSource: Sendable {
    let search: @MainActor @Sendable (String, Int) async throws -> ContentSearch
    let page: @MainActor @Sendable (Int, Int, ContentCursor, String) async throws -> ContentPage
    let reveal: @MainActor @Sendable (ContentHit) async throws -> Void
    static func workspace(_ model: WorkspaceModel, sessionID: String) -> Self {
        Self(search: { try await model.searchConversation(sessionID, query: $0, start: $1) },
             page: { try await model.conversationPage(sessionID, first: $0, last: $1, cursor: $2, revision: $3) },
             reveal: { try await model.revealConversationHit(sessionID, hit: $0) })
    }
}

@MainActor final class ConversationContentView: DashView, InheritsEnabled {
    static let size = NSSize(width: 900, height: 700)
    let model: WorkspaceModel
    let sessionID: String
    private let source: ConversationContentSource
    private let pasteboard: NSPasteboard
    private let work = PayloadTaskScope()
    var dismiss: () -> Void
    var inheritedEnabled = true { didSet { refresh() } }
    let queryField = PiKit.TextField(placeholder: "Find in retained conversation", icon: "magnifyingglass")
    let searchButton = PiKit.Button("Search", style: .secondary, compact: true)
    private let spinner = PiKit.spinner(controlSize: .small)
    private let list = LazyStackView(frame: .zero)
    private let empty = PiKit.TextLine(PiKit.Line("No matches on this page", font: PiKit.Font.caption, color: .piInkTertiary))
    private let count = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.caption, color: .piInkSecondary))
    let next = PiKit.Button("Next Results", symbol: "chevron.right", style: .secondary)
    let reveal = PiKit.Button("Show in Transcript", symbol: "text.viewfinder", style: .secondary)
    let firstField = PiKit.NumberField(placeholder: "From", value: 1, width: 110)
    let lastField = PiKit.NumberField(placeholder: "Through", value: 1, width: 110)
    let startSelection = PiKit.Button("Start at Selection", style: .secondary, compact: true)
    let endSelection = PiKit.Button("End at Selection", style: .secondary, compact: true)
    let done = PiKit.Button("Done", style: .secondary)
    let exportButton = PiKit.Button("Export…", symbol: "square.and.arrow.up", style: .secondary)
    let copyRange = PiKit.Button("Copy Range", symbol: "doc.on.doc", style: .secondary)
    let copyAll = PiKit.Button("Copy Conversation", symbol: "doc.on.doc.fill", style: .primary)
    private let status = ShellNote("", tone: .danger)
    private let column = PayloadColumn(spacing: PiSpacing.md, padding: NSEdgeInsets(top: PiSpacing.xl, left: PiSpacing.xl, bottom: PiSpacing.xl, right: PiSpacing.xl))
    private var sheet: PiKit.Sheet!
    private var searched = "", selectedID: String?
    private var result = ContentSearch(hits: [], total: 0, next: nil, revision: "")
    private var busy = false { didSet { refresh() } }
    private var started = false
    private let glide = PiKit.SelectionGlide()
    private var selected: ContentHit? { result.hits.first { $0.id == selectedID } }
    init(model: WorkspaceModel, sessionID: String, source: ConversationContentSource? = nil,
         pasteboard: NSPasteboard = .general, dismiss: @escaping () -> Void = {}) {
        self.model = model; self.sessionID = sessionID; self.source = source ?? .workspace(model, sessionID: sessionID)
        self.pasteboard = pasteboard; self.dismiss = dismiss
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        let searchRow = ShellStack(.horizontal, spacing: PiSpacing.sm, [.view(queryField, .fill), .view(searchButton), .view(spinner)])
        let results = PayloadEmptyOverlay(content: list, empty: empty)
        let paging = ShellStack(.horizontal, spacing: PiSpacing.sm, [.view(count, .flexible), .spacer(8), .view(next), .view(reveal)])
        let range = ShellStack(.horizontal, spacing: PiSpacing.sm, [.view(firstField), .view(PiKit.TextLine(PiKit.Line("through", font: PiKit.Font.caption, color: .piInkSecondary))), .view(lastField), .view(startSelection), .view(endSelection), .spacer(8)])
        let card = PiKit.card(ShellStack(.vertical, spacing: PiSpacing.sm, [.view(PiKit.TextLine(PiKit.Line("Copy range", font: PiKit.Font.heading, color: .piInk))), .view(range, .fill)]), padding: PiSpacing.md)
        column.items = [.view(searchRow), .flexible(PiKit.inset(results)), .view(paging), .view(card), .view(status)]
        let foot = ShellStack(.horizontal, spacing: PiSpacing.sm, [.view(ShellText("Copy limit: 8 MiB. Larger conversations can be copied in explicit ranges.", font: PiKit.Font.caption, color: .piInkSecondary), .flexible), .spacer(8), .view(exportButton), .view(copyRange), .view(copyAll)])
        sheet = PiKit.Sheet("Search and copy conversation", subtitle: "Completed retained messages, including exposed reasoning and tool results. Opaque provider state and image bytes are omitted. Search covers the full retained branch; the transcript stays paged.", symbol: "magnifyingglass", content: column, actions: [done], footer: foot)
        sheet.width = Self.size.width; sheet.height = Self.size.height
        sheet.dismiss = { @MainActor @Sendable [weak self] in self?.dismiss() }
        addSubview(sheet)
        queryField.onChange = { [weak self] _ in self?.refresh() }; queryField.onSubmit = { [weak self] in self?.search() }
        searchButton.onPress = { [weak self] in self?.search() }
        next.symbolTrailing = true
        next.onPress = { [weak self] in
            guard let self, let page = ConversationSearchPaging.next(after: self.result, searched: self.searched, current: self.queryField.text) else { return }
            self.search(page.query, start: page.start)
        }
        reveal.onPress = { [weak self] in self?.showSelected() }
        firstField.onChange = { [weak self] _ in self?.refresh() }; lastField.onChange = { [weak self] _ in self?.refresh() }
        startSelection.onPress = { [weak self] in guard let self, let selected = self.selected else { return }; self.firstField.value = selected.position; self.refresh() }
        endSelection.onPress = { [weak self] in guard let self, let selected = self.selected else { return }; self.lastField.value = selected.position; self.refresh() }
        done.onPress = { [weak self] in self?.dismiss() }
        copyRange.onPress = { [weak self] in guard let self else { return }; self.copy(first: self.firstField.value, last: self.lastField.value) }
        copyAll.onPress = { [weak self] in guard let self else { return }; self.copy(first: 1, last: self.result.total) }
        exportButton.onPress = { [weak self] in self?.export() }
        exportButton.toolTip = "Save the whole retained conversation as a Markdown text file"
        list.spacing = 2; list.insets = NSEdgeInsets(top: PiSpacing.sm, left: PiSpacing.sm, bottom: PiSpacing.sm, right: PiSpacing.sm)
        list.setAccessibilityLabel("Retained conversation search results")
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { Self.size }
    override func layout() { super.layout(); sheet.frame = bounds }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !started { work.resume(); started = true; search() }
        else if window == nil { prepareForRelease() }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil, window != nil { prepareForRelease() }; super.viewWillMove(toWindow: newWindow) }
    func prepareForRelease() {
        work.cancel(); started = false; busy = false; dismiss = {}
        result = ContentSearch(hits: [], total: 0, next: nil, revision: ""); selectedID = nil; refresh()
    }
    private func refresh() {
        let enabled = work.isActive && !busy && inheritedEnabled
        searchButton.isEnabled = enabled && queryField.text.count <= 256
        next.isEnabled = enabled && result.next != nil; reveal.isEnabled = enabled && selected != nil
        startSelection.isEnabled = enabled && selected != nil; endSelection.isEnabled = enabled && selected != nil
        done.isEnabled = enabled; exportButton.isEnabled = enabled && result.total > 0
        copyRange.isEnabled = enabled && firstField.value >= 1 && lastField.value >= firstField.value && lastField.value <= result.total
        copyAll.isEnabled = enabled && result.total > 0
        queryField.field.isEnabled = work.isActive && inheritedEnabled; firstField.field.isEnabled = work.isActive && inheritedEnabled; lastField.field.isEnabled = work.isActive && inheritedEnabled
        spinner.isHidden = !busy; sheet?.cancelDisabled = busy || !inheritedEnabled || !work.isActive
        count.line.text = "\(result.hits.count) matches on this page · \(result.total) retained messages"
        empty.line.text = busy ? "Searching…" : "No matches on this page"; empty.isHidden = !result.hits.isEmpty
        status.isHidden = status.text.isEmpty
        let hits = result.hits
        let source = LazyStackView.Source(count: hits.count, key: { hits[$0].id }, height: { index, width in ConversationHitRow.height(hits[index], width: width) }, view: { [weak self] index, existing in
            guard let self else { return NSView() }; let hit = hits[index]
            let cell = (existing as? ConversationHitRow).flatMap { $0.hit.preview == hit.preview && $0.hit.position == hit.position ? $0 : nil }
                ?? ConversationHitRow(hit: hit, glide: self.glide) { [weak self] in self?.selectedID = hit.id; self?.refresh() }
            cell.row.selected = hit.id == self.selectedID; return cell
        })
        list.reload(source)
        column.needsLayout = true; sheet?.needsLayout = true
    }
    private func search(_ text: String? = nil, start: Int = 0) {
        guard work.isActive, !busy, inheritedEnabled else { return }; busy = true
        let text = text ?? queryField.text, source = source
        work.run({ try await source.search(text, start) }) { [weak self] outcome in
            guard let self else { return }; defer { self.busy = false }
            switch outcome {
            case .success(let found):
                if self.result.revision.isEmpty { self.lastField.value = max(1, found.total) }
                self.result = found; self.searched = text; self.selectedID = nil; self.status.text = ""
            case .failure(let error): self.status.text = error.localizedDescription
            }
        }
    }
    private func showSelected() {
        guard work.isActive, !busy, let selected else { return }; busy = true
        let source = source
        work.run({ try await source.reveal(selected) }) { [weak self] outcome in
            guard let self else { return }; defer { self.busy = false }
            switch outcome { case .success: self.dismiss(); case .failure(let error): self.status.text = error.localizedDescription }
        }
    }
    private static func collect(source: ConversationContentSource, revision: String, first: Int, last: Int, limit: Int, failure: String) async throws -> Data {
        var bytes = Data(), cursor: ContentCursor? = .init(index: first, offset: 0)
        while let next = cursor {
            try Task.checkCancellation()
            let page = try await source.page(first, last, next, revision)
            guard bytes.count + page.text.utf8.count <= limit else { throw HostError.failure(failure) }
            bytes.append(contentsOf: page.text.utf8); cursor = page.next
        }
        try Task.checkCancellation(); return bytes
    }
    private func copy(first: Int, last: Int) {
        guard work.isActive, !busy, inheritedEnabled else { return }; busy = true; status.text = "Reading retained text…"
        let source = source, revision = result.revision
        work.run({ try await Self.collect(source: source, revision: revision, first: first, last: last, limit: 8 * 1024 * 1024, failure: "This copy exceeds 8 MiB. Choose a smaller message range. The clipboard was not changed.") }) { [weak self] outcome in
            guard let self else { return }; defer { self.busy = false }
            switch outcome {
            case .success(let bytes):
                guard let text = String(data: bytes, encoding: .utf8) else { self.status.text = StoreError.invalidRecord.localizedDescription; return }
                self.pasteboard.clearContents(); self.pasteboard.setString(text, forType: .string)
                self.status.text = "Copied messages \(first)–\(last) (\(bytes.count) UTF-8 bytes)."
            case .failure(let error): self.status.text = error.localizedDescription
            }
        }
    }
    private func export() {
        guard work.isActive, !busy, inheritedEnabled, result.total > 0 else { return }
        let panel = NSSavePanel(); panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.nameFieldStringValue = (model.record(sessionID)?.title ?? "Conversation").replacingOccurrences(of: "/", with: "-") + ".md"
        panel.message = "Save the retained conversation as Markdown text."
        let source = source, revision = result.revision, total = result.total, window = window
        busy = true
        work.run({ [weak window] in
            guard let url = await PiQuestion.shared.save(panel, over: window) else { return nil as (URL, Data)? }
            try Task.checkCancellation()
            let bytes = try await Self.collect(source: source, revision: revision, first: 1, last: total, limit: 64 * 1024 * 1024, failure: "This conversation exceeds 64 MiB. Copy explicit ranges instead. No file was written.")
            return (url, bytes)
        }) { [weak self] outcome in
            guard let self else { return }; defer { self.busy = false }
            switch outcome {
            case .success(let value):
                guard let (url, bytes) = value else { return }
                do { try bytes.write(to: url, options: .atomic); self.status.text = "Exported \(total) messages (\(bytes.count) UTF-8 bytes) to \(url.lastPathComponent)." }
                catch { self.status.text = error.localizedDescription }
            case .failure(let error): self.status.text = error.localizedDescription
            }
        }
    }
}

@MainActor private final class ConversationHitRow: DashView {
    let hit: ContentHit
    let row: PiKit.SelectableRow
    init(hit: ContentHit, glide: PiKit.SelectionGlide, action: @escaping () -> Void) {
        self.hit = hit
        let position = ShellStack(.horizontal, spacing: 0, [.spacer(0), .view(PiKit.TextLine(PiKit.Line("\(hit.position)", font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInkTertiary)))])
        let preview = ShellText(hit.preview, font: PiKit.Font.body, color: .piInk, maximumLines: 3)
        row = PiKit.SelectableRow(content: ShellStack(.horizontal, spacing: PiSpacing.md, alignment: .top, [.view(position, .fixed(44)), .view(preview, .fill)]), glide: glide, action: action)
        super.init(frame: .zero); addSubview(row)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    static func height(_ hit: ContentHit, width: CGFloat) -> CGFloat {
        let text = min(3, max(1, ShellWrap.ranges(hit.preview, font: PiKit.Font.body, width: max(0, width - 20 - 44 - PiSpacing.md)).count))
        return max(PiKit.Line("1", font: PiKit.Font.caption, color: .piInk).lineHeight, CGFloat(text) * PiKit.Line("Ag", font: PiKit.Font.body, color: .piInk).lineHeight) + 16
    }
    override func layout() { super.layout(); row.frame = bounds }
}

@MainActor final class PayloadEmptyOverlay: DashView {
    let content: NSView, empty: NSView
    init(content: NSView, empty: NSView) { self.content = content; self.empty = empty; super.init(frame: .zero); addSubview(content); addSubview(empty) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override func layout() {
        super.layout(); content.frame = bounds
        let size = shellNaturalSize(empty)
        empty.frame = CGRect(x: max(0, PiKit.round((bounds.width - size.width) / 2, piScale)), y: max(0, PiKit.round((bounds.height - size.height) / 2, piScale)), width: min(bounds.width, size.width), height: size.height)
    }
}
