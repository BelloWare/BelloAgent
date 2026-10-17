import AppKit

struct SubagentFamily: Equatable {
    struct Member: Equatable {
        var chat: ChatRecord
        var status: SubagentStatus?
        var model: String
        var spend: Double?
        var effort: String? = nil
        /// Unsealed and held at the family's cost limit until Resume.
        var paused = false
        var active: Bool { status.map { !$0.terminal } ?? false }
        var label: String { chat.subagentShortTitle }
        var statusLabel: String { paused && active ? "Paused" : baseStatusLabel }
        private var baseStatusLabel: String {
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
    /// Held at the cost limit: neither working nor waiting for a slot.
    var pausedCount = 0
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
                model: summary?.model ?? child.model ?? profiles.first(where: { $0.id == child.profileID })?.modelId ?? "Unknown model", spend: familyMemberSpend(child.id,progress:summary?.progress), effort: subagentEffortLabel(child.id, summary: summary),
                paused: summary?.pausedAtCostLimit == true)
        }
        let value = SubagentFamily(ownerID: ownerID, members: members,
            runningCount: members.filter { $0.status == .running && !$0.paused }.count,
            queuedCount: members.filter { $0.status == .queued && !$0.paused }.count,
            stoppingCount: members.filter { $0.status == .stopping && !$0.paused }.count,
            pausedCount: members.filter { $0.paused && $0.active }.count)
        subagentFamilies[ownerID] = value
        return value
    }
    /// Prefer the same durable numeric state as the footer and budget. Retained
    /// captures are a fallback, never a replacement for an observed ledger.
    func familyMemberSpend(_ id: String, progress: SubagentProgress? = nil) -> Double? {
        let reading = budgetStates[id]?.reading ?? displays[id]?.footer.cost
        if let reading, let spent = reading.spentUSD { return reading.reportedRequests > 0 ? spent : nil }
        if let progress { return progress.reported > 0 ? progress.usd : nil }
        let totals = displays[id]?.footer.gateway ?? chatAccounting.values[id]
        return totals.flatMap { $0.costSamples > 0 ? $0.costUSD : nil }
    }
    func subagentSearchTitle(_ chat: ChatRecord) -> String {
        guard let owner = chat.delegation?.budgetOwnerSessionID ?? sideFamilyOwner(chat) else { return chat.displayTitle }
        return (chat.isSubagent ? chat.subagentShortTitle : chat.title) + " — in " + (record(owner)?.title ?? "Unavailable parent")
    }
    private var familyPickerSession: String? {
        guard let id = conversationCommandID() else { return nil }
        if let reader = hostedConversationReader(in: conversationWindow()), reader.container?.isPane == false { return reader.key }
        // The main column's anchor is covered and disabled on other pages.
        // A visible independent child window above keeps its own picker.
        guard page == .chats else { return nil }
        // Embedded readers have no header of their own. Their menu must use
        // the visible main column's anchor, even after another chat is selected.
        if subagentTab(id) != nil { return selectedID }
        let owner = record(id)?.delegation?.budgetOwnerSessionID ?? id
        if let chat = record(owner), let main = sideFamilyOwner(chat), main == selectedID { return main }
        return id
    }
    var canShowAgentFamily: Bool { familyPickerSession.map { !conversationFamily(familyPickerOwner($0)).isEmpty } ?? false }
    func showAgentFamily() {
        if let id = familyPickerSession { agentFamilyRequests.send(conversationFamily(familyPickerOwner(id)).ownerID) }
    }
}

