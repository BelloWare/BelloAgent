import SwiftUI
import AppKit
import Combine

// The conversation page, drawn natively. The page follows the newest message
// until the reader scrolls away, keeps the reader's place across chat
// switches and earlier pages, asks for the page before the first row as the
// reader nears the top, and acknowledges a reply only once its end has
// actually been on screen in a key, visible window.
//
// AppKit owns both the exact document geometry and the reader's scroll offset.
// SwiftUI renders independent rows without observing every scroll transform.

struct ContentGeometry: Equatable {
    var top: CGFloat
    var height: CGFloat
}

/// Holds one session's page: the rows on display, the live turn, and where the
/// reader is. The view reads its published state; the geometry callbacks, the
/// scroll view's notifications and the session's transcript stream drive it.
@MainActor final class TranscriptPage: ObservableObject {
    /// The newest rows that fit: up to 500 messages and about 4 MB of text.
    nonisolated static let rowLimit = 500
    nonisolated static let byteLimit = 4_000_000
    /// The bottom band. The page follows the newest row only while the reader
    /// is standing inside it; leaving it unpins the page and coming back
    /// re-pins it. It is deliberately narrow — a reader a line and a half off
    /// the end has stopped following, and a page that kept dragging them back
    /// from there is the thing this band exists to stop.
    static let followThreshold: CGFloat = 24
    /// Within this many points of the top the page asks for the earlier page.
    static let earlierThreshold: CGFloat = 240

    struct Snapshot: Equatable {
        var sessionID: String
        var generation: UUID? = nil
        var messages: [TranscriptMessage]
        var items: [TranscriptItem]
        var fresh: Set<String>
        var sequence: Int
        var lifecycle: TaskPresentationProjection? = nil
        var liveTurn: TurnSummary? = nil
        /// The page ends with a message the reader has sent that the helper
        /// has not shown yet.
        var sending = false
    }

