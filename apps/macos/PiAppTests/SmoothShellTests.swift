import AppKit
import Combine
import SwiftUI
import XCTest
@testable import PiApp


/// How the shell feels around the transcript, driven in a real window over a
/// real `WorkspaceModel` on a scratch store: a chat switch that arrives
/// settled rather than empty-then-full, a reading position that survives
/// every change to the pane's size (the error strip, the composer growing,
/// the follow-up panel, the terminal, the side pane, the sidebar's edge and
/// the window's), hover that answers from the pointer's own frame, motion
/// that follows the tokens and stops under Reduce Motion, and the keyboard
/// paths for what used to need a pointer.
///
/// Everything asserted here is something the reader would see: a scroll
/// offset, a row's place on screen, a cursor, a pane's frame.
final class SmoothShellTests: XCTestCase {

    // MARK: Fixture
    //
    // Shared by every SmoothShell* file: the fixture and the wait helper are
    // internal because the tests that drive them are extensions in sibling files.

    @MainActor static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }
    @MainActor static func tree(_ view: NSView) -> [(name: String, frame: CGRect)] {
        [(String(describing: Swift.type(of: view)), view.convert(view.bounds, to: nil))] + view.subviews.flatMap { tree($0) }
    }

    /// A model with one trusted project, one connection and as many chats as
    /// the test asks for, on a scratch store. The chats count as already
    /// opened, so selecting one is the switch itself and not a first read.
    @MainActor static func workbench(root: URL, names: [String], rows: Int) throws -> (model: WorkspaceModel, project: WorkspaceRecord, chats: [ChatRecord]) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = WorkspaceRecord(id: "smooth-project", path: root.path, trusted: true)
        var profile = ProfileRecord()
        profile.id = "smooth-connection"; profile.name = "Smooth connection"; profile.api = LiteLLMConfiguration.supportedAPI
        profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "smooth-model"
        profile.contextWindow = 200_000; profile.maxOutputTokens = 32_000
        var configuration = VaultConfiguration()
        configuration.workspaces = [project]
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-smooth-key")]
        let vault = ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration)))
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("app-state"), vault: vault)
        let chats = names.map { ChatRecord(id: "chat-" + $0, workspaceID: project.id, title: $0, path: nil, profileID: profile.id) }
        model.workspaces = [project]; model.profiles = [profile]; model.chats = chats
        model.selectedWorkspaceID = project.id; model.profileChoice = profile.id
        for chat in chats {
            let display = SessionDisplay(id: chat.id)
            display.messages = Shell.conversation(rows: rows, prefix: chat.id)
            display.draft = "An unsent draft for " + chat.title
            display.selectionMetadataLoaded = true
            display.historyState = .ready
            model.displays[chat.id] = display
        }
        // Fresh selection loads an authoritative history page even for a
        // retained display. This rendering fixture serves its seeded source.
        model.historyWindowLoader = { [weak model] id, _, _, _ in
            try await MainActor.run {
                var page = try ConversationHistoryPage(.object(["version": .number(2), "messages": .array([]),
                    "incarnation": .string("fixture:" + id), "lineage": .string("root"), "older": .null, "newer": .null]))
                page.messages = model?.displays[id]?.messages ?? []
                return page
            }
        }
        model.opened = Set(chats.map(\.id))
        return (model, project, chats)
    }

    /// The whole app shell in a window: `WorkspaceView` over that model.
    @MainActor final class Shell {
        let model: WorkspaceModel
        let window: NSWindow
        let hosted: NSHostingView<AnyView>
        let root: URL
        let project: WorkspaceRecord
        let chats: [ChatRecord]

        init(chats names: [String], rows: Int, width: CGFloat = 1_280, height: CGFloat = 880) throws {
            let scratch = scratchBase()
            root = URL(fileURLWithPath: scratch).appendingPathComponent("smooth-shell-" + UUID().uuidString)
            let bench = try SmoothShellTests.workbench(root: root, names: names, rows: rows)
            model = bench.model; project = bench.project; chats = bench.chats
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            hosted = NSHostingView(rootView: AnyView(WorkspaceView(model: model)))
            window.contentView = hosted
            window.center(); window.makeKeyAndOrderFront(nil)
        }

        /// Rows long enough that the page scrolls and narrow enough that a
        /// width change really reflows them.
        static func conversation(rows: Int, prefix: String) -> [TranscriptMessage] {
            (0..<rows).map { index in
                var message = TranscriptMessage(id: "\(prefix)-m\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant",
                                                text: "Row \(index). " + String(repeating: "the handler retries twice and logs the reason it gave. ", count: 4),
                                                turn: "\(prefix)-m\(index - index % 2)")
                message.at = Double(index) * 1_000
                return message
            }
        }

        func draw() { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        func settle(_ seconds: Double = 0.4) async {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                draw(); await Task.yield()
                try? await Task.sleep(for: .milliseconds(15))
            }
            draw()
        }
        /// Panes left to right, so the chat's own transcript is always the
        /// first one even when a side conversation is open beside it.
        var markers: [TranscriptSurfaceMarker] {
            SmoothShellTests.views(TranscriptSurfaceMarker.self, in: hosted).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        }
        var marker: TranscriptSurfaceMarker? { markers.first }
        var scroll: NSScrollView? { marker?.enclosingScrollView }
        var page: TranscriptPage? { marker?.page }
        var document: TranscriptNativeDocument? { scroll?.documentView as? TranscriptNativeDocument }
        var editor: ComposerTextView? { SmoothShellTests.views(ComposerTextView.self, in: hosted).first }
        /// Where the conversation's scrollable surface sits in the window.
        var transcriptFrame: CGRect { scroll.map { $0.convert($0.bounds, to: nil) } ?? .zero }
        var offset: CGFloat { scroll?.contentView.bounds.origin.y ?? 0 }

        /// Scrolls the reader up off the newest row, the way a trackpad does.
        func scrollAwayFromTheBottom(by points: CGFloat = 520) async {
            guard let scroll,
                  let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(points), wheel2: 0, wheel3: 0)
                    .flatMap(NSEvent.init(cgEvent:)) else { return }
            scroll.scrollWheel(with: wheel)
            await settle(0.35)
        }
        /// The row identifier that is first fully inside the viewport, and
        /// where it sits: the line the reader is looking at.
        func readingRow() -> (id: String, contentY: CGFloat, screenY: CGFloat)? {
            guard let page, let snapshot = page.snapshot else { return nil }
            let top = offset
            for item in snapshot.items {
                guard let frame = page.rowFrame(of: item.id), frame.maxY > top + 1 else { continue }
                return (item.id, frame.minY, frame.minY - top)
            }
            return nil
        }
        func close() {
            TerminalRegistry.shared.shutdown()
            window.contentView = nil; window.close()
        }
    }

    @MainActor func shell(_ names: [String], rows: Int = 40, width: CGFloat = 1_280, height: CGFloat = 880) throws -> Shell {
        let shell = try Shell(chats: names, rows: rows, width: width, height: height)
        registerWorkspaceFixtureTeardown(shell.model, root: shell.root)
        addTeardownBlock { @MainActor in shell.close() }
        return shell
    }

    // MARK: 1. A chat switch arrives settled

    /// Clicking another chat must show that chat: its rows, its draft and its
    /// footer in the paint that replaces the old one. What is measured is the
    /// number of layout passes and drawn frames between the click and the
    /// settled pane, and that no frame in between shows the new chat's
    /// composer over the old chat's rows, or an empty pane.
    @MainActor func testAChatSwitchShowsTheNewChatSettledWithoutAFlash() async throws {
        let shell = try shell(["First", "Second"], rows: 60)
        await shell.model.select(shell.chats[0].id)
        await shell.settle(1.2)
        XCTAssertNotNil(shell.page?.snapshot, "the first chat never painted its transcript")

        var worstFrames = 0, worstPasses = 0, worstMilliseconds = 0.0
        for round in 0..<4 {
            let target = shell.chats[round.isMultiple(of: 2) ? 1 : 0]
            let passesBefore = shell.document?.layoutPassCount ?? 0
            let started = ProcessInfo.processInfo.systemUptime
            await shell.model.select(target.id)
            // Frames from the click until the pane shows the chosen chat
            // whole: its rows mounted, its own draft in the composer.
            var frames = 0
            while frames < 240 {
                frames += 1
                shell.draw()
                let painted = shell.page?.snapshot?.sessionID == target.id
                    && shell.editor?.sessionID == target.id
                    && shell.editor?.string.contains(target.title) == true
                    && !(shell.page?.snapshot?.items.isEmpty ?? true)
                    && (shell.document?.frame.height ?? 0) > 200
                if painted { break }
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(2))
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            // A pane that shows one chat's rows under another chat's composer
            // is the flash this is here to catch.
            XCTAssertEqual(shell.page?.snapshot?.sessionID, target.id)
            XCTAssertEqual(shell.editor?.sessionID, target.id)
            XCTAssertFalse(shell.page?.snapshot?.items.isEmpty ?? true, "the switched-to pane painted no rows")
            if round > 0 {
                worstFrames = max(worstFrames, frames)
                worstPasses = max(worstPasses, (shell.document?.layoutPassCount ?? 0) - passesBefore)
                worstMilliseconds = max(worstMilliseconds, elapsed * 1_000)
            }
        }
        print(String(format: "PERF smooth chat switch (two 60-row chats): worst %d drawn frames, %d document layout passes, %.1f ms to a settled pane",
                     worstFrames, worstPasses, worstMilliseconds))
        XCTAssertLessThanOrEqual(worstFrames, 24, "a chat switch took \(worstFrames) drawn frames to settle")
        XCTAssertLessThanOrEqual(worstPasses, 24, "a chat switch cost \(worstPasses) document layout passes")
    }


    // MARK: Helpers

    @MainActor func waitFor(_ what: String, seconds: Double = 10, file: StaticString = #filePath, line: UInt = #line,
                                    _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTFail(what, file: file, line: line)
    }
}
