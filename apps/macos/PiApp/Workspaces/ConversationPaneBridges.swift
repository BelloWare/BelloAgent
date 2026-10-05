import AppKit
import SwiftUI

// TEMPORARY (0.1.120): the SwiftUI the conversation pane still hosts — the
// transcript (Transcript/, `NativeTranscriptView`) — and the `ConversationPane` representable
// through which SwiftUI (and tests) host the AppKit pane. Each part goes
// when its owner's AppKit view lands.

extension ShellHostingView {
    /// A hosting view with nothing in it yet.
    static func empty() -> ShellHostingView { ShellHostingView(rootView: AnyView(EmptyView())) }
    /// The chat's transcript, filling what it is given.
    func showTranscript(model: WorkspaceModel, session: SessionDisplay, state: String, canFork: Bool, canQuote: Bool, enabled: Bool) {
        setRoot(AnyView(TranscriptBridge(model: model, session: session, state: state, canFork: canFork, canQuote: canQuote).disabled(!enabled)), reportsHeight: false)
    }
}

// MARK: - Hosted SwiftUI (temporary)

/// A hosting view the pane lays out with frames. Its content says how tall
/// it is at the width it is given (laid out there, it reports its height),
/// so the pane never lays a second copy out to ask.
@MainActor final class ShellHostingView: NSHostingView<AnyView>, PiKit.WidthSizing {
    var sizeChanged: (() -> Void)?
    private var reported: CGFloat?
    convenience init(root: AnyView, reportsHeight: Bool = true) {
        self.init(rootView: AnyView(EmptyView()))
        setRoot(root, reportsHeight: reportsHeight)
    }
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
    }
    @MainActor @preconcurrency required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    /// A new root. One that reports its height is as tall as it says; one
    /// that does not fills what it is given (the transcript), or takes
    /// between its least and its own height (the terminal).
    /// A root that does not report its height says so through its own
    /// size (a terminal dragged taller): the pane lays out again.
    private var reportsHeight = true
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard !reportsHeight else { return }
        DispatchQueue.main.async { [weak self] in self?.sizeChanged?() }
    }
    func setRoot(_ root: AnyView, reportsHeight: Bool = true) {
        self.reportsHeight = reportsHeight
        guard reportsHeight else { reported = nil; rootView = root; return }
        rootView = AnyView(root.fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                guard let self else { return }
                let height = ceil(height)
                guard height != self.reported else { return }
                self.reported = height
                // Not inside SwiftUI's own update.
                DispatchQueue.main.async { [weak self] in self?.sizeChanged?() }
            })
    }
    /// The height its content last reported, or what it asks for before then.
    func height(forWidth width: CGFloat) -> CGFloat { reported ?? ceil(max(0, intrinsicContentSize.height)) }
    /// The least it can be: the terminal gives way down to this.
    func minimumHeight(forWidth width: CGFloat) -> CGFloat { minimum ?? 0 }
    var minimum: CGFloat?
}

extension View {
    /// What the workspace window's SwiftUI root gave every view in it: the
    /// app's button and toggle styles.
    /// A hosting view under the title bar keeps its content there too.
    func piShellBridged() -> some View {
        buttonStyle(.piSecondary).toggleStyle(.piSwitch).ignoresSafeArea(.container, edges: .top)
    }
}

