import Foundation

// Finding a query in a file of any size (`FileSearch`): counting its matches,
// and going to the next or the one before, both away from the main thread
// and neither waiting for the other.
//
// A search reads the file as the viewer shows it, a page (a run of lines) at
// a time, through its own reads: never through what the view keeps, so a
// search never takes the screen's text from it. A long line is read a window
// at a time. What a search keeps is a count for each page, and for each
// window of a long line: never the matches themselves.
//
// Matches are what `FileMatcher` says: in each line, leftmost first, each
// sought from where the one before ended. A query whose matches could
// overlap ("aba") makes where matching resumes depend on what came before,
// so a long line is then matched from its start, and the count keeps where
// matching resumes at the start of each of its windows, for going to a match
// and drawing matches anywhere along it after.

/// A match: its line and its columns, and where it is among all the matches,
/// for its place in their count.
public struct FileSearchHit: Equatable, Sendable {
    public let line: Int
    public let columns: Range<Int>
    /// The page it is in, the window of a long line it starts in (0 in any
    /// other page), and how many matches come before it there.
    let page: Int
    let window: Int
    let index: Int

    public var start: FileTextPosition { FileTextPosition(line: line, column: columns.lowerBound) }
    public var end: FileTextPosition { FileTextPosition(line: line, column: columns.upperBound) }
}

/// A page as a search reads it: where its bytes are, its first line, and
/// how many lines and UTF-16 units the pass found in it, which what is read
/// must agree with.
struct FileSearchPage: Sendable, Equatable {
    var index: Int
    var firstLine: Int
    var bytes: Range<Int64>
    var lineCount: Int
    /// Its lines' UTF-16 units, line endings not counted.
    var units: Int
    /// A long line's page: its one line, read a window at a time.
    var long: FileLongLine?
    /// The text's last page: after a final line ending, one more line, empty.
    var last: Bool

    /// A long line's windows: between its start, its marks and its end.
    var windowCount: Int { (long?.marks.count ?? 0) + 1 }
    /// Where a window starts in the line, in UTF-16 units.
    func windowStart(_ window: Int) -> Int {
        guard let long, window > 0 else { return 0 }
        return Int(long.marks[window - 1].utf16)
    }
    /// The window a column of a long line is in.
    func window(holding column: Int) -> Int {
        guard let long else { return 0 }
        var low = 0, high = long.marks.count
        while low < high {
            let middle = (low + high + 1) / 2
            if long.marks[middle - 1].utf16 <= Int64(column) { low = middle } else { high = middle - 1 }
        }
        return low
    }
}

/// The pages that can be read, from where they were asked for.
struct FileSearchPages: Sendable {
    var pages: [FileSearchPage]
    /// No more pages will come after these.
    var complete: Bool
}

/// A page's lines as UTF-16 units, one after another, and where each starts
/// (with the end after the last).
struct FileSearchText: Sendable {
    var units: [UInt16] = []
    var starts: [Int] = [0]
    var lineCount: Int { starts.count - 1 }
}

/// Why a search stopped short of the whole text.
enum FileSearchEnd: Error, Sendable {
    /// The text was read again (as Latin-1): search it anew.
    case reread
    /// The file changed or failed, or was closed.
    case stopped(String)
}

/// What a search reads, away from the main thread: the text's pages as the
/// pass finds them, and their text as it is shown.
protocol FileSearchReader: Sendable {
    /// Pages from `first` on that can be read now, at most `limit`; while
    /// there are none but more may come, it waits for them.
    func pages(from first: Int, limit: Int) async throws -> FileSearchPages
    /// The page holding a line, once it can be read.
    func page(holding line: Int) async throws -> FileSearchPage
    /// How many pages there are, once the text has been read through.
    func pageCount() async throws -> Int
    /// A page's lines, as shown. Throws if the file is not what it was.
    func text(of page: FileSearchPage) throws -> FileSearchText
    /// Pages that follow one another (none a long line's), read together.
    func texts(of pages: [FileSearchPage]) throws -> [FileSearchText]
    /// One window of a long line's page, as shown.
    func window(_ window: Int, of page: FileSearchPage) throws -> [UInt16]
    /// Test seams: before the count reads a page, and before a find.
    func beforeCounting(_ page: Int) async
    func beforeFinding() async
}
extension FileSearchReader {
    func texts(of pages: [FileSearchPage]) throws -> [FileSearchText] { try pages.map(text) }
    func beforeCounting(_ page: Int) async {}
    func beforeFinding() async {}
}

