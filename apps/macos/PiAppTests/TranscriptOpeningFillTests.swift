import XCTest
import AppKit
import Combine
@testable import PiApp

private actor OpeningFillReadGate {
    private(set) var started = false
    private var waiting: CheckedContinuation<Void, Never>?
    func read() async { started = true; await withCheckedContinuation { waiting = $0 } }
    func release() { waiting?.resume(); waiting = nil }
}

final class TranscriptOpeningFillTests: XCTestCase, SerialTestLane {
    @MainActor private func chat(width: CGFloat = 900) async throws -> LongChatScroll {
        let mode = TranscriptDisplay.mode
        TranscriptDisplay.use(.compact)
        let journal = try ToolHeavyJournal.make(turns: 30)
        let chat = try await LongChatScroll(turns: 30, width: width, journal: journal)
        registerWorkspaceFixtureTeardown(chat.model, root: chat.root)
        addTeardownBlock { @MainActor in chat.close(); TranscriptDisplay.use(mode) }
        return chat
    }

    @MainActor private func firstRows(_ chat: LongChatScroll) async throws -> Double {
        try await eventually("The first viewport never became ready", timeout: .seconds(10)) {
            chat.draw(); return chat.view.historyState == .ready && chat.document?.visibleContentPrepared == true
        }
        return PerformanceProbe.now - chat.view.presentation.startedAt
    }

    @MainActor func testOpeningShowsSmallPageThenFillsWithoutMovingRows() async throws {
        let chat = try await chat()
        let initial = chat.view.messages.count
        XCTAssertLessThanOrEqual(initial, 250)
        XCTAssertEqual(chat.view.messages.first?.id, "u28")
        let first = try await firstRows(chat)
        let visits = chat.view.presentedMessageVisits, prepared = TranscriptOpeningPlans.used
        var admissions: [Int] = []
        let updates = chat.view.transcriptChanges.dropFirst().sink { admissions.append($0.count) }
        defer { updates.cancel() }
        let run = await chat.drive(points: 0, seconds: 10) { chat.view.messages.count >= 974 && !chat.view.presentation.openingPage }
        print(String(format: "OPENFILL first %.1f ms (%d rows), full %.1f ms (%d rows), admissions %@", first, initial,
                     PerformanceProbe.now - chat.view.presentation.startedAt, chat.view.messages.count, admissions.description))
        print(run.summary("opening fill, stationary reader"))
        XCTAssertTrue(run.reached)
        XCTAssertEqual(chat.view.messages.first?.id, "u20")
        XCTAssertEqual(chat.view.messages.count, 974)
        XCTAssertGreaterThan(admissions.count, 1, "The rest of the page must arrive in separate main-thread steps")
        XCTAssertEqual(run.jumps, []); XCTAssertEqual(run.lost, 0); XCTAssertEqual(run.blankFrames, 0)
        XCTAssertTrue(admissions.allSatisfy { $0 <= 1_000 })
        XCTAssertLessThanOrEqual(chat.view.presentedMessageVisits - visits, 1_000, "The fill projected unchanged history again on the main actor")
        XCTAssertGreaterThan(TranscriptOpeningPlans.used, prepared, "The prepared history plan never reached the page")
        let snapshot = try XCTUnwrap(chat.page?.snapshot)
        XCTAssertEqual(snapshot.items, TranscriptActivity.blocks(of: snapshot.messages, lifecycle: snapshot.lifecycle, complete: snapshot.complete))
        let prefix = chat.view.messages.map(\.id)
        _ = await chat.model.loadEarlierPage(sessionID: chat.chat.id)
        XCTAssertGreaterThan(chat.view.messages.count - prefix.count, 750, "Subsequent history reads still use 1,000-row pages")
    }

