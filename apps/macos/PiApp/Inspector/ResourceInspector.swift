import AppKit

@MainActor struct ResourceInspectorSource: Sendable {
    let options: @MainActor @Sendable (String) async throws -> [String: WireValue]
    let catalog: @MainActor @Sendable (String?) async -> Void
    let request: @MainActor @Sendable (String, [String: WireValue], String?) async throws -> [String: WireValue]
    static func workspace(_ model: WorkspaceModel) -> Self {
        Self(options: { try await model.editableResourceSettings(workspaceID: $0) },
             catalog: { await model.loadSkillCatalog(refresh: true, sessionID: $0) },
             request: { try await model.resourceRequest($0, params: $1, sessionID: $2) })
    }
}

/// Project resource discovery and policy, shown in a native resizable sheet.
/// The project/chat origin is fixed when the sheet opens.
@MainActor final class ResourceInspector: DashView, InheritsEnabled {
    static let size = NSSize(width: 1100, height: 800)
    let model: WorkspaceModel
    private let source: ResourceInspectorSource
    private let work = PayloadTaskScope()
    var dismiss: () -> Void
    var inheritedEnabled = true { didSet { refreshUI() } }
    private var tab = "skills", query = "", management = false, selectedID = ""
    private var searchEntries: [SkillSearch.Entry] = []
    private var detailTask: Task<Void, Never>?
    private var detailGeneration = UUID(), refreshGeneration = UUID()
    private var originID: String?, isPresented = false
    private var observing = false
    private var detail = "", bodyOffset = 0, nextBody: Double?
    private var snapshot: [String: WireValue] = [:], sourceOffset = 0, options: [String: WireValue] = [:]
    private var home = "", fallbacks = "", byteLimit = 32768, overrideBudget = false
    private var notice = "" { didSet { refreshFooter() } }
    private var policyBusy = false { didSet { refreshUI() } }
    private lazy var catalogObserver = ShellObserver { [weak self] in self?.catalogChanged() }
    private lazy var stateObserver = ShellObserver { [weak self] in self?.refreshUI() }
    private lazy var tabs = PiKit.Tabs(selection: "skills", items: [("skills", "Skills"), ("instructions", "Instruction chain"), ("settings", "Discovery settings"), ("mcp", "MCP servers")]) { [weak self] in self?.selectTab($0) }
    let done = PiKit.Button("Done", style: .secondary)
    let refreshButton = PiKit.Button("Refresh Sources", symbol: "arrow.clockwise", style: .secondary)
    private let column = PayloadColumn(spacing: PiSpacing.md, padding: NSEdgeInsets(top: PiSpacing.xl, left: PiSpacing.xl, bottom: PiSpacing.xl, right: PiSpacing.xl))
    private let status = ShellNote("", tone: .danger)
    private let footerText = ShellText("", font: PiKit.Font.caption, color: .piInkTertiary)
    private lazy var footer = ShellStack(.vertical, spacing: 4, [.view(status, .fill), .view(footerText, .fill)])
    private var sheet: PiKit.Sheet!
    let filterField = PiKit.TextField(placeholder: "Filter by name, description or path", icon: "magnifyingglass")
    let managementToggle = PiKit.Checkbox(isOn: false, label: "Show disabled / needs attention")
    private let skillList = LazyStackView(frame: .zero)
    private let skillEmpty = PiKit.TextLine(PiKit.Line("No skills match", font: PiKit.Font.caption, color: .piInkTertiary))
    private let skillGlide = PiKit.SelectionGlide()
    private let skillDetails = PayloadColumn()
    private var skillCard: NSView?, skillCardKey = ""
    private var skillEnabled: PiKit.Switch?, selectSkill: PiKit.Button?, projectPolicy: PiKit.MenuButton?
    private let sourceText = PagedTextView(text: "")
    private lazy var sourceBox = PiKit.inset(sourceText)
    private let sourceLabel = PiKit.TextLine(PiKit.Line("Skill file · from the start", font: PiKit.Font.body, color: .piInk))
    private lazy var bodyPager = PiKit.Pager(previousLabel: "Start", nextLabel: "Next", center: sourceLabel, canPrevious: false, canNext: false,
        previous: { [weak self] in self?.bodyOffset = 0; self?.loadBody() }, next: { [weak self] in guard let self else { return }; self.bodyOffset = Int(self.nextBody ?? 0); self.loadBody() })
    private lazy var skillsPage: NSView = {
        let left = PayloadEmptyOverlay(content: skillList, empty: skillEmpty)
        let split = PayloadSplit(leading: PiKit.inset(left), trailing: skillDetails, minimum: 290, ideal: 340, maximum: 430, trailingMinimum: 480)
        let row = ShellStack(.horizontal, spacing: PiSpacing.md, [.view(filterField, .fill), .view(managementToggle)])
        return PayloadColumn(items: [.view(row), .flexible(split)])
    }()
    private let instructionRows = ShellStack(.vertical, spacing: 0)
    private let instructionDetails = ShellStack(.vertical, spacing: 6)
    private let instructionEmpty = PiKit.TextLine(PiKit.Line("No instruction sources", font: PiKit.Font.caption, color: .piInkTertiary))
    private let sourceCount = PiKit.TextLine(PiKit.Line("n/a sources", font: PiKit.Font.body, color: .piInk))
    private lazy var sourcesPager = PiKit.Pager(previousLabel: "Previous Sources", nextLabel: "Next Sources", center: sourceCount, canPrevious: false, canNext: false,
        previous: { [weak self] in guard let self else { return }; self.sourceOffset = max(0, self.sourceOffset - 32); self.requestRefresh() },
        next: { [weak self] in self?.sourceOffset += 32; self?.requestRefresh() })
    private lazy var instructionsPage: NSView = {
        let list = PayloadEmptyOverlay(content: PayloadScroll(instructionRows), empty: instructionEmpty)
        return PayloadColumn(items: [.view(PiKit.card(instructionDetails, padding: PiSpacing.md)), .flexible(PiKit.inset(list)), .view(sourcesPager),
            .view(PiKit.Note("A new user turn refreshes the chain. In-flight requests retain their revision. Descendant guidance is not injected indiscriminately into unrelated directories."))])
    }()
    private let settingsColumn = ShellStack(.vertical, spacing: PiSpacing.xl, padding: NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2))
    private lazy var settingsPage = PayloadScroll(settingsColumn)
    let homeField = PiKit.TextField(placeholder: "/Users/you/.codex", mono: true)
    let fallbacksField = PiKit.TextField(placeholder: "AGENTS.md, CLAUDE.md", mono: true)
    let budgetToggle = PiKit.Switch(isOn: false, label: "")
    let budgetField = PiKit.NumberField(placeholder: "Bytes", value: 32768)
    let saveSettings = PiKit.Button("Save Discovery Settings", style: .primary)
    private lazy var mcpPage = NativeMCPInspector(model: model, source: source)
    init(model: WorkspaceModel, initialTab: String = "skills", source: ResourceInspectorSource? = nil, dismiss: @escaping () -> Void = {}) {
        self.model = model; self.source = source ?? .workspace(model); self.dismiss = dismiss; tab = initialTab
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        sheet = PiKit.Sheet("Skills, instructions and MCP", subtitle: "Discovered skills, the applied instruction chain, discovery settings and MCP servers for the selected project.", symbol: "book.closed", content: column, actions: [refreshButton, done], footer: footer)
        sheet.width = Self.size.width; sheet.height = Self.size.height
        sheet.dismiss = { @MainActor @Sendable [weak self] in self?.dismiss() }; addSubview(sheet)
        done.onPress = { [weak self] in self?.dismiss() }; refreshButton.onPress = { [weak self] in self?.requestRefresh() }
        filterField.onChange = { [weak self] value in self?.query = value; self?.reconcileSelection(); self?.refreshSkills() }
        managementToggle.labelFont = PiKit.Font.caption
        managementToggle.onChange = { [weak self] value in self?.management = value; self?.reconcileSelection(); self?.refreshSkills() }
        skillList.spacing = 2; skillList.insets = NSEdgeInsets(top: PiSpacing.sm, left: PiSpacing.sm, bottom: PiSpacing.sm, right: PiSpacing.sm)
        homeField.onChange = { [weak self] in self?.home = $0 }; fallbacksField.onChange = { [weak self] in self?.fallbacks = $0 }
        budgetToggle.setAccessibilityLabel("Override instruction byte budget")
        budgetToggle.onChange = { [weak self] value in self?.overrideBudget = value; self?.refreshSettings() }
        budgetField.onChange = { [weak self] in self?.byteLimit = $0 }
        saveSettings.onPress = { [weak self] in self?.saveDiscovery() }
        startObserving()
        refreshUI(); refreshSettings()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { Self.size }
    override func layout() { super.layout(); sheet.frame = bounds }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { prepareForRelease(); return }
        guard !isPresented else { return }; work.resume(); startObserving(); isPresented = true
        originID = model.resourceTargetSessionID ?? model.selectedID
        requestOptions(thenRefresh: true)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, window != nil { prepareForRelease() }
        super.viewWillMove(toWindow: newWindow)
    }
    func prepareForRelease() {
        isPresented = false; work.cancel(); detailTask?.cancel(); detailTask = nil
        detailGeneration = UUID(); refreshGeneration = UUID(); originID = nil
        catalogObserver.reset(); stateObserver.reset(); observing = false; mcpPage.prepareForRelease()
        searchEntries = []; snapshot = [:]; detail = ""; selectedID = ""; sourceText.text = ""; dismiss = {}
        policyBusy = false
    }
    private func startObserving() {
        guard !observing else { return }; observing = true
        catalogObserver.observe(publisher: model.$resourceCatalog)
        stateObserver.observe(publisher: model.$configuration); stateObserver.observe(publisher: model.$mcpRemovalInProgress)
    }
    private var selected: SkillDescriptor? { filtered.first { $0.id == selectedID } }
    private var filtered: [SkillDescriptor] { SkillSearch.search(searchEntries, query: query, actionable: !management) }
    private func selectTab(_ value: String) {
        guard tab != value else { return }; tab = value; refreshUI()
        if value == "settings" { requestOptions() }
    }
    private func catalogChanged() {
        guard isPresented, model.resourceCatalogSessionID == originID else { return }
        searchEntries = model.resourceCatalog.map(SkillSearch.Entry.init); reconcileSelection(); refreshSkills(); loadBody()
    }
    private func reconcileSelection() {
        if !filtered.contains(where: { $0.id == selectedID }) {
            detailTask?.cancel(); detailGeneration = UUID(); detail = ""; nextBody = nil
            selectedID = filtered.first?.id ?? ""; bodyOffset = 0; loadBody()
        }
    }
    static func policyTone(_ policy: String) -> PiTone {
        switch policy { case "implicitAllowed": .success; case "explicitOnly": .info; case "needsAttention": .warning; default: .neutral }
    }
    static func policyLabel(_ policy: String) -> String {
        switch policy {
        case "implicitAllowed": "Model may use it"
        case "explicitOnly": "Only when you ask"
        case "disabled": "Off"
        case "needsAttention": "Needs attention"
        default: policy.isEmpty ? "" : policy.prefix(1).uppercased() + policy.dropFirst()
        }
    }
    private func refreshUI() {
        tabs.selection = tab
        let page: NSView
        switch tab { case "instructions": page = instructionsPage; case "settings": page = settingsPage; case "mcp": page = mcpPage; default: page = skillsPage }
        column.items = [.view(tabs), .flexible(page, ideal: 500)]
        let enabled = inheritedEnabled && work.isActive
        done.isEnabled = enabled; refreshButton.isEnabled = enabled; sheet?.cancelDisabled = !enabled
        managementToggle.isEnabled = enabled; filterField.field.isEnabled = enabled
        for control in PiKit.controls(in: settingsColumn) { control.isEnabled = enabled }
        refreshSkills(); refreshInstructions(); refreshFooter()
        mcpPage.inheritedEnabled = enabled
    }
    private func refreshFooter() {
        status.text = notice.isEmpty ? originID.flatMap({ model.displays[$0]?.skillCatalog.notice }) ?? "" : notice
        status.isHidden = tab == "mcp" || status.text.isEmpty
        footerText.set(tab == "mcp"
            ? "Configuration can launch programs with your permissions. Invocation requires an editing chat and is serialized per project. Read-only chats can discover tools but cannot invoke them. Annotations are not authorization."
            : "Skill switches apply only to Bello Agent across all projects. Shared skill files and Codex settings are never changed. Running requests retain their frozen inputs; new and queued turns use the updated policy.", color: .piInkTertiary)
        footer.relayoutAll(); sheet?.needsLayout = true
    }
    private func refreshSkills() {
        managementToggle.isOn = management
        let skills = filtered
        skillEmpty.line.text = emptyNotice; skillEmpty.isHidden = !skills.isEmpty
        skillList.reload(.init(count: skills.count, key: { skills[$0].id }, height: { index, width in ResourceSkillRow.height(skills[index], width: width) }, view: { [weak self] index, existing in
            guard let self else { return NSView() }; let skill = skills[index]
            let key = ResourceSkillRow.key(skill)
            let row = (existing as? ResourceSkillRow).flatMap { $0.contentKey == key ? $0 : nil }
                ?? ResourceSkillRow(skill: skill, glide: self.skillGlide) { [weak self] in guard let self, self.selectedID != skill.id else { return }; self.selectedID = skill.id; self.bodyOffset = 0; self.loadBody(); self.refreshSkills() }
            row.row.selected = self.selectedID == skill.id; row.row.isEnabled = self.inheritedEnabled; return row
        }))
        var items: [PayloadColumn.Item] = []
        if let skill = selected {
            let key = ResourceSkillRow.key(skill) + "|" + skill.reasons.joined(separator: "|") + "|" + String(describing: skill.missingDependencies)
            if skillCardKey != key {
                skillCardKey = key
                let enabled = PiKit.Switch(isOn: model.skillEnabledInBelloAgent(skill.id), label: "Enabled in Bello Agent") { [weak self] in self?.setEnabled(skill, enabled: $0) }
                enabled.toolTip = "Applies across Bello Agent projects. Enabling does not override Codex or project restrictions."
                let select = PiKit.Button("Select for Draft", symbol: "plus.circle", style: .primary) { [weak self] in
                    guard let self, let view = self.originID.flatMap({ self.model.displays[$0] }) else { return }
                    if self.model.addSkill(skill, view: view) { self.dismiss() }
                }
                let policy = PiKit.MenuButton(title: "Project Policy", icon: "checkmark.shield", identifier: "skill-project-policy") { [weak self] in
                    PiMenuEntry.button("Explicit Only") { self?.policy(skill, key: "explicitOnly", enabled: true) }
                    PiMenuEntry.button("Remove App Explicit-only Override") { self?.policy(skill, key: "explicitOnly", enabled: false) }
                    PiMenuEntry.divider
                    PiMenuEntry.button("Disable for This Project") { self?.policy(skill, key: "disabled", enabled: true) }
                    PiMenuEntry.button("Remove Project Disable Override") { self?.policy(skill, key: "disabled", enabled: false) }
                }
                var rows: [ShellItem] = [
                    .view(ShellText(skill.description.isEmpty ? "No description" : skill.description, font: PiKit.Font.body, color: .piInk), .fill),
                    .view(PiKit.KeyValue(key: "Path", value: skill.path, mono: true), .fill), .view(PiKit.KeyValue(key: "SHA-256", value: skill.contentHash, mono: true), .fill),
                    .view(enabled), .view(ShellText("Other source and project restrictions still apply. A disabled skill is removed from suggestions and unsent selections.", font: PiKit.Font.caption, color: .piInkSecondary), .fill)]
                if !skill.reasons.isEmpty { rows.append(.view(PiKit.KeyValue(key: "Policy reasons", value: skill.reasons.joined(separator: "\n")), .fill)) }
                if !skill.missingDependencies.isEmpty { rows.append(.view(PiKit.Note("Unavailable dependencies: " + skill.missingDependencies.map { ($0["type"] ?? "") + ":" + ($0["value"] ?? "") }.joined(separator: ", "), tone: .warning), .fill)) }
                rows.append(.view(ShellStack(.horizontal, spacing: PiSpacing.sm, padding: NSEdgeInsets(top: 2, left: 0, bottom: 0, right: 0), [.view(select), .view(policy), .spacer(0)]), .fill))
                skillCard = PiKit.card(ShellStack(.vertical, spacing: 6, rows), padding: PiSpacing.md)
                skillEnabled = enabled; selectSkill = select; projectPolicy = policy
            }
            skillEnabled?.isOn = model.skillEnabledInBelloAgent(skill.id); skillEnabled?.isEnabled = !policyBusy && inheritedEnabled
            projectPolicy?.isEnabled = !policyBusy && inheritedEnabled
            selectSkill?.isEnabled = inheritedEnabled && (originID.flatMap({ model.displays[$0] }).map { model.canSelectSkill(skill, view: $0) && $0.skills.count < 8 && !$0.skills.contains(where: { $0.id == skill.id }) } ?? false)
            if let skillCard { items.append(.view(skillCard)) }
        } else { skillCardKey = ""; skillCard = nil }
        sourceText.text = detail
        sourceLabel.line.text = bodyOffset == 0 ? "Skill file · from the start" : "Skill file · continued"
        sourceLabel.toolTip = "Reading the skill file from character \(bodyOffset)"
        bodyPager.canPrevious = bodyOffset != 0 && inheritedEnabled; bodyPager.canNext = nextBody != nil && inheritedEnabled
        items += [.flexible(sourceBox), .view(bodyPager)]
        skillDetails.items = items
    }
    private func refreshInstructions() {
        instructionDetails.items = [.view(PiKit.TextLine(PiKit.Line("Global → project root → working directory → explicitly approved additions", font: PiKit.Font.heading, color: .piInk))),
            .view(PiKit.KeyValue(key: "Root", value: snapshot["root"]?.string ?? "", mono: true), .fill), .view(PiKit.KeyValue(key: "Codex home", value: snapshot["codexHome"]?.string ?? "", mono: true), .fill),
            .view(PiKit.KeyValue(key: "Included", value: "\(snapshot["instructionBytes"]?.nonnegativeInteger.map(String.init) ?? "n/a") / \(snapshot["instructionLimit"]?.nonnegativeInteger.map(String.init) ?? "n/a") UTF-8 bytes"), .fill),
            .view(PiKit.KeyValue(key: "Applied revision", value: snapshot["appliedRevision"]?.string ?? "No turn yet", mono: true), .fill)]
        let sources = snapshot["sources"]?.array ?? []
        instructionEmpty.isHidden = !sources.isEmpty
        instructionRows.items = sources.enumerated().flatMap { index, source in [.view(InstructionSourceRow(position: sourceOffset + index + 1, source: source.object ?? [:]), .fill), .view(PayloadHairline(), .fill)] }
        sourceCount.line.text = "\(snapshot["sourceCount"]?.nonnegativeInteger.map(String.init) ?? "n/a") sources"
        sourcesPager.canPrevious = sourceOffset > 0 && inheritedEnabled
        sourcesPager.canNext = sourceOffset + 32 < (snapshot["sourceCount"]?.nonnegativeInteger ?? 0) && inheritedEnabled
    }
    private func refreshSettings() {
        homeField.text = home; fallbacksField.text = fallbacks; budgetToggle.isOn = overrideBudget; budgetField.value = byteLimit
        var rows = [PiKit.Row(label: "Codex home", detail: "Absolute path", control: homeField), PiKit.Row(label: "Fallback basenames", detail: "Comma separated; blank uses config.toml", control: fallbacksField), PiKit.Row(label: "Override instruction byte budget", last: !overrideBudget, control: budgetToggle)]
        if overrideBudget { rows.append(PiKit.Row(label: "Combined source byte limit", detail: "0–262144", last: true, control: budgetField)) }
        var groups: [ShellItem] = [.view(PiKit.SettingsGroup(title: "Discovery", footer: "Default discovery includes user and project .agents/skills. No scripts or downloads run during discovery. Arbitrary Pi extensions are not loaded.", rows: rows), .fill)]
        for key in ["extraSkillPaths", "piSkillPaths", "piInstructionPaths"] {
            let paths = options[key]?.array?.compactMap(\.string) ?? []
            var rows: [PiKit.Row] = []
            if paths.isEmpty { rows.append(PiKit.Row(label: "No approved paths", last: true, control: PiKit.Button("Add Approved Path…", style: .secondary, compact: true) { [weak self] in self?.addPath(key) })) }
            for (index, path) in paths.enumerated() {
                var actions: [ShellItem] = []
                if index == paths.count - 1 { actions.append(.view(PiKit.Button("Add…", style: .secondary, compact: true) { [weak self] in self?.addPath(key) })) }
                actions.append(.view(PiKit.IconButton(symbol: "minus.circle", label: "Remove", size: 24) { [weak self] in guard let self else { return }; self.options[key] = .array((self.options[key]?.array ?? []).filter { $0.string != path }); self.refreshSettings() }))
                rows.append(PiKit.Row(label: path, last: index == paths.count - 1, control: ShellStack(.horizontal, spacing: 4, actions)))
            }
            groups.append(.view(PiKit.SettingsGroup(title: key, rows: rows), .fill))
        }
        groups.append(.view(saveSettings)); settingsColumn.items = groups
        for control in PiKit.controls(in: settingsColumn) { control.isEnabled = inheritedEnabled }
        settingsPage.needsLayout = true
    }
    private func saveDiscovery() {
        guard work.isActive, inheritedEnabled else { return }
        var values = options
        values["codexHome"] = .string(home)
        values["fallbackNames"] = fallbacks.trimmingCharacters(in: .whitespaces).isEmpty ? nil : .array(fallbacks.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) })
        values["maxInstructionBytes"] = overrideBudget ? .number(Double(byteLimit)) : nil
        let saved = values, model = model, origin = originID
        work.run({ try await model.saveResourceSettings(saved, sessionID: origin) }) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success: self.options = saved; self.notice = "Saved. New user turns use the new settings."; self.requestRefresh()
            case .failure(let error): self.notice = error.localizedDescription
            }
        }
    }
    private func applyOptions(_ loaded: [String: WireValue]) {
        options = loaded
        home = options["codexHome"]?.string ?? ""; fallbacks = options["fallbackNames"]?.array?.compactMap(\.string).joined(separator: ", ") ?? ""
        byteLimit = options["maxInstructionBytes"]?.nonnegativeInteger ?? 32768; overrideBudget = options["maxInstructionBytes"] != nil
        refreshSettings()
    }
    private func requestOptions(thenRefresh: Bool = false) {
        guard work.isActive else { return }
        let origin = originID, source = source
        guard let id = origin.flatMap(model.record)?.workspaceID ?? model.selectedWorkspaceID else {
            applyOptions(options); if thenRefresh { requestRefresh() }; return
        }
        work.run({ (try? await source.options(id)) ?? [:] }) { [weak self] outcome in
            guard let self, self.isPresented, origin == self.originID else { return }
            if case .success(let loaded) = outcome { self.applyOptions(loaded) }
            if thenRefresh { self.requestRefresh() }
        }
    }
    private func addPath(_ key: String) {
        guard work.isActive, inheritedEnabled else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = key != "piInstructionPaths"; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.message = "Approve read-only resource discovery."
        let window = window
        work.run({ [weak window] in await PiQuestion.shared.open(panel, over: window) }) { [weak self] outcome in
            guard let self, case .success(let chosen) = outcome, !chosen.isEmpty else { return }
            var paths = self.options[key]?.array?.compactMap(\.string) ?? []
            for url in chosen where !paths.contains(url.path) { paths.append(url.path) }
            self.options[key] = .array(paths.prefix(32).map(WireValue.string)); self.refreshSettings()
        }
    }
    private func policy(_ skill: SkillDescriptor, key: String, enabled: Bool) {
        guard work.isActive, inheritedEnabled, !policyBusy else { return }; policyBusy = true
        let model = model, origin = originID, source = source, saved = options
        let workspace = origin.flatMap(model.record)?.workspaceID ?? model.selectedWorkspaceID
        work.run({
            var options = saved
            if let workspace { options = (try? await source.options(workspace)) ?? [:] }
            try Task.checkCancellation()
            var ids = Set(options[key]?.array?.compactMap(\.string) ?? [])
            if enabled { ids.insert(skill.id) } else { ids.remove(skill.id) }; options[key] = .array(ids.sorted().map(WireValue.string))
            try await model.saveResourceSettings(options, sessionID: origin)
            return options
        }) { [weak self] outcome in
            guard let self else { return }; defer { self.policyBusy = false }
            switch outcome { case .success(let saved): self.applyOptions(saved); self.requestRefresh(); case .failure(let error): self.notice = error.localizedDescription }
        }
    }
    private func setEnabled(_ skill: SkillDescriptor, enabled: Bool) {
        guard work.isActive, inheritedEnabled, !policyBusy else { return }; policyBusy = true
        let model = model, source = source
        let workspace = originID.flatMap(model.record)?.workspaceID ?? model.selectedWorkspaceID
        work.run({ () async throws -> [String: WireValue]? in
            try await model.setSkillEnabledInBelloAgent(skill, enabled: enabled); try Task.checkCancellation()
            if let workspace { return (try? await source.options(workspace)) ?? [:] }
            return nil as [String: WireValue]?
        }) { [weak self] outcome in
            guard let self else { return }; defer { self.policyBusy = false }
            switch outcome {
            case .success(let loaded):
                if !enabled { self.management = true }
                self.notice = enabled ? "Enabled in Bello Agent. Source and project policies still apply." : "Disabled in Bello Agent across all projects. Codex is unchanged."
                if let loaded { self.applyOptions(loaded) }; self.requestRefresh()
            case .failure(let error): self.notice = error.localizedDescription
            }
        }
    }
    private func requestRefresh() {
        guard work.isActive, isPresented else { return }
        let model = model, source = source, origin = originID, offset = sourceOffset, generation = UUID(); refreshGeneration = generation
        work.run({
            await source.catalog(origin); try Task.checkCancellation()
            let catalog = origin.flatMap { model.displays[$0]?.skillCatalog }
            let page = try await source.request("resources.inspect", ["sourceOffset": .number(Double(offset)), "refresh": .bool(true)], origin)
            return (page, catalog?.entries, catalog?.notice)
        }) { [weak self] outcome in
            guard let self, self.isPresented, origin == self.originID, generation == self.refreshGeneration, offset == self.sourceOffset else { return }
            switch outcome {
            case .success(let (page, entries, notice)):
                if let entries { self.searchEntries = entries; self.notice = notice ?? "" }
                self.snapshot = page; self.reconcileSelection(); self.loadBody(); self.refreshUI()
            case .failure(let error): self.notice = error.localizedDescription
            }
        }
    }
    private var emptyNotice: String {
        switch originID.flatMap({ model.displays[$0]?.skillCatalog.state }) {
        case .loading: "Discovering skills…"
        case .failed: "Skill discovery failed. Refresh Sources to retry."
        case .partial: "No matches in the discovered sources. See discovery details below."
        default: "No skills match"
        }
    }
    private func loadBody() {
        guard work.isActive, isPresented else { return }
        detailTask?.cancel(); let generation = UUID(); detailGeneration = generation
        let id = selectedID, offset = bodyOffset, origin = originID
        guard !id.isEmpty else { detail = "Select a skill to inspect its source and policy."; nextBody = nil; refreshSkills(); return }
        let hash = selected?.contentHash, metadata = selected?.metadataHash
        detail = "Loading skill source…"; nextBody = nil; refreshSkills()
        let source = source
        detailTask = work.run({ try await source.request("resources.skill.read", ["skillId": .string(id), "offset": .number(Double(offset))], origin) }) { [weak self] outcome in
            guard let self, generation == self.detailGeneration, id == self.selectedID, offset == self.bodyOffset, origin == self.originID, hash == self.selected?.contentHash, metadata == self.selected?.metadataHash else { return }
            switch outcome { case .success(let page): self.detail = page["text"]?.string ?? ""; self.nextBody = page["next"]?.number; case .failure(let error): self.detail = error.localizedDescription }
            self.refreshSkills()
        }
    }
}

