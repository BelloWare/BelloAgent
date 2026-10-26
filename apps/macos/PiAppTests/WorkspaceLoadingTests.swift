import XCTest
@testable import PiApp

private final class SelectionReadGate: @unchecked Sendable {
    let entered: XCTestExpectation
    let resume = DispatchSemaphore(value: 0)
    init(entered: XCTestExpectation) { self.entered = entered }
    func hold() { entered.fulfill(); resume.wait() }
}

private extension MetadataStore {
    func holdSelectionReads(_ gate: SelectionReadGate) { gate.hold() }
}

final class WorkspaceLoadingTests: XCTestCase {
    private func folder() throws -> URL {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("workspace-loading-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func journal(_ count: Int, text: String = "original", path: URL) throws {
        var data = Data()
        let encoder = JSONEncoder()
        func append(_ value: [String: WireValue]) throws { data.append(try encoder.encode(value)); data.append(10) }
        try append(["type": .string("session"), "version": .number(3), "id": .string("a")])
        for index in 0..<count {
            // An odd count ends on a user; its newest60 starts on an assistant.
            try append(["type": .string("message"), "id": .string("m\(index)"),
                        "parentId": index == 0 ? .null : .string("m\(index - 1)"),
                        "message": .object(["role": .string(index % 2 == 0 ? "user" : "assistant"),
                                            "content": .string("\(text) \(index)")])])
        }
        try data.write(to: path, options: .atomic)
    }

    @MainActor private func fixture(root: URL, path: URL? = nil) async throws -> WorkspaceModel {
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        try await model.reloadConfiguration()
        model.chats = [ChatRecord(id: "a", workspaceID: "project", title: "A", path: path?.path, profileID: "profile"),
                       ChatRecord(id: "b", workspaceID: "project", title: "B", path: nil, profileID: "profile")]
        return model
    }

    @MainActor private func close(_ model: WorkspaceModel) async throws {
        model.shutdown(); try await model.traces.close(); await model.store?.close()
    }

    /// A chat opens on its newest page: whole turns, as many as a page's
    /// rows hold. An earlier page joins it, and a warm revisit after the
    /// reader moved up reads one page from the turn they were in. (Before
    /// 0.1.131 a page was the newest three turns.)
    @MainActor func testFreshSelectionAndWarmRevisitReadWholeTurnPages() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        // Turns of a question and a reply, and a last question on its own.
        let rows = 2 * HistoryWindowPolicy.pageRows + 501, page = HistoryWindowPolicy.pageRows, first = HistoryWindowPolicy.PageLimits.standard.opening.rows
        let path = root.appendingPathComponent("history.jsonl"); try journal(rows, path: path)
        let model = try await fixture(root: root, path: path)
        let started = ProcessInfo.processInfo.systemUptime
        await model.select("a")
        let view = try XCTUnwrap(model.selected)
        // A page back from the end, starting at a question: one row short of a page.
        XCTAssertEqual(view.messages.map(\.id), ((rows - first + 1)..<rows).map { "m\($0)" })
        model.historyViewportReady("a", generation: view.presentationGeneration)
        let loaded = await model.loadEarlierPage(sessionID: "a")
        XCTAssertTrue(loaded); XCTAssertEqual(view.messages.count, first + page - 1)
        XCTAssertEqual(view.messages.first?.id, "m\(rows - first - page + 1)", "The earlier page starts at a question too")
        view.scrollAnchor = .init(id: "m600", offset: 17, followsBottom: false)
        await model.select("b"); await model.select("a")
        // Still one bounded page, read from the turn the reader was in.
        XCTAssertEqual(view.messages.map(\.id), (600..<(600 + first)).map { "m\($0)" }); XCTAssertEqual(view.scrollAnchor?.id, "m600")
        XCTAssertTrue(model.hosts.isEmpty)
        print("FRESH selection+revisit source ms \((ProcessInfo.processInfo.systemUptime-started)*1000)")
        try await close(model)
    }

