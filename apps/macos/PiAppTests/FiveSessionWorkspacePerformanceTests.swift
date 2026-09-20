import AppKit
import Combine
import SwiftUI
import XCTest
@testable import PiApp

/// A whole-window reproduction, separate from the single-transcript scrolling
/// fixtures. The five sessions are already loaded, as after creating several
/// chats. Synthetic status/content/billing arrivals exercise the real native
/// observation boundary without user history, credentials or network traffic.
final class FiveSessionWorkspacePerformanceTests: XCTestCase {
    @MainActor private final class Heartbeat {
        private var last = ProcessInfo.processInfo.systemUptime
        private(set) var gaps: [Double] = []
        func tick() {
            let now = ProcessInfo.processInfo.systemUptime
            gaps.append((now - last) * 1_000); last = now
        }
    }

    private struct Timing {
        var total: [Double] = []
        var synchronous: [Double] = []
        var mainQueue: [Double] = []
        func report(_ label: String, publications: Int, heartbeat: [Double]) {
            func summary(_ values: [Double]) -> String {
                guard !values.isEmpty else { return "no samples" }
                let sorted = values.sorted(), p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
                return String(format: "mean %.3f ms, p95 %.3f ms, max %.3f ms", values.reduce(0, +) / Double(values.count), p95, sorted.last!)
            }
            print("FIVE SESSION PERF \(label): \(total.count) frames; layout/display + deferred work \(summary(total)); synchronous \(summary(synchronous)); queued MainActor latency \(summary(mainQueue)); heartbeat \(summary(heartbeat)); workspace publications \(publications)")
        }
    }

    @MainActor private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    private static func paragraph(_ index: Int) -> String {
        """
        ## Finding \(index)

        The **native interface** retains `file\(index).swift` and [this reference](https://example.invalid/\(index)). Background activity should update its own row while this conversation stays selectable.

        - Preserve this explanation while the user types.
        - Keep the previous results in their original position.

        ```swift
        let result = inspect(index: \(index))
        if result.isValid { print("complete") }
        ```
        """
    }

