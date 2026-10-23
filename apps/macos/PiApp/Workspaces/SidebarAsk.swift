import AppKit

/// One explicit question, partitioned by connection. No transcript text is
/// sent: the full-text index supplies excerpts locally after ranking.
@MainActor final class SidebarAsk {
    struct Status: Equatable {
        var text = "Ask in plain words, then press Return."
        var busy = false
    }
    private weak var model: WorkspaceModel?
    private var task: Task<Void, Never>?
    private var generation = 0
    private(set) var status = Status()
    private(set) var matches: [SidebarAskMatch] = []
    private(set) var hits: [String: ChatSearchHit] = [:]
    private(set) var candidateCount = 0
    private(set) var consideredCount = 0
    var changed: (() -> Void)?
    /// Test seam: after catalog loading, before the final dispatch checks.
    var beforeDispatch: (() async -> Void)?
    var beforeSelection: (() async -> Void)?
    var busy: Bool { task != nil }
    var listedMatches: [SidebarAskMatch] {
        guard let model else { return [] }
        return matches.filter { match in
            model.record(match.id).map { model.sidebarShowsArchived || !$0.isArchived } == true
        }
    }

    init(model: WorkspaceModel) { self.model = model }

    func reset() {
        generation &+= 1; task?.cancel(); task = nil
        matches = []; hits = [:]; candidateCount = 0; consideredCount = 0
        status = Status()
    }
    func cancel() {
        reset(); status.text = "Ask cancelled. Press Return to ask again."; changed?()
    }
    func settle() async { await task?.value }

    /// Return asks; field edits only reset. One partition runs at a time.
    func start(_ question: String) {
        guard !busy, let model, !model.installPreparing, !model.isShutDown else { return }
        reset()
        guard !question.isEmpty else { changed?(); return }
        guard question.utf8.count <= SidebarAskPlan.questionLimit else {
            status.text = "This question is too long. Try a shorter question."; changed?(); return
        }
        status = Status(text: "Finding relevant chats…", busy: true)
        let mine = generation
        task = Task { [weak self] in
            guard let self else { return }
            await self.run(question, generation: mine)
            guard self.generation == mine else { return }
            self.task = nil; self.status.busy = false; self.changed?()
        }
        changed?()
    }

