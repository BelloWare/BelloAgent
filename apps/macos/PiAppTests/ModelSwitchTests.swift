import XCTest
import SQLite3
@testable import PiApp

final class ModelSwitchTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PI_APP_SCRATCH_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent("native-model-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func profile(id: String = "p") -> ProfileRecord {
        var profile = ProfileRecord(); profile.id = id; profile.modelId = "router/default"; profile.baseUrl = "https://gateway.example/v1"; return profile
    }

    func testChatRecordDecodesWithoutOverridesAndRoundTripsThem() throws {
        let legacy = Data(#"{"id":"c","workspaceID":"w","title":"Old chat","profileID":"p","toolMode":"editing","imported":false}"#.utf8)
        let decoded = try JSONDecoder().decode(ChatRecord.self, from: legacy)
        XCTAssertNil(decoded.model); XCTAssertNil(decoded.thinkingLevel); XCTAssertEqual(decoded.toolMode, "editing")
        var updated = decoded; updated.model = "claude-opus"; updated.thinkingLevel = "high"; updated.contextWindow = 64_000; updated.maxOutputTokens = 8_192
        let reloaded = try JSONDecoder().decode(ChatRecord.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(reloaded.model, "claude-opus"); XCTAssertEqual(reloaded.thinkingLevel, "high"); XCTAssertEqual(reloaded, updated)
        XCTAssertEqual(reloaded.contextWindow, 64_000); XCTAssertEqual(reloaded.maxOutputTokens, 8_192)
        XCTAssertNil(decoded.contextWindow); XCTAssertNil(decoded.maxOutputTokens)
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        XCTAssertFalse(encoded.contains("\"model\""), "Absent overrides must not be written as explicit nulls")
    }

    func testTurnParamsCarryOnlyValidOverrides() {
        let base: [String: WireValue] = ["text": .string("hi"), "clientTurnId": .string("t1")]
        let plain = ChatRecord(id: "c", workspaceID: "w", title: "t", path: nil, profileID: "p")
        XCTAssertEqual(TurnOverrides.params(for: plain, base: base), base)
        let overridden = ChatRecord(id: "c", workspaceID: "w", title: "t", path: nil, profileID: "p", model: "  gpt-5 ", thinkingLevel: "xhigh", contextWindow: 128_000, maxOutputTokens: 16_000)
        let params = TurnOverrides.params(for: overridden, base: base)
        XCTAssertEqual(params["model"], .string("gpt-5")); XCTAssertEqual(params["thinkingLevel"], .string("xhigh"))
        XCTAssertEqual(params["text"], .string("hi")); XCTAssertEqual(params["clientTurnId"], .string("t1"))
        XCTAssertEqual(params["contextWindow"], .number(128_000)); XCTAssertEqual(params["maxOutputTokens"], .number(16_000))
        let invalid = ChatRecord(id: "c", workspaceID: "w", title: "t", path: nil, profileID: "p", model: String(repeating: "m", count: 201), thinkingLevel: "default")
        XCTAssertNil(TurnOverrides.params(for: invalid)["model"], "Aliases beyond 200 characters are dropped rather than rejected by the host")
        XCTAssertEqual(TurnOverrides.params(for: invalid)["thinkingLevel"], .string("default"), "Model default explicitly suppresses inherited effort")
        XCTAssertNil(TurnOverrides.normalizedThinkingLevel("profile-default"))
        XCTAssertNil(TurnOverrides.params(for: ChatRecord(id: "c", workspaceID: "w", title: "t", path: nil, profileID: "p", thinkingLevel: "ultra"))["thinkingLevel"])
        XCTAssertEqual(ThinkingLevel.allCases.map(\.rawValue), ["profile-default", "default", "off", "minimal", "low", "medium", "high", "xhigh", "max"])
    }

    @MainActor func testSettingOverridesPersistsTheChatAndSidesInheritThem() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let chat = ChatRecord(id: "chat", workspaceID: "w", title: "Chat", path: nil, profileID: "p")
        try await model.store?.put(chat, kind: "chat", id: chat.id); model.chats = [chat]
        async let modelChoice: Void = model.setModel("claude-sonnet", for: "chat")
        async let effortChoice: Void = model.setThinkingLevel("medium", for: "chat")
        _ = await (modelChoice, effortChoice)
        XCTAssertEqual(model.chats.first?.model, "claude-sonnet"); XCTAssertEqual(model.chats.first?.thinkingLevel, "medium"); XCTAssertNil(model.error)
        let saved = try await model.store?.get(ChatRecord.self, kind: "chat", id: "chat")
        XCTAssertEqual(saved?.model, "claude-sonnet"); XCTAssertEqual(saved?.thinkingLevel, "medium")
        await model.setThinkingLevel("default", for: "chat"); XCTAssertEqual(model.chats.first?.thinkingLevel, "default")
        await model.setThinkingLevel("profile-default", for: "chat"); XCTAssertNil(model.chats.first?.thinkingLevel)
        await model.setModel("", for: "chat"); XCTAssertNotNil(model.error, "An empty alias is rejected instead of clearing silently")
        XCTAssertEqual(model.chats.first?.model, "claude-sonnet"); model.error = nil
        await model.setModel(nil, for: "chat"); XCTAssertNil(model.chats.first?.model)
        let restored = try await model.store?.get(ChatRecord.self, kind: "chat", id: "chat"); XCTAssertNil(restored?.model)
        // Sides copy the parent's overrides at open time and keep their own afterwards.
        let parent = model.chats[0]
        let side = SideRecord(id: "side", parentID: parent.id, workspaceID: parent.workspaceID, profileID: parent.profileID, title: "side", model: "claude-sonnet", thinkingLevel: "high", contextWindow: 64_000, maxOutputTokens: 8_192)
        model.sides[parent.id] = side
        XCTAssertEqual(model.record("side")?.model, "claude-sonnet"); XCTAssertEqual(TurnOverrides.params(for: side.chat)["thinkingLevel"], .string("high"))
        XCTAssertEqual(TurnOverrides.params(for: side.chat)["contextWindow"], .number(64_000))
        await model.setModel("gpt-5-mini", for: "side")
        XCTAssertEqual(model.sides[parent.id]?.model, "gpt-5-mini"); XCTAssertNil(model.chats.first?.model, "Changing the side must not touch the parent")
        let sideRecord = try await model.store?.get(ChatRecord.self, kind: "chat", id: "side")
        XCTAssertNil(sideRecord, "Ephemeral sides never enter SQLite")
        XCTAssertTrue(model.hosts.isEmpty)
        model.shutdown(); await model.store?.close()
    }

    @MainActor func testSwitchingConnectionRebindsTheChatAndReconcilesOverrides() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        var second = profile(id: "q"); second.name = "Second gateway"; second.modelId = "router/other"
        var messages = profile(id: "legacy"); messages.api = "anthropic-messages"
        model.profiles = [profile(id: "p"), second, messages]
        let chat = ChatRecord(id: "chat", workspaceID: "w", title: "Chat", path: nil, profileID: "p", model: "gpt-5", thinkingLevel: "high", contextWindow: 64_000, maxOutputTokens: 8_192, outputBudgetVersion: 1)
        try await model.store?.put(chat, kind: "chat", id: chat.id); model.chats = [chat]
        model.selectedID = "chat"; model.profileChoice = "p"
        XCTAssertNil(model.connectionSwitchBlocker(for: "chat"))
        await model.setConnection("q", for: "chat")
        XCTAssertNil(model.error)
        XCTAssertEqual(model.chats.first?.profileID, "q"); XCTAssertEqual(model.profileChoice, "q", "The next new chat follows the switched chat")
        XCTAssertNil(model.chats.first?.model, "An alias the new connection's catalog does not list falls back to that connection's default")
        XCTAssertNil(model.chats.first?.contextWindow); XCTAssertNil(model.chats.first?.maxOutputTokens)
        XCTAssertEqual(model.chats.first?.thinkingLevel, "high", "Effort survives when the catalog does not restrict it")
        let saved = try await model.store?.get(ChatRecord.self, kind: "chat", id: "chat")
        XCTAssertEqual(saved?.profileID, "q"); XCTAssertNil(saved?.model); XCTAssertEqual(saved?.title, "Chat")
        let remembered = try await model.store?.get(ChatModelDefaults.self, kind: ChatModelDefaults.recordKind, id: "q")
        XCTAssertNil(remembered, "A connection switch is not remembered as a model choice for new chats")
        await model.setConnection("q", for: "chat"); XCTAssertNil(model.error, "Re-choosing the current connection is a no-op")
        await model.setConnection("missing", for: "chat"); XCTAssertNotNil(model.error); model.error = nil
        await model.setConnection("legacy", for: "chat"); XCTAssertNotNil(model.error, "A Messages connection cannot take new requests"); model.error = nil
        XCTAssertEqual(model.chats.first?.profileID, "q")
        let view = SessionDisplay(id: "chat"); view.state = "running"; model.displays["chat"] = view
        XCTAssertNotNil(model.connectionSwitchBlocker(for: "chat"))
        await model.setConnection("p", for: "chat"); XCTAssertNotNil(model.error, "A running chat keeps its connection"); model.error = nil
        XCTAssertEqual(model.chats.first?.profileID, "q")
        view.state = "idle"
        await model.setConnection("p", for: "chat"); XCTAssertNil(model.error); XCTAssertEqual(model.chats.first?.profileID, "p")
        XCTAssertEqual(view.notice, "Next turn uses LiteLLM connection.")
        let test = ChatRecord(id: "probe", workspaceID: "w", title: "Probe", path: nil, profileID: "p", connectionTest: true)
        let side = ChatRecord(id: "child", workspaceID: "w", title: "Child", path: nil, profileID: "p", toolMode: "read-only", parentSessionID: "chat")
        model.chats += [test, side]
        XCTAssertNotNil(model.connectionSwitchBlocker(for: "probe")); XCTAssertNotNil(model.connectionSwitchBlocker(for: "child"))
        XCTAssertTrue(model.hosts.isEmpty, "Switching without an open session never starts a helper")
        model.shutdown(); await model.store?.close()
    }

    @MainActor func testCustomCatalogCachesPerProfileDeduplicatesInFlightAndReportsCredentialFailure() async throws {
        let counter = CatalogFetchCounter(), clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let catalog = ModelCatalog(catalogTTL: 600, now: { clock.date }, readBundled: {
            XCTFail("An explicit custom catalog must not read the bundle"); return []
        }, fetchCatalog: { url, key in
            let call = await counter.hit()
            if call == 1 { await counter.wait() }
            if key == "bad" { throw ModelCatalogEndpoint.Failure.http(401) }
            return [ModelDescriptor(id: "model-\(call)/b", name: url.host ?? ""), ModelDescriptor(id: "model-\(call)/a", name: "Second")]
        })
        var first = profile(id: "one"), second = profile(id: "two"), third = profile(id: "three")
        first.catalogUrl = first.baseUrl + "/catalog"; second.catalogUrl = second.baseUrl + "/catalog"; third.catalogUrl = third.baseUrl + "/catalog"
        async let a = catalog.load(profile: first) { "key" }
        async let b = catalog.load(profile: first) { "key" }
        try await Task.sleep(for: .milliseconds(50)); XCTAssertTrue(catalog.entry(for: "one").loading)
        await counter.release()
        let results = await (a, b)
        XCTAssertEqual(results.0, results.1); XCTAssertEqual(results.0.count, 2)
        var calls = await counter.calls; XCTAssertEqual(calls, 1, "Concurrent loads for one profile share a single fetch")
        XCTAssertFalse(catalog.entry(for: "one").loading); XCTAssertNil(catalog.entry(for: "one").error)
        _ = await catalog.load(profile: first) { XCTFail("A fresh cache must not read the credential"); return "key" }
        calls = await counter.calls; XCTAssertEqual(calls, 1)
        clock.date = clock.date.addingTimeInterval(601)
        _ = await catalog.load(profile: first) { "key" }
        calls = await counter.calls; XCTAssertEqual(calls, 2, "An expired list is fetched again")
        _ = await catalog.load(profile: first, force: true) { "key" }
        calls = await counter.calls; XCTAssertEqual(calls, 3)
        let failed = await catalog.load(profile: second) { "bad" }
        XCTAssertTrue(failed.isEmpty); XCTAssertEqual(catalog.entry(for: "two").error, ModelCatalogEndpoint.Failure.http(401).errorDescription)
        XCTAssertEqual(catalog.entry(for: "one").models.count, 2, "Another profile's failure leaves this cache intact")
        let unavailable = await catalog.load(profile: third) { throw GatewayModelDiscovery.Failure.credential }
        XCTAssertTrue(unavailable.isEmpty); XCTAssertEqual(catalog.entry(for: "three").error, GatewayModelDiscovery.Failure.credential.errorDescription)
        catalog.invalidate(profileID: "one"); XCTAssertNil(catalog.entry(for: "one").fetchedAt)
    }

    @MainActor func testCatalogRevisionInvalidatesCacheAndLateCancelledFetchCannotReplaceNewList() async throws {
        let gate = CatalogBarrier()
        let catalog = ModelCatalog(fetchCatalog: { url, _ in
            if url.host == "old.example" { await gate.suspend(); return [ModelDescriptor(id: "old-model", name: "Old")] }
            return [ModelDescriptor(id: url.host ?? "", name: "New")]
        })
        var connection = profile(); connection.baseUrl = "https://old.example"
        connection.catalogUrl = connection.baseUrl + "/catalog"
        let original = connection
        let old = Task { await catalog.load(profile: original) { "key" } }
        await gate.waitForEntry()
        connection.baseUrl = "https://new.example"; connection.catalogUrl = connection.baseUrl + "/catalog"; connection.revision = "new-revision"
        let replacement = await catalog.load(profile: connection) { "new-key" }
        XCTAssertEqual(replacement, ["new.example"])
        await gate.release(); _ = await old.value
        XCTAssertEqual(catalog.entry(for: connection).models, replacement)
        XCTAssertNil(catalog.entry(for: connection).error)
        XCTAssertFalse(catalog.entry(for: connection).loading)
        XCTAssertTrue(catalog.entry(for: original).models.isEmpty)
        connection.revision = "another-revision"
        let counter = CatalogFetchCounter()
        _ = await catalog.load(profile: connection) { _ = await counter.hit(); return "latest-key" }
        let calls = await counter.calls; XCTAssertEqual(calls, 1, "A new credential revision must not reuse the old cache")
    }

    @MainActor func testExplicitRefreshReloadsSavedCatalogAndCredentialRevisionForTheSameConnection() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try ModelListGateway { request in
            .json(request.hasPrefix("GET /revised-catalog ") ? #"[{"id":"revised-model"}]"# : #"[{"id":"original-model"}]"#)
        }
        defer { gateway.stop() }
        let base = try await gateway.start()
        var connection = profile(); connection.baseUrl = base; connection.catalogUrl = base + "/original-catalog"
        let original = connection, vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [VaultProfile(profile: original, apiKey: "synthetic-old-key")] }
        let model = WorkspaceModel(stateRoot: root, vault: vault); defer { model.shutdown() }
        try await model.reloadConfiguration()
        let first = await model.listModels(for: original)
        XCTAssertEqual(first, ["original-model"])
        connection.catalogUrl = base + "/revised-catalog"; connection.revision = "revised"
        let revised = connection
        _ = try await vault.update(expectedRevision: 1) { $0.profiles = [VaultProfile(profile: revised, apiKey: "synthetic-new-key")] }
        XCTAssertEqual(model.profiles.first, original, "Simulate a saved change that this chat has not reloaded yet")
        let updated = try await model.refreshModels(profileID: original.id)
        XCTAssertEqual(updated, ["revised-model"])
        XCTAssertEqual(model.profiles.first, revised)
        XCTAssertEqual(model.modelCatalog.entry(for: revised).models, updated)
        XCTAssertTrue(model.modelCatalog.entry(for: original).models.isEmpty)
        XCTAssertEqual(gateway.requests.count, 2)
        XCTAssertTrue(gateway.requests[1].hasPrefix("GET /revised-catalog "))
        XCTAssertTrue(gateway.requests[1].lowercased().contains("authorization: bearer synthetic-new-key"))
        XCTAssertFalse(gateway.requests[1].contains("synthetic-old-key"))
        await model.store?.close(); try await model.traces.close()
    }

    @MainActor func testExplicitRefreshKeepsLastListOnVaultOrHTTPFailureAndSanitizesVaultErrors() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let responses = CatalogRefreshFixtureState()
        let gateway = try ModelListGateway { _ in
            responses.failing ? ModelListGateway.Reply(bytes: Data("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)) : .json(#"[{"id":"retained-model"}]"#)
        }
        defer { gateway.stop() }
        let base = try await gateway.start()
        var connection = profile(); connection.catalogUrl = base + "/catalog"
        var saved = VaultConfiguration(); saved.profiles = [VaultProfile(profile: connection, apiKey: "synthetic-only")]
        let storage = CatalogRefreshVaultStorage(try JSONEncoder().encode(saved))
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: storage)); defer { model.shutdown() }
        try await model.reloadConfiguration()
        _ = await model.listModels(for: connection)
        let cached = model.modelCatalog.entry(for: connection)
        storage.failReads = true
        let refresh = ModelCatalogRefreshState()
        await refresh.refresh(model: model, profileID: connection.id)
        XCTAssertFalse(refresh.loading)
        XCTAssertEqual(refresh.error, ModelCatalogRefreshFailure.configuration.errorDescription)
        XCTAssertFalse(refresh.error?.contains("synthetic-private-error") ?? true)
        XCTAssertEqual(model.modelCatalog.entry(for: connection), cached)
        XCTAssertEqual(gateway.requests.count, 1)
        storage.failReads = false; responses.failing = true
        await refresh.refresh(model: model, profileID: connection.id)
        XCTAssertNil(refresh.error, "A retry clears the reload error; the catalog reports HTTP failures separately")
        XCTAssertFalse(refresh.loading)
        XCTAssertEqual(model.modelCatalog.entry(for: connection).models, ["retained-model"])
        XCTAssertEqual(model.modelCatalog.entry(for: connection).error, ModelCatalogEndpoint.Failure.http(503).errorDescription)
        XCTAssertEqual(gateway.requests.count, 2)
        await model.store?.close(); try await model.traces.close()
    }

    @MainActor func testExplicitRefreshNeverSubstitutesTheSelectedForkForAMissingOrOlderConnection() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try ModelListGateway { request in
            .json(request.hasPrefix("GET /original ") ? #"[{"id":"original-model"}]"# : #"[{"id":"fork-model"}]"#)
        }
        defer { gateway.stop() }
        let base = try await gateway.start()
        var original = profile(id: "original"), fork = profile(id: "fork")
        original.catalogUrl = base + "/original"; fork.catalogUrl = base + "/fork"
        let savedOriginal = original, savedFork = fork, vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [VaultProfile(profile: savedFork, apiKey: "synthetic-only")] }
        let model = WorkspaceModel(stateRoot: root, vault: vault); defer { model.shutdown() }
        model.profiles = [original, fork]; model.profileChoice = fork.id
        _ = await model.listModels(for: original)
        let before = model.modelCatalog.entry(for: original)
        do {
            _ = try await model.refreshModels(profileID: original.id)
            XCTFail("A deleted connection cannot inherit the currently selected connection")
        } catch { XCTAssertEqual(error as? ModelCatalogRefreshFailure, .missingProfile) }
        XCTAssertEqual(gateway.requests.count, 1)
        XCTAssertEqual(model.modelCatalog.entry(for: original), before)
        XCTAssertEqual(model.profileChoice, fork.id)
        _ = try await vault.update(expectedRevision: 1) { $0.profiles.append(VaultProfile(profile: savedOriginal, apiKey: "synthetic-only")) }
        let models = try await model.refreshModels(profileID: original.id)
        XCTAssertEqual(models, ["original-model"])
        XCTAssertEqual(gateway.requests.count, 2)
        XCTAssertTrue(gateway.requests.allSatisfy { $0.hasPrefix("GET /original ") })
        XCTAssertEqual(model.profileChoice, fork.id)
        XCTAssertTrue(model.modelCatalog.entry(for: fork).models.isEmpty)
        await model.store?.close(); try await model.traces.close()
    }

    @MainActor func testPassiveCatalogOpeningAvoidsVaultAndExplicitRefreshStaysBusyDuringReload() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try ModelListGateway { _ in .json(#"[{"id":"external-model"}]"#) }
        defer { gateway.stop() }
        let base = try await gateway.start()
        var external = profile(); external.catalogUrl = base + "/catalog"
        let bundled = profile(id: "bundled")
        var saved = VaultConfiguration(); saved.profiles = [external, bundled].map { VaultProfile(profile: $0, apiKey: "synthetic-only") }
        let storage = CatalogRefreshVaultStorage(try JSONEncoder().encode(saved))
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: storage)); defer { model.shutdown() }
        model.profiles = [external, bundled]
        _ = await model.listModels(for: bundled)
        let offered = await model.listModels(for: external)
        XCTAssertEqual(offered, ["external-model"])
        XCTAssertEqual(storage.readCount, 0, "Passive bundled or external catalog opening must not read Keychain")
        storage.pauseNextRead()
        let refresh = ModelCatalogRefreshState()
        let refreshing = Task { await refresh.refresh(model: model, profileID: external.id) }
        let deadline = Date().addingTimeInterval(3)
        while !storage.readPaused, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(storage.readPaused)
        XCTAssertTrue(refresh.loading, "Show busy while reloading configuration, before any HTTP refresh exists")
        XCTAssertFalse(model.modelCatalog.entry(for: external).loading)
        await refresh.refresh(model: model, profileID: external.id)
        XCTAssertEqual(storage.readCount, 1, "Another click while reloading must not queue a second refresh")
        storage.resumeRead()
        await refreshing.value
        XCTAssertFalse(refresh.loading); XCTAssertNil(refresh.error)
        XCTAssertEqual(gateway.requests.count, 2)
        XCTAssertTrue(gateway.requests.allSatisfy { !$0.lowercased().contains("authorization:") })
        await model.store?.close(); try await model.traces.close()
    }

    @MainActor func testInvalidatingRunningCatalogLeavesNoLateCacheEntryOrCredentialErrorText() async {
        let gate = CatalogBarrier()
        var profile = profile(); profile.catalogUrl = profile.baseUrl + "/catalog"
        let catalog = ModelCatalog(fetchCatalog: { _, _ in await gate.suspend(); return [ModelDescriptor(id: "late", name: "Late")] })
        let fetch = Task { await catalog.load(profile: profile) { "key" } }
        await gate.waitForEntry(); catalog.invalidate(profileID: profile.id)
        await gate.release(); _ = await fetch.value
        XCTAssertNil(catalog.entry(for: profile.id).fetchedAt)
        XCTAssertTrue(catalog.entry(for: profile.id).models.isEmpty)
        struct EchoError: LocalizedError { var errorDescription: String? { "synthetic-secret" } }
        let failed = ModelCatalog(fetchCatalog: { _, _ in throw EchoError() })
        _ = await failed.load(profile: profile) { "key" }
        XCTAssertFalse(failed.entry(for: profile.id).error?.contains("synthetic-secret") ?? true)

        let replacementGate = CatalogBarrier(), calls = CatalogFetchCounter()
        let replacing = ModelCatalog(fetchCatalog: { _, _ in
            let call = await calls.hit()
            if call == 1 { await replacementGate.suspend() }
            return [ModelDescriptor(id: "model-\(call)", name: "Model \(call)")]
        })
        let first = Task { await replacing.load(profile: profile) { "key" } }
        await replacementGate.waitForEntry()
        let follower = Task { await replacing.load(profile: profile) { "key" } }
        await Task.yield()
        replacing.invalidate(profileID: profile.id)
        _ = await replacing.load(profile: profile) { "key" }
        await replacementGate.release()
        let values = await (first.value, follower.value)
        XCTAssertNotEqual(values.0, ["model-1"]); XCTAssertNotEqual(values.1, ["model-1"])
        XCTAssertEqual(replacing.entry(for: profile).models, ["model-2"])
    }

    @MainActor func testCatalogSelectionPersistsLimitsAndSuppressesUnsupportedInheritedEffort() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try ModelListGateway { _ in .json(#"[{"id":"small","contextWindow":128000,"maxOutputTokens":16000,"reasoning":[]}]"#) }
        defer { gateway.stop() }
        let base = try await gateway.start()
        var connection = profile(); connection.baseUrl = base; connection.catalogUrl = base + "/catalog"
        connection.contextWindow = 400_000; connection.maxOutputTokens = 300_000
        connection.advancedJSON = #"{"reasoning":true,"thinkingLevel":"high"}"#
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        model.profiles = [connection]
        let chat = ChatRecord(id: "chat", workspaceID: "w", title: "Chat", path: nil, profileID: connection.id)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        _ = await model.modelCatalog.load(profile: connection) { "synthetic-only" }
        await model.setModel("small", for: chat.id)
        let selected = try XCTUnwrap(model.record(chat.id))
        XCTAssertEqual(selected.contextWindow, 128_000); XCTAssertEqual(selected.maxOutputTokens, 16_000)
        XCTAssertEqual(selected.modelOutputLimit, 16_000)
        XCTAssertEqual(TurnOverrides.params(for: selected)["modelOutputLimit"], .number(16_000))
        XCTAssertEqual(TurnOverrides.params(for: selected)["thinkingLevel"], .string("default"))
        XCTAssertEqual(model.profiles.first, connection, "A chat choice must not rewrite the shared connection")
        let persisted = try await model.store?.get(ChatRecord.self, kind: "chat", id: chat.id)
        XCTAssertEqual(persisted, selected)
        let defaults = try await model.store?.get(ChatModelDefaults.self, kind: ChatModelDefaults.recordKind, id: connection.id)
        XCTAssertEqual(defaults, ChatModelDefaults(chat: selected), "New chats remember compatible effort and catalog limits together")
        await model.setModel("manual-router", for: chat.id)
        XCTAssertNil(model.record(chat.id)?.contextWindow); XCTAssertNil(model.record(chat.id)?.maxOutputTokens)
        XCTAssertNil(model.record(chat.id)?.modelOutputLimit)
        await model.store?.close()
    }

    @MainActor func testFailedOverridePersistenceRestoresTheVisibleChoice() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let chat = ChatRecord(id: "chat", workspaceID: "w", title: "Chat", path: nil, profileID: "p")
        model.chats = [chat]
        await model.store?.close()
        async let modelChoice: Void = model.setModel("unsaved", for: chat.id)
        async let effortChoice: Void = model.setThinkingLevel("high", for: chat.id)
        _ = await (modelChoice, effortChoice)
        XCTAssertEqual(model.chats.first, chat); XCTAssertNotNil(model.error)
    }

    @MainActor private func createChat(_ model: WorkspaceModel) async throws -> ChatRecord {
        let count = model.chats.count
        model.newChat()
        let deadline = Date().addingTimeInterval(3)
        while !model.workspaceChangesInFlight.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.workspaceChangesInFlight.isEmpty)
        XCTAssertEqual(model.chats.count, count + 1)
        XCTAssertNil(model.error)
        let created = try XCTUnwrap(model.chat)
        // A new chat exists only on screen until it is used; a draft keeps it from
        // being dropped or reused by the next New Chat in these checks.
        model.displays[created.id]?.draft = "Keeps this pending chat"
        return created
    }

    @MainActor func testNewChatsRememberChoicesAcrossProjectsAndRestartWithoutChangingExistingChats() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let connection = profile(), otherConnection = profile(id: "other")
        let workspace = WorkspaceRecord(id: "w", path: root.path, trusted: true)
        let otherWorkspace = WorkspaceRecord(id: "another-project", path: root.path, trusted: true)
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) {
            $0.profiles = [connection, otherConnection].map { VaultProfile(profile: $0, apiKey: "synthetic-only") }
            $0.workspaces = [workspace, otherWorkspace]
        }
        let model = WorkspaceModel(stateRoot: root, vault: vault)
        try await model.reloadConfiguration()
        let original = ChatRecord(id: "original", workspaceID: workspace.id, title: "Original", path: nil, profileID: connection.id)
        let older = ChatRecord(id: "older", workspaceID: workspace.id, title: "Older", path: nil, profileID: connection.id, model: "older-alias", thinkingLevel: "low")
        model.chats = [original, older]
        for chat in model.chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        await model.setModel("router/chosen", for: original.id)
        await model.setThinkingLevel("high", for: original.id)
        await model.select(older.id)
        model.selectedWorkspaceID = otherWorkspace.id
        let new = try await createChat(model)
        XCTAssertEqual(new.workspaceID, otherWorkspace.id)
        XCTAssertEqual(new.model, "router/chosen"); XCTAssertEqual(new.thinkingLevel, "high")
        XCTAssertEqual(model.record(older.id), older, "Choosing defaults must not rewrite other conversations")
        XCTAssertEqual(model.profiles, [connection, otherConnection], "Connection defaults remain separate")
        XCTAssertTrue(model.hosts.isEmpty)
        model.shutdown(); await model.flushProjectSidebarState(); try await model.traces.close(); await model.store?.close()

        let restarted = WorkspaceModel(stateRoot: root, vault: vault)
        defer { restarted.shutdown() }
        await restarted.restore()
        await restarted.select(older.id)
        let restored = try await createChat(restarted)
        XCTAssertEqual(restored.model, "router/chosen"); XCTAssertEqual(restored.thinkingLevel, "high")
        restarted.profileChoice = otherConnection.id
        let isolated = try await createChat(restarted)
        XCTAssertEqual(isolated.profileID, otherConnection.id)
        XCTAssertNil(isolated.model); XCTAssertNil(isolated.thinkingLevel, "Choices cannot leak to a different gateway")

        await restarted.select(older.id)
        // Explicitly re-selecting unchanged values also makes them the defaults.
        await restarted.setModel("older-alias", for: older.id)
        let reselected = try await createChat(restarted)
        XCTAssertEqual(reselected.model, "older-alias"); XCTAssertEqual(reselected.thinkingLevel, "low")
        await restarted.setThinkingLevel("default", for: reselected.id)
        let modelDefault = try await createChat(restarted)
        XCTAssertEqual(modelDefault.thinkingLevel, "default", "Model default must not turn into inherited profile effort")
        await restarted.setModel(nil, for: modelDefault.id)
        await restarted.setThinkingLevel("profile-default", for: modelDefault.id)
        await restarted.select(older.id)
        let reset = try await createChat(restarted)
        XCTAssertNil(reset.model); XCTAssertNil(reset.thinkingLevel, "An explicit reset must override the older chat fallback")
        await restarted.flushProjectSidebarState(); try await restarted.traces.close(); await restarted.store?.close()
    }

    @MainActor func testNewChatUsesUpgradeFallbackAndWaitsForPendingPickerSave() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let connection = profile()
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        model.configurationLoaded = true; model.profiles = [connection]
        model.workspaces = [WorkspaceRecord(id: "w", path: root.path, trusted: true)]
        model.selectedWorkspaceID = "w"; model.profileChoice = connection.id
        let original = ChatRecord(id: "old-choice", workspaceID: "w", title: "Existing", path: nil, profileID: connection.id, model: "existing-choice", thinkingLevel: "medium", contextWindow: 64_000, maxOutputTokens: 8_192)
        model.chats = [original]; model.selectedID = original.id; model.focusedSessionID = original.id
        try await model.store?.put(original, kind: "chat", id: original.id)
        let inherited = try await createChat(model)
        XCTAssertEqual(ChatModelDefaults(chat: inherited), ChatModelDefaults(chat: original))

        let gate = CatalogBarrier(), blocker = UUID()
        let pending = Task { await gate.suspend() }
        model.overrideWrites[connection.id] = (blocker, pending)
        await gate.waitForEntry()
        let selection = Task { await model.setModel("latest-choice", for: original.id) }
        let deadline = Date().addingTimeInterval(3)
        while model.overrideWrites[connection.id]?.token == blocker, Date() < deadline { await Task.yield() }
        XCTAssertNotEqual(model.overrideWrites[connection.id]?.token, blocker)
        let count = model.chats.count
        model.newChat()
        await Task.yield()
        XCTAssertEqual(model.chats.count, count, "New Chat must wait for the pending durable picker choice")
        await gate.release(); await selection.value
        while !model.workspaceChangesInFlight.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.chats.count, count + 1)
        XCTAssertEqual(model.chat?.model, "latest-choice"); XCTAssertEqual(model.chat?.thinkingLevel, "medium")
        XCTAssertNil(model.chat?.contextWindow, "A manual alias must not inherit another model's catalog limits")
        await model.flushProjectSidebarState(); await model.store?.close()
    }

    @MainActor func testDefaultsWriteFailureRollsBackChatChoiceAsWell() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let original = ChatRecord(id: "chat", workspaceID: "w", title: "Existing", path: nil, profileID: "p", model: "saved", thinkingLevel: "high")
        model.chats = [original]
        try await model.store?.saveChatModelChoice(original)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("desktop.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TRIGGER reject_defaults BEFORE INSERT ON records WHEN NEW.kind='chat-model-defaults' BEGIN SELECT RAISE(ABORT,'fixture storage failure'); END", nil, nil, nil), SQLITE_OK)
        await model.setModel("must-not-save", for: original.id)
        XCTAssertEqual(model.record(original.id), original); XCTAssertNotNil(model.error)
        let saved = try await model.store?.get(ChatRecord.self, kind: "chat", id: original.id)
        let defaults = try await model.store?.get(ChatModelDefaults.self, kind: ChatModelDefaults.recordKind, id: original.profileID)
        XCTAssertEqual(saved, original)
        XCTAssertEqual(defaults, ChatModelDefaults(chat: original))
        await model.store?.close()
    }
}

