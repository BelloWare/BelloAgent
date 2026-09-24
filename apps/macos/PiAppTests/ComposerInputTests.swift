import XCTest
import SwiftUI
import AppKit
@testable import PiApp

// MARK: - Stray typing

extension ConversationPaneTests {
    /// Typing while the cursor is outside any text view has to find the
    /// composer. With a long chat open the window holds a great many views,
    /// so that lookup must happen once, not on every keystroke.
    @MainActor func testFindingTheComposerForStrayTypingDoesNotWalkTheWindowPerKeystroke() async throws {
        let pane = try Pane(messages: longChat(rows: 300), width: 1000, height: 800); defer { pane.close() }
        await pane.settle(30)
        let editor = try XCTUnwrap(pane.editor)
        let surface = try XCTUnwrap(Self.views(TranscriptNativeScrollView.self, in: pane.hosted).first)
        let views = Self.tree(pane.hosted).count
        XCTAssertGreaterThan(views, 80, "A long chat really does fill the window with views (\(views))")
        // What one full search of the window costs, which is what used to run
        // for every keystroke landing outside a text view.
        var start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<200 { _ = WindowPresentationController.composerTarget(in: pane.window, sessionID: pane.session.id) }
        print(String(format: "PERF one full window search for the composer (%d views): %.3f ms", views, (ProcessInfo.processInfo.systemUptime - start) * 1000 / 200))

        let controller = WindowPresentationController()
        controller.attach(pane.window, chrome: WindowChromeView(frame: NSRect(x: 0, y: 0, width: 200, height: 36)))
        defer { controller.detach() }
        controller.focusedSessionID = pane.session.id
        let typed = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: pane.window.windowNumber, context: nil,
                                                   characters: "h", charactersIgnoringModifiers: "h", isARepeat: false, keyCode: 4))
        // A reader who keeps clicking back into the transcript and typing.
        pane.window.makeFirstResponder(surface)
        _ = controller.redirectTyping(typed)
        XCTAssertTrue(pane.window.firstResponder === editor)
        XCTAssertEqual(controller.composerLookups, 1, "The first stray keystroke searches the window once")
        start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<200 {
            pane.window.makeFirstResponder(surface)
            _ = controller.redirectTyping(typed)
            XCTAssertTrue(pane.window.firstResponder === editor)
        }
        print(String(format: "PERF stray keystroke into a %d view window (focus change included): %.3f ms", views, (ProcessInfo.processInfo.systemUptime - start) * 1000 / 200))
        XCTAssertEqual(controller.composerLookups, 1, "The composer is resolved once, not searched for on every keystroke")
        // A different chat, or a composer that left the window, searches again.
        controller.focusedSessionID = "another-chat"
        pane.window.makeFirstResponder(surface)
        _ = controller.redirectTyping(typed)
        XCTAssertEqual(controller.composerLookups, 2, "Switching chats resolves the new chat's composer")
    }
}

// MARK: - Pasting an image

extension ConversationPaneTests {
    /// A pasted screenshot must not freeze the window while it is decoded,
    /// re-encoded and written out. Only the bytes are taken on the main
    /// thread; the chip appears when the file lands.
    @MainActor func testPastingALargeScreenshotDoesNotBlockTheMainThread() async throws {
        let pane = try Pane(width: 900, height: 640, imageModel: true); defer { pane.close() }
        await pane.settle(16)
        let editor = try XCTUnwrap(pane.editor)
        // A 4000 x 3000 screenshot, as the owner's display produces.
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4000, pixelsHigh: 3000,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 4000, height: 3000).fill()
        NSColor.black.setFill(); NSRect(x: 100, y: 100, width: 2000, height: 1200).fill()
        NSGraphicsContext.restoreGraphicsState()
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let tiff = try XCTUnwrap(bitmap.tiffRepresentation)

