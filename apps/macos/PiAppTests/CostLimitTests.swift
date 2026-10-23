import XCTest
import AppKit
import SwiftUI
import SQLite3
@testable import PiApp

/// A chat's cost limit as the owner meets it: the Settings default every chat
/// runs under, a chat's own limit kept with the chat, the notice where a run
/// stopped at it and what Raise limit… does, and the spend-of-limit figure.
/// The end-to-end cases run on the packaged helper against the wire gateway,
/// whose "wire paid" replies report a cost of $0.004 each.
final class CostLimitTests: XCTestCase {
    func testMalformedOrOversizedCostFractionsHaveNoIntegerPercentage() {
        for fraction in [1e20, -1, -0.001, Double.infinity, .nan] { XCTAssertEqual(CostLimitMeter.percent(fraction), "n/a") }
        XCTAssertEqual(CostLimitMeter.percent(0.125), "13%")
        XCTAssertEqual(CostLimitMeter.percent(0.004), "<1%")
    }

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
        XCTAssertEqual(model.costReading(for: follows.id).defaultLimit, model.costReading(for: follows.id).limit, "Default chip and header resolve the same Settings limit")
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

    @MainActor func testRetryingTheSameLimitAfterAFailedWriteMakesItDurable() async throws {
        let root = scratchRoot("cost-retry")
        let bench = try await model(root: root, chats: ["Retry"])
        let model = bench.model, id = bench.chats[0].id
        registerWorkspaceFixtureTeardown(model, root: root)
        try RecoveredDraftTests.sql("CREATE TRIGGER refuse_cost BEFORE UPDATE ON records WHEN OLD.kind='chat' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", root: model.root)
        do { try await model.setCostLimit(.usd(1), for: id); XCTFail("The first write must fail") } catch {}
        XCTAssertNil(model.record(id)?.costLimit, "A failed save must not publish the choice as saved")
        try RecoveredDraftTests.sql("DROP TRIGGER refuse_cost", root: model.root)
        try await model.setCostLimit(.usd(1), for: id)
        let reopened = MetadataStore(url: model.root.appendingPathComponent("desktop.sqlite"))
        let saved = try await reopened.get(ChatRecord.self, kind: "chat", id: id)
        XCTAssertEqual(saved?.costLimit, .usd(1), "An identical retry must write the choice")
        await reopened.close()
    }

    @MainActor func testALateChatWriteCannotUndoASavedCostLimit() async throws {
        let root = scratchRoot("cost-stale-write")
        let bench = try await model(root: root, chats: ["Limit"])
        let model = bench.model, old = bench.chats[0]
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.setCostLimit(.usd(1), for: old.id)
        var delayed = old; delayed.path = root.appendingPathComponent("chat.jsonl").path
        try await model.store?.put(delayed, kind: "chat", id: old.id)
        let saved = try await model.store?.get(ChatRecord.self, kind: "chat", id: old.id)
        XCTAssertEqual(saved?.costLimit, .usd(1)); XCTAssertEqual(saved?.path, delayed.path)
    }

    @MainActor func testReselectingTheSavedLimitDuringAWriteKeepsTheLatestChoice() async throws {
        try await overlappingChoices(initial: .usd(3))
    }

    @MainActor func testReselectingTheDefaultDuringAWriteKeepsTheLatestChoice() async throws {
        try await overlappingChoices(initial: nil)
    }

