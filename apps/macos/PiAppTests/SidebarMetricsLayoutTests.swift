import XCTest
import AppKit
import SwiftUI
@testable import PiApp

/// The sidebar's metrics line used to pick its form by laying out four
/// candidates for every row on every pass. It now measures the figures once
/// and picks. These tests keep the old view in the bundle as an oracle and
/// insist the two agree: for every width the resize handle allows, and for
/// every shape a row's figures take.
final class SidebarMetricsLayoutTests: XCTestCase {
    // MARK: Figure sets

    @MainActor private static func stats(cost: Double?, tokens: Double?, activity: TimeInterval?,
                                         rate: Bool, state: String = "idle", busy: Bool = false) -> ChatRowStats {
        var totals = GatewayTotals(requests: 6, costSamples: 6, costUSD: cost)
        totals.tokens = GatewayTokenTotals(total: tokens, samples: 6)
        totals.lastActivity = activity.map { Date().timeIntervalSince1970 - $0 }
        let history = rate ? SessionTimingHistory(samples: [
            SessionTimingSample(id: "r1", wall: Date(), ttftMilliseconds: 320, streamingMilliseconds: 1_400,
                                outputTokens: 512, costUSD: 0.12, requestMilliseconds: 1_720)
        ]) : nil
        var value = ChatRowStats(totals: totals, timing: history)
        value.state = state
        value.busy = busy
        return value
    }

    /// Short and long costs, thousands and millions of tokens, "just now"
    /// through "yesterday", with and without a rate label, and the states that
    /// put a coloured word in front of everything else.
    @MainActor private static func figureSets() -> [(name: String, stats: ChatRowStats)] {
        var sets: [(String, ChatRowStats)] = []
        for (costName, cost) in [("no cost", nil), ("cents", 0.0042), ("dollars", 12.34), ("large", 98_765.43)] as [(String, Double?)] {
            for (tokenName, tokens) in [("no tokens", nil), ("k", 12_300), ("M", 9_876_543)] as [(String, Double?)] {
                for (whenName, when) in [("just now", 5.0), ("minutes", 900.0), ("yesterday", 129_600.0), ("none", nil)] as [(String, TimeInterval?)] {
                    for rate in [false, true] {
                        sets.append(("\(costName)/\(tokenName)/\(whenName)/\(rate ? "rate" : "no rate")",
                                     stats(cost: cost, tokens: tokens, activity: when, rate: rate)))
                    }
                }
            }
        }
        for state in ["error", "interrupted", "paused"] {
            sets.append(("state \(state)", stats(cost: 1.5, tokens: 45_600, activity: 600, rate: true, state: state)))
        }
        sets.append(("running", stats(cost: 1.5, tokens: 45_600, activity: 60, rate: true, state: "running", busy: true)))
        return sets.map { (name: $0.0, stats: $0.1) }
    }

    /// Every width the sidebar can be dragged to, and the ones between.
    private static let widths: [CGFloat] = [200, 240, 260, 300, 340, 420]

    // MARK: The oracle

