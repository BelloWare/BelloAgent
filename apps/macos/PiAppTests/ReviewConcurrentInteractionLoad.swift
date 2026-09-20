import AppKit
import SwiftUI
import XCTest
@testable import PiApp

/// Opt-in visual load for the real 20-session loopback/capture integration.
/// Retained native history is synthetic; gateway traffic, tools and capture
/// verification remain the integration's real request-aware paths.
@MainActor final class ReviewConcurrentInteractionLoad {
    let window: NSWindow
    let hosted: NSHostingView<WorkspaceView>
    let inspector: NSWindow
    private let model: WorkspaceModel
    private var seeded: Set<String> = []
    private var steps = 0
    private var costs: [Double] = []
    private var resizeCosts: [Double] = []
    private weak var editor: ComposerTextView?
    var composingSessionID: String? { editor?.sessionID }

    init(model: WorkspaceModel, json: CapturedJSON) throws {
        self.model = model
        let main = try XCTUnwrap(model.chats.first), side = try XCTUnwrap(model.chats.dropFirst().first)
        model.sides[main.id] = SideRecord(id: side.id, parentID: main.id, workspaceID: side.workspaceID,
                                          profileID: side.profileID, title: "Concurrent side", kept: true)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1460, height: 850), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        inspector = NSWindow(contentRect: NSRect(x: 1400, y: 0, width: 650, height: 600), styleMask: [.titled],
                             backing: .buffered, defer: false)
        inspector.isReleasedWhenClosed = false
        inspector.contentView = NSHostingView(rootView: JSONOutlineView(json: json, selection: .constant(""),
                                                                       expandRevision: 0, expandAll: false))
        inspector.orderFront(nil)
    }
    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }
    func step() throws {
        let started = ProcessInfo.processInfo.systemUptime
        // Keep a paged prefix in the native projection. It is deliberately
        // not inserted into the helper's request/context or durable journal.
        for chat in model.chats.prefix(2) {
            guard let session = model.displays[chat.id], !session.messages.isEmpty,
                  !session.loading, !seeded.contains(chat.id) else { continue }
            let prefix = (0..<300).map { index in
                TranscriptMessage(id: "retained-\(chat.id)-\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant",
                                  text: "## Previous finding \(index)\n\n" + String(repeating: "Keep **native selection** and the reader's place while new results arrive. ", count: 5),
                                  turn: "retained-\(chat.id)-\(index - index % 2)")
            }
            session.messages = prefix + session.messages
            seeded.insert(chat.id)
        }
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded(); inspector.displayIfNeeded()
        if editor == nil {
            editor = descendants(ComposerTextView.self, in: hosted).first { $0.sessionID == model.selectedID }
            if let editor { window.makeFirstResponder(editor) }
        }
        if let editor, model.selected?.loading == false {
            // Compose the next draft without submitting it. The sent fixture
            // prompt and the provider's exact request remain unchanged.
            editor.setMarkedText("输入 \(steps)", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.didChangeText()
        }
        if steps == 5 || steps == 9 {
            let at = ProcessInfo.processInfo.systemUptime
            let documents = descendants(TranscriptNativeDocument.self, in: hosted)
            for document in documents { document.beginLiveResize() }
            window.setContentSize(NSSize(width: steps == 5 ? 1320 : 1460, height: 850))
            hosted.layoutSubtreeIfNeeded()
            for document in documents { document.endLiveResize() }
            window.displayIfNeeded()
            resizeCosts.append((ProcessInfo.processInfo.systemUptime - at) * 1000)
        }
        steps += 1
        costs.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
    }
    func verifyAndClose() {
        defer { window.contentView = nil; window.close(); inspector.contentView = nil; inspector.close() }
        XCTAssertEqual(seeded.count, 2)
        XCTAssertEqual(descendants(TranscriptNativeDocument.self, in: hosted).count, 2)
        XCTAssertTrue(editor?.hasMarkedText() == true, "Arriving content and resize must preserve CJK composition")
        XCTAssertTrue(window.firstResponder === editor)
        let sorted = costs.sorted()
        func p(_ percentile: Double) -> Double { sorted.isEmpty ? 0 : sorted[max(0, Int(ceil(Double(sorted.count) * percentile)) - 1)] }
        print(String(format: "REVIEW combined 20 real streams / two 300-row panes / 2 MiB JSON inspector / marked text: %d iterations p50 %.2f p95 %.2f p99 %.2f max %.2f ms; resize+release %@ ms",
                     steps, p(0.5), p(0.95), p(0.99), sorted.last ?? 0,
                     resizeCosts.map { String(format: "%.2f", $0) }.joined(separator: ", ")))
    }
}
