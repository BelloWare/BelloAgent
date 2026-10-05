import AppKit
import Combine
import SwiftUI
@testable import PiApp

// Frozen from Bello Agent 0.1.119 (310b222c), ProfileSettings.connections.
// Retains all six groups, their rows, labels, controls and spacing. The
// additions are layout measurements, stable scroll targets, an eager comparison
// using the same children, and a closed catalog button without its popup.
// No native Settings layout is used by this reference.

@MainActor enum SettingsReferenceGroup: String, CaseIterable {
    case tabs, connection, reasoning, metadata, routing, capabilities
}

@MainActor final class SettingsReferenceGeometry: ObservableObject {
    @Published var target: SettingsReferenceGroup?
    var groups: [SettingsReferenceGroup: CGRect] = [:]
}

@MainActor private struct SettingsReferenceGroupGeometry: View {
    let id: SettingsReferenceGroup
    let geometry: SettingsReferenceGeometry
    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named("settings-complete-document"))
            Color.clear.onAppear { geometry.groups[id] = frame }
                .onChange(of: frame) { _, value in geometry.groups[id] = value }
        }
    }
}

@MainActor struct ProfileSettingsConnectionsV119Reference: View {
    enum Layout { case lazy, eager }
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var controller: ConnectionSettingsController
    @ObservedObject var geometry: SettingsReferenceGeometry
    var layout: Layout = .lazy
    private var isSaved: Bool { controller.isSaved }
    private var catalogURL: Binding<String> {
        Binding(get: { controller.draft.profile.catalogUrl ?? "" }, set: { controller.draft.profile.catalogUrl = $0.isEmpty ? nil : $0 })
    }
    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                Group {
                    switch layout {
                    case .lazy: LazyVStack(alignment: .leading, spacing: PiSpacing.xl) { connections }
                    case .eager: VStack(alignment: .leading, spacing: PiSpacing.xl) { connections }
                    }
                }
                .padding(PiSpacing.xl)
                .coordinateSpace(name: "settings-complete-document")
            }
            .onChange(of: geometry.target) { _, target in
                if let target { reader.scrollTo(target, anchor: .top) }
            }
        }
        .buttonStyle(.piSecondary).toggleStyle(.piSwitch)
        .foregroundStyle(Color.piInk).background(Color.piContent)
        .environment(\.piReduceMotion, true)
    }

    @ViewBuilder private var connections: some View {
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
            PiIconButton(symbol: "arrow.clockwise", label: "Reload vault", size: 26) { Task { await controller.requestReload() } }
                .help("Reload the configuration vault. Asks first when that would drop unsaved edits.")
        }
        .background(SettingsReferenceGroupGeometry(id: .tabs, geometry: geometry)).id(SettingsReferenceGroup.tabs)
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
                    SettingsCatalogMenuV119Reference(model: model, controller: controller)
                }
            }
            PiRow(label: "Mini model", detail: "Writes chat titles and the webhook's parameters. Catalog default uses the first active model marked Mini; without one, titles keep the first message and a webhook goes out without its parameters.") {
                SettingsCatalogMenuV119Reference(model: model, controller: controller, miniSelection: true)
            }
            PiRow(label: "Configured context capacity") { PiNumberField(placeholder: "Tokens", value: $controller.draft.profile.contextWindow).accessibilityLabel("Configured context capacity, tokens") }
            PiRow(label: "Output budget", detail: "Room the context estimate sets aside for a reply, so a chat compacts before a reply would no longer fit. It is never sent as a limit: replies run to the model's own output ceiling.") {
                PiNumberField(placeholder: "Tokens", value: $controller.draft.profile.maxOutputTokens).accessibilityLabel("Output budget, tokens")
            }
            PiRow(label: "Model output ceiling", detail: "The catalog's limit for the chosen model, sent with every request as its output limit.", last: true) {
                Text(controller.draft.profile.modelOutputLimit.map { "\($0.formatted()) tokens" } ?? "Not supplied by the model catalog; requests carry no output limit")
                    .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            }
        }
        .background(SettingsReferenceGroupGeometry(id: .connection, geometry: geometry)).id(SettingsReferenceGroup.connection)
        PiSettingsGroup(title: "Reasoning continuation", footer: "Portable history supports changing router models. It sends visible text and tool calls/results; original signed/encrypted reasoning stays in history. Preserving native state requires a compatible route guaranteed by your gateway.") {
            PiRow(label: "Policy", last: controller.draft.replayPolicy != "pinned") {
                PiDropdown(selection: $controller.draft.replayPolicy, items: [("portable", "Portable text and tool history"), ("pinned", "Preserve native state on a fixed route"), ("ask", "Ask before replaying native state")], compact: true, accessibilityName: "Reasoning continuation policy")
            }
            if controller.draft.replayPolicy == "pinned" {
                PiRow(label: "Expected reported model") { PiTextField(placeholder: "model id", text: $controller.draft.expectedModel, mono: true).accessibilityLabel("Expected reported model") }
                PiRow(label: "Fixed-route compatibility contract", last: true) { PiTextField(placeholder: "reference", text: $controller.draft.replayContract).accessibilityLabel("Fixed-route compatibility contract") }
            }
        }
        .background(SettingsReferenceGroupGeometry(id: .reasoning, geometry: geometry)).id(SettingsReferenceGroup.reasoning)
        PiSettingsGroup(title: "Gateway model and cache metadata contract", footer: "The response model is recorded automatically. Only configure headers documented for your deployment. An opaque deployment ID or route group is not an actual model name. Use a header reporting true/false or hit/miss; a cache key alone is not evidence of a hit.") {
            PiRow(label: "Deployment/version contract reference") { PiTextField(placeholder: "reference", text: $controller.draft.metadataReference).accessibilityLabel("Deployment/version contract reference") }
            PiRow(label: "Actual model header") { PiTextField(placeholder: "optional", text: $controller.draft.modelHeader, mono: true).accessibilityLabel("Actual model header") }
            PiRow(label: "Deployment ID header") { PiTextField(placeholder: "optional", text: $controller.draft.deploymentHeader, mono: true).accessibilityLabel("Deployment ID header") }
            PiRow(label: "Route group header") { PiTextField(placeholder: "optional", text: $controller.draft.groupHeader, mono: true).accessibilityLabel("Route group header") }
            PiRow(label: "Cache hit/miss header", last: true) { PiTextField(placeholder: "optional", text: $controller.draft.cacheHeader, mono: true).accessibilityLabel("Cache hit/miss header") }
        }
        .background(SettingsReferenceGroupGeometry(id: .metadata, geometry: geometry)).id(SettingsReferenceGroup.metadata)
        PiSettingsGroup(title: "Gateway routing", footer: "Off sends disable_fallbacks with every request, so a failing route returns its error and the report shows the requested model unanswered. On lets LiteLLM answer from its configured fallback models.") {
            PiRow(label: "Allow fallback models", last: true) { Toggle("", isOn: $controller.draft.allowFallbacks).labelsHidden().accessibilityLabel("Allow fallback models") }
        }
        .background(SettingsReferenceGroupGeometry(id: .routing, geometry: geometry)).id(SettingsReferenceGroup.routing)
        PiSettingsGroup(title: "Model capabilities", footer: "JSON: reasoning, thinkingLevel, thinkingLevelMap, input, cost, samplingParams and compat. Default thinking leaves effort unspecified. Configure conservative capacity for a router alias.") {
            NativeCodeEditor(text: $controller.draft.advanced).frame(height: 130).padding(PiSpacing.sm)
        }
        .background(SettingsReferenceGroupGeometry(id: .capabilities, geometry: geometry)).id(SettingsReferenceGroup.capabilities)
    }
}