        // What the composer used to do on the main thread for the same paste.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PiComposerImagePaste-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents(); pasteboard.setData(tiff, forType: .tiff)
        var start = ProcessInfo.processInfo.systemUptime
        let decoded = NSImage(pasteboard: pasteboard)
        let recoded = decoded?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])
        let before = (ProcessInfo.processInfo.systemUptime - start) * 1000
        XCTAssertNotNil(recoded)
        print(String(format: "PERF pasting a 4000x3000 screenshot, decode and re-encode on the main thread: %.1f ms", before))

        // PNG on the clipboard: the bytes go straight through.
        pasteboard.clearContents(); pasteboard.setData(png, forType: .png)
        start = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(editor.pasteAttachments(from: pasteboard), "A screenshot on the clipboard becomes an attachment")
        let mainThread = (ProcessInfo.processInfo.systemUptime - start) * 1000
        print(String(format: "PERF pasting a 4000x3000 screenshot, main thread: %.2f ms", mainThread))
        XCTAssertLessThan(mainThread, releaseBudget(0.016) * 1_000, "Pasting a screenshot must not cost the window a frame")
        try await waitFor("The pasted screenshot never became an attachment") { !pane.session.attachments.isEmpty }
        let attachment = try XCTUnwrap(pane.session.attachments.first)
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: attachment.path)), png, "PNG bytes are written through untouched")
        await pane.settle(8)
        XCTAssertEqual(editor.string, "", "Pasting an image must not also paste text into the composer")

        // TIFF on the clipboard: converted off the main thread, same result.
        pane.session.attachments.removeAll()
        pasteboard.clearContents(); pasteboard.setData(tiff, forType: .tiff)
        start = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(editor.pasteAttachments(from: pasteboard))
        let tiffMainThread = (ProcessInfo.processInfo.systemUptime - start) * 1000
        print(String(format: "PERF pasting a 4000x3000 TIFF screenshot, main thread: %.2f ms", tiffMainThread))
        XCTAssertLessThan(tiffMainThread, releaseBudget(0.016) * 1_000, "Converting the paste must not happen on the main thread")
        try await waitFor("The pasted TIFF never became an attachment") { !pane.session.attachments.isEmpty }
        XCTAssertEqual(pane.session.attachments.first?.mimeType, "image/png")
        // Text on the clipboard still pastes as text.
        pasteboard.clearContents(); pasteboard.setString("plain text", forType: .string)
        XCTAssertFalse(editor.pasteAttachments(from: pasteboard), "Text is not an image")
    }
}

// MARK: - The placeholder

extension ConversationPaneTests {
    /// The keyboard hints are the empty composer's placeholder, so they must
    /// sit exactly where the first character will appear, not a few points off.
    @MainActor func testThePlaceholderSitsWhereTheTypedTextWill() async throws {
        let pane = try Pane(width: 900, height: 620); defer { pane.close() }
        await pane.settle(16)
        let editor = try XCTUnwrap(pane.editor)
        let field = try XCTUnwrap(editor.enclosingScrollView)
        let region = pane.hosted.convert(field.bounds, from: field)
        func firstInk() throws -> CGPoint {
            let shot = try XCTUnwrap(pane.hosted.bitmapImageRepForCachingDisplay(in: region))
            pane.hosted.cacheDisplay(in: region, to: shot)
            let ground = try XCTUnwrap(shot.colorAt(x: shot.pixelsWide - 3, y: shot.pixelsHigh / 2)).brightnessComponent
            for x in 0..<shot.pixelsWide {
                for y in 0..<shot.pixelsHigh {
                    if let colour = shot.colorAt(x: x, y: y), abs(colour.brightnessComponent - ground) > 0.25 {
                        return CGPoint(x: Double(x) / Double(shot.pixelsWide) * region.width,
                                       y: Double(y) / Double(shot.pixelsHigh) * region.height)
                    }
                }
            }
            throw XCTSkip("Nothing was drawn in the composer")
        }
        let placeholder = try firstInk()
        pane.window.makeFirstResponder(editor)
        for character in "Message" { type(String(character), into: editor) }
        await pane.settle(8)
        XCTAssertEqual(editor.string, "Message")
        let typed = try firstInk()
        XCTAssertEqual(typed.x, placeholder.x, accuracy: 1.5, "The hint starts where the first typed character does")
        XCTAssertEqual(typed.y, placeholder.y, accuracy: 2.0, "The hint sits on the same baseline as the typed text")
        // And it leaves the moment there is a draft.
        pane.session.draft = ""
        await pane.settle(8)
        XCTAssertEqual(try firstInk().x, placeholder.x, accuracy: 1.5, "Clearing the draft brings the hint back in the same place")
    }
}

// MARK: - What a paste carries