    @MainActor private func overlappingChoices(initial: CostLimit?) async throws {
        let root = scratchRoot("cost-overlapping-choices")
        let bench = try await model(root: root, chats: ["Limit"])
        let model = bench.model, chat = bench.chats[0]
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.setCostLimit(initial, for: chat.id)
        let view = SessionDisplay(id: chat.id); view.snapshotInFlight = true
        model.displays[chat.id] = view
        var frames: [[String: WireValue]] = []
        let host = HostSupervisor(commandSender: { frames.append($0) })
        try await host.connect(cwd: root, state: root.appendingPathComponent("host"))
        model.hosts[chat.workspaceID] = host; model.opened.insert(chat.id)

        // Hold the real metadata write, while leaving the main actor free
        // to receive another choice from the editor.
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(model.root.appendingPathComponent("desktop.sqlite").path, &database), SQLITE_OK)
        let db = try XCTUnwrap(database)
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        var firstStarted = false, latestStarted = false
        let first = Task { firstStarted = true; try await model.setCostLimit(.usd(1), for: chat.id) }
        try await eventually("first choice entered") { firstStarted }
        let latest = Task { latestStarted = true; try await model.setCostLimit(initial, for: chat.id) }
        try await eventually("latest choice entered") { latestStarted }
        XCTAssertEqual(model.record(chat.id)?.costLimit, initial, "An uncommitted choice must not be published")
        XCTAssertFalse(frames.contains { $0["params"]?.object?["costLimit"] == CostLimit.usd(1).wire })
        XCTAssertEqual(sqlite3_exec(db, "ROLLBACK", nil, nil, nil), SQLITE_OK)