    @MainActor func testLargeCachedChatReopenReadsNoJournalBodies() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("large.jsonl")
        try journal(20_001, text: String(repeating: "Generated ordinary reply. ", count: 48), path: path)
        let bytes = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int)
        XCTAssertGreaterThan(bytes, 20_000_000)
        let model = try await fixture(root: root, path: path)
        let coldStart = ProcessInfo.processInfo.systemUptime
        await model.select("a")
        let cold = (ProcessInfo.processInfo.systemUptime - coldStart) * 1_000
        let display = try XCTUnwrap(model.selected)
        model.historyViewportReady("a", generation: display.presentationGeneration)
        XCTAssertEqual(display.historyState, .ready)
        try await eventually("The opening fill did not settle", timeout: .seconds(20)) { !display.presentation.openingPage }
        let messages = display.messages.map(\.id)
        let scans = await model.history.subagentScannedBytes
        let indexed = await model.history.indexedBytes, decoded = await model.history.decodedRecords
        let acceptance = await model.history.acceptanceScannedBytes
        var timings: [Double] = []
        for _ in 0..<5 {
            await model.select("b")
            let start = ProcessInfo.processInfo.systemUptime
            await model.select("a")
            timings.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            model.historyViewportReady("a", generation: display.presentationGeneration)
            XCTAssertTrue(model.selected === display)
            XCTAssertEqual(display.messages.map(\.id), messages)
            XCTAssertEqual(display.historyState, .ready)
        }
        let extraScans = await model.history.subagentScannedBytes - scans
        let extraIndexed = await model.history.indexedBytes - indexed
        let extraDecoded = await model.history.decodedRecords - decoded
        let extraAcceptance = await model.history.acceptanceScannedBytes - acceptance
        XCTAssertEqual(extraScans, 0, "Cached revisits must not rescan delegation plans, including chats without agents")
        XCTAssertEqual(extraIndexed, 0); XCTAssertEqual(extraDecoded, 0); XCTAssertEqual(extraAcceptance, 0)
        XCTAssertTrue(model.hosts.isEmpty)
        print("PERF cached-chat bytes=\(bytes) rows=20001 coldMs=\(cold) reopenMs=\(timings) extraSubagentBytes=\(extraScans) extraIndexedBytes=\(extraIndexed) extraDecoded=\(extraDecoded) extraAcceptanceBytes=\(extraAcceptance)")
        try await close(model)
    }

    @MainActor func testChangedJournalReloadsWhenReturningToCachedTab() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("history.jsonl"); try journal(120, path: path)
        let model = try await fixture(root: root, path: path)
        await model.select("a")
        let view = try XCTUnwrap(model.selected)
        XCTAssertEqual(view.messages.last?.id, "m119")
        await model.select("b")
        try journal(122, text: "updated!", path: path)
        await model.select("a")
        XCTAssertEqual(view.messages.last?.id, "m121")
        XCTAssertTrue(view.messages.allSatisfy { $0.text.hasPrefix("updated!") })
        try await close(model)
    }

    /// A turn longer than the resident window, which no page holds whole,
    /// continues across pages: the newest page holds its end and names the
    /// question it answers, and earlier pages read back to that question.
    @MainActor func testOversizedTurnUsesExplicitContinuationInsteadOfRepairBackfill() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("tools.jsonl"), encoder = JSONEncoder()
        let count = HistoryWindowPolicy.residentRows + 121
        var bytes = try encoder.encode(["type": WireValue.string("session"), "version": .number(3), "id": .string("a")]); bytes.append(10)
        for index in 0..<count {
            let role = index == 0 || index == 20 ? "user" : index % 2 == 0 ? "toolResult" : "assistant"
            let value: [String: WireValue] = ["type": .string("message"), "id": .string("m\(index)"),
                "parentId": index == 0 ? .null : .string("m\(index - 1)"),
                "message": .object(["role": .string(role), "content": .string("Evidence \(index)")])]
            bytes.append(try encoder.encode(value)); bytes.append(10)
        }
        try bytes.write(to: path)
        let model = try await fixture(root: root, path: path)
        await model.select("a")
        let view = try XCTUnwrap(model.selected)
        XCTAssertEqual(view.messages.count, HistoryWindowPolicy.residentRows); XCTAssertEqual(view.presentation.partialTurnInput, "m20")
        XCTAssertEqual(view.messages.last?.id, "m\(count - 1)")
        model.historyViewportReady("a", generation: view.presentationGeneration)
        var seen = Set(view.messages.map(\.id))
        while view.olderPage.cursor != nil {
            let loaded = await model.loadEarlierPage(sessionID: "a"); XCTAssertTrue(loaded)
            seen.formUnion(view.messages.map(\.id))
        }
        XCTAssertEqual(view.messages.first?.id, "m0")
        XCTAssertEqual(seen, Set((0..<count).map { "m\($0)" }), "Every row of the turn was read")
        XCTAssertLessThanOrEqual(view.messages.count, HistoryWindowPolicy.residentRows)
        try await close(model)
    }

    func testHistoryRevisionDetectsSameSizeReplacementAndInPlaceEditWithRestoredModificationTime() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("history.jsonl"), reader = HistoryReader()
        try journal(120, text: "original", path: path)
        let original = try await reader.read(path: path.path)
        let stamp = try FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate]
        try journal(120, text: "replaced", path: path)
        if let stamp { try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: path.path) }
        let replacement = try await reader.readIfChanged(path: path.path, since: original.revision)
        XCTAssertEqual(replacement?.messages.last?.text, "replaced 119")
        XCTAssertNotEqual(replacement?.revision, original.revision)
        var edited = try String(contentsOf: path, encoding: .utf8)
        edited = edited.replacingOccurrences(of: "replaced", with: "modified")
        let handle = try FileHandle(forWritingTo: path)
        try handle.write(contentsOf: Data(edited.utf8)); try handle.close()
        if let stamp { try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: path.path) }
        let modified = try await reader.readIfChanged(path: path.path, since: replacement?.revision)
        XCTAssertEqual(modified?.messages.last?.text, "modified 119")
        XCTAssertNotEqual(modified?.revision, replacement?.revision)
        let unchanged = try await reader.readIfChanged(path: path.path, since: modified?.revision)
        XCTAssertNil(unchanged)
    }

    func testWarmRevisionSurvivesIndexEvictionWithoutReprojectingItsPage() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = HistoryReader(), path = root.appendingPathComponent("long.jsonl")
        try journal(20_001, path: path)
        let coldStart = ProcessInfo.processInfo.systemUptime
        let original = try await reader.read(path: path.path)
        let cold = (ProcessInfo.processInfo.systemUptime - coldStart) * 1_000
        for index in 0..<4 {
            let other = root.appendingPathComponent("other-\(index).jsonl")
            try journal(2, path: other)
            _ = try await reader.read(path: other.path)
        }
        let warmStart = ProcessInfo.processInfo.systemUptime
        let unchanged = try await reader.readIfChanged(path: path.path, since: original.revision)
        let warm = (ProcessInfo.processInfo.systemUptime - warmStart) * 1_000
        XCTAssertNil(unchanged, "Retained UI pages remain reusable after the smaller offset-index cache evicts them")
        print(String(format: "PERF archive 20001 rows: cold index+page %.2f ms; warm stamp after index eviction %.2f ms", cold, warm))
        let handle = try FileHandle(forWritingTo: path); try handle.seekToEnd(); try handle.write(contentsOf: Data("{damaged".utf8)); try handle.close()
        let damaged = try await reader.readIfChanged(path: path.path, since: original.revision)
        XCTAssertNotNil(damaged?.notice); XCTAssertNil(damaged?.revision, "A damaged/incomplete journal must not be cached as a settled page")
    }

    @MainActor func testReturningBeforeDraftPersistenceCannotRestoreClearedText() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await fixture(root: root)
        try await model.store?.put(DraftRecord(id: "a", text: "Saved previous text"), kind: "draft", id: "a")
        await model.select("a")
        let view = try XCTUnwrap(model.selected)
        XCTAssertEqual(view.draft, "Saved previous text")
        // The current field is authoritative before its debounced empty save
        // reaches SQLite. Returning must not resurrect the older stored value.
        view.draft = ""
        await model.select("b"); await model.select("a")
        XCTAssertEqual(view.draft, "")
        try await model.flushDrafts()
        let persisted = try await model.store?.get(DraftRecord.self, kind: "draft", id: "a")
        XCTAssertEqual(persisted?.text, "")
        try await close(model)
    }

    @MainActor func testRapidAwayAndBackSelectionRejectsOlderHydrationCompletion() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await fixture(root: root), store = try XCTUnwrap(model.store)
        try await store.put(DraftRecord(id: "a", text: "Saved A"), kind: "draft", id: "a")
        let entered = expectation(description: "Metadata actor held"), gate = SelectionReadGate(entered: entered)
        let blocker = Task { await store.holdSelectionReads(gate) }
        await fulfillment(of: [entered], timeout: 2)
        func waitFor(_ id: String) async {
            let deadline = Date().addingTimeInterval(2)
            while model.selectedID != id, Date() < deadline { await Task.yield() }
            XCTAssertEqual(model.selectedID, id)
        }
        let first = Task { await model.select("a") }; await waitFor("a")
        let second = Task { await model.select("b") }; await waitFor("b")
        let latest = Task { await model.select("a") }; await waitFor("a")
        gate.resume.signal()
        await blocker.value; await first.value; await second.value; await latest.value
        let view = try XCTUnwrap(model.selected)
        XCTAssertEqual(view.id, "a"); XCTAssertEqual(view.draft, "Saved A")
        XCTAssertEqual(view.composerFocusRequest, 1, "Only the current selection may refocus the composer or publish readiness")
        XCTAssertEqual(model.displays["b"]?.composerFocusRequest, 0)
        XCTAssertTrue(view.draftReady)
        try await close(model)
    }
}