extension ConversationPaneTests {
    /// Text copied from a document often carries a picture of itself, and a
    /// file copied in Finder carries its icon. Pasting either used to attach
    /// the picture and drop the text or the file's name. A copied image still
    /// attaches, including one from a browser, whose URL comes along with it.
    @MainActor func testPastingTextOrAFileThatAlsoCarriesAnImagePastesTheText() async throws {
        let pane = try Pane(width: 900, height: 640, imageModel: true); defer { pane.close() }
        await pane.settle(16)
        let editor = try XCTUnwrap(pane.editor)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), tiff = try XCTUnwrap(bitmap.tiffRepresentation)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PiComposerMixedPaste-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }

        // Rich text with a rendering of itself, as Pages, Numbers and Office put it.
        let rich = NSPasteboardItem()
        rich.setString("Quarterly totals: 1,204", forType: .string)
        rich.setData(Data("{\\rtf1 Quarterly totals: 1,204}".utf8), forType: .rtf)
        rich.setData(png, forType: .png)
        pasteboard.clearContents(); pasteboard.writeObjects([rich])
        XCTAssertFalse(editor.pasteAttachments(from: pasteboard), "Text that carries a picture of itself pastes as text")

        // A file copied in Finder: its URL, its name and its icon.
        let notes = URL(fileURLWithPath: scratchBase()).appendingPathComponent("notes-\(UUID().uuidString).txt")
        try Data("notes".utf8).write(to: notes); defer { try? FileManager.default.removeItem(at: notes) }
        let file = NSPasteboardItem()
        file.setString(notes.absoluteString, forType: .fileURL)
        file.setString(notes.lastPathComponent, forType: .string)
        file.setData(tiff, forType: .tiff)
        pasteboard.clearContents(); pasteboard.writeObjects([file])
        XCTAssertFalse(editor.pasteAttachments(from: pasteboard), "A copied file pastes its name, not its icon")
        await pane.settle(8)
        XCTAssertTrue(pane.session.attachments.isEmpty, "Nothing was attached")

        // An image copied from a browser comes with its own URL as text; it is still an image.
        let web = NSPasteboardItem()
        web.setData(tiff, forType: .tiff)
        web.setString("https://example.com/chart.png", forType: .URL)
        web.setString("https://example.com/chart.png", forType: .string)
        pasteboard.clearContents(); pasteboard.writeObjects([web])
        XCTAssertTrue(editor.pasteAttachments(from: pasteboard), "A copied web image still attaches")
        try await waitFor("The copied web image never became an attachment") { pane.session.attachments.count == 1 }

        // A screenshot alone attaches as before.
        pasteboard.clearContents(); pasteboard.setData(png, forType: .png)
        XCTAssertTrue(editor.pasteAttachments(from: pasteboard))
        try await waitFor("The screenshot never became an attachment") { pane.session.attachments.count == 2 }
    }

    /// An input method sends a marked-text step for every key. Each one used
    /// to copy and compare the whole draft for a measurement that is off in
    /// the app, which on a long draft is the cost of the keystroke.
    @MainActor func testMarkedTextOnALongDraftCostsWhatItDoesOnAShortOne() async throws {
        let pane = try Pane(width: 900, height: 640); defer { pane.close() }
        await pane.settle(16)
        let editor = try XCTUnwrap(pane.editor)
        XCTAssertTrue(pane.window.makeFirstResponder(editor))
        XCTAssertFalse(PerformanceProbe.shared.enabled, "the measurement is off, as in the app")
        func stepCost(draft: String) async -> Double {
            pane.session.draft = draft
            await pane.settle(6)
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            let started = ProcessInfo.processInfo.systemUptime
            for index in 0..<30 {
                editor.setMarkedText("か" + String(repeating: "な", count: index % 4), selectedRange: NSRange(location: 1, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            let cost = (ProcessInfo.processInfo.systemUptime - started) * 1_000 / 30
            editor.unmarkText()
            return cost
        }
        let short = await stepCost(draft: "A short line.")
        let long = await stepCost(draft: String(repeating: "A line of a long draft that is typed through an input method.\n", count: 3_300))
        print(String(format: "PERF marked-text step: %.3f ms on a short draft, %.3f ms on a 200 KB draft", short, long))
        XCTAssertLessThan(long, short * 3 + 0.5, "A marked-text step must not scale with the length of the draft")
        XCTAssertLessThan(long, releaseBudget(0.002) * 1_000)
    }
}

// MARK: - The page keys in a side conversation
extension ConversationPaneTests {
    /// Page Up, Page Down, Home and End in a side conversation's composer move
    /// the side conversation. They used to take the first transcript in the
    /// window, which is always the chat's own, and page the conversation the
    /// reader was not in.
    @MainActor func testThePageKeysInASideComposerMoveTheSideConversation() async throws {
        let shell = try SmoothShellTests.Shell(chats: ["Reading"], rows: 60)
        registerWorkspaceFixtureTeardown(shell.model, root: shell.root)
        defer { shell.close() }
        let model = shell.model, parent = shell.chats[0]
        let child = ChatRecord(id: "chat-side", workspaceID: shell.project.id, title: "Side", path: nil, profileID: parent.profileID,
                               toolMode: "read-only", parentSessionID: parent.id)
        model.chats.append(child)
        let side = SessionDisplay(id: child.id)
        side.messages = SmoothShellTests.Shell.conversation(rows: 60, prefix: child.id)
        side.selectionMetadataLoaded = true
        model.displays[child.id] = side
        await model.select(parent.id)
        await model.showSide(child.id)
        await shell.settle(1.5)
        let markers = shell.markers
        XCTAssertEqual(markers.count, 2, "the chat and its side are both on screen")
        let main = try XCTUnwrap(markers.first?.enclosingScrollView), sideScroll = try XCTUnwrap(markers.last?.enclosingScrollView)
        let editors = SmoothShellTests.views(ComposerTextView.self, in: shell.hosted)
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        let editor = try XCTUnwrap(editors.last)
        XCTAssertEqual(editor.sessionID, child.id, "the right-hand composer is the side's")
        XCTAssertTrue(shell.window.makeFirstResponder(editor))
        for marker in markers { marker.page?.jumpToLatest() }
        await shell.settle(0.8)
        let mainBottom = main.contentView.bounds.origin.y, sideBottom = sideScroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(sideBottom, 300, "the side has a conversation to page back through")

        @MainActor func press(_ keyCode: UInt16, _ character: String, _ what: String) async throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function],
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: shell.window.windowNumber, context: nil,
                                                       characters: character, charactersIgnoringModifiers: character,
                                                       isARepeat: false, keyCode: keyCode), what)
            shell.window.sendEvent(event)
            await shell.settle(0.4)
        }
        // The chat beside it keeps following its newest row: rows measured
        // after the jump can still move it a little, but a page never.
        let mainPage = try XCTUnwrap(markers.first?.page), sidePage = try XCTUnwrap(markers.last?.page)
        try await press(116, "\u{F72C}", "Page Up")
        XCTAssertLessThan(sideScroll.contentView.bounds.origin.y, sideBottom - 200, "Page Up moves the side conversation")
        XCTAssertFalse(sidePage.followsBottom, "paging back detaches the side's page, as a wheel does")
        XCTAssertTrue(mainPage.followsBottom, "the chat beside it still follows its newest row")
        XCTAssertGreaterThan(main.contentView.bounds.origin.y, mainBottom - 200, "and was not paged")
        let paged = sideScroll.contentView.bounds.origin.y
        try await press(119, "\u{F72B}", "End")
        let sideEnd = (sideScroll.documentView?.frame.height ?? 0) - sideScroll.contentView.bounds.height + sideScroll.contentInsets.bottom
        XCTAssertGreaterThan(sideScroll.contentView.bounds.origin.y, paged + 200, "End moves the side conversation")
        XCTAssertGreaterThan(sideScroll.contentView.bounds.origin.y, sideEnd - 60, "End takes the side back to its newest row")
        XCTAssertTrue(mainPage.followsBottom)
        XCTAssertGreaterThan(main.contentView.bounds.origin.y, mainBottom - 200)
        XCTAssertTrue(shell.window.firstResponder === editor, "the reader keeps typing in the side")
        XCTAssertEqual(editor.string, "", "paging must not type into the side's draft")
    }
}

