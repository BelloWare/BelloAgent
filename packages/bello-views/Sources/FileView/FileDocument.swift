import Foundation

// A file on disk as the viewer's text (`FileTextSource`), of any size.
//
// Opening it shows its first lines at once. The rest is found away from the
// main thread (`FileScanner`): where every line starts and how long it is,
// kept as each line's UTF-16 length and a checkpoint every 128 lines or
// 256 KiB, whichever comes first. With that, any line is placed, and any
// offset found, without reading the file. Text is read only for what is on
// screen, a run of lines (a page) at a time, off the main thread, into a
// cache of bounded size; a long line is read by the part asked for. Nothing
// on the main thread waits for the disk, opening included: text not read yet
// is nil (`FileTextSource`), and its arrival is told.
//
// The file is the file as it was opened. Found to have changed since (its
// size, times or identity), nothing more is read of it, and the document
// says so; what was read of it as it was still shows.

/// The file as it was opened: a change to any of this is a changed file.
struct FileIdentity: Sendable, Equatable {
    var device: Int64
    var inode: UInt64
    var size: Int64
    var modified: Int64
    var modifiedNanoseconds: Int
    var changed: Int64
    var changedNanoseconds: Int

    init(_ value: stat) {
        device = Int64(value.st_dev); inode = UInt64(value.st_ino); size = Int64(value.st_size)
        modified = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changed = Int64(value.st_ctimespec.tv_sec); changedNanoseconds = value.st_ctimespec.tv_nsec
    }
    static func of(descriptor: Int32) -> FileIdentity? {
        var value = stat()
        return fstat(descriptor, &value) == 0 ? FileIdentity(value) : nil
    }
    static func of(path: String) -> FileIdentity? {
        var value = stat()
        return stat(path, &value) == 0 ? FileIdentity(value) : nil
    }
}

/// An open file's descriptor, shared by every read of it and closed when the
/// last one lets go: closing the document never closes it under a read.
final class FileBytes: @unchecked Sendable {
    // Immutable after init; pread is safe from any thread.
    let descriptor: Int32
    let path: String
    init?(path: String) {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        self.descriptor = descriptor; self.path = path
    }
    deinit { close(descriptor) }

    /// Up to `count` bytes from `offset`: fewer only where the file ends.
    func read(at offset: Int64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        var done = 0
        try data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while done < count {
                let got = pread(descriptor, base + done, count - done, off_t(offset) + off_t(done))
                if got < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if got == 0 { break }
                done += got
            }
        }
        data.count = done
        return data
    }
    /// Whether the file is still the one opened: the same through the
    /// descriptor (not written to) and at its path (not replaced).
    func unchanged(since identity: FileIdentity) -> Bool {
        FileIdentity.of(descriptor: descriptor) == identity && FileIdentity.of(path: path) == identity
    }
}

/// Each line's UTF-16 length, kept in chunks: adding lines never copies the
/// lines before them.
struct FileLengths: Sendable {
    static let chunk = 65_536
    private(set) var chunks: [[UInt32]] = []
    private(set) var count = 0
    subscript(index: Int) -> Int { Int(chunks[index / Self.chunk][index % Self.chunk]) }
    mutating func append(contentsOf lengths: ArraySlice<UInt32>) {
        var rest = lengths
        while !rest.isEmpty {
            if chunks.isEmpty || chunks[chunks.count - 1].count == Self.chunk { chunks.append([]); chunks[chunks.count - 1].reserveCapacity(Self.chunk) }
            let room = Self.chunk - chunks[chunks.count - 1].count
            chunks[chunks.count - 1].append(contentsOf: rest.prefix(room))
            rest = rest.dropFirst(room)
        }
        count += lengths.count
    }
    mutating func removeAll() { chunks = []; count = 0 }
}

@MainActor public final class FileDocument: FileTextSource {
    public enum Status: Equatable, Sendable {
        case indexing
        case ready
        /// Not text: shown by what it is (images, PDFs) or not at all.
        case binary
        /// Changed on disk since it was opened: what is shown is as it was.
        case changed
        /// More lines than are kept: the first `limit` are shown.
        case truncated(limit: Int)
        case failed(String)
    }
    /// How the document reads, for tests to make smaller or slower.
    public struct Options: Sendable {
        public var chunkBytes = 4 << 20
        /// The first lines are shown once this much is read (the first read
        /// is no bigger); then more after every `publishBytes`, or 100 ms,
        /// whichever comes first.
        public var firstPublishBytes = 64 << 10
        public var publishBytes = 8 << 20
        public var publishInterval: Duration = .milliseconds(100)
        /// At most this many lines are kept: 4 bytes each.
        public var lineLimit = 50_000_000
        /// Text kept, in UTF-16 units, across pages and windows, each line
        /// costing a little more than its text. What the screen shows, and
        /// reads held until answered, are kept even past it.
        public var cacheUnits = 8 << 20
        /// Called before opening, before each chunk the pass reads, and
        /// before each page or window is read.
        public var beforeOpen: (@Sendable () async -> Void)?
        public var beforeChunk: (@Sendable (Int64) async -> Void)?
        public var beforePage: (@Sendable () async -> Void)?
        /// Called before a search's count reads each page, with the page,
        /// and before each find.
        public var beforeCount: (@Sendable (Int) async -> Void)?
        public var beforeFind: (@Sendable () async -> Void)?
        public init() {}
    }

