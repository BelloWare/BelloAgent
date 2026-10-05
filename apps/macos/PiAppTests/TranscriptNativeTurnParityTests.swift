import XCTest
import AppKit
import SwiftUI
@testable import PiApp

/// A turn's report reads exactly as the SwiftUI report it replaces: the
/// finished turn's row (`StableTurnSummaryView`), the live dock
/// (`CompactTurnReport` with its working line) and a legacy reply's turn line
/// (`TurnLineView`) are each drawn both ways at widths either side of every
/// width the report's layouts switch at, in both appearances, and must be as
/// tall and draw the same pixels. The working line's moving highlight is
/// masked, as a turning ring is.
///
/// Set `PI_PARITY_OUT` (and `TEST_RUNNER_PI_PARITY_OUT`) to a folder to keep
/// both captures and a difference image for every pair.
final class TranscriptNativeTurnParityTests: XCTestCase {
    /// The report's inner width is the row's less 20 points: its header takes
    /// one line from 420, its readings three columns from 548 (150 + 2 × 185
    /// + 2 × 14) and a pair from 384. Each switch is covered from both sides.
    static let rowWidths: [CGFloat] = [792, 568, 566, 520, 442, 438, 406, 402, 380, 300, 240]

    static func accounting(requests: Int = 2) -> TurnAccounting {
        var a = TurnAccounting(requests: requests)
        a.input = 12_000; a.inputSamples = 2
        a.cached = 6_000; a.cachedSamples = 2
        a.uncached = 6_000; a.uncachedSamples = 2
        a.output = 3_800; a.outputSamples = 2
        a.reasoning = 900; a.reasoningSamples = 2
        a.inputSplit = GatewayTokenSplit(total: 12_000, part: 6_000, samples: 2)
        a.outputSplit = GatewayTokenSplit(total: 3_800, part: 900, samples: 2)
        a.costUSD = 0.0123; a.costSamples = 2
        a.modelNames = ["gpt-5.4-mini", "gpt-5.4"]
        a.modelRoutes = [GatewayModelRoute(requested: "auto-router", responded: "gpt-5.4-mini", latestWall: 1),
                         GatewayModelRoute(requested: "auto-router", responded: "gpt-5.4", latestWall: 2)]
        return a
    }
    static func turn(_ outcome: String? = "completed", notice: String? = nil, accounting: TurnAccounting = accounting(),
                     elapsed: Double? = 19_000, model: Double = 12_400, tools: Double = 6_600) -> TurnSummary {
        var turn = TurnSummary(replies: 2, tools: 3, startedAt: 1_790_000_000_000, endedAt: 1_790_000_019_000, elapsedMs: elapsed,
                               modelMs: model, toolMs: tools, live: false, files: 1, partial: false,
                               accounting: accounting, requests: [], outcome: outcome)
        turn.notice = notice
        return turn
    }
    static func running(phase: String = "tools", accounting: TurnAccounting = accounting(requests: 3)) -> TurnSummary {
        var value = turn(nil, accounting: accounting, elapsed: 9_000, model: 7_500, tools: 1_500)
        value.live = true; value.phase = phase; value.endedAt = nil; value.startedAt = nil
        value.current = ToolView(id: "c", name: "bash", state: "running", input: "", output: "", truncated: false)
        return value
    }

    struct Fixture {
        let name: String
        let turn: TurnSummary
        var rightToLeft = false
    }

    static var settledFixtures: [Fixture] {
        var reported = TurnAccounting(requests: 1)
        reported.input = 48_213; reported.inputSamples = 1; reported.costUSD = 0.5; reported.costSamples = 1
        var long = accounting()
        long.modelNames = ["bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0"]
        long.modelRoutes = [GatewayModelRoute(requested: "bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0-extended-thinking-router",
                                              responded: "bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0", latestWall: 1)]
        var stopped = turn("cancelled", notice: "Run cancelled. Pending messages are paused; inspect tool effects before retrying.",
                           accounting: accounting(requests: 3))
        stopped.accounting.missing = TurnMissingUsage(stopped: 1)
        var wordy = turn("cancelled", notice: "Run cancelled. " + String(repeating: "Pending messages are paused and every tool effect should be checked before anything is retried. ", count: 5),
                         accounting: accounting(requests: 3))
        wordy.accounting.missing = TurnMissingUsage(stopped: 1)
        var failed = turn("failed", notice: "The gateway refused the request: 400 Bad Request — the model is not available in this region.",
                          accounting: accounting(requests: 3))
        failed.accounting.missing = TurnMissingUsage(failed: 1)
        return [
            Fixture(name: "done", turn: turn()),
            Fixture(name: "partial", turn: turn(accounting: accounting(requests: 3))),
            Fixture(name: "failed", turn: failed),
            Fixture(name: "stopped", turn: stopped),
            Fixture(name: "wordy", turn: wordy),
            Fixture(name: "reported", turn: turn(accounting: reported, elapsed: nil, model: 0, tools: 0)),
            Fixture(name: "empty", turn: turn("interrupted", accounting: TurnAccounting(), elapsed: nil, model: 0, tools: 0)),
            Fixture(name: "long-model", turn: turn(accounting: long)),
            Fixture(name: "slow", turn: turn(elapsed: 3_723_400, model: 3_662_345, tools: 37_655)),
            // Its AI and tool time wraps in a column.
            Fixture(name: "slower", turn: turn(elapsed: 73_723_400, model: 36_620_000, tools: 36_000_000)),
        ]
    }

