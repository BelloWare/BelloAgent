import AppKit
import XCTest
@testable import PiApp

final class WorkspaceValidationGalleryTests: XCTestCase, SerialTestLane {
    @MainActor func testFailedQueuedSaveRetryInLightDarkAndNarrowLayouts() async throws {
        guard let path = testEnvironment("PI_APP_WORKSPACE_VALIDATION_GALLERY") else { throw XCTSkip("Set PI_APP_WORKSPACE_VALIDATION_GALLERY for these scenes") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for width: CGFloat in [760, 300] {
                let pane = try ConversationPaneTests.Pane(messages: [
                    TranscriptMessage(id: "question", role: "user", text: "Keep the earlier Save's outcome until the helper can confirm it.", turn: "turn"),
                    TranscriptMessage(id: "answer", role: "assistant", text: "The rewrite and the draft set aside remain available while that request is checked.", turn: "turn")
                ], width: width, height: 620)
                defer { pane.close() }
                pane.model.prewarmsHelpers = false; pane.hosted.appearance = NSAppearance(named: appearance)
                pane.session.queueEditingID = "queued"; pane.session.queueEditID = "edit"; pane.session.queueEditOriginal = "Original"
                pane.session.draftBeforeQueueEdit = DraftRecord(id: pane.chat.id, text: "Parked draft")
                pane.session.draft = "Earlier Save"
                pane.session.queueEditPendingOperation = "save"; pane.session.queueEditSentDigest = QueuedEditDraft.digest(pane.session.draft)
                pane.model.queueEditOperation = { _, _, _ in throw HostError.rejected("session_missing", "The replacement helper has not opened this chat yet.") }
                pane.model.saveQueuedEdit(sessionID: pane.chat.id)
                try await eventually("Retry refused") { !pane.session.queueEditResolving && pane.session.submittingCommands.isEmpty }
                XCTAssertEqual(pane.session.queueEditPendingOperation, "save")
                XCTAssertTrue(pane.session.queueEditNotice.contains("earlier request is still unconfirmed"))
                await pane.settle()
                let image = try XCTUnwrap(pane.hosted.bitmapImageRepForCachingDisplay(in: pane.hosted.bounds))
                pane.hosted.cacheDisplay(in: pane.hosted.bounds, to: image)
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("queued-save-retry-refused-\(theme)-\(Int(width)).png"))
            }
        }
    }

    @MainActor func testConfirmedQueuedSaveRecoveryInLightDarkAndNarrowLayouts() async throws {
        guard let path = testEnvironment("PI_APP_WORKSPACE_VALIDATION_GALLERY") else { throw XCTSkip("Set PI_APP_WORKSPACE_VALIDATION_GALLERY for these scenes") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for width: CGFloat in [760, 300] {
                let pane = try ConversationPaneTests.Pane(messages: [
                    TranscriptMessage(id: "question", role: "user", text: "Review the queued rewrite while I keep typing.", turn: "turn"),
                    TranscriptMessage(id: "answer", role: "assistant", text: "The saved rewrite stays in the queue. Newer typing remains in your composer.", turn: "turn")
                ], width: width, height: 620)
                defer { pane.close() }
                pane.model.prewarmsHelpers = false; pane.hosted.appearance = NSAppearance(named: appearance)
                let intent = CommandIntent(id: "queued-save", sessionID: pane.chat.id, turnID: "queue-edit:edit", text: "The saved queued rewrite.", state: "intent", queueEditID: "edit")
                try await pane.model.store?.recordSubmission(intent, draft: nil)
                pane.session.recovered = [intent]; pane.session.draft = "Newer typing after choosing Save."
                for confirmed in [false, true] {
                    if confirmed { try await pane.model.retireConfirmedSubmission(intent.id, in: pane.session) }
                    await pane.settle()
                    let banner = try XCTUnwrap(ConversationPaneTests.views(RecoveredBannerView.self, in: pane.hosted).first)
                    XCTAssertEqual(banner.isHidden, confirmed)
                    XCTAssertEqual(pane.session.draft, "Newer typing after choosing Save.")
                    let image = try XCTUnwrap(pane.hosted.bitmapImageRepForCachingDisplay(in: pane.hosted.bounds))
                    pane.hosted.cacheDisplay(in: pane.hosted.bounds, to: image)
                    try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("queued-save-\(confirmed ? "confirmed" : "unanswered")-\(theme)-\(Int(width)).png"))
                }
            }
        }
    }

    @MainActor func testLiveAndSettledSubmissionRecoveryInLightDarkAndNarrowLayouts() async throws {
        guard let path = testEnvironment("PI_APP_WORKSPACE_VALIDATION_GALLERY") else { throw XCTSkip("Set PI_APP_WORKSPACE_VALIDATION_GALLERY for these scenes") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for width: CGFloat in [760, 300] {
                for kind in ["steer", "followup"] {
                    let pane = try ConversationPaneTests.Pane(messages: [
                        TranscriptMessage(id: "question", role: "user", text: "Review the changes while I prepare the next message.", turn: "turn"),
                        TranscriptMessage(id: "answer", role: "assistant", text: "I am reviewing the changes. Your next message is being delivered.", turn: "turn")
                    ], width: width, height: 620)
                    defer { pane.close() }
                    pane.model.prewarmsHelpers = false; pane.hosted.appearance = NSAppearance(named: appearance)
                    let intent = CommandIntent(id: kind, sessionID: pane.chat.id, turnID: "next", text: "Include the pending edits in your review.", state: "intent")
                    try await pane.model.store?.recordSubmission(intent, draft: nil)
                    pane.session.runState = .running; pane.session.recovered = [intent]
                    pane.session.submittingCommands.insert(intent.id)
                    for live in [true, false] {
                        if !live { pane.model.finishSubmission(intent.id, in: pane.session) }
                        await pane.settle()
                        let banner = try XCTUnwrap(ConversationPaneTests.views(RecoveredBannerView.self, in: pane.hosted).first)
                        XCTAssertEqual(banner.isHidden, live)
                        let image = try XCTUnwrap(pane.hosted.bitmapImageRepForCachingDisplay(in: pane.hosted.bounds))
                        pane.hosted.cacheDisplay(in: pane.hosted.bounds, to: image)
                        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("\(kind)-\(live ? "live" : "settled")-\(theme)-\(Int(width)).png"))
                    }
                }
            }
        }
    }

    @MainActor func testRetainedInputRecoveryInLightDarkAndNarrowLayouts() async throws {
        guard let path = testEnvironment("PI_APP_WORKSPACE_VALIDATION_GALLERY") else { throw XCTSkip("Set PI_APP_WORKSPACE_VALIDATION_GALLERY for these scenes") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for width: CGFloat in [760, 300] {
                for pinned in [false, true] {
                    let pane = try ConversationPaneTests.Pane(messages: [
                        TranscriptMessage(id: "question", role: "user", text: "Review the draft without losing what I chose to send.", turn: "turn"),
                        TranscriptMessage(id: "answer", role: "assistant", text: "Retained input stays available in the recovery menu while you continue editing.", turn: "turn")
                    ], width: width, height: 620)
                    defer { pane.close() }
                    pane.model.prewarmsHelpers = false; pane.hosted.appearance = NSAppearance(named: appearance)
                    let intent = CommandIntent(id: "retained", sessionID: pane.chat.id, turnID: "turn-edit", text: "The replacement captured before newer typing.", state: "intent")
                    if pinned { pane.session.draftVersion.preservingSubmission(intent) }
                    else { try await pane.model.store?.recordSubmission(intent, draft: nil) }
                    pane.session.recovered = [intent]; pane.session.uncertain = false; pane.session.draft = "The draft restored after cancelling the active edit."
                    await pane.settle()
                    let banner = try XCTUnwrap(ConversationPaneTests.views(RecoveredBannerView.self, in: pane.hosted).first)
                    XCTAssertFalse(banner.isHidden); XCTAssertEqual(banner.frame.height, 56)
                    let chooser = try XCTUnwrap(ConversationPaneTests.views(PiKit.MenuButton.self, in: banner).first)
                    XCTAssertTrue(chooser.label.contains(pinned ? "retained" : "saved"))
                    let image = try XCTUnwrap(pane.hosted.bitmapImageRepForCachingDisplay(in: pane.hosted.bounds))
                    pane.hosted.cacheDisplay(in: pane.hosted.bounds, to: image)
                    try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("retained-\(pinned ? "unsaved" : "rejected")-\(theme)-\(Int(width)).png"))
                }
            }
        }
    }

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
