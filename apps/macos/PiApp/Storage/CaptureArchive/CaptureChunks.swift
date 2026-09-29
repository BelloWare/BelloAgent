import Foundation
import CryptoKit

// Boundaries depend on content, never on HTTP/TLS/IPC packet boundaries.
// Gear v1: 2 KiB minimum, ~8 KiB mask, 32 KiB maximum, no delta chains.
struct CaptureChunker: Sendable {
    static let minimum = 2_048, maximum = 32_768
    private static let gear: [UInt64] = (0..<256).map { index in
        var value = UInt64(index) &+ 0x9e3779b97f4a7c15
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
    private var rolling: UInt64 = 0
    private var pending = Data()
    mutating func feed(_ data: Data) -> [Data] {
        var chunks: [Data] = []
        for byte in data {
            pending.append(byte); rolling = (rolling << 1) &+ Self.gear[Int(byte)]
            if pending.count >= Self.maximum || pending.count >= Self.minimum && rolling & 8191 == 0 {
                chunks.append(pending); pending = Data(); rolling = 0
            }
        }
        return chunks
    }
    mutating func finish() -> Data { defer { pending = Data(); rolling = 0 }; return pending }
}

enum CaptureStorageFormat: String, Sendable {
    case plaintext = "plaintext-v2"
    case legacyEncrypted = "aes-gcm-v1"
}

// New captures require no encryption key. Session scoping preserves the
// existing sharing/deletion boundary without claiming ciphertext privacy.
enum CaptureContent {
    static func scope(session: String) -> String { hex(SHA256.hash(data: Data(("pi-capture-scope-v2:" + session).utf8))) }
    static func chunkID(_ data: Data, scope: String) -> String {
        var hash = SHA256(); hash.update(data: Data(("pi-capture-chunk-v2:" + scope + ":").utf8)); hash.update(data: data)
        return hex(hash.finalize())
    }
    static func hex<T: Sequence>(_ bytes: T) -> String where T.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }
}

// Read-only compatibility for archives created before plaintext-v2. The
// original native-vault key is retained; new payloads never use AES-GCM.
struct LegacyCaptureCipher: Sendable {
    private let bytes: Data
    private var key: SymmetricKey { SymmetricKey(data: bytes) }
    init(key: Data) throws { guard key.count == 32 else { throw CaptureFailure.unavailable }; bytes = key }
    func chunkID(_ data: Data, scope: String) -> String {
        let scoped = SymmetricKey(data: HMAC<SHA256>.authenticationCode(for: Data(scope.utf8), using: key))
        return CaptureContent.hex(HMAC<SHA256>.authenticationCode(for: data, using: scoped))
    }
    func open(_ data: Data, context: String) throws -> Data {
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data(("pi-capture-v1:" + context).utf8)) }
        catch { throw CaptureFailure.corrupt }
    }
}
