import SwiftUI
import AppKit

// The diff as a native table: the file cards, their notes, hunk headers and
// rows drawn by AppKit, a row at a time as they scroll into view, the way the
// Inspector's outline draws a request (`InspectorItemsOutline`). A SwiftUI
// diff laid out every row it had built again whenever the diff changed: side
// by side, a jump deep into a whole 10,000-line diff, or the next file after
// one, each kept the main thread for a fifth of a second or more.
//
// What SwiftUI drew is drawn to the point: the same fonts, colours, spacing
// and card chrome (`GitDiffMetrics`). The heading above the cards (and, for a
// commit, the commit's own header) is still SwiftUI, hosted in the table's
// first row so that it scrolls away with the diff as it always did.

/// How many diff rows have been configured for the screen. A test seam, not
/// diagnostics: a long diff must build the rows that come into view and no
/// others, and that is only checkable by counting.
@MainActor enum GitDiffRenderCount {
    private(set) static var rows = 0
    static func reset() { rows = 0 }
    static func built() { rows &+= 1 }
}

/// SwiftUI's own measures for the diff as it drew it, so the table draws the
/// same pixels: a monospaced line is 15 points with its baseline at 12, a row
/// 17, a hunk header 21, a file header 29, a note 21; cards are inset 16 and
/// 12 apart, with a 12-point continuous corner and a hairline inside it.
@MainActor enum GitDiffMetrics {
    static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let micro = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    static let microDigits = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
    static let monoLine: CGFloat = 15
    static let monoBaseline: CGFloat = 12
    static let microLine: CGFloat = 13
    static let microBaseline: CGFloat = 10.5
    static let cardInset = PiSpacing.lg
    static let cardGap = PiSpacing.md
    static let cardRadius = PiRadius.md
    static let bottom = PiSpacing.lg
    static let fileHeader: CGFloat = 29
    static let hunkHeader: CGFloat = 21
    static let note: CGFloat = 21
    /// A unified row: two 44-point line numbers, 8 points, a 12-point marker,
    /// inside 8 points of padding on either side.
    static let unifiedText: CGFloat = 8 + 44 + 44 + 8 + 12
    /// Half of a side-by-side row: a 40-point number and 8 points, inside 8
    /// points of padding on either side.
    static let splitText: CGFloat = 8 + 40 + 8
    /// Rows of one file drawn before "Show the whole diff" is pressed.
    static let rowLimit = 1_500

    /// A colour as SwiftUI's `.opacity` made it: its own alpha scaled, in the
    /// appearance being drawn.
    static func fill(_ color: NSColor, opacity: CGFloat) -> CGColor {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        return resolved.withAlphaComponent(resolved.alphaComponent * opacity).cgColor
    }

    static func textWidth(unified cardWidth: CGFloat) -> CGFloat { max(0, cardWidth - unifiedText - 8) }
    static func halfWidth(_ cardWidth: CGFloat) -> CGFloat { (cardWidth - 1) / 2 }
    static func textWidth(split cardWidth: CGFloat) -> CGFloat { max(0, halfWidth(cardWidth) - splitText - 8) }
}

/// One row of the table.
struct GitDiffTableRow {
    enum Kind: UInt8 { case top, gap, file, note, hunk, line, split, showAll, bottom }
    let kind: Kind
    /// The first and last rows of a file's card round its corners.
    var first = false
    var last = false
    var file: Int32 = 0
    var hunk: Int32 = 0
    /// A note's index, a line's index in its hunk, or a side-by-side row's in `splits`.
    var item: Int32 = 0
}

/// Where the reader's text selection starts or ends: a row, and a UTF-16
/// offset into the text that row selects.
struct GitDiffTextPoint: Comparable {
    var row: Int
    var index: Int
    static func < (a: Self, b: Self) -> Bool { a.row != b.row ? a.row < b.row : a.index < b.index }
}