/// Holds a history read until the test lets it go.
private actor LoadingReadGate {
    private(set) var reads = 0
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func read() async {
        reads += 1
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() { open = true; waiting.forEach { $0.resume() }; waiting = [] }
}

extension WorkspaceLoadingTests {
    /// A chat's file can be named while its page is being read: the first
    /// message of a new chat writes the journal, and the helper can report a
    /// moved one. The read that was in flight belonged to the old name. It
    /// used to be dropped with nothing read in its place, which left
    /// "Preparing…" up for good, and clicking the chat again did nothing.
    @MainActor func testAChatWhoseFileIsNamedWhileItLoadsStillFinishesLoading() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await fixture(root: root)
        let gate = LoadingReadGate()
        let page = try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("fixture"), "lineage": .string("root"),
            "messages": .array([.object(["id": .string("q"), "role": .string("user"), "text": .string("Question")])]), "older": .null, "newer": .null]))
        model.historyWindowLoader = { _, _, _, _ in await gate.read(); return page }
        let selecting = Task { await model.select("a") }
        for _ in 0..<500 { if await gate.reads == 1 { break }; try await Task.sleep(for: .milliseconds(2)) }
        let view = try XCTUnwrap(model.displays["a"])
        XCTAssertEqual(view.historyState, .loading)
        model.chats[0].path = root.appendingPathComponent("a.jsonl").path
        await gate.release()
        await selecting.value
        XCTAssertNotEqual(view.historyState, .loading, "The chat finished loading under its new name")
        XCTAssertEqual(view.messages.map(\.id), ["q"])
        let reads = await gate.reads
        XCTAssertEqual(reads, 2, "The page is read again for the file it now has")

        // A load that ended without a page leaves the chat clickable.
        view.presentation.begin(); view.historyState = .loading
        XCTAssertNil(view.presentation.navigation)
        await model.select("a")
        XCTAssertNotEqual(view.historyState, .loading, "Clicking a chat stuck loading reads it again")
        try await close(model)
    }
}

