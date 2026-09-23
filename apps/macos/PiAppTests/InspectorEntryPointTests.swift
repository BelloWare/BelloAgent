import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// Every way into the Session Inspector opens the chat's one Inspector window
/// at the page the link is about, driven through a real conversation pane:
/// the turn report's ⓘ, a row's Details, the composer's usage button, the
/// footer's capture badge and pills, the sidebar and menu command, and a usage
/// report row.
final class InspectorEntryPointTests: XCTestCase {
    /// A pane with one finished turn whose reply reported its usage.
    @MainActor private func finishedTurnPane() async throws -> ConversationPaneTests.Pane {
        SessionInspectorWindows.shared.closeAll()
        var accounting = GatewayTotals(requests: 1, costSamples: 1, costUSD: 0.0012)
        accounting.tokens = GatewayTokenTotals(input: 1_200, output: 80, inputSamples: 1, outputSamples: 1)
        var reply = TranscriptMessage(id: "a1", role: "assistant", text: "All green.", state: "complete", turn: "u1", taskRootID: "u1", taskExecutionID: "e1")
        reply.accounting = accounting
        reply.reply = ReplyRecord(attempt: "attempt-1", requested: "pane-model")
        let prompt = TranscriptMessage(id: "u1", role: "user", text: "Run the tests", state: "complete", turn: "u1", taskRootID: "u1", taskExecutionID: "e1")
        let pane = try ConversationPaneTests.Pane(messages: [prompt, reply])
        var task = TaskPresentationRecord(rootID: "u1", executionID: "e1", startedAt: 1_000)
        task.outcome = "completed"; task.phase = "terminal"; task.endedAt = 4_000; task.lastSourceID = "a1"; task.replies = 1
        pane.session.taskPresentation = TaskPresentationProjection(sessionID: pane.chat.id, epoch: "epoch", timeline: "root", sequence: 1,
                                                                   sourceRevision: "1", active: nil, recent: [task])
        pane.session.footer.gateway = accounting
        pane.session.publishTranscript()
        await pane.settle(12)
        return pane
    }

    /// A press target of the pane by its identifier: the AppKit button over a pill's or badge's face.
    @MainActor static func trigger(_ identifier: String, in pane: ConversationPaneTests.Pane) -> PiPopoverTriggerButton? {
        ConversationPaneTests.views(PiPopoverTriggerButton.self, in: pane.hosted).first { $0.accessibilityIdentifier() == identifier }
    }

    @MainActor private func inspector(_ pane: ConversationPaneTests.Pane) -> SessionInspectorModel? {
        SessionInspectorWindows.shared.controller(sessionID: pane.chat.id)?.inspector
    }

    /// The ⓘ of a turn report is an AppKit button in the transcript's row; its
    /// press reaches the pane through the rows' action relay and opens the turn.
    @MainActor func testATurnReportsInfoButtonOpensItsTurn() async throws {
        let pane = try await finishedTurnPane(); defer { pane.close() }
        let button = try XCTUnwrap(ConversationPaneTests.views(NSButton.self, in: pane.hosted).first { $0.accessibilityIdentifier() == "turn-info-button" },
                                   "The finished turn's report has its info button")
        XCTAssertNil(pane.model.lastInspectorFocus)
        button.performClick(nil)
        XCTAssertEqual(pane.model.lastInspectorFocus, .turn("u1"))
        let inspector = try XCTUnwrap(inspector(pane), "The chat's Inspector opened")
        XCTAssertEqual(inspector.scope, SessionUsageScope(sessionID: pane.chat.id, workspaceID: pane.chat.workspaceID))
    }

