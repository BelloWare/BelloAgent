import Foundation

// A project's files for finding one by name: listed away from the main
// thread when asked for (`FileListing`), kept as an index (`FileFinderIndex`)
// and listed again when asked for once that is more than a moment old. Asking
// while a listing is under way waits for that one; one stopped is not kept.

public actor FileFinder {
    /// The project's folders, each once. One inside another is listed on
    /// its own, the other passing over its files.
    public nonisolated let roots: [String]
    public nonisolated let limits: FileListingLimits
    private let environment: [String: String]
    private let make: @Sendable ([String], FileListingLimits, [String: String]) async throws -> FileFinderIndex
    private var current: FileFinderIndex?
    private var building: Task<Result<FileFinderIndex, Error>, Never>?
    /// Which listings may still be kept: `cancel` moves it on.
    private var generation = 0
    /// Why the last listing failed, if it did.
    public private(set) var failure: String?

    public init(roots: [String], limits: FileListingLimits = FileListingLimits()) {
        self.init(roots: roots, limits: limits, environment: FinderProcess.environment)
    }
    init(roots: [String], limits: FileListingLimits, environment: [String: String],
         make: @escaping @Sendable ([String], FileListingLimits, [String: String]) async throws -> FileFinderIndex = FileFinder.make) {
        self.roots = Self.distinct(roots)
        self.limits = limits
        self.environment = environment
        self.make = make
    }

    /// Folders as found, each once.
    static func distinct(_ roots: [String]) -> [String] {
        var kept: [String] = []
        for root in roots.map({ URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }) where !kept.contains(root) {
            kept.append(root)
        }
        return kept
    }

    /// The folders of `roots` inside `root`, as paths below it ending "/".
    static func nested(in root: String, among roots: [String]) -> [[UInt8]] {
        let base = Array((root.hasSuffix("/") ? root : root + "/").utf8)
        return roots.compactMap { other in
            let bytes = Array(other.utf8)
            guard bytes.count > base.count, bytes.starts(with: base) else { return nil }
            return Array(bytes[base.count...]) + [0x2F]
        }
    }

    /// The index as last made, without waiting; nil before the first.
    public var latest: FileFinderIndex? { current }

    /// The files as they are: listed again, unless the last listing ended
    /// less than `fresh` ago (its index is still the files) or one is under
    /// way (whose index this waits for). The last index made if listing
    /// fails; nil if none has been.
    public func refreshed(fresh: TimeInterval = 2) async -> FileFinderIndex? {
        if let current, Date().timeIntervalSince(current.madeAt) < fresh, building == nil { return current }
        let task: Task<Result<FileFinderIndex, Error>, Never>
        if let building {
            task = building
        } else {
            let roots = roots, limits = limits, environment = environment, make = make
            // Not the asker's: a listing a reader stopped waiting for still
            // makes the next one's answer ready.
            task = Task.detached(priority: .userInitiated) {
                do { return .success(try await make(roots, limits, environment)) }
                catch { return .failure(error) }
            }
            building = task
        }
        let asked = generation
        let result = await task.value
        // Stopped meanwhile: what it made is not kept, even if it ended.
        guard generation == asked else { return current }
        if building == task { building = nil }
        switch result {
        case .success(let index):
            if current.map({ index.madeAt >= $0.madeAt }) ?? true { current = index }
            failure = nil
        case .failure(let error):
            if !(error is CancellationError) { failure = String(describing: error) }
        }
        return current
    }

    /// Stops a listing under way; the index made before stays.
    public func cancel() {
        generation &+= 1
        building?.cancel()
        building = nil
    }

    @Sendable static func make(_ roots: [String], limits: FileListingLimits, environment: [String: String]) async throws -> FileFinderIndex {
        var listings: [FolderListing] = [], remaining = limits, truncated = false
        for root in roots {
            let listing = try await FileListing.list(root, limits: remaining, excluding: nested(in: root, among: roots),
                                                     environment: environment)
            listings.append(listing)
            remaining.files -= listing.count
            remaining.pathBytes -= listing.bytes.count
            if listing.truncated || remaining.files <= 0 || remaining.pathBytes <= 0 { truncated = listing.truncated || roots.last != root; break }
        }
        try Task.checkCancellation()
        return try FileFinderIndex(roots: Array(roots.prefix(listings.count)), listings: listings, truncated: truncated)
    }
}
