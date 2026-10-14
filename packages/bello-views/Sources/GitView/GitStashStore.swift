import Foundation
import Darwin

/// Stash selectors are reflog positions, not stable IDs. Git's ref lock is
/// held across identity validation and publication, so another stash push,
/// drop or pop cannot retarget an approved deletion. Files-ref repositories
/// are supported; an unfamiliar/packed stash store is refused intact.
struct GitStashStore {
    private static let limit = 4 * 1024 * 1024
    static func readLog(in directory: String) throws -> Data {
        try read(directory + "/logs/refs/stash", missing: true)
    }
    private static func read(_ path: String, missing: Bool = false) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0, errno == ENOENT, missing { return Data() }
        guard fd >= 0 else { throw GitFailure(message: "The stash store could not be read safely.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { throw GitFailure(message: "The stash store is unsupported or too large. Manage it in the terminal.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw GitFailure(message: "The stash store grew. Refresh the list.") }
        return data
    }
    private static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw GitFailure(message: "The stash update could not be saved.") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw GitFailure(message: "The stash update could not be synced.") }
    }
    private static func preservePermissions(from path: String, on fd: Int32) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              fchmod(fd, info.st_mode & 0o777) == 0 else {
            throw GitFailure(message: "The stash file permissions could not be preserved. Nothing was removed.")
        }
    }
    static func drop(_ stash: GitStashRecord, in directory: String, afterPublication: (() throws -> Void)? = nil) throws {
        let ref = directory + "/refs/stash", log = directory + "/logs/refs/stash"
        // No symlinked parents or alternate ref storage is followed by writes.
        for path in [directory, directory + "/refs", directory + "/logs", directory + "/logs/refs"] {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw GitFailure(message: "This stash store needs to be managed in the terminal.") }
        }
        let lockPath = ref + ".lock", logLockPath = log + ".lock"
        let lock = open(lockPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw GitFailure(message: "Another Git operation holds the stash lock. Try again when it finishes.") }
        var ownsRefLock = true
        defer { close(lock); if ownsRefLock { unlink(lockPath) } }
        let logLock = open(logLockPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard logLock >= 0 else { throw GitFailure(message: "Another operation holds the stash log lock. Try again when it finishes.") }
        var ownsLogLock = true
        defer { close(logLock); if ownsLogLock { unlink(logLockPath) } }
        let original = try readLog(in: directory), tip = try read(ref)
        try preservePermissions(from: ref, on: lock)
        try preservePermissions(from: log, on: logLock)
        guard GitService.stashFingerprint(original) == stash.logFingerprint else { throw GitFailure(message: "The stash list changed. Refresh and choose the stash again.") }
        let packed = try read(directory + "/packed-refs", missing: true)
        guard !String(decoding: packed, as: UTF8.self).split(separator: "\n").contains(where: { $0.hasSuffix(" refs/stash") }) else {
            throw GitFailure(message: "This stash reference is packed. Manage its removal in the terminal; the stash was kept.")
        }
        var lines = original.split(separator: UInt8(10)).map { Data($0) }
        guard original.last == 10, let number = Int(stash.selector.dropFirst(7).dropLast()), number >= 0, number < lines.count else { throw GitFailure(message: "Choose the stash again.") }
        let index = lines.count - 1 - number
        func ids(_ line: Data) -> [Substring] { String(decoding: line, as: UTF8.self).split(separator: " ", maxSplits: 2) }
        guard lines.allSatisfy({ ids($0).count == 3 }), ids(lines[index])[1] == stash.oid,
              ids(lines.last!)[1] == String(decoding: tip, as: UTF8.self).trimmingCharacters(in: .newlines) else {
            throw GitFailure(message: "The stash store changed or is unfamiliar. Nothing was removed.")
        }
        let old = String(ids(lines[index])[0]); lines.remove(at: index)
        if index < lines.count {
            // Identity and message bytes may use a non-UTF-8 repository
            // encoding. Only the leading OID changes; preserve the raw tail.
            guard let space = lines[index].firstIndex(of: 32) else { throw GitFailure(message: "Unfamiliar stash log. Nothing was removed.") }
            lines[index] = Data((old + " ").utf8) + lines[index][lines[index].index(after: space)...]
        }
        var nextLog = Data()
        for line in lines { nextLog.append(line); nextLog.append(10) }
        try write(nextLog, to: logLock)
        if let last = lines.last { try write(Data((String(ids(last)[1]) + "\n").utf8), to: lock) }
        guard rename(logLockPath, log) == 0 else { throw GitFailure(message: "The stash log could not be replaced. Nothing was removed.") }
        ownsLogLock = false
        let published = lines.isEmpty ? unlink(ref) == 0 : rename(lockPath, ref) == 0
        if published && !lines.isEmpty { ownsRefLock = false }
        if !published {
            // The ref is still locked. Restore the original log before giving
            // up, so a failed publication does not silently shift selectors.
            try original.write(to: URL(fileURLWithPath: log), options: .atomic)
            throw GitFailure(message: "The stash reference could not be replaced. The stash was kept.")
        }
        try afterPublication?()
    }
}