// MARK: Matching pages and long lines

enum FileSearchScan {
    /// Every match in a page's lines, in order: the line within the page and
    /// the column. The text is prepared (folded) here.
    static func matches(in text: inout FileSearchText, _ matcher: FileMatcher) -> [(line: Int, column: Int)] {
        var found: [(line: Int, column: Int)] = []
        let starts = text.starts
        text.units.withUnsafeMutableBufferPointer { units in
            matcher.prepare(units)
            guard let base = units.baseAddress else { return }
            for line in 0..<(starts.count - 1) {
                let from = starts[line], to = starts[line + 1]
                guard to - from >= matcher.length else { continue }
                matcher.scan(UnsafeBufferPointer(start: base + from, count: to - from), from: 0) { column in
                    found.append((line, column)); return true
                }
            }
        }
        return found
    }
    /// How many matches a page's lines hold.
    static func count(in text: inout FileSearchText, _ matcher: FileMatcher) -> Int {
        var count = 0
        let starts = text.starts
        text.units.withUnsafeMutableBufferPointer { units in
            matcher.prepare(units)
            guard let base = units.baseAddress else { return }
            for line in 0..<(starts.count - 1) {
                let from = starts[line], to = starts[line + 1]
                guard to - from >= matcher.length else { continue }
                matcher.scan(UnsafeBufferPointer(start: base + from, count: to - from), from: 0) { _ in count += 1; return true }
            }
        }
        return count
    }
}

/// A long line matched as one stream, fed its windows (or any runs of it) in
/// order: what it keeps between them is where matching resumes and the few
/// units before the end that a match could still start in.
struct FileLongScan {
    let matcher: FileMatcher
    /// Prepared units from `carryStart` to the end of what was fed.
    private var carry: [UInt16] = []
    private(set) var carryStart: Int
    /// Where matching resumes: no match starts between here and the end of
    /// what was fed, before the units kept.
    private(set) var resume: Int
    /// The end of the last match found, if any.
    private(set) var lastEnd: Int?

    /// Starting at a column where matching resumes: the line's start, or a
    /// window's resume point.
    init(_ matcher: FileMatcher, from column: Int) {
        self.matcher = matcher; carryStart = column; resume = column
    }
    /// Where the next units fed start.
    var end: Int { carryStart + carry.count }

    /// Feeds the units that follow what was fed; `found` is told each match's
    /// start, in order, and returns false to stop.
    @discardableResult
    mutating func feed(_ units: UnsafeBufferPointer<UInt16>, found: (Int) -> Bool) -> Bool {
        let old = carry.count
        carry.append(contentsOf: units)
        var going = true
        let start = carryStart, length = matcher.length
        var lastEnd = self.lastEnd
        // A pair whose halves came in two feeds is folded whole: the first
        // half was left as it was, alone, at the end of the last feed.
        var fold = old
        if old > 0, units.count > 0, carry[old - 1] & 0xFC00 == 0xD800, units[0] & 0xFC00 == 0xDC00 { fold = old - 1 }
        let resumed = carry.withUnsafeMutableBufferPointer { buffer -> Int in
            matcher.prepare(UnsafeMutableBufferPointer(rebasing: buffer[fold...]))
            return matcher.scan(UnsafeBufferPointer(buffer), from: max(0, resume - start)) { at in
                lastEnd = start + at + length
                going = found(start + at)
                return going
            }
        }
        self.lastEnd = lastEnd
        // No match starts before the last `length - 1` units that is not
        // found; keep those, and nothing before where matching resumes.
        let keep = max(start + resumed, end - (length - 1))
        resume = keep
        if keep > carryStart {
            carry.removeFirst(min(carry.count, keep - carryStart))
            carryStart = keep
        }
        return going
    }
}


