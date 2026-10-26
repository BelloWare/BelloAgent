import XCTest
import AppKit
@testable import PiApp

/// The shared cost limit pauses the whole family at once and only Resume
/// continues it (owner, 2026-10-16), as the reader meets it: the packaged
/// helper and the synthetic gateway behind a chat and its side, the app's own
/// quit between two launches, Raise limit and Resume.
final class CostPauseFamilyTests: XCTestCase {
    /// A root needed only for its budget has no transcript. Its raised limit
    /// still reaches nested sides and sub-agents through the UI's save path.
    @MainActor func testARaiseUpdatesNestedFamilyComposerLinesWithoutAnOwnerDisplay() async throws {
        let setup = try await gatewayWorkspace("cost-pause-lines", projectID: "cost-pause-lines-project")
        let model = await launch(setup)
        let main = ChatRecord(id: "main", workspaceID: setup.workspace.id, title: "Main", profileID: setup.profile.id, costLimit: .usd(0.5))
        let side = ChatRecord(id: "side", workspaceID: main.workspaceID, title: "Side", path: setup.state.appendingPathComponent("side_side.jsonl").path, profileID: main.profileID, parentSessionID: main.id)
        let nested = ChatRecord(id: "nested", workspaceID: main.workspaceID, title: "Nested", path: setup.state.appendingPathComponent("side_nested.jsonl").path, profileID: main.profileID, parentSessionID: side.id)
        var link = SubagentTranscriptTests.link; link.budgetOwnerSessionID = main.id; link.childSessionID = "child"
        let child = ChatRecord(id: "child", workspaceID: main.workspaceID, title: "Child", profileID: main.profileID, parentSessionID: main.id, delegation: link)
        model.chats = [main, side, nested, child]
        for chat in model.chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
        model.observeCost(["cost": .object(["spentUSD": .number(0.6), "limitUSD": .number(0.5), "paused": .bool(true)])], sessionID: main.id)
        for chat in [side, nested, child] {
            let view = SessionDisplay(id: chat.id); view.isManagedSubagent = chat.isSubagent
            view.observeRunState(["state": .string("paused"), "costPaused": .bool(true), "errorCode": .string("cost_limit"), "continuable": .bool(!chat.isSubagent)])
            view.preflightNotice = "Paused at the shared cost limit. Raise the main chat’s limit above the spend, then choose Resume."
            model.displays[chat.id] = view; model.refreshCostReading(chat.id)
            XCTAssertTrue(view.costLimitHeld)
        }
        try await model.setCostLimit(.usd(100), for: main.id)
        for chat in [side, nested, child] {
            let view = try XCTUnwrap(model.displays[chat.id])
            XCTAssertEqual(view.notice, "The main chat’s limit is now $100.00." + (chat.isSubagent ? " This sub-agent goes on when the main chat resumes." : " Choose Resume to continue."))
            XCTAssertFalse(view.costLimitHeld); XCTAssertTrue(view.costPaused)
            XCTAssertEqual(view.offersResume, !chat.isSubagent)
        }
        XCTAssertNil(model.displays[main.id]); XCTAssertTrue(model.hosts.isEmpty, "A raise starts no work or helper")
    }

    private typealias Setup = GatewayWorkspace