    public let url: URL
    public let options: Options
    public private(set) var status: Status = .indexing {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    /// Told when the status changes: for a host's header, beside the view's
    /// own `arrival`.
    public var onStatusChange: ((Status) -> Void)?
    public var isIndexing: Bool { status == .indexing }
    public private(set) var encoding: FileEncoding = .utf8
    /// Read as Latin-1 because its bytes are not UTF-8: said, not hidden.
    public private(set) var fellBack = false
    public private(set) var generation = 0
    public var arrival: ((ClosedRange<Int>) -> Void)?

    private var bytes: FileBytes?
    private(set) var identity: FileIdentity?
    private var start: Int64 = 0
    private var indexing: Task<Void, Never>?
    /// Bumped whenever what is read belongs to another reading of the file:
    /// anything read for an older one is dropped when it comes.
    private var version = 0
    /// Bumped whenever the pass adds to what is known: what was read of the
    /// line the pass was in is not kept if more has been found since.
    private var epoch = 0

    private var lengths = FileLengths()
    private var checkpoints: [FileCheckpoint] = []
    private var longLines: [Int: FileLongLine] = [:]
    private var openLong: FileLongLine?
    private var provisional = 0
    private var finishedUTF16: Int64 = 0
    private var scanned: Int64 = 0
    /// Where the kept text ends, when there are more lines than are kept.
    private var keptEnd: Int64?
    private var complete = false
    public private(set) var longestLine = 0

    /// What is kept of the text read, and what keeps it.
    private var cache: FileReadCache
    /// Reads under way, by what they read, with when each was last asked for.
    private var inFlight: [FileReadCache.Key: Int] = [:]
    /// The screen the view shows, as it said: what it needs is worked out
    /// again whenever what is known of the lines changes.
    private var screen: (lines: ClosedRange<Int>, columns: Range<Int>)?
    /// While a read is held (`holding`), what it has needed.
    private var recording: Set<FileReadCache.Key>?
    /// Test seams: bytes read for text (pages, windows, copies), pages and
    /// windows asked for, what the cache holds as it counts it, holds kept,
    /// and reads under way.
    private(set) var bytesRead = 0
    private(set) var pageLoads = 0
    private(set) var windowRequests = 0
    var cachedCost: Int { cache.cost }
    var cachedPages: Int { cache.pageCount }
    var holdsKept: Int { cache.holdCount }
    var readsUnderWay: Int { inFlight.count + fetching }
    /// Searches waiting for more of the text to be found.
    private var searchWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var searchWaiterTickets = 0
    /// Test seam: reads started for copies and accessibility.
    private(set) var fetchReads = 0
    private var fetching = 0
    #if DEBUG
    /// Test seam: every page read, once each however often.
    private(set) var pagesEverLoaded: Set<Int> = []
    #endif

    /// Opens the file away from the main thread: this returns at once.
    public init(url: URL, options: Options = Options()) {
        self.url = url; self.options = options
        cache = FileReadCache(budget: options.cacheUnits)
        open()
    }
    /// Stops reading. Reads under way finish and are dropped.
    public func close() {
        indexing?.cancel(); indexing = nil
        version += 1
        bytes = nil
        wakeSearches()
    }

    // MARK: Opening

    private func open() {
        let path = url.path, version = version, before = options.beforeOpen
        indexing = Task.detached(priority: .userInitiated) { [weak self] in
            await before?()
            guard let bytes = FileBytes(path: path), let identity = FileIdentity.of(descriptor: bytes.descriptor) else {
                await self?.failed("The file can't be opened.", version: version)
                return
            }
            // A byte order mark says what the file is before anything else
            // does: UTF-16 is mostly zero bytes.
            let head = (try? bytes.read(at: 0, count: 8 << 10)) ?? Data()
            let lead = [UInt8](head.prefix(4))
            let found: (FileEncoding, Int64)?
            if lead.starts(with: [0xEF, 0xBB, 0xBF]) { found = (.utf8, 3) }
            else if lead.starts(with: [0xFF, 0xFE]), !lead.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { found = (.utf16LittleEndian, 2) }
            else if lead.starts(with: [0xFE, 0xFF]) { found = (.utf16BigEndian, 2) }
            else if head.contains(0) { found = nil }
            else { found = (.utf8, 0) }
            await self?.opened(bytes, identity, found, version: version)
        }
    }
    private func opened(_ bytes: FileBytes, _ identity: FileIdentity, _ found: (FileEncoding, Int64)?, version: Int) {
        guard version == self.version else { return }
        self.bytes = bytes; self.identity = identity
        guard let (encoding, start) = found else {
            status = .binary; complete = true
            arrival?(0...0)
            // A search asked before now hears it is not text.
            wakeSearches()
            return
        }
        self.encoding = encoding; self.start = start
        index()
        wakeSearches()
    }

    /// Starts a pass over the file from its text's start, as it is now read.
    private func index() {
        guard let bytes, let identity else { return }
        let encoding = encoding, start = start, version = version, options = options
        indexing = Task.detached(priority: .userInitiated) { [weak self] in
            var scanner = FileScanner(encoding: encoding, start: start)
            var offset = start, since = 0, first = true
            var published = ContinuousClock.now
            do {
                while offset < identity.size {
                    try Task.checkCancellation()
                    await options.beforeChunk?(offset)
                    // Only as far as the file was when it was opened: a file
                    // still being written does not keep the pass going. The
                    // first lines are shown as soon as they are read.
                    let size = first ? min(options.chunkBytes, max(1, options.firstPublishBytes)) : options.chunkBytes
                    let data = try bytes.read(at: offset, count: Int(min(Int64(size), identity.size - offset)))
                    guard !data.isEmpty, bytes.unchanged(since: identity) else {
                        await self?.changed(version: version); return
                    }
                    data.withUnsafeBytes { scanner.feed($0) }
                    offset += Int64(data.count); since += data.count
                    if scanner.invalid {
                        let delta = scanner.take()
                        await self?.invalid(delta, version: version)
                        return
                    }
                    let due = first ? since >= options.firstPublishBytes
                        : since >= options.publishBytes || ContinuousClock.now - published >= options.publishInterval
                    if due {
                        let delta = scanner.take()
                        guard await self?.apply(delta, final: false, version: version) == true else { return }
                        since = 0; first = false; published = .now
                    }
                }
                scanner.finish()
                let delta = scanner.take()
                if scanner.invalid { await self?.invalid(delta, version: version); return }
                _ = await self?.apply(delta, final: true, version: version)
            } catch is CancellationError {
            } catch {
                await self?.failed(error.localizedDescription, version: version)
            }
        }
    }

    /// Takes what the pass found; false when the pass should stop.
    private func apply(_ delta: FileIndexDelta, final: Bool, version: Int) -> Bool {
        guard version == self.version else { return false }
        epoch += 1
        let before = lineCount - 1
        dropOpenLine(before)
        // Past the lines kept, the rest is not shown: more finished lines
        // than there is room for, or the room filled with more to come.
        let room = max(0, options.lineLimit - lengths.count)
        let kept = delta.lengths.prefix(room)
        let over = delta.lengths.count > room || (!final && lengths.count + kept.count >= options.lineLimit)
        lengths.append(contentsOf: kept)
        for length in kept { finishedUTF16 += Int64(length) + 1; longestLine = max(longestLine, Int(length)) }
        for point in delta.checkpoints {
            if point.line < lengths.count || (!over && point.line == lengths.count) { checkpoints.append(point) }
            // The first run of lines not kept starts where the kept text ends.
            else if keptEnd == nil { keptEnd = point.byte }
        }
        for long in delta.longLines where long.line < lengths.count { longLines[long.line] = long }
        if over {
            // Else the kept text ends as far as the pass had read, which is
            // never more than a run of lines and a line past its last run.
            if keptEnd == nil { keptEnd = delta.scanned }
            openLong = nil; provisional = 0
            complete = true
            status = .truncated(limit: options.lineLimit)
            indexing?.cancel()
            applyScreen()
            arrival?(before...max(before, lineCount - 1))
            wakeSearches()
            return false
        }
        openLong = delta.provisionalLong
        provisional = delta.provisional
        longestLine = max(longestLine, provisional)
        scanned = delta.scanned
        if final { complete = true; openLong = nil; if status == .indexing { status = .ready } }
        // Lines found, or become long: what the screen needs may be other.
        applyScreen()
        arrival?(before...max(before, lineCount - 1))
        wakeSearches()
        return true
    }
    /// The bytes are not UTF-8: read again as Latin-1, a new reading of the
    /// file, shown from its start.
    private func invalid(_ delta: FileIndexDelta, version: Int) {
        guard version == self.version else { return }
        if delta.overflow { failed("A line of this file is too long to show.", version: version); return }
        guard encoding == .utf8 else { failed("The file can't be read as text.", version: version); return }
        let shown = lineCount
        reset()
        encoding = .latin1; fellBack = true; start = 0
        generation += 1
        arrival?(0...max(0, shown - 1))
        index()
        wakeSearches()
    }
    /// Changed on disk: nothing more is read of it, and reads under way are dropped.
    private func changed(version: Int) {
        guard version == self.version else { return }
        status = .changed
        indexing?.cancel()
        self.version += 1
        inFlight = [:]
        arrival?(0...max(0, lineCount - 1))
        wakeSearches()
    }
    private func failed(_ message: String, version: Int) {
        guard version == self.version else { return }
        status = .failed(message); complete = true
        indexing?.cancel()
        self.version += 1
        inFlight = [:]
        arrival?(0...max(0, lineCount - 1))
        wakeSearches()
    }
    private func reset() {
        indexing?.cancel(); indexing = nil
        version += 1
        lengths.removeAll(); checkpoints = []; longLines = [:]; openLong = nil
        provisional = 0; finishedUTF16 = 0; scanned = 0; keptEnd = nil; complete = false; longestLine = 0
        cache.removeAll(); inFlight = [:]
        #if DEBUG
        pagesEverLoaded = []
        #endif
        status = .indexing
    }
    public var isReading: Bool { reading }
    /// Whether more is read of the file: not once it has changed or failed.
    private var reading: Bool {
        switch status {
        case .changed, .failed, .binary: return false
        default: return bytes != nil
        }
    }

    // MARK: FileTextSource

    /// The lines found, and while the pass goes on the one it is in.
    public var lineCount: Int { max(1, lengths.count + (complete ? 0 : 1)) }
    public func utf16Length(ofLine index: Int) -> Int {
        if index < lengths.count { return lengths[index] }
        return index == lengths.count && !complete ? provisional : 0
    }
    public var utf16Length: Int {
        let total = complete ? finishedUTF16 - 1 : finishedUTF16 + Int64(provisional)
        return Int(max(0, total))
    }
    /// The run of lines holding a line; there must be one.
    private func checkpoint(holding line: Int) -> Int {
        var low = 0, high = checkpoints.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if checkpoints[middle].line <= line { low = middle } else { high = middle - 1 }
        }
        return low
    }
    public func utf16Start(ofLine index: Int) -> Int {
        guard !checkpoints.isEmpty else { return 0 }
        let line = max(0, min(index, lineCount - 1))
        let point = checkpoints[checkpoint(holding: line)]
        var offset = point.utf16
        for before in point.line..<line { offset += Int64(utf16Length(ofLine: before)) + 1 }
        return Int(offset)
    }
    public func line(atUTF16 offset: Int) -> Int {
        guard !checkpoints.isEmpty else { return 0 }
        var low = 0, high = checkpoints.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if checkpoints[middle].utf16 <= Int64(offset) { low = middle } else { high = middle - 1 }
        }
        var line = checkpoints[low].line, at = checkpoints[low].utf16
        while line < lineCount - 1, at + Int64(utf16Length(ofLine: line)) < Int64(offset) {
            at += Int64(utf16Length(ofLine: line)) + 1; line += 1
        }
        return line
    }

    public func text(ofLine index: Int, range: Range<Int>) -> String? { text(ofLine: index, range: range, asking: true) }
    /// Part of a line, if it is at hand; asking for it reads what is not.
    private func text(ofLine index: Int, range: Range<Int>, asking: Bool) -> String? {
        if status == .binary { return "" }
        guard index >= 0, index < lineCount else { return "" }
        let length = utf16Length(ofLine: index)
        let low = max(0, min(range.lowerBound, length)), high = max(low, min(range.upperBound, length))
        if low == high { return "" }
        // Nothing is known of the file before its first lines are found.
        guard !checkpoints.isEmpty else { return nil }
        if let long = longLine(index) { return longText(long, index: index, low: low, high: high, asking: asking) }
        let page = checkpoint(holding: index), key = FileReadCache.Key.page(page)
        if asking { recording?.insert(key) }
        guard case .page(let firstLine, let lines)? = cache.payload(key, use: asking) else { if asking { load(page: page) }; return nil }
        let offset = index - firstLine
        let line = offset < lines.count ? lines[offset] as NSString : nil
        guard let line, high <= line.length else {
            // Never so: a page is what the pass had found when it comes, and
            // goes when the pass finds more of it. Read again if it ever were.
            cache.remove(key)
            if asking { load(page: page) }
            return nil
        }
        return low == 0 && high == line.length ? lines[offset] : line.substring(with: NSRange(location: low, length: high - low))
    }
    /// The screen the view shows: its lines, and the columns of them in
    /// view. What it needs is kept whatever the budget, until the next
    /// screen; what is around it is read ahead.
    public func showScreen(lines: ClosedRange<Int>, columns: Range<Int>) {
        screen = (lines, columns)
        applyScreen()
    }
    /// Pins what the screen needs, as its lines are known now, reads what of
    /// it is missing, then reads ahead a screen either side.
    private func applyScreen() {
        guard let screen, reading, !checkpoints.isEmpty else { return }
        let first = min(max(0, screen.lines.lowerBound), lineCount - 1), last = min(max(first, screen.lines.upperBound), lineCount - 1)
        var keys: Set<FileReadCache.Key> = []
        for line in first...last {
            guard let long = longLine(line) else { keys.insert(.page(checkpoint(holding: line))); continue }
            // The view reads a line on its grid by the columns it shows, and
            // any other line whole (a long line of wide characters).
            let length = utf16Length(ofLine: line)
            guard length > 0 else { continue }
            let grid = length > FileTextMetrics.gridLine
            let low = grid ? min(max(0, screen.columns.lowerBound), length - 1) : 0
            let high = grid ? min(max(low + 1, screen.columns.upperBound), length) : length
            for mark in Self.mark(before: low, in: long)...Self.mark(before: high - 1, in: long) { keys.insert(.window(line: line, mark: mark)) }
        }
        cache.pin(screen: keys)
        for key in keys where !cache.contains(key) { load(key) }
        // Around the screen, from its middle out, as much as half the cache
        // holds, not kept past the budget: pushing out nothing on screen.
        let span = last - first + 1
        let low = checkpoint(holding: max(0, first - span)), high = checkpoint(holding: min(lineCount - 1, last + span))
        let middle = checkpoint(holding: (first + last) / 2)
        var room = options.cacheUnits / 2
        for distance in 0...max(middle - low, high - middle) {
            for page in distance == 0 ? [middle] : [middle - distance, middle + distance] where page >= low && page <= high {
                // A long line is read by the part the view asks for.
                guard longLine(checkpoints[page].line) == nil else { continue }
                let cost = pageCost(page)
                guard cost <= room else { return }
                room -= cost
                if cache.payload(.page(page), use: true) == nil { load(page: page) }
            }
        }
    }
    /// Runs `body`, which asks for text, and when some of what it asked for
    /// had not come, keeps all of it until the hold returned is let go of:
    /// asked again when it has come, it is all there at once, however much
    /// else is read meanwhile.
    public func holding<T>(_ body: () -> T) -> (T, FileTextHold?) {
        let outer = recording
        recording = []
        let result = body()
        let needed = recording ?? []
        recording = outer.map { $0.union(needed) }
        guard needed.contains(where: { !cache.contains($0) }) else { return (result, nil) }
        let hold = cache.hold(needed)
        return (result, FileTextHold { [weak self] in self?.cache.release(hold) })
    }

    // MARK: Pages

    private func longLine(_ index: Int) -> FileLongLine? {
        if let long = longLines[index] { return long }
        if let open = openLong, open.line == index { return open }
        return nil
    }
    /// A page's lines.
    private func lines(ofPage page: Int) -> ClosedRange<Int> {
        let first = checkpoints[page].line
        let last = page + 1 < checkpoints.count ? checkpoints[page + 1].line - 1 : lineCount - 1
        return first...max(first, last)
    }
    /// What a page costs the cache: its text, and a little for each line and for the page.
    private func pageCost(_ page: Int) -> Int { lines(ofPage: page).reduce(64) { $0 + utf16Length(ofLine: $1) + 16 } }
    /// A page's bytes: from its checkpoint to the next, or to the end of the
    /// kept text, or as far as the pass has read (all of it, once done).
    private func byteRange(ofPage page: Int) -> Range<Int64> {
        let low = checkpoints[page].byte
        let high = page + 1 < checkpoints.count ? checkpoints[page + 1].byte : keptEnd ?? scanned
        return low..<max(low, high)
    }
    private func load(_ key: FileReadCache.Key) {
        switch key {
        case .page(let page): load(page: page)
        case .window(let line, let mark): if let long = longLine(line) { load(window: mark, of: line, long: long) }
        }
    }
    private func load(page: Int) {
        guard reading, let bytes, let identity else { return }
        let key = FileReadCache.Key.page(page)
        // Asked for again while it is being read: as used from now.
        guard inFlight[key] == nil else { inFlight[key] = cache.tick(); return }
        inFlight[key] = cache.tick(); pageLoads += 1
        #if DEBUG
        pagesEverLoaded.insert(page)
        #endif
        let range = byteRange(ofPage: page), lines = lines(ofPage: page)
        let expected = lines.map { utf16Length(ofLine: $0) }
        let last = page + 1 == checkpoints.count
        // Read while the pass is still in its last line, that line is read
        // only as far as the pass has gone, perhaps into a character, and
        // made the length the pass has counted: kept only if the pass has
        // found nothing more by the time it comes.
        let partial = last && !complete ? epoch : nil
        let encoding = encoding, version = version, before = options.beforePage
        Task.detached(priority: .userInitiated) { [weak self] in
            await before?()
            let result: Result<[String], Error>
            do {
                let data = try bytes.read(at: range.lowerBound, count: range.count)
                guard data.count == range.count, bytes.unchanged(since: identity) else { throw CocoaError(.fileReadUnknown) }
                var found = FileDocument.lines(of: data, encoding: encoding, last: last)
                if partial != nil, found.count == expected.count, let open = expected.last {
                    found[found.count - 1] = FileDocument.fitted(found[found.count - 1], to: open)
                }
                // The lines must be those the pass found: anything else is a
                // file that changed under it.
                guard found.count >= expected.count, zip(found, expected).allSatisfy({ ($0.0 as NSString).length == $0.1 }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                result = .success(Array(found.prefix(expected.count)))
            } catch { result = .failure(error) }
            await self?.install(page: page, firstLine: lines.lowerBound, result, bytes: range.count, version: version, partial: partial)
        }
    }
    private func install(page: Int, firstLine: Int, _ result: Result<[String], Error>, bytes: Int, version: Int, partial: Int?) {
        guard version == self.version, let asked = inFlight.removeValue(forKey: .page(page)) else { return }
        switch result {
        case .success(let lines):
            bytesRead += bytes
            let shown = firstLine...(firstLine + max(0, lines.count - 1))
            // Read short of what the pass has found since: read again when asked.
            if let partial, partial != epoch { arrival?(shown); return }
            let cost = lines.reduce(64) { $0 + ($1 as NSString).length + 16 }
            cache.put(.page(page), .page(firstLine: firstLine, lines: lines), cost: cost, asked: asked)
            arrival?(shown)
        case .failure:
            changed(version: version)
        }
    }
    /// Splits bytes into lines at "\n", "\r\n" and "\r", and decodes each.
    /// The last run of lines ends the text: after a final line ending (or in
    /// an empty file) there is one more line, empty.
    nonisolated static func lines(of data: Data, encoding: FileEncoding, last: Bool = false) -> [String] {
        var lines: [String] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let unit = encoding.unit, count = raw.count - raw.count % unit
            func value(_ at: Int) -> UInt16 {
                switch encoding {
                case .utf16LittleEndian: return UInt16(raw[at]) | UInt16(raw[at + 1]) << 8
                case .utf16BigEndian: return UInt16(raw[at]) << 8 | UInt16(raw[at + 1])
                default: return UInt16(raw[at])
                }
            }
            var start = 0, at = 0
            while at < count {
                let v = value(at)
                if v == 0x0A || v == 0x0D {
                    lines.append(decode(UnsafeRawBufferPointer(rebasing: raw[start..<at]), encoding))
                    at += unit
                    if v == 0x0D, at < count, value(at) == 0x0A { at += unit }
                    start = at
                } else { at += unit }
            }
            if start < raw.count { lines.append(decode(UnsafeRawBufferPointer(rebasing: raw[start..<raw.count]), encoding)) }
            else if last { lines.append("") }
        }
        return lines
    }
    nonisolated static func decode(_ bytes: UnsafeRawBufferPointer, _ encoding: FileEncoding) -> String {
        switch encoding {
        case .utf8: return String(decoding: bytes, as: UTF8.self)
        case .latin1: return String(data: Data(bytes), encoding: .isoLatin1) ?? ""
        case .utf16LittleEndian, .utf16BigEndian:
            let little = encoding == .utf16LittleEndian
            var units: [UInt16] = []
            units.reserveCapacity(bytes.count / 2)
            var at = 0
            while at + 1 < bytes.count {
                let first = UInt16(bytes[at]), second = UInt16(bytes[at + 1])
                units.append(little ? first | second << 8 : first << 8 | second)
                at += 2
            }
            var text = String(decoding: units, as: UTF16.self)
            // A lone byte at the file's end is a replacement character.
            if bytes.count % 2 == 1 { text.append("\u{FFFD}") }
            return text
        }
    }
    /// A line read only as far as the pass had gone, made the length the
    /// pass counted for it: a character cut short there is a replacement
    /// character a unit, until the line is read again.
    nonisolated static func fitted(_ text: String, to length: Int) -> String {
        let units = Array(text.utf16)
        if units.count == length { return text }
        if units.count > length { return String(decoding: units.prefix(length), as: UTF16.self) }
        return text + String(repeating: "\u{FFFD}", count: length - units.count)
    }

    // MARK: Long lines

    /// A long line's marks, its start as mark 0.
    private static func mark(_ index: Int, of long: FileLongLine) -> FileLongLine.Mark {
        index == 0 ? FileLongLine.Mark(byte: 0, utf16: 0) : long.marks[index - 1]
    }
    /// The last mark at or before a column.
    private static func mark(before column: Int, in long: FileLongLine) -> Int {
        var low = 0, high = long.marks.count
        while low < high {
            let middle = (low + high + 1) / 2
            if long.marks[middle - 1].utf16 <= Int64(column) { low = middle } else { high = middle - 1 }
        }
        return low
    }
    /// Part of a long line: from the windows between its marks that the part
    /// covers, each read when first asked for.
    private func longText(_ long: FileLongLine, index: Int, low: Int, high: Int, asking: Bool) -> String? {
        let covered = Self.mark(before: low, in: long)...Self.mark(before: high - 1, in: long)
        var parts: [NSString] = []
        var missing = false
        for mark in covered {
            let key = FileReadCache.Key.window(line: index, mark: mark)
            if asking { recording?.insert(key) }
            if case .window(let window)? = cache.payload(key, use: asking) { parts.append(window) }
            else { missing = true; if asking { load(window: mark, of: index, long: long) } }
        }
        guard !missing else { return nil }
        let text: NSString = parts.count == 1 ? parts[0] : parts.reduce(into: NSMutableString()) { $0.append($1 as String) }
        let base = Int(Self.mark(covered.lowerBound, of: long).utf16)
        let from = low - base, to = high - base
        guard from >= 0, to <= text.length, to >= from else { return nil }
        return text.substring(with: NSRange(location: from, length: to - from))
    }
    private func load(window index: Int, of line: Int, long: FileLongLine) {
        guard reading, let bytes, let identity else { return }
        let key = FileReadCache.Key.window(line: line, mark: index)
        guard inFlight[key] == nil else { inFlight[key] = cache.tick(); return }
        inFlight[key] = cache.tick(); windowRequests += 1
        let isLast = index == long.marks.count
        let mark = Self.mark(index, of: long)
        let from = long.byte + mark.byte
        let to = long.byte + (isLast ? long.bytes : Self.mark(index + 1, of: long).byte)
        let end = isLast ? Int64(utf16Length(ofLine: line)) : Self.mark(index + 1, of: long).utf16
        let expected = Int(end - mark.utf16)
        // The last window of the line the pass is still in: as far as the
        // pass has gone, kept only if it has found nothing more since.
        let partial = isLast && openLong?.line == line ? epoch : nil
        let encoding = encoding, version = version, before = options.beforePage
        Task.detached(priority: .userInitiated) { [weak self] in
            await before?()
            let result: Result<String, Error>
            do {
                let count = Int(to - from)
                let data = try bytes.read(at: from, count: count)
                guard data.count == count, bytes.unchanged(since: identity) else { throw CocoaError(.fileReadUnknown) }
                var text = data.withUnsafeBytes { FileDocument.decode($0, encoding) }
                if partial != nil { text = FileDocument.fitted(text, to: expected) }
                guard (text as NSString).length == expected else { throw CocoaError(.fileReadCorruptFile) }
                result = .success(text)
            } catch { result = .failure(error) }
            await self?.install(window: key, line: line, result, bytes: Int(to - from), version: version, partial: partial)
        }
    }
    private func install(window key: FileReadCache.Key, line: Int, _ result: Result<String, Error>, bytes: Int, version: Int, partial: Int?) {
        guard version == self.version, let asked = inFlight.removeValue(forKey: key) else { return }
        switch result {
        case .success(let text):
            bytesRead += bytes
            if let partial, partial != epoch { arrival?(line...line); return }
            let window = text as NSString
            cache.put(key, .window(window), cost: window.length + 64, asked: asked)
            arrival?(line...line)
        case .failure:
            changed(version: version)
        }
    }

    // MARK: The cache

    /// What was read of the line the pass is in may be short of it now: its
    /// page goes, or if it is long, its last window.
    private func dropOpenLine(_ line: Int) {
        guard !checkpoints.isEmpty, !complete else { return }
        cache.remove(.page(checkpoint(holding: line)))
        if let open = openLong, open.line == line { cache.remove(.window(line: line, mark: open.marks.count)) }
    }

    // MARK: Search

    /// A search for a query in the text as it is read now: read again (as
    /// Latin-1), the search is over and says so (`FileSearch.isStale`).
    public func search(_ matcher: FileMatcher) -> FileSearch {
        let reader = FileDocumentSearchReader(document: self, version: version, generation: generation,
                                              beforeCount: options.beforeCount, beforeFind: options.beforeFind)
        return FileSearch(matcher: matcher, reader: reader,
                          lineText: { [weak self] line, range in self?.text(ofLine: line, range: range) },
                          lineLength: { [weak self] line in self?.utf16Length(ofLine: line) ?? 0 },
                          lineFinal: { [weak self] line in self.map { $0.complete || line < $0.lengths.count } ?? true },
                          longPage: { [weak self] line in self?.searchPage(ofLong: line) })
    }
    /// How a search reads the file: through the document's descriptor, as
    /// long as the file is as it was opened.
    struct SearchReading: Sendable {
        let bytes: FileBytes
        let identity: FileIdentity
        let encoding: FileEncoding
    }
    /// What a search asks of the document.
    enum SearchAsk: Sendable {
        case pages(from: Int, limit: Int)
        case page(holding: Int)
        case count
    }
    enum SearchAnswer: Sendable {
        case pages(FileSearchPages, SearchReading)
        case count(Int, SearchReading)
        case end(FileSearchEnd)
    }
    /// Answers a search, from the reading it began in, waiting while what it
    /// asks for has not been found yet but may be.
    func answer(_ ask: SearchAsk, version: Int, generation: Int) async -> SearchAnswer {
        while true {
            if Task.isCancelled { return .end(.stopped("Cancelled")) }
            if let end = searchEnd(version: version, generation: generation) { return .end(end) }
            if let bytes, let identity {
                let reading = SearchReading(bytes: bytes, identity: identity, encoding: encoding)
                // The pages the pass has finished with: all of them once it is through.
                let closed = complete ? checkpoints.count : max(0, checkpoints.count - 1)
                switch ask {
                case .pages(let first, let limit):
                    if first < closed || complete {
                        let pages = (first..<max(first, min(closed, first + max(1, limit)))).map(searchPage)
                        return .pages(FileSearchPages(pages: pages, complete: complete && first + pages.count >= closed), reading)
                    }
                case .page(let line):
                    if !checkpoints.isEmpty {
                        let page = checkpoint(holding: max(0, min(line, lineCount - 1)))
                        if page < closed { return .pages(FileSearchPages(pages: [searchPage(page)], complete: complete), reading) }
                    } else if complete {
                        return .end(.stopped("Empty"))
                    }
                case .count:
                    if complete { return .count(checkpoints.count, reading) }
                }
            }
            // Asked without a gap since looking: nothing is found in between.
            await waitForSearch()
        }
    }
    /// Whether a search begun in a reading may go on: why not if not.
    private func searchEnd(version: Int, generation: Int) -> FileSearchEnd? {
        switch status {
        case .changed: return .stopped("Changed on disk")
        case .failed(let message): return .stopped(message)
        case .binary: return .stopped("Not text")
        default: break
        }
        if generation != self.generation { return .reread }
        if version != self.version { return .stopped("Closed") }
        return nil
    }
    private func searchPage(_ page: Int) -> FileSearchPage {
        let lines = lines(ofPage: page), point = checkpoints[page]
        // Where the page's text ends in the whole text, lines joined by one
        // unit each: the next page's start, less its joining unit, or the
        // text's end.
        let end = page + 1 < checkpoints.count ? checkpoints[page + 1].utf16 - 1 : Int64(utf16Length)
        return FileSearchPage(index: page, firstLine: lines.lowerBound, bytes: byteRange(ofPage: page), lineCount: lines.count,
                              units: Int(end - point.utf16) - (lines.count - 1), long: longLines[lines.lowerBound],
                              last: complete && page + 1 == checkpoints.count)
    }
    /// A long line's page, once the pass is past it: for drawing matches
    /// along it.
    func searchPage(ofLong line: Int) -> FileSearchPage? {
        guard longLines[line] != nil, !checkpoints.isEmpty else { return nil }
        let page = checkpoint(holding: line)
        guard complete || page + 1 < checkpoints.count else { return nil }
        return searchPage(page)
    }
    /// Waits until more of the text is found, or the reading moves on or
    /// ends, or the search is cancelled.
    private func waitForSearch() async {
        searchWaiterTickets += 1
        let ticket = searchWaiterTickets
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled { continuation.resume() } else { searchWaiters[ticket] = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.searchWaiters.removeValue(forKey: ticket)?.resume() }
        }
    }
    private func wakeSearches() {
        let waiters = searchWaiters
        searchWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
    }
    /// A page's lines as a search reads them: decoded as they are shown, each
    /// as long as the pass found it.
    nonisolated static func searchText(of raw: UnsafeRawBufferPointer, encoding: FileEncoding, last: Bool, lines: Int, units: Int) throws -> FileSearchText {
        let text = encoding == .utf8 || encoding == .latin1
            ? quickText(of: raw, latin1: encoding == .latin1, last: last, lines: lines) ?? plainText(of: raw, encoding: encoding, last: last, lines: lines)
            : plainText(of: raw, encoding: encoding, last: last, lines: lines)
        guard text.lineCount == lines, text.units.count == units else { throw FileSearchEnd.stopped("Changed on disk") }
        return text
    }
    /// UTF-8 or Latin-1 straight into UTF-16 units, split into lines as
    /// `lines(of:)` splits them, eight plain ASCII bytes at a time where it
    /// can: nil at the first byte that is not UTF-8, for `plainText` to
    /// decode as the view does.
    nonisolated static func quickText(of raw: UnsafeRawBufferPointer, latin1: Bool, last: Bool, lines wanted: Int) -> FileSearchText? {
        let count = raw.count
        var starts = [0]
        starts.reserveCapacity(wanted + 1)
        var failed = false
        let units = [UInt16](unsafeUninitializedCapacity: max(1, count)) { out, written in
            written = 0
            guard let source = raw.baseAddress?.assumingMemoryBound(to: UInt8.self), let target = out.baseAddress else { return }
            var at = 0, to = 0, lineStart = 0
            func continuation(_ offset: Int) -> Bool { source[at + offset] & 0xC0 == 0x80 }
            while at < count, starts.count <= wanted {
                if at + 8 <= count {
                    let word = UnsafeRawPointer(source + at).loadUnaligned(as: UInt64.self)
                    if word & 0x8080_8080_8080_8080 == 0, !FileScanner.holds(word, 0x0A), !FileScanner.holds(word, 0x0D) {
                        for offset in 0..<8 { target[to + offset] = UInt16(source[at + offset]) }
                        at += 8; to += 8
                        continue
                    }
                }
                let byte = source[at]
                if byte == 0x0A || byte == 0x0D {
                    starts.append(to)
                    at += 1
                    if byte == 0x0D, at < count, source[at] == 0x0A { at += 1 }
                    lineStart = at
                } else if byte < 0x80 || latin1 {
                    target[to] = UInt16(byte); to += 1; at += 1
                } else if byte >= 0xC2, byte <= 0xDF, at + 1 < count, continuation(1) {
                    target[to] = UInt16(byte & 0x1F) << 6 | UInt16(source[at + 1] & 0x3F)
                    to += 1; at += 2
                } else if byte >= 0xE0, byte <= 0xEF, at + 2 < count, continuation(1), continuation(2),
                          byte != 0xE0 || source[at + 1] >= 0xA0, byte != 0xED || source[at + 1] <= 0x9F {
                    target[to] = UInt16(byte & 0x0F) << 12 | UInt16(source[at + 1] & 0x3F) << 6 | UInt16(source[at + 2] & 0x3F)
                    to += 1; at += 3
                } else if byte >= 0xF0, byte <= 0xF4, at + 3 < count, continuation(1), continuation(2), continuation(3),
                          byte != 0xF0 || source[at + 1] >= 0x90, byte != 0xF4 || source[at + 1] <= 0x8F {
                    let scalar = UInt32(byte & 0x07) << 18 | UInt32(source[at + 1] & 0x3F) << 12 | UInt32(source[at + 2] & 0x3F) << 6 | UInt32(source[at + 3] & 0x3F)
                    let value = scalar - 0x10000
                    target[to] = 0xD800 + UInt16(value >> 10); target[to + 1] = 0xDC00 + UInt16(value & 0x3FF)
                    to += 2; at += 4
                } else {
                    failed = true
                    break
                }
            }
            // The text's last line, without a line ending; after a final one,
            // one more, empty, at the text's end.
            if !failed, starts.count <= wanted, lineStart < count || last { starts.append(to) }
            written = to
        }
        return failed ? nil : FileSearchText(units: units, starts: starts)
    }
    /// Decodes each line as the view does (`lines(of:)`).
    nonisolated static func plainText(of raw: UnsafeRawBufferPointer, encoding: FileEncoding, last: Bool, lines wanted: Int) -> FileSearchText {
        var text = FileSearchText()
        text.units.reserveCapacity(raw.count / encoding.unit + 1)
        text.starts.reserveCapacity(wanted + 1)
        let unit = encoding.unit, count = raw.count - raw.count % unit
        func value(_ at: Int) -> UInt16 {
            switch encoding {
            case .utf16LittleEndian: return UInt16(raw[at]) | UInt16(raw[at + 1]) << 8
            case .utf16BigEndian: return UInt16(raw[at]) << 8 | UInt16(raw[at + 1])
            default: return UInt16(raw[at])
            }
        }
        func append(_ from: Int, _ to: Int) {
            text.units.append(contentsOf: decode(UnsafeRawBufferPointer(rebasing: raw[from..<to]), encoding).utf16)
            text.starts.append(text.units.count)
        }
        var start = 0, at = 0
        while at < count, text.lineCount < wanted {
            let v = value(at)
            if v == 0x0A || v == 0x0D {
                append(start, at)
                at += unit
                if v == 0x0D, at < count, value(at) == 0x0A { at += unit }
                start = at
            } else { at += unit }
        }
        if text.lineCount < wanted {
            if start < raw.count { append(start, raw.count) } else if last { text.starts.append(text.units.count) }
        }
        return text
    }

    // MARK: Copy

    /// The text between two positions if all of it is at hand, reading
    /// nothing: only for a selection small enough to build here, on the main
    /// thread, and short of the line the pass is still in. Anything else is
    /// read and built by `fetch`, off it.
    public func textAtHand(from start: FileTextPosition, to end: FileTextPosition) -> String? {
        guard start.line < lineCount, end.line - start.line < 4_096, utf16Offset(of: end) - utf16Offset(of: start) <= 1 << 20 else { return nil }
        // The line the pass is in may be at hand only as far as the pass had
        // gone, a character cut there made placeholders: `fetch` reads it.
        guard complete || end.line < lengths.count else { return nil }
        var parts: [String] = []
        for index in start.line...min(end.line, lineCount - 1) {
            let length = utf16Length(ofLine: index)
            let from = index == start.line ? min(start.column, length) : 0
            let to = index == end.line ? min(end.column, length) : length
            guard let part = text(ofLine: index, range: from..<max(from, to), asking: false) else { return nil }
            parts.append(part)
        }
        return parts.joined(separator: "\n")
    }

    /// The text between two positions, read off the main thread whatever its
    /// size, lines joined by "\n". A long line at either end is read from its
    /// mark nearest the position, not from its start or to its end.
    public func fetch(from start: FileTextPosition, to end: FileTextPosition, completion: @escaping @MainActor (String?) -> Void) {
        guard start < end else { completion(""); return }
        if let text = textAtHand(from: start, to: end) { completion(text); return }
        guard reading, let bytes, let identity, !checkpoints.isEmpty else { completion(nil); return }
        let startPage = checkpoints[checkpoint(holding: start.line)]
        var from = startPage.byte, firstLine = startPage.line, firstBase = 0
        if let long = longLine(start.line) {
            let mark = Self.mark(Self.mark(before: start.column, in: long), of: long)
            from = long.byte + mark.byte; firstLine = start.line; firstBase = Int(mark.utf16)
        }
        var to = byteRange(ofPage: checkpoint(holding: end.line)).upperBound
        if let long = longLine(end.line) {
            let at = Self.mark(before: end.column, in: long), mark = Self.mark(at, of: long)
            if Int(mark.utf16) == end.column { to = long.byte + mark.byte }
            else if at < long.marks.count { to = long.byte + Self.mark(at + 1, of: long).byte }
            else { to = long.byte + long.bytes }
        }
        // The pass may have stopped inside a character of the line it is
        // in: the few bytes that finish it are read too.
        if !complete, to >= scanned { to = min(identity.size, to + 3) }
        let encoding = encoding, version = version, before = options.beforePage
        fetchReads += 1; fetching += 1
        Task.detached(priority: .userInitiated) { [weak self] in
            await before?()
            var text: String?
            var read = 0
            let count = Int(max(0, to - from))
            if let data = try? bytes.read(at: from, count: count), data.count == count, bytes.unchanged(since: identity) {
                read = count
                // Read to where a line starts, there is that line, empty so far.
                let lines = FileDocument.lines(of: data, encoding: encoding, last: true)
                let wanted = (start.line - firstLine)...(end.line - firstLine)
                if lines.indices.contains(wanted.upperBound) {
                    var parts: [String] = []
                    for (offset, line) in lines[wanted].enumerated() {
                        let ns = line as NSString
                        let base = offset == 0 ? firstBase : 0
                        let low = max(0, min(offset == 0 ? start.column - base : 0, ns.length))
                        let high = max(low, min(offset == wanted.count - 1 ? end.column - base : ns.length, ns.length))
                        parts.append(ns.substring(with: NSRange(location: low, length: high - low)))
                    }
                    text = parts.joined(separator: "\n")
                }
            }
            let copied = text, counted = read
            await MainActor.run { [weak self] in
                guard let self else { completion(nil); return }
                self.fetching -= 1
                guard version == self.version else { completion(nil); return }
                self.bytesRead += counted
                completion(copied)
            }
        }
    }
}

