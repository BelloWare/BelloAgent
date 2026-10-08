import XCTest
import AppKit
@testable import PiApp

/// A journal written the way the helper writes one: a session header, the
/// native marker, then records each naming the one before as its parent.
final class SearchJournal {
    let url: URL
    private(set) var parent: String? = "native"
    init(_ url: URL, id: String = "chat") throws {
        self.url = url
        let header = #"{"type":"session","version":3,"id":"\#(id)","cwd":"/tmp","timestamp":"2026-09-01T00:00:00Z"}"# + "\n"
            + #"{"id":"native","parentId":null,"type":"custom","customType":"pi-app.native.v1","data":{"binding":{},"version":1}}"# + "\n"
        try header.write(to: url, atomically: true, encoding: .utf8)
    }
    /// Appends one record; `body` is its fields after id and parent.
    func record(_ id: String, _ body: [String: Any]) throws {
        var value = body
        value["id"] = id; value["parentId"] = parent ?? NSNull(); value["timestamp"] = "2026-09-01T00:00:00Z"
        var bytes = try JSONSerialization.data(withJSONObject: value); bytes.append(10)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: bytes)
        parent = id
    }
    func message(_ id: String, role: String, _ content: Any, extra: [String: Any] = [:]) throws {
        var message: [String: Any] = ["role": role, "content": content]
        message.merge(extra) { $1 }
        try record(id, ["type": "message", "message": message])
    }
    /// Many records at once, in one write (long fixtures).
    func turns(_ count: Int, prefix: String, text: (Int) -> (String, String)) throws {
        var data = Data()
        for index in 0..<count {
            let (question, answer) = text(index)
            for (id, role, content) in [("\(prefix)-u\(index)", "user", question), ("\(prefix)-a\(index)", "assistant", answer)] {
                let value: [String: Any] = ["id": id, "parentId": parent ?? NSNull(), "timestamp": "2026-09-01T00:00:00Z", "type": "message",
                                            "message": ["role": role, "content": content]]
                data.append(try JSONSerialization.data(withJSONObject: value)); data.append(10)
                parent = id
            }
        }
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
}

