import XCTest
import AppKit
import SwiftUI
@testable import PiApp

/// A chat's cost limit as the owner meets it: the Settings default every chat
/// runs under, a chat's own limit kept with the chat, the notice where a run
/// stopped at it and what Raise limit… does, and the spend-of-limit figure.
/// The end-to-end cases run on the packaged helper against the wire gateway,
/// whose "wire paid" replies report a cost of $0.004 each.
final class CostLimitTests: XCTestCase {
    /// A model on a scratch store and vault, restored the way launch does, with chats on disk.
    @MainActor private func model(root: URL, vault: ConfigurationVault? = nil, chats names: [String]) async throws -> (model: WorkspaceModel, vault: ConfigurationVault, chats: [ChatRecord]) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = WorkspaceRecord(id: "cost-project", path: root.path, trusted: true)
        var profile = ProfileRecord()
        profile.id = "cost-connection"; profile.name = "Cost connection"; profile.api = LiteLLMConfiguration.supportedAPI
        profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "cost-model"; profile.contextWindow = 200_000; profile.maxOutputTokens = 32_000
        var configuration = VaultConfiguration()
        configuration.workspaces = [workspace]; configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-cost-key")]
        let vault = try vault ?? ConfigurationVault(storage: MemoryVaultStorage(JSONEncoder().encode(configuration)))
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("app-state"), vault: vault)
        await model.restore()
        var records = model.chats
        for name in names where !records.contains(where: { $0.title == name }) {
            let chat = ChatRecord(id: "chat-" + name, workspaceID: workspace.id, title: name, path: nil, profileID: profile.id)
            try await model.store?.put(chat, kind: "chat", id: chat.id); records.append(chat)
        }
        model.chats = records
        return (model, vault, names.compactMap { name in records.first { $0.title == name } })
    }

    /// Every chat without its own limit runs under the Settings default: $25
    /// as shipped, whatever the owner saves after, and what a session open
    /// sends the helper. A chat's own limit wins over it. A disabled default
    /// is "no limit" on the wire.
    @MainActor func testSettingsDefaultAppliesToChatsWithoutTheirOwnLimit() async throws {
        let root = scratchRoot("cost-default")
        let bench = try await model(root: root, chats: ["Follows", "Own"])
        let model = bench.model
        registerWorkspaceFixtureTeardown(model, root: root)
        let follows = bench.chats[0], own = bench.chats[1]
        XCTAssertEqual(model.defaultCostLimit, .usd(25), "Chats are limited to $25 unless the owner says otherwise")
        XCTAssertEqual(model.costLimit(for: follows.id), .usd(25))
        try await model.setDefaultCostLimit(.usd(10))
        try await model.setCostLimit(.usd(3), for: own.id)
        XCTAssertEqual(model.costLimit(for: follows.id), .usd(10), "The default applies to a chat without its own limit")
        XCTAssertEqual(model.costLimit(for: own.id), .usd(3), "A chat's own limit wins over the default")
        XCTAssertEqual(model.costReading(for: follows.id).source, "Default · $10.00")
        let opening = await model.costLimitParams(for: try XCTUnwrap(model.record(follows.id)))
        XCTAssertEqual(opening["costLimit"], .object(["usd": .number(10)]), "A session open carries the default")
        try await model.setDefaultCostLimit(.unlimited)
        XCTAssertEqual(model.costLimit(for: follows.id), .unlimited)
        let unlimited = await model.costLimitParams(for: try XCTUnwrap(model.record(follows.id)))
        XCTAssertEqual(unlimited["costLimit"], .object(["usd": .null]), "No limit reaches the helper as none")
        XCTAssertEqual(model.costLimit(for: own.id), .usd(3))
        // The default is the vault's: a relaunch reads it back.
        model.shutdown(); await model.store?.close(); try? await model.traces.close()
        let relaunched = try await self.model(root: root, vault: bench.vault, chats: ["Follows", "Own"]).model
        registerWorkspaceFixtureTeardown(relaunched, root: root)
        XCTAssertEqual(relaunched.defaultCostLimit, .unlimited)
        var bad = VaultConfiguration(); bad.chatCostLimit = .usd(-1)
        XCTAssertThrowsError(try bad.validate(persisted: false), "A vault never holds a limit that is not a positive amount")
    }

    /// A chat's own limit is kept with the chat: after a relaunch it is still
    /// the limit that chat runs under, "No limit" included, and a chat that
    /// never chose one still follows the default.
    @MainActor func testAChatsOwnLimitPersistsAcrossRelaunch() async throws {
        let root = scratchRoot("cost-override")
        let bench = try await model(root: root, chats: ["Custom", "Unlimited", "Plain"])
        let model = bench.model
        try await model.setCostLimit(.usd(7.5), for: bench.chats[0].id)
        try await model.setCostLimit(.unlimited, for: bench.chats[1].id)
        try await model.setDefaultCostLimit(.usd(40))
        model.shutdown(); await model.store?.close(); try? await model.traces.close()
        let relaunched = try await self.model(root: root, vault: bench.vault, chats: []).model
        registerWorkspaceFixtureTeardown(relaunched, root: root)
        XCTAssertEqual(relaunched.chatRecord(bench.chats[0].id)?.costLimit, .usd(7.5))
        XCTAssertEqual(relaunched.chatRecord(bench.chats[1].id)?.costLimit, .unlimited)
        XCTAssertNil(relaunched.chatRecord(bench.chats[2].id)?.costLimit)
        XCTAssertEqual(relaunched.costLimit(for: bench.chats[0].id), .usd(7.5))
        XCTAssertEqual(relaunched.costLimit(for: bench.chats[1].id), .unlimited)
        XCTAssertEqual(relaunched.costLimit(for: bench.chats[2].id), .usd(40))
        // Back to the default: the chat's own choice is gone for good.
        try await relaunched.setCostLimit(nil, for: bench.chats[0].id)
        let stored = try await relaunched.store?.get(ChatRecord.self, kind: "chat", id: bench.chats[0].id)
        XCTAssertNotNil(stored); XCTAssertNil(stored?.costLimit)
    }

    /// "$spent of $limit" wherever the chat's cost shows, in warning ink from
    /// 80% of the limit on; the spend alone under no limit.
    func testSpentOfLimitReadsInWarningFromEightyPercent() {
        var totals = GatewayTotals(); totals.requests = 3; totals.costSamples = 3; totals.costUSD = 0.0025
        totals.tokens = GatewayTokenTotals(); totals.tokens?.input = 1_000; totals.tokens?.inputSamples = 3
        let plain = SessionStatsPresentation(gateway: totals, work: nil)
        XCTAssertEqual(plain.costFigure, "$0.0025", "Without a reading the request log's cost reads as before")
        var reading = SessionCostReading(limit: .usd(25), spentUSD: 0.0025, reportedRequests: 3)
        let low = SessionStatsPresentation(gateway: totals, work: nil, cost: reading)
        XCTAssertEqual(low.costFigure, "$0.0025 of $25.00"); XCTAssertFalse(low.costWarning)
        XCTAssertTrue(low.usageLabel.hasSuffix(" · $0.0025 of $25.00")); XCTAssertNil(low.usageFace.warningTail)
        reading.spentUSD = 20
        let near = SessionStatsPresentation(gateway: totals, work: nil, cost: reading)
        XCTAssertEqual(near.costFigure, "$20.00 of $25.00"); XCTAssertTrue(near.costWarning, "80% of the limit reads as a warning")
        XCTAssertEqual(near.usageFace.warningTail, "$20.00 of $25.00"); XCTAssertFalse(near.usageFace.label.contains("$"))
        reading.spentUSD = 19.99
        XCTAssertFalse(SessionStatsPresentation(gateway: totals, work: nil, cost: reading).costWarning, "Below 80% it does not")
        reading.limit = .unlimited
        XCTAssertEqual(SessionStatsPresentation(gateway: totals, work: nil, cost: reading).costFigure, "$19.99")
        XCTAssertFalse(SessionStatsPresentation(gateway: totals, work: nil, cost: reading).costWarning)
        // Before the helper has counted anything, the request log's spend is shown against the limit.
        let unread = SessionStatsPresentation(gateway: totals, work: nil, cost: SessionCostReading(limit: .usd(0.003)))
        XCTAssertEqual(unread.costFigure, "$0.0025 of $0.003"); XCTAssertTrue(unread.costWarning)
        let over = SessionCostReading(limit: .usd(5), spentUSD: 5.12, reportedRequests: 9, unreportedRequests: 2)
        XCTAssertTrue(over.reached); XCTAssertEqual(over.figure, "$5.12 of $5.00"); XCTAssertEqual(CostLimitMeter.percent(over.fraction ?? 0), "102%")
        XCTAssertEqual(over.unreportedNote, "2 requests reported no cost")
        XCTAssertEqual(CostLimit.parse("$12.50"), .usd(12.5)); XCTAssertEqual(CostLimit.parse("0.001"), .usd(0.001))
        XCTAssertNil(CostLimit.parse("0")); XCTAssertNil(CostLimit.parse("-3")); XCTAssertNil(CostLimit.parse("ten"))
    }

    /// A run that reaches its limit stops before its next request, and the
    /// conversation says so where it stopped, with Raise limit…: the button
    /// opens the chat's limit editor, a raised limit reaches the helper, the
    /// notice then offers Continue, and the stopped turn goes on from there.
    /// The usage pill and the Inspector's Overview read "$0.004 of $0.003" meanwhile.
    @MainActor func testTheStopNoticeAppearsAndRaiseLimitContinuesTheRun() async throws {
        let chat = try await WireChat(); defer { Task { await chat.close() } }
        try await chat.model.setCostLimit(.usd(0.003), for: chat.id)
        chat.send("wire paid-tool")
        try await chat.waitUntil("the run stopped at its limit") { chat.session.state == "error" && chat.session.failureCode == "cost_limit" }
        let notice = try XCTUnwrap(chat.session.presentedMessages.last)
        XCTAssertEqual(notice.failureCode, "cost_limit")
        XCTAssertEqual(notice.text, "This chat reached its $0.003 cost limit ($0.004 spent). Raise the limit to continue.")
        XCTAssertEqual(chat.card("bash")?.state, "completed", "The request in flight was not cut: its tool ran")
        XCTAssertFalse(chat.replyRows.contains { $0.text.contains("Tool round finished") }, "The next request was not sent")
        try await chat.waitUntil("the usage figure shows the spend against the limit") {
            Self.trigger("session-stats-usage", in: chat.hosted)?.accessibilityLabel()?.contains("$0.004 of $0.003") == true
        }
        // The pill opens the chat's Session Inspector, whose Overview reads
        // the same spend against the limit, with the limit's editor.
        try XCTUnwrap(Self.trigger("session-stats-usage", in: chat.hosted)).performClick(nil)
        let inspector = try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID: chat.id))
        XCTAssertEqual(inspector.inspector.page, .overview)
        let window = try XCTUnwrap(inspector.window)
        var overview = ""
        let read = Date().addingTimeInterval(20)
        repeat {
            overview = try await SessionTimingTests.recognizedText(in: window)
            // The recognized text comes back in lower case.
            if overview.contains("0.004 of $0.003"), overview.contains("cost limit") { break }
        } while Date() < read
        XCTAssertTrue(overview.contains("0.004 of $0.003"), "The Overview's cost reads against the limit. OCR: \(overview)")
        XCTAssertTrue(overview.contains("cost limit"), "The Overview carries the limit's editor. OCR: \(overview)")
        inspector.close()
        // Raise limit… opens the editor over itself.
        let raise = try await Self.waitForTrigger("cost-limit-raise", in: chat)
        raise.performClick(nil)
        try await chat.waitUntil("the limit editor opened") { CostLimitPopover.shared.presenter.isShown && CostLimitPopover.shared.sessionID == chat.id }
        // What the editor's $10 chip does: the chat's own limit, saved and sent.
        try await chat.model.setCostLimit(.usd(10), for: chat.id)
        CostLimitPopover.shared.close()
        XCTAssertTrue(chat.replies.contains { $0.method == "session.configure" && $0.params["costLimit"] == .object(["usd": .number(10)]) },
                      "The raised limit reached the helper session")
        try await chat.waitUntil("the notice offers Continue") { chat.session.presentedMessages.last?.failureCode == "cost_limit_raised" }
        // The page's row for the notice is the raised one: Continue in place
        // of Raise limit…. (Whether AppKit has already let go of the old
        // button's view depends on the display cycle, so the row is read.)
        try await chat.waitUntil("the page draws the notice raised") {
            ConversationPaneTests.views(TranscriptRowContainer.self, in: chat.hosted).contains { row in
                if case .message(let message) = row.item { return message.failureCode == SessionDisplay.costLimitRaised }
                return false
            }
        }
        chat.model.costLimitNotice(.continueRun, sessionID: chat.id, anchor: nil)
        try await chat.waitUntil("the stopped turn went on") {
            !chat.session.busy && chat.session.failureMessage == nil && chat.replyRows.contains { $0.text.contains("Tool round finished") }
        }
        try await chat.waitUntil("the spend counts the request that went on") { abs((chat.session.footer.cost.spentUSD ?? 0) - 0.008) < 1e-9 }
        XCTAssertFalse(chat.session.presentedMessages.contains { $0.failureCode != nil })
    }

    /// Sending in a chat at its limit shows the same notice instead of
    /// failing quietly, and the message goes back to the composer; with the
    /// default disabled a chat is never stopped for what it costs.
    @MainActor func testSendingAtTheLimitShowsTheNoticeAndADisabledDefaultNeverStops() async throws {
        let chat = try await WireChat(); defer { Task { await chat.close() } }
        try await chat.model.setDefaultCostLimit(.usd(0.003))
        // A chat that follows the default hears the new default at once.
        try await chat.waitUntil("the open session heard the new default") {
            chat.replies.contains { $0.method == "session.configure" && $0.params["costLimit"] == .object(["usd": .number(0.003)]) }
        }
        try await chat.sendAndWait("wire paid") { $0.contains { $0.text == "Wire reply." } }
        chat.send("wire paid again")
        try await chat.waitUntil("the refused message shows the notice") { chat.session.presentedMessages.last?.failureCode == "cost_limit" }
        let notice = try XCTUnwrap(chat.session.presentedMessages.last)
        XCTAssertTrue(notice.id.hasPrefix("failure:send:"))
        XCTAssertEqual(notice.text, "This chat reached its $0.003 cost limit ($0.004 spent). Raise the limit to continue.")
        XCTAssertEqual(chat.session.draft, "wire paid again", "The message is back where it was typed")
        _ = try await Self.waitForTrigger("cost-limit-raise", in: chat)
        // Disabled: the chat follows it, its notice goes, and it is never stopped.
        try await chat.model.setDefaultCostLimit(.unlimited)
        try await chat.waitUntil("the refused message's notice left") { chat.session.sendFailure == nil }
        for round in 0..<3 {
            try await chat.sendAndWait("wire paid \(round)") { rows in rows.filter { $0.text == "Wire reply." }.count == round + 2 }
        }
        XCTAssertEqual(chat.session.footer.cost.spentUSD ?? 0, 0.016, accuracy: 1e-9)
        XCTAssertEqual(chat.session.footer.cost.limit, .unlimited)
        XCTAssertNil(chat.session.failureMessage)
    }

    @MainActor static func trigger(_ identifier: String, in view: NSView) -> PiPopoverTriggerButton? {
        ConversationPaneTests.views(PiPopoverTriggerButton.self, in: view).first { $0.accessibilityIdentifier() == identifier }
    }
    @MainActor static func waitForTrigger(_ identifier: String, in chat: WireChat) async throws -> PiPopoverTriggerButton {
        var found: PiPopoverTriggerButton?
        try await chat.waitUntil("\(identifier) is on screen") { found = trigger(identifier, in: chat.hosted); return found != nil }
        return try XCTUnwrap(found)
    }
}
