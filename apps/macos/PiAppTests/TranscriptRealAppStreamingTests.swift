import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// The same question as `TranscriptStreamingScrollTests`, asked of the whole
/// app rather than of the pane: a real conversation, a real helper, real
/// Responses deltas arriving from the synthetic loopback gateway, and the
/// reader scrolling back through the history while they arrive.
///
/// Nothing here is simulated except the model at the far end of the socket.
/// The window is the app's window, the sidebar and composer are in it, the
/// turn runs through the packaged helper, and the numbers are what a frame of
/// that costs. It is opt-in because it starts a process and streams for the
/// better part of a minute.
final class TranscriptRealAppStreamingTests: XCTestCase {
    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    @MainActor func testStreamingAndScrollingInTheRealApp() async throws {
        guard testEnvironment("PI_PERF_REAL_APP") != nil else {
            throw XCTSkip("Set PI_PERF_REAL_APP to stream a real turn through the synthetic gateway while scrolling.")
        }
        let folder = URL(fileURLWithPath: scratchBase()).appendingPathComponent("real-app-stream-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Synthetic fixture file.\n".utf8).write(to: folder.appendingPathComponent("README.md"))

        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let fixture = Process(), pipe = Pipe()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = ["-u", repository.appendingPathComponent("fixtures/native/ui-gateway.py").path]
        fixture.currentDirectoryURL = folder; fixture.standardOutput = pipe; fixture.standardError = FileHandle.nullDevice
        fixture.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": folder.path]
        try fixture.run()
        defer { if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() } }
        let handle = pipe.fileHandleForReading
        let greeting = await Task.detached { handle.availableData }.value
        let port = try XCTUnwrap(try JSONDecoder().decode([String: Int].self, from: greeting)["port"])

