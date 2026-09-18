import SwiftUI
import AppKit
import Combine

// The conversation page, drawn natively. The page follows the newest message
// until the reader scrolls away, keeps the reader's place across chat
// switches and earlier pages, asks for the page before the first row as the
// reader nears the top, and acknowledges a reply only once its end has
// actually been on screen in a key, visible window.
//
// SwiftUI's geometry says where the rows are; AppKit's scroll view says where
// the reader is and takes the programmatic scrolls. The AppKit document grows
// a moment after SwiftUI reports a taller page, so every scroll to the bottom
// is applied again when the document catches up.

struct ContentGeometry: Equatable {
    var top: CGFloat
    var height: CGFloat
}

/// Holds one session's page: the rows on display, the live turn, and where the
/// reader is. The view reads its published state; the geometry callbacks, the
/// scroll view's notifications and the session's transcript stream drive it.
@MainActor final class TranscriptPage: ObservableObject {
    static let space = "transcript"
    static let contentSpace = "transcript.content"
    static let bottomID = "transcript.bottom"
    /// The newest rows that fit: up to 500 messages and about 4 MB of text.
    nonisolated static let rowLimit = 500
    nonisolated static let byteLimit = 4_000_000
    /// Within this many points of the bottom the page still follows new rows.
    static let followThreshold: CGFloat = 70
    /// Within this many points of the top the page asks for the earlier page.
    static let earlierThreshold: CGFloat = 240

    struct Snapshot: Equatable {
        var sessionID: String
        var messages: [TranscriptMessage]
        var items: [TranscriptItem]
        var fresh: Set<String>
        var sequence: Int
    }

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var liveTurn: TurnSummary?
    @Published private(set) var detached = false
    /// The session's run state; while it is busy the bar stays up even between rows.
    var state = "idle" { didSet { if state != oldValue { recomputeLive() } } }
    var busy: Bool { ["queued", "running", "stopping", "compacting"].contains(state) }

    var proxy: ScrollViewProxy?
    var onAnchorChanged: (TranscriptAnchor?) -> Void = { _ in }
    var onReadReply: (String, String) -> Void = { _, _ in }
    var onLoadEarlier: (String) -> Void = { _ in }

    private var subscription: AnyCancellable?
    private(set) var sessionID: String?
    private var viewportRequest: Int?
    private var initialized = false
    private(set) var followsBottom = true
    private var pendingAnchor: TranscriptAnchor?
    private var anchorScrollRequested = false
    /// A chat opened while idle starts at its last question when the last turn does not fit above the bottom.
    private var openingPlacementPending = false
    private var seen: Set<String> = []
    private var completedAssistant: String?
    private var firstRow = "", earlierRequested = ""
    private var jumping = false
    private var sequence = 0
    /// Row frames relative to the content, so they stay valid while the page scrolls.
    private var frames: [String: CGRect] = [:]
    private var content = ContentGeometry(top: 0, height: 0)
    private var viewport = CGSize.zero
    private weak var scrollView: NSScrollView?
    private weak var hostView: NSView?
    private var reportTask: Task<Void, Never>?
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
    deinit { for observer in windowObservers + scrollObservers { NotificationCenter.default.removeObserver(observer) } }

    // MARK: Where the reader is

    /// The reader's position as AppKit has it now; SwiftUI's geometry stands in before the scroll view is found.
    private struct Position { var offset: CGFloat; var height: CGFloat; var viewport: CGFloat }
    private var position: Position {
        if let scrollView, let document = scrollView.documentView {
            let clip = scrollView.contentView
            let offset = document.isFlipped ? clip.bounds.origin.y : document.frame.height - clip.bounds.height - clip.bounds.origin.y
            return Position(offset: offset, height: max(document.frame.height, content.height), viewport: clip.bounds.height)
        }
        return Position(offset: -content.top, height: content.height, viewport: viewport.height)
    }
    var scrollY: CGFloat { -content.top }
    var distanceToBottom: CGFloat { let p = position; return p.height - p.viewport - p.offset }

