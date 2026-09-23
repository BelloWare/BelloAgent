import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// Skills rendered inline: the composer's tokens that lead the text, the
/// pills at the start of a sent message's bubble, the card a resting pointer
/// brings up and the popover a press opens.
final class InlineSkillPillTests: XCTestCase {

    // MARK: Fixtures

    static func descriptor(_ name: String, description: String = "Walk through the release preflight before tagging",
                           scope: String = "project", policy: String = "explicitOnly", hash: String = "3f2a9c1e77ab01cd",
                           path: String? = nil) -> SkillDescriptor {
        SkillDescriptor(id: "id-" + name, name: name, path: path ?? "/work/project/.agents/skills/\(name)/SKILL.md", description: description,
                        scope: scope, contentHash: hash, metadataHash: "meta-" + name, policy: policy, reasons: [], missingDependencies: [])
    }
    static func chip(_ name: String, arguments: String = "") -> SkillChip {
        var chip = descriptor(name).chip; chip.arguments = arguments; return chip
    }
    static func use(_ name: String, arguments: String = "", hash: String = "3f2a9c1e77ab01cd") -> TranscriptSkillUse {
        TranscriptSkillUse(id: "id-" + name, name: name, path: "/work/project/.agents/skills/\(name)/SKILL.md", contentHash: hash,
                           metadataHash: "meta-" + name, arguments: arguments, description: "Walk through the release preflight before tagging",
                           scope: "project", policy: "explicitOnly")
    }
    static func catalog(_ skills: [SkillDescriptor], state: SkillCatalog.State = .ready) -> SkillCatalog {
        SkillCatalog(state: state, scope: "fixture", revision: "r1", entries: skills.map(SkillSearch.Entry.init))
    }

