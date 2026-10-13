import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The packets already prepared for the native recorder, before delivery.
/// Only sanitized capture packets enter here: off/memory modes never emit
/// body pages. There is no byte or request cap. Each attempt is retained in
/// full until its terminal record and every queued packet are acknowledged,
/// because an acknowledged body page can still be in the owner's chunker.
/// Owned by TraceStore; no actor or network wait is needed to make it durable.
final class CaptureSpool {
    private final class File {
        let url: URL
        var handle: FileHandle?
        var revision = 0, terminal = false, refused = false
        init(url: URL, handle: FileHandle, terminal: Bool) { self.url=url; self.handle=handle; self.terminal=terminal }
        deinit { try? handle?.close() }
    }
    let directory: URL
    let recovered: [URL]
    private var files: [String: File] = [:]
    /// The open descriptors, for the backlog regression test.
    var openFileCount: Int { files.values.reduce(0) { $0 + ($1.handle == nil ? 0 : 1) } }

    init(in state: URL) throws {
        directory=state.appendingPathComponent(".capture-outbox", isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        // Do not follow a substituted directory or any replay file's symlink.
        let attributes=try FileManager.default.attributesOfItem(atPath:directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw Self.unavailable() }
        recovered=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
            .filter { $0.pathExtension == "jsonl" && UUID(uuidString:$0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try Self.syncDirectory(directory.deletingLastPathComponent())
    }
    @discardableResult func append(_ packet: JSON, attempt: String) throws -> Int {
        guard UUID(uuidString:attempt) != nil else { throw Self.unavailable() }
        let file: File
        if let existing=files[attempt] { file=existing }
        else {
            let url=directory.appendingPathComponent(attempt+".jsonl")
            let fd=open(url.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
            guard fd >= 0 else { throw Self.unavailable() }
            file=File(url:url,handle:FileHandle(fileDescriptor:fd,closeOnDealloc:true),terminal:packet["type"].text != "begin")
            files[attempt]=file
            try Self.syncDirectory(directory)
        }
        do {
            let handle: FileHandle
            if let opened=file.handle { handle=opened }
            else {
                // Output links can follow a finished request. Reopen only
                // for that append; a slow owner leaves no descriptor per
                // completed attempt, however large the durable backlog is.
                let fd=open(file.url.path,O_WRONLY | O_APPEND | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw Self.unavailable() }
                var info=stat()
                guard fstat(fd,&info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { _=close(fd); throw Self.unavailable() }
                handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true); file.handle=handle
            }
            var bytes=try packet.data(); bytes.append(10)
            try handle.write(contentsOf:bytes); try handle.synchronize()
            file.revision += 1
            if packet["type"].text == "finish" { file.terminal=true }
            if file.terminal { try handle.close(); file.handle=nil }
            return file.revision
        } catch { file.refused=true; try? file.handle?.close(); file.handle=nil; throw error }
    }
    func confirmed(_ attempt: String, through revision: Int?, accepted: Bool) throws {
        guard let file=files[attempt], let revision else { return }
        if !accepted { file.refused=true }
        guard accepted, !file.refused, file.terminal, revision == file.revision else { return }
        try discard(attempt)
    }
    func discard(_ attempt: String) throws {
        let url=directory.appendingPathComponent(attempt+".jsonl")
        guard FileManager.default.fileExists(atPath:url.path) else { return }
        try FileManager.default.removeItem(at:url)
        files.removeValue(forKey:attempt)
        try Self.syncDirectory(directory)
    }
    func removeRecovered(_ url: URL) throws {
        try FileManager.default.removeItem(at:url); try Self.syncDirectory(directory)
    }
    private static func syncDirectory(_ directory: URL) throws {
        let fd=open(directory.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw unavailable() }
        defer { _=close(fd) }
        guard fsync(fd) == 0 else { throw unavailable() }
    }
    private static func unavailable() -> AgentError { AgentError("capture_spool", "Request capture recovery storage is unavailable") }
}