    @MainActor func testTokensStayIncrementalWhileOpeningFills() async throws {
        let chat = try await chat()
        let initial = chat.view.messages.count
        XCTAssertLessThanOrEqual(initial, 250)
        _ = try await firstRows(chat)
        let page = try XCTUnwrap(chat.page); page.presentationInterval = 0
        var live = TranscriptMessage(id: "opening-live", role: "assistant", text: "", state: "streaming", turn: "u29")
        chat.view.appendMessage(live); chat.draw()
        let reply = (0..<120).map {
            "## Step \($0)\n\nHere is what changed in `file\($0).swift`: the handler now **retries** twice and logs the reason.\n\n1. First point with detail.\n2. Second point with more detail.\n\n```swift\nlet value = compute(index: \($0))\n```\n"
        }.joined(separator: "\n")
        let bytes = Array(reply.utf8)
        var costs: [Double] = [], duringCosts: [Double] = [], afterCosts: [Double] = []
        var fullAt: Double?
        let deadline = PerformanceProbe.now + 10_000
        while PerformanceProbe.now < deadline, costs.count < 80 {
            let during = chat.view.messages.count < 975
            let index = try XCTUnwrap(chat.view.messagePositions[live.id])
            live.text = String(decoding: bytes.prefix((costs.count + 1) * 300), as: UTF8.self)
            let start = PerformanceProbe.now
            chat.view.replaceMessage(at: index, with: live); chat.draw()
            let cost = PerformanceProbe.now - start
            costs.append(cost)
            if during { duringCosts.append(cost) } else { afterCosts.append(cost) }
            if !during, fullAt == nil { fullAt = PerformanceProbe.now - chat.view.presentation.startedAt }
            XCTAssertEqual(page.snapshot?.messages.last?.text, live.text)
            let native = try XCTUnwrap(chat.document?.row(drawing: live.id))
            XCTAssertEqual(native.contentItem, page.snapshot?.items.first { $0.id == native.itemID })
            try await Task.sleep(for: .milliseconds(16))
            if !during, afterCosts.count >= 12 { break }
        }
        func mean(_ values: [Double]) -> Double { values.reduce(0,+) / Double(max(1, values.count)) }
        print(String(format: "OPENFILL streaming: during fill %d tokens mean/max %.3f/%.3f ms; after %d tokens mean/max %.3f/%.3f ms; full %.1f ms, %d rows",
                     duringCosts.count, mean(duringCosts), duringCosts.max() ?? 0, afterCosts.count, mean(afterCosts), afterCosts.max() ?? 0,
                     fullAt ?? PerformanceProbe.now - chat.view.presentation.startedAt, chat.view.messages.count))
        XCTAssertGreaterThan(duringCosts.count, 0)
        XCTAssertLessThan(mean(duringCosts), releaseBudget(0.012) * 1_000)
        XCTAssertEqual(chat.view.messages.count, 975)
        XCTAssertEqual(chat.view.messages.last?.text, live.text, "A background history read replaced live content")
        XCTAssertLessThan(costs.reduce(0,+) / Double(max(1,costs.count)), releaseBudget(0.012) * 1_000)
        let snapshot = try XCTUnwrap(page.snapshot)
        XCTAssertEqual(snapshot.items, TranscriptActivity.blocks(of: snapshot.messages, lifecycle: snapshot.lifecycle, complete: snapshot.complete))
    }

    @MainActor func testRepeatedTailEditsStopTheSpeculativeFillAndKeepPagingAvailable() async throws {
        let chat = try await chat(), view = chat.view
        view.state = "running"; view.runStatus = "running"
        let opening = view.messages.map(\.id), boundary = view.olderPage.cursor
        var projections = 0
        chat.model.openSteps = { id, step in
            guard id == view.id, step == "opening fill projected" else { return }
            projections += 1
            view.appendMessage(.init(id: "tail-\(projections)", role: "assistant", text: "New response part", state: "streaming", turn: "u29"))
            // A broken retry limit must fail by count, without hanging the test.
            if projections == 12 {
                view.presentation.openingFill?.cancel(); view.presentation.openingFill = nil
            }
        }
        defer { chat.model.openSteps = nil }
        chat.model.startOpeningFill(chat.chat.id)
        let fill = try XCTUnwrap(view.presentation.openingFill)
        await fill.value
        print("OPENFILL repeated tail edits: \(projections) projections")
        XCTAssertEqual(projections, 4, "A busy tail must stop speculative work after a bounded number of projections")
        XCTAssertNil(view.presentation.openingFill)
        XCTAssertTrue(view.presentation.openingPage)
        XCTAssertEqual(view.olderPage.cursor, boundary, "The unread history remains retryable")
        XCTAssertEqual(view.messages.map(\.id), opening + (0..<projections).map { "tail-\($0 + 1)" })
        XCTAssertEqual(view.notice, "")
        chat.model.openSteps = nil
        let loaded = await chat.model.loadHistoryPage(chat.chat.id, newer: false, automatic: true)
        XCTAssertTrue(loaded, "Scrolling must still load history after speculative retries are exhausted")
        XCTAssertGreaterThan(view.messages.count, 1_000)
        XCTAssertEqual(view.messages.last?.id, "tail-\(projections)")
    }

