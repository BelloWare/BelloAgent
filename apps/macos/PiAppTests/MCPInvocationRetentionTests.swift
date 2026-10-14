import XCTest
@testable import PiApp

@MainActor private final class MCPCommands { var frames: [[String: WireValue]] = [] }

@MainActor final class MCPInvocationRetentionTests: XCTestCase {
    private func fixture() async throws -> (WorkspaceModel, HostSupervisor, MCPCommands, URL) {
        let root = scratchRoot("mcp-retention")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        let project = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        model.workspaces = [project]; model.selectedWorkspaceID = project.id
        model.chats = [ChatRecord(id: "chat", workspaceID: project.id, title: "Chat", path: nil, profileID: "fixture")]
        let commands = MCPCommands(), host = HostSupervisor(commandSender: { commands.frames.append($0) })
        try await host.connect(cwd: root, state: model.root.appendingPathComponent("Workspaces/project"))
        model.hosts[project.id] = host; model.boundHostConnections[project.id] = host.connectionID
        return (model, host, commands, model.root.appendingPathComponent("Workspaces/project/MCPResults"))
    }
    private func wait(_ what: String = "The Inspector request reached its retention boundary",
                      file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () -> Bool) async throws {
        try await eventually(what, timeout: .seconds(60), file: file, line: line, condition)
    }
    private func reply(_ frame: [String: WireValue], on host: HostSupervisor, result: WireValue) throws {
        host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(try XCTUnwrap(host.epoch)),
            "commandId": try XCTUnwrap(frame["commandId"]), "ok": .bool(true), "result": result]), connectionID: try XCTUnwrap(host.connectionID))
    }

    func testTheInspectorAcknowledgesOnlyAfterTheCompleteResultIsSaved() async throws {
        let (model, host, commands, folder) = try await fixture()
        var done = false
        let request = Task { defer { done = true }; return try await model.resourceRequest("mcp.invoke", params: ["server": .string("fixture"), "tool": .string("echo"), "arguments": .object([:])], sessionID: "chat") }
        defer { request.cancel() }
        try await wait("The Inspector invocation was dispatched") { commands.frames.count == 1 }
        let call = commands.frames[0], id = try XCTUnwrap(call["commandId"]?.string)
        let file = folder.appendingPathComponent(id + ".json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let result: WireValue = .object(["content": .array([.object(["type": .string("text"), "text": .string(String(repeating: "remote effect completed\n", count: 12_000))])]), "isError": .bool(false)])
        let bytes = try JSONEncoder().encode(result), transfer = UUID().uuidString
        try reply(call, on: host, result: .object(["_displayTransfer": .number(1), "id": .string(transfer), "bytes": .number(Double(bytes.count))]))
        var offset = 0, frameCount = 1
        while offset < bytes.count {
            frameCount += 1
            try await wait { commands.frames.count == frameCount }
            let page = commands.frames[frameCount - 1], end = min(bytes.count, offset + 192 * 1024)
            XCTAssertEqual(page["method"]?.string, "display.result.read")
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "A display-transfer descriptor or prefix is not the result")
            try reply(page, on: host, result: .object(["offset": .number(Double(offset)), "totalBytes": .number(Double(bytes.count)),
                "data": .string(bytes.subdata(in: offset..<end).base64EncodedString()), "next": end == bytes.count ? .null : .number(Double(end))]))
            offset = end
        }
        try await wait { done || commands.frames.count == frameCount + 1 }
        guard commands.frames.count == frameCount + 1 else { _ = await request.result; return XCTFail("Returning the result without a durable-retention ACK loses the crash protection") }
        let ack = commands.frames[frameCount]
        XCTAssertEqual(ack["method"]?.string, "mcp.resultRetained")
        XCTAssertEqual(ack["params"]?.object?["commandId"]?.string, id)
        XCTAssertEqual(ack["params"]?.object?["retained"]?.bool, true)
        let saved = try JSONDecoder().decode(WireValue.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.object?["result"], result)
        XCTAssertEqual(saved.object?["sessionId"]?.string, "chat")
        XCTAssertEqual(saved.object?["hostEpoch"]?.string, host.epoch)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(done, "The app waits for the helper to accept the retention acknowledgement")
        try reply(ack, on: host, result: .object(["acknowledged": .bool(true)]))
        let received = try await request.value
        XCTAssertEqual(WireValue.object(received), result)
    }

    func testAFailedSaveReportsLostRetentionAndNeverAcknowledgesSuccess() async throws {
        let (model, host, commands, folder) = try await fixture()
        try Data("not a directory".utf8).write(to: folder)
        var done = false
        let request = Task { defer { done = true }; return try await model.resourceRequest("mcp.invoke", params: ["server": .string("fixture"), "tool": .string("echo"), "arguments": .object([:])], sessionID: "chat") }
        defer { request.cancel() }
        try await wait("The Inspector invocation was dispatched") { commands.frames.count == 1 }
        try reply(commands.frames[0], on: host, result: .object(["content": .array([])]))
        try await wait("The failed save reported lost retention to the helper") { done || commands.frames.count == 2 }
        if commands.frames.count == 2 {
            let ack = commands.frames[1]
            XCTAssertEqual(ack["method"]?.string, "mcp.resultRetained")
            XCTAssertEqual(ack["params"]?.object?["retained"]?.bool, false)
            try reply(ack, on: host, result: .object(["acknowledged": .bool(true)]))
        } else { XCTFail("A failed app save must leave the invocation unknown in the running helper too") }
        do { _ = try await request.value; XCTFail("The app must report the save failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unknown"), error.localizedDescription) }
    }

    func testClosingTheInspectorAfterDispatchStillRetainsTheAnsweredCall() async throws {
        let (model, host, commands, folder) = try await fixture()
        var done = false
        let request = Task { defer { done = true }; return try await model.resourceRequest("mcp.invoke", params: ["server": .string("fixture"), "tool": .string("echo"), "arguments": .object([:])], sessionID: "chat") }
        defer { request.cancel() }
        try await wait("The Inspector invocation was dispatched") { commands.frames.count == 1 }
        request.cancel()
        let result: WireValue = .object(["content": .array([])])
        try reply(commands.frames[0], on: host, result: result)
        try await wait { done || commands.frames.count == 2 }
        guard commands.frames.count == 2 else { _ = await request.result; return XCTFail("A closed sheet must not strand a completed result awaiting retention") }
        let ack = commands.frames[1], id = try XCTUnwrap(commands.frames[0]["commandId"]?.string)
        XCTAssertEqual(ack["params"]?.object?["retained"]?.bool, true)
        let saved = try JSONDecoder().decode(WireValue.self, from: Data(contentsOf: folder.appendingPathComponent(id + ".json")))
        XCTAssertEqual(saved.object?["result"], result)
        try reply(ack, on: host, result: .object(["acknowledged": .bool(true)]))
        _ = await request.result
    }

    func testAnIncompleteDisplayTransferReportsLostRetention() async throws {
        let (model, host, commands, folder) = try await fixture()
        var done = false
        let request = Task { defer { done = true }; return try await model.resourceRequest("mcp.invoke", params: ["server": .string("fixture"), "tool": .string("echo"), "arguments": .object([:])], sessionID: "chat") }
        defer { request.cancel() }
        try await wait("The Inspector invocation was dispatched") { commands.frames.count == 1 }
        try reply(commands.frames[0], on: host, result: .object(["_displayTransfer": .number(1), "id": .string(UUID().uuidString), "bytes": .number(10)]))
        try await wait { commands.frames.count == 2 }
        try reply(commands.frames[1], on: host, result: .object(["offset": .number(0), "totalBytes": .number(10), "data": .string("not base64"), "next": .null]))
        try await wait { done || commands.frames.count == 3 }
        if commands.frames.count == 3 {
            let ack = commands.frames[2]
            XCTAssertEqual(ack["method"]?.string, "mcp.resultRetained")
            XCTAssertEqual(ack["params"]?.object?["retained"]?.bool, false)
            try reply(ack, on: host, result: .object(["acknowledged": .bool(true)]))
        } else { XCTFail("A reply the app cannot reconstruct must remain unknown, not pending forever") }
        do { _ = try await request.value; XCTFail("An incomplete reply cannot be returned") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
}
