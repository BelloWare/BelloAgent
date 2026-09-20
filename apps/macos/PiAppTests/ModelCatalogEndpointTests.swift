import XCTest
import SwiftUI
import Vision
@testable import PiApp

final class ModelCatalogEndpointTests: XCTestCase {
    private let endpoint = ModelCatalogEndpoint()

    func testShippingBundleContainsTheCuratedAliasesLimitsAndReasoningEfforts() throws {
        // Read the application resource rather than the repository fixture: this
        // fails if the release stops copying the curated catalog into the app.
        let models = try ModelCatalogEndpoint.bundled()
        XCTAssertEqual(models.map(\.id), ["deepseek-v4.1-flash", "glm-5.3-flash", "glm-5.3", "kimi-k3", "gemini-3.8-flash", "auto-router"])
        XCTAssertEqual(models.map(\.name), ["DeepSeek V4.1 Flash", "GLM 5.3 Flash", "GLM 5.3", "Kimi K3", "Gemini 3.8 Flash", "Auto Router — GPT-5.6 Sol + DeepSeek V4.1 Flash"])
        XCTAssertEqual(models.map(\.contextWindow), Array(repeating: 1_048_576, count: 6))
        XCTAssertEqual(models.map(\.maxOutputTokens), [393_216, 131_072, 131_072, 131_072, 65_536, 128_000])
        XCTAssertEqual(models.map(\.reasoning), [["off", "low", "high", "max"], ["low", "high", "max"], ["low", "high", "max"], ["low", "high", "max"], ["low", "medium", "high"], ["off", "low", "high", "max"]])
        XCTAssertTrue(models.allSatisfy { !$0.deprecated && !$0.description.isEmpty })
        for descriptor in models {
            var profile = ProfileRecord(); profile.baseUrl = "https://gateway.example"
            XCTAssertNoThrow(try LiteLLMConfiguration.validate(descriptor.applying(to: profile), headers: [:]))
        }
    }

