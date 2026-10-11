// Transcript/TranscriptActivity.swift's pieces these sources call, verbatim:
// lines 5-11, 425-434 and 609-612 (the rest of the file needs the transcript).
import Foundation
enum DurationObservation {
    static func valid(_ milliseconds: Double?) -> Double? {
        guard let milliseconds, milliseconds.isFinite, milliseconds >= 0,
              milliseconds < Double(Int.max) else { return nil }
        return milliseconds
    }
}
enum TranscriptActivity {
    static func grouped(_ value: Double) -> String {
        guard let whole = Int(exactly: value.rounded()) else { return "—" }
        let digits = String(whole.magnitude)
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return (whole < 0 ? "-" : "") + out
    }
    static func reported(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}
