import SwiftUI
import AppKit

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
        case .quiet, .loading: return session.presentation.partialTurnInput
        default: return nil
        }
    }

    var body: some View {
        let _ = RedrawCounter.note("transcript")
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
            // Not re-identified by the presentation generation: a new page of
            // the same chat (a revisit, a reload, an earlier version) keeps the
            // bar where it stands instead of replaying its entrance.
            LiveTurnBarSlot(turn: page.liveTurn, state: page.state, actions: actions, reduceMotion: reduceMotion, session: ObjectIdentifier(session)).equatable()
        }
        // The run state is read where it is used, never from the value this
        // body happened to be built with: a status that lands between the
        // body and the binding below would otherwise be overwritten by a
        // stale "idle" that nothing corrects — no spinner, no elapsed time
        // and no Stop for the whole run.
        .onChange(of: state, initial: true) { _, value in page.state = value }
        // The page takes the chat the pane is drawn for in the same update,
        // not a turn of the run loop later: bound in a task, it held the chat
        // shown before for the frames in between — its rows, and its live
        // bar — under the one just opened, and they moved as its bar and its
        // figures came and went (`TranscriptSwitchFirstFrameTests`).
        .onChange(of: session.presentationGeneration, initial: true) {
            page.onAnchorChanged = onAnchorChanged; page.onReadReply = onReadReply; page.onLoadEarlier = onLoadEarlier; page.onLoadNewer = onLoadNewer
            page.onViewportReady = onViewportReady
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

/// The pane is drawn again for every change to the workspace, and makes the
/// transcript's actions afresh each time, though each still reaches the chat
/// through the same model and session. For the same session, in the same run
/// state, offering the same actions, the transcript is the same: drawing it
/// again laid the live bar and every overlay out again for nothing. What the
/// session itself changes still reaches it, since it observes the session.
extension NativeTranscriptView: Equatable {
    nonisolated static func == (lhs: NativeTranscriptView, rhs: NativeTranscriptView) -> Bool {
        MainActor.assumeIsolated {
            lhs.session === rhs.session && lhs.state == rhs.state && lhs.actions.offered == rhs.actions.offered
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
private struct LiveTurnBarSlot: View, Equatable {
    let turn: TurnSummary?
    let state: String
    let actions: TranscriptActions
    let reduceMotion: Bool
    /// The session the actions were made for. The pane is kept across chats,
    /// so the same slot shows the next chat's bar: compared without it, a
    /// bar with the same turn (most often none) kept the actions of the chat
    /// the reader left, and they held that chat's display in memory.
    let session: ObjectIdentifier
    @State private var arrived = false
    /// The transcript is drawn again for every page of a streaming reply;
    /// the bar only when its own turn or run state changes. Its actions are
    /// the transcript's, made for the same session (see `NativeTranscriptView`).
    nonisolated static func == (lhs: LiveTurnBarSlot, rhs: LiveTurnBarSlot) -> Bool {
        MainActor.assumeIsolated {
            lhs.session == rhs.session && lhs.turn == rhs.turn && lhs.state == rhs.state && lhs.reduceMotion == rhs.reduceMotion && lhs.actions.offered == rhs.actions.offered
        }
    }
    var body: some View {
        let _ = RedrawCounter.note("liveTurnBar")
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