    private func candidates(_ model: WorkspaceModel) -> [SidebarAskCandidate] {
        let projects = Dictionary(model.sidebarProjects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let topics = Dictionary(model.topics.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        return model.chats.compactMap { chat in
            guard !chat.isUtilityChat, !chat.isSubagent, projects[chat.workspaceID] != nil,
                  model.sidebarShowsArchived || !chat.isArchived, model.side(chat.id)?.kept != false,
                  !model.pendingChatIDs.contains(chat.id) else { return nil }
            let brief = model.sidebarBrief(chat)
            return SidebarAskCandidate(id: chat.id, connection: chat.profileID,
                title: SidebarAskPlan.compact(chat.displayTitle, bytes: 120), brief: SidebarAskPlan.compact(brief?.text ?? "", bytes: 400),
                keywords: (brief?.keywords ?? []).prefix(6).map { SidebarAskPlan.compact($0, bytes: 40) },
                project: SidebarAskPlan.compact(projects[chat.workspaceID] ?? "", bytes: 80),
                topic: SidebarAskPlan.compact(chat.topicID.flatMap { topics[$0] } ?? "", bytes: 80), activity: chat.activityStamp)
        }
    }

    private func run(_ question: String, generation mine: Int) async {
        guard let model else { return }
        let all = candidates(model)
        let chatGenerations = model.connectionGenerations, deletionGenerations = model.profileDeletionGenerations
        await beforeSelection?()
        consideredCount = all.count
        let selection = Task.detached(priority: .userInitiated) { SidebarAskPlan.select(all, question: question) }
        let selected = await withTaskCancellationHandler { await selection.value } onCancel: { selection.cancel() }
        guard !Task.isCancelled, generation == mine else { return }
        let groups = Dictionary(grouping: selected, by: \.connection)
        var lists: [[SidebarAskMatch]] = [], problems: [String] = [], skipped = 0
        // Deterministic order: a connection's first local candidate's place.
        var connections: [String] = []
        for candidate in selected where !connections.contains(candidate.connection) { connections.append(candidate.connection) }
        for (offset, id) in connections.enumerated() {
            guard !Task.isCancelled, generation == mine, !model.installPreparing, !model.isShutDown else { return }
            guard let profile = model.profiles.first(where: { $0.id == id }), let group = groups[id] else { skipped += 1; continue }
            do {
                let leases = try group.map { candidate -> WorkspaceModel.ConnectionLease in
                    guard model.record(candidate.id) != nil else { throw model.connectionChanged }
                    let lease = WorkspaceModel.ConnectionLease(profileID: candidate.connection,
                        deletionGeneration: deletionGenerations[candidate.connection, default: 0], chatID: candidate.id,
                        chatGeneration: chatGenerations[candidate.id, default: 0])
                    try model.requireConnection(lease)
                    return lease
                }
                _ = await model.listModels(for: profile)
                try Task.checkCancellation()
                guard !model.installPreparing, !model.isShutDown else { return }
                let descriptors = model.catalogEntry(for: profile).descriptors
                guard TitleGenerationPlan.miniModel(profile: profile, descriptors: descriptors) != nil else { skipped += 1; continue }
                guard let plan = SidebarAskPlan(profile: profile, descriptors: descriptors, question: question, candidates: group) else {
                    throw HostError.failure("The mini model's context is too small for Ask.")
                }
                let sentIDs = Set(plan.candidates.map(\.id)), sentLeases = leases.filter { sentIDs.contains($0.chatID) }
                let validate: @MainActor @Sendable () throws -> Void = {
                    try Task.checkCancellation()
                    guard !model.installPreparing, !model.isShutDown else { throw CancellationError() }
                    for lease in sentLeases {
                        guard model.record(lease.chatID) != nil else { throw model.connectionChanged }
                        try model.requireConnection(lease)
                    }
                }
                await beforeDispatch?()
                try validate()
                candidateCount += plan.candidates.count
                status.text = "Asking \(profile.name)… \(offset + 1) of \(connections.count) connections"; changed?()
                let messages = try await model.askMiniModel(plan.request, profile: profile, sourceID: plan.candidates[0].id,
                                                           validateSource: validate) { messages in
                    let ranked = try SidebarAskPlan.parse(messages, candidates: plan.candidates)
                    return ranked.isEmpty ? "No relevant chats." : ranked.map { $0.id + ": " + $0.reason }.joined(separator: "\n")
                }
                try validate()
                lists.append(try SidebarAskPlan.parse(messages, candidates: plan.candidates))
            } catch {
                guard !Task.isCancelled, generation == mine else { return }
                problems.append(profile.name + ": " + SidebarAskPlan.compact(error.localizedDescription, bytes: 300))
            }
        }
        guard !Task.isCancelled, generation == mine, !model.installPreparing, !model.isShutDown else { return }
        let ranked = SidebarAskPlan.merge(lists).filter { model.record($0.id) != nil }
        status.text = "Checking chat text…"; changed?()
        var confirmed: [String: ChatSearchHit] = [:]
        if !ranked.isEmpty {
            // Reuse the maintained index; a cold index finishes before this read.
            await model.sidebarSearch.reconcileNow()
            let ids = Set(ranked.prefix(SidebarAskPlan.confirmationLimit).map(\.id))
            do {
                for term in [question] + SidebarAskPlan.terms(question) {
                    try Task.checkCancellation()
                    let found = try await model.sidebarSearch.reader.search(term, in: ids)
                    for (id, hit) in found where confirmed[id] == nil { confirmed[id] = hit }
                    if confirmed.count == ids.count { break }
                }
            } catch {
                guard !Task.isCancelled, generation == mine else { return }
                problems.append("Chat text could not be checked: " + SidebarAskPlan.compact(error.localizedDescription, bytes: 200))
            }
        }
        guard !Task.isCancelled, generation == mine else { return }
        matches = ranked.filter { model.record($0.id) != nil }
        hits = confirmed.filter { hit in matches.contains { $0.id == hit.key } }
        var summary = all.isEmpty ? "No chats to ask about." : candidateCount == 0 && problems.isEmpty
            ? "Ask needs a mini model. Choose one for a connection in Settings."
            : lists.isEmpty && !problems.isEmpty ? "Ask could not finish. Press Return to try again."
            : matches.isEmpty ? "No relevant chats found. Try another question." : "\(matches.count) relevant \(matches.count == 1 ? "chat" : "chats") · \(candidateCount) \(candidateCount == 1 ? "candidate" : "candidates") checked"
        if candidateCount < consideredCount, candidateCount > 0 { summary += " of \(consideredCount) chats" }
        if skipped > 0 { summary += "\nSkipped \(skipped) \(skipped == 1 ? "connection" : "connections") without a mini model." }
        if !problems.isEmpty { summary += "\n" + problems.joined(separator: "\n") }
        status.text = summary
    }
}

/// The result area's progress, cancellation and errors, using PiKit only.
@MainActor final class SidebarAskStatusView: NSView, SidebarEntryView {
    private let text = ShellText("", font: PiKit.Font.caption, color: .piInkSecondary)
    let cancel = PiKit.Button("Cancel", symbol: "xmark", compact: true)
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
        text.height(forWidth: max(0, width - 16)) + 16 + (status.busy ? cancel.intrinsicContentSize.height + 6 : 0)
    }
    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 16), height = text.height(forWidth: width)
        text.frame = CGRect(x: 8, y: 8, width: width, height: height)
        cancel.frame = CGRect(origin: CGPoint(x: 8, y: height + 14), size: cancel.intrinsicContentSize)
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
                add(.searchSnippet(SidebarSearchSnippetState(chat: chat, hit: hit, indent: 0)), gap: 0)
            }
        }
        return contents
    }
}
