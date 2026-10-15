import AppKit

struct SubagentFamily: Equatable {
    struct Member: Equatable {
        var chat: ChatRecord
        var status: SubagentStatus?
        var model: String
        var spend: Double?
        var active: Bool { status.map { !$0.terminal } ?? false }
        var label: String { chat.subagentShortTitle }
        var statusLabel: String {
            switch status {
            case .queued: "Queued"
            case .running: "Running"
            case .stopping: "Stopping"
            case .completed: "Done"
            case .failed, .outputLimited: "Failed"
            case .cancelled, .interrupted, .notExecuted: "Stopped"
            case nil: "Saved"
            }
        }
    }
    var ownerID: String
    var members: [Member]
    var runningCount: Int
}

extension WorkspaceModel {
    /// Built only after metadata/lifecycle mutations; never scans transcripts,
    /// and repeated row/header reads are constant-time cache hits.
    func subagentFamily(_ sessionID: String) -> SubagentFamily {
        let item = record(sessionID)
        let ownerID = item?.delegation?.budgetOwnerSessionID ?? sessionID
        let owner = record(ownerID)
        if let item, item.isSubagent, let owner, item.workspaceID != owner.workspaceID {
            return SubagentFamily(ownerID: ownerID, members: [], runningCount: 0)
        }
        if let value = subagentFamilies[ownerID] { return value }
        let workspaceID = owner?.workspaceID ?? item?.workspaceID
        let members = subagentChildren(of: ownerID).filter { $0.workspaceID == workspaceID }.sorted {
            let a = $0.subagentNumber ?? Int.max, b = $1.subagentNumber ?? Int.max
            return a == b ? $0.id < $1.id : a < b
        }.map { child in
            let summary = subagentSummaries[child.id]
            return SubagentFamily.Member(chat: child, status: summary?.status,
                model: summary?.model ?? child.model ?? profiles.first(where: { $0.id == child.profileID })?.modelId ?? "Unknown model", spend: summary?.progress.flatMap { $0.reported > 0 ? $0.usd : nil })
        }
        let value = SubagentFamily(ownerID: ownerID, members: members, runningCount: members.filter(\.active).count)
        subagentFamilies[ownerID] = value
        return value
    }
    func subagentSearchTitle(_ chat: ChatRecord) -> String {
        guard let owner = chat.delegation?.budgetOwnerSessionID else { return chat.displayTitle }
        return chat.subagentShortTitle + " — in " + (record(owner)?.title ?? "Unavailable parent")
    }
    var canShowAgentFamily: Bool {
        (focusedSessionID ?? selectedID).map { !subagentFamily($0).members.isEmpty } ?? false
    }
    func showAgentFamily() {
        if let id = focusedSessionID ?? selectedID { agentFamilyRequests.send(subagentFamily(id).ownerID) }
    }
}

extension ChatRecord {
    var subagentShortTitle: String { (subagentNumber.map { "#\($0)" } ?? "Sub-agent") + " · " + title }
}
