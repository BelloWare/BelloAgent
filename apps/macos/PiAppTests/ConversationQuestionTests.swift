import XCTest
import SwiftUI
import AppKit
@testable import PiApp

// MARK: - Questions the chat asks

extension ConversationPaneTests {
    /// The "outcome uncertain" question is a sheet on the chat's own window,
    /// not an application-modal alert: the rest of the app keeps running while
    /// it waits, and the answer drives the same send the return value used to.
    @MainActor func testTheUncertainQuestionIsASheetAndItsAnswerDrivesTheSend() async throws {
        let pane = try Pane(messages: [TranscriptMessage(id: "u1", role: "user", text: "Earlier", at: 1000, turn: "u1")])
        defer { pane.close() }
        await pane.settle(16)
        pane.session.uncertain = true
        pane.session.draft = "try again"
        pane.model.send(sessionID: pane.session.id)
        await pane.settle(8)
        XCTAssertTrue(pane.model.questions.askedIn === pane.window, "The question hangs off the chat's own window")
        let sheet = try XCTUnwrap(pane.window.attachedSheet, "The question hangs off the chat's own window")
        XCTAssertTrue(pane.model.questions.asking)
        XCTAssertFalse(pane.session.loading, "Nothing is sent until the question is answered")
        XCTAssertEqual(pane.session.draft, "try again", "The draft is untouched while the question is up")
        // The run loop is not blocked: the chat keeps rendering behind it.
        pane.session.state = "running"
        await pane.settle(8)
        XCTAssertNotNil(pane.transcript?.liveTurn, "Everything else keeps working while the question waits")
        pane.session.state = "idle"
        await pane.settle(6)
        // Cancel: nothing is sent and the chat is still uncertain.
        pane.window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        try await waitFor("The sheet never came down") { pane.window.attachedSheet == nil }
        await pane.settle(8)
        XCTAssertFalse(pane.model.questions.asking)
        XCTAssertTrue(pane.session.uncertain, "Cancelling leaves the chat uncertain")
        XCTAssertFalse(pane.session.loading, "Cancelling sends nothing")
        XCTAssertEqual(pane.session.draft, "try again")
        // Going ahead: the completion clears the uncertainty and sends.
        pane.model.send(sessionID: pane.session.id)
        await pane.settle(8)
        let second = try XCTUnwrap(pane.window.attachedSheet, "The question can be asked again")
        pane.window.endSheet(second, returnCode: .alertFirstButtonReturn)
        try await waitFor("The answer never reached the send") { !pane.session.uncertain }
        XCTAssertTrue(pane.session.loading || pane.session.sendFailure != nil || pane.session.draft.isEmpty,
                      "Going ahead runs the same send the old alert's return value did")
    }

    /// One question at a time: a second is refused and says so rather than
    /// stacking behind the one the reader is answering.
    @MainActor func testASecondQuestionIsRefusedWhileOneIsOnScreen() async throws {
        let pane = try Pane(); defer { pane.close() }
        await pane.settle(14)
        var answers: [Bool] = []
        XCTAssertTrue(pane.model.questions.ask(WorkspaceModel.uncertainOutcome, about: pane.session.id) { answers.append($0) })
        await pane.settle(6)
        // Whichever window the chat's sheet went to, it is that window's sheet.
        let host = try XCTUnwrap(pane.model.questions.askedIn, "The question is attached to a window")
        let sheet = try XCTUnwrap(host.attachedSheet)
        XCTAssertFalse(pane.model.questions.ask(WorkspaceModel.uncertainOutcome, about: pane.session.id) { answers.append($0) },
                       "A second question is refused while one is up")
        XCTAssertFalse(pane.model.questions.chooseImageFiles { _ in }, "So is a file choice")
        XCTAssertFalse(pane.model.questions.askText("Arguments", value: "", action: "Save", limit: 16) { _ in })
        host.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        try await waitFor("The sheet never came down") { host.attachedSheet == nil }
        XCTAssertEqual(answers, [false], "Only the question that was on screen was answered")
        XCTAssertTrue(pane.model.questions.ask(WorkspaceModel.uncertainOutcome, about: pane.session.id) { answers.append($0) },
                      "Once it is answered, the next question can be asked")
        if let next = pane.model.questions.askedIn?.attachedSheet { pane.model.questions.askedIn?.endSheet(next, returnCode: .alertSecondButtonReturn) }
        try await waitFor("The sheet never came down") { pane.model.questions.askedIn?.attachedSheet == nil }
    }

