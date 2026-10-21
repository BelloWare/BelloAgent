import XCTest
@testable import GitView

/// Only generated, local repositories. The fixture's config also protects
/// GitService calls, which deliberately use the repository's own settings.
final class GitHistoryQueryTests: ViewsTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("history-query-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-qb", "main"])
        for (key, value) in [("user.name", "History Fixture"), ("user.email", "history@example.invalid"),
                             ("commit.gpgsign", "false"), ("tag.gpgsign", "false"),
                             ("core.hooksPath", "/dev/null"), ("credential.helper", ""), ("core.fsmonitor", "false")] {
            try git(["config", key, value])
        }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    @discardableResult private func git(_ args: [String], environment: [String: String] = [:], input: URL? = nil) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = root; process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"
        ].merging(environment) { _, new in new }) { _, new in new }
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        let source = try input.map { try FileHandle(forReadingFrom: $0) }
        process.standardInput = source ?? FileHandle.nullDevice
        defer { try? source?.close() }
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, args.joined(separator: " "))
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    @discardableResult private func commit(_ message: String, path: String = "notes.txt", author: String = "History Fixture",
                                           authored: String = "2026-01-01T12:00:00Z", committed: String = "2026-10-01T12:00:00Z") throws -> String {
        try (message + "\n").write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        try git(["add", "--", path])
        try git(["commit", "-qm", message], environment: ["GIT_AUTHOR_NAME": author, "GIT_AUTHOR_DATE": authored, "GIT_COMMITTER_DATE": committed])
        return try git(["rev-parse", "HEAD"])
    }

    private func log(filter: GitLogFilter = .init()) async throws -> [GitCommit] {
        let service = GitService(), snapshot = try await service.historySnapshot(in: root.path, query: GitHistoryQuery(filter: filter))
        return try await service.historyPage(snapshot).commits
    }

    func testMessageSearchIsLiteralIncludingRegexPunctuation() async throws {
        let wanted = try commit("Fix [cache].* \\ parser")
        try commit("Fix cacheZ parser")
        let result = try await log(filter: GitLogFilter(text: "[cache].* \\"))
        XCTAssertEqual(result.map(\.hash), [wanted])
    }

    func testMessageThatLooksLikeAHashNeverInjectsACommitPastAuthorOrPath() async throws {
        let hash = try commit("Original", path: "old.txt", author: "Other Fixture")
        let prefix = String(hash.prefix(8))
        let matching = try commit("Mention " + prefix, path: "notes.txt")
        let result = try await log(filter: GitLogFilter(text: prefix, author: "History Fixture", path: "notes.txt"))
        XCTAssertEqual(result.map(\.hash), [matching])
        let noMatch = try await log(filter: GitLogFilter(text: hash, author: "Nobody", path: "notes.txt"))
        XCTAssertTrue(noMatch.isEmpty)
        let wrongAuthor = try await log(filter: GitLogFilter(text: hash, author: "Nobody"))
        XCTAssertTrue(wrongAuthor.isEmpty)
    }

    func testHistoryUsesCommittedDate() async throws {
        try commit("Later commit, old author date", committed: "2026-10-13T23:59:59Z")
        let result = try await log()
        XCTAssertEqual(result.first?.date, ISO8601DateFormatter().date(from: "2026-10-13T23:59:59Z"))
    }

    func testDateDaysIncludeBothBoundariesAndDoNotPruneNewerAncestors() async throws {
        try commit("Before", committed: "2026-10-12T23:59:59Z")
        let start = try commit("Start", committed: "2026-10-13T00:00:00Z")
        let end = try commit("End", committed: "2026-10-13T23:59:59Z")
        try commit("After", committed: "2026-10-14T00:00:00Z")
        try commit("Old head with newer ancestors", committed: "2026-10-01T00:00:00Z")
        let service = GitService()
        let snapshot = try await service.historySnapshot(in: root.path, query: GitHistoryQuery(dates: .init(from: "2026-10-13", through: "2026-10-13")))
        let page = try await service.historyPage(snapshot)
        XCTAssertEqual(Set(page.commits.map(\.hash)), [start, end])
        XCTAssertNil(page.next)
    }

    func testInvalidDateOrRefIsAnErrorRatherThanAnUnfilteredHistory() async throws {
        try commit("Seed")
        let service = GitService()
        for query in [GitHistoryQuery(dates: .init(from: "2026-02-30")),
                      GitHistoryQuery(dates: .init(from: "2026-10-14", through: "2026-10-01")),
                      GitHistoryQuery(scope: .reference("--all"))] {
            do { _ = try await service.historySnapshot(in: root.path, query: query); XCTFail("Invalid input was accepted") } catch is GitFailure {}
        }
    }

    func testDateFilteredFilePagesFollowRenamesAfterTheEndDate() async throws {
        let before = try commit("Before the range", path: "[old]*.txt", committed: "2026-09-28T23:59:59Z")
        var matches: [String] = []
        for i in 0..<7 {
            let time = i == 0 ? "00:00:00" : i == 6 ? "23:59:59" : "12:00:0\(i)"
            matches.insert(try commit("Match \(i)\n\nBody-only [needle].*", path: "[old]*.txt", committed: "2026-09-29T\(time)Z"), at: 0)
            if i == 2 { try commit("Outside the date range", path: "[old]*.txt", committed: "2026-09-30T12:00:00Z") }
        }
        for (from, to) in [("[old]*.txt", "middle.txt"), ("middle.txt", "new name.txt")] {
            try git(["mv", from, to])
            try git(["commit", "-qm", "Rename"], environment: ["GIT_AUTHOR_NAME": "Rename Fixture", "GIT_COMMITTER_DATE": "2026-10-01T12:00:00Z"])
        }
        for i in 0..<4 { try commit("After rename \(i)", path: "new name.txt", committed: "2026-10-02T12:00:00Z") }
        try "working bytes\r\n".write(to: root.appendingPathComponent("new name.txt"), atomically: true, encoding: .utf8)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let bytes = try Data(contentsOf: root.appendingPathComponent("new name.txt"))
        let tree = try git(["rev-parse", "HEAD^{tree}"]), blob = try git(["show", ":new name.txt"])
        let service = GitService()
        let through = GitHistoryDates(through: "2026-09-29")
        for (query, expected) in [
            (GitHistoryQuery(path: "new name.txt", dates: through), matches + [before]),
            (GitHistoryQuery(path: "new name.txt", dates: .init(from: "2026-09-29", through: "2026-09-29")), matches),
            (GitHistoryQuery(message: "Match", path: "new name.txt", dates: through), matches),
            (GitHistoryQuery(author: "History Fixture", path: "new name.txt", dates: through), matches + [before]),
            (GitHistoryQuery(message: "Match", author: "History Fixture", path: "new name.txt"), matches),
            (GitHistoryQuery(message: "Body-only [needle].*", path: "new name.txt", dates: through), matches),
            (GitHistoryQuery(author: "history@example.invalid", path: "new name.txt", dates: through), matches + [before])
        ] {
            let snapshot = try await service.historySnapshot(in: root.path, query: query)
            var page = try await service.historyPage(snapshot, limit: 2), found = page.commits.map(\.hash)
            for _ in 0..<10 {
                guard let cursor = page.next else { break }
                XCTAssertEqual(cursor.offset, found.count, "Only date-matching commits advance the cursor")
                page = try await service.historyPage(snapshot, after: cursor, limit: 2)
                found += page.commits.map(\.hash)
            }
            XCTAssertEqual(found, expected, "Query: \(query)")
            XCTAssertNil(page.next)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("new name.txt")), bytes)
        XCTAssertEqual(try git(["rev-parse", "HEAD^{tree}"]), tree)
        XCTAssertEqual(try git(["show", ":new name.txt"]), blob)
    }

    func testPagingIsAnchoredToImmutableTipsWhileABranchMoves() async throws {
        var expected: [String] = []
        for i in 0..<7 { expected.insert(try commit("Page \(i)"), at: 0) }
        let service = GitService()
        let snapshot = try await service.historySnapshot(in: root.path, query: GitHistoryQuery())
        var page = try await service.historyPage(snapshot, limit: 2)
        var found = page.commits.map(\.hash)
        try commit("Arrived after page one")
        for _ in 0..<10 {
            guard let cursor = page.next else { break }
            page = try await service.historyPage(snapshot, after: cursor, limit: 2)
            found += page.commits.map(\.hash)
        }
        XCTAssertEqual(found, expected)
        XCTAssertNil(page.next, "Paging must make progress and finish")
        let fresh = try await service.historySnapshot(in: root.path, query: GitHistoryQuery())
        do {
            _ = try await service.historyPage(fresh, after: GitHistoryCursor(snapshot: snapshot.id, offset: 2))
            XCTFail("A page cursor from a retired snapshot was accepted")
        } catch is GitFailure {}
    }

    func testExactHashNavigationDoesNotWalkToAnotherFileOrAffectTheCursor() async throws {
        let other = try commit("Other author", path: "unrelated.txt", author: "Other Fixture")
        let wanted = try commit("Mention " + other, path: "[notes]*.txt")
        let service = GitService()
        let query = GitHistoryQuery(message: other, author: "History Fixture", path: "[notes]*.txt")
        let snapshot = try await service.historySnapshot(in: root.path, query: query)
        let before = try await service.historyPage(snapshot, limit: 1)
        let exact = try await service.historyCommit(other, in: root.path)
        let after = try await service.historyPage(snapshot, limit: 1)
        XCTAssertEqual(exact.hash, other)
        XCTAssertEqual(before, after)
        XCTAssertEqual(before.commits.map(\.hash), [wanted]); XCTAssertNil(before.next)
        for invalid in ["HEAD", other + "~1", "--all"] {
            do { _ = try await service.historyCommit(invalid, in: root.path); XCTFail("Accepted a revision expression") } catch is GitFailure {}
        }
    }

    func testRefSelectorNamesBranchesAndTagsAndResolvesTheSelectedTip() async throws {
        let first = try commit("First")
        try git(["branch", "feature/long-name-with-punctuation"])
        try git(["tag", "-a", "v-fixture", "-m", "Fixture tag"])
        try commit("Second")
        let service = GitService(), refs = try await service.historyReferences(in: root.path)
        XCTAssertEqual(Set(refs.map(\.name)), ["refs/heads/main", "refs/heads/feature/long-name-with-punctuation", "refs/tags/v-fixture"])
        let snapshot = try await service.historySnapshot(in: root.path, query: GitHistoryQuery(scope: .reference("refs/tags/v-fixture")))
        let page = try await service.historyPage(snapshot)
        XCTAssertEqual(page.commits.map(\.hash), [first])
    }

    func testAHexadecimalBranchNameCannotImpersonateACommitHash() async throws {
        let first = try commit("First"), second = try commit("Second")
        let service = GitService()
        try git(["branch", "deadbeef", second])
        do { _ = try await service.historyCommit("deadbeef", in: root.path); XCTFail("Opened a hexadecimal ref") } catch is GitFailure {}
        try git(["branch", String(first.prefix(8)), second])
        let found = try await service.historyCommit(String(first.prefix(8)), in: root.path)
        XCTAssertEqual(found.hash, first)
    }

    @MainActor func testFollowingARenameDoesNotRepeatEarlierLongSubjectsInThePageBudget() async throws {
        // Two pages fit individually, but their combined subjects exceed
        // GitService's 4 MiB cap. This is generated metadata, never a patch.
        var hashes: [String] = []
        for i in 0..<52 { hashes.insert(try commit("\(i) " + String(repeating: "x", count: 82_000)), at: 0) }
        let service = GitService(), snapshot = try await service.historySnapshot(in: root.path, query: GitHistoryQuery(message: "x", path: "notes.txt"))
        let first = try await service.historyPage(snapshot, limit: 25)
        let second = try await service.historyPage(snapshot, after: XCTUnwrap(first.next), limit: 25)
        let third = try await service.historyPage(snapshot, after: XCTUnwrap(second.next), limit: 25)
        XCTAssertEqual((first.commits + second.commits + third.commits).map(\.hash), hashes)
        XCTAssertNil(third.next)
    }

    @MainActor func testLargePreservingReadBatchesMetadataWithoutExceedingArgumentLimit() async throws {
        var stream = ""
        for i in 0..<4_001 {
            let message = "Change \(i)", body = "\(i)\n"
            stream += "commit refs/heads/main\ncommitter History Fixture <history@example.invalid> 1791936000 +0000\ndata \(message.utf8.count)\n\(message)\nM 100644 inline notes.txt\ndata \(body.utf8.count)\n\(body)\n"
        }
        let input = root.appendingPathComponent(".git/fixture-stream")
        try Data(stream.utf8).write(to: input); try git(["fast-import", "--quiet"], input: input)
        let service = GitService(), snapshot = try await service.historySnapshot(in: root.path, query: GitHistoryQuery(message: "Change", path: "notes.txt"))
        let page = try await service.historyPage(snapshot, limit: 4_000)
        XCTAssertEqual(page.commits.count, 4_000)
        XCTAssertEqual(page.commits.first?.subject, "Change 4000")
        let last = try await service.historyPage(snapshot, after: XCTUnwrap(page.next))
        XCTAssertEqual(last.commits.map(\.subject), ["Change 0"]); XCTAssertNil(last.next)
    }

    func testPathHistoryFollowsRenamesAndReadsLeaveAllRepositoryBytesAlone() async throws {
        let one = try commit("First", path: "[old]*.txt")
        try git(["mv", "[old]*.txt", "new name.txt"]); try git(["commit", "-qm", "Rename"])
        let renamed = try git(["rev-parse", "HEAD"])
        let two = try commit("Second", path: "new name.txt")
        try "staged\n".write(to: root.appendingPathComponent("staged.txt"), atomically: true, encoding: .utf8)
        try git(["add", "staged.txt"])
        try "working\r\n".write(to: root.appendingPathComponent("new name.txt"), atomically: true, encoding: .utf8)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), tree = try git(["rev-parse", "HEAD^{tree}"])
        let bytes = try Data(contentsOf: root.appendingPathComponent("new name.txt")), blob = try git(["show", ":staged.txt"])
        let service = GitService(), snapshot = try await service.historySnapshot(in: root.path, query: GitHistoryQuery(path: "new name.txt"))
        var page = try await service.historyPage(snapshot, limit: 1), found = page.commits.map(\.hash)
        while let cursor = page.next { page = try await service.historyPage(snapshot, after: cursor, limit: 1); found += page.commits.map(\.hash) }
        XCTAssertEqual(found, [two, renamed, one])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try git(["rev-parse", "HEAD^{tree}"]), tree)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("new name.txt")), bytes)
        XCTAssertEqual(try git(["show", ":staged.txt"]), blob)
    }

    @MainActor func testAnOldRefreshCannotOverwriteANewerQueryEvenAfterIOCompletes() async throws {
        let alpha = try commit("Alpha"), beta = try commit("Beta")
        let state = GitHistoryState(service: GitService())
        var entered = false, release: CheckedContinuation<Void, Never>?
        state.didRead = { query in
            guard query.message == "Alpha" else { return }
            entered = true
            await withCheckedContinuation { release = $0 }
        }
        let old = Task { await state.reload(in: root.path, query: GitHistoryQuery(message: "Alpha")) }
        try await waitUntil { entered }
        let newest = await state.reload(in: root.path, query: GitHistoryQuery(message: "Beta"))
        XCTAssertTrue(newest); XCTAssertEqual(state.reading.commits.map(\.hash), [beta])
        release?.resume(); let accepted = await old.value
        XCTAssertFalse(accepted); XCTAssertEqual(state.reading.commits.map(\.hash), [beta]); XCTAssertNotEqual(alpha, beta)
        state.cancel()
    }

    @MainActor func testCallerCancellationLeavesLoadingIdleAndAllowsRetry() async throws {
        try commit("One")
        let state = GitHistoryState(service: GitService())
        var entered = false, release: CheckedContinuation<Void, Never>?
        state.didRead = { _ in entered = true; await withCheckedContinuation { release = $0 } }
        let read = Task { await state.reload(in: root.path, query: GitHistoryQuery()) }
        try await waitUntil { entered }
        read.cancel(); release?.resume()
        let accepted = await read.value
        XCTAssertFalse(accepted); XCTAssertFalse(state.reading.loading)
        state.didRead = nil
        let retry = await state.reload(in: root.path, query: GitHistoryQuery())
        XCTAssertTrue(retry); XCTAssertEqual(state.reading.commits.count, 1)
    }

    @MainActor func testResetReleasesRowsAndRetiresACompletedRead() async throws {
        try commit("One")
        let state = GitHistoryState(service: GitService())
        _ = await state.reload(in: root.path, query: GitHistoryQuery(message: "One"))
        var release: CheckedContinuation<Void, Never>?
        state.didRead = { _ in await withCheckedContinuation { release = $0 } }
        let read = Task { await state.reload(in: root.path, query: GitHistoryQuery(message: "One")) }
        try await waitUntil { release != nil }
        state.reset()
        XCTAssertEqual(state.reading, GitHistoryState.Reading())
        release?.resume()
        let accepted = await read.value
        XCTAssertFalse(accepted); XCTAssertEqual(state.reading, GitHistoryState.Reading())
    }

    @MainActor func testQuietRefreshKeepsItsCursorAndBlocksPagingUntilPublication() async throws {
        for i in 0..<52 { try commit("Change \(i)") }
        let state = GitHistoryState(service: GitService())
        _ = await state.reload(in: root.path, query: .init())
        let before = state.reading
        XCTAssertNotNil(before.next)
        var release: CheckedContinuation<Void, Never>?
        state.didRead = { _ in
            // Only hold the refresh, so an incorrectly admitted page fails
            // assertions instead of parking on a second continuation.
            if release == nil { await withCheckedContinuation { release = $0 } }
        }
        let refresh = Task { await state.reload(in: root.path, query: .init(), preservingCount: true) }
        try await waitUntil { release != nil }
        XCTAssertTrue(state.reading == before, "A background read preserves rows, cursor and visible flags")
        let pagedDuringRefresh = await state.loadMore()
        XCTAssertFalse(pagedDuringRefresh, "A quiet refresh still owns the in-flight read")
        XCTAssertTrue(state.reading == before)
        release?.resume()
        let accepted = await refresh.value
        XCTAssertTrue(accepted); XCTAssertFalse(state.reading.loading)
        XCTAssertEqual(state.reading.commits, before.commits)
        state.didRead = nil
        let pagedAfterRefresh = await state.loadMore()
        XCTAssertTrue(pagedAfterRefresh); XCTAssertEqual(state.reading.commits.count, 52)
        XCTAssertNil(state.reading.next)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(30))
        while !condition() {
            guard ContinuousClock.now < end else { throw NSError(domain: "HistoryQueryWait", code: 1) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
