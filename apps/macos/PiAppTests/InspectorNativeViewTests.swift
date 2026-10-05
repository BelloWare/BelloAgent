import AppKit
import SwiftUI
import XCTest
@testable import PiApp

/// Equivalent native host for the prompt expansion fixtures. Its document
/// follows the clip width, including the width a legacy scroller takes.
@MainActor func nativePromptPage(_ card: InspectorPromptCard) -> PageScrollView {
    let scroll = PageScrollView(column: card)
    scroll.insets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
    return scroll
}

@MainActor final class InspectorNativeControlTests: XCTestCase, SerialTestLane {
    func testRequestChangesKeepTheMountedOutlineAndWindowFrame() async throws {
        let fixture = try await InspectorExpandFixture(body: InspectorExpandBodies.request(result: "short tool result"))
        defer { fixture.close() }
        let page = try XCTUnwrap(fixture.window.contentView as? InspectorRequestPage)
        let outline = fixture.outline
        let frame = fixture.window.frame
        fixture.request.open(InspectorRequestRow(id: "next", wall: 2, turn: "t", purpose: "turn", api: "openai-responses", alias: "ui-fixture", model: "gpt-5.4", outcome: "completed"), predecessor: nil, previousLabel: nil)
        page.refresh()
        XCTAssertTrue(fixture.outlineView === outline, "Loading keeps the same native outline mounted")
        try await eventually("The new request did not fill the reused outline") {
            page.layoutSubtreeIfNeeded()
            return fixture.request.conversation.value != nil && fixture.coordinator.content?.key.hasPrefix("next:request:") == true
        }
        XCTAssertTrue(fixture.outlineView === outline)
        XCTAssertEqual(fixture.window.frame, frame, "Body arrival changes the page, never the independent Inspector window")
        XCTAssertFalse(InspectorExpandFixture.descendants(NSView.self, in: page).contains { String(describing: type(of: $0)).contains("HostingView") })
    }

