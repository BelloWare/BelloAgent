import AppKit
import SwiftUI

/// Which form the metrics line takes, in the order `ViewThatFits` tried them:
/// everything, then without the token total, then without the recency stamp,
/// and finally the rate on a line of its own.
enum SidebarMetricsForm: Equatable {
    case full
    case withoutTokens
    case stateCostAndRate
    case stacked

    var showsTokens: Bool { self == .full }
    var showsRecency: Bool { self == .full || self == .withoutTokens }
}

/// What the metrics line is made of and how wide each piece is, so the widest
/// form that fits can be chosen without laying any of them out.
struct SidebarMetricsFigures: Equatable {
    /// `HStack(spacing: 6)`, and the rate button's own fixed width.
    static let spacing: CGFloat = 6
    static let rateWidth: CGFloat = 108
    /// The pieces, in the order they are drawn.
    var state: String?
    var cost: String?
    var rate: Bool
    var tokens: String?
    var recency: String?

    init(_ stats: ChatRowStats) {
        if (stats.busy || stats.loading) && !stats.generating {
            state = PiSessionState.label(stats.state, loading: stats.loading)
        } else if ["error", "interrupted", "paused"].contains(stats.state) {
            state = PiSessionState.label(stats.state)
        }
        cost = stats.costLabel
        rate = stats.timing != nil
        // The token total is dropped while a run is in flight, exactly as the
        // line itself drops it.
        tokens = stats.busy ? nil : stats.tokensLabel.map { "· " + $0 }
        recency = stats.recencyLabel.map { "· " + $0 }
    }

    @MainActor private func width(tokens showTokens: Bool, recency showRecency: Bool) -> CGFloat {
        var total: CGFloat = 0, pieces = 0
        func add(_ value: CGFloat) {
            guard value > 0 else { return }
            total += value + (pieces > 0 ? Self.spacing : 0)
            pieces += 1
        }
        add(state.map { PiTextWidth.figure($0, medium: true) } ?? 0)
        add(cost.map { PiTextWidth.figure($0) } ?? 0)
        add(rate ? Self.rateWidth : 0)
        if showTokens { add(tokens.map { PiTextWidth.figure($0) } ?? 0) }
        if showRecency { add(recency.map { PiTextWidth.figure($0) } ?? 0) }
        return total
    }

    /// The widest form that fits, measured rather than tried. Below the
    /// narrowest single line the rate moves under the state and cost, which is
    /// the only form that can be narrower still.
    @MainActor func form(fitting available: CGFloat) -> SidebarMetricsForm {
        guard available.isFinite else { return .full }
        if width(tokens: true, recency: true) <= available { return .full }
        if width(tokens: false, recency: true) <= available { return .withoutTokens }
        if width(tokens: false, recency: false) <= available { return .stateCostAndRate }
        return .stacked
    }
}

extension ChatRowMetrics {
    /// The width a row's metrics line has to itself, worked out from the width
    /// of the sidebar. Every inset between the two is named here so the
    /// arithmetic lives in one place, and the line truncates rather than
    /// overflows if any of them ever drifts.
    static let listPadding = PiSpacing.sm * 2
    /// `PiSelectableRow` pads its content by ten points on each side.
    static let rowPadding: CGFloat = 20
    /// The status icon and the gap between it and the text column.
    static let iconColumn: CGFloat = 16 + 8
    /// Enough that a rounding difference between measurement and layout cannot
    /// put a glyph past the edge.
    static let safetyMargin: CGFloat = 6

    static func availableWidth(sidebar: CGFloat, indent: CGFloat, depth: Int) -> CGFloat {
        guard sidebar.isFinite else { return .infinity }
        let nesting = indent + CGFloat(min(max(depth, 0), 3) * 14)
        return max(0, sidebar - listPadding - nesting - rowPadding - iconColumn - safetyMargin)
    }
}
