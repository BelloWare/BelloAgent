import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Errors, request-parameter validation, path bounds and the content
// digest the rest of the helper is built on.

public struct AgentError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let failure: ProviderFailure?
    public let attemptID: String?
    /// What pi's provider would have reported for this failure, when it came
    /// from the gateway; pi's overflow and retry rules read it (`piMessage`).
    public let providerMessage: String?
    public init(_ code: String, _ message: String, failure: ProviderFailure? = nil, attemptID: String? = nil, providerMessage: String? = nil) { self.code = code; self.message = message; self.failure=failure; self.attemptID=attemptID; self.providerMessage=providerMessage }
    public var errorDescription: String? { message }
    public var json: JSON { ["code": JSON(code), "message": JSON(message)] }
}
func required(_ value: JSON, _ name: String, maximum: Int = 4096) throws -> String {
    guard let s = value.text, !s.isEmpty, s.utf8.count <= maximum else { throw AgentError("invalid_params", "Invalid \(name)") }
    return s
}
func identity(_ value: JSON) throws -> String {
    let s = try required(value, "identity", maximum: 128)
    guard s.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil, s != ".", s != ".." else { throw AgentError("invalid_identity", "Invalid identity") }
    return s
}
func boundedInt(_ value: JSON, fallback: Int = 0, maximum: Int = 1_000_000) throws -> Int {
    if value.isNull { return fallback }
    guard let n = value.int, n >= 0, n <= maximum else { throw AgentError("invalid_range", "Invalid numeric range") }; return n
}
func nowMS() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
func isoNow() -> String { ISO8601DateFormatter().string(from: Date()) }

func canonical(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath() }
func within(_ path: URL, _ root: URL) -> Bool { path.path == root.path || path.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") }
func readBounded(_ url: URL, maximum: Int) throws -> Data {
    // Nonblocking open and fstat reject FIFOs/devices without hanging discovery.
    let fd=open(url.path,O_RDONLY|O_NONBLOCK|O_CLOEXEC)
    guard fd>=0 else { throw AgentError("file_unavailable","Cannot open \(url.path)") }
    let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer { try? file.close() }
    var info=stat()
    guard fstat(fd,&info)==0, info.st_mode & mode_t(S_IFMT)==mode_t(S_IFREG) else { throw AgentError("not_regular_file","Only regular files can be read") }
    guard info.st_size<=maximum else { throw AgentError("file_too_large","File exceeds the supported size limit") }
    let bytes=try file.read(upToCount:maximum+1) ?? Data()
    guard bytes.count<=maximum else { throw AgentError("file_too_large","File exceeds the supported size limit") };return bytes
}

/// System-accelerated SHA-256 on macOS, with a dependency-free portable fallback.
/// Byte identities and on-disk formats remain identical; this is not encryption.
public func sha256(_ data: Data) -> String {
    #if canImport(CryptoKit)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    #else
    return portableSHA256(data)
    #endif
}

/// Kept available internally so Darwin tests compare both implementations at
/// padding boundaries and on large buffers before changing persisted identities.
func portableSHA256(_ data: Data) -> String {
    let k: [UInt32] = [0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
    var h: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
    var bytes = Array(data); let bits = UInt64(bytes.count) * 8
    bytes.append(0x80); while bytes.count % 64 != 56 { bytes.append(0) }
    for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
    func r(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    for start in stride(from: 0, to: bytes.count, by: 64) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 { let p = start + i * 4; w[i] = (UInt32(bytes[p]) << 24) | (UInt32(bytes[p+1]) << 16) | (UInt32(bytes[p+2]) << 8) | UInt32(bytes[p+3]) }
        for i in 16..<64 { let a = w[i-15], b = w[i-2]; w[i] = w[i-16] &+ (r(a,7) ^ r(a,18) ^ (a >> 3)) &+ w[i-7] &+ (r(b,17) ^ r(b,19) ^ (b >> 10)) }
        var a=h[0], b=h[1], c=h[2], d=h[3], e=h[4], f=h[5], g=h[6], z=h[7]
        for i in 0..<64 { let t = z &+ (r(e,6)^r(e,11)^r(e,25)) &+ ((e&f)^((~e)&g)) &+ k[i] &+ w[i]; let u = (r(a,2)^r(a,13)^r(a,22)) &+ ((a&b)^(a&c)^(b&c)); z=g; g=f; f=e; e=d &+ t; d=c; c=b; b=a; a=t &+ u }
        h = zip(h,[a,b,c,d,e,f,g,z]).map { $0 &+ $1 }
    }
    return h.map { String(format: "%08x", $0) }.joined()
}
