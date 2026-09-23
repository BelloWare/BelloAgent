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
class SmoothShellTestCase: XCTestCase {

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

/// The shell tests that cannot share the machine, run alone in the serial
/// lane (`scripts/test-lanes.py`): the ones that move the window's stored
/// sidebar width or split, which every test host reads, and the ones that
/// count the frames a change takes or hold each one to a frame's budget in
/// Debug too.
final class SmoothShellTests: SmoothShellTestCase, SerialTestLane {
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

    @MainActor func testTheReadingPositionHoldsThroughEveryChangeAroundTheTranscript() async throws {
        let shell = try shell(["Reading"], rows: 60)
        let session = try XCTUnwrap(shell.model.displays[shell.chats[0].id])
        await shell.model.select(shell.chats[0].id)
        await shell.settle(1.2)
        await shell.scrollAwayFromTheBottom()
        XCTAssertFalse(shell.page?.followsBottom ?? true, "the reader must be away from the newest row for this to mean anything")

        /// A change that does not alter the pane's width keeps the reader on
        /// the same content: the scroll offset and the row's own place in the
        /// document are untouched. A change that does alter it reflows the
        /// text, so what must hold is the row's place on the screen.
        func holds(_ what: String, reflows: Bool, settle seconds: Double = 0.6, tolerance: CGFloat = 2,
                   _ change: () -> Void) async throws {
            let before = try XCTUnwrap(shell.readingRow(), "no row is in view before " + what)
            let offsetBefore = shell.offset
            change()
            // Five ticks through the change, not only where it lands: an
            // animated pane moves the reader's row on every frame or on none
            // of them, and only the frames can tell which.
            for tick in 1...5 {
                shell.draw()
                if let now = shell.readingRow(), now.id == before.id {
                    XCTAssertEqual(now.screenY, before.screenY, accuracy: tolerance,
                                   "\(what) moved the row the reader was on by \(Int(now.screenY - before.screenY)) points at tick \(tick)")
                }
                try? await Task.sleep(for: .milliseconds(PiMotion.baseMilliseconds / 5))
            }
            await shell.settle(seconds)
            let after = try XCTUnwrap(shell.readingRow(), "no row is in view after " + what)
            XCTAssertEqual(after.id, before.id, "\(what) moved the reader onto another row")
            XCTAssertEqual(after.screenY, before.screenY, accuracy: tolerance,
                           "\(what) moved the row the reader was on by \(Int(after.screenY - before.screenY)) points")
            if !reflows {
                XCTAssertEqual(shell.offset, offsetBefore, accuracy: tolerance,
                               "\(what) scrolled the page by \(Int(shell.offset - offsetBefore)) points")
                XCTAssertEqual(after.contentY, before.contentY, accuracy: 1, "\(what) moved the row inside the document")
            }
            XCTAssertFalse(shell.page?.followsBottom ?? true, "\(what) put the page back on the newest row")
        }

        // The composer grows as a long draft is typed, and shrinks again.
        try await holds("a composer grown to five lines", reflows: false) {
            session.draft = (1...5).map { "Line \($0) of a draft that makes the composer taller." }.joined(separator: "\n")
        }
        try await holds("a composer shrunk back to one line", reflows: false) { session.draft = "One line." }
        // A follow-up waiting behind the run appears under the conversation.
        try await holds("the follow-up panel appearing", reflows: false) {
            session.queue = [["turnId": .string("q1"), "text": .string("Then summarise the change in one line.")]]
        }
        try await holds("the follow-up panel leaving", reflows: false) { session.queue = [] }
        // The error strip takes room from the top of the content column.
        // Pushing the column down takes the conversation out from under the
        // titlebar and AppKit removes the inset it had put there;
        // `TranscriptNativeScrollView` moves the clip view by the difference,
        // so the reader stays on the same line.
        try await holds("the error strip arriving", reflows: false) {
            shell.model.error = "The gateway refused the request: 400 invalid_request_error — the model does not accept that output limit on this route."
        }
        try await holds("the error strip dismissed", reflows: false) { shell.model.error = nil }
        // The terminal opens under the conversation and closes again.
        try await holds("the terminal opening", reflows: false, settle: 1.0) { shell.model.toggleTerminal() }
        try await holds("the terminal closing", reflows: false, settle: 1.0) { shell.model.toggleTerminal() }
        // The window and the sidebar's edge both change the pane's width.
        try await holds("the window narrowed by 200 points", reflows: true, settle: 1.0) {
            shell.window.setContentSize(NSSize(width: 1_080, height: 880))
        }
        try await holds("the sidebar widened", reflows: true, settle: 1.0) {
            WindowChrome.adjustStoredSidebarWidth(by: 3 * WindowChrome.widthStep)
        }
        WindowChrome.adjustStoredSidebarWidth(by: -3 * WindowChrome.widthStep)
        await shell.settle(0.6)
        // A side conversation halves the pane.
        try await holds("a side conversation opening beside the chat", reflows: true, settle: 1.4) {
            shell.model.openSide(parentID: shell.chats[0].id)
        }
    }

