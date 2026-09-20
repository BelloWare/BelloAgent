import XCTest
import AppKit
@testable import PiApp

final class CrashAuditRegressionTests: XCTestCase {
    func testTerminalBuffersHaveExplicitByteAndFrameBudgets() {
        let pending = PendingOutput()
        let bytes = Data(repeating: 0x61, count: PendingOutput.byteLimit)
        XCTAssertTrue(pending.append(bytes)); XCTAssertEqual(pending.available, 0)
        var drained = Data()
        while pending.count > 0 {
            let (chunk, _) = pending.take(); XCTAssertLessThanOrEqual(chunk.count, PendingOutput.deliveryBytes); drained.append(chunk)
        }
        XCTAssertEqual(drained, bytes)
        let input = TerminalInputLifetime()
        for _ in 0..<TerminalInputLifetime.frameLimit { XCTAssertTrue(input.reserve(1)) }
        XCTAssertFalse(input.reserve(1)); XCTAssertFalse(input.reserve(TerminalInputLifetime.byteLimit))
        input.cancel(); XCTAssertFalse(input.reserve(0))
        for _ in 0..<TerminalInputLifetime.frameLimit { input.release(1) }
        XCTAssertEqual(input.retainedBytes, 0)
    }

    @MainActor func testOneColumnAndCombiningFloodStayWithinTerminalCellBudget() {
        let terminal = TerminalEmulator(columns: 1, rows: 2)
        XCTAssertEqual(terminal.columns, 2)
        var notices = 0; terminal.onTextLimit = { notices += 1 }
        terminal.feed(Data(("界" + String(repeating: "\u{301}", count: 50_000)).utf8))
        XCTAssertEqual(notices, 1)
        for row in terminal.screen { for cell in row { XCTAssertLessThanOrEqual(cell.text.utf8.count, TerminalEmulator.cellTextByteLimit) } }
        terminal.resize(columns: 80, rows: 2)
        terminal.feed(Data("\r\nworking".utf8))
        XCTAssertTrue(terminal.screenText.contains("working"))
    }

