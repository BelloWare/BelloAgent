import AppKit

// Multi-folder workspaces. The primary `path` stays the host working directory
// and display name; `paths` adds trusted folders. Folder changes are durable in
// the configuration vault first and take effect when the workspace host is
// reopened, so they are refused while that workspace still has active work.
extension WorkspaceModel {
    /// Total roots (primary + extras) the host accepts for one workspace.
    static let maximumRoots = 16

    /// Directory picker; symlinks are resolved so duplicates compare by real path.
    static func chooseFolders(message: String, multiple: Bool) async -> [String] {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = false
        panel.allowsMultipleSelection = multiple; panel.message = message
        return await PiQuestion.shared.open(panel).map { $0.resolvingSymlinksInPath().path }
    }

    /// Rejects relative, missing, duplicate or overlong root lists before they reach the vault.
    static func validateRoots(_ roots: [String]) throws {
        guard !roots.isEmpty else { throw HostError.failure("A project needs a primary folder.") }
        guard roots.count <= maximumRoots else { throw HostError.failure("A project can contain up to \(maximumRoots) folders.") }
        guard Set(roots).count == roots.count else { throw HostError.failure("Each folder can be part of a project only once.") }
        for root in roots {
            var directory: ObjCBool = false
            guard root.hasPrefix("/"), root.utf8.count <= 4096, FileManager.default.fileExists(atPath: root, isDirectory: &directory), directory.boolValue else {
                throw HostError.failure("\(root) is not an existing folder.")
            }
        }
    }

    func chatCount(workspaceID: String) -> Int { chats.filter { $0.workspaceID == workspaceID }.count }

    /// A project folder moved or renamed while the app was closed used to
    /// reach the helper launch, which failed as "The bundled host could not
    /// start. Reinstall this build." Checked first, it is named instead, and
    /// the project is marked so its chats offer Locate Folder….
    func requireProjectFolders(_ workspace: WorkspaceRecord) throws {
        guard let missing = workspace.roots.first(where: { root in
            var directory: ObjCBool = false
            return !FileManager.default.fileExists(atPath: root, isDirectory: &directory) || !directory.boolValue
        }) else {
            if missingProjectFolders[workspace.id] != nil { missingProjectFolders.removeValue(forKey: workspace.id) }
            return
        }
        missingProjectFolders[workspace.id] = missing
        throw HostError.failure("The project folder \(missing) is missing or was moved. Choose Locate Folder… to point the project at where it is now; its chats stay as they are.")
    }

    /// Points a project at the new place of a folder that was moved, keeping
    /// the project, its chats and their journals (they live in app storage
    /// under the project's id, not in the folder).
    func relocateProjectFolder(_ workspaceID: String, from missing: String, to folder: String) async throws {
        try await ensureConfiguration()
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { throw HostError.failure("This project is no longer configured.") }
        guard workspace.roots.contains(missing) else { throw HostError.failure("That folder is not part of this project.") }
        try requireIdle(workspaceID)
        let replacement = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
        // Only the new place has to exist now: another folder of the project
        // may be missing too, and is located on its own.
        try Self.validateRoots([replacement])
        let roots = workspace.roots.map { $0 == missing ? replacement : $0 }
        guard Set(roots).count == roots.count else { throw HostError.failure("That folder is already part of this project.") }
        if let other = workspaces.first(where: { $0.id != workspaceID && $0.path == replacement }) {
            throw HostError.failure("\(other.path) is already another project. Choose the folder this project was moved to.")
        }
        workspaceChangesInFlight.insert(workspaceID)
        defer { workspaceChangesInFlight.remove(workspaceID) }
        try await updateConfiguration { config in
            guard let index = config.workspaces.firstIndex(where: { $0.id == workspaceID }) else { throw HostError.failure("This project is no longer configured.") }
            if config.workspaces[index].path == missing { config.workspaces[index].path = replacement }
            else { config.workspaces[index].paths = config.workspaces[index].paths.map { $0 == missing ? replacement : $0 } }
        }
        missingProjectFolders.removeValue(forKey: workspaceID)
        try await restartWorkspaceHost(workspaceID)
        for chat in chats where chat.workspaceID == workspaceID { displays[chat.id]?.sendFailure = nil }
    }

    /// Asks where a moved project folder is now, then points the project there.
    func locateMissingFolder(_ workspaceID: String) async {
        guard let missing = missingProjectFolders[workspaceID] else { return }
        let name = URL(fileURLWithPath: missing).lastPathComponent
        guard let folder = await Self.chooseFolders(message: "Where is the folder “\(name)” now? It was at \(missing).", multiple: false).first else { return }
        do { try await relocateProjectFolder(workspaceID, from: missing, to: folder) }
        catch { self.error = error.localizedDescription }
    }

    /// True while chats or unkept sides of this workspace are running, queued or loading.
    func workspaceHasActiveWork(_ workspaceID: String) -> Bool {
        workspaceChangesInFlight.contains(workspaceID)
            || sides.values.contains { $0.workspaceID == workspaceID && !$0.kept && !$0.pending }
            || displays.values.contains { ($0.hasWork || $0.loading) && record($0.id)?.workspaceID == workspaceID }
    }

    private func requireIdle(_ workspaceID: String) throws {
        guard !installPreparing else { throw HostError.failure("Wait for the app update to finish before changing projects.") }
        guard !workspaceHasActiveWork(workspaceID) else { throw HostError.failure("Stop this project's work and keep or close its sides before changing its folders.") }
    }

