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
    override func setUp() { super.setUp(); PiKit.Motion.reducedOverride = true }
    override func tearDown() { PiKit.Motion.reducedOverride = nil; super.tearDown() }

    private func check<V: View>(_ name: String, width: CGFloat, appearance: NSAppearance.Name, reference: V, native: NSView) async throws {
        let comparison = try await PiKitParity.compare(name, appearance: appearance, swiftUI: reference.frame(width: width), appKit: native, width: width)
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
}