/// Views that must change in place rather than be removed and inserted
/// again: each would otherwise replay a transition the reader sees as a
/// flicker. Read from the source, as `BlockingAlertTests` reads it.
extension ConversationPaneTests {
    static func appSource(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PiApp")
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
    /// The code from `start` to the first `end` after it.
    static func excerpt(_ source: String, from start: String, to end: String) throws -> Substring {
        let from = try XCTUnwrap(source.range(of: start), "\(start) not found")
        let to = try XCTUnwrap(source.range(of: end, range: from.upperBound..<source.endIndex), "\(end) not found after \(start)")
        return source[from.lowerBound..<to.upperBound]
    }
    func testLiveTurnBarKeepsItsIdentityAcrossPresentations() throws {
        let body = try Self.excerpt(Self.appSource("Transcript/NativeTranscriptView.swift"), from: "LiveTurnBarSlot(turn:", to: "}")
        XCTAssertFalse(body.contains(".id("), "A new presentation of the chat replays the live turn bar's entrance")
    }
    func testModelChipChangesItsLabelInPlace() throws {
        let label = try Self.excerpt(Self.appSource("Workspaces/ModelSwitchControls.swift"), from: "Text(text).font(.system(size: 12, weight: .medium))", to: "if loading")
        XCTAssertTrue(label.contains(".contentTransition(.opacity)"))
        XCTAssertFalse(label.contains(".id(text)"), "A new model name removes the chip's label and inserts another")
        XCTAssertFalse(label.contains(".transition("), "The chip's label is replaced, not changed")
    }
    func testProjectsSheetCrossesItsPanesInOneStack() throws {
        let panes = try Self.excerpt(Self.appSource("Workspaces/WorkspaceManagerView.swift"), from: "list.frame(width: 250)", to: "NewWorkspaceDraft.editing")
        XCTAssertTrue(panes.contains("ZStack {"))
        XCTAssertFalse(panes.contains("Group {"), "A Group gives each pane its own frame: the leaving and arriving panes stand side by side")
    }
}