    /// Every animated change to the shell, driven frame by frame for the
    /// length of the animation: what one tick costs the main thread, and
    /// whether any tick misses a 120 Hz frame.
    ///
    /// What is asserted about the geometry is that it does *not* move more
    /// than once. The panels slide and fade over the room they take, rather
    /// than growing into it: a panel whose height is interpolated drags the
    /// conversation's edge across a fifth of a second, and for the strip
    /// above the conversation that is the line the reader is on. The travel
    /// is the transition's own; the layout lands in one step and stays.
    @MainActor func testEveryTransitionHoldsAFrameOfTheBudget() async throws {
        let shell = try shell(["Moving"], rows: 60)
        let session = try XCTUnwrap(shell.model.displays[shell.chats[0].id])
        await shell.model.select(shell.chats[0].id)
        await shell.settle(1.2)

        /// Drives frames for the length of the animation, returning what each
        /// one cost and how many distinct pane geometries were drawn.
        @MainActor func run(_ what: String, over milliseconds: Int = PiMotion.baseMilliseconds,
                            _ change: () -> Void) async -> (mean: Double, worst: Double, ticks: Int, steps: Int) {
            var costs: [Double] = [], geometries: Set<Int> = []
            change()
            let deadline = Date().addingTimeInterval(Double(milliseconds) / 1_000)
            // The animation runs on the wall clock, so how many frames land
            // inside it is what the machine can give: under load, two or
            // three. The loop goes on past its end until it has driven five.
            // Those frames draw the pane the animation landed on, so they add
            // no height to the count of distinct ones, and their cost is still
            // held to the frame budget.
            var inside = 0
            while Date() < deadline || costs.count <= 4 {
                if Date() < deadline { inside += 1 }
                let started = ProcessInfo.processInfo.systemUptime
                shell.draw()
                costs.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
                geometries.insert(Int((shell.transcriptFrame.height * 4).rounded()))
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(4))
            }
            await shell.settle(0.5)
            let mean = costs.reduce(0, +) / Double(max(1, costs.count))
            let worst = costs.max() ?? 0
            print(String(format: "PERF smooth transition %@: %d frames (%d inside the animation), mean %.2f ms, worst %.2f ms, %d distinct heights",
                         what, costs.count, inside, mean, worst, geometries.count))
            return (mean, worst, costs.count, geometries.count)
        }

        /// One 120 Hz frame. Nothing a transition does may cost more.
        let frame = 1_000.0 / 120
        /// The target is under 2 ms a frame and that is what Release
        /// measures; what is asserted is a ceiling this machine still clears
        /// with the rest of the suite running beside it.
        let ceiling = 4.0
        var animated: [String] = [], snapped: [String] = []
        // Opening the terminal starts a login shell on its first frame, which
        // can take the whole window on a loaded machine, so that one change
        // is not held to a count of driven frames.
        let changes: [(what: String, driven: Bool, change: () -> Void)] = [
            ("the follow-up panel arriving", true, { session.queue = [["turnId": .string("q1"), "text": .string("Then summarise the change.")]] }),
            ("the follow-up panel leaving", true, { session.queue = [] }),
            ("the error strip arriving", true, { shell.model.error = "The gateway refused the request: 400 invalid_request_error." }),
            ("the error strip leaving", true, { shell.model.error = nil }),
            ("the terminal opening", false, { shell.model.toggleTerminal() }),
            ("the terminal closing", true, { shell.model.toggleTerminal() })
        ]
        for (what, driven, change) in changes {
            let result = await run(what, change)
            XCTAssertLessThan(result.mean, ceiling, "\(what) cost \(result.mean) ms a frame")
            XCTAssertLessThan(result.worst, frame, "\(what) missed a 120 Hz frame: \(result.worst) ms")
            if driven { XCTAssertGreaterThan(result.ticks, 4, "\(what) was not driven for long enough to mean anything") }
            if result.steps > 2 { animated.append(what) } else { snapped.append(what) }
        }
        print("PERF smooth transitions whose layout landed in one step: \(snapped.joined(separator: ", "))"
              + (animated.isEmpty ? "" : " — interpolated their height: \(animated.joined(separator: ", "))"))
        XCTAssertTrue(animated.isEmpty,
                      "these changes interpolate the conversation's own edge, which drags the line the reader is on: "
                      + animated.joined(separator: ", "))
    }

