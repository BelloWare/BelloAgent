import XCTest
@testable import PiApp

/// A fork of a whole chat is a clone of the chat's journal (the helper's
/// `clonedFork`, fixture written by its ForkCloneTests): the chat's records
/// as written, run-state, cost and origin records among them, then the
/// fork's origin, a cost record that starts the spend again, its run state
/// and a context record that leaves the shown rows to each reader. The app
/// reads it as the helper does: the same rows whether it indexes the whole
/// journal or starts from the fork's metadata file, the edit's version
/// shown, and no unfinished work.
final class ForkCloneReaderTests: XCTestCase {
    /// The fixture, and its metadata file when `withMetadata`, in a
    /// directory of the test's own.
    private func fixture(withMetadata: Bool) throws -> String {
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<4 { root.deleteLastPathComponent() }
        let source = root.appendingPathComponent("fixtures/native/fork-clone.jsonl")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fork-clone-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("fork-clone.jsonl")
        try FileManager.default.copyItem(at: source, to: path)
        if withMetadata { try FileManager.default.copyItem(at: URL(fileURLWithPath: source.path + ".meta"), to: URL(fileURLWithPath: path.path + ".meta")) }
        return path.path
    }
    /// Every shown row, paging back from the first page until none is older.
    private func everyRow(_ path: String) async throws -> [TranscriptMessage] {
        let reader = HistoryReader()
        var page = try await reader.window(path: path), rows = page.messages
        for _ in 0..<64 {
            guard let cursor = page.older else { break }
            page = try await reader.window(path: path, cursor: cursor)
            rows = page.messages + rows
        }
        XCTAssertNil(page.older, "every row reached")
        return rows
    }

    func testAClonedForkReadsAsTheHelperReadsIt() async throws {
        let whole = try fixture(withMetadata: false), fromMetadata = try fixture(withMetadata: true)
        let full = try await HistoryReader().read(path: whole)
        let partial = try await HistoryReader().read(path: fromMetadata)
        for page in [full, partial] {
            XCTAssertNil(page.notice); XCTAssertFalse(page.incompleteTail)
            XCTAssertNil(page.retainedRun, "the fork's own run state leaves no work unfinished")
        }
        XCTAssertNotNil(partial.older, "opened from its metadata file, the rows before it are offered")
        XCTAssertEqual(partial.messages.map(\.text), full.messages.suffix(partial.messages.count).map(\.text), "the rows read as a full index reads them")
        XCTAssertEqual(partial.total, full.total, "every shown row is counted")
        XCTAssertEqual(partial.assistantMessageCount, full.assistantMessageCount)
        XCTAssertEqual(partial.latestAssistantMessageID, full.latestAssistantMessageID)
        XCTAssertEqual(partial.lineage, full.lineage)
        let all = try await everyRow(whole), paged = try await everyRow(fromMetadata)
        XCTAssertEqual(paged.map(\.id), all.map(\.id), "every row, once, in order, either way")
        let texts = all.map(\.text)
        XCTAssertTrue(texts.contains { $0.hasPrefix("the edited answer") }, "the edit's version is shown")
        XCTAssertFalse(texts.contains("the original answer"), "the version it replaced is not")
        XCTAssertEqual(texts.last, "answer four")
    }
}
