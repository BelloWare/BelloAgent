import AppKit
import XCTest
@testable import PiApp

private final class InheritedPlanGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false, released = false
    let path: URL
    init(_ path: URL) { self.path = path }
    var hasEntered: Bool { condition.lock(); defer { condition.unlock() }; return entered }
    func enter(_ path: URL) {
        guard path == self.path else { return }
        condition.lock(); defer { condition.unlock() }
        entered = true
        let limit = Date().addingTimeInterval(15)
        while !released, condition.wait(until: limit) {}
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

final class InheritedPlanOpeningTests: XCTestCase, SerialTestLane {
    @MainActor func testFirstUsefulViewportAndForegroundReadsDoNotWaitForInheritedPlans() async throws {
        for changedLineage in [false, true] {
            var gate: InheritedPlanGate?, made: LongChatScroll?
            defer { gate?.release(); HistoryReader.planScanStarting = nil }
            let opening = Task {
                let chat = try await LongChatScroll(turns: 4, preparePaneBeforeSelection: true) { model, item in
                    let held = InheritedPlanGate(URL(fileURLWithPath: item.path!)); gate = held
                    HistoryReader.planScanStarting = { held.enter($0) }
                    self.registerWorkspaceFixtureTeardown(model, root: model.root.deletingLastPathComponent())
                }
                made = chat
                return chat
            }
            let until = ContinuousClock.now.advanced(by: .seconds(2))
            while made == nil, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertNotNil(made, "The inherited-plan scan held the initial page")
            guard let chat = made else { gate?.release(); let late = try await opening.value; late.close(); return }
            defer { chat.close() }
            try await eventually("The useful viewport waited for inherited labels") { chat.draw(); return chat.view.historyState == .ready && !chat.blankViewport }
            try await eventually("The deferred scan never started") { gate?.hasEntered == true }
            var foregroundReady = false
            let foreground = Task {
                _ = try await chat.model.history.window(path: chat.chat.path!, cursor: nil)
                foregroundReady = true
            }
            let readUntil = ContinuousClock.now.advanced(by: .seconds(2))
            while !foregroundReady, ContinuousClock.now < readUntil { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(foregroundReady, "The optional scan blocked the foreground history reader")
            var enriched = false
            chat.model.openSteps = { _, step in if step == "inherited agents read" { enriched = true } }
            if changedLineage {
                let source = try XCTUnwrap(chat.view.presentation.identity)
                chat.view.presentation.identity = (source.incarnation, "edited")
            } else { _ = chat.model.transcriptNavigation(chat.chat.id, advancing: true) }
            let enrichment = chat.view.presentation.inheritedPlanRead
            gate?.release(); try await foreground.value; _ = try await opening.value; await enrichment?.value
            XCTAssertEqual(enriched, !changedLineage, changedLineage ? "A replaced lineage published stale inherited labels" : "Moving within the same chat discarded valid inherited labels")
        }
    }

    @MainActor func testGatedLabelsKeepCollapsedAndExpandedGeometryAndAnchor() async throws {
        for (width, style, name) in [(700.0, NSAppearance.Name.aqua, "light"), (700.0, .darkAqua, "dark"), (320.0, .aqua, "narrow")] {
            for expanded in [false, true] {
                var tool = SubagentTranscriptTests.tool; tool.nativeSubagent = SubagentTranscriptTests.metadata
                let session = SessionDisplay(id: "fork")
                session.messages = [.init(id: "question", role: "user", text: "Review the saved parser result."),
                                    .init(id: "reply", role: "assistant", text: "Saved review", tools: [tool], turn: "question"),
                                    .init(id: "after", role: "assistant", text: String(repeating: "Reading after the delegated task.\n\n", count: 35), turn: "question")]
                session.disclosure.setOpen(true, .turnFold("question"))
                session.disclosure.setOpen(true, .work("legacy:reply"))
                session.disclosure.setOpen(expanded, .tool(ToolOccurrence.key("reply", tool.id)))
                session.scrollAnchor = .init(id: "question", offset: 17, followsBottom: false)
                let pane = NativeTranscriptPane(frame: .init(x: 0, y: 0, width: width, height: 600))
                pane.page.presentationInterval = 0
                pane.wantsLayer = true
                let window = NSWindow(contentRect: pane.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: style); window.contentView = pane
                window.appearance?.performAsCurrentDrawingAppearance { pane.layer?.backgroundColor = TranscriptNSPalette.canvas.cgColor }
                defer { window.contentView = nil; window.close() }
                var environment = TranscriptRowEnvironment(view: pane); environment.sessionID = session.id
                func draw() { pane.update(session: session, state: "idle", actions: .init(), environment: environment, reduceMotion: true); pane.layoutSubtreeIfNeeded(); pane.document.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
                draw()
                for _ in 0..<20 { draw(); try await Task.sleep(for: .milliseconds(5)) }
                let row = try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeActionRow.self, in: pane).first)
                XCTAssertEqual(row.card != nil, expanded, "The fixture did not apply its tool disclosure")
                let container = try XCTUnwrap(pane.document.retainedRows.first { row.isDescendant(of: $0) })
                XCTAssertFalse(container.foldedAway, "The fixture hid its card inside a folded turn")
                XCTAssertTrue(TranscriptRowDisclosure.of(container.item, in: session.disclosure).work, "The enclosing work group must be open")
                XCTAssertTrue(container.frame.intersects(pane.scrollView.contentView.bounds), "The card must be on screen for this check")
                let height = row.height(width: row.bounds.width)
                let anchor = try XCTUnwrap(pane.document.retainedRows.first { $0.item.messageIDs.contains("question") })
                let top = anchor.frame.minY - pane.scrollView.contentView.bounds.minY
                if expanded {
                    let open = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self, in: row).first { $0.accessibilityIdentifier() == "open-subagent" })
                    XCTAssertFalse(open.isEnabled, "An unvalidated original must stay disabled")
                }
                let gate = InheritedPlanGate(URL(fileURLWithPath: "/generated-label-gate"))
                let enrichment = Task {
                    await Task.detached { gate.enter(gate.path) }.value
                    session.subagentNumbers["chat-child"] = 12_345
                    session.subagentNames["chat-child"] = "parser_review_with_a_long_name"
                    session.originalSubagentAvailability["chat-child"] = .init(title: String(repeating: "Original parser investigation ", count: 6), reason: "The original project is unavailable or is not trusted.")
                }
                try await eventually("Enrichment did not reach its gate") { gate.hasEntered }
                XCTAssertNil(session.originalSubagentAvailability["chat-child"])
                gate.release(); await enrichment.value
                for _ in 0..<20 { draw(); try await Task.sleep(for: .milliseconds(5)) }
                let enriched = try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeActionRow.self, in: pane).first)
                XCTAssertEqual(enriched.height(width: enriched.bounds.width), height, accuracy: 0.5, "Late labels changed card geometry: \(name), expanded=\(expanded)")
                XCTAssertNotNil(session.presentedMessages.first { $0.id == "reply" }?.tools?.first?.originalSubagentAvailability)
                XCTAssertNotNil(session.presentationChanges.value.messages.first { $0.id == "reply" }?.tools?.first?.originalSubagentAvailability, "The enriched projection was not published")
                XCTAssertNotNil(pane.page.snapshot?.messages.first { $0.id == "reply" }?.tools?.first?.originalSubagentAvailability, "The page retained the previous projection")
                XCTAssertNotNil(enriched.tool?.originalSubagentAvailability, "The native row retained the previous tool")
                if expanded {
                    let labels = ConversationPaneTests.views(TranscriptPlainTextView.self, in: enriched).map(\.string)
                    XCTAssertTrue(labels.contains { $0.contains("Original parser investigation") }, "The enriched title never rendered")
                    XCTAssertTrue(labels.contains { $0.contains("not trusted") }, "The validation reason never rendered")
                    let buttons = ConversationPaneTests.views(PiKit.Button.self, in: enriched)
                    for id in ["open-subagent", "inspect-subagent"] {
                        let button = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == id })
                        XCTAssertFalse(button.isEnabled, "Labels must not enable an unavailable original")
                    }
                }
                let landed = try XCTUnwrap(pane.document.retainedRows.first { $0.item.messageIDs.contains("question") })
                XCTAssertEqual(landed.frame.minY - pane.scrollView.contentView.bounds.minY, top, accuracy: 0.5, "Late labels moved the reader")
                if let folder = testEnvironment("PI_INHERITED_PLAN_GALLERY") {
                    let output = URL(fileURLWithPath: folder); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    let bitmap = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds)); pane.cacheDisplay(in: pane.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("inherited-\(name)-\(expanded ? "expanded" : "collapsed").png"))
                }
            }
        }
    }
}
