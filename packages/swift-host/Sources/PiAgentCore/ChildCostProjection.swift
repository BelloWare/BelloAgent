import Foundation

/// Read-only numeric projection for managed-child journals. Children retain
/// contribution mirrors, never admissions or other families' spend. Both the
/// desktop's original-reference reader and helper tests compile this file.
/// This does no recovery, authorization, persistence or budget enforcement.
struct ChildCostProjection: Sendable {
    struct Value: Decodable, Equatable, Sendable {
        var attemptId: String?
        var sourceSessionId: String?
        var budgetOwnerSessionId: String?
        var delegationId: String?
        var usd: Double?
        var reported: Int?
        var unreported: Int?
        var accountingRevision: Int?
        var reset: Bool?
    }
    enum Failure: Error { case invalid }
    private var entries: [String:Value] = [:]
    private(set) var usd = 0.0, reported = 0, unreported = 0, revision = 0
    mutating func consume(kind: String, data: Data, child: String, owner: String, delegation: String) throws {
        guard ["pi-app.cost.v1","pi-app.cost-update.v1"].contains(kind) else { return }
        var value = try JSONDecoder().decode(Value.self,from:data)
        guard value.sourceSessionId.map({ $0 == child }) ?? true,
              value.budgetOwnerSessionId.map({ $0 == owner }) ?? true,
              value.delegationId.map({ $0 == delegation }) ?? true,
              value.usd.map({ $0.isFinite && $0 >= 0 && $0 <= 1_000_000_000_000 }) ?? true,
              (value.reported ?? 0) >= 0, (value.unreported ?? 0) >= 0 else { throw Failure.invalid }
        if value.reset == true { entries = [:]; usd = 0; reported = 0; unreported = 0; revision = 0 }
        if let id = value.attemptId {
            if value.reported != 1 || (value.unreported ?? 0) != 0 || value.usd == nil {
                value.usd = 0; value.reported = 0; value.unreported = 1
            } else { value.unreported = 0 }
            if let previous = entries[id] {
                var old = previous, incoming = value
                old.accountingRevision = nil; incoming.accountingRevision = nil
                if old == incoming {
                    // A scope/usage-only correction still advances the
                    // authoritative revision, despite identical money.
                    if kind == "pi-app.cost-update.v1" {
                        revision = max(revision,value.accountingRevision ?? 0)
                        if (value.accountingRevision ?? 0) > (previous.accountingRevision ?? 0) { entries[id] = value }
                    }
                    return
                }
                if (value.accountingRevision ?? 0) < (previous.accountingRevision ?? 0) { return }
                guard kind == "pi-app.cost-update.v1", (value.accountingRevision ?? 0) > (previous.accountingRevision ?? 0) else { throw Failure.invalid }
                usd = max(0,usd - (previous.usd ?? 0)); reported -= previous.reported ?? 0; unreported -= previous.unreported ?? 0
            }
            entries[id] = value
        }
        usd += value.usd ?? 0; reported += min(value.reported ?? 0,1_000_000_000); unreported += min(value.unreported ?? 0,1_000_000_000)
        revision = max(revision,value.accountingRevision ?? 0)
    }
}
