import Foundation
import Darwin

struct GitIndexSnapshot: Sendable {
    let path: String, bytes: Data, permissions: mode_t
    static let maximumBytes = 64 * 1024 * 1024
    static func read(at path: String) throws -> Self {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw GitFailure(message: "The index is unavailable. Use whole-file staging.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= maximumBytes else {
            throw GitFailure(message: "The index is too large or is not a regular file. Use whole-file staging.")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard bytes.count == info.st_size else { throw GitFailure(message: "The index changed while reading. Review it again.") }
        return Self(path: path, bytes: bytes, permissions: info.st_mode & 0o777)
    }
    func copyForGit() throws -> GitPrivateIndex {
        let copy = GitPrivateIndex(path: URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("bello-hunk-" + UUID().uuidString).path)
        try GitPrivateIndex.write(bytes, to: copy.path)
        return copy
    }
}

struct GitPrivateIndex: Sendable {
    let path: String
    func remove() { unlink(path); unlink(path + ".lock") }
    static func write(_ bytes: Data, to path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw GitFailure(message: "Could not create the private index transaction file.") }
        defer { close(fd) }
        do { try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: bytes) }
        catch { unlink(path); throw error }
    }
}

/// Git's own lock protocol: O_EXCL index.lock, validate while held, write
/// the finished index into that lock, fsync, then rename over index. A private
/// index is the only index Git commands write until this atomic publication.
struct GitIndexTransaction {
    let snapshot: GitIndexSnapshot
    private let fd: Int32
    private let inode: ino_t
    private var lockPath: String { snapshot.path + ".lock" }

    init(_ snapshot: GitIndexSnapshot) throws {
        self.snapshot = snapshot
        fd = open(snapshot.path + ".lock", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, snapshot.permissions)
        guard fd >= 0 else { throw GitFailure(message: "Git's index is locked. Wait for the other Git action, then refresh and review again.") }
        var info = stat()
        guard fstat(fd, &info) == 0 else { close(fd); unlink(snapshot.path + ".lock"); throw GitFailure(message: "Could not inspect the index lock.") }
        guard fchmod(fd, snapshot.permissions) == 0 else { close(fd); unlink(snapshot.path + ".lock"); throw GitFailure(message: "Could not preserve index permissions.") }
        inode = info.st_ino
    }
    private var ownsLock: Bool {
        var info = stat()
        return lstat(lockPath, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_ino == inode
    }
    func finish() {
        if ownsLock { unlink(lockPath) }
        close(fd)
    }
    func validate() throws {
        guard ownsLock, try GitIndexSnapshot.read(at: snapshot.path).bytes == snapshot.bytes else {
            throw GitFailure(message: "The index changed since this diff was reviewed. Refresh and review it again.")
        }
    }
    // Internal deterministic seam for cancellation/publication race tests.
    func publish(_ bytes: Data, beforePublication: (() throws -> Void)? = nil) throws {
        try validate()
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: bytes)
        guard fsync(fd) == 0 else { throw GitFailure(message: "Could not save the index. Nothing was staged.") }
        try beforePublication?()
        try Task.checkCancellation()
        try validate()
        guard rename(lockPath, snapshot.path) == 0 else { throw GitFailure(message: "Could not publish the index. Nothing was staged.") }
        // A failed directory sync is an uncertain durability outcome after
        // publication. Report it; callers reconcile, never replay the hunk.
        let directory = open(URL(fileURLWithPath: snapshot.path).deletingLastPathComponent().path, O_RDONLY)
        defer { if directory >= 0 { close(directory) } }
        guard directory >= 0, fsync(directory) == 0 else {
            throw GitFailure(message: "The index was updated, but its durability could not be confirmed. Refresh to inspect it; do not repeat the action automatically.")
        }
    }
}

/// Read only a bounded regular working file, refusing symlinks in every path
/// component and FIFOs/devices before any blocking read. No content conversion.
struct GitPatchFile {
    let bytes: Data, mode: String
    static func read(in root: String, path: String) throws -> Self {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw GitFailure(message: "Use whole-file staging for this path.")
        }
        var directory = open(root, O_RDONLY | O_DIRECTORY)
        guard directory >= 0 else { throw GitFailure(message: "The repository is unavailable.") }
        defer { close(directory) }
        for part in parts.dropLast() {
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw GitFailure(message: "Use whole-file staging for paths through symlinks or missing directories.") }
            close(directory); directory = next
        }
        let fd = openat(directory, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw GitFailure(message: "Use whole-file staging for symlinks or deleted files.") }
        defer { close(fd) }
        var info = stat()
        let limit = 4 * 1024 * 1024
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else {
            throw GitFailure(message: "Use whole-file staging for special files or files over 4 MiB.")
        }
        let bytes = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: limit + 1) ?? Data()
        guard bytes.count == info.st_size else { throw GitFailure(message: "The file changed while reading. Refresh and review it again.") }
        return Self(bytes: bytes, mode: info.st_mode & 0o111 == 0 ? "100644" : "100755")
    }
}
