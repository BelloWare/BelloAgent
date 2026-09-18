import SwiftUI

struct ProfileSettings: View {
    @ObservedObject var model: WorkspaceModel
    /// True in the Settings window, which replaces the system title bar; false in the sheet.
    var windowChrome = false
    @State private var profile = ProfileRecord()
    @State private var preferences = VaultConfiguration()
    @State private var revision: Int64 = 0
    @State private var key = ""
    @State private var headers = ""
    @State private var advanced = "{}"
    @State private var replayPolicy = "portable"
    @State private var expectedModel = ""
    @State private var replayContract = ""
    @State private var metadataReference = ""
    @State private var modelHeader = ""
    @State private var deploymentHeader = ""
    @State private var groupHeader = ""
    @State private var cacheHeader = ""
    @State private var allowFallbacks = false
    @State private var loadedConnection: SettingsConnectionForm?
    @State private var message = ""
    @State private var messageTone: PiTone = .neutral
    @State private var busy = false
    /// The Delete button asked once; the footer shows what the deletion touches until Delete or Keep.
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss
    private var isSaved: Bool { model.profiles.contains { $0.id == profile.id } }
    private var quotaMiB: Binding<Int64> { Binding(get: { preferences.capture.quotaBytes / 1_048_576 }, set: { preferences.capture.quotaBytes = $0 * 1_048_576 }) }
    private var connectionForm: SettingsConnectionForm {
        var routing: [String: WireValue] = ["replayPolicy": .string(replayPolicy)]
        for (name, value) in [("expectedModel", expectedModel), ("replayContract", replayContract), ("reference", metadataReference), ("modelHeader", modelHeader), ("deploymentHeader", deploymentHeader), ("groupHeader", groupHeader), ("cacheHeader", cacheHeader)] where !value.isEmpty { routing[name] = .string(value) }
        return SettingsConnectionForm(profile: profile, advanced: advanced, routing: routing, allowFallbacks: allowFallbacks)
    }

