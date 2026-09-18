import XCTest
import SwiftUI
import WebKit
@testable import PiApp

final class TranscriptRecoveryTests: XCTestCase {
    @MainActor private final class Fixture {
        var status = ""
        let window: NSWindow
        let webView: WKWebView
        var coordinator: TranscriptView.Coordinator!

        init() throws {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 500), configuration: configuration)
            window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            coordinator = TranscriptView.Coordinator(bridgeStatus: Binding(get: { [weak self] in self?.status ?? "" }, set: { [weak self] in self?.status = $0 }), scrollAnchor: nil, sessionID: "recovery-fixture")
            configuration.userContentController.add(coordinator!, name: "transcript")
            coordinator.webView = webView
            coordinator.messages = [.init(id: "first", role: "assistant", text: "Initial rendered reply")]
            webView.navigationDelegate = coordinator
            let root = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("Transcript")
            coordinator.page = root.appendingPathComponent("index.html")
            var page = URLComponents(url: coordinator.page!, resolvingAgainstBaseURL: true)!
            page.fragment = "viewId=\(coordinator.viewID)"
            window.contentView = webView; window.orderFront(nil)
            webView.loadFileURL(page.url!, allowingReadAccessTo: root)
        }

        func stop() {
            coordinator.stopReadingObservation(); coordinator.unbind()
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "transcript")
            webView.navigationDelegate = nil; webView.stopLoading()
            window.contentView = nil; window.close()
        }

        func evaluate(_ script: String) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                webView.evaluateJavaScript(script) { value, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: value as? String ?? "") }
                }
            }
        }

        func send(_ text: String, id: String = UUID().uuidString, role: String = "assistant") {
            coordinator.messages = [.init(id: id, role: role, text: text)]
            coordinator.sendSnapshot()
        }
    }

    @MainActor private func waitFor(_ description: String, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<150 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(description)
    }

    @MainActor func testRenderFailureDoesNotClaimSuccessAndTheNextValidSnapshotRecovers() async throws {
        let fixture = try Fixture(); defer { fixture.stop() }
        try await waitFor("Initial transcript did not paint") { fixture.status.contains("bridge verified") }
        // A DOM creation failure exercises the real React error boundary, not a
        // mocked acknowledgement or a helper returning a preselected result.
        _ = try await fixture.evaluate("""
        window.savedCreateElement = Document.prototype.createElement;
        Document.prototype.createElement = function(name, options) {
          if (name === 'article') throw new Error('fixture render failure');
          return window.savedCreateElement.call(this, name, options);
        };
        'injected'
        """)
        fixture.send("This row cannot render")
        try await waitFor("The native bridge did not expose the render failure") { fixture.status == "Transcript render failed" }
        let fallback = try await fixture.evaluate("document.body.textContent")
        XCTAssertTrue(fallback.contains("The transcript could not be drawn"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.status, "Transcript render failed", "A fallback commit is not a successfully painted transcript")

        _ = try await fixture.evaluate("Document.prototype.createElement = window.savedCreateElement; 'restored'")
        fixture.send("Recovered without reloading")
        try await waitFor("A corrected snapshot remained stuck behind the error boundary") {
            guard fixture.status.contains("bridge verified") else { return false }
            return try await fixture.evaluate("document.body.textContent").contains("Recovered without reloading")
        }
        let restored = try await fixture.evaluate("document.body.textContent")
        XCTAssertFalse(restored.contains("The transcript could not be drawn"))
    }

    @MainActor func testRejectedSnapshotPreservesTheVisiblePageAndAcceptsTheNextValidPage() async throws {
        let fixture = try Fixture(); defer { fixture.stop() }
        try await waitFor("Initial transcript did not paint") { fixture.status.contains("bridge verified") }
        fixture.send("Invalid role should not replace the page", role: "unknown-role")
        try await waitFor("The rejected bridge result was ignored") { fixture.status == "Transcript rejected a page" }
        let retained = try await fixture.evaluate("document.body.textContent")
        XCTAssertTrue(retained.contains("Initial rendered reply")); XCTAssertFalse(retained.contains("Invalid role"))
        fixture.send("Valid replacement after rejection")
        try await waitFor("A rejected page blocked later valid delivery") {
            guard fixture.status.contains("bridge verified") else { return false }
            return try await fixture.evaluate("document.body.textContent").contains("Valid replacement after rejection")
        }
    }

    @MainActor func testContentProcessTerminationReloadsThePackagedPageAndLatestSnapshot() async throws {
        let fixture = try Fixture(); defer { fixture.stop() }
        try await waitFor("Initial transcript did not paint") { fixture.status.contains("bridge verified") }
        let document = try await fixture.evaluate("String(performance.timeOrigin)")
        fixture.coordinator.webViewWebContentProcessDidTerminate(fixture.webView)
        fixture.send("Latest snapshot survives WebKit restart")
        try await waitFor("The content-process failure did not recover") {
            guard fixture.status.contains("bridge verified") else { return false }
            return try await fixture.evaluate("document.body.textContent").contains("Latest snapshot survives WebKit restart")
        }
        let reloaded = try await fixture.evaluate("String(performance.timeOrigin)")
        XCTAssertNotEqual(document, reloaded, "The packaged document must actually be reloaded")
        XCTAssertTrue(TranscriptView.trustedPage(fixture.webView.url, page: fixture.coordinator.page))
    }

    @MainActor func testMalformedToolDurationIsRejectedBeforeItCanThrowDuringRendering() async throws {
        let fixture = try Fixture(); defer { fixture.stop() }
        try await waitFor("Initial transcript did not paint") { fixture.status.contains("bridge verified") }
        let result = try await fixture.evaluate("""
        String(window.piTranscript.apply({v:1,viewId:new URLSearchParams(location.hash.slice(1)).get('viewId'),sessionId:'recovery-fixture',seq:100000,messages:[
          {id:'bad-tool',role:'assistant',text:'',tools:[{id:'call',name:'bash',state:'completed',input:'{}',output:'done',durationMs:'bad',truncated:false}]}
        ]}))
        """)
        XCTAssertEqual(result, "false")
        fixture.send("Valid snapshot after malformed duration")
        try await waitFor("Rejected input advanced the page sequence or broke rendering") {
            return try await fixture.evaluate("document.body.textContent").contains("Valid snapshot after malformed duration")
        }
    }
}
