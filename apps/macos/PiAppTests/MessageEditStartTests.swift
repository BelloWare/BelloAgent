import XCTest
import AppKit
@testable import PiApp

/// Edit on a question the reader can see starts at once (EDIT-1, 0.1.131):
/// the composer takes the question from its row, under the edit banner and
/// ready for typing, while the complete original — the images and skills it
/// was sent with, and the timeline and text Send is checked against — is
/// read behind it. That read used to come first, and in a long chat it
/// replays the whole journal: seconds with the question already on screen.
/// Send waits for it; what is typed meanwhile stays; an edit saved while it
/// was still loading reads it again after a restart.
final class MessageEditStartTests: XCTestCase {
    static let question = "Why does the parser read the stream twice?\nLook at the nested block."

    /// A selected chat with two questions on screen and an unsent draft. The
    /// originals are read through the model's seam, and each read waits for
    /// the test to answer it.
    @MainActor private final class Bench {
        /// The reads asked for, and those still waiting; touched only on the main actor.
        final class Reads: @unchecked Sendable {
            var asked: [String] = []
            var pending: [CheckedContinuation<[String: WireValue], Error>] = []
        }
        let model: WorkspaceModel, view: SessionDisplay, root: URL
        let reads = Reads()
        var asked: [String] { reads.asked }
        let image: AttachmentRecord
        let skill = SkillChip(id: "skill-review", name: "review", path: "/skills/review/SKILL.md", contentHash: "content", metadataHash: "metadata")

