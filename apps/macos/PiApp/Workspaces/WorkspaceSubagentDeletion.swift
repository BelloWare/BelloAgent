import AppKit

extension WorkspaceModel {
    func subagentDirectory(_ workspaceID: String) throws -> URL {
        guard !workspaceID.isEmpty, workspaceID != ".", workspaceID != "..", !workspaceID.contains("/"), !workspaceID.contains("\\") else { throw StoreError.invalidRecord }
        let directory = root.resolvingSymlinksInPath().appendingPathComponent("Workspaces/\(workspaceID)/Sessions")
        guard directory.standardizedFileURL == directory.resolvingSymlinksInPath() else { throw StoreError.invalidRecord }
        return directory
    }

    /// What one Delete removes (owner decision, 2026-10-16): the chat, its
    /// saved sides at every depth and every member's managed sub-agents. A
    /// deleted side's spend stays counted in its surviving ancestors.
    struct FamilyDeletionPreview {
        var sides: [(chat: ChatRecord, depth: Int)] = []
        var managedCount = 0
        /// Work that needs the project folder, which is missing or removed.
        var skipped: [String] = []
        var projectUnavailable = false
    }

    /// Saved sides below `root` from the complete durable graph, plus any
    /// loaded record the store has not caught up with. Off the main actor.
    func savedSideDescendants(of root: ChatRecord) async throws -> [(chat: ChatRecord, depth: Int)] {
        guard let store, !root.isSubagent, !root.imported else { return [] }
        var found = try await store.savedSideDescendants(of: root.id, workspaceID: root.workspaceID)
        var known = Set(found.map(\.chat.id)).union([root.id])
        func depth(_ item: ChatRecord) -> Int? {
            var current = item, value = 0, seen: Set<String> = [item.id]
            while let id = current.persistedBudgetParentID, seen.insert(id).inserted, value < 128 {
                value += 1
                if id == root.id { return value }
                guard let parent = record(id), parent.workspaceID == root.workspaceID else { return nil }
                current = parent
            }
            return nil
        }
        for item in chats where !item.isSubagent && !item.imported && item.workspaceID == root.workspaceID && !known.contains(item.id) {
            if let value = depth(item) { found.append((item, value)); known.insert(item.id) }
        }
        // Each side directly under its parent, as the family picker reads.
        var children: [String: [(chat: ChatRecord, depth: Int)]] = [:]
        for side in found { children[side.chat.persistedBudgetParentID ?? "", default: []].append(side) }
        var ordered: [(chat: ChatRecord, depth: Int)] = []
        func visit(_ id: String) {
            let next = (children.removeValue(forKey: id) ?? []).sorted {
                let order = $0.chat.title.localizedStandardCompare($1.chat.title)
                return order == .orderedSame ? $0.chat.id < $1.chat.id : order == .orderedAscending
            }
            for side in next { ordered.append(side); visit(side.chat.id) }
        }
        visit(root.id)
        return ordered
    }

    /// Why the helper cannot start for this project's chats right now, if so.
    /// Only the app's own chat data is touched while it is unavailable.
    func deletionProjectUnavailable(_ workspaceID: String) -> String? {
        guard let workspace = workspace(for: workspaceID) else { return "This chat's project was removed from Bello." }
        guard !workspace.isScratch else { return nil }
        do { try requireProjectFolders(workspace) }
        catch { return "This chat's project folder is missing." }
        // Owner decision (2026-10-17): an untrusted project cannot start its
        // helper either; deletion skips the same step rather than refusing.
        return workspace.trusted ? nil : "This chat's project is not trusted."
    }

    /// The text a confirmation and a result name for a skipped repair.
    func skippedRepairNote(_ root: ChatRecord) -> String {
        let owner = budgetOwner(for: root)
        let name = owner.id == root.id ? "its parent chat" : "“\(owner.title)”"
        return "Skipped: copying unreported spend from interrupted requests into \(name), which needs the project's helper. Spend already counted there stays counted."
    }

