import SwiftUI
import AppKit

struct CommandCompletion: Identifiable {
    var id: String; var name: String; var detail: String; var skill: SkillDescriptor?
}
extension WorkspaceModel {
    func editableResourceSettings(workspaceID: String) async throws -> [String: WireValue] {
        try await ensureConfiguration()
        return configuration.resources[workspaceID]?.object ?? ["codexHome":.string(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)]
    }
    func resourceSettings(workspaceID: String) async throws -> WireValue {
        try await ensureConfiguration()
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        return .object(configuration.resourceOptions(workspaceID:workspaceID,defaultCodexHome:home))
    }

    func resourceRequest(_ method: String = "resources.inspect", params: [String: WireValue] = [:], sessionID: String? = nil) async throws -> [String: WireValue] {
        guard !installPreparing, let workspace = workspaces.first(where: { $0.id == selectedWorkspaceID && $0.trusted }) else { throw HostError.failure("Choose a trusted project first") }
        let host = try await host(for: workspace)
        defer { scheduleIdle(workspaceID: workspace.id, host: host) }
        return try await host.request(method, sessionID: sessionID ?? resourceTargetSessionID ?? selectedID, params: params).object ?? [:]
    }
    func saveResourceSettings(_ options: [String: WireValue]) async throws {
        guard let id = selectedWorkspaceID else { throw StoreError.invalidRecord }
        try await updateConfiguration { $0.resources[id] = .object(options) }
        do { _ = try await resourceRequest("resources.configure", params: ["options": try await resourceSettings(workspaceID:id)]) }
        catch { hosts[id]?.shutdown(); throw error }
        await loadSkillCatalog(refresh: true)
    }
    func skillEnabledInBelloAgent(_ id: String) -> Bool { !(configuration.disabledSkills ?? []).contains(id) }
    func setSkillEnabledInBelloAgent(_ skill: SkillDescriptor, enabled: Bool) async throws {
        let id = skill.id
        try await updateConfiguration { saved in
            var disabled = Set(saved.disabledSkills ?? [])
            if enabled { disabled.remove(id) } else { disabled.insert(id) }
            saved.disabledSkills = disabled.sorted()
        }
        // Drop disabled draft selections so a previously saved chip cannot be
        // sent after its app policy changed. Already running requests retain
        // their frozen inputs; queued selections are revalidated by the helper.
        if !enabled {
            resourceCatalog = resourceCatalog.map { value in
                guard value.id == id else { return value }
                var disabled = value; disabled.policy = "disabled"; return disabled
            }
            for view in displays.values where view.skills.contains(where:{ $0.id == id }) {
                view.skills.removeAll { $0.id == id }; draftChanged(view)
            }
        }
        var firstFailure: Error?
        for (workspaceID, host) in hosts where host.isReady {
            do { _ = try await host.request("resources.configure",params:["options":try await resourceSettings(workspaceID:workspaceID)]) }
            catch {
                // Do not leave a helper advertising a now-disabled skill.
                host.shutdown(); if firstFailure == nil { firstFailure = error }
            }
        }
        resourceCatalogWorkspaceID = nil
        if selectedWorkspaceID != nil { await loadSkillCatalog(refresh:true) }
        if let firstFailure { throw firstFailure }
    }
    func loadSkillCatalog(refresh: Bool = false, sessionID: String? = nil,
                          readPage: (@MainActor ([String: WireValue], String?) async throws -> [String: WireValue])? = nil) async {
        guard let workspaceID = selectedWorkspaceID, !resourceLoading else { return }
        let target = sessionID ?? resourceTargetSessionID ?? selectedID
        if !refresh && resourceCatalogWorkspaceID == workspaceID && resourceCatalogSessionID == target { return }
        resourceLoading = true; defer { resourceLoading = false }
        do {
            try await ensureConfiguration()
            let settingsRevision = configuration.revision
            var catalogRevision: String?
            var collected: [SkillDescriptor] = [], offset: Double = 0
            repeat {
                let params: [String: WireValue] = ["refresh":.bool(refresh && offset == 0),"offset":.number(offset)]
                let page: [String: WireValue]
                if let readPage { page = try await readPage(params,target) }
                else { page = try await resourceRequest(params:params,sessionID:target) }
                guard settingsRevision == configuration.revision else { throw HostError.failure("Discovery settings changed while loading skills. Refresh the skill list.") }
                if let catalogRevision, catalogRevision != page["revision"]?.string { throw HostError.failure("Skill sources changed while loading. Refresh the skill list.") }
                catalogRevision = page["revision"]?.string
                if let values = page["skills"] { collected += try JSONDecoder().decode([SkillDescriptor].self, from: JSONEncoder().encode(values)) }
                offset = page["next"]?.number ?? -1
                resourceNotice = page["diagnostics"]?.array?.compactMap(\.string).joined(separator: "\n") ?? ""
            } while offset >= 0 && collected.count < 512 && workspaceID == selectedWorkspaceID
            guard workspaceID == selectedWorkspaceID, settingsRevision == configuration.revision else { return }
            resourceCatalog = Array(collected.prefix(512)); resourceCatalogWorkspaceID = workspaceID; resourceCatalogSessionID = target
        } catch { resourceNotice = error.localizedDescription }
    }
    func commandChanged(_ view: SessionDisplay) {
        if view.completionIndex != 0 { view.completionIndex = 0 }
        let visible = view.directCommand && view.draft.hasPrefix("/") && !view.draft.contains(where: \.isWhitespace)
        if view.completionVisible != visible { view.completionVisible = visible }
        if view.completionVisible { view.objectWillChange.send(); Task { await loadSkillCatalog(sessionID: view.id) } }
    }
    func completions(_ view: SessionDisplay) -> [CommandCompletion] {
        guard view.completionVisible else { return [] }
        let prefix = String(view.draft.dropFirst()).lowercased()
        let builtins = LeadingCommand.reserved.filter { $0.hasPrefix(prefix) }.map { CommandCompletion(id: "builtin:" + $0, name: $0, detail: "Built-in command", skill: nil) }
        let skills = resourceCatalogWorkspaceID == selectedWorkspaceID && resourceCatalogSessionID == view.id ? resourceCatalog.filter { $0.canSelect && $0.name.lowercased().hasPrefix(prefix) }.map { CommandCompletion(id: $0.id, name: $0.name, detail: $0.scope + " · " + $0.path + " · " + $0.policy, skill: $0) } : []
        return Array((builtins + skills).prefix(8))
    }
    func completionKey(_ key: UInt16, view: SessionDisplay) -> Bool {
        let choices = completions(view); guard view.completionVisible else { return false }
        if key == 53 { view.completionVisible = false; return true }
        if [36, 76].contains(key), let command = LeadingCommand.parse(view.draft, directInput: view.directCommand),
           ["side", "fork"].contains(command.name), command.arguments.isEmpty {
            // Exact structural commands execute on the first Return. Tab and
            // partial completion still insert the command without sending text.
            return resolveLeadingCommand(view, steer: false)
        }
        guard !choices.isEmpty else { return false }
        if key == 125 || key == 126 { view.completionIndex = (view.completionIndex + (key == 125 ? 1 : choices.count - 1)) % choices.count; return true }
        if key == 48 || key == 36 || key == 76 { chooseCompletion(choices[min(view.completionIndex, choices.count - 1)], view: view); return true }
        return false
    }
    func chooseCompletion(_ choice: CommandCompletion, view: SessionDisplay) {
        view.completionVisible = false
        if let skill = choice.skill { addSkill(skill, view: view, fromCommand: true) }
        else { view.draft = "/" + choice.name + " "; view.directCommand = true }
    }
    func addSkill(_ skill: SkillDescriptor, view: SessionDisplay, fromCommand: Bool = false) {
        guard skillEnabledInBelloAgent(skill.id), skill.canSelect, view.skills.count < 8, !view.skills.contains(where: { $0.id == skill.id }) else { return }
        var chip = skill.chip
        if fromCommand { chip.intent = "leading-command"; chip.arguments = LeadingCommand.parse(view.draft, directInput: view.directCommand)?.arguments ?? ""; view.draft = "" }
        view.skills.append(chip); view.directCommand = false; view.completionVisible = false; draftChanged(view)
    }
    func resolveLeadingCommand(_ view: SessionDisplay, steer: Bool) -> Bool {
        guard let command = LeadingCommand.parse(view.draft, directInput: view.directCommand) else { return false }
        view.completionVisible = false
        if LeadingCommand.reserved.contains(command.name) {
            if command.name == "side" {
                guard !steer, side(view.id) == nil else { error = "A side command opens from the main chat and cannot steer a run."; return true }
                guard canOpenSide(view.id) else { error = "Side chats require a project conversation with tools available."; return true }
                view.draft = ""; view.directCommand = false; draftChanged(view)
                openSide(parentID: view.id, question: command.arguments); return true
            }
            if command.name == "fork" {
                guard !steer, command.arguments.isEmpty else { error = "The fork command takes no arguments and cannot steer a run."; return true }
                view.draft = ""; view.directCommand = false; draftChanged(view)
                forkSession(view.id); return true
            }
            guard command.arguments.isEmpty, !steer else { error = "This built-in command takes no arguments and cannot steer a running turn."; return true }
            if command.name == "debug" { inspect(view.id) }
            if command.name == "compact" { action("context.compact", sessionID: view.id) }
            view.draft = ""; view.directCommand = false; draftChanged(view); return true
        }
        guard resourceCatalogWorkspaceID == selectedWorkspaceID && resourceCatalogSessionID == view.id else {
            Task { await loadSkillCatalog(sessionID: view.id); if resourceCatalogWorkspaceID == selectedWorkspaceID && resourceCatalogSessionID == view.id { send(steer: steer, sessionID: view.id) } else { error = resourceLoading ? "Skills are still loading. Try Send when discovery finishes." : resourceNotice } }; return true
        }
        let matches = resourceCatalog.filter { $0.name == command.name && $0.canSelect }
        guard matches.count == 1 else { inspectResources(view.id); resourceNotice = matches.isEmpty ? "Skill unavailable. Review its policy or dependencies." : "Duplicate name. Select the intended canonical path."; return true }
        guard view.skills.count < 8, !view.skills.contains(where: { $0.id == matches[0].id }) else { error = "This skill is already selected, or the eight-skill limit has been reached. Edit the existing chip or remove one."; return true }
        addSkill(matches[0], view: view, fromCommand: true)
        // Continue the same explicit Send action with the resolved structured chip.
        send(steer: steer, sessionID: view.id); return true
    }
    func editSkillArguments(_ chip: SkillChip, view: SessionDisplay) {
        let alert = NSAlert(); alert.messageText = "Arguments for /\(chip.name)"
        let field = NSTextField(string: chip.arguments); field.frame = NSRect(x: 0, y: 0, width: 480, height: 28); alert.accessoryView = field
        alert.addButton(withTitle: "Save Arguments"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, field.stringValue.utf8.count <= 16384, let index = view.skills.firstIndex(where: { $0.id == chip.id }) { view.skills[index].arguments = field.stringValue; draftChanged(view) }
    }
}