    /// The boundary between a chat and its side used to be a hairline that
    /// invited a drag it could not answer, at a fixed half. It is draggable
    /// now, bounded, and what it lands on is kept.
    @MainActor func testTheSplitPaneIsBoundedAndKeepsWhereItWasPut() async throws {
        XCTAssertEqual(SplitPane.clampFraction(0.01), SplitPane.minimumFraction)
        XCTAssertEqual(SplitPane.clampFraction(0.99), SplitPane.maximumFraction)
        XCTAssertEqual(SplitPane.clampFraction(.nan), SplitPane.defaultFraction)
        // The two panes and their divider always add up to the column exactly.
        for total in stride(from: 600.0, through: 1_801.0, by: 37.0) {
            for fraction in [0.3, 0.42, 0.5, 0.63, 0.7] {
                let main = SplitPane.mainWidth(total: CGFloat(total), fraction: fraction)
                let side = SplitPane.sideWidth(total: CGFloat(total), fraction: fraction)
                XCTAssertEqual(main + side + SplitPane.dividerWidth, CGFloat(total), accuracy: 0.001,
                               "the split lost a point at \(total) × \(fraction)")
                XCTAssertGreaterThan(main, 0); XCTAssertGreaterThan(side, 0)
            }
        }
        let start = UserDefaults.standard.object(forKey: "sidePaneFraction") as? Double
        defer {
            if let start { UserDefaults.standard.set(start, forKey: "sidePaneFraction") }
            else { UserDefaults.standard.removeObject(forKey: "sidePaneFraction") }
        }
        UserDefaults.standard.set(0.62, forKey: "sidePaneFraction")
        let shell = try shell(["Split"], rows: 20, width: 1_400)
        await shell.model.select(shell.chats[0].id)
        await shell.settle(1.0)
        let whole = shell.transcriptFrame.width
        shell.model.openSide(parentID: shell.chats[0].id)
        await shell.settle(1.4)
        let panes = Self.views(TranscriptSurfaceMarker.self, in: shell.hosted).compactMap { $0.enclosingScrollView }
        XCTAssertEqual(panes.count, 2, "the side conversation did not open beside the chat")
        let widths = panes.map(\.frame.width).sorted()
        print(String(format: "PERF smooth split pane at 0.62: panes %.0f and %.0f points of a %.0f point column",
                     widths[1], widths[0], whole))
        XCTAssertGreaterThan(widths[1], widths[0], "a stored fraction of 0.62 must leave the chat the wider pane")
        XCTAssertEqual(widths[1] / (widths[0] + widths[1]), 0.62, accuracy: 0.04,
                       "the stored fraction is not where the boundary landed")
    }

    /// The boundary answers the keyboard with the same value and the same
    /// bounds the handle commits, and the sidebar really changes width.
    @MainActor func testTheSidebarWidthHasAKeyboardPathWithinTheSameBounds() async throws {
        let shell = try shell(["Keyboard"], rows: 10)
        await shell.model.select(shell.chats[0].id)
        await shell.settle(0.8)
        let start = WindowChrome.storedSidebarWidth
        defer { UserDefaults.standard.set(Double(start), forKey: "sidebarWidth") }
        let firstTranscript = shell.transcriptFrame

        WindowChrome.adjustStoredSidebarWidth(by: WindowChrome.widthStep)
        await shell.settle(0.6)
        XCTAssertEqual(WindowChrome.storedSidebarWidth, start + WindowChrome.widthStep, accuracy: 0.5)
        XCTAssertEqual(shell.transcriptFrame.width, firstTranscript.width - WindowChrome.widthStep, accuracy: 2,
                       "widening the sidebar did not narrow the conversation")
        // The bounds are the handle's own: pressing past them stops there.
        for _ in 0..<40 { WindowChrome.adjustStoredSidebarWidth(by: WindowChrome.widthStep) }
        XCTAssertEqual(WindowChrome.storedSidebarWidth, WindowChrome.maximumSidebarWidth, accuracy: 0.5)
        for _ in 0..<60 { WindowChrome.adjustStoredSidebarWidth(by: -WindowChrome.widthStep) }
        XCTAssertEqual(WindowChrome.storedSidebarWidth, WindowChrome.minimumSidebarWidth, accuracy: 0.5)
        await shell.settle(0.6)
        XCTAssertEqual(shell.transcriptFrame.width, firstTranscript.width + (start - WindowChrome.minimumSidebarWidth), accuracy: 2)
    }
}