    // MARK: The finished turn's row

    @MainActor func testSummaryRowsMatchTheirSwiftUIRows() throws {
        try compare(Self.settledFixtures, widths: Self.rowWidths, kind: .row)
    }
    @MainActor func testRightToLeftSummaryRowsMatchTheirSwiftUIRows() throws {
        let fixtures = Self.settledFixtures.filter { ["done", "failed", "long-model"].contains($0.name) }
            .map { Fixture(name: $0.name + "-rtl", turn: $0.turn, rightToLeft: true) }
        try compare(fixtures, widths: [792, 520, 380], kind: .row)
    }

    // MARK: The live dock

    static var liveFixtures: [Fixture] {
        var none = running(phase: "preparing", accounting: TurnAccounting())
        none.elapsedMs = nil
        var compacting = running(phase: "compacting")
        compacting.accounting.missing = TurnMissingUsage(running: 1)
        return [
            Fixture(name: "live", turn: running()),
            Fixture(name: "live-empty", turn: none),
            Fixture(name: "live-compacting", turn: compacting),
        ]
    }
    @MainActor func testLiveReportsMatchTheirSwiftUIReports() throws {
        try compare(Self.liveFixtures, widths: Self.rowWidths, kind: .live)
    }
    @MainActor func testRightToLeftLiveReportsMatchTheirSwiftUIReports() throws {
        try compare(Self.liveFixtures.prefix(1).map { Fixture(name: $0.name + "-rtl", turn: $0.turn, rightToLeft: true) }, widths: [792, 380], kind: .live)
    }

    // MARK: A legacy reply's turn line

    @MainActor func testTurnLinesMatchTheirSwiftUILines() throws {
        let fixtures = Self.settledFixtures.filter { ["done", "stopped"].contains($0.name) }
        try compare(fixtures, widths: [792, 520, 380], kind: .line(settled: false))
        try compare(fixtures.prefix(1).map { Fixture(name: $0.name + "-settled", turn: $0.turn) }, widths: [792, 380], kind: .line(settled: true))
    }

    // MARK: Drawing both ways

    enum Kind { case row, live, line(settled: Bool) }

