import Foundation

extension WorkspaceModel {
    func topics(in projectID: String) -> [TopicRecord] {
        topics.filter { $0.workspaceID == projectID }.sorted(by: TopicRecord.sidebarPrecedes)
    }

    /// Missing or mismatched metadata must never hide a retained conversation.
    func effectiveTopicID(for chat: ChatRecord) -> String? {
        guard !chat.isBackgroundTask, chat.workspaceID != WorkspaceRecord.scratchID,
              let id = chat.topicID,
              topics.contains(where: { $0.id == id && $0.workspaceID == chat.workspaceID }) else { return nil }
        return id
    }

    func restoreTopics() async throws {
        guard let store else { throw StoreError.unavailable }
        topics = try await store.listTopics()
    }

    func presentNewTopic(in projectID: String) {
        do {
            try requireTopicProject(projectID)
            topicEditor = TopicEditorTarget(projectID: projectID, topicID: nil)
        } catch { self.error = error.localizedDescription }
    }

    func presentRenameTopic(_ id: String) {
        guard let topic = topics.first(where: { $0.id == id }) else { return }
        do {
            try requireTopicProject(topic.workspaceID)
            topicEditor = TopicEditorTarget(projectID: topic.workspaceID, topicID: id)
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult func createTopic(in projectID: String, title: String) async throws -> TopicRecord {
        try requireTopicProject(projectID)
        guard let store else { throw StoreError.unavailable }
        topicOperationsInFlight += 1
        defer { topicOperationsInFlight -= 1 }
        let saved = try await store.createTopic(TopicRecord(id: UUID().uuidString, workspaceID: projectID,
                                                          title: try TopicRecord.normalizedTitle(title)))
        topics.append(saved)
        setProjectExpanded(projectID, expanded: true)
        return saved
    }

    func renameTopic(_ id: String, title: String) async throws {
        guard let topic = topics.first(where: { $0.id == id }) else { throw HostError.failure("This topic is no longer available.") }
        try requireTopicProject(topic.workspaceID)
        guard let store else { throw StoreError.unavailable }
        topicOperationsInFlight += 1
        defer { topicOperationsInFlight -= 1 }
        let saved = try await store.renameTopic(id: id, title: title)
        applyTopic(saved)
    }

    func removeTopic(_ id: String) async throws {
        guard let topic = topics.first(where: { $0.id == id }) else { throw HostError.failure("This topic is no longer available.") }
        try requireTopicProject(topic.workspaceID)
        guard let store else { throw StoreError.unavailable }
        topicOperationsInFlight += 1
        defer { topicOperationsInFlight -= 1 }
        let members = try await store.removeTopic(id: id)
        applyTopicMemberships(members)
        topics.removeAll { $0.id == id }
        topicExpansionRequests.removeValue(forKey: id)
        // Empty unsent chats and sides may not have a desktop record yet.
        // They remain in place and return to their project's top level too.
        for index in chats.indices where chats[index].topicID == id { chats[index].topicID = nil }
        for parentID in Array(sides.keys) where sides[parentID]?.topicID == id { sides[parentID]?.topicID = nil }
        if topicEditor?.topicID == id { topicEditor = nil }
    }

    /// Moves the selected branches as one desktop transaction. This method
    /// never selects a chat, opens a helper, sends, stops or changes a journal.
    func moveSessions(_ ids: [String], in projectID: String, toTopic topicID: String?) async throws {
        try requireTopicProject(projectID)
        guard !ids.isEmpty, ids.count <= 10_000 else { throw HostError.failure("Choose sessions to move.") }
        if let topicID, !topics.contains(where: { $0.id == topicID && $0.workspaceID == projectID }) {
            throw HostError.failure("Choose a topic in the same project.")
        }
        let chosen = Set(ids)
        guard chosen.allSatisfy({ id in
            chats.contains { $0.id == id && $0.workspaceID == projectID && !$0.isBackgroundTask && $0.connectionTest != true }
        }) else { throw HostError.failure("Sessions can only move between topics in their own project.") }
        guard let store else { throw StoreError.unavailable }
        let knownChatIDs = Set(chats.map(\.id))
        let branches = topicBranchIDs(chosen, in: projectID)
        let storedIDs = Set(chats.filter { branches.contains($0.id) }.map(\.id))
        topicOperationsInFlight += 1
        defer { topicOperationsInFlight -= 1 }
        // An explicit move makes an otherwise empty chat durable, just as a
        // rename does. Side placeholders remain lazy until their first send.
        for id in storedIDs.sorted() { try await materializeChat(id) }
        let saved = try await store.moveChatsToTopic(ids: storedIDs, workspaceID: projectID, topicID: topicID)
        applyTopicMemberships(saved, includingNewChildrenNotIn: knownChatIDs)
        let currentBranches = topicBranchIDs(chosen, in: projectID)
        for parentID in Array(sides.keys) {
            if let info = sides[parentID], currentBranches.contains(info.id), !chats.contains(where: { $0.id == info.id }),
               let parent = record(parentID) {
                // A side may open while the actor writes, and a newer move
                // may finish first. Follow the parent's current organization,
                // never this older operation's captured destination.
                sides[parentID]?.topicID = effectiveTopicID(for: parent)
            }
        }
        setProjectExpanded(projectID, expanded: true)
        if let topicID { setTopicExpanded(topicID, expanded: true) }
    }

    private func topicBranchIDs(_ roots: Set<String>, in projectID: String) -> Set<String> {
        var children: [String: [String]] = [:]
        for chat in chats where chat.workspaceID == projectID && !chat.isBackgroundTask && chat.connectionTest != true {
            if let parent = chat.parentSessionID { children[parent, default: []].append(chat.id) }
        }
        for info in sides.values where info.workspaceID == projectID { children[info.parentID, default: []].append(info.id) }
        var seen: Set<String> = [], pending = Array(roots)
        while let id = pending.popLast() {
            guard seen.insert(id).inserted else { continue }
            pending.append(contentsOf: children[id] ?? [])
        }
        return seen
    }

    private func requireTopicProject(_ projectID: String) throws {
        guard !installPreparing else { throw HostError.failure("Wait for the app update to finish before changing topics.") }
        guard !workspaceChangesInFlight.contains(projectID) else { throw HostError.failure("Wait for project changes to finish before changing topics.") }
        guard projectID != WorkspaceRecord.scratchID, sidebarProjects.contains(where: { $0.id == projectID }) else {
            throw HostError.failure("Choose a project for this topic.")
        }
    }

    private func applyTopic(_ saved: TopicRecord) {
        guard let index = topics.firstIndex(where: { $0.id == saved.id }), saved.revision >= topics[index].revision else { return }
        var current = saved
        if let desired = topicExpansionRequests[saved.id] { current.expanded = desired }
        topics[index] = current
    }

    private func applyTopicMemberships(_ saved: [ChatRecord], includingNewChildrenNotIn knownChatIDs: Set<String>? = nil) {
        for chat in saved {
            guard let index = chats.firstIndex(where: { $0.id == chat.id }) else {
                // A child can be committed while its publication callback is
                // still awaiting the actor. The move transaction includes it;
                // expose that durable metadata so an older callback cannot
                // subsequently restore its previous topic. A previously known
                // chat that disappeared during the await was removed locally;
                // this stale move response must not bring it back.
                if let knownChatIDs, !knownChatIDs.contains(chat.id) { chats.append(chat) }
                continue
            }
            guard (chat.organizationRevision ?? 0) >= (chats[index].organizationRevision ?? 0) else { continue }
            chats[index].applyOrganization(from: chat)
            if let info = side(chat.id) { sides[info.parentID]?.topicID = chats[index].topicID }
        }
    }

    func setTopicExpanded(_ id: String, expanded: Bool) {
        guard !installPreparing, let index = topics.firstIndex(where: { $0.id == id }), topics[index].expanded != expanded else { return }
        topics[index].expanded = expanded
        topicExpansionRequests[id] = expanded
        scheduleTopicExpansionWrite(id)
    }

    private func scheduleTopicExpansionWrite(_ id: String) {
        guard topicExpansionWrites[id] == nil else { return }
        topicExpansionWrites[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.topicExpansionWrites[id] = nil }
            while let expanded = self.topicExpansionRequests[id] {
                guard self.topics.contains(where: { $0.id == id }) else { self.topicExpansionRequests.removeValue(forKey: id); return }
                do {
                    guard let store = self.store else { throw StoreError.unavailable }
                    let saved = try await store.setTopicExpanded(id: id, expanded: expanded)
                    if self.topicExpansionRequests[id] == expanded { self.topicExpansionRequests.removeValue(forKey: id) }
                    self.applyTopic(saved)
                } catch {
                    // Removal may have completed during this actor write.
                    guard self.topics.contains(where: { $0.id == id }) else { self.topicExpansionRequests.removeValue(forKey: id); return }
                    self.error = "Topic preferences could not be saved. \(error.localizedDescription)"
                    return
                }
            }
        }
    }

    @discardableResult func flushTopicChanges(timeout: TimeInterval = 5) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var retried: Set<String> = []
        while topicOperationsInFlight > 0 || !topicExpansionRequests.isEmpty || !topicExpansionWrites.isEmpty {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return false }
            for id in topicExpansionRequests.keys where topicExpansionWrites[id] == nil && retried.insert(id).inserted {
                scheduleTopicExpansionWrite(id)
            }
            if topicOperationsInFlight == 0 && topicExpansionWrites.isEmpty { return topicExpansionRequests.isEmpty }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        return true
    }
}
