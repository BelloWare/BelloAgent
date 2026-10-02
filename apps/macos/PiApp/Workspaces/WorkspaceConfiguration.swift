import AppKit
import os

extension WorkspaceModel {
    /// What an open or a send relies on: the connection, as long as it is
    /// not deleted, and the chat still on it, as long as it has not been
    /// moved to another (`connectionGenerations`).
    struct ConnectionLease {
        let profileID: String
        let deletionGeneration: UInt64
        let chatID: String
        let chatGeneration: UInt64
    }
    var connectionUnavailable: HostError {
        .rejected("connection_unavailable", "This chat's connection is unavailable. Restore it in Settings before continuing.")
    }
    var connectionChanged: HostError {
        .rejected("connection_changed", "This chat's connection changed while this was starting. Try again.")
    }
    func connectionLease(for item: ChatRecord) throws -> ConnectionLease {
        let lease = ConnectionLease(profileID: item.profileID, deletionGeneration: profileDeletionGenerations[item.profileID, default: 0],
                                    chatID: item.id, chatGeneration: connectionGenerations[item.id, default: 0])
        try requireConnection(lease)
        return lease
    }
    func requireConnection(_ lease: ConnectionLease) throws {
        guard !deletingProfiles.contains(lease.profileID),
              profileDeletionGenerations[lease.profileID, default: 0] == lease.deletionGeneration,
              profiles.contains(where: { $0.id == lease.profileID }) else { throw connectionUnavailable }
        // A chat moving to another connection, or moved since, is not on this one.
        guard connectionSwitches[lease.chatID] == nil, connectionGenerations[lease.chatID, default: 0] == lease.chatGeneration,
              record(lease.chatID).map({ $0.profileID == lease.profileID }) ?? true else { throw connectionChanged }
    }
    /// An open may acknowledge after deletion has already inspected the loaded
    /// sessions. Keep it tracked until its late runtime is actually closed.
    func withConnectionOpen(_ item: ChatRecord, lease: ConnectionLease, host: HostSupervisor,
                            operation: @MainActor () async throws -> Void) async throws {
        try requireConnection(lease)
        do {
            try await operation()
            try requireConnection(lease)
        } catch {
            do { try requireConnection(lease) } catch let gone {
                if host.isReady {
                    opened.insert(item.id)
                    do {
                        _ = try await host.request("turn.stop", sessionID: item.id)
                        _ = try await host.request("session.close", sessionID: item.id)
                        opened.remove(item.id)
                    } catch HostError.rejected(let code, _) where code == "session_missing" {
                        opened.remove(item.id)
                    } catch {
                        // A live busy runtime remains tracked; host loss has
                        // already cleared it and must not be undone here.
                        if !host.isReady, hosts[item.workspaceID] === host { opened.remove(item.id) }
                    }
                } else if hosts[item.workspaceID] === host { opened.remove(item.id) }
                throw gone
            }
            throw error
        }
    }
    func reloadConfiguration() async throws {
        let saved: VaultConfiguration
        do { saved = try await vault.load() }
        catch { configurationLoaded = false; throw error }
        applyConfiguration(saved)
        await finishConfiguration(saved)
    }
    /// What the window needs to draw: the projects and the connections. Launch
    /// publishes this as soon as the vault answers, alongside the chat list,
    /// so the sidebar's first frame already names the projects instead of
    /// listing every chat under a "Retained chats" placeholder.
    func applyConfiguration(_ saved: VaultConfiguration) {
        let costLimit = configuration.defaultChatCostLimit
        configuration = saved; configurationLoaded = true
        profiles = saved.profiles.map(\.profile); workspaces = saved.workspaces
        // The tabs come back once the projects they were opened in are known.
        tabs.restore()
        // ⌘P forgets a project gone or no longer trusted.
        quickOpenProjectsChanged()
        if saved.defaultChatCostLimit != costLimit { defaultCostLimitChanged() }
    }
    /// Hands the planner the reader's transcript choice and republishes every
    /// open chat, because a turn's fold is part of the plan rather than of a
    /// row's own state.
    ///
    /// The window calls this, not `applyConfiguration`: a model built without
    /// one — a fixture, a command test — must not change how every other
    /// fixture in the process plans its rows.
    func applyTranscriptDisplay() {
        guard TranscriptDisplay.mode != configuration.transcriptDisplay else { return }
        TranscriptDisplay.use(configuration.transcriptDisplay)
        for display in displays.values { display.publishTranscript() }
    }
    /// The rest, which nothing on screen waits for: a one-time migration of
    /// saved chat output limits, and opening the request archive with its
    /// retention sweep and retained billing.
    ///
    /// Local chat metadata is not the vault. Reporting a store failure here as
    /// "settings not loaded" disabled Save, Test Connection and the model
    /// catalog, and Reload vault repeated the same failure: Settings became
    /// unusable with no way back inside the app.
    func finishConfiguration(_ saved: VaultConfiguration) async {
        if await openConfiguredArchive(saved) { await refreshRetainedAccounting() }
    }
    /// The part of finishing configuration that a chat on screen depends on:
    /// saved output limits migrated, and the request archive open, because
    /// a chat's accounting reads it and its helper's traffic is written into
    /// it. Launch opens the chat it restores after this, and before the
    /// retained billing of every listed chat, the slowest read left.
    @discardableResult func openConfiguredArchive(_ saved: VaultConfiguration) async -> Bool {
        do { try await migrateLegacyOutputBudgets() }
        catch { self.error = "Saved chat output limits could not be migrated. \(error.localizedDescription)" }
        do {
            try await traces.configure(key: saved.captureKey, quota: saved.capture.quotaUnlimited ? nil : saved.capture.quotaBytes,
                                       bodyRetention: Double(saved.capture.retentionDays) * 86400,
                                       metricRetention: Double(saved.dashboard.metricRetentionDays) * 86400)
            return true
        } catch { self.error = "Request archive: " + error.localizedDescription; return false }
    }
    func ensureConfiguration() async throws { if !configurationLoaded { try await reloadConfiguration() } }
    /// The vault could not be read at launch, most often because the login
    /// Keychain was locked: every project read "Retained chats" and every chat
    /// "Project unavailable" until Settings happened to reload it, even after
    /// the Keychain was unlocked. Each time the app becomes active it tries
    /// again, until the vault reads.
    func retryConfigurationWhenActive() {
        guard configurationRetry == nil, !configurationLoaded else { return }
        configurationRetry = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryConfiguration() }
        }
    }
    /// One more try at the vault, from an activation or the Retry button.
    func retryConfiguration() {
        guard !configurationLoaded else { stopConfigurationRetry(); return }
        guard !configurationRetrying else { return }
        configurationRetrying = true
        let failure = error
        Task {
            defer { configurationRetrying = false }
            do {
                try await reloadConfiguration()
                stopConfigurationRetry()
                if error == failure { error = nil }
                // Launch chose these while there was nothing to choose from;
                // without them New Chat had no project or connection.
                if selectedWorkspaceID == nil { selectedWorkspaceID = workspaces.first?.id }
                if !profiles.contains(where: { $0.id == profileChoice }) { profileChoice = requestProfiles.first?.id ?? "" }
            } catch { }
        }
    }
    func stopConfigurationRetry() {
        if let configurationRetry { NotificationCenter.default.removeObserver(configurationRetry) }
        configurationRetry = nil
    }
    /// Trusted, tool-free home for chats that belong to no project. It lives in
    /// the app's own state directory, so no user folder is exposed.
    var scratchWorkspace: WorkspaceRecord {
        WorkspaceRecord(id: WorkspaceRecord.scratchID, path: root.appendingPathComponent("Scratch", isDirectory: true).path, trusted: true)
    }
    /// Configured projects plus the scratch workspace.
    func workspace(for id: String) -> WorkspaceRecord? {
        workspaces.first { $0.id == id } ?? (id == WorkspaceRecord.scratchID ? scratchWorkspace : nil)
    }
    func updateConfiguration(expectedRevision: Int64? = nil, _ change: @escaping @Sendable (inout VaultConfiguration) throws -> Void) async throws {
        try await ensureConfiguration()
        let saved = try await vault.update(expectedRevision: expectedRevision ?? configuration.revision, change)
        applyConfiguration(saved)
        // The vault write already committed. A failure migrating local chat
        // limits must not be reported as a save that did not happen: retrying
        // a route change would fork a second, duplicate connection.
        await finishConfiguration(saved)
    }
    /// Vault access can succeed after an initial startup failure. Migrate once
    /// when the matching connection is available, without replacing live state.
    private func migrateLegacyOutputBudgets() async throws {
        guard chats.contains(where: { $0.outputBudgetVersion == nil }), let store else { return }
        let saved = try await store.loadChats(profiles: profiles)
        for migrated in saved where migrated.outputBudgetVersion == 1 {
            guard let index = chats.firstIndex(where: { $0.id == migrated.id }), chats[index].outputBudgetVersion == nil else { continue }
            chats[index].maxOutputTokens = migrated.maxOutputTokens
            chats[index].modelOutputLimit = migrated.modelOutputLimit
            chats[index].outputBudgetVersion = migrated.outputBudgetVersion
        }
    }
    func credentials(for profile: ProfileRecord) async throws -> [String: WireValue] {
        // Recheck Keychain access when opening a connection. No per-profile,
        // shell, environment, Pi auth.json or plaintext fallback is consulted.
        let saved = try await vault.load()
        guard let connection = saved.profiles.first(where: { $0.profile.id == profile.id }), connection.profile == profile else {
            throw HostError.failure("The LiteLLM connection changed. Reload settings before sending.")
        }
        return ["apiKey": .string(connection.apiKey), "headers": .object(connection.headers.mapValues(WireValue.string))]
    }
    func saveProfile(_ input: ProfileRecord, key: String, headers: String = "", preferences: VaultConfiguration? = nil, expectedRevision: Int64? = nil) async throws {
        try LiteLLMConfiguration.requireSupportedAPI(input.api)
        try await ensureConfiguration()
        var profile = input; profile.providerId = "litellm"
        // Saving never waits for the connection's chats: a run that is going keeps
        // the settings it started with and its next turn uses the new ones.
        let affected = chats.filter { $0.profileID == profile.id }
        let previous = configuration.profiles.first { $0.profile.id == profile.id }
        var parsedHeaders = previous?.headers ?? [:]
        if !headers.isEmpty {
            guard headers.utf8.count <= 262_144, let values = try? JSONDecoder().decode([String: String].self, from: Data(headers.utf8)) else {
                throw HostError.failure("Custom headers must be a JSON object of strings within 256 KiB.")
            }
            parsedHeaders = values
        }
        let apiKey = key.isEmpty ? previous?.apiKey ?? "" : key
        let changedRoute = previous.map {
            $0.profile.api != profile.api || $0.profile.baseUrl != profile.baseUrl || $0.profile.modelId != profile.modelId
        } ?? false
        if changedRoute { profile.id = UUID().uuidString }
        profile.revision = UUID().uuidString
        let connection = VaultProfile(profile: profile, apiKey: apiKey, headers: parsedHeaders)
        try await updateConfiguration(expectedRevision: expectedRevision) { saved in
            if let index = saved.profiles.firstIndex(where: { $0.profile.id == connection.profile.id }) { saved.profiles[index] = connection }
            else { saved.profiles.append(connection) }
            saved.inheritCatalog(from: previous, to: connection)
            if let preferences {
                saved.runtime = preferences.runtime; saved.capture = preferences.capture
                saved.dashboard = preferences.dashboard; saved.automaticUpdateChecks = preferences.automaticUpdateChecks
                saved.completionSoundEnabled = preferences.completionSoundEnabled; saved.transcriptView = preferences.transcriptView
                saved.chatCostLimit = preferences.chatCostLimit; saved.webhook = preferences.webhook
            }
        }
        // Configuration is durable before the helper hears about it. An idle
        // session takes the new settings at once; one with a run going keeps the
        // settings it started with and switches when the run ends. Only that
        // connection's credentials travel, never the vault object.
        if !changedRoute {
            let sideSessions = sides.values.filter { $0.profileID == profile.id }.map { ($0.id, $0.workspaceID) }
            for (id, workspaceID) in affected.map({ ($0.id, $0.workspaceID) }) + sideSessions where opened.contains(id) {
                guard let host = hosts[workspaceID], host.isReady else { continue }
                var wire = connection.profile.wire.object ?? [:]
                wire["headers"] = .object(connection.headers.mapValues(WireValue.string))
                do {
                    let result = try await host.request("session.configure", sessionID: id, params: ["profile": .object(wire), "apiKey": .string(connection.apiKey)])
                    if result.object?["applied"]?.bool == false {
                        displays[id]?.notice = "Settings saved. This run keeps the connection settings it started with; the next turn uses the new ones."
                    }
                } catch {
                    // A helper without the command: an idle session reopens with the new settings on its next turn.
                    if displays[id]?.hasWork != true { _ = try? await host.request("session.close", sessionID: id); opened.remove(id) }
                }
            }
        }
        profileChoice = profile.id
    }
    /// Removes a connection and its key. Its chats keep their history and ask
    /// for another connection; a run still going under it is stopped and its
    /// helper session closed first, so the deletion never waits on work; the
    /// catalog links a route fork left behind go with it. The vault is read
    /// back afterwards, so a deletion that did not take is an error, never a
    /// list that quietly stays the same.
    func deleteProfile(_ id: String) async throws {
        try await ensureConfiguration()
        guard let removed = configuration.profiles.first(where: { $0.profile.id == id }) else {
            // The list on screen may be older than the vault: read it again before giving up.
            try await reloadConfiguration()
            guard configuration.profiles.contains(where: { $0.profile.id == id }) else {
                throw HostError.failure("This connection is no longer in the vault; the list was reloaded.")
            }
            try await deleteProfile(id); return
        }
        guard deletingProfiles.insert(id).inserted else { throw HostError.failure("This connection is already being deleted.") }
        profileDeletionGenerations[id, default: 0] &+= 1
        defer { deletingProfiles.remove(id) }
        let name = removed.profile.name.isEmpty ? "Unnamed" : removed.profile.name
        // A side may still be publishing and not yet appear in `chats`.
        // It holds the same live credentials and must be stopped as well.
        var seen = Set<String>()
        let affected = (chats + sides.values.map(\.chat)).filter { $0.profileID == id && seen.insert($0.id).inserted }
        Self.vaultLog.info("Deleting connection \(name, privacy: .public) (\(id, privacy: .public)) at vault revision \(self.configuration.revision): \(affected.count) chats, \(self.configuration.catalogSources?.count ?? 0) catalog links")
        for item in affected {
            let view = displays[item.id]
            if opened.contains(item.id), let host = hosts[item.workspaceID] {
                // Display events can lag the helper. Stop is idempotent and its
                // acknowledgment is required before removing the credentials.
                _ = try await host.request("turn.stop", sessionID: item.id)
                do {
                    _ = try await host.request("session.close", sessionID: item.id)
                    opened.remove(item.id)
                } catch {
                    // Stop is asynchronous; an unloading rejection must not
                    // make a still-live runtime disappear from our tracking.
                    // `open` also rejects deleted connections before its cache hit.
                }
            }
            if let view, view.hasWork || view.loading { view.runState = .interrupted; view.queue = []; view.queueCount = 0; view.loading = false }
        }
        let remove: @Sendable (inout VaultConfiguration) -> Void = { saved in
            saved.profiles.removeAll { $0.profile.id == id }
            saved.forgetCatalogLinks(of: id)
        }
        do {
            do { try await updateConfiguration(remove) }
            catch VaultError.conflict {
                // Another save moved the vault on: read it again and delete from what is there now.
                try await reloadConfiguration()
                try await updateConfiguration(remove)
            }
            let stored = try await vault.load()
            guard !stored.profiles.contains(where: { $0.profile.id == id }) else {
                throw HostError.failure("The vault still lists “\(name)” after the save (revision \(stored.revision)). Reload Settings and try again.")
            }
        } catch {
            Self.vaultLog.error("Deleting connection \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        Self.vaultLog.info("Deleted connection \(name, privacy: .public); vault revision \(self.configuration.revision), \(self.profiles.count) connections remain")
        // The connection is gone from the vault; its model list must go too.
        // A cached entry outlived the connection for the rest of the session,
        // and a new connection that reused the id would open on its models.
        modelCatalog.invalidate(profileID: id)
        if profileChoice == id { profileChoice = profiles.first?.id ?? "" }
        for item in affected { displays[item.id]?.notice = "This chat's connection was deleted. Choose another connection to continue." }
    }
    /// Vault outcomes, for `log show --predicate 'subsystem == "com.belloware.PiApp"'` when a report says nothing changed.
    private static let vaultLog = Logger(subsystem: "com.belloware.PiApp", category: "vault")
    func savePreferences(_ preferences: VaultConfiguration, expectedRevision: Int64) async throws {
        try await updateConfiguration(expectedRevision: expectedRevision) {
            $0.runtime = preferences.runtime; $0.capture = preferences.capture
            $0.dashboard = preferences.dashboard; $0.automaticUpdateChecks = preferences.automaticUpdateChecks
            $0.completionSoundEnabled = preferences.completionSoundEnabled; $0.transcriptView = preferences.transcriptView
            $0.chatCostLimit = preferences.chatCostLimit; $0.webhook = preferences.webhook
        }
    }
    /// Why a project's MCP servers can't change now, or nil when they can.
    func mcpChangeBlocked(_ id: String) -> String? {
        // A send counts from the moment its row shows, before it reaches the
        // helper: it has passed its own checks and won't look at this again.
        guard !chats.contains(where: { chat in
                  guard chat.workspaceID == id, let view = displays[chat.id] else { return false }
                  return view.hasWork || view.loading || !view.sendingRows.isEmpty
              }),
              !sides.values.contains(where: { $0.workspaceID == id && !($0.kept) }) else {
            return "Stop project work and close or keep sides before changing MCP servers."
        }
        return nil
    }
    /// How many MCP servers a project has saved in the vault.
    func mcpServerCount(_ id: String) -> Int { configuration.mcp[id]?.object?["servers"]?.object?.count ?? 0 }
    /// What saving a project's MCP servers did to its running helper.
    enum MCPApplied: Equatable {
        /// No helper was running, or the running one took the configuration.
        case applied
        /// The vault holds the new configuration, but the running helper
        /// couldn't load it and is being stopped; it starts with it next time.
        case helperStopping
    }
    /// Shown when the vault saved but the helper didn't take it. Fixed copy:
    /// the helper's own message can quote the configuration it refused.
    static let mcpHelperStoppingNotice = "The project's helper couldn't load the change and is being stopped. It starts with the saved MCP configuration next time."
    func saveMCPConfiguration(_ config: WireValue, expectedRevision: Int64, workspaceID: String? = nil) async throws {
        guard let id = workspaceID ?? selectedWorkspaceID else { throw HostError.failure("Choose a project first.") }
        try holdProjectForMCPChange(id)
        defer { workspaceChangesInFlight.remove(id) }
        try await updateConfiguration(expectedRevision: expectedRevision) { $0.mcp[id] = config }
        if await applyMCPConfiguration(config, to: id) == .helperStopping {
            throw HostError.failure("Saved in the vault. " + Self.mcpHelperStoppingNotice)
        }
    }
    /// Marks the project as changing, as folder changes do, so no chat opens
    /// and no helper starts on it until the change is saved and applied.
    /// The caller removes the mark.
    private func holdProjectForMCPChange(_ id: String) throws {
        guard !workspaceChangesInFlight.contains(id) else { throw HostError.failure("Wait for this project's changes to finish.") }
        if let reason = mcpChangeBlocked(id) { throw HostError.failure(reason) }
        workspaceChangesInFlight.insert(id)
    }
    /// Hands a saved configuration to the project's running helper, if one is
    /// running. A failure stops only that same helper connection. A helper
    /// that replaced it while the request was out started from the vault,
    /// which already held the change.
    private func applyMCPConfiguration(_ config: WireValue, to id: String) async -> MCPApplied {
        guard let host = hosts[id], host.isReady else { return .applied }
        let connection = host.connectionID
        do { _ = try await host.request("mcp.configure", params: ["config": config]); return .applied }
        catch {
            guard hosts[id] === host, host.connectionID == connection else { return .applied }
            host.shutdown()
            return .helperStopping
        }
    }
    enum MCPRemoval: Equatable { case nothingSaved, removed, removedHelperStopping }
    /// Deletes one project's saved MCP servers, the project captured when the
    /// reader asked, whatever is selected by the time this runs. The vault
    /// must still be at `expectedRevision`: servers saved since are not
    /// removed unseen.
    func removeAllMCPServers(workspaceID id: String, expectedRevision: Int64) async throws -> MCPRemoval {
        guard workspaces.contains(where: { $0.id == id }) else { throw HostError.failure("That project is no longer in the sidebar.") }
        try holdProjectForMCPChange(id)
        defer { workspaceChangesInFlight.remove(id) }
        try await ensureConfiguration()
        let stored = try await vault.load()
        guard stored.revision == expectedRevision else {
            throw HostError.failure("The MCP configuration changed while you were asked. Review it and try again.")
        }
        guard stored.mcp[id]?.object?["servers"]?.object?.isEmpty == false else { return .nothingSaved }
        let empty = WireValue.object(["servers": .object([:])])
        try await updateConfiguration(expectedRevision: expectedRevision) { $0.mcp[id] = empty }
        return await applyMCPConfiguration(empty, to: id) == .applied ? .removed : .removedHelperStopping
    }
    /// The question asked before removing a project's MCP servers.
    static func mcpRemovalQuestion(path: String, servers: Int) -> (title: String, detail: String) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let count = servers == 1 ? "1 server" : "\(servers) servers"
        return ("Remove all MCP servers from “\(name)”?",
                "This deletes the saved MCP configuration of the project at \(path) from the vault: \(count), and any server credentials stored with them. "
                + "It is not a temporary disconnect. To use these servers again, add them back. The project's running MCP connections close.")
    }
    /// Asks, then removes the selected project's MCP servers. Returns what to
    /// tell the reader, or nil when they cancelled or a question was already up.
    func confirmAndRemoveAllMCPServers() async -> String? {
        guard !mcpRemovalInProgress, let id = selectedWorkspaceID, let project = workspaces.first(where: { $0.id == id }) else { return nil }
        let servers = mcpServerCount(id)
        guard servers > 0 else { return "This project has no saved MCP servers." }
        mcpRemovalInProgress = true; defer { mcpRemovalInProgress = false }
        let revision = configuration.revision, name = URL(fileURLWithPath: project.path).lastPathComponent
        let question = Self.mcpRemovalQuestion(path: project.path, servers: servers)
        guard await PiQuestion.shared.confirm(question.title, question.detail, action: "Remove All Servers",
                                              destructive: true, cancelIsDefault: true) else { return nil }
        do {
            switch try await removeAllMCPServers(workspaceID: id, expectedRevision: revision) {
            case .nothingSaved: return "“\(name)” has no saved MCP servers."
            case .removed: return "Removed all MCP servers from “\(name)”."
            case .removedHelperStopping: return "Removed “\(name)”'s saved MCP servers. " + Self.mcpHelperStoppingNotice
            }
        } catch { return error.localizedDescription }
    }
}