// MARK: The search

/// A query's search in a text: its count as it goes, the match after or
/// before a place, and the matches on a line as it is drawn. Made by the text
/// (`FileTextSource.search`), one for each query; `cancel` stops it.
@MainActor public final class FileSearch {
    public let matcher: FileMatcher
    private let reader: FileSearchReader
    /// Matches counted so far, and whether the count goes on.
    public private(set) var count = 0
    public private(set) var isCounting = true
    /// Why the search stopped short, if it did: the file changed or failed.
    public private(set) var stopped: String?
    /// The text was read again (as Latin-1): this search is over; search the
    /// text again.
    public private(set) var isStale = false
    /// Told as the count goes on (a few times a second at most), and when it
    /// ends or stops.
    public var onChange: (() -> Void)?

    /// Per page counted, how many matches come before it: one more than the
    /// pages counted.
    private var before: [Int] = [0]
    /// Per long line's page counted, how many of its matches come before each
    /// of its windows.
    private var windowsBefore: [Int: [Int]] = [:]
    /// Per long line (by its line), where matching resumes at the start of
    /// each of its windows, as far as known from its start: only for a query
    /// whose matches could overlap, where it depends on the matches before.
    private var resumes: [Int: [Int]] = [:]
    private var counting: Task<Void, Never>?
    private var finds: [Int: @Sendable () -> Void] = [:]
    private var findTickets = 0
    private var changeScheduled = false
    /// For drawing: a line's text, a long line's page (nil for any other
    /// line), and the matches of lines matched whole, kept.
    private let lineText: @MainActor (Int, Range<Int>) -> String?
    private let lineLength: @MainActor (Int) -> Int
    /// Whether a line is as it will stay: not the line the pass is still in.
    private let lineFinal: @MainActor (Int) -> Bool
    private let longPage: @MainActor (Int) -> FileSearchPage?
    /// The text is held whole: reading any of it reads nothing.
    private let linesAtHand: Bool
    /// Matches of lines matched whole, kept with the length they had, within
    /// a budget of matches.
    private(set) var wholeLines: [Int: (length: Int, matches: [Range<Int>])] = [:]
    private(set) var wholeLinesKept = 0
    static let wholeLinesBudget = 1 << 18
    /// What a line kept costs beside its matches: a line with none is not free.
    static let wholeLineCost = 8
    /// Along a long line held whole, where matching resumes every
    /// `heldWindow` units, worked out once, away from the main thread, for a
    /// query whose matches could overlap.
    private var heldResumes: [Int: [Int]] = [:]
    private var heldResumesAsked: [Int: Task<Void, Never>] = [:]
    nonisolated static let heldWindow = 16_384
    /// Lines up to this long are matched whole for drawing: as long as the
    /// view sets a line whole (`FileTextMetrics.gridLine`).
    static let wholeLine = 65_536

    init(matcher: FileMatcher, reader: FileSearchReader, lineText: @escaping @MainActor (Int, Range<Int>) -> String?,
         lineLength: @escaping @MainActor (Int) -> Int, lineFinal: @escaping @MainActor (Int) -> Bool = { _ in true },
         longPage: @escaping @MainActor (Int) -> FileSearchPage?, linesAtHand: Bool = false) {
        self.matcher = matcher; self.reader = reader
        self.lineText = lineText; self.lineLength = lineLength; self.lineFinal = lineFinal; self.longPage = longPage
        self.linesAtHand = linesAtHand
        if matcher.matchesNothing { isCounting = false; return }
        startCounting()
    }
    /// Stops the count and every find under way; nothing more is told.
    public func cancel() {
        counting?.cancel(); counting = nil
        for cancel in finds.values { cancel() }
        finds = [:]
        for task in heldResumesAsked.values { task.cancel() }
        heldResumesAsked = [:]
        onChange = nil
        isCounting = false
    }
    deinit {
        counting?.cancel()
        for cancel in finds.values { cancel() }
        for task in heldResumesAsked.values { task.cancel() }
    }

