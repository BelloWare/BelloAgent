import AppKit
import Combine

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

/// The conversation pane: the scrolling transcript, what floats over its
/// edges (a read that is slow or failed, the way to an earlier turn's
/// question, Back to bottom), a note when the page could not be projected,
/// and the live turn bar at its foot. It follows the chat it is given and
/// the page it keeps, and draws again whenever either says it changed.
///
/// The rows beyond either edge are read as the reader reaches them, and
/// the edges float over the conversation: what comes and goes there never
/// changes the transcript's frame, so no row moves for it.
@MainActor final class NativeTranscriptPane: NSView {
    let page = TranscriptPage()
    let scrollView = TranscriptNativeScrollView()
    let document: TranscriptNativeDocument
    private(set) var session: SessionDisplay?
    /// The session's run state, as the pane above observes it.
    private(set) var state = "idle"
    private(set) var actions = TranscriptActions()
    var onAnchorChanged: (TranscriptAnchor?) -> Void = { _ in }
    var onReadReply: (String, String) -> Void = { _, _ in }
    var onLoadEarlier: (String) -> Void = { _ in }
    var onLoadNewer: (String) -> Void = { _ in }
    var onLatest: (String) -> Void = { _ in }
    var onViewportReady: (String, UUID) -> Void = { _, _ in }
    private(set) var environment = TranscriptRowEnvironment()
    private(set) var reduceMotion = false

    private var note: PiKit.Note?
    let earlierSlot = TranscriptEdgeSlot(), partialSlot = TranscriptEdgeSlot()
    let besideSlot = TranscriptEdgeSlot(), aboveSlot = TranscriptEdgeSlot()
    /// Back to bottom, and the marker behind it, in a box of their own that
    /// arrives and leaves as one.
    let latestBox = TranscriptLatestBox()
    /// The live bar while a run shows one; let go when the run settles, so
    /// it holds no chat's actions once it is gone.
    private var liveBar: TranscriptNativeTurnReport?
    private var liveShown = false
    private var liveArrivalPending = false
    private var liveKey: LiveKey?

