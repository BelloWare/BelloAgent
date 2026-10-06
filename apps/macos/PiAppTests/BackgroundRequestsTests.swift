import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// The Background requests page: every request the app asked a mini model
/// on its own is kept and listed there, newest first, filtered by kind; a quit
/// leaves the ones it cut short interrupted; the sidebar never lists them;
/// and a selected request reads its prompt and reply and opens its Inspector.
final class BackgroundRequestsTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("background-requests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func request(_ id: String, _ task: String, source: String = "source", started: Date? = nil, outcome: String? = nil,
                         result: String? = nil, notice: String? = nil) -> ChatRecord {
        var value = ChatRecord(id: id, workspaceID: WorkspaceRecord.scratchID, title: task == "session-title" ? TitleGenerationPlan.fixedTitle : "Request",
                               path: nil, profileID: "profile", toolMode: "read-only", connectionTest: true,
                               model: "mini-fixture", thinkingLevel: "default", contextWindow: 16_000, maxOutputTokens: 512)
        value.backgroundTask = task; value.sourceSessionID = source
        value.backgroundTaskStartedAt = started; value.backgroundTaskOutcome = outcome
        value.backgroundTaskResult = result; value.backgroundTaskNotice = notice
        if outcome != nil, let started { value.backgroundTaskEndedAt = started.addingTimeInterval(1.5) }
        return value
    }
    private func profile() -> ProfileRecord {
        var value = ProfileRecord(); value.id = "profile"; value.name = "Fixture gateway"; value.baseUrl = "http://127.0.0.1:1"; value.modelId = "fixture"
        return value
    }

    /// A request the app quit during, of this version, reads interrupted after
    /// a relaunch instead of being removed; records written before outcomes
    /// were kept get theirs from what they left; how a request ended is never
    /// taken back by a later write of an older copy.
    @MainActor func testRequestsAreKeptAndTheOnesAQuitCutShortAreInterrupted() async throws {
        let root = try scratch()
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let store = MetadataStore(url: state.appendingPathComponent("desktop.sqlite"))
        var source = ChatRecord(id: "source", workspaceID: "project", title: "Improve the model picker", path: nil, profileID: "profile")
        source.titleWasGenerated = true; source.titleTaskSessionID = "legacy-title"
        try await store.put(source, kind: "chat", id: source.id)
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        try await store.put(request("cut-short", "title-suggestions", started: started), kind: "chat", id: "cut-short")
        try await store.put(request("legacy-title", "session-title"), kind: "chat", id: "legacy-title")
        try await store.put(request("legacy-failed", "session-title", notice: "Title generation timed out. The original title was kept; nothing was retried."), kind: "chat", id: "legacy-failed")
        try await store.put(request("webhook", "webhook", started: started, outcome: "completed", result: "title: Done"), kind: "chat", id: "webhook")
        await store.close()
        var configuration = VaultConfiguration(); configuration.profiles = [VaultProfile(profile: profile(), apiKey: "synthetic")]; configuration.automaticUpdateChecks = false
        let model = makeWorkspaceModel(stateRoot: state, vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        defer { model.report.suspend(); model.shutdown() }
        await model.restore()

        XCTAssertEqual(model.record("cut-short")?.backgroundTaskOutcome, "interrupted", "Kept, and marked interrupted")
        XCTAssertEqual(model.record("cut-short")?.backgroundTaskNotice, BackgroundRequests.interruptedNotice)
        XCTAssertEqual(model.record("legacy-title")?.backgroundTaskOutcome, "completed", "An older title request its chat took a title from ended well")
        XCTAssertNotNil(model.record("legacy-title")?.backgroundTaskStartedAt, "It is dated from when it was made")
        XCTAssertEqual(model.record("legacy-failed")?.backgroundTaskOutcome, "failed")
        XCTAssertEqual(model.record("webhook")?.backgroundTaskResult, "title: Done", "A finished request is left as it was")
        let listed = try await model.store?.list(ChatRecord.self, kind: "chat") ?? []
        XCTAssertEqual(listed.first { $0.id == "cut-short" }?.backgroundTaskOutcome, "interrupted", "How it ended is saved")

        // A request ends: its outcome, result and end are written with it...
        var running = request("running", "title-suggestions", started: Date())
        model.backgroundRequestsRunning.insert(running.id)
        model.chats.append(running); try await model.store?.put(running, kind: "chat", id: running.id)
        XCTAssertEqual(BackgroundRequests.status(of: running, running: model.backgroundRequestsRunning.contains(running.id), source: nil), .running)
        await model.finishBackgroundRequest(running.id, outcome: "completed", result: "One\nTwo\nThree")
        let finished = try await model.store?.get(ChatRecord.self, kind: "chat", id: running.id)
        XCTAssertEqual(finished?.backgroundTaskOutcome, "completed"); XCTAssertEqual(finished?.backgroundTaskResult, "One\nTwo\nThree")
        XCTAssertNotNil(finished?.backgroundTaskEndedAt)
        // ...and an older copy written after it (a path update) does not take it back.
        running.path = "/synthetic/journal.jsonl"
        try await model.store?.put(running, kind: "chat", id: running.id)
        let rewritten = try await model.store?.get(ChatRecord.self, kind: "chat", id: running.id)
        XCTAssertEqual(rewritten?.backgroundTaskOutcome, "completed"); XCTAssertEqual(rewritten?.backgroundTaskResult, "One\nTwo\nThree")
        XCTAssertEqual(rewritten?.path, "/synthetic/journal.jsonl")
        await model.store?.close()
    }

    /// The rows, newest first, each with its chat, project, connection,
    /// model, result and duration; the filter keeps one kind and counts each.
    @MainActor func testThePageListsNewestFirstAndFiltersByKind() async throws {
        let root = try scratch()
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.backgroundRequests.suspend(); model.shutdown() }
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        model.workspaces = [.init(id: "project", path: root.appendingPathComponent("pi-app").path, trusted: true)]
        model.profiles = [profile()]
        let source = ChatRecord(id: "source", workspaceID: "project", title: "Fix the login loop", path: nil, profileID: "profile")
        model.chats = [
            source,
            request("title-1", "session-title", started: base, outcome: "completed", result: "Fix the login loop"),
            request("hook-1", "webhook", started: base.addingTimeInterval(60), outcome: "failed", notice: "The mini model did not answer."),
            request("suggest-1", "title-suggestions", started: base.addingTimeInterval(120), outcome: "completed", result: "Login loop\nRedirect fix\nAuth bug"),
            request("title-2", "session-title", source: "gone", started: base.addingTimeInterval(180), outcome: "interrupted", notice: BackgroundRequests.interruptedNotice),
            request("hook-2", "webhook", started: base.addingTimeInterval(240)),
        ]
        model.backgroundRequestsRunning = ["hook-2"]
        let requests = model.backgroundRequests
        requests.prepare(model)
        XCTAssertEqual(requests.rows.map(\.id), ["hook-2", "title-2", "suggest-1", "hook-1", "title-1"], "Newest first")
        XCTAssertEqual(requests.counts[.all], 5); XCTAssertEqual(requests.counts[.titles], 2)
        XCTAssertEqual(requests.counts[.suggestions], 1); XCTAssertEqual(requests.counts[.webhooks], 2)
        XCTAssertEqual(requests.summary.running, 1); XCTAssertEqual(requests.summary.failed, 1)

        let suggestion = try XCTUnwrap(requests.rows.first { $0.id == "suggest-1" })
        XCTAssertEqual(suggestion.kind, .suggestions); XCTAssertEqual(suggestion.status, .completed)
        XCTAssertEqual(suggestion.resultLine, "Login loop · Redirect fix · Auth bug")
        XCTAssertEqual(suggestion.sourceTitle, "Fix the login loop"); XCTAssertEqual(suggestion.project, "pi-app")
        XCTAssertEqual(suggestion.connection, "Fixture gateway"); XCTAssertEqual(suggestion.model, "mini-fixture")
        XCTAssertEqual(suggestion.durationMs ?? 0, 1_500, accuracy: 1)
        XCTAssertEqual(requests.rows.first { $0.id == "hook-1" }?.status, .failed("The mini model did not answer."))
        XCTAssertEqual(requests.rows.first { $0.id == "hook-2" }?.status, .running)
        XCTAssertNil(requests.rows.first { $0.id == "title-2" }?.sourceTitle, "A request whose chat is gone says so")

        requests.filter = .titles
        XCTAssertEqual(requests.rows.map(\.id), ["title-2", "title-1"])
        requests.filter = .webhooks
        XCTAssertEqual(requests.rows.map(\.id), ["hook-2", "hook-1"])
        XCTAssertEqual(requests.summary.requests, 2)
        requests.filter = .all

        // A request starts and ends while the page is up.
        model.chats.append(request("suggest-2", "title-suggestions", started: base.addingTimeInterval(300)))
        model.backgroundRequestsRunning.insert("suggest-2")
        requests.recordsChanged()
        XCTAssertEqual(requests.rows.first?.id, "suggest-2"); XCTAssertEqual(requests.rows.first?.status, .running)
        await model.finishBackgroundRequest("suggest-2", outcome: "interrupted", notice: BackgroundRequests.stoppedNotice)
        requests.recordsChanged()
        XCTAssertEqual(requests.rows.first?.status, .interrupted(BackgroundRequests.stoppedNotice))
        await model.store?.close()
    }

    /// No background request is ever a sidebar row, in any group; a chat
    /// outside every project that is not one (a connection test) still is.
    @MainActor func testTheSidebarNeverListsBackgroundRequests() async throws {
        let root = try scratch()
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        model.workspaces = [.init(id: "project", path: root.path, trusted: true)]
        let source = ChatRecord(id: "source", workspaceID: "project", title: "First message", path: nil, profileID: "profile")
        var archived = request("archived", "session-title", outcome: "completed"); archived.archivedAt = Date()
        model.chats = [source, request("title", "session-title", outcome: "completed"), request("hook", "webhook", outcome: "failed"), archived]
        XCTAssertFalse(model.sidebarProjects.contains { $0.id == WorkspaceRecord.scratchID }, "No group for requests alone")
        XCTAssertTrue(model.sidebarChats(in: WorkspaceRecord.scratchID, archived: false).isEmpty)
        XCTAssertTrue(model.sidebarChats(in: WorkspaceRecord.scratchID, archived: true).isEmpty)
        XCTAssertTrue(model.sidebarEntries(in: WorkspaceRecord.scratchID, topicID: nil, archived: false, collapsed: []).isEmpty)
        let test = ChatRecord(id: "connection-test", workspaceID: WorkspaceRecord.scratchID, title: "Connection test", path: nil, profileID: "profile", toolMode: "read-only", connectionTest: true)
        model.chats.append(test)
        XCTAssertTrue(model.sidebarProjects.contains { $0.id == WorkspaceRecord.scratchID }, "A connection test stays where it was")
        XCTAssertEqual(model.sidebarChats(in: WorkspaceRecord.scratchID, archived: false).map(\.id), [test.id])
        await model.store?.close()
    }

    /// The page opens on a request from the menu, reads the prompt and the
    /// reply from its journal, and its Inspect Requests opens that request's
    /// Session Inspector; Open Source Chat goes back to the chat.
    @MainActor func testThePageOpensAndItsInspectorLinkWorks() async throws {
        let root = try scratch()
        SessionInspectorWindows.shared.closeAll()
        defer { SessionInspectorWindows.shared.closeAll() }
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.backgroundRequests.suspend(); model.shutdown() }
        model.workspaces = [.init(id: "project", path: root.path, trusted: true)]
        model.profiles = [profile()]
        // The request's journal, as the helper writes one.
        let journal = root.appendingPathComponent("request.jsonl")
        let prompt = "Suggest 3 different concise session titles.\nFirst user message:\n\"Fix the login loop\""
        var lines = [#"{"type":"session","version":3,"id":"request"}"#]
        for (id, parent, role, text) in [("u1", nil, "user", prompt), ("a1", "u1", "assistant", "Login loop\nRedirect fix\nAuth bug")] as [(String, String?, String, String)] {
            let value: [String: Any] = ["type": "message", "id": id, "parentId": parent as Any? ?? NSNull(),
                                        "message": ["role": role, "content": [["type": "text", "text": text]]]]
            lines.append(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: journal, atomically: true, encoding: .utf8)
        let source = ChatRecord(id: "source", workspaceID: "project", title: "Fix the login loop", path: nil, profileID: "profile")
        var asked = request("request", "title-suggestions", started: Date().addingTimeInterval(-90), outcome: "completed", result: "Login loop\nRedirect fix\nAuth bug")
        asked.path = journal.path
        model.chats = [source, asked]
        await model.select(source.id)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = WorkspaceRootView(model: model)
        window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        // From the menu bar's running requests or the report, selecting a
        // request opens the page on it.
        await model.select(asked.id)
        XCTAssertEqual(model.page, .background)
        XCTAssertEqual(model.backgroundRequests.selectedID, asked.id)
        for _ in 0..<400 where model.backgroundRequests.detail?.reply == nil {
            hosted.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.backgroundRequests.rows.map(\.id), [asked.id], "Mounted, the page lists the request")
        XCTAssertEqual(model.backgroundRequests.detail?.prompt, prompt, "The prompt sent, read from the journal")
        XCTAssertEqual(model.backgroundRequests.detail?.reply, "Login loop\nRedirect fix\nAuth bug")
        XCTAssertEqual(model.selectedID, source.id, "The chat under the page stays the reader's")

        // Inspect Requests: the request's own Session Inspector.
        XCTAssertNil(model.lastInspectorFocus)
        model.inspectBackgroundRequest(asked.id)
        XCTAssertEqual(model.lastInspectorFocus, .latestRequest)
        let inspector = try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID: asked.id)?.inspector, "The request's Inspector opened")
        XCTAssertEqual(inspector.scope, SessionUsageScope(sessionID: asked.id, workspaceID: WorkspaceRecord.scratchID))

        // Open Source Chat: back to the chat it was for.
        model.openBackgroundRequestSource(asked.id)
        for _ in 0..<200 where model.page != .chats { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.page, .chats); XCTAssertEqual(model.selectedID, source.id)
        await model.store?.close()
    }
}