private actor CatalogBarrier {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiter: CheckedContinuation<Void, Never>?
    func suspend() async {
        entered = true; entryWaiters.forEach { $0.resume() }; entryWaiters = []
        await withCheckedContinuation { waiter = $0 }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { entryWaiters.append($0) } } }
    func release() { waiter?.resume(); waiter = nil }
}

private actor CatalogFetchCounter {
    var calls = 0
    private var gate: CheckedContinuation<Void, Never>?
    func hit() -> Int { calls += 1; return calls }
    func wait() async { await withCheckedContinuation { gate = $0 } }
    func release() { gate?.resume(); gate = nil }
}
/// Test clock read on the main actor only; the catalog's `now` closure runs there.
private final class TestClock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private final class CatalogRefreshFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var failing: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// A synthetic vault with a gated read, to observe the refresh's pre-network
/// phase without Keychain access or a timing-dependent HTTP delay.
private final class CatalogRefreshVaultStorage: VaultStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    private var failure = false
    private var reads = 0
    private var pause: DispatchSemaphore?
    private var paused = false
    init(_ bytes: Data) { self.bytes = bytes }
    var failReads: Bool {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    var readCount: Int { lock.withLock { reads } }
    var readPaused: Bool { lock.withLock { paused } }
    func pauseNextRead() { lock.withLock { pause = DispatchSemaphore(value: 0) } }
    func resumeRead() {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            let value = pause; pause = nil; paused = false; return value
        }
        gate?.signal()
    }
    func read() throws -> Data? {
        struct PrivateFailure: LocalizedError {
            var errorDescription: String? { "synthetic-private-error" }
        }
        let snapshot = lock.withLock { () -> (Data?, Bool, DispatchSemaphore?) in
            reads += 1; paused = pause != nil; return (bytes, failure, pause)
        }
        snapshot.2?.wait()
        if snapshot.1 { throw PrivateFailure() }
        return snapshot.0
    }
    func replace(expected: Data?, with replacement: Data) throws {
        try lock.withLock {
            guard bytes == expected else { throw VaultError.conflict }
            bytes = replacement
        }
    }
}
