import AppKit
import XCTest
@testable import PiApp

/// Generated retained captures, with the same refresh and copy controls as Raw.
@MainActor final class InspectorStorageTests: XCTestCase, SerialTestLane {
    private func fixture(withHeaders: Bool = true) async throws -> (URL, PayloadArchive, SessionInspectorModel, InspectorRawTab, NSWindow) {
        let root = scratchRoot("inspector-storage")
        let archive = PayloadArchive(root: root)
        try await archive.configure(quota: 8_388_608, bodyRetention: 86400, metricRetention: 86400)
        let id = UUID().uuidString, now = Date().timeIntervalSince1970
        let request = InspectorRequestModelTests.requestBody(2), response = InspectorRequestModelTests.stream(2, finished: true)
        var metadata: [String: WireValue] = ["attemptId": .string(id), "sessionId": .string("session"), "turnId": .string("turn"),
            "purpose": .string("turn"), "api": .string("openai-responses"), "requestedModel": .string("fixture"),
            "mode": .string("persist"), "outcome": .string("completed"), "wallTimestamp": .number(now),
            "timingVersion": .number(2), "timings": .object(["dispatch": .number(1)]),
            "requestHeaders": .object(["authorization": .string("Bearer ********-key"), "content-type": .string("application/json")]),
            "responseHeaders": .object(["content-type": .string("text/event-stream"), "x-request-id": .string("generated-request")])]
        if !withHeaders { metadata["requestHeaders"] = .object([:]); metadata["responseHeaders"] = .object([:]) }
        metadata["gateway"] = .object(["version": .number(1), "cost": .object(["status": .string("reported"), "usd": .number(1e-300)])])
        try await archive.begin(metadata, workspace: "project")
        try await archive.append(attempt: id, kind: "request", offset: 0, bytes: request)
        try await archive.append(attempt: id, kind: "response", offset: 0, bytes: response)
        metadata["request"] = .object(["observedBytes": .number(Double(request.count))])
        metadata["response"] = .object(["observedBytes": .number(Double(response.count))])
        try await archive.finish(metadata)
        let inspector = SessionInspectorModel(scope: .init(sessionID: "session", workspaceID: "project"), title: "Generated capture", archive: archive, workspace: nil,
                                              usageLoader: { _, _, _ in throw CaptureFailure.unavailable }, cache: InspectorDocumentCache())
        inspector.setVisible(true)
        try await eventually("the retained request index") { inspector.index.request(id) != nil }
        inspector.select(.request(id))
        try await eventually("the parsed request") { inspector.request.conversation.value != nil }
        inspector.request.tab = .response
        try await eventually("the parsed response") { inspector.request.response.value != nil }
        inspector.request.tab = .raw
        let raw = InspectorRawTab(inspector: inspector, request: inspector.request, compact: false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = raw; window.orderFront(nil)
        try await eventually("the retained raw body") { self.copyButton(raw)?.isEnabled == true }
        return (root, archive, inspector, raw, window)
    }
    private func copyButton(_ raw: InspectorRawTab) -> PiKit.ButtonBase? {
        InspectorExpandFixture.descendants(PiKit.ButtonBase.self, in: raw).first { $0.accessibilityIdentifier() == "inspector-raw-copy" }
    }
    private func close(_ fixture: (URL, PayloadArchive, SessionInspectorModel, InspectorRawTab, NSWindow)) async {
        fixture.2.setVisible(false); fixture.4.close()
        try? await fixture.1.close(); try? FileManager.default.removeItem(at: fixture.0)
    }

    func testClearThenRefreshRetiresLoadedBodiesWithoutNavigation() async throws {
        let fixture = try await fixture(), archive = fixture.1, inspector = fixture.2, raw = fixture.3
        addTeardownBlock { @MainActor in await self.close(fixture) }
        let copy = try XCTUnwrap(copyButton(raw))
        NSPasteboard.general.clearContents(); copy.performClick(nil)
        try await eventually("the captured body copy") { NSPasteboard.general.string(forType: .string)?.contains("message 0") == true }
        try await archive.clear(sessionID: "session")
        inspector.refresh()
        try await eventually("the purged descriptor") { inspector.request.metadata["request"]?.object?["state"]?.string == "purged" }
        XCTAssertEqual(inspector.request.metadata["request"]?.object?["retainedBytes"]?.number, 0)
        XCTAssertEqual(inspector.request.metadata["response"]?.object?["state"]?.string, "purged")
        XCTAssertEqual(inspector.request.metadata["response"]?.object?["retainedBytes"]?.number, 0)
        XCTAssertNil(inspector.request.conversation.value); XCTAssertNil(inspector.request.response.value)
        try await eventually("the purged copy source") { !copy.isEnabled }
        XCTAssertNil(InspectorExpandFixture.descendants(CapturedBodyView.self, in: raw).first?.controller.document)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("after clear", forType: .string)
        copy.performClick(nil)
        await Task.yield()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "after clear")
        inspector.request.raw = .response; raw.refresh()
        XCTAssertFalse(copy.isEnabled, "The other body must not restore its old copy source")
    }

