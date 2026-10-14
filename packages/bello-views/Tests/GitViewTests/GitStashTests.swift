import XCTest
@testable import GitView

final class GitStashTests: XCTestCase {
    func testNewStashOptionsKeepIndexAndIncludeUntrackedAndPreviewBoth() async throws {
        let f = try BranchFixture(); defer { f.close() }
        try f.write("f.txt", "staged\n"); try f.git(["add", "f.txt"]); try f.write("f.txt", "working\n"); try f.write("[new].txt", "untracked\n")
        _ = try await f.service.createStash(message: "Review work", includeUntracked: true, keepIndex: true, in: f.path)
        XCTAssertEqual(try f.read("f.txt"), "staged\n")
        XCTAssertEqual(try f.git(["show", ":f.txt"]), "staged\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("[new].txt").path))
        let records = try await f.service.stashRecords(in: f.path), stash = try XCTUnwrap(records.first)
        XCTAssertEqual(stash.message, "Review work"); XCTAssertEqual(stash.branch, "main")
        let files = try await f.service.stashFiles(stash, in: f.path)
        XCTAssertEqual(Set(files.map(\.path)), ["f.txt", "[new].txt"])
        let untracked = try XCTUnwrap(files.first { $0.untracked })
        let diff = try await f.service.stashDiff(stash, file: untracked, in: f.path)
        XCTAssertEqual(diff.first?.path, "[new].txt")
        XCTAssertTrue(diff.first?.hunks.flatMap(\.lines).contains { $0.text.contains("untracked") } == true)
    }
    func testUntrackedExcludedAndEmptyMessage() async throws {
        let f = try BranchFixture(); defer { f.close() }
        try f.write("f.txt", "work\n"); try f.write("keep.txt", "keep\n")
        _ = try await f.service.createStash(message: "", includeUntracked: false, keepIndex: false, in: f.path)
        XCTAssertEqual(try f.read("keep.txt"), "keep\n")
        XCTAssertEqual(try f.read("f.txt"), "base\n")
        let records = try await f.service.stashRecords(in: f.path)
        XCTAssertEqual(records.count, 1)
    }
    func testApplyRetainsStashAndPopRemovesOnlyReviewedEntry() async throws {
        let f = try BranchFixture(); defer { f.close() }
        try f.write("f.txt", "first\n"); _ = try await f.service.createStash(message: "First", includeUntracked: false, keepIndex: false, in: f.path)
        try f.write("second.txt", "second\n"); _ = try await f.service.createStash(message: "Second", includeUntracked: true, keepIndex: false, in: f.path)
        let records = try await f.service.stashRecords(in: f.path)
        let result = try await f.service.applyStash(records[1], pop: true, in: f.path)
        XCTAssertTrue(result.applied); XCTAssertTrue(result.removed)
        XCTAssertEqual(try f.read("f.txt"), "first\n")
        let remaining = try await f.service.stashRecords(in: f.path)
        XCTAssertEqual(remaining.map(\.oid), [records[0].oid])
        let applied = try await f.service.applyStash(remaining[0], in: f.path)
        XCTAssertTrue(applied.applied); XCTAssertFalse(applied.removed)
        XCTAssertEqual(try f.read("second.txt"), "second\n")
        let kept = try await f.service.stashRecords(in: f.path)
        XCTAssertEqual(kept.map(\.oid), remaining.map(\.oid))
    }
    func testConflictingApplyAndPopKeepStashAndShowConflict() async throws {
        for pop in [false, true] {
            let f = try BranchFixture(); defer { f.close() }
            try f.write("f.txt", "stashed\n"); _ = try await f.service.createStash(message: "Conflict", includeUntracked: false, keepIndex: false, in: f.path)
            let stashList = try await f.service.stashRecords(in: f.path)
        let stash = try XCTUnwrap(stashList.first)
            try f.write("f.txt", "committed after stash\n"); try f.commit("Conflicting base")
            let result = try await f.service.applyStash(stash, pop: pop, in: f.path)
            XCTAssertFalse(result.applied); XCTAssertFalse(result.removed)
            XCTAssertTrue(result.message.contains("kept"))
            XCTAssertTrue(try f.read("f.txt").contains("<<<<<<<"))
            XCTAssertFalse(try f.git(["ls-files", "-u"]).isEmpty)
            let kept = try await f.service.stashRecords(in: f.path)
            XCTAssertEqual(kept.map(\.oid), [stash.oid])
        }
    }
    func testStaleSelectorCannotDropOrPopNewStash() async throws {
        let f = try BranchFixture(); defer { f.close() }
        try f.write("f.txt", "first\n"); _ = try await f.service.createStash(message: "First", includeUntracked: false, keepIndex: false, in: f.path)
        let firstList = try await f.service.stashRecords(in: f.path)
        let first = try XCTUnwrap(firstList.first)
        try f.write("new.txt", "new\n"); _ = try await f.service.createStash(message: "New", includeUntracked: true, keepIndex: false, in: f.path)
        let before = try await f.service.stashRecords(in: f.path)
        do { try await f.service.dropStash(first, in: f.path); XCTFail("stale selector") } catch {}
        let result = try await f.service.applyStash(first, pop: true, in: f.path)
        XCTAssertTrue(result.applied); XCTAssertFalse(result.removed)
        XCTAssertEqual(try f.read("f.txt"), "first\n")
        let after = try await f.service.stashRecords(in: f.path)
        XCTAssertEqual(after.map(\.oid), before.map(\.oid))
    }
    func testDropTipMiddleLastAndDuplicateOIDPreservesOtherReflogEntries() async throws {
        let f = try BranchFixture(); defer { f.close() }
        try f.write("f.txt", "stash\n"); _ = try await f.service.createStash(message: "Original", includeUntracked: false, keepIndex: false, in: f.path)
        let originalList = try await f.service.stashRecords(in: f.path)
        let original = try XCTUnwrap(originalList.first)
        try f.write("f.txt", "other\n"); _ = try await f.service.createStash(message: "Other", includeUntracked: false, keepIndex: false, in: f.path)
        try f.git(["stash", "store", "-m", "Duplicate", original.oid])
        var list = try await f.service.stashRecords(in: f.path)
        try await f.service.dropStash(list[0], in: f.path)
        list = try await f.service.stashRecords(in: f.path)
        XCTAssertEqual(list.map(\.message), ["Other", "Original"])
        try await f.service.dropStash(list[0], in: f.path)
        list = try await f.service.stashRecords(in: f.path)
        XCTAssertEqual(list.map(\.oid), [original.oid])
        try await f.service.dropStash(list[0], in: f.path)
        list = try await f.service.stashRecords(in: f.path)
        XCTAssertTrue(list.isEmpty)
        XCTAssertEqual(try f.gitStatus(["rev-parse", "--verify", "refs/stash"]), 128)
        XCTAssertEqual(try f.read("f.txt"), "base\n")
        try f.write("f.txt", "after empty\n"); _ = try await f.service.createStash(message: "After", includeUntracked: false, keepIndex: false, in: f.path)
        list = try await f.service.stashRecords(in: f.path)
        XCTAssertEqual(list.map(\.message), ["After"])
    }
    func testPreviewIncludesSavedIndexWhenWorkingTreeReversedIt() async throws {
        let f = try BranchFixture(); defer { f.close() }
        try f.write("f.txt", "index only\n"); try f.git(["add", "f.txt"]); try f.write("f.txt", "base\n")
        _ = try await f.service.createStash(message: "Index snapshot", includeUntracked: false, keepIndex: false, in: f.path)
        let records = try await f.service.stashRecords(in: f.path), stash = try XCTUnwrap(records.first)
        let files = try await f.service.stashFiles(stash, in: f.path)
        let indexed = try XCTUnwrap(files.first { $0.staged })
        let diff = try await f.service.stashDiff(stash, file: indexed, in: f.path)
        XCTAssertTrue(diff.first?.hunks.flatMap(\.lines).contains { $0.text.contains("index only") } == true)
        XCTAssertEqual(try f.git(["show", stash.oid + "^2:f.txt"]), "index only\n")
    }
    func testPopAppliesTheSameObjectAsPreviewDespiteReplacementRefs() async throws {
        let f = try BranchFixture(); defer { f.close() }
        try f.write("f.txt", "reviewed bytes\n"); _ = try await f.service.createStash(message: "Reviewed", includeUntracked: false, keepIndex: false, in: f.path)
        try f.write("f.txt", "replacement bytes\n"); _ = try await f.service.createStash(message: "Replacement", includeUntracked: false, keepIndex: false, in: f.path)
        let records = try await f.service.stashRecords(in: f.path)
        try f.git(["replace", records[1].oid, records[0].oid])
        let files = try await f.service.stashFiles(records[1], in: f.path)
        let diff = try await f.service.stashDiff(records[1], file: try XCTUnwrap(files.first), in: f.path)
        XCTAssertTrue(diff.first?.hunks.flatMap(\.lines).contains { $0.text.contains("reviewed bytes") } == true)
        let result = try await f.service.applyStash(records[1], pop: true, in: f.path)
        XCTAssertTrue(result.applied); XCTAssertTrue(result.removed)
        XCTAssertEqual(try f.read("f.txt"), "reviewed bytes\n")
        let remaining = try await f.service.stashRecords(in: f.path)
        XCTAssertEqual(remaining.map(\.oid), [records[0].oid])
    }
    func testDropDoesNotRemoveLocksAcquiredAfterPublication() async throws {
        let f = try BranchFixture(); defer { f.close() }
        for number in 1...2 {
            try f.write("f.txt", "saved \(number)\n")
            _ = try await f.service.createStash(message: "Saved \(number)", includeUntracked: false, keepIndex: false, in: f.path)
        }
        let list = try await f.service.stashRecords(in: f.path)
        let directory = f.path + "/.git", marker = Data("new lock owner".utf8)
        let paths = [directory + "/refs/stash.lock", directory + "/logs/refs/stash.lock"]
        try GitStashStore.drop(list[0], in: directory, afterPublication: {
            for path in paths { try marker.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting) }
        })
        for path in paths { XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), marker) }
        XCTAssertEqual(try f.read("f.txt"), "base\n")
    }
    func testReplacementWithoutThirdParentCannotHideSavedUntrackedFiles() async throws {
        let f = try BranchFixture(); defer { f.close() }
        try f.write("saved.txt", "reviewed untracked bytes\n")
        _ = try await f.service.createStash(message: "Includes untracked", includeUntracked: true, keepIndex: false, in: f.path)
        try f.write("f.txt", "tracked replacement\n")
        _ = try await f.service.createStash(message: "Only tracked", includeUntracked: false, keepIndex: false, in: f.path)
        let records = try await f.service.stashRecords(in: f.path)
        try f.git(["replace", records[1].oid, records[0].oid])
        let files = try await f.service.stashFiles(records[1], in: f.path)
        XCTAssertEqual(files.filter(\.untracked).map(\.path), ["saved.txt"])
        let result = try await f.service.applyStash(records[1], in: f.path)
        XCTAssertTrue(result.applied)
        XCTAssertEqual(try f.read("saved.txt"), "reviewed untracked bytes\n")
        XCTAssertEqual(try f.read("f.txt"), "base\n")
    }

    func testPopRestoresIndexOnlyBytesBeforeDropping() async throws {
        let f = try BranchFixture(); defer { f.close() }
        try f.write("f.txt", "staged only\n"); try f.git(["add", "f.txt"]); try f.write("f.txt", "base\n")
        _ = try await f.service.createStash(message: "Saved index", includeUntracked: false, keepIndex: false, in: f.path)
        let records = try await f.service.stashRecords(in: f.path), stash = try XCTUnwrap(records.first)
        let result = try await f.service.applyStash(stash, pop: true, in: f.path)
        XCTAssertTrue(result.applied); XCTAssertTrue(result.removed)
        XCTAssertEqual(try f.git(["show", ":f.txt"]), "staged only\n")
        XCTAssertEqual(try f.read("f.txt"), "base\n")
        let remaining = try await f.service.stashRecords(in: f.path)
        XCTAssertTrue(remaining.isEmpty)
    }
    func testDroppingAnotherEntryPreservesNonUTF8ReflogTail() async throws {
        let f = try BranchFixture(); defer { f.close() }
        for number in 1...2 {
            try f.write("f.txt", "saved \(number)\n")
            _ = try await f.service.createStash(message: "Saved \(number)", includeUntracked: false, keepIndex: false, in: f.path)
        }
        let path = f.root.appendingPathComponent(".git/logs/refs/stash")
        var raw = try Data(contentsOf: path); raw.insert(255, at: raw.count - 1); try raw.write(to: path)
        let lines = raw.split(separator: UInt8(10)), originalTail = Data(lines.last!.dropFirst(41))
        let records = try await f.service.stashRecords(in: f.path)
        try await f.service.dropStash(records[1], in: f.path)
        let result = try Data(contentsOf: path)
        XCTAssertEqual(Data(result.dropFirst(41).dropLast()), originalTail)
    }

    func testStashLockAndPackedRefRefuseRemovalIntact() async throws {
        let f = try BranchFixture(); defer { f.close() }
        try f.write("f.txt", "work\n"); _ = try await f.service.createStash(message: "Keep", includeUntracked: false, keepIndex: false, in: f.path)
        let stashList = try await f.service.stashRecords(in: f.path)
        let stash = try XCTUnwrap(stashList.first)
        let lock = f.root.appendingPathComponent(".git/refs/stash.lock")
        try Data("fixture lock".utf8).write(to: lock)
        do { try await f.service.dropStash(stash, in: f.path); XCTFail("lock") } catch {}
        XCTAssertEqual(try Data(contentsOf: lock), Data("fixture lock".utf8))
        try FileManager.default.removeItem(at: lock)
        try f.git(["pack-refs", "--all"])
        do { try await f.service.dropStash(stash, in: f.path); XCTFail("packed") } catch {}
        let list = try await f.service.stashRecords(in: f.path)
        XCTAssertEqual(list.map(\.oid), [stash.oid])
    }
    func testDropPreservesSharedRepositoryRefAndReflogPermissions() async throws {
        let f = try BranchFixture(); defer { f.close() }
        try f.git(["config", "core.sharedRepository", "group"])
        for number in 1...2 {
            try f.write("f.txt", "saved \(number)\n")
            _ = try await f.service.createStash(message: "Saved \(number)", includeUntracked: false, keepIndex: false, in: f.path)
        }
        let paths = [f.path + "/.git/refs/stash", f.path + "/.git/logs/refs/stash"]
        for path in paths { try FileManager.default.setAttributes([.posixPermissions: 0o660], ofItemAtPath: path) }
        let records = try await f.service.stashRecords(in: f.path)
        try await f.service.dropStash(records[0], in: f.path)
        for path in paths {
            let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o660)
        }
        let remaining = try await f.service.stashRecords(in: f.path)
        XCTAssertEqual(remaining.map(\.oid), [records[1].oid])
    }
}
