import XCTest
import Darwin
@testable import PiAgentCore

/// A fork's journal can be a clone of the chat's (`SessionJournal.clone`):
/// the same bytes, but for a session header of the same length naming the
/// fork, sharing the chat's blocks until either is written. When no clone can
/// be made, nothing is left behind and the caller copies instead.
final class JournalCloneTests: XCTestCase {
    private var root: URL!
    private var profile: Profile!
    override func setUpWithError() throws { root = try temporaryDirectory(); profile = try fixtureProfile() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private let chatID = "11111111-1111-4111-8111-111111111111", forkID = "22222222-2222-4222-8222-222222222222"
    private func chat(_ records: Int = 3, flush: Bool = true) throws -> SessionJournal {
        let journal = try SessionJournal(url: root.appendingPathComponent("chat.jsonl"), id: chatID, cwd: root, binding: profile.binding, create: true)
        for index in 0..<records {
            try journal.append(["type": "message", "message": ["role": "user", "content": JSON("question \(index)")]], id: "q\(index)", flush: flush)
        }
        return journal
    }
    private func lines(_ url: URL) throws -> [Data] { try Data(contentsOf: url).split(separator: 10, omittingEmptySubsequences: false).dropLast().map { Data($0) } }
    private func leftovers() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix("chat.jsonl") }.sorted() }

    func testACloneIsTheJournalWithTheForksHeader() throws {
        let journal = try chat()
        let before = try Data(contentsOf: journal.url)
        let url = root.appendingPathComponent(".fork-clone.jsonl"), started = Date().addingTimeInterval(-1)
        var clone: SessionJournal! = try XCTUnwrap(journal.clone(to: url, id: forkID, cwd: root))
        XCTAssertEqual(try Data(contentsOf: journal.url), before, "the chat is not written")
        let chatLines = try lines(journal.url), cloneLines = try lines(url)
        XCTAssertEqual(Array(cloneLines.dropFirst()), Array(chatLines.dropFirst()), "every record as it was")
        XCTAssertEqual(cloneLines[0].count, chatLines[0].count, "the header keeps its length")
        let header = try JSON.parse(cloneLines[0])
        XCTAssertEqual(header["id"].text, forkID); XCTAssertEqual(header["type"].text, "session"); XCTAssertEqual(header["version"].int, 3)
        XCTAssertEqual(header["cwd"].text, root.path)
        XCTAssertEqual(clone.head, journal.head); XCTAssertEqual(clone.size, journal.size)
        XCTAssertEqual(clone.markerCheck, journal.markerCheck)
        XCTAssertEqual(clone.headerCheck?.sha256, JournalCheckpoint.digest(cloneLines[0]))
        let created = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date)
        XCTAssertGreaterThanOrEqual(created, started, "created now, as a copy is")
        // Its next record follows the chat's last; published, it opens as the fork.
        try clone.append(["type": "custom", "customType": "test.after", "data": [:]], id: "after")
        XCTAssertEqual(try JSON.parse(try XCTUnwrap(try lines(url).last))["parentId"].text, journal.head)
        let destination = root.appendingPathComponent("fork_\(forkID).jsonl")
        try clone.publish(to: destination)
        clone = nil
        XCTAssertNoThrow(try SessionJournal(url: destination, id: forkID, cwd: root, binding: profile.binding, create: false), "one unbroken chain")
    }

    func testAShorterIDIsPaddedAndALongerOneIsNotCloned() throws {
        let journal = try chat()
        let short = root.appendingPathComponent(".fork-short.jsonl")
        var clone: SessionJournal! = try XCTUnwrap(journal.clone(to: short, id: "fork", cwd: root))
        let header = try lines(short)[0]
        XCTAssertEqual(header.count, try lines(journal.url)[0].count)
        XCTAssertEqual(try JSON.parse(header)["id"].text, "fork")
        XCTAssertTrue(header.reversed().prefix { $0 == 0x20 }.count > 0, "padded with spaces")
        let destination = root.appendingPathComponent("fork_fork.jsonl")
        try clone.publish(to: destination)
        clone = nil
        XCTAssertNoThrow(try SessionJournal(url: destination, id: "fork", cwd: root, binding: profile.binding, create: false))
        let long = root.appendingPathComponent(".fork-long.jsonl")
        XCTAssertNil(journal.clone(to: long, id: String(repeating: "f", count: 100), cwd: root), "a longer header does not fit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: long.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: long.path + ".lock"))
    }

    func testACloneThroughARecordEndsThere() throws {
        let journal = try chat(5)
        let all = try lines(journal.url)
        // Through the third question: the header, the marker, q0, q1 and q2.
        let bytes = UInt64(all.prefix(5).map { $0.count + 1 }.reduce(0, +))
        XCTAssertEqual(try JSON.parse(all[4])["id"].text, "q2")
        let url = root.appendingPathComponent(".fork-part.jsonl")
        var clone: SessionJournal! = try XCTUnwrap(journal.clone(to: url, id: forkID, cwd: root, through: (bytes, "q2")))
        XCTAssertEqual(clone.size, bytes); XCTAssertEqual(clone.head, "q2")
        XCTAssertEqual(Array(try lines(url).dropFirst()), Array(all[1..<5]))
        try clone.append(["type": "custom", "customType": "test.after", "data": [:]], id: "after")
        XCTAssertEqual(try JSON.parse(try XCTUnwrap(try lines(url).last))["parentId"].text, "q2")
        let destination = root.appendingPathComponent("fork_\(forkID).jsonl")
        try clone.publish(to: destination)
        clone = nil
        XCTAssertNoThrow(try SessionJournal(url: destination, id: forkID, cwd: root, binding: profile.binding, create: false))
        XCTAssertEqual(try lines(journal.url), all, "the chat keeps every record")
        // A place that is not a record's end is not cloned.
        XCTAssertNil(journal.clone(to: root.appendingPathComponent(".fork-mid.jsonl"), id: forkID, cwd: root, through: (bytes - 2, "q2")))
        XCTAssertEqual(try leftovers(), ["fork_\(forkID).jsonl", "fork_\(forkID).jsonl.lock"])
    }

    /// Records written and not yet forced to disk are in the clone, and the
    /// clone does not force the chat's to disk.
    func testUnsyncedRecordsAreInTheClone() throws {
        let journal = try chat(2)
        try journal.append(["type": "message", "message": ["role": "user", "content": "not yet synced"]], id: "unsynced", flush: false)
        let synchronizations = journal.synchronizations
        let url = root.appendingPathComponent(".fork-dirty.jsonl")
        let clone = try XCTUnwrap(journal.clone(to: url, id: forkID, cwd: root))
        XCTAssertEqual(try JSON.parse(try XCTUnwrap(try lines(url).last))["id"].text, "unsynced")
        XCTAssertEqual(clone.head, "unsynced")
        XCTAssertEqual(journal.synchronizations, synchronizations, "the chat is not synchronized")
    }

    func testTheCloneAndTheChatAreWrittenApart() throws {
        let journal = try chat()
        let url = root.appendingPathComponent(".fork-apart.jsonl")
        let clone = try XCTUnwrap(journal.clone(to: url, id: forkID, cwd: root))
        let cloneBefore = try Data(contentsOf: url)
        try journal.append(["type": "message", "message": ["role": "user", "content": "the chat goes on"]], id: "chat-next")
        XCTAssertEqual(try Data(contentsOf: url), cloneBefore, "the clone is not the chat")
        let chatBefore = try Data(contentsOf: journal.url)
        try clone.append(["type": "message", "message": ["role": "user", "content": "the fork goes on"]], id: "fork-next")
        XCTAssertEqual(try Data(contentsOf: journal.url), chatBefore, "the chat is not the clone")
    }

    /// No clone can be made: a volume that does not clone, a name taken, a
    /// lock someone holds, a journal written behind the chat's back. Nothing
    /// is left behind, and nothing that was there is touched.
    func testWhenNoCloneCanBeMadeNothingIsLeftBehind() throws {
        let journal = try chat()
        let before = try Data(contentsOf: journal.url)
        let unsupported = root.appendingPathComponent(".fork-unsupported.jsonl")
        XCTAssertNil(journal.clone(to: unsupported, id: forkID, cwd: root, cloneFile: { _, _ in errno = ENOTSUP; return -1 }))
        XCTAssertEqual(try leftovers(), [])
        let taken = root.appendingPathComponent(".fork-taken.jsonl")
        try Data("someone else's\n".utf8).write(to: taken)
        XCTAssertNil(journal.clone(to: taken, id: forkID, cwd: root))
        XCTAssertEqual(try Data(contentsOf: taken), Data("someone else's\n".utf8)); XCTAssertEqual(try leftovers(), [".fork-taken.jsonl"])
        try FileManager.default.removeItem(at: taken)
        let locked = root.appendingPathComponent(".fork-locked.jsonl")
        try Data().write(to: URL(fileURLWithPath: locked.path + ".lock"))
        XCTAssertNil(journal.clone(to: locked, id: forkID, cwd: root))
        XCTAssertEqual(try leftovers(), [".fork-locked.jsonl.lock"], "a lock that was there stays")
        try FileManager.default.removeItem(atPath: locked.path + ".lock")
        let file = try FileHandle(forWritingTo: journal.url); try file.seekToEnd(); try file.write(contentsOf: Data("{}\n".utf8)); try file.close()
        XCTAssertNil(journal.clone(to: root.appendingPathComponent(".fork-grown.jsonl"), id: forkID, cwd: root), "the file is not the one the journal wrote")
        XCTAssertEqual(try leftovers(), [])
        XCTAssertEqual(try Data(contentsOf: journal.url).prefix(before.count), before)
    }

    /// A fork that never finished (the app crashed mid-way) leaves its journal
    /// and lock; they go once an hour old and unlocked. One under way, or new,
    /// stays.
    func testWhatAForkThatNeverFinishedLeftIsRemovedLater() throws {
        let journal = try chat()
        var crashed: SessionJournal? = try XCTUnwrap(journal.clone(to: root.appendingPathComponent(".fork-crashed.jsonl"), id: forkID, cwd: root))
        let underWay = try XCTUnwrap(journal.clone(to: root.appendingPathComponent(".fork-under-way.jsonl"), id: forkID, cwd: root))
        crashed = nil
        XCTAssertNil(crashed)
        try Data("new\n".utf8).write(to: root.appendingPathComponent(".fork-new.jsonl"))
        let old = Date().addingTimeInterval(-2 * JournalSlimming.leftoverAge)
        for name in [".fork-crashed.jsonl", ".fork-under-way.jsonl"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent(name).path)
        }
        // A lock alone (a crash between the lock and the clone): old, it goes;
        // new, or held, or one that cannot be opened, it stays.
        func lockAlone(_ name: String, old stale: Bool) throws -> String {
            let path = root.appendingPathComponent(name + ".lock").path
            try Data().write(to: URL(fileURLWithPath: path))
            if stale { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path) }
            return path
        }
        _ = try lockAlone(".fork-lock-old.jsonl", old: true)
        _ = try lockAlone(".fork-lock-new.jsonl", old: false)
        let heldPath = try lockAlone(".fork-lock-held.jsonl", old: true)
        let held = open(heldPath, O_RDWR); defer { _ = close(held) }
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
        // An old journal whose lock cannot be opened is not taken for one without.
        let closed = root.appendingPathComponent(".fork-closed.jsonl")
        try Data("closed\n".utf8).write(to: closed)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: closed.path)
        let closedLock = try lockAlone(".fork-closed.jsonl", old: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: closedLock)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: closedLock) }
        SessionJournal.removeForkLeftovers(in: root)
        XCTAssertEqual(try leftovers(), [".fork-closed.jsonl", ".fork-closed.jsonl.lock", ".fork-lock-held.jsonl.lock", ".fork-lock-new.jsonl.lock",
                                         ".fork-new.jsonl", ".fork-under-way.jsonl", ".fork-under-way.jsonl.lock"])
        withExtendedLifetime(underWay) {}
    }

    /// A journal whose path now names something else, even a pipe with no
    /// writer, is not cloned, and the clone does not wait on it.
    func testAJournalWhosePathNamesSomethingElseIsNotCloned() throws {
        let journal = try chat()
        let moved = root.appendingPathComponent("moved.jsonl")
        try FileManager.default.moveItem(at: journal.url, to: moved)
        XCTAssertEqual(mkfifo(journal.url.path, 0o600), 0)
        let started = Date()
        XCTAssertNil(journal.clone(to: root.appendingPathComponent(".fork-fifo.jsonl"), id: forkID, cwd: root))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".fork-fifo.jsonl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".fork-fifo.jsonl.lock").path))
    }
}
