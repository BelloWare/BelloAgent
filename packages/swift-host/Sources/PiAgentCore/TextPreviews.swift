import Foundation

// Bounded views of text: what a display row carries, what a frame may
// hold, and how a reader pages through the rest.

/// The text `next` adds to the end of `previous`, or nil when `next` is not
/// an extension of it. Byte-wise, so a grapheme that grew across a chunk
/// boundary is still recognised as an append rather than a rewrite.
func appendedText(_ previous: String, _ next: String) -> String? {
    let old = previous.utf8, new = next.utf8
    guard old.count <= new.count, new.prefix(old.count).elementsEqual(old) else { return nil }
    return old.count == new.count ? "" : String(decoding: new.dropFirst(old.count), as: UTF8.self)
}
func preview(_ s: String, bytes: Int = 16384) -> String { String(decoding: Array(s.utf8.prefix(bytes)), as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{fffd}")) }
/// A text preview whose JSON *encoding* fits `bytes`. Escaping inflates a
/// value up to six-fold (every control character becomes `\u00XX`), so a
/// source-byte preview is not a bound on what a protocol frame carries, and
/// the helper exits when a frame exceeds its 1 MiB limit.
func encodedPreview(_ s: String, bytes: Int) -> String {
    let direct = preview(s, bytes: bytes)
    if JSON(direct).encoded().utf8.count <= bytes { return direct }
    var low = 0, high = bytes, best = ""
    while low <= high {
        let middle = low + (high - low) / 2
        let candidate = preview(s, bytes: middle)
        if JSON(candidate).encoded().utf8.count <= bytes { best = candidate; low = middle + 1 } else { high = middle - 1 }
    }
    return best
}
func textPage(_ text: String, offset: Int, count: Int = 16_384) throws -> JSON {
    let ns = text as NSString
    guard offset >= 0, offset <= ns.length else { throw AgentError("invalid_range", "Text offset is outside the retained content") }
    if offset > 0, offset < ns.length, (0xDC00...0xDFFF).contains(ns.character(at: offset)) { throw AgentError("invalid_range", "Offset splits a Unicode character") }
    var end = min(ns.length, offset + count)
    if end < ns.length, end > offset, (0xD800...0xDBFF).contains(ns.character(at: end - 1)) { end -= 1 }
    return ["text": JSON(ns.substring(with: NSRange(location: offset, length: end - offset))), "offset": JSON(offset), "total": JSON(ns.length), "totalCharacters": JSON(ns.length), "next": end < ns.length ? JSON(end) : .null]
}
