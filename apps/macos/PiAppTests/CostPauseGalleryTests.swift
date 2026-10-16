import AppKit
import XCTest
@testable import PiApp

/// Generated scenes for a family paused at its shared cost limit (0.1.129):
/// the chat's card at the limit and after a raise, a sub-agent's reader and
/// the family picker. No helper, provider, preferences or installed app.
final class CostPauseGalleryTests: XCTestCase, SerialTestLane {
    @MainActor func testCostPauseScenes() async throws {
        guard let path = testEnvironment("PI_APP_COST_PAUSE_GALLERY") else { throw XCTSkip("Set PI_APP_COST_PAUSE_GALLERY for the cost-pause scenes") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try SubagentGalleryFixture(root: folder.appendingPathComponent("fixture-" + UUID().uuidString))
        addTeardownBlock { @MainActor in fixture.model.shutdown(); try? await fixture.model.traces.close(); await fixture.model.store?.close() }
        defer { fixture.close() }
        var written: [String] = []
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for size in [NSSize(width: 700, height: 600), NSSize(width: 920, height: 600), NSSize(width: 1240, height: 800)] {
                fixture.window.appearance = NSAppearance(named: appearance); fixture.window.setContentSize(size)
                for scene in ["family-cost-limit", "family-cost-limit-raised", "child-cost-paused"] {
                    fixture.show(scene); await fixture.settle()
                    let session = scene == "child-cost-paused" ? fixture.child : fixture.parent
                    let card = try XCTUnwrap(session.presentedMessages.last)
                    XCTAssertEqual(card.failureCode, scene == "child-cost-paused" ? SessionDisplay.costPausedChildCode
                                   : scene == "family-cost-limit" ? SessionDisplay.costPausedCode : SessionDisplay.costPausedRaisedCode)
                    let revealed = await fixture.model.revealInTranscript(sessionID: session.id, messageID: card.id)
                    XCTAssertTrue(revealed); await fixture.settle()
                    let notice = ConversationPaneTests.views(TranscriptNativeFailureRow.self, in: fixture.content).first { $0.accessibilityIdentifier() == "cost-paused-notice" }
                    XCTAssertNotNil(notice, scene)
                    let pill = ConversationPaneTests.views(NSView.self, in: fixture.content).first {
                        ["cost-limit-raise", "cost-paused-resume"].contains($0.accessibilityIdentifier())
                    }
                    switch scene {
                    case "family-cost-limit": XCTAssertEqual(pill?.accessibilityIdentifier(), "cost-limit-raise")
                    case "family-cost-limit-raised": XCTAssertEqual(pill?.accessibilityIdentifier(), "cost-paused-resume")
                    default: XCTAssertNil(pill, "A sub-agent has no Resume of its own")
                    }
                    let file = "\(scene)-\(name)-\(Int(size.width)).png"
                    try SessionStatsPopoverTests.capture(fixture.window, to: folder.appendingPathComponent(file)); written.append(file)
                    if scene == "family-cost-limit" {
                        let header = try XCTUnwrap(ConversationPaneTests.views(AgentFamilyHeaderView.self, in: fixture.content).first { !$0.isHidden })
                        header.open(); await fixture.settle()
                        let popup = try XCTUnwrap(header.popover.popover?.contentViewController?.view)
                        let rows = ConversationPaneTests.views(FamilyPickerRow.self, in: popup)
                        XCTAssertTrue(rows.contains { $0.accessibilityIdentifier() == "open-agent-child-0" && $0.secondary?.contains("Paused") == true })
                        try await Task.sleep(for: .milliseconds(300))
                        try SessionStatsPopoverTests.capture(fixture.window, to: folder.appendingPathComponent("family-picker-paused-\(name)-\(Int(size.width)).png")); written.append("picker")
                        header.popover.close(); await fixture.settle()
                    }
                }
            }
        }
        XCTAssertEqual(written.count, 24)
    }
}
