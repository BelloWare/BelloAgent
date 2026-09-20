import SwiftUI
import AppKit

@MainActor
struct ResourceInspector: View {
    @ObservedObject var model: WorkspaceModel
    @State private var tab = "skills"
    @State private var query = ""
    @State private var management = false
    @State private var selectedID = ""
    @State private var detail = ""
    @State private var bodyOffset = 0
    @State private var nextBody: Double?
    @State private var snapshot: [String: WireValue] = [:]
    @State private var sourceOffset = 0
    @State private var options: [String: WireValue] = [:]
    @State private var home = ""
    @State private var fallbacks = ""
    @State private var byteLimit = 32768
    @State private var overrideBudget = false
    @State private var notice = ""
    @State private var policyBusy = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PiSheet("Skills, instructions and MCP", subtitle: "Discovered skills, the applied instruction chain, discovery settings and MCP servers for the selected project.", symbol: "book.closed", width: 1100, height: 800) {
            VStack(alignment: .leading, spacing: PiSpacing.md) {
                PiTabs(selection: $tab, items: [("skills", "Skills"), ("instructions", "Instruction chain"), ("settings", "Discovery settings"), ("mcp", "MCP servers")])
                if tab == "skills" { skillsView }
                if tab == "instructions" { instructionsView }
                if tab == "settings" { settingsView }
                if tab == "mcp" { NativeMCPInspector(model: model) }
            }
            .padding(PiSpacing.xl)
        } actions: {
            Button { Task { await refresh() } } label: { Label("Refresh Sources", systemImage: "arrow.clockwise") }
            Button("Done") { dismiss() }
        } footer: {
            if tab != "mcp" {
                VStack(alignment: .leading, spacing: 4) {
                    PiStatusLine(text: notice.isEmpty ? model.resourceNotice : notice)
                    Text("Skill switches apply only to Bello Agent across all projects. Shared skill files and Codex settings are never changed. Running requests retain their frozen inputs; new and queued turns use the updated policy.").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                }
            } else {
                Text("Configuration can launch programs with your permissions. Invocation requires an editing chat and is serialized per project. Read-only chats can discover tools but cannot invoke them. Annotations are not authorization.").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
            }
        }
        .task { await loadOptions(); await refresh() }
        .onChange(of: selectedID) { _, _ in bodyOffset = 0; loadBody() }
        .onChange(of: tab) { _, value in if value == "settings" { Task { await loadOptions() } } }
    }
    private var selected: SkillDescriptor? { model.resourceCatalog.first { $0.id == selectedID } }
    /// Read from `body`, so it runs on every keystroke. Concatenating three
    /// strings per catalog entry and running a locale-aware search over the
    /// result made the filter field lag on a large catalog.
    private var filtered: [SkillDescriptor] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return model.resourceCatalog.filter {
            guard management || !["disabled", "needsAttention"].contains($0.policy) else { return false }
            guard !needle.isEmpty else { return true }
            return $0.name.range(of: needle, options: options) != nil
                || $0.path.range(of: needle, options: options) != nil
                || $0.description.range(of: needle, options: options) != nil
        }
    }
    private static func policyTone(_ policy: String) -> PiTone {
        switch policy {
        case "implicitAllowed": return .success
        case "explicitOnly": return .info
        case "disabled": return .neutral
        case "needsAttention": return .warning
        default: return .neutral
        }
    }
    /// The wire policy names are Codex's own (`implicitAllowed`,
    /// `explicitOnly`). They were reaching the badge unchanged, so a reader
    /// was told a skill was "explicitOnly" rather than what that means for
    /// them: the model will only use it when they name it with a slash.
    static func policyLabel(_ policy: String) -> String {
        switch policy {
        case "implicitAllowed": return "Model may use it"
        case "explicitOnly": return "Only when you ask"
        case "disabled": return "Off"
        case "needsAttention": return "Needs attention"
        default: return policy.isEmpty ? "" : policy.prefix(1).uppercased() + policy.dropFirst()
        }
    }
    private var skillsView: some View {
        VStack(spacing: PiSpacing.sm) {
            HStack(spacing: PiSpacing.md) {
                PiTextField(placeholder: "Filter by name, description or path", text: $query, icon: "magnifyingglass")
                Toggle("Show disabled / needs attention", isOn: $management).toggleStyle(.checkbox).font(PiFont.caption)
            }
            HSplitView {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { skill in
                            PiSelectableRow(selected: selectedID == skill.id, action: { selectedID = skill.id }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("/" + skill.name).font(PiFont.heading).foregroundStyle(Color.piInk)
                                    HStack(spacing: 4) {
                                        PiBadge(text: Self.policyLabel(skill.policy), tone: Self.policyTone(skill.policy)).help("Skill policy · " + skill.policy)
                                        PiBadge(text: skill.scope)
                                    }
                                    Text(skill.path).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                    }.padding(PiSpacing.sm)
                }
                .overlay { if filtered.isEmpty { Text(model.resourceLoading ? "Discovering skills…" : "No skills match").font(PiFont.caption).foregroundStyle(Color.piInkTertiary) } }
                .piInset().frame(minWidth: 290, idealWidth: 340, maxWidth: 430).padding(.trailing, PiSpacing.sm)
                VStack(alignment: .leading, spacing: PiSpacing.sm) {
                    if let skill = selected {
                        PiCard(padding: PiSpacing.md) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(skill.description.isEmpty ? "No description" : skill.description).font(PiFont.body).foregroundStyle(Color.piInk)
                                PiKeyValue(key: "Path", value: skill.path, mono: true)
                                PiKeyValue(key: "SHA-256", value: skill.contentHash, mono: true)
                                Toggle("Enabled in Bello Agent",isOn:Binding(get:{ model.skillEnabledInBelloAgent(skill.id) },set:{ enabled in setEnabled(skill,enabled:enabled) }))
                                    .toggleStyle(.switch).disabled(policyBusy)
                                    .help("Applies across Bello Agent projects. Enabling does not override Codex or project restrictions.")
                                Text("Other source and project restrictions still apply. A disabled skill is removed from suggestions and unsent selections.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                                if !skill.reasons.isEmpty { PiKeyValue(key: "Policy reasons", value: skill.reasons.joined(separator: "\n")) }
                                if !skill.missingDependencies.isEmpty {
                                    PiNote("Unavailable dependencies: " + skill.missingDependencies.map { ($0["type"] ?? "") + ":" + ($0["value"] ?? "") }.joined(separator: ", "), tone: .warning)
                                }
                                HStack(spacing: PiSpacing.sm) {
                                    Button {
                                        if let view = model.resourceTarget {
                                            model.addSkill(skill, view: view, fromCommand: LeadingCommand.begins(view.draft, directInput: view.directCommand)); dismiss()
                                        }
                                    } label: { Label("Select for Draft", systemImage: "plus.circle") }
                                        .buttonStyle(.piPrimary).disabled(!skill.canSelect || model.resourceTarget == nil || model.resourceTarget?.skills.count == 8)
                                    PiMenuButton(title: "Project Policy", icon: "checkmark.shield") {
                                        Button("Explicit Only") { policy(skill, key: "explicitOnly", enabled: true) }
                                        Button("Remove App Explicit-only Override") { policy(skill, key: "explicitOnly", enabled: false) }
                                        Divider()
                                        Button("Disable for This Project") { policy(skill, key: "disabled", enabled: true) }
                                        Button("Remove Project Disable Override") { policy(skill, key: "disabled", enabled: false) }
                                    }.disabled(policyBusy)
                                }.padding(.top, 2)
                            }
                        }
                    }
                    PagedTextView(text: detail).piInset()
                    PiPager(previous: { bodyOffset = 0; loadBody() }, next: { bodyOffset = Int(nextBody ?? 0); loadBody() }, canPrevious: bodyOffset != 0, canNext: nextBody != nil, previousLabel: "Start", nextLabel: "Next") {
                        Text(bodyOffset == 0 ? "Skill file · from the start" : "Skill file · continued").help("Reading the skill file from character \(bodyOffset)")
                    }
                }.frame(minWidth: 480).padding(.leading, PiSpacing.sm)
            }
        }
    }
    private var instructionsView: some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            PiCard(padding: PiSpacing.md) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Global → project root → working directory → explicitly approved additions").font(PiFont.heading)
                    PiKeyValue(key: "Root", value: snapshot["root"]?.string ?? "", mono: true)
                    PiKeyValue(key: "Codex home", value: snapshot["codexHome"]?.string ?? "", mono: true)
                    PiKeyValue(key: "Included", value: "\(snapshot["instructionBytes"]?.nonnegativeInteger.map(String.init) ?? "n/a") / \(snapshot["instructionLimit"]?.nonnegativeInteger.map(String.init) ?? "n/a") UTF-8 bytes")
                    PiKeyValue(key: "Applied revision", value: snapshot["appliedRevision"]?.string ?? "No turn yet", mono: true)
                }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array((snapshot["sources"]?.array ?? []).enumerated()), id: \.offset) { index, value in
                        InstructionSourceRow(position: sourceOffset + index + 1, source: value.object ?? [:])
                        Rectangle().fill(Color.piHairline).frame(height: 1)
                    }
                }
            }
            .overlay { if (snapshot["sources"]?.array ?? []).isEmpty { Text("No instruction sources").font(PiFont.caption).foregroundStyle(Color.piInkTertiary) } }
            .piInset()
            PiPager(previous: { sourceOffset = max(0, sourceOffset - 32); Task { await refresh() } }, next: { sourceOffset += 32; Task { await refresh() } },
                    canPrevious: sourceOffset > 0, canNext: sourceOffset + 32 < (snapshot["sourceCount"]?.nonnegativeInteger ?? 0), previousLabel: "Previous Sources", nextLabel: "Next Sources") {
                Text("\(snapshot["sourceCount"]?.nonnegativeInteger.map(String.init) ?? "n/a") sources")
            }
            PiNote("A new user turn refreshes the chain. In-flight requests retain their revision. Descendant guidance is not injected indiscriminately into unrelated directories.")
        }
    }
    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PiSpacing.xl) {
                PiSettingsGroup(title: "Discovery", footer: "Default discovery includes user and project .agents/skills. No scripts or downloads run during discovery. Arbitrary Pi extensions are not loaded.") {
                    PiRow(label: "Codex home", detail: "Absolute path") { PiTextField(placeholder: "/Users/you/.codex", text: $home, mono: true) }
                    PiRow(label: "Fallback basenames", detail: "Comma separated; blank uses config.toml") { PiTextField(placeholder: "AGENTS.md, CLAUDE.md", text: $fallbacks, mono: true) }
                    PiRow(label: "Override instruction byte budget", last: !overrideBudget) { Toggle("", isOn: $overrideBudget).labelsHidden() }
                    if overrideBudget { PiRow(label: "Combined source byte limit", detail: "0–262144", last: true) { PiNumberField(placeholder: "Bytes", value: $byteLimit) } }
                }
                ForEach(["extraSkillPaths", "piSkillPaths", "piInstructionPaths"], id: \.self) { key in
                    let paths = options[key]?.array?.compactMap(\.string) ?? []
                    PiSettingsGroup(title: key) {
                        if paths.isEmpty {
                            PiRow(label: "No approved paths", last: true) { Button("Add Approved Path…") { addPath(key) }.buttonStyle(.piSecondaryCompact) }
                        }
                        ForEach(Array(paths.enumerated()), id: \.element) { index, path in
                            PiRow(label: path, last: index == paths.count - 1) {
                                HStack(spacing: 4) {
                                    if index == paths.count - 1 { Button("Add…") { addPath(key) }.buttonStyle(.piSecondaryCompact) }
                                    PiIconButton(symbol: "minus.circle", label: "Remove", size: 24) { options[key] = .array((options[key]?.array ?? []).filter { $0.string != path }) }
                                }
                            }
                        }
                    }
                }
                Button("Save Discovery Settings") {
                    Task { do {
                        var saved = options
                        saved["codexHome"] = .string(home)
                        saved["fallbackNames"] = fallbacks.trimmingCharacters(in: .whitespaces).isEmpty ? nil : .array(fallbacks.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) })
                        saved["maxInstructionBytes"] = overrideBudget ? .number(Double(byteLimit)) : nil
                        try await model.saveResourceSettings(saved); options = saved; notice = "Saved. New user turns use the new settings."; await refresh()
                    } catch { notice = error.localizedDescription } }
                }.buttonStyle(.piPrimary)
            }.padding(2)
        }
    }
    private func loadOptions() async {
        if let id = model.selectedWorkspaceID { options = (try? await model.editableResourceSettings(workspaceID: id)) ?? [:] }
        home = options["codexHome"]?.string ?? ""; fallbacks = options["fallbackNames"]?.array?.compactMap(\.string).joined(separator: ", ") ?? ""
        byteLimit = options["maxInstructionBytes"]?.nonnegativeInteger ?? 32768; overrideBudget = options["maxInstructionBytes"] != nil
    }
    private func addPath(_ key: String) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = key != "piInstructionPaths"; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.message = "Approve read-only resource discovery."
        Task {
            let chosen = await PiQuestion.shared.open(panel)
            guard !chosen.isEmpty else { return }
            var paths = options[key]?.array?.compactMap(\.string) ?? []
            for url in chosen where !paths.contains(url.path) { paths.append(url.path) }
            options[key] = .array(paths.prefix(32).map(WireValue.string))
        }
    }
    private func policy(_ skill: SkillDescriptor, key: String, enabled: Bool) {
        guard !policyBusy else { return }; policyBusy = true
        Task { do {
            defer { policyBusy = false }
            await loadOptions(); var ids = Set(options[key]?.array?.compactMap(\.string) ?? [])
            if enabled { ids.insert(skill.id) } else { ids.remove(skill.id) }; options[key] = .array(ids.sorted().map(WireValue.string))
            try await model.saveResourceSettings(options); await refresh()
        } catch { policyBusy = false; notice = error.localizedDescription } }
    }
    private func setEnabled(_ skill: SkillDescriptor, enabled: Bool) {
        guard !policyBusy else { return }; policyBusy = true
        Task { defer { policyBusy = false }; do {
            try await model.setSkillEnabledInBelloAgent(skill,enabled:enabled)
            if !enabled { management = true }
            notice = enabled ? "Enabled in Bello Agent. Source and project policies still apply." : "Disabled in Bello Agent across all projects. Codex is unchanged."
            await loadOptions(); await refresh()
        } catch { notice = error.localizedDescription } }
    }
    private func refresh() async {
        await model.loadSkillCatalog(refresh: true)
        do {
            snapshot = try await model.resourceRequest(params: ["sourceOffset": .number(Double(sourceOffset)), "refresh": .bool(true)])
            if !model.resourceCatalog.contains(where: { $0.id == selectedID }) { selectedID = filtered.first?.id ?? "" }
            loadBody()
        } catch { notice = error.localizedDescription }
    }
    private func loadBody() {
        let id = selectedID, offset = bodyOffset
        guard !id.isEmpty else { detail = "Select a skill to inspect its source and policy."; nextBody = nil; return }
        Task { do {
            let page = try await model.resourceRequest("resources.skill.read", params: ["skillId": .string(id), "offset": .number(Double(offset))])
            guard id == selectedID, offset == bodyOffset else { return }; detail = page["text"]?.string ?? ""; nextBody = page["next"]?.number
        } catch { detail = error.localizedDescription } }
    }
}

