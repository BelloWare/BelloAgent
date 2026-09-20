import AppKit
import XCTest
@testable import PiApp

final class SessionReferenceTests: XCTestCase {
    @MainActor private func fixture() async throws -> (WorkspaceModel, URL, NSPasteboard) {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("session-reference-" + UUID().uuidString)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: state, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.traces.configure(quota: 1_048_576, bodyRetention: 86400, metricRetention: 86400)
        let pasteboard = NSPasteboard(name: .init("com.belloware.PiApp.tests.session-reference." + UUID().uuidString))
        pasteboard.clearContents()
        addTeardownBlock { @MainActor in pasteboard.releaseGlobally() }
        return (model, root, pasteboard)
    }

    private func chat(_ id: String, path: URL? = nil) -> ChatRecord {
        ChatRecord(id: id, workspaceID: "project", title: id, path: path?.path, profileID: "profile")
    }

    private func readCommand(_ reference: String) throws -> String {
        let start = try XCTUnwrap(reference.range(of: "Read with Bash:\n")).upperBound
        let end = try XCTUnwrap(reference.range(of: "\n\n", range: start..<reference.endIndex)).lowerBound
        return String(reference[start..<end])
    }

    /// Execute the copied command itself, so quoting is verified by Bash rather
    /// than by a second implementation of the production escaping rule.
    private func runReadCommand(_ reference: String, in root: URL) throws -> Data {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-c", try readCommand(reference)]
        process.currentDirectoryURL = root
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: error, as: UTF8.self))
        XCTAssertTrue(error.isEmpty, String(decoding: error, as: UTF8.self))
        return data
    }

    @MainActor func testCopyTargetsFreshArchivedRowWithoutChangingSelectionOrLoadingHistory() async throws {
        let (model, root, pasteboard) = try await fixture()
        let selected = chat("selected")
        var archived = chat("background", path: root.appendingPathComponent("old.jsonl"))
        archived.archivedAt = Date(timeIntervalSince1970: 1)
        model.chats = [selected, archived]
        let display = SessionDisplay(id: selected.id)
        display.draft = "Keep this unsent draft"
        display.messages = [.init(id: "visible", role: "user", text: "Keep this transcript")]
        model.displays[selected.id] = display
        model.selectedID = selected.id; model.selected = display; model.focusedSessionID = selected.id
        model.selectedWorkspaceID = selected.workspaceID

        // The menu could have been opened before a journal was assigned or a
        // title changed. Resolve the clicked ID from current records on action.
        let newestPath = root.appendingPathComponent("retained new journal.jsonl")
        model.chats[1].path = newestPath.path; model.chats[1].title = "Renamed in background"
        XCTAssertTrue(model.copySessionID(archived.id, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), archived.id)
        let didCopyReference = await model.copySessionReference(archived.id, to: pasteboard)
        XCTAssertTrue(didCopyReference)
        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(copied.contains("App session ID: background"))
        XCTAssertTrue(copied.contains("Title: Renamed in background"))
        XCTAssertTrue(copied.contains(newestPath.path)); XCTAssertFalse(copied.contains("old.jsonl"))
        XCTAssertEqual(model.selectedID, selected.id); XCTAssertEqual(model.focusedSessionID, selected.id)
        XCTAssertEqual(model.selectedWorkspaceID, selected.workspaceID); XCTAssertTrue(model.selected === display)
        XCTAssertEqual(display.draft, "Keep this unsent draft"); XCTAssertEqual(display.messages.map(\.id), ["visible"])
        XCTAssertEqual(Set(model.displays.keys), [selected.id]); XCTAssertTrue(model.hosts.isEmpty); XCTAssertTrue(model.opened.isEmpty)
        XCTAssertFalse(display.loading); XCTAssertFalse(model.showArchivedSessions)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newestPath.path), "Copying must not create or load a journal")
    }

    @MainActor func testCopiedCommandReadsEntireRetainedJournalAndSafelyQuotesUnusualPath() async throws {
        let (model, root, pasteboard) = try await fixture()
        let path = root.appendingPathComponent("saved space O'Brien $fixture `printf harmless`\nline.jsonl")
        var bytes = Data()
        func append(_ value: [String: WireValue]) throws {
            bytes.append(try JSONEncoder().encode(value)); bytes.append(10)
        }
        try append(["type": .string("session"), "version": .number(3), "id": .string("retained")])
        for index in 0..<125 {
            let role = index == 61 ? "toolResult" : index % 2 == 0 ? "user" : "assistant"
            try append(["type": .string("message"), "id": .string("m\(index)"),
                        "parentId": index == 0 ? .null : .string("m\(index - 1)"),
                        "message": .object(["role": .string(role), "content": .array([
                            .object(["type": .string("text"), "text": .string("Complete retained content \(index)")])
                        ])])])
        }
        try append(["type": .string("branch"), "id": .string("edit"), "parentId": .string("m124"),
                    "fromMessageId": .string("m120"), "keptIds": .array((0..<120).map { .string("m\($0)") })])
        try append(["type": .string("compaction"), "id": .string("compact"), "parentId": .string("edit"),
                    "summary": .string("Retained compaction summary"), "nativeKeptIDs": .array([.string("m119")])])
        try bytes.write(to: path)
        let originalDate = try FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date
        let originalNames = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let item = chat("retained", path: path), display = SessionDisplay(id: "retained")
        display.messages = (65..<125).map { .init(id: "m\($0)", role: "assistant", text: "Visible preview \($0)") }
        model.chats = [item]; model.displays[item.id] = display

        let didCopyReference = await model.copySessionReference(item.id, to: pasteboard)

        XCTAssertTrue(didCopyReference)
        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        let read = try runReadCommand(copied, in: root)
        XCTAssertEqual(read, bytes, "A reference must expose the whole durable file, including rows outside the visible60")
        XCTAssertTrue(String(decoding: read, as: UTF8.self).contains("Complete retained content 0"))
        XCTAssertTrue(String(decoding: read, as: UTF8.self).contains("Retained compaction summary"))
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date, originalDate)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), originalNames)
        XCTAssertEqual(display.messages.count, 60); XCTAssertEqual(display.messages.first?.id, "m65")
        XCTAssertTrue(model.hosts.isEmpty); XCTAssertTrue(model.opened.isEmpty)
    }

    @MainActor func testSavedSideForkAndImportedOriginalUseTheirOwnRetainedFiles() async throws {
        let (model, root, pasteboard) = try await fixture()
        let parent = chat("parent")
        var side = chat("side", path: root.appendingPathComponent("side_side.jsonl")); side.parentSessionID = parent.id
        let fork = chat("fork", path: root.appendingPathComponent("fork_fork.jsonl"))
        var imported = chat("import-app-id", path: root.appendingPathComponent("original external.jsonl")); imported.imported = true
        model.chats = [parent, side, fork, imported]
        // The on-screen side projection has no path. Its saved ChatRecord must
        // win, even while another conversation is focused.
        var panel = SideRecord(id: side.id, parentID: parent.id, workspaceID: "project", profileID: "profile", title: "Side")
        panel.kept = true; model.sides[parent.id] = panel
        model.selectedID = parent.id; model.focusedSessionID = parent.id

        for item in [side, fork, imported] {
            let headerID = item.imported ? "external-original-id" : item.id
            let original = Data("{\"type\":\"session\",\"version\":3,\"id\":\"\(headerID)\"}\n".utf8)
            try original.write(to: URL(fileURLWithPath: try XCTUnwrap(item.path)))
            XCTAssertTrue(model.copySessionID(item.id, to: pasteboard))
            XCTAssertEqual(pasteboard.string(forType: .string), item.id)
            let didCopyReference = await model.copySessionReference(item.id, to: pasteboard)
            XCTAssertTrue(didCopyReference)
            let copied = try XCTUnwrap(pasteboard.string(forType: .string))
            XCTAssertEqual(try runReadCommand(copied, in: root), original)
            if item.id == side.id { XCTAssertTrue(copied.contains("Parent session ID: parent")) }
            if item.id == fork.id { XCTAssertFalse(copied.contains("Parent session ID:")) }
            if item.imported {
                XCTAssertTrue(copied.contains("App session ID: import-app-id"))
                XCTAssertTrue(copied.contains("may differ from the session ID in the file header"))
            }
        }
        XCTAssertEqual(model.selectedID, parent.id); XCTAssertEqual(model.focusedSessionID, parent.id)
        XCTAssertTrue(model.displays.isEmpty); XCTAssertTrue(model.hosts.isEmpty); XCTAssertTrue(model.opened.isEmpty)
    }

    @MainActor func testEmptyChatAndPendingSideCopyIdentityWithoutInventingAFile() async throws {
        let (model, root, pasteboard) = try await fixture()
        let parent = chat("empty")
        model.chats = [parent]
        var pending = SideRecord(id: "pending-side", parentID: parent.id, workspaceID: "project", profileID: "profile", title: "Unsent side")
        pending.pending = true; model.sides[parent.id] = pending
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        for id in [parent.id, pending.id] {
            XCTAssertTrue(model.copySessionID(id, to: pasteboard))
            XCTAssertEqual(pasteboard.string(forType: .string), id)
            let didCopyReference = await model.copySessionReference(id, to: pasteboard)
            XCTAssertTrue(didCopyReference)
            let copied = try XCTUnwrap(pasteboard.string(forType: .string))
            XCTAssertTrue(copied.contains("App session ID: \(id)"))
            XCTAssertTrue(copied.contains("Conversation file: not created yet"))
            XCTAssertFalse(copied.contains("Read with Bash:")); XCTAssertFalse(copied.contains(".jsonl"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), names)
        XCTAssertTrue(model.sides[parent.id]?.pending == true); XCTAssertNil(model.record(pending.id)?.path)
        XCTAssertTrue(model.hosts.isEmpty); XCTAssertTrue(model.opened.isEmpty); XCTAssertTrue(model.displays.isEmpty)
    }

    @MainActor func testRemovedSessionPreservesAllClipboardRepresentations() async throws {
        let (model, _, pasteboard) = try await fixture()
        let removed = chat("removed")
        model.chats = [removed]
        XCTAssertTrue(model.copySessionID(removed.id, to: pasteboard))
        let extraType = NSPasteboard.PasteboardType("com.belloware.PiApp.tests.fixture-data")
        let extraData = Data([0, 1, 2, 255])
        pasteboard.addTypes([extraType], owner: nil)
        XCTAssertTrue(pasteboard.setData(extraData, forType: extraType))
        let changeCount = pasteboard.changeCount
        model.chats = []

        let didCopyReference = await model.copySessionReference(removed.id, to: pasteboard)

        XCTAssertFalse(didCopyReference)
        XCTAssertFalse(model.copySessionID(removed.id, to: pasteboard))
        XCTAssertEqual(pasteboard.changeCount, changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), removed.id)
        XCTAssertEqual(pasteboard.data(forType: extraType), extraData)
        XCTAssertNotNil(model.error); XCTAssertTrue(model.hosts.isEmpty); XCTAssertTrue(model.displays.isEmpty)
    }

    @MainActor private func saveUsage(_ model: WorkspaceModel, session: String, project: String = "project", input: Double = 38,
                                     output: Double = 302, cost: Double? = 0.0013875) async throws {
        let wall = Date().timeIntervalSince1970
        let metadata: [String: WireValue] = [
            "attemptId": .string(UUID().uuidString), "sessionId": .string(session), "turnId": .string("turn"),
            "api": .string("openai-responses"), "requestedModel": .string("router"), "purpose": .string("turn"),
            "mode": .string("off"), "outcome": .string("completed"),
            "wallTimestamp": .number(wall), "dispatchWallTimestamp": .number(wall),
            "timingVersion": .number(2), "timings": .object(["dispatch": .number(100), "firstContent": .number(110), "modelComplete": .number(120), "httpEnd": .number(130)]),
            "outputMessageIds": .array([.string("inherited-output")]),
            "usage": .object(["inputIncludingCache": .number(input), "output": .number(output), "cacheRead": .number(0), "reasoning": .number(min(253, output))]),
            "gateway": .object(["version": .number(1),
                "cost": .object(["status": .string(cost == nil ? "unreported" : "reported"), "usd": cost.map(WireValue.number) ?? .null]),
                "costBreakdown": .object(["reasoning": .object(["status": .string(cost == nil ? "unreported" : "reported"), "usd": cost.map { .number(min($0, 0.0011385)) } ?? .null])])])
        ]
        try await model.traces.begin(metadata, workspace: project)
        try await model.traces.finish(metadata)
    }

    @MainActor func testSingleCopyReadsFreshRetainedUsageWithoutOpeningTheChat() async throws {
        let (model, root, pasteboard) = try await fixture()
        model.chats = [chat("cold", path: root.appendingPathComponent("cold.jsonl"))]
        model.publishChatStats(GatewayTotals(requests: 1, costSamples: 1, costUSD: 999), sessionID: "cold")
        try await saveUsage(model, session: "cold")
        let copied = await model.copySessionReference("cold", to: pasteboard)
        XCTAssertTrue(copied)
        let reference = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(reference.contains("Total tokens (input + output): 340 (1/1 requests reported)"))
        XCTAssertTrue(reference.contains("Input tokens (includes cache): 38"))
        XCTAssertTrue(reference.contains("Output tokens (includes reasoning): 302"))
        XCTAssertTrue(reference.contains("Cached input tokens: 0 (1/1 requests reported)"))
        XCTAssertTrue(reference.contains("Reasoning tokens (part of output): 253"))
        XCTAssertTrue(reference.contains("Reported cost: $0.0013875 USD (1/1 requests reported)"))
        XCTAssertTrue(reference.contains("Reasoning cost (part of reported cost): $0.0011385 USD"))
        XCTAssertFalse(reference.contains("$999")); XCTAssertTrue(model.displays.isEmpty)
        XCTAssertTrue(model.hosts.isEmpty); XCTAssertTrue(model.opened.isEmpty)
    }

    @MainActor func testCopyMarkedReferencesUsesSidebarOrderKeepsSelectionAndScopesEachUsage() async throws {
        let (model, root, pasteboard) = try await fixture()
        var first = chat("first", path: root.appendingPathComponent("one.jsonl")); first.sidebarOrder = 20
        var second = chat("second", path: root.appendingPathComponent("two.jsonl")); second.sidebarOrder = 10
        model.chats = [second, first]
        model.workspaces = [WorkspaceRecord(id: "project", path: root.path, trusted: true)]
        model.selectedID = first.id
        model.extendSessionMarks(to: second.id)
        XCTAssertEqual(model.markedChats.map(\.id), ["first", "second"])
        try await saveUsage(model, session: first.id, input: 100, output: 20, cost: 1.5)
        try await saveUsage(model, session: second.id, input: 10, output: 3, cost: 0)
        // Same app ID in another project and common inherited message links
        // must not contaminate either reference's own request accounting.
        try await saveUsage(model, session: first.id, project: "different-project", input: 9999, output: 9999, cost: 999)
        let copied = await model.copyMarkedSessionReferences(to: pasteboard)
        XCTAssertTrue(copied)
        let text = try XCTUnwrap(pasteboard.string(forType: .string))
        let parts = text.components(separatedBy: "\n\n---\n\n")
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts[0].contains("App session ID: first")); XCTAssertTrue(parts[0].contains("Total tokens (input + output): 120"))
        XCTAssertTrue(parts[0].contains("Reported cost: $1.5 USD")); XCTAssertTrue(parts[0].contains("one.jsonl"))
        XCTAssertTrue(parts[1].contains("App session ID: second")); XCTAssertTrue(parts[1].contains("Total tokens (input + output): 13"))
        XCTAssertTrue(parts[1].contains("Reported cost: $0 USD (1/1 requests reported)")); XCTAssertTrue(parts[1].contains("two.jsonl"))
        XCTAssertFalse(text.contains("$999"))
        XCTAssertEqual(model.markedSessionIDs, ["first", "second"]); XCTAssertEqual(model.selectedID, first.id)
        XCTAssertTrue(model.hosts.isEmpty); XCTAssertTrue(model.displays.isEmpty)
    }

    func testReferenceDistinguishesPartialMissingAndExpiredAccountingFromZero() {
        var totals = GatewayTotals(requests: 3, costSamples: 1, costUSD: 0, cacheReadTokens: 8000, cacheReadSamples: 1, expiredRecords: 2)
        totals.tokens = GatewayTokenTotals(input: 10000, output: 2000, total: 12000, inputSamples: 1, outputSamples: 1, samples: 1, reasoning: 1500, reasoningSamples: 1)
        let reference = SessionReference(chat: chat("partial"), usage: totals).text
        XCTAssertTrue(reference.contains("Total tokens (input + output): 12000 (1/3 requests reported)"))
        XCTAssertTrue(reference.contains("Cached input tokens: 8000 (1/3 requests reported)"))
        XCTAssertTrue(reference.contains("Reported cost: $0 USD (1/3 requests reported)"))
        XCTAssertTrue(reference.contains("Expired request records excluded: 2"))
        XCTAssertTrue(reference.contains("Reasoning cost (part of reported cost): not reported"))
        let missing = SessionReference(chat: chat("missing")).text
        XCTAssertTrue(missing.contains("Total tokens (input + output): not reported"))
        XCTAssertTrue(missing.contains("Reported cost: not reported")); XCTAssertFalse(missing.contains("$0"))
    }

    @MainActor func testReferenceQueryHandlesMaximumSelectionAndIncludesOnlyRequestedScopes() async throws {
        let (model, _, _) = try await fixture()
        let scopes = (0..<500).map { SessionUsageScope(sessionID: "chat\($0)", workspaceID: "project") }
        for index in [0, 200, 499] { try await saveUsage(model, session: "chat\(index)") }
        try await saveUsage(model, session: "chat200", project: "other", cost: 900)
        try await saveUsage(model, session: "unselected", cost: 999)
        let totals = try await model.traces.sessionReferenceTotals(scopes: scopes)
        XCTAssertEqual(totals.count, 500)
        XCTAssertEqual(totals[scopes[0]]?.requests, 1); XCTAssertEqual(totals[scopes[200]]?.costUSD, 0.0013875)
        XCTAssertEqual(totals[scopes[499]]?.tokens?.total, 340)
        XCTAssertEqual(totals[scopes[1]]?.requests, 0); XCTAssertNil(totals[scopes[1]]?.costUSD)
        do {
            _ = try await model.traces.sessionReferenceTotals(scopes: scopes + [scopes[0]])
            XCTFail("A selection above the bound must fail rather than truncate")
        } catch { }
    }

    @MainActor func testPendingReferenceCannotReplaceANewerClipboardCopy() async throws {
        let (model, _, pasteboard) = try await fixture()
        model.chats = [chat("first"), chat("second")]
        for external in [false, true] {
            let copied = await model.copySessionReferences(["first"], to: pasteboard) { _ in
                await Task.yield()
                if external { pasteboard.clearContents(); pasteboard.setString("external copy", forType: .string) }
                else { XCTAssertTrue(model.copySessionID("second", to: pasteboard)) }
                return [:]
            }
            XCTAssertFalse(copied)
            XCTAssertEqual(pasteboard.string(forType: .string), external ? "external copy" : "second")
        }
    }

    @MainActor func testDeletedMemberAndUnavailableAccountingLeaveClipboardIntact() async throws {
        let (model, _, pasteboard) = try await fixture()
        model.chats = [chat("first"), chat("second")]
        pasteboard.setString("keep me", forType: .string)
        let before = pasteboard.changeCount
        let deleted = await model.copySessionReferences(["first", "second"], to: pasteboard) { _ in
            await Task.yield(); model.chats.removeAll { $0.id == "second" }; return [:]
        }
        XCTAssertFalse(deleted); XCTAssertEqual(pasteboard.changeCount, before)
        let unavailable = await model.copySessionReferences(["first"], to: pasteboard) { _ in throw CaptureFailure.unavailable }
        XCTAssertFalse(unavailable); XCTAssertEqual(pasteboard.changeCount, before)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me"); XCTAssertNotNil(model.error)
    }
}
