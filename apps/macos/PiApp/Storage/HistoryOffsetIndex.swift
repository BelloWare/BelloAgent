import Foundation
import SQLite3

struct HistoryOffset: Codable, Equatable {
    var id: String; var parent: String?; var offset: UInt64; var length: Int; var type: String?
    var fromMessageID: String?; var keptIDs: [String]?; var role: String? = nil
    var presentation = false
    var adopted = false
    var calls: [String]? = nil; var resultCall: String? = nil; var operationID: String? = nil
    var selectedPrefix: [String]? = nil; var contextSelection: [String]? = nil
    /// The row opens a display turn (`HistoryWindowPolicy.startsTurn`):
    /// where a transcript page may start or end.
    var turnStart: Bool? = nil
    var taskKey: String? = nil
}

/// The index's own encoding of a row: its fields, length-prefixed, no body.
/// Encoding and decoding a row through JSON for every record and every
/// lookup was most of the cost of indexing a long journal.
extension HistoryOffset {
    private enum Present: UInt16 {
        case parent = 1, type = 2, from = 4, kept = 8, role = 16, presentation = 32, adopted = 64, calls = 128
        case result = 256, operation = 512, prefix = 1024, selection = 2048, turn = 4096, turnStart = 8192, task = 16384
    }
    var indexPayload: [UInt8] {
        var bytes: [UInt8] = [], flags: UInt16 = 0
        bytes.reserveCapacity(64 + id.utf8.count)
        func flag(_ value: Present, _ on: Bool) { if on { flags |= value.rawValue } }
        flag(.parent, parent != nil); flag(.type, type != nil); flag(.from, fromMessageID != nil); flag(.kept, keptIDs != nil)
        flag(.role, role != nil); flag(.presentation, presentation); flag(.adopted, adopted); flag(.calls, calls != nil)
        flag(.result, resultCall != nil); flag(.operation, operationID != nil); flag(.prefix, selectedPrefix != nil)
        flag(.selection, contextSelection != nil); flag(.turn, turnStart != nil); flag(.turnStart, turnStart == true); flag(.task, taskKey != nil)
        bytes.append(UInt8(flags & 0xFF)); bytes.append(UInt8(flags >> 8))
        func number(_ value: UInt64) {
            var value = value
            while value >= 0x80 { bytes.append(UInt8(value & 0x7F) | 0x80); value >>= 7 }
            bytes.append(UInt8(value))
        }
        func text(_ value: String) { number(UInt64(value.utf8.count)); bytes.append(contentsOf: value.utf8) }
        func texts(_ values: [String]) { number(UInt64(values.count)); for value in values { text(value) } }
        number(offset); number(UInt64(bitPattern: Int64(length))); text(id)
        if let parent { text(parent) }; if let type { text(type) }; if let fromMessageID { text(fromMessageID) }
        if let keptIDs { texts(keptIDs) }; if let role { text(role) }; if let calls { texts(calls) }
        if let resultCall { text(resultCall) }; if let operationID { text(operationID) }
        if let selectedPrefix { texts(selectedPrefix) }; if let contextSelection { texts(contextSelection) }
        if let taskKey { text(taskKey) }
        return bytes
    }
    init(indexPayload raw: UnsafeRawBufferPointer) throws {
        var at = 0
        func byte() throws -> UInt8 {
            guard at < raw.count else { throw StoreError.unreadableRecord }
            defer { at += 1 }
            return raw[at]
        }
        func number() throws -> UInt64 {
            var value: UInt64 = 0, shift: UInt64 = 0
            while true {
                let next = try byte()
                guard shift < 64 else { throw StoreError.unreadableRecord }
                value |= UInt64(next & 0x7F) << shift
                if next < 0x80 { return value }
                shift += 7
            }
        }
        func text() throws -> String {
            guard let count = Int(exactly: try number()), count <= raw.count - at else { throw StoreError.unreadableRecord }
            defer { at += count }
            return String(decoding: UnsafeRawBufferPointer(rebasing: raw[at..<at + count]), as: UTF8.self)
        }
        func texts() throws -> [String] {
            guard let count = Int(exactly: try number()), count <= raw.count - at else { throw StoreError.unreadableRecord }
            var values: [String] = []; values.reserveCapacity(count)
            for _ in 0..<count { values.append(try text()) }
            return values
        }
        let low = try byte(), high = try byte()
        let flags = UInt16(low) | UInt16(high) << 8
        func has(_ value: Present) -> Bool { flags & value.rawValue != 0 }
        offset = try number(); length = Int(Int64(bitPattern: try number())); id = try text()
        parent = try has(.parent) ? text() : nil; type = try has(.type) ? text() : nil
        fromMessageID = try has(.from) ? text() : nil; keptIDs = try has(.kept) ? texts() : nil
        role = try has(.role) ? text() : nil; calls = try has(.calls) ? texts() : nil
        resultCall = try has(.result) ? text() : nil; operationID = try has(.operation) ? text() : nil
        selectedPrefix = try has(.prefix) ? texts() : nil; contextSelection = try has(.selection) ? texts() : nil
        taskKey = try has(.task) ? text() : nil
        presentation = has(.presentation); adopted = has(.adopted)
        turnStart = has(.turn) ? has(.turnStart) : nil
        guard at == raw.count else { throw StoreError.unreadableRecord }
    }
}

