import Foundation
import Security

enum VaultError: LocalizedError, Equatable {
    case denied(Int32), corrupt, conflict, busy, invalid(String), unsigned
    var errorDescription: String? {
        switch self {
        case .denied(let status): "Configuration Keychain access is locked or denied (\(status)). Unlock it and retry; saved data was not replaced."
        case .corrupt: "The configuration vault is corrupt or has an unsupported version. It was not replaced with defaults."
        case .conflict: "Settings changed in another operation. Reload them before saving."
        case .busy: "Another app instance is updating the configuration vault. Retry after it finishes."
        case .invalid(let reason): reason
        case .unsigned: "Configuration requires the signed Bello Agent. This build cannot access the production vault."
        }
    }
}

struct VaultProfile: Codable, Sendable, Equatable {
    var profile: ProfileRecord
    var apiKey: String
    var headers: [String: String] = [:]
}
struct RuntimePreferences: Codable, Sendable, Equatable {
    /// Kept for stored configurations; the app no longer limits how many projects run at once.
    var workspaceConcurrency = 2
    var idleGraceSeconds = 120
    var toolsPATH = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
}
struct CapturePreferences: Codable, Sendable, Equatable {
    /// Versioned separately from the vault so inherited pre-0.1.5 defaults can
    /// migrate once without changing a subsequently chosen Off or seven days.
    var policyVersion = 1
    var defaultMode = "persist"
    var sessionModes: [String: String] = [:]
    var sessionSince: [String: String] = [:]
    // Compatibility field only. Capture no longer requires a reveal/consent gate.
    var disclosureAccepted = true
    var quotaBytes: Int64 = 1_073_741_824
    var retentionDays = 30

    init() {}
    private enum CodingKeys: String, CodingKey {
        case policyVersion, defaultMode, sessionModes, sessionSince, disclosureAccepted, quotaBytes, retentionDays
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .policyVersion)
        guard version == nil || version == 1 else { throw VaultError.corrupt }
        defaultMode = try values.decodeIfPresent(String.self, forKey: .defaultMode) ?? "off"
        sessionModes = try values.decodeIfPresent([String: String].self, forKey: .sessionModes) ?? [:]
        sessionSince = try values.decodeIfPresent([String: String].self, forKey: .sessionSince) ?? [:]
        disclosureAccepted = try values.decodeIfPresent(Bool.self, forKey: .disclosureAccepted) ?? false
        quotaBytes = try values.decodeIfPresent(Int64.self, forKey: .quotaBytes) ?? 1_073_741_824
        retentionDays = try values.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 7
        if version == nil {
            // Old versions did not distinguish an untouched Off from an Off
            // deliberately selected before ever enabling capture. Only this
            // exact legacy default tuple adopts the new mode; explicit session
            // overrides, prior disclosure, or a custom quota/retention survive.
            if defaultMode == "off", !disclosureAccepted,
               quotaBytes == 1_073_741_824, retentionDays == 7 { defaultMode = "persist" }
            if retentionDays == 7 { retentionDays = 30 }
        }
    }
}
struct DashboardPreferences: Codable, Sendable, Equatable {
    var windowHours = 24
    var status = "completed"
    var metricRetentionDays = 90
    var workspaceID: String?
    var sessionID: String?
    var purpose: String?
    var api: String?
    var requestedAlias: String?
    var effectiveModel: String?
    var unreportedModelOnly: Bool?
    /// Time-range preset ("1h", "6h", "24h", "7d", "30d" or "custom"). Absent
    /// in older records, where `windowHours` alone describes the window.
    var windowPreset: String?
    /// Explicit bounds used only when `windowPreset == "custom"`.
    var customFrom: Date?
    var customUntil: Date?
}
struct VaultConfiguration: Codable, Sendable, Equatable {
    var schema = 1
    var revision: Int64 = 0
    var profiles: [VaultProfile] = []
    /// A model list can follow a saved catalog independently of the connection
    /// used for requests. Flat references only; absent in pre-0.1.14 vaults.
    var catalogSources: [String: String]?
    var workspaces: [WorkspaceRecord] = []
    var resources: [String: WireValue] = [:]
    /// Bello Agent's global skill switches; absent in older vaults. These never
    /// write shared SKILL.md, agents/openai.yaml or Codex configuration files.
    var disabledSkills: [String]?
    var mcp: [String: WireValue] = [:]
    var runtime = RuntimePreferences()
    var capture = CapturePreferences()
    var dashboard = DashboardPreferences()
    var automaticUpdateChecks = true
    // Existing keys remain for reading legacy encrypted captures only. New
    // vaults and new plaintext captures need no payload key. Helpers never
    // receive this object or a legacy key.
    var captureKey = Data()

