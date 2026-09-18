import SwiftUI
import WebKit
import Combine

struct TranscriptView: NSViewRepresentable {
    let messages: [TranscriptMessage]
    @Binding var bridgeStatus: String
    var scrollAnchor: Binding<TranscriptAnchor?>? = nil
    var sessionID: String? = nil
    var displayObservedAt: Double? = nil
    var liveSession: SessionDisplay? = nil
    var onInspectRequests: ((String, String) -> Void)? = nil
    var onEditMessage: ((String, String) -> Void)? = nil
    var onReadReply: ((String, String) -> Void)? = nil
    /// The page scrolled near its first row; the caller may prepend the page before it.
    var onLoadEarlier: ((String) -> Void)? = nil
    /// The live turn bar's Stop button.
    var onStop: ((String) -> Void)? = nil
    static func trustedPage(_ url: URL?, page: URL?) -> Bool {
        guard let url, let page else { return false }
        return url.isFileURL && (url.host?.isEmpty ?? true) && url.user == nil && url.password == nil && url.query == nil && url.path == page.path
    }
    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(bridgeStatus: $bridgeStatus, scrollAnchor: scrollAnchor, sessionID: sessionID)
        coordinator.onInspectRequests = onInspectRequests; coordinator.onEditMessage = onEditMessage; coordinator.onReadReply = onReadReply; coordinator.onLoadEarlier = onLoadEarlier; coordinator.onStop = onStop; return coordinator
    }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "transcript")
        let view = WKWebView(frame: .zero, configuration: configuration)
        // The page paints no canvas of its own so the native pane background
        // shows through in both appearances; the private setter is probed first.
        if view.responds(to: NSSelectorFromString("_setDrawsBackground:")) { view.setValue(false, forKey: "drawsBackground") }
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        context.coordinator.messages = messages
        context.coordinator.bind(liveSession)
        if let root = Bundle.main.resourceURL?.absoluteURL.appendingPathComponent("Transcript", isDirectory: true) {
            let page = root.appendingPathComponent("index.html")
            context.coordinator.page = page
            var components = URLComponents(url: page, resolvingAgainstBaseURL: true)!
            components.fragment = "viewId=\(context.coordinator.viewID)"
            view.loadFileURL(components.url!, allowingReadAccessTo: root)
        }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onInspectRequests = onInspectRequests
        context.coordinator.onEditMessage = onEditMessage
        context.coordinator.onReadReply = onReadReply
        context.coordinator.onLoadEarlier = onLoadEarlier
        context.coordinator.onStop = onStop
        let switched = context.coordinator.switchSession(sessionID, anchor: scrollAnchor)
        context.coordinator.bind(liveSession)
        context.coordinator.requestReadCheck()
        if liveSession != nil { return }
        guard switched || context.coordinator.messages != messages else { return }
        context.coordinator.observe(displayObservedAt)
        context.coordinator.messages = messages; context.coordinator.sendSnapshot()
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.unbind()
        coordinator.stopReadingObservation()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "transcript")
        view.navigationDelegate = nil; view.stopLoading()
    }
    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let viewID = UUID().uuidString
        weak var webView: WKWebView?
        var page: URL?
        var messages: [TranscriptMessage] = []
        var ready = false
        private var inFlight = false
        private var dirty = false
        private var sequence = 0
        private var renderedSequence = -1
        private var failedRenderSequence: Int?
        private var sessionID: String?
        var onInspectRequests: ((String, String) -> Void)?
        var onEditMessage: ((String, String) -> Void)?
        var onReadReply: ((String, String) -> Void)?
        var onLoadEarlier: ((String) -> Void)?
        var onStop: ((String) -> Void)?
        private var readCheckScheduled = false
        private var pendingObservation: Double?
        private struct Paint { var at: Double?; var count: Int; var sessionID: String? }
        private var unpainted: [Int: Paint] = [:]
        private var liveSubscription: AnyCancellable?
        private var boundID: String?
        private var viewportRequest = 0
        private var paintClock = PaintClockCalibration()
        private var calibratingClock = false
        private var clockGeneration = 0
        private var bridgeStatus: Binding<String>
        private var scrollAnchor: Binding<TranscriptAnchor?>?
        init(bridgeStatus: Binding<String>, scrollAnchor: Binding<TranscriptAnchor?>?, sessionID: String?) {
            self.bridgeStatus = bridgeStatus; self.scrollAnchor = scrollAnchor; self.sessionID = sessionID
            super.init()
            for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didEndSheetNotification, TranscriptReadVisibility.didRestoreNativeView] {
                NotificationCenter.default.addObserver(self, selector: #selector(readingVisibilityChanged), name: name, object: nil)
            }
        }
        func stopReadingObservation() { NotificationCenter.default.removeObserver(self); recoveryTask?.cancel(); recoveryTask = nil; ready = false; clockGeneration += 1 }
        @objc private func readingVisibilityChanged(_ notification: Notification) { requestReadCheck() }
        private var canRead: Bool {
            guard let webView, let window = webView.window else { return false }
            return TranscriptReadVisibility.permits(appActive: NSApp.isActive, keyWindow: window.isKeyWindow, windowVisible: window.isVisible,
                                                    occluded: !window.occlusionState.contains(.visible), minimized: window.isMiniaturized,
                                                    viewHidden: webView.isHiddenOrHasHiddenAncestor || webView.visibleRect.isEmpty, sheetOpen: window.attachedSheet != nil)
        }
        func requestReadCheck() {
            guard ready, !readCheckScheduled else { return }
            readCheckScheduled = true
            Task { [weak self] in
                await Task.yield() // Allow native page visibility to settle first.
                guard let self else { return }
                defer { self.readCheckScheduled = false }
                guard self.canRead, let webView = self.webView else { return }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    webView.callAsyncJavaScript("window.piTranscript.checkRead()", arguments: [:], in: nil, in: .page) { _ in continuation.resume() }
                }
            }
        }
        func unbind() { liveSubscription?.cancel(); liveSubscription = nil; boundID = nil }
        func bind(_ session: SessionDisplay?) {
            guard boundID != session?.id else { return }; unbind(); boundID = session?.id
            guard let session else { return }
            // Transcript delivery is independent of the shell's next SwiftUI
            // layout pass. One in-flight snapshot and one dirty marker remain.
            var initial = true
            liveSubscription = session.transcriptChanges.combineLatest(session.$viewportRequest).sink { [weak self, weak session] messages, viewportRequest in
                guard let self, initial || self.messages != messages || self.viewportRequest != viewportRequest else { return }; initial = false
                self.viewportRequest = viewportRequest
                self.observe(session?.displayObservedAt); self.messages = messages; self.sendSnapshot()
            }
        }
        func switchSession(_ id: String?, anchor: Binding<TranscriptAnchor?>?) -> Bool {
            scrollAnchor = anchor
            guard sessionID != id else { return false }
            sessionID = id; inFlight = false; dirty = false; pendingObservation = nil; unpainted.removeAll(); renderedSequence = -1
            sequence += 1 // Reject an old conversation's in-flight acknowledgement.
            return true
        }
        func observe(_ value: Double?) { if let value { pendingObservation = min(pendingObservation ?? value, value) } }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, Self.isFileOrigin(message.frameInfo.securityOrigin), TranscriptView.trustedPage(message.frameInfo.request.url, page: page),
                  let body = message.body as? [String: Any], body["v"] as? Int == 1,
                  body["viewId"] as? String == viewID, let type = body["type"] as? String else { return }
            if type == "ready" {
                // A user-triggered reload has no native navigation callback
                // clearing outstanding deliveries. Start a new handshake so
                // callbacks/watchdogs from the previous document cannot block it.
                recoveryTask?.cancel(); recoveryTask = nil
                sequence += 1; inFlight = false; dirty = false; unpainted.removeAll(); renderedSequence = -1
                clockGeneration += 1; calibratingClock = false; paintClock = PaintClockCalibration()
                ready = true; calibratePaintClock(); sendSnapshot()
            }
            else if type == "renderError", let failed = body["seq"] as? Int, failed <= sequence, let pending = unpainted[failed], pending.sessionID == sessionID {
                failedRenderSequence = failed
                if failed == sequence { inFlight = false }
                for key in unpainted.keys.filter({ $0 <= failed }) { unpainted.removeValue(forKey: key) }
                bridgeStatus.wrappedValue = "Transcript render failed"
                if dirty { dirty = false; sendSnapshot() }
            }
            else if type == "inspectRequests", let id = body["id"] as? String, id.utf8.count <= 256,
                    let sessionID, messages.contains(where: { $0.id == id }) { onInspectRequests?(sessionID, id) }
            else if type == "copyMessage", let id = body["id"] as? String, id.utf8.count <= 256,
                    let message = messages.first(where: { $0.id == id }) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string)
            }
            else if type == "copyContent", let requestID = body["requestId"] as? String,
                    requestID.utf8.count <= 64, requestID.range(of: "^copy-[0-9]+$", options: .regularExpression) != nil {
                var copied = false
                if let content = TranscriptClipboard.content(body, messages: messages) {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(content, forType: .string)
                }
                // Fixed JavaScript and structured arguments only. The web page
                // receives no native content or arbitrary clipboard read access.
                webView?.callAsyncJavaScript("return window.piTranscript.copyResult(result)", arguments: ["result": ["requestId": requestID, "success": copied]], in: nil, in: .page) { _ in }
            }
            else if type == "editMessage", let id = body["id"] as? String, id.utf8.count <= 256,
                    let sessionID, messages.contains(where: { $0.id == id && $0.role == "user" && $0.kind == nil }) { onEditMessage?(sessionID, id) }
            else if type == "readReply", canRead,
                    let receiptSequence = body["seq"] as? Int, let receiptSession = body["sessionId"] as? String,
                    let id = body["id"] as? String, id.utf8.count <= 256, let sessionID,
                    TranscriptReadVisibility.receiptMatches(receiptSequence: receiptSequence, renderedSequence: renderedSequence, sentSequence: sequence, receiptSession: receiptSession, currentSession: sessionID),
                    messages.contains(where: { $0.id == id && $0.role == "assistant" && $0.state != "streaming" && !$0.id.hasPrefix("stream:") }) { onReadReply?(sessionID, id) }
            else if type == "committed", body["seq"] as? Int == sequence {
                inFlight = false
                if dirty { dirty = false; sendSnapshot() }
            }
            else if type == "rendered", let painted = body["seq"] as? Int, painted <= sequence, painted != failedRenderSequence,
                    (unpainted[painted] != nil && unpainted[painted]?.sessionID == sessionID) || painted == sequence {
                // A rendered acknowledgement may flush a newer dirty snapshot
                // below. Its following receipt still proves this painted frame;
                // an issued-but-unpainted snapshot must not invalidate it.
                renderedSequence = max(renderedSequence, painted)
                if let delay = body["paintDelayMs"] as? Double { PerformanceProbe.shared.observe("webSnapshotToPaintMs", milliseconds: delay) }
                let paintedAt = (body["paintedAt"] as? Double).flatMap { paintClock.upperBound(web: $0) }
                for key in unpainted.keys.filter({ $0 <= painted }).sorted() {
                    if let value = unpainted.removeValue(forKey: key), let id = value.sessionID, value.count > 0 { PerformanceProbe.shared.viewport(id, deltaAt: value.at, paintedAt: paintedAt) }
                }
                bridgeStatus.wrappedValue = "Native ↔ React bridge verified"
                reloadAttempts = 0 // Ready alone is not proof the document recovered.
                if dirty { dirty = false; sendSnapshot() }
            } else if type == "stop", let sessionID {
                onStop?(sessionID)
            } else if type == "earlier", let sessionID, let firstID = body["firstId"] as? String, firstID.utf8.count <= 256, messages.first?.id == firstID {
                onLoadEarlier?(sessionID)
            } else if type == "viewport", body["seq"] as? Int == sequence, let id = body["id"] as? String, id.count <= 256,
                      let offset = body["offset"] as? Double, offset.isFinite, abs(offset) < 1_000_000,
                      let follows = body["followsBottom"] as? Bool, messages.contains(where: { $0.id == id }) {
                scrollAnchor?.wrappedValue = TranscriptAnchor(id: id, offset: offset, followsBottom: follows)
            }
        }
        private static func isFileOrigin(_ origin: WKSecurityOrigin) -> Bool { origin.protocol == "file" && origin.host.isEmpty }
        private func calibratePaintClock() {
            guard PerformanceProbe.shared.enabled, !calibratingClock, let webView else { return }
            calibratingClock = true
            let generation = clockGeneration
            Task { [weak self] in
                defer { if let self, self.clockGeneration == generation { self.calibratingClock = false } }
                for _ in 0..<5 {
                    let sent = PerformanceProbe.now
                    let web: Double? = await withCheckedContinuation { continuation in
                        webView.callAsyncJavaScript("return performance.now()", arguments: [:], in: nil, in: .page) { result in
                            continuation.resume(returning: (try? result.get()) as? Double)
                        }
                    }
                    guard let web, let self, self.clockGeneration == generation else { return }
                    self.paintClock.sample(sent: sent, received: PerformanceProbe.now, web: web)
                }
                if let self { PerformanceProbe.shared.observe("webClockCalibrationUncertaintyMs", milliseconds: self.paintClock.uncertainty) }
            }
        }
        func sendSnapshot() {
            guard ready, let webView else { return }
            guard !inFlight, unpainted.count < 2 else { dirty = true; return }
            // The page holds the newest rows that fit: up to 500 messages and
            // 4 MB. Older rows beyond that are reachable again with Earlier Messages.
            var page = Array(messages.suffix(500)), encoded = try? JSONEncoder().encode(page)
            while let bytes = encoded, bytes.count > 4_000_000, page.count > 1 { page.removeFirst(max(1, page.count / 8)); encoded = try? JSONEncoder().encode(page) }
            guard let data = encoded, data.count <= 4_000_000,
                  let display = try? JSONSerialization.jsonObject(with: data) else { bridgeStatus.wrappedValue = "Display page exceeds its size limit"; return }
            inFlight = true
            let observation = pendingObservation; pendingObservation = nil
            if let start = observation { PerformanceProbe.shared.observe("deltaToWebDeliveryMs", milliseconds: PerformanceProbe.now - start) }
            sequence += 1
            unpainted[sequence] = Paint(at: observation, count: messages.count, sessionID: sessionID)
            let sent = sequence
            var payload: [String: Any] = ["v": 1, "viewId": viewID, "sessionId": sessionID ?? viewID, "viewportRequest": viewportRequest, "seq": sequence, "messages": display]
            if let anchor = scrollAnchor?.wrappedValue { payload["anchor"] = ["id": anchor.id, "offset": anchor.offset, "followsBottom": anchor.followsBottom] }
            webView.callAsyncJavaScript("return window.piTranscript.apply(payload)", arguments: ["payload": payload], in: nil, in: .page) { [weak self] result in
                guard let self, self.sequence == sent else { return }
                switch result {
                case .failure:
                    self.recoverPage(webView, reason: "Transcript bridge failed; reloading")
                case .success(let value):
                    // The page returns false when it rejects a snapshot. That was
                    // previously indistinguishable from success and left the
                    // transcript silently frozen on the previous page.
                    guard (value as? Bool) == false else { return }
                    self.inFlight = false; self.unpainted.removeValue(forKey: sent); self.bridgeStatus.wrappedValue = "Transcript rejected a page"
                    if self.dirty { self.dirty = false; self.sendSnapshot() }
                }
            }
            // A page that never reports its paint (a render exception, for
            // example) must not count against the two-unpainted limit forever.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2)); guard let self, self.unpainted[sent] != nil else { return }
                // Retire every expired delivery, including older conflated
                // frames, rather than leaking one slot after the next send.
                if self.sequence == sent { self.inFlight = false }
                self.unpainted.removeValue(forKey: sent); self.bridgeStatus.wrappedValue = "Transcript needs refresh"
                if self.dirty { self.dirty = false; self.sendSnapshot() } }
        }
        private var reloadAttempts = 0
        private var recoveryTask: Task<Void, Never>?
        /// WebKit killed the content process: the page is blank and every later
        /// script call fails. Reload; the page's `ready` resends the snapshot.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { recoverPage(webView, reason: "Transcript reloading") }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { navigationFailed(webView, error: error) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { navigationFailed(webView, error: error) }
        private func navigationFailed(_ webView: WKWebView, error: any Error) {
            let failure = error as NSError
            guard !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled) else { return }
            recoverPage(webView, reason: "Transcript failed to load")
        }
        private func recoverPage(_ webView: WKWebView, reason: String) {
            recoveryTask?.cancel(); recoveryTask = nil
            sequence += 1 // Invalidate callbacks from the document being replaced.
            ready = false; inFlight = false; dirty = true; unpainted.removeAll(); renderedSequence = -1
            bridgeStatus.wrappedValue = reason
            guard reloadAttempts < 3, let page else { return }
            reloadAttempts += 1
            let delay = Double(reloadAttempts) * 0.5
            // Same URL as the first load: the page only accepts snapshots that
            // carry the view id it was launched with.
            var components = URLComponents(url: page, resolvingAgainstBaseURL: true)
            components?.fragment = "viewId=\(viewID)"
            guard let url = components?.url else { return }
            recoveryTask = Task { [weak self, weak webView] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, let webView, !self.ready else { return }
                self.recoveryTask = nil
                webView.loadFileURL(url, allowingReadAccessTo: page.deletingLastPathComponent())
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if navigationAction.targetFrame?.isMainFrame == true && TranscriptView.trustedPage(url, page: page) { return .allow }
            if navigationAction.navigationType == .linkActivated, ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }
    }
}

