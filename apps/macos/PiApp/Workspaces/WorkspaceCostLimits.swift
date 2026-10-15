import AppKit

/// What the cost-limit notice in a transcript asks for.
enum CostLimitNoticeAction: Sendable { case raise, continueRun }

// Each chat's cost limit: the Settings default, a chat's own choice, and the
// helper session that enforces it. The helper checks the chat's reported
// spend against the limit before every model request; the app decides which
// limit that is and tells the helper whenever it changes.
extension WorkspaceModel {
    /// The limit every chat without its own runs under.
    var defaultCostLimit: CostLimit { configuration.defaultChatCostLimit }
    /// Only actual sides inherit budgets; forks also have parentSessionID.
    func sideBudgetParent(_ item: ChatRecord) -> String? {
        guard !item.isSubagent else { return nil }
        if let path = item.path {
            return URL(fileURLWithPath: path).lastPathComponent == "side_" + item.id + ".jsonl" ? item.parentSessionID : nil
        }
        // Only an unpublished side draft lacks a journal. A mounted saved
        // fork is pane placement, never an accounting relationship.
        return side(item.id).flatMap { !$0.kept ? $0.parentID : nil }
    }
    func budgetOwner(for item: ChatRecord) -> ChatRecord {
        var current = item, seen: Set<String> = [item.id]
        while let id = current.delegation?.budgetOwnerSessionID ?? sideBudgetParent(current),
              seen.insert(id).inserted, let parent = record(id), parent.workspaceID == item.workspaceID { current = parent }
        return current
    }
    func costLimit(for item: ChatRecord) -> CostLimit { budgetOwner(for: item).costLimit ?? defaultCostLimit }
    func costLimit(for id: String) -> CostLimit { record(id).map(costLimit(for:)) ?? defaultCostLimit }

    func restoreSideBudgets() async throws {
        var workspaces: [String: [String: [String]]] = [:]
        for item in chats where !item.isSubagent && (item.parentSessionID != nil || sideBudgetParent(item) != nil) {
            var current = item, parents: [String] = [], seen: Set<String> = [item.id]
            while let id = sideBudgetParent(current), seen.insert(id).inserted,
                  let parent = record(id), parent.workspaceID == item.workspaceID {
                parents.append(id); current = parent
            }
            // An empty mapping retires a stale fork/orphan projection while
            // retaining physical captures and unrelated discarded-side usage.
            workspaces[item.workspaceID, default: [:]][item.id] = parents
        }
        for (workspace, sides) in workspaces { try await traces.recordSideBudgets(sides, workspaceID: workspace) }
    }

    /// The chat's reading with its current limit and what its helper last
    /// said of its spend.
    func costReading(for id: String) -> SessionCostReading {
        var reading = displays[id]?.footer.cost ?? SessionCostReading()
        if reading.budgetOwnerID != nil { reading.costAttribution = nil }
        reading.budgetOwnerID = nil; reading.budgetSpentUSD = nil
        reading.override = record(id).map { budgetOwner(for: $0).costLimit } ?? nil; reading.defaultLimit = defaultCostLimit; reading.limit = costLimit(for: id)
        if let item = record(id) {
            let owner = budgetOwner(for: item)
            if owner.id != id {
                reading.budgetOwnerID = owner.id
                reading.budgetSpentUSD = displays[owner.id]?.footer.cost.spentUSD ?? chatStats[owner.id]?.costUSD
                reading.costAttribution = "Counts toward " + owner.title
            }
        }
        return reading
    }
    /// Puts a chat's limit on its display: the footer's figure and the stop notice.
    func refreshCostReading(_ id: String) {
        displays[id]?.applyCostReading(costReading(for: id))
    }

