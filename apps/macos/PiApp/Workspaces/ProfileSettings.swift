import AppKit
import Combine

/// The Settings sheet and window, in four sections down the left since
/// 0.1.107: Connections (keys, headers, model choices, reasoning and gateway
/// contracts), Usage & capture, Chats & notifications, and App (runtime and
/// updates). One Save covers every section. Every connection is a tab; the
/// tab's edits live in `ConnectionSettingsController`, which keeps them across
/// tab switches, lists models for a connection before it is saved, and saves
/// against the vault's current revision.
@MainActor final class ProfileSettingsView: NSView, PiKit.SizeObserver, InheritsEnabled {
    let model: WorkspaceModel
    let controller: ConnectionSettingsController
    let windowChrome: Bool
    private let dismiss: () -> Void
    let sheet: PiKit.Sheet
    private let body = FlippedView()
    private let sections: SettingsSectionList
    private let sectionsRule = HairlineView()
    private let scroll = NSScrollView()
    private let page = VerticalStack(spacing: PiSpacing.xl, padding: NSEdgeInsets(top: PiSpacing.xl, left: PiSpacing.xl, bottom: PiSpacing.xl, right: PiSpacing.xl))
    private let footer: SettingsFooter
    private let cancelButton = PiKit.Button("Cancel", style: .secondary)
    private let enabled = EnabledState()
    /// Each control's value from the controller, run on every change.
    private var updaters: [() -> Void] = []
    var inheritedEnabled = true { didSet { if oldValue != inheritedEnabled { refresh() } } }
    private var builtKey: StructureKey?
    private var observations: [AnyCancellable] = []
    private var refreshScheduled = false
    private var loadTask: Task<Void, Never>?

