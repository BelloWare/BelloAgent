import XCTest
import SwiftUI
import AppKit
@testable import PiApp

extension ConversationPaneTests {
    // MARK: Typing

    /// What one keystroke costs in the real pane: the native edit, the SwiftUI
    /// publication, layout and display, with a long chat above the composer and
    /// a draft that has grown long. Printed, and bounded well under a frame.
    @MainActor func testTypingCostDoesNotGrowWithTheDraft() async throws {
        let pane = try Pane(messages: longChat(rows: 120)); defer { pane.close() }
        await pane.settle(20)
        let editor = try XCTUnwrap(pane.editor)
        pane.window.makeFirstResponder(editor)
        for _ in 0..<8 { type("w", into: editor); pane.draw() }   // warm the path
        var costs: [Int: Double] = [:]
        for length in [0, 4_000, 40_000, 200_000] {
            if length > 0 {
                pane.session.draft = String(repeating: "Some drafted sentence that the owner is still writing. ", count: length / 54)
                await pane.settle(6)
            }
            editor.setSelectedRange(NSRange(location: editor.textStorage?.length ?? 0, length: 0))
            let keystrokes = 30
            let start = ProcessInfo.processInfo.systemUptime
            for index in 0..<keystrokes {
                type(index % 9 == 8 ? "\n" : "x", into: editor)
                pane.draw()
            }
            let each = (ProcessInfo.processInfo.systemUptime - start) * 1000 / Double(keystrokes)
            costs[length] = each
            print(String(format: "PERF keystroke in a 120-row chat, %d character draft: %.2f ms", editor.textStorage?.length ?? 0, each))
        }
        // What the composer used to do on every edit, for comparison: reading
        // the draft back out of AppKit's UTF-16 store and comparing it whole.
        var bridged = 0.0, adopted = 0.0, sink = 0
        for _ in 0..<20 {
            var mark = ProcessInfo.processInfo.systemUptime
            if pane.session.draft != editor.string { sink += 1 }
            bridged += ProcessInfo.processInfo.systemUptime - mark
            mark = ProcessInfo.processInfo.systemUptime
            sink += NativeComposer.Coordinator.contents(of: editor).utf8.count
            adopted += ProcessInfo.processInfo.systemUptime - mark
        }
        XCTAssertGreaterThan(sink, 0)
        print(String(format: "PERF reading a %d character draft out of the editor: comparing the UTF-16 bridge %.2f ms, taking its UTF-8 bytes %.2f ms",
                     editor.textStorage?.length ?? 0, bridged * 1000 / 20, adopted * 1000 / 20))
        // What this holds the composer to is the shape: a keystroke must not
        // get more expensive as the draft grows. Every figure here rises
        // together when the machine is busy, so an absolute under-load number
        // would only measure the load; the ratios are what stay meaningful,
        // and the loose absolute is a guard against a hang, not a budget.
        let base = try XCTUnwrap(costs[0]), middle = try XCTUnwrap(costs[40_000]), long = try XCTUnwrap(costs[200_000])
        // The multiples are generous because the empty-draft figure is the
        // one that moves most with the load: on a quiet machine it is around
        // 3.5 ms and on a busy one under 2, which tightens every ratio taken
        // against it. What they still catch is a draft whose length the
        // keystroke walks.
        XCTAssertLessThan(middle, base * 6 + 4,
                          String(format: "Typing cost grows with the draft: %.2f ms empty, %.2f ms at 40 KB", base, middle))
        XCTAssertLessThan(long, base * 10 + 4,
                          String(format: "Typing cost grows with the draft: %.2f ms empty, %.2f ms at 200 KB", base, long))
        XCTAssertLessThan(long, releaseBudget(0.060) * 1_000, String(format: "A keystroke in a 200 KB draft took %.1f ms", long))
    }

