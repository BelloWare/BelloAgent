import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import PiApp

/// Compare the actual Overview document after visiting every original lazy
/// chart and ledger row. Keep the initial/returned-top estimates as separate
/// diagnostics; an estimate is not a complete-content height oracle.
@MainActor final class InspectorOverviewDocumentGeometryTests: XCTestCase, SerialTestLane {
    override func setUp() async throws { PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws { PiKit.Motion.reducedOverride = nil }

    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }
    private struct Snapshot: Equatable {
        let width: CGFloat, clipWidth: CGFloat, clipHeight: CGFloat
        let documentHeight: CGFloat, origin: CGFloat, knob: CGFloat
        @MainActor init(_ scroll: NSScrollView) {
            width = scroll.bounds.width; clipWidth = scroll.contentView.bounds.width
            clipHeight = scroll.contentView.bounds.height; documentHeight = scroll.documentView?.frame.height ?? 0
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
                        geometry: InspectorOverviewReferenceGeometry? = nil, requiresOverflow: Bool = true,
                        ready: () -> Bool = { true }) async throws -> Snapshot {
        var previous: Snapshot?, previousFrames: [String: CGRect] = [:], stable = 0
        try await eventually("Overview geometry settles at \(phase)", timeout: .seconds(5), poll: .milliseconds(50)) {
            root.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
            let current = Snapshot(scroll), frames = geometry?.frames ?? [:]
            stable = previous == current && previousFrames == frames ? stable + 1 : 0
            previous = current; previousFrames = frames
            return ready() && (!requiresOverflow || current.documentHeight > current.clipHeight) && stable >= 3
        }
        return try XCTUnwrap(previous)
    }
    private func scroll(_ view: NSScrollView, toBottom: Bool) {
        guard let document = view.documentView else { return }
        let travel = max(0, document.frame.height - view.contentView.bounds.height)
        let y = document.isFlipped == toBottom ? travel : 0
        view.contentView.scroll(to: NSPoint(x: 0, y: y)); view.reflectScrolledClipView(view.contentView)
    }
    private func record(_ phase: String, kind: String, snapshot: Snapshot, frames: [String: CGRect]) throws {
        let values = Dictionary(uniqueKeysWithValues: frames.map { id, frame in
            (id, [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)])
        })
        let data = try JSONSerialization.data(withJSONObject: ["phase": phase, "kind": kind, "scroll": snapshot.record, "frames": values], options: [.sortedKeys])
        print("OVERVIEW-DOCUMENT " + String(decoding: data, as: UTF8.self))
        if let path = testEnvironment("PI_COMPONENT_GALLERY"), !path.isEmpty {
            let folder = URL(fileURLWithPath: path).appendingPathComponent("inspector-overview-document-geometry")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent(kind + "-" + phase + ".json"))
        }
    }
    private func nativeFrames(_ scroll: PageScrollView, inspector: SessionInspectorModel) throws -> [String: CGRect] {
        let document = try XCTUnwrap(scroll.documentView), column = try XCTUnwrap(scroll.column as? ShellStack)
        let items = column.items.compactMap(\.view)
        let snapshot = try XCTUnwrap(inspector.usage.snapshot)
        let hero = inspector.tokenCharts.hero + inspector.timeCharts.hero.filter { $0.id == "speed" } + inspector.timeCharts.details.filter { $0.id == "ttft" }
        let details = inspector.timeCharts.hero.filter { $0.id != "speed" } + inspector.timeCharts.details.filter { $0.id != "ttft" }
        var frames = ["document": document.bounds]
        func put(_ id: String, _ view: NSView) { frames[id] = view.convert(view.bounds, to: document) }
        put("header", try XCTUnwrap(items.first))
        let figures = try XCTUnwrap(items.first { $0.accessibilityIdentifier() == "inspector-overview-figures" } as? PiKit.Box)
        put("figures", figures)
        let figureColumn = try XCTUnwrap(figures.content as? ShellStack)
        let grids = figureColumn.items.compactMap { $0.view as? GridView }
        XCTAssertEqual(grids.count, 2)
        let heroGrid = try XCTUnwrap(grids.first), detailsGrid = try XCTUnwrap(grids.last)
        XCTAssertEqual(heroGrid.items.count, hero.count); XCTAssertEqual(detailsGrid.items.count, details.count)
        for (figure, view) in zip(hero, heroGrid.items) { put("hero-" + figure.id, view) }
        for (figure, view) in zip(details, detailsGrid.items) { put("detail-" + figure.id, view) }
        put("cost-limit", try XCTUnwrap(items.first { $0.accessibilityIdentifier() == "inspector-cost-limit" }))
        let timeline = try XCTUnwrap(views(SessionTimelineChart.self, in: column).first)
        var timelineCard = timeline.superview
        while timelineCard != nil && !(timelineCard is PiKit.Box) { timelineCard = timelineCard?.superview }
        put("timeline", try XCTUnwrap(timelineCard as? PiKit.Box))
        let chartGrids = items.compactMap { $0 as? GridView }
        XCTAssertEqual(chartGrids.count, 2, "Both the chart grid and two-model grid must be present")
        let chartGrid = try XCTUnwrap(chartGrids.first), modelGrid = try XCTUnwrap(chartGrids.last)
        let chartNames = ["chart-speed", "chart-tokens", "chart-cost", "chart-time-split", "chart-composition"]
        XCTAssertEqual(chartGrid.items.count, chartNames.count, "All five original chart cards are measured")
        put("chart-grid", chartGrid)
        for (id, view) in zip(chartNames, chartGrid.items) { put(id, view) }
        XCTAssertEqual(modelGrid.items.count, 2)
        put("model-grid", modelGrid)
        for (id, view) in zip(["model-time", "model-tokens"], modelGrid.items) { put(id, view) }
        let models = try XCTUnwrap(items.first { $0.accessibilityIdentifier() == "inspector-models" } as? PiKit.Box)
        put("models", models)
        let modelColumn = try XCTUnwrap(models.content as? ShellStack)
        let modelRows = modelColumn.items.compactMap(\.view).filter { String(describing: type(of: $0)) == "InspectorModelRow" }
        XCTAssertEqual(modelRows.count, snapshot.models.count)
        for (item, view) in zip(snapshot.models, modelRows) { put(InspectorOverviewReferenceGeometry.modelID(item), view) }
        let ledger = try XCTUnwrap(items.compactMap { $0 as? SessionRequestLedgerView }.first)
        put("ledger", ledger)
        let rows = ledger.rows
        let accessible = try XCTUnwrap(rows.accessibilityChildren()).compactMap { $0 as? NSAccessibilityElement }
        XCTAssertEqual(accessible.count, rows.rows.count)
        for (row, element) in zip(rows.rows, accessible) {
            // The native press target also includes the preceding separator
            // and gap. Compare the original Button's line rectangle itself.
            var line = element.accessibilityFrameInParentSpace()
            line.origin.y += 1 + PiSpacing.sm; line.size.height -= 1 + PiSpacing.sm
            frames["ledger-row-" + row.id] = rows.convert(line, to: document)
        }
        let methodology = try XCTUnwrap(items.last)
        put("how-counted", try XCTUnwrap(views(PiKit.ButtonBase.self, in: methodology).first { $0.accessibilityIdentifier() == "inspector-how-counted" }))
        return frames
    }

    func testEveryOriginalLazyCardAndLedgerRowMatchesTheCompleteNativeOverview() async throws {
        SessionInspectorWindows.shared.closeAll()
        let pane = try await SessionStatsPopoverTests.seededPane(requests: 18)
        defer { SessionInspectorWindows.shared.closeAll(); pane.close() }
        pane.model.openInspector(session: pane.chat.id)
        let controller = try XCTUnwrap(SessionInspectorWindows.shared.controller(sessionID: pane.chat.id))
        let inspector = controller.inspector, nativeWindow = try XCTUnwrap(controller.window)
        // The same 1200 × 860 Inspector allocation as the full gallery.
        nativeWindow.setContentSize(NSSize(width: 1_200, height: 860))
        nativeWindow.appearance = NSAppearance(named: .aqua)
        let nativeRoot = try XCTUnwrap(nativeWindow.contentView)
        try await eventually("The deterministic Overview has every request and two model routes") {
            nativeRoot.layoutSubtreeIfNeeded(); nativeWindow.displayIfNeeded()
            return inspector.indexLoaded && inspector.index.requests.count == 18 && inspector.timeCharts.historyLoaded
                && inspector.usage.snapshot?.models.count == 2 && inspector.tokenCharts.models.count == 2
        }
        let native = try XCTUnwrap(views(InspectorOverviewPage.self, in: nativeRoot).first)
        let nativeScroll = try XCTUnwrap(views(PageScrollView.self, in: native).first)
        nativeScroll.scrollerStyle = .legacy
        let nativeInitial = try await settle(nativeRoot, window: nativeWindow, scroll: nativeScroll, phase: "native-initial")
        let actual = try nativeFrames(nativeScroll, inspector: inspector)
        try record("initial", kind: "native", snapshot: nativeInitial, frames: actual)
        scroll(nativeScroll, toBottom: true)
        let nativeBottom = try await settle(nativeRoot, window: nativeWindow, scroll: nativeScroll, phase: "native-bottom")
        XCTAssertGreaterThan(nativeBottom.origin, 0)
        try record("bottom", kind: "native", snapshot: nativeBottom, frames: try nativeFrames(nativeScroll, inspector: inspector))
        scroll(nativeScroll, toBottom: false)
        let nativeTop = try await settle(nativeRoot, window: nativeWindow, scroll: nativeScroll, phase: "native-returned-top")
        XCTAssertEqual(nativeTop.origin, 0, accuracy: 0.25)
        XCTAssertEqual(nativeTop.documentHeight, nativeInitial.documentHeight, accuracy: 0.25)
        try record("returned-top", kind: "native", snapshot: nativeTop, frames: try nativeFrames(nativeScroll, inspector: inspector))

        let size = nativeScroll.bounds.size
        let geometry = InspectorOverviewReferenceGeometry()
        let reference = NSHostingView(rootView: InspectorOverviewGeometryReference(inspector: inspector, compact: false, geometry: geometry)
            .frame(width: size.width, height: size.height).environment(\.piReduceMotion, true))
        let referenceWindow = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        referenceWindow.isReleasedWhenClosed = false; referenceWindow.appearance = NSAppearance(named: .aqua)
        referenceWindow.contentView = reference; referenceWindow.orderFront(nil)
        defer { referenceWindow.orderOut(nil); referenceWindow.contentView = nil; referenceWindow.close() }
        try await eventually("The frozen Overview scroll view is mounted") { reference.layoutSubtreeIfNeeded(); return !views(NSScrollView.self, in: reference).isEmpty }
        let referenceScroll = try XCTUnwrap(views(NSScrollView.self, in: reference).max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        referenceScroll.scrollerStyle = .legacy
        let originalInitial = try await settle(reference, window: referenceWindow, scroll: referenceScroll, phase: "frozen-lazy-initial", geometry: geometry) {
            geometry.frames["figures"] != nil
        }
        try record("initial", kind: "frozen-lazy", snapshot: originalInitial, frames: geometry.frames)
        let targets = ["header", "figures", "cost-limit", "timeline", "chart-speed", "chart-tokens", "chart-cost", "chart-time-split", "chart-composition", "model-time", "model-tokens", "models"]
            + inspector.ledger.rows.suffix(40).map { "ledger-row-" + $0.id } + ["how-counted"]
        for id in targets {
            geometry.target = id
            _ = try await settle(reference, window: referenceWindow, scroll: referenceScroll, phase: "realize-" + id, geometry: geometry) {
                geometry.frames[id] != nil
            }
        }
        scroll(referenceScroll, toBottom: true)
        let originalBottom = try await settle(reference, window: referenceWindow, scroll: referenceScroll, phase: "frozen-lazy-bottom", geometry: geometry)
        let bottomFrames = geometry.frames
        XCTAssertGreaterThan(originalBottom.origin, 0)
        try record("bottom", kind: "frozen-lazy", snapshot: originalBottom, frames: bottomFrames)
        scroll(referenceScroll, toBottom: false)
        let originalTop = try await settle(reference, window: referenceWindow, scroll: referenceScroll, phase: "frozen-lazy-returned-top", geometry: geometry)
        XCTAssertEqual(originalTop.origin, 0, accuracy: 0.25)
        try record("returned-top", kind: "frozen-lazy", snapshot: originalTop, frames: geometry.frames)

        // Keep the original chart/figure grids and offer a viewport tall
        // enough that every item is visible. Resolve the original ledger's
        // same children eagerly: even an all-visible LazyVStack can retain
        // an estimated container height and center its realized rows outside
        // that estimate. Normal lazy initial/bottom/top values stay above.
        let completeSize = CGSize(width: size.width, height: max(6_000, nativeInitial.documentHeight + 400))
        let completeGeometry = InspectorOverviewReferenceGeometry()
        let complete = NSHostingView(rootView: InspectorOverviewGeometryReference(inspector: inspector, compact: false, geometry: completeGeometry, resolvedLedger: true)
            .frame(width: completeSize.width, height: completeSize.height).environment(\.piReduceMotion, true))
        let completeWindow = NSWindow(contentRect: NSRect(origin: .zero, size: completeSize), styleMask: [.borderless], backing: .buffered, defer: false)
        completeWindow.isReleasedWhenClosed = false; completeWindow.appearance = NSAppearance(named: .aqua)
        completeWindow.contentView = complete; completeWindow.orderFront(nil)
        defer { completeWindow.orderOut(nil); completeWindow.contentView = nil; completeWindow.close() }
        try await eventually("The fully visible original Overview scroll view is mounted") { complete.layoutSubtreeIfNeeded(); return !views(NSScrollView.self, in: complete).isEmpty }
        let completeScroll = try XCTUnwrap(views(NSScrollView.self, in: complete).max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        completeScroll.scrollerStyle = .legacy; completeScroll.autohidesScrollers = false
        let originalComplete = try await settle(complete, window: completeWindow, scroll: completeScroll, phase: "frozen-lazy-all-visible",
                                              geometry: completeGeometry, requiresOverflow: false) {
            Set(completeGeometry.frames.keys) == Set(actual.keys)
        }
        let expected = completeGeometry.frames
        let content = try XCTUnwrap(expected["document"])
        XCTAssertLessThan(content.height, originalComplete.clipHeight, "Every original lazy child is actually inside the final measurement viewport")
        XCTAssertEqual(originalComplete.origin, 0, accuracy: 0.25)
        try record("all-visible-resolved-ledger", kind: "frozen-original", snapshot: originalComplete, frames: expected)

        // Compare the original children under the same exact width proposal.
        // The full-page SwiftUI proposal is one floating-point ulp larger;
        // Charts and the ledger round that width up to the next backing pixel.
        // Keep the raw full-page frames above and bound only that rounding.
        let scale = completeWindow.backingScaleFactor
        XCTAssertGreaterThan(scale, 0)
        XCTAssertEqual(scale, nativeWindow.backingScaleFactor)
        let rowIDs = Set(inspector.ledger.rows.suffix(40).map { "ledger-row-" + $0.id })
        var exactProposalFrames: [String: CGRect] = [:]
        var widthRoundingBounds: [String: CGFloat] = [:]
        for id in ["chart-speed", "chart-cost", "ledger"] {
            let allocation = try XCTUnwrap(actual[id])
            let originalProposal = id == "ledger" ? content.width - 2 * PiSpacing.xl
                : (try XCTUnwrap(expected["chart-grid"]).width - PiSpacing.md) / 2
            XCTAssertLessThanOrEqual(abs(originalProposal - allocation.width), allocation.width.ulp,
                                     "\(id) proposals differ only by floating-point precision")
            let roundingBound = (originalProposal * scale).rounded(.up) / scale - allocation.width
            XCTAssertGreaterThanOrEqual(roundingBound, 0)
            XCTAssertLessThanOrEqual(roundingBound, 1 / scale, "\(id) rounds by at most one backing pixel")
            let isolatedGeometry = InspectorOverviewReferenceGeometry()
            let isolated = InspectorOverviewGeometryReference(inspector: inspector, compact: false, geometry: isolatedGeometry, resolvedLedger: true)
            let host = NSHostingView(rootView: isolated.isolatedCard(id)
                .frame(width: allocation.width, alignment: .leading)
                .coordinateSpace(name: InspectorOverviewReferenceGeometry.coordinateSpace)
                .frame(width: allocation.width, height: allocation.height + 128, alignment: .topLeading)
                .environment(\.piReduceMotion, true))
            let isolatedWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: allocation.width, height: allocation.height + 128), styleMask: [.borderless], backing: .buffered, defer: false)
            isolatedWindow.isReleasedWhenClosed = false; isolatedWindow.appearance = NSAppearance(named: .aqua)
            isolatedWindow.contentView = host; isolatedWindow.orderFront(nil)
            defer { isolatedWindow.orderOut(nil); isolatedWindow.contentView = nil; isolatedWindow.close() }
            let required = id == "ledger" ? rowIDs.union(["isolated-" + id]) : Set(["isolated-" + id])
            var previous: [String: CGRect] = [:], stable = 0
            try await eventually("The isolated original \(id) has a stable exact proposal", timeout: .seconds(5), poll: .milliseconds(50)) {
                host.layoutSubtreeIfNeeded(); isolatedWindow.displayIfNeeded(); CATransaction.flush()
                let frames = isolatedGeometry.frames
                stable = frames == previous ? stable + 1 : 0; previous = frames
                return required.isSubset(of: Set(frames.keys)) && stable >= 3
            }
            let frame = try XCTUnwrap(previous["isolated-" + id])
            exactProposalFrames[id] = frame; widthRoundingBounds[id] = roundingBound
            if id == "ledger" {
                let rawLedger = try XCTUnwrap(expected[id])
                for rowID in rowIDs {
                    exactProposalFrames[rowID] = try XCTUnwrap(previous[rowID], rowID)
                    widthRoundingBounds[rowID] = roundingBound
                    XCTAssertEqual(try XCTUnwrap(expected[rowID]).width, rawLedger.width - 2 * PiSpacing.md,
                                   accuracy: 0.25, "\(rowID) inherits the raw card's rounded width")
                }
            }
            print("OVERVIEW-ISOLATED id=\(id) proposedWidth=\(allocation.width) originalProposal=\(originalProposal) scale=\(scale) roundingBound=\(roundingBound) frame=\(frame)")
        }
        XCTAssertEqual(Set(exactProposalFrames.keys), rowIDs.union(["chart-speed", "chart-cost", "ledger"]))

        XCTAssertEqual(Set(actual.keys), Set(expected.keys), "Every chart/model card, figure and ledger row must have a real original frame")
        for id in actual.keys.sorted() {
            let actualFrame = try XCTUnwrap(actual[id]), expectedFrame = try XCTUnwrap(expected[id], id)
            XCTAssertEqual(actualFrame.minX, expectedFrame.minX, accuracy: 0.25, "\(id) x")
            XCTAssertEqual(actualFrame.minY, expectedFrame.minY, accuracy: 0.25, "\(id) y")
            if let exact = exactProposalFrames[id] {
                XCTAssertEqual(actualFrame.width, exact.width, accuracy: 0.25, "\(id) width at the same exact proposal")
                XCTAssertEqual(actualFrame.height, exact.height, accuracy: 0.25, "\(id) height at the same exact proposal")
                let roundingBound = try XCTUnwrap(widthRoundingBounds[id])
                XCTAssertGreaterThanOrEqual(expectedFrame.width - actualFrame.width, 0, "\(id) raw width rounds up")
                XCTAssertLessThanOrEqual(expectedFrame.width - actualFrame.width, roundingBound,
                                         "\(id) raw width differs only by the derived backing-pixel rounding")
            } else {
                XCTAssertEqual(actualFrame.width, expectedFrame.width, accuracy: 0.25, "\(id) width")
            }
            XCTAssertEqual(actualFrame.height, expectedFrame.height, accuracy: 0.25, "\(id) height")
        }
        XCTAssertEqual(nativeInitial.clipWidth, originalBottom.clipWidth, accuracy: 0.25)
        XCTAssertEqual(nativeInitial.clipHeight, originalBottom.clipHeight, accuracy: 0.25)
        XCTAssertEqual(nativeInitial.clipWidth, originalComplete.clipWidth, accuracy: 0.25)
        XCTAssertEqual(nativeInitial.documentHeight, content.height, accuracy: 0.25, "The native document retains every original child's actual measured height")
        XCTAssertEqual(nativeInitial.knob, nativeInitial.clipHeight / content.height, accuracy: 0.001, "The native thumb represents the original complete page")
        print("OVERVIEW-LAZY-ESTIMATE initialHeight=\(originalInitial.documentHeight) bottomHeight=\(originalBottom.documentHeight) returnedTopHeight=\(originalTop.documentHeight) allVisibleContentHeight=\(content.height) nativeHeight=\(nativeInitial.documentHeight) initialKnob=\(originalInitial.knob) bottomKnob=\(originalBottom.knob) returnedTopKnob=\(originalTop.knob)")
    }
}
