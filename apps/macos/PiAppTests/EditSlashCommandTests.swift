import XCTest
import AppKit
@testable import PiApp

/// Edit commands use the mounted composer's list, keys, banner and menu entry.
final class EditSlashCommandTests: XCTestCase {
    @MainActor private func fixture(queued: Bool, width: CGFloat = 920) async throws -> ConversationPaneTests.Pane {
        let pane = try ConversationPaneTests.Pane(messages: [TranscriptMessage(id: "u1", role: "user", text: "Original question")], width: width, height: 600)
        pane.model.prewarmsHelpers = false
        try await pane.model.reloadConfiguration()
        pane.session.selectionMetadataLoaded = true
        pane.session.draft = "Parked draft"
        if queued {
            pane.session.queue = [["turnId": .string("q1"), "text": .string("Queued question"), "kind": .string("follow-up")]]
            pane.session.queueCount = 1
            await pane.settle()
            let row = try XCTUnwrap(ConversationPaneTests.views(QueueRowView.self, in: pane.hosted).first)
            row.edit.performClick(nil)
            try await eventually("queued edit opens") { pane.session.queueEditingID == "q1" }
        } else {
            pane.model.editTargetRead = { _, _ in ["messageId": .string("u1"), "text": .string("Original question"), "legacyInputs": .bool(false)] }
            pane.model.editMessage("u1", sessionID: pane.session.id)
            try await eventually("earlier edit loads") { pane.session.editingMessageID == "u1" && !pane.session.editPreparing }
        }
        let skill = SkillDescriptor(id: "review", name: "review", path: "/generated/review/SKILL.md", description: "Review the edited question", scope: "project",
                                    contentHash: "content", metadataHash: "metadata", policy: "explicitOnly", reasons: [], missingDependencies: [])
        pane.session.skillCatalog = SkillCatalog(state: .ready, scope: pane.model.skillScope(sessionID: pane.session.id, workspaceID: pane.chat.workspaceID), revision: "fixture", entries: [SkillSearch.Entry(skill)])
        await pane.settle()
        return pane
    }

