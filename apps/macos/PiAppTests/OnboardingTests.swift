import XCTest
@testable import PiApp

final class OnboardingTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PI_APP_SCRATCH_ROOT"] ?? NSTemporaryDirectory())
            .appendingPathComponent("onboarding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @MainActor private func ready() -> OnboardingState {
        let state = OnboardingState()
        state.resume(profiles: [], preferredID: "")
        state.profile.baseUrl = "https://gateway.example/proxy"
        state.profile.modelId = "auto-router"
        state.key = "synthetic-test-key"
        state.step = .model
        return state
    }

    @MainActor func testFirstProfileKeepsWorkspaceStepVisibleUntilExplicitChatCompletion() async {
        let state = ready()
        XCTAssertFalse(OnboardingState.shouldPresent(configurationLoaded: false, hasProfiles: false, hasChats: false))
        XCTAssertTrue(OnboardingState.shouldPresent(configurationLoaded: true, hasProfiles: false, hasChats: false))
        let saved = await state.save { profile, _ in profile }
        XCTAssertTrue(saved); XCTAssertEqual(state.step, .workspace)
        XCTAssertTrue(OnboardingState.shouldPresent(configurationLoaded: true, hasProfiles: true, hasChats: false))
        var creations = 0
        let untrusted = await state.finish(hasTrustedWorkspace: false, verifyConnection: { _ in XCTFail("Untrusted setup must not contact the gateway") }) { creations += 1 }
        XCTAssertFalse(untrusted); XCTAssertEqual(creations, 0)
        let complete = await state.finish(hasTrustedWorkspace: true, verifyConnection: { _ in }) { creations += 1 }
        XCTAssertTrue(complete); XCTAssertTrue(state.completed); XCTAssertEqual(creations, 1)
        let repeated = await state.finish(hasTrustedWorkspace: true, verifyConnection: { _ in }) { creations += 1 }
        XCTAssertFalse(repeated); XCTAssertEqual(creations, 1)
        XCTAssertFalse(OnboardingState.shouldPresent(configurationLoaded: true, hasProfiles: true, hasChats: true))
    }

    @MainActor func testLegacyMessagesProfilesCannotBecomeOnboardingConnections() async {
        var legacy = ready().profile; legacy.api = "anthropic-messages"
        let state = OnboardingState(); state.resume(profiles: [legacy], preferredID: legacy.id)
        XCTAssertEqual(state.profile.api, "openai-responses"); XCTAssertNotEqual(state.profile.id, legacy.id); XCTAssertEqual(state.step, .gateway)
        let supported = ready().profile, resumed = OnboardingState()
        resumed.resume(profiles: [legacy, supported], preferredID: legacy.id)
        XCTAssertEqual(resumed.profile, supported)
        state.profile = legacy; state.key = "synthetic-only"
        await state.listModels(catalog: { _, _ in XCTFail("Legacy discovery must not call the gateway"); return [] },
                               bundled: { XCTFail("Legacy connections cannot list active models"); return [] })
        XCTAssertTrue(state.listError.contains("Only the Responses API"))
        let saved = await state.save { profile, _ in XCTFail("Legacy settings must not be saved as an active connection"); return profile }
        XCTAssertFalse(saved); XCTAssertTrue(state.message.contains("Only the Responses API"))
    }

    @MainActor func testModelDiscoveryNeverVerifiesAndProbeMustSucceedBeforeChatCreation() async {
        let state = ready()
        await state.listModels(bundled: { [ModelDescriptor(id: "auto-router", name: "Router")] })
        _ = await state.save { profile, _ in profile }
        var order: [String] = []
        let failed = await state.finish(hasTrustedWorkspace: true, verifyConnection: { profile in
            order.append("probe:" + profile.modelId)
            throw ConnectionProbeError.failed("The gateway rejected authentication.")
        }) { order.append("chat") }
        XCTAssertFalse(failed); XCTAssertFalse(state.completed); XCTAssertEqual(order, ["probe:auto-router"])
        XCTAssertTrue(state.message.contains("authentication"))
        let succeeded = await state.finish(hasTrustedWorkspace: true, verifyConnection: { profile in order.append("probe:" + profile.modelId) }) { order.append("chat") }
        XCTAssertTrue(succeeded); XCTAssertEqual(order, ["probe:auto-router", "probe:auto-router", "chat"])
    }

    @MainActor func testChangedModelOrKeyCannotFinishWithStaleProbeAndRepeatClickDoesNotSendTwice() async {
        for changeKey in [false, true] {
            let state = ready(), barrier = OnboardingBarrier()
            _ = await state.save { profile, _ in profile }
            var probes = 0, chats = 0
            let running = Task { await state.finish(hasTrustedWorkspace: true, verifyConnection: { _ in
                probes += 1; await barrier.suspend()
            }) { chats += 1 } }
            await barrier.waitForEntry()
            XCTAssertTrue(state.testingConnection)
            let repeatClick = await state.finish(hasTrustedWorkspace: true, verifyConnection: { _ in probes += 1 }) { chats += 1 }
            XCTAssertFalse(repeatClick); XCTAssertEqual(probes, 1)
            if changeKey { state.key = "new-synthetic-key" } else { state.profile.modelId = "different-model" }
            await barrier.release()
            let completed = await running.value
            XCTAssertFalse(completed); XCTAssertFalse(state.completed); XCTAssertEqual(chats, 0)
            XCTAssertTrue(state.message.contains("changed")); XCTAssertFalse(state.testingConnection)
        }
    }

    @MainActor func testCancelAndTimeoutCannotCreateChatAndProviderErrorsCannotEchoKeys() async {
        let state = ready(), barrier = OnboardingBarrier()
        _ = await state.save { profile, _ in profile }
        var chats = 0
        let running = Task { await state.finish(hasTrustedWorkspace: true, verifyConnection: { _ in await barrier.suspend() }) { chats += 1 } }
        await barrier.waitForEntry(); state.cancelConnectionTest(); await barrier.release()
        let cancelled = await running.value
        XCTAssertFalse(cancelled); XCTAssertEqual(chats, 0); XCTAssertTrue(state.message.contains("cancelled"))
        let timeout = await state.finish(hasTrustedWorkspace: true, verifyConnection: { _ in throw ConnectionProbeError.timedOut }) { chats += 1 }
        XCTAssertFalse(timeout); XCTAssertEqual(chats, 0); XCTAssertTrue(state.message.contains("30 seconds"))
        struct UnsafeError: LocalizedError { var errorDescription: String? { "synthetic-secret-key" } }
        let leaked = await state.finish(hasTrustedWorkspace: true, verifyConnection: { _ in throw UnsafeError() }) { chats += 1 }
        XCTAssertFalse(leaked); XCTAssertEqual(chats, 0); XCTAssertFalse(state.message.contains("synthetic-secret-key"))
    }

    @MainActor func testFailedSavePreservesFormAndRetriesUpdateOneProfileIdentity() async {
        let state = ready(), original = state.profile
        let failed = await state.save { _, _ in throw VaultError.conflict }
        XCTAssertFalse(failed); XCTAssertEqual(state.step, .model)
        XCTAssertEqual(state.profile, original); XCTAssertEqual(state.key, "synthetic-test-key")
        var stored: [String: ProfileRecord] = [:]
        for _ in 0..<2 {
            let saved = await state.save { profile, _ in stored[profile.id] = profile; return profile }
            XCTAssertTrue(saved)
        }
        XCTAssertEqual(stored.count, 1); XCTAssertEqual(stored.keys.first, original.id)
        XCTAssertEqual(state.profile.id, original.id); XCTAssertTrue(state.key.isEmpty)
    }

    @MainActor func testSavedProfileIdentityReturnedByPersistenceIsUsedForNextSave() async {
        let state = ready()
        let saved = await state.save { profile, _ in var value = profile; value.id = "persisted-profile"; return value }
        XCTAssertTrue(saved)
        let again = await state.save { profile, _ in XCTAssertEqual(profile.id, "persisted-profile"); return profile }
        XCTAssertTrue(again)
    }

    @MainActor func testResumePreservesExistingSetupAndRequiresNewKeyForDifferentGateway() async {
        var first = ready().profile, preferred = first
        first.id = "first"; preferred.id = "preferred"
        let state = OnboardingState()
        state.resume(profiles: [first, preferred], preferredID: preferred.id)
        XCTAssertEqual(state.profile, preferred); XCTAssertEqual(state.step, .workspace)
        XCTAssertTrue(state.hasStoredKey); XCTAssertTrue(state.gatewayReady); XCTAssertTrue(state.key.isEmpty)
        state.profile.name = "Retained form edit"
        state.resume(profiles: [first], preferredID: first.id)
        XCTAssertEqual(state.profile.id, preferred.id); XCTAssertEqual(state.profile.name, "Retained form edit")
        let same = await state.save { profile, key in XCTAssertTrue(key.isEmpty); return profile }
        XCTAssertTrue(same)
        state.profile.baseUrl = "https://different-gateway.example"
        XCTAssertFalse(state.hasStoredKey); XCTAssertFalse(state.gatewayReady)
        let changed = await state.save { profile, _ in XCTFail("A stored key must not silently move to another gateway"); return profile }
        XCTAssertFalse(changed)
    }

    @MainActor func testInvalidModelLimitsFailBeforeWritingAndFailedChatCanRetry() async {
        let state = ready()
        state.profile.maxOutputTokens = state.profile.contextWindow
        let invalid = await state.save { profile, _ in XCTFail("Invalid limits must not reach persistence"); return profile }
        XCTAssertFalse(invalid); XCTAssertEqual(state.profile.maxOutputTokens, state.profile.contextWindow)
        state.profile.maxOutputTokens = 8192
        _ = await state.save { profile, _ in profile }
        let failed = await state.finish(hasTrustedWorkspace: true, verifyConnection: { _ in }) { throw StoreError.unavailable }
        XCTAssertFalse(failed); XCTAssertFalse(state.completed); XCTAssertFalse(state.finishing)
        XCTAssertEqual(state.step, .workspace)
        let retry = await state.finish(hasTrustedWorkspace: true, verifyConnection: { _ in }) { }
        XCTAssertTrue(retry)
    }

    @MainActor func testRepeatedSaveAndStartClicksDoNotDuplicateInFlightOperations() async {
        let state = ready(), saveBarrier = OnboardingBarrier()
        var writes = 0
        let save = Task { await state.save { profile, _ in writes += 1; await saveBarrier.suspend(); return profile } }
        await saveBarrier.waitForEntry()
        let repeatedSave = await state.save { profile, _ in writes += 1; return profile }
        XCTAssertFalse(repeatedSave); XCTAssertEqual(writes, 1)
        await saveBarrier.release()
        let saved = await save.value; XCTAssertTrue(saved)
        let startBarrier = OnboardingBarrier()
        var starts = 0
        let start = Task { await state.finish(hasTrustedWorkspace: true, verifyConnection: { _ in }) { starts += 1; await startBarrier.suspend() } }
        await startBarrier.waitForEntry()
        let repeatedStart = await state.finish(hasTrustedWorkspace: true, verifyConnection: { _ in }) { starts += 1 }
        XCTAssertFalse(repeatedStart); XCTAssertEqual(starts, 1)
        await startBarrier.release()
        let started = await start.value; XCTAssertTrue(started)
    }

    @MainActor func testLateCatalogCannotReplaceNewConnectionModelsOrManualAlias() async {
        let state = ready(), barrier = OnboardingBarrier()
        state.profile.modelId = ""
        state.profile.catalogUrl = "https://gateway.example/catalog"
        let old = Task { await state.listModels(catalog: { _, _ in
            await barrier.suspend(); return [ModelDescriptor(id: "old-model", name: "Old")]
        }) }
        await barrier.waitForEntry()
        state.profile.baseUrl = "https://new-gateway.example"
        state.profile.catalogUrl = "https://new-gateway.example/catalog"
        state.key = "new-synthetic-key"
        state.invalidateModelList()
        await state.listModels(catalog: { url, key in
            XCTAssertEqual(url.absoluteString, "https://new-gateway.example/catalog"); XCTAssertEqual(key, "new-synthetic-key")
            return [ModelDescriptor(id: "new-model", name: "New")]
        })
        await barrier.release(); await old.value
        XCTAssertEqual(state.models, ["new-model"]); XCTAssertEqual(state.profile.modelId, "new-model")
        XCTAssertFalse(state.listing); XCTAssertTrue(state.listError.isEmpty)
        state.profile.modelId = "manual-router"
        await state.listModels(catalog: { _, _ in [ModelDescriptor(id: "another-model", name: "Another")] })
        XCTAssertEqual(state.profile.modelId, "manual-router")
    }

    @MainActor func testUntrustedDiscoveryErrorsCannotEchoCredentialsAndManualFallbackRemains() async {
        struct EchoError: LocalizedError { var errorDescription: String? { "synthetic-test-key" } }
        let state = ready()
        await state.listModels(bundled: { throw EchoError() })
        XCTAssertFalse(state.listError.contains("synthetic-test-key"))
        XCTAssertTrue(state.listError.contains("manually")); XCTAssertEqual(state.profile.modelId, "auto-router")
        let saved = await state.save { profile, _ in profile }
        XCTAssertTrue(saved)
        await state.listModels(catalog: { _, _ in XCTFail("The default catalog needs no request"); return [] })
        XCTAssertTrue(state.listError.isEmpty, "The bundled catalog remains available with the saved key left empty")
        XCTAssertEqual(state.models.count, 6)
        XCTAssertEqual(state.profile.modelId, "auto-router", "Loading the catalog must not replace the saved alias")
        state.profile.catalogUrl = "https://gateway.example/catalog"
        await state.listModels(catalog: { _, _ in XCTFail("A saved key is not implicitly fetched for a same-origin custom catalog"); return [] })
        XCTAssertTrue(state.listError.contains("Re-enter"))
    }

    @MainActor func testCatalogSelectionUsesFirstActiveModelAndExternalCatalogIsAnonymous() async {
        let state = ready(); state.profile.modelId = ""; state.profile.catalogUrl = "https://models.example/catalog"
        await state.listModels(catalog: { _, key in
            XCTAssertTrue(key.isEmpty)
            return [ModelDescriptor(id: "retired", name: "Old", deprecated: true),
                    ModelDescriptor(id: "first", name: "First", contextWindow: 64_000, maxOutputTokens: 4_000, reasoning: []),
                    ModelDescriptor(id: "second", name: "Second")]
        }, bundled: { XCTFail("A configured catalog must not be replaced by bundled models"); return [] })
        XCTAssertEqual(state.models, ["first", "second"]); XCTAssertEqual(state.profile.modelId, "first")
        XCTAssertEqual(state.profile.contextWindow, 64_000); XCTAssertEqual(state.profile.maxOutputTokens, 4_000)
        XCTAssertEqual(state.profile.configuration["reasoning"], .bool(false))
    }

    @MainActor func testFirstRunLoadsBundledCatalogWithoutGatewayDiscoveryAndPreservesManualChoice() async throws {
        let gateway = try ModelListGateway { _ in
            XCTFail("First-run model choices must not come from /v1/models")
            return .json(#"{"data":[{"id":"gateway-only"}]}"#)
        }
        defer { gateway.stop() }
        let state = OnboardingState()
        state.profile.baseUrl = try await gateway.start()
        await state.listModels()
        XCTAssertTrue(state.listError.isEmpty)
        XCTAssertEqual(state.models, try ModelCatalogEndpoint.bundled().map(\.id))
        XCTAssertEqual(state.profile.modelId, "deepseek-v4.1-flash")
        XCTAssertEqual(state.profile.contextWindow, 1_048_576)
        XCTAssertEqual(state.profile.maxOutputTokens, 8_192, "The catalog ceiling must not raise the requested output budget")
        XCTAssertEqual(state.profile.modelOutputLimit, 393_216)
        XCTAssertTrue(state.key.isEmpty, "Listing the built-in catalog does not need the gateway key")
        state.profile.modelId = "manual-route"
        await state.listModels()
        XCTAssertEqual(state.profile.modelId, "manual-route")
        XCTAssertTrue(gateway.requests.isEmpty)
        XCTAssertFalse(state.gatewayReady, "Offline catalog loading cannot stand in for a configured gateway or successful onboarding probe")
    }

    @MainActor func testCatalogURLEditInvalidatesLateResultAndCatalogFailuresNeverUseTheGateway() async {
        let state = ready(), barrier = OnboardingBarrier()
        state.profile.modelId = ""; state.profile.catalogUrl = "https://models.example/old"
        let old = Task { await state.listModels(catalog: { _, _ in
            await barrier.suspend(); return [ModelDescriptor(id: "stale", name: "Stale")]
        }) }
        await barrier.waitForEntry(); state.profile.catalogUrl = "https://models.example/new"
        await barrier.release(); await old.value
        XCTAssertTrue(state.models.isEmpty); XCTAssertTrue(state.profile.modelId.isEmpty)
        XCTAssertFalse(state.listing)
        state.profile.catalogUrl = "http://remote.example/catalog"
        await state.listModels(catalog: { _, _ in
            XCTFail("An invalid catalog URL must not be contacted"); return []
        }, bundled: { XCTFail("An invalid catalog must not fall back to the bundled list"); return [] })
        XCTAssertTrue(state.models.isEmpty); XCTAssertTrue(state.profile.modelId.isEmpty)
        XCTAssertTrue(state.listError.contains("manually")); XCTAssertFalse(state.listing)
        state.profile.catalogUrl = "https://models.example/broken"
        await state.listModels(catalog: { _, _ in
            throw ModelCatalogEndpoint.Failure.http(500)
        }, bundled: { XCTFail("A failing catalog must not fall back to the bundled list"); return [] })
        XCTAssertTrue(state.models.isEmpty); XCTAssertTrue(state.profile.modelId.isEmpty)
        XCTAssertTrue(state.listError.contains("manually")); XCTAssertFalse(state.listing)
    }

    @MainActor func testRealWorkspaceSetupPersistsOneConnectionAndChatAndResumesAfterRestart() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = MemoryVaultStorage(), vault = ConfigurationVault(storage: storage)
        let model = WorkspaceModel(stateRoot: root, vault: vault), state = ready()
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        try await model.updateConfiguration { $0.capture.disclosureAccepted = true; $0.automaticUpdateChecks = false }
        for _ in 0..<2 {
            let saved = await state.save { profile, key in
                try await model.saveProfile(profile, key: key)
                return try XCTUnwrap(model.profiles.first { $0.id == model.profileChoice })
            }
            XCTAssertTrue(saved)
        }
        XCTAssertEqual(model.profiles.count, 1); XCTAssertTrue(model.chats.isEmpty)
        XCTAssertEqual(state.step, .workspace)
        let workspace = WorkspaceRecord(id: "trusted-workspace", path: root.path, trusted: true)
        try await model.updateConfiguration { $0.workspaces = [workspace] }
        model.selectedWorkspaceID = workspace.id
        let finished = await state.finish(hasTrustedWorkspace: true, verifyConnection: { _ in }) { try await model.createOnboardingChat() }
        XCTAssertTrue(finished); XCTAssertEqual(model.chats.count, 1)
        XCTAssertEqual(model.chat?.workspaceID, workspace.id); XCTAssertEqual(model.chat?.profileID, state.profile.id)
        let persisted = try await model.store?.list(ChatRecord.self, kind: "chat")
        XCTAssertEqual(persisted?.count, 1); XCTAssertEqual(persisted?.first?.id, model.selectedID)
        XCTAssertTrue(model.hosts.isEmpty, "Creating a first chat must not send a provider request")
        let reopened = WorkspaceModel(stateRoot: root, vault: vault)
        defer { reopened.shutdown() }
        await reopened.restore()
        XCTAssertEqual(reopened.profiles.count, 1); XCTAssertEqual(reopened.chats.count, 1)
        XCTAssertEqual(reopened.selectedID, model.selectedID)
        XCTAssertFalse(OnboardingState.shouldPresent(configurationLoaded: reopened.configurationLoaded, hasProfiles: !reopened.profiles.isEmpty, hasChats: !reopened.chats.isEmpty))
        XCTAssertTrue(reopened.hosts.isEmpty)
        await model.store?.close(); await reopened.store?.close()
    }

    @MainActor func testRealWorkspaceRejectsUntrustedFolderAndUnavailableStoreWithoutCreatingChat() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ready().profile
        var config = VaultConfiguration()
        config.capture.disclosureAccepted = true; config.automaticUpdateChecks = false
        config.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-only")]
        config.workspaces = [WorkspaceRecord(id: "untrusted", path: root.path, trusted: false)]
        let vault = ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(config)))
        let model = WorkspaceModel(stateRoot: root, vault: vault)
        defer { model.shutdown() }
        try await model.reloadConfiguration(); model.selectedWorkspaceID = "untrusted"; model.profileChoice = profile.id
        do { try await model.verifyOnboardingConnection(profile); XCTFail("Untrusted workspace must not start a gateway probe") } catch { }
        do { try await model.createOnboardingChat(); XCTFail("Untrusted workspace must be rejected") } catch { }
        XCTAssertTrue(model.chats.isEmpty); XCTAssertNil(model.selectedID)
        let records = try await model.store?.list(ChatRecord.self, kind: "chat")
        XCTAssertEqual(records?.count, 0); XCTAssertTrue(model.hosts.isEmpty)
        let blockedRoot = root.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: blockedRoot)
        config.workspaces[0].trusted = true
        let blocked = WorkspaceModel(stateRoot: blockedRoot, vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(config))))
        defer { blocked.shutdown() }
        try await blocked.reloadConfiguration(); blocked.selectedWorkspaceID = "untrusted"; blocked.profileChoice = profile.id
        XCTAssertNil(blocked.store)
        do { try await blocked.verifyOnboardingConnection(profile); XCTFail("Missing storage must prevent a gateway probe") } catch { }
        do { try await blocked.createOnboardingChat(); XCTFail("Missing storage must not report a successful chat") } catch { }
        XCTAssertTrue(blocked.chats.isEmpty); XCTAssertNil(blocked.selectedID); XCTAssertTrue(blocked.hosts.isEmpty)
        await model.store?.close()
    }

    @MainActor func testRealWorkspaceSerializesConcurrentFirstChatCreation() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ready().profile
        var config = VaultConfiguration()
        config.capture.disclosureAccepted = true; config.automaticUpdateChecks = false
        config.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-only")]
        config.workspaces = [WorkspaceRecord(id: "trusted", path: root.path, trusted: true)]
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(config))))
        defer { model.shutdown() }
        try await model.reloadConfiguration(); model.profileChoice = profile.id; model.selectedWorkspaceID = "trusted"
        let store = try XCTUnwrap(model.store), gate = OnboardingStoreGate()
        let blocker = Task.detached { await store.holdForOnboardingTest(gate) }
        defer { gate.open() }
        for _ in 0..<200 {
            if gate.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(gate.entered)
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do { try await model.createOnboardingChat(); return true }
                    catch { return false }
                }
            }
            let first = await group.next()!
            // The durable write is still held, so the in-flight guard must be
            // what rejects the second caller before the first can complete.
            XCTAssertFalse(first)
            gate.open()
            return [first, await group.next()!]
        }
        await blocker.value
        XCTAssertEqual(outcomes.filter { $0 }.count, 1)
        XCTAssertEqual(model.chats.count, 1)
        let persisted = try await store.list(ChatRecord.self, kind: "chat")
        XCTAssertEqual(persisted.count, 1); XCTAssertTrue(model.hosts.isEmpty)
        await store.close()
    }
}

private final class OnboardingStoreGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var started = false
    var entered: Bool { lock.withLock { started } }
    func hold() { lock.withLock { started = true }; _ = semaphore.wait(timeout: .now() + 3) }
    func open() { semaphore.signal() }
}
private extension MetadataStore {
    func holdForOnboardingTest(_ gate: OnboardingStoreGate) { gate.hold() }
}

private actor OnboardingBarrier {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func suspend() async {
        entered = true
        entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { entryWaiters.append($0) } } }
    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }; releaseWaiters.removeAll()
    }
}