    // MARK: Counting

    private func startCounting() {
        let reader = reader, matcher = matcher
        counting = Task.detached(priority: .utility) { [weak self] in
            var next = 0
            do {
                while true {
                    try Task.checkCancellation()
                    let batch = try await reader.pages(from: next, limit: 64)
                    var counted: [(FileSearchPage, Counted)] = []
                    // Runs of pages are read at once; a long line's page on its own.
                    var run: [FileSearchPage] = [], runBytes: Int64 = 0
                    func countRun() throws {
                        guard !run.isEmpty else { return }
                        for (page, var text) in zip(run, try reader.texts(of: run)) {
                            counted.append((page, Counted(matches: FileSearchScan.count(in: &text, matcher))))
                        }
                        run = []; runBytes = 0
                    }
                    for page in batch.pages {
                        await reader.beforeCounting(page.index)
                        try Task.checkCancellation()
                        if page.long != nil {
                            try countRun()
                            counted.append((page, try FileSearch.count(page, reader: reader, matcher: matcher)))
                        } else {
                            run.append(page); runBytes += Int64(page.bytes.count)
                            if runBytes >= 4 << 20 { try countRun() }
                        }
                    }
                    try countRun()
                    guard let self else { return }
                    await self.counted(counted)
                    next = (batch.pages.last?.index ?? next - 1) + 1
                    if batch.complete { await self.finished(nil); return }
                }
            } catch is CancellationError {
            } catch let end as FileSearchEnd {
                await self?.finished(end)
            } catch {
                await self?.finished(.stopped(error.localizedDescription))
            }
        }
    }
    /// A page counted: its matches, and in a long line's page, each window's
    /// and where matching resumes at each window's start.
    private struct Counted: Sendable {
        var matches: Int
        var windows: [Int]?
        var resumes: [Int]?
    }
    private nonisolated static func count(_ page: FileSearchPage, reader: FileSearchReader, matcher: FileMatcher) throws -> Counted {
        var scan = FileLongScan(matcher, from: 0)
        var windows: [Int] = [], resumes: [Int] = []
        for window in 0..<page.windowCount {
            try Task.checkCancellation()
            let start = page.windowStart(window)
            // Every match that starts before this window is found once it is
            // fed: none is as long as a window. Those found now started in
            // the window before and run into this one.
            var endBefore = scan.lastEnd ?? 0, inWindow = 0, runningIn = 0
            let units = try reader.window(window, of: page)
            _ = units.withUnsafeBufferPointer { buffer in
                scan.feed(buffer) { at in
                    if at < start { endBefore = at + matcher.length; runningIn += 1 } else { inWindow += 1 }
                    return true
                }
            }
            if runningIn > 0 { windows[windows.count - 1] += runningIn }
            resumes.append(max(start, endBefore))
            windows.append(inWindow)
        }
        return Counted(matches: windows.reduce(0, +), windows: windows, resumes: matcher.overlaps ? resumes : nil)
    }
    private func counted(_ pages: [(FileSearchPage, Counted)]) {
        guard counting != nil else { return }
        for (page, counted) in pages {
            guard page.index == before.count - 1 else { return }
            before.append(before[before.count - 1] + counted.matches)
            if let windows = counted.windows {
                var running = 0
                windowsBefore[page.index] = [0] + windows.map { running += $0; return running }
            }
            if let known = counted.resumes, let line = page.long?.line, known.count > resumes[line]?.count ?? 0 { resumes[line] = known }
        }
        count = before[before.count - 1]
        scheduleChange()
    }
    private func finished(_ end: FileSearchEnd?) {
        guard counting != nil else { return }
        counting = nil
        isCounting = false
        switch end {
        case .reread?: isStale = true
        case .stopped(let reason)?: stopped = reason
        case nil: break
        }
        changeScheduled = false
        onChange?()
    }
    /// Tells of the count at most every 50 ms while it goes on.
    private func scheduleChange() {
        guard !changeScheduled else { return }
        changeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.changeScheduled else { return }
                self.changeScheduled = false
                self.onChange?()
            }
        }
    }

    /// Keeps a line's matches for drawing, within the budget: past it, what
    /// was kept goes first.
    private func keep(_ found: [Range<Int>], line: Int, length: Int) {
        let cost = found.count + Self.wholeLineCost
        guard cost <= Self.wholeLinesBudget else { return }
        if let kept = wholeLines[line] { wholeLinesKept -= kept.matches.count + Self.wholeLineCost }
        if wholeLinesKept + cost > Self.wholeLinesBudget { wholeLines = [:]; wholeLinesKept = 0 }
        wholeLines[line] = (length, found)
        wholeLinesKept += cost
    }
    /// Works out, once and away from the main thread, where matching
    /// resumes along a long line held whole; drawn again when it is known.
    private func workOutResumes(alongHeld line: Int, length: Int) {
        guard heldResumesAsked[line] == nil, let text = lineText(line, 0..<length) else { return }
        let matcher = matcher
        let work = Task.detached(priority: .userInitiated) { FileSearch.resumePoints(along: text, matcher) }
        heldResumesAsked[line] = Task { [weak self] in
            let points = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled, let points else { return }
            self.heldResumes[line] = points
            self.onChange?()
        }
    }
    /// Where matching resumes at the start of each `heldWindow` of a line:
    /// matched along it once, its UTF-16 units as they are (a window's edge
    /// may fall between the halves of a pair); nil if cancelled.
    nonisolated static func resumePoints(along text: String, _ matcher: FileMatcher) -> [Int]? {
        var scan = FileLongScan(matcher, from: 0)
        var points: [Int] = [], window: [UInt16] = []
        window.reserveCapacity(heldWindow)
        var start = 0
        func feed() {
            // Every match starting before this window was found by now: none
            // is as long as a window.
            var endBefore = scan.lastEnd ?? 0
            window.withUnsafeBufferPointer { buffer in
                _ = scan.feed(buffer) { at in
                    if at < start { endBefore = at + matcher.length }
                    return true
                }
            }
            points.append(max(start, endBefore))
            start += window.count
            window.removeAll(keepingCapacity: true)
        }
        for unit in text.utf16 {
            window.append(unit)
            if window.count == heldWindow {
                feed()
                if Task.isCancelled { return nil }
            }
        }
        if !window.isEmpty { feed() }
        return points.isEmpty ? [0] : points
    }

    /// A match's place among all the matches, from 1, once the count has
    /// passed it.
    public func ordinal(of hit: FileSearchHit) -> Int? {
        guard hit.page + 1 < before.count else { return nil }
        var ordinal = before[hit.page] + hit.index + 1
        if let windows = windowsBefore[hit.page] {
            guard hit.window < windows.count else { return nil }
            ordinal += windows[hit.window]
        }
        return ordinal
    }

    // MARK: Finding

    /// The first match at or after a place (forward), or the last one before
    /// it, wrapping around the text's ends; nil when there is none, or when
    /// the search stopped or was cancelled first. Found away from the main
    /// thread; the count is not waited for.
    public func find(from position: FileTextPosition, forward: Bool) async -> FileSearchHit? {
        guard !matcher.matchesNothing, !isStale, stopped == nil else { return nil }
        let reader = reader, matcher = matcher, counts = before, known = resumes
        findTickets += 1
        let ticket = findTickets
        let work = Task.detached(priority: .userInitiated) { () -> Result<(FileSearchHit?, [Int: [Int]]), Error> in
            var finder = FileSearchFinder(reader: reader, matcher: matcher, counts: counts, resumes: known)
            do {
                let hit = try await finder.find(from: position, forward: forward)
                return .success((hit, finder.learned))
            } catch { return .failure(error) }
        }
        finds[ticket] = { work.cancel() }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        finds[ticket] = nil
        switch result {
        case .success(let (hit, learned)):
            for (line, points) in learned where points.count > resumes[line]?.count ?? 0 { resumes[line] = points }
            return hit
        case .failure(let end as FileSearchEnd):
            // The file changed, or was read again, while the count was done
            // or not yet there: said, as the count would say it.
            ended(end)
            return nil
        case .failure(is CancellationError):
            return nil
        case .failure(let error):
            // It could not be read: said, as the count would say it.
            ended(.stopped(error.localizedDescription))
            return nil
        }
    }
    private func ended(_ end: FileSearchEnd) {
        switch end {
        case .reread: isStale = true
        case .stopped(let reason): if stopped == nil { stopped = reason }
        }
        counting?.cancel(); counting = nil
        isCounting = false
        changeScheduled = false
        onChange?()
    }

    // MARK: Drawing

    /// The matches on a line that meet some of its columns, for drawing them:
    /// nil while what they depend on is not at hand (asking for it).
    public func matches(inLine line: Int, columns: Range<Int>) -> [Range<Int>]? {
        guard !matcher.matchesNothing else { return [] }
        let length = matcher.length, lineLength = lineLength(line)
        // A line of a size the view sets whole is matched whole, and kept
        // once it is as it will stay.
        if lineLength <= Self.wholeLine {
            if let kept = wholeLines[line], kept.length == lineLength { return kept.matches.filter { $0.overlaps(columns) } }
            guard let text = lineText(line, 0..<lineLength) else { return nil }
            let found = matcher.matches(in: text)
            if lineFinal(line) { keep(found, line: line, length: lineLength) }
            return found.filter { $0.overlaps(columns) }
        }
        // A longer line, only around the columns: matched from where matching
        // resumes before them, far enough back to find a match running into
        // them. Any stretch will do when matches cannot overlap; else, along a
        // line held whole, from where matching resumes as worked out once
        // along it, and along a file's, as the count found it (none drawn
        // until it has been there).
        let from = max(0, columns.lowerBound - (length - 1))
        let resume: Int
        if !matcher.overlaps {
            resume = from
        } else if linesAtHand {
            // None drawn until they are worked out, away from the main thread.
            guard let points = heldResumes[line] else { workOutResumes(alongHeld: line, length: lineLength); return nil }
            resume = points[min(points.count - 1, from / Self.heldWindow)]
        } else {
            guard let page = longPage(line), let points = resumes[line] else { return nil }
            let window = page.window(holding: from)
            guard window < points.count else { return nil }
            resume = points[window]
        }
        let to = min(lineLength, max(resume, columns.upperBound + length - 1))
        guard to > resume else { return [] }
        guard let text = lineText(line, resume..<to) else { return nil }
        return matcher.matches(in: text).map { ($0.lowerBound + resume)..<($0.upperBound + resume) }.filter { $0.overlaps(columns) }
    }
}

