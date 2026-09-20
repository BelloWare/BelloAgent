import XCTest
import SwiftUI
@testable import PiApp

final class TopicSidebarPresentationTests: XCTestCase {
    private func entry(_ id: String, title: String? = nil, depth: Int = 0, children: Bool = false) -> SidebarChatEntry {
        SidebarChatEntry(chat: ChatRecord(id: id, workspaceID: "project", title: title ?? id, path: nil, profileID: "profile"), depth: depth, hasChildren: children)
    }

    func testMatchingSideChatKeepsOnlyItsAncestorsAndTitleMatchShowsWholeTopic() {
        let entries = [entry("one", children: true), entry("side", depth: 1, children: true), entry("grandchild", title: "Fix topic navigation", depth: 2), entry("sibling", depth: 1), entry("two")]
        XCTAssertEqual(SidebarSessionPresentation.filtered(entries, by: "TOPIC").map(\.id), ["one", "side", "grandchild"])
        XCTAssertTrue(SidebarSessionPresentation.filtered(entries, by: "absent").isEmpty)
        XCTAssertEqual(SidebarSessionPresentation.filtered(entries, by: "").map(\.id), entries.map(\.id))
        let topicTitleMatch = SidebarSessionPresentation.page(entries, roots: 1, selected: [], filtering: true)
        XCTAssertEqual(topicTitleMatch.map(\.id), entries.map(\.id), "A matched topic is not limited by its previous Show more page")
    }

    func testIndependentPagesKeepSelectedDescendantsAndWholeBranchesVisible() {
        let entries = [entry("one", children: true), entry("side", depth: 1), entry("two"), entry("three", children: true), entry("selected-side", depth: 1), entry("four")]
        XCTAssertEqual(SidebarSessionPresentation.page(entries, roots: 1, selected: [], filtering: false).map(\.id), ["one", "side"])
        XCTAssertEqual(SidebarSessionPresentation.page(entries, roots: 1, selected: ["selected-side"], filtering: false).map(\.id), ["one", "side", "two", "three", "selected-side"])
        let otherTopic = [entry("independent-a"), entry("independent-b")]
        XCTAssertEqual(SidebarSessionPresentation.page(otherTopic, roots: 1, selected: ["selected-side"], filtering: false).map(\.id), ["independent-a"])
    }

    /// Real SwiftUI/AppKit layout exercises the native sidebar without a mouse
    /// or foreground desktop. Filtering must reveal a collapsed matching topic
    /// and all its chats; clearing the filter must restore its stored collapse.
    @MainActor func testHostedSidebarRendersEmptyTopicsAndRevealsFilteredCollapsedContents() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("topic-sidebar-" + UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let project = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        model.workspaces = [project]
        model.topics = [TopicRecord(id: "filled", workspaceID: project.id, title: "Investigation", expanded: false),
                        TopicRecord(id: "empty", workspaceID: project.id, title: "Planning", expanded: false)]
        model.chats = (0..<7).map { index in
            var chat = ChatRecord(id: "chat-\(index)", workspaceID: project.id, title: "Investigation item \(index)", path: nil, profileID: "profile")
            chat.topicID = "filled"; return chat
        }
        let hosted = NSHostingView(rootView: ProjectSidebarGroup(model: model, project: project, available: true, name: "Project").transaction { $0.animation = nil; $0.disablesAnimations = true })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 330, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosted
        defer { window.contentView = nil; window.close(); model.shutdown() }
        addTeardownBlock { @MainActor in
            try? await model.traces.close(); await model.store?.close()
            try? FileManager.default.removeItem(at: root)
        }
        func height() async throws -> CGFloat {
            for _ in 0..<4 { hosted.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            return hosted.fittingSize.height
        }
        let collapsedHeight = try await height()
        XCTAssertGreaterThan(collapsedHeight, 65, "Both topic headers, including the empty topic, stay visible")
        hosted.rootView = ProjectSidebarGroup(model: model, project: project, available: true, name: "Project", filter: "Investigation").transaction { $0.animation = nil; $0.disablesAnimations = true }
        let filteredHeight = try await height()
        XCTAssertGreaterThan(filteredHeight, collapsedHeight + 240, "A matching collapsed topic exposes all seven chats")
        XCTAssertFalse(model.topics[0].expanded, "Filtering must not overwrite the saved disclosure state")
        hosted.rootView = ProjectSidebarGroup(model: model, project: project, available: true, name: "Project").transaction { $0.animation = nil; $0.disablesAnimations = true }
        let restoredHeight = try await height()
        XCTAssertEqual(restoredHeight, collapsedHeight, accuracy: 1)
        XCTAssertTrue(model.hosts.isEmpty, "Rendering and filtering topic metadata cannot start a helper or chat")
    }
}