    @MainActor func testAbsentAndBlankCatalogUsesBundleForLegacyProfilesWithoutCredentialsOrNetwork() async throws {
        let gateway = try ModelListGateway { _ in
            XCTFail("A default model list must not make a gateway discovery request")
            return .json(#"{"data":[{"id":"gateway-only-wrong-list"}]}"#)
        }
        defer { gateway.stop() }
        let base = try await gateway.start()
        let legacy = Data(#"{"id":"legacy","revision":"old-revision","name":"Existing connection","providerId":"litellm","modelId":"saved-alias","api":"openai-responses","baseUrl":"https://gateway.example","contextWindow":128000,"maxOutputTokens":4096}"#.utf8)
        var profile = try JSONDecoder().decode(ProfileRecord.self, from: legacy)
        XCTAssertNil(profile.catalogUrl, "An upgraded connection has no new catalog setting")
        profile.baseUrl = base
        let reads = BundleReadCounter()
        let catalog = ModelCatalog(readBundled: {
            reads.record()
            return try ModelCatalogEndpoint.bundled()
        }, fetchCatalog: { _, _ in
            XCTFail("A blank catalog URL must read the bundled resource, not an endpoint")
            return []
        })
        let expected = try ModelCatalogEndpoint.bundled()
        let optionalURLs: [String?] = [nil, "", " \t\n"]
        for (index, url) in optionalURLs.enumerated() {
            profile.id = "legacy-\(index)"; profile.catalogUrl = url
            XCTAssertFalse(ModelCatalog.catalogConfigured(profile))
            XCTAssertEqual(catalog.entry(for: profile).source, "bundled", "The default must be identified before its first load")
            let listed = await catalog.load(profile: profile) { XCTFail("Bundled models must not read an API key"); return "synthetic-secret" }
            XCTAssertEqual(listed, expected.map(\.id))
            XCTAssertEqual(catalog.entry(for: profile).source, "bundled")
            XCTAssertEqual(catalog.entry(for: profile).offered(current: profile.modelId), expected, "The default picker must retain rich metadata, not just discovered aliases")
            let cached = await catalog.load(profile: profile) { XCTFail("A cached bundle must not read an API key"); return "synthetic-secret" }
            XCTAssertEqual(cached, listed)
            XCTAssertEqual(reads.count, index + 1, "A repeated access must use its cached bundle")
        }
        XCTAssertTrue(gateway.requests.isEmpty)
        XCTAssertEqual(profile.modelId, "saved-alias", "Upgrading the list source must not silently change the selected model")
    }

    @MainActor func testBundledCatalogFailureDoesNotDiscoverModelsOrExposeUnderlyingError() async {
        struct EchoError: LocalizedError { var errorDescription: String? { "synthetic-private-path" } }
        let catalog = ModelCatalog(readBundled: { throw EchoError() }, fetchCatalog: { _, _ in
            XCTFail("A failed bundle must not fall back to a network list")
            return []
        })
        let profile = ProfileRecord()
        let result = await catalog.load(profile: profile) { XCTFail("A failed bundle must not resolve credentials"); return "synthetic-secret" }
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(catalog.entry(for: profile).source, "bundled")
        XCTAssertNotNil(catalog.entry(for: profile).error)
        XCTAssertFalse(catalog.entry(for: profile).error?.contains("synthetic-private-path") ?? true)
    }

    func testParsesOrderDeprecationAndLimits() throws {
        let body = Data("""
        {"version": 1, "models": [
          {"id": "b", "name": "Model B", "order": 2, "contextWindow": 200000, "maxOutputTokens": 64000, "reasoning": ["low", "high", "bogus", "default"]},
          {"id": "a", "name": "Model A", "order": 1, "description": "First", "context_window": 400000},
          {"id": "c", "deprecated": true},
          {"id": "d", "reasoning": {"efforts": ["off"]}}
        ]}
        """.utf8)
        let models = try endpoint.parse(body)
        XCTAssertEqual(models.map(\.id), ["a", "b", "c", "d"], "explicit order first, then array position")
        XCTAssertEqual(models[0].contextWindow, 400_000)
        XCTAssertEqual(models[0].description, "First")
        XCTAssertEqual(models[1].reasoning, ["low", "high"], "unknown levels and default are dropped")
        XCTAssertEqual(models[1].maxOutputTokens, 64_000)
        XCTAssertTrue(models[2].deprecated)
        XCTAssertEqual(models[2].displayName, "c")
        XCTAssertEqual(models[3].reasoning, ["off"])
        XCTAssertEqual(models[0].contextLabel, "400k ctx")
    }

    @MainActor func testMiniRecommendationsAndPickerSearchPreserveCatalogAliases() throws {
        let models = try endpoint.parse(Data(#"{"models":[{"id":"main","name":"Primary"},{"id":"quick","name":"Quick utility","mini":true,"description":"Inexpensive titles"},{"id":"other","mini":false}]}"#.utf8))
        XCTAssertNil(models[0].mini)
        XCTAssertEqual(models[1].mini, true); XCTAssertEqual(models[2].mini, false)
        XCTAssertEqual(CatalogModelPicker.filtered(models, query: "titles").map(\.id), ["quick"])
        XCTAssertEqual(CatalogModelPicker.filtered(models, query: "QUICK").map(\.id), ["quick"])
        XCTAssertEqual(CatalogModelPicker.filtered(models, query: " ").map(\.id), ["main", "quick", "other"])
        for invalid in ["1", "\"yes\"", "null"] {
            XCTAssertThrowsError(try endpoint.parse(Data("[{\"id\":\"x\",\"mini\":\(invalid)}]".utf8)))
        }
        let legacy = try JSONDecoder().decode(ModelDescriptor.self, from: Data(#"{"id":"legacy","name":"","description":"","deprecated":false}"#.utf8))
        XCTAssertNil(legacy.mini)
        var profile = ProfileRecord(); profile.baseUrl = "https://gateway.example"; profile.catalogUrl = "https://catalog.example/models?access_token=private-value"
        XCTAssertEqual(CatalogModelPicker.sourceLabel(profile), "catalog.example/models")
        XCTAssertFalse(CatalogModelPicker.sourceLabel(profile).contains("private-value"))
    }

    func testAcceptsBareArrayAndRejectsDuplicatesOrMissingIds() throws {
        XCTAssertEqual(try endpoint.parse(Data("[{\"id\": \"x\"}]".utf8)).map(\.id), ["x"])
        XCTAssertThrowsError(try endpoint.parse(Data("{\"models\": [{\"id\": \"x\"}, {\"id\": \"x\"}]}".utf8)))
        XCTAssertThrowsError(try endpoint.parse(Data("{\"models\": [{\"name\": \"no id\"}]}".utf8)))
        XCTAssertThrowsError(try endpoint.parse(Data("{\"data\": []}".utf8)))
        XCTAssertThrowsError(try ModelCatalogEndpoint.url("ftp://x"))
        XCTAssertThrowsError(try ModelCatalogEndpoint.url("https://user:pw@host/catalog"))
        XCTAssertEqual(try ModelCatalogEndpoint.url(" https://models.example.com/catalog.json ").host, "models.example.com")
    }

    func testCatalogURLAndCredentialOriginsAreStrict() throws {
        for invalid in ["http://models.example/catalog", "https://models.example/catalog#fragment", "https://models.example:0/catalog", "https://models.example/a b", "https://models.example/catalog\nkey"] {
            XCTAssertThrowsError(try ModelCatalogEndpoint.url(invalid), invalid)
        }
        for value in ["http://127.0.0.1/catalog", "http://localhost:8080/catalog", "http://[::1]/catalog", "https://models.example/catalog?version=1"] {
            XCTAssertNoThrow(try ModelCatalogEndpoint.url(value), value)
        }
        let base = "https://gateway.example/proxy/v1/responses"
        XCTAssertTrue(ModelCatalogEndpoint.usesGatewayCredential(try ModelCatalogEndpoint.url("https://gateway.example:443/catalog"), base: base, api: "openai-responses"))
        for value in ["https://models.example/catalog", "https://gateway.example:444/catalog", "http://localhost/catalog"] {
            XCTAssertFalse(ModelCatalogEndpoint.usesGatewayCredential(try ModelCatalogEndpoint.url(value), base: base, api: "openai-responses"))
        }
    }

    func testMalformedNumbersCannotCrashOrBecomeTokenLimits() throws {
        for body in [#"{"version":true,"models":[]}"#, #"{"version":2,"models":[]}"#, #"{"version":1.5,"models":[]}"#,
                     #"[{"id":"x","order":1e100}]"#, #"[{"id":"x","order":-1e100}]"#, #"[{"id":"x","order":true}]"#, #"[{"id":"x","order":0.5}]"#,
                     #"[{"id":"x","contextWindow":true}]"#, #"[{"id":"x","maxOutputTokens":2.5}]"#, #"[{"id":"x","contextWindow":10000001}]"#,
                     #"[{"id":"x","maxOutputTokens":1000001}]"#, #"[{"id":"x","maxOutputTokens":0}]"#, #"[{"id":"x","deprecated":1}]"#] {
            XCTAssertThrowsError(try endpoint.parse(Data(body.utf8)), body)
        }
        let boundary = try endpoint.parse(Data("[{\"id\":\"unordered\"},{\"id\":\"last-ordered\",\"order\":\(Int.max)}]".utf8))
        XCTAssertEqual(boundary.map(\.id), ["last-ordered", "unordered"])
    }

    func testReasoningAbsenceAndEmptyListHaveDifferentMeaningAndUnicodeIsByteBounded() throws {
        let name = String(repeating: "🧠", count: 1000)
        let body = try JSONSerialization.data(withJSONObject: [["id": "unknown"], ["id": "none", "reasoning": [], "name": name, "description": name]])
        let models = try endpoint.parse(body)
        XCTAssertNil(models[0].reasoning)
        XCTAssertEqual(models[0].offeredThinkingLevels, ThinkingLevel.allCases)
        XCTAssertEqual(models[1].reasoning, [])
        XCTAssertEqual(models[1].offeredThinkingLevels, [.profileDefault, .default])
        XCTAssertLessThanOrEqual(models[1].name.utf8.count, 2048)
        XCTAssertLessThanOrEqual(models[1].description.utf8.count, 2048)
        XCTAssertFalse(models[1].description.contains("�"))
        let duplicate = Data(#"[{"id":"synthetic-secret"},{"id":"synthetic-secret"}]"#.utf8)
        XCTAssertThrowsError(try endpoint.parse(duplicate)) { XCTAssertFalse($0.localizedDescription.contains("synthetic-secret")) }
    }

    func testSelectingPartialLimitsProducesValidProfileAndClearsIncompatibleEffort() throws {
        var profile = ProfileRecord(); profile.modelId = "old"; profile.baseUrl = "https://gateway.example"
        profile.advancedJSON = #"{"reasoning":true,"thinkingLevel":"high","thinkingLevelMap":{"low":"high"}}"#
        let selected = ModelDescriptor(id: "small", name: "Small", contextWindow: 2048, reasoning: []).applying(to: profile)
        XCTAssertEqual(selected.contextWindow, 2048); XCTAssertEqual(selected.maxOutputTokens, 2047)
        XCTAssertEqual(selected.configuration["reasoning"], .bool(false)); XCTAssertNil(selected.configuration["thinkingLevel"])
        XCTAssertNil(selected.configuration["thinkingLevelMap"])
        XCTAssertNoThrow(try LiteLLMConfiguration.validate(selected, headers: [:]))
    }

    func testRealCatalogRequestRefusesRedirectsAndBoundsTheBody() async throws {
        let destination = try ModelListGateway { _ in .json(#"[{"id":"unexpected"}]"#) }
        defer { destination.stop() }
        let destinationURL = try await destination.start()
        let source = try ModelListGateway { _ in .init(bytes: Data("HTTP/1.1 307 Temporary Redirect\r\nLocation: \(destinationURL)/stolen\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)) }
        defer { source.stop() }
        let sourceURL = try await source.start()
        do { _ = try await endpoint.fetch(url: URL(string: sourceURL + "/catalog")!, key: "synthetic-only"); XCTFail("Redirect must be refused") }
        catch { XCTAssertEqual(error as? ModelCatalogEndpoint.Failure, .redirected) }
        XCTAssertEqual(source.requests.count, 1); XCTAssertTrue(destination.requests.isEmpty)
        XCTAssertTrue(source.requests[0].lowercased().contains("authorization: bearer synthetic-only\r\n"))
        for declared in [true, false] {
            let gateway = try ModelListGateway { _ in
                .init(bytes: Data(("HTTP/1.1 200 OK\r\n" + (declared ? "Content-Length: 4096\r\n" : "") + "Connection: close\r\n\r\n" + String(repeating: "x", count: 4096)).utf8))
            }
            defer { gateway.stop() }
            let base = try await gateway.start()
            do { _ = try await ModelCatalogEndpoint(limits: .init(timeout: 2, bodyBytes: 128)).fetch(url: URL(string: base)!, key: ""); XCTFail("Oversized body must fail") }
            catch { XCTAssertEqual(error as? ModelCatalogEndpoint.Failure, .oversized) }
        }
    }

    func testCatalogTimeoutAndInvalidCredentialAreBounded() async throws {
        let gateway = try ModelListGateway { _ in nil }; defer { gateway.stop() }
        let base = try await gateway.start(), url = URL(string: base)!, began = Date()
        do { _ = try await ModelCatalogEndpoint(limits: .init(timeout: 1)).fetch(url: url, key: ""); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? ModelCatalogEndpoint.Failure, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
        do { _ = try await endpoint.fetch(url: url, key: "key\r\nInjected: value"); XCTFail("Expected credential validation") }
        catch { XCTAssertEqual(error as? ModelCatalogEndpoint.Failure, .credential) }
        XCTAssertEqual(gateway.requests.count, 1)
    }

    @MainActor func testExternalCatalogNeverResolvesOrReceivesGatewayCredential() async throws {
        var profile = ProfileRecord(); profile.id = "p"; profile.baseUrl = "https://gw.example.com"; profile.catalogUrl = "https://models.example.com/catalog.json"
        let catalog = ModelCatalog(readBundled: { XCTFail("An explicit catalog replaces the bundle"); return [] }, fetchCatalog: { _, key in
            XCTAssertTrue(key.isEmpty)
            return [ModelDescriptor(id: "external", name: "External")]
        })
        _ = await catalog.load(profile: profile) { XCTFail("External catalog must not read the key"); return "synthetic-only" }
        profile.catalogUrl = "https://gw.example.com/catalog"
        let sameOrigin = ModelCatalog(fetchCatalog: { _, key in
            XCTAssertEqual(key, "synthetic-only"); return []
        })
        _ = await sameOrigin.load(profile: profile) { "synthetic-only" }
        let endpoint = try ModelListGateway { _ in .json(#"[{"id":"public-model"}]"#) }
        defer { endpoint.stop() }
        let externalURL = try await endpoint.start()
        profile.catalogUrl = externalURL + "/public-catalog"
        let live = ModelCatalog()
        let models = await live.load(profile: profile) { XCTFail("Public catalog must not read a gateway key"); return "synthetic-secret" }
        XCTAssertEqual(models, ["public-model"])
        XCTAssertEqual(endpoint.requests.count, 1)
        XCTAssertFalse(endpoint.requests[0].lowercased().contains("authorization:"))
        XCTAssertFalse(endpoint.requests[0].lowercased().contains("cookie:"))
    }

    @MainActor func testConfiguredCatalogIsTheOnlySourceAndRefreshesEveryFiveMinutes() async {
        final class Clock: @unchecked Sendable { var date = Date(timeIntervalSince1970: 1_000) }
        actor Counter { var calls = 0; func hit() -> Int { calls += 1; return calls } }
        var profile = ProfileRecord(); profile.id = "p"; profile.baseUrl = "https://gw.example.com"; profile.catalogUrl = "https://models.example.com/catalog.json"
        let clock = Clock(), fetches = Counter()
        let working = ModelCatalog(now: { clock.date }, readBundled: { XCTFail("An explicit catalog replaces the bundle"); return [] }, fetchCatalog: { _, _ in
            _ = await fetches.hit()
            return [ModelDescriptor(id: "cat-1", name: "One"), ModelDescriptor(id: "cat-old", name: "Old", deprecated: true)]
        })
        let listed = await working.load(profile: profile) { "key" }
        XCTAssertEqual(listed, ["cat-1"], "deprecated entries are not offered")
        XCTAssertEqual(working.entry(for: "p").source, "catalog")
        XCTAssertEqual(working.entry(for: "p").offered(current: "cat-old").map(\.id), ["cat-1", "cat-old"], "a chosen deprecated model stays visible")
        clock.date = clock.date.addingTimeInterval(240)
        _ = await working.load(profile: profile) { "key" }
        var calls = await fetches.calls; XCTAssertEqual(calls, 1, "A catalog list stays fresh within the five-minute window")
        clock.date = clock.date.addingTimeInterval(120)
        _ = await working.load(profile: profile) { "key" }
        calls = await fetches.calls; XCTAssertEqual(calls, 2, "A catalog older than five minutes is fetched again on the next access")

        let broken = ModelCatalog(readBundled: { XCTFail("A broken custom catalog must not fall back to the bundle"); return [] }, fetchCatalog: { _, _ in throw ModelCatalogEndpoint.Failure.http(500) })
        let failed = await broken.load(profile: profile) { "key" }
        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(broken.entry(for: "p").source, "catalog")
        XCTAssertEqual(broken.entry(for: "p").error, ModelCatalogEndpoint.Failure.http(500).errorDescription)

        var malformed = profile; malformed.catalogUrl = "http://remote.example/catalog"
        let invalid = ModelCatalog(readBundled: { XCTFail("An invalid custom URL must not fall back to the bundle"); return [] }, fetchCatalog: { _, _ in XCTFail("An invalid catalog URL is never contacted"); return [] })
        _ = await invalid.load(profile: malformed) { "key" }
        XCTAssertEqual(invalid.entry(for: "p").error, ModelCatalogEndpoint.Failure.url.errorDescription)
    }

    @MainActor func testFailedCatalogRefreshKeepsLastListAndBacksOff() async {
        final class Clock: @unchecked Sendable { var date = Date(timeIntervalSince1970: 1_000) }
        actor Counter { var calls = 0; func hit() -> Int { calls += 1; return calls } }
        var profile = ProfileRecord(); profile.id = "p"; profile.baseUrl = "https://gw.example.com"; profile.catalogUrl = "https://models.example.com/catalog.json"
        let clock = Clock(), fetches = Counter()
        let flaky = ModelCatalog(now: { clock.date }, readBundled: { XCTFail("A custom refresh must not read the bundle"); return [] }, fetchCatalog: { _, _ in
            if await fetches.hit() > 1 { throw ModelCatalogEndpoint.Failure.http(503) }
            return [ModelDescriptor(id: "cat-1", name: "One")]
        })
        let initial = await flaky.load(profile: profile) { "key" }
        XCTAssertEqual(initial, ["cat-1"])
        clock.date = clock.date.addingTimeInterval(3_601)
        let stale = await flaky.load(profile: profile) { "key" }
        XCTAssertEqual(stale, ["cat-1"], "A failed hourly refresh keeps the last list")
        XCTAssertEqual(flaky.entry(for: "p").error, ModelCatalogEndpoint.Failure.http(503).errorDescription)
        _ = await flaky.load(profile: profile) { "key" }
        var calls = await fetches.calls; XCTAssertEqual(calls, 2, "A failure is not retried immediately")
        clock.date = clock.date.addingTimeInterval(31)
        _ = await flaky.load(profile: profile) { "key" }
        calls = await fetches.calls; XCTAssertEqual(calls, 3, "The failure backoff expires")
        _ = await flaky.load(profile: profile, force: true) { "key" }
        calls = await fetches.calls; XCTAssertEqual(calls, 4, "Refresh forces a fetch")
    }

    @MainActor func testVisibleSessionPickerLoadsSavedCatalogWithoutHoverAndTracksSavedChanges() async throws {
        let models = (1...130).map { ["id": "catalog-\($0)", "name": "Catalog \($0)"] }
        let firstBody = String(decoding: try JSONSerialization.data(withJSONObject: ["models": models]), as: UTF8.self)
        let endpoint = try ModelListGateway { request in
            if request.hasPrefix("GET /catalog-one HTTP/1.1\r\n") { return .json(firstBody) }
            if request.hasPrefix("GET /catalog-two HTTP/1.1\r\n") { return .json(#"{"models":[{"id":"catalog-new","name":"New catalog"}]}"#) }
            XCTFail("The visible picker must use only its connection's configured catalog")
            return .json(#"{"models":[]}"#)
        }
        defer { endpoint.stop() }
        let base = try await endpoint.start()
        let root = URL(fileURLWithPath: scratchBase())
            .appendingPathComponent("picker-catalog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var profile = ProfileRecord(); profile.id = "visible"; profile.baseUrl = "https://gateway.invalid"; profile.modelId = "manual-router"
        profile.catalogUrl = base + "/catalog-one"
        var unused = profile; unused.id = "unused"; unused.catalogUrl = base + "/unused-catalog"
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        let connections = [VaultProfile(profile: profile, apiKey: "synthetic-only"), VaultProfile(profile: unused, apiKey: "synthetic-only")]
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = connections }
        let model = WorkspaceModel(stateRoot: root, vault: vault)
        let chat = ChatRecord(id: "chat", workspaceID: "project", title: "Chat", path: nil, profileID: profile.id)
        try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.restore()
        XCTAssertEqual(model.chat?.profileID, profile.id, "A restored chat uses its saved connection, not an unrelated model picker source")
        let session = SessionDisplay(id: chat.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { model.shutdown(); window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root) }
        let hosted = NSHostingView(rootView: ModelSwitchPills(model: model, session: session))
        window.contentView = hosted
        // Mount without ordering the window front: no pointer/hover or menu
        // activation can accidentally trigger the old loading path.
        hosted.layoutSubtreeIfNeeded()
        try await waitForPickerCatalog { model.modelCatalog.entry(for: profile).models.count == models.count }
        XCTAssertEqual(model.modelCatalog.entry(for: profile).source, "catalog")
        XCTAssertEqual(model.modelCatalog.entry(for: profile).models.last, "catalog-130")
        XCTAssertTrue(model.modelCatalog.entry(for: unused).models.isEmpty)
        XCTAssertEqual(endpoint.requests.count, 1)
        let firstRequest = try XCTUnwrap(endpoint.requests.first)
        XCTAssertFalse(firstRequest.lowercased().contains("authorization:"), "An external catalog never needs gateway credentials")

        // Editing a local settings draft must not affect the session. Only a
        // saved profile published by WorkspaceModel restarts the picker task.
        var revised = profile; revised.catalogUrl = base + "/catalog-two"; revised.revision = UUID().uuidString
        hosted.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.modelCatalog.entry(for: profile).models.count, 130)
        XCTAssertEqual(endpoint.requests.count, 1)
        model.profiles = [revised, unused]
        XCTAssertTrue(model.modelCatalog.entry(for: revised).models.isEmpty, "The old profile's cached list must not be presented as the revised catalog")
        try await waitForPickerCatalog { model.modelCatalog.entry(for: revised).models == ["catalog-new"] }
        XCTAssertEqual(endpoint.requests.count, 2)
        XCTAssertTrue(endpoint.requests.allSatisfy { !$0.contains("/v1/models") && !$0.contains("/unused-catalog") })
        XCTAssertEqual(model.chats[0], chat, "Catalog refresh must preserve the connection default and session override")
        XCTAssertTrue(model.hosts.isEmpty)
        await model.store?.close()
    }

    @MainActor func testVisibleChatCatalogRefreshFetchesAgainAndUpdatesRows() async throws {
        let calls = BundleReadCounter()
        let endpoint = try ModelListGateway { request in
            XCTAssertTrue(request.hasPrefix("GET /catalog HTTP/1.1\r\n"))
            calls.record()
            return .json(calls.count == 1
                         ? #"{"models":[{"id":"old-model","name":"Original Catalog Choice"}]}"#
                         : #"{"models":[{"id":"new-model","name":"Refreshed Catalog Choice"}]}"#)
        }
        defer { endpoint.stop() }
        let base = try await endpoint.start()
        let root = URL(fileURLWithPath: scratchBase())
            .appendingPathComponent("picker-refresh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var profile = ProfileRecord(); profile.id = "refresh"; profile.modelId = "old-model"
        profile.name = "Chat connection"
        profile.baseUrl = "https://gateway.invalid"; profile.catalogUrl = base + "/catalog"
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        let connection = VaultProfile(profile: profile, apiKey: "synthetic-only")
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [connection] }
        let model = WorkspaceModel(stateRoot: root, vault: vault)
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "chat", workspaceID: "project", title: "Chat", path: nil, profileID: profile.id)
        model.chats = [chat]; model.selectedID = chat.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 422, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        let hosted = NSHostingView(rootView: CatalogModelPicker(model: model, profile: profile, current: profile.modelId) { _ in })
        window.contentView = hosted; window.center(); window.makeKeyAndOrderFront(nil)
        defer { model.shutdown(); window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root) }
        try await waitForPickerCatalog { model.modelCatalog.entry(for: profile).models == ["old-model"] }
        let initial = try await Self.renderedText(window, filename: "chat-picker-before-refresh.jpg")
        XCTAssertTrue(initial.contains("original catalog choice"), initial)
        // Exercise the same explicit-refresh action as the chat popover, then
        // inspect its mounted content without closing or recreating the view.
        let refresh = ModelCatalogRefreshState()
        await refresh.refresh(model: model, profileID: chat.profileID)
        XCTAssertFalse(refresh.loading); XCTAssertNil(refresh.error)
        XCTAssertEqual(endpoint.requests.count, 2)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(model.modelCatalog.entry(for: profile).models, ["new-model"])
        let refreshed = try await Self.renderedText(window, filename: "chat-picker-after-refresh.jpg")
        XCTAssertTrue(refreshed.contains("refreshed catalog choice"), refreshed)
        XCTAssertFalse(refreshed.contains("original catalog choice"), refreshed)
        XCTAssertEqual(model.chats, [chat], "Refreshing the list must not modify the selected model or effort")
        XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertTrue(endpoint.requests.allSatisfy { !$0.lowercased().contains("authorization:") })
        await model.store?.close(); try await model.traces.close()
    }

    @MainActor func testLegacyPickerShowsDirectRepairAndChangesItsMountedRowsAfterSelection() async throws {
        let endpoint = try ModelListGateway { request in
            request.hasPrefix("GET /old ")
                ? .json(#"[{"id":"original-model","name":"Original Model Choice"}]"#)
                : .json(#"[{"id":"repaired-model","name":"Repaired Model Choice"}]"#)
        }
        defer { endpoint.stop() }
        let base = try await endpoint.start()
        let root = URL(fileURLWithPath: scratchBase())
            .appendingPathComponent("legacy-picker-repair-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var original = ProfileRecord(); original.id = "original"; original.name = "Original connection"
        original.baseUrl = "https://gateway.invalid"; original.modelId = "original-model"; original.catalogUrl = base + "/old"
        var saved = original; saved.id = "saved"; saved.name = "Updated connection"
        saved.modelId = "repaired-model"; saved.catalogUrl = base + "/custom?token=synthetic-query-token"
        let connections = [VaultProfile(profile: original, apiKey: "synthetic-original-key"), VaultProfile(profile: saved, apiKey: "synthetic-saved-key")]
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = connections }
        let model = WorkspaceModel(stateRoot: root, vault: vault)
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "legacy-chat", workspaceID: "project", title: "Chat", path: nil,
                              profileID: original.id, model: "original-model", thinkingLevel: "high")
        model.chats = [chat]; model.selectedID = chat.id; model.profileChoice = original.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 422, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        let hosted = NSHostingView(rootView: CatalogModelPicker(model: model, profile: original, current: chat.model, allowsCatalogSelection: true) { _ in })
        window.contentView = hosted; window.center(); window.makeKeyAndOrderFront(nil)
        defer { model.shutdown(); window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root) }
        try await waitForPickerCatalog { model.catalogEntry(for: original).models == ["original-model"] }
        let before = try await Self.renderedText(window, filename: "legacy-picker-repair-before.jpg")
        XCTAssertTrue(before.contains("this chat uses its original model list"), before)
        XCTAssertTrue(before.contains("use this catalog"), before)
        XCTAssertTrue(before.contains("updated connection"), before)
        XCTAssertFalse(before.contains("synthetic-query-token"), "Catalog query values must not be displayed")
        XCTAssertTrue(endpoint.requests.allSatisfy { $0.hasPrefix("GET /old ") }, "Suggestions must not fetch another catalog until selected")

        // Run the action shared by the visible repair button, keeping its actual
        // SwiftUI view mounted to verify that the old list disappears in place.
        let refresh = ModelCatalogRefreshState()
        await refresh.selectSource(model: model, sourceID: saved.id, profileID: original.id)
        XCTAssertNil(refresh.error)
        try await waitForPickerCatalog { model.catalogEntry(for: original).models == ["repaired-model"] }
        let after = try await Self.renderedText(window, filename: "legacy-picker-repair-after.jpg")
        XCTAssertTrue(after.contains("repaired model choice"), after)
        XCTAssertFalse(after.contains("original model choice"), after)
        XCTAssertFalse(after.contains("this chat uses its original model list"), after)
        XCTAssertEqual(model.record(chat.id), chat)
        XCTAssertEqual(model.configuration.profiles, connections)
        XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertTrue(endpoint.requests.allSatisfy { !$0.lowercased().contains("authorization:") })
        await model.store?.close(); try await model.traces.close()
    }

    @MainActor func testVisibleDefaultPickerShowsBundledCatalogWithoutReadingTheVaultOrGateway() async throws {
        let gateway = try ModelListGateway { _ in
            XCTFail("Opening the default picker must not ask the gateway for models")
            return .json(#"{"data":[{"id":"gateway-only-wrong-list"}]}"#)
        }
        defer { gateway.stop() }
        let base = try await gateway.start()
        let root = URL(fileURLWithPath: scratchBase())
            .appendingPathComponent("bundled-picker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = CatalogCredentialReadSpy()
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: storage))
        var profile = ProfileRecord(); profile.id = "bundled"; profile.name = "Fixture connection"
        profile.modelId = "auto-router"; profile.baseUrl = base
        model.profiles = [profile]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 422, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        defer { model.shutdown(); window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root) }
        let hosted = NSHostingView(rootView: CatalogModelPicker(model: model, profile: profile, current: profile.modelId) { _ in })
        window.contentView = hosted; window.center(); window.makeKeyAndOrderFront(nil)
        try await waitForPickerCatalog { model.modelCatalog.entry(for: profile).models.count == 6 }
        XCTAssertEqual(model.modelCatalog.entry(for: profile).source, "bundled")
        XCTAssertEqual(model.modelCatalog.entry(for: profile).descriptors, try ModelCatalogEndpoint.bundled())
        XCTAssertEqual(CatalogModelPicker.sourceLabel(profile), "Included with Bello Agent")
        XCTAssertFalse(CatalogModelPicker.sourceLabel(profile).contains("127.0.0.1"))
        let rendered = try await Self.renderedText(window, filename: "catalog-picker-bundled-default.jpg")
        XCTAssertTrue(rendered.contains("model catalog"), "The picker must identify the curated source. OCR: \(rendered)")
        XCTAssertTrue(rendered.contains("deepseek v4.1 flash"), "The bundled display name must render. OCR: \(rendered)")
        XCTAssertTrue(rendered.contains("glm 5.3 flash"), "A second bundled display name must render. OCR: \(rendered)")
        XCTAssertTrue(rendered.contains("6 models"), "The six-entry curated catalog must be visible. OCR: \(rendered)")
        XCTAssertFalse(rendered.contains("gateway models")); XCTAssertFalse(rendered.contains("gateway-only-wrong-list"))
        XCTAssertEqual(storage.reads, 0, "The default picker must not open Keychain merely to list models")
        XCTAssertTrue(gateway.requests.isEmpty)
        XCTAssertTrue(model.hosts.isEmpty)
        await model.store?.close()
    }

    @MainActor func testLivePickerRendersTheConfiguredCatalogAndClearsRowsAfterSourceEditFailure() async throws {
        let endpoint = try ModelListGateway { request in
            if request.hasPrefix("GET /catalog HTTP/1.1\r\n") {
                return .json(#"{"models":[{"id":"catalog-only","name":"Visible Catalog Choice","mini":true},{"id":"catalog-second","name":"Second Catalog Choice"}]}"#)
            }
            if request.hasPrefix("GET /broken HTTP/1.1\r\n") { return .json(#"{"data":[{"id":"gateway-shaped-wrong-list"}]}"#) }
            XCTFail("No gateway or other connection source may be consulted")
            return .json(#"{"models":[]}"#)
        }
        defer { endpoint.stop() }
        let base = try await endpoint.start()
        let root = URL(fileURLWithPath: scratchBase())
            .appendingPathComponent("live-picker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        var profile = ProfileRecord(); profile.id = "saved-connection"; profile.name = "Fixture connection"
        profile.modelId = "unlisted-manual-router"; profile.baseUrl = "https://gateway.invalid"; profile.catalogUrl = base + "/catalog"
        model.profiles = [profile]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 422, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        defer { model.shutdown(); window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root) }
        let hosted = NSHostingView(rootView: CatalogModelPicker(model: model, profile: profile, current: profile.modelId) { _ in })
        window.contentView = hosted; window.center(); window.makeKeyAndOrderFront(nil)
        try await waitForPickerCatalog { model.modelCatalog.entry(for: profile).models.count == 2 }
        let rendered = try await Self.renderedText(window, filename: "catalog-picker.jpg")
        XCTAssertTrue(rendered.contains("visible catalog choice"), "First rendered model name missing. OCR: \(rendered)")
        XCTAssertTrue(rendered.contains("second catalog choice"), "Second rendered model name missing. OCR: \(rendered)")
        XCTAssertTrue(rendered.contains("catalog-only"), "First rendered alias missing. OCR: \(rendered)")
        XCTAssertTrue(rendered.contains("catalog-second"), "Second rendered alias missing. OCR: \(rendered)")
        XCTAssertTrue(rendered.contains("not listed by this source"), "The manual selection must be explained separately, not fabricated as a catalog result. OCR: \(rendered)")
        XCTAssertFalse(rendered.contains("gateway-shaped-wrong-list"))
        XCTAssertEqual(endpoint.requests.count, 1)
        XCTAssertFalse(endpoint.requests[0].lowercased().contains("authorization:"))

        // While open, changing the saved URL must remove the old source's rows;
        // a malformed replacement cannot resurrect them or switch to /v1/models.
        var revised = profile; revised.catalogUrl = base + "/broken"; revised.revision = UUID().uuidString
        model.profiles = [revised]
        hosted.rootView = CatalogModelPicker(model: model, profile: revised, current: profile.modelId) { _ in }
        try await waitForPickerCatalog { model.modelCatalog.entry(for: revised).error != nil }
        hosted.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.modelCatalog.entry(for: revised).source, "catalog")
        XCTAssertTrue(model.modelCatalog.entry(for: revised).offered(current: profile.modelId).isEmpty)
        let failed = try await Self.renderedText(window, filename: "catalog-picker-source-error.jpg")
        XCTAssertFalse(failed.contains("visible catalog choice"), "A failed edited source must remove the old rendered row. OCR: \(failed)")
        XCTAssertFalse(failed.contains("second catalog choice"), "A failed edited source must remove every old rendered row. OCR: \(failed)")
        XCTAssertFalse(failed.contains("catalog-only"))
        XCTAssertFalse(failed.contains("catalog-second"))
        XCTAssertTrue(failed.contains("catalog response was not in the expected format"), "The actual source failure must be visible. OCR: \(failed)")
        XCTAssertEqual(endpoint.requests.count, 2)
        XCTAssertTrue(endpoint.requests.allSatisfy { !$0.contains("/v1/models") })
        await model.store?.close()
    }

    /// The test host does not expose SwiftUI virtual nodes through in-process
    /// accessibility getters. Read the actual own-window pixels instead, so
    /// stale/unrendered picker content cannot pass through a cache assertion.
    @MainActor private static func renderedText(_ window: NSWindow, filename: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(300))
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        XCTAssertTrue(window.isVisible)
        typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"))
        let create = unsafeBitCast(symbol, to: ListImage.self)
        let image = try XCTUnwrap(create(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber),
                                        CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
        if let path = testEnvironment("PI_APP_USAGE_CAPTURE_ROOT") {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let jpeg = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.82]))
            try jpeg.write(to: folder.appendingPathComponent(filename), options: .atomic)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ").lowercased()
    }

    @MainActor private func waitForPickerCatalog(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The visible session picker did not load its saved model catalog")
    }
}

private final class BundleReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    var count: Int { lock.withLock { reads } }
    func record() { lock.withLock { reads += 1 } }
}

private final class CatalogCredentialReadSpy: VaultStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func read() throws -> Data? {
        lock.withLock { count += 1 }
        throw VaultError.denied(-25308)
    }
    func replace(expected: Data?, with replacement: Data) throws {
        XCTFail("Listing bundled models must never write the vault")
        throw VaultError.denied(-25308)
    }
}
