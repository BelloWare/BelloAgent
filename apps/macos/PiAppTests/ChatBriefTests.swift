import XCTest
import Network
import AppKit
@testable import PiApp

/// Chat briefs (FIND-1, 0.1.131): what a request asks, how a reply is read,
/// where a brief is kept and what reads it. No helper, no network.
final class ChatBriefPlanTests: XCTestCase {
    private func row(_ id: String, _ role: String, _ text: String, kind: String? = nil) -> TranscriptMessage {
        var message = TranscriptMessage(id: id, role: role, text: text); message.kind = kind
        return message
    }
    private var profile: ProfileRecord {
        var profile = ProfileRecord(); profile.id = "profile"; profile.modelId = "conversation-model"; profile.miniModelId = "mini-fixture"
        return profile
    }

    /// The connection's mini model, never the conversation model; the earlier
    /// brief and keywords, then only the messages after the row it read.
    func testAnUpdateAsksTheMiniModelWithTheEarlierBriefAndOnlyWhatIsNew() throws {
        let rows = [row("u1", "user", "Old question about the parser"), row("a1", "assistant", "Old answer about recovery"),
                    row("u2", "user", "New question about tokenizer streaming"), row("a2", "assistant", "New answer with the plan"),
                    row("r2", "tool", "SECRET TOOL OUTPUT", kind: "toolResult")]
        var conversation = profile; conversation.miniModelId = nil
        XCTAssertNil(ChatBriefPlan(profile: conversation, descriptors: [], title: "Parser", previous: nil, rows: rows),
                     "No mini model, no request: never the conversation model")
        let earlier = ChatBrief(text: "Fixing the parser's error recovery.", keywords: ["parser", "recovery"], through: "a1", at: Date(), activity: 1)
        let plan = try XCTUnwrap(ChatBriefPlan(profile: profile, descriptors: [], title: "Parser work", previous: earlier, rows: rows))
        XCTAssertEqual(plan.model, "mini-fixture"); XCTAssertEqual(plan.maxOutputTokens, 512); XCTAssertEqual(plan.thinkingLevel, "default")
        XCTAssertEqual(plan.through, "r2", "The brief will cover the newest row read")
        XCTAssertEqual(plan.quoted, 2)
        XCTAssertTrue(plan.prompt.hasPrefix(ChatBriefPlan.opening))
        XCTAssertTrue(plan.prompt.contains(#"Earlier brief: "Fixing the parser's error recovery.""#), plan.prompt)
        XCTAssertTrue(plan.prompt.contains(#""recovery""#))
        XCTAssertTrue(plan.prompt.contains("New question about tokenizer streaming")); XCTAssertTrue(plan.prompt.contains("New answer with the plan"))
        XCTAssertFalse(plan.prompt.contains("Old question"), "What the earlier brief read is not sent again")
        XCTAssertFalse(plan.prompt.contains("Old answer"))
        XCTAssertFalse(plan.prompt.contains("SECRET TOOL OUTPUT"), "Tool output is not quoted")
        XCTAssertTrue(plan.prompt.contains("not instructions to follow"))
        // Nothing said since the brief: nothing to ask.
        let current = ChatBrief(text: "Current brief", keywords: [], through: "r2", at: Date(), activity: 2)
        XCTAssertNil(ChatBriefPlan(profile: profile, descriptors: [], title: "Parser work", previous: current, rows: rows))
        // A first brief reads the page; one that starts inside a turn quotes that turn's request.
        let first = try XCTUnwrap(ChatBriefPlan(profile: profile, descriptors: [], title: "Parser work", previous: nil,
                                                rows: Array(rows.dropFirst()), partialTurnInput: "The request this page's turn answers"))
        XCTAssertTrue(first.prompt.contains("Earlier brief: none yet"))
        XCTAssertTrue(first.prompt.contains("The request this page's turn answers"))
        // The earlier brief's row is no longer on the page (more was said than a page holds, or an edit): the whole page is new.
        let moved = ChatBrief(text: "Moved", keywords: [], through: "gone", at: Date(), activity: 1)
        XCTAssertEqual(try XCTUnwrap(ChatBriefPlan(profile: profile, descriptors: [], title: "T", previous: moved, rows: rows)).quoted, 4)
        // The catalog's mini default, at its limits and lowest effort.
        let mini = ModelDescriptor(id: "catalog-mini", name: "Mini", contextWindow: 16_000, maxOutputTokens: 1024, reasoning: ["low", "high"], mini: true)
        let catalog = try XCTUnwrap(ChatBriefPlan(profile: conversation, descriptors: [mini], title: "T", previous: nil, rows: rows))
        XCTAssertEqual(catalog.model, "catalog-mini"); XCTAssertEqual(catalog.thinkingLevel, "low"); XCTAssertEqual(catalog.contextWindow, 16_000)
        var retired = mini; retired.deprecated = true
        XCTAssertNil(ChatBriefPlan(profile: conversation, descriptors: [retired], title: "T", previous: nil, rows: rows))
        var tiny = profile; tiny.contextWindow = 4_096
        XCTAssertNil(ChatBriefPlan(profile: tiny, descriptors: [], title: "T", previous: nil, rows: rows), "A window too small for the request")
    }

    /// However long the chat and its messages, a request quotes at most
    /// `inputLimit` characters of them, the newest first.
    func testTheRequestStaysTheSameSizeHoweverLongTheChat() throws {
        let long = String(repeating: "lorem ipsum dolor sit amet ", count: 2_000)
        // What the chat's history reader hands over of a chat `turns` long: its newest page of 60 rows.
        func page(_ turns: Int) -> [TranscriptMessage] {
            (max(0, turns - 30)..<turns).flatMap { [row("u\($0)", "user", "Q#\($0)# " + long), row("a\($0)", "assistant", "A#\($0)# " + long)] }
        }
        let earlier = ChatBrief(text: String(repeating: "b", count: ChatBriefPlan.briefLimit), keywords: Array(repeating: String(repeating: "k", count: 40), count: 8),
                                through: nil, at: Date(), activity: 1)
        let short = try XCTUnwrap(ChatBriefPlan(profile: profile, descriptors: [], title: String(repeating: "T", count: 500), previous: earlier,
                                                rows: page(30), partialTurnInput: long + long))
        let huge = try XCTUnwrap(ChatBriefPlan(profile: profile, descriptors: [], title: String(repeating: "T", count: 500), previous: earlier,
                                               rows: page(5_000), partialTurnInput: long + long))
        for plan in [short, huge] {
            XCTAssertLessThan(plan.prompt.count, ChatBriefPlan.inputLimit + 4_000, "Bounded: \(plan.prompt.count) characters")
            XCTAssertLessThanOrEqual(plan.quoted, ChatBriefPlan.inputLimit / 80)
        }
        XCTAssertLessThan(abs(huge.prompt.count - short.prompt.count), 100, "A chat 160 times as long costs the same")
        XCTAssertTrue(huge.prompt.contains("A#4999#"), "The newest message is quoted")
        XCTAssertFalse(huge.prompt.contains("Q#4970#"), "Older ones give way to newer ones")
        XCTAssertFalse(huge.prompt.contains("A#0#"))
    }

    /// The JSON object wherever the model puts it, or "Brief:" lines; the
    /// brief cleaned and capped, the keywords deduplicated and short.
    func testTheRepliesBriefIsReadWhereverTheModelPutsIt() {
        let json = ##"{"brief": "  Fixing   the parser.\n", "keywords": ["parser", "Parser", "#tokenizer", "", "a keyword that is far too long to be any use in a search"]}"##
        XCTAssertEqual(ChatBriefPlan.parse(json)?.text, "Fixing the parser.")
        XCTAssertEqual(ChatBriefPlan.parse(json)?.keywords, ["parser", "tokenizer"])
        XCTAssertEqual(ChatBriefPlan.parse("```json\n" + json + "\n```")?.text, "Fixing the parser.")
        XCTAssertEqual(ChatBriefPlan.parse("Sure! " + json + " Hope this helps.")?.keywords, ["parser", "tokenizer"])
        XCTAssertEqual(ChatBriefPlan.parse(#"{"brief": "Parsing.", "keywords": "stream, tokenizer"}"#)?.keywords, ["stream", "tokenizer"])
        let lines = ChatBriefPlan.parse("**Brief:** Moving the parser to streaming input.\nKeywords: stream, tokenizer")
        XCTAssertEqual(lines?.text, "Moving the parser to streaming input."); XCTAssertEqual(lines?.keywords, ["stream", "tokenizer"])
        XCTAssertNil(ChatBriefPlan.parse(#"{"keywords": ["parser"]}"#), "No brief, nothing kept")
        XCTAssertNil(ChatBriefPlan.parse("I can't help with that."))
        XCTAssertNil(ChatBriefPlan.parse(#"{"brief": "  "}"#))
        let long = ChatBriefPlan.parse(#"{"brief": ""# + String(repeating: "word ", count: 300) + #""}"#)?.text ?? ""
        XCTAssertLessThanOrEqual(long.count, ChatBriefPlan.briefLimit + 1); XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertEqual(ChatBriefPlan.parse(#"{"brief": "A\u0007B\tC", "keywords": ["x\u0007y"]}"#)?.text, "AB C", "No control characters")
        XCTAssertEqual(ChatBriefPlan.parse(#"{"brief": "A\u0007B\tC", "keywords": ["x\u0007y"]}"#)?.keywords, ["xy"])
        let keywords = (1...12).map { #""k\#($0)""# }.joined(separator: ",")
        XCTAssertEqual(ChatBriefPlan.parse(#"{"brief": "Many", "keywords": ["# + keywords + "]}")?.keywords.count, ChatBriefPlan.keywordLimit)
        // Only a finished reply counts; the page keeps the brief with its keywords.
        XCTAssertNil(ChatBriefPlan.brief(from: [TranscriptMessage(id: "a", role: "assistant", text: json, state: "streaming")]))
        XCTAssertNil(ChatBriefPlan.brief(from: [TranscriptMessage(id: "u", role: "user", text: json)]))
        let reply = [TranscriptMessage(id: "a", role: "assistant", text: json)]
        XCTAssertEqual(ChatBriefPlan.result(from: reply), "Fixing the parser.\nparser, tokenizer")
        XCTAssertEqual(BackgroundRequests.result(kind: .brief, messages: reply), "Fixing the parser.\nparser, tokenizer")
        XCTAssertEqual(BackgroundRequestKind("chat-brief"), .brief); XCTAssertEqual(BackgroundRequestKind.brief.raw, "chat-brief")
        XCTAssertEqual(BackgroundRequestKind.brief.label, "Chat brief")
        XCTAssertTrue(BackgroundRequestFilter.briefs.includes(.brief)); XCTAssertFalse(BackgroundRequestFilter.titles.includes(.brief))
    }

    /// Search finds a brief as it finds a title (`localizedCaseInsensitiveContains`),
    /// though it compares folded bytes: case, composed or decomposed accents
    /// and full case folding alike, an accent never dropped, and no match
    /// across the brief and a keyword.
    func testABriefIsFoundAsATitleWouldBe() {
        let brief = ChatBrief(text: "Straße café: the Parser’s ÉTÉ build", keywords: ["PR 812", "naïve", "日本語"], through: nil, at: Date(), activity: nil)
        let cases: [(String, Bool)] = [("parser’s", true), ("PARSER", true), ("cafe\u{301}", true), ("CAFÉ", true), ("cafe", false),
                                       ("STRASSE", true), ("straße", true), ("été", true), ("ete", false), ("pr 8", true),
                                       ("NAÏVE", true), ("naive", false), ("本語", true), ("build\nPR", false), ("812 naïve", false)]
        for (query, expected) in cases {
            XCTAssertEqual(brief.matches(query), expected, query)
            let asTitle = brief.text.localizedCaseInsensitiveContains(query) || brief.keywords.contains { $0.localizedCaseInsensitiveContains(query) }
            XCTAssertEqual(brief.matches(query), asTitle, "as a title would be: \(query)")
        }
        XCTAssertEqual(ChatBrief.key(brief.searchKey, holds: ChatBrief.folded("Café")), true)
        XCTAssertFalse(ChatBrief.key(ChatBrief.folded("ab"), holds: ChatBrief.folded("abc")))
    }

    /// Usage beside the setting: every request the Background requests page
    /// lists, and what the gateway reported for those that reached it.
    func testUsageCountsEveryRequestAndWhatTheGatewayReported() {
        func over(_ totals: [GatewayTotals?]) -> [(totals: GatewayTotals?, over: Bool)] { totals.map { (totals: $0, over: true) } }
        XCTAssertEqual(ChatBriefUsage.sum([]), ChatBriefUsage())
        XCTAssertEqual(ChatBriefUsage.sum([]).label, "None"); XCTAssertNil(ChatBriefUsage.sum([]).note)
        let one = ChatBriefUsage.sum(over([GatewayTotals(requests: 1, costSamples: 1, costUSD: 0.004)]))
        XCTAssertEqual(one.requests, 1); XCTAssertEqual(one.costUSD, 0.004, accuracy: 1e-12); XCTAssertEqual(one.unreported, 0)
        XCTAssertEqual(one.label, "1 request · $0.004"); XCTAssertNil(one.note)
        // Never reached the gateway, or not in the archive yet: a request, at no cost, and not "unreported".
        XCTAssertEqual(ChatBriefUsage.sum(over([nil])), ChatBriefUsage(requests: 1))
        XCTAssertEqual(ChatBriefUsage.sum(over([GatewayTotals()])), ChatBriefUsage(requests: 1))
        XCTAssertEqual(ChatBriefUsage.sum(over([nil])).label, "1 request · $0.00")
        // Reached it, over, and no cost came back; one still running has none to report yet.
        let silent = ChatBriefUsage.sum(over([GatewayTotals(requests: 1, costSamples: 0, costUSD: nil)]))
        XCTAssertEqual(silent, ChatBriefUsage(requests: 1, costUSD: 0, unreported: 1))
        XCTAssertEqual(silent.label, "1 request · $0.00"); XCTAssertEqual(silent.note, "1 came back without a reported cost.")
        XCTAssertEqual(ChatBriefUsage.sum([(totals: GatewayTotals(requests: 1, costSamples: 0, costUSD: nil), over: false)]), ChatBriefUsage(requests: 1))
        let mixed = ChatBriefUsage.sum(over([GatewayTotals(requests: 2, costSamples: 1, costUSD: 0.003), nil,
                                             GatewayTotals(requests: 1, costSamples: 1, costUSD: 0.0022), GatewayTotals(requests: 1, costSamples: 1, costUSD: -1)]))
        XCTAssertEqual(mixed.requests, 4); XCTAssertEqual(mixed.costUSD, 0.0052, accuracy: 1e-12); XCTAssertEqual(mixed.unreported, 0)
        XCTAssertEqual(mixed.label, "4 requests · $0.0052")
        XCTAssertEqual(ChatBriefUsage(requests: 2, costUSD: 1.234).label, "2 requests · $1.23")
        XCTAssertEqual(ChatBriefUsage(requests: 3, unreported: 2).note, "2 came back without a reported cost.")
        XCTAssertEqual(ChatBriefUsage.dollars(0.00004), "<$0.0001"); XCTAssertEqual(ChatBriefUsage.dollars(.nan), "$0.00")
    }

    /// A brief lands on the chat's record and stays there: a copy read
    /// before it does not take it back, nor does an older brief; a brief this
    /// build cannot read leaves the chat readable.
    func testABriefIsKeptOverOlderCopiesAndNeverMakesAChatUnreadable() async throws {
        let root = scratchRoot("brief-store")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataStore(url: root.appendingPathComponent("metadata.sqlite"))
        let chat = ChatRecord(id: "chat", workspaceID: "project", title: "Parser", path: nil, profileID: "profile")
        try await store.put(chat, kind: "chat", id: chat.id)
        let brief = ChatBrief(text: "Fixing the parser.", keywords: ["parser"], through: "a1", at: Date(timeIntervalSince1970: 2_000), activity: 5)
        let saved = try await store.applyChatBrief(brief, chatID: chat.id)
        XCTAssertEqual(saved?.brief, brief)
        var stale = chat; stale.path = "/synthetic/journal.jsonl"
        try await store.put(stale, kind: "chat", id: chat.id)
        let kept = try await store.get(ChatRecord.self, kind: "chat", id: chat.id)
        XCTAssertEqual(kept?.brief, brief, "A copy read before the brief keeps it"); XCTAssertEqual(kept?.path, stale.path)
        let older = ChatBrief(text: "Older", keywords: [], through: nil, at: Date(timeIntervalSince1970: 1_000), activity: 1)
        let refused = try await store.applyChatBrief(older, chatID: chat.id)
        XCTAssertNil(refused)
        var olderCopy = stale; olderCopy.brief = older
        try await store.put(olderCopy, kind: "chat", id: chat.id)
        let newest = try await store.get(ChatRecord.self, kind: "chat", id: chat.id)
        XCTAssertEqual(newest?.brief, brief, "An older brief never replaces a newer one")
        let missing = try await store.applyChatBrief(brief, chatID: "gone")
        XCTAssertNil(missing)
        var task = ChatRecord(id: "task", workspaceID: WorkspaceRecord.scratchID, title: "Chat brief", path: nil, profileID: "profile")
        task.backgroundTask = "chat-brief"
        try await store.put(task, kind: "chat", id: task.id)
        let onTask = try await store.applyChatBrief(brief, chatID: task.id)
        XCTAssertNil(onTask, "A background request has no brief")
        await store.close()
        let unreadable = try JSONDecoder().decode(ChatRecord.self, from: Data(#"{"id":"c","workspaceID":"w","title":"T","profileID":"p","brief":"not a brief"}"#.utf8))
        XCTAssertNil(unreadable.brief); XCTAssertEqual(unreadable.title, "T")
        let partial = try JSONDecoder().decode(ChatRecord.self, from: Data(#"{"id":"c","workspaceID":"w","title":"T","profileID":"p","brief":{"text":"Only text"}}"#.utf8))
        XCTAssertEqual(partial.brief?.text, "Only text"); XCTAssertEqual(partial.brief?.keywords, [])
        var encoded = chat; encoded.brief = brief
        XCTAssertEqual(try JSONDecoder().decode(ChatRecord.self, from: JSONEncoder().encode(encoded)).brief, brief)
    }

    /// On unless the reader turns them off, in a new vault and an older one
    /// alike; the choice is kept, a vault written with the dropped spending
    /// cap still reads, and Settings carries an edit over another writer's
    /// change.
    @MainActor func testBriefsAreOnUnlessTurnedOffAndTheChoiceIsKept() throws {
        XCTAssertTrue(VaultConfiguration().briefSettings.enabled, "On by default")
        XCTAssertTrue(ChatBriefSettings().enabled)
        let old = try JSONEncoder().encode(VaultConfiguration())
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("chatBriefs"), "Nothing is written until the reader changes it")
        XCTAssertTrue(try ConfigurationVault.decode(old).briefSettings.enabled, "An older vault has them on")
        var configuration = VaultConfiguration(); configuration.briefSettings = ChatBriefSettings(enabled: false)
        XCTAssertFalse(try ConfigurationVault.decode(JSONEncoder().encode(configuration)).briefSettings.enabled, "Turned off stays off")
        XCTAssertEqual(try JSONDecoder().decode(ChatBriefSettings.self, from: Data("{}".utf8)), ChatBriefSettings(enabled: true))
        // A vault a development build wrote with a daily cap: the cap is gone, the choice stays, and it is valid.
        var capped = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        capped["chatBriefs"] = ["enabled": false, "dailyCapUSD": 101]
        let decoded = try ConfigurationVault.decode(JSONSerialization.data(withJSONObject: capped))
        XCTAssertEqual(decoded.briefSettings, ChatBriefSettings(enabled: false))
        XCTAssertNoThrow(try decoded.validate(persisted: false))
        var edits = VaultConfiguration(); edits.briefSettings.enabled = false
        var elsewhere = VaultConfiguration(); elsewhere.automaticUpdateChecks = false
        let merged = ConnectionSettingsController.merging(edits, from: VaultConfiguration(), onto: elsewhere)
        XCTAssertFalse(merged.briefSettings.enabled); XCTAssertFalse(merged.automaticUpdateChecks)
    }
}

/// Settings → Chats & notifications → Chat briefs.
@MainActor final class ChatBriefSettingsTests: XCTestCase {
    /// On by default with no spending cap; what brief requests came to; and
    /// Write Briefs for the chats without one, which goes with briefs off.
    func testTheSwitchIsOnByDefaultBesideUsageAndWriteBriefsForChatsWithoutOne() async throws {
        let root = scratchRoot("brief-settings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Settings saves its preferences with a connection, as the app always has one.
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        var profile = ProfileRecord(); profile.name = "Team"; profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "team-model"
        profile.contextWindow = 16000; profile.maxOutputTokens = 2048
        let connection = VaultProfile(profile: profile, apiKey: "sk-saved")
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [connection] }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        let controller = ConnectionSettingsController(model: model)
        await controller.load(discardingDrafts: false)
        model.settingsSection = .chats
        let view = ProfileSettingsView(model: model, controller: controller, windowChrome: false, dismiss: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        func find<T: NSView>(_ type: T.Type, _ id: String? = nil) -> T? {
            func walk(_ v: NSView) -> T? {
                if let t = v as? T, id == nil || t.accessibilityIdentifier() == id { return t }
                for s in v.subviews { if let f = walk(s) { return f } }
                return nil
            }
            return walk(view)
        }
        var toggle: PiKit.Switch?
        for _ in 0..<200 where toggle == nil {
            view.refresh(); view.layoutSubtreeIfNeeded(); toggle = find(PiKit.Switch.self, "settings-chat-briefs")
            if toggle == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let briefs = try XCTUnwrap(toggle, "The switch is in Chats & notifications")
        XCTAssertTrue(briefs.isOn, "On by default")
        XCTAssertNil(find(PiKit.Dropdown<Double>.self, "settings-chat-briefs-cap"), "No spending cap")
        let card = try XCTUnwrap(find(ChatBriefSettingsCard.self))
        let today = try XCTUnwrap(find(PiKit.TextLine.self, "settings-chat-briefs-today"))
        let month = try XCTUnwrap(find(PiKit.TextLine.self, "settings-chat-briefs-month"))
        try await eventually("the archive is read") { today.line.text == "None" && month.line.text == "None" }
        XCTAssertEqual(card.batchDetail, "Every chat has a brief.")
        XCTAssertEqual(card.batchButton.title, "Write Briefs"); XCTAssertFalse(card.batchButton.isEnabled)

        // Chats without a brief: main chats and saved sides, never a sub-agent's or a request's.
        func chat(_ id: String, parent: String? = nil, brief: ChatBrief? = nil) -> ChatRecord {
            var chat = ChatRecord(id: id, workspaceID: "project", title: id, path: root.appendingPathComponent(id + ".jsonl").path, profileID: profile.id,
                                  parentSessionID: parent)
            chat.brief = brief
            return chat
        }
        var request = chat("request"); request.workspaceID = WorkspaceRecord.scratchID; request.backgroundTask = "chat-brief"
        model.chats = [chat("first"), chat("second"), chat("kept-side", parent: "first"),
                       chat("briefed", brief: ChatBrief(text: "Done", keywords: [], through: nil, at: Date(), activity: nil)), request]
        card.update()
        XCTAssertEqual(card.batchButton.title, "Write Briefs for 3 Chats"); XCTAssertTrue(card.batchButton.isEnabled)
        XCTAssertTrue(card.batchDetail.hasPrefix("3 chats have no brief yet."), card.batchDetail)

        briefs.performClick(nil)
        XCTAssertFalse(controller.preferences.briefSettings.enabled)
        XCTAssertEqual(controller.editedSections, [.chats])
        card.update()
        XCTAssertEqual(card.batchDetail, "Chat briefs are off.", "Switched off, though not saved yet: nothing to write")
        XCTAssertFalse(card.batchButton.isEnabled)
        let outcome = await controller.saveAll()
        XCTAssertEqual(outcome, .saved, controller.message)
        let saved = try await vault.load()
        XCTAssertEqual(saved.briefSettings, ChatBriefSettings(enabled: false))
        XCTAssertFalse(model.briefSettings.enabled)
        card.update()
        XCTAssertFalse(card.batchButton.isEnabled, "Off: nothing to write")
        XCTAssertEqual(card.batchDetail, "Chat briefs are off.")
        // Switched on again but not saved: saved first.
        briefs.performClick(nil)
        card.update()
        XCTAssertEqual(card.batchDetail, "Save to turn chat briefs on, then write them here."); XCTAssertFalse(card.batchButton.isEnabled)
    }
}

/// Settings → Chats & notifications → Chat briefs, kept current while open.
@MainActor final class ChatBriefSettingsLiveTests: XCTestCase {
    /// A chat unarchived while Settings is open makes Write Briefs available
    /// at once: the card follows the chat list, which Settings' own refresh
    /// does not watch.
    func testWriteBriefsFollowsTheChatListWhileSettingsIsOpen() async throws {
        let root = scratchRoot("brief-settings-live")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vault = ConfigurationVault(storage: MemoryVaultStorage())
        var profile = ProfileRecord(); profile.name = "Team"; profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "team-model"
        profile.contextWindow = 16000; profile.maxOutputTokens = 2048
        let connection = VaultProfile(profile: profile, apiKey: "sk-saved")
        _ = try await vault.update(expectedRevision: 0) { $0.profiles = [connection] }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        var chat = ChatRecord(id: "later", workspaceID: "project", title: "Later", path: root.appendingPathComponent("later.jsonl").path, profileID: profile.id)
        chat.archivedAt = Date()
        model.chats = [chat]
        let controller = ConnectionSettingsController(model: model)
        await controller.load(discardingDrafts: false)
        model.settingsSection = .chats
        let view = ProfileSettingsView(model: model, controller: controller, windowChrome: false, dismiss: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        func findCard(_ view: NSView) -> ChatBriefSettingsCard? { (view as? ChatBriefSettingsCard) ?? view.subviews.lazy.compactMap { findCard($0) }.first }
        var found: ChatBriefSettingsCard?
        for _ in 0..<200 where found == nil {
            view.refresh(); view.layoutSubtreeIfNeeded(); found = findCard(view)
            if found == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let card = try XCTUnwrap(found)
        // Opening reads the usage twice (now and once the archive settles);
        // after that nothing but the chat list can change what it offers.
        try await Task.sleep(for: ChatBriefSettingsCard.settleDelay + .seconds(1))
        XCTAssertFalse(card.batchButton.isEnabled, "An archived chat is not offered")
        XCTAssertEqual(card.batchButton.title, "Write Briefs")
        model.chats[0].archivedAt = nil
        try await eventually("the action follows the chat list", timeout: .seconds(1)) {
            card.batchButton.isEnabled && card.batchButton.title == "Write Briefs for 1 Chat"
        }
        model.chats[0].archivedAt = Date()
        try await eventually("and back", timeout: .seconds(1)) { !card.batchButton.isEnabled && card.batchButton.title == "Write Briefs" }
    }
}

/// Sidebar search's Titles & details finds a chat by its brief and keywords
/// while briefs are on, in Topics and Flat: a main chat's and a saved side's.
final class ChatBriefSearchTests: XCTestCase {
    @MainActor private func fixture() throws -> WorkspaceSidebarView {
        let root = scratchRoot("brief-search")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.workspaces = [WorkspaceRecord(id: "project", path: root.appendingPathComponent("Orchard").path, trusted: true)]
        var profile = ProfileRecord(); profile.id = "profile"; profile.name = "Studio"; profile.modelId = "alias"
        model.profiles = [profile]
        func chat(_ id: String, _ title: String, parent: String? = nil, brief: ChatBrief? = nil) throws -> ChatRecord {
            // What the chat says is none of the words searched for: only its brief can match.
            let journal = try SearchJournal(root.appendingPathComponent(id + ".jsonl"), id: id)
            try journal.message(id + "-u0", role: "user", "Hello there.")
            var chat = ChatRecord(id: id, workspaceID: "project", title: title, path: journal.url.path, profileID: profile.id, parentSessionID: parent)
            chat.brief = brief
            return chat
        }
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        model.chats = [
            try chat("chat", "Release notes", brief: ChatBrief(text: "Moving the lantern parser to streaming input.", keywords: ["tokenizer", "PR 812"], through: "m1", at: at, activity: 1)),
            try chat("other", "Welcome copy"),
            try chat("side", "Release notes — side", parent: "chat", brief: ChatBrief(text: "Marmalade side notes", keywords: ["quince"], through: "m2", at: at, activity: 1)),
        ]
        model.configuration.briefSettings.enabled = true
        let view = WorkspaceSidebarView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 700); view.settle()
        return view
    }

    @MainActor func testAChatIsFoundByItsBriefAndKeywordsOnlyWhileBriefsAreOn() throws {
        let view = try fixture(), model = view.model
        for flat in [false, true] {
            model.setSidebarFlat(flat)
            for query in ["streaming input", "TOKENIZER", "pr 812"] {
                view.setFilter(query); view.settle()
                XCTAssertEqual(model.sidebarChatOrder, ["chat"], query)
                XCTAssertTrue(view.list.contents.entries.contains { $0.id == "chat|chat" }, query)
                XCTAssertTrue(model.sidebarMatches(model.chats[0], query: query), query)
            }
            view.setFilter("— side"); view.settle()
            let byTitle = model.sidebarChatOrder
            XCTAssertEqual(byTitle, ["chat", "side"], "A side found by its title is listed under its chat")
            view.setFilter("quince"); view.settle()
            XCTAssertEqual(model.sidebarChatOrder, byTitle, "A saved side is found by its own brief, as by its title")
            XCTAssertTrue(model.sidebarMatches(model.chats[2], query: "Marmalade"))
            XCTAssertFalse(model.sidebarMatches(model.chats[0], query: "quince"), "A side's brief is its own, not its chat's")
        }
        model.sidebarSearch.setScope(.fullChats)
        view.setFilter("tokenizer"); view.settle()
        XCTAssertEqual(model.sidebarChatOrder, ["chat"], "Full chats includes the same details")
        model.configuration.briefSettings.enabled = false
        view.setFilter("streaming input"); view.settle()
        XCTAssertTrue(model.sidebarChatOrder.isEmpty, "Off: briefs are neither shown nor searched")
        view.setFilter(""); view.settle()
        model.configuration.briefSettings.enabled = true
        view.setFilter("tokenizer"); view.settle()
        XCTAssertEqual(model.sidebarChatOrder, ["chat"], "On again: the kept brief is found without asking again")
    }
}

/// The card a row brings up when the pointer rests on it while briefs are
/// on: the chat's brief, or Write Brief for a chat without one, beside the
/// row and in place of its tooltip.
final class ChatBriefHoverTests: XCTestCase, SerialTestLane {
    @MainActor func testRestingOnARowShowsItsBriefOrWriteBriefBesideItInPlaceOfTheTooltip() async throws {
        let root = scratchRoot("brief-hover")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        model.workspaces = [WorkspaceRecord(id: "project", path: root.appendingPathComponent("Orchard").path, trusted: true)]
        var profile = ProfileRecord(); profile.id = "profile"; profile.name = "Studio"
        model.profiles = [profile]
        let brief = ChatBrief(text: "Moving the lantern parser to streaming input; error recovery is next.", keywords: ["tokenizer", "PR 812"],
                              through: "m1", at: Date().addingTimeInterval(-300), activity: 1)
        var briefed = ChatRecord(id: "briefed", workspaceID: "project", title: "Lantern parser", path: root.appendingPathComponent("a.jsonl").path, profileID: "profile")
        briefed.brief = brief; briefed.lastActivityAt = 2
        // Its connection is gone: Write Brief asks nothing of anyone.
        var plain = ChatRecord(id: "plain", workspaceID: "project", title: "Welcome copy", path: root.appendingPathComponent("b.jsonl").path, profileID: "gone")
        plain.lastActivityAt = 1
        // Never asked about before: nothing earlier can say why it has no brief.
        var fresh = ChatRecord(id: "fresh", workspaceID: "project", title: "Pricing notes", path: root.appendingPathComponent("c.jsonl").path, profileID: "gone")
        fresh.lastActivityAt = 0
        model.chats = [briefed, plain, fresh]
        XCTAssertTrue(model.briefSettings.enabled, "On by default")
        let sidebar = WorkspaceSidebarView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = sidebar; window.orderFront(nil)
        let presenter = SidebarBriefCard.presenter
        var pointer = NSPoint(x: -10_000, y: -10_000)
        presenter.delay = .milliseconds(10); presenter.reducesMotion = true; presenter.leaveGrace = .milliseconds(40)
        presenter.pointerLocation = { pointer }
        defer {
            presenter.hide(); presenter.delay = PiHoverCardPresenter.delay; presenter.leaveGrace = .milliseconds(300)
            presenter.pointerLocation = { NSEvent.mouseLocation }
            window.contentView = nil; window.close()
        }
        sidebar.settle()
        func row(_ id: String, in view: NSView? = nil) -> SidebarChatRowView? {
            let view = view ?? sidebar
            if let row = view as? SidebarChatRowView, row.chat.id == id { return row }
            return view.subviews.lazy.compactMap { row(id, in: $0) }.first
        }
        func cardViews(_ view: NSView?) -> [SidebarBriefCardView] {
            guard let view else { return [] }
            return ((view as? SidebarBriefCardView).map { [$0] } ?? []) + view.subviews.flatMap { cardViews($0) }
        }
        func texts(_ view: NSView) -> [String] { ((view as? ShellText).map { [$0.text] } ?? []) + view.subviews.flatMap { texts($0) } }
        func onScreen(_ view: NSView) -> CGRect { (view.window ?? window).convertToScreen(view.convert(view.bounds, to: nil)) }
        let briefedRow = try XCTUnwrap(row("briefed")), plainRow = try XCTUnwrap(row("plain"))
        XCTAssertEqual(briefedRow.body.content?.brief, brief)
        XCTAssertNil(briefedRow.body.toolTip, "The card says what the tooltip would")
        XCTAssertNil(plainRow.body.toolTip, "A chat without a brief offers one in its card instead")
        XCTAssertEqual(briefedRow.row.accessibilityHelp(), brief.text, "VoiceOver reads the brief")
        XCTAssertNil(plainRow.row.accessibilityHelp())

        briefedRow.body.setHovering(true)
        try await eventually("the card comes up", timeout: .seconds(5)) { presenter.isShown }
        var panel = try XCTUnwrap(presenter.panel)
        panel.layoutIfNeeded(); panel.displayIfNeeded()
        let card = try XCTUnwrap(cardViews(panel.contentView).first)
        XCTAssertEqual(card.brief, brief); XCTAssertNil(card.writeButton)
        let shown = texts(card).joined(separator: "\n")
        XCTAssertTrue(shown.contains(brief.text), shown); XCTAssertTrue(shown.contains("tokenizer · PR 812"), shown)
        XCTAssertTrue(shown.contains(try XCTUnwrap(briefedRow.body.content?.help)), "The row's state and figures, as the tooltip had them")
        // Beside the row, its top level with the row's: it covers no other row.
        let rowRect = onScreen(briefedRow.body)
        var cardRect = panel.frame.insetBy(dx: PiHoverCardPresenter.shadowMargin, dy: PiHoverCardPresenter.shadowMargin)
        XCTAssertEqual(cardRect.minX, rowRect.maxX + PiHoverCardPresenter.gap, accuracy: 1, "Beside the row's trailing edge")
        XCTAssertEqual(cardRect.maxY, rowRect.maxY, accuracy: 1)
        XCTAssertFalse(panel.ignoresMouseEvents, "The pointer can reach the card")
        // The pointer leaves the row for the card: it stays. Off both: it goes.
        pointer = NSPoint(x: cardRect.midX, y: cardRect.midY)
        briefedRow.body.setHovering(false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(presenter.isShown, "On the card, the card stays")
        pointer = NSPoint(x: -10_000, y: -10_000)
        briefedRow.body.setHovering(false)
        try await eventually("off the row and the card, it goes", timeout: .seconds(5)) { !presenter.isShown }

        // Without a brief: Write Brief, pressed on the card as the window server delivers a click.
        plainRow.body.setHovering(true)
        try await eventually("the card comes up for the chat without a brief", timeout: .seconds(5)) { presenter.isShown }
        panel = try XCTUnwrap(presenter.panel)
        // Drawn, as it is before anyone can press it.
        panel.layoutIfNeeded(); panel.displayIfNeeded()
        let writeCard = try XCTUnwrap(cardViews(panel.contentView).first)
        XCTAssertNil(writeCard.brief)
        XCTAssertTrue(texts(writeCard).joined().contains("No brief yet."))
        let button = try XCTUnwrap(writeCard.writeButton)
        cardRect = panel.frame.insetBy(dx: PiHoverCardPresenter.shadowMargin, dy: PiHoverCardPresenter.shadowMargin)
        XCTAssertTrue(cardRect.contains(onScreen(button)) && button.frame.width > 0, "The button is on the card")
        XCTAssertEqual(model.chatBriefs.attempts, 0)
        pointer = NSPoint(x: onScreen(button).midX, y: onScreen(button).midY)
        plainRow.body.setHovering(false)
        try click(button)
        try await eventually("the press asks for the brief", timeout: .seconds(5)) { model.chatBriefs.outcomes["plain"] != nil }
        XCTAssertEqual(model.chatBriefs.outcomes["plain"], .noMiniModel, "No connection, nothing sent")
        XCTAssertEqual(model.chatBriefs.attempts, 1)
        XCTAssertFalse(presenter.isShown, "Pressing it puts the card away")
        XCTAssertFalse(panel.isKeyWindow, "The card never takes focus")
        pointer = NSPoint(x: -10_000, y: -10_000)

        // The row's menu offers it too, only for a chat without a brief.
        func menuIDs(_ row: SidebarChatRowView) -> [String] {
            SidebarChatRowView.entries(model: model, chat: row.chat, state: row.state).compactMap { if case .item(let item) = $0 { return item.identifier }; return nil }
        }
        XCTAssertTrue(menuIDs(plainRow).contains("writeBrief")); XCTAssertFalse(menuIDs(briefedRow).contains("writeBrief"))

        // While the brief is being written (here, waiting out a connection
        // change), the card already up says so the moment the request starts,
        // and the menu too; once it is done, the card offers Write Brief again
        // and says why none was written.
        let freshRow = try XCTUnwrap(row("fresh"))
        freshRow.body.setHovering(true)
        try await eventually("the card comes up", timeout: .seconds(5)) { presenter.isShown && presenter.anchorView === freshRow.body }
        func shownCard() -> SidebarBriefCardView? { cardViews(presenter.panel?.contentView).first }
        XCTAssertNotNil(shownCard()?.writeButton)
        let (released, release) = AsyncStream<Never>.makeStream()
        model.connectionSwitches["fresh"] = (UUID(), Task { for await _ in released {} })
        model.writeBriefNow("fresh")
        XCTAssertTrue(model.chatBriefs.isWriting("fresh"))
        XCTAssertNil(shownCard()?.writeButton, "The card up says the brief is being written as the request starts")
        XCTAssertTrue(texts(try XCTUnwrap(shownCard())).joined().contains("Writing the brief…"))
        let writingItem = SidebarChatRowView.entries(model: model, chat: freshRow.chat, state: freshRow.state)
            .lazy.compactMap { entry -> PiMenuItem? in if case .item(let item) = entry, item.identifier == "writeBrief" { return item }; return nil }.first
        XCTAssertEqual(writingItem?.title, "Writing Brief…"); XCTAssertEqual(writingItem?.enabled, false)
        model.connectionSwitches["fresh"] = nil; release.finish()
        try await eventually("the request is over", timeout: .seconds(5)) { model.chatBriefs.outcomes["fresh"] != nil }
        XCTAssertEqual(model.chatBriefs.outcomes["fresh"], .noMiniModel)
        XCTAssertNotNil(shownCard()?.writeButton, "Done, the card offers Write Brief again")
        XCTAssertTrue(texts(try XCTUnwrap(shownCard())).joined().contains("no mini model"), "It says why no brief was written")
        freshRow.body.setHovering(false)
        try await eventually("off the row and the card, it goes", timeout: .seconds(5)) { !presenter.isShown }

        // Off: no card, no Write Brief, and the tooltip is back.
        briefedRow.body.setHovering(true)
        try await eventually("the card comes up again", timeout: .seconds(5)) { presenter.isShown }
        model.configuration.briefSettings.enabled = false
        sidebar.needsLayout = true; sidebar.settle()
        let offRow = try XCTUnwrap(row("briefed")), offPlain = try XCTUnwrap(row("plain"))
        XCTAssertNil(offRow.body.content?.brief)
        XCTAssertFalse(presenter.isShown, "A card up when briefs go off goes")
        XCTAssertEqual(offRow.body.toolTip, offRow.body.content?.help); XCTAssertEqual(offPlain.body.toolTip, offPlain.body.content?.help)
        XCTAssertNil(offRow.row.accessibilityHelp())
        XCTAssertFalse(menuIDs(offPlain).contains("writeBrief"))
        for row in [offRow, offPlain] {
            row.body.setHovering(false); row.body.setHovering(true)
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertFalse(presenter.isShown)
            row.body.setHovering(false)
        }
    }

    /// The pointer has left the control and the card, and the card's grace is
    /// running, when what it says changes: the card shown again is still on its
    /// way out, and goes when the grace is over.
    @MainActor func testACardRefreshedWhileItIsLeavingStillGoes() async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 200, height: 40))
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200)); window.contentView?.addSubview(anchor); window.orderFront(nil)
        let presenter = PiHoverCardPresenter()
        presenter.interactive = true; presenter.placement = .trailing
        presenter.delay = .milliseconds(10); presenter.reducesMotion = true; presenter.leaveGrace = .milliseconds(80)
        presenter.pointerLocation = { NSPoint(x: -10_000, y: -10_000) }
        defer { presenter.hide(); window.close() }
        func card(_ text: String) -> NSView { ShellText(text, font: .systemFont(ofSize: 12), color: .piInk) }
        presenter.hover(true, over: anchor, width: 200) { card("Before") }
        try await eventually("the card comes up", timeout: .seconds(5)) { presenter.isShown }
        presenter.hover(false, over: anchor, width: 200) { NSView() }
        XCTAssertTrue(presenter.isShown, "The grace has begun")
        presenter.refresh(over: anchor, width: 200) { card("After") }
        XCTAssertTrue(presenter.isShown, "Shown again with what it now says")
        try await eventually("the card goes once the grace is over", timeout: .seconds(3)) { !presenter.isShown }
    }

    /// A press as the window server delivers it: the button's tracking loop
    /// finds its release queued, and the press goes to the window it is in,
    /// key or not.
    @MainActor private func click(_ view: NSView) throws {
        let window = try XCTUnwrap(view.window)
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseDown ? 1 : 0))
        }
        let down = try event(.leftMouseDown), up = try event(.leftMouseUp)
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
    }
}

/// End to end with the packaged helper and a loopback gateway that serves a
/// mini model: when a request is sent, what it holds, where the brief lands,
/// and that nothing reaches the conversation. Synthetic data only.
final class ChatBriefTests: XCTestCase, SerialTestLane {
    struct Fixture { let model: WorkspaceModel; let gateway: BriefGateway; let other: BriefGateway?; let root: URL; let journals: URL }

    /// Briefs as the vault has them: `nil` writes nothing, which leaves them on.
    /// `second` adds a connection "profile-b" on a gateway of its own.
    @MainActor private func fixture(mini: String? = "mini-fixture", briefs: ChatBriefSettings? = nil, cost: String = "0.004",
                                    second: Bool = false) async throws -> Fixture {
        let root = scratchRoot("chat-briefs")
        let project = root.appendingPathComponent("project"), journals = root.appendingPathComponent("journals")
        for folder in [project, journals] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("PRIVATE PROJECT INSTRUCTION".utf8).write(to: project.appendingPathComponent("AGENTS.md"))
        let gateway = try BriefGateway(cost: cost)
        addTeardownBlock { gateway.stop() }
        let base = try await gateway.start()
        var profile = ProfileRecord(); profile.id = "profile"; profile.baseUrl = base
        profile.modelId = "conversation-model"; profile.miniModelId = mini
        var configuration = VaultConfiguration(); configuration.automaticUpdateChecks = false
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-brief-key")]
        var other: BriefGateway?
        if second {
            let gateway = try BriefGateway(cost: cost)
            addTeardownBlock { gateway.stop() }
            var moved = profile; moved.id = "profile-b"; moved.name = "Other connection"; moved.baseUrl = try await gateway.start()
            configuration.profiles.append(VaultProfile(profile: moved, apiKey: "synthetic-brief-key-b"))
            other = gateway
        }
        configuration.workspaces = [.init(id: "project", path: project.path, trusted: true)]
        // The mini model's own chats run outside every project: an isolated Codex home, never the tester's.
        configuration.resources[WorkspaceRecord.scratchID] = .object(["codexHome": .string(root.appendingPathComponent("isolated-codex").path)])
        if let briefs { configuration.chatBriefs = briefs }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"),
                                   vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        return Fixture(model: model, gateway: gateway, other: other, root: root, journals: journals)
    }

    /// A saved chat with a journal of `turns`, its activity at `activity`.
    @MainActor private func chat(_ id: String, _ fixture: Fixture, title: String, turns: [(String, String)], activity: Int64 = 1,
                                 parent: String? = nil) async throws -> (ChatRecord, SearchJournal) {
        let journal = try SearchJournal(fixture.journals.appendingPathComponent(id + ".jsonl"), id: id)
        for (index, turn) in turns.enumerated() {
            try journal.message("\(id)-u\(index)", role: "user", turn.0)
            try journal.message("\(id)-a\(index)", role: "assistant", turn.1)
        }
        var chat = ChatRecord(id: id, workspaceID: "project", title: title, path: journal.url.path, profileID: "profile", parentSessionID: parent)
        chat.lastActivityAt = activity; chat.sidebarOrder = activity
        try await fixture.model.store?.put(chat, kind: "chat", id: id)
        fixture.model.chats.append(chat)
        return (chat, journal)
    }

    /// What the helper's snapshots say when a run ends: its command receipt
    /// turns `state`, completed unless said (`observeSessionCompletion`),
    /// after a quiet baseline; with `runState` and `revision`, the session's
    /// own state and display revision too.
    @MainActor private func finishRun(_ model: WorkspaceModel, _ id: String, receipts: [String], state: String = "completed",
                                      runState: String? = nil, revision: String? = nil) {
        if model.displays[id] == nil {
            model.displays[id] = SessionDisplay(id: id)
            model.observeSessionCompletion(sessionID: id, snapshot: ["monitoring": .object(["epoch": .string("brief")]), "commands": .array([])], baseline: true)
        }
        var snapshot: [String: WireValue] = ["monitoring": .object(["epoch": .string("brief")]), "commands": .array(receipts.enumerated().map {
            .object(["commandId": .string($0.element), "turnId": .string($0.element),
                     "state": .string($0.offset == receipts.count - 1 ? state : "completed")])
        })]
        if let runState { snapshot["state"] = .string(runState) }
        if let revision { snapshot["displayRevision"] = .string(revision) }
        model.observeSessionCompletion(sessionID: id, snapshot: snapshot)
    }
    /// The brief requests on the Background requests page, oldest first.
    @MainActor private func briefRequests(_ model: WorkspaceModel) -> [ChatRecord] {
        model.chats.filter { $0.backgroundTask == "chat-brief" }
    }

    @MainActor func testARunsEndWritesTheBriefAndTheNextUpdateReadsOnlyWhatIsNew() async throws {
        let fixture = try await self.fixture()
        let model = fixture.model, gateway = fixture.gateway
        let (chat, journal) = try await self.chat("chat-a", fixture, title: "Lantern parser",
                                                  turns: [("Please move the lantern parser to streaming input.", "I moved the tokenizer onto a streaming reader.")])
        let before = try Data(contentsOf: journal.url)
        finishRun(model, chat.id, receipts: ["t1"])
        try await eventually("the brief is written", timeout: .seconds(60)) { model.record(chat.id)?.brief != nil }
        let first = try XCTUnwrap(model.record(chat.id)?.brief)
        XCTAssertEqual(first.text, "Brief 1: the lantern parser moves to streaming input.")
        XCTAssertEqual(first.keywords, ["lantern", "tokenizer-1"]); XCTAssertEqual(first.through, "chat-a-a0")
        let stored = try await model.store?.get(ChatRecord.self, kind: "chat", id: chat.id)
        XCTAssertEqual(stored?.brief, first, "The brief is saved with the chat's record")
        XCTAssertEqual(gateway.requests.count, 1)
        let request = try XCTUnwrap(gateway.requests.first)
        XCTAssertEqual(request.body["model"]?.string, "mini-fixture", "The connection's mini model, not the conversation model")
        XCTAssertEqual(request.body["max_output_tokens"]?.number, 512)
        XCTAssertEqual(request.body["tools"]?.array ?? [], [])
        XCTAssertTrue(request.system.hasPrefix("Write a short brief and a few keywords"), request.system)
        XCTAssertTrue(request.prompt.hasPrefix(ChatBriefPlan.opening), request.prompt)
        XCTAssertTrue(request.prompt.contains("Please move the lantern parser to streaming input."))
        XCTAssertTrue(request.prompt.contains("Earlier brief: none yet"))
        XCTAssertTrue(request.head.lowercased().contains("authorization: bearer synthetic-brief-key"), "The chat's own connection")
        XCTAssertFalse(request.raw.contains("PRIVATE PROJECT INSTRUCTION"))
        // Kept on the Background requests page, with what it wrote and its own billing scope.
        let task = try XCTUnwrap(model.chats.first { $0.backgroundTask == "chat-brief" })
        XCTAssertEqual(task.sourceSessionID, chat.id); XCTAssertEqual(task.workspaceID, WorkspaceRecord.scratchID); XCTAssertEqual(task.model, "mini-fixture")
        XCTAssertEqual(task.backgroundTaskOutcome, "completed")
        XCTAssertEqual(task.backgroundTaskResult, "Brief 1: the lantern parser moves to streaming input.\nlantern, tokenizer-1")
        XCTAssertEqual(request.sessionID, task.id, "Sent as the brief's own request, never as the chat's")
        var attempts = try await model.traces.list(sessionID: task.id, workspaceID: WorkspaceRecord.scratchID)
        for _ in 0..<500 where attempts.count != 1 || attempts.first?["outcome"]?.string == "running" {
            try await Task.sleep(for: .milliseconds(10))
            attempts = try await model.traces.list(sessionID: task.id, workspaceID: WorkspaceRecord.scratchID)
        }
        XCTAssertEqual(attempts.first?["purpose"]?.string, "chat-brief", "Usage lists it under its own purpose")
        let accounting = try await model.traces.gatewayAccounting(sessionID: task.id, workspaceID: WorkspaceRecord.scratchID, messages: [])
        XCTAssertEqual(accounting.session.requests, 1); XCTAssertEqual(accounting.session.costUSD ?? 0, 0.004, accuracy: 1e-9)
        let chatAccounting = try await model.traces.gatewayAccounting(sessionID: chat.id, workspaceID: chat.workspaceID, messages: [])
        XCTAssertEqual(chatAccounting.session.requests, 0, "Billed to the brief, not to the chat")
        // Nothing entered the conversation, its journal or its context.
        XCTAssertEqual(try Data(contentsOf: journal.url), before, "The chat's journal is untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.url.path + ".meta"))
        XCTAssertFalse(model.opened.contains(chat.id), "The chat itself was never opened in the helper")
        XCTAssertFalse(gateway.requests.contains { $0.sessionID == chat.id })
        XCTAssertTrue(model.displays[chat.id]?.messages.isEmpty ?? true)

        // The next run's end: the earlier brief and only what was said since.
        try journal.message("chat-a-u1", role: "user", "Now add error recovery for unterminated strings.")
        try journal.message("chat-a-a1", role: "assistant", "Recovery now resumes at the next quote.")
        let appended = try Data(contentsOf: journal.url)
        finishRun(model, chat.id, receipts: ["t1", "t2"])
        try await eventually("the brief is updated", timeout: .seconds(60)) { model.record(chat.id)?.brief?.through == "chat-a-a1" }
        XCTAssertEqual(gateway.requests.count, 2)
        let update = gateway.requests[1].prompt
        XCTAssertTrue(update.contains(#"Earlier brief: "Brief 1: the lantern parser moves to streaming input.""#), update)
        XCTAssertTrue(update.contains(#""tokenizer-1""#), "With its keywords")
        XCTAssertTrue(update.contains("Now add error recovery for unterminated strings.")); XCTAssertTrue(update.contains("Recovery now resumes at the next quote."))
        XCTAssertFalse(update.contains("Please move the lantern parser"), "What the earlier brief read is not sent again")
        XCTAssertFalse(update.contains("streaming reader"))
        XCTAssertEqual(model.record(chat.id)?.brief?.text, "Brief 2: the lantern parser moves to streaming input.")
        XCTAssertEqual(try Data(contentsOf: journal.url), appended)
        // A run's end with nothing new asks nothing.
        finishRun(model, chat.id, receipts: ["t1", "t2", "t3"])
        try await eventually("the chat is looked at again") { model.chatBriefs.outcomes[chat.id] == .nothingNew }
        XCTAssertEqual(gateway.requests.count, 2)
    }

    /// A long chat: the request still holds only the newest messages, within
    /// the budget, whatever the journal's size.
    @MainActor func testALongChatsRequestStaysWithinTheBudget() async throws {
        let fixture = try await self.fixture()
        let model = fixture.model, gateway = fixture.gateway
        let long = String(repeating: "the parser reads tokens in a loop; ", count: 300)
        let (chat, journal) = try await self.chat("long", fixture, title: "Long chat", turns: [])
        try journal.turns(2_000, prefix: "long") { ("Question #\($0)# " + long, "Answer #\($0)# " + long) }
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: journal.url.path)[.size] as? NSNumber).intValue
        XCTAssertGreaterThan(size, 40_000_000, "A journal of tens of megabytes")
        finishRun(model, chat.id, receipts: ["t1"])
        try await eventually("the brief is written", timeout: .seconds(90)) { model.record(chat.id)?.brief != nil }
        let prompt = try XCTUnwrap(gateway.requests.first).prompt
        XCTAssertLessThan(prompt.count, ChatBriefPlan.inputLimit + 4_000, "\(prompt.count) characters for a \(size)-byte journal")
        XCTAssertTrue(prompt.contains("Answer #1999#"), "The newest reply is quoted")
        XCTAssertFalse(prompt.contains("Question #1900#")); XCTAssertFalse(prompt.contains("#0#"))
        XCTAssertEqual(model.record(chat.id)?.brief?.through, "long-a1999")
    }

    /// A run that ends while its chat's brief is being written: never a
    /// second request at once, and exactly one more update once it is done,
    /// reading on from where the first one read to.
    @MainActor func testARunThatEndsWhileItsBriefIsWrittenGetsExactlyOneMoreUpdate() async throws {
        let fixture = try await self.fixture()
        let model = fixture.model, gateway = fixture.gateway
        let (chat, journal) = try await self.chat("busy", fixture, title: "Busy chat", turns: [("First question about the lantern parser.", "First answer.")])
        gateway.hold(true)
        finishRun(model, chat.id, receipts: ["t1"])
        try await eventually("the first request is sent", timeout: .seconds(60)) { gateway.requests.count == 1 }
        XCTAssertTrue(model.chatBriefs.isWriting(chat.id)); XCTAssertEqual(model.chatBriefs.writing, [chat.id])
        // Two more runs end while it is written.
        try journal.message("busy-u1", role: "user", "Second question about streaming.")
        try journal.message("busy-a1", role: "assistant", "Second answer.")
        finishRun(model, chat.id, receipts: ["t1", "t2"])
        try journal.message("busy-u2", role: "user", "Third question about recovery.")
        try journal.message("busy-a2", role: "assistant", "Third answer.")
        finishRun(model, chat.id, receipts: ["t1", "t2", "t3"])
        XCTAssertEqual(model.chatBriefs.pending, [chat.id], "One update waits, for both")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(gateway.requests.count, 1, "Never two requests at once for one chat")
        gateway.hold(false)
        try await eventually("the update after it lands", timeout: .seconds(60)) { model.record(chat.id)?.brief?.through == "busy-a2" }
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(gateway.requests.count, 2, "Exactly one more")
        XCTAssertTrue(model.chatBriefs.pending.isEmpty); XCTAssertTrue(model.chatBriefs.writing.isEmpty)
        XCTAssertEqual(model.chatBriefs.attempts, 2)
        let update = gateway.requests[1].prompt
        XCTAssertTrue(update.contains(#"Earlier brief: "Brief 1: the lantern parser moves to streaming input.""#), update)
        XCTAssertTrue(update.contains("Second question about streaming.")); XCTAssertTrue(update.contains("Third question about recovery."))
        XCTAssertFalse(update.contains("First question"), "It reads on from where the first one read to")
        XCTAssertEqual(model.record(chat.id)?.brief?.text, "Brief 2: the lantern parser moves to streaming input.")
    }

    /// Write Brief on a chat without one asks for it at once, an archived
    /// chat's too (whose run's end and Write Briefs leave it alone); while it
    /// is written the menu says so, and a chat with a brief offers nothing.
    @MainActor func testWriteBriefAsksForOneChatAndItsMenuSaysSoWhileItIsWritten() async throws {
        let fixture = try await self.fixture()
        let model = fixture.model, gateway = fixture.gateway
        let (chat, _) = try await self.chat("asked", fixture, title: "Asked", turns: [("Plan the release notes.", "Here is an outline.")])
        model.chats[try XCTUnwrap(model.chats.firstIndex { $0.id == chat.id })].archivedAt = Date()
        finishRun(model, chat.id, receipts: ["t1"])
        XCTAssertFalse(model.chatBriefs.chatsWithoutBrief().contains { $0.id == chat.id }, "Write Briefs leaves an archived chat out")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(gateway.requests.isEmpty, "An archived chat's run's end asks nothing"); XCTAssertEqual(model.chatBriefs.attempts, 0)
        func item() throws -> PiMenuItem? {
            let record = try XCTUnwrap(model.record(chat.id))
            return SidebarChatRowView.entries(model: model, chat: record, state: SidebarChatRowState(offersBrief: model.offersBrief(record)))
                .lazy.compactMap { entry -> PiMenuItem? in if case .item(let item) = entry, item.identifier == "writeBrief" { return item }; return nil }.first
        }
        let write = try XCTUnwrap(try item(), "A chat without a brief offers Write Brief")
        XCTAssertEqual(write.title, "Write Brief"); XCTAssertTrue(write.enabled)
        gateway.hold(true)
        write.perform()
        try await eventually("it is asked for at once", timeout: .seconds(60)) { gateway.requests.count == 1 }
        let writing = try XCTUnwrap(try item())
        XCTAssertEqual(writing.title, "Writing Brief…"); XCTAssertFalse(writing.enabled)
        gateway.hold(false)
        try await eventually("the brief lands", timeout: .seconds(60)) { model.record(chat.id)?.brief != nil }
        XCTAssertNil(try item(), "A chat with a brief has none to write")
        XCTAssertEqual(gateway.requests.count, 1)
        XCTAssertTrue(gateway.requests[0].prompt.contains("Plan the release notes."))
    }

    /// A saved side gets a brief of its own at its run's end, and search finds
    /// it by it; a side not saved never has one asked for.
    @MainActor func testASavedSideGetsItsBriefAndAnUnsavedSideNever() async throws {
        let fixture = try await self.fixture()
        let model = fixture.model, gateway = fixture.gateway
        let (main, _) = try await chat("main", fixture, title: "Main chat", turns: [("Main question.", "Main answer.")], activity: 2)
        let (side, _) = try await chat("kept-side", fixture, title: "Kept side", turns: [("Side question about quinces.", "Side answer.")], parent: main.id)
        finishRun(model, side.id, receipts: ["t1"])
        try await eventually("the saved side's brief is written", timeout: .seconds(60)) { model.record(side.id)?.brief != nil }
        XCTAssertTrue(gateway.requests[0].prompt.contains("Side question about quinces."))
        XCTAssertFalse(gateway.requests[0].prompt.contains("Main question."), "Its own messages, not its chat's")
        XCTAssertNil(model.record(main.id)?.brief)
        XCTAssertTrue(model.sidebarMatches(try XCTUnwrap(model.record(side.id)), query: "tokenizer-1"), "Search finds it by its brief")
        // A side open but not saved: no request at its run's end, nor when asked.
        let (draft, _) = try await chat("draft-side", fixture, title: "Main chat — side", turns: [("Unsaved question.", "Unsaved answer.")], parent: main.id)
        model.sides[main.id] = SideRecord(id: draft.id, parentID: main.id, workspaceID: "project", profileID: "profile", title: draft.title)
        XCTAssertTrue(model.isEphemeral(draft.id))
        finishRun(model, draft.id, receipts: ["t1"])
        model.writeBriefNow(draft.id)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(gateway.requests.count, 1)
        XCTAssertNil(model.chatBriefs.outcomes[draft.id]); XCTAssertNil(model.record(draft.id)?.brief)
        XCTAssertFalse(model.chatBriefs.chatsWithoutBrief().contains { $0.id == draft.id })
    }

    /// Write Briefs for the chats without one: one request at a time, newest
    /// first; a chat that cannot have one is passed over, and a chat with a
    /// brief is left alone. What it spent comes from the archive.
    @MainActor func testWriteBriefsGoesOneAtATimeNewestFirstAndPassesOverChatsThatCannotHaveOne() async throws {
        let fixture = try await self.fixture()
        let model = fixture.model, gateway = fixture.gateway
        _ = try await chat("orphan", fixture, title: "Orphan", turns: [("Orphan question.", "Orphan answer.")], activity: 6_000_000)
        let orphan = try XCTUnwrap(model.chats.firstIndex { $0.id == "orphan" })
        model.chats[orphan].profileID = "deleted-connection"
        let (_, broken) = try await chat("broken", fixture, title: "Broken", turns: [("Broken question.", "Broken answer.")], activity: 5_000_000)
        try FileManager.default.removeItem(at: broken.url)
        var journals: [String: SearchJournal] = [:]
        for (id, activity) in [("archived", 7_000_000), ("newest", 4_000_000), ("middle", 3_000_000), ("briefed", 2_500_000), ("oldest", 1_000_000)] as [(String, Int64)] {
            journals[id] = try await chat(id, fixture, title: id, turns: [("Question for the \(id) chat.", "Answer for the \(id) chat.")], activity: activity).1
        }
        model.chats[try XCTUnwrap(model.chats.firstIndex { $0.id == "archived" })].archivedAt = Date()
        let earlier = ChatBrief(text: "Earlier", keywords: [], through: "briefed-a0", at: Date(), activity: 2_500_000)
        _ = try await model.store?.applyChatBrief(earlier, chatID: "briefed")
        model.chats[try XCTUnwrap(model.chats.firstIndex { $0.id == "briefed" })].brief = earlier
        XCTAssertEqual(model.chatBriefs.chatsWithoutBrief().map(\.id), ["orphan", "broken", "newest", "middle", "oldest"])
        gateway.hold(true)
        model.chatBriefs.startBatch()
        XCTAssertEqual(model.chatBriefs.batch?.total, 5); XCTAssertTrue(model.chatBriefs.batchRunning)
        try await eventually("the first request is sent", timeout: .seconds(60)) { gateway.requests.count == 1 }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(gateway.requests.count, 1, "One at a time")
        XCTAssertEqual(model.chatBriefs.batch?.done, 2, "The chats that cannot have one are passed over")
        // Meanwhile a run ends on the chat that has a brief: its own update
        // goes out beside the batch's request, and is not the batch's.
        try journals["briefed"]?.message("briefed-u1", role: "user", "Second question for the briefed chat.")
        try journals["briefed"]?.message("briefed-a1", role: "assistant", "Second answer for the briefed chat.")
        finishRun(model, "briefed", receipts: ["t1"])
        try await eventually("the run's end asks for its update", timeout: .seconds(60)) { gateway.requests.count == 2 }
        gateway.hold(false)
        try await eventually("the batch is over", timeout: .seconds(120)) { model.chatBriefs.batch?.finished == true }
        try await eventually("the run's end's update lands", timeout: .seconds(60)) { model.record("briefed")?.brief?.through == "briefed-a1" }
        let batch = try XCTUnwrap(model.chatBriefs.batch)
        XCTAssertEqual(batch.done, 5); XCTAssertEqual(batch.written, 3); XCTAssertEqual(batch.failed, 0); XCTAssertNil(batch.stopped)
        XCTAssertFalse(model.chatBriefs.batchRunning)
        XCTAssertEqual(gateway.requests.count, 4)
        let asked = gateway.requests.map(\.prompt).filter { !$0.contains("Second question for the briefed chat.") }
        XCTAssertEqual(asked.count, 3, "The batch asked three times")
        for (index, id) in ["newest", "middle", "oldest"].enumerated() {
            XCTAssertTrue(asked[index].contains("Question for the \(id) chat."), "Newest first: \(id)")
            XCTAssertNotNil(model.record(id)?.brief)
        }
        XCTAssertEqual(model.chatBriefs.outcomes["orphan"], .noMiniModel, "No connection, no mini model to ask")
        guard case .unreadable? = model.chatBriefs.outcomes["broken"] else {
            return XCTFail("The unreadable chat is passed over: \(String(describing: model.chatBriefs.outcomes["broken"]))")
        }
        XCTAssertFalse(asked.contains { $0.contains("Earlier brief: none yet") && $0.contains("briefed chat") }, "The batch leaves a chat with a brief alone")
        XCTAssertNil(model.record("archived")?.brief, "An archived chat is left alone")
        XCTAssertTrue(model.chatBriefs.chatsWithoutBrief().map(\.id).allSatisfy { ["orphan", "broken"].contains($0) })
        // What it spent: its own three requests, not the run's end's beside them.
        try await eventually("the archive has what it cost", timeout: .seconds(30), until: {
            let all = await model.briefUsage(since: batch.startedAt)
            return all.requests == 4 && abs(all.costUSD - 0.016) < 1e-9
        })
        let spent = await model.briefUsage(since: batch.startedAt, for: Set(batch.chats))
        XCTAssertEqual(spent.requests, 3); XCTAssertEqual(spent.costUSD, 0.012, accuracy: 1e-9)
    }

    /// Stop stops the batch and the request it waits on; three failed
    /// requests in a row stop it too. Settings shows how far it got.
    @MainActor func testWriteBriefsStopsWhenToldAndAfterThreeFailedRequestsInARow() async throws {
        let fixture = try await self.fixture()
        let model = fixture.model, gateway = fixture.gateway
        for (index, id) in ["one", "two", "three", "four"].enumerated() {
            _ = try await chat(id, fixture, title: id, turns: [("Question \(id).", "Answer \(id).")], activity: Int64(10 - index) * 1_000_000)
        }
        let card = ChatBriefSettingsCard(model: model, get: { model.briefSettings }, set: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = card
        defer { window.contentView = nil; window.close() }
        card.update()
        XCTAssertEqual(card.batchButton.title, "Write Briefs for 4 Chats")
        gateway.hold(true)
        card.batchButton.performClick(nil)
        try await eventually("the first request is sent", timeout: .seconds(60)) { gateway.requests.count == 1 }
        // Under way, it has reached the gateway and has no cost yet: it is not
        // one that came back without a cost.
        let started = try XCTUnwrap(model.chatBriefs.batch?.startedAt)
        let underway = try XCTUnwrap(briefRequests(model).first)
        try await eventually("the request under way is in the archive", timeout: .seconds(30), until: {
            ((try? await model.traces.list(sessionID: underway.id, workspaceID: WorkspaceRecord.scratchID)) ?? []).count == 1
        })
        let running = await model.briefUsage(since: started)
        XCTAssertEqual(running.requests, 1); XCTAssertEqual(running.unreported, 0, "A request still running has no cost to report yet")
        card.update()
        XCTAssertEqual(card.batchButton.title, "Stop")
        XCTAssertTrue(card.batchDetail.hasPrefix("0 of 4 chats · 0 written · "), card.batchDetail)
        card.batchButton.performClick(nil)
        let stopped = try XCTUnwrap(model.chatBriefs.batch)
        XCTAssertTrue(stopped.finished); XCTAssertEqual(stopped.stopped, "Stopped."); XCTAssertFalse(model.chatBriefs.batchRunning)
        try await eventually("the request it waited on stops", timeout: .seconds(30)) { self.briefRequests(model).first?.backgroundTaskOutcome == "interrupted" }
        try await eventually("nothing is under way") { model.chatBriefs.writing.isEmpty }
        try await eventually("stopped, it came back without a cost", timeout: .seconds(30), until: {
            await model.briefUsage(since: started) == ChatBriefUsage(requests: 1, costUSD: 0, unreported: 1)
        })
        gateway.hold(false)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(gateway.requests.count, 1, "Nothing more is asked once stopped")
        XCTAssertTrue(model.chats.filter { !$0.isUtilityChat }.allSatisfy { $0.brief == nil })
        card.update()
        XCTAssertTrue(card.batchDetail.hasPrefix("Wrote 0 briefs for 4 chats · "), card.batchDetail)
        XCTAssertTrue(card.batchDetail.contains("Stopped."), card.batchDetail)
        XCTAssertEqual(card.batchButton.title, "Write Briefs for 4 Chats")

        // The mini model answers with nothing usable: the third failure in a row ends it.
        gateway.unusable(true)
        model.chatBriefs.startBatch()
        try await eventually("three failures end it", timeout: .seconds(120)) { model.chatBriefs.batch?.finished == true }
        let failed = try XCTUnwrap(model.chatBriefs.batch)
        XCTAssertEqual(failed.done, 3); XCTAssertEqual(failed.failed, 3); XCTAssertEqual(failed.written, 0)
        XCTAssertTrue(failed.stopped?.hasPrefix("Stopped after three failed requests in a row.") == true, failed.stopped ?? "")
        XCTAssertEqual(gateway.requests.count, 4, "The fourth chat is not asked about")
        XCTAssertEqual(briefRequests(model).filter { $0.backgroundTaskOutcome == "failed" }.count, 3)
    }

    /// Off, nothing is asked: not at a run's end, not by Write Brief or Write
    /// Briefs. Turned on, nothing is asked by itself. Turned off while the
    /// mini model answers, the request stops and no brief lands.
    @MainActor func testTheSettingStopsEveryBriefRequest() async throws {
        let fixture = try await self.fixture(briefs: ChatBriefSettings(enabled: false))
        let model = fixture.model, gateway = fixture.gateway
        let (chat, _) = try await self.chat("chat-off", fixture, title: "Off", turns: [("Plan the release notes.", "Here is an outline.")])
        finishRun(model, chat.id, receipts: ["t1"])
        model.writeBriefNow(chat.id)
        model.chatBriefs.startBatch()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(gateway.requests.isEmpty, "Off: neither a run's end, Write Brief nor Write Briefs asks anything")
        XCTAssertEqual(model.chatBriefs.attempts, 0); XCTAssertNil(model.chatBriefs.batch)
        XCTAssertFalse(model.offersBrief(chat)); XCTAssertTrue(model.chatBriefs.chatsWithoutBrief().isEmpty)

        gateway.hold(true)
        try await model.updateConfiguration { $0.briefSettings.enabled = true }
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertTrue(gateway.requests.isEmpty, "Turned on, nothing is asked by itself")
        finishRun(model, chat.id, receipts: ["t1", "t2"])
        try await eventually("a run's end asks", timeout: .seconds(60)) { gateway.requests.count == 1 }
        try await model.updateConfiguration { $0.briefSettings.enabled = false }
        try await eventually("turned off, the request under way stops", timeout: .seconds(30)) {
            self.briefRequests(model).contains { $0.backgroundTaskOutcome == "interrupted" }
        }
        try await eventually("nothing is under way") { model.chatBriefs.writing.isEmpty }
        XCTAssertNil(model.record(chat.id)?.brief, "No brief lands from a stopped request")
        gateway.hold(false)
        finishRun(model, chat.id, receipts: ["t1", "t2", "t3"])
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(gateway.requests.count, 1, "Nothing more is asked while briefs are off")
        XCTAssertNil(model.record(chat.id)?.brief)
    }

    /// A launch asks nothing: chats without a brief wait for their next run's
    /// end, Write Brief or Write Briefs. There is no background backfill.
    @MainActor func testALaunchAsksNothingForChatsWithoutABrief() async throws {
        let root = scratchRoot("chat-briefs-launch")
        let project = root.appendingPathComponent("project"), journals = root.appendingPathComponent("journals"), state = root.appendingPathComponent("state")
        for folder in [project, journals, state] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let gateway = try BriefGateway()
        addTeardownBlock { gateway.stop() }
        var profile = ProfileRecord(); profile.id = "profile"; profile.baseUrl = try await gateway.start()
        profile.modelId = "conversation-model"; profile.miniModelId = "mini-fixture"
        var configuration = VaultConfiguration(); configuration.automaticUpdateChecks = false
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-brief-key")]
        configuration.workspaces = [.init(id: "project", path: project.path, trusted: true)]
        // The store as an upgrade finds it: saved chats, none with a brief.
        let store = MetadataStore(url: state.appendingPathComponent("desktop.sqlite"))
        for id in ["one", "two"] {
            let journal = try SearchJournal(journals.appendingPathComponent(id + ".jsonl"), id: id)
            try journal.message(id + "-u0", role: "user", "A question for \(id)."); try journal.message(id + "-a0", role: "assistant", "An answer.")
            var chat = ChatRecord(id: id, workspaceID: "project", title: id, path: journal.url.path, profileID: profile.id)
            chat.lastActivityAt = 1; chat.sidebarOrder = 1
            try await store.put(chat, kind: "chat", id: id)
        }
        await store.close()
        let model = WorkspaceModel(stateRoot: state, vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
        registerWorkspaceFixtureTeardown(model, root: root)
        await model.restore()
        XCTAssertEqual(Set(model.chats.filter { !$0.isUtilityChat }.map(\.id)), ["one", "two"])
        XCTAssertTrue(model.briefSettings.enabled)
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(gateway.requests.isEmpty, "Nothing is asked until a run ends or the reader asks")
        XCTAssertEqual(model.chatBriefsStorage?.attempts ?? 0, 0)
        XCTAssertEqual(Set(model.chatBriefs.chatsWithoutBrief().map(\.id)), ["one", "two"], "Settings offers to write them")
    }

    /// A chat whose connection has no mini model is never asked about: the
    /// conversation model is not used instead, and no request is made.
    @MainActor func testAChatWhoseConnectionHasNoMiniModelIsNeverAskedAbout() async throws {
        let fixture = try await self.fixture(mini: nil)
        let model = fixture.model, gateway = fixture.gateway
        let (chat, _) = try await self.chat("no-mini", fixture, title: "No mini", turns: [("Draft the welcome copy.", "Here is a draft.")])
        finishRun(model, chat.id, receipts: ["t1"])
        try await eventually("the chat is looked at", timeout: .seconds(30)) { model.chatBriefs.outcomes[chat.id] == .noMiniModel }
        model.writeBriefNow(chat.id)
        try await eventually("asked again, it is looked at again", timeout: .seconds(30)) { model.chatBriefs.attempts == 2 && model.chatBriefs.writing.isEmpty }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(gateway.requests.isEmpty, "No request at all")
        XCTAssertTrue(briefRequests(model).isEmpty)
        XCTAssertEqual(model.chatBriefs.outcomes[chat.id], .noMiniModel)
        XCTAssertNil(model.record(chat.id)?.brief)
    }

    /// A chat moved to another connection while its brief is prepared sends
    /// nothing through the one it left: it is asked again, once, on the one
    /// it is on. A request whose chat moves just before it is sent is not sent.
    @MainActor func testAChatMovedToAnotherConnectionWhileItsBriefIsPreparedSendsNothingThroughTheOldOne() async throws {
        let fixture = try await self.fixture(second: true)
        let model = fixture.model, first = fixture.gateway, other = try XCTUnwrap(fixture.other)
        let (chat, _) = try await self.chat("moving", fixture, title: "Moving", turns: [("Which connection reads this?", "Only the chat's own.")])
        final class Once { var done = false }
        let once = Once()
        // What a connection change does to the chat between the reads and the request (`setConnection`).
        model.chatBriefs.beforeDispatch = { id in
            guard !once.done else { return }
            once.done = true
            model.connectionGenerations[id, default: 0] &+= 1
            if let index = model.chats.firstIndex(where: { $0.id == id }) { model.chats[index].profileID = "profile-b" }
        }
        model.writeBriefNow(chat.id)
        try await eventually("the brief is written", timeout: .seconds(60)) { model.record(chat.id)?.brief != nil }
        XCTAssertTrue(first.requests.isEmpty, "Nothing went to the connection the chat left")
        XCTAssertEqual(other.requests.count, 1, "Asked again on the one it is on")
        XCTAssertTrue(other.requests[0].head.lowercased().contains("authorization: bearer synthetic-brief-key-b"))
        XCTAssertEqual(model.chatBriefs.attempts, 2); XCTAssertEqual(model.chatBriefs.outcomes[chat.id], .written)
        XCTAssertEqual(briefRequests(model).map(\.profileID), ["profile-b"], "One request, on the new connection")

        // Moved after everything was read and just before the request goes: it does not go.
        model.chatBriefs.beforeDispatch = nil
        let current = try XCTUnwrap(model.record(chat.id))
        let lease = try model.connectionLease(for: current)
        model.connectionGenerations[chat.id, default: 0] &+= 1
        let profile = try XCTUnwrap(model.profiles.first { $0.id == "profile-b" })
        let request = MiniModelRequest(model: "mini-fixture", contextWindow: profile.contextWindow, maxOutputTokens: 512, modelOutputLimit: nil, thinkingLevel: "default",
                                       prompt: "Never sent", task: "chat-brief", title: "Chat brief", timeout: 30, name: "brief request")
        do {
            _ = try await model.askMiniModel(request, profile: profile, sourceID: chat.id, sourceLease: lease) { _ in "" }
            XCTFail("A request whose chat moved is not sent")
        } catch {
            guard case .rejected("connection_changed", _)? = error as? HostError else { return XCTFail("\(error)") }
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(other.requests.count, 1); XCTAssertTrue(first.requests.isEmpty)
    }

    /// A brief is read on a reader of its own, never on the one every chat's
    /// opening and paging goes through, even for a chat that is open: a long
    /// journal's index rebuilt for a brief holds up nothing else.
    @MainActor func testABriefReadsItsChatOffTheSharedHistoryReader() async throws {
        let fixture = try await self.fixture()
        let model = fixture.model
        let (chat, journal) = try await self.chat("open", fixture, title: "Open chat", turns: [("A question while it is open.", "An answer.")])
        finishRun(model, chat.id, receipts: ["t1"])
        XCTAssertNotNil(model.displays[chat.id], "The chat is open")
        try await eventually("the brief is written", timeout: .seconds(60)) { model.record(chat.id)?.brief != nil }
        let shared = await model.history.indexedPaths
        XCTAssertFalse(shared.contains(journal.url.path), "The shared reader never read the chat for its brief: \(shared)")
    }

    /// A run that adds messages and then fails ends a run all the same: the
    /// chat's brief is updated, as for any run's end (the chime is for
    /// completed runs only).
    @MainActor func testARunThatFailsStillUpdatesItsBrief() async throws {
        let fixture = try await self.fixture()
        let model = fixture.model, gateway = fixture.gateway
        let (chat, journal) = try await self.chat("failing", fixture, title: "Failing chat", turns: [("First question.", "First answer.")])
        finishRun(model, chat.id, receipts: ["t1"])
        try await eventually("the brief is written", timeout: .seconds(60)) { model.record(chat.id)?.brief?.through == "failing-a0" }
        try journal.message("failing-u1", role: "user", "A second question the provider failed on.")
        try journal.message("failing-a1", role: "assistant", "Half an answer before the failure.")
        finishRun(model, chat.id, receipts: ["t1", "t2"], state: "failed")
        try await eventually("the failed run's end updates it", timeout: .seconds(60)) { model.record(chat.id)?.brief?.through == "failing-a1" }
        XCTAssertEqual(gateway.requests.count, 2)
        XCTAssertTrue(gateway.requests[1].prompt.contains("A second question the provider failed on."))
    }

    /// A failed run retried, failing again: the helper reuses the run's
    /// command, so its receipt stays failed, but the retry journaled more of a
    /// reply. That retry's end is a run's end too: the brief takes it in.
    @MainActor func testARetryThatFailsAgainStillUpdatesItsBrief() async throws {
        let fixture = try await self.fixture()
        let model = fixture.model, gateway = fixture.gateway
        let (chat, journal) = try await self.chat("retried", fixture, title: "Retried chat", turns: [("First question.", "First answer.")])
        finishRun(model, chat.id, receipts: ["t1"], runState: "idle", revision: "e:1")
        try await eventually("the brief is written", timeout: .seconds(60)) { model.record(chat.id)?.brief?.through == "retried-a0" }
        try journal.message("retried-u1", role: "user", "Second question.")
        try journal.message("retried-a1", role: "assistant", "Half a reply before the provider failed.")
        finishRun(model, chat.id, receipts: ["t1", "t2"], state: "failed", runState: "error", revision: "e:2")
        try await eventually("the failed run's end updates it", timeout: .seconds(60)) { model.record(chat.id)?.brief?.through == "retried-a1" }
        // Retried: the same command runs again, its receipt still failed.
        try journal.message("retried-a2", role: "assistant", "More of the reply, from the retry, before it failed again.")
        finishRun(model, chat.id, receipts: ["t1", "t2"], state: "failed", runState: "running", revision: "e:3")
        finishRun(model, chat.id, receipts: ["t1", "t2"], state: "failed", runState: "error", revision: "e:4")
        try await eventually("the retry's end updates it", timeout: .seconds(60)) { model.record(chat.id)?.brief?.through == "retried-a2" }
        XCTAssertEqual(gateway.requests.count, 3)
        XCTAssertTrue(gateway.requests[2].prompt.contains("More of the reply, from the retry"))
        // Settled with nothing new: nothing more.
        finishRun(model, chat.id, receipts: ["t1", "t2"], state: "failed", runState: "error", revision: "e:4")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(gateway.requests.count, 3)
    }

    /// A journal the reader keeps a notice for (a damaged record, a tail cut
    /// off mid-write) is not summed up from what is left of it: Write Brief
    /// says it could not be read, and sends nothing.
    @MainActor func testAChatWhoseHistoryHasANoticeIsReportedUnreadable() async throws {
        let fixture = try await self.fixture()
        let model = fixture.model, gateway = fixture.gateway
        let (chat, journal) = try await self.chat("damaged", fixture, title: "Damaged chat", turns: [("A question.", "An answer.")])
        let handle = try FileHandle(forWritingTo: journal.url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(#"{"type":"message","id":"damaged-cut","message":{"role":"user","con"#.utf8)); try handle.close()
        model.writeBriefNow(chat.id)
        try await eventually("the chat is looked at", timeout: .seconds(30)) { model.chatBriefs.outcomes[chat.id] != nil }
        guard case .unreadable(let why)? = model.chatBriefs.outcomes[chat.id] else {
            return XCTFail("A page with a notice is unreadable: \(String(describing: model.chatBriefs.outcomes[chat.id]))")
        }
        XCTAssertFalse(why.isEmpty)
        XCTAssertTrue(model.chatBriefs.lastProblem(chat.id)?.contains("could not be read") == true, model.chatBriefs.lastProblem(chat.id) ?? "")
        XCTAssertTrue(gateway.requests.isEmpty, "Nothing is sent from a page with a notice")
        XCTAssertNil(model.record(chat.id)?.brief)
    }

    /// Quitting lets go of the briefs reader's history indexes, whose files
    /// are in the temporary folder, as it does of the shared reader's.
    @MainActor func testQuittingReleasesTheBriefsReadersIndexes() async throws {
        let fixture = try await self.fixture()
        let model = fixture.model
        let (chat, journal) = try await self.chat("quitting", fixture, title: "Quitting", turns: [("A question.", "An answer.")])
        finishRun(model, chat.id, receipts: ["t1"])
        try await eventually("the brief is written", timeout: .seconds(60)) { model.record(chat.id)?.brief != nil }
        let reader = try XCTUnwrap(model.chatBriefsStorage?.reader)
        let held = await reader.indexedPaths
        XCTAssertTrue(held.contains(journal.url.path), "The brief's read built an index: \(held)")
        try await eventually("nothing is under way", timeout: .seconds(30)) { !model.hasActiveWork }
        let lifecycle = ApplicationLifecycle()
        lifecycle.model = model
        var answers: [Bool] = []
        lifecycle.answerTermination = { answers.append($0) }
        XCTAssertEqual(lifecycle.applicationShouldTerminate(NSApp), .terminateLater)
        try await eventually("quitting answers", timeout: .seconds(60)) { !answers.isEmpty }
        XCTAssertEqual(answers, [true])
        let left = await reader.indexedPaths
        XCTAssertTrue(left.isEmpty, "Quitting released the briefs reader's indexes: \(left)")
    }

    /// The newest page starts inside a long, tool-heavy turn: the brief quotes
    /// the question that opened the turn, never the row ID the page names it by.
    @MainActor func testAPageStartingInsideATurnQuotesItsQuestionNotItsRowID() async throws {
        let fixture = try await self.fixture()
        let model = fixture.model, gateway = fixture.gateway
        let (chat, journal) = try await self.chat("heavy", fixture, title: "Tool-heavy chat", turns: [])
        try journal.message("heavy-question", role: "user", "Please move every parser module onto the streaming reader.")
        for index in 0..<40 {
            try journal.message("heavy-call-\(index)", role: "assistant",
                                [["type": "toolCall", "id": "call-\(index)", "name": "read", "arguments": ["path": "Parser\(index).swift"]]])
            try journal.message("heavy-result-\(index)", role: "toolResult", [["type": "text", "text": "contents of Parser\(index).swift"]],
                                extra: ["toolCallId": "call-\(index)", "toolName": "read", "isError": false])
        }
        try journal.message("heavy-answer", role: "assistant", "Every parser module now reads from the streaming reader.")
        let page = try await HistoryReader().read(path: journal.url.path)
        XCTAssertEqual(page.partialTurnInput, "heavy-question", "The newest page starts inside the turn and names its question's row")
        finishRun(model, chat.id, receipts: ["t1"])
        try await eventually("the brief is written", timeout: .seconds(60)) { model.record(chat.id)?.brief != nil }
        let prompt = try XCTUnwrap(gateway.requests.first).prompt
        XCTAssertTrue(prompt.contains("Please move every parser module onto the streaming reader."), prompt)
        XCTAssertFalse(prompt.contains("heavy-question"), "The row's ID is not quoted as the question")
        XCTAssertTrue(prompt.contains("Every parser module now reads from the streaming reader."))
    }

    /// A brief being prepared (its model list, its chat's page) is work under
    /// way: an update's idle barrier waits for it. One that a quit or an update
    /// overtakes anyway sends nothing, and the mini model is asked nothing once
    /// either has begun.
    @MainActor func testABriefBeingPreparedHoldsTheUpdateBarrierAndSendsNothingAfterIt() async throws {
        let fixture = try await self.fixture()
        let model = fixture.model, gateway = fixture.gateway
        let (first, _) = try await self.chat("prepared", fixture, title: "Prepared", turns: [("A question.", "An answer.")])
        let (second, _) = try await self.chat("overtaken", fixture, title: "Overtaken", turns: [("Another question.", "Another answer.")])
        // Held in its preparation (here, waiting out a connection change).
        let (released, release) = AsyncStream<Never>.makeStream()
        model.connectionSwitches[first.id] = (UUID(), Task { for await _ in released {} })
        model.writeBriefNow(first.id)
        XCTAssertTrue(model.hasActiveWork, "A brief being prepared is work under way")
        XCTAssertFalse(model.acquireUpdateBarrier(), "The update's barrier waits for it")
        XCTAssertFalse(model.installPreparing)
        model.connectionSwitches[first.id] = nil; release.finish()
        try await eventually("its brief is written", timeout: .seconds(60)) { model.record(first.id)?.brief != nil }
        try await eventually("nothing is under way", timeout: .seconds(30)) { !model.hasActiveWork }
        XCTAssertEqual(gateway.requests.count, 1)
        // A quit or an update that begins while the next one is prepared.
        model.chatBriefs.beforeDispatch = { _ in model.installPreparing = true }
        model.writeBriefNow(second.id)
        try await eventually("it is over", timeout: .seconds(30)) { model.chatBriefs.outcomes[second.id] != nil }
        XCTAssertEqual(model.chatBriefs.outcomes[second.id], .skipped)
        XCTAssertEqual(gateway.requests.count, 1, "Nothing is sent once a quit or an update has begun")
        XCTAssertFalse(model.chats.contains { $0.backgroundTask == "chat-brief" && $0.sourceSessionID == second.id })
        // Nor does any request to the mini model start a helper or send.
        model.chatBriefs.beforeDispatch = nil
        let profile = try XCTUnwrap(model.profiles.first)
        let request = MiniModelRequest(model: "mini-fixture", contextWindow: profile.contextWindow, maxOutputTokens: 512, modelOutputLimit: nil,
                                       thinkingLevel: "default", prompt: "Never sent", task: "chat-brief", title: "Chat brief", timeout: 30, name: "brief request")
        do {
            _ = try await model.askMiniModel(request, profile: profile, sourceID: second.id) { _ in "" }
            XCTFail("Nothing is asked of the mini model once a quit or an update has begun")
        } catch {}
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(gateway.requests.count, 1)
        XCTAssertFalse(model.chats.contains { $0.backgroundTask == "chat-brief" && $0.sourceSessionID == second.id }, "Not even its request's record is made")
        model.installPreparing = false
    }

    /// A chat archived while Write Briefs waits on an earlier one is left
    /// alone when its turn comes, as an archived chat is when it starts.
    @MainActor func testWriteBriefsLeavesAChatArchivedWhileItWaits() async throws {
        let fixture = try await self.fixture()
        let model = fixture.model, gateway = fixture.gateway
        for (index, id) in ["first", "second", "third"].enumerated() {
            _ = try await chat(id, fixture, title: id, turns: [("Question for the \(id) chat.", "Answer.")], activity: Int64(10 - index) * 1_000_000)
        }
        gateway.hold(true)
        model.chatBriefs.startBatch()
        XCTAssertEqual(model.chatBriefs.batch?.total, 3)
        try await eventually("the first request is sent", timeout: .seconds(60)) { gateway.requests.count == 1 }
        model.chats[try XCTUnwrap(model.chats.firstIndex { $0.id == "second" })].archivedAt = Date()
        gateway.hold(false)
        try await eventually("the batch is over", timeout: .seconds(120)) { model.chatBriefs.batch?.finished == true }
        XCTAssertEqual(gateway.requests.count, 2, "The archived chat is not asked about")
        XCTAssertFalse(gateway.requests.contains { $0.prompt.contains("Question for the second chat.") })
        XCTAssertNil(model.record("second")?.brief)
        XCTAssertNotNil(model.record("first")?.brief); XCTAssertNotNil(model.record("third")?.brief)
        XCTAssertEqual(model.chatBriefs.batch?.done, 3); XCTAssertEqual(model.chatBriefs.batch?.written, 2)
    }

    /// Beside the setting: brief requests today and over the last 30 days,
    /// counted as the Background requests page lists them, at the cost the
    /// gateway reported.
    @MainActor func testUsageBesideTheSettingCountsTodayAndTheLast30Days() async throws {
        let fixture = try await self.fixture()
        let model = fixture.model
        let (chat, _) = try await self.chat("counted", fixture, title: "Counted", turns: [("Count this request.", "Counted.")])
        let now = Date()
        func request(_ id: String, daysAgo: Double) -> ChatRecord {
            var value = ChatRecord(id: id, workspaceID: WorkspaceRecord.scratchID, title: "Chat brief", path: nil, profileID: "profile")
            value.backgroundTask = "chat-brief"; value.sourceSessionID = chat.id; value.backgroundTaskOutcome = "completed"
            value.backgroundTaskStartedAt = now.addingTimeInterval(-daysAgo * 86_400)
            return value
        }
        model.chats += [request("ten-days", daysAgo: 10), request("forty-days", daysAgo: 40)]
        var title = request("a-title", daysAgo: 0); title.backgroundTask = "session-title"
        model.chats.append(title)
        model.writeBriefNow(chat.id)
        try await eventually("the brief is written", timeout: .seconds(60)) { model.record(chat.id)?.brief != nil }
        let card = ChatBriefSettingsCard(model: model, get: { model.briefSettings }, set: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = card
        defer { window.contentView = nil; window.close() }
        try await eventually("the archive has the request's cost", timeout: .seconds(30)) {
            card.today.requests == 1 && abs(card.today.costUSD - 0.004) < 1e-9 && card.month.requests == 2
        }
        XCTAssertEqual(card.today, ChatBriefUsage(requests: 1, costUSD: card.today.costUSD))
        XCTAssertEqual(card.month.requests, 2, "Ten days ago counts; forty days ago and other requests do not")
        XCTAssertEqual(card.month.costUSD, 0.004, accuracy: 1e-9)
        func figure(_ id: String) -> String? {
            func walk(_ view: NSView) -> PiKit.TextLine? {
                if let line = view as? PiKit.TextLine, line.accessibilityIdentifier() == id { return line }
                return view.subviews.lazy.compactMap(walk).first
            }
            return walk(card)?.line.text
        }
        XCTAssertEqual(figure("settings-chat-briefs-today"), "1 request · $0.004")
        XCTAssertEqual(figure("settings-chat-briefs-month"), "2 requests · $0.004")
    }
}

/// A loopback Responses gateway for chat briefs. It keeps every request and
/// answers each with a numbered brief as JSON and a fixed reported cost, or
/// with nothing usable while told to; it holds requests unanswered while
/// told to, and answers them when let go. Synthetic credentials and data only.
final class BriefGateway: @unchecked Sendable {
    struct Request {
        let head: String
        let raw: String
        let body: [String: WireValue]
        /// The helper's system prompt, and the request's own text.
        var system: String { body["input"]?.array?.first?.object?["content"]?.string ?? "" }
        var prompt: String { body["input"]?.array?.last?.object?["content"]?.array?.compactMap { $0.object?["text"]?.string }.joined() ?? "" }
        var sessionID: String? {
            head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("x-session-id:") }
                .map { String($0.dropFirst("x-session-id:".count)).trimmingCharacters(in: .whitespaces) }
        }
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BelloAgent.BriefGatewayFixture")
    private let lock = NSLock()
    private var captured: [Request] = []
    private var connections: [NWConnection] = []
    private var holding = false
    private var held: [(NWConnection, Int)] = []
    private var useless = false
    private let cost: String
    var requests: [Request] { lock.withLock { captured } }
    /// Held: requests wait unanswered, as for a slow model. Let go: those
    /// still waiting are answered (a stopped one's connection is closed).
    func hold(_ value: Bool) {
        let release = lock.withLock { () -> [(NWConnection, Int)] in
            holding = value
            guard !value else { return [] }
            defer { held = [] }
            return held
        }
        for (connection, number) in release { answer(connection, number: number) }
    }
    /// Answers the requests waiting now, and goes on holding the next ones.
    func answerHeld() {
        let release = lock.withLock { () -> [(NWConnection, Int)] in defer { held = [] }; return held }
        for (connection, number) in release { answer(connection, number: number) }
    }
    /// Answers with text that holds no brief.
    func unusable(_ value: Bool) { lock.withLock { useless = value } }

    init(cost: String = "0.004") throws {
        self.cost = cost
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> String {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue); self.receive(connection, previous: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.listener.stateUpdateHandler = nil; continuation.resume(returning: "http://127.0.0.1:\(self.listener.port!.rawValue)")
                case .failed(let error): self.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel(); lock.withLock { connections }.forEach { $0.cancel() } }

    private func receive(_ connection: NWConnection, previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            let bytes = previous + (data ?? Data())
            guard error == nil, bytes.count <= 8 << 20 else { connection.cancel(); return }
            guard let split = bytes.range(of: Data("\r\n\r\n".utf8)), let head = String(data: bytes[..<split.lowerBound], encoding: .utf8) else {
                if complete { connection.cancel() } else { self.receive(connection, previous: bytes) }
                return
            }
            guard head.hasPrefix("POST /v1/responses") else {
                let reply = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let length = head.lowercased().components(separatedBy: "\r\n").first { $0.hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            guard bytes.count >= split.upperBound + length else {
                if complete { connection.cancel() } else { self.receive(connection, previous: bytes) }
                return
            }
            let payload = Data(bytes[split.upperBound..<(split.upperBound + length)])
            let body = (try? JSONDecoder().decode([String: WireValue].self, from: payload)) ?? [:]
            let (number, holding) = self.lock.withLock { () -> (Int, Bool) in
                self.captured.append(Request(head: head, raw: String(decoding: payload, as: UTF8.self), body: body))
                if self.holding { self.held.append((connection, self.captured.count)) }
                return (self.captured.count, self.holding)
            }
            // Held: answered once let go, unless the app stops it first.
            guard !holding else { return }
            self.answer(connection, number: number)
        }
    }

    private func answer(_ connection: NWConnection, number: Int) {
        let brief: [String: Any] = ["brief": "Brief \(number): the lantern parser moves to streaming input.", "keywords": ["lantern", "tokenizer-\(number)"]]
        let text = lock.withLock { useless } ? "I can't help with that."
            : String(decoding: (try? JSONSerialization.data(withJSONObject: brief, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        let response: [String: Any] = [
            "id": "resp_brief_\(number)", "object": "response", "status": "completed", "model": "resolved-mini-fixture",
            "output": [["id": "msg_brief_\(number)", "type": "message", "role": "assistant", "status": "completed",
                        "content": [["type": "output_text", "text": text]]]],
            "usage": ["input_tokens": 120, "output_tokens": 30, "total_tokens": 150]]
        let encoded = (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
        let reply = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(encoded.count)\r\nx-litellm-response-cost: \(cost)\r\nConnection: close\r\n\r\n".utf8) + encoded
        connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
    }
}
