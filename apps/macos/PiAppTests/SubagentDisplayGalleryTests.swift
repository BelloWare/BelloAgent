import AppKit
import Darwin
import XCTest
@testable import PiApp

/// Standalone, generated-family gallery: never opens a helper or provider.
final class SubagentDisplayGalleryTests: XCTestCase, SerialTestLane {
    @MainActor func testNumberedFamilyAndCollapsedTurn() async throws {
        guard let path = testEnvironment("PI_APP_SUB_DISPLAY_GALLERY") else { throw XCTSkip("Set PI_APP_SUB_DISPLAY_GALLERY") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try SubagentGalleryFixture(root: folder.appendingPathComponent("fixture-" + UUID().uuidString))
        addTeardownBlock { @MainActor in
            fixture.model.shutdown(); try? await fixture.model.traces.close(); await fixture.model.store?.close()
        }
        let previous = TranscriptDisplay.mode
        defer { fixture.close(); TranscriptDisplay.use(previous) }
        var written: [String] = []
        for (appearance, theme) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            fixture.window.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 920, height: 600), NSSize(width: 1240, height: 800), NSSize(width: 640, height: 600)] {
                fixture.window.setContentSize(size)
                for scene in ["finished-collapsed", "finished-expanded", "numbered-card", "mixed-reports", "child-parent-steer", "child-report"] {
                    TranscriptDisplay.use(scene.hasPrefix("finished") ? .compact : .normal)
                    switch scene {
                    case "finished-collapsed", "finished-expanded":
                        fixture.showSteering("delivered-result")
                        fixture.parent.runState = .idle; fixture.parent.runStatus = "idle"
                        for id in fixture.model.subagentSummaries.keys { fixture.model.subagentSummaries[id]?.status = .completed }
                        fixture.parent.childSummaries = fixture.model.subagentSummaries
                        fixture.parent.messages.append(.init(id: "final", role: "assistant", text: "The review is complete. Preserve the diagnostic span before advancing the recovery cursor; the focused regression passes.", turn: "turn"))
                        fixture.parent.disclosure.setOpen(scene == "finished-expanded", .turnFold("turn"))
                        fixture.parent.disclosure.setOpen(false, .tool(ToolOccurrence.key("reply", "call-0")))
                    case "numbered-card": fixture.showSteering("background-expanded")
                    case "child-parent-steer": fixture.showSteering("parent-steering")
                    case "child-report": fixture.showSteering("child-report")
                    default:
                        fixture.showSteering("delivered-question")
                        var row = fixture.agentRow("mixed", author: "subagent", kind: "result", turn: 2, text: "The token boundary regression passes.")
                        var metadata = row.nativeAgentDelivery!.object!
                        var event = metadata["events"]!.array![0].object!
                        event["child_id"] = .string("child-1"); event["task"] = .string("Audit cancellation")
                        event["text"] = .string("Cancellation preserves the accepted result and stops pending work.")
                        metadata["events"] = .array(metadata["events"]!.array! + [.object(event)])
                        row.nativeAgentDelivery = .object(metadata)
                        fixture.parent.messages = [fixture.parent.messages[0], row]
                    }
                    await fixture.settle()
                    if scene == "numbered-card" {
                        let revealed = await fixture.model.revealInTranscript(sessionID: fixture.parent.id, messageID: "reply", toolCallID: "call-0")
                        XCTAssertTrue(revealed)
                        await fixture.settle()
                    }
                    if scene == "finished-collapsed" {
                        let items = TaskTranscriptPlan.items(fixture.parent.presentedMessages, lifecycle: nil)
                        XCTAssertTrue(items.contains { if case .block(let b) = $0 { return b.presentation == .turnFold }; return false })
                        for item in items {
                            if case .message(let row) = item, row.nativeAgentDelivery != nil {
                                XCTAssertTrue(TranscriptRowDisclosure.of(item, in: fixture.parent.disclosure).foldedAway)
                            }
                        }
                    }
                    if scene == "child-parent-steer" {
                        let back = try XCTUnwrap(ConversationPaneTests.views(PiKit.Button.self, in: fixture.content).first { $0.accessibilityIdentifier() == "back-to-subagent-parent" })
                        XCTAssertTrue(back.accessibilityLabel()?.contains("Sub-agent 1") == true)
                        fixture.window.makeFirstResponder(back)
                        XCTAssertTrue(fixture.window.firstResponder === back)
                    }
                    let name = "\(scene)-\(theme)-\(Int(size.width))x\(Int(size.height)).png"
                    try capture(fixture.window, to: folder.appendingPathComponent(name)); written.append(name)
                }
            }
        }
        _ = try await fixture.prepareSteeringInspector()
        for summary in fixture.model.subagentSummaries.values {
            try await fixture.model.traces.recordSubagent(summary, workspaceID: "pane-project")
        }
        for (appearance, theme) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for size in [NSSize(width: 920, height: 600), NSSize(width: 1240, height: 800)] {
                let inspector = SessionInspectorModel(scope: .init(sessionID: fixture.parent.id, workspaceID: "pane-project"), title: "Review the parser", archive: fixture.model.traces, workspace: fixture.model,
                    usageLoader: { [archive = fixture.model.traces] scope, until, offset in
                        try await archive.sessionMetrics(sessionID: scope.sessionID, workspaceID: scope.workspaceID, until: until, offset: offset, includeFamily: scope.includeFamily)
                    })
                let controller = SessionInspectorWindowController(inspector: inspector)
                let window = try XCTUnwrap(controller.window)
                window.appearance = NSAppearance(named: appearance); window.setContentSize(size)
                controller.present(.subagent("delegation-1"))
                for _ in 0..<200 where !inspector.indexLoaded || inspector.page != .subagent("delegation-1") { try await Task.sleep(for: .milliseconds(20)) }
                XCTAssertEqual(inspector.groups.first { $0.summary.link.childSessionID == "child-1" }?.number, 2)
                window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                let name = "family-inspector-\(theme)-\(Int(size.width))x\(Int(size.height)).png"
                try capture(window, to: folder.appendingPathComponent(name)); written.append(name)
                controller.close()
            }
        }
        XCTAssertEqual(written.count, 40)
        try (written.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
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