    func testCommandBracketsStepAndCommandFFocusesTheNativeSearch() async throws {
        SessionInspectorWindows.shared.closeAll()
        let pane = try await SessionStatsPopoverTests.seededPane()
        defer { SessionInspectorWindows.shared.closeAll(); pane.close() }
        pane.model.openInspector(session: pane.chat.id)
        let controller = try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID: pane.chat.id))
        let inspector = controller.inspector, window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView as? SessionInspectorView)
        try await eventually("The Inspector did not list its requests") { inspector.index.requests.count == 12 }
        let frame = window.frame
        root.layoutSubtreeIfNeeded()
        let bar = try XCTUnwrap(InspectorExpandFixture.descendants(PiWindowBarView.self, in: root).first)
        let navigator = try XCTUnwrap(InspectorExpandFixture.descendants(InspectorNavigator.self, in: root).first)
        XCTAssertEqual(bar.frame.minY, 28, accuracy: 0.5, "The app bar starts below the native title-bar space")
        XCTAssertEqual(bar.frame.height, 48, accuracy: 0.5)
        XCTAssertEqual(navigator.frame.minY, 77, accuracy: 0.5)
        XCTAssertEqual(navigator.frame.height, root.bounds.height - 77, accuracy: 0.5)
        let request = try XCTUnwrap(inspector.index.requests.dropFirst().first)
        inspector.select(.request(request.id))
        func key(_ text: String) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0))
        }
        let previous = try XCTUnwrap(inspector.index.adjacent(to: request.id, step: -1))
        XCTAssertTrue(root.performKeyEquivalent(with: try key("[")))
        XCTAssertEqual(inspector.page, .request(previous))
        XCTAssertTrue(root.performKeyEquivalent(with: try key("]")))
        XCTAssertEqual(inspector.page, .request(request.id))
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(root.performKeyEquivalent(with: try key("f")))
        try await eventually("Command F did not reach the native raw search") {
            root.layoutSubtreeIfNeeded()
            guard let search = InspectorExpandFixture.descendants(NSTextField.self, in: root).first(where: { $0.accessibilityIdentifier() == "inspector-raw-search" }) else { return false }
            return search.currentEditor() === window.firstResponder && inspector.request.tab == .raw && inspector.request.raw == .request
        }
        XCTAssertEqual(window.frame, frame, "Restoring title-bar space and navigating keep the window's saved dimensions")
        XCTAssertEqual(bar.frame.minY, 28, accuracy: 0.5)
        XCTAssertEqual(navigator.frame.minY, 77, accuracy: 0.5)
    }

    func testMetadataArrivalKeepsTheFocusedRequestTab() async throws {
        let fixture = try await InspectorExpandFixture(body: InspectorExpandBodies.request(result: "short tool result"))
        defer { fixture.close() }
        let page = try XCTUnwrap(fixture.window.contentView as? InspectorRequestPage)
        let tabs = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.Tabs<InspectorRequestModel.Tab>.self, in: page).first)
        let conversation = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.ButtonBase.self, in: tabs).first { $0.title == "Conversation" })
        XCTAssertTrue(fixture.window.makeFirstResponder(conversation))
        fixture.request.metadataOverride = { _ in ["status": .number(503), "outcome": .string("failed")] }
        var updated = try XCTUnwrap(fixture.request.row); updated.outcome = "failed"
        fixture.request.open(updated, predecessor: nil, previousLabel: nil)
        try await eventually("The changed metadata did not reach the request header") {
            page.layoutSubtreeIfNeeded()
            return fixture.request.metadata["status"]?.nonnegativeInteger == 503 && InspectorExpandFixture.descendants(PiKit.Badge.self, in: page).contains { $0.text == "HTTP 503" }
        }
        XCTAssertTrue(fixture.window.firstResponder === conversation, "Metadata refresh preserves the tab's keyboard focus")
        XCTAssertTrue(conversation.window === fixture.window)
    }

    func testRawPartNavigationKeepsFocusAndResizingFitsTheSearch() async throws {
        let fixture = try await InspectorExpandFixture(body: InspectorExpandBodies.request(result: "short tool result"))
        defer { fixture.close() }
        let page = try XCTUnwrap(fixture.window.contentView as? InspectorRequestPage)
        fixture.request.tab = .raw
        try await eventually("Raw did not mount its native controls") { !InspectorExpandFixture.descendants(InspectorRawTab.self, in: page).isEmpty }
        let raw = try XCTUnwrap(InspectorExpandFixture.descendants(InspectorRawTab.self, in: page).first)
        let parts = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.Tabs<InspectorRequestModel.RawPart>.self, in: raw).first)
        let headers = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.ButtonBase.self, in: parts).first { $0.title == "Headers" })
        XCTAssertTrue(fixture.window.makeFirstResponder(headers))
        fixture.request.raw = .headers
        try await eventually("Headers did not become the selected raw part") { parts.selection == .headers }
        XCTAssertTrue(fixture.window.firstResponder === headers, "Selecting a raw part retains its focused tab")
        fixture.request.raw = .request
        try await eventually("Request did not restore the search") { parts.selection == .request && InspectorExpandFixture.descendants(NSTextField.self, in: raw).contains { $0.accessibilityIdentifier() == "inspector-raw-search" } }
        let search = try XCTUnwrap(InspectorExpandFixture.descendants(NSTextField.self, in: raw).first { $0.accessibilityIdentifier() == "inspector-raw-search" })
        page.compact = true; page.layoutSubtreeIfNeeded()
        XCTAssertEqual(search.superview?.frame.width ?? 0, 180, accuracy: 0.5)
        page.compact = false; page.layoutSubtreeIfNeeded()
        XCTAssertEqual(search.superview?.frame.width ?? 0, 250, accuracy: 0.5)
        XCTAssertTrue(fixture.window.firstResponder === headers, "Resizing the toolbar retains tab focus")
        fixture.request.query = "README"
        try await eventually("The clear-search action did not appear") {
            page.layoutSubtreeIfNeeded()
            return search.stringValue == "README" && InspectorExpandFixture.descendants(PiKit.ButtonBase.self, in: raw).contains { $0.accessibilityIdentifier() == "inspector-raw-search-clear" && !$0.isHidden }
        }
        let clear = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.ButtonBase.self, in: raw).first { $0.accessibilityIdentifier() == "inspector-raw-search-clear" })
        XCTAssertEqual(clear.accessibilityLabel(), "Clear the search")
        XCTAssertGreaterThan(clear.frame.height, 10, "The plain clear action retains its body-size symbol")
        XCTAssertTrue(clear.accessibilityPerformPress())
        try await eventually("The accessibility clear action did not empty the query") { fixture.request.query.isEmpty && search.stringValue.isEmpty && clear.isHidden }
        XCTAssertTrue(fixture.window.firstResponder === headers)
    }

    func testCompactionGroupHasItsSemanticNameAndCanOpenItsRequestThroughAccessibility() async throws {
        let archiveRoot = scratchRoot("inspector-compaction-accessibility")
        defer { try? FileManager.default.removeItem(at: archiveRoot) }
        let archive = PayloadArchive(root: archiveRoot)
        try await archive.configure(quota: 8_388_608, bodyRetention: 1_000_000, metricRetention: 400_000_000)
        let requestID = UUID().uuidString
        var metadata = SessionStatsPopoverTests.metadata(for: SessionStatsFixture.request(1), session: "compaction-accessibility")
        metadata["attemptId"] = .string(requestID); metadata["purpose"] = .string("compaction")
        try await archive.begin(metadata, workspace: "project"); try await archive.finish(metadata)
        let inspector = SessionInspectorModel(scope: SessionUsageScope(sessionID: "compaction-accessibility", workspaceID: "project"), title: "Compaction accessibility", archive: archive, workspace: nil, usageLoader: { _, _, _ in throw CaptureFailure.unavailable }, cache: InspectorDocumentCache())
        let controller = SessionInspectorWindowController(inspector: inspector)
        let window = try XCTUnwrap(controller.window), root = try XCTUnwrap(window.contentView as? SessionInspectorView)
        defer { controller.close() }
        controller.present(.overview)
        let navigator = try XCTUnwrap(InspectorExpandFixture.descendants(InspectorNavigator.self, in: root).first)
        try await eventually("The compaction was not listed") { inspector.indexLoaded && inspector.index.compaction(containing: requestID) != nil }
        let group = try XCTUnwrap(inspector.index.compaction(containing: requestID))
        let turn = try XCTUnwrap(inspector.index.turn(containing: requestID))
        inspector.select(.turn(turn.id))
        if inspector.expanded.contains(group.id) { inspector.toggle(group.id) }
        try await eventually("The compaction's native action did not mount") {
            root.layoutSubtreeIfNeeded()
            guard let holder = navigator.list.madeView(for: group.id) else { return false }
            return InspectorExpandFixture.descendants(PiKit.SelectableRow.self, in: holder).contains { $0.accessibilityIdentifier() == "inspector-compaction-open" }
        }
        let holder = try XCTUnwrap(navigator.list.madeView(for: group.id))
        let action = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.SelectableRow.self, in: holder).first { $0.accessibilityIdentifier() == "inspector-compaction-open" })
        XCTAssertEqual(action.accessibilityLabel(), group.title + ", " + compactGatewayUSD(0.001))
        XCTAssertEqual(action.accessibilityRole(), .button)
        XCTAssertFalse(action.isAccessibilitySelected())
        XCTAssertTrue(action.accessibilityPerformPress())
        try await eventually("Pressing the accessible compaction action did not open its request") {
            root.layoutSubtreeIfNeeded()
            return inspector.page == .request(requestID) && inspector.expanded.contains(group.id) && navigator.list.madeView(for: group.id) === holder
        }
        XCTAssertFalse(action.isAccessibilitySelected(), "The expanded group delegates selection to its visible request")
        inspector.toggle(group.id)
        try await eventually("The collapsed group did not expose the selected request") {
            root.layoutSubtreeIfNeeded()
            return !inspector.expanded.contains(group.id) && navigator.list.madeView(for: group.id) === holder && action.isAccessibilitySelected()
        }
        XCTAssertEqual(action.accessibilityLabel(), group.title + ", " + compactGatewayUSD(0.001))
        XCTAssertTrue(action.accessibilityPerformPress())
        try await eventually("The selected group could not reopen its request") { inspector.expanded.contains(group.id) && !action.isAccessibilitySelected() }
    }

    func testRequestDisclosureCanBeToggledAgainFromItsKeptKeyboardFocus() async throws {
        let fixture = try await InspectorExpandFixture(body: InspectorExpandBodies.request(result: "short tool result"))
        defer { fixture.close() }
        let page = try XCTUnwrap(fixture.window.contentView as? InspectorRequestPage)
        let more = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.ButtonBase.self, in: page).first { $0.accessibilityIdentifier() == "inspector-request-more-toggle" })
        XCTAssertTrue(fixture.window.makeFirstResponder(more))
        more.performClick(nil)
        try await eventually("More did not keep keyboard focus after opening its details") {
            let focused = fixture.window.firstResponder as? PiKit.ButtonBase
            return focused?.accessibilityIdentifier() == "inspector-request-more-toggle" && (focused?.accessibilityValue() as? String) == "Expanded"
        }
        XCTAssertTrue(InspectorExpandFixture.descendants(NSView.self, in: page).contains { $0.accessibilityIdentifier() == "inspector-request-more" })
        (fixture.window.firstResponder as? PiKit.ButtonBase)?.performClick(nil)
        try await eventually("The focused disclosure did not collapse its details") {
            let focused = fixture.window.firstResponder as? PiKit.ButtonBase
            return focused?.accessibilityIdentifier() == "inspector-request-more-toggle" && (focused?.accessibilityValue() as? String) == "Collapsed"
        }
        XCTAssertFalse(InspectorExpandFixture.descendants(NSView.self, in: page).contains { $0.accessibilityIdentifier() == "inspector-request-more" })
    }

    func testModelEvidenceKeepsExpandedRoutingDetailsThroughHeaderUpdates() async throws {
        let fixture = try await InspectorExpandFixture(body: InspectorExpandBodies.request(result: "short tool result"))
        defer { fixture.close() }
        let page = try XCTUnwrap(fixture.window.contentView as? InspectorRequestPage)
        let evidence = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.ButtonBase.self, in: page).first { $0.accessibilityIdentifier() == "inspector-request-evidence-toggle" })
        evidence.performClick(nil)
        let reports = try XCTUnwrap(InspectorExpandFixture.descendants(MessageModelReports.self, in: page).first)
        let routing = reports.disclosure
        routing.performClick(nil)
        XCTAssertTrue(routing.expanded)
        XCTAssertTrue(fixture.window.makeFirstResponder(routing))

        let more = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.ButtonBase.self, in: page).first { $0.accessibilityIdentifier() == "inspector-request-more-toggle" })
        more.performClick(nil)
        try await eventually("More replaced the expanded model evidence or its keyboard focus") {
            InspectorExpandFixture.descendants(MessageModelReports.self, in: page).first === reports && routing.expanded && fixture.window.firstResponder === routing
        }
        XCTAssertTrue(InspectorExpandFixture.descendants(NSView.self, in: page).contains { $0.accessibilityIdentifier() == "inspector-request-more" })
        page.compact = true; page.layoutSubtreeIfNeeded()
        try await eventually("Compact layout lost the routing disclosure state or focus") {
            InspectorExpandFixture.descendants(MessageModelReports.self, in: page).first === reports && routing.expanded && fixture.window.firstResponder === routing
        }

        fixture.request.metadataOverride = { _ in ["status": .number(503), "outcome": .string("failed"), "requestedModel": .string("updated-router")] }
        var updated = try XCTUnwrap(fixture.request.row); updated.outcome = "failed"
        fixture.request.open(updated, predecessor: nil, previousLabel: nil)
        try await eventually("Updated metadata did not reach the retained model evidence") {
            page.layoutSubtreeIfNeeded()
            return reports.attempt["requestedModel"]?.string == "updated-router" && routing.expanded && fixture.window.firstResponder === routing
        }
        XCTAssertTrue(InspectorExpandFixture.descendants(MessageModelReports.self, in: page).first === reports)
        XCTAssertTrue(routing.window === fixture.window)
    }

    func testNavigatorDisclosureKeepsItsFocusWhileRequestsOpenAndClose() async throws {
        SessionInspectorWindows.shared.closeAll()
        let pane = try await SessionStatsPopoverTests.seededPane()
        defer { SessionInspectorWindows.shared.closeAll(); pane.close() }
        pane.model.openInspector(session: pane.chat.id)
        let controller = try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID: pane.chat.id))
        let inspector = controller.inspector, window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView as? SessionInspectorView)
        let navigator = try XCTUnwrap(InspectorExpandFixture.descendants(InspectorNavigator.self, in: root).first)
        try await eventually("The Inspector did not list its turn disclosures") {
            root.layoutSubtreeIfNeeded()
            return inspector.indexLoaded && inspector.index.turns.contains { !$0.entries.isEmpty }
        }
        let turn = try XCTUnwrap(inspector.index.turns.first { !$0.entries.isEmpty })
        inspector.select(.turn(turn.id))
        if inspector.expanded.contains(turn.id) { inspector.toggle(turn.id) }
        try await eventually("The selected turn did not have its native navigator row") {
            root.layoutSubtreeIfNeeded()
            guard let row = navigator.list.madeView(for: turn.id) else { return false }
            return InspectorExpandFixture.descendants(PiKit.ButtonBase.self, in: row).contains { $0.accessibilityLabel() == "Show this turn's requests" }
        }
        let row = try XCTUnwrap(navigator.list.madeView(for: turn.id))
        let disclosure = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.ButtonBase.self, in: row).first { $0.accessibilityLabel() == "Show this turn's requests" })
        XCTAssertTrue(window.makeFirstResponder(disclosure))
        disclosure.performClick(nil)
        try await eventually("Opening a turn replaced its focused disclosure") {
            root.layoutSubtreeIfNeeded()
            return inspector.expanded.contains(turn.id) && navigator.list.madeView(for: turn.id) === row && window.firstResponder === disclosure && disclosure.accessibilityLabel() == "Hide this turn's requests"
        }
        disclosure.performClick(nil)
        try await eventually("The focused turn disclosure did not close its requests") {
            root.layoutSubtreeIfNeeded()
            return !inspector.expanded.contains(turn.id) && navigator.list.madeView(for: turn.id) === row && window.firstResponder === disclosure && disclosure.accessibilityLabel() == "Show this turn's requests"
        }
    }

    func testReusedConversationReturnsToPreviewAfterItsWholeTextWorkersStop() async throws {
        let result = InspectorExpandBodies.toolResult(lines: 400)
        let fixture = try await InspectorExpandFixture(body: InspectorExpandBodies.request(result: result))
        defer { fixture.close() }
        let outline = fixture.outline
        let coordinator = fixture.coordinator
        try await fixture.showAll("item:3")
        XCTAssertEqual(fixture.textView("item:3")?.string, result)
        fixture.request.tab = .response
        try await eventually("Leaving Conversation did not stop its whole-text controllers") {
            outline.window == nil && coordinator.expansions.isEmpty
        }
        fixture.request.tab = .conversation
        try await eventually("The reused Conversation kept stale whole-text rows") {
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            return fixture.outlineView === outline && outline.window === fixture.window && fixture.children("item:3").last == "item:3:more" && fixture.row("item:3:text") < 0
        }
        XCTAssertEqual(fixture.children("item:3").count, RequestDocument.wrap(RequestDocument.prefix(result as NSString, limit: RequestDocument.previewLimit)).count + 1)
        try await fixture.showAll("item:3")
        XCTAssertEqual(fixture.textView("item:3")?.string, result, "The reused outline can read and display the complete text again")
    }

    func testLiveBodiesMoveToTheArchiveWithoutLosingTheirViewFormatOrCopy() async throws {
        let root = scratchRoot("inspector-source-route")
        let workspace = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { workspace.shutdown(); try? FileManager.default.removeItem(at: root) }
        let archive = workspace.traces
        try await archive.configure(quota: 8_388_608, bodyRetention: 1_000_000, metricRetention: 400_000_000)
        let fullText = #"{"message":"prefix retained 🌍 payload "# + String(repeating: "more data ", count: 7_000) + #" suffix"}"#
        let full = Data(fullText.utf8), prefix = Data(full.prefix(180))

        for (name, kind, raw, events) in [("raw-request", "request", InspectorRequestModel.RawPart.request, false), ("raw-response", "response", .response, false), ("response-events", "response", .response, true)] {
            let inspector = SessionInspectorModel(scope: SessionUsageScope(sessionID: "route", workspaceID: "project"), title: name, archive: archive, workspace: workspace, usageLoader: { _, _, _ in throw CaptureFailure.unavailable }, cache: InspectorDocumentCache())
            let request = inspector.request
            var helperAvailable = true, liveReads = 0
            let live = CapturedBodySource(metadata: {
                guard helperAvailable else { throw CaptureFailure.unavailable }
                return CapturedBodyMetadata(body: ["state": .string("partial"), "retainedBytes": .number(Double(prefix.count)), "observedBytes": .number(Double(full.count))], hash: nil)
            }, page: { offset in
                guard helperAvailable else { throw CaptureFailure.unavailable }
                liveReads += 1
                return (prefix.subdata(in: offset..<min(prefix.count, offset + 32_768)), prefix.count)
            })
            request.sourceOverride = { row, body in
                if row.source == .live { return live }
                return CapturedBodySource.archive(archive, attemptID: row.id, kind: body)
            }
            request.metadataOverride = { row in
                if row.source != .live { return try await archive.metadata(attempt: row.id) }
                return [kind: .object(["state": .string("partial"), "retainedBytes": .number(Double(prefix.count)), "observedBytes": .number(Double(full.count))])]
            }
            request.tab = events ? .response : .raw; request.raw = raw; request.query = "prefix"
            let page = InspectorRequestPage(inspector: inspector, request: request, compact: false)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = page; window.orderFront(nil)
            defer { request.setActive(false); window.contentView = nil; window.close() }
            var row = InspectorRequestRow(id: UUID().uuidString, wall: 1, turn: "t", purpose: "turn", api: "openai-responses", alias: "route", model: "model", outcome: "running", source: .live)
            request.setActive(true); request.open(row, predecessor: nil, previousLabel: nil)
            request.query = "prefix"
            if events {
                try await eventually("The response event control did not mount") {
                    page.layoutSubtreeIfNeeded()
                    return InspectorExpandFixture.descendants(PiKit.ButtonBase.self, in: page).contains { $0.accessibilityIdentifier() == "inspector-event-log" }
                }
                let eventToggle = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.ButtonBase.self, in: page).first { $0.accessibilityIdentifier() == "inspector-event-log" })
                eventToggle.performClick(nil)
            }
            try await eventually("\(name) did not read its live prefix") {
                page.layoutSubtreeIfNeeded()
                return InspectorExpandFixture.descendants(CapturedBodyView.self, in: page).first?.controller.document?.bytes == prefix
            }
            let body = try XCTUnwrap(InspectorExpandFixture.descendants(CapturedBodyView.self, in: page).first)
            var displayed = "", copySource: CapturedBodyCopySource?
            let originalCopy = body.onCopySource
            body.onDisplayedText = { displayed = $0 }
            body.onCopySource = { source in originalCopy?(source); copySource = source }
            body.setFormat(.text)
            try await eventually("\(name) did not show its selected UTF-8 format") { displayed == String(decoding: prefix, as: UTF8.self) && copySource?.format == .text && !body.controller.loading }
            let previousDocument = try XCTUnwrap(body.controller.document?.id), readsBeforeArchive = liveReads

            let metadata: [String: WireValue] = ["attemptId": .string(row.id), "sessionId": .string("route"), "turnId": .string("t"), "mode": .string("persist"), "outcome": .string("completed"), "api": .string("openai-responses"), kind: .object(["observedBytes": .number(Double(full.count))])]
            try await archive.begin(metadata, workspace: "project")
            var offset = 0
            while offset < full.count {
                let end = min(full.count, offset + 32_768)
                try await archive.append(attempt: row.id, kind: kind, offset: offset, bytes: full.subdata(in: offset..<end))
                offset = end
            }
            try await archive.finish(metadata)
            helperAvailable = false; row.source = .log; row.outcome = "completed"
            request.open(row, predecessor: nil, previousLabel: nil)
            try await eventually("\(name) did not replace its prefix with the durable archive after the helper expired") {
                page.layoutSubtreeIfNeeded()
                return body.controller.document?.bytes == full && displayed == fullText && copySource?.id == body.controller.document?.id && !body.controller.loading
            }
            XCTAssertTrue(InspectorExpandFixture.descendants(CapturedBodyView.self, in: page).first === body)
            XCTAssertEqual(body.controller.document?.replaces, previousDocument, "The archived body replaces the prefix in place")
            XCTAssertEqual(body.format, .text); XCTAssertTrue(body.retained)
            XCTAssertEqual(liveReads, readsBeforeArchive, "Archive transition must not query the unavailable helper")
            if !events {
                XCTAssertEqual(body.searchQuery, "prefix")
                let copy = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.ButtonBase.self, in: page).first { $0.accessibilityIdentifier() == "inspector-raw-copy" })
                NSPasteboard.general.clearContents(); copy.performClick(nil)
                try await eventually("\(name) copied an incomplete live prefix") { NSPasteboard.general.string(forType: .string) == fullText }
            }
            let copied = try await XCTUnwrap(copySource).render()
            XCTAssertEqual(copied, fullText, "The complete durable body, including Unicode, can be copied")
        }
        XCTAssertTrue(workspace.hosts.isEmpty, "Source overrides keep this regression independent of external helpers")
    }

    func testSessionViewSourcesContainNoSwiftUIHostsOrImports() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let session = tests.deletingLastPathComponent().appendingPathComponent("PiApp/Inspector/Session")
        let files = try FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 15)
        for file in files {
            let source = try String(contentsOf: file)
            XCTAssertFalse(source.contains("import SwiftUI"), file.lastPathComponent)
            XCTAssertFalse(source.contains("NSHostingView"), file.lastPathComponent)
            XCTAssertFalse(source.contains("NSViewRepresentable"), file.lastPathComponent)
        }
    }
}

