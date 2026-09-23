import SwiftUI

/// The Settings sheet: connections, keys, headers, model choices, reasoning
/// and gateway contracts, runtime, capture and updates. Every connection is a
/// tab; the tab's edits live in `ConnectionSettingsController`, which keeps
/// them across tab switches, lists models for a connection before it is
/// saved, and saves against the vault's current revision.
struct ProfileSettings: View {
    @ObservedObject var model: WorkspaceModel
    /// True in the Settings window, which replaces the system title bar; false in the sheet.
    var windowChrome = false
    @StateObject private var controller: ConnectionSettingsController
    @Environment(\.dismiss) private var dismiss

    init(model: WorkspaceModel, windowChrome: Bool = false) {
        self.model = model; self.windowChrome = windowChrome
        _controller = StateObject(wrappedValue: ConnectionSettingsController(model: model))
    }
    private var quotaMiB: Binding<Int64> {
        Binding(get: { controller.preferences.capture.quotaBytes / 1_048_576 }, set: { controller.preferences.capture.quotaBytes = $0 * 1_048_576 })
    }
    private var catalogURL: Binding<String> {
        Binding(get: { controller.draft.profile.catalogUrl ?? "" }, set: { controller.draft.profile.catalogUrl = $0.isEmpty ? nil : $0 })
    }
    private var isSaved: Bool { controller.isSaved }
    /// The Test Connection button asked once; the footer explains the request until Send or Cancel.
    @State private var confirmingTest = false