        // Neither save may wait for an earlier helper acknowledgement.
        try await eventually("both choices reached the helper") { frames.filter { $0["method"]?.string == "session.configure" }.count == 2 }
        let configurations = frames.filter { $0["method"]?.string == "session.configure" }
        for frame in configurations {
            host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(try XCTUnwrap(host.epoch)),
                "commandId": try XCTUnwrap(frame["commandId"]), "ok": .bool(true), "result": .object([:])]), connectionID: try XCTUnwrap(host.connectionID))
        }
        try await first.value; try await latest.value
        let saved = try await model.store?.get(ChatRecord.self, kind: "chat", id: chat.id)
        XCTAssertEqual(saved?.costLimit, initial, "A → B → A must save the last A")
        XCTAssertEqual(model.record(chat.id)?.costLimit, initial)
        XCTAssertEqual(configurations.last?["params"]?.object?["costLimit"], (initial ?? model.defaultCostLimit).wire)
        XCTAssertEqual(view.costLimitSent, initial ?? model.defaultCostLimit)
        try await host.shutdownAndWait()
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

    /// A run whose reply reaches the limit pauses there (owner, 2026-10-17:
    /// every chat): that reply's tool call is held, and the conversation says
    /// so with Raise limit…: the button opens the chat's limit editor, a
    /// raised limit reaches the helper but resumes nothing, the card then
    /// offers Resume, which runs the held call and goes on. The usage pill
    /// and the Inspector's Overview read "$0.004 of $0.003" meanwhile.
    @MainActor func testThePauseNoticeAppearsAndResumeRunsTheHeldCallAfterARaise() async throws {
        let chat = try await WireChat(); defer { Task { await chat.close() } }
        try await chat.model.setCostLimit(.usd(0.003), for: chat.id)
        chat.send("wire paid-tool")
        try await chat.waitUntil("the run paused at its limit") { chat.session.costPaused && !chat.session.busy }
        // The spend reading can follow the pause's snapshot under load; until
        // it does, the card offers Resume and lets the helper refuse it.
        try await chat.waitUntil("the card read the spend") { chat.session.presentedMessages.last?.failureCode == SessionDisplay.costPausedCode }
        let notice = try XCTUnwrap(chat.session.presentedMessages.last)
        XCTAssertEqual(notice.failureCode, SessionDisplay.costPausedCode)
        XCTAssertEqual(notice.text, "$0.004 spent of the $0.003 limit.")
        XCTAssertNil(chat.card("bash")?.state == "completed" ? "ran" : nil, "The reply's call is held, not run")
        XCTAssertFalse(chat.replyRows.contains { $0.text.contains("Tool round finished") }, "The next request was not sent")
        try await chat.waitUntil("the usage figure shows the spend against the limit") {
            Self.trigger("session-stats-usage", in: chat.hosted)?.accessibilityLabel()?.contains("$0.004 of $0.003") == true
        }
        try XCTUnwrap(Self.trigger("session-stats-usage", in: chat.hosted)).performClick(nil)
        let inspector = try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID: chat.id))
        XCTAssertEqual(inspector.inspector.page, .overview)
        let window = try XCTUnwrap(inspector.window)
        var overview = ""
        let read = Date().addingTimeInterval(20)
        repeat {
            overview = try await SessionTimingTests.recognizedText(in: window)
            if overview.contains("0.004 of $0.003"), overview.contains("cost limit") { break }
        } while Date() < read
        XCTAssertTrue(overview.contains("0.004 of $0.003"), "The Overview's cost reads against the limit. OCR: \(overview)")
        XCTAssertTrue(overview.contains("cost limit"), "The Overview carries the limit's editor. OCR: \(overview)")
        inspector.close()
        let raise = try await Self.waitForTrigger("cost-limit-raise", in: chat)
        raise.performClick(nil)
        try await chat.waitUntil("the limit editor opened") { CostLimitPopover.shared.presenter.isShown && CostLimitPopover.shared.sessionID == chat.id }
        try await chat.model.setCostLimit(.usd(10), for: chat.id)
        CostLimitPopover.shared.close()
        XCTAssertTrue(chat.replies.contains { $0.method == "session.configure" && $0.params["costLimit"] == .object(["usd": .number(10)]) },
                      "The raised limit reached the helper session")
        try await chat.waitUntil("the card offers Resume") { chat.session.presentedMessages.last?.failureCode == SessionDisplay.costPausedRaisedCode }
        XCTAssertTrue(chat.session.costPaused, "Raising the limit alone resumes nothing")
        try await chat.waitUntil("the page draws the card raised") {
            ConversationPaneTests.views(TranscriptRowContainer.self, in: chat.hosted).contains { row in
                if case .message(let message) = row.item { return message.failureCode == SessionDisplay.costPausedRaisedCode }
                return false
            }
        }
        chat.model.resumeRun(sessionID: chat.id)
        try await chat.waitUntil("the held call ran and the turn went on") {
            !chat.session.busy && !chat.session.costPaused && chat.replyRows.contains { $0.text.contains("Tool round finished") }
        }
        XCTAssertEqual(chat.card("bash")?.state, "completed", "The held call ran on Resume")
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
        // The reply's cost arrives with the end of its stream, after its text: send
        // at the limit only once that spend is counted and the run has ended.
        try await chat.waitUntil("the reply's spend is counted") { (chat.session.footer.cost.spentUSD ?? 0) >= 0.004 && chat.session.state == "idle" }
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
        // Each reply's cost ends its stream, after its text: wait for the last one.
        try await chat.waitUntil("every reply's spend is counted") { abs((chat.session.footer.cost.spentUSD ?? 0) - 0.016) < 1e-9 }
        XCTAssertEqual(chat.session.footer.cost.spentUSD ?? 0, 0.016, accuracy: 1e-9)
        XCTAssertEqual(chat.session.footer.cost.limit, .unlimited)
        XCTAssertNil(chat.session.failureMessage)
    }

    @MainActor static func trigger(_ identifier: String, in view: NSView) -> NSButton? {
        ConversationPaneTests.views(NSButton.self, in: view).first { $0.accessibilityIdentifier() == identifier }
    }
    @MainActor static func waitForTrigger(_ identifier: String, in chat: WireChat) async throws -> NSButton {
        var found: NSButton?
        try await chat.waitUntil("\(identifier) is on screen") { found = trigger(identifier, in: chat.hosted); return found != nil }
        return try XCTUnwrap(found)
    }
}

extension CostLimitTests {
    /// The views below the chips by their identifiers.
    @MainActor private static func view<T: NSView>(_ type: T.Type, _ identifier: String, in root: NSView) -> T? {
        if let match = root as? T, match.accessibilityIdentifier() == identifier { return match }
        for subview in root.subviews { if let found = view(type, identifier, in: subview) { return found } }
        return nil
    }

