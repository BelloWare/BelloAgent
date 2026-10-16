import Foundation

// Resume, and pausing for an update.
//
// Resume goes on with a run that stopped before it finished — by Stop, a
// quit, a restart or an update — from the chat's history as it stands, with
// no new user message (`run.continue`, pi's continue). The helper never runs
// a cut-off tool call again: its recorded result goes to the model, which
// decides. Queued follow-ups go on after the resumed run. Nothing here
// resumes on its own; only the reader's Resume does.
//
// Checking for updates pauses nothing. Installing one over running chats
// asks once, then pauses them as Quit does (their helpers stop the way Stop
// does and are waited for, and their holds are saved) before the install;
// after the relaunch the paused chats offer Resume (`UpdateController`).

extension WorkspaceModel {
    /// The pending-intent key of a Resume, matching the helper's receipt.
    nonisolated static let resumeIntentPrefix = "continue:"

    /// Resume in the focused chat (the Conversation menu), or `sessionID`'s
    /// (its paused row, its queue panel). One at a time per chat: a press
    /// while one is on its way does nothing, and the helper refuses a second
    /// run besides (`session_busy`), so a double click, or Resume racing a
    /// Send, never starts two runs.
    func resumeRun(sessionID: String? = nil) {
        guard !installPreparing, let id = sessionID ?? focusedSessionID ?? selectedID, let item = record(id), !item.isSubagent, !item.isBackgroundTask,
              let view = displays[id] else { return }
        guard !item.isArchived else { view.notice = Self.archivedNotice; return }
        guard !view.resuming, !view.busy, !view.loading else { return }
        // A family paused at its cost limit resumes as one: its root, then
        // every paused side it names, from whichever member's Resume.
        if view.costPaused { resumeCostPausedFamily(from: item); return }
        // The run goes on in the latest version, and the transcript returns to it, as for a send.
        latestVersion(sessionID: id)
        view.resuming = true
        resumeSteps?("accepted")
        Task {
            defer { view.resuming = false; updateHostActivity(workspaceID: item.workspaceID) }
            _ = await performResume(item, view: view)
        }
    }

    /// Resume after the family's cost limit was raised (owner, 2026-10-16:
    /// raising alone resumes nothing). The root's `run.continue` resumes its
    /// own run and sub-agents and names its paused sides; each side's resumes
    /// its run and its own sub-agents. Refused while the spend is at the limit.
    func resumeCostPausedFamily(from item: ChatRecord) {
        guard !installPreparing else { return }
        // Unknown spend goes to the helper, which refuses at the limit.
        guard !costReading(for: item.id).reached else {
            displays[item.id]?.notice = "Still at the cost limit. Raise the limit above the spend, then choose Resume."
            return
        }
        let root = budgetOwner(for: item)
        latestVersion(sessionID: item.id)
        var views: [SessionDisplay] = []
        for view in [displays[root.id], displays[item.id]] { if let view, !views.contains(where: { $0 === view }) { views.append(view) } }
        for view in views { view.resuming = true }
        resumeSteps?("accepted")
        Task {
            defer { for view in views { view.resuming = false }; updateHostActivity(workspaceID: item.workspaceID) }
            var members: [String] = []
            if root.id == item.id || isCostPaused(root.id) {
                guard let reply = await performResume(root, view: displays[root.id], member: root.id != item.id) else { return }
                members = reply["pausedMembers"]?.array?.compactMap(\.string) ?? []
            }
            var order = members.filter { $0 != root.id }
            if item.id != root.id, !order.contains(item.id) { order.append(item.id) }
            for id in order {
                guard let member = record(id), !member.isArchived, member.workspaceID == root.workspaceID else { continue }
                _ = await performResume(member, view: displays[id], member: true)
            }
        }
    }

