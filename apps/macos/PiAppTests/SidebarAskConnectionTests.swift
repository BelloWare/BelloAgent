import AppKit
import XCTest
@testable import PiApp

actor AskCheckGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = false
    func wait() async {
        entered = true
        if !open { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

final class SidebarAskConnectionTests: XCTestCase {
    @MainActor func testOneChosenConnectionSuppliesAllCandidatesAndUsesOnlyItsMiniModelAndKey() async throws {
        let fixture = try await AskFixture.make(self, second: true), model = fixture.model
        try await fixture.chat("a", title: "Studio checklist", brief: "STUDIO_ONLY_BRIEF")
        try await fixture.chat("b", title: "Research parser", brief: "RESEARCH_ONLY_BRIEF", profile: "other")
        let sidebar = WorkspaceSidebarView(model: model), ask = model.sidebarSearch.askChats
        model.sidebarSearch.setScope(.ask); sidebar.setFilter("Find parser notes")
        ask.chooseConnection("profile", question: model.sidebarSearch.query)
        XCTAssertEqual(fixture.gateway.requests.count, 0, "Choosing before the first Ask only chooses")
        model.sidebarSearch.submit(); await ask.settle()
        XCTAssertEqual(ask.connectionID, "profile")
        XCTAssertEqual(ask.consideredCount, 1)
        XCTAssertEqual(ask.matches.map(\.id), ["a"], "A foreign ID in the reply cannot become a result")
        XCTAssertEqual(fixture.gateway.requests.count, 1); XCTAssertEqual(fixture.other?.requests.count, 0)
        let request = try XCTUnwrap(fixture.gateway.requests.first)
        XCTAssertTrue(request.prompt.contains("STUDIO_ONLY_BRIEF")); XCTAssertFalse(request.prompt.contains("RESEARCH_ONLY_BRIEF"))
        XCTAssertTrue(request.head.contains("synthetic-ask-key"))
        XCTAssertTrue(ask.status.text.contains("in Studio"), ask.status.text)
    }

    @MainActor func testDefaultAndMenuOrderFollowSettingsAndTheChoiceSurvivesTypingAndModeChanges() async throws {
        let fixture = try await AskFixture.make(self, second: true), model = fixture.model
        try await fixture.chat("a", title: "Studio checklist")
        try await fixture.chat("b", title: "Research parser", profile: "other")
        model.selectedID = "b"
        let sidebar = WorkspaceSidebarView(model: model), ask = model.sidebarSearch.askChats
        model.sidebarSearch.setScope(.ask); sidebar.setFilter("Find the checklist")
        XCTAssertEqual(ask.connections.map(\.title), ["Studio", "Research"], "Settings order, not alphabetical order")
        XCTAssertEqual(ask.connectionID, "other", "The selected chat's connection is the first default")
        ask.chooseConnection("profile", question: model.sidebarSearch.query)
        sidebar.setFilter("Another draft"); model.sidebarSearch.setScope(.fullChats); model.sidebarSearch.setScope(.ask)
        XCTAssertEqual(ask.connectionID, "profile", "The choice is memory only and outlives one search")
        XCTAssertTrue(fixture.gateway.requests.isEmpty); XCTAssertTrue(fixture.other?.requests.isEmpty == true)
    }

    @MainActor func testThePiKitChooserIsHiddenForOneConnectionAndListsDisabledChoicesInSettingsOrder() async throws {
        let fixture = try await AskFixture.make(self, second: true, unavailable: true), model = fixture.model
        try await fixture.chat("a", title: "Studio checklist")
        let sidebar = WorkspaceSidebarView(model: model), search = model.sidebarSearch, ask = search.askChats
        sidebar.frame = CGRect(x: 0, y: 0, width: 200, height: 640)
        search.setScope(.ask); sidebar.setFilter("Find notes"); sidebar.settle()
        XCTAssertTrue(sidebar.askConnection.isHidden, "Only connections with chats count")
        try await fixture.chat("b", title: "Research parser", profile: "other")
        try await fixture.chat("p", title: "Personal notes", profile: "no-mini")
        sidebar.settle()
        XCTAssertFalse(sidebar.askConnection.isHidden)
        XCTAssertTrue(sidebar.bounds.contains(sidebar.askConnection.frame))
        XCTAssertEqual(sidebar.askConnection.accessibilityRole(), .menuButton)
        var menu: NSMenu?
        PiMenus.intercept = { built, anchor in XCTAssertTrue(anchor === sidebar.askConnection); menu = built }
        defer { PiMenus.intercept = nil }
        sidebar.askConnection.performClick(nil)
        let built = try XCTUnwrap(menu)
        XCTAssertEqual(built.items.map(\.title), ["Studio", "Research", "Personal · No mini model"])
        XCTAssertEqual(built.items.map(\.isEnabled), [true, true, false])
        XCTAssertEqual(built.items.map(\.state), [.on, .off, .off])
        XCTAssertFalse(PiMenus.perform("sidebarAskConnection-no-mini", in: built))
        XCTAssertEqual(ask.connectionID, "profile")
        XCTAssertTrue(PiMenus.perform("sidebarAskConnection-other", in: built))
        XCTAssertEqual(ask.connectionID, "other")
        XCTAssertTrue(fixture.gateway.requests.isEmpty); XCTAssertTrue(fixture.other?.requests.isEmpty == true)
        search.setScope(.titlesAndDetails); sidebar.settle()
        XCTAssertTrue(sidebar.askConnection.isHidden)
    }

    @MainActor func testAnUnavailableSelectedChatDefaultsToTheFirstAvailableConnectionInSettingsOrder() async throws {
        let fixture = try await AskFixture.make(self, second: true, unavailable: true), model = fixture.model
        try await fixture.chat("a", title: "Studio checklist")
        try await fixture.chat("b", title: "Research parser", profile: "other")
        try await fixture.chat("p", title: "Personal notes", profile: "no-mini")
        model.profiles = [model.profiles[2], model.profiles[1], model.profiles[0]]
        model.selectedID = "p"
        let sidebar = WorkspaceSidebarView(model: model), ask = model.sidebarSearch.askChats
        model.sidebarSearch.setScope(.ask); sidebar.setFilter("Find notes")
        XCTAssertEqual(ask.connectionID, "other")
        XCTAssertEqual(ask.connections.map(\.id), ["no-mini", "other", "profile"])
        XCTAssertTrue(fixture.gateway.requests.isEmpty); XCTAssertTrue(fixture.other?.requests.isEmpty == true)
    }

    @MainActor func testRemovingTheChosenConnectionDropsItsResultsBeforeResolvingTheDefault() async throws {
        let fixture = try await AskFixture.make(self, second: true), model = fixture.model
        try await fixture.chat("a", title: "Studio checklist")
        try await fixture.chat("b", title: "Research parser", profile: "other")
        let sidebar = WorkspaceSidebarView(model: model), search = model.sidebarSearch, ask = search.askChats
        search.setScope(.ask); sidebar.setFilter("Find the tokenizer checklist"); search.submit(); await ask.settle()
        XCTAssertEqual(ask.matches.map(\.id), ["a"])
        model.profiles.removeAll { $0.id == "profile" }
        // Reading the list must not cancel work during its construction.
        let oldMatches = ask.matches, oldStatus = ask.status
        _ = ask.connectionID; _ = ask.listedMatches
        XCTAssertEqual(ask.matches, oldMatches); XCTAssertEqual(ask.status, oldStatus)
        ask.connectionsChanged()
        XCTAssertEqual(ask.connectionID, "other")
        XCTAssertTrue(ask.matches.isEmpty); XCTAssertTrue(ask.hits.isEmpty)
        XCTAssertFalse(ask.status.text.contains("in Studio"))
        await Task.yield()
        XCTAssertEqual(ask.connectionID, "other"); XCTAssertEqual(fixture.other?.requests.count, 0)
    }

    @MainActor func testLosingTheChosenMiniModelKeepsTheChoiceAndSendsNothingUntilAnotherIsChosen() async throws {
        let fixture = try await AskFixture.make(self, second: true), model = fixture.model
        try await fixture.chat("a", title: "Studio checklist")
        try await fixture.chat("b", title: "Research parser", profile: "other")
        let sidebar = WorkspaceSidebarView(model: model), search = model.sidebarSearch, ask = search.askChats
        search.setScope(.ask); sidebar.setFilter("Find the tokenizer checklist"); search.submit(); await ask.settle()
        model.profiles[0].miniModelId = nil
        try await eventually("A Settings edit invalidates the old answer") { ask.status.text == SidebarAsk.miniNotice }
        XCTAssertEqual(ask.connectionID, "profile"); XCTAssertTrue(ask.matches.isEmpty)
        search.submit(); await ask.settle()
        XCTAssertEqual(fixture.gateway.requests.count, 1); XCTAssertEqual(fixture.other?.requests.count, 0)
        XCTAssertEqual(ask.status.text, SidebarAsk.miniNotice)
        ask.chooseConnection("other", question: search.query); await ask.settle()
        XCTAssertEqual(ask.matches.map(\.id), ["b"]); XCTAssertEqual(fixture.other?.requests.count, 1)
    }

    @MainActor func testChoosingAfterAnErrorAsksTheSameQuestionAndTypingStartsANewDraft() async throws {
        let fixture = try await AskFixture.make(self, second: true), model = fixture.model
        try await fixture.chat("a", title: "Studio checklist")
        try await fixture.chat("b", title: "Research parser", profile: "other")
        let sidebar = WorkspaceSidebarView(model: model), search = model.sidebarSearch, ask = search.askChats
        search.setScope(.ask); sidebar.setFilter("Find the tokenizer checklist")
        fixture.gateway.fail(true); search.submit(); await ask.settle()
        XCTAssertTrue(ask.status.text.contains("Fixture Ask failure"))
        ask.chooseConnection("other", question: search.query); await ask.settle()
        XCTAssertEqual(ask.matches.map(\.id), ["b"])
        XCTAssertTrue(fixture.other?.requests.first?.prompt.contains("Find the tokenizer checklist") == true)
        XCTAssertTrue(ask.status.text.contains("in Research · 1 checked"))
        sidebar.setFilter("An unfinished new draft")
        ask.chooseConnection("profile", question: search.query); await ask.settle()
        XCTAssertTrue(ask.matches.isEmpty)
        XCTAssertEqual(fixture.gateway.requests.count, 1, "Choosing after typing only sets the choice")
    }

    @MainActor func testChoosingWhileAskingCancelsTheOldRequestAndClosesItsSessionBeforeDispatchingTheNext() async throws {
        let fixture = try await AskFixture.make(self, second: true), model = fixture.model
        try await fixture.chat("a", title: "Studio checklist")
        try await fixture.chat("b", title: "Research parser", profile: "other")
        let sidebar = WorkspaceSidebarView(model: model), search = model.sidebarSearch, ask = search.askChats
        search.setScope(.ask); sidebar.setFilter("Find parser retry"); fixture.gateway.hold(true); search.submit()
        try await eventually("Studio is asking") { fixture.gateway.requests.count == 1 }
        let old = try XCTUnwrap(model.chats.first { $0.backgroundTask == "chat-ask" })
        var closedBeforeDispatch = false
        ask.beforeDispatch = { closedBeforeDispatch = model.displays[old.id] == nil }
        ask.chooseConnection("other", question: search.query); await ask.settle()
        XCTAssertTrue(closedBeforeDispatch, "One helper request at a time, including cancellation cleanup")
        XCTAssertEqual(ask.matches.map(\.id), ["b"]); XCTAssertEqual(fixture.other?.requests.count, 1)
        XCTAssertEqual(model.record(old.id)?.backgroundTaskOutcome, "interrupted")
        fixture.gateway.hold(false)
        await Task.yield()
        XCTAssertEqual(ask.connectionID, "other"); XCTAssertEqual(ask.matches.map(\.id), ["b"])
    }
    @MainActor func testUncachedCatalogMiniDefaultCanBeChosenThenResolvedWithoutARequestWhileTyping() async throws {
        let catalog = ModelCatalog(readBundled: { [] }, fetchCatalog: { _, _ in
            [ModelDescriptor(id: "catalog-mini", name: "Catalog mini", mini: true)]
        })
        let fixture = try await AskFixture.make(self, second: true, catalog: catalog), model = fixture.model
        try await fixture.chat("a", title: "Studio checklist")
        try await fixture.chat("b", title: "Research parser", profile: "other")
        try await model.updateConfiguration { saved in
            saved.profiles[1].profile.miniModelId = nil
            saved.profiles[1].profile.catalogUrl = "http://127.0.0.1:1/catalog"
        }
        let sidebar = WorkspaceSidebarView(model: model), search = model.sidebarSearch, ask = search.askChats
        search.setScope(.ask); sidebar.setFilter("Find parser")
        XCTAssertNil(model.catalogEntry(for: model.profiles[1]).fetchedAt)
        XCTAssertEqual(ask.connections.first(where: { $0.id == "other" })?.available, true, "Unknown is not no mini model")
        ask.chooseConnection("other", question: search.query)
        XCTAssertEqual(ask.connectionID, "other"); XCTAssertTrue(fixture.other?.requests.isEmpty == true)
        // Session opening can start this catalog load too (0.1.132). Ask must
        // join it without losing the chosen connection or asking twice.
        let chat = try XCTUnwrap(model.record("b"))
        let listing = Task { await model.loadSubagentModels(for: chat) }
        search.submit(); await ask.settle(); await listing.value
        XCTAssertEqual(fixture.other?.requests.count, 1, ask.status.text)
        XCTAssertEqual(fixture.other?.requests.first?.body["model"]?.string, "catalog-mini")
        XCTAssertEqual(ask.matches.map(\.id), ["b"]); XCTAssertTrue(fixture.gateway.requests.isEmpty)
    }

    @MainActor func testAChosenConnectionThatLosesItsLastEligibleChatFallsBackWithoutAsking() async throws {
        for moved in [false, true] {
            let fixture = try await AskFixture.make(self, second: true), model = fixture.model
            try await fixture.chat("a", title: "Studio checklist")
            try await fixture.chat("b", title: "Research parser", profile: "other")
            let sidebar = WorkspaceSidebarView(model: model), search = model.sidebarSearch, ask = search.askChats
            search.setScope(.ask); sidebar.setFilter("Find checklist"); search.submit(); await ask.settle()
            if moved { model.chats[model.chats.firstIndex { $0.id == "a" }!].profileID = "other" }
            else { model.chats.removeAll { $0.id == "a" } }
            try await eventually("An empty chosen connection gets a usable default") { ask.connectionID == "other" }
            sidebar.settle()
            XCTAssertTrue(sidebar.askConnection.isHidden); XCTAssertTrue(ask.matches.isEmpty)
            XCTAssertEqual(fixture.other?.requests.count, 0, "A library change never asks on its own")
            search.submit(); await ask.settle()
            XCTAssertEqual(fixture.other?.requests.count, 1); XCTAssertTrue(ask.status.text.contains("in Research"))
        }
    }

}

final class SidebarAskPublishingTests: XCTestCase {
    @MainActor func testAColdIndexHeldOnAnUnrelatedChatCannotHoldRankingsAndSnippetsFillWithoutMovingRows() async throws {
        let fixture = try await AskFixture.make(self, second: true), model = fixture.model
        try await fixture.chat("a", title: "Tokenizer checklist", brief: "Tokenizer retry checklist", reply: "Tokenizer retry checklist.")
        try await fixture.chat("b", title: "Parser retry migration", brief: "Parser retries",
            reply: "Parser retries preserve the complete incremental input while a migration is in progress. The migration checklist also covers interrupted reads, repeated chunks, recovery after cancellation, and the final parser state after a successful retry.")
        let slow = try await fixture.chat("slow", title: "Unrelated slow journal", profile: "other")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(300)], ofItemAtPath: try XCTUnwrap(slow.path))
        let sidebar = WorkspaceSidebarView(model: model), search = model.sidebarSearch, ask = search.askChats
        sidebar.frame = CGRect(x: 0, y: 0, width: 300, height: 640)
        search.setScope(.ask); sidebar.setFilter("Find parser retry")
        let libraryGate = AskCheckGate(), snippetGate = AskCheckGate(), secondGate = AskCheckGate()
        await search.index.beforeReadingSource { id in if id == "slow" { await libraryGate.wait() } }
        let library = Task { await search.reconcileNow() }
        addTeardownBlock { await libraryGate.release(); await snippetGate.release(); await secondGate.release(); _ = await library.value; await ask.settle() }
        for _ in 0..<500 {
            if await libraryGate.entered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let held = await libraryGate.entered
        XCTAssertTrue(held, "The library pass is waiting at the unrelated journal")
        ask.beforeConfirmation = { id in if id == "b" { await snippetGate.wait() } else { await secondGate.wait() } }
        search.submit()
        try await eventually("Rankings publish while the unrelated journal is still held", timeout: .seconds(5)) { ask.matches.map(\.id) == ["b", "a"] }
        sidebar.settle()
        let rows = ["chat|b", "reason|b", "snippet|b", "chat|a", "reason|a", "snippet|a"]
        func frames() throws -> [CGRect] {
            try rows.map { try XCTUnwrap(sidebar.list.views[$0], $0).frame }
        }
        let pending = try frames()
        XCTAssertGreaterThan(pending[2].width, 200, "The snippet must have a real laid-out width")
        XCTAssertLessThanOrEqual(pending[2].width, 300)
        XCTAssertEqual(ask.checkingIDs, ["a", "b"])
        XCTAssertNotNil(sidebar.list.views["snippet|b"]); XCTAssertNotNil(sidebar.list.views["snippet|a"])
        await snippetGate.release()
        try await eventually("Each excerpt publishes when its own journal is checked") { ask.hits["b"] != nil }
        XCTAssertNil(ask.hits["a"]); XCTAssertEqual(ask.checkingIDs, ["a"])
        XCTAssertGreaterThan(try XCTUnwrap(ask.hits["b"]).excerpt.count, 120, "This excerpt must wrap, unlike the pending label")
        sidebar.settle()
        let filled = try XCTUnwrap(sidebar.list.views["snippet|b"] as? SidebarSearchSnippetView)
        XCTAssertEqual(filled.entryHeight(width: filled.frame.width), pending[2].height,
            "The pending slot must already fit the wrapped excerpt, even if a cached frame masks movement")
        XCTAssertEqual(try frames(), pending, "The first filled excerpt cannot resize its slot or move a later row")
        await secondGate.release()
        try await eventually("The two selected journals supply their excerpts without the library pass", timeout: .seconds(10)) { ask.hits.count == 2 }
        sidebar.settle()
        XCTAssertEqual(try frames(), pending, "A shorter second excerpt keeps the same reserved space")
        await ask.settle(); sidebar.settle()
        XCTAssertEqual(try frames(), pending, "Finishing confirmation cannot remove a progress row's space")
        XCTAssertTrue(ask.checkingIDs.isEmpty)
        let indexedSlow = await search.index.documentCount(chat: "slow")
        XCTAssertEqual(indexedSlow, 0, "No unrelated read had to finish")
        await libraryGate.release(); _ = await library.value
    }

    @MainActor func testOnlyTheTopEightJournalsAreCheckedAndEachResultKeepsItsSnippetSlot() async throws {
        let fixture = try await AskFixture.make(self), model = fixture.model
        for i in 0..<10 { try await fixture.chat("c\(i)", title: "Tokenizer checklist \(i)") }
        let rows = (0..<10).map { ["id": "c\($0)", "reason": "Checklist \($0)"] }
        fixture.gateway.reply(String(decoding: try JSONSerialization.data(withJSONObject: ["matches": rows]), as: UTF8.self))
        let sidebar = WorkspaceSidebarView(model: model), search = model.sidebarSearch, ask = search.askChats
        sidebar.frame = CGRect(x: 0, y: 0, width: 200, height: 1_400)
        var checked: [String] = []
        ask.beforeConfirmation = { checked.append($0) }
        search.setScope(.ask); sidebar.setFilter("Find tokenizer checklist"); search.submit(); await ask.settle(); sidebar.settle()
        XCTAssertEqual(ask.matches.map(\.id), (0..<10).map { "c\($0)" })
        XCTAssertEqual(checked, (0..<8).map { "c\($0)" })
        XCTAssertEqual(Set(ask.hits.keys), Set(checked))
        XCTAssertNotNil(sidebar.list.views["snippet|c7"]); XCTAssertNil(sidebar.list.views["snippet|c8"])
        XCTAssertEqual(search.passes, 0, "A cold Ask cannot start a library-wide pass")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: model.root.path).filter { $0.hasPrefix("ask-text-") }
        XCTAssertTrue(leftovers.isEmpty, "Temporary confirmation text is removed after checking")
    }

    @MainActor func testANewerAskCancelModeAndConnectionChangeDropPendingEnrichment() async throws {
        for action in ["ask", "cancel", "mode", "connection"] {
            let fixture = try await AskFixture.make(self, second: true), model = fixture.model
            try await fixture.chat("a", title: "Studio tokenizer checklist")
            try await fixture.chat("b", title: "Research parser retry", profile: "other")
            let sidebar = WorkspaceSidebarView(model: model), search = model.sidebarSearch, ask = search.askChats
            let gate = AskCheckGate()
            addTeardownBlock { await gate.release() }
            ask.beforeConfirmation = { id in
                if id == "a" { await gate.wait() }
            }
            search.setScope(.ask); sidebar.setFilter("Find tokenizer retry"); search.submit(); await ask.settleRanking()
            try await eventually("The old enrichment is held") { ask.checkingIDs == ["a"] }
            // Let the enrichment enter its await before replacing it.
            for _ in 0..<100 {
                if await gate.entered { break }
                await Task.yield()
            }
            let entered = await gate.entered
            XCTAssertTrue(entered)
            let oldChecks = try XCTUnwrap(ask.confirmationWork)
            switch action {
            case "ask": fixture.gateway.reply(#"{"matches":[]}"#); search.submit(); await ask.settle()
            case "cancel": ask.cancel()
            case "mode": search.setScope(.fullChats)
            default: ask.chooseConnection("other", question: search.query); await ask.settle()
            }
            let newMatches = ask.matches, newHits = ask.hits, newStatus = ask.status
            await gate.release()
            await oldChecks.value
            XCTAssertEqual(ask.matches, newMatches, action); XCTAssertEqual(ask.hits, newHits, action)
            XCTAssertEqual(ask.status, newStatus, action); XCTAssertTrue(ask.checkingIDs.isEmpty, action)
            if action == "connection" { XCTAssertEqual(ask.matches.map(\.id), ["b"]) }
            else { XCTAssertTrue(ask.matches.isEmpty, action) }
        }
    }

    @MainActor func testSemanticMatchesWithoutLiteralTextKeepTheirReservedLine() async throws {
        let fixture = try await AskFixture.make(self), model = fixture.model
        try await fixture.chat("a", title: "Design direction", brief: "An orchard palette", user: "Discuss colours", reply: "Warm orange and green")
        let sidebar = WorkspaceSidebarView(model: model), search = model.sidebarSearch, ask = search.askChats
        sidebar.frame = CGRect(x: 0, y: 0, width: 200, height: 640)
        let gate = AskCheckGate()
        addTeardownBlock { await gate.release() }
        ask.beforeConfirmation = { _ in await gate.wait() }
        search.setScope(.ask); sidebar.setFilter("Why citrus?"); search.submit(); await ask.settleRanking(); sidebar.settle()
        let pending = try XCTUnwrap(sidebar.list.views["snippet|a"] as? SidebarSearchSnippetView)
        let height = pending.entryHeight(width: 200), y = pending.frame.minY
        await gate.release(); await ask.settle(); sidebar.settle()
        let checked = try XCTUnwrap(sidebar.list.views["snippet|a"] as? SidebarSearchSnippetView)
        XCTAssertEqual(checked.entryHeight(width: 200), height); XCTAssertEqual(checked.frame.minY, y)
        XCTAssertEqual(checked.press.shownText, "No matching excerpt available.")
        XCTAssertEqual(ask.matches.map(\.id), ["a"]); XCTAssertTrue(ask.hits.isEmpty)
    }
    @MainActor func testColdConfirmationIsBoundedAndHasNoTextFilesEvenWhileAnotherCheckIsPending() async throws {
        let fixture = try await AskFixture.make(self), model = fixture.model
        let chat = try await fixture.chat("a", title: "Old evidence", reply: "ancientneedle")
        try await fixture.chat("b", title: "Newest evidence", reply: "Recent tokenizer notes")
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: try XCTUnwrap(chat.path)))
        try file.seekToEnd()
        let filler = String(repeating: "x", count: 32_768)
        var parent = "a-a"
        for i in 0..<40 {
            let id = "padding-\(i)"
            var line = try JSONSerialization.data(withJSONObject: ["id": id, "parentId": parent, "type": "message", "message": ["role": "assistant", "content": filler]])
            line.append(10); try file.write(contentsOf: line); parent = id
        }
        try file.close()
        fixture.gateway.reply(#"{"matches":[{"id":"a","reason":"Old notes"},{"id":"b","reason":"Recent notes"}]}"#)
        let sidebar = WorkspaceSidebarView(model: model), search = model.sidebarSearch, ask = search.askChats, gate = AskCheckGate()
        addTeardownBlock { await gate.release(); await ask.settle() }
        ask.beforeConfirmation = { if $0 == "b" { await gate.wait() } }
        search.setScope(.ask); sidebar.setFilter("Find ancientneedle"); search.submit(); await ask.settleRanking()
        try await eventually("The bounded first check is done", timeout: .seconds(30)) { !ask.checkingIDs.contains("a") }
        XCTAssertNil(ask.hits["a"], "Cold checks cannot scan old text outside the newest 256 KiB")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: model.root.path).filter { $0.hasPrefix("ask-text-") }
        XCTAssertTrue(leftovers.isEmpty, "No transcript copy may exist on disk, including during a check or force quit")
        ask.cancel(); await gate.release(); await ask.settle()
        model.chats.removeAll { $0.id == "a" }; await Task.yield()
        XCTAssertTrue(ask.hits.isEmpty)
    }

    @MainActor func testPromptPreparationRunsOffTheMainThread() async throws {
        let fixture = try await AskFixture.make(self), model = fixture.model
        try await fixture.chat("a", title: "Tokenizer checklist")
        let sidebar = WorkspaceSidebarView(model: model), search = model.sidebarSearch, ask = search.askChats
        let probe = AskPlanThreadProbe()
        ask.willBuildPlan = { probe.record() }
        search.setScope(.ask); sidebar.setFilter("Find tokenizer"); search.submit(); await ask.settle()
        XCTAssertEqual(probe.mainThread, false)
        XCTAssertEqual(ask.matches.map(\.id), ["a"])
    }

    @MainActor func testAnOlderLibraryEntryIsUsedWithoutReindexingTheChangedJournal() async throws {
        let fixture = try await AskFixture.make(self), model = fixture.model
        let chat = try await fixture.chat("a", title: "Tokenizer checklist", reply: "Old tokenizer library evidence")
        let sidebar = WorkspaceSidebarView(model: model), search = model.sidebarSearch, ask = search.askChats
        await search.reconcileNow()
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: try XCTUnwrap(chat.path)))
        try file.seekToEnd(); try file.write(contentsOf: Data("{\"id\":\"new\",\"parentId\":\"a-a\",\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":\"New tokenizer evidence\"}}\n".utf8)); try file.close()
        search.setScope(.ask); sidebar.setFilter("Find tokenizer"); search.submit(); await ask.settle()
        XCTAssertEqual(ask.hits["a"]?.messageID, "a-a", "Ask uses the committed library snapshot, including when older")
        XCTAssertEqual(search.passes, 1)
    }

    @MainActor func testCancelIsBesideTheStatusAndSearchModesKeepVisibleSeparation() async throws {
        let fixture = try await AskFixture.make(self), model = fixture.model
        try await fixture.chat("a", title: "Tokenizer checklist")
        let sidebar = WorkspaceSidebarView(model: model)
        model.sidebarSearch.setScope(.ask); sidebar.setFilter("Find tokenizer")
        for width: CGFloat in [200, 300] {
            sidebar.frame = CGRect(x: 0, y: 0, width: width, height: 640); sidebar.needsLayout = true; sidebar.settle()
            XCTAssertLessThanOrEqual(sidebar.searchScope.frame.maxX, width - 8)
            let tabs = SidebarSearch.Scope.allCases.compactMap { sidebar.searchScope.tab($0) }
            for tab in tabs { XCTAssertGreaterThanOrEqual(tab.intrinsicContentSize.width - tab.line.size(scale: 2).width, 12) }
            XCTAssertEqual(tabs.first?.title, width == 200 ? "Details" : "Titles & details")
            XCTAssertEqual(tabs.first?.accessibilityLabel(), "Titles & details")
        }
        let busy = SidebarAskStatusView(status: .init(text: "2 relevant chats in Studio · 12 checked", busy: true), cancel: {})
        let done = SidebarAskStatusView(status: .init(text: "2 relevant chats in Studio · 12 checked"), cancel: {})
        for width: CGFloat in [200, 300] {
            busy.frame = CGRect(x: 0, y: 0, width: width, height: busy.entryHeight(width: width)); busy.layoutSubtreeIfNeeded()
            XCTAssertEqual(busy.entryHeight(width: width), done.entryHeight(width: width))
            XCTAssertGreaterThan(busy.cancel.frame.minX, width / 2)
            XCTAssertEqual(busy.cancel.frame.minY, 8)
            XCTAssertLessThanOrEqual(busy.frame.height, 60, "No extra Cancel-height band")
        }
    }

}

