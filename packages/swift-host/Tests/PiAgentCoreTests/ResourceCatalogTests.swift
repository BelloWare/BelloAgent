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

    /// A submission with no skill selected has nothing to freeze, so it must
    /// not read every instruction file and skill again to find that out.
    func testSubmittingWithoutSkillsDoesNotRescanResources() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let skills = root.appendingPathComponent("codex/skills")
        for index in 0..<200 {
            let folder = skills.appendingPathComponent("skill-\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("---\nname: skill-\(index)\ndescription: Fixture \(index)\n---\nBody \(index)".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        }
        let resources = Resources(cwd: root, options: ["codexHome": JSON(root.appendingPathComponent("codex").path)], home: root)
        let start = nowMS()
        for _ in 0..<20 { let frozen = try await resources.freeze([], text: "hello", tools: []); XCTAssertTrue(frozen.isEmpty) }
        let perSubmit = (nowMS() - start) / 20
        let scanStart = nowMS(); _ = try await resources.resolve(); let scan = nowMS() - scanStart
        print("PERF submit-without-skills skills=200 freezeMs=\(perSubmit) resolveMs=\(scan)")
        XCTAssertLessThan(perSubmit, max(1, scan / 10), "no selection, no rescan")
        // A resource set that cannot even resolve does not stop a plain message.
        let broken = Resources(cwd: root, options: ["codexHome": JSON(root.appendingPathComponent("codex").path), "maxInstructionBytes": 999_999_999], home: root)
        do { _ = try await broken.resolve(); XCTFail("an out-of-range instruction limit does not resolve") } catch {}
        let none = try await broken.freeze([], text: "hello", tools: [])
        XCTAssertTrue(none.isEmpty)
    }
}
