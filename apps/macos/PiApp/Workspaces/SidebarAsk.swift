import AppKit

struct SidebarAskConnection: Equatable {
    var id: String
    var title: String
    var available: Bool
    var unresolved = false
}

/// An explicit question about one connection's chats. Rankings publish first;
/// the top few get local excerpts independently of library-wide indexing.
@MainActor final class SidebarAsk {
    struct Status: Equatable {
        var text = "Ask in plain words, then press Return."
        var busy = false
    }
    static let miniNotice = "Ask needs a mini model. Choose one for this connection in Settings."
    private weak var model: WorkspaceModel?
    private var task: Task<Void, Never>?
    private var tail: Task<Void, Never>?
    private var enrichment: Task<Void, Never>?
    private let library: ChatSearchQuery
    private var generation = 0
    private var chosen: String?
    private var chosenMini: String?
    private var submitted = false
    private(set) var status = Status()
    private(set) var matches: [SidebarAskMatch] = []
    private(set) var hits: [String: ChatSearchHit] = [:]
    private(set) var checkingIDs: Set<String> = []
    private(set) var candidateCount = 0
    private(set) var consideredCount = 0
    var changed: (() -> Void)?
    /// Test seams around the two independently cancellable stages.
    var beforeDispatch: (() async -> Void)?
    var beforeSelection: (() async -> Void)?
    var beforeConfirmation: ((String) async -> Void)?
    var willBuildPlan: (@Sendable () -> Void)?
    /// Tests retain a check through cancellation and await its last callback.
    var confirmationWork: Task<Void, Never>? { enrichment }
    var busy: Bool { task != nil || enrichment != nil }

    init(model: WorkspaceModel) {
        self.model = model
        library = ChatSearchQuery(url: model.root.appendingPathComponent(ChatSearchDatabase.fileName))
    }

    private func eligible(_ chat: ChatRecord, model: WorkspaceModel) -> Bool {
        !chat.isUtilityChat && !chat.isSubagent && model.side(chat.id)?.kept != false
            && !model.pendingChatIDs.contains(chat.id)
    }
    var connections: [SidebarAskConnection] {
        guard let model else { return [] }
        let projects = Set(model.sidebarProjects.map(\.id))
        let ids = Set(model.chats.filter { projects.contains($0.workspaceID) && eligible($0, model: model) }.map(\.profileID))
        return model.profiles.filter { ids.contains($0.id) }.map {
            let entry = model.catalogEntry(for: $0)
            let unresolved = entry.fetchedAt == nil || entry.error != nil && entry.descriptors.isEmpty
            return SidebarAskConnection(id: $0.id, title: $0.name, available: mini($0, model: model) != nil || unresolved, unresolved: unresolved)
        }
    }
    private func mini(_ profile: ProfileRecord, model: WorkspaceModel) -> String? {
        TitleGenerationPlan.miniModel(profile: profile, descriptors: model.catalogEntry(for: profile).descriptors)
    }
    /// Reading list contents never changes a choice or cancels work.
    var connectionID: String? { chosen }
    private func resolveDefault() {
        guard let model else { return }
        let choices = connections
        let selected = (model.focusedSessionID ?? model.selectedID).flatMap { model.record($0)?.profileID }
        chosen = choices.first { $0.id == selected && $0.available }?.id
            ?? choices.first { $0.available }?.id ?? choices.first?.id
        chosenMini = chosen.flatMap { id in model.profiles.first { $0.id == id }.flatMap { mini($0, model: model) } }
    }
    var listedMatches: [SidebarAskMatch] {
        guard let model, let connection = connectionID else { return [] }
        return matches.filter { match in
            model.record(match.id).map { $0.profileID == connection && (model.sidebarShowsArchived || !$0.isArchived) } == true
        }
    }

    /// Settings/catalog changes never ask. A removed connection gets the
    /// default; a choice that loses its mini model stays chosen, with a notice.
    func connectionsChanged() {
        guard let model else { return }
        guard let id = chosen, connections.contains(where: { $0.id == id }),
              let profile = model.profiles.first(where: { $0.id == id }) else {
            reset(); resolveDefault(); changed?(); return
        }
        let next = mini(profile, model: model)
        if chosenMini != next, chosenMini != nil {
            let wasSubmitted = submitted
            reset()
            submitted = wasSubmitted
            if next == nil { status.text = Self.miniNotice }
            else if wasSubmitted { status.text = "The mini model changed. Press Return to ask again." }
        }
        chosenMini = next
        matches = matches.filter { match in model.record(match.id).map { $0.profileID == id && eligible($0, model: model) } == true }
        let remaining = Set(matches.map(\.id))
        hits = hits.filter { remaining.contains($0.key) }; checkingIDs.formIntersection(remaining)
        if !matches.isEmpty { showSummary(profile.name) }
        changed?()
    }

