import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The reply a run is streaming, kept on disk beside the chat's journal
/// (`<journal>.stream`) so a helper that dies mid-reply (killed, crashed)
/// leaves it behind. The journal holds a reply only once it ends; until then
/// the text, the thought and the timeline parts live in memory, and a helper
/// stopped in the ordinary way writes them as the interrupted reply itself.
///
/// What arrived is gathered and written together every
/// `flushDelayNanoseconds` (sooner past `flushBytes`), unsynced: an app or
/// helper crash loses at most that last moment; only a power loss can lose
/// more. The file goes when the run settles and its journal is on disk. A
/// reopen after a crash takes the last reply in it, when the journal does not
/// hold that reply, as the interrupted reply a stop leaves (`interrupted`);
/// nothing is sent again.
///
/// The file is lines of JSON: a reply's header (`reply`), then what streamed
/// (`p` a timeline part, `t` text, `k` thought), each batch after its wall
/// time (`at`). A torn or unreadable line ends what is read: the lines before
/// it stand.
///
/// Concurrency: like the journal it sits beside, owned by one `AgentSession`
/// actor and only touched from its isolation.
final class PartialReplyLog {
    static func url(for journal: URL) -> URL { URL(fileURLWithPath: journal.path + ".stream") }
    static let flushDelayNanoseconds: UInt64 = 100_000_000
    static let flushBytes = 16 * 1024

    enum Entry { case part(ResponsePartEvent), text(String), thinking(String) }
    /// The journal record the reply was written after, by where it is and its id.
    struct Anchor: Codable, Equatable { var offset: UInt64; var length: Int; var id: String }
    struct Header: Codable, Equatable {
        var reply: String
        var after: Anchor
        var turn: String?
        var taskRootID: String?
        var taskExecutionID: String?
        var attemptID: String?
    }

    private(set) var path: String?
    private var fd: Int32 = -1
    private var failed = false
    private var pending: [Entry] = [], pendingBytes = 0
    /// The reply whose header the file holds last.
    private(set) var reply: String?
    var hasPending: Bool { !pending.isEmpty }
    /// Test seam: how many batches were written.
    private(set) var writes = 0

    /// Keeps `entry` for the next write; true once enough waits to write now.
    func add(_ entry: Entry) -> Bool {
        guard !failed else { return false }
        // Text after text grows the one entry in place: the array lets go
        // of it first, so appending copies only the token.
        switch entry {
        case .text(let text):
            if case .text(var earlier)? = pending.last { pending[pending.count - 1] = .text(""); earlier += text; pending[pending.count - 1] = .text(earlier) }
            else { pending.append(entry) }
            pendingBytes += text.utf8.count
        case .thinking(let text):
            if case .thinking(var earlier)? = pending.last { pending[pending.count - 1] = .thinking(""); earlier += text; pending[pending.count - 1] = .thinking(earlier) }
            else { pending.append(entry) }
            pendingBytes += text.utf8.count
        case .part(let part):
            pending.append(entry); pendingBytes += part.text.utf8.count + 256
        }
        return pendingBytes >= Self.flushBytes
    }
    func discardPending() { pending.removeAll(keepingCapacity: true); pendingBytes = 0 }