    @MainActor func testATransientTailEditCanRetryEachOpeningBatch() async throws {
        let chat = try await chat(), view = chat.view
        view.state = "running"; view.runStatus = "running"
        var projections = 0, admitted = 0, changed = false
        chat.model.openSteps = { id, step in
            guard id == view.id else { return }
            if step == "opening fill step" { admitted += 1; changed = false }
            if step == "opening fill projected" {
                projections += 1
                if !changed {
                    changed = true
                    view.appendMessage(.init(id: "tail-\(admitted)", role: "assistant", text: "New response part", state: "streaming", turn: "u29"))
                }
            }
        }
        defer { chat.model.openSteps = nil }
        chat.model.startOpeningFill(chat.chat.id)
        let fill = try XCTUnwrap(view.presentation.openingFill)
        await fill.value
        print("OPENFILL transient tail edits: \(projections) projections, \(admitted) admitted batches")
        XCTAssertGreaterThan(admitted, 4, "The retry allowance starts again for each batch")
        XCTAssertEqual(projections, 2 * admitted)
        XCTAssertFalse(view.presentation.openingPage)
        XCTAssertNil(view.presentation.openingFill)
        XCTAssertEqual(view.messages.count, 974 + admitted)
        XCTAssertEqual(view.messages.first?.id, "u20")
        XCTAssertEqual(view.messages.suffix(admitted).map(\.id), (0..<admitted).map { "tail-\($0)" })
    }

    func testFillPlannerKeepsWholeTurnsInBothDirections() {
        let all = (0..<1_200).map { index in
            TranscriptMessage(id: "m\(index)", role: index % 50 == 0 ? "user" : "assistant", text: "Row \(index)")
        }
        let limits = HistoryWindowPolicy.PageLimits.standard
        for newer in [false, true] {
            let opening = Array(newer ? all.prefix(250) : all.suffix(250))
            let page = Array(newer ? all.suffix(950) : all.prefix(950))
            let plan = TranscriptOpeningFill(page: page, opening: opening, newer: newer, limits: limits)
            XCTAssertGreaterThan(plan.batches.count, 1)
            XCTAssertTrue(plan.batches.allSatisfy { $0.count <= 128 && $0.first?.role == "user" })
            let added = (newer ? plan.batches : Array(plan.batches.reversed())).flatMap { $0 }
            let joined = newer ? opening + added : added + opening
            XCTAssertEqual(joined.map(\.id), Array(newer ? all.prefix(1_000) : all.suffix(1_000)).map(\.id))
            XCTAssertEqual(Set(joined.map(\.id)).count, joined.count)
        }
        // The source's partial old turn must not be mistaken for a new one.
        let partial = Array(all[25..<250])
        let plan = TranscriptOpeningFill(page: partial, opening: Array(all[250..<500]), newer: false, limits: limits, firstIsStart: false)
        XCTAssertEqual(plan.batches.last?.first?.id, "m50")
    }