    /// Sets a chat's own limit, or with nil lets it follow the default. The
    /// choice is saved with the chat and reaches its helper session at once:
    /// the next model request is checked against it, in a run that is going too.
    func setCostLimit(_ limit: CostLimit?, for id: String) async throws {
        guard let item = record(id), budgetOwner(for: item).id == id else { throw HostError.failure("This chat uses its parent’s cost limit. Change the limit in the parent.") }
        if let limit, !limit.isValid { throw HostError.failure("Enter an amount in US dollars above $0.00, up to $1,000,000.00.") }
        // An editor can choose again before the previous write finishes.
        // Compare with the saved value only after that choice settles, so
        // choosing A → B → A does not mistake the last A for a no-op.
        let previous = costLimitWrites[id]?.task, token = UUID()
        let task = Task { [weak self] in
            _ = await previous?.result
            guard let self else { return }
            try await self.persistCostLimit(limit, for: id)
        }
        costLimitWrites[id] = (token, task)
        defer { if costLimitWrites[id]?.token == token { costLimitWrites[id] = nil } }
        try await task.value
        // Only persistence is serialized: a slow helper acknowledgement
        // must not hold up the next choice's save or publication.
        await sendCostLimit(id)
    }
    private func persistCostLimit(_ limit: CostLimit?, for id: String) async throws {
        if let index = chats.firstIndex(where: { $0.id == id }) {
            if chats[index].costLimit != limit {
                // A chat not yet sent has no record; its first message writes it, limit included.
                if pendingChatIDs.contains(id) { chats[index].costLimit = limit }
                else {
                    guard let store else { throw StoreError.unavailable }
                    let saved = try await store.updateChatCostLimit(id: id, limit: limit)
                    // Re-find after the await: chats can be reordered, renamed
                    // or removed while the write is in flight.
                    if let current = chats.firstIndex(where: { $0.id == id }),
                       (chats[current].costLimitRevision ?? 0) < (saved.costLimitRevision ?? 0) {
                        chats[current].costLimit = saved.costLimit
                        chats[current].costLimitRevision = saved.costLimitRevision
                    }
                }
            }
        } else { throw HostError.failure("This chat is no longer available.") }
        refreshCostReading(id); displays[id]?.costLimitChanged()
    }
    /// Saves the Settings default. Every chat that follows it is told.
    func setDefaultCostLimit(_ limit: CostLimit) async throws {
        guard limit.isValid else { throw HostError.failure("Enter an amount in US dollars above $0.00, up to $1,000,000.00.") }
        try await updateConfiguration { $0.chatCostLimit = limit }
    }
    /// The default changed (Settings saved, the vault read again): every
    /// open chat that follows it shows and enforces the new one.
    func defaultCostLimitChanged() {
        for (id, view) in displays {
            refreshCostReading(id)
            if record(id).map({ $0.costLimit == nil }) ?? false { view.costLimitChanged() }
        }
        for id in opened where record(id).map({ $0.costLimit == nil }) ?? false { Task { await sendCostLimit(id) } }
    }
    /// Tells a chat's loaded helper session the limit it runs under. A chat
    /// with no session loaded is told when one opens (`costLimitParams`).
    func sendCostLimit(_ id: String) async {
        guard opened.contains(id), let item = record(id), budgetOwner(for: item).id == id, let host = hosts[item.workspaceID], host.isReady else { return }
        let limit = costLimit(for: item)
        displays[id]?.costLimitSent = limit
        // A failed send is not retried from here: the next change sends again,
        // and a snapshot showing the old limit asks only for a limit not yet tried.
        do { _ = try await host.request("session.configure", sessionID: id, params: ["costLimit": limit.wire]) }
        catch { displays[id]?.notice = "The new cost limit did not reach this chat's helper: " + error.localizedDescription }
        refresh(id)
    }
    /// What a session open carries: the chat's limit, and for a chat whose
    /// journal predates cost records, what the request log holds of its spend
    /// so far. The helper takes that figure once and records costs itself from then on.
    func costLimitParams(for item: ChatRecord) async -> [String: WireValue] {
        let limit = costLimit(for: item)
        var params: [String: WireValue] = ["costLimit": limit.wire]
        if let seed = await costSeed(for: item) { params["costSeed"] = seed }
        displays[item.id]?.costLimitSent = limit
        return params
    }
    private func costSeed(for item: ChatRecord) async -> WireValue? {
        if let costSeedRead { return await costSeedRead(item) }
        // A chat whose journal the helper creates records every cost from its first request.
        guard item.path != nil else { return nil }
        // The helper adopts saved-side journals separately. A family footer
        // here would seed those same physical attempts a second time.
        let totals = try? await traces.sessionMetrics(sessionID: item.id, workspaceID: item.workspaceID, until: Date(), includeFamily: false).gateway
        guard let totals, totals.requests > 0 else { return nil }
        let reported = max(0, totals.costSamples)
        return .object(["usd": .number(reported > 0 ? max(0, totals.costUSD ?? 0) : 0), "reported": .number(Double(reported)),
                        "unreported": .number(Double(max(0, totals.requests - reported)))])
    }
    /// A snapshot's `cost`: what the helper counted, and the limit it runs
    /// under. A helper that runs under another limit than the chat's (a
    /// change it missed) is told the chat's once.
    func observeCost(_ snapshot: [String: WireValue], view: SessionDisplay) {
        guard let cost = snapshot["cost"]?.object else { return }
        var reading = costReading(for: view.id)
        reading.spentUSD = cost["spentUSD"]?.number
        reading.reportedRequests = cost["reportedRequests"]?.nonnegativeInteger ?? 0
        reading.unreportedRequests = cost["unreportedRequests"]?.nonnegativeInteger ?? 0
        view.applyCostReading(reading)
        for (id, _) in displays where id != view.id {
            if let item = record(id), budgetOwner(for: item).id == view.id { refreshCostReading(id) }
        }
        guard let item = record(view.id), budgetOwner(for: item).id == item.id else { return }
        let helper: CostLimit = cost["limitUSD"]?.number.map(CostLimit.usd) ?? .unlimited
        if helper != reading.limit, view.costLimitSent != reading.limit {
            view.costLimitSent = reading.limit
            let id = view.id
            Task { await sendCostLimit(id) }
        }
    }

