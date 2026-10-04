import AppKit
import QuartzCore

// The conversation pane's own pieces around the transcript: a side's
// header, the recovered-submissions banner, the starter card, the loading
// cover, the missing-folder bar and the read-only footers.

/// A symbol as an unstyled SwiftUI `Image(systemName:)` showed it: the body
/// font's size, regular weight.
@MainActor func shellBodySymbol(_ name: String, color: NSColor) -> PiKit.SymbolView {
    PiKit.SymbolView(PiKit.Symbol(name, size: 13), color: color)
}
@MainActor func shellLine(_ text: String, font: NSFont, color: NSColor, truncation: CTLineTruncationType = .end) -> PiKit.TextLine {
    let line = PiKit.TextLine(PiKit.Line(text, font: font, color: color))
    line.truncation = truncation
    return line
}

// MARK: - A side's header

/// The side pane keeps a slim header: its name, whether it is saved, what it
/// shares, and its own controls.
@MainActor final class SideHeaderView: NSView, PiKit.WidthSizing {
    private let model: WorkspaceModel
    var actions: SideActions?
    private var chatID = ""
    private var sessionID = ""
    private let plainTitle = shellLine("Side conversation", font: PiKit.Font.title(15), color: .piInk)
    private let titleButton = TitleButton()
    private var badge = PiKit.Badge(text: "")
    private let badgeSlot = ShellStack(.horizontal, spacing: 0)
    private let boundary = shellLine("", font: PiKit.Font.caption, color: .piInkTertiary)
    private let bringBack = PiKit.IconButton(symbol: "arrow.uturn.backward", label: "Bring Back to Parent Draft…")
    private let keep = PiKit.Button("Keep", symbol: "pin", style: .secondary, compact: true)
    private var actionsMenu: ConversationActionsMenuView
    private let close = PiKit.IconButton(symbol: "xmark", label: "Close side", size: 26)
    private let stack: ShellStack
    private var badgeKey = ""

    /// A kept side's title: a plain button that renames the chat.
    final class TitleButton: PiKit.ButtonBase, ShellCutting {
        var text = "" { didSet { if oldValue != text { invalidateIntrinsicContentSize(); redrawContent() } } }
        var line: PiKit.Line { PiKit.Line(text, font: PiKit.Font.title(15), color: .piInk) }
        override init(frame: NSRect) {
            super.init(frame: frame)
            pressScales = false; disabledOpacity = PiKit.plainDisabledDimming; hitsShapeOnly = false
            toolTip = "Rename chat"; setAccessibilityIdentifier("renameSessionTitle")
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var intrinsicContentSize: NSSize { line.size(scale: piScale) }
        func cutWidth(_ width: CGFloat) -> CGFloat { shellTruncatedWidth(line, width: width, truncation: .end, scale: piScale) }
        override func drawContent(in rect: CGRect) { line.draw(in: rect, truncation: .end, scale: piScale) }
        override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
        override func cornerRadius(for size: CGSize) -> CGFloat { 0 }
    }

