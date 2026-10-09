import AppKit

// The sidebar's order (0.1.122): every group lists its chats newest activity
// first — the last message sent, reply or run change — with pinned chats on
// top. There is no order of the reader's own any more.
//
// Activity must not move a row the reader is reaching for. While the pointer
// is over the sidebar's list, a row's menu is open or a row is being dragged
// (`SidebarOrderHold`), a chat that has activity keeps the place it had; the
// order catches up once the last of these ends, or the app goes to the
// background. Explicit actions (a new chat, pin, archive, a topic move)
// apply at once: the reader asked for them.

/// What holds the sidebar's order still.
enum SidebarOrderHold: Hashable, Sendable { case pointer, menu, drag }

extension WorkspaceModel {
    /// What a chat is sorted by in the sidebar: its activity, or the activity
    /// it had when the order was held.
    func sidebarActivity(_ chat: ChatRecord) -> Int64 { heldActivity[chat.id] ?? chat.activityStamp }
    /// The sidebar's comparator: `ChatRecord.sidebarPrecedes`, over what each
    /// chat is sorted by now.
    func sidebarPrecedes(_ lhs: ChatRecord, _ rhs: ChatRecord) -> Bool {
        ChatRecord.sidebarPrecedes(lhs, rhs, activity: sidebarActivity(lhs), sidebarActivity(rhs))
    }

    /// Something happened in the chat now: a message went out, or its run
    /// started, stopped or finished. Moves it up its group, unless the order
    /// is held; saved so a relaunch lists it in the same place. Never per
    /// token: these are a handful a turn.
    func noteChatActivity(_ id: String, at date: Date = Date()) {
        guard let index = chats.firstIndex(where: { $0.id == id }), !chats[index].isUtilityChat else { return }
        let stamp = Int64(date.timeIntervalSince1970 * 1_000_000)
        guard stamp > (chats[index].lastActivityAt ?? .min) else { return }
        // Held: the chat keeps its place until the hold ends.
        if !sidebarOrderHolds.isEmpty, heldActivity[id] == nil { heldActivity[id] = chats[index].activityStamp }
        chats[index].lastActivityAt = stamp
        guard !isEphemeral(id), !pendingChatIDs.contains(id), let store else { return }
        Task { try? await store.noteChatActivity(id: id, at: stamp) }
    }

    /// The reader started or stopped pointing at, pressing, or dragging in
    /// the sidebar. The order catches up when nothing holds it.
    func setSidebarOrderHold(_ reason: SidebarOrderHold, _ held: Bool) {
        if held { sidebarOrderHolds.insert(reason) } else { sidebarOrderHolds.remove(reason) }
        if sidebarOrderHolds.isEmpty, !heldActivity.isEmpty { heldActivity.removeAll() }
        if sidebarOrderHolds.isEmpty { sidebarSearchStorage?.orderReleased() }
    }
    /// The app went to the background, or the sidebar left its window:
    /// nobody is reaching for a row.
    func releaseSidebarOrder() {
        sidebarOrderHolds.removeAll()
        if !heldActivity.isEmpty { heldActivity.removeAll() }
        sidebarSearchStorage?.orderReleased()
    }
}

/// A row's menu holds the sidebar's order for as long as it is open: from
/// when the row hands it over until it stops tracking. Then the pointer,
/// which the menu took the comings and goings of, decides again.
@MainActor final class SidebarMenuOrderHold {
    private var observer: NSObjectProtocol?
    private weak var model: WorkspaceModel?
    /// The list the row was in when its menu opened, held on its own: the
    /// row may be gone by the time the menu ends, and the list is not.
    private weak var list: SidebarListDocument?
    func hold(_ menu: NSMenu, model: WorkspaceModel, list: SidebarListDocument?) {
        release()
        self.model = model; self.list = list
        model.setSidebarOrderHold(.menu, true)
        // Held strongly until the menu ends: the row that opened it may be
        // let go of (scrolled away, rebuilt) while the menu is still up.
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: menu, queue: .main) { _ in
            MainActor.assumeIsolated { self.release() }
        }
    }
    private func release() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer); self.observer = nil
        list?.recheckPointer()
        model?.setSidebarOrderHold(.menu, false)
    }
}

/// A row's drag holds the sidebar's order until it ends. What it needs at
/// the end (the model, the list) is taken when the drag begins and held
/// here, not looked up through the row: the row may be scrolled away and
/// let go of during the drag, while its surface still reports the end.
@MainActor final class SidebarDragOrderHold {
    private weak var list: SidebarListDocument?
    func callback(model: WorkspaceModel, list: @escaping @MainActor () -> SidebarListDocument?) -> @MainActor (Bool) -> Void {
        { [weak model, self] held in
            if held { self.list = list() } else { self.list?.recheckPointer() }
            model?.setSidebarOrderHold(.drag, held)
        }
    }
}
