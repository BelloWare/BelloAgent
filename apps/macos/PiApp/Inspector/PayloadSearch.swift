import Combine
import AppKit

struct PayloadSearchResult: Sendable {
    let id = UUID()
    /// The searched text's identity: a refined query over the same text keeps it.
    var textID = UUID()
    let text: String
    let matches: [NSRange]
    let limited: Bool

    /// Scan the complete retained representation, including closed JSON
    /// children. The bounded match index avoids one allocation per byte for a
    /// common one-character query; rare matches at the end are still found.
    static func find(text: String, query: String, limit: Int = 10_000, textID: UUID = UUID()) throws -> Self {
        guard !query.isEmpty else { return Self(textID: textID, text: text, matches: [], limited: false) }
        let source = text as NSString
        var offset = 0, matches: [NSRange] = []
        while offset < source.length {
            if matches.count.isMultiple(of: 128) { try Task.checkCancellation() }
            let range = source.range(of: query, options: [.caseInsensitive], range: NSRange(location: offset, length: source.length - offset))
            guard range.location != NSNotFound, range.length > 0 else { break }
            if matches.count >= limit { return Self(textID: textID, text: text, matches: matches, limited: true) }
            matches.append(range); offset = NSMaxRange(range)
        }
        return Self(textID: textID, text: text, matches: matches, limited: false)
    }
}

@MainActor final class PayloadSearchController: ObservableObject {
    @Published private(set) var result: PayloadSearchResult?
    @Published private(set) var loading = false
    @Published private(set) var notice = ""
    @Published var selected = 0
    /// Test seam: how many times the searched text was rendered.
    private(set) var renders = 0
    private var generation = 0
    private var query = ""
    private var format: CapturedBodyFormat?
    private var kind = ""
    /// What the searched text was rendered from. The text does not depend on
    /// the query, so refining a query only matches again.
    private struct Source: Equatable {
        let document: UUID?
        let format: CapturedBodyFormat
        let kind: String
        let headers: [String: WireValue]
    }
    private var rendered: (source: Source, id: UUID, text: String)?

    func search(document: CapturedBodyDocument?, format: CapturedBodyFormat, headers: [String: WireValue], kind: String, query: String) async {
        generation += 1; let revision = generation
        let preserving = self.query == query && self.format == format && self.kind == kind
        let previousSelection = preserving ? selected : 0
        self.query = query; self.format = format; self.kind = kind
        // The previous results stay on screen, marked "Updating…", until
        // these replace them: clearing them tore down the text view per key.
        loading = true; notice = ""
        do {
            // Typing never reparses a tree or reads SQLite. Rendering and
            // matching run on the bounded payload worker after a short debounce.
            try await Task.sleep(for: .milliseconds(180))
            let source = Source(document: document?.id, format: format, kind: kind, headers: headers)
            let text: String, textID: UUID
            if let rendered, rendered.source == source { text = rendered.text; textID = rendered.id }
            else {
                text = try await CapturedBodyWorker.shared.run {
                    let header = headers.keys.sorted().map { "\($0): \(headers[$0]?.string ?? headers[$0]?.pretty ?? "")" }.joined(separator: "\n")
                    let body: String
                    if let document {
                        if let structured = document.structured(format: format) { body = try structured.render() }
                        else if format == .hex { body = try CapturedBodyHex.render(document.bytes) }
                        else { body = String(decoding: document.bytes, as: UTF8.self) }
                    } else { body = "Body unavailable or still loading." }
                    return kind.capitalized + " headers\n" + (header.isEmpty ? "No headers recorded" : header)
                        + "\n\n" + kind.capitalized + " body\n" + body
                }
                renders += 1
                guard !Task.isCancelled, revision == generation else { return }
                textID = UUID(); rendered = (source, textID, text)
            }
            let value = try await CapturedBodyWorker.shared.run { try PayloadSearchResult.find(text: text, query: query, textID: textID) }
            guard !Task.isCancelled, revision == generation else { return }
            result = value; selected = min(previousSelection, max(0, value.matches.count - 1)); loading = false
        } catch {
            guard revision == generation else { return }
            loading = false
            if !(error is CancellationError) { notice = error.localizedDescription }
        }
    }
    func move(_ delta: Int) {
        guard let result, !result.matches.isEmpty else { return }
        selected = (selected + delta + result.matches.count) % result.matches.count
    }
    /// The search ended: its results and the rendered text are released.
    func cancel() { generation += 1; loading = false; result = nil; rendered = nil }
}

/// Native selectable, wrapping text with match navigation. No SwiftUI row per
/// result and no rebuilding attributed strings on every frame or clock tick.
@MainActor final class PayloadSearchTextView: NSScrollView {
    let editor = NSTextView()
    private var id: UUID?, textID: UUID?, selected: Int?
    private var pendingScroll: NSRange?
    init(result: PayloadSearchResult, selected: Int) {
        super.init(frame: .zero)
        hasVerticalScroller = true; autohidesScrollers = true; drawsBackground = false
        editor.isEditable = false; editor.isSelectable = true; editor.isRichText = false; editor.drawsBackground = false
        editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular); editor.textColor = .labelColor
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true; editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.layoutManager?.allowsNonContiguousLayout = true
        editor.setAccessibilityLabel("Search results in complete body and headers")
        documentView = editor
        update(result: result, selected: selected)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override func layout() {
        super.layout()
        scrollToPendingMatch()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, pendingScroll != nil { needsLayout = true }
    }
    private func scrollToPendingMatch() {
        guard let range = pendingScroll, window != nil,
              contentView.bounds.width > 0, contentView.bounds.height > 0 else { return }
        pendingScroll = nil
        // Realize the selected match, leaving a large body's other text to
        // noncontiguous layout instead of laying out the whole container.
        if let manager = editor.layoutManager, let container = editor.textContainer {
            manager.ensureLayout(forCharacterRange: range)
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let glyph = manager.boundingRect(forGlyphRange: glyphs, in: container)
            let rect = contentView.convert(glyph.offsetBy(dx: editor.textContainerOrigin.x,
                                                         dy: editor.textContainerOrigin.y), from: editor)
            // Revealing an already visible first match can make AppKit
            // consume the leading text inset in an overflowing document.
            // Keep the viewport, and scroll only for a match outside it.
            if contentView.bounds.contains(rect) { return }
        }
        editor.scrollRangeToVisible(range)
    }
    func update(result: PayloadSearchResult, selected: Int) {
        if id != result.id {
            id = result.id; self.selected = nil; pendingScroll = nil
            if textID != result.textID {
                textID = result.textID
                editor.string = result.text
            } else {
                // A refined query changes only highlights, preserving the
                // same text storage and the reader's viewport.
                editor.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (editor.string as NSString).length))
            }
            for range in result.matches {
                editor.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.25), forCharacterRange: range)
            }
        }
        guard self.selected != selected, result.matches.indices.contains(selected) else { return }
        self.selected = selected
        let range = result.matches[selected]
        editor.setSelectedRange(range)
        // Selecting while the new reader has a zero-sized viewport can
        // scroll away its top inset before wrapping reaches its final width.
        // Keep selection immediate, and reveal it after the scroll view tiles.
        pendingScroll = range
        needsLayout = true
    }
}
