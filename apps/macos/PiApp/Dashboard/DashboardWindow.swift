import Foundation

/// Dashboard time-range presets. Fixed presets are relative to "now"; the
/// custom preset uses the explicit bounds stored in `DashboardPreferences`.
enum DashboardWindowPreset: String, CaseIterable, Sendable {
    case oneHour = "1h"
    case sixHours = "6h"
    case day = "24h"
    case week = "7d"
    case month = "30d"
    case custom

    static let maximumSpan: TimeInterval = 3650 * 86400
    static let minimumSpan: TimeInterval = 60

    var title: String {
        switch self {
        case .oneHour: "1h"
        case .sixHours: "6h"
        case .day: "24h"
        case .week: "7d"
        case .month: "30d"
        case .custom: "Custom"
        }
    }
    /// Relative window length; nil for the custom preset.
    var hours: Int? {
        switch self {
        case .oneHour: 1
        case .sixHours: 6
        case .day: 24
        case .week: 168
        case .month: 720
        case .custom: nil
        }
    }
    /// Exact preset for a relative hour count; nil when no preset matches.
    static func matching(hours: Int) -> DashboardWindowPreset? { allCases.first { $0.hours == hours } }

    static func customBoundsValid(from: Date?, until: Date?, required: Bool) -> Bool {
        switch (from, until) {
        case (nil, nil): return !required
        case (let from?, let until?):
            return from.timeIntervalSince1970.isFinite && until.timeIntervalSince1970.isFinite && until.timeIntervalSince(from) >= minimumSpan && until.timeIntervalSince(from) <= maximumSpan
        default: return false
        }
    }
}

struct DashboardWindow: Equatable, Sendable {
    var from: Date
    var until: Date
    var preset: DashboardWindowPreset
    var span: TimeInterval { until.timeIntervalSince(from) }

    /// Resolves the saved preferences to concrete bounds. Older records with
    /// no preset keep their relative `windowHours` window; a custom preset
    /// without valid bounds falls back to the relative window too, so a
    /// damaged record still produces a usable range instead of failing.
    static func resolve(_ preferences: DashboardPreferences, now: Date = Date()) -> DashboardWindow {
        let preset = preferences.windowPreset.flatMap(DashboardWindowPreset.init(rawValue:)) ?? DashboardWindowPreset.matching(hours: preferences.windowHours) ?? .custom
        if preset == .custom, let from = preferences.customFrom, let until = preferences.customUntil,
           DashboardWindowPreset.customBoundsValid(from: from, until: until, required: true) {
            return DashboardWindow(from: from, until: until, preset: .custom)
        }
        let hours = preset.hours ?? preferences.windowHours
        return DashboardWindow(from: now.addingTimeInterval(-Double(max(1, hours)) * 3600), until: now, preset: preset == .custom ? .custom : preset)
    }

    /// Writes a chosen preset back into the preferences. Fixed presets keep
    /// `windowHours` in sync so settings and older readers agree; switching to
    /// custom seeds explicit bounds from the currently resolved window.
    static func apply(_ preset: DashboardWindowPreset, to preferences: inout DashboardPreferences, now: Date = Date()) {
        let current = resolve(preferences, now: now)
        preferences.windowPreset = preset.rawValue
        if let hours = preset.hours { preferences.windowHours = hours; preferences.customFrom = nil; preferences.customUntil = nil }
        else if preferences.customFrom == nil || preferences.customUntil == nil { preferences.customFrom = current.from; preferences.customUntil = current.until }
    }

    /// Clamps custom bounds so the pickers can never produce an empty or
    /// oversized window, moving the other bound when necessary.
    static func normalizeCustom(from: Date, until: Date, anchorFrom: Bool) -> (from: Date, until: Date) {
        var from = from, until = until
        if anchorFrom {
            if until.timeIntervalSince(from) < DashboardWindowPreset.minimumSpan { until = from.addingTimeInterval(DashboardWindowPreset.minimumSpan) }
            if until.timeIntervalSince(from) > DashboardWindowPreset.maximumSpan { until = from.addingTimeInterval(DashboardWindowPreset.maximumSpan) }
        } else {
            if until.timeIntervalSince(from) < DashboardWindowPreset.minimumSpan { from = until.addingTimeInterval(-DashboardWindowPreset.minimumSpan) }
            if until.timeIntervalSince(from) > DashboardWindowPreset.maximumSpan { from = until.addingTimeInterval(-DashboardWindowPreset.maximumSpan) }
        }
        return (from, until)
    }
}

/// A sub-range brushed on a chart. It narrows the request table and tiles
/// without touching the saved filter; the charts keep showing the full window.
struct DashboardBrush: Equatable, Sendable {
    var from: Date
    var until: Date

    /// Orders and clamps two dragged dates into the applied window; nil when
    /// the result would be empty or shorter than one second.
    init?(_ a: Date, _ b: Date, in filter: DashboardFilter) {
        let low = max(filter.from, min(a, b)), high = min(filter.until, max(a, b))
        guard high.timeIntervalSince(low) >= 1 else { return nil }
        from = low; until = high
    }

    /// True when the brush still lies inside a (possibly changed) window.
    func fits(_ filter: DashboardFilter) -> Bool { from >= filter.from && until <= filter.until }

    func narrowed(_ filter: DashboardFilter) -> DashboardFilter {
        var result = filter
        result.from = from; result.until = until
        return result
    }

    var label: String {
        let sameDay = Calendar.current.isDate(from, inSameDayAs: until)
        let short = Date.FormatStyle().hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits)
        let long = Date.FormatStyle().month(.abbreviated).day().hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits)
        return sameDay ? from.formatted(short) + "–" + until.formatted(short) : from.formatted(long) + " – " + until.formatted(long)
    }
}