    @MainActor private func launch(_ setup: Setup) async -> WorkspaceModel {
        let model = WorkspaceModel(stateRoot: setup.state, vault: setup.vault)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WorkspaceRootView(model: model)
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil; window.close()
            model.report.suspend(); model.shutdown()
            for host in model.hosts.values { try? await host.shutdownAndWait() }
            try? await model.traces.close(); await model.store?.close()
        }
        await model.restore()
        return model
    }

    @MainActor private func quit(_ model: WorkspaceModel) async throws {
        await waitFor("The model still had work in flight when the test quit") { !model.hasActiveWork }
        let lifecycle = ApplicationLifecycle()
        lifecycle.model = model
        var answers: [Bool] = []
        lifecycle.answerTermination = { answers.append($0) }
        XCTAssertEqual(lifecycle.applicationShouldTerminate(NSApp), .terminateLater)
        await waitFor("Quitting never answered") { !answers.isEmpty }
        model.report.suspend()
        try await model.traces.close(); await model.store?.close()
    }

    @MainActor private func waitFor(_ what: String, seconds: Double = 60, file: StaticString = #filePath, line: UInt = #line,
                                    _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(15))
        }
        XCTFail(what, file: file, line: line)
    }

    private struct Capture: Decodable { var sessionID: String?; var cancelled: Bool?; var connectionTest: Bool? }
    private static func captures(_ base: String) async throws -> [Capture] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/captures")!)
        return try JSONDecoder().decode([Capture].self, from: data).filter { $0.connectionTest != true }
    }

    /// A side streams a slow reply when the chat's own reply crosses the
    /// shared limit: the side's request is cut at once, both show the pause
    /// with spend and limit, and it survives a quit. Raising the limit resumes
    /// nothing; Resume in the chat resumes the side it names, which goes on
    /// from where it stopped.
    @MainActor func testSidePausesAtOnceSurvivesRelaunchAndResumesFromTheChatAfterARaise() async throws {
        try await pauseRelaunchAndResume(fromSide: false)
    }
    /// After a relaunch the side's Resume, with its root not yet read by
    /// anything, still resumes the whole family from the root.
    @MainActor func testAColdSidesResumeResumesItsRootFirst() async throws {
        try await pauseRelaunchAndResume(fromSide: true)
    }
    /// The root accepted Resume but its reply (and the side requests) were
    /// lost: a later family Resume still resumes the sides the root names,
    /// also one outside the loaded window of chat records.
    @MainActor func testSidesStillPausedAfterALostRootResumeAreRecovered() async throws {
        try await pauseRelaunchAndResume(fromSide: true, rootAlreadyResumed: true)
    }

    @MainActor private func pauseRelaunchAndResume(fromSide: Bool, rootAlreadyResumed: Bool = false) async throws {
        // Forty words stream for about nine seconds: the crossing lands mid-reply.
        let setup = try await gatewayWorkspace("cost-pause-family", projectID: "cost-pause-project", readme: true, gatewayEnvironment: ["PI_APP_UI_FIXTURE_SLOW_WORDS": "40"])
        let first = await launch(setup)
        first.selectedWorkspaceID = setup.workspace.id; first.profileChoice = setup.profile.id
        let parent = ChatRecord(id: "parent-" + UUID().uuidString, workspaceID: setup.workspace.id, title: "Parent", path: nil, profileID: setup.profile.id)
        first.chats = [parent]; try await first.store?.put(parent, kind: "chat", id: parent.id)
        // Each synthetic request costs $0.00125: the second one crosses $0.002.
        try await first.setCostLimit(.usd(0.002), for: parent.id)
        await first.select(parent.id)
        let parentView = try XCTUnwrap(first.displays[parent.id])
        parentView.draft = "A question for the chat"; first.send(sessionID: parent.id)
        await waitFor("The chat's first turn never finished") { !parentView.hasWork && !parentView.loading && parentView.messages.last?.role == "assistant" && parentView.messages.last?.isStreaming == false }

        first.openSide(parentID: parent.id)
        let side = try XCTUnwrap(first.sides[parent.id])
        let sideView = try XCTUnwrap(first.displays[side.id])
        sideView.draft = "A slow question for the side"; first.send(sessionID: side.id)
        await waitFor("The side's reply never started streaming") {
            first.sides[parent.id]?.kept == true && sideView.messages.last?.isStreaming == true
        }
        // The chat's reply asks to read a file and crosses the limit: that
        // call is held for Resume (owner, 2026-10-17), so the chat has work too.
        parentView.draft = "Please read fixture README.md"; first.send(sessionID: parent.id)
        let crossed = Date()
        await waitFor("The family never paused") { parentView.costPaused && sideView.costPaused && !sideView.busy && !parentView.busy }
        XCTAssertLessThan(Date().timeIntervalSince(crossed), 7, "The side's slow reply was cut, not drained")
        var cut: [Capture] = []
        for _ in 0..<200 {
            // The gateway notices the closed stream at its next chunk.
            cut = try await Self.captures(setup.base).filter { $0.sessionID == side.id }
            if cut.last?.cancelled == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(cut.last?.cancelled, true, "The side's request in flight was cancelled at the limit")
        await waitFor("The cards never read the spend") {
            [parentView, sideView].allSatisfy { $0.presentedMessages.last?.failureCode == SessionDisplay.costPausedCode }
        }
        for (view, shared) in [(parentView, false), (sideView, true)] {
            let card = try XCTUnwrap(view.presentedMessages.last)
            XCTAssertEqual(card.failureCode, SessionDisplay.costPausedCode)
            XCTAssertEqual(card.text, shared ? "$0.0025 spent of the main chat’s $0.002 limit." : "$0.0025 spent of the $0.002 limit.")
            XCTAssertTrue(card.detail?.contains("Nothing resumes until you choose Resume") == true, card.detail ?? "")
            XCTAssertFalse(view.offersResume, "Resume waits for a raised limit")
        }
        XCTAssertEqual(first.runHolds[parent.id]?.state, "paused")
        let sent = try await Self.captures(setup.base).count, sideSent = cut.count
        let cutParent = try await Self.captures(setup.base).filter { $0.sessionID == parent.id }.count
        if fromSide {
            // Relaunch onto another chat: nothing reads the root before Resume.
            let other = ChatRecord(id: "other-" + UUID().uuidString, workspaceID: setup.workspace.id, title: "Other", path: nil, profileID: setup.profile.id)
            first.chats.append(other); try await first.store?.put(other, kind: "chat", id: other.id)
            await first.select(other.id); await first.flushSelection()
        }
        try await quit(first)

        let second = await launch(setup)
        if fromSide {
            try await second.setCostLimit(.usd(1), for: parent.id)
            XCTAssertNil(second.displays[parent.id], "Nothing has read the root")
            let rootRecord = try XCTUnwrap(second.record(parent.id))
            let host = try await second.open(rootRecord, budgetDependency: true)
            if rootAlreadyResumed {
                // As if the root's Resume was accepted and the app quit before
                // asking the sides: the side is still paused.
                let accepted = await second.performResume(rootRecord, view: nil, member: true)
                XCTAssertNotNil(accepted)
                try await Task.sleep(for: .milliseconds(300))
                let members = try? await host.request("session.status", sessionID: parent.id, params: ["budgetOnly": .bool(true)]).object?["cost"]?.object?["pausedMembers"]?.array?.compactMap(\.string)
                XCTAssertEqual(members, [side.id], "The resumed root still names its paused side")
                // Round 6: the side is outside the loaded window (more than
                // 10,000 newer records): its record is read from the store.
                let stored = try await second.store?.loadChats(ids: [side.id])
                XCTAssertEqual(stored?.first?.id, side.id)
                second.chats.removeAll { $0.id == side.id }
                XCTAssertNil(second.record(side.id))
                // Round 7: through the ordinary entry point. The root's own
                // pause is over, yet it still shows the family's pause and
                // offers Resume, which reaches the waiting side.
                await second.select(parent.id)
                let rootView = try XCTUnwrap(second.displays[parent.id])
                await waitFor("The root never offered Resume for its waiting side") {
                    rootView.runStateKnown && rootView.costPaused && rootView.offersResume
                }
                second.resumeRun(sessionID: parent.id)
            } else {
                second.resumeCostPausedFamily(from: try XCTUnwrap(second.record(side.id)))
            }
            var done = false
            for _ in 0..<600 where !done {
                let main = try? await host.request("session.status", sessionID: parent.id, params: ["budgetOnly": .bool(true)]).object
                let sideState = try? await host.request("session.status", sessionID: side.id).object
                let sideRequests = try await Self.captures(setup.base).filter { $0.sessionID == side.id }.count
                let mainState = try? await host.request("session.status", sessionID: parent.id).object
                done = main?["cost"]?.object?["paused"] == nil && mainState?["state"]?.string == "idle" && sideState?["state"]?.string == "idle"
                    && sideState?["costPaused"] == nil && sideRequests > sideSent
                if !done { try await Task.sleep(for: .milliseconds(50)) }
            }
            XCTAssertTrue(done, "The root and its side never both resumed")
            XCTAssertNil(second.error, second.error ?? "")
            return
        }
        await second.select(parent.id)
        let reopened = try XCTUnwrap(second.displays[parent.id])
        await waitFor("The chat never read its paused state") { reopened.runStateKnown && reopened.costPaused }
        // Read from the journal before any helper: the spend is not known
        // yet, so Resume is offered and the helper refuses it at the limit.
        XCTAssertEqual(reopened.presentedMessages.last?.failureCode, SessionDisplay.costPausedRaisedCode)
        XCTAssertEqual(second.runHolds[parent.id]?.state, "paused")
        second.resumeRun(sessionID: parent.id)
        await waitFor("Resume at the limit was not refused") { reopened.notice.contains("cost limit") && !reopened.resuming }
        await waitFor("The helper's reading never held the card") { reopened.presentedMessages.last?.failureCode == SessionDisplay.costPausedCode }
        XCTAssertFalse(reopened.offersResume)
        let refused = try await Self.captures(setup.base).count
        XCTAssertEqual(refused, sent, "A refused Resume sends nothing")
        try await second.setCostLimit(.usd(1), for: parent.id)
        await waitFor("The card never offered Resume") { reopened.presentedMessages.last?.failureCode == SessionDisplay.costPausedRaisedCode }
        XCTAssertTrue(reopened.offersResume)
        XCTAssertTrue(reopened.presentedMessages.last?.detail?.contains("with any paused sides and sub-agents") == true)
        try await Task.sleep(for: .milliseconds(400))
        let afterRaise = try await Self.captures(setup.base).count
        XCTAssertEqual(afterRaise, sent, "Raising the limit resumes nothing")

        second.resumeRun(sessionID: parent.id)
        let host = try XCTUnwrap(second.hosts[setup.workspace.id])
        var resumed = false
        for _ in 0..<600 where !resumed {
            let state = try? await host.request("session.status", sessionID: side.id).object
            let sideRequests = try await Self.captures(setup.base).filter { $0.sessionID == side.id }.count
            resumed = state?["state"]?.string == "idle" && state?["costPaused"] == nil && sideRequests > sideSent
            if !resumed { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertTrue(resumed, "The side the chat named never resumed and finished")
        await waitFor("The chat's pause never ended") { !reopened.costPaused && !reopened.resuming }
        let after = try await Self.captures(setup.base)
        XCTAssertEqual(after.filter { $0.sessionID == side.id }.count, sideSent + 1, "One continuation for the side")
        XCTAssertEqual(after.filter { $0.sessionID == parent.id }.count, cutParent + 1, "The held read ran, then one request")
        XCTAssertTrue(reopened.messages.contains { $0.text.contains("Fixture read completed") })
        XCTAssertNil(second.error, second.error ?? "")
    }

    /// LIMIT-1, for a family: the chat's limit is raised to $100 but its
    /// helper is still under the old one (a send that never reached it). The
    /// side's Resume, which is the family's, gives the chat's helper the
    /// chat's limit first: the chat and its side both go on, from where each
    /// stopped. Before LIMIT-1 the helper refused both at the old limit.
    @MainActor func testAFamilyResumeGivesTheChatsHelperItsRaisedLimitFirst() async throws {
        let setup = try await gatewayWorkspace("cost-pause-limit", projectID: "cost-pause-limit-project", readme: true, gatewayEnvironment: ["PI_APP_UI_FIXTURE_SLOW_WORDS": "40"])
        let model = await launch(setup)
        model.selectedWorkspaceID = setup.workspace.id; model.profileChoice = setup.profile.id
        let parent = ChatRecord(id: "parent-" + UUID().uuidString, workspaceID: setup.workspace.id, title: "Parent", path: nil, profileID: setup.profile.id)
        model.chats = [parent]; try await model.store?.put(parent, kind: "chat", id: parent.id)
        // Each synthetic request costs $0.00125: the second one crosses $0.002.
        try await model.setCostLimit(.usd(0.002), for: parent.id)
        await model.select(parent.id)
        let parentView = try XCTUnwrap(model.displays[parent.id])
        parentView.draft = "A question for the chat"; model.send(sessionID: parent.id)
        await waitFor("The chat's first turn never finished") { !parentView.hasWork && !parentView.loading && parentView.messages.last?.role == "assistant" && parentView.messages.last?.isStreaming == false }
        model.openSide(parentID: parent.id)
        let side = try XCTUnwrap(model.sides[parent.id])
        let sideView = try XCTUnwrap(model.displays[side.id])
        sideView.draft = "A slow question for the side"; model.send(sessionID: side.id)
        await waitFor("The side's reply never started streaming") { model.sides[parent.id]?.kept == true && sideView.messages.last?.isStreaming == true }
        parentView.draft = "Please read fixture README.md"; model.send(sessionID: parent.id)
        await waitFor("The family never paused") { parentView.costPaused && sideView.costPaused && !sideView.busy && !parentView.busy }
        let host = try XCTUnwrap(model.hosts[setup.workspace.id])
        func helperLimit() async throws -> Double? {
            try await host.request("session.status", sessionID: parent.id, params: ["budgetOnly": .bool(true)]).object?["cost"]?.object?["limitUSD"]?.number
        }
        try await model.setCostLimit(.usd(100), for: parent.id)
        XCTAssertEqual(parentView.notice, "The limit is now $100.00. Choose Resume to continue.")
        XCTAssertEqual(sideView.notice, "The main chat’s limit is now $100.00. Choose Resume to continue.")
        var limit = try await helperLimit()
        XCTAssertEqual(limit, 100)
        // Back under the old limit, as a send that never reached it left it.
        _ = try await host.request("session.configure", sessionID: parent.id, params: ["costLimit": CostLimit.usd(0.002).wire])
        limit = try await helperLimit()
        XCTAssertEqual(limit, 0.002)
        await waitFor("The side never offered Resume") { sideView.offersResume }
        let sideSent = try await Self.captures(setup.base).filter { $0.sessionID == side.id }.count
        let parentSent = try await Self.captures(setup.base).filter { $0.sessionID == parent.id }.count
        model.resumeRun(sessionID: side.id)
        var resumed = false
        for _ in 0..<600 where !resumed {
            let main = try? await host.request("session.status", sessionID: parent.id).object
            let sideState = try? await host.request("session.status", sessionID: side.id).object
            let captures = try await Self.captures(setup.base)
            resumed = main?["state"]?.string == "idle" && main?["costPaused"] == nil && sideState?["state"]?.string == "idle" && sideState?["costPaused"] == nil
                && captures.filter { $0.sessionID == side.id }.count > sideSent && captures.filter { $0.sessionID == parent.id }.count > parentSent
            if !resumed { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertTrue(resumed, "The chat and its side never both went on (notices: “\(parentView.notice)”, “\(sideView.notice)”)")
        limit = try await helperLimit()
        XCTAssertEqual(limit, 100, "The chat's helper runs under the chat's limit")
        // (A title request may complain about the fixture's missing mini model.)
        XCTAssertFalse((model.error ?? "").contains("cost limit"), model.error ?? "")
    }
}
