import SwiftUI
import AppKit

struct PayloadSearchResult: Sendable {
    let id = UUID()
    let text: String
    let matches: [NSRange]
    let limited: Bool

    /// Scan the complete retained representation, including closed JSON
    /// children. The bounded match index avoids one allocation per byte for a
    /// common one-character query; rare matches at the end are still found.
    static func find(text: String, query: String, limit: Int = 10_000) throws -> Self {
        guard !query.isEmpty else { return Self(text: text, matches: [], limited: false) }
        let source = text as NSString
        var offset = 0, matches: [NSRange] = []
        while offset < source.length {
            if matches.count.isMultiple(of: 128) { try Task.checkCancellation() }
            let range = source.range(of: query, options: [.caseInsensitive], range: NSRange(location: offset, length: source.length - offset))
            guard range.location != NSNotFound, range.length > 0 else { break }
            if matches.count >= limit { return Self(text: text, matches: matches, limited: true) }
            matches.append(range); offset = NSMaxRange(range)
        }
        return Self(text: text, matches: matches, limited: false)
    }
}

@MainActor final class PayloadSearchController: ObservableObject {
    @Published private(set) var result: PayloadSearchResult?
    @Published private(set) var loading = false
    @Published private(set) var notice = ""
    @Published var selected = 0
    private var generation = 0
    private var query = ""
    private var format: CapturedBodyFormat?
    private var kind = ""

    func search(document: CapturedBodyDocument?, format: CapturedBodyFormat, headers: [String: WireValue], kind: String, query: String) async {
        generation += 1; let revision = generation
        let preserving = self.query == query && self.format == format && self.kind == kind
        let previousSelection = preserving ? selected : 0
        self.query = query; self.format = format; self.kind = kind
        loading = true; notice = ""
        if !preserving { result = nil }
        do {
            // Typing never reparses a tree or reads SQLite. Rendering and
            // matching run on the bounded payload worker after a short debounce.
            try await Task.sleep(for: .milliseconds(180))
            let value = try await CapturedBodyWorker.shared.run {
                let header = headers.keys.sorted().map { "\($0): \(headers[$0]?.string ?? headers[$0]?.pretty ?? "")" }.joined(separator: "\n")
                let body: String
                if let document {
                    if let structured = document.structured(format: format) { body = try structured.render() }
                    else if format == .hex { body = try CapturedBodyHex.render(document.bytes) }
                    else { body = String(decoding: document.bytes, as: UTF8.self) }
                } else { body = "Body unavailable or still loading." }
                let text = kind.capitalized + " headers\n" + (header.isEmpty ? "No headers recorded" : header)
                    + "\n\n" + kind.capitalized + " body\n" + body
                return try PayloadSearchResult.find(text: text, query: query)
            }
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
    func cancel() { generation += 1; loading = false; result = nil }
}

/// Native selectable, wrapping text with match navigation. No SwiftUI row per
/// result and no rebuilding attributed strings on every frame or clock tick.
struct PayloadSearchTextView: NSViewRepresentable {
    let result: PayloadSearchResult
    let selected: Int
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let editor = NSTextView()
        editor.isEditable = false; editor.isSelectable = true; editor.isRichText = false; editor.drawsBackground = false
        editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular); editor.textColor = .labelColor
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true; editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.layoutManager?.allowsNonContiguousLayout = true
        editor.setAccessibilityLabel("Search results in complete body and headers")
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        if coordinator.id != result.id {
            coordinator.id = result.id; coordinator.selected = nil
            editor.string = result.text
            for range in result.matches {
                editor.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.25), forCharacterRange: range)
            }
        }
        guard coordinator.selected != selected, result.matches.indices.contains(selected) else { return }
        coordinator.selected = selected
        let range = result.matches[selected]
        editor.setSelectedRange(range)
        editor.scrollRangeToVisible(range)
    }
    @MainActor final class Coordinator { var id: UUID?; var selected: Int? }
}