/// Vault-backed MCP discovery/invocation. Refreshing controls never starts a
/// helper; removing the saved servers clears the list without reconnecting.
@MainActor final class NativeMCPInspector: DashView, InheritsEnabled {
    let model: WorkspaceModel
    private let source: ResourceInspectorSource
    private let work = PayloadTaskScope()
    var inheritedEnabled = true { didSet { refreshUI() } }
    private var servers: [String] = [], server = "", tool = "", tools: [[String: WireValue]] = []
    private var targets = "[]", arguments = "{}", result = "", notice = "", configuration = "{\"servers\":{}}"
    private var editingConfiguration = false, configurationRevision: Int64 = 0, configurationProject: String?
    private var busy = false, unknown = false, started = false, confirmationPending = false
    private var observing = false
    private lazy var observer = ShellObserver { [weak self] in self?.refreshUI() }
    let edit = PiKit.Button("Edit Vault Configuration…", symbol: "key", style: .secondary)
    let refresh = PiKit.Button("Refresh Servers", symbol: "arrow.clockwise", style: .secondary)
    let remove = PiKit.Button("Remove All MCP Servers…", symbol: "trash", style: .ghost)
    let save = PiKit.Button("Save and Connect…", style: .primary)
    let cancelEdit = PiKit.Button("Cancel Editing", style: .ghost)
    let listTools = PiKit.Button("List Tools", symbol: "list.bullet", style: .secondary)
    let describe = PiKit.Button("Describe Selected Tools", style: .secondary, compact: true)
    let invokeButton = PiKit.Button("Invoke One Tool…", style: .secondary, compact: true)
    let acknowledgeButton = PiKit.Button("I Reviewed the Previous Invocation’s Effects…", style: .secondary, compact: true)
    let serverField = PiKit.TextField(placeholder: "One server", mono: true)
    let toolField = PiKit.TextField(placeholder: "One tool", mono: true)
    let configurationEditor = NativeCodeEditorView()
    let targetsEditor = NativeCodeEditorView(text: "[]", accessibilityLabel: "Schema targets JSON")
    let argumentsEditor = NativeCodeEditorView(text: "{}", accessibilityLabel: "Invocation arguments JSON")
    private lazy var serverPicker = PiKit.Dropdown(selection: "", items: [("", "Choose a server")], placeholder: "Choose a server", icon: "server.rack", accessibilityName: "MCP server") { [weak self] value in self?.server = value; self?.refreshUI() }
    private let spinner = PiKit.spinner(controlSize: .small)
    private let list = LazyStackView(frame: .zero)
    private let empty = PiKit.TextLine(PiKit.Line("Choose a server and list its tools", font: PiKit.Font.caption, color: .piInkTertiary))
    private let resultText = PagedTextView(text: "")
    private lazy var resultBox = PiKit.inset(resultText)
    private let column = PayloadColumn()
    private let detailColumn = PayloadColumn()
    private let status = ShellNote("", tone: .danger)
    private let glide = PiKit.SelectionGlide()
    private lazy var configurationCard = PiKit.card(ShellStack(.vertical, spacing: PiSpacing.sm, [
        .view(PiKit.TextLine(PiKit.Line("Vault MCP configuration", font: PiKit.Font.heading, color: .piInk))),
        .view(PiKit.inset(PayloadViewport(configurationEditor, height: 160), sunken: true), .fill),
        .view(ShellStack(.horizontal, spacing: PiSpacing.sm, [.view(save), .view(cancelEdit), .spacer(0)]), .fill)]), padding: PiSpacing.md)
    private lazy var warning: NSView = {
        let icon = PiKit.SymbolView(PiKit.Symbol("exclamationmark.triangle.fill", size: 13), color: .piWarning)
        let words = ShellText("The previous invocation's outcome is unknown. Check its effects before acknowledging.", font: PiKit.Font.caption, color: .piInk)
        let row = ShellStack(.horizontal, spacing: PiSpacing.sm, padding: NSEdgeInsets(top: PiSpacing.sm, left: PiSpacing.sm, bottom: PiSpacing.sm, right: PiSpacing.sm), [.view(icon), .view(words, .flexible), .spacer(8), .view(acknowledgeButton)])
        return PiKit.Box(fill: NSColor.piWarning.piOpacity(0.10), cornerRadius: PiRadius.sm, content: row)
    }()
    private lazy var split = PayloadSplit(leading: PiKit.inset(PayloadEmptyOverlay(content: list, empty: empty)), trailing: detailColumn, minimum: 250, ideal: 300, maximum: 380, trailingMinimum: 500)
    init(model: WorkspaceModel, source: ResourceInspectorSource? = nil) {
        self.model = model; self.source = source ?? .workspace(model)
        super.init(frame: .zero); addSubview(column)
        let actions = ShellStack(.horizontal, spacing: PiSpacing.sm, [.view(edit), .view(refresh), .view(remove), .spacer(8), .view(spinner)])
        let chooser = ShellStack(.horizontal, spacing: PiSpacing.sm, [.view(serverPicker), .view(listTools), .spacer(8)])
        detailColumn.items = [
            .view(PiKit.SectionHeader("Describe", subtitle: "Schema targets: a JSON array of {server, tool}; up to 32.", accessory: describe)),
            .fixed(PiKit.inset(targetsEditor), 60),
            .view(PiKit.SectionHeader("Invoke once", subtitle: "One server, one tool, one JSON object of arguments.", accessory: invokeButton)),
            .view(ShellStack(.horizontal, spacing: PiSpacing.sm, [.view(serverField, .fill), .view(toolField, .fill)])),
            .fixed(PiKit.inset(argumentsEditor), 66), .flexible(resultBox)]
        column.items = [.view(actions), .view(PiKit.Note("MCP configuration and explicit credentials are stored in the single Keychain vault. External configuration files and inherited credential references are retired.")), .view(configurationCard), .view(chooser), .flexible(split, ideal: 400), .view(warning), .view(status)]
        remove.setAccessibilityHelp("Deletes this project's saved MCP server configuration after asking")
        edit.onPress = { [weak self] in self?.editConfiguration() }
        refresh.onPress = { [weak self] in self?.refreshServers() }
        remove.onPress = { [weak self] in self?.removeAll() }
        listTools.onPress = { [weak self] in self?.loadTools() }
        save.onPress = { [weak self] in self?.saveConfiguration() }
        cancelEdit.onPress = { [weak self] in self?.editingConfiguration = false; self?.configuration = "{\"servers\":{}}"; self?.configurationProject = nil; self?.refreshUI() }
        describe.onPress = { [weak self] in self?.describeSelected() }
        invokeButton.onPress = { [weak self] in self?.invoke() }; acknowledgeButton.onPress = { [weak self] in self?.acknowledge() }
        serverField.onChange = { [weak self] value in self?.server = value; self?.refreshUI() }
        toolField.onChange = { [weak self] value in self?.tool = value; self?.refreshUI() }
        configurationEditor.onChange = { [weak self] in self?.configuration = $0 }
        targetsEditor.onChange = { [weak self] in self?.targets = $0 }; argumentsEditor.onChange = { [weak self] in self?.arguments = $0 }
        list.spacing = 2; list.insets = NSEdgeInsets(top: PiSpacing.sm, left: PiSpacing.sm, bottom: PiSpacing.sm, right: PiSpacing.sm)
        startObserving()
        refreshUI()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override func layout() { super.layout(); column.frame = bounds }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !started { work.resume(); startObserving(); started = true; refreshServers() }
        else if window == nil { prepareForRelease() }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil, window != nil { prepareForRelease() }; super.viewWillMove(toWindow: newWindow) }
    func prepareForRelease() {
        work.cancel(); observer.reset(); observing = false; started = false; busy = false; confirmationPending = false
        configurationProject = nil; editingConfiguration = false; configuration = "{\"servers\":{}}"
        servers = []; server = ""; tool = ""; tools = []; result = ""; targets = "[]"; arguments = "{}"; notice = ""; unknown = false
        refreshUI()
    }
    private func startObserving() {
        guard !observing else { return }; observing = true
        observer.observe(publisher: model.$configuration); observer.observe(publisher: model.$selectedWorkspaceID); observer.observe(publisher: model.$mcpRemovalInProgress)
    }
    private func refreshUI() {
        let interactive = work.isActive && inheritedEnabled
        let enabled = interactive && !busy && !confirmationPending
        edit.isEnabled = enabled; refresh.isEnabled = enabled
        remove.isEnabled = enabled && !model.mcpRemovalInProgress && (model.selectedWorkspaceID.map { model.mcpServerCount($0) > 0 } ?? false)
        save.isEnabled = enabled; cancelEdit.isEnabled = enabled
        listTools.isEnabled = enabled && !server.isEmpty; describe.isEnabled = enabled
        invokeButton.isEnabled = enabled && !server.isEmpty && !tool.isEmpty && !unknown
        acknowledgeButton.isEnabled = enabled
        serverPicker.isEnabled = interactive
        serverPicker.items = [("", "Choose a server")] + servers.map { ($0, $0) }; serverPicker.selection = server
        serverField.text = server; toolField.text = tool
        serverField.field.isEnabled = interactive; toolField.field.isEnabled = interactive
        configurationEditor.text = configuration; targetsEditor.text = targets; argumentsEditor.text = arguments
        for editor in [configurationEditor, targetsEditor, argumentsEditor] { editor.editor.isEditable = interactive }
        configurationCard.isHidden = !editingConfiguration; spinner.isHidden = !busy
        resultText.text = result; empty.isHidden = !tools.isEmpty; warning.isHidden = !unknown
        status.text = busy ? "Operation in progress. No automatic retry will be made." : notice; status.isHidden = status.text.isEmpty
        let values = tools
        list.reload(.init(count: values.count, key: { "\($0):" + (values[$0]["name"]?.string ?? "") }, height: { index, width in MCPToolRow.height(values[index], width: width) }, view: { [weak self] index, existing in
            guard let self else { return NSView() }; let entry = values[index], key = WireValue.object(entry).pretty
            let row = (existing as? MCPToolRow).flatMap { $0.contentKey == key ? $0 : nil } ?? MCPToolRow(entry: entry, glide: self.glide) { [weak self] in guard let self else { return }
                self.tool = entry["name"]?.string ?? ""; self.targets = WireValue.array([.object(["server": .string(self.server), "tool": .string(self.tool)])]).pretty; self.refreshUI()
            }
            row.row.selected = entry["name"]?.string == self.tool; row.row.isEnabled = self.inheritedEnabled; return row
        }))
        column.needsLayout = true; invalidateIntrinsicContentSize(); PiKit.sizeChanged(self)
    }
    private static func parse(_ text: String) throws -> WireValue {
        guard text.utf8.count <= 262144 else { throw HostError.failure("JSON input exceeds 256 KiB") }
        return try JSONDecoder().decode(WireValue.self, from: Data(text.utf8))
    }
    private func perform<Value: Sendable>(_ operation: @escaping @MainActor @Sendable () async throws -> Value,
                                         completion: @escaping @MainActor @Sendable (Value) -> Void) {
        guard work.isActive, !busy, inheritedEnabled else { return }; busy = true; refreshUI()
        work.run(operation) { [weak self] outcome in
            guard let self else { return }; defer { self.busy = false; self.refreshUI() }
            switch outcome { case .success(let value): completion(value); case .failure(let error): self.notice = error.localizedDescription }
        }
    }
    private func applyServers(_ value: [String: WireValue]) {
        servers = value["servers"]?.array?.compactMap { $0.object?["server"]?.string } ?? []
        if !servers.contains(server) { server = servers.first ?? ""; tools = [] }
        unknown = value["outcomeUnknown"]?.bool ?? false
        notice = value["notice"]?.string ?? (unknown ? "Previous invocation outcome is unknown. Check effects before acknowledging." : "Connected configuration is approved; tool discovery does not invoke tools.")
    }
    private func refreshServers() {
        let source = source
        perform({ try await source.request("mcp.list", [:], nil) }) { [weak self] in self?.applyServers($0) }
    }
    private func loadTools() {
        let source = source, server = server
        perform({ try await source.request("mcp.list", ["server": .string(server)], nil) }) { [weak self] value in
            guard let self else { return }; self.tools = value["tools"]?.array?.compactMap(\.object) ?? []
            self.notice = "\(self.tools.count) tools. Select one or enter several schema targets."
        }
    }
    private func describeSelected() {
        let source = source, targets = targets
        perform({
            let value = try Self.parse(targets); guard value.array != nil else { throw HostError.failure("Schema targets must be a JSON array") }
            return WireValue.object(try await source.request("mcp.describe", ["targets": value], nil)).pretty
        }) { [weak self] in self?.result = $0 }
    }
    private func editConfiguration() {
        guard let id = model.selectedWorkspaceID else { return }
        configuration = (model.configuration.mcp[id] ?? .object(["servers": .object([:])])).pretty
        configurationRevision = model.configuration.revision; configurationProject = id; editingConfiguration = true; refreshUI()
    }
    private func saveConfiguration() {
        guard let project = configurationProject else { return }
        let draft = configuration, revision = configurationRevision, model = model, source = source
        confirmThen("Trust these MCP servers?", "Saving this configuration can authorize programs and authenticated endpoints with your account's permissions. Review the JSON first. Only explicit server credentials are sent to that server.", action: "Save in Vault and Connect", operation: { () async throws -> [String: WireValue]? in
            try await model.saveMCPConfiguration(Self.parse(draft), expectedRevision: revision, workspaceID: project)
            try Task.checkCancellation()
            if model.selectedWorkspaceID == project { return try await source.request("mcp.list", [:], nil) }
            return nil as [String: WireValue]?
        }) { [weak self] value in
            guard let self else { return }; self.editingConfiguration = false; self.configuration = "{\"servers\":{}}"; self.configurationProject = nil
            if let value { self.applyServers(value) }
        }
    }
    private func removeAll() {
        guard let project = model.selectedWorkspaceID else { return }
        let model = model
        perform({ await model.confirmAndRemoveAllMCPServers() }) { [weak self] outcome in
            guard let self, let outcome else { return }
            self.notice = outcome
            if self.model.selectedWorkspaceID == project, self.model.mcpServerCount(project) == 0 { self.servers = []; self.server = ""; self.tools = []; self.result = "" }
        }
    }
    private func invoke() {
        guard let id = model.resourceTargetSessionID ?? model.selectedID, let chat = model.record(id), chat.toolMode == "editing", chat.connectionTest != true else { notice = "Select an editing chat before invoking MCP."; refreshUI(); return }
        // The confirmed target and arguments belong to this press, even if
        // the reader edits another field before the confirmation returns.
        let server = server, tool = tool, arguments = arguments, model = model, source = source
        confirmThen("Invoke \(server) / \(tool)?", "Exactly one invocation will be sent. It may change external state. Inspect the schema and arguments first. No automatic retry is performed.", action: "Invoke Once", operation: {
            let value = try Self.parse(arguments); guard value.object != nil else { throw HostError.failure("Invocation arguments must be one JSON object") }
            _ = try await model.open(chat); try Task.checkCancellation()
            var output: String?, failure: String?
            do { output = WireValue.object(try await source.request("mcp.invoke", ["server": .string(server), "tool": .string(tool), "arguments": value], id)).pretty }
            catch { failure = error.localizedDescription }
            try Task.checkCancellation()
            var servers: [String: WireValue]?
            do { servers = try await source.request("mcp.list", [:], nil) }
            catch { if failure == nil { failure = error.localizedDescription } }
            return InvocationResult(output: output, servers: servers, failure: failure)
        }) { [weak self] value in
            guard let self else { return }; if let output = value.output { self.result = output }
            if let servers = value.servers { self.applyServers(servers) }; if let failure = value.failure { self.notice = failure }
        }
    }
    private struct InvocationResult: Sendable { let output: String?; let servers: [String: WireValue]?; let failure: String? }
    private func acknowledge() {
        let source = source
        confirmThen("Have you checked the previous invocation’s effects?", "Acknowledging permits a new invocation; it does not retry, cancel, or undo the previous one.", action: "I Checked — Acknowledge", operation: {
            _ = try await source.request("mcp.acknowledgeUnknown", ["confirmed": .bool(true)], nil); try Task.checkCancellation()
            return try await source.request("mcp.list", [:], nil)
        }) { [weak self] in self?.applyServers($0) }
    }
    private func confirmThen<Value: Sendable>(_ title: String, _ detail: String, action: String,
                                              operation: @escaping @MainActor @Sendable () async throws -> Value,
                                              completion: @escaping @MainActor @Sendable (Value) -> Void) {
        guard work.isActive, !busy, !confirmationPending, inheritedEnabled else { return }; confirmationPending = true; refreshUI()
        let window = window
        work.run({ [weak window] in await PiQuestion.shared.confirm(title, detail, action: action, over: window) }) { [weak self] outcome in
            guard let self else { return }; self.confirmationPending = false; self.refreshUI()
            guard case .success(true) = outcome else { return }; self.perform(operation, completion: completion)
        }
    }
}

