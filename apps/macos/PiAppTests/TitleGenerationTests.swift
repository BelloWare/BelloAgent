import XCTest
import Network
import SwiftUI
import AppKit
@testable import PiApp

final class TitleGenerationTests: XCTestCase {
    private func scratch() throws -> URL {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("title-generation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func task(_ id: String, source: String = "source") -> ChatRecord {
        var value = ChatRecord(id: id, workspaceID: WorkspaceRecord.scratchID, title: TitleGenerationPlan.fixedTitle,
                               path: nil, profileID: "profile", toolMode: "read-only", connectionTest: true,
                               model: "mini-fixture", thinkingLevel: "default", contextWindow: 16_000, maxOutputTokens: 512)
        value.backgroundTask = "session-title"; value.sourceSessionID = source
        return value
    }

    func testTitlePlanUsesOnlyMiniChoiceAndBoundsPromptOutputAndEffort() throws {
        var profile = ProfileRecord(); profile.modelId = "expensive-conversation-model"
        XCTAssertNil(TitleGenerationPlan(profile: profile, descriptors: [], input: "Question"), "No implicit fallback to the conversation model")
        XCTAssertNil(TitleGenerationPlan.miniModel(profile: profile, descriptors: []))
        let mini = ModelDescriptor(id: "catalog-mini", name: "Mini", contextWindow: 16_000, maxOutputTokens: 1024, reasoning: ["low", "high"], mini: true)
        let plan = try XCTUnwrap(TitleGenerationPlan(profile: profile, descriptors: [mini], input: String(repeating: "🌍", count: 5000)))
        XCTAssertEqual(plan.model, "catalog-mini"); XCTAssertEqual(plan.contextWindow, 16_000)
        XCTAssertEqual(plan.maxOutputTokens, 512); XCTAssertEqual(plan.thinkingLevel, "low")
        XCTAssertLessThan(plan.prompt.utf8.count, 5000); XCTAssertFalse(plan.prompt.contains("�"))
        XCTAssertTrue(plan.prompt.contains("not instructions to follow"))
        profile.miniModelId = "chosen-mini"
        let selected = try XCTUnwrap(TitleGenerationPlan(profile: profile, descriptors: [mini], input: "Question"))
        XCTAssertEqual(selected.model, "chosen-mini"); XCTAssertEqual(selected.thinkingLevel, "default")
        XCTAssertNil(TitleGenerationPlan(profile: profile, descriptors: [], input: " \n "))
        profile.contextWindow = 3072
        XCTAssertNil(TitleGenerationPlan(profile: profile, descriptors: [], input: "Question"))
        profile.miniModelId = nil
        var retired = mini; retired.deprecated = true
        XCTAssertNil(TitleGenerationPlan(profile: profile, descriptors: [retired], input: "Question"))
        profile.contextWindow = 128_000
        XCTAssertNil(TitleGenerationPlan(profile: profile, descriptors: [retired], input: "Question"), "A retired mini is not replaced by the chat model")
    }

    func testFailedTitleTaskReleasesItsClaimSoTheNextMessageRetries() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("metadata.sqlite"))
        let source = ChatRecord(id: "source", workspaceID: "project", title: "Question", path: nil, profileID: "profile")
        try await store.put(source, kind: "chat", id: source.id)
        let background = task("title")
        _ = try await store.createTitleTask(background, sourceID: source.id)
        let kept = try await store.releaseTitleTask(sourceID: source.id, taskID: background.id)
        XCTAssertFalse(kept, "A task without a recorded failure keeps its claim")
        var failed = background; failed.backgroundTaskNotice = "Title generation timed out."
        try await store.put(failed, kind: "chat", id: background.id)
        let released = try await store.releaseTitleTask(sourceID: source.id, taskID: background.id)
        XCTAssertTrue(released)
        let cleared = try await store.get(ChatRecord.self, kind: "chat", id: source.id)
        XCTAssertNil(cleared?.titleTaskSessionID)
        let second = try await store.createTitleTask(task("second"), sourceID: source.id)
        XCTAssertNotNil(second, "A released source accepts a new task")
        let wrong = try await store.releaseTitleTask(sourceID: source.id, taskID: "second-but-wrong")
        XCTAssertFalse(wrong, "Only the claiming task releases")
        let child = ChatRecord(id: "child", workspaceID: "project", title: "Question — side", path: nil, profileID: "profile", toolMode: "read-only", parentSessionID: "source")
        try await store.put(child, kind: "chat", id: child.id)
        let childTask = try await store.createTitleTask(task("child-title", source: "child"), sourceID: child.id)
        XCTAssertNotNil(childTask, "Saved side chats are titled too")
    }

    func testTitleParserRejectsPartialFailedToolOutputAndCleansWhatModelsAdd() {
        func answer(_ text: String, state: String? = nil) -> TranscriptMessage {
            TranscriptMessage(id: "answer", role: "assistant", text: text, state: state)
        }
        XCTAssertEqual(TitleGenerationPlan.title(from: [answer("  “Improve the catalog picker” \n")]), "Improve the catalog picker")
        for message in [answer("unfinished", state: "streaming"), answer("failed", state: "error"),
                        answer("cancelled", state: "aborted"), answer(""), answer("\n \n")] {
            XCTAssertNil(TitleGenerationPlan.title(from: [message]))
        }
        // What real mini models add around a title never loses the title.
        XCTAssertEqual(TitleGenerationPlan.title(from: [answer("Harden the payment retry loop\n\nThis title summarizes the request.")]), "Harden the payment retry loop")
        XCTAssertEqual(TitleGenerationPlan.title(from: [answer("Title: **Harden the retry loop**.")]), "Harden the retry loop")
        XCTAssertEqual(TitleGenerationPlan.title(from: [answer("- \u{0060}Retry loop hardening\u{0060}")]), "Retry loop hardening")
        XCTAssertEqual(TitleGenerationPlan.title(from: [answer("Sure! Here is a title:\nPayment retries with jitter")]), "Sure! Here is a title:")
        XCTAssertEqual(TitleGenerationPlan.title(from: [answer(String(repeating: "word ", count: 30))])?.count ?? 0 <= 80, true)
        XCTAssertEqual(TitleGenerationPlan.title(from: [answer(String(repeating: "x", count: 81))]), String(repeating: "x", count: 80))
        var truncated = answer("Truncated"); truncated.truncated = true
        XCTAssertNil(TitleGenerationPlan.title(from: [truncated]))
        var tool = answer("Tool response")
        tool.tools = [.init(id: "call", name: "read", state: "completed", input: "", output: "", durationMs: nil, truncated: false)]
        XCTAssertNil(TitleGenerationPlan.title(from: [tool]))
        XCTAssertNil(TitleGenerationPlan.title(from: [.init(id: "user", role: "user", text: "User is not a title")]))
    }

    func testTitleTaskClaimIsAtomicAndSurvivesRestartWithoutAnotherClaim() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("metadata.sqlite")
        let store = MetadataStore(url: url)
        let source = ChatRecord(id: "source", workspaceID: "project", title: "First message", path: nil, profileID: "profile")
        try await store.put(source, kind: "chat", id: source.id)
        let firstTask = task("first"), secondTask = task("second")
        async let first = store.createTitleTask(firstTask, sourceID: source.id)
        async let second = store.createTitleTask(secondTask, sourceID: source.id)
        let claims = try await [first, second]
        XCTAssertEqual(claims.compactMap { $0 }.count, 1)
        let all = try await store.loadChats()
        XCTAssertEqual(all.count, 2); XCTAssertEqual(all.filter(\.isBackgroundTask).count, 1)
        let claimed = try XCTUnwrap(all.first { $0.id == source.id }?.titleTaskSessionID)
        XCTAssertEqual(all.first(where: \.isBackgroundTask)?.id, claimed)
        await store.close()
        let reopened = MetadataStore(url: url)
        let repeated = try await reopened.createTitleTask(task("repeated"), sourceID: source.id)
        XCTAssertNil(repeated)
        let restored = try await reopened.loadChats()
        XCTAssertEqual(restored.count, 2); XCTAssertEqual(restored.first(where: \.isBackgroundTask)?.title, TitleGenerationPlan.fixedTitle)
        await reopened.close()
    }

    func testInvalidTaskCannotReplaceSourceAndFailureNoticeSurvivesUnrelatedWrites() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("metadata.sqlite"))
        let source = ChatRecord(id: "source", workspaceID: "project", title: "Question", path: nil, profileID: "profile")
        try await store.put(source, kind: "chat", id: source.id)
        for invalid in [task(source.id), task("wrong-source", source: "other")] {
            do { _ = try await store.createTitleTask(invalid, sourceID: source.id); XCTFail("A malformed task cannot overwrite or claim the source") }
            catch { }
        }
        let unchanged = try await store.get(ChatRecord.self, kind: "chat", id: source.id)
        XCTAssertEqual(unchanged, source)
        let background = task("title")
        _ = try await store.createTitleTask(background, sourceID: source.id)
        var failed = background; failed.backgroundTaskNotice = "The mini model did not return a usable title. The original title was kept."
        try await store.put(failed, kind: "chat", id: background.id)
        var stale = background; stale.path = "/synthetic/title.jsonl"; stale.title = "A stale title"
        try await store.put(stale, kind: "chat", id: background.id)
        let restored = try await store.get(ChatRecord.self, kind: "chat", id: background.id)
        XCTAssertEqual(restored?.backgroundTaskNotice, failed.backgroundTaskNotice)
        XCTAssertEqual(restored?.title, TitleGenerationPlan.fixedTitle); XCTAssertEqual(restored?.path, stale.path)
        await store.close()
    }

    func testGeneratedTitleCannotOverwriteManualRenameOrBeRevertedByStaleMetadata() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("metadata.sqlite"))
        let source = ChatRecord(id: "source", workspaceID: "project", title: "First message", path: nil, profileID: "profile")
        try await store.put(source, kind: "chat", id: source.id)
        _ = try await store.createTitleTask(task("title"), sourceID: source.id)
        let wrong = try await store.applyGeneratedTitle("Wrong task", sourceID: source.id, taskID: "other")
        XCTAssertNil(wrong)
        let generated = try await store.applyGeneratedTitle("Generated title", sourceID: source.id, taskID: "title")
        XCTAssertEqual(generated?.title, "Generated title"); XCTAssertEqual(generated?.titleWasGenerated, true)
        var oldPathUpdate = source; oldPathUpdate.path = "/synthetic/journal.jsonl"
        try await store.put(oldPathUpdate, kind: "chat", id: source.id)
        let afterStale = try await store.get(ChatRecord.self, kind: "chat", id: source.id)
        XCTAssertEqual(afterStale?.title, "Generated title"); XCTAssertEqual(afterStale?.titleTaskSessionID, "title")
        _ = try await store.updateChatOrganization(id: source.id, change: .title("My manual title"))
        let late = try await store.applyGeneratedTitle("Late generated title", sourceID: source.id, taskID: "title")
        XCTAssertNil(late)
        let renamed = try await store.get(ChatRecord.self, kind: "chat", id: source.id)
        XCTAssertEqual(renamed?.title, "My manual title"); XCTAssertEqual(renamed?.titleWasEdited, true)
        do {
            _ = try await store.updateChatOrganization(id: "title", change: .title("Rename utility"))
            XCTFail("The background session title stays fixed")
        } catch { }
        await store.close()
    }

    @MainActor func testBackgroundSessionsAreHiddenUntilRevealedWithoutChangingDraftOrFocus() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let source = ChatRecord(id: "source", workspaceID: "project", title: "First message", path: nil, profileID: "profile")
        let background = task("title")
        model.workspaces = [.init(id: "project", path: root.path, trusted: true)]
        model.chats = [source, background]; model.selectedID = source.id
        let display = SessionDisplay(id: source.id); display.draft = "Unsent content"; model.displays[source.id] = display
        XCTAssertFalse(model.showBackgroundSessions)
        XCTAssertTrue(model.sidebarChats(in: WorkspaceRecord.scratchID, archived: false).isEmpty)
        XCTAssertFalse(model.sidebarProjects.contains { $0.id == WorkspaceRecord.scratchID })
        model.revealProjectChat(background)
        XCTAssertTrue(model.showBackgroundSessions)
        XCTAssertEqual(model.sidebarChats(in: WorkspaceRecord.scratchID, archived: false).map(\.id), [background.id])
        XCTAssertTrue(model.sidebarProjects.contains { $0.id == WorkspaceRecord.scratchID })
        XCTAssertEqual(model.selectedID, source.id); XCTAssertEqual(display.draft, "Unsent content")
        model.scheduleTitleGeneration(sourceID: background.id, input: "Do not recurse")
        XCTAssertTrue(model.titleGenerationTasks.isEmpty)
        model.showBackgroundSessions = false
        XCTAssertTrue(model.sidebarChats(in: WorkspaceRecord.scratchID, archived: false).isEmpty)
        await model.flushProjectSidebarState()
        await model.store?.close()
    }

    @MainActor func testPackagedHelperGeneratesOneScopedTitleRequestAndRetainsItsAccounting() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try TitleGenerationGateway(); defer { gateway.stop() }
        let base = try await gateway.start()
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("PRIVATE PROJECT INSTRUCTION".utf8).write(to: project.appendingPathComponent("AGENTS.md"))
        var profile = ProfileRecord(); profile.id = "profile"; profile.baseUrl = base
        profile.modelId = "conversation-model"; profile.miniModelId = "mini-fixture"
        var configuration = VaultConfiguration(); configuration.automaticUpdateChecks = false
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-title-key")]
        configuration.workspaces = [.init(id: "project", path: project.path, trusted: true)]
        configuration.resources[WorkspaceRecord.scratchID] = .object(["codexHome": .string(root.appendingPathComponent("isolated-codex").path)])
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"),
                                   vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        let source = ChatRecord(id: "source", workspaceID: "project", title: "Improve the model selection please", path: nil, profileID: profile.id)
        model.chats = [source]; model.selectedID = source.id
        try await model.store?.put(source, kind: "chat", id: source.id)
        model.scheduleTitleGeneration(sourceID: source.id, input: "Improve the model selection please")
        model.scheduleTitleGeneration(sourceID: source.id, input: "Duplicate must not dispatch")
        XCTAssertEqual(model.titleGenerationTasks.count, 1)
        for _ in 0..<300 where !model.titleGenerationTasks.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(model.titleGenerationTasks.isEmpty, "A local title request should complete promptly")
        let background = try XCTUnwrap(model.chats.first(where: \.isBackgroundTask))
        XCTAssertEqual(model.record(source.id)?.title, "Improve the model picker", model.displays[background.id]?.notice ?? "")
        XCTAssertEqual(model.selectedID, source.id); XCTAssertFalse(model.showBackgroundSessions)
        XCTAssertEqual(background.title, TitleGenerationPlan.fixedTitle); XCTAssertEqual(background.sourceSessionID, source.id)
        XCTAssertEqual(background.workspaceID, WorkspaceRecord.scratchID); XCTAssertEqual(background.model, "mini-fixture")
        XCTAssertNotNil(background.path); XCTAssertEqual(gateway.requests.count, 1)
        let request = try XCTUnwrap(gateway.requests.first)
        XCTAssertTrue(request.hasPrefix("POST /v1/responses HTTP/1.1"))
        XCTAssertTrue(request.lowercased().contains("authorization: bearer synthetic-title-key"))
        let split = try XCTUnwrap(request.range(of: "\r\n\r\n"))
        let body = try JSONDecoder().decode(WireValue.self, from: Data(request[split.upperBound...].utf8)).object ?? [:]
        XCTAssertEqual(body["model"]?.string, "mini-fixture"); XCTAssertEqual(body["max_output_tokens"]?.number, 512)
        XCTAssertEqual(body["tools"]?.array ?? [], [])
        XCTAssertTrue(body["instructions"]?.string?.contains("Generate a short session title") == true)
        XCTAssertFalse(request.contains("PRIVATE PROJECT INSTRUCTION"))
        let attempts = try await model.traces.list(sessionID: background.id, workspaceID: WorkspaceRecord.scratchID)
        XCTAssertEqual(attempts.count, 1); XCTAssertEqual(attempts.first?["purpose"]?.string, "title")
        let accounting = try await model.traces.gatewayAccounting(sessionID: background.id, workspaceID: WorkspaceRecord.scratchID, messages: [])
        XCTAssertEqual(accounting.session.requests, 1); XCTAssertEqual(accounting.session.costUSD, 0.00001)
        let sourceAccounting = try await model.traces.gatewayAccounting(sessionID: source.id, workspaceID: source.workspaceID, messages: [])
        XCTAssertEqual(sourceAccounting.session.requests, 0, "The auxiliary request has its own billing scope")
        model.scheduleTitleGeneration(sourceID: source.id, input: "Never resend a claimed title job")
        XCTAssertTrue(model.titleGenerationTasks.isEmpty); XCTAssertEqual(gateway.requests.count, 1)
        try await model.hosts[WorkspaceRecord.scratchID]?.shutdownAndWait()
        try await model.traces.close(); await model.store?.close()
    }

    /// Chat ▸ Generate Title asks again for a chat that already has a
    /// generated title. The finished request kept its claim on the chat, so
    /// the command showed "Asking the mini model for a title…" and then
    /// nothing: no request, no error, the same title.
    @MainActor func testGenerateTitleAgainAfterAGeneratedTitleAsksTheMiniModelOnceMore() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try TitleGenerationGateway(); defer { gateway.stop() }
        let base = try await gateway.start()
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var profile = ProfileRecord(); profile.id = "profile"; profile.baseUrl = base
        profile.modelId = "conversation-model"; profile.miniModelId = "mini-fixture"
        var configuration = VaultConfiguration(); configuration.automaticUpdateChecks = false
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-title-key")]
        configuration.workspaces = [.init(id: "project", path: project.path, trusted: true)]
        configuration.resources[WorkspaceRecord.scratchID] = .object(["codexHome": .string(root.appendingPathComponent("isolated-codex").path)])
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"),
                                   vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        let source = ChatRecord(id: "source", workspaceID: "project", title: "Improve the model selection please", path: nil, profileID: profile.id)
        model.chats = [source]; model.selectedID = source.id
        try await model.store?.put(source, kind: "chat", id: source.id)
        let display = SessionDisplay(id: source.id)
        display.messages = [TranscriptMessage(id: "u1", role: "user", text: "Improve the model selection please")]
        model.displays[source.id] = display; model.selected = display
        model.scheduleTitleGeneration(sourceID: source.id, input: "Improve the model selection please")
        for _ in 0..<300 where !model.titleGenerationTasks.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(model.record(source.id)?.title, "Improve the model picker")
        XCTAssertEqual(model.record(source.id)?.titleWasGenerated, true)
        XCTAssertEqual(gateway.requests.count, 1)

        model.regenerateTitle(source.id)
        for _ in 0..<200 where gateway.requests.count < 2 || !model.titleGenerationTasks.isEmpty || display.notice.hasPrefix("Asking") {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(gateway.requests.count, 2, "Generate Title sends one more title request")
        XCTAssertEqual(display.notice, "", "The request finished and its notice cleared")
        XCTAssertEqual(model.record(source.id)?.title, "Improve the model picker")
        XCTAssertEqual(model.record(source.id)?.titleWasGenerated, true)
        XCTAssertNil(model.error)
        // An automatic retitle still never follows a generated title.
        model.scheduleTitleGeneration(sourceID: source.id, input: "Never resend a titled chat")
        XCTAssertTrue(model.titleGenerationTasks.isEmpty)
        try await model.hosts[WorkspaceRecord.scratchID]?.shutdownAndWait()
        try await model.traces.close(); await model.store?.close()
    }
}

