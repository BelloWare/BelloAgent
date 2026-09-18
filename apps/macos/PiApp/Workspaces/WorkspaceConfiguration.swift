import Foundation

extension WorkspaceModel {
    func reloadConfiguration() async throws {
        do {
            let saved = try await vault.load()
            configuration = saved; configurationLoaded = true
            profiles = saved.profiles.map(\.profile); workspaces = saved.workspaces
            try await migrateLegacyOutputBudgets()
            await configureArchive(saved)
        } catch {
            configurationLoaded = false
            throw error
        }
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
        configuration = saved; profiles = saved.profiles.map(\.profile); workspaces = saved.workspaces
        try await migrateLegacyOutputBudgets()
        await configureArchive(saved)
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
    private func configureArchive(_ config: VaultConfiguration) async {
        do {
            try await traces.configure(key: config.captureKey, quota: config.capture.quotaBytes,
                                       bodyRetention: Double(config.capture.retentionDays) * 86400,
                                       metricRetention: Double(config.dashboard.metricRetentionDays) * 86400)
            await refreshRetainedAccounting()
        }
        catch { self.error = "Request archive: " + error.localizedDescription }
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
        let affected = chats.filter { $0.profileID == profile.id }
        guard !sides.values.contains(where: { $0.profileID == profile.id && !$0.kept && !$0.pending }),
              !affected.contains(where: { displays[$0.id]?.hasWork == true || displays[$0.id]?.loading == true }) else {
            throw HostError.failure("Stop this connection's work and keep or close its side before changing settings.")
        }
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
            }
        }
        // Configuration is durable before closing idle sessions. Reopening
        // receives only that connection's credentials, never the vault object.
        if !changedRoute {
            for item in affected where opened.contains(item.id) {
                _ = try await hosts[item.workspaceID]?.request("session.close", sessionID: item.id); opened.remove(item.id)
            }
        }
        profileChoice = profile.id
    }
    func savePreferences(_ preferences: VaultConfiguration, expectedRevision: Int64) async throws {
        try await updateConfiguration(expectedRevision: expectedRevision) {
            $0.runtime = preferences.runtime; $0.capture = preferences.capture
            $0.dashboard = preferences.dashboard; $0.automaticUpdateChecks = preferences.automaticUpdateChecks
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
