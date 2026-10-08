enum DurationObservation {
    static func valid(_ milliseconds: Double?) -> Double? {
        guard let milliseconds, milliseconds.isFinite, milliseconds >= 0,
              milliseconds < Double(Int.max) else { return nil }
        return milliseconds
    }
}