extension TitleGenerationTests {
    /// The Rename sheet asks the mini model for three titles. That request
    /// belongs to the sheet: closing it must end the request. It used to run
    /// in a task nothing owned, which went on polling for up to 45 seconds.
    @MainActor func testClosingTheRenameSheetEndsItsSuggestionRequest() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("rename-suggestions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try HoldingGateway(); defer { gateway.stop() }
        let base = try await gateway.start()
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var profile = ProfileRecord(); profile.id = "profile"; profile.baseUrl = base
        profile.modelId = "conversation-model"; profile.miniModelId = "mini-fixture"
        var configuration = VaultConfiguration(); configuration.automaticUpdateChecks = false
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-title-key")]
        configuration.workspaces = [.init(id: "project", path: project.path, trusted: true)]
        configuration.resources[WorkspaceRecord.scratchID] = .object(["codexHome": .string(root.appendingPathComponent("isolated-codex").path)])
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"),
                                   vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        let source = ChatRecord(id: "source", workspaceID: "project", title: "Improve the model selection please", path: nil, profileID: profile.id)
        model.chats = [source]; model.selectedID = source.id
        try await model.store?.put(source, kind: "chat", id: source.id)
        let display = SessionDisplay(id: source.id)
        display.messages = [TranscriptMessage(id: "u1", role: "user", text: "Improve the model selection please")]
        model.displays[source.id] = display; model.selected = display
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: AnyView(RenameChatSheet(model: model, chatID: source.id)))
        window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        func asking() -> Bool { model.chats.contains { $0.backgroundTask == "title-suggestions" } }
        for _ in 0..<600 where gateway.held == 0 { hosted.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(gateway.held, 1, "The open sheet asked the mini model for suggestions")
        XCTAssertTrue(asking())
        // The sheet closes while the model is still thinking.
        hosted.rootView = AnyView(EmptyView())
        for _ in 0..<200 where asking() { hosted.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(asking(), "Closing the sheet ends its request instead of polling on")
        try await model.hosts[WorkspaceRecord.scratchID]?.shutdownAndWait()
        try await model.traces.close(); await model.store?.close()
    }
}

/// Accepts a Responses request and never answers it, as a slow model would.
/// Anything else is not found.
private final class HoldingGateway: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BelloAgent.HoldingGatewayFixture")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var holding = 0
    var held: Int { lock.withLock { holding } }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> String {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue); self.receive(connection, previous: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.listener.stateUpdateHandler = nil; continuation.resume(returning: "http://127.0.0.1:\(self.listener.port!.rawValue)")
                case .failed(let error): self.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel(); lock.withLock { connections }.forEach { $0.cancel() } }
    private func receive(_ connection: NWConnection, previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            let bytes = previous + (data ?? Data())
            guard error == nil, bytes.count <= 1_048_576 else { connection.cancel(); return }
            if let split = bytes.range(of: Data("\r\n\r\n".utf8)), let head = String(data: bytes[..<split.lowerBound], encoding: .utf8) {
                if head.hasPrefix("POST /v1/responses") { self.lock.withLock { self.holding += 1 }; return }
                let reply = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
            } else if !complete { self.receive(connection, previous: bytes) }
            else { connection.cancel() }
        }
    }
}