    private var subscriptions: [AnyCancellable] = []
    private var sessionSubscription: AnyCancellable?
    private var refreshPending = false
    private var boundSession: ObjectIdentifier?
    private var boundGeneration: UUID?
    private var appliedState: String?
    /// Set once a read at that edge has run past `TranscriptEdge.quietLoad`.
    private(set) var earlierSlow = false, newerSlow = false
    private var earlierLoading: Bool?, newerLoading: Bool?
    private var earlierTimer: Timer?, newerTimer: Timer?
    private var shownEarlier: TranscriptEdge = .quiet, shownNewerBeside: TranscriptEdge = .quiet, shownNewerAbove: TranscriptEdge = .quiet
    private var shownPartial: String?, shownTurnInput: String?
    private var shownSession: ObjectIdentifier?
    private var shownDirection = NSUserInterfaceLayoutDirection.leftToRight
    private var rightToLeft: Bool { environment.layoutDirection == .rightToLeft }
    private var latestShown = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        document = TranscriptNativeDocument(page: page)
        super.init(frame: frame)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = document
        addSubview(scrollView)
        for view in [earlierSlot, partialSlot, aboveSlot] as [NSView] { addSubview(view) }
        addSubview(latestBox)
        latestBox.besideSlot = besideSlot
        // A page publishes as its snapshot, its reader's place or its own
        // reads change; the pane draws again for each, as SwiftUI did.
        subscriptions.append(page.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() })
    }
    required init?(coder: NSCoder) { nil }
    deinit {
        MainActor.assumeIsolated { earlierTimer?.invalidate(); newerTimer?.invalidate() }
    }

    /// What the pane above hands down: the chat, its run state, the actions
    /// every row calls and the values the rows are drawn under.
    func update(session: SessionDisplay, state: String, actions: TranscriptActions, environment: TranscriptRowEnvironment, reduceMotion: Bool) {
        if self.session !== session {
            self.session = session
            sessionSubscription = session.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }
        }
        self.state = state; self.actions = actions; self.environment = environment; self.reduceMotion = reduceMotion
        refresh()
    }

    /// An `ObservableObject` says it is about to change: the pane draws again
    /// once it has, before the next frame (in the window's layout pass, or
    /// on the next turn of the run loop, whichever comes first). Until then
    /// the document measures no history: what it settles must not land
    /// between the change and the pass that draws it.
    private func scheduleRefresh() {
        document.contentWillChange()
        guard !refreshPending else { return }
        refreshPending = true
        needsLayout = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.refreshPending else { return }
                self.refresh()
            }
        }
    }

    // MARK: What the pane shows

    private var earlierEdge: TranscriptEdge {
        guard let session else { return .quiet }
        return .earlier(session.olderPage, slow: earlierSlow, waitsForReader: page.earlierWaitsForReader)
    }
    private var newerEdge: TranscriptEdge {
        guard let session else { return .quiet }
        return .newer(session.newerPage, slow: newerSlow)
    }
    /// What stands beside the Back to bottom circle: the spinner of a newer
    /// read that is slow.
    private var newerBeside: TranscriptEdge {
        switch newerEdge { case .loading: return newerEdge; default: return .quiet }
    }
    /// What is said above it: a read that failed, or a page that lost its place.
    private var newerAbove: TranscriptEdge {
        switch newerEdge { case .failed, .changed: return newerEdge; default: return .quiet }
    }
    /// The question a turn that starts before the page began with, shown on
    /// its own while the top edge has nothing else to say.
    private var partialTurnInput: String? {
        switch earlierEdge {
        case .quiet, .loading: return session?.presentation.partialTurnInput
        default: return nil
        }
    }

    /// One pass of what the pane shows, from the chat and the page as they are now.
    func refresh() {
        refreshPending = false
        guard let session else { return }
        RedrawCounter.note("transcript")
        // The run state is read where it is used, never from the value the
        // pane happened to be built with: a status that lands between the
        // pane's build and this would otherwise be overwritten by a stale
        // "idle" that nothing corrects.
        if appliedState != state { appliedState = state; page.state = state }
        // The page takes the chat the pane is drawn for in the same pass,
        // not a turn of the run loop later: bound later, it held the chat
        // shown before for the frames in between (`TranscriptSwitchFirstFrameTests`).
        if boundSession != ObjectIdentifier(session) || boundGeneration != session.presentationGeneration {
            boundSession = ObjectIdentifier(session); boundGeneration = session.presentationGeneration
            page.onAnchorChanged = onAnchorChanged; page.onReadReply = onReadReply; page.onLoadEarlier = onLoadEarlier; page.onLoadNewer = onLoadNewer
            page.onViewportReady = onViewportReady
            page.state = session.state
            page.bind(session)
        }
        watchSlowReads(session)
        document.update(snapshot: page.snapshot, actions: actions, environment: environment,
                        disclosure: page.disclosure, toolInputs: page.toolInputs)
        updateNote()
        updateEdges(session)
        applyEnabled()
        updateLiveBar(session)
        needsLayout = true
    }

    /// A read shows at its edge only once it has been slow for a moment.
    private func watchSlowReads(_ session: SessionDisplay) {
        if earlierLoading != session.olderPage.loading {
            earlierLoading = session.olderPage.loading
            earlierSlow = false; earlierTimer?.invalidate(); earlierTimer = nil
            if session.olderPage.loading {
                earlierTimer = Timer.scheduledTimer(withTimeInterval: Self.seconds(TranscriptEdge.quietLoad), repeats: false) { [weak self, weak session] _ in
                    MainActor.assumeIsolated {
                        guard let self, session?.olderPage.loading == true else { return }
                        self.earlierSlow = true; self.refresh()
                    }
                }
            }
        }
        if newerLoading != session.newerPage.loading {
            newerLoading = session.newerPage.loading
            newerSlow = false; newerTimer?.invalidate(); newerTimer = nil
            if session.newerPage.loading {
                newerTimer = Timer.scheduledTimer(withTimeInterval: Self.seconds(TranscriptEdge.quietLoad), repeats: false) { [weak self, weak session] _ in
                    MainActor.assumeIsolated {
                        guard let self, session?.newerPage.loading == true else { return }
                        self.newerSlow = true; self.refresh()
                    }
                }
            }
        }
    }
    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func updateNote() {
        if let error = page.projectionError {
            if let note, note.text == error { return }
            note?.removeFromSuperview()
            let view = PiKit.Note(error)
            addSubview(view)
            note = view
        } else if let note {
            note.removeFromSuperview(); self.note = nil
        }
    }

    private var animates: Bool { !reduceMotion }

    /// A pane that takes no input (Reports in front) presses nothing at its
    /// edges, as its SwiftUI buttons were disabled with it.
    private func applyEnabled() {
        let enabled = environment.isEnabled
        for slot in [earlierSlot, partialSlot, besideSlot, aboveSlot] { slot.setEnabled(enabled) }
        latestBox.setEnabled(enabled)
    }

    private func updateEdges(_ session: SessionDisplay) {
        // Another chat in the pane, or the other writing direction: its edges
        // are made again, whatever they show.
        if shownSession != ObjectIdentifier(session) || shownDirection != environment.layoutDirection {
            shownSession = ObjectIdentifier(session); shownDirection = environment.layoutDirection
            shownEarlier = .quiet; shownTurnInput = nil; shownPartial = nil; shownNewerBeside = .quiet; shownNewerAbove = .quiet
            for slot in [earlierSlot, partialSlot, besideSlot, aboveSlot] { slot.clear() }
        }
        let earlier = earlierEdge, turnInput = session.presentation.partialTurnInput
        if earlier != shownEarlier || turnInput != shownTurnInput {
            earlierSlot.show(earlierControl(earlier, partialTurnInput: turnInput), animated: animates && earlier.name != shownEarlier.name)
            shownEarlier = earlier; shownTurnInput = turnInput
        }
        let partial = partialTurnInput
        if partial != shownPartial {
            partialSlot.show(partial.map { partialChip($0) }, animated: animates)
            shownPartial = partial
        }
        let beside = newerBeside
        if beside != shownNewerBeside {
            besideSlot.show(newerControl(beside), animated: animates)
            shownNewerBeside = beside
        }
        let above = newerAbove
        if above != shownNewerAbove {
            aboveSlot.show(newerControl(above), animated: animates && above.name != shownNewerAbove.name)
            shownNewerAbove = above
        }
        // Whenever the reader is not standing at the bottom — however they
        // came to be away from it — the way back is one circle floating over
        // the end of the conversation. An older window offers the rows after
        // it beside that circle.
        let wanted = (!page.atBottom || session.newerPage.available) && page.snapshot?.items.isEmpty == false
        latestBox.action = { [weak self] in
            guard let self, let session = self.session else { return }
            if session.browsingHistory || session.newerPage.available { self.onLatest(session.id) } else { self.page.jumpToLatest() }
        }
        if wanted != latestShown {
            // It springs in and out as the reader leaves and reaches the
            // bottom; it comes and goes in one step for anything else.
            latestBox.setShown(wanted, animated: animates && latestAtBottom != page.atBottom)
            latestShown = wanted
        }
        latestAtBottom = page.atBottom
    }
    private var latestAtBottom = true

    /// Inspecting a message, through the actions the pane holds when it is
    /// pressed: a control kept across updates (and chats) never calls the
    /// actions, or holds the chat, it was made with.
    private var inspectNow: (String) -> Void { { [weak self] id in self?.actions.inspect(id) } }
    func earlierControl(_ state: TranscriptEdge, partialTurnInput: String?) -> TranscriptEdgeSlot.Shown? {
        let load = { [weak self] in guard let self, let session = self.session else { return }; self.onLoadEarlier(session.id) }
        let inspect = inspectNow
        let marker = TranscriptEdgeMarkerView()
        switch state {
        case .quiet: return nil
        case .loading:
            let spinner = TranscriptEdgeSpinnerView(label: "Loading earlier messages")
            marker.mark(edge: "earlier", kind: state.name, text: "", action: nil)
            return .init(key: state.name, view: spinner, marker: marker, size: { _ in spinner.size })
        case .waiting:
            let view = TranscriptEdgeWaitingView(load: load, partial: partialTurnInput.map { input in { inspect(input) } })
            view.rightToLeft = rightToLeft
            marker.mark(edge: "earlier", kind: state.name, text: "Load earlier messages", action: load)
            return .init(key: state.name, view: view, marker: marker, size: { view.size(offered: $0) })
        case .failed(let error), .changed(let error):
            let view = TranscriptEdgeProblemView(title: "Couldn’t load earlier messages", detail: error, action: "Retry", perform: load,
                                                 partial: partialTurnInput.map { input in { inspect(input) } })
            view.rightToLeft = rightToLeft
            marker.mark(edge: "earlier", kind: state.name, text: error, action: load)
            return .init(key: state.name, view: view, marker: marker, size: { view.size(offered: $0) })
        }
    }
    func partialChip(_ input: String) -> TranscriptEdgeSlot.Shown {
        let inspect = inspectNow
        let view = TranscriptPartialTurnChipView(inspect: { inspect(input) })
        view.rightToLeft = rightToLeft
        let marker = TranscriptEdgeMarkerView()
        marker.mark(edge: "earlier", kind: "partial", text: "Earlier work in this turn", action: { inspect(input) })
        return .init(key: "partial", view: view, marker: marker, size: { view.size(offered: $0) })
    }
    func newerControl(_ state: TranscriptEdge) -> TranscriptEdgeSlot.Shown? {
        let load = { [weak self] in guard let self, let session = self.session else { return }; self.onLoadNewer(session.id) }
        let reload = { [weak self] in guard let self, let session = self.session else { return }; self.onLatest(session.id) }
        let marker = TranscriptEdgeMarkerView()
        switch state {
        // The rows after the window are read as the reader reaches its end;
        // there is no control to press for them.
        case .quiet, .waiting: return nil
        case .loading:
            let spinner = TranscriptEdgeSpinnerView(label: "Loading newer messages")
            marker.mark(edge: "newer", kind: state.name, text: "", action: nil)
            return .init(key: state.name, view: spinner, marker: marker, size: { _ in spinner.size })
        case .failed(let error):
            let view = TranscriptEdgeProblemView(title: "Couldn’t load newer messages", detail: error, action: "Retry", perform: load)
            view.rightToLeft = rightToLeft
            marker.mark(edge: "newer", kind: state.name, text: error, action: load)
            return .init(key: state.name, view: view, marker: marker, size: { view.size(offered: $0) })
        case .changed(let message):
            let view = TranscriptEdgeProblemView(title: "Changed outside this window", detail: message, action: "Reload", perform: reload,
                                                 icon: "arrow.triangle.branch")
            view.rightToLeft = rightToLeft
            marker.mark(edge: "newer", kind: state.name, text: message, action: reload)
            return .init(key: state.name, view: view, marker: marker, size: { view.size(offered: $0) })
        }
    }

    // MARK: The live bar

    /// What the live bar is drawn from: it is drawn again only when one of
    /// these changes (the transcript draws again for every page of a
    /// streaming reply; the bar only for its own turn or run state).
    private struct LiveKey: Equatable {
        let session: ObjectIdentifier
        let turn: TurnSummary?
        let state: String
        let reduceMotion: Bool
        let offered: [Bool]
        let environment: TranscriptRowEnvironment
    }
    /// The live bar's slot at the foot of the conversation. The slot itself
    /// is a layout change and never animates: it opens in one step when a
    /// run starts and closes in one step once the bar has gone, so the
    /// conversation above it changes height exactly once and the document
    /// holds the reader's row through that one change as it does through
    /// any other. The bar then slides up into the slot and fades in, and
    /// goes when the run settles — an offset and an opacity, which decide
    /// no layout and so cost the page nothing per tick. Reduce Motion snaps.
    private func updateLiveBar(_ session: SessionDisplay) {
        let turn = page.liveTurn
        let key = LiveKey(session: ObjectIdentifier(session), turn: turn, state: page.state, reduceMotion: reduceMotion,
                          offered: actions.offered, environment: environment)
        guard key != liveKey else { return }
        liveKey = key
        RedrawCounter.note("liveTurnBar")
        guard let turn else {
            if liveShown { liveBar?.removeFromSuperview(); liveBar = nil; liveShown = false; liveArrivalPending = false; needsLayout = true }
            return
        }
        let liveBar = self.liveBar ?? TranscriptNativeTurnReport()
        self.liveBar = liveBar
        liveBar.reduceMotion = reduceMotion
        liveBar.update(turn: turn, actions: actions, status: TurnInfoPresentation.workingLabel(turn, state: page.state), environment: environment)
        if !liveShown {
            liveShown = true
            addSubview(liveBar)
            // It slides in once the pass that opens its slot has placed it.
            liveArrivalPending = true
            needsLayout = true
        }
    }
    /// The bar sliding up 14 points into its slot as it fades in, over the
    /// base ease.
    private func arrive(_ bar: NSView) {
        guard animates, let layer = bar.layer ?? { bar.wantsLayer = true; return bar.layer }() else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        // The layer tree is not flipped: down the screen is a negative y.
        slide.fromValue = -14; slide.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.duration = PiKit.Motion.base
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "arrive")
    }

    // MARK: Layout

    /// How tall the live bar's slot is at `width`.
    private func liveSlotHeight(width: CGFloat) -> CGFloat {
        guard liveShown else { return 0 }
        guard let liveBar else { return 0 }
        return PiKit.ceil(liveBar.height(width: max(1, width - 32)), scale) + 8
    }
    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    override func layout() {
        if refreshPending { refresh() }
        super.layout()
        let width = bounds.width
        var top: CGFloat = 0
        if let note {
            // Centred, eight points all round, as a `PiNote` in the pane's stack.
            let natural = min(note.naturalWidth, max(0, width - 16))
            let height = note.height(forWidth: natural)
            note.frame = TranscriptMotion.pixelAligned(CGRect(x: (width - natural) / 2, y: 8, width: natural, height: height), scale: scale)
            top = PiKit.ceil(height, scale) + 16
        }
        let live = liveSlotHeight(width: width)
        let surface = CGRect(x: 0, y: top, width: width, height: max(0, bounds.height - top - live))
        if scrollView.frame != surface { scrollView.frame = surface }
        if liveShown, let liveBar {
            liveBar.frame = TranscriptMotion.pixelAligned(CGRect(x: 16, y: surface.maxY, width: max(1, width - 32), height: live - 8), scale: scale)
            if liveArrivalPending { liveArrivalPending = false; arrive(liveBar) }
        }
        layoutEdges(in: surface)
    }

    private func layoutEdges(in surface: CGRect) {
        let scale = self.scale
        // The top edge: centred, ten points down, sixteen in from either side.
        let earlierRoom = max(0, surface.width - 32)
        let earlier = earlierSlot.size(offered: earlierRoom)
        earlierSlot.frame = TranscriptMotion.pixelAligned(CGRect(x: surface.midX - earlier.width / 2, y: surface.minY + 10,
                                                                  width: earlier.width, height: earlier.height), scale: scale)
        earlierSlot.place(offered: earlierRoom)
        // The turn's question: top trailing, ten down and eighteen in.
        // Offered what its trailing inset leaves, as SwiftUI's padding did.
        let partialRoom = max(0, surface.width - 18)
        let partial = partialSlot.size(offered: partialRoom)
        let partialX = rightToLeft ? surface.minX + 18 : surface.maxX - 18 - partial.width
        partialSlot.frame = TranscriptMotion.pixelAligned(CGRect(x: partialX, y: surface.minY + 10,
                                                                 width: partial.width, height: partial.height), scale: scale)
        partialSlot.place(offered: partialRoom)
        // Back to bottom: centred twelve points above the foot.
        let diameter = PiKit.BackToBottomPill.diameter
        latestBox.frame = TranscriptMotion.pixelAligned(CGRect(x: surface.midX - diameter / 2, y: surface.maxY - 12 - diameter,
                                                               width: diameter, height: diameter), scale: scale)
        // Beside it, not in a row with it: its trailing edge eight points
        // before the circle, centred on it.
        let beside = besideSlot.size(offered: .greatestFiniteMagnitude)
        besideSlot.frame = TranscriptMotion.pixelAligned(CGRect(x: rightToLeft ? diameter + 8 : -8 - beside.width, y: (diameter - beside.height) / 2,
                                                                width: beside.width, height: beside.height), scale: scale)
        besideSlot.place(offered: .greatestFiniteMagnitude)
        // A newer read that failed: above the circle, at most 440 wide.
        let aboveRoom = min(440, max(0, surface.width - 32))
        let above = aboveSlot.size(offered: aboveRoom)
        aboveSlot.frame = TranscriptMotion.pixelAligned(CGRect(x: surface.midX - above.width / 2, y: surface.maxY - 12 - diameter - 8 - above.height,
                                                               width: above.width, height: above.height), scale: scale)
        aboveSlot.place(offered: aboveRoom)
    }
}

