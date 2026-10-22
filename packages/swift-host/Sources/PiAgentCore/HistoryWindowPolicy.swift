import Foundation

/// Shared by the read-only desktop and the live helper. These are presentation
/// budgets, never model-context or journal retention limits. A single full
/// row may exceed the preferred byte window; IPC chunks do not shorten it.
public enum HistoryWindowPolicy {
    /// The live snapshot: the newest display turns the helper sends with
    /// every update (`AgentSession.projectedDisplay`), within one envelope.
    public static let turns = 3
    public static let rows = 60
    public static let envelopeBytes = 256 * 1024
    public static let metadataAllowance = 8192
    /// A history page (`page`, `PageFill`): whole display turns, as many as
    /// fit in this many rows and encoded bytes. A turn's work folds behind
    /// its one line only when the whole turn is on the page, so a page cut
    /// inside a turn showed that turn call by call until the rest of it was
    /// read, and then folded it away under the reader. Before 0.1.131 a page
    /// was three turns or sixty rows: less than one turn of a coding agent
    /// that makes forty tool calls.
    ///
    /// Chosen by measurement (docs/validation/a131-scroll-0.1.131.md):
    /// every streamed token costs the main thread about 0.02 ms for each row
    /// the window holds (the page's projection, regrouping and document
    /// update each walk the whole window), so the window's size is what a
    /// reply arriving costs: 3 ms a token at 60 rows, 7 ms at 250, 17 ms at
    /// 750, 22 ms at 1,000 and 61 ms at 3,000. Pages of 1,000 rows read a
    /// tool-heavy chat back in two loads instead of nineteen, but made every
    /// token of a reply in a long chat cost five to seven times what it
    /// did; pages of 250 rows hold about two such turns, read it back in
    /// nineteen loads instead of forty-eight, open it faster than before
    /// and land each page in about half the time.
    public static let pageRows = 250
    public static let pageBytes = 1024 * 1024
    /// The resident window: what one chat's transcript holds at once, three
    /// pages. A turn longer than a page is still read whole up to these;
    /// only a turn the window could not hold whole is cut.
    public static let residentRows = 750
    public static let residentBytes = 6_000_000
    public static let automaticFills = 2

    /// What a history page may hold: whole turns, as many as fit in `rows`
    /// rows and `bytes` bytes, and its first turn alone up to `turnRows` and
    /// `turnBytes`, past which a turn is cut.
    public struct PageLimits: Equatable, Sendable {
        public var rows: Int, bytes: Int, turnRows: Int, turnBytes: Int
        public init(rows: Int, bytes: Int, turnRows: Int, turnBytes: Int) {
            self.rows = rows; self.bytes = bytes; self.turnRows = max(rows, turnRows); self.turnBytes = max(bytes, turnBytes)
        }
        /// A page's rows and bytes; a turn alone may take the resident window's.
        public static let standard = PageLimits(rows: pageRows, bytes: pageBytes, turnRows: residentRows, turnBytes: residentBytes)
    }

    /// Each delivered visible user input is a display-turn boundary, including
    /// steering. A task's nativeTurn can span several submissions; it must not
    /// merge those inputs. Old/imported rows use the same conservative boundary.
    /// The live snapshot's newest `turns`, at most `rows` rows.
    public static func range(count: Int, before: Int? = nil, after: Int? = nil,
                             around: Int? = nil, target: Int = turns,
                             isUser: (Int) -> Bool) -> Range<Int> {
        if let start = around ?? after.map({ $0 + 1 }) {
            let start = min(count, max(0, start))
            var end = start, turns = start < count && isUser(start) ? 0 : 1
            while end < count && end - start < rows {
                if isUser(end) { if turns >= target { break }; turns += 1 }
                end += 1
            }
            return start..<end
        }
        let end = min(count, max(0, before ?? count))
        var start = end, turns = 0
        while start > 0 && end - start < rows {
            start -= 1
            if isUser(start) { turns += 1; if turns >= target { break } }
        }
        return start..<end
    }

    /// Whether a row opens a display turn: a message of the reader's, a
    /// steer among them, exactly as the transcript's fold counts turns. An
    /// agent's delivery is a user row too, but it is work of the turn it
    /// arrives in, never the start of one.
    public static func startsTurn(role: String?, kind: String?, agentDelivery: Bool) -> Bool {
        role == "user" && kind == nil && !agentDelivery
    }

