import AppKit

/// What the transcript marks in its text: every occurrence of the find bar's
/// query, softly, and one place in one message strongly — the find bar's
/// current match, or a range a reveal asked for (`revealInTranscript`).
///
/// Marks are TextKit temporary attributes on the text views of rows on
/// screen: they never change a row's text or its height, so nothing moves
/// for them. They are applied again to a row's text whenever the row is
/// mounted, so a row that let go of its tree and built it again is marked
/// like any other.
struct TranscriptHighlights: Equatable {
    /// Marked wherever it occurs, ignoring case. Empty marks nothing.
    var query = ""
    var focus: Focus?
    struct Focus: Equatable {
        /// The message whose row holds the place.
        var messageID: String
        /// The text to find in that row, ignoring case, and which occurrence
        /// of it (from 0, in reading order) is the place.
        var needle: String
        var occurrence: Int
        /// Bumped for each request, so the same place asked for again is
        /// brought into view again.
        var serial: Int
        /// The find bar's own match, whose drawn count it reconciles; a
        /// reveal's mark is not.
        var fromFind = false
        /// Counts only text inside the card of this call (a tool's result
        /// drawn in its call's card: the occurrence is the result's own, not
        /// the reply's).
        var scopeCall: String? = nil
        /// The record the place was asked for when its row is another
        /// message's (a tool's result): whose count a find reconciles.
        var record: String? = nil
    }
    var isEmpty: Bool { query.isEmpty && focus == nil }

    static let matchColor = NSColor.piAccentSoft
    static let focusColor = NSColor.piWarning.withAlphaComponent(0.42)
}

extension TranscriptItem {
    /// The messages this row draws.
    var messageIDs: [String] {
        switch self {
        case .message(let message): return [message.id]
        case .block(let block): return block.replies.map(\.id)
        }
    }
}

extension TranscriptNativeDocument {
    /// Every text view in `view`, in reading order.
    static func textViews(in view: NSView) -> [NSTextView] {
        var found: [NSTextView] = []
        func visit(_ view: NSView) {
            if let text = view as? NSTextView { found.append(text); return }
            for child in view.subviews where !child.isHidden { visit(child) }
        }
        visit(view)
        return found.sorted { a, b in
            let ya = a.convert(NSPoint.zero, to: view).y, yb = b.convert(NSPoint.zero, to: view).y
            return view.isFlipped ? ya < yb : ya > yb
        }
    }
    /// What holds text in `view`, in reading order: text views, and a card's
    /// lines as one unit (their lines are built only near the viewport).
    static func textUnits(in view: NSView) -> [NSView] {
        var found: [NSView] = []
        func visit(_ view: NSView) {
            if view is TranscriptCardLines || view is NSTextView { found.append(view); return }
            for child in view.subviews where !child.isHidden { visit(child) }
        }
        visit(view)
        return found.sorted { a, b in
            let ya = a.convert(NSPoint.zero, to: view).y, yb = b.convert(NSPoint.zero, to: view).y
            return view.isFlipped ? ya < yb : ya > yb
        }
    }
    /// The tool call row whose card `view` is in, if any.
    static func card(holding view: NSView) -> TranscriptNativeActionRow? {
        var current = view.superview
        while let ancestor = current, !(ancestor is TranscriptRowContainer) {
            if let row = ancestor as? TranscriptNativeActionRow { return row }
            current = ancestor.superview
        }
        return nil
    }
    /// Whether `text` draws a call's input rather than what it returned: a
    /// card's "Tool input" section, or a terminal card's command line.
    static func isToolInput(_ text: NSView) -> Bool {
        var current = text.superview, capped = false
        while let ancestor = current, !(ancestor is TranscriptNativeActionRow) {
            if let section = ancestor as? TranscriptCardSection { return section.accessibilityLabel() == "Tool input" }
            if ancestor is TranscriptCappedText { capped = true }
            if ancestor is TranscriptNativeTerminalCard { return !capped }
            current = ancestor.superview
        }
        return false
    }
    /// Opens what a card keeps folded inside it — a read card's middle lines
    /// — when the focused needle is in that card's output, so the place has
    /// text to be marked in. Only while a place is being brought into view:
    /// a reader who folds it again afterwards keeps it folded.
    func expandCardsForFocus(in row: TranscriptRowContainer) {
        guard let focus = highlights.focus else { return }
        func visit(_ view: NSView) {
            if let action = view as? TranscriptNativeActionRow, let tool = action.tool,
               focus.scopeCall.map({ $0 == tool.id }) ?? true,
               tool.output.range(of: focus.needle, options: .caseInsensitive) != nil {
                func expand(_ view: NSView) {
                    if let read = view as? TranscriptNativeReadCard, !read.expanded { read.setExpanded(true) }
                    for child in view.subviews { expand(child) }
                }
                expand(action)
                return
            }
            for child in view.subviews { visit(child) }
        }
        visit(row)
    }
    /// The ranges of `needle` in `text`, ignoring case.
    static func ranges(of needle: String, in text: NSString) -> [NSRange] {
        guard !needle.isEmpty, text.length > 0 else { return [] }
        var found: [NSRange] = [], from = 0
        while from < text.length {
            let range = text.range(of: needle, options: [.caseInsensitive], range: NSRange(location: from, length: text.length - from))
            guard range.location != NSNotFound, range.length > 0 else { break }
            found.append(range); from = NSMaxRange(range)
        }
        return found
    }

