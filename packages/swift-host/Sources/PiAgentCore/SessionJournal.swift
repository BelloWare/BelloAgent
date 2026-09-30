import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// The append-only session journal: the durable record of one chat.

/// The rule every native journal keeps: one branch, each record's id new and
/// its parent the record before it. Each walk that checks a journal (an open,
/// one resumed from a checkpoint, a recovery, a portable preview) holds it
/// alike, and says what breaking it means there.
struct JournalChainCheck {
    private(set) var last: String?
    private var seen = Set<String>()
    init(after last: String? = nil) { self.last = last }
    /// Whether the record `id`, whose parent is `parent`, continues the
    /// branch, which it then does.
    mutating func extend(_ id: String, parent: String?) -> Bool {
        guard seen.insert(id).inserted, parent == last else { return false }
        last = id; return true
    }
}

/// Append-only, locked native journal with the existing Pi-compatible *display*
/// envelope. Opaque provider items are native metadata, not a Pi replay promise.
///
/// Concurrency: deliberately not `Sendable`. One journal belongs to one
/// `AgentSession` actor and is only ever touched from that actor's isolation,
/// so the file handle needs no lock of its own; the `flock` it holds excludes
/// other *processes*, not other threads.
final class SessionJournal {
    private(set) var url: URL
    private let handle: FileHandle
    private var lockFD: Int32
    private var poisoned = false
    var writeOutcomeUncertain: Bool { poisoned }
    private var tail: String?, bytes: UInt64
    var head: String? { tail }
    private var unsynced = false
    /// Test seams: how many records were written and how many times they were
    /// forced to stable storage, so the batching contract is assertable
    /// without timing a disk.
    private(set) var appends = 0, synchronizations = 0
    private let beforeAppend: @Sendable (JSON) throws -> Void
    private let beforeSynchronize: @Sendable () throws -> Void
    /// The checkpoint this journal was opened from, when its records all
    /// still match it and nothing after it rewrites the context; the replay
    /// then resumes there (`JournalCheckpoint`).
    private(set) var resumedFrom: JournalCheckpoint?
    /// The session header and the native marker as written, for a checkpoint.
    private(set) var headerCheck: JournalCheckpoint.Check?, markerCheck: JournalCheckpoint.Check?
    /// Where the last append went, and its bytes, for a checkpoint.
    private(set) var lastAppend: (offset: UInt64, length: Int)?
    private(set) var lastAppendLine: Data?
    init(url: URL, id: String, cwd: URL, binding: JSON, create: Bool, checkpoint: JournalCheckpoint? = nil, beforeAppend: @escaping @Sendable (JSON) throws -> Void = { _ in }, beforeSynchronize: @escaping @Sendable () throws -> Void = {}) throws {
        self.url=url; self.beforeAppend=beforeAppend; self.beforeSynchronize=beforeSynchronize
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        lockFD=open(url.path + ".lock",O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard lockFD >= 0 else { throw AgentError("session_lock", "Cannot create session writer lock") }
        guard flock(lockFD,LOCK_EX|LOCK_NB) == 0 else { _ = close(lockFD); throw AgentError("session_locked", "Another process owns this session") }
        do {
            if create {
                let fd=open(url.path,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW|O_CLOEXEC,0o600)
                guard fd >= 0 else { throw AgentError("session_exists", "Session path already exists; open it explicitly") }
                _=close(fd)
                let header: JSON = ["type":"session","version":3,"id":JSON(id),"cwd":JSON(cwd.path),"timestamp":JSON(isoNow())]
                var data=try header.data(); data.append(10); try data.write(to:url)
            }
            if !create, let checkpoint, let resumed=Self.resume(url:url,id:id,binding:binding,from:checkpoint) {
                tail=resumed.last; bytes=resumed.size; resumedFrom=checkpoint; headerCheck=checkpoint.header; markerCheck=checkpoint.marker
            } else {
                let scanned=try Self.chain(url:url,id:id,binding:binding,requireMarker:!create)
                tail=scanned.last; bytes=scanned.size; headerCheck=scanned.header; markerCheck=scanned.marker
            }
            handle=try FileHandle(forWritingTo:url); try handle.seekToEnd()
        } catch { _=flock(lockFD,LOCK_UN); _=close(lockFD); throw error }
        if create {
            try append(["type":"custom","customType":JSON(JournalRecordKind.marker),"data":["binding":binding,"version":1]])
            if let span=lastAppend, let line=lastAppendLine { markerCheck=JournalCheckpoint.Check(offset:span.offset,length:span.length,sha256:JournalCheckpoint.digest(line)) }
        }
    }
    /// A journal a clone made (`clone(to:id:cwd:through:)`): its file written,
    /// locked and open, its header, marker and last record known.
    private init(cloned url: URL, lockFD: Int32, handle: FileHandle, tail: String, bytes: UInt64,
                 header: JournalCheckpoint.Check, marker: JournalCheckpoint.Check?) {
        self.url=url; self.lockFD=lockFD; self.handle=handle; self.tail=tail; self.bytes=bytes
        self.beforeAppend={ _ in }; self.beforeSynchronize={}
        headerCheck=header; markerCheck=marker; unsynced=true
    }
    /// The whole journal checked as one unbroken chain, as every open did
    /// before checkpoints. The chain needs each record's id, parent and kind,
    /// which a scan reads without building the record; the replay parses what
    /// it uses. A line the scan cannot read plainly is parsed in full.
    private static func chain(url: URL, id: String, binding: JSON, requireMarker: Bool) throws
        -> (last: String?, size: UInt64, header: JournalCheckpoint.Check, marker: JournalCheckpoint.Check?) {
        let reader=try JournalRecordReader(url)
        // Empty lines are tolerated, as the JSONL reader always has.
        var headerStart: UInt64=0, headerLine=Data()
        while headerLine.isEmpty { headerStart=reader.completeBytes; guard let line=try reader.nextLine() else { break }; headerLine=line }
        guard !headerLine.isEmpty, let header=try? JSON.parse(headerLine),
              header["type"].text == "session", header["version"].int == 3, header["id"].text == id else { throw AgentError("session_identity", "Session header does not match its identity") }
        let headerCheck=JournalCheckpoint.Check(offset:headerStart,length:headerLine.count,sha256:JournalCheckpoint.digest(headerLine))
        var branch=JournalChainCheck()
        var marker: JSON?, markerCheck: JournalCheckpoint.Check?
        while true {
            let start=reader.completeBytes
            guard let line=try reader.nextLine() else { break }
            if line.isEmpty { continue }
            let item: JSON?, fields: JournalLineScan.Fields
            if let tail=JournalLineScan.stateTail(line) { item = nil; fields = tail }
            else if let scanned=JournalLineScan.fields(line), scanned.id != nil { item = nil; fields = scanned }
            else {
                let parsed=try JSON.parse(line); item = parsed
                fields = JournalLineScan.Fields(id: parsed["id"].text, parentID: parsed["parentId"].text, customType: parsed["customType"].text)
            }
            let rid=try identity(item?["id"] ?? .string(fields.id ?? ""))
            guard branch.extend(rid, parent: fields.parentID) else { throw AgentError("session_damaged", "Native journal must be a valid single branch") }
            if marker == nil, fields.customType == JournalRecordKind.marker {
                marker=try item ?? JSON.parse(line)
                markerCheck=JournalCheckpoint.Check(offset:start,length:line.count,sha256:JournalCheckpoint.digest(line))
            }
        }
        if requireMarker {
            guard let marker, marker["data"]["binding"] == binding else { throw AgentError("legacy_session", "This is not a compatible native session. Original Pi history remains read-only; use an explicit portable handoff.") }
        }
        return (branch.last, reader.size, headerCheck, markerCheck)
    }
    /// The chain from a checkpoint on, when the records the checkpoint relies
    /// on are still exactly as it recorded them and nothing after it rewrites
    /// the model context (an edit or a fork boundary, which only a full replay
    /// applies). nil means: check and replay the whole journal.
    private static func resume(url: URL, id: String, binding: JSON, from checkpoint: JournalCheckpoint) -> (last: String?, size: UInt64)? {
        guard checkpoint.sessionID == id, let file=try? FileHandle(forReadingFrom:url) else { return nil }
        defer { try? file.close() }
        guard let headerLine=JournalCheckpoint.verified(checkpoint.header,in:file), let header=try? JSON.parse(headerLine),
              header["type"].text == "session", header["version"].int == 3, header["id"].text == id,
              let markerLine=JournalCheckpoint.verified(checkpoint.marker,in:file), let marker=try? JSON.parse(markerLine),
              marker["customType"].text == JournalRecordKind.marker, marker["data"]["binding"] == binding,
              let lastLine=JournalCheckpoint.verified(checkpoint.last,in:file), let last=try? JSON.parse(lastLine),
              last["id"].text == checkpoint.lastID, let reader=try? JournalRecordReader(url,startingAt:checkpoint.start) else { return nil }
        var branch=JournalChainCheck(after: checkpoint.lastID)
        do {
            while let line=try reader.nextLine() {
                if line.isEmpty { continue }
                let fields: JournalLineScan.Fields
                if let scanned=JournalLineScan.stateTail(line) ?? JournalLineScan.fields(line), scanned.id != nil { fields=scanned }
                else { let parsed=try JSON.parse(line); fields = .init(id:parsed["id"].text,parentID:parsed["parentId"].text,customType:parsed["customType"].text,type:parsed["type"].text) }
                let rid=try identity(.string(fields.id ?? ""))
                guard branch.extend(rid, parent: fields.parentID), fields.type != "branch", fields.customType != JournalRecordKind.context else { return nil }
            }
        } catch { return nil }
        return (branch.last, reader.size)
    }
    /// `flush` false leaves the record written but not yet forced to stable
    /// storage. The bytes are in the file either way — another reader, a fork
    /// and a reopen all see them — so only a power loss can lose them, and
    /// only for records a run is still producing. `synchronize` closes that
    /// window when the turn settles.
    @discardableResult func append(_ value: JSON, id: String = UUID().uuidString, flush: Bool = true) throws -> String {
        guard !poisoned else { throw AgentError("session_damaged", "A journal write failed; recover a copy before continuing") }
        var v=value; v["id"]=JSON(id); v["parentId"]=tail.map { JSON($0) } ?? .null; v["timestamp"]=JSON(isoNow())
        var data=try v.data(); data.append(10)
        guard data.count - 1 <= JournalRecordReader.maximumRecordBytes else { throw AgentError("session_record_limit", "This individual journal record exceeds 32 MiB; the existing conversation is preserved") }
        try beforeAppend(v)
        do { try handle.write(contentsOf:data) } catch { poisoned=true; throw error }
        lastAppend=(bytes, data.count - 1); lastAppendLine=data.dropLast()
        tail=id; bytes += UInt64(data.count); unsynced=true; appends += 1
        if flush { try synchronize() }
        return id
    }
    /// A record already written as this journal writes them, whose `id` is
    /// `id` and whose `parentId` is this journal's tail (`JournalEnvelope`):
    /// a fork's copy of a record, appended without parsing and encoding it
    /// again. It does not pass through `beforeAppend`, which sees the records
    /// a session writes, not a fork's copies.
    func appendLine(_ line: Data, id: String, flush: Bool = true) throws {
        guard !poisoned else { throw AgentError("session_damaged", "A journal write failed; recover a copy before continuing") }
        guard line.count <= JournalRecordReader.maximumRecordBytes else { throw AgentError("session_record_limit", "This individual journal record exceeds 32 MiB; the existing conversation is preserved") }
        var data=line; data.append(10)
        do { try handle.write(contentsOf:data) } catch { poisoned=true; throw error }
        lastAppend=(bytes, line.count); lastAppendLine=line
        tail=id; bytes += UInt64(data.count); unsynced=true; appends += 1
        if flush { try synchronize() }
    }
    /// Forces everything appended so far to stable storage.
    func synchronize() throws {
        guard !poisoned else { throw AgentError("session_damaged","A journal synchronization failed; recover a copy before continuing") }
        guard unsynced else { return }
        do { try beforeSynchronize(); try handle.synchronize() } catch { poisoned=true; throw error }
        unsynced=false; synchronizations += 1
    }
    func publish(to destination: URL) throws {
        try synchronize()
        let newFD=open(destination.path + ".lock",O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard newFD >= 0 else { throw AgentError("session_lock", "Cannot acquire destination lock") }
        guard flock(newFD,LOCK_EX|LOCK_NB) == 0 else { _=close(newFD); throw AgentError("session_locked", "Destination is owned by another writer") }
        do { try FileManager.default.moveItem(at:url,to:destination) }
        catch { _=flock(newFD,LOCK_UN); _=close(newFD); throw error }
        let old=url; _=flock(lockFD,LOCK_UN); _=close(lockFD); lockFD=newFD; url=destination
        try? FileManager.default.removeItem(atPath:old.path+".lock")
    }
    /// Stream replay/copies without a second parsed copy of the whole journal.
    func recordReader(from start: UInt64 = 0) throws -> JournalRecordReader {
        guard !poisoned else { throw AgentError("session_damaged", "A failed journal write must be recovered before forking") }
        if start > 0 { return try JournalRecordReader(url,expectedBytes:bytes,startingAt:start) }
        let reader=try JournalRecordReader(url,expectedBytes:bytes)
        _=try reader.next() // The header is validated at open, not a replay record.
        return reader
    }
    /// The journal's size as written so far: where the next record goes.
    var size: UInt64 { bytes }
    /// Checks the whole chain after an open that resumed from a checkpoint
    /// whose rows then failed to load; the caller replays the whole journal.
    func checkWhole(id: String, binding: JSON) throws {
        let scanned=try Self.chain(url:url,id:id,binding:binding,requireMarker:true)
        tail=scanned.last; bytes=scanned.size; headerCheck=scanned.header; markerCheck=scanned.marker; resumedFrom=nil
    }
    deinit { try? synchronize(); try? handle.close(); _=flock(lockFD,LOCK_UN); _=close(lockFD) }
}

// A fork's journal made by cloning the chat's instead of copying it: on APFS
// the clone shares the chat's blocks, so it costs next to nothing whatever
// the chat's size, and only what either file writes afterwards is its own.
extension SessionJournal {
    /// The first `end.bytes` bytes of this journal, whose last record is
    /// `end.lastID` (the whole journal when `end` is nil), cloned to `url`,
    /// with the session header rewritten for `id` and `cwd`: a fork's journal,
    /// locked and ready for the fork's own records. The header keeps its
    /// length, padded with spaces, so every record stays where it is.
    ///
    /// Nil, with nothing left behind, when no clone can be made: a volume that
    /// does not clone, a new header longer than the old, a file that is not
    /// the one this journal wrote as it wrote it. The caller copies instead.
    /// `cloneFile` is a test seam for a clone that fails.
    func clone(to url: URL, id: String, cwd: URL, through end: (bytes: UInt64, lastID: String)? = nil,
               cloneFile: (Int32, String) -> Int32 = { fclonefileat($0, AT_FDCWD, $1, UInt32(CLONE_NOFOLLOW)) }) -> SessionJournal? {
        guard !poisoned, let headerCheck, let lastID = end?.lastID ?? tail else { return nil }
        let keep = end?.bytes ?? bytes, headerEnd = headerCheck.offset + UInt64(headerCheck.length) + 1
        guard keep <= bytes, keep > headerEnd, markerCheck.map({ $0.offset + UInt64($0.length) < keep }) ?? true else { return nil }
        // The file this journal writes, as long as it has written it.
        let source = open(self.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else { return nil }
        defer { _ = close(source) }
        var sourceInfo = stat(), ownInfo = stat()
        guard fstat(source, &sourceInfo) == 0, fstat(handle.fileDescriptor, &ownInfo) == 0,
              sourceInfo.st_dev == ownInfo.st_dev, sourceInfo.st_ino == ownInfo.st_ino,
              sourceInfo.st_mode & S_IFMT == S_IFREG, UInt64(sourceInfo.st_size) == bytes else { return nil }
        // The clone's lock is its own and new; one already there is someone else's.
        let lockPath = url.path + ".lock"
        let lock = open(lockPath, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { return nil }
        var cloned = false, file: FileHandle?
        func abandon() -> SessionJournal? {
            try? file?.close(); if cloned { _ = unlink(url.path) }
            _ = flock(lock, LOCK_UN); _ = close(lock); _ = unlink(lockPath); return nil
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0, cloneFile(source, url.path) == 0 else { return abandon() }
        cloned = true
        let fd = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return abandon() }
        file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat(), last: UInt8 = 0
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, UInt64(info.st_size) == bytes,
              keep == bytes || ftruncate(fd, off_t(keep)) == 0, pread(fd, &last, 1, off_t(keep - 1)) == 1, last == 10 else { return abandon() }
        // The header as this journal wrote it, then the fork's in its place.
        var old = Data(count: headerCheck.length + 1)
        let read = old.withUnsafeMutableBytes { pread(fd, $0.baseAddress, headerCheck.length + 1, off_t(headerCheck.offset)) }
        guard read == headerCheck.length + 1, old.last == 10, JournalCheckpoint.digest(old.dropLast()) == headerCheck.sha256 else { return abandon() }
        let header: JSON = ["type":"session","version":3,"id":JSON(id),"cwd":JSON(cwd.path),"timestamp":JSON(isoNow())]
        guard var line = try? header.data(), line.count <= headerCheck.length else { return abandon() }
        line.append(contentsOf: repeatElement(0x20, count: headerCheck.length - line.count))
        let wrote = line.withUnsafeBytes { pwrite(fd, $0.baseAddress, line.count, off_t(headerCheck.offset)) }
        guard wrote == line.count, (try? file?.seekToEnd()) != nil, let file else { return abandon() }
        // A new file's creation date, as a copy has.
        try? FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: url.path)
        return SessionJournal(cloned: url, lockFD: lock, handle: file, tail: lastID, bytes: keep,
                              header: .init(offset: headerCheck.offset, length: headerCheck.length, sha256: JournalCheckpoint.digest(line)), marker: markerCheck)
    }

    /// Removes what a fork that did not finish (the app quit or crashed
    /// mid-way) left in `directory`: its journal and lock, or a lock alone,
    /// once an hour old and no longer locked. A fork under way holds its lock.
    static func removeForkLeftovers(in directory: URL, olderThan age: TimeInterval = JournalSlimming.leftoverAge) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let cutoff = Date().timeIntervalSince1970 - age
        let journals = names.filter { $0.hasPrefix(".fork-") && $0.hasSuffix(".jsonl") }
        let locksAlone = names.filter { $0.hasPrefix(".fork-") && $0.hasSuffix(".jsonl.lock") && !journals.contains(String($0.dropLast(5))) }
        for name in journals + locksAlone.map({ String($0.dropLast(5)) }) {
            removeForkLeftover(directory.appendingPathComponent(name).path, before: cutoff)
        }
    }
    /// One fork's leftovers at `path`, if they are older than `cutoff`: held
    /// under their lock (one made for the purpose when there is none), and
    /// removed only while the lock and the journal are still the files found.
    private static func removeForkLeftover(_ path: String, before cutoff: TimeInterval) {
        func found(_ path: String) -> (device: dev_t, inode: ino_t, modified: TimeInterval)? {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            return (info.st_dev, info.st_ino, TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        }
        let journal = found(path), lockPath = path + ".lock"
        if let journal, journal.modified >= cutoff { return }
        var lock = open(lockPath, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC), made = false
        if lock < 0 {
            // No lock: one of our own, new, for the journal; any other failure leaves it.
            guard errno == ENOENT, journal != nil else { return }
            lock = open(lockPath, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard lock >= 0 else { return }
            made = true
        }
        defer { _ = flock(lock, LOCK_UN); _ = close(lock) }
        var held = stat()
        guard flock(lock, LOCK_EX | LOCK_NB) == 0, fstat(lock, &held) == 0, held.st_mode & S_IFMT == S_IFREG,
              let named = found(lockPath), named.device == held.st_dev, named.inode == held.st_ino else { return }
        if let journal {
            guard let now = found(path), now.device == journal.device, now.inode == journal.inode, now.modified < cutoff else { return }
            _ = unlink(path); _ = unlink(path + ".meta")
        } else {
            // A lock alone: old itself, and still without its journal.
            guard !made, named.modified < cutoff, found(path) == nil else { return }
        }
        _ = unlink(lockPath)
    }
}