    // MARK: Session binding

    func bind(_ session: SessionDisplay) {
        guard sessionID != session.id else { return }
        subscription?.cancel()
        sessionID = session.id; viewportRequest = nil
        reset()
        frames = [:]
        snapshot = nil; liveTurn = nil; detached = false
        subscription = session.transcriptChanges.combineLatest(session.$viewportRequest).sink { [weak self, weak session] messages, request in
            guard let self, let session else { return }
            self.receive(messages, viewportRequest: request, from: session)
        }
    }
    private func reset() {
        initialized = false; followsBottom = true; pendingAnchor = nil; anchorScrollRequested = false; openingPlacementPending = false
        seen = []; completedAssistant = nil; firstRow = ""; earlierRequested = ""; jumping = false
    }

    /// The newest rows that fit the display limits, dropping the oldest first.
    nonisolated static func displayPage(_ messages: [TranscriptMessage]) -> [TranscriptMessage] {
        var page = Array(messages.suffix(rowLimit))
        func size(_ message: TranscriptMessage) -> Int {
            message.text.utf8.count + (message.thinking?.utf8.count ?? 0) + (message.tools ?? []).reduce(0) { $0 + $1.input.utf8.count + $1.output.utf8.count } + 256
        }
        var total = page.reduce(0) { $0 + size($1) }
        while total > byteLimit, page.count > 1 {
            let drop = max(1, page.count / 8)
            total -= page.prefix(drop).reduce(0) { $0 + size($1) }
            page.removeFirst(drop)
        }
        return page
    }

    private func receive(_ messages: [TranscriptMessage], viewportRequest request: Int, from session: SessionDisplay) {
        guard session.id == sessionID else { return }
        if viewportRequest != request {
            // A jump to the latest page or a prepended earlier page: the page starts over from the session's anchor.
            viewportRequest = request
            reset()
        }
        let page = Self.displayPage(messages)
        if let current = snapshot, current.messages == page, initialized { return }
        var fresh: Set<String> = []
        for message in page {
            if initialized, !seen.contains(message.id) { fresh.insert(message.id) }
            seen.insert(message.id)
        }
        if !initialized {
            if let anchor = session.scrollAnchor { followsBottom = anchor.followsBottom; pendingAnchor = anchor.followsBottom ? nil : anchor }
            else { followsBottom = true; pendingAnchor = nil }
            anchorScrollRequested = false
            openingPlacementPending = followsBottom && !busy && !page.isEmpty
        }
        let completed = TranscriptActivity.latestCompletedAssistant(page)
        if initialized, let completed, completed != completedAssistant {
            AccessibilityNotification.Announcement("Reply complete").post()
        }
        completedAssistant = completed
        firstRow = page.first?.id ?? ""
        // A delta to the reply that is arriving patches the last block; anything else regroups the page.
        let items = snapshot.flatMap { TranscriptActivity.patched($0.items, from: $0.messages, to: page) } ?? TranscriptActivity.blocks(of: page)
        let ids = Set(items.map(\.id))
        frames = frames.filter { ids.contains($0.key) }
        sequence += 1
        let next = Snapshot(sessionID: session.id, messages: page, items: items, fresh: fresh, sequence: sequence)
        let live = Self.liveTurn(in: items, busy: busy)
        // Rows that arrive settled animate in; nothing animates while a reply streams, so its text never slides.
        let animate = initialized && !fresh.isEmpty && live == nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        initialized = true
        if animate { withAnimation(.easeOut(duration: 0.32)) { snapshot = next; liveTurn = live } }
        else { snapshot = next; liveTurn = live }
        PerformanceProbe.shared.viewport(session.id, deltaAt: session.displayObservedAt)
        scheduleSettle()
    }