    @Published private(set) var snapshot: Snapshot?
    @Published var projectionError: String?
    var liveTurn: TurnSummary? {
        if let turn = snapshot?.liveTurn { return turn }
        // Older helpers and the brief pre-snapshot phase only report run state.
        // Keep activity visible without borrowing historical usage or claiming
        // a task completion. A message just sent starts its turn in that same
        // phase, before the helper's first presentation of it arrives.
        guard snapshot?.lifecycle?.active == nil, snapshot?.lifecycle?.recent.isEmpty != false || snapshot?.sending == true else { return nil }
        return Self.liveTurn(in: [], busy: busy)
    }
    @Published private(set) var detached = false
    /// Whether the reader is standing in the bottom band right now. The Back
    /// to bottom pill is shown whenever they are not — which is the same
    /// question as whether the page is following, asked of the geometry
    /// rather than of the page's intentions, so the pill can never disagree
    /// with what the reader can see.
    @Published private(set) var atBottom = true
    /// Set when the page has stopped asking for earlier rows on its own: its
    /// rows do not reach past the viewport, and it has already filled it as
    /// often as it may. From here the reader asks, at the top edge.
    @Published private(set) var earlierWaitsForReader = false
    /// What `earlierWaitsForReader` is about to become. It is decided inside
    /// the document's layout, where the page must not publish, so it is
    /// published a turn of the run loop later.
    private var earlierWaits = false {
        didSet {
            guard earlierWaits != oldValue else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.earlierWaitsForReader != self.earlierWaits else { return }
                self.earlierWaitsForReader = self.earlierWaits
            }
        }
    }
    @Published var state = "idle"
    var busy: Bool { ["queued", "running", "stopping", "compacting"].contains(state) }

    var onAnchorChanged: (TranscriptAnchor?) -> Void = { _ in }
    var onReadReply: (String, String) -> Void = { _, _ in }
    var onLoadEarlier: (String) -> Void = { _ in }
    var onViewportReady: (String, UUID) -> Void = { _, _ in }

    private var subscription: AnyCancellable?
    private var pendingPresentation: (input: TranscriptPresentationInput, request: Int)?
    private var presentationTask: Task<Void, Never>?
    private weak var presentationSession: SessionDisplay?
    private var lastPresentationAt: TimeInterval = 0
    var pendingPresentationCount: Int { presentationTask == nil ? 0 : 1 }
    /// Internal benchmark seam: zero measures every input delta separately.
    var presentationInterval: TimeInterval = 1 / 30

    private(set) var sessionID: String?
    private(set) var generation: UUID?
    /// The bound session's disclosure store, used by the native document.
    private(set) var disclosure: TranscriptDisclosure?
    /// The bound session's fetched tool-argument documents.
    private(set) var toolInputs: TranscriptToolInputs?
    private var viewportRequest: Int?
    private var initialized = false
    private(set) var followsBottom = true { didSet { syncReadingOwnership() } }
    private var readerNavigationStarted = false
    private var viewportResizePending = false
    private var upwardNavigation = false
    private var explicitDestination = false
    private var pendingAnchor: TranscriptAnchor? { didSet {
        pendingAnchorRow = nil
        if pendingAnchor == nil { explicitDestination = false }
        syncReadingOwnership()
    } }
    /// Whether the page is placing the reader itself: following the newest
    /// row, landing a destination they asked for, or holding the question
    /// this chat opened at. While it is, the pane's own reading correction
    /// stands aside — two things correcting the same clip view fight each
    /// other, and it is the page's placement the reader asked for.
    private var pagePlacesItself: Bool { followsBottom || explicitDestination || openingReadingAnchor != nil }
    private func syncReadingOwnership() { scrollView?.transcriptReading.following = pagePlacesItself }

    /// Which row holds the pending anchor, worked out once. Resolving it for
    /// every row of the page as its frame arrives is quadratic in the page,
    /// and every row's frame arrives on every reflow.
    private var pendingAnchorRow: String?
    /// A chat opened while idle starts at its last question when the last turn does not fit above the bottom.
    private var openingPlacementPending = false
    private var openingReadingAnchor: TranscriptAnchor? { didSet { syncReadingOwnership() } }
    private var seen: Set<String> = []
    private var completedAssistant: String?
    private var firstRow = ""
    private var jumping = false
    private var sequence = 0
    /// Row frames relative to the content, so they stay valid while the page scrolls.
    private var frames: [String: CGRect] = [:]
    private var content = ContentGeometry(top: 0, height: 0)
    private var viewport = CGSize.zero
    private weak var scrollView: NSScrollView?
    private weak var hostView: NSView?
    private var reportTask: Task<Void, Never>?
    private var freshTask: Task<Void, Never>?
    private var completionBaselineAt = Date().timeIntervalSince1970 * 1000
    var announceCompletion: () -> Void = { AccessibilityNotification.Announcement("Task complete").post() }
    /// How long a row that has just arrived wears its settling accent.
    static let freshDuration = Duration.milliseconds(1_500)
    private var readCheckScheduled = false
    private var settleScheduled = false
    nonisolated(unsafe) private var flushLink: CADisplayLink?
    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var scrollObservers: [NSObjectProtocol] = []

    init() {
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didEndSheetNotification, TranscriptReadVisibility.didRestoreNativeView] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestReadCheck() }
            })
        }
    }
    deinit {
        for observer in windowObservers + scrollObservers { NotificationCenter.default.removeObserver(observer) }
        freshTask?.cancel(); reportTask?.cancel(); presentationTask?.cancel()
        flushLink?.invalidate()
    }

    // MARK: Where the reader is

    /// The reader's position as AppKit has it now; reported geometry stands in before attachment.
    private struct Position { var offset: CGFloat; var height: CGFloat; var viewport: CGFloat }
    private var position: Position {
        if let scrollView, let document = scrollView.documentView {
            let clip = scrollView.contentView
            let offset = document.isFlipped ? clip.bounds.origin.y : document.frame.height - clip.bounds.height - clip.bounds.origin.y
            return Position(offset: offset, height: max(document.frame.height, content.height), viewport: clip.bounds.height)
        }
        return Position(offset: -content.top, height: content.height, viewport: viewport.height)
    }
    var scrollY: CGFloat { position.offset }
    var distanceToBottom: CGFloat { let p = position; return p.height - p.viewport - p.offset }

    // MARK: Session binding

    func bind(_ session: SessionDisplay) {
        guard sessionID != session.id || generation != session.presentationGeneration else { return }
        subscription?.cancel(); subscription = nil
        presentationTask?.cancel(); presentationTask = nil; pendingPresentation = nil
        stopFlushLink(); heldSince = nil
        presentationSession = session; lastPresentationAt = 0; lastReportedAnchor = nil
        completionBaselineAt = Date().timeIntervalSince1970 * 1000
        freshTask?.cancel(); freshTask = nil
        reportTask?.cancel(); reportTask = nil
        // The chat the reader left keeps nothing here. The pane is kept
        // across chats, so a callback still holding the conversation it was
        // made for would hold it for the window's lifetime.
        toolInputs?.onChanged = nil
        disclosure = nil; toolInputs = nil
        sessionID = session.id; generation = session.presentationGeneration; viewportRequest = nil; disclosure = session.disclosure
        toolInputs = session.toolInputs
        // A document landing changes what an open card can show, and so its
        // row's height: republish so the document reconciles and re-measures.
        session.toolInputs.onChanged = { [weak self] in self?.republish() }
        // Folding a whole response changes what several rows draw without any
        // message changing. The page republishes for it and hands the page to
        // its document at once, so the clicked row and its siblings are
        // re-measured and moved in the same pass as the click. Left to
        // SwiftUI's next update, the rows took their new content there and
        // their geometry a run-loop turn later, and a frame drew one in the
        // other's place.
        session.disclosure.spanningChange = { [weak self] in
            guard let self else { return }
            self.republish()
            (self.scrollView?.documentView as? TranscriptNativeDocument)?.spanningDisclosureChanged()
        }
        reset()
        scrollView?.transcriptReading.bind(scope: session.id + ":" + session.presentationGeneration.uuidString)
        frames = [:]
        snapshot = nil; detached = false; earlierWaits = false; earlierWaitsForReader = false
        subscription = session.presentationChanges.combineLatest(session.$viewportRequest).sink { [weak self, weak session] input, request in
            guard let self, let session else { return }
            self.present(input, viewportRequest: request, from: session)
        }
    }
    private func reset() {
        initialized = false; followsBottom = true; atBottom = true; pendingAnchor = nil; openingPlacementPending = false; openingReadingAnchor = nil
        viewportResizePending = false
        settleScheduled = false; readCheckScheduled = false
        seen = []; completedAssistant = nil; firstRow = ""; jumping = false
    }

    /// Defend the source-selected resident window without evicting its reading
    /// anchor. The history/live source already chooses which edge to retain.
    nonisolated static func displayPage(_ messages: [TranscriptMessage]) -> [TranscriptMessage] {
        // A message just sent, a retry notice and the failure where the
        // conversation stopped come after it, added by the app rather than
        // read from the history. The resident window is for the conversation:
        // at a full window they were the rows it cut, so the retry and its
        // Retry button never showed, and a message sent into a long chat
        // would not have shown until the helper's own row arrived.
        let added = messages.reversed().prefix { $0.isSending || $0.role == "system" && ["notice", "failure"].contains($0.kind ?? "")
            && ($0.id.hasPrefix("notice:retry:") || $0.id.hasPrefix("failure:")) }.count
        return TranscriptPaging.window(Array(messages.dropLast(added)), keepingEarlier: true) + messages.suffix(added)
    }

    /// One leading and one trailing presentation per pane, not a debounce:
    /// raw history has already been updated before it reaches this boundary.
    /// Tool transitions, first content and every terminal state flush promptly.
    private static func sameLifecycle(_ lhs: TaskPresentationProjection?, _ rhs: TaskPresentationProjection?) -> Bool {
        guard var lhs, let rhs else { return lhs == rhs }
        lhs.sequence = rhs.sequence; lhs.sourceRevision = rhs.sourceRevision
        return lhs == rhs
    }

    /// How long an arriving reply may wait for the reader's gesture to end
    /// before it is published anyway, so a long momentum scroll never leaves
    /// the reply looking stuck.
    static let gestureHold: TimeInterval = 0.25
    private var heldSince: TimeInterval?
    private var scrollGestureInFlight: Bool {
        (scrollView as? TranscriptNativeScrollView)?.readerIsScrolling ?? false
    }

    private func present(_ input: TranscriptPresentationInput, viewportRequest request: Int, from session: SessionDisplay) {
        let textDelta = projectionError == nil && viewportRequest == request && Self.sameLifecycle(snapshot?.lifecycle, input.lifecycle) &&
            TaskTranscriptPlan.cosmetic(from: snapshot?.messages ?? [], to: input.messages)
        let now = ProcessInfo.processInfo.systemUptime
        let delay = presentationInterval - (now - lastPresentationAt)
        // The frames of a wheel gesture belong to the scroll. A reply that
        // arrives inside one waits for it — the text catches up when the hand
        // stops — unless it has been waiting long enough to look stuck.
        let held = scrollGestureInFlight && (heldSince.map { now - $0 < Self.gestureHold } ?? true)
        if textDelta, delay > 0 || held {
            if held, heldSince == nil { heldSince = now }
            pendingPresentation = (input, request)
            // On the display's own beat: the page publishes just after a frame
            // has been presented, so laying the arriving row out has the whole
            // frame interval, and never more than once per frame.
            if startFlushLink() { return }
            guard presentationTask == nil else { return }
            presentationTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(1.0 / 240, delay)))
                guard !Task.isCancelled, let self else { return }
                self.presentationTask = nil
                self.flushPendingPresentation()
            }
        } else {
            presentationTask?.cancel(); presentationTask = nil; pendingPresentation = nil; heldSince = nil
            receive(input, viewportRequest: request, from: session)
        }
    }
    /// The display's beat, while a reply is waiting to be published. It runs
    /// only while something is pending: a quiet page keeps no timer.
    private func startFlushLink() -> Bool {
        if flushLink != nil { return true }
        guard let host = hostView, host.window != nil else { return false }
        let link = host.displayLink(target: PresentationFlushTarget(self), selector: #selector(PresentationFlushTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        flushLink = link
        return true
    }
    private func stopFlushLink() { flushLink?.invalidate(); flushLink = nil }
    fileprivate func displayFlush() {
        guard pendingPresentation != nil else { stopFlushLink(); return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPresentationAt >= presentationInterval - 1.0 / 240 else { return }
        flushPendingPresentation()
        if pendingPresentation == nil { stopFlushLink() }
    }
    /// The reader's gesture has ended: publish what it was holding.
    func flushHeldPresentation() {
        guard pendingPresentation != nil else { return }
        heldSince = nil
        flushPendingPresentation()
    }
    /// Publishes the newest text the page is holding, once the gesture that
    /// was holding it has ended or has held it long enough.
    private func flushPendingPresentation() {
        guard let pending = pendingPresentation, let session = presentationSession else { heldSince = nil; return }
        let now = ProcessInfo.processInfo.systemUptime
        if scrollGestureInFlight, let heldSince, now - heldSince < Self.gestureHold {
            guard presentationTask == nil else { return }
            presentationTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.gestureHold - (now - heldSince)))
                guard !Task.isCancelled, let self else { return }
                self.presentationTask = nil
                self.flushPendingPresentation()
            }
            return
        }
        pendingPresentation = nil; heldSince = nil
        receive(pending.input, viewportRequest: pending.request, from: session)
    }

    private func receive(_ input: TranscriptPresentationInput, viewportRequest request: Int, from session: SessionDisplay) {
        guard session.id == sessionID, session.presentationGeneration == generation else { return }
        let messages = input.messages
        var navigated = false
        if viewportRequest != request {
            // A jump to the latest page or a prepended earlier page: the page starts over from the session's anchor.
            let navigating = viewportRequest != nil
            viewportRequest = request
            reset()
            explicitDestination = navigating && session.scrollAnchor?.followsBottom == false
            navigated = navigating
        }
        if snapshot?.messages.first?.id != messages.first?.id, viewportRequest == request {
            preserveReadingPositionForLayout()
        }
        let page = Self.displayPage(messages)
        let patched = snapshot.flatMap { current in
            Self.sameLifecycle(current.lifecycle, input.lifecycle) ? TranscriptActivity.patched(current.items, from: current.messages, to: page) : nil
        }
        // A page short of the conversation's newest row — cut by the resident
        // window, or a history window with newer rows after it — may end in
        // the middle of a turn; that turn folds only on its task's receipt.
        let items = patched ?? TranscriptActivity.blocks(of: page, lifecycle: input.lifecycle,
                                                         complete: page.count == messages.count && !session.newerPage.available)
        guard Set(page.map(\.id)).count == page.count, Set(items.map(\.id)).count == items.count else {
            projectionError = "This conversation contains conflicting row identities. The last valid page is retained; inspect the session file to repair it. No history was deleted."
            return
        }
        if projectionError != nil { projectionError = nil }
        if let current = snapshot, current.messages == page, current.lifecycle == input.lifecycle, initialized { return }
        var fresh: Set<String> = []
        for message in page {
            if initialized, !seen.contains(message.id) { fresh.insert(message.id) }
            seen.insert(message.id)
        }
        if !initialized {
            if let anchor = session.scrollAnchor {
                // Restoring a saved position is an explicit destination too.
                // Geometry from the initial top-of-page mount must not win.
                explicitDestination = !anchor.followsBottom
                followsBottom = anchor.followsBottom; pendingAnchor = anchor.followsBottom ? nil : anchor
            } else { followsBottom = true; pendingAnchor = nil }
            // A chat the reader opens starts at the question of its last turn.
            // A jump they asked for — back to the latest reply, which reloads
            // the page with an anchor that names no row, or the turn they have
            // just sent — lands where they asked, not at that question.
            let askedForLatest = navigated || (session.scrollAnchor.map { $0.followsBottom && $0.id.isEmpty } ?? false)
            openingPlacementPending = followsBottom && !busy && !page.isEmpty && !askedForLatest
        }
        let completed = TranscriptActivity.latestCompletedAssistant(page)
        if initialized, !session.browsingHistory, snapshot?.lifecycle?.epoch == input.lifecycle?.epoch,
           snapshot?.lifecycle?.timeline == input.lifecycle?.timeline {
            var old = Set((snapshot?.lifecycle?.recent ?? []).map(\.key))
            for task in input.lifecycle?.recent ?? [] where task.outcome == "completed" && (task.endedAtUnixMs ?? 0) >= completionBaselineAt {
                if old.insert(task.key).inserted { announceCompletion() }
            }
        }
        completedAssistant = completed
        firstRow = page.first?.id ?? ""
        // A single bounded plan supplies stable identities for both initial
        // history and incremental updates; the native document reuses hosts.
        let ids = Set(items.map(\.id))
        frames = frames.filter { ids.contains($0.key) }
        sequence += 1
        lastPresentationAt = ProcessInfo.processInfo.systemUptime
        let next = Snapshot(sessionID: session.id, generation: generation, messages: page, items: items, fresh: fresh, sequence: sequence, lifecycle: input.lifecycle, liveTurn: TaskTranscriptPlan.live(input.lifecycle, messages: messages),
                            sending: page.last(where: { $0.role == "user" })?.isSending == true)
        // The scroll document always adopts its final geometry immediately.
        // Animating a complete snapshot also animates every existing row's
        // position and races AppKit's exact anchor/bottom placement. Controls
        // and disclosures below own their small, local transitions instead.
        initialized = true
        // The rows changed, so which row holds the anchor may have changed too.
        pendingAnchorRow = nil
        snapshot = next
        PerformanceProbe.shared.transcriptSnapshotApplied(session.id, deltaAt: session.displayObservedAt)
        scheduleSettle()
        fadeFreshRows()
    }

    /// Publishes the rows again without changing them, so the native document
    /// reconciles: a fetched tool document or a faded accent changes what a
    /// row draws without any message changing.
    private func republish() {
        guard var current = snapshot else { return }
        sequence += 1
        current.sequence = sequence
        snapshot = current
    }

    /// The accent a row wears as it arrives is a moment, not a state. Without
    /// this the last turn of a conversation that then goes quiet keeps its
    /// settling highlight for as long as the chat stays open.
    private func fadeFreshRows() {
        freshTask?.cancel(); freshTask = nil
        guard snapshot?.fresh.isEmpty == false else { return }
        freshTask = Task { [weak self] in
            try? await Task.sleep(for: Self.freshDuration)
            guard !Task.isCancelled, let self, var current = self.snapshot, !current.fresh.isEmpty else { return }
            current.fresh = []
            self.sequence += 1
            current.sequence = self.sequence
            self.freshTask = nil
            self.snapshot = current
        }
    }

    /// The reader opened a card whose arguments the host had to cut: ask for
    /// the rest. Nothing happens for a card that already has its document, a
    /// fetch already in flight, or a host that cannot answer.
    func requestToolInput(messageID: String, callID: String) {
        toolInputs?.request(messageID: messageID, callID: callID)
    }

    /// Compatibility helper for callers without lifecycle evidence. Never
    /// borrows a historical row to claim it is the currently running task.
    static func liveTurn(in items: [TranscriptItem], busy: Bool) -> TurnSummary? {
        guard busy else { return nil }
        var turn = TaskTranscriptPlan.summary([], task: nil)
        turn.live = true; turn.phase = "preparing"; return turn
    }

    // MARK: Geometry

    func attach(_ scrollView: NSScrollView?, host: NSView) {
        hostView = host
        guard self.scrollView !== scrollView else { return }
        for observer in scrollObservers { NotificationCenter.default.removeObserver(observer) }
        scrollObservers = []
        self.scrollView?.transcriptReading.classifyMovement = nil
        self.scrollView = scrollView
        guard let scrollView else { return }
        // Whoever reaches the reading anchor first after a movement asks the
        // page whose it was, so a reader's scroll is never undone by an
        // anchor taken before it landed.
        scrollView.transcriptReading.classifyMovement = { [weak self] in self?.classifyMovement() }
        // A reply held back by the reader's gesture goes out the moment it ends.
        (scrollView as? TranscriptNativeScrollView)?.onScrollGestureEnded = { [weak self] in
            self?.flushHeldPresentation()
        }
        scrollView.transcriptReading.bind(scope: (sessionID ?? "") + ":" + (generation?.uuidString ?? ""))
        scrollView.transcriptReading.following = pagePlacesItself
        let center = NotificationCenter.default
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObservers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionDelivered() }
        })
        // User scrolling decides whether the page follows; programmatic scrolls never do.
        for name in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
            scrollObservers.append(center.addObserver(forName: name, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.userScrolled(ended: name == NSScrollView.didEndLiveScrollNotification) }
            })
        }
        scrollObservers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readerWillNavigate(upward: false) }
        })
        if let document = scrollView.documentView {
            document.postsFrameChangedNotifications = true
            scrollObservers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.documentResized() }
            })
        }
        scheduleSettle()
    }
    func viewportChanged(_ size: CGSize) {
        guard size != viewport else { return }
        viewport = size
        // A page the reader can scroll through now asks for earlier rows on
        // its own again, as they reach the top.
        if content.height > viewport.height + Self.earlierThreshold { earlierWaits = false }
        // AppKit may adjust the origin more than once during this resize.
        // Those changes belong to layout until its deferred placement lands.
        viewportResizePending = true
        // A narrower pane makes the same rows taller; a reader at the newest message
        // stays there. The geometry callback runs inside a native update, so the
        // scroll itself waits for the run loop: AppKit and SwiftUI never fight over
        // the scroll position mid-layout, and a resize animation settles once per frame.
        scheduleSettle()
        requestReadCheck()
    }
    func viewportWillResize() {
        viewportResizePending = true
        scheduleSettle()
    }
    func contentChanged(_ geometry: ContentGeometry) {
        guard geometry != content else { return }
        let previous = content
        content = geometry
        if geometry.height != previous.height {
            scheduleSettle()
            requestEarlierIfNearTop(scrollY: followsBottom ? max(0, geometry.height - viewport.height) : scrollY)
        } else if geometry.top != previous.top {
            scheduleReport()
        }
    }
    func rowFrame(_ id: String, _ frame: CGRect) {
        guard frames[id] != frame else { return }
        frames[id] = frame
        guard let anchor = pendingAnchor else { return }
        if pendingAnchorRow == nil { pendingAnchorRow = rowIdentifier(for: anchor.id) }
        if pendingAnchorRow == id { scheduleSettle() }
    }
    func rowGone(_ id: String) { frames.removeValue(forKey: id) }
    /// Capture the actual first visible row before a reflow. This keeps a
    /// detached reader at the same text when rows above grow or the pane narrows.
    func preserveReadingPositionForLayout() {
        scrollView?.transcriptReading.captureDocument()
        guard initialized, !followsBottom, !jumping, pendingAnchor == nil, let snapshot else { return }
        // Keep the chosen opening question fixed while offscreen estimates
        // settle. A preceding row visible only in its 12-point margin must
        // not steal that anchor and move the question when it remeasures.
        if let openingReadingAnchor, snapshot.messages.contains(where: { $0.id == openingReadingAnchor.id }) {
            pendingAnchor = openingReadingAnchor
            return
        }
        let offset = position.offset
        for item in snapshot.items {
            guard let frame = frames[item.id], frame.maxY > offset else { continue }
            pendingAnchor = TranscriptAnchor(id: item.id, offset: frame.minY - offset, followsBottom: false)
            return
        }
    }
    var preferredOpeningRowID: String? {
        guard openingPlacementPending else { return nil }
        return snapshot?.items.last(where: { if case .message(let row) = $0 { return row.role == "user" }; return false })?.id
    }
    func pinSelectedRow(_ item: TranscriptItem?) {
        switch item {
        case .message(let row): presentationSession?.pinnedHistoryIDs = [row.id]
        case .block(let block): presentationSession?.pinnedHistoryIDs = Set(block.replies.map(\.id))
        case nil: presentationSession?.pinnedHistoryIDs = []
        }
    }
    /// A row's frame in content coordinates, for tests.
    func rowFrame(of id: String) -> CGRect? { frames[id] }
    /// The row the reader is on and where it sits, for a layout that has to
    /// work out which rows they will be able to see once it lands. Nil while
    /// the page follows the newest row, or while a jump owns the scroll.
    var readingAnchor: TranscriptAnchor? { followsBottom || jumping ? nil : pendingAnchor }
    /// The same anchor named by the row that holds it, which is what a layout
    /// pass can look up. A remembered anchor names a message; the row that
    /// draws it is the block the message was folded into.
    var readingAnchorRow: TranscriptAnchor? {
        guard let anchor = readingAnchor else { return nil }
        return TranscriptAnchor(id: rowIdentifier(for: anchor.id), offset: anchor.offset, followsBottom: false)
    }
    /// While a jump to the newest row is running it owns the scroll position;
    /// nothing else may move the reader.
    var isPlacingScroll: Bool { jumping }
    /// Standing on the newest row and following it, placing nothing else: no
    /// jump, no destination the reader asked for, no opening placement or
    /// anchor still to land. A viewport that changes height keeps such a page
    /// on its newest row in the same layout pass.
    var pinsNewestRow: Bool {
        initialized && followsBottom && atBottom && !jumping && !explicitDestination && !openingPlacementPending
            && openingReadingAnchor == nil && pendingAnchor == nil
    }
    /// The AppKit document took its newly measured height: land the pending
    /// scroll. The frame notification can fire while the hosting scroll view is
    /// still updating (that is where 0.1.47 crashed), so the landing is deferred.
    private func documentResized() {
        if followsBottom || explicitDestination { scheduleSettle() }
    }

    private func scheduleSettle() {
        guard !settleScheduled else { return }
        settleScheduled = true
        // After the document commits the new rows, never inside an AppKit layout callback.
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.settleScheduled = false
            self.settle()
        }
    }
    /// Puts the page where it belongs after rows change: at the bottom while
    /// following, or with the anchored row back where the reader left it.
    private func settle() {
        defer { viewportResizePending = false }
        // An explicit jump owns scrolling until it lands. A reply arriving
        // during that animation must not snap the clip view on every delta.
        guard !jumping else { requestReadCheck(); return }
        if openingPlacementPending, documentSettled, viewport.height > 0, let snapshot {
            // The reader opened this chat: show the question that started the last
            // turn, unless the whole turn fits above the bottom anyway.
            if let lastUser = snapshot.items.last(where: { if case .message(let m) = $0 { return m.role == "user" }; return false }), let frame = frames[lastUser.id] {
                openingPlacementPending = false
                let bottom = max(0, content.height - viewport.height)
                if frame.minY < bottom - 1 {
                    followsBottom = false
                    pendingAnchor = TranscriptAnchor(id: lastUser.id, offset: 12, followsBottom: false)
                    openingReadingAnchor = pendingAnchor
                    if !detached { detached = true }
                }
            } else if !frames.isEmpty { openingPlacementPending = false }
        }
        if followsBottom {
            pendingAnchor = nil
            // Wait for exact native geometry instead of landing at a stale height.
            if documentSettled { scrollToBottom() }
            if detached && !jumping { detached = false }
            requestReadCheck()
            return
        }
        if scrollView?.transcriptReading.restore() == true {
            pendingAnchor = nil; requestReadCheck(); return
        }
        guard let anchor = pendingAnchor, let snapshot else { requestReadCheck(); return }
        let rowID = rowIdentifier(for: anchor.id)
        guard snapshot.items.contains(where: { $0.id == rowID }) else { pendingAnchor = nil; return }
        if let frame = frames[rowID] {
            // Wait for the document height, or AppKit would clamp the scroll short.
            guard documentSettled else { return }
            // Keep the saved anchor until the native document attaches.
            guard let scrollView, let document = scrollView.documentView else { return }
            let destination = explicitDestination
            pendingAnchor = nil
            scroll(to: frame.minY - anchor.offset, animated: false)
            // A saved position or a jump lands on the heights the rows above
            // have so far, most of them estimated. Their measurement comes
            // after, and moved the row the reader was put on by up to the
            // estimate's error. Hold the reader's line on that row until the
            // reader moves.
            if destination, let row = (document as? TranscriptNativeDocument)?.retainedRows.first(where: { $0.itemID == rowID }) {
                scrollView.transcriptReading.hold(row)
            }
        }
        requestReadCheck()
    }
    private var documentSettled: Bool {
        guard let document = scrollView?.documentView else { return true }
        return document.frame.height >= content.height - 1
    }
    /// A message folded into a block scrolls to the block that holds it.
    private func rowIdentifier(for messageID: String) -> String {
        guard let snapshot else { return messageID }
        if let body = snapshot.items.first(where: { item in
            if case .block(let block) = item { return block.presentation == .body && block.message?.id == messageID }; return false
        }) { return body.id }
        for item in snapshot.items {
            switch item {
            case .message(let message): if message.id == messageID { return item.id }
            case .block(let block): if block.replies.contains(where: { $0.id == messageID }) { return item.id }
            }
        }
        return messageID
    }
    /// The row a message ends in. A response read in order is a header line,
    /// its parts and its accounting line, every one of them carrying the
    /// response's id: its end is the last of them, not the header.
    private func endRowIdentifier(for messageID: String) -> String {
        guard let snapshot else { return messageID }
        for item in snapshot.items.reversed() {
            switch item {
            case .message(let message): if message.id == messageID { return item.id }
            case .block(let block): if block.replies.contains(where: { $0.id == messageID }) { return item.id }
            }
        }
        return messageID
    }
    /// Whether the end of a reply is on the screen: what counts it as read.
    func replyEndIsOnScreen(_ messageID: String) -> Bool {
        guard let frame = frames[endRowIdentifier(for: messageID)]?.offsetBy(dx: 0, dy: -position.offset) else { return false }
        return TranscriptActivity.replyEndIsVisible(top: frame.minY, bottom: frame.maxY, height: frame.height, viewportHeight: viewport.height)
    }

    /// The reader scrolled: decide whether the page still follows the newest
    /// message, show or hide the jump pill, ask for the earlier page near the
    /// top, and a little later remember the anchor and check for a read.
    func readerWillNavigate(upward: Bool) {
        scrollView?.transcriptReading.readerMoved()
        upwardNavigation = readerNavigationStarted ? upwardNavigation || upward : upward; readerNavigationStarted = true
        readerOwnsPosition()
        // Going up leaves the bottom band, and saying so now rather than once
        // AppKit has delivered the new offset is what keeps a reply arriving
        // in the same frame from scrolling the page to the end under the
        // reader's hand. Every other direction is left to the band itself.
        guard upward, followsBottom else { return }
        followsBottom = false; atBottom = false
        if !detached { detached = true }
    }
    /// How far the reader is from the end of the page as AppKit has it this
    /// instant. The reported content height lags the document's own frame by
    /// a layout, and a clamp to a document that has just become shorter lands
    /// exactly on this figure: reading the lagging one instead would make
    /// every such clamp look like the reader scrolling away.
    private var liveDistanceToBottom: CGFloat {
        guard let scrollView, let document = scrollView.documentView, scrollView.contentView.bounds.height > 0 else { return distanceToBottom }
        return max(0, document.frame.height - scrollView.contentView.bounds.height) - position.offset
    }
    /// Whether the reader is standing in the bottom band. The extra point
    /// absorbs the rounding AppKit does to the backing scale, so a reader who
    /// is visibly at the end is never a fraction of a point short of it.
    private var isWithinBottomBand: Bool { liveDistanceToBottom <= Self.followThreshold + 1 }

    /// AppKit has given the clip view a new origin.
    private func positionDelivered() {
        classifyMovement()
    }
    /// The ledger says whose movement the clip's current origin was.
    ///
    /// A movement the page wrote leaves ownership exactly as it was: the page
    /// keeps following if it was following, and a document that has just
    /// grown is settled back onto its new end rather than being unpinned for
    /// the one frame between the growth and the landing.
    ///
    /// Anything else is the reader's. That hands them the destination — an
    /// opening placement, a restored anchor, a jump still in flight all give
    /// way — and the bottom band alone then decides whether the page follows.
    /// The line of text the pane was holding goes too: it was taken where
    /// the reader stood before this movement — AppKit lands a mouse wheel a
    /// frame or more after the event, and moves a dragged scroller many times
    /// after the drag began — so restoring it would put them back there. The
    /// next pass that changes the geometry around them takes it again, where
    /// they are now.
    ///
    /// Asking again about the same offset changes nothing: the ledger has
    /// already seen it and answers that nothing moved.
    private func classifyMovement() {
        guard let scrollView, position.viewport > 0 else { scheduleReport(); return }
        viewportChanged(scrollView.contentView.bounds.size)
        let short = liveDistanceToBottom
        let inBand = short <= Self.followThreshold + 1
        let delivery = scrollView.transcriptReading.ledger.delivered(position.offset, floor: position.offset + short)
        // While the page is still putting itself where this chat opens, or
        // landing a jump, it has not finished writing where the reader should
        // be: AppKit's own clamping as the rows above them settle is not the
        // reader taking over, and must not abandon the placement half way. A
        // real gesture still does, through `readerWillNavigate`.
        //
        // The question a chat opened at is not among these: the page has put
        // the reader there, and a movement nothing announced — a selection
        // dragged past the edge, a control reached with Tab — is theirs.
        // Read as the page's, it left the question pinned, and the next
        // pass of idle measuring put them back on it.
        let placing = openingPlacementPending || jumping || viewportResizePending
        if delivery == .reader, initialized, !placing {
            scrollView.transcriptReading.readerMoved()
            readerOwnsPosition()
            setPinned(inBand)
        } else if followsBottom {
            // Nothing the reader did. A page that was following stays
            // following: letting the geometry decide here would unpin it for
            // the one frame between the document growing and the page landing
            // on its new end. Landing there is `contentChanged`'s business,
            // and settling from here as well would race the placement a chat
            // makes when it opens.
            setPinned(true)
        } else if atBottom != inBand {
            // The page's own movement, and the page is not following: an
            // opening placement at the last question, or a reading position
            // restored from a previous session. The way back is offered
            // because of where the reader now is, not because of who put
            // them there.
            atBottom = inBand
        }
        // Where the reader is is remembered a moment after it changes: after
        // a movement of theirs, or one of the page's that puts them somewhere.
        // Following the newest row, the page writes a scroll for every token
        // of a reply, and none of those is a place anyone chose — remembering
        // each was a write to the chat's saved state several times a second.
        if delivery == .reader || (delivery == .page && !followsBottom) { scheduleReport() }
    }
    /// The reader has taken the position. Everything the page was still
    /// intending to do with it is dropped.
    ///
    /// The reading anchor is a different thing: it is what holds the line of
    /// text they are on while blocks above them re-measure. It is released
    /// where a gesture begins, in `readerWillNavigate`, and where a movement
    /// of theirs lands, in `classifyMovement` — never from a notification
    /// about a gesture that has already been attributed, which can arrive
    /// after the page has taken a new anchor where the reader now is.
    private func readerOwnsPosition() {
        viewportResizePending = false
        pendingAnchor = nil; openingPlacementPending = false; openingReadingAnchor = nil
        jumping = false
    }
    /// Standing in the bottom band pins the page to the newest row; leaving
    /// it unpins; coming back re-pins. Nothing else decides this — not which
    /// way the last gesture went, not how the reader got here.
    private func setPinned(_ pinned: Bool) {
        if atBottom != pinned { atBottom = pinned }
        guard !jumping else { return }
        if followsBottom != pinned { followsBottom = pinned }
        if detached != !pinned { detached = !pinned }
    }
    private func userScrolled(ended: Bool) {
        // The reader's own movement wins over an opening/restoration still waiting for layout.
        readerOwnsPosition()
        if !readerNavigationStarted { scrollView?.transcriptReading.readerMoved() }
        if ended { readerNavigationStarted = false; upwardNavigation = false }
        evaluateFollowing()
        requestEarlierIfNearTop(scrollY: position.offset)
        scheduleReport()
    }
    private func evaluateFollowing() {
        guard position.viewport > 0 else { return }
        setPinned(isWithinBottomBand)
    }
    private func requestEarlierIfNearTop(scrollY: CGFloat) {
        let short = content.height <= viewport.height + Self.earlierThreshold
        // Rows the reader can scroll through again ask for the page before
        // them again on their own.
        if !short { earlierWaits = false }
        guard scrollY < Self.earlierThreshold, !firstRow.isEmpty, let sessionID, let session = presentationSession,
              !session.historyState.loading, !session.olderPage.loading, session.olderPage.error == nil,
              session.olderPage.cursor != nil, session.presentation.readyAt != nil else { return }
        if short {
            guard session.presentation.automaticFills < HistoryWindowPolicy.automaticFills else {
                // A page this short cannot be scrolled to ask again.
                earlierWaits = true
                return
            }
            session.presentation.automaticFills += 1
        }
        earlierWaits = false
        onLoadEarlier(sessionID)
    }
    private func scheduleReport() {
        guard reportTask == nil else { return }
        reportTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            self.reportTask = nil
            self.reportAnchor()
            self.requestReadCheck()
        }
    }
    /// The last place the page said the reader was, so the same place is not
    /// said again.
    private var lastReportedAnchor: TranscriptAnchor?
    private func reportAnchor() {
        guard let snapshot else { return }
        let scrollY = scrollY
        for item in snapshot.items {
            guard let frame = frames[item.id], frame.maxY - scrollY > 0 else { continue }
            let id: String = { if case .block(let block) = item { return block.message?.id ?? block.activity.first?.id ?? item.id }; return item.id }()
            // The anchor names a message, and it is put back against the row
            // that message resolves to — for a response read in order, its
            // header. Measured from that same row, a reader on a later part of
            // the response comes back to that part rather than to the header.
            let held = frames[rowIdentifier(for: id)] ?? frame
            let anchor = TranscriptAnchor(id: id, offset: held.minY - scrollY, followsBottom: followsBottom)
            if let last = lastReportedAnchor, last.id == anchor.id, last.followsBottom == anchor.followsBottom,
               abs(last.offset - anchor.offset) < 0.5 { return }
            lastReportedAnchor = anchor
            onAnchorChanged(anchor)
            return
        }
    }

    // MARK: Scrolling

    private func scroll(to y: CGFloat, animated: Bool, completion: (() -> Void)? = nil) {
        guard let scrollView, let document = scrollView.documentView else {
            completion?(); return
        }
        let clip = scrollView.contentView
        let maximum = max(0, document.frame.height - clip.bounds.height)
        let target = min(max(0, y), maximum)
        let origin = NSPoint(x: clip.bounds.origin.x, y: document.isFlipped ? target : maximum - target)
        guard animated else {
            scrollView.transcriptReading.setOrigin(origin)
            completion?(); return
        }
        // Every frame of the animation is delivered as a bounds change, so the
        // whole corridor between here and there is written down as the page's
        // own movement before the first of them arrives.
        scrollView.transcriptReading.willAnimate(from: clip.bounds.origin.y, to: origin.y)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(origin)
        }, completionHandler: {
            MainActor.assumeIsolated {
                scrollView.reflectScrolledClipView(clip)
                completion?()
            }
        })
    }
    private func scrollToBottom(animated: Bool = false, completion: (() -> Void)? = nil) {
        let p = position
        scroll(to: max(0, p.height - p.viewport), animated: animated, completion: completion)
    }
    func jumpToLatest() {
        scrollView?.transcriptReading.readerMoved()
        followsBottom = true; jumping = true; detached = false
        pendingAnchor = nil; openingPlacementPending = false; openingReadingAnchor = nil
        let animated = !PiMotion.reducesMotion
        let generation = generation
        scrollToBottom(animated: animated) { [weak self] in
            guard let self, self.generation == generation, self.jumping else { return }
            self.jumping = false
            // The document may have grown while the animation was targeting
            // its earlier bottom. Keep following the latest content instead
            // of incorrectly detaching at that stale target.
            self.scrollToBottom()
            self.evaluateFollowing()
            self.scheduleReport()
        }
        // A scroll the system abandons must not leave the pill hidden.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard let self, self.generation == generation, self.jumping else { return }
            self.jumping = false
            self.evaluateFollowing()
        }
    }

    /// Native document commits final visible geometry before lifting the loading
    /// cover. The next run-loop opportunity is not physical frame presentation.
    func visibleBandLaidOut(ready: @escaping () -> Bool) {
        guard let id = sessionID, let generation, presentationSession?.historyState == .preparing else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation, self.sessionID == id,
                  self.presentationSession?.historyState == .preparing else { return }
            self.settle()
            guard !self.openingPlacementPending, self.pendingAnchor == nil, ready() else { return }
            self.onViewportReady(id, generation)
            // The prepared tree may already be cached beneath the loading
            // cover. Request one destination draw after lifting that cover.
            self.scrollView?.documentView?.needsDisplay = true
            self.requestEarlierIfNearTop(scrollY: self.scrollY)
        }
    }
    func destinationDrawOpportunity() -> Bool {
        guard let session = presentationSession, session.presentationGeneration == generation,
              session.historyState == .ready else { return false }
        session.presentation.drawOpportunityAt = PerformanceProbe.now
        PerformanceProbe.shared.observe("selectionDestinationDrawMs", milliseconds: PerformanceProbe.now - session.presentation.startedAt)
        return true
    }

    // MARK: Read receipts

    private var canRead: Bool {
        guard let session = presentationSession, session.presentationGeneration == generation,
              session.historyState == .ready || session.historyState == .dormant else { return false }
        guard let host = hostView, let window = host.window else { return false }
        let surface: NSView = scrollView ?? host
        return TranscriptReadVisibility.permits(appActive: NSApp.isActive, keyWindow: window.isKeyWindow, windowVisible: window.isVisible,
                                                occluded: !window.occlusionState.contains(.visible), minimized: window.isMiniaturized,
                                                viewHidden: surface.isHiddenOrHasHiddenAncestor || surface.visibleRect.isEmpty, sheetOpen: window.attachedSheet != nil)
    }
    /// Whether a reply on screen would count as read right now: the window is
    /// this app's, key, visible, unoccluded and carrying no sheet. Reading it
    /// is how a test says whether the desktop it is running on can answer the
    /// question at all.
    var readingIsVisible: Bool { canRead }
    func requestReadCheck() {
        guard !readCheckScheduled else { return }
        readCheckScheduled = true
        Task { [weak self] in
            await Task.yield() // Let window and page visibility settle first.
            guard let self else { return }
            self.readCheckScheduled = false
            self.checkRead()
        }
    }
    private func checkRead() {
        guard let sessionID, let completed = completedAssistant, canRead, replyEndIsOnScreen(completed) else { return }
        onReadReply(sessionID, completed)
    }
}