    /// Sending again after an uncertain outcome asks first, and the answer
    /// drives exactly what the alert's return value used to.
    @MainActor func testSendAsksBeforeRepeatingAnUncertainCommand() async throws {
        let pane = try Pane(messages: [TranscriptMessage(id: "u1", role: "user", text: "Earlier", at: 1000, turn: "u1")])
        defer { pane.close() }
        await pane.settle(16)
        var asked: [ChatQuestion] = []
        pane.model.questions.answer = { asked.append($0); return false }
        pane.session.uncertain = true; pane.session.draft = "again"
        pane.model.send(sessionID: pane.session.id)
        await pane.settle(8)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.action, "I Reviewed It — Send New Command")
        XCTAssertTrue(pane.session.uncertain, "Saying no sends nothing")
        XCTAssertFalse(pane.session.loading)
        XCTAssertEqual(pane.session.draft, "again", "The draft is untouched")
        XCTAssertNil(pane.window.attachedSheet, "An answered question leaves no sheet behind")
        pane.model.questions.answer = { asked.append($0); return true }
        pane.model.send(sessionID: pane.session.id)
        await pane.settle(8)
        XCTAssertEqual(asked.count, 2)
        XCTAssertFalse(pane.session.uncertain, "Saying yes clears the uncertainty and goes on to send")
        XCTAssertTrue(pane.session.loading || pane.session.draft.isEmpty || pane.session.sendFailure != nil,
                      "Saying yes runs the send")
        try await waitFor("The send never settled") { !pane.session.loading }
    }

    /// Resending an edited message asks the same question on the same window.
    @MainActor func testResendingAnEditedMessageAsksTheSameQuestion() async throws {
        let pane = try Pane(messages: [TranscriptMessage(id: "u1", role: "user", text: "Earlier", at: 1000, turn: "u1")])
        defer { pane.close() }
        await pane.settle(16)
        var asked: [ChatQuestion] = []
        pane.model.questions.answer = { asked.append($0); return false }
        pane.session.editingMessageID = "u1"
        pane.session.draft = "edited"
        pane.session.uncertain = true
        pane.model.sendEdit(sessionID: pane.session.id)
        await pane.settle(8)
        XCTAssertEqual(asked.map(\.title), ["Previous command outcome is uncertain"])
        XCTAssertTrue(pane.session.uncertain, "Saying no resends nothing")
        XCTAssertFalse(pane.session.loading)
        XCTAssertEqual(pane.session.editingMessageID, "u1", "The edit stays open")
    }

    /// Deleting a chat asks first, and only the answer deletes it.
    @MainActor func testDeletingAChatAsksFirst() async throws {
        let pane = try Pane(); defer { pane.close() }
        // Deleting clears the chat's retained request archive, so this fixture
        // needs its configuration loaded the way a launched app does.
        try await pane.model.reloadConfiguration()
        await pane.settle(16)
        var asked: [ChatQuestion] = []
        pane.model.questions.answer = { asked.append($0); return false }
        pane.model.deleteChat(pane.chat.id)
        await pane.settle(8)
        XCTAssertEqual(asked.map(\.action), ["Delete Chat"])
        XCTAssertNotNil(pane.model.record(pane.chat.id), "Saying no keeps the chat")
        XCTAssertNil(pane.model.error, pane.model.error ?? "")
        pane.model.questions.answer = { asked.append($0); return true }
        pane.model.deleteChat(pane.chat.id)
        try await waitFor("Saying yes never deleted the chat") { pane.model.record(pane.chat.id) == nil }
        XCTAssertNil(pane.model.error, pane.model.error ?? "")
        XCTAssertEqual(asked.count, 2)
    }

    /// Skill arguments and the image chooser answer the same way.
    @MainActor func testSkillArgumentsAndImageChoiceAnswerThroughTheirSheets() async throws {
        let pane = try Pane(imageModel: true); defer { pane.close() }
        await pane.settle(16)
        let chip = SkillChip(id: "s1", name: "release", path: "/skills/release", contentHash: "c", metadataHash: "m")
        pane.session.skills = [chip]
        pane.model.questions.enterText = { title, value in
            XCTAssertEqual(title, "Arguments for /release"); XCTAssertEqual(value, "")
            return "--dry-run"
        }
        pane.model.editSkillArguments(chip, view: pane.session)
        await pane.settle(6)
        XCTAssertEqual(pane.session.skills.first?.arguments, "--dry-run", "The entered arguments reach the chip")
        pane.model.questions.enterText = { _, _ in nil }
        pane.model.editSkillArguments(chip, view: pane.session)
        await pane.settle(6)
        XCTAssertEqual(pane.session.skills.first?.arguments, "--dry-run", "Cancelling changes nothing")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent(pane.session.id + ".png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        pane.model.questions.chooseFiles = { [] }
        pane.model.attachImages(sessionID: pane.session.id)
        await pane.settle(6)
        XCTAssertTrue(pane.session.attachments.isEmpty, "Cancelling the file choice attaches nothing")
        pane.model.questions.chooseFiles = { [file] }
        pane.model.attachImages(sessionID: pane.session.id)
        try await waitFor("The chosen image never attached") { !pane.session.attachments.isEmpty }
        XCTAssertEqual(pane.session.attachments.first?.mimeType, "image/png")
        XCTAssertNil(pane.window.attachedSheet, "None of this leaves a sheet on the window")
    }
}

