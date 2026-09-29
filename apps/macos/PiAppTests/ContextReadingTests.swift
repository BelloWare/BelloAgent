import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// A chat's context pill shows the reading its helper last counted, and
/// showing the chat again opens no helper while that reading still stands:
/// the same figures, from the first frame, after a relaunch too. Typing, a
/// changed model or limits, and a changed journal count again, as before.
final class ContextReadingTests: XCTestCase {
    private typealias Setup = GatewayWorkspace

    @MainActor private func setup() async throws -> Setup {
        try await gatewayWorkspace("context-reading", projectID: "context-reading-project")
    }

    /// A launch: a new model over the same state, in a window, not yet restored.
    @MainActor private func launch(_ setup: Setup) -> WorkspaceModel {
        let model = WorkspaceModel(stateRoot: setup.state, vault: setup.vault)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceView(model: model))
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil; window.close()
            model.report.suspend(); model.shutdown()
            for host in model.hosts.values { try? await host.shutdownAndWait() }
            try? await model.traces.close(); await model.store?.close()
        }
        return model
    }

    /// ⌘Q: the app's own quit path, which saves before it answers.
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

    /// What the pill draws: the ring's fill and its words.
    @MainActor private func pill(_ model: WorkspaceModel, _ view: SessionDisplay) -> (fraction: Double?, detail: String) {
        let meter = ContextMeterPresentation(context: model.displayedContext(view), capacity: 2_000_000)
        return (meter.fraction, meter.detailLabel)
    }

    /// A chat with one turn, counted by its helper as the reader saw it, then quit.
    @MainActor private func countedChat(_ setup: Setup) async throws -> (chat: ChatRecord, shown: [String: WireValue]) {
        let first = launch(setup)
        await first.restore()
        first.selectedWorkspaceID = setup.workspace.id; first.profileChoice = setup.profile.id
        let chat = ChatRecord(id: "chat-" + UUID().uuidString, workspaceID: setup.workspace.id, title: "Counted", path: nil, profileID: setup.profile.id)
        first.chats = [chat]; try await first.store?.put(chat, kind: "chat", id: chat.id)
        await first.select(chat.id)
        let view = try XCTUnwrap(first.displays[chat.id])
        view.draft = "A question to count"; first.send(sessionID: chat.id)
        await waitFor("The turn never finished") { quiet(first.displays[chat.id]) }
        // The pill counts the next request, as it does for every chat shown.
        await waitFor("The context was never counted and kept") { first.contextReadings[chat.id] != nil && !view.footer.preparingContext }
        let shown = first.displayedContext(view)
        XCTAssertNotNil(ContextMeterPresentation(context: shown, capacity: 2_000_000).fraction, "The pill had a figure")
        XCTAssertEqual(first.contextReadings[chat.id]?.context, shown, "What it showed is what is kept")
        try await quit(first)
        return (chat, shown)
    }

    @MainActor func testAChatCountedOnceShowsItsReadingAfterARelaunchWithoutAHelper() async throws {
        let setup = try await setup()
        let (chat, shown) = try await countedChat(setup)

        let second = launch(setup)
        let restoring = Task { @MainActor in await second.restore() }
        // From the first frame the chat is on screen, its pill shows the reading.
        await waitFor("The chat never came back") { second.displays[chat.id] != nil && second.selectedID == chat.id }
        let view = try XCTUnwrap(second.displays[chat.id])
        XCTAssertEqual(second.displayedContext(view), shown, "The first frame shows the figures it had")
        XCTAssertFalse(view.footer.preparingContext, "and never says it is calculating")
        await restoring.value
        await waitFor("The chat never became ready") { view.historyState == .ready }
        // Long enough for the automatic count to have started the helper.
        let until = Date().addingTimeInterval(2)
        while Date() < until {
            XCTAssertEqual(second.displayedContext(view), shown, "The figures do not change")
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(second.hosts.isEmpty, "Showing the chat started no helper")
        XCTAssertFalse(second.opened.contains(chat.id))

        // Counted by its helper now, on purpose: the figures are the same.
        let before = pill(second, view)
        _ = try await second.preparedContext(chat.id)
        XCTAssertFalse(second.hosts.isEmpty)
        let after = pill(second, view)
        XCTAssertEqual(after.fraction, before.fraction, "The helper counts what the saved reading showed")
        XCTAssertEqual(after.detail, before.detail)

        // The helper goes, as an idle one does: the pill keeps its figures and
        // nothing opens it again.
        let host = try XCTUnwrap(second.hosts[chat.workspaceID])
        try await host.shutdownAndWait()
        await waitFor("The helper's exit was never seen") { !second.opened.contains(chat.id) }
        let settled = Date().addingTimeInterval(2)
        while Date() < settled {
            XCTAssertEqual(pill(second, view).fraction, before.fraction, "The figures stay when the helper goes")
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(second.opened.contains(chat.id), "and the chat is not opened again to count them")
    }

    @MainActor func testTypingStillCountsTheDraft() async throws {
        let setup = try await setup()
        let (chat, shown) = try await countedChat(setup)
        let second = launch(setup)
        await second.restore()
        let view = try XCTUnwrap(second.displays[chat.id])
        await waitFor("The chat never became ready") { view.historyState == .ready }
        XCTAssertEqual(second.displayedContext(view), shown)
        view.draft = String(repeating: "A longer draft to count. ", count: 40); second.draftChanged(view)
        await waitFor("Typing never counted the draft") { view.footer.preparedContext != nil && !view.footer.preparingContext }
        XCTAssertFalse(second.hosts.isEmpty, "Counting a draft opens the helper, as before")
        let counted = try XCTUnwrap(second.displayedContext(view)["tokens"]?.number), saved = try XCTUnwrap(shown["tokens"]?.number)
        XCTAssertGreaterThan(counted, saved, "The draft is part of the count")
    }

    @MainActor func testAChangedModelOrJournalCountsAgain() async throws {
        let setup = try await setup()
        let (chat, _) = try await countedChat(setup)

        // Another context window: the saved reading was not counted for it.
        let second = launch(setup)
        await second.restore()
        var changed = try XCTUnwrap(second.record(chat.id)); changed.contextWindow = 1_000_000
        if let index = second.chats.firstIndex(where: { $0.id == chat.id }) { second.chats[index] = changed }
        try await second.store?.put(changed, kind: "chat", id: chat.id)
        await second.select(chat.id)
        let view = try XCTUnwrap(second.displays[chat.id])
        XCTAssertNil(second.servingContextReading(view), "A reading counted for another window does not stand")
        await waitFor("The chat was never counted again for its new window") { !second.hosts.isEmpty && view.footer.preparedContext != nil && !view.footer.preparingContext }
        try await quit(second)

        // A journal that changed since: counted again too.
        let path = try XCTUnwrap(changed.path)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); try handle.seekToEnd()
        try handle.write(contentsOf: Data()); try handle.close()
        let attributes = [FileAttributeKey.modificationDate: Date().addingTimeInterval(5)]
        try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
        let third = launch(setup)
        await third.restore()
        let reopened = try XCTUnwrap(third.displays[chat.id])
        XCTAssertNil(third.servingContextReading(reopened), "A reading counted from another journal does not stand")
        await waitFor("The chat was never counted again for its changed journal") { !third.hosts.isEmpty && reopened.footer.preparedContext != nil }
    }
}
