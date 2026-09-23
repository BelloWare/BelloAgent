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
        let target = sessionID ?? resourceTargetSessionID ?? selectedID
        let item = target.flatMap(record)
        let workspaceID = item?.workspaceID ?? selectedWorkspaceID
        guard !installPreparing, let workspace = workspaces.first(where: { $0.id == workspaceID && $0.trusted }) else { throw HostError.failure("Choose a trusted project first") }
        let host = try await host(for: workspace)
        defer { scheduleIdle(workspaceID: workspace.id, host: host) }
        var params = params
        // An unopened session still has a deliberate tool mode. Discovery must
        // not borrow the editing capabilities of another pane or open a run.
        if method == "resources.inspect", let item { params["readOnly"] = .bool(item.toolMode == "read-only") }
        return try await host.request(method, sessionID: target, params: params).object ?? [:]
    }
    func saveResourceSettings(_ options: [String: WireValue], sessionID: String? = nil) async throws {
        guard let id = sessionID.flatMap(record)?.workspaceID ?? selectedWorkspaceID else { throw StoreError.invalidRecord }
        try await updateConfiguration { $0.resources[id] = .object(options) }
        do { _ = try await resourceRequest("resources.configure", params: ["options": try await resourceSettings(workspaceID:id)], sessionID: sessionID) }
        catch { hosts[id]?.shutdown(); throw error }
        await loadSkillCatalog(refresh: true, sessionID: sessionID)
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
            for view in displays.values {
                view.skillCatalog.state = .loading
                view.skillCatalog.notice = "Skill policy changed. Refresh before selecting."
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
    func skillScope(sessionID: String?, workspaceID: String) -> String {
        let host = hosts[workspaceID]
        return [workspaceID, sessionID ?? "", String(configuration.revision),
                sessionID.flatMap(record)?.toolMode ?? "editing", host?.connectionID?.uuidString ?? "", host?.epoch ?? ""].joined(separator: "|")
    }
    func loadSkillCatalog(refresh: Bool = false, sessionID: String? = nil,
                          readPage: (@MainActor ([String: WireValue], String?) async throws -> [String: WireValue])? = nil) async {
        let target = sessionID ?? resourceTargetSessionID ?? selectedID
        guard let workspaceID = target.flatMap(record)?.workspaceID ?? selectedWorkspaceID else { return }
        let key = target ?? "project:" + workspaceID, scope = skillScope(sessionID: target, workspaceID: workspaceID)
        if let pending = skillCatalogLoads[key], pending.scope == scope { await pending.task.value; return }
        if !refresh, let view = target.flatMap({ displays[$0] }), view.skillCatalog.authorizes, view.skillCatalog.scope == scope { return }
        skillCatalogLoads[key]?.task.cancel()
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.discoverSkills(target: target, workspaceID: workspaceID, key: key, token: token, refresh: refresh, readPage: readPage)
        }
        skillCatalogLoads[key] = (token, scope, task)
        await task.value
        if skillCatalogLoads[key]?.token == token { skillCatalogLoads.removeValue(forKey: key) }
    }
    private func discoverSkills(target: String?, workspaceID: String, key: String, token: UUID, refresh: Bool,
                                readPage: (@MainActor ([String: WireValue], String?) async throws -> [String: WireValue])?) async {
        func owns() -> Bool { skillCatalogLoads[key]?.token == token && !Task.isCancelled }
        func publish(_ catalog: SkillCatalog) {
            guard owns() else { return }
            if let target, let view = displays[target] { view.skillCatalog = catalog; updateCompletionSelection(view) }
            if (resourceTargetSessionID ?? selectedID) == target && selectedWorkspaceID == workspaceID {
                resourceLoading = catalog.state == .loading; resourceNotice = catalog.notice
                if catalog.authorizes {
                    resourceCatalog = catalog.entries.map(\.skill); resourceCatalogWorkspaceID = workspaceID; resourceCatalogSessionID = target
                }
            }
        }
        var catalog = target.flatMap { displays[$0]?.skillCatalog } ?? SkillCatalog()
        catalog.state = .loading; catalog.notice = catalog.entries.isEmpty ? "Discovering skills…" : "Refreshing skills · previous results unavailable for selection"
        publish(catalog)
        do {
            try await ensureConfiguration()
            if readPage == nil {
                guard let workspace = workspace(for: workspaceID) else { throw HostError.failure("The originating project is unavailable.") }
                _ = try await host(for: workspace)
            }
            let scope = skillScope(sessionID: target, workspaceID: workspaceID), settings = configuration.revision
            if owns() { skillCatalogLoads[key]?.scope = scope }
            var revision: String?, seen = Set<String>(), cursors = Set<Int>(), collected: [SkillDescriptor] = [], diagnostics: [String] = [], offset = 0
            var expectedTotal: Int?
            while true {
                try Task.checkCancellation()
                guard owns() else { return }
                guard cursors.insert(offset).inserted else { throw HostError.failure("Skill discovery repeated a page. Retry discovery.") }
                let params: [String: WireValue] = ["refresh": .bool(refresh && offset == 0), "offset": .number(Double(offset))]
                let page: [String: WireValue]
                if let readPage { page = try await readPage(params, target) }
                else { page = try await resourceRequest(params: params, sessionID: target) }
                guard owns() else { return }
                guard configuration.revision == settings else { throw HostError.failure("Discovery settings changed while loading skills. Refresh the skill list.") }
                guard scope == skillScope(sessionID: target, workspaceID: workspaceID) else { throw HostError.failure("The originating session or host changed. Refresh the skill list.") }
                guard let current = page["revision"]?.string, revision == nil || revision == current else { throw HostError.failure("Skill sources changed while loading. Retry discovery.") }
                revision = current
                let values = try JSONDecoder().decode([SkillDescriptor].self, from: JSONEncoder().encode(page["skills"] ?? .array([])))
                guard values.allSatisfy({ seen.insert($0.id).inserted }) else { throw HostError.failure("Skill discovery returned duplicate identities. Retry discovery.") }
                collected += values
                diagnostics += page["diagnostics"]?.array?.compactMap(\.string) ?? []
                let total = page["total"]?.nonnegativeInteger ?? collected.count
                guard expectedTotal == nil || expectedTotal == total, total >= collected.count else { throw HostError.failure("Skill discovery returned an inconsistent total. Retry discovery.") }
                expectedTotal = total
                if let next = page["next"], next != .null, next.nonnegativeInteger == nil { throw HostError.failure("Skill discovery returned an invalid page cursor. Retry discovery.") }
                if let next = page["next"]?.nonnegativeInteger {
                    guard next > offset, next == collected.count, !values.isEmpty else { throw HostError.failure("Skill discovery did not advance. Retry discovery.") }
                    if collected.count >= 512 { diagnostics.append("Discovery limited to 512 skills. Refine discovery settings to include other sources."); break }
                    offset = next
                } else {
                    guard total == collected.count else { throw HostError.failure("Skill discovery ended before all results arrived. Retry discovery.") }
                    break
                }
            }
            catalog = SkillCatalog(state: diagnostics.isEmpty ? .ready : .partial, scope: scope, revision: revision ?? "",
                                   entries: collected.prefix(512).map(SkillSearch.Entry.init), notice: Array(Set(diagnostics)).sorted().joined(separator: "\n"))
            publish(catalog)
        } catch {
            guard owns() else { return }
            catalog.state = .failed; catalog.notice = error.localizedDescription
            publish(catalog)
        }
    }
    func composerMoved(_ location: ComposerLocation, editor: ComposerTextView, view: SessionDisplay) {
        guard location.sessionID == view.id else { return }
        view.composerEditor = editor; view.composerLocation = location
        view.completionParse?.cancel()
        guard let token = SlashCompletionToken.local(in: editor.string as NSString, at: location, directInput: view.directCommand) else {
            view.completionToken = nil; if view.completionVisible { view.completionVisible = false }; return
        }
        func apply(_ outside: Bool) {
            view.completionToken = outside ? token : nil
            if view.completionVisible != outside { view.completionVisible = outside }
            if outside { updateCompletionSelection(view); Task { await loadSkillCatalog(sessionID: view.id) } }
        }
        if let cached = view.codeClassification, cached.generation == location.editorGeneration, cached.revision == location.draftRevision, cached.offset == token.replacementRangeUTF16.location { apply(cached.outside); return }
        // Classify immutable native-owned draft off the UI actor, only after
        // the local 64-character token passed. Late results cannot authorize.
        let text = view.draft
        view.completionToken = nil; if view.completionVisible { view.completionVisible = false }
        view.completionParse = Task { [weak view] in
            let work = Task.detached(priority: .userInitiated) { SlashCompletionToken.outsideCode(text, before: token.replacementRangeUTF16.location) }
            let outside = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let view, !Task.isCancelled, view.composerLocation == location, view.draft == text else { return }
            view.codeClassification = (location.editorGeneration, location.draftRevision, token.replacementRangeUTF16.location, outside)
            apply(outside)
        }
    }
    func commandChanged(_ view: SessionDisplay) {
        // Actual native selection notifications carry the authoritative caret.
        if let editor = view.composerEditor, let location = editor.completionLocation { composerMoved(location, editor: editor, view: view) }
    }
    func completions(_ view: SessionDisplay) -> [CommandCompletion] {
        guard view.completionVisible, let token = view.completionToken else { return [] }
        let builtins = token.wholeMessageCommandEligible ? LeadingCommand.reserved.filter { $0.hasPrefix(token.query.lowercased()) }.map { CommandCompletion(id: "builtin:" + $0, name: $0, detail: "Built-in command", skill: nil) } : []
        let skills = view.skillCatalog.authorizes ? SkillSearch.search(view.skillCatalog.entries, query: token.query, actionable: true).map {
            CommandCompletion(id: $0.id, name: $0.name, detail: $0.scope + " · " + $0.path, skill: $0)
        } : []
        return builtins + skills
    }
    func updateCompletionSelection(_ view: SessionDisplay) {
        let choices = completions(view)
        let id = choices.contains(where: { $0.id == view.completionSelectionID }) ? view.completionSelectionID : choices.first?.id
        if view.completionSelectionID != id { view.completionSelectionID = id }
    }
    func completionKey(_ key: UInt16, modifiers: NSEvent.ModifierFlags = [], view: SessionDisplay) -> Bool {
        guard modifiers.intersection([.command, .shift, .option, .control]).isEmpty else { return false }
        let choices = completions(view); guard view.completionVisible else { return false }
        if key == 53 { view.completionVisible = false; view.completionParse?.cancel(); return true }
        if [36, 76].contains(key), choices.first(where: { $0.id == view.completionSelectionID })?.skill == nil,
           view.completionToken?.wholeMessageCommandEligible == true,
           let command = LeadingCommand.parse(view.draft, directInput: view.directCommand), ["side", "fork"].contains(command.name), command.arguments.isEmpty {
            return resolveLeadingCommand(view, steer: false)
        }
        guard !choices.isEmpty else { return [48, 36, 76].contains(key) }
        let index = choices.firstIndex { $0.id == view.completionSelectionID } ?? 0
        if key == 125 || key == 126 { view.completionSelectionID = choices[(index + (key == 125 ? 1 : choices.count - 1)) % choices.count].id; return true }
        if [48, 36, 76].contains(key) { chooseCompletion(choices[index], view: view); return true }
        return false
    }
    func chooseCompletion(_ choice: CommandCompletion, view: SessionDisplay) {
        guard let token = view.completionToken, let editor = view.composerEditor,
              editor.completionLocation == token.location, editor.selectedRange() == token.location.selectedRangeUTF16,
              !editor.hasMarkedText(), view.composerLocation == token.location,
              SlashCompletionToken.local(in: editor.string as NSString, at: token.location, directInput: view.directCommand) == token,
              NativeComposer.Coordinator.contents(of: editor) == view.draft else { view.notice = "The draft changed. Select the skill again."; return }
        if let skill = choice.skill {
            guard let workspaceID = record(view.id)?.workspaceID, view.skillCatalog.scope == skillScope(sessionID: view.id, workspaceID: workspaceID),
                  view.skillCatalog.authorizes, view.skillCatalog.entries.contains(where: { $0.skill.id == skill.id && $0.skill.contentHash == skill.contentHash && $0.skill.metadataHash == skill.metadataHash }),
                  skillEnabledInBelloAgent(skill.id), skill.canSelect else { view.notice = "The skill changed or is unavailable. Refresh and select it again."; return }
            guard view.skills.count < 8, !view.skills.contains(where: { $0.id == skill.id }) else { view.notice = "This skill is already selected, or the eight-skill limit has been reached."; return }
            editor.replaceCompletion(range: token.replacementRangeUTF16, with: "", skills: view.skills + [skill.chip], display: view) { [weak self, weak view] in
                if let view { self?.draftChanged(view) }
            }
        } else if token.wholeMessageCommandEligible {
            editor.insertText("/" + choice.name + " ", replacementRange: token.replacementRangeUTF16); view.directCommand = true
        }
        view.completionVisible = false; view.completionToken = nil; view.completionParse?.cancel()
    }
    func canSelectSkill(_ skill: SkillDescriptor, view: SessionDisplay) -> Bool {
        guard let workspaceID = record(view.id)?.workspaceID, skillEnabledInBelloAgent(skill.id), skill.canSelect,
              view.skillCatalog.authorizes, view.skillCatalog.scope == skillScope(sessionID: view.id, workspaceID: workspaceID) else { return false }
        return view.skillCatalog.entries.contains { $0.skill.id == skill.id && $0.skill.canSelect && $0.skill.contentHash == skill.contentHash && $0.skill.metadataHash == skill.metadataHash }
    }
    @discardableResult func addSkill(_ skill: SkillDescriptor, view: SessionDisplay, fromCommand: Bool = false) -> Bool {
        guard canSelectSkill(skill, view: view) else { view.notice = "This skill needs a fresh catalog. Refresh and select it again."; return false }
        guard view.skills.count < 8, !view.skills.contains(where: { $0.id == skill.id }) else { view.notice = "This skill is already selected, or the eight-skill limit has been reached."; return false }
        var chip = skill.chip
        if fromCommand { chip.intent = "leading-command"; chip.arguments = LeadingCommand.parse(view.draft, directInput: view.directCommand)?.arguments ?? ""; view.draft = "" }
        view.skills.append(chip); view.directCommand = false; view.completionVisible = false; draftChanged(view)
        return true
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
            if command.name == "compact" {
                // Pi's /compact [instructions]: the running turn stops first and
                // the text after the command is the summary's focus.
                let focus = command.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
                view.draft = ""; view.directCommand = false; draftChanged(view)
                action("context.compact", params: focus.isEmpty ? [:] : ["focus": .string(focus)], sessionID: view.id); return true
            }
            guard command.arguments.isEmpty, !steer else { error = "This built-in command takes no arguments and cannot steer a running turn."; return true }
            if command.name == "debug" { inspect(view.id) }
            view.draft = ""; view.directCommand = false; draftChanged(view); return true
        }
        guard let workspaceID = record(view.id)?.workspaceID, view.skillCatalog.authorizes,
              view.skillCatalog.scope == skillScope(sessionID: view.id, workspaceID: workspaceID) else {
            view.notice = "Skills need refreshing. Select the skill or press Send again when discovery finishes."
            Task { await loadSkillCatalog(sessionID: view.id) }; return true
        }
        let matches = view.skillCatalog.entries.map(\.skill).filter { $0.name == command.name && $0.canSelect }
        guard matches.count == 1 else { inspectResources(view.id); resourceNotice = matches.isEmpty ? "Skill unavailable. Review its policy or dependencies." : "Duplicate name. Select the intended canonical path."; return true }
        guard view.skills.count < 8, !view.skills.contains(where: { $0.id == matches[0].id }) else { error = "This skill is already selected, or the eight-skill limit has been reached. Edit the existing chip or remove one."; return true }
        guard addSkill(matches[0], view: view, fromCommand: true) else { return true }
        // Continue the same explicit Send action with the resolved structured chip.
        send(steer: steer, sessionID: view.id); return true
    }
    func editSkillArguments(_ chip: SkillChip, view: SessionDisplay) {
        if !questions.askText("Arguments for /\(chip.name)", value: chip.arguments, action: "Save Arguments", limit: 16384, about: view.id, entered: { [weak self] text in
            guard let self, let index = view.skills.firstIndex(where: { $0.id == chip.id }) else { return }
            view.skills[index].arguments = text
            self.draftChanged(view)
        }) { view.notice = PiQuestion.busyNotice }
    }
}