    func resourceOptions(workspaceID: String, defaultCodexHome: String) -> [String: WireValue] {
        var options = resources[workspaceID]?.object ?? ["codexHome":.string(defaultCodexHome)]
        // Keep per-project policies and Codex restrictions. A global switch can
        // add a restriction; re-enabling cannot remove restrictions elsewhere.
        let disabled = Set(options["disabled"]?.array?.compactMap(\.string) ?? []).union(disabledSkills ?? [])
        if !disabled.isEmpty { options["disabled"] = .array(disabled.sorted().map(WireValue.string)) }
        return options
    }

    func validate(persisted: Bool = true) throws {
        guard schema == 1, revision >= 0, !persisted || captureKey.isEmpty || captureKey.count == 32 else { throw VaultError.corrupt }
        guard profiles.count <= 128, workspaces.count <= 1000,
              Set(profiles.map { $0.profile.id }).count == profiles.count,
              Set(workspaces.map(\.id)).count == workspaces.count,
              (1...4).contains(runtime.workspaceConcurrency), (10...600).contains(runtime.idleGraceSeconds),
              !runtime.toolsPATH.isEmpty, runtime.toolsPATH.utf8.count <= 8192,
              capture.policyVersion == 1, ["off", "memory", "persist"].contains(capture.defaultMode),
              capture.sessionModes.values.allSatisfy({ ["off", "memory", "persist"].contains($0) }),
              (1_048_576...10_737_418_240).contains(capture.quotaBytes), (1...365).contains(capture.retentionDays),
              (1...8760).contains(dashboard.windowHours), (1...3650).contains(dashboard.metricRetentionDays),
              ["completed", "failed", "cancelled", "running", "truncated", "interrupted", "all"].contains(dashboard.status),
              [dashboard.workspaceID, dashboard.sessionID].allSatisfy({ ($0?.utf8.count ?? 0) <= 128 }),
              [dashboard.purpose, dashboard.api, dashboard.requestedAlias, dashboard.effectiveModel].allSatisfy({ ($0?.utf8.count ?? 0) <= 256 }),
              dashboard.windowPreset.map({ DashboardWindowPreset(rawValue: $0) != nil }) ?? true,
              DashboardWindowPreset.customBoundsValid(from: dashboard.customFrom, until: dashboard.customUntil, required: dashboard.windowPreset == DashboardWindowPreset.custom.rawValue) else {
            throw VaultError.invalid("Configuration limits or identifiers are invalid.")
        }
        for value in profiles {
            guard value.profile.providerId == "litellm", !value.profile.isImported,
                  !value.apiKey.isEmpty, value.apiKey.utf8.count <= 16_384,
                  !value.apiKey.utf8.contains(where: { $0 < 32 || $0 == 127 }),
                  value.headers.count <= 64 else { throw VaultError.invalid("Save an explicit LiteLLM endpoint and API key. External credential references are unsupported.") }
            try LiteLLMConfiguration.validate(value.profile, headers: value.headers)
        }
        if let catalogSources {
            let ids = Set(profiles.map { $0.profile.id })
            guard catalogSources.count <= 128, catalogSources.allSatisfy({ route, source in
                route != source && ids.contains(route) && ids.contains(source) && catalogSources[source] == nil &&
                profiles.first(where: { $0.profile.id == source })?.profile.api == LiteLLMConfiguration.supportedAPI
            }) else { throw VaultError.invalid("Model catalog sources must reference saved Responses connections without chains or cycles.") }
        }
        for options in resources.values {
            guard options.object != nil, options.object?["mcpConfigPath"] == nil, options.object?["mcpConfigSHA256"] == nil,
                  try JSONEncoder().encode(options).count <= 262_144 else { throw VaultError.invalid("Discovery settings must contain source references, not MCP configuration files.") }
        }
        if let disabledSkills {
            guard disabledSkills.count <= 512, Set(disabledSkills).count == disabledSkills.count,
                  disabledSkills.allSatisfy({ $0.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil }) else {
                throw VaultError.invalid("Skill switches must identify up to 512 discovered skills.")
            }
        }
        for config in mcp.values {
            guard let object = config.object, Set(object.keys) == ["servers"], let servers = object["servers"]?.object,
                  servers.count <= 32, try JSONEncoder().encode(config).count <= 262_144 else { throw VaultError.invalid("MCP configuration must contain up to 32 servers and fit within 256 KiB.") }
            try MCPConfiguration.validate(servers)
        }
    }
}

// This interface is injected only by tests. The application always uses the
// Keychain implementation; no disk or per-profile fallback exists.
protocol VaultStorage: Sendable {
    func read() throws -> Data?
    func replace(expected: Data?, with replacement: Data) throws
}

