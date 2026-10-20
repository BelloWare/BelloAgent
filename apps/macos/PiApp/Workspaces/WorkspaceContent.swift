import AppKit

/// Each sheet owns its selection; later searches cannot lend a stale copy a
/// different source or revision, including while an export chooser is open.
@MainActor final class ConversationCopyReader {
    let model: WorkspaceModel, sessionID: String
    private var searchID = UUID(), selection: (token: String, result: ContentSearch)?
    private var range: (first: Int, last: Int, digest: String)?
    init(model: WorkspaceModel, sessionID: String) { self.model = model; self.sessionID = sessionID }
    func search(_ query: String, start: Int) async throws -> ContentSearch {
        let id = UUID(); searchID = id
        let held = selection?.result
        var result = try await model.searchConversation(sessionID, query: query, start: start, known: held)
        guard searchID == id, !Task.isCancelled else { throw CancellationError() }
        if result.rowHashes == nil, let held, result.sameSnapshot(as: held) { result.rowHashes = held.rowHashes }
        let token = UUID().uuidString
        selection = (token, result); range = nil
        var published = result; published.revision = token
        return published
    }
    func page(first: Int, last: Int, cursor: ContentCursor, revision: String) async throws -> ContentPage {
        guard let selection, selection.token == revision else { throw HostError.failure("History changed. Refresh the range before copying") }
        let digest: String
        if let range, range.first == first, range.last == last { digest = range.digest }
        else {
            guard let hashes = selection.result.rowHashes,
                  let value = await model.history.contentRangeDigest(hashes, first: first, last: last) else { throw HostError.failure("History changed. Refresh the range before copying") }
            try Task.checkCancellation()
            guard self.selection?.token == revision else { throw CancellationError() }
            digest = value; range = (first, last, digest)
        }
        let page = try await model.conversationPage(sessionID, first: first, last: last, cursor: cursor, selection: selection.result, digest: digest)
        try Task.checkCancellation()
        guard self.selection?.token == revision else { throw CancellationError() }
        return page
    }
}

extension WorkspaceModel {
    @discardableResult
    func copySessionID(_ id: String, to pasteboard: NSPasteboard = .general) -> Bool {
        sessionReferenceCopyRevision += 1
        guard record(id) != nil else { error = "That chat is no longer available to copy."; return false }
        return writeSessionReference(id, to: pasteboard)
    }

    @discardableResult
    func copySessionReference(_ id: String, to pasteboard: NSPasteboard = .general) async -> Bool {
        await copySessionReferences([id], to: pasteboard)
    }

    @discardableResult
    func copyMarkedSessionReferences(to pasteboard: NSPasteboard = .general) async -> Bool {
        await copySessionReferences(markedChats.map(\.id), to: pasteboard)
    }

    @discardableResult
    func copySessionReferences(_ ids: [String], to pasteboard: NSPasteboard = .general,
                               query: (@MainActor ([SessionUsageScope]) async throws -> [SessionUsageScope: GatewayTotals])? = nil) async -> Bool {
        sessionReferenceCopyRevision += 1
        let revision = sessionReferenceCopyRevision, clipboardRevision = pasteboard.changeCount
        var seen = Set<String>()
        let ids = ids.filter { seen.insert($0).inserted }
        guard !ids.isEmpty, ids.count <= Self.markedSessionLimit else { error = "Select chats to copy their references."; return false }
        let records = ids.compactMap { record($0) }
        guard records.count == ids.count else { error = "A selected chat is no longer available to copy."; return false }
        let scopes = records.map { SessionUsageScope(sessionID: $0.id, workspaceID: $0.workspaceID) }
        func isCurrent() -> Bool {
            !Task.isCancelled && !isShutDown && sessionReferenceCopyRevision == revision && pasteboard.changeCount == clipboardRevision
        }
        do {
            let totals: [SessionUsageScope: GatewayTotals]
            if let query { totals = try await query(scopes) }
            else { totals = try await traces.sessionReferenceTotals(scopes: scopes) }
            guard isCurrent() else { return false }
            // Resolve current titles and file paths after the metadata read,
            // while retaining the originally requested order and identities.
            let current = ids.compactMap { record($0) }
            guard current.count == scopes.count, zip(current, scopes).allSatisfy({ $0.workspaceID == $1.workspaceID }) else {
                error = "A selected chat is no longer available to copy."; return false
            }
            let references = zip(current, scopes).map { SessionReference(chat: $0, usage: totals[$1] ?? GatewayTotals()).text }
            let heading = references.count > 1 ? "Bello Agent session references (\(references.count))\n\n" : ""
            return writeSessionReference(heading + references.joined(separator: "\n\n---\n\n"), to: pasteboard)
        } catch {
            if isCurrent() { self.error = "Session usage could not be read for copying. " + error.localizedDescription }
            return false
        }
    }

