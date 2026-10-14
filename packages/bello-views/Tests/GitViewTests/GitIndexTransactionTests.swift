import XCTest
@testable import GitView

final class GitIndexTransactionTests: XCTestCase {
    func testStageAndUnstageOneHunkPreserveOtherHunksAndWorktree() async throws {
        let repo = try HunkFixture(); defer { repo.remove() }
        let service = GitService()
        let review = try await service.patchReview(in: repo.root.path, path: repo.path, staged: false)
        XCTAssertEqual(review.patch.hunks.count, 2)
        let worktree = try repo.bytes(repo.path)
        try await service.applyHunk(0, from: review)
        XCTAssertEqual(try repo.git(["show", ":" + repo.path]), repo.first)
        XCTAssertEqual(try repo.bytes(repo.path), worktree)
        let staged = try await service.patchReview(in: repo.root.path, path: repo.path, staged: true)
        try await service.applyHunk(0, from: staged)
        XCTAssertEqual(try repo.git(["show", ":" + repo.path]), repo.base)
        XCTAssertEqual(try repo.bytes(repo.path), worktree)
    }
    func testMixedStagingAndReverseSecondHunk() async throws {
        let repo = try HunkFixture(); defer { repo.remove() }
        try repo.first.write(to: repo.root.appendingPathComponent(repo.path)); try repo.git(["add", "--", repo.path])
        try repo.both.write(to: repo.root.appendingPathComponent(repo.path))
        let service = GitService(), worktree = try repo.bytes(repo.path)
        let pending = try await service.patchReview(in: repo.root.path, path: repo.path, staged: false)
        XCTAssertEqual(pending.patch.hunks.count, 1)
        try await service.applyHunk(0, from: pending)
        XCTAssertEqual(try repo.git(["show", ":" + repo.path]), repo.both)
        let staged = try await service.patchReview(in: repo.root.path, path: repo.path, staged: true)
        XCTAssertEqual(staged.patch.hunks.count, 2)
        try await service.applyHunk(1, from: staged)
        XCTAssertEqual(try repo.git(["show", ":" + repo.path]), repo.first)
        XCTAssertEqual(try repo.bytes(repo.path), worktree)
    }

    func testConcurrentUnrelatedStagingIsNeverOverwritten() async throws {
        let repo = try HunkFixture(); defer { repo.remove() }
        let service = GitService(), review = try await service.patchReview(in: repo.root.path, path: repo.path, staged: false)
        let other = Data("staged elsewhere\n".utf8)
        try other.write(to: repo.root.appendingPathComponent("other.txt")); try repo.git(["add", "other.txt"])
        let index = try repo.git(["ls-files", "--stage", "-z"]), tree = try repo.git(["write-tree"])
        await refusal { try await service.applyHunk(0, from: review) }
        XCTAssertEqual(try repo.git(["ls-files", "--stage", "-z"]), index)
        XCTAssertEqual(try repo.git(["write-tree"]), tree)
        XCTAssertEqual(try repo.git(["show", ":other.txt"]), other)
        XCTAssertEqual(try repo.bytes(repo.path), repo.both)
    }

    func testWorktreeChangeSinceReviewRefusesWithoutTouchingIndex() async throws {
        let repo = try HunkFixture(); defer { repo.remove() }
        let service = GitService(), review = try await service.patchReview(in: repo.root.path, path: repo.path, staged: false)
        let changed = Data("newer work\n".utf8); try changed.write(to: repo.root.appendingPathComponent(repo.path))
        await refusal { try await service.applyHunk(0, from: review) }
        XCTAssertEqual(try repo.git(["show", ":" + repo.path]), repo.base)
        XCTAssertEqual(try repo.bytes(repo.path), changed)
    }

    func testLockFailureLeavesSomeoneElsesLockAndIndexAlone() async throws {
        let repo = try HunkFixture(); defer { repo.remove() }
        let service = GitService(), review = try await service.patchReview(in: repo.root.path, path: repo.path, staged: false)
        let lock = repo.root.appendingPathComponent(".git/index.lock"), marker = Data("owned by fixture\n".utf8)
        try marker.write(to: lock)
        await refusal { try await service.applyHunk(0, from: review) }
        XCTAssertEqual(try Data(contentsOf: lock), marker)
        XCTAssertEqual(try repo.git(["show", ":" + repo.path]), repo.base)
    }

    func testRealGitWriterCannotEnterWhileTransactionOwnsLock() throws {
        let repo = try HunkFixture(); defer { repo.remove() }
        let snapshot = try GitIndexSnapshot.read(at: repo.root.appendingPathComponent(".git/index").path)
        let transaction = try GitIndexTransaction(snapshot); defer { transaction.finish() }
        try transaction.validate()
        XCTAssertThrowsError(try repo.git(["add", "--", repo.path]))
        XCTAssertEqual(try repo.git(["show", ":" + repo.path]), repo.base)
        XCTAssertEqual(try repo.bytes(repo.path), repo.both)
    }

