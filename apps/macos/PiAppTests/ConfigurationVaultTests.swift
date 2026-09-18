import XCTest
@testable import PiApp

final class MemoryVaultStorage: VaultStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    private var error: VaultError?
    private(set) var writes = 0
    init(_ bytes: Data? = nil, error: VaultError? = nil) { self.bytes = bytes; self.error = error }
    func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; if let error { throw error }; return bytes }
    func replace(expected: Data?, with replacement: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if let error { throw error }
        guard bytes == expected else { throw VaultError.conflict }
        bytes = replacement; writes += 1
    }
}

final class ConfigurationVaultTests: XCTestCase {
    func testNewCaptureDefaultsPersistBodiesForThirtyDaysWithoutDisclosure() async throws {
        let storage = MemoryVaultStorage(), vault = ConfigurationVault(storage: storage)
        let value = try await vault.load()
        XCTAssertEqual(value.capture.defaultMode, "persist")
        XCTAssertEqual(value.capture.retentionDays, 30)
        XCTAssertEqual(value.capture.policyVersion, 1)
        XCTAssertEqual(storage.writes, 0, "Reading defaults must not create or replace a Keychain item")
        let restored = try JSONDecoder().decode(CapturePreferences.self, from: JSONEncoder().encode(value.capture))
        XCTAssertEqual(restored, value.capture)
    }

    func testLegacyCaptureDefaultsMigrateWithoutDiscardingSessionOverridesOrVaultIdentity() async throws {
        var original = VaultConfiguration(); original.revision = 8; original.captureKey = Data(repeating: 7, count: 32)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        raw["capture"] = ["defaultMode": "off", "retentionDays": 7, "disclosureAccepted": false,
                          "quotaBytes": 1_073_741_824, "sessionModes": ["private": "off", "temporary": "memory"],
                          "sessionSince": ["private": "2026-09-15T00:00:00Z"]]
        let storage = MemoryVaultStorage(try JSONSerialization.data(withJSONObject: raw)), vault = ConfigurationVault(storage: storage)
        let migrated = try await vault.load()
        XCTAssertEqual(migrated.revision, 8); XCTAssertEqual(migrated.captureKey, original.captureKey)
        XCTAssertEqual(migrated.capture.defaultMode, "persist"); XCTAssertEqual(migrated.capture.retentionDays, 30)
        XCTAssertEqual(migrated.capture.sessionModes, ["private": "off", "temporary": "memory"])
        XCTAssertEqual(migrated.capture.sessionSince["private"], "2026-09-15T00:00:00Z")
        XCTAssertEqual(storage.writes, 0, "Migration is an in-memory interpretation until the next normal vault save")
        let saved = try await vault.update(expectedRevision: 8) { $0.runtime.idleGraceSeconds = 60 }
        XCTAssertEqual(saved.capture, migrated.capture); XCTAssertEqual(saved.revision, 9)
        let reloaded = try await vault.load()
        XCTAssertEqual(reloaded.capture, migrated.capture); XCTAssertEqual(storage.writes, 1)
    }

    func testDistinguishableLegacyCaptureChoicesAndNewOffOrSevenDaysRemainExplicit() throws {
        func legacy(_ mode: String, days: Int = 7, accepted: Bool = false, quota: Int64 = 1_073_741_824) throws -> CapturePreferences {
            let object: [String: Any] = ["defaultMode": mode, "retentionDays": days, "disclosureAccepted": accepted, "quotaBytes": quota]
            return try JSONDecoder().decode(CapturePreferences.self, from: JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertEqual(try legacy("off", accepted: true).defaultMode, "off", "A prior enabled capture followed by Off stays off")
        XCTAssertEqual(try legacy("off", days: 14).defaultMode, "off")
        XCTAssertEqual(try legacy("off", days: 14).retentionDays, 14)
        XCTAssertEqual(try legacy("off", quota: 2_097_152).defaultMode, "off")
        XCTAssertEqual(try legacy("memory", accepted: true).defaultMode, "memory")
        XCTAssertEqual(try legacy("persist", accepted: true).retentionDays, 30)
        for mode in ["off", "memory", "persist"] {
            var selected = CapturePreferences(); selected.defaultMode = mode; selected.retentionDays = 7
            selected.disclosureAccepted = false
            let reloaded = try JSONDecoder().decode(CapturePreferences.self, from: JSONEncoder().encode(selected))
            XCTAssertEqual(reloaded, selected, "Versioned choices must never be silently migrated again")
        }
    }

    func testFutureCapturePolicyIsRejectedInsteadOfReplacedWithDefaults() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(CapturePreferences.self, from: Data("{\"policyVersion\":2}".utf8)))
    }

