import Foundation

extension VaultConfiguration {
    /// Update one model-list binding, leaving route records and credentials intact.
    mutating func useCatalog(sourceID: String, for profileID: String) throws {
        guard profiles.contains(where: { $0.profile.id == profileID && $0.profile.api == LiteLLMConfiguration.supportedAPI }),
              profiles.contains(where: { $0.profile.id == sourceID && $0.profile.api == LiteLLMConfiguration.supportedAPI }) else {
            throw ModelCatalogRefreshFailure.missingProfile
        }
        var sources = catalogSources ?? [:]
        // Selecting this connection explicitly restores its own saved URL.
        let authority = sourceID == profileID ? profileID : sources[sourceID] ?? sourceID
        if authority == profileID { sources.removeValue(forKey: profileID) }
        else {
            // Flatten followers before this authority becomes a reference.
            for (id, target) in sources where target == profileID { sources[id] = authority }
            sources[profileID] = authority
        }
        catalogSources = sources.isEmpty ? nil : sources
    }

    /// Only a route fork we create establishes lineage. Similar legacy records
    /// are not evidence that two independently configured catalogs are related.
    mutating func inheritCatalog(from previous: VaultProfile?, to replacement: VaultProfile) {
        guard let previous else { return }
        let oldID = previous.profile.id, newID = replacement.profile.id
        let editedCatalog = previous.profile.catalogUrl != replacement.profile.catalogUrl
        if oldID == newID {
            if editedCatalog { catalogSources?.removeValue(forKey: oldID) }
            return
        }
        guard Self.sameCatalogAuthority(previous, replacement) else { return }
        var sources = catalogSources ?? [:]
        let authority = sources[oldID] ?? oldID
        if authority != oldID && !editedCatalog {
            sources[newID] = authority
        } else if authority == oldID {
            // A new default model must not strand earlier chats on an old URL.
            for (id, target) in sources where target == authority { sources[id] = newID }
            sources[authority] = newID
            sources[oldID] = newID
            sources.removeValue(forKey: newID)
        } else {
            // A follower can adopt a new catalog for its own chats. Editing it
            // does not grant ownership of the independently selected source.
            sources[oldID] = newID
        }
        catalogSources = sources.isEmpty ? nil : sources
    }

    private static func sameCatalogAuthority(_ lhs: VaultProfile, _ rhs: VaultProfile) -> Bool {
        lhs.profile.api == rhs.profile.api && lhs.profile.baseUrl == rhs.profile.baseUrl &&
        lhs.apiKey == rhs.apiKey && lhs.headers == rhs.headers
    }
}

extension WorkspaceModel {
    /// Resolve catalog metadata only. Never use this profile to dispatch a turn.
    func catalogProfile(for route: ProfileRecord) -> ProfileRecord {
        let sourceID = configuration.catalogSources?[route.id] ?? route.id
        return profiles.first(where: { $0.id == sourceID }) ?? route
    }

    func catalogEntry(for route: ProfileRecord) -> ModelCatalog.Entry {
        modelCatalog.entry(for: catalogProfile(for: route))
    }

    /// Older route snapshots have no recorded catalog lineage. Surface newer
    /// saved alternatives instead of silently guessing that they share a list.
    /// This deliberately ignores profileChoice: selecting a chat resets it to
    /// that chat's original request profile, even after Settings saved a fork.
    func catalogRepairChoices(for route: ProfileRecord) -> [ProfileRecord] {
        guard route.api == LiteLLMConfiguration.supportedAPI,
              configuration.catalogSources?[route.id] == nil,
              let index = profiles.firstIndex(where: { $0.id == route.id }) else { return [] }
        let currentURL = normalizedCatalogURL(route)
        var seen = Set<String>()
        return profiles.dropFirst(index + 1).reversed().filter { candidate in
            guard candidate.api == route.api, candidate.baseUrl == route.baseUrl,
                  configuration.catalogSources?[candidate.id] == nil,
                  let url = normalizedCatalogURL(candidate), url != currentURL else { return false }
            return seen.insert(url).inserted
        }
    }

    private func normalizedCatalogURL(_ profile: ProfileRecord) -> String? {
        let value = (profile.catalogUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Explicit repair for older chats whose preserved connection predates a
    /// custom catalog. This changes the list for that connection, not its route.
    func selectCatalog(sourceID: String, for profileID: String) async throws {
        do {
            try await reloadConfiguration()
            try await updateConfiguration { try $0.useCatalog(sourceID: sourceID, for: profileID) }
        } catch let error as ModelCatalogRefreshFailure { throw error }
        catch { throw ModelCatalogRefreshFailure.configuration }
        guard let profile = profiles.first(where: { $0.id == profileID }) else { throw ModelCatalogRefreshFailure.missingProfile }
        _ = await listModels(for: profile, force: true)
    }
}
