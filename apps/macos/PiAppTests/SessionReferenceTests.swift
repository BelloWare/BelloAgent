import AppKit
import XCTest
@testable import PiApp

final class SessionReferenceTests: XCTestCase {
    @MainActor private func fixture() throws -> (WorkspaceModel, URL, NSPasteboard) {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("session-reference-" + UUID().uuidString)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: state, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
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

    @MainActor func testCopyTargetsFreshArchivedRowWithoutChangingSelectionOrLoadingHistory() throws {
        let (model, root, pasteboard) = try fixture()
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
        XCTAssertTrue(model.copySessionReference(archived.id, to: pasteboard))
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

    @MainActor func testCopiedCommandReadsEntireRetainedJournalAndSafelyQuotesUnusualPath() throws {
        let (model, root, pasteboard) = try fixture()
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

        XCTAssertTrue(model.copySessionReference(item.id, to: pasteboard))
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

    @MainActor func testSavedSideForkAndImportedOriginalUseTheirOwnRetainedFiles() throws {
        let (model, root, pasteboard) = try fixture()
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
            XCTAssertTrue(model.copySessionReference(item.id, to: pasteboard))
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

    @MainActor func testEmptyChatAndPendingSideCopyIdentityWithoutInventingAFile() throws {
        let (model, root, pasteboard) = try fixture()
        let parent = chat("empty")
        model.chats = [parent]
        var pending = SideRecord(id: "pending-side", parentID: parent.id, workspaceID: "project", profileID: "profile", title: "Unsent side")
        pending.pending = true; model.sides[parent.id] = pending
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        for id in [parent.id, pending.id] {
            XCTAssertTrue(model.copySessionID(id, to: pasteboard))
            XCTAssertEqual(pasteboard.string(forType: .string), id)
            XCTAssertTrue(model.copySessionReference(id, to: pasteboard))
            let copied = try XCTUnwrap(pasteboard.string(forType: .string))
            XCTAssertTrue(copied.contains("App session ID: \(id)"))
            XCTAssertTrue(copied.contains("Conversation file: not created yet"))
            XCTAssertFalse(copied.contains("Read with Bash:")); XCTAssertFalse(copied.contains(".jsonl"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), names)
        XCTAssertTrue(model.sides[parent.id]?.pending == true); XCTAssertNil(model.record(pending.id)?.path)
        XCTAssertTrue(model.hosts.isEmpty); XCTAssertTrue(model.opened.isEmpty); XCTAssertTrue(model.displays.isEmpty)
    }

    @MainActor func testRemovedSessionPreservesAllClipboardRepresentations() throws {
        let (model, _, pasteboard) = try fixture()
        let removed = chat("removed")
        model.chats = [removed]
        XCTAssertTrue(model.copySessionID(removed.id, to: pasteboard))
        let extraType = NSPasteboard.PasteboardType("com.belloware.PiApp.tests.fixture-data")
        let extraData = Data([0, 1, 2, 255])
        pasteboard.addTypes([extraType], owner: nil)
        XCTAssertTrue(pasteboard.setData(extraData, forType: extraType))
        let changeCount = pasteboard.changeCount
        model.chats = []

        XCTAssertFalse(model.copySessionReference(removed.id, to: pasteboard))
        XCTAssertFalse(model.copySessionID(removed.id, to: pasteboard))
        XCTAssertEqual(pasteboard.changeCount, changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), removed.id)
        XCTAssertEqual(pasteboard.data(forType: extraType), extraData)
        XCTAssertNotNil(model.error); XCTAssertTrue(model.hosts.isEmpty); XCTAssertTrue(model.displays.isEmpty)
    }
}