actor ConfigurationVault {
    static let maximumBytes = 2_097_152
    static let shared = ConfigurationVault(storage: KeychainVaultStorage())
    private let storage: any VaultStorage
    private let worker = KeychainWorker()
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(storage: any VaultStorage) { self.storage = storage }
    private func acquire() async throws {
        if !occupied { occupied = true; return }
        guard waiters.count < 32 else { throw VaultError.busy }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { occupied = false } else { waiters.removeFirst().resume() }
    }
    static func decode(_ data: Data?) throws -> VaultConfiguration {
        guard let data else { return VaultConfiguration() }
        guard data.count <= maximumBytes else { throw VaultError.corrupt }
        // validate() explains exactly which field a newer build wrote that this
        // one rejects. Collapsing that into "corrupt" told a user who had just
        // downgraded that their settings were damaged, with no clue what to fix.
        do { let value = try JSONDecoder().decode(VaultConfiguration.self, from: data); try value.validate(); return value }
        catch let error as VaultError { throw error }
        catch { throw VaultError.corrupt }
    }
    func load() async throws -> VaultConfiguration {
        try await acquire(); defer { release() }
        let storage = storage
        return try await worker.perform { try Self.decode(storage.read()) }
    }
    func update(expectedRevision: Int64, _ change: @escaping @Sendable (inout VaultConfiguration) throws -> Void) async throws -> VaultConfiguration {
        try await acquire(); defer { release() }
        let storage = storage
        return try await worker.perform {
            let previous = try storage.read()
            var value = try Self.decode(previous)
            guard value.revision == expectedRevision, expectedRevision < Int64.max else { throw VaultError.conflict }
            let key = value.captureKey
            try change(&value)
            guard value.captureKey == key, value.schema == 1 else { throw VaultError.invalid("The legacy capture key must be preserved so existing encrypted history remains readable.") }
            value.revision = expectedRevision + 1
            try value.validate()
            let encoded = try JSONEncoder().encode(value)
            guard encoded.count <= Self.maximumBytes else { throw VaultError.invalid("Configuration exceeds the 2 MiB vault limit.") }
            try storage.replace(expected: previous, with: encoded)
            return value
        }
    }
}

enum LiteLLMConfiguration {
    static let supportedAPI = "openai-responses"
    static let unsupportedAPIMessage = "Only the Responses API is supported for new requests. Existing Messages history and credentials are preserved. Create a Responses connection in Settings to continue."
    static func requireSupportedAPI(_ api: String) throws {
        guard api == supportedAPI else { throw VaultError.invalid(unsupportedAPIMessage) }
    }
    static func validateForRequests(_ profile: ProfileRecord, headers: [String: String]) throws {
        try requireSupportedAPI(profile.api)
        try validate(profile, headers: headers)
    }
    // Retain validation for saved Messages connections so loading or changing
    // unrelated vault preferences never discards legacy credentials/history.
    static func endpoint(_ value: String, api: String) throws -> URL {
        guard ["openai-responses", "anthropic-messages"].contains(api),
              !value.contains(where: \.isWhitespace), var parts = URLComponents(string: value),
              let host = parts.host, !host.isEmpty, ["http", "https"].contains(parts.scheme),
              parts.scheme == "https" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              !parts.percentEncodedPath.lowercased().contains("%2f"), !parts.percentEncodedPath.lowercased().contains("%2e") else {
            throw VaultError.invalid("Use a LiteLLM HTTPS URL, or explicit loopback HTTP, without credentials, query, fragment or encoded path separators.")
        }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        let leaf = api == "openai-responses" ? "/responses" : "/messages"
        let fullRoute = path.hasSuffix(leaf)
        if fullRoute { path.removeLast(leaf.count) }
        guard !path.hasSuffix("/responses"), !path.hasSuffix("/messages"), !path.hasSuffix("/completions"),
              !path.contains("//"), !path.contains("/v1/v1"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw VaultError.invalid("The LiteLLM URL contains an incompatible or repeated API route.")
        }
        if !fullRoute && !path.hasSuffix("/v1") { path += "/v1" }
        parts.path = path + leaf
        guard let endpoint = parts.url else { throw VaultError.invalid("Invalid LiteLLM endpoint.") }
        return endpoint
    }
    static func validate(_ profile: ProfileRecord, headers: [String: String]) throws {
        _ = try endpoint(profile.baseUrl, api: profile.api)
        guard !profile.modelId.isEmpty, profile.modelId.utf8.count <= 256,
              !profile.modelId.utf8.contains(where: { $0 < 32 || $0 == 127 }),
              profile.maxOutputTokens > 0, profile.maxOutputTokens <= 1_000_000,
              profile.contextWindow > profile.maxOutputTokens, profile.contextWindow <= 10_000_000 else { throw VaultError.invalid("Set a model alias, a context capacity of at most 10,000,000 tokens and an output budget below it.") }
        // The budget is a local reserve; the catalog ceiling is what requests carry. Either may be the larger.
        if let ceiling = profile.modelOutputLimit {
            guard ceiling > 0, ceiling <= 1_000_000 else { throw VaultError.invalid("The model output ceiling must be between 1 and 1,000,000 tokens.") }
        }
        if let mini = profile.miniModelId {
            guard !mini.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  mini == mini.trimmingCharacters(in: .whitespacesAndNewlines), mini.utf8.count <= 200,
                  !mini.utf8.contains(where: { $0 < 32 || $0 == 127 }) else {
                throw VaultError.invalid("Choose a mini model alias of 1 to 200 UTF-8 bytes without surrounding whitespace or control characters.")
            }
        }
        let forbidden: Set<String> = ["host", "content-length", "transfer-encoding", "connection", "authorization", "x-api-key"]
        guard headers.allSatisfy({ name, value in
            !forbidden.contains(name.lowercased()) && name.range(of: "^[A-Za-z0-9-]{1,128}$", options: .regularExpression) != nil &&
            !value.utf8.contains(where: { $0 < 32 || $0 == 127 }) && value.utf8.count <= 16_384
        }) else { throw VaultError.invalid("Headers must be bounded strings. Transport and authentication headers are managed by the LiteLLM connection.") }
        if let advanced = profile.advancedJSON {
            let allowed: Set<String> = ["reasoning", "thinkingLevel", "thinkingLevelMap", "input", "cost", "samplingParams", "compat", "routing"]
            guard advanced.utf8.count <= 65_536, let value = try? JSONDecoder().decode(WireValue.self, from: Data(advanced.utf8)),
                  let fields = value.object, Set(fields.keys).isSubset(of: allowed) else {
                throw VaultError.invalid("Advanced model settings contain unsupported fields. Credentials and external references belong only in the vault connection fields.")
            }
            try RoutingConfiguration.validate(fields["routing"])
        }
    }
}

