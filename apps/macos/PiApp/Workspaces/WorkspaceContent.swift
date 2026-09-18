import SwiftUI

extension WorkspaceModel {
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
        let wasBrowsing = view.browsingHistory
        var loaded = false
        view.browsingHistory = true
        defer { if !loaded { view.browsingHistory = wasBrowsing } }
        if opened.contains(id), let host = hosts[item.workspaceID] {
            let result = try await host.request("session.history", sessionID: id, params: ["before": .number(Double(hit.position))]).object ?? [:]
            view.messages = try JSONDecoder().decode([TranscriptMessage].self, from: JSONEncoder().encode(result["messages"] ?? .array([])))
            view.hostBefore = result["before"]?.number
        } else if let path = item.path {
            let page = try await history.read(path: path, around: hit.id); view.messages = page.messages; view.before = page.before
        } else { throw HostError.failure("This conversation has no saved history to open.") }
        loaded = true
        view.scrollAnchor = .init(id: hit.id, offset: 0, followsBottom: false); view.viewportRequest += 1; anchorChanged(view)
        await refreshAccounting(view, workspaceID: item.workspaceID)
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