    /// One `run.continue`, recorded as a pending intent first for a durable
    /// chat. Returns the helper's reply; nil when it was refused or failed.
    /// `member`: part of a family Resume, where a chat with nothing of its
    /// own left (a side the root already resumed) is not an error.
    func performResume(_ item: ChatRecord, view: SessionDisplay?, member: Bool = false) async -> [String: WireValue]? {
        let commandID = UUID().uuidString, params = turnOverrides(for: item)
        let durable = !isEphemeral(item.id)
        var recorded = false
        defer { refresh(item.id) }
        do {
            let lease = try connectionLease(for: item)
            // A helper stopped for an update, or restarting, is started
            // again here: the chat reopens from its journal, paused.
            let host = try await open(item)
            if durable {
                guard let store else { throw StoreError.unavailable }
                // As for a compaction: the command's record is on disk
                // before it goes, and the helper's receipt settles it.
                try await store.put(CommandIntent(id: commandID, sessionID: item.id, turnID: Self.resumeIntentPrefix + commandID, text: "[Resume]",
                                                  state: "intent", epoch: host.epoch), kind: "pending:\(item.id)", id: commandID)
                recorded = true; pendingIntentsChanged(item.id)
            }
            try requireConnection(lease)
            resumeSteps?("dispatched")
            let reply = try await host.request("run.continue", sessionID: item.id, params: params, commandID: commandID)
            view?.acceptedCommands.insert(commandID)
            if reply.object?["continued"]?.bool == true || reply.object?["resumedQueue"]?.bool == true { noteChatActivity(item.id) }
            if durable { try? await store?.acknowledgeCommand(sessionID: item.id, commandID: commandID); pendingIntentsChanged(item.id) }
            // What comes next is what the reader wants to see.
            if !member { followSubmittedTurn(item.id) }
            resumeSteps?("answered")
            return reply.object ?? [:]
        } catch {
            let rejection: String? = { if case HostError.rejected(let code, _) = error { return code }; return nil }()
            // A refused Resume never ran: its record goes.
            if recorded, rejection != nil { try? await store?.remove(kind: "pending:\(item.id)", id: commandID); pendingIntentsChanged(item.id) }
            switch rejection {
            case "session_busy":
                // A run is already going (a Send, or another Resume, got
                // there first): that is the chat's run now.
                break
            case "nothing_to_continue":
                if !member {
                    view?.continuable = false
                    view?.notice = "There is nothing to resume. Send a new message to go on."
                }
            case SessionDisplay.costLimitCode:
                view?.notice = error.localizedDescription
            default:
                self.error = error.localizedDescription
            }
            resumeSteps?("failed")
            return nil
        }
    }

    /// What a Resume button does in `view`'s chat: goes on with the stopped
    /// run when there is one; otherwise sends the paused follow-ups.
    func resumeOrSendQueued(_ view: SessionDisplay) {
        // A Resume on its way holds the chat: a second press sends nothing,
        // not even the follow-ups, which would overtake the continuation.
        // A send on its way too: what it does decides what Resume means.
        guard !view.resuming, !view.loading, !view.busy else { return }
        // Unknown (`continuable` nil) goes to the helper too: from an answered
        // chat its continue sends what waits, as Resume Follow-ups does.
        if view.showsPausedRun { resumeRun(sessionID: view.id) }
        else { action("queue.resume", sessionID: view.id) }
    }

    /// Running chats, for the update's question: those with a run under way.
    var runningChatCount: Int { displays.values.filter { $0.busy }.count }