    init(model: WorkspaceModel) {
        self.model = model
        actionsMenu = ConversationActionsMenuView(model: model, sessionID: "")
        let titleRow = ShellStack(.horizontal, spacing: 6, [.view(plainTitle), .view(titleButton, .flexible), .view(badgeSlot)])
        stack = ShellStack(.horizontal, spacing: PiSpacing.sm, padding: NSEdgeInsets(top: 10, left: PiSpacing.lg, bottom: 8, right: PiSpacing.lg), [
            .view(ShellStack(.vertical, spacing: 3, [.view(titleRow, .fill), .view(boundary, .fill)]), .flexible),
            .spacer(PiSpacing.sm),
            .view(bringBack), .view(keep), .view(actionsMenu), .view(close),
        ])
        super.init(frame: .zero)
        addSubview(stack)
        bringBack.onPress = { [weak self] in self?.actions?.bringBack() }
        keep.onPress = { [weak self] in self?.actions?.keep() }
        close.onPress = { [weak self] in self?.actions?.close() }
        titleButton.onPress = { [weak self] in guard let self else { return }; self.model.renameSession(self.chatID) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func update(side: SideRecord, chat: ChatRecord, session: SessionDisplay, boundary text: String, detail: String, loading: Bool) {
        chatID = chat.id
        if sessionID != session.id { sessionID = session.id; actionsMenu.sessionID = session.id; actionsMenu.session = session }
        plainTitle.isHidden = side.kept
        titleButton.isHidden = !side.kept
        titleButton.text = chat.title
        titleButton.isEnabled = !chat.isBackgroundTask
        titleButton.setAccessibilityLabel("Rename chat: " + chat.title)
        let key = side.pending ? "pending" : side.kept ? "kept" : "memory"
        if key != badgeKey {
            badgeKey = key
            badge = side.pending ? PiKit.Badge(text: "Created when you send", icon: "square.and.pencil")
                : PiKit.Badge(text: side.kept ? "Saved · Read-only" : "In memory", tone: side.kept ? .success : .warning, icon: "arrow.triangle.branch")
            badgeSlot.items = [.view(badge)]
        }
        boundary.line.text = text; boundary.toolTip = detail
        keep.isHidden = side.pending || side.kept
        keep.title = side.keeping ? "Keeping…" : side.keepRequested ? "Keep Requested" : "Keep"
        keep.isEnabled = !(side.keeping || side.keepRequested || loading)
        close.isEnabled = !(side.keeping || loading)
        stack.relayoutAll()
        PiKit.sizeChanged(self)
    }
    func height(forWidth width: CGFloat) -> CGFloat { stack.height(forWidth: width) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() { super.layout(); stack.frame = bounds }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piContent) }
}

// MARK: - Interrupted submissions

@MainActor final class RecoveredBannerView: NSView, PiKit.WidthSizing {
    var changed: (() -> Void)?
    private let box = PiKit.Box(fill: NSColor.piWarning.withAlphaComponent(0.10), stroke: NSColor.piWarning.withAlphaComponent(0.35), cornerRadius: PiRadius.md,
                                padding: NSEdgeInsets(top: PiSpacing.md, left: PiSpacing.md, bottom: PiSpacing.md, right: PiSpacing.md))
    private var stack = ShellStack(.vertical, spacing: PiSpacing.sm)
    private var shownIDs: [String] = []

