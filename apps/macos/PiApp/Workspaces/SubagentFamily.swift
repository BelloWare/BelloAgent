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
    var queuedCount = 0
    var stoppingCount = 0
    var activeCount: Int { runningCount + queuedCount + stoppingCount }
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
        let value = SubagentFamily(ownerID: ownerID, members: members,
            runningCount: members.filter { $0.status == .running }.count,
            queuedCount: members.filter { $0.status == .queued }.count,
            stoppingCount: members.filter { $0.status == .stopping }.count)
        subagentFamilies[ownerID] = value
        return value
    }
    func subagentSearchTitle(_ chat: ChatRecord) -> String {
        guard let owner = chat.delegation?.budgetOwnerSessionID ?? sideFamilyOwner(chat) else { return chat.displayTitle }
        return (chat.isSubagent ? chat.subagentShortTitle : chat.title) + " — in " + (record(owner)?.title ?? "Unavailable parent")
    }
    var canShowAgentFamily: Bool {
        (focusedSessionID ?? selectedID).map { !conversationFamily($0).isEmpty } ?? false
    }
    func showAgentFamily() {
        if let id = focusedSessionID ?? selectedID { agentFamilyRequests.send(conversationFamily(id).ownerID) }
    }
}

struct FamilyActivity: Equatable {
    var workingSides = 0
    var runningAgents = 0
    var queuedAgents = 0
    var stoppingAgents = 0
    var working: Int { workingSides + runningAgents + stoppingAgents }
    var active: Int { working + queuedAgents }
    var badge: String { working > 0 ? "\(working) working" : "\(queuedAgents) queued" }
    var label: String {
        [(workingSides, "side", "working"), (runningAgents, "sub-agent", "running"),
         (queuedAgents, "sub-agent", "queued"), (stoppingAgents, "sub-agent", "stopping")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s") \($0.2)" }.joined(separator: ", ")
    }
}

struct ConversationFamily: Equatable {
    struct Side: Equatable {
        var id: String
        var title: String
        var status: String
        var working: Bool
        var spend: Double?
        var open: Bool
    }
    var ownerID: String
    var sides: [Side]
    var agents: SubagentFamily
    var canAddSide: Bool
    var isEmpty: Bool { sides.isEmpty && agents.members.isEmpty }
    var title: String {
        [(sides.count, "side"), (agents.members.count, "agent")].filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }.joined(separator: " · ")
    }
    var activity: FamilyActivity {
        .init(workingSides: sides.filter(\.working).count, runningAgents: agents.runningCount,
              queuedAgents: agents.queuedCount, stoppingAgents: agents.stoppingCount)
    }
}

extension WorkspaceModel {
    /// A retained child opens as a side only while its parent remains in the
    /// same project. Imported originals and orphaned sides remain main chats.
    func sideFamilyOwner(_ chat: ChatRecord) -> String? {
        guard !chat.isSubagent, !chat.imported, !chat.isBackgroundTask,
              let id = chat.parentSessionID, id != chat.id, let parent = record(id),
              parent.workspaceID == chat.workspaceID else { return nil }
        return id
    }
    func invalidateConversationFamily(_ id: String? = nil) {
        if let id, let chat = record(id) {
            conversationFamilies[id] = nil
            if let owner = chat.delegation?.budgetOwnerSessionID ?? sideFamilyOwner(chat) { conversationFamilies[owner] = nil }
        } else { conversationFamilies.removeAll(keepingCapacity: true) }
    }
    /// Metadata is grouped once, and status/spend are cached between activity
    /// publications. Neither the header nor a sidebar row reads transcripts.
    func conversationFamily(_ sessionID: String) -> ConversationFamily {
        let item = record(sessionID)
        let ownerID = item?.delegation?.budgetOwnerSessionID ?? item.flatMap(sideFamilyOwner) ?? sessionID
        let agents = subagentFamily(item?.isSubagent == true ? sessionID : ownerID)
        if let item, let owner = record(ownerID), item.workspaceID != owner.workspaceID {
            return .init(ownerID: ownerID, sides: [], agents: agents, canAddSide: false)
        }
        if let value = conversationFamilies[ownerID] { return value }
        if familySideRecords == nil {
            var grouped: [String: [ChatRecord]] = [:]
            for chat in chats { if let owner = sideFamilyOwner(chat) { grouped[owner, default: []].append(chat) } }
            familySideRecords = grouped
        }
        let shown = sides[ownerID]
        var records = (familySideRecords?[ownerID] ?? []).filter { !$0.isArchived || $0.id == shown?.id }
            .sorted { sidebarPrecedes($0, $1) }
        if let shown, !records.contains(where: { $0.id == shown.id }), shown.workspaceID == record(ownerID)?.workspaceID {
            records.insert(shown.chat, at: 0)
        }
        let members = records.map { chat -> ConversationFamily.Side in
            let display = displays[chat.id], pending = shown?.id == chat.id && shown?.pending == true
            let working = display.map { $0.busy || $0.loading } ?? false
            let failed = unreadFailure(sessionID: chat.id) || display?.runState == .error
            let unread = unreadOutputCount(sessionID: chat.id) > 0
            let status = working ? "Working" : failed ? "Failed" : unread ? (markedUnreadOnly(sessionID: chat.id) ? "Unread" : "New reply") : pending ? "Draft" : "Saved"
            let totals = display?.footer.gateway ?? chatAccounting.row(for: chat.id).totals
            let spend = totals.flatMap { $0.costSamples > 0 ? $0.costUSD : nil }
            return .init(id: chat.id, title: pending ? "New side" : chat.title, status: status, working: working,
                         spend: spend, open: shown?.id == chat.id)
        }
        let value = ConversationFamily(ownerID: ownerID, sides: members, agents: agents, canAddSide: canOpenSide(ownerID))
        conversationFamilies[ownerID] = value
        return value
    }
    func openFamilySide(_ id: String) async {
        await openFromSidebar(id)
        if side(id) != nil { tabs.showSide() }
    }
    func openNewFamilySide(_ ownerID: String) {
        page = .chats
        if selectedID == ownerID { openSide(parentID: ownerID); tabs.showSide() }
        else { Task { await select(ownerID, focusesComposer: false); guard selectedID == ownerID else { return }; openSide(parentID: ownerID); tabs.showSide() } }
    }
}

extension ChatRecord {
    var subagentShortTitle: String { (subagentNumber.map { "#\($0)" } ?? "Sub-agent") + " · " + title }
}
