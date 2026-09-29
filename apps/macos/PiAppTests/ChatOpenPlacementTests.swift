import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// Opening a chat from the sidebar: where its rows are drawn first, and that
/// they stay there.
final class ChatOpenPlacementTests: XCTestCase, SerialTestLane {
    @MainActor private struct Setup {
        let root: URL, state: URL
        let vault: ConfigurationVault
        let workspace: WorkspaceRecord, profile: ProfileRecord
    }

    @MainActor private func setup() async throws -> Setup {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let script = repository.appendingPathComponent("fixtures/native/ui-gateway.py")
        guard FileManager.default.isReadableFile(atPath: script.path) else { throw XCTSkip("The synthetic gateway fixture is unavailable") }
        let root = scratchRoot("chat-open-placement")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let gateway = Process(), pipe = Pipe()
        gateway.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        gateway.arguments = ["-u", script.path]
        gateway.currentDirectoryURL = root; gateway.standardOutput = pipe; gateway.standardError = FileHandle.nullDevice
        gateway.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": root.path]
        try gateway.run()
        addTeardownBlock { gateway.terminate(); gateway.waitUntilExit() }
        let handle = pipe.fileHandleForReading
        let greeting = await Task.detached { handle.availableData }.value
        let port = try XCTUnwrap(try JSONDecoder().decode([String: Int].self, from: greeting)["port"])
        let base = "http://127.0.0.1:\(port)"
        let workspace = WorkspaceRecord(id: "chat-open-project", path: root.appendingPathComponent("project").path, trusted: true)
        try FileManager.default.createDirectory(atPath: workspace.path, withIntermediateDirectories: true)
        try Data("Synthetic UI fixture file: read-tool round trip verified.\n".utf8).write(to: URL(fileURLWithPath: workspace.path).appendingPathComponent("README.md"))
        var profile = ProfileRecord()
        profile.api = "openai-responses"; profile.baseUrl = base; profile.modelId = "ui-fixture"; profile.catalogUrl = base + "/catalog"
        profile.name = "Fixture"; profile.contextWindow = 2_000_000; profile.maxOutputTokens = 300_000; profile.modelOutputLimit = 300_000
        var configuration = VaultConfiguration()
        configuration.workspaces = [workspace]
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-loopback-only-key")]
        configuration.automaticUpdateChecks = false
        configuration.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)])
        let vault = ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration)))
        return Setup(root: root, state: root.appendingPathComponent("app-state"), vault: vault, workspace: workspace, profile: profile)
    }

    @MainActor private final class Launched {
        let model: WorkspaceModel, window: NSWindow, hosted: NSView
        init(model: WorkspaceModel, window: NSWindow, hosted: NSView) { self.model = model; self.window = window; self.hosted = hosted }
        func views<T: NSView>(_ type: T.Type, in view: NSView? = nil) -> [T] {
            let view = view ?? hosted
            return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
        }
        var scroll: NSScrollView? { views(TranscriptSurfaceMarker.self).first?.enclosingScrollView }
        var document: TranscriptNativeDocument? { scroll?.documentView as? TranscriptNativeDocument }
    }

    @MainActor private func launch(_ setup: Setup) async -> Launched {
        let model = WorkspaceModel(stateRoot: setup.state, vault: setup.vault)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil; window.close()
            model.report.suspend(); model.shutdown()
            for host in model.hosts.values { try? await host.shutdownAndWait() }
            try? await model.traces.close(); await model.store?.close()
        }
        return Launched(model: model, window: window, hosted: hosted)
    }

    @MainActor private func quit(_ model: WorkspaceModel) async throws {
        await waitFor("The model still had work in flight when the test quit") { !model.hasActiveWork }
        let lifecycle = ApplicationLifecycle()
        lifecycle.model = model
        var answers: [Bool] = []
        lifecycle.answerTermination = { answers.append($0) }
        XCTAssertEqual(lifecycle.applicationShouldTerminate(NSApp), .terminateLater)
        await waitFor("Quitting never answered") { !answers.isEmpty }
        model.report.suspend()
        try await model.traces.close(); await model.store?.close()
    }

    @MainActor private func waitFor(_ what: String, seconds: Double = 60, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(what, file: file, line: line)
    }

    @MainActor private func quiet(_ view: SessionDisplay?) -> Bool {
        guard let view else { return false }
        return !view.hasWork && !view.loading && !view.busy && view.state == "idle" && view.taskPresentation?.active == nil
            && view.sendingRows.isEmpty && view.queue.isEmpty && view.messages.last?.role == "assistant" && view.messages.last?.isStreaming == false
    }

    private struct Sample { var at: Double; var shown: [String: (y: CGFloat, height: CGFloat)] }

    @MainActor private func sample(_ launched: Launched, since start: Double) -> Sample {
        var shown: [String: (y: CGFloat, height: CGFloat)] = [:]
        if let document = launched.document, let clip = launched.scroll?.contentView {
            let visible = document.convert(clip.bounds, from: clip)
            for row in document.retainedRows where row.superview === document && row.isHosted && !row.isHidden && row.frame.intersects(visible) {
                shown[row.itemID] = (row.frame.minY - visible.minY, row.frame.height)
            }
        }
        return Sample(at: ProcessInfo.processInfo.systemUptime - start, shown: shown)
    }

    /// Opens `id` from the sidebar while another chat is on screen, and
    /// watches the page from the new chat's first rows for `seconds`: every
    /// movement of a row once drawn, and where the rows were at the end.
    @MainActor private func open(_ id: String, in launched: Launched, for seconds: Double = 2.5) async throws -> (changes: [String], last: Sample) {
        let start = ProcessInfo.processInfo.systemUptime
        let before = Set(launched.document?.retainedRows.map(\.itemID) ?? [])
        Task { @MainActor in await launched.model.select(id) }
        var samples: [Sample] = []
        while ProcessInfo.processInfo.systemUptime - start < seconds {
            samples.append(sample(launched, since: start))
            try await Task.sleep(for: .milliseconds(4))
        }
        let last = samples.last ?? Sample(at: 0, shown: [:])
        // The new chat's rows: rows the chat shown before did not have.
        guard let shownAt = samples.firstIndex(where: { !$0.shown.isEmpty && !$0.shown.keys.contains(where: before.contains) }) else { return (["never drawn"], last) }
        var changes: [String] = []
        for (previous, next) in zip(samples[shownAt...], samples[(shownAt + 1)...]) {
            for (row, place) in next.shown { if let was = previous.shown[row], abs(was.y - place.y) > 0.5 || abs(was.height - place.height) > 0.5 {
                changes.append(String(format: "%.3f s: row %@ moved from y %.1f to %.1f, height %.1f to %.1f", next.at, String(row.prefix(14)), was.y, place.y, was.height, place.height))
            } }
        }
        return (changes, last)
    }

    /// Found by `SoakTests`. A chat opened from the sidebar was drawn first
    /// where the chat shown before it was scrolled to, and moved to its own
    /// place a few frames later, thousands of points at once. A chat whose
    /// last turn is taller than the pane opened at its end the first time
    /// and at the question that started that turn when revisited, where it
    /// was drawn and then taken to its end; and held there, it shook by the
    /// difference whenever a row above it was measured again. Now each chat
    /// is drawn once where it stays, and the same place every time: at the
    /// question of a turn taller than the pane, at the end otherwise.
    @MainActor func testAChatOpenedFromTheSidebarIsDrawnWhereItStays() async throws {
        let setup = try await setup()
        let first = await launch(setup)
        await first.model.restore()
        first.model.selectedWorkspaceID = setup.workspace.id; first.model.profileChoice = setup.profile.id
        func chat(_ name: String) -> ChatRecord { ChatRecord(id: "chat-\(name)-" + UUID().uuidString, workspaceID: setup.workspace.id, title: name, path: nil, profileID: setup.profile.id) }
        let shorter = chat("shorter"), longer = chat("longer"), endsLong = chat("endslong")
        let turns: [(ChatRecord, [String])] = [
            (shorter, ["Please read fixture README.md", "Please write bulk 12 now", "And a short one"]),
            (longer, ["Please read fixture README.md", "Please write bulk 20 now", "And a short one"]),
            (endsLong, ["Please read fixture README.md", "And a short one", "Please write bulk 16 now"]),
        ]
        for (chat, texts) in turns {
            first.model.chats.append(chat); try await first.model.store?.put(chat, kind: "chat", id: chat.id)
            await first.model.select(chat.id)
            for text in texts {
                first.model.displays[chat.id]?.draft = text; first.model.send(sessionID: chat.id)
                await waitFor("“\(text)” never finished") { quiet(first.model.displays[chat.id]) }
            }
        }
        await first.model.select(shorter.id)
        try await quit(first.model)

        let second = await launch(setup)
        await second.model.restore()
        await waitFor("The reopened chat never became ready") { second.model.displays[shorter.id]?.historyState == .ready }
        try await Task.sleep(for: .milliseconds(1_000))
        var changes: [String] = []
        func atEnd() -> Bool {
            guard let document = second.document, let clip = second.scroll?.contentView else { return false }
            return document.frame.height - clip.bounds.maxY < 1
        }
        func question(_ sample: Sample) -> CGFloat? {
            second.model.displays[endsLong.id]?.messages.last(where: { $0.role == "user" }).flatMap { sample.shown[$0.id]?.y }
        }
        for (id, name) in [(longer.id, "first open after a scrolled chat"), (shorter.id, "back to the first chat"), (longer.id, "revisit")] {
            let opened = try await open(id, in: second)
            changes += opened.changes.map { name + ": " + $0 }
            XCTAssertTrue(atEnd(), "\(name): a chat whose last turn fits opens at its end")
        }
        for (id, name) in [(endsLong.id, "a chat ending in a long reply"), (shorter.id, "back again"), (endsLong.id, "a chat ending in a long reply, revisited")] {
            let opened = try await open(id, in: second)
            changes += opened.changes.map { name + ": " + $0 }
            if id == endsLong.id {
                XCTAssertEqual(try XCTUnwrap(question(opened.last), "\(name): its last question is on screen"), 12, accuracy: 1,
                               "\(name): a chat whose last turn is taller than the pane opens at the question that started it")
            }
        }
        XCTAssertEqual(Array(changes.prefix(12)), [], "Once drawn, an opened chat's rows stay where they are (\(changes.count) changes)")
    }

    /// Found by `SoakTests`: a chat left while its reply was still arriving
    /// kept the reply as the reader left it, since a chat in the background
    /// is asked for its status and not its rows. Opened again once the run
    /// had finished, it showed the reply unfinished, and moved when the
    /// finished page came: its usage line appeared, its turn's live report
    /// gave way to the settled one. It now opens as it is, once.
    @MainActor func testAChatWhoseReplyFinishedInTheBackgroundOpensAsItIsNow() async throws {
        let setup = try await setup()
        let launched = await launch(setup)
        await launched.model.restore()
        launched.model.selectedWorkspaceID = setup.workspace.id; launched.model.profileChoice = setup.profile.id
        func chat(_ name: String) -> ChatRecord { ChatRecord(id: "chat-\(name)-" + UUID().uuidString, workspaceID: setup.workspace.id, title: name, path: nil, profileID: setup.profile.id) }
        let running = chat("running"), other = chat("other")
        for (chat, texts) in [(other, ["And a short one"]), (running, ["Please read fixture README.md", "And a short one"])] {
            launched.model.chats.append(chat); try await launched.model.store?.put(chat, kind: "chat", id: chat.id)
            await launched.model.select(chat.id)
            for text in texts {
                launched.model.displays[chat.id]?.draft = text; launched.model.send(sessionID: chat.id)
                await waitFor("“\(text)” never finished") { quiet(launched.model.displays[chat.id]) }
            }
        }
        // A long reply starts, and the reader moves on while it arrives.
        let view = try XCTUnwrap(launched.model.displays[running.id])
        view.draft = "A large answer, please"; launched.model.send(sessionID: running.id)
        await waitFor("The long reply never started arriving") { view.messages.last?.isStreaming == true && (view.messages.last?.text.count ?? 0) > 400 }
        await launched.model.select(other.id)
        await waitFor("The long reply never finished in the background", seconds: 90) { !view.busy && view.state == "idle" }
        try await Task.sleep(for: .milliseconds(600))
        let opened = try await open(running.id, in: launched)
        XCTAssertEqual(Array(opened.changes.prefix(12)), [], "The chat opens as it is now, and nothing on it moves (\(opened.changes.count) changes)")
        XCTAssertFalse(view.messages.contains { $0.isStreaming }, "The finished reply is shown finished")
    }
}
