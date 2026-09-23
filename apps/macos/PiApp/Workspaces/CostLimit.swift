import Foundation

/// A chat's cost limit. The helper stops the chat's run before its next model
/// request once the spend the gateway reported for the chat reaches it; a run
/// with no limit is never stopped for what it costs.
///
/// Saved as a number of dollars, or `"none"` for no limit. A chat record that
/// has none of its own (nil) runs under the Settings default.
enum CostLimit: Hashable, Sendable, Codable {
    case unlimited
    case usd(Double)

    /// What every chat runs under until the owner chooses otherwise.
    static let standard = CostLimit.usd(25)
    /// The amounts offered beside No limit and a custom amount.
    static let presets: [Double] = [5, 10, 25, 50, 100]
    /// A guard on a typed amount, as the helper enforces on the wire.
    static let maximumUSD = 1_000_000.0

    var usd: Double? { if case .usd(let value) = self { return value }; return nil }
    var isValid: Bool { usd.map { $0.isFinite && $0 > 0 && $0 <= Self.maximumUSD } ?? true }
    /// The helper's `costLimit` wire field: `{"usd": 25}`, or `{"usd": null}` for none.
    var wire: WireValue { .object(["usd": usd.map(WireValue.number) ?? .null]) }
    /// "$25.00", "$0.001" or "No limit".
    var label: String { usd.map(Self.dollars) ?? "No limit" }

    /// Dollars as a limit reads: cents, or the digits a sub-cent amount needs
    /// so it never reads as $0.00. The helper's stop notice says them the same way.
    static func dollars(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "$0.00" }
        if value >= 0.01 { return String(format: "$%.2f", value) }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return "$" + text
    }
    /// A typed amount — "5", "$5", "12.50", "0.001" — or nil when it is not a
    /// positive number of dollars within the limit's range.
    static func parse(_ text: String) -> CostLimit? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("$") { trimmed.removeFirst() }
        trimmed = trimmed.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isNumber || $0 == "." }), let value = Double(trimmed) else { return nil }
        let limit = CostLimit.usd(value)
        return limit.isValid ? limit : nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            guard text == "none" else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "A cost limit is a number of dollars or \"none\"") }
            self = .unlimited; return
        }
        self = .usd(try container.decode(Double.self))
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .unlimited: try container.encode("none")
        case .usd(let value): try container.encode(value)
        }
    }
}

/// A chat's spend against its limit, as the usage pill, its popover, Session
/// info and the stop notice read it. The limit is the app's (the chat's own,
/// else the Settings default); the spend is what the chat's helper counted,
/// once it has said: the sum of the costs the gateway reported for its
/// requests, and how many requests reported none.
struct SessionCostReading: Equatable, Sendable {
    /// The limit the chat runs under, whichever it comes from.
    var limit: CostLimit = .standard
    /// The chat's own choice; nil when it follows the default.
    var override: CostLimit? = nil
    /// The Settings default, which an override replaces.
    var defaultLimit: CostLimit = .standard
    var spentUSD: Double? = nil
    var reportedRequests = 0
    var unreportedRequests = 0

    /// From this share of the limit on, the figure reads as a warning.
    static let warningFraction = 0.8

    init(limit: CostLimit = .standard, override: CostLimit? = nil, defaultLimit: CostLimit = .standard,
         spentUSD: Double? = nil, reportedRequests: Int = 0, unreportedRequests: Int = 0) {
        self.limit = limit; self.override = override; self.defaultLimit = defaultLimit
        self.spentUSD = spentUSD; self.reportedRequests = reportedRequests; self.unreportedRequests = unreportedRequests
    }

    /// Spent over the limit, when both are known.
    func fraction(spent: Double?) -> Double? {
        guard let cap = limit.usd, cap > 0, let spent, spent.isFinite, spent >= 0 else { return nil }
        return spent / cap
    }
    var fraction: Double? { fraction(spent: spentUSD) }
    /// At 80% of the limit or more.
    func warning(spent: Double?) -> Bool { (fraction(spent: spent) ?? 0) >= Self.warningFraction }
    var warning: Bool { warning(spent: spentUSD) }
    /// The next model request would not go.
    var reached: Bool { (fraction ?? 0) >= 1 }
    /// "$4.12 of $5.00" under a limit, "$4.12" with none; nil with no spend.
    func figure(spent: Double?) -> String? {
        guard let spent, spent.isFinite, spent >= 0 else { return nil }
        let amount = compactGatewayUSD(spent)
        guard let cap = limit.usd else { return amount }
        return amount + " of " + CostLimit.dollars(cap)
    }
    var figure: String? { figure(spent: spentUSD) }
    /// Requests whose cost the gateway never reported can't be counted.
    var unreportedNote: String? {
        guard unreportedRequests > 0 else { return nil }
        return unreportedRequests == 1 ? "1 request reported no cost" : "\(unreportedRequests) requests reported no cost"
    }
    /// Which limit this is, in words: "Default · $25.00", "This chat · No limit".
    var source: String { (override == nil ? "Default · " : "This chat · ") + limit.label }
}
