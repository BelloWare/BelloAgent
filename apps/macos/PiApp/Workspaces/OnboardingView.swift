import AppKit
import Combine

/// First-launch flow: connect a LiteLLM gateway, choose a model, open a workspace.
@MainActor final class OnboardingContentView: NSView, PiKit.SizeObserver {
    let model: WorkspaceModel
    let setup = OnboardingState()
    private var filter = ""
    private var folderError = ""
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let icon = NSImageView()
    private let title = PiKit.TextLine(PiKit.Line("", font: PiKit.Font.display(30), color: .piInk))
    private let subtitle = TextBlock("", font: PiKit.Font.body, color: .piInkSecondary, centred: true)
    private let steps = OnboardingSteps()
    private let card = PiKit.Box(fill: .piSurface, stroke: .piHairline, cornerRadius: PiRadius.lg)
    private let cardStack = VerticalStack(spacing: PiSpacing.lg, padding: NSEdgeInsets(top: PiSpacing.xl, left: PiSpacing.xl, bottom: PiSpacing.xl, right: PiSpacing.xl))
    private var status: PiKit.Note?
    private let cancelTest = PiKit.Button("Cancel Connection Test", style: .secondary)
    private let enabled = EnabledState()
    private var updaters: [() -> Void] = []
    private var folders: HostedSwiftUI?
    private var builtKey: Key?
    private var observations: [AnyCancellable] = []
    private var refreshScheduled = false
    private var appeared = false
    /// What the model list was last read for: a change asks for it again.
    private var listedFor: [String?] = []

