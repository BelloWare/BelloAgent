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
    /// SCROLL-1 first kept pages at 250 rows because every streamed token
    /// walked the window. STREAM-1 retains the unchanged projection, plan
    /// and native rows; its measured token cost stays flat through 3,000
    /// rows, allowing these larger pages (docs/validation/a131-stream-0.1.131.md).
    public static let pageRows = 1_000
    public static let pageBytes = 4 * 1024 * 1024
    /// The resident window: what one chat's transcript holds at once, three
    /// pages. A turn longer than a page is still read whole up to these;
    /// only a turn the window could not hold whole is cut.
    public static let residentRows = 3_000
    public static let residentBytes = 24_000_000
    public static let automaticFills = 2

    /// What one display row weighs in the app's resident window
    /// (`TranscriptPaging.size`): its text and reasoning, its tools' inputs
    /// and outputs, each timeline segment's text and 512, and 512 more. Both
    /// readers fill a page within the larger of this and its rows' encoded
    /// bytes, so a page fits the window it is shown in: a page that fitted as
    /// encoded passed the window, which then let go of its first turn's
    /// question and unfolded it.
    public static func residentWeight(text: Int, thinking: Int, toolBytes: Int, segmentBytes: Int, segments: Int) -> Int {
        text + thinking + toolBytes + segmentBytes + 512 * segments + 512
    }

    /// What a history page may hold: whole turns, as many as fit in `rows`
    /// rows and `bytes` bytes, and its first turn alone up to `turnRows` and
    /// `turnBytes`, past which a turn is cut.
    public struct PageLimits: Equatable, Sendable {
        public var rows: Int, bytes: Int, turnRows: Int, turnBytes: Int
        public init(rows: Int, bytes: Int, turnRows: Int, turnBytes: Int) {
            self.rows = rows; self.bytes = bytes; self.turnRows = max(rows, turnRows); self.turnBytes = max(bytes, turnBytes)
        }
        /// The first paint is a small page; later reads keep the full budget.
        /// A single display turn still has its usual whole-turn allowance.
        public var opening: Self {
            Self(rows: min(rows, 250), bytes: min(bytes, 1024 * 1024), turnRows: turnRows, turnBytes: turnBytes)
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
    /// row of such a turn that a page from its question would not reach
    /// starts at that row. `startsTurn` says which rows
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
                // To the row's question only while the page from there still
                // reaches the row: a page holds at most `longest` rows, and a
                // row exactly that far from its question fell just past the
                // end of a page started there, so find, reveal and a position
                // read never showed it.
                if (turn == 0 && firstIsStart) || startsTurn(turn), start - turn < longest { start = turn }
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
