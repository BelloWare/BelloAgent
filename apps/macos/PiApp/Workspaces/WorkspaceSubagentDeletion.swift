import AppKit

extension WorkspaceModel {
    func subagentDirectory(_ workspaceID: String) throws -> URL {
        guard !workspaceID.isEmpty, workspaceID != ".", workspaceID != "..", !workspaceID.contains("/"), !workspaceID.contains("\\") else { throw StoreError.invalidRecord }
        let directory = root.resolvingSymlinksInPath().appendingPathComponent("Workspaces/\(workspaceID)/Sessions")
        guard directory.standardizedFileURL == directory.resolvingSymlinksInPath() else { throw StoreError.invalidRecord }
        return directory
    }

    func deleteSubagentFamily(_ parent: ChatRecord) async throws {
        guard !parent.isSubagent, !parent.imported, let store, displays[parent.id]?.hasWork != true,
              displays[parent.id]?.loading != true else { throw HostError.failure("Stop work before deleting this family.") }
        let existing = try await store.pendingFamilyDeletions().filter { $0.ownerID == parent.id }
        if !existing.isEmpty { try await finishFamilyDeletion(existing); return }
        guard deletingFamilies.insert(parent.id).inserted else { throw HostError.failure("This family is already being deleted.") }
        var durable = false
        defer { if !durable { deletingFamilies.remove(parent.id) } }
        let directory = try subagentDirectory(parent.workspaceID)
        let parentPath = parent.path ?? directory.appendingPathComponent(parent.id + ".jsonl").path
        let owner = SessionDeletionRecord(id: parent.id, ownerID: parent.id, workspaceID: parent.workspaceID, path: parentPath)
        // Reject unsupported paths before detaching the runtime or committing
        // tombstones, which intentionally prevent this chat from reopening.
        try await prepareFamilyDeletion(owner)
        helperSessionDidUnload(parent.id)
        // Read after the runtime is detached: no last-millisecond delegation
        // can escape the manifest. App opens are blocked during this operation.
        var plans: [DiscoveredSubagent] = []
        if FileManager.default.fileExists(atPath: parentPath) {
            plans = try await history.subagentPlans(path: URL(fileURLWithPath: parentPath), ownerID: parent.id)
        }
        var members = [owner]
        var known: Set<String> = [parent.id]
        for plan in plans where known.insert(plan.header.link.childSessionID).inserted {
            let id = plan.header.link.childSessionID
            if FileManager.default.fileExists(atPath: plan.path) { try await history.validateSubagentDeletion(path: URL(fileURLWithPath: plan.path), directory: directory, expected: SubagentTarget(plan.header.link)) }
            members.append(SessionDeletionRecord(id: id, ownerID: parent.id, workspaceID: parent.workspaceID, path: plan.path))
        }
        for child in subagentChildren(of: parent.id) where child.workspaceID == parent.workspaceID && known.insert(child.id).inserted {
            // Metadata cannot authorize deleting an unrelated file.
            if let path = child.path, let link = child.delegation, FileManager.default.fileExists(atPath: path) {
                try await history.validateSubagentDeletion(path: URL(fileURLWithPath: path), directory: directory, expected: SubagentTarget(link))
            }
            members.append(SessionDeletionRecord(id: child.id, ownerID: parent.id, workspaceID: parent.workspaceID, path: child.path))
        }
        for member in members where member.id != parent.id {
            _ = try familyDeletionJournal(member)
            if let host = hosts[parent.workspaceID], host.isReady { _ = try await host.request("session.forget", sessionID: member.id) }
            helperSessionDidUnload(member.id)
        }
        try await store.beginFamilyDeletion(members); durable = true
        try await finishFamilyDeletion(members, repaired: true)
    }

