import AppKit
import XCTest
@testable import PiApp

final class OpeningPaneTests: XCTestCase, SerialTestLane {
    @MainActor func testAutomaticPreviewNeverCoversTheDrawnConversation() async throws {
        let f = try await OpeningPaneFixture(), gate = OpeningPaneGate()
        registerWorkspaceFixtureTeardown(f.model, root:f.root)
        defer { gate.release(); f.close() }
        f.model.sessionOpeningStep = { if $0 == "dispatch" { await gate.wait() } }
        f.session.contextSelectionReady = true
        f.model.scheduleAutomaticContext(f.chat.id)
        try await eventually("The selection preview is opening its helper") { gate.entered }
        await f.drawAfterThreshold()
        XCTAssertTrue(f.session.footer.preparingContext)
        XCTAssertFalse(ConversationPaneView.coversTranscript(f.session))
        XCTAssertTrue(f.openingViews.allSatisfy(\.isHidden), "Selection never shows opening UI over journal-backed rows")
        XCTAssertTrue(f.pane.transcript.frame.height > 200)
    }

    @MainActor func testSendShowsAStripWithoutMovingTheTranscript() async throws {
        let f = try await OpeningPaneFixture(), gate = OpeningPaneGate()
        registerWorkspaceFixtureTeardown(f.model, root:f.root)
        defer { gate.release(); f.close() }
        f.model.sessionOpeningStep = { if $0 == "dispatch" { await gate.wait() } }
        f.model.send(sessionID: f.chat.id)
        try await eventually("Send waits on the opening") { gate.entered }
        f.draw(); let frame = f.pane.transcript.frame
        await f.drawAfterThreshold()
        XCTAssertFalse(ConversationPaneView.coversTranscript(f.session))
        let strip = try XCTUnwrap(f.openingViews.first { !$0.isHidden })
        XCTAssertLessThanOrEqual(strip.frame.height, 64, "Opening is a slim strip, never a transcript cover")
        XCTAssertEqual(f.pane.transcript.frame, frame, "The strip takes no room from the reader")
        let token = try XCTUnwrap(f.model.sessionOpenings[f.chat.id]?.token)
        f.model.observeOpening(.init(completed:37,total:100), id:f.chat.id, token:token)
        f.draw()
        XCTAssertEqual(strip.progress.value, 0.37)
        XCTAssertEqual(f.pane.transcript.frame, frame)
    }

    @MainActor func testCancelledSendLeavesRowsAndComposerUsable() async throws {
        let f = try await OpeningPaneFixture(), gate = OpeningPaneGate()
        registerWorkspaceFixtureTeardown(f.model, root:f.root)
        defer { gate.release(); f.close() }
        f.model.sessionOpeningStep = { if $0 == "dispatch" { await gate.wait() } }
        f.model.send(sessionID:f.chat.id)
        try await eventually("Send waits") { gate.entered }
        await f.drawAfterThreshold()
        f.model.cancelSessionOpening(f.chat.id); gate.release()
        try await eventually("Cancel settles and withdraws the opening") {
            !f.session.loading && f.model.sessionOpenings[f.chat.id] == nil && f.model.sessionClosings[f.chat.id] == nil
        }
        f.draw()
        XCTAssertEqual(f.session.draft, OpeningPaneFixture.draft)
        XCTAssertEqual(f.session.sendFailure, "Opening cancelled. Your message was not sent.")
        XCTAssertFalse(ConversationPaneView.coversTranscript(f.session))
        XCTAssertTrue(f.openingViews.allSatisfy(\.isHidden), "The send's notice is its failure surface; no Retry panel remains")
        XCTAssertTrue(try XCTUnwrap(f.editor).isEditable)
        XCTAssertEqual(f.session.messages.map(\.id), ["question", "answer"])
    }