final class SidebarSearchIndexTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("search-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func index(_ root: URL) -> (ChatSearchIndex, ChatSearchQuery) {
        let url = root.appendingPathComponent("state").appendingPathComponent(ChatSearchDatabase.fileName)
        return (ChatSearchIndex(url: url, indexDirectory: root), ChatSearchQuery(url: url))
    }

    /// A long chat: a word said once near its start is found, and its row is
    /// where the chat opens. Where it says it twice, the newer one wins.
    func testTheIndexFindsTextInAnOldMessageOfALongChat() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SearchJournal(root.appendingPathComponent("long.jsonl"))
        try journal.turns(1_000, prefix: "t") { index in
            (index == 1 ? "Where did the quokkaline parser go?" : "Question \(index) about the retry loop",
             index == 700 ? "The bramblewick cache is warm." : "Answer \(index): it retries with backoff.")
        }
        try journal.message("late", role: "assistant", "Mentioning bramblewick once more, later.")
        let (index, query) = index(root)
        let pass = await index.reconcile([ChatSearchSource(id: "long", path: journal.url.path)])
        XCTAssertEqual(pass.rebuilt, ["long"])
        let hits = try await query.search("quokkaline")
        let hit = try XCTUnwrap(hits["long"])
        XCTAssertEqual(hit.messageID, "t-u1", "The match opens at the old message, 2,000 rows back")
        XCTAssertEqual(hit.kind, .user)
        XCTAssertEqual((hit.excerpt as NSString).substring(with: hit.highlight), "quokkaline")
        XCTAssertTrue(hit.excerpt.contains("Where did the"))
        let newer = try await query.search("BRAMBLEWICK")
        XCTAssertEqual(newer["long"]?.messageID, "late", "Each chat shows its newest match")
        let none = try await query.search("absent-word")
        XCTAssertTrue(none.isEmpty)
        let short = try await query.search("qu")
        XCTAssertTrue(short.isEmpty, "Two characters are matched against titles only")
        await index.close()
    }

    /// Messages written after the chat was indexed are found: only the new
    /// rows are read and added, the rest stays as it was.
    func testNewMessagesBecomeSearchable() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SearchJournal(root.appendingPathComponent("grow.jsonl"))
        try journal.turns(300, prefix: "t") { ("Question \($0)", "Answer \($0)") }
        let (index, query) = index(root)
        let source = ChatSearchSource(id: "grow", path: journal.url.path)
        _ = await index.reconcile([source])
        let before = await index.documentCount(chat: "grow")
        XCTAssertEqual(before, 600)
        let missing = try await query.search("marmalade")
        XCTAssertTrue(missing.isEmpty)
        let unchanged = await index.reconcile([source])
        XCTAssertFalse(unchanged.changed, "An unchanged journal is not read again")

        try journal.message("new-u", role: "user", "Add marmalade to the release notes")
        try journal.message("new-a", role: "assistant", "Added the marmalade line.")
        let pass = await index.reconcile([source])
        XCTAssertEqual(pass.extended, ["grow"], "Only the new rows are added")
        XCTAssertEqual(pass.rebuilt, [])
        let after = await index.documentCount(chat: "grow")
        XCTAssertEqual(after, 602)
        let found = try await query.search("marmalade")
        XCTAssertEqual(found["grow"]?.messageID, "new-a")
        await index.close()
    }

    /// A chat no longer listed (deleted) leaves the index: its rows go and
    /// nothing of it is found. Its journal gone does the same.
    func testDeletedChatsDisappearFromResults() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try SearchJournal(root.appendingPathComponent("first.jsonl"), id: "first")
        try first.message("f1", role: "user", "the zircon migration plan")
        let second = try SearchJournal(root.appendingPathComponent("second.jsonl"), id: "second")
        try second.message("s1", role: "user", "zircon rollback checklist")
        let (index, query) = index(root)
        let sources = [ChatSearchSource(id: "first", path: first.url.path), ChatSearchSource(id: "second", path: second.url.path)]
        _ = await index.reconcile(sources)
        let both = try await query.search("zircon")
        XCTAssertEqual(Set(both.keys), ["first", "second"])

        let pass = await index.reconcile([sources[0]])
        XCTAssertEqual(pass.removed, ["second"])
        let one = try await query.search("zircon")
        XCTAssertEqual(Set(one.keys), ["first"])
        let rows = await index.documentCount(chat: "second")
        XCTAssertEqual(rows, 0, "The deleted chat's text is gone from the index")

        try FileManager.default.removeItem(at: first.url)
        let gone = await index.reconcile([sources[0]])
        XCTAssertEqual(gone.removed, ["first"], "A chat whose journal is gone is not searchable")
        let none = try await query.search("zircon")
        XCTAssertTrue(none.isEmpty)
        await index.close()
    }

    /// An edit moves the chat onto a new branch: the abandoned message is no
    /// longer on the timeline the chat shows, so it is no longer found.
    func testAnEditRebuildsTheChatWithoutTheAbandonedMessage() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SearchJournal(root.appendingPathComponent("edit.jsonl"))
        try journal.message("kept", role: "user", "kept question")
        try journal.message("kept-answer", role: "assistant", "kept answer")
        try journal.message("old", role: "user", "the obsidian question")
        try journal.message("old-answer", role: "assistant", "old answer")
        let (index, query) = index(root)
        let source = ChatSearchSource(id: "edit", path: journal.url.path)
        _ = await index.reconcile([source])
        let old = try await query.search("obsidian")
        XCTAssertEqual(old["edit"]?.messageID, "old")
        try journal.record("branch", ["type": "branch", "fromMessageId": "old", "keptIds": ["kept", "kept-answer"]])
        try journal.message("new", role: "user", "the basalt question")
        try journal.message("new-answer", role: "assistant", "new answer")
        let pass = await index.reconcile([source])
        XCTAssertEqual(pass.rebuilt, ["edit"], "A new branch is not an append")
        let abandoned = try await query.search("obsidian")
        XCTAssertTrue(abandoned.isEmpty)
        let current = try await query.search("basalt")
        XCTAssertEqual(current["edit"]?.messageID, "new")
        await index.close()
    }

    /// A tool's input and output are found; an output opens at the reply
    /// whose card shows it — the latest that made that call, as call ids are
    /// reused. Reasoning is never indexed.
    func testToolTextIsFoundAndOpensAtItsCallButReasoningIsNot() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SearchJournal(root.appendingPathComponent("tools.jsonl"))
        try journal.message("u1", role: "user", "Read the config")
        for (reply, result, output) in [("a1", "r1", "first output"), ("a2", "r2", "port=8443 listener ready")] {
            try journal.message(reply, role: "assistant", [
                ["type": "thinking", "thinking": "secret pondering about pelicans"],
                ["type": "text", "text": "Reading it now."],
                ["type": "toolCall", "id": "call-1", "name": "read", "arguments": ["path": "config/\(reply)-loadbalancer.yaml"]]])
            try journal.message(result, role: "toolResult", [["type": "text", "text": output]], extra: ["toolCallId": "call-1", "toolName": "read"])
        }
        let (index, query) = index(root)
        _ = await index.reconcile([ChatSearchSource(id: "tools", path: journal.url.path)])
        let output = try await query.search("8443 listener")
        XCTAssertEqual(output["tools"]?.kind, .toolOutput)
        XCTAssertEqual(output["tools"]?.messageID, "a2", "A tool's output opens at the reply that made that call")
        let input = try await query.search("a1-loadbalancer")
        XCTAssertEqual(input["tools"]?.kind, .toolInput)
        XCTAssertEqual(input["tools"]?.messageID, "a1")
        let reasoning = try await query.search("pelicans")
        XCTAssertTrue(reasoning.isEmpty, "Reasoning is not searched")
        await index.close()
    }

    /// A very long text is indexed whole, in overlapping pieces: a match far
    /// past the first piece, and one across a piece's edge, are both found.
    func testALongMessageIsSearchableToItsEnd() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SearchJournal(root.appendingPathComponent("big.jsonl"))
        let edge = ChatSearchDatabase.chunkCharacters
        var text = String(repeating: "lorem ipsum ", count: edge / 12 + 1)
        text = String(text.prefix(edge - 4)) + "SEAMWORD" + String(repeating: " dolor sit", count: 20_000) + " tailword"
        try journal.message("big", role: "toolResult", [["type": "text", "text": text]], extra: ["toolCallId": "c", "toolName": "read"])
        let (index, query) = index(root)
        _ = await index.reconcile([ChatSearchSource(id: "big", path: journal.url.path)])
        let seam = try await query.search("seamword")
        XCTAssertNotNil(seam["big"], "A word across two pieces' edge")
        let tail = try await query.search("tailword")
        XCTAssertNotNil(tail["big"], "The end of a 200 KB output")
        XCTAssertEqual((tail["big"]!.excerpt as NSString).substring(with: tail["big"]!.highlight), "tailword")
        await index.close()
    }

    /// Text typed with a decomposed accent finds text written composed.
    func testComposedAndDecomposedTextMatch() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SearchJournal(root.appendingPathComponent("accents.jsonl"))
        try journal.message("m", role: "user", "Notes from the caf\u{e9} meeting")
        let (index, query) = index(root)
        _ = await index.reconcile([ChatSearchSource(id: "accents", path: journal.url.path)])
        let hits = try await query.search("cafe\u{301} meeting")
        XCTAssertEqual(hits["accents"]?.messageID, "m")
        await index.close()
    }

    /// The index files are this user's alone, like the desktop database,
    /// even in a folder made earlier with looser permissions.
    func testTheIndexIsPrivate() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SearchJournal(root.appendingPathComponent("p.jsonl"))
        try journal.message("m", role: "user", "private words")
        let (index, _) = index(root)
        try FileManager.default.createDirectory(at: index.url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let pass = await index.reconcile([ChatSearchSource(id: "p", path: journal.url.path)])
        XCTAssertEqual(pass.rebuilt, ["p"])
        func mode(_ path: String) throws -> Int? { try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int }
        XCTAssertEqual(try mode(index.url.deletingLastPathComponent().path), 0o700)
        for suffix in ["", "-wal", "-shm"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: index.url.path + suffix), suffix)
            XCTAssertEqual(try mode(index.url.path + suffix), 0o600, "search-index.sqlite" + suffix)
        }
        await index.close()
    }

    /// A chat deleted before a pass that listed it reaches the index is not
    /// written by that pass; one deleted during a pass that is then shut
    /// down still leaves the index.
    func testDeletedChatsStayOutOfTheIndexAcrossPassesAndShutdown() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try SearchJournal(root.appendingPathComponent("old.jsonl"), id: "old")
        try old.message("o", role: "user", "garnet in the old chat")
        let big = try SearchJournal(root.appendingPathComponent("big.jsonl"), id: "big")
        try big.turns(3_000, prefix: "b") { ("question \($0)", "answer \($0)") }
        let (index, query) = index(root)
        let oldSource = ChatSearchSource(id: "old", path: old.url.path), bigSource = ChatSearchSource(id: "big", path: big.url.path)
        await index.forget(["old"])
        let stale = await index.reconcile([oldSource])
        XCTAssertTrue(stale.rebuilt.isEmpty, "A pass listed before the deletion does not write it")
        let none = try await query.search("garnet")
        XCTAssertTrue(none.isEmpty)

        // Another index over the same file: "old2" indexed, then deleted while a long pass runs, then shut down.
        let second = ChatSearchIndex(url: index.url, indexDirectory: root)
        await index.close()
        let old2 = ChatSearchSource(id: "old2", path: old.url.path)
        _ = await second.reconcile([old2])
        let indexed = await second.documentCount(chat: "old2")
        XCTAssertEqual(indexed, 1)
        try big.message("more", role: "user", "more")
        let pass = Task { await second.reconcile([old2, bigSource]) }
        try await Task.sleep(for: .milliseconds(100))
        await second.forget(["old2"])
        await second.close()
        _ = await pass.value
        let reopened = ChatSearchIndex(url: index.url, indexDirectory: root)
        let left = await reopened.documentCount(chat: "old2")
        XCTAssertEqual(left, 0, "Its rows went before the index closed")
        await reopened.close()
    }

    /// Whitespace reads alike in the query and the text: a phrase typed with
    /// one space finds it across a line break or a run of spaces.
    func testAPhraseMatchesAcrossLineBreaks() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SearchJournal(root.appendingPathComponent("w.jsonl"))
        try journal.message("m", role: "assistant", "The retry\n\n   loop waits.")
        let (index, query) = index(root)
        _ = await index.reconcile([ChatSearchSource(id: "w", path: journal.url.path)])
        let hits = try await query.search("retry loop")
        XCTAssertEqual(hits["w"]?.messageID, "m")
        XCTAssertEqual(hits["w"].map { ($0.excerpt as NSString).substring(with: $0.highlight) }, "retry loop")
        await index.close()
    }

    /// A chat deleted while a pass is reading it is not written, and the
    /// rest of the pass goes on.
    func testAChatDeletedDuringAPassIsNotIndexed() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let big = try SearchJournal(root.appendingPathComponent("big.jsonl"), id: "big")
        try big.turns(3_000, prefix: "b") { ("cobalt question \($0)", "cobalt answer \($0)") }
        let small = try SearchJournal(root.appendingPathComponent("small.jsonl"), id: "small")
        try small.message("s", role: "user", "cobalt note")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: small.url.path)
        let (index, query) = index(root)
        let pass = Task { await index.reconcile([ChatSearchSource(id: "big", path: big.url.path), ChatSearchSource(id: "small", path: small.url.path)]) }
        try await Task.sleep(for: .milliseconds(150))
        await index.forget(["big"])
        let result = await pass.value
        XCTAssertFalse(result.rebuilt.contains("big"), "The deleted chat is not committed")
        XCTAssertEqual(result.rebuilt, ["small"], "The pass goes on to the other chats")
        let rows = await index.documentCount(chat: "big")
        XCTAssertEqual(rows, 0)
        let hits = try await query.search("cobalt")
        XCTAssertEqual(Set(hits.keys), ["small"])
        await index.close()
    }

    /// A query stopped by a newer one ends at once with no answer.
    func testACancelledQueryGivesNoAnswer() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SearchJournal(root.appendingPathComponent("c.jsonl"))
        try journal.turns(200, prefix: "t") { ("needle question \($0)", "needle answer \($0)") }
        let (index, query) = index(root)
        _ = await index.reconcile([ChatSearchSource(id: "c", path: journal.url.path)])
        let task = Task { try await query.search("needle") }
        task.cancel()
        do { _ = try await task.value; XCTFail("A cancelled query answered") } catch is CancellationError {}
        let fresh = try await query.search("needle")
        XCTAssertNotNil(fresh["c"], "The next query still answers")
        await index.close()
    }

    /// The snippet: the match with words around it, on one line, cut at words.
    func testTheExcerptShowsTheMatchInItsLine() throws {
        let text = "First line.\n\nThe   retry loop in PaymentClient waits 30 seconds\nbefore it gives up and reports the failure to the caller, which then decides what to do next."
        let value = try XCTUnwrap(ChatSearchHit.excerpt(of: "paymentclient", in: text))
        XCTAssertFalse(value.excerpt.contains("\n"))
        XCTAssertEqual((value.excerpt as NSString).substring(with: value.highlight), "PaymentClient")
        XCTAssertTrue(value.excerpt.contains("retry loop in PaymentClient waits"))
        let hit = ChatSearchHit(chatID: "c", messageID: "m", kind: .user, excerpt: value.excerpt, highlight: value.highlight, context: value.context)
        XCTAssertEqual(hit.refined(to: "PaymentClient waits").map { ($0.excerpt as NSString).substring(with: $0.highlight) }, "PaymentClient waits")
        XCTAssertNil(hit.refined(to: "PaymentClient sleeps"))
    }
}

