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
        view.observeRetainedFailure(page.failure)
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
        view.historyState = .loading; view.historyProgress = nil; view.browsingHistory = true; view.publishTranscript()
        view.presentation.navigation = Task { [weak self, weak view] in
            guard let self, let view else { return }
            do {
                let page = try await self.readConversationWindow(item, cursor: nil, around: around)
                guard !Task.isCancelled, self.displays[id] === view, view.presentationGeneration == generation else { return }
                self.adoptInitialHistory(page, into: view, around: around)
                if self.opened.contains(id) { self.refresh(id) }
            } catch is CancellationError { }
            catch { if !Task.isCancelled, view.presentationGeneration == generation { view.historyState = .failed(error.localizedDescription) } }
        }
    }
    func loadEarlier(sessionID: String? = nil) { Task { _ = await loadEarlierPage(sessionID: sessionID) } }
    func loadNewer(sessionID: String) { Task { _ = await loadHistoryPage(sessionID, newer: true) } }
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
        let generation = view.presentationGeneration
        if newer { view.newerPage.loading = true; view.newerPage.error = nil }
        else { view.olderPage.loading = true; view.olderPage.error = nil; view.loadingEarlier = true }
        let task = Task { [weak self, weak view] () -> Bool in
            guard let self, let view else { return false }
            @MainActor func current() -> Bool { !Task.isCancelled && self.displays[id] === view && view.presentationGeneration == generation }
            defer {
                if view.presentationGeneration == generation {
                    if newer { view.newerPage.loading = false; view.presentation.newerTask = nil }
                    else { view.olderPage.loading = false; view.loadingEarlier = false; view.presentation.olderTask = nil }
                }
            }
            do {
                let page = try await self.readConversationWindow(item, cursor: cursor, newer: newer)
                guard current() else { return false }
                guard (newer ? view.newerPage.cursor : view.olderPage.cursor) == cursor else {
                    throw HostError.failure("The reading window moved while loading. Retry its current boundary.")
                }
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
                    if newer { view.newerPage = .init() } else { view.olderPage = .init() }
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
                view.browsingHistory = true
                // TranscriptPage owns the actual visible anchor, and captures
                // it on adoption; a first-array-row surrogate would jump.
                view.messages = joined
                self.scheduleAccounting(id, workspaceID: item.workspaceID)
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
}