final class SidebarAskKeyboardTests: XCTestCase, SerialTestLane {
    @MainActor func testTabReachesTheChooserAndVoiceOverNamesItsCurrentConnection() async throws {
        let fixture = try await AskFixture.make(self, second: true), model = fixture.model
        try await fixture.chat("a", title: "Studio checklist")
        let sidebar = WorkspaceSidebarView(model: model)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 200, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "ask-connection-" + UUID().uuidString
        let group = PiKit.Box.ClipView(frame: CGRect(x: 0, y: 0, width: 200, height: 640))
        group.setAccessibilityElement(true); group.setAccessibilityRole(.group)
        sidebar.frame = group.bounds; group.addSubview(sidebar); window.contentView = group
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        model.sidebarSearch.setScope(.ask); sidebar.setFilter("Find notes"); sidebar.settle()
        try await eventually("The fixture window is key") { window.isKeyWindow && NSApp.isActive }
        sidebar.settle()
        XCTAssertTrue(sidebar.askConnection.isHidden)
        // The scope geometry stays fixed while the chooser first joins its
        // key loop: the loop must be recalculated after the chooser is laid out.
        try await fixture.chat("b", title: "Research parser", profile: "other")
        sidebar.settle()
        XCTAssertEqual(model.sidebarSearch.scope, .ask); XCTAssertFalse(sidebar.askConnection.isHidden)
        XCTAssertTrue(sidebar.askConnection.acceptsFirstResponder); XCTAssertTrue(sidebar.askConnection.canBecomeKeyView)
        XCTAssertTrue(window.makeFirstResponder(sidebar.searchScope.tab(.ask)))
        let next = sidebar.searchScope.tab(.ask)?.nextValidKeyView
        let frames = SidebarSearch.Scope.allCases.map { scope in
            let button = sidebar.searchScope.tab(scope)!
            return scope.title + ": " + NSStringFromRect(button.convert(button.bounds, to: nil))
        }.joined(separator: "; ")
        window.selectNextKeyView(nil)
        XCTAssertTrue(window.firstResponder === sidebar.askConnection,
            "Tab reached \((window.firstResponder as? NSView)?.accessibilityLabel() ?? String(describing: window.firstResponder)); next was \(next?.accessibilityLabel() ?? String(describing: next)); \(frames); chooser: \(NSStringFromRect(sidebar.askConnection.convert(sidebar.askConnection.bounds, to: nil)))")
        let ax = try await AXClient.find(in: window) { $0.label == "Ask connection" }
        XCTAssertEqual(ax.role, "AXMenuButton")
        XCTAssertEqual(sidebar.askConnection.accessibilityValue() as? String, "Studio")
        var menu: NSMenu?
        PiMenus.intercept = { built, _ in menu = built }
        defer { PiMenus.intercept = nil }
        XCTAssertTrue(sidebar.askConnection.accessibilityPerformPress())
        XCTAssertTrue(PiMenus.perform("sidebarAskConnection-other", in: try XCTUnwrap(menu)))
        sidebar.settle()
        XCTAssertEqual(sidebar.askConnection.accessibilityValue() as? String, "Research")
        XCTAssertTrue(fixture.gateway.requests.isEmpty); XCTAssertTrue(fixture.other?.requests.isEmpty == true)
    }
}

