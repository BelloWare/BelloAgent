import AppKit
import SwiftUI

/// AppKit owns the scrolling document. SwiftUI receives row content changes,
/// not a new document coordinate transform for every wheel/trackpad event.
struct TranscriptScrollSurface: NSViewRepresentable {
    let snapshot: TranscriptPage.Snapshot?
    let page: TranscriptPage
    let actions: TranscriptActions

    func makeNSView(context: Context) -> TranscriptNativeScrollView {
        let scroll = TranscriptNativeScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .none
        let document = TranscriptNativeDocument(page: page)
        scroll.documentView = document
        document.update(snapshot: snapshot, actions: actions, environment: TranscriptRowEnvironment(context.environment),
                        disclosure: page.disclosure, toolInputs: page.toolInputs)
        return scroll
    }

    func updateNSView(_ scroll: TranscriptNativeScrollView, context: Context) {
        (scroll.documentView as? TranscriptNativeDocument)?.update(snapshot: snapshot, actions: actions,
                                                                   environment: TranscriptRowEnvironment(context.environment),
                                                                   disclosure: page.disclosure, toolInputs: page.toolInputs)
    }
}

/// Where a key press moves a reader through a conversation.
enum TranscriptKeyScroll {
    case pageUp, pageDown, top, bottom
}

final class TranscriptNativeScrollView: NSScrollView {
    /// A Tab order can reach the conversation, so the keys below have
    /// somewhere to land even without the composer handing them on.
    override var acceptsFirstResponder: Bool { true }
    /// AppKit gives a scroll view that reaches the window's top edge a
    /// content inset for the titlebar, and takes it away the moment anything
    /// is put above it. Either way the reader must stay on the same line of
    /// text, so when the inset changes the clip view moves by the difference
    /// — unless the page is following the newest row, which places itself.
    override var contentInsets: NSEdgeInsets {
        didSet {
            let delta = contentInsets.top - oldValue.top
            guard abs(delta) > 0.5, !((documentView as? TranscriptNativeDocument)?.pageFollowsBottom ?? true) else { return }
            let clip = contentView
            let lowest = -contentInsets.top
            let highest = max(lowest, (documentView?.frame.height ?? 0) - clip.bounds.height + contentInsets.bottom)
            let target = min(max(lowest, clip.bounds.origin.y + delta), highest)
            guard abs(target - clip.bounds.origin.y) > 0.5 else { return }
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: target))
            reflectScrolledClipView(clip)
        }
    }
    /// Moves the reader the way the key they pressed says. Returns whether
    /// there was anywhere to go, so a key the conversation cannot use goes
    /// back to whoever sent it.
    @discardableResult func scroll(by move: TranscriptKeyScroll) -> Bool {
        let clip = contentView
        let lowest = -contentInsets.top
        let highest = max(lowest, (documentView?.frame.height ?? 0) - clip.bounds.height + contentInsets.bottom)
        // A page keeps a couple of lines of what was on screen, the way every
        // reader expects a page key to.
        let page = max(40, clip.bounds.height - 48)
        let target: CGFloat
        switch move {
        case .pageUp: target = clip.bounds.origin.y - page
        case .pageDown: target = clip.bounds.origin.y + page
        case .top: target = lowest
        case .bottom: target = highest
        }
        let clamped = min(max(lowest, target), highest)
        guard abs(clamped - clip.bounds.origin.y) > 0.5 else { return false }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: clamped))
        reflectScrolledClipView(clip)
        // The reader moved, so the page decides again whether it follows the
        // newest row — exactly as it does for a wheel or a trackpad.
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: self)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: self)
        return true
    }
    override func layout() {
        super.layout()
        (documentView as? TranscriptNativeDocument)?.layoutRows(width: contentSize.width)
    }
    // AppKit sends these to the whole hierarchy of a window or split view the
    // reader is dragging. The document measures less while the drag is running
    // and catches up the moment it stops.
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        (documentView as? TranscriptNativeDocument)?.beginLiveResize()
    }
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        (documentView as? TranscriptNativeDocument)?.endLiveResize()
    }
}

/// Retained native rows keep stable closures while their containing pane can
/// supply newer callbacks. Updating actions must not force a history walk or
/// rebuild a selected text field merely because another session refreshed.
@MainActor final class TranscriptActionRelay {
    var current = TranscriptActions()
    private(set) lazy var forwarded = TranscriptActions(
        inspect: { [weak self] in self?.current.inspect($0) },
        edit: { [weak self] in self?.current.edit($0) },
        copyMessage: { [weak self] in self?.current.copyMessage($0) },
        stop: { [weak self] in self?.current.stop() },
        retry: { [weak self] in self?.current.retry() }
    )
}