    private func writeSessionReference(_ value: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        guard pasteboard.setString(value, forType: .string) else { error = "The session reference could not be copied. Try again."; return false }
        return true
    }

    func inspectConversation(_ id: String) { contentSessionID = id; showConversationContent = true }
    func searchConversation(_ id: String, query: String, start: Int, renderedAgentProse: Bool = false, known: ContentSearch? = nil) async throws -> ContentSearch {
        let navigation = transcriptNavigation(id)
        let result = try await searchConversationSource(id, query: query, start: start, renderedAgentProse: renderedAgentProse, known: known)
        try Task.checkCancellation()
        guard navigation.isCurrent(in: self) else { throw CancellationError() }
        return result
    }
    private func searchConversationSource(_ id: String, query: String, start: Int, renderedAgentProse: Bool, known: ContentSearch?) async throws -> ContentSearch {
        if let conversationSearchLoader { return try await conversationSearchLoader(id, query, start) }
        guard let item = record(id) else { throw StoreError.invalidRecord }
        // The app owns Markdown rendering. Search its journal projection for
        // Find, including unloaded rows, without changing the helper's source
        // search or the source ranges used by Copy Conversation/Inspector.
        if renderedAgentProse {
            let view = displays[id]
            let presented = view?.versionView == nil ? view?.presentedMessages ?? [] : []
            let rawReplies = view?.disclosure.rawReplies ?? []
            let fetchedInputs = view?.toolInputs.snapshot() ?? [:]
            if let path = item.path {
                return try await history.searchContent(path: path, query: query, start: start, renderedAgentProse: true, managedChild: item.isSubagent, presented: presented, rawReplies: rawReplies, fetchedInputs: fetchedInputs, agentPresentation: view?.agentPresentation)
            }
            return try await history.searchPresented(presented, query: query, start: start, rawReplies: rawReplies, fetchedInputs: fetchedInputs)
        }
        if opened.contains(id), let host = hosts[item.workspaceID] {
            let epoch = host.epoch
            let source = ContentSearch.Source(sessionID: id, workspaceID: item.workspaceID, path: item.path, hostEpoch: epoch)
            var params: [String: WireValue] = ["query": .string(query), "start": .number(Double(start)), "retained": .bool(true)]
            if let known, known.rowHashes != nil, known.source == source {
                params["knownRevision"] = .string(known.revision); params["knownIncarnation"] = known.incarnation.map(WireValue.string)
            }
            let value = try await host.request("session.content.search", sessionID: id, params: params)
            var result = try JSONDecoder().decode(ContentSearch.self, from: JSONEncoder().encode(value))
            result.source = source
            return result
        }
        guard let path = item.path else { return .init(hits: [], total: 0, next: nil, revision: "empty") }
        let source = ContentSearch.Source(sessionID: id, workspaceID: item.workspaceID, path: path, hostEpoch: nil)
        let revision = known?.source == source && known?.rowHashes != nil ? known?.revision : nil
        var result = try await history.searchContent(path: path, query: query, start: start, retained: true, knownRevision: revision)
        result.source = source
        return result
    }
    func conversationPage(_ id: String, first: Int, last: Int, cursor: ContentCursor, selection: ContentSearch, digest: String) async throws -> ContentPage {
        guard let item = record(id), let source = selection.source, source.sessionID == id,
              source.workspaceID == item.workspaceID, source.path == item.path else { throw StoreError.invalidRecord }
        let host = hosts[item.workspaceID]
        if let epoch = source.hostEpoch, opened.contains(id), let host, host.isReady, host.epoch == epoch {
            do {
                let value = try await host.request("session.content.page", sessionID: id, params: ["first": .number(Double(first)), "last": .number(Double(last)), "index": .number(Double(cursor.index)), "offset": .number(Double(cursor.offset)), "revision": .string(selection.revision), "incarnation": selection.incarnation.map(WireValue.string) ?? .null, "digest": .string(digest)])
                return try JSONDecoder().decode(ContentPage.self, from: JSONEncoder().encode(value))
            } catch {
                // A runtime can unload or retire while its page is awaiting IPC.
                // Rebinding still verifies the complete selected range.
                if case HostError.rejected(let code, _) = error, ["history_changed", "session_missing", "session_closed"].contains(code) { }
                else if host.isReady, host.epoch == epoch, opened.contains(id) { throw error }
            }
        }
        try Task.checkCancellation()
        guard let path = source.path else { throw StoreError.invalidRecord }
        if source.hostEpoch != nil { try await host?.settleCaptureIfStopping() }
        return try await history.retainedContentPage(path: path, journalID: selection.journalID, first: first, last: last, cursor: cursor, digest: digest)
    }
    func revealConversationHit(_ id: String, hit: ContentHit) async throws {
        guard let item = record(id), let view = displays[id] else { throw StoreError.invalidRecord }
        let navigation = transcriptNavigation(id, advancing: true)
        let generation = view.presentation.readGeneration
        revealSerial += 1
        let read = revealSerial
        view.revealRead = read; view.revealFailure = nil; view.abandonJump()
        defer { if view.revealRead == read { view.revealRead = nil }; resumeVisibleReaders() }
        var page = try await readConversationWindow(item, cursor: nil, around: hit.id)
        guard !Task.isCancelled, navigation.isCurrent(in: self), transcriptShows(id), displays[id] === view, view.presentation.readGeneration == generation, view.revealRead == read else { return }
        page.messages = await withAccounting(page.messages, view: view, workspaceID: item.workspaceID)
        guard !Task.isCancelled, navigation.isCurrent(in: self), transcriptShows(id), displays[id] === view, view.presentation.readGeneration == generation, view.revealRead == read else { return }
        adoptInitialHistory(page, into: view, around: hit.id)
        view.browsingHistory = true
        anchorChanged(view)
    }

