import Foundation
import SQLite3
import Darwin

enum CaptureFailure: Error, LocalizedError {
    case unavailable, corrupt, quota, busy, sequence, legacyKeyUnavailable
    case database(String, Int32)
    var errorDescription: String? {
        switch self {
        case .unavailable: "Request storage is unavailable. No complete capture is claimed."
        case .corrupt: "Capture integrity verification failed. Stored bytes were not repaired or reconstructed."
        case .legacyKeyUnavailable: "Existing encrypted captures require their original Keychain key. Their stored bytes were preserved."
        case .quota: "Capture quota is full. Request metrics remain available; body retention stopped."
        case .busy: "Capture storage is in use by another writer or an active export."
        case .sequence: "Capture bytes arrived out of order. Retained data is explicitly partial."
        case .database(let operation, let code): "Request storage \(operation) failed (SQLite \(code)). No complete capture is claimed."
        }
    }
}

enum CaptureSQLValue: Sendable {
    case text(String), integer(Int64), real(Double), blob(Data), null
    var string: String? { if case .text(let value) = self { value } else { nil } }
    var number: Int64? { if case .integer(let value) = self { value } else { nil } }
    var double: Double? { switch self { case .real(let value): value; case .integer(let value): Double(value); default: nil } }
    var data: Data? { if case .blob(let value) = self { value } else { nil } }
}

// Owned exclusively by PayloadArchive's actor. The wrapper makes lifetime
// cleanup explicit without transferring an SQLite pointer between actors.
final class CaptureDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    // MARK: Test seams
    //
    // Three counters SQLite already keeps. They cost one addition per statement
    // and let a test pin the shape of a write instead of its wall clock.

    /// Rows visited by full table scans, from SQLite's own statement counters.
    /// Tests pin writes with it: a per-chunk or per-event cost that grows with
    /// the size of the archive shows up here long before it shows up in a timer.
    private(set) var scannedRows = 0
    /// Prepared statements, and committed top-level transactions. Tests pin how
    /// much work an operation costs without depending on a wall clock.
    private(set) var statements = 0
    private(set) var commits = 0
    init(url: URL) throws {
        // macOS exposes its temporary directory through /var -> /private/var.
        // Resolve the already-validated archive directory, while keeping the
        // database leaf subject to SQLite's no-follow check.
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { throw CaptureFailure.unavailable }
        defer { free(parent) }
        // URL.resolvingSymlinksInPath deliberately shortens /private/var back
        // to /var on Darwin, so use realpath's bytes without URL normalization.
        let path = String(cString: parent) + "/" + url.lastPathComponent
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            let code = sqlite3_extended_errcode(handle)
            sqlite3_close(handle); handle = nil; throw CaptureFailure.database("open", code)
        }
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA busy_timeout=3000")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String, _ values: [CaptureSQLValue] = []) throws { _ = try rows(sql, values) }
    func rows(_ sql: String, _ values: [CaptureSQLValue] = []) throws -> [[String: CaptureSQLValue]] {
        var statement: OpaquePointer?
        statements += 1
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw CaptureFailure.database("prepare", sqlite3_extended_errcode(handle)) }
        defer {
            scannedRows += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_FULLSCAN_STEP, 0))
            sqlite3_finalize(statement)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1), result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(statement, index, text, -1, transient)
            case .integer(let number): result = sqlite3_bind_int64(statement, index, number)
            case .real(let number): result = sqlite3_bind_double(statement, index, number)
            case .blob(let data): result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw CaptureFailure.unavailable }
        }
        var result: [[String: CaptureSQLValue]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw CaptureFailure.database("step", sqlite3_extended_errcode(handle)) }
            guard result.count < 100_001 else { throw CaptureFailure.quota }
            var row: [String: CaptureSQLValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, index))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    guard count <= 4_194_304 else { throw CaptureFailure.corrupt }
                    row[name] = .blob(sqlite3_column_blob(statement, index).map { Data(bytes: $0, count: count) } ?? Data())
                default: row[name] = .null
                }
            }
            result.append(row)
        }
    }
    private var depth = 0
    /// Nested calls join the outermost transaction, so a sweep can hold every
    /// eviction it performs in one commit instead of one fsync per row.
    func transaction<T>(_ work: () throws -> T) throws -> T {
        if depth > 0 { depth += 1; defer { depth -= 1 }; return try work() }
        try execute("BEGIN IMMEDIATE"); depth = 1; commits += 1
        do { let result = try work(); depth = 0; try execute("COMMIT"); return result }
        catch { depth = 0; try? execute("ROLLBACK"); throw error }
    }
}