/// The display link retains its target; the target must not retain the page.
@MainActor private final class PresentationFlushTarget: NSObject {
    weak var page: TranscriptPage?
    init(_ page: TranscriptPage) { self.page = page }
    @objc func tick(_ link: CADisplayLink) { page?.displayFlush() }
}

/// Sits inside the page's scroll view; its enclosing scroll view is the transcript surface.
final class TranscriptSurfaceMarker: NSView {
    var attach: ((NSScrollView?, NSView) -> Void)?
    /// The page behind this surface, for tests that measure rows.
    weak var page: TranscriptPage?
    private weak var found: NSScrollView?
    private var located = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); locate() }
    func locate() {
        var view: NSView? = superview
        while let current = view, !(current is NSScrollView) { view = current.superview }
        let scroll = view as? NSScrollView
        guard !located || scroll !== found else { return }
        located = true; found = scroll
        attach?(scroll, self)
    }
}

/// Values affecting the row's own rendering must cross the hosting boundary.
/// Reduce Motion remains a system accessibility environment in both hosts.
struct TranscriptRowEnvironment: Equatable {
    var colorScheme: ColorScheme
    var contrast: ColorSchemeContrast
    var dynamicTypeSize: DynamicTypeSize
    var layoutDirection: LayoutDirection
    var locale: Locale
    var isEnabled: Bool
    init(_ values: EnvironmentValues = EnvironmentValues()) {
        colorScheme = values.colorScheme; contrast = values.colorSchemeContrast
        dynamicTypeSize = values.dynamicTypeSize; layoutDirection = values.layoutDirection; locale = values.locale
        isEnabled = values.isEnabled
    }
    /// Whether a row measured under these values is as tall under those.
    /// The type size, the writing direction and the locale decide how text
    /// wraps; the colour scheme, the contrast and whether the pane takes input
    /// only decide how it is painted. The pane is disabled while Reports is
    /// in front, and that must not cost every row its measurement.
    func hasSameGeometry(as other: TranscriptRowEnvironment) -> Bool {
        return dynamicTypeSize == other.dynamicTypeSize && layoutDirection == other.layoutDirection && locale == other.locale
    }
}

