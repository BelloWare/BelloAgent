import AppKit
import XCTest
@testable import PiApp

/// The Projects sheet in AppKit: its panes cross in one place, the remove
/// question asks once, and Escape and Done close it.
final class WorkspaceManagerSheetTests: XCTestCase {
    @MainActor private func fixture(_ name: String) async throws -> (WorkspaceModel, URL) {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("manager-\(name)-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        for folder in [first, second] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var config = VaultConfiguration(); config.automaticUpdateChecks = false
        config.workspaces = [WorkspaceRecord(id: "a", path: first.path, trusted: true), WorkspaceRecord(id: "b", path: second.path, trusted: true)]
        let vault = ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(config)))
        let model = makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        model.selectedWorkspaceID = "a"
        return (model, root)
    }
    @MainActor private func window(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: WorkspaceManagerSheetView.size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// New Project brings the form over the project's detail: while they
    /// cross, both stand in the same frame (one over the other, never side
    /// by side), and the detail goes once the form has arrived.
    @MainActor func testTheProjectsSheetCrossesItsPanesInOnePlace() async throws {
        let (model, _) = try await fixture("cross")
        let sheet = WorkspaceManagerSheetView(model: model, dismiss: {})
        let window = window(sheet); defer { window.contentView = nil; window.close() }
        sheet.layoutSubtreeIfNeeded()
        let detail = try XCTUnwrap(sheet.subviewsOfType(WorkspaceManagerDetail.self).first)
        XCTAssertEqual(detail.workspaceID, "a")
        sheet.newProject.performClick(nil)
        let form = try XCTUnwrap(sheet.subviewsOfType(NewWorkspacePaneView.self).first)
        if !PiKit.Motion.reduced {
            XCTAssertNotNil(detail.superview, "the detail leaves as the form arrives")
            XCTAssertTrue(detail.superview === form.superview, "the leaving and arriving panes share one holder")
            XCTAssertEqual(detail.frame, form.frame, "one pane over the other, not side by side")
        }
        XCTAssertFalse(sheet.newProject.isEnabled, "a second New Project waits for this one")
        try await eventually("the detail leaves") { detail.superview == nil }
        form.cancelButton.performClick(nil)
        try await eventually("Cancel brings back the selected project") {
            sheet.subviewsOfType(WorkspaceManagerDetail.self).contains { $0.workspaceID == "a" && $0.superview != nil }
                && sheet.subviewsOfType(NewWorkspacePaneView.self).isEmpty
        }
        let back = try XCTUnwrap(sheet.subviewsOfType(WorkspaceManagerDetail.self).first { $0.superview != nil })
        XCTAssertTrue(back === detail, "the detail is the one kept, not made again")
        XCTAssertEqual(back.alphaValue, 1, "and it comes back to be seen")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(back.alphaValue, 1)
        XCTAssertNil(back.layer?.animation(forKey: "pane-fade"), "nothing of its leaving is left on it")
    }

    /// Remove asks once in place; Keep takes the question back, and another
    /// project's detail does not carry it over.
    @MainActor func testRemoveAsksOnceAndKeepTakesItBack() async throws {
        let (model, _) = try await fixture("remove")
        let sheet = WorkspaceManagerSheetView(model: model, dismiss: {})
        let window = window(sheet); defer { window.contentView = nil; window.close() }
        sheet.layoutSubtreeIfNeeded()
        func detail() -> WorkspaceManagerDetail? { sheet.subviewsOfType(WorkspaceManagerDetail.self).first { $0.superview != nil && $0.alphaValue > 0 } }
        let first = try XCTUnwrap(detail())
        XCTAssertTrue(first.removeButton.isEnabled, "a project without chats or topics can go")
        first.removeButton.performClick(nil)
        XCTAssertEqual(sheet.confirmingRemove, "a")
        XCTAssertNil(first.removeButton.superview, "the question stands in the button's place")
        XCTAssertNotNil(first.confirmRemove.window)
        first.keep.performClick(nil)
        XCTAssertNil(sheet.confirmingRemove)
        XCTAssertNotNil(first.removeButton.window)
        first.removeButton.performClick(nil)
        sheet.select("b")
        XCTAssertNil(sheet.confirmingRemove, "another project starts without the question")
        sheet.select("a")
        try await eventually("project a's detail again") { detail()?.workspaceID == "a" }
        detail()?.removeButton.performClick(nil)
        detail()?.confirmRemove.performClick(nil)
        try await eventually("the project is removed and the first left is selected") { !model.workspaces.contains { $0.id == "a" } && sheet.selection == "b" }
    }

    /// Done closes the sheet, and so does Escape through the window's keys.
    @MainActor func testDoneAndEscapeCloseTheSheet() async throws {
        let (model, _) = try await fixture("close")
        var closed = 0
        let sheet = WorkspaceManagerSheetView(model: model, dismiss: { closed += 1 })
        let window = window(sheet); defer { window.contentView = nil; window.close() }
        sheet.layoutSubtreeIfNeeded()
        sheet.done.performClick(nil)
        XCTAssertEqual(closed, 1)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertTrue(window.performKeyEquivalent(with: escape))
        XCTAssertEqual(closed, 2)
    }

    /// The folder list's remove buttons take a folder away through the model.
    @MainActor func testAFolderRemovesThroughTheModel() async throws {
        let (model, root) = try await fixture("folders")
        let extra = root.appendingPathComponent("extra")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try await model.updateConfiguration { $0.workspaces[0].paths = [extra.path] }
        let list = WorkspaceFolderListView(model: model, workspaceID: "a")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = list; defer { window.contentView = nil; window.close() }
        list.layoutSubtreeIfNeeded()
        let rows = list.subviewsOfType(WorkspaceFolderRowView.self)
        XCTAssertEqual(rows.map(\.path), [model.workspaces[0].path, extra.path])
        XCTAssertNil(rows[0].removeButton, "the primary folder stays")
        XCTAssertEqual(list.addFolders.title, "Add Folders…")
        rows[1].removeButton?.performClick(nil)
        try await eventually("the extra folder is gone") { model.workspaces[0].paths.isEmpty && list.subviewsOfType(WorkspaceFolderRowView.self).count == 1 }
    }

    /// A project chosen while a new one is being made: the form goes at once,
    /// and the making still ends, its project listed and the sheet free again.
    @MainActor func testCreatingAProjectFinishesAfterTheFormHasGone() async throws {
        let (model, root) = try await fixture("create")
        let folder = root.appendingPathComponent("third")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        PiQuestion.shared.chooseFiles = { [folder] }
        PiKit.Motion.reducedOverride = true
        defer { PiQuestion.shared.chooseFiles = nil; PiKit.Motion.reducedOverride = nil }
        let sheet = WorkspaceManagerSheetView(model: model, dismiss: {})
        let window = window(sheet); defer { window.contentView = nil; window.close() }
        sheet.newProject.performClick(nil)
        // The test keeps no hold on the form: once it goes, it is gone.
        weak var gone: NewWorkspacePaneView?
        try await {
            let form = try XCTUnwrap(sheet.subviewsOfType(NewWorkspacePaneView.self).first)
            form.choosePrimary.performClick(nil)
            try await eventually("the primary folder is chosen") { form.create.isEnabled }
            form.create.performClick(nil)
            gone = form
        }()
        XCTAssertFalse(sheet.newProject.isEnabled, "busy while the project is made")
        sheet.select("b")
        XCTAssertNil(gone?.superview, "the form went at once")
        try await eventually("the project is made and the sheet is free again") {
            model.workspaces.contains { $0.path == folder.resolvingSymlinksInPath().path } && sheet.newProject.isEnabled
        }
    }

    /// A long failure wraps short of Done instead of running under it.
    @MainActor func testALongStatusWrapsShortOfDone() async throws {
        let (model, root) = try await fixture("status")
        let missing = root.appendingPathComponent(String(repeating: "a-folder-that-is-not-there-", count: 6))
        PiQuestion.shared.chooseFiles = { [missing] }
        defer { PiQuestion.shared.chooseFiles = nil }
        let sheet = WorkspaceManagerSheetView(model: model, dismiss: {})
        let window = window(sheet); defer { window.contentView = nil; window.close() }
        sheet.newProject.performClick(nil)
        let form = try XCTUnwrap(sheet.subviewsOfType(NewWorkspacePaneView.self).first)
        form.choosePrimary.performClick(nil)
        try await eventually("the primary folder is chosen") { form.create.isEnabled }
        form.create.performClick(nil)
        let note = try XCTUnwrap(sheet.subviewsOfType(ShellNote.self).first { $0.superview is WorkspaceManagerFooter })
        try await eventually("the failure shows") { !note.isHidden && note.text.contains("not an existing folder") }
        sheet.layoutSubtreeIfNeeded()
        let done = sheet.done.convert(sheet.done.bounds, to: sheet), status = note.convert(note.bounds, to: sheet)
        XCTAssertLessThanOrEqual(status.maxX, done.minX - PiSpacing.md, "the status stops short of Done")
        XCTAssertGreaterThan(status.height, 20, "and wraps onto more lines")
    }

    /// A project without extra folders reads without a "+0".
    @MainActor func testAProjectRowReadsOnlyWhatItShows() async throws {
        let (model, _) = try await fixture("spoken")
        let sheet = WorkspaceManagerSheetView(model: model, dismiss: {})
        let window = window(sheet); defer { window.contentView = nil; window.close() }
        let rows = sheet.subviewsOfType(PiKit.SelectableRow.self).filter { $0.contentView is WorkspaceManagerRowContent }
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            let label = row.accessibilityLabel() ?? ""
            XCTAssertFalse(label.contains("+0"), label)
            XCTAssertTrue(label.contains("0 chats"), label)
        }
    }

    /// A folder taken away fades up and out inside the inset while the inset
    /// eases to its new height over 0.2 s; then the row is gone.
    @MainActor func testARemovedFolderLeavesInsideTheEasingInset() async throws {
        let (model, root) = try await fixture("leave")
        let extra = root.appendingPathComponent("extra")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try await model.updateConfiguration { $0.workspaces[0].paths = [extra.path] }
        let list = WorkspaceFolderListView(model: model, workspaceID: "a")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = list; window.orderFront(nil); defer { window.contentView = nil; window.close() }
        list.frame = window.contentView?.bounds ?? .zero
        list.layoutSubtreeIfNeeded()
        let stack = try XCTUnwrap(list.subviewsOfType(WorkspaceFolderStack.self).first)
        let tall = stack.frame.height
        let row = try XCTUnwrap(list.subviewsOfType(WorkspaceFolderRowView.self).first { $0.path == extra.path })
        try await model.updateConfiguration { $0.workspaces[0].paths = [] }
        try await eventually("the list takes the change") { list.refresh(); return stack.height(forWidth: stack.bounds.width) < tall }
        list.layoutSubtreeIfNeeded()
        XCTAssertNotNil(row.superview, "the row is still leaving")
        XCTAssertGreaterThan(stack.frame.height, tall / 2, "the inset has not jumped to its new height")
        try await Task.sleep(for: .milliseconds(500))
        list.layoutSubtreeIfNeeded()
        XCTAssertNil(row.superview, "then the row is gone")
        XCTAssertLessThan(stack.frame.height, tall - 20, "and the inset has its new height")
    }

    /// The projects list keeps its rows as wide as its clip when the scroller
    /// style changes, either way.
    @MainActor func testTheListFollowsTheScrollerStyle() async throws {
        let (model, root) = try await fixture("scroller")
        var many: [WorkspaceRecord] = []
        for index in 0..<30 {
            let folder = root.appendingPathComponent("p\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            many.append(WorkspaceRecord(id: "p\(index)", path: folder.path, trusted: true))
        }
        try await model.updateConfiguration { [many] in $0.workspaces += many }
        let sheet = WorkspaceManagerSheetView(model: model, dismiss: {})
        let window = window(sheet); defer { window.contentView = nil; window.close() }
        let list = try XCTUnwrap(sheet.subviewsOfType(WorkspaceManagerList.self).first)
        try await eventually("every project listed") { sheet.layoutSubtreeIfNeeded(); return list.subviewsOfType(PiKit.SelectableRow.self).count == 32 }
        let scroll = try XCTUnwrap(list.subviewsOfType(NSScrollView.self).first)
        for style in [NSScroller.Style.legacy, .overlay, .legacy] {
            scroll.scrollerStyle = style
            try await eventually("the document follows the clip (\(style.rawValue))") {
                sheet.layoutSubtreeIfNeeded()
                return scroll.documentView?.frame.width == scroll.contentSize.width
            }
        }
    }

    /// A change that leaves the folders' height alone (another primary
    /// folder) starts no easing; a change of height does.
    @MainActor func testOnlyAHeightChangeEases() async throws {
        let (model, root) = try await fixture("ease")
        let one = root.appendingPathComponent("one"), two = root.appendingPathComponent("two")
        for folder in [one, two] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var answers = [[one], [two], [one, two]]
        PiQuestion.shared.chooseFiles = { answers.isEmpty ? [] : answers.removeFirst() }
        defer { PiQuestion.shared.chooseFiles = nil }
        let sheet = WorkspaceManagerSheetView(model: model, dismiss: {})
        let window = window(sheet); defer { window.contentView = nil; window.close() }
        sheet.newProject.performClick(nil)
        let form = try XCTUnwrap(sheet.subviewsOfType(NewWorkspacePaneView.self).first)
        sheet.layoutSubtreeIfNeeded()
        form.choosePrimary.performClick(nil)
        try await eventually("a primary folder") { form.create.isEnabled }
        let stack = try XCTUnwrap(form.subviewsOfType(WorkspaceFolderStack.self).first)
        try await eventually("the first change settles") { !stack.isEasing }
        form.choosePrimary.performClick(nil)
        try await eventually("another primary folder") { form.subviewsOfType(WorkspaceFolderRowView.self).contains { $0.path == two.resolvingSymlinksInPath().path } }
        XCTAssertFalse(stack.isEasing, "the same height: nothing to ease")
        form.addExtras.performClick(nil)
        try await eventually("an extra folder") { form.subviewsOfType(WorkspaceFolderRowView.self).count == 2 }
        XCTAssertTrue(stack.isEasing, "a new row: the height eases")
    }
}