    /// The choices as the editor and Settings use them: a chip chooses at once;
    /// Custom… opens an amount field that starts from a custom limit, refuses
    /// an amount it cannot use (the Set button disabled, Return naming the
    /// range) and sets a valid one, closing again.
    @MainActor func testTheChoicesChooseAPresetOrAValidCustomAmount() throws {
        var chosen: [CostLimit?] = []
        let choices = CostLimitChoices(selection: .usd(7.5), defaultLimit: .usd(25)) { chosen.append($0) }
        choices.frame = CGRect(x: 0, y: 0, width: 348, height: choices.height(forWidth: 348))
        choices.layoutSubtreeIfNeeded()
        let custom = try XCTUnwrap(Self.view(CostLimitChip.self, "cost-limit-custom", in: choices))
        XCTAssertEqual(custom.label, "Custom · $7.50")
        XCTAssertTrue(custom.isAccessibilitySelected())
        XCTAssertFalse(try XCTUnwrap(Self.view(CostLimitChip.self, "cost-limit-default", in: choices)).isAccessibilitySelected())

        try XCTUnwrap(Self.view(CostLimitChip.self, "cost-limit-10", in: choices)).performClick(nil)
        XCTAssertEqual(chosen, [.usd(10)])
        try XCTUnwrap(Self.view(CostLimitChip.self, "cost-limit-default", in: choices)).performClick(nil)
        XCTAssertEqual(chosen.last, .some(nil), "Default follows the Settings limit")

        let closedHeight = choices.height(forWidth: 348)
        custom.performClick(nil)
        XCTAssertTrue(choices.customOpen)
        XCTAssertGreaterThan(choices.height(forWidth: 348), closedHeight, "The amount's row opens under the chips")
        XCTAssertEqual(choices.width(forProposal: 500), 500, "The choices take the width offered, as their flow did")
        let field = try XCTUnwrap(Self.view(PiKit.TextField.self, "cost-limit-custom-amount", in: choices))
        let set = try XCTUnwrap(Self.view(PiKit.Button.self, "cost-limit-custom-set", in: choices))
        XCTAssertEqual(field.text, "7.50", "The field starts from the custom limit")
        XCTAssertTrue(set.isEnabled)
        field.text = "nope"; field.onChange?("nope")
        XCTAssertFalse(set.isEnabled, "Set Limit waits for an amount it can use")
        let beforeInvalid = choices.height(forWidth: 348)
        field.onSubmit?()
        XCTAssertGreaterThan(choices.height(forWidth: 348), beforeInvalid, "Return on a bad amount names the range")
        XCTAssertEqual(chosen.count, 2, "Nothing was chosen")
        field.text = "12.5"; field.onChange?("12.5")
        XCTAssertEqual(choices.height(forWidth: 348), beforeInvalid, "Typing clears the complaint")
        set.performClick(nil)
        XCTAssertEqual(chosen.last, .some(.usd(12.5)))
        XCTAssertFalse(choices.customOpen, "Setting an amount closes the field")
        XCTAssertEqual(choices.height(forWidth: 348), closedHeight)
    }

    /// Settings sets its controls' enabled state itself: an invalid amount's
    /// Set button stays disabled through the form's pass, a valid one follows the form.
    @MainActor func testSettingsKeepsAnInvalidAmountsSetButtonDisabled() throws {
        let state = EnabledState()
        let choices = CostLimitChoices(selection: .usd(25), identifier: "settings-cost-limit") { _ in }
        choices.enabledState = state
        choices.frame = CGRect(x: 0, y: 0, width: 420, height: 120)
        try XCTUnwrap(Self.view(CostLimitChip.self, "settings-cost-limit-custom", in: choices)).performClick(nil)
        let field = try XCTUnwrap(Self.view(PiKit.TextField.self, "settings-cost-limit-custom-amount", in: choices))
        let set = try XCTUnwrap(Self.view(PiKit.Button.self, "settings-cost-limit-custom-set", in: choices))
        field.text = ""; field.onChange?("")
        state.apply(to: choices, formEnabled: true)
        XCTAssertFalse(set.isEnabled)
        field.text = "3"; field.onChange?("3")
        state.apply(to: choices, formEnabled: true)
        XCTAssertTrue(set.isEnabled)
        state.apply(to: choices, formEnabled: false)
        XCTAssertFalse(set.isEnabled)
    }