@MainActor private struct SettingsCatalogMenuV119Reference: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var controller: ConnectionSettingsController
    @ObservedObject private var catalog: ModelCatalog
    var miniSelection = false
    init(model: WorkspaceModel, controller: ConnectionSettingsController, miniSelection: Bool = false) {
        self.model = model; self.controller = controller; self.catalog = model.modelCatalog; self.miniSelection = miniSelection
    }
    var body: some View {
        let listing = controller.listingProfile
        let entry = catalog.entry(for: listing)
        let draft = controller.draft
        Button {} label: {
            HStack(spacing: 5) {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 11, weight: .semibold))
                Text(miniSelection ? (draft.profile.miniModelId ?? "Catalog default") : "Choose")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if entry.loading { PiSpinner(controlSize: .mini) }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.piInkTertiary)
            }
            .foregroundStyle(Color.piInk).padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.piSurface, in: Capsule()).overlay(Capsule().stroke(Color.piHairlineStrong, lineWidth: 1)).contentShape(Capsule())
        }
        .buttonStyle(.plain).piPointer().disabled(!controller.supportedAPI)
        .help(controller.supportedAPI ? "Search every model from the bundled Bello catalog or this connection's custom catalog." : "Choose Use Responses above to list models.")
        .accessibilityLabel(miniSelection ? "Mini model: \(draft.profile.miniModelId ?? "Catalog default")" : "Choose connection model")
        .accessibilityIdentifier(miniSelection ? "settings-mini-model-menu" : "settings-model-menu")
    }
}
