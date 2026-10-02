import XCTest
@testable import PiApp

private final class CleanupClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1000
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: time) }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; time += seconds }
}

/// An archive holding more than 100,001 chunks is cleaned a batch at a time:
/// reopening, retention expiry, clearing a chat and the next capture all
/// work, a cleanup that fails part-way is finished by the next one, and no
/// maintenance query reads more than a batch (finding 6).
final class CaptureGarbageCollectionTests: XCTestCase {
    static let many = 100_002
    private func root() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func fixture(_ count: Int, seed: UInt64 = 0xabcde12345) -> Data {
        var state = seed
        return Data((0..<count).map { _ in state ^= state << 13; state ^= state >> 7; state ^= state << 17; return UInt8(truncatingIfNeeded: state) })
    }
    private func metadata(id: String, session: String, outcome: String = "running", observed: Int = 0) -> [String: WireValue] {
        ["attemptId": .string(id), "sessionId": .string(session), "turnId": .string("turn"), "purpose": .string("turn"), "api": .string("openai-responses"),
         "requestedModel": .string("auto-router"), "mode": .string("persist"), "outcome": .string(outcome), "messageIds": .array([.string("input-message")]),
         "outputMessageIds": .array(outcome == "running" ? [] : [.string("output-message")]), "request": .object(["observedBytes": .number(Double(observed))]),
         "response": .object(["observedBytes": .number(0)])]
    }
    private func save(_ archive: PayloadArchive, bytes: Data, session: String) async throws -> String {
        let id = UUID().uuidString
        try await archive.begin(metadata(id: id, session: session), workspace: "workspace")
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
    private func name(_ index: Int) -> String { String(format: "%064x", index) }
    /// Chunks and references for `attempt`, written by a second connection
    /// while the archive is idle, with files for the chunks `files` picks.
    private func plant(_ folder: URL, attempt: String, scope: String, count: Int, bytes: Int64, files: (Int) -> Bool) throws {
        let db = try CaptureDatabase(url: folder.appendingPathComponent("requests.sqlite"))
        try db.transaction {
            for index in 0..<count {
                try db.execute("INSERT INTO chunks(scope,id,length,bytes,storage) VALUES(?,?,?,?,'plaintext-v2')", [.text(scope), .text(name(index)), .integer(bytes), .integer(bytes)])
                try db.execute("INSERT INTO refs VALUES(?,?,?,?,?,?,?)", [.text(attempt), .text("request"), .integer(Int64(1_000_000 + index)), .text(scope), .text(name(index)), .integer(0), .integer(bytes)])
            }
        }
        let directory = folder.appendingPathComponent("chunks/" + scope, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<count where files(index) { FileManager.default.createFile(atPath: directory.appendingPathComponent(name(index)).path, contents: Data([1])) }
    }
    private func count(_ folder: URL, _ sql: String, _ values: [CaptureSQLValue] = []) throws -> Int64 {
        try CaptureDatabase(url: folder.appendingPathComponent("requests.sqlite"), readOnly: true).rows(sql, values).first?["n"]?.number ?? -1
    }
    private func exists(_ folder: URL, _ scope: String, _ index: Int) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("chunks/" + scope + "/" + name(index)).path)
    }