    var body: some View {
        PiSheet("Settings", subtitle: "Connections, keys, headers, MCP servers and preferences share one versioned Keychain item owned by the signed app.", symbol: "gearshape", windowChrome: windowChrome) {
            ScrollView {
                VStack(alignment: .leading, spacing: PiSpacing.xl) {
                    // Every saved connection is a tab, so the count and the
                    // current one are visible at a glance; a new connection opens
                    // as its own tab until it is saved.
                    HStack(alignment: .center, spacing: PiSpacing.sm) {
                        Text("Connections · \(model.profiles.count)").font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.4).fixedSize()
                        ScrollView(.horizontal, showsIndicators: false) {
                            PiTabs(selection: Binding(get: { profile.id }, set: { id in if id != profile.id, let saved = model.profiles.first(where: { $0.id == id }) { select(saved) } }),
                                   items: model.profiles.map { ($0.id, $0.name.isEmpty ? "Unnamed" : $0.name) } + (isSaved ? [] : [(profile.id, profile.name.isEmpty ? "New connection" : profile.name + " · new")]))
                                .accessibilityIdentifier("settings-connection-tabs")
                        }
                        if isSaved {
                            PiIconButton(symbol: "plus", label: "New connection", size: 26) { select(ProfileRecord()); message = "Fill in the new connection and save it." }
                                .help("Start a new connection in its own tab")
                                .accessibilityIdentifier("settings-new-connection")
                        }
                        Spacer(minLength: 0)
                        PiIconButton(symbol: "arrow.clockwise", label: "Reload vault", size: 26) { Task { await reload() } }.help("Reload the configuration vault")
                    }
                    PiSettingsGroup(title: isSaved ? "Connection" : "New connection", footer: "Leave the key and headers empty to keep the saved values. The selected alias remains the requested model; a gateway's reported route may change between requests.") {
                        PiRow(label: "Name", detail: "Rename freely: the connection keeps its id, key, chats and model cache.") { PiTextField(placeholder: "Team router", text: $profile.name) }
                        PiRow(label: "LiteLLM API") {
                            if profile.api == LiteLLMConfiguration.supportedAPI {
                                Text("Responses").font(PiFont.body).foregroundStyle(Color.piInkSecondary)
                            } else {
                                HStack {
                                    Text("Messages · history only").font(PiFont.body).foregroundStyle(Color.piWarning)
                                    Button("Use Responses") {
                                        profile.api = LiteLLMConfiguration.supportedAPI
                                        message = "Review the Responses URL below, then save. A new connection will retain this key; the original Messages connection and its history stay unchanged."
                                    }
                                }
                            }
                        }
                        if profile.api != LiteLLMConfiguration.supportedAPI {
                            Text(LiteLLMConfiguration.unsupportedAPIMessage).font(PiFont.caption).foregroundStyle(Color.piWarning).padding(.horizontal, PiSpacing.md)
                        }
                        PiRow(label: "Base URL or full API route") { PiTextField(placeholder: "https://litellm.example.com", text: $profile.baseUrl, mono: true) }
                        PiRow(label: "Custom model catalog URL", detail: "Blank uses the included Bello catalog. A custom URL replaces it; only the gateway's origin receives its key.") {
                            PiTextField(placeholder: "Blank uses the Bello model catalog", text: Binding(get: { profile.catalogUrl ?? "" }, set: { profile.catalogUrl = $0.isEmpty ? nil : $0 }), icon: "list.bullet.rectangle", mono: true)
                        }
                        if isSaved, model.catalogProfile(for: profile).id != profile.id {
                            let source = model.catalogProfile(for: profile)
                            Text("Model list follows \(source.name) · \(CatalogModelPicker.sourceLabel(source)). Editing the URL above saves a separate catalog for this connection.")
                                .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).padding(.horizontal, PiSpacing.md)
                        }
                        PiRow(label: "Requested model / router alias") {
                            HStack(spacing: 6) {
                                PiTextField(placeholder: "alias", text: $profile.modelId, mono: true)
                                CatalogModelMenu(model: model, profile: profile) { item in
                                    var candidate = profile; candidate.advancedJSON = advanced
                                    profile = item.applying(to: candidate)
                                    advanced = profile.advancedJSON ?? "{}"
                                }
                            }
                        }
                        PiRow(label: "Mini model", detail: "Used for automatic chat titles. Catalog default uses the first active model marked Mini; without one, no title request is sent.") {
                            CatalogModelMenu(model: model, profile: profile, miniSelection: true,
                                             restoreCatalogDefault: { profile.miniModelId = nil }) { item in
                                // Choosing a utility model must not replace the chat model,
                                // context limits, or its reasoning preferences.
                                profile.miniModelId = item.id
                            }
                        }
                        PiRow(label: "Configured context capacity") { PiNumberField(placeholder: "Tokens", value: $profile.contextWindow) }
                        PiRow(label: "Output budget", detail: "Maximum tokens requested per response, including reasoning. This budget is reserved before sending; choosing a larger model never increases it.") { PiNumberField(placeholder: "Tokens", value: $profile.maxOutputTokens) }
                        PiRow(label: "Model output ceiling") {
                            Text(profile.modelOutputLimit.map { "\($0.formatted()) tokens" } ?? "Not supplied by the model catalog")
                                .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                        }
                        PiRow(label: "LiteLLM API key", detail: "Empty preserves the saved key. No shell, OAuth or environment fallback.") { PiTextField(placeholder: "sk-…", text: $key, icon: "key", secure: true) }
                        PiRow(label: "Custom headers JSON", detail: "Empty preserves saved headers; {} clears them.", last: true) { PiTextField(placeholder: "{\"X-Team\": \"payments\"}", text: $headers, icon: "curlybraces", secure: true) }
                    }
                    PiSettingsGroup(title: "Reasoning continuation", footer: "Portable history supports changing router models. It sends visible text and tool calls/results; original signed/encrypted reasoning stays in history. Preserving native state requires a compatible route guaranteed by your gateway.") {
                        PiRow(label: "Policy", last: replayPolicy != "pinned") {
                            PiDropdown(selection: $replayPolicy, items: [("portable", "Portable text and tool history"), ("pinned", "Preserve native state on a fixed route"), ("ask", "Ask before replaying native state")], compact: true)
                        }
                        if replayPolicy == "pinned" {
                            PiRow(label: "Expected reported model") { PiTextField(placeholder: "model id", text: $expectedModel, mono: true) }
                            PiRow(label: "Fixed-route compatibility contract", last: true) { PiTextField(placeholder: "reference", text: $replayContract) }
                        }
                    }
                    PiSettingsGroup(title: "Gateway model and cache metadata contract", footer: "The response model is recorded automatically. Only configure headers documented for your deployment. An opaque deployment ID or route group is not an actual model name. Use a header reporting true/false or hit/miss; a cache key alone does not establish a hit. Cost is shown only when the gateway reports a completed request amount.") {
                        PiRow(label: "Deployment/version contract reference") { PiTextField(placeholder: "reference", text: $metadataReference) }
                        PiRow(label: "Actual model header") { PiTextField(placeholder: "optional", text: $modelHeader, mono: true) }
                        PiRow(label: "Deployment ID header") { PiTextField(placeholder: "optional", text: $deploymentHeader, mono: true) }
                        PiRow(label: "Route group header") { PiTextField(placeholder: "optional", text: $groupHeader, mono: true) }
                        PiRow(label: "Cache hit/miss header", last: true) { PiTextField(placeholder: "optional", text: $cacheHeader, mono: true) }
                    }
                    PiSettingsGroup(title: "Gateway routing", footer: "Off sends disable_fallbacks with every request, so a failing route returns its error and the report shows the requested model unanswered. On lets LiteLLM answer from its configured fallback models.") {
                        PiRow(label: "Allow fallback models", last: true) { Toggle("", isOn: $allowFallbacks).labelsHidden().accessibilityLabel("Allow fallback models") }
                    }
                    PiSettingsGroup(title: "Model capabilities", footer: "JSON: reasoning, thinkingLevel, thinkingLevelMap, input, cost, samplingParams and compat. Default thinking leaves effort unspecified. Configure conservative capacity for a router alias.") {
                        NativeCodeEditor(text: $advanced).frame(height: 130).padding(PiSpacing.sm)
                    }
                    PiSettingsGroup(title: "Runtime", footer: "PATH applies to newly started helpers. Provider credentials are never inherited by shell tools.") {
                        PiRow(label: "Idle helper grace") { PiStepper(label: "\(preferences.runtime.idleGraceSeconds) seconds", value: $preferences.runtime.idleGraceSeconds, range: 10...600, step: 10) }
                        PiRow(label: "Tools PATH", last: true) { PiTextField(placeholder: "/usr/bin:/bin", text: $preferences.runtime.toolsPATH, mono: true) }
                    }
                    PiSettingsGroup(title: "Capture and dashboard", footer: "Request and response bodies are saved locally for 30 days by default, within the storage quota. Headers are included with authentication values masked. Bodies are unencrypted; known credentials in request bodies are hashed. Per-session overrides are separate.") {
                        PiRow(label: "Default future body capture") { PiDropdown(selection: $preferences.capture.defaultMode, items: [("off", "Off"), ("memory", "Session memory"), ("persist", "Persist locally")], compact: true) }
                        PiRow(label: "Body retention") { PiStepper(label: "\(preferences.capture.retentionDays) days", value: $preferences.capture.retentionDays, range: 1...365) }
                        PiRow(label: "Payload quota") { PiStepper64(label: "\(quotaMiB.wrappedValue) MiB", value: quotaMiB, range: 1...10_240) }
                        PiRow(label: "Metric retention") { PiStepper(label: "\(preferences.dashboard.metricRetentionDays) days", value: $preferences.dashboard.metricRetentionDays, range: 1...3650) }
                        PiRow(label: "Dashboard window", last: true) { PiStepper(label: "\(preferences.dashboard.windowHours) hours", value: $preferences.dashboard.windowHours, range: 1...8760) }
                    }
                    PiSettingsGroup(title: "Updates") {
                        PiRow(label: "Check for app updates automatically", last: true) { Toggle("", isOn: $preferences.automaticUpdateChecks).labelsHidden() }
                    }
                }
                .padding(PiSpacing.xl)
            }
        } actions: {
            Button("Cancel") { dismiss() }
        } footer: {
            HStack(spacing: PiSpacing.sm) {
                if isSaved && confirmingDelete {
                    // The question sits where the button was, in the sheet itself: no modal to miss.
                    Text("Delete “\(profile.name.isEmpty ? "Unnamed" : profile.name)”? " + deletionSummary)
                        .font(PiFont.caption).foregroundStyle(Color.piDanger).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-delete-connection-question")
                    Spacer(minLength: PiSpacing.md)
                    Button("Keep") { withAnimation(PiMotion.quick) { confirmingDelete = false } }.buttonStyle(.piSecondaryCompact).fixedSize()
                        .accessibilityIdentifier("settings-keep-connection")
                    Button { deleteConnection() } label: { Label("Delete Connection", systemImage: "trash") }.buttonStyle(.piDanger).fixedSize()
                        .accessibilityIdentifier("settings-confirm-delete-connection")
                } else {
                    if isSaved {
                        Button { withAnimation(PiMotion.base) { confirmingDelete = true } } label: { Label("Delete Connection…", systemImage: "trash") }.buttonStyle(.piDanger).fixedSize()
                            .help("Removes this connection and its key from the vault. Its chats keep their history and ask for another connection.")
                            .accessibilityIdentifier("settings-delete-connection")
                    }
                    Button { save(thenTest: true) } label: { Label("Test Connection…", systemImage: "bolt.horizontal") }.fixedSize()
                        .disabled(!model.configurationLoaded || profile.api != LiteLLMConfiguration.supportedAPI || profile.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Saves this configuration, then sends one test request in a saved chat outside any project.")
                    PiStatusLine(text: message, tone: messageTone).lineLimit(2)
                    Spacer(minLength: PiSpacing.md)
                    Button("Save") { save() }.buttonStyle(.piPrimary).fixedSize().disabled(!model.configurationLoaded)
                        .help("Saves the connection and preferences, then closes Settings.")
                }
            }
            .disabled(busy)
            .piAnimation(PiMotion.base, value: confirmingDelete)
        }
        .task { await reload() }
    }
    private func select(_ value: ProfileRecord) {
        profile = value; key = ""; headers = ""; confirmingDelete = false
        let form = SettingsConnectionForm.loaded(value, isSaved: isSaved), routing = form.routing
        advanced = form.advanced; replayPolicy = routing["replayPolicy"]?.string ?? "ask"
        expectedModel = routing["expectedModel"]?.string ?? ""; replayContract = routing["replayContract"]?.string ?? ""
        metadataReference = routing["reference"]?.string ?? ""; modelHeader = routing["modelHeader"]?.string ?? ""
        deploymentHeader = routing["deploymentHeader"]?.string ?? ""; groupHeader = routing["groupHeader"]?.string ?? ""
        cacheHeader = routing["cacheHeader"]?.string ?? ""
        allowFallbacks = form.allowFallbacks; loadedConnection = form
    }
    /// What the deletion touches: the key, the chats that keep their history, the runs that stop.
    private var deletionSummary: String {
        let using = model.chats.filter { $0.profileID == profile.id && $0.connectionTest != true && !$0.isBackgroundTask }
        let working = using.filter { model.displays[$0.id]?.hasWork == true }.count
        var parts = ["Its key leaves the Keychain item."]
        parts.append(using.isEmpty ? "No chat uses it." : using.count == 1 ? "One chat keeps its history and will need another connection."
                     : "\(using.count) chats keep their history and will need another connection.")
        if working > 0 { parts.append(working == 1 ? "One run will be stopped." : "\(working) runs will be stopped.") }
        return parts.joined(separator: " ")
    }
    private func deleteConnection() {
        let id = profile.id, name = profile.name.isEmpty ? "Unnamed" : profile.name
        confirmingDelete = false
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.deleteProfile(id)
                preferences = model.configuration; revision = preferences.revision
                select(model.profiles.first ?? ProfileRecord())
                messageTone = .neutral
                message = model.profiles.isEmpty ? "“\(name)” was deleted. Add a new connection to send messages." : "“\(name)” was deleted. \(model.profiles.count) connection\(model.profiles.count == 1 ? "" : "s") remain\(model.profiles.count == 1 ? "s" : "")."
            } catch {
                // In the footer and in the window's banner: a deletion that did not happen is never quiet.
                messageTone = .danger
                message = "“\(name)” was not deleted: " + error.localizedDescription
                model.error = "Connection “\(name)” was not deleted: " + error.localizedDescription
            }
        }
    }
    private func reload() async {
        busy = true; defer { busy = false }
        do {
            try await model.reloadConfiguration(); preferences = model.configuration; revision = preferences.revision
            select(model.profiles.first(where: { $0.id == profile.id }) ?? model.profiles.first ?? ProfileRecord())
            message = "Vault revision \(revision). No connection test was sent."; messageTone = .neutral
        } catch { message = error.localizedDescription; messageTone = .danger }
    }
    /// Saves everything on the sheet in one step and closes it on success. The
    /// connection is rewritten only when it changed, so an unchanged connection
    /// keeps its sessions and model cache.
    private func save(thenTest: Bool = false) {
        guard let loadedConnection else { message = "Wait for Settings to finish loading before saving."; return }
        let form = connectionForm, savedKey = key, savedHeaders = headers, savedPreferences = preferences, expectedRevision = revision
        busy = true
        Task {
            defer { busy = false }
            do {
                let savedID = try await form.save(to: model, comparedTo: loadedConnection, key: savedKey, headers: savedHeaders, preferences: savedPreferences, expectedRevision: expectedRevision)
                preferences = model.configuration; revision = preferences.revision
                let forked = savedID != loadedConnection.profile.id, previousName = loadedConnection.profile.name.isEmpty ? "Unnamed" : loadedConnection.profile.name
                if let saved = model.profiles.first(where: { $0.id == savedID }) { select(saved) }
                key = ""; headers = ""; messageTone = .neutral
                if thenTest { model.testConnection(profileID: savedID) }
                if forked {
                    // A changed route is a new connection; the sheet stays open so the extra tab is explained, not a surprise.
                    message = "Saved as a new connection because its API route changed. “\(previousName)” stays for its earlier chats; delete it in its tab if you no longer need it."
                } else {
                    message = "Saved in the configuration vault (revision \(revision))."
                    dismiss()
                }
            } catch { message = error.localizedDescription; messageTone = .danger }
        }
    }
}

