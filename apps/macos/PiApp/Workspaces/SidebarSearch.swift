import AppKit
import Combine

// The sidebar's search inside chats, on the main actor: what the filter
// field holds, the content matches the index found for it, keeping the
// index current, and opening a chat at its match. The index itself is
// Storage/ChatSearchIndex.swift; the snippet under a matching row is
// `SidebarSearchSnippetView` below.

@MainActor final class SidebarSearch {
    private weak var model: WorkspaceModel?
    let index: ChatSearchIndex
    let reader: ChatSearchQuery
    /// What the field holds, whitespace collapsed: titles are filtered by it
    /// at once, content once the index answers.
    private(set) var query = ""
    /// Each chat's newest content match for `query`. Always true of `query`:
    /// a longer query keeps only the earlier matches that still hold
    /// (`ChatSearchHit.refined`), a shorter one keeps them all, anything else
    /// drops them, until the index's own answer replaces them.
    private(set) var hits: [String: ChatSearchHit] = [:] { didSet { matchedIDs = Set(hits.keys) } }
    private(set) var matchedIDs: Set<String> = []
    /// The sidebar redraws: content matches arrived or went.
    var changed: (() -> Void)?

    /// How long typing rests before the index is asked.
    var debounce: Duration = .milliseconds(120)
    /// How long a change (a chat added or gone, a run's progress) rests
    /// before the index is brought up to date.
    var settleDelay: Duration = .milliseconds(1_500)
    /// Indexing starts on its own a little after launch in the app; in tests
    /// it starts with the first content query or `reconcileNow()`.
    static var startsAutomatically = ProcessInfo.processInfo.environment["PI_APP_TESTING"] != "1"
    static let launchDelay: Duration = .seconds(3)

    private var queryTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    private var reconcileAgain = false
    /// The pass itself, off the main actor: cancelled at shutdown.
    private var worker: Task<ChatSearchIndex.Pass, Never>?
    private var settleTask: Task<Void, Never>?
    private var watches: [AnyCancellable] = []
    private(set) var indexing = false
    private var stopped = false
    /// Sidebar opens so far (`beginSidebarOpen`).
    var openings = 0
    /// The reveal under way: a changed field or another open cancels it.
    var revealing: Task<Void, Never>?
    /// Test seams: queries answered by the index, and passes run.
    private(set) var answeredQueries = 0
    private(set) var lastPass = ChatSearchIndex.Pass()
    private(set) var passes = 0

    init(model: WorkspaceModel) {
        self.model = model
        let url = model.root.appendingPathComponent(ChatSearchDatabase.fileName)
        index = ChatSearchIndex(url: url)
        reader = ChatSearchQuery(url: url)
    }

