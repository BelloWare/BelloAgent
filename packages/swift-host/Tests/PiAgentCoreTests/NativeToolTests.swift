import XCTest
@testable import PiAgentCore

/// The built-in tools: what they return to the model, and what happens to a
/// command that outlives its deadline while a child still holds the pipes.
final class NativeToolTests: XCTestCase {
    func testNativeShellAndFileTools() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let tools=NativeTools(cwd:root,outputs:root.appendingPathComponent("out"),mcp:MCPManager(cwd:root))
        let written = try await tools.invoke(ToolCall(id:"w",name:"write",arguments:["path":"file.txt","content":"abc"]),readOnly:false)
        XCTAssertEqual(written["stats"]["added"].int, 1); XCTAssertEqual(written["stats"]["removed"].int, 0)
        XCTAssertEqual(written["stats"]["path"].text, root.resolvingSymlinksInPath().appendingPathComponent("file.txt").path)
        let read=try await tools.invoke(ToolCall(id:"r",name:"read",arguments:["path":"file.txt"]),readOnly:true)
        XCTAssertTrue(read.encoded().contains("abc"))
        let edited = try await tools.invoke(ToolCall(id:"e2",name:"edit",arguments:["path":"file.txt","oldText":"abc","newText":"line one\nline two"]),readOnly:false)
        XCTAssertEqual(edited["stats"]["added"].int, 2, "the replaced line became two"); XCTAssertEqual(edited["stats"]["removed"].int, 1)
        XCTAssertTrue(edited["content"].list.first?["text"].text?.contains("(+2 -1)") ?? false)
        _ = try await tools.invoke(ToolCall(id:"w2",name:"write",arguments:["path":"file.txt","content":"abc"]),readOnly:false)
        do { _ = try await tools.invoke(ToolCall(id:"e",name:"edit",arguments:["path":"file.txt","oldText":"abc","newText":"x"]),readOnly:true);XCTFail("Readonly edit accepted") } catch {}
        let shell=try await tools.invoke(ToolCall(id:"b",name:"bash",arguments:["command":"printf hello; printf error >&2","timeout":2]),readOnly:false)
        XCTAssertTrue(shell.encoded().contains("hello"));XCTAssertTrue(shell.encoded().contains("error"))
    }
    func testShellTimeoutTerminatesOrphanHoldingPipes() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let start=nowMS()
        let result=try await ShellRun(command:"sleep 4 & exit 0",cwd:folder,outputDirectory:folder,onUpdate:{_ in}).run(timeoutSeconds:1)
        XCTAssertLessThan(nowMS()-start,3500,"Descendants must not keep the result hanging after timeout")
        XCTAssertEqual(result["isError"].flag,true,"A timeout is a failed tool result the model can act on, not a cancellation")
        XCTAssertTrue(result["content"].list.first?["text"].text?.contains("timed out after 1 seconds") ?? false)
    }
}