/// How a search reads a document: pages as the pass finishes with them,
/// through the document's own descriptor, away from the main thread.
final class FileDocumentSearchReader: FileSearchReader, @unchecked Sendable {
    // The document is only asked, on the main actor; the reading is kept
    // under the lock once told.
    private weak var document: FileDocument?
    private let version: Int
    private let generation: Int
    private let lock = NSLock()
    private var kept: FileDocument.SearchReading?
    private let beforeCount: (@Sendable (Int) async -> Void)?
    private let beforeFind: (@Sendable () async -> Void)?

    init(document: FileDocument, version: Int, generation: Int, beforeCount: (@Sendable (Int) async -> Void)?, beforeFind: (@Sendable () async -> Void)?) {
        self.document = document; self.version = version; self.generation = generation
        self.beforeCount = beforeCount; self.beforeFind = beforeFind
    }
    func beforeCounting(_ page: Int) async { await beforeCount?(page) }
    func beforeFinding() async { await beforeFind?() }
    private func ask(_ ask: FileDocument.SearchAsk) async throws -> FileDocument.SearchAnswer {
        try Task.checkCancellation()
        guard let document else { throw FileSearchEnd.stopped("Closed") }
        let answer = await document.answer(ask, version: version, generation: generation)
        try Task.checkCancellation()
        switch answer {
        case .pages(_, let reading), .count(_, let reading): lock.withLock { kept = reading }
        case .end(let end): throw end
        }
        return answer
    }
    private var reading: FileDocument.SearchReading {
        get throws {
            guard let reading = lock.withLock({ kept }) else { throw FileSearchEnd.stopped("Closed") }
            return reading
        }
    }

