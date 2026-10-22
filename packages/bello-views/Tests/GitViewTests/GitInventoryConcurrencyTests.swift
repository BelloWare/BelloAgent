import XCTest
@testable import GitView
@testable import GitProcessSafety

final class GitInventoryConcurrencyTests: ViewsTestCase {
    @MainActor func testCancellationDoesNotWaitForAStartingChild() async throws {
        let root = root!, gate = ProbeGate(), process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.currentDirectoryURL = root
        process.arguments = ["-c", ": > marker"]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let child = GitChildProcess(process), invocation = GitInvocation()
        child.beforeSpawn = { gate.block() }
        XCTAssertTrue(invocation.adopt(child))
        let launch = Work { try child.run() }
        defer { gate.release(); child.killIfRunning() }
        let entered = try await wait { gate.calls == 1 }; XCTAssertTrue(entered)
        let cancel = Work { invocation.stop() }
        let prompt = try await wait({ cancel.isFinished }, timeout: 0.2)
        XCTAssertTrue(prompt, "Cancellation must not wait for spawn's filesystem work")
        gate.release()
        let finished = try await wait { launch.isFinished && cancel.isFinished }; XCTAssertTrue(finished)
        child.waitUntilExit()
        XCTAssertThrowsError(try launch.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("marker").path))
    }

    private var root: URL!
    private var environment: [String: String]!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("git-inventory-concurrency-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.currentDirectoryURL = root
        process.arguments = ["init", "-q", "--template=", "-b", "main"]; process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        try Data("[include]\npath = included\n".utf8).append(to: root.appendingPathComponent(".git/config"))
        try Data("# generated fixture\n".utf8).write(to: root.appendingPathComponent(".git/included"))
        GitConfiguration.invalidate()
    }
    override func tearDownWithError() throws {
        GitFileStamp.beforeProbe = nil
        GitFileStamp.beforeValidation = nil
        GitConfiguration.invalidate()
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor func testStalledInventoryProbeConfinesWithoutRepeatingOrHoldingTheRead() async throws {
        let root = root!, environment = environment!, gate = ProbeGate()
        let target = root.path + "/inactive-config"
        try Data("[includeIf \"onbranch:never\"]\npath = \(target)\n".utf8).append(to: root.appendingPathComponent(".git/config"))
        GitFileStamp.beforeProbe = { if $0 == target { gate.block() } }
        defer { gate.release(); GitFileStamp.beforeProbe = nil }
        // Release even with the pre-fix synchronous probe, to report failures
        // instead of leaving the test runner stuck.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { gate.release() }
        let begin = ProcessInfo.processInfo.systemUptime
        let first = Work { () -> Bool in
            let process = Process(); process.currentDirectoryURL = root
            let policy = try GitReadProcess(process, arguments: ["status", "--porcelain"], environment: environment,
                                            trusted: true, invocation: GitInvocation(timeout: 1))
            defer { policy.remove() }
            return process.executableURL?.path == "/usr/bin/sandbox-exec"
        }
        let entered = try await wait { gate.calls > 0 }; XCTAssertTrue(entered)
        let completed = try await wait({ first.isFinished }, timeout: 0.5)
        XCTAssertTrue(completed, "Inventory probes must leave time for the confined read")
        let second = Work { () -> Bool in
            let process = Process(); process.currentDirectoryURL = root
            let policy = try GitReadProcess(process, arguments: ["status", "--porcelain"], environment: environment,
                                            trusted: true, invocation: GitInvocation(timeout: 1))
            defer { policy.remove() }; return process.executableURL?.path == "/usr/bin/sandbox-exec"
        }
        let another = try await wait({ second.isFinished }, timeout: 0.5)
        XCTAssertTrue(another); XCTAssertEqual(gate.calls, 1, "A stuck path gets only one filesystem probe")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - begin, 1)
        let service = GitService(environment: environment, trusted: true)
        let result = try await service.run(["status", "--porcelain"], in: root.path, timeout: 1)
        XCTAssertEqual(result.status, 0, "Git can read this repository without touching the inactive include")
        XCTAssertEqual(gate.calls, 1)
        gate.release()
        let drained = try await wait { first.isFinished && second.isFinished }; XCTAssertTrue(drained)
        XCTAssertTrue(try first.get()); XCTAssertTrue(try second.get())
    }

    @MainActor func testStalledWarmStampUsesConfinedReadWithinDeadline() async throws {
        let root = root!, environment = environment!, gate = ProbeGate()
        let service = GitService(environment: environment, trusted: true)
        _ = try await service.run(["status", "--porcelain"], in: root.path)
        GitFileStamp.beforeValidation = { if $0.gitHasSuffix("/.git/config") { gate.block() } }
        defer { gate.release(); GitFileStamp.beforeValidation = nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { gate.release() }
        let start = ProcessInfo.processInfo.systemUptime
        let output = try await service.run(["status", "--porcelain"], in: root.path, timeout: 1)
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(gate.calls, 1)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
    }

    @MainActor func testCancellingAColdFilesystemProbeReleasesTheReadSlot() async throws {
        let root = root!, environment = environment!, gate = ProbeGate()
        GitFileStamp.beforeProbe = { if $0 == root.path { gate.block() } }
        defer { gate.release(); GitFileStamp.beforeProbe = nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { gate.release() }
        let service = GitService(environment: environment, trusted: true)
        let read = Task { try await service.run(["status", "--porcelain"], in: root.path) }
        let entered = try await wait { gate.calls > 0 }; XCTAssertTrue(entered)
        let start = ProcessInfo.processInfo.systemUptime
        read.cancel()
        do { _ = try await read.value; XCTFail("Cancelled inventory completed") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.3)
        let running = await service.processesRunning; XCTAssertEqual(running, 0)
    }

    private final class ProbeGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var count = 0, released = false
        var calls: Int { condition.lock(); defer { condition.unlock() }; return count }
        func block() {
            condition.lock(); count += 1
            while !released { condition.wait() }
            condition.unlock()
        }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock(), released = DispatchSemaphore(value: 0)
        private var entered = false
        var isEntered: Bool { lock.withLock { entered } }
        func blockOnce() {
            guard lock.withLock({ if entered { return false }; entered = true; return true }) else { return }
            _ = released.wait(timeout: .now() + 10)
        }
        func release() { released.signal() }
    }
    private final class Work<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Value, Error>?
        var isFinished: Bool { lock.withLock { result != nil } }
        func get() throws -> Value { try lock.withLock { try XCTUnwrap(result).get() } }
        init(_ body: @escaping @Sendable () throws -> Value) {
            DispatchQueue.global().async { [self] in
                let value = Result { try body() }
                lock.withLock { result = value }
            }
        }
    }
    private final class Inventory: @unchecked Sendable {
        let value: GitConfiguration
        init(_ value: GitConfiguration) { self.value = value }
    }
    @MainActor private func wait(_ ready: () -> Bool, timeout: TimeInterval = 1) async throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !ready(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(5)) }
        return ready()
    }

    @MainActor func testBlockedStampDoesNotHoldReadersInvalidationOrClear() async throws {
        let root = root!, environment = environment!, gate = Gate()
        let inventory = try GitConfiguration(in: root, environment: environment)
        XCTAssertTrue(inventory.cacheable)
        let config = root.appendingPathComponent(".git/config").path
        GitFileStamp.beforeValidation = {
            guard $0.gitHasSuffix("/.git/config") else { return }
            if gate.isEntered { Thread.sleep(forTimeInterval: 0.12) }
            else { gate.blockOnce() }
        }
        defer { gate.release(); GitFileStamp.beforeValidation = nil }
        let first = Work { try GitConfiguration(in: root, environment: environment) }
        let entered = try await wait { gate.isEntered }; XCTAssertTrue(entered)
        let cancelled = GitInvocation(), expired = GitInvocation(timeout: 0.06)
        let second = Work { try GitConfiguration(in: root, environment: environment, invocation: cancelled) }
        let third = Work { try GitConfiguration(in: root, environment: environment, invocation: expired) }
        try await Task.sleep(for: .milliseconds(20)); cancelled.stop()
        let invalidation = Work { GitConfiguration.invalidate(paths: [config]) }
        try await Task.sleep(for: .milliseconds(20))
        let clearing = Work { GitConfiguration.invalidate() }
        for (name, done) in [("cancelled reader", { second.isFinished }), ("expired reader", { third.isFinished }),
                             ("watcher invalidation", { invalidation.isFinished }), ("trust clear", { clearing.isFinished })] {
            let prompt = try await wait(done, timeout: 0.3)
            XCTAssertTrue(prompt, "\(name) must not wait for another reader's filesystem lookup")
        }
        gate.release()
        let drained = try await wait { first.isFinished && second.isFinished && third.isFinished && invalidation.isFinished && clearing.isFinished }
        XCTAssertTrue(drained)
        XCTAssertThrowsError(try second.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try third.get())
        _ = try first.get()
    }

    @MainActor func testMemoRechecksSnapshotAfterConcurrentReplacement() async throws {
        let memo = GitInventoryMemo<Int>(), gate = Gate()
        _ = try memo.get(invocation: GitInvocation(), build: { 1 })
        let first = Work { try memo.get(invocation: GitInvocation(), valid: { value in
            if value == 1 { gate.blockOnce() }; return true
        }, build: { 3 }) }
        defer { gate.release() }
        let entered = try await wait { gate.isEntered }; XCTAssertTrue(entered)
        let second = Work { try memo.get(invocation: GitInvocation(), valid: { $0 == 2 }, build: { 2 }) }
        let prompt = try await wait({ second.isFinished }, timeout: 0.3)
        XCTAssertTrue(prompt, "A different reader can replace an invalid snapshot while validation is blocked")
        gate.release()
        let drained = try await wait { first.isFinished && second.isFinished }; XCTAssertTrue(drained)
        XCTAssertEqual(try first.get(), 2, "The old snapshot must not be returned after replacement")
        XCTAssertEqual(try second.get(), 2)
    }

    @MainActor func testIgnoredEventsDuringColdBuildDoNotRefreshOrPreventCaching() async throws {
        try await coldEvents(paths: (0..<100).map { "build/output-\($0)" }, configurationChanged: false)
    }

    @MainActor func testSourceEventsDuringColdBuildDeferRefreshAndPreventCaching() async throws {
        for path in [".git/config", ".git/included"] { try await coldEvents(paths: [path], configurationChanged: true) }
    }

    @MainActor func testStoppedWatcherDoesNotConsumeDeferredSourceEvent() async throws {
        try await coldEvents(paths: [".git/included"], configurationChanged: true, stopWatcher: true)
    }

    @MainActor func testCancelledWaiterPreservesColdBuildAndTrustClearDiscardsIt() async throws {
        let root = root!, environment = environment!
        for clear in [false, true] {
            let inventory = Inventory(try GitConfiguration(in: root, environment: environment)), gate = Gate()
            GitConfiguration.invalidate()
            let build = Work { try GitInventoryCache.shared.configuration(in: root, environment: environment, invocation: GitInvocation()) {
                gate.blockOnce(); return inventory.value
            } }
            defer { gate.release() }
            let entered = try await wait { gate.isEntered }; XCTAssertTrue(entered)
            let waiter = Work { try GitConfiguration(in: root, environment: environment, invocation: GitInvocation(timeout: 0.06)) }
            let cancelled = try await wait({ waiter.isFinished }, timeout: 0.3); XCTAssertTrue(cancelled)
            if cancelled { XCTAssertThrowsError(try waiter.get()) }
            if clear { GitConfiguration.invalidate() }
            gate.release()
            let finished = try await wait { build.isFinished }; XCTAssertTrue(finished)
            _ = try build.get()
            let before = GitConfiguration.queryCount
            _ = try GitConfiguration(in: root, environment: environment)
            if clear { XCTAssertGreaterThan(GitConfiguration.queryCount, before, "Trust clearing cannot be undone by an older build") }
            else { XCTAssertEqual(GitConfiguration.queryCount, before, "An expired waiter does not own the builder's publication") }
        }
    }

    @MainActor private func coldEvents(paths: [String], configurationChanged: Bool, stopWatcher: Bool = false) async throws {
        let root = root!, environment = environment!, gate = Gate()
        let inventory = Inventory(try GitConfiguration(in: root, environment: environment))
        GitConfiguration.invalidate()
        var changes: [GitWatchChanges] = []
        let watcher = GitWorkingTreeWatcher(root: root.path, interval: 0) { changes.append($0) }
        watcher.ignored.update(root: root.path, relative: ["build/"], scanStartedAt: DispatchTime.now().uptimeNanoseconds)
        watcher.start(); XCTAssertTrue(watcher.isWatching)
        defer { gate.release(); watcher.stop() }
        let build = Work { try GitInventoryCache.shared.configuration(in: root, environment: environment, invocation: GitInvocation()) {
            gate.blockOnce(); return inventory.value
        } }
        let entered = try await wait { gate.isEntered }; XCTAssertTrue(entered)
        for path in paths { watcher.bridge?.deliver([root.path + "/" + path], [0]) }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(changes.isEmpty, "A pending build alone is not evidence of a configuration event")
        if stopWatcher { watcher.stop(); watcher.start() }
        // A newer ignore scan cannot swallow the deferred configuration signal.
        watcher.ignored.update(root: root.path, relative: ["build/", ".git/"], scanStartedAt: DispatchTime.now().uptimeNanoseconds)
        gate.release()
        let finished = try await wait { build.isFinished }; XCTAssertTrue(finished)
        _ = try build.get()
        if configurationChanged && !stopWatcher {
            let refreshed = try await wait { !changes.isEmpty }; XCTAssertTrue(refreshed, "A source event must still refresh after the inventory completes")
            XCTAssertTrue(changes.contains { $0.paths.isEmpty && !$0.isEmpty }, "The deferred signal bypasses working-tree ignores")
        } else {
            try await Task.sleep(for: .milliseconds(60)); XCTAssertTrue(changes.isEmpty)
        }
        let before = GitConfiguration.queryCount
        _ = try GitConfiguration(in: root, environment: environment)
        if configurationChanged { XCTAssertGreaterThan(GitConfiguration.queryCount, before, "A source event prevents publication even if its current stamp happens to match") }
        else { XCTAssertEqual(GitConfiguration.queryCount, before, "Unrelated cold-build events must preserve cache reuse") }
    }
}

private extension Data {
    func append(to url: URL) throws { try (Data(contentsOf: url) + self).write(to: url) }
}
