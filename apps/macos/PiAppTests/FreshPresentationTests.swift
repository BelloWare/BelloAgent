import XCTest
import SwiftUI
@testable import PiApp

final class FreshPresentationTests: XCTestCase {
    private actor Gate {
        var entered: [String] = []
        var waiting: [CheckedContinuation<ConversationHistoryPage, Error>] = []
        func read(_ id: String) async throws -> ConversationHistoryPage {
            entered.append(id)
            return try await withCheckedThrowingContinuation { waiting.append($0) }
        }
        func finish(_ index: Int, page: ConversationHistoryPage) { waiting[index].resume(returning: page) }
        var count: Int { waiting.count }
    }
    private func page(_ id: String) throws -> ConversationHistoryPage {
        try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string(id), "lineage": .string("root"),
            "messages": .array([.object(["id": .string(id), "role": .string("assistant"), "text": .string(id)])]), "older": .null, "newer": .null]))
    }
    func testNonoverlappingLiveTailDoesNotEraseHistory() {
        let history = [TranscriptMessage(id: "old", role: "user", text: "Reading here")]
        let live = [TranscriptMessage(id: "new", role: "assistant", text: "A later reply")]
        XCTAssertEqual(TranscriptPaging.merge(previous: history, live: live).map(\.id), ["old"],
                       "A missing overlap is a gap, not proof that history was edited")
    }
    private func folder() throws -> URL {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("fresh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func journal(_ count: Int, root: URL, large: Bool = false, largeLines: Int = 1_200, userEvery: Int = 2, rich: Bool = false) throws -> URL {
        let file = root.appendingPathComponent("history.jsonl"), encoder = JSONEncoder()
        var bytes = try encoder.encode(["type": WireValue.string("session"), "version": .number(3), "id": .string("a")]); bytes.append(10)
        for i in 0..<count {
            bytes.append(try encoder.encode(["type": WireValue.string("message"), "id": .string("m\(i)"),
                "parentId": i == 0 ? .null : .string("m\(i-1)"),
                "message": .object(["role": .string(i % userEvery == 0 ? "user" : "assistant"),
                    "content": .string(large ? String(repeating: "Evidence\n", count: largeLines) : rich && i % userEvery != 0 ? "## Module \(i)\n\n" + String(repeating: "A **bounded** paragraph with `code` and useful details. ", count: 18) + "\n\n~~~swift\nlet value = inspect()\n~~~" : "Message \(i)")])]))
            bytes.append(10)
        }
        try bytes.write(to: file); return file
    }
    /// A chat past both of the resident window's caps. The app's caps are
    /// 500 rows and 4,000,000 bytes, which 1,100 messages of 10,800 bytes
    /// pass 2.2 and 3.1 times over, the byte cap binding at 353 rows. The
    /// caps are lowered here to the same shape at a size a test pages
    /// through in moments: 66 messages of 900 bytes (1,412 as the window
    /// counts them) pass 30 rows and 30,000 bytes 2.2 and 3.1 times over,
    /// the byte cap binding at 21 rows.
    private static let pastCaps = (messages: 66, lines: 100, rows: 30, bytes: 30_000)
    private func lowerResidentCaps() -> (rows: Int, bytes: Int) {
        let app = TranscriptPaging.residentCaps
        TranscriptPaging.residentCaps = (Self.pastCaps.rows, Self.pastCaps.bytes)
        addTeardownBlock { TranscriptPaging.residentCaps = app }
        return TranscriptPaging.residentCaps
    }
    /// The chat really is longer than the row cap and larger than the byte cap.
    @MainActor private func assertPassesBothCaps(_ view: SessionDisplay, count: Int, _ caps: (rows: Int, bytes: Int),
                                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let perRow = TranscriptPaging.size(try XCTUnwrap(view.messages.first, file: file, line: line))
        XCTAssertGreaterThan(count, caps.rows, "the chat must be longer than the row cap", file: file, line: line)
        XCTAssertGreaterThan(count * perRow, caps.bytes, "the chat must be larger than the byte cap", file: file, line: line)
    }
    @MainActor private func model(_ root: URL, path: URL? = nil) async throws -> WorkspaceModel {
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        try await model.reloadConfiguration()
        model.chats = [ChatRecord(id: "a", workspaceID: "project", title: "A", path: path?.path, profileID: "profile"),
                       ChatRecord(id: "b", workspaceID: "project", title: "B", path: nil, profileID: "profile")]
        addTeardownBlock { @MainActor in model.shutdown(); try await model.traces.close(); await model.store?.close() }
        return model
    }
    func testStoredThreeTurnsAndExhaustiveBidirectionalTraversalPastIndexSegment() async throws {
        let root = try folder(), path = try journal(2_402, root: root), reader = HistoryReader()
        await reader.setIndexRecordLimit(19)
        var page = try await reader.window(path: path.path)
        XCTAssertEqual(page.messages.map(\.id), (2396..<2402).map { "m\($0)" })
        var backward = page.messages.map(\.id)
        while let cursor = page.older {
            page = try await reader.window(path: path.path, cursor: cursor)
            XCTAssertFalse(page.messages.isEmpty); XCTAssertLessThanOrEqual(page.messages.count, 60)
            backward = page.messages.map(\.id) + backward
        }
        XCTAssertEqual(backward, (0..<2402).map { "m\($0)" })
        var forward = page.messages.map(\.id)
        while let cursor = page.newer {
            page = try await reader.window(path: path.path, cursor: cursor, newer: true)
            XCTAssertFalse(page.messages.isEmpty)
            forward += page.messages.map(\.id)
        }
        XCTAssertEqual(forward, backward)
        XCTAssertNil(page.limitNotice, "An index work segment is not an archive limit")
    }
    func testOversizedTurnSegmentsKeepInputReferenceAndFullContentAccess() async throws {
        let root = try folder(), path = try journal(401, root: root, large: true, userEvery: 500), reader = HistoryReader()
        let page = try await reader.window(path: path.path)
        XCTAssertLessThan(page.messages.count, 60)
        XCTAssertEqual(page.partialTurnInput, "m0")
        XCTAssertNotNil(page.older)
        let bytes = try JSONEncoder().encode(page.messages).count
        XCTAssertLessThan(bytes + HistoryWindowPolicy.metadataAllowance, HistoryWindowPolicy.envelopeBytes)
        let (text, total) = try await reader.message(path: path.path, id: "m0", field: "text", offset: 0)
        XCTAssertEqual(text.utf8.count, total)
    }
    func testAppendKeepsCursorValidButRewriteAndIncompleteTailDoNot() async throws {
        let root = try folder(), path = try journal(20, root: root), reader = HistoryReader()
        let page = try await reader.window(path: path.path), cursor = try XCTUnwrap(page.older)
        let h = try FileHandle(forWritingTo: path); try h.seekToEnd()
        try h.write(contentsOf: Data("{\"type\":\"message\",\"id\":\"m20\",\"parentId\":\"m19\",\"message\":{\"role\":\"user\",\"content\":\"Appended\"}}\n".utf8)); try h.close()
        let earlier = try await reader.window(path: path.path, cursor: cursor)
        XCTAssertEqual(earlier.messages.last?.id, "m13")
        let edit = try FileHandle(forUpdating: path); let original = try Data(contentsOf: path)
        let changed = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "Message 0", with: "Revised 0")
        try edit.seek(toOffset: 0); try edit.write(contentsOf: Data(changed.utf8)); try edit.close()
        do { _ = try await reader.window(path: path.path, cursor: cursor); XCTFail("Changed prefix accepted") } catch { }
        let tail = try FileHandle(forWritingTo: path); try tail.seekToEnd(); try tail.write(contentsOf: Data("{unfinished".utf8)); try tail.close()
        let broken = try await reader.window(path: path.path)
        XCTAssertNotNil(broken.notice)
        // A cut-off last line no longer hides the chat: every complete record
        // before it opens read-only, marked as a damaged tail.
        XCTAssertTrue(broken.incompleteTail)
        let readable = try ConversationHistoryPage(broken)
        XCTAssertTrue(readable.damagedTail)
        XCTAssertEqual(readable.messages.last?.id, broken.messages.last?.id, "the complete prefix is shown")
        XCTAssertFalse(readable.messages.isEmpty)
    }
    @MainActor func testFreshRevisitAndIdempotentSelectionPreserveDraftAndRuntime() async throws {
        let root = try folder(), path = try journal(40, root: root), model = try await model(root, path: path)
        await model.select("a")
        let view = try XCTUnwrap(model.selected), generation = view.presentationGeneration
        XCTAssertEqual(view.historyState, .preparing); XCTAssertEqual(view.messages.count, 6)
        model.historyViewportReady("a", generation: generation)
        view.draft = "Do not overwrite this"
        let loaded = await model.loadEarlierPage(sessionID: "a"); XCTAssertTrue(loaded)
        XCTAssertEqual(view.messages.count, 12)
        await model.select("a")
        XCTAssertEqual(view.presentationGeneration, generation)
        await model.select("b"); await model.select("a")
        XCTAssertNotEqual(view.presentationGeneration, generation)
        XCTAssertEqual(view.messages.count, 6); XCTAssertEqual(view.messages.first?.id, "m34")
        XCTAssertEqual(view.draft, "Do not overwrite this"); XCTAssertTrue(model.hosts.isEmpty)
    }
    /// Returning to a chat whose rows are cached keeps them on the page while
    /// the fresh page is read and placed: no cover fades over them. A chat
    /// never shown is still covered while it loads.
    @MainActor func testRevisitKeepsCachedRowsUncoveredWhileTheFreshPageLoads() async throws {
        let root = try folder(), model = try await model(root), gate = Gate()
        model.historyWindowLoader = { id, _, _, _ in try await gate.read(id) }
        let first = Task { await model.select("a") }
        while await gate.count < 1 { await Task.yield() }
        let view = try XCTUnwrap(model.selected)
        XCTAssertTrue(ConversationPane.coversTranscript(view), "A chat never shown is covered while it loads")
        try await gate.finish(0, page: page("cached")); await first.value
        XCTAssertTrue(ConversationPane.coversTranscript(view), "Its first page is placed behind the cover")
        model.historyViewportReady("a", generation: view.presentationGeneration)
        XCTAssertFalse(ConversationPane.coversTranscript(view))
        let away = Task { await model.select("b") }
        while await gate.count < 2 { await Task.yield() }
        try await gate.finish(1, page: page("b")); await away.value
        let revisit = Task { await model.select("a") }
        while await gate.count < 3 { await Task.yield() }
        XCTAssertEqual(view.historyState, .loading)
        XCTAssertFalse(ConversationPane.coversTranscript(view), "The cached rows were covered while the fresh page was read")
        XCTAssertEqual(view.presentedMessages.map(\.id), ["cached"], "The cached rows left the page while the fresh page was read")
        try await gate.finish(2, page: page("fresh")); await revisit.value
        XCTAssertEqual(view.historyState, .preparing); XCTAssertEqual(view.presentedMessages.map(\.id), ["fresh"])
        XCTAssertFalse(ConversationPane.coversTranscript(view), "The fresh page was placed behind a cover")
        model.historyViewportReady("a", generation: view.presentationGeneration)
        XCTAssertEqual(view.historyState, .ready); XCTAssertFalse(view.refreshingCachedRows)
        // An explicit reload still reads behind the cover.
        model.reloadHistory("a")
        XCTAssertTrue(ConversationPane.coversTranscript(view))
        while await gate.count < 4 { await Task.yield() }
        try await gate.finish(3, page: page("reloaded")); await view.presentation.navigation?.value
    }
    @MainActor func testFailedEarlierRequestCanRetryAtSameBoundary() async throws {
        let root = try folder(), path = try journal(40, root: root), model = try await model(root, path: path)
        await model.select("a")
        let view = try XCTUnwrap(model.selected)
        model.historyViewportReady("a", generation: view.presentationGeneration)
        let cursor = view.olderPage.cursor
        model.historyWindowLoader = { _, _, _, _ in throw HostError.failure("Transient fixture failure") }
        let failed = await model.loadEarlierPage(sessionID: "a"); XCTAssertFalse(failed)
        XCTAssertEqual(view.olderPage.cursor, cursor); XCTAssertNotNil(view.olderPage.error)
        model.historyWindowLoader = nil
        let loaded = await model.loadEarlierPage(sessionID: "a"); XCTAssertTrue(loaded)
        XCTAssertNil(view.olderPage.error); XCTAssertEqual(view.messages.first?.id, "m28")
    }
    @MainActor func testMovingWindowRevealsRequestedRowsPastRowAndByteCaps() async throws {
        let caps = lowerResidentCaps(), count = Self.pastCaps.messages
        let root = try folder(), path = try journal(count, root: root, large: true, largeLines: Self.pastCaps.lines)
        let model = try await model(root, path: path)
        await model.select("a")
        let view = try XCTUnwrap(model.selected), native = TranscriptPage()
        try assertPassesBothCaps(view, count: count, caps)
        model.historyViewportReady("a", generation: view.presentationGeneration)
        native.bind(view)
        var firsts = [String]()
        while view.olderPage.cursor != nil {
            let previous = view.messages.first?.id
            let loaded = await model.loadEarlierPage(sessionID: "a"); XCTAssertTrue(loaded)
            XCTAssertNotEqual(view.messages.first?.id, previous)
            firsts.append(view.messages.first!.id)
            XCTAssertEqual(native.snapshot?.messages.first?.id, view.messages.first?.id)
            XCTAssertLessThanOrEqual(view.messages.count, caps.rows)
            XCTAssertLessThanOrEqual(view.messages.reduce(0) { $0 + TranscriptPaging.size($1) }, caps.bytes)
        }
        XCTAssertEqual(firsts.last, "m0"); XCTAssertNotNil(view.newerPage.cursor)
        while view.newerPage.cursor != nil { let loaded = await model.loadHistoryPage("a", newer: true); XCTAssertTrue(loaded) }
        XCTAssertEqual(view.messages.last?.id, "m\(count - 1)")
    }
    @MainActor func testRapidABARejectsObsoleteSourceAndKeepsTypingWhileLoading() async throws {
        let root = try folder(), model = try await model(root), gate = Gate()
        model.historyWindowLoader = { id, _, _, _ in try await gate.read(id) }
        let first = Task { await model.select("a") }
        while await gate.count < 1 { await Task.yield() }
        let a = try XCTUnwrap(model.selected), firstGeneration = a.presentationGeneration
        XCTAssertEqual(a.historyState, .loading); XCTAssertTrue(a.presentedMessages.isEmpty); XCTAssertTrue(a.draftReady)
        a.draft = "Typed during hydration"
        let second = Task { await model.select("b") }
        while await gate.count < 2 { await Task.yield() }
        let third = Task { await model.select("a") }
        while await gate.count < 3 { await Task.yield() }
        try await gate.finish(2, page: page("current")); await third.value
        try await gate.finish(0, page: page("obsolete A")); await first.value
        try await gate.finish(1, page: page("obsolete B")); await second.value
        XCTAssertNotEqual(a.presentationGeneration, firstGeneration)
        XCTAssertEqual(a.messages.map(\.id), ["current"])
        XCTAssertEqual(a.draft, "Typed during hydration"); XCTAssertEqual(a.historyState, .preparing)
        model.historyViewportReady("a", generation: firstGeneration)
        XCTAssertEqual(a.historyState, .preparing, "An old draw callback cannot reveal revisited A")
        model.historyViewportReady("a", generation: a.presentationGeneration)
        XCTAssertEqual(a.historyState, .ready)
    }
    @MainActor func testOnlyOnePageRequestAndCancelledGenerationCannotClearNewLoading() async throws {
        let root = try folder(), path = try journal(40, root: root), model = try await model(root, path: path), gate = Gate()
        await model.select("a")
        let view = try XCTUnwrap(model.selected)
        model.historyViewportReady("a", generation: view.presentationGeneration)
        model.historyWindowLoader = { id, _, _, _ in try await gate.read(id) }
        let first = Task { await model.loadEarlierPage(sessionID: "a") }
        while await gate.count < 1 { await Task.yield() }
        let duplicate = await model.loadEarlierPage(sessionID: "a"); XCTAssertFalse(duplicate)
        let count = await gate.count; XCTAssertEqual(count, 1)
        model.reloadHistory("a")
        while await gate.count < 2 { await Task.yield() }
        try await gate.finish(0, page: page("obsolete")); _ = await first.value
        XCTAssertEqual(view.historyState, .loading)
        try await gate.finish(1, page: page("current")); await view.presentation.navigation?.value
        XCTAssertEqual(view.messages.map(\.id), ["current"])
    }
    func testCodeSectionsRetainEveryUTF8ByteIncludingHugeUnbrokenLines() {
        for source in [String(repeating: "let word = \"中文🙂\"\n", count: 2000), String(repeating: "中文🙂", count: 10_000)] {
            let ranges = CodeBlockSections.ranges(source), bytes = Array(source.utf8)
            XCTAssertGreaterThan(ranges.count, 1)
            let restored = ranges.map { String(decoding: bytes[$0], as: UTF8.self) }.joined()
            XCTAssertEqual(restored, source)
            XCTAssertTrue(ranges.allSatisfy { $0.count <= 8192 })
        }
    }
    @MainActor func testKnownEmptyMalformedAndOverlapNeverPretendToBeEOF() async throws {
        let root = try folder(), path = try journal(0, root: root), model = try await model(root, path: path)
        await model.select("a"); XCTAssertEqual(model.selected?.historyState, .empty)
        await model.select("b"); XCTAssertEqual(model.selected?.historyState, .empty)
        try Data("{\"type\":\"custom\",\"id\":\"invalid\"}\n".utf8).write(to: path)
        await model.select("a")
        guard case .failed = model.selected?.historyState else { return XCTFail("Missing session header claimed empty") }
        _ = try journal(40, root: root)
        model.reloadHistory("a"); await model.selected?.presentation.navigation?.value
        let view = try XCTUnwrap(model.selected)
        model.historyViewportReady("a", generation: view.presentationGeneration)
        let old = view.olderPage.cursor, ids = view.messages.map(\.id)
        let overlapping = try ConversationHistoryPage(await model.history.window(path: path.path))
        model.historyWindowLoader = { _, _, _, _ in overlapping }
        let loaded = await model.loadEarlierPage(sessionID: "a")
        XCTAssertFalse(loaded); XCTAssertEqual(view.olderPage.cursor, old)
        XCTAssertEqual(view.messages.map(\.id), ids); XCTAssertNotNil(view.olderPage.error)
    }
    @MainActor func testNativeDocumentAdoptsOlderCoverageBeyondBothResidentCaps() async throws {
        let caps = lowerResidentCaps(), count = Self.pastCaps.messages
        let root = try folder(), path = try journal(count, root: root, large: true, largeLines: Self.pastCaps.lines)
        let model = try await model(root, path: path)
        await model.select("a")
        let view = try XCTUnwrap(model.selected)
        try assertPassesBothCaps(view, count: count, caps)
        model.historyViewportReady("a", generation: view.presentationGeneration)
        let pane = TranscriptFrameBudgetTests.Pane(view)
        defer { pane.close() }
        await pane.settle()
        while view.olderPage.cursor != nil {
            let loaded = await model.loadEarlierPage(sessionID: "a"); XCTAssertTrue(loaded)
        }
        await pane.settle()
        let document = try XCTUnwrap(pane.document), page = try XCTUnwrap(pane.page)
        XCTAssertTrue(document.retainedRows.contains { $0.itemID == "m0" }, "The requested prefix must reach the actual native document")
        XCTAssertFalse(document.retainedRows.contains { $0.itemID == "m\(count - 2)" }, "Far newer content is evicted, not the newly fetched prefix")
        let target = try XCTUnwrap(page.rowFrame(of: "m0")), scroll = try XCTUnwrap(pane.scroll)
        page.readerWillNavigate(upward: true)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: target.minY))
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        await pane.settle()
        XCTAssertTrue(document.subviews.contains { ($0 as? TranscriptRowContainer)?.itemID == "m0" })
        XCTAssertNotNil(view.newerPage.cursor)
        model.latest(sessionID: "a"); await view.presentation.navigation?.value
        await pane.settle()
        XCTAssertEqual(view.messages.last?.id, "m\(count - 1)"); XCTAssertEqual(view.messages.count, 6)
        XCTAssertTrue(document.retainedRows.contains { $0.itemID == "m\(count - 2)" })
    }
    @MainActor func testFiftyFreshNativePresentationsAndRichThresholds() async throws {
        let session = SessionDisplay(id: "first"), pane = TranscriptFrameBudgetTests.Pane(session)
        defer { pane.close(); TranscriptLayoutClock.recording = false }
        var timings: [Double] = [], units: [Double] = []
        var departed: [WeakSession] = []
        for iteration in 0..<55 {
            let count = iteration < 50 ? 6 : [3, 8, 16, 32, 33][iteration - 50]
            let display = SessionDisplay(id: "visit-\(iteration)")
            display.presentation.begin(); display.presentationGeneration = display.presentation.generation
            display.historyState = .loading
            pane.hosted.rootView = NativeTranscriptView(session: display, actions: TranscriptActions(), onViewportReady: { [weak display] _, generation in
                guard let display, display.presentationGeneration == generation else { return }
                display.historyState = .ready
            })
            await pane.settle(turns: 2)
            XCTAssertTrue(pane.document?.retainedRows.isEmpty != false, "A fresh loading destination cannot display the prior transcript")
            display.historyState = .preparing
            let began = ProcessInfo.processInfo.systemUptime
            display.messages = (0..<count).map { i in
                .init(id: "v\(iteration)-m\(i)", role: i % 2 == 0 ? "user" : "assistant",
                      text: i % 2 == 0 ? "Inspect module \(i)" : "## Findings\n\n" + String(repeating: "A **bounded** paragraph with `code` and useful details. ", count: 18) + "\n\n~~~swift\nlet value = inspect()\n~~~")
            }
            let deadline = began + 5
            repeat {
                let frame = pane.frame({})
                units.append((frame.layout + frame.model + frame.display) * 1000)
                await Task.yield()
            } while display.historyState != .ready && ProcessInfo.processInfo.systemUptime < deadline
            XCTAssertEqual(display.historyState, .ready)
            pane.window.displayIfNeeded()
            let ms = (ProcessInfo.processInfo.systemUptime - began) * 1000
            if iteration < 50 { timings.append(ms) }
            else { print("FRESH native rich rows \(count): useful draw opportunity \(ms) ms; hosted \(pane.document?.hostedRowCount ?? -1)") }
            XCTAssertTrue(pane.document?.visibleContentPrepared == true)
            XCTAssertEqual(pane.page?.snapshot?.sessionID, display.id)
            departed.append(WeakSession(display))
        }
        await pane.settle()
        XCTAssertLessThanOrEqual(departed.filter { $0.value != nil }.count, 1, "Outgoing generations do not accumulate retained sessions")
        let sorted = timings.sorted(), work = units.sorted()
        print("FRESH 50 UI generations p50=\(sorted[25]) p95=\(sorted[47]) max=\(sorted.last!) ms; layout/draw work p95=\(work[Int(Double(work.count-1)*0.95)]) p99=\(work[Int(Double(work.count-1)*0.99)]) max=\(work.last!) ms")
        XCTAssertLessThan(sorted[47], releaseBudget(0.200) * 1_000, "p95 of fifty fresh presentations")
    }
    @MainActor private final class WeakSession {
        weak var value: SessionDisplay?
        init(_ value: SessionDisplay) { self.value = value }
    }

    @MainActor func testColdThenIndexedSelectionThroughUsefulNativeDraw() async throws {
        let root = try folder(), path = try journal(2_000, root: root, rich: true), model = try await model(root, path: path)
        let view = SessionDisplay(id: "a")
        model.displays["a"] = view
        let pane = TranscriptFrameBudgetTests.Pane(view, onReady: { model.historyViewportReady($0, generation: $1) })
        defer { pane.close() }
        var draws: [Double] = [], sources: [Double] = [], feedback: [Double] = []
        for visit in 0..<21 {
            if visit > 0 { await model.select("b") }
            let invoked = PerformanceProbe.now
            let selection = Task { await model.select("a") }
            while model.selectedID != "a" { await Task.yield() }
            feedback.append(PerformanceProbe.now - invoked)
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            repeat {
                _ = pane.frame({})
                await Task.yield()
            } while view.presentation.drawOpportunityAt == nil && ProcessInfo.processInfo.systemUptime < deadline
            await selection.value
            XCTAssertEqual(view.historyState, .ready)
            let source = try XCTUnwrap(view.presentation.sourceReadyAt) - invoked
            let draw = try XCTUnwrap(view.presentation.drawOpportunityAt) - invoked
            XCTAssertTrue(pane.document?.visibleContentPrepared == true)
            XCTAssertEqual(view.messages.map(\.id), (1994..<2000).map { "m\($0)" })
            if visit == 0 {
                print("FRESH cold file bytes=\(try Data(contentsOf: path).count) records=2001 source=\(source) usefulDraw=\(draw) ms")
            } else { sources.append(source); draws.append(draw) }
        }
        let times = draws.sorted(), sourceTimes = sources.sorted(), feedbackTimes = feedback.sorted()
        print("FRESH 20 indexed source+UI p50=\(times[10]) p95=\(times[18]) max=\(times[19]) ms; source p95=\(sourceTimes[18]) ms; selection feedback p95=\(feedbackTimes[19]) ms")
        XCTAssertLessThan(times[18], releaseBudget(0.200) * 1_000, "p95 of indexed source and UI")
        XCTAssertLessThan(feedbackTimes[19], releaseBudget(0.050) * 1_000, "worst selection feedback")
        XCTAssertTrue(model.hosts.isEmpty, "Display-only history must not launch an agent")
    }

    @MainActor func testRapidABCOnlyFinalSelectionCanPublishOrFocus() async throws {
        let root = try folder(), model = try await model(root), gate = Gate()
        model.chats.append(ChatRecord(id: "c", workspaceID: "project", title: "C", path: nil, profileID: "profile"))
        model.historyWindowLoader = { id, _, _, _ in try await gate.read(id) }
        let first = Task { await model.select("a") }
        while await gate.count < 1 { await Task.yield() }
        let second = Task { await model.select("b") }
        while await gate.count < 2 { await Task.yield() }
        let third = Task { await model.select("c") }
        while await gate.count < 3 { await Task.yield() }
        try await gate.finish(2, page: page("current C")); await third.value
        try await gate.finish(1, page: page("obsolete B")); await second.value
        try await gate.finish(0, page: page("obsolete A")); await first.value
        XCTAssertEqual(model.selectedID, "c"); XCTAssertEqual(model.focusedSessionID, "c")
        XCTAssertEqual(model.selected?.messages.map(\.id), ["current C"])
        XCTAssertTrue(model.displays["a"]?.presentedMessages.isEmpty == true)
        XCTAssertTrue(model.displays["b"]?.presentedMessages.isEmpty == true)
    }

    @MainActor func testMainAndEphemeralSideHydrateIndependentlyWithoutInventingDiskHistory() async throws {
        let root = try folder(), model = try await model(root), gate = Gate()
        let side = SessionDisplay(id: "side")
        side.draft = "Keep the side draft"
        model.sides["a"] = SideRecord(id: "side", parentID: "a", workspaceID: "project", profileID: "profile", title: "Side")
        model.displays["side"] = side
        try await model.store?.put(DraftRecord(id: "side", text: "Older saved draft"), kind: "draft", id: "side")
        model.historyWindowLoader = { id, _, _, _ in try await gate.read(id) }
        let selection = Task { await model.select("a") }
        while await gate.count < 2 { await Task.yield() }
        let entered = await gate.entered
        try await gate.finish(try XCTUnwrap(entered.firstIndex(of: "side")), page: page("side-row"))
        await side.presentation.navigation?.value
        XCTAssertEqual(side.historyState, .preparing); XCTAssertEqual(model.selected?.historyState, .loading)
        XCTAssertEqual(side.draft, "Keep the side draft"); XCTAssertEqual(model.focusedSessionID, "a")
        model.historyViewportReady("side", generation: side.presentationGeneration)
        XCTAssertEqual(side.historyState, .ready); XCTAssertEqual(model.selected?.historyState, .loading)
        try await gate.finish(try XCTUnwrap(entered.firstIndex(of: "a")), page: page("main-row")); await selection.value
        XCTAssertEqual(model.selected?.messages.map(\.id), ["main-row"])
        XCTAssertEqual(side.messages.map(\.id), ["side-row"])
        model.historyWindowLoader = nil
        do { _ = try await model.readConversationWindow(try XCTUnwrap(model.record("side")), cursor: nil); XCTFail("Ephemeral side invented a source") }
        catch { XCTAssertTrue(error.localizedDescription.contains("owning helper")) }
        XCTAssertTrue(model.hosts.isEmpty)
    }

    @MainActor func testNativeShortViewportAutofillIsBoundedAndManualEarlierStillWorks() async throws {
        let root = try folder(), path = try journal(80, root: root), model = try await model(root, path: path)
        await model.select("a"); let view = try XCTUnwrap(model.selected)
        let pane = TranscriptFrameBudgetTests.Pane(view, height: 1600,
            onReady: { model.historyViewportReady($0, generation: $1) }, onEarlier: { model.loadEarlier(sessionID: $0) })
        defer { pane.close() }
        await pane.settle(turns: 40)
        XCTAssertEqual(view.historyState, .ready)
        XCTAssertLessThanOrEqual(view.presentation.automaticFills, 2)
        XCTAssertLessThanOrEqual(view.messages.count, 18)
        XCTAssertNotNil(view.olderPage.cursor)
        let first = view.messages.first?.id
        let loaded = await model.loadEarlierPage(sessionID: "a")
        XCTAssertTrue(loaded); XCTAssertNotEqual(view.messages.first?.id, first)
    }
    private final class ProgressGate: @unchecked Sendable {
        let arrived: XCTestExpectation
        let resume = DispatchSemaphore(value: 0)
        init(_ arrived: XCTestExpectation) { self.arrived = arrived }
        func hold() { arrived.fulfill(); resume.wait() }
    }
    func testColdIndexCancellationStopsWorkWithoutTouchingSource() async throws {
        let root = try folder(), path = try journal(60_000, root: root), reader = HistoryReader()
        let original = try Data(contentsOf: path)
        let entered = expectation(description: "cold index progress"), gate = ProgressGate(entered)
        let work = Task { try await reader.window(path: path.path, progress: { _, _, _ in gate.hold() }) }
        await fulfillment(of: [entered], timeout: 5)
        work.cancel(); gate.resume.signal()
        do { _ = try await work.value; XCTFail("Cancelled index completed") } catch is CancellationError {} catch { XCTFail("Cancellation misreported as corruption: \(error)") }
        XCTAssertEqual(try Data(contentsOf: path), original)
        let retained = await reader.retainedIndexCount; XCTAssertEqual(retained, 0)
    }

    @MainActor func testFileHelperHandoffUsesStableIDsAndStopWorksDuringHydration() async throws {
        let root = try folder(), path = try journal(40, root: root), model = try await model(root, path: path)
        await model.select("a"); let view = try XCTUnwrap(model.selected)
        model.historyViewportReady("a", generation: view.presentationGeneration)
        var frames: [[String: WireValue]] = []
        let host = HostSupervisor(commandSender: { frames.append($0) })
        try await host.connect(cwd: root, state: root.appendingPathComponent("host"))
        model.hosts["project"] = host; model.opened.insert("a")
        defer { host.shutdown() }
        let fetch = Task { await model.loadEarlierPage(sessionID: "a") }
        while frames.isEmpty { await Task.yield() }
        let params = try XCTUnwrap(frames[0]["params"]?.object)
        XCTAssertEqual(params["entry"]?.string, "m34"); XCTAssertNil(params["cursor"])
        XCTAssertEqual(params["lineage"]?.string, "root")
        func cursor(_ id: String) -> WireValue { .object(["entry":.string(id), "incarnation":.string("live-session"), "lineage":.string("root")]) }
        let rows: [WireValue] = (28..<34).map { .object(["id":.string("m\($0)"), "role":.string($0 % 2 == 0 ? "user" : "assistant"), "text":.string("Message \($0)")]) }
        host.receive(.frame(["v":.number(1), "kind":.string("reply"), "hostEpoch":.string(try XCTUnwrap(host.epoch)),
                            "commandId":try XCTUnwrap(frames[0]["commandId"]), "ok":.bool(true),
                            "result":.object(["version":.number(2), "incarnation":.string("live-session"), "lineage":.string("root"),
                                              "messages":.array(rows), "older":cursor("m28"), "newer":cursor("m33")])]), connectionID:try XCTUnwrap(host.connectionID))
        let loaded = await fetch.value; XCTAssertTrue(loaded)
        XCTAssertEqual(view.messages.map(\.id), (28..<40).map { "m\($0)" })
        XCTAssertEqual(view.olderPage.cursor?.incarnation, "live-session")
        model.opened.remove("a")
        let retained = await model.loadEarlierPage(sessionID: "a"); XCTAssertTrue(retained)
        XCTAssertEqual(view.messages.first?.id, "m22")
        XCTAssertTrue(view.olderPage.cursor?.incarnation.hasPrefix("file:") == true)
        model.opened.insert("a"); view.state = "running"; view.historyState = .loading; view.draftReady = false
        model.stop(sessionID: "a")
        while !frames.contains(where: { $0["method"]?.string == "turn.stop" }) { await Task.yield() }
        XCTAssertEqual(view.state, "stopping")
        XCTAssertEqual(frames.filter { $0["method"]?.string == "turn.stop" }.count, 1)
        XCTAssertFalse(frames.contains { ["turn.submit", "tool.execute", "session.open"].contains($0["method"]?.string ?? "") })
        try await host.shutdownAndWait()
    }

}
