import Foundation

// Earlier versions of an edited message, and forks from any reply.
//
// Every edit leaves the message it replaced, and the replies that followed
// it, in the chat's journal. The transcript shows the latest version; the
// edited message's switcher (`‹ 2 / 2 ›`, or ⌥← and ⌥→) shows an earlier one
// in its place, read-only, paged from the helper off the main actor. The
// composer and the model's context never leave the latest version, and a
// send returns the transcript to it.

extension WorkspaceModel {
    /// ‹ or ›: the version `step` away from the one a row shows. The row is
    /// the latest version's message, or the earlier version on screen.
    func showVersion(sessionID: String, messageID: String, step: Int) {
        guard let view = displays[sessionID], let group = versionGroup(view, containing: messageID) else { return }
        showVersion(sessionID: sessionID, latestID: group.latestID, index: min(max(1, group.index + step), group.count), count: group.count,
                    ids: group.ids, live: group.live)
    }

    /// ⌥← and ⌥→: a step through the versions of the edited message the
    /// reader used last, or else the latest edited message on the page.
    /// False when the chat shows no edited message.
    @discardableResult func stepVersion(sessionID: String?, step: Int) -> Bool {
        guard let id = sessionID ?? focusedSessionID ?? selectedID, let view = displays[id] else { return false }
        let target = view.versionView?.latestID
            ?? view.versionFocus.flatMap { focus in view.messages.contains { $0.id == focus && $0.versions?.usable == true } ? focus : nil }
            ?? view.messages.last { $0.role == "user" && $0.versions?.usable == true }?.id
        guard let target, let group = versionGroup(view, containing: target) else { return false }
        let index = min(max(1, group.index + step), group.count)
        if index != group.index { showVersion(sessionID: id, latestID: group.latestID, index: index, count: group.count, ids: group.ids, live: group.live) }
        return true
    }

    /// Shows version `index` of the message the chat holds as `latestID`,
    /// version `live`; that one returns the transcript to it.
    func showVersion(sessionID: String, latestID: String, index: Int, count: Int, ids: [String], live: Int? = nil) {
        guard let view = displays[sessionID], ids.count == count, (1...count).contains(index) else { return }
        view.versionFocus = latestID
        let live = live ?? count
        guard index != live else { latestVersion(sessionID: sessionID); return }
        if let shown = view.versionView, shown.latestID == latestID, shown.index == index { return }
        view.versionLoad?.cancel()
        view.versionView = TranscriptVersionView(latestID: latestID, index: index, count: count, ids: ids, live: live)
        let messageID = ids[index - 1]
        view.versionLoad = Task { [weak self, weak view] in
            guard let self, let view else { return }
            @MainActor func current() -> Bool { !Task.isCancelled && view.versionView?.latestID == latestID && view.versionView?.index == index }
            do {
                // Page by page: the first page shows as soon as it is read,
                // the rest follow it, each decoded off the main actor.
                var offset: Int? = 0, first = true
                while let from = offset {
                    let page = try await self.readVersionPage(sessionID: sessionID, messageID: messageID, offset: from)
                    guard current() else { return }
                    var rows = TranscriptVersionView.readOnly(page.rows, index: index, count: count, ids: ids, first: first)
                    // Old replies keep their receipts: the request log's figures for them.
                    if let workspaceID = self.record(sessionID)?.workspaceID,
                       let accounting = try? await self.traces.gatewayAccounting(sessionID: sessionID, workspaceID: workspaceID, messages: rows, includeTiming: false) {
                        for position in rows.indices { rows[position].accounting = accounting.messages[rows[position].id] }
                    }
                    guard current(), var shown = view.versionView else { return }
                    // One change, one publish.
                    shown.rows += rows; shown.tasks += page.tasks; shown.loading = false
                    view.versionView = shown
                    first = false
                    offset = page.next.flatMap { $0 > from && shown.rows.count < HistoryWindowPolicy.residentRows ? $0 : nil }
                }
            } catch is CancellationError {
            } catch {
                guard current(), var shown = view.versionView else { return }
                shown.loading = false; shown.failure = "This version could not be read: " + error.localizedDescription
                view.versionView = shown
            }
        }
    }

    /// Back to latest: the banner's link, the switcher's last version, a send.
    func latestVersion(sessionID: String) {
        guard let view = displays[sessionID] else { return }
        view.versionLoad?.cancel(); view.versionLoad = nil
        if view.versionView != nil { view.versionView = nil }
    }

    /// Where a row stands among its versions: the latest version's message id,
    /// the version shown, how many there are and every version's id.
    private func versionGroup(_ view: SessionDisplay, containing messageID: String) -> (latestID: String, index: Int, count: Int, ids: [String], live: Int)? {
        if let shown = view.versionView, shown.latestID == messageID || shown.ids.contains(messageID) {
            return (shown.latestID, shown.index, shown.count, shown.ids, shown.live)
        }
        guard let row = view.messages.first(where: { $0.id == messageID }), let mark = row.versions, mark.usable, let ids = mark.ids else { return nil }
        return (row.id, mark.index, mark.count, ids, mark.index)
    }

