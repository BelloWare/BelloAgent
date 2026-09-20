import Foundation

/// Reasoning effort levels accepted by turn.submit / turn.steer (contract H3).
/// Profile default is stored as nil; wire `default` omits an explicit effort.
enum ThinkingLevel: String, CaseIterable, Sendable {
    case profileDefault = "profile-default"
    case `default`, off, minimal, low, medium, high, xhigh, max
    var label: String {
        switch self {
        case .profileDefault: return "Profile default"
        case .default: return "Model default"
        case .off: return "Off"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Max"
        }
    }
    /// Short text for the composer pill, e.g. "Effort · medium".
    var pillLabel: String {
        switch self {
        // "default" twice over said nothing about whose default it was, and
        // "model" read as the name of a model rather than as who decides.
        case .profileDefault: return "Effort · connection default"
        case .default: return "Effort · model decides"
        default: return "Effort · \(rawValue)"
        }
    }
}

/// Builds the per-turn override parameters from a chat record. Overrides only
/// affect the requests of that turn; the profile itself is never rewritten.
enum TurnOverrides {
    static let maximumModelLength = 200
    /// A trimmed model alias within the 1…200 character wire limit, or nil.
    static func normalizedModel(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              trimmed.count <= maximumModelLength, !trimmed.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { return nil }
        return trimmed
    }
    /// A wire level, including explicit `default`, or nil for the profile setting.
    static func normalizedThinkingLevel(_ value: String?) -> String? {
        guard let value, let level = ThinkingLevel(rawValue: value), level != .profileDefault else { return nil }
        return level.rawValue
    }
    static func params(for chat: ChatRecord, base: [String: WireValue] = [:]) -> [String: WireValue] {
        var params = base
        if let model = normalizedModel(chat.model) { params["model"] = .string(model) }
        if let level = normalizedThinkingLevel(chat.thinkingLevel) { params["thinkingLevel"] = .string(level) }
        if let context = chat.contextWindow { params["contextWindow"] = .number(Double(context)) }
        if let output = chat.maxOutputTokens { params["maxOutputTokens"] = .number(Double(output)) }
        if let ceiling = chat.modelOutputLimit { params["modelOutputLimit"] = .number(Double(ceiling)) }
        return params
    }
}

/// The last deliberate picker choice for one connection. Kept separately from
/// chats so opening an older conversation cannot replace the next chat's defaults.
/// An existing record with nil values means the user chose the profile defaults.
struct ChatModelDefaults: Codable, Sendable, Equatable {
    static let recordKind = "chat-model-defaults"
    var model: String?
    var thinkingLevel: String?
    var contextWindow: Int?
    var maxOutputTokens: Int?
    var modelOutputLimit: Int?
    var outputBudgetVersion: Int?

    init(chat: ChatRecord) {
        model = chat.model; thinkingLevel = chat.thinkingLevel
        contextWindow = chat.contextWindow; maxOutputTokens = chat.maxOutputTokens
        modelOutputLimit = chat.modelOutputLimit; outputBudgetVersion = chat.outputBudgetVersion
    }

    func apply(to chat: inout ChatRecord, profile: ProfileRecord? = nil) {
        chat.model = model; chat.thinkingLevel = thinkingLevel
        chat.contextWindow = contextWindow; chat.maxOutputTokens = maxOutputTokens
        chat.modelOutputLimit = modelOutputLimit; chat.outputBudgetVersion = outputBudgetVersion
        if let profile { chat.migrateOutputBudget(profile: profile) }
    }
}

/// Cached model catalogs keyed by profile id. Connections use the bundled
/// Bello catalog unless an explicit catalog URL replaces it. Remote catalogs
/// refresh lazily every five minutes when a picker next asks. Concurrent
/// requests for one profile share a single fetch, and a failed refresh keeps
/// the last list usable beside its error.
@MainActor final class ModelCatalog: ObservableObject {
    struct Entry: Equatable, Sendable {
        var models: [String] = []
        /// Rich entries when the connection publishes a catalog (docs/Model-Catalog.md).
        var descriptors: [ModelDescriptor] = []
        /// The configured source, including while loading or after an error.
        var source = "bundled"
        var fetchedAt: Date?
        var error: String?
        var loading = false
        func descriptor(for id: String) -> ModelDescriptor? { descriptors.first { $0.id == id } }
        /// Models offered in pickers: catalog order without deprecated entries (unless currently chosen).
        func offered(current: String?) -> [ModelDescriptor] {
            descriptors.filter { !$0.deprecated || $0.id == current }
        }
        func isFresh(now: Date, ttl: TimeInterval) -> Bool { fetchedAt.map { now.timeIntervalSince($0) < ttl } ?? false }
    }
    typealias FetchCatalog = @Sendable (_ url: URL, _ key: String) async throws -> [ModelDescriptor]
    typealias ReadBundled = @Sendable () throws -> [ModelDescriptor]

