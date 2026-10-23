import XCTest
import AppKit
import ObjectiveC
@testable import PiApp

final class TranscriptImageCostTests: XCTestCase {
    @MainActor func testSkillOnlyRowsKeepTheirExistingStorage() throws {
        let recording = TranscriptLayoutClock.recording
        defer { TranscriptLayoutClock.recording = recording }
        TranscriptLayoutClock.recording = true; TranscriptMessageContentClock.allocations = 0
        var message = TranscriptMessage(id: "skill", role: "user", text: "Review")
        message.skills = [TranscriptNativeRowParityTests.skill("review")]
        let decoded = try JSONDecoder().decode(TranscriptMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.skills, message.skills)
        XCTAssertEqual(TranscriptMessageContentClock.allocations, 0, "A message with skills but no images needs no new content container")
    }

    @MainActor func testImageMetadataDoesNotWidenTheCommonRow() {
        XCTAssertLessThanOrEqual(MemoryLayout<TranscriptMessage>.stride, 1_272, "The pre-image row's storage budget")
        XCTAssertLessThanOrEqual(MemoryLayout<TranscriptItem>.stride, 5_600, "Work blocks carry messages, including image-free replies")
        XCTAssertLessThanOrEqual(MemoryLayout<TranscriptActions>.stride, 320, "Image actions must fit within the pre-image action budget")
        for type: AnyClass in [TranscriptRowContainer.self, TranscriptNativeUserRow.self, TranscriptNativePartRow.self] {
            print("IMAGE COST class \(type): \(class_getInstanceSize(type)) bytes")
        }
    }

    @MainActor func testPlainRowsDoNoImageMeasuringOrForwarding() throws {
        let previous = TranscriptRowRenderer.reference
        let recording = TranscriptLayoutClock.recording
        defer { TranscriptRowRenderer.reference = previous; TranscriptLayoutClock.recording = recording }
        var forwarded: [Bool] = []
        TranscriptRowRenderer.reference = { inputs in
            forwarded.append(inputs.actions.loadImage != nil)
            return TranscriptNativeUserRow(inputs: inputs)
        }
        TranscriptLayoutClock.recording = true; TranscriptImageMetrics.heightReads = 0
        for caption in ["Question", "Image", "2 images", ""] {
            let message = TranscriptMessage(id: caption, role: "user", text: caption)
            XCTAssertNil(message.imageContent, "Plain rows allocate no image metadata")
            let decoded = try JSONDecoder().decode(TranscriptMessage.self, from: JSONEncoder().encode(message))
            XCTAssertNil(decoded.imageContent, "Decoding a plain row allocates no user-content container")
            let item = TranscriptItem.message(message)
            _ = TranscriptRowEstimate.height(of: item, width: 500)
            let row = TranscriptRowContainer(item: item, fresh: false, actions: TranscriptActions())
            row.frame = CGRect(x: 0, y: 0, width: 500, height: row.measure(width: 500).height)
            row.layoutForViewport()
        }
        XCTAssertEqual(TranscriptImageMetrics.heightReads, 0, "Text-only rows must keep the pre-image geometry path")
        XCTAssertEqual(forwarded, [false, false, false, false], "Rows without images need no image-action closure")
        print("IMAGE COST message stride \(MemoryLayout<TranscriptMessage>.stride), item stride \(MemoryLayout<TranscriptItem>.stride), actions stride \(MemoryLayout<TranscriptActions>.stride), inputs stride \(MemoryLayout<TranscriptRowInputs>.stride)")
    }