/// Exact row frames are retained independently of scroll offset. Row hosts
/// retain their SwiftUI disclosure and native selection state across updates.
@MainActor final class TranscriptNativeDocument: NSView {
    private weak var page: TranscriptPage?
    private let actionRelay = TranscriptActionRelay()
    private let geometryCache: TranscriptGeometryCache
    /// What the reader opened or closed, shared by every row of this chat.
    private var disclosure: TranscriptDisclosure?
    /// The full argument documents this chat has fetched.
    private var toolInputs: TranscriptToolInputs?
    private let marker = TranscriptSurfaceMarker()
    private let emptyLabel = NSTextField(labelWithString: "Ready for a conversation.")
    private var rows: [TranscriptRowContainer] = []
    private var snapshot: TranscriptPage.Snapshot?
    private var environment: TranscriptRowEnvironment?
    private var rowWidth: CGFloat = 0
    private var layoutPending = false
    private var visibilityPending = false
    private var layingOut = false
    private var dirty = true
    /// Rows still standing at the height they had at an earlier width. While
    /// the reader drags a pane's edge only the rows from the top of the page
    /// down to the bottom of the buffered viewport are measured again; the
    /// rest keep their height until the drag stops or the reader scrolls to
    /// them. Nothing in this set is ever mounted, so nothing draws at a height
    /// that is not its own.
    private var approximate: Set<String> = []
    /// The subset of those that have never been measured at all: a chat the
    /// reader has just opened, or a page of earlier rows just prepended. They
    /// stand at `TranscriptRowEstimate` until a slice reaches them.
    private var estimated: Set<String> = []
    /// How many rows beyond the buffered viewport the page has already
    /// measured. Each slice widens this, so the exact part of the page only
    /// ever grows and a slice never takes a measured row back to an estimate.
    private var grownRows = 0
    private var sliceScheduled = false
    /// The first row whose place in the page this layout has to work out
    /// again. Everything above it keeps the frame it already has, so a reply
    /// arriving at the end of a three-hundred-row chat moves one row and the
    /// rows under it, not every row of the page.
    private var dirtyFrom = 0
    /// The width the rows are currently placed at, so a pass knows whether
    /// the places it is reusing were worked out for this pane.
    private var placedWidth: CGFloat = 0
    /// Where the reader's window was last time, so the page can tell which
    /// way they are going and get the rows they are about to reach ready.
    private var lastViewportTop: CGFloat?
    /// When the conversation last changed, so slices can keep out of the way.
    private var contentChangedAt: TimeInterval = 0
    /// Set only for the pass a slice asked for. Any other pass — a delta, a
    /// scroll, a resize — measures what the reader can see and nothing more,
    /// so the history a long chat is still working through never lands on
    /// top of something the reader is waiting for.
    private var slicePass = false
    /// Set while the page is re-placing itself around estimates the reader has
    /// reached, so the pass does not recurse back into mounting.
    private var placingCorrection = false
    static let bufferCorrectionLimit = 8
    private var liveResizing = false
    private var resolvingApproximate = false
    private var resolveScheduled = false
    private var approximatedAt: TimeInterval = 0
    /// How long an approximate page may stand before it is measured anyway,
    /// for a drag whose end AppKit never reports.
    static let approximateGrace: TimeInterval = 0.2
    /// A page with more unmeasured rows than this is opened viewport first:
    /// the rows the reader is about to look at are measured now and the rest
    /// stand at an estimate. Below it a page is short enough to measure whole.
    static let sliceThreshold = 32
    /// How long one slice of a long chat may spend measuring. The reader can
    /// read and scroll between slices, so this is a frame's worth of work, not
    /// a whole page's.
    static let sliceBudget: TimeInterval = 0.008
    /// How much further out each slice reaches. Rows inside the buffered
    /// viewport are always measured; this is what a slice adds beyond it.
    static let sliceReach = 24
    /// How far past the buffered viewport a row keeps its SwiftUI tree.
    /// Beyond it the tree goes and the row keeps only what it is and how tall
    /// it is, so a page of any length — and a chat the reader leaves — holds
    /// a bounded number of them.
    static let hostReach: CGFloat = 3
    /// How many trees one quiet slice builds ahead of the reader, so a chat
    /// they are reading through has the next screenful ready before they
    /// reach it.
    static let hostsPerSlice = 6
    /// How far ahead of the reader, and how far behind, the page keeps the
    /// rows' trees ready, in screenfuls of the direction they are going.
    static let prepareAhead: CGFloat = 3
    static let prepareBehind: CGFloat = 1
    static let hostsPerViewportChange = 1
    /// How many it builds on one movement of the reader's window. A row
    /// lasts many wheel events, so one is enough to stay ahead of a
    /// continuous scroll, and one is small enough to fit in the frame it
    /// lands on.
    /// The gap between slices, so events and drawing get the main thread back.
    static let sliceInterval: TimeInterval = 0.004
    /// How long the slices stand aside after the conversation changes. While
    /// a reply is arriving the reader is watching the newest row, not the
    /// history behind it, so a streamed delta costs what its own row costs
    /// and the rest of the page waits for the next quiet moment.
    static let sliceQuietPeriod: TimeInterval = 0.15
    private weak var observedClip: NSClipView?
    nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?
    /// All exact rows stay retained; only the buffered viewport participates
    /// in AppKit drawing, cursor tracking and SwiftUI window updates.
    var retainedRows: [TranscriptRowContainer] { rows }
    /// Count actual native work independently of SwiftUI's parent updates.
    /// These do not publish view state; performance fixtures can distinguish
    /// content reconciliation from width/reflow and already cached geometry.
    private(set) var updateInvocationCount = 0
    private(set) var contentReconciliationCount = 0
    private(set) var layoutPassCount = 0
    private(set) var rowLayoutTraversalCount = 0
    /// How many row hosts this document has had to build. Creating one is a
    /// SwiftUI hosting view; opening a long chat must not build them all.
    private(set) var rowsBuiltCount = 0
    /// How many rows the last pass had to measure for real, and how wide the
    /// band it measured was. Evidence for the fixtures that hold an opening
    /// page to measuring only what it draws.
    private(set) var lastBandCount = 0
    /// How many passes placed only the part of the page below what changed.
    private(set) var partialPassCount = 0
    private(set) var estimatedEver = 0
    private(set) var correctionRounds = 0
    /// How many rows the last pass left standing at an earlier width or at an
    /// estimate.
    var approximateRowCount: Int { approximate.count }
    func isApproximate(_ id: String) -> Bool { approximate.contains(id) }
    /// Whether the page is following the newest row, for the scroll view
    /// deciding whether a content-inset change should move the reader.
    var pageFollowsBottom: Bool { page?.followsBottom ?? true }
    /// Which chat's rows the document currently holds, which lags the page's
    /// own binding by one SwiftUI update.
    var shownSessionID: String? { snapshot?.sessionID }
    /// How many rows are holding a SwiftUI tree. A long chat must keep this
    /// near the size of the viewport however many rows it has.
    var hostedRowCount: Int { rows.reduce(0) { $0 + ($1.isHosted ? 1 : 0) } }
    /// How many rows are still standing at an estimate because the reader has
    /// not been near them since the chat opened.
    var estimatedRowCount: Int { estimated.count }
    func isEstimated(_ id: String) -> Bool { estimated.contains(id) }
    override var isFlipped: Bool { true }