enum TranscriptClipboard {
    /// The page identifies ordered UTF-16 ranges of the exact current display
    /// source. It cannot provide replacement text or copy another message's data.
    static func content(_ body: [String: Any], messages: [TranscriptMessage]) -> String? {
        guard let id = body["id"] as? String, id.utf8.count <= 256,
              let field = body["field"] as? String, ["text", "thinking"].contains(field),
              let message = messages.first(where: { $0.id == id }),
              let expected = body["source"] as? String, expected.utf8.count <= 65_536,
              let ranges = body["ranges"] as? [[String: Any]], !ranges.isEmpty, ranges.count <= 4_096 else { return nil }
        let source = field == "text" ? message.text : message.thinking ?? ""
        guard source.utf16.elementsEqual(expected.utf16) else { return nil } // Reject stale streaming selections, including normalization changes.
        let units = Array(source.utf16)
        func scalarBoundary(_ offset: Int) -> Bool {
            offset == 0 || offset == units.count || !((0xD800...0xDBFF).contains(units[offset - 1]) && (0xDC00...0xDFFF).contains(units[offset]))
        }
        var previousEnd = 0, pieces: [String] = []
        for range in ranges {
            guard let start = range["start"] as? NSNumber, let end = range["end"] as? NSNumber,
                  CFGetTypeID(start) != CFBooleanGetTypeID(), CFGetTypeID(end) != CFBooleanGetTypeID(),
                  start.doubleValue.isFinite, end.doubleValue.isFinite,
                  start.doubleValue.rounded(.towardZero) == start.doubleValue, end.doubleValue.rounded(.towardZero) == end.doubleValue,
                  start.doubleValue >= Double(previousEnd), end.doubleValue > start.doubleValue, end.doubleValue <= Double(source.utf16.count) else { return nil }
            let lower = start.intValue, upper = end.intValue
            guard scalarBoundary(lower), scalarBoundary(upper) else { return nil }
            pieces.append(String(decoding: units[lower..<upper], as: UTF16.self)); previousEnd = upper
        }
        let result = pieces.joined()
        return result.utf8.count <= 65_536 ? result : nil
    }
}

enum TranscriptReadVisibility {
    static let didRestoreNativeView = Notification.Name("PiTranscriptDidRestoreNativeView")
    static func receiptMatches(receiptSequence: Int, renderedSequence: Int, sentSequence: Int, receiptSession: String, currentSession: String) -> Bool {
        renderedSequence >= 0 && receiptSequence == renderedSequence && receiptSequence <= sentSequence && receiptSession == currentSession
    }
    static func permits(appActive: Bool, keyWindow: Bool, windowVisible: Bool, occluded: Bool, minimized: Bool, viewHidden: Bool, sheetOpen: Bool) -> Bool {
        appActive && keyWindow && windowVisible && !occluded && !minimized && !viewHidden && !sheetOpen
    }
}
