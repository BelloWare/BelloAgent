import XCTest
import Combine
@testable import PiApp

/// The draft marker (0.1.122): a chat whose composer holds something unsent
/// shows a pencil on its sidebar row. It follows the saved draft (the store's
/// committed writes), never the keystrokes, and comes back after a relaunch.
final class DraftMarkTests: XCTestCase {
    func testWhatCountsAsUnsentWork() {
        func draft(_ text: String, images: Int = 0, skills: Int = 0) -> DraftRecord {
            DraftRecord(id: "c", text: text,
                        attachments: images == 0 ? nil : (0..<images).map { AttachmentRecord(id: "i\($0)", path: "/tmp/i.png", sha256: "x", bytes: 1, mimeType: "image/png") },
                        skills: skills == 0 ? nil : (0..<skills).map { _ in SkillChip(id: "s", name: "review", path: "/s/SKILL.md", contentHash: "c", metadataHash: "m") })
        }
        XCTAssertTrue(draft("Still thinking").holdsUnsentDraft)
        XCTAssertFalse(draft("  \n ").holdsUnsentDraft, "spaces are nothing")
        XCTAssertTrue(draft("", images: 1).holdsUnsentDraft, "an image alone is a draft")
        XCTAssertTrue(draft("", skills: 1).holdsUnsentDraft, "a skill alone is a draft")
        // An edit of an earlier message set the reader's own draft aside.
        var editing = draft("")
        editing.edit = MessageEditDraft(messageID: "m", originalText: "the draft set aside", originalAttachments: nil, originalSkills: nil)
        XCTAssertTrue(editing.holdsUnsentDraft)
        editing.edit?.originalText = ""
        XCTAssertFalse(editing.holdsUnsentDraft)
        // A queued message being rewritten: only once the rewrite differs.
        var queued = draft("")
        queued.queuedEdit = QueuedEditDraft(editID: "e", turnID: "t", rewrite: "Short one", original: "Short one", pending: nil)
        XCTAssertFalse(queued.holdsUnsentDraft, "an edit opened and not changed is not a draft")
        queued.queuedEdit?.rewrite = "Short one, rewritten"
        XCTAssertTrue(queued.holdsUnsentDraft)
        queued.queuedEdit?.beginOnly = true
        XCTAssertFalse(queued.holdsUnsentDraft, "a Begin the helper has not answered is not a draft")
    }

    /// The store tells of each committed draft write, in order; a write
    /// rolled back is not told.
    func testTheStoreTellsOfCommittedDraftWritesInOrder() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("draft-events-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        try await store.open()
        let events = Events()
        store.draftWrites.observe { id, holds, sequence in events.append(id, holds, sequence) }
        try await store.put(DraftRecord(id: "a", text: "Hello"), kind: "draft", id: "a")
        try await store.put(DraftRecord(id: "a", text: " "), kind: "draft", id: "a")
        try await store.put(DraftRecord(id: "b", text: "Other"), kind: "draft", id: "b")
        try await store.remove(kind: "draft", id: "b")
        // Sending: the submission and the emptied draft commit together.
        try await store.put(DraftRecord(id: "c", text: "About to send"), kind: "draft", id: "c")
        let intent = CommandIntent(id: "k", sessionID: "c", turnID: "t", text: "About to send", state: "intent", epoch: nil, attachments: nil, skills: nil)
        try await store.recordSubmission(intent, draft: DraftRecord(id: "c", text: ""))
        XCTAssertEqual(events.list.map { "\($0.0):\($0.1)" }, ["a:true", "a:false", "b:true", "b:false", "c:true", "c:false"])
        XCTAssertEqual(events.list.map(\.2), Array(1...6), "in the order the store made them")
        // A write rolled back is not told: a handoff whose provenance is too large to keep.
        let handoff = ChatRecord(id: "h", workspaceID: "w", title: "Handoff", path: nil, profileID: "p")
        do {
            try await store.commitPortableHandoff(handoff, draft: DraftRecord(id: "h", text: "carried over"), provenance: .string(String(repeating: "x", count: 600_000)))
            XCTFail("an oversized record was kept")
        } catch {}
        XCTAssertEqual(events.list.count, 6, "the rolled-back draft write is not told")
        let marks = try await store.draftMarks()
        XCTAssertEqual(marks.ids, [], "nothing holds a draft now"); XCTAssertEqual(marks.sequence, 6)
        try await store.put(DraftRecord(id: "a", text: "Back"), kind: "draft", id: "a")
        let after = try await store.draftMarks()
        XCTAssertEqual(after.ids, ["a"]); XCTAssertEqual(after.sequence, 7)
        await store.close()
    }