private struct TranscriptHostedRow: View {
    let item: TranscriptItem
    let fresh: Bool
    let actions: TranscriptActions
    let width: CGFloat
    let environment: TranscriptRowEnvironment
    /// Plain values, not observed state: the row host knows what the reader
    /// opened, so it can re-measure this row in the same pass as the click.
    var disclosure = TranscriptRowDisclosure.default
    var toggle: (TranscriptDisclosure.Part) -> Void = { _ in }
    /// What this turn's work list measured last time it was open, kept by the
    /// row container so a fold costs a frame change rather than sixty rows of
    /// native layout.
    var workListHeight: CGFloat? = nil
    var workListMeasured: (CGFloat) -> Void = { _ in }
    /// True while the document is moving this row between two measured
    /// heights, so a folding work list stays on screen and slides away.
    var foldInMotion = false
    /// Whether this message draws nothing at all: its turn has folded behind
    /// one line, or its response has folded and this is the header line's own
    /// figures, which that line already carries.
    private func drawsNothing(_ message: TranscriptMessage) -> Bool {
        disclosure.foldedAway || (message.kind == "requestInfo" && disclosure.responseFolded)
    }
    var body: some View {
        Group {
            switch item {
            case .message(let message):
                // A row a fold has emptied must take up nothing: the paragraph
                // spacing reserved around every message would otherwise leave
                // fourteen points of blank where the fold swallowed the row.
                let blank = drawsNothing(message)
                MessageRowView(message: message, actions: actions, disclosure: disclosure, toggle: toggle).equatable()
                    .padding(.top, blank ? 0 : (message.role == "user" ? 14 : 4))
                    .padding(.bottom, blank ? 0 : (message.role == "user" ? 4 : 10))
            case .block(let block):
                BlockRowView(block: block, actions: actions, fresh: fresh, disclosure: disclosure, toggle: toggle,
                             workListHeight: workListHeight, workListMeasured: workListMeasured,
                             foldInMotion: foldInMotion).equatable()
            }
        }
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, environment.colorScheme)
        .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
        .environment(\.layoutDirection, environment.layoutDirection)
        .environment(\.locale, environment.locale)
        .disabled(!environment.isEnabled)
        // No control in a row draws the system's focus ring; the ones that
        // take focus on purpose draw their own (`TranscriptFocusRing`).
        .focusEffectDisabled()
        .piStableLayout()
    }
}

