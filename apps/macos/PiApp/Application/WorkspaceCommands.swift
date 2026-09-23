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

    /// The page the fold commands act on, planned the way the transcript
    /// plans it: the same resident window, the same task lifecycle, the same
    /// reading of whether the page reaches the newest row. A command plans it
    /// once and asks everything of that one plan.
    static func commandItems(_ session: SessionDisplay) -> [TranscriptItem] {
        let presented = session.presentedMessages, page = TranscriptPage.displayPage(presented)
        return TaskTranscriptPlan.items(page, lifecycle: session.taskPresentation,
                                        complete: page.count == presented.count && !session.newerPage.available)
    }
    private static func position(of anchorID: String, in items: [TranscriptItem], response: Bool = false) -> Int? {
        items.firstIndex { item in
            if case .block(let block) = item {
                return block.key == anchorID || (response && block.responseID == anchorID) || block.replies.contains { $0.id == anchorID }
            }
            return item.id == anchorID
        }
    }
    /// A block the reader can open or close as work. A turn's fold line and a
    /// task's receipt are not: the line is the end-of-turn fold's own control.
    private static func workBlock(_ item: TranscriptItem) -> TranscriptBlock? {
        guard case .block(let block) = item, block.presentation != .turnFold, block.presentation != .summary else { return nil }
        return block
    }

    /// The turn the reader is on: the block holding the row the transcript
    /// last reported as their reading anchor, else the newest turn. Folding is
    /// keyed by the block's own key, which survives a reply landing under its
    /// settled id, so the fold outlives the turn it was applied to.
    static func turnKey(holding anchorID: String?, in messages: [TranscriptMessage]) -> String? {
        turnKey(holding: anchorID, in: TranscriptActivity.blocks(of: messages))
    }
    static func turnKey(holding anchorID: String?, in items: [TranscriptItem]) -> String? {
        func lastKey(_ slice: ArraySlice<TranscriptItem>) -> String? {
            for item in slice.reversed() { if let block = workBlock(item) { return block.key } }
            return nil
        }
        guard let anchorID, let index = position(of: anchorID, in: items) else { return lastKey(items[...]) }
        // A question the reader is looking at begins a turn: the work to fold
        // is the reply under it, not the one before.
        for item in items[index...] { if let block = workBlock(item) { return block.key } }
        return lastKey(items[..<index])
    }
    /// Every turn's work, for the fold-all pair.
    static func turnKeys(in messages: [TranscriptMessage]) -> [String] { turnKeys(in: TranscriptActivity.blocks(of: messages)) }
    static func turnKeys(in items: [TranscriptItem]) -> [String] { items.compactMap { workBlock($0)?.key } }
    /// Every chronological response on the page, in order.
    static func responseIDs(in messages: [TranscriptMessage]) -> [String] { responseIDs(in: TranscriptActivity.blocks(of: messages)) }
    static func responseIDs(in items: [TranscriptItem]) -> [String] {
        var ids: [String] = [], seen = Set<String>()
        for case .block(let block) in items {
            guard let response = block.responseID, seen.insert(response).inserted else { continue }
            ids.append(response)
        }
        return ids
    }
    /// The response the reader is on: the one holding the row they last
    /// reported as their reading anchor, else the newest. Folding is keyed by
    /// the reply's own id, which outlives its streaming row.
    static func focusedResponse(holding anchorID: String?, in messages: [TranscriptMessage]) -> String? {
        focusedResponse(holding: anchorID, in: TranscriptActivity.blocks(of: messages))
    }
    static func focusedResponse(holding anchorID: String?, in items: [TranscriptItem]) -> String? {
        func lastResponse(_ slice: ArraySlice<TranscriptItem>) -> String? {
            for case .block(let block) in slice.reversed() { if let response = block.responseID { return response } }
            return nil
        }
        guard let anchorID, let index = position(of: anchorID, in: items, response: true) else { return lastResponse(items[...]) }
        for case .block(let block) in items[index...] { if let response = block.responseID { return response } }
        return lastResponse(items[..<index])
    }
    /// Every finished turn's fold on the page: the id of the reader's message
    /// that opened each display turn whose work is behind one line.
    static func turnFolds(in items: [TranscriptItem]) -> [String] {
        items.compactMap { if case .block(let block) = $0 { return block.foldControl }; return nil }
    }
    /// The end-of-turn fold of the display turn the reader is on: the one the
    /// reader's latest message at or above their anchor opened, else the
    /// newest. A row above the page's first question belongs to no fold.
    static func turnFold(holding anchorID: String?, in items: [TranscriptItem]) -> String? {
        let folds = turnFolds(in: items)
        guard !folds.isEmpty else { return nil }
        guard let anchorID, let index = position(of: anchorID, in: items, response: true) else { return folds.last }
        for case .message(let message) in items[...index].reversed() where message.role == "user" && message.kind == nil {
            return folds.contains(message.id) ? message.id : nil
        }
        return nil
    }

    @discardableResult func setFocusedTurnFolded(_ folded: Bool) -> String? {
        guard let session = commandSession else { return nil }
        let items = Self.commandItems(session), anchor = session.scrollAnchor?.id
        let key = Self.turnKey(holding: anchor, in: items)
        if let key { session.disclosure.setOpen(!folded, .work(key)) }
        // The same shortcut folds a chronological response as a whole: every
        // reasoning segment and every card inside it. Unfolding also clears
        // the one-line fold, so ⌥⌘] always leaves the response open.
        let response = Self.focusedResponse(holding: anchor, in: items)
        if let response {
            session.disclosure.setOpen(folded, .response(response))
            if !folded { session.disclosure.setOpen(false, .responseLine(response)) }
        }
        // And the end-of-turn fold: the one line a finished turn reads as is
        // what ⌥⌘[ gives back and what ⌥⌘] opens.
        let fold = Self.turnFold(holding: anchor, in: items)
        if let fold { session.disclosure.setOpen(!folded, .turnFold(fold)) }
        guard key != nil || response != nil || fold != nil else { return nil }
        session.publishTranscript()
        return key ?? response ?? fold
    }
    @discardableResult func setEveryTurnFolded(_ folded: Bool) -> Int {
        guard let session = commandSession else { return 0 }
        let items = Self.commandItems(session)
        let keys = Self.turnKeys(in: items), folds = Self.turnFolds(in: items)
        for key in keys { session.disclosure.setOpen(!folded, .work(key)) }
        for response in Self.responseIDs(in: items) {
            session.disclosure.setOpen(folded, .response(response))
            if !folded { session.disclosure.setOpen(false, .responseLine(response)) }
        }
        for fold in folds { session.disclosure.setOpen(!folded, .turnFold(fold)) }
        if !keys.isEmpty || !folds.isEmpty { session.publishTranscript() }
        return keys.count
    }
    /// The focused response folded down to its one line, or opened again.
    @discardableResult func setFocusedResponseCollapsed(_ collapsed: Bool) -> String? {
        guard let session = commandSession,
              let response = Self.focusedResponse(holding: session.scrollAnchor?.id, in: Self.commandItems(session)) else { return nil }
        session.disclosure.setOpen(collapsed, .responseLine(response))
        if !collapsed { session.disclosure.setOpen(false, .response(response)) }
        session.publishTranscript()
        return response
    }
    // SwiftUI evaluates the Conversation menu on every publish of the model,
    // and asks each fold item whether it is enabled. Each used to plan the
    // whole page to answer, six plans per evaluation; the rows answer instead.
    // A command plans once, when it runs.

    /// Whether the focused chat has a chronological response to fold at all.
    var canFoldResponses: Bool { commandSession.map { Self.shownRows($0).contains(where: Self.respondsInOrder) } ?? false }
    /// Whether there is a turn with work to fold at all, so the menu items can
    /// say so instead of doing nothing.
    var canFoldTurns: Bool {
        commandSession.map { session in
            (session.historyState != .loading && session.taskPresentation?.active != nil) || Self.shownRows(session).contains(where: Self.yieldsWork)
        } ?? false
    }
    /// The rows the page shows, as the planner would read them: none while
    /// history loads. The notices the page appends never fold, so they are
    /// not needed to answer.
    private static func shownRows(_ session: SessionDisplay) -> [TranscriptMessage] {
        session.historyState == .loading ? [] : session.messages
    }
    /// A reply the planner lays out as a chronological response: a header
    /// line and its parts in the order they arrived.
    nonisolated private static func respondsInOrder(_ message: TranscriptMessage) -> Bool {
        guard (message.role == "assistant" && message.kind == nil) || message.kind == "requestLedger",
              let timeline = message.responseTimeline else { return false }
        return timeline.supported && !timeline.segments.isEmpty
    }
    /// A reply the planner draws at least one block for.
    nonisolated private static func yieldsWork(_ message: TranscriptMessage) -> Bool {
        guard (message.role == "assistant" && message.kind == nil) || message.kind == "requestLedger" else { return false }
        return respondsInOrder(message) || !(message.thinking ?? "").isEmpty || !(message.tools ?? []).isEmpty
            || TaskTranscriptPlan.visible(message.text)
    }
}
