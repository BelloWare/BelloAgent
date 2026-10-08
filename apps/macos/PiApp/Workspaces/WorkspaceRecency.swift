import Foundation

// Recently opened chats (0.1.122): the sidebar row of the chat open now has
// the accent wash, and the chats opened before it keep a fainter one, fading
// out over four steps (`PiKit.SelectableRow.recencyLadder`). The rank is the
// order of opening, not time. It changes only when a chat is opened, so rows
// redraw then and never with a run's tokens. It is kept with the selection
// (`RememberedSelection.recentChats`), so a relaunch shows the same wash.

extension WorkspaceModel {
    /// How many chats are remembered by order of opening.
    nonisolated static let recentlyOpenedLimit = 16

    /// The reader came to a chat (or launch reopened it): it is the most recent.
    func noteOpened(_ id: String) {
        guard recentlyOpened.first != id else { return }
        var next = recentlyOpened.filter { $0 != id }
        next.insert(id, at: 0)
        if next.count > Self.recentlyOpenedLimit { next.removeLast(next.count - Self.recentlyOpenedLimit) }
        recentlyOpened = next
    }
    /// The chat's place by order of opening (0: the one open now), when it
    /// is among those the sidebar washes.
    func recencyRank(_ id: String) -> Int? {
        guard let rank = recentlyOpened.firstIndex(of: id), rank < PiKit.SelectableRow.recencyLadder.count else { return nil }
        return rank
    }
    /// What is written with the selection: chats a relaunch can list, in order.
    var recentChatsToRemember: [String]? {
        let durable = recentlyOpened.filter { id in
            chatRecord(id).map { !$0.isUtilityChat } == true && !pendingChatIDs.contains(id) && !isEphemeral(id)
        }
        return durable.isEmpty ? nil : durable
    }
    /// The order of opening read back at launch, for the chats that still exist.
    func adoptRecentChats(_ ids: [String]?) {
        var seen: Set<String> = []
        recentlyOpened = (ids ?? []).filter { id in chatRecord(id).map { !$0.isUtilityChat } == true && seen.insert(id).inserted }
            .prefix(Self.recentlyOpenedLimit).map { $0 }
    }
    /// Opening `parent` only on the way to its side: the side is what the
    /// reader opened, not the parent. Only the one focus the navigation
    /// itself gives the parent is passed over (it is taken by it); the
    /// reader focusing the parent while the side loads is an opening.
    func passingThrough(_ parent: String, _ body: @MainActor () async -> Void) async {
        let added = recencyPassing.insert(parent).inserted
        defer { if added { recencyPassing.remove(parent) } }
        await body()
    }
    /// A chat that existed only on screen is gone: it holds no place.
    func forgetOpened(_ id: String) { recentlyOpened.removeAll { $0 == id } }
}