enum MCPConfiguration {
    static func validate(_ servers: [String: WireValue]) throws {
        let allowed: Set<String> = ["enabled", "transport", "command", "args", "env", "url", "headers", "allowedTools", "timeoutSeconds"]
        func bounded(_ value: WireValue?) -> Bool {
            guard let text = value?.string else { return false }
            return text.utf8.count <= 16_384 && !text.utf8.contains(0)
        }
        for (name, value) in servers {
            guard name.range(of: "^[A-Za-z0-9_:-][A-Za-z0-9._:-]{0,127}$", options: .regularExpression) != nil,
                  let fields = value.object, Set(fields.keys).isSubset(of: allowed),
                  fields["enabled"] == nil || fields["enabled"]?.bool != nil else { throw VaultError.invalid("Invalid MCP server name, fields or enabled value.") }
            for field in ["args", "allowedTools"] where fields[field] != nil {
                guard let values = fields[field]?.array, values.count <= 256, values.allSatisfy({ bounded($0) }) else { throw VaultError.invalid("MCP arrays require up to 256 bounded strings.") }
            }
            for field in ["env", "headers"] where fields[field] != nil {
                guard let values = fields[field]?.object, values.count <= 64, values.allSatisfy({ key, value in
                    key.range(of: field == "env" ? "^[A-Za-z_][A-Za-z0-9_]{0,127}$" : "^[A-Za-z0-9-]{1,128}$", options: .regularExpression) != nil && bounded(value) &&
                    (field != "headers" || (!value.string!.utf8.contains(where: { $0 < 32 || $0 == 127 }) && !["host", "content-length", "transfer-encoding", "connection"].contains(key.lowercased())))
                }) else { throw VaultError.invalid("MCP environment and headers must be explicit bounded strings; inherited credential references are unsupported.") }
            }
            if let timeout = fields["timeoutSeconds"] { guard let number = timeout.number, number.rounded() == number, (1...300).contains(number) else { throw VaultError.invalid("MCP timeout must be 1–300 seconds.") } }
            if fields["enabled"]?.bool == false { continue }
            let transport = fields["transport"]?.string ?? (fields["url"] == nil ? "stdio" : "http")
            if transport == "stdio" {
                guard bounded(fields["command"]), fields["command"]?.string?.isEmpty == false, fields["url"] == nil else { throw VaultError.invalid("A stdio MCP server needs an explicit command and no HTTP URL.") }
            } else if transport == "http" {
                guard let text = fields["url"]?.string, !text.contains(where: \.isWhitespace), let url = URLComponents(string: text), let host = url.host, !host.isEmpty,
                      url.scheme == "https" || url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
                      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, fields["command"] == nil else { throw VaultError.invalid("HTTP MCP servers require HTTPS or loopback HTTP without URL credentials, query or fragment.") }
            } else { throw VaultError.invalid("MCP supports stdio or HTTP transport.") }
        }
    }
}