    private func recomputeLive() {
        let live = Self.liveTurn(in: snapshot?.items ?? [], busy: busy)
        if live != liveTurn { liveTurn = live }
    }
    /// The turn the bar shows: a live turn from the rows, or, while the session
    /// is busy without a streaming row (waiting for the first token, running a
    /// tool between requests, compacting), the current turn's figures so far.
    static func liveTurn(in items: [TranscriptItem], busy: Bool) -> TurnSummary? {
        if case .block(let block) = items.last, let turn = block.turn, turn.live { return turn }
        guard busy else { return nil }
        var notice: String? = nil
        var tail = items[...]
        if case .message(let last) = tail.last, last.kind == "notice" { notice = last.text; tail = tail.dropLast() }
        switch tail.last {
        case .block(let block):
            if var turn = block.turn { turn.live = true; turn.endedAt = nil; turn.current = block.tools.last { ["running", "preparing", "prepared"].contains($0.state) }; turn.notice = notice; return turn }
            return TurnSummary(replies: 1, tools: block.tools.count, startedAt: block.startedAt, endedAt: nil, elapsedMs: nil, modelMs: block.modelMs, toolMs: block.toolMs, live: true, files: 0, partial: false, accounting: block.accounting, requests: [], current: nil, notice: notice)
        case .message(let message):
            return TurnSummary(replies: 0, tools: 0, startedAt: message.at, endedAt: nil, elapsedMs: nil, modelMs: 0, toolMs: 0, live: true, files: 0, partial: false, accounting: TurnAccounting(), requests: [], current: nil, notice: notice)
        case nil:
            return TurnSummary(replies: 0, tools: 0, startedAt: nil, endedAt: nil, elapsedMs: nil, modelMs: 0, toolMs: 0, live: true, files: 0, partial: false, accounting: TurnAccounting(), requests: [], current: nil, notice: notice)
        }
    }

    // MARK: Geometry

