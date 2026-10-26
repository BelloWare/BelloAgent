import Foundation

// The packaged helper: one process per project, one session per chat, and
// the bookkeeping that keeps two callers from starting either twice.

extension WorkspaceModel {
    /// Runtime publication belongs to the connection that acknowledged it,
    /// even if the same supervisor has already started a replacement helper.
    func requireHost(_ host: HostSupervisor, connection: UUID?, workspaceID: String) throws {
        guard !isShutDown, let connection, host.isReady, host.connectionID == connection,
              hosts[workspaceID] === host else { throw HostError.failure("The project host changed while opening this chat. Open it again to continue.") }
    }

    func host(for workspace: WorkspaceRecord) async throws -> HostSupervisor {
        try Task.checkCancellation()
        guard !isShutDown else { throw CancellationError() }
        guard !workspaceChangesInFlight.contains(workspace.id) else { throw HostError.failure("Wait for this project's folder changes to finish before starting work.") }
        idleTasks[workspace.id]?.cancel()
        // The protocol handshake is ready before workspace.open has installed
        // its roots/resources. Every caller shares that complete bootstrap.
        if let pending = hostStarts[workspace.id] { return try await pending.task.value }
        if let existing = hosts[workspace.id], existing.isReady,
           let connection = existing.connectionID, boundHostConnections[workspace.id] == connection { return existing }
        let token = UUID()
        let task = Task { try await startHost(for: workspace) }
        hostStarts[workspace.id] = (token, task)
        defer { if hostStarts[workspace.id]?.token == token { hostStarts.removeValue(forKey: workspace.id) } }
        return try await task.value
    }
    private func startHost(for workspace: WorkspaceRecord) async throws -> HostSupervisor {
        try Task.checkCancellation()
        try await ensureConfiguration()
        try Task.checkCancellation()
        guard !workspaceChangesInFlight.contains(workspace.id) else { throw HostError.failure("Wait for this project's folder changes to finish before starting work.") }
        if workspace.isScratch {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: workspace.path, isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else {
            guard configuration.workspaces.contains(workspace), workspace.trusted else { throw HostError.failure("Trust this project in the configuration vault before starting tools.") }
            try requireProjectFolders(workspace)
        }
        // Any number of projects and chats may be active at once; idle helpers
        // leave on their own after the grace period.
        let host = hosts[workspace.id] ?? HostSupervisor(); hosts[workspace.id] = host
        host.onEvent = { [weak self, weak host] frame in
            guard let self, let host, self.hosts[workspace.id] === host, let id = frame["sessionId"]?.string else { return }
            if frame["type"]?.string == "session.cost", self.record(id)?.workspaceID == workspace.id,
               self.record(id)?.isSubagent == true, let cost = frame["payload"] {
                self.observeCost(["cost":cost],sessionID:id)
            }
            if frame["type"]?.string == "session.changed" { self.refresh(id) }
            if frame["type"]?.string == "session.unloaded" {
                self.sessionOpenings[id]?.task.cancel()
                self.helperSessionDidUnload(id); self.displays[id]?.notice = "Saved history · Host runtime unloaded"; self.displays[id]?.captureAvailable = false
            }
        }
        host.onLoss = { [weak self, weak host] in
            guard let self, let host, self.hosts[workspace.id] === host else { return }
            // A helper stopped for being idle has not crashed: nothing was
            // running, and what the footers show is still what the chats hold.
            let retired = self.retiringHosts.remove(ObjectIdentifier(host)) != nil
            let paused = self.pausingHosts.remove(ObjectIdentifier(host)) != nil
            self.boundHostConnections.removeValue(forKey: workspace.id)
            self.interruptSubagents(workspaceID: workspace.id)
            self.liveActivity.disconnect(workspace.id)
            let configured = self.sessionConfigurations.filter { $0.value.lease.workspaceID == workspace.id }.map(\.key)
            for id in Set(configured).union(self.chats.filter { $0.workspaceID == workspace.id }.map(\.id)) { self.retireSessionConfiguration(id) }
            self.discardLostSides(workspaceID: workspace.id)
            for chat in self.chats where chat.workspaceID == workspace.id {
                self.retireBudgetRead(chat.id)
                self.opened.remove(chat.id); self.budgetDependencySessions.remove(chat.id); self.releasedHelperSessions.remove(chat.id); self.displays[chat.id]?.captureAvailable = false
                self.displays[chat.id]?.lastSequence = -1
                if !retired, let view = self.displays[chat.id] {
                    view.observeContext([:],baseline:true)
                    // The reading it last counted stands again, and nothing
                    // reopens the helper to count it.
                    self.adoptContextReading(view, item: chat)
                }
                self.displays[chat.id]?.footer.pendingContextSubmission=nil
                // A message the helper took but never showed is not drawn as
                // sent any more; its record says the outcome is uncertain. A
                // send still waiting for its answer settles that itself.
                if !retired, let view = self.displays[chat.id], !view.loading { view.dropAllSending() }
                if paused, let view = self.displays[chat.id] { self.settlePausedForUpdate(view); continue }
                if let view = self.displays[chat.id], view.hasWork, view.runState != .error { view.runState = .interrupted; view.runStatus = "interrupted"; view.queueCount = 0; view.uncertain = true; view.continuable = nil; view.notice = "Host interrupted. Outcome uncertain. No command was replayed."; view.settleInterruptedRows() }
            }
        }
        let state = root.appendingPathComponent("Workspaces/\(workspace.id)", isDirectory: true)
        let archive = traces, workspaceID = workspace.id
        try await host.connect(cwd: URL(fileURLWithPath: workspace.path), state: state, runtime: configuration.runtime, capture: { [weak self] packet in
            try await archive.accept(packet, workspace: workspaceID)
            // A final capture can arrive after the last session-status event.
            // Refresh accounting from its committed metadata, without waiting
            // for the user to focus this conversation again.
            // ACK is gated only on the durable archive, never on a busy UI
            // actor. Body/event chunks do not affect presentation accounting.
            guard let type = packet["type"]?.string, ["begin", "metadata", "finish", "links", "interrupted"].contains(type) else { return }
            Task { @MainActor [weak self] in await self?.captureDidPersist(packet, workspaceID: workspaceID) }
        })
        // The previous helper has exited by now, or never had a process to
        // exit: a stop that marked it retired no longer describes this one.
        retiringHosts.remove(ObjectIdentifier(host)); pausingHosts.remove(ObjectIdentifier(host))
        try Task.checkCancellation()
        let connection = host.connectionID
        // "cwd" remains for hosts that predate multi-folder roots; "roots" lists every trusted folder, primary first.
        let retry = configuration.retrySettings
        _ = try await host.request("workspace.open", params: ["cwd": .string(workspace.path), "roots": .array(workspace.roots.map(WireValue.string)), "directory": .string(state.appendingPathComponent("Sessions").path), "captureProtocol": .number(1), "resources": try await resourceSettings(workspaceID: workspace.id), "mcp": configuration.mcp[workspace.id] ?? .object(["servers": .object([:])]), "retry": retry.wire])
        // A change saved while the helper was opening missed both the open and the broadcast to ready helpers.
        if configuration.retrySettings != retry { _ = try await host.request("retry.configure", params: configuration.retrySettings.wire.object ?? [:]) }
        if PerformanceProbe.shared.enabled { try await host.calibrateClock() }
        try Task.checkCancellation()
        guard host.isReady, hosts[workspace.id] === host, let connection, host.connectionID == connection else {
            throw HostError.failure("The project host stopped during startup. Try again.")
        }
        boundHostConnections[workspace.id] = connection
        return host
    }
    func isSessionOpening(_ id: String) -> Bool { sessionOpenCallers[id, default: 0] > 0 }
    /// The reader is writing in a chat, or has put the cursor in its
    /// composer: its project's helper, and the chat's session on it, start
    /// now if they are not running, so Return does not wait for either.
    ///
    /// Only what a send would open anyway is opened, and only when opening is
    /// harmless: a session that would repair interrupted work waits for an
    /// explicit send (as the automatic context preview does), and a chat that
    /// has never been sent — a new chat, a draft side — gets its project's
    /// helper and nothing else, since nothing is written for it before its
    /// first message. Typing counts as using the helper: the idle stop of a
    /// helper that is up starts over.
    func prewarm(_ id: String) {
        guard prewarmsHelpers, !isShutDown, !installPreparing, page == .chats, !prewarming.contains(id),
              let item = record(id), let view = displays[id], !view.loading, !view.uncertain, view.recovered.isEmpty,
              view.contextSelectionReady || side(id)?.pending == true,
              !item.imported, !item.isArchived, !item.isBackgroundTask, !workspaceChangesInFlight.contains(item.workspaceID),
              let workspace = workspace(for: item.workspaceID), workspace.trusted || workspace.isScratch,
              let profile = profiles.first(where: { $0.id == item.profileID }), profile.api == LiteLLMConfiguration.supportedAPI else { return }
        let unsent = pendingChatIDs.contains(id) || side(id)?.pending == true
        // An unkept side lives in its helper: there is nothing to start for it.
        if isEphemeral(id), !unsent { return }
        if let host = hosts[item.workspaceID], host.isReady, unsent || opened.contains(id) {
            if idleTasks[item.workspaceID] != nil { scheduleIdle(workspaceID: item.workspaceID, host: host) }
            return
        }
        prewarming.insert(id)
        Task {
            defer { prewarming.remove(id) }
            do {
                let host: HostSupervisor
                if unsent { host = try await self.host(for: workspace) }
                else {
                    if let path = item.path, !(try await history.allowsAutomaticContext(path: path, id: id)) { return }
                    if try await store?.get(WireValue.self, kind: "handoff", id: id) != nil { return }
                    // The reads above yield: the chat may have moved on meanwhile.
                    guard let current = record(id), current.workspaceID == item.workspaceID, current.profileID == item.profileID,
                          displays[id] === view, !view.loading, !view.uncertain, view.recovered.isEmpty else { return }
                    host = try await open(current)
                }
                scheduleIdle(workspaceID: item.workspaceID, host: host)
            } catch {
                // Nothing was asked for: a send reports what went wrong, typing does not.
            }
        }
    }
    /// Unloads the helper session of a chat whose display was let go of.
    /// Without it the helper kept every chat visited loaded (its messages,
    /// pages and tool state) for as long as it ran, which over a day of use
    /// only grew. The journal stays, and the next open reads it back. The
    /// helper refuses a session with work; that one stays loaded, and the
    /// next `session.open` is answered by it. A chat an Inspector window is
    /// open on keeps its session, which that window reads.
    func releaseHelperSession(_ id: String) {
        releasedHelperSessions.insert(id)
        releaseUnusedBudgetSessions()
    }
    /// Only currently loaded/opening sides pin a writer. Pane placement and
    /// fork provenance never do. The helper remains the final busy authority.
    func releaseUnusedBudgetSessions() {
        guard !isShutDown, !budgetDependencySessions.isEmpty || !releasedHelperSessions.isEmpty else { return }
        var pinned = Set<String>()
        for id in opened.union(budgetOpenCallers.keys) {
            guard var item = record(id) else { continue }
            var seen: Set<String> = [id]
            while let parentID = sideBudgetParent(item), seen.insert(parentID).inserted,
                  let parent = record(parentID), parent.workspaceID == item.workspaceID {
                pinned.insert(parentID); item = parent
            }
        }
        for id in budgetDependencySessions.union(releasedHelperSessions) {
            guard budgetOpenCallers[id] == nil, sessionOpenings[id] == nil, sessionClosings[id] == nil else { continue }
            guard opened.contains(id) else {
                budgetDependencySessions.remove(id); releasedHelperSessions.remove(id); continue
            }
            guard !pinned.contains(id), !isEphemeral(id),
                  (releasedHelperSessions.contains(id) || displays[id] == nil),
                  SessionInspectorWindows.shared.controller(sessionID: id) == nil,
                  let item = record(id), !deletingFamilies.contains(id),
                  !budgetOwnerChanges.contains(id), connectionSwitches[id] == nil, !workspaceChangesInFlight.contains(item.workspaceID),
                  let host = hosts[item.workspaceID], host.isReady else { continue }
            let token = UUID(), connection = host.connectionID
            let task = Task { [weak self] in
                var unloaded = false
                do {
                    _ = try await host.request("session.close", sessionID: id)
                    if let self, self.hosts[item.workspaceID] === host, host.connectionID == connection {
                        self.retireBudgetRead(id)
                        self.opened.remove(id); self.budgetDependencySessions.remove(id); self.releasedHelperSessions.remove(id)
                        self.retireSessionConfiguration(id)
                        unloaded = true
                    }
                } catch { /* A busy runtime remains loaded, including its tool mode. */ }
                if self?.sessionClosings[id]?.token == token { self?.sessionClosings.removeValue(forKey: id) }
                // Release deepest ancestors first. A rejected close never spins.
                if unloaded { self?.releaseUnusedBudgetSessions() }
            }
            sessionClosings[id] = (token, task)
        }
    }
    func helperSessionDidUnload(_ id: String) {
        retireBudgetRead(id)
        if record(id) == nil { budgetStates.removeValue(forKey:id) }
        opened.remove(id); budgetDependencySessions.remove(id); releasedHelperSessions.remove(id)
        retireSessionConfiguration(id)
        releaseUnusedBudgetSessions()
    }
    func open(_ item: ChatRecord, automaticContext: Bool = false, budgetDependency: Bool = false) async throws -> HostSupervisor {
        guard !isOriginalSubagentReader(item.id) else { throw HostError.failure("This original sub-agent is open read-only from a fork.") }
        if !budgetDependency { releasedHelperSessions.remove(item.id) }
        var accepted = false
        // Pin before the first await, including metadata/credential reads and
        // waiting for an earlier close. A failed open releases its ancestors.
        budgetOpenCallers[item.id, default: 0] += 1
        defer {
            // A successful direct open owns its runtime even if it shared an
            // ancestor open already in flight. Failed callers claim nothing.
            if accepted, !budgetDependency { budgetDependencySessions.remove(item.id) }
            if budgetOpenCallers[item.id, default: 0] <= 1 { budgetOpenCallers.removeValue(forKey: item.id) }
            else { budgetOpenCallers[item.id, default: 0] -= 1 }
            releaseUnusedBudgetSessions()
        }
        guard !deletingFamilies.contains(item.delegation?.budgetOwnerSessionID ?? item.id) else { throw HostError.failure("This chat is being deleted.") }
        if try await store?.get(String.self, kind: "session-deleted", id: item.delegation?.budgetOwnerSessionID ?? item.id) != nil { throw HostError.failure("This chat is being deleted.") }
        if let issue = item.delegationIssue { throw HostError.failure(issue) }
        displays[item.id]?.isManagedSubagent = item.isSubagent
        // A close sent when the chat's display was let go of lands first, so
        // this open is not answered by the session being unloaded; so does a
        // move to another connection, so it is not opened on the old one.
        while true {
            if let closing = sessionClosings[item.id] { await closing.task.value }
            else if let change = connectionSwitches[item.id] { await change.task.value }
            else { break }
        }
        if budgetDependency, !opened.contains(item.id), displays[item.id] == nil {
            budgetDependencySessions.insert(item.id)
        }
        // A caller that read the chat before it moved may already have
        // written something naming the old connection (a fork's or a side's
        // record): it is refused, and opens again from the chat as it is.
        if let current = record(item.id), current.profileID != item.profileID || current.workspaceID != item.workspaceID { throw connectionChanged }
        try Task.checkCancellation()
        guard !isShutDown else { throw CancellationError() }
        if automaticContext { try requireAutomaticContext(item.id) }
        guard let store else { throw StoreError.unavailable }
        guard !workspaceChangesInFlight.contains(item.workspaceID) else { throw HostError.failure("Wait for this project's folder changes to finish before starting work.") }
        let lease = try connectionLease(for: item)
        guard let profile = profiles.first(where: { $0.id == item.profileID }) else { throw connectionUnavailable }
        try LiteLLMConfiguration.requireSupportedAPI(profile.api)
        try await retainBudgetAncestors(for: item)
        // Open authoritative budget writers before a kept side after relaunch.
        // Parent selection and model context are unchanged.
        if let parentID = sideBudgetParent(item), let parent = record(parentID), parent.id != item.id {
            let owner = budgetOwner(for: item)
            guard parent.workspaceID == item.workspaceID, owner.id != item.id,
                  sideBudgetParent(owner).flatMap({ record($0) }) == nil, !owner.isSubagent else { throw HostError.failure("The side’s budget ancestry is inconsistent.") }
            _ = try await open(parent, automaticContext: false, budgetDependency: true)
        }
        if sessionOpenings[item.id] == nil, opened.contains(item.id), let host = hosts[item.workspaceID], host.isReady {
            let connection = host.connectionID
            if !item.isSubagent { try await reconcileSessionProfile(item, host: host) }
            try requireHost(host, connection: connection, workspaceID: item.workspaceID)
            idleTasks[item.workspaceID]?.cancel(); accepted = true; return host
        }
        if isEphemeral(item.id) { throw HostError.failure("This unkept side lost its host. Open a new side from the parent; nothing was replayed.") }
        // A registered chat opens only the journal it is registered with. A
        // record read before registration names none, and the helper would
        // start another file in its place: such a caller is refused.
        if let registered = chatRecord(item.id)?.path,
           !Self.sameFile(registered, item.path ?? root.appendingPathComponent("Workspaces/\(item.workspaceID)/Sessions/\(item.id).jsonl").path) { throw journalChanged }
        // Preserve the opening contract used by connection switching. A caller
        // waiting behind a switch pins its budget but has not begun this open.
        sessionOpenCallers[item.id, default: 0] += 1
        defer {
            if sessionOpenCallers[item.id, default: 0] <= 1 { sessionOpenCallers.removeValue(forKey: item.id) }
            else { sessionOpenCallers[item.id, default: 0] -= 1 }
        }
        try await materializeChat(item.id)
        guard !item.imported, let workspace = workspace(for: item.workspaceID), workspace.trusted else { throw HostError.failure("This chat needs its saved profile and trusted project. Imported originals cannot be written.") }
        let credential = try await credentials(for: profile)
        // A read already dispatched to Keychain may finish after shutdown.
        // It must not create a new helper once terminal teardown has begun.
        try Task.checkCancellation()
        guard !isShutDown else { throw CancellationError() }
        try requireConnection(lease)
        if automaticContext { try requireAutomaticContext(item.id) }
        let key = credential["apiKey"]?.string ?? ""
        if key.isEmpty { throw HostError.failure("Save an API key in Keychain for this profile") }
        let host = try await host(for: workspace), connection = host.connectionID
        defer { if automaticContext { scheduleIdle(workspaceID: item.workspaceID, host: host) } }
        try Task.checkCancellation()
        guard !isShutDown else { throw CancellationError() }
        if automaticContext {
            do { try requireAutomaticContext(item.id) }
            catch { scheduleIdle(workspaceID: item.workspaceID, host: host); throw error }
        }
        if let pending = sessionOpenings[item.id] {
            try await pending.task.value
        } else if !opened.contains(item.id) {
            var wire = profile.wire.object ?? [:]
            if let headers = credential["headers"] { wire["headers"] = headers }
            if item.isSubagent, let model = item.model { wire["modelId"] = .string(model) }
            var params: [String: WireValue] = ["profile": .object(wire), "apiKey": .string(key), "toolMode": .string(item.toolMode)]
            if let grants = subagentModels(for: item) { params["subagentModels"] = grants }
            if let handoff = try await store.get(WireValue.self, kind: "handoff", id: item.id) { params["handoff"] = handoff }
            // The chat's cost limit, which the helper checks before every model request.
            params.merge(await costLimitParams(for: item)) { _, limit in limit }
            if automaticContext { try requireAutomaticContext(item.id) }
            if item.connectionTest == true || workspace.isScratch { params["connectionTest"] = .bool(true) }
            // A background request opens as the helper's utility request of its
            // kind: its own short instructions, no tools, no project context.
            if let task = item.backgroundTask, [BackgroundRequestKind.title, .suggestions, .webhook, .brief].contains(BackgroundRequestKind(task)) { params["backgroundTask"] = .string(task) }
            if let path = item.path { params["path"] = .string(path) }
            // Loading a retained handoff above yields too. Recheck immediately
            // before installing the shared operation, without another await.
            try requireHost(host, connection: connection, workspaceID: item.workspaceID)
            if let pending = sessionOpenings[item.id] {
                try await pending.task.value
            } else if !opened.contains(item.id) {
                let token = UUID()
                let task = Task { [self] in
                    try Task.checkCancellation()
                    try requireHost(host, connection: connection, workspaceID: item.workspaceID)
                    try await withConnectionOpen(item, lease: lease, host: host) {
                        try await reconcileJournal(item.id, host: host, profile: profile)
                        try requireHost(host, connection: connection, workspaceID: item.workspaceID)
                        let initial = try await host.request("session.open", sessionID: item.id, params: params)
                        try requireHost(host, connection: connection, workspaceID: item.workspaceID)
                        // A prior open may have created this runtime before
                        // capture/path setup failed. session.open then returns
                        // that same runtime without applying its new arguments.
                        if sessionProfileRevisions[item.id]?.connection != host.connectionID {
                            sessionProfileRevisions[item.id] = (host.connectionID, profile.revision)
                        }
                        budgetState(for:item.id).limitSent = costLimit(for:item.id)
                        observeCost(initial.object ?? [:],sessionID:item.id)
                        // Previewing a fresh chat allocates a native journal too. Persist
                        // its path before an idle unload, even when no message is sent.
                        if let path = initial.object?["path"]?.string, let index = chats.firstIndex(where: { $0.id == item.id }) {
                            // Never another file in place of a registered journal:
                            // the runtime opened on it goes, and the open is refused.
                            if let registered = chats[index].path, !Self.sameFile(registered, path) {
                                if (try? await host.request("session.close", sessionID: item.id)) != nil, hosts[item.workspaceID] === host, host.connectionID == connection { helperSessionDidUnload(item.id) }
                                throw journalChanged
                            }
                            chats[index].path = path
                            // Always retry this durable write on a later open after a
                            // storage failure, even though the in-memory path is known.
                            try await store.put(chats[index], kind: "chat", id: item.id)
                        }
                        try requireHost(host, connection: connection, workspaceID: item.workspaceID)
                        if !item.isSubagent, initial.object?["subagentsRevision"] != nil { try await reconcileCapturedBudget(item, host: host) }
                        try requireHost(host, connection: connection, workspaceID: item.workspaceID)
                        observeAssistantOutputs(sessionID: item.id, snapshot: initial.object ?? [:])
                        observeSessionCompletion(sessionID: item.id, snapshot: initial.object ?? [:], baseline: true)
                        displays[item.id]?.observeCompaction(initial.object ?? [:])
                        displays[item.id]?.observeContext(initial.object ?? [:], baseline: true)
                        let preference = try await capturePreference(sessionID: item.id)
                        try requireHost(host, connection: connection, workspaceID: item.workspaceID)
                        // Managed readers inherit their owner's capture policy;
                        // opening one must never issue a child policy change.
                        if !item.isSubagent { _ = try await host.request("debug.mode", sessionID: item.id, params: ["mode": .string(preference.mode)]) }
                        // Recovery may have unloaded this reader after its open
                        // reply, while path/capture persistence yielded above.
                        try Task.checkCancellation()
                        try requireHost(host, connection: connection, workspaceID: item.workspaceID)
                        opened.insert(item.id)
                        // Recovery may have corrected the cost after the open
                        // response. Read just the authoritative numeric state.
                        if budgetDependency { refreshBudgetState(item.id) }
                        // Settings or this chat's override may have changed
                        // while its seed or opening acknowledgement was read.
                        if params["costLimit"] != costLimit(for: item.id).wire { await sendCostLimit(item.id) }
                        try requireHost(host, connection: connection, workspaceID: item.workspaceID)
                        displays[item.id]?.captureMode = item.isSubagent ? initial.object?["captureMode"]?.string ?? preference.mode : preference.mode
                        displays[item.id]?.captureAvailable = true
                        displays[item.id]?.lastSequence = -1
                        if !item.isSubagent { try await reconcileSessionProfile(item, host: host) }
                    }
                }
                sessionOpenings[item.id] = (token, task)
                defer { if sessionOpenings[item.id]?.token == token { sessionOpenings.removeValue(forKey: item.id) } }
                try await task.value
            }
        }
        try requireConnection(lease)
        try requireHost(host, connection: connection, workspaceID: item.workspaceID)
        accepted = true
        return host
    }
}