struct GitDiffTable: NSViewRepresentable {
    let files: [GitDiffFile]
    let split: Bool
    let wrap: Bool
    /// The whole diff, not the first 1,500 rows of each file.
    let showAll: Bool
    let identity: String
    /// What comes before the cards, hosted: the heading, and for a commit its
    /// own header. `topKey` changes whenever its height may.
    let top: AnyView
    let topKey: AnyHashable
    /// "Show the whole diff", hosted, after the cards; nil when there is no more.
    let more: AnyView?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        let table = GitDiffTableView()
        // Plain: the automatic style insets every row by 16 points and the
        // table by 10, and the cards keep their own insets.
        table.style = .plain
        table.headerView = nil; table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAutomaticRowHeights = false
        table.allowsTypeSelect = false
        table.focusRingType = .none
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.coordinator = context.coordinator
        table.setAccessibilityLabel("Diff")
        table.setAccessibilityIdentifier("git-diff-table")
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.observe(scroll)
        context.coordinator.schedule(state)
        return scroll
    }

    /// A change is shown in the table's next layout pass: after SwiftUI's
    /// update, never inside it, and in the same frame.
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.schedule(state) }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.close()
        guard let table = scroll.documentView as? NSTableView else { return }
        table.delegate = nil; table.dataSource = nil
    }

    private var state: Coordinator.State {
        Coordinator.State(files: files, split: split, wrap: wrap, showAll: showAll, identity: identity, top: top, topKey: topKey, more: more)
    }

    // MARK: - Coordinator

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        struct State {
            var files: [GitDiffFile]
            var split: Bool
            var wrap: Bool
            var showAll: Bool
            var identity: String
            var top: AnyView
            var topKey: AnyHashable
            var more: AnyView?
        }
        weak var table: GitDiffTableView?
        private(set) var files: [GitDiffFile] = []
        private var identity = ""
        private(set) var split = false
        private(set) var wrap = false
        private var showAll = false
        private var hasMore = false
        private(set) var rows: [GitDiffTableRow] = []
        private var splits: [GitSplitRow] = []
        /// Each layout's rows for the diff on screen, kept while it is: the
        /// reader switching back and forth builds each once.
        private var built: [Bool: (rows: [GitDiffTableRow], splits: [GitSplitRow])] = [:]
        /// Wrapped rows' heights at `heightWidth`, measured as the table asks.
        private var wrapped: [CGFloat?] = []
        private var heightWidth: CGFloat = -1
        /// What the hosted heading was last given: set again only when it changes.
        private var shownTop: AnyHashable?
        private var pending: State?
        private var topKey: AnyHashable?
        private var topHeight: CGFloat = 0
        private var moreHeight: CGFloat = 0
        private var measuredWidth: CGFloat = -1
        private let topHost = NSHostingController(rootView: AnyView(EmptyView()))
        private let moreHost = NSHostingController(rootView: AnyView(EmptyView()))
        private var observers: [NSObjectProtocol] = []
        /// The reader's selection: where it began and where it reaches, and
        /// for a side-by-side diff which side it is in.
        private(set) var anchor: GitDiffTextPoint?
        private(set) var focus: GitDiffTextPoint?
        private(set) var side: GitDiffSide = .whole
        /// Wrapped lines of a row's text, by row, at `heightWidth`.
        private var breaks: [Int: [Range<Int>]] = [:]

        override init() {
            super.init()
            // The hosted rows are sized by the table, never by themselves: a
            // hosting view that published its size invalidated the layout of
            // the whole sheet around the table on every frame of an animation
            // inside it (the Unified and Split tabs' glide).
            for host in [topHost, moreHost] {
                host.sizingOptions = []
                (host.view as? NSHostingView<AnyView>)?.sizingOptions = []
                host.view.translatesAutoresizingMaskIntoConstraints = true
            }
        }

        func observe(_ scroll: NSScrollView) {
            scroll.contentView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.table?.window?.invalidateCursorRects(for: self?.table ?? NSView()) }
            })
        }
        func close() {
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            topHost.rootView = AnyView(EmptyView()); moreHost.rootView = AnyView(EmptyView())
        }

        func schedule(_ next: State) {
            pending = next
            table?.needsLayout = true
        }

        /// Called as the table lays out: a state waiting is shown, and a new
        /// width measured.
        func layoutWillHappen() {
            guard let table, table.bounds.width > 0 else { return }
            if let next = pending { pending = nil; apply(next) }
            else if table.bounds.width != measuredWidth { widthChanged() }
        }

        /// Shows a state: the hosted heading always, the rows again only when
        /// the diff, its layout or its gate changed.
        private func apply(_ next: State) {
            guard let table else { return }
            let sameFiles = Self.same(files, next.files) && identity == next.identity
            let rebuild = !sameFiles || split != next.split || showAll != next.showAll || (next.more != nil) != hasMore || rows.isEmpty
            let rewrap = wrap != next.wrap
            let newDiff = identity != next.identity
            if !sameFiles || showAll != next.showAll || (next.more != nil) != hasMore { built = [:] }
            if !sameFiles { anchor = nil; focus = nil }
            let moreChanged = newDiff || (next.more != nil) != hasMore
            files = next.files; identity = next.identity; split = next.split; showAll = next.showAll
            wrap = next.wrap; hasMore = next.more != nil
            // The heading is drawn again only when what it shows changed: the
            // panel's every other update left it as it was.
            let topShown = AnyHashable([next.topKey, AnyHashable(split), AnyHashable(wrap)])
            if topShown != shownTop { shownTop = topShown; topHost.rootView = next.top }
            if moreChanged, let more = next.more { moreHost.rootView = more }
            let width = table.bounds.width
            var heading = false
            if next.topKey != topKey || width != measuredWidth {
                topKey = next.topKey
                heading = remeasure(width: width)
            } else if moreChanged, hasMore {
                // "Show the whole diff" arrives with a diff grown past the
                // gate under the same heading.
                moreHeight = ceil(moreHost.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            }
            if rebuild {
                if let cached = built[split] { rows = cached.rows; splits = cached.splits } else { build(); built[split] = (rows, splits) }
                measureRows(width: width)
                table.reloadData()
                if newDiff, let clip = table.enclosingScrollView?.contentView, clip.bounds.minY != 0 {
                    clip.scroll(to: .zero); table.enclosingScrollView?.reflectScrolledClipView(clip)
                }
            } else if rewrap || width != heightWidth {
                measureRows(width: width)
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
                redrawVisible()
            } else if heading {
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0))
            }
        }

        /// Two diffs are the same when they are the same array: the controller
        /// publishes a new one for every read, and a body evaluated again
        /// hands over the one it had. Comparing the lines would walk them all.
        private static func same(_ a: [GitDiffFile], _ b: [GitDiffFile]) -> Bool {
            a.withUnsafeBufferPointer { x in b.withUnsafeBufferPointer { y in x.baseAddress == y.baseAddress && x.count == y.count } }
        }

        /// The rows, as SwiftUI laid the cards out: the heading, then each file
        /// 12 points after the last, then "Show the whole diff" when there is
        /// more, then 16 points.
        private func build() {
            var rows: [GitDiffTableRow] = [GitDiffTableRow(kind: .top)]
            var splits: [GitSplitRow] = []
            for (fileIndex, file) in files.enumerated() {
                let f = Int32(fileIndex)
                rows.append(GitDiffTableRow(kind: .gap))
                let first = rows.count
                rows.append(GitDiffTableRow(kind: .file, file: f))
                for index in file.notes.indices { rows.append(GitDiffTableRow(kind: .note, file: f, item: Int32(index))) }
                var remaining = showAll ? Int.max : GitDiffMetrics.rowLimit
                for (hunkIndex, hunk) in file.hunks.enumerated() {
                    guard remaining > 0 else { break }
                    let h = Int32(hunkIndex)
                    rows.append(GitDiffTableRow(kind: .hunk, file: f, hunk: h))
                    if split {
                        for row in hunk.splitRows(limit: remaining) {
                            rows.append(GitDiffTableRow(kind: .split, file: f, hunk: h, item: Int32(splits.count)))
                            splits.append(row)
                        }
                    } else {
                        for index in 0..<min(hunk.lines.count, remaining) { rows.append(GitDiffTableRow(kind: .line, file: f, hunk: h, item: Int32(index))) }
                    }
                    remaining = hunk.lines.count >= remaining ? 0 : remaining - hunk.lines.count
                }
                rows[first].first = true
                rows[rows.count - 1].last = true
            }
            if hasMore { rows.append(GitDiffTableRow(kind: .gap)); rows.append(GitDiffTableRow(kind: .showAll)) }
            rows.append(GitDiffTableRow(kind: .bottom))
            self.rows = rows; self.splits = splits
        }

        /// The hosted heading's height at this width, and "Show the whole
        /// diff"'s. True when the heading's changed.
        @discardableResult
        private func remeasure(width: CGFloat) -> Bool {
            measuredWidth = width
            guard width > 0 else { return false }
            let bound = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            let top = ceil(topHost.sizeThatFits(in: bound).height)
            moreHeight = hasMore ? ceil(moreHost.sizeThatFits(in: bound).height) : 0
            defer { topHeight = top }
            return top != topHeight
        }

        /// Forgets wrapped rows' heights: they are measured again, at this
        /// width, as the table asks for them. Rows that do not wrap have the
        /// height of their kind and are never measured.
        private func measureRows(width: CGFloat) {
            heightWidth = width; breaks = [:]
            wrapped = wrap ? Array(repeating: nil, count: rows.count) : []
        }
        private func height(of index: Int, card: CGFloat) -> CGFloat {
            let row = rows[index]
            switch row.kind {
            case .top: return topHeight
            case .showAll: return moreHeight
            case .gap: return GitDiffMetrics.cardGap
            case .bottom: return GitDiffMetrics.bottom
            case .file: return GitDiffMetrics.fileHeader
            case .hunk: return GitDiffMetrics.hunkHeader
            case .note:
                let count = GitDiffText.lineCount(files[Int(row.file)].notes[Int(row.item)], font: GitDiffMetrics.micro, width: card - 24)
                return CGFloat(count) * GitDiffMetrics.microLine + 8
            case .line:
                guard wrap else { return GitDiffMetrics.monoLine + 2 }
                return CGFloat(lines(of: index, width: GitDiffMetrics.textWidth(unified: card)).count) * GitDiffMetrics.monoLine + 2
            case .split:
                guard wrap else { return GitDiffMetrics.monoLine + 2 }
                let pair = splits[Int(row.item)], width = GitDiffMetrics.textWidth(split: card)
                let left = pair.left.map { GitDiffText.lineCount(Self.shown($0.text), font: GitDiffMetrics.mono, width: width) } ?? 1
                let right = pair.right.map { GitDiffText.lineCount(Self.shown($0.text), font: GitDiffMetrics.mono, width: width) } ?? 1
                return CGFloat(max(left, right)) * GitDiffMetrics.monoLine + 2
            }
        }
        func cardWidth(_ width: CGFloat) -> CGFloat { max(0, width - 2 * GitDiffMetrics.cardInset) }

        /// A line's text as SwiftUI showed it: an empty line is a space.
        static func shown(_ text: String) -> String { text.isEmpty ? " " : text }

        /// The wrapped lines of a unified row's text, cached per width.
        func lines(of index: Int, width: CGFloat) -> [Range<Int>] {
            if let cached = breaks[index] { return cached }
            let row = rows[index]
            let text = Self.shown(files[Int(row.file)].hunks[Int(row.hunk)].lines[Int(row.item)].text)
            let found = GitDiffText.breaks(text, font: GitDiffMetrics.mono, width: width)
            breaks[index] = found
            return found
        }

        /// A new width: the heading measured again, and wrapped text.
        private func widthChanged() {
            guard let table else { return }
            let width = table.bounds.width
            let heading = remeasure(width: width)
            if wrap || rows.contains(where: { $0.kind == .note || $0.kind == .showAll }) {
                measureRows(width: width)
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
            } else if heading {
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0))
            }
            heightWidth = width
        }

        // MARK: Rows

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < rows.count else { return 1 }
            switch rows[row].kind {
            case .top: return max(1, topHeight)
            case .showAll: return max(1, moreHeight)
            case .gap: return GitDiffMetrics.cardGap
            case .bottom: return GitDiffMetrics.bottom
            case .file: return GitDiffMetrics.fileHeader
            case .hunk: return GitDiffMetrics.hunkHeader
            case .line, .split:
                guard wrap else { return GitDiffMetrics.monoLine + 2 }
                if row < wrapped.count, let known = wrapped[row] { return known }
                let measured = height(of: row, card: cardWidth(heightWidth))
                if row < wrapped.count { wrapped[row] = measured }
                return measured
            case .note: return height(of: row, card: cardWidth(heightWidth))
            }
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("git-diff-row")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? GitDiffRowView ?? GitDiffRowView()
            view.identifier = identifier
            return view
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < rows.count else { return nil }
            switch rows[row].kind {
            case .top: return topHost.view
            case .showAll: return moreHost.view
            case .gap, .bottom:
                let cell = tableView.makeView(withIdentifier: GitDiffSpaceCell.identifier, owner: self) as? GitDiffSpaceCell ?? GitDiffSpaceCell()
                return cell
            default:
                let cell = tableView.makeView(withIdentifier: GitDiffRowCell.identifier, owner: self) as? GitDiffRowCell ?? GitDiffRowCell()
                cell.coordinator = self; cell.row = row
                cell.setAccessibilityValue(accessibilityText(row))
                cell.needsDisplay = true
                GitDiffRenderCount.built()
                return cell
            }
        }

        private func accessibilityText(_ index: Int) -> String {
            let row = rows[index], file = files[Int(row.file)]
            switch row.kind {
            case .file: return file.renamed ? "\(file.oldPath) renamed to \(file.newPath)" : file.path
            case .note: return file.notes[Int(row.item)]
            case .hunk: return file.hunks[Int(row.hunk)].header
            case .line: return Self.spoken(file.hunks[Int(row.hunk)].lines[Int(row.item)])
            case .split:
                let pair = splits[Int(row.item)]
                return [pair.left.map { Self.spoken($0) }, pair.right.map { Self.spoken($0) }].compactMap { $0 }.joined(separator: "; ")
            default: return ""
            }
        }
        private static func spoken(_ line: GitDiffLine) -> String {
            switch line.kind {
            case .added: return "Added line \(line.newNumber ?? 0): " + line.text
            case .removed: return "Removed line \(line.oldNumber ?? 0): " + line.text
            case .context: return "Line \(line.newNumber ?? 0): " + line.text
            case .note: return line.text
            }
        }

        func redrawVisible() {
            guard let table else { return }
            table.enumerateAvailableRowViews { rowView, _ in rowView.subviews.forEach { $0.needsDisplay = true } }
        }

        // MARK: Drawing

        func line(_ row: GitDiffTableRow) -> GitDiffLine { files[Int(row.file)].hunks[Int(row.hunk)].lines[Int(row.item)] }
        func pair(_ row: GitDiffTableRow) -> GitSplitRow { splits[Int(row.item)] }
        func file(_ row: GitDiffTableRow) -> GitDiffFile { files[Int(row.file)] }

        // MARK: Selection

        /// The text a row selects on a side: a line's text, a file's path.
        func selectable(_ index: Int, side: GitDiffSide) -> String? {
            guard index >= 0, index < rows.count else { return nil }
            let row = rows[index]
            switch row.kind {
            case .line: return line(row).text
            case .split:
                let pair = pair(row)
                switch side { case .left: return pair.left?.text; case .right: return pair.right?.text; case .whole: return nil }
            case .file:
                let file = file(row)
                return file.renamed ? "\(file.oldPath) → \(file.newPath)" : file.path
            default: return nil
            }
        }
        /// The part of a row's text inside the selection, and whether the
        /// selection runs on past the row's end.
        func selected(in index: Int, side: GitDiffSide) -> (range: Range<Int>, through: Bool)? {
            guard let anchor, let focus, anchor != focus, side == self.side || rows[index].kind == .file,
                  let text = selectable(index, side: self.side) else { return nil }
            let start = min(anchor, focus), end = max(anchor, focus)
            guard index >= start.row, index <= end.row else { return nil }
            let length = text.utf16.count
            let from = index == start.row ? min(start.index, length) : 0
            let to = index == end.row ? min(end.index, length) : length
            guard to > from || index < end.row else { return nil }
            return (from..<max(from, to), index < end.row)
        }
        var selectedText: String {
            guard let anchor, let focus, anchor != focus else { return "" }
            let start = min(anchor, focus), end = max(anchor, focus)
            var parts: [String] = []
            for index in start.row...end.row {
                guard let text = selectable(index, side: side) else { continue }
                let utf16 = Array(text.utf16)
                let from = index == start.row ? min(start.index, utf16.count) : 0
                let to = index == end.row ? min(end.index, utf16.count) : utf16.count
                parts.append(String(utf16CodeUnits: Array(utf16[from..<max(from, to)]), count: max(0, to - from)))
            }
            return parts.joined(separator: "\n")
        }
        func select(from anchor: GitDiffTextPoint?, to focus: GitDiffTextPoint?, side: GitDiffSide) {
            let before = rangeOfRows
            self.anchor = anchor; self.focus = focus; self.side = side
            let after = rangeOfRows
            redraw(rows: before, after)
        }
        private var rangeOfRows: ClosedRange<Int>? {
            guard let anchor, let focus else { return nil }
            return min(anchor.row, focus.row)...max(anchor.row, focus.row)
        }
        private func redraw(rows ranges: ClosedRange<Int>?...) {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            for range in ranges.compactMap({ $0 }) {
                let low = max(range.lowerBound, visible.location), high = min(range.upperBound, visible.location + visible.length - 1)
                guard low <= high else { continue }
                for row in low...high { table.view(atColumn: 0, row: row, makeIfNecessary: false)?.needsDisplay = true }
            }
        }
        func selectAll() {
            guard let first = rows.firstIndex(where: { $0.kind == .file }), let last = rows.lastIndex(where: { $0.kind == .line || $0.kind == .split || $0.kind == .file }) else { return }
            let side: GitDiffSide = split ? .right : .whole
            select(from: GitDiffTextPoint(row: first, index: 0), to: GitDiffTextPoint(row: last, index: (selectable(last, side: side) ?? "").utf16.count), side: side)
            redrawVisible()
        }
        func copySelection() {
            let text = selectedText
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

enum GitDiffSide { case whole, left, right }

// MARK: - Text

/// Core Text for the diff's rows: a line drawn as SwiftUI drew a one-line
/// `Text` (tab stops every 28 points, "…" where it is cut), and wrapped lines
/// broken as SwiftUI broke them.
@MainActor enum GitDiffText {
    static func attributed(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor])
    }
    static func line(_ text: String, font: NSFont, color: NSColor = .black) -> CTLine {
        CTLineCreateWithAttributedString(attributed(text, font: font, color: color))
    }
    static func width(_ text: String, font: NSFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(text, font: font), nil, nil, nil))
    }
    /// A one-line text's width as SwiftUI sized it: up to the next pixel.
    static func frameWidth(_ text: String, font: NSFont, scale: CGFloat) -> CGFloat { ceil(width(text, font: font) * scale) / scale }

    /// Draws `text` on one line with its baseline at `baseline`, cut to
    /// `width` with an ellipsis at the end (or the middle). Returns the line
    /// drawn, for hit-testing.
    @discardableResult
    static func draw(_ text: String, font: NSFont, color: NSColor, x: CGFloat, baseline: CGFloat, width: CGFloat = .greatestFiniteMagnitude,
                     truncation: CTLineTruncationType = .end, in context: CGContext) -> CTLine {
        let full = line(text, font: font, color: color)
        let drawn = fitted(full, text: text, font: font, color: color, width: width, truncation: truncation)
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(drawn, context)
        context.restoreGState()
        return drawn
    }
    static func fitted(_ full: CTLine, text: String, font: NSFont, color: NSColor, width: CGFloat, truncation: CTLineTruncationType = .end) -> CTLine {
        guard width.isFinite, CGFloat(CTLineGetTypographicBounds(full, nil, nil, nil)) > width + 0.01,
              let cut = CTLineCreateTruncatedLine(full, Double(width), truncation, line("…", font: font, color: color)) else { return full }
        return cut
    }

    /// Where a text breaks into lines `width` wide: at words, or inside a word
    /// longer than a line.
    static func breaks(_ text: String, font: NSFont, width: CGFloat) -> [Range<Int>] {
        let attributed = self.attributed(text, font: font, color: .black)
        let length = attributed.length
        guard width > 1, length > 0 else { return [0..<length] }
        // A line that fits whole needs no typesetter.
        if CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)) <= width { return [0..<length] }
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var ranges: [Range<Int>] = [], start = 0
        while start < length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(width)))
            ranges.append(start..<(start + count)); start += count
        }
        return ranges
    }
    static func lineCount(_ text: String, font: NSFont, width: CGFloat) -> Int { breaks(text, font: font, width: width).count }
}