/// One find, away from the main thread: through the pages from a place, one
/// way, around the text's ends, to the first match it meets.
struct FileSearchFinder {
    let reader: FileSearchReader
    let matcher: FileMatcher
    /// The count so far: per page counted, the matches before it.
    let counts: [Int]
    /// Where matching resumes along long lines, as known when it began, and
    /// what it has come to know since.
    var resumes: [Int: [Int]]
    private(set) var learned: [Int: [Int]] = [:]

    init(reader: FileSearchReader, matcher: FileMatcher, counts: [Int], resumes: [Int: [Int]]) {
        self.reader = reader; self.matcher = matcher; self.counts = counts; self.resumes = resumes
    }

    /// Whether a page is known to hold no match.
    private func empty(_ page: Int) -> Bool { page + 1 < counts.count && counts[page + 1] == counts[page] }

    mutating func find(from position: FileTextPosition, forward: Bool) async throws -> FileSearchHit? {
        await reader.beforeFinding()
        let home = try await reader.page(holding: position.line)
        if forward {
            if let hit = try first(in: home, from: position) { return hit }
            // On to the end.
            var next = home.index + 1
            while true {
                try Task.checkCancellation()
                let batch = try await reader.pages(from: next, limit: 16)
                for page in batch.pages {
                    next = page.index + 1
                    if !empty(page.index), let hit = try first(in: page, from: nil) { return hit }
                }
                if batch.complete { break }
            }
            // Around from the start, up to where it began.
            next = 0
            while next <= home.index {
                try Task.checkCancellation()
                let batch = try await reader.pages(from: next, limit: min(16, home.index - next + 1))
                guard !batch.pages.isEmpty else { return nil }
                for page in batch.pages where page.index <= home.index {
                    next = page.index + 1
                    if !empty(page.index), let hit = try first(in: page, from: nil) { return hit }
                }
            }
            return nil
        }
        if let hit = try last(in: home, before: position) { return hit }
        // Back to the start.
        var index = home.index - 1
        while index >= 0 {
            try Task.checkCancellation()
            let low = max(0, index - 15)
            let batch = try await reader.pages(from: low, limit: index - low + 1)
            for page in batch.pages.reversed() where page.index <= index {
                if !empty(page.index), let hit = try last(in: page, before: nil) { return hit }
            }
            index = low - 1
        }
        // Around from the end, once it is known, back to where it began.
        index = try await reader.pageCount() - 1
        while index >= home.index {
            try Task.checkCancellation()
            let low = max(home.index, index - 15)
            let batch = try await reader.pages(from: low, limit: index - low + 1)
            for page in batch.pages.reversed() where page.index <= index {
                if !empty(page.index), let hit = try last(in: page, before: nil) { return hit }
            }
            index = low - 1
        }
        return nil
    }

