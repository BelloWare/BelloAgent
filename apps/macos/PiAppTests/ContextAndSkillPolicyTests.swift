import XCTest
@testable import PiApp

final class ContextAndSkillPolicyTests: XCTestCase {
    func testGlobalSkillSwitchesRoundTripWithoutChangingProjectOverridesOrLegacyVaults() throws {
        let global = String(repeating:"a",count:64), project = String(repeating:"b",count:64)
        var saved = VaultConfiguration(); saved.disabledSkills = [global]
        saved.resources["first"] = .object(["codexHome":.string("/fixture/codex"),"disabled":.array([.string(project)]),"explicitOnly":.array([.string(global)])])
        let originalProject = saved.resources
        let restored = try ConfigurationVault.decode(JSONEncoder().encode(saved))
        XCTAssertEqual(restored.disabledSkills,[global]); XCTAssertEqual(restored.resources,originalProject)
        let first = restored.resourceOptions(workspaceID:"first",defaultCodexHome:"/default")
        XCTAssertEqual(first["disabled"]?.array?.compactMap(\.string),[global,project])
        XCTAssertEqual(first["codexHome"]?.string,"/fixture/codex")
        let second = restored.resourceOptions(workspaceID:"second",defaultCodexHome:"/default")
        XCTAssertEqual(second["disabled"]?.array?.compactMap(\.string),[global])
        var enabled = restored; enabled.disabledSkills = []
        XCTAssertEqual(enabled.resourceOptions(workspaceID:"first",defaultCodexHome:"/default")["disabled"]?.array?.compactMap(\.string),[project])
        XCTAssertEqual(enabled.resources,originalProject,"Global re-enable cannot remove project overrides")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(saved)) as? [String:Any]); legacy.removeValue(forKey:"disabledSkills")
        let older = try ConfigurationVault.decode(JSONSerialization.data(withJSONObject:legacy))
        XCTAssertNil(older.disabledSkills); XCTAssertEqual(older.resources,originalProject)
        var invalid = saved; invalid.disabledSkills = ["not a canonical skill identity"]
        XCTAssertThrowsError(try invalid.validate())
    }

    @MainActor func testDisablingSkillRemovesAllUnsentSelectionsAndRejectsStaleCatalogSelection() async throws {
        let root = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let storage = MemoryVaultStorage(), vault = ConfigurationVault(storage:storage)
        let model = WorkspaceModel(stateRoot:root,vault:vault); defer { model.shutdown() }
        let skill = SkillDescriptor(id:String(repeating:"a",count:64),name:"example",path:"/synthetic/never-written/SKILL.md",description:"Fixture",scope:"user",contentHash:String(repeating:"b",count:64),metadataHash:String(repeating:"c",count:64),policy:"implicitAllowed",reasons:[],missingDependencies:[])
        let a = SessionDisplay(id:"first"), b = SessionDisplay(id:"second")
        a.skills = [skill.chip]; b.skills = [skill.chip]; a.draft = "keep text"; b.draft = "keep another"
        model.displays = [a.id:a,b.id:b]; model.resourceCatalog = [skill]
        try await model.setSkillEnabledInBelloAgent(skill,enabled:false)
        XCTAssertTrue(a.skills.isEmpty); XCTAssertTrue(b.skills.isEmpty)
        XCTAssertEqual(a.draft,"keep text"); XCTAssertEqual(b.draft,"keep another")
        XCTAssertFalse(model.skillEnabledInBelloAgent(skill.id))
        XCTAssertEqual(model.resourceCatalog.first?.policy,"disabled")
        model.addSkill(skill,view:a)
        XCTAssertTrue(a.skills.isEmpty,"A stale catalog row cannot put a disabled skill back into the draft")
        let saved = try await vault.load(); XCTAssertEqual(saved.disabledSkills,[skill.id]); XCTAssertTrue(saved.resources.isEmpty)
        try await model.setSkillEnabledInBelloAgent(skill,enabled:true)
        model.addSkill(skill,view:a); XCTAssertEqual(a.skills,[skill.chip])
        XCTAssertEqual(storage.writes,2,"Only the app's injected vault was written")
    }

    @MainActor func testSkillCatalogDoesNotPublishResultsFromBeforeAPolicyChange() async throws {
        let root = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let vault = ConfigurationVault(storage:MemoryVaultStorage())
        let model = WorkspaceModel(stateRoot:root,vault:vault); defer { model.shutdown() }
        try await model.reloadConfiguration(); model.selectedWorkspaceID = "project"
        let skill = SkillDescriptor(id:String(repeating:"a",count:64),name:"example",path:"/synthetic/SKILL.md",description:"Fixture",scope:"user",contentHash:String(repeating:"b",count:64),metadataHash:String(repeating:"c",count:64),policy:"implicitAllowed",reasons:[],missingDependencies:[])
        let encoded = try JSONDecoder().decode(WireValue.self,from:JSONEncoder().encode([skill]))
        var reads = 0
        await model.loadSkillCatalog(refresh:true,readPage:{ _, _ in
            reads += 1
            model.configuration.revision += 1
            return ["revision":.string("old-policy"),"skills":encoded]
        })
        XCTAssertEqual(reads,1); XCTAssertTrue(model.resourceCatalog.isEmpty); XCTAssertNil(model.resourceCatalogWorkspaceID)
        XCTAssertTrue(model.resourceNotice.contains("settings changed"))
    }

    func testContextBindingIgnoresJournalAllocationButRejectsChangedRouteOrToolMode() {
        let original = ChatRecord(id:"chat",workspaceID:"project",title:"New chat",path:nil,profileID:"profile")
        var saved = original; saved.path = "/allocated/journal.jsonl"; saved.title = "Renamed"; saved.pinnedAt = Date(); saved.organizationRevision = 1
        XCTAssertEqual(ContextPreviewBinding(original),ContextPreviewBinding(saved))
        saved.model = "other"; XCTAssertNotEqual(ContextPreviewBinding(original),ContextPreviewBinding(saved))
        saved = original; saved.toolMode = "read-only"; XCTAssertNotEqual(ContextPreviewBinding(original),ContextPreviewBinding(saved))
        saved = original; saved.profileID = "replacement"; XCTAssertNotEqual(ContextPreviewBinding(original),ContextPreviewBinding(saved))
        saved = original; saved.maxOutputTokens = 2048; XCTAssertNotEqual(ContextPreviewBinding(original),ContextPreviewBinding(saved))
        saved = original; saved.modelOutputLimit = 32768; XCTAssertNotEqual(ContextPreviewBinding(original),ContextPreviewBinding(saved))
    }

    @MainActor func testCommandDraftIsNotMisrepresentedAsALiteralModelRequest() async throws {
        let root = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let storage = MemoryVaultStorage(), model = WorkspaceModel(stateRoot:root,vault:ConfigurationVault(storage:storage))
        defer { model.shutdown() }
        let chat = ChatRecord(id:"chat",workspaceID:"project",title:"New chat",path:nil,profileID:"unused")
        let display = SessionDisplay(id:chat.id); display.directCommand = true
        model.chats = [chat]; model.displays[chat.id] = display
        for draft in ["/side", "/fork", "/compact", "/example explain"] {
            display.draft = draft
            do { _ = try await model.preparedContext(chat.id); XCTFail("A command was represented as a literal provider input") }
            catch { XCTAssertTrue(error.localizedDescription.contains("command") || error.localizedDescription.contains("skill suggestions")) }
        }
        XCTAssertTrue(model.hosts.isEmpty); XCTAssertEqual(storage.writes,0)
    }

    @MainActor func testFirstContextPreviewOfFreshChatUsesPackagedHelperWithoutSending() async throws {
        let folder = URL(fileURLWithPath:ProcessInfo.processInfo.environment["PI_APP_SCRATCH_ROOT"] ?? ProcessInfo.processInfo.environment["PI_BUILD_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let vault = ConfigurationVault(storage:MemoryVaultStorage())
        let workspace = WorkspaceRecord(id:"context-fixture",path:folder.path,trusted:true)
        var profile = ProfileRecord(); profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "preview-only"; profile.contextWindow = 16000; profile.maxOutputTokens = 2048
        let connection = VaultProfile(profile:profile,apiKey:"synthetic-preview-only-key")
        _ = try await vault.update(expectedRevision:0) {
            $0.workspaces = [workspace]; $0.profiles = [connection]
            $0.resources[workspace.id] = .object(["codexHome":.string(folder.appendingPathComponent("codex").path)])
        }
        let model = WorkspaceModel(stateRoot:folder.appendingPathComponent("app-state"),vault:vault); defer { model.shutdown() }
        try await model.reloadConfiguration()
        let chat = ChatRecord(id:"preview",workspaceID:workspace.id,title:"New chat",path:nil,profileID:profile.id)
        let display = SessionDisplay(id:chat.id); display.draft = "This remains unsent."
        model.chats = [chat]; model.displays[chat.id] = display
        XCTAssertEqual(ContextMeterPresentation(context:model.displayedContext(display)).compactLabel,"Inspect context")
        _ = try await model.open(chat)
        XCTAssertEqual(display.context["state"], .string("pending"), "Opening does not substitute a different formula before the request body is prepared")
        XCTAssertNil(display.context["tokens"]?.number)
        XCTAssertNil(ContextMeterPresentation(context:model.displayedContext(display)).fraction)
        let preview = try await model.preparedContext(chat.id)
        XCTAssertEqual(preview["draftIncluded"]?.bool,true); XCTAssertEqual(preview["dispatched"]?.bool,false)
        XCTAssertEqual(model.displayedContext(display)["tokens"],preview["estimatedTokens"],"The ring and inspector must use the same calculated preview")
        XCTAssertEqual(model.displayedContext(display)["contextWindow"],preview["contextWindow"])
        XCTAssertTrue(ContextMeterPresentation(context:model.displayedContext(display)).detailLabel.contains("unsent draft"))
        let revision = try XCTUnwrap(preview["revision"]?.string)
        let body = try await model.readPreparedContext(chat.id,revision:revision,section:"request")
        XCTAssertTrue(body["text"]?.string?.contains("This remains unsent.") == true)
        XCTAssertEqual(display.draft,"This remains unsent.")
        let host = try XCTUnwrap(model.hosts[workspace.id])
        let state = try await host.request("session.snapshot",sessionID:chat.id).object ?? [:]
        XCTAssertEqual(state["messages"]?.array?.count,0); XCTAssertEqual(state["queueCount"]?.number,0)
        XCTAssertEqual(state["state"]?.string,"idle")
        let attempts = try await model.traces.list(sessionID:chat.id); XCTAssertTrue(attempts.isEmpty)
        await model.clearPreparedContext(chat.id,revision:revision)
        XCTAssertEqual(model.displayedContext(display)["tokens"],preview["estimatedTokens"],"Closing inspection must not revert to unknown")
        display.draft = "Changed draft"
        XCTAssertEqual(model.displayedContext(display),display.context,"An estimate for an old draft must not be presented as current")
        display.draft = "This remains unsent."
        XCTAssertEqual(model.displayedContext(display)["tokens"],preview["estimatedTokens"])
        display.observeContext(["seq":.number((preview["seq"]?.number ?? 0) + 1),"context":.object(["tokens":.number(3000),"contextWindow":.number(16000)])])
        XCTAssertNil(display.footer.preparedContext,"New conversation activity invalidates a prepared estimate")
        XCTAssertEqual(model.displayedContext(display)["tokens"]?.number,3000)
        try await host.shutdownAndWait(); try await model.traces.close(); await model.store?.close()
        try FileManager.default.removeItem(at:folder)
    }

    @MainActor func testPreparedContextMeterRejectsChangedInputsAndConfiguration() throws {
        let folder = URL(fileURLWithPath:ProcessInfo.processInfo.environment["PI_APP_SCRATCH_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let model = WorkspaceModel(stateRoot:folder,vault:ConfigurationVault(storage:MemoryVaultStorage()))
        defer { model.shutdown(); try? FileManager.default.removeItem(at:folder) }
        var chat = ChatRecord(id:"meter",workspaceID:"project",title:"New chat",path:nil,profileID:"profile")
        chat.model = "first"; chat.contextWindow = 16000
        model.chats = [chat]
        let view = SessionDisplay(id:chat.id); model.displays[chat.id] = view
        view.context = ["tokens":.number(2000),"contextWindow":.number(16000)]
        let summary: [String:WireValue] = ["estimatedTokens":.number(2100),"contextWindow":.number(16000),"seq":.number(3)]
        let params = TurnOverrides.params(for:chat,base:["text":.string(""),"skills":.array([]),"attachments":.array([])])
        view.footer.preparedContext = try XCTUnwrap(PreparedContextMetrics(summary:summary,binding:ContextPreviewBinding(chat),params:params,configurationRevision:model.configuration.revision,directCommand:false))
        XCTAssertEqual(model.displayedContext(view)["tokens"]?.number,2100)
        model.chats[0].title = "Renamed"; model.chats[0].path = "/new-journal.jsonl"
        XCTAssertEqual(model.displayedContext(view)["tokens"]?.number,2100,"Presentation-only changes do not invalidate context")
        model.chats[0].model = "second"; XCTAssertEqual(model.displayedContext(view),view.context)
        model.chats[0].model = "first"
        view.directCommand = true; XCTAssertEqual(model.displayedContext(view),view.context); view.directCommand = false
        view.editingMessageID = "edit"; XCTAssertEqual(model.displayedContext(view),view.context); view.editingMessageID = nil
        view.lastSequence = 4; XCTAssertEqual(model.displayedContext(view),view.context); view.lastSequence = 3
        XCTAssertEqual(model.displayedContext(view)["tokens"]?.number,2100)
        model.configuration.revision += 1; XCTAssertEqual(model.displayedContext(view),view.context)
        view.observeContext(["seq":.number(0),"context":.object(view.context)],baseline:true)
        XCTAssertNil(view.footer.preparedContext,"Reopening the helper invalidates the previous sequence epoch")
        XCTAssertTrue(model.hosts.isEmpty,"Reading meter state must not start helpers or call a model")
    }

    func testContextMeterHandlesUnavailableAndInvalidCountsWithoutInventingUsage() {
        XCTAssertEqual(ContextMeterPresentation(context:[:]).compactLabel,"Inspect context")
        XCTAssertEqual(ContextMeterPresentation(context:["state":.string("post-compaction")]).compactLabel,"Context pending")
        XCTAssertEqual(ContextMeterPresentation(context:["state":.string("pending"),"tokens":.null]).compactLabel,"Context pending")
        for tokens in [-1.0,Double.nan,Double.infinity] {
            XCTAssertNil(ContextMeterPresentation(context:["tokens":.number(tokens),"contextWindow":.number(16000)]).fraction)
        }
        let zero = ContextMeterPresentation(context:["tokens":.number(0),"contextWindow":.number(16000)])
        XCTAssertEqual(zero.fraction,0); XCTAssertEqual(zero.compactLabel,"≈0 / 16k")
        XCTAssertNil(ContextMeterPresentation(context:["tokens":.number(100),"contextWindow":.number(0)]).fraction)
        XCTAssertEqual(ContextMeterPresentation(context:["tokens":.number(8000),"contextWindow":.number(16000)],capacity:32000).fraction,0.25)
    }

    func testPreparedCountPreservesProvenanceAndUsesTheSameCountForInspectorAndRing() throws {
        let chat = ChatRecord(id: "context", workspaceID: "project", title: "New chat", path: nil, profileID: "connection")
        let count: [String: WireValue] = [
            "tokens": .number(850), "method": .string("provider-count"), "estimated": .bool(false),
            "requestedModel": .string("chosen-model"), "countedModel": .string("provider/chosen-model"),
            "requestFingerprint": .string("fingerprint-for-this-request"), "source": .string("Provider token counting API"),
            "warnings": .array([]), "inputBudget": .number(13000), "outputBudget": .number(2048),
            "safetyMargin": .number(952), "modelOutputLimit": .number(32768)
        ]
        let summary: [String: WireValue] = ["count": .object(count), "estimatedTokens": .number(9999),
            "contextWindow": .number(16000), "outputReserve": .number(32768), "seq": .number(7), "draftIncluded": .bool(true)]
        let prepared = try XCTUnwrap(PreparedContextMetrics(summary: summary, binding: ContextPreviewBinding(chat), params: [:], configurationRevision: 1, directCommand: false))
        let inspection = try XCTUnwrap(PreparedContextMetrics.context(from: summary))
        XCTAssertEqual(prepared.context, inspection)
        for (key, value) in count { XCTAssertEqual(inspection[key], value, "Count provenance must retain \(key)") }
        XCTAssertEqual(inspection["outputReserve"], .number(2048), "The requested output budget takes precedence over a legacy ceiling")
        let ring = ContextMeterPresentation(context: prepared.context, capacity: 128000)
        XCTAssertEqual(ring.fraction, 850.0 / 16000, "A fingerprinted result retains the capacity used by the helper")
        XCTAssertFalse(ring.estimated); XCTAssertEqual(ring.compactLabel, "850 / 16k")
        XCTAssertEqual(ring.fullLabel, ContextMeterPresentation(context: inspection).fullLabel)
        XCTAssertEqual(ring.methodLabel, "Provider count")
        XCTAssertTrue(ring.modelLabel?.contains("provider/chosen-model") == true)
        XCTAssertTrue(ring.budgetLabel?.contains("requested output " + Double(2048).formatted(.number.precision(.fractionLength(0)))) == true)
        XCTAssertTrue(ring.detailLabel.contains("unsent draft"))
    }

    func testRoutedCountShowsEstimateMethodAndUncertaintyWithoutInventingCountedModel() throws {
        let warning = "The gateway has not bound this count to the eventual auto-router deployment."
        let summary: [String: WireValue] = ["count": .object([
            "tokens": .number(4000), "method": .string("tokenizer"), "estimated": .bool(true),
            "requestedModel": .string("auto-router"), "requestFingerprint": .string("router-request"),
            "warnings": .array([.string(warning)]), "source": .string("Gateway tokenizer fallback")]),
            "contextWindow": .number(16000)]
        let context = try XCTUnwrap(PreparedContextMetrics.context(from: summary))
        let meter = ContextMeterPresentation(context: context)
        XCTAssertEqual(meter.compactLabel, "≈4k / 16k")
        XCTAssertEqual(meter.methodLabel, "Gateway tokenizer")
        XCTAssertEqual(meter.warnings, [warning]); XCTAssertTrue(meter.detailLabel.contains(warning))
        XCTAssertEqual(meter.modelLabel, "Requested auto-router · counted model unverified")
        XCTAssertNil(context["countedModel"])
    }

    func testMalformedNewCountDoesNotResurrectLegacyHeuristicAndLegacyCountsRemainEstimated() throws {
        let validLegacy: [String: WireValue] = ["estimatedTokens": .number(800), "contextWindow": .number(16000)]
        let legacy = try XCTUnwrap(PreparedContextMetrics.context(from: validLegacy))
        XCTAssertEqual(legacy["estimated"], .bool(true)); XCTAssertEqual(legacy["method"], .string("heuristic"))
        XCTAssertTrue(ContextMeterPresentation(context: legacy).compactLabel.hasPrefix("≈"))
        for invalid in [WireValue.null, .number(800), .object([:]), .object(["tokens": .number(-1)]), .object(["tokens": .number(.infinity)])] {
            var summary = validLegacy; summary["count"] = invalid
            XCTAssertNil(PreparedContextMetrics.context(from: summary))
        }
        var summary = validLegacy; summary["count"] = .object(["tokens": .number(800), "method": .string("tokenizer")])
        XCTAssertEqual(PreparedContextMetrics.context(from: summary)?["estimated"], .bool(true), "Missing confidence must not imply exact counting")
    }
}
