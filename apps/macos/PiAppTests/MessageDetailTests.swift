import XCTest
@testable import PiApp

final class MessageDetailTests: XCTestCase {
    func testModelDetailsUseLiteralBodyRouteAndKeepHeaderAndAliasReports() {
        func item(_ source: String, _ name: String) -> WireValue { .object(["kind": .string("model"), "source": .string(source), "value": .string(name)]) }
        let metadata: [String: WireValue] = ["requestedModel": .string("auto-router"), "identity": .object([
            "status": .string("conflict"), "effectiveModel": .null, "evidence": .array([
                item("header:x-litellm-model-name", "openai/gpt-5.4-mini"), item("body.model", "auto-router"),
                item("body.router_model_name", "gpt-5.4-mini-2026-09-16")])])]
        let model = GatewayModelIdentity(metadata: metadata)
        XCTAssertEqual(model.response, .init(name: "gpt-5.4-mini-2026-09-16", source: "body.router_model_name"))
        XCTAssertEqual(model.displayName, "gpt-5.4-mini-2026-09-16")
        XCTAssertEqual(model.headerReports, [.init(name: "openai/gpt-5.4-mini", source: "header:x-litellm-model-name")])
        XCTAssertEqual(model.bodyReports.map(\.name), ["auto-router", "gpt-5.4-mini-2026-09-16"])
        XCTAssertNil(model.legacyModel)
    }

    func testModelDetailsPreferTerminalReportsWithoutGuessingUnknownOrLegacyProvenance() {
        func item(_ source: String, _ name: String, kind: String = "model") -> WireValue { .object(["kind": .string(kind), "source": .string(source), "value": .string(name)]) }
        func project(_ values: [WireValue]) -> GatewayModelIdentity { GatewayModelIdentity(metadata: ["identity": .object(["evidence": .array(values)])]) }
        let terminal = project([item("response.completed.response.router_model_name", "terminal-model"),
                                item("response.created.response.router_model_name", "initial-model"), item("response.completed.response.model", "alias")])
        XCTAssertEqual(terminal.displayName, "terminal-model")
        XCTAssertEqual(project([item("response.completed.response.model", "body-model")]).displayName, "body-model")
        XCTAssertEqual(project([item("body.router_model_name", "earlier"), item("body.router_model_name", "later")]).displayName, "later")
        for report in [item("response.output_text.delta.router_model_name", "not-a-model-report"), item("body.model", "bad\nname"), item("body.model", String(repeating: "x", count: 257)), item("body.model", "  "), item("body.model", "route-group", kind: "group")] {
            XCTAssertNil(project([report]).displayName)
        }
        let invalidRouter = project([item("body.router_model_name", "invalid\nroute"), item("body.model", "fallback-body")])
        XCTAssertEqual(invalidRouter.displayName, "fallback-body")
        XCTAssertNil(GatewayModelIdentity(metadata: [:]).displayName)
        let legacy = GatewayModelIdentity(metadata: ["requestedModel": .string("router"), "identity": .object(["status": .string("reported"), "effectiveModel": .string("legacy-model")])])
        XCTAssertEqual(legacy.displayName, "legacy-model"); XCTAssertNil(legacy.response); XCTAssertTrue(legacy.headerReports.isEmpty)
        XCTAssertEqual(GatewayModelIdentity(metadata: ["identity": .object(["effectiveModel": .string("older-model")])]).displayName, "older-model")
        let conflictedLegacy = GatewayModelIdentity(metadata: ["identity": .object(["status": .string("conflict"), "reportedModels": .array([.string("short"), .string("long-unknown-source")])])])
        XCTAssertNil(conflictedLegacy.displayName, "Unattributed conflicting names cannot establish a response-body preference")
    }