    /// A row's Details, which the hover pills, the receipt's model link,
    /// Request details and the partial-turn chip all call through the rows'
    /// action relay, opens the request that produced the message.
    @MainActor func testARowsDetailsOpenTheInspectorAtItsMessage() async throws {
        let pane = try await finishedTurnPane(); defer { pane.close() }
        let document = try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeDocument.self, in: pane.hosted).first, "The transcript is on screen")
        document.actionRelay.forwarded.inspect("a1")
        XCTAssertEqual(pane.model.lastInspectorFocus, .message("a1"))
        XCTAssertNotNil(inspector(pane))
        XCTAssertEqual(SessionInspectorWindows.shared.count, 1)
    }

    /// The composer bar's usage button and the footer's capture badge open the
    /// Overview, in the same window as every other link.
    @MainActor func testTheUsageButtonAndTheCaptureBadgeOpenTheOverview() async throws {
        let pane = try await finishedTurnPane(); defer { pane.close() }
        let usage = try XCTUnwrap(Self.trigger("sessionUsageCostButton", in: pane) ?? Self.trigger("sessionUsageButton", in: pane),
                                  "The usage button is in the composer bar")
        usage.performClick(nil)
        XCTAssertEqual(pane.model.lastInspectorFocus, .overview)
        let opened = try XCTUnwrap(inspector(pane))
        opened.select(.nextRequest)
        let badge = try XCTUnwrap(Self.trigger("capture-badge", in: pane), "The capture badge is in the footer")
        badge.performClick(nil)
        XCTAssertEqual(pane.model.lastInspectorFocus, .overview)
        XCTAssertTrue(inspector(pane) === opened, "One window per chat")
        XCTAssertEqual(opened.page, .overview, "brought back to the Overview")
    }

    /// The chat menu's Session Inspector…, built when the menu opens, opens
    /// the latest request.
    @MainActor func testTheChatMenuOpensTheLatestRequest() async throws {
        let pane = try await finishedTurnPane()
        var shown: [NSMenu] = []
        PiMenus.intercept = { menu, _ in shown.append(menu) }
        defer { PiMenus.intercept = nil; pane.close() }
        let actions = try XCTUnwrap(ConversationPaneTests.views(PiPopoverTriggerButton.self, in: pane.hosted)
            .first { $0.accessibilityIdentifier() == "conversationActions" }, "The chat menu is in the composer bar")
        actions.performClick(nil)
        let menu = try XCTUnwrap(shown.last)
        XCTAssertEqual(menu.items.first { $0.identifier?.rawValue == "sessionInspector" }?.title, "Session Inspector…")
        XCTAssertFalse(menu.items.contains { $0.title.hasPrefix("View Retained Message") || $0.title == "Inspect Requests" },
                       "The retired entries are gone")
        XCTAssertTrue(PiMenus.perform("sessionInspector", in: menu))
        XCTAssertEqual(pane.model.lastInspectorFocus, .latestRequest)
        XCTAssertNotNil(inspector(pane))
    }

    /// The sidebar's inspect button and ⌥⌘I call `inspect`: the latest request.
    @MainActor func testTheSidebarAndTheMenuCommandOpenTheLatestRequest() async throws {
        let pane = try await finishedTurnPane(); defer { pane.close() }
        pane.model.inspect(pane.chat.id)
        XCTAssertEqual(pane.model.lastInspectorFocus, .latestRequest)
        XCTAssertNotNil(inspector(pane))
    }

    /// The latest request, asked of a window that has not read the log yet,
    /// is the latest request once it has, not the Overview it starts on.
    @MainActor func testTheLatestRequestOpensOnAFreshWindow() async throws {
        SessionInspectorWindows.shared.closeAll()
        let pane = try await SessionStatsPopoverTests.seededPane(); defer { SessionInspectorWindows.shared.closeAll(); pane.close() }
        pane.model.inspect(pane.chat.id)
        let inspector = try XCTUnwrap(inspector(pane))
        try await SessionStatsPopoverTests.waitFor("The latest request did not open", pane: pane) {
            inspector.indexLoaded && inspector.page != .overview
        }
        let latest = try XCTUnwrap(inspector.index.latestRequestID)
        XCTAssertEqual(inspector.page, .request(latest))
        XCTAssertEqual(inspector.request.row?.id, latest)
    }

    /// A usage report row opens its request, even when its chat was deleted;
    /// a chat's own links explain a chat that is gone.
    @MainActor func testAReportRowOpensItsRequestEvenForADeletedChat() async throws {
        let pane = try await finishedTurnPane(); defer { pane.close() }
        pane.model.openInspector(session: "deleted-chat", workspaceID: pane.chat.workspaceID, title: nil, focus: .request("attempt-9"))
        let controller = try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID: "deleted-chat"))
        XCTAssertEqual(controller.window?.title, "Deleted chat — Session Inspector")
        XCTAssertEqual(pane.model.lastInspectorFocus, .request("attempt-9"))
        pane.model.openInspector(session: "gone")
        XCTAssertTrue(pane.model.error?.contains("no longer available") == true, pane.model.error ?? "")
        XCTAssertNil(SessionInspectorWindows.shared.controller(sessionID: "gone"))
    }
}