    @Published private(set) var entries: [String: Entry] = [:]
    /// Catalog lists stay fresh this long before the next picker access refetches.
    let catalogTTL: TimeInterval
    /// A failed fetch is not retried for this long unless forced, so hovering a picker cannot hammer a broken endpoint.
    static let failureRetry: TimeInterval = 30
    private let readBundled: ReadBundled
    private let fetchCatalog: FetchCatalog
    private let now: @Sendable () -> Date
    private struct Listing: Sendable { var models: [String]; var descriptors: [ModelDescriptor]; var source: String }
    private struct Fetch { var token: UUID; var task: Task<Listing, Error> }
    private var inFlight: [String: Fetch] = [:]
    private var cachedProfiles: [String: ProfileRecord] = [:]

    init(catalogTTL: TimeInterval = 300, now: @escaping @Sendable () -> Date = { Date() },
         readBundled: @escaping ReadBundled = { try ModelCatalogEndpoint.bundled() },
         fetchCatalog: @escaping FetchCatalog = { url, key in try await ModelCatalogEndpoint().fetch(url: url, key: key) }) {
        self.catalogTTL = catalogTTL; self.now = now; self.readBundled = readBundled; self.fetchCatalog = fetchCatalog
    }

    func entry(for profileID: String) -> Entry { entries[profileID] ?? Entry() }
    func entry(for profile: ProfileRecord) -> Entry {
        cachedProfiles[profile.id] == profile ? entry(for: profile.id) : Entry(source: Self.catalogConfigured(profile) ? "catalog" : "bundled")
    }