/// The pane's Back to bottom circle (`PiKit.BackToBottomPill`), the marker
/// a check finds it by, and the newer edge beside it, in one box that
/// springs in — fading, rising six points and growing from 92% — and out
/// the same way.
@MainActor final class TranscriptLatestBox: NSView {
    private(set) var pill: PiKit.BackToBottomPill?
    let marker = TranscriptEdgeMarkerView()
    weak var besideSlot: TranscriptEdgeSlot? {
        didSet { oldValue?.removeFromSuperview(); if let besideSlot { addSubview(besideSlot) } }
    }
    var action: () -> Void = {} {
        didSet { marker.mark(edge: "newer", kind: "latest", text: "Jump to the latest message", action: action) }
    }
    private(set) var shown = false
    private(set) var enabled = true
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }
    func setEnabled(_ value: Bool) {
        enabled = value
        if pill?.isEnabled != value { pill?.isEnabled = value }
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
    func setShown(_ wanted: Bool, animated: Bool) {
        guard wanted != shown else { return }
        shown = wanted
        if wanted {
            // A circle that left with the spring may come back in one step:
            // nothing of its exit stays on it.
            layer?.removeAnimation(forKey: "latestMove"); layer?.removeAnimation(forKey: "latestFade")
            layer?.sublayerTransform = CATransform3DIdentity; layer?.opacity = 1
            if pill == nil {
                let pill = PiKit.BackToBottomPill { [weak self] in self?.action() }
                pill.isEnabled = enabled
                addSubview(marker, positioned: .below, relativeTo: nil)
                addSubview(pill)
                self.pill = pill
            }
            isHidden = false
            needsLayout = true
            if animated { spring(from: Self.away, to: CATransform3DIdentity, opacity: (0, 1)) }
        } else if animated {
            spring(from: CATransform3DIdentity, to: Self.away, opacity: (1, 0)) { [weak self] in
                guard let self, !self.shown else { return }
                self.isHidden = true
            }
        } else {
            isHidden = true
        }
    }
    /// Where the circle comes from and goes to: six points lower, at 92%.
    private static var away: CATransform3D {
        // The layer tree is not flipped: down the screen is a negative y.
        CATransform3DScale(CATransform3DMakeTranslation(0, -6, 0), 0.92, 0.92, 1)
    }
    private func spring(from: CATransform3D, to: CATransform3D, opacity: (Float, Float), completion: (() -> Void)? = nil) {
        guard let layer else { completion?(); return }
        layoutSubtreeIfNeeded()
        // About the circle's middle.
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        func about(_ transform: CATransform3D) -> CATransform3D {
            CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-centre.x, -centre.y, 0), transform),
                                CATransform3DMakeTranslation(centre.x, centre.y, 0))
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion?() } }
        let move = PiKit.Motion.pop("sublayerTransform")
        move.fromValue = about(from); move.toValue = about(to)
        let fade = PiKit.Motion.pop("opacity")
        fade.fromValue = opacity.0; fade.toValue = opacity.1
        move.fillMode = .forwards; fade.fillMode = .forwards
        move.isRemovedOnCompletion = completion == nil; fade.isRemovedOnCompletion = completion == nil
        layer.add(move, forKey: "latestMove"); layer.add(fade, forKey: "latestFade")
        CATransaction.commit()
        if completion == nil { layer.sublayerTransform = CATransform3DIdentity; layer.opacity = 1 }
    }
    override func layout() {
        super.layout()
        pill?.frame = bounds
        marker.frame = bounds
    }
}