    init(model: WorkspaceModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        icon.image = NSImage(named: "BelloAgentIcon"); icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        card.shadowColor = .piShadow; card.shadowRadius = 12; card.shadowOffsetY = 4
        card.clipsContent = true
        card.content = cardStack
        for view in [icon, title, subtitle, steps, card] as [NSView] { document.addSubview(view) }
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        // From the window's top, under the title bar, as the SwiftUI flow's
        // scroll view began: no inset for the bar.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = document
        addSubview(scroll)
        cancelTest.onPress = { [setup] in setup.cancelConnectionTest() }
        addSubview(cancelTest)
        observations.append(setup.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() })
        observations.append(model.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() })
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piContent) }
    func contentSizeChanged() { needsLayout = true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !appeared {
            appeared = true
            setup.resume(profiles: model.profiles, preferredID: model.profileChoice)
            if model.profiles.contains(where: { $0.id == setup.profile.id }) { model.profileChoice = setup.profile.id }
            if model.selectedWorkspaceID == nil { model.selectedWorkspaceID = model.workspaces.first(where: \.trusted)?.id }
        } else if window == nil, appeared {
            // Gone: what was being read or tested stops.
            setup.invalidateModelList(); setup.cancelConnectionTest()
        }
    }

    private func scheduleRefresh() {
        needsLayout = true
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { if self?.refreshScheduled == true { self?.refresh() } } }
    }

    private var selectedWorkspace: WorkspaceRecord? { model.workspaces.first { $0.id == model.selectedWorkspaceID } }
    private var filteredModels: [String] { filter.isEmpty ? setup.models : setup.models.filter { $0.localizedCaseInsensitiveContains(filter) } }

    /// What decides which views a step has: built again only when it
    /// changes. Values (a field's text, the list's rows, a hint) update in place.
    private struct Key: Hashable {
        var step: Int, workspace: String?, trusted: Bool, folderError: Bool
    }
    func refresh() {
        refreshScheduled = false
        // The address, API, catalog or key changed: the list read for the old ones goes.
        let listing: [String?] = [setup.profile.baseUrl, setup.profile.api, setup.profile.catalogUrl, setup.key]
        if !listedFor.isEmpty, listing != listedFor { setup.invalidateModelList() }
        listedFor = listing
        title.line.text = setup.resumedFromSaved ? "Welcome back" : "Welcome to Bello Agent"
        subtitle.text = setup.resumedFromSaved ? "Your connection is saved. Choose a project and start a chat."
            : "Three quick steps: connect your LiteLLM gateway, pick a model, open a project."
        steps.step = setup.step.rawValue
        // The workspace step's views follow the project; the other steps keep
        // their fields mounted and show or hide their notes and lists.
        let workspaceStep = setup.step == .workspace
        let key = Key(step: setup.step.rawValue, workspace: workspaceStep ? selectedWorkspace?.id : nil, trusted: workspaceStep && selectedWorkspace?.trusted == true,
                      folderError: workspaceStep && !folderError.isEmpty)
        if key != builtKey { builtKey = key; build() }
        updaters.forEach { $0() }
        setStatus(setup.message, tone: setup.message.hasPrefix("Saved") ? .success : .danger)
        cancelTest.isHidden = !setup.testingConnection
        enabled.apply(to: document, formEnabled: !setup.busy)
        folders?.disabled = setup.busy
        needsLayout = true
    }
    private var gatewayHint: String { setup.gatewayHint }
    private func setStatus(_ text: String, tone: PiTone) {
        if text.isEmpty { status?.removeFromSuperview(); status = nil; return }
        if let status, status.text == text, status.tone == tone { return }
        status?.removeFromSuperview()
        let note = PiKit.Note(text, tone: tone)
        document.addSubview(note); status = note
    }

    // MARK: Layout

    private var contentWidth: CGFloat { min(600, max(0, scroll.contentView.bounds.width - PiSpacing.xl * 2)) }
    override func layout() {
        if refreshScheduled { refresh() }
        super.layout()
        let testing = !cancelTest.isHidden
        let button = cancelTest.intrinsicContentSize
        let bottom = testing ? button.height + PiSpacing.md * 2 : 0
        scroll.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - bottom)
        if testing { cancelTest.frame = CGRect(x: PiKit.round((bounds.width - button.width) / 2, piScale), y: bounds.height - bottom + PiSpacing.md, width: button.width, height: button.height) }
        layoutDocument()
        // A document taller than the view brings a scroller, which takes its width.
        let before = scroll.contentView.bounds.width
        scroll.tile()
        if scroll.contentView.bounds.width != before { layoutDocument() }
    }
    private func layoutDocument() {
        let width = scroll.contentView.bounds.width, inner = contentWidth, x = PiKit.round((width - inner) / 2, piScale)
        var y: CGFloat = 48
        // The greeting: the icon, the title and a line, 10 apart.
        icon.frame = CGRect(x: PiKit.round((width - 72) / 2, piScale), y: y, width: 72, height: 72); y += 72 + 10
        let titleSize = title.intrinsicContentSize
        title.frame = CGRect(x: PiKit.round((width - titleSize.width) / 2, piScale), y: y, width: titleSize.width, height: titleSize.height); y += titleSize.height + 10
        let subtitleWidth = min(subtitle.idealWidth, inner), subtitleHeight = subtitle.height(forWidth: subtitleWidth)
        subtitle.frame = CGRect(x: PiKit.round((width - subtitleWidth) / 2, piScale), y: y, width: subtitleWidth, height: subtitleHeight); y += subtitleHeight + PiSpacing.xl
        let stepsSize = steps.size(forWidth: inner)
        steps.frame = CGRect(x: PiKit.round((width - stepsSize.width) / 2, piScale), y: y, width: stepsSize.width, height: stepsSize.height); y += stepsSize.height + PiSpacing.xl
        let cardHeight = cardStack.height(forWidth: inner)
        card.frame = CGRect(x: x, y: y, width: inner, height: cardHeight); y += cardHeight
        if let status {
            y += PiSpacing.xl
            let height = status.height(forWidth: inner)
            status.frame = CGRect(x: x, y: y, width: inner, height: height); y += height
        }
        y += 48
        document.frame = CGRect(x: 0, y: 0, width: width, height: max(y, scroll.contentView.bounds.height))
    }

    // MARK: Steps

    private func build() {
        updaters = []; folders = nil
        switch setup.step {
        case .gateway: cardStack.setItems(gateway())
        case .model: cardStack.setItems(modelStep())
        case .workspace: cardStack.setItems(workspace())
        }
    }
    /// A labelled control: the label in small capitals, 5 points above it.
    private func field(_ label: String, _ control: NSView) -> NSView {
        let caption = PiKit.TextLine(PiKit.Line(label, font: PiKit.Font.micro, color: .piInkSecondary, tracking: 0.4, uppercased: true))
        let stack = VerticalStack(spacing: 5)
        stack.setItems([LeadingView(caption), control])
        return stack
    }
    private func textField(placeholder: String, icon: String? = nil, secure: Bool = false, mono: Bool = false,
                           get: @escaping () -> String, set: @escaping (String) -> Void) -> PiKit.TextField {
        let field = PiKit.TextField(placeholder: placeholder, text: get(), icon: icon, secure: secure, mono: mono, onChange: set)
        updaters.append { [weak field] in field?.text = get() }
        return field
    }
    private func caption(_ text: String) -> TextBlock { TextBlock(text, font: PiKit.Font.caption, color: .piInkTertiary) }
    private func row(_ items: [NSView], spacing: CGFloat = StackLayout.system, layout: @escaping () -> [StackLayout.Item]) -> HStackView {
        let row = HStackView(spacing: spacing, flexible: true, views: items)
        row.items = layout
        return row
    }

    private func gateway() -> [NSView] {
        let setup = setup
        var items: [NSView] = [
            PiKit.SectionHeader("Connect your LiteLLM gateway", subtitle: "The key is stored in your macOS Keychain and is only sent to this gateway."),
            field("Connection name", textField(placeholder: "Team router", get: { setup.profile.name }, set: { setup.profile.name = $0 })),
            field("Gateway URL", textField(placeholder: "https://litellm.example.com", icon: "link", mono: true, get: { setup.profile.baseUrl }, set: { setup.profile.baseUrl = $0 })),
            field("API key", textField(placeholder: "sk-…", icon: "key", secure: true, get: { setup.key }, set: { setup.key = $0 })),
            field("Custom model catalog URL · optional", textField(placeholder: "Blank uses the Bello model catalog", icon: "list.bullet.rectangle", mono: true,
                                                                   get: { setup.profile.catalogUrl ?? "" }, set: { setup.profile.catalogUrl = $0.isEmpty ? nil : $0 })),
            caption("The Bello model catalog is included. Set a URL to replace it with your own list, context sizes and reasoning levels. External catalogs are fetched anonymously."),
        ]
        let stored = PiKit.Note("Leave the key empty to keep its saved value. Re-enter it only to refresh a custom catalog on the gateway's origin.")
        updaters.append { [weak stored] in stored?.isHidden = !setup.hasStoredKey }
        items.append(stored)
        items.append(field("API", LeadingView(PiKit.TextLine(PiKit.Line("Responses", font: PiKit.Font.body, color: .piInkSecondary)))))
        // A disabled Continue always says what it is waiting for.
        let next = PiKit.Button("Continue", symbol: "arrow.right", style: .primary) {
            setup.step = .model; Task { await setup.listModels() }
        }
        next.symbolTrailing = true
        updaters.append { [weak next, weak self] in if let next { self?.enabled.set(next, setup.gatewayReady) } }
        let hint = PiKit.Note(setup.gatewayHint)
        identify(hint, "onboarding-gateway-hint")
        let hintRow = row([hint, next]) { [weak hint] in
            var items: [StackLayout.Item] = []
            if let hint, !hint.isHidden { items.append(.view(hint, .wrapping(hint, ideal: { hint.naturalWidth }))) }
            return items + [.spacer(), .fixed(next)]
        }
        updaters.append { [weak hint, weak hintRow] in
            hint?.text = setup.gatewayHint; hint?.isHidden = setup.gatewayHint.isEmpty
            hintRow?.invalidateIntrinsicContentSize(); hintRow?.needsLayout = true
        }
        items.append(hintRow)
        return items
    }

    private func modelStep() -> [NSView] {
        let setup = setup
        let refresh = PiKit.Button("Refresh", symbol: "arrow.clockwise", style: .ghost) { Task { await setup.listModels() } }
        let spinner = PiKit.spinner(controlSize: .small)
        let accessory = HStackView(spacing: 0, views: [spinner, refresh])
        accessory.items = { setup.listing ? [.fixed(spinner)] : [.fixed(refresh)] }
        var items: [NSView] = [PiKit.SectionHeader("Choose a model", subtitle: "Catalog choices set the model's context and output ceiling. Your output budget stays separate. The gateway must support the selected alias.",
                                                   accessory: accessory)]
        let error = PiKit.Note("", tone: .warning)
        let filterField = PiKit.TextField(placeholder: "Filter models", text: filter, icon: "magnifyingglass") { [weak self] in self?.filter = $0; self?.scheduleRefresh() }
        let list = OnboardingModelList(setup: setup, ids: filteredModels)
        let loadingSpinner = PiKit.spinner(controlSize: .small)
        let loadingText = PiKit.TextLine(PiKit.Line("Loading the model catalog…", font: PiKit.Font.caption, color: .piInkSecondary))
        let loading = row([loadingSpinner, loadingText], spacing: 8) { [.fixed(loadingSpinner), .fixed(loadingText), .spacer(0)] }
        updaters.append { [weak self, weak accessory, weak error, weak filterField, weak list, weak loading, weak spinner, weak refresh] in
            guard let self else { return }
            spinner?.isHidden = !setup.listing; refresh?.isHidden = setup.listing
            accessory?.invalidateIntrinsicContentSize(); accessory?.needsLayout = true
            error?.text = setup.listError; error?.isHidden = setup.listError.isEmpty
            let models = !setup.models.isEmpty
            filterField?.isHidden = !models; list?.isHidden = !models
            if models { list?.update(ids: self.filteredModels) }
            loading?.isHidden = models || !setup.listing
        }
        items += [error, filterField, list, loading]
        items.append(field("Model or router alias", textField(placeholder: "gpt-5.1 or claude-router", icon: "cpu", mono: true,
                                                              get: { setup.profile.modelId }, set: { setup.profile.modelId = $0 })))
        let context = PiKit.NumberField(placeholder: "Tokens", value: setup.profile.contextWindow, width: 130) { setup.profile.contextWindow = $0 }
        context.field.setAccessibilityLabel("Context capacity, tokens")
        let output = PiKit.NumberField(placeholder: "Tokens", value: setup.profile.maxOutputTokens, width: 130) { setup.profile.maxOutputTokens = $0 }
        output.field.setAccessibilityLabel("Output budget, tokens")
        updaters.append { [weak context, weak output] in
            if let context, context.field.currentEditor() == nil { context.value = setup.profile.contextWindow }
            if let output, output.field.currentEditor() == nil { output.value = setup.profile.maxOutputTokens }
        }
        let contextField = field("Context capacity", context), outputField = field("Output budget", output)
        items.append(row([contextField, outputField], spacing: PiSpacing.md) {
            [.view(contextField, .fixed(CGSize(width: 130, height: PiKit.height(of: contextField, width: 130)))),
             .view(outputField, .fixed(CGSize(width: 130, height: PiKit.height(of: outputField, width: 130)))), .spacer()]
        })
        let note = caption("")
        updaters.append { [weak note] in
            note?.text = "The output budget only sizes the reserve the context estimate keeps for a reply; it is never sent as a limit. Model output ceiling: "
                + (setup.profile.modelOutputLimit.map { "\($0.formatted()) tokens, sent with every request." } ?? "not supplied, so requests carry no output limit.")
        }
        items.append(note)
        let back = PiKit.Button("Back", symbol: "arrow.left", style: .ghost) { setup.invalidateModelList(); setup.step = .gateway }
        let save = PiKit.Button("Save and Continue", symbol: "arrow.right", style: .primary) { [weak self] in Task { await self?.save() } }
        save.symbolTrailing = true
        updaters.append { [weak save, weak self] in
            guard let save else { return }
            save.title = setup.saving ? "Saving…" : "Save and Continue"
            self?.enabled.set(save, !(setup.profile.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || setup.saving))
        }
        items.append(row([back, save]) { [.fixed(back), .spacer(), .fixed(save)] })
        return items
    }

    private func workspace() -> [NSView] {
        let setup = setup, model = model
        let trusted = selectedWorkspace?.trusted == true
        var items: [NSView] = [trusted
            ? PiKit.SectionHeader("Start your first chat", subtitle: "Your project is ready. Test & Start sends one small request to the selected model, then opens the chat. Add more folders below if a task spans several.")
            : PiKit.SectionHeader("Create a project", subtitle: "Choose the primary folder Bello Agent may read, then add more folders if a task spans several. Editing chats can also run commands and change files there with your permissions.")]
        if selectedWorkspace != nil {
            let folders = SettingsBridges.folderList(model: model, workspace: { [weak self] in self?.selectedWorkspace }, onError: { [weak self] in
                self?.folderError = $0; self?.scheduleRefresh()
            })
            updaters.append { folders.update() }
            self.folders = folders
            items.append(folders)
            if !folderError.isEmpty {
                let note = PiKit.Note(folderError, tone: .danger)
                updaters.append { [weak note, weak self] in note?.text = self?.folderError ?? "" }
                items.append(note)
            }
        }
        items.append(PiKit.Note("Test & Start sends one small request to the selected model. Tools and project contents are excluded. Gateway usage may be charged; you can inspect the request in Requests."))
        items.append(caption("Request and response bodies are saved locally for 30 days by default, within the storage quota. Authentication headers are masked. Change capture and retention in Settings."))
        let back = PiKit.Button("Back", symbol: "arrow.left", style: .ghost) { setup.step = .model }
        let choose = PiKit.Button(selectedWorkspace == nil ? "Choose Primary Folder…" : "Change Primary Folder…", symbol: "house", style: .secondary) { [weak self] in
            self?.folderError = ""; model.pickWorkspace()
        }
        var buttons: [NSView] = [back, choose]
        if trusted {
            let start = PiKit.Button("Test & Start Chat", symbol: "arrow.right", style: .primary) { [weak self] in
                guard let self else { return }
                let verified = self.selectedWorkspace
                Task {
                    await setup.finish(hasTrustedWorkspace: self.selectedWorkspace?.trusted == true,
                                       verifyConnection: { try await model.verifyOnboardingConnection($0) }) {
                        guard model.profileChoice == setup.profile.id, self.selectedWorkspace == verified else { throw ConnectionProbeError.changed }
                        try await model.createOnboardingChat()
                    }
                }
            }
            start.symbolTrailing = true
            updaters.append { [weak start] in start?.title = setup.testingConnection ? "Testing Connection…" : setup.finishing ? "Starting…" : "Test & Start Chat" }
            buttons.append(start)
        }
        items.append(row(buttons) { [.fixed(back), .spacer()] + buttons.dropFirst().map { .fixed($0) } })
        return items
    }

    private func save() async {
        let saved = await setup.save { [model] profile, key in
            try await model.saveProfile(profile, key: key)
            guard let saved = model.profiles.first(where: { $0.id == model.profileChoice }) else {
                throw HostError.failure("The saved connection could not be reloaded. Reload Settings before continuing.")
            }
            return saved
        }
        if saved, model.selectedWorkspaceID == nil { model.selectedWorkspaceID = model.workspaces.first(where: \.trusted)?.id }
    }
}