    /// Navigates from the report to a message: opens its chat, scrolls to the
    /// message when it is on the visible transcript, otherwise opens the
    /// message details sheet, which explains why it is not visible (edited
    /// away or outside the loaded page). Returns false when the chat is gone.
    @discardableResult
    func revealMessage(sessionID: String, messageID: String?, historyLookup: (@Sendable (String, String) async throws -> HistoryPage)? = nil, origin: HostedReaderToken? = nil) async -> Bool {
        guard !Task.isCancelled, origin?.isCurrent != false else { return false }
        retirePendingSubagentOpening()
        if subagentTab(sessionID)?.container?.isPane != false { messageNavigationRevision += 1 }
        guard let item = record(sessionID) else {
            error = "That chat is no longer available. It was deleted or was an unkept side conversation; its retained requests remain in the report and inspector."
            return false
        }
        if item.isSubagent {
            let opening = beginSubagentOpening(sessionID)
            defer { finishSubagentOpening(opening) }
            guard await openSubagentTab(sessionID, opening: opening) != nil, opening.isCurrent, subagentTabIsShown(sessionID) else { return false }
            guard let messageID else { return true }
            return await revealInTranscript(sessionID: sessionID, messageID: messageID, navigation: opening)
        }
        // A fork may already occupy the main column, even with a remembered
        // side slot. Reveals retain that visible destination instead of moving it.
        let sideOwner = selectedID == sessionID ? nil : (side(sessionID)?.parentID ?? sideFamilyOwner(item))
        let parentID = sideOwner ?? item.id
        // Revealing a delivery intentionally uncovers its ordinary side. That
        // hides an embedded child and transfers ownership to the main pane;
        // a popped-out origin keeps its independent cancellation token.
        let origin = sideOwner != nil && origin?.reader.container?.isPane == true ? nil : origin
        let changingSelection = selectedID != parentID
        // select changes selectedID synchronously before its first await, which
        // advances the revision once. Any additional navigation supersedes us.
        let revision = messageNavigationRevision + (changingSelection ? 1 : 0) + (page == .chats ? 0 : 1)
        let navigation = TranscriptNavigationToken(reader: nil, workspaceRevision: revision, origin: origin)
        // Reaching a side through its chat: the side is what is opened.
        if sideOwner != nil, side(sessionID) != nil { await selectSide(sessionID, revealInSidebar: false) }
        else if sideOwner != nil { await showSide(sessionID, revealInSidebar: false) }
        else if changingSelection { await select(parentID) }
        else { page = .chats; focusedSessionID = sessionID }
        guard !Task.isCancelled, navigation.isCurrent(in: self), selectedID == parentID,
              transcriptShows(sessionID), record(sessionID) != nil,
              (sideOwner == nil || side(sessionID)?.parentID == parentID),
              let view = displays[sessionID] else { return false }
        // Opening chose focus before loading. Publication neither depends on
        // that focus nor overwrites a newer responder choice after the await.
        guard let messageID else { return true }
        var expectedMessageIDs = view.messages.map(\.id)
        if view.messages.contains(where: { $0.id == messageID }) {
            view.abandonReveal(); view.abandonJump()
            view.scrollAnchor = .init(id: messageID, offset: 0, followsBottom: false); view.viewportRequestOpens = false; view.viewportRequest += 1; anchorChanged(view)
            return true
        }
        // These legacy report/search reads own the destination just like the
        // transcript's Find/Home path. Recovery must wait for their publication.
        revealSerial += 1
        let read = revealSerial
        view.revealRead = read; view.revealFailure = nil; view.abandonJump()
        defer { if view.revealRead == read { view.revealRead = nil }; resumeVisibleReaders() }
        func current() -> Bool {
            !Task.isCancelled && navigation.isCurrent(in: self) && transcriptShows(sessionID) && selectedID == parentID &&
            record(sessionID) != nil && record(sessionID)?.path == item.path && displays[sessionID] === view && view.revealRead == read && view.messages.map(\.id) == expectedMessageIDs
        }
        if historyLookup == nil {
            do {
                let generation = view.presentation.readGeneration
                var window = try await readConversationWindow(item, cursor: nil, around: messageID)
                guard current(), view.presentation.readGeneration == generation else { return false }
                guard window.messages.contains(where: { $0.id == messageID }) else {
                    showMessageDetail(sessionID, messageID: messageID)
                    return true
                }
                window.messages = await withAccounting(window.messages, view: view, workspaceID: item.workspaceID)
                guard current(), view.presentation.readGeneration == generation else { return false }
                adoptInitialHistory(window, into: view, around: messageID)
                view.browsingHistory = true; anchorChanged(view)
                return true
            } catch is CancellationError { return false }
            catch { if current() { showMessageDetail(sessionID, messageID: messageID) }; return current() }
        }
        if let path = item.path, !opened.contains(sessionID) {
            let loaded: HistoryPage?
            if let historyLookup { loaded = try? await historyLookup(path, messageID) }
            else { loaded = try? await history.read(path: path, around: messageID) }
            guard current(), !opened.contains(sessionID) else { return false }
            if let loaded, loaded.messages.contains(where: { $0.id == messageID }) {
                view.browsingHistory = true; view.messages = loaded.messages; view.before = loaded.before
                expectedMessageIDs = loaded.messages.map(\.id)
                await refreshAccounting(view, workspaceID: item.workspaceID)
                guard current() else { return false }
                view.scrollAnchor = .init(id: messageID, offset: 0, followsBottom: false); view.viewportRequestOpens = false; view.viewportRequest += 1; anchorChanged(view)
                return true
            }
        }
        guard current() else { return false }
        showMessageDetail(sessionID, messageID: messageID)
        return true
    }
}