/// The transcript as the pane used to build it, until the transcript itself is AppKit.
private struct TranscriptBridge: View {
    let model: WorkspaceModel
    let session: SessionDisplay
    /// The run state, carried here so a change to it is a change to this view.
    let state: String
    let canFork: Bool
    let canQuote: Bool
    var body: some View {
        let model = model, session = session
        NativeTranscriptView(session: session, state: state,
                             actions: TranscriptActions(inspect: { model.showMessageDetail(session.id, messageID: $0) },
                                                        edit: { model.editMessage($0, sessionID: session.id) },
                                                        copyMessage: { id in
                                                            guard let message = session.presentedMessages.first(where: { $0.id == id }) else { return }
                                                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string)
                                                        },
                                                        stop: { model.stop(sessionID: session.id) },
                                                        // The retry carries this chat's current model, effort and budgets, as a send would.
                                                        retry: { model.action("turn.retry", params: model.record(session.id).map { model.turnOverrides(for: $0) } ?? [:], sessionID: session.id) },
                                                        quoteReply: canQuote ? { quote in model.openQuotedSide(parentID: session.id, quote: quote) } : nil,
                                                        inspectTurn: { [weak model] turn in
                                                            model?.openInspector(session: session.id, focus: WorkspaceModel.inspectorFocus(for: turn))
                                                        },
                                                        skillPressed: { [weak model, weak session] messageID, use, anchor in
                                                            guard let model, let session else { return }
                                                            SkillPopovers.shared.pressSent(use: use, messageID: messageID, anchor: anchor, model: model, session: session)
                                                        },
                                                        skillHovered: { [weak session] _, use, anchor, inside in
                                                            guard let session else { return }
                                                            SkillPopovers.shared.hoverSent(inside, use: use, anchor: anchor, session: session)
                                                        },
                                                        costLimit: { [weak model] action, anchor in model?.costLimitNotice(action, sessionID: session.id, anchor: anchor) },
                                                        fork: { [weak model, id = session.id] messageID in model?.forkFromReply(sessionID: id, messageID: messageID) },
                                                        switchVersion: { [weak model] messageID, step in model?.showVersion(sessionID: session.id, messageID: messageID, step: step) },
                                                        latestVersion: { [weak model] in model?.latestVersion(sessionID: session.id) },
                                                        openFile: { [weak model] path, lines in model?.openFile(fromChat: session.id, path: path, lines: lines) },
                                                        resolveReplyFile: { [weak model] text in await model?.resolveReplyFile(text, fromChat: session.id) }),
                             onAnchorChanged: { anchor in session.scrollAnchor = anchor; model.anchorChanged(session) },
                             onReadReply: { sessionID, messageID in model.acknowledgeVisibleReply(sessionID: sessionID, messageID: messageID) },
                             onLoadEarlier: { sessionID in model.loadEarlier(sessionID: sessionID) },
                             onLoadNewer: { model.loadNewer(sessionID: $0) },
                             onLatest: { model.latest(sessionID: $0) },
                             onViewportReady: { model.historyViewportReady($0, generation: $1) })
            .equatable()
            .environment(\.transcriptForks, canFork)
            .environment(\.transcriptOpensFiles, true)
            .piStableLayout()
            .background(Color.piContent)
            .piShellBridged()
    }
}

/// The pane inside the still-SwiftUI workspace, side and tab panes (TEMPORARY).
struct ConversationPane: View {
    let model: WorkspaceModel
    let session: SessionDisplay
    let chat: ChatRecord
    /// How wide this pane is; the AppKit pane reads its own width.
    let paneWidth: CGFloat
    var side: SideRecord? = nil
    var sideActions: SideActions? = nil
    @MainActor static func coversTranscript(_ session: SessionDisplay) -> Bool { ConversationPaneView.coversTranscript(session) }
    static var coverDelay: Duration { ConversationPaneView.coverDelay }
    var body: some View {
        // Under the title bar, as the SwiftUI pane was: its transcript starts
        // beside the window's controls.
        Host(model: model, session: session, chat: chat, side: side, sideActions: sideActions)
            .ignoresSafeArea(.container, edges: .top)
    }
    private struct Host: NSViewRepresentable {
        let model: WorkspaceModel
        let session: SessionDisplay
        let chat: ChatRecord
        var side: SideRecord?
        var sideActions: SideActions?
        func makeNSView(context: Context) -> ConversationPaneView {
            let view = ConversationPaneView(model: model)
            view.show(session: session, chat: chat, side: side, sideActions: sideActions)
            return view
        }
        func updateNSView(_ view: ConversationPaneView, context: Context) {
            view.inheritedEnabled = context.environment.isEnabled
            view.show(session: session, chat: chat, side: side, sideActions: sideActions)
        }

    }
}

