import XCTest
import AppKit
@testable import PiApp

/// The queue panel's states at the 920×600 minimum window, light and dark:
/// 1, 5, 20 and 64 waiting (the queue's limit), collapsed, held by an edit
/// in the composer, and held by an edit a restart left. Each scene checks
/// that the panel stays inside its bound and off the composer; with
/// `PI_APP_QUEUE_GALLERY` set to a folder, each is also written there as a
/// PNG to look at.
final class QueuePanelGalleryTests: XCTestCase {
    private struct Scene { let name: String; let count: Int; var collapsed = false; var editing = false; var heldElsewhere = false; var terminal = false; var width: CGFloat = 920; var tallDraft = false }

    @MainActor func testQueuePanelScenes() async throws {
        let folder = ProcessInfo.processInfo.environment["PI_APP_QUEUE_GALLERY"].map(URL.init(fileURLWithPath:))
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let scenes = [Scene(name: "queue-1", count: 1), Scene(name: "queue-5", count: 5), Scene(name: "queue-20", count: 20),
                      Scene(name: "queue-64-limit", count: 64), Scene(name: "queue-20-collapsed", count: 20, collapsed: true),
                      Scene(name: "queue-5-editing", count: 5, editing: true), Scene(name: "queue-5-held-after-restart", count: 5, heldElsewhere: true),
                      Scene(name: "queue-20-terminal-tall-draft", count: 20, terminal: true, tallDraft: true),
                      Scene(name: "queue-5-split-terminal", count: 5, terminal: true, width: 460)]
        for scene in scenes {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                let pane = try ConversationPaneTests.Pane(width: scene.width, height: 600)
                defer { pane.close(); if scene.terminal { TerminalRegistry.shared.shutdown() } }
                pane.model.terminalVisible = scene.terminal
                pane.window.appearance = NSAppearance(named: appearance)
                pane.session.state = scene.editing || scene.heldElsewhere || scene.terminal ? "idle" : "running"
                if scene.terminal { pane.session.queuePaused = true }
                pane.session.queue = (0..<scene.count).map { index in
                    ["turnId": .string("q\(index)"), "kind": .string(index % 4 == 1 ? "steering" : "follow-up"),
                     "text": .string(index % 4 == 1 ? "Check the failing test before the next edit" : "Follow-up \(index): summarise what changed and why")]
                }
                pane.session.draft = scene.tallDraft ? (0..<20).map { "Line \($0) of a long draft" }.joined(separator: "\n") : "A thought still being typed."
                await pane.settle(16)
                if scene.editing {
                    pane.model.editQueued("q2", sessionID: pane.session.id)
                    try await eventually("The edit never opened") { pane.session.queueEditingID == "q2" }
                }
                if scene.heldElsewhere {
                    _ = try await pane.edits.handler(pane.session)("queue.edit.begin", pane.session.id, ["turnId": .string("q0"), "editId": .string("left")])
                    pane.session.adoptQueueEditHold(QueueEditHold(["editId": .string("left"), "turnId": .string("q0")]), revision: pane.edits.revision)
                }
                pane.session.queueCollapsed = scene.collapsed
                await pane.settle(40)
                XCTAssertEqual(pane.window.frame.height, pane.window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: scene.width, height: 600)).height, accuracy: 0.5,
                               "\(scene.name): the window keeps its size")
                if pane.window.frame.height > 700 {
                    func dump(_ v: NSView, _ depth: Int) { if v.frame.height > 650 && depth < 40 { FileHandle.standardError.write("GROW \(depth) \(type(of: v)) \(v.frame)\n".data(using: .utf8)!) }; for c in v.subviews { dump(c, depth + 1) } }
                    dump(pane.hosted, 0)
                }
                let field = try XCTUnwrap(ConversationPaneTests.views(ComposerTextView.self, in: pane.hosted).first?.enclosingScrollView)
                if let list = ConversationPaneTests.views(NSScrollView.self, in: pane.hosted).first(where: { $0 is QueueListScrollView }) {
                    XCTAssertFalse(scene.collapsed, "\(scene.name): a collapsed panel shows no rows")
                    XCTAssertLessThanOrEqual(list.frame.height, QueuePanel.visibleRows * QueuePanel.rowHeight + 2 * QueuePanel.sectionHeaderHeight + 0.5, scene.name)
                    XCTAssertFalse(list.convert(list.bounds, to: nil).intersects(field.convert(field.bounds, to: nil)), "\(scene.name): the queue covers the composer")
                } else {
                    XCTAssertTrue(scene.collapsed, "\(scene.name): the rows are missing")
                }
                if let folder {
                    let view = try XCTUnwrap(pane.window.contentView)
                    let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: image)
                    try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("\(scene.name)-\(suffix).png"))
                }
            }
        }
    }
}