    func chooseConnection(_ id: String, question: String) {
        guard connections.contains(where: { $0.id == id && $0.available }), connectionID != id else { return }
        let askAgain = submitted
        reset(); chosen = id
        if let model, let profile = model.profiles.first(where: { $0.id == id }) { chosenMini = mini(profile, model: model) }
        if askAgain { start(question) } else { changed?() }
    }

    func reset() {
        generation &+= 1; task?.cancel(); task = nil
        enrichment?.cancel(); enrichment = nil; library.cancel()
        matches = []; hits = [:]; checkingIDs = []; candidateCount = 0; consideredCount = 0
        submitted = false; status = Status()
    }
    func shutdown() {
        reset()
        let library = library
        Task { await library.close() }
    }
    func cancel() { reset(); status.text = "Ask cancelled. Press Return to ask again."; changed?() }
    /// Tests may wait for all local checks, or for rankings alone.
    func settle() async { await task?.value; await enrichment?.value }
    func settleRanking() async { await task?.value }

    /// Return or a deliberate connection change. A later Ask replaces local
    /// enrichment; two provider requests are never in flight together.
    func start(_ question: String) {
        guard task == nil, let model, !model.installPreparing, !model.isShutDown else { return }
        if chosen == nil { connectionsChanged() }
        let previous = tail
        reset()
        guard !question.isEmpty else { changed?(); return }
        submitted = true
        guard question.utf8.count <= SidebarAskPlan.questionLimit else {
            status.text = "This question is too long. Try a shorter question."; changed?(); return
        }
        guard let connection = connectionID else { status.text = Self.miniNotice; changed?(); return }
        status = Status(text: "Finding relevant chats…", busy: true)
        let mine = generation
        let request = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.generation == mine else { return }
            var requestID: String?
            await self.run(question, connection: connection, generation: mine) { requestID = $0 }
            // askMiniModel stops and closes a cancelled session in its cleanup
            // task. Let that finish before the next chosen connection asks.
            if let requestID {
                await Task { @MainActor [weak model] in
                    while model?.displays[requestID] != nil { try? await Task.sleep(for: .milliseconds(10)) }
                }.value
            }
            guard self.generation == mine else { return }
            self.task = nil; self.status.busy = self.enrichment != nil; self.changed?()
        }
        task = request; tail = request
        changed?()
    }

    private func candidates(_ model: WorkspaceModel, connection: String) -> [SidebarAskCandidate] {
        let projects = Dictionary(model.sidebarProjects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let topics = Dictionary(model.topics.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        return model.chats.compactMap { chat in
            // Scope before reading any title, brief or keywords.
            guard chat.profileID == connection, eligible(chat, model: model), projects[chat.workspaceID] != nil,
                  model.sidebarShowsArchived || !chat.isArchived else { return nil }
            let brief = model.sidebarBrief(chat)
            return SidebarAskCandidate(id: chat.id, connection: chat.profileID,
                title: SidebarAskPlan.compact(chat.displayTitle, bytes: 120), brief: SidebarAskPlan.compact(brief?.text ?? "", bytes: 400),
                keywords: (brief?.keywords ?? []).prefix(6).map { SidebarAskPlan.compact($0, bytes: 40) },
                project: SidebarAskPlan.compact(projects[chat.workspaceID] ?? "", bytes: 80),
                topic: SidebarAskPlan.compact(chat.topicID.flatMap { topics[$0] } ?? "", bytes: 80), activity: chat.activityStamp)
        }
    }

    private func run(_ question: String, connection: String, generation mine: Int, onRecord: @escaping @MainActor (String) -> Void) async {
        guard current(mine, connection: connection), let model, let profile = model.profiles.first(where: { $0.id == connection }) else { return }
        let all = candidates(model, connection: connection)
        let chatGenerations = model.connectionGenerations, deletionGenerations = model.profileDeletionGenerations
        await beforeSelection?()
        guard current(mine, connection: connection) else { return }
        consideredCount = all.count
        guard !all.isEmpty else { status.text = "No chats to ask about in \(profile.name)."; return }
        let selection = Task.detached(priority: .userInitiated) { SidebarAskPlan.select(all, question: question) }
        let selected = await withTaskCancellationHandler { await selection.value } onCancel: { selection.cancel() }
        guard current(mine, connection: connection) else { return }
        do {
            let leases = try selected.map { candidate -> WorkspaceModel.ConnectionLease in
                guard model.record(candidate.id) != nil, candidate.connection == connection else { throw model.connectionChanged }
                let lease = WorkspaceModel.ConnectionLease(profileID: connection, deletionGeneration: deletionGenerations[connection, default: 0],
                    chatID: candidate.id, chatGeneration: chatGenerations[candidate.id, default: 0])
                try model.requireConnection(lease)
                return lease
            }
            _ = await model.listModels(for: profile)
            guard current(mine, connection: connection) else { return }
            let descriptors = model.catalogEntry(for: profile).descriptors
            guard mini(profile, model: model) != nil else {
                if let error = model.catalogEntry(for: profile).error { throw HostError.failure(error) }
                status.text = Self.miniNotice; return
            }
            let willBuildPlan = willBuildPlan
            let preparing = Task.detached(priority: .userInitiated) {
                willBuildPlan?()
                return SidebarAskPlan(profile: profile, descriptors: descriptors, question: question, candidates: selected)
            }
            let prepared = await withTaskCancellationHandler { await preparing.value } onCancel: { preparing.cancel() }
            guard current(mine, connection: connection) else { return }
            guard let plan = prepared else {
                throw HostError.failure("The mini model's context is too small for Ask.")
            }
            let sentIDs = Set(plan.candidates.map(\.id)), sentLeases = leases.filter { sentIDs.contains($0.chatID) }
            let validate: @MainActor @Sendable () throws -> Void = {
                try Task.checkCancellation()
                guard !model.installPreparing, !model.isShutDown else { throw CancellationError() }
                guard let current = model.profiles.first(where: { $0.id == connection }),
                      TitleGenerationPlan.miniModel(profile: current, descriptors: model.catalogEntry(for: current).descriptors) == plan.request.model else {
                    throw HostError.failure(Self.miniNotice)
                }
                for lease in sentLeases {
                    guard model.record(lease.chatID) != nil else { throw model.connectionChanged }
                    try model.requireConnection(lease)
                }
            }
            await beforeDispatch?()
            try validate()
            candidateCount = plan.candidates.count
            status.text = "Asking \(profile.name)…"; changed?()
            let messages = try await model.askMiniModel(plan.request, profile: profile, sourceID: plan.candidates[0].id,
                onRecord: onRecord, validateSource: validate) { messages in
                    let ranked = try SidebarAskPlan.parse(messages, candidates: plan.candidates)
                    return ranked.isEmpty ? "No relevant chats." : ranked.map { $0.id + ": " + $0.reason }.joined(separator: "\n")
                }
            try validate()
            guard current(mine, connection: connection) else { return }
            matches = try SidebarAskPlan.parse(messages, candidates: plan.candidates).filter { model.record($0.id)?.profileID == connection }
            checkingIDs = Set(matches.prefix(SidebarAskPlan.confirmationLimit).map(\.id))
            showSummary(profile.name)
            changed?() // The rows exist before any index read, including a cold one.
            if !checkingIDs.isEmpty {
                let top = Array(matches.prefix(SidebarAskPlan.confirmationLimit))
                enrichment = Task { [weak self] in
                    await self?.enrich(top, question: question, connection: connection, leases: sentLeases, generation: mine)
                    guard let self, self.generation == mine else { return }
                    self.enrichment = nil; self.status.busy = self.task != nil; self.changed?()
                }
            }
        } catch {
            guard current(mine, connection: connection) else { return }
            status.text = "Ask could not finish. Press Return to try again.\n" + profile.name + ": " + SidebarAskPlan.compact(error.localizedDescription, bytes: 300)
        }
    }

    private func current(_ mine: Int, connection: String) -> Bool {
        !Task.isCancelled && generation == mine && chosen == connection && model?.isShutDown == false && model?.installPreparing == false
    }
    private func showSummary(_ connection: String) {
        status.text = matches.isEmpty ? "No relevant chats found in \(connection). Try another question."
            : "\(matches.count) relevant \(matches.count == 1 ? "chat" : "chats") in \(connection) · \(candidateCount) checked"
        if candidateCount < consideredCount { status.text += " of \(consideredCount) chats" }
    }

    private func enrich(_ top: [SidebarAskMatch], question: String, connection: String, leases: [WorkspaceModel.ConnectionLease], generation mine: Int) async {
        guard let model, current(mine, connection: connection) else { return }
        do {
            for match in top {
                guard current(mine, connection: connection) else { throw CancellationError() }
                await beforeConfirmation?(match.id)
                guard current(mine, connection: connection) else { throw CancellationError() }
                guard let chat = model.record(match.id), chat.profileID == connection, let path = chat.path,
                      let lease = leases.first(where: { $0.chatID == match.id }) else {
                    checkingIDs.remove(match.id); changed?(); continue
                }
                do {
                    try model.requireConnection(lease)
                    let source = ChatSearchSource(id: chat.id, path: path, rebuildsOnChange: chat.imported)
                    var hit: ChatSearchHit?
                    if try await library.indexed(source, acceptsOlder: true) {
                        for term in [question] + SidebarAskPlan.terms(question) {
                            guard current(mine, connection: connection) else { throw CancellationError() }
                            hit = try await library.search(term, in: [match.id])[match.id]
                            if hit != nil { break }
                        }
                    } else {
                        // No disk index, offset cache or library-wide pass: read
                        // only a bounded tail, held in memory for this check.
                        let check = Task.detached(priority: .utility) { try SidebarAskText.check(source, question: question) }
                        hit = try await withTaskCancellationHandler { try await check.value } onCancel: { check.cancel() }
                    }
                    try model.requireConnection(lease)
                    guard current(mine, connection: connection) else { throw CancellationError() }
                    if model.record(match.id)?.path == path, model.record(match.id)?.profileID == connection { hits[match.id] = hit }
                } catch {
                    guard current(mine, connection: connection) else { throw CancellationError() }
                }
                checkingIDs.remove(match.id); changed?()
            }
        } catch { /* A newer question, mode or connection owns the result area. */ }
    }
}

/// A cold excerpt reads at most 256 KiB and 512 complete records. It owns
/// no files or caches: cancellation, quit and process death leave no text copy.
/// An existing library entry is preferred, even if its revision is older.
enum SidebarAskText {
    static let byteLimit = 262_144
    static let recordLimit = 512
    static func check(_ source: ChatSearchSource, question: String) throws -> ChatSearchHit? {
        try Task.checkCancellation()
        guard let revision = HistoryReader.currentRevision(path: source.path), let file = FileHandle(forReadingAtPath: source.path) else { return nil }
        defer { try? file.close() }
        let size = try file.seekToEnd(), start = size > UInt64(byteLimit) ? size - UInt64(byteLimit) : 0
        try file.seek(toOffset: start)
        let data = try file.read(upToCount: byteLimit) ?? Data()
        var lines = data.split(separator: 10, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        if data.last != 10, !lines.isEmpty { lines.removeLast() }
        var records: [String: [String: WireValue]] = [:], last: String?
        for line in lines.suffix(recordLimit) {
            try Task.checkCancellation()
            guard let row = try? JSONDecoder().decode(WireValue.self, from: Data(line)).object,
                  let id = row["id"]?.string else { continue }
            // These operations need older context to establish what is still
            // displayed. A cold bounded check never guesses at that history.
            if ["pi-app.native.context.v1", "pi-app.presentation.update.v1"].contains(row["customType"]?.string ?? "") { return nil }
            records[id] = row; last = id
        }
        let terms = [question] + SidebarAskPlan.terms(question)
        var visited: Set<String> = []
        while let id = last, visited.insert(id).inserted, let row = records[id] {
            try Task.checkCancellation()
            if ["branch", "compaction"].contains(row["type"]?.string ?? "") { break }
            if row["type"]?.string == "message", let value = row["message"]?.object {
                let message = TranscriptMessage.project(id: id, message: value)
                let pieces = ChatSearchIndex.pieces(of: message)
                for term in terms where ChatSearchDatabase.answers(ChatSearchHit.collapsed(term)) {
                    for piece in pieces {
                        if let excerpt = ChatSearchHit.excerpt(of: term, in: piece.text) {
                            guard HistoryReader.currentRevision(path: source.path) == revision else { return nil }
                            return ChatSearchHit(chatID: source.id, messageID: id, kind: piece.kind,
                                excerpt: excerpt.excerpt, highlight: excerpt.highlight, context: excerpt.context)
                        }
                    }
                }
            }
            last = row["parentId"]?.string
        }
        return nil
    }
}

/// The result area's progress, cancellation and errors, using PiKit only.
@MainActor final class SidebarAskStatusView: NSView, SidebarEntryView {
    private let text = ShellText("", font: PiKit.Font.caption, color: .piInkSecondary)
    let cancel = PiKit.IconButton(symbol: "xmark", label: "Cancel Ask", size: 20)
    private var status = SidebarAsk.Status()
    init(status: SidebarAsk.Status, cancel: @escaping () -> Void) {
        super.init(frame: .zero)
        addSubview(text); addSubview(self.cancel)
        self.cancel.onPress = cancel
        self.cancel.setAccessibilityIdentifier("sidebarAskCancel")
        setAccessibilityIdentifier("sidebarAskStatus")
        update(status)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func update(_ status: SidebarAsk.Status) {
        self.status = status; text.runs = [.init(text: status.text, color: .piInkSecondary)]
        cancel.isHidden = !status.busy; needsLayout = true
    }
    func entryHeight(width: CGFloat) -> CGFloat {
        max(20, text.height(forWidth: max(0, width - 44))) + 16
    }
    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 44), height = text.height(forWidth: width)
        text.frame = CGRect(x: 8, y: 8, width: width, height: height)
        cancel.frame = CGRect(x: bounds.width - 28, y: 8, width: 20, height: 20)
    }
}

extension SidebarAsk {
    static func contents(model: WorkspaceModel, width: CGFloat) -> SidebarListContents {
        let ask = model.sidebarSearch.askChats
        var contents = SidebarListContents(entries: [.askStatus(ask.status)], gaps: [0], owners: [("", nil)])
        let projects = Dictionary(model.sidebarProjects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for match in ask.listedMatches {
            guard let chat = model.record(match.id), let project = projects[chat.workspaceID] else { continue }
            let topic = chat.topicID.flatMap { id in model.topics.first { $0.id == id && $0.workspaceID == chat.workspaceID } }
            // Ranked matches are independent rows, including saved sides.
            // Group filtering deliberately hides sides for an empty query.
            let state = SidebarChatRowState(
                selected: model.focusedSessionID == chat.id || model.selectedID == chat.id && model.focusedSessionID == nil,
                marked: model.isSessionMarked(chat.id), anyMarked: model.hasMarkedSessions,
                familyActivity: model.sideFamilyOwner(chat) == nil ? model.conversationFamily(chat.id).activity : .init(),
                unreadCount: model.unreadOutputCount(sessionID: chat.id), unreadFailure: model.unreadFailure(sessionID: chat.id),
                markedUnreadOnly: model.markedUnreadOnly(sessionID: chat.id),
                heldRun: chat.isArchived || chat.isUtilityChat ? nil : model.runHolds[chat.id]?.presented,
                recency: model.recencyRank(chat.id), hasDraft: model.showsDraftMark(chat.id),
                brief: model.sidebarBrief(chat), offersBrief: model.offersBrief(chat),
                projectTag: project.name, projectTagFullName: project.name, topicTag: topic?.title,
                liveIdentity: model.displays[chat.id].map(ObjectIdentifier.init),
                subtitle: model.sidebarRowSubtitle(chat, namesConnection: model.sidebarConnectionCount > 1),
                available: ChatRowMetrics.availableWidth(sidebar: width, indent: 0, depth: 0))
            func add(_ entry: SidebarEntry, gap: CGFloat) {
                contents.entries.append(entry); contents.gaps.append(gap); contents.owners.append((chat.workspaceID, nil))
            }
            add(.chat(chat: chat, state: state, projectID: chat.workspaceID), gap: 6)
            add(.searchSnippet(SidebarSearchSnippetState(chat: chat, reason: match.reason, indent: 0)), gap: 0)
            if let hit = ask.hits[chat.id] {
                add(.searchSnippet(SidebarSearchSnippetState(chat: chat, hit: hit, indent: 0, confirmed: true)), gap: 0)
            } else if ask.matches.prefix(SidebarAskPlan.confirmationLimit).contains(where: { $0.id == chat.id }) {
                add(.searchSnippet(SidebarSearchSnippetState(chat: chat, checking: ask.checkingIDs.contains(chat.id), indent: 0)), gap: 0)
            }
        }
        return contents
    }
}
