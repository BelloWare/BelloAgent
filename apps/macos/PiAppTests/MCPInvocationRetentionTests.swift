import XCTest
@testable import PiApp

@MainActor private final class MCPCommands { var frames: [[String: WireValue]] = [] }

@MainActor final class MCPInvocationRetentionTests: XCTestCase {
    private func fixture(acknowledgmentTimeout: Duration? = nil) async throws -> (WorkspaceModel, HostSupervisor, MCPCommands, URL) {
        let root = scratchRoot("mcp-retention")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        try await model.reloadConfiguration()
        let project = WorkspaceRecord(id: "project", path: root.path, trusted: true)
        model.workspaces = [project]; model.selectedWorkspaceID = project.id
        model.chats = [ChatRecord(id: "chat", workspaceID: project.id, title: "Chat", path: nil, profileID: "fixture")]
        let commands = MCPCommands(), host = HostSupervisor(commandSender: { commands.frames.append($0) }, acknowledgmentTimeout: acknowledgmentTimeout)
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

    func testDiscoveryPreservesTheHostsExistingActivityPin() async throws {
        let (model, host, commands, _) = try await fixture()
        // Discovery leaves the host's activity state to its existing owner.
        host.isBusy = true
        let request = Task { try await model.resourceRequest("mcp.list", sessionID: "chat") }
        defer { request.cancel() }
        try await wait { commands.frames.count == 1 }
        XCTAssertTrue(host.isBusy)
        try reply(commands.frames[0], on: host, result: .object(["servers": .array([])]))
        _ = try await request.value
        XCTAssertTrue(host.isBusy)
    }

    func testInspectorWorkPinsUpdateAndIdleUntilRetentionAcknowledgement() async throws {
        let (model, host, commands, _) = try await fixture()
        model.configuration.runtime.idleGraceSeconds = 0
        let request = Task { try await model.resourceRequest("mcp.invoke", params: ["server": .string("fixture"), "tool": .string("echo"), "arguments": .object([:])], sessionID: "chat") }
        defer { request.cancel() }
        try await wait { commands.frames.count == 1 }
        XCTAssertTrue(model.hasActiveWork)
        XCTAssertFalse(model.acquireUpdateBarrier(), "An Inspector invocation is active work")
        model.releaseUpdateBarrier()
        // A concurrent chat's completion re-evaluates the project activity.
        model.updateHostActivity(workspaceID: "project")
        XCTAssertTrue(host.isBusy)
        model.scheduleIdle(workspaceID: "project", host: host)
        try await Task.sleep(for: .milliseconds(80))
        guard host.isReady else { return XCTFail("Idle shutdown interrupted the Inspector invocation") }
        try reply(commands.frames[0], on: host, result: .object(["content": .array([])]))
        try await wait { commands.frames.count == 2 }
        XCTAssertTrue(model.hasActiveWork, "The saved result still awaits the helper's retention acknowledgement")
        XCTAssertFalse(model.acquireUpdateBarrier())
        model.releaseUpdateBarrier()
        try reply(commands.frames[1], on: host, result: .object(["acknowledged": .bool(true)]))
        _ = try await request.value
        XCTAssertFalse(model.hasActiveWork)
        XCTAssertTrue(model.acquireUpdateBarrier())
        model.releaseUpdateBarrier()
    }

    func testFolderChangesRefuseClosedInspectorExecutionAndPendingRetention() async throws {
        for removing in [false, true] {
            let (model, host, commands, folder) = try await fixture()
            let extra = folder.deletingLastPathComponent().appendingPathComponent("extra").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
            let project = try XCTUnwrap(model.workspaces.first)
            try await model.updateConfiguration {
                $0.workspaces = [WorkspaceRecord(id: project.id, path: project.path, trusted: true, paths: removing ? [extra.path] : [])]
            }
            model.opened.insert("chat")
            let request = Task { try await model.resourceRequest("mcp.invoke", sessionID: "chat") }
            defer { request.cancel() }
            try await wait { commands.frames.count == 1 }
            // Closing Resources cancels the caller; the dispatched work remains physical.
            request.cancel()
            func change() async throws {
                if removing { try await model.removeFolder(extra.path, from: project.id) }
                else { try await model.addFolders([extra.path], to: project.id) }
            }
            for retained in [false, true] {
                let before = model.configuration.workspaces, frameCount = commands.frames.count
                var finished = false, rejected = false
                let changing = Task {
                    defer { finished = true }
                    do { try await change() } catch { rejected = true }
                }
                try await wait { finished || commands.frames.count > frameCount }
                XCTAssertTrue(finished && rejected, "Folder admission must refuse execution and retention, retained=\(retained)")
                XCTAssertEqual(commands.frames.count, frameCount, "No session unloading before rejecting the folder change")
                XCTAssertEqual(model.configuration.workspaces, before)
                XCTAssertTrue(host.isReady); XCTAssertTrue(model.opened.contains("chat"))
                guard finished && rejected else {
                    changing.cancel()
                    if let frame = commands.frames.dropFirst(frameCount).first { try reply(frame, on: host, result: .object([:])) }
                    _ = await changing.result
                    return
                }
                if !retained {
                    try reply(commands.frames[0], on: host, result: .object(["content": .array([])]))
                    try await wait { commands.frames.count == 2 }
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
                }
            }
            try reply(commands.frames[1], on: host, result: .object(["acknowledged": .bool(true)]))
            _ = await request.result
            let changing = Task { try await change() }
            try await wait { commands.frames.count == 3 }
            XCTAssertEqual(commands.frames[2]["method"]?.string, "session.releaseDependents")
            try reply(commands.frames[2], on: host, result: .object(["released": .array([])]))
            try await wait { commands.frames.count == 4 }
            XCTAssertEqual(commands.frames[3]["method"]?.string, "session.close")
            try reply(commands.frames[3], on: host, result: .object([:]))
            try await changing.value
            XCTAssertEqual(model.workspaces.first?.paths, removing ? [] : [extra.path])
        }
    }

    func testTimedOutInvocationPinsActivityUntilItsPhysicalReplyOrHostExit() async throws {
        for lateReply in [true, false] {
            let (model, host, commands, _) = try await fixture(acknowledgmentTimeout: .seconds(1))
            model.configuration.runtime.idleGraceSeconds = 0
            let request = Task { try await model.resourceRequest("mcp.invoke", sessionID: "chat") }
            defer { request.cancel() }
            try await wait { commands.frames.count == 2 }
            let call = commands.frames[0], ack = commands.frames[1]
            XCTAssertEqual(ack["params"]?.object?["retained"]?.bool, false)
            try reply(ack, on: host, result: .object(["acknowledged": .bool(true)]))
            do { _ = try await request.value; XCTFail("The caller must still receive its timeout") } catch {}
            XCTAssertTrue(model.hasActiveWork, "A timed-out caller does not end the helper's execution")
            XCTAssertFalse(model.acquireUpdateBarrier()); model.releaseUpdateBarrier()
            model.scheduleIdle(workspaceID: "project", host: host)
            try await Task.sleep(for: .milliseconds(80))
            guard host.isReady else { return XCTFail("Idle shutdown interrupted a timed-out but outstanding invocation") }
            if lateReply { try reply(call, on: host, result: .object(["content": .array([])])) }
            else { try await host.shutdownAndWait() }
            try await wait { !model.hasActiveWork }
            XCTAssertTrue(model.acquireUpdateBarrier()); model.releaseUpdateBarrier()
        }
    }

    func testTimedOutRetentionAcknowledgementPinsActivityUntilItsPhysicalReply() async throws {
        let (model, host, commands, folder) = try await fixture(acknowledgmentTimeout: .seconds(1))
        model.configuration.runtime.idleGraceSeconds = 0
        let request = Task { try await model.resourceRequest("mcp.invoke", sessionID: "chat") }
        defer { request.cancel() }
        try await wait { commands.frames.count == 1 }
        try reply(commands.frames[0], on: host, result: .object(["content": .array([])]))
        try await wait { commands.frames.count == 2 }
        let ack = commands.frames[1]
        XCTAssertEqual(ack["params"]?.object?["retained"]?.bool, true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
        do { _ = try await request.value; XCTFail("The caller must still receive its timeout") } catch {}
        XCTAssertTrue(model.hasActiveWork)
        XCTAssertFalse(model.acquireUpdateBarrier()); model.releaseUpdateBarrier()
        model.scheduleIdle(workspaceID: "project", host: host)
        try await Task.sleep(for: .milliseconds(80))
        guard host.isReady else { return XCTFail("Idle shutdown overtook the retention acknowledgement") }
        try reply(ack, on: host, result: .object(["acknowledged": .bool(true)]))
        try await wait { !model.hasActiveWork }
    }

    func testHeldMCPCallSurvivesConcurrentChatCompletionAndIdleGrace() async throws {
        let setup = try await gatewayWorkspace("mcp-idle-wire", projectID: "mcp-idle-wire")
        let model = WorkspaceModel(stateRoot: setup.state, vault: setup.vault)
        registerWorkspaceFixtureTeardown(model, root: setup.root)
        model.automaticContextOperation = { _, _ in throw CancellationError() }
        try await model.reloadConfiguration()
        model.configuration.runtime.idleGraceSeconds = 10
        let chat = ChatRecord(id: UUID().uuidString, workspaceID: setup.workspace.id, title: "Fixture", profileID: setup.profile.id)
        model.chats = [chat]; try await model.store?.put(chat, kind: "chat", id: chat.id)
        let view = SessionDisplay(id: chat.id); model.displays[chat.id] = view
        let host = try await model.open(chat)
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let server: WireValue = .object(["command": .string("/usr/bin/python3"), "args": .array([.string(repository.appendingPathComponent("fixtures/native/mcp-server.py").path), .string(setup.root.path)]), "timeoutSeconds": .number(60)])
        _ = try await host.request("mcp.configure", params: ["config": .object(["servers": .object(["fixture": server])])])
        _ = try await host.request("turn.submit", sessionID: chat.id, params: ["clientTurnId": .string(UUID().uuidString), "text": .string("Concurrent chat")])
        let request = Task { try await model.resourceRequest("mcp.invoke", params: ["server": .string("fixture"), "tool": .string("echo"), "arguments": .object(["text": .string("Retained result")])], sessionID: chat.id) }
        defer { request.cancel(); try? Data().write(to: setup.root.appendingPathComponent("mcp-release")) }
        try await wait("MCP tools/call reached the fixture barrier") { FileManager.default.fileExists(atPath: setup.root.appendingPathComponent("mcp-arrived").path) }
        XCTAssertFalse(model.acquireUpdateBarrier())
        model.releaseUpdateBarrier()
        do { _ = try await host.request("workspace.quiesce"); XCTFail("The helper overlooked MCP execution") }
        catch HostError.rejected(let code, _) { XCTAssertTrue(["mcp_busy", "session_busy"].contains(code)) }
        try await eventually("Concurrent chat completed") {
            let status = try await host.request("session.status", sessionID: chat.id)
            return status.object?["state"]?.string == "idle"
        }
        view.state = "idle"; view.loading = false
        model.updateHostActivity(workspaceID: setup.workspace.id)
        model.scheduleIdle(workspaceID: setup.workspace.id, host: host)
        try await Task.sleep(for: .seconds(11))
        XCTAssertTrue(host.isReady, "The MCP call outlives the configured 10-second idle grace")
        try Data().write(to: setup.root.appendingPathComponent("mcp-release"))
        let result = try await request.value
        XCTAssertEqual(result["content"]?.array?.first?.object?["text"]?.string, "Retained result")
        let folder = model.root.appendingPathComponent("Workspaces/\(setup.workspace.id)/MCPResults")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let saved = try JSONDecoder().decode(WireValue.self, from: Data(contentsOf: XCTUnwrap(files.first)))
        XCTAssertEqual(saved.object?["result"], .object(result))
        let status = try await host.request("mcp.list")
        XCTAssertEqual(status.object?["outcomeUnknown"]?.bool, false)
        XCTAssertTrue(model.acquireUpdateBarrier())
        let quiet = try await host.request("workspace.quiesce")
        XCTAssertEqual(quiet.object?["quiesced"]?.bool, true)
        model.releaseUpdateBarrier()
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
