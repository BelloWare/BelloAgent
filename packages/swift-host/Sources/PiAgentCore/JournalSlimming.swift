import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A chat's journal written again without the run-state records a later one
/// supersedes, once, for journals written before 0.1.111.
///
/// Until then every run-state record (`pi-app.native.state.v1`) carried the
/// whole list of the chat's last 128 command receipts, and the helper wrote
/// several a turn: in a long chat they were most of the file, though a replay
/// reads only the newest (`CommandReceipts`). Nothing a chat shows or does
/// changes:
///
/// - Only standalone run-state records go, and not the one the chat's run
///   state comes from: that one stays, its receipts written whole. An edit's
///   record keeps the state it carries.
/// - A record after one that went names the record before it as its parent,
///   so the journal is still one chain; no id changes. An edit that named
///   the journal's head when it was made names that parent too.
/// - The new journal is written beside the old one, and both are replayed in
///   full. The old one is replaced only when the rows, the model context,
///   the versions, spend, receipts, queue and run state, task records and
///   request links all come out the same; it then goes to the Trash, and the
///   metadata file is written for the new one.
/// - The journal's lock is held throughout, so no session opens it meanwhile.
///   Anything that fails leaves the journal as it was.
enum JournalSlimming {
    struct Outcome: Equatable {
        /// True when the journal was replaced by its slimmed copy.
        var slimmed = false
        /// Why it was left as it was: "not-native", "little-to-gain",
        /// "session-open", "locked", "mismatch:<what>", "discard-failed", …
        var reason: String?
        var bytesBefore: UInt64 = 0, bytesAfter: UInt64 = 0
        var recordsRemoved = 0
        var json: JSON {
            ["slimmed": JSON(slimmed), "reason": reason.map { JSON($0) } ?? .null, "bytesBefore": JSON(Double(bytesBefore)),
             "bytesAfter": JSON(Double(bytesAfter)), "recordsRemoved": JSON(recordsRemoved)]
        }
    }

    /// Less than this to gain, and the journal is left as it is.
    static let minimumSaving: UInt64 = 1 << 20
    /// Leftovers of a slimming that did not finish (the app quit mid-way) are
    /// removed once they are this old; a slimming under way is never older.
    static let leftoverAge: TimeInterval = 3600

    /// Moves the replaced journal where it can still be recovered.
    static func trash(_ url: URL) throws { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }

    /// Slims the journal at `url`, the session `id`'s. `discard` receives the
    /// original once its copy has been checked (the Trash, unless a test says
    /// otherwise). `tamper` is a test seam: it may change the copy before it
    /// is checked.
    static func slim(url: URL, id: String, minimumSaving: UInt64 = minimumSaving, discard: (URL) throws -> Void = trash,
                     tamper: ((URL) throws -> Void)? = nil) throws -> Outcome {
        let directory = url.deletingLastPathComponent()
        removeLeftovers(in: directory)
        var outcome = Outcome()
        guard let binding = try nativeBinding(url) else { outcome.reason = "not-native"; return outcome }
        // The session's own lock, as an open takes it: a session open in any
        // process holds it, and none can open while this does.
        let original: SessionJournal
        do { original = try SessionJournal(url: url, id: id, cwd: directory, binding: binding, create: false) }
        catch let error as AgentError where error.code == "session_locked" { outcome.reason = "locked"; return outcome }
        return try withExtendedLifetime(original) { try slim(original, url: url, id: id, binding: binding, minimumSaving: minimumSaving, discard: discard, tamper: tamper) }
    }

