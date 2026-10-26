import Foundation

/// A full history read lends the opening only the missing rows. Its current
/// rows stay authoritative: tokens and accounting may have landed meanwhile.
struct TranscriptOpeningFill: Sendable {
    var batches: [[TranscriptMessage]]

    init(page: [TranscriptMessage], opening: [TranscriptMessage], newer: Bool, limits: HistoryWindowPolicy.PageLimits, firstIsStart: Bool = true) {
        let candidates = newer ? opening + page : page + opening
        let range = HistoryWindowPolicy.page(count: candidates.count, around: newer ? 0 : nil, limits: limits, firstIsStart: firstIsStart,
                                               startsTurn: { TranscriptPaging.startsTurn(candidates[$0]) })
        let window = Array(candidates[range])
        var fill = HistoryWindowPolicy.PageFill(forward: newer, limits: limits)
        for row in newer ? window : Array(window.reversed()) {
            if !fill.admit(TranscriptPaging.size(row), startsTurn: TranscriptPaging.startsTurn(row)) { break }
        }
        let kept = newer ? Array(window.prefix(fill.kept)) : Array(window.suffix(fill.kept))
        let known = Set(opening.map(\.id))
        let extra = kept.filter { !known.contains($0.id) }
        var batches: [[TranscriptMessage]] = []
        let batchLimits = HistoryWindowPolicy.PageLimits(rows: 128, bytes: limits.bytes, turnRows: limits.turnRows, turnBytes: limits.turnBytes)
        if newer {
            var after = -1
            while after + 1 < extra.count {
                let range = HistoryWindowPolicy.page(count: extra.count, after: after, limits: batchLimits,
                                                       startsTurn: { TranscriptPaging.startsTurn(extra[$0]) })
                guard !range.isEmpty else { break }
                batches.append(Array(extra[range])); after = range.upperBound - 1
            }
        } else {
            var end = extra.count
            while end > 0 {
                let range = HistoryWindowPolicy.page(count: extra.count, before: end, limits: batchLimits,
                                                       startsTurn: { TranscriptPaging.startsTurn(extra[$0]) })
                guard !range.isEmpty else { break }
                batches.append(Array(extra[range])); end = range.lowerBound
            }
        }
        self.batches = batches
    }
}

