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
    var following = false { didSet { if following { clear(reason: "following") } } }
    var readingAnchor: NativeMarkdownContainer.LogicalAnchor? { source }
    var hasAnchor: Bool { source != nil || row != nil }
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
    }
    func readerMoved() {
        readerRevision &+= 1; clear(reason: "reader gesture")
    }
    private func clear(reason: String) {
        source = nil; surface = nil; row = nil; lastInvalidation = reason
    }
    func capture(_ candidate: NativeMarkdownContainer) {
        guard !following, source == nil, let scroll, candidate.window != nil,
              candidate.enclosingScrollView === scroll,
              candidate.convert(candidate.bounds, to: scroll.contentView).intersects(scroll.contentView.bounds),
              let anchor = candidate.preparedLogicalAnchor else { return }
        source = anchor; surface = candidate; row = nil
    }
    func captureDocument() {
        guard !following, !hasAnchor, let scroll, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        func visit(_ view: NSView) {
            guard source == nil, !view.isHidden, view.convert(view.bounds, to: clip).intersects(clip.bounds) else { return }
            if let markdown = view as? NativeMarkdownContainer { capture(markdown); return }
            for child in view.subviews { visit(child) }
        }
        visit(document)
        if source == nil, let native = document as? TranscriptNativeDocument,
           let first = native.retainedRows.first(where: { $0.frame.maxY > clip.bounds.minY }) {
            row = first; rowDisplacement = first.convert(.zero, to: clip).y - clip.bounds.minY
        }
    }
    func geometryChanged() {
        scroll?.documentView?.needsDisplay = true
        guard hasAnchor, !following, !scheduled else { return }
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
        guard !following, !writing, let scroll else { return false }
        let clip = scroll.contentView
        let delta: CGFloat
        if let source, let surface, surface.enclosingScrollView === scroll,
           let desiredTop = surface.top(for: source) {
            let currentTop = surface.convert(clip.bounds, from: clip).minY
            delta = surface.convert(NSPoint(x: 0, y: desiredTop), to: clip).y - surface.convert(NSPoint(x: 0, y: currentTop), to: clip).y
        } else if let row, row.enclosingScrollView === scroll {
            delta = row.convert(.zero, to: clip).y - clip.bounds.minY - rowDisplacement
        } else { clear(reason: "source no longer retained"); return false }
        let scale = scroll.window?.backingScaleFactor ?? 1
        if abs(delta) > 1 / scale { setOrigin(NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + delta)); correctionCount += 1 }
        return true
    }
    func setOrigin(_ origin: NSPoint) {
        guard let scroll else { return }
        writing = true
        let clip = scroll.contentView
        let bounds = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size))
        if clip.bounds.origin != bounds.origin { clip.setBoundsOrigin(bounds.origin); scroll.reflectScrolledClipView(clip) }
        writing = false
    }
}
