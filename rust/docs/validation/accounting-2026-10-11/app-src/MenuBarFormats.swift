// Lines 264-276 of Dashboard/MenuBarMetrics.swift, verbatim (the file's other
// types need the dashboard database).
import Foundation
func menuBarTokens(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
    return value.formatted(.number.precision(.fractionLength(0)))
}

/// Sidebar-sized token figure: 812, 1.2K, 12K, 1.2M. Missing usage is n/a.
func compactTokens(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "n/a" }
    if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000).replacingOccurrences(of: ".0M", with: "M") }
    if value >= 10_000 { return String(format: "%.0fK", value / 1000) }
    if value >= 1_000 { return String(format: "%.1fK", value / 1000).replacingOccurrences(of: ".0K", with: "K") }
    return String(format: "%.0f", value)
}
