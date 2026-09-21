import Foundation
import SQLite3

struct HistoryOffset: Codable {
    var id: String; var parent: String?; var offset: UInt64; var length: Int; var type: String?
    var fromMessageID: String?; var keptIDs: [String]?; var role: String? = nil
}

/// Rebuildable read-only source index. Offset/branch tables spill to a private
/// temporary database, not the source journal. SQLite's page cache is bounded;
/// no 100k-record prefix can impersonate the latest conversation anymore.
final class HistoryOffsetIndex: @unchecked Sendable {
    private var db: OpaquePointer?
    private let path: URL
    private(set) var count = 0
    private(set) var recordCount = 0
    private(set) var lineage = "root"
    private var nextOrdinal = 0
    init() throws {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("bello-history-" + UUID().uuidString + ".sqlite")
        guard sqlite3_open(path.path, &db) == SQLITE_OK else { throw StoreError.unreadableRecord }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        try execute("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA cache_size=-512; PRAGMA temp_store=FILE; CREATE TABLE refs(id TEXT PRIMARY KEY, payload BLOB NOT NULL); CREATE TABLE chain(n INTEGER PRIMARY KEY, id TEXT NOT NULL); CREATE TABLE visible(n INTEGER PRIMARY KEY, id TEXT UNIQUE NOT NULL, role TEXT); CREATE TABLE seen(id TEXT PRIMARY KEY); BEGIN")
    }
    deinit { sqlite3_close(db); try? FileManager.default.removeItem(at: path) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.unreadableRecord }
    }
    private func query(_ sql: String, strings: [String] = [], data: Data? = nil) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw StoreError.unreadableRecord }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in strings.enumerated() { sqlite3_bind_text(statement, Int32(i + 1), value, -1, transient) }
        if let data { _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(strings.count + 1), $0.baseAddress, Int32($0.count), transient) } }
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
    func insert(_ ref: HistoryOffset) throws {
        try done(query("INSERT INTO refs VALUES(?,?)", strings: [ref.id], data: JSONEncoder().encode(ref)))
        recordCount += 1
    }
    func ref(_ id: String) throws -> HistoryOffset? {
        let statement = try query("SELECT payload FROM refs WHERE id=?", strings: [id]); defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw StoreError.unreadableRecord }
        return try JSONDecoder().decode(HistoryOffset.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }
    func constructChain(leaf: String?) throws {
        var id = leaf, ordinal = 0
        while let current = id {
            try Task.checkCancellation()
            guard let ref = try ref(current), ordinal < recordCount else { throw StoreError.unreadableRecord }
            try done(query("INSERT INTO chain VALUES(\(-ordinal),?)", strings: [current]))
            id = ref.parent; ordinal += 1
        }
    }
    func replayChain(_ body: (HistoryOffset) throws -> Void) throws {
        let statement = try query("SELECT id FROM chain ORDER BY n"); defer { sqlite3_finalize(statement) }
        while try next(statement) {
            try Task.checkCancellation()
            guard let text = sqlite3_column_text(statement, 0), let ref = try ref(String(cString: text)) else { throw StoreError.unreadableRecord }
            try body(ref)
        }
    }
    func hasSeen(_ id: String) throws -> Bool {
        let statement = try query("SELECT 1 FROM seen WHERE id=?", strings: [id]); defer { sqlite3_finalize(statement) }
        return try next(statement)
    }
    func append(_ ref: HistoryOffset) throws {
        if ref.type == "branch" { lineage = ref.id }
        try done(query("INSERT INTO visible VALUES(\(nextOrdinal),?,?)", strings: [ref.id, ref.role ?? ""]))
        try done(query("INSERT OR IGNORE INTO seen VALUES(?)", strings: [ref.id]))
        nextOrdinal += 1; count += 1
    }
    func branch(from: String?, kept: [String]) throws {
        if let from, let position = try ordinal(of: from) { try execute("DELETE FROM visible WHERE n>=\(position)") }
        else {
            try execute("CREATE TEMP TABLE kept(id TEXT PRIMARY KEY)")
            for id in kept { try done(query("INSERT OR IGNORE INTO kept VALUES(?)", strings: [id])) }
            try execute("DELETE FROM visible WHERE id NOT IN (SELECT id FROM kept); DROP TABLE kept")
        }
        count = try scalar("SELECT count(*) FROM visible")
        for id in kept where try ordinal(of: id) == nil {
            guard let ref = try ref(id), try hasSeen(id) else { throw StoreError.unreadableRecord }
            try append(ref)
        }
    }
    private func scalar(_ sql: String) throws -> Int {
        let statement = try query(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreError.unreadableRecord }
        return Int(sqlite3_column_int64(statement, 0))
    }
    private func ordinal(of id: String) throws -> Int? {
        let statement = try query("SELECT n FROM visible WHERE id=?", strings: [id]); defer { sqlite3_finalize(statement) }
        return try next(statement) ? Int(sqlite3_column_int64(statement, 0)) : nil
    }
    func finish() throws {
        // Compact branch holes into a dense position table once. Reads now do
        // primary-key lookups rather than OFFSET walks over a long journal.
        try execute("CREATE TABLE ordered(n INTEGER PRIMARY KEY, id TEXT UNIQUE, role TEXT); INSERT INTO ordered SELECT ROW_NUMBER() OVER(ORDER BY n)-1,id,role FROM visible; DROP TABLE visible; ALTER TABLE ordered RENAME TO visible; DROP TABLE chain; COMMIT")
        count = try scalar("SELECT count(*) FROM visible")
    }
    func index(of id: String) throws -> Int? { try ordinal(of: id) }
    func at(_ index: Int) throws -> HistoryOffset {
        let statement = try query("SELECT id FROM visible WHERE n=\(index)"); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0), let ref = try ref(String(cString: text)) else { throw StoreError.unreadableRecord }
        return ref
    }
    func latestUser(before: Int) throws -> String? {
        let statement = try query("SELECT id FROM visible WHERE n<\(before) AND role='user' ORDER BY n DESC LIMIT 1"); defer { sqlite3_finalize(statement) }
        return try next(statement) ? sqlite3_column_text(statement, 0).map { String(cString: $0) } : nil
    }
    func userPositions(in range: Range<Int>) throws -> Set<Int> {
        let statement = try query("SELECT n FROM visible WHERE n>=\(range.lowerBound) AND n<\(range.upperBound) AND role='user'"); defer { sqlite3_finalize(statement) }
        var result: Set<Int> = []
        while try next(statement) { result.insert(Int(sqlite3_column_int64(statement, 0))) }
        return result
    }
}
