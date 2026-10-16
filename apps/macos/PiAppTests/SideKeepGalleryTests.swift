import AppKit
import XCTest
@testable import PiApp

/// Generated metadata and transcripts only; never launches an installed app.
final class SideKeepGalleryTests: XCTestCase, SerialTestLane {
    @MainActor func testCombinedNoticeAndDismissConfirmation() async throws {
        guard let path = testEnvironment("PI_APP_SIDE_KEEP_GALLERY") else { throw XCTSkip("Set PI_APP_SIDE_KEEP_GALLERY for these scenes") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = makeWorkspaceModel(stateRoot: folder.appendingPathComponent("fixture-" + UUID().uuidString))
        model.launching = false
        let parent = ChatRecord(id: "parent", workspaceID: "project", title: "Release checklist", path: nil, profileID: "fixture")
        model.chats = [parent]
        let session = SessionDisplay(id: parent.id); session.historyState = .ready; session.selectionMetadataLoaded = true
        session.messages = [.init(id: "q", role: "user", text: "Review the release checklist."),
                            .init(id: "a", role: "assistant", text: "The checklist is ready. You can continue working in this chat while reviewing the saved copies above.")]
        model.displays[parent.id] = session; model.selected = session; model.selectedID = parent.id
        model.sideKeepIssues = [
            .init(chat: .init(id: "copy-a", workspaceID: "project", title: "Release notes — side conversation", path: "/Generated/Workspaces/project/Sessions/side_copy-a.jsonl", profileID: "fixture"), parentTitle: parent.title, reason: "The file belongs to a different chat."),
            .init(chat: .init(id: "copy-b", workspaceID: "project", title: "Parser investigation — fork", path: "/Generated/Workspaces/project/Sessions/fork_copy-b.jsonl", profileID: "fixture"), parentTitle: nil, reason: "The file has no readable conversation header.")]
        let root = WorkspaceRootView(model: model)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1240, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root; window.orderFront(nil)
        defer { window.close() }
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            for width in [1240, 920] {
                window.setContentSize(NSSize(width: width, height: 600))
                root.refresh(); root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let notice = try XCTUnwrap(ConversationPaneTests.views(SideKeepNoticeView.self, in: root).first)
                XCTAssertEqual(notice.issues.count, 2)
                try checkControls(notice)
                try capture(root, to: folder.appendingPathComponent("notice-\(theme)-\(width)x600.png"))
            }
            let narrow = SideKeepNoticeView(issues: model.sideKeepIssues, open: { _ in }, reveal: { _ in }, dismiss: { _, _ in }, retry: {})
            narrow.appearance = NSAppearance(named: appearance)
            narrow.frame = CGRect(x: 0, y: 0, width: 300, height: narrow.height(forWidth: 300))
            narrow.layoutSubtreeIfNeeded(); try checkControls(narrow)
            try capture(narrow, to: folder.appendingPathComponent("notice-\(theme)-300.png"))
            for width in [920, 300] {
                let question = SideKeepDismissSheet(issue: model.sideKeepIssues[0], parentSize: NSSize(width: width, height: 600), answer: { _ in })
                question.appearance = NSAppearance(named: appearance)
                question.frame = CGRect(origin: .zero, size: question.intrinsicContentSize)
                question.layoutSubtreeIfNeeded()
                XCTAssertLessThan(question.bounds.width, CGFloat(width))
                XCTAssertLessThan(question.bounds.height, 600)
                for button in [question.cancel, question.confirm] {
                    XCTAssertTrue(question.bounds.contains(button.convert(button.bounds, to: question)))
                }
                try capture(question, to: folder.appendingPathComponent("dismiss-\(theme)-\(width).png"))
            }
        }
    }
    @MainActor private func checkControls(_ view: NSView) throws {
        for button in ConversationPaneTests.views(PiKit.Button.self, in: view) {
            let box = button.convert(button.bounds, to: view)
            XCTAssertGreaterThanOrEqual(box.minX, 0); XCTAssertLessThanOrEqual(box.maxX, view.bounds.width + 1)
            XCTAssertFalse((button.accessibilityLabel() ?? "").isEmpty)
        }
    }
    @MainActor private func capture(_ view: NSView, to path: URL) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: path)
    }
}
