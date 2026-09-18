import XCTest
import AppKit
import SwiftUI
@testable import PiApp

final class WorkspaceTests: XCTestCase {
    func testComposerMeasurementIgnoresNonEditingKeysAndRetainsSlowEdits() {
        var measurement = ComposerEditMeasurement()
        measurement.begin(event: 100, handler: 102); measurement.end()
        XCTAssertNil(measurement.draw(at: 20_000), "Navigation or candidate dismissal must not become a delayed edit sample")
        measurement.begin(event: 21_000, handler: 21_005); measurement.edited(); measurement.end()
        measurement.begin(event: 21_020, handler: 21_022); measurement.edited(); measurement.end()
        let delayed = measurement.draw(at: 41_000)
        XCTAssertEqual(delayed?.input, 20_000, "A genuinely delayed edit must remain measured, without trimming slow samples")
        XCTAssertEqual(delayed?.handler, 19_995)
        XCTAssertNil(measurement.draw(at: 41_005))
    }
    func testStalledCredentialWorkerTimesOutWithoutQueuingMoreBlockedOperations() async throws {
        let worker = KeychainWorker(timeout: .milliseconds(30)), gate = DispatchSemaphore(value: 0)
        let finished = expectation(description: "Security operation ended")
        do { let _: String = try await worker.perform { gate.wait(); finished.fulfill(); return "synthetic" }; XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Keychain did not respond")) }
        do { let _: String = try await worker.perform { XCTFail("A second blocked worker must not be queued"); return "unexpected" }; XCTFail("Expected capacity rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("earlier operation")) }
        gate.signal(); await fulfillment(of: [finished], timeout: 1)
    }
    @MainActor func testConnectionTestChatIsSavedOutsideAnyProject() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = MemoryVaultStorage(), model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: storage))
        try await model.reloadConfiguration()
        var profile = ProfileRecord(); profile.id = "profile"; profile.name = "Router"; profile.api = LiteLLMConfiguration.supportedAPI
        profile.baseUrl = "https://gw.example.com"; profile.modelId = "auto"
        try await model.saveProfile(profile, key: "sk-synthetic-test-key")
        XCTAssertNil(model.selectedWorkspaceID, "No project exists yet")
        let chat = try await model.createConnectionTestChat(profileID: model.profileChoice)
        XCTAssertEqual(chat.workspaceID, WorkspaceRecord.scratchID); XCTAssertEqual(chat.connectionTest, true)
        XCTAssertEqual(model.selectedID, chat.id)
        XCTAssertNil(model.selectedWorkspaceID, "A chat outside any project never becomes the target for new chats")
        XCTAssertEqual(model.sidebarProjects.map(\.name), ["No project"])
        XCTAssertEqual(model.workspace(for: WorkspaceRecord.scratchID)?.trusted, true)
        let stored = try await model.store?.loadChats() ?? []
        XCTAssertEqual(stored.map(\.id), [chat.id], "The connection test chat is persisted")
        model.shutdown(); await model.store?.close()
    }

    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PI_APP_SCRATCH_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent("native-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    func testSQLiteKeepsIndependentQueuedIntentsAndRejectsStaleDraftWrites() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        try await store.put(DraftRecord(id: "chat", text: "new 🌍"), kind: "draft", id: "chat", revision: 2)
        do { try await store.put(DraftRecord(id: "chat", text: "old"), kind: "draft", id: "chat", revision: 1); XCTFail("A rejected write must report that it did not save") }
        catch { XCTAssertEqual(error as? StoreError, .staleRevision) }
        let draft = try await store.get(DraftRecord.self, kind: "draft", id: "chat")
        XCTAssertEqual(draft?.text, "new 🌍")
        for id in ["first", "followup"] { try await store.put(CommandIntent(id: id, sessionID: "chat", turnID: id, text: id, state: "intent", epoch: "epoch"), kind: "pending:chat", id: id) }
        await store.close()
        let reopened = try MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        let intents = try await reopened.list(CommandIntent.self, kind: "pending:chat")
        XCTAssertEqual(Set(intents.map(\.id)), ["first", "followup"])
        await reopened.close()
    }
    func testWorkspaceLockTracksDescriptorOwnership() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("writer.lock")
        var first: WorkspaceLock? = try WorkspaceLock(url: url)
        XCTAssertNotNil(first); XCTAssertThrowsError(try WorkspaceLock(url: url))
        first = nil
        let next = try WorkspaceLock(url: url); withExtendedLifetime(next) { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
    }
    func testArchiveReaderFollowsParentBranchAndPreservesDamagedTail() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("history.jsonl")
        let records: [[String: WireValue]] = [
            ["type": .string("session"), "version": .number(3), "id": .string("s")],
            ["type": .string("message"), "id": .string("a"), "parentId": .null, "message": .object(["role": .string("user"), "content": .string("first")])],
            ["type": .string("message"), "id": .string("orphan"), "parentId": .string("a"), "message": .object(["role": .string("assistant"), "content": .string("old branch")])],
            ["type": .string("message"), "id": .string("b"), "parentId": .string("a"), "message": .object(["role": .string("assistant"), "content": .string("current 🌍")])]
        ]
        var bytes = Data(); for record in records { bytes.append(try JSONEncoder().encode(record)); bytes.append(10) }; bytes.append(Data("{\"unfinished\":".utf8))
        try bytes.write(to: path)
        let page = try await HistoryReader().read(path: path.path)
        XCTAssertEqual(page.messages.map(\.id), ["a", "b"]); XCTAssertEqual(page.messages.last?.text, "current 🌍")
        XCTAssertNotNil(page.notice); XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
    func testArchiveReaderReplaysEditBranchesBeforePagingAndSearching() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("edited.jsonl")
        var records: [[String: WireValue]] = [["type": .string("session"), "version": .number(3), "id": .string("s")]]
        var parent: String?
        func append(_ id: String, _ fields: [String: WireValue]) {
            var record = fields; record["id"] = .string(id); record["parentId"] = parent.map(WireValue.string) ?? .null
            records.append(record); parent = id
        }
        func message(_ id: String, _ role: String, _ text: String) { append(id, ["type": .string("message"), "message": .object(["role": .string(role), "content": .string(text)])]) }
        message("u1", "user", "first question"); message("a1", "assistant", "first answer")
        message("u2", "user", "replace me"); message("a2", "assistant", "abandoned reply")
        append("summary", ["type": .string("compaction"), "summary": .string("kept facts"), "tokensBefore": .number(12000), "nativeKeptIDs": .array([.string("u2"), .string("a2")])])
        append("edit1", ["type": .string("branch"), "fromMessageId": .string("u2"), "keptIds": .array([.string("summary")])])
        message("u3", "user", "replacement"); message("a3", "assistant", "another abandoned reply")
        append("edit2", ["type": .string("branch"), "fromMessageId": .string("u3"), "keptIds": .array([.string("summary")])])
        message("u4", "user", "final question")
        var bytes = Data(); for record in records { bytes.append(try JSONEncoder().encode(record)); bytes.append(10) }; try bytes.write(to: path)
        let reader = HistoryReader(), expected = ["u1", "a1", "summary", "edit1", "edit2", "u4"]
        let page = try await reader.read(path: path.path)
        XCTAssertNil(page.notice); XCTAssertEqual(page.messages.map(\.id), expected); XCTAssertEqual(page.total, expected.count)
        XCTAssertEqual(page.messages[2].kind, "compaction"); XCTAssertEqual(page.messages[2].detail, "Compacted 12000 tokens · 2 messages kept")
        XCTAssertEqual(page.messages[3].kind, "branch"); XCTAssertEqual(page.messages[4].kind, "branch")
        let fresh = try await HistoryReader().read(path: path.path)
        XCTAssertEqual(fresh.messages, page.messages, "A cold archive index must preserve the same visible branch")
        let anchored = try await reader.read(path: path.path, around: "summary")
        XCTAssertEqual(anchored.messages.map(\.id), Array(expected.dropFirst(2)))
        let earlier = try await reader.read(path: path.path, before: "edit1")
        XCTAssertEqual(earlier.messages.map(\.id), Array(expected.prefix(3)))
        let abandoned = try await reader.searchContent(path: path.path, query: "abandoned", start: 0)
        XCTAssertTrue(abandoned.hits.isEmpty)
        let markers = try await reader.searchContent(path: path.path, query: "Edited from here", start: 0)
        XCTAssertEqual(markers.hits.map(\.id), ["edit1", "edit2"])
        let copied = try await reader.copyContentPage(path: path.path, first: 4, last: 4, cursor: .init(index: 4, offset: 0), revision: markers.revision)
        XCTAssertTrue(copied.text.contains("Edited from here"))
        let original = try await reader.message(path: path.path, id: "a2", field: "text", offset: 0)
        XCTAssertEqual(original.0, "abandoned reply", "Explicit retained-message reads still expose the unchanged journal")
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
    @MainActor func testNativeComposerEnterShiftEnterAndMarkedText() throws {
        let editor = ComposerTextView(); editor.allowsUndo = true; editor.isRichText = false
        var sends = 0; editor.send = { sends += 1 }
        func enter(_ flags: NSEvent.ModifierFlags = []) -> NSEvent { NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)! }
        editor.string = "hello"; editor.keyDown(with: enter()); XCTAssertEqual(sends, 1)
        editor.setSelectedRange(NSRange(location: 5, length: 0)); editor.keyDown(with: enter(.shift)); XCTAssertEqual(sends, 1); XCTAssertTrue(editor.string.contains("\n"))
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText()); editor.keyDown(with: enter()); XCTAssertEqual(sends, 1)
    }

    @MainActor func testComposerModelRefreshDoesNotPublishTextOrCompletionsBackIntoViewUpdate() throws {
        var draft = "restored draft", writes = 0, completions = 0
        let composer = NativeComposer(text:.init(get:{ draft },set:{ draft = $0; writes += 1 }),send:{},completion:{ _ in completions += 1 })
        let coordinator = composer.makeCoordinator(), editor = ComposerTextView()
        editor.isRichText = false; editor.allowsUndo = true; editor.string = "previous draft"; editor.delegate = coordinator
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:150),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = editor
        defer { window.contentView = nil; window.close() }
        XCTAssertTrue(window.makeFirstResponder(editor))
        coordinator.applyModelText(draft,to:editor)
        XCTAssertEqual(editor.string,"restored draft"); XCTAssertEqual(writes,0); XCTAssertEqual(completions,0)
        XCTAssertTrue(editor.undoManager?.canUndo == true,"Model refresh retains the native undo operation")
        editor.setSelectedRange(NSRange(location:(editor.string as NSString).length,length:0))
        editor.insertText("!",replacementRange:editor.selectedRange())
        XCTAssertEqual(draft,"restored draft!"); XCTAssertEqual(writes,1); XCTAssertEqual(completions,1)
        editor.setMarkedText("に",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        let marked = editor.string
        coordinator.applyModelText("another model update",to:editor)
        XCTAssertEqual(editor.string,marked,"A programmatic refresh cannot replace an active IME composition")
    }

    @MainActor func testComposerFocusPublicationIsDeferredAndRejectsSupersededResponder() async throws {
        var focused = 0
        let composer = NativeComposer(text:.constant(""),send:{},focused:{ focused += 1 })
        let coordinator = composer.makeCoordinator(), editor = ComposerTextView(), other = ComposerTextView()
        let container = NSView(frame:NSRect(x:0,y:0,width:400,height:150))
        editor.frame = NSRect(x:0,y:0,width:200,height:150); other.frame = NSRect(x:200,y:0,width:200,height:150)
        container.addSubview(editor); container.addSubview(other)
        let window = NSWindow(contentRect:container.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = container
        defer { window.contentView = nil; window.close() }
        XCTAssertTrue(window.makeFirstResponder(editor))
        coordinator.focusChanged(editor); XCTAssertEqual(focused,0,"Focus cannot publish synchronously during native view attachment")
        XCTAssertTrue(window.makeFirstResponder(other))
        try await Task.sleep(for:.milliseconds(20)); XCTAssertEqual(focused,0,"An older native focus event cannot steal the newly selected session")
        XCTAssertTrue(window.makeFirstResponder(editor)); coordinator.focusChanged(editor)
        XCTAssertEqual(focused,0)
        try await Task.sleep(for:.milliseconds(20)); XCTAssertEqual(focused,1)
        coordinator.focusChanged(editor); editor.isHidden = true
        try await Task.sleep(for:.milliseconds(20)); XCTAssertEqual(focused,1,"A report-hidden composer cannot publish its stale focus")
    }

    // MARK: - Multi-folder workspaces

    @MainActor func testNewProjectPrimarySelectionReadsLiveDraftAndUpdatesAtomically() throws {
        typealias Draft = WorkspaceManagerView.NewWorkspaceDraft
        var state: Draft? = Draft(), writes = 0
        let source = Binding<Draft?>(get: { state }, set: { state = $0; writes += 1 })
        let draft = try XCTUnwrap(Draft.editing(source))

        draft.wrappedValue.selectPrimary("/fixture/primary")
        XCTAssertEqual(state?.primary, "/fixture/primary")
        XCTAssertEqual(writes, 1, "Choosing a folder must publish one complete draft")
        XCTAssertEqual(draft.wrappedValue.primary, state?.primary, "The pane must immediately read its chosen folder")

        draft.wrappedValue.extras += ["/fixture/extra", "/fixture/keep"]
        draft.wrappedValue.selectPrimary("/fixture/extra")
        XCTAssertEqual(state?.primary, "/fixture/extra", "Changing primary must not restore the old value")
        XCTAssertEqual(state?.extras, ["/fixture/keep"], "Promoting one extra must preserve the other folders")
        draft.wrappedValue.extras.removeAll()
        XCTAssertEqual(state?.primary, "/fixture/extra", "Later form edits must retain the current primary")
    }

    @MainActor func testCancelledNewProjectCannotBeReopenedByAnOutgoingPane() throws {
        typealias Draft = WorkspaceManagerView.NewWorkspaceDraft
        var state: Draft? = Draft()
        let source = Binding<Draft?>(get: { state }, set: { state = $0 })
        let outgoing = try XCTUnwrap(Draft.editing(source))
        state = nil
        outgoing.wrappedValue.selectPrimary("/fixture/late-folder")
        XCTAssertNil(state)
        XCTAssertNil(Draft.editing(source))
        state = Draft()
        let fresh = try XCTUnwrap(Draft.editing(source))
        fresh.wrappedValue.selectPrimary("/fixture/new-folder")
        XCTAssertEqual(state?.primary, "/fixture/new-folder", "New Project must work again after cancellation")
    }

    @MainActor func testCreateSecondProjectFromFolderSelectionPreservesFirstProject() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let firstFolder = root.appendingPathComponent("first"), secondFolder = root.appendingPathComponent("second")
        for folder in [firstFolder, secondFolder] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let first = WorkspaceRecord(id: "first", path: firstFolder.path, trusted: true)
        var config = VaultConfiguration(); config.workspaces = [first]; config.automaticUpdateChecks = false
        let storage = MemoryVaultStorage(try JSONEncoder().encode(config))
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: storage))
        defer { model.shutdown() }
        try await model.reloadConfiguration()

        typealias Draft = WorkspaceManagerView.NewWorkspaceDraft
        var state: Draft? = Draft()
        let draft = try XCTUnwrap(Draft.editing(Binding(get: { state }, set: { state = $0 })))
        draft.wrappedValue.selectPrimary(secondFolder.path)
        let primary = try XCTUnwrap(draft.wrappedValue.primary)
        let second = try await model.createWorkspace(primary: primary, extras: draft.wrappedValue.extras)
        XCTAssertEqual(model.workspaces, [first, second])
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(model.selectedWorkspaceID, second.id)
        let saved = try await ConfigurationVault(storage: storage).load()
        XCTAssertEqual(saved.workspaces, [first, second], "Both projects must survive a fresh vault read")
        await model.store?.close()
    }

    func testWorkspaceRecordDecodesLegacyRecordsWithoutExtraFolders() throws {
        let legacy = try JSONDecoder().decode(WorkspaceRecord.self, from: Data(#"{"id":"w","path":"/tmp/primary","trusted":true}"#.utf8))
        XCTAssertEqual(legacy.paths, []); XCTAssertEqual(legacy.roots, ["/tmp/primary"]); XCTAssertTrue(legacy.trusted)
        let record = WorkspaceRecord(id: "multi", path: "/tmp/primary", trusted: true, paths: ["/tmp/second", "/tmp/third"])
        let restored = try JSONDecoder().decode(WorkspaceRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored, record); XCTAssertEqual(restored.roots, ["/tmp/primary", "/tmp/second", "/tmp/third"])
        var config = VaultConfiguration(); config.workspaces = [legacy, record]
        let vault = try ConfigurationVault.decode(JSONEncoder().encode(config))
        XCTAssertEqual(vault.workspaces.map(\.roots.count), [1, 3], "Legacy and multi-folder records must coexist in one vault")
    }

    @MainActor func testAddAndRemoveFoldersUpdateTheVaultAndRefuseActiveWork() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("primary"), second = root.appendingPathComponent("second"), third = root.appendingPathComponent("third")
        for folder in [primary, second, third] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var config = VaultConfiguration(); config.automaticUpdateChecks = false
        config.workspaces = [WorkspaceRecord(id: "w", path: primary.path, trusted: true)]
        let storage = MemoryVaultStorage(try JSONEncoder().encode(config)), vault = ConfigurationVault(storage: storage)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        try await model.addFolders([second.path, third.path], to: "w")
        XCTAssertEqual(model.workspaces[0].paths, [second.path, third.path])
        let saved = try await ConfigurationVault(storage: storage).load()
        XCTAssertEqual(saved.workspaces[0].roots, [primary.path, second.path, third.path], "Folder additions must be durable in the vault")
        do { try await model.addFolders([second.path, primary.path], to: "w"); XCTFail("Duplicate folders must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("already part")) }
        do { try await model.addFolders([root.appendingPathComponent("missing").path], to: "w"); XCTFail("Missing folders must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not an existing folder")) }
        do { try await model.removeFolder(primary.path, from: "w"); XCTFail("The primary folder must stay") }
        catch { XCTAssertTrue(error.localizedDescription.contains("primary folder")) }
        try await model.removeFolder(second.path, from: "w")
        XCTAssertEqual(model.workspaces[0].paths, [third.path])
        let afterRemoval = try await ConfigurationVault(storage: storage).load()
        XCTAssertEqual(afterRemoval.workspaces[0].paths, [third.path])
        do { try await model.removeFolder(second.path, from: "w"); XCTFail("Unknown folders must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not part of this project")) }
        // Active work blocks folder changes until the workspace is idle.
        let chat = ChatRecord(id: "chat", workspaceID: "w", title: "Running", path: nil, profileID: "p")
        model.chats = [chat]; let display = SessionDisplay(id: "chat"); display.state = "running"; model.displays["chat"] = display
        XCTAssertTrue(model.workspaceHasActiveWork("w"))
        do { try await model.addFolders([second.path], to: "w"); XCTFail("Active work must refuse folder changes") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Stop this project's work")) }
        do { try await model.removeWorkspace("w"); XCTFail("A workspace with chats must not be removed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("chat")) }
        XCTAssertEqual(model.workspaces[0].paths, [third.path])
        display.state = "idle"
        XCTAssertFalse(model.workspaceHasActiveWork("w"))
        do { try await model.removeWorkspace("w"); XCTFail("A workspace with chats must not be removed even when idle") } catch { }
        model.chats = []
        try await model.removeWorkspace("w")
        XCTAssertTrue(model.workspaces.isEmpty); XCTAssertNil(model.selectedWorkspaceID)
        let afterRemoveWorkspace = try await ConfigurationVault(storage: storage).load()
        XCTAssertTrue(afterRemoveWorkspace.workspaces.isEmpty)
        await model.store?.close()
    }

    @MainActor func testCreateWorkspaceStoresPrimaryAndDeduplicatedExtrasWithinTheRootLimit() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("primary"), extra = root.appendingPathComponent("extra")
        for folder in [primary, extra] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let storage = MemoryVaultStorage(), model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: storage))
        defer { model.shutdown() }
        let created = try await model.createWorkspace(primary: primary.path, extras: [extra.path, primary.path, extra.path])
        XCTAssertEqual(created.roots, [primary.path, extra.path]); XCTAssertTrue(created.trusted)
        XCTAssertEqual(model.selectedWorkspaceID, created.id); XCTAssertEqual(model.chatCount(workspaceID: created.id), 0)
        let again = try await model.createWorkspace(primary: primary.path)
        XCTAssertEqual(again.id, created.id, "Re-creating the same primary folder keeps the workspace identity")
        XCTAssertEqual(model.workspaces.count, 1); XCTAssertEqual(model.workspaces[0].paths, [])
        var many: [String] = []
        for index in 0..<WorkspaceModel.maximumRoots { let folder = root.appendingPathComponent("many-\(index)"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); many.append(folder.path) }
        do { try await model.addFolders(many, to: created.id); XCTFail("The root limit must be enforced") }
        catch { XCTAssertTrue(error.localizedDescription.contains("up to \(WorkspaceModel.maximumRoots)")) }
        try await model.addFolders(Array(many.prefix(WorkspaceModel.maximumRoots - 1)), to: created.id)
        XCTAssertEqual(model.workspaces[0].roots.count, WorkspaceModel.maximumRoots)
        let persisted = try await ConfigurationVault(storage: storage).load()
        XCTAssertEqual(persisted.workspaces[0].roots.count, WorkspaceModel.maximumRoots)
        await model.store?.close()
    }
    @MainActor func testFolderChangesBlockNewWorkUntilTheVaultWriteCompletes() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("primary"), extra = root.appendingPathComponent("extra")
        for folder in [primary, extra] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var config = VaultConfiguration(); config.workspaces = [WorkspaceRecord(id: "w", path: primary.path, trusted: true)]
        var profile = ProfileRecord(); profile.baseUrl = "https://fixture.invalid"; profile.modelId = "fixture"
        config.profiles = [VaultProfile(profile: profile, apiKey: "fixture-key", headers: [:])]
        let started = expectation(description: "Folder update entered the vault write"), gate = DispatchSemaphore(value: 0)
        let storage = DelayedWorkspaceVaultStorage(data: try JSONEncoder().encode(config), started: started, gate: gate)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: storage))
        defer { gate.signal(); model.shutdown() }
        try await model.reloadConfiguration()
        let chat = ChatRecord(id: "chat", workspaceID: "w", title: "t", path: nil, profileID: profile.id)
        model.chats = [chat]; model.selectedWorkspaceID = "w"; model.profileChoice = profile.id
        let update = Task { try await model.addFolders([extra.path], to: "w") }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.workspaceHasActiveWork("w")); XCTAssertTrue(model.hasActiveWork)
        do { _ = try await model.open(chat); XCTFail("New work must not race the pending folder update") }
        catch { XCTAssertTrue(error.localizedDescription.contains("folder changes")) }
        model.newChat(); XCTAssertEqual(model.chats.count, 1, "A pending removal/reconfiguration cannot gain an orphaned chat")
        do { try await model.addFolders([extra.path], to: "w"); XCTFail("Folder mutations must serialize per workspace") } catch { }
        XCTAssertTrue(model.hosts.isEmpty, "Rejected new work must not launch a helper or load credentials")
        gate.signal(); try await update.value
        XCTAssertFalse(model.workspaceHasActiveWork("w")); XCTAssertTrue(model.workspaceChangesInFlight.isEmpty)
        XCTAssertEqual(model.workspaces[0].roots, [primary.path, extra.path])
        await model.store?.close()
    }
}

private final class DelayedWorkspaceVaultStorage: VaultStorage, @unchecked Sendable {
    let storage: MemoryVaultStorage
    let started: XCTestExpectation
    let gate: DispatchSemaphore
    init(data: Data, started: XCTestExpectation, gate: DispatchSemaphore) { storage = MemoryVaultStorage(data); self.started = started; self.gate = gate }
    func read() throws -> Data? { try storage.read() }
    func replace(expected: Data?, with replacement: Data) throws {
        started.fulfill()
        guard gate.wait(timeout: .now() + 5) == .success else { throw VaultError.busy }
        try storage.replace(expected: expected, with: replacement)
    }
}