    /// The notice's two actions: open the limit editor over the button, or
    /// carry on from where the run stopped once the limit is above the spend.
    func costLimitNotice(_ action: CostLimitNoticeAction, sessionID: String, anchor: NSView?) {
        guard record(sessionID)?.isSubagent != true else { return }
        switch action {
        case .raise:
            guard let anchor, let item = record(sessionID) else { return }
            let owner = budgetOwner(for: item)
            if owner.id != sessionID { openInspector(session: owner.id, focus: .overview); return }
            guard let view = displays[owner.id] else { return }
            CostLimitPopover.shared.toggle(model: self, footer: view.footer, sessionID: owner.id, anchor: anchor)
        case .continueRun: continueAfterCostLimit(sessionID)
        }
    }
    /// Continues a chat stopped at its limit: the stopped turn is sent again
    /// from where it stopped, with the chat's current choices, and queued
    /// follow-ups go on after it; a run that stopped between turns resumes
    /// its queue instead.
    func continueAfterCostLimit(_ id: String) {
        guard !installPreparing, let item = record(id), !costReading(for: id).reached else { return }
        guard !item.isArchived else { displays[id]?.notice = Self.archivedNotice; return }
        Task {
            do {
                let lease = try connectionLease(for: item)
                let host = try await open(item)
                try requireConnection(lease)
                do { _ = try await host.request("turn.retry", sessionID: id, params: turnOverrides(for: item)) }
                catch HostError.rejected(let code, _) where code == "nothing_to_retry" {
                    _ = try await host.request("queue.resume", sessionID: id)
                }
                refresh(id)
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// The popover "Raise limit…" opens over its button: the chat's limit editor.
/// One app-owned popover at a time, like the stats pills' and the skills'.
@MainActor final class CostLimitPopover {
    static let shared = CostLimitPopover()
    let presenter = PiPopoverPresenter()
    /// The chat whose limit the open popover edits (a test seam).
    private(set) var sessionID: String?
    static let width: CGFloat = 380
    func toggle(model: WorkspaceModel, footer: SessionMetrics, sessionID: String, anchor: NSView) {
        if presenter.isShown, self.sessionID == sessionID { close(); return }
        presenter.close()
        self.sessionID = sessionID
        presenter.toggle(from: anchor, width: Self.width, maximumHeight: 460, animates: !PiKit.Motion.reduced) { [weak model] in
            let editor = CostLimitLiveEditor(footer: footer, title: "Raise this chat's limit") { limit in
                try await model?.setCostLimit(limit, for: sessionID)
                // Chosen: the popover has done its job.
                CostLimitPopover.shared.close()
            }
            return PaddedView(editor, padding: NSEdgeInsets(top: PiSpacing.lg, left: PiSpacing.lg, bottom: PiSpacing.lg, right: PiSpacing.lg))
        }
    }
    func close() { presenter.close(); sessionID = nil }
}
