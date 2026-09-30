import XCTest
import AppKit
@testable import PiApp

/// A row reaches the pane's actions through two relays, both
/// `TranscriptActions.forwarding`: the document's, which every row of a page
/// is handed, and the row's own, which its SwiftUI tree is built with. An
/// action one of them leaves out compiles, and does nothing in any row.
final class TranscriptActionsForwardingTests: XCTestCase {
    /// Each action a pane makes arrives once, from a row, through both relays.
    @MainActor func testEveryActionReachesThePaneThroughBothRelays() {
        var calls: [String] = []
        let pane = TranscriptActions(
            inspect: { calls.append("inspect \($0)") },
            edit: { calls.append("edit \($0)") },
            copyMessage: { calls.append("copyMessage \($0)") },
            stop: { calls.append("stop") },
            retry: { calls.append("retry") },
            quoteReply: { _ in calls.append("quoteReply") },
            inspectTurn: { _ in calls.append("inspectTurn") },
            skillPressed: { id, use, _ in calls.append("skillPressed \(id) \(use.name)") },
            skillHovered: { id, use, _, inside in calls.append("skillHovered \(id) \(use.name) \(inside)") },
            costLimit: { action, _ in calls.append("costLimit \(action)") },
            fork: { calls.append("fork \($0)") },
            switchVersion: { calls.append("switchVersion \($0) \($1)") },
            latestVersion: { calls.append("latestVersion") },
            openFile: { calls.append("openFile \($0) \($1.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "top")") })
        let relay = TranscriptActionRelay()
        relay.current = pane
        let document = relay.forwarded
        let row = TranscriptActions.forwarding { document }
        let anchor = NSView()
        let skill = TranscriptSkillUse(id: "id-review", name: "review", path: "/p/.agents/skills/review/SKILL.md",
                                       contentHash: "3f2a9c1e77", metadataHash: "", arguments: "")
        row.inspect("m1"); row.edit("m2"); row.copyMessage("m3"); row.stop(); row.retry()
        row.inspectTurn?(TaskTranscriptPlan.summary([], task: nil))
        row.skillPressed?("m4", skill, anchor); row.skillHovered?("m5", skill, anchor, true)
        row.costLimit?(.raise, anchor); row.fork?("m6"); row.switchVersion?("m7", -1); row.latestVersion?()
        row.openFile?("/p/a.swift", 3...5); row.openFile?("/p/b.swift", nil)
        XCTAssertEqual(calls, ["inspect m1", "edit m2", "copyMessage m3", "stop", "retry", "inspectTurn",
                               "skillPressed m4 review", "skillHovered m5 review true", "costLimit raise",
                               "fork m6", "switchVersion m7 -1", "latestVersion", "openFile /p/a.swift 3-5", "openFile /p/b.swift top"])
        XCTAssertNil(row.quoteReply, "Rows never ask for a quote; the page's selection controller does")

        // The rows keep the closures they were handed; the pane's newer
        // actions are what those closures reach.
        calls = []
        relay.current = TranscriptActions(inspect: { calls.append("newer inspect \($0)") })
        row.inspect("m8")
        XCTAssertEqual(calls, ["newer inspect m8"])
    }

    /// An optional action the pane does not offer is still there for a row
    /// to call, and does nothing.
    @MainActor func testAnActionThePaneDoesNotOfferDoesNothing() {
        let relay = TranscriptActionRelay()
        let row = TranscriptActions.forwarding { relay.forwarded }
        XCTAssertNotNil(row.fork, "Rows decide what they offer from the environment, not from a nil action")
        row.fork?("m1"); row.switchVersion?("m1", 1); row.latestVersion?(); row.costLimit?(.continueRun, nil)
        row.openFile?("/p/a.swift", nil)
    }

    /// Fails when `TranscriptActions` gains or loses an action, so the
    /// relays cannot fall behind it.
    @MainActor func testTheRelaysForwardEveryAction() {
        XCTAssertEqual(Mirror(reflecting: TranscriptActions()).children.count, 14,
                       "TranscriptActions changed. Forward the action in `TranscriptActions.forwarding`, list it in `offered` if it is optional, and call it in testEveryActionReachesThePaneThroughBothRelays.")
    }
}