    func testTranscriptMessageDecodesKindAndDetailAndKeepsThemOptional() throws {
        let packet = Data("""
        [{"id":"c1","role":"system","text":"Summary of the earlier work","kind":"compaction","detail":"Compacted 12000 tokens · 4 messages kept"},
         {"id":"b1","role":"system","text":"Edited from here · earlier replies stay in the journal","kind":"branch"},
         {"id":"u1","role":"user","text":"hello"}]
        """.utf8)
        let messages = try JSONDecoder().decode([TranscriptMessage].self, from: packet)
        XCTAssertEqual(messages.map(\.kind), ["compaction", "branch", nil])
        XCTAssertEqual(messages[0].detail, "Compacted 12000 tokens · 4 messages kept")
        XCTAssertNil(messages[1].detail); XCTAssertNil(messages[2].detail)
        let roundTrip = try JSONDecoder().decode([TranscriptMessage].self, from: JSONEncoder().encode(messages))
        XCTAssertEqual(roundTrip, messages, "Codable round trip must preserve kind and detail")
        XCTAssertNotEqual(messages[0], TranscriptMessage(id: "c1", role: "system", text: "Summary of the earlier work"), "Equatable must include the marker fields")
        let projected = TranscriptMessage.project(id: "h1", message: ["role": .string("user"), "content": .string("history")])
        XCTAssertNil(projected.kind); XCTAssertNil(projected.detail)
    }
    func testEditTurnCommandCarriesContractParameters() throws {
        let attachment = AttachmentRecord(id: "a", path: "/tmp/image.png", sha256: "00", bytes: 3, mimeType: "image/png")
        let skill = SkillChip(id: "s", name: "review", path: "/skills/review.md", contentHash: "c", metadataHash: "m", arguments: "src")
        XCTAssertEqual(WorkspaceModel.editTurnMethod, "turn.edit")
        let params = WorkspaceModel.editTurnParams(messageID: "msg-7", text: "edited text", turnID: "turn-1", attachments: [attachment], skills: [skill])
        XCTAssertEqual(params["messageId"], .string("msg-7")); XCTAssertEqual(params["text"], .string("edited text")); XCTAssertEqual(params["clientTurnId"], .string("turn-1"))
        XCTAssertEqual(params["attachments"], .array([attachment.wire])); XCTAssertEqual(params["skills"], .array([skill.wire]))
        XCTAssertNil(params["model"]); XCTAssertNil(params["thinkingLevel"])
        let overridden = WorkspaceModel.editTurnParams(messageID: "msg-7", text: "t", turnID: "turn-2", attachments: [], skills: [], model: "gpt-5", thinkingLevel: "high")
        XCTAssertEqual(overridden["model"], .string("gpt-5")); XCTAssertEqual(overridden["thinkingLevel"], .string("high"))
        let invalid = WorkspaceModel.editTurnParams(messageID: "m", text: "t", turnID: "turn-3", attachments: [], skills: [], model: String(repeating: "x", count: 201), thinkingLevel: "turbo")
        XCTAssertNil(invalid["model"]); XCTAssertNil(invalid["thinkingLevel"])
        struct Record: Encodable { var id = "c"; var model: String?; var thinkingLevel: String? }
        let overrides = WorkspaceModel.turnOverrides(Record(model: "claude", thinkingLevel: "low"))
        XCTAssertEqual(overrides.model, "claude"); XCTAssertEqual(overrides.thinkingLevel, "low")
        let none = WorkspaceModel.turnOverrides(ChatRecord(id: "c", workspaceID: "w", title: "t", path: nil, profileID: "p"))
        XCTAssertNil(none.model); XCTAssertNil(none.thinkingLevel)
    }
    @MainActor func testEditModeLoadsUserTextAndCancelRestoresDraft() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("native-edit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage())), view = SessionDisplay(id: "chat")
        model.chats = [ChatRecord(id: "chat", workspaceID: "w", title: "t", path: nil, profileID: "p")]
        model.displays["chat"] = view; model.selectedID = "chat"
        view.messages = [TranscriptMessage(id: "u1", role: "user", text: "first question"), TranscriptMessage(id: "a1", role: "assistant", text: "answer"),
                         TranscriptMessage(id: "b1", role: "system", text: "Edited from here", kind: "branch")]
        view.draft = "unsent draft"
        let originalAttachment = AttachmentRecord(id: "original", path: "/tmp/original.png", sha256: "00", bytes: 3, mimeType: "image/png")
        let originalSkill = SkillChip(id: "skill", name: "review", path: "/skills/review.md", contentHash: "c", metadataHash: "m", arguments: "src")
        view.attachments = [originalAttachment]; view.skills = [originalSkill]
        model.editMessage("a1", sessionID: "chat"); XCTAssertNil(view.editingMessageID, "Only user messages can be edited")
        model.editMessage("b1", sessionID: "chat"); XCTAssertNil(view.editingMessageID, "Marker rows are display-only")
        model.editTargetRead = { session, id in
            ["messageId": .string(id), "text": .string("first question"), "sourceTimeline": .string("fixture"), "sourceTextDigest": .string("fixture")]
        }
        let focus = view.composerFocusRequest
        model.editMessage("u1", sessionID: "chat")
        while view.editPreparing { await Task.yield() }
        XCTAssertEqual(view.editingMessageID, "u1"); XCTAssertEqual(view.draft, "first question"); XCTAssertEqual(view.draftBeforeEdit?.text, "unsent draft")
        XCTAssertGreaterThan(view.composerFocusRequest, focus, "Editing a message puts the cursor in the composer")
        XCTAssertTrue(view.attachments.isEmpty); XCTAssertTrue(view.skills.isEmpty, "An unrelated draft's skills must never authorize an edited turn")
        view.state = "running"; view.draft = "changed question"
        model.send(sessionID: "chat")
        XCTAssertEqual(view.editingMessageID, "u1"); XCTAssertFalse(view.loading); XCTAssertTrue(view.notice.contains("Wait for the current run"), "Edits require an idle session with an empty queue")
        model.send(steer: true, sessionID: "chat")
        XCTAssertTrue(view.notice.contains("Finish or cancel"), "Global send/steer commands must respect edit mode too")
        view.state = "idle"
        model.cancelEdit(sessionID: "chat")
        XCTAssertNil(view.editingMessageID); XCTAssertEqual(view.draft, "unsent draft"); XCTAssertNil(view.draftBeforeEdit)
        XCTAssertEqual(view.attachments, [originalAttachment]); XCTAssertEqual(view.skills, [originalSkill])
        // A message's Details open the chat's Session Inspector at that message's request.
        model.showMessageDetail("chat", messageID: "u1")
        XCTAssertEqual(model.lastInspectorFocus, .message("u1"))
        XCTAssertNotNil(SessionInspectorWindows.shared.controller(sessionID: "chat"), "The chat's Inspector window is open")
        model.shutdown()
        XCTAssertNil(SessionInspectorWindows.shared.controller(sessionID: "chat"), "Shutting down closes the chat's Inspector")
    }
    @MainActor func testEditDraftRoundTripRestoresTargetAndOriginalComposer() throws {
        let view = SessionDisplay(id: "chat")
        let attachment = AttachmentRecord(id: "a", path: "/tmp/image.png", sha256: "00", bytes: 3, mimeType: "image/png")
        view.draftBeforeEdit = DraftRecord(id: "chat", text: "original unsent draft", attachments: [attachment])
        view.editingMessageID = "earlier-user"; view.draft = "edited request"
        let persisted = try JSONDecoder().decode(DraftRecord.self, from: JSONEncoder().encode(view.savedDraft))
        let restored = SessionDisplay(id: "chat"); restored.restoreDraft(persisted)
        XCTAssertEqual(restored.editingMessageID, "earlier-user"); XCTAssertEqual(restored.draft, "edited request")
        XCTAssertEqual(restored.draftBeforeEdit?.text, "original unsent draft"); XCTAssertEqual(restored.draftBeforeEdit?.attachments, [attachment])
        XCTAssertTrue(restored.attachments.isEmpty)
        let legacy = try JSONDecoder().decode(DraftRecord.self, from: Data(#"{"id":"chat","text":"legacy draft"}"#.utf8))
        restored.restoreDraft(legacy)
        XCTAssertNil(restored.editingMessageID); XCTAssertNil(restored.draftBeforeEdit); XCTAssertEqual(restored.draft, "legacy draft")
    }
    @MainActor func testEditingTruncatedMessageLoadsRetainedTextWithoutReplacingDraftWithPreview() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("native-edit-full-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = String(repeating: "full message 🌍 ", count: 5000), path = root.appendingPathComponent("session.jsonl")
        let entry: [String: WireValue] = ["id": .string("u1"), "type": .string("message"), "message": .object(["role": .string("user"), "content": .string(text)])]
        var bytes = Data("{\"type\":\"session\",\"version\":3,\"id\":\"chat\"}\n".utf8)
        bytes.append(try JSONEncoder().encode(entry)); bytes.append(10); try bytes.write(to: path)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        model.chats = [ChatRecord(id: "chat", workspaceID: "w", title: "t", path: path.path, profileID: "p")]
        let view = SessionDisplay(id: "chat"); view.draft = "unsent"; model.displays[view.id] = view
        // Simulate a preview persisted by older versions; new projections keep
        // the complete text and no longer manufacture truncated messages.
        var preview = TranscriptMessage.project(id: "u1", message: entry["message"]!.object!)
        preview.text = String(text.prefix(100)); preview.truncated = true
        view.messages = [preview]
        XCTAssertEqual(view.messages[0].truncated, true)
        model.editMessage("u1", sessionID: "chat")
        XCTAssertTrue(view.editPreparing); XCTAssertNil(view.editingMessageID); XCTAssertEqual(view.draft, "unsent")
        for _ in 0..<200 where view.editPreparing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(view.editPreparing); XCTAssertEqual(view.editingMessageID, "u1"); XCTAssertEqual(view.draft, text)
        XCTAssertEqual(view.draftBeforeEdit?.text, "unsent")
    }
    @MainActor func testBodyCopyRequiresEveryPageOfOneStableRetainedBody() async throws {
        let bytes = Data(String(repeating: "Unicode 🌍 body\n", count: 7000).utf8)
        let copied = try await MessageBodyReader.assemble(limit: bytes.count) { offset in
            (bytes.subdata(in: offset..<min(offset + 32768, bytes.count)), bytes.count)
        }
        XCTAssertEqual(copied, bytes, "Copy must assemble beyond the currently displayed 32 KiB page without corrupting split Unicode")
        let oversized = try await MessageBodyReader.assemble(limit: 1) { _ in (Data([1, 2]), 2) }
        XCTAssertNil(oversized)
        do {
            _ = try await MessageBodyReader.assemble(limit: 100) { offset in (offset == 0 ? Data([1, 2]) : Data(), 5) }
            XCTFail("A missing later page must fail instead of silently copying a shortened body")
        } catch { XCTAssertTrue(error.localizedDescription.contains("incomplete")) }
        do {
            _ = try await MessageBodyReader.assemble(limit: 100) { offset in (Data([1, 2]), offset == 0 ? 4 : 6) }
            XCTFail("A changing live capture must be retried instead of mixing different lengths")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        for state in ["not-captured", "not-retained", "credential-omitted", "expired", "purged", "corrupt"] {
            XCTAssertFalse(MessageBodyReader.canReadRetained(state), "\(state) is not an empty original body")
        }
    }
    @MainActor func testBodyCopyReadsRetainedPartialPrefixWithoutLiveHost() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("native-body-prefix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root)
        try await archive.configure(quota: 1_048_576, bodyRetention: 3600, metricRetention: 3600)
        let id = UUID().uuidString, bytes = Data("retained prefix 🌍".utf8)
        var metadata: [String: WireValue] = ["attemptId": .string(id), "sessionId": .string("s"), "turnId": .string("t"), "mode": .string("persist"), "outcome": .string("running")]
        try await archive.begin(metadata, workspace: "w")
        try await archive.append(attempt: id, kind: "response", offset: 0, bytes: bytes)
        metadata["outcome"] = .string("interrupted"); metadata["response"] = .object(["observedBytes": .number(Double(bytes.count + 10))])
        try await archive.finish(metadata)
        let retained = try await archive.metadata(attempt: id)["response"]!.object!
        XCTAssertEqual(retained["state"], .string("partial"))
        XCTAssertTrue(MessageBodyReader.canReadRetained(retained["state"]!.string!))
        let copied = try await MessageBodyReader.assemble(limit: 1024) { offset in
            (try await archive.body(attemptID: id, body: "response", offset: offset), Int(retained["retainedBytes"]!.number!))
        }
        XCTAssertEqual(copied, bytes)
    }
}
