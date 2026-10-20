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
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        child.stop()
        XCTAssertEqual(child.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.process.terminationStatus, SIGKILL)
        let next = secondModel(root: root)
        try await next.cleanupPastedImages()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Kernel-released leases must not pin crashed generations")
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
        let journal = root.appendingPathComponent("saved.jsonl"), pause = PastedJournalPause()
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
