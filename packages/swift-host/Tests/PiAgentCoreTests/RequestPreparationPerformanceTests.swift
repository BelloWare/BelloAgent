import XCTest
@testable import PiAgentCore

final class RequestPreparationPerformanceTests: XCTestCase {
    func testAcceleratedHashMatchesPortableIdentityAcrossPaddingAndLargeBuffers() {
        XCTAssertEqual(sha256(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(sha256(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        for count in [1, 55, 56, 63, 64, 65, 127, 128, 1_048_576] {
            let bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 * 131) })
            XCTAssertEqual(sha256(bytes), portableSHA256(bytes))
        }
    }
    func testRepeatedCountsRetainActualByteFingerprintAtLargeSizes() throws {
        let profile = try fixtureProfile()
        for mib in [1, 8, 32] {
            let messages = [ChatMessage(role: "user", content: [textBlock(String(repeating: "abc\n", count: mib * 262_144))])]
            let request = try ProviderClient.requestBody(profile: profile, messages: messages, instructions: "fixture", tools: [], sessionID: "perf")
            let counter = RequestContextCounter()
            let first = try counter.count(messages: messages, profile: profile)
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<3 {
                let repeated = try counter.count(messages: messages, profile: profile)
                XCTAssertEqual(repeated.tokens, first.tokens)
                XCTAssertEqual(repeated.requestTokens, first.requestTokens)
            }
            print("PERF repeated-context MiB=\(mib) meanMs=\((ProcessInfo.processInfo.systemUptime-start)*1000/3)")
            XCTAssertEqual(first.tokens, mib * 262_144, "four characters per token")
            XCTAssertEqual(try counter.count(messages: messages, profile: profile, request: request).requestFingerprint,
                           try RequestContextCounter.fingerprint(request, profile: profile))
        }
    }
}
