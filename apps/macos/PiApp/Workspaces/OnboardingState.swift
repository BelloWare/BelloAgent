import Foundation
import Combine

/// Keeps the first-run transaction alive until a chat has actually been saved.
/// Form edits and its profile identity survive failures and repeated saves.
@MainActor final class OnboardingState: ObservableObject {
    enum Step: Int { case gateway, model, workspace }
    @Published var step = Step.gateway
    @Published var profile: ProfileRecord
    @Published var key = ""
    @Published private(set) var message = ""
    @Published private(set) var saving = false
    @Published private(set) var finishing = false
    @Published private(set) var testingConnection = false
    @Published private(set) var completed = false
    @Published private(set) var models: [String] = []
    /// Rich entries when the connection's catalog endpoint answered.
    @Published private(set) var descriptors: [ModelDescriptor] = []
    @Published private(set) var listing = false
    @Published private(set) var listError = ""
    private var resumed = false
    private var storedProfile: ProfileRecord?
    private var discoveryGeneration = UUID()
    private typealias Listing = (models: [String], descriptors: [ModelDescriptor], note: String)
    private var discoveryTask: Task<Listing, Error>?
    private var finishTask: Task<Void, Error>?

    init() {
        var profile = ProfileRecord()
        profile.name = "LiteLLM"
        profile.maxOutputTokens = 8192
        profile.advancedJSON = "{\"routing\":{\"replayPolicy\":\"portable\"}}"
        self.profile = profile
    }

    static func shouldPresent(configurationLoaded: Bool, hasProfiles: Bool, hasChats: Bool) -> Bool {
        configurationLoaded && (!hasProfiles || !hasChats)
    }