@MainActor private final class ResourceSkillRow: DashView {
    let row: PiKit.SelectableRow
    let contentKey: String
    static func key(_ skill: SkillDescriptor) -> String { [skill.id, skill.name, skill.path, skill.description, skill.contentHash, skill.metadataHash, skill.policy, skill.scope].joined(separator: "|") }
    init(skill: SkillDescriptor, glide: PiKit.SelectionGlide, action: @escaping () -> Void) {
        contentKey = Self.key(skill)
        let policy = PiKit.Badge(text: ResourceInspector.policyLabel(skill.policy), tone: ResourceInspector.policyTone(skill.policy)); policy.toolTip = "Skill policy · " + skill.policy
        let path = PiKit.TextLine(PiKit.Line(skill.path, font: PiKit.Font.caption, color: .piInkTertiary)); path.truncation = .middle
        let content = ShellStack(.vertical, spacing: 4, [.view(ShellText("/" + skill.name, font: PiKit.Font.heading, color: .piInk), .fill), .view(ShellStack(.horizontal, spacing: 4, [.view(policy), .view(PiKit.Badge(text: skill.scope)), .spacer(0)]), .fill), .view(path, .fill)])
        row = PiKit.SelectableRow(content: content, glide: glide, action: action)
        super.init(frame: .zero); addSubview(row)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    static func height(_ skill: SkillDescriptor, width: CGFloat) -> CGFloat { ShellWrap.height("/" + skill.name, font: PiKit.Font.heading, width: max(0, width - 20)) + 8 + PiKit.Line("Ag", font: PiKit.Font.micro, color: .piInk).lineHeight + 7 + PiKit.Line("Ag", font: PiKit.Font.caption, color: .piInk).lineHeight + 16 }
    override func layout() { super.layout(); row.frame = bounds }
}

@MainActor private final class MCPToolRow: DashView {
    let row: PiKit.SelectableRow
    let contentKey: String
    init(entry: [String: WireValue], glide: PiKit.SelectionGlide, action: @escaping () -> Void) {
        contentKey = WireValue.object(entry).pretty
        let title = ShellText(entry["name"]?.string ?? "", font: PiKit.Font.heading, color: .piInk)
        let description = ShellText(entry["description"]?.string ?? "", font: PiKit.Font.caption, color: .piInkSecondary, maximumLines: 3)
        row = PiKit.SelectableRow(content: ShellStack(.vertical, spacing: 3, [.view(title, .fill), .view(description, .fill)]), glide: glide, action: action)
        super.init(frame: .zero); addSubview(row)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    static func height(_ entry: [String: WireValue], width: CGFloat) -> CGFloat {
        let count = min(3, max(1, ShellWrap.ranges(entry["description"]?.string ?? "", font: PiKit.Font.caption, width: max(0, width - 20)).count))
        return ShellWrap.height(entry["name"]?.string ?? "", font: PiKit.Font.heading, width: max(0, width - 20)) + 3 + CGFloat(count) * PiKit.Line("Ag", font: PiKit.Font.caption, color: .piInk).lineHeight + 16
    }
    override func layout() { super.layout(); row.frame = bounds }
}

@MainActor final class InstructionSourceRow: DashView, PiKit.WidthSizing {
    let position: Int, source: [String: WireValue]
    private let content: ShellStack
    init(position: Int, source: [String: WireValue]) {
        self.position = position; self.source = source
        let state = source["state"]?.string ?? ""
        let badges = ShellStack(.horizontal, spacing: 4, [.view(PiKit.Badge(text: state, tone: state == "included" ? .success : state == "skipped" || state == "omitted" ? .warning : .neutral)), .view(PiKit.Badge(text: source["scope"]?.string ?? "")), .spacer(0)])
        let path = PayloadSingleLine(source["path"]?.string ?? "", font: PiKit.Font.mono, color: .piInk)
        let hash = PayloadSingleLine("SHA-256 " + (source["hash"]?.string ?? "unavailable"), font: PiKit.Font.caption, color: .piInkTertiary)
        var rows: [ShellItem] = [.view(badges, .fill), .view(path, .fill)]
        if let reason = source["reason"]?.string, !reason.isEmpty { rows.append(.view(ShellText(reason, font: PiKit.Font.caption, color: .piInkSecondary), .fill)) }
        rows.append(.view(hash, .fill))
        let number = ShellStack(.horizontal, spacing: 0, [.spacer(0), .view(PiKit.TextLine(PiKit.Line("\(position)", font: PiKit.Font.monospacedDigits(PiKit.Font.caption), color: .piInkTertiary)))])
        content = ShellStack(.horizontal, spacing: PiSpacing.sm, alignment: .top, padding: NSEdgeInsets(top: 8, left: PiSpacing.md, bottom: 8, right: PiSpacing.md), [.view(number, .fixed(22)), .view(ShellStack(.vertical, spacing: 3, rows), .fill)])
        super.init(frame: .zero); addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    func height(forWidth width: CGFloat) -> CGFloat { content.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 900)) }
    override func layout() { super.layout(); content.frame = bounds }
}

@MainActor private final class PayloadHairline: DashView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }
    override func draw(_ dirtyRect: NSRect) { NSColor.piHairline.setFill(); bounds.fill() }
}
