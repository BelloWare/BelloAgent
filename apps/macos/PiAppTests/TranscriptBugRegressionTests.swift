import AppKit
import XCTest
@testable import PiApp

final class TranscriptBugRegressionTests: XCTestCase {
    static let nestedHeading = "- item\n\n  ## Nested\n\n  nested text\n\n# Real\n\nreal text."
    static let before = "header\n…[truncated, 12 more bytes]\nold tail"
    static let after = "header\n…[truncated, 12 more bytes]\nnew tail"

    @MainActor private func checkFailedDiffNavigation(_ name: String, calls: Int = 1) async throws {
        let arguments: WireValue = name == "write"
            ? .object(["path": .string("fixture.txt"), "content": .string("inputneedle new")])
            : .object(["path": .string("fixture.txt"), "oldText": .string("inputneedle old"), "newText": .string("inputneedle new")])
        let call = (0..<calls).map { n in WireValue.object(["type": .string("toolCall"), "id": .string("call\(n)"), "name": .string(name), "arguments": arguments]) }
        var entries: [WireValue] = [.object(["type": .string("message"), "id": .string("reply"), "parentId": .null,
            "message": .object(["role": .string("assistant"), "content": .array(call)])])]
        for n in 0..<calls {
            entries.append(.object(["type": .string("message"), "id": .string("receipt\(n)"), "parentId": .string(n == 0 ? "reply" : "receipt\(n - 1)"),
                "message": .object(["role": .string("toolResult"), "toolCallId": .string("call\(n)"), "toolName": .string(name),
                    "content": .string("Permission denied"), "nativeToolStats": .object(["outcome": .string("failed")])])]))
        }
        let (model, pane, window) = try await findFixture(saved: true, entries: entries)
        let session = try XCTUnwrap(model.selected), messages = session.presentedMessages
        for page in [[messages[0]], messages] {
            pane.closeFind(focusing: false); session.messages = page; pane.refresh()
            pane.showFind(); pane.find.setQuery("inputneedle")
            try await eventually("Failed \(name) input projection finishes") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching }
            let count = calls * (name == "write" ? 1 : 2)
            XCTAssertEqual(pane.find.matches.count, count, "The projection retains every displayed diff input")
            XCTAssertEqual(Set(pane.find.matches.map(\.messageID)), ["reply"])
            for index in 0..<count {
                if pane.find.current != index { pane.find.step(index - (pane.find.current ?? 0)) }
                try await eventually("Failed \(name) input occurrence \(index) is focusable") {
                    pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    return !pane.document.focusPending && pane.document.focusText != nil
                }
                XCTAssertEqual(pane.find.current, index, "Rendered reconciliation must not discard an input occurrence")
                let text = try XCTUnwrap(pane.document.focusText), range = pane.document.focusRange
                XCTAssertEqual((text.string as NSString).substring(with: range), "inputneedle")
                let manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
                XCTAssertNotNil(manager.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil))
                var rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
                rect.origin.x += text.textContainerOrigin.x; rect.origin.y += text.textContainerOrigin.y
                let point = CGPoint(x: rect.midX, y: rect.midY), clip = pane.scrollView.contentView
                XCTAssertTrue(clip.bounds.contains(text.convert(point, to: clip)), "The focused input is visible in the transcript")
                if let inner = text.enclosingScrollView, inner !== pane.scrollView {
                    XCTAssertTrue(inner.contentView.bounds.contains(text.convert(point, to: inner.contentView)), "The focused input is visible inside the card")
                }
                XCTAssertEqual(pane.document.highlights.focus?.omittedOutputs, Set((0..<calls).map { "call\($0)" }), "This exercises receipt-owned failures")
            }
        }
    }
    @MainActor func testFailedEditInputsRemainFocusableWithCapturedReply() async throws {
        for large in [false, true] {
            let request = TranscriptActivity.EditRequest(before: "old input", after: "new input", mode: "edit",
                rows: large ? [] : [.init(kind: .removed, text: "old input"), .init(kind: .added, text: "new input")],
                hiddenRows: 0, complete: true, tooLarge: large, lines: large ? 9_000 : 2)
            let model = TranscriptToolRow.Card.diff(request, path: nil, outcome: .failed, added: nil, removed: nil)
            let card = TranscriptNativeCard.make(model); card.update(model, link: nil, environment: .init())
            if large { try XCTUnwrap(ConversationPaneTests.views(NSButton.self, in: card).first { $0.bezelStyle == .disclosure }).performClick(nil) }
            card.frame.size = CGSize(width: 620, height: card.height(width: 620)); card.layoutSubtreeIfNeeded()
            let units = TranscriptNativeDocument.textUnits(in: card)
            XCTAssertFalse(units.isEmpty)
            for unit in units {
                let text = (unit as? NSTextView)?.string ?? ""
                let input = unit is TranscriptCardLines || text == "old input" || text == "new input"
                XCTAssertEqual(TranscriptNativeDocument.isToolInput(unit), input, "Only requested diff content is input: \(text)")
            }
        }
        try await checkFailedDiffNavigation("edit")
    }
    @MainActor func testFailedWriteInputsRemainFocusableWithCapturedReply() async throws { try await checkFailedDiffNavigation("write") }
    @MainActor func testFailedMultiEditInputsRemainFocusableWithCapturedReply() async throws { try await checkFailedDiffNavigation("edit", calls: 2) }

    static func repeatedCards(_ name: String) -> TranscriptMessage {
        var timeline = ResponseTimeline()
        for (ordinal, call) in ["A", "B", "A"].enumerated() {
            timeline.consume(.init(attemptID: "fixture", ordinal: ordinal, itemID: "part\(ordinal)", kind: "toolArguments", update: "replace", text: "", callID: call, name: name))
        }
        timeline.finish("completed")
        let lines = (1...20).map { "Line \($0)" }.joined(separator: "\n")
        let arguments: WireValue = name == "read" ? .object(["path": .string("fixture.txt")])
            : .object(["path": .string("fixture.txt"), "oldText": .string("old"), "newText": .string(lines)])
        let tools = ["A", "B"].map { ToolView(id: $0, name: name, state: "completed", input: ToolInputDisplay.encoded(arguments), output: name == "read" ? lines : "Done", durationMs: 10, truncated: false) }
        var message = TranscriptMessage(id: "reply", role: "assistant", text: "", tools: tools, state: "complete")
        message.responseTimeline = timeline
        return message
    }
    @MainActor private func checkRepeatedCardExpansion(_ name: String) async throws {
        let (model, pane, window) = try await findFixture(saved: true)
        let session = try XCTUnwrap(model.selected)
        session.messages = [Self.repeatedCards(name)]
        for case .block(let block) in TaskTranscriptPlan.rows(session.presentedMessages, lifecycle: nil) where block.presentation == .work {
            session.disclosure.setOpen(true, .work(block.key))
        }
        for call in ["A", "B"] { session.disclosure.setOpen(true, .tool(ToolOccurrence.key("reply", call))) }
        pane.refresh(); pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); pane.document.finishDisclosureMotion()
        let rows = pane.document.rows(drawing: "reply").filter { if case .block(let block) = $0.item { return block.presentation == .work }; return false }
        XCTAssertEqual(rows.count, 3)
        func cards() throws -> [TranscriptNativeCard] {
            try rows.map { row in
                row.prepareToDraw(); row.frame.size = row.measure(width: pane.document.bounds.width); row.layoutForViewport()
                return try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeCard.self, in: row).first)
            }
        }
        func expanded(_ card: TranscriptNativeCard) -> Bool { (card as? TranscriptNativeReadCard)?.expanded ?? (card as? TranscriptNativeDiffCard)?.expanded ?? false }
        func press(_ card: TranscriptNativeCard) throws {
            XCTAssertTrue(try XCTUnwrap(ConversationPaneTests.views(TranscriptCardMoreLines.self, in: card).first).accessibilityPerformPress())
        }
        let initial = try cards(), key = TranscriptDisclosure.Part.toolLines(ToolOccurrence.key("reply", "A"))
        try press(initial[0])
        XCTAssertTrue(session.disclosure.isOpen(key))
        XCTAssertTrue(expanded(initial[2]), "The already mounted sibling must adopt expansion in the same pass")
        XCTAssertFalse(expanded(initial[1]), "Another occurrence keeps its own state")
        let open = try cards()
        XCTAssertEqual(open.map(expanded), [true, false, true])
        try press(open[2])
        XCTAssertFalse(session.disclosure.isOpen(key), "The sibling now displays Less Lines and explicitly collapses both")
        XCTAssertFalse(expanded(open[0]))
        // A pending card action may carry the displayed state from before a
        // sibling changed. Asking to expand an already-open occurrence is idempotent.
        session.disclosure.setOpen(true, key)
        let stale = try cards()[2]; stale.restoreExpansion(false)
        try press(stale)
        XCTAssertTrue(session.disclosure.isOpen(key), "An expand action must never toggle an already-true stored value")
        pane.refresh()
        for row in rows {
            try await eventually("Repeated \(name) card geometry settles") {
                row.frame.size = row.measure(width: pane.document.bounds.width); row.layoutForViewport(); window.displayIfNeeded()
                return !row.needsMountedValidation
            }
            window.makeFirstResponder(nil); row.releaseHost(); XCTAssertFalse(row.isHosted)
        }
        let remounted = try cards()
        XCTAssertEqual(remounted.map(expanded), [true, false, true])
        for row in rows { XCTAssertEqual(row.measure(width: pane.document.bounds.width).height, row.hostedFittingHeight, accuracy: 1) }
        session.disclosure.setOpen(false, key)
        XCTAssertFalse(expanded(remounted[0])); XCTAssertFalse(expanded(remounted[2]))
        // Find opens the same inner disclosure without a button click. Visiting
        // both copies must not undo the first copy's expansion either.
        pane.showFind(); pane.find.setQuery("Line 10")
        try await eventually("Repeated card Find finishes") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching }
        XCTAssertEqual(pane.find.matches.count, 3)
        for index in 0..<3 {
            if pane.find.current != index { pane.find.step(index - (pane.find.current ?? 0)) }
            try await eventually("Repeated card occurrence \(index) focuses") {
                pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                return !pane.document.focusPending && pane.document.focusText != nil
            }
            let text = try XCTUnwrap(pane.document.focusText)
            XCTAssertEqual((text.string as NSString).substring(with: pane.document.focusRange), "Line 10")
            XCTAssertTrue(session.disclosure.isOpen(key))
            XCTAssertTrue(expanded(try cards()[0])); XCTAssertTrue(expanded(try cards()[2]))
        }
    }
    @MainActor func testRepeatedReadCardsShareExpansion() async throws { try await checkRepeatedCardExpansion("read") }
    @MainActor func testRepeatedDiffCardsShareExpansion() async throws { try await checkRepeatedCardExpansion("edit") }

    private final class SearchDecodeCost: @unchecked Sendable {
        private let lock = NSLock()
        private var decodes: [UInt64: Int] = [:]
        private var total = 0, batch = 0, peak = 0, retained = 0
        private var announced = false
        var ready: XCTestExpectation?
        func observe(_ event: HistoryReader.SearchDecodeEvent) {
            lock.lock(); defer { lock.unlock() }
            switch event {
            case .decoded(let offset, let bytes):
                decodes[offset, default: 0] += 1; total += bytes; batch += bytes; peak = max(peak, batch)
                if total >= 10 * 1_048_576, !announced { announced = true; ready?.fulfill() }
            case .retained(let bytes): retained = max(retained, bytes)
            case .yielded: batch = 0
            }
        }
        var snapshot: (counts: [UInt64: Int], bytes: Int, peak: Int, retained: Int) {
            lock.lock(); defer { lock.unlock() }; return (decodes, total, peak, retained)
        }
    }
    private struct WideSearchFixture {
        var root: URL, path: URL
        var reader: HistoryReader
        var messages: [TranscriptMessage]
        var offsets: [String: UInt64]
        var bytes: Int
    }
    private func searchCostFixture(_ entries: [(String, [String: WireValue], Int)]) async throws -> WideSearchFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wide-search-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("fixture.jsonl"), reader = HistoryReader(indexDirectory: root)
        var data = Data("{\"type\":\"session\",\"version\":3,\"id\":\"fixture\"}\n".utf8)
        var messages: [TranscriptMessage] = [], results: [String: ToolResultRecord] = [:], offsets: [String: UInt64] = [:], parent: WireValue = .null
        func add(_ id: String, _ message: [String: WireValue], padding: Int = 0) throws {
            offsets[id] = UInt64(data.count)
            var row: [String: WireValue] = ["type": .string("message"), "id": .string(id), "parentId": parent, "message": .object(message)]
            // Generated opaque provider metadata makes the journal decode large
            // without measuring Markdown layout or using a real provider trace.
            if padding > 0 { row["providerTrace"] = .string(String(repeating: "x", count: padding)) }
            data.append(try JSONEncoder().encode(WireValue.object(row))); data.append(10); parent = .string(id)
            messages.append(.project(id: id, message: message))
            if let result = ToolResultRecord.of(message) { results[id] = result.record }
        }
        for (id, message, padding) in entries { try add(id, message, padding: padding) }
        try data.write(to: path)
        _ = try await reader.read(path: path.path, whole: true)
        return .init(root: root, path: path, reader: reader, messages: TranscriptMessage.resolvingToolResults(messages, results: results), offsets: offsets, bytes: data.count)
    }
    private func wideSearchEntries(prefix: String = "", calls: Int = 64, orphan: Bool = false) throws -> [(String, [String: WireValue], Int)] {
        var issuer: [String: WireValue] = ["role": .string(orphan ? "system" : "assistant"), "content": .array((0..<calls).map { n in
            .object(["type": .string("toolCall"), "id": .string("call\(n)"), "name": .string("fixture"), "arguments": .object(["item": .string("inputneedle \(n)")])])
        })]
        if orphan {
            issuer["nativeKind"] = .string("requestLedger"); issuer["nativePresentationSourceID"] = .string("missing")
            var timeline = ResponseTimeline()
            for n in 0..<calls {
                timeline.consume(.init(attemptID: "attempt", ordinal: n, itemID: "item\(n)", kind: "toolArguments", update: "replace",
                    text: "", callID: "call\(n)", name: "fixture"))
            }
            issuer["nativeResponseTimeline"] = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(timeline))
        }
        var entries: [(String, [String: WireValue], Int)] = [(prefix + "issuer", issuer, 8 * 1_048_576)]
        for n in 0..<40 { entries.append((prefix + "spacer\(n)", ["role": .string("system"), "nativeKind": .string("notice"), "content": .string("Spacer \(n)")], 0)) }
        for n in 0..<calls {
            entries.append((prefix + "receipt\(n)", ["role": .string("toolResult"), "toolCallId": .string("call\(n)"), "toolName": .string("fixture"),
                "content": .string("**receiptneedle** \(n)"), "nativeToolStats": .object(["outcome": .string("completed")])], n < 4 ? 4 * 1_048_576 : 0))
        }
        return entries
    }
    func testFindContinuationsDecodeDependenciesOnceAcrossTenPages() async throws {
        var entries = try wideSearchEntries(calls: 1_000)
        for i in entries.indices { entries[i].2 = 0 }
        let fixture = try await searchCostFixture(entries); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cost = SearchDecodeCost(); await fixture.reader.observeSearchDecodes { cost.observe($0) }
        var start = 0, pages = 0, ids: [String] = []
        let began = ProcessInfo.processInfo.systemUptime
        repeat {
            let page = try await fixture.reader.searchContent(path: fixture.path.path, query: "receiptneedle", start: start, renderedAgentProse: true)
            pages += 1; ids += page.hits.map(\.id)
            guard let next = page.next else { break }; start = next
        } while pages < 11
        print("CONTINUATION-COST pages=\(pages) decodes=\(cost.snapshot.counts.values.reduce(0, +)) bytes=\(cost.snapshot.bytes) source=\(fixture.bytes)")
        XCTAssertEqual(pages, 10); XCTAssertEqual(ids, (0..<1_000).map { "receipt\($0)" })
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 12, "Wide dependency planning must remain linear")
        assertBoundedSearch(cost, sourceBytes: fixture.bytes, name: "ten continuation pages")
        await fixture.reader.releaseIndexes()
    }
    func testWideLegacyIssuerRetainsOnlyBoundedMatchState() async throws {
        var entries = try wideSearchEntries(calls: 64)
        var future = try XCTUnwrap(JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(ResponseTimeline())).object)
        future["version"] = .number(999); entries[0].1["nativeResponseTimeline"] = .object(future)
        for i in entries.indices {
            entries[i].2 = 0
            if entries[i].0.hasPrefix("receipt") { entries[i].1["content"] = .string(String(repeating: "x", count: 1_048_576) + " outputneedle") }
        }
        let fixture = try await searchCostFixture(entries); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cost = SearchDecodeCost(), scratch = SearchOrder()
        let ready = expectation(description: "First large card projected")
        let signal = SearchOrder()
        await fixture.reader.observeSearchDecodes { event in
            cost.observe(event)
            if case .retained = event, signal.events.isEmpty { signal.add("ready"); ready.fulfill() }
            if case .retained = event, ((try? FileManager.default.contentsOfDirectory(atPath: fixture.root.path)) ?? []).contains(where: { $0.hasPrefix("search-inputs-") }) { scratch.add("named payload file") }
        }
        let search = Task { try await fixture.reader.searchContent(path: fixture.path.path, query: "outputneedle", start: 0, renderedAgentProse: true) }
        await fulfillment(of: [ready], timeout: 20)
        let began = ProcessInfo.processInfo.systemUptime
        _ = try await fixture.reader.read(path: fixture.path.path, position: fixture.messages.count - 1)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let found = try await search.value
        print("WIDE-PAYLOAD pageSeconds=\(elapsed)")
        XCTAssertLessThan(elapsed, 0.75, "Receipt projection work must yield as well as its source reads")
        XCTAssertTrue(scratch.events.isEmpty, "Transient payloads must be anonymous even before the issuer returns")
        print("RETAINED-SEARCH bytes=\(cost.snapshot.retained) source=\(fixture.bytes)")
        XCTAssertEqual(found.hits.first { $0.id == "issuer" }?.count, 64)
        XCTAssertEqual(found.hits.reduce(0) { $0 + ($1.count ?? 1) }, 128, "Legacy cards and standalone receipts are both displayed")
        XCTAssertLessThan(cost.snapshot.retained, 2 * 1_048_576, "An issuer must retain summaries, never its accumulated receipt payloads")
        assertBoundedSearch(cost, sourceBytes: fixture.bytes, name: "wide legacy receipts")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix("search-inputs-") })
        await fixture.reader.releaseIndexes()
    }
    func testFailedToolSummariesEqualDisplayedCardsSavedAndLive() async throws {
        let cases: [(String, WireValue)] = [
            ("edit", .object(["path": .string("fixture.txt"), "oldText": .string("old"), "newText": .string("new")])),
            ("write", .object(["path": .string("fixture.txt"), "content": .string("new")])),
            ("bash", .object(["command": .string("fixture-command")]))]
        for (name, arguments) in cases {
            let fields = try XCTUnwrap(toolEntry(name, arguments: arguments)["message"]?.object)
            let fixture = try await searchCostFixture([("reply", fields, 0), ("result", ["role": .string("toolResult"),
                "toolCallId": .string("call"), "toolName": .string(name), "content": .string("Permission denied\nHidden failure detail"),
                "nativeToolStats": .object(["outcome": .string("failed")])], 0)])
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let tool = try XCTUnwrap(fixture.messages.first?.tools?.first)
            let shown = await MainActor.run {
                let row = TranscriptNativeActionRow(frame: .zero)
                row.update(tool: tool, open: true, fetched: nil, environment: .init(), toggle: {}, openFile: { _, _ in })
                XCTAssertEqual(row.line.content.summary, "Permission denied")
                let body = Self.cardPayload(tool, includeWorkSummary: false)
                let shown = name == "bash" ? body : body + "\n" + row.line.content.summary
                XCTAssertEqual(ConversationContent.toolText(tool), shown, name)
                XCTAssertEqual(row.searchText, shown, "Native highlight projection \(name)")
                var empty = tool; empty.output = ""
                XCTAssertEqual(ConversationContent.toolText(empty), Self.cardPayload(empty), "A failed card without output has no extra error summary")
                return shown
            }
            let live = try await fixture.reader.searchPresented(fixture.messages, query: "", start: 0)
            XCTAssertEqual(live.hits.map(\.preview).filter { !$0.isEmpty }.joined(separator: "\n"), shown, "Live \(name)")
            for page in [[], [fixture.messages[0]], fixture.messages] {
                let saved = try await fixture.reader.searchContent(path: fixture.path.path, query: "", start: 0, renderedAgentProse: true, presented: page)
                XCTAssertEqual(saved.hits.map(\.preview).filter { !$0.isEmpty }.joined(separator: "\n"), shown, "Saved \(name) captured=\(page.count)")
                let found = try await fixture.reader.searchContent(path: fixture.path.path, query: "Permission denied", start: 0, renderedAgentProse: true, presented: page)
                XCTAssertEqual(found.hits.map(\.id), ["result"], name)
                XCTAssertEqual(found.hits.first?.count, 1)
                let hidden = try await fixture.reader.searchContent(path: fixture.path.path, query: "Hidden failure detail", start: 0, renderedAgentProse: true, presented: page)
                XCTAssertEqual(hidden.hits.count, name == "bash" ? 1 : 0)
            }
            await fixture.reader.releaseIndexes()
        }
    }
    func testFragmentSearchEqualsJoinedDisplayText() {
        let corpus = [["", "", ""], ["alpha", "beta", "gamma"], ["aaa", "aaa", "aaaa"],
            ["Straße", "STRASSE", "é", "e\u{301}", "🐈cat"], ["a\r", "b\0c", "finish"],
            [String(repeating: "z", count: 300) + "alpha", "beta", String(repeating: "tail", count: 100)],
            ["input", "output", "input", "output"], ["abc", "", "def"]]
        for parts in corpus {
            let joined = parts.filter { !$0.isEmpty }.joined(separator: "\n")
            for query in ["", "alpha", "alpha\nbeta", "a\na", "aaa", "\n", "e\u{301}", "é\ne\u{301}", "STRASSE", "🐈cat", "\0", "absent", "input\noutput"] {
                var search = HistoryReader.SearchText(query)
                for part in parts { search.append(part) }
                let count = ConversationContent.occurrences(of: query, in: joined)
                XCTAssertEqual(search.match.count, query.isEmpty ? 0 : count == 0 ? -1 : count, "\(parts), \(query)")
                if let range = joined.range(of: query, options: [.caseInsensitive]), !query.isEmpty {
                    let from = joined.index(range.lowerBound, offsetBy: -60, limitedBy: joined.startIndex) ?? joined.startIndex
                    XCTAssertEqual(search.match.preview, String(joined[from...].prefix(240)), "\(query)")
                } else if query.isEmpty { XCTAssertEqual(search.match.preview, String(joined.prefix(240))) }
                XCTAssertLessThan(search.retainedBytes, 8_192)
            }
        }
    }
    func testContinuationSummariesInvalidateForQueryDisplayAndJournalChanges() async throws {
        for change in ["query", "captured", "journal", "restart"] {
            var entries = try wideSearchEntries(calls: 101)
            for index in entries.indices { entries[index].2 = 0 }
            let fixture = try await searchCostFixture(entries); defer { try? FileManager.default.removeItem(at: fixture.root) }
            let first = try await fixture.reader.searchContent(path: fixture.path.path, query: "receiptneedle", start: 0, renderedAgentProse: true)
            let start = try XCTUnwrap(first.next)
            let tables = await fixture.reader.retainedSearchCacheTables
            XCTAssertEqual(tables, 3)
            var page: [TranscriptMessage] = []
            if change == "captured" {
                var owner = fixture.messages[0]; owner.tools?[100].output = "changed output"; page = [owner]
            }
            if change == "journal" {
                let message: [String: WireValue] = ["role": .string("toolResult"), "toolCallId": .string("call100"), "toolName": .string("fixture"),
                    "content": .string("changed output"), "nativeToolStats": .object(["outcome": .string("completed")])]
                let record: WireValue = .object(["type": .string("message"), "id": .string("replacement"), "parentId": .string("receipt100"), "message": .object(message)])
                let file = try FileHandle(forWritingTo: fixture.path); try file.seekToEnd()
                try file.write(contentsOf: JSONEncoder().encode(record)); try file.write(contentsOf: Data([10])); try file.close()
            }
            let cost = SearchDecodeCost(); await fixture.reader.observeSearchDecodes { cost.observe($0) }
            let last = try await fixture.reader.searchContent(path: fixture.path.path, query: change == "query" ? "absent" : "receiptneedle",
                start: change == "restart" ? 0 : start, renderedAgentProse: true, presented: page)
            if change == "restart" { XCTAssertEqual(last.hits.count, 100); XCTAssertGreaterThan(cost.snapshot.bytes, 0) }
            else { XCTAssertTrue(last.hits.isEmpty, change); XCTAssertNil(last.next) }
            await fixture.reader.releaseIndexes()
            let cleared = await fixture.reader.retainedSearchCacheTables
            XCTAssertEqual(cleared, 0)
        }
    }
    func testWideTimelineJoinDoesNotBlockPagingBetweenBatches() async throws {
        var entries = try wideSearchEntries(calls: 1_000)
        for index in entries.indices { entries[index].2 = 0 }
        let fixture = try await searchCostFixture(entries); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ready = expectation(description: "A wide issuer started its first receipt")
        let offset = try XCTUnwrap(fixture.offsets["receipt0"])
        await fixture.reader.observeSearchDecodes { event in
            if case .decoded(let at, _) = event, at == offset { ready.fulfill() }
        }
        let search = Task { try await fixture.reader.searchContent(path: fixture.path.path, query: "receiptneedle", start: 0, renderedAgentProse: true) }
        await fulfillment(of: [ready], timeout: 10)
        let began = ProcessInfo.processInfo.systemUptime
        _ = try await fixture.reader.read(path: fixture.path.path, position: fixture.messages.count - 1)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        search.cancel(); _ = try? await search.value
        print("WIDE-TIMELINE pageSeconds=\(elapsed)")
        XCTAssertLessThan(elapsed, 0.75, "A dependency join must not plan all 1,000 sibling rows for each receipt")
        await fixture.reader.releaseIndexes()
    }
    func testCancelledSpilledSearchReleasesItsFilesAndSummaries() async throws {
        var entries = try wideSearchEntries(calls: 32)
        for index in entries.indices where entries[index].0.hasPrefix("receipt") {
            entries[index].1["content"] = .string(String(repeating: "x", count: 256 * 1_024) + " receiptneedle")
        }
        var future = ResponseTimeline(); future.version = 999
        entries[0].1["nativeResponseTimeline"] = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(future))
        let fixture = try await searchCostFixture(entries); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cost = SearchDecodeCost(), ready = expectation(description: "Large receipt read")
        cost.ready = ready; await fixture.reader.observeSearchDecodes { cost.observe($0) }
        let search = Task { try await fixture.reader.searchContent(path: fixture.path.path, query: "receiptneedle", start: 0, renderedAgentProse: true) }
        await fulfillment(of: [ready], timeout: 10)
        search.cancel()
        do { _ = try await search.value; XCTFail("The obsolete query must stop at its next batch") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix("search-inputs-") })
        let tables = await fixture.reader.retainedSearchCacheTables
        XCTAssertEqual(tables, 0)
        _ = try await fixture.reader.read(path: fixture.path.path, position: fixture.messages.count - 1)
        await fixture.reader.releaseIndexes()
    }
    func testSpilledCardsKeepPlannerOrderWithoutDecodingRepeatedParts() async throws {
        var entries = try wideSearchEntries(calls: 2)
        let calls = (0..<2).map { n in WireValue.object(["type": .string("toolCall"), "id": .string("call\(n)"), "name": .string("fixture"),
            "arguments": .object(["begin": .string("inputneedle\(n)"), "padding": .string(String(repeating: "x", count: 100_000)), "tail": .string("tail\(n)")])]) }
        entries[0].1["content"] = .array(calls)
        var timeline = ResponseTimeline()
        for (ordinal, call) in [1, 0, 1].enumerated() {
            timeline.consume(.init(attemptID: "attempt", ordinal: ordinal, itemID: "part\(ordinal)", kind: "toolArguments", update: "replace", text: "", callID: "call\(call)", name: "fixture"))
        }
        timeline.finish("completed")
        entries[0].1["nativeResponseTimeline"] = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(timeline))
        for index in entries.indices { entries[index].2 = 0 }
        let fixture = try await searchCostFixture(entries); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tools = try XCTUnwrap(fixture.messages.first?.tools)
        let boundary = String(ConversationContent.toolText(tools[0], inputOnly: true).suffix(24)) + "\n" + String(ConversationContent.toolText(tools[1], inputOnly: true).prefix(24))
        let expected = ConversationContent.Presentation(fixture.messages).text("issuer")
        for page in [[], [fixture.messages[0]]] { for query in [boundary, "inputneedle1"] {
            let cost = SearchDecodeCost(), scratch = SearchOrder()
            await fixture.reader.observeSearchDecodes { event in
                cost.observe(event)
                if case .retained = event, ((try? FileManager.default.contentsOfDirectory(atPath: fixture.root.path)) ?? []).contains(where: { $0.hasPrefix("search-inputs-") }) { scratch.add("named payload file") }
            }
            let found = try await fixture.reader.searchContent(path: fixture.path.path, query: query, start: 0, renderedAgentProse: true, presented: page)
            XCTAssertTrue(scratch.events.isEmpty, "Spilled payloads must have no surviving pathname")
            XCTAssertEqual(found.hits.map(\.id), ["issuer"])
            XCTAssertEqual(found.hits.first?.count, ConversationContent.occurrences(of: query, in: expected))
            XCTAssertEqual(found.hits.first?.count, query == boundary ? 1 : 2)
            assertBoundedSearch(cost, sourceBytes: fixture.bytes, name: "repeated spooled card captured=\(page.count)")
            XCTAssertLessThan(cost.snapshot.retained, 2 * 1_048_576)
        } }
        await fixture.reader.releaseIndexes()
    }
    func testSearchSummarySnippetsBoundLongGraphemesAndKeepTheMatch() async throws {
        let giant = "e" + String(repeating: "\u{301}", count: 8_192)
        for output in [giant + " receiptneedle", "receiptneedle " + giant] {
            var entries = try wideSearchEntries(calls: 1)
            for index in entries.indices { entries[index].2 = 0 }
            entries[entries.count - 1].1["content"] = .string(output)
            let fixture = try await searchCostFixture(entries); defer { try? FileManager.default.removeItem(at: fixture.root) }
            for rendered in [false, true] { for query in ["", "receiptneedle"] {
                let found = try await fixture.reader.searchContent(path: fixture.path.path, query: query, start: 0, renderedAgentProse: rendered)
                let hit = try XCTUnwrap(found.hits.first { $0.id == "receipt0" })
                XCTAssertLessThanOrEqual(hit.preview.utf8.count, 4_096)
                if !query.isEmpty { XCTAssertTrue(hit.preview.contains(query)) }
            } }
            await fixture.reader.releaseIndexes()
        }
    }
    func testFragmentSearchMatchesFoundationAcrossUnicodeAndLineEndings() {
        var seed: UInt64 = 1234567
        func random(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(n)) }
        let alphabet = ["a", "A", "ß", "S", "é", "e\u{301}", "\r", "\n", " ", "🐈", "\u{301}"]
        var failed = 0
        for example in 0..<200 {
            let parts = (0..<4).map { _ in (0..<80).map { _ in alphabet[random(alphabet.count)] }.joined() }
            let text = parts.joined(separator: "\n")
            let chars = Array(text)
            var queries = ["a", "aa", "SS", "é", "e\u{301}", "\r", "\n", "\r\n", "🐈", "é\né"]
            let start = random(chars.count-10)
            queries.append(String(chars[start..<(start+5)]))
            for query in queries {
                var expected = 0, from = text.startIndex
                var preview = ""
                while let match = text.range(of: query, options: [.caseInsensitive], range: from..<text.endIndex) {
                    if expected == 0 {
                        let begin = text.index(match.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
                        preview = String(text[begin...].prefix(240))
                    }
                    expected += 1; from = match.upperBound
                }
                var actual = HistoryReader.SearchText(query)
                for part in parts { actual.append(part) }
                if actual.match.count != (expected == 0 ? -1 : expected) || actual.match.preview != preview {
                    failed += 1
                    if failed < 8 { XCTFail("Unicode example=\(example) query=\(query.debugDescription) counts=\(actual.match.count)/\(expected) previewEqual=\(actual.match.preview == preview)") }
                }
            }
        }
        XCTAssertEqual(failed, 0)
        print("FRAGMENT-FUZZ comparisons=2200 failures=\(failed)")
    }
    func testWideUnansweredIssuerYieldsWithoutReceiptDecodes() async throws {
        var entries = Array(try wideSearchEntries(calls: 10_000).prefix(41))
        entries[0].2 = 0
        // Isolate Find's loops from the helper's separate legacy canonicalizer.
        entries[0].1["nativeResponseTimeline"] = .object(["version": .number(999), "segments": .array([]),
            "omittedEvents": .number(0), "coverage": .string("observed")])
        let fixture = try await searchCostFixture(entries); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let baselineStart = ProcessInfo.processInfo.systemUptime
        _ = try await fixture.reader.read(path: fixture.path.path, position: fixture.messages.count - 1)
        let baseline = ProcessInfo.processInfo.systemUptime - baselineStart
        let ready = expectation(description: "Unanswered issuer decoded")
        let offset = try XCTUnwrap(fixture.offsets["issuer"])
        await fixture.reader.observeSearchDecodes { event in
            if case .decoded(let at, _) = event, at == offset { ready.fulfill() }
        }
        let search = Task { try await fixture.reader.searchContent(path: fixture.path.path, query: "inputneedle", start: 0, renderedAgentProse: true) }
        await fulfillment(of: [ready], timeout: 10)
        let began = ProcessInfo.processInfo.systemUptime
        _ = try await fixture.reader.read(path: fixture.path.path, position: fixture.messages.count - 1)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let found = try await search.value
        print("UNANSWERED-WIDE pageSeconds=\(elapsed) baseline=\(baseline)")
        XCTAssertEqual(found.hits.first?.count, 10_000)
        XCTAssertLessThan(elapsed, baseline + 0.75, "Metadata-only and unmatched-card projection loops must also yield")
        await fixture.reader.releaseIndexes()
    }
    private func wideSearchFixture() async throws -> WideSearchFixture { try await searchCostFixture(wideSearchEntries()) }
    private func assertBoundedSearch(_ cost: SearchDecodeCost, sourceBytes: Int, name: String, file: StaticString = #filePath, line: UInt = #line) {
        let measured = cost.snapshot
        print("DEPENDENCY-COST \(name) sourceBytes=\(sourceBytes) decodedBytes=\(measured.bytes) peakBatch=\(measured.peak) largestRepeat=\(measured.counts.values.max() ?? 0)")
        XCTAssertTrue(measured.counts.values.allSatisfy { $0 == 1 }, name, file: file, line: line)
        XCTAssertLessThanOrEqual(measured.bytes, sourceBytes, name, file: file, line: line)
        XCTAssertLessThanOrEqual(measured.peak, HistoryReader.searchRunBytes, name, file: file, line: line)
    }
    func testReusedWideIssuersAndOrphanLedgersShareOnceOnlyDecodes() async throws {
        for orphan in [false, true] {
            let entries = try wideSearchEntries(prefix: "first-", calls: 32, orphan: orphan) + wideSearchEntries(prefix: "second-", calls: 32, orphan: orphan)
            let fixture = try await searchCostFixture(entries); defer { try? FileManager.default.removeItem(at: fixture.root) }
            for page in [[], [fixture.messages[0]], Array(fixture.messages.suffix(32)), fixture.messages] {
                for start in [0, 41, 114] {
                    let cost = SearchDecodeCost(); await fixture.reader.observeSearchDecodes { cost.observe($0) }
                    let found = try await fixture.reader.searchContent(path: fixture.path.path, query: "receiptneedle", start: start,
                        renderedAgentProse: true, presented: page)
                    let expected = fixture.messages.enumerated().filter { $0.offset >= start && $0.element.id.contains("receipt") }.map { $0.element.id }
                    XCTAssertEqual(found.hits.map(\.id), expected); XCTAssertNil(found.next)
                    assertBoundedSearch(cost, sourceBytes: fixture.bytes, name: "reused orphan=\(orphan) page=\(page.count) start=\(start)")
                }
            }
        }
    }
    func testRecoveryPresenceDependenciesDoNotDecodeLargePeerBodies() async throws {
        var entries: [(String, [String: WireValue], Int)] = [("accepted", ["role": .string("assistant"), "content": .string("Accepted response")], 8 * 1_048_576)]
        for n in 0..<64 {
            var ledger = try recoveryLedger(terminal: "completed")
            ledger["nativePresentationSourceID"] = .string(n == 63 ? "missing" : "accepted")
            entries.append(("ledger\(n)", ledger, 0))
        }
        for n in 0..<65 {
            entries.append(("operation\(n)", ["role": .string("system"), "nativeKind": .string("execution"),
                "nativeOperationID": .string("shared-operation"), "nativeDetail": .string("operationneedle"), "content": .string("")], n == 0 ? 8 * 1_048_576 : 0))
        }
        let fixture = try await searchCostFixture(entries); defer { try? FileManager.default.removeItem(at: fixture.root) }
        for page in [[], Array(fixture.messages.suffix(65)), fixture.messages] {
            let cost = SearchDecodeCost(); await fixture.reader.observeSearchDecodes { cost.observe($0) }
            let found = try await fixture.reader.searchContent(path: fixture.path.path, query: "operationneedle", start: 0,
                renderedAgentProse: true, presented: page)
            XCTAssertEqual(found.hits.count, 65); XCTAssertNil(found.next)
            assertBoundedSearch(cost, sourceBytes: fixture.bytes, name: "operation/source presence page=\(page.count)")
            let orphan = try await fixture.reader.searchContent(path: fixture.path.path, query: "gamma delta", start: 0,
                renderedAgentProse: true, presented: page)
            XCTAssertEqual(orphan.hits.map(\.id), ["ledger63"])
        }
    }
    func testManyToolStartsReuseTheirLargeIssuersProjection() async throws {
        var entries = try wideSearchEntries()
        for n in 0..<64 {
            var timeline = ResponseTimeline()
            timeline.consume(.init(attemptID: "attempt", ordinal: n, itemID: "start\(n)", kind: "toolArguments", update: "replace",
                text: "startneedle", callID: "call\(n)", name: "fixture"))
            let encoded = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(timeline))
            entries.insert(("start\(n)", ["role": .string("system"), "nativeKind": .string("execution"),
                "nativeDetail": .string("Started tool"), "nativeResponseTimeline": encoded, "content": .string("")], 0), at: 41 + n)
        }
        let fixture = try await searchCostFixture(entries); defer { try? FileManager.default.removeItem(at: fixture.root) }
        for start in [0, 41] {
            let cost = SearchDecodeCost(); await fixture.reader.observeSearchDecodes { cost.observe($0) }
            let found = try await fixture.reader.searchContent(path: fixture.path.path, query: "startneedle", start: start, renderedAgentProse: true)
            XCTAssertTrue(found.hits.isEmpty); XCTAssertNil(found.next)
            XCTAssertEqual(cost.snapshot.counts[fixture.offsets["issuer"]!], 1)
            assertBoundedSearch(cost, sourceBytes: fixture.bytes, name: "tool starts start=\(start)")
        }
    }
    func testSearchMatchCachesStayIsolatedAndReleaseAfterUse() throws {
        let index = try HistoryOffsetIndex()
        try index.finish()
        XCTAssertEqual(index.searchCacheTableCount, 0)
        let first = try HistoryOffsetIndex.SearchCache(index)
        let preview = "prefix\0suffix 🐈", call = "reuse\0call"
        try first.store(.init(count: 2, preview: preview, drawing: .init(messageID: "reply", toolCallID: call), omittedOutputs: [call]), at: 42)
        try first.store(.init(card: true, paired: true), call: call, at: 42)
        do {
            let second = try HistoryOffsetIndex.SearchCache(index)
            XCTAssertNil(try second.match(42)); XCTAssertNil(try second.call(call, at: 42))
            // Enough summaries to spill beyond the 512 KiB SQLite page cache.
            for n in 0..<50_000 { try second.store(.init(count: 1, preview: String(repeating: "x", count: 240)), at: UInt64(n)) }
            XCTAssertEqual(try second.match(0)?.count, 1); XCTAssertEqual(try second.match(49_999)?.count, 1)
            XCTAssertEqual(try first.match(42)?.preview, preview)
            withExtendedLifetime((first, second)) { XCTAssertEqual(index.searchCacheTableCount, 6) }
            print("SEARCH-CACHE summaries=50000 residentBytes=\(index.residentCacheBytes)")
            XCTAssertGreaterThan(index.residentCacheBytes, 0)
            XCTAssertLessThan(index.residentCacheBytes, 2 * 1_048_576, "The private index pager stays bounded after spilling 50,000 match summaries")
        }
        withExtendedLifetime(first) { XCTAssertEqual(index.searchCacheTableCount, 3) }
        let third = try HistoryOffsetIndex.SearchCache(index)
        XCTAssertNil(try third.match(42))
        withExtendedLifetime((first, third)) { XCTAssertEqual(index.searchCacheTableCount, 6) }
        let held = try XCTUnwrap(first.match(42))
        XCTAssertEqual(held.count, 2); XCTAssertEqual(held.preview, preview)
        XCTAssertEqual(held.drawing?.toolCallID, call); XCTAssertEqual(held.omittedOutputs, [call])
        XCTAssertTrue(try XCTUnwrap(first.call(call, at: 42)).paired)
        XCTAssertNil(try first.call(call, at: 43), "Reused IDs belong to a record offset, never every issuer with that ID")
    }
    func testSourceSearchUsesTheSameByteBudgetAndOversizedRecordsRunAlone() async throws {
        let fixture = try await searchCostFixture((0..<3).map { ("large\($0)", ["role": WireValue.string("user"), "content": .string("needle")], 20 * 1_048_576) })
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for rendered in [false, true] {
            let cost = SearchDecodeCost(); await fixture.reader.observeSearchDecodes { cost.observe($0) }
            let found = try await fixture.reader.searchContent(path: fixture.path.path, query: "needle", start: 0, renderedAgentProse: rendered)
            XCTAssertEqual(found.hits.count, 3)
            let measured = cost.snapshot
            XCTAssertEqual(measured.counts.count, 3); XCTAssertTrue(measured.counts.values.allSatisfy { $0 == 1 })
            XCTAssertLessThanOrEqual(measured.bytes, fixture.bytes)
            XCTAssertLessThan(measured.peak, 21 * 1_048_576, "An oversized record cannot share a batch with even one neighbour")
        }
    }
    func testWideToolSearchDecodesEachRecordOnceAndYieldsItsWholeBudget() async throws {
        let fixture = try await wideSearchFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cost = SearchDecodeCost(), order = SearchOrder()
        let ready = expectation(description: "The search has decoded enough work to test its next budget boundary")
        cost.ready = ready
        await fixture.reader.observeSearchDecodes { cost.observe($0) }
        await fixture.reader.observeSearchReads { if $0 == .scanned { order.add("search") } }
        let search = Task { try await fixture.reader.searchContent(path: fixture.path.path, query: "receiptneedle", start: 0, renderedAgentProse: true) }
        await fulfillment(of: [ready], timeout: 30)
        var elapsed = 0.0, pages = 0
        repeat {
            let began = ProcessInfo.processInfo.systemUptime
            let page = try await fixture.reader.read(path: fixture.path.path, position: fixture.messages.count - 1)
            elapsed = max(elapsed, ProcessInfo.processInfo.systemUptime - began); pages += 1
            XCTAssertTrue(page.messages.contains { $0.id == "receipt63" })
            order.add("page")
            await Task.yield()
        } while !order.events.contains("search")
        let found = try await search.value, measured = cost.snapshot
        print("WIDE-SEARCH sourceBytes=\(fixture.bytes) decodedBytes=\(measured.bytes) peakBatch=\(measured.peak) issuerDecodes=\(measured.counts[fixture.offsets["issuer"]!, default: 0]) pageSeconds=\(elapsed) order=\(order.events)")
        XCTAssertEqual(found.hits.count, 64); XCTAssertNil(found.next)
        XCTAssertEqual(found.hits.reduce(0) { $0 + ($1.count ?? 1) }, 64)
        XCTAssertEqual(measured.counts[fixture.offsets["issuer"]!], 1, "A wide round must decode its 8 MiB issuer once")
        XCTAssertTrue(measured.counts.values.allSatisfy { $0 == 1 }, "Primary and dependency reads share the same once-per-pass cache")
        XCTAssertLessThanOrEqual(measured.bytes, fixture.bytes)
        XCTAssertLessThanOrEqual(measured.peak, HistoryReader.searchRunBytes, "Dependencies consume the same 16 MiB budget as primary records")
        XCTAssertEqual(order.events.first, "page"); XCTAssertGreaterThan(pages, 1)
        XCTAssertLessThan(elapsed, 0.75, "Paging must run at the budget boundary inside a wide tool round")
    }
    func testWideAgentArgumentsDoNotRepeatAcrossNeighbourProjections() async throws {
        var entries = try wideSearchEntries(), issuer = entries[0].1
        var calls = try XCTUnwrap(issuer["content"]?.array)
        for n in calls.indices {
            var call = try XCTUnwrap(calls[n].object)
            call["name"] = .string("subagent_start")
            var input: [String: WireValue] = ["task": .string("Task \(n)")]
            if n == 0 { input["extra"] = .string(String(repeating: "x", count: 28 * 1_048_576)) }
            call["arguments"] = .object(input); calls[n] = .object(call)
        }
        issuer["content"] = .array(calls); entries[0] = ("issuer", issuer, 0)
        let fixture = try await searchCostFixture(entries); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let agents = AgentTranscriptPresentation(id: "parent", isManagedSubagent: false, busy: false, familyWaiting: false,
            subagentNumbers: [:], subagentEfforts: [:], subagentCosts: [:], originalSubagentAvailability: [:],
            agentCoordination: [:], childSummaries: [:], heldAgentChildren: [])
        let ready = expectation(description: "The large agent issuer has started"), cost = SearchDecodeCost(), order = SearchOrder()
        cost.ready = ready
        await fixture.reader.observeSearchDecodes { cost.observe($0) }
        await fixture.reader.observeSearchReads { if $0 == .scanned { order.add("search") } }
        let search = Task { try await fixture.reader.searchContent(path: fixture.path.path, query: "receiptneedle", start: 0,
            renderedAgentProse: true, agentPresentation: agents) }
        await fulfillment(of: [ready], timeout: 30)
        var elapsed = 0.0, pages = 0
        repeat {
            let began = ProcessInfo.processInfo.systemUptime
            _ = try await fixture.reader.read(path: fixture.path.path, position: fixture.messages.count - 1)
            elapsed = max(elapsed, ProcessInfo.processInfo.systemUptime - began); pages += 1
            order.add("page"); await Task.yield()
        } while !order.events.contains("search")
        let found = try await search.value
        print("AGENT-DEPENDENCIES decodedBytes=\(cost.snapshot.bytes) pageSeconds=\(elapsed) pages=\(pages)")
        XCTAssertEqual(found.hits.reduce(0) { $0 + ($1.count ?? 1) }, 64)
        XCTAssertTrue(cost.snapshot.counts.values.allSatisfy { $0 == 1 })
        XCTAssertLessThanOrEqual(cost.snapshot.bytes, fixture.bytes)
        XCTAssertLessThan(elapsed, 0.75, "A receipt must not reproject every sibling's large agent arguments")
        XCTAssertEqual(order.events.first, "page"); XCTAssertGreaterThan(pages, 1)
    }
    func testCapturedWideToolPagesShareTheSearchDecodeBudget() async throws {
        let fixture = try await wideSearchFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        for page in [[fixture.messages[0]], Array(fixture.messages.suffix(64)), fixture.messages] {
            let cost = SearchDecodeCost()
            await fixture.reader.observeSearchDecodes { cost.observe($0) }
            let found = try await fixture.reader.searchContent(path: fixture.path.path, query: "receiptneedle", start: 0,
                renderedAgentProse: true, presented: page)
            let measured = cost.snapshot
            print("CAPTURED-WIDE rows=\(page.count) sourceBytes=\(fixture.bytes) decodedBytes=\(measured.bytes) peakBatch=\(measured.peak)")
            XCTAssertEqual(found.hits.reduce(0) { $0 + ($1.count ?? 1) }, 64)
            XCTAssertNil(found.next)
            XCTAssertTrue(measured.counts.values.allSatisfy { $0 == 1 }, "Captured and unloaded dependencies must share one cache: page=\(page.count)")
            XCTAssertLessThanOrEqual(measured.bytes, fixture.bytes)
            XCTAssertLessThanOrEqual(measured.peak, HistoryReader.searchRunBytes)
        }
    }

    @MainActor func testNumberedFenceKeepsHeadingCopyBoundaries() throws {
        let setup = "# Setup\n\n1. ```sh\n   # comment\n   echo ok\n   ```\n\n"
        let done = "# Done\nFinished.", source = setup + done
        let sections = TranscriptCopy.targets(in: source).filter { if case .section = $0.kind { return true }; return false }
        XCTAssertEqual(sections.map(\.text), [setup, done])
        let message = TranscriptMessage(id: "reply", role: "assistant", text: source)
        let row = TranscriptNativeReplyRow(inputs: .init(item: TranscriptNativePartView.wordsItem(message), fresh: false,
            actions: .init(), width: 620, environment: .init(), disclosure: .init()))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = row
        defer { window.contentView = nil; window.close() }
        row.layoutSubtreeIfNeeded()
        let surface = try XCTUnwrap(ConversationPaneTests.views(NativeMarkdownContainer.self, in: row).first)
        let text = surface.textView, manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
        let range = (text.string as NSString).range(of: "Done")
        let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        surface.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved,
            location: surface.convert(NSPoint(x: rect.midX, y: rect.midY + text.topInset), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
        let action = try XCTUnwrap(surface.subviews.compactMap { $0 as? MarkdownHeadingActionView }.first)
        XCTAssertEqual(action.copy.accessibilityLabel(), "Copy Done as Markdown")
        XCTAssertTrue(action.copy.accessibilityPerformPress())
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), done)
        XCTAssertEqual(text.copyTargets().map(\.label), ["Copy Setup as Markdown", "Copy Done as Markdown"])
    }

    func testReusedToolDependenciesStayWithinPagingBudget() throws {
        let index = try HistoryOffsetIndex()
        for n in 0..<5_000 {
            let call = HistoryOffset(id: "call\(n)", offset: 0, length: 1, type: "message", role: "assistant", calls: ["reused"])
            let result = HistoryOffset(id: "result\(n)", offset: 0, length: 1, type: "message", role: "toolResult", resultCall: "reused")
            for record in [call, result] { try index.insert(record); try index.append(record) }
        }
        try index.finish()
        let start = ProcessInfo.processInfo.systemUptime
        for n in 0..<5_000 {
            let peers = try index.related(to: "call\(n)", calls: ["reused"], result: nil, operation: nil)
            XCTAssertEqual(peers.map(\.id), ["result\(n)"])
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("REUSED-DEPENDENCIES pairs=5000 lookups=5000 seconds=\(elapsed)")
        XCTAssertLessThan(elapsed, 1.0, "Indexed neighbours must not scan and sort the reuse set for each call")
    }

    func testDependencyPositionsFollowSelectionAndMetadata() throws {
        let index = try HistoryOffsetIndex()
        var records: [HistoryOffset] = []
        for n in 0..<3 {
            records += [.init(id: "c\(n)", offset: 0, length: 1, type: "message", calls: ["reuse"]),
                        .init(id: "r\(n)", offset: 0, length: 1, type: "message", resultCall: n == 2 ? "old" : "reuse")]
        }
        for ref in records { try index.insert(ref); try index.append(ref) }
        try index.branch(from: nil, kept: ["c0", "r0", "r1", "c2", "r2"])
        var receipt = records[5]; receipt.resultCall = "reuse"; try index.replaceMetadata(receipt)
        func check() throws {
            for n in [0, 2] {
                XCTAssertEqual(try index.related(to: "c\(n)", calls: ["reuse"], result: nil, operation: nil).map(\.id), ["r\(n)"])
                XCTAssertEqual(try index.related(to: "r\(n)", calls: [], result: "reuse", operation: nil).map(\.id), ["c\(n)"])
            }
        }
        XCTAssertEqual(try index.related(to: "c0", calls: ["reuse"], result: nil, operation: nil).map(\.id), ["r1"], "An abandoned issuer cannot hide the retained receipt")
        XCTAssertEqual(try index.related(to: "r1", calls: [], result: "reuse", operation: nil).map(\.id), ["c0"])
        try index.selectTimeline(["c2", "r2", "c0", "r0"]); try check()
        try index.finish(); try check()
        XCTAssertTrue(try index.related(to: "c1", calls: ["reuse"], result: nil, operation: nil).isEmpty)
    }

    private final class SearchOrder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        var events: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }
    func testPagingCanFinishWhileFindScansReusedCalls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-find-paging-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("fixture.jsonl"), reader = HistoryReader(indexDirectory: root)
        var bytes = Data("{\"type\":\"session\",\"version\":3,\"id\":\"fixture\"}\n".utf8)
        var parent: WireValue = .null
        for n in 0..<5_000 {
            for (id, message): (String, [String: WireValue]) in [
                ("call\(n)", ["role": .string("assistant"), "content": .array([.object(["type": .string("toolCall"), "id": .string("reused"), "name": .string("fixture"), "arguments": .object(["value": .number(Double(n))])])])]),
                ("result\(n)", ["role": .string("toolResult"), "toolCallId": .string("reused"), "toolName": .string("fixture"), "content": .string("result \(n)")])
            ] {
                let entry: WireValue = .object(["type": .string("message"), "id": .string(id), "parentId": parent, "message": .object(message)])
                bytes.append(try JSONEncoder().encode(entry)); bytes.append(10); parent = .string(id)
            }
        }
        try bytes.write(to: path)
        _ = try await reader.read(path: path.path, whole: true)
        let indexed = expectation(description: "Find has captured its index"), order = SearchOrder()
        await reader.observeSearchReads { stage in
            if stage == .indexed { indexed.fulfill() }
            if stage == .scanned { order.add("search") }
        }
        let cost = SearchDecodeCost(); await reader.observeSearchDecodes { cost.observe($0) }
        let search = Task { try await reader.searchContent(path: path.path, query: "absent needle", start: 0, renderedAgentProse: true) }
        await fulfillment(of: [indexed], timeout: 10)
        let start = ProcessInfo.processInfo.systemUptime
        let page = try await reader.read(path: path.path, position: 8_000)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        order.add("page")
        let result = try await search.value
        print("FIND-PAGING pairs=5000 page-seconds=\(elapsed) order=\(order.events)")
        XCTAssertEqual(order.events, ["page", "search"], "Find must yield its actor so paging can finish during the scan")
        XCTAssertLessThan(elapsed, 0.5, "A warm page must not wait for Find's 5,000-record window")
        XCTAssertTrue(page.messages.contains { $0.id == "call4000" })
        XCTAssertTrue(result.hits.isEmpty); XCTAssertEqual(result.next, 5_000)
        assertBoundedSearch(cost, sourceBytes: bytes.count, name: "5000 reused-ID pairs")
        let cachedBytes = await reader.retainedIndexBytes
        let cancelling = expectation(description: "The superseded query has its index")
        await reader.observeSearchReads { if $0 == .indexed { cancelling.fulfill() } }
        let obsolete = Task { try await reader.searchContent(path: path.path, query: "another absent needle", start: 0, renderedAgentProse: true) }
        await fulfillment(of: [cancelling], timeout: 10)
        obsolete.cancel()
        do { _ = try await obsolete.value; XCTFail("The superseded search must cancel") }
        catch is CancellationError { }
        let retainedBytes = await reader.retainedIndexBytes
        XCTAssertEqual(retainedBytes, cachedBytes, "Cancelling Find must not discard the warm index needed by paging")
    }

    @MainActor func testExpandedReadAndDiffSurviveHostEviction() async throws {
        let lines = (1...100).map { "line \($0)" }.joined(separator: "\n")
        for name in ["read", "edit"] {
            let tool = name == "read" ? TranscriptNativeWorkBehaviourTests.read(output: lines)
                : ToolView(id: "r1", name: "edit", state: "completed", input: WireValue.object(["path": .string("fixture.txt"), "oldText": .string(""), "newText": .string(lines)]).pretty, output: "ok", truncated: false)
            for (timeline, count) in [(false, 1), (false, 8), (true, 1)] {
                var message = TranscriptMessage.project(id: "reply", message: try XCTUnwrap(toolEntry(name, arguments: .object(["path": .string("fixture.txt")]))["message"]?.object))
                message.tools = (0..<count).map { index in var value = tool; value.id = "r\(index)"; return value }
                if timeline {
                    // The generated call's stable ID is the timeline part's ID.
                    message.tools?[0].id = "call"
                } else { message.responseTimeline = nil }
                let item = try XCTUnwrap(TaskTranscriptPlan.rows([message], lifecycle: nil).first { if case .block(let block) = $0 { return block.presentation == .work }; return false })
                let disclosure = TranscriptDisclosure()
                if case .block(let block) = item { disclosure.setOpen(true, .work(block.key)) }
                disclosure.setOpen(true, .tool(ToolOccurrence.key(message.id, message.tools![0].id)))
                let row = TranscriptRowContainer(item: item, fresh: false, actions: .init(), disclosure: disclosure)
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = NSView(); window.contentView?.addSubview(row)
                defer { window.contentView = nil; window.close() }
                func draw() { row.frame.size = row.measure(width: 620); row.layoutForViewport(); window.displayIfNeeded() }
                draw()
                let collapsed = row.measure(width: 620).height
                let more = try XCTUnwrap(ConversationPaneTests.views(TranscriptCardMoreLines.self, in: row).first)
                XCTAssertTrue(more.accessibilityPerformPress())
                try await eventually("Expanded card has validated its own height") { draw(); return !row.needsMountedValidation }
                let height = row.measure(width: 620).height
                XCTAssertGreaterThan(height, collapsed, "Expanding the body updates the cached work-list height")
                XCTAssertEqual(height, row.hostedFittingHeight, accuracy: 1)
                window.makeFirstResponder(nil); row.releaseHost()
                XCTAssertFalse(row.isHosted, "The view must really have been evicted")
                row.prepareToDraw(); draw()
                if name == "read" { XCTAssertTrue(try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeReadCard.self, in: row).first).expanded) }
                else { XCTAssertTrue(try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeDiffCard.self, in: row).first).expanded) }
                XCTAssertEqual(row.measure(width: 620).height, row.hostedFittingHeight, accuracy: 1, "\(name), timeline=\(timeline): no blank gap after remount")
                XCTAssertEqual(row.measure(width: 620).height, height, accuracy: 1)
            }
        }
    }

    @MainActor func testMoreLinesKeepsItsExistingResizeBehavior() async throws {
        let (model, pane, window) = try await findFixture(saved: false)
        let session = try XCTUnwrap(model.selected)
        let tool = TranscriptNativeWorkBehaviourTests.read(output: (1...100).map { "line \($0)" }.joined(separator: "\n"))
        session.messages[1].tools = [tool]
        for case .block(let block) in TaskTranscriptPlan.rows(session.presentedMessages, lifecycle: nil) where block.presentation == .work {
            session.disclosure.setOpen(true, .work(block.key))
        }
        session.disclosure.setOpen(true, .tool(ToolOccurrence.key(session.messages[1].id, tool.id)))
        pane.refresh(); pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); pane.document.finishDisclosureMotion()
        let before = TranscriptNativeDocument.reducesMotionOverride
        TranscriptNativeDocument.reducesMotionOverride = false
        defer { TranscriptNativeDocument.reducesMotionOverride = before }
        let card = try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeReadCard.self, in: pane).first)
        let more = try XCTUnwrap(ConversationPaneTests.views(TranscriptCardMoreLines.self, in: card).first)
        XCTAssertTrue(more.accessibilityPerformPress()); XCTAssertTrue(card.expanded)
        XCTAssertFalse(pane.document.isMovingDisclosure, "Saving inner-card state must not add a new outer fold animation")
    }

    @MainActor func testReorderedFullTableCellDetailsCopyTheVisibleColumn() throws {
        let before = Set(MarkdownTableWindow.open.map(ObjectIdentifier.init))
        MarkdownTableWindow.open(header: [AttributedString("A"), AttributedString("B")],
            rows: (1...41).map { [AttributedString("A\($0)"), AttributedString("B\($0)")] })
        let window = try XCTUnwrap(MarkdownTableWindow.open.first { !before.contains(ObjectIdentifier($0)) })
        defer { window.close() }
        let controller = try XCTUnwrap(MarkdownTableWindow.controller(of: window))
        let table = try XCTUnwrap(controller.gridScroll.documentView as? NSTableView)
        table.moveColumn(1, toColumn: 0); table.reloadData()
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let rect = table.frameOfCell(atColumn: 0, row: 0), point = NSPoint(x: rect.midX, y: rect.midY)
        let clickedRow = table.row(at: point), clickedColumn = table.column(at: point)
        XCTAssertEqual(clickedRow, 0); XCTAssertEqual(clickedColumn, 0)
        let cell = try XCTUnwrap(table.view(atColumn: clickedColumn, row: clickedRow, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(cell.textField?.stringValue, "B1")
        table.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        controller.showCell(row: clickedRow, column: clickedColumn)
        let detail = try XCTUnwrap(controller.detailScroll.documentView as? NSTextView)
        XCTAssertEqual(detail.string, "B1")
        detail.selectAll(nil); detail.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "B1")
    }

    @MainActor func testHeadingCopyUsesTheRenderedTopLevelHeading() throws {
        let message = TranscriptMessage(id: "reply", role: "assistant", text: Self.nestedHeading)
        let row = TranscriptNativeReplyRow(inputs: .init(item: TranscriptNativePartView.wordsItem(message), fresh: false,
            actions: .init(), width: 620, environment: .init(), disclosure: .init(), toggle: { _ in }))
        let surface = try XCTUnwrap(ConversationPaneTests.views(NativeMarkdownContainer.self, in: row).first)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = row
        defer { window.contentView = nil; window.close() }
        row.layoutSubtreeIfNeeded()
        let text = surface.textView
        let range = (text.string as NSString).range(of: "Real")
        let manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
        let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        let point = NSPoint(x: rect.midX, y: rect.midY + text.topInset)
        surface.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: surface.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
        let action = try XCTUnwrap(surface.subviews.compactMap { $0 as? MarkdownHeadingActionView }.first)
        XCTAssertEqual(action.copy.accessibilityLabel(), "Copy Real as Markdown")
        NSPasteboard.general.clearContents()
        XCTAssertTrue(action.copy.accessibilityPerformPress())
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "# Real\n\nreal text.")
        XCTAssertEqual(text.copyTargets().map(\.label), ["Copy Real as Markdown"], "Nested headings consume no top-level index")
    }

    func testSectionCopyMatchesParsedContainersAndMultilineSetextSource() {
        for prefix in ["- item\n\n  ## Nested\n\n  nested text\n\n", "1. item\n\n   Nested\n   ------\n\n   nested text\n\n",
                       "> ## Nested\n> text\n\n", "<!--\n# Hidden\n-->\n\n"] {
            let source = prefix + "# Real\n\nreal text."
            let sections = TranscriptCopy.targets(in: source).filter { if case .section = $0.kind { return true }; return false }
            XCTAssertEqual(sections.map(\.text), ["# Real\n\nreal text."], source)
        }
        let source = "Intro 🌍\r\n\r\nFirst **line**\r\nsecond line\r\n===========\r\n\r\nbody\r\n\r\n# Peer\r\nlast"
        let sections = TranscriptCopy.targets(in: source).filter { if case .section = $0.kind { return true }; return false }
        XCTAssertEqual(sections.map(\.text), ["First **line**\r\nsecond line\r\n===========\r\n\r\nbody\r\n\r\n", "# Peer\r\nlast"])
    }

    func testSectionCopyPreservesCRLFAndMixedLineEndings() {
        for ending in ["\r", "\r\n", "\n"] {
            let intro = "Intro 🌍" + ending + ending
            let one = "# One" + ending + "body" + ending + ending
            let two = "# Two" + ending + "more"
            let targets = TranscriptCopy.targets(in: intro + one + two)
            XCTAssertEqual(targets.map(\.text), [intro, one, two], ending.debugDescription)
        }
        let intro = "Intro 🌍\r\n\r", one = "First **line**\nsecond line\r=======\r\nbody\r\r", two = "# Two\nmore"
        XCTAssertEqual(TranscriptCopy.targets(in: intro + one + two).map(\.text), [intro, one, two])
    }

    func testLiveMarkdownOffsetsRespectCRLFAndMixedLineEndings() {
        for ending in ["\r", "\r\n", "\n"] {
            let intro = "Intro 🌍\r\n\r", first = "- first" + ending, second = "- second" + ending + ending, tail = "# Last" + ending + "body"
            let parsed = TranscriptMarkdown.liveBlocksWithItems(intro + first + second + tail, style: .prose)
            XCTAssertEqual(parsed.blocks.map(\.offset), [0, intro.utf8.count, (intro + first + second).utf8.count,
                (intro + first + second + "# Last" + ending).utf8.count], ending.debugDescription)
            XCTAssertEqual(parsed.items, [[], [intro.utf8.count, (intro + first).utf8.count], [], []], ending.debugDescription)
        }
    }

    @MainActor func testHeadingCopyControlStaysInsideNarrowReplyRows() throws {
        for width: CGFloat in [320, 360, 620, 760] {
            let message = TranscriptMessage(id: "reply", role: "assistant", text: "# Real\n\nreal text.")
            let row = TranscriptNativeReplyRow(inputs: .init(item: TranscriptNativePartView.wordsItem(message), fresh: false,
                actions: .init(), width: width, environment: .init(), disclosure: .init(), toggle: { _ in }))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = row
            defer { window.contentView = nil; window.close() }
            row.layoutSubtreeIfNeeded()
            let surface = try XCTUnwrap(ConversationPaneTests.views(NativeMarkdownContainer.self, in: row).first)
            let text = surface.textView, manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
            let range = (text.string as NSString).range(of: "Real")
            let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            let point = NSPoint(x: rect.midX, y: rect.midY + text.topInset)
            surface.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: surface.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
            let action = try XCTUnwrap(surface.subviews.compactMap { $0 as? MarkdownHeadingActionView }.first)
            XCTAssertTrue(surface.bounds.contains(action.frame), "\(width)-point surface: \(action.frame) outside \(surface.bounds)")
            XCTAssertTrue(row.bounds.contains(surface.convert(action.frame, to: row)), "\(width)-point row clips heading Copy")
        }
    }

    static func editTool(name: String = "edit", truncated: Bool? = false) throws -> ToolView {
        let values = name == "write" ? ["path": "fixture.txt", "content": after] : ["path": "fixture.txt", "oldText": before, "newText": after]
        return ToolView(id: "edit", name: name, state: "completed", input: String(decoding: try JSONEncoder().encode(values), as: UTF8.self),
                        output: "ok", truncated: false, path: "fixture.txt", inputTruncated: truncated)
    }
    func testCompleteEditKeepsLiteralTruncationMarkerAndChangedTails() throws {
        for flag: Bool? in [false, nil] {
            let tool = try Self.editTool(truncated: flag)
            guard case .diff(let request, _, _, _, _) = TranscriptToolRow.card(of: tool, fetched: nil, model: TranscriptToolRow.model(of: tool), linked: false) else { return XCTFail("Expected edit card") }
            XCTAssertTrue(request.complete)
            XCTAssertEqual(request.before, Self.before); XCTAssertEqual(request.after, Self.after)
            XCTAssertTrue(request.rows.contains { $0.kind == .removed && $0.text == "old tail" })
            XCTAssertTrue(request.rows.contains { $0.kind == .added && $0.text == "new tail" })
            XCTAssertTrue(request.rows.contains { $0.kind == .context && $0.text == "…[truncated, 12 more bytes]" })
        }
    }
    func testCompleteWriteKeepsLiteralTruncationMarker() throws {
        let tool = try Self.editTool(name: "write")
        guard case .diff(let request, _, _, _, _) = TranscriptToolRow.card(of: tool, fetched: nil, model: TranscriptToolRow.model(of: tool), linked: false) else { return XCTFail("Expected write card") }
        XCTAssertTrue(request.complete); XCTAssertEqual(request.after, Self.after)
        XCTAssertEqual(request.rows.map(\.text), Self.after.components(separatedBy: "\n"))
    }
    func testExplicitlyTruncatedEditStillSeparatesTheLegacyMarker() throws {
        let tool = try Self.editTool(truncated: true)
        let request = try XCTUnwrap(TranscriptActivity.editRequest(tool))
        XCTAssertFalse(request.complete)
        XCTAssertEqual(request.before, "header\n"); XCTAssertEqual(request.after, "header\n")
        XCTAssertEqual(request.rows.last?.text, "…[truncated, 12 more bytes]\nnew tail")
    }

    @MainActor private func findFixture(saved: Bool, reasoning: Bool = false, source: String = "**alpha** beta", content: WireValue? = nil, entries: [WireValue]? = nil) async throws -> (WorkspaceModel, NativeTranscriptPane, NSWindow) {
        let root = scratchRoot("ordinary-markdown-find")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let answer: WireValue = content ?? (saved && reasoning ? .array([
            .object(["type": .string("thinking"), "thinking": .string("**alpha** beta")]),
            .object(["type": .string("text"), "text": .string("Done.")])]) : .string(saved ? source : "Earlier saved text"))
        let records: [WireValue] = [.object(["type": .string("session"), "version": .number(3), "id": .string("ordinary-find")])] + (entries ?? [
            .object(["type": .string("message"), "id": .string("question"), "parentId": .null,
                     "message": .object(["role": .string("user"), "content": .string("Reply")])]),
            .object(["type": .string("message"), "id": .string("reply"), "parentId": .string("question"),
                     "message": .object(["role": .string("assistant"), "content": answer])])])
        var bytes = Data()
        for record in records { bytes.append(try JSONEncoder().encode(record)); bytes.append(10) }
        let path = root.appendingPathComponent("find.jsonl"); try bytes.write(to: path)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        model.chats = [ChatRecord(id: "ordinary-find", workspaceID: "project", title: "Find", path: path.path, profileID: "profile")]
        await model.select("ordinary-find")
        let session = try XCTUnwrap(model.selected)
        if !saved {
            session.messages[1].text = reasoning ? "Done." : source; session.messages[1].state = "streaming"
            if reasoning { session.messages[1].thinking = "**alpha** beta" }
        }
        let pane = NativeTranscriptPane()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = pane; window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in pane.closeFind(focusing: false); window.contentView = nil; window.close() }
        pane.showTranscript(model: model, session: session, state: saved ? "idle" : "running", canFork: false, canQuote: false, enabled: true)
        return (model, pane, window)
    }
    @MainActor private func checkFind(saved: Bool, reasoning: Bool = false, raw: Bool = false) async throws {
        let (model, pane, window) = try await findFixture(saved: saved, reasoning: reasoning)
        if raw { model.selected?.disclosure.setOpen(true, .source("reply")); pane.refresh() }
        pane.showFind(); pane.find.setQuery("alpha beta")
        try await eventually("Ordinary reply search finished") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching }
        XCTAssertFalse(pane.find.failed)
        XCTAssertEqual(pane.find.matches.map(\.messageID), ["reply"])
        guard !pane.find.matches.isEmpty else { return }
        try await eventually("The phrase across emphasis is visibly highlighted") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return !pane.document.focusPending && pane.document.focusText != nil
        }
        let text = try XCTUnwrap(pane.document.focusText), range = pane.document.focusRange
        XCTAssertEqual((text.string as NSString).substring(with: range), "alpha beta")
        let manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
        XCTAssertNotNil(manager.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil))
        var rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        rect.origin.x += text.textContainerOrigin.x; rect.origin.y += text.textContainerOrigin.y
        XCTAssertTrue(pane.scrollView.contentView.bounds.intersects(text.convert(rect, to: pane.scrollView.contentView)))
        XCTAssertEqual(reasoning ? model.selected?.messages.last?.thinking : model.selected?.messages.last?.text,
                       "**alpha** beta", "Find leaves source Markdown intact")
    }
    @MainActor func testFindMatchesFormattedOrdinaryLiveReply() async throws { try await checkFind(saved: false) }
    @MainActor func testFindMatchesFormattedOrdinaryReopenedReply() async throws { try await checkFind(saved: true) }
    @MainActor func testFindMatchesFormattedLiveReasoning() async throws { try await checkFind(saved: false, reasoning: true) }
    @MainActor func testFindMatchesFormattedReopenedReasoning() async throws { try await checkFind(saved: true, reasoning: true) }
    @MainActor func testRememberedViewRawKeepsStreamingFindRendered() async throws { try await checkFind(saved: false, raw: true) }
    @MainActor func testViewRawKeepsReasoningFindRendered() async throws { try await checkFind(saved: true, reasoning: true, raw: true) }

    @MainActor private func checkRawFind(unsaved: Bool = false, noJournal: Bool = false, alreadySearching: Bool = false) async throws {
        let source = "[site](https://example.test)"
        let (model, pane, window) = try await findFixture(saved: true, source: source)
        let session = try XCTUnwrap(model.selected)
        let replyID = unsaved ? "unsaved-reply" : "reply"
        if unsaved { session.messages[1] = TranscriptMessage(id: replyID, role: "assistant", text: source) }
        if noJournal { model.chats[0].path = nil }
        pane.refresh(); pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        if alreadySearching {
            pane.showFind(); pane.find.setQuery("example.test")
            try await eventually("Rendered link search finishes") { !pane.find.searching }
            XCTAssertTrue(pane.find.matches.isEmpty, "The rendered link hides its destination")
        }
        let row = try XCTUnwrap(pane.document.retainedRows.first { ReplySource.replyID(of: $0.contentItem) == replyID })
        row.toggleDisclosure(.source(replyID))
        pane.refresh(); pane.document.finishDisclosureMotion(); pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        XCTAssertTrue(ConversationPaneTests.views(TranscriptPlainTextView.self, in: row).contains { $0.string == source && !$0.isHiddenOrHasHiddenAncestor })
        if !alreadySearching { pane.showFind(); pane.find.setQuery("example.test") }
        try await eventually("Raw reply search finishes") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching }
        XCTAssertFalse(pane.find.failed)
        XCTAssertEqual(pane.find.matches.map(\.messageID), [replyID])
        guard !pane.find.matches.isEmpty else { return }
        if alreadySearching {
            XCTAssertNil(pane.document.highlights.focus, "A refresh that gains its first match creates no navigation focus")
            XCTAssertFalse(pane.document.focusPending)
            pane.find.step(1)
        }
        try await eventually("The visible raw destination is highlighted") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return !pane.document.focusPending && pane.document.focusText != nil
        }
        let text = try XCTUnwrap(pane.document.focusText), range = pane.document.focusRange
        XCTAssertEqual((text.string as NSString).substring(with: range), "example.test")
        XCTAssertNotNil(text.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil))
        row.toggleDisclosure(.source(replyID)); pane.refresh()
        try await eventually("Switching back refreshes the active search") { !pane.find.searching }
        XCTAssertTrue(pane.find.matches.isEmpty)
        XCTAssertEqual(session.messages.last?.text, source)
    }
    @MainActor func testFindMatchesViewRawInSavedReply() async throws { try await checkRawFind() }
    @MainActor func testFindMatchesViewRawInUnsavedReply() async throws { try await checkRawFind(unsaved: true) }
    @MainActor func testFindMatchesViewRawWithoutJournal() async throws { try await checkRawFind(noJournal: true) }
    @MainActor func testViewRawRefreshesAnActiveFind() async throws { try await checkRawFind(alreadySearching: true) }

    @MainActor private func assertFind(_ query: String, in pane: NativeTranscriptPane, window: NSWindow, record: String = "reply") async throws {
        pane.showFind(); pane.find.setQuery(query)
        try await eventually("Search finishes for \(query)") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching }
        XCTAssertFalse(pane.find.failed)
        XCTAssertEqual(pane.find.matches.map(\.messageID), [record])
        guard !pane.find.matches.isEmpty else { return }
        try await eventually("Visible match for \(query)") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return !pane.document.focusPending && pane.document.focusText != nil
        }
        let text = try XCTUnwrap(pane.document.focusText), range = pane.document.focusRange
        XCTAssertEqual((text.string as NSString).substring(with: range), query)
        let manager = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
        XCTAssertNotNil(manager.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil))
        var rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        rect.origin.x += text.textContainerOrigin.x; rect.origin.y += text.textContainerOrigin.y
        let point = NSPoint(x: rect.midX, y: rect.midY), clip = pane.scrollView.contentView
        XCTAssertTrue(clip.bounds.contains(text.convert(point, to: clip)), "The match is visible in the transcript")
        if let inner = text.enclosingScrollView, inner !== pane.scrollView {
            XCTAssertTrue(inner.contentView.bounds.contains(text.convert(point, to: inner.contentView)), "The match is visible inside its card")
        }
    }
    @MainActor func testFindIncludesVisibleOrderedMarkersInSavedReply() async throws {
        let (_, pane, window) = try await findFixture(saved: true, source: "1. alpha\n2. beta")
        try await assertFind("2.", in: pane, window: window)
    }
    @MainActor func testFindIncludesVisibleOrderedMarkersInLiveReply() async throws {
        let (_, pane, window) = try await findFixture(saved: false, source: "1. alpha\n2. beta")
        try await assertFind("2.", in: pane, window: window)
    }

    @MainActor func testFindUsesRawCompletedSegmentWhileAnotherSegmentStreams() async throws {
        let source = "[site](https://example.test)", later = "**later** text"
        let (model, pane, window) = try await findFixture(saved: false, source: source + later)
        let session = try XCTUnwrap(model.selected)
        var timeline = ResponseTimeline()
        timeline.consume(.init(attemptID: "fixture", ordinal: 0, itemID: "first", kind: "text", update: "replace", text: source))
        timeline.consume(.init(attemptID: "fixture", ordinal: 1, itemID: "later", kind: "text", update: "append", text: later))
        session.messages[1].responseTimeline = timeline
        pane.refresh(); pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let row = try XCTUnwrap(pane.document.retainedRows.first {
            if case .block(let block) = $0.contentItem { return block.part?.id == timeline.segments[0].id }; return false
        })
        row.toggleDisclosure(.source("reply")); pane.refresh(); pane.document.finishDisclosureMotion()
        pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        XCTAssertTrue(TranscriptNativeDocument.textViews(in: row).contains { $0.string == source })
        XCTAssertTrue(ConversationPaneTests.views(NativeMarkdownContainer.self, in: pane.document).contains { !$0.isParked && $0.textView.string == "later text" })
        try await assertFind("example.test", in: pane, window: window)
    }

    @MainActor func testSourceRefreshKeepsTheReaderAwayFromTheCurrentFindHit() async throws {
        let (model, pane, window) = try await findFixture(saved: true, source: "needle here and needle again")
        let session = try XCTUnwrap(model.selected)
        session.messages += [.init(id: "other-question", role: "user", text: "Read something else"),
                             .init(id: "other-reply", role: "assistant", text: String(repeating: "Other plain paragraph.\n\n", count: 100))]
        pane.refresh(); pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        pane.showFind(); pane.find.setQuery("needle")
        try await eventually("The initial search lands") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return !pane.find.searching && !pane.document.focusPending && pane.document.focusText != nil
        }
        XCTAssertEqual(pane.find.matches.count, 2)
        pane.find.step(1)
        try await eventually("The reader chooses the second hit") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.document.focusPending
        }
        XCTAssertEqual(pane.find.current, 1)
        let focus = try XCTUnwrap(pane.document.highlights.focus), current = pane.find.current
        let clip = pane.scrollView.contentView
        pane.page.readerWillNavigate(upward: false)
        clip.setBoundsOrigin(NSPoint(x: 0, y: 750)); pane.scrollView.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: pane.scrollView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: pane.scrollView)
        pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let row = try XCTUnwrap(pane.document.retainedRows.first { ReplySource.replyID(of: $0.contentItem) == "other-reply" })
        row.toggleDisclosure(.source("other-reply")); pane.refresh(); pane.document.finishDisclosureMotion()
        pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let origin = clip.bounds.origin
        XCTAssertGreaterThan(origin.y, 500, "The reader has left the hit behind")
        XCTAssertEqual(pane.document.highlights.focus, focus, "Refreshing never clears and reinstalls navigation focus")
        XCTAssertEqual(pane.find.current, current, "Keep the selected match while refreshing")
        try await eventually("Refreshed results finish without a reveal") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return !pane.find.searching && !pane.document.focusPending
        }
        for _ in 0..<5 { await Task.yield(); pane.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        XCTAssertEqual(clip.bounds.origin.y, origin.y, accuracy: 1, "Refreshing cannot scroll back to the old hit")
        XCTAssertEqual(pane.document.highlights.focus, focus)
        XCTAssertEqual(pane.find.current, current)
    }

    @MainActor func testFindRefreshKeepsNewerNextAndPreviousSelections() async throws {
        let (_, pane, window) = try await findFixture(saved: true, source: "needle one, needle two, needle three")
        pane.showFind(); pane.find.setQuery("needle")
        try await eventually("Initial Find lands") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return !pane.find.searching && !pane.document.focusPending && pane.document.focusText != nil
        }
        let search = try XCTUnwrap(pane.find.search)
        var waiting: CheckedContinuation<Void, Never>?
        defer { waiting?.resume(); pane.find.search = search }
        pane.find.search = { id, query, start in
            let result = try await search(id, query, start)
            await withCheckedContinuation { waiting = $0 }
            return result
        }
        for direction in [1, -1] {
            let row = try XCTUnwrap(pane.document.retainedRows.first { ReplySource.replyID(of: $0.contentItem) == "reply" })
            row.toggleDisclosure(.source("reply")); pane.refresh(); pane.document.finishDisclosureMotion()
            try await eventually("Refresh reaches its held search result") { waiting != nil }
            pane.find.step(direction)
            try await eventually("Newer Find step lands") {
                pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.document.focusPending
            }
            let selection = pane.find.current, focus = try XCTUnwrap(pane.document.highlights.focus)
            let text = pane.document.focusText, range = pane.document.focusRange
            waiting?.resume(); waiting = nil
            try await eventually("Refresh finishes") {
                pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching
            }
            XCTAssertEqual(pane.find.current, selection, "The newer \(direction) step wins")
            XCTAssertEqual(pane.document.highlights.focus, focus, "Refresh retains the newer focused highlight")
            XCTAssertTrue(pane.document.focusText === text)
            XCTAssertEqual(pane.document.focusRange, range)
            XCTAssertFalse(pane.document.focusPending)
        }
    }

    @MainActor func testFindRefreshKeepsPendingNavigationWhenMatchIndexesChange() async throws {
        let (model, pane, window) = try await findFixture(saved: true, source: "needle here")
        var refreshing = false
        var searchWait: CheckedContinuation<Void, Never>?, revealWait: CheckedContinuation<Void, Never>?
        defer { searchWait?.resume(); revealWait?.resume() }
        pane.showFind()
        pane.find.search = { _, _, _ in
            if refreshing { await withCheckedContinuation { searchWait = $0 } }
            let ids = refreshing ? ["earlier", "reply", "target"] : ["reply", "target"]
            return ContentSearch(hits: ids.enumerated().map { ContentHit(id: $0.element, position: $0.offset, preview: "needle", count: 1) }, total: ids.count, next: nil, revision: "fixture")
        }
        pane.find.reveal = { _, id in
            XCTAssertEqual(id, "target")
            await withCheckedContinuation { revealWait = $0 }
            return true
        }
        pane.find.setQuery("needle")
        try await eventually("Initial results arrive") { !pane.find.searching }
        refreshing = true; pane.find.setQuery("needle", restarting: true)
        try await eventually("Refresh waits") { searchWait != nil }
        pane.find.step(1)
        try await eventually("The newer step waits for its missing page") { revealWait != nil }
        searchWait?.resume(); searchWait = nil
        try await eventually("Refresh inserts an earlier match") { !pane.find.searching }
        XCTAssertEqual(pane.find.current, 2)
        model.selected?.messages += [.init(id: "target-question", role: "user", text: "Later question"),
            .init(id: "target", role: "assistant", text: "Done.", thinking: "needle target", state: "complete")]
        pane.refresh(); pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        revealWait?.resume(); revealWait = nil
        try await eventually("The original Next action opens and highlights the loaded thought") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return !pane.document.focusPending && pane.document.focusText?.string == "needle target"
        }
        XCTAssertEqual(pane.document.highlights.focus?.record, "target")
    }

    private var twoUsers: [WireValue] {
        ["question", "reply"].enumerated().map { index, id in
            .object(["type": .string("message"), "id": .string(id), "parentId": index == 0 ? .null : .string("question"),
                     "message": .object(["role": .string("user"), "content": .string("user \(index + 1)")])])
        }
    }
    @MainActor func testSavedUserFindCountsOnlyDisplayedTextAndKeepsPreviousHighlight() async throws {
        let (_, pane, window) = try await findFixture(saved: true, entries: twoUsers)
        pane.showFind(); pane.find.setQuery("user")
        try await eventually("User search finishes") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching }
        XCTAssertEqual(pane.find.matches.count, 2)
        pane.find.step(-1)
        try await eventually("Previous reaches the other user's text") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return !pane.document.focusPending && pane.document.focusText?.string == "user 2"
        }
        XCTAssertEqual(pane.document.highlights.focus?.record, "reply")
        XCTAssertEqual(pane.document.highlights.focus?.occurrence, 0)
    }
    @MainActor func testReconciliationAdoptsClampedFocusWithoutNewNavigation() async throws {
        let (_, pane, window) = try await findFixture(saved: true, entries: twoUsers)
        pane.showFind()
        // Keep overcounts independent of the projection fix: a newly drawn
        // row may still reconcile a count obtained before its text changed.
        pane.find.search = { _, _, _ in
            ContentSearch(hits: [ContentHit(id: "question", position: 1, preview: "user", count: 2),
                                ContentHit(id: "reply", position: 2, preview: "user", count: 2)], total: 2, next: nil, revision: "fixture")
        }
        pane.document.onFocusResolved = nil
        pane.find.setQuery("user")
        try await eventually("Controlled counts arrive") { !pane.find.searching }
        pane.find.step(-1)
        let previous = try XCTUnwrap(pane.document.highlights.focus)
        XCTAssertEqual(previous.occurrence, 1)
        pane.document.focusPending = false
        let origin = pane.scrollView.contentView.bounds.origin
        pane.find.reconcile("reply", needle: "user", rendered: 1)
        let adopted = pane.document.highlights.focus
        XCTAssertEqual(adopted?.record, "reply")
        XCTAssertEqual(adopted?.occurrence, 0)
        XCTAssertEqual(adopted?.serial, previous.serial, "Count adoption creates no navigation request")
        XCTAssertFalse(pane.document.focusPending)
        pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        XCTAssertEqual(pane.scrollView.contentView.bounds.origin, origin)
        XCTAssertEqual(pane.document.focusText?.string, "user 2")
        XCTAssertEqual(pane.document.focusRange, NSRange(location: 0, length: 4))
        pane.document.highlights.focus = nil
        pane.find.reconcile("reply", needle: "user", rendered: 2)
        XCTAssertNil(pane.document.highlights.focus, "Reconciliation cannot invent focus after the reader cleared it")
    }

    @MainActor private func rowPayload(_ message: TranscriptMessage) -> String {
        let item = TranscriptItem.message(message)
        let row = TranscriptRowRenderer.content(for: item, inputs: .init(item: item, fresh: false, actions: .init(), width: 620,
            environment: .init(), disclosure: .init(compaction: true)))
        row.frame = CGRect(x: 0, y: 0, width: 620, height: 500)
        row.frame.size.height = row.settle().height
        row.layoutSubtreeIfNeeded()
        if message.kind == "notice" {
            return ConversationPaneTests.views(TranscriptLabel.self, in: row).filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if message.kind == "versionBanner" {
            return row.subviews.compactMap { ($0 as? TranscriptLabel)?.text }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if let execution = row as? TranscriptNativeExecutionRow {
            let body = TranscriptNativeDocument.textViews(in: row).filter { $0.accessibilityLabel() != "Button" }.map { Self.copiedText($0) }.filter { !$0.isEmpty }.joined(separator: "\n")
            return [execution.line.accessibilityLabel() ?? "", body].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if row is TranscriptNativeAgentRow {
            var parts: [String] = []
            func visit(_ view: NSView) {
                if let prose = view as? TranscriptAgentMarkdown { parts.append(Self.copiedText(prose.markdown.textView)); return }
                if let title = view as? PiKit.WrappedText { parts.append(title.text); return }
                if let badge = view as? PiKit.Badge { parts.append(badge.text); return }
                if let note = view as? PiKit.Note { parts.append(note.text); return }
                for child in view.subviews where !child.isHidden { visit(child) }
            }
            visit(row)
            return parts.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return TranscriptNativeDocument.textViews(in: row).filter { message.kind != "failure" || $0.accessibilityLabel() != "Title" }
            .map { Self.copiedText($0) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    @MainActor func testUserStatusAndSummaryProjectionEqualsNativeRowsSavedAndLive() throws {
        let sources = ["user", "**literal** [site](https://example.test)", "1. first\n2. second", "# Heading\n\nBody 🌍", "", "left\r\nright"]
        for source in sources {
            for (role, kind) in [("user", ""), ("system", ""), ("system", "notice"), ("system", "compaction"), ("system", "unrecognized")] {
                var fields: [String: WireValue] = ["role": .string(role), "content": .string(source)]
                if !kind.isEmpty { fields["nativeKind"] = .string(kind) }
                let message = TranscriptMessage.project(id: "row", message: fields), shown = rowPayload(message)
                XCTAssertEqual(ConversationContent.transcriptText(["id": .string("row"), "message": .object(fields)]), shown, "Saved \(role)/\(kind): \(source)")
                XCTAssertEqual(ConversationContent.transcriptText(message), shown, "Live \(role)/\(kind): \(source)")
            }
        }
        for content: WireValue in [.array([.object(["type": .string("image")])]),
                                   .array([.object(["type": .string("image")]), .object(["type": .string("image")])]),
                                   .array([.object(["type": .string("text"), "text": .string("first ")]), .object(["type": .string("text"), "text": .string("second")])])] {
            let fields: [String: WireValue] = ["role": .string("user"), "content": content]
            let message = TranscriptMessage.project(id: "row", message: fields)
            XCTAssertEqual(ConversationContent.transcriptText(["message": .object(fields)]), rowPayload(message))
            XCTAssertEqual(ConversationContent.transcriptText(message), rowPayload(message))
        }
        let fields: [String: WireValue] = ["role": .string("user"), "content": .string("hidden envelope"), "nativeDisplayText": .string("Visible **literal** request")]
        XCTAssertEqual(ConversationContent.transcriptText(["message": .object(fields)]), rowPayload(.project(id: "row", message: fields)))
    }
    @MainActor func testSavedCompactionFindUsesTheNativeSummaryAndOpensIt() async throws {
        let entry: WireValue = .object(["type": .string("compaction"), "id": .string("reply"), "parentId": .null,
                                      "summary": .string("Keep **alpha** beta."), "tokensBefore": .number(120)])
        let (model, pane, window) = try await findFixture(saved: true, entries: [entry])
        let message = try XCTUnwrap(model.selected?.messages.first)
        XCTAssertEqual(ConversationContent.transcriptText(try XCTUnwrap(entry.object)), rowPayload(message))
        try await assertFind("alpha beta", in: pane, window: window)
    }
    @MainActor func testAgentDeliveryProjectionEqualsNativeCardsSavedAndLive() throws {
        let source = "1. **alpha** beta\n2. [site](https://example.test)"
        for (author, kind) in [("parent", "task"), ("parent", "follow_up"), ("parent", "steer"), ("subagent", "result"),
                               ("subagent", "note"), ("subagent", "question"), ("subagent", "blocker")] {
            let delivery: WireValue = .object(["author": .string(author), "childId": .string("child"), "turn": .number(1),
                "events": .array([.object(["kind": .string(kind), "text": .string(source), "task": .string("Fixture task")])])])
            let fields: [String: WireValue] = ["role": .string("user"), "content": .string("hidden transport envelope"), "nativeAgentDelivery": delivery]
            let message = TranscriptMessage.project(id: "delivery", message: fields), shown = rowPayload(message)
            XCTAssertEqual(ConversationContent.transcriptText(["message": .object(fields)]), shown, "Saved \(author)/\(kind)")
            XCTAssertEqual(ConversationContent.transcriptText(message), shown, "Live \(author)/\(kind)")
        }
        let child = SessionDisplay(id: "child"); child.isManagedSubagent = true; child.delegatedTask = source
        let task = try XCTUnwrap(child.presentedMessages.first)
        XCTAssertEqual(ConversationContent.transcriptText(task), rowPayload(task), "Unsaved delegated task")
    }
    @MainActor func testSidePaneProjectionEqualsItsSavedAndLiveUserRows() async throws {
        let (model, _, window) = try await findFixture(saved: true, entries: twoUsers)
        let session = try XCTUnwrap(model.selected)
        let info = SideRecord(id: session.id, parentID: "fixture-parent", workspaceID: "project", profileID: "profile", title: "Side", kept: true)
        let side = SidePaneView(model: model, session: session, info: info, paneWidth: 620)
        window.contentView = side
        defer { side.pane.transcript.closeFind(focusing: false) }
        for saved in [true, false] {
            if !saved { session.messages = [.init(id: "live-user", role: "user", text: "**literal** [site](https://example.test)")] }
            side.pane.transcript.refresh(); side.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            for message in session.presentedMessages {
                let row = try XCTUnwrap(side.pane.transcript.document.row(drawing: message.id))
                row.prepareToDraw(); row.layoutForViewport()
                let shown = TranscriptNativeDocument.textViews(in: row).filter(\.isSelectable).map { Self.copiedText($0) }.joined(separator: "\n")
                XCTAssertEqual(ConversationContent.transcriptText(message), shown, "Side \(message.id)")
                if saved {
                    let entry = try XCTUnwrap(twoUsers.first { $0.object?["id"]?.string == message.id }?.object)
                    XCTAssertEqual(ConversationContent.transcriptText(entry), shown, "Saved side \(message.id)")
                }
            }
        }
    }
    @MainActor func testSavedManagedRowsKeepTheirDisplayedAgentAndUserText() async throws {
        let entries: [WireValue] = [
            .object(["type": .string("message"), "id": .string("question"), "parentId": .null,
                "message": .object(["role": .string("user"), "content": .string("**alpha** beta")])]),
            .object(["type": .string("message"), "id": .string("reply"), "parentId": .string("question"),
                "message": .object(["role": .string("user"), "content": .string("**literal** user")])])]
        let (model, pane, window) = try await findFixture(saved: true, entries: entries)
        let session = try XCTUnwrap(model.selected), path = try XCTUnwrap(model.chats.first?.path)
        session.isManagedSubagent = true; session.subagentNumbers = [session.id: 3]
        pane.refresh(); pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let task = try XCTUnwrap(session.presentedMessages.first)
        XCTAssertEqual(ConversationContent.transcriptText(task), rowPayload(task))
        for (query, id) in [("Parent → Sub-agent 3", "question"), ("alpha beta", "question"), ("**literal** user", "reply")] {
            let found = try await model.history.searchContent(path: path, query: query, start: 0, renderedAgentProse: true,
                                                            managedChild: true, presented: session.presentedMessages)
            XCTAssertEqual(found.hits.map(\.id), [id], "Presented managed row: \(query)")
        }
        for (query, id) in [("alpha beta", "question"), ("**literal** user", "reply")] {
            let cold = try await model.history.searchContent(path: path, query: query, start: 0, renderedAgentProse: true, managedChild: true)
            XCTAssertEqual(cold.hits.map(\.id), [id], "Unloaded managed row: \(query)")
        }
    }
    @MainActor func testAgentDeliveryNotesAndUnavailableAttributionMatchTheCard() {
        for metadata: WireValue? in [nil, .object([:]), .object(["author": .string("subagent"), "childId": .string("child"), "turn": .number(2),
            "events": .array([.object(["kind": .string("result"), "text": .string("**visible** result"),
                "result": .object(["text_truncated": .bool(true), "error": .object(["message": .string("Fixture error")])])])])])] {
            var fields: [String: WireValue] = ["role": .string("user"), "content": .string("hidden delivery transport"), "nativeKind": .string("agent_message")]
            fields["nativeAgentDelivery"] = metadata
            let message = TranscriptMessage.project(id: "agent", message: fields), shown = rowPayload(message)
            XCTAssertEqual(ConversationContent.transcriptText(["message": .object(fields)]), shown)
            XCTAssertEqual(ConversationContent.transcriptText(message), shown)
        }
    }
    @MainActor func testRemainingRowKindsProjectTheirNativeContent() throws {
        for kind in ["failure", "branch", "versionBanner", "requestInfo", "execution", "toolResult"] {
            var fields: [String: WireValue] = ["role": .string(kind == "toolResult" ? "toolResult" : "system"),
                "nativeKind": .string(kind), "content": .string("Literal body"), "nativeDetail": .string("Visible detail")]
            if kind == "requestInfo" { fields["nativeStopReason"] = .string("length") }
            if kind == "execution" {
                var timeline = ResponseTimeline()
                timeline.consume(.init(attemptID: "fixture", ordinal: 0, itemID: "part", kind: "text", update: "replace", text: "**alpha** beta"))
                timeline.finish("completed")
                fields["nativeResponseTimeline"] = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(timeline))
            }
            let message = TranscriptMessage.project(id: "row", message: fields), shown = rowPayload(message)
            XCTAssertEqual(ConversationContent.transcriptText(["message": .object(fields)]), shown, "Saved \(kind)")
            XCTAssertEqual(ConversationContent.transcriptText(message), shown, "Live \(kind)")
        }
    }
    @MainActor func testBranchSearchUsesItsDisplayedDetailWithoutAnExportHeading() async throws {
        let entries: [WireValue] = [twoUsers[0], .object(["type": .string("branch"), "id": .string("reply"),
            "parentId": .string("question"), "fromMessageId": .string("question"), "keptIds": .array([.string("question")])])]
        let (model, _, _) = try await findFixture(saved: true, entries: entries)
        let message = try XCTUnwrap(model.selected?.messages.first { $0.kind == "branch" }), path = try XCTUnwrap(model.chats.first?.path)
        let shown = rowPayload(message)
        let rendered = try await model.history.searchContent(path: path, query: "", start: 0, renderedAgentProse: true)
        XCTAssertEqual(rendered.hits.first { $0.id == message.id }?.preview, shown)
        let source = try await model.history.searchContent(path: path, query: "## Edit", start: 0)
        XCTAssertEqual(source.hits.map(\.id), [message.id], "Source export retains its heading")
    }
    @MainActor func testExecutionFindUsesAndOpensItsRenderedTimeline() async throws {
        var timeline = ResponseTimeline()
        timeline.consume(.init(attemptID: "fixture", ordinal: 0, itemID: "part", kind: "text", update: "replace", text: "**alpha** beta"))
        timeline.finish("completed")
        let entry: WireValue = .object(["type": .string("message"), "id": .string("reply"), "parentId": .null,
            "message": .object(["role": .string("system"), "nativeKind": .string("execution"), "content": .string("Hidden canonical text"),
                "nativeDetail": .string("Recorded execution"), "nativeResponseTimeline": try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(timeline))])])
        let (_, pane, window) = try await findFixture(saved: true, entries: [entry])
        try await assertFind("alpha beta", in: pane, window: window)
    }
    @MainActor func testExecutionCaptionsStaySearchableWithAndWithoutTimelineBodies() throws {
        for hasBody in [false, true] { for caption: String? in [nil, "Recorded execution"] {
            var fields: [String: WireValue] = ["role": .string("system"), "nativeKind": .string("execution"), "content": .string("Fallback caption")]
            fields["nativeDetail"] = caption.map(WireValue.string)
            if hasBody {
                var timeline = ResponseTimeline()
                timeline.consume(.init(attemptID: "fixture", ordinal: 0, itemID: "part", kind: "text", update: "replace", text: "Body **alpha** beta"))
                timeline.finish("completed")
                fields["nativeResponseTimeline"] = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(timeline))
            }
            let message = TranscriptMessage.project(id: "execution", message: fields), shown = rowPayload(message)
            XCTAssertEqual(ConversationContent.transcriptText(message), shown, "Live body=\(hasBody), caption=\(caption ?? "fallback")")
            XCTAssertEqual(ConversationContent.transcriptText(["message": .object(fields)]), shown, "Saved body=\(hasBody), caption=\(caption ?? "fallback")")
        } }
    }
    @MainActor func testStandaloneToolResultsMatchTheirNativeRowsSavedAndLive() async throws {
        for name in ["custom_fixture", "subagent_start"] { for saved in [true, false] {
            let source = name == "custom_fixture" ? "**alpha** beta" : #"{"text":"**alpha** beta"}"#
            let fields: [String: WireValue] = ["role": .string("toolResult"), "toolName": .string(name), "toolCallId": .string("call"), "content": .string(source)]
            let entry: WireValue = .object(["type": .string("message"), "id": .string("reply"), "parentId": .null, "message": .object(fields)])
            let (model, pane, window) = try await findFixture(saved: true, entries: [entry])
            let session = try XCTUnwrap(model.selected), shown = rowPayload(try XCTUnwrap(session.messages.first))
            if saved {
                let found = try await model.history.searchContent(path: try XCTUnwrap(model.chats.first?.path), query: "", start: 0,
                    renderedAgentProse: true, presented: session.presentedMessages)
                XCTAssertEqual(found.hits.first?.preview, shown, "Saved standalone \(name)")
            } else {
                model.chats[0].path = nil
                let found = try await model.history.searchPresented(session.presentedMessages, query: "", start: 0)
                XCTAssertEqual(found.hits.first?.preview, shown, "Live standalone \(name)")
            }
            try await assertFind("alpha beta", in: pane, window: window)
        } }
    }
    @MainActor func testPairedToolResultsKeepTheirLiteralCardText() async throws {
        let call = toolEntry("custom_fixture", arguments: .object([:]))
        let entries: [WireValue] = [.object(["type": .string("message"), "id": .string("reply"), "parentId": .null, "message": call["message"]!]),
            .object(["type": .string("message"), "id": .string("result"), "parentId": .string("reply"), "message": .object([
                "role": .string("toolResult"), "toolName": .string("custom_fixture"), "toolCallId": .string("call"), "content": .string("**alpha** beta")])])]
        let (model, pane, window) = try await findFixture(saved: true, entries: entries)
        pane.showFind(); pane.find.setQuery("**alpha** beta")
        try await eventually("Paired result is highlighted literally") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return !pane.find.searching && !pane.document.focusPending && pane.document.focusText != nil
        }
        XCTAssertEqual(pane.find.matches.map(\.messageID), ["result"])
        XCTAssertEqual(pane.document.focusText?.string, "**alpha** beta")
        let session = try XCTUnwrap(model.selected), path = try XCTUnwrap(model.chats.first?.path)
        let hidden = try await model.history.searchContent(path: path, query: "alpha beta", start: 0, renderedAgentProse: true, presented: session.presentedMessages)
        XCTAssertTrue(hidden.hits.isEmpty, "The paired I/O card shows literal Markdown marks")
    }

    private func recoveryLedger(terminal: String? = nil, legacy: Bool = false) throws -> [String: WireValue] {
        var fields: [String: WireValue] = ["role": .string("system"), "nativeKind": .string("requestLedger"),
            "nativePresentationSourceID": .string("missing-reply"), "content": .array([])]
        if legacy {
            fields["content"] = .array([.object(["type": .string("thinking"), "thinking": .string("**alpha** beta")]),
                .object(["type": .string("text"), "text": .string("Visible **gamma** delta")])])
        } else {
            var timeline = ResponseTimeline()
            timeline.consume(.init(attemptID: "recovery", ordinal: 0, itemID: "thought", kind: "reasoningText", update: "replace", text: "**alpha** beta"))
            timeline.consume(.init(attemptID: "recovery", ordinal: 1, itemID: "words", kind: "text", update: "replace", text: "Visible **gamma** delta and [site](https://recovery.test)"))
            if let terminal { timeline.finish(terminal) }
            fields["nativeResponseTimeline"] = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(timeline))
        }
        return fields
    }
    @MainActor private func plannedPayload(_ messages: [TranscriptMessage], raw: Bool = false, omittingOutputs: Set<String> = []) -> [String: String] {
        var payload: [String: [String]] = [:]
        for item in TaskTranscriptPlan.rows(messages, lifecycle: nil) {
            if case .message(let message) = item {
                let text = rowPayload(message)
                if !text.isEmpty { payload[message.id, default: []].append(text) }
                continue
            }
            guard case .block(let block) = item, block.presentation != .response, block.presentation != .summary else { continue }
            if block.part != nil, let message = block.message, let tool = message.tools?.first {
                payload[message.id, default: []].append(Self.cardPayload(tool, inputOnly: omittingOutputs.contains(message.id))); continue
            }
            let disclosure = TranscriptRowDisclosure(work: true,
                openTools: Set(block.replies.flatMap { message in (message.tools ?? []).map { ToolOccurrence.key(message.id, $0.id) } }),
                openReasoning: Set(block.replies.map(\.id)), compaction: true, raw: raw)
            let row = TranscriptRowRenderer.content(for: item, inputs: .init(item: item, fresh: false, actions: .init(), width: 620,
                environment: .init(), disclosure: disclosure))
            row.frame = CGRect(x: 0, y: 0, width: 620, height: 500); row.frame.size.height = row.settle().height; row.layoutSubtreeIfNeeded()
            let shown = TranscriptNativeDocument.textViews(in: row).filter { $0.isSelectable && !$0.isHiddenOrHasHiddenAncestor }
                .map { Self.copiedText($0) }.filter { !$0.isEmpty }.joined(separator: "\n")
            if !shown.isEmpty { payload[block.message?.id ?? block.activity.first?.id ?? block.id, default: []].append(shown) }
        }
        return payload.mapValues { $0.joined(separator: "\n") }
    }
    @MainActor func testOrphanLedgerProjectionEqualsPlannedNativeRowsSavedAndLive() throws {
        for terminal: String? in [nil, "completed", "interrupted"] { for legacy in [false, true] { for raw in [false, true] {
            let fields = try recoveryLedger(terminal: terminal, legacy: legacy), message = TranscriptMessage.project(id: "reply", message: fields)
            let shown = plannedPayload([message], raw: raw)["reply"] ?? ""
            XCTAssertTrue(shown.contains("alpha beta"))
            XCTAssertEqual(ConversationContent.transcriptText(message, rawReply: raw), shown, "Live terminal=\(terminal ?? "missing"), legacy=\(legacy), raw=\(raw)")
            XCTAssertEqual(ConversationContent.transcriptText(["id": .string("reply"), "message": .object(fields)], rawReply: raw), shown,
                "Saved terminal=\(terminal ?? "missing"), legacy=\(legacy), raw=\(raw)")
        } } }
    }
    @MainActor func testFindSearchesOrphanLedgerTextAndReasoningAfterRecovery() async throws {
        for saved in [true, false] {
            let entry: WireValue = .object(["type": .string("message"), "id": .string("reply"), "parentId": .null,
                "message": .object(try recoveryLedger())])
            let (model, pane, window) = try await findFixture(saved: true, entries: [entry])
            if !saved { model.chats[0].path = nil }
            try await assertFind("alpha beta", in: pane, window: window)
            try await assertFind("gamma delta", in: pane, window: window)
            model.selected?.disclosure.setOpen(true, .source("reply")); pane.refresh()
            try await assertFind("recovery.test", in: pane, window: window)
        }
    }
    @MainActor func testRecoverySearchFollowsPlannerSuppressionAndDiscardedRevisions() async throws {
        var fields = try recoveryLedger(terminal: "completed")
        fields["nativePresentationSourceID"] = .string("accepted")
        let accepted: WireValue = .object(["type": .string("message"), "id": .string("accepted"), "parentId": .string("reply"),
            "message": .object(["role": .string("assistant"), "content": .string("Accepted answer")])])
        for superseded in [true, false] {
            var entries: [WireValue] = [.object(["type": .string("message"), "id": .string("reply"), "parentId": .null, "message": .object(fields)])]
            if superseded { entries.append(accepted) }
            else {
                var cleared = ResponseTimeline(); cleared.finish("failed")
                var discarded = fields
                discarded["nativeResponseTimeline"] = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(cleared))
                entries.append(.object(["type": .string("custom"), "customType": .string("pi-app.presentation.update.v1"),
                    "id": .string("discard"), "parentId": .string("reply"), "data": .object(["id": .string("reply")]), "message": .object(discarded)]))
            }
            let (model, _, _) = try await findFixture(saved: true, entries: entries)
            let rows = try XCTUnwrap(model.selected).presentedMessages, shown = plannedPayload(rows)
            XCTAssertFalse(shown.values.contains { $0.contains("alpha beta") })
            let live = try await model.history.searchPresented(rows, query: "alpha beta", start: 0)
            XCTAssertTrue(live.hits.isEmpty)
            for presented in [rows, []] {
                let saved = try await model.history.searchContent(path: try XCTUnwrap(model.chats[0].path), query: "alpha beta", start: 0,
                    renderedAgentProse: true, presented: presented)
                XCTAssertTrue(saved.hits.isEmpty, "superseded=\(superseded), presented=\(!presented.isEmpty)")
            }
        }
    }

    @MainActor func testRecoveryPlannerCorpusMatchesSavedAndLiveSearch() async throws {
        let encoded = try XCTUnwrap(recoveryLedger(terminal: "completed")["nativeResponseTimeline"])
        let execution: [String: WireValue] = ["role": .string("system"), "nativeKind": .string("execution"), "content": .string("Hidden canonical"),
            "nativeReplayEligible": .bool(false), "nativeDetail": .string("Compaction stage"), "nativeOperationID": .string("operation"), "nativeResponseTimeline": encoded]
        var unfinished = execution
        unfinished["nativeResponseTimeline"] = try recoveryLedger()["nativeResponseTimeline"]
        var unsupported = try recoveryLedger(legacy: true), future = try XCTUnwrap(encoded.object)
        future["version"] = .number(999); unsupported["nativeResponseTimeline"] = .object(future)
        let summary: WireValue = .object(["type": .string("compaction"), "id": .string("summary"), "parentId": .string("reply"),
            "summary": .string("Hidden checkpoint **alpha** beta"), "nativeCompactionVersion": .number(2),
            "nativeCompaction": .object(["operationId": .string("operation"), "version": .number(2), "sourceIDs": .array([]), "protectedIDs": .array([]), "keptIDs": .array([])])])
        for (name, fields, checkpoint) in [("unfinished operation", unfinished, false), ("adopted operation", unfinished, true),
                                           ("duplicate checkpoint", execution, true), ("unsupported ledger", unsupported, false)] {
            var entries: [WireValue] = [.object(["type": .string("message"), "id": .string("reply"), "parentId": .null, "message": .object(fields)])]
            if checkpoint { entries.append(summary) }
            let (model, _, _) = try await findFixture(saved: true, entries: entries)
            let rows = try XCTUnwrap(model.selected).presentedMessages, shown = plannedPayload(rows)
            let live = try await model.history.searchPresented(rows, query: "", start: 0)
            for row in rows { XCTAssertEqual(live.hits.first { $0.id == row.id }?.preview, shown[row.id] ?? "", "Live \(name), \(row.id)") }
            for presented in [rows, []] {
                let saved = try await model.history.searchContent(path: try XCTUnwrap(model.chats[0].path), query: "", start: 0,
                    renderedAgentProse: true, presented: presented)
                for row in rows { XCTAssertEqual(saved.hits.first { $0.id == row.id }?.preview, shown[row.id] ?? "", "Saved \(name), \(row.id), presented=\(!presented.isEmpty)") }
            }
        }
    }

    @MainActor func testPlannedPairedToolPayloadsMatchSavedAndLiveSearch() async throws {
        let cases: [(String, WireValue, String)] = [
            ("custom_fixture", .object(["key": .string("value")]), "**alpha** beta"),
            ("bash", .object(["command": .string("printf fixture")]), "**alpha** beta"),
            ("read", .object(["path": .string("fixture.txt")]), "**alpha** beta"),
            ("edit", .object(["path": .string("fixture.txt"), "oldText": .string("old tail"), "newText": .string("new tail")]), "Transport receipt"),
            ("subagent_start", .object(["task": .string("**Task** prose")]), #"{"text":"**alpha** beta"}"#)]
        for (name, arguments, output) in cases { for separated in [false, true] {
            let call = toolEntry(name, arguments: arguments)
            let entries: [WireValue] = [.object(["type": .string("message"), "id": .string("reply"), "parentId": .null, "message": call["message"]!]),
                .object(["type": .string("message"), "id": .string("result"), "parentId": .string("reply"), "message": .object([
                    "role": .string("toolResult"), "toolName": .string(name), "toolCallId": .string("call"), "content": .string(output),
                    "nativeToolStats": .object(["outcome": .string("succeeded")])])])]
            var records = entries
            if separated {
                var parent = "reply"
                for i in 0..<40 {
                    let id = "spacer-\(i)"
                    records.insert(.object(["type": .string("message"), "id": .string(id), "parentId": .string(parent),
                        "message": .object(["role": .string("system"), "nativeKind": .string("notice"), "nativeReplayEligible": .bool(false), "content": .string("Spacer \(i)")])]), at: records.count - 1)
                    parent = id
                }
                records[records.count - 1].object.map { original in
                    var value = original; value["parentId"] = .string(parent); records[records.count - 1] = .object(value)
                }
            }
            let (model, _, _) = try await findFixture(saved: true, entries: records)
            let rows = try XCTUnwrap(model.selected).presentedMessages, payload = plannedPayload(rows)
            let shown = ["reply", "result"].compactMap { payload[$0] }.filter { !$0.isEmpty }.joined(separator: "\n")
            let live = try await model.history.searchPresented(rows, query: "", start: 0)
            XCTAssertEqual(live.hits.filter { ["reply", "result"].contains($0.id) }.map(\.preview).filter { !$0.isEmpty }.joined(separator: "\n"), shown, "Live paired \(name), separated=\(separated)")
            for presented in [rows, []] {
                let saved = try await model.history.searchContent(path: try XCTUnwrap(model.chats[0].path), query: "", start: 0,
                    renderedAgentProse: true, presented: presented)
                XCTAssertEqual(saved.hits.filter { ["reply", "result"].contains($0.id) }.map(\.preview).filter { !$0.isEmpty }.joined(separator: "\n"), shown, "Saved paired \(name), presented=\(!presented.isEmpty), separated=\(separated)")
            }
        } }
    }

    private func pageBoundaryEntries(_ name: String = "custom_fixture", arguments: WireValue = .object(["message": .string("inputneedle sharedneedle")]),
                                     output: String = "**outputneedle** sharedneedle [site](https://receipt.test)") -> [WireValue] {
        let call = toolEntry(name, arguments: arguments)
        return [.object(["type": .string("message"), "id": .string("reply"), "parentId": .null, "message": call["message"]!]),
            .object(["type": .string("message"), "id": .string("result"), "parentId": .string("reply"), "message": .object([
                "role": .string("toolResult"), "toolName": .string(name), "toolCallId": .string("call"), "content": .string(output),
                "nativeToolStats": .object(["outcome": .string("succeeded")])])]),
            .object(["type": .string("message"), "id": .string("answer"), "parentId": .string("result"), "message": .object([
                "role": .string("assistant"), "content": .string("**replyneedle** sharedneedle [reply](https://reply.test)")])])]
    }
    @MainActor private func nativePageSearchText(_ full: [TranscriptMessage], page: [TranscriptMessage], pairs: [(String, String)], raw: Bool = false) -> String {
        var rows = full
        for message in page { if let index = rows.firstIndex(where: { $0.id == message.id }) { rows[index] = message } }
        let complete = plannedPayload(rows, raw: raw), captured = plannedPayload(page, raw: raw)
        // A visible standalone receipt keeps its own native Markdown. Its
        // payload replaces the off-page card output, not the card's input.
        // Pair identities are explicit fixture data, independent of search.
        let omitted = Set(pairs.compactMap { call, receipt in captured[receipt] != nil && complete[receipt] == nil ? call : nil })
        let standalone = page.filter { $0.role == "tool" && complete[$0.id] == nil }.compactMap { captured[$0.id] }
        return (Array(plannedPayload(rows, raw: raw, omittingOutputs: omitted).values) + standalone).joined(separator: "\n")
    }
    @MainActor func testCapturedCallDoesNotDuplicateItsUnloadedReceipt() async throws {
        let (model, pane, window) = try await findFixture(saved: true, entries: pageBoundaryEntries())
        let rows = try XCTUnwrap(model.selected).presentedMessages, call = try XCTUnwrap(rows.first)
        XCTAssertEqual(call.tools?.first?.state, "completed")
        XCTAssertEqual(ConversationContent.occurrences(of: "outputneedle", in: plannedPayload([call])[call.id] ?? ""), 1)
        let found = try await model.history.searchContent(path: try XCTUnwrap(model.chats[0].path), query: "outputneedle", start: 0,
            renderedAgentProse: true, presented: [call])
        XCTAssertEqual(found.hits.map(\.id), ["result"], "The retained receipt owns the card output even outside the captured page")
        XCTAssertEqual(found.hits.reduce(0) { $0 + ($1.count ?? 1) }, 1)
        model.selected?.messages = [call]; pane.refresh()
        try await assertFind("outputneedle", in: pane, window: window, record: "result")
        pane.find.step(1); pane.find.step(-1)
        XCTAssertEqual(pane.find.current, 0); XCTAssertEqual(pane.find.matches.map(\.messageID), ["result"])
    }
    @MainActor func testFindCountsEveryCallReceiptReplyPageSplitSavedAndLive() async throws {
        let output = "**outputneedle** sharedneedle [site](https://receipt.test)"
        let cases: [(String, WireValue, String)] = [
            ("custom_fixture", .object(["message": .string("inputneedle sharedneedle")]), output),
            ("bash", .object(["command": .string("printf 'inputneedle sharedneedle'")]), output),
            ("read", .object(["path": .string("inputneedle-sharedneedle.txt")]), output),
            ("edit", .object(["path": .string("fixture.txt"), "oldText": .string("old inputneedle sharedneedle"), "newText": .string("new editneedle")]), "transportneedle"),
            ("subagent_start", .object(["task": .string("inputneedle sharedneedle")]), #"{"text":"**outputneedle** sharedneedle [site](https://receipt.test)"}"#)]
        let queries = ["inputneedle", "outputneedle", "replyneedle", "sharedneedle", "**outputneedle**", "receipt.test", "transportneedle", "reply.test", "outputneedle sharedneedle"]
        for (name, arguments, output) in cases {
            let (model, _, _) = try await findFixture(saved: true, entries: pageBoundaryEntries(name, arguments: arguments, output: output))
            let saved = try XCTUnwrap(model.selected).presentedMessages, path = try XCTUnwrap(model.chats[0].path)
            XCTAssertEqual(saved.map(\.id), ["reply", "result", "answer"])
            for live in [false, true] { for raw in [false, true] {
                var rows = saved
                if live {
                    rows[2].state = "streaming"
                    rows = try TranscriptMessage.page(JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(rows)))
                }
                // Every contiguous page: both edges can fall before, between
                // or after the call, receipt and following reply, including an
                // empty overlay, the receipt alone and the complete group.
                for lower in 0...rows.count { for upper in lower...rows.count {
                    let page = Array(rows[lower..<upper])
                    let shown = nativePageSearchText(saved, page: page, pairs: [("reply", "result")], raw: raw)
                    for query in queries {
                        let found = try await model.history.searchContent(path: path, query: query, start: 0,
                            renderedAgentProse: true, presented: page, rawReplies: raw ? ["reply", "answer"] : [])
                        let expected = ConversationContent.occurrences(of: query, in: shown)
                        XCTAssertEqual(found.hits.reduce(0) { $0 + ($1.count ?? 1) }, expected,
                            "\(name), live=\(live), raw=\(raw), page=\(lower)..<\(upper), query=\(query)")
                    }
                } }
            } }
        }
    }

    @MainActor func testFindRevealsCapturedOutputWithoutLoadingItsReceipt() async throws {
        let (model, pane, window) = try await findFixture(saved: true, entries: pageBoundaryEntries())
        let call = try XCTUnwrap(model.selected?.presentedMessages.first)
        model.selected?.messages = [call]; pane.refresh()
        var reads: [String] = []
        pane.find.reveal = { _, id in reads.append(id); return false }
        pane.showFind(); pane.find.setQuery("receipt.test")
        try await eventually("Captured output search finishes") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching }
        XCTAssertEqual(pane.find.matches.map(\.messageID), ["result"])
        XCTAssertEqual(pane.document.highlights.focus?.messageID, "reply", "The loaded card draws the receipt's output")
        XCTAssertEqual(pane.document.highlights.focus?.scopeCall, "call")
        XCTAssertTrue(reads.isEmpty, "The output is already loaded; revealing its receipt can replace literal card text with standalone Markdown")
        guard pane.document.highlights.focus?.messageID == "reply" else { return }
        try await assertFind("receipt.test", in: pane, window: window, record: "result")
    }

    @MainActor func testFindKeepsCallInputAndReceiptOutputSeparateWhenReconciling() async throws {
        let (model, pane, window) = try await findFixture(saved: true, entries: pageBoundaryEntries())
        let rows = try XCTUnwrap(model.selected).presentedMessages
        for page in [[rows[0]], rows] {
            pane.closeFind(focusing: false); model.selected?.messages = page; pane.refresh()
            pane.showFind(); pane.find.setQuery("sharedneedle")
            try await eventually("Shared input/output search finishes") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching }
            if pane.find.current != 0 { pane.find.step(-(pane.find.current ?? 0)) }
            try await eventually("Shared input/output focus resolves") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.document.focusPending && pane.document.focusText != nil }
            XCTAssertEqual(pane.find.matches.map(\.messageID), ["reply", "result", "answer"], "Reconciling the call must not count its receipt-owned output again")
            XCTAssertTrue(pane.document.focusText?.string.contains("inputneedle") == true)
            pane.find.step(1)
            try await eventually("The receipt occurrence resolves") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.document.focusPending && pane.document.focusText != nil }
            XCTAssertEqual(pane.document.highlights.focus?.record, "result")
            XCTAssertTrue(pane.document.focusText?.string.contains("outputneedle") == true)
        }
    }

    @MainActor func testCompletedWireCardOwnsOneOutputAcrossThePageByteLimit() async throws {
        let output = String(repeating: "padding ", count: 24_000) + "outputneedle"
        let entries = pageBoundaryEntries(output: output)
        let (model, _, _) = try await findFixture(saved: true, entries: entries)
        var call = TranscriptMessage.project(id: "reply", message: try XCTUnwrap(entries[0].object?["message"]?.object))
        call.tools?[0].state = "completed"; call.tools?[0].output = output
        let result = TranscriptMessage.project(id: "result", message: try XCTUnwrap(entries[1].object?["message"]?.object))
        let bytes = try JSONEncoder().encode([call])
        XCTAssertLessThan(bytes.count + HistoryWindowPolicy.metadataAllowance, HistoryWindowPolicy.envelopeBytes)
        XCTAssertGreaterThan(try JSONEncoder().encode([call, result]).count, HistoryWindowPolicy.envelopeBytes)
        let captured = try TranscriptMessage.page(JSONDecoder().decode(WireValue.self, from: bytes))
        let found = try await model.history.searchContent(path: try XCTUnwrap(model.chats[0].path), query: "outputneedle", start: 0,
            renderedAgentProse: true, presented: captured)
        XCTAssertEqual(found.hits.map(\.id), ["result"])
        XCTAssertEqual(found.hits.reduce(0) { $0 + ($1.count ?? 1) }, 1)
    }
    @MainActor func testEveryPageSplitKeepsReusedCallsAndLatestReceiptsSeparate() async throws {
        var entries: [WireValue] = [], parent: String?
        for prefix in ["first", "second"] {
            for (index, item) in pageBoundaryEntries(output: "**\(prefix)output** sharedneedle").enumerated() {
                if prefix == "first", index == 1 {
                    var stale = try XCTUnwrap(item.object), fields = try XCTUnwrap(stale["message"]?.object)
                    stale["id"] = .string("stale-result"); stale["parentId"] = parent.map(WireValue.string) ?? .null
                    fields["content"] = .string("staleoutput"); stale["message"] = .object(fields)
                    entries.append(.object(stale)); parent = "stale-result"
                }
                var value = try XCTUnwrap(item.object)
                let id = prefix + "-" + (try XCTUnwrap(value["id"]?.string))
                value["id"] = .string(id); value["parentId"] = parent.map(WireValue.string) ?? .null
                entries.append(.object(value)); parent = id
            }
        }
        let (model, _, _) = try await findFixture(saved: true, entries: entries)
        let rows = try XCTUnwrap(model.selected).presentedMessages, path = try XCTUnwrap(model.chats[0].path)
        XCTAssertEqual(rows.count, 7); XCTAssertFalse(plannedPayload(rows).values.contains { $0.contains("staleoutput") })
        for lower in 0...rows.count { for upper in lower...rows.count {
            let shown = nativePageSearchText(rows, page: Array(rows[lower..<upper]), pairs: [("first-reply", "first-result"), ("second-reply", "second-result")])
            for query in ["firstoutput", "secondoutput", "staleoutput", "sharedneedle", "**firstoutput**"] {
                let cost = SearchDecodeCost(); await model.history.observeSearchDecodes { cost.observe($0) }
                let found = try await model.history.searchContent(path: path, query: query, start: 0,
                    renderedAgentProse: true, presented: Array(rows[lower..<upper]))
                assertBoundedSearch(cost, sourceBytes: try Data(contentsOf: URL(fileURLWithPath: path)).count, name: "all-splits \(lower)..<\(upper) \(query)")
                XCTAssertEqual(found.hits.reduce(0) { $0 + ($1.count ?? 1) }, ConversationContent.occurrences(of: query, in: shown),
                    "page=\(lower)..<\(upper), query=\(query)")
                if query == "firstoutput" || query == "secondoutput" {
                    XCTAssertEqual(found.hits.map(\.id), [query == "firstoutput" ? "first-result" : "second-result"])
                }
            }
        } }
    }
    @MainActor func testEveryLegacyPageSplitKeepsBothDisplayedOutputRows() async throws {
        var entries = pageBoundaryEntries()
        var value = try XCTUnwrap(entries[0].object), fields = try XCTUnwrap(value["message"]?.object)
        var future = try XCTUnwrap(JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(ResponseTimeline())).object)
        future["version"] = .number(999); fields["nativeResponseTimeline"] = .object(future)
        value["message"] = .object(fields); entries[0] = .object(value)
        let (model, _, _) = try await findFixture(saved: true, entries: entries)
        let rows = try XCTUnwrap(model.selected).presentedMessages, path = try XCTUnwrap(model.chats[0].path)
        let shown = plannedPayload(rows).values.joined(separator: "\n")
        XCTAssertEqual(ConversationContent.occurrences(of: "outputneedle", in: shown), 2)
        for lower in 0...rows.count { for upper in lower...rows.count {
            for query in ["outputneedle", "**outputneedle**", "receipt.test", "sharedneedle"] {
                let found = try await model.history.searchContent(path: path, query: query, start: 0,
                    renderedAgentProse: true, presented: Array(rows[lower..<upper]))
                XCTAssertEqual(found.hits.reduce(0) { $0 + ($1.count ?? 1) }, ConversationContent.occurrences(of: query, in: shown),
                    "page=\(lower)..<\(upper), query=\(query)")
            }
        } }
    }
    @MainActor func testCapturedStandaloneReceiptKeepsItsRenderedText() async throws {
        let entries = pageBoundaryEntries(output: "**alpha** beta and [site](https://receipt.test)")
        let (model, _, _) = try await findFixture(saved: true, entries: entries)
        let rows = try XCTUnwrap(model.selected).presentedMessages, receipt = rows[1]
        let recorded = TranscriptMessage.project(id: "reply", message: try XCTUnwrap(entries[0].object?["message"]?.object))
        var carrying = recorded; carrying.tools?[0].output = "capturedliteral"
        for page in [[receipt], [recorded, receipt], [carrying, receipt]] {
            let shown = plannedPayload(page).values.joined(separator: "\n")
            XCTAssertTrue(shown.contains("alpha beta and site"))
            for query in ["alpha beta", "receipt.test", "**alpha** beta", "capturedliteral"] {
                let found = try await model.history.searchContent(path: try XCTUnwrap(model.chats[0].path), query: query, start: 0,
                    renderedAgentProse: true, presented: page)
                XCTAssertEqual(found.hits.reduce(0) { $0 + ($1.count ?? 1) }, ConversationContent.occurrences(of: query, in: shown),
                    "page=\(page.map(\.id)), query=\(query)")
            }
        }
    }
    @MainActor func testCapturedCardKeepsItsDisplayedOutputWhenReceiptIsUnloaded() async throws {
        let (model, _, _) = try await findFixture(saved: true, entries: pageBoundaryEntries(output: "retainedoutput"))
        var call = try XCTUnwrap(model.selected?.presentedMessages.first)
        call.tools?[0].output = "displayedoutput"
        XCTAssertTrue(plannedPayload([call])[call.id]?.contains("displayedoutput") == true)
        for query in ["retainedoutput", "displayedoutput"] {
            let found = try await model.history.searchContent(path: try XCTUnwrap(model.chats[0].path), query: query, start: 0,
                renderedAgentProse: true, presented: [call])
            XCTAssertEqual(found.hits.map(\.id), query == "displayedoutput" ? ["result"] : [])
            XCTAssertEqual(found.hits.reduce(0) { $0 + ($1.count ?? 1) }, query == "displayedoutput" ? 1 : 0)
        }
    }
    @MainActor func testCapturedOutputWithoutARetainedReceiptStaysOnItsCall() async throws {
        let entries = pageBoundaryEntries()
        let (model, _, _) = try await findFixture(saved: true, entries: [entries[0]])
        var call = try XCTUnwrap(model.selected?.presentedMessages.first)
        call.tools?[0].state = "completed"; call.tools?[0].output = "outputneedle"
        let path = try XCTUnwrap(model.chats[0].path)
        let saved = try await model.history.searchContent(path: path, query: "outputneedle", start: 0, renderedAgentProse: true, presented: [call])
        let live = try await model.history.searchPresented([call], query: "outputneedle", start: 0)
        XCTAssertEqual(saved.hits.map(\.id), ["reply"]); XCTAssertEqual(live.hits.map(\.id), ["reply"])
        XCTAssertEqual(saved.hits.first?.count, 1); XCTAssertEqual(live.hits.first?.count, 1)
    }

    @MainActor func testColdPlannerContextCrossesDecodeRuns() async throws {
        for tool in [false, true] {
            var fields = tool ? try XCTUnwrap(toolEntry("custom_fixture", arguments: .object(["key": .string("value")]))["message"]?.object) : try recoveryLedger(terminal: "completed")
            if !tool { fields["nativePresentationSourceID"] = .string("result") }
            var entries: [WireValue] = [.object(["type": .string("message"), "id": .string("reply"), "parentId": .null, "message": .object(fields)])]
            var parent = "reply"
            for i in 0..<40 {
                let id = "spacer-\(i)"
                entries.append(.object(["type": .string("message"), "id": .string(id), "parentId": .string(parent),
                    "message": .object(["role": .string("system"), "nativeKind": .string("notice"), "nativeReplayEligible": .bool(false), "content": .string("Spacer \(i)")])]))
                parent = id
            }
            let result: [String: WireValue] = tool
                ? ["role": .string("toolResult"), "toolName": .string("custom_fixture"), "toolCallId": .string("call"), "content": .string("**alpha** beta"), "nativeToolStats": .object(["outcome": .string("succeeded")])]
                : ["role": .string("assistant"), "content": .string("Accepted answer")]
            entries.append(.object(["type": .string("message"), "id": .string("result"), "parentId": .string(parent), "message": .object(result)]))
            let (model, _, _) = try await findFixture(saved: true, entries: entries)
            let rows = try XCTUnwrap(model.selected).presentedMessages
            XCTAssertEqual(rows.count, 42)
            let query = tool ? "**alpha** beta" : "alpha beta"
            for presented in [rows, []] {
                let found = try await model.history.searchContent(path: try XCTUnwrap(model.chats[0].path), query: query, start: 0,
                    renderedAgentProse: true, presented: presented)
                XCTAssertEqual(found.hits.map(\.id), tool ? ["result"] : [], "tool=\(tool), presented=\(!presented.isEmpty)")
            }
        }
    }

    func testPlannerDependencyIndexKeepsReusedCallsAndActiveBranchesSeparate() throws {
        let index = try HistoryOffsetIndex()
        let records: [HistoryOffset] = [
            .init(id: "first", parent: nil, offset: 0, length: 1, type: "message", role: "assistant", calls: ["call"]),
            .init(id: "old-result", parent: "first", offset: 1, length: 1, type: "message", role: "toolResult", resultCall: "call"),
            .init(id: "second", parent: "old-result", offset: 2, length: 1, type: "message", role: "assistant", calls: ["call"]),
            .init(id: "new-result", parent: "second", offset: 3, length: 1, type: "message", role: "toolResult", resultCall: "call"),
            .init(id: "operation", parent: "new-result", offset: 4, length: 1, type: "message", role: "system", operationID: "compact"),
            .init(id: "summary", parent: "operation", offset: 5, length: 1, type: "compaction")]
        for record in records { try index.insert(record); try index.append(record) }
        func peers(_ id: String, calls: [String] = [], result: String? = nil, operation: String? = nil) throws -> Set<String> {
            Set(try index.related(to: id, calls: calls, result: result, operation: operation).map(\.id))
        }
        XCTAssertEqual(try peers("first", calls: ["call"]), ["old-result"])
        XCTAssertEqual(try peers("second", calls: ["call"]), ["new-result"])
        XCTAssertEqual(try peers("old-result", result: "call"), ["first"])
        XCTAssertEqual(try peers("new-result", result: "call"), ["second"])
        XCTAssertEqual(try peers("summary", operation: "compact"), ["operation"])
        try index.branch(from: "second", kept: ["first", "old-result"])
        XCTAssertEqual(try peers("first", calls: ["call"]), ["old-result"], "Abandoned call/result links stay outside the active plan")
        XCTAssertTrue(try peers("old-result", operation: "compact").isEmpty)
    }
    @MainActor func testSearchKeepsCapturedOrphanPresentationWhenFinalReplyIsAppended() async throws {
        var fields = try recoveryLedger(terminal: "completed"); fields["nativePresentationSourceID"] = .string("accepted")
        let entry: WireValue = .object(["type": .string("message"), "id": .string("reply"), "parentId": .null, "message": .object(fields)])
        let (model, _, _) = try await findFixture(saved: true, entries: [entry])
        let rows = try XCTUnwrap(model.selected).presentedMessages, path = try XCTUnwrap(model.chats[0].path)
        let accepted: WireValue = .object(["type": .string("message"), "id": .string("accepted"), "parentId": .string("reply"),
            "message": .object(["role": .string("assistant"), "content": .string("Accepted answer")])])
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: JSONEncoder().encode(accepted)); try file.write(contentsOf: Data([10]))
        let captured = try await model.history.searchContent(path: path, query: "alpha beta", start: 0, renderedAgentProse: true, presented: rows)
        XCTAssertEqual(captured.hits.map(\.id), ["reply"], "The current pane still draws the orphan; a later journal append does not override that snapshot")
        let reopened = try await model.history.read(path: path, whole: true)
        let refreshed = try await model.history.searchContent(path: path, query: "alpha beta", start: 0, renderedAgentProse: true, presented: reopened.messages)
        XCTAssertTrue(refreshed.hits.isEmpty, "The refreshed planner hides the superseded ledger")
    }

    func testPlannerDependencyIndexKeepsLiteralCallIDs() throws {
        let index = try HistoryOffsetIndex()
        let first = "call\u{0}first", second = "call\u{0}second"
        let records: [HistoryOffset] = [
            .init(id: "first", parent: nil, offset: 0, length: 1, type: "message", role: "assistant", calls: [first]),
            .init(id: "second", parent: "first", offset: 1, length: 1, type: "message", role: "assistant", calls: [second]),
            .init(id: "first-result", parent: "second", offset: 2, length: 1, type: "message", role: "toolResult", resultCall: first),
            .init(id: "second-result", parent: "first-result", offset: 3, length: 1, type: "message", role: "toolResult", resultCall: second)]
        for record in records { try index.insert(record); try index.append(record) }
        let peers = try index.related(to: "first-result", calls: [], result: first, operation: nil)
        XCTAssertEqual(Set(peers.map(\.id)), ["first"], "The complete provider call ID selects its own issuer")
    }

    @MainActor func testUnsupportedToolTimelineKeepsBothNativeRecoveryRowsAcrossRuns() async throws {
        var fields = try XCTUnwrap(toolEntry("custom_fixture", arguments: .object(["key": .string("value")]))["message"]?.object)
        fields["nativeResponseTimeline"] = .object(["version": .number(999), "segments": .array([]), "omittedEvents": .number(0), "coverage": .string("observed")])
        var entries: [WireValue] = [.object(["type": .string("message"), "id": .string("reply"), "parentId": .null, "message": .object(fields)])]
        var parent = "reply"
        for i in 0..<40 {
            let id = "spacer-\(i)"
            entries.append(.object(["type": .string("message"), "id": .string(id), "parentId": .string(parent),
                "message": .object(["role": .string("system"), "nativeKind": .string("notice"), "content": .string("Spacer \(i)")])]))
            parent = id
        }
        entries.append(.object(["type": .string("message"), "id": .string("result"), "parentId": .string(parent), "message": .object([
            "role": .string("toolResult"), "toolName": .string("custom_fixture"), "toolCallId": .string("call"), "content": .string("**alpha** beta"),
            "nativeToolStats": .object(["outcome": .string("succeeded")])])]))
        let (model, _, _) = try await findFixture(saved: true, entries: entries)
        let rows = try XCTUnwrap(model.selected).presentedMessages, shown = plannedPayload(rows)
        XCTAssertTrue(shown["reply"]?.contains("**alpha** beta") == true)
        XCTAssertEqual(shown["result"], "alpha beta")
        let live = try await model.history.searchPresented(rows, query: "", start: 0)
        for id in ["reply", "result"] { XCTAssertEqual(live.hits.first { $0.id == id }?.preview, shown[id], "Live legacy \(id)") }
        for presented in [rows, []] {
            let saved = try await model.history.searchContent(path: try XCTUnwrap(model.chats[0].path), query: "", start: 0, renderedAgentProse: true, presented: presented)
            for id in ["reply", "result"] { XCTAssertEqual(saved.hits.first { $0.id == id }?.preview, shown[id], "Saved legacy \(id), presented=\(!presented.isEmpty)") }
        }
    }

    @MainActor func testColdCompactionContextUsesBothRetainedOperationIdentityForms() async throws {
        for nested in [false, true] {
            let identity: WireValue = .object(["operationId": .string("operation"), "version": .number(2), "sourceIDs": .array([]), "protectedIDs": .array([]), "keptIDs": .array([])])
            var timeline = ResponseTimeline(); timeline.finish("completed")
            var operation: [String: WireValue] = ["role": .string("system"), "nativeKind": .string("execution"), "nativeReplayEligible": .bool(false),
                "nativeDetail": .string("Recorded operation"), "content": .string(""), "nativeResponseTimeline": try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(timeline))]
            if nested { operation["nativeCompaction"] = identity } else { operation["nativeOperationID"] = .string("operation") }
            var entries: [WireValue] = [.object(["type": .string("message"), "id": .string("reply"), "parentId": .null, "message": .object(operation)])]
            var parent = "reply"
            for i in 0..<40 {
                let id = "spacer-\(i)"
                entries.append(.object(["type": .string("message"), "id": .string(id), "parentId": .string(parent), "message": .object([
                    "role": .string("system"), "nativeKind": .string("notice"), "nativeReplayEligible": .bool(false), "content": .string("Spacer \(i)")])]))
                parent = id
            }
            entries.append(.object(["type": .string("compaction"), "id": .string("summary"), "parentId": .string(parent),
                "summary": .string("Hidden **checkpoint** token"), "nativeCompactionVersion": .number(2), "nativeCompaction": identity]))
            let (model, _, _) = try await findFixture(saved: true, entries: entries)
            let rows = try XCTUnwrap(model.selected).presentedMessages
            XCTAssertNil(plannedPayload(rows)["summary"])
            for presented in [rows, []] {
                let found = try await model.history.searchContent(path: try XCTUnwrap(model.chats[0].path), query: "checkpoint token", start: 0, renderedAgentProse: true, presented: presented)
                XCTAssertTrue(found.hits.isEmpty, "nested=\(nested), presented=\(!presented.isEmpty)")
            }
        }
    }

    @MainActor private static func cardPayload(_ tool: ToolView, fetched: ToolInputDocument? = nil, linked: Bool? = nil, rendered: TranscriptNativeCard? = nil, inputOnly: Bool = false, includeWorkSummary: Bool = true) -> String {
        let model = TranscriptToolRow.model(of: tool)
        let value = TranscriptToolRow.card(of: tool, fetched: fetched, model: model, linked: linked ?? (model.file != nil))
        let card = rendered ?? TranscriptNativeCard.make(value)
        if rendered == nil { card.update(value, link: nil, environment: .init()) }
        card.frame = CGRect(x: 0, y: 0, width: 620, height: card.height(width: 620))
        card.layoutSubtreeIfNeeded()
        var payload = TranscriptNativeDocument.textUnits(in: card).compactMap { view -> String? in
            if inputOnly, !(card is TranscriptNativeDiffCard), !TranscriptNativeDocument.isToolInput(view) { return nil }
            if let lines = view as? TranscriptCardLines { return lines.lines.map(\.text).joined(separator: "\n") }
            guard let text = view as? NSTextView, text.isSelectable else { return nil }
            return Self.copiedText(text)
        }.filter { !$0.isEmpty }.joined(separator: "\n")
        if case .diff(_, _, .failed, _, _) = value, !tool.output.isEmpty, !inputOnly, includeWorkSummary {
            let row = TranscriptNativeActionRow(frame: .zero)
            row.update(tool: tool, open: false, fetched: fetched, environment: .init(), toggle: {}, openFile: nil)
            payload = [payload, row.line.content.summary].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        // File paths and the agent's row identity are searchable labels outside
        // the selectable payload; retain them while comparing the actual body.
        switch value {
        case .subagent:
            let line = (card.superview as? TranscriptNativeActionRow)?.line.content
            let heading = line.map { [$0.title, $0.summary].filter { !$0.isEmpty }.joined(separator: " · ") } ?? SubagentToolView(tool).title
            return [heading, payload].filter { !$0.isEmpty }.joined(separator: "\n")
        case .diff(_, let path?, _, _, _), .read(_, _, let path?, _), .io(let path?, _, _, _, _):
            let label = ConversationPaneTests.views(TranscriptLabel.self, in: card).first { !$0.isHiddenOrHasHiddenAncestor && $0.text == path }
            XCTAssertNotNil(label)
            return [label?.text ?? "", payload].filter { !$0.isEmpty }.joined(separator: "\n")
        default: return payload
        }
    }
    private func toolEntry(_ name: String, arguments: WireValue) -> [String: WireValue] {
        ["id": .string("reply"), "message": .object(["role": .string("assistant"), "content": .array([
            .object(["type": .string("toolCall"), "id": .string("call"), "name": .string(name), "arguments": arguments])])])]
    }
    @MainActor func testManagedAttributedEntryKeepsItsNativeAgentCard() {
        for metadata in [WireValue.object(["author": .string("parent"), "childId": .string("child"), "turn": .number(1), "task": .string("First task label")]), .object([:])] {
            let fields: [String: WireValue] = ["role": .string("user"), "content": .string("Check **visible** task."), "nativeAgentDelivery": metadata]
            let message = TranscriptMessage.project(id: "first", message: fields)
            XCTAssertEqual(ConversationContent.transcriptText(["id": .string("first"), "message": .object(fields)], managedChild: true), rowPayload(message))
        }
    }
    @MainActor func testUnloadedFirstAgentTaskMatchesItsNativeCard() async throws {
        for events in [false, true] {
            var metadata: [String: WireValue] = ["author": .string("parent"), "childId": .string("ordinary-find"), "turn": .number(1), "task": .string("First task label")]
            if events { metadata["events"] = .array([.object(["kind": .string("task"), "text": .string("Check **visible** task.")])]) }
            let entries: [WireValue] = [.object(["type": .string("message"), "id": .string("question"), "parentId": .null,
                "message": .object(["role": .string("user"), "content": .string(events ? "hidden transport" : "Check **visible** task."), "nativeAgentDelivery": .object(metadata)])]),
                .object(["type": .string("message"), "id": .string("reply"), "parentId": .string("question"), "message": .object(["role": .string("assistant"), "content": .string("Done.")])])]
            let (model, pane, _) = try await findFixture(saved: true, entries: entries)
            let session = try XCTUnwrap(model.selected)
            var link = SubagentTranscriptTests.link; link.childSessionID = session.id
            model.chats[0].delegation = link; session.isManagedSubagent = true
            for numbered in [false, true] {
                session.subagentNumbers = numbered ? [session.id: 3] : [:]
                let shown = rowPayload(try XCTUnwrap(session.presentedMessages.first)), saved = session.messages
                for loaded in [true, false] {
                    if !loaded { session.messages = Array(saved.suffix(1)); pane.refresh() }
                    let result = try await model.searchConversation(session.id, query: "", start: 0, renderedAgentProse: true)
                    XCTAssertEqual(result.hits.first { $0.id == "question" }?.preview, shown, "events=\(events), numbered=\(numbered), loaded=\(loaded)")
                    if !loaded, !numbered {
                        let cold = try await model.history.searchContent(path: try XCTUnwrap(model.chats[0].path), query: "", start: 0, renderedAgentProse: true, managedChild: true)
                        XCTAssertEqual(cold.hits.first { $0.id == "question" }?.preview, shown, "A caller without a display snapshot still keeps saved delivery metadata")
                    }
                    for query in ["First task label", numbered ? "Parent → Sub-agent 3" : "Parent → Sub-agent", "turn 1", "Check visible task."] {
                        let found = try await model.searchConversation(session.id, query: query, start: 0, renderedAgentProse: true)
                        XCTAssertEqual(found.hits.map(\.id), ["question"], query)
                    }
                    session.messages = saved
                }
            }
        }
    }
    @MainActor private func openFetchedCard(_ session: SessionDisplay, pane: NativeTranscriptPane, message: TranscriptMessage, document: ToolInputDocument) async throws {
        session.toolInputs.forget(session.toolInputs.knownIDs)
        session.messages = [message]
        for item in TaskTranscriptPlan.rows(session.presentedMessages, lifecycle: nil) {
            if case .block(let block) = item {
                session.disclosure.setOpen(true, .work(block.key))
                if let fold = block.foldGroup { session.disclosure.setOpen(true, .turnFold(fold)) }
            }
        }
        let tool = try XCTUnwrap(message.tools?.first), key = ToolOccurrence.key(message.id, tool.id)
        session.disclosure.setOpen(true, .tool(key))
        session.toolInputs.load = { _, _ in document }
        session.toolInputs.request(messageID: message.id, callID: tool.id)
        try await eventually("Generated full arguments arrive") { session.toolInputs.document(key) == document }
        pane.refresh(); pane.layoutSubtreeIfNeeded()
    }
    @MainActor func testFetchedArgumentsMatchNativeCardsInEverySearchPath() async throws {
        let corpus: [(String, WireValue, String)] = [
            ("custom_fixture", .object(["message": .string("fetched needle"), "nested": .object(["value": .number(2)])]), "result"),
            ("bash", .object(["command": .string("printf 'fetched needle'")]), "command result"),
            ("edit", .object(["path": .string("fixture.txt"), "oldText": .string("old"), "newText": .string("fetched needle")]), "applied"),
            ("write", .object(["path": .string("fixture.txt"), "content": .string("fetched needle")]), "written"),
            ("read", .object(["path": .string("fixture.txt"), "offset": .number(17)]), "read result"),
            ("subagent_start", .object(["description": .string("Fetched task"), "task": .string("Check **fetched** needle")]), "{\"text\":\"done\"}"),
            ("subagent_send", .object(["child_id": .string("child"), "message": .string("Check **fetched** needle")]), "{\"accepted\":true}"),
            ("subagent_report", .object(["kind": .string("note"), "message": .string("Check **fetched** needle")]), "{\"accepted\":true}")]
        for mode in ["retained", "unsaved", "no-journal"] {
            let (model, pane, _) = try await findFixture(saved: true)
            let session = try XCTUnwrap(model.selected)
            if mode == "no-journal" { model.chats[0].path = nil }
            for timeline in [false, true] { for (name, arguments, output) in corpus {
                let entry = toolEntry(name, arguments: arguments)
                var message = TranscriptMessage.project(id: mode == "unsaved" ? "live" : "reply", message: try XCTUnwrap(entry["message"]?.object))
                if mode == "unsaved" { message.state = "streaming" }
                if !timeline { message.responseTimeline = nil }
                message.tools?[0].input = "{\"path\":\"fixture.txt\",\"preview\":\"short\"}"
                message.tools?[0].inputTruncated = true; message.tools?[0].state = "completed"; message.tools?[0].output = output
                let full = arguments.pretty
                let document = ToolInputDocument(input: full, truncated: false, bytes: full.utf8.count, streaming: false)
                try await openFetchedCard(session, pane: pane, message: message, document: document)
                let shown = Self.cardPayload(try XCTUnwrap(session.presentedMessages.first?.tools?.first), fetched: document)
                let item = try XCTUnwrap(TaskTranscriptPlan.rows(session.presentedMessages, lifecycle: nil).first { item in
                    if case .block(let block) = item { return block.presentation == .work && block.replies.contains { $0.tools?.isEmpty == false } }; return false
                })
                var environment = TranscriptRowEnvironment(); environment.opensFiles = true
                var actions = TranscriptActions(); actions.openFile = { _, _ in }
                let row = TranscriptRowRenderer.content(for: item, inputs: .init(item: item, fresh: false, actions: actions, width: 620,
                    environment: environment, disclosure: .of(item, in: session.disclosure, inputs: session.toolInputs)))
                row.frame = CGRect(x: 0, y: 0, width: 620, height: row.settle().height); row.layoutSubtreeIfNeeded()
                let native = try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeCard.self, in: row).first)
                XCTAssertEqual(Self.cardPayload(try XCTUnwrap(session.presentedMessages.first?.tools?.first), fetched: document, rendered: native), shown,
                               "The planner row renderer receives the same document: \(mode), timeline=\(timeline), \(name)")
                let result = try await model.searchConversation(session.id, query: "", start: 0, renderedAgentProse: true)
                XCTAssertEqual(result.hits.first { $0.id == message.id }?.preview, String(shown.prefix(240)), "\(mode), timeline=\(timeline), \(name)")
                if name != "read" {
                    let found = try await model.searchConversation(session.id, query: "fetched needle", start: 0, renderedAgentProse: true)
                    XCTAssertEqual(found.hits.map(\.id), [message.id], "\(mode), timeline=\(timeline), \(name)")
                }
            } }
        }
    }
    @MainActor func testFindRefreshesWhenFetchedArgumentsArriveWithoutNavigation() async throws {
        let (model, pane, window) = try await findFixture(saved: true)
        let session = try XCTUnwrap(model.selected)
        let tool = ToolView(id: "call", name: "custom_fixture", state: "completed", input: "{\"preview\":\"short\"}", output: "", truncated: false, inputTruncated: true)
        session.messages = [.init(id: "reply", role: "assistant", text: "", tools: [tool])]
        pane.refresh(); pane.showFind(); pane.find.setQuery("fetched needle")
        try await eventually("Initial search finishes") { !pane.find.searching }
        XCTAssertTrue(pane.find.matches.isEmpty)
        let input = "{\"message\":\"fetched needle\"}"
        try await openFetchedCard(session, pane: pane, message: session.messages[0], document: .init(input: input, truncated: false, bytes: input.utf8.count, streaming: false))
        try await eventually("Fetched card refresh settles") {
            pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching
        }
        XCTAssertEqual(pane.find.matches.map(\.messageID), ["reply"])
        XCTAssertNil(pane.document.highlights.focus, "A new result is not a reader navigation action")
        XCTAssertFalse(pane.document.focusPending)
        pane.find.step(1)
        try await assertFind("fetched needle", in: pane, window: window)
    }
    @MainActor func testFetchedInputsKeepTheirOccurrenceWhenCardsAreClosed() async throws {
        let (model, pane, window) = try await findFixture(saved: true)
        let session = try XCTUnwrap(model.selected); model.chats[0].path = nil
        let tool = ToolView(id: "reused", name: "custom_fixture", state: "completed", input: "{}", output: "", truncated: false, inputTruncated: true)
        session.messages = [.init(id: "first", role: "assistant", text: "", tools: [tool]), .init(id: "second", role: "assistant", text: "", tools: [tool])]
        session.toolInputs.load = { message, _ in .init(input: "{\"message\":\"fetched \(message)\"}", truncated: false, bytes: 30, streaming: false) }
        for id in ["first", "second"] { session.toolInputs.request(messageID: id, callID: tool.id) }
        try await eventually("Both occurrence documents arrive") { session.toolInputs.count == 2 }
        XCTAssertNil(session.toolInputs.document(tool.id), "An ambiguous legacy call ID cannot borrow either document")
        pane.refresh()
        for id in ["first", "second"] {
            let found = try await model.searchConversation(session.id, query: "fetched " + id, start: 0, renderedAgentProse: true)
            XCTAssertEqual(found.hits.map(\.id), [id], "Find opens the cached full document, including a closed card")
            try await assertFind("fetched " + id, in: pane, window: window, record: id)
            session.disclosure.setOpen(true, .tool(ToolOccurrence.key(id, tool.id)))
            let items = TaskTranscriptPlan.rows(session.presentedMessages, lifecycle: nil)
            let item = try XCTUnwrap(items.first { if case .block(let block) = $0 { return block.presentation == .work && block.replies.contains { $0.id == id } }; return false })
            let disclosure = TranscriptRowDisclosure.of(item, in: session.disclosure, inputs: session.toolInputs)
            XCTAssertEqual(disclosure.toolInputs[ToolOccurrence.key(id, tool.id)]?.input, "{\"message\":\"fetched \(id)\"}")
        }
    }
    @MainActor func testFindKeepsTheFileHeaderOfAnIOFallbackCard() async throws {
        let entry = toolEntry("write", arguments: .object(["path": .string("fallback.txt")]))
        let (model, _, _) = try await findFixture(saved: true, content: entry["message"]?.object?["content"])
        let session = try XCTUnwrap(model.selected), tool = try XCTUnwrap(session.presentedMessages.last?.tools?.first)
        let shown = Self.cardPayload(tool, linked: true)
        XCTAssertTrue(shown.hasPrefix("fallback.txt\n"), "The production pane enables the file header's link")
        let found = try await model.searchConversation(session.id, query: "", start: 0, renderedAgentProse: true)
        XCTAssertEqual(found.hits.first { $0.id == "reply" }?.preview, shown)
    }
    @MainActor func testFetchedAgentTaskKeepsTheDisplayedRowHeading() async throws {
        let (model, pane, _) = try await findFixture(saved: true)
        let session = try XCTUnwrap(model.selected)
        let tool = ToolView(id: "call", name: "subagent_start", state: "completed",
            input: "{\"description\":\"Inline label\",\"task\":\"short\"}", output: "", truncated: false, inputTruncated: true)
        let full = "{\"description\":\"Fetched label\",\"task\":\"Full task body\"}"
        let document = ToolInputDocument(input: full, truncated: false, bytes: full.utf8.count, streaming: false)
        try await openFetchedCard(session, pane: pane, message: .init(id: "reply", role: "assistant", text: "", tools: [tool]), document: document)
        let action = TranscriptNativeActionRow()
        action.update(tool: tool, open: true, fetched: document, environment: .init(), toggle: {}, openFile: nil)
        XCTAssertEqual(action.line.content.summary, "Inline label")
        let expected = action.line.content.title + " · " + action.line.content.summary + "\nFull task body"
        let result = try await model.searchConversation(session.id, query: "", start: 0, renderedAgentProse: true)
        XCTAssertEqual(result.hits.first { $0.id == "reply" }?.preview, expected)
        for (query, ids) in [("Inline label", ["reply"]), ("Fetched label", [])] {
            let found = try await model.searchConversation(session.id, query: query, start: 0, renderedAgentProse: true)
            XCTAssertEqual(found.hits.map(\.id), ids, query)
        }
    }
    @MainActor func testFetchedCardKeepsOutputOwnershipAcrossAPartialPage() async throws {
        for name in ["custom_fixture", "write"] {
            let arguments = WireValue.object(name == "write" ? ["path": .string("fixture.txt"), "content": .string("fetched needle")]
                : ["message": .string("fetched needle")])
            let (model, pane, _) = try await findFixture(saved: true, entries: pageBoundaryEntries(name, arguments: arguments, output: "outputneedle"))
            let session = try XCTUnwrap(model.selected)
            var call = try XCTUnwrap(session.messages.first { $0.id == "reply" })
            call.tools?[0].input = "{\"path\":\"fixture.txt\",\"preview\":\"short\"}"; call.tools?[0].inputTruncated = true
            let full = arguments.pretty, document = ToolInputDocument(input: full, truncated: false, bytes: full.utf8.count, streaming: false)
            for wire in [false, true] {
                let message = wire ? try XCTUnwrap(TranscriptMessage.page(JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode([call]))).first) : call
                try await openFetchedCard(session, pane: pane, message: message, document: document)
                let shown = Self.cardPayload(try XCTUnwrap(message.tools?.first), fetched: document)
                let found = try await model.searchConversation(session.id, query: "", start: 0, renderedAgentProse: true)
                XCTAssertEqual(found.hits.filter { ["reply", "result"].contains($0.id) }.map(\.preview).filter { !$0.isEmpty }.joined(separator: "\n"), shown, "\(name), wire=\(wire)")
                for query in ["fetched needle", "outputneedle"] {
                    let hits = try await model.searchConversation(session.id, query: query, start: 0, renderedAgentProse: true)
                    XCTAssertEqual(hits.hits.reduce(0) { $0 + ($1.count ?? 1) }, ConversationContent.occurrences(of: query, in: shown))
                }
            }
        }
    }
    @MainActor func testFindExpandsFetchedEditTextBeyondItsPreview() async throws {
        let (model, pane, window) = try await findFixture(saved: true)
        let session = try XCTUnwrap(model.selected), query = "fetched middle change"
        let source = (0..<180).map { $0 == 90 ? query : "fixture line \($0)" }.joined(separator: "\n")
        let arguments = WireValue.object(["path": .string("fixture.txt"), "oldText": .string("old"), "newText": .string(source)]).pretty
        let tool = ToolView(id: "call", name: "edit", state: "completed", input: "{\"path\":\"fixture.txt\",\"newText\":\"short\"}", output: "applied", truncated: false, inputTruncated: true)
        try await openFetchedCard(session, pane: pane, message: .init(id: "reply", role: "assistant", text: "", tools: [tool]),
                                  document: .init(input: arguments, truncated: false, bytes: arguments.utf8.count, streaming: false))
        try await assertFind(query, in: pane, window: window)
        XCTAssertTrue(ConversationPaneTests.views(TranscriptNativeDiffCard.self, in: pane.document).contains(where: \.expanded))
    }
    @MainActor func testUnloadedAgentToolKeepsItsNumberAcrossDecodeRuns() async throws {
        var entries = pageBoundaryEntries("subagent_send", arguments: .object(["child_id": .string("child"), "message": .string("Task body")]), output: "{\"text\":\"Result body\"}")
        var parent = "reply", spacers: [WireValue] = []
        for i in 0..<40 {
            let id = "spacer-\(i)"
            spacers.append(.object(["type": .string("message"), "id": .string(id), "parentId": .string(parent), "message": .object(["role": .string("system"), "nativeKind": .string("notice"), "content": .string("Spacer")])]))
            parent = id
        }
        var receipt = try XCTUnwrap(entries[1].object); receipt["parentId"] = .string(parent)
        entries = [entries[0]] + spacers + [.object(receipt), entries[2]]
        let (model, pane, _) = try await findFixture(saved: true, entries: entries)
        let session = try XCTUnwrap(model.selected); session.subagentNumbers = ["child": 3]
        let source = try XCTUnwrap(session.presentedMessages.first { $0.id == "reply" }), shown = Self.cardPayload(try XCTUnwrap(source.tools?.first))
        session.messages = Array(session.messages.suffix(1)); pane.refresh()
        let found = try await model.searchConversation(session.id, query: "", start: 0, renderedAgentProse: true)
        XCTAssertEqual(found.hits.filter { ["reply", "result"].contains($0.id) }.map(\.preview).filter { !$0.isEmpty }.joined(separator: "\n"), shown)
        let number = try await model.searchConversation(session.id, query: "Sub-agent 3", start: 0, renderedAgentProse: true)
        XCTAssertEqual(number.hits.map(\.id), ["reply"])
    }
    @MainActor func testFetchedRefreshKeepsNavigationAlreadyInFlight() async throws {
        let (model, pane, window) = try await findFixture(saved: true, source: "needle here")
        let session = try XCTUnwrap(model.selected)
        let tool = ToolView(id: "call", name: "custom_fixture", state: "completed", input: "{}", output: "", truncated: false, inputTruncated: true)
        session.messages[1].tools = [tool]
        pane.refresh(); pane.showFind()
        pane.find.search = { _, _, _ in .init(hits: ["reply", "target"].enumerated().map { .init(id: $0.element, position: $0.offset, preview: "needle", count: 1) }, total: 2, next: nil, revision: "fixture") }
        var waiting: CheckedContinuation<Void, Never>?, cancelled: Bool?
        defer { waiting?.resume() }
        pane.find.reveal = { _, _ in
            await withCheckedContinuation { waiting = $0 }
            cancelled = Task.isCancelled
            return true
        }
        pane.find.setQuery("needle")
        try await eventually("Initial Find settles") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching && !pane.document.focusPending }
        pane.find.step(1)
        try await eventually("The reader's Next waits for a page") { waiting != nil }
        try await openFetchedCard(session, pane: pane, message: session.messages[1], document: .init(input: "{\"message\":\"full arguments\"}", truncated: false, bytes: 28, streaming: false))
        try await eventually("Fetched refresh settles") { !pane.find.searching }
        session.messages += [.init(id: "target-question", role: "user", text: "Later question"), .init(id: "target", role: "assistant", text: "needle target")]
        pane.refresh(); waiting?.resume(); waiting = nil
        try await eventually("Pending reveal returns") { cancelled != nil }
        XCTAssertEqual(cancelled, false, "A document arriving must not cancel the reader's Next")
        if cancelled == false {
            try await eventually("The reader's chosen target is highlighted") {
                pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return pane.document.focusText?.string == "needle target" && !pane.document.focusPending
            }
        }
    }
    @MainActor func testFindMatchesDisplayedToolJSONInSavedAndLiveReplies() async throws {
        for saved in [true, false] {
            let entry = toolEntry("custom_fixture", arguments: .object(["message": .string("visible card value")]))
            let projected = TranscriptMessage.project(id: "reply", message: try XCTUnwrap(entry["message"]?.object))
            let query = try XCTUnwrap(Self.cardPayload(try XCTUnwrap(projected.tools?.first)).split(separator: "\n").first { $0.contains("visible card value") })
                .trimmingCharacters(in: .whitespaces)
            let (model, pane, window) = try await findFixture(saved: saved, content: saved ? entry["message"]?.object?["content"] : nil)
            if !saved { model.selected?.messages[1] = projected; model.selected?.messages[1].state = "streaming"; pane.refresh() }
            try await assertFind(query, in: pane, window: window)
        }
    }
    @MainActor func testFindOpensDecodedEditTextBeyondItsPreview() async throws {
        let query = "middle \"quoted\" change"
        let source = (0..<180).map { $0 == 90 ? query : "fixture line \($0)" }.joined(separator: "\n")
        let entry = toolEntry("edit", arguments: .object(["path": .string("fixture.txt"), "oldText": .string("old"), "newText": .string(source)]))
        let (_, pane, window) = try await findFixture(saved: true, content: entry["message"]?.object?["content"])
        try await assertFind(query, in: pane, window: window)
        if !pane.find.matches.isEmpty {
            XCTAssertTrue(ConversationPaneTests.views(TranscriptNativeDiffCard.self, in: pane.document).contains(where: \.expanded))
        }
    }
    @MainActor func testToolSearchProjectionEqualsNativeCardPayloadsSavedAndLive() throws {
        let corpus: [(String, WireValue, String)] = [
            ("custom_fixture", .object(["message": .string("two words 🌍 \"quoted\"\nnext line"), "nested": .object(["flag": .bool(true), "items": .array([.number(2), .null])])]), "output **stays literal**"),
            ("mcp", .object(["server": .string("fixture"), "tool": .string("lookup"), "arguments": .object(["key": .string("some value")])]), "result"),
            ("find", .object(["pattern": .string("*.swift"), "path": .string("fixture")]), "fixture/a.swift"),
            ("grep", .object(["pattern": .string("two words"), "path": .string("fixture")]), "fixture/a.swift:2: two words"),
            ("ls", .object(["path": .string("fixture")]), "first\nsecond"),
            ("bash", .object(["command": .string("printf 'one two'\nprintf 'three'"), "timeout": .number(12)]), "one two\nthree"),
            ("read", .object(["path": .string("fixture.txt"), "offset": .number(4)]), "first line\nlast line\n[Truncated. 9 total lines; read another range.]"),
            ("edit", .object(["path": .string("fixture.txt"), "oldText": .string("shared\nold \"tail\""), "newText": .string("shared\nnew \"tail\"")]), "applied"),
            ("write", .object(["path": .string("fixture.txt"), "content": .string("first line\nlast \"line\"")]), "written"),
            ("subagent_start", .object(["description": .string("Separate label"), "task": .string("1. **first**\n2. [second](https://example.test)")]), "{\"text\":\"**done** now\"}"),
            ("subagent_send", .object(["child_id": .string("fixture-child"), "message": .string("Check **these** words.")]), "{\"accepted\":true}"),
            ("subagent_report", .object(["kind": .string("note"), "message": .string("A **reported** observation.")]), "{\"accepted\":true}")
        ]
        for (name, arguments, output) in corpus {
            let entry = toolEntry(name, arguments: arguments)
            let saved = TranscriptMessage.project(id: "reply", message: try XCTUnwrap(entry["message"]?.object))
            let tool = try XCTUnwrap(saved.tools?.first)
            XCTAssertEqual(ConversationContent.transcriptText(entry), Self.cardPayload(tool), "Saved \(name)")
            for state in ["running", "completed", "held", "failed", "unknown"] {
                var live = saved; live.responseTimeline = nil; live.state = "streaming"
                live.tools?[0].state = state; live.tools?[0].output = output
                XCTAssertEqual(ConversationContent.transcriptText(live), Self.cardPayload(try XCTUnwrap(live.tools?.first)), "Live \(name), \(state)")
            }
        }
        for input in [#"{"message":"complete field","tail":"unfinished"#,
                      #"{"message":"a \"quoted\" value","tail":"unfinished"#,
                      #"{"message":"unterminated"#] {
            let tool = ToolView(id: "partial", name: "custom_fixture", state: "running", input: input, output: "", truncated: false, inputTruncated: true)
            let message = TranscriptMessage(id: "reply", role: "assistant", text: "", tools: [tool], state: "streaming")
            XCTAssertEqual(ConversationContent.transcriptText(message), Self.cardPayload(tool), "Partial input \(input)")
        }
    }

    static let copiedMarkdownCorpus = ["**alpha** beta and _italic_ ~~gone~~ `code`", "# Heading\n\nBody\n\nSetext\n------",
                      "1. alpha", "1. alpha\n2. beta", "7. seven\n29. eight\n   - nested\n\n     > quote",
                      "- ```swift\n  let x = 1\n  ```\n- next", "> # Quote\n>\n> body\n>\n> 1. one\n> 2. two",
                      "```text\nfirst\n\nlast\n```\n\n~~~\n~~~", "[site](https://example.test) and [reference][id]\n\n[id]: https://reference.test",
                      "![alt](https://image.test/a.png)\n\n<!-- hidden -->\n\nvisible", "| A | B |\n|---|---|\n| one | |\n| two | three |",
                      "| A | B |\n|---|---|\n" + (0..<45).map { "| row \($0) | value |" }.joined(separator: "\n"),
                      "Before **unfinished", "[unfinished](https://example.test", "1. first\n2.", "9. café 👩‍💻\n10. e\u{301}nd", "before  after\n\n`literal\tcode`",
                      "```text\nleft\tright  aligned\nzero\u{200D}join \u{FFFC} literal\n```", "---\n\nAfter rule", "| A | B | C |\n|:--|:-:|--:|\n| | | last |\n| | | |",
                      "```\n```\n\n```\n```\n\nafter", "- first\n\n  continuation\n\n- second", "hard  \nbreak\nsoft",
                      "<https://example.test>\n\n\\*literal\\* and &amp; entity"]

    @MainActor private static func copiedText(_ text: NSTextView) -> String {
        (text as? MarkdownTextView)?.copyText([NSRange(location: 0, length: text.string.utf16.count)]) ?? text.string
    }

    @MainActor func testCopiedMarkdownRangesMapBackToRenderedText() throws {
        for source in Self.copiedMarkdownCorpus {
            let (surface, window) = MarkdownTextSurfaceTests.surface(source)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let text = surface.textView, storage = try XCTUnwrap(text.textStorage)
            let copied = Self.copiedText(text)
            guard !copied.isEmpty else { continue }
            let cache = TranscriptTextMatches(storage)
            let matches = cache.ranges(.init(needle: copied))
            XCTAssertEqual(matches.count, 1, "Copied construct: \(source)")
            if let range = matches.first { XCTAssertEqual(text.copyText([range]), copied) }
            for word in ["alpha", "8.", "10.", "café", "👩‍💻", "e\u{301}nd", "literal\tcode"] {
                let expected = transcriptRanges(of: word, in: text.string as NSString)
                XCTAssertEqual(cache.ranges(.init(needle: word)), expected, "Character offsets stay exact after normalisation: \(word)")
            }
        }
    }

    @MainActor func testCopyNormalizationKeepsLiteralWhitespaceAndSelectionSemantics() throws {
        let source = "# Title\n\n7. first\n8. second\n\n- nested\n  - leaf\n\n| A | B |\n|:--|--:|\n| left | right |\n\n```text\nraw\ttab  spaces 👩‍💻\n```"
        let (surface, window) = MarkdownTextSurfaceTests.surface(source)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let text = surface.textView, rendered = text.string as NSString
        XCTAssertEqual(Self.copiedText(text), "Title\n\n7. first\n8. second\n\n- nested\n  - leaf\n\nA\tB\nleft\tright\n\nraw\ttab  spaces 👩‍💻")
        XCTAssertEqual(text.copyText([rendered.range(of: "first"), rendered.range(of: "second")]), "first\nsecond")
        XCTAssertEqual(text.copyText([rendered.range(of: "7.")]), "7. ")
        let storage = try XCTUnwrap(text.textStorage), cache = TranscriptTextMatches(storage)
        XCTAssertEqual(cache.ranges(.init(needle: "raw\ttab  spaces 👩‍💻")), [rendered.range(of: "raw\ttab  spaces 👩‍💻")])
        XCTAssertTrue(cache.ranges(.init(needle: "raw tab spaces")).isEmpty, "Literal whitespace is not made flexible")
        let raw = NSTextStorage(string: "1. alpha\t beta  👩‍💻\u{FFFC}")
        XCTAssertEqual(TranscriptTextMatches(raw).ranges(.init(needle: raw.string)), [NSRange(location: 0, length: raw.length)])
        XCTAssertTrue(TranscriptTextMatches(raw).ranges(.init(needle: "1. alpha beta")).isEmpty)
    }

    @MainActor func testCopiedMarkdownMatchCacheTracksLayoutAttributes() {
        let storage = NSTextStorage(string: "\t1.\talpha\nbeta")
        let cache = TranscriptTextMatches(storage)
        XCTAssertTrue(cache.ranges(.init(needle: "1. alpha\n\nbeta")).isEmpty)
        storage.addAttribute(.piListMarker, value: "1. ", range: NSRange(location: 0, length: 4))
        storage.addAttribute(.piBlockBreak, value: "\n\n", range: NSRange(location: 9, length: 1))
        let expected = NSRange(location: 1, length: 13)
        XCTAssertEqual(cache.ranges(.init(needle: "1. alpha\n\nbeta")), [expected])
        let scans = TranscriptHighlightSearch.scans
        storage.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: storage.length))
        XCTAssertEqual(cache.ranges(.init(needle: "1. alpha\n\nbeta")), [expected])
        XCTAssertEqual(TranscriptHighlightSearch.scans, scans, "Colour changes do not invalidate Find")
        storage.addAttribute(.piChrome, value: true, range: NSRange(location: 10, length: 4))
        XCTAssertTrue(cache.ranges(.init(needle: "1. alpha\n\nbeta")).isEmpty)
        storage.removeAttribute(.piChrome, range: NSRange(location: 10, length: 4))
        XCTAssertEqual(cache.ranges(.init(needle: "1. alpha\n\nbeta")), [expected])
        storage.removeAttribute(.piListMarker, range: NSRange(location: 0, length: 4))
        XCTAssertTrue(cache.ranges(.init(needle: "1. alpha\n\nbeta")).isEmpty)
        XCTAssertEqual(cache.ranges(.init(needle: "\t1.\talpha")), [NSRange(location: 0, length: 9)])
    }

    @MainActor func testCopiedBreaksDoNotDependOnColourRunBoundaries() throws {
        let surface = NativeMarkdownContainer(frame: .zero), text = surface.textView
        let storage = try XCTUnwrap(text.textStorage)
        storage.setAttributedString(NSAttributedString(string: "alpha\n\nbeta"))
        storage.addAttribute(.piBlockBreak, value: "\n\n", range: NSRange(location: 5, length: 2))
        let query = "alpha\n\n\n\nbeta", range = NSRange(location: 0, length: storage.length)
        let cache = TranscriptTextMatches(storage)
        XCTAssertEqual(text.copyText([range]), query, "Each marked block break has its declared copy spelling")
        XCTAssertEqual(cache.ranges(.init(needle: query)), [range])
        let scans = TranscriptHighlightSearch.scans
        storage.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 5, length: 1))
        XCTAssertEqual(text.copyText([range]), query, "Colour must not change what a selection copies")
        XCTAssertEqual(cache.ranges(.init(needle: query)), [range])
        XCTAssertEqual(TranscriptHighlightSearch.scans, scans)
    }

    @MainActor private func checkCopiedMarkdownFind(saved: Bool) async throws {
        for source in Self.copiedMarkdownCorpus {
            let (model, pane, window) = try await findFixture(saved: saved, source: source)
            for streaming in saved ? [false] : [true, false] {
                if !saved { model.selected?.messages[1].state = streaming ? "streaming" : "complete"; pane.refresh() }
                for raw in [false, true] {
                    pane.closeFind(focusing: false)
                    model.selected?.disclosure.setOpen(raw, .source("reply")); pane.refresh()
                    pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    let text = try XCTUnwrap(pane.document.rows(drawing: "reply").flatMap { TranscriptNativeDocument.textViews(in: $0) }
                        .first { $0.isSelectable && !$0.string.isEmpty })
                    let selection = (text.string as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: min(120, text.string.utf16.count)))
                    let query = (text as? MarkdownTextView)?.copyText([selection]) ?? (text.string as NSString).substring(with: selection)
                    guard !query.isEmpty else { continue }
                    pane.showFind(); pane.find.setQuery(query)
                    try await eventually("Copied Markdown search finishes") { pane.layoutSubtreeIfNeeded(); window.displayIfNeeded(); return !pane.find.searching }
                    XCTAssertFalse(pane.find.failed)
                    XCTAssertEqual(pane.find.matches.map(\.messageID), ["reply"], "saved=\(saved), streaming=\(streaming), raw=\(raw), source=\(source)")
                    guard !pane.find.matches.isEmpty else { continue }
                    try await eventually("Copied Markdown focuses its rendered range") {
                        pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                        return !pane.document.focusPending && pane.document.focusText != nil
                    }
                    let focused = try XCTUnwrap(pane.document.focusText), range = pane.document.focusRange
                    let copied = (focused as? MarkdownTextView)?.copyText([range]) ?? (focused.string as NSString).substring(with: range)
                    XCTAssertEqual(copied, query)
                    let manager = try XCTUnwrap(focused.layoutManager), container = try XCTUnwrap(focused.textContainer)
                    XCTAssertEqual(manager.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil) as? NSColor, TranscriptHighlights.focusColor)
                    let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
                    XCTAssertTrue(pane.scrollView.contentView.bounds.intersects(focused.convert(rect.offsetBy(dx: focused.textContainerOrigin.x, dy: focused.textContainerOrigin.y), to: pane.scrollView.contentView)))
                }
            }
        }
    }
    @MainActor func testCopiedMarkdownFindsAndFocusesSavedReplies() async throws { try await checkCopiedMarkdownFind(saved: true) }
    @MainActor func testCopiedMarkdownFindsAndFocusesLiveReplies() async throws { try await checkCopiedMarkdownFind(saved: false) }

    @MainActor func testFindProjectionEqualsNativeReplyTextAcrossMarkdownCorpus() throws {
        for (index, source) in Self.copiedMarkdownCorpus.enumerated() {
            for streaming in [false, true] { for raw in [false, true] {
                let message = TranscriptMessage(id: "corpus", role: "assistant", text: source, state: streaming ? "streaming" : "complete")
                let row = TranscriptNativeReplyRow(inputs: .init(item: TranscriptNativePartView.wordsItem(message), fresh: false,
                    actions: .init(), width: 620, environment: .init(), disclosure: .init(raw: raw), toggle: { _ in }))
                let shown = TranscriptNativeDocument.textViews(in: row).filter(\.isSelectable).map { Self.copiedText($0) }.joined(separator: "\n")
                XCTAssertEqual(ConversationContent.transcriptText(message, rawReply: raw), shown, "Corpus \(index), streaming=\(streaming), raw=\(raw)")
                if !streaming {
                    let entry: [String: WireValue] = ["id": .string("corpus"), "message": .object(["role": .string("assistant"), "content": .string(source)])]
                    XCTAssertEqual(ConversationContent.transcriptText(entry, rawReply: raw), shown, "Saved corpus \(index), raw=\(raw)")
                }
            } }
        }
    }

    @MainActor func testTimelineProjectionEqualsEachNativeSegmentInBothModes() throws {
        var timeline = ResponseTimeline()
        for (index, kind) in ["text", "refusal", "reasoningText", "reasoningSummary", "opaque", "text"].enumerated() {
            timeline.consume(.init(attemptID: "fixture", ordinal: index, itemID: "part-\(index)", kind: kind,
                update: index == 5 ? "append" : "replace", text: "\(index + 1). [site](https://part\(index).test)\n\n**alpha** beta"))
        }
        for streaming in [false, true] { for raw in [false, true] {
            let message = TranscriptMessage(id: "reply", role: "assistant", text: "Canonical text is not the arrival-ordered rows",
                                           state: streaming ? "streaming" : "complete", responseTimeline: timeline)
            let shown = timeline.segments.map { part -> String in
                let view = TranscriptNativePartView(frame: CGRect(x: 0, y: 0, width: 620, height: 300))
                view.update(.init(part: part, message: message, actions: .init(), open: true, toggle: {}, raw: raw, toggleRow: { _ in }, environment: .init()))
                return TranscriptNativeDocument.textViews(in: view).filter(\.isSelectable).map { Self.copiedText($0) }.joined(separator: "\n")
            }.joined(separator: "\n")
            XCTAssertEqual(ConversationContent.transcriptText(message, rawReply: raw), shown, "streaming=\(streaming), raw=\(raw)")
            if !streaming {
                let entry: [String: WireValue] = ["id": .string("reply"), "message": .object(["role": .string("assistant"), "content": .string(message.text),
                    "nativeResponseTimeline": try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(timeline))])]
                XCTAssertEqual(ConversationContent.transcriptText(entry, rawReply: raw), shown, "saved raw=\(raw)")
            }
        } }
    }

    @MainActor func testFindOpensTimelineProseForItsRenderedListMarker() async throws {
        for kind in ["reasoningText", "reasoningSummary", "opaque", "correction"] {
            let (model, pane, window) = try await findFixture(saved: false)
            var timeline = ResponseTimeline()
            timeline.consume(.init(attemptID: "fixture", ordinal: 0, itemID: "part", kind: kind, update: "replace", text: "7. first\n29. second"))
            model.selected?.messages[1].responseTimeline = timeline
            pane.refresh(); pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await assertFind("8.", in: pane, window: window)
        }
    }

    @MainActor func testAgentMarkdownSearchIncludesItsNativeListMarkers() {
        let view = TranscriptAgentMarkdown(label: "Task", identity: "list-marker")
        view.update("7. first\n29. second", environment: .init())
        XCTAssertTrue(view.markdown.textView.string.contains("8."))
        XCTAssertTrue(view.contains("8.", flexible: false), "The agent preview uses the same searchable text as its native surface")
    }

    func testSavedFindProjectsAssistantTextAlongsideToolCalls() throws {
        let prose: WireValue = .object(["type": .string("text"), "text": .string("**alpha** beta")])
        for name in ["read", "subagent_start"] {
            let tool: WireValue = .object(["type": .string("toolCall"), "id": .string("call"), "name": .string(name), "arguments": .object(["path": .string("fixture.txt"), "task": .string("Check **task** boundaries and \\*literal\\*.")])])
            let entry: [String: WireValue] = ["type": .string("message"), "id": .string("reply"), "message": .object(["role": .string("assistant"), "content": .array([prose, tool])])]
            XCTAssertEqual(ConversationContent.occurrences(of: "alpha beta", in: ConversationContent.transcriptText(entry)), 1, name)
            XCTAssertTrue(ConversationContent.text(entry).contains("**alpha** beta"))
            if SubagentToolView.isControl(name) {
                XCTAssertTrue(ConversationContent.transcriptText(entry).contains("Check task boundaries and *literal*."), "Already-rendered agent text is never parsed twice")
            }
        }
    }

    func testSavedFindProjectsTimelineProseAndKeepsSourceEvidence() throws {
        for kind in ["text", "reasoningText", "reasoningSummary"] {
            var timeline = ResponseTimeline()
            timeline.consume(.init(attemptID: "fixture", ordinal: 0, itemID: "text", kind: kind, update: "replace", text: "**alpha** beta"))
            timeline.consume(.init(attemptID: "fixture", ordinal: 1, itemID: "tool", kind: "toolArguments", update: "replace", text: "**literal** argument"))
            timeline.finish("completed")
            let entry: [String: WireValue] = ["message": .object(["role": .string("assistant"), "content": .string("**alpha** beta"),
                "nativeResponseTimeline": try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(timeline))])]
            let projected = ConversationContent.transcriptText(entry)
            XCTAssertEqual(ConversationContent.occurrences(of: "alpha beta", in: projected), 1, kind)
            XCTAssertTrue(projected.contains("**literal** argument"))
            XCTAssertTrue(ConversationContent.text(entry).contains("**alpha** beta"))
        }
        let user: [String: WireValue] = ["message": .object(["role": .string("user"), "content": .string("**alpha** beta")])]
        XCTAssertEqual(ConversationContent.transcriptText(user), "**alpha** beta")
        XCTAssertEqual(ConversationContent.text(user), "## user\n\n**alpha** beta\n\n", "Export keeps its source heading")
    }
}