    @MainActor func testBusyMainThreadBackpressuresPTYWithoutLosingBytes() async throws {
        let process = PseudoTerminal(), done = expectation(description: "Flooding PTY exited")
        let expected = Data(String(repeating: "a🌍\u{1b}[0m", count: 350_000).utf8)
        var output = Data(), largest = 0
        process.onData = { largest = max(largest, $0.count); output.append($0) }
        process.onExit = { _ in done.fulfill() }
        process.onNotice = { XCTFail($0) }
        try process.start(executable: "/usr/bin/python3", arguments: ["python3", "-c", "import os; data=('a🌍\\x1b[0m'*350000).encode(); n=0\nwhile n<len(data): n+=os.write(1,data[n:])"], environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"], directory: NSTemporaryDirectory(), columns: 80, rows: 24)
        defer { process.terminate() }
        usleep(600_000)
        XCTAssertLessThanOrEqual(process.bufferedOutputBytes, PendingOutput.byteLimit)
        await fulfillment(of: [done], timeout: 12)
        XCTAssertEqual(output, expected)
        XCTAssertLessThanOrEqual(largest, PendingOutput.deliveryBytes)
    }

    @MainActor func testPasteFloodToANonreadingChildIsRejectedBeforeDuplicatingDescriptors() async throws {
        let process = PseudoTerminal(), done = expectation(description: "Nonreader exited")
        var rejected = 0; process.onNotice = { _ in rejected += 1 }; process.onExit = { _ in done.fulfill() }
        try process.start(executable: "/bin/sleep", arguments: ["sleep", "2"], environment: [:], directory: NSTemporaryDirectory(), columns: 80, rows: 24)
        for _ in 0..<200 { process.write(Data(repeating: 0x61, count: 131_072)) }
        XCTAssertGreaterThan(rejected, 0)
        XCTAssertLessThanOrEqual(process.bufferedInputBytes, TerminalInputLifetime.byteLimit)
        process.terminate(); await fulfillment(of: [done], timeout: 4)
        for _ in 0..<100 where process.bufferedInputBytes > 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(process.bufferedInputBytes, 0)
    }

    @MainActor func testPTYExitDoesNotWaitForAContinuouslyWritingDescendant() async throws {
        let process = PseudoTerminal(), done = expectation(description: "Root exit drains within its budget")
        var exits = 0, delivered = 0, largest = 0
        process.onData = { delivered += $0.count; largest = max(largest, $0.count) }
        process.onExit = { _ in exits += 1; done.fulfill() }
        // The child acknowledges that SIGHUP is ignored before its parent exits.
        // It stops on the closed PTY or its own deadline, leaving no lingering fixture.
        let script = """
        import os, signal, time
        r, w = os.pipe()
        if os.fork() == 0:
            os.close(r)
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            os.write(w, b'ready'); os.close(w)
            end = time.monotonic() + 5
            while time.monotonic() < end:
                try: os.write(1, b'x' * 16384)
                except OSError: break
            os._exit(0)
        os.close(w); os.read(r, 5); os.close(r)
        time.sleep(0.2)
        os._exit(0)
        """
        try process.start(executable: "/usr/bin/python3", arguments: ["python3", "-c", script],
                          environment: ["PATH": "/usr/bin:/bin"], directory: NSTemporaryDirectory(), columns: 80, rows: 24)
        defer { process.terminate() }
        usleep(600_000)
        XCTAssertLessThanOrEqual(process.bufferedOutputBytes, PendingOutput.byteLimit)
        await fulfillment(of: [done], timeout: 3)
        XCTAssertFalse(process.running)
        XCTAssertEqual(exits, 1)
        XCTAssertGreaterThan(delivered, 0)
        XCTAssertLessThanOrEqual(largest, PendingOutput.deliveryBytes)
        let countAtExit = delivered
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(delivered, countAtExit, "Closing the owned PTY stops late descendant output")
        XCTAssertEqual(process.bufferedOutputBytes, 0)
    }

    func testGitOutputAndDiagnosticFloodsFailWithoutReturningPartialResults() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()), service = GitService()
        for command in ["!/usr/bin/yes output", "!/usr/bin/yes diagnostics >&2"] {
            let start = ProcessInfo.processInfo.systemUptime
            do { _ = try await service.run(["-c", "alias.flood=" + command, "flood"], in: root.path, timeout: 4); XCTFail("Unbounded output accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("exceeded"), error.localizedDescription) }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 5)
        }
        let cancelled = Task { try await service.run(["-c", "alias.wait=!sleep 8", "wait"], in: root.path, timeout: 10) }
        try await Task.sleep(for: .milliseconds(100)); cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled git succeeded") } catch is CancellationError { }
        let running = await service.processesRunning; XCTAssertEqual(running, 0)
    }

    func testMalformedDurationsAreUnavailableAndNeverIntegerTraps() {
        for value in [Double.nan, .infinity, -.infinity, -1, 1e30, Double(Int.max)] {
            XCTAssertEqual(workDuration(value), "n/a")
            XCTAssertEqual(TranscriptActivity.formatDuration(value), "")
            XCTAssertNil(WorkSplit(timing: ["sessionModelMs": .number(value), "sessionToolMs": .number(1)]))
        }
        XCTAssertEqual(workDuration(72_000), "1m 12s")
        XCTAssertEqual(workDuration(3_720_000), "1h 2m")
        let split = WorkSplit(timing: ["sessionModelMs": .number(1_000), "sessionToolMs": .number(0), "modelMs": .number(1e30), "toolMs": .number(0)])
        XCTAssertNil(split?.turn)
        XCTAssertEqual(TranscriptActivity.grouped(1e30), "—")
    }

    @MainActor func testOpaqueJournalIDsSurviveConsecutiveNativeReconciliations() throws {
        let session = SessionDisplay(id: "opaque-ids"), page = TranscriptPage()
        let messages = [
            TranscriptMessage(id: "block:x", role: "user", text: "First"),
            TranscriptMessage(id: "x", role: "assistant", text: "Answer"),
            TranscriptMessage(id: "message:block:x", role: "user", text: "Next"),
            TranscriptMessage(id: "stream:x", role: "assistant", text: "Historical id")
        ]
        session.messages = messages; page.bind(session)
        let document = TranscriptNativeDocument(page: page)
        document.update(snapshot: page.snapshot, actions: TranscriptActions(), environment: TranscriptRowEnvironment())
        session.messages[3].text += " updated"
        document.update(snapshot: page.snapshot, actions: TranscriptActions(), environment: TranscriptRowEnvironment())
        XCTAssertEqual(document.retainedRows.count, 4)
        XCTAssertEqual(Set(document.retainedRows.map(\.itemID)).count, 4)
        XCTAssertFalse(messages[3].isStreaming)
        XCTAssertNil(page.projectionError)
        XCTAssertEqual(page.snapshot?.messages.map(\.id), messages.map(\.id))
        // Prepending, branch replacement and reopening must retain every row.
        session.messages.insert(TranscriptMessage(id: "message:message:block:x", role: "user", text: "Earlier"), at: 0)
        document.update(snapshot: page.snapshot, actions: TranscriptActions(), environment: TranscriptRowEnvironment())
        XCTAssertEqual(document.retainedRows.count, 5)
        session.messages.removeLast()
        document.update(snapshot: page.snapshot, actions: TranscriptActions(), environment: TranscriptRowEnvironment())
        let reopened = TranscriptPage(); reopened.bind(session)
        XCTAssertEqual(page.snapshot?.items, reopened.snapshot?.items)
        let previous = page.snapshot
        session.messages.append(session.messages[0])
        XCTAssertNotNil(page.projectionError)
        XCTAssertEqual(page.snapshot, previous, "Invalid projection is rejected, never silently deduplicated")
        session.messages.removeLast()
        XCTAssertNil(page.projectionError)
    }

    @MainActor func testExplicitStreamingStateKeepsTheSameRowWhenProseArrives() throws {
        let session = SessionDisplay(id: "settle"), page = TranscriptPage()
        session.messages = [TranscriptMessage(id: "stream:literal", role: "assistant", text: "", thinking: "Working", state: "streaming")]
        page.bind(session)
        let document = TranscriptNativeDocument(page: page)
        document.update(snapshot: page.snapshot, actions: TranscriptActions(), environment: TranscriptRowEnvironment())
        let row = try XCTUnwrap(document.retainedRows.first)
        session.messages[0].text = "Finished"; session.messages[0].state = "completed"
        document.update(snapshot: page.snapshot, actions: TranscriptActions(), environment: TranscriptRowEnvironment())
        XCTAssertTrue(document.retainedRows.first === row)
        XCTAssertFalse(session.messages[0].isStreaming)
    }

    @MainActor func testNativeProjectionFailurePublishesAfterReconciliationAndRejectsStaleNotices() async throws {
        let session = SessionDisplay(id: "projection-notice"), page = TranscriptPage()
        session.messages = [TranscriptMessage(id: "one", role: "user", text: "Retained")]
        page.bind(session)
        let document = TranscriptNativeDocument(page: page)
        document.update(snapshot: page.snapshot, actions: TranscriptActions(), environment: TranscriptRowEnvironment())
        var invalid = try XCTUnwrap(page.snapshot)
        invalid.sequence += 1; invalid.items.append(invalid.items[0])
        document.update(snapshot: invalid, actions: TranscriptActions(), environment: TranscriptRowEnvironment())
        XCTAssertNil(page.projectionError, "Never publish inside SwiftUI's native reconciliation")
        XCTAssertEqual(document.retainedRows.count, 1)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNotNil(page.projectionError)
        page.projectionError = nil
        document.update(snapshot: invalid, actions: TranscriptActions(), environment: TranscriptRowEnvironment())
        session.messages[0].text = "Newer valid page"
        document.update(snapshot: page.snapshot, actions: TranscriptActions(), environment: TranscriptRowEnvironment())
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(page.projectionError, "An old failure must not follow the user to a repaired page")
    }

    func testPipeCloseWaitsForAnExecutingReaderAndIsIdempotent() async throws {
        let pipe = Pipe(), queue = DispatchQueue(label: "crash-audit.pipe")
        let entered = expectation(description: "Read entered"), closed = expectation(description: "Descriptor closed once")
        let release = DispatchSemaphore(value: 0), fd = pipe.fileHandleForReading.fileDescriptor
        let reader = HostPipeReader(handle: pipe.fileHandleForReading, queue: queue, receive: { data in
            if !data.isEmpty { entered.fulfill(); _ = release.wait(timeout: .now() + 3) }
        }, failed: { XCTFail("Unexpected read failure") })
        try pipe.fileHandleForWriting.write(contentsOf: Data("hello".utf8))
        await fulfillment(of: [entered], timeout: 2)
        queue.async { reader.close(); reader.close() }
        XCTAssertGreaterThanOrEqual(fcntl(fd, F_GETFD), 0, "Executing read retains descriptor ownership")
        release.signal()
        queue.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(fcntl(fd, F_GETFD), -1); XCTAssertEqual(errno, EBADF); closed.fulfill()
        }
        await fulfillment(of: [closed], timeout: 2)
        try pipe.fileHandleForWriting.close()
    }

    func testRapidHostExitAndSignalsDeliverExitExactlyOnce() async throws {
        for index in 0..<18 {
            let started = expectation(description: "Child \(index) started"), exited = expectation(description: "Child \(index) ended")
            exited.assertForOverFulfill = true
            let transport = HostTransport { event in
                if case .frame(let frame) = event, frame["ready"]?.bool == true { started.fulfill() }
                if case .exited = event { exited.fulfill() }
            }
            let script = index % 3 == 0 ? "printf '{\"ready\":true}\\n'; printf '{\"unfinished\":'" : "printf '{\"ready\":true}\\n'; exec /bin/sleep 4"
            transport.start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], cwd: URL(fileURLWithPath: NSTemporaryDirectory()), environment: [:])
            await fulfillment(of: [started], timeout: 2)
            if index % 3 != 0, let pid = transport.processIdentifier { kill(pid, index % 3 == 1 ? SIGTERM : SIGKILL) }
            transport.stop(); transport.stop()
            await fulfillment(of: [exited], timeout: 3)
        }
    }
}
