import AppKit
import XCTest
@testable import PiApp

/// Native tracking runs a nested AppKit event loop, so these fixtures run alone.
@MainActor final class SidebarNativeBindingTests: XCTestCase, SerialTestLane {
    private enum Pool: String { case chat, side, panel }
    private struct Unchecked<Value>: @unchecked Sendable { let value: Value }

    private func event(_ type: NSEvent.EventType, button: NSButton, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type,
            location: button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func assertHeldButtonCannotBeRecycled(_ pool: Pool, embedded: Bool = false, directRebind: Bool = false) throws {
        let root = scratchRoot("native-row-binding-\(pool.rawValue)")
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 280, height: 320))
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer {
            while NSApp.nextEvent(matching: .any, until: .now, inMode: .default, dequeue: true) != nil {}
            window.orderOut(nil); window.contentView = nil; window.close(); model.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        let replace: @MainActor (String) -> Void
        let mounted: @MainActor () -> NSView?
        switch pool {
        case .chat, .side:
            let document = SidebarListDocument(model: model)
            scroll.documentView = document
            replace = { id in
                let entry: SidebarEntry
                if pool == .chat {
                    let chat = ChatRecord(id: id, workspaceID: "project", title: id, path: nil, profileID: "fixture")
                    entry = .chat(chat: chat, state: SidebarChatRowState(hasSide: true, available: 220), projectID: "project")
                } else { entry = .side(SidebarSideRowState(id: id, title: id, available: 220)) }
                if directRebind, case .chat(let chat, let state, let projectID) = entry,
                   let row = document.views.values.first as? SidebarChatRowView {
                    row.apply(chat: chat, state: state, projectID: projectID, force: true)
                } else {
                    document.update(SidebarListContents(entries: [entry], gaps: [3], owners: [("project", nil)]), width: 280, animated: false)
                }
                document.layoutSubtreeIfNeeded()
            }
            mounted = { document.views.values.first }
        case .panel:
            let document = SidesPanelListDocument(model: model, newSide: NSView(), empty: NSView(), glide: PiKit.SelectionGlide())
            document.content = { .init(entry: $0, stats: ChatRowStats(totals: nil), unread: false, failed: false, enabled: true) }
            scroll.documentView = document
            replace = { id in
                document.update([.init(entry: SidesPanelEntry(id: id, title: id, open: false, saved: true), unread: false)], hasParent: true)
                document.frame = CGRect(x: 0, y: 0, width: 280, height: max(320, document.height(forWidth: 280)))
                document.refreshVisible(); document.layoutSubtreeIfNeeded()
            }
            mounted = { document.rows.values.first }
        }
        replace("original")
        window.orderFront(nil); scroll.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let original = try XCTUnwrap(mounted())
        func mainButton(_ view: NSView) throws -> PiKit.SelectableRow {
            try XCTUnwrap((view as? SidebarChatRowView)?.row ?? (view as? SidebarSideRowView)?.row ?? (view as? SidesPanelRowView)?.row)
        }
        let button: PiKit.ButtonBase
        if embedded {
            button = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.IconButton.self, in: original)
                .first { $0.accessibilityLabel() == "Hide child chats" })
        } else { button = try mainButton(original) }
        var fired: [String] = []
        button.onPress = { [weak original] in
            guard let original else { fired.append("released"); return }
            fired.append((original as? SidebarChatRowView)?.chat.id ?? (original as? SidebarSideRowView)?.state.id
                ?? (original as? SidesPanelRowView)?.content?.entry.id ?? "retired")
        }
        let release = Unchecked(value: try event(.leftMouseUp, button: button, window: window))
        let trackingButton = Unchecked(value: button)
        var replacedDuringTracking = false
        RunLoop.main.perform(inModes: [.eventTracking]) {
            MainActor.assumeIsolated {
                // Highlight is not a reliable tracking flag: AppKit can clear
                // it while the mouse is still down, as prepareForReuse does.
                trackingButton.value.cell?.isHighlighted = false
                replace("replacement")
                replacedDuringTracking = true
                if directRebind {
                    XCTAssertTrue(mounted() === original, "Exercise dispatch independently of the pool's exclusion")
                    trackingButton.value.onPress = { fired.append("replacement") }
                } else { XCTAssertFalse(mounted() === original, "A native tracking view cannot enter this pool") }
                NSApp.postEvent(release.value, atStart: false)
            }
        }
        button.mouseDown(with: try event(.leftMouseDown, button: button, window: window))
        XCTAssertTrue(replacedDuringTracking)
        print("NATIVE-REUSE \(pool.rawValue)\(embedded ? " embedded" : ""): stale actions \(fired)")
        XCTAssertTrue(fired.isEmpty, "Releasing a retired binding cannot dispatch a native button action")

        let fresh = try mainButton(XCTUnwrap(mounted()))
        fresh.onPress = { fired.append("fresh") }
        NSApp.postEvent(try event(.leftMouseUp, button: fresh, window: window), atStart: false)
        fresh.mouseDown(with: try event(.leftMouseDown, button: fresh, window: window))
        XCTAssertEqual(fired, ["fresh"], "A new gesture on the replacement still works")
    }

    func testSidebarChatPoolDoesNotReuseANativeTrackingRow() throws { try assertHeldButtonCannotBeRecycled(.chat) }
    func testSidebarSidePoolDoesNotReuseANativeTrackingRow() throws { try assertHeldButtonCannotBeRecycled(.side) }
    func testSidesPanelPoolDoesNotReuseANativeTrackingRow() throws { try assertHeldButtonCannotBeRecycled(.panel) }
    func testSidebarPoolAlsoProtectsEmbeddedNativeButtons() throws { try assertHeldButtonCannotBeRecycled(.chat, embedded: true) }
    func testNativeTrackingKeepsItsStartingBindingWhenAnAttachedRowIsRebound() throws {
        try assertHeldButtonCannotBeRecycled(.chat, directRebind: true)
    }
}