    /// The rows that draw message `id`, in reading order: one, or several
    /// for a response laid out as a timeline (its header, then its parts).
    func rows(drawing id: String) -> [TranscriptRowContainer] {
        retainedRows.filter { $0.contentItem.messageIDs.contains(id) }
    }
    func row(drawing id: String) -> TranscriptRowContainer? { rows(drawing: id).first }

    /// Where the focused place is: its occurrence counted across every row of
    /// the message the page has on screen, in reading order. `complete` says
    /// whether every row of the message was on screen to count; `pending` is
    /// the first of its rows that was not.
    struct FocusResolution {
        var target: (text: NSTextView, range: NSRange, row: TranscriptRowContainer)?
        var rendered: Int
        var complete: Bool
        var pending: TranscriptRowContainer?
        var first: TranscriptRowContainer?
        /// The place is on this card line, which is not built yet.
        var line: (lines: TranscriptCardLines, index: Int)?
    }
    func resolveFocus() -> FocusResolution? {
        guard let focus = highlights.focus else { return nil }
        let rows = rows(drawing: focus.messageID)
        guard !rows.isEmpty else { return nil }
        let request = "\(focus.serial):\(focus.fromFind)"
        if focusCountsSerial != request { focusCountsSerial = request; focusRowCounts = [:] }
        // In reading order, the occurrences each row holds: counted from its
        // text while it is on screen, remembered once counted. The place is
        // found only among rows counted in order, so a row not yet seen never
        // lets a later one's occurrence stand for it.
        var counted = 0, pending: TranscriptRowContainer?, target: (NSTextView, NSRange, TranscriptRowContainer)?
        var unbuilt: (lines: TranscriptCardLines, index: Int)?
        let index = max(0, focus.occurrence)
        for row in rows {
            if row.superview === self, row.isHosted {
                // Every occurrence in order, a card's lines counted from what
                // they hold whether or not each line is built now.
                var ranges: [(text: NSTextView?, range: NSRange, lines: TranscriptCardLines?, line: Int)] = []
                for unit in Self.textUnits(in: row) {
                    if let call = focus.scopeCall, Self.card(holding: unit)?.tool?.id != call || Self.isToolInput(unit) { continue }
                    if let lines = unit as? TranscriptCardLines {
                        for (line, content) in lines.lines.enumerated() {
                            for range in Self.ranges(of: focus.needle, in: content.text as NSString) { ranges.append((lines.builtText(at: line), range, lines, line)) }
                        }
                    } else if let text = unit as? NSTextView {
                        for range in Self.ranges(of: focus.needle, in: (text.textStorage?.string ?? "") as NSString) { ranges.append((text, range, nil, 0)) }
                    }
                }
                focusRowCounts[ObjectIdentifier(row)] = ranges.count
                if target == nil, unbuilt == nil, index >= counted, index < counted + ranges.count {
                    let found = ranges[index - counted]
                    // An occurrence on a card line not built yet has no text
                    // to mark: the line is gone to, and looked at again.
                    if let text = found.text { target = (text, found.range, row) }
                    else if let lines = found.lines { unbuilt = (lines, found.line) }
                }
                counted += ranges.count
            } else if let known = focusRowCounts[ObjectIdentifier(row)] {
                // The place is in a row counted before and off screen now:
                // that row is where to go, and nothing after it matters yet.
                if target == nil, index >= counted, index < counted + known { pending = row; break }
                counted += known
            } else {
                if pending == nil, target == nil { pending = row }
                break
            }
        }
        let complete = rows.allSatisfy { focusRowCounts[ObjectIdentifier($0)] != nil }
        return FocusResolution(target: target.map { (text: $0.0, range: $0.1, row: $0.2) }, rendered: counted,
                               complete: complete, pending: target == nil && unbuilt == nil ? pending : nil, first: rows.first, line: unbuilt)
    }

