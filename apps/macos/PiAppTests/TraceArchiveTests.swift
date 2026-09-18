import XCTest
import CryptoKit
@testable import PiApp

final class TraceArchiveTests: XCTestCase {
    func testUnavailableLiveBodiesAreNotExportedAsEmptyOriginals() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TraceArchive(root: root)
        for state in ["credential-omitted", "not-captured", "not-retained", "unavailable", "purged", "expired", "complete"] {
            let emptyHash = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
            let metadata: [String: WireValue] = [
                "attemptId": .string(UUID().uuidString), "sessionId": .string("fixture"),
                "request": .object(["state": .string(state), "retainedBytes": .number(0), "observedBytes": .number(state == "complete" ? 0 : 100)]),
                "requestHash": state == "complete" ? .object(["sha256": .string(emptyHash)]) : .null,
                "requestFile": .string("request.bin"), "requestFileSHA256": .string(emptyHash)
            ]
            let saved = try await archive.persist(metadata, read: { _, _ in XCTFail("No body bytes are available"); return [:] }, verify: { metadata })
            let manifest = try JSONDecoder().decode([String: WireValue].self, from: Data(contentsOf: saved.appendingPathComponent("manifest.json")))
            XCTAssertEqual(FileManager.default.fileExists(atPath: saved.appendingPathComponent("request.bin").path), state == "complete", state)
            XCTAssertEqual(manifest["requestFile"] != nil, state == "complete", state)
            XCTAssertEqual(manifest["requestFileSHA256"] != nil, state == "complete", state)
            XCTAssertFalse(FileManager.default.fileExists(atPath: saved.appendingPathComponent("response.bin").path), "A missing descriptor is unavailable")
            XCTAssertNil(manifest["responseFile"])
            XCTAssertEqual(manifest["request"]?.object?["state"]?.string, state)
        }
    }
    func testRetainedBytesArePagedHashedPrivateAndClearedSeparatelyFromHistory() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TraceArchive(root: root), bytes = Data(repeating: 65, count: 65_537)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), id = UUID().uuidString
        let metadata: [String: WireValue] = ["attemptId": .string(id), "sessionId": .string("main"), "request": .object(["state": .string("complete"), "retainedBytes": .number(Double(bytes.count)), "observedBytes": .number(Double(bytes.count))]), "requestHash": .object(["sha256": .string(hash), "scope": .string("full")]), "response": .object(["state": .string("unavailable"), "retainedBytes": .number(0)])]
        let saved = try await archive.persist(metadata, read: { _, offset in .init(uniqueKeysWithValues: [("bytes", .string(bytes.subdata(in: offset..<min(offset + 32_768, bytes.count)).base64EncodedString())), ("retainedBytes", .number(Double(bytes.count)))]) }, verify: { metadata })
        XCTAssertEqual(try Data(contentsOf: saved.appendingPathComponent("request.bin")), bytes)
        let permissions = try FileManager.default.attributesOfItem(atPath: saved.appendingPathComponent("request.bin").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let list = try await archive.list(sessionID: "main"); XCTAssertEqual(list.count, 1)
        let page = try await archive.body(attemptID: id, body: "request", offset: 32_768); XCTAssertEqual(page.count, 32_768)
        try await archive.clear(sessionID: "side"); XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        try await archive.clear(sessionID: "main"); XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
    }
    func testQuotaAndDiskFailureDoNotPublishPartialOrFalselyCompleteArtifacts() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TraceArchive(root: root, budget: 20), id = UUID().uuidString
        let meta: [String: WireValue] = ["attemptId": .string(id), "request": .object(["retainedBytes": .number(100)])]
        do { _ = try await archive.persist(meta, read: { _, _ in XCTFail("Quota must be reserved before reading"); return [:] }, verify: { meta }); XCTFail("Expected quota error") } catch { }
        let larger = TraceArchive(root: root)
        do { _ = try await larger.persist(meta, read: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }, verify: { meta }); XCTFail("Expected disk failure") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 0)
    }
    @MainActor func testCapturePreferenceCanBeSetWithoutLaunchingAHostAndSurvivesModelReload() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = MemoryVaultStorage()
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: storage))
        try await model.setCaptureMode("off", sessionID: "chat")
        let next = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: storage))
        let preference = try await next.capturePreference(sessionID: "chat")
        XCTAssertEqual(preference.mode, "off"); XCTAssertFalse(next.hasActiveWork)
        try await model.setCaptureMode("persist", sessionID: "chat")
        try await next.reloadConfiguration()
        let persisted = try await next.capturePreference(sessionID: "chat")
        XCTAssertEqual(persisted.mode, "persist"); XCTAssertTrue(persisted.since.contains("."))
    }
    func testMetadataProfileUpgradeKeepsLegacyKeysAndDoesNotSerializeSecrets() throws {
        let old = Data("{\"id\":\"p\",\"revision\":\"r\",\"name\":\"Profile\",\"providerId\":\"fixture\",\"modelId\":\"alias\",\"api\":\"openai-responses\",\"baseUrl\":\"https://example.test/v1\",\"contextWindow\":128000,\"maxOutputTokens\":4096}".utf8)
        var profile = try JSONDecoder().decode(ProfileRecord.self, from: old)
        XCTAssertNil(profile.advancedJSON)
        profile.advancedJSON = "{\"reasoning\":true,\"thinkingLevel\":\"high\"}"
        XCTAssertEqual(profile.wire.object?["thinkingLevel"]?.string, "high")
        XCTAssertNil(profile.wire.object?["apiKey"])
    }
}
