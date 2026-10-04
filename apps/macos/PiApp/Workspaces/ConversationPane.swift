import AppKit
import SwiftUI

// The chat itself: the transcript, what sits above it (a side's header, a
// recovery banner, a starter card) and what sits below it (the queue, the
// terminal, the composer and the metrics footer).
//
// TEMPORARY bridges in this file, until their owners are AppKit: the
// transcript (Transcript/, `NativeTranscriptView`), the queue panel and the
// terminal panel (next in this workstream), and the metrics footer
// (Inspector/), each in a hosting view the pane lays out; and the
// `ConversationPane` representable the still-SwiftUI workspace, side and
// tab panes host the AppKit pane through.

struct SideActions {
    var bringBack: () -> Void
    var keep: () -> Void
    var close: () -> Void
}

/// One column's conversation: kept across chats, so a click in the sidebar
/// hands it another chat (`show`) rather than building a new pane, its
/// transcript's document and its row hosts with it. Everything in it that
/// belongs to one chat — the composer's editor, the queue's own state — is
/// that chat's.
@MainActor final class ConversationPaneView: NSView {
    let model: WorkspaceModel
    private(set) var session: SessionDisplay?
    private(set) var chat: ChatRecord?
    private(set) var side: SideRecord?
    private var sideActions: SideActions?

    private let sideHeader: SideHeaderView
    private let sideLine = CALayer()
    private let recovered = RecoveredBannerView()
    let transcript = ShellHostingView(rootView: AnyView(EmptyView()))
    private let starter = StarterPanelView()
    private let cover = LoadingCoverView()
    private var queue: QueuePanelView?
    private var terminal: ShellHostingView?
    private var terminalWorkspace: WorkspaceRecord?
    private let missingFolder = MissingFolderBar()
    private let footer = PaneFooterView()
    let composer: ComposerInputView
    private let metrics = ShellHostingView(rootView: AnyView(EmptyView()))
    private var observer: ShellObserver?
    private var shown: State?
    private var coverTask: Task<Void, Never>?
    private var coverDue = false
    /// The room the queue's list last had, handed to it after layout.
    private var queueRoom: CGFloat = .infinity

    /// Whether the loading cover stands over the transcript. A revisit of a
    /// chat whose rows are already on the page reads its fresh page behind
    /// those rows, not behind a cover; a first message being sent is already
    /// on the page and is not covered while the helper starts.
    @MainActor static func coversTranscript(_ session: SessionDisplay) -> Bool {
        session.historyState.loading && !session.refreshingCachedRows
            || session.loading && session.messages.isEmpty && session.sendingRows.isEmpty
    }
    static let coverDelay = Duration.milliseconds(150)

    /// What the pane shows around the transcript, read once per change.
    private struct State: Equatable {
        var sessionID: String
        var chat: ChatRecord
        var side: SideRecord?
        var showsStarter: Bool
        /// Everything the starter card shows, so an edit to any of it redraws the card.
        var starterKey: String
        var covered: Bool
        var failure: String?
        var progress: String?
        var showsRecovered: Bool
        var recovered: [String]
        var showsQueue: Bool
        var terminalWorkspace: WorkspaceRecord?
        var missingFolder: String?
        var footer: PaneFooterView.Kind
        var transcriptState: String
        var canFork: Bool
        var canQuote: Bool
        var contextWindow: Int?
        var outputReserve: Int?
        var sideBoundary: String
        var sideBoundaryDetail: String
        var sideLoading: Bool
        /// The window's disabled state, which the bridged SwiftUI roots take too.
        var enabled: Bool
    }