    func testLegacyMessagesVaultLoadsAndPreferenceEditsPreserveItsCredentials() async throws {
        var profile = ProfileRecord(); profile.api = "anthropic-messages"; profile.baseUrl = "https://gateway.example/v1/messages"; profile.modelId = "legacy-router"
        let connection = VaultProfile(profile: profile, apiKey: "synthetic-legacy-key", headers: ["X-Team": "fixture"])
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [connection] }
        let loaded = try await vault.load()
        XCTAssertEqual(loaded.profiles, [connection])
        let updated = try await vault.update(expectedRevision: loaded.revision) { $0.automaticUpdateChecks = false }
        XCTAssertEqual(updated.profiles, [connection], "Unrelated preferences must not migrate or discard legacy connections")
        XCTAssertThrowsError(try LiteLLMConfiguration.validateForRequests(profile, headers: connection.headers)) {
            XCTAssertTrue($0.localizedDescription.contains("Only the Responses API"))
        }
        XCTAssertNoThrow(try LiteLLMConfiguration.validate(profile, headers: connection.headers), "Retained vault validation stays compatible")
    }

    @MainActor func testLegacyMessagesCannotStartWorkAndExplicitResponsesCopyPreservesOriginal() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PI_APP_SCRATCH_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceRecord(id: "fixture", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.api = "anthropic-messages"; profile.baseUrl = "https://gateway.example/v1/messages"; profile.modelId = "legacy-router"
        let original = VaultProfile(profile: profile, apiKey: "synthetic-preserved-key", headers: ["X-Team": "fixture"])
        let storage = MemoryVaultStorage(), vault = ConfigurationVault(storage: storage)
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [original]; $0.workspaces = [workspace] }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        model.selectedWorkspaceID = workspace.id; model.profileChoice = profile.id
        let chat = ChatRecord(id: "legacy", workspaceID: workspace.id, title: "Old chat", path: nil, profileID: profile.id)
        do { _ = try await model.open(chat); XCTFail("Legacy API must be rejected before helper startup or HTTP") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Only the Responses API")) }
        XCTAssertTrue(model.hosts.isEmpty); XCTAssertTrue(model.opened.isEmpty)
        model.newChat(); XCTAssertTrue(model.chats.isEmpty); XCTAssertTrue(model.showProfiles)
        model.testConnection(profileID: profile.id)
        XCTAssertTrue(model.error?.contains("Only the Responses API") == true)
        do { try await model.saveProfile(profile, key: ""); XCTFail("New or edited connections must use Responses") } catch { }
        XCTAssertEqual(storage.writes, 1)

        // The owner's explicit switch does not reinterpret a Messages URL.
        var responses = profile; responses.api = "openai-responses"
        do { try await model.saveProfile(responses, key: ""); XCTFail("A Messages route is not a Responses endpoint") } catch { }
        XCTAssertEqual(storage.writes, 1)
        responses.baseUrl = "https://gateway.example/v1/responses"
        try await model.saveProfile(responses, key: "")
        let saved = try await vault.load()
        XCTAssertEqual(saved.profiles.count, 2)
        XCTAssertEqual(saved.profiles.first { $0.profile.id == original.profile.id }, original)
        let copy = try XCTUnwrap(saved.profiles.first { $0.profile.id != original.profile.id })
        XCTAssertEqual(copy.profile.api, "openai-responses"); XCTAssertEqual(copy.apiKey, original.apiKey); XCTAssertEqual(copy.headers, original.headers)
        XCTAssertEqual(model.requestProfiles.map(\.id), [copy.profile.id])
        XCTAssertEqual(model.profileChoice, copy.profile.id)
        try await model.traces.close(); await model.store?.close()
    }

    func testMCPAndAdvancedCredentialReferencesCannotBecomeSavedAuthorities() async throws {
        let storage = MemoryVaultStorage(), vault = ConfigurationVault(storage: storage)
        for server: WireValue in [
            .object(["command": .string("/usr/bin/true"), "inheritEnv": .array([.string("SECRET")])]),
            .object(["url": .string("https://gateway.example/mcp"), "headers": .object(["x-test": .string("value\r\ninjected")])]),
            .object(["transport": .string("stdio"), "command": .string("/usr/bin/true"), "url": .string("https://gateway.example/mcp")])
        ] {
            do { _ = try await vault.update(expectedRevision: 0) { $0.mcp["workspace"] = .object(["servers": .object(["fixture": server])]) }; XCTFail("Invalid MCP configuration") } catch { }
        }
        var profile = ProfileRecord(); profile.baseUrl = "https://gateway.example"; profile.modelId = "alias"
        for advanced in ["{\"apiKeyEnv\":\"SECRET\"}", "{\"source\":\"external-file\"}", "not JSON"] {
            profile.advancedJSON = advanced
            XCTAssertThrowsError(try LiteLLMConfiguration.validate(profile, headers: [:]))
        }
        XCTAssertEqual(storage.writes, 0)
    }
    func testMissingVaultCreatesOneItemOnlyOnExplicitSaveWithoutGeneratingPayloadKey() async throws {
        let storage = MemoryVaultStorage(), vault = ConfigurationVault(storage: storage)
        let missing = try await vault.load()
        XCTAssertEqual(missing.revision, 0); XCTAssertTrue(missing.captureKey.isEmpty); XCTAssertEqual(storage.writes, 0)
        let first = try await vault.update(expectedRevision: 0) { $0.runtime.workspaceConcurrency = 3 }
        XCTAssertTrue(first.captureKey.isEmpty); XCTAssertEqual(first.revision, 1)
        let second = try await vault.update(expectedRevision: 1) { $0.capture.defaultMode = "persist" }
        XCTAssertEqual(second.captureKey, first.captureKey); XCTAssertEqual(second.revision, 2)
        let restored = try await ConfigurationVault(storage: storage).load()
        XCTAssertEqual(restored, second); XCTAssertEqual(storage.writes, 2)
    }
    func testExistingCaptureKeyIsPreservedOnlyForLegacyHistory() async throws {
        var existing = VaultConfiguration(); existing.revision = 3; existing.captureKey = Data(repeating: 7, count: 32)
        let storage = MemoryVaultStorage(try JSONEncoder().encode(existing)), vault = ConfigurationVault(storage: storage)
        let updated = try await vault.update(expectedRevision: 3) { $0.capture.defaultMode = "persist" }
        XCTAssertEqual(updated.captureKey, existing.captureKey)
        do { _ = try await vault.update(expectedRevision: 4) { $0.captureKey = Data() }; XCTFail("Legacy history must not lose its key") } catch { }
        XCTAssertEqual(storage.writes, 1)
    }
    func testDeniedCorruptAndUnsupportedVaultsNeverFallBackOrWriteDefaults() async throws {
        let denied = MemoryVaultStorage(error: .denied(-25308))
        var future = VaultConfiguration(); future.schema = 2; future.captureKey = Data(repeating: 1, count: 32)
        for storage in [denied, MemoryVaultStorage(Data("not JSON".utf8)), MemoryVaultStorage(try JSONEncoder().encode(future))] {
            let vault = ConfigurationVault(storage: storage)
            do { _ = try await vault.load(); XCTFail("Unreadable vault must fail closed") } catch { XCTAssertTrue(error is VaultError) }
            do { _ = try await vault.update(expectedRevision: 0) { $0.runtime.workspaceConcurrency = 1 }; XCTFail("Must not overwrite") } catch { }
            XCTAssertEqual(storage.writes, 0)
        }
    }
    func testStaleAndConcurrentWritersCannotLoseAConfigurationChange() async throws {
        let storage = MemoryVaultStorage(), a = ConfigurationVault(storage: storage), b = ConfigurationVault(storage: storage)
        _ = try await a.update(expectedRevision: 0) { $0.runtime.idleGraceSeconds = 30 }
        do { _ = try await b.update(expectedRevision: 0) { $0.runtime.idleGraceSeconds = 60 }; XCTFail("Stale revision") }
        catch { XCTAssertEqual(error as? VaultError, .conflict) }
        let second = try await b.update(expectedRevision: 1) { $0.runtime.workspaceConcurrency = 4 }
        XCTAssertEqual(second.runtime.idleGraceSeconds, 30)
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for vault in [a, b] { group.addTask { do { _ = try await vault.update(expectedRevision: 2) { $0.runtime.idleGraceSeconds = 40 }; return true } catch { return false } } }
            var values: [Bool] = []; for await value in group { values.append(value) }; return values
        }
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let saved = try await a.load(); XCTAssertEqual(saved.revision, 3); XCTAssertEqual(storage.writes, 3)
    }
    func testInvalidChangesAndImplicitKeyRotationLeaveTheItemUnchanged() async throws {
        let storage = MemoryVaultStorage(), vault = ConfigurationVault(storage: storage)
        let first = try await vault.update(expectedRevision: 0) { _ in }
        do { _ = try await vault.update(expectedRevision: 1) { $0.runtime.workspaceConcurrency = 500 }; XCTFail("Invalid limits") } catch { }
        do { _ = try await vault.update(expectedRevision: 1) { $0.captureKey = Data(repeating: 9, count: 32) }; XCTFail("No implicit key rotation") } catch { }
        let after = try await vault.load(); XCTAssertEqual(after, first); XCTAssertEqual(storage.writes, 1)
    }
    func testLiteLLMEndpointNormalizationAndAuthenticationOwnership() throws {
        for (api, leaf) in [("openai-responses", "responses"), ("anthropic-messages", "messages")] {
            for input in ["https://gateway.example/proxy", "https://gateway.example/proxy/v1/", "https://gateway.example/proxy/v1/\(leaf)"] {
                XCTAssertEqual(try LiteLLMConfiguration.endpoint(input, api: api).absoluteString, "https://gateway.example/proxy/v1/\(leaf)")
            }
            XCTAssertEqual(try LiteLLMConfiguration.endpoint("http://127.0.0.1:51278", api: api).path, "/v1/\(leaf)")
            XCTAssertEqual(try LiteLLMConfiguration.endpoint("https://gateway.example/proxy/\(leaf)", api: api).path, "/proxy/\(leaf)")
            for invalid in ["http://remote.example", "https://u:p@gateway.example", "https://gateway.example?key=secret", "https://gateway.example#fragment", "https://gateway.example/v1/v1", "https://gateway.example/v1/chat/completions", "https://gateway.example/a/../b", "https://gateway.example/a%2fb", "https://gateway.example /v1"] {
                XCTAssertThrowsError(try LiteLLMConfiguration.endpoint(invalid, api: api), invalid)
            }
        }
        var profile = ProfileRecord(); profile.baseUrl = "https://gateway.example"; profile.modelId = "auto-router"
        for name in ["Authorization", "X-API-Key", "Content-Length", "Host"] { XCTAssertThrowsError(try LiteLLMConfiguration.validate(profile, headers: [name: "secret"])) }
        for separator in ["\r", "\n", "\r\n"] {
            XCTAssertThrowsError(try LiteLLMConfiguration.validate(profile, headers: ["x-extra": "value" + separator + "injection"]))
        }
        XCTAssertNoThrow(try LiteLLMConfiguration.validate(profile, headers: ["x-project": "example"]))
    }
}