private final class AskPlanThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    var mainThread: Bool? { lock.withLock { value } }
    func record() { lock.withLock { value = Thread.isMainThread } }
}

final class SidebarAskTextTests: XCTestCase {
    func testTailChecksFollowTheNewestParentsAndOmitReasoningAndControlHistory() throws {
        let root = scratchRoot("ask-tail")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SearchJournal(root.appendingPathComponent("chat.jsonl"))
        try journal.message("old", role: "assistant", "Abandonedneedle")
        try journal.record("branch", ["type": "branch", "fromMessageId": "native", "keptIds": []])
        try journal.message("new", role: "assistant", [["type": "thinking", "thinking": "secretneedle"], ["type": "text", "text": "Freshneedle is visible"]])
        let source = ChatSearchSource(id: "chat", path: journal.url.path)
        XCTAssertEqual(try SidebarAskText.check(source, question: "freshneedle")?.messageID, "new")
        XCTAssertNil(try SidebarAskText.check(source, question: "abandonedneedle"))
        XCTAssertNil(try SidebarAskText.check(source, question: "secretneedle"))
        try journal.record("context", ["type": "custom", "customType": "pi-app.native.context.v1", "data": ["visibleIDs": []]])
        XCTAssertNil(try SidebarAskText.check(source, question: "freshneedle"), "Unresolved visible history must not be guessed")
    }

