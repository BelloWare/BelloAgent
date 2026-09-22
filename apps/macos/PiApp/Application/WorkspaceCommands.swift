import AppKit
import SwiftUI

/// What the application menu needs so that everything reachable with the
/// pointer is reachable from the keyboard: the sidebar's width, the chat row's
/// own actions, and folding the turn the reader is looking at. The menu items
/// themselves are in `PiApp.swift`; the decisions are here, next to the model
/// they act on, and are what the tests drive.

extension WindowChrome {
    /// What one press of Control-Command-Left or -Right moves the boundary.
    static let widthStep: CGFloat = 24
    /// The width the sidebar is at, as the handle last committed it.
    static var storedSidebarWidth: CGFloat {
        clampSidebarWidth(CGFloat(UserDefaults.standard.object(forKey: "sidebarWidth") as? Double ?? Double(sidebarWidth)))
    }
    /// Moves the boundary and stores it, exactly as ending a drag does, so the
    /// keyboard and the handle share one value and one set of bounds.
    @discardableResult static func adjustStoredSidebarWidth(by delta: CGFloat) -> CGFloat {
        let landed = clampSidebarWidth(storedSidebarWidth + delta)
        UserDefaults.standard.set(Double(landed), forKey: "sidebarWidth")
        return landed
    }
}

extension WorkspaceModel {
    /// The chat the menus act on: the one with keyboard focus, else the one on
    /// screen. A side conversation's own row actions live in its header, so
    /// only a saved chat answers here.
    var commandChat: ChatRecord? {
        guard page == .chats else { return nil }
        return (focusedSessionID ?? selectedID).flatMap { chatRecord($0) }
    }
    /// The conversation the fold commands act on.
    var commandSession: SessionDisplay? {
        guard page == .chats, let id = focusedSessionID ?? selectedID else { return nil }
        return displays[id]
    }

    func archiveCommandChat() { if let chat = commandChat { toggleSessionArchive(chat.id) } }
    func pinCommandChat() { if let chat = commandChat { toggleSessionPin(chat.id) } }
    func markCommandChatRead() { if let chat = commandChat { markSessionRead(chat.id) } }
    /// Topics the focused chat can be moved into, or nothing when the chat
    /// cannot hold a topic at all (the scratch project, a background task, a
    /// connection test) — the same rule the row's own menu applies.
    var commandTopicChoices: [TopicRecord] {
        guard let chat = commandChat, chat.workspaceID != WorkspaceRecord.scratchID,
              !chat.isBackgroundTask, chat.connectionTest != true else { return [] }
        return topics(in: chat.workspaceID)
    }
    func moveCommandChat(toTopic topicID: String?) {
        guard let chat = commandChat else { return }
        Task {
            do { try await moveSessions([chat.id], in: chat.workspaceID, toTopic: topicID) }
            catch { self.error = error.localizedDescription }
        }
    }

