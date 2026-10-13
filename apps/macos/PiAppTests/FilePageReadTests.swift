import Foundation
import XCTest
@testable import FileView

final class FilePageReadTests: XCTestCase {
    private actor Gate {
        var entered = 0
        var continuations: [CheckedContinuation<Void, Never>] = []
        var open = false
        func wait() async {
            entered += 1
            if !open { await withCheckedContinuation { continuations.append($0) } }
        }
        func release() { open = true; let held = continuations; continuations = []; for item in held { item.resume() } }
    }

    @MainActor private func ready(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "page-read fixture did not finish")
    }

    @MainActor func testQueuedShortPageBecomingLongIsReplannedWithoutLosingItsHold() async throws {
        for held in [false, true] {
            let prefix = String(repeating: "head\n", count: 128)
            let longBytes = 4 << 20, provisionalUnits = 40 << 10
            let content = prefix + String(repeating: "x", count: longBytes) + "\n" + String(repeating: "tail\n", count: 256)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("growing-page-\(UUID().uuidString).txt")
            try content.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }
            let chunks = Gate(), pages = Gate()
            var options = FileDocument.Options()
            options.firstPublishBytes = prefix.utf8.count + provisionalUnits
            options.maximumPageReads = 1
            options.cacheUnits = held ? 1 : 256 << 10
            options.beforeChunk = { offset in if offset > 0 { await chunks.wait() } }
            options.beforePage = { await pages.wait() }
            let document = FileDocument(url: url, options: options)
            defer { document.close(); Task { await chunks.release(); await pages.release() } }
            try await ready { document.lineCount == 129 && document.utf16Length(ofLine: 128) == provisionalUnits }
            XCTAssertEqual(document.status, .indexing)
            // Occupy the only worker with an earlier, already closed page.
            XCTAssertNil(document.text(ofLine: 0, range: 0..<4))
            let columns = ((32 << 10) - 8)..<((32 << 10) + 8)
            var hold: FileTextHold?
            if held {
                let result = document.holding { document.text(ofLine: 128, range: columns) }
                XCTAssertNil(result.0); hold = try XCTUnwrap(result.1)
            } else {
                XCTAssertNil(document.text(ofLine: 128, range: columns))
            }
            defer { hold?.release() }
            XCTAssertEqual(document.activePageReads, 1)
            XCTAssertEqual(document.queuedPageReads, 1)
            // The queued page's first line now grows past the long-line
            // threshold, while no queued read can start.
            await chunks.release()
            try await ready { document.status == .ready }
            XCTAssertEqual(document.utf16Length(ofLine: 128), longBytes)
            document.showScreen(lines: 200...210, columns: 0..<4)
            await pages.release()
            try await ready { document.readsUnderWay == 0 }
            print("FILE_READ replan held=\(held) bytes=\(document.bytesRead) windows=\(document.windowRequests) cache=\(document.cachedCost)")
            XCTAssertLessThan(document.bytesRead, 128 << 10, "a queued short request must not read the completed 4 MiB line")
            XCTAssertLessThan(document.cachedCost, 128 << 10)
            XCTAssertGreaterThan(document.windowRequests, 0, "the stale page must become bounded windows")
            XCTAssertLessThanOrEqual(document.windowRequests, 4)
            XCTAssertEqual(document.text(ofLine: 128, range: columns), String(repeating: "x", count: columns.count),
                           "the original request must be ready, including all held windows under cache pressure")
            XCTAssertEqual(document.holdsKept, held ? 1 : 0)
            hold?.release()
            XCTAssertEqual(document.holdsKept, 0)
        }
    }

    @MainActor func testViewportReadsAreBoundedAndObsoletePagesAndWindowsDoNotRead() async throws {
        for longLine in [false, true] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("page-queue-\(UUID().uuidString).txt")
            let content = longLine ? String(repeating: "x", count: 8 << 20) : (0..<100_000).map { "line \($0)" }.joined(separator: "\n")
            try content.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }
            let gate = Gate()
            var options = FileDocument.Options()
            options.maximumPageReads = 2
            options.beforePage = { await gate.wait() }
            let document = FileDocument(url: url, options: options)
            defer { document.close(); Task { await gate.release() } }
            try await ready { document.status == .ready }
            for step in 0..<100 {
                if longLine { document.showScreen(lines: 0...0, columns: (step * 65_536)..<(step * 65_536 + 80)) }
                else { document.showScreen(lines: (step * 900)...(step * 900 + 10), columns: 0..<80) }
            }
            // Let the bounded workers enter an intentionally uncancellable
            // storage gate. Cancelling a request must not free its slot early.
            let deadline = ContinuousClock.now + .seconds(10)
            while await gate.entered == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            let entered = await gate.entered
            print("FILE_READ long=\(longLine) held workers=\(entered) queued=\(document.queuedPageReads)")
            XCTAssertGreaterThan(entered, 0)
            XCTAssertLessThanOrEqual(entered, 2)
            XCTAssertLessThanOrEqual(document.activePageReads, 2)
            XCTAssertLessThanOrEqual(document.queuedPageReads, 3, "only the last viewport and its read-ahead remain")
            await gate.release()
            try await ready { document.readsUnderWay == 0 }
            let line = longLine ? 0 : 89_100, column = longLine ? 99 * 65_536 : 0
            XCTAssertNotNil(document.text(ofLine: line, range: column..<(column + 4)))
            XCTAssertLessThanOrEqual(document.pageLoads + document.windowRequests, 5, "obsolete queued viewports never start")
            XCTAssertLessThan(document.bytesRead, 512 << 10, "obsolete active reads stop before disk I/O")
        }
    }

    @MainActor func testExplicitHoldsSurviveViewportReplacementAndCloseCancelsTheQueue() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("page-hold-\(UUID().uuidString).txt")
        try (0..<10_000).map { "line \($0)" }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let gate = Gate()
        var options = FileDocument.Options(); options.maximumPageReads = 1; options.beforePage = { await gate.wait() }
        let document = FileDocument(url: url, options: options)
        defer { document.close(); Task { await gate.release() } }
        try await ready { document.status == .ready }
        document.showScreen(lines: 0...10, columns: 0..<80)
        let (missing, hold) = document.holding { document.text(ofLine: 5_000, range: 0..<9) }
        XCTAssertNil(missing); XCTAssertNotNil(hold)
        document.showScreen(lines: 9_000...9_010, columns: 0..<80)
        await gate.release()
        try await ready { document.readsUnderWay == 0 }
        XCTAssertEqual(document.text(ofLine: 5_000, range: 0..<9), "line 5000")
        XCTAssertEqual(document.text(ofLine: 9_000, range: 0..<9), "line 9000")
        hold?.release()

        let closedGate = Gate()
        options.beforePage = { await closedGate.wait() }
        let closing = FileDocument(url: url, options: options)
        try await ready { closing.status == .ready }
        closing.showScreen(lines: 0...1_000, columns: 0..<80)
        closing.close()
        await closedGate.release()
        try await ready { closing.readsUnderWay == 0 }
        XCTAssertEqual(closing.bytesRead, 0)
        XCTAssertEqual(closing.queuedPageReads, 0)
    }
}