    /// The sidebar is up: keep the index current from now on.
    func activate() {
        guard watches.isEmpty, let model else { return }
        known = Set(model.chats.map(\.id))
        watches.append(model.$chats.dropFirst().sink { [weak self] chats in MainActor.assumeIsolated { self?.chatsChanged(chats) } })
        watches.append(model.activityChanged.sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleReconcile() } })
        if Self.startsAutomatically, !indexing {
            settleTask = Task { [weak self] in
                try? await Task.sleep(for: Self.launchDelay)
                guard !Task.isCancelled else { return }
                self?.startIndexing()
            }
        }
    }

    /// The chats the model listed last time: one gone was deleted.
    private var known: Set<String> = []
    private func chatsChanged(_ chats: [ChatRecord]) {
        let now = Set(chats.map(\.id)), gone = known.subtracting(now)
        known = now
        if !gone.isEmpty {
            // Off the sidebar at once, and out of the index as soon as no
            // pass is writing; a pass reading one of them commits nothing.
            if hits.keys.contains(where: gone.contains) { hits = hits.filter { !gone.contains($0.key) }; changed?() }
            let index = index
            Task.detached(priority: .utility) { await index.forget(gone) }
        }
        scheduleReconcile()
    }

    func shutdown() {
        stopped = true
        watches.removeAll()
        worker?.cancel()
        revealing?.cancel(); revealing = nil
        for task in [queryTask, reconcileTask, settleTask] { task?.cancel() }
        reader.cancel()
        let index = index
        Task.detached(priority: .utility) { await index.close() }
    }

    // MARK: Typing

    /// The field changed. Titles follow at once (the sidebar filters them
    /// itself); the index is asked once typing rests, and a query still
    /// running for older text is stopped.
    func setQuery(_ raw: String) {
        let new = ChatSearchHit.collapsed(raw)
        guard new != query else { return }
        let old = query
        query = new
        queryTask?.cancel(); reader.cancel()
        revealing?.cancel(); revealing = nil
        guard ChatSearchDatabase.answers(new) else {
            if !hits.isEmpty { hits = [:] }
            return
        }
        if ChatSearchDatabase.answers(old), new.localizedCaseInsensitiveContains(old) {
            hits = hits.compactMapValues { $0.refined(to: new) }
        } else if !(ChatSearchDatabase.answers(old) && old.localizedCaseInsensitiveContains(new)) {
            if !hits.isEmpty { hits = [:] }
        }
        if indexing, ContinuousClock.now - lastPassEnded > .seconds(2) { scheduleReconcile(after: .zero) }
        startIndexing()
        let delay = debounce
        queryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.ask(new)
        }
    }

    /// Asks the index for `text` and shows the answer if it is still what
    /// the field holds.
    private func ask(_ text: String) async {
        guard !stopped else { return }
        let found: [String: ChatSearchHit]
        do { found = try await reader.search(text) } catch { return }
        guard !Task.isCancelled, text == query, !stopped else { return }
        answeredQueries += 1
        guard found != hits else { return }
        hits = found
        model?.sidebarIndex.invalidate()
        changed?()
    }

    /// The match a listed chat shows and opens at, while the field asks for one.
    func hit(for chatID: String) -> ChatSearchHit? { hits[chatID] }

    /// Waits for the current query's answer (tests).
    func settleQuery() async { await queryTask?.value }

    // MARK: Keeping the index current

    private func startIndexing() {
        guard !indexing, !stopped else { return }
        indexing = true
        scheduleReconcile(after: .zero)
    }

    /// A chat's journal was written (`session.changed`): it is indexed again
    /// once the writes rest, and at least every few seconds while they go on.
    func journalChanged() { scheduleReconcile() }

    /// The longest a stream of changes holds a pass back.
    var maximumDelay: Duration = .seconds(5)
    private var firstWaiting: ContinuousClock.Instant?
    private func scheduleReconcile(after delay: Duration? = nil) {
        guard indexing, !stopped else { return }
        let now = ContinuousClock.now
        let first = firstWaiting ?? now
        firstWaiting = first
        // Rests for `settleDelay`, but never past `maximumDelay` from the first change.
        let wait = min(delay ?? settleDelay, max(.zero, maximumDelay - (now - first)))
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled, let self else { return }
            self.firstWaiting = nil
            self.runReconcile()
        }
    }

    /// The chats the sidebar can list: saved chats with a journal, but no
    /// background request and no side the reader has not kept.
    func sources() -> [ChatSearchSource] {
        guard let model else { return [] }
        return model.chats.compactMap { chat in
            guard let path = chat.path, !chat.isBackgroundTask, model.side(chat.id)?.kept != false,
                  !model.pendingChatIDs.contains(chat.id) else { return nil }
            return ChatSearchSource(id: chat.id, path: path, rebuildsOnChange: chat.imported)
        }
    }

    private func runReconcile() {
        guard reconcileTask == nil else { reconcileAgain = true; return }
        guard let model, !stopped else { return }
        // Until launch has listed the saved chats, an empty list is not a
        // list of none: pruning against it would empty the index.
        guard !model.launching, model.store != nil else { scheduleReconcile(); return }
        let sources = sources(), index = index
        let worker = Task.detached(priority: .utility) {
            await index.reconcile(sources) { [weak self] in await self?.indexChanged() }
        }
        self.worker = worker
        reconcileTask = Task { [weak self] in
            let pass = await worker.value
            guard let self else { return }
            self.reconcileTask = nil; self.worker = nil
            self.lastPass = pass; self.passes += 1; self.lastPassEnded = .now
            if pass.changed { self.indexChanged(throttled: false) }
            if self.reconcileAgain { self.reconcileAgain = false; self.runReconcile() }
        }
    }

    /// Brings the index up to date now and waits for it (tests, and a pass
    /// that must have finished before a query).
    @discardableResult func reconcileNow() async -> ChatSearchIndex.Pass {
        indexing = true
        while let running = reconcileTask { await running.value }
        settleTask?.cancel()
        runReconcile()
        await reconcileTask?.value
        return lastPass
    }

    private var lastRequery = ContinuousClock.now - .seconds(10)
    private var lastPassEnded = ContinuousClock.now - .seconds(10)
    /// Something a query finds changed: the field's query is asked again,
    /// at most a few times a second while a long pass runs.
    private func indexChanged(throttled: Bool = true) {
        guard ChatSearchDatabase.answers(query), !stopped else { return }
        let now = ContinuousClock.now
        guard !throttled || now - lastRequery > .milliseconds(500) else { return }
        lastRequery = now
        let text = query
        queryTask?.cancel(); reader.cancel()
        queryTask = Task { [weak self] in await self?.ask(text) }
    }
}

// MARK: - Opening at the match

