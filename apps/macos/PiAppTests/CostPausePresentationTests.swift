import XCTest
@testable import PiApp

/// How a family paused at its shared cost limit reads (owner, 2026-10-16):
/// the card with spend and limit, Raise limit… until the limit is above the
/// spend, then Resume; sub-agent cards, picker rows and readers say Paused.
final class CostPausePresentationTests: XCTestCase {
    @MainActor private func paused(_ id: String, child: Bool = false) -> SessionDisplay {
        let view = SessionDisplay(id: id); view.isManagedSubagent = child
        view.observeRunState(["state":.string("paused"), "runStatus":.string("cancelled"), "queuePaused":.bool(true),
            "continuable":.bool(!child), "costPaused":.bool(true), "errorCode":.string("cost_limit"),
            "preflightError":.string("Paused at the cost limit: $0.60 spent of $0.50. Raise the limit above the spend, then choose Resume.")])
        return view
    }

    @MainActor func testTheCardOffersRaiseLimitAtTheLimitAndResumeOnlyAfterARaise() throws {
        let view = paused("main")
        view.applyCostReading(SessionCostReading(limit: .usd(0.5), spentUSD: 0.6, reportedRequests: 3, unreportedRequests: 2))
        var card = try XCTUnwrap(view.presentedMessages.last)
        XCTAssertEqual(card.id, "paused:run:main"); XCTAssertEqual(card.failureCode, SessionDisplay.costPausedCode)
        XCTAssertEqual(card.text, "$0.60 spent of the $0.50 limit.")
        XCTAssertEqual(card.detail, "Raise the limit above the spend. Nothing resumes until you choose Resume. 2 requests reported no cost, so the spend may be higher.")
        XCTAssertFalse(view.offersResume, "Resume is unavailable while the spend is at the limit")
        XCTAssertEqual(view.runHold, "paused")
        // Raised: the card changes, and still nothing resumes by itself.
        view.applyCostReading(SessionCostReading(limit: .usd(5), spentUSD: 0.6, reportedRequests: 3))
        card = try XCTUnwrap(view.presentedMessages.last)
        XCTAssertEqual(card.failureCode, SessionDisplay.costPausedRaisedCode)
        XCTAssertEqual(card.detail, "The limit is now $5.00. Resume goes on from where the work stopped, with any paused sides and sub-agents.")
        // Later figures reach the card while it is paused.
        view.applyCostReading(SessionCostReading(limit: .usd(6), spentUSD: 0.7, reportedRequests: 4))
        XCTAssertEqual(view.presentedMessages.last?.text, "$0.70 spent of the $6.00 limit.")
        XCTAssertTrue(view.offersResume); XCTAssertTrue(view.costPaused)
        view.resuming = true
        XCTAssertEqual(view.presentedMessages.last?.failureCode, SessionDisplay.costPausedResumingCode, "No second Resume while one is on its way")
        view.resuming = false
        // Removing the limit reads as such.
        view.applyCostReading(SessionCostReading(limit: .unlimited, spentUSD: 0.6, reportedRequests: 3))
        card = try XCTUnwrap(view.presentedMessages.last)
        XCTAssertEqual(card.text, "$0.60 spent; there is no limit now.")
        XCTAssertTrue(card.detail?.hasPrefix("There is no limit now.") == true)
        // The helper ending the pause removes the card.
        view.observeRunState(["state":.string("idle"), "runStatus":.string("idle"), "queuePaused":.bool(false), "continuable":.bool(false)])
        XCTAssertFalse(view.presentedMessages.contains { $0.failureCode?.hasPrefix("cost_paused") == true })
    }

    @MainActor func testSidesNameTheSharedLimitAndChildrenHaveNoActionOfTheirOwn() throws {
        let side = paused("side")
        var reading = SessionCostReading(limit: .usd(0.5), spentUSD: 0.1, reportedRequests: 1)
        reading.budgetOwnerID = "main"; reading.budgetSpentUSD = 0.6
        side.applyCostReading(reading)
        let card = try XCTUnwrap(side.presentedMessages.last)
        XCTAssertEqual(card.text, "$0.60 spent of the main chat’s $0.50 limit.")
        XCTAssertTrue(card.detail?.hasPrefix("Raise the main chat’s limit above the spend.") == true)
        let child = paused("child", child: true)
        child.applyCostReading(reading)
        let childCard = try XCTUnwrap(child.presentedMessages.last)
        XCTAssertEqual(childCard.failureCode, SessionDisplay.costPausedChildCode)
        XCTAssertEqual(childCard.text, "$0.60 spent of the main chat’s $0.50 limit. This sub-agent goes on when the main chat resumes.")
        XCTAssertNil(childCard.detail); XCTAssertFalse(child.offersResume)
        XCTAssertEqual(PiSessionState.label("paused", costLimited: true), "Paused · cost limit")
    }

