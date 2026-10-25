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
        // The sidebar can resolve its label before the queued Settings observer.
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
}

final class SidebarAskPublishingTests: XCTestCase {
    @MainActor func testAColdIndexHeldOnAnUnrelatedChatCannotHoldRankingsAndSnippetsFillWithoutMovingRows() async throws {
        let fixture = try await AskFixture.make(self, second: true), model = fixture.model
        try await fixture.chat("a", title: "Tokenizer checklist", brief: "Tokenizer retry checklist")
        try await fixture.chat("b", title: "Parser retry migration", brief: "Parser retries")
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
        let first = try XCTUnwrap(sidebar.list.views["chat|b"]), second = try XCTUnwrap(sidebar.list.views["chat|a"])
        let firstY = first.frame.minY, secondY = second.frame.minY
        XCTAssertEqual(ask.checkingIDs, ["a", "b"])
        XCTAssertNotNil(sidebar.list.views["snippet|b"]); XCTAssertNotNil(sidebar.list.views["snippet|a"])
        await snippetGate.release()
        try await eventually("Each excerpt publishes when its own journal is checked") { ask.hits["b"] != nil }
        XCTAssertNil(ask.hits["a"]); XCTAssertEqual(ask.checkingIDs, ["a"])
        sidebar.settle()
        XCTAssertEqual(first.frame.minY, firstY); XCTAssertEqual(second.frame.minY, secondY)
        await secondGate.release()
        try await eventually("The two selected journals supply their excerpts without the library pass", timeout: .seconds(10)) { ask.hits.count == 2 }
        sidebar.settle()
        XCTAssertEqual(first.frame.minY, firstY); XCTAssertEqual(second.frame.minY, secondY)
        await ask.settle(); sidebar.settle()
        XCTAssertEqual(second.frame.minY, secondY, "Finishing confirmation cannot remove a progress row's space")
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
            var oldCheckReturned = false
            ask.beforeConfirmation = { id in
                if id == "a" { await gate.wait(); oldCheckReturned = true }
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
            switch action {
            case "ask": fixture.gateway.reply(#"{"matches":[]}"#); search.submit(); await ask.settle()
            case "cancel": ask.cancel()
            case "mode": search.setScope(.fullChats)
            default: ask.chooseConnection("other", question: search.query); await ask.settle()
            }
            let newMatches = ask.matches, newHits = ask.hits, newStatus = ask.status
            await gate.release()
            try await eventually("The old journal check returns") { oldCheckReturned }
            await Task.yield()
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
}

final class SidebarAskKeyboardTests: XCTestCase, SerialTestLane {
    @MainActor func testTabReachesTheChooserAndVoiceOverNamesItsCurrentConnection() async throws {
        let fixture = try await AskFixture.make(self, second: true), model = fixture.model
        try await fixture.chat("a", title: "Studio checklist")
        try await fixture.chat("b", title: "Research parser", profile: "other")
        let sidebar = WorkspaceSidebarView(model: model)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 200, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = sidebar
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        model.sidebarSearch.setScope(.ask); sidebar.setFilter("Find notes"); sidebar.settle()
        XCTAssertTrue(window.makeFirstResponder(sidebar.searchScope.tab(.ask)))
        window.selectNextKeyView(nil)
        XCTAssertTrue(window.firstResponder === sidebar.askConnection)
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
