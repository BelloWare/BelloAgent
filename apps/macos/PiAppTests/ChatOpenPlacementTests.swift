import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// Opening a chat from the sidebar: where its rows are drawn first, and that
/// they stay there.
final class ChatOpenPlacementTests: XCTestCase, SerialTestLane {
    private typealias Setup = GatewayWorkspace

    @MainActor private func setup() async throws -> Setup {
        try await gatewayWorkspace("chat-open-placement", projectID: "chat-open-project", readme: true)
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

    /// The rows on screen and where they sit, and how tall the viewport is:
    /// what stands under the conversation (the live turn bar, the composer)
    /// takes its room from the viewport, and the rows of a page following
    /// its end move with it.
    private struct Sample { var at: Double; var shown: [String: (y: CGFloat, height: CGFloat)]; var viewport: CGFloat = 0; var trace = "" }

    @MainActor private func sample(_ launched: Launched, since start: Double) -> Sample {
        var shown: [String: (y: CGFloat, height: CGFloat)] = [:]
        var viewport: CGFloat = 0
        if let document = launched.document, let clip = launched.scroll?.contentView {
            let visible = document.convert(clip.bounds, from: clip)
            viewport = clip.bounds.height
            for row in document.retainedRows where row.superview === document && row.isHosted && !row.isHidden && row.frame.intersects(visible) {
                shown[row.itemID] = (row.frame.minY - visible.minY, row.frame.height)
            }
        }
        let page = launched.views(TranscriptSurfaceMarker.self).first?.page
        let trace = "selected \(launched.model.selectedID?.prefix(10) ?? "-") page \(page?.sessionID?.prefix(10) ?? "-") state \(page?.state ?? "-") bar \(page?.liveTurn.map { "\($0.phase ?? "?")/\($0.live)" } ?? "none") snapshot \(page?.snapshot?.sessionID.prefix(10) ?? "-")"
        return Sample(at: ProcessInfo.processInfo.systemUptime - start, shown: shown, viewport: viewport, trace: trace)
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
        if testEnvironment("PI_PLACEMENT_TRACE") == "1" {
            var last = ""
            for sample in samples.prefix(shownAt + 40) {
                let line = String(format: "%.0f viewport, %ld rows, ", sample.viewport, sample.shown.count) + sample.trace
                if line != last { print(String(format: "PLACEMENT-TRACE %.3f ", sample.at) + line); last = line }
            }
        }
        var changes: [String] = []
        for (previous, next) in zip(samples[shownAt...], samples[(shownAt + 1)...]) {
            if abs(previous.viewport - next.viewport) > 0.5 {
                changes.append(String(format: "%.3f s: the viewport went from %.1f to %.1f pt", next.at, previous.viewport, next.viewport))
            }
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

    /// Found by `SoakTests`: the live turn bar of a chat that is running, or
    /// has just been sent to, stood under the next chat the reader opened,
    /// and went a moment later. The bar takes its room from the
    /// conversation, so the opened chat's rows were drawn over a viewport
    /// 116 pt short and moved down when it went.
    @MainActor func testAChatOpenedWhileAnotherRunsIsDrawnWithoutTheOthersLiveBar() async throws {
        let setup = try await setup()
        let first = await launch(setup)
        await first.model.restore()
        first.model.selectedWorkspaceID = setup.workspace.id; first.model.profileChoice = setup.profile.id
        func chat(_ name: String) -> ChatRecord { ChatRecord(id: "chat-\(name)-" + UUID().uuidString, workspaceID: setup.workspace.id, title: name, path: nil, profileID: setup.profile.id) }
        let running = chat("running"), idle = chat("idle"), other = chat("other")
        for (chat, texts) in [(idle, ["Please read fixture README.md", "And a short one"]), (other, ["And a short one"]), (running, ["And a short one"])] {
            first.model.chats.append(chat); try await first.model.store?.put(chat, kind: "chat", id: chat.id)
            await first.model.select(chat.id)
            for text in texts {
                first.model.displays[chat.id]?.draft = text; first.model.send(sessionID: chat.id)
                await waitFor("“\(text)” never finished") { quiet(first.model.displays[chat.id]) }
            }
        }
        try await quit(first.model)

        let second = await launch(setup)
        await second.model.restore()
        await waitFor("The reopened chat never became ready") { second.model.displays[running.id]?.historyState == .ready }
        try await Task.sleep(for: .milliseconds(800))
        let settled = sample(second, since: 0).viewport
        var changes: [String] = []
        func run(_ text: String) throws {
            let view = try XCTUnwrap(second.model.displays[running.id])
            view.draft = text; second.model.send(sessionID: running.id)
        }
        // A long reply streaming, with its live bar under it: the chat opened
        // next is read in for the first time this launch.
        try run("A large answer, please")
        await waitFor("The long reply never started arriving") { (second.model.displays[running.id]?.messages.last?.text.count ?? 0) > 400 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertLessThan(sample(second, since: 0).viewport, settled - 50, "the running chat's live bar stands under its conversation")
        changes += try await open(idle.id, in: second).changes.map { "opened while another streams: " + $0 }
        // Back to the running chat, then the idle one again: its rows are
        // still on the page (a revisit).
        _ = try await open(running.id, in: second)
        changes += try await open(idle.id, in: second, for: 1.5).changes.map { "revisited while another streams: " + $0 }
        // Its rows stop where the reader left them; its run state does not.
        func finished(_ view: SessionDisplay?) -> Bool { view.map { !$0.busy && !$0.loading && $0.state == "idle" && $0.sendingRows.isEmpty } ?? false }
        await waitFor("The long reply never finished", seconds: 90) { finished(second.model.displays[running.id]) }
        // A message just sent, and the reader away before the helper has it.
        _ = try await open(running.id, in: second, for: 1)
        try run("And a short one")
        changes += try await open(other.id, in: second, for: 1.5).changes.map { "opened just after a send: " + $0 }
        // A chat in the background is asked for its status, not its rows: the
        // message stays a sending row until the chat is shown again.
        _ = try await open(running.id, in: second, for: 0.5)
        await waitFor("The short reply never finished") { quiet(second.model.displays[running.id]) }
        XCTAssertEqual(Array(changes.prefix(12)), [], "An opened chat is drawn at its own height from its first frame (\(changes.count) changes)")
        XCTAssertEqual(sample(second, since: 0).viewport, settled, accuracy: 0.5, "and settles where an idle chat stands")
    }

    /// Found by `SoakTests`: a chat the reader left the moment its reply
    /// ended, before the reply's figures had come, kept its rows without
    /// them — a chat in the background had its totals read, not its rows'
    /// figures. Opened again, those rows were drawn at once, and the reply
    /// grew by its usage line a moment later, moving every row above it.
    @MainActor func testAChatLeftBeforeItsFiguresCameIsDrawnWithThemWhenOpenedAgain() async throws {
        let setup = try await setup()
        let launched = await launch(setup)
        await launched.model.restore()
        launched.model.selectedWorkspaceID = setup.workspace.id; launched.model.profileChoice = setup.profile.id
        func chat(_ name: String) -> ChatRecord { ChatRecord(id: "chat-\(name)-" + UUID().uuidString, workspaceID: setup.workspace.id, title: name, path: nil, profileID: setup.profile.id) }
        let left = chat("left"), other = chat("other")
        for (chat, texts) in [(other, ["And a short one"]), (left, ["Please read fixture README.md", "And a short one"])] {
            launched.model.chats.append(chat); try await launched.model.store?.put(chat, kind: "chat", id: chat.id)
            await launched.model.select(chat.id)
            for text in texts {
                launched.model.displays[chat.id]?.draft = text; launched.model.send(sessionID: chat.id)
                await waitFor("“\(text)” never finished") { quiet(launched.model.displays[chat.id]) }
            }
        }
        let view = try XCTUnwrap(launched.model.displays[left.id])
        await waitFor("The reply's figures never came") { view.messages.last?.accounting != nil }
        try await Task.sleep(for: .milliseconds(500))
        // The reply's rows as they stand when the reader goes on the moment
        // it ends: its figures are in the request log, not yet on the reply.
        let reply = try XCTUnwrap(view.messages.last?.id)
        view.messageAccounting[reply] = nil
        view.messages[view.messages.count - 1].accounting = nil
        _ = try await open(other.id, in: launched, for: 1)
        // Its figures are persisted after the reader has gone on.
        launched.model.scheduleAccounting(left.id, workspaceID: setup.workspace.id)
        try await Task.sleep(for: .milliseconds(600))
        await waitFor("The figures' read never ended") { launched.model.accountingTasks[left.id] == nil }
        let opened = try await open(left.id, in: launched)
        XCTAssertNotNil(view.messages.last?.accounting, "the reply's figures are on it")
        XCTAssertEqual(Array(opened.changes.prefix(12)), [], "The chat is drawn with its figures, and nothing on it moves (\(opened.changes.count) changes)")
    }

    /// Found by the kept-rows soak: a chat revisited after its journal
    /// changed — the reader ran a turn in it since it was read, then went
    /// on — was placed twice: its rows, still on the page, at the question
    /// its last turn started with, and the page read in again at its end.
    /// A revisit lands where a chat opens, once.
    @MainActor func testARevisitAfterTheJournalChangedIsPlacedOnce() async throws {
        let setup = try await setup()
        let launched = await launch(setup)
        await launched.model.restore()
        launched.model.selectedWorkspaceID = setup.workspace.id; launched.model.profileChoice = setup.profile.id
        func chat(_ name: String) -> ChatRecord { ChatRecord(id: "chat-\(name)-" + UUID().uuidString, workspaceID: setup.workspace.id, title: name, path: nil, profileID: setup.profile.id) }
        let changed = chat("changed"), other = chat("other")
        for (chat, texts) in [(other, ["And a short one"]), (changed, ["Please read fixture README.md", "And a short one"])] {
            launched.model.chats.append(chat); try await launched.model.store?.put(chat, kind: "chat", id: chat.id)
            await launched.model.select(chat.id)
            for text in texts {
                launched.model.displays[chat.id]?.draft = text; launched.model.send(sessionID: chat.id)
                await waitFor("“\(text)” never finished") { quiet(launched.model.displays[chat.id]) }
            }
        }
        // Read in, then left: its rows are kept, and its journal as read.
        _ = try await open(other.id, in: launched, for: 1)
        _ = try await open(changed.id, in: launched, for: 1.5)
        // A turn taller than the pane since: the journal is not the one read.
        let view = try XCTUnwrap(launched.model.displays[changed.id])
        view.draft = "Please write bulk 16 now"; launched.model.send(sessionID: changed.id)
        await waitFor("The long turn never finished") { quiet(view) }
        try await Task.sleep(for: .milliseconds(800))
        var changes: [String] = []
        for round in 1...2 {
            _ = try await open(other.id, in: launched, for: 1)
            let opened = try await open(changed.id, in: launched)
            changes += opened.changes.map { "revisit \(round): " + $0 }
            let question = view.messages.last(where: { $0.role == "user" }).flatMap { opened.last.shown[$0.id]?.y }
            XCTAssertEqual(try XCTUnwrap(question, "revisit \(round): its last question is on screen"), 12, accuracy: 1,
                           "revisit \(round): a chat whose last turn is taller than the pane opens at the question that started it")
        }
        XCTAssertEqual(Array(changes.prefix(12)), [], "A revisit is placed once, and nothing on it moves (\(changes.count) changes)")
    }
}
