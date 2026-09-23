import Foundation
import os

extension WorkspaceModel {
    struct ConnectionLease {
        let profileID: String
        let deletionGeneration: UInt64
    }
    var connectionUnavailable: HostError {
        .rejected("connection_unavailable", "This chat's connection is unavailable. Restore it in Settings before continuing.")
    }
    func connectionLease(for item: ChatRecord) throws -> ConnectionLease {
        let lease = ConnectionLease(profileID: item.profileID, deletionGeneration: profileDeletionGenerations[item.profileID, default: 0])
        try requireConnection(lease)
        return lease
    }
    func requireConnection(_ lease: ConnectionLease) throws {
        guard !deletingProfiles.contains(lease.profileID),
              profileDeletionGenerations[lease.profileID, default: 0] == lease.deletionGeneration,
              profiles.contains(where: { $0.id == lease.profileID }) else { throw connectionUnavailable }
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
            if case nil = try? requireConnection(lease) {
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
                throw connectionUnavailable
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
        configuration = saved; configurationLoaded = true
        profiles = saved.profiles.map(\.profile); workspaces = saved.workspaces
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
            try await traces.configure(key: saved.captureKey, quota: saved.capture.quotaBytes,
                                       bodyRetention: Double(saved.capture.retentionDays) * 86400,
                                       metricRetention: Double(saved.dashboard.metricRetentionDays) * 86400)
            return true
        } catch { self.error = "Request archive: " + error.localizedDescription; return false }
    }
    func ensureConfiguration() async throws { if !configurationLoaded { try await reloadConfiguration() } }
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
            if let view, view.hasWork || view.loading { view.state = "interrupted"; view.queue = []; view.queueCount = 0; view.loading = false }
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
        }
    }
    func saveMCPConfiguration(_ config: WireValue, expectedRevision: Int64) async throws {
        guard let id = selectedWorkspaceID, !chats.contains(where: { $0.workspaceID == id && displays[$0.id]?.hasWork == true }),
              !sides.values.contains(where: { $0.workspaceID == id && !($0.kept) }) else { throw HostError.failure("Stop project work and close or keep sides before changing MCP servers.") }
        try await updateConfiguration(expectedRevision: expectedRevision) { $0.mcp[id] = config }
        if let host = hosts[id], host.isReady {
            do { _ = try await host.request("mcp.configure", params: ["config": config]) }
            catch { host.shutdown(); throw error }
        }
    }
}