/// The one place the sidebar's search opens a chat at a message. Today it
/// uses report navigation's `revealMessage` (scrolls when the message is on
/// the loaded page, else reads the page around it); it moves to the
/// transcript's own "reveal message" when that lands.
@MainActor enum SidebarSearchReveal {
    /// Test seam: called instead of revealing.
    static var override: ((String, String) async -> Void)?
    static func reveal(_ model: WorkspaceModel, chatID: String, messageID: String) async {
        if let override { await override(chatID, messageID); return }
        await model.revealMessage(sessionID: chatID, messageID: messageID)
    }
}

extension WorkspaceModel {
    /// The filter's search inside chats, made on first use.
    var sidebarSearch: SidebarSearch {
        if let sidebarSearchStorage { return sidebarSearchStorage }
        let search = SidebarSearch(model: self)
        sidebarSearchStorage = search
        return search
    }
    var sidebarSearchIfStarted: SidebarSearch? { sidebarSearchStorage }
    /// The chats whose messages match what the filter holds.
    var sidebarContentMatches: Set<String> { sidebarSearchStorage?.matchedIDs ?? [] }
    /// The content match a sidebar row opens at, while the filter asks for one.
    func sidebarSearchHit(_ chatID: String) -> ChatSearchHit? {
        sidebarSearchIfStarted?.hit(for: chatID)
    }
    /// Whether a chat is listed by the filter: its title, or its messages.
    func sidebarMatches(_ chat: ChatRecord, query: String) -> Bool {
        chat.title.localizedCaseInsensitiveContains(query) || sidebarSearchHit(chat.id) != nil
    }
    /// After a chat the filter listed opened, its match is shown — unless
    /// the reader has opened something else meanwhile (`opening` is what
    /// `beginSidebarOpen` gave before the chat was opened).
    func revealSidebarSearchHit(_ chatID: String, hit: ChatSearchHit?, opening: Int) async {
        // Still the chats page, still this chat in front, still the match the
        // field shows: the reader has not gone to the report, another chat or
        // another search meanwhile.
        guard let hit, !Task.isCancelled, !isShutDown, sidebarSearch.openings == opening, page == .chats,
              (focusedSessionID ?? selectedID) == chatID, sidebarSearch.hit(for: chatID)?.messageID == hit.messageID else { return }
        // Cancelled by the next keystroke or open while it loads the page
        // around the match: the reveal stops at its next check.
        let reveal = Task { await SidebarSearchReveal.reveal(self, chatID: chatID, messageID: hit.messageID) }
        sidebarSearch.revealing = reveal
        await withTaskCancellationHandler { await reveal.value } onCancel: { reveal.cancel() }
    }
    /// Counts sidebar opens, so a slow one cannot reveal over a newer one.
    func beginSidebarOpen() -> Int {
        sidebarSearch.revealing?.cancel(); sidebarSearch.revealing = nil
        sidebarSearch.openings &+= 1; return sidebarSearch.openings
    }
    /// Return in the filter field: the first chat it lists, at its match.
    func openFirstSidebarResult() {
        guard let first = sidebarChatOrder.first else { return }
        Task { await openFromSidebar(first) }
    }
}

// MARK: - The snippet under a matching row

/// What a matching chat's snippet line shows.
struct SidebarSearchSnippetState: Equatable {
    var chatID: String
    var title: String
    var kind: ChatSearchKind
    var excerpt: String
    var highlight: NSRange
    /// Where the row's title starts, so the snippet lines up under it.
    var indent: CGFloat

    init(chat: ChatRecord, hit: ChatSearchHit, indent: CGFloat) {
        chatID = chat.id; title = chat.title; kind = hit.kind; excerpt = hit.excerpt; highlight = hit.highlight; self.indent = indent
    }
    var symbol: String {
        switch kind {
        case .user: "person"
        case .assistant: "sparkle"
        case .toolInput, .toolOutput: "wrench.and.screwdriver"
        }
    }
    var role: String {
        switch kind {
        case .user: "Your message"
        case .assistant: "Reply"
        case .toolInput: "Tool input"
        case .toolOutput: "Tool output"
        }
    }
    /// What VoiceOver reads: the chat, where the match is, and the match.
    var spoken: String { title + ", " + role + ": " + excerpt }
}

/// The line under a matching chat's row: the text around the match, the
/// match in accent. Pressing it opens the chat at that message. Like a row,
/// it starts at its depth's indent and washes under the pointer.
@MainActor final class SidebarSearchSnippetView: NSView, SidebarEntryView {
    private(set) var state: SidebarSearchSnippetState
    let press = SnippetPress()
    var open: (() -> Void)? { get { press.onPress } set { press.onPress = newValue } }

