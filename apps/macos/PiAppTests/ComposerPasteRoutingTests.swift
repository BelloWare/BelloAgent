import AppKit
import ObjectiveC
import XCTest
@testable import PiApp

final class ComposerPasteRoutingTests: XCTestCase, SerialTestLane {
    @MainActor func testMainChatCommandVPastesAnImage() async throws { try await paste(kind: "main") }
    @MainActor func testPendingChatCommandVPastesAnImage() async throws { try await paste(kind: "pending") }
    @MainActor func testSideComposerCommandVPastesAnImage() async throws { try await paste(kind: "side") }
    @MainActor func testEarlierMessageEditCommandVPastesAnImage() async throws { try await paste(kind: "earlier") }
    @MainActor func testQueuedEditCommandVKeepsImagesInTheParkedDraft() async throws { try await paste(kind: "queued") }

    @MainActor private func paste(kind: String) async throws {
        let fixture = try Fixture(kind: kind)
        defer { fixture.close() }
        let board = NSPasteboard(name: .init("composer-menu-paste-" + UUID().uuidString))
        // Replace the getter before it is ever invoked: even paste: and
        // AppKit menu validation see only this generated, private board.
        let method = try XCTUnwrap(class_getClassMethod(NSPasteboard.self, #selector(getter: NSPasteboard.general)))
        let replacement = imp_implementationWithBlock({ (_: AnyObject) -> NSPasteboard in board } as @convention(block) (AnyObject) -> NSPasteboard)
        let original = method_setImplementation(method, replacement)
        defer { method_setImplementation(method, original); imp_removeBlock(replacement); board.releaseGlobally() }
        guard NSPasteboard.general.name == board.name else { XCTFail("Private pasteboard routing failed"); return }
        board.setData(try ClipboardImageTests.image(), forType: .png)

        let oldMenu = NSApp.mainMenu, oldPolicy = NSApp.activationPolicy()
        defer { NSApp.mainMenu = oldMenu; NSApp.setActivationPolicy(oldPolicy) }
        let menus = ApplicationMenus(model: fixture.model, updates: UpdateController(), workspaceWindow: { fixture.window },
                                     revealWorkspace: {}, showSettings: {})
        menus.install()
        NSApp.unhide(nil); NSApp.setActivationPolicy(.accessory); NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        fixture.window.makeKeyAndOrderFront(nil); fixture.window.makeMain(); fixture.window.makeKey()
        try await eventually("fixture key window") { NSApp.keyWindow === fixture.window }
        let editor = try XCTUnwrap(fixture.pane.composer.field?.documentView as? ComposerTextView)
        XCTAssertTrue(fixture.window.makeFirstResponder(editor))
        let edit = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu)
        let command = try XCTUnwrap(edit.items.first { $0.action == #selector(NSText.paste(_:)) })
        XCTAssertNil(command.target, "Use the real responder chain")
        edit.update()
        XCTAssertTrue(command.isEnabled, "\(kind): AppKit must enable Paste for an image-only board")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber, context: nil,
            characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        let handledByWindow = fixture.window.performKeyEquivalent(with: event)
        let handled = handledByWindow || NSApp.mainMenu?.performKeyEquivalent(with: event) == true
        XCTAssertTrue(handled, "\(kind): ⌘V must reach paste: through Edit")
        guard handled else { return }
        try await eventually("\(kind) paste settled") { fixture.model.attachmentImports == 0 }
        let images = kind == "queued" ? fixture.session.draftBeforeQueueEdit?.attachments ?? [] : fixture.session.attachments
        XCTAssertEqual(images.count, 1, kind)
        XCTAssertEqual(fixture.session.draft, "Keep this draft")
        if kind == "queued" {
            XCTAssertTrue(fixture.session.attachments.isEmpty, "Queued edits remain text-only")
            XCTAssertEqual(fixture.session.draftBeforeQueueEdit?.text, "Parked draft")
        }
        XCTAssertEqual(fixture.model.displays["unrelated"]?.attachments.count, 0)
        XCTAssertNil(fixture.model.error)
        print("PASTE menu route: \(kind), handled=\(handled), attachments=\(images.count)")
    }

    @MainActor func testSubagentReaderHasNoInputComposer() throws {
        let fixture = try Fixture(kind: "child"); defer { fixture.close() }
        XCTAssertTrue(fixture.pane.composer.isHidden)
        XCTAssertNil(fixture.pane.composer.field)
        XCTAssertTrue(ConversationPaneTests.views(ComposerTextView.self, in: fixture.pane).isEmpty)
    }

    @MainActor final class Fixture {
        let root: URL, model: WorkspaceModel, session: SessionDisplay, pane: ConversationPaneView, window: NSWindow
        init(kind: String, width: CGFloat = 920) throws {
            root = scratchRoot("paste-composer-" + kind)
            let setup = try ConversationPaneTests.workbench(root: root, chats: ["paste", "unrelated"], imageModel: true)
            model = setup.model
            var chat = setup.chats[0]
            var side: SideRecord?
            if kind == "side" {
                let record = SideRecord(id: "paste-side", parentID: chat.id, workspaceID: chat.workspaceID,
                                        profileID: chat.profileID, title: "Generated side", pending: true)
                model.sides[chat.id] = record; chat = record.chat; side = record
            } else if kind == "child" {
                chat.delegation = SubagentLink(delegationID: "delegation", childSessionID: chat.id, budgetOwnerSessionID: "parent",
                    call: .init(parentSessionID: "parent", assistantMessageID: "reply", toolCallID: "tool"), parentTurnID: "turn", parentExecutionID: "execution")
                model.chats[0] = chat
            }
            session = SessionDisplay(id: chat.id); session.selectionMetadataLoaded = true
            session.draft = "Keep this draft"
            session.messages = [.init(id: "user", role: "user", text: "Describe the generated image."),
                                .init(id: "assistant", role: "assistant", text: "Paste your image into the composer.")]
            session.historyState = .ready
            model.displays[chat.id] = session; model.selectedID = chat.id; model.selected = session
            model.displays["unrelated"] = SessionDisplay(id: "unrelated")
            if kind == "pending" { model.pendingChatIDs.insert(chat.id) }
            if kind == "earlier" {
                session.editingMessageID = "user"; session.draftBeforeEdit = .init(id: chat.id, text: "Parked draft")
            }
            if kind == "queued" {
                session.queueEditingID = "queued"; session.queueEditID = "edit"
                session.draftBeforeQueueEdit = .init(id: chat.id, text: "Parked draft")
            }
            pane = ConversationPaneView(model: model)
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = pane
            pane.show(session: session, chat: chat, side: side)
            pane.layoutSubtreeIfNeeded()
        }
        func close() { model.shutdown(); window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root) }
    }
}
