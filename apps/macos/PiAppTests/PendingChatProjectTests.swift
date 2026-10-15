import AppKit
import XCTest
@testable import PiApp

extension XCTestCase {
    @MainActor func pendingProjectModel(gateway: Bool = false) async throws -> WorkspaceModel {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("pending-project-" + UUID().uuidString)
        let projects = ["Orchard", "Harbor", "Untrusted"].map { WorkspaceRecord(id: $0, path: root.appendingPathComponent($0).path, trusted: $0 != "Untrusted") }
        for project in projects {
            try FileManager.default.createDirectory(atPath: project.path, withIntermediateDirectories: true)
            try Data("Instructions unique to \(project.id) project.\n".utf8).write(to: URL(fileURLWithPath: project.path).appendingPathComponent("AGENTS.md"))
            try Data("Synthetic UI fixture file: read-tool round trip verified.\n".utf8).write(to: URL(fileURLWithPath: project.path).appendingPathComponent("README.md"))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var profile = ProfileRecord()
        profile.name = "Fixture"; profile.api = LiteLLMConfiguration.supportedAPI
        profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "fixture"
        if gateway {
            profile.baseUrl = try await startSyntheticGateway(in: root).base
            profile.modelId = "ui-fixture"; profile.contextWindow = 2_000_000; profile.maxOutputTokens = 300_000; profile.modelOutputLimit = 300_000
        }
        profile.advancedJSON = "{\"input\":[\"text\",\"image\"]}"
        var config = VaultConfiguration()
        config.workspaces = projects; config.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-loopback-only-key")]
        // No real Codex instructions, skills, preferences or credentials.
        for project in projects { config.resources[project.id] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)]) }
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(config))))
        model.prewarmsHelpers = false
        await model.restore()
        model.selectedWorkspaceID = "Orchard"; model.profileChoice = profile.id
        return model
    }

    @MainActor func startPendingProjectChat(_ model: WorkspaceModel, project: String = "Orchard") async throws -> SessionDisplay {
        let previous = model.selectedID
        model.newChat(in: project)
        try await eventually("pending chat ready") { model.selectedID != previous && model.selected?.draftReady == true && model.selected?.historyState == .empty && model.workspaceChangesInFlight.isEmpty }
        return try XCTUnwrap(model.selected)
    }

}

