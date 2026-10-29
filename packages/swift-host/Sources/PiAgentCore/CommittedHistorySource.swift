import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Negotiated display authority for one complete journal prefix. No message
/// bodies, permissions, provider context or accounting travel in this contract.
struct CommittedHistorySource: Codable, Equatable, Sendable {
    static let capability = "committed-history-v1"
    var version = 1
    var sessionID: String
    var path: String
    var device: UInt64
    var inode: UInt64
    var header: JournalCheckpoint.Check
    var marker: JournalCheckpoint.Check
    var last: JournalCheckpoint.Check
    var lastID: String
    var lineage: String
    var runtime: String
    var presentationRevision: UInt64
    var total: Int
    /// The first row that requires live helper projection, or nil when every
    /// row is committed. The position belongs only to this journal identity.
    var liveTail: Tail?
    /// Oldest row already available to session.history without its deferred
    /// replay. This preserves its checkpoint-backed page ranges.
    var availableFrom = 0
    struct Tail: Codable, Equatable, Sendable { var entry: String; var position: Int }
    var committedBytes: UInt64 { last.offset + UInt64(max(0, last.length)) + 1 }
    var incarnation: String { "file:\(device):\(inode)" }
    var valid: Bool {
        guard version == 1, !sessionID.isEmpty, !path.isEmpty, !lastID.isEmpty, !lineage.isEmpty,
              !runtime.isEmpty, total >= 0, availableFrom >= 0, availableFrom <= total else { return false }
        for check in [header, marker, last] {
            guard check.length > 0, check.length <= 32 * 1024 * 1024, check.sha256.count == 64 else { return false }
            let maximum = UInt64(Int64.max) - UInt64(check.length) - 1
            guard check.offset <= maximum else { return false }
        }
        guard header.offset + UInt64(header.length) < marker.offset, marker.offset + UInt64(marker.length) < committedBytes else { return false }
        if let liveTail { return !liveTail.entry.isEmpty && liveTail.position >= 0 && liveTail.position < total }
        return true
    }
    func sameJournal(as other: Self) -> Bool {
        sessionID == other.sessionID && path == other.path && device == other.device && inode == other.inode && header == other.header && marker == other.marker
    }
    /// Ordinary appends do not revoke an already read prefix. An edit, a
    /// replaced journal, a runtime replacement or a changed presentation does.
    func validates(_ captured: Self, through end: Int) -> Bool {
        valid && sameJournal(as: captured) && lineage == captured.lineage && runtime == captured.runtime &&
        presentationRevision == captured.presentationRevision && committedBytes >= captured.committedBytes && total >= captured.total &&
        end <= (captured.liveTail?.position ?? captured.total) && end <= (liveTail?.position ?? total)
    }
    /// Reopen checks are bounded by three individual records. File growth is
    /// allowed; a missing newline, changed identity or changed record is not.
    func verify(_ file: FileHandle) throws {
        struct Header: Decodable { var type: String; var id: String; var version: Int }
        struct Record: Decodable { var id: String }
        var info = stat()
        guard valid, fstat(file.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              UInt64(info.st_dev) == device, UInt64(info.st_ino) == inode,
              info.st_size >= 0, UInt64(info.st_size) >= committedBytes,
              let head = JournalCheckpoint.verified(header, in: file),
              let identity = try? JSONDecoder().decode(Header.self, from: head), identity.type == "session", identity.id == sessionID, identity.version == 3,
              JournalCheckpoint.verified(marker, in: file) != nil,
              let tail = JournalCheckpoint.verified(last, in: file),
              (try? JSONDecoder().decode(Record.self, from: tail).id) == lastID else { throw CocoaError(.fileReadCorruptFile) }
    }
}