    private func prepareFamilyDeletion(_ owner: SessionDeletionRecord) async throws {
        let journal = try familyDeletionJournal(owner)
        var host = hosts[owner.workspaceID]
        if host?.isReady != true {
            try await host?.settleCaptureIfStopping()
            // A missing journal has no ledger left to repair. Inspection
            // errors must not be mistaken for absence and permit cleanup.
            guard let journal else { return }
            do {
                let values = try journal.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw StoreError.invalidRecord }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return }
            try await ensureConfiguration()
            guard let workspace = workspace(for: owner.workspaceID) else { throw HostError.failure("Restore this chat's project before deleting it so saved side costs can be repaired.") }
            host = try await self.host(for: workspace)
        }
        guard let host else { return }
        cancelIdle(workspaceID: owner.workspaceID)
        defer { scheduleIdle(workspaceID: owner.workspaceID, host: host) }
        // The helper refuses unsettled work and repairs surviving side ledgers
        // from the owner's committed charges, even with no loaded runtime or
        // capture evidence. Await that durable repair before tombstones/Trash.
        // Starting only the project helper needs no model profile/credential.
        _ = try await host.request("session.forget", sessionID: owner.id)
    }

    func markPendingFamilyDeletions() async {
        guard let store else { return }
        let intents = (try? await store.pendingFamilyDeletions()) ?? []
        deletingFamilies.formUnion(intents.map(\.ownerID))
    }

    func resumeFamilyDeletions() async {
        guard let store else { return }
        do {
            let intents = try await store.pendingFamilyDeletions()
            for members in Dictionary(grouping: intents, by: \.ownerID).values { try await finishFamilyDeletion(members) }
        } catch { self.error = "Family deletion is incomplete and will be retried. " + error.localizedDescription }
    }

    private func familyDeletionJournal(_ member: SessionDeletionRecord) throws -> URL? {
        guard let path = member.path else { return nil }
        let directory = try subagentDirectory(member.workspaceID), journal = URL(fileURLWithPath: path)
        // Durable forks and kept sides use the helper's existing names. Only
        // owners accept those aliases; managed children always use their UUID.
        let names = member.id == member.ownerID ? [member.id + ".jsonl", "fork_" + member.id + ".jsonl", "side_" + member.id + ".jsonl"] : [member.id + ".jsonl"]
        guard journal.resolvingSymlinksInPath().deletingLastPathComponent().path == directory.path,
              names.contains(journal.lastPathComponent) else { throw StoreError.invalidRecord }
        return journal
    }

    private func finishFamilyDeletion(_ members: [SessionDeletionRecord], repaired: Bool = false) async throws {
        guard let store, let owner = members.first?.ownerID else { return }
        deletingFamilies.insert(owner)
        if !repaired {
            // An older app's intent is not proof that it repaired side mirrors.
            // Retry before any cleanup, using the persisted owner even when it
            // is absent from the current chat-list window.
            guard let record = members.first(where: { $0.id == owner }),
                  try await store.get(String.self, kind: "session-deleted", id: owner) == owner else { throw StoreError.invalidRecord }
            try await prepareFamilyDeletion(record)
            helperSessionDidUnload(owner)
        }
        // Keep the parent until its children are gone, so a partial failure
        // still has an obvious entry from which the user can retry deletion.
        for member in members.sorted(by: { ($0.id == owner ? 1 : 0, $0.id) < ($1.id == owner ? 1 : 0, $1.id) }) {
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
                var files = names.filter { $0 == journal.lastPathComponent || $0 == journal.lastPathComponent + ".meta" || $0 == journal.lastPathComponent + ".promotion" || $0.hasPrefix(journal.lastPathComponent + ".stream") || JournalCheckpoint.isTemporary($0, for: journal) }
                    .sorted().map { directory.appendingPathComponent($0) }
                let outputs = try ToolOutputOwnership.directory(root: directory.appendingPathComponent("tool-output"), sessionID: member.id)
                // Use throwing inspection: an I/O failure must retain the intent.
                do {
                    let values = try outputs.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true else { throw StoreError.invalidRecord }
                    files.append(outputs)
                } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { }
                if !files.isEmpty {
                    if let familyFileRecycler { try await familyFileRecycler(files) }
                    else {
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            NSWorkspace.shared.recycle(files) { _, error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
                        }
                    }
                }
            }
            forgetReadState(member.id); forgetRunHold(member.id)
            for kind in ["chat", "draft", "anchor", "capture-preference", "handoff", "side-keep", SideKeepRegistration.kind, "session-read", RunHoldRecord.kind, ContextReading.recordKind, JournalSlimMark.kind] { try await store.remove(kind: kind, id: member.id) }
            try await store.removeAll(kind: "receipt:\(member.id)")
            try await store.removeAll(kind: "pending:\(member.id)")
            contextReadings.removeValue(forKey: member.id); subagentSummaries.removeValue(forKey: member.id)
            chats.removeAll { $0.id == member.id }; displays.removeValue(forKey: member.id); helperSessionDidUnload(member.id)
            forgetOpened(member.id)
            if selectedID == member.id { selectedID = nil; selected = nil }
            if focusedSessionID == member.id { focusedSessionID = nil }
            try await removeDeletedCapturePreference(sessionID: member.id)
            try await store.remove(kind: SessionDeletionRecord.kind, id: member.id)
        }
        try await restoreSideBudgets()
        for id in displays.keys { refreshCostReading(id) }
        deletingFamilies.remove(owner)
    }
}