/// A snapshot of the editable connection fields, separate from the persisted
/// profile. Defaults shown by the form and JSON formatting are not user edits.
struct SettingsConnectionForm {
    var profile: ProfileRecord
    var advanced: String
    var routing: [String: WireValue]
    var allowFallbacks: Bool

    static func loaded(_ profile: ProfileRecord, isSaved: Bool) -> Self {
        var fields = profile.configuration
        var routing = fields.removeValue(forKey: "routing")?.object ?? [:]
        if routing["replayPolicy"] == nil { routing["replayPolicy"] = .string(isSaved ? "ask" : "portable") }
        return Self(profile: profile, advanced: WireValue.object(fields).pretty, routing: routing,
                    allowFallbacks: fields["compat"]?.object?["allowFallbacks"]?.bool == true)
    }

    private func normalizedProfile() throws -> ProfileRecord {
        let allowed: Set<String> = ["reasoning", "thinkingLevel", "thinkingLevelMap", "input", "cost", "samplingParams", "compat"]
        guard advanced.utf8.count <= 32_768, let config = try? JSONDecoder().decode(WireValue.self, from: Data(advanced.utf8)), var fields = config.object, Set(fields.keys).isSubset(of: allowed) else {
            throw VaultError.invalid("Invalid model capabilities. Credentials and external configuration references do not belong in this field.")
        }
        try RoutingConfiguration.validate(.object(routing))
        fields["routing"] = .object(routing)
        var compat = fields["compat"]?.object ?? [:]
        if allowFallbacks { compat["allowFallbacks"] = .bool(true) } else { compat.removeValue(forKey: "allowFallbacks") }
        if compat.isEmpty { fields.removeValue(forKey: "compat") } else { fields["compat"] = .object(compat) }
        var result = profile; result.advancedJSON = WireValue.object(fields).pretty
        return result
    }

