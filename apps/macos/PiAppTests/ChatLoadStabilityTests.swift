import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// Opening a chat, in the window, with the packaged helper and the synthetic
/// gateway: what the reader sees from the first painted rows until the chat
/// has settled, the helper's own rows included. Nothing on screen may move or
/// change once shown, other than by what the reader does.
final class ChatLoadStabilityTests: XCTestCase, SerialTestLane {
    private typealias Setup = GatewayWorkspace

    @MainActor private func setup() async throws -> Setup {
        try await gatewayWorkspace("chat-load", projectID: "chat-load-project", readme: true)
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

    /// A launch: a new model over the same state, in a window, restored as the app does.
    @MainActor private func launch(_ setup: Setup) async -> Launched {
        let model = WorkspaceModel(stateRoot: setup.state, vault: setup.vault)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = WorkspaceRootView(model: model)
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
        return !view.hasWork && !view.loading && view.messages.last?.role == "assistant" && view.messages.last?.isStreaming == false
    }

    /// One sample of the page: the rows on screen, where they are in the
    /// viewport, and the rows the display holds.
    private struct Sample {
        var at: Double
        var shown: [String: (y: CGFloat, height: CGFloat)]
        var messages: [String: Data]
        var ids: [String]
    }

    @MainActor private func sample(_ launched: Launched, _ id: String, since start: Double) -> Sample {
        let view = launched.model.displays[id]
        var shown: [String: (y: CGFloat, height: CGFloat)] = [:]
        if let document = launched.document, let clip = launched.scroll?.contentView {
            let visible = document.convert(clip.bounds, from: clip)
            for row in document.retainedRows where row.superview === document && row.isHosted && !row.isHidden && row.frame.intersects(visible) {
                shown[row.itemID] = (row.frame.minY - visible.minY, row.frame.height)
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var messages: [String: Data] = [:]
        for message in view?.messages ?? [] { messages[message.id] = try? encoder.encode(message) }
        return Sample(at: ProcessInfo.processInfo.systemUptime - start, shown: shown, messages: messages, ids: view?.messages.map(\.id) ?? [])
    }

    /// The fields of a row that differ between two encodings of it.
    private func changedFields(_ before: Data, _ after: Data) -> [String] {
        guard let lhs = try? JSONSerialization.jsonObject(with: before) as? [String: Any],
              let rhs = try? JSONSerialization.jsonObject(with: after) as? [String: Any] else { return ["<unreadable>"] }
        return Set(lhs.keys).union(rhs.keys).sorted().filter { key in
            switch (lhs[key], rhs[key]) {
            case (nil, nil): return false
            case let (l?, r?): return !(NSDictionary(dictionary: ["v": l]).isEqual(to: ["v": r]))
            default: return true
            }
        }
    }

    /// A chat with tool calls, long answers and cost on its replies, opened
    /// after a relaunch. Its rows are drawn once, at their final height and
    /// place: the cost and usage under each reply are there from the first
    /// frame, and neither the refresh after it nor the helper's own rows
    /// change or move anything. Before, each reply grew by its usage line a
    /// moment after it appeared, which pushed every row on screen, and the
    /// helper's rows differed from the journal's in their state, so all were
    /// drawn again when they arrived.
    @MainActor func testOpeningAChatShowsItsRowsOnceAndDoesNotMoveThem() async throws {
        let setup = try await setup()
        let first = await launch(setup)
        await first.model.restore()
        first.model.selectedWorkspaceID = setup.workspace.id; first.model.profileChoice = setup.profile.id
        let chat = ChatRecord(id: "chat-" + UUID().uuidString, workspaceID: setup.workspace.id, title: "Loading", path: nil, profileID: setup.profile.id)
        first.model.chats = [chat]; try await first.model.store?.put(chat, kind: "chat", id: chat.id)
        await first.model.select(chat.id)
        for text in ["Please read fixture README.md", "A large answer, please", "And a short one"] {
            first.model.displays[chat.id]?.draft = text; first.model.send(sessionID: chat.id)
            await waitFor("“\(text)” never finished") { quiet(first.model.displays[chat.id]) }
        }
        try await quit(first.model)

        let second = await launch(setup)
        // The helper is opened below, at a known moment, not by the context meter.
        second.model.automaticContextOperation = { _, _ in throw CancellationError() }
        let start = ProcessInfo.processInfo.systemUptime
        var samples: [Sample] = []
        let restoring = Task { @MainActor in await second.model.restore() }
        func watch(for seconds: Double) async throws {
            let until = ProcessInfo.processInfo.systemUptime + seconds
            while ProcessInfo.processInfo.systemUptime < until {
                samples.append(sample(second, chat.id, since: start))
                try await Task.sleep(for: .milliseconds(4))
            }
        }
        await waitFor("The chat never became ready") { second.model.displays[chat.id]?.historyState == .ready }
        // The refresh of its cost and usage, after it is shown.
        try await watch(for: 1.5)
        await restoring.value
        // The helper opens, as a send or the context meter opens it, and its
        // rows meet the journal's.
        let item = try XCTUnwrap(second.model.record(chat.id))
        _ = try await second.model.open(item)
        second.model.refresh(chat.id)
        try await watch(for: 2)
        XCTAssertTrue(second.model.opened.contains(chat.id), "The helper opened the chat")

        guard let shownAt = samples.firstIndex(where: { !$0.shown.isEmpty }) else { return XCTFail("No rows were ever on screen") }
        let firstShown = samples[shownAt]
        let replies = firstShown.messages.values.compactMap { try? JSONDecoder().decode(TranscriptMessage.self, from: $0) }.filter { $0.role == "assistant" }
        XCTAssertTrue(replies.contains { $0.accounting != nil }, "The replies' cost and usage are on them from the first frame")
        var changes: [String] = []
        for (previous, next) in zip(samples[shownAt...], samples[(shownAt + 1)...]) {
            let at = String(format: "%.3f s", next.at)
            if previous.ids != next.ids { changes.append("\(at): the rows became \(next.ids.count), from \(previous.ids.count)") }
            for (id, data) in next.messages { if let was = previous.messages[id], was != data {
                changes.append("\(at): row \(id.prefix(8)) changed \(changedFields(was, data))")
            } }
            for (id, place) in next.shown { if let was = previous.shown[id], abs(was.y - place.y) > 0.5 || abs(was.height - place.height) > 0.5 {
                changes.append(String(format: "%@: row %@ moved from y %.0f to %.0f, height %.0f to %.0f", at, String(id.prefix(8)), was.y, place.y, was.height, place.height))
            } }
        }
        XCTAssertEqual(Array(changes.prefix(12)), [], "Once shown, the chat's rows neither change nor move (\(changes.count) changes)")
    }
}