    init(page: TranscriptPage, geometryCache: TranscriptGeometryCache = .shared) {
        self.page = page
        self.geometryCache = geometryCache
        super.init(frame: .zero)
        marker.page = page
        marker.attach = { [weak page] scroll, host in page?.attach(scroll, host: host) }
        addSubview(marker)
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        addSubview(emptyLabel)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Conversation page")
    }
    required init?(coder: NSCoder) { nil }
    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        motionTimer?.invalidate()
    }

    func update(snapshot: TranscriptPage.Snapshot?, actions: TranscriptActions, environment: TranscriptRowEnvironment,
                disclosure: TranscriptDisclosure? = nil, toolInputs: TranscriptToolInputs? = nil) {
        let clock = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        defer { if TranscriptLayoutClock.recording { TranscriptLayoutClock.updateSeconds += TranscriptLayoutClock.now - clock } }
        updateInvocationCount += 1
        actionRelay.current = actions
        if let disclosure, self.disclosure !== disclosure { self.disclosure = disclosure }
        if let toolInputs, self.toolInputs !== toolInputs { self.toolInputs = toolInputs }
        // TranscriptPage owns this monotonically increasing revision. Avoid
        // deep equality and rebuilding the full row dictionary when SwiftUI
        // repaints an unchanged transcript for surrounding workspace state.
        // Environment and independent native intrinsic-size/width updates
        // still reach every affected row through their own paths.
        guard self.snapshot?.sessionID != snapshot?.sessionID || self.snapshot?.sequence != snapshot?.sequence || self.environment != environment else { return }
        contentReconciliationCount += 1
        contentChangedAt = ProcessInfo.processInfo.systemUptime
        // A reply arriving while a disclosure is moving lands on the geometry
        // the click measured: the motion finishes first, so the reader's row
        // is never placed from two sets of geometry at once.
        finishDisclosureMotion()
        // A different rendering environment changes every row's height.
        if self.environment != environment { dirtyFrom = 0 }
        if self.snapshot?.sessionID != snapshot?.sessionID {
            for row in rows { row.onHeightInvalidated = nil; row.onHeightValidated = nil; row.removeFromSuperview(); page?.rowGone(row.itemID) }
            rows = []
            // Another chat measures itself from its own viewport outward.
            // Its stores and the actions the pane made for it were adopted
            // above, so the ones the chat before it had are already gone.
            approximate = []; estimated = []; grownRows = 0; dirtyFrom = 0; placedWidth = 0; lastViewportTop = nil
        }
        self.snapshot = snapshot
        self.environment = environment
        // A chat the reader left keeps nothing; rows that left drop their parts.
        // Walking every id of the page is only worth doing when the reader has
        // actually opened or closed something, which is most often not the case.
        if let disclosure, disclosure.changedCount > 0, let items = snapshot?.items {
            let live = Set(items.flatMap { item -> [String] in
                switch item {
                case .message(let message): return [message.id] + (message.tools ?? []).map(\.id)
                case .block(let block):
                    return [block.key, block.id] + block.tools.map(\.id) + block.replies.flatMap { [$0.id] + ($0.tools ?? []).map(\.id) }
                }
            })
            disclosure.forget(disclosure.changedIDs.subtracting(live))
        }
        if let toolInputs, toolInputs.count > 0, let items = snapshot?.items {
            let live = Set(items.flatMap { item -> [String] in
                switch item {
                case .message(let message): return (message.tools ?? []).map(\.id)
                case .block(let block): return block.tools.map(\.id) + block.replies.flatMap { ($0.tools ?? []).map(\.id) }
                }
            })
            toolInputs.forget(toolInputs.knownIDs.subtracting(live))
        }
        let items = snapshot?.items ?? []
        let previous = rows
        // Where this snapshot first differs from the one the page is placed
        // at: a row that is a different row than it was, or the same row with
        // different content. Everything above keeps its place.
        var changedFrom = items.count == previous.count ? items.count : min(items.count, previous.count)
        var retained = Dictionary(uniqueKeysWithValues: rows.map { ($0.itemID, $0) })
        rows = items.enumerated().map { index, item in
            let fresh: Bool
            if case .block(let block) = item {
                let ids = snapshot?.fresh ?? []
                fresh = block.message.map { ids.contains($0.id) } ?? block.activity.contains { ids.contains($0.id) }
            } else { fresh = false }
            if let row = retained.removeValue(forKey: item.id) {
                if row.update(item: item, fresh: fresh, actions: actionRelay.forwarded, environment: environment) {
                    changedFrom = min(changedFrom, index)
                }
                if previous.indices.contains(index), previous[index] !== row { changedFrom = min(changedFrom, index) }
                row.layoutIndex = index
                return row
            }
            changedFrom = min(changedFrom, index)
            rowsBuiltCount += 1
            let row = TranscriptRowContainer(item: item, fresh: fresh, actions: actionRelay.forwarded, environment: environment,
                                             geometryCache: geometryCache, geometrySessionID: snapshot?.sessionID, disclosure: disclosure,
                                             toolInputs: toolInputs)
            row.onToolInputNeeded = { [weak self] messageID, callID in
                self?.page?.requestToolInput(messageID: messageID, callID: callID)
            }
            row.onHeightInvalidated = { [weak self, weak row] in
                if let row { self?.markDirty(from: row.layoutIndex) }
                self?.scheduleLayout()
            }
            row.onHeightValidated = { [weak self] in self?.scheduleVisibilityUpdate() }
            // Opening or closing part of a row is a direct answer to a click.
            row.onDisclosureChanged = { [weak self, weak row] in
                guard let self, let row else { return }
                self.disclosureChanged(row)
            }
            // An immutable warm row can borrow its exact baseline while still
            // detached. Cache misses mount for native measurement in layoutRows.
            row.layoutIndex = index
            return row
        }
        for row in retained.values { row.onHeightInvalidated = nil; row.onHeightValidated = nil; row.removeFromSuperview(); page?.rowGone(row.itemID) }
        markDirty(from: changedFrom)
        scheduleLayout()
    }

    /// The reader started dragging a pane's edge.
    func beginLiveResize() { liveResizing = true }
    /// The drag stopped: every row the page left standing is measured now.
    func endLiveResize() {
        liveResizing = false
        resolveApproximateRows()
    }
    /// Measure every row the page left standing, however long it takes. This
    /// is what the end of a pane drag asks for: the reader has stopped moving
    /// the edge and the whole page must be exact again.
    func resolveApproximateRows() {
        guard !approximate.isEmpty, !layingOut, !resolvingApproximate else { return }
        resolvingApproximate = true
        defer { resolvingApproximate = false }
        layoutNow()
    }
    /// The next slice of a long chat the reader has just opened: a frame's
    /// worth of measuring, further out than the last slice reached.
    private func scheduleSlice() {
        guard !sliceScheduled else { return }
        sliceScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sliceInterval) { [weak self] in
            guard let self else { return }
            self.sliceScheduled = false
            guard self.window != nil, !self.liveResizing else { return }
            guard ProcessInfo.processInfo.systemUptime - self.contentChangedAt >= Self.sliceQuietPeriod else {
                self.scheduleSlice(); return
            }
            if self.prepareHostsAheadOfTheReader(limit: Self.hostsPerSlice) { self.scheduleSlice() }
            guard !self.estimated.isEmpty else { return }
            self.grownRows += Self.sliceReach
            self.slicePass = true
            self.layoutNow()
            self.slicePass = false
        }
    }
    private func scheduleApproximateResolve() {
        guard !resolveScheduled else { return }
        resolveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.approximateGrace) { [weak self] in
            guard let self else { return }
            self.resolveScheduled = false
            guard !self.approximate.isEmpty else { return }
            // Still moving: wait for the drag to settle rather than measuring
            // a width the reader is about to leave.
            guard Date().timeIntervalSinceReferenceDate - self.approximatedAt >= Self.approximateGrace else {
                self.scheduleApproximateResolve(); return
            }
            self.resolveApproximateRows()
        }
    }

    /// From this row down the page has to be placed again.
    private func markDirty(from index: Int) { dirtyFrom = min(dirtyFrom, max(0, index)) }

    // MARK: Moving a disclosure

    /// A disclosure the reader has just clicked. The click measures the
    /// page's new geometry exactly, as it always did; this then moves the
    /// rows from where they were to where they belong. Every tick is frame
    /// changes: no row is measured, no tree is rebuilt, nothing is asked of
    /// SwiftUI — the row that is changing keeps its tree at the height it was
    /// measured at and clips to the frame the motion is interpolating.
    private struct DisclosureMotion {
        var index: Int
        /// Where every row from the changed one down sat when it began, so a
        /// tick is an addition rather than a walk back through the page.
        var startOrigins: [CGFloat]
        var fromHeight: CGFloat
        var toHeight: CGFloat
        var fromDocument: CGFloat
        var toDocument: CGFloat
        var opening: Bool
        var started: TimeInterval
        var duration: TimeInterval
    }
    private var motion: DisclosureMotion?
    /// Set while the pass that measures a disclosure's target geometry runs,
    /// so the rows the motion will move past stay on screen for it.
    private var preparingMotion = false
    nonisolated(unsafe) private var motionTimer: Timer?
    /// How many ticks the last motion took and what they cost, as evidence
    /// that a tick is frame changes and nothing else.
    private(set) var motionTickCount = 0
    private(set) var motionTickSeconds = 0.0
    /// Whether a disclosure is moving right now.
    var isMovingDisclosure: Bool { motion != nil }
    static var disclosureMotionDuration: TimeInterval { Double(PiMotion.baseMilliseconds) / 1_000 }
    /// Whether a disclosure snaps rather than moves. The reader's Reduce
    /// Motion setting decides it; a fixture overrides it to check both.
    static var reducesMotionOverride: Bool?
    static var reducesMotion: Bool { reducesMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func disclosureChanged(_ row: TranscriptRowContainer) {
        markDirty(from: row.layoutIndex)
        guard !Self.reducesMotion, enclosingScrollView != nil, !rows.isEmpty,
              let index = rows.firstIndex(where: { $0 === row }) else {
            finishDisclosureMotion(settling: false)
            layoutNow()
            return
        }
        // Where the page is right now — which, for a second click part way
        // through, is where the last motion had got to. Nothing snaps.
        let startOrigins = rows[index...].map(\.frame.minY)
        let fromHeight = row.frame.height
        let fromDocument = frame.height
        motion = nil
        stopMotionTimer()
        row.endDisclosureMotion()
        preparingMotion = true
        layoutNow()
        preparingMotion = false
        let toHeight = row.frame.height
        guard abs(toHeight - fromHeight) > 1 else { return }
        motion = DisclosureMotion(index: index, startOrigins: startOrigins, fromHeight: fromHeight, toHeight: toHeight,
                                  fromDocument: fromDocument, toDocument: frame.height, opening: toHeight > fromHeight,
                                  started: ProcessInfo.processInfo.systemUptime, duration: Self.disclosureMotionDuration)
        motionTickCount = 0; motionTickSeconds = 0
        row.beginDisclosureMotion(contentHeight: max(fromHeight, toHeight), keepingContentPlaced: toHeight < fromHeight)
        advanceDisclosureMotion(to: 0)
        startMotionTimer()
    }

    /// Moves the page to this point on the curve. The app's tick calls it
    /// with the elapsed fraction; a fixture calls it directly to look at the
    /// page part way through.
    func advanceDisclosureMotion(to fraction: Double) {
        guard let motion, motion.index < rows.count else { return }
        let started = ProcessInfo.processInfo.systemUptime
        let clamped = min(1, max(0, fraction))
        // The state-change ease: out, so it leaves at once and arrives gently.
        let t = 1 - pow(1 - clamped, 3)
        let height = motion.fromHeight + (motion.toHeight - motion.fromHeight) * t
        let shift = height - motion.fromHeight
        for offset in motion.index..<min(rows.count, motion.index + motion.startOrigins.count) {
            let row = rows[offset]
            let start = motion.startOrigins[offset - motion.index]
            let rect = offset == motion.index
                ? CGRect(x: row.frame.minX, y: start, width: row.frame.width, height: max(1, height))
                : CGRect(x: row.frame.minX, y: start + shift, width: row.frame.width, height: row.frame.height)
            if row.frame != rect { row.frame = rect }
        }
        let documentHeight = motion.fromDocument + (motion.toDocument - motion.fromDocument) * t
        if abs(frame.height - documentHeight) > 0.5 { setFrameSize(CGSize(width: frame.width, height: documentHeight)) }
        // What the two states do not share goes over the first third of the
        // motion and arrives over the last two thirds, so neither end of any
        // disclosure is a jump.
        rows[motion.index].setDisclosureReveal(keeping: min(motion.fromHeight, motion.toHeight),
                                               fade: motion.opening ? min(1, max(0, (clamped - 1.0 / 3) * 1.5))
                                                                    : min(1, max(0, 1 - clamped * 3)))
        // The scroll bar follows the document as it moves rather than
        // jumping to its new size at the end.
        if let scroll = enclosingScrollView {
            page?.contentChanged(ContentGeometry(top: -scroll.contentView.bounds.minY, height: documentHeight))
        }
        motionTickCount += 1
        motionTickSeconds += ProcessInfo.processInfo.systemUptime - started
        if clamped >= 1 { finishDisclosureMotion(settling: true) }
    }

    /// Ends the motion on the geometry the click measured.
    func finishDisclosureMotion(settling: Bool = true) {
        guard let motion else { return }
        self.motion = nil
        stopMotionTimer()
        if motion.index < rows.count { rows[motion.index].endDisclosureMotion() }
        guard settling else { return }
        markDirty(from: motion.index)
        dirty = true
        if let scroll = enclosingScrollView { layoutRows(width: scroll.contentSize.width) }
    }

    private func startMotionTimer() {
        stopMotionTimer()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let motion = self.motion else { return }
                self.advanceDisclosureMotion(to: (ProcessInfo.processInfo.systemUptime - motion.started) / motion.duration)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
    }
    private func stopMotionTimer() { motionTimer?.invalidate(); motionTimer = nil }
    /// Lays out now, for a change the reader just made and is looking at.
    func layoutNow() {
        dirty = true
        guard let scroll = enclosingScrollView else { return }
        layoutRows(width: scroll.contentSize.width)
    }

    private func scheduleLayout() {
        dirty = true
        guard !layoutPending else { return }
        layoutPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutPending = false
            guard let scroll = self.enclosingScrollView else { return }
            self.layoutRows(width: scroll.contentSize.width)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        marker.locate()
        observeViewport()
        scheduleLayout()
    }

    private func observeViewport() {
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

    private func scheduleVisibilityUpdate() {
        guard !visibilityPending else { return }
        visibilityPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.visibilityPending = false
            self.mountVisibleRows()
        }
    }

    private func mountVisibleRows() {
        guard !layingOut, let clip = enclosingScrollView?.contentView else { return }
        let clock = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        defer { if TranscriptLayoutClock.recording { TranscriptLayoutClock.mountSeconds += TranscriptLayoutClock.now - clock } }
        var buffered = clip.bounds.insetBy(dx: 0, dy: -max(240, clip.bounds.height / 2))
        let selected = rowOwningFirstResponder()
        // The reader scrolled into a part of the page that was left standing
        // at an earlier width: measure it before any of it is drawn. A row
        // standing at an earlier width is only exact again once the whole page
        // is; a row standing at an estimate needs no more than the passes that
        // place it.
        if !approximate.isEmpty,
           rows.contains(where: { approximate.contains($0.itemID) && !estimated.contains($0.itemID) && Self.overlaps($0.frame, buffered) }) {
            resolveApproximateRows()
            return
        }
        // No estimate is ever drawn: a row standing at one that the reader has
        // reached is measured now, whatever the slice budget says, and the page
        // placed again around it. Each round makes at least one more row exact,
        // so this settles; the limit only bounds a page of wild estimates.
        var rounds = 0
        while rounds < Self.bufferCorrectionLimit,
              rows.contains(where: { estimated.contains($0.itemID) && Self.overlaps($0.frame, buffered) }) {
            rounds += 1; correctionRounds += 1
            for row in rows where estimated.contains(row.itemID) && Self.overlaps(row.frame, buffered) {
                if row.superview == nil { addSubview(row) }
                _ = row.measure(width: rowWidth)
                estimated.remove(row.itemID); approximate.remove(row.itemID)
            }
            placingCorrection = true
            layoutNow()
            placingCorrection = false
            buffered = clip.bounds.insetBy(dx: 0, dy: -max(240, clip.bounds.height / 2))
        }
        var cold = false
        for row in rows {
            // A local disclosure can change height just before a scroll moves
            // it away: a row the reader has only just left finishes its
            // deferred native validation before detaching. A row the page
            // measured in a slice, pages away from the viewport, has nothing
            // on screen to finish and detaches at once.
            let nearby = Self.overlaps(row.frame, buffered.insetBy(dx: 0, dy: -buffered.height * Self.hostReach))
            let needed = Self.overlaps(row.frame, buffered) || row === selected
                || (row.superview != nil && row.needsMountedValidation && nearby)
            if needed, row.superview == nil {
                if TranscriptLayoutClock.recording { TranscriptLayoutClock.mountedRows += 1 }
                addSubview(row)
                row.prepareToDraw()
            }
            if needed, row.superview != nil, row.awaitingViewportLayout {
                // A row is laid out as it is mounted: that is what keeps the
                // frame after it cheap, and it is what makes scrolling smooth.
                rowLayoutTraversalCount += 1
                row.layoutForViewport()
            }
            if !needed, !preparingMotion, motion == nil {
                if row.superview != nil { row.removeFromSuperview() }
                if !nearby { row.releaseHost() }
                else if !row.isHosted { cold = true }
            }
        }
        // The reader is reading through a chat they have not seen before.
        // The rows they are about to reach get their trees built now, on the
        // movement of their window, rather than under the wheel event that
        // brings one into view — one per movement, which is all a continuous
        // scroll needs because a row lasts many of them.
        let more = prepareHostsAheadOfTheReader(limit: Self.hostsPerViewportChange)
        if cold || more { scheduleSlice() }
    }
    /// Builds the trees the reader is about to need, in the direction they
    /// are going. Returns whether any are left.
    @discardableResult private func prepareHostsAheadOfTheReader(limit: Int) -> Bool {
        guard limit > 0, let clip = enclosingScrollView?.contentView else { return false }
        let view = clip.bounds
        let travel = view.minY - (lastViewportTop ?? view.minY)
        lastViewportTop = view.minY
        // Going down, the rows below are the ones about to arrive; going up,
        // the rows above. Either way one screenful the other way stays ready
        // for a reader who changes their mind.
        let forward = travel >= 0
        let above = (forward ? Self.prepareBehind : Self.prepareAhead) * view.height
        let below = (forward ? Self.prepareAhead : Self.prepareBehind) * view.height
        let ready = CGRect(x: view.minX, y: view.minY - above, width: max(1, view.width), height: view.height + above + below)
        // The nearest row in the direction of travel is the one they reach
        // first, so it is the one that gets built first.
        let edge = forward ? view.maxY : view.minY
        var cold = rows.filter { !$0.isHosted && Self.overlaps($0.frame, ready) }
        guard !cold.isEmpty else { return false }
        if cold.count > limit {
            cold.sort { abs($0.frame.midY - edge) < abs($1.frame.midY - edge) }
        }
        for row in cold.prefix(limit) { row.prepareForTheReader() }
        return cold.count > limit
    }

    /// The rows this pass must measure for real: everything the reader can
    /// see where the page is parked now, everything they will see once this
    /// pass settles, and however far the slices have already reached beyond
    /// both. Working it out needs somewhere to put every row, so rows the page
    /// has not measured contribute their estimate — which is all this has to
    /// be, because every row it picks is then measured properly.
    private func exactBand(width: CGFloat, viewportHeight: CGFloat, parking: Bool) -> Set<Int> {
        guard !rows.isEmpty else { return [] }
        var tops: [CGFloat] = []
        tops.reserveCapacity(rows.count + 1)
        var y: CGFloat = 12
        for row in rows {
            tops.append(y)
            y += row.measuredHeight(width: width) ?? (row.neverMeasured ? row.estimatedHeight(width: width) : max(1, row.frame.height))
        }
        tops.append(y)
        let total = y + 13
        let buffer = max(240, viewportHeight / 2)
        let bottom = max(0, total - viewportHeight)
        var wanted: [CGFloat] = []
        if let anchor = page?.readingAnchorRow, let index = rows.firstIndex(where: { $0.itemID == anchor.id }) {
            wanted.append(tops[index] - CGFloat(anchor.offset))
        } else if page?.followsBottom ?? true {
            wanted.append(bottom)
        }
        // Where the page is parked right now counts too: until it has moved to
        // its opening position, that is what the reader is looking at. A pass
        // that is about to park the page has no such moment.
        if !parking { wanted.append(enclosingScrollView?.contentView.bounds.minY ?? 0) }
        var band: Set<Int> = []
        for want in wanted {
            let top = min(max(0, want), bottom)
            let low = top - buffer, high = top + viewportHeight + buffer
            var first = rows.count, last = -1
            for index in rows.indices where tops[index + 1] > low && tops[index] < high {
                first = min(first, index); last = max(last, index)
            }
            if first > last { continue }
            for index in max(0, first - grownRows)...min(rows.count - 1, last + grownRows) { band.insert(index) }
        }
        // A page whose estimates put every window off the end still measures
        // something: the rows at the parked position.
        if band.isEmpty { for index in 0..<min(rows.count, 12) { band.insert(index) } }
        return band
    }

    /// The row holding the reader's selection, found by walking up from the
    /// window's first responder. Asking each row instead walks the responder
    /// chain once per row, three hundred times a pass.
    private func rowOwningFirstResponder() -> TranscriptRowContainer? {
        guard var view = window?.firstResponder as? NSView else { return nil }
        // AppKit's shared field editor is attached to the window, not always
        // beneath its selectable NSTextField. Its delegate owns the selection.
        if let editor = view as? NSTextView, let field = editor.delegate as? NSView { view = field }
        var node: NSView? = view
        while let current = node {
            if let row = current as? TranscriptRowContainer { return row }
            node = current.superview
        }
        return nil
    }

    /// Whether a row at this rect would be inside the band AppKit draws from.
    /// A row the page has not placed yet has an empty frame, which is nowhere;
    /// `CGRect.intersects` is not the test for that, and only the vertical
    /// axis decides what the reader can see.
    static func overlaps(_ rect: CGRect, _ band: CGRect) -> Bool {
        rect.height > 0 && rect.maxY > band.minY && rect.minY < band.maxY
    }

    /// The row the reader is looking at and where it sits on the screen.
    private func heldReadingRow() -> (id: String, screenY: CGFloat)? {
        guard let scroll = enclosingScrollView, !(page?.isPlacingScroll ?? false) else { return nil }
        let offset = scroll.contentView.bounds.minY
        guard offset > 0.5, let row = rows.first(where: { $0.frame.maxY > offset }) else { return nil }
        return (row.itemID, row.frame.minY - offset)
    }
    /// Puts that row back on the same line of the screen. A slice measuring
    /// rows above the reader moves everything below it; without this the text
    /// they are reading would walk up the window while the page settles.
    private func restoreReadingRow(_ held: (id: String, screenY: CGFloat)?, contentHeight: CGFloat) {
        guard let held, let scroll = enclosingScrollView, !(page?.isPlacingScroll ?? false),
              let row = rows.first(where: { $0.itemID == held.id }) else { return }
        let clip = scroll.contentView
        let maximum = max(0, contentHeight - clip.bounds.height)
        let target = min(max(0, row.frame.minY - held.screenY), maximum)
        guard abs(target - clip.bounds.minY) > 0.5 else { return }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: target))
        scroll.reflectScrolledClipView(clip)
    }

    func layoutRows(width: CGFloat) {
        guard width.isFinite, width > 0, !layingOut else { return }
        let clock = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        defer { if TranscriptLayoutClock.recording { TranscriptLayoutClock.layoutSeconds += TranscriptLayoutClock.now - clock } }
        if let scroll = enclosingScrollView { page?.viewportChanged(scroll.contentView.bounds.size) }
        observeViewport()
        let nextWidth = max(1, min(TranscriptMetrics.pageWidth, width - 48))
        guard dirty || rowWidth != nextWidth || frame.width != width else { mountVisibleRows(); return }
        // A pass that places the rows again while a disclosure is moving
        // lands the motion first: two sets of geometry cannot both own them.
        if motion != nil, !placingCorrection { finishDisclosureMotion() }
        // A new width is a new band: how far the slices had reached at the
        // old one says nothing about how much of this one the reader can see.
        if rowWidth != nextWidth { grownRows = 0 }
        layoutPassCount += 1
        layingOut = true
        defer { layingOut = false; if !placingCorrection { mountVisibleRows() } }
        dirty = false
        page?.preserveReadingPositionForLayout()
        rowWidth = nextWidth
        let left = (width - nextWidth) / 2
        // Only the buffered viewport needs its native tree laid out now; a row
        // outside it lays out when the reader scrolls it back into the buffer.
        let buffered: CGRect? = enclosingScrollView.map { scroll in
            let bounds = scroll.contentView.bounds
            return bounds.insetBy(dx: 0, dy: -max(240, bounds.height / 2))
        }
        // While the reader drags a pane's edge, measure from the top of the
        // page down to the bottom of the viewport they will be looking at, and
        // leave the rows below standing where they are. Every row above and in
        // view is exact, so nothing they can see moves; the rest are measured
        // when the drag stops, or sooner if they scroll down to them.
        let selected = rowOwningFirstResponder()
        let deferring = liveResizing && !resolvingApproximate
        let anchor = deferring ? page?.readingAnchorRow : nil
        let viewportHeight = enclosingScrollView?.contentView.bounds.height ?? 0
        // A row can borrow an exact height another pane already measured, and
        // what the page still has to measure is decided after it has. A pane
        // drag is the exception: most of its rows stand at the height they
        // already have, so it restores a baseline where a row is about to be
        // measured and nowhere else.
        // Everything above the first row that changed is already where it
        // belongs, so a reply arriving at the end of a long chat places one
        // row and the rows under it. A pass that reflows, slices or leaves
        // rows standing has to work the whole page out again.
        let reusable = !deferring && approximate.isEmpty && estimated.isEmpty
            && placedWidth == nextWidth && frame.width == width && !rows.isEmpty && !resolvingApproximate
        let firstPlaced = reusable ? min(max(0, dirtyFrom), rows.count) : 0
        let scale = window?.backingScaleFactor
        if !deferring, let scale {
            for index in firstPlaced..<rows.count { rows[index].restoreSharedMeasurement(width: nextWidth, backingScale: scale) }
        }
        // Opening a long chat: measure the rows the reader is about to look at
        // and stand the rest at an estimate, then widen that band a slice at a
        // time. Nothing standing is ever in the view tree, so no estimate is
        // ever drawn.
        // Rows this pass would otherwise have to measure: a chat just opened
        // has never measured any of them, a pane that changed width has
        // measured them all at another one. Either way the reader can only
        // see a screenful, and the rest can stand until a slice reaches them.
        let unmeasured = firstPlaced > 0 ? 0 : rows.reduce(0) { $0 + ($1.hasMeasurement(width: nextWidth) ? 0 : 1) }
        let slicing = unmeasured > Self.sliceThreshold && !resolvingApproximate && !deferring && firstPlaced == 0
        // A long chat that opens at its newest row is parked there by this very
        // pass, so it need not also measure the top of the history the reader
        // would otherwise see for one frame.
        let parking = slicing && (page?.followsBottom ?? false) && !(page?.isPlacingScroll ?? false)
            && (enclosingScrollView?.contentView.bounds.minY ?? 0) <= 0.5
        let band = slicing ? exactBand(width: nextWidth, viewportHeight: viewportHeight, parking: parking) : nil
        lastBandCount = band?.count ?? rows.count
        // Where the reader's row sits now, so a slice that measures the rows
        // above it can put it back on the same line of the screen.
        let held = slicing ? heldReadingRow() : nil
        let sliceStarted = ProcessInfo.processInfo.systemUptime
        var spent = !slicePass
        let loopClock = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        var exactUntil = CGFloat.greatestFiniteMagnitude
        var standing: Set<String> = []
        var guesses: Set<String> = []
        var y: CGFloat = firstPlaced > 0 ? rows[firstPlaced - 1].frame.maxY : 12
        partialPassCount += firstPlaced > 0 ? 1 : 0
        for index in firstPlaced..<rows.count {
            let row = rows[index]
            if let anchor, row.itemID == anchor.id {
                // Where the reader's window lands once this pass settles, and
                // never less than the buffer AppKit is mounting from right now.
                let projected = (y - CGFloat(anchor.offset)) + viewportHeight + max(240, viewportHeight / 2)
                exactUntil = max(projected, buffered?.maxY ?? 0)
            }
            // A row may stand at its old height only when it is out of sight
            // both where it is now and where this pass would put it, and holds
            // no selection. Nothing standing stays in the view tree, so AppKit
            // can never draw one at a height that is not its own.
            let outOfSight = !(buffered.map { Self.overlaps(row.frame, $0) } ?? true)
            if deferring, y > exactUntil, outOfSight, row.frame.height > 0,
               !row.hasMeasurement(width: nextWidth), row !== selected {
                if row.superview != nil { row.removeFromSuperview() }
                standing.insert(row.itemID)
                let rect = CGRect(x: left, y: y, width: nextWidth, height: row.frame.height)
                if row.frame != rect { row.frame = rect }
                page?.rowFrame(row.itemID, rect)
                y += rect.height
                continue
            }
            if let band, !row.hasMeasurement(width: nextWidth), !band.contains(index), row !== selected {
                // Outside the band the reader can reach, this slice measures
                // what it has time for. A row it leaves stands at the height
                // it already had, or at an estimate if it has never had one.
                let standingHeight = row.neverMeasured ? row.estimatedHeight(width: nextWidth) : max(1, row.frame.height)
                let rect = CGRect(x: left, y: y, width: nextWidth, height: standingHeight)
                // Neither where it stands now nor where this pass would put it
                // may be anywhere AppKit could draw it from.
                let hidden = !(buffered.map { Self.overlaps(row.frame, $0) || Self.overlaps(rect, $0) } ?? true)
                if hidden, spent || ProcessInfo.processInfo.systemUptime - sliceStarted > Self.sliceBudget {
                    spent = true
                    if row.superview != nil { row.removeFromSuperview() }
                    standing.insert(row.itemID); guesses.insert(row.itemID)
                    if row.frame != rect { row.frame = rect }
                    page?.rowFrame(row.itemID, rect)
                    y += rect.height
                    continue
                }
            }
            if deferring, let scale { row.restoreSharedMeasurement(width: nextWidth, backingScale: scale) }
            // Changed offscreen content and width reflows need the same window
            // metrics as visible rows. Cached rows need no mounting to measure.
            if !row.hasMeasurement(width: nextWidth), row.superview == nil { addSubview(row) }
            let size = row.measure(width: nextWidth)
            let rect = CGRect(x: left, y: y, width: nextWidth, height: size.height)
            if row.frame != rect { row.frame = rect }
            // Exact geometry is cached even for detached history. Traversing
            // all of those native text trees on each streaming-tail update
            // defeats viewport culling. Changed content/width was mounted for
            // measurement above; a row outside the buffered viewport lays its
            // tree out when the reader scrolls it back, not on every reflow.
            if row.superview != nil, buffered.map(rect.intersects) ?? true {
                rowLayoutTraversalCount += 1
                row.layoutForViewport()
            }
            page?.rowFrame(row.itemID, rect)
            y += size.height
        }
        if TranscriptLayoutClock.recording { TranscriptLayoutClock.rowLoopSeconds += TranscriptLayoutClock.now - loopClock }
        dirtyFrom = rows.count
        placedWidth = nextWidth
        approximate = standing
        estimated = guesses
        estimatedEver += guesses.count
        if !standing.subtracting(guesses).isEmpty {
            approximatedAt = Date().timeIntervalSinceReferenceDate
            scheduleApproximateResolve()
        }
        if !guesses.isEmpty { scheduleSlice() }
        emptyLabel.isHidden = !rows.isEmpty
        if rows.isEmpty {
            emptyLabel.frame = CGRect(x: left, y: 40, width: nextWidth, height: 22)
            y = 74
        }
        let size = CGSize(width: width, height: y + 13)
        if frame.size != size { setFrameSize(size) }
        restoreReadingRow(held, contentHeight: size.height)
        // A long chat that opens at its newest row is parked there before
        // anything is drawn. Otherwise the reader sees the top of the history
        // for a frame and the page has to measure both ends of it.
        if parking, let scroll = enclosingScrollView {
            let clip = scroll.contentView
            let bottom = max(0, size.height - clip.bounds.height)
            if clip.bounds.minY < bottom - 0.5 {
                clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: bottom))
                scroll.reflectScrolledClipView(clip)
            }
        }
        if let scroll = enclosingScrollView {
            page?.viewportChanged(scroll.contentView.bounds.size)
            page?.contentChanged(ContentGeometry(top: -scroll.contentView.bounds.minY, height: size.height))
        }
        marker.locate()
    }
}
