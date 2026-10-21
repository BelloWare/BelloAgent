import XCTest
@testable import PiApp

final class QueuedAttachmentLimitTests: XCTestCase {
    @MainActor func testQueuedRewriteValidatesTheParkedDraftCountAndBytes() async throws {
        for limitedByCount in [true, false] {
            let root = scratchRoot("queued-image-limit")
            let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
            registerWorkspaceFixtureTeardown(model, root: root)
            let view = SessionDisplay(id: "chat"); view.selectionMetadataLoaded = true; model.displays[view.id] = view
            let images = (0..<(limitedByCount ? 4 : 2)).map { AttachmentRecord(id: "i\($0)", path: "/fixture/\($0).png", sha256: "h", bytes: limitedByCount ? 10 : 16 * 1024 * 1024, mimeType: "image/png") }
            view.draftBeforeQueueEdit = DraftRecord(id: view.id, text: "Parked", attachments: images)
            view.queueEditingID = "queued"; view.queueEditID = "edit"; view.draft = "Rewrite"
            let extra = AttachmentRecord(id: "extra", path: "/fixture/extra.png", sha256: "h", bytes: 10, mimeType: "image/png")
            model.receiveAttachments([extra], into: view)
            XCTAssertEqual(view.draftBeforeQueueEdit?.attachments, images)
            XCTAssertTrue(view.attachments.isEmpty); XCTAssertEqual(view.draft, "Rewrite")
            XCTAssertTrue(view.notice.contains("four images") || model.error?.contains("four images") == true)
            view.restoreDraft(try XCTUnwrap(view.draftBeforeQueueEdit))
            XCTAssertEqual(view.attachments, images, "Cancel restores a draft still within the helper's limits")
        }
    }

    @MainActor func testAnImportWaitingForRecoveryRechecksTheParkedDestination() async throws {
        let root = scratchRoot("queued-image-recovery")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let view = SessionDisplay(id: "chat"); model.displays[view.id] = view
        let images = (0..<4).map { AttachmentRecord(id: "i\($0)", path: "/fixture/\($0).png", sha256: "h", bytes: 1, mimeType: "image/png") }
        var release: CheckedContinuation<Void, Never>?
        let recovery = Task { await withCheckedContinuation { release = $0 }; model.draftWrites.recoveries.removeValue(forKey: view.id) }
        model.draftWrites.recoveries[view.id] = recovery
        try await eventually("recovery held") { release != nil }
        model.receiveAttachments([images[0]], into: view)
        view.draftBeforeQueueEdit = DraftRecord(id: view.id, text: "Parked", attachments: images)
        view.queueEditingID = "q"; view.queueEditID = "e"; view.draft = "Rewrite"
        release?.resume(); release = nil
        try await eventually("import settled") { model.attachmentImports == 0 }
        XCTAssertEqual(view.draftBeforeQueueEdit?.attachments, images)
        XCTAssertTrue(view.attachments.isEmpty)
    }
}