    func attach(_ scrollView: NSScrollView?, host: NSView) {
        hostView = host
        guard self.scrollView !== scrollView else { return }
        for observer in scrollObservers { NotificationCenter.default.removeObserver(observer) }
        scrollObservers = []
        self.scrollView = scrollView
        guard let scrollView else { return }
        let center = NotificationCenter.default
        // User scrolling decides whether the page follows; programmatic scrolls never do.
        for name in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
            scrollObservers.append(center.addObserver(forName: name, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.userScrolled() }
            })
        }
        if let document = scrollView.documentView {
            document.postsFrameChangedNotifications = true
            scrollObservers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.documentResized() }
            })
        }
    }
    func viewportChanged(_ size: CGSize) {
        guard size != viewport else { return }
        viewport = size
        // A narrower pane makes the same rows taller; a reader at the newest message stays there.
        if followsBottom { scrollToBottom() }
        requestReadCheck()
    }
    func contentChanged(_ geometry: ContentGeometry) {
        let previous = content
        content = geometry
        if geometry.height != previous.height {
            settle()
            requestEarlierIfNearTop(scrollY: followsBottom ? max(0, geometry.height - viewport.height) : scrollY)
        } else if geometry.top != previous.top {
            scheduleReport()
        }
    }
    func rowFrame(_ id: String, _ frame: CGRect) {
        frames[id] = frame
        if pendingAnchor.map({ rowIdentifier(for: $0.id) }) == id { settle() }
    }
    func rowGone(_ id: String) { frames.removeValue(forKey: id) }
    /// A row's frame in content coordinates, for tests.
    func rowFrame(of id: String) -> CGRect? { frames[id] }
    /// The AppKit document took the height SwiftUI reported: land the pending scroll.
    private func documentResized() {
        if followsBottom { scrollToBottom() } else if pendingAnchor != nil { settle() }
    }

    private func scheduleSettle() {
        guard !settleScheduled else { return }
        settleScheduled = true
        // After SwiftUI commits the new rows; the geometry callbacks usually get here first.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.settleScheduled = false
            self.settle()
        }
    }
    /// Puts the page where it belongs after rows change: at the bottom while
    /// following, or with the anchored row back where the reader left it.
    private func settle() {
        if openingPlacementPending, documentSettled, viewport.height > 0, let snapshot {
            // The reader opened this chat: show the question that started the last
            // turn, unless the whole turn fits above the bottom anyway.
            if let lastUser = snapshot.items.last(where: { if case .message(let m) = $0 { return m.role == "user" }; return false }), let frame = frames[lastUser.id] {
                openingPlacementPending = false
                let bottom = max(0, content.height - viewport.height)
                if frame.minY < bottom - 1 {
                    followsBottom = false; pendingAnchor = nil
                    scroll(to: max(0, frame.minY - 12), animated: false)
                    if !detached { detached = true }
                    requestReadCheck()
                    return
                }
            } else if !frames.isEmpty { openingPlacementPending = false }
        }
        if followsBottom {
            pendingAnchor = nil
            // One scroll per change: while the AppKit document still lags SwiftUI's
            // height, wait for its frame notification instead of landing short first.
            if documentSettled { scrollToBottom() }
            if detached && !jumping { detached = false }
            requestReadCheck()
            return
        }
        guard let anchor = pendingAnchor, let snapshot else { requestReadCheck(); return }
        let rowID = rowIdentifier(for: anchor.id)
        guard snapshot.items.contains(where: { $0.id == rowID }) else { pendingAnchor = nil; return }
        if let frame = frames[rowID] {
            // Wait for the AppKit document to reach SwiftUI's height, or the scroll would clamp short.
            guard documentSettled else { return }
            pendingAnchor = nil
            scroll(to: frame.minY - anchor.offset, animated: false)
        } else if !anchorScrollRequested {
            anchorScrollRequested = true
            proxy?.scrollTo(rowID, anchor: .top)
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
        return frame.offsetBy(dx: 0, dy: content.top)
    }

    /// The reader scrolled: decide whether the page still follows the newest
    /// message, show or hide the jump pill, ask for the earlier page near the
    /// top, and a little later remember the anchor and check for a read.
    private func userScrolled() {
        evaluateFollowing()
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
        guard scrollY < Self.earlierThreshold, !firstRow.isEmpty, earlierRequested != firstRow, let sessionID else { return }
        earlierRequested = firstRow
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
            if let snapshot, let last = snapshot.items.last { proxy?.scrollTo(last.id, anchor: .bottom) }
            completion?(); return
        }
        let clip = scrollView.contentView
        let maximum = max(0, document.frame.height - clip.bounds.height)
        let target = min(max(0, y), maximum)
        let origin = NSPoint(x: clip.bounds.origin.x, y: document.isFlipped ? target : maximum - target)
        guard animated else {
            if clip.bounds.origin != origin { clip.setBoundsOrigin(origin); scrollView.reflectScrolledClipView(clip) }
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
        followsBottom = true; jumping = true; detached = false
        let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        scrollToBottom(animated: animated) { [weak self] in
            guard let self, self.jumping else { return }
            self.jumping = false
            self.evaluateFollowing()
            self.scheduleReport()
        }
        // A scroll the system abandons must not leave the pill hidden.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard let self, self.jumping else { return }
            self.jumping = false
            self.evaluateFollowing()
        }
    }

    // MARK: Read receipts

    private var canRead: Bool {
        guard let host = hostView, let window = host.window else { return false }
        let surface: NSView = scrollView ?? host
        return TranscriptReadVisibility.permits(appActive: NSApp.isActive, keyWindow: window.isKeyWindow, windowVisible: window.isVisible,
                                                occluded: !window.occlusionState.contains(.visible), minimized: window.isMiniaturized,
                                                viewHidden: surface.isHiddenOrHasHiddenAncestor || surface.visibleRect.isEmpty, sheetOpen: window.attachedSheet != nil)
    }
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