    func testIncompleteAndOversizeRecordsNeverMakeAnUnboundedRead() throws {
        let root = scratchRoot("ask-tail-records")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SearchJournal(root.appendingPathComponent("chat.jsonl"))
        try journal.message("large", role: "assistant", "needle " + String(repeating: "x", count: 1_000_000))
        let source = ChatSearchSource(id: "chat", path: journal.url.path)
        XCTAssertNil(try SidebarAskText.check(source, question: "needle"))
        try journal.message("last", role: "user", "Freshneedle")
        let file = try FileHandle(forWritingTo: journal.url); try file.seekToEnd()
        try file.write(contentsOf: Data(#"{"id":"unfinished","parentId":"last","type":"message","message":{"role":"assistant","content":"unfinishedneedle"}}"#.utf8)); try file.close()
        XCTAssertEqual(try SidebarAskText.check(source, question: "freshneedle")?.messageID, "last")
        XCTAssertNil(try SidebarAskText.check(source, question: "unfinishedneedle"))
    }
}

final class SidebarAskTextMeasurementTests: XCTestCase, SerialTestLane {
    @MainActor func testA100MiBColdCheckReportsTimePeakDiskAndMemory() async throws {
        guard testEnvironment("PI_APP_ASK_MEASURE") == "1" else { throw XCTSkip("Opt-in 100 MiB Release measurement") }
        let fixture = try await AskFixture.make(self), model = fixture.model
        let chat = try await fixture.chat("a", title: "Large tokenizer journal")
        try await fixture.chat("b", title: "Small tokenizer journal")
        let url = URL(fileURLWithPath: try XCTUnwrap(chat.path)), file = try FileHandle(forWritingTo: url)
        try file.seekToEnd()
        var parent = "a-a"
        let filler = String(repeating: "bounded tokenizer fixture evidence ", count: 1_000)
        for i in 0..<3_200 {
            let id = "bulk-\(i)"
            var row = try JSONSerialization.data(withJSONObject: ["id": id, "parentId": parent, "type": "message", "message": ["role": "assistant", "content": filler]])
            row.append(10); try file.write(contentsOf: row); parent = id
        }
        try file.close()
        let bytes = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertGreaterThan(bytes, 100 * 1_048_576)
        fixture.gateway.reply(#"{"matches":[{"id":"a","reason":"Large tokenizer journal"},{"id":"b","reason":"Small tokenizer journal"}]}"#)
        let sidebar = WorkspaceSidebarView(model: model), search = model.sidebarSearch, ask = search.askChats
        let first = AskCheckGate(), second = AskCheckGate()
        addTeardownBlock { await first.release(); await second.release(); await ask.settle() }
        ask.beforeConfirmation = { if $0 == "a" { await first.wait() } else { await second.wait() } }
        search.setScope(.ask); sidebar.setFilter("tokenizer"); search.submit(); await ask.settleRanking()
        for _ in 0..<500 { if await first.entered { break }; try await Task.sleep(for: .milliseconds(10)) }
        let probe = AskTextResourceProbe(root: model.root)
        let start = ContinuousClock.now
        probe.start(); await first.release()
        for _ in 0..<36_000 { if await second.entered { break }; try await Task.sleep(for: .milliseconds(10)) }
        let reached = await second.entered
        let elapsed = start.duration(to: .now), stats = probe.stop()
        XCTAssertTrue(reached, "The large check completed within six minutes")
        XCTAssertNotNil(ask.hits["a"])
        print("ASK_TEXT_MEASURE bytes=\(bytes) seconds=\(elapsed) disk_peak_bytes=\(stats.disk) footprint_start_bytes=\(stats.start) footprint_peak_bytes=\(stats.peak) footprint_delta_bytes=\(stats.peak - stats.start)")
        if testEnvironment("PI_APP_ASK_BASELINE") != "1" { XCTAssertEqual(stats.disk, 0, "No transcript text is written during confirmation") }
        await second.release(); await ask.settle()
    }
}

private final class AskTextResourceProbe: @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ask.text.measure")
    private var timer: DispatchSourceTimer?
    private var disk = 0, peak: UInt64 = 0, initial: UInt64 = 0
    init(root: URL) { self.root = root }
    private func sample() {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) }
        }
        var size = 0
        for folder in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where folder.lastPathComponent.hasPrefix("ask-text-") {
            if let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in files { size += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
            }
        }
        lock.withLock {
            disk = max(disk, size)
            if result == 0 { peak = max(peak, usage.ri_phys_footprint); if initial == 0 { initial = usage.ri_phys_footprint } }
        }
    }
    func start() {
        sample()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20)); timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer; timer.resume()
    }
    func stop() -> (disk: Int, start: UInt64, peak: UInt64) {
        timer?.cancel(); timer = nil
        queue.sync { sample() }
        return lock.withLock { (disk, initial, peak) }
    }
}