    /// Marks one row's text as the highlights say, if it is not marked so already.
    func markHighlights(in row: TranscriptRowContainer) {
        for text in Self.textViews(in: row) {
            let focused = focusText === text
            let stamp = highlightGeneration * 2 + (focused ? 1 : 0)
            guard let manager = text.layoutManager, let storage = text.textStorage else { continue }
            if markedText.object(forKey: text)?.intValue == stamp, storage.length == markedLength.object(forKey: text)?.intValue { continue }
            let whole = NSRange(location: 0, length: storage.length)
            manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
            for range in Self.ranges(of: highlights.query, in: storage.string as NSString) {
                manager.addTemporaryAttribute(.backgroundColor, value: TranscriptHighlights.matchColor, forCharacterRange: range)
            }
            if focused, NSMaxRange(focusRange) <= storage.length {
                manager.addTemporaryAttribute(.backgroundColor, value: TranscriptHighlights.focusColor, forCharacterRange: focusRange)
            }
            markedText.setObject(NSNumber(value: stamp), forKey: text)
            markedLength.setObject(NSNumber(value: storage.length), forKey: text)
        }
    }
    /// Works out where the focused place is now, and marks every row on
    /// screen again where that changed.
    func markMountedRows() {
        // Cards that keep the place folded open before anything is counted,
        // or their folded lines would count as nothing.
        if focusPending, let focus = highlights.focus {
            for row in rows(drawing: focus.messageID) where row.superview === self { expandCardsForFocus(in: row) }
        }
        let resolution = resolveFocus()
        let text = resolution?.target?.text, range = resolution?.target?.range ?? NSRange(location: NSNotFound, length: 0)
        if text !== focusText || range != focusRange {
            focusText = text; focusRange = range; highlightGeneration += 1
        }
        if let resolution, resolution.complete, let focus = highlights.focus, focus.fromFind, reportedFocus != focus.serial {
            reportedFocus = focus.serial
            onFocusResolved?(focus.record ?? focus.messageID, focus.needle, resolution.rendered)
        }
        for row in retainedRows where row.superview === self { markHighlights(in: row) }
    }

    /// Brings the focused place into view if a request for it is pending: a
    /// third of the way down the viewport, unless it is already well inside
    /// it. A row of the message that is not on screen yet, and holds the
    /// place, is scrolled to first. The reader is then the page's no longer:
    /// the page stops following the newest row and holds the row where it
    /// stands, so measuring around it does not move the place away.
    func revealFocusIfPending() {
        guard focusPending, let scroll = enclosingScrollView, let focus = highlights.focus else { return }
        for row in rows(drawing: focus.messageID) where row.superview === self { expandCardsForFocus(in: row) }
        guard let resolution = resolveFocus() else { return }
        let clip = scroll.contentView, viewport = clip.bounds
        let rect: CGRect, row: TranscriptRowContainer
        if let target = resolution.target, let manager = target.text.layoutManager, let container = target.text.textContainer {
            manager.ensureLayout(forCharacterRange: target.range)
            // Output capped in a scroll of its own is scrolled to the place
            // first; the transcript then brings that into view.
            if let inner = target.text.enclosingScrollView, inner !== scroll { target.text.scrollRangeToVisible(target.range) }
            let glyphs = manager.glyphRange(forCharacterRange: target.range, actualCharacterRange: nil)
            var bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
            bounds.origin.x += target.text.textContainerOrigin.x; bounds.origin.y += target.text.textContainerOrigin.y
            rect = target.text.convert(bounds, to: clip); row = target.row
            focusPending = false
        } else if let (lines, index) = resolution.line, let lineRect = lines.lineRect(at: index) {
            // The place is on a line of a card not built yet: go there, and
            // look again once it is. Lines capped in a scroll of their own are
            // scrolled there first.
            if let inner = lines.enclosingScrollView, inner !== scroll {
                lines.scrollToVisible(lineRect)
                // The inner scroll builds the line without the transcript
                // moving: look again once it has, a bounded number of times.
                if focusRetries < 30 {
                    focusRetries += 1
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.focusPending else { return }
                        self.markMountedRows(); self.scheduleFocusReveal()
                    }
                }
            }
            let line = lines.convert(lineRect, to: clip)
            if !viewport.insetBy(dx: 0, dy: min(80, viewport.height / 6)).contains(CGPoint(x: line.midX, y: line.midY)) {
                readerWillNavigate(upward: line.minY < viewport.minY)
                scroll.transcriptReading.setOrigin(NSPoint(x: viewport.minX, y: line.minY - viewport.height / 3))
            }
            focusPending = true
            return
        } else if let pending = resolution.pending {
            // The place is in a row of the message not on screen yet: go there,
            // and look again once it is mounted.
            rect = convert(CGRect(x: 0, y: pending.frame.minY, width: 1, height: 1), to: clip); row = pending
        } else if let first = resolution.first {
            // The message's text does not show the place (it is inside a
            // folded card): its row is where it is.
            rect = first.convert(first.bounds, to: clip); row = first
            focusPending = false
        } else { return }
        let margin = min(80, viewport.height / 6), stillPending = focusPending
        if rect.minY < viewport.minY + margin || rect.maxY > viewport.maxY - margin {
            readerWillNavigate(upward: rect.minY < viewport.minY)
            scroll.transcriptReading.setOrigin(NSPoint(x: viewport.minX, y: rect.minY - viewport.height / 3))
        }
        focusPending = stillPending
        scroll.transcriptReading.hold(row)
    }
}
