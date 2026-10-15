import AppKit
import Darwin
import XCTest
@testable import PiApp

/// A generated family in this test's windows only; no helper or provider.
final class SubagentEffortGalleryTests: XCTestCase, SerialTestLane {
    @MainActor func testPickerCardAndChildHeaderEffort() async throws {
        guard let path = testEnvironment("PI_APP_SUB_EFFORT_GALLERY") else { throw XCTSkip("Set PI_APP_SUB_EFFORT_GALLERY") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try SubagentGalleryFixture(root: folder.appendingPathComponent("fixture-" + UUID().uuidString))
        let model = fixture.model, window = fixture.window
        let root = WorkspaceRootView(model: model); window.contentView = root
        model.historyWindowLoader = { id, _, _, _ in
            try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("fixture-" + id), "lineage": .string("root"),
                "messages": .array([.object(["id": .string(id + "-reply"), "role": .string("assistant"), "text": .string("The tokenizer preserves Unicode boundaries. Save the original diagnostic span before recovery advances the cursor.")])]), "older": .null, "newer": .null]))
        }
        defer { fixture.close() }
        addTeardownBlock { @MainActor in model.shutdown(); try? await model.traces.close(); await model.store?.close() }
        var files: [String] = []
        for (appearance, theme) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 1240, height: 800), NSSize(width: 920, height: 600)] {
                for tab in model.tabs.allTabs { model.tabs.close(tab) }
                fixture.showSteering("background-expanded")
                for (index, level) in ["high", "low", "default", "default"].enumerated() {
                    let id = "child-\(index)", child = try XCTUnwrap(model.record(id))
                    model.publishSubagentEffort(.init(model: "fixture-model", thinkingLevel: "low", reasoning: index == 3 ? [] : ["low", "high"]), child: child)
                    model.subagentSummaries[id]?.effort = level
                }
                fixture.parent.childSummaries = model.subagentSummaries
                window.setContentSize(size); root.refresh(); await settle(window)
                let main = try XCTUnwrap(root.conversation)
                _ = await model.revealInTranscript(sessionID: fixture.parent.id, messageID: "reply", toolCallID: "call-0")
                await settle(window)
                let card = try XCTUnwrap(ConversationPaneTests.views(TranscriptNativeSubagentCard.self, in: main).first)
                XCTAssertTrue(card.accessibilityLabel()?.contains(" · high") == true)
                let base = "\(theme)-\(Int(size.width))x\(Int(size.height))"
                try capture([window], to: folder.appendingPathComponent(base + "-card.png")); files.append(base + "-card.png")
                main.agentFamilyHeader.open(); await settle(window)
                let popup = try XCTUnwrap(main.agentFamilyHeader.popover.popover?.contentViewController?.view.window)
                let content = try XCTUnwrap(popup.contentView)
                let rows = ConversationPaneTests.views(FamilyPickerRow.self, in: content).filter { $0.accessibilityIdentifier().hasPrefix("open-agent-") }
                XCTAssertEqual(rows.count, 4)
                for (row, expected) in zip(rows, [" · high", " · low", " · model default", nil]) {
                    if let expected { XCTAssertTrue(row.accessibilityLabel()?.contains(expected) == true) }
                    else { XCTAssertFalse(row.accessibilityLabel()?.contains("model default") == true) }
                }
                XCTAssertGreaterThanOrEqual(popup.frame.minX, window.frame.minX); XCTAssertLessThanOrEqual(popup.frame.maxX, window.frame.maxX)
                try capture([popup, window], to: folder.appendingPathComponent(base + "-picker.png")); files.append(base + "-picker.png")
                main.agentFamilyHeader.popover.close()
                await model.openSubagentTab("child-0"); root.refresh(); await settle(window)
                let pane = try XCTUnwrap(model.subagentTab("child-0")?.pane)
                let header = try XCTUnwrap(ConversationPaneTests.views(SubagentHeaderView.self, in: pane).first)
                let effort = try XCTUnwrap(ConversationPaneTests.views(PiKit.TextLine.self, in: header).first { $0.line.text == "· high" })
                XCTAssertTrue(header.bounds.contains(effort.convert(effort.bounds, to: header)), "Effort stays visible beside a truncated child title")
                try capture([window], to: folder.appendingPathComponent(base + "-child.png")); files.append(base + "-child.png")
            }
        }
        XCTAssertEqual(files.count, 12)
        try (files.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
    }
    @MainActor private func settle(_ window: NSWindow) async {
        for _ in 0..<6 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try? await Task.sleep(for: .milliseconds(50)) }
    }
    @MainActor private func capture(_ windows: [NSWindow], to url: URL) throws {
        typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"))
        let create = unsafeBitCast(symbol, to: ListImage.self)
        let union = windows.reduce(CGRect.null) { $0.union($1.frame) }
        let screen = NSScreen.screens.first?.frame ?? .zero, scale = windows.first?.backingScaleFactor ?? 1
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(union.width * scale), height: Int(union.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        for window in windows.reversed() {
            let frame = window.frame
            let bounds = CGRect(x: frame.minX, y: screen.height - frame.maxY, width: frame.width, height: frame.height)
            let image = try XCTUnwrap(create(bounds, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber), CGWindowImageOption.bestResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
            context.draw(image, in: CGRect(x: frame.minX - union.minX, y: frame.minY - union.minY, width: frame.width, height: frame.height))
        }
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