    @MainActor private func model(root: URL) async throws -> (WorkspaceModel, SessionDisplay) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        _ = await model.prepareStore()
        let chats = [ChatRecord(id: "c", workspaceID: "w", title: "Refund edge cases", path: nil, profileID: "p"),
                     ChatRecord(id: "o", workspaceID: "w", title: "Other", path: nil, profileID: "p")]
        model.chats = chats
        for chat in chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        let view = SessionDisplay(id: "c"); view.selectionMetadataLoaded = true; model.displays["c"] = view
        return (model, view)
    }
    @MainActor private func waitFor(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail(what); throw CancellationError()
    }

    /// Typing marks the chat once, behind the typing: the sidebar is not
    /// told per keystroke. Emptying the composer takes the mark away.
    @MainActor func testTypingMarksTheChatOnceAndEmptyingItClearsTheMark() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("draft-mark-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, view) = try await model(root: root)
        defer { model.shutdown() }
        var publications = 0
        let watch = model.$draftChatIDs.dropFirst().sink { _ in publications += 1 }
        defer { watch.cancel() }
        for text in ["R", "Re", "Ref", "Refu", "Refun", "Refund", "Refund the", "Refund the order"] {
            view.draft = text; model.draftChanged(view)
        }
        try await waitFor("the draft was never marked") { model.showsDraftMark("c") }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(publications, 1, "eight keystrokes, one change to the sidebar")
        view.draft = "Refund the order now"; model.draftChanged(view)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(publications, 1, "a draft that stays a draft changes nothing")
        view.draft = "   "; model.draftChanged(view)
        try await waitFor("the emptied draft kept its mark") { !model.showsDraftMark("c") }
        XCTAssertEqual(publications, 2)
        // The row says it.
        view.draft = "Back again"; model.draftChanged(view)
        try await waitFor("the draft was never marked again") { model.showsDraftMark("c") }
        let chat = try XCTUnwrap(model.record("c"))
        let content = SidebarChatRowView.content(model: model, chat: chat, state: SidebarChatRowState(hasDraft: true), display: nil, retained: nil)
        XCTAssertEqual(content.accessibilityLabel, "Refund edge cases, has a draft")
        let row = SidebarChatRowView(model: model, chat: chat, state: SidebarChatRowState(hasDraft: true), projectID: "w", glide: PiKit.SelectionGlide())
        XCTAssertFalse(row.body.draftMark.isHidden); XCTAssertEqual(row.body.draftMark.accessibilityLabel(), "Has a draft")
        row.apply(chat: chat, state: SidebarChatRowState(), projectID: "w")
        XCTAssertTrue(row.body.draftMark.isHidden)
    }

    /// Drafts are kept, so the marks come back after a relaunch; a write
    /// made while launch reads them is newer and stands.
    @MainActor func testTheMarksComeBackAfterARelaunch() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("draft-relaunch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (first, view) = try await model(root: root)
        view.draft = "Unsent"; first.draftChanged(view)
        try await first.flushDrafts()
        first.shutdown(); try await first.traces.close(); await first.store?.close()

        let second = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { second.shutdown() }
        _ = await second.prepareStore()
        second.chats = [ChatRecord(id: "c", workspaceID: "w", title: "Refund edge cases", path: nil, profileID: "p"),
                        ChatRecord(id: "o", workspaceID: "w", title: "Other", path: nil, profileID: "p")]
        await second.restoreDraftMarks()
        XCTAssertTrue(second.showsDraftMark("c")); XCTAssertFalse(second.showsDraftMark("o"))
        // A chat whose draft was saved but which is not listed yet (a side
        // being kept) is marked once it is.
        second.draftChatIDs = []; second.chats.removeAll { $0.id == "c" }
        await second.restoreDraftMarks()
        XCTAssertTrue(second.draftChatIDs.contains("c"), "the reading's chats are kept even before they are listed")
        second.chats.append(ChatRecord(id: "c", workspaceID: "w", title: "Refund edge cases", path: nil, profileID: "p"))
        // Told of a write older than launch's reading: it does not undo it,
        // even for a chat an even older write was applied to before the reading.
        second.draftMarkSequences["c"] = 2; second.draftMarksRestoredAt = 10
        second.applyDraftMark("c", holds: false, sequence: 8)
        XCTAssertTrue(second.showsDraftMark("c"))
        second.applyDraftMark("c", holds: false, sequence: 11)
        XCTAssertFalse(second.showsDraftMark("c"), "a newer write does")
    }

    /// Only chats with kept drafts are marked: never a side that was not
    /// kept, a New chat not yet sent, or a background request.
    @MainActor func testOnlyKeptChatsShowTheMark() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("draft-kinds-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = try await model(root: root)
        defer { model.shutdown() }
        var task = ChatRecord(id: "t", workspaceID: "w", title: "Title job", path: nil, profileID: "p"); task.backgroundTask = "title"
        model.chats += [task, ChatRecord(id: "new", workspaceID: "w", title: ChatRecord.defaultTitle, path: nil, profileID: "p")]
        model.pendingChatIDs = ["new"]
        model.sides["o"] = SideRecord(id: "side", parentID: "o", workspaceID: "w", profileID: "p", title: "Side")
        model.draftChatIDs = ["t", "new", "side", "o"]
        XCTAssertFalse(model.showsDraftMark("t")); XCTAssertFalse(model.showsDraftMark("new")); XCTAssertFalse(model.showsDraftMark("side"))
        XCTAssertTrue(model.showsDraftMark("o"))
    }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(String, Bool, Int)] = []
    func append(_ id: String, _ holds: Bool, _ sequence: Int) { lock.lock(); values.append((id, holds, sequence)); lock.unlock() }
    var list: [(String, Bool, Int)] { lock.lock(); defer { lock.unlock() }; return values }
}
