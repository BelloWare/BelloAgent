import XCTest
@testable import PiAgentCore

/// The instruction and skill catalog: what reaches a request, what an
/// explicit selection authorizes, and the metadata a skill may not carry.
final class ResourceCatalogTests: XCTestCase {
    func testCodexInstructionsExplicitSkillAndRevocation() async throws {
        let root=try temporaryDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let cwd=root.appendingPathComponent("repo/sub"),home=root.appendingPathComponent("home"),skill=home.appendingPathComponent(".codex/skills/review")
        for p in [cwd,root.appendingPathComponent("repo/.git"),skill.appendingPathComponent("agents")] { try FileManager.default.createDirectory(at:p,withIntermediateDirectories:true) }
        try Data("GLOBAL".utf8).write(to:home.appendingPathComponent(".codex/AGENTS.md"))
        try Data("ROOT".utf8).write(to:root.appendingPathComponent("repo/AGENTS.md"))
        try Data("IGNORED".utf8).write(to:cwd.appendingPathComponent("AGENTS.md"))
        try Data("OVERRIDE".utf8).write(to:cwd.appendingPathComponent("AGENTS.override.md"))
        try Data("---\nname: review\ndescription: Review files\n---\nDo the review.".utf8).write(to:skill.appendingPathComponent("SKILL.md"))
        try Data("policy:\n  allow_implicit_invocation: false\n".utf8).write(to:skill.appendingPathComponent("agents/openai.yaml"))
        let resources=Resources(cwd:cwd,home:home),snapshot=try await resources.resolve()
        XCTAssertTrue(snapshot.prompt.contains("GLOBAL"));XCTAssertTrue(snapshot.prompt.contains("ROOT"));XCTAssertTrue(snapshot.prompt.contains("OVERRIDE"));XCTAssertFalse(snapshot.prompt.contains("IGNORED"))
        XCTAssertEqual(snapshot.skills.count,1);XCTAssertEqual(snapshot.skills[0]["policy"].text,"explicitOnly");XCTAssertFalse(snapshot.prompt.contains("Review files"))
        var selection=snapshot.skills[0];selection["intent"]="leading-command";selection["arguments"]="changes"
        let frozen=try await resources.freeze([selection],text:"",tools:[])
        XCTAssertEqual(frozen.count,1)
        try await resources.configure(["disabled":[snapshot.skills[0]["id"]]])
        do { try await resources.validate(frozen);XCTFail("Revoked skill was accepted") } catch {}
    }
    func testMetadataDuplicateAndAliasFailClosed() throws {
        var a=try MetadataYAML("policy:\n  allow_implicit_invocation: true\n  allow_implicit_invocation: false\n");XCTAssertThrowsError(try a.parse())
        var b=try MetadataYAML("name: &anchor abc\n");XCTAssertThrowsError(try b.parse())
    }
}