    /// The rows of a history page: whole display turns, read back from
    /// `before` (the timeline's end when nil), forward after `after`, or
    /// forward from the start of the turn that holds `around`, for as long
    /// as the next turn still fits in the limits' rows. A page holds at least
    /// one turn whole, a turn longer than that too, up to the limits'
    /// `turnRows`; only a turn longer still is cut, and a page read around a
    /// row of such a turn starts at that row. `startsTurn` says which rows
    /// open a turn (`startsTurn(role:kind:agentDelivery:)`). `firstIsStart`:
    /// row 0 is the conversation's own first row, where any page may start;
    /// false for a timeline that holds only the newest rows of a longer one.
    public static func page(count: Int, before: Int? = nil, after: Int? = nil, around: Int? = nil,
                            limits: PageLimits = .standard, firstIsStart: Bool = true, startsTurn: (Int) -> Bool) -> Range<Int> {
        let rows = limits.rows, longest = limits.turnRows
        if let from = around ?? after.map({ $0 + 1 }) {
            var start = min(count, max(0, from))
            if around != nil, start < count {
                var turn = start
                while turn > 0, !startsTurn(turn), start - turn < longest { turn -= 1 }
                if (turn == 0 && firstIsStart) || startsTurn(turn) { start = turn }
            }
            // `aligned`: where the page last stood at the end of a turn.
            var end = start, aligned = start
            while end < count {
                if end > start, startsTurn(end) { aligned = end }
                if end - start >= (aligned == start ? longest : rows) { break }
                end += 1
            }
            if end == count { aligned = count }
            return start..<(aligned > start ? aligned : end)
        }
        let end = min(count, max(0, before ?? count))
        // `aligned`: where the page last stood at the start of a turn.
        var start = end, aligned = end
        while start > 0 {
            if end - start >= (aligned == end ? longest : rows) { break }
            start -= 1
            if startsTurn(start) { aligned = start }
        }
        return ((start == 0 && firstIsStart) || aligned == end ? start : aligned)..<end
    }

    /// A history page filled within its byte budget, one row at a time in the
    /// order the page is read (forward from its first row, or back from its
    /// last), so that it keeps whole turns: a page that runs out of room
    /// ends at the edge of its last whole turn. Its first turn alone may take
    /// the limits' `turnBytes`; only a turn longer still is cut.
    public struct PageFill: Sendable {
        public let forward: Bool
        public let limits: PageLimits
        public private(set) var bytes: Int
        /// The rows admitted so far.
        public private(set) var rows = 0
        /// The rows the page held when it last stood at a turn's edge.
        private var aligned = 0
        private var full = false
        public init(forward: Bool, bytes: Int = HistoryWindowPolicy.metadataAllowance, limits: PageLimits = .standard) {
            self.forward = forward; self.bytes = bytes; self.limits = limits
        }
        /// Whether the next row read, `size` encoded bytes, joins the page.
        /// Once one does not, no later row does.
        public mutating func admit(_ size: Int, startsTurn: Bool) -> Bool {
            guard !full else { return false }
            // Read forward, the rows so far end a turn where the next starts.
            if forward, startsTurn, rows > 0 { aligned = rows }
            let budget = aligned == 0 ? limits.turnBytes : limits.bytes
            guard rows == 0 || bytes + size + 1 <= budget else { full = true; return false }
            bytes += size + 1; rows += 1
            // Read back, the page now starts where this row starts a turn.
            if !forward, startsTurn { aligned = rows }
            return true
        }
        /// How many of the rows admitted the page keeps, counted in the order
        /// they were read: all of them, or, once the budget ran out, the
        /// whole turns among them.
        public var kept: Int { full && aligned > 0 ? aligned : rows }
    }
}

/// Stable exclusive entry boundary. The UI passes this through without index
/// arithmetic. Source adapters validate incarnation and structural lineage;
/// ordinary appends keep earlier boundaries valid.
public struct ConversationCursor: Codable, Equatable, Sendable {
    public var incarnation: String
    public var lineage: String
    public var entry: String
    public var committedBytes: UInt64? = nil
    public var fingerprint: String? = nil
    public init(incarnation: String, lineage: String, entry: String) {
        self.incarnation = incarnation; self.lineage = lineage; self.entry = entry
    }
}
