import XCTest
@testable import GitView

/// The diff parser on its own, without a repository or a window: files,
/// hunks, lines with their numbers, the counts a card shows, and the rows a
/// side-by-side card pairs.
final class GitDiffParserTests: XCTestCase {
    static let patch = """
    diff --git a/Sources/Engine/Router.swift b/Sources/Engine/Router.swift
    --- a/Sources/Engine/Router.swift
    +++ b/Sources/Engine/Router.swift
    @@ -18,4 +18,5 @@ struct Router {
         let profile: Profile
    -    var timeout: Duration = .seconds(30)
    +    var timeout: Duration = .seconds(45)
    +    var retries = 2
         func route() {}

    """

    func testAPatchBecomesFilesHunksAndNumberedLines() throws {
        let files = GitDiffParser.parse(Self.patch)
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(file.path, "Sources/Engine/Router.swift")
        XCTAssertFalse(file.renamed)
        XCTAssertEqual(file.added, 2); XCTAssertEqual(file.removed, 1); XCTAssertEqual(file.lineCount, 5)
        let hunk = try XCTUnwrap(file.hunks.first)
        XCTAssertEqual(hunk.header, "@@ -18,4 +18,5 @@ struct Router {")
        XCTAssertEqual(hunk.lines.map(\.kind), [.context, .removed, .added, .added, .context])
        XCTAssertEqual(hunk.lines.map(\.oldNumber), [18, 19, nil, nil, 20])
        XCTAssertEqual(hunk.lines.map(\.newNumber), [18, nil, 19, 20, 21])
        XCTAssertEqual(hunk.lines[2].text, "    var timeout: Duration = .seconds(45)")
    }

    func testSideBySideRowsPairTheRemovedWithTheAdded() throws {
        let hunk = try XCTUnwrap(GitDiffParser.parse(Self.patch).first?.hunks.first)
        let rows = hunk.splitRows()
        XCTAssertEqual(rows.count, 4, "Context, the changed pair, the added line alone, context")
        XCTAssertEqual(rows[1].left?.kind, .removed); XCTAssertEqual(rows[1].right?.kind, .added)
        XCTAssertNil(rows[2].left); XCTAssertEqual(rows[2].right?.text, "    var retries = 2")
    }

    func testARenameKeepsBothPaths() throws {
        let files = GitDiffParser.parse("diff --git a/old.txt b/new.txt\nsimilarity index 100%\nrename from old.txt\nrename to new.txt\n")
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(file.oldPath, "old.txt"); XCTAssertEqual(file.newPath, "new.txt")
        XCTAssertTrue(file.renamed)
    }
}
