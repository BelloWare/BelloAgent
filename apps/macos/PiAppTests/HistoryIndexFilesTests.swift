import XCTest
import AppKit
@testable import PiApp

/// The history index's temporary files. An index's file lives as long as the
/// index: the reader keeps eight at most, the least recently read going first,
/// and lets go of all of them when the app quits. At launch the files an app
/// left behind (a crash, an ended test host, an earlier version) are removed,
/// but never one a running process holds: another copy of the app may be
/// reading it.
final class HistoryIndexFilesTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("index-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func files(_ directory: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted() }
    private func journal(at url: URL, records: Int, id: String = "fixture") throws {
        var bytes = Data("{\"type\":\"session\",\"version\":3,\"id\":\"\(id)\"}\n".utf8)
        for index in 0..<records {
            let value: [String: Any] = ["type": "message", "id": "m\(index)", "parentId": index == 0 ? NSNull() : "m\(index - 1)" as Any,
                                        "message": ["role": index % 2 == 0 ? "user" : "assistant", "content": [["type": "text", "text": "message \(index)"]]]]
            bytes.append(try JSONSerialization.data(withJSONObject: value)); bytes.append(10)
        }
        try bytes.write(to: url)
    }
    private func identities(_ directory: URL) throws -> Set<HistoryIndexFiles.FileIdentity> {
        try Set(files(directory).map { name in
            var status = stat()
            guard lstat(directory.appendingPathComponent(name).path, &status) == 0 else { throw StoreError.unreadableRecord }
            return HistoryIndexFiles.FileIdentity(device: UInt64(UInt32(bitPattern: status.st_dev)), inode: status.st_ino)
        })
    }

    func testRetainedCopiesRegisterNewAndEvictedIndexes() async throws {
        let root = try scratch(), folder = try scratch(), sourceFolder = try scratch()
        let reader = HistoryReader(indexDirectory: folder), source = HistoryReader(indexDirectory: sourceFolder)
        var selections: [(path: URL, snapshot: ContentSearch, digest: String)] = []
        for n in 0..<12 {
            let path = root.appendingPathComponent("chat-\(n).jsonl")
            try journal(at: path, records: 2, id: "chat-\(n)")
            let snapshot = try await source.searchContent(path: path.path, query: "", start: 0, retained: true)
            let digest = try XCTUnwrap(RetainedConversation.rangeDigest(try XCTUnwrap(snapshot.rowHashes), first: 1, last: 2))
            selections.append((path, snapshot, digest))
        }
        await source.releaseIndexes()
        var observed: Set<HistoryIndexFiles.FileIdentity> = []
        // First hand off without a disk index; then copy the held selections
        // again in order, rebuilding indexes evicted by the preceding chats.
        for pass in 0..<2 {
            for (n, selection) in selections.enumerated() {
                var cursor: ContentCursor? = .init(index: 1, offset: 0), text = ""
                while let at = cursor {
                    let page = try await reader.retainedContentPage(path: selection.path.path, journalID: selection.snapshot.journalID,
                        first: 1, last: 2, cursor: at, digest: selection.digest)
                    text += page.text; cursor = page.next
                }
                XCTAssertTrue(text.contains("message 0")); XCTAssertTrue(text.contains("message 1"))
                let count = await reader.retainedIndexCount
                XCTAssertEqual(count, min(8, pass * selections.count + n + 1))
                XCTAssertEqual(files(folder).count, count, "Only retained indexes keep their files")
                observed.formUnion(try identities(folder))
            }
            let held = try XCTUnwrap(HistoryIndexFiles.openFiles()).intersection(observed)
            print("INDEX copy pass \(pass): \(await reader.retainedIndexCount) indexes, \(files(folder).count) files, \(held.count) open")
            XCTAssertEqual(held.count, 8, "Eviction also closes descriptors, including unlinked files")
        }
        await reader.releaseIndexes()
        XCTAssertEqual(files(folder), [])
        XCTAssertTrue(try XCTUnwrap(HistoryIndexFiles.openFiles()).intersection(observed).isEmpty)
    }

    func testRetainedCopyRefreshesIndexRecency() async throws {
        let root = try scratch(), folder = try scratch(), reader = HistoryReader(indexDirectory: folder)
        let first = root.appendingPathComponent("chat-0.jsonl")
        try journal(at: first, records: 2)
        let snapshot = try await reader.searchContent(path: first.path, query: "", start: 0, retained: true)
        let digest = try XCTUnwrap(RetainedConversation.rangeDigest(try XCTUnwrap(snapshot.rowHashes), first: 1, last: 2))
        let firstFile = try XCTUnwrap(files(folder).first)
        for n in 1..<8 {
            let path = root.appendingPathComponent("chat-\(n).jsonl")
            try journal(at: path, records: 2); _ = try await reader.read(path: path.path)
        }
        _ = try await reader.retainedContentPage(path: first.path, journalID: snapshot.journalID,
            first: 1, last: 2, cursor: .init(index: 1, offset: 0), digest: digest)
        let ninth = root.appendingPathComponent("chat-8.jsonl")
        try journal(at: ninth, records: 2); _ = try await reader.read(path: ninth.path)
        XCTAssertTrue(files(folder).contains(firstFile), "Copying an existing index makes it recently used")
        XCTAssertEqual(files(folder).count, 8)
        await reader.releaseIndexes()
    }

    func testCancelledRenderedSearchIndexesStayBounded() async throws {
        let root = try scratch(), folder = try scratch(), reader = HistoryReader(indexDirectory: folder)
        await reader.observeSearchReads { stage in
            if stage == .indexed { withUnsafeCurrentTask { $0?.cancel() } }
        }
        var observed: Set<HistoryIndexFiles.FileIdentity> = []
        for n in 0..<12 {
            let path = root.appendingPathComponent("chat-\(n).jsonl")
            try journal(at: path, records: 2)
            let search = Task { try await reader.searchContent(path: path.path, query: "", start: 0, renderedAgentProse: true) }
            do { _ = try await search.value; XCTFail("The search was canceled after index construction") }
            catch is CancellationError { }
            let count = await reader.retainedIndexCount
            XCTAssertLessThanOrEqual(count, 8); XCTAssertEqual(files(folder).count, count)
            observed.formUnion(try identities(folder))
        }
        let held = try XCTUnwrap(HistoryIndexFiles.openFiles()).intersection(observed)
        print("INDEX canceled searches: \(await reader.retainedIndexCount) indexes, \(files(folder).count) files, \(held.count) open")
        XCTAssertLessThanOrEqual(held.count, 8)
        await reader.releaseIndexes()
        XCTAssertEqual(files(folder), [])
        XCTAssertTrue(try XCTUnwrap(HistoryIndexFiles.openFiles()).intersection(observed).isEmpty)
    }

    func testAnIndexFileNamesItsProcessAndGoesWithTheIndex() throws {
        let root = try scratch()
        do {
            let index = try HistoryOffsetIndex(directory: root)
            XCTAssertEqual(files(root).count, 1)
            XCTAssertTrue(files(root).first?.hasPrefix("bello-history-p\(getpid())-") == true, "The name carries the process holding it: \(files(root))")
            for n in 0..<50 {
                let ref = HistoryOffset(id: "m\(n)", parent: n == 0 ? nil : "m\(n - 1)", offset: UInt64(n * 100), length: 99, type: "message", role: n % 2 == 0 ? "user" : "assistant")
                try index.insert(ref); try index.append(ref)
            }
            try index.finish()
            XCTAssertEqual(try index.at(10).id, "m10"); XCTAssertEqual(try index.latestUser(before: 11), "m10")
            XCTAssertEqual(files(root).count, 1, "Held, it keeps its file")
        }
        XCTAssertEqual(files(root), [], "Let go of, its file goes")
        do {
            let unfinished = try HistoryOffsetIndex(directory: root)
            try unfinished.insert(HistoryOffset(id: "m0", parent: nil, offset: 0, length: 1))
        }
        XCTAssertEqual(files(root), [], "So does one let go of before it was built")
    }

    /// Reading more chats than the reader keeps indexes for, and a journal
    /// that grew: one file per index held, eight at most, none once the
    /// reader lets go of them all as the app quits.
    func testTheReaderHoldsAFileOnlyForEachIndexItKeeps() async throws {
        let root = try scratch(), folder = try scratch()
        let reader = HistoryReader(indexDirectory: folder)
        var paths: [URL] = []
        for n in 0..<9 {
            let path = root.appendingPathComponent("chat-\(n).jsonl")
            try journal(at: path, records: 12)
            paths.append(path)
            let page = try await reader.read(path: path.path)
            XCTAssertEqual(page.messages.last?.id, "m11")
            XCTAssertLessThanOrEqual(files(folder).count, 8, "After chat \(n): \(files(folder).count) files")
        }
        try journal(at: paths[8], records: 20)
        let grown = try await reader.read(path: paths[8].path)
        XCTAssertEqual(grown.messages.last?.id, "m19", "A journal that grew is indexed again")
        let search = try await reader.searchContent(path: paths[8].path, query: "message 3", start: 0)
        XCTAssertEqual(search.hits.first?.id, "m3")
        let retained = await reader.retainedIndexCount, bytes = await reader.retainedIndexBytes
        XCTAssertEqual(retained, 8, "The least recently read is let go of past eight")
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertEqual(files(folder).count, 8, "One file per index kept; the replaced and the evicted ones are gone")
        await reader.releaseIndexes()
        XCTAssertEqual(files(folder), [], "Quitting lets go of every file")
    }

    func testAtLaunchOnlyFilesNoProcessHoldsAreRemoved() throws {
        let root = try scratch()
        func make(_ name: String) throws -> String { try Data("index".utf8).write(to: root.appendingPathComponent(name)); return name }
        let left = try make("bello-history-\(UUID().uuidString).sqlite")
        let held = try make("bello-history-\(UUID().uuidString).sqlite")
        // A process id no process has: the app that named the file ended.
        let gone = try XCTUnwrap((1..<400).map { pid_t(99_990 - $0) }.first { kill($0, 0) == -1 && errno == ESRCH })
        let crashed = try make("bello-history-p\(gone)-\(UUID().uuidString).sqlite")
        let mine = try make("bello-history-p\(getpid())-\(UUID().uuidString).sqlite")
        let unrelated = try make("notes.sqlite")
        XCTAssertEqual(HistoryIndexFiles.owner(crashed), gone); XCTAssertNil(HistoryIndexFiles.owner(left))

        // Another app holding one open, as a running copy holds its index.
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/sh")
        holder.arguments = ["-c", "exec 3<\"$1\"; sleep 30", "sh", root.appendingPathComponent(held).path]
        try holder.run()
        defer { if holder.isRunning { holder.terminate(); holder.waitUntilExit() } }
        var status = stat(); XCTAssertEqual(lstat(root.appendingPathComponent(held).path, &status), 0)
        let identity = HistoryIndexFiles.FileIdentity(device: UInt64(UInt32(bitPattern: status.st_dev)), inode: status.st_ino)
        var waited = 0
        while HistoryIndexFiles.openFiles()?.contains(identity) != true, waited < 500 { usleep(10_000); waited += 1 }
        XCTAssertTrue(HistoryIndexFiles.openFiles()?.contains(identity) == true, "The holder has the file open")

        XCTAssertEqual(HistoryIndexFiles.removeStale(in: root, openFiles: { nil }), [], "What is open cannot be read: nothing is removed")
        XCTAssertEqual(files(root).count, 5)
        XCTAssertEqual(Set(HistoryIndexFiles.removeStale(in: root)), [left, crashed])
        XCTAssertEqual(files(root), [held, mine, unrelated].sorted(), "The held file, one a running app named, and other files stay")

        holder.terminate(); holder.waitUntilExit()
        XCTAssertEqual(HistoryIndexFiles.removeStale(in: root), [held], "Let go of, it goes")
        XCTAssertEqual(files(root), [mine, unrelated].sorted())
    }

    /// `PI_PERF_HISTORY_JOURNAL`: what a long chat's index takes, from its
    /// metadata file and in full.
    func testTheIndexOfALongChat() async throws {
        guard let path = testEnvironment("PI_PERF_HISTORY_JOURNAL") else { throw XCTSkip("Set PI_PERF_HISTORY_JOURNAL to measure a long chat's index.") }
        let folder = try scratch()
        let reader = HistoryReader(indexDirectory: folder)
        var started = Date()
        _ = try await reader.read(path: path)
        let partial = await reader.retainedIndexBytes, partialTook = Date().timeIntervalSince(started)
        started = Date()
        _ = try await reader.read(path: path, whole: true)
        let whole = await reader.retainedIndexBytes, wholeTook = Date().timeIntervalSince(started)
        print(String(format: "PERF history index: %.1f MB from the metadata file (%.0f ms), %.1f MB whole (%.0f ms); files held %d",
                     Double(partial) / 1_048_576, partialTook * 1000, Double(whole) / 1_048_576, wholeTook * 1000, files(folder).count))
    }

    @MainActor func testQuittingReleasesBothReadersIndexFilesBeforeAnswering() async throws {
        let root = try scratch()
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()), tabDefaults: nil); defer { model.shutdown() }
        let journal = try TranscriptImageLoadingTests.Journal(root: root.appendingPathComponent("journal"))
        let directory = FileManager.default.temporaryDirectory
        let prefix = HistoryOffsetIndex.filePrefix + "p\(getpid())-"
        func ownedIndexes() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(prefix) })
        }
        let before = try ownedIndexes()
        _ = try await model.history.read(path: journal.path.path)
        _ = try await model.transcriptImageReader.imageReference(path: journal.path.path, id: "caption")
        let historyCount = await model.history.retainedIndexCount
        let imageCount = await model.transcriptImageReader.retainedIndexCount
        XCTAssertEqual(historyCount, 1); XCTAssertEqual(imageCount, 1)
        let created = try ownedIndexes().subtracting(before)
        XCTAssertEqual(created.count, 2, "The model owns a real temporary database in each reader")
        XCTAssertFalse(model.hasActiveWork)

        let lifecycle = ApplicationLifecycle(); lifecycle.model = model
        let answered = expectation(description: "Quit answers after index cleanup")
        var answers: [Bool] = [], remainingAtAnswer: Set<String>?
        lifecycle.answerTermination = { value in
            answers.append(value)
            remainingAtAnswer = (try? ownedIndexes()).map { $0.intersection(created) }
            answered.fulfill()
        }
        XCTAssertEqual(lifecycle.applicationShouldTerminate(NSApp), .terminateLater)
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(answers, [true]); XCTAssertTrue(model.isShutDown)
        XCTAssertEqual(remainingAtAnswer, [], "Both readers' index files must be gone before termination is accepted")
        let historyAfter = await model.history.retainedIndexCount
        let imageAfter = await model.transcriptImageReader.retainedIndexCount
        XCTAssertEqual(historyAfter, 0); XCTAssertEqual(imageAfter, 0, "The model stays alive here; cleanup cannot rely on deinit")

        // Release test-held readers before fixture teardown, including when a
        // regression leaves one open.
        await model.history.releaseIndexes(); await model.transcriptImageReader.releaseIndexes()
        try await model.traces.close(); await model.store?.close()
    }
}