    @MainActor func testHistoricalOpeningFillsForwardAndKeepsTheReadersRow() async throws {
        let chat = try await chat()
        let other = ChatRecord(id: "other", workspaceID: "project", title: "Other", path: nil, profileID: "profile")
        chat.model.chats.append(other)
        await chat.model.select(other.id)
        chat.pane.show(session: try XCTUnwrap(chat.model.selected), chat: other)
        chat.view.scrollAnchor = .init(id: "u5", offset: 17, followsBottom: false)
        await chat.model.select(chat.chat.id)
        chat.pane.show(session: chat.view, chat: chat.chat)
        XCTAssertLessThanOrEqual(chat.view.messages.count, 250)
        XCTAssertEqual(chat.view.messages.first?.id, "u5")
        _ = try await firstRows(chat)
        let run = await chat.drive(points: 0, seconds: 10) { !chat.view.presentation.openingPage }
        print(run.summary("historical opening fill"))
        XCTAssertTrue(run.reached)
        XCTAssertGreaterThan(chat.view.messages.count, 750)
        XCTAssertLessThanOrEqual(chat.view.messages.count, 1_000)
        XCTAssertEqual(chat.view.messages.first?.id, "u5")
        XCTAssertNotNil(chat.view.newerPage.cursor)
        XCTAssertEqual(run.jumps, []); XCTAssertEqual(run.lost, 0); XCTAssertEqual(run.blankFrames, 0)
    }