    init(model: WorkspaceModel, controller: ConnectionSettingsController, windowChrome: Bool, dismiss: @escaping () -> Void) {
        self.model = model; self.controller = controller; self.windowChrome = windowChrome; self.dismiss = dismiss
        sections = SettingsSectionList()
        footer = SettingsFooter(model: model, controller: controller)
        sheet = PiKit.Sheet("Settings", subtitle: "Your connections, keys, headers, MCP servers and preferences. Everything here is kept in your macOS Keychain and only this signed app can read it.",
                            symbol: "gearshape", windowChrome: windowChrome, content: body, actions: [cancelButton], footer: footer)
        super.init(frame: NSRect(x: 0, y: 0, width: 880, height: 780))
        footer.dismiss = dismiss
        // Cancel is the explicit way out without saving: every unsaved edit
        // goes, and Settings opens next time on what the vault holds.
        cancelButton.onPress = { [controller, dismiss] in controller.discardAll(); dismiss() }
        cancelButton.toolTip = "Close Settings and discard every unsaved change"
        cancelButton.setAccessibilityIdentifier("settings-cancel")
        sheet.onCancel = { [controller, dismiss] in Task { if await controller.requestClose() { dismiss() } } }
        sections.select = { [model] in model.settingsSection = $0 }
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.documentView = page
        for view in [sections, sectionsRule, scroll] as [NSView] { body.addSubview(view) }
        addSubview(sheet)
        observations.append(controller.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() })
        observations.append(model.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() })
        observations.append(model.modelCatalog.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() })
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 880, height: 780) }
    func contentSizeChanged() { needsLayout = true; page.needsLayout = true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The window the form is in: questions about unsaved edits go over it.
        controller.presentationWindow = window
        if window != nil, loadTask == nil {
            loadTask = Task { [controller] in await controller.load(discardingDrafts: false) }
        } else if window == nil {
            loadTask?.cancel(); loadTask = nil
        }
    }

    private func scheduleRefresh() {
        needsLayout = true
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { if self?.refreshScheduled == true { self?.refresh() } } }
    }

    // MARK: Refresh

    private var lastSection: SettingsSection?
    private var lastProfileID: String?
    func refresh() {
        refreshScheduled = false
        let section = model.settingsSection
        if let lastSection, lastSection != section { controller.confirmingTest = false; controller.confirmingDelete = false }
        if let lastProfileID, lastProfileID != controller.draft.profile.id { controller.confirmingTest = false }
        lastSection = section; lastProfileID = controller.draft.profile.id
        sections.update(selection: section, edited: controller.editedSections)
        sheet.cancelDisabled = controller.saving || !inheritedEnabled
        enabled.set(cancelButton, !controller.saving)
        let key = structureKey
        if key != builtKey {
            let sectionChanged = builtKey?.section != section
            builtKey = key
            build()
            // Each section opens at its top.
            if sectionChanged { scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }
        }
        updaters.forEach { $0() }
        StaticTextAccessibility.asValues(in: page)
        footer.refresh()
        // A save writes the tabs it captured when it started; nor while the
        // app is quitting or updating: its last save has been decided.
        let formEnabled = inheritedEnabled && !(controller.busy || model.installPreparing)
        enabled.formEnabled = formEnabled
        enabled.apply(to: page, formEnabled: formEnabled)
        enabled.apply(to: cancelButton, formEnabled: inheritedEnabled)
        footer.applyEnabled(formEnabled)
        needsLayout = true; page.needsLayout = true
    }

    /// What decides which rows there are: built again only when it changes.
    private struct StructureKey: Hashable {
        var section: SettingsSection, isSaved: Bool, supportedAPI: Bool, catalogNote: String?, pinned: Bool
        var quotaUnlimited: Bool, profiles: Int, profileID: String
    }
    private var structureKey: StructureKey {
        let draft = controller.draft
        let source = model.catalogProfile(for: draft.profile)
        let note = controller.isSaved && source.id != draft.profile.id
            ? "Model list follows \(source.name) · \(CatalogModelPickerView.sourceLabel(source)). Editing the URL above saves a separate catalog for this connection." : nil
        return StructureKey(section: model.settingsSection, isSaved: controller.isSaved, supportedAPI: controller.supportedAPI, catalogNote: note,
                            pinned: draft.replayPolicy == "pinned", quotaUnlimited: controller.preferences.capture.quotaUnlimited,
                            profiles: model.profiles.count, profileID: draft.profile.id)
    }

    private func build() {
        updaters = []
        let items: [NSView]
        switch model.settingsSection {
        case .connections: items = connections()
        case .usage: items = usageAndCapture()
        case .chats: items = chatsAndNotifications()
        case .app: items = app()
        }
        page.setItems(items)
    }

    // MARK: Layout

    override func layout() {
        if refreshScheduled { refresh() }
        super.layout()
        sheet.frame = bounds
        sheet.layoutSubtreeIfNeeded()
        layoutBody()
    }
    private func layoutBody() {
        let bounds = body.bounds
        sections.frame = CGRect(x: 0, y: 0, width: 210, height: bounds.height)
        sectionsRule.frame = CGRect(x: 210, y: 0, width: 1, height: bounds.height)
        scroll.frame = CGRect(x: 211, y: 0, width: max(0, bounds.width - 211), height: bounds.height)
        // Twice at most: a page taller than the view brings a scroller,
        // which takes its width from the page.
        for _ in 0..<2 {
            let width = scroll.contentView.bounds.width
            let height = page.height(forWidth: width)
            page.frame = CGRect(x: 0, y: 0, width: width, height: max(height, scroll.contentView.bounds.height))
            scroll.tile()
            if scroll.contentView.bounds.width == width { break }
        }
    }

    // MARK: Building blocks

    /// A field bound to the controller: shows `get` and writes with `set`.
    private func field(placeholder: String, icon: String? = nil, secure: Bool = false, mono: Bool = false, identifier: String? = nil,
                       label: String? = nil, get: @escaping () -> String, set: @escaping (String) -> Void) -> PiKit.TextField {
        let field = PiKit.TextField(placeholder: placeholder, text: get(), icon: icon, secure: secure, mono: mono, onChange: set)
        if let identifier { field.field.setAccessibilityIdentifier(identifier) }
        if let label { field.field.setAccessibilityLabel(label) }
        updaters.append { [weak field] in field?.text = get() }
        return field
    }
    private func number(label: String, width: CGFloat = 120, get: @escaping () -> Int, set: @escaping (Int) -> Void) -> PiKit.NumberField {
        let field = PiKit.NumberField(placeholder: "Tokens", value: get(), width: width, onChange: set)
        field.field.setAccessibilityLabel(label)
        updaters.append { [weak field] in if let field, field.field.currentEditor() == nil { field.value = get() } }
        return field
    }
    private func toggle(label: String, identifier: String? = nil, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> PiKit.Switch {
        let toggle = PiKit.Switch(isOn: get(), onChange: set)
        toggle.setAccessibilityLabel(label)
        if let identifier { toggle.setAccessibilityIdentifier(identifier) }
        updaters.append { [weak toggle] in toggle?.isOn = get() }
        return toggle
    }
    private func dropdown<Tag: Hashable>(_ items: [(Tag, String)], name: String, identifier: String? = nil,
                                         get: @escaping () -> Tag, set: @escaping (Tag) -> Void) -> PiKit.Dropdown<Tag> {
        let dropdown = PiKit.Dropdown(selection: get(), items: items, compact: true, accessibilityName: name, onSelect: set)
        if let identifier { dropdown.setAccessibilityIdentifier(identifier) }
        updaters.append { [weak dropdown] in dropdown?.selection = get() }
        return dropdown
    }
    private func stepper(name: String, unit: String, range: ClosedRange<Int64>, step: Int64 = 1, get: @escaping () -> Int64, set: @escaping (Int64) -> Void) -> PiKit.Stepper {
        let stepper = PiKit.Stepper(name: name, unit: unit, value: get(), range: range, step: step, onChange: set)
        updaters.append { [weak stepper] in stepper?.value = get() }
        return stepper
    }
    private func text(_ text: String, font: NSFont = PiKit.Font.body, color: NSColor = .piInkSecondary) -> PiKit.TextLine {
        PiKit.TextLine(PiKit.Line(text, font: font, color: color))
    }
    /// Text inside a group, 12 points in from either side.
    private func insetText(_ text: String, color: NSColor) -> InsetView {
        InsetView(TextBlock(text, font: PiKit.Font.caption, color: color), insets: NSEdgeInsets(top: 0, left: PiSpacing.md, bottom: 0, right: PiSpacing.md))
    }

    // MARK: Connections

    /// Every connection's tab, with its gateway, model and contract settings.
    private func connections() -> [NSView] {
        let controller = controller, model = model
        let isSaved = controller.isSaved
        // Every saved connection is a tab, so the count and the current one
        // are visible at a glance; a new connection opens as its own tab
        // until it is saved, and a tab with unsaved edits carries a dot.
        let header = ConnectionTabsHeader(controller: controller, showsNew: isSaved)
        updaters.append { [weak header] in header?.update(count: model.profiles.count) }

        var rows: [NSView] = [
            SettingsRow(label: "Name", detail: "Rename freely: the connection keeps its id, key, chats and model cache.",
                      control: field(placeholder: "Team router", identifier: "settings-connection-name",
                                     get: { controller.draft.profile.name }, set: { controller.draft.profile.name = $0 })),
        ]
        if controller.supportedAPI {
            rows.append(SettingsRow(label: "LiteLLM API", control: text("Responses")))
        } else {
            let use = PiKit.Button("Use Responses", style: .secondary) {
                controller.draft.profile.api = LiteLLMConfiguration.supportedAPI
                controller.message = "Review the Responses URL below, then save. A new connection will retain this key; the original Messages connection and its history stay unchanged."
                controller.messageTone = .neutral
            }
            let warning = text("Messages · history only", color: .piWarning)
            let pair = HStackView(spacing: StackLayout.system, views: [warning, use])
            pair.items = { [.fixed(warning), .fixed(use)] }
            rows.append(SettingsRow(label: "LiteLLM API", control: pair))
            rows.append(insetText(LiteLLMConfiguration.unsupportedAPIMessage, color: .piWarning))
        }
        rows.append(SettingsRow(label: "Base URL or full API route", control: field(placeholder: "https://litellm.example.com", mono: true, identifier: "settings-base-url",
                                                                                   get: { controller.draft.profile.baseUrl }, set: { controller.draft.profile.baseUrl = $0 })))
        // The key sits right under the URL: together they are what a gateway
        // needs before its models can be listed below.
        rows.append(SettingsRow(label: "LiteLLM API key", detail: isSaved ? "Empty keeps the saved key. No shell, OAuth or environment fallback." : "Needed to list a gateway's own catalog and to send. No shell, OAuth or environment fallback.",
                              control: field(placeholder: isSaved ? "Saved · type to replace" : "sk-…", icon: "key", secure: true, identifier: "settings-api-key",
                                             get: { controller.draft.key }, set: { controller.draft.key = $0 })))
        rows.append(SettingsRow(label: "Custom headers JSON", detail: "Empty preserves saved headers; {} clears them.",
                              control: field(placeholder: "{\"X-Team\": \"payments\"}", icon: "curlybraces", secure: true,
                                             get: { controller.draft.headers }, set: { controller.draft.headers = $0 })))
        rows.append(SettingsRow(label: "Custom model catalog URL", detail: "Blank uses the included Bello catalog. A custom URL replaces it; only the gateway's origin receives its key.",
                              control: field(placeholder: "Blank uses the Bello model catalog", icon: "list.bullet.rectangle", mono: true, identifier: "settings-catalog-url",
                                             get: { controller.draft.profile.catalogUrl ?? "" }, set: { controller.draft.profile.catalogUrl = $0.isEmpty ? nil : $0 })))
        if let note = builtKey?.catalogNote { rows.append(insetText(note, color: .piInkSecondary)) }
        let alias = field(placeholder: "alias", mono: true, identifier: "settings-model-alias", get: { controller.draft.profile.modelId }, set: { controller.draft.profile.modelId = $0 })
        let menu = CatalogModelMenuButton(model: model, controller: controller, mini: false)
        updaters.append { [weak menu] in menu?.refresh() }
        let aliasRow = HStackView(spacing: 6, flexible: true, views: [alias, menu])
        aliasRow.items = { [.view(alias, .flexible(height: { _ in alias.intrinsicContentSize.height })), .fixed(menu)] }
        rows.append(SettingsRow(label: "Requested model / router alias", detail: isSaved ? nil : "Choose from the catalog, or type an alias your gateway routes.", control: aliasRow))
        let mini = CatalogModelMenuButton(model: model, controller: controller, mini: true)
        updaters.append { [weak mini] in mini?.refresh() }
        rows.append(SettingsRow(label: "Mini model", detail: "Writes chat titles and the webhook's parameters. Catalog default uses the first active model marked Mini; without one, titles keep the first message and a webhook goes out without its parameters.", control: mini))
        rows.append(SettingsRow(label: "Configured context capacity", control: number(label: "Configured context capacity, tokens",
                                                                                    get: { controller.draft.profile.contextWindow }, set: { controller.draft.profile.contextWindow = $0 })))
        rows.append(SettingsRow(label: "Output budget", detail: "Room the context estimate sets aside for a reply, so a chat compacts before a reply would no longer fit. It is never sent as a limit: replies run to the model's own output ceiling.",
                              control: number(label: "Output budget, tokens", get: { controller.draft.profile.maxOutputTokens }, set: { controller.draft.profile.maxOutputTokens = $0 })))
        let ceiling = RowText("", font: PiKit.Font.caption, color: .piInkSecondary)
        updaters.append { [weak ceiling] in
            ceiling?.block.text = controller.draft.profile.modelOutputLimit.map { "\($0.formatted()) tokens" } ?? "Not supplied by the model catalog; requests carry no output limit"
        }
        rows.append(SettingsRow(label: "Model output ceiling", detail: "The catalog's limit for the chosen model, sent with every request as its output limit.", last: true, control: ceiling))
        let connection = SettingsCard(title: isSaved ? "Connection" : "New connection",
                                      footer: "Leave the key and headers empty to keep the saved values. The selected alias remains the requested model; a gateway's reported route may change between requests.", rows: rows)

        let pinned = controller.draft.replayPolicy == "pinned"
        var replay: [NSView] = [SettingsRow(label: "Policy", last: !pinned, control: dropdown([("portable", "Portable text and tool history"), ("pinned", "Preserve native state on a fixed route"), ("ask", "Ask before replaying native state")],
                                                                                          name: "Reasoning continuation policy", get: { controller.draft.replayPolicy }, set: { controller.draft.replayPolicy = $0 }))]
        if pinned {
            replay.append(SettingsRow(label: "Expected reported model", control: field(placeholder: "model id", mono: true, label: "Expected reported model",
                                                                                     get: { controller.draft.expectedModel }, set: { controller.draft.expectedModel = $0 })))
            replay.append(SettingsRow(label: "Fixed-route compatibility contract", last: true, control: field(placeholder: "reference", label: "Fixed-route compatibility contract",
                                                                                                            get: { controller.draft.replayContract }, set: { controller.draft.replayContract = $0 })))
        }
        let reasoning = SettingsCard(title: "Reasoning continuation", footer: "Portable history supports changing router models. It sends visible text and tool calls/results; original signed/encrypted reasoning stays in history. Preserving native state requires a compatible route guaranteed by your gateway.", rows: replay)

        let metadata = SettingsCard(title: "Gateway model and cache metadata contract", footer: "The response model is recorded automatically. Only configure headers documented for your deployment. An opaque deployment ID or route group is not an actual model name. Use a header reporting true/false or hit/miss; a cache key alone is not evidence of a hit.", rows: [
            SettingsRow(label: "Deployment/version contract reference", control: field(placeholder: "reference", label: "Deployment/version contract reference", get: { controller.draft.metadataReference }, set: { controller.draft.metadataReference = $0 })),
            SettingsRow(label: "Actual model header", control: field(placeholder: "optional", mono: true, label: "Actual model header", get: { controller.draft.modelHeader }, set: { controller.draft.modelHeader = $0 })),
            SettingsRow(label: "Deployment ID header", control: field(placeholder: "optional", mono: true, label: "Deployment ID header", get: { controller.draft.deploymentHeader }, set: { controller.draft.deploymentHeader = $0 })),
            SettingsRow(label: "Route group header", control: field(placeholder: "optional", mono: true, label: "Route group header", get: { controller.draft.groupHeader }, set: { controller.draft.groupHeader = $0 })),
            SettingsRow(label: "Cache hit/miss header", last: true, control: field(placeholder: "optional", mono: true, label: "Cache hit/miss header", get: { controller.draft.cacheHeader }, set: { controller.draft.cacheHeader = $0 })),
        ])
        let routing = SettingsCard(title: "Gateway routing", footer: "Off sends disable_fallbacks with every request, so a failing route returns its error and the report shows the requested model unanswered. On lets LiteLLM answer from its configured fallback models.", rows: [
            SettingsRow(label: "Allow fallback models", last: true, control: toggle(label: "Allow fallback models", get: { controller.draft.allowFallbacks }, set: { controller.draft.allowFallbacks = $0 })),
        ])
        let editor = CodeEditorView()
        editor.text = controller.draft.advanced
        editor.onChange = { controller.draft.advanced = $0 }
        updaters.append { [weak editor] in editor?.text = controller.draft.advanced }
        let capabilities = SettingsCard(title: "Model capabilities", footer: "JSON: reasoning, thinkingLevel, thinkingLevelMap, input, cost, samplingParams and compat. Default thinking leaves effort unspecified. Configure conservative capacity for a router alias.",
                                        rows: [InsetView(editor, insets: NSEdgeInsets(top: PiSpacing.sm, left: PiSpacing.sm, bottom: PiSpacing.sm, right: PiSpacing.sm), contentHeight: 130)])
        return [header, connection, reasoning, metadata, routing, capabilities]
    }

    // MARK: Usage and capture

    /// The request log's capture, the dashboard and what a chat may spend.
    private func usageAndCapture() -> [NSView] {
        let controller = controller
        let quota = HStackView(spacing: 8, flexible: true)
        let mode = dropdown([(false, "Limit"), (true, "Unlimited")], name: "Payload quota mode",
                            get: { controller.preferences.capture.quotaUnlimited }, set: { controller.preferences.capture.quotaUnlimited = $0 })
        quota.addSubview(mode)
        var quotaItems: [StackLayout.Item] = [.fixed(mode)]
        if !controller.preferences.capture.quotaUnlimited {
            let mib = stepper(name: "Payload quota", unit: "MiB", range: 1...10_240, get: { controller.preferences.capture.quotaBytes / 1_048_576 },
                              set: { controller.preferences.capture.quotaBytes = $0 * 1_048_576 })
            quota.addSubview(mib); quotaItems.append(.view(mib, .flexible(min: mib.minimumWidth, height: { _ in mib.intrinsicContentSize.height })))
        }
        quota.items = { quotaItems }
        let capture = SettingsCard(title: "Capture and dashboard", footer: "Request and response bodies are saved locally for 30 days by default, within the payload quota; past a limited quota the oldest bodies are deleted to make room, and Unlimited keeps every body until its retention ends. Headers are included with authentication values masked. Bodies are unencrypted; known credentials in request bodies are hashed. Per-session overrides are separate.", rows: [
            SettingsRow(label: "Default future body capture", control: dropdown([("off", "Off"), ("memory", "Session memory"), ("persist", "Persist locally")], name: "Default future body capture",
                                                                              get: { controller.preferences.capture.defaultMode }, set: { controller.preferences.capture.defaultMode = $0 })),
            SettingsRow(label: "Body retention", control: stepper(name: "Body retention", unit: "days", range: 1...365,
                                                               get: { Int64(controller.preferences.capture.retentionDays) }, set: { controller.preferences.capture.retentionDays = Int($0) })),
            SettingsRow(label: "Payload quota", control: quota),
            SettingsRow(label: "Metric retention", control: stepper(name: "Metric retention", unit: "days", range: 1...3650,
                                                                 get: { Int64(controller.preferences.dashboard.metricRetentionDays) }, set: { controller.preferences.dashboard.metricRetentionDays = Int($0) })),
            SettingsRow(label: "Dashboard window", last: true, control: stepper(name: "Dashboard window", unit: "hours", range: 1...8760,
                                                                            get: { Int64(controller.preferences.dashboard.windowHours) }, set: { controller.preferences.dashboard.windowHours = Int($0) })),
        ])
        let choices = CostLimitChoices(selection: controller.preferences.defaultChatCostLimit, identifier: "settings-cost-limit") {
            controller.preferences.chatCostLimit = $0 ?? .standard
        }
        choices.enabledState = enabled
        updaters.append { [weak choices] in choices?.selection = controller.preferences.defaultChatCostLimit }
        let limitRow = SettingsRow(label: "Cost limit per chat", detail: Self.costDetail(controller), last: true, control: choices)
        let spending = SettingsCard(title: "Spending", footer: CostLimitText.explanation + " A chat can have its own limit: open its token usage figure under the composer, or Session info.", rows: [limitRow])
        // The detail follows the default limit: the row is made again when it changes.
        var detail = Self.costDetail(controller)
        updaters.append { [weak spending, weak self] in
            guard let spending, let self else { return }
            let now = Self.costDetail(controller)
            guard now != detail else { return }
            detail = now
            spending.setRows([SettingsRow(label: "Cost limit per chat", detail: now, last: true, control: choices)])
            self.needsLayout = true
        }
        return [capture, spending]
    }
    private static func costDetail(_ controller: ConnectionSettingsController) -> String {
        controller.preferences.defaultChatCostLimit.usd == nil
            ? "No chat is stopped for what it costs, unless it has a limit of its own."
            : "Every chat without its own limit stops at \(controller.preferences.defaultChatCostLimit.label) of reported spend."
    }

    // MARK: Chats and notifications

    /// How a finished turn reads, and what says that a chat finished.
    private func chatsAndNotifications() -> [NSView] {
        let controller = controller, model = model
        let transcript = SettingsCard(title: "Transcript", footer: "Compact is how a finished turn reads by default: its tool calls and thoughts fold behind one line above the answer, and one click on that line shows the whole turn again. Nothing is discarded either way, and a turn still running always reads in full.", rows: [
            SettingsRow(label: "Finished turns", detail: TranscriptDisplayMode.compact.detail, last: true,
                      control: dropdown(TranscriptDisplayMode.allCases.map { ($0, $0.label) }, name: "Transcript display for finished turns", identifier: "settings-transcript-display",
                                        get: { controller.preferences.transcriptDisplay }, set: { controller.preferences.transcriptDisplay = $0 })),
        ])
        let preview = PiKit.Button("Preview", symbol: "speaker.wave.2", style: .secondary, compact: true) { model.completionSound.play() }
        preview.setAccessibilityIdentifier("settings-preview-completion-sound")
        let sound = toggle(label: "Play task completion sound", identifier: "settings-completion-sound",
                           get: { controller.preferences.playsCompletionSound }, set: { controller.preferences.playsCompletionSound = $0 })
        let soundRow = HStackView(spacing: PiSpacing.sm, views: [preview, sound])
        soundRow.items = { [.fixed(preview), .fixed(sound)] }
        let notifications = SettingsCard(title: "Notifications", rows: [
            SettingsRow(label: "Task completion sound", detail: "Play a short chime when a chat finishes its task, even while the app is in the background.", last: true, control: soundRow),
        ])
        let webhook = WebhookSettingsCard(get: { controller.preferences.webhook ?? WebhookSettings() }, set: { controller.preferences.webhook = $0 },
                                          test: { try await model.sendTestWebhook($0) }, enabled: enabled)
        updaters.append { [weak webhook] in webhook?.update() }
        return [transcript, notifications, webhook]
    }

    // MARK: App

    /// The helpers' runtime and app updates.
    private func app() -> [NSView] {
        let controller = controller
        let runtime = SettingsCard(title: "Runtime", footer: "PATH applies to newly started helpers. Provider credentials are never inherited by shell tools.", rows: [
            SettingsRow(label: "Idle helper grace", control: stepper(name: "Idle helper grace", unit: "seconds", range: 10...600, step: 10,
                                                                  get: { Int64(controller.preferences.runtime.idleGraceSeconds) }, set: { controller.preferences.runtime.idleGraceSeconds = Int($0) })),
            SettingsRow(label: "Tools PATH", last: true, control: field(placeholder: "/usr/bin:/bin", mono: true,
                                                                     get: { controller.preferences.runtime.toolsPATH }, set: { controller.preferences.runtime.toolsPATH = $0 })),
        ])
        let updates = SettingsCard(title: "Updates", rows: [
            SettingsRow(label: "Check for app updates automatically", last: true, control: toggle(label: "Check for app updates automatically",
                                                                                               get: { controller.preferences.automaticUpdateChecks }, set: { controller.preferences.automaticUpdateChecks = $0 })),
        ])
        return [runtime, updates]
    }
}

