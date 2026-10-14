import AppKit
import XCTest
@testable import PiApp

final class PiQuestionSheetTests: GitPanelTestCase {
    @MainActor func testLettingGoOfTheAskerClosesItsActualSheet() async throws {
        let window = host(NSView()); defer { window.close() }
        var questions: PiQuestion? = PiQuestion()
        questions?.askSheet(over: window, make: { _ in Self.content() }, answered: { _ in })
        let sheet = try XCTUnwrap(window.attachedSheet)
        defer { if sheet.sheetParent != nil { window.endSheet(sheet); sheet.orderOut(nil) } }
        questions = nil
        try await eventually("retire the released asker's sheet", timeout: 5) { sheet.contentView == nil }
    }

    @MainActor func testClosingTheParentDuringApprovalCancelsBeforeDispatch() async throws {
        try await cancelDuringClose(closeParent: true)
    }

    @MainActor func testOwnerCancellationDuringApprovalCancelsBeforeDispatch() async throws {
        try await cancelDuringClose(closeParent: false)
    }

    @MainActor private func cancelDuringClose(closeParent: Bool) async throws {
        let window = host(NSView()); defer { window.close() }
        let questions = PiQuestion()
        var response: ((Bool) -> Void)?, answers: [Bool] = []
        questions.askSheet(over: window, make: { answer in response = answer; return Self.content() }, answered: { answers.append($0) })
        response?(true)
        if closeParent { window.close() } else { questions.cancel() }
        try await eventually("cancel before the accepted sheet has finished closing") { !questions.asking }
        XCTAssertEqual(answers, [false])
    }

    @MainActor private static func content() -> NSView {
        let sheet = PiKit.Sheet("Review", content: NSView())
        sheet.width = 300; sheet.height = 200
        return sheet
    }

    @MainActor func testOnlyTheFirstAnswerCountsAndABusyAskerRefusesAnotherQuestion() throws {
        let window = host(NSView()); defer { window.close() }
        let questions = PiQuestion()
        var response: ((Bool) -> Void)?, answers: [Bool] = [], presentations = 0
        questions.presentSheet = { _, _, answer in presentations += 1; response = answer }
        XCTAssertTrue(questions.askSheet(over: window, make: { _ in NSView() }, answered: { answers.append($0) }))
        XCTAssertTrue(questions.asking); XCTAssertTrue(questions.askedIn === window)
        XCTAssertFalse(questions.askSheet(over: window, make: { _ in XCTFail("Do not build a refused question"); return NSView() }, answered: { _ in XCTFail("Not asked") }))
        XCTAssertEqual(presentations, 1)
        response?(true); response?(false); response?(true)
        XCTAssertEqual(answers, [true]); XCTAssertFalse(questions.asking)
    }

    @MainActor func testCancelRetiresAPendingAnswerAndALateApprovalCannotReviveIt() {
        let window = host(NSView()); defer { window.close() }
        let questions = PiQuestion()
        var response: ((Bool) -> Void)?, answers: [Bool] = []
        questions.presentSheet = { _, _, answer in response = answer }
        questions.askSheet(over: window, make: { _ in NSView() }, answered: { answers.append($0) })
        questions.cancel(); response?(true)
        XCTAssertEqual(answers, [false]); XCTAssertFalse(questions.asking)
    }

    @MainActor func testClosingTheParentCancelsAndReleasesTheSheet() async throws {
        let window = host(NSView()); defer { window.close() }
        let questions = PiQuestion()
        var answers: [Bool] = []
        XCTAssertTrue(questions.askSheet(over: window, make: { answer in
            let sheet = PiKit.Sheet("Review", content: NSView())
            sheet.width = 300; sheet.height = 200; sheet.onCancel = { answer(false) }
            return sheet
        }, answered: { answers.append($0) }))
        let sheet = try XCTUnwrap(window.attachedSheet)
        let other = PiQuestion()
        XCTAssertFalse(other.askSheet(over: window, make: { _ in XCTFail("Do not queue behind an existing sheet"); return NSView() }, answered: { _ in XCTFail("Not asked") }))
        window.close()
        try await eventually("cancel and release the closed window's question") { !questions.asking && sheet.contentView == nil }
        XCTAssertEqual(answers, [false]); XCTAssertNil(window.attachedSheet)
    }
}
