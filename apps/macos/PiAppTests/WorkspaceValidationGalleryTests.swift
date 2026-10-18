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
    }
}