    @MainActor func save(to model: WorkspaceModel, comparedTo baseline: Self, key: String, headers: String,
                         preferences: VaultConfiguration, expectedRevision: Int64) async throws -> String {
        let candidate = try normalizedProfile(), original = try baseline.normalizedProfile()
        if candidate == original, key.isEmpty, headers.isEmpty {
            // Includes an untouched new connection form and retained Messages
            // connections, neither of which should block unrelated preferences.
            try await model.savePreferences(preferences, expectedRevision: expectedRevision)
            return profile.id
        }
        // Validate an edited connection even if its URL was cleared. Failure
        // leaves the form and vault unchanged, so the sheet can show the error.
        try LiteLLMConfiguration.validateForRequests(candidate, headers: [:])
        try await model.saveProfile(candidate, key: key, headers: headers, preferences: preferences, expectedRevision: expectedRevision)
        return model.profileChoice
    }
}


/// Lists the bundled or custom catalog and applies the chosen entry.
private struct CatalogModelMenu: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject private var catalog: ModelCatalog
    let profile: ProfileRecord
    var miniSelection = false
    var restoreCatalogDefault: (() -> Void)?
    let choose: (ModelDescriptor) -> Void
    @State private var presented = false
    init(model: WorkspaceModel, profile: ProfileRecord, miniSelection: Bool = false,
         restoreCatalogDefault: (() -> Void)? = nil, choose: @escaping (ModelDescriptor) -> Void) {
        self.model = model; self.profile = profile; self.choose = choose; self.catalog = model.modelCatalog
        self.miniSelection = miniSelection; self.restoreCatalogDefault = restoreCatalogDefault
    }
    private var listingProfile: ProfileRecord? {
        model.profiles.first { $0.id == profile.id && $0.baseUrl == profile.baseUrl && $0.api == profile.api && $0.catalogUrl == profile.catalogUrl }
    }
    var body: some View {
        let entry = listingProfile.map { model.catalogEntry(for: $0) } ?? ModelCatalog.Entry()
        Button { presented.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 11, weight: .semibold))
                Text(miniSelection ? (profile.miniModelId ?? "Catalog default") : "Choose")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if entry.loading { ProgressView().controlSize(.mini) }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.piInkTertiary)
            }
            .foregroundStyle(Color.piInk).padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.piSurface, in: Capsule()).overlay(Capsule().stroke(Color.piHairlineStrong, lineWidth: 1)).contentShape(Capsule())
        }
        .buttonStyle(.plain).piPointer().disabled(listingProfile == nil)
        .popover(isPresented: $presented, arrowEdge: .trailing) {
            if let listingProfile {
                CatalogModelPicker(model: model, profile: listingProfile, current: miniSelection ? profile.miniModelId : profile.modelId,
                                   defaultTitle: miniSelection ? "Use catalog Mini default" : nil,
                                   defaultSelected: miniSelection && profile.miniModelId == nil,
                                   useDefault: restoreCatalogDefault.map { action in { presented = false; action() } }) { item in
                    presented = false; choose(item)
                }
            }
        }
        .onChange(of: profile.id) { _, _ in presented = false }
        .help(listingProfile == nil ? "Save the connection's source URL first, then choose from its models." :
                "Search every model from the bundled Bello catalog or this connection's custom catalog.")
        .accessibilityLabel(miniSelection ? "Mini model: \(profile.miniModelId ?? "Catalog default")" : "Choose connection model")
    }
}