    /// Starts a clean undo history. Under XCTest the run loop that would close
    /// one keystroke's undo group before the next never turns, so every edit
    /// a test makes lands in one group; clearing it first leaves the next
    /// step's group holding that step alone, as a keystroke's would.
    @MainActor static func freshUndo(_ editor: NSTextView) { editor.undoManager?.removeAllActions() }
    /// One keystroke through the editor's real key handling.
    @MainActor static func key(_ characters: String, code: UInt16, into view: NSView, modifiers: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
        view.keyDown(with: event)
    }
    /// The pointer entering or leaving a view, as its tracking area reports it.
    @MainActor static func pointer(_ entered: Bool, over view: NSView) {
        guard let event = NSEvent.enterExitEvent(with: entered ? .mouseEntered : .mouseExited, location: .zero, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
                                                 context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) else { return }
        if entered { view.mouseEntered(with: event) } else { view.mouseExited(with: event) }
    }
    @MainActor static func sentPills(in pane: ConversationPaneTests.Pane) -> [SkillPillButton] {
        ConversationPaneTests.views(SkillPillButton.self, in: pane.hosted).filter { !($0 is ComposerSkillToken) }
    }
    @MainActor static func row(_ id: String, in pane: ConversationPaneTests.Pane) -> TranscriptRowContainer? {
        ConversationPaneTests.views(TranscriptRowContainer.self, in: pane.hosted).first { $0.itemID == id }
    }
    /// Where the editor draws a character, in its own coordinates.
    @MainActor static func glyphRect(_ index: Int, in editor: NSTextView) -> CGRect {
        guard let layout = editor.layoutManager, let container = editor.textContainer else { return .zero }
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        return rect.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
    }
    @MainActor func waitFor(_ what: String, seconds: Double = 10, pane: ConversationPaneTests.Pane? = nil,
                            file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            pane?.draw()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(what, file: file, line: line)
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            SkillPopovers.shared.close()
            SkillPopovers.shared.card.delay = PiHoverCardPresenter.delay
            SkillPopovers.shared.openFile = { NSWorkspace.shared.open($0) }
            SkillPopovers.shared.revealFile = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        }
        super.tearDown()
    }

    // MARK: The wire: the skills a message was sent with reach the app

    private static let sorted: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
    }()
    private func wire(_ object: Any) throws -> WireValue {
        try JSONDecoder().decode(WireValue.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// The helper's display row carries the skills a user message was sent
    /// with; the direct projector reads them exactly as Codable does, and a
    /// row it is unsure of falls back to Codable's answer.
    func testDisplayRowsCarryTheSkillsTheMessageWasSentWith() throws {
        let full: [String: Any] = ["id": "id-review", "name": "review", "path": "/p/.agents/skills/review/SKILL.md", "contentHash": "3f2a9c1e77",
                                   "metadataHash": "m1", "arguments": "focus on tests", "description": "Review the diff",
                                   "scope": "project", "policy": "explicitOnly"]
        let bare: [String: Any] = ["id": "id-plan", "name": "plan", "path": "", "contentHash": "", "metadataHash": "", "arguments": ""]
        let rows: [(String, [String: Any])] = [
            ("two skills", ["id": "u1", "role": "user", "text": "Go", "skills": [full, bare]]),
            ("optional fields null", ["id": "u2", "role": "user", "text": "", "skills": [bare.merging(["description": NSNull(), "scope": NSNull(), "policy": NSNull()]) { $1 }]]),
            ("no skills key", ["id": "u3", "role": "user", "text": "Plain"]),
            ("skills null", ["id": "u4", "role": "user", "text": "Plain", "skills": NSNull()]),
            ("empty skills", ["id": "u5", "role": "user", "text": "Plain", "skills": []]),
        ]
        for (what, row) in rows {
            let value = try wire([row])
            let projected = try TranscriptMessage.projected(value)
            let decoded = try JSONDecoder().decode([TranscriptMessage].self, from: JSONEncoder().encode(value))
            XCTAssertEqual(projected, decoded, what)
            XCTAssertEqual(try Self.sorted.encode(projected), try Self.sorted.encode(decoded), what + " (bytes)")
        }
        let page = try TranscriptMessage.page(try wire([rows[0].1]))
        let skills = try XCTUnwrap(page.first?.skills)
        XCTAssertEqual(skills.map(\.name), ["review", "plan"], "In the order the model received them")
        XCTAssertEqual(skills[0], TranscriptSkillUse(id: "id-review", name: "review", path: "/p/.agents/skills/review/SKILL.md", contentHash: "3f2a9c1e77",
                                                     metadataHash: "m1", arguments: "focus on tests", description: "Review the diff",
                                                     scope: "project", policy: "explicitOnly"))
        XCTAssertNil(skills[1].description)
        XCTAssertNil(try TranscriptMessage.page(try wire([rows[2].1])).first?.skills)

        let declined: [(String, Any)] = [
            ("skills is not a list", [["id": "u", "role": "user", "text": "t", "skills": ["id": "x"]]]),
            ("a skill without a name", [["id": "u", "role": "user", "text": "t", "skills": [["id": "x", "path": "", "contentHash": "", "metadataHash": "", "arguments": ""]]]]),
            ("arguments of another type", [["id": "u", "role": "user", "text": "t", "skills": [bare.merging(["arguments": 7]) { $1 }]]]),
        ]
        for (what, object) in declined {
            let value = try wire(object)
            XCTAssertThrowsError(try TranscriptMessage.projected(value), what)
            let fallback = try? TranscriptMessage.page(value)
            let reference = try? JSONDecoder().decode([TranscriptMessage].self, from: JSONEncoder().encode(value))
            XCTAssertEqual(fallback, reference, what + ": the fallback answers exactly what Codable answers")
        }
    }

    /// A journal read without the helper — an archived or imported chat —
    /// shows the same pills: the recorded selection is read leniently, and a
    /// damaged entry is left out rather than failing the page.
    func testJournalRowsCarryTheRecordedSkills() async throws {
        let recorded: WireValue = .object(["version": .number(1), "attachments": .array([]), "skills": .array([
            .object(["id": .string("id-review"), "name": .string("review"), "path": .string("/p/.agents/skills/review/SKILL.md"),
                     "contentHash": .string("3f2a9c1e77"), "metadataHash": .string("m1"), "arguments": .string("focus"), "intent": .string("picker"),
                     "description": .string("Review the diff"), "scope": .string("project"), "policy": .string("explicitOnly")]),
            .object(["id": .string("id-old"), "name": .string("old"), "path": .string("/Users/x/.codex/skills/old/SKILL.md"),
                     "contentHash": .string("aa"), "metadataHash": .string("bb"), "arguments": .string(""), "intent": .string("picker")]),
            .object(["id": .string("id-broken")]),
            .string("not a skill"),
        ])])
        let message: [String: WireValue] = ["role": .string("user"), "content": .array([.object(["type": .string("text"), "text": .string("Explicit user skill selection …\n\nShip it")])]),
                                            "nativeDisplayText": .string("Ship it"), "nativeUserInput": recorded]
        let row = TranscriptMessage.project(id: "u1", message: message)
        XCTAssertEqual(row.text, "Ship it", "The row shows what was typed, not the expanded skill bodies")
        XCTAssertEqual(row.skills?.map(\.name), ["review", "old"])
        XCTAssertEqual(row.skills?.first?.description, "Review the diff")
        XCTAssertNil(row.skills?.last?.description, "Journals before 0.1.86 did not record a description")
        XCTAssertNil(TranscriptMessage.project(id: "a1", message: ["role": .string("assistant"), "content": .string("Done"), "nativeUserInput": recorded]).skills,
                     "Only a user message carries skills")
        XCTAssertNil(TranscriptMessage.project(id: "u2", message: ["role": .string("user"), "content": .string("Plain")]).skills)

        // The same row through the history reader, from a file on disk.
        let folder = scratchRoot("skill-journal")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("chat.jsonl")
        var lines = [Data("{\"type\":\"session\",\"version\":3,\"id\":\"journal\"}".utf8)]
        lines.append(try JSONEncoder().encode(WireValue.object(["type": .string("message"), "id": .string("u1"), "parentId": .null, "message": .object(message)])))
        lines.append(try JSONEncoder().encode(WireValue.object(["type": .string("message"), "id": .string("a1"), "parentId": .string("u1"),
                                                                "message": .object(["role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string("Shipped")])])])])))
        try Data(lines.map { $0 + Data([10]) }.joined()).write(to: path)
        let page = try await HistoryReader().read(path: path.path)
        let user = try XCTUnwrap(page.messages.first { $0.id == "u1" })
        XCTAssertEqual(user.skills?.map(\.name), ["review", "old"])
        XCTAssertEqual(user.skills?.first?.arguments, "focus")
        XCTAssertNil(page.messages.first { $0.id == "a1" }?.skills)
    }

    // MARK: The token model

    /// The card sits above its pill while the window has the room there,
    /// below it while the window has the room there, and on the screen always.
    func testHoverCardStaysInItsWindowWhereItCan() {
        let size = CGSize(width: 316, height: 128), m = PiHoverCardPresenter.shadowMargin, gap = PiHoverCardPresenter.gap
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900), window = CGRect(x: 200, y: 100, width: 900, height: 700)
        let low = PiHoverCardPresenter.frame(size: size, anchor: CGRect(x: 300, y: 150, width: 120, height: 18), window: window, visible: screen)
        XCTAssertEqual(low.minY + m, 168 + gap, "Near the window's foot, above the pill")
        XCTAssertEqual(low.minX + m, 300, "lined up with it")
        let high = PiHoverCardPresenter.frame(size: size, anchor: CGRect(x: 300, y: 740, width: 120, height: 18), window: window, visible: screen)
        XCTAssertEqual(high.maxY - m, 740 - gap, "Near the window's top, below it, rather than over the title bar")
        let edge = PiHoverCardPresenter.frame(size: size, anchor: CGRect(x: 1400, y: 400, width: 30, height: 18), window: window, visible: screen)
        XCTAssertLessThanOrEqual(edge.maxX, screen.maxX, "Never off the screen")
    }

    /// Tokens flow like words: along the first line, onto the next when one
    /// does not fit, one wider than the line cut to it; the text begins after
    /// the last token, or on a line of its own when too little room is left.
    func testTokenLayoutFlowsLikeWordsAndLeavesTheTextItsLine() {
        XCTAssertTrue(ComposerTokenLayout.place(widths: [], containerWidth: 400, padding: 5).isEmpty)
        let row = ComposerTokenLayout.place(widths: [120, 60], containerWidth: 400, padding: 5)
        XCTAssertEqual(row.frames, [CGRect(x: 5, y: 2, width: 120, height: 18), CGRect(x: 129, y: 2, width: 60, height: 18)])
        XCTAssertEqual(row.textOffset, 0, "The text begins on the tokens' own line")
        XCTAssertEqual(row.exclusion, CGRect(x: 0, y: 0, width: 190, height: 20), "The line's first 190 points are the tokens'")
        XCTAssertEqual(row.textStart, 195)
        XCTAssertEqual(row.rows, 1)

        let wrapped = ComposerTokenLayout.place(widths: [120, 60], containerWidth: 160, padding: 5)
        XCTAssertEqual(wrapped.frames[1], CGRect(x: 5, y: 22, width: 60, height: 18), "A token that does not fit starts the next row")
        XCTAssertEqual(wrapped.textOffset, 20, "The text moves down one row, onto the last token's")
        XCTAssertEqual(wrapped.exclusion?.width, 66)
        XCTAssertEqual(wrapped.rows, 2)

        let full = ComposerTokenLayout.place(widths: [150], containerWidth: 200, padding: 5)
        XCTAssertEqual(full.textOffset, 20, "Too little room after the last token: the text starts below it")
        XCTAssertNil(full.exclusion)
        XCTAssertEqual(full.textStart, 5)

        let wide = ComposerTokenLayout.place(widths: [900], containerWidth: 200, padding: 5)
        XCTAssertEqual(wide.frames, [CGRect(x: 5, y: 2, width: 190, height: 18)], "A token wider than the line is cut to it")
        XCTAssertEqual(wide.textOffset, 20)
    }

    /// Backspace with the caret at the very start of the text removes the
    /// last token, as one undo step; anywhere else it deletes text as ever.
    @MainActor func testBackspaceAtTheStartRemovesTheLastTokenAsOneUndoStep() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = ComposerTextView(frame: window.contentView!.bounds)
        editor.isRichText = false; editor.allowsUndo = true; editor.sessionID = "a"
        window.contentView?.addSubview(editor); window.makeFirstResponder(editor)
        let view = SessionDisplay(id: "a"), a = Self.chip("release-checklist"), b = Self.chip("review")
        var saves = 0
        editor.skillStrip.display = view; editor.skillStrip.changed = { saves += 1 }
        view.skills = [a, b]; editor.skillTokens = view.skills
        view.draft = "hello"; editor.string = "hello"
        XCTAssertEqual(editor.skillTokenViews.map(\.chip.id), [a.id, b.id])

        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "helo", "Away from the start, Backspace deletes text")
        XCTAssertEqual(view.skills.count, 2)
        Self.freshUndo(editor)

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.deleteBackward(nil)
        XCTAssertEqual(view.skills, [a], "At the start, Backspace removes the last token")
        XCTAssertEqual(editor.skillTokenViews.map(\.chip.id), [a.id])
        XCTAssertEqual(editor.string, "helo", "and leaves the text alone")
        XCTAssertEqual(saves, 1, "The draft is saved like any edit")
        editor.undoManager?.undo()
        XCTAssertEqual(view.skills, [a, b], "One undo brings the token back")
        XCTAssertEqual(editor.skillTokenViews.count, 2)
        XCTAssertEqual(editor.string, "helo")
        editor.undoManager?.redo()
        XCTAssertEqual(view.skills, [a])
        editor.undoManager?.undo()
        XCTAssertEqual(view.skills, [a, b])
        XCTAssertFalse(editor.undoManager?.canUndo ?? true, "The removal was one step, and nothing else was in it")

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.deleteWordBackward(nil)
        XCTAssertEqual(view.skills, [a], "Option-Backspace at the start removes a token too")

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertFalse(editor.removeLastSkillToken(), "An open composition is the input method's, not the tokens'")
        XCTAssertEqual(view.skills, [a])
        editor.unmarkText()

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("skill-copy-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let token = try XCTUnwrap(editor.skillTokenViews.first)
        token.pasteboard = pasteboard
        token.copy(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "/release-checklist", "Copying a token copies its /name")
    }

    /// The draft is saved and restored with its tokens, and what is sent is
    /// exactly what was sent before the tokens were drawn inline.
    @MainActor func testDraftRoundTripAndSendPayloadAreUnchanged() throws {
        var chip = Self.chip("release-checklist", arguments: "focus on notarization")
        XCTAssertEqual(chip.description, "Walk through the release preflight before tagging", "The token keeps what the catalog said")
        XCTAssertEqual(chip.wire, .object(["id": .string(chip.id), "contentHash": .string(chip.contentHash), "metadataHash": .string(chip.metadataHash),
                                           "arguments": .string("focus on notarization"), "intent": .string("picker")]),
                       "The selection sent is the five fields it always was, and nothing the token only shows")
        let params = WorkspaceModel.editTurnParams(messageID: "m", text: "Tag it", turnID: "t", attachments: [], skills: [chip])
        XCTAssertEqual(params["skills"], .array([chip.wire]))
        XCTAssertEqual(params["text"], .string("Tag it"), "The text is the text: no token was ever part of it")

        let display = SessionDisplay(id: "chat")
        display.draft = "Tag the release once both pass."
        display.skills = [chip, Self.chip("review")]
        let saved = try JSONDecoder().decode(DraftRecord.self, from: JSONEncoder().encode(display.savedDraft))
        let restored = SessionDisplay(id: "chat")
        restored.restoreDraft(saved)
        XCTAssertEqual(restored.draft, display.draft)
        XCTAssertEqual(restored.skills, display.skills, "Every token comes back, with its arguments and description")

        // A draft saved before tokens carried their descriptions still restores.
        chip.description = nil; chip.scope = nil; chip.policy = nil; chip.sourceRoot = nil
        let old = #"{"id":"chat","text":"t","skills":[{"id":"\#(chip.id)","name":"release-checklist","path":"\#(chip.path)","contentHash":"\#(chip.contentHash)","metadataHash":"\#(chip.metadataHash)","arguments":"focus on notarization","intent":"picker"}]}"#
        let legacy = try JSONDecoder().decode(DraftRecord.self, from: Data(old.utf8))
        XCTAssertEqual(legacy.skills, [chip])
    }

    // MARK: What a pill says

    /// A sent message's pill is compared with the skill as installed now.
    func testChangedSinceThisMessageAndNoLongerInstalled() {
        let sent = Self.use("release-checklist", hash: "3f2a9c1e77ab01cd")
        let same = SkillDetail.sent(sent, catalog: Self.catalog([Self.descriptor("release-checklist", hash: "3f2a9c1e77ab01cd")]))
        XCTAssertEqual(same.revision, .current)
        XCTAssertEqual(same.revisionNote?.text, "Unchanged since this message"); XCTAssertEqual(same.revisionNote?.warns, false)

        let changed = SkillDetail.sent(sent, catalog: Self.catalog([Self.descriptor("release-checklist", hash: "77ab01cd3f2a9c1e")]))
        XCTAssertEqual(changed.revision, .changed(now: "77ab01cd"))
        XCTAssertEqual(changed.revisionNote?.text, "Changed since this message: the reply used the earlier version")
        XCTAssertEqual(changed.revisionNote?.warns, true)
        XCTAssertEqual(changed.version, "3f2a9c1e", "The version shown is the one the reply used")

        let removed = SkillDetail.sent(sent, catalog: Self.catalog([Self.descriptor("review")]))
        XCTAssertEqual(removed.revision, .removed)
        XCTAssertEqual(removed.revisionNote?.text, "No longer installed: this skill is not in the current skill list")
        XCTAssertTrue(removed.accessibilityHelp.contains("No longer installed"), "What the card warns of is read out too")

        XCTAssertEqual(SkillDetail.sent(sent, catalog: Self.catalog([Self.descriptor("review")], state: .partial)).revision, .unknown,
                       "A partial list cannot say a skill is gone: its source may be the one that failed")
        XCTAssertEqual(SkillDetail.sent(sent, catalog: Self.catalog([], state: .failed)).revision, .unknown)
        XCTAssertNil(SkillDetail.sent(sent, catalog: Self.catalog([], state: .failed)).revisionNote)
        XCTAssertEqual(SkillDetail.sent(sent, catalog: SkillCatalog()).revision, .unknown, "Nobody has asked for the list yet")
        var reading = SkillCatalog(); reading.notice = "Discovering skills…"
        XCTAssertEqual(SkillDetail.sent(sent, catalog: reading).revision, .checking)
        XCTAssertEqual(SkillDetail.sent(sent, catalog: reading).revisionNote?.text, "Checking the current skill list…")

        // The composer's tokens: changed since they were selected.
        let token = Self.chip("release-checklist")
        XCTAssertNil(SkillDetail.composer(token, catalog: Self.catalog([Self.descriptor("release-checklist")])).revisionNote)
        XCTAssertEqual(SkillDetail.composer(token, catalog: Self.catalog([Self.descriptor("release-checklist", hash: "ffff")])).revisionNote?.warns, true)
        XCTAssertEqual(SkillDetail.composer(token, catalog: Self.catalog([])).revisionNote?.text, "No longer installed. Remove it before sending.")

        // What was recorded comes first; the catalog fills in for older journals.
        var old = sent; old.description = nil; old.policy = nil; old.scope = nil
        let current = Self.descriptor("release-checklist", description: "The current description", scope: "project", policy: "implicitAllowed")
        let filled = SkillDetail.sent(old, catalog: Self.catalog([current]))
        XCTAssertEqual(filled.description, "The current description")
        XCTAssertEqual(filled.policyTitle, "Implicit allowed")
        XCTAssertEqual(SkillDetail.sent(sent, catalog: Self.catalog([current])).description, "Walk through the release preflight before tagging")
    }

    /// Scope and policy, in words.
    func testScopeAndPolicyInWords() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let project = SkillPlace.of(scope: "project", path: "/work/pay/.agents/skills/review/SKILL.md")
        XCTAssertEqual(project.kind, .project); XCTAssertEqual(project.title, "Project skill")
        XCTAssertEqual(project.location, "pay/.agents/skills"); XCTAssertEqual(project.file("/work/pay/.agents/skills/review/SKILL.md"), "review/SKILL.md")
        XCTAssertEqual(project.sentence, "Project skill · pay/.agents/skills")
        let personal = SkillPlace.of(scope: "user", path: home + "/.agents/skills/plan/SKILL.md", sourceRoot: home + "/.agents/skills")
        XCTAssertEqual(personal.kind, .personal); XCTAssertEqual(personal.location, "~/.agents/skills")
        let codex = SkillPlace.of(scope: "user", path: home + "/.codex/skills/review/SKILL.md", sourceRoot: home + "/.codex/skills")
        XCTAssertEqual(codex.kind, .codex); XCTAssertEqual(codex.title, "Codex skill"); XCTAssertEqual(codex.location, "~/.codex/skills")
        XCTAssertEqual(SkillPlace.of(scope: "approved additional", path: "/opt/skills/x/SKILL.md").kind, .added)
        // Records without a scope are placed from their path.
        XCTAssertEqual(SkillPlace.of(scope: nil, path: home + "/.agents/skills/plan/SKILL.md").kind, .personal)
        XCTAssertEqual(SkillPlace.of(scope: nil, path: "/Users/x/.codex/skills/review/SKILL.md").kind, .codex)
        XCTAssertEqual(SkillPlace.of(scope: nil, path: "/work/pay/.agents/skills/review/SKILL.md").kind, .project)
        XCTAssertEqual(SkillPlace.of(scope: nil, path: "/somewhere/SKILL.md").kind, .file)

        XCTAssertEqual(SkillPolicyWords.title("explicitOnly"), "Explicit only")
        XCTAssertEqual(SkillPolicyWords.detail("explicitOnly"), "Runs only when you select it")
        XCTAssertEqual(SkillPolicyWords.title("implicitAllowed"), "Implicit allowed")
        XCTAssertNil(SkillPolicyWords.title("something new"))

        let detail = SkillDetail.composer(Self.chip("review", arguments: "focus on tests"), catalog: SkillCatalog())
        XCTAssertEqual(detail.accessibilityLabel, "Skill review, explicit for this message")
        XCTAssertEqual(detail.accessibilityHelp, "Walk through the release preflight before tagging. Project skill · project/.agents/skills. Arguments: focus on tests")
        XCTAssertEqual(SkillPillLabel.arguments("focus on notarization and the appcast"), "focus on notarization…", "Cut at a word")
        XCTAssertEqual(SkillPillLabel.arguments(String(repeating: "x", count: 40)), String(repeating: "x", count: 23) + "…")
        XCTAssertEqual(SkillPillLabel.arguments("two\nlines"), "two lines")
    }

    // MARK: In a real window: the composer

    /// Two skills in a real composer: tokens inside the editor that lead the
    /// text on its first line, no row above it; typing, an input method's
    /// marked text and Backspace behave.
    @MainActor func testComposerLeadsItsTextWithInlineTokensAndNoSeparateRow() async throws {
        let pane = try ConversationPaneTests.Pane(); defer { pane.close() }
        await pane.settle(12)
        let editor = try XCTUnwrap(pane.editor)
        let field = try XCTUnwrap(editor.enclosingScrollView)
        let surface = try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeScrollView.self, in: pane.hosted).first)
        let conversation = surface.frame.height, empty = field.frame.height
        pane.session.skillCatalog = Self.catalog([Self.descriptor("release-checklist"), Self.descriptor("review")])
        pane.session.skills = [Self.chip("release-checklist", arguments: "focus on notarization"), Self.chip("review")]
        pane.session.draft = "Tag the release once both pass."
        await pane.settle(12)

        XCTAssertEqual(surface.frame.height, conversation, accuracy: 0.5, "No row of chips above the editor takes room from the conversation")
        XCTAssertEqual(field.frame.height, empty, accuracy: 0.5, "Two tokens and a short line still fit the one-line field")
        let tokens = editor.skillTokenViews
        XCTAssertEqual(tokens.map(\.chip.name), ["release-checklist", "review"])
        XCTAssertTrue(tokens.allSatisfy { $0.superview === editor }, "The tokens are drawn inside the editor")
        let lineStart = editor.textContainerOrigin.x + (editor.textContainer?.lineFragmentPadding ?? 0)
        XCTAssertEqual(tokens[0].frame.minX, lineStart, accuracy: 0.5, "The first token stands where the text would begin")
        XCTAssertEqual(tokens[0].frame.midY, tokens[1].frame.midY, accuracy: 0.5, "on the first line, beside the second")
        let first = Self.glyphRect(0, in: editor)
        XCTAssertGreaterThan(first.minX, tokens[1].frame.maxX, "The typed text begins after the last token")
        XCTAssertLessThan(first.minX - tokens[1].frame.maxX, 12, "right after it, like the next word")
        XCTAssertEqual(first.midY, tokens[1].frame.midY, accuracy: 3, "on the tokens' line")
        XCTAssertEqual(editor.string, pane.session.draft, "The editor holds the draft and nothing else")
        XCTAssertEqual(tokens[1].accessibilityLabel(), "Skill review, explicit for this message")
        XCTAssertTrue(editor.accessibilityChildren()?.contains { ($0 as AnyObject) === tokens[0] } == true, "Assistive technology finds the tokens in the editor")

        // Typing goes on after them.
        pane.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        Self.key("!", code: 0, into: editor)
        await pane.settle(4)
        XCTAssertEqual(pane.session.draft, "Tag the release once both pass.!")
        XCTAssertEqual(pane.session.skills.count, 2)

        // An input method's composition at the very start is drawn, and its
        // candidates placed, after the tokens.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 0, length: 0))
        await pane.settle(4)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.skillTokenViews.count, 2)
        XCTAssertGreaterThan(Self.glyphRect(0, in: editor).minX, tokens[1].frame.maxX)
        let candidates = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        let tokenOnScreen = pane.window.convertToScreen(tokens[1].convert(tokens[1].bounds, to: nil))
        XCTAssertGreaterThan(candidates.minX, tokenOnScreen.maxX - 0.5, "The candidate window opens beside the composition, not over a token")
        editor.insertText("日本", replacementRange: NSRange(location: 0, length: 3))
        await pane.settle(6)
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(pane.session.draft, "日本Tag the release once both pass.!")

        // Backspace at the very start takes the last token, as one undo step.
        Self.freshUndo(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        Self.key("\u{7f}", code: 51, into: editor)
        await pane.settle(4)
        XCTAssertEqual(pane.session.skills.map(\.name), ["release-checklist"])
        XCTAssertEqual(editor.skillTokenViews.map(\.chip.name), ["release-checklist"])
        XCTAssertEqual(pane.session.draft, "日本Tag the release once both pass.!", "and not a character of the text")
        editor.undoManager?.undo()
        await pane.settle(4)
        XCTAssertEqual(pane.session.skills.map(\.name), ["release-checklist", "review"])
        XCTAssertEqual(editor.skillTokenViews.count, 2)
        XCTAssertEqual(pane.session.draft, "日本Tag the release once both pass.!")
        XCTAssertFalse(editor.undoManager?.canUndo ?? true, "The removal was one undo step")
    }

    /// In a narrow composer the tokens wrap like words, the text goes on
    /// after the last of them, and they return to one line when there is room.
    @MainActor func testNarrowComposerWrapsTokensLikeWords() async throws {
        let pane = try ConversationPaneTests.Pane(width: 440, height: 420); defer { pane.close() }
        await pane.settle(12)
        let editor = try XCTUnwrap(pane.editor)
        let field = try XCTUnwrap(editor.enclosingScrollView)
        pane.session.skills = [Self.chip("release-checklist", arguments: "focus on notarization"), Self.chip("review"), Self.chip("summarize-changes")]
        pane.session.draft = "Tag it."
        await pane.settle(12)
        let tokens = editor.skillTokenViews
        XCTAssertEqual(Set(tokens.map { $0.frame.minY.rounded() }).count, 2, "The tokens wrap onto a second row")
        let lineStart = editor.textContainerOrigin.x + (editor.textContainer?.lineFragmentPadding ?? 0)
        XCTAssertEqual(tokens[2].frame.minX, lineStart, accuracy: 0.5, "The one that did not fit begins the next row")
        let first = Self.glyphRect(0, in: editor)
        XCTAssertGreaterThan(first.minX, tokens[2].frame.maxX, "The text goes on after the last token")
        XCTAssertEqual(first.midY, tokens[2].frame.midY, accuracy: 3, "on its row")
        XCTAssertGreaterThanOrEqual(field.frame.height, 54 - 0.5, "The field grew by the row the tokens took")
        XCTAssertTrue(tokens.allSatisfy { editor.bounds.contains($0.frame) }, "Every token is inside the editor")

        // Fewer tokens: the text returns to the first line and the field to one line.
        let all = pane.session.skills
        pane.session.skills = [all[0]]
        await pane.settle(12)
        XCTAssertEqual(editor.skillTokenViews.count, 1)
        XCTAssertEqual(field.frame.height, 44, accuracy: 0.5, "The field gives the row back")
        XCTAssertGreaterThan(Self.glyphRect(0, in: editor).minX, editor.skillTokenViews[0].frame.maxX)
        XCTAssertEqual(Self.glyphRect(0, in: editor).midY, editor.skillTokenViews[0].frame.midY, accuracy: 3)

        pane.session.skills = all
        pane.window.setContentSize(NSSize(width: 1_000, height: 420))
        await pane.settle(12)
        XCTAssertEqual(Set(editor.skillTokenViews.map { $0.frame.minY.rounded() }).count, 1, "With room, they share one line again")
        XCTAssertGreaterThan(Self.glyphRect(0, in: editor).minX, editor.skillTokenViews[2].frame.maxX)
        XCTAssertEqual(field.frame.height, 44, accuracy: 0.5)
    }

    // MARK: In a real window: the transcript

    /// A sent message shows the skills it used as pills at the start of its
    /// bubble, ahead of the text, and the bubble is exactly one pill row and
    /// a gap taller than the same message without them.
    @MainActor func testSentMessageShowsItsSkillsAsPillsLeadingTheBubble() async throws {
        var user = TranscriptMessage(id: "u1", role: "user", text: "Tag it.", at: 1_000, turn: "u1")
        user.skills = [Self.use("release-checklist", arguments: "focus on notarization"), Self.use("review")]
        let reply = TranscriptMessage(id: "a1", role: "assistant", text: "Tagged.", state: "complete", at: 2_000, turn: "u1")
        let plain = TranscriptMessage(id: "u2", role: "user", text: "Tag it.", at: 3_000, turn: "u2")
        let answer = TranscriptMessage(id: "a2", role: "assistant", text: "Done.", state: "complete", at: 4_000, turn: "u2")
        let pane = try ConversationPaneTests.Pane(messages: [user, reply, plain, answer]); defer { pane.close() }
        await pane.settle(20)
        let pills = Self.sentPills(in: pane)
        XCTAssertEqual(pills.map { $0.accessibilityLabel() }, ["Skill release-checklist, explicit for this message", "Skill review, explicit for this message"])
        XCTAssertTrue(pills[0].accessibilityHelp()?.contains("focus on notarization") == true, "The card's content is read out with the pill")
        let row = try XCTUnwrap(Self.row("u1", in: pane)), other = try XCTUnwrap(Self.row("u2", in: pane))
        XCTAssertEqual(row.frame.height - other.frame.height, SkillPillFace.height + MessageRowView.skillGap, accuracy: 0.5,
                       "The pills take one row and a gap ahead of the same text")
        let rowFrame = row.convert(row.bounds, to: nil)
        let frames = pills.map { $0.convert($0.bounds, to: nil) }
        XCTAssertTrue(frames.allSatisfy { rowFrame.contains($0) }, "The pills are in the message's own row")
        XCTAssertEqual(frames[0].midY, frames[1].midY, accuracy: 0.5, "side by side")
        XCTAssertLessThan(frames[0].minX, frames[1].minX)
        XCTAssertLessThan(rowFrame.maxY - frames[0].maxY, 30, "at the top of the bubble")
        XCTAssertEqual(frames[0].height, SkillPillFace.height, accuracy: 0.5)
        XCTAssertEqual(row.hostedFittingHeight, row.frame.height, accuracy: 0.5, "The row holds exactly what it measured")

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("skill-copy-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pills[1].pasteboard = pasteboard
        pills[1].copy(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "/review")
    }

    /// A message with pills arriving at the end of a conversation is drawn at
    /// its final height the first time: it never grows after it appears, and
    /// nothing above it moves. That holds through the hand-over from the row
    /// the app draws on Return (built from the composer's tokens) to the
    /// helper's row for the same message.
    @MainActor func testAMessageWithPillsArrivesAtItsFinalHeight() async throws {
        let first = TranscriptMessage(id: "u0", role: "user", text: "Look at the release.", at: 1_000, turn: "u0")
        let reply = TranscriptMessage(id: "a0", role: "assistant", text: "It is ready to tag.", state: "complete", at: 2_000, turn: "u0")
        let pane = try ConversationPaneTests.Pane(messages: [first, reply]); defer { pane.close() }
        await pane.settle(20)
        let before = try XCTUnwrap(Self.row("u0", in: pane)).frame, answered = try XCTUnwrap(Self.row("block:a0", in: pane)).frame
        // What the app has on Return: the composer's tokens.
        let chips = [Self.chip("release-checklist", arguments: "focus on notarization and the appcast"), Self.chip("review"), Self.chip("summarize-changes")]
        var drawn = TranscriptMessage(id: "u9", role: "user", text: "Tag it now, and write the notes.", at: 3_000, turn: "u9")
        drawn.skills = chips.map(TranscriptSkillUse.init(chip:))
        // What the helper records for the same message.
        var recorded = drawn
        recorded.skills = chips.map { chip in
            TranscriptSkillUse(id: chip.id, name: chip.name, path: chip.path, contentHash: chip.contentHash, metadataHash: chip.metadataHash,
                               arguments: chip.arguments, description: chip.description, scope: chip.scope, policy: chip.policy)
        }
        recorded.state = "complete"
        var heights: [CGFloat] = []
        func watch(_ passes: Int) async throws {
            for _ in 0..<passes {
                pane.draw()
                if let row = Self.row("u9", in: pane), row.frame.height > 1 { heights.append(row.frame.height) }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        pane.session.messages = pane.session.messages + [drawn]
        try await watch(30)
        pane.session.messages = Array(pane.session.messages.dropLast()) + [recorded]
        try await watch(30)
        XCTAssertFalse(heights.isEmpty, "The message arrived")
        XCTAssertEqual(Set(heights.map { ($0 * 2).rounded() }).count, 1, "The row kept one height from the moment it appeared: \(Set(heights))")
        let row = try XCTUnwrap(Self.row("u9", in: pane))
        XCTAssertEqual(row.hostedFittingHeight, row.frame.height, accuracy: 0.5, "and it is the height its content needs")
        XCTAssertEqual(Self.sentPills(in: pane).count, 3)
        XCTAssertEqual(try XCTUnwrap(Self.row("u0", in: pane)).frame, before, "The rows above did not move")
        XCTAssertEqual(try XCTUnwrap(Self.row("block:a0", in: pane)).frame, answered)
        print("PERF skill-pill row: \(row.measurementCount) measurement(s), height \(row.frame.height)")
    }

    // MARK: In a real window: hover and press

    /// The card appears once the pointer has rested on a pill for about 450
    /// ms, takes no focus, and leaves with the pointer.
    @MainActor func testHoverShowsTheCardAfterTheDelayAndHidesItOnExit() async throws {
        var user = TranscriptMessage(id: "u1", role: "user", text: "Tag it.", at: 1_000, turn: "u1")
        user.skills = [Self.use("release-checklist", arguments: "focus on notarization")]
        let pane = try ConversationPaneTests.Pane(messages: [user, TranscriptMessage(id: "a1", role: "assistant", text: "Tagged.", state: "complete", at: 2_000, turn: "u1")])
        defer { pane.close() }
        pane.session.skillCatalog = Self.catalog([Self.descriptor("release-checklist")])
        pane.session.skills = [Self.chip("review")]
        await pane.settle(20)
        let editor = try XCTUnwrap(pane.editor)
        pane.window.makeFirstResponder(editor)
        let card = SkillPopovers.shared.card
        let pill = try XCTUnwrap(Self.sentPills(in: pane).first)

        let start = ProcessInfo.processInfo.systemUptime
        Self.pointer(true, over: pill)
        XCTAssertTrue(card.isWaiting); XCTAssertFalse(card.isShown)
        try await Task.sleep(for: .milliseconds(250)); pane.draw()
        if ProcessInfo.processInfo.systemUptime - start < 0.4 { XCTAssertFalse(card.isShown, "Nothing shows before the pointer has rested") }
        try await waitFor("The card did not appear", seconds: 3, pane: pane) { card.isShown }
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - start, 0.44, "It waited for the pointer to rest")
        let panel = try XCTUnwrap(card.panel)
        XCTAssertFalse(panel.canBecomeKey); XCTAssertFalse(panel.canBecomeMain); XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(pane.window.firstResponder === editor, "The card takes no focus: the composer keeps it")
        XCTAssertTrue(panel.parent === pane.window, "It rides on the window it describes")
        let pillOnScreen = pane.window.convertToScreen(pill.convert(pill.bounds, to: nil))
        XCTAssertTrue(panel.frame.maxY <= pillOnScreen.minY + PiHoverCardPresenter.shadowMargin || panel.frame.minY >= pillOnScreen.maxY - PiHoverCardPresenter.shadowMargin,
                      "It sits above or below the pill, not over it")
        XCTAssertLessThanOrEqual(abs(panel.frame.minX + PiHoverCardPresenter.shadowMargin - pillOnScreen.minX), 1, "and lines up with it")
        Self.pointer(false, over: pill)
        XCTAssertFalse(card.isShown, "The card leaves with the pointer"); XCTAssertNil(card.panel)

        // A pointer that passes over without resting shows nothing.
        Self.pointer(true, over: pill)
        try await Task.sleep(for: .milliseconds(150))
        Self.pointer(false, over: pill)
        try await Task.sleep(for: .milliseconds(500)); pane.draw()
        XCTAssertFalse(card.isShown)

        // A composer token has its card too, and typing sends it away.
        let token = try XCTUnwrap(editor.skillTokenViews.first)
        Self.pointer(true, over: token)
        try await waitFor("The token's card did not appear", seconds: 3, pane: pane) { card.isShown }
        XCTAssertTrue(card.anchorView === token)
        XCTAssertTrue(pane.window.firstResponder === editor)
        Self.pointer(false, over: token)
        XCTAssertFalse(card.isShown)
    }

    /// A press opens the pill's popover — the composer's with Edit Arguments
    /// and Remove, a sent message's with Open and Reveal in Finder — and
    /// Escape closes it. The keyboard reaches the tokens too.
    @MainActor func testPressOpensThePopoverWithItsActionsAndEscapeClosesIt() async throws {
        let folder = scratchRoot("skill-file")
        let skillFolder = folder.appendingPathComponent(".agents/skills/release-checklist")
        try FileManager.default.createDirectory(at: skillFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = skillFolder.appendingPathComponent("SKILL.md")
        try Data("---\nname: release-checklist\ndescription: Walk through the release preflight before tagging\n---\nCheck.\n".utf8).write(to: file)
        var use = Self.use("release-checklist"); use.path = file.path
        var user = TranscriptMessage(id: "u1", role: "user", text: "Tag it.", at: 1_000, turn: "u1")
        user.skills = [use]
        let pane = try ConversationPaneTests.Pane(messages: [user, TranscriptMessage(id: "a1", role: "assistant", text: "Tagged.", state: "complete", at: 2_000, turn: "u1")])
        defer { pane.close() }
        let installed = Self.descriptor("release-checklist", path: file.path)
        pane.session.skillCatalog = Self.catalog([installed])
        pane.session.skills = [installed.chip]
        await pane.settle(20)
        let popovers = SkillPopovers.shared
        var opened: [URL] = [], revealed: [URL] = []
        popovers.openFile = { opened.append($0) }; popovers.revealFile = { revealed.append($0) }
        let editor = try XCTUnwrap(pane.editor)
        func shown() async throws -> (detail: SkillDetail, actions: SkillPopoverActions) {
            try await waitFor("The popover did not open", pane: pane) { popovers.popover.popover?.isShown == true }
            await pane.settle(4)
            XCTAssertNotNil(popovers.popover.popover?.contentViewController?.view.window, "The popover is on screen")
            return try XCTUnwrap(popovers.presented)
        }
        func escape() async throws {
            try SessionStatsPopoverTests.escape(try XCTUnwrap(popovers.popover.popover?.contentViewController?.view.window))
            try await waitFor("Escape did not close the popover", pane: pane) { !popovers.popover.isShown }
        }

        // The composer's token: a click where the reader clicks.
        let token = try XCTUnwrap(editor.skillTokenViews.first)
        let center = token.convert(NSPoint(x: token.bounds.midX, y: token.bounds.midY), to: nil)
        XCTAssertTrue(pane.window.contentView?.superview?.hitTest(center) === token, "A click on the token lands on the token")
        token.performClick(nil)
        var open = try await shown()
        XCTAssertTrue(popovers.popover.anchorView === token, "The popover points at the token")
        XCTAssertEqual(open.detail.context, .composer)
        XCTAssertNotNil(open.actions.editArguments, "The composer's popover can edit the arguments")
        XCTAssertNotNil(open.actions.remove, "and remove the token")
        XCTAssertNotNil(open.actions.open, "and open the source file"); XCTAssertNotNil(open.actions.reveal)
        XCTAssertEqual(popovers.openKey, SkillPopovers.composerKey(sessionID: pane.session.id, skillID: installed.id))
        XCTAssertFalse(pane.window.firstResponder is SkillPillButton, "A click does not pull focus onto the token")
        try await escape()
        XCTAssertNil(popovers.openKey); XCTAssertNil(popovers.presented)

        // Edit Arguments…, from the popover: the existing editor, and the token shows them.
        let narrow = token.frame.width
        pane.model.questions.enterText = { title, value in
            XCTAssertEqual(title, "Arguments for /release-checklist"); XCTAssertEqual(value, "")
            return "focus on notarization"
        }
        token.performClick(nil)
        open = try await shown()
        open.actions.editArguments?()
        try await waitFor("Edit Arguments did not reach the token", pane: pane) { pane.session.skills.first?.arguments == "focus on notarization" }
        XCTAssertFalse(popovers.popover.isShown, "The popover makes way for the editor")
        await pane.settle(6)
        XCTAssertGreaterThan(try XCTUnwrap(editor.skillTokenViews.first).frame.width, narrow + 40, "The token now shows its arguments")

        // Remove, from the popover: the token goes, as one undo step.
        Self.freshUndo(editor)
        token.performClick(nil)
        open = try await shown()
        open.actions.remove?()
        try await waitFor("Remove did not remove the token", pane: pane) { pane.session.skills.isEmpty }
        XCTAssertFalse(popovers.popover.isShown, "The popover closes with its token")
        XCTAssertTrue(editor.skillTokenViews.isEmpty)
        editor.undoManager?.undo()
        await pane.settle(4)
        XCTAssertEqual(pane.session.skills.map(\.id), [installed.id], "Undo brings it back")

        // A sent message's pill: its source file, no editing.
        let pill = try XCTUnwrap(Self.sentPills(in: pane).first)
        pill.performClick(nil)
        open = try await shown()
        XCTAssertTrue(popovers.popover.anchorView === pill)
        XCTAssertEqual(open.detail.context, .sent)
        XCTAssertNil(open.actions.editArguments, "A sent message's skill is not edited")
        XCTAssertNil(open.actions.remove)
        XCTAssertEqual(popovers.openKey, SkillPopovers.sentKey(messageID: "u1", skillID: installed.id))
        XCTAssertEqual(open.detail.revisionNote?.text, "Unchanged since this message")
        open.actions.open?()
        try await waitFor("Open did nothing", pane: pane) { opened == [file] }
        XCTAssertFalse(popovers.popover.isShown)
        pill.performClick(nil)
        open = try await shown()
        open.actions.reveal?()
        try await waitFor("Reveal in Finder did nothing", pane: pane) { revealed == [file] }

        // A second press on the pill whose popover is open closes it.
        pill.performClick(nil)
        _ = try await shown()
        pill.performClick(nil)
        try await waitFor("A second press did not close the popover", pane: pane) { !popovers.popover.isShown }

        // The keyboard: Left at the very start moves onto the last token,
        // Space opens its popover, Escape closes it, Right returns to the text.
        pane.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        Self.key(String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!), code: 123, into: editor)
        let focused = try XCTUnwrap(editor.skillTokenViews.last)
        XCTAssertTrue(pane.window.firstResponder === focused, "Left at the start focuses the last token")
        Self.key(" ", code: 49, into: focused)
        _ = try await shown()
        try await escape()
        Self.key(String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!), code: 124, into: focused)
        XCTAssertTrue(pane.window.firstResponder === editor, "Right past the last token returns to the text")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
    }

    /// A sent message's skill that has changed since, or gone, says so.
    @MainActor func testTheSentPopoverSaysWhenTheSkillChangedOrWentAway() async throws {
        var user = TranscriptMessage(id: "u1", role: "user", text: "Tag it.", at: 1_000, turn: "u1")
        user.skills = [Self.use("release-checklist", hash: "3f2a9c1e77ab01cd"), Self.use("review")]
        let pane = try ConversationPaneTests.Pane(messages: [user, TranscriptMessage(id: "a1", role: "assistant", text: "Tagged.", state: "complete", at: 2_000, turn: "u1")])
        defer { pane.close() }
        pane.session.skillCatalog = Self.catalog([Self.descriptor("release-checklist", hash: "77ab01cd3f2a9c1e")])
        await pane.settle(20)
        let popovers = SkillPopovers.shared
        for (index, expected) in [(0, "Changed since this message: the reply used the earlier version"), (1, "No longer installed")] {
            let pill = Self.sentPills(in: pane)[index]
            pill.performClick(nil)
            try await waitFor("The popover did not open", pane: pane) { popovers.popover.popover?.isShown == true }
            await pane.settle(4)
            let note = try XCTUnwrap(popovers.presented?.detail.revisionNote)
            XCTAssertTrue(note.text.hasPrefix(expected), note.text)
            XCTAssertTrue(note.warns)
            popovers.close()
            await pane.settle(2)
        }
    }

    // MARK: Looks (opt-in captures for review)

    @MainActor func testCaptureSkillPillLooks() async throws {
        guard let path = testEnvironment("PI_APP_UI_SCREENSHOT_ROOT") else {
            throw XCTSkip("Set PI_APP_UI_SCREENSHOT_ROOT to render the skill pill captures.")
        }
        let folder = URL(fileURLWithPath: path).appendingPathComponent("screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var user = TranscriptMessage(id: "u1", role: "user", text: "Tag 0.1.86 once the checklist passes, and tell me what you changed.", at: 1_000, turn: "u1")
        user.skills = [Self.use("release-checklist", arguments: "focus on notarization and the appcast"), Self.use("review")]
        let reply = TranscriptMessage(id: "a1", role: "assistant", text: "The checklist passed. Signing, notarization and the appcast are in order.", state: "complete", at: 2_000, turn: "u1")
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let pane = try ConversationPaneTests.Pane(messages: [user, reply], width: 760, height: 520)
            defer { pane.close() }
            pane.window.appearance = NSAppearance(named: appearance)
            pane.session.skillCatalog = Self.catalog([Self.descriptor("release-checklist"), Self.descriptor("review", description: "Review the pending diff for correctness")])
            pane.session.skills = [Self.chip("release-checklist", arguments: "focus on notarization"), Self.chip("review")]
            pane.session.draft = "Tag the release once both pass."
            await pane.settle(20)
            try SessionStatsPopoverTests.capture(pane.window, to: folder.appendingPathComponent("skills-pane-\(name).png"))
            let token = try XCTUnwrap(pane.editor?.skillTokenViews.first)
            token.performClick(nil)
            await pane.settle(12)
            try SessionStatsPopoverTests.capture(pane.window, to: folder.appendingPathComponent("skills-popover-composer-\(name).png"))
            SkillPopovers.shared.close()
            await pane.settle(4)
            let pill = try XCTUnwrap(ConversationPaneTests.views(SkillPillButton.self, in: pane.hosted).first { !($0 is ComposerSkillToken) })
            pill.performClick(nil)
            await pane.settle(12)
            try SessionStatsPopoverTests.capture(pane.window, to: folder.appendingPathComponent("skills-popover-sent-\(name).png"))
            SkillPopovers.shared.close()
            SkillPopovers.shared.card.delay = .milliseconds(10)
            defer { SkillPopovers.shared.card.delay = PiHoverCardPresenter.delay }
            pill.setHovering(true)
            try await Task.sleep(for: .milliseconds(120)); await pane.settle(6)
            try captureWithPanels(pane.window, to: folder.appendingPathComponent("skills-card-\(name).png"))
            pill.setHovering(false)
            await pane.settle(4)

            let narrow = try ConversationPaneTests.Pane(messages: [user], width: 440, height: 420)
            defer { narrow.close() }
            narrow.window.appearance = NSAppearance(named: appearance)
            narrow.session.skills = [Self.chip("release-checklist", arguments: "focus on notarization"), Self.chip("review"), Self.chip("summarize-changes")]
            narrow.session.draft = "Tag the release once both pass, then summarise the changes for the notes."
            await narrow.settle(20)
            try SessionStatsPopoverTests.capture(narrow.window, to: folder.appendingPathComponent("skills-narrow-\(name).png"))
        }
    }

    /// The window and every panel of ours over it (the hover card is a child panel, not a popover).
    @MainActor func captureWithPanels(_ window: NSWindow, to url: URL) throws {
        typealias ArrayImage = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImageFromArray") else { throw XCTSkip("Window capture unavailable") }
        let create = unsafeBitCast(symbol, to: ArrayImage.self)
        let screen = NSScreen.screens.first?.frame ?? .zero
        let panels = NSApp.windows.filter { $0.isVisible && $0 != window && ($0 is PiHoverCardPanel || String(describing: type(of: $0)).contains("Popover")) }
        var frame = window.frame
        for panel in panels { frame = frame.union(panel.frame) }
        var ids = (panels + [window]).map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) }
        let array = try XCTUnwrap(ids.withUnsafeMutableBufferPointer { CFArrayCreate(nil, $0.baseAddress, $0.count, nil) })
        let bounds = CGRect(x: frame.minX, y: screen.height - frame.maxY, width: frame.width, height: frame.height)
        let options = CGWindowImageOption.bestResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue
        guard let image = create(bounds, array, options)?.takeRetainedValue() else { throw XCTSkip("Window capture returned no image") }
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: url, options: .atomic)
    }
}
