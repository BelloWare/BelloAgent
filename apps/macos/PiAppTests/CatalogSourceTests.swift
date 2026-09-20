import XCTest
@testable import PiApp

final class CatalogSourceTests: XCTestCase {
    @MainActor func testDefaultModelForkKeepsOriginalRouteButFollowsSavedCatalogAndRefreshesItsURL() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try ModelListGateway { request in
            if request.hasPrefix("GET /latest ") { return .json(#"[{"id":"catalog-latest"}]"#) }
            if request.hasPrefix("GET /updated ") { return .json(#"[{"id":"catalog-updated"}]"#) }
            return .json(#"[{"id":"catalog-original"}]"#)
        }
        defer { gateway.stop() }
        let base = try await gateway.start()
        let original = connection(id: "original", base: base, catalog: "/original")
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [original] }
        let model = WorkspaceModel(stateRoot: root, vault: vault); defer { model.shutdown() }
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "chat", workspaceID: "project", title: "Retained chat", path: nil,
                              profileID: original.profile.id, model: "retained-model", thinkingLevel: "high",
                              contextWindow: 64_000, maxOutputTokens: 8_000)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        let initial = await model.listModels(for: original.profile)
        XCTAssertEqual(initial, ["catalog-original"])

        var edited = original.profile; edited.modelId = "new-default"; edited.catalogUrl = base + "/latest"
        try await model.saveProfile(edited, key: "")
        let fork = try XCTUnwrap(model.profiles.first { $0.id == model.profileChoice })
        XCTAssertNotEqual(fork.id, original.profile.id)
        XCTAssertEqual(model.configuration.catalogSources, [original.profile.id: fork.id])
        XCTAssertTrue(model.catalogRepairChoices(for: original.profile).isEmpty,
                      "A new default-model fork already records its catalog lineage and needs no repair banner")
        model.profileChoice = original.profile.id
        XCTAssertTrue(model.catalogRepairChoices(for: original.profile).isEmpty)
        XCTAssertEqual(model.configuration.profiles.first { $0.profile.id == original.profile.id }, original)
        XCTAssertEqual(model.record(chat.id), chat, "Changing a catalog must not retarget or reset an existing chat")
        let refreshed = try await model.refreshModels(profileID: original.profile.id)
        XCTAssertEqual(refreshed, ["catalog-latest"])
        XCTAssertEqual(model.catalogProfile(for: original.profile), fork)
        XCTAssertEqual(model.catalogEntry(for: original.profile).models, ["catalog-latest"])
        XCTAssertTrue(model.catalogRepairChoices(for: original.profile).isEmpty)
        let routeCredentials = try await model.credentials(for: original.profile)
        XCTAssertEqual(routeCredentials["apiKey"], .string(original.apiKey))

        var updated = fork; updated.catalogUrl = base + "/updated"
        try await model.saveProfile(updated, key: "")
        XCTAssertEqual(model.profileChoice, fork.id, "A catalog-only edit keeps its authority identity")
        let revised = try await model.refreshModels(profileID: original.profile.id)
        XCTAssertEqual(revised, ["catalog-updated"])
        XCTAssertTrue(model.catalogRepairChoices(for: original.profile).isEmpty)
        XCTAssertEqual(model.configuration.profiles.first { $0.profile.id == original.profile.id }, original)
        XCTAssertEqual(model.record(chat.id), chat)
        let persistedChat = try await model.store?.get(ChatRecord.self, kind: "chat", id: chat.id)
        XCTAssertEqual(persistedChat, chat)
        XCTAssertEqual(gateway.requests.count, 3)
        XCTAssertTrue(gateway.requests[2].hasPrefix("GET /updated "))
        XCTAssertTrue(gateway.requests.allSatisfy { $0.lowercased().contains("cache-control: no-cache\r\n") },
                      "A deliberate refresh must also ask intermediary caches to revalidate")
        XCTAssertTrue(model.hosts.isEmpty, "Model-list repair must not start a conversation helper")
        await model.store?.close(); try await model.traces.close()
    }

    @MainActor func testLegacyConnectionsStayIndependentUntilExplicitSelectionAndPersistDescriptorSource() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try ModelListGateway { request in
            request.hasPrefix("GET /custom ")
                ? .json(#"[{"id":"compact","name":"Compact catalog model","contextWindow":64000,"maxOutputTokens":8000,"reasoning":["low"]}]"#)
                : .json(#"[{"id":"legacy-model","contextWindow":128000,"maxOutputTokens":16000,"reasoning":["high"]}]"#)
        }
        defer { gateway.stop() }
        let base = try await gateway.start()
        let route = connection(id: "legacy", base: base, catalog: "/legacy")
        let source = connection(id: "custom", base: base, catalog: "/custom", key: "synthetic-source-key")
        let storage = MemoryVaultStorage(), vault = ConfigurationVault(storage: storage)
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [route, source] }
        let model = WorkspaceModel(stateRoot: root, vault: vault); defer { model.shutdown() }
        try await model.reloadConfiguration(); model.profileChoice = source.profile.id
        let chat = ChatRecord(id: "chat", workspaceID: "project", title: "Existing chat", path: nil,
                              profileID: route.profile.id, model: "retained-alias", thinkingLevel: "high",
                              contextWindow: 96_000, maxOutputTokens: 2_048, modelOutputLimit: 16_000)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        XCTAssertEqual(model.catalogRepairChoices(for: route.profile).map(\.id), [source.profile.id])
        await model.select(chat.id)
        XCTAssertEqual(model.profileChoice, route.profile.id, "Selecting an old chat restores its original request connection")
        XCTAssertEqual(model.catalogRepairChoices(for: route.profile).map(\.id), [source.profile.id],
                       "Repair discovery must not depend on the new-chat profileChoice")

        let independent = try await model.refreshModels(profileID: route.profile.id)
        XCTAssertEqual(independent, ["legacy-model"])
        XCTAssertNil(model.configuration.catalogSources, "Similar old profiles are not proof of shared catalog lineage")
        XCTAssertEqual(model.catalogProfile(for: route.profile), route.profile)
        let picker = ModelCatalogRefreshState()
        await picker.selectSource(model: model, sourceID: source.profile.id, profileID: route.profile.id)
        XCTAssertNil(picker.error); XCTAssertFalse(picker.loading)
        XCTAssertEqual(model.catalogEntry(for: route.profile).models, ["compact"])
        XCTAssertEqual(model.configuration.catalogSources, [route.profile.id: source.profile.id])
        XCTAssertTrue(model.catalogRepairChoices(for: route.profile).isEmpty)
        let descriptor = try XCTUnwrap(model.catalogEntry(for: route.profile).descriptor(for: "compact"))
        XCTAssertEqual(descriptor.contextWindow, 64_000); XCTAssertEqual(descriptor.maxOutputTokens, 8_000)
        XCTAssertEqual(descriptor.offeredThinkingLevels.map(\.rawValue), ["profile-default", "default", "low"])
        XCTAssertEqual(model.configuration.profiles, [route, source])
        XCTAssertEqual(model.record(chat.id), chat, "Selecting a list is separate from selecting a model")
        let unchangedChat = try await model.store?.get(ChatRecord.self, kind: "chat", id: chat.id)
        XCTAssertEqual(unchangedChat, chat, "Rebinding must preserve the persisted selected alias, effort, budget and model limits")
        let retainedCredentials = try await model.credentials(for: route.profile)
        XCTAssertEqual(retainedCredentials["apiKey"], .string(route.apiKey))
        XCTAssertEqual(retainedCredentials["headers"], .object(route.headers.mapValues(WireValue.string)))
        await picker.refresh(model: model, profileID: route.profile.id)
        XCTAssertNil(picker.error); XCTAssertFalse(picker.loading)
        XCTAssertEqual(model.catalogEntry(for: route.profile).models, ["compact"])
        XCTAssertEqual(model.record(chat.id), chat)

        await model.setModel(descriptor.id, for: chat.id)
        let selected = try XCTUnwrap(model.record(chat.id))
        XCTAssertEqual(selected.model, "compact"); XCTAssertEqual(selected.profileID, route.profile.id)
        XCTAssertEqual(selected.contextWindow, 64_000); XCTAssertEqual(selected.maxOutputTokens, 4_096)
        XCTAssertEqual(selected.modelOutputLimit, 8_000, "Catalog output ceilings must remain separate from requested budgets")
        XCTAssertEqual(selected.thinkingLevel, "default", "The chosen catalog's supported efforts govern selection")
        let routeCredentials = try await model.credentials(for: route.profile)
        XCTAssertEqual(routeCredentials["apiKey"], .string(route.apiKey))
        XCTAssertEqual(model.configuration.profiles, [route, source])
        XCTAssertTrue(model.hosts.isEmpty)
        await model.store?.close(); try await model.traces.close()

        let restarted = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: storage)); defer { restarted.shutdown() }
        try await restarted.reloadConfiguration()
        let restored = try await restarted.store?.get(ChatRecord.self, kind: "chat", id: chat.id)
        XCTAssertEqual(restored, selected)
        XCTAssertEqual(restarted.catalogProfile(for: route.profile), source.profile)
        XCTAssertTrue(restarted.catalogRepairChoices(for: route.profile).isEmpty)
        let restartedPicker = ModelCatalogRefreshState()
        await restartedPicker.refresh(model: restarted, profileID: route.profile.id)
        XCTAssertNil(restartedPicker.error)
        XCTAssertEqual(restarted.catalogEntry(for: route.profile).models, ["compact"])
        XCTAssertEqual(restarted.configuration.profiles, [route, source])
        XCTAssertEqual(gateway.requests.map { $0.components(separatedBy: " ")[1] }, ["/legacy", "/custom", "/custom", "/custom"])
        XCTAssertTrue(gateway.requests[0].contains("Bearer " + route.apiKey))
        XCTAssertTrue(gateway.requests.dropFirst().allSatisfy { $0.contains("Bearer " + source.apiKey) && !$0.contains(route.apiKey) },
                      "A linked list uses its chosen authority's key, never the chat's request key")
        await restarted.store?.close(); try await restarted.traces.close()
    }

