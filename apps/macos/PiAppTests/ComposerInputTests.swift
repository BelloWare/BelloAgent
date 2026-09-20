import XCTest
import SwiftUI
import AppKit
@testable import PiApp

// MARK: - Stray typing

extension ConversationPaneTests {
    /// Typing while the cursor is outside any text view has to find the
    /// composer. With a long chat open the window holds hundreds of views, so
    /// that lookup must happen once, not on every keystroke.
    @MainActor func testFindingTheComposerForStrayTypingDoesNotWalkTheWindowPerKeystroke() async throws {
        let pane = try Pane(messages: longChat(rows: 300), width: 1000, height: 800); defer { pane.close() }
        await pane.settle(30)
        let editor = try XCTUnwrap(pane.editor)
        let surface = try XCTUnwrap(Self.views(TranscriptNativeScrollView.self, in: pane.hosted).first)
        let views = Self.tree(pane.hosted).count
        XCTAssertGreaterThan(views, 150, "A long chat really does fill the window with views (\(views))")
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
