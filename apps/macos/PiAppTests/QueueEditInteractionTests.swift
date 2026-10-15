import AppKit
import XCTest
@testable import PiApp

/// The native queue row, composer and application menu, with the packaged
/// helper and generated loopback responses. Key-window/menu ownership is serial.
final class QueueEditInteractionTests: XCTestCase, SerialTestLane {
    @MainActor func testReturnSavesSlashTextWhileEditingInsteadOfOpeningSkillCompletion() async throws {
        let fixture = try await fixture()
        let id = try await fixture.queued(paused: true)
        try await fixture.edit(id)
        try fixture.type("Please explain /nonexistent")
        let editor = try XCTUnwrap(fixture.pane.composer.field?.documentView as? ComposerTextView)
        // Wait for the native location callback, including the code classifier.
        try await eventually("native caret reported") { fixture.session.composerLocation?.selectedRangeUTF16.location == editor.string.utf16.count }
        await fixture.session.completionParse?.value
        XCTAssertFalse(fixture.session.completionVisible, "A queued rewrite is text only: completion must not take Return")
        fixture.key()
        try await eventually("Return saved the literal rewrite", timeout: .seconds(5)) { fixture.session.queueEditingID == nil }
        let result = try await fixture.host.request("queue.read", sessionID: fixture.session.id, params: ["turnId": .string(id)]).object ?? [:]
        XCTAssertEqual(result["text"]?.string, "Please explain /nonexistent")
    }

