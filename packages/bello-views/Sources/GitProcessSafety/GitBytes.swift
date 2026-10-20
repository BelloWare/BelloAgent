import Foundation

/// Git syntax is delimited by ASCII bytes, not extended grapheme clusters.
/// Decode only after locating delimiters, so adjacent scalars stay intact.
public extension StringProtocol {
    func gitHasPrefix(_ prefix: String) -> Bool { utf8.starts(with: prefix.utf8) }
    func gitHasSuffix(_ suffix: String) -> Bool { utf8.suffix(suffix.utf8.count).elementsEqual(suffix.utf8) }
    func gitDropFirst(_ count: Int = 1) -> String { String(decoding: utf8.dropFirst(count), as: UTF8.self) }
    func gitDropLast(_ count: Int = 1) -> String { String(decoding: utf8.dropLast(count), as: UTF8.self) }
    func gitSplit(separator: UInt8, maxSplits: Int = .max, omittingEmptySubsequences: Bool = true) -> [String] {
        utf8.split(separator: separator, maxSplits: maxSplits, omittingEmptySubsequences: omittingEmptySubsequences)
            .map { String(decoding: $0, as: UTF8.self) }
    }
    func gitSplitOnce(separator: UInt8, last: Bool = false) -> (before: String, after: String)? {
        let bytes = String(self).utf8
        guard let index = last ? bytes.lastIndex(of: separator) : bytes.firstIndex(of: separator) else { return nil }
        return (String(decoding: bytes[..<index], as: UTF8.self),
                String(decoding: bytes[bytes.index(after: index)...], as: UTF8.self))
    }
    func gitContains(_ text: String) -> Bool { Data(utf8).range(of: Data(text.utf8)) != nil }
    func gitComponents(separatedBy separator: String) -> [String] {
        let bytes = Data(utf8), delimiter = Data(separator.utf8)
        guard !delimiter.isEmpty else { return [String(self)] }
        var result: [String] = [], start = bytes.startIndex
        while let range = bytes.range(of: delimiter, in: start..<bytes.endIndex) {
            result.append(String(decoding: bytes[start..<range.lowerBound], as: UTF8.self))
            start = range.upperBound
        }
        result.append(String(decoding: bytes[start...], as: UTF8.self))
        return result
    }
    func gitSplitWhitespace() -> [String] {
        utf8.split { $0 == 32 || (9...13).contains($0) }.map { String(decoding: $0, as: UTF8.self) }
    }
    func gitTrimmingWhitespace() -> String {
        let bytes = String(self).utf8
        let start = bytes.drop { $0 == 32 || (9...13).contains($0) }
        let end = start.reversed().drop { $0 == 32 || (9...13).contains($0) }
        return String(decoding: end.reversed(), as: UTF8.self)
    }
    var gitASCIILowercased: String {
        String(decoding: utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
    }
}