    @MainActor private func fixture() throws -> (WorkspaceModel, [SessionDisplay]) {
        let base = testEnvironment("PI_APP_SCRATCH_ROOT") ?? NSTemporaryDirectory()
        let root = URL(fileURLWithPath: base).appendingPathComponent("five-session-workspace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        var profile = ProfileRecord(); profile.id = "fixture-profile"; profile.modelId = "fixture-model"; profile.baseUrl = "https://fixture.invalid/v1"
        let project = WorkspaceRecord(id: "fixture-project", path: root.path, trusted: true)
        model.profiles = [profile]; model.workspaces = [project]
        model.selectedWorkspaceID = project.id; model.profileChoice = profile.id
        model.chats = (0..<5).map { ChatRecord(id: "session-\($0)", workspaceID: project.id, title: "Investigation \($0 + 1)", path: nil, profileID: profile.id) }
        let sessions = model.chats.enumerated().map { number, chat -> SessionDisplay in
            let view = SessionDisplay(id: chat.id)
            view.messages = (0..<61).map { index in
                TranscriptMessage(id: "s\(number)-m\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant",
                                  text: index.isMultiple(of: 2) ? "Inspect the result of check \(index)." : Self.paragraph(index), turn: "s\(number)-m\(index - index % 2)")
            }
            view.draft = "Keep my unsent draft for \(chat.id)."
            view.state = "running"; view.runStatus = "running"; view.selectionMetadataLoaded = true
            view.activity = ["version": .number(2), "phase": .string("model"), "modelActive": .bool(true)]
            // This is the real coalescing path: another status invalidation
            // arrives before its outstanding snapshot has completed. No helper
            // command is dispatched by refresh while this flag is set.
            view.snapshotInFlight = true
            return view
        }
        model.displays = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        model.selectedID = sessions[0].id; model.focusedSessionID = sessions[0].id; model.selected = sessions[0]
        model.hosts[project.id] = HostSupervisor(); model.opened = Set(sessions.map(\.id))
        return (model, sessions)
    }

    /// Repeated status invalidations must remain local while their existing
    /// snapshot is in flight. Keep this invariant even when display storage or
    /// session scheduling changes in a later release.
    @MainActor func testBackgroundRefreshBurstDoesNotRepublishTheWholeWorkspace() throws {
        let (model, sessions) = try fixture()
        let identities = model.displays.mapValues(ObjectIdentifier.init)
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        for _ in 0..<50 { for session in sessions { model.refresh(session.id) } }
        XCTAssertEqual(publications, 0, "Refreshing an existing in-flight display must not invalidate the complete workspace and every unrelated chat")
        XCTAssertEqual(model.displays.mapValues(ObjectIdentifier.init), identities)
        XCTAssertTrue(sessions.allSatisfy { $0.dirty && $0.snapshotInFlight })
        XCTAssertTrue(model.hosts.values.allSatisfy { $0.connectionID == nil }, "The regression uses the coalescing path, never a gateway or helper")
    }

    @MainActor private func settle(_ hosted: NSView, window: NSWindow, until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The five-session workspace did not finish its native layout")
    }

    @MainActor private func mainQueueTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    /// Timings are deliberately printed rather than asserted against a machine
    /// speed. The structural/identity/geometry assertions are deterministic.
    /// This measures native CPU/layout latency, not physical screen scanout.
    @MainActor func testFiveLoadedSessionsBackgroundAndForegroundUpdateBaselines() async throws {
        let (model, sessions) = try fixture()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: WorkspaceView(model: model))
        let mountedAt = ProcessInfo.processInfo.systemUptime
        window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await settle(hosted, window: window) {
            guard let marker = self.descendants(TranscriptSurfaceMarker.self, in: hosted).first else { return false }
            // A page this long comes up with its viewport exact and measures
            // the rest in idle slices; what follows compares the geometry it
            // settles on, so it waits for the last slice.
            let document = marker.enclosingScrollView?.documentView as? TranscriptNativeDocument
            return marker.page?.rowFrame(of: "s0-m60") != nil && document?.approximateRowCount == 0
                && self.descendants(ComposerTextView.self, in: hosted).count == 1
        }
        print(String(format: "FIVE SESSION PERF complete workspace initial layout: %.3f ms", (ProcessInfo.processInfo.systemUptime - mountedAt) * 1_000))
        try await Task.sleep(for: .milliseconds(200))
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let marker = try XCTUnwrap(descendants(TranscriptSurfaceMarker.self, in: hosted).first)
        let scroll = try XCTUnwrap(marker.enclosingScrollView)
        let document = try XCTUnwrap(scroll.documentView as? TranscriptNativeDocument)
        let editor = try XCTUnwrap(descendants(ComposerTextView.self, in: hosted).first)
        XCTAssertTrue(window.makeFirstResponder(editor)); editor.setSelectedRange(NSRange(location: 5, length: 7))
        let selectedRange = editor.selectedRange(), draft = editor.string
        let documentHeight = document.frame.height
        let initialFrames = try ["s0-m0", "s0-m30", "s0-m60"].map { (id: $0, frame: try XCTUnwrap(marker.page?.rowFrame(of: $0))) }
        let initialMeasurements = Dictionary(uniqueKeysWithValues: document.retainedRows.map { ($0.itemID, $0.measurementCount) })
        var workspacePublications = 0
        var focusPublications = 0
        let observation = model.objectWillChange.sink { workspacePublications += 1 }
        let focusObservation = model.$focusedSessionID.dropFirst().sink { _ in focusPublications += 1 }
        defer { observation.cancel(); focusObservation.cancel() }

        func phase(_ label: String, frames: Int, updatedSessions: [SessionDisplay], publishContent: Bool, publishBilling: Bool, smallDeltas: Bool = false) async throws {
            let document = try XCTUnwrap(self.descendants(TranscriptSurfaceMarker.self, in: hosted).first?.enclosingScrollView?.documentView as? TranscriptNativeDocument)
            let heartbeat = Heartbeat()
            let pulse = Task { @MainActor in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
                    heartbeat.tick()
                }
            }
            defer { pulse.cancel() }
            var timing = Timing()
            let publicationsAtStart = workspacePublications
            let focusPublicationsAtStart = focusPublications
            let invocations = document.updateInvocationCount, reconciliations = document.contentReconciliationCount
            let traversals = document.rowLayoutTraversalCount, layouts = document.layoutPassCount
            let prefixes = Dictionary(uniqueKeysWithValues: updatedSessions.map { ($0.id, $0.messages.last?.text ?? "") })
            let smallChunk = " Another small streamed detail. "
            for frame in 0..<frames {
                let streamedText = (0...frame).map(Self.paragraph).joined(separator: "\n\n")
                let start = ProcessInfo.processInfo.systemUptime
                for session in updatedSessions {
                    model.refresh(session.id)
                    if publishContent {
                        let text = smallDeltas ? (prefixes[session.id] ?? "") + "\n\n" + String(repeating: smallChunk, count: frame + 1) : streamedText
                        let tail = TranscriptMessage(id: session.id + "-stream", role: "assistant", text: text, state: "streaming", turn: "s\(sessions.firstIndex(where: { $0 === session })!)-m60")
                        if session.messages.last?.id == tail.id { session.messages[session.messages.count - 1] = tail }
                        else { session.messages.append(tail) }
                    }
                    if publishBilling, frame.isMultiple(of: smallDeltas ? 10 : 5) {
                        var totals = GatewayTotals(requests: frame + 1, costSamples: frame + 1, costUSD: Double(frame + 1) / 1_000)
                        totals.tokens = GatewayTokenTotals(input: Double(frame + 1) * 20, output: Double(frame + 1) * 50, total: Double(frame + 1) * 70, inputSamples: frame + 1, outputSamples: frame + 1, samples: frame + 1)
                        session.footer.gateway = totals
                        model.publishChatStats(totals, sessionID: session.id)
                    }
                }
                hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                var synchronous = ProcessInfo.processInfo.systemUptime - start
                let queuedAt = ProcessInfo.processInfo.systemUptime
                await mainQueueTurn()
                let resumedAt = ProcessInfo.processInfo.systemUptime
                timing.mainQueue.append((resumedAt - queuedAt) * 1_000)
                hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                synchronous += ProcessInfo.processInfo.systemUptime - resumedAt
                timing.total.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
                timing.synchronous.append(synchronous * 1_000)
                // Network delivery yields between bursts. Exclude this pacing
                // delay from CPU/layout timings but include it in heartbeat.
                try await Task.sleep(for: .milliseconds(smallDeltas ? 50 : 16))
            }
            pulse.cancel(); await pulse.value
            timing.report(label, publications: workspacePublications - publicationsAtStart, heartbeat: heartbeat.gaps)
            if workspacePublications != publicationsAtStart {
                print("FIVE SESSION PUBLICATIONS \(label): focus assignments \(focusPublications - focusPublicationsAtStart) of \(workspacePublications - publicationsAtStart) workspace publications")
            }
            if smallDeltas { print("FIVE SESSION INPUT \(label): \(smallChunk.utf8.count) new UTF-8 bytes per update after initial paragraph boundary, 50 ms pacing, \(prefixes[updatedSessions[0].id]?.utf8.count ?? 0)-byte initial rich answer; cost pulses every ten frames") }
            print("FIVE SESSION WORK \(label): native updates \(document.updateInvocationCount - invocations), content reconciliations \(document.contentReconciliationCount - reconciliations), row traversals \(document.rowLayoutTraversalCount - traversals), layout passes \(document.layoutPassCount - layouts)")
            XCTAssertFalse(heartbeat.gaps.isEmpty, "The MainActor heartbeat must make progress during a five-session update burst")
            if !updatedSessions.isEmpty {
                XCTAssertEqual(workspacePublications - publicationsAtStart, 0, "Per-session status, content and billing delivery must not invalidate the complete workspace")
            }
            if !updatedSessions.isEmpty, !updatedSessions.contains(where: { $0.id == model.selectedID }) {
                XCTAssertEqual(document.contentReconciliationCount, reconciliations, "Background-only activity cannot reconcile the selected transcript")
            }
        }

