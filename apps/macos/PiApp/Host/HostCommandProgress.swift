import Foundation

/// One command's known journal work. Epoch/command identity and monotonicity
/// are checked by the supervisor before a deadline or a view sees this value.
struct HostCommandProgress: Equatable, Sendable {
    let completed: Int, total: Int
    var fraction: Double { Double(completed) / Double(total) }
    init?(_ frame: [String: WireValue]) {
        guard let completed = frame["completed"]?.nonnegativeInteger,
              let total = frame["total"]?.nonnegativeInteger, total > 0, completed <= total,
              total <= 9_007_199_254_740_991 else { return nil }
        self.completed = completed; self.total = total
    }
    init(completed: Int, total: Int) { self.completed = completed; self.total = total }
}