    var body: some View {
        PiSheet("Settings", subtitle: "Your connections, keys, headers, MCP servers and preferences. Everything here is kept in your macOS Keychain and only this signed app can read it.", symbol: "gearshape", windowChrome: windowChrome) {
            ScrollView {
                // Lazy, so opening Settings builds the connection form the
                // sheet opens on rather than all eight groups, the code editor
                // among them, before it can be shown.
                LazyVStack(alignment: .leading, spacing: PiSpacing.xl) {
                    // Every saved connection is a tab, so the count and the
                    // current one are visible at a glance; a new connection opens
                    // as its own tab until it is saved, and a tab with unsaved
                    // edits carries a dot until they are saved or discarded.
                    HStack(alignment: .center, spacing: PiSpacing.sm) {
                        Text("Connections · \(model.profiles.count)").font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.4).fixedSize()
                        ScrollView(.horizontal, showsIndicators: false) {
                            PiTabs(selection: Binding(get: { controller.draft.profile.id }, set: { controller.select(id: $0) }), items: controller.tabs)
                                .accessibilityIdentifier("settings-connection-tabs")
                        }
                        if isSaved {
                            PiIconButton(symbol: "plus", label: "New connection", size: 26) { controller.startNew() }
                                .help("Start a new connection in its own tab")
                                .accessibilityIdentifier("settings-new-connection")
                        }
                        Spacer(minLength: 0)
                        PiIconButton(symbol: "arrow.clockwise", label: "Reload vault", size: 26) { Task { await controller.load(discardingDrafts: true) } }
                            .help("Reload the configuration vault and drop unsaved edits")
                    }
                    PiSettingsGroup(title: isSaved ? "Connection" : "New connection",
                                    footer: "Leave the key and headers empty to keep the saved values. The selected alias remains the requested model; a gateway's reported route may change between requests.") {
                        PiRow(label: "Name", detail: "Rename freely: the connection keeps its id, key, chats and model cache.") {
                            PiTextField(placeholder: "Team router", text: $controller.draft.profile.name).accessibilityIdentifier("settings-connection-name")
                        }
                        PiRow(label: "LiteLLM API") {
                            if controller.supportedAPI {
                                Text("Responses").font(PiFont.body).foregroundStyle(Color.piInkSecondary)
                            } else {
                                HStack {
                                    Text("Messages · history only").font(PiFont.body).foregroundStyle(Color.piWarning)
                                    Button("Use Responses") {
                                        controller.draft.profile.api = LiteLLMConfiguration.supportedAPI
                                        controller.message = "Review the Responses URL below, then save. A new connection will retain this key; the original Messages connection and its history stay unchanged."
                                        controller.messageTone = .neutral
                                    }
                                }
                            }
                        }
                        if !controller.supportedAPI {
                            Text(LiteLLMConfiguration.unsupportedAPIMessage).font(PiFont.caption).foregroundStyle(Color.piWarning).padding(.horizontal, PiSpacing.md)
                        }
                        PiRow(label: "Base URL or full API route") {
                            PiTextField(placeholder: "https://litellm.example.com", text: $controller.draft.profile.baseUrl, mono: true).accessibilityIdentifier("settings-base-url")
                        }
                        // The key sits right under the URL: together they are what a
                        // gateway needs before its models can be listed below.
                        PiRow(label: "LiteLLM API key", detail: isSaved ? "Empty keeps the saved key. No shell, OAuth or environment fallback." : "Needed to list a gateway's own catalog and to send. No shell, OAuth or environment fallback.") {
                            PiTextField(placeholder: isSaved ? "Saved · type to replace" : "sk-…", text: $controller.draft.key, icon: "key", secure: true).accessibilityIdentifier("settings-api-key")
                        }
                        PiRow(label: "Custom headers JSON", detail: "Empty preserves saved headers; {} clears them.") {
                            PiTextField(placeholder: "{\"X-Team\": \"payments\"}", text: $controller.draft.headers, icon: "curlybraces", secure: true)
                        }
                        PiRow(label: "Custom model catalog URL", detail: "Blank uses the included Bello catalog. A custom URL replaces it; only the gateway's origin receives its key.") {
                            PiTextField(placeholder: "Blank uses the Bello model catalog", text: catalogURL, icon: "list.bullet.rectangle", mono: true).accessibilityIdentifier("settings-catalog-url")
                        }
                        if isSaved, model.catalogProfile(for: controller.draft.profile).id != controller.draft.profile.id {
                            let source = model.catalogProfile(for: controller.draft.profile)
                            Text("Model list follows \(source.name) · \(CatalogModelPicker.sourceLabel(source)). Editing the URL above saves a separate catalog for this connection.")
                                .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).padding(.horizontal, PiSpacing.md)
                        }
                        PiRow(label: "Requested model / router alias", detail: isSaved ? nil : "Choose from the catalog, or type an alias your gateway routes.") {
                            HStack(spacing: 6) {
                                PiTextField(placeholder: "alias", text: $controller.draft.profile.modelId, mono: true).accessibilityIdentifier("settings-model-alias")
                                CatalogModelMenu(model: model, controller: controller)
                            }
                        }
                        PiRow(label: "Mini model", detail: "Used for automatic chat titles. Catalog default uses the first active model marked Mini; without one, no title request is sent.") {
                            CatalogModelMenu(model: model, controller: controller, miniSelection: true)
                        }
                        PiRow(label: "Configured context capacity") { PiNumberField(placeholder: "Tokens", value: $controller.draft.profile.contextWindow) }
                        PiRow(label: "Output budget", detail: "Room the context estimate sets aside for a reply, so a chat compacts before a reply would no longer fit. It is never sent as a limit: replies run to the model's own output ceiling.") {
                            PiNumberField(placeholder: "Tokens", value: $controller.draft.profile.maxOutputTokens)
                        }
                        PiRow(label: "Model output ceiling", detail: "The catalog's limit for the chosen model, sent with every request as its output limit.", last: true) {
                            Text(controller.draft.profile.modelOutputLimit.map { "\($0.formatted()) tokens" } ?? "Not supplied by the model catalog; requests carry no output limit")
                                .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                        }
                    }
                    PiSettingsGroup(title: "Reasoning continuation", footer: "Portable history supports changing router models. It sends visible text and tool calls/results; original signed/encrypted reasoning stays in history. Preserving native state requires a compatible route guaranteed by your gateway.") {
                        PiRow(label: "Policy", last: controller.draft.replayPolicy != "pinned") {
                            PiDropdown(selection: $controller.draft.replayPolicy, items: [("portable", "Portable text and tool history"), ("pinned", "Preserve native state on a fixed route"), ("ask", "Ask before replaying native state")], compact: true)
                        }
                        if controller.draft.replayPolicy == "pinned" {
                            PiRow(label: "Expected reported model") { PiTextField(placeholder: "model id", text: $controller.draft.expectedModel, mono: true) }
                            PiRow(label: "Fixed-route compatibility contract", last: true) { PiTextField(placeholder: "reference", text: $controller.draft.replayContract) }
                        }
                    }
                    PiSettingsGroup(title: "Gateway model and cache metadata contract", footer: "The response model is recorded automatically. Only configure headers documented for your deployment. An opaque deployment ID or route group is not an actual model name. Use a header reporting true/false or hit/miss; a cache key alone is not evidence of a hit.") {
                        PiRow(label: "Deployment/version contract reference") { PiTextField(placeholder: "reference", text: $controller.draft.metadataReference) }
                        PiRow(label: "Actual model header") { PiTextField(placeholder: "optional", text: $controller.draft.modelHeader, mono: true) }
                        PiRow(label: "Deployment ID header") { PiTextField(placeholder: "optional", text: $controller.draft.deploymentHeader, mono: true) }
                        PiRow(label: "Route group header") { PiTextField(placeholder: "optional", text: $controller.draft.groupHeader, mono: true) }
                        PiRow(label: "Cache hit/miss header", last: true) { PiTextField(placeholder: "optional", text: $controller.draft.cacheHeader, mono: true) }
                    }
                    PiSettingsGroup(title: "Gateway routing", footer: "Off sends disable_fallbacks with every request, so a failing route returns its error and the report shows the requested model unanswered. On lets LiteLLM answer from its configured fallback models.") {
                        PiRow(label: "Allow fallback models", last: true) { Toggle("", isOn: $controller.draft.allowFallbacks).labelsHidden().accessibilityLabel("Allow fallback models") }
                    }
                    PiSettingsGroup(title: "Model capabilities", footer: "JSON: reasoning, thinkingLevel, thinkingLevelMap, input, cost, samplingParams and compat. Default thinking leaves effort unspecified. Configure conservative capacity for a router alias.") {
                        NativeCodeEditor(text: $controller.draft.advanced).frame(height: 130).padding(PiSpacing.sm)
                    }
                    PiSettingsGroup(title: "Runtime", footer: "PATH applies to newly started helpers. Provider credentials are never inherited by shell tools.") {
                        PiRow(label: "Idle helper grace") { PiStepper(label: "\(controller.preferences.runtime.idleGraceSeconds) seconds", value: $controller.preferences.runtime.idleGraceSeconds, range: 10...600, step: 10) }
                        PiRow(label: "Tools PATH", last: true) { PiTextField(placeholder: "/usr/bin:/bin", text: $controller.preferences.runtime.toolsPATH, mono: true) }
                    }
                    PiSettingsGroup(title: "Capture and dashboard", footer: "Request and response bodies are saved locally for 30 days by default, within the storage quota. Headers are included with authentication values masked. Bodies are unencrypted; known credentials in request bodies are hashed. Per-session overrides are separate.") {
                        PiRow(label: "Default future body capture") { PiDropdown(selection: $controller.preferences.capture.defaultMode, items: [("off", "Off"), ("memory", "Session memory"), ("persist", "Persist locally")], compact: true) }
                        PiRow(label: "Body retention") { PiStepper(label: "\(controller.preferences.capture.retentionDays) days", value: $controller.preferences.capture.retentionDays, range: 1...365) }
                        PiRow(label: "Payload quota") { PiStepper64(label: "\(quotaMiB.wrappedValue) MiB", value: quotaMiB, range: 1...10_240) }
                        PiRow(label: "Metric retention") { PiStepper(label: "\(controller.preferences.dashboard.metricRetentionDays) days", value: $controller.preferences.dashboard.metricRetentionDays, range: 1...3650) }
                        PiRow(label: "Dashboard window", last: true) { PiStepper(label: "\(controller.preferences.dashboard.windowHours) hours", value: $controller.preferences.dashboard.windowHours, range: 1...8760) }
                    }
                    PiSettingsGroup(title: "Spending", footer: CostLimitText.explanation + " A chat can have its own limit: open its token usage figure under the composer, or Session info.") {
                        PiRow(label: "Cost limit per chat", detail: controller.preferences.defaultChatCostLimit.usd == nil
                              ? "No chat is stopped for what it costs, unless it has a limit of its own."
                              : "Every chat without its own limit stops at \(controller.preferences.defaultChatCostLimit.label) of reported spend.", last: true) {
                            CostLimitChoices(selection: controller.preferences.defaultChatCostLimit,
                                             choose: { controller.preferences.chatCostLimit = $0 ?? .standard },
                                             identifier: "settings-cost-limit")
                        }
                    }
                    PiSettingsGroup(title: "Transcript", footer: "Compact is how a finished turn reads by default: its tool calls and thoughts fold behind one line above the answer, and one click on that line shows the whole turn again. Nothing is discarded either way, and a turn still running always reads in full.") {
                        PiRow(label: "Finished turns", detail: TranscriptDisplayMode.compact.detail, last: true) {
                            PiDropdown(selection: $controller.preferences.transcriptDisplay,
                                       items: TranscriptDisplayMode.allCases.map { ($0, $0.label) }, compact: true)
                                .accessibilityLabel("Transcript display for finished turns")
                                .accessibilityIdentifier("settings-transcript-display")
                        }
                    }
                    PiSettingsGroup(title: "Notifications") {
                        PiRow(label: "Task completion sound", detail: "Play a short chime when a chat finishes its task, even while the app is in the background.", last: true) {
                            HStack(spacing: PiSpacing.sm) {
                                Button { model.completionSound.play() } label: { Label("Preview", systemImage: "speaker.wave.2") }
                                    .buttonStyle(.piSecondaryCompact)
                                    .accessibilityIdentifier("settings-preview-completion-sound")
                                Toggle("", isOn: $controller.preferences.playsCompletionSound).labelsHidden()
                                    .accessibilityLabel("Play task completion sound")
                                    .accessibilityIdentifier("settings-completion-sound")
                            }
                        }
                    }
                    PiSettingsGroup(title: "Updates") {
                        PiRow(label: "Check for app updates automatically", last: true) { Toggle("", isOn: $controller.preferences.automaticUpdateChecks).labelsHidden() }
                    }
                }
                .padding(PiSpacing.xl)
                // A save writes the tabs it captured when it started. Leaving
                // the sheet live meant a tab switch mid-save lost what was typed
                // after it, and Reload vault cleared `busy` under the save.
                .disabled(controller.busy)
            }
        } actions: {
            Button("Cancel") { dismiss() }.disabled(controller.busy)
        } footer: {
            HStack(spacing: PiSpacing.sm) {
                if isSaved && controller.confirmingDelete {
                    // The question sits where the button was, in the sheet itself: no modal to miss.
                    Text("Delete “\(controller.draft.name)”? " + controller.deletionSummary)
                        .font(PiFont.caption).foregroundStyle(Color.piDanger).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-delete-connection-question")
                    Spacer(minLength: PiSpacing.md)
                    Button("Keep") { withAnimation(PiMotion.quick) { controller.confirmingDelete = false } }.buttonStyle(.piSecondaryCompact).fixedSize()
                        .accessibilityIdentifier("settings-keep-connection")
                    Button { Task { await controller.delete() } } label: { Label("Delete Connection", systemImage: "trash") }.buttonStyle(.piDanger).fixedSize()
                        .accessibilityIdentifier("settings-confirm-delete-connection")
                } else if confirmingTest {
                    Text("Send one small test request to “\(controller.draft.name)” now? Its provider may charge for it. The test runs in a saved chat outside any project, so you can inspect it later.")
                        .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-test-connection-question")
                    Spacer(minLength: PiSpacing.md)
                    Button("Cancel") { withAnimation(PiMotion.quick) { confirmingTest = false } }.buttonStyle(.piSecondaryCompact).fixedSize()
                    Button { confirmingTest = false; Task { if await controller.save(thenTest: true) { dismiss() } } } label: { Label("Send Test Request", systemImage: "bolt.horizontal") }.buttonStyle(.piPrimary).fixedSize()
                        .accessibilityIdentifier("settings-confirm-test-connection")
                } else {
                    if isSaved {
                        // Asking to delete is not deleting: the quiet form here,
                        // the loud one on the confirmation above. A filled danger
                        // pill was the loudest control on the sheet, louder than
                        // Save, which is the action almost every visit ends with.
                        Button { withAnimation(PiMotion.base) { controller.confirmingDelete = true } } label: { Label("Delete Connection…", systemImage: "trash") }.buttonStyle(.piGhostDanger).fixedSize()
                            .help("Removes this connection and its key from the vault. Its chats keep their history and ask for another connection.")
                            .accessibilityIdentifier("settings-delete-connection")
                    } else if !model.profiles.isEmpty {
                        Button("Discard") { controller.discardCurrent() }.buttonStyle(.piSecondaryCompact).fixedSize()
                            .help("Drop this unsaved connection and return to a saved one")
                            .accessibilityIdentifier("settings-discard-connection")
                    }
                    Button { withAnimation(PiMotion.base) { confirmingTest = true } } label: { Label("Test Connection…", systemImage: "bolt.horizontal") }.fixedSize()
                        .disabled(!model.configurationLoaded || !controller.supportedAPI || controller.draft.profile.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Saves this configuration, then sends one test request in a saved chat outside any project.")
                    PiStatusLine(text: controller.message, tone: controller.messageTone).lineLimit(2)
                    Spacer(minLength: PiSpacing.md)
                    Button("Save") { Task { if await controller.save() { dismiss() } } }.buttonStyle(.piPrimary).fixedSize().disabled(!model.configurationLoaded)
                        .help("Saves every tab with edits and the preferences, then closes Settings.")
                        .accessibilityIdentifier("settings-save")
                }
            }
            .disabled(controller.busy)
            .piAnimation(PiMotion.base, value: controller.confirmingDelete)
            .piAnimation(PiMotion.base, value: confirmingTest)
            .onChange(of: controller.draft.profile.id) { _, _ in confirmingTest = false }
        }
        .task { await controller.load(discardingDrafts: false) }
    }
}