/// A view at its own width at the leading edge of what it is given.
@MainActor final class LeadingView: NSView, PiKit.WidthSizing {
    let content: NSView
    init(_ content: NSView) { self.content = content; super.init(frame: .zero); addSubview(content) }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func height(forWidth width: CGFloat) -> CGFloat { content.intrinsicContentSize.height }
    override func layout() {
        super.layout()
        let size = content.intrinsicContentSize
        content.frame = CGRect(x: 0, y: 0, width: min(size.width, bounds.width), height: size.height)
    }
}

/// The three steps, numbered, the done ones ticked, joined by short lines.
@MainActor final class OnboardingSteps: NSView {
    var step = 0 { didSet { if oldValue != step { needsDisplay = true; needsLayout = true } } }
    private let titles = ["Gateway", "Model", "Project"]
    override var isFlipped: Bool { true }
    private func line(_ index: Int) -> PiKit.Line {
        PiKit.Line(titles[index], font: .systemFont(ofSize: 12.5, weight: index == step ? .semibold : .regular), color: index == step ? .piInk : .piInkSecondary)
    }
    /// The width the steps take in `width`, their joins up to 60 points each.
    func size(forWidth width: CGFloat) -> CGSize {
        let scale = window?.backingScaleFactor ?? 2
        let parts = (0..<3).reduce(CGFloat(0)) { $0 + 22 + 8 + line($1).size(scale: scale).width }
        let joins = max(0, min(60, (width - parts) / 2 - PiSpacing.md * 2))
        return CGSize(width: parts + 2 * (joins + PiSpacing.md * 2), height: 22)
    }
    override func draw(_ dirtyRect: NSRect) {
        let scale = piScale
        let parts = (0..<3).reduce(CGFloat(0)) { $0 + 22 + 8 + line($1).size(scale: scale).width }
        let join = max(0, (bounds.width - parts) / 2 - PiSpacing.md * 2)
        var x: CGFloat = 0
        for index in 0..<3 {
            (index <= step ? NSColor.piAccent : NSColor.piFillStrong).setFill()
            NSBezierPath(ovalIn: CGRect(x: x, y: 0, width: 22, height: 22)).fill()
            if index < step {
                PiKit.Symbol("checkmark", size: 10, weight: .bold).draw(centredIn: CGRect(x: x, y: 0, width: 22, height: 22), color: .piOnAccent, scale: scale)
            } else {
                let number = PiKit.Line("\(index + 1)", font: .systemFont(ofSize: 11, weight: .semibold), color: index == step ? .piOnAccent : .piInkSecondary)
                let size = number.size(scale: scale)
                number.draw(at: CGPoint(x: PiKit.round(x + (22 - size.width) / 2, scale), y: PiKit.round((22 - size.height) / 2, scale)), scale: scale)
            }
            x += 22 + 8
            let text = line(index), size = text.size(scale: scale)
            text.draw(at: CGPoint(x: x, y: PiKit.round((22 - size.height) / 2, scale)), scale: scale)
            x += size.width
            if index < 2 {
                (index < step ? NSColor.piAccent : NSColor.piHairlineStrong).setFill()
                CGRect(x: x + PiSpacing.md, y: 10.5, width: join, height: 1).fill()
                x += join + PiSpacing.md * 2
            }
        }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "Step \(step + 1) of 3: \(titles[min(step, 2)])" }
}

