import AppKit
import XCTest
@testable import PiApp

/// Standalone generated-history scenes; no helper, gateway or real settings.
final class SubagentForkGalleryTests: XCTestCase, SerialTestLane {
    @MainActor func testHistoricalCardsInIndependentFork() async throws {
        guard let path = testEnvironment("PI_APP_FORK_GALLERY") else { throw XCTSkip("Set PI_APP_FORK_GALLERY for the fork gallery") }
        let folder = URL(fileURLWithPath:path)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let fixture = try SubagentGalleryFixture(root:folder.appendingPathComponent("fixture-" + UUID().uuidString))
        addTeardownBlock { @MainActor in
            fixture.model.shutdown(); try? await fixture.model.traces.close(); await fixture.model.store?.close()
        }
        defer { fixture.close() }
        for (appearance, color) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            for width in [1240,920,684] {
                fixture.window.appearance = NSAppearance(named:appearance)
                fixture.window.setContentSize(NSSize(width:width,height:600))
                for complete in [true,false] {
                    fixture.show("completed")
                    fixture.model.chats = [fixture.model.chats[0]]
                    fixture.model.chats[0].title = "Parser review — fork"
                    fixture.parent.childSummaries = [:]; fixture.parent.familyWaiting = false
                    fixture.parent.runState = .idle; fixture.parent.runStatus = "idle"; fixture.parent.continuable = false
                    fixture.parent.footer.cost = SessionCostReading(limit:.usd(25),spentUSD:0)
                    var tool = fixture.steeringTool("subagent_start",turn:1,route:"start",message:"Check token boundaries and report the saved result.",id:"call-0",source:"reply")
                    tool.subagent = nil
                    var metadata = tool.nativeSubagent?.object ?? [:]; metadata["budgetOwnerSessionId"] = .string("source-chat")
                    tool.nativeSubagent = .object(metadata)
                    if complete { tool.output = "{\"version\":3,\"accepted\":true,\"text\":\"Parser checked. The saved token-boundary checks passed.\"}" }
                    fixture.parent.messages[1].tools = [tool]
                    await fixture.settle()
                    let revealed = await fixture.model.revealInTranscript(sessionID:fixture.parent.id,messageID:"reply",toolCallID:"call-0")
                    XCTAssertTrue(revealed); await fixture.settle()
                    let card = try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeSubagentCard.self,in:fixture.content).first)
                    let open = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self,in:card).first { $0.accessibilityIdentifier() == "open-subagent" })
                    XCTAssertEqual(open.title,"History"); XCTAssertFalse(open.isEnabled)
                    for button in ConversationPaneTests.views(PiKit.Button.self,in:card) where !button.isHidden {
                        XCTAssertLessThanOrEqual(button.convert(button.bounds,to:card).maxX,card.bounds.width + 1)
                    }
                    fixture.content.layoutSubtreeIfNeeded(); fixture.window.displayIfNeeded()
                    let image = try XCTUnwrap(fixture.content.bitmapImageRepForCachingDisplay(in:fixture.content.bounds))
                    fixture.content.cacheDisplay(in:fixture.content.bounds,to:image)
                    let name = "historical-\(complete ? "result" : "pending")-\(color)-\(width)x600.png"
                    try XCTUnwrap(image.representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent(name))
                }
            }
        }
    }
}
