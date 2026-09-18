import XCTest
import CryptoKit
@testable import PiApp

private final class ArchiveTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1000
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: time) }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; time += seconds }
}
private actor ExportLatch {
    var entered = false, released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func pause() async {
        guard !released else { return }; entered = true
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
private final class ArchiveMaintenanceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
    func read() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

final class PayloadArchiveTests: XCTestCase {
    private let key = Data(repeating: 0x5a, count: 32)
    private func root() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func fixture(_ count: Int) -> Data {
        var state: UInt64 = 0xabcde12345
        return Data((0..<count).map { _ in state ^= state << 13; state ^= state >> 7; state ^= state << 17; return UInt8(truncatingIfNeeded: state) })
    }
    private func metadata(id: String = UUID().uuidString, session: String = "session", mode: String = "persist", outcome: String = "running", observed: Int = 0) -> [String: WireValue] {
        ["attemptId": .string(id), "sessionId": .string(session), "turnId": .string("turn"), "purpose": .string("turn"), "api": .string("openai-responses"), "requestedModel": .string("auto-router"), "mode": .string(mode), "outcome": .string(outcome), "messageIds": .array([.string("input-message")]), "outputMessageIds": .array(outcome == "running" ? [] : [.string("output-message")]), "request": .object(["observedBytes": .number(Double(observed))]), "response": .object(["observedBytes": .number(0)])]
    }
    private func save(_ archive: PayloadArchive, bytes: Data, session: String = "session") async throws -> String {
        let id = UUID().uuidString
        try await archive.begin(metadata(id: id, session: session), workspace: "workspace")
        // Deliberately odd transfer pages to decouple network boundaries from chunks.
        for offset in stride(from: 0, to: bytes.count, by: 13_117) {
            try await archive.append(attempt: id, kind: "request", offset: offset, bytes: bytes.subdata(in: offset..<min(offset + 13_117, bytes.count)))
        }
        try await archive.finish(metadata(id: id, session: session, outcome: "completed", observed: bytes.count)); return id
    }
    private func read(_ archive: PayloadArchive, id: String, count: Int) async throws -> Data {
        var result = Data()
        while result.count < count { result.append(try await archive.body(attemptID: id, body: "request", offset: result.count)) }
        return result
    }
    func testSidebarPollingDoesNotSweepArchiveBeforeExpiryAndPolicyChangesApplyImmediately() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let clock = ArchiveTestClock(), passes = ArchiveMaintenanceCounter()
        let archive = PayloadArchive(root: folder, now: { clock.read() }, didReconcile: { passes.increment() })
        try await archive.configure(quota: 1_048_576, bodyRetention: 10, metricRetention: 100)
        let id = try await save(archive, bytes: Data("retained request".utf8))
        _ = try await archive.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: [])
        let initial = passes.read()
        for _ in 0..<100 {
            _ = try await archive.gatewayAccounting(sessionID: "session", workspaceID: "workspace", messages: [])
            _ = try await archive.list(sessionID: "session")
        }
        XCTAssertEqual(passes.read(), initial, "Every sidebar/report read must not trigger global retention and garbage collection")
        clock.advance(11)
        _ = try await archive.list(sessionID: "session")
        let expired = try await archive.metadata(attempt: id)
        XCTAssertEqual(expired["request"]?.object?["state"]?.string, "expired")
        XCTAssertEqual(expired["metricsRetained"]?.bool, true)
        XCTAssertEqual(passes.read(), initial + 1)
        try await archive.configure(quota: 1_048_576, bodyRetention: 10, metricRetention: 5)
        let metrics = try await archive.metadata(attempt: id)
        XCTAssertEqual(metrics["metricsRetained"]?.bool, false, "A shortened retention setting must invalidate the cached deadline")
        // Completing an old running request must also invalidate the deadline.
        var delayed = metadata()
        delayed["wallTimestamp"] = .number(900)
        try await archive.begin(delayed, workspace: "workspace")
        delayed["outcome"] = .string("failed")
        try await archive.finish(delayed)
        _ = try await archive.list(sessionID: "session")
        let delayedMetadata = try await archive.metadata(attempt: delayed["attemptId"]!.string!)
        XCTAssertEqual(delayedMetadata["metricsRetained"]?.bool, false)
        try await archive.close()
    }

    func testMaskedResponseRetainsExplicitTransformationThroughRestartExpiryAndExport() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let clock = ArchiveTestClock(), archive = PayloadArchive(root: folder, now: { clock.read() })
        try await archive.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 10)
        let id = UUID().uuidString, bytes = Data(#"{"error":"echo *************"}"#.utf8)
        let transformation = "Known authentication credential echoes masked with same-length asterisks"
        var entry = metadata(id: id)
        try await archive.begin(entry, workspace: "workspace")
        try await archive.append(attempt: id, kind: "response", offset: 0, bytes: bytes)
        entry["outcome"] = .string("failed"); entry["transportOutcome"] = .string("eof")
        entry["response"] = .object(["state": .string("credential-masked"), "observedBytes": .number(Double(bytes.count)), "captureBytes": .number(Double(bytes.count)), "credentialRedactions": .number(1), "byteExact": .bool(false), "transformations": .array([.string(transformation)])])
        try await archive.finish(entry); try await archive.close()
        try await archive.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 10)
        clock.advance(11); try await archive.reconcile()
        let retained = try await archive.metadata(attempt: id), response = try XCTUnwrap(retained["response"]?.object)
        XCTAssertEqual(retained["metricsRetained"]?.bool, false)
        XCTAssertEqual(response["state"]?.string, "credential-masked")
        XCTAssertEqual(response["byteExact"]?.bool, false)
        XCTAssertEqual(response["transformations"]?.array, [.string(transformation)])
        XCTAssertEqual(retained["responseHash"]?.object?["scope"]?.string, "retained credential-masked bytes")
        XCTAssertTrue(MessageBodyReader.canReadRetained("credential-masked"))
        let displayed = try await archive.completeBody(attemptID: id, body: "response")
        XCTAssertEqual(displayed, bytes)
        let exported = try await archive.exportRetained(sessionID: "session", attemptID: id, destination: folder)
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("response.bin")), bytes)
        let manifest = try JSONDecoder().decode([String: WireValue].self, from: Data(contentsOf: exported.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest["response"]?.object?["byteExact"], .bool(false))
        try await archive.close()
    }

    func testHTTPFinishedButUnconsumedResponseTailCannotBeMarkedComplete() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let archive = PayloadArchive(root: folder)
        try await archive.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 1000)
        let bytes = Data("observed prefix".utf8), id = UUID().uuidString
        var entry = metadata(id: id)
        try await archive.begin(entry, workspace: "workspace")
        try await archive.append(attempt: id, kind: "response", offset: 0, bytes: bytes)
        entry["outcome"] = .string("failed"); entry["transportOutcome"] = .string("eof")
        entry["response"] = .object(["state": .string("partial"), "observedBytes": .number(Double(bytes.count + 20)), "captureBytes": .number(Double(bytes.count)), "byteExact": .bool(true)])
        try await archive.finish(entry)
        let retained = try await archive.metadata(attempt: id)
        XCTAssertEqual(retained["response"]?.object?["state"]?.string, "partial")
        let prefix = try await archive.completeBody(attemptID: id, body: "response")
        XCTAssertEqual(prefix, bytes)
        try await archive.close()
    }
    func testCredentialOmittedBodyCannotBecomeAnEmptyCompleteCaptureOrExport() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let archive = PayloadArchive(root: folder)
        try await archive.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 604800)
        let id = UUID().uuidString
        var value = metadata(id: id, outcome: "completed", observed: 100_000)
        value["request"] = .object(["state": .string("credential-omitted"), "observedBytes": .number(100_000), "captureBytes": .number(0), "credentialRedactions": .number(65_536), "byteExact": .bool(false)])
        try await archive.begin(value, workspace: "workspace")
        try await archive.finish(value)
        let stored = try await archive.metadata(attempt: id)
        XCTAssertEqual(stored["request"]?.object?["state"]?.string, "credential-omitted")
        XCTAssertEqual(stored["request"]?.object?["observedBytes"]?.number, 100_000)
        XCTAssertEqual(stored["requestHash"], .null)
        do { _ = try await archive.body(attemptID: id, body: "request", offset: 0); XCTFail("An omitted body is unavailable, not an empty original") } catch { }
        let export = try await archive.exportRetained(sessionID: "session", attemptID: id, destination: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.appendingPathComponent("request.bin").path))
        try await archive.close()
        let reopened = PayloadArchive(root: folder)
        try await reopened.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 604800)
        let restored = try await reopened.metadata(attempt: id)
        XCTAssertEqual(restored["request"]?.object?["state"]?.string, "credential-omitted")
    }
    // This is the actual pre-change schema/crypto contract, constructed without
    // using the current writer. Migration must read it without rewriting bytes.
    private func legacyFixture(_ folder: URL, bytes: Data) throws -> (ids: [String], file: URL, encrypted: Data) {
        let symmetric = SymmetricKey(data: key)
        func seal(_ data: Data, context: String) throws -> Data {
            try XCTUnwrap(AES.GCM.seal(data, using: symmetric, authenticating: Data(("pi-capture-v1:" + context).utf8)).combined)
        }
        let scope = CaptureContent.hex(HMAC<SHA256>.authenticationCode(for: Data("scope-v1:session".utf8), using: symmetric))
        let scoped = SymmetricKey(data: HMAC<SHA256>.authenticationCode(for: Data(scope.utf8), using: symmetric))
        let chunk = CaptureContent.hex(HMAC<SHA256>.authenticationCode(for: bytes, using: scoped))
        let file = folder.appendingPathComponent("chunks/" + scope + "/" + chunk)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encrypted = try seal(bytes, context: scope + ":" + chunk)
        try encrypted.write(to: file)
        let db = try CaptureDatabase(url: folder.appendingPathComponent("requests.sqlite"))
        try db.execute("CREATE TABLE archive_info(name TEXT PRIMARY KEY,value BLOB NOT NULL)")
        try db.execute("INSERT INTO archive_info VALUES('key-check',?)", [.blob(try seal(Data("PiApp capture archive v1".utf8), context: "archive-key-check"))])
        try db.execute("CREATE TABLE attempts(id TEXT PRIMARY KEY,session TEXT NOT NULL,workspace TEXT NOT NULL,turn TEXT NOT NULL,purpose TEXT NOT NULL,api TEXT NOT NULL,alias TEXT NOT NULL,model TEXT,outcome TEXT NOT NULL,wall REAL NOT NULL,updated REAL NOT NULL,metadata BLOB NOT NULL,metrics_retained INTEGER NOT NULL DEFAULT 1)")
        try db.execute("CREATE TABLE bodies(attempt TEXT NOT NULL REFERENCES attempts(id) ON DELETE CASCADE,kind TEXT NOT NULL,state TEXT NOT NULL,reason TEXT,observed INTEGER NOT NULL DEFAULT 0,length INTEGER NOT NULL DEFAULT 0,digest BLOB,PRIMARY KEY(attempt,kind))")
        try db.execute("CREATE TABLE chunks(scope TEXT NOT NULL,id TEXT NOT NULL,length INTEGER NOT NULL,bytes INTEGER NOT NULL,PRIMARY KEY(scope,id))")
        try db.execute("CREATE TABLE refs(attempt TEXT NOT NULL,kind TEXT NOT NULL,ordinal INTEGER NOT NULL,scope TEXT NOT NULL,chunk TEXT NOT NULL,offset INTEGER NOT NULL,length INTEGER NOT NULL,PRIMARY KEY(attempt,kind,ordinal),FOREIGN KEY(attempt,kind) REFERENCES bodies(attempt,kind) ON DELETE CASCADE,FOREIGN KEY(scope,chunk) REFERENCES chunks(scope,id))")
        try db.execute("INSERT INTO chunks VALUES(?,?,?,?)", [.text(scope), .text(chunk), .integer(Int64(bytes.count)), .integer(Int64(encrypted.count))])
        let ids = [UUID().uuidString, UUID().uuidString]
        for id in ids {
            let data = try JSONEncoder().encode(metadata(id: id, outcome: "completed", observed: bytes.count))
            try db.execute("INSERT INTO attempts VALUES(?,'session','workspace','turn','turn','openai-responses','auto-router',NULL,'completed',?,?,?,1)", [.text(id), .real(Date().timeIntervalSince1970), .real(Date().timeIntervalSince1970), .blob(data)])
            try db.execute("INSERT INTO bodies VALUES(?,'request','complete','',?,?,?)", [.text(id), .integer(Int64(bytes.count)), .integer(Int64(bytes.count)), .blob(try seal(Data(SHA256.hash(data: bytes)), context: id + ":request"))])
            try db.execute("INSERT INTO bodies VALUES(?,'response','complete','',0,0,?)", [.text(id), .blob(try seal(Data(SHA256.hash(data: Data())), context: id + ":response"))])
            try db.execute("INSERT INTO refs VALUES(?,'request',0,?,?,0,?)", [.text(id), .text(scope), .text(chunk), .integer(Int64(bytes.count))])
        }
        try db.execute("PRAGMA user_version=4")
        return (ids, file, encrypted)
    }
    func testLegacyEncryptedHistoryRemainsReadableAlongsideNewPlaintextAndRequiresOriginalKey() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data("legacy exact body 🧪\0".utf8), legacy = try legacyFixture(folder, bytes: bytes)
        let archive = PayloadArchive(root: folder)
        do { try await archive.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 604800); XCTFail("Legacy key required") }
        catch { guard case CaptureFailure.legacyKeyUnavailable = error else { return XCTFail("Wrong legacy-key error: \(error)") } }
        do { try await archive.configure(key: Data(repeating: 9, count: 32), quota: 1_048_576, bodyRetention: 86400, metricRetention: 604800); XCTFail("Wrong key must not replace history") }
        catch { XCTAssertTrue(error is CaptureFailure) }
        XCTAssertEqual(try Data(contentsOf: legacy.file), legacy.encrypted)
        try await archive.configure(key: key, quota: 1_048_576, bodyRetention: 86400, metricRetention: 604800)
        let original = try await read(archive, id: legacy.ids[0], count: bytes.count); XCTAssertEqual(original, bytes)
        let oldMetadata = try await archive.metadata(attempt: legacy.ids[0])
        XCTAssertEqual(oldMetadata["storageVersion"]?.number, 5)
        XCTAssertEqual(oldMetadata["request"]?.object?["storage"]?.string, "aes-gcm-v1")
        let fresh = try await save(archive, bytes: bytes)
        let freshMetadata = try await archive.metadata(attempt: fresh)
        XCTAssertEqual(freshMetadata["request"]?.object?["storage"]?.string, "plaintext-v2")
        XCTAssertEqual(try Data(contentsOf: legacy.file), legacy.encrypted, "Opening and writing v2 never rewrites old ciphertext")
        let exported = try await archive.exportRetained(sessionID: "session", attemptID: legacy.ids[0], destination: folder)
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("request.bin")), bytes)
        try await archive.purge(attemptID: legacy.ids[0])
        let shared = try await read(archive, id: legacy.ids[1], count: bytes.count); XCTAssertEqual(shared, bytes)
        try await archive.purge(attemptID: legacy.ids[1]); try await archive.close()
        try await archive.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 604800)
        let remaining = try await read(archive, id: fresh, count: bytes.count); XCTAssertEqual(remaining, bytes)
        let stats = try await archive.statistics(); XCTAssertEqual(stats["legacyEncryptedBytes"], 0)
    }
    func testCredentialHashedRequestPreservesTransformationAndWireLengthAcrossRestartAndExport() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let clock = ArchiveTestClock(), archive = PayloadArchive(root: folder, now: { clock.read() }), id = UUID().uuidString
        try await archive.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 10)
        let key = "synthetic-key", marker = "[sha256:" + CaptureContent.hex(SHA256.hash(data: Data(key.utf8))) + "]"
        let wire = Data(("{\"text\":\"" + key + "\"}").utf8), retained = Data(("{\"text\":\"" + marker + "\"}").utf8)
        var entry = metadata(id: id, observed: wire.count)
        let transformation = "Known authentication credential bytes replaced by SHA-256 hashes"
        entry["request"] = .object(["observedBytes": .number(Double(wire.count)), "captureBytes": .number(Double(retained.count)), "credentialRedactions": .number(1), "byteExact": .bool(false), "transformations": .array([.string(transformation)])])
        try await archive.begin(entry, workspace: "workspace")
        try await archive.append(attempt: id, kind: "request", offset: 0, bytes: retained)
        entry["outcome"] = .string("completed"); try await archive.finish(entry); try await archive.close()
        try await archive.configure(quota: 1_048_576, bodyRetention: 100, metricRetention: 10)
        clock.advance(11); try await archive.reconcile()
        let descriptor = try await archive.metadata(attempt: id), request = try XCTUnwrap(descriptor["request"]?.object)
        XCTAssertEqual(descriptor["metricsRetained"]?.bool, false)
        XCTAssertEqual(request["state"]?.string, "credential-hashed")
        XCTAssertEqual(request["observedBytes"]?.number, Double(wire.count)); XCTAssertEqual(request["retainedBytes"]?.number, Double(retained.count))
        XCTAssertEqual(request["byteExact"]?.bool, false); XCTAssertEqual(request["transformations"]?.array, [.string(transformation)])
        XCTAssertEqual(descriptor["requestHash"]?.object?["scope"]?.string, "retained credential-hashed bytes")
        let exported = try await archive.exportRetained(sessionID: "session", attemptID: id, destination: folder)
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("request.bin")), retained)
        XCTAssertFalse(try String(contentsOf: exported.appendingPathComponent("manifest.json")).contains(key))
    }
    func testContentBoundariesSurviveArbitraryPacketsShiftedPrefixesAndOneByteChange() throws {
        let bytes = fixture(524_288)
        var whole = CaptureChunker(), split = CaptureChunker()
        let expected = whole.feed(bytes) + [whole.finish()]
        var actual: [Data] = []
        for offset in stride(from: 0, to: bytes.count, by: 137) { actual += split.feed(bytes.subdata(in: offset..<min(offset + 137, bytes.count))) }
        actual.append(split.finish()); XCTAssertEqual(actual, expected); XCTAssertEqual(actual.reduce(Data(), +), bytes)
        var changed = bytes; changed[21_500] ^= 1; changed.insert(contentsOf: "shifted prefix 🧪\0".utf8, at: 0)
        var shifted = CaptureChunker(); let chunks = shifted.feed(changed) + [shifted.finish()]
        let originals = Set(expected)
        XCTAssertGreaterThan(chunks.filter { originals.contains($0) }.reduce(0) { $0 + $1.count }, bytes.count * 3 / 4)
    }
    func testInheritedSideMessagesFindParentOriginAndChildRequestsOnlyWithinTheirWorkspace() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let archive = PayloadArchive(root: folder), bytes = Data("original parent response".utf8), parentID = UUID().uuidString
        try await archive.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 604800)
        var parent = metadata(id: parentID, session: "parent")
        parent["messageIds"] = .array([])
        try await archive.begin(parent, workspace: "workspace")
        try await archive.append(attempt: parentID, kind: "response", offset: 0, bytes: bytes)
        parent["outcome"] = .string("completed"); parent["outputMessageIds"] = .array([.string("inherited-message")])
        parent["response"] = .object(["observedBytes": .number(Double(bytes.count))])
        try await archive.finish(parent)
        var unrelated = metadata(session: "unrelated-session", mode: "off", outcome: "completed")
        unrelated["messageIds"] = .array([.string("inherited-message")])
        try await archive.begin(unrelated, workspace: "unrelated-workspace"); try await archive.finish(unrelated)

        // A freshly opened side has no native archive attempt of its own.
        let untouchedSide = try await archive.list(sessionID: "new-side", messageID: "inherited-message", workspaceID: "workspace")
        XCTAssertEqual(untouchedSide.compactMap { $0["attemptId"]?.string }, [parentID])
        let normalEmptyList = try await archive.list(sessionID: "new-side", workspaceID: "workspace")
        XCTAssertTrue(normalEmptyList.isEmpty, "Normal request lists must remain session-specific")

        let childID = UUID().uuidString
        var child = metadata(id: childID, session: "new-side", mode: "off", outcome: "completed")
        child["messageIds"] = .array([.string("inherited-message")])
        try await archive.begin(child, workspace: "workspace"); try await archive.finish(child)
        let linked = try await archive.list(sessionID: "new-side", messageID: "inherited-message", workspaceID: "workspace")
        XCTAssertEqual(Set(linked.compactMap { $0["attemptId"]?.string }), [parentID, childID])
        XCTAssertTrue(linked.allSatisfy { $0["workspaceId"]?.string == "workspace" })
        let sessionOnly = try await archive.list(sessionID: "new-side", workspaceID: "workspace")
        XCTAssertEqual(sessionOnly.compactMap { $0["attemptId"]?.string }, [childID])
        let actualOwner = try XCTUnwrap(linked.first { $0["attemptId"]?.string == parentID }?["sessionId"]?.string)
        let exported = try await archive.exportRetained(sessionID: actualOwner, attemptID: parentID, destination: folder)
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("response.bin")), bytes)
    }
    func testPlaintextSharedManifestsRestoreExactBinaryWithoutKeyAndKeepMetricsAfterPurge() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let archive = PayloadArchive(root: folder), bytes = fixture(262_144)
        try await archive.configure(quota: 4_194_304, bodyRetention: 86400, metricRetention: 604800)
        let first = try await save(archive, bytes: bytes), second = try await save(archive, bytes: bytes)
        let stats = try await archive.statistics()
        XCTAssertEqual(stats["logicalBytes"], Int64(bytes.count * 2)); XCTAssertEqual(stats["storedBytes"]!, Int64(bytes.count)); XCTAssertEqual(stats["legacyEncryptedBytes"], 0)
        let exported = try await archive.exportRetained(sessionID: "session", attemptID: first, destination: folder)
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("request.bin")), bytes)
        try FileManager.default.removeItem(at: exported)
        let files = FileManager.default.enumerator(at: folder.appendingPathComponent("chunks"), includingPropertiesForKeys: [.isRegularFileKey])!
        for case let file as URL in files where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            let stored = try Data(contentsOf: file)
            XCTAssertNotNil(bytes.range(of: stored), "Chunk files contain the original unencrypted bytes")
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        try await archive.close()
        let restored = PayloadArchive(root: folder)
        try await restored.configure(quota: 4_194_304, bodyRetention: 86400, metricRetention: 604800)
        let recovered = try await read(restored, id: second, count: bytes.count); XCTAssertEqual(recovered, bytes)
        try await restored.purge(attemptID: first)
        let afterOneDeleted = try await read(restored, id: second, count: bytes.count); XCTAssertEqual(afterOneDeleted, bytes)
        let linked = try await restored.list(sessionID: "session", messageID: "output-message"); XCTAssertEqual(linked.count, 2)
        try await restored.clear(sessionID: "unrelated")
        let stillReadable = try await restored.body(attemptID: second, body: "request", offset: 0); XCTAssertEqual(stillReadable, bytes.prefix(32_768))
        try await restored.clear(sessionID: "session")
        let after = try await restored.statistics(); XCTAssertEqual(after["chunks"], 0); XCTAssertEqual(after["attempts"], 2)
        let meta = try await restored.metadata(attempt: first); XCTAssertEqual(meta["request"]?.object?["state"]?.string, "purged")
    }
    func testCrashRetainsOnlyVerifiedPrefixAndRejectsPlaintextCorruption() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let archive = PayloadArchive(root: folder), bytes = fixture(32_768), id = UUID().uuidString
        try await archive.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 604800)
        try await archive.begin(metadata(id: id), workspace: "workspace")
        try await archive.append(attempt: id, kind: "request", offset: 0, bytes: bytes)
        try await archive.close() // Simulated process death before final manifest.
        let restored = PayloadArchive(root: folder)
        try await restored.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 604800)
        let meta = try await restored.metadata(attempt: id), retained = Int(meta["request"]!.object!["retainedBytes"]!.number!)
        XCTAssertEqual(meta["outcome"]?.string, "interrupted"); XCTAssertGreaterThan(retained, 0)
        XCTAssertLessThanOrEqual(retained, bytes.count)
        let prefix = try await read(restored, id: id, count: retained); XCTAssertEqual(prefix, bytes.prefix(retained))
        try await restored.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 604800)
        let files = FileManager.default.enumerator(at: folder.appendingPathComponent("chunks"), includingPropertiesForKeys: [.isRegularFileKey])!
        let file = try XCTUnwrap(files.allObjects.compactMap { $0 as? URL }.first { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true })
        var damaged = try Data(contentsOf: file); damaged[0] ^= 1; try damaged.write(to: file)
        do { _ = try await read(restored, id: id, count: retained); XCTFail("Tampering must fail verification") } catch { XCTAssertTrue(error is CaptureFailure) }
    }
    func testQuotaAndDiskFailureCannotClaimCompleteAndCaptureOffStillHasRequestLinks() async throws {
        for diskFailure in [false, true] {
            let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
            let archive = PayloadArchive(root: folder, beforeChunkWrite: { if diskFailure { throw CocoaError(.fileWriteOutOfSpace) } })
            try await archive.configure(quota: diskFailure ? 1_048_576 : 100, bodyRetention: 86400, metricRetention: 604800)
            let id = UUID().uuidString
            try await archive.begin(metadata(id: id), workspace: "workspace")
            do { try await archive.append(attempt: id, kind: "request", offset: 0, bytes: fixture(32_768)); XCTFail("Cannot retain beyond quota") } catch { }
            try await archive.finish(metadata(id: id, outcome: "failed", observed: 32_768))
            let meta = try await archive.metadata(attempt: id)
            XCTAssertEqual(meta["request"]?.object?["state"]?.string, "partial"); XCTAssertEqual(meta["request"]?.object?["retainedBytes"]?.number, 0)
            let off = UUID().uuidString
            try await archive.begin(metadata(id: off, mode: "off"), workspace: "workspace")
            try await archive.finish(metadata(id: off, mode: "off", outcome: "completed", observed: 50))
            let attempts = try await archive.list(sessionID: "session", messageID: "input-message"); XCTAssertEqual(attempts.count, 2)
            let offMeta = try await archive.metadata(attempt: off)
            XCTAssertEqual(offMeta["request"]?.object?["state"]?.string, "not-retained")
        }
    }
    func testSessionPrivacyAndBodyRetentionAreIndependentOfMetricRetention() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let clock = ArchiveTestClock(), archive = PayloadArchive(root: folder, now: { clock.read() }), bytes = fixture(65_536)
        try await archive.configure(quota: 1_048_576, bodyRetention: 10, metricRetention: 100)
        let first = try await save(archive, bytes: bytes, session: "one")
        _ = try await save(archive, bytes: bytes, session: "two")
        let stats = try await archive.statistics()
        XCTAssertEqual(stats["storedBytes"]!, Int64(bytes.count * 2), "Identical plaintext in separate sessions must not share chunk identities")
        clock.advance(11); try await archive.reconcile()
        let retainedMetrics = try await archive.statistics(); XCTAssertEqual(retainedMetrics["attempts"], 2); XCTAssertEqual(retainedMetrics["chunks"], 0)
        let meta = try await archive.metadata(attempt: first); XCTAssertEqual(meta["request"]?.object?["state"]?.string, "expired")
        clock.advance(100); try await archive.reconcile()
        let expiredMetrics = try await archive.statistics(); XCTAssertEqual(expiredMetrics["attempts"], 0)
        XCTAssertEqual(expiredMetrics["expiredRequests"], 2)
        let links = try await archive.list(sessionID: "one", messageID: "input-message")
        XCTAssertEqual(links.count, 1); XCTAssertEqual(links[0]["metricsExpired"]?.bool, true)
    }
    func testDefaultThirtyDayBodiesExpireWhileRetainedHeadersAndMetricsRemainReadable() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let clock = ArchiveTestClock(), archive = PayloadArchive(root: folder, now: { clock.read() })
        let preferences = VaultConfiguration(), id = UUID().uuidString, bytes = Data("retained request".utf8)
        try await archive.configure(quota: preferences.capture.quotaBytes,
                                    bodyRetention: Double(preferences.capture.retentionDays) * 86400,
                                    metricRetention: Double(preferences.dashboard.metricRetentionDays) * 86400)
        var entry = metadata(id: id, observed: bytes.count)
        entry["requestHeaders"] = .object(["authorization": .string("Bearer ********-key"), "content-type": .string("application/json")])
        entry["responseHeaders"] = .object(["date": .string("Wed, 16 Sep 2026 01:23:24 GMT"), "x-provider-build": .string("fixture-v1")])
        try await archive.begin(entry, workspace: "workspace")
        try await archive.append(attempt: id, kind: "request", offset: 0, bytes: bytes)
        entry["outcome"] = .string("completed"); try await archive.finish(entry)
        clock.advance(29 * 86400); try await archive.reconcile()
        let retained = try await archive.body(attemptID: id, body: "request", offset: 0)
        XCTAssertEqual(retained, bytes)
        clock.advance(2 * 86400); try await archive.reconcile()
        let expired = try await archive.metadata(attempt: id)
        XCTAssertEqual(expired["request"]?.object?["state"]?.string, "expired")
        XCTAssertEqual(expired["requestHeaders"], entry["requestHeaders"])
        XCTAssertEqual(expired["responseHeaders"], entry["responseHeaders"])
        XCTAssertEqual(expired["metricsRetained"]?.bool, true)
        do { _ = try await archive.body(attemptID: id, body: "request", offset: 0); XCTFail("Expired bytes must be unavailable") } catch { }
    }
    func testQuotaEvictionAndCancellationRetainHonestPrefixesAndRequestCounts() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let archive = PayloadArchive(root: folder), bytes = fixture(131_072)
        try await archive.configure(quota: 150_000, bodyRetention: 86400, metricRetention: 604800)
        let old = try await save(archive, bytes: bytes)
        let current = UUID().uuidString
        try await archive.begin(metadata(id: current), workspace: "workspace")
        for offset in stride(from: 0, to: bytes.count, by: 32_768) {
            try await archive.append(attempt: current, kind: "response", offset: offset, bytes: Data(bytes.subdata(in: offset..<offset + 32_768).reversed()))
        }
        var cancelled = metadata(id: current, outcome: "cancelled")
        cancelled["response"] = .object(["observedBytes": .number(Double(bytes.count))])
        try await archive.finish(cancelled)
        let previous = try await archive.metadata(attempt: old), newest = try await archive.metadata(attempt: current)
        XCTAssertEqual(previous["request"]?.object?["state"]?.string, "expired")
        XCTAssertEqual(newest["response"]?.object?["state"]?.string, "partial")
        XCTAssertEqual(newest["response"]?.object?["retainedBytes"]?.number, Double(bytes.count))
        let stats = try await archive.statistics(); XCTAssertEqual(stats["attempts"], 2); XCTAssertLessThanOrEqual(stats["storedBytes"]!, 150_000)
    }
    func testExportLeaseProtectsSharedChunksFromConcurrentDeletion() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let latch = ExportLatch(), clock = ArchiveTestClock()
        let archive = PayloadArchive(root: folder, now: { clock.read() }, exportDidReadPage: { await latch.pause() }), bytes = fixture(131_072)
        try await archive.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 604800)
        let first = try await save(archive, bytes: bytes), second = try await save(archive, bytes: bytes)
        let export = Task { try await archive.exportRetained(sessionID: "session", attemptID: first, destination: folder) }
        for _ in 0..<100 { if await latch.entered { break }; try await Task.sleep(for: .milliseconds(10)) }
        let entered = await latch.entered; XCTAssertTrue(entered)
        do { try await archive.clear(sessionID: "session"); XCTFail("Active export must protect its references") } catch { XCTAssertTrue(error is CaptureFailure) }
        try await archive.purge(attemptID: second)
        clock.advance(604801); try await archive.reconcile()
        let leased = try await archive.metadata(attempt: first)
        XCTAssertEqual(leased["request"]?.object?["state"]?.string, "complete")
        XCTAssertEqual(leased["metricsRetained"]?.bool, true)
        await latch.release()
        let url = try await export.value
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("request.bin")), bytes)
        _ = try await archive.list(sessionID: "session")
        let expired = try await archive.metadata(attempt: first)
        XCTAssertEqual(expired["request"]?.object?["state"]?.string, "expired", "Releasing the export must invalidate the cached retention deadline immediately")
        XCTAssertEqual(expired["metricsRetained"]?.bool, false)
        try await archive.purge(attemptID: first)
        let stats = try await archive.statistics(); XCTAssertEqual(stats["chunks"], 0)
    }
    func testRetainedSSEIndicesAndMessageLinksArePagedAndReleasedWithBodies() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let archive = PayloadArchive(root: folder)
        try await archive.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 604800)
        let id = try await save(archive, bytes: fixture(1000))
        let event: WireValue = .object(["type": .string("message"), "start": .number(0), "end": .number(100), "observedAt": .number(50)])
        try await archive.accept(["type": .string("events"), "attemptId": .string(id), "offset": .number(0), "events": .array([event])], workspace: "workspace")
        do { try await archive.accept(["type": .string("events"), "attemptId": .string(id), "offset": .number(0), "events": .array([event])], workspace: "workspace"); XCTFail("Duplicate index pages must not silently duplicate records") } catch { }
        let events = try await archive.eventIndices(attemptID: id, offset: 0); XCTAssertEqual(events["events"]?.array, [event])
        let links = try await archive.messageLinks(attemptID: id, offset: 0); XCTAssertEqual(links["total"]?.number, 2)
        try await archive.purge(attemptID: id)
        let after = try await archive.eventIndices(attemptID: id, offset: 0); XCTAssertEqual(after["total"]?.number, 0)
        let retainedLinks = try await archive.messageLinks(attemptID: id, offset: 0); XCTAssertEqual(retainedLinks["total"]?.number, 2)
    }
}
