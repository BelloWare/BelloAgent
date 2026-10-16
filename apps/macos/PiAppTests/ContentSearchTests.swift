import XCTest
@testable import PiApp

/// The conversation's own search (⌘F reads it for a chat's unloaded rows)
/// finds exactly what a case-insensitive `range(of:)` over each record's
/// text finds, in the same order and counts, with its ASCII shortcut and its
/// records decoded a run at a time.
final class ContentSearchTests: XCTestCase {
    /// A deterministic writer at a real search boundary, with no timing race.
    /// The lock protects the one-shot flag when captured by a Sendable observer.
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ action: () throws -> Void) rethrows {
            try lock.withLock { guard !done else { return }; done = true; try action() }
        }
    }
    static func append(_ bytes: Data, to path: String) throws {
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath:path)); defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf:bytes)
    }
    func testRenderedSearchIgnoresOnlyAnUncommittedTail() async throws {
        let root = scratchRoot("search-incomplete-tail"), path = root.appendingPathComponent("chat.jsonl")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let initial = Data("{\"type\":\"session\",\"version\":3,\"id\":\"chat\"}\n{\"type\":\"message\",\"id\":\"saved\",\"parentId\":null,\"message\":{\"role\":\"assistant\",\"content\":\"Saved answer\"}}\n".utf8)
        let pending = Data("{\"type\":\"message\",\"id\":\"pending\",\"parentId\":\"saved\",\"message\":{\"role\":\"assistant\",\"content\":\"Next".utf8)
        try (initial + pending).write(to:path)
        let reader = HistoryReader(indexDirectory:root)
        let found = try await reader.searchContent(path:path.path,query:"Saved answer",start:0,renderedAgentProse:true)
        XCTAssertEqual(found.hits.map(\.id),["saved"]); XCTAssertEqual(found.total,1)
        XCTAssertEqual(try Data(contentsOf:path),initial + pending)
        do { _ = try await reader.searchContent(path:path.path,query:"Saved",start:0); XCTFail("Source/copy searches still require validated history") }
        catch { }
        try Self.append(Data(" answer\"}}\n".utf8),to:path.path)
        let completed = try await reader.searchContent(path:path.path,query:"Next answer",start:0,renderedAgentProse:true)
        XCTAssertEqual(completed.hits.map(\.id),["pending"])
        try Self.append(Data("not a complete JSON record\n".utf8),to:path.path)
        do { _ = try await reader.searchContent(path:path.path,query:"Saved",start:0,renderedAgentProse:true); XCTFail("A damaged complete record is never a pending append") }
        catch { }
        // A malformed newest state is decoded after the fast offset scan. A
        // following in-flight line must not mask that complete record's damage.
        let damagedState = Data("{\"customType\":\"pi-app.native.state.v1\",\"data\":{\"active\":tru},\"id\":\"state\",\"parentId\":\"saved\",\"timestamp\":\"2026-10-16T00:00:00Z\",\"type\":\"custom\"}\n{".utf8)
        try (initial + damagedState).write(to:path)
        do { _ = try await reader.searchContent(path:path.path,query:"Saved",start:0,renderedAgentProse:true); XCTFail("A pending tail cannot hide damaged state") }
        catch { }
    }
    func testRenderedSearchRejectsRewrittenTruncatedAndReplacedSnapshots() async throws {
        for change in ["rewrite-and-grow", "truncate", "replace"] {
            let root = scratchRoot("search-changed-prefix"), path = root.appendingPathComponent("chat.jsonl")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:root) }
            let source = "Saved answer " + String(repeating:"x",count:300_000)
            let header = Data("{\"type\":\"session\",\"version\":3,\"id\":\"chat\"}\n".utf8)
            let row = try JSONEncoder().encode(WireValue.object(["type":.string("message"),"id":.string("saved"),"parentId":.null,
                "message":.object(["role":.string("assistant"),"content":.string(source)])]))
            let bytes = header + row + Data([10]); try bytes.write(to:path)
            let reader = HistoryReader(indexDirectory:root)
            await reader.observeSearchReads { stage in
                guard stage == .indexed else { return }
                if change == "replace" { try bytes.write(to:path,options:.atomic); return }
                let file = try FileHandle(forWritingTo:path); defer { try? file.close() }
                if change == "truncate" { try file.truncate(atOffset:UInt64(header.count)); return }
                // Outside both 64 KiB edge fingerprints: growth must not hide
                // an in-place change anywhere in the captured prefix.
                try file.seek(toOffset:150_000); try file.write(contentsOf:Data("y".utf8))
                try file.seekToEnd(); try file.write(contentsOf:Data("\n".utf8))
            }
            do { _ = try await reader.searchContent(path:path.path,query:"Saved answer",start:0,renderedAgentProse:true); XCTFail("Accepted \(change)") }
            catch { }
        }
    }
    func testRenderedSearchBoundsItsSnapshotWhileMessagesAppend() async throws {
        for stage in HistoryReader.SearchReadStage.allCases {
            let root = scratchRoot("search-append"), path = root.appendingPathComponent("chat.jsonl")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:root) }
            let initial = Data("""
            {"type":"session","version":3,"id":"chat"}
            {"type":"message","id":"saved","parentId":null,"message":{"role":"user","content":"A **rendered** result","nativeAgentDelivery":{"author":"subagent","childId":"child","turn":1}}}

            """.utf8)
            let addition = Data("{\"type\":\"message\",\"id\":\"appended\",\"parentId\":\"saved\",\"message\":{\"role\":\"assistant\",\"content\":\"Appended result\"}}\n".utf8)
            try initial.write(to:path)
            let reader = HistoryReader(indexDirectory:root), once = Once()
            await reader.observeSearchReads { current in
                if current == stage { try once.run { try Self.append(addition,to:path.path) } }
            }
            let found = try await reader.searchContent(path:path.path,query:"rendered result",start:0,renderedAgentProse:true)
            XCTAssertEqual(found.hits.map(\.id),["saved"]); XCTAssertEqual(found.total,1); XCTAssertNil(found.next)
            await reader.observeSearchReads(nil)
            let next = try await reader.searchContent(path:path.path,query:"Appended result",start:0,renderedAgentProse:true)
            XCTAssertEqual(next.hits.map(\.id),["appended"]); XCTAssertEqual(next.total,2)
            XCTAssertEqual(try Data(contentsOf:path),initial + addition)
        }
    }
    func testIncompleteResponseCopyUsesPlainHeadingAndKeepsTheFullSavedSource() throws {
        var timeline = ResponseTimeline()
        timeline.consume(.init(attemptID:"attempt",ordinal:0,itemID:"part",kind:"text",update:"append",text:"Partial preview"))
        timeline.omittedEvents = 1
        let encoded = try JSONDecoder().decode(WireValue.self,from:JSONEncoder().encode(timeline))
        let source = "Complete **saved** answer"
        let text = ConversationContent.text(["message":.object(["role":.string("assistant"),"content":.string(source),"nativeResponseTimeline":encoded])])
        XCTAssertTrue(text.contains("## Full saved response"))
        XCTAssertTrue(text.contains("Partial preview")); XCTAssertTrue(text.contains(source))
        XCTAssertFalse(text.contains("Canonical")); XCTAssertFalse(text.contains("arrival order"))
    }
    func testRenderedSearchKeepsSourceCopyPagingAndAbandonedRowsSeparate() async throws {
        let root = scratchRoot("rendered-agent-search")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var data = Data(), parent: String?
        func add(_ record: WireValue) throws { data.append(try JSONEncoder().encode(record)); data.append(10) }
        try add(.object(["type": .string("session"), "version": .number(3), "id": .string("fixture")]))
        try add(.object(["type": .string("message"), "id": .string("abandoned"), "parentId": .null,
            "message": .object(["role": .string("assistant"), "content": .string("Abandoned stale reply")])]))
        // A new root abandons the old reply, but retains its record in the journal.
        for index in 0..<110 {
            try add(.object(["type": .string("message"), "id": .string("agent-\(index)"), "parentId": parent.map(WireValue.string) ?? .null,
                "message": .object(["role": .string("user"), "content": .string("A **rendered** phrase. A **rendered** phrase."),
                    "nativeAgentDelivery": .object(["author": .string("subagent"), "childId": .string("child"), "turn": .number(1)])])]))
            parent = "agent-\(index)"
        }
        let file = root.appendingPathComponent("fixture.jsonl"); try data.write(to: file)
        let reader = HistoryReader()
        var hits: [ContentHit] = [], start = 0
        repeat {
            let found = try await reader.searchContent(path: file.path, query: "A rendered phrase", start: start, renderedAgentProse: true)
            hits += found.hits; start = found.next ?? -1
        } while start >= 0
        XCTAssertEqual(hits.map(\.id), (0..<110).map { "agent-\($0)" })
        XCTAssertTrue(hits.allSatisfy { $0.count == 2 })
        let raw = try await reader.searchContent(path: file.path, query: "**rendered**", start: 0)
        XCTAssertEqual(raw.hits.count, 100)
        let copy = try await reader.copyContentPage(path: file.path, first: 1, last: 1, cursor: .init(index: 1, offset: 0), revision: raw.revision)
        XCTAssertTrue(copy.text.contains("A **rendered** phrase."))
        let stale = try await reader.searchContent(path: file.path, query: "Abandoned stale reply", start: 0, renderedAgentProse: true,
            presented: [.init(id: "abandoned", role: "assistant", text: "Abandoned stale reply")])
        XCTAssertTrue(stale.hits.isEmpty, "A stale display must not append an abandoned journal row as unsaved text")
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    func testTheASCIIShortcutOnlyExcludesWhatCannotMatch() {
        let needle = try! XCTUnwrap(ConversationContent.asciiNeedle("Zephyr C"))
        XCTAssertTrue(ConversationContent.excludes(needle, from: "nothing here at all"))
        XCTAssertFalse(ConversationContent.excludes(needle, from: "a ZEPHYR checkpoint"), "case is folded")
        XCTAssertFalse(ConversationContent.excludes(needle, from: "ends in zephyr c"))
        XCTAssertTrue(ConversationContent.excludes(needle, from: "zephyr"), "shorter than the needle")
        // Anything but ASCII is left to range(of:).
        XCTAssertFalse(ConversationContent.excludes(needle, from: "café, nothing else"))
        XCTAssertNil(ConversationContent.asciiNeedle("straße"))
        XCTAssertNil(ConversationContent.asciiNeedle(""))
    }

    @MainActor func testSearchHitsAreThoseOfRangeOfOverEveryRecord() async throws {
        let root = scratchRoot("content-search")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var data = try LongChatScroll.journal(turns: 40)
        // Records whose text is not ASCII alone: a Kelvin sign, a sharp s, an emoji.
        var parent = "a39b"
        for (index, text) in ["The \u{212A}elvin scale", "Die Straße und die STRASSE", "Parser 🎉 done, parser again"].enumerated() {
            data.append(try JSONEncoder().encode(["type": WireValue.string("message"), "id": .string("x\(index)"), "parentId": .string(parent),
                                                  "message": .object(["role": .string("assistant"), "content": .string(text)])]))
            data.append(10); parent = "x\(index)"
        }
        let file = root.appendingPathComponent("long.jsonl")
        try data.write(to: file)
        // The reference: every record's text, searched the way the search always did.
        let records = String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst().map { line in
            ConversationContent.text((try? JSONDecoder().decode(WireValue.self, from: Data(line.utf8)))?.object ?? [:])
        }
        let reader = HistoryReader()
        for query in ["everything for question 1", "PARSE(INPUT, AT: 57)", "kelvin", "strasse", "parser", "🎉", "nothing says this", "e"] {
            var expected: [(Int, Int)] = []
            for (index, text) in records.enumerated() where expected.count < 100 && text.range(of: query, options: [.caseInsensitive]) != nil {
                expected.append((index + 1, ConversationContent.occurrences(of: query, in: text)))
            }
            var found: [(Int, Int)] = [], start = 0
            while true {
                let page = try await reader.searchContent(path: file.path, query: query, start: start)
                found += page.hits.map { ($0.position, $0.count ?? 1) }
                guard found.count < 100, let next = page.next else { break }
                start = next
            }
            XCTAssertEqual(found.prefix(100).map(\.0), expected.map(\.0), "positions for \(query)")
            XCTAssertEqual(found.prefix(100).map(\.1), expected.map(\.1), "counts for \(query)")
        }
    }
}