    init(model: WorkspaceModel) {
        self.model = model
        composer = ComposerInputView(model: model)
        sideHeader = SideHeaderView(model: model)
        super.init(frame: .zero)
        wantsLayer = true
        // What stands out past the pane (a composer wider than a narrow
        // pane) is cut at its edges, as the SwiftUI pane cut it.
        clipsToBounds = true
        for view in [recovered, transcript, starter, cover, missingFolder, footer, metrics] as [NSView] { addSubview(view) }
        // The composer last: its slash-command list floats over everything above it.
        addSubview(composer)
        layer?.addSublayer(sideLine)
        composer.heightChanged = { [weak self] in self?.needsLayout = true }
        for host in [transcript, metrics] { host.sizeChanged = { [weak self] in self?.needsLayout = true } }
        recovered.changed = { [weak self] in self?.needsLayout = true }
        cover.isHidden = true
        starter.removeFromSuperview()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    // MARK: The chat shown

    /// Shows `chat`, its page `session`, and for a side its record and its
    /// header's actions. The rows, the composer and the queue follow before
    /// the pane is next drawn.
    func show(session: SessionDisplay, chat: ChatRecord, side: SideRecord? = nil, sideActions: SideActions? = nil) {
        let switched = session !== self.session
        self.session = session; self.chat = chat; self.side = side; self.sideActions = sideActions
        sideHeader.actions = sideActions
        if switched {
            let observer = ShellObserver { [weak self] in self?.refresh() }
            observer.observe(model); observer.observe(session); observer.observe(session.footer)
            self.observer = observer
            composer.retire()
            // The queue panel keeps nothing of its own: it starts over for each chat.
            queue?.removeFromSuperview(); queue = nil
            // A card whose arguments the host had to cut asks it for the rest
            // when the reader opens it.
            session.toolInputs.load = { [weak model, weak session] messageID, callID in
                guard let model, let session else { throw HostError.failure("This conversation is gone") }
                return try await model.toolInput(sessionID: session.id, messageID: messageID, callID: callID)
            }
            coverDue = false; coverTask?.cancel(); coverTask = nil
            shown = nil
        }
        refresh()
    }

    private var profile: ProfileRecord? { chat.flatMap { chat in model.profiles.first { $0.id == chat.profileID } } }
    /// The disabled state handed down from the window: every control in
    /// the pane follows it, as SwiftUI's `.disabled` reached them.
    var inheritedEnabled = true {
        didSet {
            guard oldValue != inheritedEnabled else { return }
            composer.inheritedEnabled = inheritedEnabled
            for view in [sideHeader, recovered, footer, missingFolder, starter, cover] as [NSView] { enable(view, inheritedEnabled) }
            shown = nil; refresh()
        }
    }
    /// The controls the window's disabled state turned off, to turn back on.
    private var inheritedOff: [Weak<NSControl>] = []
    struct Weak<T: AnyObject> { weak var value: T? }
    /// Disables (or enables again) every control in `view`, keeping each
    /// one's own reason to be disabled where it has one.
    private func enable(_ view: NSView, _ enabled: Bool) {
        if enabled {
            for control in inheritedOff.compactMap(\.value) where control.isDescendant(of: view) { control.isEnabled = true }
            inheritedOff.removeAll { $0.value == nil || $0.value!.isDescendant(of: view) }
        } else {
            for control in PiKit.controls(in: view) where control.isEnabled {
                control.isEnabled = false
                if !inheritedOff.contains(where: { $0.value === control }) { inheritedOff.append(Weak(value: control)) }
            }
        }
    }
    /// The narrowest the pane is: its composer's controls.
    var minimumWidth: CGFloat { composer.isHidden ? 0 : composer.minimumWidth }

    private func read(_ session: SessionDisplay, _ chat: ChatRecord) -> State {
        // The record its parent handed it: the parent hands it again as it changes.
        let current = chat
        let projectAvailable = model.workspace(for: current.workspaceID) != nil
        let side = self.side.flatMap { model.sides[$0.parentID]?.id == $0.id ? model.sides[$0.parentID] : $0 } ?? self.side
        let showsStarter = session.historyState == .empty && session.messages.isEmpty && session.sendingRows.isEmpty && !session.busy && !session.loading
            && session.failureMessage == nil && session.sendFailure == nil
            && !current.imported && !current.isBackgroundTask && projectAvailable && (side == nil || side?.pending == true)
        var failure: String?
        if case .failed(let error) = session.historyState { failure = error }
        let terminalWorkspace = model.terminalVisible && side == nil ? model.workspace(for: current.workspaceID).flatMap { $0.isScratch ? nil : $0 } : nil
        let kind: PaneFooterView.Kind
        if !projectAvailable { kind = .projectUnavailable(retry: !model.configurationLoaded) }
        else if current.isBackgroundTask {
            kind = .backgroundTask(busy: session.busy, source: current.sourceSessionID.flatMap { model.record($0) != nil ? $0 : nil })
        } else if current.isArchived { kind = .archived }
        else if session.damagedTail { kind = .damaged }
        else if current.imported { kind = .imported(choice: model.profileChoice, profiles: model.requestProfiles.map { PaneFooterView.Profile(id: $0.id, name: $0.name) }) }
        else { kind = .composer }
        return State(sessionID: session.id, chat: current, side: side, showsStarter: showsStarter,
                     starterKey: showsStarter ? StarterPanelView.key(model: model, chat: current, sessionID: session.id) : "",
                     covered: Self.coversTranscript(session), failure: failure, progress: session.historyProgress,
                     showsRecovered: session.uncertain && !session.busy && !session.recovered.isEmpty,
                     recovered: session.recovered.map(\.id),
                     showsQueue: !session.queue.isEmpty || session.queueDetailID != nil,
                     terminalWorkspace: terminalWorkspace, missingFolder: model.missingProjectFolders[current.workspaceID],
                     footer: kind, transcriptState: session.state, canFork: model.canForkFromReply(session.id),
                     canQuote: model.canQuoteReply(session.id),
                     contextWindow: current.contextWindow ?? profile?.contextWindow, outputReserve: current.maxOutputTokens ?? profile?.maxOutputTokens,
                     sideBoundary: side.map { Self.boundary($0, model: model) } ?? "", sideBoundaryDetail: side.map { Self.boundaryDetail($0) } ?? "",
                     sideLoading: session.loading, enabled: inheritedEnabled)
    }

    /// Reads the chat and the workspace again and changes only what differs.
    func refresh() {
        guard let session, let chat else { return }
        let now = read(session, chat)
        guard now != shown else { return }
        let before = shown
        shown = now
        apply(now, before: before, session: session)
        // The new geometry is worked out now, in the turn that changed it, as
        // SwiftUI applied an update in its own transaction: the next frame
        // only draws it.
        if window != nil { layoutSubtreeIfNeeded() }
    }

    private func apply(_ state: State, before: State?, session: SessionDisplay) {
        let chat = state.chat
        // The transcript: a new root only when what it is drawn from changed.
        if before?.sessionID != state.sessionID || before?.transcriptState != state.transcriptState
            || before?.canFork != state.canFork || before?.canQuote != state.canQuote || before?.enabled != state.enabled {
            transcript.setRoot(AnyView(TranscriptBridge(model: model, session: session, state: state.transcriptState, canFork: state.canFork, canQuote: state.canQuote).disabled(!state.enabled)), reportsHeight: false)
        }
        // Above it: a side's header and a recovery banner.
        // A side's header is in the pane only while it shows a side.
        if state.side == nil { sideHeader.removeFromSuperview() } else if sideHeader.superview !== self { addSubview(sideHeader) }
        sideLine.isHidden = state.side == nil
        if let side = state.side {
            sideHeader.update(side: side, chat: chat, session: session, boundary: state.sideBoundary, detail: state.sideBoundaryDetail, loading: state.sideLoading)
        }
        recovered.isHidden = !state.showsRecovered
        if state.showsRecovered { recovered.update(session.recovered, model: model) }
        // Over it: the starter card and the loading cover.
        if before?.showsStarter != state.showsStarter {
            if state.showsStarter {
                if starter.superview !== self { addSubview(starter, positioned: .above, relativeTo: transcript) }
                starter.isHidden = false
                starter.update(model: model, chat: chat, sessionID: session.id)
            }
            // It fades in and out (`.transition(.opacity)`), and is gone once out.
            let animated = before != nil && window != nil && !PiKit.Motion.reduced
            if state.showsStarter, animated { starter.layer?.opacity = 0 }
            PiKit.Motion.layers(PiKit.Motion.quick, animated: animated) { starter.layer?.opacity = state.showsStarter ? 1 : 0 }
            if !state.showsStarter {
                if animated {
                    DispatchQueue.main.asyncAfter(deadline: .now() + PiKit.Motion.quick) { [weak self] in
                        MainActor.assumeIsolated { if self?.shown?.showsStarter == false { self?.starter.removeFromSuperview() } }
                    }
                } else { starter.removeFromSuperview() }
            }
        } else if state.showsStarter, before?.starterKey != state.starterKey { starter.update(model: model, chat: chat, sessionID: session.id) }
        updateCover(state, before: before)
        // Below it: the queue, the terminal, the folder bar, the footer and the figures.
        if state.showsQueue, queue == nil {
            let host = QueuePanelView(model: model, session: session)
            host.room = queueRoom; host.inheritedEnabled = inheritedEnabled
            host.sizeChanged = { [weak self] in self?.needsLayout = true }
            addSubview(host, positioned: .below, relativeTo: composer)
            host.frame = CGRect(x: 0, y: bounds.height, width: bounds.width, height: host.height(forWidth: bounds.width))
            host.layoutSubtreeIfNeeded()
            queue = host
            arrive(host, before: before)
        } else if !state.showsQueue, let host = queue {
            queue = nil
            leave(host)
        }
        if let workspace = state.terminalWorkspace {
            if let host = terminal {
                // The same panel follows its project's record (a relocated folder).
                if terminalWorkspace != workspace || before?.enabled != state.enabled {
                    if terminalWorkspace?.id != workspace.id {
                        host.removeFromSuperview(); terminal = nil
                    } else {
                        host.setRoot(AnyView(TerminalPanel(model: model, workspace: workspace).disabled(!state.enabled).piShellBridged()), reportsHeight: false)
                        terminalWorkspace = workspace
                    }
                }
            }
            if terminal == nil {
                let arriving = before?.terminalWorkspace == nil
                let host = ShellHostingView(root: AnyView(TerminalPanel(model: model, workspace: workspace).disabled(!state.enabled).piShellBridged()), reportsHeight: false)
                host.minimum = TerminalPanel.minimumHeight + TerminalPanel.chromeHeight
                host.sizeChanged = { [weak self] in self?.needsLayout = true }
                addSubview(host, positioned: .below, relativeTo: composer)
                terminal = host; terminalWorkspace = workspace
                if arriving { arrive(host, before: before) }
            }
        } else if let host = terminal {
            terminal = nil; terminalWorkspace = nil
            leave(host)
        }
        queue?.inheritedEnabled = state.enabled
        // The window's disabled state over whatever the updates above enabled.
        if !state.enabled { for view in [sideHeader, recovered, footer, missingFolder, starter, cover] as [NSView] { enable(view, false) } }
        missingFolder.isHidden = state.missingFolder == nil
        if let missing = state.missingFolder { missingFolder.update(missing, workspaceID: chat.workspaceID, model: model) }
        footer.isHidden = state.footer == .composer
        composer.isHidden = state.footer != .composer
        // As the SwiftUI pane did, the composer (and its editor) goes while a
        // footer stands in its place, and comes back made for the chat.
        if state.footer == .composer { if composer.session !== session { composer.show(session) } } else if composer.session != nil { composer.retire() }
        if state.footer != .composer {
            footer.update(state.footer, chat: chat, session: session, model: model)
            if !state.enabled { enable(footer, false) }
        }
        composer.maximumFieldHeight = state.terminalWorkspace != nil ? ComposerScrollView.besideTerminalHeight : ComposerScrollView.maximumHeight
        if before?.sessionID != state.sessionID || before?.contextWindow != state.contextWindow || before?.outputReserve != state.outputReserve
            || (before?.side == nil) != (state.side == nil) || before?.enabled != state.enabled {
            let model = self.model, id = session.id
            metrics.setRoot(AnyView(MetricsFooter(model: model, session: session, contextWindow: state.contextWindow,
                                                     outputReserve: state.outputReserve, compact: state.side != nil) { [model, id] in
                model.openInspector(session: id, focus: .overview)
            }.disabled(!state.enabled).piShellBridged()))
        }
        needsLayout = true
    }


    // MARK: The loading cover

    private func updateCover(_ state: State, before: State?) {
        if state.covered {
            // It appears at once when due and fades only on its way out.
            if before?.covered != true || before?.sessionID != state.sessionID {
                coverTask?.cancel(); coverDue = false
                coverTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.coverDelay)
                    guard let self, !Task.isCancelled, self.shown?.covered == true else { return }
                    self.coverDue = true
                    self.showCover()
                }
            }
            if coverDue { showCover() } else if state.failure == nil { hideCover(animated: false) }
        } else {
            coverTask?.cancel(); coverTask = nil; coverDue = false
            if let failure = state.failure {
                cover.showFailure(failure) { [weak self] in
                    guard let self, let session = self.session else { return }
                    self.model.reloadHistory(session.id)
                }
                cover.isHidden = false; cover.layer?.opacity = 1
            } else {
                hideCover(animated: before?.covered == true)
            }
        }
    }
    private func showCover() {
        cover.showLoading(progress: shown?.progress)
        cover.isHidden = false
        CATransaction.begin(); CATransaction.setDisableActions(true); cover.layer?.opacity = 1; CATransaction.commit()
        needsLayout = true
    }
    private func hideCover(animated: Bool) {
        guard !cover.isHidden else { return }
        guard animated, !PiKit.Motion.reduced else { cover.isHidden = true; return }
        PiKit.Motion.layers(PiKit.Motion.quick) { cover.layer?.opacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + PiKit.Motion.quick) { [weak self] in
            guard let self, self.cover.layer?.opacity == 0 else { return }
            self.cover.isHidden = true
        }
    }

    // MARK: Panels arriving and leaving

    /// The follow-up panel and the terminal slide in from the bottom of the
    /// pane and fade as they come; both take their room from below the
    /// conversation, so it is the composer's edge that moves.
    private var animatesNextLayout = false
    private func arrive(_ host: NSView, before: State?) {
        guard before != nil, !PiKit.Motion.reduced else { return }
        animatesNextLayout = true
        host.wantsLayer = true
        host.layer?.opacity = 0
        arriving.insert(ObjectIdentifier(host))
    }
    private var arriving: Set<ObjectIdentifier> = []
    private var leaving: [NSView] = []
    private func leave(_ host: NSView) {
        guard !PiKit.Motion.reduced, window != nil else { host.removeFromSuperview(); return }
        animatesNextLayout = true
        leaving.append(host)
    }

    /// `.move(edge: .bottom).combined(with: .opacity)` on the view's own
    /// layer: its translation and opacity, eased over the base duration.
    private static func slide(_ view: NSView, arriving: Bool, done: (() -> Void)? = nil) {
        view.wantsLayer = true
        guard let layer = view.layer else { done?(); return }
        let height = view.frame.height
        CATransaction.begin()
        CATransaction.setCompletionBlock { done?() }
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        // Flipped or not, "below" is down the screen.
        let below = view.superview?.isFlipped == true ? height : -height
        move.fromValue = arriving ? below : 0; move.toValue = arriving ? 0 : below
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = arriving ? 0 : 1; fade.toValue = arriving ? 1 : 0
        let group = CAAnimationGroup()
        group.animations = [move, fade]; group.duration = PiKit.Motion.base
        group.timingFunction = PiKit.Motion.timing(.easeOut)
        if !arriving { group.fillMode = .forwards; group.isRemovedOnCompletion = false }
        layer.add(group, forKey: "panel")
        CATransaction.commit()
    }

    // MARK: Layout

    private static let sideLineHeight: CGFloat = 1
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { composer.paneWidth = newSize.width }
        needsLayout = true
    }
    private func hostHeight(_ host: ShellHostingView?, width: CGFloat) -> CGFloat {
        guard let host else { return 0 }
        return host.height(forWidth: width)
    }
    override func layout() {
        super.layout()
        let width = bounds.width
        var top: CGFloat = 0
        var frames: [(NSView, CGRect)] = []
        if sideHeader.superview === self {
            let height = sideHeader.height(forWidth: width)
            frames.append((sideHeader, CGRect(x: 0, y: 0, width: width, height: height)))
            top = height + Self.sideLineHeight
        }
        if !recovered.isHidden {
            let height = recovered.height(forWidth: width)
            frames.append((recovered, CGRect(x: 0, y: top, width: width, height: height)))
            top += height
        }
        // From the bottom up: the figures, the composer or footer, the folder bar, the terminal, the queue.
        var bottom = bounds.height
        let metricsHeight = metrics.height(forWidth: width)
        bottom -= metricsHeight
        frames.append((metrics, CGRect(x: 0, y: bottom, width: width, height: metricsHeight)))
        let lower: NSView = composer.isHidden ? footer : composer
        let lowerHeight = composer.isHidden ? footer.height(forWidth: width) : composer.height(forWidth: width)
        bottom -= lowerHeight
        frames.append((lower, CGRect(x: 0, y: bottom, width: width, height: lowerHeight)))
        let composerHeight = composer.isHidden ? 0 : lowerHeight
        if !missingFolder.isHidden {
            let height = missingFolder.height(forWidth: width)
            bottom -= height
            frames.append((missingFolder, CGRect(x: 0, y: bottom, width: width, height: height)))
        }
        // The queue's list takes only what the pane has after the composer,
        // an open terminal and the transcript's reading space.
        let room = QueuePanel.room(pane: bounds.height, composer: composerHeight,
                                   terminal: terminal != nil ? TerminalPanel.minimumHeight + TerminalPanel.chromeHeight : 0)
        if room != queueRoom {
            queueRoom = room
            queue?.room = room
        }
        // Bottom up: the terminal on the folder bar (or the composer), the
        // queue on the terminal. The queue's height is its own; the terminal
        // and the transcript share what is left, as a stack shares it between
        // two flexible views: the terminal, the less flexible, is offered half
        // and takes it within its own bounds; the transcript takes the rest.
        let queueHeight = queue.map { $0.height(forWidth: width) } ?? 0
        var terminalHeight: CGFloat = 0
        if let terminal {
            let remaining = max(0, bottom - queueHeight - top)
            let least = terminal.minimumHeight(forWidth: width), most = max(least, hostHeight(terminal, width: width))
            terminalHeight = min(most, max(least, (remaining / 2).rounded(.down)))
            frames.append((terminal, CGRect(x: 0, y: bottom - terminalHeight, width: width, height: terminalHeight)))
        }
        bottom -= terminalHeight
        if let queue {
            frames.append((queue, CGRect(x: 0, y: bottom - queueHeight, width: width, height: queueHeight)))
            bottom -= queueHeight
        }
        let transcriptFrame = CGRect(x: 0, y: top, width: width, height: max(0, bottom - top))
        frames.append((transcript, transcriptFrame))
        let animate = animatesNextLayout && window != nil && !PiKit.Motion.reduced
        animatesNextLayout = false
        let gone = leaving; leaving = []
        // The layout lands in one step: every frame is final at once. Only
        // a panel that comes or goes moves, on its own layer, sliding from
        // (or to) below its place and fading, over room already given.
        for (view, frame) in frames where view.frame != frame { view.frame = frame }
        for (view, _) in frames where arriving.contains(ObjectIdentifier(view)) {
            view.layer?.opacity = 1
            if animate { Self.slide(view, arriving: true) }
        }
        for view in gone {
            if animate, view.window != nil {
                Self.slide(view, arriving: false) { [weak view] in view?.removeFromSuperview() }
            } else { view.removeFromSuperview() }
        }
        arriving.removeAll()
        // Over the transcript: the starter card at its top, the cover over all of it.
        if starter.superview === self {
            let cardWidth = min(transcriptFrame.width, StarterPanelView.maximumWidth)
            let height = starter.height(forWidth: cardWidth)
            starter.frame = CGRect(x: PiKit.round(transcriptFrame.midX - cardWidth / 2, piScale), y: transcriptFrame.minY + PiSpacing.xl,
                                   width: cardWidth, height: height)
        }
        cover.frame = transcriptFrame
        CATransaction.begin(); CATransaction.setDisableActions(true)
        sideLine.frame = CGRect(x: 0, y: sideHeader.frame.maxY, width: width, height: Self.sideLineHeight)
        sideLine.backgroundColor = piCGColor(.piHairline)
        CATransaction.commit()
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piContent) }

    // MARK: Words for a side

    /// Plain words for what the side shares; the identifiers stay in the tooltip.
    static func boundary(_ side: SideRecord, model: WorkspaceModel) -> String {
        if side.pending { return "Draft side · takes the parent's context when you send your first message" }
        guard let cutoff = side.boundary["cutoffEntryId"]?.string else { return "Shares the parent's context as of when it opened" }
        let parent = model.displays[side.parentID]?.messages.first { $0.id == cutoff }
        let preview = parent.map { String($0.text.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        let upTo = preview.map { "up to “\($0.count > 60 ? String($0.prefix(59)) + "…" : $0)”" } ?? "as of when it opened"
        return "Shares the parent's context \(upTo)" + (side.boundary["instructionsRefreshed"]?.bool == true ? " · instructions refreshed" : "")
    }
    static func boundaryDetail(_ side: SideRecord) -> String {
        "Snapshot through \(side.boundary["cutoffEntryId"]?.string ?? "empty context") · \(Int(side.boundary["omittedIncompleteEntries"]?.number ?? 0)) incomplete entries omitted"
            + (side.boundary["instructionsRefreshed"]?.bool == true ? " · instructions refreshed" : " · initial instruction snapshot")
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

// MARK: - The chat's actions

/// The chat's actions, reachable from the composer bar (and the side header): the
/// conversation itself has no header bar. The menu is built when it opens,
/// from the chat as it is then.
@MainActor final class ConversationActionsMenuView: NSView {
    let model: WorkspaceModel
    var sessionID: String
    /// The chat's page, when the menu's owner has it; else the workspace's.
    weak var session: SessionDisplay?
    private let face = Face()
    private var control: PiKit.MenuControl!
    static let size = CGSize(width: 28, height: 28)

    /// The "…" in its soft circle, firmer under the pointer.
    final class Face: NSView {
        var hovering = false { didSet { if oldValue != hovering { needsLayout = true; needsDisplay = true } } }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var wantsUpdateLayer: Bool { false }
        override func draw(_ dirtyRect: NSRect) {
            (hovering ? NSColor.piFillStrong : NSColor.piFill).setFill()
            NSBezierPath(ovalIn: bounds).fill()
            PiKit.Symbol("ellipsis", size: 13, weight: .semibold).draw(centredIn: bounds, color: hovering ? .piInk : .piInkSecondary, scale: piScale)
        }
    }

    init(model: WorkspaceModel, sessionID: String) {
        self.model = model; self.sessionID = sessionID
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        control = PiKit.MenuControl(label: "Chat actions", identifier: "conversationActions", help: "Chat actions", face: face,
                                    onHover: { [weak face] in face?.hovering = $0 }) { [weak self] in
            guard let self, let session = self.session.flatMap({ $0.id == self.sessionID ? $0 : nil }) ?? self.model.displays[self.sessionID],
                  let chat = self.model.record(self.sessionID) else { return [] }
            return ConversationActionsMenu.entries(model: self.model, session: session, chat: chat)
        }
        addSubview(control)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { Self.size }
    var isEnabled: Bool { get { control.isEnabled } set { control.isEnabled = newValue } }
    override func layout() { super.layout(); control.frame = bounds; face.frame = control.bounds }
}

/// What the chat's actions menu offers, built when it opens.
enum ConversationActionsMenu {
    @MainActor @PiMenuBuilder static func entries(model: WorkspaceModel, session: SessionDisplay, chat: ChatRecord) -> [PiMenuEntry] {
        if !chat.isBackgroundTask {
            PiMenuEntry.button("Rename Chat…") { model.renameSession(chat.id) }
            if !chat.imported, !chat.isArchived {
                PiMenuEntry.button("Generate Title", enabled: model.titleSuggestionsAvailable(for: model.profiles.first { $0.id == chat.profileID } ?? ProfileRecord())) {
                    model.regenerateTitle(chat.id)
                }
            }
        }
        if !model.isEphemeral(session.id) {
            SessionOrganizationActions.entries(model: model, chat: chat)
            PiMenuEntry.divider
        }
        if model.activeWebhook != nil, model.webhookEligible(chat.id) {
            PiMenuEntry.button("Send Webhook When Done", checked: chat.webhookOff != true, identifier: "chatWebhook",
                               help: "When this chat finishes and waits for you, send the webhook set up in Settings") { model.toggleWebhook(for: chat.id) }
            PiMenuEntry.button("Preview Webhook…", identifier: "previewWebhook") { model.previewWebhook(chat.id) }
            PiMenuEntry.divider
        }
        if model.side(session.id) == nil && !chat.isBackgroundTask {
            PiMenuEntry.button("Open Side", enabled: model.canOpenSide(session.id)) { model.openSide(parentID: session.id) }
            PiMenuEntry.button("Portable Context Handoff…") { model.portableHandoff() }
            if chat.toolMode == ChatRecord.readOnlyTools && chat.connectionTest != true && chat.workspaceID != WorkspaceRecord.scratchID {
                PiMenuEntry.button("Enable Editing Tools…", enabled: !session.hasWork) { model.enableEditing(session.id) }
            }
            PiMenuEntry.divider
        }
        if !chat.isBackgroundTask { PiMenuEntry.button("Compact Now", identifier: "compactNow") { model.action("context.compact", sessionID: session.id) } }
        if session.before != nil || session.hostBefore != nil { PiMenuEntry.button("Earlier Messages") { model.loadEarlier(sessionID: session.id) } }
        PiMenuEntry.button("Latest Messages") { model.latest(sessionID: session.id) }
        PiMenuEntry.divider
        SessionReferenceActions.entries(model: model, sessionID: session.id)
        PiMenuEntry.divider
        PiMenuEntry.button("Search and Copy Conversation…") { model.inspectConversation(session.id) }
        PiMenuEntry.button("Session Inspector…", identifier: "sessionInspector") { model.inspect(session.id) }
        if model.side(session.id) == nil {
            PiMenuEntry.divider
            PiMenuEntry.button("Delete Chat…") { model.deleteChat(chat.id) }
        }
    }
}
