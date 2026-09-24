import XCTest
import SwiftUI
@testable import PiApp

final class WorkspaceFollowupTests: XCTestCase {
    private func scratch() throws -> URL {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("workspace-followup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }
    @MainActor private func waitFor(_ message: String = "Conversation view did not settle", file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(message, file: file, line: line)
    }

    @MainActor func testScratchChatRendersComposerAndPreparesToolFreeRequestWithoutProject() async throws {
        let root = try scratch()
        var profile = ProfileRecord(); profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "preview-only"
        var configuration = VaultConfiguration()
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-preview-key")]
        configuration.resources[WorkspaceRecord.scratchID] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)])
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("app-state"), vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { model.shutdown(); window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root) }
        try await model.reloadConfiguration()
        let chat = try await model.createConnectionTestChat(profileID: profile.id)
        let display = try XCTUnwrap(model.displays[chat.id]); display.draft = "Connection follow-up"
        let hosted = NSHostingView(rootView: ConversationPane(model: model, session: display, chat: chat, paneWidth: 900))
        window.contentView = hosted; window.orderFront(nil)
        try await waitFor("The scratch chat must mount its native composer") {
            hosted.layoutSubtreeIfNeeded()
            return self.descendants(ComposerTextView.self, in: hosted).count == 1
        }
        XCTAssertEqual(descendants(ComposerTextView.self, in: hosted).first?.string, display.draft)
        XCTAssertTrue(model.workspaces.isEmpty); XCTAssertNil(model.selectedWorkspaceID)

        let preview = try await model.preparedContext(chat.id)
        let revision = try XCTUnwrap(preview["revision"]?.string)
        let tools = try await model.readPreparedContext(chat.id, revision: revision, section: "tools")
        let body = try JSONDecoder().decode(WireValue.self, from: Data(try XCTUnwrap(tools["text"]?.string).utf8))
        XCTAssertEqual(body, .array([]), "The scratch host must not advertise filesystem or MCP tools")
        XCTAssertEqual(preview["dispatched"]?.bool, false)
        let attempts = try await model.traces.list(sessionID: chat.id); XCTAssertTrue(attempts.isEmpty)

        var unavailable = chat; unavailable.workspaceID = "removed-project"
        hosted.rootView = ConversationPane(model: model, session: display, chat: unavailable, paneWidth: 900)
        try await waitFor("An unavailable project must remove the native composer") {
            hosted.layoutSubtreeIfNeeded()
            return self.descendants(ComposerTextView.self, in: hosted).isEmpty
        }
        XCTAssertEqual(display.draft, "Connection follow-up", "Unavailable projects remain history-only without losing the draft")
        hosted.rootView = ConversationPane(model: model, session: display, chat: chat, paneWidth: 900)
        try await waitFor("Returning to the scratch chat must restore its native composer and draft") {
            hosted.layoutSubtreeIfNeeded()
            return self.descendants(ComposerTextView.self, in: hosted).first?.string == "Connection follow-up"
        }
        try await model.hosts[WorkspaceRecord.scratchID]?.shutdownAndWait()
        try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testConnectionTestSideActionsPreserveDraftAndCreateNoChild() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let test = ChatRecord(id: "test", workspaceID: "project", title: "Connection test", path: nil, profileID: "p", toolMode: "read-only", connectionTest: true)
        let scratch = ChatRecord(id: "scratch-child", workspaceID: WorkspaceRecord.scratchID, title: "Retained scratch chat", path: nil, profileID: "p", toolMode: "read-only")
        let regular = ChatRecord(id: "regular", workspaceID: "project", title: "Regular", path: nil, profileID: "p")
        model.chats = [test, scratch, regular]
        XCTAssertTrue(model.canOpenSide(regular.id))
        for chat in [test, scratch] {
            let display = SessionDisplay(id: chat.id); display.draft = "/side keep this question"; display.directCommand = true
            model.displays[chat.id] = display
            XCTAssertFalse(model.canOpenSide(chat.id))
            model.openSide(parentID: chat.id)
            XCTAssertNotNil(model.error); XCTAssertTrue(model.sides.isEmpty)
            XCTAssertTrue(model.resolveLeadingCommand(display, steer: false))
            XCTAssertEqual(display.draft, "/side keep this question")
            XCTAssertTrue(display.directCommand); XCTAssertFalse(display.loading)
            model.enableEditing(chat.id)
            XCTAssertEqual(model.record(chat.id)?.toolMode, "read-only")
        }
        let intents = try await model.store?.list(SideKeepIntent.self, kind: "side-keep") ?? []
        XCTAssertTrue(intents.isEmpty); XCTAssertTrue(model.hosts.isEmpty)
        await model.store?.close()
    }

    @MainActor func testConnectionTestSubmissionKeepsItsTargetAfterSelectionChanges() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        try await model.reloadConfiguration()
        var profile = ProfileRecord(); profile.id = "synthetic-profile"; profile.api = LiteLLMConfiguration.supportedAPI
        model.profiles = [profile]
        let test = try await model.createConnectionTestChat(profileID: profile.id)
        let testDisplay = try XCTUnwrap(model.displays[test.id])
        let other = ChatRecord(id: "other", workspaceID: "project", title: "Other chat", path: nil, profileID: profile.id)
        let otherDisplay = SessionDisplay(id: other.id); otherDisplay.draft = "Keep this unrelated draft"
        model.chats.append(other); model.displays[other.id] = otherDisplay
        model.selectedID = other.id; model.focusedSessionID = other.id; model.selected = otherDisplay
        // A missing synthetic profile ends the submission before a helper or
        // network request, while exercising the actual target capture in send.
        model.profiles = []
        model.submitConnectionTestChat(test.id)
        XCTAssertTrue(testDisplay.loading); XCTAssertFalse(otherDisplay.loading)
        XCTAssertEqual(testDisplay.draft, "Reply with OK to confirm this API connection.")
        XCTAssertEqual(otherDisplay.draft, "Keep this unrelated draft")
        XCTAssertEqual(model.selectedID, other.id); XCTAssertEqual(model.focusedSessionID, other.id)
        try await waitFor { !testDisplay.loading }
        XCTAssertTrue(model.hosts.isEmpty)
        let saved = try await model.store?.get(DraftRecord.self, kind: "draft", id: test.id)
        XCTAssertEqual(saved?.text, testDisplay.draft)
        XCTAssertNotNil(testDisplay.sendFailure)
        XCTAssertFalse(testDisplay.uncertain, "A locally rejected send never reached the helper")
        let pending = try await model.store?.list(CommandIntent.self, kind: "pending:\(test.id)") ?? []
        XCTAssertTrue(pending.isEmpty)
        let unrelated = try await model.store?.get(DraftRecord.self, kind: "draft", id: other.id)
        XCTAssertNil(unrelated)
        await model.store?.close()
    }

    @MainActor func testMissingConnectionPreservesTheEditedMessageAndDisplacedDraft() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let chat = ChatRecord(id: "edit", workspaceID: "project", title: "Retained chat", path: nil, profileID: "missing")
        let display = SessionDisplay(id: chat.id)
        display.draft = "Edited question"; display.editingMessageID = "earlier-user-message"
        display.draftBeforeEdit = DraftRecord(id: chat.id, text: "Unsent original draft")
        model.chats = [chat]; model.displays[chat.id] = display

        model.sendEdit(sessionID: chat.id)
        try await waitFor { !display.loading }
        let saved = try await model.store?.get(DraftRecord.self, kind: "draft", id: chat.id)
        XCTAssertEqual(saved?.text, "Edited question")
        XCTAssertEqual(saved?.edit?.messageID, "earlier-user-message")
        XCTAssertEqual(saved?.edit?.originalText, "Unsent original draft")
        XCTAssertTrue(display.notice.contains("connection is unavailable"))
        XCTAssertFalse(display.uncertain); XCTAssertTrue(model.hosts.isEmpty)
        let pending = try await model.store?.list(CommandIntent.self, kind: "pending:\(chat.id)") ?? []
        XCTAssertTrue(pending.isEmpty)
        await model.store?.close()
    }

    @MainActor func testArchivedOpenSideDeletionKeepsPaneRecordDraftAndJournal() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        let path = root.appendingPathComponent("child.jsonl"), bytes = Data("retained child history\n".utf8)
        try bytes.write(to: path)
        let parent = ChatRecord(id: "parent", workspaceID: "w", title: "Parent", path: nil, profileID: "p")
        var child = ChatRecord(id: "child", workspaceID: "w", title: "Side", path: path.path, profileID: "p", toolMode: "read-only", parentSessionID: parent.id)
        child.archivedAt = Date()
        let display = SessionDisplay(id: child.id); display.draft = "Unsent child draft"
        model.chats = [parent, child]; model.displays[child.id] = display
        model.sides[parent.id] = SideRecord(id: child.id, parentID: parent.id, workspaceID: "w", profileID: "p", title: child.title, kept: true)
        model.selectedID = parent.id; model.focusedSessionID = child.id
        try await model.store?.put(child, kind: "chat", id: child.id)
        model.deleteChat(child.id)
        XCTAssertEqual(model.error, "Close this side panel before deleting its chat.")
        XCTAssertEqual(model.sides[parent.id]?.id, child.id); XCTAssertTrue(model.displays[child.id] === display)
        XCTAssertEqual(model.record(child.id), child); XCTAssertEqual(display.draft, "Unsent child draft")
        XCTAssertEqual(model.selectedID, parent.id); XCTAssertEqual(model.focusedSessionID, child.id)
        let stored = try await model.store?.get(ChatRecord.self, kind: "chat", id: child.id)
        XCTAssertEqual(stored, child); XCTAssertEqual(try Data(contentsOf: path), bytes)
        await model.store?.close()
    }

    /// A compaction is one summary request: its progress names the phase,
    /// never a chunk or an invented percent.
    @MainActor func testCompactionProgressNamesThePhaseWithoutChunksOrInventedPercent() {
        let display=SessionDisplay(id:"progress")
        display.observeCompaction(["runStatus":.string("compacting"),"compaction":.object(["phase":.string("planning")])])
        XCTAssertEqual(display.compactionProgress,"Preparing complete tool history")
        display.observeCompaction(["runStatus":.string("compacting"),"compaction":.object(["phase":.string("summarizing"),"chunk":.number(2)])])
        XCTAssertEqual(display.compactionProgress,"Summarizing earlier work","An older helper's chunk is not shown")
        display.observeCompaction(["runStatus":.string("compacting"),"compaction":.object(["phase":.string("retrying")])])
        XCTAssertEqual(display.compactionProgress,"Retrying summary request")
        display.observeCompaction(["runStatus":.string("compacting"),"compaction":.object(["phase":.string("merging")])])
        XCTAssertNil(display.compactionProgress,"No helper merges summaries now")
        display.observeCompaction(["runStatus":.string("failed"),"compaction":.object(["phase":.string("failed")])])
        XCTAssertNil(display.compactionProgress);XCTAssertNil(display.compactionNotice)
    }

    @MainActor func testCompactionNoticesRequireNewSuccessAndIgnoreFailureCancellationAndOldHistory() {
        func snapshot(_ id: String?, detail: String = "Compacted 12000 tokens · 2 messages kept", run: String = "idle") -> [String: WireValue] {
            ["runStatus": .string(run), "latestSuccessfulCompaction": id.map { .object(["id": .string($0), "detail": .string(detail)]) } ?? .null]
        }
        let display = SessionDisplay(id: "chat")
        display.observeCompaction(snapshot("historical"), baseline: true)
        XCTAssertNil(display.compactionNotice, "Opening existing history is not a new compaction")
        display.observeCompaction(snapshot("historical", run: "compacting"))
        display.observeCompaction(snapshot("historical", run: "failed"))
        XCTAssertNil(display.compactionNotice, "Leaving compacting after failure cannot reuse a historical summary")
        display.observeCompaction(snapshot("historical", run: "compacting"))
        display.observeCompaction(snapshot("historical", run: "cancelled"))
        XCTAssertNil(display.compactionNotice)

        display.browsingHistory = true
        display.messages = [TranscriptMessage(id: "old-row", role: "system", text: "Old summary", kind: "compaction", detail: "Old statistics")]
        display.observeCompaction(snapshot("new", detail: "Current statistics"))
        XCTAssertEqual(display.compactionNotice, "Current statistics", "A fast or background compaction needs no observed running state or current transcript rows")
        display.compactionNotice = nil
        display.observeCompaction(snapshot("new", detail: "Current statistics"))
        XCTAssertNil(display.compactionNotice, "Repeated status cannot resurrect a dismissed or sent notice")
        display.observeCompaction(snapshot("newer", detail: "Newer statistics"))
        XCTAssertEqual(display.compactionNotice, "Newer statistics")
        display.observeCompaction(snapshot(nil))
        XCTAssertNil(display.compactionNotice, "A summary removed from active context must not retain its notice")
    }
}