        try await phase("five running rows, no incoming updates", frames: 20, updatedSessions: [], publishContent: false, publishBilling: false)
        for session in sessions { session.state = "idle"; session.runStatus = "idle" }
        await mainQueueTurn(); hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        try await phase("five idle rows, no incoming updates", frames: 20, updatedSessions: [], publishContent: false, publishBilling: false)
        for session in sessions { session.state = "running"; session.runStatus = "running" }
        await mainQueueTurn(); hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        try await phase("four hidden sessions status only", frames: 30, updatedSessions: Array(sessions.dropFirst()), publishContent: false, publishBilling: false)
        try await phase("four hidden sessions content + billing", frames: 30, updatedSessions: Array(sessions.dropFirst()), publishContent: true, publishBilling: true)
        XCTAssertTrue(descendants(ComposerTextView.self, in: hosted).first === editor)
        XCTAssertTrue(window.firstResponder === editor); XCTAssertEqual(editor.selectedRange(), selectedRange)
        XCTAssertEqual(editor.string, draft)
        XCTAssertEqual(document.frame.height, documentHeight, accuracy: 0.5, "Hidden chats cannot move the visible transcript")
        for expected in initialFrames { XCTAssertEqual(marker.page?.rowFrame(of: expected.id), expected.frame) }
        for row in document.retainedRows { XCTAssertEqual(row.measurementCount, initialMeasurements[row.itemID], "Hidden-chat delivery must reuse the visible chat's exact measured geometry") }