    /// The editor saves a choice and shows why a save failed; its reading
    /// follows the chat's live figures.
    @MainActor func testTheEditorSavesAndShowsAFailure() async throws {
        struct Refused: LocalizedError { var errorDescription: String? { "The vault is locked." } }
        let footer = SessionMetrics()
        footer.cost = SessionCostReading(limit: .usd(25), defaultLimit: .usd(25), spentUSD: 1, reportedRequests: 1)
        @MainActor final class Saves { var saved: [CostLimit?] = []; var refuse = true }
        let saves = Saves()
        let editor = CostLimitLiveEditor(footer: footer) { limit in
            saves.saved.append(limit)
            if saves.refuse { throw Refused() }
        }
        editor.frame = CGRect(x: 0, y: 0, width: 348, height: editor.height(forWidth: 348))
        let plain = editor.height(forWidth: 348)
        try XCTUnwrap(Self.view(CostLimitChip.self, "cost-limit-5", in: editor)).performClick(nil)
        let deadline = Date().addingTimeInterval(5)
        while editor.saving || editor.height(forWidth: 348) == plain, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(saves.saved, [.usd(5)])
        XCTAssertGreaterThan(editor.height(forWidth: 348), plain, "The failure is shown")
        func texts(_ view: NSView) -> [String] {
            var found = (view as? TextBlock).map { $0.isHidden ? [] : [$0.text] } ?? []
            for subview in view.subviews { found += texts(subview) }
            return found
        }
        XCTAssertTrue(texts(editor).contains("The vault is locked."), "The failure reads: \(texts(editor))")
        saves.refuse = false
        try XCTUnwrap(Self.view(CostLimitChip.self, "cost-limit-10", in: editor)).performClick(nil)
        while editor.saving || editor.height(forWidth: 348) != plain, Date() < deadline.addingTimeInterval(5) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(editor.height(forWidth: 348), plain, "A good save clears the failure")
        footer.cost = SessionCostReading(limit: .usd(10), override: .usd(10), defaultLimit: .usd(25), spentUSD: 9, reportedRequests: 3)
        while editor.reading != footer.cost, Date() < deadline.addingTimeInterval(10) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(editor.reading, footer.cost, "The editor follows the chat's reading")
        XCTAssertTrue(try XCTUnwrap(Self.view(CostLimitChip.self, "cost-limit-10", in: editor)).isAccessibilitySelected())
        XCTAssertEqual(editor.meter.accessibilityLabel(), "$9.00 of $10.00, 90%")
    }
}

