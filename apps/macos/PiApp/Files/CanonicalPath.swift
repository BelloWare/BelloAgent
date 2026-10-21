import Foundation

/// Whether one canonical path (`FileTab.key(for:)`, or a URL standardized and
/// resolved the same way) is in another: project ownership, a reply link's
/// project, the folder a file's history, blame or recents are read from.
/// The "/" is found as a byte, as the filesystem finds it. A "/" followed by
/// a combining mark, ZWJ or variation selector is one Character with it, so
/// `hasPrefix(root + "/")` missed the separator, and a file of an untrusted
/// nested project looked like its trusted parent's, or outside every project.
enum CanonicalPath {
    /// `path` below `root` ("" for `root` itself), every byte of its names
    /// kept; nil when `path` is not in `root`.
    static func relative(_ path: String, in root: String) -> String? {
        let bytes = Array(path.utf8), rootBytes = Array(root.utf8)
        if bytes == rootBytes { return "" }
        let base = rootBytes.last == UInt8(ascii: "/") ? rootBytes : rootBytes + [UInt8(ascii: "/")]
        if bytes.starts(with: base) { return String(decoding: bytes[base.count...], as: UTF8.self) }
        // A canonically equivalent spelling of `root`, which String
        // comparison found before, still counts.
        if path == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }
    /// Whether `path` is `root` or in it.
    static func isWithin(_ path: String, _ root: String) -> Bool { relative(path, in: root) != nil }
    /// Whether `path` is in `root`, not `root` itself.
    static func isBelow(_ path: String, _ root: String) -> Bool { relative(path, in: root)?.isEmpty == false }
}
