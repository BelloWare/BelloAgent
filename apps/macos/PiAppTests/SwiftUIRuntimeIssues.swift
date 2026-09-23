import Foundation
import OSLog

/// What SwiftUI said about this process in its own log: state changed or an
/// observable object published while a view was being updated, or a hosting
/// view laid out while it rendered. Each is a side effect of an update that
/// schedules, or re-enters, another; a run of them is how a window stops
/// returning to its run loop. SwiftUI detects these itself, on every OS; the
/// log is where it says so.
enum SwiftUIRuntimeIssues {
    static let phrases = ["during view update", "from within view updates", "laid out reentrantly"]

    /// Every such message logged since `start`. The log store answers a
    /// moment after the fact, so this waits for its own marker to arrive.
    static func since(_ start: Date) throws -> [String] {
        let marker = "SwiftUIRuntimeIssues marker " + UUID().uuidString
        Logger(subsystem: "com.belloware.PiAppTests", category: "runtime-issues").log("\(marker, privacy: .public)")
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let deadline = Date().addingTimeInterval(5)
        repeat {
            var issues: [String] = [], sawMarker = false
            // The store's position is approximate: an entry from before
            // `start` belongs to whatever ran then, not to this scene.
            for case let entry as OSLogEntryLog in try store.getEntries(at: store.position(date: start)) where entry.date >= start {
                let message = entry.composedMessage
                if message == marker { sawMarker = true; continue }
                if phrases.contains(where: { message.contains($0) }) { issues.append("[\(entry.category)] " + message) }
            }
            if sawMarker { return issues }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return try store.getEntries(at: store.position(date: start)).compactMap { $0 as? OSLogEntryLog }
            .filter { $0.date >= start }.map(\.composedMessage)
            .filter { message in phrases.contains { message.contains($0) } }
    }
}