struct FamilyActivity: Equatable {
    var workingSides = 0
    var runningAgents = 0
    var queuedAgents = 0
    var stoppingAgents = 0
    /// Held at the cost limit: named, but not activity (no spinner or badge).
    var pausedAgents = 0
    var working: Int { workingSides + runningAgents + stoppingAgents }
    var active: Int { working + queuedAgents }
    var badge: String { working > 0 ? "\(working) working" : "\(queuedAgents) queued" }
    var label: String {
        [(workingSides, "side", "working"), (runningAgents, "sub-agent", "running"),
         (queuedAgents, "sub-agent", "queued"), (stoppingAgents, "sub-agent", "stopping"), (pausedAgents, "sub-agent", "paused")]
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
    struct Row: Equatable {
        enum Content: Equatable { case side(Side); case agent(SubagentFamily.Member, ownerID: String); case inherited(InheritedSubagent, OriginalSubagentAvailability) }
        var content: Content
        var depth: Int
    }
    var ownerID: String
    var sides: [Side]
    var agents: SubagentFamily
    var canAddSide: Bool
    /// Separate delegation scopes belonging to the saved sides in this picker.
    /// They remain labelled by their own owner; numbers and Stop authority are
    /// never reassigned to the main chat.
    var sideAgentFamilies: [SubagentFamily] = []
    var rows: [Row] = []
    var agentFamilies: [SubagentFamily] { [agents] + sideAgentFamilies }
    var agentCount: Int { agentFamilies.reduce(0) { $0 + $1.members.count } + rows.filter { if case .inherited = $0.content { return true }; return false }.count }
    var isEmpty: Bool { sides.isEmpty && agentCount == 0 }
    var title: String {
        [(sides.count, "side"), (agentCount, "agent")].filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }.joined(separator: " · ")
    }
    var activity: FamilyActivity {
        agentFamilies.reduce(into: FamilyActivity(workingSides: sides.filter(\.working).count)) {
            $0.runningAgents += $1.runningCount; $0.queuedAgents += $1.queuedCount; $0.stoppingAgents += $1.stoppingCount
            $0.pausedAgents += $1.pausedCount
        }
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
    /// Display ancestry is separate from a delegation's authority. Forks with
    /// copied references offer their own family plus read-only original entries.
    func familyPickerOwner(_ sessionID: String) -> String {
        if let fork = subagentTab(sessionID)?.originalForkID { return fork }
        if inheritedSubagents[sessionID]?.isEmpty == false { return sessionID }
        var id = sessionID
        var visited: Set<String> = [id]
        while let chat = record(id), let parent = chat.delegation?.budgetOwnerSessionID ?? sideFamilyOwner(chat),
              let owner = record(parent), owner.workspaceID == chat.workspaceID, visited.insert(parent).inserted { id = parent }
        return id
    }
    func invalidateConversationFamily(_ id: String? = nil) {
        guard let id, record(id) != nil else { conversationFamilies.removeAll(keepingCapacity: true); return }
        var current: String? = id, visited = Set<String>()
        while let id = current, visited.insert(id).inserted {
            conversationFamilies[id] = nil
            current = record(id).flatMap { $0.delegation?.budgetOwnerSessionID ?? sideFamilyOwner($0) }
        }
    }
    /// Metadata is grouped once, and status/spend are cached between activity
    /// publications. Neither the header nor a sidebar row reads transcripts.
    func conversationFamily(_ sessionID: String) -> ConversationFamily {
        let item = record(sessionID)
        let ownerID = item?.delegation?.budgetOwnerSessionID ?? sessionID
        let agents = subagentFamily(sessionID)
        if let item, let owner = record(ownerID), item.workspaceID != owner.workspaceID {
            return .init(ownerID: ownerID, sides: [], agents: agents, canAddSide: false)
        }
        if let value = conversationFamilies[ownerID] { return value }
        if familySideRecords == nil {
            var grouped: [String: [ChatRecord]] = [:]
            for chat in chats { if let owner = sideFamilyOwner(chat) { grouped[owner, default: []].append(chat) } }
            familySideRecords = grouped
        }
        var members: [ConversationFamily.Side] = [], related: [SubagentFamily] = [], rows: [ConversationFamily.Row] = []
        var visited: Set<String> = [ownerID]
        func visit(_ parentID: String, depth: Int) {
            let shown = sides[parentID]
            // Retained archived forks remain reachable too; their archive state
            // is descriptive, not a reason to hide a branch and its descendants.
            var records = (familySideRecords?[parentID] ?? []).sorted { sidebarPrecedes($0, $1) }
            if let shown, !records.contains(where: { $0.id == shown.id }), shown.workspaceID == record(parentID)?.workspaceID {
                records.insert(shown.chat, at: 0)
            }
            for chat in records where visited.insert(chat.id).inserted {
                let display = displays[chat.id], pending = shown?.id == chat.id && shown?.pending == true
                let working = display.map { $0.busy || $0.loading } ?? false
                let failed = unreadFailure(sessionID: chat.id) || display?.runState == .error
                let unread = unreadOutputCount(sessionID: chat.id) > 0
                let status = working ? "Working" : display?.costPaused == true ? "Paused at cost limit" : failed ? "Failed" : unread ? (markedUnreadOnly(sessionID: chat.id) ? "Unread" : "New reply") : pending ? "Draft" : chat.isArchived ? "Archived" : "Saved"
                let spend = familyMemberSpend(chat.id)
                let side = ConversationFamily.Side(id: chat.id, title: pending ? "New side" : chat.title, status: status, working: working,
                    spend: spend, open: shown?.id == chat.id)
                members.append(side); rows.append(.init(content: .side(side), depth: depth))
                visit(chat.id, depth: depth + 1)
            }
            guard record(parentID)?.isSubagent != true else { return }
            let group = subagentFamily(parentID)
            if parentID != ownerID, !group.members.isEmpty { related.append(group) }
            for member in group.members where visited.insert(member.chat.id).inserted {
                rows.append(.init(content: .agent(member, ownerID: parentID), depth: depth))
                visit(member.chat.id, depth: depth + 1)
            }
            for original in inheritedSubagents[parentID] ?? [] {
                rows.append(.init(content: .inherited(original, originalAvailability(original.target)), depth: depth))
            }
        }
        visit(ownerID, depth: 0)
        let value = ConversationFamily(ownerID: ownerID, sides: members, agents: agents,
            canAddSide: canOpenSide(ownerID) && familyPickerOwner(ownerID) == ownerID, sideAgentFamilies: related, rows: rows)
        conversationFamilies[ownerID] = value
        return value
    }
    func openFamilySide(_ id: String) async {
        await openFromSidebar(id)
    }
    func openNewFamilySide(_ ownerID: String) {
        page = .chats
        if selectedID == ownerID { openSide(parentID: ownerID); tabs.showSide() }
        else {
            tabs.showSide()
            let intent = tabs.navigationRevision, selection = selectionRevision, revision = messageNavigationRevision
            Task {
                guard !Task.isCancelled, messageNavigationRevision == revision, tabs.navigationRevision == intent, selectionRevision == selection else { return }
                await select(ownerID, focusesComposer: false)
                guard !Task.isCancelled, messageNavigationRevision == revision + 1, tabs.navigationRevision == intent, selectionRevision == selection + 1, selectedID == ownerID else { return }
                openSide(parentID: ownerID)
            }
        }
    }
}

extension ChatRecord {
    var subagentShortTitle: String { (subagentNumber.map { "#\($0)" } ?? "Sub-agent") + " · " + title }
}
