import AppKit
import XCTest
@testable import PiApp

/// The Delete confirmation that names a chat's saved sides. Generated titles
/// only; set PI_APP_CHAT_DELETION_GALLERY to a folder to write the scenes.
final class ChatDeletionGalleryTests: XCTestCase, SerialTestLane {
    @MainActor func testDeletionConfirmationScenes() throws {
        guard let path = testEnvironment("PI_APP_CHAT_DELETION_GALLERY") else { throw XCTSkip("Set PI_APP_CHAT_DELETION_GALLERY for these scenes") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let few: [ChatQuestion.List.Item] = [.init(title: "Parser edge cases"), .init(title: "Escaped scalar spans", depth: 2),
            .init(title: "A very long side title that keeps going well past the width of the sheet to show how it is cut", depth: 3), .init(title: "Release notes draft")]
        let many = (1...240).map { ChatQuestion.List.Item(title: "Side conversation \($0)", depth: $0 % 4 == 0 ? 2 : 1) }
        let scenes: [(String, String, String, [ChatQuestion.List.Item], [String])] = [
            ("few", "Delete this chat and its sides?", "Move its managed conversation files to Trash and remove its draft and retained trace bodies. All 4 of its saved sides go with it, with their sub-agents. Includes 2 managed sub-agents.", few, []),
            ("many", "Delete this chat and its sides?", "Move its managed conversation files to Trash and remove its draft and retained trace bodies. All 240 of its saved sides go with it, with their sub-agents.", many, []),
            ("missing-project", "Delete this side and its sides?", "Move its managed conversation files to Trash and remove its draft and retained trace bodies. Its saved side goes with it, with its sub-agents. Its spend stays counted in “Parser review”.", [.init(title: "Escaped scalar spans")],
             ["This chat's project folder is missing. Only Bello's own copy of the chat is removed; nothing in the project folder is touched.",
              "Skipped: checking for costs from interrupted requests that were not yet copied into “Parser review”. That check needs the project folder. Spend already counted there stays counted."]),
            ("no-sides", "Delete this chat?", "Move its managed conversation files to Trash and remove its draft and retained trace bodies.", [], ["This chat's project folder is missing. Only Bello's own copy of the chat is removed; nothing in the project folder is touched."]),
        ]
        for (name, title, detail, items, notes) in scenes {
            var question = ChatQuestion(title: title, detail: detail, action: "Delete Chat")
            question.list = .init(heading: items.isEmpty ? "" : "Saved sides deleted with it (\(items.count))", items: items, notes: notes)
            for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for size in [NSSize(width: 1240, height: 760), NSSize(width: 340, height: 520)] {
                    let sheet = ChatQuestionSheet(question: question, list: try XCTUnwrap(question.list), destructive: true, parentSize: size, answer: { _ in })
                    sheet.appearance = NSAppearance(named: appearance)
                    sheet.frame = CGRect(origin: .zero, size: sheet.intrinsicContentSize)
                    sheet.layoutSubtreeIfNeeded()
                    XCTAssertLessThanOrEqual(sheet.bounds.width, size.width, name)
                    XCTAssertLessThan(sheet.bounds.height, size.height, name)
                    for button in [sheet.cancel, sheet.confirm] {
                        XCTAssertTrue(sheet.bounds.contains(button.convert(button.bounds, to: sheet)), name)
                    }
                    try capture(sheet, to: folder.appendingPathComponent("\(name)-\(theme)-\(Int(size.width)).png"))
                }
            }
        }
    }
    @MainActor private func capture(_ view: NSView, to path: URL) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: path)
    }
}