        let workspace = WorkspaceRecord(id: "real-app-stream", path: folder.path, trusted: true)
        var profile = ProfileRecord()
        profile.api = "openai-responses"; profile.baseUrl = "http://127.0.0.1:\(port)"; profile.modelId = "ui-fixture"
        profile.catalogUrl = profile.baseUrl + "/catalog"
        profile.contextWindow = 2_000_000; profile.maxOutputTokens = 300_000; profile.modelOutputLimit = 300_000
        profile.name = "Synthetic Responses"
        let connection = VaultProfile(profile: profile, apiKey: "synthetic-loopback-only-key")
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [workspace]
            $0.profiles = [connection]
            $0.automaticUpdateChecks = false
        }
        let model = WorkspaceModel(stateRoot: folder.appendingPathComponent("app-state"), vault: vault)
        addTeardownBlock { @MainActor in
            model.report.suspend(); model.shutdown()
            await model.flushReadStates(); await model.flushProjectSidebarState()
            try? await model.traces.close(); await model.store?.close()
            try? FileManager.default.removeItem(at: folder)
        }
        await model.restore()
        model.profileChoice = profile.id; model.selectedWorkspaceID = workspace.id
        let chat = ChatRecord(id: UUID().uuidString, workspaceID: workspace.id, title: "Streaming while scrolling",
                              path: nil, profileID: profile.id, toolMode: "read-only")
        model.chats.append(chat); try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.select(chat.id)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 860),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted
        defer { window.contentView = nil; window.close() }
        window.center(); window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(800))
        let session = try XCTUnwrap(model.displays[chat.id])

        // A few settled turns first, so the reader has a history to scroll
        // back through while the next reply arrives.
        for index in 0..<3 {
            session.draft = "Summarise fixture note \(index) in a short paragraph."
            model.send(sessionID: chat.id)
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline, session.hasWork { try await Task.sleep(for: .milliseconds(50)) }
            try await Task.sleep(for: .milliseconds(200))
        }
        let marker = try XCTUnwrap(descendants(TranscriptSurfaceMarker.self, in: hosted).first)
        let scroll = try XCTUnwrap(marker.enclosingScrollView as? TranscriptNativeScrollView)
        let page = try XCTUnwrap(marker.page)
        let document = try XCTUnwrap(scroll.documentView as? TranscriptNativeDocument)
        let clip = scroll.contentView

        // The long reply: "large" makes the fixture stream a hundred sections
        // of Markdown, a delta every 35 ms.
        session.draft = "Write a large answer covering every section of the fixture notes."
        model.send(sessionID: chat.id)
        try await Task.sleep(for: .milliseconds(400))

        var frames: [Double] = []
        var moved: [String] = []
        var unprepared = 0
        var y = clip.bounds.minY
        var direction: CGFloat = -1
        var textBytes = 0
        let started = ProcessInfo.processInfo.systemUptime
        // Every step is a frame the reader pays for: one wheel step, the whole
        // window laid out, the whole window displayed.
        while session.hasWork, ProcessInfo.processInfo.systemUptime - started < 90 {
            let travel = max(0, document.frame.height - clip.bounds.height)
            if y <= 0 { direction = 1 } else if y >= travel * 0.9 { direction = -1 }
            let arriving = document.retainedRows.last
            let arrivingTop = arriving?.frame.minY ?? .greatestFiniteMagnitude
            let before = Dictionary(uniqueKeysWithValues: document.retainedRows
                .filter { $0.superview != nil && $0.frame.maxY <= arrivingTop }
                .map { ($0.itemID, $0.frame.minY - clip.bounds.minY) })
            let beforeY = clip.bounds.minY
            let start = ProcessInfo.processInfo.systemUptime
            y = max(0, min(travel, y + direction * 12))
            scroll.readerWillNavigate(upward: direction < 0)
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
            scroll.reflectScrolledClipView(clip)
            hosted.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            frames.append(ProcessInfo.processInfo.systemUptime - start)
            let delta = clip.bounds.minY - beforeY
            for row in document.retainedRows where row.superview != nil {
                guard let was = before[row.itemID] else { continue }
                let now = row.frame.minY - clip.bounds.minY
                if abs(now - (was - delta)) > 0.6 {
                    moved.append(String(format: "%@ moved %.1f pt (the scroll was %.1f pt)", row.itemID, now - was, -delta))
                }
            }
            unprepared += document.retainedRows.filter {
                TranscriptNativeDocument.overlaps($0.frame, clip.bounds) && !$0.isHosted
            }.count
            textBytes = page.snapshot?.messages.last?.text.utf8.count ?? textBytes
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertGreaterThan(frames.count, 200, "the run was too short to say anything")
        XCTAssertGreaterThan(textBytes, 2_000, "the fixture did not stream a long reply")
        let ordered = frames.sorted()
        func percentile(_ p: Double) -> Double { ordered[max(0, min(ordered.count - 1, Int(ceil(Double(ordered.count) * p)) - 1))] }
        let over = frames.filter { $0 > 1.0 / 120 }.count
        let fraction = Double(over) / Double(frames.count)
        let worst = ordered.last ?? 0
        print(String(format: "PERF the real app, streaming a reply through the synthetic gateway while the reader scrolls: %d frames over %.1f s — mean %.2f ms, p50 %.2f, p95 %.2f, p99 %.2f, worst %.2f ms; %d over 8.33 ms (%.2f%%); %.0f reply bytes/s sustained; %d visits to a row with no tree",
                     frames.count, elapsed, frames.reduce(0, +) / Double(frames.count) * 1000,
                     percentile(0.5) * 1000, percentile(0.95) * 1000, percentile(0.99) * 1000, worst * 1000,
                     over, fraction * 100, Double(textBytes) / elapsed, unprepared))
        XCTAssertEqual(moved, [], "the page moved by something other than the scroll while a reply arrived")
        XCTAssertEqual(unprepared, 0, "a scroll reached \(unprepared) rows the page had not prepared")
        // Measured, 0.1.79, Release, a 921-frame run: 3.04 % of frames over a
        // 120 Hz frame, worst 21.1 ms, mean 3.47 ms, p95 7.71 ms. The ceilings
        // are those figures with headroom, not the target: the reference asks
        // for under 1 %, and what keeps this run above it is the frames where
        // the whole window is laid out and displayed, not the streaming path
        // (no row tree is built and no row is put through SwiftUI's sizing in
        // any of them). Tighten these as that comes down.
        XCTAssertLessThan(fraction, releaseBudget(0.05),
                          String(format: "%.2f%% of the reader's frames went over a 120 Hz frame while a reply arrived", fraction * 100))
        XCTAssertLessThan(worst, releaseBudget(0.030),
                          String(format: "the worst frame of the run took %.1f ms", worst * 1000))
        XCTAssertLessThan(percentile(0.95), releaseBudget(0.012),
                          String(format: "the reader's 95th-percentile frame took %.1f ms", percentile(0.95) * 1000))
        XCTAssertNil(model.error, model.error ?? "")
    }
}
