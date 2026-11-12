import AppKit
import XCTest
@testable import PiApp

/// Generated scenes for 0.1.138: the notice a provider's refusal of earlier
/// reasoning leaves, with its one button; the row that says a request is over
/// the model's window; and a compaction's row while its summary is asked for
/// once more. No helper, provider, preferences or installed app.
final class ReasoningNoticeGalleryTests: XCTestCase, SerialTestLane {
    static let overWindow = "Context · This request is about 78,362 tokens, more than the 41,308 that this model's 50,000-token window leaves for input. Nothing was summarized away, and it is sent whole: the provider may refuse it, or cut the reply short."
    static let askedAgain = "Compaction · Summary reply was not a checkpoint (no text); asking once more"

    @MainActor func testReasoningNoticeAndOverWindowScenes() async throws {
        guard let path = testEnvironment("PI_APP_REASONING_GALLERY") else { throw XCTSkip("Set PI_APP_REASONING_GALLERY for the 0.1.138 scenes") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try SubagentGalleryFixture(root: folder.appendingPathComponent("fixture-" + UUID().uuidString))
        addTeardownBlock { @MainActor in fixture.model.shutdown(); try? await fixture.model.traces.close(); await fixture.model.store?.close() }
        defer { fixture.close() }
        let title = "flash-lite can't use the earlier reasoning"
        let body = "Its provider refused the hidden reasoning saved from earlier replies by luna. Your messages, the replies and the tool results are all still sent."
        var written: [String] = []
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for size in [NSSize(width: 700, height: 600), NSSize(width: 1240, height: 800)] {
                fixture.window.appearance = NSAppearance(named: appearance); fixture.window.setContentSize(size)
                fixture.show("running-collapsed")
                let session = fixture.parent
                fixture.model.subagentSummaries = [:]
                var over = TranscriptMessage(id: "over-window", role: "system", text: ""); over.kind = "execution"; over.detail = Self.overWindow
                var again = TranscriptMessage(id: "asked-again", role: "system", text: ""); again.kind = "execution"; again.detail = Self.askedAgain
                session.messages = [TranscriptMessage(id: "turn", role: "user", text: "Read the ten parts and list their markers."),
                                    TranscriptMessage(id: "reply", role: "assistant", text: "Reading all ten at once.", turn: "turn"), over, again]
                session.observeRunState(["state": .string("error"), "runStatus": .string("failed"), "queuePaused": .bool(true), "errorCode": .string("reasoning_rejected"),
                    "preflightError": .string(title + "\n" + body + "\n\nProvider's message: Corrupted thought signature."),
                    "reasoningRejection": .object(["id": .string("q1"), "rule": .string("thoughtSignature"), "sentence": .string("Corrupted thought signature."), "routeChanged": .bool(false),
                        "model": .string("flash-lite"), "ownReasoning": .bool(false), "origins": .array([.string("luna")]), "title": .string(title), "body": .string(body),
                        "hint": .string("Switching back to luna keeps its reasoning."), "purpose": .string("turn")])])
                await fixture.settle()
                let card = try XCTUnwrap(session.presentedMessages.last { $0.failureCode == SessionDisplay.reasoningRejectedCode })
                let revealed = await fixture.model.revealInTranscript(sessionID: session.id, messageID: card.id)
                XCTAssertTrue(revealed); await fixture.settle()
                let notice = ConversationPaneTests.views(TranscriptNativeFailureRow.self, in: fixture.content).first { $0.accessibilityIdentifier() == "reasoning-refused-notice" }
                XCTAssertNotNil(notice, "The notice is drawn")
                let button = ConversationPaneTests.views(NSView.self, in: fixture.content).first { $0.accessibilityIdentifier() == "continue-without-reasoning" }
                XCTAssertNotNil(button, "with its one button")
                let details = session.presentedMessages.filter { $0.kind == "execution" }.compactMap(\.detail)
                XCTAssertEqual(details, [Self.overWindow, Self.askedAgain])
                XCTAssertEqual(ConversationPaneTests.views(TranscriptNativeExecutionRow.self, in: fixture.content).count, 2, "Both rows are drawn as execution records")
                let file = "reasoning-refused-\(name)-\(Int(size.width)).png"
                try SessionStatsPopoverTests.capture(fixture.window, to: folder.appendingPathComponent(file)); written.append(file)
            }
        }
        XCTAssertEqual(written.count, 4)
    }
}