    @MainActor func testImageStorageKeepsValueSemanticsAndTheFlatEncoding() throws {
        var original = TranscriptMessage(id: "images", role: "user", text: "2 images")
        original.skills = [TranscriptNativeRowParityTests.skill("review")]
        original.imageCount = 2; original.imageOnly = true
        original.imageReference = TranscriptImageReference(path: "/generated/images.jsonl", id: original.id, offset: 123, length: 456, device: 1, inode: 2)
        original.imageAttachments = [AttachmentRecord(id: "image", path: "/generated/image.png", sha256: "fixture", bytes: 1, mimeType: "image/png")]
        original.foldGroup = "turn"; original.failureCode = "fixture"; original.earlierVersion = true
        original.agentNumbers = ["agent": 1]; original.presentationSourceID = "source"; original.operationID = "operation"
        let bytes = try JSONEncoder().encode(original)
        let fields = try XCTUnwrap(JSONDecoder().decode(WireValue.self, from: bytes).object)
        XCTAssertNil(fields["imageContent"])
        XCTAssertEqual(fields["imageCount"]?.number, 2); XCTAssertEqual(fields["imageOnly"]?.bool, true)
        XCTAssertEqual(fields["skills"]?.array?.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptMessage.self, from: bytes), original)
        var copy = original
        copy.skills = nil; copy.imageCount = 1; copy.imageOnly = false; copy.imageReference = nil; copy.imageAttachments = nil
        XCTAssertEqual(original.imageCount, 2); XCTAssertEqual(original.imageOnly, true)
        XCTAssertNotNil(original.imageReference); XCTAssertEqual(original.imageAttachments?.count, 1)
        XCTAssertEqual(original.skills?.count, 1); XCTAssertNotEqual(copy, original)
        copy.imageCount = nil; copy.imageOnly = nil
        XCTAssertNil(copy.imageContent, "Clearing the last user content releases its container")
        let actions = TranscriptActions(quoteReply: { _ in }, loadImage: { _, _, _ in throw CancellationError() })
        var changed = actions; changed.quoteReply = nil; changed.loadImage = nil
        XCTAssertNotNil(actions.quoteReply); XCTAssertNotNil(actions.loadImage)
        XCTAssertNil(changed.quoteReply); XCTAssertNil(changed.loadImage)
    }

    @MainActor func testAWorkspaceWithNoImageRequestsQuitsWithoutCreatingImageServices() async throws {
        let root = scratchRoot("image-cost-quit")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()), tabDefaults: nil)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(model.transcriptImages); XCTAssertNil(model.transcriptImageReader)
        let lifecycle = ApplicationLifecycle(); lifecycle.model = model
        let answered = expectation(description: "Quit with no image requests")
        lifecycle.answerTermination = { accepted in XCTAssertTrue(accepted); answered.fulfill() }
        XCTAssertEqual(lifecycle.applicationShouldTerminate(NSApp), .terminateLater)
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertNil(model.transcriptImages, "Quit must not initialize an unused cache")
        XCTAssertNil(model.transcriptImageReader, "Quit must not initialize an unused reader")
        try await model.traces.close(); await model.store?.close()
    }

    @MainActor func testOnlyAnImageRequestCreatesTheServicesItsSourceNeeds() async throws {
        let journal = try TranscriptImageLoadingTests.Journal(); defer { journal.remove() }
        let model = WorkspaceModel(stateRoot: journal.root.appendingPathComponent("workspace"), vault: ConfigurationVault(storage: MemoryVaultStorage()), tabDefaults: nil)
        defer { model.shutdown() }
        let page = try await model.history.read(path: journal.path.path)
        XCTAssertNil(model.transcriptImages, "Reading an image-bearing page must not create a cache")
        XCTAssertNil(model.transcriptImageReader, "Reading a page must not start the thumbnail reader")
        let plain = try XCTUnwrap(page.messages.first { $0.role == "assistant" })
        do { _ = try await model.transcriptImage(plain, sessionID: "chat", index: 0, pixels: 128); XCTFail("Not an image") }
        catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertNil(model.transcriptImages); XCTAssertNil(model.transcriptImageReader)
        let image = try XCTUnwrap(page.messages.first { $0.id == "caption" })
        let bitmap = try await model.transcriptImage(image, sessionID: "chat", index: 0, pixels: 128)
        XCTAssertEqual(bitmap.image.width, 128)
        XCTAssertNotNil(model.transcriptImages)
        XCTAssertNil(model.transcriptImageReader, "A valid offset needs pixels, not a second journal index")
        // A live row has no offset yet. This request really needs the reader.
        model.chats = [ChatRecord(id: "chat", workspaceID: "fixture", title: "Generated images", path: journal.path.path, profileID: "fixture")]
        var live = image; live.imageReference = nil
        _ = try await model.transcriptImage(live, sessionID: "chat", index: 1, pixels: 128)
        let reader = try XCTUnwrap(model.transcriptImageReader)
        let count = await reader.retainedIndexCount
        XCTAssertEqual(count, 1)
        await reader.releaseIndexes(); await model.history.releaseIndexes()
        try await model.traces.close(); await model.store?.close()
    }
}