    /// The field is one line tall when empty, grows with its content, stops at
    /// its ceiling, and comes back when the draft is cleared.
    @MainActor func testComposerHeightGrowsAndShrinks() async throws {
        let pane = try Pane(); defer { pane.close() }
        await pane.settle(12)
        let editor = try XCTUnwrap(pane.editor)
        func fieldHeight() -> CGFloat { editor.enclosingScrollView?.frame.height ?? 0 }
        let empty = fieldHeight()
        XCTAssertEqual(empty, 44, accuracy: 0.5, "An empty composer is one line tall")
        pane.session.draft = (0..<6).map { "line \($0)" }.joined(separator: "\n")
        await pane.settle(8)
        XCTAssertGreaterThan(fieldHeight(), empty, "Six lines make the composer taller")
        pane.session.draft = (0..<60).map { "line \($0)" }.joined(separator: "\n")
        await pane.settle(8)
        XCTAssertEqual(fieldHeight(), 240, accuracy: 0.5, "The composer stops growing at its ceiling and scrolls instead")
        pane.session.draft = ""
        await pane.settle(8)
        XCTAssertEqual(fieldHeight(), empty, accuracy: 0.5, "Clearing the draft brings the composer back to one line")
    }

    /// Return sends, Shift-Return adds a line, and neither does the other.
    @MainActor func testReturnSendsAndShiftReturnAddsALine() async throws {
        let pane = try Pane(); defer { pane.close() }
        await pane.settle(12)
        let editor = try XCTUnwrap(pane.editor)
        pane.window.makeFirstResponder(editor)
        for character in "hello" { type(String(character), into: editor) }
        pane.draw()
        type("\r", into: editor, keyCode: 36, modifiers: .shift)
        await pane.settle(4)
        XCTAssertEqual(editor.string, "hello\n", "Shift-Return adds a line instead of sending")
        XCTAssertEqual(pane.session.draft, "hello\n", "The new line reaches the draft")
        XCTAssertNil(pane.session.sendFailure, "Shift-Return must not start a send")
        type("\r", into: editor, keyCode: 36)
        XCTAssertEqual(editor.string, "hello\n", "Return does not type a line break")
        XCTAssertTrue(pane.session.loading, "Return submits the draft")
    }

