import AppKit
import Darwin
import XCTest
@testable import PiApp

/// Generated content in this fixture's native window only; no helper or provider.
final class SubagentMarkdownGalleryTests: XCTestCase, SerialTestLane {
    @MainActor func testRichMarkdownInCardsReportsAndDelegatedTasks() async throws {
        guard let path = testEnvironment("PI_APP_SUB_MARKDOWN_GALLERY") else { throw XCTSkip("Set PI_APP_SUB_MARKDOWN_GALLERY") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try SubagentGalleryFixture(root: folder.appendingPathComponent("fixture-" + UUID().uuidString))
        addTeardownBlock { @MainActor in fixture.model.shutdown(); try? await fixture.model.traces.close(); await fixture.model.store?.close() }
        defer { fixture.close() }
        let rich = SubagentMarkdownTests.rich
        let task = "Review the **tokenizer**.\n\n- Preserve Unicode boundaries.\n- Check `Parser.read` and report a focused regression."
        var files: [String] = []
        for (appearance, theme) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            fixture.window.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 1240, height: 800), NSSize(width: 920, height: 600)] {
                fixture.window.setContentSize(size)
                fixture.show("completed")
                fixture.parent.runState = .idle; fixture.parent.runStatus = "idle"
                var tool = try SubagentMarkdownTests.tool(task: task, result: rich)
                tool.id = "call-0"; tool.subagentNumber = 1
                tool.input = WireValue.object(["task": .string(task), "description": .string("Check token boundaries")]).pretty
                tool.nativeSubagent = .object(["version": .number(1), "delegationId": .string("delegation-0"), "sessionId": .string("child-0"),
                    "budgetOwnerSessionId": .string(fixture.parent.id), "parentAssistantMessageId": .string("reply"), "toolCallId": .string("call-0")])
                fixture.parent.messages = [.init(id: "turn", role: "user", text: "Review the parser and share the findings."),
                    .init(id: "reply", role: "assistant", text: "The focused review is ready.", tools: [tool], turn: "turn")]
                fixture.parent.messages[1].responseTimeline = .canonical([("text", "The focused review is ready.", nil, nil), ("toolArguments", tool.input, tool.id, tool.name)], sourceID: "reply")
                await fixture.settle()
                _ = await fixture.model.revealInTranscript(sessionID: fixture.parent.id, messageID: "reply", toolCallID: "call-0")
                await fixture.settle()
                let body = try XCTUnwrap(ConversationPaneTests.views(TranscriptAgentMarkdown.self, in: fixture.content.pane).first { $0.accessibilityIdentifier() == "agent-markdown-result" })
                let base = "\(theme)-\(Int(size.width))x\(Int(size.height))"
                body.scrollToVisible(body.bounds); await fixture.settle()
                try capture(fixture.window, to: folder.appendingPathComponent(base + "-card-folded.png")); files.append(base + "-card-folded.png")
                body.setExpanded(true); await fixture.settle()
                try capture(fixture.window, to: folder.appendingPathComponent(base + "-card-expanded.png")); files.append(base + "-card-expanded.png")
                let scroll = fixture.content.pane.transcript.scrollView
                body.scrollToVisible(CGRect(x: 0, y: max(0, body.bounds.height - 360), width: max(1, body.bounds.width), height: 350))
                scroll.reflectScrolledClipView(scroll.contentView); await fixture.settle()
                try capture(fixture.window, to: folder.appendingPathComponent(base + "-card-details.png")); files.append(base + "-card-details.png")
                fixture.parent.messages = [.init(id: "report-question", role: "user", text: "What should change before release?"),
                    fixture.agentRow("rich-note", author: "subagent", kind: "note", turn: 1, text: rich)]
                await fixture.settle()
                let report = try XCTUnwrap(ConversationPaneTests.views(TranscriptAgentMarkdown.self, in: fixture.content.pane).first)
                try capture(fixture.window, to: folder.appendingPathComponent(base + "-report-folded.png")); files.append(base + "-report-folded.png")
                report.setExpanded(true); await fixture.settle()
                try capture(fixture.window, to: folder.appendingPathComponent(base + "-report-expanded.png")); files.append(base + "-report-expanded.png")
                fixture.show("child")
                fixture.child.delegatedTask = rich; fixture.child.messages = []
                await fixture.settle()
                let delegated = try XCTUnwrap(ConversationPaneTests.views(TranscriptAgentMarkdown.self, in: fixture.content.pane).first)
                let childScroll = fixture.content.pane.transcript.scrollView
                childScroll.contentView.setBoundsOrigin(.zero); childScroll.reflectScrolledClipView(childScroll.contentView)
                await fixture.settle()
                try capture(fixture.window, to: folder.appendingPathComponent(base + "-task-folded.png")); files.append(base + "-task-folded.png")
                delegated.setExpanded(true); await fixture.settle()
                try capture(fixture.window, to: folder.appendingPathComponent(base + "-task-expanded.png")); files.append(base + "-task-expanded.png")
            }
        }
        XCTAssertEqual(files.count, 28)
        try (files.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
    }

    @MainActor private func capture(_ window: NSWindow, to url: URL) throws {
        typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"))
        let create = unsafeBitCast(symbol, to: ListImage.self)
        let screen = NSScreen.screens.first?.frame ?? .zero, frame = window.frame
        let bounds = CGRect(x: frame.minX, y: screen.height - frame.maxY, width: frame.width, height: frame.height)
        let options = CGWindowImageOption.bestResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue
        let captured = try XCTUnwrap(create(bounds, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber), options)?.takeRetainedValue())
        let bitmap = NSBitmapImageRep(cgImage: captured)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