private final class TranscriptRowHostingView: NSHostingView<TranscriptHostedRow> {
    weak var owner: TranscriptRowContainer?
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        owner?.contentSizeChanged()
    }
}

@MainActor final class TranscriptRowContainer: NSView {
    var onHeightInvalidated: (() -> Void)?
    var onHeightValidated: (() -> Void)?
    /// The SwiftUI tree this row draws through, built the first time the row
    /// is measured or mounted and let go of once the reader has scrolled well
    /// past it. A page of three hundred rows would otherwise hold three
    /// hundred hosting views, which is most of what opening or leaving a long
    /// chat used to cost. The row keeps what it is, what it measured and what
    /// the reader opened in it either way.
    private var hosted: TranscriptRowHostingView?
    private(set) var item: TranscriptItem
    private var fresh: Bool
    private var actions: TranscriptActions
    private var environment: TranscriptRowEnvironment
    private var measurements: [CGSize] = []
    private var measuring = false
    private var invalidationPending = false
    private var width: CGFloat = TranscriptMetrics.pageWidth
    private let geometryCache: TranscriptGeometryCache?
    private let geometrySessionID: String?
    private let disclosureStore: TranscriptDisclosure?
    private let toolInputs: TranscriptToolInputs?
    /// Asks the conversation for a call's full arguments, with the id of the
    /// reply that made the call.
    var onToolInputNeeded: ((String, String) -> Void)?
    private var disclosure: TranscriptRowDisclosure
    /// The store and tool-document revisions `disclosure` was read at.
    private var disclosureRevisions = (-1, -1)
    /// Called when the reader opens or closes part of this row, so the document
    /// lays the rows out again in the same pass rather than a run loop later.
    var onDisclosureChanged: (() -> Void)?
    private var measurementScale: CGFloat?
    private var restoredMeasurementNeedsValidation = false
    /// Geometry inside FoldedWork, independently of the reply prose and turn
    /// footer. Usage that is actually inside the work list remains in this key:
    /// a longer model name can wrap and must invalidate the measured height.
    private struct ReplyWorkKey: Equatable {
        var id: String
        var thinking: String
        var streaming: Bool
        var tools: [ToolView]
        var accounting: GatewayTotals?
    }
    private struct WorkListKey: Equatable {
        var width: CGFloat
        var replies: [ReplyWorkKey]
        var openTools: Set<String>
        var openReasoning: Set<String>
        var inputs: [String: ToolInputDocument]
        var environment: TranscriptRowEnvironment
    }
    private var workList: (key: WorkListKey, height: CGFloat)?
    private var workListKey: WorkListKey {
        let replies: [ReplyWorkKey]
        if case .block(let block) = item {
            replies = block.replies.map { reply in
                let showsUsage = !(reply.tools ?? []).isEmpty || !(reply.thinking ?? "").isEmpty || reply.id != block.message?.id
                return ReplyWorkKey(id: reply.id, thinking: reply.thinking ?? "", streaming: reply.isStreaming,
                                    tools: reply.tools ?? [], accounting: showsUsage ? reply.accounting : nil)
            }
        } else { replies = [] }
        return WorkListKey(width: width, replies: replies, openTools: disclosure.openTools,
                           openReasoning: disclosure.openReasoning, inputs: disclosure.toolInputs, environment: environment)
    }
    /// How often this row has been able to reuse its work list's measured
    /// height instead of measuring sixty tool rows again.
    private(set) var workListReuses = 0
    /// Explicit exact-width cache misses, separately from AppKit's redundant
    /// intrinsic-size validation requests when a host reenters a window.
    private(set) var measurementCount = 0
    /// How many times SwiftUI has sized or laid this row's tree out.
    private(set) var nativeSizingPasses = 0
    private(set) var intrinsicValidationCount = 0
    private(set) var sharedMeasurementHits = 0
    var itemID: String { item.id }
    var contentItem: TranscriptItem { item }
    /// The values this row is drawn with, for checks that a change reached it.
    var renderingEnvironment: TranscriptRowEnvironment { environment }
    /// What the hosted content actually needs at this width, for checks that a
    /// row never draws more than its own frame holds.
    var hostedFittingHeight: CGFloat { ceil(host().fittingSize.height) }
    /// Whether this row is holding a SwiftUI tree right now.
    var isHosted: Bool { hosted != nil }
    /// Set while this row's tree has not been laid out since it was built or
    /// its content changed. A row mounted only because it is near the
    /// viewport waits for the reader to actually reach it.
    private(set) var awaitingViewportLayout = false
    /// Builds the row's tree so it is ready to draw. A row near the viewport
    /// is prepared; only one the reader can actually see is laid out.
    func prepareToDraw() { host() }
    /// What a row about to arrive can usefully do before it arrives. Laying
    /// it out and drawing it into its backing store here as well was tried
    /// and measured: a first read through a four-hundred-row page went from
    /// 4.2 % of its steps over a 120 Hz frame to 8.3 %, because the work
    /// lands on the step that prepares the row instead of the step that
    /// shows it, and an unmounted row's drawing is thrown away. Building the
    /// tree is the part that pays.
    func prepareForTheReader() {
        host()
        // Laying it out here is what leaves the frame that shows it with
        // nothing to do. The shared scheduler admits one of these per frame,
        // so it is bounded; a row still standing at an estimate is left until
        // it has a height of its own.
        if hasMeasurement(width: width) { layoutForViewport() }
    }
    /// While the document is moving this row between two measured heights,
    /// the tree inside it stays at the height it was measured at and the row
    /// clips to the frame the motion is interpolating. Resizing the tree on
    /// every tick is the SwiftUI re-layout the motion exists to avoid.
    private var pinnedContentHeight: CGFloat?
    /// The part of the row the motion is revealing or hiding fades while the
    /// frame moves. It is one mask over the region the two states do not
    /// share, so every disclosure fades the same way — a turn's work, a tool
    /// card, exposed reasoning, a compaction summary — without any of them
    /// having to know about it, and without a hosting boundary per region.
    private var revealFade: CALayer?
    private var addedLayerForReveal = false
    var isInDisclosureMotion: Bool { pinnedContentHeight != nil }
    /// True while a folding work list must stay placed although the row is
    /// closing, so it slides out of sight instead of vanishing first.
    private var keepingFoldedContent = false
    func beginDisclosureMotion(contentHeight: CGFloat, keepingContentPlaced: Bool) {
        pinnedContentHeight = max(1, contentHeight)
        // Opening, the content is placed anyway; only a closing row has to be
        // told to keep it, and only then is the tree worth rebuilding.
        if keepingContentPlaced {
            keepingFoldedContent = true
            updateRoot()
        }
        if layer == nil { wantsLayer = true; addedLayerForReveal = true }
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        let fade = CALayer()
        fade.backgroundColor = NSColor.black.cgColor
        mask.addSublayer(fade)
        revealFade = fade
        layer?.mask = mask
        needsLayout = true
        layout()
    }
    func endDisclosureMotion() {
        guard pinnedContentHeight != nil else { return }
        pinnedContentHeight = nil
        layer?.mask = nil
        revealFade = nil
        if addedLayerForReveal { wantsLayer = false; addedLayerForReveal = false }
        if keepingFoldedContent {
            keepingFoldedContent = false
            updateRoot()
        }
        needsLayout = true
    }
    /// The region the two states do not share, and how visible it is. The
    /// part both states have stays solid; the rest fades out as it goes and
    /// in as it arrives.
    func setDisclosureReveal(keeping: CGFloat, fade: CGFloat) {
        guard let revealFade, let mask = layer?.mask else { return }
        let height = max(1, pinnedContentHeight ?? bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = CGRect(x: 0, y: 0, width: max(1, bounds.width), height: max(1, keeping))
        revealFade.frame = CGRect(x: 0, y: max(0, keeping), width: max(1, bounds.width), height: max(0, height - keeping))
        revealFade.opacity = Float(min(1, max(0, fade)))
        CATransaction.commit()
    }
    /// Lets go of the SwiftUI tree for a row the reader has scrolled well
    /// past. Everything that decides what the row is and how tall it is
    /// stays, so coming back to it is one native layout and no measuring.
    func releaseHost() {
        guard let hosted, !measurements.isEmpty, !invalidationPending, !restoredMeasurementNeedsValidation,
              !ownsFirstResponder else { return }
        hosted.owner = nil
        hosted.removeFromSuperview()
        self.hosted = nil
    }
    /// Lays the row's tree out as it joins the view tree, so the frame that
    /// draws it has nothing left to do. A tree that is already laid out costs
    /// nothing here; a borrowed height is confirmed once, the first time the
    /// row is actually drawn.
    func layoutForViewport() {
        let started = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        defer { if TranscriptLayoutClock.recording { TranscriptLayoutClock.viewportLayoutSeconds += TranscriptLayoutClock.now - started } }
        let hosted = host()
        if hosted.needsLayout || needsLayout {
            nativeSizingPasses += 1
            if TranscriptLayoutClock.recording { TranscriptLayoutClock.rowSizingPasses += 1 }
        }
        layoutSubtreeIfNeeded()
        guard awaitingViewportLayout else { return }
        awaitingViewportLayout = false
        validateSharedMeasurementAfterMount()
    }
    func hasMeasurement(width: CGFloat) -> Bool { measurements.contains { $0.width == width } }
    /// The exact height this row already has at a width, or nil.
    func measuredHeight(width: CGFloat) -> CGFloat? { measurements.last { $0.width == width }?.height }
    /// A row nothing has ever measured, at any width: a chat the reader has
    /// just opened, or a page of earlier rows just prepended. Such a row may
    /// stand at an estimate until the page is about to draw it; a row whose
    /// content or width changed has a height to fall back on and never does.
    var neverMeasured: Bool { measurementCount == 0 && measurements.isEmpty }
    /// What this row is worth before anything has measured it. The page asks
    /// for this once per pass for every row it has not measured yet, so the
    /// answer is kept rather than counting the row's characters again.
    func estimatedHeight(width: CGFloat) -> CGFloat {
        if let estimate, estimate.width == width { return estimate.height }
        let height = TranscriptRowEstimate.height(of: item, width: width)
        estimate = (width, height)
        return height
    }
    private var estimate: (width: CGFloat, height: CGFloat)?
    var needsMountedValidation: Bool { invalidationPending || restoredMeasurementNeedsValidation || !hasMeasurement(width: width) }
    var ownsFirstResponder: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        if responder.isDescendant(of: self) { return true }
        // AppKit's shared field editor is attached to the window, not always
        // beneath its selectable NSTextField. Its delegate owns the selection.
        if let editor = responder as? NSTextView, let field = editor.delegate as? NSView {
            return field.isDescendant(of: self)
        }
        return false
    }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measurements.last { $0.width == width }?.height ?? NSView.noIntrinsicMetric)
    }
    init(item: TranscriptItem, fresh: Bool, actions: TranscriptActions, environment: TranscriptRowEnvironment = TranscriptRowEnvironment(),
         geometryCache: TranscriptGeometryCache? = nil, geometrySessionID: String? = nil, disclosure: TranscriptDisclosure? = nil,
         toolInputs: TranscriptToolInputs? = nil) {
        self.item = item; self.fresh = fresh; self.actions = actions; self.environment = environment
        self.geometryCache = geometryCache; self.geometrySessionID = geometrySessionID
        self.disclosureStore = disclosure
        self.toolInputs = toolInputs
        self.disclosure = disclosure.map { TranscriptRowDisclosure.of(item, in: $0, inputs: toolInputs) } ?? .default
        super.init(frame: .zero)
        // A row never paints outside itself, so a transient mismatch between a
        // resizing host and its frame can never draw over the next row.
        clipsToBounds = true
    }
    /// The row's SwiftUI tree, built if this is the first time it is needed.
    @discardableResult private func host() -> TranscriptRowHostingView {
        if let hosted { return hosted }
        let started = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        defer { if TranscriptLayoutClock.recording {
            TranscriptLayoutClock.hostBuildSeconds += TranscriptLayoutClock.now - started
            TranscriptLayoutClock.hostBuilds += 1
        } }
        let view = TranscriptRowHostingView(rootView: hostedRow())
        view.owner = self
        view.sizingOptions = [.intrinsicContentSize]
        view.safeAreaRegions = []
        hosted = view
        awaitingViewportLayout = true
        view.frame = bounds.width > 0 ? bounds : CGRect(x: 0, y: 0, width: width, height: 1)
        addSubview(view)
        return view
    }
    required init?(coder: NSCoder) { return nil }
    /// Where this row sits in the page, so the document can say from which
    /// row down a pass has to place anything.
    var layoutIndex = 0
    /// How many tokens this row has taken by extending the reply's own native
    /// surface, without SwiftUI rebuilding or re-sizing its tree.
    private(set) var streamingAppendCount = 0
    /// Tokens taken since this row was last measured for real. Every so often
    /// one is measured properly, so a long reply cannot drift away from what
    /// its tree actually needs.
    private var tokensSinceMeasured = 0
    static let tokensPerMeasurement = 64
    /// True while this row's reply has grown with no tree to grow: the reader
    /// is reading elsewhere. The page may stand it at an estimate until they
    /// come back, exactly as it stands unseen history.
    private(set) var grewWithoutATree = false
    /// True while the height this row holds came from the message's own
    /// surface measuring the block a token extended. The hosting view
    /// invalidates its intrinsic size for that same change; validating it
    /// would put the whole row through SwiftUI again for a height the row
    /// already has, and that second pass is most of what a token used to cost.
    private var streamingHeightKnown = false
    /// The surface carrying a reply, found once and kept while it streams.
    private weak var streamingSurface: NativeMarkdownContainer?
    private var streamingSurfaceID = ""
    private func surface(for messageID: String) -> NativeMarkdownContainer? {
        if let streamingSurface, streamingSurfaceID == messageID, streamingSurface.superview != nil,
           streamingSurface.readingIdentity == messageID { return streamingSurface }
        guard let hosted else { return nil }
        func visit(_ view: NSView) -> NativeMarkdownContainer? {
            if let surface = view as? NativeMarkdownContainer { return surface.readingIdentity == messageID ? surface : nil }
            for child in view.subviews { if let found = visit(child) { return found } }
            return nil
        }
        let found = visit(hosted)
        streamingSurface = found; streamingSurfaceID = messageID
        return found
    }
    /// A native surface in this row measured blocks it had stood at an
    /// estimate — the reader scrolled onto them, or a token opened one — and
    /// its text is that much taller or shorter. The row is the rest of it plus
    /// that text, so it changes by the same amount; neither a row that took
    /// its height from the surface token by token nor one measured whole
    /// hears its hosting tree resize, and the difference stood as a gap under
    /// the reply, or its last lines cut off, until the next full measurement.
    func surfaceResolved(_ delta: CGFloat) {
        // Measuring right now: the height this pass arrives at includes it.
        guard !measuring, let cached = measurements.last(where: { $0.width == width }) else { return }
        measurements = [CGSize(width: cached.width, height: max(1, cached.height + delta))]
        if let hosted, hosted.frame.height != measurements[0].height {
            hosted.frame = CGRect(x: 0, y: 0, width: cached.width, height: measurements[0].height)
        }
        if let cache = geometryCache, let sessionID = geometrySessionID, let scale = measurementScale {
            cache.invalidate(sessionID: sessionID, item: item, width: cached.width, backingScale: scale)
        }
        // The surface resolves as it is laid out, which can be inside the
        // document's own pass; the page is placed again after it, as for any
        // other row whose height changed.
        DispatchQueue.main.async { [weak self] in self?.onHeightInvalidated?() }
    }
    /// Returns whether anything that decides this row's height changed.
    @discardableResult
    func update(item: TranscriptItem, fresh: Bool, actions: TranscriptActions, environment: TranscriptRowEnvironment = TranscriptRowEnvironment()) -> Bool {
        self.actions = actions
        let sameItem = self.item == item
        // New content can bring parts the reader already opened or closed.
        // Otherwise what the row shows open changes only when the reader
        // opens or closes something, or a card's document lands: not with
        // every token of a reply somewhere else on the page.
        let disclosure: TranscriptRowDisclosure
        let revisions = (disclosureStore?.revision ?? -1, toolInputs?.revision ?? -1)
        if sameItem, revisions == disclosureRevisions { disclosure = self.disclosure }
        else {
            if TranscriptLayoutClock.recording { TranscriptLayoutClock.disclosureReads += 1 }
            disclosure = disclosureStore.map { TranscriptRowDisclosure.of(item, in: $0, inputs: toolInputs) } ?? .default
        }
        disclosureRevisions = revisions
        guard !sameItem || self.fresh != fresh || self.environment != environment || self.disclosure != disclosure else { return false }
        // Only how the row is painted changed: it is drawn with the new values
        // and keeps every height it has.
        if sameItem, self.fresh == fresh, self.disclosure == disclosure, self.environment.hasSameGeometry(as: environment) {
            self.environment = environment
            measuring = true
            updateRoot()
            measuring = false
            return false
        }
        // A token: the reply's own surface takes the text and says how much
        // taller the message became. The row's SwiftUI tree is not rebuilt and
        // not sized again — the one measurement it already has is adjusted by
        // that much, and the page places itself around the new height in this
        // same pass.
        // Every so often the row is measured properly again, so a long reply
        // cannot drift away from what its tree actually needs.
        // A reply arriving below (or above) the reader's screen has no tree at
        // all: the reader scrolled well past it. Building and laying one out
        // for every token of a reply nobody can see is what made scrolling
        // during a reply expensive. Such a row stands at an estimate of its
        // own growth, is never drawn at it, and is measured properly when the
        // reader comes back to it.
        let tail = TranscriptStreamingTail.append(from: self.item, to: item)
        let unchangedOtherwise = self.fresh == fresh && self.environment == environment && self.disclosure == disclosure
            && pinnedContentHeight == nil
        if hosted == nil, unchangedOtherwise, tail != nil {
            self.item = item
            measurements.removeAll(keepingCapacity: true)
            estimate = nil
            grewWithoutATree = true
            restoredMeasurementNeedsValidation = false
            if TranscriptLayoutClock.recording { TranscriptLayoutClock.streamingEstimates += 1 }
            return true
        }
        if unchangedOtherwise, tokensSinceMeasured < Self.tokensPerMeasurement, let append = tail,
           let surface = surface(for: append.messageID), let cached = measurements.last(where: { $0.width == width }) {
            measuring = true
            let grew = surface.appendStreaming(append.text, identity: append.messageID)
            measuring = false
            if let grew {
                grewWithoutATree = false
                self.item = item
                streamingAppendCount += 1; tokensSinceMeasured += 1
                estimate = nil
                measurements = [CGSize(width: cached.width, height: max(1, cached.height + grew))]
                if let hosted, hosted.frame.height != measurements[0].height {
                    hosted.frame = CGRect(x: 0, y: 0, width: cached.width, height: measurements[0].height)
                }
                streamingHeightKnown = true
                if TranscriptLayoutClock.recording { TranscriptLayoutClock.streamingAppends += 1 }
                return grew != 0
            }
        }
        let oldItem = self.item
        let fixedClosedPart: Bool = {
            guard case .block(let old) = self.item, case .block(let new) = item,
                  old.presentation == new.presentation, old.presentation == .timeline || old.presentation == .work,
                  let a = old.part, let b = new.part,
                  !self.disclosure.work, !disclosure.work,
                  self.disclosure.openTools.isEmpty, disclosure.openTools.isEmpty,
                  !["text", "refusal", "status"].contains(a.part.kind) else { return false }
            // A call's card is one line while it is closed, whatever its
            // arguments say, so it keeps its height while they arrive — as
            // long as it is still the same call in the same state.
            if old.presentation == .work {
                guard let was = old.message?.tools?.first, let now = new.message?.tools?.first,
                      was.id == now.id, was.name == now.name, was.state == now.state else { return false }
            }
            // Everything the reader has opened or closed must agree, not only
            // this row's own work fold: a card whose whole response has just
            // been folded changes height although its own text has not.
            return self.disclosure == disclosure && self.environment == environment && self.fresh == fresh &&
                a.part.kind == b.part.kind && a.part.name == b.part.name && a.state == b.state
        }()
        let fixedClosedWork: Bool = {
            guard case .block(let old) = self.item, case .block(let new) = item else { return false }
            // Timeline tool cards have their own disclosure and live summary.
            // Only an unchanged, closed aggregate work list has fixed geometry.
            return old.presentation == .work && new.presentation == .work && old.part == nil && new.part == nil &&
                !self.disclosure.work && self.disclosure == disclosure &&
                self.environment == environment && self.fresh == fresh
        }()
        self.item = item; self.fresh = fresh; self.environment = environment; self.disclosure = disclosure
        if fixedClosedPart {
            // The collapsed line keeps its height, but its latest reasoning
            // text still needs to reach the view while the reply streams.
            updateRoot()
            return false
        }
        if fixedClosedWork {
            workList = nil
            if case .block(let old) = oldItem, case .block(let new) = item,
               old.live != new.live || old.task?.outcome != new.task?.outcome ||
               old.taskSummary?.tools != new.taskSummary?.tools || old.taskSummary?.partial != new.taskSummary?.partial ||
               old.taskSummary?.toolCountPartial != new.taskSummary?.toolCountPartial {
                updateRoot()
            }
            return false
        }
        if TranscriptLayoutClock.recording, TranscriptStreamingTail.textGrew(from: oldItem, to: item) {
            TranscriptLayoutClock.streamingRebuilds += 1
        }
        streamingHeightKnown = false
        measurements.removeAll(keepingCapacity: true)
        estimate = nil
        if hosted != nil { awaitingViewportLayout = true }
        // Prose, freshness and the turn footer still remeasure the outer row,
        // but do not throw away unchanged tool/reasoning geometry.
        if workList?.key != workListKey { workList = nil }
        restoredMeasurementNeedsValidation = false
        updateRoot()
        invalidateIntrinsicContentSize()
        return true
    }
    /// Only a new, unmeasured native host can borrow default-state geometry.
    /// No retained local disclosure state is ever replaced by a shared size.
    func restoreSharedMeasurement(width: CGFloat, backingScale: CGFloat) {
        guard measurementCount == 0, measurements.isEmpty, let geometryCache, let geometrySessionID,
              TranscriptGeometryCache.permits(item),
              let size = geometryCache.measurement(sessionID: geometrySessionID, item: item, fresh: fresh,
                                                   environment: environment, disclosure: disclosure,
                                                   width: width, backingScale: backingScale) else { return }
        measurements = [size]; measurementScale = backingScale
        restoredMeasurementNeedsValidation = true
        sharedMeasurementHits += 1
        if self.width != width {
            measuring = true
            self.width = width; updateRoot()
            measuring = false
        }
    }
    /// Once a borrowed baseline enters the viewport, resolve actual native
    /// text at its drawn width before accepting that mounted measurement.
    func validateSharedMeasurementAfterMount() {
        if restoredMeasurementNeedsValidation, window != nil, hosted != nil { contentSizeChanged() }
    }
    private func hostedRow() -> TranscriptHostedRow {
        // The relay reads the latest callbacks without replacing unchanged
        // SwiftUI text fields merely because their parent's closures changed.
        let relay = TranscriptActions(inspect: { [weak self] in self?.actions.inspect($0) }, edit: { [weak self] in self?.actions.edit($0) },
                                      copyMessage: { [weak self] in self?.actions.copyMessage($0) }, stop: { [weak self] in self?.actions.stop() }, retry: { [weak self] in self?.actions.retry() },
                                      inspectTurn: { [weak self] in self?.actions.inspectTurn?($0) },
                                      skillPressed: { [weak self] in self?.actions.skillPressed?($0, $1, $2) },
                                      skillHovered: { [weak self] in self?.actions.skillHovered?($0, $1, $2, $3) },
                                      costLimit: { [weak self] in self?.actions.costLimit?($0, $1) })
        let key = workListKey
        let known = workList?.key == key ? workList?.height : nil
        if known != nil { workListReuses += 1 }
        return TranscriptHostedRow(item: item, fresh: fresh, actions: relay, width: width, environment: environment,
                                   disclosure: disclosure, toggle: { [weak self] part in self?.toggleDisclosure(part) },
                                   workListHeight: known,
                                   workListMeasured: { [weak self] height in
                                       guard let self, self.workListKey == key else { return }
                                       self.workList = (key, height)
                                   },
                                   foldInMotion: keepingFoldedContent)
    }
    /// Rebuilds the tree, if this row is holding one. A row with no host has
    /// nothing to rebuild: it builds the current content when it is next
    /// measured or mounted.
    private func updateRoot() {
        guard let hosted else { return }
        let started = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        defer { if TranscriptLayoutClock.recording {
            TranscriptLayoutClock.rootUpdateSeconds += TranscriptLayoutClock.now - started
            TranscriptLayoutClock.rootUpdates += 1
        } }
        hosted.rootView = hostedRow()
    }
    /// A click on a disclosure: record it, rebuild this row's content and drop
    /// its measurements, then let the document lay out now. Nothing waits for a
    /// hosting view to notice its own intrinsic size changed.
    func toggleDisclosure(_ part: TranscriptDisclosure.Part) {
        guard let disclosureStore else { return }
        disclosureStore.toggle(part)
        // A card the reader just opened whose arguments the host had to cut
        // asks for the rest, once. The card draws the inline document until it
        // lands, and this row is measured again when it does.
        if disclosureStore.isOpen(part), let card = TranscriptToolInputs.cutCard(part, in: item) {
            onToolInputNeeded?(card.messageID, card.callID)
        }
        let updated = TranscriptRowDisclosure.of(item, in: disclosureStore, inputs: toolInputs)
        disclosureRevisions = (disclosureStore.revision, toolInputs?.revision ?? -1)
        guard updated != disclosure else { return }
        disclosure = updated
        measurements.removeAll(keepingCapacity: true)
        restoredMeasurementNeedsValidation = false
        // The document measures and lays this row out immediately below, so the
        // hosting view must not also schedule its own deferred re-validation:
        // that would lay the same tree out a second and third time per click.
        measuring = true
        updateRoot()
        measuring = false
        invalidateIntrinsicContentSize()
        onDisclosureChanged?()
    }
    func measure(width proposed: CGFloat?) -> CGSize {
        // SwiftUI probes zero while discovering minimum sizes. It is not the
        // row's actual wrapping width and must not pin the parent's minimum.
        if proposed == 0 { return .zero }
        let target = proposed.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? width
        // A VStack probes the ideal page width as well as the actual viewport
        // width on every update. Keep both exact results; changing the root for
        // an already known speculative width would redo native text layout.
        if let cached = measurements.last(where: { $0.width == target }) { return cached }
        let clock = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        defer {
            if TranscriptLayoutClock.recording {
                TranscriptLayoutClock.measureSeconds += TranscriptLayoutClock.now - clock
                TranscriptLayoutClock.measuredRows += 1
            }
        }
        measuring = true
        defer {
            measuring = false
            // Keep first-mount rows attached until a later fitting pass agrees
            // with their exact size. Only then is a value shared across tabs.
            if geometryCache != nil, TranscriptGeometryCache.permits(item) { contentSizeChanged() }
        }
        if width != target { width = target; updateRoot() }
        let hosted = host()
        // One native pass. The host is given the width the text wraps at and
        // laid out; the height it settles on is read from that same pass
        // through the intrinsic size SwiftUI has just computed, so nothing
        // asks it to size the tree a second time for the same answer. The
        // root is vertically fixed, so the frame's own height never moves it.
        if hosted.frame.width != target { hosted.frame = CGRect(x: 0, y: 0, width: target, height: max(1, hosted.frame.height)) }
        let sizingStart = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
        hosted.layoutSubtreeIfNeeded()
        let intrinsic = hosted.intrinsicContentSize.height
        // A host that has not published one yet is asked directly; that is a
        // second pass, and the count is what says how often it happens.
        let height = intrinsic > 0 ? max(1, ceil(intrinsic)) : max(1, ceil(hosted.fittingSize.height))
        nativeSizingPasses += intrinsic > 0 ? 1 : 2
        if TranscriptLayoutClock.recording {
            TranscriptLayoutClock.rowSizingPasses += intrinsic > 0 ? 1 : 2
            TranscriptLayoutClock.rowSizingSeconds += TranscriptLayoutClock.now - sizingStart
        }
        // Leave the tree at the size the row is about to be given, so the
        // frame the document sets a moment later is the height it was just
        // laid out at and nothing is laid out again before it is drawn.
        if hosted.frame.height != height {
            let started = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
            hosted.frame = CGRect(x: 0, y: 0, width: target, height: height)
            hosted.layoutSubtreeIfNeeded()
            if TranscriptLayoutClock.recording { TranscriptLayoutClock.placementSeconds += TranscriptLayoutClock.now - started }
        }
        let result = CGSize(width: target, height: height)
        if measurements.count == 4 { measurements.removeFirst() }
        measurements.append(result); measurementCount += 1
        grewWithoutATree = false; streamingHeightKnown = false; tokensSinceMeasured = 0
        measurementScale = window?.backingScaleFactor
        needsLayout = true
        return result
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let scale = window?.backingScaleFactor, let previous = measurementScale, scale != previous else { return }
        measurements.removeAll(keepingCapacity: true)
        workList = nil
        restoredMeasurementNeedsValidation = false; streamingHeightKnown = false
        measurementScale = scale
        invalidateIntrinsicContentSize()
        onHeightInvalidated?()
    }
    override func layout() {
        super.layout()
        // While a disclosure is moving, the tree keeps the height it was
        // measured at and the row's own frame does the moving.
        if let pinnedContentHeight {
            let target = CGRect(x: 0, y: 0, width: bounds.width, height: pinnedContentHeight)
            if let hosted, hosted.frame != target { hosted.frame = target }
            return
        }
        // A sizing probe need not be the width eventually drawn. Bind the
        // hosted content to its real bounds here, without invalidating exact
        // measurements merely because a different proposal was probed last.
        if bounds.width > 0, width != bounds.width {
            measuring = true
            width = bounds.width; updateRoot()
            measuring = false
        }
        if let hosted, hosted.frame != bounds { hosted.frame = bounds }
    }
    var hasProvisionalMarkdown: Bool {
        func provisional(_ view: NSView) -> Bool {
            if let markdown = view as? NativeMarkdownContainer, markdown.hasProvisionalGeometry { return true }
            for child in view.subviews { if provisional(child) { return true } }
            return false
        }
        guard let hosted else { return false }; return provisional(hosted)
    }
    var visibleContentPrepared: Bool {
        func prepared(_ view: NSView) -> Bool {
            if let markdown = view as? NativeMarkdownContainer { return markdown.visibleContentPrepared }
            for child in view.subviews { if !prepared(child) { return false } }
            return true
        }
        guard let hosted else { return false }; return prepared(hosted)
    }
    fileprivate func contentSizeChanged() {
        if TranscriptLayoutClock.recording { TranscriptLayoutClock.intrinsicInvalidations += 1 }
        // The host also invalidates while answering fittingSize. That call
        // supplies the new exact measurement; it need not schedule itself.
        guard !measuring else { return }
        // While the document is moving this row between two measured
        // heights, it owns the geometry: the tree is deliberately taller
        // than the frame and has nothing to report.
        guard pinnedContentHeight == nil else { return }
        // A token the message's own surface has already measured: the row has
        // the new height, and the page has already been placed around it.
        guard !streamingHeightKnown else { return }
        guard !invalidationPending else { return }
        invalidationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer {
                self.invalidationPending = false
                self.onHeightValidated?()
            }
            // Reports retains this tree but hides its native scroll surface.
            // Reflow its latest revision when shown, not behind the report.
            if self.isHiddenOrHasHiddenAncestor { self.onHeightInvalidated?(); return }
            // Removing/reinserting the same host also invalidates its AppKit
            // intrinsic-size observation. Keep exact geometry unless its
            // actual height changed; otherwise scrolling causes a reflow loop.
            if let cached = self.measurements.last(where: { $0.width == self.width }) {
                guard self.window != nil, let hosted = self.hosted else {
                    // Measured in a window and detached since — a row the page
                    // measured in a slice, or one the reader scrolled past.
                    // The measurement stands, so share it rather than drop it;
                    // a baseline this row only borrowed is not shared again
                    // until a mounted pass has confirmed it.
                    if self.measurementCount > 0, !self.restoredMeasurementNeedsValidation,
                       let cache = self.geometryCache, let sessionID = self.geometrySessionID, let scale = self.measurementScale {
                        cache.store(cached, sessionID: sessionID, item: self.item, fresh: self.fresh,
                                    environment: self.environment, disclosure: self.disclosure, backingScale: scale)
                    }
                    return
                }
                self.measuring = true
                // One native pass, as in `measure`: laying the host out and
                // then asking its fitting size runs SwiftUI's sizing twice.
                let started = TranscriptLayoutClock.recording ? TranscriptLayoutClock.now : 0
                let height = max(1, ceil(hosted.fittingSize.height))
                if TranscriptLayoutClock.recording { TranscriptLayoutClock.validationSeconds += TranscriptLayoutClock.now - started }
                self.intrinsicValidationCount += 1
                self.measuring = false
                self.restoredMeasurementNeedsValidation = false
                if height == cached.height {
                    if !self.hasProvisionalMarkdown, let cache = self.geometryCache, let sessionID = self.geometrySessionID,
                       let scale = self.window?.backingScaleFactor, self.measurementScale == scale {
                        cache.store(cached, sessionID: sessionID, item: self.item, fresh: self.fresh, environment: self.environment,
                                    disclosure: self.disclosure, backingScale: scale)
                    }
                    return
                }
                if let cache = self.geometryCache, let sessionID = self.geometrySessionID, let scale = self.measurementScale {
                    cache.invalidate(sessionID: sessionID, item: self.item, width: cached.width, backingScale: scale)
                }
            }
            self.measurements.removeAll(keepingCapacity: true)
            self.invalidateIntrinsicContentSize()
            self.onHeightInvalidated?()
        }
    }
}