    /// Stops the workspace host so the next chat reopens it with the new root set. Sessions are re-opened lazily.
    func restartWorkspaceHost(_ workspaceID: String) async throws {
        cancelIdle(workspaceID: workspaceID)
        if let host = hosts[workspaceID] {
            try await host.shutdownAndWait()
            hosts.removeValue(forKey: workspaceID)
        }
        opened.subtract(chats.filter { $0.workspaceID == workspaceID }.map(\.id))
        for chat in chats where chat.workspaceID == workspaceID { displays[chat.id]?.captureAvailable = false; displays[chat.id]?.notice = "Project folders changed · Host reopens on the next message" }
    }

    func addFolders(_ folders: [String], to workspaceID: String) async throws {
        try await ensureConfiguration()
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { throw HostError.failure("This project is no longer configured.") }
        try requireIdle(workspaceID)
        workspaceChangesInFlight.insert(workspaceID)
        defer { workspaceChangesInFlight.remove(workspaceID) }
        guard folders.allSatisfy({ $0.hasPrefix("/") }) else { throw HostError.failure("Project folders must be absolute paths.") }
        let additions = folders.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }.filter { !workspace.roots.contains($0) }
        guard !additions.isEmpty else { throw HostError.failure("Those folders are already part of this project.") }
        try Self.validateRoots(workspace.roots + additions)
        try await updateConfiguration { config in
            guard let index = config.workspaces.firstIndex(where: { $0.id == workspaceID }) else { throw HostError.failure("This project is no longer configured.") }
            let current = config.workspaces[index].roots
            config.workspaces[index].paths += additions.filter { !current.contains($0) }
        }
        try await restartWorkspaceHost(workspaceID)
    }

    func removeFolder(_ folder: String, from workspaceID: String) async throws {
        try await ensureConfiguration()
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { throw HostError.failure("This project is no longer configured.") }
        guard folder != workspace.path else { throw HostError.failure("The primary folder names the project and cannot be removed. Remove the project instead.") }
        guard workspace.paths.contains(folder) else { throw HostError.failure("That folder is not part of this project.") }
        try requireIdle(workspaceID)
        workspaceChangesInFlight.insert(workspaceID)
        defer { workspaceChangesInFlight.remove(workspaceID) }
        try await updateConfiguration { config in
            guard let index = config.workspaces.firstIndex(where: { $0.id == workspaceID }) else { throw HostError.failure("This project is no longer configured.") }
            config.workspaces[index].paths.removeAll { $0 == folder }
        }
        try await restartWorkspaceHost(workspaceID)
    }

    /// Creates (or re-trusts) a workspace whose primary folder is `primary`. Trust must already be confirmed by the caller.
    @discardableResult
    func createWorkspace(primary: String, extras: [String] = []) async throws -> WorkspaceRecord {
        try await ensureConfiguration()
        guard ([primary] + extras).allSatisfy({ $0.hasPrefix("/") }) else { throw HostError.failure("Project folders must be absolute paths.") }
        let root = URL(fileURLWithPath: primary).resolvingSymlinksInPath().path
        var seen: Set<String> = [root]
        let paths = extras.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }.filter { seen.insert($0).inserted }
        try Self.validateRoots([root] + paths)
        let existing = workspaces.first { $0.path == root }
        let workspace = WorkspaceRecord(id: existing?.id ?? UUID().uuidString, path: root, trusted: true, paths: paths)
        if let existing { try requireIdle(existing.id) }
        workspaceChangesInFlight.insert(workspace.id)
        defer { workspaceChangesInFlight.remove(workspace.id) }
        try await updateConfiguration { config in
            if let index = config.workspaces.firstIndex(where: { $0.id == workspace.id }) { config.workspaces[index] = workspace }
            else { config.workspaces.append(workspace) }
        }
        if let existing, existing.paths != paths { try await restartWorkspaceHost(existing.id) }
        selectedWorkspaceID = workspace.id
        return workspace
    }

    /// Removes a workspace that has no chats. Its state directory is left in place for manual cleanup.
    func removeWorkspace(_ workspaceID: String) async throws {
        try await ensureConfiguration()
        guard workspaces.contains(where: { $0.id == workspaceID }) else { throw HostError.failure("This project is no longer configured.") }
        let count = chatCount(workspaceID: workspaceID)
        guard count == 0 else { throw HostError.failure("Delete its \(count == 1 ? "chat" : "\(count) chats") before removing this project.") }
        guard topics(in: workspaceID).isEmpty else { throw HostError.failure("Remove this project's topics before removing the project. Removing a topic keeps its chats.") }
        guard topicOperationsInFlight == 0, !organizationScheduler.inFlight else { throw HostError.failure("Wait for topic changes to finish before removing the project.") }
        try requireIdle(workspaceID)
        workspaceChangesInFlight.insert(workspaceID)
        defer { workspaceChangesInFlight.remove(workspaceID) }
        try await restartWorkspaceHost(workspaceID)
        try await updateConfiguration { config in
            config.workspaces.removeAll { $0.id == workspaceID }
            config.resources.removeValue(forKey: workspaceID); config.mcp.removeValue(forKey: workspaceID)
        }
        TerminalRegistry.shared.close(workspaceID: workspaceID)
        if selectedWorkspaceID == workspaceID { selectedWorkspaceID = workspaces.first?.id }
    }

    /// Open panel + durable update, for the manager sheet and onboarding.
    func addFoldersInteractively(to workspaceID: String) async throws {
        let folders = await Self.chooseFolders(message: "Choose additional folders for this project.", multiple: true)
        guard !folders.isEmpty else { return }
        try await addFolders(folders, to: workspaceID)
    }
}