/// Reads the complete declared body before validating it. Only synthetic
/// loopback credentials and the title request are accepted by this fixture.
private final class TitleGenerationGateway: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BelloAgent.TitleGenerationFixture")
    private let lock = NSLock()
    private var captured: [String] = []
    private var connections: [NWConnection] = []
    var requests: [String] { lock.withLock { captured } }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> String {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue); self.receive(connection, previous: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.listener.stateUpdateHandler = nil; continuation.resume(returning: "http://127.0.0.1:\(self.listener.port!.rawValue)")
                case .failed(let error): self.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel(); lock.withLock { connections }.forEach { $0.cancel() } }
    private func receive(_ connection: NWConnection, previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            let bytes = previous + (data ?? Data())
            guard bytes.count <= 65_536, error == nil else { connection.cancel(); return }
            if let split = bytes.range(of: Data("\r\n\r\n".utf8)),
               let head = String(data: bytes[..<split.lowerBound], encoding: .utf8),
               let lengthLine = head.lowercased().components(separatedBy: "\r\n").first(where: { $0.hasPrefix("content-length:") }),
               let length = Int(lengthLine.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)), length >= 0,
               bytes.count >= split.upperBound + length {
                let request = String(decoding: bytes.prefix(split.upperBound + length), as: UTF8.self)
                self.lock.withLock { self.captured.append(request) }
                let body = try? JSONDecoder().decode(WireValue.self, from: Data(bytes[split.upperBound..<(split.upperBound + length)])).object
                let valid = head.hasPrefix("POST /v1/responses HTTP/1.1") &&
                    head.lowercased().contains("authorization: bearer synthetic-title-key") &&
                    body?["model"]?.string == "mini-fixture" && body?["max_output_tokens"]?.number == 512 &&
                    (body?["tools"]?.array ?? []).isEmpty && !request.contains("PRIVATE PROJECT INSTRUCTION") &&
                    body?["instructions"]?.string?.contains("Generate a short session title") == true
                let response = valid
                    ? #"{"id":"resp_title","object":"response","status":"completed","model":"resolved-mini-fixture","output":[{"id":"msg_title","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Improve the model picker"}]}],"usage":{"input_tokens":24,"output_tokens":5,"total_tokens":29}}"#
                    : #"{"error":{"message":"Title request failed fixture validation"}}"#
                let payload = Data(response.utf8)
                let reply = Data("HTTP/1.1 \(valid ? "200 OK" : "422 Unprocessable Entity")\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nx-litellm-response-cost: 0.00001\r\nConnection: close\r\n\r\n".utf8) + payload
                connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
            } else if !complete { self.receive(connection, previous: bytes) }
            else { connection.cancel() }
        }
    }
}