    var busy: Bool { saving || finishing }
    var hasStoredKey: Bool { storedProfile?.baseUrl == profile.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines) }
    var gatewayReady: Bool {
        (try? GatewayModelDiscovery.modelsURL(base: profile.baseUrl, api: profile.api)) != nil &&
        (GatewayModelDiscovery.validKey(key) || key.isEmpty && hasStoredKey)
    }

    func resume(profiles: [ProfileRecord], preferredID: String) {
        guard !resumed else { return }
        resumed = true
        let supported = profiles.filter { $0.api == LiteLLMConfiguration.supportedAPI }
        if let saved = supported.first(where: { $0.id == preferredID }) ?? supported.first {
            profile = saved; storedProfile = saved; step = .workspace
        }
    }

    func invalidateModelList() {
        discoveryGeneration = UUID()
        discoveryTask?.cancel(); discoveryTask = nil
        models = []; descriptors = []; listError = ""; listing = false
    }

    /// Applies catalog capacity and ceiling without increasing the configured output budget.
    func choose(_ descriptor: ModelDescriptor) {
        profile = descriptor.applying(to: profile)
    }

    func listModels(catalog: @escaping @Sendable (URL, String) async throws -> [ModelDescriptor] = { url, key in
        try await ModelCatalogEndpoint().fetch(url: url, key: key)
    }, bundled: @escaping @Sendable () throws -> [ModelDescriptor] = {
        try ModelCatalogEndpoint.bundled()
    }) async {
        invalidateModelList()
        guard profile.api == LiteLLMConfiguration.supportedAPI else { listError = LiteLLMConfiguration.unsupportedAPIMessage; return }
        let generation = discoveryGeneration
        let base = profile.baseUrl, api = profile.api, credential = key, catalogValue = profile.catalogUrl
        let catalogURL = profile.catalogUrl.flatMap { try? ModelCatalogEndpoint.url($0) }
        if ModelCatalog.catalogConfigured(profile), catalogURL == nil {
            listError = ModelCatalogEndpoint.Failure.url.localizedDescription + " Fix the catalog URL or enter the alias manually."
            return
        }
        if let catalogURL, ModelCatalogEndpoint.usesGatewayCredential(catalogURL, base: base, api: api),
           !GatewayModelDiscovery.validKey(credential) {
            listError = "Re-enter the gateway key to refresh this custom catalog, or enter the model alias manually."
            return
        }
        listing = true
        let task = Task<Listing, Error> {
            // A configured catalog is the only source; the gateway list is never
            // consulted for it, so a catalog failure surfaces as an error.
            if let catalogURL {
                let catalogKey = ModelCatalogEndpoint.usesGatewayCredential(catalogURL, base: base, api: api) ? credential : ""
                let found = try await catalog(catalogURL, catalogKey)
                return (found.filter { !$0.deprecated }.map(\.id), found, "")
            }
            try Task.checkCancellation()
            let found = try bundled()
            return (found.filter { !$0.deprecated }.map(\.id), found, "")
        }
        discoveryTask = task
        defer {
            if generation == discoveryGeneration { listing = false; discoveryTask = nil }
        }
        do {
            let found = try await task.value
            guard generation == discoveryGeneration, base == profile.baseUrl, api == profile.api, credential == key, catalogValue == profile.catalogUrl else { return }
            models = found.models; descriptors = found.descriptors; listError = found.note
            if found.models.isEmpty { listError += (listError.isEmpty ? "" : " ") + "No available models were listed. Enter the alias manually." }
            else if profile.modelId.isEmpty, let first = found.descriptors.first(where: { !$0.deprecated }) { choose(first) }
            else if profile.modelId.isEmpty, found.models.count == 1 { profile.modelId = found.models[0] }
        } catch is CancellationError { }
        catch {
            guard generation == discoveryGeneration, base == profile.baseUrl, api == profile.api, credential == key, catalogValue == profile.catalogUrl else { return }
            // Only locally authored errors are shown. A transport/server error
            // may contain request details or echo a credential in its message.
            let detail = (error as? GatewayModelDiscovery.Failure)?.localizedDescription ?? (error as? ModelCatalogEndpoint.Failure)?.localizedDescription ?? "Couldn't list models."
            listError = detail + " Enter the alias manually."
        }
    }

    @discardableResult
    func save(using persist: @MainActor (ProfileRecord, String) async throws -> ProfileRecord) async -> Bool {
        guard !busy, !completed else { return false }
        saving = true; message = ""
        defer { saving = false }
        var candidate = profile
        candidate.name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.name.isEmpty { candidate.name = "LiteLLM" }
        candidate.baseUrl = candidate.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.modelId = candidate.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try LiteLLMConfiguration.validateForRequests(candidate, headers: [:])
            guard GatewayModelDiscovery.validKey(key) || key.isEmpty && storedProfile?.baseUrl == candidate.baseUrl else {
                throw VaultError.invalid("Enter an API key for this gateway before saving the connection.")
            }
            let saved = try await persist(candidate, key)
            profile = saved; storedProfile = saved; key = ""
            invalidateModelList()
            step = .workspace; message = "Saved in the configuration vault. Choose a trusted project to continue."
            return true
        } catch { message = error.localizedDescription; return false }
    }

    @discardableResult
    func finish(hasTrustedWorkspace: Bool,
                verifyConnection: @escaping @MainActor (ProfileRecord) async throws -> Void,
                createChat: @escaping @MainActor () async throws -> Void) async -> Bool {
        guard !busy, !completed else { return false }
        guard hasTrustedWorkspace, storedProfile == profile, key.isEmpty else {
            message = "Save a connection and choose a trusted project before starting a chat."
            return false
        }
        let candidate = profile
        finishing = true; testingConnection = true; message = ""
        let task = Task { @MainActor in
            do { try await verifyConnection(candidate) }
            catch let error as ConnectionProbeError { throw error }
            catch is CancellationError { throw ConnectionProbeError.cancelled }
            catch { throw ConnectionProbeError.failed("Couldn't verify this connection. Check the gateway URL, key and selected model, then test again.") }
            try Task.checkCancellation()
            guard self.profile == candidate, self.storedProfile == candidate, self.key.isEmpty else { throw ConnectionProbeError.changed }
            self.testingConnection = false
            try await createChat()
        }
        finishTask = task
        defer { finishing = false; testingConnection = false; finishTask = nil }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            completed = true; return true
        } catch is CancellationError { message = ConnectionProbeError.cancelled.localizedDescription; return false }
        catch { message = error.localizedDescription; return false }
    }

    func cancelConnectionTest() { if testingConnection { finishTask?.cancel() } }
}