/// Rebuildable read-only source index. Offset/branch tables spill to a private
/// temporary database, not the source journal. SQLite's page cache is bounded;
/// no 100k-record prefix can impersonate the latest conversation anymore.
///
/// Its file lives as long as the index: removed when the reader lets go of
/// it and when the app quits (`HistoryReader.releaseIndexes`). The name
/// carries the process id, so a later launch can tell a file a crashed app
/// left from one a running copy is reading (`HistoryIndexFiles`). The file
/// must keep its name while open: Apple's SQLite takes a database unlinked
/// while in use for corruption and cuts its descriptor off, and an anonymous
/// temporary database would be held in memory instead of on disk.
final class HistoryOffsetIndex: @unchecked Sendable {
    static let filePrefix = "bello-history-"
    private var db: OpaquePointer?
    private let path: URL
    private(set) var count = 0
    private(set) var recordCount = 0
    private(set) var lineage = "root"
    private var nextOrdinal = 0
    /// Statements prepared once and reset after every use (`run`). Preparing
    /// each lookup and insert again cost more than running it.
    private var statements: [String: OpaquePointer] = [:]
    /// Whether every row was inserted with the row inserted before it as its
    /// parent, the first with none: then the chain from the last row is the
    /// rows in insertion order, and replaying it needs no walk (`replayChain`).
    private var insertedAsChain = true, lastInserted: String?, chainInInsertionOrder = false
    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
    init(directory: URL = FileManager.default.temporaryDirectory) throws {
        path = directory.appendingPathComponent(Self.filePrefix + "p\(getpid())-" + UUID().uuidString + ".sqlite")
        guard sqlite3_open(path.path, &db) == SQLITE_OK else { throw StoreError.unreadableRecord }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        try execute("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA cache_size=-512; PRAGMA temp_store=FILE; CREATE TABLE refs(id TEXT PRIMARY KEY, payload BLOB NOT NULL); CREATE TABLE chain(n INTEGER PRIMARY KEY, id TEXT NOT NULL); CREATE TABLE visible(n INTEGER PRIMARY KEY, id TEXT UNIQUE NOT NULL, role TEXT, turn INTEGER); CREATE TABLE seen(id TEXT PRIMARY KEY); CREATE TABLE links(id TEXT, kind TEXT, value TEXT, n INTEGER, PRIMARY KEY(id,kind,value)); CREATE INDEX link_values ON links(kind,value,n); BEGIN")
    }
    deinit { releaseStatements(); sqlite3_close(db); try? FileManager.default.removeItem(at: path) }
    private func releaseStatements() { for statement in statements.values { sqlite3_finalize(statement) }; statements.removeAll() }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.unreadableRecord }
    }
    private func query(_ sql: String, strings: [String] = [], data: Data? = nil) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw StoreError.unreadableRecord }
        for (i, value) in strings.enumerated() { sqlite3_bind_text(statement, Int32(i + 1), value, Int32(value.utf8.count), Self.transient) }
        if let data { _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(strings.count + 1), $0.baseAddress, Int32($0.count), Self.transient) } }
        return statement
    }
    private func done(_ statement: OpaquePointer) throws {
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.unreadableRecord }
    }
    private func next(_ statement: OpaquePointer) throws -> Bool {
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw StoreError.unreadableRecord }
        return status == SQLITE_ROW
    }
    /// One cached statement: `bind` binds it, `body` steps it, and it is
    /// reset either way, so it never holds a cursor past its own use.
    private func run<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        let statement: OpaquePointer
        if let cached = statements[sql] { statement = cached }
        else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &prepared, nil) == SQLITE_OK, let prepared else { throw StoreError.unreadableRecord }
            statements[sql] = prepared; statement = prepared
        }
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        return try body(statement)
    }
    @inline(__always) private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, Int32(value.utf8.count), Self.transient)
    }
    @inline(__always) private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int) { sqlite3_bind_int64(statement, index, Int64(value)) }
    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.unreadableRecord }
    }
    private func row(_ statement: OpaquePointer) throws -> Bool { try next(statement) }
    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }
    private static func payload(_ statement: OpaquePointer, _ column: Int32) throws -> HistoryOffset {
        guard let bytes = sqlite3_column_blob(statement, column) else { throw StoreError.unreadableRecord }
        return try HistoryOffset(indexPayload: UnsafeRawBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))))
    }
    /// One query's completed projections and small ownership facts. Payloads
    /// are never retained here. Use the private index file's bounded pager:
    /// macOS SQLite keeps TEMP tables in memory despite temp_store=FILE.
    /// Continuation pages share them; completion, replacement, cancellation
    /// or failure releases the query and drops its tables.
    final class SearchCache {
        struct Match {
            /// -1 is a miss; zero is the empty-query preview.
            var count: Int
            var preview: String
            var drawing: ContentHit.Drawing? = nil
            var omittedOutputs: Set<String>? = nil
        }
        struct Call { var card: Bool; var paired: Bool }
        private let index: HistoryOffsetIndex
        private let name = "search_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        init(_ index: HistoryOffsetIndex) throws {
            self.index = index
            do { try index.execute("CREATE TABLE \(name)(offset INTEGER PRIMARY KEY, count INTEGER, preview TEXT, drawing INTEGER, message TEXT, call TEXT); CREATE TABLE \(name)_calls(offset INTEGER, call TEXT, card INTEGER, paired INTEGER, PRIMARY KEY(offset,call)); CREATE TABLE \(name)_omitted(offset INTEGER, call TEXT, PRIMARY KEY(offset,call))") }
            catch { clear(); throw error }
        }
        deinit { clear() }
        private func clear() { try? index.execute("DROP TABLE IF EXISTS \(name); DROP TABLE IF EXISTS \(name)_calls; DROP TABLE IF EXISTS \(name)_omitted") }
        private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
            guard let bytes = sqlite3_column_text(statement, column) else { return "" }
            return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
        }
        func match(_ offset: UInt64) throws -> Match? {
            let statement = try index.query("SELECT count,preview,drawing,message,call FROM \(name) WHERE offset=\(offset)")
            defer { sqlite3_finalize(statement) }
            guard try index.next(statement) else { return nil }
            let drawing: ContentHit.Drawing? = sqlite3_column_int(statement, 2) == 0 ? nil : .init(messageID: text(statement, 3), toolCallID: text(statement, 4))
            let omitted = try index.query("SELECT call FROM \(name)_omitted WHERE offset=\(offset)")
            defer { sqlite3_finalize(omitted) }
            var calls = Set<String>()
            while try index.next(omitted) { calls.insert(text(omitted, 0)) }
            return .init(count: Int(sqlite3_column_int64(statement, 0)), preview: text(statement, 1), drawing: drawing, omittedOutputs: calls.isEmpty ? nil : calls)
        }
        func store(_ value: Match, at offset: UInt64) throws {
            try index.done(index.query("INSERT OR REPLACE INTO \(name) VALUES(\(offset),\(value.count),?,\(value.drawing == nil ? 0 : 1),?,?)",
                strings: [value.preview, value.drawing?.messageID ?? "", value.drawing?.toolCallID ?? ""]))
            for call in value.omittedOutputs ?? [] { try index.done(index.query("INSERT OR IGNORE INTO \(name)_omitted VALUES(\(offset),?)", strings: [call])) }
        }
        func call(_ call: String, at offset: UInt64) throws -> Call? {
            let statement = try index.query("SELECT card,paired FROM \(name)_calls WHERE offset=\(offset) AND call=?", strings: [call])
            defer { sqlite3_finalize(statement) }
            guard try index.next(statement) else { return nil }
            return .init(card: sqlite3_column_int(statement, 0) != 0, paired: sqlite3_column_int(statement, 1) != 0)
        }
        func store(_ value: Call, call: String, at offset: UInt64) throws {
            try index.done(index.query("INSERT OR REPLACE INTO \(name)_calls VALUES(\(offset),?,\(value.card ? 1 : 0),\(value.paired ? 1 : 0))", strings: [call]))
        }
    }


    func insert(_ ref: HistoryOffset) throws {
        try run("INSERT INTO refs VALUES(?1,?2)") { statement in
            bind(statement, 1, ref.id)
            let payload = ref.indexPayload
            _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), Self.transient) }
            try step(statement)
        }
        // A new row has no links yet and no position: it joins the timeline
        // only when it is appended.
        if ref.calls?.isEmpty == false || ref.resultCall != nil || ref.operationID != nil { try insertLinks(ref, position: nil) }
        if ref.parent != lastInserted { insertedAsChain = false }
        lastInserted = ref.id
        recordCount += 1
    }
    private func insertLinks(_ ref: HistoryOffset, position: Int?) throws {
        func link(_ kind: String, _ value: String) throws {
            try run("INSERT INTO links VALUES(?1,?2,?3,?4)") { statement in
                bind(statement, 1, ref.id); bind(statement, 2, kind); bind(statement, 3, value)
                if let position { bind(statement, 4, position) } else { sqlite3_bind_null(statement, 4) }
                try step(statement)
            }
        }
        for call in Set(ref.calls ?? []) { try link("call", call) }
        if let call = ref.resultCall { try link("result", call) }
        if let operation = ref.operationID { try link("operation", operation) }
    }
    private func replaceLinks(_ ref: HistoryOffset) throws {
        let position = try ordinal(of: ref.id)
        try run("DELETE FROM links WHERE id=?1") { statement in bind(statement, 1, ref.id); try step(statement) }
        try insertLinks(ref, position: position)
    }
    func replaceMetadata(_ ref: HistoryOffset) throws {
        try run("UPDATE refs SET payload=?2 WHERE id=?1") { statement in
            bind(statement, 1, ref.id)
            let payload = ref.indexPayload
            _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), Self.transient) }
            try step(statement)
        }
        try replaceLinks(ref)
    }
    func ref(_ id: String) throws -> HistoryOffset? {
        try run("SELECT payload FROM refs WHERE id=?1") { statement in
            bind(statement, 1, id)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw StoreError.unreadableRecord }
            return try Self.payload(statement, 0)
        }
    }
    /// Whether a row with this id was inserted, without decoding it.
    func contains(_ id: String) throws -> Bool {
        try run("SELECT 1 FROM refs WHERE id=?1") { statement in bind(statement, 1, id); return try row(statement) }
    }
    /// The retained neighbours needed by the row planner, across decode-run
    /// boundaries. Links carry active-branch positions, so each neighbour is
    /// an indexed range seek even when a provider reuses the same call ID.
    func related(to id: String, calls: [String], result: String?, operation: String?) throws -> [HistoryOffset] {
        guard !calls.isEmpty || result != nil || operation != nil, let position = try ordinal(of: id) else { return [] }
        var ids = Set<String>()
        /// The nearest linked row of `kind` and `value` after `after` and
        /// before `before` (either may be nil), first or last.
        func linked(_ kind: String, _ value: String, after: Int? = nil, before: Int? = nil, last: Bool = false) throws -> (String, Int)? {
            let sql = "SELECT v.id,v.n FROM links v WHERE v.kind=?1 AND v.value=?2 AND v.n IS NOT NULL" + (after == nil ? "" : " AND v.n>?3")
                + (before == nil ? "" : " AND v.n<?4") + " ORDER BY v.n " + (last ? "DESC" : "ASC") + " LIMIT 1"
            return try run(sql) { statement in
                bind(statement, 1, kind); bind(statement, 2, value)
                if let after { bind(statement, 3, after) }; if let before { bind(statement, 4, before) }
                guard try row(statement), let text = sqlite3_column_text(statement, 0) else { return nil }
                return (String(cString: text), Int(sqlite3_column_int64(statement, 1)))
            }
        }
        func receipt(_ call: String, after: Int) throws {
            let end = try linked("call", call, after: after)?.1
            if let row = try linked("result", call, after: after, before: end, last: true) { ids.insert(row.0) }
        }
        for call in calls { try receipt(call, after: position) }
        if let result, let issuer = try linked("call", result, before: position, last: true) {
            ids.insert(issuer.0); try receipt(result, after: issuer.1)
        }
        if let operation, let row = try linked("operation", operation) { ids.insert(row.0) }
        ids.remove(id)
        return try ids.compactMap { try ref($0) }
    }
    func constructChain(leaf: String?) throws {
        // Rows inserted each after its parent, up to the leaf: the chain is
        // every row in insertion order (`replayChain` reads them so).
        if insertedAsChain, leaf == lastInserted { chainInInsertionOrder = true; return }
        var id = leaf, ordinal = 0
        while let current = id {
            try Task.checkCancellation()
            guard let ref = try ref(current), ordinal < recordCount else { throw StoreError.unreadableRecord }
            try run("INSERT INTO chain VALUES(?1,?2)") { statement in bind(statement, 1, -ordinal); bind(statement, 2, current); try step(statement) }
            id = ref.parent; ordinal += 1
        }
    }
    func replayChain(_ body: (HistoryOffset) throws -> Void) throws {
        if chainInInsertionOrder {
            let statement = try query("SELECT payload FROM refs ORDER BY rowid"); defer { sqlite3_finalize(statement) }
            while try next(statement) {
                try Task.checkCancellation()
                try body(try Self.payload(statement, 0))
            }
            return
        }
        let statement = try query("SELECT id FROM chain ORDER BY n"); defer { sqlite3_finalize(statement) }
        while try next(statement) {
            try Task.checkCancellation()
            guard let text = sqlite3_column_text(statement, 0), let ref = try ref(String(cString: text)) else { throw StoreError.unreadableRecord }
            try body(ref)
        }
    }
    func hasSeen(_ id: String) throws -> Bool {
        try run("SELECT 1 FROM seen WHERE id=?1") { statement in bind(statement, 1, id); return try row(statement) }
    }
    /// The timeline a partial index starts on: the newest edit marker before
    /// the rows it holds, as the journal's metadata file records it.
    func startLineage(_ id: String?) { lineage = id ?? "root" }
    func append(_ ref: HistoryOffset) throws {
        if ref.type == "branch" { lineage = ref.id }
        try run("INSERT INTO visible VALUES(?1,?2,?3,?4)") { statement in
            bind(statement, 1, nextOrdinal); bind(statement, 2, ref.id); bind(statement, 3, ref.role ?? ""); bind(statement, 4, ref.turnStart == true ? 1 : 0)
            try step(statement)
        }
        try run("INSERT OR IGNORE INTO seen VALUES(?1)") { statement in bind(statement, 1, ref.id); try step(statement) }
        if ref.calls?.isEmpty == false || ref.resultCall != nil || ref.operationID != nil {
            try run("UPDATE links SET n=?1 WHERE id=?2") { statement in bind(statement, 1, nextOrdinal); bind(statement, 2, ref.id); try step(statement) }
        }
        nextOrdinal += 1; count += 1
    }
    func branch(from: String?, kept: [String]) throws {
        if let from, let position = try ordinal(of: from) { try execute("DELETE FROM visible WHERE n>=\(position)") }
        else {
            try execute("CREATE TEMP TABLE kept(id TEXT PRIMARY KEY)")
            for id in kept { try done(query("INSERT OR IGNORE INTO kept VALUES(?)", strings: [id])) }
            try execute("DELETE FROM visible WHERE id NOT IN (SELECT id FROM kept); DROP TABLE kept")
        }
        try execute("UPDATE links SET n=NULL WHERE n IS NOT NULL AND id NOT IN (SELECT id FROM visible)")
        count = try scalar("SELECT count(*) FROM visible")
        for id in kept where try ordinal(of: id) == nil {
            guard let ref = try ref(id), try hasSeen(id) else { throw StoreError.unreadableRecord }
            try append(ref)
        }
    }
    func selectTimeline(_ ids: [String]) throws {
        guard Set(ids).count == ids.count else { throw StoreError.unreadableRecord }
        try execute("DELETE FROM visible; UPDATE links SET n=NULL"); count = 0
        for id in ids {
            guard try hasSeen(id), let ref = try ref(id) else { throw StoreError.unreadableRecord }
            try append(ref)
        }
    }
    private func scalar(_ sql: String) throws -> Int {
        let statement = try query(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.unreadableRecord }
        return Int(sqlite3_column_int64(statement, 0))
    }
    private func ordinal(of id: String) throws -> Int? {
        try run("SELECT n FROM visible WHERE id=?1") { statement in
            bind(statement, 1, id)
            return try row(statement) ? Int(sqlite3_column_int64(statement, 0)) : nil
        }
    }
    func finish() throws {
        // The renamed tables invalidate statements prepared against them.
        releaseStatements()
        // Compact branch holes into a dense position table once. Reads now do
        // primary-key lookups rather than OFFSET walks over a long journal.
        try execute("CREATE TABLE ordered(n INTEGER PRIMARY KEY, id TEXT UNIQUE, role TEXT, turn INTEGER); INSERT INTO ordered SELECT ROW_NUMBER() OVER(ORDER BY n)-1,id,role,turn FROM visible; DROP TABLE visible; ALTER TABLE ordered RENAME TO visible; DROP TABLE chain; UPDATE links SET n=(SELECT n FROM visible WHERE visible.id=links.id); COMMIT")
        count = try scalar("SELECT count(*) FROM visible")
        nextOrdinal = count
    }
    /// Test seam: the database's size, on disk or held.
    var bytes: Int { ((try? scalar("PRAGMA page_count")) ?? 0) * ((try? scalar("PRAGMA page_size")) ?? 0) }
    /// Test seams for per-search spill and cleanup, including cancellation.
    var searchCacheTableCount: Int { (try? scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name LIKE 'search_%'")) ?? 0 }
    var residentCacheBytes: Int {
        var used: Int32 = 0, high: Int32 = 0
        sqlite3_db_status(db, SQLITE_DBSTATUS_CACHE_USED, &used, &high, 0)
        return Int(used)
    }
    func timelineIDs() throws -> [String] {
        let statement = try query("SELECT id FROM visible ORDER BY n"); defer { sqlite3_finalize(statement) }
        var ids: [String] = []
        while try next(statement) {
            guard let text = sqlite3_column_text(statement, 0) else { throw StoreError.unreadableRecord }
            ids.append(String(cString: text))
        }
        return ids
    }
    func index(of id: String) throws -> Int? { try ordinal(of: id) }
    func at(_ index: Int) throws -> HistoryOffset {
        let id = try run("SELECT id FROM visible WHERE n=?1") { statement -> String in
            bind(statement, 1, index)
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw StoreError.unreadableRecord }
            return String(cString: text)
        }
        guard let ref = try ref(id) else { throw StoreError.unreadableRecord }
        return ref
    }
    func latestUser(before: Int) throws -> String? {
        try run("SELECT id FROM visible WHERE n<?1 AND role='user' ORDER BY n DESC LIMIT 1") { statement in
            bind(statement, 1, before)
            return try row(statement) ? sqlite3_column_text(statement, 0).map { String(cString: $0) } : nil
        }
    }
    func firstUser() throws -> String? {
        try run("SELECT id FROM visible WHERE role='user' ORDER BY n LIMIT 1") { statement in
            try row(statement) ? sqlite3_column_text(statement, 0).map { String(cString: $0) } : nil
        }
    }
    /// The positions in `range` whose rows open a display turn.
    func turnStarts(in range: Range<Int>) throws -> Set<Int> {
        try run("SELECT n FROM visible WHERE n>=?1 AND n<?2 AND turn=1") { statement in
            bind(statement, 1, range.lowerBound); bind(statement, 2, range.upperBound)
            var result: Set<Int> = []
            while try row(statement) { result.insert(Int(sqlite3_column_int64(statement, 0))) }
            return result
        }
    }
    /// The row that opened the display turn a row before `before` is in.
    func latestTurnStart(before: Int) throws -> String? {
        try run("SELECT id FROM visible WHERE n<?1 AND turn=1 ORDER BY n DESC LIMIT 1") { statement in
            bind(statement, 1, before)
            return try row(statement) ? sqlite3_column_text(statement, 0).map { String(cString: $0) } : nil
        }
    }
}