    func testDuplicateActivationConsumesTheReviewedIndexOnlyOnce() async throws {
        let repo = try HunkFixture(); defer { repo.remove() }
        let service = GitService(), review = try await service.patchReview(in: repo.root.path, path: repo.path, staged: false)
        async let a: Bool = Self.attempt { try await service.applyHunk(0, from: review) }
        async let b: Bool = Self.attempt { try await service.applyHunk(0, from: review) }
        let results = await [a, b]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertEqual(try repo.git(["show", ":" + repo.path]), repo.first)
        XCTAssertEqual(try repo.bytes(repo.path), repo.both)
    }

    func testUnusualLiteralPathsCRLFAndNoFinalNewline() async throws {
        for path in ["-review.txt", ":(glob)*.txt", "quote\" tab\tline\n雪.txt", "file,with,[brackets].txt"] {
            let repo = try HunkFixture(path: path, crlf: true, newline: false); defer { repo.remove() }
            let service = GitService(), review = try await service.patchReview(in: repo.root.path, path: path, staged: false)
            try await service.applyHunk(0, from: review)
            XCTAssertEqual(try repo.git(["show", ":" + path]), repo.first, path)
            XCTAssertEqual(try repo.bytes(path), repo.both, path)
        }
    }

    func testUnsupportedKindsAndIncompleteDisplayNeverOfferActions() async throws {
        let repo = try HunkFixture(); defer { repo.remove() }
        let service = GitService(), file = repo.root.appendingPathComponent(repo.path)
        try repo.git(["mv", "--", repo.path, "renamed.txt"])
        await refusal { _ = try await service.patchReview(in: repo.root.path, path: "renamed.txt", staged: true) }
        try repo.git(["reset", "--hard", "HEAD"])
        try Data([0, 1, 2]).write(to: file)
        do {
            _ = try await service.patchReview(in: repo.root.path, path: repo.path, staged: false)
            XCTFail("Binary files require whole-file staging")
        } catch { XCTAssertTrue(error.localizedDescription.contains("binary")) }
        try repo.both.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        await refusal { _ = try await service.patchReview(in: repo.root.path, path: repo.path, staged: false) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try FileManager.default.removeItem(at: file)
        await refusal { _ = try await service.patchReview(in: repo.root.path, path: repo.path, staged: false) }
        try Data("added\n".utf8).write(to: repo.root.appendingPathComponent("new.txt")); try repo.git(["add", "new.txt"])
        await refusal { _ = try await service.patchReview(in: repo.root.path, path: "new.txt", staged: true) }
        try Data((0...21_000).map { "new line \($0)\n" }.joined().utf8).write(to: file)
        await refusal { _ = try await service.patchReview(in: repo.root.path, path: repo.path, staged: false) }
    }


    func testUnequalHunkCountsUseExactForwardAndReverseCoordinates() async throws {
        let repo = try HunkFixture(); defer { repo.remove() }
        let first = String(decoding: repo.base, as: UTF8.self).replacingOccurrences(of: "line 3\n", with: "line 3\ninsert one\ninsert two\n")
        let both = first.replacingOccurrences(of: "line 30\nline 31\n", with: "last edit\n")
        try Data(both.utf8).write(to: repo.root.appendingPathComponent(repo.path))
        let service = GitService(), review = try await service.patchReview(in: repo.root.path, path: repo.path, staged: false)
        XCTAssertEqual(review.patch.hunks.count, 2)
        try await service.applyHunk(1, from: review)
        XCTAssertEqual(try repo.git(["show", ":" + repo.path]), Data(String(decoding: repo.base, as: UTF8.self).replacingOccurrences(of: "line 30\nline 31\n", with: "last edit\n").utf8))
        try repo.git(["add", "--", repo.path])
        let staged = try await service.patchReview(in: repo.root.path, path: repo.path, staged: true)
        try await service.applyHunk(1, from: staged)
        XCTAssertEqual(try repo.git(["show", ":" + repo.path]), Data(first.utf8))
        XCTAssertEqual(try repo.bytes(repo.path), Data(both.utf8))
    }

    func testPublicationRevalidatesAfterWritingLockAndLeavesReplacementIndex() throws {
        let repo = try HunkFixture(); defer { repo.remove() }
        let path = repo.root.appendingPathComponent(".git/index").path
        let snapshot = try GitIndexSnapshot.read(at: path)
        try repo.git(["add", "--", repo.path]); let newer = try GitIndexSnapshot.read(at: path)
        try snapshot.bytes.write(to: URL(fileURLWithPath: path))
        let transaction = try GitIndexTransaction(snapshot); defer { transaction.finish() }
        try transaction.validate()
        XCTAssertThrowsError(try transaction.publish(snapshot.bytes, beforePublication: {
            try newer.bytes.write(to: URL(fileURLWithPath: path), options: .atomic)
        }))
        XCTAssertEqual(try repo.git(["show", ":" + repo.path]), repo.both)
    }

    func testReplacedLockIsNotPublishedOrRemoved() throws {
        let repo = try HunkFixture(); defer { repo.remove() }
        let snapshot = try GitIndexSnapshot.read(at: repo.root.appendingPathComponent(".git/index").path)
        let transaction = try GitIndexTransaction(snapshot)
        let lock = URL(fileURLWithPath: snapshot.path + ".lock"), marker = Data("another owner\n".utf8)
        try FileManager.default.removeItem(at: lock); try marker.write(to: lock)
        XCTAssertThrowsError(try transaction.publish(snapshot.bytes))
        transaction.finish()
        XCTAssertEqual(try Data(contentsOf: lock), marker)
        XCTAssertEqual(try repo.git(["show", ":" + repo.path]), repo.base)
    }

    func testCancellationBeforePublicationLeavesOriginalIndexAndReleasesLock() async throws {
        let repo = try HunkFixture(); defer { repo.remove() }
        let snapshot = try GitIndexSnapshot.read(at: repo.root.appendingPathComponent(".git/index").path)
        let task = Task {
            let transaction = try GitIndexTransaction(snapshot); defer { transaction.finish() }
            try transaction.publish(snapshot.bytes) { withUnsafeCurrentTask { $0?.cancel() } }
        }
        do { try await task.value; XCTFail("Cancellation must prevent publication") } catch is CancellationError { }
        XCTAssertEqual(try GitIndexSnapshot.read(at: snapshot.path).bytes, snapshot.bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path + ".lock"))
    }

