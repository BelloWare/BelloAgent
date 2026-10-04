import SwiftUI
import AppKit

// TEMPORARY: still SwiftUI. The composer's model pill shows it in an AppKit
// popover through a hosting controller, and Settings shows it as before,
// until it is ported with Settings.

/// A live native catalog view. Unlike a tracking NSMenu snapshot, its contents
/// update while a fetch is in flight. Opening it always checks the source's TTL,
/// whether invoked with the pointer or keyboard. Search includes every model,
/// not just a first menu page.
struct CatalogModelPicker: View {
    /// A connection as the Settings sheet edits it: listed on its own, with the key typed there.
    struct DraftListing: Equatable { var profile: ProfileRecord; var key: String }
    @ObservedObject var model: WorkspaceModel
    @ObservedObject private var catalog: ModelCatalog
    let profile: ProfileRecord
    let current: String?
    var draft: DraftListing? = nil
    var allowsCatalogSelection = false
    var defaultTitle: String?
    var defaultSelected = false
    var useDefault: (() -> Void)?
    /// Called with an alias typed into the picker; empty means the connection default.
    var manualEntry: ((String) -> Void)?
    let choose: (ModelDescriptor) -> Void
    @State private var query = ""
    @State private var enteringAlias = false
    @State private var alias = ""
    @StateObject private var refresh = ModelCatalogRefreshState()

    init(model: WorkspaceModel, profile: ProfileRecord, current: String?, draft: DraftListing? = nil, allowsCatalogSelection: Bool = false,
         defaultTitle: String? = nil, defaultSelected: Bool = false,
         useDefault: (() -> Void)? = nil, manualEntry: ((String) -> Void)? = nil,
         choose: @escaping (ModelDescriptor) -> Void) {
        self.model = model; self.catalog = model.modelCatalog; self.profile = profile; self.draft = draft
        self.current = current; self.defaultTitle = defaultTitle; self.defaultSelected = defaultSelected
        self.allowsCatalogSelection = allowsCatalogSelection
        self.useDefault = useDefault; self.manualEntry = manualEntry; self.choose = choose
    }

