import SwiftUI
import AppKit
@testable import PiApp

// The SwiftUI conversation pane before it was AppKit (NativeTranscriptView,
// renamed NativeTranscriptReferenceView), its scroll surface and its edges'
// views, kept as they were for the parity tests to draw against.

struct NativeTranscriptReferenceView: View {
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
                            // Weak: SwiftUI can keep a hover handler — and the action
                            // in it — after the circle is gone, and that must not
                            // keep the chat the reader left.
                            let latest = { [weak session, weak page, onLatest] in
                                guard let session else { return }
                                if session.browsingHistory || session.newerPage.available { onLatest(session.id) } else { page?.jumpToLatest() }
                            }
                            PiBackToBottomPill(action: latest)
                                .background(TranscriptEdgeMarker(edge: "newer", kind: "latest", text: "Jump to the latest message", action: latest))
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
extension NativeTranscriptReferenceView: Equatable {
    nonisolated static func == (lhs: NativeTranscriptReferenceView, rhs: NativeTranscriptReferenceView) -> Bool {
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
    /// the transcript's, made for the same session (see `NativeTranscriptReferenceView`).
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

/// AppKit owns the scrolling document. SwiftUI receives row content changes,
/// not a new document coordinate transform for every wheel/trackpad event.
struct TranscriptScrollSurface: NSViewRepresentable {
    /// Which page of the conversation this is, as a number the page
    /// increments. The rows themselves are read from the page: handing
    /// SwiftUI the whole snapshot would have it hold and compare three
    /// hundred messages for every token of an arriving reply.
    let revision: Int
    let page: TranscriptPage
    let actions: TranscriptActions
    private var snapshot: TranscriptPage.Snapshot? { page.snapshot }

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


/// What the top edge shows about the rows before the first one the page holds.
struct TranscriptEarlierEdge: View {
    let state: TranscriptEdge
    /// The question the turn at the top of the page began with, when that
    /// turn started before the page does.
    let partialTurnInput: String?
    let load: () -> Void
    let inspect: (String) -> Void
    var body: some View {
        ZStack {
            switch state {
            case .quiet: EmptyView()
            case .loading:
                TranscriptEdgeSpinner(label: "Loading earlier messages")
                    .background(TranscriptEdgeMarker(edge: "earlier", kind: state.name, text: ""))
                    .transition(.opacity)
            case .waiting:
                TranscriptEdgeSurface {
                    HStack(spacing: 2) {
                        Button("Load earlier messages", action: load).buttonStyle(TranscriptEdgeLinkStyle())
                            .accessibilityIdentifier("loadEarlierHistory")
                        if let partialTurnInput {
                            Text("·").foregroundStyle(TranscriptPalette.faint)
                            Button("Earlier work in this turn") { inspect(partialTurnInput) }.buttonStyle(TranscriptEdgeLinkStyle(quiet: true))
                        }
                    }
                }
                .background(TranscriptEdgeMarker(edge: "earlier", kind: state.name, text: "Load earlier messages", action: load))
                .transition(.opacity)
            case .failed(let error), .changed(let error):
                TranscriptEdgeProblem(title: "Couldn’t load earlier messages", detail: error, action: "Retry", perform: load,
                                      partial: partialTurnInput.map { input in { inspect(input) } })
                    .background(TranscriptEdgeMarker(edge: "earlier", kind: state.name, text: error, action: load))
                    .transition(.opacity)
            }
        }
    }
}

/// The way to the question a long turn began with, while the page starts
/// part way through that turn. It stays where it is for as long as that is
/// true, whatever the reader or the page's reads do, so it never flickers.
struct TranscriptPartialTurnChip: View {
    let input: String
    let inspect: (String) -> Void
    var body: some View {
        TranscriptEdgeSurface {
            Button { inspect(input) } label: {
                Label("Earlier work in this turn", systemImage: "arrow.up.to.line").labelStyle(.titleAndIcon)
            }
            .buttonStyle(TranscriptEdgeLinkStyle(quiet: true))
        }
        .background(TranscriptEdgeMarker(edge: "earlier", kind: "partial", text: "Earlier work in this turn", action: { inspect(input) }))
        .help("Show the question this turn began with")
    }
}

/// What the bottom edge shows, beside the way back to the latest message,
/// when the page holds an older window: rows after its last one.
struct TranscriptNewerEdge: View {
    let state: TranscriptEdge
    let load: () -> Void
    let reload: () -> Void
    var body: some View {
        ZStack {
            switch state {
            // The rows after the window are read as the reader reaches its
            // end; there is no control to press for them.
            case .quiet, .waiting: EmptyView()
            case .loading:
                TranscriptEdgeSpinner(label: "Loading newer messages")
                    .background(TranscriptEdgeMarker(edge: "newer", kind: state.name, text: ""))
                    .transition(.opacity)
            case .failed(let error):
                TranscriptEdgeProblem(title: "Couldn’t load newer messages", detail: error, action: "Retry", perform: load)
                    .background(TranscriptEdgeMarker(edge: "newer", kind: state.name, text: error, action: load))
                    .transition(.opacity)
            case .changed(let message):
                TranscriptEdgeProblem(title: "Changed outside this window", detail: message, action: "Reload", perform: reload, icon: "arrow.triangle.branch")
                    .background(TranscriptEdgeMarker(edge: "newer", kind: state.name, text: message, action: reload))
                    .transition(.opacity)
            }
        }
    }
}

/// The small spinner an edge shows while a slow read is under way.
struct TranscriptEdgeSpinner: View {
    let label: String
    static let diameter: CGFloat = 26
    var body: some View {
        SpinnerView()
            .frame(width: Self.diameter, height: Self.diameter)
            .background(TranscriptPalette.surface, in: Circle())
            .overlay(Circle().stroke(TranscriptPalette.hairStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
            .accessibilityElement()
            .accessibilityLabel(label)
    }
}

/// A read that failed, or a page that lost its place: one line saying so
/// with the thing to do about it, and the error under it.
struct TranscriptEdgeProblem: View {
    let title: String
    let detail: String
    let action: String
    let perform: () -> Void
    var partial: (() -> Void)? = nil
    var icon = "exclamationmark.circle"
    var body: some View {
        TranscriptEdgeSurface(radius: 12) {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(TranscriptPalette.warning)
                    Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(TranscriptPalette.text)
                    Button(action, action: perform).buttonStyle(TranscriptEdgeLinkStyle())
                    if let partial {
                        Text("·").foregroundStyle(TranscriptPalette.faint)
                        Button("Earlier work in this turn", action: partial).buttonStyle(TranscriptEdgeLinkStyle(quiet: true))
                    }
                }
                Text(detail).font(.system(size: 10.5)).foregroundStyle(TranscriptPalette.muted)
                    .multilineTextAlignment(.center).lineLimit(3).textSelection(.enabled)
                    .padding(.horizontal, 6).padding(.bottom, 3)
            }
            .padding(.leading, 4)
        }
        .frame(maxWidth: 460)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title + ". " + detail)
    }
}

/// The floating surface every edge control stands on: the transcript's own
/// card colour, a hairline and a soft shadow, like the Back to bottom pill.
struct TranscriptEdgeSurface<Content: View>: View {
    var radius: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 4).padding(.vertical, 3)
            .background(TranscriptPalette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(TranscriptPalette.hairStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
    }
}

/// A word to press inside an edge control: accent text that lights up on
/// hover. The quiet form reads as a secondary way somewhere.
struct TranscriptEdgeLinkStyle: ButtonStyle {
    var quiet = false
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: quiet ? .medium : .semibold))
            .foregroundStyle(quiet && !hovering ? TranscriptPalette.muted : TranscriptPalette.accent)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(hovering ? TranscriptPalette.accentSoft : Color.clear, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .piPointer()
    }
}

/// Marks an edge control in the view tree, so a check can find what the
/// reader would see at an edge and press it. It draws nothing and takes no
/// clicks.
struct TranscriptEdgeMarker: NSViewRepresentable {
    let edge: String
    let kind: String
    let text: String
    var action: (() -> Void)? = nil
    func makeNSView(context: Context) -> TranscriptEdgeMarkerView { TranscriptEdgeMarkerView() }
    func updateNSView(_ view: TranscriptEdgeMarkerView, context: Context) {
        view.mark(edge: edge, kind: kind, text: text, action: action)
    }
}