/// "Connections · N", the connection tabs (scrolling sideways when there are
/// many), New connection and Reload vault.
@MainActor final class ConnectionTabsHeader: NSView, PiKit.WidthSizing {
    private let controller: ConnectionSettingsController
    private let count = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.micro, color: .piInkTertiary, tracking: 0.4, uppercased: true))
    private let tabsScroll = NSScrollView()
    private let tabs: PiKit.Tabs<String>
    private let newButton: PiKit.IconButton?
    private let reload: PiKit.IconButton
    init(controller: ConnectionSettingsController, showsNew: Bool) {
        self.controller = controller
        tabs = PiKit.Tabs(selection: controller.draft.profile.id, items: controller.tabs) { [controller] in controller.select(id: $0) }
        tabs.setAccessibilityIdentifier("settings-connection-tabs")
        newButton = showsNew ? PiKit.IconButton(symbol: "plus", label: "New connection", size: 26) { [controller] in controller.startNew() } : nil
        newButton?.toolTip = "Start a new connection in its own tab"
        newButton?.setAccessibilityIdentifier("settings-new-connection")
        reload = PiKit.IconButton(symbol: "arrow.clockwise", label: "Reload vault", size: 26) { [controller] in Task { await controller.requestReload() } }
        reload.toolTip = "Reload the configuration vault. Asks first when that would drop unsaved edits."
        super.init(frame: .zero)
        tabsScroll.hasHorizontalScroller = false; tabsScroll.hasVerticalScroller = false; tabsScroll.drawsBackground = false
        tabsScroll.borderType = .noBorder
        tabsScroll.documentView = tabs
        for view in [count, tabsScroll, newButton, reload].compactMap({ $0 }) as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func update(count value: Int) {
        count.line.text = "Connections · \(value)"
        tabs.items = controller.tabs
        tabs.selection = controller.draft.profile.id
        needsLayout = true
    }
    private var items: [StackLayout.Item] {
        let tabsHeight = tabs.intrinsicContentSize.height
        var items: [StackLayout.Item] = [.fixed(count), .view(tabsScroll, .flexible(height: { _ in tabsHeight }))]
        if let newButton { items.append(.fixed(newButton)) }
        items += [.spacer(0), .fixed(reload)]
        return items
    }
    func height(forWidth width: CGFloat) -> CGFloat { StackLayout.height(items, spacing: PiSpacing.sm, width: width) }
    override func layout() {
        super.layout()
        StackLayout.place(items, spacing: PiSpacing.sm, in: bounds, scale: piScale)
        tabs.frame = CGRect(origin: .zero, size: tabs.intrinsicContentSize)
    }
}

