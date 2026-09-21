import XCTest
import SwiftUI
@testable import PiApp

final class TranscriptGeometryCacheTests: XCTestCase {
    private func item(_ id: String, text: String = "Exact immutable text") -> TranscriptItem {
        .message(TranscriptMessage(id: id, role: "user", text: text))
    }

    @MainActor func testEveryGeometryInputAndSessionIdentityMustMatch() {
        let cache = TranscriptGeometryCache()
        let original = item("row")
        let environment = TranscriptRowEnvironment()
        let size = CGSize(width: 700, height: 112)
        cache.store(size, sessionID: "session", item: original, fresh: false, environment: environment, backingScale: 2)
        XCTAssertEqual(cache.measurement(sessionID: "session", item: original, fresh: false, environment: environment, width: 700, backingScale: 2), size)
        XCTAssertNil(cache.measurement(sessionID: "fork", item: original, fresh: false, environment: environment, width: 700, backingScale: 2))
        XCTAssertNil(cache.measurement(sessionID: "session", item: original, fresh: false, environment: environment, width: 500, backingScale: 2))
        XCTAssertNil(cache.measurement(sessionID: "session", item: original, fresh: false, environment: environment, width: 700, backingScale: 1))
        XCTAssertNil(cache.measurement(sessionID: "session", item: original, fresh: true, environment: environment, width: 700, backingScale: 2))
        cache.store(size, sessionID: "session", item: original, fresh: false, environment: environment, backingScale: 2)
        var changed = environment; changed.dynamicTypeSize = .accessibility3
        XCTAssertNil(cache.measurement(sessionID: "session", item: original, fresh: false, environment: changed, width: 700, backingScale: 2))
        cache.store(size, sessionID: "session", item: original, fresh: false, environment: environment, backingScale: 2)
        XCTAssertNil(cache.measurement(sessionID: "session", item: item("row", text: "Updated while hidden"), fresh: false, environment: environment, width: 700, backingScale: 2))
    }

