import AppKit
import Combine
import ImageIO
import ObjectiveC
import UniformTypeIdentifiers
import XCTest
@testable import PiApp

/// The main composer's actual Edit menu and key equivalent, including the
/// background conversion, draft refresh and Send that follow the press.
final class ComposerPasteLifecycleTests: XCTestCase, SerialTestLane {
    @MainActor func testImageSourcesStayInTheMainComposerThroughRefreshAndSend() async throws {
        let bench = try await gatewayWorkspace("paste-lifecycle", projectID: "paste",
            gatewayEnvironment: ["PI_APP_UI_FIXTURE_SUMMARY_DELAY": "0", "PI_APP_UI_FIXTURE_SLOW_WORDS": "400"])
        _ = try await bench.vault.update(expectedRevision: 0) { $0.profiles[0].profile.advancedJSON = "{\"input\":[\"text\",\"image\"]}" }
        let model = makeWorkspaceModel(stateRoot: bench.state, vault: bench.vault)
        try await model.reloadConfiguration()
        model.prewarmsHelpers = false
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        model.launching = false
        let fixtures = try sources(in: bench.root)
        for (scenario, saved, warm, phase) in [
            ("new-cold", false, false, "idle"), ("new-warm", false, true, "idle"),
            ("saved-cold", true, false, "idle"), ("saved-warm", true, true, "idle"),
            ("during-run", true, true, "running"), ("after-run", true, true, "finished"),
        ] {
            for hasDraft in [false, true] {
                let id = "\(scenario)-\(hasDraft)", draft = hasDraft ? "Keep this draft" : ""
                var chat = ChatRecord(id: id, workspaceID: bench.workspace.id, title: id, profileID: bench.profile.id)
                chat.titleWasEdited = true
                model.chats.append(chat)
                let view = SessionDisplay(id: id)
                model.displays[id] = view; model.selectedID = id; model.selected = view; model.focusedSessionID = id
                if !saved { model.pendingChatIDs.insert(id) }
                else { try await model.store?.put(chat, kind: "chat", id: id) }
                var host: HostSupervisor?
                if saved || warm {
                    host = try await model.open(chat)
                    if saved {
                        _ = try await host?.request("turn.submit", sessionID: id, params: ["clientTurnId": .string("history-" + id), "text": .string("A generated question")])
                        try await idle(try XCTUnwrap(host), id: id)
                        model.refresh(id)
                        try await eventually("saved history is shown", timeout: .seconds(30)) { !view.snapshotInFlight && !view.messages.isEmpty }
                    }
                    if !warm {
                        try await host?.shutdownAndWait(); model.hosts.removeValue(forKey: chat.workspaceID); model.opened.remove(id); host = nil
                    }
                }
                try await model.loadDraftBaseline(view)
                let pane = ConversationPaneView(model: model)
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 640), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = pane
                defer { window.contentView = nil; window.close() }
                pane.show(session: view, chat: try XCTUnwrap(model.record(id)))
                let menu = try PasteMenu(model: model, window: window)
                defer { menu.close() }
                if phase == "running" {
                    _ = try await host?.request("turn.submit", sessionID: id, params: ["clientTurnId": .string("running-" + id), "text": .string("fixture:slow Paste while this reply runs")])
                    model.refresh(id)
                    try await eventually("the run is visible", timeout: .seconds(30)) { view.busy }
                }
                for (index, source) in fixtures.enumerated() {
                    XCTAssertEqual(model.opened.contains(id), warm, "\(id)/\(source.name): the helper stays in the requested state")
                    view.draft = draft; view.attachments = []
                    pane.composer.refresh(); pane.layoutSubtreeIfNeeded()
                    let editor = try XCTUnwrap(pane.composer.field?.documentView as? ComposerTextView)
                    source.write(menu.board)
                    try await menu.paste(into: editor, commandV: index.isMultiple(of: 2))
                    XCTAssertGreaterThan(view.imageImports, 0, "\(id)/\(source.name): import admitted at the press")
                    model.submitComposer(intent: .followUp, sessionID: id)
                    XCTAssertEqual(view.draft, draft, "Send waits for the image")
                    try await eventually("\(id)/\(source.name) import settled", timeout: .seconds(30)) { view.imageImports == 0 }
                    model.refresh(id)
                    try await eventually("refresh settled", timeout: .seconds(30)) { !view.snapshotInFlight }
                    pane.composer.refresh(); pane.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    XCTAssertEqual(view.attachments.count, 1, "\(id)/\(source.name): \(model.error ?? view.notice)")
                    XCTAssertEqual(view.draft, draft)
                    XCTAssertEqual(ConversationPaneTests.views(ComposerImageAttachmentChip.self, in: pane.composer).count, 1, "The attached image stays visible")
                    XCTAssertNil(model.error)
                    let image = try XCTUnwrap(view.attachments.first)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
                    XCTAssertNotNil(CGImageSourceCreateWithURL(URL(fileURLWithPath: image.path) as CFURL, nil))
                    print("PASTE2 source=\(source.name) scenario=\(id) attached=\(view.attachments.count) bytes=\(image.bytes)")
                }
                // One real submission from each state, through the packaged helper.
                if phase == "running" {
                    XCTAssertTrue(view.busy, "The paste matrix ran while the reply was arriving")
                    _ = try await host?.request("turn.stop", sessionID: id)
                    try await idle(try XCTUnwrap(host), id: id, acceptsPause: true)
                }
                model.submitComposer(intent: .followUp, sessionID: id)
                try await eventually("the image message sends", timeout: .seconds(30)) { !view.loading && view.attachments.isEmpty }
                host = model.hosts[chat.workspaceID]
                try await idle(try XCTUnwrap(host), id: id)
                let snapshot = try await host?.request("session.snapshot", sessionID: id, params: ["includeMessages": .bool(true)]).object ?? [:]
                let rows = try TranscriptMessage.page(snapshot["messages"] ?? .array([]))
                XCTAssertTrue(rows.contains { $0.role == "user" && $0.text == (draft.isEmpty ? "Image" : draft) })
                let captureFile = bench.root.appendingPathComponent("captures.json")
                try await eventually("the gateway finishes its capture", timeout: .seconds(30)) { FileManager.default.fileExists(atPath: captureFile.path) }
                let requests = try Data(contentsOf: captureFile)
                let captures = try JSONDecoder().decode([[String: WireValue]].self, from: requests)
                let sent = captures.filter { $0["sessionID"]?.string == id }.compactMap { $0["request"]?.string.flatMap { Data(base64Encoded: $0) } }
                XCTAssertTrue(sent.contains { String(decoding: $0, as: UTF8.self).contains("input_image") }, "The loopback provider receives the pasted image in this chat")
            }
        }
    }

    @MainActor func testPastedImageHasAThumbnail() async throws {
        let fixture = try mainFixture()
        defer { fixture.close() }
        let menu = try PasteMenu(model: fixture.model, window: fixture.window)
        defer { menu.close() }
        menu.board.setData(try thumbnailImage(), forType: .png)
        try await menu.paste(into: try XCTUnwrap(fixture.pane.composer.field?.documentView as? ComposerTextView), commandV: true)
        try await eventually("paste settled") { fixture.session.imageImports == 0 }
        fixture.pane.composer.refresh(); fixture.pane.layoutSubtreeIfNeeded()
        XCTAssertEqual(fixture.session.attachments.count, 1)
        let chip = try XCTUnwrap(ConversationPaneTests.views(ComposerImageAttachmentChip.self, in: fixture.pane.composer).first)
        try await eventually("the pasted image's preview is decoded") { chip.main.thumbnail != nil }
        fixture.pane.layoutSubtreeIfNeeded(); fixture.window.displayIfNeeded()
        let preview = try XCTUnwrap(chip.main.thumbnail)
        XCTAssertLessThanOrEqual(max(preview.size.width, preview.size.height), 96)
        let bitmap = try XCTUnwrap(chip.main.bitmapImageRepForCachingDisplay(in: chip.main.bounds))
        chip.main.cacheDisplay(in: chip.main.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / chip.main.bounds.width
        var red = 0, blue = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<min(bitmap.pixelsWide, Int(32 * scale)) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.8 && color.blueComponent < 0.2 { red += 1 }
                if color.blueComponent > 0.8 && color.redComponent < 0.2 { blue += 1 }
            }
        }
        XCTAssertGreaterThan(red, 60, "The thumbnail's red half is drawn")
        XCTAssertGreaterThan(blue, 60, "The thumbnail's blue half is drawn")
    }

    /// Lazy pasteboard providers can re-enter the app before returning bytes.
    /// Send must already be held then, not only during background conversion.
    @MainActor func testSendCannotOvertakeALazyPasteboardRead() async throws {
        for kind in ["png", "tiff", "html", "file"] {
            let fixture = try mainFixture()
            defer { fixture.close() }
            try await fixture.model.reloadConfiguration()
            let chat = try XCTUnwrap(fixture.model.record(fixture.session.id))
            try await fixture.model.store?.put(chat, kind: "chat", id: chat.id)
            var frames: [[String: WireValue]] = [], accepted = 0, importsAtRead = -1
            let host = HostSupervisor(commandSender: { frames.append($0) })
            try await host.connect(cwd: fixture.root, state: fixture.root.appendingPathComponent("host"))
            fixture.model.hosts[chat.workspaceID] = host; fixture.model.opened.insert(chat.id)
            fixture.model.sendSteps = { if $0 == "accepted" { accepted += 1 } }
            let png = try ClipboardImageTests.image()
            let type: NSPasteboard.PasteboardType, bytes: Data
            if kind == "file" {
                let file = fixture.root.appendingPathComponent("copied.png"); try png.write(to: file)
                type = .fileURL; bytes = Data(file.absoluteString.utf8)
            } else if kind == "tiff" { type = .tiff; bytes = try ClipboardImageTests.image(type: .tiff) }
            else { type = .png; bytes = png }
            let provider = ReentrantImage(bytes: bytes) {
                importsAtRead = fixture.session.imageImports
                fixture.pane.composer.send.performClick(nil)
            }
            let menu = try PasteMenu(model: fixture.model, window: fixture.window)
            defer { menu.close() }
            let item = NSPasteboardItem()
            if kind == "html" {
                item.setString("Image caption", forType: .string)
                item.setString("<img src='data:image/png;base64,generated'>", forType: .html)
            }
            item.setDataProvider(provider, forTypes: [type]); menu.board.writeObjects([item])
            XCTAssertEqual(provider.reads, 0, "Writing types does not fetch bytes")
            try await menu.paste(into: try XCTUnwrap(fixture.pane.composer.field?.documentView as? ComposerTextView), commandV: kind != "html")
            XCTAssertTrue(provider.readOnMain, "The generated provider re-enters the main paste action")
            XCTAssertGreaterThan(importsAtRead, 0, "\(kind): Send is held before a provider can re-enter the app")
            XCTAssertEqual(accepted, 0, "\(kind): Send during byte delivery does not capture a text-only message")
            try await eventually("the lazy image is attached") { fixture.session.imageImports == 0 }
            // On the old implementation, retire its premature submission too,
            // so the failing-first run leaves no outstanding fake-host request.
            if accepted == 0 {
                XCTAssertEqual(fixture.session.draft, "Keep this draft")
                XCTAssertEqual(fixture.session.attachments.count, 1)
                fixture.pane.composer.refresh(); fixture.pane.composer.send.performClick(nil)
            }
            try await eventually("the image message reaches the helper") { frames.contains { $0["method"]?.string == "turn.submit" } }
            let frame = try XCTUnwrap(frames.first { $0["method"]?.string == "turn.submit" })
            let images = frame["params"]?.object?["attachments"]?.array ?? []
            print("PASTE2 lazy=\(kind) importsAtRead=\(importsAtRead) sends=\(accepted) sentImages=\(images.count)")
            XCTAssertEqual(images.count, 1, "\(kind): the message carries its pasted image")
            XCTAssertEqual(frame["params"]?.object?["text"]?.string, "Keep this draft")
            host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(try XCTUnwrap(host.epoch)),
                "commandId": try XCTUnwrap(frame["commandId"]), "ok": .bool(true), "result": .object(["accepted": .bool(true)])]),
                connectionID: try XCTUnwrap(host.connectionID))
            try await eventually("the lazy paste's send settles") { !fixture.session.loading }
            try await host.shutdownAndWait()
        }
    }

    private final class ReentrantImage: NSObject, NSPasteboardItemDataProvider {
        let bytes: Data
        let onRead: @MainActor () -> Void
        private let mutex = NSLock()
        private var count = 0, main = true
        var reads: Int { mutex.lock(); defer { mutex.unlock() }; return count }
        var readOnMain: Bool { mutex.lock(); defer { mutex.unlock() }; return main }
        init(bytes: Data, onRead: @escaping @MainActor () -> Void) { self.bytes = bytes; self.onRead = onRead }
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            mutex.lock(); count += 1; main = main && Thread.isMainThread; let first = count == 1; mutex.unlock()
            let callback = onRead
            if first && Thread.isMainThread { MainActor.assumeIsolated { callback() } }
            item.setData(bytes, forType: type)
        }
    }

    /// An app can advertise a file URL it cannot deliver alongside its image.
    /// Metadata alone must not turn that available image into an empty paste.
    @MainActor func testAnUnavailableFileURLDoesNotSilentlyDiscardTheImage() async throws {
        let fixture = try mainFixture()
        defer { fixture.close() }
        let menu = try PasteMenu(model: fixture.model, window: fixture.window)
        defer { menu.close() }
        let editor = try XCTUnwrap(fixture.pane.composer.field?.documentView as? ComposerTextView)
        for (index, fileURL) in [Data(), Data("not a file URL".utf8)].enumerated() {
            menu.board.clearContents()
            menu.board.setData(try ClipboardImageTests.image(), forType: .png)
            menu.board.setData(fileURL, forType: .fileURL)
            fixture.session.attachments = []
            try await menu.paste(into: editor, commandV: index == 0)
            try await eventually("the paste finishes") { fixture.session.imageImports == 0 }
            XCTAssertEqual(fixture.session.attachments.count, 1, "A missing file representation cannot swallow the available bitmap")
            XCTAssertEqual(fixture.session.draft, "Keep this draft")
            XCTAssertNil(fixture.model.error)
        }
    }

    @MainActor func testAnUnavailableImportShowsWhyAndKeepsTheDraft() async throws {
        let fixture = try mainFixture()
        defer { fixture.close() }
        let menu = try PasteMenu(model: fixture.model, window: fixture.window)
        defer { menu.close() }
        menu.board.setData(try ClipboardImageTests.image(), forType: .png)
        fixture.model.installPreparing = true
        defer { fixture.model.installPreparing = false }
        try await menu.paste(into: try XCTUnwrap(fixture.pane.composer.field?.documentView as? ComposerTextView), commandV: true)
        XCTAssertEqual(fixture.session.imageImports, 0)
        XCTAssertTrue(fixture.session.attachments.isEmpty)
        XCTAssertEqual(fixture.session.draft, "Keep this draft")
        XCTAssertTrue(fixture.session.notice.contains("preparing to close"), "An unavailable destination must explain the refused paste")
        XCTAssertEqual(fixture.model.error, fixture.session.notice, "The refusal survives the next snapshot")
    }

    @MainActor func testAnImportBecomingUnavailableDuringConversionShowsWhy() async throws {
        let fixture = try mainFixture()
        defer { fixture.close() }
        let menu = try PasteMenu(model: fixture.model, window: fixture.window)
        defer { menu.close() }
        menu.board.setData(try ClipboardImageTests.image(type: .tiff), forType: .tiff)
        try await menu.paste(into: try XCTUnwrap(fixture.pane.composer.field?.documentView as? ComposerTextView), commandV: true)
        XCTAssertGreaterThan(fixture.session.imageImports, 0)
        fixture.model.installPreparing = true
        defer { fixture.model.installPreparing = false }
        try await eventually("the unavailable import finishes") { fixture.session.imageImports == 0 }
        XCTAssertTrue(fixture.session.attachments.isEmpty)
        XCTAssertEqual(fixture.session.draft, "Keep this draft")
        XCTAssertTrue(fixture.session.notice.contains("preparing to close"), "An import that becomes unavailable must explain its refusal")
        XCTAssertEqual(fixture.model.error, fixture.session.notice)
    }

    @MainActor func testAnImportInvalidatedWhileRecoveryWaitsShowsWhy() async throws {
        let fixture = try mainFixture()
        defer { fixture.close() }
        let menu = try PasteMenu(model: fixture.model, window: fixture.window)
        defer { menu.close() }
        let gate = AsyncGate()
        let recovery = Task { await gate.wait() }
        fixture.model.draftWrites.recoveries[fixture.session.id] = recovery
        defer { fixture.model.draftWrites.recoveries.removeValue(forKey: fixture.session.id); recovery.cancel() }
        var imports: [Int] = []
        let observation = fixture.session.$imageImports.sink { imports.append($0) }
        defer { observation.cancel() }
        menu.board.setData(try ClipboardImageTests.image(), forType: .png)
        try await menu.paste(into: try XCTUnwrap(fixture.pane.composer.field?.documentView as? ComposerTextView), commandV: false)
        try await eventually("the image waits behind recovery") { imports.filter { $0 == 2 }.count >= 2 && fixture.session.imageImports == 1 }
        // Recovery may restore an earlier-message draft. The image cannot
        // enter a different draft, but its refusal must remain visible.
        fixture.session.restoreDraft(DraftRecord(id: fixture.session.id, text: "Recovered draft",
            edit: MessageEditDraft(messageID: "original", originalText: "Kept original")))
        fixture.model.draftWrites.recoveries.removeValue(forKey: fixture.session.id)
        await gate.open(); await recovery.value
        try await eventually("the refused import finishes") { fixture.session.imageImports == 0 }
        XCTAssertTrue(fixture.session.attachments.isEmpty)
        XCTAssertEqual(fixture.session.draft, "Recovered draft")
        XCTAssertTrue(fixture.session.notice.contains("draft changed"), "An invalidated recovery wait must explain the refused paste")
        XCTAssertEqual(fixture.model.error, fixture.session.notice)
    }

    @MainActor private func mainFixture() throws -> ComposerPasteRoutingTests.Fixture {
        let fixture = try ComposerPasteRoutingTests.Fixture(kind: "main")
        fixture.model.prewarmsHelpers = false
        fixture.model.automaticContextOperation = { _, _ in throw CancellationError() }
        fixture.model.cancelAutomaticContext()
        return fixture
    }

    @MainActor private func idle(_ host: HostSupervisor, id: String, acceptsPause: Bool = false) async throws {
        try await eventually("the synthetic run finishes", timeout: .seconds(30), until: {
            let status = try await host.request("session.status", sessionID: id).object ?? [:]
            if status["state"]?.string == "error" { XCTFail("The synthetic run failed: \(status["preflightError"]?.string ?? "Unknown error")"); throw HostError.failure("Synthetic run failed") }
            return status["state"]?.string == "idle" || acceptsPause && status["state"]?.string == "paused"
        })
    }

    struct Source { let name: String; let write: @MainActor (NSPasteboard) -> Void }
    private func thumbnailImage() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 48, height: 64))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 48, y: 0, width: 48, height: 64))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
    @MainActor private func sources(in folder: URL) throws -> [Source] {
        var sources: [Source] = []
        for (name, type, width, height) in [("screenshot-png", UTType.png, 400, 300), ("screenshot-tiff", .tiff, 400, 300),
                ("retina-png", .png, 5120, 2880), ("retina-tiff", .tiff, 5120, 2880), ("app-jpeg", .jpeg, 400, 300)] {
            let bytes = try XCTUnwrap(ImageFormatImportTests.image(type, width: width, height: height))
            sources.append(Source(name: name, write: { board in board.clearContents(); board.setData(bytes, forType: .init(type.identifier)) }))
        }
        let png = try ClipboardImageTests.image()
        let tiff = try ClipboardImageTests.image(type: .tiff)
        sources.append(Source(name: "screenshot-png-tiff", write: { board in
            board.clearContents(); board.setData(png, forType: .png); board.setData(tiff, forType: .tiff)
        }))
        sources.append(Source(name: "app-html-image", write: { board in
            board.clearContents(); board.setString("Picture caption", forType: .string)
            board.setString("<html><body><img src='data:image/png;base64,generated'></body></html>", forType: .html); board.setData(png, forType: .png)
        }))
        for type in [UTType.png, .jpeg, .heic] {
            let file = folder.appendingPathComponent("Finder image." + (type.preferredFilenameExtension ?? "png"))
            try XCTUnwrap(ImageFormatImportTests.image(type, width: 400, height: 300)).write(to: file)
            sources.append(Source(name: "finder-" + type.identifier, write: { board in board.clearContents(); board.writeObjects([file as NSURL]) }))
        }
        return sources
    }

    @MainActor final class PasteMenu {
        let board = NSPasteboard(name: .init("paste-lifecycle-" + UUID().uuidString))
        let window: NSWindow
        private let method: Method, original: IMP, replacement: IMP
        private let previousMenu: NSMenu?, previousPolicy: NSApplication.ActivationPolicy
        init(model: WorkspaceModel, window: NSWindow) throws {
            self.window = window
            method = try XCTUnwrap(class_getClassMethod(NSPasteboard.self, #selector(getter: NSPasteboard.general)))
            let board = board
            replacement = imp_implementationWithBlock({ (_: AnyObject) -> NSPasteboard in board } as @convention(block) (AnyObject) -> NSPasteboard)
            original = method_setImplementation(method, replacement)
            previousMenu = NSApp.mainMenu; previousPolicy = NSApp.activationPolicy()
            ApplicationMenus(model: model, updates: UpdateController(), workspaceWindow: { window }, revealWorkspace: {}, showSettings: {}).install()
            NSApp.unhide(nil); NSApp.setActivationPolicy(.accessory); NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeMain(); window.makeKey()
        }
        func paste(into editor: ComposerTextView, commandV: Bool) async throws {
            try await eventually("the paste fixture has the key window") { NSApp.keyWindow === self.window }
            XCTAssertTrue(window.makeFirstResponder(editor))
            let edit = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu)
            let item = try XCTUnwrap(edit.items.first { $0.action == #selector(NSText.paste(_:)) })
            edit.update(); XCTAssertTrue(item.isEnabled)
            if commandV {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
                XCTAssertTrue(window.performKeyEquivalent(with: event) || NSApp.mainMenu?.performKeyEquivalent(with: event) == true)
            } else { XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)) }
        }
        func close() {
            NSApp.mainMenu = previousMenu; NSApp.setActivationPolicy(previousPolicy)
            method_setImplementation(method, original); imp_removeBlock(replacement); board.releaseGlobally()
        }
    }
}