/// The catalog's models to choose from, 220 points tall at most.
@MainActor final class OnboardingModelList: NSView, PiKit.WidthSizing {
    private let setup: OnboardingState
    private var ids: [String]
    private var shownSelection: String?
    private var shownDescriptors: [String] = []
    /// Each row's height by what decides it, so a choice or a keystroke
    /// elsewhere measures nothing again.
    private var heights: [HeightKey: CGFloat] = [:]
    private struct HeightKey: Hashable { let id: String, width: CGFloat, selected: Bool, item: String }
    private let list = LazyStackView()
    private let box: PiKit.Box
    private let glide = PiKit.SelectionGlide()
    init(setup: OnboardingState, ids: [String]) {
        self.setup = setup; self.ids = ids
        box = PiKit.inset(list, sunken: true)
        super.init(frame: .zero)
        list.spacing = 1
        list.insets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        addSubview(box)
        reload()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    /// The rows as they are now: the same rows keep their place and scroll,
    /// only their state changing.
    func update(ids next: [String]) {
        let rowsSame = next == ids
        // The rows' descriptions too: a refreshed catalog can rename the same ids.
        let described = setup.descriptors.map { "\($0)" }
        guard !rowsSame || shownSelection != setup.profile.modelId || described != shownDescriptors else { return }
        shownDescriptors = described
        ids = next
        // A choice moves the tick, and the two rows' text columns with it.
        reload(keepingHeights: false)
        _ = rowsSame
        PiKit.sizeChanged(self)
    }
    private func reload(keepingHeights: Bool = false) {
        shownSelection = setup.profile.modelId
        let setup = setup, ids = ids, glide = glide
        let source = LazyStackView.Source(count: ids.count, key: { AnyHashable(ids[$0]) }, height: { [weak self] index, width in
            let id = ids[index], item = setup.descriptors.first { $0.id == id }, selected = setup.profile.modelId == id
            let key = HeightKey(id: id, width: width, selected: selected, item: item.map { "\($0)" } ?? "")
            if let known = self?.heights[key] { return known }
            let measured = OnboardingModelRow.height(of: item, id: id, width: width, selected: selected)
            self?.heights[key] = measured
            return measured
        }, view: { index, existing in
            let id = ids[index]
            let row = existing as? OnboardingModelRow ?? OnboardingModelRow(glide: glide)
            row.apply(id: id, item: setup.descriptors.first { $0.id == id }, selected: setup.profile.modelId == id) {
                if let item = setup.descriptors.first(where: { $0.id == id }) { setup.choose(item) } else { setup.profile.modelId = id }
            }
            return row
        })
        if keepingHeights { list.update(source) } else { list.reload(source) }
    }
    func height(forWidth width: CGFloat) -> CGFloat { min(220, CGFloat(max(1, ids.count)) * 34 + 8) }
    override func layout() { super.layout(); box.frame = bounds }
}

/// One model: its name and id, badges for its context, output, effort and
/// images in one row (a squeezed name wraps), its description, and a tick
/// when chosen.
@MainActor final class OnboardingModelRow: NSView {
    private let content = FlippedView()
    let row: PiKit.SelectableRow
    private var headline: [NSView] = []
    private let detail = TextBlock("", font: PiKit.Font.caption, color: .piInkSecondary, maximumLines: 2)
    private let tick = PiKit.SymbolView(PiKit.Symbol("checkmark", size: 11, weight: .bold), color: .piAccent)
    private var selected = false
    init(glide: PiKit.SelectionGlide) {
        row = PiKit.SelectableRow(content: content, glide: glide)
        super.init(frame: .zero)
        for view in [detail, tick] as [NSView] { content.addSubview(view) }
        tick.setAccessibilityElement(false)
        addSubview(row)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    /// The headline's parts: the name, the alias when it differs, and the badges.
    static func parts(_ item: ModelDescriptor?, id: String) -> [NSView] {
        var parts: [NSView] = [TextBlock(item?.displayName ?? id, font: item == nil ? PiKit.Font.mono : PiKit.Font.heading, color: .piInk)]
        if let item, item.displayName != item.id { parts.append(TextBlock(item.id, font: PiKit.Font.mono, color: .piInkSecondary)) }
        if let context = item?.contextLabel { parts.append(PiKit.Badge(text: context)) }
        if let output = item?.outputLimitLabel { parts.append(PiKit.Badge(text: output)) }
        if let efforts = item?.reasoning, !efforts.isEmpty { parts.append(PiKit.Badge(text: "effort " + efforts.joined(separator: "/"), icon: "brain")) }
        if item?.takesImages == true { parts.append(PiKit.Badge(text: "images", icon: "photo")) }
        return parts
    }
    /// Everything the row shows, for VoiceOver: the button's whole content.
    static func spoken(_ item: ModelDescriptor?, id: String) -> String {
        var words: [String] = [item?.displayName ?? id]
        if let item, item.displayName != item.id { words.append(item.id) }
        if let context = item?.contextLabel { words.append(context) }
        if let output = item?.outputLimitLabel { words.append(output) }
        if let efforts = item?.reasoning, !efforts.isEmpty { words.append("effort " + efforts.joined(separator: "/")) }
        if item?.takesImages == true { words.append("images") }
        if let text = item?.description, !text.isEmpty { words.append(text) }
        return words.joined(separator: ", ")
    }
    static func items(_ parts: [NSView]) -> [StackLayout.Item] {
        parts.map { part in
            if let text = part as? TextBlock { return .view(text, .wrapping(text, ideal: { text.idealWidth })) }
            return .fixed(part)
        }
    }
    private static let tickWidth = PiKit.Symbol("checkmark", size: 11, weight: .bold).layoutSize.width
    /// The text column's width in a content area this wide.
    private static func column(_ width: CGFloat, selected: Bool) -> CGFloat { max(0, width - (selected ? 8 + tickWidth : 0)) }
    static func height(of item: ModelDescriptor?, id: String, width: CGFloat, selected: Bool) -> CGFloat {
        let content = width - PiKit.SelectableRow.padding.left - PiKit.SelectableRow.padding.right
        let inner = column(content, selected: selected)
        var height = StackLayout.height(items(parts(item, id: id)), spacing: 6, width: inner)
        if let text = item?.description, !text.isEmpty {
            height += 2 + CGFloat(min(2, PiKit.wrappedLines(text, font: PiKit.Font.caption, width: inner).count)) * PiKit.Line("", font: PiKit.Font.caption, color: .black).lineHeight
        }
        return height + PiKit.SelectableRow.padding.top + PiKit.SelectableRow.padding.bottom
    }
    private var shownContent: String?
    func apply(id: String, item: ModelDescriptor?, selected: Bool, choose: @escaping () -> Void) {
        // The headline's views stay while what they show does.
        let shown = id + "\u{1}" + (item.map { "\($0)" } ?? "")
        if shown != shownContent {
            shownContent = shown
            headline.forEach { $0.removeFromSuperview() }
            headline = Self.parts(item, id: id)
            for part in headline { content.addSubview(part) }
        }
        detail.text = item?.description ?? ""; detail.isHidden = detail.text.isEmpty
        self.selected = selected
        // The row says it is selected; the tick would only repeat it.
        tick.isHidden = !selected
        row.selected = selected
        row.onPress = choose
        row.setAccessibilityLabel(Self.spoken(item, id: id))
        StaticTextAccessibility.asValues(in: content)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        row.frame = bounds
        let width = max(0, bounds.width - PiKit.SelectableRow.padding.left - PiKit.SelectableRow.padding.right)
        let inner = Self.column(width, selected: selected)
        let items = Self.items(headline)
        let headHeight = StackLayout.height(items, spacing: 6, width: inner)
        StackLayout.place(items, spacing: 6, in: CGRect(x: 0, y: 0, width: inner, height: headHeight), scale: piScale)
        let detailHeight = detail.isHidden ? 0 : detail.height(forWidth: inner)
        detail.frame = CGRect(x: 0, y: headHeight + 2, width: inner, height: detailHeight)
        let total = headHeight + (detail.isHidden ? 0 : 2 + detailHeight)
        let size = tick.intrinsicContentSize
        tick.frame = CGRect(x: width - size.width, y: PiKit.round((total - size.height) / 2, piScale), width: size.width, height: size.height)
    }
}
