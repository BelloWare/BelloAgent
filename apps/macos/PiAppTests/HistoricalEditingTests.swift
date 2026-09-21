import XCTest
import SwiftUI
import AppKit
@testable import PiApp

final class HistoricalEditingTests: XCTestCase {
    @MainActor func testNativeCompactedForkEditSelectsInlineSkillAndSubmitsThroughPackagedHelper() async throws {
        let root = URL(fileURLWithPath: scratchBase()).appendingPathComponent("native-historical-gateway-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var repo = URL(fileURLWithPath: #filePath); for _ in 0..<4 { repo.deleteLastPathComponent() }
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [repo.appendingPathComponent("fixtures/native/edit_gateway.py").path, root.path, "--native-tools"]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice; try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let ready = root.appendingPathComponent("ready.json")
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: ready.path) { try await Task.sleep(for: .milliseconds(10)) }
        let port = try XCTUnwrap(try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: ready))["port"])
        let workspace = WorkspaceRecord(id: "edit", path: root.path, trusted: true)
        var profile = ProfileRecord(); profile.baseUrl = "http://127.0.0.1:\(port)/v1"; profile.modelId = "fixture-model"
        profile.contextWindow = 1_000_000; profile.maxOutputTokens = 2048
        profile.advancedJSON = "{\"routing\":{\"replayPolicy\":\"pinned\",\"expectedModel\":\"fixture-fixed\",\"replayContract\":\"Local deterministic fixture fixes compatible provider items\"}}"
        let vault = ConfigurationVault(storage: MemoryVaultStorage()), savedProfile = profile
        _ = try await vault.update(expectedRevision: 0) {
            $0.workspaces = [workspace]; $0.profiles = [.init(profile: savedProfile, apiKey: "synthetic-edit-key")]
            $0.resources[workspace.id] = .object(["codexHome": .string(root.appendingPathComponent("empty").path)])
        }
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: vault)
        registerWorkspaceFixtureTeardown(model, root: root); try await model.reloadConfiguration()
        let parent = ChatRecord(id: "parent", workspaceID: workspace.id, title: "Parent", profileID: profile.id)
        model.chats = [parent]; model.displays[parent.id] = SessionDisplay(id: parent.id)
        let host = try await model.open(parent)
        func settled(_ id: String) async throws -> [String: WireValue] {
            for _ in 0..<1000 {
                let snapshot = try await host.request("session.snapshot", sessionID: id).object ?? [:]
                if ["idle", "error", "paused"].contains(snapshot["state"]?.string ?? "") { return snapshot }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw HostError.failure("Historical edit fixture did not settle")
        }
        for (id, text) in [("first", "SAFE_FIRST"), ("target", "ORIGINAL_TARGET"), ("third", "FUTURE_THIRD")] {
            _ = try await host.request("turn.submit", sessionID: parent.id, params: ["clientTurnId": .string(id), "text": .string(text)])
            let snapshot = try await settled(parent.id); XCTAssertEqual(snapshot["state"]?.string, "idle", String(describing: snapshot["preflightError"]))
        }
        _ = try await host.request("context.compact", sessionID: parent.id)
        let compacted = try await settled(parent.id); XCTAssertEqual(compacted["state"]?.string, "idle")
        let parentPath = try XCTUnwrap(model.record(parent.id)?.path), parentBytes = try Data(contentsOf: URL(fileURLWithPath: parentPath))
        XCTAssertTrue(String(decoding: parentBytes, as: UTF8.self).contains("FUTURE_TOOL_RESULT"))
        XCTAssertTrue(String(decoding: parentBytes, as: UTF8.self).contains("future-opaque"))
        let fork = try await host.request("session.fork", sessionID: parent.id, params: ["forkSessionId": .string("child")]).object ?? [:]
        let childID = fork["sessionId"]?.string ?? "child", childPath = try XCTUnwrap(fork["path"]?.string)
        let child = ChatRecord(id: childID, workspaceID: workspace.id, title: "Child", path: childPath, profileID: profile.id)
        try await model.store?.put(child, kind: "chat", id: child.id); model.chats.append(child)
        let view = SessionDisplay(id: child.id); view.draft = "ordinary draft"; model.displays[view.id] = view
        model.selectedID = child.id; model.selected = view; model.selectedWorkspaceID = workspace.id; model.focusedSessionID = child.id
        _ = try await model.open(child)
        model.editMessage("target", sessionID: child.id)
        for _ in 0..<1000 where view.editPreparing { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(view.draft, "ORIGINAL_TARGET"); XCTAssertEqual(view.editingMessageID, "target", view.editNotice)
        let directory = root.appendingPathComponent(".agents/skills/edit-check")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "---\nname: edit-check\ndescription: Current native selection\n---\nSKILL_CURRENT_SELECTION\n".write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        await model.loadSkillCatalog(refresh: true, sessionID: child.id)
        view.draft = "EDITED_REPLACEMENT /edit-check"
        let hosted = NSHostingView(rootView: NativeComposer(text: Binding(get: { view.draft }, set: { view.draft = $0 }), send: { _ in XCTFail("Selection must not submit") }, sessionID: view.id, locationChanged: { model.composerMoved($0, editor: $1, view: view) }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func find(_ node: NSView) -> ComposerTextView? { if let editor = node as? ComposerTextView { return editor }; return node.subviews.lazy.compactMap { find($0) }.first }
        hosted.layoutSubtreeIfNeeded(); let editor = try XCTUnwrap(find(hosted)); window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (view.draft as NSString).length, length: 0))
        for _ in 0..<500 where !view.completionVisible { try await Task.sleep(for: .milliseconds(5)) }
        let choice = try XCTUnwrap(model.completions(view).first { $0.name == "edit-check" })
        model.chooseCompletion(choice, view: view); XCTAssertEqual(view.skills.count, 1); XCTAssertEqual(view.draft, "EDITED_REPLACEMENT ")
        model.sendEdit(sessionID: child.id)
        for _ in 0..<1000 where view.editSubmitting { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(view.editingMessageID, view.editNotice); XCTAssertEqual(view.draft, "ordinary draft")
        let result = try await settled(child.id)
        XCTAssertEqual(result["state"]?.string, "idle", String(describing: result["preflightError"]))
        XCTAssertEqual(result["messages"]?.array?.last?.object?["text"]?.string, "EDIT_ACCEPTED_SAFE_PREFIX")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: parentPath)), parentBytes)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("mutation.txt")), "MUTATED_ONCE\n")
        let attempts = try await model.traces.list(sessionID: child.id, workspaceID: workspace.id)
        XCTAssertEqual(attempts.count, 1)
        let replacement = try XCTUnwrap(result["messages"]?.array?.compactMap(\.object).first { $0["role"]?.string == "user" && $0["text"]?.string?.contains("EDITED_REPLACEMENT") == true }?["id"]?.string)
        // Model a second edit while its acknowledgement is pending. Its new
        // typing must not point at the occurrence the accepted edit abandons.
        model.editMessage(replacement, sessionID: child.id)
        for _ in 0..<1000 where view.editPreparing { try await Task.sleep(for: .milliseconds(5)) }
        view.state = "idle"; view.draft = "EDITED_REPLACEMENT second edit"
        model.sendEdit(sessionID: child.id)
        view.draft = "EDITED_REPLACEMENT newer typing"
        for _ in 0..<1000 where view.editSubmitting { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(view.editingMessageID); XCTAssertNotEqual(view.editingMessageID, replacement)
        XCTAssertEqual(view.draft, "EDITED_REPLACEMENT newer typing")
        let amended = try await settled(child.id)
        XCTAssertTrue(amended["messages"]?.array?.contains { $0.object?["id"]?.string == view.editingMessageID } == true)
        model.cancelEdit(sessionID: child.id); XCTAssertEqual(view.draft, "ordinary draft")
    }
    private func fixture(_ suffix: String) -> URL {
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<4 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("fixtures/native/historical-edit-\(suffix).jsonl")
    }
    func testNativeReaderReplaysSharedGoldenBranchAndReadsFullOffWindowInput() async throws {
        let history = HistoryReader(), before = fixture("before").path, after = fixture("after").path
        let page = try await history.read(path: before, targetTurns: 3)
        XCTAssertFalse(page.messages.contains { $0.id == "u05" })
        let target = try await history.editTarget(path: before, id: "u05")
        XCTAssertEqual(target["text"]?.string, String(repeating: "Original 🌍 user text ", count: 2000))
        XCTAssertEqual(target["input"]?.object?["skills"]?.array?.first?.object?["id"]?.string, "skill")
        XCTAssertEqual(target["input"]?.object?["attachments"]?.array?.first?.object?["id"]?.string, "missing")
        let branched = try await history.read(path: after)
        let prefix = (1...4).flatMap { [String(format: "u%02d", $0), String(format: "a%02d", $0)] }
        XCTAssertNil(branched.notice); XCTAssertEqual(branched.messages.map(\.id), prefix + ["branch", "replacement", "new-answer"])
        XCTAssertEqual(branched.assistantMessageCount, 21, "Historical accounting counts original appends")
        do { _ = try await history.editTarget(path: after, id: "u05"); XCTFail("Abandoned original cannot be an edit target") } catch { }
        let replacement = try await history.editTarget(path: after, id: "replacement"); XCTAssertEqual(replacement["text"]?.string, "replacement")
    }
    func testUnsupportedBranchKeepsSourceAndExplainsCompatibilityInsteadOfSelectingItsTail() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("bad.jsonl")
        let text = try String(contentsOf: fixture("after")).replacingOccurrences(of: "\"nativeBranchVersion\":2", with: "\"nativeBranchVersion\":99")
        try text.write(to: path, atomically: true, encoding: .utf8)
        let reader = HistoryReader(), page = try await reader.read(path: path.path)
        XCTAssertTrue(page.notice?.contains("Unsupported native branch version") == true)
        XCTAssertFalse(page.messages.contains { $0.id == "replacement" })
        XCTAssertEqual(try String(contentsOf: path), text)
    }
    @MainActor func testOffWindowEditingPreservesOriginalInputsAndBlocksMissingAttachment() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage())); defer { model.shutdown() }
        let view = SessionDisplay(id: "chat"); view.draft = "ordinary unsent draft"; model.displays[view.id] = view; model.selectedID = view.id
        model.chats = [ChatRecord(id: view.id, workspaceID: "w", title: "T", path: fixture("before").path, profileID: "p", toolMode: "read-only")]
        XCTAssertTrue(view.messages.isEmpty, "No viewport source is needed")
        model.editMessage("u05", sessionID: view.id)
        while view.editPreparing { await Task.yield() }
        XCTAssertEqual(view.editingMessageID, "u05"); XCTAssertEqual(view.skills.first?.id, "skill")
        XCTAssertEqual(view.attachments.first?.id, "missing"); XCTAssertTrue(model.editBlocker(view)?.contains("attachment") == true)
        view.attachments.removeAll(); XCTAssertNil(model.editBlocker(view), "Read-only tools allow conversation editing")
        model.cancelEdit(sessionID: view.id); XCTAssertEqual(view.draft, "ordinary unsent draft")
    }
    @MainActor func testLateTargetReadCannotOverwriteNewTypingOrAnotherEdit() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage())); defer { model.shutdown() }
        let view = SessionDisplay(id: "chat"); view.draft = "first draft"; model.displays[view.id] = view
        model.chats = [ChatRecord(id: view.id, workspaceID: "w", title: "T", profileID: "p")]
        var pending: CheckedContinuation<Void, Never>?
        model.editTargetRead = { _, id in
            await withCheckedContinuation { pending = $0 }
            return ["messageId": .string(id), "text": .string("old message")]
        }
        model.editMessage("old", sessionID: view.id)
        while pending == nil { await Task.yield() }
        view.draft = "newer draft"; pending?.resume()
        while view.editPreparing { await Task.yield() }
        XCTAssertNil(view.editingMessageID); XCTAssertEqual(view.draft, "newer draft")
    }
}
