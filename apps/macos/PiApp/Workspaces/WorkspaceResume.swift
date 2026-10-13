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
// An update with chats running asks once, then pauses them as Quit does
// (their helpers stop the way Stop does and are waited for, and their holds
// are saved) before Sparkle checks. Whether or not an update follows, the
// paused chats offer Resume.

extension WorkspaceModel {
    /// The pending-intent key of a Resume, matching the helper's receipt.
    nonisolated static let resumeIntentPrefix = "continue:"

    /// Resume in the focused chat (the Conversation menu), or `sessionID`'s
    /// (its paused row, its queue panel). One at a time per chat: a press
    /// while one is on its way does nothing, and the helper refuses a second
    /// run besides (`session_busy`), so a double click, or Resume racing a
    /// Send, never starts two runs.
    func resumeRun(sessionID: String? = nil) {
        guard !installPreparing, let id = sessionID ?? focusedSessionID ?? selectedID, let item = record(id), !item.isBackgroundTask,
              let view = displays[id] else { return }
        guard !item.isArchived else { view.notice = Self.archivedNotice; return }
        guard !view.resuming, !view.busy, !view.loading else { return }
        // The run goes on in the latest version, and the transcript returns to it, as for a send.
        latestVersion(sessionID: id)
        view.resuming = true
        let commandID = UUID().uuidString, params = turnOverrides(for: item)
        let durable = !isEphemeral(item.id)
        resumeSteps?("accepted")
        Task {
            defer { view.resuming = false; updateHostActivity(workspaceID: item.workspaceID) }
            var recorded = false
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
                view.acceptedCommands.insert(commandID)
                if reply.object?["continued"]?.bool == true || reply.object?["resumedQueue"]?.bool == true { noteChatActivity(item.id) }
                if durable { try? await store?.acknowledgeCommand(sessionID: item.id, commandID: commandID); pendingIntentsChanged(item.id) }
                // What comes next is what the reader wants to see.
                followSubmittedTurn(item.id)
                resumeSteps?("answered")
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
                    view.continuable = false
                    view.notice = "There is nothing to resume. Send a new message to go on."
                default:
                    self.error = error.localizedDescription
                }
                resumeSteps?("failed")
            }
            refresh(item.id)
        }
    }

    /// What a Resume button does in `view`'s chat: goes on with the stopped
    /// run when there is one; otherwise sends the paused follow-ups.
    func resumeOrSendQueued(_ view: SessionDisplay) {
        // A Resume on its way holds the chat: a second press sends nothing,
        // not even the follow-ups, which would overtake the continuation.
        guard !view.resuming else { return }
        // Unknown (`continuable` nil) goes to the helper too: from an answered
        // chat its continue sends what waits, as Resume Follow-ups does.
        if view.offersResume { resumeRun(sessionID: view.id) }
        else { action("queue.resume", sessionID: view.id) }
    }

    /// Running chats, for the update's question: those with a run under way.
    var runningChatCount: Int { displays.values.filter { $0.busy }.count }

    /// Pauses every chat's work before an update, as Quit does: what was
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
        for host in hosts.values { pausingHosts.insert(ObjectIdentifier(host)) }
        await stopHostsAndWait()
        // Every exit has been seen by now; a helper that had no process to
        // stop must not have its next, real, loss read as a pause.
        pausingHosts.removeAll()
        await flushRunHolds()
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