    @MainActor func testLeavingDuringFillCancelsAndCachedRevisitResumes() async throws {
        let chat = try await chat()
        let path = try XCTUnwrap(chat.chat.path), history = chat.model.history
        let held = OpeningFillReadGate()
        chat.model.historyWindowLoader = { _, cursor, newer, around in
            await held.read()
            return try ConversationHistoryPage(await history.window(path: path, cursor: cursor, newer: newer, around: around))
        }
        _ = try await firstRows(chat)
        for _ in 0..<1_000 {
            if await held.started { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let entered = await held.started
        XCTAssertTrue(entered, "The opening fill never read its next page")
        let before = chat.view.messages.map(\.id)
        let other = ChatRecord(id: "other", workspaceID: "project", title: "Other", path: nil, profileID: "profile")
        chat.model.chats.append(other)
        chat.model.historyWindowLoader = nil
        await chat.model.select(other.id)
        await held.release()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(chat.view.messages.map(\.id), before, "A canceled background fill landed after leaving")
        XCTAssertNil(chat.view.presentation.openingFill)
        XCTAssertTrue(chat.view.presentation.openingPage, "A partial cached opening still needs its fill")
        await chat.model.select(chat.chat.id)
        chat.pane.show(session: chat.view, chat: chat.chat)
        _ = try await firstRows(chat)
        let run = await chat.drive(points: 0, seconds: 10) { !chat.view.presentation.openingPage }
        XCTAssertTrue(run.reached)
        XCTAssertEqual(chat.view.messages.count, 974)
        XCTAssertEqual(run.jumps, []); XCTAssertEqual(run.lost, 0)
    }

    @MainActor func testReplacingThePageCancelsOnlyItsOwnFill() async throws {
        let chat = try await chat(), held = OpeningFillReadGate()
        let path = try XCTUnwrap(chat.chat.path), history = chat.model.history
        chat.model.historyWindowLoader = { _, cursor, newer, around in
            await held.read()
            return try ConversationHistoryPage(await history.window(path: path, cursor: cursor, newer: newer, around: around))
        }
        _ = try await firstRows(chat)
        for _ in 0..<1_000 {
            if await held.started { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let original = try XCTUnwrap(chat.view.presentation.openingFill)
        let replacement = try ConversationHistoryPage(.object(["version": .number(2), "incarnation": .string("replacement"), "lineage": .string("root"),
            "messages": .array([.object(["id": .string("new"), "role": .string("user"), "text": .string("New page")])]), "older": .null, "newer": .null]))
        chat.model.adoptPage(replacement, into: chat.view, presenting: false)
        XCTAssertTrue(original.isCancelled, "Replacing the page left its old opening fill alive")
        XCTAssertNil(chat.view.presentation.openingFill)
        chat.view.presentation.openingFill = Task { }
        await held.release(); await original.value
        XCTAssertNotNil(chat.view.presentation.openingFill, "The canceled task cleared a newer fill")
        XCTAssertEqual(chat.view.messages.map(\.id), ["new"])
        chat.view.presentation.openingFill = nil
    }

    @MainActor func testPreparedFillKeepsATokenReceivedBeforePublication() async throws {
        let view = SessionDisplay(id: "prepared-token")
        view.messages = [.init(id: "q", role: "user", text: "Question"), .init(id: "reply", role: "assistant", text: "First", state: "streaming")]
        let shown = view.presentedMessages
        let projection = TranscriptOpeningProjection(raw: shown, overlay: [], agent: view.agentPresentation, lifecycle: nil, display: TranscriptDisplay.mode, complete: true)
        TranscriptOpeningPlans.install(projection, for: view)
        var live = view.messages[1]; live.text += " new token"
        view.replaceMessage(at: 1, with: live)
        let input = view.presentationChanges.value
        let items = try XCTUnwrap(TranscriptOpeningPlans.take(for: view, input: input, complete: true))
        XCTAssertEqual(items, TranscriptActivity.blocks(of: input.messages))
    }

    @MainActor func testPreparedFillRejectsAChangedLifecycle() throws {
        let view = SessionDisplay(id: "prepared-lifecycle")
        view.messages = [.init(id: "q", role: "user", text: "Question")]
        let projection = TranscriptOpeningProjection(raw: view.presentedMessages, overlay: [], agent: view.agentPresentation, lifecycle: nil, display: TranscriptDisplay.mode, complete: true)
        TranscriptOpeningPlans.install(projection, for: view)
        view.taskPresentation = .init(sessionID: view.id, epoch: "e", timeline: "t", sequence: 1, sourceRevision: "1",
                                      active: .init(rootID: "q", executionID: "run", startedAt: 1), recent: [])
        XCTAssertNil(TranscriptOpeningPlans.take(for: view, input: view.presentationChanges.value, complete: true))
    }

    @MainActor func testFailedFillLeavesAutomaticPagingAvailable() async throws {
        let chat = try await chat()
        chat.model.historyWindowLoader = { _, _, _, _ in throw HostError.failure("Generated fill failure") }
        _ = try await firstRows(chat)
        try await eventually("The failed speculative fill never ended") { chat.view.presentation.openingFill == nil }
        XCTAssertTrue(chat.view.presentation.openingPage)
        XCTAssertEqual(chat.view.notice, "")
        chat.model.historyWindowLoader = nil
        let loaded = await chat.model.loadHistoryPage(chat.chat.id, newer: false, automatic: true)
        XCTAssertTrue(loaded, "The fill's resume marker blocked ordinary paging")
        XCTAssertGreaterThan(chat.view.messages.count, 1_000)
    }

    @MainActor func testOpeningFillGallery() async throws {
        guard let folder = testEnvironment("PI_OPENING_GALLERY") else { throw XCTSkip("Set PI_OPENING_GALLERY to capture first/full pages") }
        let output = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, style, width) in [("light", NSAppearance.Name.aqua, 900.0), ("dark", .darkAqua, 900.0), ("narrow", .aqua, 520.0)] {
            let chat = try await chat(width: CGFloat(width))
            // Compare a constant viewport: AppKit can finish reading its
            // preferred scroller style after a test host's first frame.
            let scroll = try XCTUnwrap(chat.scroll)
            scroll.scrollerStyle = .legacy; scroll.autohidesScrollers = false
            scroll.tile(); chat.draw()
            chat.window.appearance = NSAppearance(named: style)
            _ = try await firstRows(chat)
            try await Task.sleep(for: .milliseconds(1))
            func capture(_ phase: String) throws {
                chat.draw()
                let content = try XCTUnwrap(chat.window.contentView)
                content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
                let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("opening-\(phase)-\(name).png"))
            }
            try capture("first")
            let firstFrame = try XCTUnwrap(chat.document?.row(drawing: "a29_z")).frame
            let run = await chat.drive(points: 0, seconds: 10) { !chat.view.presentation.openingPage }
            XCTAssertTrue(run.reached)
            XCTAssertEqual(run.jumps, []); XCTAssertEqual(run.lost, 0); XCTAssertEqual(run.blankFrames, 0)
            XCTAssertEqual(chat.view.messages.count, 974)
            try capture("full")
            let fullFrame = try XCTUnwrap(chat.document?.row(drawing: "a29_z")).frame
            XCTAssertEqual(fullFrame.minX, firstFrame.minX, accuracy: 0.5)
            XCTAssertEqual(fullFrame.width, firstFrame.width, accuracy: 0.5)
            chat.close()
        }
    }
}