    // MARK: In a page

    /// The first match at or after a position in a page (from its start if nil).
    private mutating func first(in page: FileSearchPage, from position: FileTextPosition?) throws -> FileSearchHit? {
        if let long = page.long {
            let column = position.map { $0.line > long.line ? Int.max : ($0.line < long.line ? 0 : $0.column) } ?? 0
            guard column != Int.max else { return nil }
            return try firstInLong(page, from: column)
        }
        var text = try reader.text(of: page)
        let found = FileSearchScan.matches(in: &text, matcher)
        for (index, match) in found.enumerated() {
            let at = FileTextPosition(line: page.firstLine + match.line, column: match.column)
            if let position, at < position { continue }
            return FileSearchHit(line: at.line, columns: match.column..<(match.column + matcher.length), page: page.index, window: 0, index: index)
        }
        return nil
    }
    /// The last match before a position in a page (anywhere in it if nil).
    private mutating func last(in page: FileSearchPage, before position: FileTextPosition?) throws -> FileSearchHit? {
        if let long = page.long {
            let column = position.map { $0.line > long.line ? Int.max : ($0.line < long.line ? 0 : $0.column) } ?? Int.max
            guard column > 0 else { return nil }
            return try lastInLong(page, before: column)
        }
        var text = try reader.text(of: page)
        let found = FileSearchScan.matches(in: &text, matcher)
        for (index, match) in found.enumerated().reversed() {
            let at = FileTextPosition(line: page.firstLine + match.line, column: match.column)
            if let position, at >= position { continue }
            return FileSearchHit(line: at.line, columns: match.column..<(match.column + matcher.length), page: page.index, window: 0, index: index)
        }
        return nil
    }

