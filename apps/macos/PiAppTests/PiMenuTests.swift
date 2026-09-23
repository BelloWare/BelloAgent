import XCTest
import AppKit
import SwiftUI
@testable import PiApp

/// Menus described as values and built on the press (PiMenu.swift).
final class PiMenuTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    /// A menu is built when it opens, from the model as it is then, and never
    /// on the way: a sidebar that redraws for every snapshot of a running turn
    /// builds no menu at all.
    @MainActor func testMenusAreBuiltOnlyWhenTheyOpen() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("lazy-list-open-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, window, hosted) = try LazyListAppKitControlTests.crowdedWindow(root)
        defer { model.shutdown(); window.contentView = nil; window.close(); PiMenus.intercept = nil }
        var shown: [NSMenu] = []
        PiMenus.intercept = { menu, _ in shown.append(menu) }
        await LazyListAppKitControlTests.settle(hosted, window)
        let before = PiMenus.built
        let compacting = try XCTUnwrap(model.displays["chat-0-0"])
        for step in 0..<20 {
            compacting.state = step % 2 == 0 ? "running" : "compacting"
            compacting.activity = ["version": .number(2), "phase": .string(step % 3 == 0 ? "compacting" : "model"), "modelActive": .bool(step % 2 == 0)]
            model.topics[0].title = "Payments \(step)"
            await LazyListAppKitControlTests.settle(hosted, window)
        }
        XCTAssertEqual(PiMenus.built, before, "Updates of the sidebar and the composer built menus nobody opened")
        let trigger = try XCTUnwrap(descendants(hosted).compactMap { $0 as? PiPopoverTriggerButton }
            .first { $0.accessibilityIdentifier() == "projectActions-pane-project" })
        trigger.performClick(nil)
        XCTAssertEqual(PiMenus.built, before + 1, "One press, one menu")
        let menu = try XCTUnwrap(shown.last)
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["New Chat", "New Topic…", "Changes and History…", "Collapse Project", "Show Archived Chats", "Manage Project…"])
        XCTAssertTrue(PiMenus.perform("newTopic-pane-project", in: menu), "The menu's commands run as the old menu's did")
        XCTAssertEqual(model.topicEditor?.projectID, "pane-project")
        // The chat actions read the chat when they open.
        model.topicEditor = nil
        let actions = try XCTUnwrap(descendants(hosted).compactMap { $0 as? PiPopoverTriggerButton }
            .first { $0.accessibilityIdentifier() == "conversationActions" })
        actions.performClick(nil)
        let chatMenu = try XCTUnwrap(shown.last)
        XCTAssertTrue(chatMenu.items.contains { $0.identifier?.rawValue == "compactNow" }, "Compact Now is in the chat's menu")
        XCTAssertTrue(chatMenu.items.contains { $0.title == "Move to Topic" && $0.submenu?.items.contains { $0.title == "Payments 19" } == true },
                      "Move to Topic lists the topics as they are when the menu opens")
    }

    /// Sections that come out empty leave no separator at either end or two in a row.
    func testSeparatorsAreTidied() {
        let entries = PiMenuEntry.tidy([.divider, .button("A") {}, .divider, .divider, .note("Caption"), .divider])
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(entries[1].isSeparator)
        if case .note(let text) = entries[2] { XCTAssertEqual(text, "Caption") } else { XCTFail("The caption stays") }
    }
}