/// The sidebar's side: content matches list chats as titles do, under the
/// archive switch and in their projects, with a snippet that reads its chat
/// and its match, and opening one goes to the matching message.
final class SidebarSearchSidebarTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("search-sidebar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Two projects; in the first an active chat and an archived one, both
    /// mentioning "teapot" only in their messages; in the second a chat that
    /// does not.
    @MainActor private func model(_ root: URL) throws -> WorkspaceModel {
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"))
        model.workspaces = [WorkspaceRecord(id: "one", path: root.appendingPathComponent("one").path, trusted: true),
                            WorkspaceRecord(id: "two", path: root.appendingPathComponent("two").path, trusted: true)]
        func chat(_ id: String, _ project: String, _ title: String, archived: Bool = false, order: Int64, words: String) throws -> ChatRecord {
            let journal = try SearchJournal(root.appendingPathComponent(id + ".jsonl"), id: id)
            try journal.turns(40, prefix: id) { index in (index == 3 ? words : "Question \(index)", "Answer \(index)") }
            var record = ChatRecord(id: id, workspaceID: project, title: title, path: journal.url.path, profileID: "fixture", sidebarOrder: 1_000 - order)
            if archived { record.archivedAt = Date(timeIntervalSince1970: 1_000_000) }
            return record
        }
        model.chats = [try chat("active", "one", "Release planning", order: 1, words: "Where is the teapot icon?"),
                       try chat("archived", "one", "Old design review", archived: true, order: 2, words: "the teapot sketches"),
                       try chat("other", "two", "Unrelated", order: 3, words: "nothing here")]
        return model
    }
    @MainActor private func sidebar(_ model: WorkspaceModel) -> WorkspaceSidebarView {
        let view = WorkspaceSidebarView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 700)
        view.layoutSubtreeIfNeeded()
        return view
    }
    @MainActor private func search(_ view: WorkspaceSidebarView, _ text: String) async {
        view.setFilter(text)
        await view.model.sidebarSearch.settleQuery()
        view.settle()
    }
    @MainActor private func snippets(_ view: WorkspaceSidebarView) -> [SidebarSearchSnippetState] {
        view.list.contents.entries.compactMap { if case .searchSnippet(let state) = $0 { return state } else { return nil } }
    }

    @MainActor func testArchivedChatsFollowTheArchiveSwitch() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try model(root); defer { model.shutdown() }
        let view = sidebar(model)
        await model.sidebarSearch.reconcileNow()
        await search(view, "teapot")
        XCTAssertEqual(model.sidebarChatOrder, ["active"], "Off: the archived chat's match is not listed")
        XCTAssertEqual(snippets(view).map(\.chatID), ["active"])
        model.setArchivedChatsShown(true); view.settle()
        XCTAssertEqual(model.sidebarChatOrder, ["active", "archived"], "On: it is listed after the active one, in its project")
        XCTAssertEqual(snippets(view).map(\.chatID), ["active", "archived"])
        model.setArchivedChatsShown(false); view.settle()
        XCTAssertEqual(snippets(view).map(\.chatID), ["active"])
        XCTAssertFalse(model.sidebarChatOrder.contains("other"))
    }

    /// While the reader is reaching for a row (the pointer over the list, a
    /// menu, a drag), a match that arrives in the background waits: the rows
    /// do not move under the pointer. It shows once nothing holds the order.
    /// What the reader types shows at once.
    @MainActor func testABackgroundMatchWaitsWhileTheReaderReachesForARow() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try model(root); defer { model.shutdown() }
        let view = sidebar(model)
        await model.sidebarSearch.reconcileNow()
        await search(view, "teapot")
        XCTAssertEqual(snippets(view).map(\.chatID), ["active"])
        // A reply mentioning it lands in the other project's chat while the pointer is over the list.
        model.setSidebarOrderHold(.pointer, true)
        let line = #"{"id":"other-late","parentId":"other-a39","timestamp":"2026-09-01T00:00:00Z","type":"message","message":{"role":"assistant","content":"found the teapot"}}"# + "\n"
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("other.jsonl"))
        try handle.seekToEnd(); try handle.write(contentsOf: Data(line.utf8)); try handle.close()
        await model.sidebarSearch.reconcileNow()
        await model.sidebarSearch.settleQuery(); view.settle()
        XCTAssertNotNil(model.sidebarSearch.heldHits, "the background answer came")
        XCTAssertEqual(snippets(view).map(\.chatID), ["active"], "and waits while the pointer is over the list")
        model.setSidebarOrderHold(.pointer, false); view.settle()
        XCTAssertEqual(Set(snippets(view).map(\.chatID)), ["active", "other"], "it shows once nothing holds the order")
        // The reader's own typing is not held.
        model.setSidebarOrderHold(.pointer, true)
        await search(view, "nothing here")
        XCTAssertEqual(snippets(view).map(\.chatID), ["other"], "a query typed shows at once, held or not")
        // A chat deleted while an answer waits does not come back with it.
        await search(view, "teapot")
        let more = #"{"id":"active-late","parentId":"active-a39","timestamp":"2026-09-01T00:00:00Z","type":"message","message":{"role":"assistant","content":"another teapot"}}"# + "\n"
        let active = try FileHandle(forWritingTo: root.appendingPathComponent("active.jsonl"))
        try active.seekToEnd(); try active.write(contentsOf: Data(more.utf8)); try active.close()
        await model.sidebarSearch.reconcileNow(); await model.sidebarSearch.settleQuery()
        XCTAssertNotNil(model.sidebarSearch.heldHits?["other"], "an answer waits, naming the other chat")
        model.chats.removeAll { $0.id == "other" }
        await Task.yield()
        XCTAssertNil(model.sidebarSearch.heldHits?["other"], "the waiting answer forgets a deleted chat")
        model.setSidebarOrderHold(.pointer, false); view.settle()
        XCTAssertEqual(snippets(view).map(\.chatID), ["active"])
    }

    /// Typed before the index is ready, while the pointer is over the list:
    /// the answer is still the reader's own, and shows when the index has it.
    @MainActor func testATypedQueryAnsweredByAColdIndexIsNotHeld() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try model(root); defer { model.shutdown() }
        let view = sidebar(model)
        model.setSidebarOrderHold(.pointer, true)
        view.setFilter("teapot")
        await model.sidebarSearch.reconcileNow(); await model.sidebarSearch.settleQuery(); view.settle()
        XCTAssertEqual(snippets(view).map(\.chatID), ["active"], "the typed query's answer shows while held")
        model.setSidebarOrderHold(.pointer, false)
    }

    /// Titles answer at once; content after the index does. Each snippet
    /// sits right under its row and reads its chat and its match.
    @MainActor func testEachResultReadsItsTitleAndSnippet() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try model(root); defer { model.shutdown() }
        let view = sidebar(model)
        await model.sidebarSearch.reconcileNow()
        view.setFilter("Release"); view.settle()
        XCTAssertEqual(model.sidebarChatOrder, ["active"], "A title match is listed at once")
        await search(view, "teapot icon")
        let entries = view.list.contents.entries.map(\.id)
        let row = try XCTUnwrap(entries.firstIndex(of: "chat|active"))
        XCTAssertEqual(entries[row + 1], "snippet|active", "The snippet is right under its row")
        let snippet = try XCTUnwrap(view.list.views["snippet|active"] as? SidebarSearchSnippetView)
        XCTAssertEqual(snippet.press.accessibilityRole(), .button)
        XCTAssertEqual(snippet.press.accessibilityLabel(), "Release planning, Your message: Where is the teapot icon?")
        XCTAssertEqual(snippet.press.accessibilityIdentifier(), "sidebarSearchSnippet-active")
        XCTAssertGreaterThan(snippet.frame.height, 10)
        snippet.press.refreshFace(animated: false)
        XCTAssertEqual(snippet.press.stroke.borderColor?.alpha ?? 0, 0, "A snippet has no outline: it reads as part of its row")
        XCTAssertEqual(snippet.press.fill.backgroundColor?.alpha ?? 0, 0, "Nor a fill until the pointer is over it")
        view.setFilter(""); view.settle()
        XCTAssertTrue(snippets(view).isEmpty, "Clearing the field clears the snippets")
    }

    /// Opening a result — the row, its snippet, or Return in the field —
    /// goes to the message that matched.
    @MainActor func testOpeningAResultTargetsTheMatchingMessage() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try model(root); defer { model.shutdown() }
        let view = sidebar(model)
        var revealed: [String] = []
        SidebarSearchReveal.override = { chat, message in revealed.append(chat + "/" + message) }
        defer { SidebarSearchReveal.override = nil }
        // Already open, so opening it again changes nothing but the place.
        let display = SessionDisplay(id: "active"); display.historyState = .ready
        model.selectedID = "active"; model.displays["active"] = display; model.selected = display; model.focusedSessionID = "active"
        await model.sidebarSearch.reconcileNow()
        await search(view, "teapot")
        await model.openFromSidebar("active")
        XCTAssertEqual(revealed, ["active/active-u3"])
        let snippet = try XCTUnwrap(view.list.views["snippet|active"] as? SidebarSearchSnippetView)
        snippet.press.performClick(nil)
        for _ in 0..<50 where revealed.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(revealed.last, "active/active-u3")
        model.openFirstSidebarResult()
        for _ in 0..<50 where revealed.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(revealed, ["active/active-u3", "active/active-u3", "active/active-u3"])
        // A title match alone opens the chat as it always did.
        view.setFilter("Release"); view.settle()
        await model.openFromSidebar("active")
        XCTAssertEqual(revealed.count, 3)
    }

    /// The adapter as the app runs it: the chat's page is read around the
    /// matching message, 80 rows back, and the transcript anchors there.
    @MainActor func testRevealingAMatchLoadsAndAnchorsItsMessage() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try model(root); defer { model.shutdown() }
        let display = SessionDisplay(id: "active")
        display.messages = [.init(id: "active-a39", role: "assistant", text: "Answer 39")]
        model.displays["active"] = display; model.selectedID = "active"; model.selected = display; model.focusedSessionID = "active"
        await SidebarSearchReveal.reveal(model, chatID: "active", messageID: "active-u3")
        XCTAssertTrue(display.messages.contains { $0.id == "active-u3" }, "The page around the match is loaded")
        XCTAssertEqual(display.scrollAnchor?.id, "active-u3")
    }

    /// A slow open of one chat does not take the reader back to it after
    /// they opened another.
    @MainActor func testAnOlderOpenDoesNotRevealOverANewerOne() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try model(root); defer { model.shutdown() }
        var revealed: [String] = []
        SidebarSearchReveal.override = { chat, message in revealed.append(chat + "/" + message) }
        defer { SidebarSearchReveal.override = nil }
        model.selectedID = "active"; model.focusedSessionID = "active"
        let hit = ChatSearchHit(chatID: "active", messageID: "active-u3", kind: .user, excerpt: "x", highlight: NSRange(), context: "x")
        let opening = model.beginSidebarOpen()
        _ = model.beginSidebarOpen()
        await model.revealSidebarSearchHit("active", hit: hit, opening: opening)
        XCTAssertTrue(revealed.isEmpty, "A newer open supersedes it")
        let current = model.beginSidebarOpen()
        model.focusedSessionID = "other"
        await model.revealSidebarSearchHit("active", hit: hit, opening: current)
        XCTAssertTrue(revealed.isEmpty, "The reader is in another chat")
        model.focusedSessionID = "active"
        await model.revealSidebarSearchHit("active", hit: hit, opening: current)
        XCTAssertTrue(revealed.isEmpty, "The field no longer shows that match")
        let view = sidebar(model)
        await model.sidebarSearch.reconcileNow()
        await search(view, "teapot")
        let shown = try XCTUnwrap(model.sidebarSearchHit("active"))
        model.openReport()
        await model.revealSidebarSearchHit("active", hit: shown, opening: current)
        XCTAssertTrue(revealed.isEmpty, "The reader went to the report")
        model.page = .chats
        await model.revealSidebarSearchHit("active", hit: shown, opening: current)
        XCTAssertEqual(revealed, ["active/active-u3"])
        // A reveal still loading when the field changes stops there.
        SidebarSearchReveal.override = { chat, message in
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { revealed.append(chat + "/" + message) }
        }
        let slow = Task { await model.revealSidebarSearchHit("active", hit: shown, opening: current) }
        try await Task.sleep(for: .milliseconds(50))
        view.setFilter("teapot sketches")
        await slow.value
        XCTAssertEqual(revealed.count, 1, "The changed field cancelled the reveal")
        // Nor does one survive the app coming down, or start after it.
        await search(view, "teapot")
        let again = try XCTUnwrap(model.sidebarSearchHit("active"))
        let last = model.beginSidebarOpen()
        let pending = Task { await model.revealSidebarSearchHit("active", hit: again, opening: last) }
        try await Task.sleep(for: .milliseconds(50))
        model.shutdown()
        await pending.value
        await model.revealSidebarSearchHit("active", hit: again, opening: last)
        XCTAssertEqual(revealed.count, 1, "Shutdown cancelled the reveal, and none starts after it")
    }

    /// A chat deleted from the sidebar stops matching, and its text leaves the index.
    @MainActor func testADeletedChatLeavesTheResults() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try model(root); defer { model.shutdown() }
        let view = sidebar(model)
        model.setArchivedChatsShown(true)
        await model.sidebarSearch.reconcileNow()
        await search(view, "teapot")
        XCTAssertEqual(Set(model.sidebarContentMatches), ["active", "archived"])
        model.chats.removeAll { $0.id == "archived" }
        XCTAssertEqual(model.sidebarContentMatches, ["active"], "It leaves the results at once")
        await model.sidebarSearch.reconcileNow()
        await model.sidebarSearch.settleQuery(); view.settle()
        XCTAssertEqual(model.sidebarContentMatches, ["active"])
        let indexed = await model.sidebarSearch.index.indexedChats()
        XCTAssertFalse(indexed.contains("archived"))
        let rows = await model.sidebarSearch.index.documentCount(chat: "archived")
        XCTAssertEqual(rows, 0)
    }
}
