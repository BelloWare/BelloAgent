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
        return Self.liveTurn(busy: busy)
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
    var busy: Bool { RunState(rawValue: state).isBusy }

    var onAnchorChanged: (TranscriptAnchor?) -> Void = { _ in }
    var onReadReply: (String, String) -> Void = { _, _ in }
    var onLoadEarlier: (String) -> Void = { _ in }
    var onLoadNewer: (String) -> Void = { _ in }
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

    // MARK: Who places the reader
    //
    // Where the page puts the reader is decided by the flags below, and each
    // is set and cleared only where this says:
    //
    // - `followsBottom`: the page keeps the newest row in view. True after
    //   `reset` and `jumpToLatest`, and as a page opens it takes the chat's
    //   saved anchor (`receive`). From then on the reader decides it through
    //   the bottom band (`setPinned`, `pinIfAtLatest`), going up unpins it at
    //   once (`readerWillNavigate`), and the opening placement unpins it to
    //   hold the last question (`resolveOpeningPlacement`).
    // - `atBottom`: the reader stands in the bottom band now: the geometry's
    //   answer, which the Back to bottom pill shows. `detached` is the page's
    //   own answer, which only the tests read.
    // - `jumping`: a jump to the newest row is animating (`jumpToLatest`).
    //   Nothing else moves the reader until it lands, or for 1.5 s at most.
    // - `pendingAnchor`, with `explicitDestination` when the reader asked for
    //   it: a row to land on — a saved position, the row a reflow must keep
    //   the reader on, a destination. `settle` clears it once it has landed.
    // - `openingPlacementPending`, then `openingReadingAnchor`: a chat opened
    //   idle starts at the question of its last turn when that turn does not
    //   fit. Pending until the rows are placed (`resolveOpeningPlacement`),
    //   then the question is held while the rows above it measure.
    // - `awaitingFirstPlacement`: from a new page until its first landing
    //   (`layoutPlacement`, `settle`). Until then the document's geometry is
    //   the chat shown before.
    // - `viewportResizePending`: the viewport changed height, and AppKit may
    //   still move the origin; those moves are layout's, not the reader's.
    // - `joiningLatest`: the reader stands at the end of a window with rows
    //   after it, which join below them until the window reaches the latest.
    //
    // A movement of the reader's (`readerOwnsPosition`) drops everything the
    // page still meant to do: the anchor, the opening placement, a jump.
    // Every writer keeps these true, and a change should too: `jumping` and
    // `openingPlacementPending` each imply `followsBottom`, and an
    // `openingReadingAnchor` implies it is false.
    private var initialized = false
    private(set) var followsBottom = true { didSet { syncReadingOwnership() } }
    /// The reader stood at the end of a window with rows after it, which the
    /// page does not follow: the rows read in join below them. Once the
    /// window reaches the latest, the bottom band decides again.
    private var joiningLatest = false
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
    /// True from a new page or viewport request until the page has landed its
    /// first placement. Until the document has laid this page's rows out,
    /// its geometry is the chat shown before: a placement worked out against
    /// it landed on that chat's height and drew the new rows where the old
    /// chat was scrolled to, for the frames until the rows were placed.
    private var awaitingFirstPlacement = false
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
        joiningLatest = false
        awaitingFirstPlacement = true
        viewportResizePending = false
        settleScheduled = false; readCheckScheduled = false
        seen = []; completedAssistant = nil; firstRow = ""; jumping = false
    }

    /// The rows the page draws: the display's own. The display is the one
    /// owner of the resident window — the snapshot loop and every history
    /// read bound what they hold — and it may run past the budget on purpose
    /// while the reader holds a row further up (`WorkspaceRefresh`). Cut here
    /// again, keeping the earliest rows, that window lost its newest ones:
    /// the reply arriving at the live tail.
    nonisolated static func displayPage(_ messages: [TranscriptMessage]) -> [TranscriptMessage] { messages }
    /// The rows the request log is asked about for their figures: the page,
    /// or its newest rows when a held row has stretched it past what one
    /// read may name (`HistoryWindowPolicy.residentRows`). New requests land
    /// at the live end; rows further up keep the figures they already show.
    nonisolated static func accountingPage(_ messages: [TranscriptMessage]) -> [TranscriptMessage] {
        messages.count <= HistoryWindowPolicy.residentRows ? messages : Array(messages.suffix(HistoryWindowPolicy.residentRows))
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
            // The chat's own opening page, read in or shown again on a
            // revisit, is not a jump the reader asked for: it opens as any
            // chat opens. Counted as one, it cancelled the opening placement
            // the page had already drawn, and a revisit drew the last question
            // and then jumped to the bottom a few frames later.
            navigated = navigating && !session.viewportRequestOpens
        }
        if snapshot?.messages.first?.id != messages.first?.id, viewportRequest == request {
            preserveReadingPositionForLayout()
        }
        let page = Self.displayPage(messages)
        let patch = snapshot.flatMap { current in
            Self.sameLifecycle(current.lifecycle, input.lifecycle) ? TranscriptActivity.patch(current.items, from: current.messages, to: page) : nil
        }
        // A page short of the conversation's newest row — cut by the resident
        // window, or a history window with newer rows after it — may end in
        // the middle of a turn; that turn folds only on its task's receipt.
        let items = patch?.items ?? TranscriptActivity.blocks(of: page, lifecycle: input.lifecycle,
                                                              complete: page.count == messages.count && !session.newerPage.available)
        // A token keeps every row's identity and place (see `patch`), all of
        // them already proved unique and already seen by the page presented.
        // Hashing every id of a long chat again, twice for uniqueness and
        // twice for what is new, was most of what a token cost the page.
        let sameIdentities = patch != nil && initialized
        if !sameIdentities {
            if TranscriptLayoutClock.recording { TranscriptLayoutClock.identityWalks += 1 }
            guard Set(page.map(\.id)).count == page.count, Set(items.map(\.id)).count == items.count else {
                projectionError = "This conversation contains conflicting row identities. The last valid page is retained; inspect the session file to repair it. No history was deleted."
                return
            }
        }
        if projectionError != nil { projectionError = nil }
        if let current = snapshot, current.lifecycle == input.lifecycle, initialized,
           patch.map({ !$0.changed }) ?? (current.messages == page) { return }
        var fresh: Set<String> = []
        if !sameIdentities {
            for message in page {
                if initialized, !seen.contains(message.id) { fresh.insert(message.id) }
                seen.insert(message.id)
            }
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
        if !sameIdentities {
            let ids = Set(items.map(\.id))
            frames = frames.filter { ids.contains($0.key) }
        }
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
    static func liveTurn(busy: Bool) -> TurnSummary? {
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
            // Rows joined below a reader at the end of a window with rows
            // after it. Once the window reaches the latest, the band decides
            // again whether the page follows; until then the next rows are
            // read as the reader nears the end.
            if joiningLatest, reachesLatest { joiningLatest = false; evaluateFollowing() }
            requestNewerIfNearBottom()
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
        // Until the transcript's document has laid this page's rows out, the
        // geometry it reports is the chat shown before: landing on it put the
        // new rows where that chat was scrolled to, and took the place of the
        // first placement the layout pass makes (`layoutPlacement`).
        if awaitingFirstPlacement, scrollView?.documentView is TranscriptNativeDocument,
           let last = snapshot?.items.last, frames[last.id] == nil { return }
        if openingPlacementPending, documentSettled, viewport.height > 0, let snapshot {
            resolveOpeningPlacement(snapshot, bottom: max(0, content.height - viewport.height))
        }
        if openingReadingAnchor != nil, !detached { detached = true }
        if followsBottom {
            pendingAnchor = nil
            // Wait for exact native geometry instead of landing at a stale height.
            if documentSettled { scrollToBottom(); awaitingFirstPlacement = false }
            if detached && !jumping { detached = false }
            requestReadCheck()
            return
        }
        if scrollView?.transcriptReading.restore() == true {
            pendingAnchor = nil; awaitingFirstPlacement = false; requestReadCheck(); return
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
            pendingAnchor = nil; awaitingFirstPlacement = false
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
    /// The reader opened this chat: show the question that started the last
    /// turn, unless the whole turn fits above the bottom anyway.
    private func resolveOpeningPlacement(_ snapshot: Snapshot, bottom: CGFloat) {
        if let lastUser = snapshot.items.last(where: { if case .message(let m) = $0 { return m.role == "user" }; return false }), let frame = frames[lastUser.id] {
            openingPlacementPending = false
            if frame.minY < bottom - 1 {
                followsBottom = false
                pendingAnchor = TranscriptAnchor(id: lastUser.id, offset: Double(TranscriptMetrics.pageTopInset), followsBottom: false)
                openingReadingAnchor = pendingAnchor
            }
        } else if !frames.isEmpty { openingPlacementPending = false }
    }
    /// Where the page belongs, worked out in the layout pass that has just
    /// placed its rows, for the placements only the page makes: its first,
    /// after a chat is opened or its rows shown again, and the question a
    /// chat opened at while the rows above it measure. Landed a run-loop turn
    /// later instead, the frame between drew the new rows where the chat
    /// before was scrolled to, and a question the rows above had moved by
    /// their difference. Nil when the page has nothing to place here; the
    /// reader's own position is the pane's reading correction's to keep.
    func layoutPlacement(contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat? {
        guard initialized, !jumping, viewportHeight > 0, let snapshot, let last = snapshot.items.last, frames[last.id] != nil else { return nil }
        let bottom = max(0, contentHeight - viewportHeight)
        if openingPlacementPending { resolveOpeningPlacement(snapshot, bottom: bottom) }
        if awaitingFirstPlacement, !openingPlacementPending {
            // Where the page was put is remembered once it is there, as it
            // was when the landing came a turn after the first frame.
            if followsBottom { awaitingFirstPlacement = false; scheduleReport(); return bottom }
            if let anchor = pendingAnchor, let frame = frames[rowIdentifier(for: anchor.id)] {
                awaitingFirstPlacement = false; scheduleReport()
                return min(max(0, frame.minY - anchor.offset), bottom)
            }
            return nil
        }
        // Held in the pass while the page places it: the question a chat
        // opened at, and a destination still landing. Once one has landed,
        // the pane's reading correction holds the row the reader is on.
        if !followsBottom, pagePlacesItself, let anchor = pendingAnchor ?? openingReadingAnchor,
           let frame = frames[rowIdentifier(for: anchor.id)] {
            return min(max(0, frame.minY - anchor.offset), bottom)
        }
        return nil
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
            pinIfAtLatest(inBand)
            requestNewerIfNearBottom()
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
        requestNewerIfNearBottom()
        scheduleReport()
    }
    private func evaluateFollowing() {
        guard position.viewport > 0 else { return }
        pinIfAtLatest(isWithinBottomBand)
    }
    /// Whether the page's last row is the conversation's newest: nothing
    /// after it waits to be read.
    private var reachesLatest: Bool {
        guard let session = presentationSession else { return true }
        return session.newerPage.cursor == nil && !session.browsingHistory
    }
    /// Standing in the bottom band pins the page to the newest row, where the
    /// page's end is the conversation's. The end of a window with rows after
    /// it is not: pinned there, the page jumped to the end of the rows read in
    /// below, past the reader. They join under the reader instead, who stays
    /// where they are.
    private func pinIfAtLatest(_ inBand: Bool) {
        let latest = reachesLatest
        joiningLatest = inBand && !latest
        setPinned(inBand && latest)
    }
    /// The reader has come near the end of a window with rows after it: they
    /// are read in and join below, as rows before a window are read in when
    /// the reader nears its top. Once the window reaches the last rows the
    /// history holds, the chat takes its live rows again, and a reply still
    /// being written goes on arriving where the reader is.
    private func requestNewerIfNearBottom() {
        guard position.viewport > 0, !jumping, liveDistanceToBottom < Self.earlierThreshold, let sessionID,
              let session = presentationSession, session.newerPage.cursor != nil, !session.newerPage.loading,
              session.newerPage.error == nil, !session.historyState.loading, session.presentation.readyAt != nil else { return }
        onLoadNewer(sessionID)
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
            // A page this short cannot be scrolled to ask again. Nor does a
            // window fill itself when it could not take another page without
            // letting go of rows it holds: the rows it pushed out would be the
            // ones on screen, and the live tail with them, so a reply being
            // written stopped arriving. The reader asks, at the edge.
            guard session.presentation.automaticFills < HistoryWindowPolicy.automaticFills,
                  TranscriptPaging.takesAnotherPage(session.messages) else {
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
            self.requestNewerIfNearBottom()
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