// MARK: - Questions asked in the middle of a task

extension ConversationPaneTests {
    /// Recovering a copy asks before it creates or starts anything, as a sheet
    /// on the chat's window, and the task waits on the answer rather than the
    /// run loop. Cancel creates nothing; going ahead resumes the same work.
    @MainActor func testRecoveringACopyAsksBeforeItStartsAnythingAndResumes() async throws {
        let pane = try Pane(); defer { pane.close() }
        try await pane.model.reloadConfiguration()
        await pane.settle(16)
        // A chat with a source history on disk, which is what can be continued.
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("recover-\(UUID().uuidString).jsonl")
        try Data("{}\n".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        guard let index = pane.model.chats.firstIndex(where: { $0.id == pane.chat.id }) else { return XCTFail("The chat is gone") }
        pane.model.chats[index].path = source.path
        pane.model.selectedID = pane.chat.id
        let before = pane.model.chats.count

        pane.model.recoverCopy(pane.chat.id)
        try await waitFor("The question never appeared") { pane.window.attachedSheet != nil }
        XCTAssertTrue(pane.model.questions.askedIn === pane.window, "The question hangs off the chat's own window")
        XCTAssertTrue(pane.model.hosts.isEmpty, "Nothing is started before the answer")
        XCTAssertEqual(pane.model.chats.count, before, "Nothing is created before the answer")
        // The app keeps running behind it.
        pane.session.state = "running"
        await pane.settle(8)
        XCTAssertNotNil(pane.transcript?.liveTurn, "The chat keeps rendering while the question waits")
        pane.session.state = "idle"
        await pane.settle(6)
        let sheet = try XCTUnwrap(pane.window.attachedSheet)
        pane.window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        try await waitFor("The sheet never came down") { pane.window.attachedSheet == nil }
        await pane.settle(10)
        XCTAssertEqual(pane.model.chats.count, before, "Cancelling creates nothing")
        XCTAssertTrue(pane.model.hosts.isEmpty, "Cancelling starts no helper")
        XCTAssertNil(pane.model.error, pane.model.error ?? "")
        XCTAssertFalse(pane.model.questions.asking)

        // Going ahead resumes the same work: it reaches the helper's recovery,
        // and reports what the helper made of the file.
        pane.model.recoverCopy(pane.chat.id)
        try await waitFor("The question never came back") { pane.window.attachedSheet != nil }
        let second = try XCTUnwrap(pane.window.attachedSheet)
        pane.window.endSheet(second, returnCode: .alertFirstButtonReturn)
        try await waitFor("Going ahead never reached the recovery", seconds: 90) { pane.model.error != nil }
        XCTAssertTrue(pane.model.error?.contains("could not be recovered") == true,
                      "The resumed task ran the recovery: “\(pane.model.error ?? "")”")
        for host in pane.model.hosts.values { try? await host.shutdownAndWait() }
    }

    /// The portable handoff asks after the helper has prepared its preview,
    /// still as a sheet, and the answer decides whether the draft chat is made.
    @MainActor func testThePortableHandoffAsksOnTheChatsWindowAndItsAnswerDecides() async throws {
        let live = try await LiveChat()
        var closed = false
        defer { if !closed { Task { await live.close() } } }
        await live.settle(20)
        live.session.draft = "Summarize the retry loop."
        live.model.send(sessionID: live.chat.id)
        await live.waitUntil("The turn never finished", seconds: 120) {
            !live.session.hasWork && !live.session.loading && live.session.messages.contains { $0.role == "assistant" }
        }
        await live.waitUntil("The chat never got a history file") { live.model.record(live.chat.id)?.path != nil }
        let before = live.model.chats.count

        live.model.portableHandoff()
        await live.waitUntil("The question never appeared") { live.window.attachedSheet != nil }
        XCTAssertTrue(live.model.questions.askedIn === live.window, "The question hangs off the chat's own window")
        XCTAssertEqual(live.model.chats.count, before, "Nothing is created before the answer")
        // The app keeps running behind it.
        await live.holdRunning(8)
        XCTAssertNotNil(live.transcript?.liveTurn, "The chat keeps rendering while the question waits")
        live.session.state = "idle"
        await live.settle(6)
        let sheet = try XCTUnwrap(live.window.attachedSheet)
        live.window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        await live.waitUntil("The sheet never came down") { live.window.attachedSheet == nil }
        await live.settle(10)
        XCTAssertEqual(live.model.chats.count, before, "Cancelling makes no draft chat")
        XCTAssertNil(live.model.error, live.model.error ?? "")

        live.model.portableHandoff()
        await live.waitUntil("The question never came back") { live.window.attachedSheet != nil }
        let second = try XCTUnwrap(live.window.attachedSheet)
        live.window.endSheet(second, returnCode: .alertFirstButtonReturn)
        await live.waitUntil("Going ahead never made the draft chat", seconds: 60) { live.model.chats.count == before + 1 }
        let handoff = try XCTUnwrap(live.model.chats.first { $0.title.hasSuffix("— portable handoff") })
        XCTAssertEqual(live.model.selectedID, handoff.id, "The resumed task opens the draft it made")
        XCTAssertFalse(live.model.displays[handoff.id]?.draft.isEmpty ?? true, "The draft chat carries the portable text")
        XCTAssertNil(live.model.error, live.model.error ?? "")
        closed = true
        await live.close()
    }

    /// Choosing a project folder and opening a history are sheets too, and
    /// each one's choice drives the same work the panel's return value did.
    @MainActor func testChoosingAFolderOrAHistoryGoesThroughASheet() async throws {
        let pane = try Pane(); defer { pane.close() }
        try await pane.model.reloadConfiguration()
        await pane.settle(16)
        // Cancelling the folder chooser changes nothing.
        pane.model.questions.chooseFile = { _ in nil }
        let projects = pane.model.workspaces.count
        pane.model.pickWorkspace()
        await pane.settle(8)
        XCTAssertEqual(pane.model.workspaces.count, projects, "Cancelling adopts no project")
        // Choosing one adopts it and selects it.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pane-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var asked: [String] = []
        pane.model.questions.chooseFile = { message in asked.append(message); return folder }
        pane.model.pickWorkspace()
        try await waitFor("The chosen folder never became a project") { pane.model.workspaces.count == projects + 1 }
        XCTAssertTrue(asked.first?.contains("working directory") == true)
        let adopted = try XCTUnwrap(pane.model.workspaces.first { $0.path == folder.resolvingSymlinksInPath().path })
        XCTAssertTrue(adopted.trusted)
        try await waitFor("The adopted project never became the one new chats use") { pane.model.selectedWorkspaceID == adopted.id }
        XCTAssertNil(pane.model.error, pane.model.error ?? "")

        // Opening a history reads the file the chooser returned.
        let history = folder.appendingPathComponent("imported.jsonl")
        try Data("{}\n".utf8).write(to: history)
        let chats = pane.model.chats.count
        pane.model.questions.chooseFile = { message in asked.append(message); return history }
        pane.model.importChat()
        try await waitFor("The chosen history never opened") { pane.model.chats.count == chats + 1 }
        XCTAssertTrue(asked.last?.contains("read-only") == true)
        let imported = try XCTUnwrap(pane.model.chats.first { $0.imported })
        XCTAssertEqual(imported.path, history.path)
        XCTAssertEqual(imported.title, "imported")
        // Neither leaves a sheet behind.
        XCTAssertNil(pane.window.attachedSheet)
        XCTAssertFalse(pane.model.questions.asking)
    }

    /// A question raised from inside a task while another is on screen is
    /// refused and says so, rather than stacking behind it.
    @MainActor func testAnAwaitedQuestionIsRefusedWhileAnotherIsOnScreen() async throws {
        let pane = try Pane(); defer { pane.close() }
        await pane.settle(14)
        XCTAssertTrue(pane.model.questions.ask(WorkspaceModel.uncertainOutcome, about: pane.session.id) { _ in })
        await pane.settle(6)
        let host = try XCTUnwrap(pane.model.questions.askedIn)
        let sheet = try XCTUnwrap(host.attachedSheet)
        let answer = await pane.model.questions.confirm(WorkspaceModel.portableDraft, about: pane.session.id)
        XCTAssertEqual(answer, .busy, "The awaited question is refused, not stacked")
        host.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        try await waitFor("The sheet never came down") { host.attachedSheet == nil }
        // Once it is answered, the awaited form asks and resumes with the answer.
        let pending = Task { await pane.model.questions.confirm(WorkspaceModel.portableDraft, about: pane.session.id) }
        try await waitFor("The awaited question never appeared") { pane.model.questions.askedIn?.attachedSheet != nil }
        let owner = try XCTUnwrap(pane.model.questions.askedIn)
        owner.endSheet(try XCTUnwrap(owner.attachedSheet), returnCode: .alertFirstButtonReturn)
        let resumed = await pending.value
        XCTAssertEqual(resumed, .yes, "The awaited question resumes with the answer it was given")
        XCTAssertFalse(pane.model.questions.asking)
    }
}