    /// The turn the reader is on: the block holding the row the transcript
    /// last reported as their reading anchor, else the newest turn. Folding is
    /// keyed by the block's own key, which survives a reply landing under its
    /// settled id, so the fold outlives the turn it was applied to.
    static func turnKey(holding anchorID: String?, in messages: [TranscriptMessage]) -> String? {
        let items = TranscriptActivity.blocks(of: messages)
        func lastKey(_ slice: ArraySlice<TranscriptItem>) -> String? {
            for case .block(let block) in slice.reversed() { return block.key }
            return nil
        }
        guard let anchorID, let index = items.firstIndex(where: { item in
            if case .block(let block) = item { return block.key == anchorID || block.replies.contains { $0.id == anchorID } }
            return item.id == anchorID
        }) else { return lastKey(items[...]) }
        // A question the reader is looking at begins a turn: the work to fold
        // is the reply under it, not the one before.
        for case .block(let block) in items[index...] { return block.key }
        return lastKey(items[..<index])
    }
    /// Every turn's work, for the fold-all pair.
    static func turnKeys(in messages: [TranscriptMessage]) -> [String] {
        TranscriptActivity.blocks(of: messages).compactMap { if case .block(let block) = $0 { return block.key }; return nil }
    }
    /// Every chronological response on the page, in order.
    static func responseIDs(in messages: [TranscriptMessage]) -> [String] {
        var ids: [String] = [], seen = Set<String>()
        for case .block(let block) in TranscriptActivity.blocks(of: messages) {
            guard let response = block.responseID, seen.insert(response).inserted else { continue }
            ids.append(response)
        }
        return ids
    }
    /// The response the reader is on: the one holding the row they last
    /// reported as their reading anchor, else the newest. Folding is keyed by
    /// the reply's own id, which outlives its streaming row.
    static func focusedResponse(holding anchorID: String?, in messages: [TranscriptMessage]) -> String? {
        let items = TranscriptActivity.blocks(of: messages)
        func lastResponse(_ slice: ArraySlice<TranscriptItem>) -> String? {
            for case .block(let block) in slice.reversed() { if let response = block.responseID { return response } }
            return nil
        }
        guard let anchorID, let index = items.firstIndex(where: { item in
            if case .block(let block) = item { return block.key == anchorID || block.responseID == anchorID || block.replies.contains { $0.id == anchorID } }
            return item.id == anchorID
        }) else { return lastResponse(items[...]) }
        for case .block(let block) in items[index...] { if let response = block.responseID { return response } }
        return lastResponse(items[..<index])
    }

    @discardableResult func setFocusedTurnFolded(_ folded: Bool) -> String? {
        guard let session = commandSession else { return nil }
        let key = Self.turnKey(holding: session.scrollAnchor?.id, in: session.presentedMessages)
        if let key { session.disclosure.setOpen(!folded, .work(key)) }
        // The same shortcut folds a chronological response as a whole: every
        // reasoning segment and every card inside it. Unfolding also clears
        // the one-line fold, so ⌥⌘] always leaves the response open.
        if let response = Self.focusedResponse(holding: session.scrollAnchor?.id, in: session.presentedMessages) {
            session.disclosure.setOpen(folded, .response(response))
            if !folded { session.disclosure.setOpen(false, .responseLine(response)) }
        }
        guard key != nil || Self.canFold(session) else { return nil }
        session.publishTranscript()
        return key ?? Self.focusedResponse(holding: session.scrollAnchor?.id, in: session.presentedMessages)
    }
    private static func canFold(_ session: SessionDisplay) -> Bool { !responseIDs(in: session.presentedMessages).isEmpty }
    @discardableResult func setEveryTurnFolded(_ folded: Bool) -> Int {
        guard let session = commandSession else { return 0 }
        let keys = Self.turnKeys(in: session.presentedMessages)
        for key in keys { session.disclosure.setOpen(!folded, .work(key)) }
        for response in Self.responseIDs(in: session.presentedMessages) {
            session.disclosure.setOpen(folded, .response(response))
            if !folded { session.disclosure.setOpen(false, .responseLine(response)) }
        }
        if !keys.isEmpty { session.publishTranscript() }
        return keys.count
    }
    /// The focused response folded down to its one line, or opened again.
    @discardableResult func setFocusedResponseCollapsed(_ collapsed: Bool) -> String? {
        guard let session = commandSession,
              let response = Self.focusedResponse(holding: session.scrollAnchor?.id, in: session.presentedMessages) else { return nil }
        session.disclosure.setOpen(collapsed, .responseLine(response))
        if !collapsed { session.disclosure.setOpen(false, .response(response)) }
        session.publishTranscript()
        return response
    }
    /// Whether the focused chat has a chronological response to fold at all.
    var canFoldResponses: Bool { commandSession.map { !Self.responseIDs(in: $0.presentedMessages).isEmpty } ?? false }
    /// Whether there is a turn with work to fold at all, so the menu items can
    /// say so instead of doing nothing.
    var canFoldTurns: Bool { commandSession.map { !Self.turnKeys(in: $0.presentedMessages).isEmpty } ?? false }
}