    @MainActor private func type(_ text: String, in pane: ConversationPaneTests.Pane) async throws {
        let editor = try XCTUnwrap(pane.editor)
        XCTAssertTrue(pane.window.makeFirstResponder(editor))
        editor.insertText("", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        if text.hasPrefix("/") {
            let slash = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: pane.window.windowNumber,
                                                    context: nil, characters: "/", charactersIgnoringModifiers: "/", isARepeat: false, keyCode: 44))
            editor.keyDown(with: slash)
            editor.insertText(String(text.dropFirst()), replacementRange: editor.selectedRange())
        } else { editor.insertText(text, replacementRange: editor.selectedRange()) }
        await pane.settle()
        await pane.session.completionParse?.value
    }
    @MainActor private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], in pane: ConversationPaneTests.Pane) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: pane.window.windowNumber,
                                                context: nil, characters: code == 48 ? "\t" : "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code))
        if !pane.window.performKeyEquivalent(with: event) { pane.editor?.keyDown(with: event) }
    }

    @MainActor func testSkillsCanBeChosenWithReturnTabAndListClickInBothEdits() async throws {
        for queued in [true, false] {
            for code: UInt16 in [36, 48, 0] {
                let pane = try await fixture(queued: queued)
                defer { pane.close() }
                try await type("Please use /rev", in: pane)
                XCTAssertTrue(pane.session.completionVisible, "The slash list opens during an edit")
                let row = try XCTUnwrap(ConversationPaneTests.views(SlashCompletionRowView.self, in: pane.hosted).first { $0.choice.skill?.id == "review" })
                pane.editor?.undoManager?.removeAllActions()
                if code == 0 { row.performClick(nil) } else { try key(code, in: pane) }
                XCTAssertEqual(pane.session.skills.map(\.id), ["review"])
                XCTAssertEqual(pane.session.draft, "Please use ")
                XCTAssertFalse(pane.session.loading); XCTAssertFalse(pane.session.queueEditResolving)
                XCTAssertEqual(pane.session.queueEditingID, queued ? "q1" : nil)
                XCTAssertEqual(pane.session.editingMessageID, queued ? nil : "u1")
                pane.editor?.undoManager?.undo()
                XCTAssertEqual(pane.session.draft, "Please use /rev"); XCTAssertTrue(pane.session.skills.isEmpty)
                pane.editor?.undoManager?.redo()
                XCTAssertEqual(pane.session.skills.map(\.id), ["review"])
            }
        }
    }

    @MainActor func testBranchAndCompactCommandsRefuseThroughListKeysMenuAndBanner() async throws {
        for queued in [true, false] {
            for command in ["side", "fork", "compact"] {
                let pane = try await fixture(queued: queued)
                defer { pane.close() }
                for path in ["return", "list", "menu", "banner"] {
                    try await type("/" + command, in: pane)
                    pane.session.editNotice = ""; pane.session.queueEditNotice = ""; pane.session.notice = ""
                    switch path {
                    case "return": try key(36, in: pane)
                    case "list":
                        let row = try XCTUnwrap(ConversationPaneTests.views(SlashCompletionRowView.self, in: pane.hosted).first { $0.choice.name == command })
                        row.performClick(nil)
                    case "menu": pane.model.submitFocusedComposer(intent: .steer, in: pane.window)
                    default:
                        if queued {
                            let banner = try XCTUnwrap(ConversationPaneTests.views(ComposerEditBanner.self, in: pane.hosted).first)
                            banner.save.performClick(nil)
                        } else { try XCTUnwrap(ConversationPaneTests.views(ComposerInputView.self, in: pane.hosted).first).send.performClick(nil) }
                    }
                    let notice = queued ? pane.session.queueEditNotice : pane.session.editNotice
                    XCTAssertTrue(notice.contains("/" + command), "\(command) via \(path): a composer notice explains the refusal")
                    XCTAssertEqual(pane.session.draft, "/" + command)
                    XCTAssertFalse(pane.session.loading); XCTAssertFalse(pane.session.queueEditResolving)
                    XCTAssertNil(pane.model.sides[pane.session.id])
                    XCTAssertEqual(pane.session.queueEditingID, queued ? "q1" : nil)
                    XCTAssertEqual(pane.session.editingMessageID, queued ? nil : "u1")
                }
            }
        }
    }

    @MainActor func testCommandReturnDoesNotAuthorizeAnUnselectedSkillInEitherEdit() async throws {
        for queued in [true, false] {
            let pane = try await fixture(queued: queued)
            defer { pane.close() }
            try await type("/review", in: pane)
            try key(36, flags: .command, in: pane)
            XCTAssertTrue(pane.session.skills.isEmpty); XCTAssertFalse(pane.session.loading); XCTAssertFalse(pane.session.queueEditResolving)
            XCTAssertTrue(pane.session.notice.contains("Select"))
            XCTAssertEqual(pane.session.draft, "/review")
        }
    }

    @MainActor func testDebugOpensTheInspectorAndKeepsBothEdits() async throws {
        for queued in [true, false] {
            let pane = try await fixture(queued: queued)
            defer { pane.close() }
            defer { SessionInspectorWindows.shared.closeAll() }
            try await type("/debug", in: pane)
            pane.model.submitFocusedComposer(intent: .steer, in: pane.window)
            XCTAssertEqual(pane.model.lastInspectorFocus, .latestRequest)
            XCTAssertEqual(pane.session.draft, "/debug")
            XCTAssertTrue((queued ? pane.session.queueEditNotice : pane.session.editNotice).contains("/debug"))
            XCTAssertFalse(pane.session.loading); XCTAssertFalse(pane.session.queueEditResolving)
            pane.model.lastInspectorFocus = nil
            try await type("/debug extra", in: pane)
            pane.session.editNotice = ""; pane.session.queueEditNotice = ""
            pane.model.submitFocusedComposer(intent: .steer, in: pane.window)
            XCTAssertNil(pane.model.lastInspectorFocus)
            XCTAssertTrue((queued ? pane.session.queueEditNotice : pane.session.editNotice).contains("takes no arguments"))
            XCTAssertEqual(pane.session.draft, "/debug extra")
        }
    }
    @MainActor func testLeadingSkillCommandsResolveArgumentsBeforeEitherEditSubmits() async throws {
        for queued in [true, false] {
            let pane = try await fixture(queued: queued)
            defer { pane.close() }
            try await type("/review check the revised tests", in: pane)
            pane.model.submitFocusedComposer(intent: .followUp, in: pane.window)
            XCTAssertEqual(pane.session.skills.first?.id, "review")
            XCTAssertEqual(pane.session.skills.first?.arguments, "check the revised tests")
            XCTAssertEqual(pane.session.skills.first?.intent, "leading-command")
            XCTAssertEqual(pane.session.draft, "")
            XCTAssertTrue(queued ? pane.session.queueEditResolving : pane.session.editSubmitting)
        }
    }

    @MainActor func testAnArgumentDialogCannotChangeSkillsAfterAQueuedSaveStarts() async throws {
        let pane = try await fixture(queued: true)
        defer { pane.close() }
        try await type("Use /rev", in: pane); try key(48, in: pane)
        let chip = try XCTUnwrap(pane.session.skills.first)
        pane.model.questions.enterText = { _, _ in
            pane.model.saveQueuedEdit(sessionID: pane.session.id)
            return "late arguments"
        }
        pane.model.editSkillArguments(chip, view: pane.session)
        XCTAssertTrue(pane.session.queueEditResolving)
        XCTAssertEqual(pane.session.skills.first?.arguments, "")
        try await eventually("original selection saved") { pane.session.queueEditingID == nil }
        XCTAssertEqual(pane.edits.skills["q1"]?.first?.arguments, "")
    }

    @MainActor func testAnOpenSkillPopoverCannotRemoveTheCapturedSelectionWhileSaving() async throws {
        let pane = try await fixture(queued: true)
        defer { SkillPopovers.shared.close(); pane.close() }
        try await type("Use /rev", in: pane); try key(48, in: pane)
        await pane.settle()
        let token = try XCTUnwrap(pane.editor?.skillTokenViews.first)
        token.performClick(nil)
        try await eventually("skill popover opens") { SkillPopovers.shared.presented != nil }
        let remove = try XCTUnwrap(SkillPopovers.shared.presented?.actions.remove)
        let gate = AsyncGate(); pane.edits.gates["queue.edit.save"] = gate
        pane.model.saveQueuedEdit(sessionID: pane.session.id)
        try await eventually("Save waits") { pane.edits.count("queue.edit.save") == 1 }
        remove()
        XCTAssertEqual(pane.session.skills.map(\.id), ["review"])
        await gate.open()
        try await eventually("captured input saved") { pane.session.queueEditingID == nil }
        XCTAssertEqual(pane.edits.skills["q1"]?.map(\.id), ["review"])
    }

    @MainActor func testQueuedSkillsSurviveLostRepliesAndReconcileByTheWholeSavedInput() async throws {
        for changed in [false, true] {
            let pane = try await fixture(queued: true)
            defer { pane.close() }
            try await type("Use /rev", in: pane)
            try key(48, in: pane)
            pane.session.skills[0].arguments = "saved arguments"
            pane.edits.lostReplies.insert("queue.edit.save"); pane.edits.unansweredStatuses = 3
            pane.model.saveQueuedEdit(sessionID: pane.session.id)
            try await eventually("unanswered Save stays recoverable") { !pane.session.queueEditResolving && pane.session.queueEditPendingOperation == "save" }
            var record = try XCTUnwrap(pane.session.savedDraft.queuedEdit)
            XCTAssertEqual(record.skills?.first?.arguments, "saved arguments")
            XCTAssertEqual(record.sentDigest, QueuedEditDraft.digest("Use ", skills: record.skills))
            if changed { record.skills?[0].arguments = "newer arguments" }
            let baseline = pane.session.savedDraft
            try await pane.model.flushDrafts()
            let reopened = SessionDisplay(id: pane.session.id)
            reopened.restoreDraft(baseline); reopened.draftVersion = pane.session.draftVersion
            reopened.selectionMetadataLoaded = true
            pane.model.displays[reopened.id] = reopened
            await pane.model.reconcileQueuedEdit(reopened, record)
            XCTAssertNil(reopened.queueEditingID); XCTAssertNil(reopened.unreconciledQueuedEdit)
            XCTAssertEqual(reopened.draft, changed ? "Use \n\nParked draft" : "Parked draft")
            XCTAssertEqual(reopened.skills.first?.arguments, changed ? "newer arguments" : nil)
            try await pane.model.flushDrafts()
        }
    }

    @MainActor func testConflictingSkillArgumentsKeepTheUnsavedRewriteAsASeparateDraft() async throws {
        let pane = try await fixture(queued: true)
        defer { pane.close() }
        try await type("Use /rev", in: pane); try key(48, in: pane)
        let rewrite = try XCTUnwrap(pane.session.skills.first)
        var parked = rewrite; parked.arguments = "parked arguments"
        pane.session.draftBeforeQueueEdit?.skills = [parked]
        let editID = try XCTUnwrap(pane.session.queueEditID)
        _ = try await pane.model.queueEditRequest("queue.edit.remove", sessionID: pane.session.id, params: ["editId": .string(editID)])
        pane.model.saveQueuedEdit(sessionID: pane.session.id)
        try await eventually("ended edit keeps rewrite separately") { pane.session.queueEditingID == nil && !pane.session.draftConflicts.isEmpty }
        XCTAssertEqual(pane.session.skills, [parked])
        XCTAssertEqual(pane.session.draftConflicts.first?.draft.skills, [rewrite])
        // Exercise the normal debounce: Quit's flush already preserves the
        // separate copy first and would hide a false competing-instance error.
        await pane.settle()
        while let write = pane.model.draftWrites.tasks[pane.session.id] { await write.value }
        XCTAssertNil(pane.model.error)
        XCTAssertFalse(pane.model.draftWrites.failed)
        XCTAssertFalse(pane.session.draftVersion.hasConflictEpisode)
        let reader = MetadataStore(url: pane.model.root.appendingPathComponent("desktop.sqlite"))
        let saved = try await reader.get(DraftRecord.self, kind: "draft", id: pane.session.id)
        let copies = try await reader.draftConflicts(id: pane.session.id)
        await reader.close()
        XCTAssertEqual(saved?.text, "Parked draft")
        XCTAssertEqual(saved?.skills, [parked])
        XCTAssertNil(saved?.queuedEdit)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(copies.first?.draft.text, "Use ")
        XCTAssertEqual(copies.first?.draft.skills, [rewrite])
        XCTAssertFalse(pane.session.draftVersion.hasUnsavedConflict)
    }

    @MainActor func testNewerArgumentsAfterSaveKeepBothDraftsAndExplainWhereTheRewriteIs() async throws {
        let pane = try await fixture(queued: true)
        defer { pane.close() }
        try await type("Use /rev", in: pane); try key(48, in: pane)
        var parked = try XCTUnwrap(pane.session.skills.first); parked.arguments = "parked arguments"
        pane.session.draftBeforeQueueEdit?.skills = [parked]
        let gate = AsyncGate(); pane.edits.gates["queue.edit.save"] = gate
        pane.model.saveQueuedEdit(sessionID: pane.session.id)
        try await eventually("Save waits on its reply") { pane.edits.count("queue.edit.save") == 1 }
        pane.session.skills[0].arguments = "newer arguments"
        await gate.open()
        try await eventually("Save closes after its own reply") { pane.session.queueEditingID == nil }
        XCTAssertEqual(pane.session.skills, [parked])
        XCTAssertEqual(pane.session.draftConflicts.first?.draft.skills?.first?.arguments, "newer arguments")
        XCTAssertTrue(pane.session.queueEditNotice.contains("separate draft"), pane.session.queueEditNotice)
    }

    @MainActor func testAnIncompleteQueuedSkillReplyKeepsTheHoldAndTheParkedDraft() async throws {
        let pane = try await fixture(queued: false)
        defer { pane.close() }
        pane.model.cancelEdit(sessionID: pane.session.id)
        pane.model.queueEditOperation = { _, _, params in
            ["text": .string("Queued input"), "skillCount": .number(1), "skills": .array([]), "revision": .number(1),
             "held": .object(["editId": params["editId"] ?? .null, "turnId": .string("q1"), "kind": .string("follow-up"), "sequence": .number(1)])]
        }
        pane.model.editQueued("q1", sessionID: pane.session.id)
        try await eventually("incomplete selections refuse opening") { pane.session.queueEditNotice.contains("skills could not be read") }
        XCTAssertNil(pane.session.queueEditingID)
        XCTAssertEqual(pane.session.queueEditHold?.turnID, "q1")
        XCTAssertEqual(pane.session.draft, "Parked draft")
        XCTAssertTrue(pane.session.skills.isEmpty)
        XCTAssertEqual(pane.session.savedDraft.queuedEdit?.beginOnly, true)
    }

    @MainActor func testSlashListsInBothEditsGallery() async throws {
        guard let folder = testEnvironment("PI_APP_EDIT_SLASH_GALLERY").map(URL.init(fileURLWithPath:)) else { throw XCTSkip("Set PI_APP_EDIT_SLASH_GALLERY for captures") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for queued in [true, false] {
            for width: CGFloat in [920, 420] {
                for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                    let pane = try await fixture(queued: queued, width: width)
                    defer { pane.close() }
                    pane.window.appearance = NSAppearance(named: appearance)
                    try await type("/", in: pane)
                    await pane.settle(12)
                    XCTAssertTrue(pane.session.completionVisible)
                    let list = try XCTUnwrap(ConversationPaneTests.views(SlashCompletionListView.self, in: pane.hosted).first { !$0.isHidden })
                    let banner = try XCTUnwrap(ConversationPaneTests.views(ComposerEditBanner.self, in: pane.hosted).first)
                    XCTAssertFalse(list.convert(list.bounds, to: nil).intersects(banner.convert(banner.bounds, to: nil)))
                    XCTAssertEqual(pane.model.completions(pane.session).count, 5)
                    let content = try XCTUnwrap(pane.window.contentView)
                    let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    let name = "\(queued ? "queued" : "earlier")-\(Int(width))-\(suffix).png"
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name))
                }
            }
        }
    }

}