        init(_ test: XCTestCase, root given: URL? = nil, messages: [TranscriptMessage]? = nil) async throws {
            let folder = given ?? scratchRoot("message-edit-start")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Registered first, so it runs last: after the models' own teardown.
            if given == nil { test.addTeardownBlock { try? FileManager.default.removeItem(at: folder) } }
            root = folder
            // A real image file, so the original's attachment is found as it was.
            let file = root.appendingPathComponent("diagram.png")
            if !FileManager.default.fileExists(atPath: file.path) { try Self.png.write(to: file) }
            image = try AttachmentRecord.inspect(file)
            model = test.makeWorkspaceModel(stateRoot: root.appendingPathComponent("state"))
            let chat = ChatRecord(id: "chat", workspaceID: "w", title: "Chat", profileID: "p")
            model.chats = [chat]
            view = SessionDisplay(id: chat.id)
            view.messages = messages ?? [
                TranscriptMessage(id: "u1", role: "user", text: "First question"),
                TranscriptMessage(id: "a1", role: "assistant", text: "First answer"),
                TranscriptMessage(id: "u2", role: "user", text: MessageEditStartTests.question),
                TranscriptMessage(id: "a2", role: "assistant", text: "Second answer"),
            ]
            model.displays[chat.id] = view; model.selectedID = chat.id; model.selected = view; model.focusedSessionID = chat.id
            let reads = reads
            model.editTargetRead = { _, id in
                reads.asked.append(id)
                return try await withCheckedThrowingContinuation { reads.pending.append($0) }
            }
            // A selected chat has its saved draft read before its rows show.
            try await model.loadDraftBaseline(view)
            view.draft = "An unsent draft"
        }
        /// Answers the oldest read still waiting.
        func answer(_ result: Result<[String: WireValue], Error>) { reads.pending.removeFirst().resume(with: result) }
        func original(_ id: String = "u2", text: String = MessageEditStartTests.question, inputs: Bool = true) throws -> [String: WireValue] {
            var input: [String: WireValue] = ["version": .number(1)]
            if inputs {
                input["attachments"] = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode([image]))
                input["skills"] = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode([skill]))
            }
            return ["messageId": .string(id), "text": .string(text), "sourceTimeline": .string("timeline-1"),
                    "sourceTextDigest": .string("digest-1"), "input": .object(input), "legacyInputs": .bool(false)]
        }
        func settle() async { for _ in 0..<5 { await Task.yield() } }
        /// The smallest PNG: one transparent pixel.
        static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
    }

    @MainActor private static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// The press puts the question in the composer under its banner, ready
    /// for typing, before its original is read; the original's image, skill
    /// and checks then join what was typed, and Send waits only until then.
    @MainActor func testAQuestionOnScreenIsInTheComposerAtOnceAndTypingKeepsWhenItsOriginalArrives() async throws {
        let bench = try await Bench(self)
        let model = bench.model, view = bench.view
        let composer = ComposerInputView(model: model)
        composer.frame = NSRect(x: 0, y: 0, width: 720, height: 320)
        composer.show(view)
        model.editMessage("u2", sessionID: view.id)
        // At once: nothing has been read.
        XCTAssertTrue(bench.asked.isEmpty)
        XCTAssertEqual(view.editingMessageID, "u2", "The composer takes the question from its row at once")
        XCTAssertEqual(view.draft, Self.question)
        XCTAssertTrue(view.editPreparing)
        XCTAssertEqual(model.editBlocker(view), "Loading the complete original input…", "Send waits for the complete original")
        composer.refresh(); composer.layoutSubtreeIfNeeded()
        XCTAssertNotNil(Self.views(ComposerEditBanner.self, in: composer).first { $0.accessibilityLabel() == "Editing an earlier message" && !$0.isHidden },
                        "The edit banner shows while the original loads")
        let editor = try XCTUnwrap(composer.field?.documentView as? ComposerTextView)
        XCTAssertEqual(editor.string, Self.question)
        XCTAssertTrue(editor.isEditable, "The composer takes typing while the original loads")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText(" Also check the tests.", replacementRange: editor.selectedRange())
        XCTAssertEqual(view.draft, Self.question + " Also check the tests.")

        // Send before the original is read says why it waits, and sends nothing.
        model.sendEdit(sessionID: view.id)
        XCTAssertEqual(view.notice, "Loading the complete original input…"); XCTAssertFalse(view.editSubmitting)
        try await eventually("The original is asked for") { bench.asked == ["u2"] }
        bench.answer(.success(try bench.original()))
        try await eventually("The original is read") { !view.editPreparing }
        XCTAssertEqual(view.notice, "", "The wait it gave as the reason is over")
        XCTAssertEqual(view.draft, Self.question + " Also check the tests.", "What was typed while the original loaded stays")
        XCTAssertEqual(view.attachments, [bench.image]); XCTAssertEqual(view.skills.map(\.id), [bench.skill.id])
        XCTAssertEqual(view.editSourceTimeline, "timeline-1"); XCTAssertEqual(view.editSourceTextDigest, "digest-1")
        XCTAssertFalse(view.editInputPending)
        XCTAssertNil(model.editBlocker(view), "Send takes the edit once the original is read")
        XCTAssertNil(view.savedDraft.edit?.inputPending)

        model.cancelEdit(sessionID: view.id)
        XCTAssertNil(view.editingMessageID)
        XCTAssertEqual(view.draft, "An unsent draft", "Cancel gives back the draft the edit set aside")
    }

    /// Cancel while the original loads gives the draft back, and the read
    /// that finishes after it changes nothing.
    @MainActor func testCancelWhileTheOriginalLoadsGivesBackTheDraftAndALateReadChangesNothing() async throws {
        let bench = try await Bench(self)
        let model = bench.model, view = bench.view
        model.editMessage("u2", sessionID: view.id)
        XCTAssertEqual(view.editingMessageID, "u2")
        model.cancelEdit(sessionID: view.id)
        XCTAssertNil(view.editingMessageID); XCTAssertFalse(view.editPreparing); XCTAssertFalse(view.editInputPending)
        XCTAssertEqual(view.draft, "An unsent draft")
        try await eventually("The original is asked for") { bench.asked == ["u2"] }
        bench.answer(.success(try bench.original()))
        await bench.settle(); try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(view.editingMessageID); XCTAssertEqual(view.draft, "An unsent draft"); XCTAssertTrue(view.attachments.isEmpty)
    }

    /// An original that cannot be read leaves the question and the typing in
    /// the composer, and holds Send until Edit reads it again.
    @MainActor func testAnOriginalThatCannotBeReadKeepsTheTypingAndHoldsSend() async throws {
        let bench = try await Bench(self)
        let model = bench.model, view = bench.view
        model.editMessage("u2", sessionID: view.id)
        view.draft += " More."
        try await eventually("The original is asked for") { bench.asked.count == 1 }
        bench.answer(.failure(HostError.failure("The journal could not be read.")))
        try await eventually("The read ends") { !view.editPreparing }
        XCTAssertEqual(view.editingMessageID, "u2"); XCTAssertEqual(view.draft, Self.question + " More.")
        XCTAssertTrue(view.editInputPending)
        XCTAssertEqual(model.editBlocker(view), "The complete original input could not be loaded. Cancel, or choose Edit on the message again.")
        XCTAssertTrue(view.notice.contains("The journal could not be read."), view.notice)
        XCTAssertEqual(view.savedDraft.edit?.inputPending, true, "A restart reads it again")
        model.editMessage("u2", sessionID: view.id)
        try await eventually("The original is asked for again") { bench.asked.count == 2 }
        bench.answer(.success(try bench.original()))
        try await eventually("The original is read") { !view.editPreparing }
        XCTAssertFalse(view.editInputPending); XCTAssertNil(model.editBlocker(view))
    }

    /// Edit again on a message whose original could not be read (what the
    /// banner asks for) reads it again behind the composer: what was typed
    /// and the skill added since stay (review, 2026-10-23).
    @MainActor func testEditAgainAfterAFailedReadKeepsWhatWasTypedAndAdded() async throws {
        let bench = try await Bench(self)
        let model = bench.model, view = bench.view
        model.editMessage("u2", sessionID: view.id)
        view.draft += " More."
        let added = SkillChip(id: "skill-notes", name: "notes", path: "/skills/notes/SKILL.md", contentHash: "notes", metadataHash: "notes-meta")
        view.skills = [added]
        try await eventually("The original is asked for") { bench.asked.count == 1 }
        bench.answer(.failure(HostError.failure("The journal could not be read.")))
        try await eventually("The read ends") { !view.editPreparing }
        XCTAssertTrue(view.editInputPending)
        model.editMessage("u2", sessionID: view.id)
        XCTAssertEqual(view.draft, Self.question + " More.", "Edit again keeps what was typed")
        XCTAssertEqual(view.skills.map(\.id), [added.id], "Edit again keeps the skill added")
        XCTAssertTrue(view.editPreparing)
        try await eventually("The original is asked for again") { bench.asked.count == 2 }
        bench.answer(.success(try bench.original()))
        try await eventually("The original is read") { !view.editPreparing }
        XCTAssertEqual(view.draft, Self.question + " More.")
        XCTAssertEqual(view.skills.map(\.id), [bench.skill.id, added.id]); XCTAssertEqual(view.attachments, [bench.image])
        XCTAssertFalse(view.editInputPending); XCTAssertNil(model.editBlocker(view))
        model.cancelEdit(sessionID: view.id)
        XCTAssertEqual(view.draft, "An unsent draft")
    }

    /// A skill chosen while the original loads, with arguments of its own,
    /// is kept when the original arrives with the same skill: the composer's
    /// chip, not the historical one, is what Send sends (review, 2026-10-23).
    @MainActor func testASkillChosenWhileTheOriginalLoadsKeepsItsArguments() async throws {
        let bench = try await Bench(self)
        let model = bench.model, view = bench.view
        model.editMessage("u2", sessionID: view.id)
        var chosen = bench.skill
        chosen.arguments = "--strict"; chosen.contentHash = "content-now"
        view.skills = [chosen]
        try await eventually("The original is asked for") { bench.asked.count == 1 }
        bench.answer(.success(try bench.original()))
        try await eventually("The original is read") { !view.editPreparing }
        XCTAssertEqual(view.skills, [chosen], "The chip chosen while the original loaded is kept")
        XCTAssertEqual(view.attachments, [bench.image])
    }

    /// Undo of a skill step made while the original loaded (a skill chosen
    /// through the slash list, a token removed) takes back that step only:
    /// the original's own skill, which arrived after the steps were recorded,
    /// stays through Undo and Redo (review, 2026-10-23).
    @MainActor func testUndoOfSkillStepsMadeWhileTheOriginalLoadedKeepsTheOriginalsSkill() async throws {
        let bench = try await Bench(self)
        let model = bench.model, view = bench.view
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let editor = ComposerTextView(frame: window.contentView!.bounds); editor.isRichText = false; editor.allowsUndo = true; editor.sessionID = view.id
        editor.skillStrip.display = view
        window.contentView?.addSubview(editor)
        model.editMessage("u2", sessionID: view.id)
        editor.string = view.draft
        let undo = try XCTUnwrap(editor.undoManager)
        undo.groupsByEvent = false
        func step(_ change: () -> Void) { undo.beginUndoGrouping(); change(); undo.endUndoGrouping() }
        func chip(_ name: String) -> SkillChip { SkillChip(id: "skill-" + name, name: name, path: "/skills/\(name)/SKILL.md", contentHash: name, metadataHash: name + "-meta") }
        let notes = chip("notes"), lint = chip("lint")
        func choose(_ chosen: SkillChip) {
            let end = NSRange(location: (editor.string as NSString).length, length: 0)
            editor.replaceCompletion(range: end, with: "", skills: view.skills + [chosen], display: view, changed: {})
        }
        step { choose(notes) }
        step { choose(lint) }
        step { editor.skillTokens = view.skills; editor.applySkillChange([notes], actionName: "Remove Skill") }
        XCTAssertEqual(view.skills.map(\.id), [notes.id])
        try await eventually("The original is asked for") { bench.asked.count == 1 }
        bench.answer(.success(try bench.original()))
        try await eventually("The original is read") { !view.editPreparing }
        let original = bench.skill.id
        XCTAssertEqual(view.skills.map(\.id), [original, notes.id])
        undo.undo(); XCTAssertEqual(view.skills.map(\.id), [original, notes.id, lint.id], "Undo of the removal brings back only what it removed")
        undo.undo(); XCTAssertEqual(view.skills.map(\.id), [original, notes.id], "Undo of a choice takes back only that skill")
        undo.undo(); XCTAssertEqual(view.skills.map(\.id), [original])
        undo.redo(); XCTAssertEqual(view.skills.map(\.id), [original, notes.id], "Redo puts it back beside the original's")
        undo.redo(); XCTAssertEqual(view.skills.map(\.id), [original, notes.id, lint.id])
        undo.redo(); XCTAssertEqual(view.skills.map(\.id), [original, notes.id])
    }

    /// A skill step undone or redone over skills that came in since: what it
    /// removed comes back where it stood among the step's own skills, and a
    /// skill loaded since (an edited message's original) stays where it is
    /// (review, 2026-10-23).
    @MainActor func testASkillStepIsUndoneInPlaceBesideASkillLoadedSince() {
        func chip(_ name: String) -> SkillChip { SkillChip(id: "skill-" + name, name: name, path: "/skills/\(name)/SKILL.md", contentHash: name, metadataHash: name + "-meta") }
        let a = chip("a"), b = chip("b"), c = chip("c"), loaded = chip("loaded")
        func step(_ current: [SkillChip], from: [SkillChip], to: [SkillChip]) -> [String] {
            ComposerTextView.skills(current, steppedFrom: from, to: to).map(\.name)
        }
        XCTAssertEqual(step([b, c], from: [b, c], to: [a, b, c]), ["a", "b", "c"], "A removed first token comes back first")
        XCTAssertEqual(step([a, c], from: [a, c], to: [a, b, c]), ["a", "b", "c"], "a middle one between its neighbours")
        XCTAssertEqual(step([loaded, b, c], from: [b, c], to: [a, b, c]), ["loaded", "a", "b", "c"], "beside a skill loaded since, which stays")
        XCTAssertEqual(step([loaded, a], from: [a], to: [a, b]), ["loaded", "a", "b"])
        XCTAssertEqual(step([loaded], from: [], to: [a]), ["loaded", "a"])
        XCTAssertEqual(step([loaded, a, b], from: [a, b], to: [a]), ["loaded", "a"])
    }

    /// An image import under way when Edit is chosen again on the same edit
    /// (its original unread) still lands in the composer: the edit and its
    /// draft are the same, only the read starts over (review, 2026-10-23).
    @MainActor func testAnImageImportGoingOnKeepsItsPlaceWhenEditIsChosenAgain() async throws {
        let bench = try await Bench(self)
        let model = bench.model, view = bench.view
        model.editMessage("u2", sessionID: view.id)
        try await eventually("The original is asked for") { bench.asked.count == 1 }
        bench.answer(.failure(HostError.failure("The journal could not be read.")))
        try await eventually("The read ends") { !view.editPreparing }
        let importing = model.beginImageImport(sessionID: view.id)
        XCTAssertTrue(importing.isCurrent())
        model.editMessage("u2", sessionID: view.id)
        XCTAssertTrue(importing.isCurrent(), "Edit again on the same edit keeps an image import under way")
        try await eventually("The original is asked for again") { bench.asked.count == 2 }
        bench.answer(.success(try bench.original()))
        try await eventually("The original is read") { !view.editPreparing }
        XCTAssertTrue(importing.isCurrent(), "The original arriving keeps it too")
        importing.finish()
        model.cancelEdit(sessionID: view.id)
        XCTAssertFalse(importing.isCurrent(), "Cancel ends the edit the import was for")
    }

    /// A read the helper refused because rows were written while it loaded
    /// the whole history (a run going on) is made again.
    @MainActor func testAReadThatMetRowsWrittenMeanwhileIsMadeAgain() async throws {
        let bench = try await Bench(self)
        let model = bench.model, view = bench.view
        model.editMessage("u2", sessionID: view.id)
        try await eventually("The original is asked for") { bench.asked.count == 1 }
        bench.answer(.failure(HostError.rejected("edit_changed", "The conversation changed during edit preparation. Select the message again.")))
        try await eventually("The original is asked for again") { bench.asked.count == 2 }
        bench.answer(.success(try bench.original()))
        try await eventually("The original is read") { !view.editPreparing }
        XCTAssertFalse(view.editInputPending); XCTAssertEqual(view.editSourceTimeline, "timeline-1"); XCTAssertNil(model.editBlocker(view))
    }

    /// An original that reads differently from its row: taken whole while
    /// the composer is untouched; once typed in, the typing stays and the
    /// banner says so.
    @MainActor func testAnOriginalUnlikeItsRowReplacesItUntilTypedIn() async throws {
        let bench = try await Bench(self)
        let model = bench.model, view = bench.view
        model.editMessage("u2", sessionID: view.id)
        try await eventually("The original is asked for") { bench.asked.count == 1 }
        bench.answer(.success(try bench.original(text: "The whole original question")))
        try await eventually("The original is read") { !view.editPreparing }
        XCTAssertEqual(view.draft, "The whole original question")

        model.editMessage("u2", sessionID: view.id)
        XCTAssertEqual(view.draft, Self.question)
        view.draft += " Typed."
        try await eventually("The original is asked for again") { bench.asked.count == 2 }
        bench.answer(.success(try bench.original(text: "The whole original question")))
        try await eventually("The original is read") { !view.editPreparing }
        XCTAssertEqual(view.draft, Self.question + " Typed.")
        XCTAssertEqual(view.editNotice, "The original message differs from its row as shown. Review the text before sending.")
        model.cancelEdit(sessionID: view.id)
        XCTAssertEqual(view.draft, "An unsent draft")
    }

    /// A row that is not the whole question — an image-only message's label,
    /// a cut row — and a chat whose saved draft is not read yet wait for the
    /// original, as every edit did.
    @MainActor func testARowThatIsNotTheWholeQuestionWaitsForItsOriginal() async throws {
        var cut = TranscriptMessage(id: "u4", role: "user", text: "The start of a long question")
        cut.truncated = true
        let bench = try await Bench(self, messages: [
            TranscriptMessage(id: "u3", role: "user", text: TranscriptMessage.imageOnlyText(2)), TranscriptMessage(id: "a3", role: "assistant", text: "Two images"),
            cut, TranscriptMessage(id: "a4", role: "assistant", text: "Answer"),
            TranscriptMessage(id: "u5", role: "user", text: "Plain"), TranscriptMessage(id: "a5", role: "assistant", text: "Answer"),
        ])
        let model = bench.model, view = bench.view
        for id in ["u3", "u4"] {
            model.editMessage(id, sessionID: view.id)
            XCTAssertNil(view.editingMessageID, id); XCTAssertEqual(view.draft, "An unsent draft", id); XCTAssertTrue(view.editPreparing, id)
            try await eventually("The original is asked for") { bench.asked.last == id }
            bench.answer(.success(try bench.original(id, text: id == "u3" ? "" : "The start of a long question and its whole end")))
            try await eventually("The original is read") { !view.editPreparing }
            XCTAssertEqual(view.editingMessageID, id)
            model.cancelEdit(sessionID: view.id)
        }
        view.selectionMetadataLoaded = false
        model.editMessage("u5", sessionID: view.id)
        XCTAssertNil(view.editingMessageID, "A chat whose saved draft is unread waits"); XCTAssertEqual(view.draft, "An unsent draft")
        try await eventually("The original is asked for") { bench.asked.last == "u5" }
        bench.answer(.success(try bench.original("u5", text: "Plain")))
        try await eventually("The original is read") { !view.editPreparing }
        XCTAssertEqual(view.editingMessageID, "u5"); XCTAssertEqual(view.draft, "Plain")
    }

    /// An edit saved while its original was still loading comes back after
    /// a restart with what was typed, and reads its original again before
    /// Send takes it; the draft it set aside comes back on Cancel.
    @MainActor func testAnEditSavedWhileItsOriginalLoadedReadsItAgainAfterARestart() async throws {
        let bench = try await Bench(self)
        let first = bench.model, view = bench.view
        first.editMessage("u2", sessionID: view.id)
        view.draft += " Typed before the restart."
        try await first.flushDrafts()
        XCTAssertEqual(view.savedDraft.edit?.inputPending, true)
        first.shutdown()
        try await eventually("The original is asked for") { bench.asked.count == 1 }
        bench.answer(.failure(CancellationError()))
        try? await first.traces.close(); await first.store?.close()

        let model = makeWorkspaceModel(stateRoot: bench.root.appendingPathComponent("state"))
        model.chats = [ChatRecord(id: "chat", workspaceID: "w", title: "Chat", profileID: "p")]
        let again = SessionDisplay(id: "chat")
        again.messages = view.messages
        model.displays[again.id] = again; model.selectedID = again.id; model.selected = again; model.focusedSessionID = again.id
        var asked: [String] = []
        let original = try bench.original()
        model.editTargetRead = { _, id in asked.append(id); return original }
        try await model.loadDraftBaseline(again)
        XCTAssertEqual(again.editingMessageID, "u2")
        XCTAssertEqual(again.draft, Self.question + " Typed before the restart.")
        try await eventually("The original is read again") { !again.editPreparing && !again.editInputPending }
        XCTAssertEqual(asked, ["u2"])
        XCTAssertEqual(again.draft, Self.question + " Typed before the restart.")
        XCTAssertEqual(again.attachments, [bench.image]); XCTAssertEqual(again.skills.map(\.id), [bench.skill.id])
        XCTAssertEqual(again.editSourceTimeline, "timeline-1"); XCTAssertNil(model.editBlocker(again))
        model.cancelEdit(sessionID: again.id)
        XCTAssertEqual(again.draft, "An unsent draft")
    }

    /// A chat on the packaged helper and the synthetic gateway, its questions
    /// asked through the helper and its rows read into its display as a
    /// selected chat has them (its saved draft read too).
    @MainActor private final class LiveChat {
        let model: WorkspaceModel, chat: ChatRecord, view: SessionDisplay
        private(set) var host: HostSupervisor
        init(_ test: XCTestCase, _ name: String, slowWords: Int? = nil) async throws {
            var environment = ["PI_APP_UI_FIXTURE_SUMMARY_DELAY": "0"]
            if let slowWords { environment["PI_APP_UI_FIXTURE_SLOW_WORDS"] = String(slowWords) }
            let bench = try await test.gatewayWorkspace(name, projectID: "edit-start", gatewayEnvironment: environment)
            model = test.makeWorkspaceModel(stateRoot: bench.state, vault: bench.vault)
            try await model.reloadConfiguration()
            chat = ChatRecord(id: name + "-chat", workspaceID: bench.workspace.id, title: "Edit", path: nil, profileID: bench.profile.id)
            try await model.store?.put(chat, kind: "chat", id: chat.id); model.chats = [chat]
            view = SessionDisplay(id: chat.id)
            model.displays[chat.id] = view; model.selectedID = chat.id; model.selected = view; model.focusedSessionID = chat.id
            host = try await model.open(chat)
        }
        func settle() async throws {
            for _ in 0..<5_000 {
                let status = try await host.request("session.status", sessionID: chat.id).object ?? [:]
                if ["idle", "error", "paused"].contains(status["state"]?.string ?? "") { XCTAssertEqual(status["state"]?.string, "idle", "\(status)"); return }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("The turn did not settle")
        }
        func ask(_ id: String, _ text: String) async throws {
            _ = try await host.request("turn.submit", sessionID: chat.id, params: ["clientTurnId": .string(id), "text": .string(text)])
            try await settle()
        }
        /// The message `id` rewritten through the helper directly, as another
        /// window's edit would: the occurrence it replaces leaves the timeline.
        func editElsewhere(_ id: String, as turnID: String, _ text: String) async throws {
            _ = try await host.request(WorkspaceModel.editTurnMethod, sessionID: chat.id,
                                       params: WorkspaceModel.editTurnParams(messageID: id, text: text, turnID: turnID, attachments: [], skills: []),
                                       commandID: UUID().uuidString)
            try await settle()
        }
        /// Opened again, from the metadata file a compaction wrote.
        func reopen() async throws {
            let item = try XCTUnwrap(model.record(chat.id))
            _ = try await host.request("session.close", sessionID: chat.id); model.helperSessionDidUnload(chat.id)
            host = try await model.open(item)
        }
        /// The display reads the helper's rows, settled, as a selected chat does.
        func read(through id: String) async throws {
            model.refresh(chat.id)
            try await eventually("The chat's rows are read", timeout: .seconds(30)) {
                !self.view.hasWork && self.view.messages.contains { $0.id == id } && self.view.messages.last?.role == "assistant"
            }
            if !view.selectionMetadataLoaded { try await model.loadDraftBaseline(view) }
        }
        func userTexts() async throws -> [String] {
            let snapshot = try await host.request("session.snapshot", sessionID: chat.id, params: ["includeMessages": .bool(true)]).object ?? [:]
            return try TranscriptMessage.page(snapshot["messages"] ?? .array([])).filter { $0.role == "user" }.map(\.text)
        }
    }

    /// Through the packaged helper and the synthetic gateway: a chat with a
    /// compaction, opened again from its metadata file, so its original needs
    /// the whole history. Edit puts the question in the composer at once, the
    /// typing goes in while the helper reads the history, and Send then
    /// resends the edit, which the helper takes against the timeline and
    /// text the read gave.
    @MainActor func testEditingAQuestionOnScreenThroughThePackagedHelper() async throws {
        let live = try await LiveChat(self, "message-edit-helper")
        let model = live.model, view = live.view
        // Long enough replies for a compaction to keep only the latest turns.
        for (turn, text) in ["The first question, bulk 60 please", "The second question, bulk 60 please", "The question to edit", "The last question"].enumerated() {
            try await live.ask("q\(turn)", text)
            if turn == 1 { _ = try await live.host.request("context.compact", sessionID: live.chat.id); try await live.settle() }
        }
        let path = try XCTUnwrap(model.record(live.chat.id)?.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".meta"), "The compaction wrote the metadata file")
        try await live.reopen()
        try await live.read(through: "q2")

        model.editMessage("q2", sessionID: live.chat.id)
        XCTAssertEqual(view.editingMessageID, "q2"); XCTAssertEqual(view.draft, "The question to edit")
        view.draft = "The question, edited"
        try await eventually("The helper reads the original", timeout: .seconds(30)) { !view.editPreparing }
        XCTAssertFalse(view.editInputPending, view.notice); XCTAssertNotNil(view.editSourceTimeline); XCTAssertNotNil(view.editSourceTextDigest)
        XCTAssertNil(model.editBlocker(view))
        XCTAssertEqual(view.draft, "The question, edited")
        model.sendEdit(sessionID: live.chat.id)
        try await eventually("The edit is accepted", timeout: .seconds(30)) { !view.editSubmitting && view.editingMessageID == nil }
        try await live.settle()
        let texts = try await live.userTexts()
        XCTAssertEqual(texts.last, "The question, edited", view.notice)
        XCTAssertFalse(texts.contains("The last question"), "The question after the edited one is off the timeline")
    }

    /// Owner decision, 2026-10-23 ("Re-check at Send"): an edit opened while a
    /// run goes on is checked again at Send against the conversation through
    /// the edited message. The rows the run added after it do not refuse it.
    @MainActor func testAnEditOpenedDuringARunIsSentOnceTheRunHasAddedRows() async throws {
        let live = try await LiveChat(self, "message-edit-run", slowWords: 12)
        let model = live.model, view = live.view
        try await live.ask("q0", "The question to edit")
        try await live.ask("q1", "The second question")
        try await live.read(through: "q1")
        view.draft = "A slow answer, please"; model.send(sessionID: live.chat.id)
        try await eventually("The slow run streams", timeout: .seconds(30)) { view.busy && view.messages.last?.isStreaming == true }
        model.editMessage("q0", sessionID: live.chat.id)
        XCTAssertEqual(view.editingMessageID, "q0")
        try await eventually("The original is read while the run goes on", timeout: .seconds(30)) { !view.editPreparing }
        XCTAssertTrue(view.busy, "The checks were read during the run")
        view.draft = "The question, edited during the run"
        try await eventually("The run ends", timeout: .seconds(60)) { !view.hasWork && !view.loading && view.messages.last?.isStreaming == false }
        let during = try await live.userTexts()
        XCTAssertEqual(during.last, "A slow answer, please", "The run added its rows after the edited message")
        model.sendEdit(sessionID: live.chat.id)
        try await eventually("Send settles", timeout: .seconds(30)) { !view.editSubmitting }
        XCTAssertNil(view.editingMessageID, "Send takes the edit: \(view.notice)")
        try await live.settle()
        let after = try await live.userTexts()
        XCTAssertEqual(after, ["The question, edited during the run"])
    }

    /// Re-checked at Send, an edit is still refused when the message itself
    /// or the conversation it branches from changed since it was read: here
    /// another window's edits, first of the message before it, then of the
    /// message itself. The composer keeps the edit and its typing.
    @MainActor func testAnEditIsStillRefusedWhenItsMessageOrWhatItBranchesFromChanged() async throws {
        let live = try await LiveChat(self, "message-edit-refused")
        let model = live.model, view = live.view
        for (turn, text) in ["The first question", "The second question", "The third question"].enumerated() { try await live.ask("q\(turn)", text) }
        try await live.read(through: "q2")
        // What it branches from changes: the message before it is rewritten.
        model.editMessage("q2", sessionID: live.chat.id)
        try await eventually("The original is read", timeout: .seconds(30)) { !view.editPreparing }
        view.draft = "The third question, edited"
        try await live.editElsewhere("q1", as: "q1b", "The second question, rewritten elsewhere")
        try await eventually("The rewrite reaches the chat", timeout: .seconds(30)) { !view.hasWork && !view.loading }
        model.sendEdit(sessionID: live.chat.id)
        XCTAssertTrue(view.editSubmitting, "Send is made: \(model.editBlocker(view) ?? view.notice)")
        try await eventually("Send settles", timeout: .seconds(30)) { !view.editSubmitting }
        XCTAssertEqual(view.editingMessageID, "q2", "The edit stays in the composer")
        // The banner keeps the helper's reason; the line under the composer
        // goes back to the tool notice at the chat's next refresh.
        XCTAssertEqual(view.draft, "The third question, edited"); XCTAssertTrue(view.editNotice.contains("abandoned branch"), view.editNotice)
        try await live.settle()
        let first = try await live.userTexts()
        XCTAssertEqual(first, ["The first question", "The second question, rewritten elsewhere"])
        model.cancelEdit(sessionID: live.chat.id)
        // The message itself changes: it is rewritten elsewhere after it was
        // read. The display need not show another writer's branch yet, so this
        // edit may read its original before the composer takes it.
        model.editMessage("q1b", sessionID: live.chat.id)
        try await eventually("The original is read", timeout: .seconds(30)) { !view.editPreparing }
        XCTAssertEqual(view.editingMessageID, "q1b", view.notice)
        view.draft = "The second question, edited here"
        try await live.editElsewhere("q1b", as: "q1c", "The second question, rewritten again elsewhere")
        try await eventually("The rewrite reaches the chat", timeout: .seconds(30)) { !view.hasWork && !view.loading }
        model.sendEdit(sessionID: live.chat.id)
        XCTAssertTrue(view.editSubmitting, "Send is made: \(model.editBlocker(view) ?? view.notice)")
        try await eventually("Send settles", timeout: .seconds(30)) { !view.editSubmitting }
        XCTAssertEqual(view.editingMessageID, "q1b", "The edit stays in the composer")
        XCTAssertEqual(view.draft, "The second question, edited here"); XCTAssertTrue(view.editNotice.contains("abandoned branch"), view.editNotice)
        try await live.settle()
        let second = try await live.userTexts()
        XCTAssertEqual(second, ["The first question", "The second question, rewritten again elsewhere"])
    }
}
