import XCTest
import SwiftUI
import AppKit
import CoreServices
@testable import PiApp

/// The Git panel's tests that hold a wall-clock figure in Debug: a long patch
/// opens without stalling the panel, a hostile diff is read in bounded time, a
/// file saved on disk shows within about a second, and git's reads leave the
/// rest of the app its threads. They run in the serial lane
/// (`scripts/test-lanes.py`), where nothing else shares the machine.
final class GitPanelTimingTests: GitPanelTestCase, SerialTestLane {
    /// A 20,000-line patch, unified and side by side, wide and narrow.
    @MainActor func testALongPatchDrawsAtEveryWidthInBothLayouts() throws {
        let lines = (0..<20_000).map { index -> String in
            switch index % 4 {
            case 0: return "-removed \(index) " + String(repeating: "x", count: 400)
            case 1: return "+added \(index)\twith\ttabs"
            case 2: return " context \(index) 中文 🌍"
            default: return " plain \(index)"
            }
        }
        let patch = "diff --git a/long.txt b/long.txt\n--- a/long.txt\n+++ b/long.txt\n@@ -1,20000 +1,20000 @@\n" + lines.joined(separator: "\n") + "\n"
        let files = GitDiffParser.parse(patch)
        XCTAssertEqual(files.count, 1)
        for (label, width) in [("wide", CGFloat(1_180)), ("narrow", CGFloat(420))] {
            for split in [false, true] {
                let holder = DiffHolder()
                let view = DiffView(files: files, title: "long.txt", subtitle: "Working tree versus index", identity: "audit",
                                    split: Binding(get: { split }, set: { _ in }), expanded: Binding(get: { holder.expanded }, set: { holder.expanded = $0 }))
                var window: NSWindow!
                let building = milliseconds { window = host(view, width: width, height: 700) }
                let cost = milliseconds {
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.contentView?.displayIfNeeded()
                }
                // And with the gate opened: every row of the patch on screen.
                holder.expanded = "audit"
                let whole = milliseconds {
                    window.contentView?.needsLayout = true
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.contentView?.displayIfNeeded()
                }
                let closing = milliseconds { window.contentView = nil; window.close() }
                print(String(format: "PERF 20000-line patch, %@ %@: build %.0f ms, layout %.0f ms, whole diff %.0f ms, close %.0f ms",
                             label, split ? "split" : "unified", building, cost, whole, closing))
                XCTAssertLessThan(building + cost, 4_000, "opening a long patch must not stall the panel")
                XCTAssertLessThan(whole, 4_000, "and neither must asking for the whole of it")
            }
        }
    }