    /// The metrics line exactly as it was before it measured anything: four
    /// candidates, the first that fits. Kept here so the deterministic choice
    /// has something to be checked against.
    private struct OracleRow: View {
        let stats: ChatRowStats
        let title: String
        let tokens: Bool
        let recency: Bool
        var body: some View {
            HStack(spacing: 6) {
                stateAndCost
                if let history = stats.timing { SidebarReportedRate(history: history, sessionTitle: title) }
                if tokens, !stats.busy, let value = stats.tokensLabel { Text("· " + value) }
                if recency, let value = stats.recencyLabel { Text("· " + value) }
            }
            .font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkTertiary)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }
        @ViewBuilder private var stateAndCost: some View {
            if (stats.busy || stats.loading) && !stats.generating {
                Text(PiSessionState.label(stats.state, loading: stats.loading)).foregroundStyle(Color.piWarning).fontWeight(.medium)
            } else if ["error", "interrupted", "paused"].contains(stats.state) {
                Text(PiSessionState.label(stats.state)).foregroundStyle(stats.state == "paused" ? Color.piInfo : Color.piDanger).fontWeight(.medium)
            }
            if let cost = stats.costLabel { Text(cost) }
        }
    }

    /// What SwiftUI itself says a candidate wants to be. `ViewThatFits` takes
    /// the first candidate whose ideal width fits the proposal, so these
    /// widths are the whole of its decision.
    @MainActor private func idealWidth(_ view: some View) -> CGFloat {
        let hosting = NSHostingView(rootView: view.fixedSize())
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.width
    }

    @MainActor private func oracleForm(_ stats: ChatRowStats, available: CGFloat) -> (form: SidebarMetricsForm, width: CGFloat) {
        let candidates: [(SidebarMetricsForm, Bool, Bool)] = [(.full, true, true), (.withoutTokens, false, true), (.stateCostAndRate, false, false)]
        for (form, tokens, recency) in candidates {
            let width = idealWidth(OracleRow(stats: stats, title: "Chat", tokens: tokens, recency: recency))
            if width <= available { return (form, width) }
        }
        return (.stacked, 0)
    }

    // MARK: Tests

    /// The sidebar used to print the helper's own state names: a chat waiting
    /// its turn said "queued", a chat being opened said "preparing", a chat
    /// mid-compaction said "compacting" in lower case beside its cost. Every
    /// state a row can show is now a word a reader already knows, and none of
    /// the wire names survives into the line.
    @MainActor func testRunStatesReachTheRowAsWordsAReaderKnows() {
        let expected: [(String, Bool, String)] = [
            ("queued", false, "Waiting"), ("running", false, "Working"), ("tool", false, "Using a tool"),
            ("stopping", false, "Stopping"), ("compacting", false, "Compacting"), ("paused", false, "Paused"),
            ("interrupted", false, "Interrupted"), ("error", false, "Failed"), ("running", true, "Opening")
        ]
        for (state, loading, label) in expected {
            XCTAssertEqual(PiSessionState.label(state, loading: loading), label)
        }
        // And what the measured line actually carries, for the states that show one.
        for state in ["queued", "running", "stopping", "compacting", "error", "interrupted", "paused"] {
            var stats = ChatRowStats(totals: nil)
            stats.updateActivity(state: state, loading: false, activity: [:])
            guard let shown = SidebarMetricsFigures(stats).state else { continue }
            XCTAssertFalse(["queued", "running", "stopping", "compacting", "error", "interrupted", "paused", "preparing", "tool"].contains(shown),
                           "The wire word “\(shown)” reached the sidebar")
            XCTAssertEqual(shown.first, shown.first?.uppercased().first, "A state reads as a word, not a token: \(shown)")
        }
    }


    /// The measured choice must be the choice `ViewThatFits` made, at every
    /// width and for every shape the figures take.
    @MainActor func testTheMeasuredFormIsTheOneViewThatFitsWouldHaveChosen() throws {
        var disagreements: [String] = [], checks = 0
        for (name, stats) in Self.figureSets() {
            let figures = SidebarMetricsFigures(stats)
            for sidebar in Self.widths {
                let available = ChatRowMetrics.availableWidth(sidebar: sidebar, indent: 14, depth: 0)
                let oracle = oracleForm(stats, available: available)
                let measured = figures.form(fitting: available)
                checks += 1
                if measured != oracle.form {
                    disagreements.append("\(name) at \(Int(sidebar))pt (available \(Int(available))): measured \(measured), oracle \(oracle.form)")
                }
            }
        }
        print("PERF sidebar metrics oracle: \(checks) comparisons, \(disagreements.count) disagreements")
        XCTAssertTrue(disagreements.isEmpty, "The measured form differs from what ViewThatFits chose:\n" + disagreements.prefix(12).joined(separator: "\n"))
    }

    /// Whatever form is chosen has to fit, so the last-resort truncation never
    /// has anything to do. This is the assertion that a measurement drifting
    /// from layout would break first.
    @MainActor func testTheChosenFormAlwaysFitsSoTheLineNeverTruncates() throws {
        var overflows: [String] = []
        var worstSlack = CGFloat.greatestFiniteMagnitude, tightest = ""
        for (name, stats) in Self.figureSets() {
            let figures = SidebarMetricsFigures(stats)
            for sidebar in Self.widths {
                let available = ChatRowMetrics.availableWidth(sidebar: sidebar, indent: 14, depth: 0)
                let form = figures.form(fitting: available)
                guard form != .stacked else { continue }
                let drawn = idealWidth(OracleRow(stats: stats, title: "Chat", tokens: form.showsTokens, recency: form.showsRecency))
                if available - drawn < worstSlack { worstSlack = available - drawn; tightest = "\(name) at \(Int(sidebar))pt, \(form)" }
                if drawn > available { overflows.append("\(name) at \(Int(sidebar))pt: draws \(drawn), has \(available)") }
            }
        }
        print(String(format: "PERF sidebar metrics tightest fit: %.2f pt of slack (%@), on top of the %.0f pt safety margin",
                     worstSlack, tightest, ChatRowMetrics.safetyMargin))
        XCTAssertTrue(overflows.isEmpty, "A chosen form does not fit, so the row would truncate:\n" + overflows.prefix(12).joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(worstSlack, 0)
    }

    /// The whole point: the strings are measured once, not once per row.
    @MainActor func testTheFiguresAreMeasuredOncePerString() throws {
        PiTextWidth.forget()
        let stats = Self.stats(cost: 12.34, tokens: 45_600, activity: 600, rate: true)
        let figures = SidebarMetricsFigures(stats)
        _ = figures.form(fitting: 240)
        let afterFirst = PiTextWidth.measuredCount
        XCTAssertGreaterThan(afterFirst, 0)
        for _ in 0..<200 { _ = figures.form(fitting: CGFloat.random(in: 80...400)) }
        XCTAssertEqual(PiTextWidth.measuredCount, afterFirst, "Asking again must not measure again")

        // The same figures on a hundred rows are the same strings.
        for _ in 0..<100 { _ = SidebarMetricsFigures(stats).form(fitting: 240) }
        XCTAssertEqual(PiTextWidth.measuredCount, afterFirst)
    }

    /// The chosen form is what the view actually draws: told it has a child
    /// row's width, the real line puts the rate under the state and cost and
    /// grows taller, rather than truncating on one line. `SessionTimingTests`
    /// asserts the same thing for a line that is told nothing and works it out
    /// with `ViewThatFits`; this is the told path.
    @MainActor func testTheToldLineStacksInsteadOfTruncatingWhenTheRoomRunsOut() throws {
        var stats = Self.stats(cost: 12.34, tokens: nil, activity: 600, rate: true)
        stats.requests = 1
        stats.updateActivity(state: "paused", loading: false, activity: [:])
        XCTAssertNotEqual(SidebarMetricsFigures(stats).form(fitting: 226), .stacked,
                          "A root row at the default sidebar width keeps its rate on one line")
        XCTAssertEqual(SidebarMetricsFigures(stats).form(fitting: 112), .stacked,
                       "A first-level child row has no room for the rate beside the cost")

        func height(_ available: CGFloat, width: CGFloat) -> CGFloat {
            let hosting = NSHostingView(rootView: ChatRowMetrics(stats: stats, title: "Fixture", available: available)
                .frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true))
            hosting.layoutSubtreeIfNeeded()
            return hosting.fittingSize.height
        }
        let wide = height(226, width: 226), narrow = height(112, width: 112)
        XCTAssertGreaterThan(narrow, wide + 8, "The narrow row must wrap the rate below state and cost, not truncate it away")
    }

    /// The insets between the sidebar's width and the line's are named in one
    /// place; a child row gets less room than its parent, and the arithmetic
    /// never goes negative.
    @MainActor func testTheAvailableWidthFollowsTheRowsOwnIndent() throws {
        let root = ChatRowMetrics.availableWidth(sidebar: 300, indent: 14, depth: 0)
        let inTopic = ChatRowMetrics.availableWidth(sidebar: 300, indent: 28, depth: 0)
        let child = ChatRowMetrics.availableWidth(sidebar: 300, indent: 14, depth: 1)
        XCTAssertEqual(inTopic, root - 14)
        XCTAssertEqual(child, root - 14)
        XCTAssertEqual(ChatRowMetrics.availableWidth(sidebar: 300, indent: 14, depth: 9),
                       ChatRowMetrics.availableWidth(sidebar: 300, indent: 14, depth: 3), "Indentation stops at three levels")
        XCTAssertEqual(ChatRowMetrics.availableWidth(sidebar: 40, indent: 14, depth: 0), 0)
        XCTAssertEqual(ChatRowMetrics.availableWidth(sidebar: .infinity, indent: 14, depth: 0), .infinity)
        XCTAssertEqual(SidebarMetricsFigures(Self.stats(cost: 1, tokens: 1, activity: 1, rate: true)).form(fitting: .infinity), .full)
    }
}
