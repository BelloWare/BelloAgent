import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// Quitting and opening the app again puts the reader back on the chat they
/// had open: its project, the side beside it, the place they were reading,
/// and a sidebar row they can see. Every launch here is a new
/// `WorkspaceModel` over the same state directory, restored the way the app
/// restores it, and every quit goes through the app's own quit path.
final class LaunchSelectionTests: XCTestCase {
    /// Two projects and three chats. `a` sorts first, so it is what every
    /// launch opened before the open chat was remembered; `b2`, the second
    /// chat of the second project, has three long turns of history.
    @MainActor private struct Fixture {
        let root: URL
        let state: URL
        let vault: ConfigurationVault
        let first: WorkspaceRecord
        let second: WorkspaceRecord
        let profile: ProfileRecord
        let a: ChatRecord, b1: ChatRecord, b2: ChatRecord
        var b2Messages: [String] { (0..<3).flatMap { ["b2-q\($0)", "b2-a\($0)"] } }
    }

    /// The record as the store holds it, read the way any test reads a record.
    private struct StoredSelection: Decodable, Sendable { var chatID: String?; var shownSides: [String: String]? }

    @MainActor private func fixture(_ extra: [ChatRecord] = [], archiveB2: Bool = false, b2Topic: TopicRecord? = nil,
                                    journals: [String: [(role: String, id: String, text: String)]] = [:]) async throws -> Fixture {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("launch-selection-" + UUID().uuidString)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var profile = ProfileRecord(); profile.id = "launch-profile"; profile.name = "Launch"
        profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "launch-model"
        let first = WorkspaceRecord(id: "first-project", path: root.appendingPathComponent("first").path, trusted: true)
        let second = WorkspaceRecord(id: "second-project", path: root.appendingPathComponent("second").path, trusted: true)
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        let saved = profile
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [first, second]; $0.profiles = [VaultProfile(profile: saved, apiKey: "synthetic-launch-key")]
            $0.automaticUpdateChecks = false
        }
        let answer = (0..<40).map { "Paragraph \($0) of a long answer, long enough to wrap across the width of the pane." }.joined(separator: "\n\n")
        var b2Journal: [(role: String, id: String, text: String)] = []
        for turn in 0..<3 {
            b2Journal.append((role: "user", id: "b2-q\(turn)", text: "Question \(turn)"))
            b2Journal.append((role: "assistant", id: "b2-a\(turn)", text: "Answer \(turn).\n\n" + answer))
        }
        let a = ChatRecord(id: "a", workspaceID: first.id, title: "A", path: nil, profileID: profile.id, sidebarOrder: 3_000)
        let b1 = ChatRecord(id: "b1", workspaceID: second.id, title: "B1", path: nil, profileID: profile.id, sidebarOrder: 2_000)
        var b2 = ChatRecord(id: "b2", workspaceID: second.id, title: "B2", path: try journal("b2", b2Journal, in: root).path,
                            profileID: profile.id, sidebarOrder: 1_000)
        if archiveB2 { b2.archivedAt = Date() }
        b2.topicID = b2Topic?.id
        let store = MetadataStore(url: state.appendingPathComponent("desktop.sqlite"))
        if let b2Topic { _ = try await store.createTopic(b2Topic) }
        var extras = extra
        for index in extras.indices { if let rows = journals[extras[index].id] { extras[index].path = try journal(extras[index].id, rows, in: root).path } }
        for chat in [a, b1, b2] + extras { try await store.put(chat, kind: "chat", id: chat.id) }
        await store.close()
        return Fixture(root: root, state: state, vault: vault, first: first, second: second, profile: profile, a: a, b1: b1, b2: b2)
    }

    private func journal(_ id: String, _ rows: [(role: String, id: String, text: String)], in root: URL) throws -> URL {
        let url = root.appendingPathComponent(id + ".jsonl")
        var data = Data(), parent: WireValue = .null
        let encoder = JSONEncoder()
        func append(_ value: [String: WireValue]) throws { data.append(try encoder.encode(value)); data.append(10) }
        try append(["type": .string("session"), "version": .number(3), "id": .string(id)])
        for row in rows {
            try append(["type": .string("message"), "id": .string(row.id), "parentId": parent,
                        "message": .object(["role": .string(row.role), "content": .string(row.text)])])
            parent = .string(row.id)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// A launch: a new model over the same state, restored as the app does.
    /// The focused chat's context meter is the one thing stubbed out: it
    /// starts a helper for an idle saved chat on its own schedule, which says
    /// nothing about what the launch opened.
    @MainActor private func launch(_ fixture: Fixture, before restoring: (WorkspaceModel) -> Void = { _ in }) async -> WorkspaceModel {
        let model = unrestoredModel(fixture)
        restoring(model)
        await model.restore()
        return model
    }

    @MainActor private func unrestoredModel(_ fixture: Fixture, state: URL? = nil, launching: Bool = false) -> WorkspaceModel {
        let model = WorkspaceModel(stateRoot: state ?? fixture.state, vault: fixture.vault, launching: launching)
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        addTeardownBlock { @MainActor in
            model.report.suspend(); model.shutdown()
            for host in model.hosts.values { try? await host.shutdownAndWait() }
            try? await model.traces.close(); await model.store?.close()
        }
        return model
    }

    /// ⌘Q: the app's own quit path, which saves before it answers.
    @MainActor private func quit(_ model: WorkspaceModel, file: StaticString = #filePath, line: UInt = #line) async throws {
        await waitFor("The model still had work in flight when the test quit", file: file, line: line) { !model.hasActiveWork }
        let lifecycle = ApplicationLifecycle()
        lifecycle.model = model
        var answers: [Bool] = []
        lifecycle.answerTermination = { answers.append($0) }
        XCTAssertEqual(lifecycle.applicationShouldTerminate(NSApp), .terminateLater, file: file, line: line)
        await waitFor("Quitting never answered", file: file, line: line) { !answers.isEmpty }
        XCTAssertEqual(answers, [true], "Nothing here should keep the app from quitting", file: file, line: line)
        model.report.suspend()
        try await model.traces.close(); await model.store?.close()
    }

    @MainActor private func waitFor(_ what: String, seconds: Double = 10, drawing window: NSWindow? = nil,
                                    file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let window { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(15))
        }
        XCTFail(what, file: file, line: line)
    }

    /// The window the app opens, with the workspace in it, before the chats
    /// are read back: the launch the reader sees.
    @MainActor private func window(for model: WorkspaceModel) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted
        window.center(); window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        return (window, hosted)
    }

    @MainActor private func page(in view: NSView) -> TranscriptPage? {
        func markers(_ view: NSView) -> [TranscriptSurfaceMarker] {
            ((view as? TranscriptSurfaceMarker).map { [$0] } ?? []) + view.subviews.flatMap { markers($0) }
        }
        return markers(view).first?.page
    }

    // MARK: The chat, its project and its transcript

    @MainActor func testARelaunchReopensTheChatAndProjectTheReaderLeftOpen() async throws {
        let fixture = try await fixture()
        let first = await launch(fixture)
        XCTAssertEqual(first.selectedID, fixture.a.id, "A store with nothing remembered opens the first chat, as before")
        await first.select(fixture.b2.id)
        XCTAssertEqual(first.selectedWorkspaceID, fixture.second.id)
        try await quit(first)

        var shown: (window: NSWindow, view: NSView)?
        let second = await launch(fixture) { model in shown = self.window(for: model) }
        let (window, view) = try XCTUnwrap(shown)
        XCTAssertEqual(second.selectedID, fixture.b2.id, "The relaunch must reopen the chat that was open, not the one that sorts first")
        XCTAssertEqual(second.selectedWorkspaceID, fixture.second.id, "and its project")
        XCTAssertEqual(second.focusedSessionID, fixture.b2.id)
        XCTAssertEqual(second.selected?.messages.map(\.id), fixture.b2Messages)
        await waitFor("The pane never showed the reopened chat's transcript", drawing: window) {
            let page = self.page(in: view)
            return page?.sessionID == fixture.b2.id && page?.snapshot?.messages.map(\.id) == fixture.b2Messages
        }
        XCTAssertEqual(second.displays.count, 1, "A launch reads one chat, the one it opens")
        XCTAssertTrue(second.hosts.isEmpty, "Reopening a chat starts no helper")
    }

    /// Launch opens the chat it restores as soon as that chat can be read and
    /// written — its request archive open — and before the retained billing
    /// of every listed chat, the slowest read left. The first chat the pane
    /// paints is that chat, and until it does the pane shows nothing: not the
    /// welcome, whose setup buttons stand there before the vault answers.
    @MainActor func testTheRestoredChatIsTheOnlyChatPaintedAndPaintsBeforeTheRetainedBilling() async throws {
        let fixture = try await fixture()
        let first = await launch(fixture)
        await first.select(fixture.b2.id)
        try await quit(first)

        // As the app builds it: launching from its window's first frame.
        let second = unrestoredModel(fixture, launching: true)
        // The request archive is held from the moment launch reads the chat
        // it opens: it is open by then, and what launch reads from it after
        // that — the retained billing — is still to come.
        let archive = second.traces, reader = HistoryReader(), gate = ArchiveGate()
        let path = try XCTUnwrap(fixture.b2.path)
        second.historyWindowLoader = { _, cursor, newer, around in
            await gate.hold(archive)
            return try ConversationHistoryPage(await reader.window(path: path, cursor: cursor, newer: newer, around: around))
        }
        let (window, view) = self.window(for: second)
        let finished = LaunchFlag()
        let restoring = Task { @MainActor in await second.restore(); finished.value = true }
        var painted: [String] = [], welcomeFrames = 0
        await waitFor("The restored chat never painted", drawing: window) {
            let page = self.page(in: view)
            if let id = page?.sessionID, painted.last != id { painted.append(id) }
            // What `WorkspaceView` draws with no chat selected: nothing while
            // launching, the welcome or onboarding otherwise.
            if second.selected == nil, !second.launching { welcomeFrames += 1 }
            return page?.sessionID == fixture.b2.id && page?.rowFrame(of: "b2-q2") != nil
        }
        XCTAssertEqual(painted, [fixture.b2.id], "The first chat the pane paints after launch is the restored one, and no other is painted first")
        XCTAssertEqual(welcomeFrames, 0, "No frame of the launch showed the welcome in place of the chat")
        XCTAssertFalse(finished.value, "The restored chat is on screen while launch is still reading the retained billing")
        gate.release()
        await restoring.value
        XCTAssertTrue(finished.value)
        XCTAssertEqual(second.selectedID, fixture.b2.id)
    }

    /// A crash, a force-quit or a lost power supply runs no quit path. What
    /// was open is written as it changes, so it survives all of them.
    @MainActor func testTheOpenChatIsWrittenAsItChangesSoAForcedQuitStillReopensIt() async throws {
        let fixture = try await fixture()
        let first = await launch(fixture)
        await first.select(fixture.b1.id)
        await first.select(fixture.b2.id)
        let store = try XCTUnwrap(first.store)
        var written: StoredSelection?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            written = try await store.get(StoredSelection.self, kind: "selection", id: "main")
            if written?.chatID == fixture.b2.id { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(written?.chatID, fixture.b2.id, "The open chat must be written while the app runs, not only when it quits")
        // Killed: nothing is flushed and nothing is shut down.
        first.report.suspend()
        await first.store?.close()

        let second = await launch(fixture)
        XCTAssertEqual(second.selectedID, fixture.b2.id, "A relaunch after a forced quit reopens the chat that was open")
        XCTAssertEqual(second.selectedWorkspaceID, fixture.second.id)
    }

    /// The rows are live as soon as the chats are listed, and the request
    /// archive's retention sweep is the longest read after that. A chat the
    /// reader opens from them before launch finishes is the one they get,
    /// with its project and connection, and the one the next launch reopens.
    @MainActor func testAChatOpenedWhileLaunchIsStillReadingIsNotSwitchedAway() async throws {
        let other = ChatRecord(id: "c", workspaceID: "first-project", title: "C", path: nil, profileID: "other-profile", sidebarOrder: 1_500)
        let fixture = try await fixture([other])
        let first = await launch(fixture)
        await first.select(fixture.b2.id)
        try await quit(first)

        let second = unrestoredModel(fixture)
        let gate = ArchiveGate()
        await gate.hold(second.traces)
        let restoring = Task { await second.restore() }
        await waitFor("The sidebar never listed the chats") { !second.chats.isEmpty }
        await second.select(other.id)
        gate.release()
        await restoring.value
        XCTAssertEqual(second.selectedID, other.id, "Launch must not switch away from the chat the reader opened")
        XCTAssertEqual(second.selectedWorkspaceID, fixture.first.id, "nor from its project")
        XCTAssertEqual(second.profileChoice, other.profileID, "nor from its connection")
        XCTAssertEqual(Set(second.displays.keys), [other.id], "and it opened no other chat")
        try await quit(second)

        let third = await launch(fixture)
        XCTAssertEqual(third.selectedID, other.id, "The chat opened during the launch is the one the next launch reopens")
    }

    // MARK: What falls back, and what does not

    @MainActor func testAnArchivedChatTheReaderHadOpenIsReopenedAndItsRowShown() async throws {
        let fixture = try await fixture(archiveB2: true)
        let first = await launch(fixture)
        await first.select(fixture.b2.id)
        // Back to the project's active chats, with the archived one still open.
        first.setProjectArchiveFilter(fixture.second.id, archived: false)
        XCTAssertEqual(first.selectedID, fixture.b2.id)
        try await quit(first)

        let second = await launch(fixture)
        XCTAssertEqual(second.selectedID, fixture.b2.id, "The reader was looking at it: archived is no reason not to reopen it")
        XCTAssertTrue(second.record(fixture.b2.id)?.isArchived == true)
        XCTAssertEqual(second.selected?.messages.map(\.id), fixture.b2Messages)
        XCTAssertTrue(second.projectShowsArchive(fixture.second.id), "Its project lists the archive, where its row is")
        XCTAssertTrue(second.sidebarChatOrder.contains(fixture.b2.id), "The highlighted row can be seen")
        XCTAssertNotEqual(second.projectSidebarStates[fixture.second.id]?.archived, true, "The list the reader chose to save is not changed")
    }

    @MainActor func testAChatThatIsGoneOrABackgroundTaskFallsBackToTheFirstChat() async throws {
        var task = ChatRecord(id: "task", workspaceID: "second-project", title: "Title job", path: nil, profileID: "launch-profile", sidebarOrder: 4_000)
        task.backgroundTask = "title"; task.sourceSessionID = "b2"
        let fixture = try await fixture([task])
        let first = await launch(fixture)
        await first.select(fixture.b1.id)
        try await quit(first)

        let second = await launch(fixture)
        XCTAssertEqual(second.selectedID, fixture.b1.id)
        second.questions.answer = { _ in true }
        second.deleteChat(fixture.b1.id)
        await waitFor("Deleting the open chat never finished") { second.record(fixture.b1.id) == nil }
        XCTAssertNil(second.selectedID)
        try await quit(second)

        let third = await launch(fixture)
        XCTAssertEqual(third.selectedID, fixture.a.id, "A chat that is gone falls back to the first chat, as every launch did before")
        XCTAssertEqual(third.selectedWorkspaceID, fixture.first.id)
        await third.select(task.id)
        XCTAssertEqual(third.selectedID, task.id)
        try await quit(third)

        let fourth = await launch(fixture)
        XCTAssertEqual(fourth.selectedID, fixture.a.id, "A background task falls back to the first chat")
        XCTAssertEqual(fourth.selectedWorkspaceID, fixture.first.id)
    }

    /// A New chat that was never sent is written nowhere, by design. It must
    /// not take the place of the chat open before it; one that holds a draft
    /// when the app quits is given a chat record, and so it is reopened.
    @MainActor func testANewChatNeverSentKeepsTheChatOpenBeforeIt() async throws {
        let fixture = try await fixture()
        let first = await launch(fixture)
        await first.select(fixture.b1.id)
        first.newChat()
        await waitFor("New Chat never opened") { first.selectedID != fixture.b1.id && first.selectedID != nil && first.workspaceChangesInFlight.isEmpty }
        let unsent = try XCTUnwrap(first.selectedID)
        XCTAssertTrue(first.pendingChatIDs.contains(unsent))
        try await quit(first)

        let second = await launch(fixture)
        XCTAssertFalse(second.chats.contains { $0.id == unsent }, "Nothing was written for the empty New chat")
        XCTAssertEqual(second.selectedID, fixture.b1.id, "The chat open before the New chat is the one reopened")
        XCTAssertEqual(second.selectedWorkspaceID, fixture.second.id)

        second.newChat()
        await waitFor("New Chat never opened") { second.selectedID != fixture.b1.id && second.selectedID != nil && second.workspaceChangesInFlight.isEmpty }
        let drafted = try XCTUnwrap(second.selectedID)
        second.displays[drafted]?.draft = "Half a thought"
        try await quit(second)

        let third = await launch(fixture)
        XCTAssertEqual(third.selectedID, drafted, "A New chat whose draft was saved at quit is a chat, and the one reopened")
        XCTAssertEqual(third.selected?.draft, "Half a thought")
    }

    /// The chosen project after a relaunch is the reopened chat's own. A New
    /// chat started in another project and never sent leaves the chat open
    /// before it, in that chat's project; a chat outside every project keeps
    /// the project that was chosen beside it.
    @MainActor func testTheChosenProjectIsTheReopenedChatsOwn() async throws {
        var outside = ChatRecord(id: "probe", workspaceID: WorkspaceRecord.scratchID, title: "Connection test", path: nil,
                                 profileID: "launch-profile", sidebarOrder: 100)
        outside.connectionTest = true
        let fixture = try await fixture([outside])
        let first = await launch(fixture)
        await first.select(fixture.b1.id)
        first.newChat(in: fixture.first.id)
        await waitFor("New Chat never opened") { first.selectedID != fixture.b1.id && first.selectedID != nil && first.workspaceChangesInFlight.isEmpty }
        XCTAssertEqual(first.selectedWorkspaceID, fixture.first.id)
        try await quit(first)

        let second = await launch(fixture)
        XCTAssertEqual(second.selectedID, fixture.b1.id)
        XCTAssertEqual(second.selectedWorkspaceID, fixture.second.id, "The chat's own project, not the one the unsent New chat was started in")
        await second.select(outside.id)
        XCTAssertEqual(second.selectedWorkspaceID, fixture.second.id)
        try await quit(second)

        let third = await launch(fixture)
        XCTAssertEqual(third.selectedID, outside.id)
        XCTAssertEqual(third.selectedWorkspaceID, fixture.second.id, "A chat outside every project keeps the project chosen beside it")
    }

    // MARK: The side beside it, and where it was being read

    /// `b2` with a kept side conversation of its own.
    @MainActor private func sideFixture() async throws -> (Fixture, ChatRecord) {
        var side = ChatRecord(id: "side", workspaceID: "second-project", title: "B2 — side", path: nil, profileID: "launch-profile", toolMode: "read-only", sidebarOrder: 500)
        side.parentSessionID = "b2"
        let fixture = try await fixture([side], journals: ["side": [(role: "user", id: "side-q", text: "A side question"),
                                                                  (role: "assistant", id: "side-a", text: "A side answer")]])
        return (fixture, side)
    }

    @MainActor func testASideShownBesideTheOpenChatIsReopenedWithTheFocusItHad() async throws {
        let (fixture, side) = try await sideFixture()
        let first = await launch(fixture)
        await first.select(fixture.b2.id)
        await first.showSide(side.id)
        XCTAssertEqual(first.sides[fixture.b2.id]?.id, side.id)
        XCTAssertEqual(first.focusedSessionID, side.id)
        // Back in the parent's composer.
        first.focusedSessionID = fixture.b2.id
        try await quit(first)

        let second = await launch(fixture)
        XCTAssertEqual(second.selectedID, fixture.b2.id)
        let shown = try XCTUnwrap(second.sides[fixture.b2.id], "The side that was open beside its parent is open again")
        XCTAssertEqual(shown.id, side.id); XCTAssertTrue(shown.kept)
        await waitFor("The reopened side never read its page") { second.displays[side.id]?.messages.map(\.id) == ["side-q", "side-a"] }
        XCTAssertEqual(second.focusedSessionID, fixture.b2.id, "The parent had the keyboard, and has it again")
        XCTAssertTrue(second.hosts.isEmpty, "Reopening a saved side starts no helper")
        second.focusedSessionID = side.id
        try await quit(second)

        let third = await launch(fixture)
        XCTAssertEqual(third.sides[fixture.b2.id]?.id, side.id)
        XCTAssertEqual(third.focusedSessionID, side.id, "The side had the keyboard, and has it again")
        await waitFor("The focused side never read its page") { third.displays[side.id]?.draftReady == true }
    }

    /// Within a launch a chat's side comes back with it; after a relaunch it
    /// does too, whichever chat was open at quit. Closing the pane forgets
    /// it, and a side that has not been kept never replaces a kept one.
    @MainActor func testEveryChatReopensTheKeptSideItLastShowed() async throws {
        let (fixture, side) = try await sideFixture()
        let first = await launch(fixture)
        await first.select(fixture.b2.id)
        await first.showSide(side.id)
        await first.select(fixture.b1.id)
        XCTAssertEqual(first.sides[fixture.b2.id]?.id, side.id, "Within a launch the side stays with its chat")
        try await quit(first)

        let second = await launch(fixture)
        XCTAssertEqual(second.selectedID, fixture.b1.id)
        XCTAssertTrue(second.sides.isEmpty)
        await second.select(fixture.b2.id)
        XCTAssertEqual(second.sides[fixture.b2.id]?.id, side.id, "Opening the chat after a relaunch brings its side back beside it")
        XCTAssertEqual(second.focusedSessionID, fixture.b2.id, "Opening a chat puts the keyboard in the chat, as it does within a launch")
        await waitFor("The side never read its page") { second.displays[side.id]?.messages.map(\.id) == ["side-q", "side-a"] }
        // A new side that has not sent its first message covers it.
        second.openSide(parentID: fixture.b2.id)
        let unsent = try XCTUnwrap(second.sides[fixture.b2.id])
        XCTAssertTrue(unsent.pending)
        try await quit(second)

        let third = await launch(fixture)
        XCTAssertEqual(third.selectedID, fixture.b2.id)
        XCTAssertEqual(third.sides[fixture.b2.id]?.id, side.id, "The unsent side is gone, and the kept side it covered comes back")
        await waitFor("The side never finished loading") { third.displays[side.id]?.loading == false && third.displays[side.id]?.draftReady == true }
        third.closeSide(side.id)
        await waitFor("Closing the side never finished") { third.sides[fixture.b2.id] == nil }
        try await quit(third)

        let fourth = await launch(fixture)
        XCTAssertEqual(fourth.selectedID, fixture.b2.id)
        XCTAssertNil(fourth.sides[fixture.b2.id], "A closed side stays closed")
    }

    /// A side is remembered once it is kept, not before: until then it would
    /// not exist after a relaunch. Keeping it while it is shown (what
    /// `registerKeptSide` does to `sides`) is what writes it.
    @MainActor func testASideIsRememberedOnceItIsKept() async throws {
        let (fixture, side) = try await sideFixture()
        let first = await launch(fixture)
        await first.select(fixture.b2.id)
        let store = try XCTUnwrap(first.store)
        first.sides[fixture.b2.id] = SideRecord(id: side.id, parentID: fixture.b2.id, workspaceID: side.workspaceID,
                                                profileID: side.profileID, title: side.title)
        await first.flushSelection()
        let unkept = try await store.get(StoredSelection.self, kind: "selection", id: "main")
        XCTAssertEqual(unkept?.chatID, fixture.b2.id)
        XCTAssertNil(unkept?.shownSides?[fixture.b2.id], "A side that is not kept is not remembered")
        first.sides[fixture.b2.id]?.kept = true
        await first.flushSelection()
        let kept = try await store.get(StoredSelection.self, kind: "selection", id: "main")
        XCTAssertEqual(kept?.shownSides?[fixture.b2.id], side.id, "Keeping the shown side remembers it")
        try await quit(first)

        let second = await launch(fixture)
        XCTAssertEqual(second.sides[fixture.b2.id]?.id, side.id, "and the next launch reopens it beside its chat")
    }

    /// An older chat reopens where it was being read: the question the reader
    /// left it on is back near the top of the pane, not the bottom of the
    /// chat and not the question of its last turn, where a chat opened for
    /// the first time starts. The page places that question against the rows
    /// above it as they are measured when it lands; rows measured after that
    /// can still move it by their difference, which is the transcript's to
    /// hold, inside a launch as much as after one.
    @MainActor func testTheReopenedChatOpensWhereTheReaderLeftIt() async throws {
        let fixture = try await fixture()
        let first = await launch(fixture)
        await first.select(fixture.b2.id)
        let reading = try XCTUnwrap(first.displays[fixture.b2.id])
        // Where the page reports a reader who left the second question 40
        // points below the top of the pane.
        reading.scrollAnchor = TranscriptAnchor(id: "b2-q1", offset: 40, followsBottom: false)
        first.anchorChanged(reading)
        try await quit(first)

        var shown: (window: NSWindow, view: NSView)?
        let second = await launch(fixture) { model in shown = self.window(for: model) }
        let (window, view) = try XCTUnwrap(shown)
        XCTAssertEqual(second.selectedID, fixture.b2.id)
        await waitFor("The reopened chat never placed its page", drawing: window) {
            self.page(in: view)?.sessionID == fixture.b2.id && self.page(in: view)?.rowFrame(of: "b2-q1") != nil
        }
        // Let the page finish placing and measuring before reading it.
        for _ in 0..<60 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(15)) }
        let page = try XCTUnwrap(self.page(in: view))
        let viewport = try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeScrollView.self, in: view).first).contentView.bounds.height
        let question = try XCTUnwrap(page.rowFrame(of: "b2-q1")), last = try XCTUnwrap(page.rowFrame(of: "b2-q2"))
        XCTAssertGreaterThan(question.maxY - page.scrollY, 0, "The question the reader left is on screen")
        XCTAssertLessThan(question.minY - page.scrollY, viewport / 2, "in the top half of the pane, where it was left")
        XCTAssertGreaterThan(last.minY - 12 - page.scrollY, 200, "The page did not open at the last question")
        XCTAssertGreaterThan(page.distanceToBottom, 200, "nor at the bottom")
    }

    // MARK: A row the reader can see

    /// The reader collapsed the project and the topic the open chat is in.
    /// The relaunch opens them far enough to show its row, for this launch
    /// only: what the reader saved is still collapsed, and the reader's own
    /// click closes them again.
    @MainActor func testARowInACollapsedProjectAndTopicIsShownWithoutChangingWhatWasSaved() async throws {
        let topic = TopicRecord(id: "billing", workspaceID: "second-project", title: "Billing")
        let fixture = try await fixture(b2Topic: topic)
        let first = await launch(fixture)
        await first.select(fixture.b2.id)
        first.setTopicExpanded(topic.id, expanded: false)
        first.setProjectExpanded(fixture.second.id, expanded: false)
        XCTAssertFalse(first.sidebarChatOrder.contains(fixture.b2.id))
        try await quit(first)

        let second = await launch(fixture)
        XCTAssertEqual(second.selectedID, fixture.b2.id)
        XCTAssertTrue(second.projectIsExpanded(fixture.second.id), "The collapsed project is shown open")
        let project = try XCTUnwrap(second.sidebarProjects.first { $0.id == fixture.second.id }).record
        let group = second.topicGroupContents(in: project, topic: try XCTUnwrap(second.topics.first { $0.id == topic.id }),
                                              archived: second.projectShowsArchive(project.id), filter: "", sidebarWidth: 280, namesConnection: false)
        XCTAssertTrue(group.expanded, "and so is the collapsed topic")
        XCTAssertEqual(group.contents.rows.first { $0.chat.id == fixture.b2.id }?.state.selected, true, "with the reopened chat's row highlighted in it")
        XCTAssertTrue(second.sidebarChatOrder.contains(fixture.b2.id))
        XCTAssertTrue(second.projectIsExpanded(fixture.first.id), "Other projects are as they were")
        XCTAssertEqual(second.projectSidebarStates[fixture.second.id]?.expanded, false, "What the reader saved is unchanged")
        XCTAssertEqual(second.topics.first { $0.id == topic.id }?.expanded, false)

        // The reader's own click on the chevron closes it again, and writes nothing new.
        let revision = second.projectSidebarStates[fixture.second.id]?.revision
        second.setProjectExpanded(fixture.second.id, expanded: !second.projectIsExpanded(fixture.second.id))
        XCTAssertFalse(second.projectIsExpanded(fixture.second.id))
        XCTAssertFalse(second.sidebarChatOrder.contains(fixture.b2.id))
        XCTAssertEqual(second.projectSidebarStates[fixture.second.id]?.revision, revision)
        second.setProjectExpanded(fixture.second.id, expanded: true)
        let reopened = second.topicGroupContents(in: project, topic: try XCTUnwrap(second.topics.first { $0.id == topic.id }),
                                                 archived: false, filter: "", sidebarWidth: 280, namesConnection: false)
        second.setTopicExpanded(topic.id, expanded: !reopened.expanded)
        XCTAssertFalse(second.topicGroupContents(in: project, topic: try XCTUnwrap(second.topics.first { $0.id == topic.id }),
                                                 archived: false, filter: "", sidebarWidth: 280, namesConnection: false).expanded,
                       "Clicking the topic's chevron closes it")
        try await quit(second)

        let third = await launch(fixture)
        XCTAssertEqual(third.topics.first { $0.id == topic.id }?.expanded, false, "Nothing the launch opened was written")
        XCTAssertEqual(third.selectedID, fixture.b2.id)
    }

    // MARK: Nothing remembered

    /// A store with no chats ends its launch where the welcome or onboarding
    /// can show, never on the empty pane that stands in while launch reads.
    @MainActor func testALaunchWithNoChatsEndsWhereTheWelcomeCanShow() async throws {
        let fixture = try await fixture()
        let empty = fixture.root.appendingPathComponent("empty-state", isDirectory: true)
        let model = unrestoredModel(fixture, state: empty, launching: true)
        XCTAssertTrue(model.launching)
        await model.restore()
        XCTAssertTrue(model.chats.isEmpty)
        XCTAssertNil(model.selectedID)
        XCTAssertFalse(model.launching, "With nothing to reopen, the welcome or onboarding takes the pane")
    }

    /// No record — the first launch of this version, or a store that never
    /// had one — opens exactly what every launch opened before: the first
    /// chat that is neither archived nor a background task, with the sidebar
    /// as it was saved.
    @MainActor func testALaunchWithNothingRememberedOpensTheFirstChatAsBefore() async throws {
        var archived = ChatRecord(id: "archived", workspaceID: "second-project", title: "Old", path: nil, profileID: "launch-profile", sidebarOrder: 9_000)
        archived.archivedAt = Date()
        var task = ChatRecord(id: "task", workspaceID: "second-project", title: "Title job", path: nil, profileID: "launch-profile", sidebarOrder: 8_000)
        task.backgroundTask = "title"; task.sourceSessionID = "b2"
        let fixture = try await fixture([archived, task])
        let store = MetadataStore(url: fixture.state.appendingPathComponent("desktop.sqlite"))
        try await store.put(ProjectSidebarState(id: fixture.first.id, expanded: false, revision: 1), kind: "project-sidebar", id: fixture.first.id, revision: 1)
        await store.close()

        let model = await launch(fixture)
        XCTAssertEqual(model.chats.first { !$0.isArchived && !$0.isBackgroundTask }?.id, fixture.a.id)
        XCTAssertEqual(model.selectedID, fixture.a.id)
        XCTAssertEqual(model.focusedSessionID, fixture.a.id)
        XCTAssertEqual(model.selectedWorkspaceID, fixture.first.id)
        XCTAssertFalse(model.projectIsExpanded(fixture.first.id), "The sidebar is as it was saved")
        XCTAssertFalse(model.projectShowsArchive(fixture.second.id))
        XCTAssertTrue(model.sides.isEmpty)
        XCTAssertEqual(model.displays.count, 1)
        XCTAssertTrue(model.hosts.isEmpty)
    }
}