    func testSubagentCardsAndFamilyRowsSayPausedWithoutCountingAsWork() throws {
        var summary = SubagentSummary(link: subagentLink("child"), description: "Worker", model: "fixture", status: .queued, revision: 4, turn: 1)
        summary.costPaused = true
        XCTAssertTrue(summary.pausedAtCostLimit)
        XCTAssertEqual(summary.presentationLabel, "Paused at cost limit · turn 1")
        var tool = ToolView(id: "start", name: "subagent_start", state: "completed", input: #"{"task":"Worker","mode":"background"}"#,
                            output: #"{"accepted":true,"child_id":"child","turn":1}"#, truncated: false)
        tool.subagent = summary
        XCTAssertTrue(SubagentToolView(tool).label.hasPrefix("Paused at cost limit"))
        summary.status = .completed
        XCTAssertFalse(summary.pausedAtCostLimit, "A sealed turn is never paused")
        let chat = ChatRecord(id: "child", workspaceID: "w", title: "Worker", profileID: "p")
        let member = SubagentFamily.Member(chat: chat, status: .queued, model: "fixture", spend: nil, paused: true)
        XCTAssertEqual(member.statusLabel, "Paused")
        var activity = FamilyActivity(); activity.pausedAgents = 2
        XCTAssertEqual(activity.active, 0, "Paused work shows no spinner or working badge")
        activity.runningAgents = 1
        XCTAssertEqual(activity.label, "1 sub-agent running, 2 sub-agents paused")
    }

    private func subagentLink(_ child: String) -> SubagentLink {
        SubagentLink(delegationID: "delegation", childSessionID: child, budgetOwnerSessionID: "main",
                     call: .init(parentSessionID: "main", assistantMessageID: "assistant", toolCallID: "start"),
                     parentTurnID: "turn", parentExecutionID: "execution")
    }
}

extension CostPausePresentationTests {
    /// After a relaunch, before any helper starts, an unsealed child of a
    /// paused family reads Paused (queued), not Interrupted; without the
    /// pause it still reads Interrupted.
    @MainActor func testColdDiscoveryKeepsPausedChildrenQueued() async throws {
        for paused in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let model = try SubagentOrganizationTests.fixture(root); registerWorkspaceFixtureTeardown(model, root: root)
            model.chats.remove(at: 1)
            let family = try SubagentDiscoveryTests.family(model)
            // Unseal the child: drop its terminal row, as a parked turn has none.
            let lines = try String(contentsOf: family.path, encoding: .utf8).split(separator: "\n").filter { !$0.contains("subagent-terminal") }
            try (lines.joined(separator: "\n") + "\n").write(to: family.path, atomically: true, encoding: .utf8)
            let parent = URL(fileURLWithPath: try XCTUnwrap(model.chats[0].path))
            let handle = try FileHandle(forWritingTo: parent); try handle.seekToEnd()
            let state: [String: WireValue] = ["type": .string("custom"), "customType": .string(StateRecordTail.customType),
                "data": .object(["active": .bool(false), "queuePaused": .bool(true), "runStatus": .string("cancelled"), "costPaused": .bool(paused)])]
            var data = try JSONEncoder().encode(state); data.append(10); try handle.write(contentsOf: data); try handle.close()
            for chat in model.chats { try await model.store?.put(chat, kind: "chat", id: chat.id) }
            await model.reconcileSubagents()
            let summary = try XCTUnwrap(model.subagentSummaries[family.child])
            XCTAssertEqual(summary.status, paused ? .queued : .interrupted)
            XCTAssertEqual(summary.pausedAtCostLimit, paused)
            XCTAssertTrue(model.hosts.isEmpty, "Nothing was started to learn it")
        }
    }
}
