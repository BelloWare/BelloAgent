import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// An edited message's versions in the conversation: `‹ 2 / 2 ›` under the
/// edited message in place of the edit's marker row, an earlier version shown
/// read-only under a quiet banner with the way back, the latest version for
/// the composer and every send, and ⌥← and ⌥→ from the keyboard.
final class MessageVersionTranscriptTests: XCTestCase {
    /// `u1 a1`, then `u2` edited into `u2b` (reply `a2b`), with the marker row
    /// the edit left before `u2b`.
    static func editedRows(numbered: Bool = true) -> [TranscriptMessage] {
        var edited = TranscriptMessage(id: "u2b", role: "user", text: "Which retry budget, edited?", at: 3_000, turn: "u2b")
        if numbered { edited.versions = MessageVersionMark(index: 2, count: 2, ids: ["u2", "u2b"]) }
        var marker = TranscriptMessage(id: "branch-1", role: "system", text: "Edited from here · earlier replies stay in the journal", kind: "branch")
        marker.at = 2_500
        return [TranscriptMessage(id: "u1", role: "user", text: "First question", at: 1_000, turn: "u1"),
                TranscriptMessage(id: "a1", role: "assistant", text: "First answer.", state: "complete", at: 1_500, turn: "u1"),
                marker, edited,
                TranscriptMessage(id: "a2b", role: "assistant", text: "The edited answer.", state: "complete", at: 3_500, turn: "u2b")]
    }
    /// The requests of the first turn, of version 1 and of version 2.
    static let firstAttempt = "5A0C1F3E-1D2B-4C3A-8E9F-0A1B2C3D4E51", oldAttempt = "5A0C1F3E-1D2B-4C3A-8E9F-0A1B2C3D4E52",
               newAttempt = "5A0C1F3E-1D2B-4C3A-8E9F-0A1B2C3D4E53"
    /// Version 1 as the helper pages it: the original question and its reply,
    /// with the request the reply came from.
    static var versionOne: [TranscriptMessage] {
        var reply = TranscriptMessage(id: "a2", role: "assistant", text: "The original answer.", state: "complete", at: 2_200, turn: "u2")
        reply.reply = ReplyRecord(attempt: oldAttempt, requested: "pane-model")
        reply.requestAttemptIDs = [oldAttempt]
        return [TranscriptMessage(id: "u2", role: "user", text: "Which retry budget?", at: 2_000, turn: "u2"), reply]
    }