final class PendingChatProjectTests: XCTestCase {
    @MainActor func testSwitchRebindsOpenInspectorAndReadsDestinationArchive() async throws {
        let model = try await pendingProjectModel(gateway: true), initial = try await startPendingProjectChat(model)
        defer { SessionInspectorWindows.shared.closeAll(owner: model) }
        model.openInspector(session: initial.id)
        let controller = try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID: initial.id))
        let window = try XCTUnwrap(controller.window), frame = window.frame, old = controller.inspector
        // Hold an old-scope read across the switch. It must retire along with
        // the old model, even when its asynchronous work completes later.
        old.setVisible(false)
        let gate = AsyncGate(), reads = old.indexReads
        var entered = false
        old.beforeRead = { entered = true; await gate.wait() }
        old.setVisible(true)
        try await eventually("old inspector read started") { entered }
        do { try await model.setPendingChatProject("Harbor", for: initial.id) }
        catch { await gate.open(); throw error }
        let inspector = controller.inspector
        XCTAssertFalse(inspector === old)
        XCTAssertFalse(old.visible); XCTAssertFalse(old.isReading)
        XCTAssertEqual(inspector.scope, SessionUsageScope(sessionID: initial.id, workspaceID: "Harbor"))
        XCTAssertEqual(inspector.usage.scope.workspaceID, "Harbor")
        XCTAssertTrue(controller.window === window); XCTAssertEqual(window.frame, frame)
        await gate.open()

        model.openInspector(session: initial.id)
        XCTAssertEqual(SessionInspectorWindows.shared.controllers.filter { $0.inspector.scope.sessionID == initial.id }.count, 1,
                       "Opening Inspector again must reuse the retargeted window")
        XCTAssertTrue(SessionInspectorWindows.shared.controller(sessionID: initial.id) === controller)
        let view = try XCTUnwrap(model.selected)
        view.footer.turnTiming = ["modelMs": .number(250)]
        XCTAssertEqual(inspector.work["modelMs"], .number(250))
        initial.footer.turnTiming = ["modelMs": .number(999)]
        XCTAssertEqual(inspector.work["modelMs"], .number(250))
        view.draft = "Hello from the inspector's destination project."
        model.submitComposer(intent: .followUp, sessionID: view.id)
        try await eventually("synthetic reply completed", timeout: .seconds(60)) {
            !view.loading && !view.busy && (view.messages.contains { $0.role == "assistant" } || view.sendFailure != nil || view.runState == .error)
        }
        XCTAssertNotEqual(view.runState, .error, view.failureMessage ?? view.notice); XCTAssertNil(view.sendFailure)
        try await eventually("destination request archived") {
            try await model.traces.inspectorRows(sessionID: view.id, workspaceID: "Harbor").rows.contains { $0.source == .log }
        }
        inspector.setVisible(true); inspector.refresh()
        try await eventually("inspector finished its destination read") { inspector.indexLoaded && !inspector.isReading && !inspector.usage.loading }
        XCTAssertTrue(inspector.index.requests.contains { $0.source == .log }, "Destination archive requests belong in the already-open Inspector")
        XCTAssertGreaterThan(inspector.usage.snapshot?.gateway.requests ?? 0, 0)
        XCTAssertEqual(old.indexReads, reads, "The cancelled old-scope read cannot publish after the switch")
    }

    @MainActor func testSwitchKeepsInspectorHiddenAndDoesNotRetargetAnotherOwner() async throws {
        let model = try await pendingProjectModel(), view = try await startPendingProjectChat(model)
        let other = try await pendingProjectModel()
        defer { SessionInspectorWindows.shared.closeAll(owner: model); SessionInspectorWindows.shared.closeAll(owner: other) }
        let controller = SessionInspectorWindows.shared.show(model: model, sessionID: view.id, workspaceID: "Orchard", title: "New chat", focus: .overview)
        let unrelated = SessionInspectorWindows.shared.show(model: other, sessionID: view.id, workspaceID: "Orchard", title: "Another owner's report", focus: .overview)
        let window = try XCTUnwrap(controller.window), originalOther = unrelated.inspector
        window.orderOut(nil); controller.inspector.setVisible(false)
        try await model.setPendingChatProject("Harbor", for: view.id)
        XCTAssertTrue(controller.window === window); XCTAssertFalse(window.isVisible)
        XCTAssertFalse(controller.inspector.visible, "Switching projects must not reopen a hidden Inspector")
        XCTAssertEqual(controller.inspector.scope.workspaceID, "Harbor")
        XCTAssertTrue(unrelated.inspector === originalOther, "An inspector owned by another workspace window keeps its scope")
        XCTAssertEqual(unrelated.inspector.scope.workspaceID, "Orchard")
    }

    @MainActor func testPendingProjectChipInFlatAndTopics() async throws {
        let model = try await pendingProjectModel()
        let session = try await startPendingProjectChat(model)
        for flat in [false, true] {
            model.setSidebarFlat(flat)
            let composer = ComposerInputView(model: model)
            composer.paneWidth = 600; composer.show(session)
            let chip = ConversationPaneTests.views(NSButton.self, in: composer).first { $0.accessibilityIdentifier() == "pending-chat-project" }
            XCTAssertNotNil(chip, "An unsent chat offers its project above the composer in both sidebar modes")
            XCTAssertEqual(chip?.accessibilityLabel(), "Project: Orchard, change")
            XCTAssertTrue(chip?.acceptsFirstResponder == true)
        }
    }

    @MainActor func testSwitchUsesFreshNewChatDefaultsAndKeepsOnlyUserInput() async throws {
        let model = try await pendingProjectModel(), view = try await startPendingProjectChat(model)
        let store = try XCTUnwrap(model.store), id = view.id
        var chosen = try XCTUnwrap(model.record(id))
        chosen.model = "remembered-model"; chosen.thinkingLevel = "high"; chosen.contextWindow = 90_000
        chosen.maxOutputTokens = 4_000; chosen.modelOutputLimit = 20_000
        try await store.put(ChatModelDefaults(chat: chosen), kind: ChatModelDefaults.recordKind, id: chosen.profileID)
        model.chats[0].toolMode = ChatRecord.readOnlyTools; model.chats[0].webhookOff = true
        model.chats[0].topicID = "old-topic"; model.chats[0].model = "old-model"
        let bytes = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
        let image = try AttachmentRecord.inspect(model.pastedImages.write(bytes))
        view.draft = "  Draft 🪴\nkeep indentation\n"; view.attachments = [image]; view.directCommand = true
        let skill = SkillDescriptor(id: String(repeating: "a", count: 64), name: "old-project-skill", path: "/synthetic/SKILL.md", description: "Old", scope: "project", contentHash: "old", metadataHash: "old", policy: "explicitOnly", reasons: [], missingDependencies: [])
        view.skills = [skill.chip]
        view.skillCatalog = SkillCatalog(state: .ready, scope: "old", revision: "old", entries: [SkillSearch.Entry(skill)])
        view.context = ["tokens": .number(123), "old-project": .bool(true)]
        view.footer.contextState = ["old-project": .bool(true)]
        view.metrics = ["old-project": .bool(true)]
        view.captureAvailable = true
        let oldLease = try model.connectionLease(for: XCTUnwrap(model.record(id)))

        try await model.setPendingChatProject("Harbor", for: id)
        let replacement = try XCTUnwrap(model.selected), switched = try XCTUnwrap(model.record(id))
        XCTAssertFalse(view === replacement, "The old editor, resource selections and context caches must retire")
        XCTAssertEqual(replacement.draft, view.draft); XCTAssertEqual(replacement.attachments, [image])
        XCTAssertTrue(replacement.skills.isEmpty); XCTAssertTrue(replacement.skillCatalog.entries.isEmpty)
        XCTAssertFalse(replacement.directCommand, "Old slash text cannot authorize a skill in the new project")
        XCTAssertTrue(replacement.context.isEmpty); XCTAssertTrue(replacement.footer.contextState.isEmpty)
        XCTAssertTrue(replacement.metrics.isEmpty); XCTAssertFalse(replacement.captureAvailable)
        XCTAssertTrue(replacement.notice.contains("Selected skills were cleared"))
        XCTAssertThrowsError(try model.requireConnection(oldLease))
        XCTAssertEqual(switched.workspaceID, "Harbor"); XCTAssertNil(switched.topicID)
        XCTAssertTrue(model.pendingChatIDs.contains(id)); XCTAssertTrue(model.hosts.isEmpty)
        let storedChats = try await store.list(ChatRecord.self, kind: "chat"), drafts = try await store.list(DraftRecord.self, kind: "draft")
        XCTAssertTrue(storedChats.isEmpty); XCTAssertTrue(drafts.isEmpty)

        let freshView = try await startPendingProjectChat(model, project: "Harbor")
        var fresh = try XCTUnwrap(model.record(freshView.id))
        fresh.id = switched.id; fresh.sidebarOrder = switched.sidebarOrder
        XCTAssertEqual(switched, fresh, "Project switch must use the same defaults as New Chat in the target")
    }

    @MainActor func testUntrustedMissingScratchAndChangingProjectsAreNotOfferedOrAccepted() async throws {
        let model = try await pendingProjectModel(), view = try await startPendingProjectChat(model)
        model.workspaces.append(WorkspaceRecord(id: "missing", path: model.root.appendingPathComponent("missing").path, trusted: true))
        model.workspaces.append(WorkspaceRecord(id: WorkspaceRecord.scratchID, path: model.root.path, trusted: true))
        model.workspaceChangesInFlight.insert("Harbor")
        let choices = await WorkspaceModel.availableChatProjects(model.pendingChatProjects)
        XCTAssertEqual(choices.map(\.id), ["Orchard"])
        view.draft = "Keep this draft"
        for target in ["Untrusted", "missing", WorkspaceRecord.scratchID, "Harbor", "removed"] {
            do { try await model.setPendingChatProject(target, for: view.id); XCTFail("Accepted \(target)") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
            XCTAssertEqual(model.record(view.id)?.workspaceID, "Orchard"); XCTAssertEqual(model.selected?.draft, "Keep this draft")
        }
        model.workspaceChangesInFlight.removeAll()
    }

    @MainActor func testSavedEmptyChatCannotChangeProjectAndChipDisappears() async throws {
        let model = try await pendingProjectModel(), view = try await startPendingProjectChat(model)
        let composer = ComposerInputView(model: model); composer.show(view)
        XCTAssertFalse(composer.projectChip.isHidden)
        try await model.materializeChat(view.id)
        composer.refresh(); XCTAssertTrue(composer.projectChip.isHidden)
        do { try await model.setPendingChatProject("Harbor", for: view.id); XCTFail("A saved chat changed project") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Only an unsaved new chat")) }
        XCTAssertEqual(model.record(view.id)?.workspaceID, "Orchard")
    }

    @MainActor func testSavingDisablesProjectChoiceBeforeTheStoreReturns() async throws {
        let model = try await pendingProjectModel(), view = try await startPendingProjectChat(model)
        let store = try XCTUnwrap(model.store), composer = ComposerInputView(model: model)
        composer.show(view)
        let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        // Hold the actual store actor before its write, without adding a
        // production delay or relying on disk timing.
        let barrier = Task { try await store.put(PendingProjectStoreBarrier(entered: entered, released: released), kind: "fixture", id: "write-barrier") }
        defer { released.signal() }
        try await eventually("store actor occupied") { entered.wait(timeout: .now()) == .success }
        var saving = false
        let save = Task { saving = true; try await model.materializeChat(view.id) }
        try await eventually("save reached the store") { saving }
        try await eventually("project choice disabled while saving") { !composer.projectChip.isEnabled }
        XCTAssertFalse(composer.projectChip.isEnabled, "A save already owns the chat's project before its store write returns")
        XCTAssertNotNil(model.pendingProjectBlocker(view.id))
        released.signal()
        try await barrier.value; try await save.value
        XCTAssertFalse(model.pendingChatIDs.contains(view.id))
    }

    @MainActor func testSendHidesChipAndFixesProjectUsingSyntheticGateway() async throws {
        let model = try await pendingProjectModel(gateway: true), initial = try await startPendingProjectChat(model)
        try await model.setPendingChatProject("Harbor", for: initial.id)
        let view = try XCTUnwrap(model.selected), composer = ComposerInputView(model: model)
        composer.show(view); XCTAssertFalse(composer.projectChip.isHidden)
        view.draft = "Hello from the selected project."
        model.submitComposer(intent: .followUp, sessionID: view.id)
        composer.refresh(); XCTAssertTrue(composer.projectChip.isHidden, "Hidden synchronously when Send accepts the first message")
        do { try await model.setPendingChatProject("Orchard", for: view.id); XCTFail("A submitting chat changed project") } catch { }
        try await eventually("synthetic reply completed", timeout: .seconds(60)) { !view.loading && !view.busy && (view.messages.contains { $0.role == "assistant" } || view.sendFailure != nil || view.runState == .error) }
        XCTAssertNotEqual(view.runState, .error, view.failureMessage ?? view.notice)
        XCTAssertNil(view.sendFailure); XCTAssertEqual(model.record(view.id)?.workspaceID, "Harbor")
        XCTAssertFalse(model.pendingChatIDs.contains(view.id)); XCTAssertNil(model.hosts["Orchard"])
        composer.refresh(); XCTAssertTrue(composer.projectChip.isHidden)
    }

    @MainActor func testSwitchRechecksTrustAndMaterializationAfterAwait() async throws {
        for materialize in [false, true] {
            let model = try await pendingProjectModel(), view = try await startPendingProjectChat(model)
            view.draft = "Keep while waiting"
            let gate = AsyncGate(), profile = model.profileChoice
            model.overrideWrites[profile] = (UUID(), Task { await gate.wait() })
            var entered = false
            let change = Task { entered = true; try await model.setPendingChatProject("Harbor", for: view.id) }
            try await eventually("switch entered defaults wait") { entered }
            if materialize { try await model.materializeChat(view.id) }
            else { model.workspaces[1].trusted = false }
            await gate.open()
            do { try await change.value; XCTFail("A stale choice was committed") } catch { }
            model.overrideWrites.removeValue(forKey: profile)
            XCTAssertTrue(model.selected === view); XCTAssertEqual(view.draft, "Keep while waiting")
            XCTAssertEqual(model.record(view.id)?.workspaceID, "Orchard")
        }
    }

    @MainActor func testSwitchRejectsLeavingChatsWhileDefaultsAreSuspended() async throws {
        for report in [true, false] {
            try await assertSwitchRejectsNavigation { model, _ in
                if report { model.openReport() } else { model.openBackgroundRequests() }
            }
        }
    }

    @MainActor func testSwitchRejectsReturningToTheSameDraftAfterNavigation() async throws {
        for destination in ["report", "background", "chat"] {
            try await assertSwitchRejectsNavigation { model, view in
                switch destination {
                case "report": model.openReport()
                case "background": model.openBackgroundRequests()
                default: await model.select(try XCTUnwrap(model.chats.first { $0.id != view.id }).id)
                }
                await model.select(view.id)
                XCTAssertEqual(model.page, .chats)
                XCTAssertTrue(model.selected === view, "Returning restores the same nonempty draft display")
            }
        }
    }

    @MainActor func testSwitchCannotStartOutsideChats() async throws {
        for report in [true, false] {
            let model = try await pendingProjectModel(), view = try await startPendingProjectChat(model)
            view.draft = "Keep the draft while another page is open."
            if report { model.openReport() } else { model.openBackgroundRequests() }
            let page = model.page, original = model.record(view.id)
            do { try await model.setPendingChatProject("Harbor", for: view.id); XCTFail("A hidden chat accepted a project choice") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
            XCTAssertEqual(model.page, page); XCTAssertEqual(model.record(view.id), original)
            XCTAssertTrue(model.selected === view)
        }
    }

    @MainActor func testChoosingCurrentProjectSupersedesSuspendedSwitchInFlatAndTopics() async throws {
        for flat in [false, true] {
            let model = try await pendingProjectModel(), view = try await startPendingProjectChat(model)
            model.setSidebarFlat(flat)
            view.draft = "Keep this draft in Orchard."
            let original = model.record(view.id), gate = AsyncGate(), profile = model.profileChoice
            model.overrideWrites[profile] = (UUID(), Task { await gate.wait() })
            var entered = false
            let older = Task { entered = true; try await model.setPendingChatProject("Harbor", for: view.id) }
            try await eventually("older project choice waiting") { entered }
            do { try await model.setPendingChatProject("Orchard", for: view.id) }
            catch { await gate.open(); _ = await older.result; throw error }
            await gate.open()
            let result = await older.result
            if case .success = result { XCTFail("Choosing the current project must supersede the suspended switch") }
            model.overrideWrites.removeValue(forKey: profile)
            XCTAssertEqual(model.record(view.id), original)
            XCTAssertTrue(model.selected === view)
            XCTAssertEqual(model.selected?.draft, "Keep this draft in Orchard.")
        }
    }

    @MainActor func testLatestProjectChoiceWinsInEitherReadCompletionOrder() async throws {
        for oldestFirst in [true, false] {
            let model = try await pendingProjectModel(), view = try await startPendingProjectChat(model)
            try addThirdProject(to: model)
            view.draft = "Keep the latest draft."
            let olderGate = AsyncGate(), newerGate = AsyncGate(), profile = model.profileChoice
            model.overrideWrites[profile] = (UUID(), Task { await olderGate.wait() })
            var olderEntered = false, newerEntered = false
            let older = Task { olderEntered = true; try await model.setPendingChatProject("Harbor", for: view.id) }
            try await eventually("older project choice waiting") { olderEntered }
            model.overrideWrites[profile] = (UUID(), Task { await newerGate.wait() })
            let newer = Task { newerEntered = true; try await model.setPendingChatProject("Meadow", for: view.id) }
            try await eventually("newer project choice waiting") { newerEntered }
            if oldestFirst {
                await olderGate.open()
                if case .success = await older.result { XCTFail("An older choice committed while a newer choice was waiting") }
                XCTAssertEqual(model.record(view.id)?.workspaceID, "Orchard")
                XCTAssertTrue(model.selected === view)
            }
            view.draft = "Edited while the choices were waiting."
            await newerGate.open()
            let newerResult = await newer.result
            await olderGate.open()
            if case .success = await older.result { XCTFail("A superseded choice succeeded") }
            model.overrideWrites.removeValue(forKey: profile)
            if case .failure(let error) = newerResult { XCTFail("The newest choice lost ownership: \(error)") }
            XCTAssertEqual(model.record(view.id)?.workspaceID, "Meadow")
            XCTAssertEqual(model.selected?.draft, "Edited while the choices were waiting.")
            XCTAssertTrue(model.pendingChatIDs.contains(view.id))
        }
    }

    @MainActor func testFailedOrCancelledNewerChoiceDoesNotReviveOlderSwitch() async throws {
        for cancel in [false, true] {
            let model = try await pendingProjectModel(), view = try await startPendingProjectChat(model)
            try addThirdProject(to: model)
            view.draft = "A failed latest choice leaves the original project intact."
            let original = model.record(view.id), olderGate = AsyncGate(), newerGate = AsyncGate(), profile = model.profileChoice
            model.overrideWrites[profile] = (UUID(), Task { await olderGate.wait() })
            var olderEntered = false, newerEntered = false
            let older = Task { olderEntered = true; try await model.setPendingChatProject("Harbor", for: view.id) }
            try await eventually("older project choice waiting") { olderEntered }
            model.overrideWrites[profile] = (UUID(), Task { await newerGate.wait() })
            let newer = Task { newerEntered = true; try await model.setPendingChatProject("Meadow", for: view.id) }
            try await eventually("newer project choice waiting") { newerEntered }
            if cancel { newer.cancel() }
            else { try FileManager.default.removeItem(atPath: XCTUnwrap(model.workspaces.first { $0.id == "Meadow" }).path) }
            await newerGate.open()
            if case .success = await newer.result { XCTFail("The unavailable or cancelled latest choice succeeded") }
            await olderGate.open()
            if case .success = await older.result { XCTFail("An unsuccessful latest choice revived an obsolete one") }
            model.overrideWrites.removeValue(forKey: profile)
            XCTAssertEqual(model.record(view.id), original)
            XCTAssertTrue(model.selected === view)
            XCTAssertEqual(model.selected?.draft, "A failed latest choice leaves the original project intact.")
        }
    }

    @MainActor func testMenuChoicesRegisterBeforeTasksAndSilenceSupersededFailures() async throws {
        for target in ["Orchard", "Meadow"] {
            let model = try await pendingProjectModel(), view = try await startPendingProjectChat(model)
            try addThirdProject(to: model)
            view.draft = "The last menu action owns this draft."
            view.notice = "Keep the current draft's notice."
            let gate = AsyncGate(), profile = model.profileChoice
            model.overrideWrites[profile] = (UUID(), Task { await gate.wait() })
            // The chip calls this synchronous entry point. Both actions are
            // accepted before either task runs; task scheduling cannot choose
            // the winner or allow an old completion to clear the new owner.
            let older = model.choosePendingChatProject("Harbor", for: view.id)
            let newer = model.choosePendingChatProject(target, for: view.id)
            await older.value
            XCTAssertEqual(model.record(view.id)?.workspaceID, "Orchard")
            XCTAssertEqual(view.notice, "Keep the current draft's notice.", "A superseded error is silent, even while the newest choice is waiting")
            await gate.open(); await newer.value
            model.overrideWrites.removeValue(forKey: profile)
            XCTAssertEqual(model.record(view.id)?.workspaceID, target)
            XCTAssertEqual(model.selected?.draft, "The last menu action owns this draft.")
            XCTAssertTrue(model.pendingChatProjectChoices.isEmpty, "Finished choices release their ownership without retaining per-chat history")
        }
    }

    @MainActor func testMenuChoiceCannotPublishFailureAfterNavigationCancellationOrSave() async throws {
        for supersession in ["report", "return", "cancel", "save"] {
            let model = try await pendingProjectModel(), view = try await startPendingProjectChat(model)
            view.draft = "Keep the draft across navigation."
            view.notice = "The current draft's notice."
            let original = model.record(view.id)
            let choice = model.choosePendingChatProject("Harbor", for: view.id)
            if supersession == "cancel" { choice.cancel() }
            else if supersession == "save" { try await model.materializeChat(view.id) }
            else {
                model.openReport()
                if supersession == "return" { await model.select(view.id) }
            }
            let page = model.page
            await choice.value
            XCTAssertEqual(model.page, page); XCTAssertEqual(model.record(view.id), original)
            XCTAssertTrue(model.selected === view)
            XCTAssertEqual(view.notice, "The current draft's notice.", "The same ownership guard must protect error delivery")
            XCTAssertTrue(model.pendingChatProjectChoices.isEmpty)
        }
    }

    @MainActor func testLatestMenuChoiceStillReportsAnUnavailableProject() async throws {
        let model = try await pendingProjectModel(), view = try await startPendingProjectChat(model)
        try addThirdProject(to: model)
        try FileManager.default.removeItem(atPath: XCTUnwrap(model.workspaces.first { $0.id == "Meadow" }).path)
        view.draft = "Keep the draft when a project becomes unavailable."
        await model.choosePendingChatProject("Meadow", for: view.id).value
        XCTAssertEqual(model.record(view.id)?.workspaceID, "Orchard"); XCTAssertTrue(model.selected === view)
        XCTAssertEqual(view.draft, "Keep the draft when a project becomes unavailable.")
        XCTAssertFalse(view.notice.isEmpty, "Failures of the current choice still explain why the project did not change")
        XCTAssertTrue(model.pendingChatProjectChoices.isEmpty)
    }

    @MainActor func testNewChatSupersedesAProjectChoiceBeforeReuseOrCreation() async throws {
        for reuse in [true, false] {
            let model = try await pendingProjectModel(), view = try await startPendingProjectChat(model)
            try addThirdProject(to: model)
            view.draft = reuse ? "" : "Keep this draft in its original project when creating another chat."
            let original = model.record(view.id), olderGate = AsyncGate(), creationGate = AsyncGate(), profile = model.profileChoice
            model.overrideWrites[profile] = (UUID(), Task { await olderGate.wait() })
            var entered = false
            let older = Task { entered = true; try await model.setPendingChatProject("Harbor", for: view.id) }
            try await eventually("project choice waiting before New Chat") { entered }
            model.overrideWrites[profile] = (UUID(), Task { await creationGate.wait() })
            model.newChat(in: reuse ? "Orchard" : "Meadow")
            await olderGate.open()
            if case .success = await older.result { XCTFail("An older project choice survived a newer New Chat action") }
            XCTAssertEqual(model.record(view.id), original)
            XCTAssertTrue(model.selected === view, "New Chat has either reused this draft or is still reading its defaults")
            await creationGate.open()
            model.overrideWrites.removeValue(forKey: profile)
            if reuse { XCTAssertEqual(model.selectedID, view.id) }
            else {
                try await eventually("new chat created in the later destination") { model.selectedID != view.id && model.selected?.draftReady == true }
                XCTAssertEqual(model.record(try XCTUnwrap(model.selectedID))?.workspaceID, "Meadow")
                XCTAssertEqual(model.displays[view.id]?.draft, "Keep this draft in its original project when creating another chat.")
            }
        }
    }

    @MainActor func testFailedFirstSaveDoesNotReviveAnEarlierProjectChoice() async throws {
        let model = try await pendingProjectModel(), view = try await startPendingProjectChat(model)
        view.draft = "A first-save attempt supersedes the older project choice."
        let original = model.record(view.id)
        let gate = AsyncGate(), profile = model.profileChoice
        model.overrideWrites[profile] = (UUID(), Task { await gate.wait() })
        var entered = false
        let older = Task { entered = true; try await model.setPendingChatProject("Harbor", for: view.id) }
        try await eventually("project choice waiting before save") { entered }
        // Reject the actual first write in this generated database, then
        // restore storage while the old project choice is still waiting.
        try RecoveredDraftTests.sql("CREATE TRIGGER refuse_first_chat BEFORE INSERT ON records WHEN NEW.kind='chat' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", root: model.root)
        do { try await model.materializeChat(view.id); XCTFail("The unavailable store accepted the first save") }
        catch { XCTAssertEqual(error as? StoreError, .unavailable) }
        try RecoveredDraftTests.sql("DROP TRIGGER refuse_first_chat", root: model.root)
        XCTAssertTrue(model.pendingChatIDs.contains(view.id)); XCTAssertNil(model.pendingProjectBlocker(view.id))
        view.notice = "The first save failed; retry when ready."
        await gate.open()
        if case .success = await older.result { XCTFail("A failed save revived the older project choice") }
        model.overrideWrites.removeValue(forKey: profile)
        XCTAssertEqual(model.record(view.id), original); XCTAssertTrue(model.selected === view)
        XCTAssertEqual(model.selected?.draft, "A first-save attempt supersedes the older project choice.")
        XCTAssertEqual(model.selected?.notice, "The first save failed; retry when ready.")
    }

    @MainActor private func addThirdProject(to model: WorkspaceModel) throws {
        let path = model.root.appendingPathComponent("Meadow").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        model.workspaces.append(WorkspaceRecord(id: "Meadow", path: path, trusted: true))
    }

    @MainActor private func assertSwitchRejectsNavigation(_ navigate: @MainActor (WorkspaceModel, SessionDisplay) async throws -> Void) async throws {
        let model = try await pendingProjectModel(), view = try await startPendingProjectChat(model)
        let draft = "Keep this nonempty draft when navigating away and back."
        view.draft = draft
        // Create the other destination before holding defaults: New Chat
        // itself waits for the same saved-default write as the project picker.
        let other = try await startPendingProjectChat(model, project: "Harbor")
        other.draft = "Another pending chat."
        await model.select(view.id)
        let original = try XCTUnwrap(model.record(view.id)), lease = try model.connectionLease(for: original)
        let gate = AsyncGate(), profile = model.profileChoice
        model.overrideWrites[profile] = (UUID(), Task { await gate.wait() })
        var entered = false
        let choice = Task { entered = true; try await model.setPendingChatProject("Harbor", for: view.id) }
        do {
            try await eventually("project choice suspended at defaults") { entered }
            try await navigate(model, view)
        } catch {
            await gate.open(); _ = try? await choice.value
            model.overrideWrites.removeValue(forKey: profile)
            throw error
        }
        let page = model.page, selection = model.selectedID
        await gate.open()
        do { try await choice.value; XCTFail("A project choice survived newer navigation") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        model.overrideWrites.removeValue(forKey: profile)
        XCTAssertEqual(model.page, page, "The newer page keeps control of navigation")
        XCTAssertEqual(model.selectedID, selection)
        XCTAssertEqual(model.record(view.id), original, "A stale choice cannot change the pending chat's project or defaults")
        XCTAssertTrue(model.displays[view.id] === view, "The original draft display and its state stay intact")
        XCTAssertEqual(model.selected?.draft, draft)
        XCTAssertTrue(model.pendingChatIDs.contains(view.id))
        XCTAssertNoThrow(try model.requireConnection(lease), "Refusing a stale choice preserves the existing connection boundary")
    }

    @MainActor func testImportAndSideKeepTheirDestinationUntilFinished() async throws {
        let model = try await pendingProjectModel(), view = try await startPendingProjectChat(model)
        let importing = model.beginImageImport(sessionID: view.id)
        do { try await model.setPendingChatProject("Harbor", for: view.id); XCTFail("An in-flight import changed destination") }
        catch { XCTAssertTrue(error.localizedDescription.contains("image")) }
        XCTAssertTrue(importing.isCurrent()); importing.finish()
        model.openSide(parentID: view.id)
        do { try await model.setPendingChatProject("Harbor", for: view.id); XCTFail("A parent's pending side crossed projects") } catch { }
        XCTAssertEqual(model.record(view.id)?.workspaceID, "Orchard")
    }

    @MainActor func testOldRecordCannotOpenPreviousProjectAfterSwitch() async throws {
        let model = try await pendingProjectModel(), view = try await startPendingProjectChat(model)
        let old = try XCTUnwrap(model.record(view.id))
        try await model.setPendingChatProject("Harbor", for: view.id)
        do { _ = try await model.open(old); XCTFail("A stale record opened the old project's helper") } catch { }
        XCTAssertTrue(model.hosts.isEmpty); XCTAssertTrue(model.pendingChatIDs.contains(view.id))
    }

    @MainActor func testPreparedRequestUsesOnlyTargetFoldersAndInstructions() async throws {
        let model = try await pendingProjectModel(), view = try await startPendingProjectChat(model)
        view.draft = "Inspect the target project."
        let extra = model.root.appendingPathComponent("Harbor-extra")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try await model.updateConfiguration { $0.workspaces[1].paths = [extra.path] }
        try await model.setPendingChatProject("Harbor", for: view.id)
        let preview = try await model.preparedContext(view.id)
        XCTAssertEqual(preview["dispatched"]?.bool, false)
        let request = try await model.readPreparedContext(view.id, revision: XCTUnwrap(preview["revision"]?.string), section: "request")
        let body = try XCTUnwrap(request["text"]?.string)
        XCTAssertTrue(body.contains("Instructions unique to Harbor")); XCTAssertFalse(body.contains("Instructions unique to Orchard"))
        XCTAssertTrue(body.contains(extra.path)); XCTAssertTrue(body.contains("Inspect the target project."))
        XCTAssertNil(model.hosts["Orchard"])
        XCTAssertTrue(model.record(view.id)?.path?.contains("/Harbor/") == true)
        let captures = try await model.traces.list(sessionID: view.id); XCTAssertTrue(captures.isEmpty)
    }

    @MainActor func testSearchAndKeyboardCommitUseCheckedPiMenuEntries() {
        var chosen: Int?, cancelled = false
        let entries: [PiMenuEntry] = (0..<12).map { index in
            .button("Project \(index)", checked: index == 3, identifier: String(index), help: "/generated/project-\(index)") { chosen = index }
        }
        let picker = PendingChatProjectPicker(entries: entries) { cancelled = true }
        XCTAssertFalse(picker.search.isHidden); XCTAssertEqual(picker.highlighted, "3")
        picker.move(1); XCTAssertNil(chosen, "Arrow navigation never changes the project")
        picker.activate(picker.highlighted); XCTAssertEqual(chosen, 4)
        picker.filter("project-11"); XCTAssertEqual(picker.visible.map(\.identifier), ["11"])
        picker.activate(picker.highlighted); XCTAssertEqual(chosen, 11)
        picker.filter("absent"); XCTAssertTrue(picker.visible.isEmpty)
        picker.cancelOperation(nil); XCTAssertTrue(cancelled)
    }
}

private struct PendingProjectStoreBarrier: Encodable, Sendable {
    let entered: DispatchSemaphore
    let released: DispatchSemaphore
    func encode(to encoder: Encoder) throws {
        entered.signal(); released.wait()
        var value = encoder.singleValueContainer(); try value.encode(true)
    }
}