    /// Marked text from an input method is not republished or overwritten
    /// while a composition is open.
    @MainActor func testMarkedTextSurvivesTheModelRoundTrip() async throws {
        let pane = try Pane(); defer { pane.close() }
        await pane.settle(12)
        let editor = try XCTUnwrap(pane.editor)
        pane.window.makeFirstResponder(editor)
        for character in "ka" { type(String(character), into: editor) }
        await pane.settle(4)
        editor.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 2, length: 0))
        pane.draw()
        XCTAssertTrue(editor.hasMarkedText(), "The composition is open")
        XCTAssertEqual(editor.string, "kaにほん")
        await pane.settle(6)
        XCTAssertTrue(editor.hasMarkedText(), "A model refresh must not end the composition")
        XCTAssertEqual(editor.string, "kaにほん", "A model refresh must not rewrite marked text")
        editor.insertText("日本", replacementRange: NSRange(location: 2, length: 3))
        await pane.settle(6)
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(pane.session.draft, "ka日本", "The committed composition reaches the draft")
    }

    /// Pasting more than the submission limit is refused with a notice, and the
    /// draft that was there is untouched. A paste that fits grows the field.
    @MainActor func testOversizedPasteIsRefusedAndKeepsTheDraft() async throws {
        let pane = try Pane(); defer { pane.close() }
        await pane.settle(12)
        let editor = try XCTUnwrap(pane.editor)
        pane.session.draft = "keep me"
        await pane.settle(6)
        XCTAssertFalse(editor.shouldChangeText(in: NSRange(location: 7, length: 0), replacementString: String(repeating: "x", count: 300_000)),
                       "A paste beyond the 256 KiB limit is refused")
        await pane.settle(4)
        XCTAssertEqual(editor.string, "keep me", "The existing draft is untouched")
        XCTAssertTrue(pane.session.notice.contains("256 KiB"), "The refusal explains the limit; notice was “\(pane.session.notice)”")
        let before = editor.enclosingScrollView?.frame.height ?? 0
        let large = String(repeating: "pasted line of text\n", count: 400)
        XCTAssertTrue(editor.shouldChangeText(in: NSRange(location: 7, length: 0), replacementString: large))
        editor.insertText(large, replacementRange: NSRange(location: 7, length: 0))
        await pane.settle(8)
        XCTAssertGreaterThan(editor.enclosingScrollView?.frame.height ?? 0, before, "A large paste grows the composer")
        XCTAssertTrue(pane.session.draft.hasPrefix("keep me"), "The paste lands after the existing draft")
    }

    // MARK: The live turn bar

    /// A chat whose run starts while its pane is being mounted must still show
    /// the live bar: the spinner, the elapsed time and Stop.
    @MainActor func testLiveBarShowsWhenTheRunStartsAsThePaneOpens() async throws {
        let pane = try Pane(messages: [TranscriptMessage(id: "u1", role: "user", text: "Go", at: 1000, turn: "u1")])
        defer { pane.close() }
        // The status refresh that marks the chat busy lands before the
        // transcript's own start-up task has run.
        pane.session.state = "running"
        await pane.settle(20)
        let page = try XCTUnwrap(pane.transcript)
        // Known gap, owned by the transcript: NativeTranscriptView's start-up
        // `.task(id: session.id)` writes the run state captured when the view
        // was built, so a state that changed in between was overwritten and the
        // bar never appeared for that run. Fixed in 0.1.59: the task reads the
        // live state, and `onChange(initial:)` carries the first one.
        XCTAssertEqual(page.state, pane.session.state, "The transcript must adopt the run state the chat has now, not the one it had when the pane was built")
        XCTAssertNotNil(page.liveTurn, "A chat that is running must show its live bar as soon as it is on screen")
    }

    /// The live bar through the phases of a run and away again when it ends.
    @MainActor func testLiveBarFollowsTheRunAndLeavesWhenItEnds() async throws {
        let pane = try Pane(messages: [TranscriptMessage(id: "u1", role: "user", text: "Go", at: 1000, turn: "u1")])
        defer { pane.close() }
        await pane.settle(16)
        let page = try XCTUnwrap(pane.transcript)
        XCTAssertNil(page.liveTurn, "An idle chat shows no live bar")
        let surface = try XCTUnwrap(Self.views(TranscriptNativeScrollView.self, in: pane.hosted).first)
        let idleHeight = surface.frame.height
        for state in ["queued", "running", "stopping", "compacting"] {
            pane.session.state = state
            await pane.settle(6)
            XCTAssertNotNil(page.liveTurn, "State \(state) must keep the live bar up")
            XCTAssertEqual(page.state, state, "The bar's label follows the run state")
        }
        XCTAssertLessThan(surface.frame.height, idleHeight, "The live bar takes room above the composer")
        pane.session.state = "idle"
        // The bar slides out of its slot before the slot closes, so the room
        // comes back a motion later rather than in the same frame.
        await pane.settle(30)
        XCTAssertNil(page.liveTurn, "The live bar leaves when the run ends")
        XCTAssertEqual(surface.frame.height, idleHeight, accuracy: 0.5, "The transcript takes the room back")
    }

    /// Two chats, one streaming: the pane, its composer, its draft and the live
    /// bar always belong to the chat that is selected, never to the other one.
    @MainActor func testTwoChatsStreamingAtOnceFollowTheSelection() async throws {
        let scratch = scratchBase()
        let root = URL(fileURLWithPath: scratch).appendingPathComponent("pane-shell-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bench = try Self.workbench(root: root, chats: ["Alpha", "Beta"])
        let model = bench.model
        defer { model.shutdown() }
        let a = bench.chats[0], b = bench.chats[1]
        let viewA = SessionDisplay(id: a.id), viewB = SessionDisplay(id: b.id)
        viewA.messages = [TranscriptMessage(id: "a1", role: "user", text: "Alpha question", at: 1000, turn: "a1")]
        viewB.messages = [TranscriptMessage(id: "b1", role: "user", text: "Beta question", at: 1000, turn: "b1")]
        viewA.historyState = .ready; viewB.historyState = .ready
        model.displays[a.id] = viewA; model.displays[b.id] = viewB
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        func draw() { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        func settle(_ turns: Int = 12) async { for _ in 0..<turns { draw(); await Task.yield(); try? await Task.sleep(for: .milliseconds(15)) }; draw() }
        await model.select(a.id)
        await settle(20)
        func composers() -> [String] { Self.views(ComposerTextView.self, in: hosted).map { $0.sessionID + "=" + $0.string } }
        func page() -> TranscriptPage? { Self.views(TranscriptSurfaceMarker.self, in: hosted).first?.page }
        viewA.draft = "alpha draft"; viewB.draft = "beta draft"
        viewB.state = "running"
        await settle(14)
        XCTAssertEqual(composers(), [a.id + "=alpha draft"], "Only the selected chat's composer may be mounted")
        XCTAssertNil(page()?.liveTurn, "The other chat's run must not raise a live bar in the selected chat")
        // Since 0.1.96 a revisited chat keeps its rows while its fresh page is
        // read, and the page is presented again when that read lands: wait
        // for what the reader sees rather than a fixed number of frames.
        func settle(until condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(5)
            while !condition() && Date() < deadline { await settle(2) }
        }
        await model.select(b.id); await settle(until: { page()?.liveTurn != nil })
        XCTAssertEqual(composers(), [b.id + "=beta draft"], "Switching chats swaps the composer and its draft")
        XCTAssertNotNil(page()?.liveTurn, "The running chat shows its live bar once selected")
        viewB.state = "idle"; await settle(until: { page()?.liveTurn == nil })
        XCTAssertNil(page()?.liveTurn, "Ending the run removes the live bar")
        await model.select(a.id); await settle(20)
        XCTAssertEqual(composers(), [a.id + "=alpha draft"], "Switching back restores the first chat's draft")
        await model.store?.close()
    }

    // MARK: Focus

    /// The cursor goes back into the composer when the app asks for it, stray
    /// typing lands there, and neither happens while a sheet is up.
    @MainActor func testFocusReturnsToTheComposerAndStrayTypingLandsThere() async throws {
        let pane = try Pane(messages: [TranscriptMessage(id: "u1", role: "user", text: "Hello", at: 1000, turn: "u1")])
        defer { pane.close() }
        await pane.settle(16)
        let editor = try XCTUnwrap(pane.editor)
        let surface = try XCTUnwrap(Self.views(TranscriptNativeScrollView.self, in: pane.hosted).first)
        // A click in the transcript, then Escape in the chat filter: the model
        // asks for the composer back.
        pane.window.makeFirstResponder(surface)
        XCTAssertFalse(pane.window.firstResponder === editor)
        pane.model.focusComposer()
        await pane.settle(8)
        XCTAssertTrue(pane.window.firstResponder === editor, "focusComposer must put the cursor back in the composer")
        // Typing with the transcript focused reaches the composer through the
        // window controller, with the real pane mounted.
        pane.window.makeFirstResponder(surface)
        let controller = WindowPresentationController()
        controller.attach(pane.window, chrome: WindowChromeView(frame: NSRect(x: 0, y: 0, width: 200, height: 36)))
        defer { controller.detach() }
        controller.focusedSessionID = pane.session.id
        let typed = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: pane.window.windowNumber, context: nil,
                                                   characters: "h", charactersIgnoringModifiers: "h", isARepeat: false, keyCode: 4))
        XCTAssertNotNil(controller.redirectTyping(typed), "The keystroke still goes through")
        XCTAssertTrue(pane.window.firstResponder === editor, "Typing with nothing editable focused lands in the composer")
        // A sheet owns the keyboard while it is up.
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        pane.window.beginSheet(sheet, completionHandler: nil)
        pane.window.makeFirstResponder(surface)
        _ = controller.redirectTyping(typed)
        XCTAssertFalse(pane.window.firstResponder === editor, "A sheet keeps the keyboard while it is up")
        pane.model.focusComposer()
        await pane.settle(8)
        XCTAssertFalse(pane.window.firstResponder === editor, "A focus request must not reach past an open sheet")
        pane.window.endSheet(sheet); sheet.close()
    }

    // MARK: Layout

    /// The composer bar, live bar and footer rendered in both appearances and
    /// at a narrow width. Set PI_APP_PANE_SHOTS to keep the PNGs.
    @MainActor func testComposerBarRendersInBothAppearancesAndNarrowWidths() async throws {
        let folder = testEnvironment("PI_APP_PANE_SHOTS").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { NSApp.appearance = nil }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for width in [980.0, 520.0, 460.0] {
                NSApp.appearance = NSAppearance(named: appearance)
                let pane = try Pane(messages: [TranscriptMessage(id: "u1", role: "user", text: "Harden the retry loop", at: 1000, turn: "u1")], width: width, height: 620)
                defer { pane.close() }
                pane.session.state = "running"
                pane.session.draft = "and add a test for the jitter bounds"
                pane.session.queue = [["turnId": .string("q0"), "kind": .string("followup"), "text": .string("Then run the suite and report")]]
                pane.session.footer.context = ["tokens": .number(48_000), "method": .string("usage-baseline")]
                await pane.settle(20)
                let composer = try XCTUnwrap(Self.views(ComposerTextView.self, in: pane.hosted).first)
                XCTAssertEqual(composer.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), appearance,
                               "The composer must follow the \(name) appearance")
                // The bottom of the pane: live bar, queue, composer bar, footer.
                // The hosting view is flipped, so the bottom of the pane is at the far edge.
                let region = NSRect(x: 0, y: pane.hosted.bounds.height - 300, width: width, height: 300)
                let shot = try XCTUnwrap(pane.hosted.bitmapImageRepForCachingDisplay(in: region))
                pane.hosted.cacheDisplay(in: region, to: shot)
                XCTAssertGreaterThan(shot.pixelsWide, 0)
                var distinct = Set<String>()
                for x in stride(from: 4, to: shot.pixelsWide - 4, by: 23) {
                    for y in stride(from: 4, to: shot.pixelsHigh - 4, by: 23) {
                        if let colour = shot.colorAt(x: x, y: y) { distinct.insert(String(format: "%.2f", colour.brightnessComponent)) }
                    }
                }
                XCTAssertGreaterThan(distinct.count, 2, "The \(name) composer region at \(width) points renders content, not a flat fill")
                if let folder {
                    try XCTUnwrap(shot.representation(using: .png, properties: [:]))
                        .write(to: folder.appendingPathComponent("composer-\(name)-\(Int(width)).png"), options: .atomic)
                }
            }
        }
    }

    /// The composer bar under narrow panes: every control keeps its place
    /// inside the bar instead of spilling past its edges.
    @MainActor func testComposerBarFitsNarrowPanes() async throws {
        for width in [1200.0, 900.0, 720.0, 560.0, 460.0] {
            let pane = try Pane(width: width, height: 640); defer { pane.close() }
            pane.session.state = "running"
            pane.session.draft = "a queued follow-up"
            await pane.settle(16)
            let composer = try XCTUnwrap(Self.views(ComposerTextView.self, in: pane.hosted).first)
            let card = try XCTUnwrap(composer.enclosingScrollView?.superview?.superview)
            let bounds = card.convert(card.bounds, to: nil)
            let leaves = Self.tree(card).filter { $0.name.contains("ShapeHitTesting") || $0.name.contains("CGDrawingView") || $0.name.contains("FocusRing") }
            let overflow = leaves.filter { $0.frame.maxX > bounds.maxX + 0.5 || $0.frame.minX < bounds.minX - 0.5 }
            print(String(format: "PERF composer bar at %.0f points: card %@, %d controls, %d overflowing", width, NSStringFromRect(bounds), leaves.count, overflow.count))
            XCTAssertTrue(overflow.isEmpty, "At \(width) points the composer bar pushes \(overflow.map(\.name)) outside \(bounds)")
            XCTAssertLessThanOrEqual(bounds.width, width, "The composer card stays inside the pane")
            let field = try XCTUnwrap(composer.enclosingScrollView).frame.height
            XCTAssertLessThanOrEqual(bounds.height, field + 44,
                                     "At \(width) points the composer bar wrapped onto extra rows (card \(bounds.height) for a \(field) point field)")
        }
    }
}
