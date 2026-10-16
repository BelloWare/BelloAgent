import Foundation

/// Counts discovery work for generated-journal performance regressions. It
/// observes no content and is absent from release helpers.
#if DEBUG
enum SideOriginReadProbe {
    static let lock = NSLock()
    static var observer: ((URL, Int, Int) -> Void)?
    static var scanObserver: ((URL) -> Void)?
    static func observe(_ value: ((URL, Int, Int) -> Void)?, scan: ((URL) -> Void)? = nil) {
        lock.lock(); observer = value; scanObserver = scan; lock.unlock()
    }
    static func scan(_ directory: URL) {
        lock.lock(); defer { lock.unlock() }; scanObserver?(directory)
    }
    static func record(_ file: URL, bytes: Int = 0, decoded: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        observer?(file,bytes,decoded)
    }
}
#endif
