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
            let request: JSON = ["model": JSON(profile.model), "input": [["role": "user", "content": [["type": "input_text", "text": JSON(String(repeating: "abc\n", count: mib * 262_144))]]]], "instructions": "fixture"]
            var counter = RequestContextCounter()
            let first = try counter.count(request: request, profile: profile)
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<3 {
                let repeated = try counter.count(request: request, profile: profile)
                XCTAssertEqual(repeated.tokens, first.tokens)
                XCTAssertEqual(repeated.requestFingerprint, first.requestFingerprint)
            }
            print("PERF repeated-context MiB=\(mib) meanMs=\((ProcessInfo.processInfo.systemUptime-start)*1000/3)")
            XCTAssertEqual(first.requestFingerprint, try RequestContextCounter.fingerprint(request, profile: profile))
        }
    }
}