    init() {
        super.init(frame: .zero)
        box.content = stack
        addSubview(box)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    func update(_ intents: [CommandIntent], model: WorkspaceModel) {
        let ids = intents.map(\.id)
        guard ids != shownIDs else { return }
        shownIDs = ids
        var items: [ShellItem] = [.view(ShellStack(.horizontal, spacing: 6, [
            .view(shellBodySymbol("exclamationmark.triangle.fill", color: .piWarning)),
            .view(shellLine("Interrupted submissions", font: PiKit.Font.heading, color: .labelColor)),
            .view(shellLine("· Nothing was resent", font: PiKit.Font.caption, color: .piInkSecondary)),
        ]))]
        for intent in intents {
            items.append(.view(ShellStack(.horizontal, spacing: 8, [
                .view(shellLine(intent.text, font: PiKit.Font.body, color: .labelColor), .flexible),
                .spacer(8),
                .view(PiKit.Button("Insert in Draft", style: .secondary, compact: true) { model.recoverDraft(intent, insert: true) }),
                .view(PiKit.Button("Dismiss", style: .ghost) { model.recoverDraft(intent, insert: false) }),
            ]), .fill))
        }
        stack.items = items
        box.content = stack
        changed?()
    }
    func height(forWidth width: CGFloat) -> CGFloat { PiKit.height(of: box, width: width - PiSpacing.lg * 2) + PiSpacing.sm }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() {
        super.layout()
        box.frame = CGRect(x: PiSpacing.lg, y: PiSpacing.sm, width: max(0, bounds.width - PiSpacing.lg * 2), height: max(0, bounds.height - PiSpacing.sm))
    }
}

// MARK: - The starter card

/// What an empty chat is connected to, and where to start. Gone with the
/// first message; it holds the chat's id and reaches the model, never the page.
@MainActor final class StarterPanelView: NSView, PiKit.WidthSizing {
    static let maximumWidth: CGFloat = 560
    private let box = PiKit.Box(fill: .piSurface, stroke: .piHairline, cornerRadius: PiRadius.md,
                                padding: NSEdgeInsets(top: PiSpacing.lg, left: PiSpacing.lg, bottom: PiSpacing.lg, right: PiSpacing.lg))
    private var stack = ShellStack(.vertical, spacing: PiSpacing.md)
    private var key: String?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        box.content = stack
        addSubview(box)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityIdentifier("starterPanel")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    /// Everything the card shows, in one string: it is drawn again when this changes.
    static func key(model: WorkspaceModel, chat: ChatRecord, sessionID: String) -> String {
        let workspace = model.workspace(for: chat.workspaceID)
        let profile = model.profiles.first { $0.id == chat.profileID }
        let modelName = chat.model ?? profile?.modelId ?? "catalog default"
        return [chat.id, workspace?.path ?? "", (workspace?.roots ?? []).joined(separator: "|"), profile?.name ?? "\u{0}", modelName,
                chat.toolMode, "\(model.side(sessionID) != nil)", "\(model.canOpenSide(sessionID))", chat.workspaceID].joined(separator: "\u{1}")
    }
    func update(model: WorkspaceModel, chat: ChatRecord, sessionID: String) {
        let workspace = model.workspace(for: chat.workspaceID)
        let profile = model.profiles.first { $0.id == chat.profileID }
        let modelName = chat.model ?? profile?.modelId ?? "catalog default"
        let isSide = model.side(sessionID) != nil
        let canOpenSide = model.canOpenSide(sessionID)
        let key = Self.key(model: model, chat: chat, sessionID: sessionID)
        guard key != self.key else { return }
        let first = self.key == nil
        self.key = key
        let icon = NSImageView(image: NSImage(named: "BelloAgentIcon") ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel("Bello Agent")
        let iconRow = ShellStack(.horizontal, spacing: 0, [.spacer(0), .view(icon, .fixed(48)), .spacer(0)])
        icon.frame.size = CGSize(width: 48, height: 48)
        let fixedIcon = FixedSizeView(content: icon, size: CGSize(width: 48, height: 48))
        iconRow.items = [.spacer(0), .view(fixedIcon), .spacer(0)]
        var names: [ShellItem] = [.view(shellLine(workspace.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? chat.workspaceID,
                                                  font: PiKit.Font.heading, color: .piInk), .flexible)]
        for root in (workspace?.roots ?? []).prefix(4) {
            names.append(.view(shellLine(root, font: PiKit.Font.micro, color: .piInkTertiary, truncation: .middle), .flexible))
        }
        let project = ShellStack(.horizontal, spacing: PiSpacing.sm, [
            .view(PiKit.IconBadge(symbol: "folder", tone: .accent, size: 28)),
            .view(ShellStack(.vertical, spacing: 2, names), .flexible),
        ])
        let readOnly = chat.toolMode == ChatRecord.readOnlyTools
        let badges = ShellStack(.horizontal, spacing: PiSpacing.sm, [
            .view(PiKit.Badge(text: profile?.name ?? "No connection", tone: profile == nil ? .danger : .neutral, icon: "antenna.radiowaves.left.and.right")),
            .view(PiKit.Badge(text: modelName, icon: "cpu")),
            .view(PiKit.Badge(text: readOnly ? "Read-only tools" : "Editing tools", icon: readOnly ? "eye" : "pencil")),
        ])
        let hint = shellLine("Type below to start. Your first message creates the chat.", font: PiKit.Font.caption, color: .piInkSecondary)
        let flow = PiKit.FlowView()
        flow.spacing = PiSpacing.sm; flow.rowSpacing = PiSpacing.sm
        if !isSide, chat.workspaceID != WorkspaceRecord.scratchID {
            flow.addSubview(PiKit.Button("Changes", symbol: "arrow.triangle.branch", style: .secondary, compact: true) { model.showChanges(in: chat.workspaceID) })
            flow.addSubview(PiKit.Button("Terminal", symbol: "terminal", style: .secondary, compact: true) { model.toggleTerminal() })
        }
        flow.addSubview(PiKit.Button("Skills", symbol: "command", style: .secondary, compact: true) { model.inspectResources(sessionID) })
        if !isSide {
            let open = PiKit.Button("Open a side", symbol: "arrow.triangle.branch", style: .secondary, compact: true) { model.openSide(parentID: sessionID) }
            open.isEnabled = canOpenSide
            flow.addSubview(open)
        }
        let parts: [NSView] = [iconRow, project, badges, hint, flow]
        stack = ShellStack(.vertical, spacing: PiSpacing.md, parts.map { .view($0, $0 === hint ? .natural : .fill) })
        box.content = stack
        needsLayout = true
        // Each line arrives a beat after the one above it, the first time.
        if first { layoutSubtreeIfNeeded(); for (index, view) in parts.enumerated() { PiKit.appear(view, index: index) } }
    }
    func height(forWidth width: CGFloat) -> CGFloat { PiKit.height(of: box, width: width) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() { super.layout(); box.frame = bounds }
}

/// A view at one fixed size, whatever its content says.
@MainActor final class FixedSizeView: NSView {
    let size: CGSize
    let content: NSView
    init(content: NSView, size: CGSize) {
        self.size = size; self.content = content
        super.init(frame: NSRect(origin: .zero, size: size))
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { size }
    override func layout() { super.layout(); content.frame = bounds }
}

// MARK: - The loading cover

/// The canvas over a chat whose page is still being read, with the app mark
/// breathing; or, when the read failed, what went wrong and Retry.
@MainActor final class LoadingCoverView: NSView {
    private let mark = LoadingMarkView()
    private let progress = shellLine("", font: PiKit.Font.caption, color: .piInkSecondary)
    private let failureTitle = shellLine("Couldn’t load this conversation", font: PiKit.Font.heading, color: .labelColor)
    private let failureText = ShellSelectableText("", font: PiKit.Font.caption, color: .piInkSecondary)
    private let retry = PiKit.Button("Retry", style: .secondary, compact: true)
    private var retryAction: (() -> Void)?
    private var failing = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for view in [mark, progress, failureTitle, failureText, retry] as [NSView] { addSubview(view) }
        retry.onPress = { [weak self] in self?.retryAction?() }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = piCGColor(.piContent) }

    func showLoading(progress text: String?) {
        failing = false
        mark.isHidden = false
        progress.isHidden = text == nil; progress.line.text = text ?? ""
        for view in [failureTitle, failureText, retry] as [NSView] { view.isHidden = true }
        needsLayout = true
    }
    func showFailure(_ error: String, retry action: @escaping () -> Void) {
        failing = true; retryAction = action
        mark.isHidden = true; progress.isHidden = true
        failureText.text = error
        for view in [failureTitle, failureText, retry] as [NSView] { view.isHidden = false }
        needsLayout = true
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() {
        super.layout()
        let scale = piScale
        if failing {
            let width = min(max(0, bounds.width - PiSpacing.lg * 2), max(failureTitle.intrinsicContentSize.width, failureText.naturalWidth, retry.intrinsicContentSize.width))
            let textHeight = failureText.height(forWidth: width)
            let total = failureTitle.intrinsicContentSize.height + PiSpacing.md + textHeight + PiSpacing.md + retry.intrinsicContentSize.height
            var y = PiKit.round((bounds.height - total) / 2, scale)
            let titleSize = failureTitle.intrinsicContentSize
            failureTitle.frame = CGRect(x: PiKit.round((bounds.width - titleSize.width) / 2, scale), y: y, width: titleSize.width, height: titleSize.height)
            y += titleSize.height + PiSpacing.md
            let textWidth = min(width, failureText.naturalWidth)
            failureText.frame = CGRect(x: PiKit.round((bounds.width - textWidth) / 2, scale), y: y, width: textWidth, height: textHeight)
            y += textHeight + PiSpacing.md
            let retrySize = retry.intrinsicContentSize
            retry.frame = CGRect(x: PiKit.round((bounds.width - retrySize.width) / 2, scale), y: y, width: retrySize.width, height: retrySize.height)
        } else {
            let markSize = mark.intrinsicContentSize
            let progressHeight = progress.isHidden ? 0 : progress.intrinsicContentSize.height + PiSpacing.md
            var y = PiKit.round((bounds.height - markSize.height - progressHeight) / 2, scale)
            mark.frame = CGRect(x: PiKit.round((bounds.width - markSize.width) / 2, scale), y: y, width: markSize.width, height: markSize.height)
            y += markSize.height + PiSpacing.md
            if !progress.isHidden {
                let size = progress.intrinsicContentSize
                progress.frame = CGRect(x: PiKit.round((bounds.width - size.width) / 2, scale), y: y, width: size.width, height: size.height)
            }
        }
    }
}

/// The app mark with a soft pulse while a chat is being prepared and has nothing to show yet.
@MainActor final class LoadingMarkView: NSView {
    private let icon = NSImageView(image: NSImage(named: "BelloAgentIcon") ?? NSImage())
    private let spinner = PiKit.spinner(controlSize: .small)
    private let label = shellLine("Preparing…", font: PiKit.Font.caption, color: .piInkSecondary)
    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.setAccessibilityLabel("Bello Agent")
        for view in [icon, spinner, label] as [NSView] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityIdentifier("loadingMark")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    private var rowWidth: CGFloat { 16 + 6 + label.intrinsicContentSize.width }
    override var intrinsicContentSize: NSSize {
        NSSize(width: max(56, rowWidth), height: 56 + PiSpacing.md + max(16, label.intrinsicContentSize.height))
    }
    override func layout() {
        super.layout()
        let scale = piScale
        icon.frame = CGRect(x: PiKit.round((bounds.width - 56) / 2, scale), y: 0, width: 56, height: 56)
        let rowY = 56 + PiSpacing.md, rowHeight = max(16, label.intrinsicContentSize.height)
        let x = PiKit.round((bounds.width - rowWidth) / 2, scale)
        spinner.frame = CGRect(x: x, y: rowY + PiKit.round((rowHeight - 16) / 2, scale), width: 16, height: 16)
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: x + 22, y: rowY + PiKit.round((rowHeight - size.height) / 2, scale), width: size.width, height: size.height)
        breathe()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); breathe() }
    /// Breathing in and out over 1.1 seconds, for as long as it is shown.
    private func breathe() {
        guard let layer = icon.layer else { return }
        guard window != nil, !PiKit.Motion.reduced else { layer.removeAnimation(forKey: "breathe"); layer.opacity = 1; return }
        guard layer.animation(forKey: "breathe") == nil else { return }
        // Scale about the icon's centre.
        let frame = layer.frame
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5); layer.frame = frame
        let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 1; scale.toValue = 1.06
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.82; fade.toValue = 1
        let group = CAAnimationGroup(); group.animations = [scale, fade]
        group.duration = 1.1; group.autoreverses = true; group.repeatCount = .infinity
        group.timingFunction = PiKit.Motion.timing(.easeInOut)
        layer.add(group, forKey: "breathe")
    }
}

// MARK: - Below the transcript

/// The project's folder is gone: where it was, and a way to find it again.
@MainActor final class MissingFolderBar: NSView, PiKit.WidthSizing {
    private let text = shellLine("", font: PiKit.Font.caption, color: .piInkSecondary, truncation: .middle)
    private let locate = PiKit.Button("Locate Folder…", style: .secondary, compact: true)
    private let stack: ShellStack
    private var workspaceID = ""
    private weak var model: WorkspaceModel?
    init() {
        stack = ShellStack(.horizontal, spacing: PiSpacing.sm, padding: NSEdgeInsets(top: PiSpacing.sm, left: PiSpacing.md, bottom: 0, right: PiSpacing.md), [
            .view(shellBodySymbol("folder.badge.questionmark", color: .piWarning)), .view(text, .flexible), .spacer(8), .view(locate),
        ])
        super.init(frame: .zero)
        addSubview(stack)
        locate.setAccessibilityIdentifier("locateProjectFolder")
        locate.onPress = { [weak self] in
            guard let self, let model = self.model else { return }
            let id = self.workspaceID
            Task { await model.locateMissingFolder(id) }
        }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func update(_ missing: String, workspaceID: String, model: WorkspaceModel) {
        self.workspaceID = workspaceID; self.model = model
        text.line.text = "Project folder not found · \(missing)"; text.toolTip = missing
    }
    func height(forWidth width: CGFloat) -> CGFloat { stack.height(forWidth: width) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() { super.layout(); stack.frame = bounds }
}

/// What stands where the composer would when the chat cannot take a message.
@MainActor final class PaneFooterView: NSView, PiKit.WidthSizing {
    struct Profile: Equatable { var id: String; var name: String }
    enum Kind: Equatable {
        case composer
        case projectUnavailable(retry: Bool)
        case backgroundTask(busy: Bool, source: String?)
        case archived
        case damaged
        case imported(choice: String, profiles: [Profile])
    }
    private var kind: Kind?
    private var content: NSView?
    private var importedDropdown: PiKit.Dropdown<String>?
    /// The chat its buttons act on: whichever is shown now.
    private var chatID = ""
    private weak var session: SessionDisplay?

    override var isFlipped: Bool { true }

    func update(_ kind: Kind, chat: ChatRecord, session: SessionDisplay, model: WorkspaceModel) {
        chatID = chat.id; self.session = session
        // The imported footer's connection list follows the model in place.
        if case .imported(let choice, let profiles) = kind, case .imported = self.kind, let dropdown = importedDropdown {
            dropdown.items = [("", "Choose Responses connection")] + profiles.map { ($0.id, $0.name) }
            dropdown.selection = choice
            self.kind = kind
            return
        }
        guard kind != self.kind else { return }
        self.kind = kind
        content?.removeFromSuperview()
        importedDropdown = nil
        let view: NSView
        switch kind {
        case .composer:
            view = NSView()
        case .projectUnavailable(let retry):
            let button = retry ? PiKit.Button("Retry", style: .secondary, compact: true) { model.retryConfiguration() }
                : PiKit.Button("Configure Projects…", style: .secondary, compact: true) { model.showWorkspaceManager = true }
            view = ShellStack(.horizontal, spacing: PiSpacing.sm, padding: Self.padding, [
                .view(shellBodySymbol("folder.badge.questionmark", color: .piInkSecondary)),
                .view(shellLine("Project unavailable · Retained history is read-only", font: PiKit.Font.caption, color: .piInkSecondary), .flexible),
                .spacer(8), .view(button),
            ])
        case .backgroundTask(let busy, let source):
            var items: [ShellItem] = [
                .view(shellBodySymbol("sparkle", color: .piAccent)),
                .view(shellLine("Background task · Tools disabled", font: PiKit.Font.caption, color: .piInkSecondary), .flexible),
                .spacer(8),
            ]
            if busy { items.append(.view(PiKit.Button("Stop task", symbol: "stop.fill", style: .danger) { [weak self] in
                guard let self else { return }
                model.stop(sessionID: self.session?.id ?? self.chatID)
            })) }
            if let source { items.append(.view(PiKit.Button("Open source chat", style: .secondary, compact: true) { Task { await model.select(source) } })) }
            view = ShellStack(.horizontal, spacing: PiSpacing.sm, padding: Self.padding, items)
        case .archived:
            let restore = PiKit.Button("Restore Chat", style: .secondary, compact: true) { [weak self] in
                if let self { model.toggleSessionArchive(self.chatID) }
            }
            restore.setAccessibilityIdentifier("restoreArchivedChat")
            view = Self.readOnly(symbol: "archivebox", tone: .piInkSecondary, title: "Archived · Read-only",
                                 detail: "Restore the chat to send messages, steer or resume its queue.", button: restore, name: "Archived chat")
        case .damaged:
            let recover = PiKit.Button("Recover Copy", style: .secondary, compact: true) { [weak self] in
                if let self { model.recoverCopy(self.chatID) }
            }
            recover.setAccessibilityIdentifier("recoverDamagedChat")
            view = Self.readOnly(symbol: "exclamationmark.triangle", tone: .piWarning, title: "Last record incomplete · Read-only",
                                 detail: "Recover Copy makes a new chat from every complete record. This chat's file stays as it is.", button: recover,
                                 name: "Chat with an incomplete last record")
        case .imported(let choice, let profiles):
            let dropdown = PiKit.Dropdown(selection: choice, items: [("", "Choose Responses connection")] + profiles.map { ($0.id, $0.name) },
                                          placeholder: "Choose Responses connection", icon: "antenna.radiowaves.left.and.right",
                                          accessibilityName: "Responses connection") { model.profileChoice = $0 }
            importedDropdown = dropdown
            let inner = ShellStack(.vertical, spacing: PiSpacing.sm, [
                .view(ShellStack(.horizontal, spacing: 6, [.view(shellBodySymbol("doc.text", color: .piInkSecondary)),
                                                          .view(shellLine("Imported original · Read-only", font: PiKit.Font.heading, color: .labelColor))])),
                .view(ShellText("A portable context draft starts a separate chat from its text; the imported file stays untouched.",
                                font: PiKit.Font.caption, color: .piInkSecondary), .fill),
                .view(ShellStack(.horizontal, spacing: PiSpacing.sm, [
                    .view(dropdown), .view(PiKit.Button("Portable Context Draft…", style: .primary) { model.portableHandoff() }), .spacer(0),
                ]), .fill),
            ])
            let card = PiKit.elevated(PaddedView(inner, padding: NSEdgeInsets(top: PiSpacing.lg, left: PiSpacing.lg, bottom: PiSpacing.lg, right: PiSpacing.lg)))
            view = PaddedView(card, padding: NSEdgeInsets(top: PiSpacing.sm, left: PiSpacing.lg, bottom: PiSpacing.sm, right: PiSpacing.lg))
        }
        content = view
        addSubview(view)
        needsLayout = true
    }
    private static let padding = NSEdgeInsets(top: PiSpacing.md, left: PiSpacing.md, bottom: PiSpacing.md, right: PiSpacing.md)
    private static func readOnly(symbol: String, tone: NSColor, title: String, detail: String, button: NSView, name: String) -> NSView {
        let stack = ShellStack(.horizontal, spacing: PiSpacing.sm, padding: padding, [
            .view(shellBodySymbol(symbol, color: tone)),
            .view(ShellStack(.vertical, spacing: 2, [.view(shellLine(title, font: PiKit.Font.heading, color: .labelColor)),
                                                     .view(ShellText(detail, font: PiKit.Font.caption, color: .piInkSecondary), .fill)]), .flexible),
            .spacer(8), .view(button),
        ])
        stack.setAccessibilityElement(true); stack.setAccessibilityRole(.group); stack.setAccessibilityLabel(name)
        return stack
    }
    func height(forWidth width: CGFloat) -> CGFloat { content.map { PiKit.height(of: $0, width: width) } ?? 0 }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() { super.layout(); content?.frame = bounds }
}

/// A view inside padding, sized by its content.
@MainActor final class PaddedView: NSView, PiKit.WidthSizing {
    let content: NSView
    let padding: NSEdgeInsets
    init(_ content: NSView, padding: NSEdgeInsets) {
        self.content = content; self.padding = padding
        super.init(frame: .zero)
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func height(forWidth width: CGFloat) -> CGFloat {
        PiKit.height(of: content, width: width - padding.left - padding.right) + padding.top + padding.bottom
    }
    override var intrinsicContentSize: NSSize {
        let size = shellNaturalSize(content)
        return NSSize(width: size.width + padding.left + padding.right, height: size.height + padding.top + padding.bottom)
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() {
        super.layout()
        content.frame = CGRect(x: padding.left, y: padding.top, width: max(0, bounds.width - padding.left - padding.right),
                               height: max(0, bounds.height - padding.top - padding.bottom))
    }
}