    /// One page of a version's rows from the helper, decoded off the main
    /// actor, and where the next page starts.
    func readVersionPage(sessionID: String, messageID: String, offset: Int) async throws -> (rows: [TranscriptMessage], tasks: [TaskPresentationRecord], next: Int?) {
        if let versionPageLoader {
            let loaded = try await versionPageLoader(sessionID, messageID)
            return (loaded.rows, loaded.tasks, nil)
        }
        guard let item = record(sessionID) else { throw HostError.failure("This conversation is no longer available.") }
        // An earlier version is read from the chat's own helper, as an edit is.
        let host = try await open(item)
        try Task.checkCancellation()
        let result = try await host.request("session.version.page", sessionID: sessionID,
                                            params: ["messageId": .string(messageID), "offset": .number(Double(offset))]).object ?? [:]
        let page = try await Task.detached(priority: .userInitiated) { () throws -> ([TranscriptMessage], [TaskPresentationRecord]) in
            let decoded = try TranscriptMessage.page(result["messages"] ?? .array([]))
            let records = (try? JSONDecoder().decode([TaskPresentationRecord].self, from: JSONEncoder().encode(result["taskRecords"] ?? .array([])))) ?? []
            return (decoded, records)
        }.value
        return (page.0, page.1, result["next"]?.number.flatMap { Int(exactly: $0) })
    }

    /// Every edited message's versions, as the chat's helper numbers them
    /// (`session.versions`), when the helper has the chat open. The Inspector
    /// nests each earlier version, and the turns it ran on into, under the
    /// turn as it stands. Nil when no helper has the chat: the rows on the
    /// page say as much as is needed then.
    func messageVersionGroups(sessionID: String) async -> [[String: WireValue]]? {
        guard let item = record(sessionID), opened.contains(sessionID), let host = hosts[item.workspaceID], host.isReady,
              let result = try? await host.request("session.versions", sessionID: sessionID).object else { return nil }
        return result["groups"]?.array?.compactMap(\.object)
    }

    // MARK: Fork from here

    /// Whether a chat's replies offer "Fork from here": a saved chat of the
    /// app's own, not an unkept side, an imported original or a background task.
    func canForkFromReply(_ sessionID: String) -> Bool {
        guard let item = record(sessionID) else { return false }
        return !item.imported && !item.isBackgroundTask && item.connectionTest != true && !isEphemeral(sessionID)
    }

    /// "Fork from here" on a reply: a new chat, "‹title› · fork", nested
    /// under this one, whose conversation ends at that reply and its tools.
    /// It opens with its composer focused.
    func forkFromReply(sessionID: String, messageID: String) {
        // The Inspector offers this for a chat with no display this launch
        // (never shown, or let go): the fork needs only its saved record.
        guard !installPreparing, record(sessionID) != nil else { return }
        if forkingReplies.contains(sessionID) { return }
        forkingReplies.insert(sessionID)
        // The fork opens only if the reader is still where they asked for
        // it, as with /fork: one who moved on meanwhile is not pulled back.
        let selectedBefore = selectedID
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.forkingReplies.remove(sessionID)
                if let workspace = self.record(sessionID)?.workspaceID {
                    self.updateHostActivity(workspaceID: workspace)
                    if let host = self.hosts[workspace] { self.scheduleIdle(workspaceID: workspace, host: host) }
                }
            }
            do {
                let fork = try await self.createFork(parentID: sessionID, atMessageID: messageID)
                guard self.selectedID == selectedBefore else { return }
                await self.select(fork.id)
                self.focusComposer(fork.id)
            } catch {
                self.displays[sessionID]?.notice = error.localizedDescription
                self.error = error.localizedDescription
            }
        }
    }

    /// The reply a request produced, for "Fork from here" on the Inspector's
    /// request page: from the rows on screen, else from the request log's
    /// links and the journal's own record of each linked message's role.
    func replyID(forAttempt attemptID: String, sessionID: String) async -> String? {
        if let view = displays[sessionID] {
            let rows = view.presentedMessages + view.messages
            if let row = rows.first(where: { $0.role == "assistant" && ($0.reply?.attempt == attemptID || $0.requestAttemptIDs?.contains(attemptID) == true) }) {
                return row.id
            }
        }
        guard let path = record(sessionID)?.path,
              let links = try? await traces.linkedMessages(attemptID: attemptID) else { return nil }
        for id in links.output where (try? await history.messageRole(path: path, id: id)) == "assistant" { return id }
        return nil
    }
}