    /// Pauses every chat's work before an update installs, as Quit does: what was
    /// typed into unkept sides moves to their chats and drafts are saved;
    /// every helper stops the way Stop does and is waited for, so a reply cut
    /// off mid-stream stays as an interrupted row; the chats it paused are
    /// saved as paused. The app keeps running: each chat's helper starts again
    /// when the chat is next used, and a paused chat shows Resume.
    func pauseRunsForUpdate(settleTimeout: TimeInterval = 15) async throws {
        guard !isShutDown else { throw CancellationError() }
        // No new send, Resume or command starts meanwhile; one already under
        // way (a send, a Retry or a compaction awaiting credentials, its
        // helper or its session) gets there first, so its run is paused with
        // the rest instead of starting after the pause.
        let wasPreparing = installPreparing
        installPreparing = true
        defer { installPreparing = wasPreparing }
        let deadline = ProcessInfo.processInfo.systemUptime + settleTimeout
        // A display's loading counts only for the reader's chats: a background
        // request (a title, the mini model) is loading for as long as its
        // model answers, and ends with its helper like any run.
        let readers = { [unowned self] (id: String) -> Bool in record(id).map { !$0.isUtilityChat } ?? true }
        func underWay() -> Bool {
            if !hostStarts.isEmpty { return true }
            if displays.values.contains(where: { ($0.loading || $0.resuming) && readers($0.id) }) { return true }
            // Any session being opened, a background request's too: once
            // open it would start a helper the pause no longer stops.
            return !sessionOpenings.isEmpty || !sessionOpenCallers.isEmpty
        }
        while underWay() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw HostError.failure("A message is still being sent. Try the update again in a moment.")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await moveUnsavedSideDraftsToParents()
        try await flushDrafts()
        // Their exit is the pause, not a crash: the chats read paused, not
        // "outcome uncertain" (`WorkspaceHosts` onLoss).
        // Title requests under way, named before their helpers stop: one
        // that unwinds during the stop leaves the table before it ends.
        let titled = Array(titleGenerationTasks.keys)
        for host in hosts.values { pausingHosts.insert(ObjectIdentifier(host)) }
        await stopHostsAndWait()
        // Every exit has been seen by now; a helper that had no process to
        // stop must not have its next, real, loss read as a pause.
        pausingHosts.removeAll()
        // Background requests (titles) lost their helpers with the rest; as
        // at Quit they end here, and a title cut off is asked for again on
        // the chat's next send. The pause is done once nothing is left.
        let unwinding = Array(titleGenerationTasks.keys)
        for task in titleGenerationTasks.values { task.cancel() }
        let settleBy = ProcessInfo.processInfo.systemUptime + 5
        while hasActiveWork, ProcessInfo.processInfo.systemUptime < settleBy { try? await Task.sleep(for: .milliseconds(20)) }
        await markTitlesInterrupted(Array(Set(titled + unwinding)))
        await flushRunHolds()
    }

    /// Title requests the pause cut off read as interrupted when the app
    /// closed, whatever their task wrote on the way out: that is the one
    /// state the chat's next send asks again from (`resumeInterruptedTitle`).
    func markTitlesInterrupted(_ sources: [String]) async {
        for sourceID in sources {
            guard let source = record(sourceID), source.titleWasGenerated != true, source.titleWasEdited != true,
                  let taskID = source.titleTaskSessionID, var task = chats.first(where: { $0.id == taskID }),
                  task.backgroundTask == BackgroundRequestKind.title.raw, task.backgroundTaskOutcome != "completed" else { continue }
            task.backgroundTaskNotice = BackgroundRequests.interruptedNotice; task.backgroundTaskOutcome = "interrupted"
            try? await store?.put(task, kind: "chat", id: taskID)
            if let index = chats.firstIndex(where: { $0.id == taskID }) {
                chats[index].backgroundTaskNotice = task.backgroundTaskNotice; chats[index].backgroundTaskOutcome = task.backgroundTaskOutcome
            }
        }
    }

    /// A helper stopped by `pauseRunsForUpdate` has gone: each of its chats
    /// that had work is paused, as its journal now says, and offers Resume.
    func settlePausedForUpdate(_ view: SessionDisplay) {
        guard view.hasWork || view.runState == .interrupted, view.runState != .error else { return }
        view.beginTranscriptBatch(); defer { view.endTranscriptBatch() }
        view.settleInterruptedRows()
        view.runState = .paused; view.runStatus = "cancelled"; view.queueCount = 0
        view.queuePaused = true; view.continuable = nil
        view.notice = "Paused for the update. Resume when you’re ready."
        reconcileRunHold(view.id)
    }
}