    /// What a diff can contain: CRLF, bytes that are not UTF-8 at all, a line
    /// thousands of characters long, and a file with no newline at the end.
    @MainActor func testDiffsSurviveCRLFForeignBytesAndVeryLongLines() async throws {
        let root = try repository("git-bytes"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try Data("first\r\nsecond\r\nthird\r\n".utf8).write(to: root.appendingPathComponent("crlf.txt"))
        try Data([0x68, 0x69, 0x0a, 0xff, 0xfe, 0x80, 0x0a, 0x62, 0x79, 0x65, 0x0a]).write(to: root.appendingPathComponent("latin.txt"))
        try Data((String(repeating: "L", count: 20_000) + "\n").utf8).write(to: root.appendingPathComponent("long.txt"))
        try Data("no trailing newline".utf8).write(to: root.appendingPathComponent("tail.txt"))
        try git(["add", "-A"], in: root); try git(["commit", "-q", "-m", "Seed odd bytes"], in: root)
        try Data("first\r\nsecond changed\r\nthird\r\n".utf8).write(to: root.appendingPathComponent("crlf.txt"))
        try Data([0x68, 0x69, 0x0a, 0xff, 0xfe, 0x81, 0x0a, 0x62, 0x79, 0x65, 0x0a]).write(to: root.appendingPathComponent("latin.txt"))
        try Data((String(repeating: "L", count: 19_000) + String(repeating: "M", count: 1_000) + "\n").utf8).write(to: root.appendingPathComponent("long.txt"))
        try Data("no trailing newline at all".utf8).write(to: root.appendingPathComponent("tail.txt"))

        let service = GitService()
        let discovered = await service.repositoryRoot(of: root.path)
        let top = try XCTUnwrap(discovered)
        let crlf = try await service.diffFiles(in: top, paths: ["crlf.txt"], staged: false)
        let lines = try XCTUnwrap(crlf.first?.hunks.first?.lines)
        XCTAssertEqual(lines.count, 4, "a file with Windows endings is four rows, not one: \(lines.map(\.text))")
        XCTAssertEqual(lines.map(\.kind), [.context, .removed, .added, .context])
        XCTAssertEqual(lines.map(\.text), ["first", "second", "second changed", "third"])
        XCTAssertEqual(lines.map(\.oldNumber), [1, 2, nil, 3])
        XCTAssertEqual(lines.map(\.newNumber), [1, nil, 2, 3])

        let latin = try await service.diffFiles(in: top, paths: ["latin.txt"], staged: false)
        XCTAssertFalse(latin.isEmpty, "bytes that are not UTF-8 still produce a readable diff")
        XCTAssertEqual(latin.first?.path, "latin.txt")

        let long = try await service.diffFiles(in: top, paths: ["long.txt"], staged: false)
        let longest = long.first?.hunks.first?.lines.map(\.text.count).max() ?? 0
        XCTAssertGreaterThan(longest, 19_000, "a very long line arrives whole")
        XCTAssertEqual(long.first?.added, 1)

        let tail = try await service.diffFiles(in: top, paths: ["tail.txt"], staged: false)
        XCTAssertTrue(tail.first?.hunks.first?.lines.contains { $0.kind == .note } == true, "the missing final newline is noted")

        // And all four render in one pane without stalling.
        let files = crlf + latin + long + tail
        let holder = DiffHolder()
        let view = DiffView(files: files, title: "Four awkward files", subtitle: nil, identity: "bytes",
                            split: Binding(get: { true }, set: { _ in }), expanded: Binding(get: { holder.expanded }, set: { holder.expanded = $0 }))
        var window: NSWindow!
        let cost = milliseconds {
            window = host(view, width: 520, height: 600)
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
        defer { window.contentView = nil; window.close() }
        print(String(format: "PERF diff pane with CRLF, foreign bytes and a 20000-character line: %.0f ms", cost))
        XCTAssertLessThan(cost, 3_000)
    }

    /// The reader saves a file in their editor. The panel must show it without
    /// being told, and without waiting long.
    @MainActor func testAFileSavedOnDiskAppearsWithoutPressingRefresh() async throws {
        let root = try repository("git-watch"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        try "seed\n".write(to: root.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Seed"], in: root)
        let controller = GitController(roots: [root.path])
        try await eventually("settle on a clean tree") { controller.repositoryRoot != nil && !controller.loading }
        XCTAssertTrue(controller.isWatching, "the panel watches the working tree while it is open")
        XCTAssertTrue(controller.status.entries.isEmpty)

        let started = ProcessInfo.processInfo.systemUptime
        try "edited in another editor\n".write(to: root.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try await eventually("see the saved file", timeout: 5) { controller.status.entries.map(\.path) == ["seed.txt"] }
        let delay = (ProcessInfo.processInfo.systemUptime - started) * 1000
        print(String(format: "PERF a file saved on disk reached the changes list in %.0f ms", delay))
        XCTAssertLessThan(delay, 2_000, "about a second, not a Refresh press")
        XCTAssertGreaterThanOrEqual(controller.automaticRefreshes, 1)
        XCTAssertEqual(controller.notice, "")
    }

    /// Blocking on a process inside Swift's cooperative pool takes one of its
    /// few threads out of circulation: a handful of git reads used to stall
    /// every other task in the app for seconds.
    func testConcurrentGitReadsDoNotStallUnrelatedTasks() async throws {
        let root = try repository("git-stall"); defer { try? FileManager.default.removeItem(at: root) }
        try start(root)
        let service = GitService()
        let start = ProcessInfo.processInfo.systemUptime
        let reads = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<24 {
                    group.addTask { _ = try? await service.run(["-c", "alias.wait=!sleep 1", "wait"], in: root.path, timeout: 30) }
                }
                await group.waitForAll()
            }
        }
        let unrelated = Task(priority: .userInitiated) { () -> Double in
            for _ in 0..<50 { await Task.yield() }
            return (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        let latency = await unrelated.value
        print(String(format: "PERF unrelated task while 24 git reads are in flight: %.0f ms", latency))
        XCTAssertLessThan(latency, 600, "git reads must not own the cooperative threads the rest of the app runs on")
        await reads.value
        let total = (ProcessInfo.processInfo.systemUptime - start) * 1000
        print(String(format: "PERF 24 concurrent one-second git reads finished in %.0f ms", total))
        XCTAssertLessThan(total, 6_000)
    }
}