    init(state: SidebarSearchSnippetState) {
        self.state = state
        super.init(frame: .zero)
        setAccessibilityElement(false)
        addSubview(press)
        apply(state, force: true)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func apply(_ new: SidebarSearchSnippetState, force: Bool = false) {
        guard force || new != state else { return }
        state = new
        press.show(new)
        needsLayout = true
    }
    func entryHeight(width: CGFloat) -> CGFloat { Self.height(of: state, width: width) }

    /// A snippet's height without a view: one line or two. Most excerpts are
    /// far longer than two lines' worth, which a glance at their length
    /// tells without setting the text; only a short one is measured. Typing
    /// with hundreds of matches re-measures every snippet on each key.
    private static let captionLine = PiKit.Line("Ag", font: PiKit.Font.caption, color: .black).lineHeight
    static func height(of state: SidebarSearchSnippetState, width: CGFloat) -> CGFloat {
        let textWidth = max(0, width - state.indent - SnippetPress.leading - SnippetPress.trailing)
        let line = captionLine
        // No caption glyph is narrower than this: past twice the width's worth, it wraps.
        let narrowest: CGFloat = 2.5
        let lines: CGFloat
        if textWidth > 0, CGFloat((state.excerpt as NSString).length) * narrowest > textWidth * 2 { lines = 2 }
        else {
            let natural = PiKit.Line(state.excerpt, font: PiKit.Font.caption, color: .black).size(scale: 2).width
            lines = natural <= textWidth ? 1 : 2
        }
        return lines * line + SnippetPress.vertical * 2
    }
    override func layout() {
        super.layout()
        press.frame = CGRect(x: state.indent, y: 0, width: max(0, bounds.width - state.indent), height: bounds.height)
    }

    /// The snippet's press surface: its symbol and text, a quiet wash under the pointer.
    @MainActor final class SnippetPress: PiKit.ButtonBase {
        private let icon = PiKit.SymbolView(PiKit.Symbol("person", size: 9, weight: .medium), color: .piInkTertiary)
        private let text = ShellText("", font: PiKit.Font.caption, color: .piInkSecondary, maximumLines: 2)
        static let vertical: CGFloat = 3
        /// The row's padding and icon column: the text starts under the title.
        static let leading: CGFloat = PiKit.SelectableRow.padding.left + 24
        static let trailing: CGFloat = PiKit.SelectableRow.padding.right

        override init(frame: NSRect) {
            super.init(frame: frame)
            pressScales = false
            text.setAccessibilityElement(false)
            for view in [icon, text] as [NSView] { addSubview(view) }
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }

        /// What the text says to VoiceOver as well as on screen.
        private(set) var shownText = ""
        func show(_ state: SidebarSearchSnippetState) {
            icon.symbol = PiKit.Symbol(state.symbol, size: 9, weight: .medium)
            let source = state.excerpt as NSString
            let match = NSIntersectionRange(state.highlight, NSRange(location: 0, length: source.length))
            var runs: [ShellText.Run] = []
            if match.length > 0 {
                if match.location > 0 { runs.append(.init(text: source.substring(to: match.location), color: .piInkSecondary)) }
                runs.append(.init(text: source.substring(with: match), color: .piAccent, weight: .semibold))
                if NSMaxRange(match) < source.length { runs.append(.init(text: source.substring(from: NSMaxRange(match)), color: .piInkSecondary)) }
            } else { runs = [.init(text: state.excerpt, color: .piInkSecondary)] }
            text.runs = runs
            shownText = state.excerpt
            setAccessibilityLabel(state.spoken)
            setAccessibilityHelp("Opens the chat at this message")
            setAccessibilityIdentifier("sidebarSearchSnippet-" + state.chatID)
            needsLayout = true
        }
        private func textWidth(_ width: CGFloat) -> CGFloat { max(0, width - Self.leading - Self.trailing) }
        override func layout() {
            super.layout()
            // As tall as the list measured it (`SidebarSearchSnippetView.height`).
            text.frame = CGRect(x: Self.leading, y: Self.vertical, width: textWidth(bounds.width), height: max(0, bounds.height - Self.vertical * 2))
            let size = icon.intrinsicContentSize
            let line = PiKit.Line("Ag", font: PiKit.Font.caption, color: .black).lineHeight
            icon.frame = CGRect(x: Self.leading - 6 - size.width, y: Self.vertical + PiKit.round((line - size.height) / 2, piScale),
                                width: size.width, height: size.height)
        }
        override func cornerRadius(for size: CGSize) -> CGFloat { PiRadius.sm }
        override func styleFace() {
            fill.backgroundColor = piCGColor(hovering || isPressedDown ? .piFill : .clear)
            stroke.borderColor = CGColor.clear
        }
    }
}