/// Frozen 59ef8e0d components compare the same copy, spacing and ink at two
/// widths in each appearance. The allowance covers only the existing symbol
/// edge differences (PiKitParityTests), not visible movement or wrapping.
@MainActor final class InspectorNativeParityTests: XCTestCase, SerialTestLane {
    override func setUp() async throws { PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws { PiKit.Motion.reducedOverride = nil }

    private func check<V: View>(_ name: String, width: CGFloat, appearance: NSAppearance.Name, reference: V, native: NSView, canvas: NSColor = .piContent) async throws {
        let comparison = try await PiKitParity.compare(name, appearance: appearance, swiftUI: reference.frame(width: width), appKit: native, canvas: canvas, width: width)
        print(comparison.description)
        XCTAssertEqual(comparison.swiftUIFit.height, comparison.appKitFit.height, accuracy: 0.5, comparison.description)
        XCTAssertLessThanOrEqual(comparison.differing, Int(Double(comparison.total) * 0.03), comparison.description)
    }

    func testHeadersKeepActionsBadgesAndSubtitleAtBothWidths() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width: CGFloat in [760, 380] {
                let reference = InspectorPageHeaderReference("Request 2 of 18", subtitle: "auto-router → provider/gpt-5.4 · Turn 1 · 10:42:18 AM") {
                    PiBadge(text: "tool round", tone: .neutral)
                    PiBadge(text: "HTTP 200", tone: .success)
                } actions: {
                    InspectorShowInChatReference(action: {})
                    InspectorForkFromHereReference(action: {})
                }
                let native = InspectorPageHeader("Request 2 of 18", subtitle: "auto-router → provider/gpt-5.4 · Turn 1 · 10:42:18 AM", badges: [PiKit.Badge(text: "tool round", tone: .neutral), PiKit.Badge(text: "HTTP 200", tone: .success)], actions: [InspectorShowInChat(action: {}), InspectorForkFromHere(action: {})])
                try await check("inspector-header-\(Int(width))-\(appearance.rawValue)", width: width, appearance: appearance, reference: reference, native: native)
            }
        }
    }

    func testBannersWrapAtTheSameWordsAndKeepTheirNotes() async throws {
        let text = "2 new items since request 1 · 3 earlier items unchanged"
        let notes = ["The provider returned 12,340 cached input tokens.", "This comparison uses the request bodies that were retained."]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width: CGFloat in [660, 280] {
                try await check("inspector-banner-\(Int(width))-\(appearance.rawValue)", width: width, appearance: appearance, reference: InspectorBannerReference(symbol: "plus.circle", text: text, notes: notes, tone: .accent), native: InspectorBanner(symbol: "plus.circle", text: text, notes: notes, tone: .accent))
            }
        }
    }

    func testFiguresKeepTheirBaselinesWhenTheyWrap() async throws {
        let figures = [InspectorFigure(label: "In", value: "18,240", detail: "(15,112 cached)"), InspectorFigure(label: "Out", value: "1,104"), InspectorFigure(label: "reasoning", value: "640"), InspectorFigure(label: "Cost", value: "$0.0213"), InspectorFigure(label: "TTFT", value: "820 ms"), InspectorFigure(label: "Speed", value: "96 tok/s")]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width: CGFloat in [760, 320] {
                try await check("inspector-figures-\(Int(width))-\(appearance.rawValue)", width: width, appearance: appearance, reference: InspectorFigureStripReference(figures: figures), native: InspectorFigureStrip(figures: figures))
            }
        }
    }

    func testRequestFiguresAlignWithTheFirstLineOfTheirDisclosures() async throws {
        let fixture = try await InspectorExpandFixture(body: InspectorExpandBodies.request(result: "A short result"))
        defer { fixture.close() }
        var row = try XCTUnwrap(fixture.request.row)
        row.input = 30; row.cached = 10; row.output = 20; row.cost = 0.00125
        row.ttft = 2; row.decode = 112; row.duration = 114
        fixture.request.open(row, predecessor: nil, previousLabel: nil)
        try await eventually("The metric fixture did not settle") { fixture.request.metadataLoaded && fixture.request.conversation.value != nil }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width: CGFloat in [889, 513] {
                let page = InspectorRequestPage(inspector: fixture.inspector, request: fixture.request, compact: width < 600)
                let strip = try XCTUnwrap(InspectorExpandFixture.descendants(InspectorFigureStrip.self, in: page).first)
                let metrics = try XCTUnwrap(strip.superview as? ShellStack)
                try await check("inspector-request-metrics-\(Int(width))-\(appearance.rawValue)", width: width, appearance: appearance, reference: InspectorRequestMetricsReference(figures: row.figures), native: metrics)
            }
        }
    }

    func testRawSearchKeepsItsClearSymbolAndTextInsetsAtBothWidths() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width: CGFloat in [250, 180] {
                try await check("inspector-raw-search-\(Int(width))-\(appearance.rawValue)", width: width, appearance: appearance, reference: InspectorSearchFieldReference(text: "README"), native: InspectorSearchField(text: "README", changed: { _ in }))
            }
        }
    }

    func testRequestPagesKeepTheirFixedChromeAndOutlineAtBothWidths() async throws {
        let fixture = try await InspectorExpandFixture(body: InspectorExpandBodies.request(result: InspectorExpandBodies.toolResult(lines: 12)))
        defer { fixture.close() }
        for tab in [InspectorRequestModel.Tab.conversation, .response] {
            fixture.request.tab = tab
            try await eventually("The parity request did not settle on \(tab.rawValue)") {
                switch tab {
                case .conversation: return fixture.request.conversation.value != nil && fixture.request.delta != nil
                case .response: if case .failed = fixture.request.response { return true }; return false
                case .raw: return false
                }
            }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for (width, compact) in [(CGFloat(820), false), (CGFloat(550), true)] {
                    let reference = InspectorRequestPageReference(inspector: fixture.inspector, request: fixture.request, compact: compact).frame(width: width, height: 720)
                    let native = InspectorFixedSize(InspectorRequestPage(inspector: fixture.inspector, request: fixture.request, compact: compact), width: width, height: 720)
                    try await check("inspector-request-\(tab.rawValue)-\(Int(width))-\(appearance.rawValue)", width: width, appearance: appearance, reference: reference, native: native)
                }
            }
        }
    }

    func testNavigatorKeepsItsFullLabelsAtBothWidths() async throws {
        let root = scratchRoot("inspector-navigator-parity")
        defer { try? FileManager.default.removeItem(at: root) }
        let inspector = SessionInspectorModel(scope: SessionUsageScope(sessionID: "navigator", workspaceID: "project"), title: "Navigator parity", archive: PayloadArchive(root: root), workspace: nil, usageLoader: { _, _, _ in throw CaptureFailure.unavailable }, cache: InspectorDocumentCache())
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (width, compact) in [(CGFloat(262), false), (CGFloat(214), true)] {
                let reference = InspectorNavigatorViewportReference(inspector: inspector, compact: compact).frame(width: width, height: 200)
                let native = InspectorFixedSize(InspectorNavigator(inspector: inspector), width: width, height: 200)
                try await check("inspector-navigator-\(Int(width))-\(appearance.rawValue)", width: width, appearance: appearance, reference: reference, native: native, canvas: .piWindow)
            }
        }
    }
}
