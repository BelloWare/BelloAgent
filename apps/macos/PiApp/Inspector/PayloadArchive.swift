import Foundation
import CryptoKit
import Darwin

// One native actor owns global quota, manifests and request metadata. Helpers
// stream bounded byte pages. New bodies are plaintext; only the compatibility
// reader for existing encrypted bodies receives their original native-vault key.
actor PayloadArchive {
    // Two bounded chunkers belong to each persisted attempt. This supports
    // 20 live chats plus their utility requests while retaining at most 4 MiB
    // of unpublished chunk tails across 64 simultaneous attempts.
    private static let maximumBodyWriters = 128
    let root: URL
    private var database: CaptureDatabase?
    private var reportReader: DashboardReader?
    var usageSnapshots: [UsageSnapshotKey: MenuBarSnapshot] = [:]
    var usageReadGeneration = 0
    private var closeTask: Task<Void, Never>?
    private var ownership: WorkspaceLock?
    private var legacyCipher: LegacyCaptureCipher?
    private var quota: Int64 = 1_073_741_824
    private var bodyRetention: TimeInterval = 30 * 86400
    private var metricRetention: TimeInterval = 90 * 86400
    private let now: @Sendable () -> Date
    private let beforeChunkWrite: @Sendable () throws -> Void
    private let exportDidReadPage: @Sendable () async -> Void
    private let didReconcile: @Sendable () -> Void
    // Accounting refreshes for each sidebar row share this deadline. A read
    // before the next expiry must not sweep every manifest/chunk in the archive.
    private var nextReconciliation = -Double.infinity
    private struct Writer {
        var chunker = CaptureChunker(), hasher = SHA256()
        var observed = 0, length = 0, ordinal = 0
        var failure: String?
    }
    private var writers: [String: Writer] = [:]
    private var leases: Set<String> = []
    /// Running totals for the two tables whose size is checked on every write.
    /// Recomputing them per chunk and per event page made each write cost a
    /// full scan of the whole archive, so capture slowed down as it filled.
    /// Seeded on demand and dropped whenever rows are removed.
    private var chunkTotals: (count: Int64, bytes: Int64)?
    private var eventIndexCount: Int64?
    init(root: URL, now: @escaping @Sendable () -> Date = { Date() }, beforeChunkWrite: @escaping @Sendable () throws -> Void = {}, exportDidReadPage: @escaping @Sendable () async -> Void = { await Task.yield() }, didReconcile: @escaping @Sendable () -> Void = {}) {
        self.root = root; self.now = now; self.beforeChunkWrite = beforeChunkWrite; self.exportDidReadPage = exportDidReadPage
        self.didReconcile = didReconcile
    }
    func configure(key: Data? = nil, quota: Int64, bodyRetention: TimeInterval, metricRetention: TimeInterval) throws {
        guard closeTask == nil else { throw CaptureFailure.busy }
        let next = try key.flatMap { $0.isEmpty ? nil : try LegacyCaptureCipher(key: $0) }
        guard quota > 0, bodyRetention > 0, metricRetention > 0 else { throw CaptureFailure.unavailable }
        if let database { try verifyLegacyKey(database, cipher: next) }
        legacyCipher = next; self.quota = quota; self.bodyRetention = bodyRetention; self.metricRetention = metricRetention
        nextReconciliation = -Double.infinity
        if database == nil { try open() }
        try reconcile()
    }
    private func verifyLegacyKey(_ db: CaptureDatabase, cipher: LegacyCaptureCipher?) throws {
        let encryptedChunks = try db.rows("SELECT 1 AS present FROM chunks WHERE storage='aes-gcm-v1' LIMIT 1")
        let encryptedDigests = try db.rows("SELECT 1 AS present FROM bodies WHERE storage='aes-gcm-v1' AND digest IS NOT NULL LIMIT 1")
        guard !encryptedChunks.isEmpty || !encryptedDigests.isEmpty else { return }
        guard let cipher else { throw CaptureFailure.legacyKeyUnavailable }
        guard let check = try db.rows("SELECT value FROM archive_info WHERE name='key-check'").first?["value"]?.data,
              try cipher.open(check, context: "archive-key-check") == Data("PiApp capture archive v1".utf8) else { throw CaptureFailure.corrupt }
    }
    private func open() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw CaptureFailure.unavailable }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let ownership = try WorkspaceLock(url: root.appendingPathComponent("writer.lock"))
        let db = try CaptureDatabase(url: root.appendingPathComponent("requests.sqlite"))
        try db.execute("CREATE TABLE IF NOT EXISTS archive_info(name TEXT PRIMARY KEY,value BLOB NOT NULL)")
        try db.execute("CREATE TABLE IF NOT EXISTS attempts(id TEXT PRIMARY KEY, session TEXT NOT NULL, workspace TEXT NOT NULL, turn TEXT NOT NULL, purpose TEXT NOT NULL, api TEXT NOT NULL, alias TEXT NOT NULL, model TEXT, outcome TEXT NOT NULL, wall REAL NOT NULL, updated REAL NOT NULL, metadata BLOB NOT NULL)")
        let version = try db.rows("PRAGMA user_version").first?["user_version"]?.number ?? 0
        guard version <= 5 else { throw CaptureFailure.corrupt }
        if !(try db.rows("PRAGMA table_info(attempts)")).contains(where: { $0["name"]?.string == "metrics_retained" }) {
            try db.execute("ALTER TABLE attempts ADD COLUMN metrics_retained INTEGER NOT NULL DEFAULT 1")
        }
        try Self.prepareDashboardSchema(db, migrate: version < 4)
        try db.execute("CREATE INDEX IF NOT EXISTS attempts_filter ON attempts(wall,workspace,session,purpose,api,outcome)")
        try db.execute("CREATE TABLE IF NOT EXISTS bodies(attempt TEXT NOT NULL REFERENCES attempts(id) ON DELETE CASCADE, kind TEXT NOT NULL, state TEXT NOT NULL, reason TEXT, observed INTEGER NOT NULL DEFAULT 0, length INTEGER NOT NULL DEFAULT 0, digest BLOB, PRIMARY KEY(attempt,kind))")
        try db.execute("CREATE TABLE IF NOT EXISTS chunks(scope TEXT NOT NULL, id TEXT NOT NULL, length INTEGER NOT NULL, bytes INTEGER NOT NULL, PRIMARY KEY(scope,id))")
        try db.execute("CREATE TABLE IF NOT EXISTS refs(attempt TEXT NOT NULL, kind TEXT NOT NULL, ordinal INTEGER NOT NULL, scope TEXT NOT NULL, chunk TEXT NOT NULL, offset INTEGER NOT NULL, length INTEGER NOT NULL, PRIMARY KEY(attempt,kind,ordinal), FOREIGN KEY(attempt,kind) REFERENCES bodies(attempt,kind) ON DELETE CASCADE, FOREIGN KEY(scope,chunk) REFERENCES chunks(scope,id))")
        try db.transaction {
            for table in ["bodies", "chunks"] {
                if !(try db.rows("PRAGMA table_info(\(table))")).contains(where: { $0["name"]?.string == "storage" }) {
                    try db.execute("ALTER TABLE \(table) ADD COLUMN storage TEXT NOT NULL DEFAULT 'aes-gcm-v1'")
                }
            }
            try verifyLegacyKey(db, cipher: legacyCipher)
            try db.execute("PRAGMA user_version=5")
        }
        try db.execute("CREATE INDEX IF NOT EXISTS refs_chunk ON refs(scope,chunk)")
        try db.execute("CREATE TABLE IF NOT EXISTS message_links(attempt TEXT NOT NULL REFERENCES attempts(id) ON DELETE CASCADE, message TEXT NOT NULL, role TEXT NOT NULL, PRIMARY KEY(attempt,message,role))")
        try db.execute("CREATE INDEX IF NOT EXISTS message_lookup ON message_links(message,attempt)")
        try db.execute("CREATE INDEX IF NOT EXISTS accounting_outputs ON message_links(message,attempt) WHERE role='output'")
        try db.execute("CREATE TABLE IF NOT EXISTS event_indices(attempt TEXT NOT NULL REFERENCES attempts(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, value BLOB NOT NULL, PRIMARY KEY(attempt,ordinal))")
        // Only startup has no live producer. Surviving manifests describe a
        // verified prefix; a crash never manufactures a successful completion.
        try db.execute("UPDATE bodies SET state='interrupted',reason='Writer exited before final manifest' WHERE state='recording'")
        try db.execute("UPDATE attempts SET outcome='interrupted' WHERE outcome='running'")
        self.database = db; self.ownership = ownership
        try collectGarbage(scanOrphans: true)
    }
    private func ready() throws -> CaptureDatabase {
        guard let database else { throw CaptureFailure.unavailable }; return database
    }
    // Called only by actor-isolated dashboard extension methods. No UI receives
    // the connection or executes SQL; filters are typed and parameterized.
    func dashboardDatabase() throws -> CaptureDatabase { try ready() }
    func dashboardReader() throws -> DashboardReader {
        _ = try ready()
        try reconcile()
        if let reportReader { return reportReader }
        let reader = DashboardReader(url: root.appendingPathComponent("requests.sqlite"))
        reportReader = reader
        return reader
    }
    private func writerKey(_ id: String, _ kind: String) -> String { id + ":" + kind }
    private func record(_ id: String) throws -> [String: CaptureSQLValue] {
        let db = try ready()
        guard UUID(uuidString: id) != nil, let row = try db.rows("SELECT * FROM attempts WHERE id=?", [.text(id)]).first else { throw CaptureFailure.unavailable }
        return row
    }
    /// Resolve the owner plus output links on at most two 500-row visible
    /// pages. Final metadata omits link arrays; never materialize the attempt's
    /// entire retained context or scan unrelated sessions to route its update.
    func accountingTarget(attemptID: String, workspaceID: String, visibleMessageIDs: Set<String> = []) throws -> (sessionID: String, outputMessageIDs: Set<String>)? {
        guard UUID(uuidString: attemptID) != nil else { return nil }
        guard visibleMessageIDs.count <= 1000 else { throw CaptureFailure.unavailable }
        let db = try ready()
        guard let session = try db.rows("SELECT session FROM attempts WHERE id=? AND workspace=?", [.text(attemptID), .text(workspaceID)]).first?["session"]?.string else { return nil }
        guard !visibleMessageIDs.isEmpty else { return (session, []) }
        let placeholders = Array(repeating: "?", count: visibleMessageIDs.count).joined(separator: ",")
        let rows = try db.rows("SELECT message FROM message_links INDEXED BY accounting_outputs WHERE role='output' AND attempt=? AND message IN (\(placeholders))", [.text(attemptID)] + visibleMessageIDs.map(CaptureSQLValue.text))
        return (session, Set(rows.compactMap { $0["message"]?.string }))
    }
    func begin(_ metadata: [String: WireValue], workspace: String) throws {
        let db = try ready()
        guard let id = metadata["attemptId"]?.string, UUID(uuidString: id) != nil,
              let session = metadata["sessionId"]?.string, !session.isEmpty, session.utf8.count <= 128,
              let turn = metadata["turnId"]?.string, turn.utf8.count <= 128, workspace.utf8.count <= 128 else { throw CaptureFailure.unavailable }
        let mode = metadata["mode"]?.string ?? "off"
        guard ["persist", "memory", "off"].contains(mode), try db.rows("SELECT id FROM attempts WHERE id=?", [.text(id)]).isEmpty else { throw CaptureFailure.sequence }
        guard mode != "persist" || writers.count + 2 <= Self.maximumBodyWriters else { throw CaptureFailure.quota }
        let encoded = try JSONEncoder().encode(metadata)
        guard encoded.count <= 262_144 else { throw CaptureFailure.unavailable }
        try reconcile()
        guard (try db.rows("SELECT COUNT(*) AS n FROM attempts").first?["n"]?.number ?? 0) < 100_000 else { throw CaptureFailure.quota }
        try db.transaction {
            try db.execute("INSERT INTO attempts(id,session,workspace,turn,purpose,api,alias,model,outcome,wall,updated,metadata) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", [.text(id), .text(session), .text(workspace), .text(turn), .text(metadata["purpose"]?.string ?? "turn"), .text(metadata["api"]?.string ?? ""), .text(metadata["requestedModel"]?.string ?? ""), .null, .text("running"), .real(metadata["wallTimestamp"]?.number ?? now().timeIntervalSince1970), .real(now().timeIntervalSince1970), .blob(encoded)])
            for kind in ["request", "response"] {
                try db.execute("INSERT INTO bodies(attempt,kind,state,reason,storage) VALUES(?,?,?,?,'plaintext-v2')", [.text(id), .text(kind), .text(mode == "persist" ? "recording" : "not-retained"), .text(mode == "off" ? "Capture was disabled" : mode == "memory" ? "Session-memory capture is not durable" : "")])
            }
            try link(metadata, id: id, db: db)
            try Self.projectDashboard(metadata, id: id, db: db)
        }
        if mode == "persist" { for kind in ["request", "response"] { writers[writerKey(id, kind)] = Writer() } }
    }
    private func link(_ metadata: [String: WireValue], id: String, db: CaptureDatabase) throws {
        for (field, role) in [("messageIds", "context"), ("outputMessageIds", "output")] {
            let values = metadata[field]?.array ?? []
            guard values.count <= 10_000 else { throw CaptureFailure.unavailable }
            for value in values {
                guard let message = value.string, !message.isEmpty, message.utf8.count <= 128 else { throw CaptureFailure.unavailable }
                try db.execute("INSERT OR IGNORE INTO message_links VALUES(?,?,?)", [.text(id), .text(message), .text(role)])
            }
        }
    }
    func append(attempt: String, kind: String, offset: Int, bytes: Data) throws {
        let db = try ready(), key = writerKey(attempt, kind)
        guard ["request", "response"].contains(kind), !bytes.isEmpty, bytes.count <= 32_768,
              var writer = writers[key], writer.failure == nil, offset == writer.observed,
              offset + bytes.count <= (kind == "request" ? 33_554_432 : 67_108_864) else { throw CaptureFailure.sequence }
        let row = try record(attempt), scope = CaptureContent.scope(session: try archiveText(row, "session"))
        writer.observed += bytes.count
        do {
            let chunks = writer.chunker.feed(bytes)
            for chunk in chunks { try publish(chunk, attempt: attempt, kind: kind, scope: scope, writer: &writer) }
            try db.execute("UPDATE bodies SET observed=? WHERE attempt=? AND kind=?", [.integer(Int64(writer.observed)), .text(attempt), .text(kind)])
            writers[key] = writer
        } catch {
            let reason = error is CaptureFailure ? error.localizedDescription : "Capture disk write failed"
            writer.failure = reason
            writers[key] = writer
            try? db.execute("UPDATE bodies SET state='partial',reason=?,observed=? WHERE attempt=? AND kind=?", [.text(reason), .integer(Int64(writer.observed)), .text(attempt), .text(kind)])
            throw error
        }
    }
    private func publish(_ bytes: Data, attempt: String, kind: String, scope: String, writer: inout Writer) throws {
        guard !bytes.isEmpty else { return }
        let db = try ready(), id = CaptureContent.chunkID(bytes, scope: scope)
        let existing = try db.rows("SELECT length,storage FROM chunks WHERE scope=? AND id=?", [.text(scope), .text(id)]).first
        if let existing { guard existing["length"]?.number == Int64(bytes.count), existing["storage"]?.string == CaptureStorageFormat.plaintext.rawValue else { throw CaptureFailure.corrupt }; _ = try readChunk(scope: scope, id: id, count: bytes.count) }
        else {
            try reserve(Int64(bytes.count))
            try beforeChunkWrite()
            let folder = root.appendingPathComponent("chunks/" + scope, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for directory in [folder, folder.deletingLastPathComponent()] {
                guard (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw CaptureFailure.corrupt }
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
            let file = folder.appendingPathComponent(id)
            try bytes.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }; try handle.synchronize()
            // Content and directory entry are durable before a manifest refers
            // to them. Orphans from a crash are collected on restart.
            for directory in [folder, folder.deletingLastPathComponent(), root] {
                let fd = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW); guard fd >= 0 else { throw CaptureFailure.unavailable }
                let synced = fsync(fd); Darwin.close(fd); guard synced == 0 else { throw CaptureFailure.unavailable }
            }
        }
        var hasher = writer.hasher; hasher.update(data: bytes)
        let digest = Data(hasher.finalize())
        let stored = existing == nil
        try db.transaction {
            try db.execute("INSERT OR IGNORE INTO chunks(scope,id,length,bytes,storage) VALUES(?,?,?,?,'plaintext-v2')", [.text(scope), .text(id), .integer(Int64(bytes.count)), .integer(Int64(bytes.count))])
            try db.execute("INSERT INTO refs VALUES(?,?,?,?,?,?,?)", [.text(attempt), .text(kind), .integer(Int64(writer.ordinal)), .text(scope), .text(id), .integer(Int64(writer.length)), .integer(Int64(bytes.count))])
            try db.execute("UPDATE bodies SET length=?,digest=? WHERE attempt=? AND kind=?", [.integer(Int64(writer.length + bytes.count)), .blob(digest), .text(attempt), .text(kind)])
        }
        if stored, let totals = chunkTotals { chunkTotals = (totals.count + 1, totals.bytes + Int64(bytes.count)) }
        writer.hasher.update(data: bytes); writer.length += bytes.count; writer.ordinal += 1
    }
    func finish(_ metadata: [String: WireValue]) throws {
        guard let id = metadata["attemptId"]?.string else { throw CaptureFailure.unavailable }
        let db = try ready(), row = try record(id), scope = CaptureContent.scope(session: try archiveText(row, "session"))
        guard row["session"]?.string == metadata["sessionId"]?.string else { throw CaptureFailure.sequence }
        // Validate both descriptors before publishing tails or dropping either
        // writer. Off/memory captures and repeated finishes need the same bounds.
        for kind in ["request", "response"] {
            let source = metadata[kind]?.object ?? [:]
            for field in ["observedBytes", "captureBytes"] {
                guard let value = source[field] else { continue }
                guard let number = value.number, number.isFinite, number >= 0,
                      number <= 1_073_741_824, number.rounded() == number else { throw CaptureFailure.sequence }
            }
            if kind == "request", source["state"]?.string == "credential-omitted",
               let writer = writers[writerKey(id, kind)] {
                guard writer.length == 0, writer.observed == 0,
                      (source["captureBytes"]?.number ?? source["observedBytes"]?.number ?? 0) == 0 else { throw CaptureFailure.sequence }
            }
        }
        for kind in ["request", "response"] {
            let key = writerKey(id, kind)
            if var writer = writers.removeValue(forKey: key) {
                do {
                    if writer.failure == nil { let tail = writer.chunker.finish(); try publish(tail, attempt: id, kind: kind, scope: scope, writer: &writer) }
                } catch { writer.failure = error.localizedDescription }
                let source = metadata[kind]?.object ?? [:]
                let reportedObserved = source["observedBytes"]?.number ?? 0
                let reportedCapture = source["captureBytes"]?.number
                // Credential hashes can be longer than the submitted key.
                // Keep wire size separate from the transformed capture size.
                let observed = reportedCapture == nil ? max(writer.observed, Int(reportedObserved)) : Int(reportedObserved)
                let captureLength = Int(reportedCapture ?? Double(observed))
                let transformed = (source["credentialRedactions"]?.number ?? 0) > 0
                let transformedState = kind == "request" ? "credential-hashed" : "credential-masked"
                let transformedReason = kind == "request"
                    ? "Known authentication credentials were replaced with SHA-256 hashes; retained bytes differ from the submitted body"
                    : "Known authentication credential echoes were masked; retained bytes differ from the received body"
                let credentialOmitted = kind == "request" && source["state"]?.string == "credential-omitted"
                let complete = writer.failure == nil && writer.length == captureLength && (kind == "request" ||
                    (captureLength == observed && (metadata["transportOutcome"]?.string.map { $0 == "eof" } ?? (metadata["outcome"]?.string == "completed"))))
                let digest = Data(writer.hasher.finalize())
                try db.execute("UPDATE bodies SET state=?,reason=?,observed=?,length=?,digest=? WHERE attempt=? AND kind=?", [.text(credentialOmitted ? "credential-omitted" : complete ? (transformed ? transformedState : "complete") : "partial"), .text(credentialOmitted ? "Request body was not retained because credential hashing exceeded capture safety limits" : writer.failure ?? (complete ? (transformed ? transformedReason : "") : "Only a prefix of the observed HTTP body was retained, or HTTP completion was unobserved")), .integer(Int64(observed)), .integer(Int64(writer.length)), credentialOmitted ? .null : .blob(digest), .text(id), .text(kind)])
            } else {
                try db.execute("UPDATE bodies SET observed=? WHERE attempt=? AND kind=?", [.integer(Int64(metadata[kind]?.object?["observedBytes"]?.number ?? 0)), .text(id), .text(kind)])
            }
        }
        try update(metadata)
    }
    func update(_ metadata: [String: WireValue]) throws {
        let db = try ready()
        guard let id = metadata["attemptId"]?.string else { throw CaptureFailure.sequence }
        let existing = try record(id)
        guard existing["session"]?.string == metadata["sessionId"]?.string else { throw CaptureFailure.sequence }
        let encoded = try JSONEncoder().encode(metadata); guard encoded.count <= 262_144 else { throw CaptureFailure.unavailable }
        try db.transaction {
            try db.execute("UPDATE attempts SET outcome=?,model=?,updated=?,metadata=? WHERE id=?", [.text(metadata["outcome"]?.string ?? "interrupted"), metadata["identity"]?.object?["effectiveModel"]?.string.map(CaptureSQLValue.text) ?? .null, .real(now().timeIntervalSince1970), .blob(encoded), .text(id)])
            try link(metadata, id: id, db: db)
            try Self.projectDashboard(metadata, id: id, db: db)
        }
        // A finished request becomes eligible when its own retention deadline
        // arrives, which for a request that just ended is weeks away. Forcing a
        // sweep here made the next dispatched request re-read every manifest,
        // reference and chunk in the archive, so capture slowed down as the
        // archive filled. An older request finishing late still lowers it.
        if metadata["outcome"]?.string != "running" {
            if let wall = existing["wall"]?.double {
                nextReconciliation = min(nextReconciliation, wall + min(bodyRetention, metricRetention))
            } else { nextReconciliation = -Double.infinity }
        }
    }
    func accept(_ packet: [String: WireValue], workspace: String) throws {
        switch packet["type"]?.string {
        case "begin": guard let metadata = packet["metadata"]?.object else { throw CaptureFailure.sequence }; try begin(metadata, workspace: workspace)
        case "bytes":
            guard let id = packet["attemptId"]?.string, let kind = packet["body"]?.string,
                  let offset = packet["offset"]?.number, offset >= 0, offset <= 67_108_864, offset.rounded() == offset,
                  let base64 = packet["bytes"]?.string, base64.utf8.count <= 43_692, let bytes = Data(base64Encoded: base64),
                  try record(id)["workspace"]?.string == workspace else { throw CaptureFailure.sequence }
            try append(attempt: id, kind: kind, offset: Int(offset), bytes: bytes)
        case "finish", "metadata":
            guard let metadata = packet["metadata"]?.object, let id = metadata["attemptId"]?.string,
                  try record(id)["workspace"]?.string == workspace else { throw CaptureFailure.sequence }
            if packet["type"]?.string == "finish" { try finish(metadata) } else { try update(metadata) }
        case "links":
            let db = try ready()
            guard let id = packet["attemptId"]?.string, try record(id)["workspace"]?.string == workspace else { throw CaptureFailure.sequence }
            try db.transaction { try link(packet, id: id, db: db) }
        case "events":
            let db = try ready()
            guard let id = packet["attemptId"]?.string, try record(id)["workspace"]?.string == workspace,
                  let number = packet["offset"]?.number, number >= 0, number.rounded() == number,
                  let events = packet["events"]?.array, events.count <= 128, number + Double(events.count) <= 4096,
                  (try db.rows("SELECT COUNT(*) AS n FROM event_indices WHERE attempt=?", [.text(id)]).first?["n"]?.number ?? 0) == Int64(number),
                  try eventIndexCountNow() + Int64(events.count) <= 100_000 else { throw CaptureFailure.quota }
            try db.transaction {
                for (offset, value) in events.enumerated() {
                    guard let event = value.object, Set(event.keys) == ["type", "start", "end", "observedAt"],
                          let type = event["type"]?.string, type.utf8.count <= 128,
                          let start = event["start"]?.number, let end = event["end"]?.number, start >= 0, end >= start, end <= 67_108_864,
                          event["observedAt"]?.number != nil else { throw CaptureFailure.sequence }
                    try db.execute("INSERT INTO event_indices VALUES(?,?,?)", [.text(id), .integer(Int64(number) + Int64(offset)), .blob(try JSONEncoder().encode(value))])
                }
            }
            if let count = eventIndexCount { eventIndexCount = count + Int64(events.count) }
        case "interrupted":
            let db = try ready()
            for row in try db.rows("SELECT id FROM attempts WHERE workspace=? AND outcome='running'", [.text(workspace)]) {
                let id = try archiveText(row, "id")
                var metadata = try self.metadata(attempt: id)
                guard metadata["hostEpoch"] == packet["hostEpoch"] else { continue }
                metadata["outcome"] = .string("interrupted"); metadata["modelOutcome"] = .string("interrupted")
                try finish(metadata)
            }
        default: throw CaptureFailure.sequence
        }
    }
    func metadata(attempt id: String) throws -> [String: WireValue] {
        let db = try ready(), row = try record(id)
        return try metadata(row: row, bodies: try db.rows("SELECT * FROM bodies WHERE attempt=?", [.text(id)]))
    }
    /// Projects one already-fetched attempt row and its already-fetched body
    /// descriptors. Listing a page used to re-query both per row.
    private func metadata(row: [String: CaptureSQLValue], bodies: [[String: CaptureSQLValue]]) throws -> [String: WireValue] {
        let id = try archiveText(row, "id")
        guard UUID(uuidString: id) != nil else { throw CaptureFailure.corrupt }
        guard let bytes = row["metadata"]?.data else { throw CaptureFailure.corrupt }
        var value = try JSONDecoder().decode([String: WireValue].self, from: bytes)
        value["workspaceId"] = .string(try archiveText(row, "workspace")); value["outcome"] = .string(try archiveText(row, "outcome"))
        value["storageVersion"] = .number(5); value["metricsRetained"] = .bool(row["metrics_retained"]?.number == 1)
        for body in bodies {
            let kind = try archiveText(body, "kind")
            guard ["request", "response"].contains(kind) else { throw CaptureFailure.corrupt }
            var descriptor = value[kind]?.object ?? [:]
            guard let storage = body["storage"]?.string.flatMap(CaptureStorageFormat.init(rawValue:)) else { throw CaptureFailure.corrupt }
            descriptor["state"] = .string(try archiveText(body, "state"))
            descriptor["reason"] = .string(body["reason"]?.string ?? "")
            let observed = try archiveNumber(body, "observed"), length = try archiveNumber(body, "length")
            guard observed >= 0, observed <= 1_073_741_824,
                  length >= 0, length <= (kind == "request" ? 33_554_432 : 67_108_864) else { throw CaptureFailure.corrupt }
            descriptor["observedBytes"] = .number(Double(observed))
            descriptor["retainedBytes"] = .number(Double(length))
            descriptor["storage"] = .string(storage.rawValue)
            value[kind] = .object(descriptor)
            if let stored = body["digest"]?.data {
                let digest: Data
                switch storage {
                case .plaintext: digest = stored
                case .legacyEncrypted:
                    guard let legacyCipher else { throw CaptureFailure.legacyKeyUnavailable }
                    digest = try legacyCipher.open(stored, context: id + ":" + kind)
                }
                guard digest.count == 32 else { throw CaptureFailure.corrupt }
                let transformed = (descriptor["credentialRedactions"]?.number ?? 0) > 0
                value[kind + "Hash"] = .object(["sha256": .string(CaptureContent.hex(digest)), "scope": .string(transformed ? (kind == "request" ? "retained credential-hashed bytes" : "retained credential-masked bytes") : "retained bytes")])
            } else { value[kind + "Hash"] = .null }
        }
        return value
    }
    func list(sessionID: String, messageID: String? = nil, workspaceID: String? = nil, offset: Int = 0) throws -> [[String: WireValue]] {
        let db = try ready(); guard offset >= 0, offset <= 100_000 else { throw CaptureFailure.unavailable }
        if let workspaceID { guard !workspaceID.isEmpty, workspaceID.utf8.count <= 128 else { throw CaptureFailure.unavailable } }
        try reconcile()
        var sql = "SELECT id FROM attempts WHERE session=?", values: [CaptureSQLValue] = [.text(sessionID)]
        // Side snapshots preserve source message IDs. Their originating parent
        // requests and later child-context requests share these links, even
        // before the side dispatches its first request. Workspace scope prevents
        // unrelated histories with the same message ID entering this lookup.
        if messageID != nil, let workspaceID { sql = "SELECT id FROM attempts WHERE workspace=?"; values = [.text(workspaceID)] }
        if let messageID { sql += " AND id IN (SELECT attempt FROM message_links WHERE message=?)"; values.append(.text(messageID)) }
        sql += " ORDER BY wall DESC,id DESC LIMIT 128 OFFSET ?"; values.append(.integer(Int64(offset)))
        // Two statements for the page, not two per row: the inspector polls
        // this once a second, and 128 ids used to cost 257 statements and a
        // re-read of every attempt's metadata blob.
        let rows = try db.rows(sql.replacingOccurrences(of: "SELECT id FROM attempts", with: "SELECT * FROM attempts"), values)
        guard !rows.isEmpty else { return [] }
        let ids = try rows.map { try archiveText($0, "id") }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var descriptors: [String: [[String: CaptureSQLValue]]] = [:]
        for body in try db.rows("SELECT * FROM bodies WHERE attempt IN (\(placeholders))", ids.map { CaptureSQLValue.text($0) }) {
            descriptors[try archiveText(body, "attempt"), default: []].append(body)
        }
        return try zip(rows, ids).map { try metadata(row: $0, bodies: descriptors[$1] ?? []) }
    }
    func eventIndices(attemptID: String, offset: Int) throws -> [String: WireValue] {
        let db = try ready(); _ = try record(attemptID)
        guard offset >= 0, offset <= 4096 else { throw CaptureFailure.sequence }
        let rows = try db.rows("SELECT value FROM event_indices WHERE attempt=? AND ordinal>=? ORDER BY ordinal LIMIT 128", [.text(attemptID), .integer(Int64(offset))])
        return ["events": .array(try rows.map {
                    guard let data = $0["value"]?.data,
                          let value = try? JSONDecoder().decode(WireValue.self, from: data) else { throw CaptureFailure.corrupt }
                    return value
                }),
                "total": .number(Double(try db.rows("SELECT COUNT(*) AS n FROM event_indices WHERE attempt=?", [.text(attemptID)]).first?["n"]?.number ?? 0)),
                "boundary": .string("SSE byte offsets into the original response. Indices are bounded to 4096 per request / 100000 globally and expire with bodies; omitted counts are in request metadata.")]
    }
    /// Message ids linked to an attempt: produced messages first, then the
    /// context messages it consumed. Empty when links were never recorded.
    func linkedMessages(attemptID: String) throws -> (output: [String], context: [String], turn: String?) {
        let db = try ready(); let attempt = try record(attemptID)
        // Read outputs first: a large input context must not crowd out
        // the answer. The turn is the navigation fallback, not a lexically last UUID.
        let rows = try db.rows("SELECT message,role FROM message_links WHERE attempt=? ORDER BY CASE WHEN role='output' THEN 0 ELSE 1 END,message LIMIT 256", [.text(attemptID)])
        var output: [String] = [], context: [String] = []
        for row in rows {
            guard let message = row["message"]?.string else { continue }
            if row["role"]?.string == "output" { output.append(message) } else { context.append(message) }
        }
        let turn = attempt["turn"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        return (output, context, turn)
    }

    func messageLinks(attemptID: String, offset: Int) throws -> [String: WireValue] {
        let db = try ready(); _ = try record(attemptID)
        guard offset >= 0, offset <= 100_000 else { throw CaptureFailure.sequence }
        let rows = try db.rows("SELECT message,role FROM message_links WHERE attempt=? ORDER BY role,message LIMIT 128 OFFSET ?", [.text(attemptID), .integer(Int64(offset))])
        return ["links": .array(try rows.map { .object(["messageId": .string(try archiveText($0, "message")), "relationship": .string(try archiveText($0, "role"))]) }),
                "total": .number(Double(try db.rows("SELECT COUNT(*) AS n FROM message_links WHERE attempt=?", [.text(attemptID)]).first?["n"]?.number ?? 0))]
    }
    private func readChunk(scope: String, id: String, count: Int) throws -> Data {
        let db = try ready()
        guard scope.count == 64, id.count == 64, scope.allSatisfy(\.isHexDigit), id.allSatisfy(\.isHexDigit), count > 0, count <= CaptureChunker.maximum,
              let row = try db.rows("SELECT length,bytes,storage FROM chunks WHERE scope=? AND id=?", [.text(scope), .text(id)]).first,
              row["length"]?.number == Int64(count),
              let storage = row["storage"]?.string.flatMap(CaptureStorageFormat.init(rawValue:)) else { throw CaptureFailure.corrupt }
        let storedLength = count + (storage == .legacyEncrypted ? 28 : 0)
        guard row["bytes"]?.number == Int64(storedLength) else { throw CaptureFailure.corrupt }
        let file = root.appendingPathComponent("chunks/" + scope + "/" + id)
        let fd = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CaptureFailure.corrupt }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size == storedLength else { throw CaptureFailure.corrupt }
        let stored = try handle.read(upToCount: CaptureChunker.maximum + 29) ?? Data()
        let bytes: Data, verifiedID: String
        switch storage {
        case .plaintext:
            bytes = stored; verifiedID = CaptureContent.chunkID(bytes, scope: scope)
        case .legacyEncrypted:
            guard let legacyCipher else { throw CaptureFailure.legacyKeyUnavailable }
            bytes = try legacyCipher.open(stored, context: scope + ":" + id)
            verifiedID = legacyCipher.chunkID(bytes, scope: scope)
        }
        guard bytes.count == count, verifiedID == id else { throw CaptureFailure.corrupt }; return bytes
    }
    func body(attemptID: String, body: String, offset: Int) throws -> Data {
        let db = try ready(); _ = try record(attemptID)
        guard ["request", "response"].contains(body), let descriptor = try db.rows("SELECT * FROM bodies WHERE attempt=? AND kind=?", [.text(attemptID), .text(body)]).first,
              !["expired", "purged", "not-retained", "credential-omitted"].contains(descriptor["state"]?.string ?? "") else { throw CaptureFailure.unavailable }
        let length = try archiveNumber(descriptor, "length")
        guard length >= 0, length <= (body == "request" ? 33_554_432 : 67_108_864) else { throw CaptureFailure.corrupt }
        guard offset >= 0, offset <= length else { throw CaptureFailure.unavailable }
        let end = min(Int(length), offset + 32_768)
        var output = Data(), position = offset
        for ref in try db.rows("SELECT * FROM refs WHERE attempt=? AND kind=? AND offset<? AND offset+length>? ORDER BY ordinal", [.text(attemptID), .text(body), .integer(Int64(end)), .integer(Int64(offset))]) {
            let start = Int(try archiveNumber(ref, "offset")), count = Int(try archiveNumber(ref, "length"))
            guard start >= 0, start <= position, count > 0, count <= CaptureChunker.maximum,
                  count <= Int(length) - start, start + count > position else { throw CaptureFailure.corrupt }
            let bytes: Data
            do { bytes = try readChunk(scope: try archiveText(ref, "scope"), id: try archiveText(ref, "chunk"), count: count) }
            catch {
                try? db.execute("UPDATE bodies SET state='corrupt',reason='Chunk integrity failed; no repair attempted' WHERE attempt=? AND kind=?", [.text(attemptID), .text(body)])
                throw error
            }
            let stop = min(end, start + count); output.append(bytes.subdata(in: (position - start)..<(stop - start))); position = stop
        }
        guard position == end else { throw CaptureFailure.corrupt }; return output
    }
    /// Whole-body display walks the ordered manifest once. Repeated calls to
    /// the compatibility range API would rescan all references for every page.
    /// No retention lease is held: expiry/purge or a changing writer causes an
    /// explicit failure rather than a fabricated complete read.
    func completeBody(attemptID: String, body: String,
                      progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> Data {
        try Task.checkCancellation()
        guard ["request", "response"].contains(body) else { throw CaptureFailure.unavailable }
        let db = try ready(), before = try metadata(attempt: attemptID)
        guard let descriptor = before[body]?.object,
              ["complete", "credential-hashed", "credential-masked", "partial", "truncated", "interrupted", "recording"].contains(descriptor["state"]?.string ?? ""),
              let length = descriptor["retainedBytes"]?.number, length.isFinite, length >= 0,
              length.rounded() == length, length <= Double(body == "request" ? 33_554_432 : 67_108_864) else { throw CaptureFailure.unavailable }
        let count = Int(length)
        let references = try db.rows("SELECT * FROM refs WHERE attempt=? AND kind=? ORDER BY ordinal", [.text(attemptID), .text(body)])
        var output = Data(), hasher = SHA256(), lastProgress = 0
        output.reserveCapacity(count)
        for (ordinal, ref) in references.enumerated() {
            try Task.checkCancellation()
            guard ref["ordinal"]?.number == Int64(ordinal), ref["offset"]?.number == Int64(output.count),
                  let length = ref["length"]?.number, length > 0, length <= CaptureChunker.maximum,
                  length <= count - output.count, let scope = ref["scope"]?.string, let id = ref["chunk"]?.string else { throw CaptureFailure.corrupt }
            let bytes: Data
            do { bytes = try readChunk(scope: scope, id: id, count: Int(length)) }
            catch {
                try? db.execute("UPDATE bodies SET state='corrupt',reason='Chunk integrity failed; no repair attempted' WHERE attempt=? AND kind=?", [.text(attemptID), .text(body)])
                throw error
            }
            output.append(bytes); hasher.update(data: bytes)
            if output.count - lastProgress >= 131_072 || output.count == count {
                lastProgress = output.count
                await progress(output.count, count)
                await Task.yield()
            }
        }
        try Task.checkCancellation()
        guard output.count == count else { throw CaptureFailure.corrupt }
        if let expected = before[body + "Hash"]?.object?["sha256"]?.string {
            guard CaptureContent.hex(hasher.finalize()) == expected else {
                try? db.execute("UPDATE bodies SET state='corrupt',reason='Body digest integrity failed; no repair attempted' WHERE attempt=? AND kind=?", [.text(attemptID), .text(body)])
                throw CaptureFailure.corrupt
            }
        }
        let after = try metadata(attempt: attemptID)
        guard before[body] == after[body], before[body + "Hash"] == after[body + "Hash"] else { throw TraceError.changed }
        await progress(count, count)
        try Task.checkCancellation()
        return output
    }
    func clear(sessionID: String) throws {
        let db = try ready()
        let ids = try db.rows("SELECT id FROM attempts WHERE session=?", [.text(sessionID)]).compactMap { $0["id"]?.string }
        guard ids.allSatisfy({ !leases.contains($0) && !writers.keys.contains(writerKey($0, "request")) && !writers.keys.contains(writerKey($0, "response")) }) else { throw CaptureFailure.busy }
        for id in ids { try evict(id, state: "purged") }; try collectGarbage()
    }
    func purge(attemptID: String) throws { _ = try record(attemptID); try evict(attemptID, state: "purged"); try collectGarbage() }
    private func eventIndexCountNow() throws -> Int64 {
        if let eventIndexCount { return eventIndexCount }
        let value = try ready().rows("SELECT COUNT(*) AS n FROM event_indices").first?["n"]?.number ?? 0
        eventIndexCount = value
        return value
    }
    private func evict(_ id: String, state: String) throws {
        let db = try ready(); guard !leases.contains(id), writers[writerKey(id, "request")] == nil, writers[writerKey(id, "response")] == nil else { throw CaptureFailure.busy }
        try db.transaction {
            try db.execute("DELETE FROM refs WHERE attempt=?", [.text(id)])
            try db.execute("DELETE FROM event_indices WHERE attempt=?", [.text(id)])
            eventIndexCount = nil
            try db.execute("UPDATE bodies SET state=?,reason='Body retention ended; request metrics retained',length=0,digest=NULL WHERE attempt=?", [.text(state), .text(id)])
        }
    }
    private func chunkTotalsNow() throws -> (count: Int64, bytes: Int64) {
        if let chunkTotals { return chunkTotals }
        let row = try ready().rows("SELECT COUNT(*) AS n, COALESCE(SUM(bytes),0) AS stored FROM chunks").first
        let value = (row?["n"]?.number ?? 0, row?["stored"]?.number ?? 0)
        chunkTotals = value
        return value
    }
    private func reserve(_ bytes: Int64) throws {
        let db = try ready()
        guard try chunkTotalsNow().count < 100_000 else { throw CaptureFailure.quota }
        if try chunkTotalsNow().bytes + bytes <= quota { return }
        for row in try db.rows("SELECT id FROM attempts WHERE outcome!='running' AND id IN (SELECT attempt FROM refs) ORDER BY wall") {
            let id = try archiveText(row, "id"); if leases.contains(id) { continue }
            try evict(id, state: "expired"); try collectGarbage()
            if try chunkTotalsNow().bytes + bytes <= quota { return }
        }
        throw CaptureFailure.quota
    }
    func reconcile() throws {
        let db = try ready(), time = now().timeIntervalSince1970
        guard time > nextReconciliation else { return }
        // One commit for the whole sweep. Each eviction and each expiry used to
        // be its own transaction, which under synchronous=FULL is one fsync per
        // row: an overdue sweep of a large archive froze the app for minutes.
        // Ids first, bodies per row, so the expiring set is never materialised
        // with its metadata blobs at once.
        try db.transaction {
        for row in try db.rows("SELECT id FROM attempts WHERE outcome!='running' AND wall<? AND id IN (SELECT attempt FROM refs)", [.real(time - bodyRetention)]) {
            let id = try archiveText(row, "id"); if !leases.contains(id) { try evict(id, state: "expired") }
        }
        for expiring in try db.rows("SELECT id FROM attempts WHERE outcome!='running' AND metrics_retained=1 AND wall<?", [.real(time - metricRetention)]) {
            let id = try archiveText(expiring, "id")
            guard !leases.contains(id) else { continue }
            let row = try record(id)
            // Keep the relationship after metrics expire. Old chat messages
            // resolve to an explicit tombstone, never an invented HTTP body.
            var tombstone: [String: WireValue] = ["attemptId": .string(id), "sessionId": .string(try archiveText(row, "session")), "turnId": .string(try archiveText(row, "turn")), "purpose": .string(try archiveText(row, "purpose")), "api": .string(try archiveText(row, "api")), "requestedModel": .string(try archiveText(row, "alias")), "metricsExpired": .bool(true), "notice": .string("Request metrics retention expired; payload availability and original message relationships are retained independently.")]
            // These describe the retained body, not request telemetry. Keep
            // credential transformations visible for the body's own lifetime.
            if let data = row["metadata"]?.data {
                let previous = try JSONDecoder().decode([String: WireValue].self, from: data)
                for kind in ["request", "response"] {
                    let annotations = (previous[kind]?.object ?? [:]).filter { ["captureBytes", "credentialRedactions", "byteExact", "transformations"].contains($0.key) }
                    if !annotations.isEmpty { tombstone[kind] = .object(annotations) }
                }
            }
            try db.execute("UPDATE attempts SET metrics_retained=0,dispatch=NULL,ttft_ms=NULL,stream_ms=NULL,request_ms=NULL,http_ms=NULL,model=NULL,identity_status='expired',reported_models=NULL,response_model=NULL,cost_usd=NULL,cost_status='unreported',cache_read_tokens=NULL,cache_write_tokens=NULL,input_tokens=NULL,output_tokens=NULL,reasoning_tokens=NULL,reasoning_cost_usd=NULL,reasoning_cost_status='unreported',cache_status='unreported',metadata=? WHERE id=?", [.blob(try JSONEncoder().encode(tombstone)), .text(id)])
        }
        }
        try collectGarbage()
        let nextBody = try db.rows("SELECT MIN(wall) AS wall FROM attempts WHERE outcome!='running' AND id IN (SELECT attempt FROM refs)").first?["wall"]?.double.map { $0 + bodyRetention }
        let nextMetrics = try db.rows("SELECT MIN(wall) AS wall FROM attempts WHERE outcome!='running' AND metrics_retained=1").first?["wall"]?.double.map { $0 + metricRetention }
        // An export lease may temporarily defer an overdue request; retry at
        // most once a second, and immediately after releasing the lease.
        let deadline = [nextBody, nextMetrics].compactMap { $0 }.min() ?? .infinity
        nextReconciliation = deadline <= time ? time + 1 : deadline
        didReconcile()
    }
    private func collectGarbage(scanOrphans: Bool = false) throws {
        let db = try ready()
        for row in try db.rows("SELECT scope,id FROM chunks WHERE NOT EXISTS (SELECT 1 FROM refs WHERE refs.scope=chunks.scope AND refs.chunk=chunks.id)") {
            guard let scope = row["scope"]?.string, let id = row["id"]?.string, scope.count == 64, id.count == 64, scope.allSatisfy(\.isHexDigit), id.allSatisfy(\.isHexDigit) else { throw CaptureFailure.corrupt }
            let file = try root.appendingPathComponent("chunks/" + archiveText(row, "scope") + "/" + archiveText(row, "id"))
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        try db.execute("DELETE FROM chunks WHERE NOT EXISTS (SELECT 1 FROM refs WHERE refs.scope=chunks.scope AND refs.chunk=chunks.id)")
        chunkTotals = nil
        guard scanOrphans else { return }
        let valid = Set(try db.rows("SELECT scope,id FROM chunks").map { try archiveText($0, "scope") + "/" + archiveText($0, "id") })
        let folder = root.appendingPathComponent("chunks", isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) { guard (try folder.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw CaptureFailure.corrupt } }
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return }
        for case let file as URL in enumerator {
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if info.isSymbolicLink == true { throw CaptureFailure.corrupt }
            if info.isRegularFile == true, !valid.contains(file.deletingLastPathComponent().lastPathComponent + "/" + file.lastPathComponent) { try FileManager.default.removeItem(at: file) }
        }
    }
    func exportRetained(sessionID: String, attemptID: String, destination: URL) async throws -> URL {
        let metadata = try metadata(attempt: attemptID)
        guard metadata["sessionId"]?.string == sessionID, metadata["outcome"]?.string != "running", !leases.contains(attemptID) else { throw CaptureFailure.busy }
        leases.insert(attemptID); defer { leases.remove(attemptID); nextReconciliation = -Double.infinity }
        let staging = destination.appendingPathComponent(".partial-" + UUID().uuidString), final = destination.appendingPathComponent(attemptID)
        guard !FileManager.default.fileExists(atPath: final.path) else { throw CaptureFailure.unavailable }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var published = false; defer { if !published { try? FileManager.default.removeItem(at: staging) } }
        for kind in ["request", "response"] {
            let length = Int(metadata[kind]?.object?["retainedBytes"]?.number ?? 0)
            guard metadata[kind + "Hash"]?.object?["sha256"]?.string != nil else { continue }
            let file = staging.appendingPathComponent(kind + ".bin")
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CaptureFailure.unavailable }
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            var offset = 0, hasher = SHA256()
            while offset < length {
                let bytes = try body(attemptID: attemptID, body: kind, offset: offset)
                guard !bytes.isEmpty else { throw CaptureFailure.corrupt }
                try handle.write(contentsOf: bytes); hasher.update(data: bytes); offset += bytes.count
                await exportDidReadPage(); try Task.checkCancellation()
            }
            guard CaptureContent.hex(hasher.finalize()) == metadata[kind + "Hash"]?.object?["sha256"]?.string else { throw CaptureFailure.corrupt }
            try handle.synchronize()
        }
        try Data(WireValue.object(metadata).pretty.utf8).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.appendingPathComponent("manifest.json").path)
        try FileManager.default.moveItem(at: staging, to: final); published = true; return final
    }
    /// Full-scan rows this archive's database has visited so far (tests only).
    func scannedRows() throws -> Int { try ready().scannedRows }
    /// Statements prepared and top-level transactions opened (tests only).
    func statementCount() throws -> Int { try ready().statements }
    func commitCount() throws -> Int { try ready().commits }
    func statistics() throws -> [String: Int64] {
        let db = try ready()
        return ["chunks": try db.rows("SELECT COUNT(*) AS n FROM chunks").first?["n"]?.number ?? 0,
                "storedBytes": try db.rows("SELECT COALESCE(SUM(bytes),0) AS n FROM chunks").first?["n"]?.number ?? 0,
                "legacyEncryptedBytes": try db.rows("SELECT COALESCE(SUM(bytes),0) AS n FROM chunks WHERE storage='aes-gcm-v1'").first?["n"]?.number ?? 0,
                "logicalBytes": try db.rows("SELECT COALESCE(SUM(length),0) AS n FROM refs").first?["n"]?.number ?? 0,
                "attempts": try db.rows("SELECT COUNT(*) AS n FROM attempts WHERE metrics_retained=1").first?["n"]?.number ?? 0,
                "expiredRequests": try db.rows("SELECT COUNT(*) AS n FROM attempts WHERE metrics_retained=0").first?["n"]?.number ?? 0]
    }
    func close() async throws {
        guard leases.isEmpty else { throw CaptureFailure.busy }
        if let closeTask { await closeTask.value; return }
        let reader = reportReader; reportReader = nil
        usageReadGeneration &+= 1
        usageSnapshots.removeAll()
        // Reject new writer/report work while the old read queue drains.
        writers.removeAll(); database = nil; legacyCipher = nil; nextReconciliation = -Double.infinity
        chunkTotals = nil; eventIndexCount = nil
        // Concurrent shutdown callers share one drain. Its task owns cleanup,
        // so no second close can release the workspace lock before the reader
        // finishes, or release a newly reopened archive's ownership afterward.
        let task = Task {
            await reader?.close()
            ownership = nil
            closeTask = nil
        }
        closeTask = task
        await task.value
    }
}

/// A NOT NULL column that is missing or mistyped means the archive is damaged:
/// a recoverable error for the caller, never a trap in a release build.
private func archiveText(_ row: [String: CaptureSQLValue], _ key: String) throws -> String {
    guard let value = row[key]?.string else { throw CaptureFailure.corrupt }
    return value
}
private func archiveNumber(_ row: [String: CaptureSQLValue], _ key: String) throws -> Int64 {
    guard let value = row[key]?.number else { throw CaptureFailure.corrupt }
    return value
}