extension WorkspaceLoadingTests {
    /// A selection overtaken before its saved draft is read leaves the chat's
    /// display alive with an empty composer that is not the user's. Quit and
    /// update wrote it over the draft on disk.
    @MainActor func testQuitKeepsTheSavedDraftOfASelectionThatNeverLoadedIt() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await fixture(root: root), store = try XCTUnwrap(model.store)
        try await store.put(DraftRecord(id: "a", text: "Saved A"), kind: "draft", id: "a")
        let entered = expectation(description: "Metadata actor held"), gate = SelectionReadGate(entered: entered)
        let blocker = Task { await store.holdSelectionReads(gate) }
        await fulfillment(of: [entered], timeout: 2)
        let first = Task { await model.select("a") }
        for _ in 0..<500 where model.selectedID != "a" { await Task.yield() }
        let second = Task { await model.select("b") }
        for _ in 0..<500 where model.selectedID != "b" { await Task.yield() }
        gate.resume.signal()
        await blocker.value; await first.value; await second.value
        XCTAssertEqual(model.displays["a"]?.selectionMetadataLoaded, false, "The overtaken selection never read A's draft")
        try await model.flushDrafts()
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: "a")
        XCTAssertEqual(saved?.text, "Saved A")
        try await close(model)
    }

    /// Closing a saved side before its saved draft was read wrote the empty
    /// composer over it.
    @MainActor func testClosingASideBeforeItsDraftLoadedKeepsTheSavedDraft() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await fixture(root: root), store = try XCTUnwrap(model.store)
        model.chats[1].parentSessionID = "a"
        try await store.put(DraftRecord(id: "b", text: "Side text"), kind: "draft", id: "b")
        let view = model.mountSide(model.chats[1], beside: "a")
        XCTAssertFalse(view.selectionMetadataLoaded)
        model.closeSide("b")
        for _ in 0..<500 where model.sides["a"] != nil || view.loading { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNil(model.sides["a"], "The side closed")
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: "b")
        XCTAssertEqual(saved?.text, "Side text")
        try await close(model)
    }

    /// Closing a saved side writes its draft before it lets go. A second side
    /// opened on the same chat during that write was the one removed.
    @MainActor func testClosingASideLeavesASideOpenedDuringItsCloseInPlace() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await fixture(root: root)
        model.chats[1].parentSessionID = "a"
        var second = ChatRecord(id: "c", workspaceID: "project", title: "C", path: nil, profileID: "profile"); second.parentSessionID = "a"
        model.chats.append(second)
        let first = model.mountSide(model.chats[1], beside: "a")
        first.selectionMetadataLoaded = true
        model.closeSide("b")
        _ = model.mountSide(second, beside: "a")
        model.focusedSessionID = "c"
        for _ in 0..<500 where first.loading { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertFalse(first.loading)
        XCTAssertEqual(model.sides["a"]?.id, "c", "The side opened meanwhile stays open")
        XCTAssertEqual(model.focusedSessionID, "c", "and keeps the cursor")
        try await close(model)
    }

    /// A helper event for a chat nobody is showing (a settings change reaches
    /// every loaded session) builds it an empty display. Quit wrote that
    /// empty draft over the saved one.
    @MainActor func testQuitKeepsTheSavedDraftOfADisplayAHelperEventRebuilt() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await fixture(root: root), store = try XCTUnwrap(model.store)
        try await store.put(DraftRecord(id: "a", text: "keep me"), kind: "draft", id: "a")
        model.hosts["project"] = HostSupervisor(); model.opened.insert("a")
        model.refresh("a")
        XCTAssertEqual(model.displays["a"]?.draft, "")
        try await model.flushDrafts()
        let saved = try await store.get(DraftRecord.self, kind: "draft", id: "a")
        XCTAssertEqual(saved?.text, "keep me")
        model.hosts.removeAll(); model.opened.removeAll()
        try await close(model)
        let reopened = try await fixture(root: root)
        await reopened.select("a")
        XCTAssertEqual(reopened.selected?.draft, "keep me")
        try await close(reopened)
    }
}