/// Holds the request archive's actor until the test lets it go, the way
/// `WorkspaceLoadingTests` holds the metadata store. Only the first `hold`
/// holds; it returns once the archive is held.
private final class ArchiveGate: @unchecked Sendable {
    fileprivate let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var claimed = false
    func hold(_ archive: PayloadArchive) async {
        guard claim() else { return }
        await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
            Task.detached { await archive.holdForLaunchTest(self) { held.resume() } }
        }
    }
    func release() { resume.signal() }
    private func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true; return true
    }
}

private extension PayloadArchive {
    func holdForLaunchTest(_ gate: ArchiveGate, held: @Sendable () -> Void) { held(); gate.resume.wait() }
}

/// Whether launch has finished, read by the test between frames.
@MainActor private final class LaunchFlag { var value = false }

extension LaunchSelectionTests {
    /// "Show background tasks" and the report page were forgotten at every
    /// launch: the toggle came back off and the window came back on Chats.
    @MainActor func testTheReportPageAndShownBackgroundTasksComeBackAfterARelaunch() async throws {
        let fixture = try await fixture()
        let first = await launch(fixture)
        await first.select(fixture.b2.id)
        first.showBackgroundSessions = true
        first.openReport()
        try await quit(first)

        let second = await launch(fixture)
        XCTAssertTrue(second.showBackgroundSessions, "The sidebar still shows background tasks")
        XCTAssertEqual(second.page, .report, "The window comes back on the report")
        XCTAssertEqual(second.selectedID, fixture.b2.id, "with the chat the reader had open underneath")
        second.closeReport(); second.showBackgroundSessions = false
        try await quit(second)

        let third = await launch(fixture)
        XCTAssertFalse(third.showBackgroundSessions); XCTAssertEqual(third.page, .chats, "Turning them off is remembered too")
        third.report.suspend()
    }
}