    @MainActor func compare(_ fixtures: [Fixture], widths: [CGFloat], kind: Kind) throws {
        let out = testEnvironment("PI_PARITY_OUT").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        var failures: [String] = []
        for fixture in fixtures {
            for width in widths {
                for dark in [false, true] {
                    let label = "turn-\(fixture.name)-\(Int(width))-\(dark ? "dark" : "light")"
                    let hosted = render(fixture, kind: kind, width: width, dark: dark, native: false)
                    let native = render(fixture, kind: kind, width: width, dark: dark, native: true)
                    if hosted.height != native.height {
                        failures.append("\(label): height \(native.height) native, \(hosted.height) SwiftUI")
                    }
                    let (differing, total, diff) = TranscriptNativeRowParityTests.difference(hosted.image, native.image, masked: native.animated)
                    let share = total == 0 ? 0 : Double(differing) / Double(total)
                    if share > TranscriptNativeRowParityTests.pixelTolerance { failures.append(String(format: "%@: %.2f%% of pixels differ (%d)", label, share * 100, differing)) }
                    if let out {
                        try TranscriptNativeRowParityTests.png(hosted.image)?.write(to: out.appendingPathComponent(label + "-swiftui.png"))
                        try TranscriptNativeRowParityTests.png(native.image)?.write(to: out.appendingPathComponent(label + "-native.png"))
                        if let diff { try TranscriptNativeRowParityTests.png(diff)?.write(to: out.appendingPathComponent(label + "-diff.png")) }
                    }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    struct Rendered { let height: CGFloat; let image: NSBitmapImageRep; var animated: [CGRect] = [] }

    @MainActor func render(_ fixture: Fixture, kind: Kind, width: CGFloat, dark: Bool, native: Bool) -> Rendered {
        let previous = TranscriptRowRenderer.native
        TranscriptRowRenderer.native = native
        defer { TranscriptRowRenderer.native = previous }
        var environment = TranscriptRowEnvironment()
        environment.colorScheme = dark ? .dark : .light
        environment.layoutDirection = fixture.rightToLeft ? .rightToLeft : .leftToRight
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let canvas = TranscriptNativeRowParityTests.ParityCanvas(frame: CGRect(x: 0, y: 0, width: width, height: 100))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.white.cgColor
        window.contentView = canvas
        let view: NSView, measure: () -> CGFloat
        var row: TranscriptRowContainer?
        switch kind {
        case .row:
            var block = TranscriptBlock(id: "summary:t", key: "summary:t", turnID: nil, message: nil, activity: [], tools: [], accounting: TurnAccounting(),
                                        startedAt: nil, endedAt: nil, modelMs: 0, toolMs: 0, live: false, turn: fixture.turn)
            block.presentation = .summary
            let container = TranscriptRowContainer(item: .block(block), fresh: false, actions: TranscriptActions(), environment: environment, disclosure: TranscriptDisclosure())
            row = container
            view = container
            measure = { container.measure(width: width).height }
        case .live, .line:
            if native {
                if case .line(let settled) = kind {
                    let line = TranscriptNativeTurnLine()
                    line.update(turn: fixture.turn, settled: settled, actions: TranscriptActions(), model: nil, environment: environment)
                    view = line
                    measure = { ceil(line.height(width: width) * 2) / 2 }
                } else {
                    let report = TranscriptNativeTurnReport()
                    report.reduceMotion = false
                    report.update(turn: fixture.turn, actions: TranscriptActions(), status: TurnInfoPresentation.workingLabel(fixture.turn, state: "running"),
                                  environment: environment)
                    view = report
                    measure = { ceil(report.height(width: width) * 2) / 2 }
                }
            } else {
                let content: AnyView
                if case .line(let settled) = kind {
                    content = AnyView(TurnLineView(turn: fixture.turn, settled: settled))
                } else {
                    content = AnyView(CompactTurnReport(turn: fixture.turn, status: TurnInfoPresentation.workingLabel(fixture.turn, state: "running")))
                }
                let host = NSHostingView(rootView: content
                    .frame(width: width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.colorScheme, environment.swiftUIColorScheme)
                    .environment(\.layoutDirection, environment.swiftUILayoutDirection)
                    .focusEffectDisabled()
                    .piStableLayout())
                host.safeAreaRegions = []
                host.sizingOptions = [.intrinsicContentSize]
                view = host
                measure = { ceil(host.fittingSize.height * 2) / 2 }
            }
        }
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame = CGRect(x: 0, y: 0, width: width, height: 100)
        canvas.addSubview(view)
        let height = measure()
        window.setContentSize(CGSize(width: width, height: height))
        canvas.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        row?.layoutForViewport()
        if let row { XCTAssertEqual(row.subviews.first is TranscriptNativeTurnSummaryRow, native, "\(fixture.name): drawn by the wrong renderer") }
        canvas.layoutSubtreeIfNeeded()
        canvas.display()
        let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        var animated: [CGRect] = []
        func findAnimated(_ view: NSView) {
            if view is TranscriptShimmerLabel, !view.isHidden {
                let rect = view.convert(view.bounds, to: canvas).insetBy(dx: -2, dy: -2)
                let scale = CGFloat(rep.pixelsWide) / width
                animated.append(CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale))
            }
            for child in view.subviews { findAnimated(child) }
        }
        findAnimated(view)
        view.removeFromSuperview()
        window.contentView = nil
        return Rendered(height: height, image: rep, animated: animated)
    }

    // MARK: Middle truncation

    /// A label cut in its middle keeps what SwiftUI's `Text` keeps: as wide
    /// at every width, and drawn on the same pixels.
    @MainActor func testMiddleCutsMatchSwiftUI() throws {
        let texts = ["auto-router → gpt-5.4 · 2 models", "bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0 · 3 models", "Model pending"]
        let font = NSFont.systemFont(ofSize: 10.5)
        var failures: [String] = []
        for text in texts {
            for w in stride(from: CGFloat(20), through: 300, by: 3.5) {
                SizeProbe.size = .zero
                TranscriptTextCalibrationTests.measureInWindow(SizeProbe { Text(text).font(.system(size: 10.5)).lineLimit(1).truncationMode(.middle) }.frame(width: w))
                let label = TranscriptLabel(); label.text = text; label.font = font; label.truncation = .middle
                let native = label.width(truncatedTo: w)
                if native != SizeProbe.size.width { failures.append("\(text.prefix(12)) at \(w): \(native) native, \(SizeProbe.size.width) SwiftUI") }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