    @MainActor static func switchers(_ pane: ConversationPaneTests.Pane) -> [VersionSwitcherMarkerView] {
        ConversationPaneTests.views(VersionSwitcherMarkerView.self, in: pane.hosted)
    }
    @MainActor static func document(_ pane: ConversationPaneTests.Pane) throws -> TranscriptNativeDocument {
        try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeDocument.self, in: pane.hosted).first, "The transcript is on screen")
    }
    /// A pane whose earlier versions come from `versionOne`, as the helper would page them.
    @MainActor static func pane(_ rows: [TranscriptMessage] = editedRows()) async throws -> ConversationPaneTests.Pane {
        let pane = try ConversationPaneTests.Pane(messages: rows)
        let old = versionOne
        pane.model.versionPageLoader = { _, messageID in
            guard messageID == "u2" else { throw HostError.failure("No such version") }
            return (old, [])
        }
        await pane.settle(12)
        return pane
    }
    @MainActor static func shown(_ pane: ConversationPaneTests.Pane, version index: Int?) async {
        for _ in 0..<200 {
            if index == nil ? pane.session.versionView == nil : (pane.session.versionView?.index == index && pane.session.versionView?.loading == false) { break }
            await pane.settle(1)
        }
        await pane.settle(6)
    }

    /// Only the edited message carries the switcher, where the edit's marker
    /// row used to be; a marker the helper has not numbered still shows.
    @MainActor func testTheSwitcherAppearsOnlyOnEditedMessages() async throws {
        let pane = try await Self.pane(); defer { pane.close() }
        let switchers = Self.switchers(pane)
        XCTAssertEqual(switchers.map(\.messageID), ["u2b"], "One switcher, on the edited message")
        XCTAssertEqual(switchers.first?.mark, MessageVersionMark(index: 2, count: 2, ids: ["u2", "u2b"]))
        XCTAssertFalse(pane.session.presentedMessages.contains { $0.kind == "branch" }, "The switcher replaces the marker row")
        XCTAssertEqual(pane.session.presentedMessages.map(\.id), ["u1", "a1", "u2b", "a2b"])

        // An older helper numbers nothing: its marker row stays, and no switcher shows.
        pane.session.messages = Self.editedRows(numbered: false)
        await pane.settle(12)
        XCTAssertTrue(Self.switchers(pane).isEmpty)
        XCTAssertTrue(pane.session.presentedMessages.contains { $0.kind == "branch" })
    }

    /// ‹ shows version 1 in place of the latest: the banner, then the original
    /// question and its reply, read-only. Back to latest, or ›, returns.
    @MainActor func testAnEarlierVersionShowsReadOnlyUnderItsBannerAndReturnsToLatest() async throws {
        let pane = try await Self.pane(); defer { pane.close() }
        pane.session.draft = "A draft for the latest version"
        try Self.document(pane).actionRelay.forwarded.switchVersion?("u2b", -1)
        await Self.shown(pane, version: 1)
        let rows = pane.session.presentedMessages
        XCTAssertEqual(rows.map(\.id), ["u1", "a1", "version-banner:u2b", "u2", "a2"], "The latest version gives way to version 1 under its banner")
        XCTAssertEqual(rows.first { $0.id == "version-banner:u2b" }?.kind, "versionBanner")
        XCTAssertTrue(rows.filter { ["u2", "a2"].contains($0.id) }.allSatisfy { $0.earlierVersion == true })
        XCTAssertFalse(MessageRowView.editable(try XCTUnwrap(rows.first { $0.id == "u2" })), "An earlier version is read-only")
        XCTAssertTrue(MessageRowView.editable(try XCTUnwrap(rows.first { $0.id == "u1" })), "The latest version's messages stay editable")
        XCTAssertEqual(Self.switchers(pane).map(\.messageID), ["u2"])
        XCTAssertEqual(Self.switchers(pane).first?.mark?.index, 1)
        XCTAssertEqual(ConversationPaneTests.views(VersionBannerMarkerView.self, in: pane.hosted).count, 1, "The banner is on screen")
        XCTAssertEqual(pane.session.draft, "A draft for the latest version", "The composer stays on the latest version")
        XCTAssertEqual(pane.session.messages.map(\.id), ["u1", "a1", "branch-1", "u2b", "a2b"], "The chat's own rows are untouched")

        // Back to latest, from the banner.
        try Self.document(pane).actionRelay.forwarded.latestVersion?()
        await Self.shown(pane, version: nil)
        XCTAssertEqual(pane.session.presentedMessages.map(\.id), ["u1", "a1", "u2b", "a2b"])
        XCTAssertEqual(Self.switchers(pane).map(\.messageID), ["u2b"])
        XCTAssertTrue(ConversationPaneTests.views(VersionBannerMarkerView.self, in: pane.hosted).isEmpty)

        // And with › from version 1.
        try Self.document(pane).actionRelay.forwarded.switchVersion?("u2b", -1)
        await Self.shown(pane, version: 1)
        try Self.document(pane).actionRelay.forwarded.switchVersion?("u2", 1)
        await Self.shown(pane, version: nil)
        XCTAssertEqual(pane.session.presentedMessages.map(\.id), ["u1", "a1", "u2b", "a2b"])
    }

    /// A send goes to the latest version, and the transcript returns to it.
    @MainActor func testSendingReturnsToTheLatestVersion() async throws {
        let pane = try await Self.pane(); defer { pane.close() }
        try Self.document(pane).actionRelay.forwarded.switchVersion?("u2b", -1)
        await Self.shown(pane, version: 1)
        pane.session.draft = "A follow-up"
        pane.model.send(sessionID: pane.chat.id)
        XCTAssertNil(pane.session.versionView, "Sending returns the transcript to the latest version")
        XCTAssertFalse(pane.session.presentedMessages.contains { $0.earlierVersion == true })
        XCTAssertTrue(pane.session.presentedMessages.contains { $0.id == "u2b" })
    }

    /// ⌥← and ⌥→ step through the versions of the edited message, and leave
    /// the keys to text wherever text takes them.
    @MainActor func testOptionArrowsStepThroughTheVersions() async throws {
        XCTAssertEqual(WindowPresentationController.versionStep(keyCode: 123, modifiers: [.option, .numericPad, .function]), -1)
        XCTAssertEqual(WindowPresentationController.versionStep(keyCode: 124, modifiers: [.option, .numericPad, .function]), 1)
        XCTAssertNil(WindowPresentationController.versionStep(keyCode: 123, modifiers: [.option, .shift]), "⌥⇧← selects text")
        XCTAssertNil(WindowPresentationController.versionStep(keyCode: 124, modifiers: [.option, .command]))
        XCTAssertNil(WindowPresentationController.versionStep(keyCode: 123, modifiers: []))
        XCTAssertNil(WindowPresentationController.versionStep(keyCode: 0, modifiers: .option))

        let pane = try await Self.pane(); defer { pane.close() }
        XCTAssertTrue(pane.model.stepVersion(sessionID: pane.chat.id, step: -1))
        await Self.shown(pane, version: 1)
        XCTAssertEqual(pane.session.versionView?.shownID, "u2")
        XCTAssertTrue(pane.model.stepVersion(sessionID: pane.chat.id, step: -1), "There is no version before the first; the key is still the switcher's")
        XCTAssertEqual(pane.session.versionView?.index, 1)
        XCTAssertTrue(pane.model.stepVersion(sessionID: pane.chat.id, step: 1))
        await Self.shown(pane, version: nil)

        let plain = try ConversationPaneTests.Pane(messages: Array(Self.editedRows().prefix(2))); defer { plain.close() }
        XCTAssertFalse(plain.model.stepVersion(sessionID: plain.chat.id, step: -1), "A chat with no edited message leaves the keys alone")
    }

    /// Old rows keep their receipts: their Details open the Inspector at the
    /// old request, which the navigator lists under the edited turn.
    @MainActor func testAnEarlierVersionsRequestsOpenInTheInspectorNestedUnderTheTurn() async throws {
        SessionInspectorWindows.shared.closeAll()
        let pane = try await Self.pane(); defer { SessionInspectorWindows.shared.closeAll(); pane.close() }
        let archive = pane.model.traces
        try await archive.configure(quota: 8_388_608, bodyRetention: 1_000_000, metricRetention: 400_000_000)
        for (attempt, turn, output, wall) in [(Self.firstAttempt, "u1", "a1", 1.0), (Self.oldAttempt, "u2", "a2", 2.0), (Self.newAttempt, "u2b", "a2b", 3.0)] {
            let sample = SessionTimingSample(id: attempt, wall: Date(timeIntervalSince1970: 1_800_000_000 + wall), ttftMilliseconds: 300, streamingMilliseconds: 900,
                                             outputTokens: 40, costUSD: 0.001, requestMilliseconds: 1_200, outcome: "completed", api: "openai-responses",
                                             model: "pane-model", inputTokens: 900, turn: turn)
            var value = SessionStatsPopoverTests.metadata(for: sample, session: pane.chat.id)
            value["attemptId"] = .string(attempt); value["outputMessageIds"] = .array([.string(output)])
            try await archive.begin(value, workspace: pane.chat.workspaceID)
            try await archive.finish(value)
        }
        try Self.document(pane).actionRelay.forwarded.switchVersion?("u2b", -1)
        await Self.shown(pane, version: 1)

        // The old reply's Details.
        try Self.document(pane).actionRelay.forwarded.inspect("a2")
        XCTAssertEqual(pane.model.lastInspectorFocus, .message("a2"))
        let inspector = try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID: pane.chat.id)?.inspector)
        for _ in 0..<400 where !(inspector.indexLoaded && inspector.page == .request(Self.oldAttempt)) { await pane.settle(1) }
        XCTAssertEqual(inspector.page, .request(Self.oldAttempt), "The old reply's Details open its own request")

        // The navigator: turn 2 as it stands, with version 1 and its request under it.
        for _ in 0..<400 where inspector.index.turns.first(where: { $0.id == "u2b" })?.earlier.isEmpty != false { await pane.settle(1) }
        XCTAssertEqual(inspector.index.turns.filter { !$0.isOther }.map(\.id), ["u1", "u2b"], "An earlier version is not a turn of its own")
        let edited = try XCTUnwrap(inspector.index.turns.first { $0.id == "u2b" })
        XCTAssertEqual(edited.number, 2)
        XCTAssertEqual(edited.earlier.map(\.id), ["u2"])
        XCTAssertEqual(edited.earlier.first?.requests.map(\.id), [Self.oldAttempt])
        XCTAssertEqual(edited.earlier.first?.version, InspectorTurnVersion(index: 1, count: 2, latest: "u2b"))
        XCTAssertEqual(inspector.index.turn(containing: Self.oldAttempt)?.version?.latest, "u2b")
        XCTAssertTrue(inspector.expanded.contains("u2b"), "Opening the old request opens the turn it nests under")
    }

    /// Against the packaged helper: an edit's row comes numbered, and its
    /// earlier version is read from the helper, page by page.
    @MainActor func testAnEarlierVersionIsReadFromTheHelper() async throws {
        let live = try await ConversationPaneTests.LiveChat()
        var closed = false
        defer { if !closed { Task { await live.close() } } }
        await live.settle(20)
        await live.send("The original question")
        await live.waitUntil("The first turn never finished") { !live.session.hasWork && live.session.messages.last?.role == "assistant" }
        let original = try XCTUnwrap(live.session.messages.last { $0.role == "user" }?.id)
        let originalReply = try XCTUnwrap(live.session.messages.last { $0.role == "assistant" && $0.kind == nil })
        live.model.editMessage(original, sessionID: live.chat.id)
        await live.waitUntil("The edit never loaded") { !live.session.editPreparing && live.session.editingMessageID == original }
        live.session.draft = "The edited question"
        live.model.sendEdit(sessionID: live.chat.id)
        await live.waitUntil("The edited question never settled") {
            live.session.editingMessageID == nil && !live.session.hasWork && live.session.messages.contains { $0.versions?.index == 2 }
                && live.session.messages.last?.role == "assistant"
        }
        let edited = try XCTUnwrap(live.session.messages.first { $0.versions != nil })
        XCTAssertEqual(edited.versions, MessageVersionMark(index: 2, count: 2, ids: [original, edited.id]))
        XCTAssertFalse(live.session.presentedMessages.contains { $0.kind == "branch" })
        live.model.showVersion(sessionID: live.chat.id, messageID: edited.id, step: -1)
        await live.waitUntil("Version 1 was never read") { live.session.versionView?.loading == false }
        XCTAssertNil(live.session.versionView?.failure)
        let shown = live.session.presentedMessages
        XCTAssertTrue(shown.contains { $0.id == original && $0.text == "The original question" && $0.earlierVersion == true })
        XCTAssertTrue(shown.contains { $0.id == originalReply.id && $0.earlierVersion == true && $0.requestAttemptIDs?.isEmpty == false },
                      "The old reply keeps the request it came from")
        XCTAssertFalse(shown.contains { $0.id == edited.id })
        XCTAssertNil(live.model.error, live.model.error ?? "")
        closed = true
        await live.close()
    }

    /// A chat edited before versions were shown, read from its journal with
    /// no helper running: the replacement row is numbered all the same.
    func testTheRetainedReaderNumbersVersionsOfAJournalWrittenBeforeThem() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("versions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("chat.jsonl")
        var parent: String? = nil
        var lines = [#"{"type":"session","version":3,"id":"chat","cwd":"/tmp","timestamp":"2026-09-01T00:00:00Z"}"#]
        func record(_ id: String, _ body: String) {
            lines.append("{\"id\":\"\(id)\",\"parentId\":" + (parent.map { "\"\($0)\"" } ?? "null") + ",\"timestamp\":\"2026-09-01T00:00:00Z\"," + body + "}")
            parent = id
        }
        record("native", #""type":"custom","customType":"pi-app.native.v1","data":{"binding":{},"version":1}"#)
        record("kept", #""type":"message","message":{"role":"user","content":"kept question"}"#)
        record("kept-answer", #""type":"message","message":{"role":"assistant","content":"kept answer"}"#)
        record("old", #""type":"message","message":{"role":"user","content":"old question"}"#)
        record("old-answer", #""type":"message","message":{"role":"assistant","content":"old answer"}"#)
        record("branch", #""type":"branch","fromMessageId":"old","keptIds":["kept","kept-answer"]"#)
        record("new", #""type":"message","message":{"role":"user","content":"new question"}"#)
        record("new-answer", #""type":"message","message":{"role":"assistant","content":"new answer"}"#)
        try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
        let page = try await HistoryReader().read(path: path.path)
        XCTAssertNil(page.notice, page.notice ?? "")
        XCTAssertEqual(page.messages.first { $0.id == "new" }?.versions, MessageVersionMark(index: 2, count: 2, ids: ["old", "new"]))
        XCTAssertNil(page.messages.first { $0.id == "kept" }?.versions)
        XCTAssertEqual(SessionDisplay.hidingBranchMarkers(page.messages).map(\.id), ["kept", "kept-answer", "new", "new-answer"])
    }

    /// The navigator's nesting, from what the helper numbers: every turn an
    /// earlier version ran on into nests with it.
    func testTheInspectorNestsEveryTurnOfAnEarlierVersion() {
        let groups: [[String: WireValue]] = [["group": .string("u2"), "versions": .array([
            .object(["index": .number(1), "messageId": .string("u2"), "live": .bool(false), "turns": .array([.string("u2"), .string("u3")])]),
            .object(["index": .number(2), "messageId": .string("u2b"), "live": .bool(true), "turns": .array([.string("u2b")])]),
        ])]]
        let map = SessionInspectorModel.versionMap(marks: [], groups: groups)
        XCTAssertEqual(map.earlier["u3"], .init(latest: "u2b", index: 1, count: 2, version: "u2"))
        func row(_ id: String, _ turn: String, _ wall: Double) -> InspectorRequestRow {
            InspectorRequestRow(id: id, wall: wall, turn: turn, purpose: "turn", api: "openai-responses", outcome: "completed")
        }
        let index = InspectorIndex(archived: [row("r1", "u1", 1), row("r2", "u2", 2), row("r3", "u3", 3), row("r4", "u2b", 4)], versions: map)
        XCTAssertEqual(index.turns.map(\.id), ["u1", "u2b"])
        XCTAssertEqual(index.turns[1].earlier.map { $0.requests.map(\.id) }, [["r2", "r3"]])
        XCTAssertEqual(index.turn("u3")?.id, "u2", "A later turn of version 1 opens version 1")
        XCTAssertEqual(index.requests.map(\.id), ["r1", "r4", "r2", "r3"], "⌘] steps through a turn, then its earlier versions")
        XCTAssertEqual(index.resolve(.turn("u2")), .turn("u2"))
    }
}

/// "Fork from here": a new chat, nested under the chat it came from, whose
/// conversation ends at the reply it was made from.
final class ForkFromReplyTests: XCTestCase {
    /// The right-click menu offers it on a finished reply of a chat that can
    /// fork, and nowhere else; choosing it forks at that reply.
    @MainActor func testTheReplyMenuOffersForkFromHereOnFinishedReplies() {
        var forked: [String] = []
        var actions = TranscriptActions()
        actions.fork = { forked.append($0) }
        let reply = TranscriptMessage(id: "a1", role: "assistant", text: "Done.", state: "complete", turn: "u1")
        let menu = PiMenus.menu(ReplyMenu.entries(reply, actions: actions, forks: true))
        XCTAssertEqual(menu.items.first { $0.identifier?.rawValue == "reply-fork" }?.title, "Fork from Here")
        XCTAssertTrue(PiMenus.perform("reply-fork", in: menu))
        XCTAssertEqual(forked, ["a1"])
        XCTAssertNil(PiMenus.menu(ReplyMenu.entries(reply, actions: actions, forks: false)).items.first { $0.identifier?.rawValue == "reply-fork" },
                     "A chat that cannot fork offers no fork")
        var streaming = reply; streaming.state = "streaming"
        XCTAssertFalse(ReplyMenu.forks(streaming, enabled: true), "A reply still arriving cannot be forked from")
        var stopped = reply; stopped.stopReason = "interrupted"
        XCTAssertFalse(ReplyMenu.forks(stopped, enabled: true), "A stopped reply is not part of the conversation")
        XCTAssertFalse(ReplyMenu.forks(TranscriptMessage(id: "u1", role: "user", text: "Hi"), enabled: true))
        var old = reply; old.earlierVersion = true
        XCTAssertTrue(ReplyMenu.forks(old, enabled: true), "A reply of an earlier version forks too")
    }

    /// Against the packaged helper: "Fork from here" on the first reply makes
    /// "‹title› · fork", nested under the chat, opens it with its composer
    /// focused, and its transcript ends at that reply.
    @MainActor func testForkFromHereOpensANestedChatEndingAtThatReply() async throws {
        let live = try await ConversationPaneTests.LiveChat()
        var closed = false
        defer { if !closed { Task { await live.close() } } }
        await live.settle(20)
        await live.send("First question for the fork")
        await live.waitUntil("The first turn never finished") { !live.session.hasWork && live.session.messages.contains { $0.role == "assistant" } }
        let reply = try XCTUnwrap(live.session.messages.last { $0.role == "assistant" && $0.kind == nil }?.id)
        await live.send("Second question, after the fork point")
        await live.waitUntil("The second turn never finished") {
            !live.session.hasWork && live.session.messages.contains { $0.text.contains("Second question") } && live.session.messages.last?.role == "assistant"
        }
        let document = try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeDocument.self, in: live.hosted).first)
        document.actionRelay.forwarded.fork?(reply)
        await live.waitUntil("The fork never opened") { live.model.selectedID != live.chat.id && live.model.chats.contains { $0.parentSessionID == live.chat.id } }
        let fork = try XCTUnwrap(live.model.chats.first { $0.parentSessionID == live.chat.id })
        XCTAssertEqual(fork.title, "Live · fork")
        XCTAssertEqual(live.model.selectedID, fork.id, "The fork opens")
        let view = try XCTUnwrap(live.model.displays[fork.id])
        await live.waitUntil("The fork's transcript never loaded") { view.historyState != .loading && !view.messages.isEmpty }
        XCTAssertEqual(view.messages.last { $0.kind == nil }?.id, reply, "The fork's transcript ends at the reply it was made from")
        XCTAssertFalse(view.messages.contains { $0.text.contains("Second question") })
        XCTAssertGreaterThan(view.composerFocusRequest, 0, "The fork's composer takes the cursor")
        XCTAssertEqual(live.model.focusedSessionID, fork.id)
        XCTAssertNil(live.model.error, live.model.error ?? "")
        closed = true
        await live.close()
    }

    /// The Inspector's request page forks from the reply its request produced.
    @MainActor func testTheRequestPageFindsTheReplyItsRequestProduced() async throws {
        var reply = TranscriptMessage(id: "a1", role: "assistant", text: "Done.", state: "complete", turn: "u1")
        reply.reply = ReplyRecord(attempt: "attempt-1")
        let pane = try ConversationPaneTests.Pane(messages: [TranscriptMessage(id: "u1", role: "user", text: "Hi", turn: "u1"), reply])
        defer { pane.close() }
        let found = await pane.model.replyID(forAttempt: "attempt-1", sessionID: pane.chat.id)
        XCTAssertEqual(found, "a1")
        let missing = await pane.model.replyID(forAttempt: "attempt-unknown", sessionID: pane.chat.id)
        XCTAssertNil(missing)
        XCTAssertTrue(pane.model.canForkFromReply(pane.chat.id))
    }
}
