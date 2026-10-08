    static func formatDuration(_ ms: Double) -> String {
        guard DurationObservation.valid(ms) != nil else { return "" }
        // A tenth that rounds up to the second is written as the second:
        // 990 ms is "1s", never "1.0s".
        if (ms / 100).rounded() < 10 { return String(format: "%.1fs", ms / 1000) }
        // Retained history can contain finite values outside Int's range.
        guard let seconds = Int(exactly: (ms / 1000).rounded()) else { return "" }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60, rest = seconds % 60
        if minutes < 60 { return rest > 0 ? "\(minutes)m \(rest)s" : "\(minutes)m" }
        let hours = minutes / 60, restMinutes = minutes % 60
        return restMinutes > 0 ? "\(hours)h \(restMinutes)m" : "\(hours)h"
    }
