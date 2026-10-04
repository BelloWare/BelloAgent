import AppKit
import SwiftUI

/// A turn's tool calls, drawn natively. A turn that ran sixty of them retains
/// every card and its exact height, while only the cards near the outer
/// conversation viewport participate in native layout, drawing and tracking.
/// This is not another scroll view and it truncates nothing: every card is
/// still there, still openable, still selectable once it is on screen.
///
/// The reason a long turn can be folded and unfolded inside a frame is that a
/// card the reader has not opened is one line high whatever it says — the
/// header truncates to a single line and every badge on it is shorter than
/// that line. So measuring one closed card measures all of them, and only the
/// cards the reader has actually opened are laid out individually. The
/// assumption is not taken on trust: every card that mounts is checked against
/// the height it was placed at, and a card that disagrees keeps its own.
struct NativeWorkListSurface: NSViewRepresentable {
    /// Below this a turn is short enough that the plain SwiftUI stack is both
    /// simpler and cheaper than a hosting view per card.
    static let minimumRowCount = 8
    let tools: [ToolView]
    let openTools: Set<String>
    let fetched: [String: ToolInputDocument]
    let toggle: (String) -> Void
    var openFile: ((String, ClosedRange<Int>?) -> Void)? = nil

    func makeNSView(context: Context) -> NativeWorkListContainer {
        let view = NativeWorkListContainer()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: NativeWorkListContainer, context: Context) {
        view.update(tools: tools, openTools: openTools, fetched: fetched, toggle: toggle, openFile: openFile,
                    environment: TranscriptRowEnvironment(context.environment))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeWorkListContainer, context: Context) -> CGSize? {
        nsView.measure(width: proposal.width)
    }
}

/// What one card is, as a value the container can compare.
private struct NativeWorkListItem: Equatable {
    var tool: ToolView
    var open: Bool
    var fetched: ToolInputDocument?
    var environment: TranscriptRowEnvironment
}

/// The relay a card's button talks to, so replacing the turn's callbacks never
/// replaces a card's view.
@MainActor private final class WorkListToggleRelay {
    var current: (String) -> Void = { _ in }
    var openFile: ((String, ClosedRange<Int>?) -> Void)?
}

/// One card of the list: its call, the native row once it is needed, and
/// what it was last measured at. A closed card nobody has scrolled to is
/// never built: the shared closed height stands for it.
@MainActor private final class NativeWorkListRowHost {
    private(set) var built: TranscriptNativeActionRow?
    /// Called when the built row changed its own height.
    var sizeChanged: () -> Void = {}
    var view: TranscriptNativeActionRow {
        if let built { return built }
        let view = TranscriptNativeActionRow()
        // A card never paints outside the space the list gave it, so a height
        // that turns out to be wrong is a short card, never one drawn over
        // the next.
        view.clipsToBounds = true
        view.sizeChanged = { [weak self] in self?.sizeChanged() }
        built = view
        apply()
        return view
    }
    private(set) var item: NativeWorkListItem
    private var sizes: [CGSize] = []
    private let relay: WorkListToggleRelay
    var frame = CGRect.zero
    /// Set when this card's own measurement disagreed with the height every
    /// closed card is placed at, so it keeps its own from then on.
    var ownHeight: (width: CGFloat, height: CGFloat)?
    private(set) var measurementCount = 0
    var id: String { item.tool.id }

    init(item: NativeWorkListItem, relay: WorkListToggleRelay) {
        self.item = item
        self.relay = relay
    }
    @discardableResult func update(_ item: NativeWorkListItem) -> Bool {
        guard self.item != item else { return false }
        self.item = item
        forgetSizes()
        apply()
        return true
    }
    /// What the card measured no longer holds: it changed its own height.
    func forgetSizes() { sizes.removeAll(keepingCapacity: true); ownHeight = nil }
    private func apply() {
        guard let view = built else { return }
        let id = item.tool.id
        view.update(tool: item.tool, open: item.open, fetched: item.fetched, environment: item.environment,
                    toggle: { [weak relay] in relay?.current(id) },
                    openFile: { [weak relay] path, lines in relay?.openFile?(path, lines) })
    }
    func measure(width: CGFloat) -> CGFloat {
        if let cached = sizes.last(where: { $0.width == width }) { return cached.height }
        if TranscriptLayoutClock.recording { TranscriptLayoutClock.workListCardsMeasured += 1 }
        let height = max(1, ceil(view.height(width: width)))
        if sizes.count == 4 { sizes.removeFirst() }
        sizes.append(CGSize(width: width, height: height))
        measurementCount += 1
        return height
    }
    /// What this card measures if it has already been measured at this width.
    func measured(width: CGFloat) -> CGFloat? { sizes.last(where: { $0.width == width })?.height }
    func place(in container: NSView) {
        let moved = view.frame != frame || view.superview !== container
        if view.frame != frame { view.frame = frame }
        if view.superview !== container { container.addSubview(view) }
        // A card that moved shows other lines than it did.
        if moved { view.refreshVisibleLines() }
    }
}