// LIMIT-1 (owner, 2026-10-22): at the limit, $100 "got switched to $100, but
// I couldn't resume it. But if I switch it to like $50, it works." No amount
// is special: every amount above the spend resumes. A limit the chat shows
// but its helper never received was: the helper refused the Resume the card
// offered, until another choice sent a limit again. The owner's pause: the
// chat follows the $25 default, $24.99 is spent, then a reply crosses the
// limit ($25.01) and its bash call is held.
extension CostLimitTests {
    @MainActor private func pausedAtTheDefaultLimit() async throws -> WireChat {
        let chat = try await WireChat()
        do {
            try await chat.sendAndWait("wire paid usd=24.99") { $0.contains { $0.text == "Wire reply." } }
            try await chat.waitUntil("the first reply's spend is counted") {
                abs((chat.session.footer.cost.spentUSD ?? 0) - 24.99) < 1e-9 && chat.session.state == "idle"
            }
            chat.send("wire paid-tool usd=0.02")
            try await chat.waitUntil("the run paused at the default limit") { chat.session.costPaused && !chat.session.busy }
            try await chat.waitUntil("the card read the spend") { chat.session.presentedMessages.last?.failureCode == SessionDisplay.costPausedCode }
        } catch { await chat.close(); throw error }
        XCTAssertEqual(chat.session.presentedMessages.last?.text, "$25.01 spent of the $25.00 limit.")
        XCTAssertNil(chat.model.record(chat.id)?.costLimit, "The chat follows the default")
        return chat
    }
    /// The chat's limit as its helper holds it.
    @MainActor private func helperLimit(_ chat: WireChat) async throws -> CostLimit {
        let status = try await XCTUnwrap(chat.host).request("session.status", sessionID: chat.id, params: ["budgetOnly": .bool(true)])
        return status.object?["cost"]?.object?["limitUSD"]?.number.map(CostLimit.usd) ?? .unlimited
    }
    /// The paused card's own Resume, pressed as the reader presses it.
    @MainActor private func pressResume(_ chat: WireChat) async throws {
        var pill: TranscriptPillButton?
        try await chat.waitUntil("the card offers Resume") {
            pill = ConversationPaneTests.views(TranscriptPillButton.self, in: chat.hosted).first { $0.accessibilityIdentifier() == "cost-paused-resume" }
            return pill != nil
        }
        XCTAssertTrue(try XCTUnwrap(pill).accessibilityPerformPress())
    }
    @MainActor private func waitForTheHeldCallToGoOn(_ chat: WireChat, _ what: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await chat.waitUntil("\(what): the held call ran and the turn went on", seconds: 20, file: file, line: line) {
            !chat.session.busy && !chat.session.costPaused && chat.replyRows.contains { $0.text.contains("Tool round finished") }
        }
        XCTAssertEqual(chat.card("bash")?.state, "completed", "\(what): the held call ran on Resume", file: file, line: line)
        XCTAssertFalse(chat.session.notice.contains("Still at the cost limit"), "\(what): \(chat.session.notice)", file: file, line: line)
    }

    /// The owner's steps with each kind of amount: Raise limit…, a preset or
    /// a typed amount in its editor, then the card's Resume. Every amount
    /// above the spend resumes; one at or below it keeps the pause, with
    /// Raise limit… and nothing resumed.
    @MainActor func testEveryAmountAboveTheSpendResumesFromRaiseLimit() async throws {
        for (amount, typed) in [("25", false), ("50", false), ("100", false), ("99.99", true), ("1000", true)] {
            let chat = try await pausedAtTheDefaultLimit()
            do { try await raiseAndResume(chat, amount: amount, typed: typed) } catch { await chat.close(); throw error }
            await chat.close()
        }
    }
    @MainActor private func raiseAndResume(_ chat: WireChat, amount: String, typed: Bool) async throws {
        let raise = try await Self.waitForTrigger("cost-limit-raise", in: chat)
        raise.performClick(nil)
        try await chat.waitUntil("the limit editor opened") { CostLimitPopover.shared.presenter.isShown && CostLimitPopover.shared.sessionID == chat.id }
        let content = try XCTUnwrap(CostLimitPopover.shared.presenter.popover?.contentViewController?.view)
        if typed {
            try XCTUnwrap(Self.view(CostLimitChip.self, "cost-limit-custom", in: content)).performClick(nil)
            let field = try XCTUnwrap(Self.view(PiKit.TextField.self, "cost-limit-custom-amount", in: content))
            field.text = amount; field.onChange?(amount)
            try XCTUnwrap(Self.view(PiKit.Button.self, "cost-limit-custom-set", in: content)).performClick(nil)
        } else {
            try XCTUnwrap(Self.view(CostLimitChip.self, "cost-limit-" + amount, in: content)).performClick(nil)
        }
        let chosen = CostLimit.usd(try XCTUnwrap(Double(amount)))
        try await chat.waitUntil("$\(amount) was saved and sent") {
            chat.model.record(chat.id)?.costLimit == chosen && chat.model.costLimitWrites[chat.id] == nil && !CostLimitPopover.shared.presenter.isShown
        }
        let limit = try await helperLimit(chat)
        XCTAssertEqual(limit, chosen, "$\(amount) reached the helper")
        if chosen.usd! <= 25.01 {
            XCTAssertEqual(chat.session.presentedMessages.last?.failureCode, SessionDisplay.costPausedCode, "$\(amount) is not above the spend")
            chat.model.resumeRun(sessionID: chat.id)
            try await chat.waitUntil("$\(amount): Resume is refused") { chat.session.notice.contains("Still at the cost limit") }
            XCTAssertTrue(chat.session.costPaused); XCTAssertNotEqual(chat.card("bash")?.state, "completed", "Nothing resumed at $\(amount)")
        } else {
            try await pressResume(chat)
            try await waitForTheHeldCallToGoOn(chat, "$\(amount)")
        }
    }