    @MainActor func testBundledLegacyCatalogShowsLaterCustomChoiceWithoutBindingOrRetargeting() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        var original = connection(id: "old", base: "https://gateway.example", catalog: "")
        original.profile.catalogUrl = nil
        let newer = connection(id: "newer", base: "https://gateway.example", catalog: "/custom", key: "synthetic-new-key")
        let savedOriginal = original, vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [savedOriginal, newer] }
        let model = WorkspaceModel(stateRoot: root, vault: vault); defer { model.shutdown() }
        try await model.reloadConfiguration()
        model.profileChoice = newer.profile.id
        XCTAssertEqual(model.catalogRepairChoices(for: original.profile), [newer.profile])
        model.profileChoice = original.profile.id
        XCTAssertEqual(model.catalogRepairChoices(for: original.profile), [newer.profile])
        XCTAssertEqual(model.catalogProfile(for: original.profile), original.profile,
                       "Showing an alternative does not silently adopt a different saved authority")
        XCTAssertNil(model.configuration.catalogSources)
        XCTAssertEqual(model.configuration.profiles, [original, newer])
        XCTAssertTrue(model.hosts.isEmpty)
        await model.store?.close(); try await model.traces.close()
    }

    @MainActor func testRepairChoicesExcludeLinkedUnrelatedAndDuplicateCatalogsAndKeepMultipleChoices() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let base = "https://gateway.example"
        let earlier = connection(id: "earlier", base: base, catalog: "/earlier")
        let route = connection(id: "old-chat", base: base, catalog: "/original")
        let first = connection(id: "first-choice", base: base, catalog: "/one")
        let otherGateway = connection(id: "other-gateway", base: "https://another.example", catalog: "/one")
        let unchangedURL = connection(id: "same-url", base: base, catalog: "/original")
        var bundled = connection(id: "bundled", base: base, catalog: "")
        bundled.profile.catalogUrl = nil
        var unsupported = connection(id: "messages", base: base, catalog: "/messages-catalog")
        unsupported.profile.api = "anthropic-messages"
        let second = connection(id: "second-choice", base: base, catalog: "/two")
        let linked = connection(id: "linked-follower", base: base, catalog: "/follower")
        var duplicate = connection(id: "latest-duplicate", base: base, catalog: "/one")
        duplicate.profile.catalogUrl = "  " + base + "/one  "
        let connections = [earlier, route, first, otherGateway, unchangedURL, bundled, unsupported, second, linked, duplicate]
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) {
            $0.profiles = connections
            $0.catalogSources = [linked.profile.id: second.profile.id]
        }
        let model = WorkspaceModel(stateRoot: root, vault: vault); defer { model.shutdown() }
        try await model.reloadConfiguration(); model.profileChoice = otherGateway.profile.id
        XCTAssertEqual(model.catalogRepairChoices(for: route.profile).map(\.id), [duplicate.profile.id, second.profile.id],
                       "Offer each distinct newer custom URL once, newest first, without guessing between multiple choices")
        XCTAssertTrue(model.catalogRepairChoices(for: linked.profile).isEmpty,
                      "An explicit linked source must not be presented as an unresolved legacy mismatch")
        XCTAssertTrue(model.catalogRepairChoices(for: unsupported.profile).isEmpty)
        var missing = route.profile; missing.id = "not-saved"
        XCTAssertTrue(model.catalogRepairChoices(for: missing).isEmpty)
        XCTAssertEqual(model.configuration.profiles, connections)
        XCTAssertEqual(model.configuration.catalogSources, [linked.profile.id: second.profile.id])
        XCTAssertTrue(model.hosts.isEmpty)
        await model.store?.close(); try await model.traces.close()
    }

    @MainActor func testChangedEndpointAPIKeyAndHeadersNeverInheritCatalogAuthority() async throws {
        for change in ["endpoint", "api", "key", "headers"] {
            let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
            var previous = connection(id: "route", base: "https://gateway.example", catalog: "/old-catalog")
            if change == "api" { previous.profile.api = "anthropic-messages" }
            let original = previous, vault = ConfigurationVault(storage: MemoryVaultStorage())
            _ = try await vault.update(expectedRevision: 0) { $0.profiles = [original] }
            let model = WorkspaceModel(stateRoot: root, vault: vault); defer { model.shutdown() }
            try await model.reloadConfiguration()
            var replacement = previous.profile; replacement.api = LiteLLMConfiguration.supportedAPI
            replacement.modelId = "replacement-default"
            replacement.catalogUrl = "https://catalog.example/new"
            if change == "endpoint" { replacement.baseUrl = "https://other-gateway.example" }
            try await model.saveProfile(replacement, key: change == "key" ? "synthetic-rotated-key" : "",
                                        headers: change == "headers" ? #"{"X-Team":"changed"}"# : "")
            let fork = try XCTUnwrap(model.profiles.first { $0.id == model.profileChoice })
            XCTAssertNotEqual(fork.id, original.profile.id, change)
            XCTAssertNil(model.configuration.catalogSources, change)
            XCTAssertEqual(model.catalogProfile(for: original.profile), original.profile, change)
            XCTAssertEqual(model.configuration.profiles.first { $0.profile.id == original.profile.id }, original, change)
            XCTAssertTrue(model.hosts.isEmpty)
            await model.store?.close(); try await model.traces.close()
        }
    }

    @MainActor func testRouteForkWithCredentialRotationLeavesFollowersOnOriginalCatalogAuthority() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let original = connection(id: "route", base: "https://gateway.example", catalog: "/catalog")
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [original] }
        let model = WorkspaceModel(stateRoot: root, vault: vault); defer { model.shutdown() }
        try await model.reloadConfiguration()
        var changedModel = original.profile; changedModel.modelId = "next-default"
        try await model.saveProfile(changedModel, key: "")
        let authority = try XCTUnwrap(model.profiles.first { $0.id == model.profileChoice })
        XCTAssertEqual(model.configuration.catalogSources, [original.profile.id: authority.id])
        var replacement = authority; replacement.modelId = "rotated-default"
        try await model.saveProfile(replacement, key: "synthetic-rotated-key")
        let rotated = try XCTUnwrap(model.profiles.first { $0.id == model.profileChoice })
        XCTAssertNotEqual(rotated.id, authority.id)
        XCTAssertEqual(model.configuration.catalogSources, [original.profile.id: authority.id])
        XCTAssertEqual(model.catalogProfile(for: original.profile), authority)
        XCTAssertEqual(model.catalogProfile(for: rotated), rotated)
        let retainedCredentials = try await model.credentials(for: authority)
        let rotatedCredentials = try await model.credentials(for: rotated)
        XCTAssertEqual(retainedCredentials["apiKey"], .string(original.apiKey))
        XCTAssertEqual(rotatedCredentials["apiKey"], .string("synthetic-rotated-key"))
        await model.store?.close(); try await model.traces.close()
    }

    @MainActor func testEditingFollowerCatalogAndDefaultDoesNotTakeOverIndependentAuthority() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let follower = connection(id: "follower", base: "https://gateway.example", catalog: "/original")
        let authority = connection(id: "authority", base: "https://gateway.example", catalog: "/shared")
        let peer = connection(id: "peer", base: "https://gateway.example", catalog: "/peer")
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) {
            $0.profiles = [follower, authority, peer]
            $0.catalogSources = [follower.profile.id: authority.profile.id, peer.profile.id: authority.profile.id]
        }
        let model = WorkspaceModel(stateRoot: root, vault: vault); defer { model.shutdown() }
        try await model.reloadConfiguration()
        var replacement = follower.profile; replacement.modelId = "new-default"
        replacement.catalogUrl = "https://catalog.example/follower-choice"
        try await model.saveProfile(replacement, key: "")
        let fork = try XCTUnwrap(model.profiles.first { $0.id == model.profileChoice })
        XCTAssertEqual(model.configuration.catalogSources, [follower.profile.id: fork.id, peer.profile.id: authority.profile.id])
        XCTAssertEqual(model.catalogProfile(for: follower.profile), fork)
        XCTAssertEqual(model.catalogProfile(for: authority.profile), authority.profile)
        XCTAssertEqual(model.catalogProfile(for: peer.profile), authority.profile)
        XCTAssertEqual(Array(model.configuration.profiles.prefix(3)), [follower, authority, peer])
        XCTAssertNoThrow(try model.configuration.validate())
        XCTAssertTrue(model.hosts.isEmpty)
        await model.store?.close(); try await model.traces.close()
    }

    func testCatalogBindingValidationRejectsMissingSelfChainedAndCyclicReferencesAndDecodesLegacy() throws {
        var valid = VaultConfiguration()
        valid.profiles = ["a", "b", "c"].map { connection(id: $0, base: "https://gateway.example", catalog: "/\($0)") }
        valid.catalogSources = ["a": "c", "b": "c"]
        XCTAssertNoThrow(try valid.validate())
        for mapping in [["missing": "a"], ["a": "missing"], ["a": "a"], ["a": "b", "b": "c"], ["a": "b", "b": "a"]] {
            var invalid = valid; invalid.catalogSources = mapping
            XCTAssertThrowsError(try invalid.validate(), "Invalid binding \(mapping) must never enter the vault")
            XCTAssertThrowsError(try ConfigurationVault.decode(JSONEncoder().encode(invalid)))
        }
        var unsupported = valid; unsupported.profiles[2].profile.api = "anthropic-messages"
        XCTAssertThrowsError(try unsupported.validate())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        object.removeValue(forKey: "catalogSources")
        let legacy = try ConfigurationVault.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.catalogSources)
        XCTAssertEqual(legacy.profiles, valid.profiles)
    }

    func testExplicitCatalogSelectionFlattensFollowersAndCanRestoreOwnCatalog() throws {
        var saved = VaultConfiguration()
        saved.profiles = ["a", "b", "c", "d"].map { connection(id: $0, base: "https://gateway.example", catalog: "/\($0)") }
        saved.catalogSources = ["a": "b", "c": "d"]
        try saved.useCatalog(sourceID: "c", for: "b")
        XCTAssertEqual(saved.catalogSources, ["a": "d", "b": "d", "c": "d"])
        XCTAssertNoThrow(try saved.validate())
        try saved.useCatalog(sourceID: "a", for: "a")
        XCTAssertEqual(saved.catalogSources, ["b": "d", "c": "d"])
        XCTAssertNoThrow(try saved.validate())
        let original = saved
        XCTAssertThrowsError(try saved.useCatalog(sourceID: "missing", for: "a"))
        XCTAssertEqual(saved, original)
    }

    private func connection(id: String, base: String, catalog: String, key: String = "synthetic-catalog-key") -> VaultProfile {
        var profile = ProfileRecord(); profile.id = id; profile.modelId = "default-model"
        profile.baseUrl = base; profile.catalogUrl = base + catalog
        return VaultProfile(profile: profile, apiKey: key, headers: ["X-Team": "fixture"])
    }

    private func scratch() throws -> URL {
        let parent = scratchBase()
        let root = URL(fileURLWithPath: parent).appendingPathComponent("catalog-sources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
