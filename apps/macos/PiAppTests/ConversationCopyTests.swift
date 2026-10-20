import AppKit
import XCTest
@testable import PiApp

@MainActor final class ConversationCopyTests: XCTestCase, SerialTestLane {
    private func fixture(omitArguments: Bool = false) async throws -> (WorkspaceModel, ChatRecord, HostSupervisor, String) {
        let setup = try await gatewayWorkspace("conversation-copy", projectID: "copy")
        let model = WorkspaceModel(stateRoot: setup.state, vault: setup.vault)
        registerWorkspaceFixtureTeardown(model, root: setup.root)
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        try await model.reloadConfiguration()
        model.configuration.runtime.idleGraceSeconds = 3600
        let chat = ChatRecord(id: "copy-chat", workspaceID: "copy", title: "Copy", profileID: setup.profile.id)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        let host = try await model.open(chat)
        let item = try XCTUnwrap(model.record(chat.id)), path = try XCTUnwrap(item.path)
        _ = try await host.request("session.close", sessionID: item.id)
        model.helperSessionDidUnload(item.id)
        let records = try Data(contentsOf: URL(fileURLWithPath: path)).split(separator: 10).map { try JSONDecoder().decode(WireValue.self, from: Data($0)) }
        var call: [String: WireValue] = ["type": .string("toolCall"), "id": .string("call"), "name": .string("echo")]
        if !omitArguments { call["arguments"] = .object(["text": .string("COPY-ARGUMENT")]) }
        let message: WireValue = .object(["role": .string("assistant"), "content": .array([
            .object(["type": .string("text"), "text": .string("COPY-TEXT " + String(repeating: "🌍 retained text ", count: 4000))]),
            .object(["type": .string("thinking"), "thinking": .string("COPY-REASONING")]),
            .object(call)
        ])])
        let row: [String: WireValue] = ["type": .string("message"), "id": .string("answer"), "parentId": try XCTUnwrap(records.last?.object?["id"]), "message": message]
        try ContentSearchTests.append(JSONEncoder().encode(row) + Data([10]), to: path)
        for (id, parent, value) in [
            ("receipt", "answer", WireValue.object(["role": .string("toolResult"), "toolCallId": .string("call"), "toolName": .string("echo"), "content": .string("COPY-RESULT")])),
            ("final", "receipt", WireValue.object(["role": .string("assistant"), "content": .string("COPY-FINAL")]))
        ] {
            try ContentSearchTests.append(JSONEncoder().encode(WireValue.object(["type": .string("message"), "id": .string(id), "parentId": .string(parent), "message": value])) + Data([10]), to: path)
        }
        _ = try await model.open(item)
        return (model, item, host, ConversationContent.text(row))
    }
    private func collect(_ source: ConversationContentSource, result: ContentSearch, last: Int = 1) async throws -> String {
        var cursor: ContentCursor? = .init(index: 1, offset: 0), text = ""
        while let next = cursor {
            let page = try await source.page(1, last, next, result.revision)
            text += page.text; cursor = page.next
        }
        return text
    }
    private func retire(_ model: WorkspaceModel, chat: ChatRecord, host: HostSupervisor) async throws {
        model.configuration.runtime.idleGraceSeconds = 0
        model.scheduleIdle(workspaceID: chat.workspaceID, host: host)
        try await eventually("The idle helper retired") { !host.isReady && !model.opened.contains(chat.id) }
        try await host.shutdownAndWait()
    }
    func testLiveAndDiskCopyRetainTheSameCompleteAssistantRange() async throws {
        for omitArguments in [false, true] {
            let (model, chat, host, expected) = try await fixture(omitArguments: omitArguments)
            let live = ConversationContentSource.workspace(model, sessionID: chat.id)
            let found = try await live.search("", 0), copied = try await collect(live, result: found)
            XCTAssertEqual(copied, expected)
            for marker in ["COPY-TEXT", "COPY-REASONING", omitArguments ? "[Tool echo]\n{}" : "COPY-ARGUMENT"] {
                XCTAssertTrue(copied.contains(marker), marker)
            }
            try await retire(model, chat: chat, host: host)
            let rebound = try await collect(live, result: found)
            XCTAssertEqual(rebound, expected)
            let disk = ConversationContentSource.workspace(model, sessionID: chat.id)
            let saved = try await disk.search("", 0), diskText = try await collect(disk, result: saved)
            XCTAssertEqual(diskText, expected)
        }
    }
    func testExistingSheetCopiesAndExportsAfterIdleRetirement() async throws {
        for exporting in [false, true] {
            let (model, chat, host, expected) = try await fixture()
            let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
            let sheet = ConversationContentView(model: model, sessionID: chat.id, pasteboard: pasteboard)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: ConversationContentView.size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = sheet; window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            try await eventually("The live selection is ready") { sheet.copyAll.isEnabled }
            let destination = model.root.appendingPathComponent("export.md"), previous = PiQuestion.shared.chooseFiles
            defer { PiQuestion.shared.chooseFiles = previous }
            if exporting {
                PiQuestion.shared.chooseFiles = { [destination] }
                // The export has captured its source, but is held before its chooser.
                let gate = AsyncGate(); var arrived = false
                model.toolOutputProducerStep = { _ in arrived = true; await gate.wait() }
                sheet.exportButton.onPress?()
                try await eventually("Export is held") { arrived }
                try await retire(model, chat: chat, host: host)
                await gate.open()
            } else {
                try await retire(model, chat: chat, host: host)
                sheet.lastField.value = 1
                sheet.copyRange.onPress?()
            }
            try await eventually("Copy/export settled") { sheet.copyAll.isEnabled }
            if exporting {
                XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
                if let bytes = try? Data(contentsOf: destination) { XCTAssertEqual(String(decoding: bytes, as: UTF8.self), expected + "## toolResult\n\nCOPY-RESULT\n\n## assistant\n\nCOPY-FINAL\n\n") }
            } else { XCTAssertEqual(pasteboard.string(forType: .string), expected) }
        }
    }
    func testIdleHandoffContinuesUnicodePagesAndRejectsChangedContent() async throws {
        for change in ["none", "content", "identity"] {
            let (model, chat, host, expected) = try await fixture()
            let source = ConversationContentSource.workspace(model, sessionID: chat.id)
            let found = try await source.search("", 0)
            let first = try await source.page(1, 1, .init(index: 1, offset: 0), found.revision)
            var cursor = try XCTUnwrap(first.next), text = first.text
            try await retire(model, chat: chat, host: host)
            let path = URL(fileURLWithPath: try XCTUnwrap(chat.path))
            if change == "content" {
                let bytes = try String(contentsOf: path, encoding: .utf8)
                try bytes.replacingOccurrences(of: "COPY-TEXT", with: "EDIT-TEXT").write(to: path, atomically: true, encoding: .utf8)
            } else if change == "identity" {
                var lines: [Data] = try Data(contentsOf: path).split(separator: UInt8(10)).map { Data($0) }
                var header = try JSONDecoder().decode(WireValue.self, from: lines[0]).object!
                header["id"] = .string("different-chat")
                lines[0] = try JSONEncoder().encode(header)
                try lines.reduce(into: Data()) { $0 += $1; $0.append(10) }.write(to: path, options: .atomic)
            }
            if change != "none" {
                do { _ = try await source.page(1, 1, cursor, found.revision); XCTFail("Accepted changed \(change)") }
                catch { }
            } else {
                while true {
                    let page = try await source.page(1, 1, cursor, found.revision)
                    text += page.text
                    guard let next = page.next else { break }; cursor = next
                }
                XCTAssertEqual(text, expected, "The handoff preserves UTF-16 offsets without duplicating a prefix")
            }
        }
    }
    func testCompactionAndEditedBranchesCopyIdenticallyAfterHandoff() async throws {
        for name in ["before", "after"] {
            let (model, chat, host, _) = try await fixture()
            let path = URL(fileURLWithPath: try XCTUnwrap(chat.path))
            _ = try await host.request("session.close", sessionID: chat.id)
            model.helperSessionDidUnload(chat.id)
            let saved = try Data(contentsOf: path).split(separator: 10).map { try JSONDecoder().decode(WireValue.self, from: Data($0)) }
            let marker = try XCTUnwrap(saved.first { $0.object?["customType"]?.string == "pi-app.native.v1" }?.object?["data"])
            var repo = URL(fileURLWithPath: #filePath); for _ in 0..<4 { repo.deleteLastPathComponent() }
            let source = try Data(contentsOf: repo.appendingPathComponent("fixtures/native/historical-edit-\(name).jsonl"))
            var rows = try source.split(separator: 10).map { try JSONDecoder().decode(WireValue.self, from: Data($0)).object! }
            rows[0]["id"] = .string(chat.id); rows[1]["data"] = marker
            var bytes = Data()
            for row in rows { bytes += try JSONEncoder().encode(row); bytes.append(10) }
            try bytes.write(to: path)
            _ = try await model.open(chat)
            let reader = ConversationContentSource.workspace(model, sessionID: chat.id)
            let found = try await reader.search("", 0), live = try await collect(reader, result: found, last: found.total)
            try await retire(model, chat: chat, host: host)
            let retained = try await collect(reader, result: found, last: found.total)
            XCTAssertEqual(retained, live, "\(name): compaction/edit and user display text must use the same copy format")
        }
    }
    func testAReplacementRuntimeCannotReuseTheSelectionsSequence() async throws {
        let (model, chat, host, _) = try await fixture()
        let reader = ConversationContentSource.workspace(model, sessionID: chat.id)
        let found = try await reader.search("", 0)
        let old = try await host.request("session.content.search", sessionID: chat.id, params: ["retained": .bool(true)])
        _ = try await host.request("session.close", sessionID: chat.id)
        model.helperSessionDidUnload(chat.id)
        let path = URL(fileURLWithPath: try XCTUnwrap(chat.path))
        let text = try String(contentsOf: path, encoding: .utf8)
        try text.replacingOccurrences(of: "COPY-TEXT", with: "EDIT-TEXT").write(to: path, atomically: true, encoding: .utf8)
        _ = try await model.open(chat)
        let current = try await host.request("session.content.search", sessionID: chat.id, params: ["retained": .bool(true)])
        XCTAssertEqual(old.object?["revision"], current.object?["revision"], "The replacement deliberately reuses counts and sequence")
        XCTAssertNotEqual(old.object?["incarnation"], current.object?["incarnation"])
        do { _ = try await collect(reader, result: found); XCTFail("A replacement runtime lent new content to the old selection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("History changed"), error.localizedDescription) }
    }
    func testCopySheetGallery() async throws {
        guard let folder = testEnvironment("PI_APP_CONVERSATION_COPY_GALLERY"), !folder.isEmpty else { throw XCTSkip("Set PI_APP_CONVERSATION_COPY_GALLERY to render copy sheets") }
        let (model, chat, _, _) = try await fixture()
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for (name, width, appearance) in [("light", 1080.0, NSAppearance.Name.aqua), ("dark", 1080.0, .darkAqua), ("narrow", 900.0, .aqua)] {
            let size = NSSize(width: width, height: 700), sheet = ConversationContentView(model: model, sessionID: chat.id)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance)
            window.contentView = sheet; window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            try await eventually("The gallery selection is ready") { sheet.copyAll.isEnabled }
            if window.firstResponder is NSText { window.makeFirstResponder(nil) }
            var previous: Data?, image: Data?
            try await eventually("The gallery frame has settled", poll: .milliseconds(60)) {
                sheet.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
                guard let data = try? PiKitParity.windowImage(window).representation(using: .png, properties: [:]) else { return false }
                defer { previous = data }
                guard data == previous else { return false }
                image = data; return true
            }
            try XCTUnwrap(image).write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }
}