    /// $100 is chosen in Raise limit…'s editor and the editor goes away
    /// before its save is done: a click outside the popover (on the Resume
    /// the card offers as soon as the limit is saved), Escape, or AppKit
    /// closing the popover about half a second after its anchor, the Raise
    /// limit… pill, leaves the window. The editor then cancels its save task
    /// (`CostLimitEditor.deinit`), as this test cancels the one it runs. The
    /// saved $100 still reaches the helper, and Resume goes on. Before
    /// LIMIT-1 the cancelled task never sent it: the chat showed $100, the
    /// helper kept $25 and refused the Resume the card offered.
    @MainActor func testA100LimitWhoseEditorWentAwayMidSaveStillReachesTheHelper() async throws {
        let chat = try await pausedAtTheDefaultLimit()
        defer { Task { await chat.close() } }
        // The chat record's write is held, as a busy store holds it.
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(chat.model.root.appendingPathComponent("desktop.sqlite").path, &database), SQLITE_OK)
        let db = try XCTUnwrap(database)
        XCTAssertEqual(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        let save = Task { try await chat.model.setCostLimit(.usd(100), for: chat.id) }
        try await chat.waitUntil("the choice's write began") { chat.model.costLimitWrites[chat.id] != nil }
        save.cancel()
        XCTAssertEqual(sqlite3_exec(db, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        _ = await save.result
        XCTAssertEqual(chat.model.record(chat.id)?.costLimit, .usd(100), "The choice is saved")
        try await chat.waitUntil("the card offers Resume") { chat.session.presentedMessages.last?.failureCode == SessionDisplay.costPausedRaisedCode }
        var limit = CostLimit.unlimited
        let deadline = Date().addingTimeInterval(5)
        repeat {
            limit = try await helperLimit(chat)
            if limit == .usd(100) { break }
            try await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        XCTAssertEqual(limit, .usd(100), "The saved limit reached the chat's helper before any Resume")
        try await pressResume(chat)
        try await waitForTheHeldCallToGoOn(chat, "$100")
    }

    /// However a chat's limit failed to reach its helper, Resume first gives
    /// the helper the limit the chat shows, then goes on: the card never
    /// offers a Resume the helper refuses at a limit already raised.
    @MainActor func testResumeGivesAHelperStillUnderTheOldLimitTheChatsLimitFirst() async throws {
        let chat = try await pausedAtTheDefaultLimit()
        defer { Task { await chat.close() } }
        try await chat.model.setCostLimit(.usd(100), for: chat.id)
        var limit = try await helperLimit(chat)
        XCTAssertEqual(limit, .usd(100))
        // The helper is back under $25, as a send that never reached it left
        // it; the chat, and the limit it last sent, say $100.
        _ = try await XCTUnwrap(chat.host).request("session.configure", sessionID: chat.id, params: ["costLimit": CostLimit.usd(25).wire])
        limit = try await helperLimit(chat)
        XCTAssertEqual(limit, .usd(25))
        try await pressResume(chat)
        try await waitForTheHeldCallToGoOn(chat, "$100")
        limit = try await helperLimit(chat)
        XCTAssertEqual(limit, .usd(100), "The helper runs under the chat's limit")
    }
}
