import AppKit
import XCTest
@testable import PiApp

final class SidebarAskTests: XCTestCase {
    @MainActor private func view(_ fixture: AskFixture) -> WorkspaceSidebarView {
        let view = WorkspaceSidebarView(model: fixture.model)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 640)
        fixture.model.sidebarSearch.setScope(.ask); view.settle()
        return view
    }
    @MainActor private func submit(_ view: WorkspaceSidebarView) throws {
        let delegate = try XCTUnwrap(view.filterField.field.delegate as? SidebarFilterDelegate)
        XCTAssertTrue(delegate.control(view.filterField.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
    }
    @MainActor func testTypingSendsNothingReturnRanksValidatesConfirmsAndOpensTheReasonLine() async throws {
        let fixture = try await AskFixture.make(self), model = fixture.model
        try await fixture.chat("a", title: "Welcome notes", brief: "The marmalade tokenizer checklist.")
        try await fixture.chat("b", title: "Retry migration", brief: "Parser retries move to incremental input.")
        let view = view(fixture), ask = model.sidebarSearch.askChats
        for draft in ["Where", "Where was the marmalade", "Where was the marmalade parser retry discussed?"] {
            view.filterField.field.stringValue = draft
            view.filterField.field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: view.filterField.field))
        }
        await model.sidebarSearch.reconcileNow(); await model.sidebarSearch.settleQuery(); view.settle()
        XCTAssertEqual(fixture.gateway.requests.count, 0); XCTAssertFalse(ask.busy)
        XCTAssertTrue(model.sidebarChatOrder.isEmpty, "Ask waits for Return, including title matches")
        try submit(view)
        XCTAssertTrue(ask.busy, "Return starts Ask"); guard ask.busy else { return }
        XCTAssertTrue(model.hasActiveWork, "Preparation holds the update/quit barrier")
        await ask.settle(); view.settle()
        XCTAssertEqual(fixture.gateway.requests.count, 1)
        XCTAssertEqual(model.sidebarChatOrder, ["b", "a"], "Model order is kept; unknown IDs are dropped")
        XCTAssertEqual(ask.matches.map(\.reason), ["Tracks the parser retry migration.", "Contains the tokenizer checklist."])
        XCTAssertEqual(Set(ask.hits.keys), ["a", "b"], "Top chats are confirmed with local word hits")
        XCTAssertTrue(ask.hits.values.allSatisfy { $0.excerpt.localizedCaseInsensitiveContains("marmalade") })
        let request = try XCTUnwrap(fixture.gateway.requests.first)
        XCTAssertEqual(request.body["model"]?.string, "mini-fixture"); XCTAssertEqual(request.body["tools"]?.array ?? [], [])
        XCTAssertTrue(request.system.hasPrefix("Find relevant chats"), request.system)
        XCTAssertTrue(request.prompt.contains("Parser retries move")); XCTAssertFalse(request.raw.contains("PRIVATE PROJECT INSTRUCTION"))
        XCTAssertFalse(request.prompt.contains("Keep the marmalade tokenizer beside"), "No transcript text is sent")
        let record = try XCTUnwrap(model.chats.first { $0.backgroundTask == "chat-ask" })
        XCTAssertEqual(record.backgroundTaskOutcome, "completed"); XCTAssertEqual(record.workspaceID, WorkspaceRecord.scratchID)
        XCTAssertEqual(request.sessionID, record.id); XCTAssertEqual(BackgroundRequestKind(record.backgroundTask ?? ""), .ask)
        XCTAssertTrue(BackgroundRequestFilter.asks.includes(.ask))
        var attempts = try await model.traces.list(sessionID: record.id, workspaceID: WorkspaceRecord.scratchID)
        for _ in 0..<500 where attempts.first?["outcome"]?.string == "running" || attempts.isEmpty {
            try await Task.sleep(for: .milliseconds(10)); attempts = try await model.traces.list(sessionID: record.id, workspaceID: WorkspaceRecord.scratchID)
        }
        XCTAssertEqual(attempts.count, 1); XCTAssertEqual(attempts.first?["purpose"]?.string, "chat-ask")
        let totals = try await model.traces.allSessionTotals()
        XCTAssertEqual(totals[WorkspaceRecord.scratchID + "\u{0}" + record.id]?.requests, 1)
        XCTAssertEqual(totals[WorkspaceRecord.scratchID + "\u{0}" + record.id]?.costUSD ?? 0, 0.004, accuracy: 0.000_001)
        let reason = try XCTUnwrap(view.list.views["reason|b"] as? SidebarSearchSnippetView)
        XCTAssertEqual(reason.press.shownText, ask.matches[0].reason)
        XCTAssertEqual(reason.press.accessibilityLabel(), "Retry migration, Why this chat: Tracks the parser retry migration.")
        XCTAssertLessThan(reason.entryHeight(width: 200), 25, "One reason line even in a narrow sidebar")
        let display = SessionDisplay(id: "b"); display.historyState = .ready
        model.selectedID = "b"; model.displays["b"] = display; model.selected = display; model.focusedSessionID = "b"
        var reveals: [String] = []
        SidebarSearchReveal.override = { id, message in reveals.append(id + "/" + message) }
        defer { SidebarSearchReveal.override = nil }
        reason.press.performClick(nil)
        try await eventually("The reason opens its chat at the confirmed message") { !reveals.isEmpty }
        XCTAssertEqual(reveals, ["b/" + (ask.hits["b"]?.messageID ?? "missing")])
        for flat in [false, true] {
            model.setSidebarFlat(flat); view.settle()
            XCTAssertEqual(view.list.contents.entries.compactMap { if case .chat(let chat, _, _) = $0 { return chat.id }; return nil }, ["b", "a"])
        }
    }

    @MainActor func testEveryConnectionSeesOnlyItsOwnCandidatesAndItsOwnKey() async throws {
        let fixture = try await AskFixture.make(self, second: true), model = fixture.model, other = try XCTUnwrap(fixture.other)
        try await fixture.chat("a", title: "Private studio", brief: "STUDIO_PRIVATE_BRIEF")
        try await fixture.chat("b", title: "Private research", brief: "RESEARCH_PRIVATE_BRIEF", profile: "other")
        fixture.gateway.reply(#"{"matches":[{"id":"a","reason":"Studio match"},{"id":"b","reason":"Foreign ID"}]}"#)
        other.reply(#"{"matches":[{"id":"b","reason":"Research match"},{"id":"a","reason":"Foreign ID"}]}"#)
        let view = view(fixture); view.setFilter("Find the planning discussion")
        try submit(view); XCTAssertTrue(model.sidebarSearch.askChats.busy); guard model.sidebarSearch.askChats.busy else { return }
        await model.sidebarSearch.askChats.settle()
        XCTAssertEqual(Set(model.sidebarChatOrder), ["a", "b"])
        let first = try XCTUnwrap(fixture.gateway.requests.first), second = try XCTUnwrap(other.requests.first)
        XCTAssertTrue(first.prompt.contains("STUDIO_PRIVATE_BRIEF")); XCTAssertFalse(first.prompt.contains("RESEARCH_PRIVATE_BRIEF"))
        XCTAssertTrue(second.prompt.contains("RESEARCH_PRIVATE_BRIEF")); XCTAssertFalse(second.prompt.contains("STUDIO_PRIVATE_BRIEF"))
        XCTAssertTrue(first.head.contains("synthetic-ask-key")); XCTAssertFalse(first.head.contains("synthetic-other-key"))
        XCTAssertTrue(second.head.contains("synthetic-other-key")); XCTAssertEqual(fixture.gateway.requests.count, 1); XCTAssertEqual(other.requests.count, 1)
        XCTAssertEqual(model.chats.filter { $0.backgroundTask == "chat-ask" }.count, 2)
        XCTAssertFalse(model.sidebarSearch.askChats.matches.contains { $0.reason == "Foreign ID" })
    }

    @MainActor func testCancelStopsTheRequestAndDraftChangesNeverSendOrShowALateAnswer() async throws {
        let fixture = try await AskFixture.make(self), model = fixture.model
        try await fixture.chat("a", title: "Checklist")
        fixture.gateway.hold(true)
        let view = view(fixture), ask = model.sidebarSearch.askChats
        view.setFilter("Find the tokenizer"); try submit(view)
        XCTAssertTrue(ask.busy); guard ask.busy else { return }
        try await eventually("The mini model is waiting", timeout: .seconds(45)) { fixture.gateway.requests.count == 1 }
        view.settle()
        let status = try XCTUnwrap(view.list.views["ask-status"] as? SidebarAskStatusView)
        status.cancel.performClick(nil)
        XCTAssertFalse(ask.busy); XCTAssertTrue(ask.status.text.contains("cancelled"))
        guard !ask.busy else { ask.reset(); return }
        try await eventually("The background request is interrupted", timeout: .seconds(30)) {
            model.chats.first { $0.backgroundTask == "chat-ask" }?.backgroundTaskOutcome == "interrupted"
        }
        fixture.gateway.hold(false)
        view.setFilter("A changed question"); await model.sidebarSearch.settleQuery()
        XCTAssertEqual(fixture.gateway.requests.count, 1); XCTAssertTrue(ask.matches.isEmpty)
        XCTAssertFalse(ask.status.busy)
        view.setFilter(""); XCTAssertEqual(model.sidebarSearch.scope, .titlesAndDetails)
        model.sidebarSearch.setScope(.ask); view.setFilter("Find retry")
        fixture.gateway.hold(true); try submit(view)
        try await eventually("The second request starts", timeout: .seconds(45)) { fixture.gateway.requests.count == 2 }
        view.setFilter("Edited while asking"); XCTAssertFalse(ask.busy)
        fixture.gateway.hold(false)
        try await eventually("Typing cancels the old request") { model.chats.filter { $0.backgroundTask == "chat-ask" && $0.backgroundTaskOutcome == "interrupted" }.count == 2 }
        XCTAssertTrue(ask.matches.isEmpty); XCTAssertEqual(fixture.gateway.requests.count, 2)
    }

    @MainActor func testGatewayAndMalformedResponseErrorsAndNoMatchesStayInTheResultArea() async throws {
        let fixture = try await AskFixture.make(self), model = fixture.model
        try await fixture.chat("a", title: "Checklist")
        let view = view(fixture), ask = model.sidebarSearch.askChats
        view.setFilter("Find the tokenizer"); fixture.gateway.fail(true); try submit(view)
        XCTAssertTrue(ask.busy); guard ask.busy else { return }
        await ask.settle(); view.settle()
        XCTAssertTrue(ask.status.text.contains("Fixture Ask failure"), ask.status.text)
        XCTAssertEqual(model.chats.first { $0.backgroundTask == "chat-ask" }?.backgroundTaskOutcome, "failed")
        XCTAssertTrue(view.list.contents.entries.contains { if case .askStatus = $0 { return true }; return false })
        fixture.gateway.fail(false); fixture.gateway.reply("not JSON"); try submit(view); await ask.settle()
        XCTAssertTrue(ask.status.text.contains("usable chat ranking"), ask.status.text)
        fixture.gateway.reply(#"{"matches":[]}"#); try submit(view); await ask.settle()
        XCTAssertTrue(ask.status.text.contains("No relevant chats")); XCTAssertTrue(ask.matches.isEmpty)
        XCTAssertEqual(model.chats.filter { $0.backgroundTask == "chat-ask" && $0.backgroundTaskOutcome == "failed" }.count, 2)
        XCTAssertEqual(fixture.gateway.requests.count, 3)
    }

    @MainActor func testMissingMiniModelSendsNothingAndBriefsOffUsesOnlyTitlesAndDetails() async throws {
        let fixture = try await AskFixture.make(self, mini: nil), model = fixture.model
        try await fixture.chat("a", title: "Checklist", brief: "HIDDEN_BRIEF")
        let view = view(fixture), ask = model.sidebarSearch.askChats
        view.setFilter("Find the checklist"); try submit(view); XCTAssertTrue(ask.busy); guard ask.busy else { return }; await ask.settle()
        XCTAssertEqual(fixture.gateway.requests.count, 0); XCTAssertTrue(ask.status.text.contains("mini model"))
        XCTAssertTrue(model.chats.filter { $0.backgroundTask == "chat-ask" }.isEmpty)
        _ = try await model.vault.update(expectedRevision: model.configuration.revision) {
            $0.profiles[0].profile.miniModelId = "mini-fixture"; $0.briefSettings.enabled = false
        }
        try await model.reloadConfiguration()
        model.sidebarSearch.setScope(.ask); try submit(view); await ask.settle()
        XCTAssertEqual(fixture.gateway.requests.count, 1)
        XCTAssertFalse(fixture.gateway.requests[0].prompt.contains("HIDDEN_BRIEF"))
        XCTAssertTrue(fixture.gateway.requests[0].prompt.contains("Checklist"))
    }

    @MainActor func testMovingAnyCandidateBeforeDispatchSendsNothingToItsOldConnection() async throws {
        let fixture = try await AskFixture.make(self, second: true), model = fixture.model
        try await fixture.chat("a", title: "Checklist", brief: "SECRET_TO_MOVE")
        let view = view(fixture), ask = model.sidebarSearch.askChats
        ask.beforeDispatch = {
            model.connectionGenerations["a", default: 0] &+= 1
            let index = model.chats.firstIndex { $0.id == "a" }!
            model.chats[index].profileID = "other"
        }
        view.setFilter("Find checklist"); try submit(view); await ask.settle()
        XCTAssertEqual(fixture.gateway.requests.count, 0); XCTAssertEqual(fixture.other?.requests.count, 0)
        XCTAssertTrue(ask.status.text.contains("connection changed"), ask.status.text)
        XCTAssertTrue(ask.matches.isEmpty)
    }
    @MainActor func testMovingAChatWhileItsMetadataIsBeingPrefilteredSendsNothingThroughItsOldConnection() async throws {
        let fixture = try await AskFixture.make(self, second: true), model = fixture.model
        try await fixture.chat("a", title: "Checklist", brief: "SECRET_BEFORE_LOCAL_PREFILTER")
        let view = view(fixture), ask = model.sidebarSearch.askChats
        ask.beforeSelection = {
            model.connectionGenerations["a", default: 0] &+= 1
            model.chats[model.chats.firstIndex { $0.id == "a" }!].profileID = "other"
        }
        view.setFilter("Find checklist"); try submit(view); await ask.settle()
        XCTAssertEqual(fixture.gateway.requests.count, 0, "A candidate's snapshot belongs to its original connection")
        XCTAssertEqual(fixture.other?.requests.count, 0)
        XCTAssertTrue(ask.status.text.contains("connection changed"), ask.status.text)
        XCTAssertTrue(ask.matches.isEmpty)
    }

    @MainActor func testIndexConfirmationReturnsOnlyTheRequestedChats() async throws {
        let fixture = try await AskFixture.make(self), search = fixture.model.sidebarSearch
        try await fixture.chat("a", title: "Checklist"); try await fixture.chat("b", title: "More notes")
        await search.reconcileNow()
        let found = try await search.reader.search("marmalade", in: ["a"])
        XCTAssertEqual(Set(found.keys), ["a"])
        let none = try await search.reader.search("marmalade", in: [])
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(fixture.gateway.requests.count, 0, "Full-text confirmation is local")
    }

    @MainActor func testTurningBriefsOffWhileAskIsPreparedStopsItBeforeDispatch() async throws {
        let fixture = try await AskFixture.make(self), model = fixture.model
        try await fixture.chat("a", title: "Checklist", brief: "BRIEF_HIDDEN_AFTER_SWITCH_OFF")
        let view = view(fixture), ask = model.sidebarSearch.askChats
        ask.beforeDispatch = { model.configuration.briefSettings.enabled = false }
        view.setFilter("Find checklist"); try submit(view); await ask.settle()
        XCTAssertEqual(fixture.gateway.requests.count, 0, "Off must not send a brief already being prepared")
        XCTAssertTrue(ask.matches.isEmpty)
        ask.beforeDispatch = nil
        try submit(view); await ask.settle()
        XCTAssertEqual(fixture.gateway.requests.count, 1)
        XCTAssertFalse(fixture.gateway.requests.last?.prompt.contains("BRIEF_HIDDEN_AFTER_SWITCH_OFF") == true)
    }

    @MainActor func testEverySourceIsValidatedAgainAfterTheRequestSessionOpens() async throws {
        let fixture = try await AskFixture.make(self, second: true), model = fixture.model
        let chat = try await fixture.chat("a", title: "Checklist")
        let lease = try model.connectionLease(for: chat)
        let plan = try XCTUnwrap(SidebarAskPlan(profile: model.profiles[0], descriptors: [], question: "Find checklist",
            candidates: [.init(id: "a", connection: "profile", title: "Checklist", brief: "", keywords: [], project: "Orchard", topic: "", activity: 1)]))
        var validations = 0
        do {
            _ = try await model.askMiniModel(plan.request, profile: model.profiles[0], sourceID: chat.id, validateSource: {
                validations += 1
                if validations == 2 {
                    model.connectionGenerations[chat.id, default: 0] &+= 1
                    model.chats[model.chats.firstIndex { $0.id == chat.id }!].profileID = "other"
                }
                try model.requireConnection(lease)
            }) { _ in "Must not return" }
            XCTFail("The source's move before submit was missed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("connection changed"), error.localizedDescription) }
        XCTAssertEqual(validations, 2)
        XCTAssertEqual(fixture.gateway.requests.count, 0); XCTAssertEqual(fixture.other?.requests.count, 0)
    }

    @MainActor func testSavedSidesAndMissingTopicsStayListedInRankOrder() async throws {
        let fixture = try await AskFixture.make(self), model = fixture.model
        try await fixture.chat("a", title: "Checklist", brief: "The tokenizer checklist.")
        try await fixture.chat("b", title: "Saved retry notes", parent: "a")
        model.chats[model.chats.firstIndex { $0.id == "b" }!].topicID = "removed-topic"
        let view = view(fixture)
        view.setFilter("Find the tokenizer retry"); try submit(view); await model.sidebarSearch.askChats.settle(); view.settle()
        XCTAssertEqual(model.sidebarChatOrder, ["b", "a"])
        XCTAssertEqual(view.list.contents.entries.compactMap { if case .chat(let chat, _, _) = $0 { return chat.id }; return nil }, ["b", "a"], "Missing topic metadata must not hide a ranked saved side")
        XCTAssertNotNil(view.list.views["reason|b"])
    }

}