    var body: some View {
        // A popover can outlive a Settings/vault reload. Resolve only its own
        // saved ID, so its rows and source label follow the newly saved revision.
        // A draft being edited in Settings is listed as given, with the typed key.
        let profile = draft == nil ? (model.profiles.first(where: { $0.id == self.profile.id }) ?? self.profile) : self.profile
        let source = draft == nil ? model.catalogProfile(for: profile) : self.profile
        let entry = catalog.entry(for: source)
        let offered = entry.offered(current: current)
        let matches = Self.filtered(offered, query: query)
        let loading = refresh.loading || entry.loading
        let repairs = allowsCatalogSelection ? model.catalogRepairChoices(for: profile) : []
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ModelCatalog.catalogConfigured(source) ? "Model catalog" : "Bello model catalog").font(.headline)
                    Text(source.name).font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    Text(Self.sourceLabel(source)).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(2)
                        .accessibilityIdentifier("model-picker-source")
                }
                Spacer(minLength: 8)
                if loading { PiSpinner(controlSize: .small) }
                Button {
                    Task {
                        if let draft { await model.listModels(forDraft: draft.profile, typedKey: draft.key, force: true) }
                        else { await refresh.refresh(model: model, profileID: profile.id) }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(loading).help("Reload this saved connection and refresh its model list")
                    .accessibilityLabel("Refresh models")
                    .accessibilityIdentifier("refresh-model-catalog")
            }
            if allowsCatalogSelection, model.profiles.filter({ $0.api == LiteLLMConfiguration.supportedAPI }).count > 1 {
                if !repairs.isEmpty { catalogRepairNotice(profile: profile, choices: repairs, loading: loading) }
                sourceSelector(profile: profile, source: source, loading: loading)
            }
            PiTextField(placeholder: "Search model names or aliases", text: $query, icon: "magnifyingglass")
                .accessibilityIdentifier("model-catalog-search")
            if let defaultTitle, let useDefault {
                Button(action: useDefault) {
                    HStack {
                        Image(systemName: defaultSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(defaultSelected ? Color.piAccent : Color.piInkTertiary)
                        Text(defaultTitle).lineLimit(2)
                        Spacer()
                    }.font(PiFont.caption).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if let error = refresh.error ?? entry.error {
                VStack(alignment: .leading, spacing: 3) {
                    if !offered.isEmpty { Text("Refresh failed · showing the last list").fontWeight(.medium) }
                    Text(error)
                }.font(PiFont.caption).foregroundStyle(Color.piWarning).fixedSize(horizontal: false, vertical: true)
            }
            if matches.isEmpty {
                Text(loading ? "Loading models…" : offered.isEmpty ? "No models are listed by this connection." : "No matching models.")
                    .font(PiFont.body).foregroundStyle(Color.piInkSecondary).frame(maxWidth: .infinity, minHeight: 70)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(matches) { item in
                            Button { choose(item) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: !defaultSelected && current == item.id ? "checkmark" : "cpu")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(!defaultSelected && current == item.id ? Color.piAccent : Color.piInkTertiary)
                                        .frame(width: 14).padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                                            Text(item.displayName).font(PiFont.body).foregroundStyle(Color.piInk)
                                            if item.mini == true { Text("Mini").font(PiFont.caption).foregroundStyle(Color.piAccent) }
                                            if item.takesImages { Text("Images").font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
                                            if item.deprecated { Text("Deprecated").font(PiFont.caption).foregroundStyle(Color.piWarning) }
                                        }
                                        if item.displayName != item.id { Text(item.id).font(PiFont.mono).foregroundStyle(Color.piInkSecondary) }
                                        if !item.description.isEmpty { Text(item.description).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(2) }
                                        if let context = item.contextLabel { Text(context).font(PiFont.caption).foregroundStyle(Color.piInkTertiary) }
                                        if let output = item.outputLimitLabel { Text(output).font(PiFont.caption).foregroundStyle(Color.piInkTertiary) }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                .background(!defaultSelected && current == item.id ? Color.piAccentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("catalog-choice-\(item.id)")
                            .accessibilityLabel(ModelSwitchPills.menuTitle(item))
                        }
                    }
                }.frame(height: min(340, CGFloat(matches.count) * 68))
            }
            if let current, !current.isEmpty, !offered.contains(where: { $0.id == current }), entry.fetchedAt != nil {
                Text("Current selection “\(current)” is not listed by this source. It remains selected until you choose another model.")
                    .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("\(offered.count) models").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                if !loading, entry.error == nil, let date = entry.fetchedAt {
                    Text("Updated \(date.formatted(date: .omitted, time: .standard))")
                        .font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                        .accessibilityIdentifier("model-catalog-refreshed-at")
                }
                Spacer()
                if manualEntry != nil { Button(enteringAlias ? "Hide alias field" : "Enter alias…") { withAnimation(PiMotion.quick) { enteringAlias.toggle() } }.buttonStyle(.plain).font(PiFont.caption).accessibilityIdentifier("model-enter-alias") }
            }
            if let manualEntry, enteringAlias {
                // Any alias the gateway routes, typed here; empty returns to the connection default.
                HStack(spacing: 6) {
                    PiTextField(placeholder: profile.modelId, text: $alias, icon: "cpu", mono: true, onSubmit: { manualEntry(alias.trimmingCharacters(in: .whitespacesAndNewlines)) })
                        .accessibilityIdentifier("model-alias-field")
                    Button("Use") { manualEntry(alias.trimmingCharacters(in: .whitespacesAndNewlines)) }.buttonStyle(.piPrimaryCompact).fixedSize()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if !ModelCatalog.catalogConfigured(source) {
                Text("Included models change with app updates. Choose a saved custom catalog above or set its URL in Settings.")
                    .font(PiFont.caption).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).frame(width: 390).background(Color.piSurface)
        .task(id: [source.id, source.baseUrl, source.catalogUrl ?? "", draft?.key ?? ""]) {
            if let draft { await model.listModels(forDraft: draft.profile, typedKey: draft.key) } else { await model.listModels(for: profile) }
        }
        .onChange(of: profile.id) { _, _ in query = "" }
        .onChange(of: source.id) { _, _ in query = "" }
    }

    private func catalogRepairNotice(profile: ProfileRecord, choices: [ProfileRecord], loading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This chat uses its original model list.")
                .font(PiFont.caption.weight(.semibold)).foregroundStyle(Color.piInk)
            Text("Another catalog is saved for this gateway. Refresh reloads the list shown above.")
                .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            if choices.count == 1, let candidate = choices.first {
                Text("Available: \(candidate.name) · \(Self.sourceLabel(candidate))")
                    .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(2)
                Button("Use this catalog") {
                    Task { await refresh.selectSource(model: model, sourceID: candidate.id, profileID: profile.id) }
                }.accessibilityIdentifier("repair-model-catalog")
            } else {
                PiMenuButton(title: "Choose a saved catalog", icon: "list.bullet.rectangle", identifier: "repair-model-catalog") { [refresh, model] in
                    for candidate in choices {
                        PiMenuEntry.button("\(candidate.name) · \(Self.sourceLabel(candidate))") {
                            Task { await refresh.selectSource(model: model, sourceID: candidate.id, profileID: profile.id) }
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.piAccentSoft, in: RoundedRectangle(cornerRadius: 8))
        .disabled(loading)
        .help("Changes only the catalog for this connection's chats. Requests keep their existing connection, key, model and effort.")
        .accessibilityIdentifier("model-catalog-mismatch")
    }

    private func sourceSelector(profile: ProfileRecord, source: ProfileRecord, loading: Bool) -> some View {
        let choices = [PiChoice(id: profile.id, title: "Saved with this connection", subtitle: Self.sourceLabel(profile))] +
            model.profiles.filter { $0.id != profile.id && $0.api == LiteLLMConfiguration.supportedAPI && model.catalogProfile(for: $0).id == $0.id }
                .map { PiChoice(id: $0.id, title: $0.name, subtitle: Self.sourceLabel($0)) }
        return PiChoicePicker(title: "Catalog source", selection: source.id, choices: choices, choose: { id in
            Task { await refresh.selectSource(model: model, sourceID: id, profileID: profile.id) }
        }) {
            Label("Catalog source…", systemImage: "list.bullet.rectangle")
                .font(PiFont.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(loading)
        .help("Choose the model list for chats using this connection. The request connection, credentials and selected model stay the same.")
        .accessibilityIdentifier("select-model-catalog-source")
    }

    static func filtered(_ models: [ModelDescriptor], query: String) -> [ModelDescriptor] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return models }
        return models.filter {
            $0.id.localizedCaseInsensitiveContains(query) || $0.displayName.localizedCaseInsensitiveContains(query) ||
            $0.description.localizedCaseInsensitiveContains(query)
        }
    }

    /// Deliberately omit query values: catalog URLs may contain access tokens.
    static func sourceLabel(_ profile: ProfileRecord) -> String {
        guard ModelCatalog.catalogConfigured(profile) else { return "Included with Bello Agent" }
        let value = profile.catalogUrl ?? ""
        guard let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host else { return "Saved connection source" }
        return host + (parts.port.map { ":\($0)" } ?? "") + parts.path
    }
}

