import AppKit
import XCTest
@testable import PiApp

final class SideKeepRecoveryTests: XCTestCase {
    @MainActor private func fixture() throws -> WorkspaceModel {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("side-keep-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        return model
    }

    /// The helper's envelope and parent chain, including a promoted marker.
    static func journal(id: String, marker: Int = 3, tool: Bool = false, coordination: Bool = false) throws -> Data {
        var bytes = Data(), parent: String?
        func append(_ id: String, _ fields: [String: WireValue]) throws {
            var row = fields; row["id"] = .string(id); row["parentId"] = parent.map(WireValue.string) ?? .null
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            bytes.append(try encoder.encode(row)); bytes.append(10); parent = id
        }
        try append(id, ["type": .string("session"), "version": .number(3)]); parent = nil
        try append("marker", ["type": .string("custom"), "customType": .string("pi-app.native.v\(marker)"), "data": .object(["version": .number(Double(marker))])])
        try append("question", ["type": .string("message"), "message": .object(["role": .string("user"), "content": .string("Generated question")])])
        if tool {
            try append("call", ["type": .string("message"), "message": .object(["role": .string("assistant"), "content": .array([.object(["type": .string("toolCall"), "id": .string("read-1"), "name": .string("read"), "arguments": .object(["path": .string("fixture.txt")])])])])])
        }
        if coordination {
            for kind in ["agent-operation", "agent-message", "agent-delivery", "subagent-turn-state", "subagent-turn-terminal", "family-run", "subagent-call"] {
                try append(kind, ["type": .string("custom"), "customType": .string("pi-app.\(kind).v1"), "data": .object([:])])
            }
            for author in ["parent", "subagent"] {
                try append(author, ["type": .string("message"), "message": .object([
                    "role": .string("user"), "content": .array([.object(["type": .string("text"), "text": .string("{\"kind\":\"agent_events\",\"version\":3,\"events\":[]}")])]),
                    "nativeKind": .string("agent_message"), "nativeAgentDelivery": .object(["version": .number(1), "author": .string(author), "childId": .string("child"), "turn": .number(1), "eventIds": .array([])])])])
            }
            try append("fork-context", ["type": .string("custom"), "customType": .string("pi-app.native.context.v1"), "data": .object(["ids": .array(["question", "parent", "subagent"].map(WireValue.string))])])
        }
        try append("state", ["type": .string("custom"), "customType": .string("pi-app.native.state.v1"), "data": .object(["active": .bool(tool), "queue": .array([]), "steering": .array([])])])
        return bytes
    }

    @MainActor @discardableResult private func save(_ bytes: Data?, id: String, in model: WorkspaceModel) async throws -> ChatRecord {
        let path = model.root.appendingPathComponent("\(id).jsonl")
        if let bytes { try bytes.write(to: path) }
        let chat = ChatRecord(id: id, workspaceID: "w", title: "Side \(id)", path: path.path, profileID: "p", toolMode: "read-only", parentSessionID: "parent")
        try await model.store?.put(SideKeepIntent(chat: chat), kind: "side-keep", id: id)
        return chat
    }

    @MainActor func testCutOffStreamingAndToolTailsRegisterAndOpenWithExistingRecoveryNotice() async throws {
        let model = try fixture()
        for tool in [false, true] {
            let id = tool ? "tool" : "streaming"
            var bytes = try Self.journal(id: id, tool: tool)
            bytes.append(Data("{\"type\":\"message\",\"id\":\"unfinished".utf8))
            let chat = try await save(bytes, id: id, in: model)
            await model.reconcileSideKeeps()
            XCTAssertNotNil(model.record(id), "A history notice is not an identity failure")
            let pending = try await model.store?.get(SideKeepIntent.self, kind: "side-keep", id: id)
            XCTAssertNil(pending)
            await model.select(id)
            XCTAssertEqual(model.selected?.notice, "The last record of this chat was cut off while it was written. Everything before it is shown, read-only.")
            XCTAssertEqual(model.selected?.messages.first?.text, "Generated question")
            XCTAssertTrue(model.hosts.isEmpty)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: chat.path!)), bytes)
        }
    }

    @MainActor func testDamagedHistoryAfterValidIdentityRegistersWithoutRepair() async throws {
        let model = try fixture()
        var bytes = try Self.journal(id: "damaged"); bytes.append(Data("not-json\n".utf8))
        let chat = try await save(bytes, id: "damaged", in: model)
        await model.reconcileSideKeeps()
        XCTAssertNotNil(model.record(chat.id))
        await model.select(chat.id)
        XCTAssertTrue(model.selected?.notice.contains("Damaged history record preserved") == true)
        XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: chat.path!)), bytes)
    }

    @MainActor func testIdentityValidationDoesNotScanHistory() async throws {
        let model = try fixture(), bytes = try Self.journal(id: "bounded")
        let chat = try await save(bytes, id: "bounded", in: model)
        try await model.history.validateIdentity(path: chat.path!, id: chat.id)
        let indexed = await model.history.indexedBytes
        XCTAssertEqual(indexed, 0, "Identity admission reads the bounded header, not the transcript")
    }

    @MainActor func testV3CoordinationTypedRowsAndForkContextAreReadableInNormalAndKeptChats() async throws {
        let model = try fixture(), bytes = try Self.journal(id: "v3", coordination: true)
        let chat = try await save(bytes, id: "v3", in: model)
        let page = try await model.history.window(path: chat.path!)
        XCTAssertNil(page.notice); XCTAssertEqual(page.messages.map(\.id), ["question", "parent", "subagent"])
        await model.reconcileSideKeeps()
        XCTAssertNotNil(model.record(chat.id)); XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: chat.path!)), bytes)
    }

    @MainActor func testUnpublishedFileKeepsItsPendingRegistrationAndCanCompleteLater() async throws {
        let model = try fixture(), chat = try await save(nil, id: "late", in: model)
        await model.reconcileSideKeeps()
        let pending = try await model.store?.get(SideKeepIntent.self, kind: "side-keep", id: chat.id)
        XCTAssertNotNil(pending, "The helper may not have published the promised file yet")
        let bytes = try Self.journal(id: chat.id)
        try bytes.write(to: URL(fileURLWithPath: chat.path!))
        await model.reconcileSideKeeps()
        XCTAssertNotNil(model.record(chat.id)); XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: chat.path!)), bytes)
    }

    @MainActor func testPathAliasesRegisterButASeparateCopyCannotSubstituteForTheExpectedPath() async throws {
        let model = try fixture(), bytes = try Self.journal(id: "alias")
        let chat = try await save(bytes, id: "alias", in: model)
        let alias = model.root.appendingPathComponent("alias-link.jsonl")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: chat.path!)
        try await model.registerKeptSide(id: chat.id, path: alias.path)
        XCTAssertEqual(model.record(chat.id)?.path, alias.path)
        let copy = try await save(bytes, id: "copy", in: model)
        do { try await model.registerKeptSide(id: copy.id, path: alias.path); XCTFail("Wrong file must not be registered") } catch {}
        XCTAssertNil(model.record(copy.id))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: chat.path!)), bytes)
    }

    @MainActor func testInvalidIdentityIsRejectedWithoutChangingBytes() async throws {
        let model = try fixture()
        for (id, text) in [("wrong", "{\"type\":\"session\",\"version\":3,\"id\":\"other\"}\n"),
                           ("version", "{\"type\":\"session\",\"version\":4,\"id\":\"version\"}\n"),
                           ("missing", "{\"type\":\"message\"}\n"), ("cut-header", "{\"type\":\"session\""), ("unreadable", "not-json\n")] {
            let bytes = Data(text.utf8), chat = try await save(bytes, id: id, in: model)
            do { try await model.history.validateIdentity(path: chat.path!, id: chat.id); XCTFail("Invalid identity: \(id)") } catch {}
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: chat.path!)), bytes)
        }
        await model.reconcileSideKeeps(); XCTAssertTrue(model.chats.isEmpty)
        let pending = try await model.store?.list(SideKeepIntent.self, kind: "side-keep")
        XCTAssertEqual(pending?.count, 5)
        XCTAssertEqual(model.sideKeepIssues.count, 5)
        XCTAssertEqual(model.sideKeepIssues.first { $0.id == "wrong" }?.reason, "The file belongs to a different chat.")
        XCTAssertEqual(model.sideKeepIssues.first { $0.id == "version" }?.reason, "The file uses a conversation version this app cannot register.")
        XCTAssertEqual(model.sideKeepIssues.first { $0.id == "missing" }?.reason, "The file has no readable conversation header.")
    }

    @MainActor func testFailuresAreNamedCombinedAndDoNotOverwriteOtherErrors() async throws {
        let model = try fixture()
        model.chats = [ChatRecord(id: "parent", workspaceID: "w", title: "Release checklist", path: nil, profileID: "p")]
        let bytes = try Self.journal(id: "other")
        try await save(bytes, id: "wrong", in: model)
        try await save(Data(), id: "empty", in: model)
        try await save(nil, id: "gone", in: model)
        model.error = "An unrelated connection error"
        for _ in 0..<2 {
            await model.reconcileSideKeeps()
            XCTAssertEqual(model.sideKeepIssues.map(\.id), ["empty", "gone", "wrong"])
            XCTAssertEqual(model.sideKeepIssues.map(\.parentTitle), Array(repeating: "Release checklist", count: 3))
            XCTAssertEqual(model.sideKeepIssues.map { $0.chat.title }, ["Side empty", "Side gone", "Side wrong"])
            XCTAssertEqual(model.error, "An unrelated connection error")
        }
        let view = WorkspaceRootView(model: model)
        view.refresh(); view.layoutSubtreeIfNeeded()
        let notices = ConversationPaneTests.views(SideKeepNoticeView.self, in: view)
        XCTAssertEqual(notices.count, 1); XCTAssertEqual(notices.first?.issues.count, 3)
        let buttons = ConversationPaneTests.views(PiKit.Button.self, in: view).filter { $0.accessibilityIdentifier().hasPrefix("side-keep-") }
        XCTAssertEqual(buttons.count, 10)
        XCTAssertTrue(buttons.allSatisfy { !($0.accessibilityLabel() ?? "").isEmpty })
    }

    @MainActor func testOpenAnywayOnlyInspectsTheFileAndFinderSelectsItsLocation() async throws {
        let model = try fixture(), bytes = try Self.journal(id: "other")
        let chat = try await save(bytes, id: "wrong", in: model)
        await model.reconcileSideKeeps()
        let issue = try XCTUnwrap(model.sideKeepIssues.first)
        let file = try XCTUnwrap(model.openSideKeepFile(issue))
        XCTAssertEqual(file.url.path, FileTab.key(for: URL(fileURLWithPath: chat.path!)))
        XCTAssertTrue(model.chats.isEmpty); XCTAssertTrue(model.hosts.isEmpty); XCTAssertNil(model.selected)
        var shown: URL?
        model.showSideKeepFile(issue) { shown = $0 }
        XCTAssertEqual(shown?.path, chat.path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: chat.path!)), bytes)
        let pending = try await model.store?.get(SideKeepIntent.self, kind: "side-keep", id: chat.id)
        XCTAssertNotNil(pending, "Inspection does not dismiss or register the wrong chat")
        model.tabs.close(file)
        try FileManager.default.removeItem(atPath: chat.path!)
        model.showSideKeepFile(issue) { shown = $0 }
        XCTAssertEqual(shown?.path, model.root.path, "A missing file reveals its remaining folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: chat.path!))
    }

    @MainActor func testDismissRequiresPiConfirmationPreservesFilesAndDoesNotReturnAfterRelaunch() async throws {
        let model = try fixture(), bytes = try Self.journal(id: "other")
        let chat = try await save(bytes, id: "wrong", in: model)
        try await model.store?.put(DraftRecord(id: chat.id, text: "Unsent draft"), kind: "draft", id: chat.id)
        await model.reconcileSideKeeps()
        let issue = try XCTUnwrap(model.sideKeepIssues.first)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 920, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        var answer: ((Bool) -> Void)?, sheet: SideKeepDismissSheet?
        model.questions.presentSheet = { content, _, respond in sheet = content as? SideKeepDismissSheet; answer = respond }
        model.dismissSideKeep(issue, over: window)
        XCTAssertNotNil(sheet); XCTAssertEqual(sheet?.cancel.keyEquivalent, "\r"); XCTAssertEqual(sheet?.confirm.keyEquivalent, "")
        let text = ConversationPaneTests.views(ShellText.self, in: try XCTUnwrap(sheet)).map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("file stays on disk")); XCTAssertTrue(text.contains(chat.title))
        answer?(false)
        var pending = try await model.store?.get(SideKeepIntent.self, kind: "side-keep", id: chat.id)
        XCTAssertNotNil(pending); XCTAssertEqual(model.sideKeepIssues.count, 1)
        model.dismissSideKeep(issue, over: window); answer?(true)
        try await eventually("dismiss the reviewed copy") { model.sideKeepIssues.isEmpty }
        pending = try await model.store?.get(SideKeepIntent.self, kind: "side-keep", id: chat.id)
        XCTAssertNil(pending)
        let draft = try await model.store?.get(DraftRecord.self, kind: "draft", id: chat.id)
        XCTAssertEqual(draft?.text, "Unsent draft"); XCTAssertTrue(model.chats.isEmpty)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: chat.path!)), bytes)
        model.shutdown(); try await model.traces.close(); await model.store?.close()
        let reopened = makeWorkspaceModel(stateRoot: model.root)
        await reopened.restore()
        XCTAssertTrue(reopened.sideKeepIssues.isEmpty); XCTAssertNil(reopened.error)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: chat.path!)), bytes)
    }

    @MainActor func testStaleDismissalCannotRemoveAReplacedPendingCopy() async throws {
        let model = try fixture(), chat = try await save(try Self.journal(id: "other"), id: "wrong", in: model)
        let store = try XCTUnwrap(model.store)
        await model.reconcileSideKeeps()
        let issue = try XCTUnwrap(model.sideKeepIssues.first)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 920, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        var answer: ((Bool) -> Void)?
        model.questions.presentSheet = { _, _, respond in answer = respond }
        model.dismissSideKeep(issue, over: window)
        var replacement = chat; replacement.path = model.root.appendingPathComponent("new-location.jsonl").path
        try await store.put(SideKeepIntent(chat: replacement), kind: "side-keep", id: chat.id)
        answer?(true)
        try await eventually("reject a stale dismissal") { model.error != nil || model.sideKeepIssues.isEmpty }
        let retained = try await store.get(SideKeepIntent.self, kind: "side-keep", id: chat.id)
        XCTAssertEqual(retained?.chat, replacement); XCTAssertEqual(model.sideKeepIssues, [issue])
        XCTAssertNotNil(model.error)
    }

    @MainActor func testArchivedCopyKeepsItsOrganizationAndMissingOrMovedFilesRemainActionable() async throws {
        let model = try fixture(), bytes = try Self.journal(id: "archived")
        var chat = try await save(bytes, id: "archived", in: model)
        chat.archivedAt = Date(timeIntervalSince1970: 123); chat.title = "Renamed after keep"
        try await model.store?.put(chat, kind: "chat", id: chat.id); model.chats = [chat]
        await model.reconcileSideKeeps()
        XCTAssertEqual(model.record(chat.id)?.archivedAt, chat.archivedAt); XCTAssertEqual(model.record(chat.id)?.title, chat.title)
        let moved = try await save(try Self.journal(id: "moved"), id: "moved", in: model)
        let destination = model.root.appendingPathComponent("moved-elsewhere.jsonl")
        try FileManager.default.moveItem(atPath: moved.path!, toPath: destination.path)
        let movedBytes = try Data(contentsOf: destination)
        await model.reconcileSideKeeps()
        XCTAssertEqual(model.sideKeepIssues.map(\.id), ["moved"])
        XCTAssertTrue(model.sideKeepIssues.first?.reason.contains("moved or deleted") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path!))
        XCTAssertEqual(try Data(contentsOf: destination), movedBytes)
    }

    @MainActor func testNoSavedPathHasAnActionableNoticeAndCannotOpenAnUnrelatedFile() async throws {
        let model = try fixture()
        let chat = ChatRecord(id: "no-path", workspaceID: "w", title: "Unlocated copy", path: nil, profileID: "p")
        try await model.store?.put(SideKeepIntent(chat: chat), kind: "side-keep", id: chat.id)
        await model.reconcileSideKeeps()
        let issue = try XCTUnwrap(model.sideKeepIssues.first)
        XCTAssertEqual(issue.reason, "No file location was saved for this chat.")
        XCTAssertNil(model.openSideKeepFile(issue)); model.showSideKeepFile(issue) { _ in XCTFail("No invented location") }
    }

    @MainActor func testLiveKeepFailureUsesTheSameNamedNoticeWithoutBlockingItsSide() async throws {
        let model = try fixture(), chat = try await save(try Self.journal(id: "other"), id: "side", in: model)
        model.sides["parent"] = .init(id: chat.id, parentID: "parent", workspaceID: "w", profileID: "p", title: chat.title)
        await model.applySideStatus(id: chat.id, result: ["ephemeral": .bool(false), "path": .string(chat.path!)])
        XCTAssertEqual(model.sideKeepIssues.map(\.id), [chat.id]); XCTAssertNil(model.error)
        XCTAssertFalse(model.sides["parent"]?.kept ?? true)
    }

    @MainActor func testDismissReturnAndEscapeChooseCancel() throws {
        let chat = ChatRecord(id: "copy", workspaceID: "w", title: "Named copy", path: nil, profileID: "p")
        var answers: [Bool] = []
        let sheet = SideKeepDismissSheet(issue: .init(chat: chat, reason: "Missing header"), parentSize: NSSize(width: 920, height: 600), answer: { answers.append($0) })
        for key in [UInt16(36), 76, 53] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: key == 53 ? "\u{1b}" : "\r", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key))
            XCTAssertTrue(sheet.performKeyEquivalent(with: event))
        }
        XCTAssertEqual(answers, [false, false, false])
    }
}