    /// The rest of `slim`, with the original's lock held.
    private static func slim(_ original: SessionJournal, url: URL, id: String, binding: JSON, minimumSaving: UInt64,
                             discard: (URL) throws -> Void, tamper: ((URL) throws -> Void)?) throws -> Outcome {
        let directory = url.deletingLastPathComponent()
        var outcome = Outcome()
        let plan = try Plan(url)
        outcome.bytesBefore = plan.size
        guard plan.removableBytes >= minimumSaving else { outcome.reason = "little-to-gain"; return outcome }
        let before = try AgentSession.replay(original, url: url, id: id, binding: binding, spendTracked: false, resume: false)

        let copy = directory.appendingPathComponent(".slim-" + UUID().uuidString + ".jsonl")
        // The copy's journal, and the lock it holds on the copy, live until
        // the copy has taken the original's place or been removed.
        var copyJournal: SessionJournal?
        func closeCopy() { withExtendedLifetime(copyJournal) {}; copyJournal = nil }
        func removeCopy() {
            closeCopy()
            try? FileManager.default.removeItem(at: copy); try? FileManager.default.removeItem(atPath: copy.path + ".lock")
        }
        do {
            try plan.write(to: copy, finalState: before.stateRecord)
            try tamper?(copy)
            let opened = try SessionJournal(url: copy, id: id, cwd: directory, binding: binding, create: false)
            copyJournal = opened
            let after = try AgentSession.replay(opened, url: copy, id: id, binding: binding, spendTracked: false, resume: false)
            if let difference = Self.difference(before, after) { removeCopy(); outcome.reason = "mismatch:" + difference; return outcome }
            // The original goes where it can be recovered before its place is
            // taken: a second name for it is discarded, and the copy is then
            // renamed over the first in one step.
            let kept = directory.appendingPathComponent(".pre-slim-" + UUID().uuidString + ".jsonl")
            guard link(url.path, kept.path) == 0 else { removeCopy(); outcome.reason = "discard-failed"; return outcome }
            do { try discard(kept) } catch {
                try? FileManager.default.removeItem(at: kept); removeCopy()
                outcome.reason = "discard-failed"; return outcome
            }
            try? FileManager.default.removeItem(at: kept)
            guard rename(copy.path, url.path) == 0 else { throw AgentError("session_damaged", "The slimmed journal could not take the original's place") }
            // The metadata file follows the new journal, as a full open writes it.
            if let captured = after.captured { try? captured.write(for: url) } else { JournalCheckpoint.remove(for: url) }
            closeCopy()
            try? FileManager.default.removeItem(atPath: copy.path + ".lock")
            outcome.slimmed = true; outcome.recordsRemoved = plan.removed.count
            outcome.bytesAfter = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
            return outcome
        } catch { removeCopy(); throw error }
    }

    /// The binding the journal's native marker records, or nil for a journal
    /// that has none (an imported pi journal).
    static func nativeBinding(_ url: URL) throws -> JSON? {
        let reader = try JournalRecordReader(url)
        var seen = 0
        while let line = try reader.nextLine(), seen < 8 {
            if line.isEmpty { continue }
            seen += 1
            guard let record = try? JSON.parse(line) else { continue }
            if record["customType"].text == JournalRecordKind.marker { return record["data"]["binding"] }
        }
        return nil
    }

