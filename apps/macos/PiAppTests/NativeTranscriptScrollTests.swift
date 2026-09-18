import XCTest
import SwiftUI
@testable import PiApp

/// The page inside the real workspace: it lands at the newest row as rows
/// stream in, a wheel scroll up detaches it, and a later row never pulls the
/// reader back.
final class NativeTranscriptScrollTests: XCTestCase {
    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) } }

    @MainActor func testPageFollowsStreamingRowsUntilTheReaderScrollsUp() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("native-scroll-" + UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        try await model.reloadConfiguration()
        var profile = ProfileRecord(); profile.modelId = "auto-router"; profile.baseUrl = "https://fixture.invalid"
        let project = WorkspaceRecord(id: "scroll-project", path: root.path, trusted: true)
        let chat = ChatRecord(id: "scroll-chat", workspaceID: project.id, title: "Scrolling", path: nil, profileID: profile.id)
        let session = SessionDisplay(id: chat.id)
        session.messages = [TranscriptMessage(id: "u0", role: "user", text: "Start")]
        model.profiles = [profile]; model.workspaces = [project]; model.chats = [chat]
        model.selectedID = chat.id; model.selected = session; model.displays[chat.id] = session
        model.focusedSessionID = chat.id; model.selectedWorkspaceID = project.id; model.profileChoice = profile.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted
        defer { model.report.suspend(); model.shutdown(); window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root) }
        window.center(); window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(500))
        for index in 1..<30 {
            session.messages.append(TranscriptMessage(id: "m\(index)", role: index % 2 == 0 ? "user" : "assistant", text: "Row \(index) " + String(repeating: "lorem ipsum dolor sit amet ", count: 10)))
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(800))
        let marker = try XCTUnwrap(descendants(TranscriptSurfaceMarker.self, in: hosted).first)
        let scroll = try XCTUnwrap(marker.enclosingScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        func bottomOffset() -> CGFloat { document.frame.height - scroll.contentView.bounds.height }
        XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height * 2, "the fixture must be taller than the viewport")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, bottomOffset(), accuracy: 2, "the page follows streamed rows to the bottom")
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 600, wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:)))
        scroll.scrollWheel(with: wheel)
        try await Task.sleep(for: .milliseconds(300))
        let detached = scroll.contentView.bounds.origin.y
        XCTAssertLessThan(detached, bottomOffset() - 300, "a wheel scroll up moves the reader away from the bottom")
        session.messages.append(TranscriptMessage(id: "late", role: "assistant", text: "Late row " + String(repeating: "more text ", count: 30)))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, detached, accuracy: 2, "a later row never pulls the reader back down")
        model.report.suspend(); model.shutdown()
        await model.flushReadStates(); await model.flushProjectSidebarState()
        try await model.traces.close(); await model.store?.close()
    }

    /// Scrolled up while a reply streams below: the rows in view must not move, or nothing on them can be clicked.
    @MainActor func testRowsInViewStayPutWhileARowBelowStreams() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("native-steady-" + UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        try await model.reloadConfiguration()
        var profile = ProfileRecord(); profile.modelId = "auto-router"; profile.baseUrl = "https://fixture.invalid"
        let project = WorkspaceRecord(id: "steady-project", path: root.path, trusted: true)
        let chat = ChatRecord(id: "steady-chat", workspaceID: project.id, title: "Steady", path: nil, profileID: profile.id)
        let session = SessionDisplay(id: chat.id)
        session.messages = (0..<30).map { TranscriptMessage(id: "m\($0)", role: $0 % 2 == 0 ? "user" : "assistant", text: "Row \($0) " + String(repeating: "lorem ipsum dolor sit amet ", count: 10), turn: $0 % 2 == 0 ? "m\($0)" : "m\($0 - 1)") }
        model.profiles = [profile]; model.workspaces = [project]; model.chats = [chat]
        model.selectedID = chat.id; model.selected = session; model.displays[chat.id] = session
        model.focusedSessionID = chat.id; model.selectedWorkspaceID = project.id; model.profileChoice = profile.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted
        defer { model.report.suspend(); model.shutdown(); window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root) }
        window.center(); window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(900))
        let marker = try XCTUnwrap(descendants(TranscriptSurfaceMarker.self, in: hosted).first)
        let scroll = try XCTUnwrap(marker.enclosingScrollView), page = try XCTUnwrap(marker.page)
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 500, wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:)))
        scroll.scrollWheel(with: wheel)
        try await Task.sleep(for: .milliseconds(400))
        let origin = scroll.contentView.bounds.origin.y
        // A row that is in view after scrolling up.
        let visible = try XCTUnwrap((0..<30).map { "m\($0)" }.first { id in
            guard let frame = page.rowFrame(of: id) ?? page.rowFrame(of: "block:" + id) else { return false }
            return frame.minY > origin + 40 && frame.maxY < origin + 300
        })
        let key = page.rowFrame(of: visible) != nil ? visible : "block:" + visible
        let before = try XCTUnwrap(page.rowFrame(of: key))
        // The newest reply streams and grows below, then a new row arrives.
        session.state = "running"
        session.messages.append(TranscriptMessage(id: "stream:x", role: "assistant", text: "", state: "streaming", turn: "m28"))
        for step in 1...12 {
            session.messages[30] = TranscriptMessage(id: "stream:x", role: "assistant", text: String(repeating: "streamed words arrive here ", count: step * 6), state: "streaming", turn: "m28")
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(scroll.contentView.bounds.origin.y, origin, accuracy: 0.5, "the page must not scroll while the reader is away from the bottom (step \(step))")
            let now = try XCTUnwrap(page.rowFrame(of: key))
            XCTAssertEqual(now.minY, before.minY, accuracy: 0.5, "a row in view must not move while a row below streams (step \(step))")
        }
        // A tool round lands as a new row, then the reply settles and the working bar leaves.
        session.messages[30] = TranscriptMessage(id: "a30", role: "assistant", text: "", tools: [ToolView(id: "t1", name: "read", state: "completed", input: "{\"path\":\"README.md\"}", output: "ok", durationMs: 3, truncated: false, path: "README.md", added: nil, removed: nil)], turn: "m28")
        session.messages.append(TranscriptMessage(id: "stream:y", role: "assistant", text: "More words", state: "streaming", turn: "m28"))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, origin, accuracy: 0.5, "a new tool row below must not move the page")
        XCTAssertEqual(try XCTUnwrap(page.rowFrame(of: key)).minY, before.minY, accuracy: 0.5, "a new tool row below must not move rows in view")
        session.messages[31] = TranscriptMessage(id: "a31", role: "assistant", text: "Done.", turn: "m28"); session.state = "idle"
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, origin, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(page.rowFrame(of: key)).minY, before.minY, accuracy: 0.5)
        model.report.suspend(); model.shutdown()
        await model.flushReadStates(); await model.flushProjectSidebarState()
        try await model.traces.close(); await model.store?.close()
    }

    /// An idle chat whose last turn is taller than the viewport opens at the question that started it, not at the bottom.
    @MainActor func testAnIdleChatOpensAtTheLastQuestionWhenTheLastTurnIsTall() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("native-open-" + UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        try await model.reloadConfiguration()
        var profile = ProfileRecord(); profile.modelId = "auto-router"; profile.baseUrl = "https://fixture.invalid"
        let project = WorkspaceRecord(id: "open-project", path: root.path, trusted: true)
        let chat = ChatRecord(id: "open-chat", workspaceID: project.id, title: "Open", path: nil, profileID: profile.id)
        let session = SessionDisplay(id: chat.id)
        var rows = (0..<6).map { TranscriptMessage(id: "m\($0)", role: $0 % 2 == 0 ? "user" : "assistant", text: "Row \($0) " + String(repeating: "lorem ipsum ", count: 8), turn: "m\($0 - $0 % 2)") }
        rows.append(TranscriptMessage(id: "q", role: "user", text: "The last question, which should be in view when the chat opens.", turn: "q"))
        rows.append(TranscriptMessage(id: "a", role: "assistant", text: (0..<40).map { "Line \($0) of a long answer with enough words to wrap around." }.joined(separator: "\n\n"), turn: "q"))
        session.messages = rows
        model.profiles = [profile]; model.workspaces = [project]; model.chats = [chat]
        model.selectedID = chat.id; model.selected = session; model.displays[chat.id] = session
        model.focusedSessionID = chat.id; model.selectedWorkspaceID = project.id; model.profileChoice = profile.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted
        defer { model.report.suspend(); model.shutdown(); window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root) }
        window.center(); window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(900))
        let marker = try XCTUnwrap(descendants(TranscriptSurfaceMarker.self, in: hosted).first)
        let scroll = try XCTUnwrap(marker.enclosingScrollView), page = try XCTUnwrap(marker.page)
        let question = try XCTUnwrap(page.rowFrame(of: "q"))
        let origin = scroll.contentView.bounds.origin.y
        XCTAssertEqual(origin, max(0, question.minY - 12), accuracy: 2, "the page opens with the last question at the top")
        XCTAssertLessThan(origin, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height - 100, "and not at the bottom")
        model.report.suspend(); model.shutdown()
        await model.flushReadStates(); await model.flushProjectSidebarState()
        try await model.traces.close(); await model.store?.close()
    }
}
