import Combine
import XCTest
@testable import PiApp

/// Billing changes are frequent and independent across running chats. The
/// retained sidebar cache must update the owning row, not the whole workspace.
final class SessionAccountingCacheTests: XCTestCase {
    @MainActor private func fixture() -> WorkspaceModel {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("session-accounting-cache-" + UUID().uuidString)
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        registerWorkspaceFixtureTeardown(model, root: root)
        return model
    }

    @MainActor func testRowsKeepIdentityAndNotifyOnlyTheirOwnObservers() {
        let cache = SessionAccountingCache()
        let rows = (0..<5).map { cache.row(for: "session-\($0)") }
        var notifications = Array(repeating: 0, count: rows.count)
        let observations = rows.enumerated().map { index, row in row.objectWillChange.sink { notifications[index] += 1 } }
        defer { observations.forEach { $0.cancel() } }
        for index in rows.indices {
            XCTAssertTrue(cache.row(for: "session-\(index)") === rows[index])
            XCTAssertNil(rows[index].totals)
        }
        let first = GatewayTotals(requests: 2, costSamples: 2, costUSD: 0.003)
        cache.publish(first, sessionID: "session-3")
        XCTAssertEqual(notifications, [0, 0, 0, 1, 0])
        XCTAssertEqual(rows[3].totals, first); XCTAssertEqual(cache.values["session-3"], first)
        for index in rows.indices where index != 3 { XCTAssertNil(rows[index].totals) }
        let second = GatewayTotals(requests: 1, costSamples: 1, costUSD: 0.002)
        cache.publish(second, sessionID: "session-1")
        XCTAssertEqual(notifications, [0, 1, 0, 1, 0])
        XCTAssertEqual(rows[1].totals, second); XCTAssertEqual(rows[3].totals, first)
    }

    @MainActor func testUnchangedBillingDoesNotNotifyAndLateRowReceivesCurrentTotals() {
        let cache = SessionAccountingCache()
        var totals = GatewayTotals(requests: 1, costSamples: 1, costUSD: 0.001)
        totals.tokens = GatewayTokenTotals(input: 38, output: 302, total: 340, inputSamples: 1, outputSamples: 1, samples: 1)
        cache.publish(totals, sessionID: "late")
        let row = cache.row(for: "late")
        XCTAssertEqual(row.totals, totals, "A row first mounted after its accounting read must not wait for another request or focus event")
        var notifications = 0
        let observation = row.objectWillChange.sink { notifications += 1 }; defer { observation.cancel() }
        for _ in 0..<100 { cache.publish(totals, sessionID: "late") }
        XCTAssertEqual(notifications, 0)
        XCTAssertTrue(cache.row(for: "late") === row)
    }

    @MainActor func testEmptyRetainedTotalsClearStaleCostAndUsageWithoutChangingOtherRows() {
        let cache = SessionAccountingCache(), empty = GatewayTotals()
        var totals = GatewayTotals(requests: 5, costSamples: 4, costUSD: 0.1, cacheHits: 2)
        totals.tokens = GatewayTokenTotals(input: 1_000, output: 500, total: 1_500, inputSamples: 5, outputSamples: 5, samples: 5)
        cache.publish(totals, sessionID: "expired"); cache.publish(totals, sessionID: "kept")
        let row = cache.row(for: "expired"), kept = cache.row(for: "kept")
        var changes = 0, unrelated = 0
        let a = row.objectWillChange.sink { changes += 1 }, b = kept.objectWillChange.sink { unrelated += 1 }
        defer { a.cancel(); b.cancel() }
        cache.publish(empty, sessionID: "expired")
        XCTAssertEqual(row.totals, empty); XCTAssertEqual(cache.values["expired"], empty)
        XCTAssertNil(row.totals?.costUSD); XCTAssertNil(row.totals?.tokens)
        XCTAssertEqual(row.totals?.requests, 0)
        XCTAssertEqual(kept.totals, totals); XCTAssertEqual(changes, 1); XCTAssertEqual(unrelated, 0)
    }

    @MainActor func testWorkspaceBillingPublicationUpdatesRowsWithoutGlobalInvalidation() throws {
        let model = fixture()
        let rows = (0..<5).map { model.chatAccounting.row(for: "session-\($0)") }
        var workspaceChanges = 0, rowChanges = Array(repeating: 0, count: 5)
        let shell = model.objectWillChange.sink { workspaceChanges += 1 }
        let observations = rows.enumerated().map { index, row in row.objectWillChange.sink { rowChanges[index] += 1 } }
        defer { shell.cancel(); observations.forEach { $0.cancel() } }
        for sample in 1...10 {
            for index in rows.indices {
                let totals = GatewayTotals(requests: sample, costSamples: sample, costUSD: Double(sample * (index + 1)) / 1_000)
                model.publishChatStats(totals, sessionID: "session-\(index)")
            }
        }
        XCTAssertEqual(workspaceChanges, 0, "Fifty per-chat billing updates must not rebuild the selected conversation and every project/topic")
        XCTAssertEqual(rowChanges, [10, 10, 10, 10, 10])
        for index in rows.indices {
            XCTAssertEqual(rows[index].totals, model.chatStats["session-\(index)"])
            XCTAssertEqual(rows[index].totals?.costUSD, Double(10 * (index + 1)) / 1_000)
        }
    }

    @MainActor func testDisplayPresenceAndIdentityChangesRefreshTheLiveRowBranchExactlyOnce() {
        let model = fixture(), first = SessionDisplay(id: "chat"), replacement = SessionDisplay(id: "chat")
        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }; defer { observation.cancel() }
        model.displays["chat"] = first
        XCTAssertEqual(changes, 1, "A retained sidebar row must switch to live state when its display is first created")
        model.displays["chat"] = first
        XCTAssertEqual(changes, 1, "Coalesced refreshes reusing the same display must not invalidate the shell")
        model.displays["chat"] = replacement
        XCTAssertEqual(changes, 2, "Replacing a display requires the row to subscribe to the new object")
        model.displays.removeValue(forKey: "chat")
        XCTAssertEqual(changes, 3, "Evicting an idle page must switch the row back to retained accounting")
        model.displays.removeValue(forKey: "missing")
        model.displays = [:]
        XCTAssertEqual(changes, 3, "No-op removals and equivalent maps must not publish")
    }
}