extension BackgroundRequestsTests {
    @MainActor private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }

    /// The AppKit page: a row per request, kept (the same view) while its
    /// request changes; a click selects it and the details sit beside the list,
    /// or cover it on a narrow page, where the list takes no clicks; the close
    /// button and the filter tabs work; a disabled page disables its controls.
    @MainActor func testThePageShowsRowsAndTheSelectedRequestsDetails() async throws {
        let root = try scratch()
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.backgroundRequests.suspend(); model.shutdown() }
        let base = Date().addingTimeInterval(-600)
        model.workspaces = [.init(id: "project", path: root.appendingPathComponent("pi-app").path, trusted: true)]
        model.profiles = [profile()]
        model.chats = [
            ChatRecord(id: "source", workspaceID: "project", title: "Fix the login loop", path: nil, profileID: "profile"),
            request("title-1", "session-title", started: base, outcome: "completed", result: "Fix the login loop"),
            request("hook-1", "webhook", started: base.addingTimeInterval(60), outcome: "failed", notice: "The mini model did not answer."),
            request("hook-2", "webhook", started: base.addingTimeInterval(120)),
        ]
        model.backgroundRequestsRunning = ["hook-2"]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let page = BackgroundRequestsPage(model: model)
        window.contentView = page; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func settle() async throws { for _ in 0..<5 { try await Task.sleep(for: .milliseconds(15)); page.layoutSubtreeIfNeeded() } }
        try await settle()
        var rows = all(PiKit.SelectableRow.self, in: page)
        XCTAssertEqual(rows.map { $0.accessibilityIdentifier() }, ["backgroundRequest-hook-2", "backgroundRequest-hook-1", "backgroundRequest-title-1"], "Newest first")
        let running = rows[0]

        // A request ends: its row is the same view, now reading the outcome.
        await model.finishBackgroundRequest("hook-2", outcome: "completed", notice: nil)
        model.backgroundRequestsRunning = []
        model.backgroundRequests.recordsChanged()
        try await settle()
        rows = all(PiKit.SelectableRow.self, in: page)
        XCTAssertTrue(rows[0] === running, "The row is kept")
        XCTAssertTrue(all(PiKit.Badge.self, in: rows[0]).contains { $0.text == "Done" }, "It reads its new status")

        // Selecting a row shows its details beside the list.
        rows[1].performClick(nil)
        try await settle()
        XCTAssertEqual(model.backgroundRequests.selectedID, "hook-1")
        let pane = try XCTUnwrap(all(BackgroundRequestDetailPane.self, in: page).first)
        XCTAssertEqual(pane.frame.width, 440, "Wide pages give the details 440 points")
        XCTAssertTrue(all(PiKit.Note.self, in: pane).contains { $0.text == "The mini model did not answer." }, "The failure's reason")
        XCTAssertNotNil(page.hitTest(page.convert(NSPoint(x: 100, y: 200), to: page.superview)), "The list still takes clicks")

        // Narrow, the details cover the list, which takes no clicks.
        window.setContentSize(NSSize(width: 800, height: 700))
        try await settle()
        XCTAssertEqual(pane.frame.width, 800)
        let point = page.convert(NSPoint(x: 100, y: 200), to: page.superview)
        XCTAssertFalse(page.hitTest(point).map { $0.isDescendant(of: all(LazyStackView.self, in: page)[0]) } ?? false, "The covered list takes no clicks")

        // Close: back to the list.
        try XCTUnwrap(all(PiKit.IconButton.self, in: pane).first).performClick(nil)
        try await settle()
        XCTAssertNil(model.backgroundRequests.selectedID)
        XCTAssertTrue(all(BackgroundRequestDetailPane.self, in: page).isEmpty)

        // The tabs filter the list.
        model.backgroundRequests.filter = .titles
        try await settle()
        XCTAssertEqual(all(PiKit.SelectableRow.self, in: page).map { $0.accessibilityIdentifier() }, ["backgroundRequest-title-1"])

        // Disabled with the window: every control, and back again.
        let before = Dictionary(uniqueKeysWithValues: PiKit.controls(in: page).map { (ObjectIdentifier($0), $0.isEnabled) })
        page.inheritedEnabled = false
        XCTAssertTrue(PiKit.controls(in: page).allSatisfy { !$0.isEnabled })
        page.inheritedEnabled = true
        XCTAssertTrue(PiKit.controls(in: page).allSatisfy { $0.isEnabled == before[ObjectIdentifier($0)] })
        await model.store?.close()
    }
}

