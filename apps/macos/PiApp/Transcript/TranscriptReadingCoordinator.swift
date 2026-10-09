import AppKit
import ObjectiveC

@MainActor private var readingCoordinatorKey: UInt8 = 0

extension NSScrollView {
    /// One position writer per pane, including standalone full-source views.
    @MainActor var transcriptReading: TranscriptReadingCoordinator {
        if let value = objc_getAssociatedObject(self, &readingCoordinatorKey) as? TranscriptReadingCoordinator { return value }
        let value = TranscriptReadingCoordinator(scroll: self)
        objc_setAssociatedObject(self, &readingCoordinatorKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return value
    }
}

/// Inner Markdown reports source coordinates; only this pane-level object
/// converts them to a constrained clip correction. An anchor survives any
/// number of source appends and hosting-height adoptions until reader intent
/// or its presentation scope supersedes it.
@MainActor final class TranscriptReadingCoordinator {
    private weak var scroll: NSScrollView?
    private weak var surface: NativeMarkdownContainer?
    private var source: NativeMarkdownContainer.LogicalAnchor?
    private weak var row: NSView? { didSet { if row !== oldValue { noteRow() } } }
    private var rowDisplacement: CGFloat = 0 {
        didSet { noteRow(); anchorDocumentTop = scroll.map { $0.contentView.bounds.minY + rowDisplacement } }
    }
    /// Where the held row's top belongs in the document, as of the last time
    /// the reader's line was where the anchor says. A row that has moved from
    /// there since — rows above it measured, a page read in — is owed that
    /// difference by the next correction.
    private var anchorDocumentTop: CGFloat?
    /// The same for the anchored character of a text anchor, whose line can
    /// move within its row while the row's top stays put.
    private var anchorSourceTop: CGFloat?
    private func sourceTop(in scroll: NSScrollView) -> CGFloat? {
        guard let source, let surface, surface.enclosingScrollView === scroll, let y = surface.top(for: source) else { return nil }
        return surface.convert(NSPoint(x: 0, y: y), to: scroll.contentView).y
    }
    /// What the held row draws, and how far below the viewport's top its
    /// bottom stands: a row replaced by one for the same messages — the turn
    /// at the top of the window joining its earlier part as an earlier page
    /// arrives — is found again by them, its new rows above the old ones.
    private var heldMessages: [String] = []
    private var rowBottomDisplacement: CGFloat = 0
    private func noteRow() {
        guard let held = row as? TranscriptRowContainer else { heldMessages = []; return }
        heldMessages = held.contentItem.messageIDs
        rowBottomDisplacement = rowDisplacement + held.frame.height
    }
    /// The row that now draws the held row's messages, when the held row was
    /// replaced; nil when none does. `ready` is false while it is not placed yet.
    private func successor(in scroll: NSScrollView) -> (row: TranscriptRowContainer, ready: Bool)? {
        guard !heldMessages.isEmpty, let document = scroll.documentView as? TranscriptNativeDocument else { return nil }
        for id in heldMessages.reversed() {
            if let found = document.retainedRows.first(where: { $0 !== row && $0.contentItem.messageIDs.contains(id) }) {
                return (found, found.frame.height > 0)
            }
        }
        return nil
    }
    private var scope = ""
    private(set) var readerRevision: UInt64 = 0
    private(set) var correctionCount = 0
    private(set) var lastInvalidation = "initial"
    private var scheduled = false
    private var writing = false
    /// Every scroll this pane writes, so the page can tell its own movement
    /// from the reader's. Each write goes through `setOrigin`, so recording it
    /// here covers the anchor correction, the bottom follow, the opening
    /// placement and a restored reading position alike.
    let ledger = TranscriptScrollLedger()
    var following = false { didSet { if following { clear(reason: "following") } } }
    var readingAnchor: NativeMarkdownContainer.LogicalAnchor? { source }
    /// A row replaced under the anchor (`successor`) is still the anchor
    /// until it is found again or the anchor is let go of.
    var hasAnchor: Bool { source != nil || row != nil || !heldMessages.isEmpty }
    /// The page's answer to whose movement the clip's current offset is. An
    /// anchor holds the reader's line while the geometry around it changes;
    /// it is taken where the reader stands, so a movement of theirs that lands
    /// after it was taken — a wheel AppKit applies a frame later, each step of
    /// a scroller drag — leaves it describing a place they have left, and
    /// restoring it would put them back there. The page drops it the moment
    /// the ledger says a movement was the reader's. Every observer of the
    /// clip hears of that movement, in no promised order, so one that reaches
    /// the anchor first asks the page before capturing or restoring it.
    var classifyMovement: (() -> Void)?
    nonisolated(unsafe) private var eventMonitor: Any?

