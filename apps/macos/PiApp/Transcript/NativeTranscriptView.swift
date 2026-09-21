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
    /// Within this many points of the bottom the page still follows new rows.
    static let followThreshold: CGFloat = 70
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
    }

    @Published private(set) var snapshot: Snapshot?
    @Published var projectionError: String?
    var liveTurn: TurnSummary? {
        if let turn = snapshot?.liveTurn { return turn }
        // Older helpers and the brief pre-snapshot phase only report run state.
        // Keep activity visible without borrowing historical usage or claiming a task completion.
        guard snapshot?.lifecycle?.active == nil, snapshot?.lifecycle?.recent.isEmpty != false else { return nil }
        return Self.liveTurn(in: [], busy: busy)
    }
    @Published private(set) var detached = false
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
    private(set) var followsBottom = true { didSet { scrollView?.transcriptReading.following = followsBottom || explicitDestination } }
    private var readerNavigationStarted = false
    private var upwardNavigation = false
    private var explicitDestination = false
    private var pendingAnchor: TranscriptAnchor? { didSet {
        pendingAnchorRow = nil
        if pendingAnchor == nil { explicitDestination = false }
        scrollView?.transcriptReading.following = followsBottom || explicitDestination
    } }

    /// Which row holds the pending anchor, worked out once. Resolving it for
    /// every row of the page as its frame arrives is quadratic in the page,
    /// and every row's frame arrives on every reflow.
    private var pendingAnchorRow: String?
    /// A chat opened while idle starts at its last question when the last turn does not fit above the bottom.
    private var openingPlacementPending = false
    private var openingReadingAnchor: TranscriptAnchor?
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
        presentationSession = session; lastPresentationAt = 0
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
        reset()
        scrollView?.transcriptReading.bind(scope: session.id + ":" + session.presentationGeneration.uuidString)
        frames = [:]
        snapshot = nil; detached = false
        subscription = session.presentationChanges.combineLatest(session.$viewportRequest).sink { [weak self, weak session] input, request in
            guard let self, let session else { return }
            self.present(input, viewportRequest: request, from: session)
        }
    }
    private func reset() {
        initialized = false; followsBottom = true; pendingAnchor = nil; openingPlacementPending = false; openingReadingAnchor = nil
        settleScheduled = false; readCheckScheduled = false
        seen = []; completedAssistant = nil; firstRow = ""; jumping = false
    }

    /// Defend the source-selected resident window without evicting its reading
    /// anchor. The history/live source already chooses which edge to retain.
    nonisolated static func displayPage(_ messages: [TranscriptMessage]) -> [TranscriptMessage] {
        TranscriptPaging.window(messages, keepingEarlier: true)
    }

    /// One leading and one trailing presentation per pane, not a debounce:
    /// raw history has already been updated before it reaches this boundary.
    /// Tool transitions, first content and every terminal state flush promptly.
    private static func sameLifecycle(_ lhs: TaskPresentationProjection?, _ rhs: TaskPresentationProjection?) -> Bool {
        guard var lhs, let rhs else { return lhs == rhs }
        lhs.sequence = rhs.sequence; lhs.sourceRevision = rhs.sourceRevision
        return lhs == rhs
    }

    private func present(_ input: TranscriptPresentationInput, viewportRequest request: Int, from session: SessionDisplay) {
        let textDelta = projectionError == nil && viewportRequest == request && Self.sameLifecycle(snapshot?.lifecycle, input.lifecycle) &&
            TaskTranscriptPlan.cosmetic(from: snapshot?.messages ?? [], to: input.messages)
        let delay = presentationInterval - (ProcessInfo.processInfo.systemUptime - lastPresentationAt)
        if textDelta, delay > 0 {
            pendingPresentation = (input, request)
            guard presentationTask == nil else { return }
            presentationTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.presentationTask = nil
                guard let pending = self.pendingPresentation, let session = self.presentationSession else { return }
                self.pendingPresentation = nil
                self.receive(pending.input, viewportRequest: pending.request, from: session)
            }
        } else {
            presentationTask?.cancel(); presentationTask = nil; pendingPresentation = nil
            receive(input, viewportRequest: request, from: session)
        }
    }

    private func receive(_ input: TranscriptPresentationInput, viewportRequest request: Int, from session: SessionDisplay) {
        guard session.id == sessionID, session.presentationGeneration == generation else { return }
        let messages = input.messages
        if viewportRequest != request {
            // A jump to the latest page or a prepended earlier page: the page starts over from the session's anchor.
            let navigating = viewportRequest != nil
            viewportRequest = request
            reset()
            explicitDestination = navigating && session.scrollAnchor?.followsBottom == false
        }
        if snapshot?.messages.first?.id != messages.first?.id, viewportRequest == request {
            preserveReadingPositionForLayout()
        }
        let page = Self.displayPage(messages)
        let patched = snapshot.flatMap { current in
            Self.sameLifecycle(current.lifecycle, input.lifecycle) ? TranscriptActivity.patched(current.items, from: current.messages, to: page) : nil
        }
        let items = patched ?? TranscriptActivity.blocks(of: page, lifecycle: input.lifecycle)
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
            openingPlacementPending = followsBottom && !busy && !page.isEmpty
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
        let next = Snapshot(sessionID: session.id, generation: generation, messages: page, items: items, fresh: fresh, sequence: sequence, lifecycle: input.lifecycle, liveTurn: TaskTranscriptPlan.live(input.lifecycle, messages: messages))
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
        self.scrollView = scrollView
        guard let scrollView else { return }
        scrollView.transcriptReading.bind(scope: (sessionID ?? "") + ":" + (generation?.uuidString ?? ""))
        scrollView.transcriptReading.following = followsBottom || explicitDestination
        let center = NotificationCenter.default
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObservers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReport() }
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
        // A narrower pane makes the same rows taller; a reader at the newest message
        // stays there. The geometry callback runs inside a native update, so the
        // scroll itself waits for the run loop: AppKit and SwiftUI never fight over
        // the scroll position mid-layout, and a resize animation settles once per frame.
        if followsBottom { scheduleSettle() }
        requestReadCheck()
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
            guard scrollView?.documentView != nil else { return }
            pendingAnchor = nil
            scroll(to: frame.minY - anchor.offset, animated: false)
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
    /// Frame of the row that holds a message, relative to the viewport.
    private func viewportFrame(of messageID: String) -> CGRect? {
        guard let frame = frames[rowIdentifier(for: messageID)] else { return nil }
        return frame.offsetBy(dx: 0, dy: -position.offset)
    }

    /// The reader scrolled: decide whether the page still follows the newest
    /// message, show or hide the jump pill, ask for the earlier page near the
    /// top, and a little later remember the anchor and check for a read.
    func readerWillNavigate(upward: Bool) {
        scrollView?.transcriptReading.readerMoved()
        upwardNavigation = readerNavigationStarted ? upwardNavigation || upward : upward; readerNavigationStarted = true
        pendingAnchor = nil; openingPlacementPending = false; openingReadingAnchor = nil
        jumping = false; followsBottom = false
        if !detached { detached = true }
    }
    private func userScrolled(ended: Bool) {
        // The reader's own movement wins over an opening/restoration still waiting for layout.
        pendingAnchor = nil; openingPlacementPending = false; openingReadingAnchor = nil
        jumping = false
        if !readerNavigationStarted { scrollView?.transcriptReading.readerMoved() }
        // Only deliberate arrival at the end resumes following. Proximity
        // after an upward gesture or a resize is not reader intent.
        followsBottom = !upwardNavigation && distanceToBottom <= 0.5
        if detached != !followsBottom { detached = !followsBottom }
        if ended { readerNavigationStarted = false; upwardNavigation = false }
        requestEarlierIfNearTop(scrollY: position.offset)
        scheduleReport()
    }
    private func evaluateFollowing() {
        guard position.viewport > 0 else { return }
        followsBottom = distanceToBottom < Self.followThreshold
        if followsBottom { jumping = false }
        if !jumping, detached != !followsBottom { detached = !followsBottom }
    }
    private func requestEarlierIfNearTop(scrollY: CGFloat) {
        guard scrollY < Self.earlierThreshold, !firstRow.isEmpty, let sessionID, let session = presentationSession,
              !session.historyState.loading, !session.olderPage.loading, session.olderPage.error == nil,
              session.olderPage.cursor != nil, session.presentation.readyAt != nil else { return }
        if content.height <= viewport.height + Self.earlierThreshold {
            guard session.presentation.automaticFills < HistoryWindowPolicy.automaticFills else { return }
            session.presentation.automaticFills += 1
        }
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
    private func reportAnchor() {
        guard let snapshot else { return }
        let scrollY = scrollY
        for item in snapshot.items {
            guard let frame = frames[item.id], frame.maxY - scrollY > 0 else { continue }
            let id: String = { if case .block(let block) = item { return block.message?.id ?? block.activity.first?.id ?? item.id }; return item.id }()
            onAnchorChanged(TranscriptAnchor(id: id, offset: frame.minY - scrollY, followsBottom: followsBottom))
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
        guard let sessionID, let completed = completedAssistant, canRead, let frame = viewportFrame(of: completed) else { return }
        if TranscriptActivity.replyEndIsVisible(top: frame.minY, bottom: frame.maxY, height: frame.height, viewportHeight: viewport.height) {
            onReadReply(sessionID, completed)
        }
    }
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
    var body: some View {
        Group {
            switch item {
            case .message(let message):
                MessageRowView(message: message, actions: actions, disclosure: disclosure, toggle: toggle).equatable()
                    .padding(.top, message.role == "user" ? 14 : 4).padding(.bottom, message.role == "user" ? 4 : 10)
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
    func prepareForTheReader() { host() }
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
    /// Returns whether anything that decides this row's height changed.
    @discardableResult
    func update(item: TranscriptItem, fresh: Bool, actions: TranscriptActions, environment: TranscriptRowEnvironment = TranscriptRowEnvironment()) -> Bool {
        self.actions = actions
        // New content can bring parts the reader already opened or closed.
        let disclosure = disclosureStore.map { TranscriptRowDisclosure.of(item, in: $0, inputs: toolInputs) } ?? .default
        guard self.item != item || self.fresh != fresh || self.environment != environment || self.disclosure != disclosure else { return false }
        let oldItem = self.item
        let fixedClosedPart: Bool = {
            guard case .block(let old) = self.item, case .block(let new) = item,
                  old.presentation == .timeline, new.presentation == .timeline,
                  let a = old.part, let b = new.part,
                  !["text", "refusal", "status"].contains(a.part.kind) else { return false }
            return !self.disclosure.work && !disclosure.work && self.environment == environment && self.fresh == fresh &&
                a.part.kind == b.part.kind && a.part.name == b.part.name && a.state == b.state
        }()
        let fixedClosedWork: Bool = {
            guard case .block(let old) = self.item, case .block(let new) = item else { return false }
            return old.presentation == .work && new.presentation == .work && !self.disclosure.work && !disclosure.work &&
                self.environment == environment && self.fresh == fresh
        }()
        self.item = item; self.fresh = fresh; self.environment = environment; self.disclosure = disclosure
        if fixedClosedPart { return false }
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
    /// Which reply made a call, so the host can be asked for its arguments.
    private func replyOwning(callID: String) -> String? {
        func owner(_ messages: [TranscriptMessage]) -> String? {
            messages.first { ($0.tools ?? []).contains { $0.id == callID } }?.id
        }
        switch item {
        case .message(let message): return owner([message])
        case .block(let block): return owner(block.replies)
        }
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
                                      copyMessage: { [weak self] in self?.actions.copyMessage($0) }, stop: { [weak self] in self?.actions.stop() }, retry: { [weak self] in self?.actions.retry() })
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
        if part.kind == .tool, disclosureStore.isOpen(part) {
            if case .block(let block) = item, block.presentation == .work {
                for reply in block.replies { for tool in reply.tools ?? [] where ToolOccurrence.key(reply.id,tool.id) == part.id {
                    onToolInputNeeded?(reply.id,tool.id)
                } }
            } else if let owner = replyOwning(callID:part.id) { onToolInputNeeded?(owner,part.id) }
        }
        let updated = TranscriptRowDisclosure.of(item, in: disclosureStore, inputs: toolInputs)
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
        measurementScale = window?.backingScaleFactor
        needsLayout = true
        return result
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let scale = window?.backingScaleFactor, let previous = measurementScale, scale != previous else { return }
        measurements.removeAll(keepingCapacity: true)
        workList = nil
        restoredMeasurementNeedsValidation = false
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

    var body: some View {
        VStack(spacing: 0) {
            if session.olderPage.available { boundaryControl(earlier: true) }
            if let error = page.projectionError { PiNote(error).padding(8) }
            TranscriptScrollSurface(snapshot: page.snapshot, page: page, actions: actions)
                .overlay(alignment: .bottom) {
                    ZStack {
                        if page.detached || session.newerPage.available, page.snapshot?.items.isEmpty == false {
                            LatestPill { if session.browsingHistory || session.newerPage.available { onLatest(session.id) } else { page.jumpToLatest() } }.padding(.bottom, 12).transition(.opacity.combined(with: .offset(y: 6)).combined(with: .scale(scale: 0.92)))
                        }
                    }
                    .animation(reduceMotion ? nil : PiMotion.spring, value: page.detached)
                }
            // Parent panel or status changes must not animate the document's
            // frame. Row disclosures and the Latest pill set their own motion.
            .transaction { $0.animation = nil }
            if session.newerPage.available { boundaryControl(earlier: false) }
            LiveTurnBarSlot(turn: page.liveTurn, state: page.state, actions: actions, onStop: actions.stop, reduceMotion: reduceMotion)
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
    }
    private func boundaryControl(earlier: Bool) -> some View {
        let boundary = earlier ? session.olderPage : session.newerPage
        let direction = earlier ? "earlier" : "newer"
        return VStack(spacing: 3) {
            HStack(spacing: 6) {
                if boundary.loading { ProgressView().controlSize(.mini) }
                Button(boundary.loading ? "Loading \(direction)…" : boundary.error != nil ? "Retry loading \(direction)" : "Load \(direction)") {
                    if earlier { onLoadEarlier(session.id) } else { onLoadNewer(session.id) }
                }.buttonStyle(.plain).foregroundStyle(Color.piAccent).disabled(boundary.loading)
                    .accessibilityIdentifier(earlier ? "loadEarlierHistory" : "loadNewerHistory")
                if earlier, let input = session.presentation.partialTurnInput {
                    Button("Earlier work in this turn") { actions.inspect(input) }.buttonStyle(.plain).foregroundStyle(Color.piInkSecondary)
                }
            }
            if let error = boundary.error { Text(error).foregroundStyle(Color.piWarning).textSelection(.enabled) }
        }.font(PiFont.caption).padding(6).frame(maxWidth: .infinity).background(Color.piContent)
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
    let onStop: () -> Void
    let reduceMotion: Bool
    @State private var arrived = false
    var body: some View {
        // No delayed exit owns a second structural mutation. The snapshot that
        // inserts a terminal summary also releases (or retargets) this slot.
        Group {
            if let turn {
                LiveTurnBar(turn:turn, state:state, actions:actions, onStop:onStop)
                    .padding(.horizontal,16).padding(.bottom,8)
                    .opacity(arrived ? 1 : 0).offset(y:arrived ? 0 : 14)
                    .onAppear { if reduceMotion { arrived = true } else { withAnimation(PiMotion.base) { arrived = true } } }
            }
        }.onChange(of:turn == nil) { _, absent in if absent { arrived = false } }
    }
}

/// The pill that brings the reader back to the newest message.
struct LatestPill: View {
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text("Latest").font(.system(size: 12, weight: .semibold))
                Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(hovering ? TranscriptPalette.text : TranscriptPalette.muted)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(TranscriptPalette.surface, in: Capsule())
            .overlay(Capsule().stroke(hovering ? TranscriptPalette.hairStrong : TranscriptPalette.hair, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
        .buttonStyle(.plain).piPointer()
        .onHover { hovering = $0 }
        .accessibilityLabel("Jump to the latest message")
    }
}
