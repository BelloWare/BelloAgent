import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import PiApp

/// Uses the 13 previews shown by the released gallery's 07 Search sheet.
/// Initial lazy estimates are recorded independently from the complete
/// document after every row has been visited. All sizing checks use the
/// original lazy layout, rather than an eager replacement or added padding.
@MainActor final class ConversationResultsGeometryTests: XCTestCase, SerialTestLane {
    override func setUp() async throws { PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws { PiKit.Motion.reducedOverride = nil }

    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }
    private func mount(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: ConversationContentView.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = view; window.orderFront(nil); window.makeFirstResponder(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil); window.contentView = nil; window.close() }
        return window
    }
    private struct Snapshot: Equatable {
        let width: CGFloat, clipWidth: CGFloat, clipHeight: CGFloat, documentHeight: CGFloat, origin: CGFloat, knob: CGFloat
        @MainActor init(_ scroll: NSScrollView) {
            width = scroll.bounds.width; clipWidth = scroll.contentView.bounds.width; clipHeight = scroll.contentView.bounds.height
            documentHeight = scroll.documentView?.frame.height ?? 0
            let visible = scroll.documentView?.convert(scroll.contentView.bounds, from: scroll.contentView) ?? .zero
            origin = scroll.documentView?.isFlipped == false ? documentHeight - visible.maxY : visible.minY
            knob = scroll.verticalScroller?.knobProportion ?? 0
        }
        var record: [String: Double] {
            ["width": Double(width), "clipWidth": Double(clipWidth), "clipHeight": Double(clipHeight),
             "documentHeight": Double(documentHeight), "origin": Double(origin), "knobProportion": Double(knob)]
        }
    }
    private func settle(_ root: NSView, window: NSWindow, scroll: NSScrollView, phase: String,
                        ready: () -> Bool = { true }) async throws -> Snapshot {
        var previous: Snapshot?, stable = 0
        try await eventually("Conversation results geometry settles at \(phase)", timeout: .seconds(5), poll: .milliseconds(40)) {
            root.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
            let current = Snapshot(scroll)
            stable = previous == current ? stable + 1 : 0; previous = current
            return ready() && current.documentHeight > current.clipHeight && stable >= 3
        }
        return try XCTUnwrap(previous)
    }
    private func scroll(_ scroll: NSScrollView, toBottom: Bool) {
        guard let document = scroll.documentView else { return }
        let travel = max(0, document.frame.height - scroll.contentView.bounds.height)
        let y = document.isFlipped == toBottom ? travel : 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func collect(_ list: LazyStackView, into rows: inout [String: CGRect]) {
        guard let document = list.documentView else { return }
        for cell in views(ConversationHitRow.self, in: list) { rows[cell.hit.id] = cell.convert(cell.bounds, to: document) }
    }
    private func record(_ kind: String, phase: String, snapshot: Snapshot, rows: [String: CGRect], window: NSWindow) throws {
        let frames = Dictionary(uniqueKeysWithValues: rows.map { id, rect in
            (id, [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)])
        })
        let data = try JSONSerialization.data(withJSONObject: ["scroll": snapshot.record, "rows": frames], options: [.sortedKeys])
        print("CONVERSATION-RESULTS " + kind + " " + phase + " " + String(decoding: data, as: UTF8.self))
        if let path = testEnvironment("PI_COMPONENT_GALLERY"), !path.isEmpty {
            let folder = URL(fileURLWithPath: path).appendingPathComponent("conversation-results-geometry")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = kind + "-" + phase
            try data.write(to: folder.appendingPathComponent(name + ".json"))
            let image = try PiKitParity.windowImage(window)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
        }
    }

    func testGalleryConversationResultsRetainEveryRowAndTheCompleteDocumentHeight() async throws {
        let root = scratchRoot("conversation-results-geometry")
        let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        addTeardownBlock { @MainActor in model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let hits = Self.galleryPreviews.enumerated().map { ContentHit(id: "gallery-\($0.offset + 1)", position: $0.offset + 1, preview: $0.element) }
        let result = ContentSearch(hits: hits, total: hits.count, next: nil, revision: "gallery-07")
        let source = ConversationContentSource(search: { _, _ in result }, page: { _, _, _, _ in .init(text: "", next: nil) }, reveal: { _ in })
        let native = ConversationContentView(model: model, sessionID: "gallery", source: source)
        let nativeWindow = mount(native)
        let list = try XCTUnwrap(views(LazyStackView.self, in: native).first)
        list.scrollerStyle = .legacy
        var nativeRows: [String: CGRect] = [:]
        let nativeInitial = try await settle(native, window: nativeWindow, scroll: list, phase: "native-initial") {
            native.copyAll.isEnabled && list.madeView(for: hits[0].id) != nil
        }
        collect(list, into: &nativeRows)
        try record("native", phase: "initial", snapshot: nativeInitial, rows: nativeRows, window: nativeWindow)
        for (index, hit) in hits.enumerated() {
            list.scrollToRowCentred(index)
            _ = try await settle(native, window: nativeWindow, scroll: list, phase: "native-realize-\(hit.position)") {
                list.madeView(for: hit.id) != nil
            }
            collect(list, into: &nativeRows)
        }
        scroll(list, toBottom: true)
        let nativeBottom = try await settle(native, window: nativeWindow, scroll: list, phase: "native-bottom")
        collect(list, into: &nativeRows)
        try record("native", phase: "bottom", snapshot: nativeBottom, rows: nativeRows, window: nativeWindow)

        let geometry = ConversationResultsReferenceGeometry()
        let frozen = NSHostingView(rootView: ConversationContentReference(model: model, sessionID: "gallery", source: source, geometry: geometry)
            .environment(\.piReduceMotion, true))
        let frozenWindow = mount(frozen)
        try await eventually("The frozen conversation results scroll view is mounted", timeout: .seconds(5)) {
            frozen.layoutSubtreeIfNeeded(); return !self.views(NSScrollView.self, in: frozen).isEmpty
        }
        let oldList = try XCTUnwrap(views(NSScrollView.self, in: frozen).max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        oldList.scrollerStyle = .legacy
        let oldInitial = try await settle(frozen, window: frozenWindow, scroll: oldList, phase: "frozen-initial") {
            geometry.rows[hits[0].id] != nil
        }
        try record("frozen-v119", phase: "initial", snapshot: oldInitial, rows: geometry.rows, window: frozenWindow)
        for hit in hits {
            geometry.targetID = hit.id
            _ = try await settle(frozen, window: frozenWindow, scroll: oldList, phase: "frozen-realize-\(hit.position)") {
                geometry.rows[hit.id] != nil
            }
        }
        // The last target centers its row. Go to the actual bottom so the
        // thumb and document are measured after the last padding is visible.
        scroll(oldList, toBottom: true)
        let oldBottom = try await settle(frozen, window: frozenWindow, scroll: oldList, phase: "frozen-bottom")
        let oldRows = geometry.rows
        try record("frozen-v119", phase: "bottom", snapshot: oldBottom, rows: oldRows, window: frozenWindow)
        scroll(oldList, toBottom: false)
        let oldTop = try await settle(frozen, window: frozenWindow, scroll: oldList, phase: "frozen-returned-top")
        try record("frozen-v119", phase: "returned-top", snapshot: oldTop, rows: geometry.rows, window: frozenWindow)

        XCTAssertEqual(Set(nativeRows.keys), Set(hits.map(\.id)), "Every native retained result remains reachable")
        XCTAssertEqual(Set(oldRows.keys), Set(hits.map(\.id)), "Every original retained result was realized")
        XCTAssertEqual(nativeInitial.width, oldBottom.width, accuracy: 0.5)
        XCTAssertEqual(nativeInitial.clipWidth, oldBottom.clipWidth, accuracy: 0.5)
        XCTAssertEqual(nativeInitial.clipHeight, oldBottom.clipHeight, accuracy: 0.5)
        XCTAssertEqual(nativeInitial.documentHeight, oldBottom.documentHeight, accuracy: 0.5, "The original complete document is retained")
        XCTAssertEqual(nativeInitial.knob, oldBottom.knob, accuracy: 0.001, "The native thumb matches the original resolved document")
        XCTAssertEqual(nativeBottom.documentHeight, nativeInitial.documentHeight, accuracy: 0.5)
        for hit in hits {
            let expected = try XCTUnwrap(oldRows[hit.id]), actual = try XCTUnwrap(nativeRows[hit.id])
            XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, "Message \(hit.position) leading position")
            XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, "Message \(hit.position) complete position")
            XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, "Message \(hit.position) width")
            XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, "Message \(hit.position) height, including trailing newlines and an empty preview")
        }
        print("CONVERSATION-LAZY-ESTIMATE initialHeight=\(oldInitial.documentHeight) resolvedHeight=\(oldBottom.documentHeight) returnedTopHeight=\(oldTop.documentHeight) nativeHeight=\(nativeInitial.documentHeight) initialKnob=\(oldInitial.knob) resolvedKnob=\(oldBottom.knob) returnedTopKnob=\(oldTop.knob)")
    }

    // Filled from the saved 0.1.119 synthetic gallery's first 13 shown rows.
    // Keep the original 240-byte preview boundaries and whitespace intact.
    private static let galleryPreviews: [String] = [
        "Please read fixture README.md first, then explain what the retry loop in PaymentClient does today.",
        "Request completed\n\nTimeline evidence: observed\n\n[toolArguments · 105BA45D-0B05-417E-8CD6-CCDE6029A828 / fc_f95a3e996c884adfbdcc85859660ca41 / 0 · observed]\n{\"path\":\"README.md\"}\n\n[completed]",
        "",
        "Tool started · read\n\nTimeline evidence: local\n\n[status · 105BA45D-0B05-417E-8CD6-CCDE6029A828 / 24C9C14E-E1C5-458D-B9F4-9DFC53AFD24D / 0 · local]\nInvocation started: read\n\n[recorded]",
        "Synthetic UI fixture file: read-tool round trip verified.\n",
        "Request completed\n\nTimeline evidence: observed\n\n[text · FDF9E4DD-5E9C-444F-B55E-21B79D295CAB / msg_b837cbc869db41f5983ba935da963e64 / 0 · observed]\nFixture read completed. The native helper returned the local README contents.\n\n[completed]",
        "Fixture read completed. The native helper returned the local README contents.",
        "Here is the loop I want to harden:\n\n```swift\nfunc charge(_ order: Order) async throws -> Receipt {\n    for attempt in 1...3 {\n        if let receipt = try? await gateway.charge(order) { return receipt }\n    }\n    throw PaymentError.exhauste",
        "Request completed\n\nTimeline evidence: observed\n\n[text · 3A600ADF-7034-4094-8BDC-0B093A496F2D / msg_70c2c7d1b05c43a7be92f41da12aa918 / 0 · observed]\nFixture reply: Here is the loop I want to harden:\n\n```swift\nfunc charge(_ order: Order) as",
        "Fixture reply: Here is the loop I want to harden:\n\n```swift\nfunc charge(_ order: Order) async throws -> Receipt {\n    for attempt in 1...3 {\n        if let receipt = try? await gateway.charge(order) { return receipt }\n    }\n    throw Paymen",
        "Summarize the plan in one line.",
        "Request completed\n\nTimeline evidence: observed\n\n[text · 7F6E8DB5-5DC3-4C7A-A236-927DF3FE8FD5 / msg_f106fdee8f974a079eedf677182981d1 / 0 · observed]\nFixture reply: Summarize the plan in one line.\n\nUnicode: 中文🙂 café.\n\n[completed]",
        "Fixture reply: Summarize the plan in one line.\n\nUnicode: 中文🙂 café."
    ]
}