    // MARK: Along a long line

    /// Where matching resumes at a window's start, working it out along the
    /// line from the last place known where it must.
    private mutating func resume(_ window: Int, of page: FileSearchPage) throws -> Int {
        guard matcher.overlaps, let line = page.long?.line else { return page.windowStart(window) }
        var points = resumes[line] ?? [0]
        if window < points.count { return points[window] }
        var scan = FileLongScan(matcher, from: points[points.count - 1])
        var current = points.count - 1
        let first = try reader.window(current, of: page)
        let skip = points[current] - page.windowStart(current)
        _ = first.withUnsafeBufferPointer { buffer in
            scan.feed(UnsafeBufferPointer(rebasing: buffer[min(skip, buffer.count)...])) { _ in true }
        }
        while current < window {
            try Task.checkCancellation()
            current += 1
            let start = page.windowStart(current)
            var endBefore = scan.lastEnd ?? 0
            _ = try reader.window(current, of: page).withUnsafeBufferPointer { buffer in
                scan.feed(buffer) { at in
                    if at < start { endBefore = at + matcher.length }
                    return true
                }
            }
            points.append(max(start, endBefore))
        }
        resumes[line] = points
        learned[line] = points
        return points[window]
    }
    /// The matches that start in a window of a long line, in order: fed from
    /// where matching resumes at its start, with enough of the next window
    /// for a match running into it.
    private mutating func matches(inWindow window: Int, of page: FileSearchPage) throws -> [Int] {
        let start = page.windowStart(window), resume = try resume(window, of: page)
        let end = window + 1 < page.windowCount ? page.windowStart(window + 1) : Int.max
        var scan = FileLongScan(matcher, from: resume)
        var found: [Int] = []
        let units = try reader.window(window, of: page)
        _ = units.withUnsafeBufferPointer { buffer in
            scan.feed(UnsafeBufferPointer(rebasing: buffer[min(resume - start, buffer.count)...])) { found.append($0); return true }
        }
        if window + 1 < page.windowCount, matcher.length > 1 {
            let next = try reader.window(window + 1, of: page)
            _ = next.withUnsafeBufferPointer { buffer in
                scan.feed(UnsafeBufferPointer(rebasing: buffer[..<min(buffer.count, matcher.length - 1)])) { at in
                    if at < end { found.append(at) }
                    return at < end
                }
            }
        }
        return found.filter { $0 < end }
    }
    private mutating func firstInLong(_ page: FileSearchPage, from column: Int) throws -> FileSearchHit? {
        guard let line = page.long?.line else { return nil }
        var window = page.window(holding: column)
        while window < page.windowCount {
            try Task.checkCancellation()
            let found = try matches(inWindow: window, of: page)
            if let index = found.firstIndex(where: { $0 >= column }) {
                return FileSearchHit(line: line, columns: found[index]..<(found[index] + matcher.length), page: page.index, window: window, index: index)
            }
            window += 1
        }
        return nil
    }
    private mutating func lastInLong(_ page: FileSearchPage, before column: Int) throws -> FileSearchHit? {
        guard let line = page.long?.line else { return nil }
        var window = page.window(holding: column == Int.max ? Int.max : max(0, column - 1))
        while window >= 0 {
            try Task.checkCancellation()
            let found = try matches(inWindow: window, of: page)
            if let index = found.lastIndex(where: { $0 < column }) {
                return FileSearchHit(line: line, columns: found[index]..<(found[index] + matcher.length), page: page.index, window: window, index: index)
            }
            window -= 1
        }
        return nil
    }
}