// Kept in this already-registered source file: the checked-in Xcode project needs
// no generated-file edit to make MCP accessible from the existing inspector.
@MainActor
private struct NativeMCPInspector: View {
    @ObservedObject var model: WorkspaceModel
    @State private var servers: [String] = []
    @State private var server = ""
    @State private var tool = ""
    @State private var tools: [[String: WireValue]] = []
    @State private var targets = "[]"
    @State private var arguments = "{}"
    @State private var result = ""
    @State private var notice = ""
    @State private var configuration = "{\"servers\":{}}"
    @State private var editingConfiguration = false
    @State private var configurationRevision: Int64 = 0
    @State private var busy = false
    @State private var unknown = false

    var body: some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            HStack(spacing: PiSpacing.sm) {
                Button { editConfiguration() } label: { Label("Edit Vault Configuration…", systemImage: "key") }.disabled(busy)
                Button { perform { try await refreshServers() } } label: { Label("Refresh Servers", systemImage: "arrow.clockwise") }.disabled(busy)
                Button { disconnect() } label: { Label("Disconnect All", systemImage: "bolt.slash") }.buttonStyle(.piGhost).disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            PiNote("MCP configuration and explicit credentials are stored in the single Keychain vault. External configuration files and inherited credential references are retired.")
            if editingConfiguration {
                PiCard(padding: PiSpacing.md) {
                    VStack(alignment: .leading, spacing: PiSpacing.sm) {
                        Text("Vault MCP configuration").font(PiFont.heading)
                        NativeCodeEditor(text: $configuration).piInset(sunken: true).frame(height: 160)
                        HStack {
                            Button("Save and Connect…") { saveConfiguration() }.buttonStyle(.piPrimary).disabled(busy)
                            Button("Cancel Editing") { editingConfiguration = false; configuration = "{\"servers\":{}}" }.buttonStyle(.piGhost)
                        }
                    }
                }
            }
            HStack(spacing: PiSpacing.sm) {
                PiDropdown(selection: $server, items: [("", "Choose a server")] + servers.map { ($0, $0) }, placeholder: "Choose a server", icon: "server.rack")
                Button { perform { try await loadTools() } } label: { Label("List Tools", systemImage: "list.bullet") }.disabled(busy || server.isEmpty)
                Spacer()
            }
            HSplitView {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(tools.enumerated()), id: \.offset) { _, entry in
                            let name = entry["name"]?.string ?? ""
                            PiSelectableRow(selected: name == tool, action: {
                                tool = name
                                targets = WireValue.array([.object(["server": .string(server), "tool": .string(tool)])]).pretty
                            }) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(name).font(PiFont.heading).foregroundStyle(Color.piInk)
                                    Text(entry["description"]?.string ?? "").font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(3)
                                }
                            }
                        }
                    }.padding(PiSpacing.sm)
                }
                .overlay { if tools.isEmpty { Text("Choose a server and list its tools").font(PiFont.caption).foregroundStyle(Color.piInkTertiary) } }
                .piInset().frame(minWidth: 250, idealWidth: 300, maxWidth: 380).padding(.trailing, PiSpacing.sm)
                VStack(alignment: .leading, spacing: PiSpacing.sm) {
                    PiSectionHeader("Describe", subtitle: "Schema targets: a JSON array of {server, tool}; up to 32.") {
                        Button("Describe Selected Tools") {
                            perform {
                                let value = try parse(targets); guard value.array != nil else { throw HostError.failure("Schema targets must be a JSON array") }
                                result = WireValue.object(try await model.resourceRequest("mcp.describe", params: ["targets": value])).pretty
                            }
                        }.buttonStyle(.piSecondaryCompact).disabled(busy)
                    }
                    NativeCodeEditor(text: $targets, accessibilityLabel: "Schema targets JSON").piInset().frame(height: 60)
                    PiSectionHeader("Invoke once", subtitle: "One server, one tool, one JSON object of arguments.") {
                        Button("Invoke One Tool…") { invoke() }.buttonStyle(.piSecondaryCompact).disabled(busy || server.isEmpty || tool.isEmpty || unknown)
                    }
                    HStack { PiTextField(placeholder: "One server", text: $server, mono: true); PiTextField(placeholder: "One tool", text: $tool, mono: true) }
                    NativeCodeEditor(text: $arguments, accessibilityLabel: "Invocation arguments JSON").piInset().frame(height: 66)
                    PagedTextView(text: result).piInset()
                }.frame(minWidth: 500).padding(.leading, PiSpacing.sm)
            }
            if unknown {
                HStack(spacing: PiSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.piWarning)
                    Text("The previous invocation's outcome is unknown. Check its effects before acknowledging.").font(PiFont.caption)
                    Spacer()
                    Button("I Reviewed the Previous Invocation’s Effects…") { acknowledge() }.buttonStyle(.piSecondaryCompact).disabled(busy)
                }.padding(PiSpacing.sm).background(Color.piWarning.opacity(0.10), in: RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous))
            }
            PiStatusLine(text: busy ? "Operation in progress. No automatic retry will be made." : notice)
        }.task { perform { try await refreshServers() } }
    }
    private func parse(_ text: String) throws -> WireValue {
        guard text.utf8.count <= 262144 else { throw HostError.failure("JSON input exceeds 256 KiB") }
        return try JSONDecoder().decode(WireValue.self, from: Data(text.utf8))
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        Task { defer { busy = false }; do { try await operation() } catch { notice = error.localizedDescription } }
    }
    private func refreshServers() async throws {
        let value = try await model.resourceRequest("mcp.list")
        servers = value["servers"]?.array?.compactMap { $0.object?["server"]?.string } ?? []
        if !servers.contains(server) { server = servers.first ?? ""; tools = [] }
        unknown = value["outcomeUnknown"]?.bool ?? false
        notice = value["notice"]?.string ?? (unknown ? "Previous invocation outcome is unknown. Check effects before acknowledging." : "Connected configuration is approved; tool discovery does not invoke tools.")
    }
    private func loadTools() async throws {
        let value = try await model.resourceRequest("mcp.list", params: ["server": .string(server)])
        tools = value["tools"]?.array?.compactMap(\.object) ?? []; notice = "\(tools.count) tools. Select one or enter several schema targets."
    }
    private func editConfiguration() {
        guard let id = model.selectedWorkspaceID else { return }
        configuration = (model.configuration.mcp[id] ?? .object(["servers": .object([:])])).pretty
        configurationRevision = model.configuration.revision; editingConfiguration = true
    }
    private func saveConfiguration() {
        confirmThen("Trust these MCP servers?",
                    "Saving this configuration can authorize programs and authenticated endpoints with your account's permissions. Review the JSON first. Only explicit server credentials are sent to that server.",
                    action: "Save in Vault and Connect") {
            try await model.saveMCPConfiguration(parse(configuration), expectedRevision: configurationRevision)
            editingConfiguration = false; configuration = "{\"servers\":{}}"; try await refreshServers()
        }
    }
    private func disconnect() {
        perform {
            try await model.saveMCPConfiguration(.object(["servers": .object([:])]), expectedRevision: model.configuration.revision)
            try await refreshServers(); tools = []; result = ""
        }
    }
    private func invoke() {
        guard let id = model.resourceTargetSessionID ?? model.selectedID, let chat = model.record(id), chat.toolMode == "editing", chat.connectionTest != true else { notice = "Select an editing chat before invoking MCP."; return }
        confirmThen("Invoke \(server) / \(tool)?",
                    "Exactly one invocation will be sent. It may change external state. Inspect the schema and arguments first. No automatic retry is performed.",
                    action: "Invoke Once") {
            let value = try parse(arguments); guard value.object != nil else { throw HostError.failure("Invocation arguments must be one JSON object") }
            _ = try await model.open(chat)
            do { result = WireValue.object(try await model.resourceRequest("mcp.invoke", params: ["server": .string(server), "tool": .string(tool), "arguments": value], sessionID: id)).pretty }
            catch { try? await refreshServers(); throw error }
            try await refreshServers()
        }
    }
    private func acknowledge() {
        confirmThen("Have you checked the previous invocation’s effects?",
                    "Acknowledging permits a new invocation; it does not retry, cancel, or undo the previous one.",
                    action: "I Checked — Acknowledge") {
            _ = try await model.resourceRequest("mcp.acknowledgeUnknown", params: ["confirmed": .bool(true)]); try await refreshServers()
        }
    }
    /// Asks on a sheet and, if the reader agrees, runs the work through the
    /// same busy guard `perform` uses. A modal run loop would stop the app.
    private func confirmThen(_ title: String, _ detail: String, action: String, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        Task {
            guard await PiQuestion.shared.confirm(title, detail, action: action) else { return }
            perform(operation)
        }
    }
}

private struct InstructionSourceRow: View {
    let position: Int
    let source: [String: WireValue]
    private var state: String { source["state"]?.string ?? "" }
    var body: some View {
        HStack(alignment: .top, spacing: PiSpacing.sm) {
            Text("\(position)").font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkTertiary).frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    PiBadge(text: state, tone: state == "included" ? .success : state == "skipped" || state == "omitted" ? .warning : .neutral)
                    PiBadge(text: source["scope"]?.string ?? "")
                }
                Text(source["path"]?.string ?? "").font(PiFont.mono).foregroundStyle(Color.piInk).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                if let reason = source["reason"]?.string, !reason.isEmpty { Text(reason).font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
                Text("SHA-256 " + (source["hash"]?.string ?? "unavailable")).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
        }.padding(.horizontal, PiSpacing.md).padding(.vertical, 8)
    }
}
