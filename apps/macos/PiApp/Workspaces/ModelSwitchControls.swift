import AppKit
import SwiftUI

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

/// What the pills read from the workspace, and the words they share.
@MainActor enum ModelSwitchPills {
    /// The effort pill's label says whose default is in force ("Effort ·
    /// connection default"), which needs more room than the word "default"
    /// did: at 130 points the widest of them was truncated down the middle.
    static let effortLabelWidth: CGFloat = 176

    /// Everything one chat's pills show, read once.
    struct Reading: Equatable {
        var chatID: String?
        var profileID: String?
        var contents: ModelSwitchPillContents
        var connectionActive: Bool
        var modelActive: Bool
        var effortActive: Bool
        var modelHelp: String
        var disabled: Bool
    }
    static func chat(_ model: WorkspaceModel, _ session: SessionDisplay) -> ChatRecord? { model.record(session.id) }
    static func profile(_ model: WorkspaceModel, _ chat: ChatRecord?) -> ProfileRecord? {
        chat.flatMap { item in model.profiles.first { $0.id == item.profileID } }
    }
    static func override(_ chat: ChatRecord?) -> String? { TurnOverrides.normalizedModel(chat?.model) }
    static func level(_ chat: ChatRecord?) -> ThinkingLevel { chat?.thinkingLevel.flatMap(ThinkingLevel.init(rawValue:)) ?? .profileDefault }
    static func showsConnection(_ model: WorkspaceModel, profile: ProfileRecord?) -> Bool {
        model.requestProfiles.count > 1 || profile == nil || profile?.api != LiteLLMConfiguration.supportedAPI
    }