@MainActor final class NativeWorkListContainer: NSView {
    private struct Layout {
        var width: CGFloat
        var heights: [CGFloat]
        var total: CGFloat
    }
    private var rows: [NativeWorkListRowHost] = []
    private var layouts: [Layout] = []
    private var laidOutWidth: CGFloat?
    private var invalidationScheduled = false
    private var applyingLayout = false
    private let relay = WorkListToggleRelay()
    /// What one closed card is worth at a width, measured once for the turn.
    private var closedHeight: [CGFloat: CGFloat] = [:]
    /// How many closed cards at a width have been checked against the height
    /// they all share, and the widths where one of them disagreed. A handful
    /// of agreeing cards is enough to trust the rest of a turn; one that
    /// disagrees puts every card of that turn back on its own measurement.
    private var closedChecks: [CGFloat: Int] = [:]
    private var closedDisagreed: Set<CGFloat> = []
    static let closedCardChecks = 4
    private weak var observedClip: NSClipView?
    nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: layouts.last(where: { $0.width == bounds.width })?.total ?? NSView.noIntrinsicMetric)
    }
    /// Evidence for the fixtures: unfolding a long turn must measure a handful
    /// of cards, not all of them, and scrolling must measure none.
    var rowMeasurementCount: Int { rows.reduce(0) { $0 + $1.measurementCount } }
    var retainedRowCount: Int { rows.count }
    var mountedRowCount: Int { rows.reduce(0) { $0 + ($1.built?.superview === self ? 1 : 0) } }
    /// How many cards have a native row at all: the ones ever near the viewport, or measured.
    var builtRowCount: Int { rows.reduce(0) { $0 + ($1.built == nil ? 0 : 1) } }
    /// The card at an index, for fixtures that check what is drawn where.
    func mountedRowIDs() -> [String] { rows.filter { $0.built?.superview === self }.map(\.id) }

    deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }

    func update(tools: [ToolView], openTools: Set<String>, fetched: [String: ToolInputDocument],
                toggle: @escaping (String) -> Void, openFile: ((String, ClosedRange<Int>?) -> Void)? = nil, environment: TranscriptRowEnvironment) {
        relay.current = toggle
        relay.openFile = openFile
        // A changed environment changes every card, including the closed ones
        // that share one measurement. Read it before the cards take the new one.
        let environmentChanged = rows.first.map { $0.item.environment != environment } ?? false
        var changed = rows.count != tools.count
        for (index, tool) in tools.enumerated() {
            let item = NativeWorkListItem(tool: tool, open: openTools.contains(tool.id),
                                          fetched: openTools.contains(tool.id) ? fetched[tool.id] : nil,
                                          environment: environment)
            if rows.indices.contains(index) { if rows[index].update(item) { changed = true } }
            else {
                let host = NativeWorkListRowHost(item: item, relay: relay)
                // A card that changes its own height (a diff expanded) is
                // measured again, and the list laid out around it.
                host.sizeChanged = { [weak self, weak host] in
                    guard let self, let host else { return }
                    host.forgetSizes()
                    self.relayout()
                }
                rows.append(host)
            }
        }
        if rows.count > tools.count {
            for row in rows.dropFirst(tools.count) { row.built?.removeFromSuperview() }
            rows.removeLast(rows.count - tools.count)
        }
        guard changed else { return }
        if environmentChanged { closedHeight = [:]; closedChecks = [:]; closedDisagreed = [] }
        layouts.removeAll(keepingCapacity: true)
        laidOutWidth = nil
        needsLayout = true
        // Input changes can arrive during a parent's fittingSize pass. Let
        // SwiftUI finish that update before advertising a new intrinsic size.
        guard !invalidationScheduled else { return }
        invalidationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.invalidationScheduled = false
            self.invalidateIntrinsicContentSize()
        }
    }

    /// Lays the list out again after a card changed its own height, and
    /// tells the transcript row it is drawn in to measure itself again: the
    /// change came from inside, not from anything SwiftUI was given.
    private func relayout() {
        layouts.removeAll(keepingCapacity: true)
        laidOutWidth = nil
        needsLayout = true
        invalidateIntrinsicContentSize()
        var ancestor = superview
        while let view = ancestor {
            if let row = view as? TranscriptHostedRowContent { row.invalidateIntrinsicContentSize(); break }
            ancestor = view.superview
        }
    }
    /// One closed card's height at this width, measured once for the turn.
    private func closedRowHeight(width: CGFloat) -> CGFloat {
        if let known = closedHeight[width] { return known }
        guard let sample = rows.first(where: { !$0.item.open }) else { return 0 }
        let height = sample.measure(width: width)
        closedHeight[width] = height
        return height
    }

    private func exactLayout(width: CGFloat) -> Layout {
        if let cached = layouts.last(where: { $0.width == width }) { return cached }
        let closed = closedRowHeight(width: width)
        var heights: [CGFloat] = []
        heights.reserveCapacity(rows.count)
        for row in rows {
            if row.item.open { heights.append(row.measure(width: width)) }
            else if let own = row.ownHeight, own.width == width { heights.append(own.height) }
            else { heights.append(row.measured(width: width) ?? closed) }
        }
        let layout = Layout(width: width, heights: heights, total: heights.reduce(0, +))
        if layouts.count == 4 { layouts.removeFirst() }
        layouts.append(layout)
        return layout
    }
    func measure(width proposed: CGFloat?) -> CGSize {
        if proposed == 0 { return .zero }
        let width = proposed.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? (bounds.width > 0 ? bounds.width : TranscriptMetrics.pageWidth)
        return CGSize(width: width, height: exactLayout(width: width).total)
    }
    override func layout() {
        super.layout()
        guard bounds.width > 0, !applyingLayout else { return }
        applyingLayout = true
        defer { applyingLayout = false }
        if laidOutWidth != bounds.width {
            let layout = exactLayout(width: bounds.width)
            var y: CGFloat = 0
            for (index, row) in rows.enumerated() {
                row.frame = CGRect(x: 0, y: y, width: bounds.width, height: layout.heights[index])
                y += layout.heights[index]
            }
            laidOutWidth = bounds.width
        }
        bindViewport()
        mountVisibleRows()
    }
    /// The list moved inside the row it is drawn in (a section above it
    /// opened or closed): other cards, and other lines of the open ones,
    /// are in view now.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let moved = newOrigin != frame.origin
        super.setFrameOrigin(newOrigin)
        guard moved, laidOutWidth != nil else { return }
        mountVisibleRows()
        for row in rows { if let view = row.built, view.superview === self { view.refreshVisibleLines() } }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        bindViewport()
        mountVisibleRows()
    }
    private func bindViewport() {
        let clip = enclosingScrollView?.contentView
        guard observedClip !== clip else { return }
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil; observedClip = clip
        guard let clip else { return }
        clip.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mountVisibleRows() }
        }
    }
    private func containsSelection(_ row: NativeWorkListRowHost) -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        guard let view = row.built else { return false }
        if responder === view || responder.isDescendant(of: view) { return true }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let owner = editor.delegate as? NSView {
            return owner === view || owner.isDescendant(of: view)
        }
        return false
    }
    private func mountVisibleRows() {
        guard laidOutWidth != nil else { return }
        let viewport: CGRect
        if let clip = observedClip {
            viewport = convert(clip.bounds, from: clip)
        } else if window != nil {
            viewport = visibleRect
        } else {
            // An offscreen retained transcript row is detached as a whole.
            // Keep its data and exact sizes, but no native cards mounted.
            viewport = .null
        }
        let visible = viewport.isNull ? viewport : TranscriptNativeDocument.buffered(viewport)
        var corrected = false
        for row in rows {
            if (!visible.isNull && row.frame.intersects(visible)) || containsSelection(row) {
                row.place(in: self)
                // A closed card placed at the height every closed card shares
                // must actually be that tall. If this one is not, it keeps its
                // own height and the list is laid out again around it, so no
                // card is ever drawn outside the space it was given.
                if !row.item.open, row.ownHeight == nil, let width = laidOutWidth,
                   closedDisagreed.contains(width) || (closedChecks[width] ?? 0) < Self.closedCardChecks {
                    closedChecks[width, default: 0] += 1
                    let actual = row.measure(width: width)
                    if abs(actual - row.frame.height) > 0.5 {
                        row.ownHeight = (width, actual)
                        closedDisagreed.insert(width)
                        corrected = true
                    }
                }
            } else if let view = row.built, view.superview === self {
                view.removeFromSuperview()
            }
        }
        guard corrected else { return }
        layouts.removeAll(keepingCapacity: true)
        laidOutWidth = nil
        needsLayout = true
        invalidateIntrinsicContentSize()
    }
}
