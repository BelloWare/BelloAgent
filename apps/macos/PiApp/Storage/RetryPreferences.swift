import Foundation

/// Settings ▸ Connections ▸ Retries: pi's settings.retry, one setting for
/// every connection. A provider request that fails for a reason pi reads as
/// transient (overloaded, rate limited, a dropped stream) is sent again after
/// the first delay, doubled before each further retry. It is not a secret; it
/// lives in the vault with the other app preferences, and every helper gets it
/// with `workspace.open` and from `retry.configure` when it changes.
struct RetryPreferences: Codable, Sendable, Equatable {
    var enabled = true
    var maxRetries = 3
    var baseDelaySeconds = 2

    static let retryRange = 0...10
    static let delayRange = 1...60

    var isValid: Bool { Self.retryRange.contains(maxRetries) && Self.delayRange.contains(baseDelaySeconds) }
    /// The wait before each retry, in seconds: the first delay × 2^(n−1).
    var delays: [Int] {
        guard enabled, maxRetries > 0 else { return [] }
        return (0..<maxRetries).map { baseDelaySeconds << $0 }
    }
    /// One line under the setting, e.g. "Waits 2 s, 4 s, 8 s".
    var summary: String {
        guard enabled else { return "Off: a failed request stops at once." }
        guard maxRetries > 0 else { return "No retries: a failed request stops at once." }
        return "Waits " + delays.map(Self.duration).joined(separator: ", ")
    }
    static func duration(_ seconds: Int) -> String {
        if seconds < 120 { return "\(seconds) s" }
        if seconds < 7_200 { return "\(Int((Double(seconds) / 60).rounded())) min" }
        let hours = Double(seconds) / 3_600
        return (hours * 10).rounded() / 10 == hours.rounded() ? "\(Int(hours.rounded())) h" : String(format: "%.1f h", hours)
    }
    /// What the helper reads (`PiProviderRules.RetrySettings(wire:)`).
    var wire: WireValue {
        .object(["enabled": .bool(enabled), "maxRetries": .number(Double(maxRetries)), "baseDelayMs": .number(Double(baseDelaySeconds) * 1_000)])
    }
}

extension WorkspaceModel {
    /// Hands the saved retry setting to every running helper, so every chat of
    /// every connection uses it on its next request. A helper that starts
    /// later gets it with `workspace.open`. A helper that refuses it keeps the
    /// one it had; it gets the setting again when it next starts.
    func retrySettingsChanged() {
        let retry = configuration.retrySettings
        for (workspaceID, host) in hosts where host.isReady {
            Task { [weak self] in
                do { _ = try await host.request("retry.configure", params: retry.wire.object ?? [:]) }
                catch { if self?.hosts[workspaceID] === host { self?.error = "The retry setting did not reach a project's helper: " + error.localizedDescription } }
            }
        }
    }
}
