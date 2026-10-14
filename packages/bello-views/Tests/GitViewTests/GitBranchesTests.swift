import XCTest
@testable import GitView

final class GitBranchesTests: XCTestCase {
    func testUnfamiliarTrackingStatusNeverClaimsTheBranchIsInSync() {
        for status in ["[future status]", "[ahead many]", "[ahead -1]", "[ahead 1, ahead 2]", "[]"] {
            let tracking = GitBranchTracking(upstream: "origin/topic", description: status)
            XCTAssertNil(tracking.ahead); XCTAssertNil(tracking.behind); XCTAssertFalse(tracking.gone)
        }
        let ahead = GitBranchTracking(upstream: "origin/topic", description: "[ahead 2]")
        XCTAssertEqual(ahead.ahead, 2); XCTAssertEqual(ahead.behind, 0)
    }

    func testCatalogCachesTrackingCountsAndHandlesGoneAndUntrackedBranches() async throws {
        let f = try BranchFixture(); defer { f.close() }
        _ = try await f.divergedBranch(); try f.origin(branch: "topic")
        try f.git(["branch", "--set-upstream-to=origin/topic", "main"])
        try f.git(["branch", "--set-upstream-to=origin/topic", "topic"])
        try f.git(["branch", "untracked"])
        try f.git(["branch", "behind"]); try f.git(["branch", "--set-upstream-to=origin/topic", "behind"])
        try f.write("one.txt", "one\n"); try f.commit("Local one")
        try f.write("two.txt", "two\n"); try f.commit("Local two")
        let before = try f.snapshot(), catalog = try await f.service.branchCatalog(in: f.path)
        let main = try XCTUnwrap(catalog.branches.first { $0.name == "main" })
        XCTAssertEqual(main.upstream, "refs/remotes/origin/topic")
        XCTAssertEqual(main.tracking?.upstream, "origin/topic")
        XCTAssertEqual(main.tracking?.ahead, 2); XCTAssertEqual(main.tracking?.behind, 1)
        XCTAssertEqual(main.tracking?.gone, false)
        XCTAssertEqual(catalog.branches.first { $0.name == "topic" }?.tracking?.ahead, 0)
        XCTAssertEqual(catalog.branches.first { $0.name == "topic" }?.tracking?.behind, 0)
        XCTAssertEqual(catalog.branches.first { $0.name == "behind" }?.tracking?.behind, 1)
        XCTAssertNil(catalog.branches.first { $0.name == "untracked" }?.tracking)
        XCTAssertNil(catalog.branches.first { $0.name == "origin/topic" }?.tracking)
        XCTAssertEqual(try f.snapshot(), before, "Catalog reads preserve index and worktree bytes")
        try f.git(["update-ref", "-d", "refs/remotes/origin/topic"])
        let next = try await f.service.branchCatalog(in: f.path)
        XCTAssertEqual(next.branches.first { $0.name == "main" }?.tracking?.gone, true)
        XCTAssertEqual(main.tracking?.ahead, 2, "The displayed catalog keeps its own metadata snapshot")
        XCTAssertEqual(main.tracking?.gone, false)
        XCTAssertEqual(try f.snapshot(), before)
    }

