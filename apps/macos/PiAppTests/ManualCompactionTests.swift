import XCTest
@testable import PiApp

final class ManualCompactionTests: XCTestCase {
    @MainActor func testManualButtonsAndSlashCommandSendSelectedProfileToActualGateway() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("manual-compact-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var repo = URL(fileURLWithPath:#filePath); for _ in 0..<4 { repo.deleteLastPathComponent() }
        let server = Process(); server.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        server.arguments = [repo.appendingPathComponent("fixtures/native/manual_compaction.py").path,root.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate() } }
        let ready = root.appendingPathComponent("ready.json")
        for _ in 0..<500 where !FileManager.default.fileExists(atPath:ready.path) { try await Task.sleep(for:.milliseconds(10)) }
        let port = try XCTUnwrap(try JSONDecoder().decode([String:Int].self,from:Data(contentsOf:ready))["port"])
        let workspace = WorkspaceRecord(id:"manual",path:root.path,trusted:true)
        var profile = ProfileRecord(); profile.baseUrl = "http://127.0.0.1:\(port)/v1"; profile.modelId = "connection-default"
        profile.contextWindow = 100000; profile.maxOutputTokens = 4096
        profile.advancedJSON = #"{"reasoning":true,"thinkingLevel":"low","routing":{"replayPolicy":"portable"}}"#
        let vault = ConfigurationVault(storage:MemoryVaultStorage()), saved = profile
        _ = try await vault.update(expectedRevision:0) {
            $0.workspaces = [workspace]; $0.profiles = [.init(profile:saved,apiKey:"synthetic-manual-key")]
            $0.resources[workspace.id] = .object(["codexHome":.string(root.appendingPathComponent("empty").path),"skills":.bool(false)])
        }
        let model = WorkspaceModel(stateRoot:root.appendingPathComponent("state"),vault:vault)
        registerWorkspaceFixtureTeardown(model,root:root); try await model.reloadConfiguration()
        for id in ["menu","slash","default"] {
            var chat = ChatRecord(id:id,workspaceID:workspace.id,title:"Fixture",profileID:profile.id)
            chat.titleWasEdited = true; chat.model = "previous-model"; chat.thinkingLevel = "low"
            let view = SessionDisplay(id:id); model.chats.append(chat); model.displays[id] = view
            model.selectedID = id; model.selected = view; model.focusedSessionID = id
            let host = try await model.open(chat)
            // Two answers past pi's 20,000-token recent tail: the second is
            // kept, the first task is what compaction summarizes.
            for (turn, text) in ["Keep my original objective.", "Continue with the evidence."].enumerated() {
                view.draft = text; model.send(sessionID:id)
                for _ in 0..<1500 {
                    if !view.loading && !view.busy && view.taskPresentation?.recent.count == turn + 1 { break }
                    try await Task.sleep(for:.milliseconds(10))
                }
                XCTAssertNil(view.sendFailure); XCTAssertNil(view.failureMessage)
            }
            let index = try XCTUnwrap(model.chats.firstIndex { $0.id == id })
            model.chats[index].model = id == "default" ? nil : "chosen-" + id
            model.chats[index].thinkingLevel = id == "default" ? nil : "high"
            model.chats[index].contextWindow = id == "default" ? nil : 60000
            model.chats[index].maxOutputTokens = id == "default" ? nil : 2048
            model.chats[index].modelOutputLimit = id == "default" ? nil : 16000
            if id == "slash" { view.draft = "/compact"; view.directCommand = true; model.send(sessionID:id) }
            else { model.action("context.compact",sessionID:id) }
            // Selection is frozen synchronously even while open() awaits.
            model.chats[index].model = "changed-after-dispatch"
            var state: [String:WireValue] = [:]
            for _ in 0..<1500 {
                state = try await host.request("session.status",sessionID:id).object ?? [:]
                if state["compaction"]?.object?["phase"]?.string == "completed" { break }
                if state["state"]?.string == "error" { break }
                try await Task.sleep(for:.milliseconds(10))
            }
            XCTAssertEqual(state["compaction"]?.object?["phase"]?.string,"completed",id + ": " + String(describing:state["preflightError"]))
            XCTAssertNil(model.error)
            var attempts: [[String:WireValue]] = []
            for _ in 0..<500 {
                attempts = try await model.traces.list(sessionID:id)
                if attempts.count == 3 { break }
                try await Task.sleep(for:.milliseconds(10))
            }
            let records = try String(contentsOf:root.appendingPathComponent("records.jsonl"),encoding:.utf8).split(separator:"\n").map { try JSONDecoder().decode([String:WireValue].self,from:Data($0.utf8)) }.filter { $0["session"]?.string == id }
            XCTAssertEqual(attempts.count,3); XCTAssertEqual(records.count,3)
            XCTAssertTrue(records.allSatisfy { $0["status"]?.number == 200 })
            for attempt in attempts {
                let attemptID = try XCTUnwrap(attempt["attemptId"]?.string)
                let request = try await model.traces.completeBody(attemptID:attemptID,body:"request")
                let response = try await model.traces.completeBody(attemptID:attemptID,body:"response")
                XCTAssertTrue(records.contains { Data(base64Encoded:$0["request"]?.string ?? "") == request && Data(base64Encoded:$0["response"]?.string ?? "") == response })
            }
        }
    }
}
