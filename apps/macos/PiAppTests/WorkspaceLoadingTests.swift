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

    @MainActor func testFreshThreeTurnSelectionAndWarmRevisitStayBounded() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("history.jsonl"); try journal(1_001, path: path)
        let model = try await fixture(root: root, path: path)
        let started = ProcessInfo.processInfo.systemUptime
        await model.select("a")
        let view = try XCTUnwrap(model.selected)
        XCTAssertEqual(view.messages.map(\.id), (996..<1001).map { "m\($0)" })
        model.historyViewportReady("a", generation: view.presentationGeneration)
        let loaded = await model.loadEarlierPage(sessionID: "a")
        XCTAssertTrue(loaded); XCTAssertEqual(view.messages.count, 11)
        view.scrollAnchor = .init(id: "m990", offset: 17, followsBottom: false)
        await model.select("b"); await model.select("a")
        XCTAssertEqual(view.messages.count, 5); XCTAssertNil(view.scrollAnchor)
        XCTAssertTrue(model.hosts.isEmpty)
        print("FRESH selection+revisit source ms \((ProcessInfo.processInfo.systemUptime-started)*1000)")
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

    @MainActor func testOversizedTurnUsesExplicitContinuationInsteadOfRepairBackfill() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("tools.jsonl"), encoder = JSONEncoder()
        var bytes = try encoder.encode(["type": WireValue.string("session"), "version": .number(3), "id": .string("a")]); bytes.append(10)
        for index in 0..<121 {
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
        XCTAssertEqual(view.messages.count, 60); XCTAssertEqual(view.presentation.partialTurnInput, "m20")
        model.historyViewportReady("a", generation: view.presentationGeneration)
        while view.olderPage.cursor != nil { let loaded = await model.loadEarlierPage(sessionID: "a"); XCTAssertTrue(loaded) }
        XCTAssertEqual(view.messages.map(\.id), (0..<121).map { "m\($0)" })
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