    /// Removes what a slimming that did not finish left in the directory.
    static func removeLeftovers(in directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let cutoff = Date().addingTimeInterval(-leftoverAge)
        for name in names where name.hasPrefix(".slim-") || name.hasPrefix(".pre-slim-") {
            let path = directory.appendingPathComponent(name).path
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date, modified < cutoff else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Where each record is, which run-state records go, and how the ones
    /// after them are linked.
    struct Plan {
        struct Line {
            var start: UInt64; var length: Int; var id: String; var parent: String?
            /// A standalone run-state record; an edit's record; one that carries run state.
            var state: Bool; var branch: Bool; var carriesState: Bool
        }
        let url: URL
        let size: UInt64
        let header: (start: UInt64, length: Int)
        let lines: [Line]
        /// Indexes of the run-state records that go.
        let removed: Set<Int>
        /// The run-state record the chat's run state comes from, if a
        /// standalone one does.
        let finalState: Int?
        var removableBytes: UInt64 { removed.reduce(0) { $0 + UInt64(lines[$1].length + 1) } }

        init(_ url: URL) throws {
            self.url = url
            let reader = try JournalRecordReader(url)
            var headerSpan: (UInt64, Int)?, lines: [Line] = []
            while true {
                let start = reader.completeBytes
                guard let line = try reader.nextLine() else { break }
                if line.isEmpty { continue }
                if headerSpan == nil { headerSpan = (start, line.count); continue }
                if let tail = JournalLineScan.stateTail(line), let id = tail.id {
                    lines.append(Line(start: start, length: line.count, id: id, parent: tail.parentID, state: true, branch: false, carriesState: false)); continue
                }
                var fields = JournalLineScan.fields(line)
                if fields?.id == nil {
                    let parsed = try JSON.parse(line)
                    fields = .init(id: parsed["id"].text, parentID: parsed["parentId"].text, customType: parsed["customType"].text, type: parsed["type"].text)
                }
                guard let fields, let id = fields.id else { throw AgentError("session_damaged", "A journal record has no identity") }
                let branch = fields.type == "branch"
                let carriesState = branch && !((try? JSON.parse(line))?["nativeState"].isNull ?? true)
                lines.append(Line(start: start, length: line.count, id: id, parent: fields.parentID,
                                  state: fields.customType == JournalRecordKind.state, branch: branch, carriesState: carriesState))
            }
            guard let headerSpan else { throw AgentError("session_identity", "The journal has no session header") }
            header = headerSpan; size = reader.size; self.lines = lines
            // The chat's run state comes from the last record that carries one:
            // a standalone run-state record, or an edit's.
            let last = lines.lastIndex { $0.state || $0.carriesState }
            let final = last.flatMap { lines[$0].state ? $0 : nil }
            finalState = final
            removed = Set(lines.indices.filter { lines[$0].state && $0 != final })
        }

        /// The journal without the records that go, to `copy`: `finalState`
        /// is the run state the full replay gave, written whole in the record
        /// it came from.
        func write(to copy: URL, finalState state: JSON?) throws {
            guard FileManager.default.createFile(atPath: copy.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw AgentError("session_io", "The slimmed journal could not be created")
            }
            let source = try FileHandle(forReadingFrom: url), target = try FileHandle(forWritingTo: copy)
            defer { try? source.close(); try? target.close() }
            func read(_ start: UInt64, _ length: Int) throws -> Data {
                try source.seek(toOffset: start)
                guard let data = try source.read(upToCount: length), data.count == length else { throw AgentError("session_damaged", "The journal changed while it was read") }
                return data
            }
            var buffer = Data(); buffer.reserveCapacity(1 << 20)
            func emit(_ line: Data) throws {
                buffer.append(line); buffer.append(10)
                if buffer.count >= 1 << 20 { try target.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
            }
            try emit(read(header.start, header.length))
            // The last record kept: the parent the next one kept names.
            var tail: String?, dropped = Set<String>()
            for (index, line) in lines.enumerated() {
                if removed.contains(index) { dropped.insert(line.id); continue }
                var bytes = try read(line.start, line.length)
                let relinked = line.parent != tail
                let rewhole = index == finalState && CommandReceipts.holdsChanges(bytes)
                if relinked || rewhole || line.branch {
                    var record = try JSON.parse(bytes)
                    var changed = false
                    if relinked { record["parentId"] = tail.map { JSON($0) } ?? .null; changed = true }
                    if rewhole, let state { record["data"] = state; changed = true }
                    // An edit's record names the journal's head when it was
                    // made; a head that went is the record now before it.
                    if let head = record["sourceJournalHead"].text, dropped.contains(head) {
                        record["sourceJournalHead"] = tail.map { JSON($0) } ?? .null; changed = true
                    }
                    if changed { bytes = try record.data() }
                }
                try emit(bytes)
                tail = line.id
            }
            if !buffer.isEmpty { try target.write(contentsOf: buffer) }
            try target.synchronize()
        }
    }

    /// What differs between two replays of the same chat, or nil when nothing
    /// a session derives from its journal does. Offsets differ by design; the
    /// rows a replay makes itself (a compaction's summary, an edit's marker)
    /// carry the moment of that replay.
    static func difference(_ lhs: JournalReplay, _ rhs: JournalReplay) -> String? {
        func rows(_ messages: [ChatMessage]) -> [Data] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return messages.map { message in
                var message = message
                if ["compaction", "branch"].contains(message.kind ?? "") { message.timestamp = nil }
                return (try? encoder.encode(message)) ?? Data()
            }
        }
        if rows(lhs.history) != rows(rhs.history) { return "history" }
        if rows(lhs.visible) != rows(rhs.visible) { return "visible" }
        if rows(lhs.context) != rows(rhs.context) { return "context" }
        if lhs.versions.ledger != rhs.versions.ledger || lhs.versions.timelines != rhs.versions.timelines { return "versions" }
        if lhs.versions.starts.mapValues({ [$0.timeline, $0.offset] }) != rhs.versions.starts.mapValues({ [$0.timeline, $0.offset] }) { return "versions" }
        if lhs.spend != rhs.spend || lhs.spendTracked != rhs.spendTracked { return "spend" }
        if lhs.assistantMessageCount != rhs.assistantMessageCount || lhs.latestAssistantMessageID != rhs.latestAssistantMessageID { return "replies" }
        if lhs.pendingRequestLinks != rhs.pendingRequestLinks { return "request-links" }
        if lhs.recentTaskPresentations != rhs.recentTaskPresentations { return "tasks" }
        if lhs.compactionState != rhs.compactionState || lhs.contextRecovery != rhs.contextRecovery
            || lhs.failedCompactionFingerprint != rhs.failedCompactionFingerprint { return "compaction" }
        if lhs.parentInfo != rhs.parentInfo { return "origin" }
        if lhs.presentationOrdinal != rhs.presentationOrdinal { return "ordinal" }
        if lhs.stateRecord != rhs.stateRecord { return "run-state" }
        return nil
    }
}