/// The Inspector keeps no live menu and no AppKit control that sizes itself
/// in its navigator's lazy list: the hang of 0.1.89 was a lazy list updating
/// such controls for ever (PiMenu.swift, LazyListAppKitControlTests).
final class InspectorWindowControlTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    @MainActor func testTheInspectorKeepsNoLiveMenuAndNoSelfSizingControlInItsList() async throws {
        SessionInspectorWindows.shared.closeAll()
        let pane = try await SessionStatsPopoverTests.seededPane(); defer { SessionInspectorWindows.shared.closeAll(); pane.close() }
        pane.model.openInspector(session: pane.chat.id)
        let controller = try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID: pane.chat.id))
        let inspector = controller.inspector, window = try XCTUnwrap(controller.window), hosted = try XCTUnwrap(window.contentView)
        try await SessionStatsPopoverTests.waitFor("The Inspector read the session", pane: pane) { inspector.indexLoaded && inspector.index.requests.count == 12 }
        let turn = try XCTUnwrap(inspector.index.turns.first { !$0.isOther })
        let request = try XCTUnwrap(turn.requests.first)
        let pages: [(String, () -> Void)] = [
            ("Overview", { inspector.select(.overview) }),
            ("Turn", { inspector.select(.turn(turn.id)) }),
            ("Conversation", { inspector.select(.request(request.id)); inspector.request.tab = .conversation }),
            ("Response", { inspector.request.tab = .response }),
            ("Raw", { inspector.request.tab = .raw }),
            ("Next request", { inspector.select(.nextRequest) }),
        ]
        for (name, open) in pages {
            open()
            for _ in 0..<10 { hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            let popUps = descendants(hosted).filter { $0 is NSPopUpButton }.map { String(describing: type(of: $0)) }
            XCTAssertEqual(popUps, [], "\(name): live pop-up menus in the Inspector, rebuilt on every update: \(popUps)")
            if name == "Raw" {
                XCTAssertTrue(descendants(hosted).contains { ($0 as? PiPopoverTriggerButton)?.accessibilityIdentifier() == "inspector-raw-menu" },
                              "Raw's capture menu is built when it opens")
            }
            // The navigator's lazy list: the scroll view along the window's leading edge.
            let lists = descendants(hosted).compactMap { $0 as? NSScrollView }.filter {
                let frame = $0.convert($0.bounds, to: nil)
                return frame.minX < 10 && frame.width <= 263
            }
            let list = try XCTUnwrap(lists.max { $0.bounds.height < $1.bounds.height }?.documentView, "\(name): the navigator is on screen")
            XCTAssertGreaterThan(descendants(list).count, 0)
            let controls = LazyListAppKitControlTests.selfSizingControls(in: list)
            XCTAssertEqual(controls, [], "\(name): the navigator's lazy list hosts AppKit controls that size themselves: \(controls)")
        }
    }
}