    /// Writes what waits, after `header` when the reply is not the one the
    /// file holds last, to the file beside `journal` (moved there when the
    /// journal moved, as a side kept while it runs does). A failure stops
    /// the log for good; the stream itself goes on.
    func write(header: Header?, journal: URL) {
        defer { discardPending() }
        guard !failed, !pending.isEmpty else { return }
        let target = Self.url(for: journal).path
        if let path, path != target {
            if fd >= 0, rename(path, target) != 0 { stop(); return }
            self.path = target
        }
        if fd < 0 {
            fd = open(target, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { failed = true; return }
            path = target
        }
        var data = Data()
        let encoder = JSONEncoder()
        func line(_ value: JSON) throws { data.append(try value.data()); data.append(10) }
        do {
            if let header {
                data.append(try encoder.encode(header)); data.append(10); reply = header.reply
            }
            guard reply != nil else { return }
            try line(["at": JSON(Date().timeIntervalSince1970 * 1000)])
            for entry in pending {
                switch entry {
                case .text(let text): try line(["t": JSON(text)])
                case .thinking(let text): try line(["k": JSON(text)])
                case .part(let part):
                    data.append(contentsOf: Array(#"{"p":"#.utf8)); data.append(try encoder.encode(part)); data.append(contentsOf: Array("}\n".utf8))
                }
            }
        } catch { stop(); return }
        if writeAll(fd, data) { writes += 1 } else { stop() }
    }
    /// Closes the file and moves it aside (`setAside`): the journal did not
    /// take a reply it holds. False, with the file left where it is and
    /// nothing more written to it, when it could not be moved.
    @discardableResult func keepAside() -> Bool {
        if fd >= 0 { _ = close(fd); fd = -1 }
        discardPending()
        if let path, !Self.setAside(URL(fileURLWithPath: path)) { failed = true; return false }
        path = nil; reply = nil
        return true
    }
    /// Closes and removes the file: the run settled and its journal is on disk.
    func remove() {
        if fd >= 0 { _ = close(fd); fd = -1 }
        if let path { _ = unlink(path) }
        path = nil; reply = nil; discardPending()
    }
    private func stop() {
        failed = true; discardPending()
        if fd >= 0 { _ = close(fd); fd = -1 }
    }
    deinit { if fd >= 0 { _ = close(fd) } }

    /// The last reply the file at `url` holds, as streamed so far, when the
    /// journal at `journal` (`size` bytes) still has the record it was
    /// written after and holds no record of the reply after that: what a
    /// helper that died mid-reply never wrote. Nil otherwise.
    static func unfinished(_ url: URL, journal: URL, size: UInt64) -> (header: Header, text: String, thinking: String, timeline: ResponseTimeline, at: Double?)? {
        guard let reader = try? JournalRecordReader(url, allowIncompleteTail: true) else { return nil }
        var header: Header?, text = "", thinking = "", timeline = ResponseTimeline(), at: Double?
        let decoder = JSONDecoder()
        while let line = try? reader.nextLine() {
            if line.isEmpty { continue }
            guard let value = try? JSON.parse(line) else { break }
            if !value["reply"].isNull {
                guard let next = try? decoder.decode(Header.self, from: line) else { break }
                header = next; text = ""; thinking = ""; timeline = ResponseTimeline(); at = nil
            } else if header == nil {
                continue
            } else if let time = value["at"].double { at = time }
            else if let chunk = value["t"].text { text += chunk }
            else if let chunk = value["k"].text { thinking += chunk }
            else if !value["p"].isNull {
                guard let data = try? value["p"].data(), let part = try? decoder.decode(ResponsePartEvent.self, from: data) else { break }
                timeline.consume(part)
            }
        }
        // The reply's id becomes a journal record's: one the journal would
        // refuse on its next open (not an id, or one a record already has,
        // the reply's own row among them) is not written. The whole journal
        // is read for it, as only a reopen after a crash does.
        guard let header, (try? identity(JSON(header.reply))) != nil, !text.isEmpty || !thinking.isEmpty || !timeline.segments.isEmpty,
              journalHolds(header.after, in: journal, size: size), !journalNames(header.reply, in: journal) else { return nil }
        return (header, text, thinking, timeline, at)
    }
    /// A log the journal could not take its reply from (the record would not
    /// write), moved aside beside it, kept for inspection: the next settled
    /// run or open would otherwise remove it.
    static func setAside(_ url: URL) -> Bool {
        let kept = url.path + "-unrestored-" + String(Int(Date().timeIntervalSince1970 * 1000))
        return rename(url.path, kept) == 0
    }
    /// The log beside `source`, written beside `destination`: a recovered copy
    /// of a journal whose records start `shift` bytes later than the
    /// original's (its header written again). Up to a torn or unreadable
    /// line, as a reopen reads it. Nothing is written when there is no log.
    static func carry(from source: URL, to destination: URL, shift: Int64) throws {
        let log = url(for: source)
        guard FileManager.default.fileExists(atPath: log.path) else { return }
        let reader = try JournalRecordReader(log, allowIncompleteTail: true)
        let target = url(for: destination)
        let fd = open(target.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AgentError("session_write", "Cannot write the recovered copy's unfinished reply") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        do {
            // Written as read, a batch at a time: a long run's log is never
            // held whole.
            var data = Data()
            while let line = try? reader.nextLine() {
                if line.isEmpty { continue }
                guard let value = try? JSON.parse(line) else { break }
                if !value["reply"].isNull {
                    guard var header = try? decoder.decode(Header.self, from: line), let offset = Int64(exactly: header.after.offset) else { break }
                    let (moved, overflow) = offset.addingReportingOverflow(shift)
                    guard !overflow, moved >= 0 else { break }
                    header.after.offset = UInt64(moved)
                    data.append(try encoder.encode(header))
                } else { data.append(line) }
                data.append(10)
                if data.count >= 1 << 20 { try file.write(contentsOf: data); data.removeAll(keepingCapacity: true) }
            }
            try file.write(contentsOf: data); try file.synchronize()
        } catch { try? file.close(); _ = unlink(target.path); throw error }
        try file.close()
    }
    /// Whether the journal's record at `anchor` is still the one named.
    private static func journalHolds(_ anchor: Anchor, in journal: URL, size: UInt64) -> Bool {
        guard anchor.length > 0, anchor.length <= JournalRecordReader.maximumRecordBytes, anchor.offset < size, UInt64(anchor.length) < size - anchor.offset,
              let file = try? FileHandle(forReadingFrom: journal) else { return false }
        defer { try? file.close() }
        guard (try? file.seek(toOffset: anchor.offset)) != nil, let bytes = try? file.read(upToCount: anchor.length + 1),
              bytes.count == anchor.length + 1, bytes.last == 10 else { return false }
        let line = Data(bytes.prefix(anchor.length))
        let id = JournalLineScan.fields(line)?.id ?? (try? JSON.parse(line))?["id"].text
        return id == anchor.id
    }
    /// Whether a record of the journal has the reply's id: the reply was
    /// journaled, or the id is taken.
    private static func journalNames(_ reply: String, in journal: URL) -> Bool {
        guard let reader = try? JournalRecordReader(journal) else { return true }
        while true {
            // A journal that cannot be read through counts as naming it.
            let next: Data?
            do { next = try reader.nextLine() } catch { return true }
            guard let line = next else { return false }
            if line.isEmpty { continue }
            let id = JournalLineScan.fields(line)?.id ?? (try? JSON.parse(line))?["id"].text
            if id == reply { return true }
        }
    }
}

/// Writes all of `data` to `fd`, however many calls it takes.
private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return true }
        var offset = 0
        while offset < raw.count {
            let count = write(fd, base + offset, raw.count - offset)
            if count < 0 { if errno == EINTR { continue }; return false }
            offset += count
        }
        return true
    }
}

extension AgentSession {
    /// The row a reply cut off before its end leaves: kept and shown, never
    /// sent to the model again.
    static func interruptedReply(id: String, text: String, thinking: String, timeline: ResponseTimeline, attemptIDs: [String]?) -> ChatMessage {
        var partial=ChatMessage(role:"assistant",content:[textBlock(text),["type":"thinking","thinking":JSON(thinking)]])
        partial.responseTimeline=timeline; partial.responseTimeline?.finish("interrupted")
        partial.id=id; partial.replayEligible=false; partial.stopReason="interrupted"; partial.requestAttemptIDs=attemptIDs
        return partial
    }
    /// Keeps a streamed delta for the reply's log, written a moment later
    /// with whatever else arrives meanwhile.
    func logStreamed(_ entry: PartialReplyLog.Entry) {
        // Not over a refused reply's log still waiting to be set aside: the
        // next open reads its last reply.
        guard journal != nil, partialID != nil, !partialReplyUnsaved else { return }
        let log = partialReplyLog ?? PartialReplyLog(); partialReplyLog = log
        if log.add(entry) { flushStreamed() }
        else if partialReplyFlush == nil {
            partialReplyFlush = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: PartialReplyLog.flushDelayNanoseconds) } catch { return }
                await self?.flushStreamed()
            }
        }
    }
    /// `reply`: the reply what waits belongs to, when it is no longer the
    /// streaming one (it ended, and the journal refused its row).
    func flushStreamed(as reply: String? = nil) {
        partialReplyFlush?.cancel(); partialReplyFlush = nil
        guard let log = partialReplyLog, log.hasPending else { return }
        guard let journal, let partialID = reply ?? partialID else { log.discardPending(); return }
        var header: PartialReplyLog.Header?
        if log.reply != partialID {
            guard let head = journal.head, let span = journal.lastAppend else { log.discardPending(); return }
            header = .init(reply: partialID, after: .init(offset: span.offset, length: span.length, id: head), turn: currentTurnID.isEmpty ? nil : currentTurnID,
                           taskRootID: taskRootID, taskExecutionID: activeTaskPresentation?.executionID, attemptID: requestObservation?.attemptID)
        }
        log.write(header: header, journal: journal.url)
    }
    /// What waits for the log is let go: the reply it belongs to is over, and
    /// its row (when anything arrived) is the journal's to keep.
    func dropStreamed() {
        partialReplyFlush?.cancel(); partialReplyFlush = nil
        partialReplyLog?.discardPending()
    }
    /// The run settled and its journal is on disk: the log is no longer
    /// needed, unless a reply it holds could not be written there.
    func removeStreamedLog() {
        dropStreamed()
        // A log that could not be moved aside stays, and so does the mark:
        // the next open restores its reply, or sets it aside, whatever the
        // run was saved as.
        if partialReplyUnsaved { guard partialReplyLog?.keepAside() ?? true else { return } } else { partialReplyLog?.remove() }
        partialReplyLog = nil; partialReplyUnsaved = false
    }
}
