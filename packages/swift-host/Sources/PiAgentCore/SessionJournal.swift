import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// The append-only session journal: the durable record of one chat.

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
    private var tail: String?, bytes: UInt64
    private var unsynced = false
    /// Test seams: how many records were written and how many times they were
    /// forced to stable storage, so the batching contract is assertable
    /// without timing a disk.
    private(set) var appends = 0, synchronizations = 0
    private let beforeAppend: @Sendable (JSON) throws -> Void
    private let beforeSynchronize: @Sendable () throws -> Void
    let loaded: [JSON]
    init(url: URL, id: String, cwd: URL, binding: JSON, create: Bool, beforeAppend: @escaping @Sendable (JSON) throws -> Void = { _ in }, beforeSynchronize: @escaping @Sendable () throws -> Void = {}) throws {
        self.url=url; self.beforeAppend=beforeAppend; self.beforeSynchronize=beforeSynchronize
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        lockFD=open(url.path + ".lock",O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard lockFD >= 0 else { throw AgentError("session_lock", "Cannot create session writer lock") }
        guard flock(lockFD,LOCK_EX|LOCK_NB) == 0 else { _ = close(lockFD); throw AgentError("session_locked", "Another process owns this session") }
        do {
            if create {
                let fd=open(url.path,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0o600)
                guard fd >= 0 else { throw AgentError("session_exists", "Session path already exists; open it explicitly") }
                _=close(fd)
                let header: JSON = ["type":"session","version":3,"id":JSON(id),"cwd":JSON(cwd.path),"timestamp":JSON(isoNow())]
                var data=try header.data(); data.append(10); try data.write(to:url)
            }
            let data=try readBounded(url,maximum:128*1024*1024)
            guard data.last == 10 else { throw AgentError("session_damaged", "Incomplete journal tail preserved; recover a copy before continuing") }
            var records: [JSON]=[]
            for line in data.split(separator:10) { guard line.count <= 32*1024*1024 else { throw AgentError("session_damaged", "Journal record exceeds limit") }; records.append(try JSON.parse(Data(line))) }
            guard let header=records.first, header["type"].text == "session", header["version"].int == 3, header["id"].text == id else { throw AgentError("session_identity", "Session header does not match its identity") }
            var last: String?, seen=Set<String>()
            for item in records.dropFirst() {
                let rid=try identity(item["id"])
                guard seen.insert(rid).inserted, item["parentId"].text == last else { throw AgentError("session_damaged", "Native journal must be a valid single branch") }; last=rid
            }
            if !create {
                guard let marker=records.first(where:{$0["customType"].text == "pi-app.native.v1"}), marker["data"]["binding"] == binding else { throw AgentError("legacy_session", "This is not a compatible native session. Original Pi history remains read-only; use an explicit portable handoff.") }
            }
            loaded=Array(records.dropFirst()); tail=last; bytes=UInt64(data.count); handle=try FileHandle(forWritingTo:url); try handle.seekToEnd()
        } catch { _=flock(lockFD,LOCK_UN); _=close(lockFD); throw error }
        if create { try append(["type":"custom","customType":"pi-app.native.v1","data":["binding":binding,"version":1]]) }
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
        guard data.count <= 32*1024*1024, bytes+UInt64(data.count) <= 128*1024*1024 else { throw AgentError("session_limit", "Session journal size limit reached; start a new chat") }
        try beforeAppend(v)
        do { try handle.write(contentsOf:data) } catch { poisoned=true; throw error }
        tail=id; bytes += UInt64(data.count); unsynced=true; appends += 1
        if flush { try synchronize() }
        return id
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
        let newFD=open(destination.path + ".lock",O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard newFD >= 0 else { throw AgentError("session_lock", "Cannot acquire destination lock") }
        guard flock(newFD,LOCK_EX|LOCK_NB) == 0 else { _=close(newFD); throw AgentError("session_locked", "Destination is owned by another writer") }
        do { try FileManager.default.moveItem(at:url,to:destination) }
        catch { _=flock(newFD,LOCK_UN); _=close(newFD); throw error }
        let old=url; _=flock(lockFD,LOCK_UN); _=close(lockFD); lockFD=newFD; url=destination
        try? FileManager.default.removeItem(atPath:old.path+".lock")
    }
    func records() throws -> [JSON] {
        guard !poisoned else { throw AgentError("session_damaged", "A failed journal write must be recovered before forking") }
        let data=try readBounded(url,maximum:128*1024*1024)
        guard data.last == 10, data.count == bytes else { throw AgentError("session_damaged", "The source journal changed or has an incomplete tail") }
        return try data.split(separator:10).dropFirst().map { try JSON.parse(Data($0)) }
    }
    deinit { try? synchronize(); try? handle.close(); _=flock(lockFD,LOCK_UN); _=close(lockFD) }
}