struct NativeTranscriptView: View {
    @ObservedObject var session: SessionDisplay
    /// The session's run state, observed by the pane and handed down so the live bar follows it.
    var state = "idle"
    let actions: TranscriptActions
    var onAnchorChanged: (TranscriptAnchor?) -> Void = { _ in }
    var onReadReply: (String, String) -> Void = { _, _ in }
    var onLoadEarlier: (String) -> Void = { _ in }
    var onLoadNewer: (String) -> Void = { _ in }
    var onLatest: (String) -> Void = { _ in }
    var onViewportReady: (String, UUID) -> Void = { _, _ in }
    @StateObject private var page = TranscriptPage()
    @Environment(\.piReduceMotion) private var reduceMotion
    /// Set once a read at that edge has run past `TranscriptEdge.quietLoad`.
    @State private var earlierSlow = false
    @State private var newerSlow = false

    private var earlierEdge: TranscriptEdge {
        .earlier(session.olderPage, slow: earlierSlow, waitsForReader: page.earlierWaitsForReader)
    }
    private var newerEdge: TranscriptEdge { .newer(session.newerPage, slow: newerSlow) }
    /// What stands beside the Back to bottom circle: a word or a spinner.
    private var newerBeside: TranscriptEdge {
        switch newerEdge { case .loading, .waiting: return newerEdge; default: return .quiet }
    }
    /// What is said above it: a read that failed, or a page that lost its place.
    private var newerAbove: TranscriptEdge {
        switch newerEdge { case .failed, .changed: return newerEdge; default: return .quiet }
    }
    /// The question a turn that starts before the page began with, shown on
    /// its own while the top edge has nothing else to say.
    private var partialTurnInput: String? {
        switch earlierEdge {
        case .quiet, .loading: return session.presentation.partialTurnInput
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = page.projectionError { PiNote(error).padding(8) }
            TranscriptScrollSurface(revision: page.snapshot?.sequence ?? 0, page: page, actions: actions)
                // The rows beyond either edge are read as the reader reaches
                // them, and the edges float over the conversation: what comes
                // and goes there never changes the transcript's frame, so no
                // row moves for it.
                .overlay(alignment: .top) {
                    TranscriptEarlierEdge(state: earlierEdge, partialTurnInput: session.presentation.partialTurnInput,
                                          load: { onLoadEarlier(session.id) }, inspect: actions.inspect)
                        .padding(.top, 10).padding(.horizontal, 16)
                        .animation(reduceMotion ? nil : PiMotion.quick, value: earlierEdge)
                }
                .overlay(alignment: .topTrailing) {
                    ZStack {
                        if let input = partialTurnInput {
                            TranscriptPartialTurnChip(input: input, inspect: actions.inspect).transition(.opacity)
                        }
                    }
                    .padding(.top, 10).padding(.trailing, 18)
                    .animation(reduceMotion ? nil : PiMotion.quick, value: partialTurnInput)
                }
                // Whenever the reader is not standing at the bottom — however
                // they came to be away from it — the way back is one circle
                // floating over the end of the conversation. An older window
                // offers the rows after it beside that circle.
                .overlay(alignment: .bottom) {
                    ZStack {
                        if !page.atBottom || session.newerPage.available, page.snapshot?.items.isEmpty == false {
                            PiBackToBottomPill { if session.browsingHistory || session.newerPage.available { onLatest(session.id) } else { page.jumpToLatest() } }
                                .background(TranscriptEdgeMarker(edge: "newer", kind: "latest", text: "Jump to the latest message", action: {
                                    if session.browsingHistory || session.newerPage.available { onLatest(session.id) } else { page.jumpToLatest() }
                                }))
                                // Beside the circle, not in a row with it: the
                                // circle stays where it is whatever shows there.
                                .overlay(alignment: .leading) {
                                    TranscriptNewerEdge(state: newerBeside, load: { onLoadNewer(session.id) }, reload: { onLatest(session.id) })
                                        .fixedSize()
                                        .alignmentGuide(.leading) { $0[.trailing] + 8 }
                                        .animation(reduceMotion ? nil : PiMotion.quick, value: newerBeside)
                                }
                                .padding(.bottom, 12)
                                .transition(.opacity.combined(with: .offset(y: 6)).combined(with: .scale(scale: 0.92)))
                        }
                    }
                    .animation(reduceMotion ? nil : PiMotion.spring, value: page.atBottom)
                }
                .overlay(alignment: .bottom) {
                    TranscriptNewerEdge(state: newerAbove, load: { onLoadNewer(session.id) }, reload: { onLatest(session.id) })
                        .frame(maxWidth: 440)
                        .padding(.horizontal, 16).padding(.bottom, 12 + PiBackToBottomPill.diameter + 8)
                        .animation(reduceMotion ? nil : PiMotion.quick, value: newerAbove)
                }
            // Parent panel or status changes must not animate the document's
            // frame. Row disclosures and the Back to bottom pill set their own motion.
            .transaction { $0.animation = nil }
            LiveTurnBarSlot(turn: page.liveTurn, state: page.state, actions: actions, reduceMotion: reduceMotion)
                .id(session.presentationGeneration)
        }
        // The run state is read where it is used, never from the value this
        // body happened to be built with: a task runs a turn of the run loop
        // later, and a status that lands in between would otherwise be
        // overwritten by a stale "idle" that nothing corrects — no spinner, no
        // elapsed time and no Stop for the whole run.
        .onChange(of: state, initial: true) { _, value in page.state = value }
        .task(id: session.presentationGeneration) {
            page.onAnchorChanged = onAnchorChanged; page.onReadReply = onReadReply; page.onLoadEarlier = onLoadEarlier; page.onViewportReady = onViewportReady
            page.state = session.state
            page.bind(session)
        }
        // A read shows at its edge only once it has been slow for a moment.
        .task(id: session.olderPage.loading) {
            earlierSlow = false
            guard session.olderPage.loading else { return }
            try? await Task.sleep(for: TranscriptEdge.quietLoad)
            if !Task.isCancelled, session.olderPage.loading { earlierSlow = true }
        }
        .task(id: session.newerPage.loading) {
            newerSlow = false
            guard session.newerPage.loading else { return }
            try? await Task.sleep(for: TranscriptEdge.quietLoad)
            if !Task.isCancelled, session.newerPage.loading { newerSlow = true }
        }
    }
}

/// The live bar's slot at the foot of the conversation. The slot itself is
/// a layout change and never animates: it opens in one step when a run
/// starts and closes in one step once the bar has gone, so the conversation
/// above it changes height exactly once and the document holds the reader's
/// row through that one change as it does through any other. The bar then
/// slides up into the slot and fades in, and slides back down and fades out
/// when the run settles — an offset and an opacity, which decide no
/// layout and so cost the page nothing per tick. Reduce Motion snaps.
private struct LiveTurnBarSlot: View {
    let turn: TurnSummary?
    let state: String
    let actions: TranscriptActions
    let reduceMotion: Bool
    @State private var arrived = false
    var body: some View {
        // No delayed exit owns a second structural mutation. The snapshot that
        // inserts a terminal summary also releases (or retargets) this slot.
        Group {
            if let turn {
                LiveTurnBar(turn:turn, state:state, actions:actions)
                    .padding(.horizontal,16).padding(.bottom,8)
                    .opacity(arrived ? 1 : 0).offset(y:arrived ? 0 : 14)
                    .onAppear { if reduceMotion { arrived = true } else { withAnimation(PiMotion.base) { arrived = true } } }
            }
        }.onChange(of:turn == nil) { _, absent in if absent { arrived = false } }
    }
}
