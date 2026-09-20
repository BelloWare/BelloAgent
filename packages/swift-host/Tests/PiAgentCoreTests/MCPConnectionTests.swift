import XCTest
@testable import PiAgentCore

/// MCP servers: discovery and serial invocation, an unknown outcome that
/// survives a restart, and the configurations that are refused outright.
final class MCPConnectionTests: XCTestCase {
    func testMCPListDescribeSerialInvokeAndUnknownOutcome() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let manager=MCPManager(cwd:root),transport=FakeMCP();await manager.installForTesting(name:"test",transport:transport)
        let list=try await manager.perform(["action":"list","server":"test"])
        XCTAssertTrue(list["tools"].list[0]["inputSchema"].isNull)
        let schema=try await manager.perform(["action":"describe","targets":[["server":"test","tool":"echo"],["server":"test","tool":"echo"]]])
        XCTAssertEqual(schema["tools"].list.count,2);XCTAssertEqual(schema["tools"].list[0]["schema"]["inputSchema"]["type"].text,"object")
        try await withThrowingTaskGroup(of:JSON.self) { group in
            for i in 0..<5 { group.addTask { try await manager.perform(["action":"invoke","server":"test","tool":"echo","arguments":["text":JSON(String(i))]]) } }
            for try await _ in group {}
        }
        let maximum=await transport.maximum;XCTAssertEqual(maximum,1)
        do { _ = try await manager.perform(["action":"invoke","server":"test","tool":"echo","arguments":[:]],readOnly:true);XCTFail("Readonly invocation accepted") } catch {}
        do { _ = try await manager.perform(["action":"invoke","targets":[]]);XCTFail("Batch accepted") } catch {}
        await transport.failNext()
        do { _ = try await manager.perform(["action":"invoke","server":"test","tool":"echo","arguments":[:]]);XCTFail("Failure expected") } catch {}
        do { _ = try await manager.perform(["action":"invoke","server":"test","tool":"echo","arguments":[:]]);XCTFail("Unknown outcome did not quarantine") } catch { XCTAssertEqual((error as? AgentError)?.code,"mcp_outcome_unknown") }
        try await manager.acknowledgeUnknown()
        _ = try await manager.perform(["action":"invoke","server":"test","tool":"echo","arguments":[:]])
    }
    func testMCPUnknownOutcomeSurvivesManagerRestart() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let marker=folder.appendingPathComponent("unknown.json"),first=MCPManager(cwd:folder,outcomeMarker:marker),transport=FakeMCP()
        await first.installForTesting(name:"test",transport:transport);await transport.failNext()
        do { _=try await first.perform(["action":"invoke","server":"test","tool":"echo","arguments":[:]]);XCTFail("Expected transport failure") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path))
        let second=MCPManager(cwd:folder,outcomeMarker:marker);await second.installForTesting(name:"test",transport:FakeMCP())
        let list=try await second.perform(["action":"list"]);XCTAssertEqual(list["outcomeUnknown"].flag,true)
        do { _=try await second.perform(["action":"invoke","server":"test","tool":"echo","arguments":[:]]);XCTFail("Must remain blocked") }
        catch let error as AgentError { XCTAssertEqual(error.code,"mcp_outcome_unknown") }
        try await second.acknowledgeUnknown();XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
        _=try await second.perform(["action":"invoke","server":"test","tool":"echo","arguments":["text":"once"]])
        XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
    }
    func testMCPConfigurationComesFromPrivateIPCAndRejectsExternalFiles() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let file=folder.appendingPathComponent("mcp.json"),initial=Data("{\"servers\":{}}".utf8)
        try initial.write(to:file)
        let host=NativeHostService(emit:{_ in})
        _=try await host.command("workspace.open",sessionID:nil,params:["cwd":JSON(folder.path),"directory":JSON(folder.appendingPathComponent("state").path),"mcp":["servers":[:]]])
        do { _=try await host.command("mcp.configure",sessionID:nil,params:["path":JSON(file.path)]); XCTFail("External files must be rejected") }
        catch { XCTAssertEqual((error as? AgentError)?.code, "vault_configuration_required") }
        let approved=try await host.command("mcp.configure",sessionID:nil,params:["config":["servers":[:]]])
        XCTAssertEqual(approved["configurationSource"].text,"native vault via private IPC")
        XCTAssertEqual(try Data(contentsOf:file),initial);await host.shutdown()
    }
    func testMCPConfigurationRejectsHeaderInjectionAndAmbiguousTransports() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let manager = MCPManager(cwd: root)
        for config: JSON in [
            ["url": "https://gateway.example/mcp", "headers": ["x-test": "ok\r\ninjected"]],
            ["url": "https://gateway.example/mcp", "headers": ["Transfer-Encoding": "chunked"]],
            ["command": "/usr/bin/true", "env": ["INVALID=KEY": "value"]],
            ["transport": "stdio", "command": "/usr/bin/true", "url": "https://gateway.example/mcp"]
        ] {
            do { try await manager.configure(["servers": ["fixture": config]]); XCTFail("Invalid explicit configuration must fail before connecting") } catch { }
        }
        let names = await manager.serverNames(); XCTAssertTrue(names.isEmpty)
    }
}