extension BackgroundRequestsTests {
    /// The journal's read landing changes only the exchange: the result the
    /// reader may be selecting in, and the action buttons, are the same views.
    @MainActor func testTheDetailsKeepTheirPartsWhenTheJournalArrives() throws {
        var record = request("r", "title-suggestions", started: Date().addingTimeInterval(-60), outcome: "completed", result: "Login loop\nAuth bug")
        record.path = "/nonexistent"
        let row = try XCTUnwrap(BackgroundRequestRow.rows(records: [record], lookup: { _ in nil }, workspaces: [], profiles: [profile()], running: [], totals: [:]).first)
        let pane = BackgroundRequestDetailPane(row: row, detail: nil, loading: true, openSource: { _ in }, inspect: { _ in }, close: {})
        pane.frame = CGRect(x: 0, y: 0, width: 440, height: 700); pane.layoutSubtreeIfNeeded()
        func find(_ id: String) -> NSView? {
            func walk(_ view: NSView) -> NSView? { view.accessibilityIdentifier() == id ? view : view.subviews.lazy.compactMap(walk).first }
            return walk(pane)
        }
        let result = try XCTUnwrap(find("backgroundRequestResult"))
        let open = try XCTUnwrap(find("backgroundRequestOpenSource"))
        XCTAssertNil(find("backgroundRequestPrompt"))
        pane.update(row: row, detail: BackgroundRequestDetail(prompt: "Suggest titles", reply: "Login loop"), loading: false)
        pane.layoutSubtreeIfNeeded()
        XCTAssertTrue(find("backgroundRequestResult") === result, "The result is the same view")
        XCTAssertTrue(find("backgroundRequestOpenSource") === open, "So are the actions")
        XCTAssertNotNil(find("backgroundRequestPrompt"), "The prompt arrived")
        XCTAssertNotNil(find("backgroundRequestReply"))
    }
}