/// Settings' footer: what the open connection's tab can do (delete, discard,
/// test), what the last action said, the unsaved badge and Save All; or the
/// question Delete or Test asks, where the buttons were.
@MainActor final class SettingsFooter: NSView, PiKit.WidthSizing {
    private let model: WorkspaceModel
    private let controller: ConnectionSettingsController
    var dismiss: () -> Void = {}
    private let question = TextBlock("", font: PiKit.Font.caption, color: .piDanger, maximumLines: 3)
    private let keep = PiKit.Button("Keep", style: .secondary, compact: true)
    private let confirmDelete = PiKit.Button("Delete Connection", symbol: "trash", style: .danger)
    private let cancelTest = PiKit.Button("Cancel", style: .secondary, compact: true)
    private let confirmTest = PiKit.Button("Send Test Request", symbol: "bolt.horizontal", style: .primary)
    private let delete = PiKit.Button("Delete Connection…", symbol: "trash", style: .ghostDanger)
    private let discard = PiKit.Button("Discard", style: .secondary, compact: true)
    private let test = PiKit.Button("Test Connection…", symbol: "bolt.horizontal", style: .secondary)
    private var status: StatusNote?
    private let unsaved = PiKit.Badge(text: "Unsaved changes", tone: .warning)
    private let save = PiKit.Button("Save All", style: .primary)
    private let enabled = EnabledState()
    private enum Mode { case deleting, testing, normal }
    private var mode = Mode.normal

