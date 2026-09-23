import XCTest
import AppKit
import Combine
@testable import PiApp

final class HardeningTests: XCTestCase {
    @MainActor func testNativeSupervisorStartsTheBundledSwiftHostAndExitsOnEOF() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("host-heap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = HostSupervisor(); defer { host.shutdown() }
        try await host.connect(cwd: root, state: root.appendingPathComponent("state"))
        let result = try await host.request("runtime.info").object ?? [:]
        XCTAssertEqual(result["engine"]?.string, "swift")
        XCTAssertEqual(result["engineVersion"]?.string, "1.0.0")
        XCTAssertEqual(result["protocolMajor"]?.number, 1)
        XCTAssertEqual(result["bundledNode"]?.bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/node").path))
        try await host.shutdownAndWait()
    }
    /// Since 0.1.78 a projected reply is complete: the 16 KiB text preview,
    /// the 32-card limit and the 4 KiB per-card argument preview are gone, and
    /// nothing silently shortens an answer. What still has to hold is that the
    /// projection keeps every card and every scalar it was given, cuts no
    /// multi-byte character in half and claims no truncation it did not do.
    func testArchiveProjectionKeepsEveryCardAndEveryCharacterOfAReply() throws {
        let text = String(repeating: "🌍", count: 20_000)
        let tools = (0..<100).map { WireValue.object(["type": .string("toolCall"), "id": .string("t\($0)"), "name": .string("read"), "arguments": .object(["value": .string(text)])]) }
        let projected = TranscriptMessage.project(id: "m", message: ["role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string(text)])] + tools)])
        XCTAssertEqual(projected.tools?.count, 100, "Every call the reply made is a card")
        XCTAssertEqual(projected.text, text, "The reply's own words are complete")
        XCTAssertEqual(projected.text.utf8.count, 80_000)
        XCTAssertFalse(projected.text.contains("\u{FFFD}"), "No character is cut in half")
        XCTAssertEqual(projected.truncated, false, "Nothing was shortened, so nothing says it was")
        XCTAssertTrue(projected.tools?.allSatisfy { card in
            card.inputTruncated == nil && !card.input.contains("\u{FFFD}") && card.input.contains(text)
        } == true, "Each card holds the whole parseable request it was given")
        XCTAssertEqual(projected.toolCallCount, 100)
        // The rows travel in bounded IPC frames, not in one bounded row: the
        // page admits one complete oversized row, which is what this is.
        XCTAssertGreaterThan(try JSONEncoder().encode(projected).count, HistoryWindowPolicy.envelopeBytes)
    }
    @MainActor func testStreamAndFooterChangesDoNotInvalidateTheWholeConversation() {
        let session = SessionDisplay(id: "stream")
        var shell = 0, transcript = 0, footer = 0
        let a = session.objectWillChange.sink { shell += 1 }
        let b = session.transcriptChanges.dropFirst().sink { _ in transcript += 1 }
        let c = session.footer.objectWillChange.sink { footer += 1 }
        for index in 0..<100 {
            session.messages = [.init(id: "m", role: "assistant", text: "\(index)")]
            session.context = ["tokens": .number(Double(index))]
            session.scrollAnchor = .init(id: "m", offset: Double(index), followsBottom: true)
        }
        XCTAssertEqual(shell, 0); XCTAssertEqual(transcript, 100); XCTAssertEqual(footer, 100)
        var editor = 0; let d = session.composerDraft.objectWillChange.sink { editor += 1 }
        session.draft = "typed"; XCTAssertEqual(shell, 0); XCTAssertEqual(editor, 1); XCTAssertEqual(session.composerDraft.text, "typed"); d.cancel()
        a.cancel(); b.cancel(); c.cancel()
    }
    @MainActor func testRestoredOlderViewportLoadsItsBoundedPageWithoutStartingHost() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("native-anchor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("session.jsonl")
        var bytes = Data("{\"type\":\"session\",\"version\":3,\"id\":\"fixture\"}\n".utf8)
        for index in 0..<100 {
            let value: [String: Any] = ["type": "message", "id": "m\(index)", "parentId": index == 0 ? NSNull() : "m\(index - 1)" as Any, "message": ["role": "user", "content": String(repeating: "x", count: 16_000)]]
            bytes.append(try JSONSerialization.data(withJSONObject: value)); bytes.append(10)
        }
        try bytes.write(to: path)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        model.chats = [ChatRecord(id: "fixture", workspaceID: "workspace", title: "fixture", path: path.path, profileID: "profile")]
        try await model.store?.put(TranscriptAnchor(id: "m10", offset: -12, followsBottom: false), kind: "anchor", id: "fixture")
        await model.select("fixture")
        // An unloaded chat opens where the reader left it: the bounded turns
        // from their row on, detached from the newest turns. No host starts.
        XCTAssertEqual(model.selected?.messages.first?.id, "m10"); XCTAssertEqual(model.selected?.messages.last?.id, "m12"); XCTAssertEqual(model.selected?.before, "m10")
        XCTAssertTrue(model.selected?.browsingHistory == true); XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertEqual(model.selected?.scrollAnchor, TranscriptAnchor(id: "m10", offset: -12, followsBottom: false), "The reading position is kept with its offset")
        XCTAssertLessThanOrEqual(model.selected?.messages.reduce(0) { $0 + $1.text.utf8.count } ?? 0, 300_000)
        // Scrolling up prepends the page before the first row without starting a host.
        let view = try XCTUnwrap(model.selected)
        model.historyViewportReady("fixture", generation: view.presentationGeneration)
        let loaded = await model.loadEarlierPage(sessionID:"fixture")
        XCTAssertTrue(loaded)
        XCTAssertEqual(view.messages.first?.id, "m7"); XCTAssertEqual(view.messages.last?.id, "m12"); XCTAssertEqual(view.before, "m7")
        XCTAssertEqual(view.scrollAnchor?.id, "m10", "A model-only page read leaves the viewport and its anchor to the pane")
        XCTAssertTrue(model.hosts.isEmpty)
        model.latest(sessionID: "fixture")
        for _ in 0..<500 where view.messages.first?.id == "m7" { try await Task.sleep(for: .milliseconds(10)) }
        await model.select("fixture")
        XCTAssertEqual(model.selected?.messages.last?.id, "m99"); XCTAssertEqual(model.selected?.messages.first?.id, "m97"); XCTAssertFalse(model.selected?.browsingHistory == true)
        let earlier = try await model.history.read(path: path.path, before: "m10")
        XCTAssertEqual(earlier.messages.last?.id, "m9")
        do { _ = try await model.history.read(path:path.path,around:"missing"); XCTFail("A lost boundary must not silently jump to the latest page") } catch { }
        let found = try await model.history.searchContent(path: path.path, query: "", start: 0)
        XCTAssertEqual(found.hits.count, 100); XCTAssertEqual(found.total, 100)
        let copied = try await model.history.copyContentPage(path: path.path, first: 11, last: 11, cursor: .init(index: 11, offset: 0), revision: found.revision)
        XCTAssertTrue(copied.text.hasPrefix("## user")); XCTAssertNil(copied.next)
        let handle = try FileHandle(forWritingTo: path); try handle.seekToEnd(); try handle.write(contentsOf: Data("{changed".utf8)); try handle.close()
        do { _ = try await model.history.copyContentPage(path: path.path, first: 11, last: 11, cursor: .init(index: 11, offset: 0), revision: found.revision); XCTFail("Changed history must not produce a mixed copy") } catch { }
        model.shutdown(); await model.store?.close()
    }
    @MainActor func testLiveTranscriptDeliveryDoesNotWaitForShellLayoutOrKeepTheOldSession() {
        let first = SessionDisplay(id: "first"), second = SessionDisplay(id: "second")
        first.messages = [.init(id: "a", role: "user", text: "first")]
        second.messages = [.init(id: "b", role: "user", text: "second")]
        let page = TranscriptPage()
        page.bind(first); XCTAssertEqual(page.snapshot?.messages.first?.text, "first")
        first.messages = [.init(id: "a", role: "assistant", text: "streamed")]
        XCTAssertEqual(page.snapshot?.messages.first?.text, "streamed", "rows arrive through the transcript stream, not a shell layout pass")
        page.bind(second)
        first.messages = []; XCTAssertEqual(page.snapshot?.messages.first?.text, "second")
        XCTAssertEqual(page.snapshot?.sessionID, "second"); XCTAssertTrue(page.snapshot?.fresh.isEmpty == true, "a switched-to page arrives settled")
    }
    @MainActor func testUnchangedSideMetadataDoesNotRepublishTheWorkspace() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("native-side-publication-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let view = SessionDisplay(id: "typing"); var draftPublications = 0
        let draftSubscription = view.objectWillChange.sink { draftPublications += 1 }
        for _ in 0..<100 { model.commandChanged(view) }
        XCTAssertEqual(draftPublications, 0); draftSubscription.cancel()
        model.sides["parent"] = SideRecord(id: "side", parentID: "parent", workspaceID: "w", profileID: "p", title: "side", boundary: ["cutoff": .string("one")])
        var publications = 0; let subscription = model.objectWillChange.sink { publications += 1 }
        let unchanged: [String: WireValue] = ["side": .object(["cutoff": .string("one")]), "keeping": .bool(false), "keepRequested": .bool(false), "ephemeral": .bool(true)]
        for _ in 0..<100 { await model.applySideStatus(id: "side", result: unchanged) }
        XCTAssertEqual(publications, 0)
        var changed = unchanged; changed["keeping"] = .bool(true)
        await model.applySideStatus(id: "side", result: changed)
        XCTAssertEqual(publications, 1); XCTAssertTrue(model.sides["parent"]?.keeping == true)
        subscription.cancel(); model.shutdown(); await model.store?.close()
    }
    func testHistoryIndexInvalidatesOnSameLengthReplacementAppendAndDamagedTail() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("native-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("session.jsonl"), reader = HistoryReader()
        func bytes(_ text: String) -> Data { Data(("{\"type\":\"session\",\"version\":3,\"id\":\"fixture\"}\n{\"type\":\"message\",\"id\":\"one\",\"parentId\":null,\"message\":{\"role\":\"user\",\"content\":\"" + text + "\"}}\n").utf8) }
        try bytes("alpha").write(to: path, options: .atomic)
        let first = try await reader.read(path: path.path), warm = try await reader.read(path: path.path)
        XCTAssertEqual(first.messages.first?.text, "alpha"); XCTAssertEqual(warm.messages.first?.text, "alpha")
        try bytes("bravo").write(to: path, options: .atomic)
        let replaced = try await reader.read(path: path.path); XCTAssertEqual(replaced.messages.first?.text, "bravo")
        let handle = try FileHandle(forWritingTo: path); try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"message\",\"id\":\"two\",\"parentId\":\"one\",\"message\":{\"role\":\"user\",\"content\":\"tail\"}}\n".utf8))
        let appended = try await reader.read(path: path.path); XCTAssertEqual(appended.messages.last?.text, "tail"); XCTAssertEqual(appended.total, 2)
        try handle.write(contentsOf: Data("{damaged".utf8)); try handle.close()
        let damaged = try await reader.read(path: path.path); XCTAssertNotNil(damaged.notice); XCTAssertEqual(damaged.total, 2)
    }
    func testUnicodePagingNeverSplitsSurrogates() throws {
        let text = (String(repeating: "a", count: 16_383) + "🌍" + String(repeating: "漢", count: 16_382) + "😀tail") as NSString
        var offset = 0, result = ""
        while offset < text.length { let page = try UnicodePage.slice(text, offset: offset); result += page; offset += (page as NSString).length }
        XCTAssertEqual(result, text as String); XCTAssertFalse(result.contains("�")); XCTAssertThrowsError(try UnicodePage.slice(text, offset: 16_384))
    }
    @MainActor func testLargePastePreservesExistingNativeDraft() {
        var draft = "original", notice = ""
        let composer = NativeComposer(text: .init(get: { draft }, set: { draft = $0 }), send: { _ in }, inputRejected: { notice = $0 })
        let coordinator = composer.makeCoordinator(), editor = NSTextView(); editor.string = draft
        XCTAssertFalse(coordinator.textView(editor, shouldChangeTextIn: NSRange(location: 0, length: 8), replacementString: String(repeating: "x", count: 1_048_576)))
        XCTAssertEqual(draft, "original"); XCTAssertTrue(notice.contains("256 KiB"))
    }
    @MainActor func testUpdateBarrierBlocksNewTurnsAndFlushesUnsentDraftsBeforeIdleShutdown() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("native-barrier-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage())), view = SessionDisplay(id: "chat")
        defer { model.shutdown() }
        view.selectionMetadataLoaded = true
        model.displays["chat"] = view; view.state = "running"; XCTAssertFalse(model.acquireUpdateBarrier())
        view.state = "idle"; view.loading = true; XCTAssertFalse(model.acquireUpdateBarrier()); view.loading = false
        model.sides["chat"] = SideRecord(id: "side", parentID: "chat", workspaceID: "w", profileID: "p", title: "side")
        XCTAssertFalse(model.acquireUpdateBarrier()); model.sides = [:]
        let originalAttachment = AttachmentRecord(id: "original-image", path: root.appendingPathComponent("original.png").path, sha256: "00", bytes: 3, mimeType: "image/png")
        view.draftBeforeEdit = DraftRecord(id: view.id, text: "Original unsent draft survives update", attachments: [originalAttachment])
        view.editingMessageID = "earlier-user-message"; view.draft = "Edited request survives update"
        model.draftChanged(view) // The install flush must replace this cancelled, debounced edit write.
        let plain = SessionDisplay(id: "plain"); plain.selectionMetadataLoaded = true; plain.draft = "Ordinary unsent draft"; model.displays[plain.id] = plain
        XCTAssertTrue(model.acquireUpdateBarrier()); XCTAssertTrue(model.installPreparing)
        model.selectedID = "chat"; model.send(); XCTAssertTrue(model.hosts.isEmpty)
        try await model.prepareForInstall()
        let draft = try await model.store?.get(DraftRecord.self, kind: "draft", id: "chat"); XCTAssertEqual(draft?.text, view.draft)
        XCTAssertEqual(draft?.edit?.messageID, "earlier-user-message")
        XCTAssertEqual(draft?.edit?.originalText, "Original unsent draft survives update")
        XCTAssertEqual(draft?.edit?.originalAttachments, [originalAttachment])
        let restored = SessionDisplay(id: view.id); restored.restoreDraft(try XCTUnwrap(draft))
        XCTAssertEqual(restored.editingMessageID, view.editingMessageID)
        XCTAssertEqual(restored.draftBeforeEdit?.text, view.draftBeforeEdit?.text)
        XCTAssertEqual(restored.draftBeforeEdit?.attachments, [originalAttachment])
        let ordinary = try await model.store?.get(DraftRecord.self, kind: "draft", id: plain.id)
        XCTAssertEqual(ordinary?.text, plain.draft); XCTAssertNil(ordinary?.edit)
        model.releaseUpdateBarrier(); XCTAssertFalse(model.installPreparing)
        await model.store?.close()
    }
    func testReceiptIndexPrunesAndDeletesOnlyItsOwnChat() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("native-receipts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("desktop.sqlite"))
        for n in 0..<140 { try await store.put("receipt", kind: "receipt:chat", id: String(n), revision: Int64(n)) }
        try await store.put("other", kind: "receipt:other", id: "one")
        let items = try await store.list(String.self, kind: "receipt:chat"); XCTAssertEqual(items.count, 128)
        try await store.removeAll(kind: "receipt:chat")
        let empty = try await store.list(String.self, kind: "receipt:chat"), other = try await store.list(String.self, kind: "receipt:other")
        XCTAssertTrue(empty.isEmpty); XCTAssertEqual(other, ["other"]); await store.close()
    }
}

extension HardeningTests {
    /// Reading back in a long chat, then looking at another chat and coming
    /// back (or quitting and reopening), used to land on the newest turns: the
    /// chat opened on its newest page, and a position outside it was dropped.
    @MainActor func testAnOlderReadingPositionSurvivesSwitchingAwayAndRelaunching() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("native-reading-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("session.jsonl")
        var bytes = Data("{\"type\":\"session\",\"version\":3,\"id\":\"fixture\"}\n".utf8)
        for index in 0..<100 {
            let value: [String: Any] = ["type": "message", "id": "m\(index)", "parentId": index == 0 ? NSNull() : "m\(index - 1)" as Any, "message": ["role": index % 2 == 0 ? "user" : "assistant", "content": "Row \(index)"]]
            bytes.append(try JSONSerialization.data(withJSONObject: value)); bytes.append(10)
        }
        try bytes.write(to: path)
        let chats = [ChatRecord(id: "fixture", workspaceID: "workspace", title: "fixture", path: path.path, profileID: "profile"),
                     ChatRecord(id: "other", workspaceID: "workspace", title: "other", path: nil, profileID: "profile")]
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        model.chats = chats
        await model.select("fixture")
        let view = try XCTUnwrap(model.selected)
        for _ in 0..<60 where !view.messages.contains(where: { $0.id == "m10" }) {
            model.historyViewportReady("fixture", generation: view.presentationGeneration)
            guard await model.loadEarlierPage(sessionID: "fixture") else { break }
        }
        XCTAssertTrue(view.messages.contains { $0.id == "m10" }, "Scrolled back to the eleventh row")
        let reading = TranscriptAnchor(id: "m10", offset: 30, followsBottom: false)
        view.scrollAnchor = reading; model.anchorChanged(view)
        await model.select("other"); await model.select("fixture")
        XCTAssertTrue(model.selected?.messages.contains { $0.id == "m10" } == true, "Coming back reads the turns the reader was in")
        XCTAssertEqual(model.selected?.scrollAnchor, reading)
        XCTAssertTrue(model.hosts.isEmpty)

        try await model.flushDrafts(); model.shutdown(); try await model.traces.close(); await model.store?.close()
        let relaunched = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        relaunched.chats = chats
        await relaunched.select("fixture")
        XCTAssertTrue(relaunched.selected?.messages.contains { $0.id == "m10" } == true, "A relaunch opens on the turns the reader was in")
        XCTAssertEqual(relaunched.selected?.scrollAnchor, reading)
        XCTAssertLessThanOrEqual(relaunched.selected?.messages.count ?? 0, 60, "Still one bounded page")
        // A row that is gone opens the newest turns, as before.
        relaunched.selected?.scrollAnchor = TranscriptAnchor(id: "gone", offset: 0, followsBottom: false)
        await relaunched.select("other"); await relaunched.select("fixture")
        XCTAssertEqual(relaunched.selected?.messages.last?.id, "m99")
        XCTAssertNil(relaunched.selected?.scrollAnchor)
        relaunched.shutdown(); try await relaunched.traces.close(); await relaunched.store?.close()
    }
}