    /// A deleted side's surviving ancestors need the helper's ledger repair;
    /// a main chat has none, and every saved side goes with it. Listed sides
    /// keep their persisted ancestors loaded, so an absent parent is deleted
    /// (a side orphaned by 0.1.128 is its own budget owner).
    func deletionNeedsAncestorRepair(_ root: ChatRecord) -> Bool {
        guard root.delegation == nil, let parent = root.persistedBudgetParentID else { return false }
        return record(parent) != nil && !deletingFamilies.contains(parent)
    }

    func familyDeletionPreview(_ root: ChatRecord) async throws -> FamilyDeletionPreview {
        var preview = FamilyDeletionPreview()
        var managed = Set(subagentChildren(of: root.id).map(\.id))
        guard !root.imported else { preview.managedCount = managed.count; return preview }
        preview.sides = try await savedSideDescendants(of: root)
        let directory = try subagentDirectory(root.workspaceID)
        for (owner, path) in [(root.id, root.path ?? directory.appendingPathComponent(root.id + ".jsonl").path)] + preview.sides.compactMap({ side in side.chat.path.map { (side.chat.id, $0) } }) {
            managed.formUnion(subagentChildren(of: owner).map(\.id))
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard URL(fileURLWithPath: path).resolvingSymlinksInPath().deletingLastPathComponent().path == directory.path else { throw StoreError.invalidRecord }
            let plans = try await history.subagentPlans(path: URL(fileURLWithPath: path), ownerID: owner)
            managed.formUnion(plans.map { $0.header.link.childSessionID })
        }
        preview.managedCount = managed.count
        if let reason = deletionProjectUnavailable(root.workspaceID) {
            preview.projectUnavailable = true
            preview.skipped.append(reason + " Only Bello's own copy of the chat is removed; nothing in the project folder is touched.")
            if deletionNeedsAncestorRepair(root), hosts[root.workspaceID]?.isReady != true { preview.skipped.append(skippedRepairNote(root)) }
        }
        return preview
    }

