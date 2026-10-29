import XCTest
import AppKit
import Darwin
import Darwin.libproc
@testable import PiApp

/// PERF-1 phase A. Opt-in, serial, Release only; real journal/helper and the
/// existing native scroll driver. Timings are evidence, not pass thresholds.
final class LongChatPerformanceTests: XCTestCase, SerialTestLane {
    override func setUpWithError() throws {
        try XCTSkipUnless(testEnvironment("PI_PERF_JOURNAL") != nil, "Set PI_PERF_JOURNAL to a generated fixture")
        #if !PI_RELEASE_TESTS
        throw XCTSkip("PERF-1 numbers require Release build-for-testing")
        #endif
        executionTimeAllowance = 4_000
    }
    private static var now: Double { ProcessInfo.processInfo.systemUptime }
    private static func report(_ event: String, _ fields: [String: Any]) {
        var value = fields; value["event"] = event; value["uptime"] = now; value["measurementVersion"] = 2
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            print("PERF136 " + String(decoding: data, as: UTF8.self))
        }
    }
    private static func usage(_ pid: Int32 = getpid()) -> [String: Double] {
        var value = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &value) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return [:] }
        // proc_pid_rusage uses Mach ticks, unlike getrusage's timeval.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1e9
        return ["userSeconds": Double(value.ri_user_time) * secondsPerTick, "systemSeconds": Double(value.ri_system_time) * secondsPerTick,
                "footprintMiB": Double(value.ri_phys_footprint) / 1_048_576,
                "peakFootprintMiB": Double(value.ri_lifetime_max_phys_footprint) / 1_048_576,
                "diskReadMiB": Double(value.ri_diskio_bytesread) / 1_048_576]
    }
    private static func launchedAt() -> Double? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6
    }
    private static func pids(helper: Int32? = nil) throws {
        if let path = testEnvironment("PI_PERF_PID_FILE") {
            var ids = ["host": getpid()]; if let helper { ids["helper"] = helper }
            try JSONSerialization.data(withJSONObject: ids).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
    @MainActor private func frames(_ run: LongChatScroll.Run, label: String, chat: LongChatScroll) {
        let errors = Array(Set(run.errors + [chat.view.olderPage.error, chat.view.newerPage.error].compactMap { $0 })).sorted()
        Self.report(label, ["frames": run.frames.count, "seconds": run.seconds,
            "p50": run.percentile(run.frames, 0.5), "p95": run.percentile(run.frames, 0.95), "p99": run.percentile(run.frames, 0.99),
            "max": run.frames.max() ?? 0, "over16_7": run.frames.filter { $0 > 16.7 }.count,
            "over33": run.frames.filter { $0 > 33 }.count, "over50": run.frames.filter { $0 > 50 }.count,
            "over100": run.frames.filter { $0 > 100 }.count, "workP95": run.percentile(run.work, 0.95), "workMax": run.work.max() ?? 0,
            "blank": run.blankFrames, "jumps": run.jumps.count, "visibleJumps": run.visibleJumps, "lost": run.lost, "loads": run.loads,
            "reached": run.reached, "errors": errors, "hitches": run.hitchReport(8), "jumpExamples": Array(run.jumps.prefix(5)),
            "residentRows": chat.view.messages.count, "first": chat.view.messages.first?.id ?? "", "last": chat.view.messages.last?.id ?? "",
            "layoutMS": TranscriptLayoutClock.layoutSeconds * 1000, "measureMS": TranscriptLayoutClock.measureSeconds * 1000,
            "updateMS": TranscriptLayoutClock.updateSeconds * 1000, "rowBuildMS": TranscriptLayoutClock.hostBuildSeconds * 1000,
            "textLayoutMS": TranscriptLayoutClock.markdownLayoutSeconds * 1000, "rowLoopMS": TranscriptLayoutClock.rowLoopSeconds * 1000,
            "rowsMeasured": TranscriptLayoutClock.measuredRows, "identityWalks": TranscriptLayoutClock.identityWalks,
            "usage": Self.usage()])
        if let output = testEnvironment("PI_PERF_OUTPUT") {
            let directory = URL(fileURLWithPath: output)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let raw: [String: Any] = ["intervalMS": run.frames, "workMS": run.work, "jumps": run.jumps,
                                       "frameUptimes": run.frameUptimes, "blankAt": run.blankAt, "inputPoints": run.inputPoints,
                                       "documentHeights": run.documentHeights.map(Double.init)]
            try? JSONSerialization.data(withJSONObject: raw).write(to: directory.appendingPathComponent(label + ".json"))
        }
        TranscriptLayoutClock.reset()
    }
    /// Passive frame observation, without sending a zero-distance scroll that
    /// would change following/navigation. Includes async publication work.
    @MainActor private func observe(_ chat: LongChatScroll, timeout: Double = 120, until done: () -> Bool) async -> LongChatScroll.Run {
        var run = LongChatScroll.Run(), last: Double?
        let started = Self.now
        while Self.now - started < timeout {
            let time = Self.now
            run.frameUptimes.append(time)
            if let last { run.frames.append((time - last) * 1000) }
            last = time
            chat.draw()
            run.work.append((Self.now - time) * 1000)
            if chat.blankViewport { run.blankFrames += 1; run.blankAt.append(run.work.count - 1) }
            if done() { run.reached = true; break }
            try? await Task.sleep(for: .seconds(max(0, 1.0 / 60 - (Self.now - time))))
        }
        run.seconds = Self.now - started
        return run
    }
    @MainActor private func findShown(_ chat: LongChatScroll, pane: NativeTranscriptPane) -> Bool {
        guard let current = pane.find.current, pane.find.matches.indices.contains(current),
              let document = chat.document, !document.focusPending, let text = document.focusText,
              let manager = text.layoutManager, let container = text.textContainer, let clip = chat.scroll?.contentView,
              document.highlights.focus?.record == pane.find.matches[current].messageID,
              document.focusRange.location != NSNotFound,
              NSMaxRange(document.focusRange) <= (text.textStorage?.length ?? 0) else { return false }
        let rect = text.convert(manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: document.focusRange, actualCharacterRange: nil), in: container), to: clip)
        return clip.bounds.contains(CGPoint(x: clip.bounds.midX, y: rect.midY))
    }
    @MainActor func testMeasureLongChat() async throws {
        let path = try XCTUnwrap(testEnvironment("PI_PERF_JOURNAL"))
        let buildRoot = try XCTUnwrap(testEnvironment("PI_PERF_ROOT"))
        let journalURL = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let rootURL = URL(fileURLWithPath: buildRoot).resolvingSymlinksInPath().standardizedFileURL
        guard journalURL.path.hasPrefix(rootURL.path + "/") else {
            XCTFail("Use only a generated journal inside PI_PERF_ROOT")
            return
        }
        Self.report("environment", ["temporaryDirectory": FileManager.default.temporaryDirectory.path,
                                    "hostID": Bundle.main.bundleIdentifier ?? "", "configuration": "Release"])
        let live = testEnvironment("PI_PERF_SOURCE") == "helper"
        let previous = TranscriptDisplay.mode
        TranscriptDisplay.use(.compact)
        TranscriptLayoutClock.recording = true; TranscriptLayoutClock.reset()
        defer { TranscriptDisplay.use(previous); TranscriptLayoutClock.recording = false }
        let watchdog = SoakStallWatchdog(threshold: 0.1)
        watchdog.start()
        defer {
            watchdog.stop()
            Self.report("mainQueue", ["over100MS": watchdog.slowAnswers.map { $0 * 1000 },
                "stalls": watchdog.recorded.map { ["at": $0.at, "ms": $0.duration * 1000, "label": $0.label] as [String: Any] }])
        }
        try Self.pids()
        if testEnvironment("PI_PERF_PROFILE_PAUSE") == "1" { try await Task.sleep(for: .seconds(1)) }
        let began = Self.now, usageBefore = Self.usage()
        var selectAt = began, helper: HostSupervisor?
        watchdog.label("opening")
        let switchingFirst = testEnvironment("PI_PERF_SWITCH_FIRST") == "1"
        let chat = try await LongChatScroll(turns: 0, journalFile: journalURL, lastMessageID: "compact-final", startingWithOtherChat: switchingFirst, preparePaneBeforeSelection: true) { model, record in
            self.registerWorkspaceFixtureTeardown(model, root: model.root.deletingLastPathComponent())
            model.openSteps = { [weak model] id, step in
                if step == "select", id == "long" { selectAt = Self.now }
                Self.report("open.step", ["chat": id, "step": step, "ms": (Self.now - selectAt) * 1000,
                    "positionsTotal": model?.displays[id]?.historyPositions.total ?? -1])
            }
            if live {
                // Keep the fixture helper-owned for the whole scroll trial.
                // The default 120-second idle retirement is a separate handoff
                // scenario, selected explicitly when measuring that behavior.
                if testEnvironment("PI_PERF_DEFAULT_IDLE") != "1" { model.configuration.runtime.idleGraceSeconds = 7_200 }
                Self.report("helper.fixturePolicy", ["idleGraceSeconds": model.configuration.runtime.idleGraceSeconds])
                let timeout = testEnvironment("PI_PERF_ACK_SECONDS").flatMap(Double.init).map { Duration.seconds($0) }
                let host = HostSupervisor(acknowledgmentTimeout: timeout); helper = host
                self.addTeardownBlock { @MainActor in try? await host.shutdownAndWait() }
                let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
                let state = directory.appendingPathComponent("host-" + UUID().uuidString)
                try await host.connect(cwd: directory, state: state)
                try Self.pids(helper: host.helperProcessIdentifier)
                _ = try await host.request("workspace.open", params: ["cwd": .string(directory.path), "directory": .string(directory.path), "mcp": .object(["servers": .object([:])])])
                var profile = ProfileRecord(); profile.id = "profile"; profile.modelId = "fixture"; profile.baseUrl = "http://127.0.0.1:1/v1"
                let opened = Self.now
                do {
                    _ = try await host.request("session.open", sessionID: "long", params: ["profile": profile.wire, "apiKey": .string("synthetic-only"), "path": .string(path), "connectionTest": .bool(true)])
                } catch {
                    Self.report("helper.open.failure", ["ms": (Self.now - opened) * 1000, "error": String(describing: error), "usage": Self.usage(host.helperProcessIdentifier ?? 0)])
                    throw error
                }
                Self.report("helper.open", ["ms": (Self.now - opened) * 1000, "usage": Self.usage(host.helperProcessIdentifier ?? 0)])
                if testEnvironment("PI_PERF_HELPER_HOT") == "1" {
                    let indexing = Self.now
                    _ = try await host.request("session.history", sessionID: "long", params: ["version": .number(2), "edge": .string("start")])
                    Self.report("helper.indexReady", ["ms": (Self.now - indexing) * 1000, "usage": Self.usage(host.helperProcessIdentifier ?? 0)])
                }
                model.hosts[record.workspaceID] = host; model.opened.insert(record.id)
            }
        }
        addTeardownBlock { @MainActor in chat.close() }
        let opening = await observe(chat) {
            chat.view.historyState == .ready && chat.document?.visibleContentPrepared == true && !chat.blankViewport
        }
        XCTAssertTrue(opening.reached, "The opening viewport never became useful")
        Self.report("open", ["source": live ? "helper" : "journal", "fixture": path,
            "switchFromOtherChat": switchingFirst,
            "selectionToFirstDrawMS": (Self.now - selectAt) * 1000, "fixtureStartToDrawMS": (Self.now - began) * 1000,
            "processLaunchToDrawMS": Self.launchedAt().map { (Date().timeIntervalSince1970 - $0) * 1000 } ?? -1,
            "positionsTotal": chat.view.historyPositions.total ?? -1, "rowHeight": chat.view.historyPositions.rowHeight ?? -1,
            "residentRows": chat.view.messages.count, "usageBefore": usageBefore, "usage": Self.usage()])
        frames(opening, label: "opening.frames", chat: chat)
        var sawFill = chat.view.presentation.openingFill != nil
        let filled = await observe(chat) {
            sawFill = sawFill || chat.view.presentation.openingFill != nil
            return (sawFill && chat.view.presentation.openingFill == nil) ||
                (!chat.view.presentation.openingPage && !chat.view.olderPage.loading && chat.view.historyPositions.rowHeight != nil)
        }
        let fillErrors = [chat.view.olderPage.error, chat.view.newerPage.error].compactMap { $0 }
        Self.report("wholeChatReady", ["ms": (Self.now - selectAt) * 1000, "ready": filled.reached && !chat.view.presentation.openingPage && fillErrors.isEmpty,
            "positionsTotal": chat.view.historyPositions.total ?? -1, "residentRows": chat.view.messages.count,
            "errors": fillErrors])
        frames(filled, label: "opening.fill", chat: chat)
        if testEnvironment("PI_PERF_OPEN_ONLY") == "1" { return }
        watchdog.label("switch and wheel")

        // A real pane switch with the other chat already drawn. The long
        // chat retains its page, matching an ordinary recent-chat revisit.
        let other = ChatRecord(id: "other", workspaceID: "project", title: "Other", path: nil, profileID: "profile")
        chat.model.chats.append(other)
        await chat.model.select("other")
        let small = try XCTUnwrap(chat.model.selected)
        small.messages = [TranscriptMessage(id: "other-message", role: "user", text: "A short generated chat.")]
        chat.pane.show(session: small, chat: other); chat.draw()
        let switched = Self.now
        await chat.model.select("long")
        chat.pane.show(session: chat.view, chat: chat.chat)
        let switching = await observe(chat) { chat.view.historyState == .ready && chat.document?.visibleContentPrepared == true && !chat.blankViewport }
        Self.report("switch.cached", ["ms": (Self.now - switched) * 1000, "ready": switching.reached])
        frames(switching, label: "switch.frames", chat: chat)
        if testEnvironment("PI_PERF_STREAM_ONLY") == "1" {
            watchdog.label("streaming")
            try await streaming(chat)
            Self.report("final.usage", ["app": Self.usage(), "helper": helper?.helperProcessIdentifier.map { Self.usage($0) } ?? [:]])
            return
        }

        if testEnvironment("PI_PERF_FIND_ONLY") != "1" {
        // Follow at least ten completed windows, or the entire 10k fixture.
        // CG wheel input is real. Decaying steps reproduce a momentum tail;
        // the harness does not claim this is physical trackpad hardware.
        var windows: Set<String> = [], previousIDs = Set(chat.view.messages.map(\.id))
        var seenIDs = previousIDs
        var committedFirst: String?, hasWindowBaseline = false
        var startedRead: Double?, requestRows: Set<String> = [], latencies: [Double] = []
        func tick() {
            if chat.view.jumpRead != nil || chat.view.historyState.loading || chat.view.olderPage.loading || chat.view.newerPage.loading {
                if startedRead == nil { startedRead = Self.now; requestRows = previousIDs }
            }
            let known = Set(chat.view.messages.map(\.id))
            if known != previousIDs {
                let added = known.subtracting(previousIDs)
                Self.report("window.change", ["rows": known.count, "added": added.count,
                    "readmitted": added.intersection(seenIDs).count, "evicted": previousIDs.subtracting(known).count,
                    "first": chat.view.messages.first?.id ?? "", "last": chat.view.messages.last?.id ?? "",
                    "knob": chat.knobFraction, "residentBytes": chat.view.messageBytes])
                seenIDs.formUnion(known)
            }
            previousIDs = known
            if chat.view.historyState == .ready, !chat.view.presentation.openingPage, chat.view.jumpRead == nil,
               !chat.view.olderPage.loading, !chat.view.newerPage.loading, !chat.blankViewport,
               let first = chat.view.messages.first?.id, first != committedFirst {
                if hasWindowBaseline { windows.insert(first) }
                committedFirst = first; hasWindowBaseline = true
            }
            if let startedRead, let document = chat.document, let clip = chat.scroll?.contentView.bounds {
                let drawn = document.retainedRows.filter { !$0.foldedAway && $0.frame.intersects(clip) && $0.superview != nil }.flatMap { $0.item.messageIDs }
                if drawn.contains(where: { !requestRows.contains($0) }) {
                    latencies.append((Self.now - startedRead) * 1000); selfReadFinished()
                }
            }
        }
        func selfReadFinished() { startedRead = nil }
        // Repeated two-second wheel bursts: steady input, a decaying tail,
        // then 20 quiet frames. Continuous motion is a separate stress knob.
        let continuous = testEnvironment("PI_PERF_CONTINUOUS_WHEEL") == "1"
        let dwell = max(0, Int(testEnvironment("PI_PERF_DWELL_FRAMES") ?? "") ?? 20)
        let wheelPoints = Double(testEnvironment("PI_PERF_WHEEL_POINTS") ?? "") ?? 480
        let wheelSeconds = Double(testEnvironment("PI_PERF_WHEEL_SECONDS") ?? "") ?? 120
        let cycle = continuous ? 120 : 100 + dwell
        func wheelStep(_ frame: Int) -> CGFloat {
            let phase = frame % cycle
            if continuous { return phase < 85 ? wheelPoints : max(wheelPoints / 16, wheelPoints * pow(0.91, Double(phase - 85))) }
            return phase < 70 ? wheelPoints : phase < 100 ? max(wheelPoints / 96, wheelPoints * pow(0.87, Double(phase - 70))) : 0
        }
        func wheelPhases(_ frame: Int) -> (scroll: Int64, momentum: Int64) {
            let phase = frame % cycle, fingerEnd = continuous ? 84 : 69, coastEnd = continuous ? 119 : 99
            if phase == 0 { return (1, 0) } // CGScrollPhase began/changed/ended.
            if phase < fingerEnd { return (2, 0) }
            if phase == fingerEnd { return (4, 0) }
            if phase == fingerEnd + 1 { return (0, 1) } // CGMomentumScrollPhase begin/continue/end.
            if phase < coastEnd { return (0, 2) }
            return phase == coastEnd ? (0, 3) : (0, 0)
        }
        let up = await chat.drive(points: wheelPoints, seconds: wheelSeconds, input: .wheel,
            pointsAtFrame: wheelStep, wheelPhases: wheelPhases,
            onFrame: tick) { windows.count >= 12 || chat.atFirstMessage }
        frames(up, label: "wheel.up", chat: chat)
        Self.report("page.requestToNewRowsVisible", ["valuesMS": latencies, "windows": windows.count])
        Self.report("wheel.up.coverage", ["tenWindows": windows.count >= 10, "reachedStart": chat.atFirstMessage, "phasedWheel": true,
            "continuous": continuous, "dwellFrames": dwell, "pointsPerSteadyFrame": wheelPoints, "limitSeconds": wheelSeconds])
        windows.removeAll(); latencies.removeAll(); startedRead = nil
        let down = await chat.drive(points: -wheelPoints, seconds: wheelSeconds, input: .wheel,
            pointsAtFrame: { -wheelStep($0) }, wheelPhases: wheelPhases, onFrame: tick) { chat.atLastMessage }
        frames(down, label: "wheel.down", chat: chat)
        Self.report("page.requestToNewRowsVisible.down", ["valuesMS": latencies, "windows": windows.count])
        if testEnvironment("PI_PERF_WHEEL_ONLY") == "1" { return }

        for fraction: CGFloat in [0.17, 0.73, 0.39, 0.91] {
            watchdog.label("drag \(fraction)")
            let start = Self.now
            let drag = await chat.drive(points: 0, seconds: 0.35, input: .drag({ _ in return fraction })) { false }
            frames(drag, label: "drag.\(fraction)", chat: chat)
            let landed = await observe(chat, timeout: 15) { !chat.blankViewport && chat.document?.visibleContentPrepared == true && !chat.view.historyState.loading && !chat.view.olderPage.loading && !chat.view.newerPage.loading }
            Self.report("drag.landed", ["fraction": fraction, "ms": (Self.now - start) * 1000, "ready": landed.reached, "knob": chat.knobFraction])
            frames(landed, label: "drag.settle.\(fraction)", chat: chat)
        }
        for top in [true, false] {
            watchdog.label("fling \(top)")
            let start = Self.now
            chat.wheel(top ? 100_000_000 : -100_000_000)
            let flung = await observe(chat, timeout: 30) { top ? chat.atFirstMessage : chat.atLastMessage }
            Self.report("wheel.fling", ["top": top, "ms": (Self.now - start) * 1000, "reached": flung.reached])
            frames(flung, label: top ? "wheel.fling.first" : "wheel.fling.last", chat: chat)
            let home = Self.now
            chat.scroll?.scroll(by: top ? .top : .bottom)
            let run = await observe(chat, timeout: 15) { top ? chat.atFirstMessage : chat.atLastMessage }
            Self.report("home.edge", ["top": top, "ms": (Self.now - home) * 1000, "reached": run.reached])
            frames(run, label: top ? "home.first" : "home.last", chat: chat)
        }
        }
        if testEnvironment("PI_PERF_SKIP_FIND") != "1" {
            watchdog.label("find")
            let pane = try XCTUnwrap(LongChatScroll.views(NativeTranscriptPane.self, in: chat.pane).first)
            chat.model.findInFocusedConversation(.show, in: chat.window)
            _ = await observe(chat, timeout: 5) { pane.findBar != nil }
            let bar = try XCTUnwrap(pane.findBar), started = Self.now
            var initialScanCompletedAt: Double?
            pane.find.performanceScanCompleted = { seconds, refreshing, matches in
                if !refreshing && initialScanCompletedAt == nil { initialScanCompletedAt = Self.now }
                Self.report("find.scanComplete", ["ms": (Self.now - started) * 1000, "scanMS": seconds * 1000,
                    "refreshing": refreshing, "matches": matches])
            }
            defer { pane.find.performanceScanCompleted = nil }
            bar.field.text = "perfneedle"; bar.field.onChange?("perfneedle")
            let searchLimit = Double(testEnvironment("PI_PERF_FIND_SECONDS") ?? "") ?? 60
            var firstMatchReported = false
            var progressAt = started
            let found = await observe(chat, timeout: searchLimit) {
                let shown = findShown(chat, pane: pane)
                if Self.now - progressAt >= 30 {
                    progressAt = Self.now
                    Self.report("find.progress", ["ms": (Self.now - started) * 1000, "matches": pane.find.matches.count,
                        "lastRecord": pane.find.matches.last?.messageID ?? "", "searching": pane.find.searching,
                        "highlightReady": shown, "usage": Self.usage()])
                }
                if shown && !firstMatchReported {
                    firstMatchReported = true
                    Self.report("find.firstMatch", ["ms": (Self.now - started) * 1000, "matches": pane.find.matches.count,
                        "searching": pane.find.searching])
                }
                return initialScanCompletedAt != nil
            }
            Self.report("find.search", ["ms": ((initialScanCompletedAt ?? Self.now) - started) * 1000,
                "matches": pane.find.matches.count, "ready": found.reached, "initialScanComplete": initialScanCompletedAt != nil,
                "highlightReady": findShown(chat, pane: pane),
                "limitSeconds": searchLimit,
                "searching": pane.find.searching, "focusPending": chat.document?.focusPending ?? false,
                "focusedRecord": chat.document?.highlights.focus?.record ?? "", "focusRange": NSStringFromRange(chat.document?.focusRange ?? NSRange()),
                "currentRecord": pane.find.current.flatMap { pane.find.matches.indices.contains($0) ? pane.find.matches[$0].messageID : nil } ?? ""])
            if initialScanCompletedAt != nil, let expected = testEnvironment("PI_PERF_EXPECTED_MATCHES").flatMap(Int.init) {
                XCTAssertEqual(pane.find.matches.count, expected, "A complete Find scan must cover the whole generated chat")
            }
            frames(found, label: "find.search.frames", chat: chat)
            if testEnvironment("PI_PERF_FIND_REFRESH_DIAGNOSTIC") == "1" {
                let refresh = await observe(chat, timeout: 20) { false }
                frames(refresh, label: "find.refresh.diagnostic", chat: chat)
            }
            for (index, direction) in [1, 1, -1, -1, -1].enumerated() {
                let start = Self.now
                pane.find.step(direction)
                let shown = await observe(chat, timeout: 15) { findShown(chat, pane: pane) }
                Self.report("find.step", ["ms": (Self.now - start) * 1000, "index": index, "ready": shown.reached,
                    "searchComplete": initialScanCompletedAt != nil, "searching": pane.find.searching, "matches": pane.find.matches.count,
                    "currentRecord": pane.find.current.flatMap { pane.find.matches.indices.contains($0) ? pane.find.matches[$0].messageID : nil } ?? ""])
                frames(shown, label: "find.step.\(index)", chat: chat)
            }
            pane.closeFind(focusing: true)
        }
        chat.beginGesture(); chat.dragKnob(to: 0.45); chat.endGesture()
        watchdog.label("resize")
        _ = await observe(chat) { !chat.blankViewport && !chat.view.historyState.loading }
        var resized = 0
        let resize = await chat.drive(points: 0, seconds: 2, input: .wheel, onFrame: {
            resized += 1
            chat.window.setContentSize(NSSize(width: 820 + 160 * sin(Double(resized) * 0.12), height: 760))
        }) { false }
        frames(resize, label: "resize.history", chat: chat)
        if testEnvironment("PI_PERF_STREAM") == "1" { watchdog.label("streaming"); try await streaming(chat) }
        Self.report("final.usage", ["app": Self.usage(), "helper": helper?.helperProcessIdentifier.map { Self.usage($0) } ?? [:]])
        if let helper { try await helper.shutdownAndWait() }
    }

    /// Same native row-update path as TranscriptFrameBudgetTests, now in a
    /// paged 50k journal. Measures display delivery, not a network/provider.
    @MainActor private func streaming(_ chat: LongChatScroll) async throws {
        chat.model.latest(sessionID: "long")
        _ = await observe(chat) { !chat.view.browsingHistory && chat.view.historyState == .ready && !chat.view.presentation.openingPage }
        let row = TranscriptMessage(id: "stream:perf", role: "assistant", text: "Starting. ", state: "streaming", turn: "perf-user")
        chat.view.appendMessage(TranscriptMessage(id: "perf-user", role: "user", text: "Continue the generated check."))
        chat.view.appendMessage(row)
        chat.view.runState = .running
        _ = await observe(chat, timeout: 3) { chat.document?.visibleContentPrepared == true }
        for away in [false, true] {
            if away {
                chat.beginGesture(); chat.gestureStep(3000); chat.endGesture()
                _ = await observe(chat, timeout: 3) { chat.document?.pageFollowsBottom == false && chat.highest - chat.clipY > 1000 }
            }
            XCTAssertEqual(chat.document?.pageFollowsBottom, !away, "Verify the actual reader mode, not just the requested gesture")
            let startClip = chat.clipY
            var ticks = 0, costs: [Double] = []
            let result = await observe(chat, timeout: 12) {
                if ticks >= 240 { return true }
                if ticks.isMultiple(of: 2) {
                    let start = Self.now
                    if let index = chat.view.messages.firstIndex(where: { $0.id == row.id }) {
                        var changed = chat.view.messages[index]
                        changed.text += "Token \(ticks): `parse(input)` keeps the boundary.\n"
                        chat.view.replaceMessage(at: index, with: changed)
                        chat.draw()
                        costs.append((Self.now - start) * 1000)
                    }
                }
                ticks += 1
                return false
            }
            Self.report("stream.delivery", ["away": away, "deltas": costs.count, "meanMS": costs.reduce(0, +) / Double(max(1, costs.count)), "maxMS": costs.max() ?? 0,
                "residentRows": chat.view.messages.count, "totalRows": chat.view.historyPositions.total ?? -1,
                "followsBottom": chat.document?.pageFollowsBottom ?? true, "startClipY": startClip, "endClipY": chat.clipY,
                "distanceFromEnd": chat.highest - chat.clipY,
                "streamOnScreen": chat.document?.retainedRows.contains(where: { $0.item.messageIDs.contains(row.id) && $0.frame.intersects(chat.scroll?.contentView.bounds ?? .zero) }) ?? false,
                "appends": TranscriptLayoutClock.streamingAppends, "estimates": TranscriptLayoutClock.streamingEstimates,
                "rebuilds": TranscriptLayoutClock.streamingRebuilds])
            XCTAssertEqual(costs.count, 120, "Every measured token must update a retained stream row")
            XCTAssertEqual(chat.document?.pageFollowsBottom, !away, "Streaming must not change the reader's mode")
            frames(result, label: away ? "stream.away" : "stream.follow", chat: chat)
        }
    }
}