/// Finds the scroll view SwiftUI built for the page, so the page can be
/// positioned exactly and its window watched for read receipts.
private struct ScrollViewFinder: NSViewRepresentable {
    let attach: (NSScrollView?, NSView) -> Void
    func makeNSView(context: Context) -> TranscriptSurfaceMarker { let view = TranscriptSurfaceMarker(); view.attach = attach; return view }
    func updateNSView(_ view: TranscriptSurfaceMarker, context: Context) { view.attach = attach; view.locate() }
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

struct NativeTranscriptView: View {
    let session: SessionDisplay
    /// The session's run state, observed by the pane and handed down so the live bar follows it.
    var state = "idle"
    let actions: TranscriptActions
    var onAnchorChanged: (TranscriptAnchor?) -> Void = { _ in }
    var onReadReply: (String, String) -> Void = { _, _ in }
    var onLoadEarlier: (String) -> Void = { _ in }
    @StateObject private var page = TranscriptPage()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    rows
                        .coordinateSpace(name: TranscriptPage.contentSpace)
                        .onGeometryChange(for: ContentGeometry.self, of: { ContentGeometry(top: $0.frame(in: .named(TranscriptPage.space)).minY, height: $0.size.height) }, action: { page.contentChanged($0) })
                        .background(ScrollViewFinder { scrollView, host in (host as? TranscriptSurfaceMarker)?.page = page; page.attach(scrollView, host: host) })
                }
                .coordinateSpace(name: TranscriptPage.space)
                .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { page.viewportChanged($0) })
                .overlay(alignment: .bottom) {
                    if page.detached, page.snapshot?.items.isEmpty == false {
                        LatestPill { page.jumpToLatest() }.padding(.bottom, 12).transition(.opacity.combined(with: .offset(y: 6)).combined(with: .scale(scale: 0.92)))
                    }
                }
                .animation(reduceMotion ? nil : PiMotion.spring, value: page.detached)
                .onAppear { page.proxy = proxy }
            }
            if let turn = page.liveTurn {
                LiveTurnBar(turn: turn, state: page.state, onStop: actions.stop)
                    .padding(.horizontal, 16).padding(.bottom, 8)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: page.liveTurn != nil)
        .task(id: session.id) {
            page.onAnchorChanged = onAnchorChanged; page.onReadReply = onReadReply; page.onLoadEarlier = onLoadEarlier
            page.state = state
            page.bind(session)
        }
        .onChange(of: state) { _, value in page.state = value }
    }

    @ViewBuilder private var rows: some View {
        let snapshot = page.snapshot
        let items = snapshot?.items ?? []
        let fresh = snapshot?.fresh ?? []
        // Every row is laid out, not estimated: rows keep exact positions while
        // others stream, anchors are exact, and nothing below shifts what is in view.
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text("Ready for a conversation.").font(.system(size: 13)).foregroundStyle(TranscriptPalette.faint)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
            }
            ForEach(items) { item in
                row(item, fresh: fresh)
                    .id(item.id)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(TranscriptPage.contentSpace)) }, action: { page.rowFrame(item.id, $0) })
                    .onDisappear { page.rowGone(item.id) }
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .identity))
            }
            Color.clear.frame(height: 1).id(TranscriptPage.bottomID)
        }
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 12)
        .frame(maxWidth: TranscriptMetrics.pageWidth + 48)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation page")
    }
    @ViewBuilder private func row(_ item: TranscriptItem, fresh: Set<String>) -> some View {
        switch item {
        case .message(let message):
            MessageRowView(message: message, actions: actions).equatable()
                .padding(.top, message.role == "user" ? 14 : 4).padding(.bottom, message.role == "user" ? 4 : 10)
        case .block(let block):
            BlockRowView(block: block, actions: actions, fresh: block.message.map { fresh.contains($0.id) } ?? block.activity.contains { fresh.contains($0.id) }).equatable()
        }
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
