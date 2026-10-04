import Foundation

/// One row of a stat dialog: a name, its figure, and — when the gateway did
/// not report every request — the coverage that makes the figure honest.
struct PiStatRow: Identifiable, Equatable, Sendable {
    var name: String
    var value: String
    /// A quieter figure under the value, such as "12,400 reasoning".
    var detail: String? = nil
    /// "3/5 requests reported"; shown in warning ink so partial coverage reads
    /// as partial rather than as a total.
    var coverage: String? = nil
    var id: String { name }

    /// One line of the same row, for a copy action or an accessibility value.
    var line: String {
        ([name + ": " + value, detail, coverage].compactMap { $0 }).joined(separator: " · ")
    }
}
