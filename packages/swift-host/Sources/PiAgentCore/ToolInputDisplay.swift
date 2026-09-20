import Foundation

// How a tool call's arguments are cut down for display.

/// Display bounds for a tool call's arguments.
///
/// The arguments are a *document*, not prose: the transcript parses them to
/// show "Requested edit" with a diff. Cutting the encoded document at a byte
/// offset lands in the middle of a string value, so nothing parses and the
/// card degrades to raw JSON text for every edit over the bound. These bounds
/// cut long *string values* individually instead, each one carrying an
/// explicit marker with the number of omitted bytes, so the document always
/// parses and every key survives.
public enum ToolInputDisplay {
    /// What rides along on every display snapshot. The projection re-sends the
    /// whole page on each streamed delta and the transport kills the helper on
    /// a frame over 1 MiB, so the inline preview stays small; the full bounded
    /// document is fetched once, on demand, through `session.tool.input`.
    public static let inlineBytes = 4096
    /// The on-demand bound for tools whose arguments carry file content.
    public static let contentBytes = 65_536
    /// The on-demand bound for every other tool.
    public static let otherBytes = 8192
    /// Total input+output preview bytes retained across live tool states.
    static let retainedTotalBytes = 1_048_576
    /// Entries kept per object and elements per array, so even a pathological
    /// argument document has a bounded projection. The share scales with the
    /// bound: at 4 KiB a marker per entry would itself overflow the document.
    static let maximumEntries = 512
    static func entries(for limit: Int) -> Int { max(8, min(maximumEntries, limit / 64)) }
    /// Tool cards one projected assistant row shows, streamed or durable. A
    /// row is always admitted to a display page even when it is over the page
    /// budget, so its card count has to be bounded here or an oversized
    /// snapshot frame terminates the helper.
    public static let projectedCards = 32
    /// Prefix of every marker this type writes into a truncated value. The app
    /// may match on it to label a partial field.
    public static let truncationMarker = "\u{2026}[truncated,"
    static func marker(bytes: Int) -> String { "\(truncationMarker) \(bytes) more bytes]" }
    static func marker(elements: Int) -> String { "\(truncationMarker) \(elements) more elements]" }
    static func marker(keys: Int) -> String { "\(truncationMarker) \(keys) more keys]" }
    /// Tools whose arguments carry the file content the transcript renders as
    /// a diff. They get the large bound; everything else gets the small one.
    public static func bound(for name: String) -> Int {
        let n = name.lowercased()
        if ["edit","write","apply_patch","applypatch","multi_edit","multiedit","str_replace","str_replace_editor","create_file","notebook_edit","patch"].contains(n) { return contentBytes }
        if n.hasSuffix("_edit") || n.hasSuffix("_write") || n.hasSuffix("_patch") { return contentBytes }
        return otherBytes
    }
    /// The original document with every long string clamped once, so the
    /// search below re-renders a small tree instead of walking the original.
    private indirect enum Clamped {
        case leaf(JSON)
        case text(head: String, full: Int)
        case list([Clamped], omitted: Int)
        case map([(String, Clamped)], omitted: Int)
    }
    private static func clamp(_ value: JSON, to limit: Int) -> Clamped {
        let kept = entries(for: limit)
        switch value {
        case .string(let s):
            let count = s.utf8.count
            return .text(head: count > limit ? preview(s, bytes: limit) : s, full: count)
        case .array(let a):
            return .list(a.prefix(kept).map { clamp($0, to: limit) }, omitted: max(0, a.count - kept))
        case .object(let o):
            let keys = o.keys.sorted()
            return .map(keys.prefix(kept).map { ($0, clamp(o[$0] ?? .null, to: limit)) }, omitted: max(0, keys.count - kept))
        default: return .leaf(value)
        }
    }
    private static func render(_ node: Clamped, cap: Int) -> JSON {
        switch node {
        case .leaf(let value): return value
        case .text(let head, let full):
            if full <= cap { return .string(head) }
            let kept = preview(head, bytes: cap)
            return .string(kept + marker(bytes: full - kept.utf8.count))
        case .list(let items, let omitted):
            var out = items.map { render($0, cap: cap) }
            if omitted > 0 { out.append(.string(marker(elements: omitted))) }
            return .array(out)
        case .map(let entries, let omitted):
            var out: [String: JSON] = [:]
            for (key, value) in entries { out[key] = render(value, cap: cap) }
            if omitted > 0 { out[truncationMarker] = .string(marker(keys: omitted)) }
            return .object(out)
        }
    }
    /// The arguments encoded for display within `limit` bytes. The result is
    /// always a parseable JSON document: long string values are cut to the
    /// largest per-value length that fits and carry their omitted byte count.
    public static func bounded(_ arguments: JSON, limit: Int) -> (text: String, truncated: Bool, bytes: Int) {
        let full = arguments.encoded(), bytes = full.utf8.count
        guard bytes > limit else { return (full, false, bytes) }
        let tree = clamp(arguments, to: limit)
        var best = render(tree, cap: 0).encoded()
        // The document's own structure can exceed the bound on its own; there
        // is nothing further to cut without dropping the keys the app needs.
        guard best.utf8.count <= limit else { return (best, true, bytes) }
        var low = 1, high = limit
        while low <= high {
            let middle = low + (high - low) / 2
            let candidate = render(tree, cap: middle).encoded()
            if candidate.utf8.count <= limit { best = candidate; low = middle + 1 } else { high = middle - 1 }
        }
        return (best, true, bytes)
    }
}
/// The three display fields every tool card carries for its arguments:
/// a JSON-safe bounded document, whether that document is partial, and the
/// full encoded size of the arguments so the app can offer the full value.
func toolInputFields(_ arguments: JSON, limit: Int = ToolInputDisplay.inlineBytes) -> [(String, JSON)] {
    let bounded = ToolInputDisplay.bounded(arguments, limit: limit)
    return [("input", JSON(bounded.text)), ("inputTruncated", JSON(bounded.truncated)), ("inputBytes", JSON(bounded.bytes))]
}
func merging(_ value: JSON, _ fields: [(String, JSON)]) -> JSON {
    var result = value; for (key, item) in fields { result[key] = item }; return result
}