    /// Deletes `parent` with its saved sides at every depth and all of their
    /// managed sub-agents, under one durable intent. Returns what was skipped
    /// because the project is unavailable (the chat's own files still go).
    @discardableResult
    func deleteSubagentFamily(_ parent: ChatRecord) async throws -> [String] {
        guard !parent.isSubagent, !parent.imported, let store, displays[parent.id]?.hasWork != true,
              displays[parent.id]?.loading != true else { throw HostError.failure("Stop work before deleting this family.") }
        try beginBudgetOwnerChange(parent.id)
        defer { budgetOwnerChanges.remove(parent.id) }
        let existing = try await store.pendingFamilyDeletions().filter { $0.ownerID == parent.id }
        if !existing.isEmpty { try await finishFamilyDeletion(existing); return [] }
        // An interrupted deletion of a side below this chat owns its members'
        // receipts. Finish it first; a new manifest never adopts them.
        try await finishOtherPendingDeletions(parent)
        guard deletingFamilies.insert(parent.id).inserted else { throw HostError.failure("This family is already being deleted.") }
        var durable = false, blocked: Set<String> = [parent.id]
        defer { if !durable { deletingFamilies.subtract(blocked) } }
        let directory = try subagentDirectory(parent.workspaceID)
        let parentPath = parent.path ?? directory.appendingPathComponent(parent.id + ".jsonl").path
        let owner = SessionDeletionRecord(id: parent.id, ownerID: parent.id, workspaceID: parent.workspaceID, path: parentPath)
        let repairAncestors = deletionNeedsAncestorRepair(parent)
        // Every saved side below goes too. Block their opens and discovery
        // before any runtime detaches; the tombstones keep them blocked.
        var members = [owner]
        var known: Set<String> = [parent.id]
        for side in try await savedSideDescendants(of: parent) where known.insert(side.chat.id).inserted {
            // Fail closed rather than overwrite another deletion's receipt.
            // Own the mark before any await, so every failure below releases it.
            guard deletingFamilies.insert(side.chat.id).inserted else { throw sideStillFinishing(side.chat) }
            blocked.insert(side.chat.id)
            guard try await sideTombstoneOwner(side.chat.id) == nil else { throw sideStillFinishing(side.chat) }
            members.append(SessionDeletionRecord(id: side.chat.id, ownerID: parent.id, workspaceID: parent.workspaceID, path: side.chat.path, sideDepth: side.depth))
        }
        // Reject unsupported paths before detaching the runtime or committing
        // tombstones, which intentionally prevent these chats from reopening.
        for member in members { _ = try familyDeletionJournal(member) }
        if let busy = members.lazy.compactMap({ self.displays[$0.id] }).first(where: { $0.hasWork || $0.loading }) {
            throw HostError.failure(budgetMemberBusy(busy.id))
        }
        let skipped = try await prepareFamilyDeletion(owner, descendantsDeleted: true, repairAncestors: repairAncestors)
            .map { _ in skippedRepairNote(parent) }
        helperSessionDidUnload(parent.id)
        // Read after the runtimes are detached: no last-millisecond delegation
        // can escape the manifest. App opens are blocked during this operation.
        let owners = members
        for delegator in owners {
            let path = delegator.path ?? parentPath
            var plans: [DiscoveredSubagent] = []
            if FileManager.default.fileExists(atPath: path) {
                plans = try await history.subagentPlans(path: URL(fileURLWithPath: path), ownerID: delegator.id)
            }
            for plan in plans where known.insert(plan.header.link.childSessionID).inserted {
                let id = plan.header.link.childSessionID
                if FileManager.default.fileExists(atPath: plan.path) { try await history.validateSubagentDeletion(path: URL(fileURLWithPath: plan.path), directory: directory, expected: SubagentTarget(plan.header.link)) }
                members.append(SessionDeletionRecord(id: id, ownerID: parent.id, workspaceID: parent.workspaceID, path: plan.path))
            }
            for child in subagentChildren(of: delegator.id) where child.workspaceID == parent.workspaceID && known.insert(child.id).inserted {
                // Metadata cannot authorize deleting an unrelated file.
                if let path = child.path, let link = child.delegation, FileManager.default.fileExists(atPath: path) {
                    try await history.validateSubagentDeletion(path: URL(fileURLWithPath: path), directory: directory, expected: SubagentTarget(link))
                }
                members.append(SessionDeletionRecord(id: child.id, ownerID: parent.id, workspaceID: parent.workspaceID, path: child.path))
            }
        }
        for member in members where member.id != parent.id {
            _ = try familyDeletionJournal(member)
            // The root's forget already repaired every surviving ancestor
            // from the whole deleted subtree; members only detach and clear.
            if let host = hosts[parent.workspaceID], host.isReady {
                _ = try await host.request("session.forget", sessionID: member.id, params: ["descendantsDeleted": .bool(true), "ancestorsRepaired": .bool(true)])
            }
            helperSessionDidUnload(member.id)
        }
        try await store.beginFamilyDeletion(members, repairCompleted: true); durable = true
        members[0].repairCompleted = true // committed by beginFamilyDeletion above
        try await finishFamilyDeletion(members)
        return skipped
    }

