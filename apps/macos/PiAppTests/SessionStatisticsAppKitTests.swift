import AppKit
import SwiftUI
import XCTest
@testable import PiApp

/// The full card chrome around the separately validated native chart engine.
@MainActor final class SessionStatisticsParityTests: XCTestCase, SerialTestLane {
    override func setUp() async throws { PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws { PiKit.Motion.reducedOverride = nil }

    private func compare<V: View>(_ name: String, width: CGFloat, share: Double = 0.012, strongShare: Double = 0.002,
                                  _ reference: V, _ native: NSView, file: StaticString = #filePath, line: UInt = #line) async throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let result = try await PiKitParity.compare("stats-\(name)-\(Int(width))-\(suffix)", appearance: appearance,
                swiftUI: reference.frame(width: width), appKit: native, canvas: .piSurface, width: width)
            print("STATSPARITY " + result.description)
            XCTAssertEqual(result.swiftUIFit.height, result.appKitFit.height, accuracy: 0.5, "\(result.name) height", file: file, line: line)
            XCTAssertLessThanOrEqual(Double(result.differing), Double(result.total) * share, result.description, file: file, line: line)
            let strong = PiKitParity.difference(result.swiftUIImage, result.appKitImage, tolerance: 64).0
            XCTAssertLessThanOrEqual(Double(strong), Double(result.total) * strongShare, "\(result.name): \(strong) strong pixels", file: file, line: line)
        }
    }

    func testFullChartCardsMatchTheirReferences() async throws {
        let history = SessionStatsFixture.session(), inputs = SessionStatsFixture.inputs(history)
        let time = SessionTimeCharts(inputs: inputs, history: history), tokens = SessionTokenCharts(inputs: inputs, history: history)
        for width in [436.0, 650.0] {
            let timeline = try XCTUnwrap(time.timeline)
            try await compare("timeline", width: width, share: 0.07,
                SessionTimelineChartReference(timeline: timeline, selection: PiChartSelection()), SessionTimelineChart(timeline: timeline, selection: PiChartSelection()))
            let speed = try XCTUnwrap(time.speed)
            try await compare("speed", width: width,
                SessionSpeedChartReference(speed: speed, selection: PiChartSelection()), SessionSpeedChart(speed: speed, selection: PiChartSelection()))
            let bars = try XCTUnwrap(tokens.perRequest)
            try await compare("tokens", width: width, share: 0.05, strongShare: 0.007,
                SessionTokenBarsChartReference(bars: bars, selection: PiChartSelection()), SessionTokenBarsChart(bars: bars, selection: PiChartSelection()))
            let cost = try XCTUnwrap(tokens.cost)
            try await compare("cost", width: width,
                SessionCostChartReference(cost: cost, selection: PiChartSelection()), SessionCostChart(cost: cost, selection: PiChartSelection()))
        }
    }

    func testCompositionTimeSplitAndModelTablesMatch() async throws {
        let history = SessionStatsFixture.session(), inputs = SessionStatsFixture.inputs(history)
        let time = SessionTimeCharts(inputs: inputs, history: history), tokens = SessionTokenCharts(inputs: inputs, history: history)
        for width in [436.0, 650.0] {
            let split = try XCTUnwrap(time.split)
            try await compare("time-split", width: width, SessionTimeSplitViewReference(split: split), SessionTimeSplitView(split: split))
            let composition = try XCTUnwrap(tokens.composition)
            try await compare("composition", width: width, SessionCompositionViewReference(composition: composition), SessionCompositionView(composition: composition))
            try await compare("time-models", width: width, SessionModelTimeTableReference(rows: time.models), SessionModelTimeTable(rows: time.models))
            try await compare("token-models", width: width, SessionModelTokenTableReference(rows: tokens.models), SessionModelTokenTable(rows: tokens.models))
        }
    }

    func testLedgerAndLoadingStatesMatch() async throws {
        let history = SessionStatsFixture.session(requests: 3)
        let ledger = SessionRequestLedger(history: SessionTimingHistory(samples: history.requests, completedRequests: history.requests.count))
        for width in [1080.0, 1260.0] {
            try await compare("ledger", width: width, SessionRequestLedgerViewReference(ledger: ledger), SessionRequestLedgerView(ledger: ledger))
        }
        for loading in [false, true] {
            try await compare(loading ? "loading" : "empty", width: 436, SessionStatsLoadingNoteReference(loading: loading, failure: nil), SessionStatsLoadingNote(loading: loading, failure: nil))
        }
        try await compare("failure", width: 436, SessionStatsLoadingNoteReference(loading: false, failure: "The retained history could not be read."), SessionStatsLoadingNote(loading: false, failure: "The retained history could not be read."))
    }

    func testComposerInspectorButtonsMatch() async throws {
        let root = scratchRoot("stats-button-parity")
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        let chat = ChatRecord(id: "stats", workspaceID: WorkspaceRecord.scratchID, title: "Statistics", path: nil, profileID: "profile")
        let footer = SessionMetrics()
        for label: String? in [nil, "$0.1420"] {
            let button = SessionUsageButton(model: model, chat: chat, footer: footer, costLabel: label)
            // The same symbol-edge allowance as the DesignKit component gallery.
            try await compare(label == nil ? "inspector-button" : "cost-button", width: button.intrinsicContentSize.width, share: 0.03, strongShare: 0.004,
                SessionUsageButtonReference(model: model, chat: chat, footer: footer, costLabel: label), button)
            XCTAssertEqual(button.accessibilityLabel(), "Session Inspector: cost, tokens, time and every request")
            XCTAssertEqual(button.accessibilityIdentifier(), label == nil ? "sessionUsageButton" : "sessionUsageCostButton")
        }
    }
}