        try await phase("five sessions content + billing", frames: 30, updatedSessions: sessions, publishContent: true, publishBilling: true)
        try await settle(hosted, window: window) { marker.page?.snapshot?.messages.last?.text == sessions[0].messages.last?.text }
        XCTAssertEqual(descendants(ComposerTextView.self, in: hosted).map(\.sessionID), [sessions[0].id])
        XCTAssertEqual(descendants(TranscriptSurfaceMarker.self, in: hosted).count, 1, "Retained background sessions must not mount hidden transcripts")
        XCTAssertTrue(descendants(ComposerTextView.self, in: hosted).first === editor)
        XCTAssertTrue(window.firstResponder === editor); XCTAssertEqual(editor.selectedRange(), selectedRange); XCTAssertEqual(editor.string, draft)
        XCTAssertTrue(sessions.allSatisfy { $0.messages.last?.id == $0.id + "-stream" })

        // The first cycle has loaded data but has never mounted the other
        // four native pages. Its final return to session0 is directly comparable
        // to the original baseline. The second cycle revisits five pages that
        // have all been mounted already, with unchanged content and width.
        var geometries: [String: (height: CGFloat, width: CGFloat, rows: [String: CGRect])] = [:]
        func viewCount(_ view: NSView) -> Int { 1 + view.subviews.reduce(0) { $0 + viewCount($1) } }
        for cycle in 0..<2 {
            let label = cycle == 0 ? "loaded data / first mount except final return" : "previously mounted five-tab returns"
            var switches: [Double] = [], deferredSettlement: [Double] = [], surfaceCounts: [String] = []
            for session in Array(sessions.dropFirst()) + [sessions[0]] {
                let started = ProcessInfo.processInfo.systemUptime
                model.selectedID = session.id; model.selected = session; model.focusedSessionID = session.id
                try await settle(hosted, window: window) {
                    self.descendants(ComposerTextView.self, in: hosted).first?.sessionID == session.id
                        && self.descendants(TranscriptSurfaceMarker.self, in: hosted).first?.page?.snapshot?.sessionID == session.id
                }
                switches.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
                // A real user cannot select ten tabs in one MainActor turn.
                // Keep the original readiness timing above comparable, then
                // give deferred native sizing/cache confirmation its own turn
                // before measuring final geometry or choosing another tab.
                let settlementStarted = ProcessInfo.processInfo.systemUptime
                await mainQueueTurn(); hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                XCTAssertEqual(descendants(ComposerTextView.self, in: hosted).count, 1)
                XCTAssertEqual(descendants(ComposerTextView.self, in: hosted).first?.string, session.draft)
                let markers = descendants(TranscriptSurfaceMarker.self, in: hosted)
                XCTAssertEqual(markers.count, 1, "Only the selected transcript may remain mounted across tab switches")
                let native = try XCTUnwrap(markers.first?.enclosingScrollView?.documentView as? TranscriptNativeDocument)
                let settlementDeadline = ProcessInfo.processInfo.systemUptime + 10
                var settledPasses = 0, previousSize = native.frame.size
                while settledPasses < 2, ProcessInfo.processInfo.systemUptime < settlementDeadline {
                    await mainQueueTurn(); hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    let pendingRows = native.subviews.compactMap { $0 as? TranscriptRowContainer }.contains(where: \.needsMountedValidation)
                    // Exact-geometry comparisons cannot snapshot provisional
                    // offscreen heights merely because two run-loop turns had
                    // the same document size. First paint stays timed above;
                    // bounded idle reconciliation is measured separately.
                    settledPasses = native.approximateRowCount == 0 && !pendingRows && native.frame.size == previousSize ? settledPasses + 1 : 0
                    previousSize = native.frame.size
                    if settledPasses < 2 { try await Task.sleep(for: .milliseconds(5)) }
                }
                XCTAssertEqual(native.approximateRowCount, 0, "Record only exact geometry for the next tab-return comparison")
                XCTAssertEqual(settledPasses, 2, "Deferred native height confirmation and its queued layout must settle before choosing another tab")
                XCTAssertFalse(native.subviews.compactMap { $0 as? TranscriptRowContainer }.contains(where: \.needsMountedValidation), "Mounted rows must finish their deferred exact-height confirmation before leaving the tab")
                deferredSettlement.append((ProcessInfo.processInfo.systemUptime - settlementStarted) * 1_000)
                let frames = Dictionary(uniqueKeysWithValues: native.retainedRows.map { ($0.itemID, $0.frame) })
                XCTAssertFalse(frames.isEmpty)
                if let previous = geometries[session.id] {
                    XCTAssertEqual(native.frame.height, previous.height, accuracy: 0.5)
                    XCTAssertEqual(native.frame.width, previous.width, accuracy: 0.5)
                    XCTAssertEqual(frames, previous.rows, "Revisiting an unchanged page must retain exact row positions and heights")
                } else { geometries[session.id] = (native.frame.height, native.frame.width, frames) }
                let mounted = native.subviews.compactMap { $0 as? TranscriptRowContainer }.count
                surfaceCounts.append("\(session.id): views=\(viewCount(hosted)), mounted rows=\(mounted)/\(native.retainedRows.count), document=\(Int(native.frame.height))pt")
            }
            print("FIVE SESSION PERF \(label) visual switches ms: " + switches.map { String(format: "%.3f", $0) }.joined(separator: ", "))
            print("FIVE SESSION PERF \(label) additional deferred settlement ms: " + deferredSettlement.map { String(format: "%.3f", $0) }.joined(separator: ", "))
            print("FIVE SESSION GEOMETRY \(label): " + surfaceCounts.joined(separator: "; "))
        }