// MARK: - Views

/// The table: rows drawn by their cells, a text selection across them that
/// the reader drags, extends and copies, and the keys that scroll it.
final class GitDiffTableView: NSTableView {
    weak var coordinator: GitDiffTable.Coordinator?

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { defer { coordinator?.redrawVisible() }; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { defer { coordinator?.redrawVisible() }; return super.resignFirstResponder() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged(_:)), name: NSWindow.didResignKeyNotification, object: window)
        }
    }
    @objc private func keyChanged(_ note: Notification) { coordinator?.redrawVisible() }
    /// The selection shows in the reader's highlight while they are in the
    /// table, and in the quieter one otherwise, as a text view's does.
    var selectionActive: Bool { window?.isKeyWindow == true && window?.firstResponder === self }

    override func setFrameSize(_ newSize: NSSize) {
        let wider = newSize.width != frame.width
        super.setFrameSize(newSize)
        if wider { needsLayout = true }
    }
    override func layout() {
        coordinator?.layoutWillHappen()
        super.layout()
    }

    // MARK: Selection

    override func mouseDown(with event: NSEvent) {
        guard let coordinator, let window else { return super.mouseDown(with: event) }
        window.makeFirstResponder(self)
        let start = convert(event.locationInWindow, from: nil)
        guard let hit = point(at: start, side: nil) else { coordinator.select(from: nil, to: nil, side: .whole); return }
        let clicks = event.clickCount
        var anchor = hit.point, side = hit.side
        if event.modifierFlags.contains(.shift), let existing = coordinator.anchor { anchor = existing; side = coordinator.side }
        // A double click takes a word, a triple click the row's whole text.
        var wordAnchor: Range<Int>?
        if clicks >= 2, let text = coordinator.selectable(hit.point.row, side: hit.side) {
            let range: Range<Int>
            if clicks == 2 {
                let ns = NSAttributedString(string: text).doubleClick(at: min(hit.point.index, max(0, text.utf16.count - 1)))
                range = ns.location..<(ns.location + ns.length)
            } else { range = 0..<text.utf16.count }
            wordAnchor = range
            coordinator.select(from: GitDiffTextPoint(row: hit.point.row, index: range.lowerBound), to: GitDiffTextPoint(row: hit.point.row, index: range.upperBound), side: hit.side)
        } else {
            coordinator.select(from: anchor, to: hit.point, side: side)
        }
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        var last = event
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
            if next.type == .leftMouseUp { break }
            if next.type == .leftMouseDragged { last = next }
            autoscroll(with: last)
            let location = convert(last.locationInWindow, from: nil)
            guard let moved = point(at: location, side: side) else { continue }
            if let word = wordAnchor {
                // A word or a line taken at a click stays taken; dragging past
                // it extends the selection from its far end.
                let origin = hit.point.row
                let start = GitDiffTextPoint(row: origin, index: word.lowerBound), end = GitDiffTextPoint(row: origin, index: word.upperBound)
                if moved.point >= start && moved.point <= end { coordinator.select(from: start, to: end, side: side) }
                else { coordinator.select(from: moved.point > end ? start : end, to: moved.point, side: side) }
            } else {
                coordinator.select(from: anchor, to: moved.point, side: side)
            }
        }
    }

    /// The text position under a point: its row, and the offset in the text
    /// that row selects, the side fixed once a selection has begun.
    func point(at location: NSPoint, side fixed: GitDiffSide?) -> (point: GitDiffTextPoint, side: GitDiffSide)? {
        guard let coordinator, numberOfRows > 0 else { return nil }
        // The row across from the pointer, wherever it is left or right.
        var row = self.row(at: NSPoint(x: min(max(location.x, 0), bounds.width - 1), y: location.y))
        if row < 0 { row = location.y < 0 ? 0 : numberOfRows - 1 }
        let rect = rect(ofRow: row)
        let card = coordinator.cardWidth(bounds.width)
        let side = fixed ?? (coordinator.split && location.x >= GitDiffMetrics.cardInset + GitDiffMetrics.halfWidth(card) ? .right : coordinator.split ? .left : .whole)
        guard let text = coordinator.selectable(row, side: side) else {
            // Between rows that hold text: the start of the next one.
            return (GitDiffTextPoint(row: row, index: location.y > rect.midY ? Int.max / 2 : 0), side)
        }
        let geometry = GitDiffRowCell.textFrame(coordinator.rows[row].kind, side: side, card: card, rowWidth: bounds.width)
        let x = location.x - geometry.x
        let y = location.y - rect.minY
        let font = GitDiffMetrics.mono
        let wrapped = coordinator.wrap && coordinator.rows[row].kind != .file
        let lines: [Range<Int>] = wrapped ? GitDiffText.breaks(GitDiffTable.Coordinator.shown(text), font: font, width: geometry.width) : [0..<text.utf16.count]
        let index = max(0, min(lines.count - 1, Int((y - geometry.top) / GitDiffMetrics.monoLine)))
        let range = lines[index]
        let utf16 = Array(text.utf16)
        let segment = String(utf16CodeUnits: Array(utf16[range.clamped(to: 0..<utf16.count)]), count: range.clamped(to: 0..<utf16.count).count)
        let line = GitDiffText.line(segment, font: font)
        if x >= geometry.width { return (GitDiffTextPoint(row: row, index: range.upperBound), side) }
        let offset = CTLineGetStringIndexForPosition(line, CGPoint(x: max(0, x), y: 0))
        return (GitDiffTextPoint(row: row, index: range.lowerBound + max(0, min(offset, range.count))), side)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let coordinator else { return nil }
        let location = convert(event.locationInWindow, from: nil)
        let row = self.row(at: location)
        var entries: [PiMenuEntry] = [
            .button("Copy", enabled: !coordinator.selectedText.isEmpty, identifier: "git-diff-copy") { [weak coordinator] in coordinator?.copySelection() },
            .button("Select All", identifier: "git-diff-select-all") { [weak coordinator] in coordinator?.selectAll() },
        ]
        if row >= 0, row < coordinator.rows.count, coordinator.rows[row].kind == .file {
            let path = coordinator.file(coordinator.rows[row]).path
            entries.append(.divider)
            entries.append(.button("Copy Path", identifier: "git-diff-copy-path") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string)
            })
        }
        return PiMenus.menu(entries)
    }

    @objc func copy(_ sender: Any?) { coordinator?.copySelection() }
    override func selectAll(_ sender: Any?) { coordinator?.selectAll() }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !(coordinator?.selectedText.isEmpty ?? true) }
        if item.action == #selector(selectAll(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Keys

    /// Arrows scroll a row, Page Up and Down and the space bar a page, Home
    /// and End to either end. Everything else, Escape first, goes on.
    override func keyDown(with event: NSEvent) {
        guard let clip = enclosingScrollView?.contentView else { return super.keyDown(with: event) }
        let page = max(GitDiffMetrics.monoLine, clip.bounds.height - GitDiffMetrics.monoLine - 2)
        let delta: CGFloat?
        switch event.keyCode {
        case 126: delta = -(GitDiffMetrics.monoLine + 2)
        case 125: delta = GitDiffMetrics.monoLine + 2
        case 116: delta = -page
        case 121: delta = page
        case 49: delta = event.modifierFlags.contains(.shift) ? -page : page
        case 115: delta = -.greatestFiniteMagnitude
        case 119: delta = .greatestFiniteMagnitude
        default: delta = nil
        }
        guard let delta, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return super.keyDown(with: event) }
        let top = max(0, min(frame.height - clip.bounds.height, clip.bounds.minY + delta))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }
    override func cancelOperation(_ sender: Any?) { nextResponder?.doCommand(by: #selector(cancelOperation(_:))) }

    override func resetCursorRects() {
        guard let coordinator else { return }
        let visible = rows(in: visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) where row < coordinator.rows.count {
            switch coordinator.rows[row].kind {
            case .line, .split, .file: addCursorRect(rect(ofRow: row), cursor: .iBeam)
            default: break
            }
        }
    }
}

/// A row's background draws nothing: the cells draw their own.
final class GitDiffRowView: NSTableRowView {
    override var isOpaque: Bool { false }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    /// Clicks on a drawn row reach the table, which selects text; a hosted
    /// row's controls take their own.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// The space between cards and under the last one.
final class GitDiffSpaceCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("git-diff-space")
    init() { super.init(frame: .zero); identifier = Self.identifier; setAccessibilityElement(false) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A drawn row: a file's header, a note, a hunk's header, or a line, unified
/// or side by side, inside its card.
final class GitDiffRowCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("git-diff-row-cell")
    weak var coordinator: GitDiffTable.Coordinator?
    var row = 0

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    /// Where a row's selectable text sits, in the row: its x, its width and
    /// the top of its first line.
    static func textFrame(_ kind: GitDiffTableRow.Kind, side: GitDiffSide, card: CGFloat, rowWidth: CGFloat) -> (x: CGFloat, width: CGFloat, top: CGFloat) {
        let left = GitDiffMetrics.cardInset
        switch kind {
        case .file: return (left + 12 + 12 + 8, card - 24 - 20, 7)
        case .split:
            let half = GitDiffMetrics.halfWidth(card)
            let start = side == .right ? left + half + 1 : left
            return (start + GitDiffMetrics.splitText, GitDiffMetrics.textWidth(split: card), 1)
        default: return (left + GitDiffMetrics.unifiedText, GitDiffMetrics.textWidth(unified: card), 1)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let coordinator, row < coordinator.rows.count, let context = NSGraphicsContext.current?.cgContext else { return }
        let model = coordinator.rows[row]
        let card = coordinator.cardWidth(bounds.width)
        let left = GitDiffMetrics.cardInset
        // The card: its corners on its first and last rows, a hairline inside
        // its edge, everything clipped to it, as SwiftUI's overlay and clip.
        let top: CGFloat = model.first ? 0 : -1_000, bottom: CGFloat = model.last ? bounds.height : bounds.height + 1_000
        let shape = RoundedRectangle(cornerRadius: GitDiffMetrics.cardRadius, style: .continuous)
            .path(in: CGRect(x: left, y: top, width: card, height: bottom - top)).cgPath
        context.saveGState()
        context.addPath(shape); context.clip()
        switch model.kind {
        case .file: drawFile(model, card: card, context: context, coordinator: coordinator)
        case .note: drawNote(model, card: card, context: context, coordinator: coordinator)
        case .hunk: drawHunk(model, card: card, context: context, coordinator: coordinator)
        case .line: drawLine(model, card: card, context: context, coordinator: coordinator)
        case .split: drawSplit(model, card: card, context: context, coordinator: coordinator)
        default: break
        }
        context.addPath(shape)
        context.setStrokeColor(GitDiffMetrics.fill(.piHairline, opacity: 1)); context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()
    }

    /// The display's pixel: SwiftUI rounds a text's width up to it.
    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    private var selectionColor: NSColor {
        (superview?.superview as? GitDiffTableView)?.selectionActive == true ? .selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor
    }

    /// The selected part of one line of text, filled behind it: from `start`
    /// to `end` in the line, or on to the column's edge when the selection
    /// runs past the line.
    private func drawSelection(start: Int, end: Int, runsOn: Bool, length: Int, line: CTLine, x: CGFloat, top: CGFloat, width: CGFloat, context: CGContext) {
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        func offset(_ index: Int) -> CGFloat { index >= length ? lineWidth : CGFloat(CTLineGetOffsetForStringIndex(line, index, nil)) }
        let from = min(width, offset(start))
        let to = runsOn ? width : min(width, offset(end))
        guard to > from else { return }
        context.setFillColor(selectionColor.cgColor)
        context.fill(CGRect(x: x + from, y: top, width: to - from, height: GitDiffMetrics.monoLine))
    }
    private func drawSelection(_ selection: (range: Range<Int>, through: Bool)?, text: String, line: CTLine, x: CGFloat, top: CGFloat, width: CGFloat, context: CGContext) {
        guard let selection else { return }
        drawSelection(start: selection.range.lowerBound, end: selection.range.upperBound, runsOn: selection.through, length: text.utf16.count,
                      line: line, x: x, top: top, width: width, context: context)
    }

    private func drawFile(_ model: GitDiffTableRow, card: CGFloat, context: CGContext, coordinator: GitDiffTable.Coordinator) {
        let file = coordinator.file(model), left = GitDiffMetrics.cardInset
        context.setFillColor(GitDiffMetrics.fill(.piSurfaceSunken, opacity: 1))
        context.fill(CGRect(x: left, y: 0, width: card, height: bounds.height))
        GitDiffSymbol.draw("doc.text", pointSize: 11, weight: .regular, color: .piInkSecondary, in: CGRect(x: left + 12, y: 7.5, width: 12, height: 14))
        // The counts at the right, then the path in what is left.
        var right = left + card - 12
        var counts: [(String, NSColor)] = []
        if file.added > 0 { counts.append(("+\(file.added)", .piSuccess)) }
        if file.removed > 0 { counts.append(("−\(file.removed)", .piDanger)) }
        for (text, color) in counts.reversed() {
            let width = GitDiffText.frameWidth(text, font: GitDiffMetrics.microDigits, scale: scale)
            GitDiffText.draw(text, font: GitDiffMetrics.microDigits, color: color, x: right - width, baseline: 8 + GitDiffMetrics.microBaseline, in: context)
            right -= width + 8
        }
        let text = file.renamed ? "\(file.oldPath) → \(file.newPath)" : file.path
        let x = left + 32
        let width = max(0, right - 8 - x)
        let line = GitDiffText.fitted(GitDiffText.line(text, font: GitDiffMetrics.mono, color: .piInk), text: text, font: GitDiffMetrics.mono, color: .piInk, width: width, truncation: .middle)
        drawSelection(coordinator.selected(in: row, side: coordinator.side), text: text, line: line, x: x, top: 7, width: width, context: context)
        GitDiffText.draw(text, font: GitDiffMetrics.mono, color: .piInk, x: x, baseline: 7 + GitDiffMetrics.monoBaseline, width: width, truncation: .middle, in: context)
    }

    private func drawNote(_ model: GitDiffTableRow, card: CGFloat, context: CGContext, coordinator: GitDiffTable.Coordinator) {
        let text = coordinator.file(model).notes[Int(model.item)], left = GitDiffMetrics.cardInset
        let lines = GitDiffText.breaks(text, font: GitDiffMetrics.micro, width: card - 24)
        let utf16 = Array(text.utf16)
        for (index, range) in lines.enumerated() {
            let part = String(utf16CodeUnits: Array(utf16[range]), count: range.count)
            GitDiffText.draw(part, font: GitDiffMetrics.micro, color: .piInkTertiary, x: left + 12,
                             baseline: 4 + CGFloat(index) * GitDiffMetrics.microLine + GitDiffMetrics.microBaseline, in: context)
        }
    }

    private func drawHunk(_ model: GitDiffTableRow, card: CGFloat, context: CGContext, coordinator: GitDiffTable.Coordinator) {
        let hunk = coordinator.file(model).hunks[Int(model.hunk)], left = GitDiffMetrics.cardInset
        context.setFillColor(GitDiffMetrics.fill(.piInfo, opacity: 0.06))
        context.fill(CGRect(x: left, y: 0, width: card, height: bounds.height))
        GitDiffText.draw(hunk.header, font: GitDiffMetrics.mono, color: .piInfo, x: left + 12, baseline: 3 + GitDiffMetrics.monoBaseline, width: card - 24, in: context)
    }

    private static func tint(_ kind: GitDiffLine.Kind) -> NSColor? {
        switch kind { case .added: .piSuccess; case .removed: .piDanger; case .context, .note: nil }
    }

    private func drawLine(_ model: GitDiffTableRow, card: CGFloat, context: CGContext, coordinator: GitDiffTable.Coordinator) {
        let line = coordinator.line(model), left = GitDiffMetrics.cardInset
        let tint = Self.tint(line.kind)
        if let tint {
            context.setFillColor(GitDiffMetrics.fill(tint, opacity: 0.10))
            context.fill(CGRect(x: left, y: 0, width: card, height: bounds.height))
        }
        let x0 = left + 8, baseline = 1 + GitDiffMetrics.monoBaseline
        if let old = line.oldNumber {
            let text = String(old)
            GitDiffText.draw(text, font: GitDiffMetrics.mono, color: .piInkTertiary, x: x0 + 44 - GitDiffText.frameWidth(text, font: GitDiffMetrics.mono, scale: scale), baseline: baseline, in: context)
        }
        if let new = line.newNumber {
            let text = String(new)
            GitDiffText.draw(text, font: GitDiffMetrics.mono, color: .piInkTertiary, x: x0 + 88 - GitDiffText.frameWidth(text, font: GitDiffMetrics.mono, scale: scale), baseline: baseline, in: context)
        }
        let marker = switch line.kind { case .added: "+"; case .removed: "−"; case .context: " "; case .note: "\\" }
        GitDiffText.draw(marker, font: GitDiffMetrics.mono, color: tint ?? .piInkTertiary, x: x0 + 96 + (12 - GitDiffText.width(marker, font: GitDiffMetrics.mono)) / 2, baseline: baseline, in: context)
        let geometry = Self.textFrame(.line, side: .whole, card: card, rowWidth: bounds.width)
        drawText(GitDiffTable.Coordinator.shown(line.text), selectable: line.text, color: line.kind == .note ? .piInkTertiary : .piInk,
                 x: geometry.x, width: geometry.width, selection: coordinator.selected(in: row, side: .whole), wrap: coordinator.wrap, context: context)
    }

    private func drawSplit(_ model: GitDiffTableRow, card: CGFloat, context: CGContext, coordinator: GitDiffTable.Coordinator) {
        let pair = coordinator.pair(model), left = GitDiffMetrics.cardInset
        let half = GitDiffMetrics.halfWidth(card)
        for (side, line, number) in [(GitDiffSide.left, pair.left, pair.left?.oldNumber), (GitDiffSide.right, pair.right, pair.right?.newNumber)] {
            let start = side == .left ? left : left + half + 1
            let kind = line?.kind ?? .context
            // The halves' fills stop a point short of the row's top and bottom.
            let fill: CGColor? = line == nil ? GitDiffMetrics.fill(.piFill, opacity: 0.5) : Self.tint(kind).map { GitDiffMetrics.fill($0, opacity: 0.10) }
            if let fill {
                context.setFillColor(fill)
                context.fill(CGRect(x: start, y: 1, width: half, height: bounds.height - 2))
            }
            if let number {
                let text = String(number)
                GitDiffText.draw(text, font: GitDiffMetrics.mono, color: .piInkTertiary, x: start + 48 - GitDiffText.frameWidth(text, font: GitDiffMetrics.mono, scale: scale),
                                 baseline: 1 + GitDiffMetrics.monoBaseline, in: context)
            }
            let geometry = Self.textFrame(.split, side: side, card: card, rowWidth: bounds.width)
            drawText(GitDiffTable.Coordinator.shown(line?.text ?? ""), selectable: line?.text ?? "", color: kind == .note ? .piInkTertiary : .piInk,
                     x: geometry.x, width: geometry.width, selection: coordinator.selected(in: row, side: side), wrap: coordinator.wrap, context: context)
        }
        context.setFillColor(GitDiffMetrics.fill(.piHairline, opacity: 1))
        context.fill(CGRect(x: left + half, y: 1, width: 1, height: bounds.height - 2))
    }

    /// A row's text: one line cut with "…", or every line it wraps to.
    private func drawText(_ text: String, selectable: String, color: NSColor, x: CGFloat, width: CGFloat, selection: (range: Range<Int>, through: Bool)?,
                          wrap: Bool, context: CGContext) {
        guard wrap else {
            drawSelection(selection, text: selectable, line: GitDiffText.line(text, font: GitDiffMetrics.mono), x: x, top: 1, width: width, context: context)
            GitDiffText.draw(text, font: GitDiffMetrics.mono, color: color, x: x, baseline: 1 + GitDiffMetrics.monoBaseline, width: width, in: context)
            return
        }
        let utf16 = Array(text.utf16)
        let lines = GitDiffText.breaks(text, font: GitDiffMetrics.mono, width: width)
        for (index, range) in lines.enumerated() {
            let part = String(utf16CodeUnits: Array(utf16[range]), count: range.count)
            let top = 1 + CGFloat(index) * GitDiffMetrics.monoLine
            if let selection {
                // What of the selection falls on this line, and whether it runs past it.
                let start = max(selection.range.lowerBound, range.lowerBound), end = min(selection.range.upperBound, range.upperBound)
                let runsOn = selection.through || selection.range.upperBound > range.upperBound
                if start <= range.upperBound, end > start || runsOn, selection.range.lowerBound <= range.upperBound {
                    drawSelection(start: start - range.lowerBound, end: max(start, end) - range.lowerBound, runsOn: runsOn, length: range.count,
                                  line: GitDiffText.line(part, font: GitDiffMetrics.mono), x: x, top: top, width: width, context: context)
                }
            }
            GitDiffText.draw(part, font: GitDiffMetrics.mono, color: color, x: x, baseline: top + GitDiffMetrics.monoBaseline, in: context)
        }
    }
}

/// Symbol images drawn by the rows, cached by name, size, weight, colour and appearance.
@MainActor enum GitDiffSymbol {
    private static var cache: [String: NSImage] = [:]
    static func draw(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor, in frame: CGRect) {
        let appearance = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? ""
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(ObjectIdentifier(color).hashValue)|\(appearance)"
        let image: NSImage
        if let cached = cache[key] { image = cached }
        else {
            let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color.usingColorSpace(.sRGB) ?? color]))
            guard let made = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
            cache[key] = made; image = made
        }
        // From the frame's leading edge, as SwiftUI places a symbol a little
        // wider than the frame its alignment rectangle gives it.
        let size = image.size
        image.draw(in: CGRect(x: frame.minX, y: frame.midY - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