    @MainActor func testWindowAndMainMenuCommandReturnSaveTheSameHeldSteeringItem() async throws {
        let fixture = try await fixture()
        let id = try await fixture.queued(paused: true, steer: true)
        let oldMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = oldMenu }
        let menus = ApplicationMenus(model: fixture.model, updates: UpdateController(), workspaceWindow: { fixture.window }, revealWorkspace: {}, showSettings: {})
        menus.install()
        NSApp.unhide(nil)
        // XCTest's host can still be registered as a background process on
        // launch. Refresh its activation policy before asking for keys.
        let oldPolicy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(oldPolicy) }
        NSApp.setActivationPolicy(.accessory)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        fixture.window.makeKeyAndOrderFront(nil); fixture.window.makeMain(); fixture.window.makeKey()
        try await eventually("fixture is key") { NSApp.keyWindow === fixture.window }
        let conversation = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "Conversation" }?.submenu)
        let command = try XCTUnwrap(conversation.items.first { $0.keyEquivalent == "\r" })
        XCTAssertEqual(command.title, "Send / Steer Current Run")
        XCTAssertEqual(command.keyEquivalentModifierMask, .command)
        for fromMenu in [false, true] {
            fixture.session.draft = "Parked draft"
            try await fixture.edit(id)
            let rewrite = "Steering rewritten via \(fromMenu ? "menu" : "composer")"
            try fixture.type(rewrite)
            if fromMenu { fixture.window.makeFirstResponder(nil) }
            menus.menuNeedsUpdate(conversation)
            fixture.key(.command)
            try await eventually("Command-Return saved", timeout: .seconds(10)) { fixture.session.queueEditingID == nil }
            XCTAssertEqual(fixture.session.draft, "Parked draft")
            let result = try await fixture.host.request("queue.read", sessionID: fixture.session.id, params: ["turnId": .string(id)]).object ?? [:]
            XCTAssertEqual(result["text"]?.string, rewrite); XCTAssertEqual(result["kind"]?.string, "steering")
            XCTAssertEqual(fixture.session.queue.count, 1, "Save creates no new follow-up or steer")
            XCTAssertTrue(fixture.session.queuePaused, "Save releases only the edit hold")
        }
    }

    @MainActor func testExternallyRemovedEditKeepsExactTextAndExplainsAfterRefresh() async throws {
        let fixture = try await fixture()
        let id = try await fixture.queued(paused: true)
        fixture.session.draft = "Parked draft"
        try await fixture.edit(id)
        try fixture.type("  Keep this rewrite exactly\n")
        let editID = try XCTUnwrap(fixture.session.queueEditID)
        _ = try await fixture.host.request("queue.edit.remove", sessionID: fixture.session.id, params: ["editId": .string(editID)])
        fixture.pane.composer.send.performClick(nil)
        try await eventually("removed edit reconciled", timeout: .seconds(10)) { fixture.session.queueEditingID == nil }
        XCTAssertEqual(fixture.session.draft, "  Keep this rewrite exactly\n\n\nParked draft")
        fixture.model.refresh(fixture.session.id)
        try await eventually("refresh settled") { !fixture.session.snapshotInFlight }
        XCTAssertTrue(fixture.session.notice.contains("not saved"), "The reason must survive streaming/snapshot refresh: \(fixture.session.notice)")
        XCTAssertTrue(fixture.session.notice.contains("removed"))
        try await fixture.model.flushDrafts()
        let saved = try await fixture.model.store?.get(DraftRecord.self, kind: "draft", id: fixture.session.id)
        XCTAssertEqual(saved?.text, fixture.session.draft)
    }

    @MainActor func testSaveButtonReplacesRunningFollowUpAndRestoresDraft() async throws {
        let fixture = try await fixture()
        let view = fixture.session, model = fixture.model
        view.draft = "slow starting request"; model.send(sessionID: view.id)
        try await eventually("run started", timeout: .seconds(60)) { view.busy && !view.loading }
        view.draft = "Queued original"; model.send(sessionID: view.id)
        try await eventually("follow-up queued", timeout: .seconds(60)) { !view.loading && view.queue.count == 1 }
        let turnID = try XCTUnwrap(view.queue.first?["turnId"]?.string)
        view.draft = "Draft before editing"
        try await fixture.edit(turnID)
        try fixture.type("Rewritten queued message")
        fixture.pane.composer.refresh()
        XCTAssertEqual(fixture.pane.composer.send.accessibilityLabel(), "Save Queued Message")
        XCTAssertTrue(fixture.pane.composer.send.isEnabled, "Save must be enabled while the parent run is active")
        fixture.pane.composer.send.performClick(nil)
        try await eventually("Save confirmed: \(view.notice)", timeout: .seconds(15)) { view.queueEditingID == nil }
        XCTAssertEqual(view.draft, "Draft before editing")
        let result = try await fixture.host.request("queue.read", sessionID: view.id, params: ["turnId": .string(turnID)]).object ?? [:]
        XCTAssertEqual(result["text"]?.string, "Rewritten queued message")
        try await eventually("queue panel updated") { view.queue.first?["text"]?.string == "Rewritten queued message" }
        try await model.flushDrafts()
        let saved = try await model.store?.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.text, "Draft before editing"); XCTAssertNil(saved?.queuedEdit)
    }

    @MainActor func testSavePublishesAcknowledgedTextBeforeTheNextSnapshot() async throws {
        let fixture = try await fixture()
        let id = try await fixture.queued(paused: true)
        try await fixture.edit(id)
        try fixture.type("Acknowledged replacement")
        try await eventually("previous snapshot finished") { !fixture.session.snapshotInFlight }
        fixture.session.snapshotInFlight = true
        defer { fixture.session.snapshotInFlight = false }
        fixture.pane.composer.send.performClick(nil)
        try await eventually("Save confirmed") { fixture.session.queueEditingID == nil }
        XCTAssertEqual(fixture.session.queue.first?["text"]?.string, "Acknowledged replacement", "A confirmed Save updates its row even when streaming refresh is delayed")
    }

    @MainActor func testRetriedSaveKeepsANewerRewriteFromTheHelper() async throws {
        try await assertHistoricalSaveKeepsNewerQueueText(viaStatus: false)
    }

    @MainActor func testSaveSettledByStatusKeepsANewerRewriteFromTheHelper() async throws {
        try await assertHistoricalSaveKeepsNewerQueueText(viaStatus: true)
    }

    @MainActor private func assertHistoricalSaveKeepsNewerQueueText(viaStatus: Bool) async throws {
        let fixture = try await fixture()
        let id = try await fixture.queued(paused: true)
        let view = fixture.session, host = fixture.host
        view.draft = "Unrelated queued message"; fixture.model.send(sessionID: view.id)
        try await eventually("second message queued") { !view.loading && view.queue.count == 2 }
        let otherID = try XCTUnwrap(view.queue.last?["turnId"]?.string)
        view.draft = "Parked draft"
        try await fixture.edit(id); try fixture.type("Older save")
        let editID = try XCTUnwrap(view.queueEditID)
        try await eventually("previous snapshot finished") { !view.snapshotInFlight }
        view.snapshotInFlight = true
        defer { view.snapshotInFlight = false }

        // The first Save reached the helper, but its response was lost.
        _ = try await host.request("queue.edit.save", sessionID: view.id, params: ["editId": .string(editID), "text": .string("Older save")])
        _ = try await host.request("queue.edit.begin", sessionID: view.id, params: ["editId": .string("newer"), "turnId": .string(id)])
        _ = try await host.request("queue.edit.save", sessionID: view.id, params: ["editId": .string("newer"), "text": .string("Newer rewrite")])
        let snapshot = try await host.request("session.snapshot", sessionID: view.id).object ?? [:]
        XCTAssertNotNil(view.applyQueueSnapshot(snapshot))
        let rows = view.queue, displayedRevision = view.queuePresentedEditRevision
        XCTAssertEqual(rows.first?["text"]?.string, "Newer rewrite")
        let unrelated = try await host.request("queue.edit.begin", sessionID: view.id, params: ["editId": .string("unrelated"), "turnId": .string(otherID)]).object ?? [:]
        XCTAssertGreaterThan(try XCTUnwrap(unrelated["revision"]?.number), Double(displayedRevision))

        var acknowledgement: [String: WireValue] = [:]
        fixture.model.queueEditOperation = { method, sessionID, params in
            if viaStatus && method == "queue.edit.save" { throw HostError.failure("Synthetic lost retry reply") }
            acknowledgement = try await host.request(method, sessionID: sessionID, params: params).object ?? [:]
            return acknowledgement
        }
        fixture.pane.composer.refresh(); fixture.pane.composer.send.performClick(nil)
        try await eventually("historical Save settled") { view.queueEditingID == nil }
        XCTAssertEqual(acknowledgement["revision"], unrelated["revision"], "The helper returns its current revision for historical outcomes")
        if viaStatus { XCTAssertEqual(acknowledgement["state"]?.string, "saved") }
        else { XCTAssertEqual(acknowledgement["repeated"]?.bool, true) }
        XCTAssertEqual(view.queue, rows, "Save settlement cannot roll the visible queue back to an earlier rewrite")
        XCTAssertEqual(view.queuePresentedEditRevision, displayedRevision)
        XCTAssertEqual(view.draft, "Parked draft")
        XCTAssertTrue(view.sendingRows.isEmpty)
        let current = try await host.request("queue.read", sessionID: view.id, params: ["turnId": .string(id)]).object ?? [:]
        XCTAssertEqual(current["text"]?.string, "Newer rewrite")
        view.snapshotInFlight = false
        fixture.model.refresh(view.id)
        try await eventually("current queue refreshed") { !view.snapshotInFlight && view.queuePresentedEditRevision == Int(unrelated["revision"]?.number ?? -1) }
        XCTAssertEqual(view.queue.first?["text"]?.string, "Newer rewrite")
    }

    @MainActor func testRetryingCancellationClearsTheRestartRecoveryWarning() async throws {
        try await assertRecoveredCancellationSettlesNotice(viaStatus: false)
    }

    @MainActor func testCancelledRecoveryStatusClearsTheRestartRecoveryWarning() async throws {
        try await assertRecoveredCancellationSettlesNotice(viaStatus: true)
    }

    @MainActor private func assertRecoveredCancellationSettlesNotice(viaStatus: Bool) async throws {
        let fixture = try await fixture()
        let id = try await fixture.queued(paused: true)
        let view = fixture.session, model = fixture.model, host = fixture.host
        // Cover a hold with no recovered draft, an unchanged rewrite and a
        // changed rewrite that must replace the old warning with useful text.
        for rewrite in [nil, "Queued original", "Recovered rewrite"] as [String?] {
            let editID = UUID().uuidString
            view.draft = "Parked draft"; view.queueEditNotice = ""
            _ = try await host.request("queue.edit.begin", sessionID: view.id, params: ["editId": .string(editID), "turnId": .string(id)])
            view.unreconciledQueuedEdit = rewrite.map { QueuedEditDraft(editID: editID, turnID: id, rewrite: $0, original: "Queued original") }
            model.refresh(view.id)
            try await eventually("restart hold shown") { !view.snapshotInFlight && view.queueEditHold?.editID == editID }
            try await eventually("Cancel Edit mounted") {
                fixture.pane.layoutSubtreeIfNeeded()
                return ConversationPaneTests.views(QueueRowView.self, in: fixture.pane).contains { $0.state?.item.id == id && !$0.cancelEdit.isHidden && $0.cancelEdit.isEnabled }
            }
            let row = try XCTUnwrap(ConversationPaneTests.views(QueueRowView.self, in: fixture.pane).first { $0.state?.item.id == id })
            var firstCancel = true
            model.queueEditOperation = { method, sessionID, params in
                if method == "queue.edit.cancel", firstCancel {
                    firstCancel = false
                    if viaStatus { _ = try await host.request(method, sessionID: sessionID, params: params) }
                    throw HostError.failure("Synthetic unanswered cancellation")
                }
                return try await host.request(method, sessionID: sessionID, params: params).object ?? [:]
            }
            row.cancelEdit.performClick(nil)
            try await eventually("cancellation failure shown") { view.queueEditCancelling == nil && view.queueEditNotice.contains("could not be let go") }
            model.refresh(view.id)
            try await eventually("failure snapshot settled") { !view.snapshotInFlight }
            XCTAssertTrue(view.notice.contains("could not be let go"), "Unconfirmed cancellation stays visible")
            let stopped = try await host.request("session.status", sessionID: view.id).object ?? [:]
            let preflight = try XCTUnwrap(stopped["preflightError"]?.string)
            XCTAssertFalse(preflight.isEmpty)
            XCTAssertEqual(view.notice, view.queueEditNotice + "\n" + preflight)
            // No snapshot may repair the displayed notice after settlement.
            // A status reply or repeated Cancel emits no queue-change event.
            try await eventually("snapshot idle before recovery settlement") { !view.snapshotInFlight }
            view.snapshotInFlight = true
            defer { view.snapshotInFlight = false }
            if viaStatus {
                await model.reconcileQueuedEdit(view, try XCTUnwrap(view.unreconciledQueuedEdit))
            } else {
                _ = try await host.request("queue.edit.cancel", sessionID: view.id, params: ["editId": .string(editID)])
                try await eventually("Cancel Edit available again") { row.cancelEdit.isEnabled }
                row.cancelEdit.performClick(nil)
            }
            try await eventually("recovery cancellation settled") { view.queueEditCancelling == nil && view.unreconciledQueuedEdit == nil }
            XCTAssertFalse(view.queueEditNotice.contains("could not be let go"), "Confirmed recovery must retire its retained failure")
            let expected = view.queueEditNotice.isEmpty ? preflight : view.queueEditNotice + "\n" + preflight
            XCTAssertEqual(view.notice, expected, "Settlement must recompute both components without waiting for a snapshot")
            view.snapshotInFlight = false
            model.refresh(view.id)
            try await eventually("settled snapshot applied") { !view.snapshotInFlight }
            XCTAssertFalse(view.notice.contains("could not be let go"), "Snapshots must not republish a resolved cancellation failure")
            let kept = rewrite == "Recovered rewrite"
            XCTAssertEqual(view.draft, kept ? "Recovered rewrite\n\nParked draft" : "Parked draft")
            if kept { XCTAssertTrue(view.queueEditNotice.contains("rewrite was not saved")) }
            XCTAssertNil(view.queueEditingID); XCTAssertNil(view.queueEditHold)
            XCTAssertEqual(view.queue.first?["text"]?.string, "Queued original")
            try await model.flushDrafts()
            let saved = try await model.store?.get(DraftRecord.self, kind: "draft", id: view.id)
            XCTAssertEqual(saved?.text, view.draft); XCTAssertNil(saved?.queuedEdit)
        }
    }

    @MainActor func testReturnReplacesRunningSteeringWithoutSubmittingAnotherMessage() async throws {
        let fixture = try await fixture()
        let id = try await fixture.queued(paused: false, steer: true)
        try await fixture.edit(id); try fixture.type("Steering replacement")
        fixture.key()
        try await eventually("steering saved") { fixture.session.queueEditingID == nil }
        let result = try await fixture.host.request("queue.read", sessionID: fixture.session.id, params: ["turnId": .string(id)]).object ?? [:]
        XCTAssertEqual(result["text"]?.string, "Steering replacement"); XCTAssertEqual(result["kind"]?.string, "steering")
        XCTAssertEqual(fixture.session.queue.compactMap { $0["turnId"]?.string }, [id])
        XCTAssertTrue(fixture.session.sendingRows.isEmpty)
    }

    @MainActor func testOverLimitPasteKeepsTheEditAndAllowsCorrection() async throws {
        let fixture = try await fixture()
        let id = try await fixture.queued(paused: true)
        fixture.session.draft = "Parked"
        try await fixture.edit(id)
        let oversized = String(repeating: "x", count: SubmissionLimits.messageBytes + 1)
        let editor = try XCTUnwrap(fixture.pane.composer.field?.documentView as? ComposerTextView)
        editor.insertText(oversized, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertEqual(fixture.session.draft, "Queued original", "The normal composer's size limit still protects queued edits")
        let banner = try XCTUnwrap(ConversationPaneTests.views(ComposerEditBanner.self, in: fixture.pane).first)
        XCTAssertTrue(banner.save.isEnabled); XCTAssertEqual(fixture.session.queueEditingID, id)
        XCTAssertNotNil(fixture.session.queueEditHold)
        try fixture.type("Corrected replacement"); fixture.key(.command)
        try await eventually("corrected Save confirmed") { fixture.session.queueEditingID == nil }
        XCTAssertEqual(fixture.session.draft, "Parked")
    }

    @MainActor func testBannerOffersSaveAndCancelAndBothRestoreTheParkedDraft() async throws {
        let fixture = try await fixture()
        let id = try await fixture.queued(paused: true)
        for saving in [false, true] {
            fixture.session.draft = "Parked draft"
            try await fixture.edit(id)
            try fixture.type("Replacement")
            fixture.pane.composer.refresh()
            let banner = try XCTUnwrap(ConversationPaneTests.views(ComposerEditBanner.self, in: fixture.pane).first)
            let button = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self, in: banner).first { $0.title == (saving ? "Save" : "Cancel") })
            XCTAssertTrue(button.isEnabled); button.performClick(nil)
            try await eventually("banner action confirmed") { fixture.session.queueEditingID == nil }
            XCTAssertEqual(fixture.session.draft, "Parked draft")
            let result = try await fixture.host.request("queue.read", sessionID: fixture.session.id, params: ["turnId": .string(id)]).object ?? [:]
            XCTAssertEqual(result["text"]?.string, saving ? "Replacement" : "Queued original")
        }
    }

    @MainActor func testImagesAndSkillsStayQueuedAndTheWholeParkedDraftReturns() async throws {
        let fixture = try await fixture(images: true)
        let id = try await fixture.queued(paused: true)
        let directory = URL(fileURLWithPath: fixture.setup.workspace.path).appendingPathComponent(".agents/skills/queue-fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "---\nname: queue-fixture\ndescription: Generated queue test\n---\nSynthetic instructions.\n".write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        await fixture.model.loadSkillCatalog(refresh: true, sessionID: fixture.session.id)
        let skill = try XCTUnwrap(fixture.session.skillCatalog.entries.first { $0.skill.name == "queue-fixture" }?.skill)
        let file = fixture.setup.root.appendingPathComponent("fixture.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(NSColor(deviceRed: 0.2, green: 0.4, blue: 0.8, alpha: 1), atX: x, y: y) } }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        let attachment = try AttachmentRecord.inspect(file)
        fixture.session.skills = [skill.chip]; fixture.session.attachments = [attachment]; fixture.session.draft = ""
        fixture.model.send(sessionID: fixture.session.id)
        try await eventually("image submission settled") { !fixture.session.loading }
        XCTAssertNil(fixture.session.sendFailure)
        try await eventually("image and skill message queued", timeout: .seconds(60)) { !fixture.session.loading && fixture.session.queue.count == 2 }
        let inputID = try XCTUnwrap(fixture.session.queue.last?["turnId"]?.string)
        for save in [false, true] {
            fixture.session.draft = "My parked draft"; fixture.session.skills = [skill.chip]; fixture.session.attachments = [attachment]
            try await fixture.edit(inputID)
            XCTAssertEqual(fixture.session.draft, ""); XCTAssertTrue(fixture.session.skills.isEmpty); XCTAssertTrue(fixture.session.attachments.isEmpty)
            XCTAssertTrue(fixture.pane.composer.send.isEnabled, "Image/skill-only queued messages can save empty text")
            let banner = try XCTUnwrap(ConversationPaneTests.views(ComposerEditBanner.self, in: fixture.pane).first)
            if save { banner.save.performClick(nil) } else { banner.cancel.performClick(nil) }
            try await eventually("input edit finished") { fixture.session.queueEditingID == nil }
            XCTAssertEqual(fixture.session.draft, "My parked draft")
            XCTAssertEqual(fixture.session.skills, [skill.chip]); XCTAssertEqual(fixture.session.attachments, [attachment])
        }
        XCTAssertEqual(fixture.session.queue.compactMap { $0["turnId"]?.string }, [id, inputID], "Same position and identity")
        let check = try await fixture.host.request("queue.edit.begin", sessionID: fixture.session.id, params: ["turnId": .string(inputID), "editId": .string("verify-inputs")]).object ?? [:]
        XCTAssertEqual(check["attachmentCount"]?.number, 1); XCTAssertEqual(check["skillCount"]?.number, 1)
        _ = try await fixture.host.request("queue.edit.cancel", sessionID: fixture.session.id, params: ["editId": .string("verify-inputs")])
    }

    @MainActor func testEditAndParkedDraftSurviveRelaunchAndSaveDurably() async throws {
        let first = try await fixture()
        let id = try await first.queued(paused: true)
        first.session.draft = "Before relaunch"
        try await first.edit(id); try first.type("Recovered queued rewrite")
        try await first.model.flushDrafts()
        await first.model.stopHostsAndWait(); first.model.shutdown()
        try await first.model.traces.close(); await first.model.store?.close()
        first.window.contentView = nil; first.window.close()
        let model = WorkspaceModel(stateRoot: first.setup.state, vault: first.setup.vault)
        await model.restore(); await model.select(first.session.id)
        let chat = try XCTUnwrap(model.record(first.session.id)), view = try XCTUnwrap(model.selected)
        let second = try await mount(model, chat: chat, session: view, setup: first.setup)
        try await eventually("saved edit resumed", timeout: .seconds(60)) { view.queueEditingID == id }
        second.pane.composer.refresh()
        XCTAssertEqual(view.draft, "Recovered queued rewrite"); XCTAssertEqual(view.savedDraft.text, "Before relaunch")
        XCTAssertTrue(second.pane.composer.send.isEnabled)
        second.pane.composer.send.performClick(nil)
        try await eventually("recovered edit saved") { view.queueEditingID == nil }
        XCTAssertEqual(view.draft, "Before relaunch")
        try await model.flushDrafts()
        let saved = try await model.store?.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertNil(saved?.queuedEdit); XCTAssertEqual(saved?.text, "Before relaunch")
        let result = try await second.host.request("queue.read", sessionID: view.id, params: ["turnId": .string(id)]).object ?? [:]
        XCTAssertEqual(result["text"]?.string, "Recovered queued rewrite")
        await model.stopHostsAndWait()
        _ = try await model.open(try XCTUnwrap(model.record(view.id)))
        let reopened = try await second.host.request("queue.read", sessionID: view.id, params: ["turnId": .string(id)]).object ?? [:]
        XCTAssertEqual(reopened["text"]?.string, "Recovered queued rewrite", "The helper journal retained the replacement")
    }

    @MainActor func testDeliveredOrRemovedDuringEditKeepsEvenUnchangedText() async throws {
        let fixture = try await fixture()
        let id = try await fixture.queued(paused: true)
        fixture.session.draft = "Parked"
        try await fixture.edit(id)
        let editID = try XCTUnwrap(fixture.session.queueEditID)
        _ = try await fixture.host.request("queue.edit.cancel", sessionID: fixture.session.id, params: ["editId": .string(editID)])
        _ = try await fixture.host.request("queue.resume", sessionID: fixture.session.id)
        try await eventually("message left the queue", timeout: .seconds(60)) { !fixture.session.queue.contains { $0["turnId"]?.string == id } }
        fixture.pane.composer.send.performClick(nil)
        try await eventually("ended edit reconciled") { fixture.session.queueEditingID == nil }
        XCTAssertEqual(fixture.session.draft, "Queued original\n\nParked")
        XCTAssertTrue(fixture.session.notice.contains("not saved"))
        XCTAssertTrue(fixture.session.notice.contains("cancelled"))
        XCTAssertTrue(fixture.session.sendingRows.isEmpty)
    }

    @MainActor func testSideBannerAndKeyboardSaveTheirOwnQueueWithParentFocused() async throws {
        let parent = try await fixture()
        parent.model.openSide(parentID: parent.session.id)
        let info = try XCTUnwrap(parent.model.sides[parent.session.id])
        let view = try XCTUnwrap(parent.model.displays[info.id])
        let side = Fixture(model: parent.model, session: view, host: parent.host, chat: info.chat, setup: parent.setup)
        defer { side.window.contentView = nil; side.window.close() }
        let queued = try await side.queued(paused: true)
        let parentID = try await parent.queued(paused: true)
        parent.session.draft = "Parent draft"
        for banner in [true, false] {
            view.draft = "Side draft"
            try await side.edit(queued); try side.type("Side replacement \(banner)")
            parent.model.focusedSessionID = parent.session.id
            if banner {
                try XCTUnwrap(ConversationPaneTests.views(ComposerEditBanner.self, in: side.pane).first).save.performClick(nil)
            } else { side.key(.command, code: 76) }
            try await eventually("side Save confirmed") { view.queueEditingID == nil }
            XCTAssertEqual(view.draft, "Side draft"); XCTAssertEqual(parent.session.draft, "Parent draft")
            let result = try await parent.host.request("queue.read", sessionID: view.id, params: ["turnId": .string(queued)]).object ?? [:]
            XCTAssertEqual(result["text"]?.string, "Side replacement \(banner)")
            let unchanged = try await parent.host.request("queue.read", sessionID: parent.session.id, params: ["turnId": .string(parentID)]).object ?? [:]
            XCTAssertEqual(unchanged["text"]?.string, "Queued original")
        }
        try await parent.model.flushDrafts()
        let saved = try await parent.model.store?.get(DraftRecord.self, kind: "draft", id: view.id)
        XCTAssertEqual(saved?.text, "Side draft"); XCTAssertNil(saved?.queuedEdit)
    }

    @MainActor func testSubagentParentCanSaveWhileItsChildIsWorking() async throws {
        let fixture = try await fixture()
        let id = try await fixture.queued(paused: false, initial: "delegate opening fixture in background")
        try await eventually("child reached its generated gateway barrier", timeout: .seconds(60)) {
            FileManager.default.fileExists(atPath: fixture.setup.root.appendingPathComponent("child-streaming").path)
        }
        await fixture.model.reconcileSubagents(parentID: fixture.session.id)
        XCTAssertTrue(fixture.model.chats.contains { $0.isSubagent })
        fixture.session.draft = "Parent draft"
        try await fixture.edit(id); try fixture.type("Parent queue replacement")
        fixture.key(.command)
        try await eventually("parent Save confirmed") { fixture.session.queueEditingID == nil }
        XCTAssertEqual(fixture.session.draft, "Parent draft")
        let result = try await fixture.host.request("queue.read", sessionID: fixture.session.id, params: ["turnId": .string(id)]).object ?? [:]
        XCTAssertEqual(result["text"]?.string, "Parent queue replacement")
        try Data().write(to: fixture.setup.root.appendingPathComponent("release-child"))
    }

    @MainActor private func fixture(images: Bool = false) async throws -> Fixture {
        let setup = try await gatewayWorkspace("queue-edit-ui", projectID: "queue-edit-project", gatewayEnvironment: ["PI_APP_UI_FIXTURE_SLOW_WORDS": "400"])
        if images { _ = try await setup.vault.update(expectedRevision: 0) { $0.profiles[0].profile.advancedJSON = "{\"input\":[\"text\",\"image\"]}" } }
        let model = WorkspaceModel(stateRoot: setup.state, vault: setup.vault)
        try await model.reloadConfiguration()
        var chat = ChatRecord(id: "queue-chat", workspaceID: setup.workspace.id, title: "Queued editing", profileID: setup.profile.id)
        chat.titleWasEdited = true
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.select(chat.id)
        let session = try XCTUnwrap(model.selected)
        return try await mount(model, chat: chat, session: session, setup: setup)
    }

    @MainActor private func mount(_ model: WorkspaceModel, chat: ChatRecord, session: SessionDisplay, setup: GatewayWorkspace) async throws -> Fixture {
        let host = try await model.open(chat)
        let fixture = Fixture(model: model, session: session, host: host, chat: chat, setup: setup)
        addTeardownBlock { @MainActor in
            fixture.window.contentView = nil; fixture.window.close()
            await model.stopHostsAndWait(); model.shutdown()
            try? await model.traces.close(); await model.store?.close()
        }
        return fixture
    }

    @MainActor private final class Fixture {
        let setup: GatewayWorkspace
        let model: WorkspaceModel, session: SessionDisplay, host: HostSupervisor
        let window: NSWindow, pane: ConversationPaneView
        init(model: WorkspaceModel, session: SessionDisplay, host: HostSupervisor, chat: ChatRecord, setup: GatewayWorkspace) {
            self.setup = setup
            self.model = model; self.session = session; self.host = host
            pane = ConversationPaneView(model: model)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = pane
            pane.show(session: session, chat: chat, side: model.side(session.id)); window.makeKeyAndOrderFront(nil)
        }
        func edit(_ id: String) async throws {
            try await eventually("queue row's Edit action available") {
                self.pane.layoutSubtreeIfNeeded()
                return ConversationPaneTests.views(QueueRowView.self, in: self.pane).contains { $0.state?.item.id == id && $0.edit.isEnabled && !$0.edit.isHidden }
            }
            let row = try XCTUnwrap(ConversationPaneTests.views(QueueRowView.self, in: pane).first { $0.state?.item.id == id })
            XCTAssertTrue(row.edit.isEnabled); row.edit.performClick(nil)
            try await eventually("queue edit opened", timeout: .seconds(60)) { self.session.queueEditingID == id }
            pane.composer.refresh(); pane.layoutSubtreeIfNeeded()
            XCTAssertNotNil(ConversationPaneTests.views(ComposerEditBanner.self, in: pane).first)
        }
        func type(_ text: String) throws {
            let editor = try XCTUnwrap(pane.composer.field?.documentView as? ComposerTextView)
            XCTAssertTrue(window.makeFirstResponder(editor))
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            XCTAssertEqual(session.draft, text)
        }
        func key(_ modifiers: NSEvent.ModifierFlags = [], code: UInt16 = 36) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code)!
            if window.performKeyEquivalent(with: event) { return }
            if !modifiers.isEmpty, NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
            window.sendEvent(event)
        }
        func queued(paused: Bool, steer: Bool = false, initial: String = "slow initial request") async throws -> String {
            session.draft = initial; model.send(sessionID: session.id)
            try await eventually("initial submission settled", timeout: .seconds(60)) { !self.session.loading }
            XCTAssertNil(session.sendFailure)
            do {
                try await eventually("run admitted", timeout: .seconds(10)) { self.session.busy }
            } catch {
                let status = try await host.request("session.status", sessionID: session.id).object ?? [:]
                if let attempt = status["latestAttempt"]?.object?["attemptId"]?.string,
                   let bytes = try? await model.traces.body(attemptID: attempt, body: "response", offset: 0) {
                    print("QUEUE FIXTURE RESPONSE: \(String(decoding: bytes.prefix(2_048), as: UTF8.self))")
                }
                throw error
            }
            session.draft = "Queued original"; model.send(steer: steer, sessionID: session.id)
            try await eventually("queue admitted", timeout: .seconds(60)) { !self.session.loading && self.session.queue.count == 1 }
            let id = try XCTUnwrap(session.queue.first?["turnId"]?.string)
            if paused {
                model.stop(sessionID: session.id)
                try await eventually("queue paused", timeout: .seconds(60)) { !self.session.busy && self.session.queuePaused }
            }
            return id
        }
    }
}
