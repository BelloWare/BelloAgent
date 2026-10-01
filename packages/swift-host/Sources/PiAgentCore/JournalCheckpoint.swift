import Foundation
import CryptoKit

/// A chat journal's metadata file, `<journal>.meta`: where the chat's model
/// context starts after its latest compaction (or edit, or fork boundary),
/// the rows shown from there on with where each one is in the journal, and
/// what the records before that point add up to. Opening a chat reads the
/// records it names and replays only what follows them; the rest of the
/// journal is read when something asks for it.
///
/// The journal stays the only record. The file names the records it relies
/// on with their bytes' SHA-256, and a file that is missing, unreadable or no
/// longer matches its journal is ignored and written again from the journal.
/// The helper, which owns the journal, writes it; the helper and the app's
/// history reader read it. Plain JSON.
struct JournalCheckpoint: Codable, Equatable, Sendable {
    static let currentVersion = 1

    /// A record the checkpoint relies on, as it was written.
    struct Check: Codable, Equatable, Sendable {
        var offset: UInt64
        var length: Int
        var sha256: String
    }
    /// Where a shown row's content is now: its own message record, the
    /// presentation update that last replaced it, a compaction record, or the
    /// edit record whose marker it is.
    struct Row: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case message, update, compaction, branch }
        var id: String
        var kind: Kind
        var offset: UInt64
        var length: Int
    }

    var version = Self.currentVersion
    var sessionID: String
    /// The session header, the native marker and the record the checkpoint
    /// follows: a journal they no longer match is not the one described.
    var header: Check
    var marker: Check
    var last: Check
    var lastID: String
    /// The shown rows from the model context's first row on, in order, and
    /// how many shown rows come before them.
    var rows: [Row]
    var rowsBefore: Int
    /// The model context, in order: ids of rows.
    var context: [String]
    /// The newest edit marker among all shown rows: which timeline a page
    /// cursor names, when that marker is not among the rows loaded.
    var lineage: String?
    /// The newest run state before the checkpoint, and the key its record
    /// holds it under (`data`, or an edit's `nativeState`).
    var state: Check?
    var stateKey: String?
    var assistantMessageCount: Int
    var latestAssistantMessageID: String?
    var versions: MessageVersionLedger
    var tasks: [TaskPresentationRecord]
    /// What only the helper reads (spend, recovery and compaction state,
    /// fork or side origin, presentation ordinal), as JSON text.
    var helper: String
    /// Every move of the chat to another connection in the journal, in
    /// order (`SessionJournal.rebind`); nil when there is none.
    var rebinds: [Check]?

    /// Where the replay resumes: just past the record the checkpoint follows.
    var start: UInt64 { last.offset + UInt64(last.length) + 1 }

    static func url(for journal: URL) -> URL { URL(fileURLWithPath: journal.path + ".meta") }
    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    /// The file for `journal`, if there is one that decodes as this version.
    static func read(for journal: URL) -> JournalCheckpoint? {
        guard let data = try? Data(contentsOf: url(for: journal)), data.count <= 64 * 1024 * 1024,
              let value = try? JSONDecoder().decode(JournalCheckpoint.self, from: data), value.version == currentVersion else { return nil }
        return value
    }
    /// Written whole, then moved over the old file: a reader sees one or the other.
    func write(for journal: URL) throws {
        let target = Self.url(for: journal), temporary = target.deletingLastPathComponent()
            .appendingPathComponent("." + target.lastPathComponent + "." + UUID().uuidString)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: temporary)
        guard rename(temporary.path, target.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }
    static func remove(for journal: URL) { try? FileManager.default.removeItem(at: url(for: journal)) }

    /// The bytes of a checked record, if the journal still holds exactly them
    /// there, followed by its newline.
    static func verified(_ check: Check, in file: FileHandle) -> Data? {
        guard check.length > 0, check.length <= 32 * 1024 * 1024 else { return nil }
        do {
            try file.seek(toOffset: check.offset)
            guard let bytes = try file.read(upToCount: check.length + 1), bytes.count == check.length + 1, bytes.last == 10 else { return nil }
            let line = bytes.prefix(check.length)
            return digest(line) == check.sha256 ? Data(line) : nil
        } catch { return nil }
    }
    /// A row's record bytes: in range, and ending at a newline.
    static func rowBytes(_ row: Row, in file: FileHandle) -> Data? {
        guard row.length > 0, row.length <= 32 * 1024 * 1024 else { return nil }
        do {
            try file.seek(toOffset: row.offset)
            guard let bytes = try file.read(upToCount: row.length + 1), bytes.count == row.length + 1, bytes.last == 10 else { return nil }
            return Data(bytes.prefix(row.length))
        } catch { return nil }
    }
    /// The same, read at its place without moving the file's position, so
    /// several rows can be read at once.
    static func rowBytes(_ row: Row, descriptor: Int32) -> Data? {
        guard row.length > 0, row.length <= 32 * 1024 * 1024 else { return nil }
        var bytes = Data(count: row.length + 1)
        let read = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, row.length + 1, off_t(row.offset)) }
        guard read == row.length + 1, bytes.last == 10 else { return nil }
        bytes.removeLast()
        return bytes
    }
}