    static func failureMessage(_ error: Error) -> String {
        (error as? ModelCatalogEndpoint.Failure)?.localizedDescription ??
        (error as? GatewayModelDiscovery.Failure)?.localizedDescription ??
        (error as? HostError)?.localizedDescription ?? "Couldn't list models."
    }
    /// A non-blank catalog URL makes the catalog the only model source.
    static func catalogConfigured(_ profile: ProfileRecord) -> Bool {
        !(profile.catalogUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Lists models for a profile, reusing a fresh cache or an in-flight fetch.
    /// `credential` resolves the gateway key lazily so nothing leaves Keychain
    /// while the cache is warm.
    @discardableResult
    func load(profile: ProfileRecord, force: Bool = false, credential: @escaping @Sendable () async throws -> String) async -> [String] {
        let id = profile.id
        if cachedProfiles[id] != profile { invalidate(profileID: id); cachedProfiles[id] = profile }
        var current = entry(for: id)
        let usesCatalog = Self.catalogConfigured(profile)
        if !force, current.error == nil, current.fetchedAt != nil,
           !usesCatalog || current.isFresh(now: now(), ttl: catalogTTL) { return current.models }
        if !force, current.error != nil, current.isFresh(now: now(), ttl: Self.failureRetry) { return current.models }
        if let running = inFlight[id] {
            let listing = try? await running.task.value
            guard cachedProfiles[id] == profile, !running.task.isCancelled else { return entry(for: profile).models }
            return listing?.models ?? entry(for: profile).models
        }
        current.source = usesCatalog ? "catalog" : "bundled"
        current.loading = true; current.error = nil; entries[id] = current
        let base = profile.baseUrl, api = profile.api, readBundled = readBundled, fetchCatalog = fetchCatalog
        let catalogURL = profile.catalogUrl.flatMap { try? ModelCatalogEndpoint.url($0) }
        let task = Task<Listing, Error> {
            if usesCatalog {
                // The catalog replaces the gateway list entirely: falling back
                // would reintroduce the models the catalog was set up to hide.
                guard let catalogURL else { throw ModelCatalogEndpoint.Failure.url }
                let key = ModelCatalogEndpoint.usesGatewayCredential(catalogURL, base: base, api: api) ? try await credential() : ""
                try Task.checkCancellation()
                let descriptors = try await fetchCatalog(catalogURL, key)
                return Listing(models: descriptors.filter { !$0.deprecated }.map(\.id), descriptors: descriptors, source: "catalog")
            }
            try Task.checkCancellation()
            // This task inherits the main actor, and reading and parsing the
            // bundled catalog is a file read: it happens in the window between
            // a chat's pane appearing and its controls settling.
            let descriptors = try await Self.readingBundled(readBundled)
            return Listing(models: descriptors.filter { !$0.deprecated }.map(\.id), descriptors: descriptors, source: "bundled")
        }
        let token = UUID()
        inFlight[id] = Fetch(token: token, task: task)
        let result = await task.result
        guard inFlight[id]?.token == token, cachedProfiles[id] == profile else { return entry(for: profile).models }
        inFlight[id] = nil
        var updated = entry(for: id); updated.loading = false
        do {
            let listing = try result.get()
            updated.models = listing.models; updated.descriptors = listing.descriptors; updated.source = listing.source
            updated.fetchedAt = now(); updated.error = nil
        } catch {
            // No "cancelled" case: the only canceller is `invalidate`, which
            // clears this entry and its in-flight token, so such a result is
            // already dropped by the guard above. A cancellation that somehow
            // arrived from the endpoint is reported like any other failure,
            // rather than as an action nobody took. The last good list stays
            // usable; pickers show the error beside it.
            updated.source = usesCatalog ? "catalog" : "bundled"
            updated.fetchedAt = now(); updated.error = Self.failureMessage(error)
        }
        entries[id] = updated
        return updated.models
    }

    /// Off the main actor: the catalog is `Sendable`, so nothing else moves.
    private nonisolated static func readingBundled(_ read: @escaping ReadBundled) async throws -> [ModelDescriptor] {
        try await Task.detached(priority: .userInitiated) { try read() }.value
    }

    func invalidate(profileID: String) {
        inFlight[profileID]?.task.cancel(); inFlight[profileID] = nil; entries[profileID] = nil; cachedProfiles[profileID] = nil
    }
}

/// Explicit refresh rechecks the saved connection, unlike passive catalog
/// opening. Keep these errors fixed: vault failures can contain private data.
enum ModelCatalogRefreshFailure: Error, LocalizedError, Equatable {
    case configuration, missingProfile, unsupportedAPI
    var errorDescription: String? {
        switch self {
        case .configuration: return "Couldn't reload the saved connection. Open Settings, reload the vault, then try again."
        case .missingProfile: return "This chat's connection is no longer saved. Open Settings to restore the connection."
        case .unsupportedAPI: return "This connection is for Messages history only. Choose a Responses connection in Settings."
        }
    }
}

/// The catalog's loading flag starts at the HTTP fetch. This state also covers
/// the preceding vault reload, so Refresh cannot look idle or be clicked twice.
@MainActor final class ModelCatalogRefreshState: ObservableObject {
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    func selectSource(model: WorkspaceModel, sourceID: String, profileID: String) async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do { try await model.selectCatalog(sourceID: sourceID, for: profileID) }
        catch { self.error = (error as? ModelCatalogRefreshFailure ?? .configuration).localizedDescription }
    }

    func refresh(model: WorkspaceModel, profileID: String) async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do { _ = try await model.refreshModels(profileID: profileID) }
        catch { self.error = (error as? ModelCatalogRefreshFailure ?? .configuration).localizedDescription }
    }
}