    init(model: WorkspaceModel, controller: ConnectionSettingsController) {
        self.model = model; self.controller = controller
        super.init(frame: .zero)
        question.setAccessibilityIdentifier("settings-delete-connection-question")
        keep.setAccessibilityIdentifier("settings-keep-connection")
        confirmDelete.setAccessibilityIdentifier("settings-confirm-delete-connection")
        confirmTest.setAccessibilityIdentifier("settings-confirm-test-connection")
        delete.setAccessibilityIdentifier("settings-delete-connection")
        discard.setAccessibilityIdentifier("settings-discard-connection")
        unsaved.setAccessibilityIdentifier("settings-unsaved")
        save.setAccessibilityIdentifier("settings-save")
        delete.toolTip = "Removes this connection and its key from the vault. Its chats keep their history and ask for another connection."
        discard.toolTip = "Drop this unsaved connection and return to a saved one"
        test.toolTip = "Saves this configuration, then sends one test request in a saved chat outside any project."
        save.toolTip = "Saves every connection tab with edits and the preferences, then closes Settings."
        keep.onPress = { [controller] in controller.confirmingDelete = false }
        confirmDelete.onPress = { [controller] in Task { await controller.delete() } }
        cancelTest.onPress = { [controller] in controller.confirmingTest = false }
        confirmTest.onPress = { [weak self, controller] in
            controller.confirmingTest = false
            Task { if await controller.save(thenTest: true) { self?.dismiss() } }
        }
        delete.onPress = { [controller] in controller.confirmingDelete = true }
        discard.onPress = { [controller] in controller.discardCurrent() }
        test.onPress = { [controller] in controller.confirmingTest = true }
        save.onPress = { [weak self, controller] in Task { if await controller.save() { self?.dismiss() } } }
        for view in [question, keep, confirmDelete, cancelTest, confirmTest, delete, discard, test, unsaved, save] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 800)) }

    private var onConnections: Bool { model.settingsSection == .connections }
    func refresh() {
        let isSaved = controller.isSaved
        mode = onConnections && isSaved && controller.confirmingDelete ? .deleting : onConnections && controller.confirmingTest ? .testing : .normal
        switch mode {
        case .deleting:
            question.text = "Delete “\(controller.draft.name)”? " + controller.deletionSummary
            question.color = .piDanger
            question.setAccessibilityIdentifier("settings-delete-connection-question")
        case .testing:
            question.text = "Send one small test request to “\(controller.draft.name)” now? Its provider may charge for it. The test runs in a saved chat outside any project, so you can inspect it later."
            question.color = .piInkSecondary
            question.setAccessibilityIdentifier("settings-test-connection-question")
        case .normal: break
        }
        let normal = mode == .normal
        question.isHidden = normal
        keep.isHidden = mode != .deleting; confirmDelete.isHidden = mode != .deleting
        cancelTest.isHidden = mode != .testing; confirmTest.isHidden = mode != .testing
        delete.isHidden = !(normal && onConnections && isSaved)
        discard.isHidden = !(normal && onConnections && !isSaved && !model.profiles.isEmpty)
        test.isHidden = !(normal && onConnections)
        enabled.set(test, model.configurationLoaded && controller.supportedAPI && !controller.draft.profile.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        setStatus(normal ? controller.message : "", tone: controller.messageTone)
        unsaved.isHidden = !(normal && controller.isDirty)
        save.isHidden = !normal
        enabled.set(save, model.configurationLoaded)
        needsLayout = true
        PiKit.sizeChanged(self)
    }
    func applyEnabled(_ formEnabled: Bool) { enabled.apply(to: self, formEnabled: formEnabled) }
    private func setStatus(_ text: String, tone: PiTone) {
        if text.isEmpty { status?.removeFromSuperview(); status = nil; return }
        if let status, status.text == text, status.tone == tone { return }
        status?.removeFromSuperview()
        let note = StatusNote(text, tone: tone)
        addSubview(note); status = note
    }
    private var items: [StackLayout.Item] {
        switch mode {
        case .deleting:
            return [.view(question, .wrapping(question, ideal: { [question] in question.idealWidth })), .spacer(PiSpacing.md), .fixed(keep), .fixed(confirmDelete)]
        case .testing:
            return [.view(question, .wrapping(question, ideal: { [question] in question.idealWidth })), .spacer(PiSpacing.md), .fixed(cancelTest), .fixed(confirmTest)]
        case .normal:
            var items: [StackLayout.Item] = []
            if !delete.isHidden { items.append(.fixed(delete)) }
            if !discard.isHidden { items.append(.fixed(discard)) }
            if !test.isHidden { items.append(.fixed(test)) }
            if let status { items.append(.view(status, .wrapping(status, ideal: { [status] in status.naturalWidth }))) }
            items.append(.spacer(PiSpacing.md))
            if !unsaved.isHidden { items.append(.fixed(unsaved)) }
            items.append(.fixed(save))
            return items
        }
    }
    func height(forWidth width: CGFloat) -> CGFloat { StackLayout.height(items, spacing: PiSpacing.sm, width: width) }
    override func layout() {
        super.layout()
        StackLayout.place(items, spacing: PiSpacing.sm, in: bounds, scale: piScale)
    }
}