    /// Detaches the deleted root's runtimes. With `repairAncestors`, the
    /// helper first repairs surviving ancestors' ledgers from the deleted
    /// subtree. Returns a non-empty value when that repair was skipped
    /// because the project is unavailable; no runtime can be loaded then.
    /// Without `descendantsDeleted` (intents from older versions), surviving
    /// saved sides also receive the owner's committed charges.
    private func prepareFamilyDeletion(_ owner: SessionDeletionRecord, descendantsDeleted: Bool = false, repairAncestors: Bool = true) async throws -> [String] {
        let journal = try familyDeletionJournal(owner)
        var host = hosts[owner.workspaceID]
        if host?.isReady != true {
            try await host?.settleCaptureIfStopping()
            // Nothing is loaded and no survivor needs this ledger: deleting a
            // main chat with its whole family needs no helper at all.
            if descendantsDeleted && !repairAncestors { return [] }
            // A missing journal has no ledger left to repair. Inspection
            // errors must not be mistaken for absence and permit cleanup.
            guard let journal else { return [] }
            do {
                let values = try journal.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw StoreError.invalidRecord }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return [] }
            try await ensureConfiguration()
            // Owner decision (2026-10-16): a missing project no longer blocks
            // deletion; the repair that needs it is skipped and named.
            if descendantsDeleted, let reason = deletionProjectUnavailable(owner.workspaceID) { return [reason] }
            guard let workspace = workspace(for: owner.workspaceID) else { throw HostError.failure("Restore this chat's project before deleting it so saved side costs can be repaired.") }
            host = try await self.host(for: workspace)
        }
        guard let host else { return [] }
        cancelIdle(workspaceID: owner.workspaceID)
        defer { scheduleIdle(workspaceID: owner.workspaceID, host: host) }
        // The helper refuses unsettled work and repairs surviving ledgers
        // from the deleted subtree's committed charges, even with no loaded
        // runtime or capture evidence. Await that durable repair before
        // tombstones/Trash. Starting only the project helper needs no model
        // profile/credential.
        try await releaseIdleBudgetDependents(of:owner.id,host:host)
        _ = try await host.request("session.forget", sessionID: owner.id, params: descendantsDeleted ? ["descendantsDeleted": .bool(true)] : [:])
        return []
    }

    private func sideStillFinishing(_ side: ChatRecord) -> Error {
        HostError.failure("An earlier deletion of “\(side.title)” is still finishing. Try again in a moment.")
    }
    /// Test seam for the durable tombstone read during manifest building.
    func sideTombstoneOwner(_ id: String) async throws -> String? {
        if let deletionTombstoneRead { return try await deletionTombstoneRead(id) }
        return try await store?.get(String.self, kind: "session-deleted", id: id)
    }

    /// Finishes this project's other interrupted deletions first. One may be
    /// rooted at a side below `root` and own its members' receipts; a new
    /// manifest never adopts those. A deletion that still cannot finish is
    /// left for its own retry, and the tombstone check below fails closed.
    private func finishOtherPendingDeletions(_ root: ChatRecord) async throws {
        guard let store else { return }
        let groups = Dictionary(grouping: try await store.pendingFamilyDeletions(), by: \.ownerID)
        for (owner, members) in groups.sorted(by: { $0.key < $1.key }) where owner != root.id && members.first?.workspaceID == root.workspaceID {
            try? await finishFamilyDeletion(members)
        }
    }

    func markPendingFamilyDeletions() async {
        guard let store else { return }
        let intents = (try? await store.pendingFamilyDeletions()) ?? []
        deletingFamilies.formUnion(intents.map(\.ownerID))
        deletingFamilies.formUnion(intents.filter { $0.sideDepth != nil }.map(\.id))
    }

    func resumeFamilyDeletions() async {
        guard let store else { return }
        do {
            let intents = try await store.pendingFamilyDeletions()
            if intents.isEmpty { try await recycleUnreferencedToolOutputs() }
            for members in Dictionary(grouping: intents, by: \.ownerID).values { try await finishFamilyDeletion(members) }
        } catch { self.error = "Family deletion is incomplete and will be retried. " + error.localizedDescription }
    }

    /// Physical owners may have been deleted before their last fork. Their
    /// tombstones persist, and surviving journals/drafts retain the bytes.
    /// Nothing is copied, and only explicitly deleted owners can be reclaimed.
    private func recycleUnreferencedToolOutputs() async throws {
        guard let store else { return }
        let owners = try await store.deletedToolOutputOwners()
        guard !owners.isEmpty else { return }
        let deleted = Set(owners.values.flatMap { $0 })
        let root = self.root
        let listing = Task.detached(priority: .utility) { try ToolOutputOwnership.inventory(appRoot: root, deleted: owners) }
        let inventory = try await withTaskCancellationHandler { try await listing.value } onCancel: { listing.cancel() }
        guard !inventory.folders.isEmpty else { return }
        let candidates = inventory.keys
        let metadata = try await store.toolOutputReferences(root: root, candidates: candidates, deleted: deleted)
        let scan = Task.detached(priority: .utility) {
            try ToolOutputOwnership.references(in: inventory.journals.union(metadata.journals), candidates: candidates)
        }
        let references = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
        // A writer/import that changed the reference set wins. The tombstone
        // leaves these files eligible for the next deletion/relaunch sweep.
        let unchanged = await Task.detached(priority: .utility) { inventory.unchanged && references.unchanged }.value
        guard unchanged, try await store.pastedImageReferencesUnchanged(metadata.token) else { return }
        var kept = references.keys.union(metadata.keys)
        for view in displays.values where !deleted.contains(view.id) {
            kept.formUnion(try ToolOutputOwnership.references(in: JSONEncoder().encode(view.savedDraft), candidates: candidates))
            for draft in [view.draftBeforeEdit, view.draftBeforeQueueEdit].compactMap({ $0 }) {
                kept.formUnion(try ToolOutputOwnership.references(in: JSONEncoder().encode(draft), candidates: candidates))
            }
        }
        try Task.checkCancellation()
        let files = inventory.recyclable(keeping: kept)
        guard !files.isEmpty else { return }
        if let familyFileRecycler { try await familyFileRecycler(files) }
        else {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.recycle(files) { _, error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
            }
        }
    }

    private func familyDeletionJournal(_ member: SessionDeletionRecord) throws -> URL? {
        guard let path = member.path else { return nil }
        let directory = try subagentDirectory(member.workspaceID), journal = URL(fileURLWithPath: path)
        // Durable forks and kept sides use the helper's existing names. Only
        // owners accept those aliases; managed children always use their UUID.
        let names = member.id == member.ownerID ? [member.id + ".jsonl", "fork_" + member.id + ".jsonl", "side_" + member.id + ".jsonl"]
            : member.sideDepth != nil ? (member.isSavedSide ? ["side_" + member.id + ".jsonl"] : []) : [member.id + ".jsonl"]
        guard journal.resolvingSymlinksInPath().deletingLastPathComponent().path == directory.path,
              names.contains(journal.lastPathComponent) else { throw StoreError.invalidRecord }
        return journal
    }

    private func finishFamilyDeletion(_ members: [SessionDeletionRecord]) async throws {
        guard let store, let owner = members.first?.ownerID else { return }
        deletingFamilies.insert(owner)
        guard let record = members.first(where: { $0.id == owner }),
              try await store.get(String.self, kind: "session-deleted", id: owner) == owner else { throw StoreError.invalidRecord }
        if record.repairCompleted != true {
            // An older app's intent is not proof that it repaired side mirrors.
            // Retry before any cleanup, using the persisted owner even when it
            // is absent from the current chat-list window.
            _ = try await prepareFamilyDeletion(record)
            helperSessionDidUnload(owner)
            try await store.completeFamilyDeletionRepair(owner)
        }
        try familyDeletionStep?("repaired")
        // Validate the complete manifest before deleting any file. Remove the
        // owner journal first, then saved sides parents-first: a cold family
        // scan must never discover a side whose children have already been
        // intentionally removed. The repair receipt and owner metadata remain
        // until every file is cleaned up.
        for member in members {
            guard member.ownerID == owner, try await store.get(String.self, kind: "session-deleted", id: member.id) == owner else { throw StoreError.invalidRecord }
            _ = try familyDeletionJournal(member)
        }
        try await store.rememberDeletedToolOutputOwners(members)
        func rank(_ member: SessionDeletionRecord) -> Int { member.id == owner ? 0 : member.sideDepth ?? 129 }
        for member in members.sorted(by: { (rank($0), $0.id) < (rank($1), $1.id) }) {
            guard member.ownerID == owner, try await store.get(String.self, kind: "session-deleted", id: member.id) == owner else { throw StoreError.invalidRecord }
            let directory = try subagentDirectory(member.workspaceID)
            let journal = try familyDeletionJournal(member)
            try removeRetiredCaptureSpools(sessionID: member.id)
            try await traces.clear(sessionID: member.id)
            try await traces.forgetSubagentRelationships(sessionID: member.id, workspaceID: member.workspaceID)
            if let journal {
                let names: [String]
                do { names = try FileManager.default.contentsOfDirectory(atPath: directory.path) }
                catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { names = [] }
                let files = names.filter { $0 == journal.lastPathComponent || $0 == journal.lastPathComponent + ".meta" || $0 == journal.lastPathComponent + ".origin" || $0 == journal.lastPathComponent + ".promotion" || $0.hasPrefix(journal.lastPathComponent + ".stream") || JournalCheckpoint.isTemporary($0, for: journal) }
                    .sorted().map { directory.appendingPathComponent($0) }
                if !files.isEmpty {
                    if let familyFileRecycler { try await familyFileRecycler(files) }
                    else {
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            NSWorkspace.shared.recycle(files) { _, error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
                        }
                    }
                }
            }
            try familyDeletionStep?("files:" + member.id)
        }
        try await recycleUnreferencedToolOutputs()
        // Keep the owner's retry entry/repair proof until child metadata and
        // intents are gone too. Retrying never needs a deleted child journal.
        for member in members.sorted(by: { (rank($0), $0.id) > (rank($1), $1.id) }) {
            forgetReadState(member.id); forgetRunHold(member.id)
            for kind in ["chat", "draft", "anchor", "capture-preference", "handoff", "side-keep", SideKeepRegistration.kind, "session-read", RunHoldRecord.kind, ContextReading.recordKind, JournalSlimMark.kind] { try await store.remove(kind: kind, id: member.id) }
            try await store.removeAll(kind: "receipt:\(member.id)")
            try await store.removeAll(kind: "pending:\(member.id)")
            contextReadings.removeValue(forKey: member.id); subagentSummaries.removeValue(forKey: member.id); subagentEfforts.removeValue(forKey: member.id)
            for (parentID, info) in sides where parentID == member.id || info.id == member.id {
                sides.removeValue(forKey:parentID)
                if info.pending { displays.removeValue(forKey:info.id); forgetOpened(info.id) }
                else { displays[info.id]?.presentation.cancel() }
            }
            chats.removeAll { $0.id == member.id }; displays.removeValue(forKey: member.id); helperSessionDidUnload(member.id)
            forgetOpened(member.id)
            if selectedID == member.id { selectedID = nil; selected = nil }
            if focusedSessionID == member.id { focusedSessionID = nil }
            try await removeDeletedCapturePreference(sessionID: member.id)
            // A side published without a chat row may carry a recovery notice;
            // its intent and file are gone now, so the notice goes too.
            if sideKeepIssues.contains(where: { $0.id == member.id }) {
                sideKeepResolutionRevision &+= 1
                sideKeepIssues.removeAll { $0.id == member.id }
            }
            try familyDeletionStep?("metadata:" + member.id)
            try await store.remove(kind: SessionDeletionRecord.kind, id: member.id)
            if member.id != owner { try familyDeletionStep?("intent:" + member.id) }
        }
        try await restoreSideBudgets()
        for id in displays.keys { refreshCostReading(id) }
        deletingFamilies.remove(owner)
        deletingFamilies.subtract(members.filter { $0.sideDepth != nil }.map(\.id))
    }
}