    /// Reopening with every chunk still referenced, then letting retention
    /// expire them, then capturing again.
    func testRetentionExpiresMoreThanAHundredThousandChunks() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let clock = CleanupClock(), scope = String(repeating: "a", count: 64)
        var archive = PayloadArchive(root: folder, now: { clock.read() })
        try await archive.configure(quota: nil, bodyRetention: 1_000, metricRetention: 100_000)
        let old = try await save(archive, bytes: fixture(4_096), session: "old")
        try await archive.close()
        try plant(folder, attempt: old, scope: scope, count: Self.many, bytes: 1, files: { $0 % 997 == 0 || $0 >= Self.many - 3 })
        archive = PayloadArchive(root: folder, now: { clock.read() })
        try await archive.configure(quota: nil, bodyRetention: 1_000, metricRetention: 100_000)
        XCTAssertGreaterThan(try count(folder, "SELECT COUNT(*) AS n FROM chunks"), Int64(Self.many), "reopened with every chunk still in use")
        clock.advance(2_000)
        let bytes = fixture(70_000, seed: 7), fresh = try await save(archive, bytes: bytes, session: "fresh")
        let retained = try await read(archive, id: fresh, count: bytes.count)
        XCTAssertEqual(retained, bytes, "a capture begins and finishes after the sweep")
        XCTAssertEqual(try count(folder, "SELECT COUNT(*) AS n FROM chunks WHERE scope=?", [.text(scope)]), 0)
        XCTAssertFalse(exists(folder, scope, 0) || exists(folder, scope, Self.many - 1), "the expired chunks' files are gone")
        let largest = await archive.largestMaintenanceBatch
        XCTAssertLessThanOrEqual(largest, PayloadArchive.maintenanceBatch)
        try await archive.close()
    }

    /// Clearing a chat with more than 100,001 chunks, where a file cannot be
    /// removed part-way through a batch: the next cleanup finishes, quota
    /// accounting is not left stale, and only stray files are swept at open.
    func testClearingAHugeChatRecoversFromAFailedBatch() async throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let first = String(repeating: "0", count: 64), last = String(repeating: "f", count: 64)
        var archive = PayloadArchive(root: folder)
        try await archive.configure(quota: nil, bodyRetention: 86_400, metricRetention: 172_800)
        let kept = fixture(90_000, seed: 3), keep = try await save(archive, bytes: kept, session: "keep")
        let big = try await save(archive, bytes: fixture(2_048, seed: 5), session: "big")
        try await archive.close()
        let tail = Self.many % PayloadArchive.maintenanceBatch
        try plant(folder, attempt: big, scope: first, count: Self.many, bytes: 10_000, files: { $0 % 991 == 0 || $0 >= Self.many - tail - 2 })
        // Planted after the first scope's references: its own indices.
        let db = try CaptureDatabase(url: folder.appendingPathComponent("requests.sqlite"))
        try db.transaction {
            for index in 0..<600 {
                try db.execute("INSERT INTO chunks(scope,id,length,bytes,storage) VALUES(?,?,?,?,'plaintext-v2')", [.text(last), .text(name(index)), .integer(1), .integer(1)])
                try db.execute("INSERT INTO refs VALUES(?,?,?,?,?,?,?)", [.text(big), .text("request"), .integer(Int64(2_000_000 + index)), .text(last), .text(name(index)), .integer(0), .integer(1)])
            }
        }
        let locked = folder.appendingPathComponent("chunks/" + last, isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        for index in 0..<600 { FileManager.default.createFile(atPath: locked.appendingPathComponent(name(index)).path, contents: Data([1])) }
        let stored = try count(folder, "SELECT COALESCE(SUM(bytes),0) AS n FROM chunks")
        // Room for a little more than is stored: stale totals after the failed
        // cleanup would evict the kept chat to make room for the next capture.
        archive = PayloadArchive(root: folder)
        try await archive.configure(quota: stored + 100_000, bodyRetention: 86_400, metricRetention: 172_800)
        _ = try await save(archive, bytes: fixture(64, seed: 9), session: "probe")

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        do { try await archive.clear(sessionID: "big"); XCTFail("removing a file in a read-only folder fails") }
        catch let error as CocoaError { XCTAssertEqual(error.code, .fileWriteNoPermission, "\(error)") }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        XCTAssertEqual(try count(folder, "SELECT COUNT(*) AS n FROM chunks WHERE scope=?", [.text(first)]), Int64(tail),
                       "batches before the failed one are gone; the failed batch's rows remain")
        XCTAssertFalse(exists(folder, first, Self.many - 1), "a remaining row's file was already removed")
        XCTAssertTrue(exists(folder, last, 0), "the file that could not be removed is still there")

        let next = fixture(150_000, seed: 11), after = try await save(archive, bytes: next, session: "after")
        let keptBack = try await read(archive, id: keep, count: kept.count)
        XCTAssertEqual(keptBack, kept, "the next capture found room without evicting the kept chat")
        let nextBack = try await read(archive, id: after, count: next.count)
        XCTAssertEqual(nextBack, next)
        try await archive.clear(sessionID: "big")
        XCTAssertEqual(try count(folder, "SELECT COUNT(*) AS n FROM chunks WHERE scope IN (?,?)", [.text(first), .text(last)]), 0)
        XCTAssertFalse(exists(folder, last, 0) || exists(folder, first, Self.many - 1), "the next cleanup finished the files")
        let largest = await archive.largestMaintenanceBatch
        XCTAssertLessThanOrEqual(largest, PayloadArchive.maintenanceBatch)
        try await archive.close()

        // At open, only files that are not a known chunk at its own place go.
        let chunks = folder.appendingPathComponent("chunks", isDirectory: true)
        let keepScope = CaptureContent.scope(session: "keep")
        let keepChunk = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: chunks.appendingPathComponent(keepScope).path).first)
        let strays = [chunks.appendingPathComponent(keepScope + "/" + name(42)), chunks.appendingPathComponent("loose"),
                      chunks.appendingPathComponent("extra/" + keepScope + "/" + keepChunk)]
        for stray in strays {
            try FileManager.default.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: stray.path, contents: Data([2]))
        }
        archive = PayloadArchive(root: folder)
        try await archive.configure(quota: nil, bodyRetention: 86_400, metricRetention: 172_800)
        for stray in strays { XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path), stray.path) }
        let reopened = try await read(archive, id: keep, count: kept.count)
        XCTAssertEqual(reopened, kept, "known chunks stay")
        try await archive.close()
    }
}
