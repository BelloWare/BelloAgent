import Foundation

/// A project choice belongs only to an unsaved, never-opened chat. Resetting
/// its display also retires editor undo, selected skills and request previews.
extension WorkspaceModel {
    var pendingChatProjects: [WorkspaceRecord] {
        workspaces.filter { $0.trusted && !$0.isScratch && !workspaceChangesInFlight.contains($0.id) }
    }

    /// Filesystem checks happen only on opening the picker or committing a
    /// choice, off the UI actor; never in the composer's layout or refresh.
    nonisolated static func availableChatProjects(_ projects: [WorkspaceRecord]) async -> [WorkspaceRecord] {
        await Task.detached(priority: .userInitiated) {
            projects.filter { project in
                project.roots.allSatisfy { path in
                    var directory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                        && directory.boolValue && FileManager.default.isReadableFile(atPath: path)
                }
            }
        }.value
    }

    func pendingProjectBlocker(_ id: String) -> String? {
        guard pendingChatIDs.contains(id), let item = record(id), item.path == nil,
              !item.imported, !item.isUtilityChat, !item.isArchived, item.parentSessionID == nil,
              !item.isSubagent, side(id) == nil, sides[id] == nil, !opened.contains(id) else {
            return "Only an unsaved new chat can change project. Start a new chat for another project."
        }
        guard !isShutDown, !installPreparing, !workspaceChangesInFlight.contains(item.workspaceID),
              pendingChatSaveCounts[id, default: 0] == 0,
              !isSessionOpening(id), sessionOpenings[id] == nil, sessionClosings[id] == nil, connectionSwitches[id] == nil,
              let view = displays[id], view.draftReady, !view.loading, !view.hasWork,
              view.messages.isEmpty, view.sendingRows.isEmpty, view.queue.isEmpty,
              !view.uncertain, view.recovered.isEmpty, view.submissionReviews.isEmpty,
              view.editingMessageID == nil, view.queueEditingID == nil, !view.editPreparing,
              !view.recoveringDraft else { return "Wait for this chat's current work to finish before changing project." }
        if view.imageImports > 0 { return "Wait for the image to finish attaching before changing project." }
        return nil
    }

    /// Uses precisely the ordinary New Chat seed, then carries only deliberate
    /// user input. No session, journal, capture or permission state is moved.
    func setPendingChatProject(_ projectID: String, for id: String) async throws {
        if let reason = pendingProjectBlocker(id) { throw HostError.failure(reason) }
        guard let item = record(id), let view = displays[id], selectedID == id else {
            throw HostError.failure("Open the new chat before changing its project.")
        }
        guard item.workspaceID != projectID else { return }
        guard let target = pendingChatProjects.first(where: { $0.id == projectID }) else {
            throw HostError.failure("Choose an available, trusted project.")
        }
        let profileID = requestProfiles.contains(where: { $0.id == profileChoice }) ? profileChoice : requestProfiles.first?.id
        guard let profileID else { throw HostError.failure("Choose a saved Responses connection first.") }
        await overrideWrites[profileID]?.task.value
        var fresh = try await newChatRecord(workspaceID: projectID, profileID: profileID, previousChatID: id, topicID: nil)
        let available = await Self.availableChatProjects([target])
        try Task.checkCancellation()
        // A send, rename, navigation, folder edit or loss of trust during the
        // reads wins. The old chat and draft remain untouched on every refusal.
        if let reason = pendingProjectBlocker(id) { throw HostError.failure(reason) }
        guard selectedID == id, displays[id] === view, record(id) == item,
              pendingChatProjects.contains(target), available == [target],
              requestProfiles.contains(where: { $0.id == profileID }),
              let index = chats.firstIndex(where: { $0.id == id }) else {
            throw HostError.failure("The chat or project changed. Choose its project again.")
        }
        fresh.id = id; fresh.sidebarOrder = item.sidebarOrder
        let replacement = SessionDisplay(id: id)
        replacement.draft = view.draft
        // Attachments are explicit user selections, individually hash-checked
        // again at delivery. Keeping them grants no access to their folders.
        replacement.attachments = view.attachments
        replacement.directCommand = false
        var notices: [String] = []
        if !view.skills.isEmpty { notices.append("Project changed. Selected skills were cleared; choose skills from this project.") }
        if !replacement.attachments.isEmpty, !modelInput(for: fresh).contains("image") {
            notices.append("Images kept. Choose a model that supports images before sending.")
        }
        replacement.notice = notices.joined(separator: " ")
        view.presentation.cancel()
        skillCatalogLoads.removeValue(forKey: id)?.task.cancel()
        if resourceCatalogSessionID == id {
            resourceCatalog = []; resourceCatalogWorkspaceID = nil; resourceCatalogSessionID = nil
            resourceLoading = false; resourceNotice = ""
        }
        cancelAutomaticContext(id)
        contextReadings.removeValue(forKey: id)
        // A caller holding the old record/lease cannot open it after the swap.
        connectionGenerations[id, default: 0] &+= 1
        chats[index] = fresh
        displays[id] = replacement; selected = replacement
        selectedWorkspaceID = projectID; profileChoice = profileID
        await select(id)
    }
}