    func testCatalogListsLocalRemoteCurrentAndRecent() async throws {
        let f = try BranchFixture(); defer { f.close() }
        try f.git(["switch", "-c", "topic"]); try f.git(["switch", "main"])
        try f.origin(branch: "topic")
        let catalog = try await f.service.branchCatalog(in: f.path)
        XCTAssertEqual(catalog.branches.filter(\.current).map(\.name), ["main"])
        XCTAssertEqual(catalog.branches.first { $0.name == "origin/topic" }?.remote, "origin")
        XCTAssertTrue(catalog.recent.contains("refs/heads/topic"))
        XCTAssertFalse(catalog.branches.contains { $0.name == "origin/HEAD" })
    }
    func testUnmergedDeletionRequiresExplicitSecondConsent() async throws {
        let f = try BranchFixture(); defer { f.close() }
        let branch = try await f.divergedBranch()
        let review = try await f.service.reviewBranchDeletion(branch, in: f.path)
        XCTAssertEqual(review.unmergedCount, 1)
        XCTAssertEqual(review.commits.first?.subject, "Topic only")
        let before = try f.snapshot()
        do { try await f.service.deleteBranch(review, in: f.path); XCTFail("Unmerged branch must be guarded") } catch {}
        XCTAssertEqual(try f.git(["rev-parse", branch.ref]).trimmed, branch.oid)
        XCTAssertEqual(try f.snapshot(), before)
        try await f.service.deleteBranch(review, allowUnmerged: true, in: f.path)
        XCTAssertEqual(try f.gitStatus(["show-ref", "--verify", branch.ref]), 128)
        XCTAssertEqual(try f.snapshot(), before)
    }
    func testCannotDeleteCurrentOrLinkedWorktreeBranch() async throws {
        let f = try BranchFixture(); defer { f.close() }
        let current = try await f.branch("main")
        do { _ = try await f.service.reviewBranchDeletion(current, in: f.path); XCTFail("current") } catch {}
        try f.git(["branch", "linked"])
        let branch = try await f.branch("linked")
        try f.git(["worktree", "add", f.folder.appendingPathComponent("linked").path, "linked"])
        do { _ = try await f.service.reviewBranchDeletion(branch, in: f.path); XCTFail("linked worktree") } catch {}
        XCTAssertEqual(try f.git(["rev-parse", branch.ref]).trimmed, branch.oid)
    }
    func testCannotDeleteBranchReservedByRebaseInAnyWorktree() async throws {
        for linked in [false, true] { try await checkOperationReservation("rebase", linked: linked) }
    }
    func testCannotDeleteBranchReservedByBisectInAnyWorktree() async throws {
        for linked in [false, true] { try await checkOperationReservation("bisect", linked: linked) }
    }
    private func checkOperationReservation(_ operation: String, linked: Bool) async throws {
        let f = try BranchFixture(); defer { f.close() }
        _ = try await f.divergedBranch()
        if operation == "rebase" {
            try f.write("f.txt", "main conflict\n"); try f.commit("Main conflict")
        } else {
            try f.git(["switch", "topic"]); try f.write("f.txt", "second topic\n")
            try f.commit("Second topic"); try f.git(["switch", "main"])
        }
        let worktree = linked ? f.folder.appendingPathComponent("linked").path : f.path
        if linked { try f.git(["worktree", "add", worktree, "topic"]) }
        else { try f.git(["switch", "topic"]) }
        if operation == "rebase" {
            XCTAssertEqual(try f.gitStatus(["-C", worktree, "rebase", "main"]), 1, "The conflicting rebase must pause")
        } else { try f.git(["-C", worktree, "bisect", "start", "topic", "main"]) }
        XCTAssertNotEqual(try f.gitStatus(["-C", worktree, "symbolic-ref", "HEAD"]), 0)
        let branch = try await f.branch("topic"), review = try await f.service.reviewBranchDeletion(branch, in: f.path)
        XCTAssertGreaterThan(review.unmergedCount, 0)
        let before = try f.snapshot(), index = try f.git(["-C", worktree, "ls-files", "--stage"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: worktree + "/f.txt"))
        let reservation = try f.git(["-C", worktree, "rev-parse", "--path-format=absolute", "--git-path",
                                     operation == "rebase" ? "rebase-merge/head-name" : "BISECT_START"]).trimmed
        let reserved = try Data(contentsOf: URL(fileURLWithPath: reservation))
        XCTAssertNotEqual(try f.gitStatus(["branch", "-D", "topic"]), 0, "Native Git recognizes this operation reservation")
        do {
            try await f.service.deleteBranch(review, allowUnmerged: true, in: f.path)
            XCTFail("Even explicit unmerged consent cannot remove a branch reserved by \(operation)")
        } catch {}
        XCTAssertEqual(try? f.git(["rev-parse", branch.ref]).trimmed, branch.oid)
        XCTAssertEqual(try f.snapshot(), before)
        XCTAssertEqual(try f.git(["-C", worktree, "ls-files", "--stage"]), index)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: worktree + "/f.txt")), bytes)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: reservation)), reserved)
    }
    func testLinkedWorktreeSwitchAtPublicationCannotDeleteItsNewCurrentBranch() async throws {
        let f = try BranchFixture(); defer { f.close() }
        try f.git(["branch", "target"]); try f.git(["branch", "other"])
        let linked = f.folder.appendingPathComponent("linked").path
        try f.git(["worktree", "add", linked, "other"])
        let branch = try await f.branch("target"), review = try await f.service.reviewBranchDeletion(branch, in: f.path)
        let service = f.service
        do {
            try await service.deleteReviewedBranch(review, allowUnmerged: false, in: f.path, beforeDeletion: {
                try await service.checkout("target", in: linked)
            })
            XCTFail("Native deletion must protect every registered worktree HEAD")
        } catch {}
        XCTAssertEqual(try f.git(["rev-parse", "target"]).trimmed, branch.oid)
        XCTAssertEqual(try f.git(["-C", linked, "symbolic-ref", "HEAD"]).trimmed, branch.ref)
        XCTAssertEqual(try f.read("f.txt"), "base\n")
    }

    func testMovedTipAndChangedHEADRetireDeletionReview() async throws {
        let f = try BranchFixture(); defer { f.close() }
        let branch = try await f.divergedBranch()
        let review = try await f.service.reviewBranchDeletion(branch, in: f.path)
        try f.git(["switch", "topic"])
        do { try await f.service.deleteBranch(review, allowUnmerged: true, in: f.path); XCTFail("now current") } catch {}
        try f.write("f.txt", "new topic\n"); try f.commit("Later topic"); try f.git(["switch", "main"])
        let tip = try f.git(["rev-parse", "topic"])
        do { try await f.service.deleteBranch(review, allowUnmerged: true, in: f.path); XCTFail("moved") } catch {}
        XCTAssertEqual(try f.git(["rev-parse", "topic"]), tip)
    }
    func testHEADMovingBeforeNativeDeletionCannotReuseMergedConsent() async throws {
        let f = try BranchFixture(); defer { f.close() }
        try f.git(["branch", "base"])
        let branch = try await f.divergedBranch()
        try f.git(["merge", "--ff-only", "topic"])
        let review = try await f.service.reviewBranchDeletion(branch, in: f.path)
        XCTAssertEqual(review.unmergedCount, 0)
        let service = f.service, root = f.path
        do {
            try await service.deleteReviewedBranch(review, allowUnmerged: false, in: root, beforeDeletion: {
                try await service.checkout("base", in: root)
            })
            XCTFail("A merged review must stay bound to the reviewed HEAD")
        } catch {}
        XCTAssertEqual(try f.git(["rev-parse", branch.ref]).trimmed, branch.oid)
        XCTAssertEqual(try f.read("f.txt"), "base\n")
    }
    func testDeletedBranchDoesNotLeaveTrackingConfigurationForRecreation() async throws {
        let f = try BranchFixture(); defer { f.close() }
        try f.git(["branch", "old"])
        try f.git(["config", "branch.old.remote", "previous-origin"])
        try f.git(["config", "branch.old.merge", "refs/heads/old-destination"])
        try f.git(["config", "branch.main.description", "Keep unrelated configuration"])
        let branch = try await f.branch("old"), review = try await f.service.reviewBranchDeletion(branch, in: f.path)
        try await f.service.deleteBranch(review, in: f.path)
        try f.git(["branch", "old"])
        XCTAssertEqual(try f.gitStatus(["config", "--local", "--get", "branch.old.remote"]), 1)
        XCTAssertEqual(try f.gitStatus(["config", "--local", "--get", "branch.old.merge"]), 1)
        XCTAssertEqual(try f.git(["config", "branch.main.description"]).trimmed, "Keep unrelated configuration")
        XCTAssertEqual(try f.git(["rev-parse", "old"]).trimmed, branch.oid)
    }
    func testUnbornRepositoryCanListAndCheckOutRemoteTrackingBranch() async throws {
        let f = try BranchFixture(); defer { f.close() }
        try f.origin(branch: "main")
        let empty = f.folder.appendingPathComponent("empty").path
        try f.git(["init", "--template=", "-b", "initial", empty])
        for (key, value) in [("user.name", "Branch Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false"),
                             ("tag.gpgsign", "false"), ("credential.helper", ""), ("core.fsmonitor", "false"),
                             ("core.hooksPath", f.folder.appendingPathComponent("empty-hooks").path), ("core.excludesFile", "/dev/null")] {
            try f.git(["-C", empty, "config", key, value])
        }
        try f.git(["-C", empty, "remote", "add", "origin", f.folder.appendingPathComponent("origin.git").path])
        try f.git(["-C", empty, "fetch", "origin"])
        let catalog = try await f.service.branchCatalog(in: empty)
        XCTAssertEqual(catalog.head.ref, "refs/heads/initial")
        let remote = try XCTUnwrap(catalog.branches.first { $0.name == "origin/main" })
        _ = try await f.service.checkoutBranch(remote, from: catalog.head, newName: "tracking", in: empty)
        XCTAssertEqual(try f.git(["-C", empty, "symbolic-ref", "HEAD"]).trimmed, "refs/heads/tracking")
        XCTAssertEqual(try f.git(["-C", empty, "rev-parse", "--symbolic-full-name", "@{upstream}"]).trimmed, remote.ref)
        XCTAssertEqual(try String(contentsOfFile: empty + "/f.txt", encoding: .utf8), "base\n")
    }
    func testConfigCleanupMatchesOnlyTheExactDottedBranchName() async throws {
        let f = try BranchFixture(); defer { f.close() }
        try f.git(["branch", "release/1.0"])
        try f.git(["config", "branch.release/1.0.1.remote", "keep-other-branch"])
        let branch = try await f.branch("release/1.0"), review = try await f.service.reviewBranchDeletion(branch, in: f.path)
        let result = try await f.service.deleteBranch(review, in: f.path)
        XCTAssertEqual(result, "Deleted branch release/1.0.")
        XCTAssertEqual(try f.git(["config", "branch.release/1.0.1.remote"]).trimmed, "keep-other-branch")
        XCTAssertEqual(try f.git(["branch", "--list", branch.name]), "")
    }
    func testMergedDeletionAndRenameNeverOverwriteExistingBranch() async throws {
        let f = try BranchFixture(); defer { f.close() }
        try f.git(["branch", "old"])
        let old = try await f.branch("old")
        try await f.service.renameBranch(old, to: "renamed", in: f.path)
        let renamed = try await f.branch("renamed")
        do { try await f.service.renameBranch(renamed, to: "main", in: f.path); XCTFail("existing") } catch {}
        let review = try await f.service.reviewBranchDeletion(renamed, in: f.path)
        XCTAssertEqual(review.unmergedCount, 0)
        let result = try await f.service.deleteBranch(review, in: f.path)
        XCTAssertEqual(result, "Deleted branch renamed.")
        XCTAssertEqual(try f.git(["branch", "--list", "renamed"]), "")
    }
    func testCheckoutRefusalPreservesIndexWorktreeThenExplicitRecoveryStashes() async throws {
        let f = try BranchFixture(); defer { f.close() }
        let branch = try await f.divergedBranch(), head = try await f.service.branchHead(in: f.path)
        try f.write("f.txt", "staged\n"); try f.git(["add", "f.txt"]); try f.write("f.txt", "working\n"); try f.write("new.txt", "untracked\n")
        let before = try f.snapshot()
        guard case .needsStash(let blocked) = try await f.service.checkoutBranch(branch, from: head, in: f.path) else { return XCTFail("offer recovery") }
        XCTAssertTrue(blocked.reason.contains("would be overwritten"))
        XCTAssertEqual(try f.snapshot(), before)
        guard case .switched = try await f.service.stashAndCheckout(blocked, in: f.path) else { return XCTFail("checkout after explicit stash") }
        XCTAssertEqual(try f.read("f.txt"), "topic\n")
        XCTAssertEqual(try f.git(["show", "stash@{0}:f.txt"]), "working\n")
        XCTAssertEqual(try f.git(["show", "stash@{0}^2:f.txt"]), "staged\n")
        XCTAssertEqual(try f.git(["show", "stash@{0}^3:new.txt"]), "untracked\n")
    }
    func testDirtyCheckoutGuardRejectsEditsMadeAfterTheRecoveryOffer() async throws {
        let f = try BranchFixture(); defer { f.close() }
        let branch = try await f.divergedBranch(), head = try await f.service.branchHead(in: f.path)
        try f.write("f.txt", "reviewed work\n")
        guard case .needsStash(let blocked) = try await f.service.checkoutBranch(branch, from: head, in: f.path) else { return XCTFail("blocked") }
        try f.write("f.txt", "later work not reviewed\n")
        let before = try f.snapshot()
        do { _ = try await f.service.stashAndCheckout(blocked, in: f.path); XCTFail("Changed dirty state must retire the recovery offer") } catch {}
        XCTAssertEqual(try f.snapshot(), before)
        let stashes = try await f.service.stashRecords(in: f.path)
        XCTAssertTrue(stashes.isEmpty)
    }
    func testCheckoutCannotOverwriteIgnoredLocalBytes() async throws {
        let f = try BranchFixture(); defer { f.close() }
        try f.write(".gitignore", "secret.txt\n"); try f.commit("Ignore file")
        try f.git(["switch", "-c", "target"]); try f.write("secret.txt", "target\n"); try f.git(["add", "-f", "secret.txt"]); try f.commit("Target file"); try f.git(["switch", "main"])
        try f.write("secret.txt", "local ignored bytes\n")
        let branch = try await f.branch("target"), head = try await f.service.branchHead(in: f.path)
        guard case .needsStash(let blocked) = try await f.service.checkoutBranch(branch, from: head, in: f.path) else { return XCTFail("Ignored bytes must be protected") }
        _ = try await f.service.stashAndCheckout(blocked, in: f.path)
        XCTAssertEqual(try f.read("secret.txt"), "local ignored bytes\n")
        XCTAssertEqual(try f.git(["symbolic-ref", "HEAD"]).trimmed, "refs/heads/main")
    }
    func testLegacyCheckoutAlsoProtectsIgnoredLocalBytes() async throws {
        let f = try BranchFixture(); defer { f.close() }
        try f.write(".gitignore", "secret.txt\n"); try f.commit("Ignore")
        try f.git(["switch", "-c", "target"]); try f.write("secret.txt", "committed\n"); try f.git(["add", "-f", "secret.txt"]); try f.commit("Target"); try f.git(["switch", "main"])
        try f.write("secret.txt", "local ignored bytes\n")
        do { try await f.service.checkout("target", in: f.path); XCTFail("Checkout must refuse ignored-file loss") } catch {}
        XCTAssertEqual(try f.read("secret.txt"), "local ignored bytes\n")
        XCTAssertEqual(try f.git(["symbolic-ref", "HEAD"]).trimmed, "refs/heads/main")
    }

    func testRemoteCheckoutCreatesTrackingBranchAndNewBranchUsesReviewedCommit() async throws {
        let f = try BranchFixture(); defer { f.close() }
        _ = try await f.divergedBranch(); try f.origin(branch: "topic")
        let remote = try await f.branch("origin/topic"), head = try await f.service.branchHead(in: f.path)
        _ = try await f.service.checkoutBranch(remote, from: head, newName: "tracking", in: f.path)
        XCTAssertEqual(try f.git(["rev-parse", "HEAD"]).trimmed, remote.oid)
        XCTAssertEqual(try f.git(["rev-parse", "--symbolic-full-name", "@{upstream}"]).trimmed, remote.ref)
        let tracking = try await f.branch("tracking"), nextHead = try await f.service.branchHead(in: f.path)
        _ = try await f.service.checkoutBranch(tracking, from: nextHead, newName: "copy", in: f.path)
        XCTAssertEqual(try f.git(["rev-parse", "copy"]).trimmed, remote.oid)
        XCTAssertEqual(try f.read("f.txt"), "topic\n")
    }
    func testComparisonHasBothDirectionsAndStableIDs() async throws {
        let f = try BranchFixture(); defer { f.close() }
        let branch = try await f.divergedBranch()
        try f.write("main.txt", "main\n"); try f.commit("Main only")
        let before = try f.snapshot(), comparison = try await f.service.compareBranch(branch, in: f.path)
        XCTAssertEqual(comparison.onlyCurrent.map(\.subject), ["Main only"])
        XCTAssertEqual(comparison.onlyTarget.map(\.subject), ["Topic only"])
        XCTAssertEqual(comparison.currentCount, 1); XCTAssertEqual(comparison.targetCount, 1)
        XCTAssertEqual(try f.snapshot(), before)
        try f.write("other.txt", "later\n"); try f.commit("Later")
        let pinned = try await f.service.compareBranch(branch, current: comparison.current, in: f.path)
        XCTAssertEqual(pinned.onlyCurrent.map(\.hash), comparison.onlyCurrent.map(\.hash))
    }
    func testHistoryHashSearchHonorsExplicitBranchEvenWithAllBranchesEnabled() async throws {
        let f = try BranchFixture(); defer { f.close() }
        let topic = try await f.divergedBranch(), before = try f.snapshot()
        let excluded = try await f.service.log(in: f.path, filter: GitLogFilter(allBranches: true, text: topic.oid, reference: "refs/heads/main"))
        XCTAssertTrue(excluded.isEmpty, "An explicit branch filter must also constrain hash matches")
        let included = try await f.service.log(in: f.path, filter: GitLogFilter(allBranches: true, text: topic.oid, reference: topic.ref))
        XCTAssertEqual(included.map(\.hash), [topic.oid])
        XCTAssertEqual(try f.snapshot(), before)
    }
}

