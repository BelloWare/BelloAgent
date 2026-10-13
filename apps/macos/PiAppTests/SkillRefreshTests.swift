import XCTest
import AppKit
@testable import PiApp

/// A skill chosen in the composer that changes before the message goes. The
/// helper refuses it (only an explicit selection activates a skill, pinned to
/// what the reader chose); the app reads the skill list again, pins the chip
/// to the current version (or takes it off if the skill is gone), says so,
/// and sends nothing. The reader's next Send is the confirmation. Against
/// the packaged helper and the synthetic gateway, with skills written into
/// the test's own project folder.
final class SkillRefreshTests: XCTestCase {
    private struct Fixture {
        let setup: GatewayWorkspace, model: WorkspaceModel, chat: ChatRecord, view: SessionDisplay
        var skills: URL { URL(fileURLWithPath: setup.workspace.path).appendingPathComponent(".agents/skills") }
    }

    private static let text = "Summarise the release notes"

    private func writeSkill(_ root: URL, _ name: String, description: String, body: String) throws {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try Data("---\nname: \(name)\ndescription: \(description)\n---\n\(body)\n".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        try Data("policy:\n  allow_implicit_invocation: false\n".utf8).write(to: folder.appendingPathComponent("agents/openai.yaml"))
    }

    @MainActor private func fixture(_ name: String, gateway: [String: String] = [:]) async throws -> Fixture {
        let setup = try await gatewayWorkspace(name, projectID: name + "-project", gatewayEnvironment: gateway)
        let model = makeWorkspaceModel(stateRoot: setup.state, vault: setup.vault)
        await model.restore()
        model.selectedWorkspaceID = setup.workspace.id; model.profileChoice = setup.profile.id
        let chat = ChatRecord(id: "chat-" + UUID().uuidString, workspaceID: setup.workspace.id, title: "Skills", path: nil, profileID: setup.profile.id)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        await model.select(chat.id)
        let f = Fixture(setup: setup, model: model, chat: chat, view: try XCTUnwrap(model.displays[chat.id]))
        try writeSkill(f.skills, "review-notes", description: "Review the notes", body: "ORIGINAL_NOTES_BODY")
        try writeSkill(f.skills, "style-guide", description: "Follow the style guide", body: "STYLE_GUIDE_BODY")
        return f
    }

    /// Chooses the skill as the slash list does: from a fresh catalog.
    @MainActor private func choose(_ name: String, in view: SessionDisplay, _ model: WorkspaceModel) async throws {
        await model.loadSkillCatalog(refresh: true, sessionID: view.id)
        let skill = try XCTUnwrap(view.skillCatalog.entries.map(\.skill).first { $0.name == name }, view.skillCatalog.notice)
        XCTAssertTrue(model.addSkill(skill, view: view))
    }

    @MainActor private func current(_ name: String, in view: SessionDisplay) -> SkillDescriptor? {
        view.skillCatalog.entries.map(\.skill).first { $0.name == name }
    }

    @MainActor private func waitFor(_ what: String, seconds: Double = 60, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(what, file: file, line: line)
    }

    @MainActor private func quiet(_ view: SessionDisplay) -> Bool {
        !view.hasWork && !view.loading && view.messages.last?.role == "assistant" && view.messages.last?.isStreaming == false
    }

    @MainActor private func refused(_ view: SessionDisplay) -> Bool {
        view.sendFailureCode == SessionDisplay.skillRefreshedCode && !view.loading
    }

    @MainActor private func userRows(_ view: SessionDisplay) -> Int { view.messages.filter { $0.role == "user" }.count }

    /// The reported case: the skill file is edited after it was chosen. The
    /// chip is pinned to the new version with a notice, nothing is sent, the
    /// draft and the other chip stay, and the next Send uses the new version.
    @MainActor func testAnEditedSkillIsPinnedAgainAndTheNextSendUsesIt() async throws {
        let f = try await fixture("skill-refresh-edited")
        try await choose("review-notes", in: f.view, f.model); try await choose("style-guide", in: f.view, f.model)
        let style = f.view.skills[1]
        f.view.draft = Self.text
        try writeSkill(f.skills, "review-notes", description: "Review the notes", body: "UPDATED_NOTES_BODY")
        f.model.send(sessionID: f.chat.id)
        await waitFor("The refused send never came back with a notice: \(f.view.sendFailure ?? "")") { refused(f.view) }
        XCTAssertEqual(f.view.sendFailure, "\u{201C}review-notes\u{201D} changed since you chose it. Press Send to use the updated version.")
        XCTAssertEqual(f.view.draft, Self.text, "The text is untouched")
        XCTAssertEqual(f.view.skills.map(\.name), ["review-notes", "style-guide"], "Both chips stay, in order")
        XCTAssertEqual(f.view.skills[1], style, "The other chip is untouched")
        let fresh = try XCTUnwrap(current("review-notes", in: f.view))
        XCTAssertEqual(f.view.skills[0].contentHash, fresh.contentHash, "The chip holds the current version")
        XCTAssertEqual(f.view.skills[0].metadataHash, fresh.metadataHash)
        XCTAssertEqual(userRows(f.view), 0, "Nothing was sent")
        let notice = try XCTUnwrap(f.view.presentedMessages.last)
        XCTAssertEqual(notice.failureCode, SessionDisplay.skillRefreshedCode, "The conversation shows the notice")
        try? await Task.sleep(for: .milliseconds(300))
        let saved = try await f.model.store?.get(DraftRecord.self, kind: "draft", id: f.chat.id)
        XCTAssertEqual(saved?.skills?.first?.contentHash, fresh.contentHash, "The re-pinned chip is what the draft saves")

        f.model.send(sessionID: f.chat.id)
        await waitFor("The confirmed send never finished") { quiet(f.view) }
        XCTAssertNil(f.view.sendFailure)
        let reply = f.view.messages.last { $0.role == "assistant" }?.text ?? ""
        XCTAssertTrue(reply.contains("UPDATED_NOTES_BODY"), "The updated version was sent")
        XCTAssertFalse(reply.contains("ORIGINAL_NOTES_BODY"), "The old version never was")
        XCTAssertTrue(reply.contains("STYLE_GUIDE_BODY"))
        XCTAssertEqual(userRows(f.view), 1)
    }

    /// A skill deleted after it was chosen: its chip goes, with a notice;
    /// the rest of the message stays, and Send sends it.
    @MainActor func testADeletedSkillIsTakenOffWithANotice() async throws {
        let f = try await fixture("skill-refresh-deleted")
        try await choose("review-notes", in: f.view, f.model); try await choose("style-guide", in: f.view, f.model)
        f.view.draft = Self.text
        try FileManager.default.removeItem(at: f.skills.appendingPathComponent("review-notes"))
        f.model.send(sessionID: f.chat.id)
        await waitFor("The refused send never came back with a notice: \(f.view.sendFailure ?? "")") { refused(f.view) }
        XCTAssertEqual(f.view.sendFailure, "\u{201C}review-notes\u{201D} is no longer available, so it was removed from your message. Press Send to send the rest of it.")
        XCTAssertEqual(f.view.skills.map(\.name), ["style-guide"])
        XCTAssertEqual(f.view.draft, Self.text)
        XCTAssertEqual(userRows(f.view), 0, "Nothing was sent")
        f.model.send(sessionID: f.chat.id)
        await waitFor("The confirmed send never finished") { quiet(f.view) }
        let reply = f.view.messages.last { $0.role == "assistant" }?.text ?? ""
        XCTAssertTrue(reply.contains("STYLE_GUIDE_BODY")); XCTAssertFalse(reply.contains("ORIGINAL_NOTES_BODY"))
    }

    /// A skill typed as `/name request` keeps the request in its chip. When
    /// the skill is gone the request comes back as the draft's text, not lost
    /// with the chip.
    @MainActor func testAGoneCommandsRequestComesBackAsText() async throws {
        let f = try await fixture("skill-refresh-command")
        await f.model.loadSkillCatalog(refresh: true, sessionID: f.view.id)
        let skill = try XCTUnwrap(current("review-notes", in: f.view))
        f.view.directCommand = true; f.view.draft = "/review-notes check the dates"
        XCTAssertTrue(f.model.addSkill(skill, view: f.view, fromCommand: true))
        XCTAssertEqual(f.view.draft, ""); XCTAssertEqual(f.view.skills.first?.arguments, "check the dates")
        try FileManager.default.removeItem(at: f.skills.appendingPathComponent("review-notes"))
        f.model.send(sessionID: f.chat.id)
        await waitFor("The refused send never came back with a notice: \(f.view.sendFailure ?? "")") { refused(f.view) }
        XCTAssertTrue(f.view.skills.isEmpty)
        XCTAssertEqual(f.view.draft, "check the dates", "What was written for the skill is kept")
        XCTAssertEqual(f.view.sendFailure, "\u{201C}review-notes\u{201D} is no longer available, so it was removed from your message; what you wrote for it is kept in the text. Press Send to send the rest of it.")
    }

    /// A skill missing from a list that could not be read completely is not
    /// taken off: nothing changes, and the notice says the list could not be read.
    @MainActor func testAnIncompleteListTakesNothingOff() async throws {
        let f = try await fixture("skill-refresh-incomplete")
        try await choose("review-notes", in: f.view, f.model)
        let chosen = f.view.skills
        f.view.draft = Self.text
        let broken = f.skills.appendingPathComponent("a-broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data([0x2d, 0x2d, 0x2d, 0x0a, 0xff, 0xfe, 0x0a]).write(to: broken.appendingPathComponent("SKILL.md"))
        try writeSkill(f.skills, "review-notes", description: "Review the notes", body: "UPDATED_NOTES_BODY")
        f.model.send(sessionID: f.chat.id)
        await waitFor("The refused send never came back with a notice") { !f.view.loading && f.view.sendFailure != nil }
        XCTAssertEqual(f.view.skills, chosen, "The chip is kept as it was")
        XCTAssertTrue(f.view.sendFailure?.hasPrefix("A selected skill changed, and the skill list could not be read again") == true, f.view.sendFailure ?? "")
        XCTAssertNotEqual(f.view.sendFailureCode, SessionDisplay.skillRefreshedCode)
        XCTAssertEqual(userRows(f.view), 0)
    }

    /// The notice shows even below a run failure the chat still shows: the
    /// reader sees what changed before the Send that confirms it.
    @MainActor func testTheNoticeShowsBelowAnEarlierRunFailure() {
        let view = SessionDisplay(id: "notice")
        view.observeRunState(["state": .string("error"), "runStatus": .string("failed"), "preflightError": .string("The gateway closed the connection.")])
        view.sendFailure = "\u{201C}a\u{201D} changed since you chose it. Press Send to use the updated version."
        view.sendFailureCode = SessionDisplay.skillRefreshedCode
        let rows = view.presentedMessages.filter { $0.kind == "failure" }
        XCTAssertEqual(rows.map(\.id), ["failure:run:notice", "failure:send:notice"])
        XCTAssertEqual(rows.last?.failureCode, SessionDisplay.skillRefreshedCode)
    }

    /// A skill that changes again after its chip was pinned again says it is
    /// changing; it is pinned once more and nothing is sent, and once it
    /// settles Send sends the latest version.
    @MainActor func testASkillThatKeepsChangingSaysSoAndNeverLoops() async throws {
        let f = try await fixture("skill-refresh-changing")
        try await choose("review-notes", in: f.view, f.model)
        f.view.draft = Self.text
        try writeSkill(f.skills, "review-notes", description: "Review the notes", body: "SECOND_NOTES_BODY")
        f.model.send(sessionID: f.chat.id)
        await waitFor("The first refusal never came back") { refused(f.view) }
        try writeSkill(f.skills, "review-notes", description: "Review the notes", body: "THIRD_NOTES_BODY")
        f.model.send(sessionID: f.chat.id)
        await waitFor("The second refusal never came back") { refused(f.view) && f.view.sendFailure?.contains("again") == true }
        XCTAssertEqual(f.view.sendFailure, "\u{201C}review-notes\u{201D} changed again while it was being sent, so it seems to be changing right now. Wait until the skill file stops changing, then press Send.")
        XCTAssertEqual(f.view.skills.first?.contentHash, current("review-notes", in: f.view)?.contentHash, "The chip holds the latest version")
        XCTAssertEqual(userRows(f.view), 0, "Nothing was sent, and nothing was sent again on its own")
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(userRows(f.view), 0); XCTAssertFalse(f.view.loading)
        f.model.send(sessionID: f.chat.id)
        await waitFor("The confirmed send never finished") { quiet(f.view) }
        let reply = f.view.messages.last { $0.role == "assistant" }?.text ?? ""
        XCTAssertTrue(reply.contains("THIRD_NOTES_BODY")); XCTAssertFalse(reply.contains("SECOND_NOTES_BODY"))
    }

    /// An unchanged skill goes on the first Send, as always.
    @MainActor func testAnUnchangedSkillSendsFirstTime() async throws {
        let f = try await fixture("skill-refresh-unchanged")
        try await choose("review-notes", in: f.view, f.model)
        f.view.draft = Self.text
        f.model.send(sessionID: f.chat.id)
        await waitFor("The send never finished") { quiet(f.view) }
        XCTAssertNil(f.view.sendFailure)
        XCTAssertTrue(f.view.skills.isEmpty)
        XCTAssertTrue((f.view.messages.last { $0.role == "assistant" }?.text ?? "").contains("ORIGINAL_NOTES_BODY"))
    }

    /// A follow-up queued behind a running turn whose skill changes before it
    /// goes: the queue pauses on a notice with Resume, nothing is sent on its
    /// own, and Resume sends the updated version.
    @MainActor func testAQueuedFollowUpWithAChangedSkillWaitsForResume() async throws {
        let f = try await fixture("skill-refresh-queued", gateway: ["PI_APP_UI_FIXTURE_SLOW_WORDS": "16"])
        f.view.draft = "A slow first question"
        f.model.send(sessionID: f.chat.id)
        await waitFor("The slow turn never started") { f.view.busy && !f.view.loading }
        try await choose("review-notes", in: f.view, f.model)
        f.view.draft = Self.text
        f.model.send(sessionID: f.chat.id)
        await waitFor("The follow-up was never queued") { !f.view.loading && f.view.queueCount == 1 }
        // The description is the metadata a queued selection is checked against.
        try writeSkill(f.skills, "review-notes", description: "Review the notes, revised", body: "UPDATED_NOTES_BODY")
        await waitFor("The queue never paused on the notice: \(f.view.failureMessage ?? "")") { f.view.failureCode == SessionDisplay.skillUpdatedCode && !f.view.busy }
        XCTAssertEqual(f.view.failureMessage, "\u{201C}review-notes\u{201D} changed after this message was queued. The message now uses the updated version. Press Resume to send it.")
        XCTAssertTrue(f.view.queuePaused); XCTAssertEqual(f.view.queueCount, 1)
        XCTAssertEqual(userRows(f.view), 1, "The follow-up was not sent")
        let notice = try XCTUnwrap(f.view.presentedMessages.last)
        XCTAssertEqual(notice.failureCode, SessionDisplay.skillUpdatedCode); XCTAssertNil(notice.detail)
        f.model.action("queue.resume", sessionID: f.chat.id)
        await waitFor("Resume never sent the follow-up") { userRows(f.view) == 2 && quiet(f.view) }
        let reply = f.view.messages.last { $0.role == "assistant" }?.text ?? ""
        XCTAssertTrue(reply.contains("UPDATED_NOTES_BODY")); XCTAssertFalse(reply.contains("ORIGINAL_NOTES_BODY"))
        XCTAssertNil(f.view.failureMessage)
    }

    /// An edit of an earlier message stays in the composer when its skill
    /// changed: the chip is pinned again, the banner says so, and the next
    /// Send makes the edit with the updated version.
    @MainActor func testAnEditWithAChangedSkillIsPinnedAgainInTheComposer() async throws {
        let f = try await fixture("skill-refresh-edit")
        f.view.draft = "First question"
        f.model.send(sessionID: f.chat.id)
        await waitFor("The first turn never finished") { quiet(f.view) }
        let question = try XCTUnwrap(f.view.messages.first { $0.role == "user" }?.id)
        f.model.editMessage(question, sessionID: f.chat.id)
        await waitFor("The edit never opened") { !f.view.editPreparing && f.view.editingMessageID == question }
        try await choose("review-notes", in: f.view, f.model)
        f.view.draft = "Edited question"
        try writeSkill(f.skills, "review-notes", description: "Review the notes", body: "UPDATED_NOTES_BODY")
        f.model.sendEdit(sessionID: f.chat.id)
        await waitFor("The refused edit never came back: \(f.view.editNotice)") { !f.view.editSubmitting && f.view.editNotice.contains("Press Send") }
        XCTAssertEqual(f.view.editNotice, "\u{201C}review-notes\u{201D} changed since you chose it. Press Send to use the updated version.")
        XCTAssertEqual(f.view.editingMessageID, question, "The edit is still open")
        XCTAssertEqual(f.view.draft, "Edited question")
        XCTAssertEqual(f.view.skills.first?.contentHash, current("review-notes", in: f.view)?.contentHash)
        XCTAssertEqual(userRows(f.view), 1, "Nothing was sent")
        f.model.sendEdit(sessionID: f.chat.id)
        await waitFor("The confirmed edit never finished") { f.view.editingMessageID == nil && quiet(f.view) && (f.view.messages.last { $0.role == "assistant" }?.text.contains("Edited question") ?? false) }
        let reply = f.view.messages.last { $0.role == "assistant" }?.text ?? ""
        XCTAssertTrue(reply.contains("UPDATED_NOTES_BODY")); XCTAssertFalse(reply.contains("ORIGINAL_NOTES_BODY"))
    }

    /// A side chat's composer is put right the same way.
    @MainActor func testASideWithAChangedSkillIsPinnedAgain() async throws {
        let f = try await fixture("skill-refresh-side")
        f.model.openSide(parentID: f.chat.id)
        let info = try XCTUnwrap(f.model.sides[f.chat.id], f.model.error ?? "")
        let side = try XCTUnwrap(f.model.displays[info.id])
        try await choose("review-notes", in: side, f.model)
        side.draft = "A side question"
        try writeSkill(f.skills, "review-notes", description: "Review the notes", body: "UPDATED_NOTES_BODY")
        f.model.send(sessionID: info.id)
        await waitFor("The side's refused send never came back: \(side.sendFailure ?? "")") { refused(side) }
        XCTAssertEqual(side.sendFailure, "\u{201C}review-notes\u{201D} changed since you chose it. Press Send to use the updated version.")
        XCTAssertEqual(side.draft, "A side question")
        XCTAssertEqual(side.skills.first?.contentHash, current("review-notes", in: side)?.contentHash)
        XCTAssertEqual(userRows(side), 0)
        f.model.send(sessionID: info.id)
        await waitFor("The side's confirmed send never finished") { quiet(side) }
        XCTAssertTrue((side.messages.last { $0.role == "assistant" }?.text ?? "").contains("UPDATED_NOTES_BODY"))
    }

    /// The notice's words for each outcome, including a skill list that
    /// cannot be read (nothing changes, and the reader is told what to do).
    @MainActor func testTheNoticeSaysWhatBecameOfEachSkill() {
        typealias R = WorkspaceModel.SkillRefresh
        XCTAssertEqual(R(updated: ["a", "b"]).notice, "\u{201C}a\u{201D} and \u{201C}b\u{201D} changed since you chose them. Press Send to use the updated versions.")
        XCTAssertEqual(R(updated: ["a"], removed: ["b"]).notice, "\u{201C}a\u{201D} changed since you chose it. \u{201C}b\u{201D} is no longer available, so it was removed from your message. Press Send to use the updated version.")
        XCTAssertEqual(R(removed: ["b"], sendable: false).notice, "\u{201C}b\u{201D} is no longer available, so it was removed from your message. Add a message or choose another skill to send.")
        XCTAssertEqual(R(failure: "Skill discovery repeated a page.").notice, "A selected skill changed, and the skill list could not be read again (Skill discovery repeated a page). Remove the skill and choose it again, then press Send.")
        XCTAssertEqual(R().notice, "The selected skills are current again. Press Send to try once more.")
    }
}
