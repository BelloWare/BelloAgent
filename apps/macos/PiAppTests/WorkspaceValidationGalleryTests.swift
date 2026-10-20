import AppKit
import XCTest
@testable import PiApp

final class WorkspaceValidationGalleryTests: XCTestCase, SerialTestLane {
    @MainActor func testChangedWorkspaceErrorsInLightDarkAndNarrowLayouts() async throws {
        guard let path = testEnvironment("PI_APP_WORKSPACE_VALIDATION_GALLERY") else { throw XCTSkip("Set PI_APP_WORKSPACE_VALIDATION_GALLERY for these scenes") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = makeWorkspaceModel(stateRoot: scratchRoot("workspace-errors"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        model.prewarmsHelpers = false
        await model.setModel(String(repeating: "界", count: 70), for: "chat")
        var messages = [("model", try XCTUnwrap(model.error)), ("draft", StoreError.draftConflict.localizedDescription)]
        model.displays["chat"] = SessionDisplay(id: "chat")
        let image = model.beginImageImport(sessionID: "chat"); defer { image.finish() }
        do { try await model.pauseRunsForUpdate(); XCTFail("Import must refuse pause") }
        catch { messages.append(("image", error.localizedDescription)) }
        for (name, text) in messages {
            for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for width: CGFloat in [760, 300] {
                    let banner = ErrorBannerView(text: text)
                    banner.appearance = NSAppearance(named: appearance)
                    banner.frame = CGRect(x: 0, y: 0, width: width, height: banner.height(forWidth: width))
                    banner.layoutSubtreeIfNeeded(); banner.displayIfNeeded()
                    for button in [banner.copyButton, banner.dismissButton] {
                        XCTAssertTrue(banner.bounds.contains(button.convert(button.bounds, to: banner)))
                    }
                    let image = try XCTUnwrap(banner.bitmapImageRepForCachingDisplay(in: banner.bounds))
                    banner.cacheDisplay(in: banner.bounds, to: image)
                    try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("\(name)-\(theme)-\(Int(width)).png"))
                }
            }
        }
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for width: CGFloat in [760, 300] {
                for count in [1, 40] {
                    let messages = [TranscriptMessage(id: "question", role: "user", text: "Keep the transcript readable while recovering a draft.", turn: "turn"),
                                    TranscriptMessage(id: "answer", role: "assistant", text: "Saved copies are available from the recovery menu. The conversation keeps its reading space.", turn: "turn")]
                    let pane = try ConversationPaneTests.Pane(messages: messages, width: width, height: 620)
                    defer { pane.close() }
                    pane.model.prewarmsHelpers = false
                    pane.hosted.appearance = NSAppearance(named: appearance)
                    pane.session.draftConflicts = (0..<count).map { .init(id: "copy-\($0)", draft: DraftRecord(id: pane.chat.id, text: "Saved conflict \($0): an image and an edited message remain recoverable.")) }
                    await pane.settle()
                    let banner = try XCTUnwrap(ConversationPaneTests.views(RecoveredBannerView.self, in: pane.hosted).first)
                    XCTAssertEqual(banner.frame.height, 56)
                    let image = try XCTUnwrap(pane.hosted.bitmapImageRepForCachingDisplay(in: pane.hosted.bounds))
                    pane.hosted.cacheDisplay(in: pane.hosted.bounds, to: image)
                    try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("conflict-recovery-\(count)-\(theme)-\(Int(width)).png"))
                }
            }
        }
    }
}