    func testSharedPermissionsAndSplitIndexPreserveUnrelatedStaging() async throws {
        let repo = try HunkFixture(); defer { repo.remove() }
        let other = Data("unrelated staged text\n".utf8)
        try other.write(to: repo.root.appendingPathComponent("other.txt")); try repo.git(["add", "other.txt"])
        try repo.git(["update-index", "--split-index"])
        let path = repo.root.appendingPathComponent(".git/index").path
        try FileManager.default.setAttributes([.posixPermissions: 0o660], ofItemAtPath: path)
        let service = GitService(), review = try await service.patchReview(in: repo.root.path, path: repo.path, staged: false)
        try await service.applyHunk(0, from: review)
        XCTAssertEqual(try repo.git(["show", ":" + repo.path]), repo.first)
        XCTAssertEqual(try repo.git(["show", ":other.txt"]), other)
        XCTAssertEqual(try GitIndexSnapshot.read(at: path).permissions, 0o660)
    }

    func testDiffDriversAndLateCleanFilterCannotExecuteOrChangeWorktree() async throws {
        let repo = try HunkFixture(); defer { repo.remove() }
        let marker = repo.root.appendingPathComponent("executed")
        let driver = repo.root.appendingPathComponent(".git/fixture-driver")
        try Data("#!/bin/sh\ntouch executed\ncat\n".utf8).write(to: driver)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: driver.path)
        try repo.git(["config", "diff.external", driver.path])
        try repo.git(["config", "diff.fixture.textconv", driver.path])
        try Data("review.txt diff=fixture\n".utf8).write(to: repo.root.appendingPathComponent(".gitattributes"))
        let service = GitService()
        await refusal { _ = try await service.patchReview(in: repo.root.path, path: repo.path, staged: false) }
        try Data("review.txt -diff\n".utf8).write(to: repo.root.appendingPathComponent(".gitattributes"))
        await refusal { _ = try await service.patchReview(in: repo.root.path, path: repo.path, staged: false) }
        try Data().write(to: repo.root.appendingPathComponent(".gitattributes"))
        let review = try await service.patchReview(in: repo.root.path, path: repo.path, staged: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        try repo.git(["config", "filter.fixture.clean", driver.path])
        try Data("review.txt filter=fixture\n".utf8).write(to: repo.root.appendingPathComponent(".gitattributes"))
        await refusal { try await service.applyHunk(0, from: review) }
        await refusal { _ = try await service.patchReview(in: repo.root.path, path: repo.path, staged: false) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try repo.bytes(repo.path), repo.both)
        XCTAssertEqual(try repo.git(["show", ":" + repo.path]), repo.base)
    }

