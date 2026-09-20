import SwiftUI
import AppKit

/// Composer pills for the per-chat connection, model and reasoning choices
/// (contract H3). The model list comes from the shared catalog; manual entry
/// always works. The connection pill appears once more than one Responses
/// connection is saved, or when the chat's connection is unusable.
/// What the three pills are drawn from, worked out once so the bar can
/// measure them and the pills can draw them without asking twice.
struct ModelSwitchPillContents: Equatable {
    /// The connection pill appears once more than one Responses connection is
    /// saved, or when the chat's connection is unusable.
    var showsConnection = false
    var connection = ""
    var model = ""
    var effort = ""
    /// The model pill carries a spinner while its catalog loads.
    var loading = false
}

struct ModelSwitchPills: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    @ObservedObject private var catalog: ModelCatalog
    /// How much of itself the group shows, decided by the bar that holds it.
    var form: ComposerPillsForm = .named
    @State private var showingModels = false
    @State private var presentedProfile: ProfileRecord?
    init(model: WorkspaceModel, session: SessionDisplay, form: ComposerPillsForm = .named) {
        self.model = model; self.session = session; self.catalog = model.modelCatalog; self.form = form
    }
    private var chat: ChatRecord? { model.record(session.id) }
    private var profile: ProfileRecord? { chat.flatMap { item in model.profiles.first { $0.id == item.profileID } } }
    private var override: String? { TurnOverrides.normalizedModel(chat?.model) }
    private var level: ThinkingLevel { chat?.thinkingLevel.flatMap(ThinkingLevel.init(rawValue:)) ?? .profileDefault }
    private var modelLabel: String { override ?? profile?.modelId ?? "Model" }
    /// The strings and flags the bar measures, from the same places the pills
    /// read them, so a measurement can never describe a different pill.
    @MainActor static func contents(model: WorkspaceModel, session: SessionDisplay) -> ModelSwitchPillContents {
        let pills = ModelSwitchPills(model: model, session: session)
        return ModelSwitchPillContents(showsConnection: pills.showsConnectionPill,
                                       connection: pills.profile?.name ?? "No connection",
                                       model: pills.modelLabel,
                                       effort: pills.level.pillLabel,
                                       loading: pills.profile.map { model.catalogEntry(for: $0).loading } ?? false)
    }
    var body: some View {
        // The pills give up detail before they push the send button off the
        // bar, and they give it up in the order of what the reader needs to
        // see: the model they are talking to is the last label to go. Which
        // form that is was three trial layouts of this whole group inside
        // three more of the run controls; `ComposerBarMetrics` measures the
        // strings once and this builds the one rung that fits.
        HStack(spacing: ComposerBarMetrics.spacing) {
            if showsConnectionPill { connectionPill(compact: form.connectionIsCompact) }
            modelPill(maxWidth: form.modelWidth, compact: form.modelIsCompact)
            effortPill(compact: form.effortIsCompact)
        }
        // A pane that narrows past a rung takes the labels away; they go by
        // fading, not by disappearing between two frames.
        .piAnimation(PiMotion.base, value: form)
        .disabled(session.loading || model.installPreparing || chat == nil)
        .accessibilityElement(children: .contain)
        // A visible picker must load without requiring mouse hover (including
        // keyboard access). Key on the saved profile so catalog edits reload
        // only this connection; ModelCatalog shares requests and applies TTLs.
        .task(id: profile.map { model.catalogProfile(for: $0) }) {
            if let profile { _ = await model.listModels(for: profile) }
        }
    }

    private func modelPill(maxWidth: CGFloat, compact: Bool) -> some View {
        let entry = profile.map { model.catalogEntry(for: $0) } ?? ModelCatalog.Entry()
        return Button {
            if !showingModels { presentedProfile = profile }
            showingModels.toggle()
        } label: {
            PillLabel(icon: "cpu", text: modelLabel, active: override != nil, loading: entry.loading, maxWidth: maxWidth, compact: compact)
        }
        .buttonStyle(.plain).fixedSize().piPointer()
        .popover(isPresented: $showingModels, arrowEdge: .top) {
            if let profile = profile ?? presentedProfile, let chat {
                CatalogModelPicker(model: model, profile: profile, current: modelLabel, allowsCatalogSelection: true,
                                   defaultTitle: "Use connection default · \(profile.modelId)", defaultSelected: override == nil,
                                   useDefault: { showingModels = false; Task { await model.setModel(nil, for: chat.id) } },
                                   manualEntry: { alias in showingModels = false; Task { await model.setModel(alias.isEmpty ? nil : alias, for: chat.id) } }) { item in
                    showingModels = false
                    Task { await model.setModel(item.id, for: chat.id) }
                }
            }
        }
        .onChange(of: chat?.id) { _, _ in showingModels = false; presentedProfile = nil }
        .help((override.map { "Model override for this chat: \($0). Profile default: \(profile?.modelId ?? "")." } ?? "Model from the profile.") + " Your choice is remembered for new chats using this connection.")
        .accessibilityLabel("Model: \(modelLabel)")
        .accessibilityIdentifier("session-model-picker")
    }

    private var showsConnectionPill: Bool {
        model.requestProfiles.count > 1 || profile == nil || profile?.api != LiteLLMConfiguration.supportedAPI
    }
    private func connectionPill(compact: Bool) -> some View {
        let blocker = chat.flatMap { model.connectionSwitchBlocker(for: $0.id) }
        return PiChoicePicker(title: "Connection", selection: chat?.profileID,
                              choices: model.requestProfiles.map { candidate in
                                  PiChoice(id: candidate.id, title: candidate.name, subtitle: candidate.modelId,
                                           enabled: blocker == nil || candidate.id == chat?.profileID)
                              }, note: blocker, actionTitle: "Manage Connections…",
                              action: { model.showProfiles = true }, choose: { id in
                                  guard let chat else { return }
                                  Task { await model.setConnection(id, for: chat.id) }
                              }) {
            PillLabel(icon: "antenna.radiowaves.left.and.right", text: profile?.name ?? "No connection", active: profile == nil, loading: false, maxWidth: 150, compact: compact)
        }
        .fixedSize()
        .help("The LiteLLM connection, key and model list this chat uses. Switching closes its helper session; the next turn replays the chat's portable history on the new connection.")
        .accessibilityLabel("Connection: \(profile?.name ?? "none")")
        .accessibilityIdentifier("session-connection-picker")
    }

    /// The effort pill's label says whose default is in force ("Effort ·
    /// connection default"), which needs more room than the word "default"
    /// did: at 130 points the widest of them was truncated down the middle.
    static let effortLabelWidth: CGFloat = 176
    private func effortPill(maxWidth: CGFloat = ModelSwitchPills.effortLabelWidth, compact: Bool) -> some View {
        let levels = offeredLevels
        let note = !levels.contains(level) ? "Current effort is unavailable for this model. Choose another level." :
            levels.count < ThinkingLevel.allCases.count ? "Levels from the model catalog" : nil
        return PiChoicePicker(title: "Reasoning effort", selection: level,
                              choices: levels.map { PiChoice(id: $0, title: $0.label) },
                              note: note, choose: { option in
                                  guard let chat else { return }
                                  Task { await model.setThinkingLevel(option.rawValue, for: chat.id) }
                              }) {
            PillLabel(icon: "brain", text: level.pillLabel, active: level != .profileDefault, loading: false, maxWidth: maxWidth, compact: compact)
        }
        .fixedSize()
        .help("Profile default keeps the connection's effort. Model default leaves effort unspecified. Your choice is remembered for new chats using this connection.")
        .accessibilityLabel("Reasoning effort: \(level.label)")
        .accessibilityIdentifier("session-reasoning-picker")
    }

    /// "GPT-5.1 · 400k ctx" or the bare alias, with a deprecation note.
    static func menuTitle(_ item: ModelDescriptor) -> String {
        var parts = [item.displayName]
        if item.displayName != item.id { parts.append(item.id) }
        if let context = item.contextLabel { parts.append(context) }
        if item.deprecated { parts.append("deprecated") }
        return parts.joined(separator: " · ")
    }
    /// Efforts the effective model accepts per the catalog; every level when unknown.
    private var offeredLevels: [ThinkingLevel] {
        guard let profile, let descriptor = model.catalogEntry(for: profile).descriptor(for: override ?? profile.modelId) else { return ThinkingLevel.allCases }
        var levels = descriptor.offeredThinkingLevels
        if let efforts = descriptor.reasoning {
            let inherited = profile.configuration["thinkingLevel"]?.string
            if efforts.isEmpty && profile.configuration["reasoning"]?.bool == true ||
                inherited.map({ $0 != "default" && !efforts.contains($0) }) == true {
                levels.removeAll { $0 == .profileDefault }
            }
        }
        return levels
    }
}

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
                if loading { ProgressView().controlSize(.small) }
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
                Menu("Choose a saved catalog") {
                    ForEach(choices) { candidate in
                        Button("\(candidate.name) · \(Self.sourceLabel(candidate))") {
                            Task { await refresh.selectSource(model: model, sourceID: candidate.id, profileID: profile.id) }
                        }
                    }
                }.accessibilityIdentifier("repair-model-catalog")
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

/// Compact pill label matching PiDropdown; the text cross-fades when it changes
/// and the stroke warms up while an override is active.
private struct PillLabel: View {
    let icon: String
    let text: String
    let active: Bool
    let loading: Bool
    let maxWidth: CGFloat
    /// Icon and chevron only, for a bar too narrow for labels; the help text still names the value.
    var compact = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(active ? Color.piAccent : Color.piInkSecondary)
            if !compact {
                Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: maxWidth, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity).id(text)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            if loading { ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 10).transition(.opacity) }
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.piInkTertiary)
        }
        .padding(.horizontal, compact ? 7 : 9).padding(.vertical, 4)
        .background(active ? Color.piAccentSoft : Color.piSurface, in: Capsule())
        .overlay(Capsule().stroke(active ? Color.piAccent.opacity(0.45) : Color.piHairlineStrong, lineWidth: 1))
        .contentShape(Capsule())
        .opacity(enabled ? 1 : 0.45)
        .animation(.easeInOut(duration: 0.18), value: text)
        .animation(.easeInOut(duration: 0.18), value: active)
        .animation(.easeInOut(duration: 0.15), value: loading)
    }
}
