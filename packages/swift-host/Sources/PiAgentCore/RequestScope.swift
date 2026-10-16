import Foundation

/// Immutable lineage allocated before capture and transport. Physical request
/// identity remains the source chat's, while accounting belongs to the owner.
public struct RequestScope: Codable, Sendable, Equatable {
    public let sourceSessionID: String
    public let budgetOwnerSessionID: String
    public let turnID: String
    public let executionID: String
    public let purpose: String
    public let ownerGeneration: Int
    public let delegation: SubagentLink?
    /// Side ancestry only; delegation identity and provider/cache identities
    /// retain their existing meaning. The last ancestor owns the total budget.
    public var sideParents: [String]? = nil
    public var chargeOwnerSessionID: String { sideParents?.last ?? budgetOwnerSessionID }
    public var childTurn: Int? = nil
    public var parentExecutionID: String? = nil
    public var agentDeliveryIDs: [String]? = nil

    public var valid: Bool {
        let ids = [sourceSessionID, budgetOwnerSessionID, turnID, executionID, purpose]
        guard ownerGeneration >= 0, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.utf8.contains(where: { $0 < 32 || $0 == 127 }) }) else { return false }
        if let sideParents {
            guard !sideParents.isEmpty, sideParents.count <= 128, Set(sideParents).count == sideParents.count,
                  !sideParents.contains(sourceSessionID), !sideParents.contains(budgetOwnerSessionID),
                  sideParents.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.utf8.contains(where: { $0 < 32 || $0 == 127 }) }) else { return false }
        }
        if let childTurn { guard childTurn >= 1, parentExecutionID?.isEmpty == false, delegation != nil else { return false } }
        if let delegation {
            return delegation.valid && sourceSessionID == delegation.childSessionID && budgetOwnerSessionID == delegation.budgetOwnerSessionID
        }
        return sourceSessionID == budgetOwnerSessionID
    }
}
