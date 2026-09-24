import Foundation

// The packaged helper: one process per project, one session per chat, and
// the bookkeeping that keeps two callers from starting either twice.

extension WorkspaceModel {
    func host(for workspace: WorkspaceRecord) async throws -> HostSupervisor {
        try Task.checkCancellation()
        guard !accountingStopped else { throw CancellationError() }
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
        host.onEvent = { [weak self] frame in
            guard let id = frame["sessionId"]?.string else { return }
            if frame["type"]?.string == "session.changed" { self?.refresh(id) }
            if frame["type"]?.string == "session.unloaded" { self?.opened.remove(id); self?.displays[id]?.notice = "Saved history · Host runtime unloaded"; self?.displays[id]?.captureAvailable = false }
        }
        host.onLoss = { [weak self, weak host] in
            guard let self, let host, self.hosts[workspace.id] === host else { return }
            // A helper stopped for being idle has not crashed: nothing was
            // running, and what the footers show is still what the chats hold.
            let retired = self.retiringHosts.remove(ObjectIdentifier(host)) != nil
            self.boundHostConnections.removeValue(forKey: workspace.id)
            self.liveActivity.disconnect(workspace.id)
            self.discardLostSides(workspaceID: workspace.id)
            for chat in self.chats where chat.workspaceID == workspace.id {
                self.opened.remove(chat.id); self.displays[chat.id]?.captureAvailable = false
                self.displays[chat.id]?.lastSequence = -1
                if !retired { self.displays[chat.id]?.observeContext([:],baseline:true) }
                self.displays[chat.id]?.footer.pendingContextSubmission=nil
                // A message the helper took but never showed is not drawn as
                // sent any more; its record says the outcome is uncertain. A
                // send still waiting for its answer settles that itself.
                if !retired, let view = self.displays[chat.id], !view.loading { view.dropAllSending() }
                if let view = self.displays[chat.id], view.hasWork, view.state != "error" { view.state = "interrupted"; view.runStatus = "interrupted"; view.queueCount = 0; view.uncertain = true; view.notice = "Host interrupted. Outcome uncertain. No command was replayed."; view.settleInterruptedRows() }
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
        retiringHosts.remove(ObjectIdentifier(host))
        try Task.checkCancellation()
        let connection = host.connectionID
        // "cwd" remains for hosts that predate multi-folder roots; "roots" lists every trusted folder, primary first.
        _ = try await host.request("workspace.open", params: ["cwd": .string(workspace.path), "roots": .array(workspace.roots.map(WireValue.string)), "directory": .string(state.appendingPathComponent("Sessions").path), "captureProtocol": .number(1), "resources": try await resourceSettings(workspaceID: workspace.id), "mcp": configuration.mcp[workspace.id] ?? .object(["servers": .object([:])])])
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
        guard prewarmsHelpers, !accountingStopped, !installPreparing, page == .chats, !prewarming.contains(id),
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
    func open(_ item: ChatRecord, automaticContext: Bool = false) async throws -> HostSupervisor {
        try Task.checkCancellation()
        guard !accountingStopped else { throw CancellationError() }
        if automaticContext { try requireAutomaticContext(item.id) }
        guard let store else { throw StoreError.unavailable }
        guard !workspaceChangesInFlight.contains(item.workspaceID) else { throw HostError.failure("Wait for this project's folder changes to finish before starting work.") }
        let lease = try connectionLease(for: item)
        guard let profile = profiles.first(where: { $0.id == item.profileID }) else { throw connectionUnavailable }
        try LiteLLMConfiguration.requireSupportedAPI(profile.api)
        if sessionOpenings[item.id] == nil, opened.contains(item.id), let host = hosts[item.workspaceID], host.isReady { idleTasks[item.workspaceID]?.cancel(); return host }
        if isEphemeral(item.id) { throw HostError.failure("This unkept side lost its host. Open a new side from the parent; nothing was replayed.") }
        // Include credential/journal reads before the shared helper operation:
        // a connection switch cannot overtake an automatic context cold open.
        sessionOpenCallers[item.id, default: 0] += 1
        defer {
            if sessionOpenCallers[item.id, default: 0] <= 1 { sessionOpenCallers.removeValue(forKey: item.id) }
            else { sessionOpenCallers[item.id, default: 0] -= 1 }
        }
        try await materializeChat(item.id)
        guard !item.imported, let workspace = workspace(for: item.workspaceID), workspace.trusted else { throw HostError.failure("This chat needs its saved profile and trusted project. Imported originals cannot be written.") }
        // The project's helper starts while the credential, handoff and cost
        // reads below run: starting it (spawn, handshake, workspace.open)
        // takes none of them. The credential first goes out with
        // session.open, after it and the connection lease are checked.
        let starting = Task { try await self.host(for: workspace) }
        var used = false
        defer {
            // An open that stopped before it used the helper leaves it to idle
            // out, as a helper started by typing does.
            if !used { Task { if !self.accountingStopped, let host = try? await starting.value { self.scheduleIdle(workspaceID: item.workspaceID, host: host) } } }
        }
        let credential = try await credentials(for: profile)
        // A read already dispatched to Keychain may finish after shutdown.
        // It must not open a session once terminal teardown has begun.
        try Task.checkCancellation()
        guard !accountingStopped else { throw CancellationError() }
        try requireConnection(lease)
        if automaticContext { try requireAutomaticContext(item.id) }
        let key = credential["apiKey"]?.string ?? ""
        do { if key.isEmpty { throw HostError.failure("Save an API key in Keychain for this profile") } }
        catch let error as HostError { throw error }
        catch { throw HostError.failure("The profile key is unavailable or Keychain access is locked. Review this profile in Settings.") }
        // What the session opens with, read while the helper starts.
        func sessionParams() async throws -> [String: WireValue] {
            var wire = profile.wire.object ?? [:]
            if let headers = credential["headers"] { wire["headers"] = headers }
            var params: [String: WireValue] = ["profile": .object(wire), "apiKey": .string(key), "toolMode": .string(item.toolMode)]
            if let handoff = try await store.get(WireValue.self, kind: "handoff", id: item.id) { params["handoff"] = handoff }
            // The chat's cost limit, which the helper checks before every model request.
            params.merge(await costLimitParams(for: item)) { _, limit in limit }
            if item.connectionTest == true || workspace.isScratch { params["connectionTest"] = .bool(true) }
            if item.backgroundTask == "session-title" { params["backgroundTask"] = .string("session-title") }
            if let path = item.path { params["path"] = .string(path) }
            // The capture mode rides on the open (the helper echoes it); a
            // helper that does not echo it is sent `debug.mode` after.
            let preference = try await capturePreference(sessionID: item.id)
            params["captureMode"] = .string(preference.mode)
            return params
        }
        var prepared: [String: WireValue]?
        if sessionOpenings[item.id] == nil, !opened.contains(item.id) { prepared = try await sessionParams() }
        let host = try await starting.value
        used = true
        defer { if automaticContext { scheduleIdle(workspaceID: item.workspaceID, host: host) } }
        try Task.checkCancellation()
        guard !accountingStopped else { throw CancellationError() }
        if automaticContext {
            do { try requireAutomaticContext(item.id) }
            catch { scheduleIdle(workspaceID: item.workspaceID, host: host); throw error }
        }
        if let pending = sessionOpenings[item.id] {
            try await pending.task.value
        } else if !opened.contains(item.id) {
            let params: [String: WireValue]
            if let prepared { params = prepared } else { params = try await sessionParams() }
            if automaticContext { try requireAutomaticContext(item.id) }
            // Reading the parameters may have yielded. Recheck immediately
            // before installing the shared operation, without another await.
            if let pending = sessionOpenings[item.id] {
                try await pending.task.value
            } else if !opened.contains(item.id) {
                let token = UUID()
                let task = Task { [self] in
                    try Task.checkCancellation()
                    try await withConnectionOpen(item, lease: lease, host: host) {
                        let initial = try await host.request("session.open", sessionID: item.id, params: params)
                        // Previewing a fresh chat allocates a native journal too. Persist
                        // its path before an idle unload, even when no message is sent.
                        if let path = initial.object?["path"]?.string, let index = chats.firstIndex(where: { $0.id == item.id }) {
                            chats[index].path = path
                            // Always retry this durable write on a later open after a
                            // storage failure, even though the in-memory path is known.
                            // The saved record decides, not the one in memory: a
                            // reopened chat's record usually holds the path already,
                            // and reading it costs far less than a durable rewrite.
                            if try await store.get(ChatRecord.self, kind: "chat", id: item.id)?.path != path,
                               let current = chats.first(where: { $0.id == item.id }) {
                                try await store.put(current, kind: "chat", id: item.id)
                            }
                        }
                        observeAssistantOutputs(sessionID: item.id, snapshot: initial.object ?? [:])
                        observeSessionCompletion(sessionID: item.id, snapshot: initial.object ?? [:], baseline: true)
                        displays[item.id]?.observeCompaction(initial.object ?? [:], baseline: true)
                        displays[item.id]?.observeContext(initial.object ?? [:], baseline: true)
                        let mode = params["captureMode"]?.string ?? "memory"
                        if initial.object?["captureMode"]?.string != mode {
                            _ = try await host.request("debug.mode", sessionID: item.id, params: ["mode": .string(mode)])
                        }
                        opened.insert(item.id)
                        displays[item.id]?.captureMode = mode; displays[item.id]?.captureAvailable = true
                        displays[item.id]?.lastSequence = -1
                    }
                }
                sessionOpenings[item.id] = (token, task)
                defer { if sessionOpenings[item.id]?.token == token { sessionOpenings.removeValue(forKey: item.id) } }
                try await task.value
            }
        }
        try requireConnection(lease)
        return host
    }
}
