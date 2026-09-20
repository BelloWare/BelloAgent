import XCTest
import AppKit
@testable import PiApp

final class SkillTests: XCTestCase {
    func testOnlyDirectLeadingSlashParsesAndQuotesCodeHistoryRemainPlainText() {
        XCTAssertEqual(LeadingCommand.parse("/design explain 🌍", directInput: true), LeadingCommand(name: "design", arguments: "explain 🌍"))
        for text in [" /design", "> /design", "\"/design\"", "```\n/design\n```", "Assistant: /design", "See /design", "/../bad", "/design/extra"] { XCTAssertNil(LeadingCommand.parse(text, directInput: true), text) }
        XCTAssertNil(LeadingCommand.parse("/design", directInput: false))
        XCTAssertEqual(LeadingCommand.reserved, ["side", "fork", "debug", "compact"])
    }
    func testStructuredSkillDraftRoundTripKeepsVersionAndArgumentsWithoutGrantingFromPlainText() throws {
        let chip = SkillChip(id: String(repeating: "a", count: 64), name: "example", path: "/synthetic/SKILL.md", contentHash: String(repeating: "b", count: 64), metadataHash: String(repeating: "c", count: 64), arguments: "explain $(literal)", intent: "leading-command")
        let restored = try JSONDecoder().decode(DraftRecord.self, from: JSONEncoder().encode(DraftRecord(id: "chat", text: "", skills: [chip])))
        XCTAssertEqual(restored.skills, [chip]); XCTAssertEqual(chip.wire.object?["intent"]?.string, "leading-command")
        let legacy = try JSONDecoder().decode(DraftRecord.self, from: Data("{\"id\":\"chat\",\"text\":\"/example\"}".utf8))
        XCTAssertNil(legacy.skills)
    }
    @MainActor func testCompletionKeyboardRespectsMarkedTextAndExplicitTypingOrigin() throws {
        let editor = ComposerTextView(); editor.isRichText = false
        var origins = 0, selections = 0; editor.directSlash = { origins += 1 }; editor.completionKey = { key, _ in if key == 48 { selections += 1; return true }; return false }
        func key(_ code: UInt16, _ characters: String) -> NSEvent { NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)! }
        editor.keyDown(with: key(44, "/")); XCTAssertEqual(origins, 1)
        editor.keyDown(with: key(48, "\t")); XCTAssertEqual(selections, 1)
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.keyDown(with: key(48, "\t")); XCTAssertEqual(selections, 1)
    }
}