extension TitleGenerationTests {
    /// A title request the app quit during kept its claim for good: only the
    /// first send asks for a title, so the chat kept its first-message title,
    /// and its row, with no recorded end, read as an unknown outcome. A
    /// suggestions row the rename sheet was using stayed in the list too.
    @MainActor func testATitleRequestInterruptedByAQuitIsAskedAgainOnTheNextMessage() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let store = MetadataStore(url: state.appendingPathComponent("desktop.sqlite"))
        let source = ChatRecord(id: "source", workspaceID: "project", title: "First message", path: nil, profileID: "profile")
        try await store.put(source, kind: "chat", id: source.id)
        _ = try await store.createTitleTask(task("interrupted"), sourceID: source.id)
        var suggestions = task("suggestions"); suggestions.title = "Title suggestions"; suggestions.backgroundTask = "title-suggestions"
        try await store.put(suggestions, kind: "chat", id: suggestions.id)
        await store.close()
        var profile = ProfileRecord(); profile.id = "profile"; profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "fixture"
        var configuration = VaultConfiguration(); configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic")]; configuration.automaticUpdateChecks = false
        let model = WorkspaceModel(stateRoot: state, vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        defer { model.report.suspend(); model.shutdown() }
        await model.restore()
        XCTAssertFalse(model.chats.contains { $0.id == "suggestions" }, "Launch removes a leftover suggestions row")
        let listed = try await model.store?.list(ChatRecord.self, kind: "chat") ?? []
        XCTAssertFalse(listed.contains { $0.id == "suggestions" })
        XCTAssertEqual(model.record("source")?.titleTaskSessionID, "interrupted", "Launch itself resends nothing")
        // What sending the next message in the chat does once it is accepted.
        model.resumeInterruptedTitle("source")
        for _ in 0..<500 where model.record("source")?.titleTaskSessionID == "interrupted" || !model.titleGenerationTasks.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotEqual(model.record("source")?.titleTaskSessionID, "interrupted", "The stale claim is released and a title asked for again")
        XCTAssertNotNil(model.chats.first { $0.id == "interrupted" }?.backgroundTaskNotice, "The interrupted request says how it ended")
        try await model.traces.close(); await model.store?.close()
    }
}