/// Settings' sections, down the left: one row each, the open one
/// highlighted, a dot on the icon of a section with unsaved edits.
@MainActor final class SettingsSectionList: NSView {
    var select: (SettingsSection) -> Void = { _ in }
    private let glide = PiKit.SelectionGlide()
    private var rows: [(SettingsSection, PiKit.SelectableRow, SectionRowContent)] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for section in SettingsSection.allCases {
            let content = SectionRowContent(section: section)
            let row = PiKit.SelectableRow(content: content, glide: glide) { [weak self] in self?.select(section) }
            row.setAccessibilityIdentifier("settings-section-" + section.rawValue)
            row.setAccessibilityLabel(section.title)
            addSubview(row)
            rows.append((section, row, content))
        }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piWindow) }
    func update(selection: SettingsSection, edited: Set<SettingsSection>) {
        for (section, row, content) in rows {
            row.selected = section == selection
            content.update(selected: section == selection, edited: edited.contains(section))
            row.setAccessibilityValue(edited.contains(section) ? "Unsaved changes" : "")
        }
    }
    override func layout() {
        super.layout()
        var y = PiSpacing.md
        let width = bounds.width - PiSpacing.md * 2
        for (_, row, _) in rows {
            let height = row.height(forWidth: width)
            row.frame = CGRect(x: PiSpacing.md, y: y, width: width, height: height)
            y += height + 2
        }
    }
}