    func testSymlinkSubmoduleAndUnmergedEntryAreRejected() async throws {
        let repo = try HunkFixture(); defer { repo.remove() }
        let service = GitService(), file = repo.root.appendingPathComponent(repo.path)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: repo.root.appendingPathComponent("other.txt"))
        await refusal { _ = try await service.patchReview(in: repo.root.path, path: repo.path, staged: false) }
        try FileManager.default.removeItem(at: file); try repo.both.write(to: file)
        let head = String(decoding: try repo.git(["rev-parse", "HEAD"]), as: UTF8.self).trimmingCharacters(in: .newlines)
        try repo.git(["update-index", "--cacheinfo", "160000", head, repo.path])
        await refusal { _ = try await service.patchReview(in: repo.root.path, path: repo.path, staged: true) }
        try repo.git(["reset", "-q", "HEAD", "--", repo.path])
        try repo.git(["checkout", "-qb", "side"])
        try Data("side\n".utf8).write(to: file); try repo.git(["add", "--", repo.path]); try repo.git(["commit", "-qm", "Side"])
        try repo.git(["checkout", "-q", "main"])
        try Data("main\n".utf8).write(to: file); try repo.git(["add", "--", repo.path]); try repo.git(["commit", "-qm", "Main"])
        XCTAssertThrowsError(try repo.git(["merge", "--no-edit", "side"]))
        let index = try repo.git(["ls-files", "--stage", "-z"]), bytes = try repo.bytes(repo.path)
        await refusal { _ = try await service.patchReview(in: repo.root.path, path: repo.path, staged: false) }
        XCTAssertEqual(try repo.git(["ls-files", "--stage", "-z"]), index); XCTAssertEqual(try repo.bytes(repo.path), bytes)
    }


    func testReplacementBlobCannotStageUnreviewedContent() async throws {
        let repo = try HunkFixture(); defer { repo.remove() }
        let service = GitService(), review = try await service.patchReview(in: repo.root.path, path: repo.path, staged: false)
        let fake = Data(String(decoding: repo.base, as: UTF8.self).replacingOccurrences(of: "line 16", with: "unreviewed replacement").utf8)
        try fake.write(to: repo.root.appendingPathComponent("replacement"))
        let replacement = String(decoding: try repo.git(["hash-object", "-w", "--", "replacement"]), as: UTF8.self).trimmingCharacters(in: .newlines)
        let original = String(decoding: try repo.git(["rev-parse", ":" + repo.path]), as: UTF8.self).trimmingCharacters(in: .newlines)
        try repo.git(["replace", original, replacement])
        try await service.applyHunk(0, from: review)
        XCTAssertEqual(try repo.git(["--no-replace-objects", "show", ":" + repo.path]), repo.first)
        XCTAssertEqual(try repo.bytes(repo.path), repo.both)
    }

    private static func attempt(_ work: @Sendable () async throws -> Void) async -> Bool { do { try await work(); return true } catch { return false } }
    private func refusal(_ work: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await work(); XCTFail("The unsafe action should have been refused", file: file, line: line) } catch { }
    }

}

final class HunkFixture {
    let root: URL
    let path: String
    let base: Data, first: Data, both: Data
    init(path: String = "review.txt", crlf: Bool = false, newline: Bool = true) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bello-hunks-" + UUID().uuidString)
        self.path = path
        let end = crlf ? "\r\n" : "\n"
        func bytes(_ changes: [Int: String]) -> Data {
            Data(((1...32).map { changes[$0] ?? "line \($0)" }.joined(separator: end) + (newline ? end : "")).utf8)
        }
        base = bytes([:]); first = bytes([3: "reviewed change"]); both = bytes([3: "reviewed change", 30: "later change"])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try git(["init", "-q", "-b", "main"])
        for (key, value) in [("user.name", "Hunk Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("core.autocrlf", "false"), ("core.attributesFile", "/dev/null"), ("credential.helper", ""), ("core.filemode", "true")] { _ = try git(["config", key, value]) }
        try base.write(to: root.appendingPathComponent(path))
        try Data("untouched\n".utf8).write(to: root.appendingPathComponent("other.txt"))
        _ = try git(["add", "."]); _ = try git(["commit", "-qm", "Fixture base"])
        try both.write(to: root.appendingPathComponent(path))
    }
    func bytes(_ path: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(path)) }
    func remove() { try? FileManager.default.removeItem(at: root) }
    @discardableResult func git(_ args: [String]) throws -> Data {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = root; p.arguments = ["-c", "core.fsmonitor=false"] + args
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0", "LANG": "C"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        try p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw GitFailure(message: "Fixture git failed: \(args)") }
        return data
    }
}