    /// The strings and flags the bar measures, from the same places the pills
    /// read them, so a measurement can never describe a different pill.
    static func contents(model: WorkspaceModel, session: SessionDisplay) -> ModelSwitchPillContents {
        reading(model: model, session: session).contents
    }
    static func reading(model: WorkspaceModel, session: SessionDisplay) -> Reading {
        let chat = chat(model, session), profile = profile(model, chat), override = override(chat), level = level(chat)
        let modelLabel = override ?? profile?.modelId ?? "Model"
        let contents = ModelSwitchPillContents(showsConnection: showsConnection(model, profile: profile),
                                               connection: profile?.name ?? "No connection", model: modelLabel, effort: level.pillLabel,
                                               loading: profile.map { model.catalogEntry(for: $0).loading } ?? false)
        let help = (override.map { "Model override for this chat: \($0). Profile default: \(profile?.modelId ?? "")." } ?? "Model from the profile.")
            + " Your choice is remembered for new chats using this connection."
        return Reading(chatID: chat?.id, profileID: profile?.id, contents: contents, connectionActive: profile == nil,
                       modelActive: override != nil, effortActive: level != .profileDefault, modelHelp: help,
                       disabled: session.loading || model.installPreparing || chat == nil)
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
    static func offeredLevels(model: WorkspaceModel, chat: ChatRecord?) -> [ThinkingLevel] {
        guard let profile = profile(model, chat),
              let descriptor = model.catalogEntry(for: profile).descriptor(for: override(chat) ?? profile.modelId) else { return ThinkingLevel.allCases }
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

/// The three pills on the composer bar. Each opens its list in a popover
/// under the pointer; the pills give up detail before they push the send
/// button off the bar (`ComposerPillsForm`, chosen by the bar).
@MainActor final class ModelSwitchPillsView: NSView {
    private let model: WorkspaceModel
    /// The chat shown; nil once retired.
    private var session: SessionDisplay?
    let connection: ComposerPillButton
    let modelPill: ComposerPillButton
    let effort: ComposerPillButton
    private var reading: ModelSwitchPills.Reading?
    var form: ComposerPillsForm = .named { didSet { if oldValue != form { apply() } } }
    /// The disabled state handed down from the window (`.disabled`).
    var inheritedEnabled = true { didSet { if oldValue != inheritedEnabled { apply() } } }
    private var popover: NSPopover?
    /// Which pill the open popover belongs to.
    private weak var popoverAnchor: NSView?
    /// What the open connection or effort list shows, so an update that
    /// changes nothing leaves it alone.
    private var listShown: ListContents?
    private struct ListContents: Equatable {
        var ids: [String]
        var titles: [String]
        var enabled: [Bool]
        var selection: String?
        var note: String?
    }
    /// The catalog read for this chat's connection, so a visible picker loads without a hover.
    private var listing: Task<Void, Never>?
    private var listedSource: ProfileRecord?
    private var observer: ShellObserver?

    init(model: WorkspaceModel, session: SessionDisplay? = nil) {
        self.model = model
        connection = ComposerPillButton(icon: "antenna.radiowaves.left.and.right", text: "", maxTextWidth: 150)
        modelPill = ComposerPillButton(icon: "cpu", text: "", maxTextWidth: 170)
        effort = ComposerPillButton(icon: "brain", text: "", maxTextWidth: ModelSwitchPills.effortLabelWidth)
        super.init(frame: .zero)
        connection.toolTip = "The LiteLLM connection, key and model list this chat uses. Switching closes its helper session; the next turn replays the chat's portable history on the new connection."
        connection.setAccessibilityIdentifier("session-connection-picker")
        modelPill.setAccessibilityIdentifier("session-model-picker")
        effort.toolTip = "Profile default keeps the connection's effort. Model default leaves effort unspecified. Your choice is remembered for new chats using this connection."
        effort.setAccessibilityIdentifier("session-reasoning-picker")
        connection.onPress = { [weak self] in self?.toggleConnections() }
        modelPill.onPress = { [weak self] in self?.toggleModels() }
        effort.onPress = { [weak self] in self?.toggleEfforts() }
        for pill in [connection, modelPill, effort] { addSubview(pill) }
        setAccessibilityElement(true); setAccessibilityRole(.group)
        if let session { show(session) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    /// Another chat: its pills, and no list left open for the one before.
    func show(_ session: SessionDisplay) {
        guard session !== self.session || observer == nil else { return }
        self.session = session
        // The workspace, the catalog and the chat itself (its record, its loading).
        let observer = ShellObserver { [weak self] in self?.refresh() }
        observer.observe(model); observer.observe(model.modelCatalog); observer.observe(session)
        self.observer = observer
        closePopover()
        reading = nil
        refresh()
    }

    /// Lets go of its chat: no list left open, no read, no watching.
    func retire() {
        observer = nil; session = nil
        closePopover()
        listing?.cancel(); listing = nil; listedSource = nil
        reading = nil
    }

    /// Reads the workspace again and changes only what differs.
    func refresh() {
        guard let session else { return }
        let now = ModelSwitchPills.reading(model: model, session: session)
        let profile = ModelSwitchPills.profile(model, ModelSwitchPills.chat(model, session))
        let source = profile.map { model.catalogProfile(for: $0) }
        // As `.task(id: catalogProfile)`: a new source restarts the read, the same one never does.
        if source != listedSource {
            listedSource = source
            listing?.cancel()
            if let profile { listing = Task { [weak model] in _ = await model?.listModels(for: profile) } }
        }
        if now.chatID != reading?.chatID { closePopover() }
        refreshOpenList()
        guard now != reading else { return }
        reading = now
        apply()
    }

    private func apply() {
        guard let reading, let session else { return }
        let contents = reading.contents
        let chat = ModelSwitchPills.chat(model, session)
        connection.isHidden = !contents.showsConnection
        connection.text = contents.connection; connection.active = reading.connectionActive
        connection.compact = form.connectionIsCompact
        connection.setAccessibilityLabel("Connection: \(ModelSwitchPills.profile(model, chat)?.name ?? "none")")
        modelPill.text = contents.model; modelPill.active = reading.modelActive; modelPill.loading = contents.loading
        modelPill.maxTextWidth = form.modelWidth; modelPill.compact = form.modelIsCompact
        modelPill.toolTip = reading.modelHelp
        modelPill.setAccessibilityLabel("Model: \(contents.model)")
        effort.text = contents.effort; effort.active = reading.effortActive
        effort.compact = form.effortIsCompact
        effort.setAccessibilityLabel("Reasoning effort: \(ModelSwitchPills.level(chat).label)")
        for pill in [connection, modelPill, effort] { pill.isEnabled = !reading.disabled && inheritedEnabled }
        invalidateIntrinsicContentSize(); needsLayout = true
        PiKit.sizeChanged(self)
    }

    private var shownPills: [ComposerPillButton] { [connection, modelPill, effort].filter { !$0.isHidden } }
    override var intrinsicContentSize: NSSize {
        let sizes = shownPills.map(\.intrinsicContentSize)
        return NSSize(width: sizes.map(\.width).reduce(0, +) + CGFloat(max(0, sizes.count - 1)) * ComposerBarMetrics.spacing,
                      height: sizes.map(\.height).max() ?? 0)
    }
    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for pill in shownPills {
            let size = pill.intrinsicContentSize
            pill.frame = CGRect(x: x, y: PiKit.round((bounds.height - size.height) / 2, piScale), width: size.width, height: size.height)
            x += size.width + ComposerBarMetrics.spacing
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closePopover() }
    }

    // MARK: Lists

    private func closePopover() {
        popover?.close(); popover = nil; popoverAnchor = nil; listShown = nil
    }
    /// Opens `content` from `anchor`, or closes the list when it is that pill's.
    private func toggle(_ anchor: NSView, _ content: () -> NSViewController) {
        if let popover, popover.isShown {
            let same = popoverAnchor === anchor
            closePopover()
            if same { return }
        }
        guard anchor.window != nil else { return }
        let controller = content()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !PiKit.Motion.reduced
        popover.contentViewController = controller
        self.popover = popover; popoverAnchor = anchor
        // The arrow on the pill's top edge, the list above it, as `.popover(arrowEdge: .top)`.
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .minY : .maxY)
        controller.view.window?.makeFirstResponder(controller.view)
    }
    private func controller(_ list: NSView) -> NSViewController {
        let controller = NSViewController()
        controller.view = list
        list.layoutSubtreeIfNeeded()
        controller.preferredContentSize = list.frame.size
        return controller
    }

    // The connection list.
    private func connectionContents() -> ListContents {
        let chat = session.flatMap { ModelSwitchPills.chat(model, $0) }
        let blocker = chat.flatMap { model.connectionSwitchBlocker(for: $0.id) }
        let profiles = model.requestProfiles
        return ListContents(ids: profiles.map(\.id), titles: profiles.map { $0.name + "\u{1}" + $0.modelId },
                            enabled: profiles.map { blocker == nil || $0.id == chat?.profileID }, selection: chat?.profileID, note: blocker)
    }
    private func connectionList(_ contents: ListContents) -> PiKit.ChoiceList<String> {
        let profiles = model.requestProfiles
        let choices = zip(profiles, contents.enabled).map { PiKit.Choice(id: $0.id, title: $0.name, subtitle: $0.modelId, enabled: $1) }
        return PiKit.ChoiceList(title: "Connection", selection: contents.selection, choices: choices, note: contents.note,
                                actionTitle: "Manage Connections…",
                                action: { [weak self] in self?.closePopover(); self?.model.showProfiles = true },
                                choose: { [weak self] id in
                                    guard let self else { return }
                                    self.closePopover()
                                    guard let session = self.session, let chat = ModelSwitchPills.chat(self.model, session) else { return }
                                    let model = self.model
                                    Task { await model.setConnection(id, for: chat.id) }
                                }, cancel: { [weak self] in self?.closePopover() })
    }
    private func toggleConnections() {
        let contents = connectionContents()
        toggle(connection) { listShown = contents; return controller(connectionList(contents)) }
    }

    // The effort list.
    private func effortContents() -> ListContents {
        let chat = session.flatMap { ModelSwitchPills.chat(model, $0) }
        let levels = ModelSwitchPills.offeredLevels(model: model, chat: chat)
        let level = ModelSwitchPills.level(chat)
        let note = !levels.contains(level) ? "Current effort is unavailable for this model. Choose another level." :
            levels.count < ThinkingLevel.allCases.count ? "Levels from the model catalog" : nil
        return ListContents(ids: levels.map(\.rawValue), titles: levels.map(\.label), enabled: levels.map { _ in true },
                            selection: level.rawValue, note: note)
    }
    private func effortList(_ contents: ListContents) -> PiKit.ChoiceList<ThinkingLevel> {
        let levels = contents.ids.compactMap(ThinkingLevel.init(rawValue:))
        return PiKit.ChoiceList(title: "Reasoning effort", selection: contents.selection.flatMap(ThinkingLevel.init(rawValue:)),
                                choices: levels.map { PiKit.Choice(id: $0, title: $0.label) }, note: contents.note,
                                choose: { [weak self] option in
                                    guard let self else { return }
                                    self.closePopover()
                                    guard let session = self.session, let chat = ModelSwitchPills.chat(self.model, session) else { return }
                                    let model = self.model
                                    Task { await model.setThinkingLevel(option.rawValue, for: chat.id) }
                                }, cancel: { [weak self] in self?.closePopover() })
    }
    private func toggleEfforts() {
        let contents = effortContents()
        toggle(effort) { listShown = contents; return controller(effortList(contents)) }
    }

    /// An open connection or effort list follows the workspace where it
    /// stands: a catalog that arrives takes away what the model cannot do,
    /// and its note says so. A list whose contents did not change is left alone.
    private func refreshOpenList() {
        guard let popover, popover.isShown, let shown = listShown, let controller = popover.contentViewController else { return }
        let now = popoverAnchor === connection ? connectionContents() : popoverAnchor === effort ? effortContents() : shown
        guard now != shown else { return }
        listShown = now
        // The same list when only its rows changed: it keeps the keyboard's
        // row and its scroll. A new note needs a new list, which then goes
        // back to the row the keyboard was on.
        if popoverAnchor === connection, let list = controller.view as? PiKit.ChoiceList<String> {
            if now.note == shown.note {
                let profiles = model.requestProfiles
                list.update(selection: now.selection, choices: zip(profiles, now.enabled).map { PiKit.Choice(id: $0.id, title: $0.name, subtitle: $0.modelId, enabled: $1) })
                controller.preferredContentSize = list.frame.size
            } else { replace(list, with: connectionList(now), in: controller) }
        } else if let list = controller.view as? PiKit.ChoiceList<ThinkingLevel> {
            if now.note == shown.note {
                let levels = now.ids.compactMap(ThinkingLevel.init(rawValue:))
                list.update(selection: now.selection.flatMap(ThinkingLevel.init(rawValue:)), choices: levels.map { PiKit.Choice(id: $0, title: $0.label) })
                controller.preferredContentSize = list.frame.size
            } else { replace(list, with: effortList(now), in: controller) }
        }
    }
    private func replace<Tag: Hashable>(_ old: PiKit.ChoiceList<Tag>, with new: PiKit.ChoiceList<Tag>, in controller: NSViewController) {
        let highlighted = old.highlighted
        controller.view = new
        new.layoutSubtreeIfNeeded()
        controller.preferredContentSize = new.frame.size
        new.window?.makeFirstResponder(new)
        let enabled = new.choices.filter(\.enabled).map(\.id)
        if let highlighted, let target = enabled.firstIndex(of: highlighted), let current = new.highlighted, let from = enabled.firstIndex(of: current),
           target != from {
            new.move(target - from)
        }
    }

    private func toggleModels() {
        guard let session, let chat = ModelSwitchPills.chat(model, session), let profile = ModelSwitchPills.profile(model, chat) else { return }
        let override = ModelSwitchPills.override(chat)
        let label = override ?? profile.modelId
        let model = self.model, chatID = chat.id
        toggle(modelPill) {
            // TEMPORARY bridge: the catalog picker is still SwiftUI.
            let picker = CatalogModelPicker(model: model, profile: profile, current: label, allowsCatalogSelection: true,
                                            defaultTitle: "Use connection default · \(profile.modelId)", defaultSelected: override == nil,
                                            useDefault: { [weak self] in self?.closePopover(); Task { await model.setModel(nil, for: chatID) } },
                                            manualEntry: { [weak self] alias in
                                                self?.closePopover()
                                                Task { await model.setModel(alias.isEmpty ? nil : alias, for: chatID) }
                                            }) { [weak self] item in
                self?.closePopover()
                Task { await model.setModel(item.id, for: chatID) }
            }
            let host = NSHostingController(rootView: picker)
            host.sizingOptions = [.preferredContentSize]
            return host
        }
    }
}
