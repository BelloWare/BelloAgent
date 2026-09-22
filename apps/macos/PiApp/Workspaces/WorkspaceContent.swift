import SwiftUI
import AppKit

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
            !Task.isCancelled && !accountingStopped && sessionReferenceCopyRevision == revision && pasteboard.changeCount == clipboardRevision
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
    func searchConversation(_ id: String, query: String, start: Int) async throws -> ContentSearch {
        guard let item = record(id) else { throw StoreError.invalidRecord }
        if opened.contains(id), let host = hosts[item.workspaceID] {
            let value = try await host.request("session.content.search", sessionID: id, params: ["query": .string(query), "start": .number(Double(start))])
            return try JSONDecoder().decode(ContentSearch.self, from: JSONEncoder().encode(value))
        }
        guard let path = item.path else { return .init(hits: [], total: 0, next: nil, revision: "empty") }
        return try await history.searchContent(path: path, query: query, start: start)
    }
    func conversationPage(_ id: String, first: Int, last: Int, cursor: ContentCursor, revision: String) async throws -> ContentPage {
        guard let item = record(id) else { throw StoreError.invalidRecord }
        if opened.contains(id), let host = hosts[item.workspaceID] {
            let value = try await host.request("session.content.page", sessionID: id, params: ["first": .number(Double(first)), "last": .number(Double(last)), "index": .number(Double(cursor.index)), "offset": .number(Double(cursor.offset)), "revision": .string(revision)])
            return try JSONDecoder().decode(ContentPage.self, from: JSONEncoder().encode(value))
        }
        guard let path = item.path else { throw StoreError.invalidRecord }
        return try await history.copyContentPage(path: path, first: first, last: last, cursor: cursor, revision: revision)
    }
    func revealConversationHit(_ id: String, hit: ContentHit) async throws {
        guard let item = record(id), let view = displays[id] else { throw StoreError.invalidRecord }
        let generation = view.presentationGeneration
        let page = try await readConversationWindow(item, cursor: nil, around: hit.id)
        guard !Task.isCancelled, displays[id] === view, view.presentationGeneration == generation else { return }
        adoptInitialHistory(page, into: view, around: hit.id)
        view.browsingHistory = true
        anchorChanged(view)
    }

    /// Navigates from the report to a message: opens its chat, scrolls to the
    /// message when it is on the visible transcript, otherwise opens the
    /// message details sheet, which explains why it is not visible (edited
    /// away or outside the loaded page). Returns false when the chat is gone.
    @discardableResult
    func revealMessage(sessionID: String, messageID: String?, historyLookup: (@Sendable (String, String) async throws -> HistoryPage)? = nil) async -> Bool {
        guard !Task.isCancelled else { return false }
        messageNavigationRevision += 1
        guard let item = record(sessionID) else {
            error = "That chat is no longer available. It was deleted or was an unkept side conversation; its retained requests remain in the report and inspector."
            return false
        }
        let parentID = side(sessionID)?.parentID ?? item.id
        let changingSelection = selectedID != parentID
        // select changes selectedID synchronously before its first await, which
        // advances the revision once. Any additional navigation supersedes us.
        let revision = messageNavigationRevision + (changingSelection ? 1 : 0)
        if changingSelection { await select(parentID) }
        guard !Task.isCancelled, revision == messageNavigationRevision, selectedID == parentID,
              !changingSelection || page == .chats, record(sessionID) != nil,
              (side(sessionID)?.parentID ?? sessionID) == parentID,
              let view = displays[sessionID] else { return false }
        focusedSessionID = sessionID
        page = .chats
        guard let messageID else { return true }
        var expectedMessageIDs = view.messages.map(\.id)
        if view.messages.contains(where: { $0.id == messageID }) {
            view.scrollAnchor = .init(id: messageID, offset: 0, followsBottom: false); view.viewportRequest += 1; anchorChanged(view)
            return true
        }
        func current() -> Bool {
            !Task.isCancelled && revision == messageNavigationRevision && page == .chats && selectedID == parentID && focusedSessionID == sessionID &&
            record(sessionID) != nil && record(sessionID)?.path == item.path && displays[sessionID] === view && view.messages.map(\.id) == expectedMessageIDs
        }
        if historyLookup == nil {
            do {
                let generation = view.presentationGeneration
                let window = try await readConversationWindow(item, cursor: nil, around: messageID)
                guard current(), view.presentationGeneration == generation else { return false }
                guard window.messages.contains(where: { $0.id == messageID }) else {
                    showMessageDetail(sessionID, messageID: messageID)
                    return true
                }
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
                view.scrollAnchor = .init(id: messageID, offset: 0, followsBottom: false); view.viewportRequest += 1; anchorChanged(view)
                return true
            }
        }
        guard current() else { return false }
        showMessageDetail(sessionID, messageID: messageID)
        return true
    }
}