    func pages(from first: Int, limit: Int) async throws -> FileSearchPages {
        guard case .pages(let pages, _) = try await ask(.pages(from: first, limit: limit)) else { throw FileSearchEnd.stopped("Closed") }
        return pages
    }
    func page(holding line: Int) async throws -> FileSearchPage {
        guard case .pages(let pages, _) = try await ask(.page(holding: line)), let page = pages.pages.first else { throw FileSearchEnd.stopped("Closed") }
        return page
    }
    func pageCount() async throws -> Int {
        guard case .count(let count, _) = try await ask(.count) else { throw FileSearchEnd.stopped("Closed") }
        return count
    }
    func text(of page: FileSearchPage) throws -> FileSearchText { try texts(of: [page])[0] }
    /// Pages that follow one another, read at once and checked once.
    func texts(of pages: [FileSearchPage]) throws -> [FileSearchText] {
        guard let low = pages.first?.bytes.lowerBound, let high = pages.last?.bytes.upperBound else { return [] }
        let reading = try reading
        let data = try reading.bytes.read(at: low, count: Int(high - low))
        guard data.count == Int(high - low), reading.bytes.unchanged(since: reading.identity) else { throw FileSearchEnd.stopped("Changed on disk") }
        return try data.withUnsafeBytes { raw in
            try pages.map { page in
                let slice = UnsafeRawBufferPointer(rebasing: raw[Int(page.bytes.lowerBound - low)..<Int(page.bytes.upperBound - low)])
                return try FileDocument.searchText(of: slice, encoding: reading.encoding, last: page.last, lines: page.lineCount, units: page.units)
            }
        }
    }
    func window(_ window: Int, of page: FileSearchPage) throws -> [UInt16] {
        guard let long = page.long else { return [] }
        let reading = try reading
        let from = window == 0 ? 0 : long.marks[window - 1].byte
        let to = window == long.marks.count ? long.bytes : long.marks[window].byte
        let start = window == 0 ? 0 : long.marks[window - 1].utf16
        let end = window == long.marks.count ? Int64(page.units) : long.marks[window].utf16
        let data = try reading.bytes.read(at: long.byte + from, count: Int(to - from))
        guard data.count == Int(to - from), reading.bytes.unchanged(since: reading.identity) else { throw FileSearchEnd.stopped("Changed on disk") }
        let units = Array(data.withUnsafeBytes { FileDocument.decode($0, reading.encoding) }.utf16)
        guard units.count == Int(end - start) else { throw FileSearchEnd.stopped("Changed on disk") }
        return units
    }
}
