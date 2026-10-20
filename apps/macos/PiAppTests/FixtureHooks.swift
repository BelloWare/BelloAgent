import AppKit
import XCTest
@testable import PiApp

// Install before any view is made, and unwind after the fixture's own teardown.
// Keeping the previous closures also makes nested fixtures safe.
@MainActor func installStandaloneFileResolver(_ test: XCTestCase) {
    let previous = FileTab.resolveProject
    test.addTeardownBlock { @MainActor in FileTab.resolveProject = previous }
    FileTab.resolveProject = { $0 == nil ? .none : .removed }
}

@MainActor func installQuestionHooks(_ test: XCTestCase) {
    let question = PiQuestion.shared, fixture = PiQuestion()
    let answers = (question.answer, question.answerAlert, question.enterText)
    let files = (question.chooseFiles, question.chooseFile)
    let presentation = (question.present, question.presentSheet)
    test.addTeardownBlock { @MainActor in
        question.answer = answers.0; question.answerAlert = answers.1; question.enterText = answers.2
        question.chooseFiles = files.0; question.chooseFile = files.1
        question.present = presentation.0; question.presentSheet = presentation.1
    }
    question.answer = fixture.answer; question.answerAlert = fixture.answerAlert; question.enterText = fixture.enterText
    question.chooseFiles = fixture.chooseFiles; question.chooseFile = fixture.chooseFile
    question.present = fixture.present; question.presentSheet = fixture.presentSheet
}

@MainActor func installSidebarRevealHook(_ test: XCTestCase) {
    let previous = SidebarSearchReveal.override
    test.addTeardownBlock { @MainActor in SidebarSearchReveal.override = previous }
    SidebarSearchReveal.override = nil
}

@MainActor func installSkillPopoverHooks(_ test: XCTestCase) {
    let popovers = SkillPopovers.shared
    let previous = (popovers.card.delay, popovers.openFile, popovers.revealFile)
    test.addTeardownBlock { @MainActor in
        popovers.close()
        popovers.card.delay = previous.0; popovers.openFile = previous.1; popovers.revealFile = previous.2
    }
    popovers.card.delay = PiHoverCardPresenter.delay
    popovers.openFile = { _ in XCTFail("Install an Open fixture before invoking a skill action") }
    popovers.revealFile = { _ in XCTFail("Install a Reveal fixture before invoking a skill action") }
}

// These probes call the class's real setUp after installing another fixture's
// hooks. The inner teardown must restore that fixture before the outer setup's
// teardown restores the original caller. No test-order or worker choice needed.
@MainActor func checkStandaloneFileResolverSetup(_ test: XCTestCase, setUp: @MainActor () async throws -> Void) async throws {
    let previous = FileTab.resolveProject
    FileTab.resolveProject = { _ in .removed }
    test.addTeardownBlock { @MainActor in
        XCTAssertEqual(FileTab.resolveProject(nil), .removed, "Restore the inherited resolver, not a default")
        FileTab.resolveProject = previous
    }
    try await setUp()
    let root = scratchRoot("file-resolver-order")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("standalone.txt")
    try Data("fixture".utf8).write(to: url)
    let tab = FileTab(url: url, projectID: nil)
    defer { tab.willClose() }
    XCTAssertNil(tab.missingReason, "A previous workspace cannot remove this standalone fixture")
    let document = try XCTUnwrap(tab.document)
    try await eventually("the standalone fixture is read") { document.status == .ready }
}

@MainActor func checkQuestionHooksSetup(_ test: XCTestCase, setUp: @MainActor () async throws -> Void) async throws {
    let previous = PiQuestion.shared.answerAlert
    PiQuestion.shared.answerAlert = { _ in .alertSecondButtonReturn }
    test.addTeardownBlock { @MainActor in
        XCTAssertEqual(PiQuestion.shared.answerAlert?(NSAlert()), .alertSecondButtonReturn,
                       "Restore the inherited answer, not nil")
        PiQuestion.shared.answerAlert = previous
    }
    try await setUp()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    let alert = NSAlert()
    alert.messageText = "Fixture question"
    var answer: NSApplication.ModalResponse?
    PiQuestion.shared.ask(alert, over: window) { answer = $0 }
    XCTAssertNil(answer, "An inherited answer must not bypass the fixture's sheet")
    guard answer == nil else { return }
    try await eventually("the fixture's own sheet attaches") { window.attachedSheet != nil }
    let sheet = try XCTUnwrap(window.attachedSheet)
    window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
    try await eventually("the fixture's own sheet answers") { answer == .alertFirstButtonReturn }
}

@MainActor func checkSidebarRevealSetup(_ test: XCTestCase, setUp: @MainActor () async throws -> Void) async throws {
    let previous = SidebarSearchReveal.override
    var inheritedCalls = 0
    SidebarSearchReveal.override = { _, _ in inheritedCalls += 1 }
    test.addTeardownBlock { @MainActor in
        await SidebarSearchReveal.override?("fixture", "message")
        XCTAssertEqual(inheritedCalls, 1, "Restore the inherited reveal, not nil")
        SidebarSearchReveal.override = previous
    }
    try await setUp()
    XCTAssertNil(SidebarSearchReveal.override, "This class exercises the real sidebar reveal")
}

@MainActor func checkSkillPopoverHooksSetup(_ test: XCTestCase, setUp: @MainActor () async throws -> Void) async throws {
    let popovers = SkillPopovers.shared, previous = popovers.card.delay
    popovers.card.delay = .seconds(20)
    test.addTeardownBlock { @MainActor in
        XCTAssertEqual(popovers.card.delay, .seconds(20), "Restore the inherited delay, not the app default")
        popovers.card.delay = previous
    }
    try await setUp()
    XCTAssertEqual(popovers.card.delay, PiHoverCardPresenter.delay, "The hover fixture owns its timing")
}