/// A snapshot of the editable connection fields, separate from the persisted
/// profile. Defaults shown by the form and JSON formatting are not user edits.
struct SettingsConnectionForm: Equatable {
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

/// Opens the catalog picker for the connection being edited: the bundled
/// Bello catalog needs nothing, a custom catalog on the gateway's origin
/// uses the key typed above (or the saved one), and the list follows the
/// URL fields as they change.
private struct CatalogModelMenu: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var controller: ConnectionSettingsController
    @ObservedObject private var catalog: ModelCatalog
    var miniSelection = false
    @State private var presented = false
    init(model: WorkspaceModel, controller: ConnectionSettingsController, miniSelection: Bool = false) {
        self.model = model; self.controller = controller; self.catalog = model.modelCatalog; self.miniSelection = miniSelection
    }
    var body: some View {
        let listing = controller.listingProfile
        let entry = catalog.entry(for: listing)
        let draft = controller.draft
        Button { presented.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 11, weight: .semibold))
                Text(miniSelection ? (draft.profile.miniModelId ?? "Catalog default") : "Choose")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if entry.loading { ProgressView().controlSize(.mini) }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.piInkTertiary)
            }
            .foregroundStyle(Color.piInk).padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.piSurface, in: Capsule()).overlay(Capsule().stroke(Color.piHairlineStrong, lineWidth: 1)).contentShape(Capsule())
        }
        .buttonStyle(.plain).piPointer().disabled(!controller.supportedAPI)
        .popover(isPresented: $presented, arrowEdge: .trailing) {
            CatalogModelPicker(model: model, profile: listing, current: miniSelection ? draft.profile.miniModelId : draft.profile.modelId,
                               draft: .init(profile: draft.profile, key: draft.key),
                               defaultTitle: miniSelection ? "Use catalog Mini default" : nil,
                               defaultSelected: miniSelection && draft.profile.miniModelId == nil,
                               useDefault: miniSelection ? { presented = false; controller.useCatalogMiniDefault() } : nil) { item in
                presented = false
                if miniSelection { controller.chooseMini(item) } else { controller.choose(item) }
            }
        }
        .onChange(of: draft.profile.id) { _, _ in presented = false }
        .help(controller.supportedAPI ? "Search every model from the bundled Bello catalog or this connection's custom catalog." : "Choose Use Responses above to list models.")
        .accessibilityLabel(miniSelection ? "Mini model: \(draft.profile.miniModelId ?? "Catalog default")" : "Choose connection model")
        .accessibilityIdentifier(miniSelection ? "settings-mini-model-menu" : "settings-model-menu")
    }
}
