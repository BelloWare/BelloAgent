import Darwin
import XCTest
@testable import PiApp

final class PastedImageLeaseTests: XCTestCase {
    @MainActor func testSecondModelStartupKeepsAnUnpersistedPendingDraftImage() async throws {
        let root = scratchRoot("paste-live-models"), first = makeWorkspaceModel(stateRoot: root)
        let bytes = try ClipboardImageTests.image(), file = try first.pastedImages.write(bytes)
        let view = SessionDisplay(id: "pending")
        view.attachments = [try AttachmentRecord.inspect(file)]
        first.displays[view.id] = view; first.pendingChatIDs.insert(view.id)
        first.draftChanged(view)
        let saved = try await first.store?.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertNil(saved, "Pending New Chat drafts must remain unpersisted")
        let second = secondModel(root: root)
        await second.restore(); await second.pastedImageCleanup?.value
        XCTAssertNotNil(second.pastedImageCleanup, "Exercise the actual startup sweep")
        XCTAssertEqual(try? Data(contentsOf: file), bytes, "Another live instance still owns these bytes")
        XCTAssertEqual(view.attachments.first?.path, file.resolvingSymlinksInPath().path)
        withExtendedLifetime(first) {}
    }

    @MainActor func testChildLeaseProtectsLiveImagesAndCrashMakesThemCollectable() async throws {
        let root = scratchRoot("paste-child-lease"), model = makeWorkspaceModel(stateRoot: root)
        let bytes = try ClipboardImageTests.image()
        let file = try PastedImageStorage(root: root).write(bytes)
        let child = try LeaseProcess(lock: lockURL(for: file), hold: true)
        defer { child.stop() }
        let held = try await child.result()
        XCTAssertEqual(held, "held")
        // A legacy generation has no lease file and must still be collected.
        let legacy = model.pastedImages.directory.appendingPathComponent("pasted-\(UUID().uuidString)-\(UUID().uuidString).png")
        try bytes.write(to: legacy)
        try await model.cleanupPastedImages()
        XCTAssertTrue(child.process.isRunning, "The sweep must not wait for the live lease to end")
        XCTAssertEqual(try? Data(contentsOf: file), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL(for: file).path), "A live generation keeps its sidecar")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        child.stop()
        XCTAssertEqual(child.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.process.terminationStatus, SIGKILL)
        let next = secondModel(root: root)
        try await next.cleanupPastedImages()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Kernel-released leases must not pin crashed generations")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL(for: file).path), "An empty crashed generation leaves no sidecar")
    }

    @MainActor func testStorageCopiesHoldOneLeaseUntilTheLastOwnerIsReleased() async throws {
        let root = scratchRoot("paste-lease-copy")
        defer { try? FileManager.default.removeItem(at: root) }
        var first: PastedImageStorage? = PastedImageStorage(root: root)
        var copy = first
        let file = try XCTUnwrap(first).write(ClipboardImageTests.image())
        first = nil
        let live = try LeaseProcess(lock: lockURL(for: file), hold: false)
        defer { live.stop() }
        let liveResult = try await live.result()
        XCTAssertEqual(liveResult, "busy", "The copied storage owns the same kernel lease")
        withExtendedLifetime(copy) {}; copy = nil
        let abandoned = try LeaseProcess(lock: lockURL(for: file), hold: false)
        defer { abandoned.stop() }
        let abandonedResult = try await abandoned.result()
        XCTAssertEqual(abandonedResult, "held")
    }

    @MainActor func testLeaseFailureCannotPublishAnUnprotectedImage() throws {
        let root = scratchRoot("paste-lease-failure"), storage = PastedImageStorage(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = storage.directory.appendingPathComponent("pasted-\(storage.generation).lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        XCTAssertThrowsError(try storage.write(ClipboardImageTests.image()))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: storage.directory.path).contains { $0.hasSuffix(".png") })
    }

    @MainActor func testCleanupLeavesImagesWhenTheLeaseCannotBeVerified() async throws {
        let root = scratchRoot("paste-lease-symlink"), model = makeWorkspaceModel(stateRoot: root)
        let bytes = try ClipboardImageTests.image(), file = try PastedImageStorage(root: root).write(bytes)
        let lock = lockURL(for: file), sentinel = root.appendingPathComponent("sentinel")
        try Data("Keep this file".utf8).write(to: sentinel)
        if FileManager.default.fileExists(atPath: lock.path) { try FileManager.default.removeItem(at: lock) }
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: sentinel)
        try await model.cleanupPastedImages()
        XCTAssertEqual(try? Data(contentsOf: file), bytes)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "Keep this file")
    }

    @MainActor func testSweepClaimsAbandonedGenerationsBeforeReadingReferences() async throws {
        let root = scratchRoot("paste-inventory-lease"), model = makeWorkspaceModel(stateRoot: root)
        let file = try PastedImageStorage(root: root).write(ClipboardImageTests.image())
        let journal = root.appendingPathComponent("saved.jsonl"), pause = PastedJournalPause(skippingReads: 1)
        try Data("{}\n".utf8).write(to: journal)
        try await model.store?.put(ChatRecord(id: "saved", workspaceID: "w", title: "Saved", path: journal.path, profileID: "p"),
                                   kind: "chat", id: "saved")
        model.pastedImageRead = { try pause.read($0) }
        defer { pause.release() }
        let sweep = Task { try await model.cleanupPastedImages() }
        try await eventually("reference scan paused") { pause.entered }
        let contender = try LeaseProcess(lock: lockURL(for: file), hold: false)
        defer { contender.stop() }
        let result = try await contender.result()
        XCTAssertEqual(result, "busy", "Ownership must precede the inventory, not be inferred after a producer can commit and exit")
        contender.stop(); pause.release(); try await sweep.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor func testRetainedGenerationsDoNotConsumeSweepDescriptors() async throws {
        let root = scratchRoot("paste-many-retained"), model = makeWorkspaceModel(stateRoot: root)
        let bytes = try ClipboardImageTests.image()
        let retained = try (0..<96).map { _ in try PastedImageStorage(root: root).write(bytes) }
        let garbage = try (0..<3).map { _ in try PastedImageStorage(root: root).write(bytes) }
        _ = try await savedJournal(retaining: retained, model: model)
        let probe = SweepReadProbe(directory: model.pastedImages.directory)
        model.pastedImageRead = { try probe.read($0) }
        try await model.cleanupPastedImages()
        let measured = probe.measurements
        XCTAssertGreaterThan(measured.peak, 0, "Measure actual sweep descriptors during the journal scan")
        XCTAssertLessThanOrEqual(measured.peak, 32, "Retained pasting launches must not exhaust the process descriptor limit")
        XCTAssertLessThanOrEqual(measured.peak, garbage.count, "The pre-pass must skip wholly retained generations")
        XCTAssertLessThanOrEqual(measured.reads, 2, "Retained generations must not cause a full scan per batch")
        for file in retained { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
        for file in garbage { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
        print("PASTE_LEASE_RETAINED peak=\(measured.peak) scans=\(measured.reads)")
    }

    @MainActor func testGarbageGenerationsAreClaimedInBoundedBatches() async throws {
        let root = scratchRoot("paste-many-orphans"), model = makeWorkspaceModel(stateRoot: root)
        let bytes = try ClipboardImageTests.image()
        let files = try (0..<70).map { _ in try PastedImageStorage(root: root).write(bytes) }
        _ = try await savedJournal(retaining: [], model: model)
        let probe = SweepReadProbe(directory: model.pastedImages.directory)
        model.pastedImageRead = { try probe.read($0) }
        try await model.cleanupPastedImages()
        XCTAssertEqual(files.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 38, "Leave excess generations for a later bounded sweep")
        XCTAssertLessThanOrEqual(probe.measurements.peak, 32)
        try await model.cleanupPastedImages(); try await model.cleanupPastedImages()
        XCTAssertLessThanOrEqual(probe.measurements.peak, 32)
        XCTAssertLessThanOrEqual(probe.measurements.reads, 6, "At most two journal scans per sweep")
        for file in files { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
        print("PASTE_LEASE_GARBAGE peak=\(probe.measurements.peak) scans=\(probe.measurements.reads)")
    }

    @MainActor func testEmptyLiveGenerationKeepsSidecarUntilOwnerEnds() async throws {
        let root = scratchRoot("paste-empty-generation"), model = makeWorkspaceModel(stateRoot: root)
        var owner: PastedImageStorage? = PastedImageStorage(root: root)
        let file = try XCTUnwrap(owner).write(ClipboardImageTests.image()), lock = lockURL(for: file)
        try FileManager.default.removeItem(at: file)
        try await model.cleanupPastedImages()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path), "No files does not mean no live owner")
        withExtendedLifetime(owner) {}; owner = nil
        let unknown = file.deletingPathExtension().appendingPathExtension("unfinished")
        try Data("Preserve unrecognized generation files".utf8).write(to: unknown)
        try await model.cleanupPastedImages()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path), "Retire a sidecar only when every generation file is gone")
        try FileManager.default.removeItem(at: unknown)
        try await model.cleanupPastedImages()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path), "Collect sidecars left after the last image disappeared")
    }

    @MainActor func testNonRetirableSidecarsCannotStarveOrphanImages() async throws {
        let root = scratchRoot("paste-blocked-sidecars"), model = makeWorkspaceModel(stateRoot: root)
        let directory = model.pastedImages.directory, sidecars = try emptySidecars(35, directory: directory)
        let bytes = Data("Keep unrecognized generation files".utf8)
        let unknown = sidecars.map { $0.deletingPathExtension().path + "-unfinished" }
        for path in unknown.prefix(33) { try bytes.write(to: URL(fileURLWithPath: path)) }
        try FileManager.default.createDirectory(atPath: unknown[33], withIntermediateDirectories: false)
        let sentinel = root.appendingPathComponent("sentinel")
        try bytes.write(to: sentinel)
        try FileManager.default.createSymbolicLink(atPath: unknown[34], withDestinationPath: sentinel.path)
        let orphan = directory.appendingPathComponent("pasted-FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF-\(UUID().uuidString).png")
        try ClipboardImageTests.image().write(to: orphan)
        _ = try await savedJournal(retaining: [], model: model)
        let probe = SweepReadProbe(directory: directory)
        model.pastedImageRead = { try probe.read($0) }
        try await model.cleanupPastedImages()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "Unrecognized files must not starve later orphan images")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL(for: orphan).path))
        XCTAssertEqual(probe.measurements.peak, 1, "Non-retirable sidecars must not consume spare lease capacity")
        XCTAssertLessThanOrEqual(probe.measurements.reads, 2)
        for lock in sidecars { XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path)) }
        for path in unknown.prefix(33) { XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: unknown[33]).isEmpty)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: unknown[34]), sentinel.path)
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
        print("PASTE_LEASE_BLOCKED peak=\(probe.measurements.peak) scans=\(probe.measurements.reads)")
    }

    @MainActor func testOrphanImagesTakePriorityOverRetirableSidecars() async throws {
        let root = scratchRoot("paste-sidecar-priority"), model = makeWorkspaceModel(stateRoot: root)
        let directory = model.pastedImages.directory, sidecars = try emptySidecars(33, directory: directory)
        let orphan = directory.appendingPathComponent("pasted-FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF-\(UUID().uuidString).png")
        try ClipboardImageTests.image().write(to: orphan)
        _ = try await savedJournal(retaining: [], model: model)
        let probe = SweepReadProbe(directory: directory)
        model.pastedImageRead = { try probe.read($0) }
        try await model.cleanupPastedImages()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "Collect image bytes before spending leases on empty sidecars")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL(for: orphan).path))
        XCTAssertEqual(sidecars.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 2, "Only spare capacity retires empty sidecars")
        XCTAssertEqual(probe.measurements.peak, 32)
        try await model.cleanupPastedImages()
        for lock in sidecars { XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path)) }
        XCTAssertLessThanOrEqual(probe.measurements.reads, 2, "Empty sidecars need no additional journal reads")
        print("PASTE_LEASE_PRIORITY peak=\(probe.measurements.peak) scans=\(probe.measurements.reads)")
    }

    @MainActor func testProducerCommitAndExitAfterPrepassSurvivesClaimedRescan() async throws {
        let root = scratchRoot("paste-prepass-commit"), model = makeWorkspaceModel(stateRoot: root)
        var producer: PastedImageStorage? = PastedImageStorage(root: root)
        let bytes = try ClipboardImageTests.image(), file = try XCTUnwrap(producer).write(bytes)
        let journal = try await savedJournal(retaining: [], model: model)
        let pause = PastedJournalPause(afterReading: true)
        model.pastedImageRead = { try pause.read($0) }
        defer { pause.release() }
        let sweep = Task { try await model.cleanupPastedImages() }
        try await eventually("pre-pass captured before commit") { pause.entered }
        try JSONEncoder().encode([file.path]).write(to: journal)
        withExtendedLifetime(producer) {}; producer = nil
        pause.release(); try await sweep.value
        XCTAssertEqual(try? Data(contentsOf: file), bytes, "Only the inventory read after claiming can authorize deletion")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL(for: file).path), "Retained files keep their generation's sidecar")
    }

    @MainActor func testWriterRejectsReplacedGenerationSidecar() throws {
        let root = scratchRoot("paste-replaced-sidecar"), storage = PastedImageStorage(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try ClipboardImageTests.image(), file = try storage.write(bytes), lock = lockURL(for: file)
        // Model an opener that was paused while a collector retired its inode.
        try FileManager.default.removeItem(at: lock); try Data().write(to: lock)
        XCTAssertThrowsError(try storage.write(bytes), "An unlinked descriptor cannot protect a new image")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.directory.path).filter { $0.hasSuffix(".png") }.count, 1)
    }

    @MainActor private func savedJournal(retaining files: [URL], model: WorkspaceModel) async throws -> URL {
        let journal = model.root.appendingPathComponent("saved.jsonl")
        try (JSONEncoder().encode(files.map(\.path)) + Data([10])).write(to: journal)
        try await model.store?.put(ChatRecord(id: "saved", workspaceID: "w", title: "Saved", path: journal.path, profileID: "p"),
                                   kind: "chat", id: "saved")
        return journal
    }

    private func emptySidecars(_ count: Int, directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try (0..<count).map { index in
            let lock = directory.appendingPathComponent(String(format: "pasted-00000000-0000-0000-0000-%012d.lock", index))
            try Data().write(to: lock)
            return lock
        }
    }

    private final class SweepReadProbe: @unchecked Sendable {
        private let directory: URL, mutex = NSLock()
        private var reads = 0, peak = 0
        init(directory: URL) { self.directory = directory }
        var measurements: (reads: Int, peak: Int) {
            mutex.lock(); defer { mutex.unlock() }; return (reads, peak)
        }
        func read(_ path: String) throws -> Set<String> {
            // Observe only this generated fixture's real open lease descriptors.
            let prefix = directory.resolvingSymlinksInPath().path + "/"
            let count = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").filter { name in
                guard let descriptor = Int32(name) else { return false }
                var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
                let result = path.withUnsafeMutableBytes { buffer in fcntl(descriptor, F_GETPATH, buffer.baseAddress!) }
                guard result == 0 else { return false }
                let file = URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }, as: UTF8.self)).resolvingSymlinksInPath().path
                return file.hasPrefix(prefix) && file.hasSuffix(".lock")
            }.count
            mutex.lock(); reads += 1; peak = max(peak, count); mutex.unlock()
            return try PastedImageStorage.names(inJournal: path)
        }
    }

    private func lockURL(for image: URL) -> URL {
        image.deletingLastPathComponent().appendingPathComponent(String(image.lastPathComponent.prefix(43)) + ".lock")
    }

    @MainActor private func secondModel(root: URL) -> WorkspaceModel {
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        // Close this store before the first model's teardown removes their root.
        addTeardownBlock { @MainActor in
            model.shutdown(); try? await model.traces.close(); await model.store?.close()
        }
        return model
    }

    @MainActor private final class LeaseProcess {
        let process = Process()
        private let input = Pipe(), ready: URL
        init(lock: URL, hold: Bool) throws {
            ready = lock.deletingLastPathComponent().appendingPathComponent("lease-result-" + UUID().uuidString)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", """
                import fcntl, os, pathlib, select, sys
                lock, ready, hold = sys.argv[1:]
                fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    result = "held"
                except BlockingIOError:
                    result = "busy"
                path = pathlib.Path(ready)
                temporary = path.with_suffix(".tmp")
                temporary.write_text(result)
                temporary.replace(path)
                if hold == "yes" and result == "held":
                    select.select([sys.stdin], [], [], 30)
                """, lock.path, ready.path, hold ? "yes" : "no"]
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
        }
        func result() async throws -> String {
            try await eventually("child lease result") { FileManager.default.fileExists(atPath: self.ready.path) }
            return try String(contentsOf: ready, encoding: .utf8)
        }
        func stop() {
            if process.isRunning, process.processIdentifier > 0 {
                kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: ready)
        }
    }
}