    @MainActor func testFailedSendLeavesRowsAndComposerUsable() async throws {
        let f = try await OpeningPaneFixture(), gate = OpeningPaneGate()
        registerWorkspaceFixtureTeardown(f.model, root:f.root)
        defer { gate.release(); f.close() }
        f.model.sessionOpeningStep = { if $0 == "dispatch" { await gate.wait(); throw HostError.failure("Generated opening failure") } }
        f.model.send(sessionID:f.chat.id)
        try await eventually("Send waits") { gate.entered }
        await f.drawAfterThreshold(); gate.release()
        try await eventually("Failure restores the draft") { !f.session.loading && f.session.sendFailure != nil }
        f.draw()
        XCTAssertEqual(f.session.draft, OpeningPaneFixture.draft)
        XCTAssertEqual(f.session.sendFailure, "Generated opening failure")
        XCTAssertFalse(ConversationPaneView.coversTranscript(f.session))
        XCTAssertTrue(f.openingViews.allSatisfy(\.isHidden), "The action already reports its error")
        XCTAssertTrue(try XCTUnwrap(f.editor).isEditable)
        XCTAssertEqual(f.session.messages.map(\.id), ["question", "answer"])
    }
    @MainActor func testSendJoiningAutomaticOpeningRevealsTheSharedProgress() async throws {
        let f = try await OpeningPaneFixture(), gate = OpeningPaneGate()
        registerWorkspaceFixtureTeardown(f.model, root:f.root)
        defer { gate.release(); f.close() }
        f.model.sessionOpeningStep = { if $0 == "dispatch" { await gate.wait() } }
        f.session.contextSelectionReady = true; f.model.scheduleAutomaticContext(f.chat.id)
        try await eventually("Selection started the shared open") { gate.entered }
        await f.drawAfterThreshold()
        XCTAssertNil(f.session.waitingOpening)
        let token = try XCTUnwrap(f.model.sessionOpenings[f.chat.id]?.token)
        f.model.observeOpening(.init(completed:37,total:100), id:f.chat.id, token:token)
        f.model.send(sessionID:f.chat.id)
        try await eventually("Send joined the existing open") { f.session.helperOpeningActions > 0 }
        await f.drawAfterThreshold()
        XCTAssertEqual(f.model.sessionOpenings[f.chat.id]?.token, token)
        XCTAssertFalse(ConversationPaneView.coversTranscript(f.session))
        let strip = try XCTUnwrap(f.openingViews.first { !$0.isHidden })
        XCTAssertFalse(strip.inCover); XCTAssertEqual(strip.progress.value, 0.37)
        f.model.cancelSessionOpening(f.chat.id)
    }

    @MainActor func testExistingEmptyLoadingCoverContainsProgressAndCancel() async throws {
        let f = try await OpeningPaneFixture()
        registerWorkspaceFixtureTeardown(f.model, root:f.root)
        defer { f.close() }
        f.session.messages = []; f.session.historyState = .loading
        f.session.helperOpeningActions = 1; f.session.helperOpening = .opening(.init(completed:37,total:100))
        f.draw(); await f.drawAfterThreshold()
        XCTAssertTrue(ConversationPaneView.coversTranscript(f.session))
        let cover = try XCTUnwrap(f.openingViews.first { !$0.isHidden })
        XCTAssertTrue(cover.inCover); XCTAssertEqual(cover.frame, f.pane.transcript.frame)
        XCTAssertEqual(cover.action.title, "Cancel")
    }

    @MainActor func testQuickOpeningNeverFlashes() async throws {
        let f = try await OpeningPaneFixture()
        registerWorkspaceFixtureTeardown(f.model, root:f.root)
        defer { f.close() }
        f.session.helperOpeningActions = 1; f.session.helperOpening = .opening(nil); f.draw()
        XCTAssertTrue(f.openingViews.allSatisfy(\.isHidden))
        f.session.helperOpening = nil; f.session.helperOpeningActions = 0; f.draw()
        await f.drawAfterThreshold()
        XCTAssertTrue(f.openingViews.allSatisfy(\.isHidden))
    }

}

@MainActor final class OpeningPaneGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor final class OpeningPaneFixture {
    static let draft = "Keep my unsent message"
    let root: URL, model: WorkspaceModel, chat: ChatRecord, session: SessionDisplay
    let pane: ConversationPaneView, window: NSWindow
    init(width: CGFloat = 840) async throws {
        root = URL(fileURLWithPath:scratchBase()).appendingPathComponent("opening-pane-" + UUID().uuidString)
        let bench = try ConversationPaneTests.workbench(root:root, chats:["opening"])
        model = bench.model; chat = bench.chats[0]
        model.prewarmsHelpers = false
        try await model.reloadConfiguration()
        try await model.store?.put(chat, kind:"chat", id:chat.id)
        session = SessionDisplay(id:chat.id); session.selectionMetadataLoaded = true
        session.messages = [.init(id:"question", role:"user", text:"Can you explain the parser change?", turn:"question"),
                            .init(id:"answer", role:"assistant", text:"The saved conversation remains readable while the helper prepares the next action.", turn:"question")]
        session.historyState = .ready; session.draft = Self.draft
        model.displays[chat.id] = session; model.selectedID = chat.id; model.selected = session; model.focusedSessionID = chat.id
        pane = ConversationPaneView(model:model)
        window = NSWindow(contentRect:CGRect(x:100,y:100,width:width,height:600),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = pane
        pane.show(session:session,chat:chat); draw()
    }
    var openingViews: [SessionOpeningView] { ConversationPaneTests.views(SessionOpeningView.self,in:pane) }
    var editor: ComposerTextView? { ConversationPaneTests.views(ComposerTextView.self,in:pane).first }
    func draw() { pane.show(session:session,chat:chat); pane.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
    func drawAfterThreshold() async { try? await Task.sleep(for:.milliseconds(220)); draw() }
    func close() { model.shutdown(); window.contentView = nil; window.close() }
}
