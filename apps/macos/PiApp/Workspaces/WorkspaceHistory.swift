import Foundation

extension WorkspaceModel {
    func readConversationWindow(_ item: ChatRecord, cursor: ConversationCursor?, newer: Bool = false,
                                around: String? = nil) async throws -> ConversationHistoryPage {
        if let historyWindowLoader { return try await historyWindowLoader(item.id, cursor, newer, around) }
        try Task.checkCancellation()
        if opened.contains(item.id), let host = hosts[item.workspaceID] {
            var params: [String: WireValue] = ["version": .number(2), "direction": .string(newer ? "newer" : "older")]
            // Source handoff uses a stable entry id. Numeric file positions are
            // never passed to a helper. The replacement source validates it.
            if let cursor {
                if cursor.incarnation.hasPrefix("file:") {
                    params["entry"] = .string(cursor.entry); params["lineage"] = .string(cursor.lineage)
                } else { params["cursor"] = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(cursor)) }
            }
            if let around { params["around"] = .string(around) }
            let result = try await host.request("session.history", sessionID: item.id, params: params)
            try Task.checkCancellation()
            return try ConversationHistoryPage(result)
        }
        guard side(item.id)?.pending == true || !isEphemeral(item.id) else { throw HostError.failure("This side's owning helper is unavailable. Its retained history was not changed.") }
        if let path = item.path {
            if let cursor, !cursor.incarnation.hasPrefix("file:") {
                let page = try await history.read(path: path, before: newer ? nil : cursor.entry, around: around,
                                                  after: newer ? cursor.entry : nil, targetTurns: HistoryWindowPolicy.turns)
                guard page.lineage == cursor.lineage else { throw HostError.failure("History branch changed during source handoff. Reload history.") }
                return try ConversationHistoryPage(page)
            }
            let display = displays[item.id], generation = display?.presentationGeneration
            return try ConversationHistoryPage(await history.window(path: path, cursor: cursor, newer: newer, around: around, progress: { [weak display] records, bytes, total in
                Task { @MainActor [weak display] in
                    guard let display, display.presentationGeneration == generation, display.historyState == .loading else { return }
                    display.historyProgress = "Reading history · \(records.formatted()) records · \(Int(Double(bytes) / Double(max(1, total)) * 100))%"
                }
            }))
        }
        // A newly created in-memory chat is authoritatively empty.
        return try ConversationHistoryPage(.object(["version": .number(2), "messages": .array([]),
            "incarnation": .string("new:" + item.id), "lineage": .string("root"), "older": .null, "newer": .null]))
    }

    func adoptInitialHistory(_ page: ConversationHistoryPage, into view: SessionDisplay, around: String? = nil) {
        view.beginTranscriptBatch(); defer { view.endTranscriptBatch() }
        if view.taskPresentation?.active == nil {
            view.taskPresentation = .init(sessionID:view.id, epoch:page.incarnation, timeline:page.lineage, sequence:0, sourceRevision:page.revision?.stamp ?? "history", active:nil, recent:page.taskRecords)
        }
        view.presentation.identity = (page.incarnation, page.lineage)
        view.historyProgress = nil
        view.presentation.partialTurnInput = page.partialTurnInput
        view.olderPage = .init(cursor: page.older); view.newerPage = .init(cursor: page.newer)
        view.before = page.older?.entry; view.hostBefore = nil; view.historyRevision = page.revision
        if let around { view.scrollAnchor = .init(id: around, offset: 0, followsBottom: false) }
        else if let anchor = view.scrollAnchor, !anchor.followsBottom, !page.messages.contains(where: { $0.id == anchor.id }) { view.scrollAnchor = nil }
        view.browsingHistory = page.newer != nil
        view.projectedRows = []; view.projectionRevision = nil
        view.historyState = page.messages.isEmpty ? .empty : .preparing
        view.messages = page.messages
        view.viewportRequest += 1
        if let count = page.assistantCount {
            observeAssistantOutputs(sessionID: view.id, snapshot: ["assistantMessageCount": .number(Double(count)),
                "latestAssistantMessageId": page.latestAssistantID.map(WireValue.string) ?? .null])
        }
        view.observeRetainedFailure(page.failure); view.observeRetainedRun(page)
        if let notice = page.notice { view.notice = notice }
        view.presentation.sourceReadyAt = PerformanceProbe.now
        PerformanceProbe.shared.observe("selectionSourceReadyMs", milliseconds: PerformanceProbe.now - view.presentation.startedAt)
        if page.messages.isEmpty { historyViewportReady(view.id, generation: view.presentationGeneration) }
    }

    /// Called only after the destination's native visible band and placement
    /// have settled. Optional context/accounting cannot hold first presentation.
    func historyViewportReady(_ id: String, generation: UUID) {
        guard let view = displays[id], view.presentationGeneration == generation,
              view.historyState == .preparing || view.historyState == .empty,
              id == selectedID || sides[selectedID ?? ""]?.id == id else { return }
        if view.historyState != .empty { view.historyState = .ready }
        view.refreshingCachedRows = false
        view.presentation.readyAt = PerformanceProbe.now
        view.contextSelectionReady = true
        PerformanceProbe.shared.observe("selectionUsefulViewportMs", milliseconds: PerformanceProbe.now - view.presentation.startedAt)
        view.presentation.secondary?.cancel()
        view.presentation.secondary = Task { [weak self, weak view] in
            // Use the existing input-quiet scheduler rather than blocking
            // presentation on accounting or starting a helper for display.
            await Task.yield()
            while !Task.isCancelled, TranscriptIdleScheduler.shared.remainingInputQuietTime > 0 {
                try? await Task.sleep(for: .seconds(TranscriptIdleScheduler.shared.remainingInputQuietTime))
            }
            guard !Task.isCancelled, let self, let view, view.presentationGeneration == generation,
                  let item = self.record(id), id == self.selectedID || self.sides[self.selectedID ?? ""]?.id == id else { return }
            view.contextSelectionReady = true
            self.scheduleAutomaticContext(id)
            await self.refreshAccounting(view, workspaceID: item.workspaceID)
        }
    }

    func reloadHistory(_ id: String, around: String? = nil) {
        guard let view = displays[id], let item = record(id) else { return }
        view.presentation.begin(); view.presentationGeneration = view.presentation.generation
        let generation = view.presentationGeneration
        // The reads of the page being replaced end with it: neither boundary
        // is left loading, or failed, behind the cover.
        view.olderPage = .init(); view.newerPage = .init()
        view.historyState = .loading; view.refreshingCachedRows = false; view.historyProgress = nil; view.browsingHistory = true; view.publishTranscript()
        view.presentation.navigation = Task { [weak self, weak view] in
            guard let self, let view else { return }
            do {
                let page = try await self.readConversationWindow(item, cursor: nil, around: around)
                guard !Task.isCancelled, self.displays[id] === view, view.presentationGeneration == generation else { return }
                self.adoptInitialHistory(page, into: view, around: around)
                if self.opened.contains(id) { self.refresh(id) }
            } catch is CancellationError { }
            catch { if !Task.isCancelled, view.presentationGeneration == generation { view.historyState = .failed(error.localizedDescription); view.refreshingCachedRows = false } }
        }
    }
    func loadEarlier(sessionID: String? = nil) { Task { _ = await loadEarlierPage(sessionID: sessionID) } }
    func loadNewer(sessionID: String) { Task { _ = await loadHistoryPage(sessionID, newer: true) } }
    /// A live page that does not join the rows a chat shows leaves a gap. A
    /// reply longer than the page starts it after the message it answers,
    /// and a chat that sent that message a moment ago may not have its row
    /// yet. A reader at the live end has the gap read in at once, which
    /// returns the chat to the live tail. Before, the gap waited behind the
    /// "newer" edge until they pressed it, and the reply being written never
    /// appeared. A page not yet presented, or a read already under way, is
    /// waited out for up to two seconds first.
    func fillLiveGap(_ id: String) {
        Task { [weak self] in
            var reads = 0, waits = 0
            while reads < 4 {
                guard let self, let view = self.displays[id], view.browsingHistory, view.newerPage.cursor != nil,
                      view.newerPage.error == nil, view.scrollAnchor?.followsBottom != false else { return }
                if view.historyState.loading || view.newerPage.loading {
                    waits += 1
                    guard waits <= 40 else { return }
                    try? await Task.sleep(for: .milliseconds(50)); continue
                }
                guard await self.loadHistoryPage(id, newer: true) else { return }
                reads += 1
            }
        }
    }
    func loadEarlierPage(sessionID: String? = nil, startingTurnOnly: Bool = false) async -> Bool {
        guard let id = sessionID ?? selectedID else { return false }
        return await loadHistoryPage(id, newer: false)
    }
    // Compatibility for old callers; the source now chooses turn boundaries.
    func ensurePageStartsAtTurn(sessionID: String, refreshAfterRepair: Bool = true) async { }

    @discardableResult func loadHistoryPage(_ id: String, newer: Bool) async -> Bool {
        guard let view = displays[id], let item = record(id), !view.historyState.loading else { return false }
        let boundary = newer ? view.newerPage : view.olderPage
        guard let cursor = boundary.cursor, !boundary.loading else { return false }
        let generation = view.presentationGeneration, read = UUID()
        if newer { view.newerPage.loading = true; view.newerPage.error = nil; view.presentation.newerRead = read }
        else { view.olderPage.loading = true; view.olderPage.error = nil; view.loadingEarlier = true; view.presentation.olderRead = read }
        let task = Task { [weak self, weak view] () -> Bool in
            guard let self, let view else { return false }
            @MainActor func current() -> Bool { !Task.isCancelled && self.displays[id] === view && view.presentationGeneration == generation }
            defer {
                // Only the read the flag belongs to ends it. A read whose page
                // was replaced under it (and read again since) must not end
                // the read under way now: its spinner would go, and a second
                // read of the same page would start.
                if view.presentationGeneration == generation {
                    if newer, view.presentation.newerRead == read {
                        view.newerPage.loading = false; view.presentation.newerTask = nil; view.presentation.newerRead = nil
                    } else if !newer, view.presentation.olderRead == read {
                        view.olderPage.loading = false; view.loadingEarlier = false; view.presentation.olderTask = nil; view.presentation.olderRead = nil
                    }
                }
            }
            do {
                let page = try await self.readConversationWindow(item, cursor: cursor, newer: newer)
                guard current() else { return false }
                // The window's edge row was let go of while this page was on
                // its way, so the page no longer joins it. Nothing is wrong
                // with the boundary it has now; the next request reads that.
                // (Reporting it stopped earlier rows from loading on their own.)
                guard (newer ? view.newerPage.cursor : view.olderPage.cursor) == cursor else { return false }
                let handoff = page.incarnation.hasPrefix("file:") != cursor.incarnation.hasPrefix("file:")
                guard (page.incarnation == cursor.incarnation || handoff), page.lineage == cursor.lineage else {
                    throw HostError.failure("History source changed. Use Latest to reload, or reopen the retained message.")
                }
                let known = Set(view.messages.map(\.id)), added = page.messages.filter { !known.contains($0.id) }
                guard added.count == page.messages.count else {
                    throw HostError.failure("History returned an overlapping page. Retry this boundary or use Latest.")
                }
                let next = newer ? page.newer : page.older
                if added.isEmpty {
                    guard page.messages.isEmpty && next == nil else { throw HostError.failure("No new history was returned. Retry loading this boundary.") }
                    if newer {
                        view.newerPage = .init()
                        view.browsingHistory = false
                        view.projectedRows = []; view.projectionRevision = nil
                        self.refresh(id)
                    } else { view.olderPage = .init() }
                    return true
                }
                var joined = newer ? view.messages + added : added + view.messages
                // Keep the requested side, evict only the far opposite edge.
                let bounded = TranscriptPaging.window(joined, keepingEarlier: !newer)
                let evicted = bounded.count != joined.count
                var pinned = view.pinnedHistoryIDs
                if let anchor = view.scrollAnchor, !anchor.followsBottom, known.contains(anchor.id) { pinned.insert(anchor.id) }
                guard pinned.isSubset(of: Set(bounded.map(\.id))) else {
                    throw HostError.failure("The selected text is at the display boundary. Clear the selection to load more history.")
                }
                joined = bounded
                guard added.contains(where: { row in joined.contains { $0.id == row.id } }) else {
                    throw HostError.failure("The selected content fills the display budget. Open the full message or move the reading position before loading more.")
                }
                // Commit source ownership only after the complete candidate
                // passes coverage and residency checks. A failed handoff must
                // leave both the page and its retry cursor unchanged.
                if handoff {
                    view.presentation.identity = (page.incarnation, page.lineage)
                    let sourceCursor = page.older ?? page.newer
                    if var old = view.olderPage.cursor { old.incarnation = page.incarnation; old.committedBytes = sourceCursor?.committedBytes; old.fingerprint = sourceCursor?.fingerprint; view.olderPage.cursor = old }
                    if var old = view.newerPage.cursor { old.incarnation = page.incarnation; old.committedBytes = sourceCursor?.committedBytes; old.fingerprint = sourceCursor?.fingerprint; view.newerPage.cursor = old }
                }
                for index in joined.indices { joined[index].accounting = view.messageAccounting[joined[index].id] }
                if newer {
                    view.newerPage = .init(cursor: page.newer)
                    if evicted, let first = joined.first { var edge = page.older ?? page.newer ?? cursor; edge.entry = first.id; view.olderPage = .init(cursor: edge) }
                } else {
                    view.olderPage = .init(cursor: page.older)
                    view.presentation.partialTurnInput = page.partialTurnInput
                    if evicted, let last = joined.last { var edge = page.newer ?? page.older ?? cursor; edge.entry = last.id; view.newerPage = .init(cursor: edge) }
                }
                view.before = view.olderPage.cursor?.entry
                // Reading earlier rows (including automatic viewport fills)
                // does not disconnect the live tail. Pause projection merges
                // only while a newer gap actually remains in this window.
                let wasBrowsing = view.browsingHistory
                view.beginTranscriptBatch(); defer { view.endTranscriptBatch() }
                if var lifecycle = view.taskPresentation, lifecycle.timeline == page.lineage {
                    let combined = Dictionary((lifecycle.recent + page.taskRecords).map { ($0.key,$0) },uniquingKeysWith:{ first,_ in first })
                    lifecycle.recent = Array(combined.values.sorted { $0.startedAt < $1.startedAt }.suffix(64))
                    view.taskPresentation = lifecycle
                }
                view.browsingHistory = view.newerPage.available
                // TranscriptPage owns the actual visible anchor, and captures
                // it on adoption; a first-array-row surrogate would jump.
                view.messages = joined
                self.scheduleAccounting(id, workspaceID: item.workspaceID)
                if wasBrowsing && !view.browsingHistory {
                    view.projectedRows = []; view.projectionRevision = nil
                    self.refresh(id)
                }
                return true
            } catch is CancellationError { return false }
            catch {
                guard current() else { return false }
                if newer { view.newerPage.error = error.localizedDescription }
                else { view.olderPage.error = error.localizedDescription }
                return false
            }
        }
        if newer { view.presentation.newerTask = task } else { view.presentation.olderTask = task }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    func latest(sessionID: String? = nil) {
        if let id = sessionID ?? selectedID, let view = displays[id] {
            view.scrollAnchor = .init(id: "", offset: 0, followsBottom: true)
            anchorChanged(view); reloadHistory(id)
        }
    }

    /// A successful submission follows its new turn even from a retained
    /// earlier window or while an old source read is still being hydrated.
    /// A message drawn on Return follows it before the helper has it, and has
    /// nothing to fetch yet (`refreshing: false`).
    func followSubmittedTurn(_ id: String, refreshing: Bool = true) {
        guard let view = displays[id] else { return }
        if view.browsingHistory || view.historyState.loading || view.newerPage.available || view.newerPage.loading {
            latest(sessionID: id)
        } else {
            // An earlier page still on its way is not where the reader is
            // going, and joining it could push the newest rows out of the
            // window they are about to follow. It is let go of, rather than
            // the whole conversation being read again behind the cover.
            if view.olderPage.loading { view.presentation.olderTask?.cancel() }
            view.scrollAnchor = .init(id: view.messages.last?.id ?? "", offset: 0, followsBottom: true)
            view.viewportRequest += 1; anchorChanged(view)
            if refreshing { refresh(id) }
        }
    }

    /// The reader's own edit has moved the chat onto a new branch
    /// (`sendEdit`), and this snapshot is the first to carry it. The page
    /// takes the new branch as its source where the reader is: the rows the
    /// edit abandoned leave, the earlier boundary is read from the new
    /// branch, no newer gap is left behind, and the page goes to the new
    /// turn. The reader made this change, so nothing reports it to them;
    /// a change of branch nobody here asked for is still reported.
    func adoptOwnBranch(_ view: SessionDisplay, rows: [TranscriptMessage], snapshot result: [String: WireValue]) {
        guard let pending = view.pendingBranch, let incarnation = result["historyIncarnation"]?.string,
              let lineage = result["historyLineage"]?.string else { return }
        let held = view.presentation.identity?.lineage
        if let from = pending.from {
            // Taken before the edit landed: it is still on its way.
            guard lineage != from else { return }
            // Already on the new branch: a reload read it first.
            if held == lineage { view.pendingBranch = nil; return }
            // The page went to some other branch meanwhile; not this edit's.
            guard held == nil || held == from else { return }
        } else {
            // The page held no branch when the edit went. Only a snapshot
            // that shows the new branch beginning, without the question it
            // replaced, is the edit landing.
            guard held != lineage, rows.contains(where: { $0.id == lineage && $0.kind == "branch" }),
                  !rows.contains(where: { $0.id == pending.messageID }) else { return }
        }
        view.pendingBranch = nil
        view.presentation.identity = (incarnation, lineage)
        // Reads under way on the branch the reader left would only fail on
        // this one. The earlier boundary is re-pointed as the rows land.
        view.presentation.olderTask?.cancel(); view.presentation.newerTask?.cancel()
        view.olderPage = .init(cursor: view.olderPage.cursor); view.newerPage = .init()
        view.pinnedHistoryIDs = []
        // A window that reaches no row held replaces the rows: nothing
        // vouches for what would lie between, and the rows before it are
        // read again from its earlier boundary as the reader goes up.
        let arriving = Set(rows.map(\.id))
        if !view.messages.contains(where: { arriving.contains($0.id) }) {
            view.messages = []; view.presentation.partialTurnInput = nil
        } else if view.presentation.partialTurnInput == pending.messageID { view.presentation.partialTurnInput = nil }
        // The reader goes with their edit, to the new turn at the end.
        view.scrollAnchor = .init(id: "", offset: 0, followsBottom: true)
        view.viewportRequest += 1; anchorChanged(view)
    }
    /// A change of branch nobody here asked for: another copy of the app, or
    /// a journal changed under the chat. The page stops following the live
    /// rows and says so once, with the way back.
    static let branchChangedElsewhere = "This conversation was changed outside this window. Reload to show it as it is now."
}
