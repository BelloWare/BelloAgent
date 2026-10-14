import Foundation
import Darwin

/// Bounded, read-only reflog metadata for detecting stale stash selections.
/// Native Git owns ref/reflog writes, locking and repository permissions.
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
}