    init(scroll: NSScrollView) {
        self.scroll = scroll
        // Clip bounds also change during layout. Only real input can supersede
        // a reading anchor, including in standalone full-source scroll views.
        if !(scroll is TranscriptNativeScrollView) {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) { [weak self, weak scroll] event in
                MainActor.assumeIsolated {
                    guard let scroll, event.window === scroll.window else { return }
                    let point = scroll.convert(event.locationInWindow, from: nil)
                    if scroll.bounds.contains(point), event.type != .leftMouseDown || scroll.verticalScroller?.frame.contains(point) == true {
                        self?.readerMoved()
                    }
                }
                return event
            }
        }
    }
    deinit { if let eventMonitor { NSEvent.removeMonitor(eventMonitor) } }
    func bind(scope: String) {
        guard self.scope != scope else { return }
        self.scope = scope; readerRevision &+= 1; clear(reason: "presentation changed")
        ledger.reset()
    }
    func readerMoved() {
        // A movement of the reader's can land between a change of the
        // geometry around their row and its correction (AppKit applies a
        // wheel step on its own schedule). What the change moved is put
        // right first; what the reader moved stays theirs.
        if !writing, let scroll {
            // Measured where the anchor holds: at its character when the text
            // is on screen, else at its row.
            var owed: CGFloat?
            if let expected = anchorSourceTop, let now = sourceTop(in: scroll) { owed = now - expected }
            else if let row, let expected = anchorDocumentTop, let now = heldRowTop(row, in: scroll) { owed = now - expected }
            if let owed, abs(owed) > 0.5 {
                let clip = scroll.contentView
                setOrigin(NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + owed))
            }
        }
        readerRevision &+= 1; clear(reason: "reader gesture")
        // Nothing the page wrote before the reader touched the page still
        // explains where they end up.
        ledger.forgetWrites()
    }
    private func clear(reason: String) {
        source = nil; surface = nil; row = nil; lastInvalidation = reason; anchorDocumentTop = nil; anchorSourceTop = nil
        // Explicitly: a row already let go of reads nil, and setting nil again
        // does not tell `noteRow`.
        heldMessages = []
    }
    /// Makes sure the movement that put the clip where it is has been
    /// attributed before the anchor is used.
    private func catchUp() {
        guard let scroll, ledger.awaitsDelivery(of: scroll.contentView.bounds.origin.y) else { return }
        classifyMovement?()
    }
    func capture(_ candidate: NativeMarkdownContainer) {
        catchUp()
        guard !following, source == nil, let scroll, candidate.window != nil,
              candidate.enclosingScrollView === scroll,
              candidate.convert(candidate.bounds, to: scroll.contentView).intersects(scroll.contentView.bounds),
              holdsReadingLine(candidate) else { return }
        // A row already held is given up only for its own text at the
        // reader's line, which holds that line to the character.
        if let row, !candidate.isDescendant(of: row) { return }
        guard let anchor = candidate.preparedLogicalAnchor else { return }
        source = anchor; surface = candidate
        // The row the text is in is held with it. A page arriving above the
        // reader, or rows let go of above them, can move that row out of the
        // view tree in the pass that has to put it back, and its text with
        // it: the row still has its place in the document, and that place
        // still says where the reader's line is.
        var container: NSView? = candidate.superview
        while let view = container, !(view is TranscriptRowContainer) { container = view.superview }
        row = container
        if let container { rowDisplacement = container.convert(NSPoint.zero, to: scroll.contentView).y - scroll.contentView.bounds.minY }
        anchorSourceTop = sourceTop(in: scroll)
    }
    /// The reader's line is the top of the viewport. In a conversation it is
    /// in the first row, in page order, that reaches below it, and a native
    /// surface holds it only when the line falls in that surface's own text.
    /// A surface lower on the screen is not where the reader is: holding one
    /// made a card opened above it grow upward, its header leaving the top of
    /// the screen, and every streamed token of a reply below the reader took
    /// the position for itself.
    private func holdsReadingLine(_ candidate: NativeMarkdownContainer) -> Bool {
        guard let scroll, let native = scroll.documentView as? TranscriptNativeDocument else { return true }
        let clip = scroll.contentView
        let text = candidate.convert(candidate.bounds, to: clip)
        guard text.minY <= clip.bounds.minY, text.maxY > clip.bounds.minY,
              let reading = readingRow(in: native, clip: clip) else { return false }
        return candidate.isDescendant(of: reading)
    }
    /// The row after `reading`, when `reading` starts above the screen and
    /// less than a third of the screen shows it, and that next row starts on
    /// screen; nil otherwise. The reader is reading that next row: held by the
    /// top of the one above it, a measurement of that one's unseen part (an
    /// estimate the page replaces as the row comes into reach) moved
    /// everything they can see.
    static func firstStartingOnScreen(_ document: TranscriptNativeDocument, clip: NSClipView, after reading: TranscriptRowContainer) -> TranscriptRowContainer? {
        let screen = document.convert(clip.bounds, from: clip)
        guard reading.frame.minY < screen.minY - 0.5, reading.frame.maxY - screen.minY < screen.height / 3,
              document.retainedRows.indices.contains(reading.layoutIndex + 1) else { return nil }
        let next = document.retainedRows[reading.layoutIndex + 1]
        return next.frame.minY < screen.maxY && next.frame.height > 0 ? next : nil
    }
    /// The row the reader's line is in, once it is on screen: a row the page
    /// has not mounted there yet has no place to be held from.
    private func readingRow(in document: TranscriptNativeDocument, clip: NSClipView) -> TranscriptRowContainer? {
        guard let first = document.retainedRows.first(where: { $0.frame.maxY > clip.bounds.minY }),
              first.superview === document else { return nil }
        return first
    }
    /// Holds the reader's line on a row the page has just put them at,
    /// wherever on the screen it sits, instead of the row at the top of the
    /// viewport: that row is usually one the reader was never shown, and its
    /// own measurement would move the one they were.
    func hold(_ held: NSView) {
        catchUp()
        guard !following, let scroll, held.enclosingScrollView === scroll else { return }
        source = nil; surface = nil; anchorSourceTop = nil; row = held
        rowDisplacement = held.convert(NSPoint.zero, to: scroll.contentView).y - scroll.contentView.bounds.minY
    }
    func captureDocument() {
        catchUp()
        guard !following, !hasAnchor, let scroll, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        func visit(_ view: NSView) {
            guard source == nil, !view.isHidden, view.convert(view.bounds, to: clip).intersects(clip.bounds) else { return }
            if let markdown = view as? NativeMarkdownContainer { capture(markdown); return }
            for child in view.subviews { visit(child) }
        }
        guard let native = document as? TranscriptNativeDocument else { visit(document); return }
        // In a conversation, the row at the reader's line — and its own text,
        // if the line falls in a native surface of it — rather than whichever
        // surface comes first among the subviews, which are in the order the
        // rows were mounted, not the order they are read.
        if let reading = readingRow(in: native, clip: clip) {
            visit(reading)
            if source == nil {
                // A row of which only a little shows is not the one being read:
                // the row after it, which starts on screen, is held instead,
                // as a web page holds its first visible element.
                let held = Self.firstStartingOnScreen(native, clip: clip, after: reading) ?? reading
                row = held; rowDisplacement = native.convert(NSPoint(x: 0, y: held.frame.minY), to: clip).y - clip.bounds.minY
            }
            return
        }
        // A fast scroll can stand the reader on a row the page has not
        // mounted yet. It still has its place in the document, and that place
        // is held: a page read in above in this moment would otherwise move
        // everything on screen by its height.
        guard let first = native.retainedRows.first(where: { $0.frame.maxY > clip.bounds.minY }), first.frame.height > 0 else { return }
        let unmounted = Self.firstStartingOnScreen(native, clip: clip, after: first) ?? first
        row = unmounted
        rowDisplacement = native.convert(NSPoint(x: 0, y: native.isFlipped ? unmounted.frame.minY : unmounted.frame.maxY), to: clip).y - clip.bounds.minY
    }
    func geometryChanged() {
        // A page with a position to hold must draw the corrected geometry, not
        // the geometry that changed: the correction below lands in this same
        // pass or in the next run-loop turn, and the draw waits for it. A page
        // that is following the newest row has nothing to correct and nothing
        // to wait for, so it is not marked.
        guard hasAnchor, !following else { return }
        scroll?.documentView?.needsDisplay = true
        guard !scheduled else { return }
        scheduled = true
        let revision = readerRevision, scope = scope
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard self.scope == scope, self.readerRevision == revision else { return }
            self.restore()
        }
    }
    @discardableResult func restore() -> Bool {
        guard !writing else { return false }
        catchUp()
        guard !following, let scroll else { return false }
        let clip = scroll.contentView
        let scale = scroll.window?.backingScaleFactor ?? 1
        // Moving the clip can synchronously prepare newly visible blocks.
        // That preparation can move the anchor again while setOrigin's
        // reentrancy guard is active. Reconcile the resulting geometry before
        // returning to drawing, instead of showing it for one frame and
        // correcting it on the next run-loop turn. Bound the work in case a
        // view keeps changing or AppKit constrains the requested position.
        for _ in 0..<4 {
            let delta: CGFloat
            var bySource = false
            if let source, let surface, surface.enclosingScrollView === scroll,
               let desiredTop = surface.top(for: source) {
                let currentTop = surface.convert(clip.bounds, from: clip).minY
                delta = surface.convert(NSPoint(x: 0, y: desiredTop), to: clip).y - surface.convert(NSPoint(x: 0, y: currentTop), to: clip).y
                bySource = true
            } else if let row, let top = heldRowTop(row, in: scroll) {
                // The text's surface is gone for good (its row let go of its
                // tree): the row alone holds the line from here, and a new
                // capture may take the rebuilt text again.
                if source != nil, surface == nil { source = nil; anchorSourceTop = nil }
                delta = top - clip.bounds.minY - rowDisplacement
            } else if let next = successor(in: scroll) {
                // The row was replaced by one drawing the same messages. Until
                // it is placed there is nothing to correct against yet.
                guard next.ready else { return true }
                let bottom = rowBottomDisplacement
                source = nil; surface = nil; anchorSourceTop = nil; row = next.row
                rowDisplacement = bottom - next.row.frame.height
                continue
            } else {
                clear(reason: "source no longer retained"); return false
            }
            guard abs(delta) > 1 / scale else {
                // Held to the character, the row may have moved within the
                // reader's line (text above it in the row re-measured): the
                // row's own place is taken again from where it now stands.
                if bySource, let row, let top = heldRowTop(row, in: scroll) { rowDisplacement = top - clip.bounds.minY; anchorSourceTop = sourceTop(in: scroll) }
                else { anchorDocumentTop = clip.bounds.minY + rowDisplacement }
                return true
            }
            let previous = clip.bounds.origin
            setOrigin(NSPoint(x: previous.x, y: previous.y + delta))
            guard clip.bounds.origin != previous else { return true }
            correctionCount += 1
            // What this write moved is paid, and only that: a movement of the
            // row the write itself caused (rows measured as it scrolled) is
            // still owed by a reader movement before the next restore.
            let moved = clip.bounds.origin.y - previous.y
            if let paid = anchorDocumentTop { anchorDocumentTop = paid + moved }
            if let paid = anchorSourceTop { anchorSourceTop = paid + moved }
        }
        geometryChanged()
        return true
    }
    /// Where the held row begins, in the clip's coordinates. A row the page
    /// still holds keeps its place in the document when the viewport pass
    /// takes it out of the view tree — an earlier page arriving above the
    /// reader pushes their row out of the viewport in the same pass that has
    /// to put it back — and that place is still where their line is. Read
    /// from the view tree only, the row was lost there: the line came back a
    /// run-loop turn later, and the frame in between showed the earlier page
    /// where the reader's row had been.
    private func heldRowTop(_ row: NSView, in scroll: NSScrollView) -> CGFloat? {
        if row.enclosingScrollView === scroll { return row.convert(NSPoint.zero, to: scroll.contentView).y }
        guard let held = row as? TranscriptRowContainer, let document = scroll.documentView as? TranscriptNativeDocument,
              document.retainedRows.indices.contains(held.layoutIndex), document.retainedRows[held.layoutIndex] === held else { return nil }
        let origin = NSPoint(x: held.frame.minX, y: held.isFlipped == document.isFlipped ? held.frame.minY : held.frame.maxY)
        return document.convert(origin, to: scroll.contentView).y
    }
    func setOrigin(_ origin: NSPoint) {
        guard let scroll else { return }
        writing = true
        let clip = scroll.contentView
        let bounds = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size))
        if clip.bounds.origin != bounds.origin {
            // Written down before it is written: the bounds notification can
            // arrive inside `setBoundsOrigin`, and the page reads the ledger
            // from inside it.
            ledger.wrote(from: clip.bounds.origin.y, to: bounds.origin.y)
            clip.setBoundsOrigin(bounds.origin); scroll.reflectScrolledClipView(clip)
        }
        writing = false
    }
    /// A scroll this pane is about to run as an animation. AppKit delivers
    /// every frame of it, so the whole corridor between the two ends belongs
    /// to the page until it lands.
    func willAnimate(from: CGFloat, to: CGFloat) { ledger.wrote(from: from, to: to, animated: true) }
}