extension WorkspaceModel {
    /// Re-read Settings before a deliberate refresh, including the independently
    /// saved catalog binding. A newer profileChoice is never inferred as a source.
    @discardableResult
    func refreshModels(profileID: String) async throws -> [String] {
        do { try await reloadConfiguration() }
        catch { throw ModelCatalogRefreshFailure.configuration }
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            throw ModelCatalogRefreshFailure.missingProfile
        }
        guard profile.api == LiteLLMConfiguration.supportedAPI else {
            throw ModelCatalogRefreshFailure.unsupportedAPI
        }
        return await listModels(for: profile, force: true)
    }

    /// Persists a per-chat override and remembers it for new chats using this connection.
    func setModel(_ value: String?, for chatID: String) async {
        let normalized = TurnOverrides.normalizedModel(value)
        if value != nil && normalized == nil { error = "Enter a model alias of 1 to 200 printable characters."; return }
        guard let chat = record(chatID) else { return }
        let profile = profiles.first { $0.id == chat.profileID }
        await updateOverrides(chatID) { [self] selected in applyModelChoice(normalized, to: &selected, profile: profile) }
    }
    /// Applies a model choice to a chat against its connection: catalog limits
    /// for a listed model, connection defaults otherwise, and an effort the
    /// effective model offers. Shared by the model pill and the connection switch.
    func applyModelChoice(_ normalized: String?, to selected: inout ChatRecord, profile: ProfileRecord?) {
        let descriptor = profile.flatMap { catalogEntry(for: $0).descriptor(for: normalized ?? $0.modelId) }
        selected.model = normalized
        selected.contextWindow = nil; selected.maxOutputTokens = nil; selected.modelOutputLimit = nil; selected.outputBudgetVersion = 1
        if normalized != nil, let profile, let descriptor, descriptor.contextWindow != nil || descriptor.maxOutputTokens != nil {
            let effective = descriptor.applying(to: profile)
            selected.contextWindow = effective.contextWindow; selected.maxOutputTokens = effective.maxOutputTokens
            selected.modelOutputLimit = effective.modelOutputLimit
        }
        let effectiveEffort = selected.thinkingLevel ?? profile?.configuration["thinkingLevel"]?.string
        if let efforts = descriptor?.reasoning {
            if efforts.isEmpty || effectiveEffort.map({ $0 != "default" && !efforts.contains($0) }) == true {
                selected.thinkingLevel = ThinkingLevel.default.rawValue
            }
        }
    }
    /// nil or `profile-default` restores the profile; `default` leaves effort unspecified.
    func setThinkingLevel(_ value: String?, for chatID: String) async {
        let normalized = TurnOverrides.normalizedThinkingLevel(value)
        if let value, value != ThinkingLevel.profileDefault.rawValue, normalized == nil { error = "Unknown reasoning level “\(value)”."; return }
        await updateOverrides(chatID) { $0.thinkingLevel = normalized }
    }
    private func updateOverrides(_ chatID: String, _ change: @escaping @MainActor (inout ChatRecord) -> Void) async {
        guard let profileID = record(chatID)?.profileID else { return }
        // Serialize across a connection, including choices made in different
        // panes. The last accepted choice must also win for future chats.
        let previous = overrideWrites[profileID]?.task, token = UUID()
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.persistOverrides(chatID, change)
        }
        overrideWrites[profileID] = (token, task)
        await task.value
        if overrideWrites[profileID]?.token == token { overrideWrites[profileID] = nil }
    }
    private func persistOverrides(_ chatID: String, _ change: @MainActor (inout ChatRecord) -> Void) async {
        if let index = chats.firstIndex(where: { $0.id == chatID }) {
            let previous = chats[index]
            var updated = previous; change(&updated)
            do {
                guard let store else { throw StoreError.unavailable }
                // Re-selecting an unchanged option still makes this chat's
                // model/effort the next-chat choice, without modifying its peers.
                // A chat that has not sent anything yet records only the choice.
                if pendingChatIDs.contains(chatID) { try await store.put(ChatModelDefaults(chat: updated), kind: ChatModelDefaults.recordKind, id: updated.profileID) }
                else { try await store.saveChatModelChoice(updated) }
                if let current = chats.firstIndex(where: { $0.id == chatID }) {
                    chats[current].model = updated.model; chats[current].thinkingLevel = updated.thinkingLevel
                    chats[current].contextWindow = updated.contextWindow; chats[current].maxOutputTokens = updated.maxOutputTokens
                    chats[current].modelOutputLimit = updated.modelOutputLimit; chats[current].outputBudgetVersion = updated.outputBudgetVersion
                }
            } catch {
                self.error = "The model choice could not be saved. \(error.localizedDescription)"
            }
        } else if let info = side(chatID) {
            var chat = info.chat; change(&chat)
            do {
                guard let store else { throw StoreError.unavailable }
                try await store.put(ChatModelDefaults(chat: chat), kind: ChatModelDefaults.recordKind, id: chat.profileID)
                guard sides[info.parentID]?.id == chatID else { return }
                sides[info.parentID]?.model = chat.model; sides[info.parentID]?.thinkingLevel = chat.thinkingLevel
                sides[info.parentID]?.contextWindow = chat.contextWindow; sides[info.parentID]?.maxOutputTokens = chat.maxOutputTokens
                sides[info.parentID]?.modelOutputLimit = chat.modelOutputLimit; sides[info.parentID]?.outputBudgetVersion = chat.outputBudgetVersion
            } catch {
                self.error = "The model choice could not be saved. \(error.localizedDescription)"
            }
        }
    }
    /// Loads the discovered model list for a profile through the shared catalog.
    @discardableResult
    func listModels(for profile: ProfileRecord, force: Bool = false) async -> [String] {
        guard profile.api == LiteLLMConfiguration.supportedAPI else { return [] }
        let profile = catalogProfile(for: profile)
        return await modelCatalog.load(profile: profile, force: force) { [weak self] in
            guard let self else { throw HostError.failure("The project is closing.") }
            let credential = try await self.credentials(for: profile)
            let key = credential["apiKey"]?.string ?? ""
            guard GatewayModelDiscovery.validKey(key) else { throw GatewayModelDiscovery.Failure.credential }
            return key
        }
    }
}