/// How a search reads lines held whole (`FileTextLines`): in pages of 128.
struct FileLinesSearchReader: FileSearchReader {
    let lines: [String]
    static let pageLines = 128
    private var count: Int { max(1, (lines.count + Self.pageLines - 1) / Self.pageLines) }
    private func page(_ index: Int) -> FileSearchPage {
        let first = index * Self.pageLines, end = min(lines.count, first + Self.pageLines)
        return FileSearchPage(index: index, firstLine: first, bytes: 0..<0, lineCount: max(0, end - first),
                              units: lines[min(first, end)..<end].reduce(0) { $0 + $1.utf16.count }, long: nil, last: index + 1 == count)
    }
    func pages(from first: Int, limit: Int) async throws -> FileSearchPages {
        let end = min(count, first + max(1, limit))
        return FileSearchPages(pages: (min(first, end)..<end).map(page), complete: end >= count)
    }
    func page(holding line: Int) async throws -> FileSearchPage { page(min(count - 1, max(0, line) / Self.pageLines)) }
    func pageCount() async throws -> Int { count }
    func text(of page: FileSearchPage) throws -> FileSearchText {
        var text = FileSearchText()
        for line in lines[min(page.firstLine, lines.count)..<min(lines.count, page.firstLine + page.lineCount)] {
            text.units.append(contentsOf: line.utf16)
            text.starts.append(text.units.count)
        }
        return text
    }
    func window(_ window: Int, of page: FileSearchPage) throws -> [UInt16] { [] }
}