@MainActor final class SessionStatisticsControlTests: XCTestCase, SerialTestLane {
    private func window(_ view: NSView, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil); window.contentView = nil; window.close() } }
        return window
    }
    private func render(_ view: NSView) {
        view.layoutSubtreeIfNeeded(); view.window?.displayIfNeeded()
    }

    func testPointerSelectionUsesEachChartsGeometryAndOpensItsRequest() throws {
        PiKit.Motion.reducedOverride = true
        defer { PiKit.Motion.reducedOverride = nil }
        let history = SessionStatsFixture.session(), inputs = SessionStatsFixture.inputs(history)
        let time = SessionTimeCharts(inputs: inputs, history: history), tokens = SessionTokenCharts(inputs: inputs, history: history)
        var opened: [String] = []
        let timeline = SessionTimelineChart(timeline: try XCTUnwrap(time.timeline), selection: PiChartSelection(), open: { opened.append($0) })
        let speed = SessionSpeedChart(speed: try XCTUnwrap(time.speed), selection: PiChartSelection(), open: { opened.append($0) })
        let bars = SessionTokenBarsChart(bars: try XCTUnwrap(tokens.perRequest), selection: PiChartSelection(), open: { opened.append($0) })
        let cost = SessionCostChart(cost: try XCTUnwrap(tokens.cost), selection: PiChartSelection(), open: { opened.append($0) })
        for surface in [timeline.surface, speed.surface, bars.surface, cost.surface] {
            surface.frame = CGRect(x: 0, y: 0, width: 436, height: surface.plotHeight); surface.layoutSubtreeIfNeeded()
            let geometry = surface.chart.resolved(), index = 2
            let point: CGPoint
            switch surface.marker {
            case .timeline(let count): point = geometry.point(geometry.x.domain.upperBound / 2, Double(count - 1 - index))
            case .columns: point = geometry.point(Double(index), geometry.y.domain.upperBound / 2)
            case .point(let points): point = geometry.point(points[index].0, points[index].1)
            }
            surface.select(at: point); XCTAssertEqual(surface.selection.index, index)
            surface.openSelection(); XCTAssertEqual(opened.last, surface.requestIDs[index])
            surface.select(at: CGPoint(x: -1, y: -1)); XCTAssertNil(surface.selection.index)
            surface.openSelection(); XCTAssertEqual(opened.count, 1)
            opened = []
            XCTAssertEqual(surface.chart.accessibilityChildren()?.count, surface.chart.spec.accessibleMarks.count)
            XCTAssertNotNil(surface.chart.accessibilityChartDescriptor)
        }
    }

    func testHoverDrawsOnlyOverlayAndCaptionAndKeepsTheCardHeight() throws {
        PiKit.Motion.reducedOverride = true
        defer { PiKit.Motion.reducedOverride = nil }
        let history = SessionStatsFixture.session(), inputs = SessionStatsFixture.inputs(history)
        let speed = try XCTUnwrap(SessionTimeCharts(inputs: inputs, history: history).speed)
        let selection = PiChartSelection(), card = SessionSpeedChart(speed: speed, selection: selection, open: { _ in })
        let height = card.height(forWidth: 436)
        let window = window(card, size: CGSize(width: 436, height: height))
        render(card)
        let before = card.surface.chart.markDraws, geometry = card.surface.chart.resolved()
        SessionStatsRenderCount.reset()
        for index in [0, 3, 8, 1] {
            card.surface.select(at: geometry.point(speed.points[index].x, speed.points[index].rate))
            render(card); window.displayIfNeeded()
        }
        XCTAssertEqual(card.surface.chart.markDraws, before, "Pointer selection cannot redraw the marks")
        XCTAssertEqual(SessionStatsRenderCount.marks, 0); XCTAssertEqual(SessionStatsRenderCount.panels, 0)
        XCTAssertGreaterThanOrEqual(SessionStatsRenderCount.pointers, 4); XCTAssertGreaterThanOrEqual(SessionStatsRenderCount.captions, 4)
        XCTAssertEqual(card.height(forWidth: 436), height)
        XCTAssertTrue(window.makeFirstResponder(card.surface))
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        card.surface.keyDown(with: key); XCTAssertEqual(selection.index, 2, "The keyboard moves through request items")
    }

    func testLedgerWaitsForTheViewportAndReusesRowsWhenARequestSettles() throws {
        let history = SessionStatsFixture.session(requests: 100)
        let ledger = SessionRequestLedger(history: SessionTimingHistory(samples: history.requests, completedRequests: history.requests.count))
        let view = SessionRequestLedgerView(ledger: ledger, open: { _ in }, limit: 40)
        let spacer = FixedHeight(NSView(), height: 1500, fills: true)
        let column = ShellStack(.vertical, spacing: 8, [.view(spacer, .fill), .view(view, .fill)])
        let scroll = PageScrollView(column: column)
        let window = window(scroll, size: CGSize(width: 1080, height: 400))
        SessionStatsRenderCount.reset(); render(scroll)
        XCTAssertEqual(view.rows.made.count, 0, "The Overview does not build the ledger below the charts")
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 1530)); scroll.reflectScrolledClipView(scroll.contentView)
        render(scroll); view.rows.tileRows()
        XCTAssertGreaterThan(view.rows.made.count, 0)
        XCTAssertLessThan(view.rows.made.count, 20, "The card makes only rows near the viewport")
        let retained = try XCTUnwrap(view.rows.made.values.first), retainedID = retained.row.id
        window.makeFirstResponder(retained)
        var next = history.requests
        next.append(SessionStatsFixture.request(101, turn: "t26"))
        view.update(ledger: SessionRequestLedger(history: SessionTimingHistory(samples: next, completedRequests: next.count)))
        render(scroll); view.rows.tileRows()
        XCTAssertTrue(view.rows.made.values.contains(where: { $0 === retained && $0.row.id == retainedID }), "A retained request keeps its row and keyboard target")
        XCTAssertTrue(window.firstResponder === retained)
        XCTAssertEqual(view.rows.rows.count, 40); XCTAssertEqual(view.rows.rows.last?.id, "r101")
        XCTAssertEqual(view.rows.accessibilityChildren()?.count, 40, "VoiceOver can reach rows outside the current viewport")
    }
}
