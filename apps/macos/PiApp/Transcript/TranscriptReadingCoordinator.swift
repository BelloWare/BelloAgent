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
    private weak var row: NSView?
    private var rowDisplacement: CGFloat = 0
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
    var hasAnchor: Bool { source != nil || row != nil }
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
        readerRevision &+= 1; clear(reason: "reader gesture")
        // Nothing the page wrote before the reader touched the page still
        // explains where they end up.
        ledger.forgetWrites()
    }
    private func clear(reason: String) {
        source = nil; surface = nil; row = nil; lastInvalidation = reason
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
        source = anchor; surface = candidate; row = nil
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
    /// The row the reader's line is in, once it is on screen: a row the page
    /// has not mounted there yet has no place to be held from.
    private func readingRow(in document: TranscriptNativeDocument, clip: NSClipView) -> TranscriptRowContainer? {
        guard let first = document.retainedRows.first(where: { $0.frame.maxY > clip.bounds.minY }),
              first.superview === document else { return nil }
        return first
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
        guard let reading = readingRow(in: native, clip: clip) else { return }
        visit(reading)
        if source == nil {
            row = reading; rowDisplacement = reading.convert(.zero, to: clip).y - clip.bounds.minY
        }
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
            if let source, let surface, surface.enclosingScrollView === scroll,
               let desiredTop = surface.top(for: source) {
                let currentTop = surface.convert(clip.bounds, from: clip).minY
                delta = surface.convert(NSPoint(x: 0, y: desiredTop), to: clip).y - surface.convert(NSPoint(x: 0, y: currentTop), to: clip).y
            } else if let row, let top = heldRowTop(row, in: scroll) {
                delta = top - clip.bounds.minY - rowDisplacement
            } else { clear(reason: "source no longer retained"); return false }
            guard abs(delta) > 1 / scale else { return true }
            let previous = clip.bounds.origin
            setOrigin(NSPoint(x: previous.x, y: previous.y + delta))
            guard clip.bounds.origin != previous else { return true }
            correctionCount += 1
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
