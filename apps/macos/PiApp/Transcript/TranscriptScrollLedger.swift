import AppKit

/// Who moved the reader, decided by what the page wrote down.
///
/// Every scroll the page performs itself is recorded here before it is
/// written to the clip view. AppKit then delivers the new origin back through
/// a bounds notification, and the page compares that offset with what it
/// wrote: an offset the page wrote is the page's own movement; anything else
/// is the reader's — a wheel, a trackpad, a scroller drag, a page key, a
/// find-and-reveal, the window server's own inertia. That is the whole test,
/// and it needs no gesture notification, so it cannot be fooled by the ways
/// AppKit reports one input device differently from another.
///
/// Whether the page *follows* the newest row is a separate, purely
/// geometric question: the reader is pinned while they stand within
/// `TranscriptPage.followThreshold` of the bottom, and unpinned the moment
/// they leave that band. Ownership decides who the destination belongs to;
/// the band decides what the page does with it.
@MainActor final class TranscriptScrollLedger {
    /// How far a delivered offset may sit from what the page wrote and still
    /// be that write. AppKit clamps an origin to the document, rounds it to
    /// the backing scale and coalesces two writes into one delivery, so an
    /// exact comparison would hand the position to the reader on the page's
    /// own scrolls.
    static let tolerance: CGFloat = 0.75
    /// How long a write stands before it is written off, for an animation the
    /// system abandons or a write AppKit never delivers.
    static let grace: TimeInterval = 2.0
    /// At most this many writes are remembered. The page writes one position
    /// at a time; the depth is only there for a settle that overtakes itself.
    static let depth = 8

    /// What became of an offset AppKit delivered.
    enum Delivery {
        /// The reader is where they already were. Nothing moved anybody.
        case unchanged
        /// The page put them there.
        case page
        /// Nothing the page wrote explains this offset, so it is theirs.
        case reader
    }

    private struct Write {
        var from: CGFloat
        var to: CGFloat
        /// An animated scroll owns every offset between where it started and
        /// where it is going, because AppKit delivers each frame of it.
        var animated: Bool
        var at: TimeInterval
    }
    private var writes: [Write] = []
    private var lastDelivered: CGFloat?
    /// The last place the page asked for, kept after the write itself has
    /// been accounted for: a document that becomes shorter is clamped to its
    /// new end, and that end is not somewhere the reader chose to be.
    private var lastWritten: CGFloat?
    /// Evidence for the fixtures: how many scrolls the page wrote, and how
    /// often the reader took the position away from it.
    private(set) var writeCount = 0
    private(set) var readerTakeoverCount = 0

    /// The page is about to put the reader at `to`, from `from`.
    func wrote(from: CGFloat, to: CGFloat, animated: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        writes.removeAll { now - $0.at > Self.grace }
        if writes.count >= Self.depth { writes.removeFirst() }
        writes.append(Write(from: from, to: to, animated: animated, at: now))
        lastWritten = to
        writeCount += 1
    }

    /// AppKit has given the clip view this origin, with `floor` the furthest
    /// it could have been given. Answers whose movement it was, and remembers
    /// it as where the reader now stands.
    func delivered(_ offset: CGFloat, floor: CGFloat) -> Delivery {
        guard let previous = lastDelivered else {
            // The first reading is where the reader is standing, not a
            // movement: a pane that has just been built, or one whose clip
            // view has only changed size, has not moved anybody.
            self.lastDelivered = offset
            return .unchanged
        }
        if abs(offset - previous) <= Self.tolerance { return .unchanged }
        self.lastDelivered = offset
        if claim(offset, floor: floor, from: previous) { return .page }
        writes.removeAll()
        // The reader has the position. Where the page last asked to be says
        // nothing about where they go from here: kept, it made the reader
        // coming back down onto the end look like the document clamping them
        // there, and the page stopped following although it showed the end.
        lastWritten = nil
        readerTakeoverCount += 1
        return .reader
    }

    /// Whether one of the page's own writes explains this offset, consuming
    /// it and everything written before it when it does: a scroll that has
    /// landed means nothing written earlier can still be in flight.
    private func claim(_ offset: CGFloat, floor: CGFloat, from previous: CGFloat) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        writes.removeAll { now - $0.at > Self.grace }
        for (index, write) in writes.enumerated() {
            if abs(offset - write.to) <= Self.tolerance {
                writes.removeFirst(index + 1)
                return true
            }
            if write.animated, offset >= min(write.from, write.to) - Self.tolerance,
               offset <= max(write.from, write.to) + Self.tolerance {
                writes.removeFirst(index)
                return true
            }
        }
        // A page that became shorter: AppKit brings the clip view back to the
        // new end, from wherever the reader was standing — the place the page
        // last asked for, or the place they scrolled to themselves. Nobody can
        // scroll past the end, so a delivery that lands exactly on it from
        // beyond it is the document moving out from under the reader, not the
        // reader moving. Reading it as their own scroll would say they had
        // just chosen the bottom of the page, and pin the page there.
        let stood = max(lastWritten ?? previous, previous)
        if stood > floor + Self.tolerance, abs(offset - floor) <= Self.tolerance {
            // The page stands at the new end now, not beyond it.
            lastWritten = offset
            return true
        }
        return false
    }

    /// Whether the clip is at an offset nobody has asked about yet. A bounds
    /// change reaches every observer of the clip, in an order AppKit does not
    /// promise, so one of them can be looking at a movement before the page
    /// has been told whose it was. Before the first reading there is nothing
    /// to be behind.
    func awaitsDelivery(of offset: CGFloat) -> Bool {
        guard let lastDelivered else { return false }
        return abs(offset - lastDelivered) > Self.tolerance
    }

    /// The reader has touched the page: nothing written before they did still
    /// explains where they end up. Where they are standing is still where
    /// they are standing, so that much is kept.
    func forgetWrites() { writes.removeAll(); lastWritten = nil }
    /// A different conversation: the offsets of the last one mean nothing
    /// here, so the ledger starts over from its first reading.
    func reset() { writes.removeAll(); lastDelivered = nil; lastWritten = nil }
}
