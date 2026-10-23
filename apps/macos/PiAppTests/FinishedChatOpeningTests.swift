import XCTest
import AppKit
@testable import PiApp

/// Opening a chat whose run finished while another chat was shown (OPEN-1).
final class FinishedChatOpeningTests: XCTestCase, SerialTestLane {
    private typealias Setup = GatewayWorkspace

    @MainActor private final class Launched {
        let model: WorkspaceModel, window: NSWindow, hosted: NSView
        init(model: WorkspaceModel, window: NSWindow, hosted: NSView) { self.model = model; self.window = window; self.hosted = hosted }
        func views<T: NSView>(_ type: T.Type, in view: NSView? = nil) -> [T] {
            let view = view ?? hosted
            return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
        }
        private weak var cachedScroll: NSScrollView?
        var scroll: NSScrollView? {
            if let cachedScroll, cachedScroll.window != nil { return cachedScroll }
            cachedScroll = views(TranscriptSurfaceMarker.self).first?.enclosingScrollView
            return cachedScroll
        }
        var document: TranscriptNativeDocument? { scroll?.documentView as? TranscriptNativeDocument }
    }

    @MainActor private func launch(_ setup: Setup) async -> Launched {
        let model = WorkspaceModel(stateRoot: setup.state, vault: setup.vault)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = WorkspaceRootView(model: model)
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil; window.close()
            model.report.suspend(); model.shutdown()
            for host in model.hosts.values { try? await host.shutdownAndWait() }
            try? await model.traces.close(); await model.store?.close()
        }
        return Launched(model: model, window: window, hosted: hosted)
    }

    @MainActor private func waitFor(_ what: String, seconds: Double = 60, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(what, file: file, line: line)
    }

    @MainActor private func quiet(_ view: SessionDisplay?) -> Bool {
        guard let view else { return false }
        return !view.hasWork && !view.loading && !view.busy && view.state == "idle" && view.taskPresentation?.active == nil
            && view.sendingRows.isEmpty && view.queue.isEmpty && view.messages.last?.role == "assistant" && view.messages.last?.isStreaming == false
    }
    @MainActor private func finished(_ view: SessionDisplay?) -> Bool {
        view.map { !$0.busy && !$0.loading && $0.state == "idle" && $0.sendingRows.isEmpty } ?? false
    }

    /// What one opening did, from the call to the page standing still.
    private struct Opening {
        var firstRows: Double?
        var ready: Double?
        var settled: Double?
        var covered = false
        var steps: [(String, Double)] = []
        var moves: [String] = []
        var line: String {
            func ms(_ value: Double?) -> String { value.map { String(format: "%.0f", $0 * 1_000) } ?? "-" }
            return "first rows \(ms(firstRows)) ms, ready \(ms(ready)) ms, settled \(ms(settled)) ms, cover \(covered ? "yes" : "no"), moves \(moves.count); steps "
                + steps.map { "\($0.0) \(ms($0.1))" }.joined(separator: ", ")
        }
    }

    /// Opens `id` from the sidebar while another chat is on screen and
    /// watches the page until it has stood still for half a second.
    @MainActor private func open(_ id: String, in launched: Launched, seconds: Double = 15) async throws -> Opening {
        let model = launched.model
        let before = Set(launched.document?.retainedRows.map(\.itemID) ?? [])
        var opening = Opening()
        let start = ProcessInfo.processInfo.systemUptime
        model.openSteps = { chat, step in if chat == id { opening.steps.append((step, ProcessInfo.processInfo.systemUptime - start)) } }
        defer { model.openSteps = nil }
        Task { @MainActor in await model.openFromSidebar(id) }
        var last: [String: (y: CGFloat, height: CGFloat)] = [:], lastChange = start
        while ProcessInfo.processInfo.systemUptime - start < seconds {
            let now = ProcessInfo.processInfo.systemUptime
            let view = model.displays[id]
            if model.selectedID == id, view?.historyState == .loading, view?.refreshingCachedRows == false { opening.covered = true }
            if opening.ready == nil, model.selectedID == id, opening.steps.contains(where: { $0.0.hasPrefix("prepared") }), view?.historyState == .ready {
                opening.ready = now - start
            }
            var shown: [String: (y: CGFloat, height: CGFloat)] = [:]
            if model.selectedID == id, let document = launched.document, let clip = launched.scroll?.contentView, view?.presentedMessages.isEmpty == false {
                let visible = document.convert(clip.bounds, from: clip)
                for row in document.retainedRows where row.superview === document && row.isHosted && !row.isHidden && row.frame.intersects(visible) {
                    shown[row.itemID] = (row.frame.minY - visible.minY, row.frame.height)
                }
            }
            if opening.firstRows == nil, !shown.isEmpty, !shown.keys.contains(where: before.contains) { opening.firstRows = now - start }
            if opening.firstRows != nil {
                var changed = shown.count != last.count
                for (row, place) in shown {
                    guard let was = last[row] else { changed = true; continue }
                    if abs(was.y - place.y) > 0.5 || abs(was.height - place.height) > 0.5 {
                        changed = true
                        opening.moves.append(String(format: "%.3f s: row %@ moved from y %.1f to %.1f, height %.1f to %.1f", now - start, String(row.prefix(14)), was.y, place.y, was.height, place.height))
                    }
                }
                if changed { lastChange = now }
            }
            last = shown
            if opening.ready != nil, opening.firstRows != nil, now - max(lastChange, start + (opening.ready ?? 0)) > 0.5 {
                opening.settled = max(lastChange - start, opening.ready ?? 0)
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        return opening
    }

    /// Opt-in measurement (`PI_OPEN_PROBE=1`, `PI_OPEN_PROBE_ROUNDS`, 6 by
    /// default): what opening a chat costs when its reply has just finished
    /// in the background while others still run, and long after, against a
    /// revisit whose rows were kept and a chat still running. Rounds
    /// alternate with the read as a run ends (`catchUpFinishedRows`) off, as
    /// before 0.1.131, and on, in one build. Release numbers only.
    @MainActor func testWhereOpeningAChatThatJustFinishedSpendsItsTime() async throws {
        guard testEnvironment("PI_OPEN_PROBE") == "1" else { throw XCTSkip("Set PI_OPEN_PROBE=1 (TEST_RUNNER_PI_OPEN_PROBE) to measure") }
        let rounds = testEnvironment("PI_OPEN_PROBE_ROUNDS").flatMap(Int.init) ?? 6
        let setup = try await gatewayWorkspace("finished-open", projectID: "finished-open-project", readme: true)
        // A read's output the size of a real source file.
        var readme = "Synthetic UI fixture file: read-tool round trip verified.\n"
        for line in 0..<300 { readme += "Line \(line): fixture content for a long tool output, shown in the call's card and kept in the journal.\n" }
        try Data(readme.utf8).write(to: URL(fileURLWithPath: setup.workspace.path).appendingPathComponent("README.md"))
        let launched = await launch(setup)
        let model = launched.model
        await model.restore()
        model.selectedWorkspaceID = setup.workspace.id; model.profileChoice = setup.profile.id
        func chat(_ name: String) -> ChatRecord { ChatRecord(id: "chat-\(name)-" + UUID().uuidString, workspaceID: setup.workspace.id, title: name, path: nil, profileID: setup.profile.id) }
        let finishing = chat("finishing"), shown = chat("shown"), running = chat("running"), other = chat("other"), later = chat("later")
        let all = [finishing, shown, running, other, later]
        for item in all {
            model.chats.append(item); try await model.store?.put(item, kind: "chat", id: item.id)
        }
        // Each chat grows by tool calls and long replies while it is shown.
        let growStart = ProcessInfo.processInfo.systemUptime
        for item in all {
            await model.select(item.id)
            for round in 0..<6 {
                for text in ["Please read fixture README.md", "Please write bulk 24 now"] {
                    model.displays[item.id]?.draft = text; model.send(sessionID: item.id)
                    await waitFor("round \(round) “\(text)” never finished in \(item.title)", seconds: 60) { quiet(model.displays[item.id]) }
                }
            }
        }
        for item in all {
            let size = (try? FileManager.default.attributesOfItem(atPath: model.record(item.id)?.path ?? "")[.size] as? NSNumber)?.intValue ?? 0
            print("OPEN-PROBE \(item.title): \(model.displays[item.id]?.messages.count ?? 0) rows held, journal \(size / 1024) KiB")
        }
        print(String(format: "OPEN-PROBE grew %d chats in %.1f s", all.count, ProcessInfo.processInfo.systemUptime - growStart))

        _ = try await open(shown.id, in: launched)
        print("OPEN-PROBE idle revisit (kept rows): " + (try await open(other.id, in: launched)).line)
        _ = try await open(shown.id, in: launched)

        var justFinished: [Bool: [Opening]] = [:], longAgo: [Bool: [Opening]] = [:]
        for round in 0..<rounds {
            let catchesUp = round % 2 == 1
            model.catchesUpFinishedRows = catchesUp
            let mode = catchesUp ? "read as the run ends" : "read as it opens"
            // A long reply starts in four chats, each while it is shown; the
            // reader goes to an idle chat while they arrive.
            for item in [finishing, later, running, other] {
                _ = try await open(item.id, in: launched, seconds: 0.5)
                model.displays[item.id]?.draft = "A large answer, please"; model.send(sessionID: item.id)
                await waitFor("The long reply never started arriving") { model.displays[item.id]?.messages.last?.isStreaming == true && (model.displays[item.id]?.messages.last?.text.count ?? 0) > 400 }
            }
            _ = try await open(shown.id, in: launched, seconds: 0.5)
            if round == 0 { print("OPEN-PROBE still running: " + (try await open(running.id, in: launched, seconds: 1.5)).line); _ = try await open(shown.id, in: launched, seconds: 0.5) }
            await waitFor("The long reply never finished in the background", seconds: 90) { finished(model.displays[finishing.id]) }
            let busy = [later, running, other].filter { model.displays[$0.id]?.busy == true }.count
            // About as long as it takes a reader to see it finish and click it.
            try await Task.sleep(for: .milliseconds(500))
            let rowsAtClick = (model.displays[finishing.id]?.messages ?? []).contains { $0.isStreaming } ? "rows as the reader left them" : "finished rows"
            let opened = try await open(finishing.id, in: launched)
            justFinished[catchesUp, default: []].append(opened)
            print("OPEN-PROBE round \(round + 1), \(mode), just finished, \(busy) others running, \(rowsAtClick): " + opened.line)
            _ = try await open(shown.id, in: launched)
            for item in all { await waitFor("every reply finished", seconds: 90) { finished(model.displays[item.id]) } }
            try await Task.sleep(for: .seconds(3))
            let long = try await open(later.id, in: launched)
            longAgo[catchesUp, default: []].append(long)
            print("OPEN-PROBE round \(round + 1), \(mode), finished long ago, nothing running: " + long.line)
            _ = try await open(shown.id, in: launched)
        }
        model.catchesUpFinishedRows = true
        print("OPEN-PROBE revisit after it finished: " + (try await open(finishing.id, in: launched)).line)
        func median(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return sorted.isEmpty ? "-" : String(format: "%.0f", sorted[sorted.count / 2] * 1_000)
        }
        for (catchesUp, mode) in [(false, "read as it opens"), (true, "read as the run ends")] {
            for (label, openings) in [("just finished", justFinished[catchesUp] ?? []), ("finished long ago", longAgo[catchesUp] ?? [])] {
                print("OPEN-PROBE median, \(mode), \(label) (\(openings.count)): first rows \(median(openings.compactMap(\.firstRows))) ms, settled \(median(openings.compactMap(\.settled))) ms, covered \(openings.filter(\.covered).count) of \(openings.count), moves \(openings.map(\.moves.count).reduce(0, +))")
            }
        }
    }
}
