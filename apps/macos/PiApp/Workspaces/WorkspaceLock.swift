import Foundation
import Darwin

// Ownership follows the open file descriptor, not the presence of the file.
final class WorkspaceLock: @unchecked Sendable {
    private let descriptor: Int32
    init(url: URL) throws {
        descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw StoreError.unavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw StoreError.unavailable }
    }
    /// A collector may retire an empty generation while an opener is paused
    /// before flock. Its unlinked descriptor must not become a new owner.
    func matchesFile(at url: URL) -> Bool {
        var held = stat(), named = stat()
        return fstat(descriptor, &held) == 0 && lstat(url.path, &named) == 0 &&
            held.st_dev == named.st_dev && held.st_ino == named.st_ino
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