    func testRefreshPreservesAnUnchangedRawDocumentAndFormat() async throws {
        let fixture = try await fixture(), inspector = fixture.2, raw = fixture.3
        addTeardownBlock { @MainActor in await self.close(fixture) }
        let body = try XCTUnwrap(InspectorExpandFixture.descendants(CapturedBodyView.self, in: raw).first)
        body.setFormat(.hex)
        let document = try XCTUnwrap(body.controller.document?.id)
        let reads = inspector.indexReads
        inspector.refresh()
        try await eventually("the explicit refresh") { inspector.indexReads > reads && inspector.request.metadataLoaded }
        raw.refresh()
        let refreshed = try XCTUnwrap(InspectorExpandFixture.descendants(CapturedBodyView.self, in: raw).first)
        XCTAssertTrue(refreshed === body)
        XCTAssertEqual(refreshed.format, .hex)
        XCTAssertEqual(refreshed.controller.document?.id, document)
    }

    func testACopyAlreadyRenderingCannotPublishAfterClear() async throws {
        let fixture = try await fixture(), archive = fixture.1, inspector = fixture.2, raw = fixture.3
        addTeardownBlock { @MainActor in await self.close(fixture) }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let held = Task {
            try await CapturedBodyWorker.shared.run { entered.signal(); release.wait() }
        }
        defer { release.signal() }
        try await eventually("the held copy worker") { entered.wait(timeout: .now()) == .success }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("after clear", forType: .string)
        try XCTUnwrap(copyButton(raw)).performClick(nil)
        await Task.yield()
        try await archive.clear(sessionID: "session"); inspector.request.capturesCleared(); inspector.refresh()
        release.signal(); try await held.value
        try await CapturedBodyWorker.shared.run { }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "after clear")
    }

    func testHeadersCopyIncludesBothDisplayedMaskedSections() async throws {
        let fixture = try await fixture(), inspector = fixture.2, raw = fixture.3
        addTeardownBlock { @MainActor in await self.close(fixture) }
        inspector.request.raw = .headers; raw.refresh()
        let headers = InspectorExpandFixture.descendants(CapturedHeadersView.self, in: raw)
        XCTAssertEqual(headers.count, 2)
        let copy = try XCTUnwrap(copyButton(raw)); XCTAssertTrue(copy.isEnabled)
        NSPasteboard.general.clearContents(); copy.performClick(nil)
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(text.contains("Request headers")); XCTAssertTrue(text.contains("Response headers"))
        for section in headers { XCTAssertTrue(text.contains(section.text), "Missing displayed headers: \(section.text)") }
        XCTAssertTrue(text.contains("authorization: Bearer ********-key"))
    }
    func testEmptyHeadersDoNotEnableCopyFromUnrelatedMetadata() async throws {
        let fixture = try await fixture(withHeaders: false), inspector = fixture.2, raw = fixture.3
        addTeardownBlock { @MainActor in await self.close(fixture) }
        inspector.request.raw = .headers; raw.refresh()
        XCTAssertFalse(inspector.request.metadataText.isEmpty)
        XCTAssertFalse(try XCTUnwrap(copyButton(raw)).isEnabled)
    }

    func testEmptyLinksDoNotEnableCopyFromUnrelatedMetadata() async throws {
        let fixture = try await fixture(), inspector = fixture.2, raw = fixture.3
        addTeardownBlock { @MainActor in await self.close(fixture) }
        inspector.request.raw = .links; raw.refresh()
        let copy = try XCTUnwrap(copyButton(raw))
        try await eventually("empty links disable Copy", timeout: .seconds(2)) { !copy.isEnabled }
    }

    func testGalleryHeadersPurgedBodiesAndTinyCost() async throws {
        guard let path = testEnvironment("PI_APP_INSPECTOR_STORAGE_GALLERY") else { throw XCTSkip("Set PI_APP_INSPECTOR_STORAGE_GALLERY") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try await fixture(), archive = fixture.1, inspector = fixture.2, raw = fixture.3, window = fixture.4
        addTeardownBlock { @MainActor in await self.close(fixture) }
        let canvas = FillView(.piContent)
        window.contentView = canvas; canvas.addSubview(raw)
        raw.autoresizingMask = [.width, .height]; raw.frame = canvas.bounds
        let now = Date(), filter = DashboardFilter(from: now.addingTimeInterval(-60), until: now.addingTimeInterval(60), bucketCount: 2)
        let report = try await archive.dashboard(filter)
        let chart = PiChartView(spec: ReportChartSpec.make(buckets: report.buckets, metric: .cost, latency: .firstToken, domain: filter.from...filter.until))
        for scene in ["headers", "purged"] {
            if scene == "purged" {
                try await archive.clear(sessionID: "session"); inspector.refresh()
                try await eventually("gallery purge") { inspector.request.metadata["request"]?.object?["state"]?.string == "purged" }
            }
            inspector.request.raw = scene == "headers" ? .headers : .request; raw.refresh()
            if scene == "purged" {
                try await eventually("the unavailable body notice") {
                    InspectorExpandFixture.descendants(CapturedBodyView.self, in: raw).first?.controller.notice.contains("purged") == true
                }
            }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                for width in [1000, 700] {
                    raw.compact = width == 700
                    window.setContentSize(NSSize(width: width, height: 600)); raw.refresh()
                    try capture(canvas, to: folder.appendingPathComponent("\(scene)-\(name)-\(width).png"))
                }
            }
        }
        raw.removeFromSuperview(); canvas.addSubview(chart)
        chart.autoresizingMask = [.width, .height]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            for width in [1000, 700] {
                window.setContentSize(NSSize(width: width, height: 300))
                chart.frame = canvas.bounds.insetBy(dx: 24, dy: 24)
                try capture(canvas, to: folder.appendingPathComponent("cost-\(name)-\(width).png"))
            }
        }
    }

    private func capture(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded(); view.window?.displayIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
    }

}