final class BranchFixture {
    let folder: URL, root: URL
    let service = GitService()
    var path: String { root.path }
    init() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bello-branches-fixture-" + UUID().uuidString)
        root = folder.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "--template=", "-q", "-b", "main"])
        for (key, value) in [("user.name", "Branch Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false"), ("tag.gpgsign", "false"), ("credential.helper", ""), ("core.hooksPath", folder.appendingPathComponent("empty-hooks").path), ("core.fsmonitor", "false"), ("core.excludesFile", "/dev/null")] { try git(["config", key, value]) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty-hooks"), withIntermediateDirectories: true)
        try write("f.txt", "base\n"); try commit("Base")
    }
    func close() { try? FileManager.default.removeItem(at: folder) }
    @discardableResult func git(_ args: [String]) throws -> String {
        let (code, output) = try command(args)
        guard code == 0 else { throw NSError(domain: "Fixture Git: \(args.joined(separator: " ")) \(output)", code: Int(code)) }
        return output
    }
    func gitStatus(_ args: [String]) throws -> Int32 { try command(args).0 }
    private func command(_ args: [String]) throws -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args; p.currentDirectoryURL = root
        p.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        try p.run(); let bytes = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: bytes, as: UTF8.self))
    }
    func write(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(name)) }
    func read(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
    func commit(_ message: String) throws { try git(["add", "-A"]); try git(["commit", "-q", "-m", message]) }
    func branch(_ name: String) async throws -> GitBranchReference { let list = try await service.branchCatalog(in: path); return try XCTUnwrap(list.branches.first { $0.name == name }) }
    func divergedBranch() async throws -> GitBranchReference {
        try git(["switch", "-c", "topic"]); try write("f.txt", "topic\n"); try commit("Topic only"); try git(["switch", "main"])
        return try await branch("topic")
    }
    func snapshot() throws -> [String] { [try git(["rev-parse", "HEAD"]), try git(["ls-files", "--stage"]), try git(["diff", "--binary"]), try git(["diff", "--cached", "--binary"]), try read("f.txt")] }
    func origin(branch: String) throws {
        let bare = folder.appendingPathComponent("origin.git").path
        try git(["init", "--bare", "--template=", bare]); try git(["remote", "add", "origin", bare]); try git(["push", "origin", branch])
    }
}
private extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
