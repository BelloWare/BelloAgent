import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

extension RequestContextCounter {
    /// Internal cache identity, never a wire-body fingerprint or an exported
    /// credential. Type/length framing and original UTF-8 avoid JSON escaping
    /// and canonical-Unicode equality on a cache hit. All profile/routing inputs
    /// participate. Only the small digest is retained, not another request body.
    static func cacheIdentity(request: JSON, profile: Profile) throws -> String {
        #if canImport(CryptoKit)
        var hash = SHA256()
        func byte(_ value: UInt8) { withUnsafeBytes(of: value) { hash.update(bufferPointer: $0) } }
        func integer(_ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { hash.update(bufferPointer: $0) } }
        func string(_ value: String) {
            var contiguous = value
            contiguous.withUTF8 { bytes in
                integer(UInt64(bytes.count)); hash.update(bufferPointer: UnsafeRawBufferPointer(bytes))
            }
        }
        func add(_ value: JSON) throws {
            try Task.checkCancellation()
            switch value {
            case .null: byte(0)
            case .bool(let value): byte(value ? 2 : 1)
            case .number(let value): byte(3); integer(value.bitPattern)
            case .string(let value): byte(4); string(value)
            case .array(let values):
                byte(5); integer(UInt64(values.count))
                for value in values { try add(value) }
            case .object(let values):
                byte(6); integer(UInt64(values.count))
                for key in values.keys.sorted() { string(key); try add(values[key]!) }
            }
        }
        byte(1) // Internal format revision. No on-disk cache uses it.
        try add(request); try add(profile.raw); string(profile.endpoint.absoluteString)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return try fingerprint(request, profile: profile)
        #endif
    }
}
