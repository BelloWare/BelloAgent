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
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