        // Run this after both switch cycles so their original 11,808-byte payload
        // remains comparable. This adds 32 bytes at a 50 ms delivery cadence;
        // it is a text-delivery fixture, not a token-rate measurement.
        let smallMarker = try XCTUnwrap(descendants(TranscriptSurfaceMarker.self, in: hosted).first)
        let smallEditor = try XCTUnwrap(descendants(ComposerTextView.self, in: hosted).first)
        XCTAssertTrue(window.makeFirstResponder(smallEditor)); smallEditor.setSelectedRange(selectedRange)
        // NativeComposer publishes a focus callback in a queued MainActor task.
        // Finish that navigation transaction before attributing publications to
        // arriving content/billing. Keep the zero-publication assertion inside
        // phase(), so any later data-driven workspace repaint still fails.
        for _ in 0..<2 {
            await mainQueueTurn(); hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        }
        let richPrefixes = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.messages.last!.text) })
        XCTAssertTrue(richPrefixes.values.allSatisfy { $0.utf8.count == 11_808 }, "Keep the original rich-answer payload identical across performance comparisons")
        try await phase("five sessions 32-byte deltas at 50 ms", frames: 30, updatedSessions: sessions, publishContent: true, publishBilling: true, smallDeltas: true)
        try await settle(hosted, window: window) { smallMarker.page?.snapshot?.messages.last?.text == sessions[0].messages.last?.text }
        for session in sessions {
            let original = richPrefixes[session.id]!, latest = try XCTUnwrap(session.messages.last?.text)
            XCTAssertTrue(latest.hasPrefix(original), "Small deltas must preserve the complete earlier rich answer")
            XCTAssertEqual(latest.utf8.count, original.utf8.count + 2 + 30 * 32)
        }
        XCTAssertTrue(descendants(ComposerTextView.self, in: hosted).first === smallEditor)
        XCTAssertTrue(window.firstResponder === smallEditor); XCTAssertEqual(smallEditor.selectedRange(), selectedRange); XCTAssertEqual(smallEditor.string, draft)
        XCTAssertEqual(descendants(TranscriptSurfaceMarker.self, in: hosted).count, 1)
        XCTAssertTrue(model.hosts.values.allSatisfy { $0.connectionID == nil }, "The fixture must not open a helper or gateway")
    }
}