/// A section's row: its symbol, 18 points wide, and its title.
@MainActor final class SectionRowContent: NSView, PiKit.WidthSizing {
    private let symbol: PiKit.SymbolView
    private let title: PiKit.TextLine
    private let dot = FillView(.piWarning)
    init(section: SettingsSection) {
        symbol = PiKit.SymbolView(PiKit.Symbol(section.symbol, size: 12, weight: .medium), color: .piInkSecondary)
        title = PiKit.TextLine(PiKit.Line(section.title, font: PiKit.Font.body, color: .piInk))
        super.init(frame: .zero)
        dot.layer?.cornerRadius = 3
        dot.setAccessibilityElement(false)
        for view in [symbol, title, dot] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func update(selected: Bool, edited: Bool) {
        symbol.color = selected ? .piAccent : .piInkSecondary
        dot.isHidden = !edited
    }
    private var symbolHeight: CGFloat { symbol.intrinsicContentSize.height }
    func height(forWidth width: CGFloat) -> CGFloat { max(symbolHeight, title.intrinsicContentSize.height) }
    override func layout() {
        super.layout()
        let frames = StackLayout.place([.view(symbol, .fixed(CGSize(width: 18, height: symbolHeight))), .line(title)], spacing: 8, in: bounds, scale: piScale)
        // Unsaved edits mark the icon, so the title keeps its room.
        dot.frame = CGRect(x: frames[0].maxX - 6 + 2, y: frames[0].minY - 2, width: 6, height: 6)
    }
}

/// Opens the catalog picker for the connection being edited: the bundled
/// Bello catalog needs nothing, a custom catalog on the gateway's origin
/// uses the key typed above (or the saved one), and the list follows the
/// URL fields as they change.
@MainActor final class CatalogModelMenuButton: PiKit.ButtonBase, OwnEnabled, ProposedWidthSizing {
    private let model: WorkspaceModel
    private let controller: ConnectionSettingsController
    private let mini: Bool
    private let spinner = PiKit.spinner(controlSize: .mini)
    private let popover = AnchoredPopover()
    private var label = "Choose"
    private var loading = false
    private var shownProfile: String?
    init(model: WorkspaceModel, controller: ConnectionSettingsController, mini: Bool) {
        self.model = model; self.controller = controller; self.mini = mini
        super.init(frame: .zero)
        pressScales = false
        disabledOpacity = PiKit.plainDisabledDimming
        addSubview(spinner)
        setAccessibilityIdentifier(mini ? "settings-mini-model-menu" : "settings-model-menu")
        onPress = { [weak self] in self?.toggle() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    func refresh() {
        let draft = controller.draft
        label = mini ? (draft.profile.miniModelId ?? "Catalog default") : "Choose"
        loading = controller.listingEntry.loading
        spinner.isHidden = !loading
        toolTip = controller.supportedAPI ? "Search every model from the bundled Bello catalog or this connection's custom catalog." : "Choose Use Responses above to list models."
        setAccessibilityLabel(mini ? "Mini model: \(draft.profile.miniModelId ?? "Catalog default")" : "Choose connection model")
        if let shownProfile, shownProfile != draft.profile.id { popover.close() }
        shownProfile = draft.profile.id
        invalidateIntrinsicContentSize(); redrawContent(); needsLayout = true
    }
    private func toggle() {
        if popover.isShown { popover.close(); return }
        let controller = controller, mini = mini
        let draft = controller.draft
        let close = { [weak self] in self?.popover.close() }
        let content = CatalogModelPickerView(model: model, profile: controller.listingProfile, current: mini ? draft.profile.miniModelId : draft.profile.modelId,
                                                    draft: .init(profile: draft.profile, key: draft.key),
                                                    defaultTitle: mini ? "Use catalog Mini default" : nil, defaultSelected: mini && draft.profile.miniModelId == nil,
                                                    useDefault: mini ? { close(); controller.useCatalogMiniDefault() } : nil) { item in
            close()
            if mini { controller.chooseMini(item) } else { controller.choose(item) }
        }
        let viewController = NSViewController()
        content.frame = NSRect(origin: .zero, size: content.intrinsicContentSize)
        viewController.view = content; viewController.preferredContentSize = content.intrinsicContentSize
        content.sizeChanged = { [weak content, weak viewController] in
            guard let content, let viewController else { return }
            viewController.preferredContentSize = content.intrinsicContentSize
        }
        popover.showController(viewController, from: self, edge: .maxX)
    }

    /// Only for a connection whose API lists models.
    var ownEnabled: Bool { controller.supportedAPI }
    /// As wide as its label wants, or what it is offered: the label is cut.
    func width(forProposal proposal: CGFloat) -> CGFloat { min(intrinsicContentSize.width, max(0, proposal)) }

    // A capsule: the list symbol, the label, a spinner while the catalog is
    // read, and a chevron, 10 by 6 points in.
    private var labelLine: PiKit.Line { PiKit.Line(label, font: .systemFont(ofSize: 12, weight: .medium), color: .piInk) }
    private let icon = PiKit.Symbol("list.bullet.rectangle", size: 11, weight: .semibold)
    private let chevron = PiKit.Symbol("chevron.down", size: 9, weight: .semibold)
    private var parts: [CGSize] {
        var sizes = [icon.layoutSize, labelLine.size(scale: piScale)]
        if loading { sizes.append(CGSize(width: 10, height: 10)) }
        sizes.append(chevron.layoutSize)
        return sizes
    }
    override var intrinsicContentSize: NSSize {
        let sizes = parts
        return NSSize(width: sizes.reduce(0) { $0 + $1.width } + 5 * CGFloat(sizes.count - 1) + 20, height: (sizes.map(\.height).max() ?? 0) + 12)
    }
    override func cornerRadius(for size: CGSize) -> CGFloat { size.height / 2 }
    override func styleFace() {
        fill.backgroundColor = piCGColor(.piSurface)
        stroke.borderColor = piCGColor(.piHairlineStrong)
    }
    override func layout() {
        super.layout()
        if loading {
            let sizes = parts
            let others = sizes.enumerated().filter { $0.offset != 1 }.reduce(0) { $0 + $1.element.width } + 5 * CGFloat(sizes.count - 1) + 20
            let x = 10 + sizes[0].width + 5 + max(0, min(sizes[1].width, bounds.width - others)) + 5
            spinner.frame = CGRect(x: x, y: PiKit.round((bounds.height - 10) / 2, piScale), width: 10, height: 10)
        }
    }
    override func drawContent(in rect: CGRect) {
        let scale = piScale, sizes = parts
        var x: CGFloat = 10
        icon.draw(centredIn: CGRect(x: x, y: 0, width: sizes[0].width, height: rect.height), color: .piInk, scale: scale)
        x += sizes[0].width + 5
        // What is left for the label once the rest has its room.
        let others = sizes.enumerated().filter { $0.offset != 1 }.reduce(0) { $0 + $1.element.width } + 5 * CGFloat(sizes.count - 1) + 20
        let text = CGSize(width: max(0, min(sizes[1].width, rect.width - others)), height: sizes[1].height)
        labelLine.draw(in: CGRect(x: x, y: PiKit.round((rect.height - text.height) / 2, scale), width: text.width, height: text.height), truncation: .middle, scale: scale)
        x += text.width + 5
        if loading { x += 10 + 5 }
        chevron.draw(centredIn: CGRect(x: x, y: 0, width: sizes.last!.width, height: rect.height), color: .piInkTertiary, scale: scale)
    }
}

/// Settings' sections, down the left of the sheet and of the window.
enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case connections, usage, chats, app
    var id: String { rawValue }
    var title: String {
        switch self {
        case .connections: return "Connections"
        case .usage: return "Usage & capture"
        case .chats: return "Chats & notifications"
        case .app: return "App"
        }
    }
    var symbol: String {
        switch self {
        case .connections: return "network"
        case .usage: return "chart.bar"
        case .chats: return "bubble.left.and.bubble.right"
        case .app: return "gearshape"
        }
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