extension WorkspaceModel {
    /// First rows have painted. Read ahead now, then admit whole turns on
    /// separate beats so the fill shares the main thread with input/tokens.
    func startOpeningFill(_ id: String) {
        guard let view = displays[id], view.presentation.openingPage, view.presentation.openingFill == nil, view.versionView == nil else { return }
        let newer = view.presentation.openingAround != nil
        guard view.presentation.partialTurnInput == nil, let item = record(id), let boundary = newer ? view.newerPage.cursor : view.olderPage.cursor else { view.presentation.openingPage = false; return }
        let generation = view.presentation.readGeneration, navigation = transcriptNavigation(id)
        let opening = view.messages, limits = TranscriptPaging.pageLimits
        view.presentation.openingFill = Task { [weak self, weak view] in
            guard let self, let view else { return }
            @MainActor func current() -> Bool {
                !Task.isCancelled && navigation.isCurrent(in: self) && self.displays[id] === view && view.versionView == nil
                    && view.presentation.readGeneration == generation && self.transcriptShows(id)
                    && self.record(id)?.path == item.path && self.record(id)?.workspaceID == item.workspaceID
                    && view.newerPage.error != Self.branchChangedElsewhere
            }
            defer { if !Task.isCancelled, view.presentation.readGeneration == generation { view.presentation.openingFill = nil } }
            await Task.yield()
            do {
                var page = try await self.readConversationWindow(item, cursor: boundary, newer: newer)
                guard current(), page.lineage == boundary.lineage else { return }
                page.messages = await self.withAccounting(page.messages, view: view, workspaceID: item.workspaceID, adding: true)
                guard current() else { return }
                let source = page.messages
                let firstIsStart = newer || page.start == 0 || page.messages.first.map(TranscriptPaging.startsTurn) == true
                let prepared = await Task.detached(priority: .utility) {
                    TranscriptOpeningFill(page: source, opening: opening, newer: newer, limits: limits, firstIsStart: firstIsStart)
                }.value
                var edge = boundary
                for batch in prepared.batches {
                    var retries = 0
                    while true {
                        guard current(), (newer ? view.newerPage.cursor : view.olderPage.cursor) == edge,
                              view.presentation.identity?.lineage == boundary.lineage,
                              batch.allSatisfy({ view.messagePositions[$0.id] == nil }) else { return }
                        var added = batch
                        for index in added.indices { added[index].accounting = view.messageAccounting[added[index].id] }
                        let addedBytes = added.reduce(0) { $0 + TranscriptPaging.size($1) }
                        guard view.messages.count + added.count <= TranscriptPaging.residentCaps.rows,
                              view.messageBytes + addedBytes <= TranscriptPaging.residentCaps.bytes else { return }
                        let before = view.presentedMessages, log = view.messageProjection.changes
                        let context = TranscriptMessageProjection.Context(view), accounting = view.accountingRevision
                        let originalLifecycle = view.taskPresentation
                        var lifecycle = originalLifecycle
                        if var value = lifecycle, value.timeline == page.lineage {
                            let records = Dictionary((value.recent + page.taskRecords).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
                            value.recent = Array(records.values.sorted { $0.startedAt < $1.startedAt }.suffix(64)); lifecycle = value
                        }
                        let atSourceEnd = newer ? batch.last?.id == page.messages.last?.id : batch.first?.id == page.messages.first?.id
                        let more = !atSourceEnd || (newer ? page.newer : page.older) != nil
                        let complete = newer ? (!more || !atSourceEnd || page.endsTurn) : view.newerPage.lastTurnFinished
                        let raw = newer ? view.messages + added : added + view.messages
                        let addedIDs = Set(added.map(\.id)), sending = Set(view.sendingRows.map(\.id))
                        let overlay = before.dropFirst(view.messageProjection.sourceRows).filter { !sending.contains($0.id) || !addedIDs.contains($0.id) }
                        let agent = view.agentPresentation
                        let display = TranscriptDisplay.mode, plannedLifecycle = lifecycle
                        var projection = await Task.detached(priority: .utility) {
                            TranscriptOpeningProjection(raw: raw, overlay: overlay, agent: agent, lifecycle: plannedLifecycle,
                                                        display: display, complete: complete)
                        }.value
                        self.openSteps?(id, "opening fill projected")
                        guard current(), (newer ? view.newerPage.cursor : view.olderPage.cursor) == edge else { return }
                        let now = view.presentedMessages
                        guard context == TranscriptMessageProjection.Context(view), accounting == view.accountingRevision,
                              originalLifecycle == view.taskPresentation, display == TranscriptDisplay.mode,
                              let changed = view.messageProjection.changes.indices(since: log), projection.update(now, at: changed) else {
                            // A busy live tail can outpace a full plan. Yield, then
                            // leave ordinary paging to finish if this batch stays stale.
                            guard retries < 3 else { return }
                            try await Task.sleep(for: .milliseconds(16 << retries))
                            retries += 1
                            continue
                        }
                        guard view.messages.count + added.count <= TranscriptPaging.residentCaps.rows,
                              view.messageBytes + addedBytes <= TranscriptPaging.residentCaps.bytes else { return }
                        // The prepared plan is current. Everything through publication is one
                        // actor turn; a token cannot slip between these two installations.
                        let joined = newer ? view.messages + added : added + view.messages
                        let started = PerformanceProbe.now
                        view.beginTranscriptBatch()
                        view.presentation.identity = (page.incarnation, page.lineage)
                        view.historyPositions.record(page)
                        view.taskPresentation = lifecycle
                        var cursor = page.older ?? page.newer ?? boundary
                        cursor.incarnation = page.incarnation; cursor.lineage = page.lineage
                        cursor.entry = newer ? joined.last!.id : joined.first!.id
                        edge = cursor
                        if newer { view.newerPage = .init(cursor: more ? cursor : nil, endsTurn: !atSourceEnd || page.endsTurn) }
                        else { view.olderPage = .init(cursor: more ? cursor : nil); view.before = view.olderPage.cursor?.entry }
                        let wasBrowsing = view.browsingHistory
                        view.browsingHistory = view.newerPage.available
                        let revision = view.projectionRevision
                        view.messagePositions = Dictionary(joined.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
                        view.messageBytes += addedBytes
                        view.replacingMessages = true; view.messages = joined; view.replacingMessages = false
                        view.messageProjection.install(projection.messages, context: .init(view), sources: view.messagePositions)
                        TranscriptOpeningPlans.install(projection, for: view)
                        view.projectionRevision = revision
                        view.adoptedPage = view.pageRows
                        view.endTranscriptBatch()
                        if wasBrowsing && !view.browsingHistory {
                            view.projectedRows = []; view.projectionRevision = nil
                            self.refresh(id)
                        }
                        PerformanceProbe.shared.observe("openingFillStepMs", milliseconds: PerformanceProbe.now - started)
                        self.openSteps?(id, "opening fill step")
                        break
                    }
                    try await Task.sleep(for: .milliseconds(16))
                }
                guard current() else { return }
                view.presentation.openingPage = false
                self.scheduleAccounting(id, workspaceID: item.workspaceID)
                self.openSteps?(id, "opening fill ready")
            } catch { /* A speculative fill leaves the readable page and its retry boundary intact. */ }
        }
    }
}


/// Pure work for one admission; the main actor installs it after validating
/// the sources/agent state that were captured with it.
struct TranscriptOpeningProjection: Sendable {
    var messages: [TranscriptMessage]
    var sourceRows: Int
    var positions: [String: Int]
    var items: [TranscriptItem]
    var lifecycle: TaskPresentationProjection?
    var display: TranscriptDisplayMode
    var complete: Bool

    init(raw: [TranscriptMessage], overlay: [TranscriptMessage], agent: AgentTranscriptPresentation,
         lifecycle: TaskPresentationProjection?, display: TranscriptDisplayMode, complete: Bool) {
        let sources = SessionDisplay.hidingBranchMarkers(raw)
        let first = agent.isManagedSubagent ? sources.first(where: { $0.role == "user" })?.id : nil
        let shown = sources.map { agent.present($0, firstTask: first) }
        messages = shown + overlay; sourceRows = shown.count
        positions = Dictionary(messages.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        items = TranscriptActivity.preparedBlocks(of: messages, lifecycle: lifecycle, display: display, complete: complete)
        self.lifecycle = lifecycle; self.display = display; self.complete = complete
    }

    /// Tokens can arrive while the full plan is prepared. Bring only those
    /// rows forward with the same local planner the streaming path uses.
    mutating func update(_ rows: [TranscriptMessage], at indices: [Int]) -> Bool {
        guard !indices.isEmpty else { return true }
        var next = messages, changed: [Int] = []
        for index in indices {
            guard rows.indices.contains(index), let place = positions[rows[index].id] else { return false }
            next[place] = rows[index]; changed.append(place)
        }
        let previous = TranscriptChanges()
        var edits = previous; edits.record(changed)
        let input = TranscriptPresentationInput(messages: next, lifecycle: lifecycle, changes: edits)
        guard let updated = Self.updating(items, from: messages, to: input, previous: previous, complete: complete) else { return false }
        messages = next; items = updated; return true
    }

    static func updating(_ items: [TranscriptItem], from messages: [TranscriptMessage], to input: TranscriptPresentationInput,
                         previous: TranscriptChanges, complete: Bool) -> [TranscriptItem]? {
        guard let changes = input.changes,
              changes.indices(since: previous) != nil || changes.tailStart(since: previous) != nil else { return nil }
        let changed = changes.indices(since: previous)
        if changed?.isEmpty == true { return messages.count == input.messages.count ? items : nil }
        var index = TranscriptActivity.PatchIndex(items)
        if let patch = index.patch(items, from: messages, to: input.messages, changed: changed) { return patch.items }
        let snapshot = TranscriptPage.Snapshot(sessionID: "history", messages: messages, items: items, fresh: [], sequence: 0,
                                               lifecycle: input.lifecycle, messageChanges: previous, complete: complete)
        return TranscriptTailPlan(messages, items: items).replacing(snapshot, with: input, complete: complete)?.items
    }
}

/// A one-presentation handoff, not a second history cache. Coalesced tokens
/// patch the prepared plan; other semantic changes use ordinary planning.
@MainActor enum TranscriptOpeningPlans {
    private struct Pending {
        var generation: UUID
        var changes: TranscriptChanges
        var projection: TranscriptOpeningProjection
    }
    private static var pending: [ObjectIdentifier: Pending] = [:]
    private(set) static var used = 0

    static func install(_ projection: TranscriptOpeningProjection, for session: SessionDisplay) {
        let key = ObjectIdentifier(session), changes = session.messageProjection.changes
        pending[key] = Pending(generation: session.presentationGeneration, changes: changes, projection: projection)
        Task {
            try? await Task.sleep(for: .seconds(1))
            if pending[key]?.changes.stamp == changes.stamp { pending[key] = nil }
        }
    }
    static func take(for session: SessionDisplay, input: TranscriptPresentationInput, complete: Bool) -> [TranscriptItem]? {
        guard let held = pending.removeValue(forKey: ObjectIdentifier(session)), held.generation == session.presentationGeneration,
              held.projection.lifecycle == input.lifecycle, held.projection.display == TranscriptDisplay.mode,
              held.projection.complete == complete else { return nil }
        guard let items = TranscriptOpeningProjection.updating(held.projection.items, from: held.projection.messages,
                                                               to: input, previous: held.changes, complete: complete) else { return nil }
        used += 1; return items
    }
}