    @MainActor func testCountPayloadAndSingleEntryLimitsRetireOldMeasurements() {
        let cache = TranscriptGeometryCache(countLimit: 2, byteLimit: 3_000, entryByteLimit: 2_000)
        let environment = TranscriptRowEnvironment()
        let size = CGSize(width: 700, height: 112)
        for id in ["one", "two"] { cache.store(size, sessionID: "session", item: item(id), fresh: false, environment: environment, backingScale: 2) }
        XCTAssertEqual(cache.count, 2)
        _ = cache.measurement(sessionID: "session", item: item("one"), fresh: false, environment: environment, width: 700, backingScale: 2)
        cache.store(size, sessionID: "session", item: item("three"), fresh: false, environment: environment, backingScale: 2)
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.measurement(sessionID: "session", item: item("two"), fresh: false, environment: environment, width: 700, backingScale: 2))
        XCTAssertNotNil(cache.measurement(sessionID: "session", item: item("one"), fresh: false, environment: environment, width: 700, backingScale: 2))
        let oversized = item("one", text: String(repeating: "large ", count: 1_000))
        cache.store(size, sessionID: "session", item: oversized, fresh: false, environment: environment, backingScale: 2)
        XCTAssertEqual(cache.count, 1, "A now-oversized row must retire its old baseline rather than retain stale geometry")
        XCTAssertNil(cache.measurement(sessionID: "session", item: oversized, fresh: false, environment: environment, width: 700, backingScale: 2))
        XCTAssertLessThanOrEqual(cache.byteCost, cache.byteLimit)
        let metadataHeavy = TranscriptItem.message(TranscriptMessage(id: "metadata", role: "user", text: "Small body",
            accounting: GatewayTotals(models: GatewayModelSummary(names: [String(repeating: "model", count: 1_000)]))))
        cache.store(size, sessionID: "session", item: metadataHeavy, fresh: false, environment: environment, backingScale: 2)
        XCTAssertEqual(cache.count, 1, "Variable-sized accounting/model metadata is part of the payload budget")
        let byteBounded = TranscriptGeometryCache(countLimit: 50, byteLimit: 2_500, entryByteLimit: 2_000)
        for index in 0..<10 { byteBounded.store(size, sessionID: "session", item: item("row-\(index)"), fresh: false, environment: environment, backingScale: 2) }
        XCTAssertLessThanOrEqual(byteBounded.count, 2)
        XCTAssertLessThanOrEqual(byteBounded.byteCost, 2_500)
    }

    @MainActor func testLiveOutputAndLocallyExpandableRowsNeverShareTheirMeasurements() {
        let cache = TranscriptGeometryCache()
        let tool = ToolView(id: "tool", name: "read", state: "completed", input: "{}", output: "A locally expanded tool result.", durationMs: 3, truncated: false)
        let messages = [TranscriptMessage(id: "tool-reply", role: "assistant", text: "Done", tools: [tool]),
                        TranscriptMessage(id: "reasoning-reply", role: "assistant", text: "Done", thinking: "Exposed reasoning"),
                        TranscriptMessage(id: "stream:reply", role: "assistant", text: "Still changing", state: "streaming")]
        var items = messages.flatMap { TranscriptActivity.blocks(of: [$0]) }
        items.append(.message(TranscriptMessage(id: "compaction", role: "system", text: "Expandable summary", kind: "compaction")))
        var immutableBodies = 0
        for item in items {
            let plainBody: Bool
            if case .block(let block) = item { plainBody = block.presentation == .body && !block.live }
            else { plainBody = false }
            XCTAssertEqual(TranscriptGeometryCache.permits(item), plainBody)
            if plainBody { immutableBodies += 1 }
            cache.store(CGSize(width: 700, height: 10_000), sessionID: "session", item: item, fresh: false, environment: TranscriptRowEnvironment(), backingScale: 2)
        }
        XCTAssertEqual(immutableBodies, 2, "Separated settled prose can share its exact geometry")
        XCTAssertEqual(cache.count, immutableBodies, "Local tool/reasoning/compaction heights cannot leak into another pane")
    }

    @MainActor func testTimelineDisclosureGeometryAndEvidenceStayWithinCacheContract() {
        let cache = TranscriptGeometryCache(countLimit: 20, byteLimit: 4_000, entryByteLimit: 3_000)
        let timeline = ResponseTimeline.canonical([
            (kind: "text", text: "Plain response", callID: nil, name: nil),
            (kind: "reasoningSummary", text: "Expandable reasoning", callID: nil, name: nil),
            (kind: "toolArguments", text: "{}", callID: "call", name: "read")], sourceID: "r")
        var response = TranscriptMessage(id: "r", role: "assistant", text: "Plain response")
        response.responseTimeline = timeline
        let parts = TaskTranscriptPlan.items([response], lifecycle: nil).filter {
            if case .block(let block) = $0 { return block.part != nil }; return false
        }
        for item in parts {
            guard case .block(let block) = item else { continue }
            XCTAssertEqual(TranscriptGeometryCache.permits(item), block.part?.part.kind == "text")
            cache.store(CGSize(width: 600, height: 100), sessionID: "s", item: item, fresh: false, environment: .init(), backingScale: 2)
        }
        XCTAssertEqual(cache.count, 1)
        for kind in ["execution", "toolResult", "compaction"] {
            XCTAssertFalse(TranscriptGeometryCache.permits(.message(.init(id: kind, role: "system", text: "Details", kind: kind))))
        }
        if case .block(var heavy) = parts[0] {
            heavy.part?.part.itemID = String(repeating: "large-id", count: 1_000)
            cache.store(CGSize(width: 600, height: 100), sessionID: "s", item: .block(heavy), fresh: false, environment: .init(), backingScale: 2)
            XCTAssertEqual(cache.count, 0, "Retained timeline metadata participates in the payload limit")
        }
    }

    @MainActor private final class Fixture {
        let window: NSWindow
        let scroll = TranscriptNativeScrollView()
        let page = TranscriptPage()
        let document: TranscriptNativeDocument
        init(session: SessionDisplay, cache: TranscriptGeometryCache, width: CGFloat = 760, environment: TranscriptRowEnvironment = TranscriptRowEnvironment()) {
            page.bind(session)
            document = TranscriptNativeDocument(page: page, geometryCache: cache)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            scroll.documentView = document; window.contentView = scroll; window.makeKeyAndOrderFront(nil)
            document.update(snapshot: page.snapshot, actions: TranscriptActions(), environment: environment)
        }
        func close() { window.contentView = nil; window.close() }
        func settle(until condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while ProcessInfo.processInfo.systemUptime < deadline {
                scroll.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Native warm-row geometry did not settle")
        }
    }

    @MainActor private func session(_ id: String) -> SessionDisplay {
        let session = SessionDisplay(id: id)
        session.messages = (0..<50).map { index in
            TranscriptMessage(id: "m\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant",
                              text: "Row \(index). " + String(repeating: "Selectable **native** prose with a useful amount of exact content. ", count: 8),
                              turn: "m\(index - index % 2)")
        }
        return session
    }

    @MainActor func testWarmDocumentReusesExactFramesAndRemeasuresAnAnswerChangedWhileHidden() async throws {
        let cache = TranscriptGeometryCache()
        let session = session("warm-exact-frames")
        let cold = Fixture(session: session, cache: cache)
        try await cold.settle { cold.document.retainedRows.count == 50 && cache.count >= 50 }
        let original = Dictionary(uniqueKeysWithValues: cold.document.retainedRows.map { ($0.itemID, $0.frame) })
        cold.close()
        session.messages[49].text += String(repeating: "\n\nA new paragraph generated while this tab was hidden.", count: 10)
        session.scrollAnchor = TranscriptAnchor(id: "m20", offset: -9, followsBottom: false)
        let warm = Fixture(session: session, cache: cache)
        defer { warm.close() }
        try await warm.settle {
            guard let anchor = warm.page.rowFrame(of: "m20"), let last = warm.document.retainedRows.last else { return false }
            return last.frame.height > (original[last.itemID]?.height ?? 0) && abs(warm.scroll.contentView.bounds.minY - anchor.minY - 9) < 1
        }
        XCTAssertGreaterThanOrEqual(warm.document.retainedRows.reduce(0) { $0 + $1.sharedMeasurementHits }, 49)
        XCTAssertGreaterThan(warm.document.retainedRows.filter { $0.measurementCount == 0 && $0.superview == nil }.count, 35,
                             "Warm history must not mount and remeasure every unchanged native text tree")
        for row in warm.document.retainedRows.dropLast() {
            XCTAssertEqual(row.frame, original[row.itemID], "Shared baseline keeps the exact original row/anchor positions")
        }
        XCTAssertGreaterThan(try XCTUnwrap(warm.document.retainedRows.last).measurementCount, 0,
                             "The answer changed while hidden must be laid out from its new content")
    }

    @MainActor func testWarmGeometryDoesNotCrossViewportWidthOrRenderingEnvironment() async throws {
        let cache = TranscriptGeometryCache()
        let session = session("warm-width-environment")
        let cold = Fixture(session: session, cache: cache)
        try await cold.settle { cache.count >= 50 }
        let originalHeight = try XCTUnwrap(cold.document.retainedRows.first).frame.height
        cold.close()
        let narrow = Fixture(session: session, cache: cache, width: 450)
        try await narrow.settle { narrow.document.retainedRows.count == 50 && (narrow.document.retainedRows.first?.frame.height ?? 0) > originalHeight }
        XCTAssertEqual(narrow.document.retainedRows.reduce(0) { $0 + $1.sharedMeasurementHits }, 0)
        narrow.close()
        var environment = TranscriptRowEnvironment(); environment.isEnabled = false
        let changed = Fixture(session: session, cache: cache, environment: environment)
        defer { changed.close() }
        try await changed.settle { changed.document.retainedRows.count == 50 && (changed.document.retainedRows.last?.frame.height ?? 0) > 0 }
        XCTAssertEqual(changed.document.retainedRows.reduce(0) { $0 + $1.sharedMeasurementHits }, 0,
                       "A differently rendered or disabled pane must not borrow another environment's geometry")
    }
}
