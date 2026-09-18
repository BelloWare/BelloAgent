import Foundation

enum UnicodePage {
    static func slice(_ text: NSString, offset: Int, limit: Int = 16_384) throws -> String {
        guard offset >= 0 else { throw StoreError.invalidRecord }
        let start = min(offset, text.length)
        if start > 0 && start < text.length && low(text.character(at: start)) && high(text.character(at: start - 1)) { throw HostError.failure("Offset is inside a Unicode codepoint") }
        var end = min(text.length, start + limit)
        if end < text.length && end > start && high(text.character(at: end - 1)) && low(text.character(at: end)) { end -= 1 }
        return text.substring(with: NSRange(location: start, length: end - start))
    }
    private static func high(_ x: unichar) -> Bool { (0xD800...0xDBFF).contains(x) }
    private static func low(_ x: unichar) -> Bool { (0xDC00...0xDFFF).contains(x) }
}
