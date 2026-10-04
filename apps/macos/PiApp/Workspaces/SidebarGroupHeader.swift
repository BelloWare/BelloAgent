import AppKit

/// A project's header strip, as values. The strip is a disclosure, two
/// buttons, a menu and a right-click menu; it is drawn again only when these
/// change.
struct ProjectHeaderState: Equatable {
    var projectID = ""
    var name = ""
    var scratch = false
    var trusted = false
    /// A project whose configuration is gone still lists its retained chats.
    var available = true
    var expanded = true
    /// The filter locks disclosure open, so the header's toggles are disabled.
    var filtering = false
    var chosen = false
    var hasUnread = false
    /// Below `ProjectSidebarGroup.compactHeaderWidth` the strip keeps only its
    /// actions menu; both buttons are in that menu.
    var compact = false
    /// A sibling shares this name's opening, so the tail is what tells them apart.
    var truncatesInTheMiddle = false
    var dropTargeted = false
    var help = ""
}

/// A topic's header strip, on the same terms as the project's.
struct TopicHeaderState: Equatable {
    var projectID = ""
    var topicID = ""
    var title = ""
    var trusted = false
    var expanded = true
    var filtering = false
    var hasUnread = false
    var chats = 0
    var dropTargeted = false
}

/// The "…" of a project or topic header: the header's ink, 20 points wide,
/// with a soft fill under the pointer like every other sidebar control.
@MainActor final class SidebarMenuFace: NSView {
    static let size = CGSize(width: 20, height: 22)
    var hovering = false { didSet { if oldValue != hovering { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize { Self.size }
    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.piFillStrong.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        PiKit.Symbol("ellipsis", size: 13).drawPlaced(centredIn: bounds, color: .piInk, scale: piScale)
    }
}

/// A header's disclosure: a plain button drawing a chevron (turned a quarter
/// when open), an icon, the name, an unread dot when folded, and for a topic
/// its count at the trailing edge. Disabled (while filtering), it dims as a
/// plain button's label does.
@MainActor final class SidebarDisclosureButton: PiKit.ButtonBase {
    struct Face: Equatable {
        var chevronSize: CGFloat
        var chevronWeight: CGFloat
        var icon: String
        var iconSize: CGFloat
        var title: String
        var titleWeight: NSFont.Weight
        var ink: NSColor
        var spacing: CGFloat
        var expanded: Bool
        var dot: Bool
        var count: String?
        var middle: Bool
    }
    var faceState: Face {
        didSet {
            guard oldValue != faceState else { return }
            redrawContent(); chevron.setNeedsDisplay()
            if oldValue.expanded != faceState.expanded { turnChevron(animated: true) }
        }
    }
    /// The chevron on a layer of its own, so opening and closing turn it
    /// (`.rotationEffect` under `PiMotion.glide`) rather than redraw it.
    private let chevron = PiKit.DrawingLayer()
    init(_ face: Face) {
        faceState = face
        super.init(frame: .zero)
        pressScales = false
        hitsShapeOnly = false
        disabledOpacity = PiKit.plainDisabledDimming
        face_.addSublayer(chevron)
        chevron.drawer = { [weak self] rect in
            guard let self else { return }
            PiKit.Symbol("chevron.right", size: self.faceState.chevronSize, weight: .semibold)
                .drawPlaced(centredIn: rect, color: self.faceState.ink, scale: self.piScale)
        }
        turnChevron(animated: false)
    }
    private var face_: CALayer { face }
    private var chevronAngle: CGFloat { faceState.expanded ? .pi / 2 : 0 }
    private func turnChevron(animated: Bool) {
        let from = (chevron.presentation() ?? chevron).value(forKeyPath: "transform.rotation.z") as? CGFloat ?? 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        chevron.setAffineTransform(CGAffineTransform(rotationAngle: chevronAngle))
        CATransaction.commit()
        guard animated, window != nil, !PiKit.Motion.reduced else { chevron.removeAnimation(forKey: "turn"); return }
        let turn = PiKit.Motion.glide("transform.rotation.z")
        turn.fromValue = from; turn.toValue = chevronAngle
        chevron.add(turn, forKey: "turn")
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // A square about the chevron's centre, so a quarter turn keeps it on the pixel grid.
        let side = bounds.height
        let transform = chevron.affineTransform()
        chevron.setAffineTransform(.identity)
        chevron.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        chevron.position = CGPoint(x: 5, y: bounds.height / 2)
        chevron.setAffineTransform(transform)
        chevron.contentsScale = piScale
        chevron.appearance = effectiveAppearance
        CATransaction.commit()
        chevron.setNeedsDisplay()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        chevron.appearance = effectiveAppearance; chevron.setNeedsDisplay()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override func cornerRadius(for size: CGSize) -> CGFloat { 0 }
    override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
    private var line: PiKit.Line { PiKit.Line(faceState.title, font: .systemFont(ofSize: 12, weight: faceState.titleWeight), color: faceState.ink) }
    private var countLine: PiKit.Line? {
        faceState.count.map { PiKit.Line($0, font: PiKit.Font.monospacedDigits(PiKit.Font.micro), color: .piInkTertiary) }
    }
    override var intrinsicContentSize: NSSize {
        let scale = piScale
        let icon = PiKit.Symbol(faceState.icon, size: faceState.iconSize, weight: .medium).layoutSize
        var width = 10 + faceState.spacing + icon.width + faceState.spacing + line.size(scale: scale).width
        if faceState.dot { width += faceState.spacing + UnreadDotView.size }
        if let countLine { width += faceState.spacing + countLine.size(scale: scale).width }
        return NSSize(width: width, height: max(line.lineHeight, icon.height))
    }
    override func drawContent(in rect: CGRect) {
        let scale = piScale
        var x: CGFloat = 0
        // The chevron (its own layer) takes the first ten points.
        x += 10 + faceState.spacing
        let icon = PiKit.Symbol(faceState.icon, size: faceState.iconSize, weight: .medium)
        icon.drawPlaced(centredIn: CGRect(x: x, y: 0, width: icon.layoutSize.width, height: rect.height), color: faceState.ink, scale: scale)
        x += icon.layoutSize.width + faceState.spacing
        // What follows the name: the dot, then (a topic's) the count at the end.
        var trailing: CGFloat = 0
        if let countLine { trailing = countLine.size(scale: scale).width + faceState.spacing }
        let dotRoom = faceState.dot ? UnreadDotView.size + faceState.spacing : 0
        let size = line.size(scale: scale)
        let titleWidth = min(size.width, max(0, rect.width - x - trailing - dotRoom))
        let cut = titleWidth < size.width ? shellTruncatedWidth(line, width: titleWidth, truncation: faceState.middle ? .middle : .end, scale: scale) : size.width
        line.draw(in: CGRect(x: x, y: PiKit.round((rect.height - size.height) / 2, scale), width: titleWidth, height: size.height),
                  truncation: faceState.middle ? .middle : .end, scale: scale)
        x += cut
        if faceState.dot {
            x += faceState.spacing
            NSColor.piBrandOrange.setFill()
            NSBezierPath(ovalIn: CGRect(x: x, y: PiKit.round((rect.height - UnreadDotView.size) / 2, scale), width: UnreadDotView.size, height: UnreadDotView.size)).fill()
        }
        if let countLine {
            let countSize = countLine.size(scale: scale)
            countLine.draw(at: CGPoint(x: rect.width - countSize.width, y: PiKit.round((rect.height - countSize.height) / 2, scale)), scale: scale)
        }
    }
}

/// A project's header: its disclosure, its changes and new-chat buttons
/// (dropped when the sidebar is narrow), its actions menu, and its
/// right-click menu; tinted while chats are dragged over the project.
@MainActor final class ProjectHeaderView: NSView {
    private let model: WorkspaceModel
    private(set) var state: ProjectHeaderState
    private let disclosure: SidebarDisclosureButton
    private let changes = PiKit.IconButton(symbol: "arrow.triangle.branch", label: "", size: 22)
    private let newChat = PiKit.IconButton(symbol: "plus", label: "", size: 22)
    private let face = SidebarMenuFace()
    private var menuControl: PiKit.MenuControl!
    private let highlight = CALayer(), outline = CALayer()
    /// Folds or unfolds the project, with the sidebar's own motion.
    var setExpanded: ((Bool) -> Void)?

    init(model: WorkspaceModel, state: ProjectHeaderState) {
        self.model = model; self.state = state
        disclosure = SidebarDisclosureButton(Self.face(state))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(highlight); layer?.addSublayer(outline)
        for layer in [highlight, outline] { layer.cornerRadius = PiRadius.sm }
        outline.borderWidth = 1
        menuControl = PiKit.MenuControl(label: "", face: face, onHover: { [weak face] in face?.hovering = $0 }) { [weak self] in
            guard let self else { return [] }
            return ProjectSidebarActions.entries(model: self.model, state: self.state, expand: self.setExpanded)
        }
        for view in [disclosure, changes, newChat, menuControl!] as [NSView] { addSubview(view) }
        disclosure.onPress = { [weak self] in guard let self else { return }; self.setExpanded?(!self.state.expanded) }
        changes.onPress = { [weak self] in guard let self else { return }; self.model.showChanges(in: self.state.projectID) }
        newChat.onPress = { [weak self] in guard let self else { return }; self.model.newChat(in: self.state.projectID, topicID: nil) }
        apply(force: true)
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    private static func face(_ state: ProjectHeaderState) -> SidebarDisclosureButton.Face {
        SidebarDisclosureButton.Face(chevronSize: 9, chevronWeight: 0, icon: state.scratch ? "tray" : "folder", iconSize: 12, title: state.name,
                                     titleWeight: .semibold, ink: state.chosen ? .piInk : .piInkSecondary, spacing: 7, expanded: state.expanded,
                                     dot: !state.expanded && state.hasUnread, count: nil, middle: state.truncatesInTheMiddle)
    }
    func update(_ new: ProjectHeaderState) {
        guard new != state else { return }
        state = new
        apply(force: false)
    }
    private func apply(force: Bool) {
        disclosure.faceState = Self.face(state)
        disclosure.isEnabled = !state.filtering
        disclosure.toolTip = state.help
        disclosure.setAccessibilityLabel((state.expanded ? "Collapse project " : "Expand project ") + state.name)
        disclosure.setAccessibilityIdentifier("projectDisclosure-" + state.projectID)
        changes.label = "Changes and history of " + state.name
        changes.setAccessibilityIdentifier("projectChanges-" + state.projectID)
        changes.isEnabled = state.available
        newChat.label = "New chat in " + state.name
        newChat.setAccessibilityIdentifier("newProjectChat-" + state.projectID)
        newChat.isEnabled = state.available && state.trusted
        changes.isHidden = state.scratch || state.compact
        newChat.isHidden = state.scratch || state.compact
        menuControl.isHidden = state.scratch
        menuControl.setAccessibilityLabel("Project actions for " + state.name)
        menuControl.setAccessibilityIdentifier("projectActions-" + state.projectID)
        menuControl.toolTip = "Project actions for " + state.name
        needsLayout = true
        updateLayer()
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        PiMenus.menu(ProjectSidebarActions.entries(model: model, state: state, expand: setExpanded))
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        highlight.backgroundColor = state.dropTargeted ? piCGColor(.piAccentSoft) : CGColor.clear
        outline.borderColor = state.dropTargeted ? piCGColor(.piAccent) : CGColor.clear
    }
    static let height: CGFloat = 28
    /// The row's height: its tallest piece and `.padding(.vertical, 3)`.
    var preferredHeight: CGFloat { max(disclosure.intrinsicContentSize.height, 22, SidebarMenuFace.size.height) + 6 }
    override func layout() {
        super.layout()
        // `.padding(.horizontal, 7).padding(.vertical, 3)`, buttons on the right.
        var right = bounds.width - 7
        if !menuControl.isHidden {
            menuControl.frame = CGRect(x: right - SidebarMenuFace.size.width, y: PiKit.round((bounds.height - SidebarMenuFace.size.height) / 2, piScale),
                                       width: SidebarMenuFace.size.width, height: SidebarMenuFace.size.height)
            right -= SidebarMenuFace.size.width + 4
        }
        for button in [newChat, changes] where !button.isHidden {
            button.frame = CGRect(x: right - 22, y: PiKit.round((bounds.height - 22) / 2, piScale), width: 22, height: 22)
            right -= 22 + 4
        }
        let height = disclosure.intrinsicContentSize.height
        disclosure.frame = CGRect(x: 7, y: PiKit.round((bounds.height - height) / 2, piScale), width: max(0, right + 4 - 7 - 4), height: height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        highlight.frame = bounds
        outline.frame = bounds.insetBy(dx: -0.5, dy: -0.5); outline.cornerRadius = PiRadius.sm + 0.5
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateLayer() }
}

/// What the header's menu and the project's right-click menu both offer.
enum ProjectSidebarActions {
    @MainActor @PiMenuBuilder static func entries(model: WorkspaceModel, state: ProjectHeaderState, expand: ((Bool) -> Void)?) -> [PiMenuEntry] {
        if !state.scratch {
            PiMenuEntry.button("New Chat", systemImage: "square.and.pencil", enabled: state.available && state.trusted) {
                model.newChat(in: state.projectID, topicID: nil)
            }
            PiMenuEntry.button("New Topic…", systemImage: "folder.badge.plus", identifier: "newTopic-" + state.projectID) {
                model.presentNewTopic(in: state.projectID)
            }
            // The header drops its own button for this in a narrow sidebar.
            PiMenuEntry.button("Changes and History…", systemImage: "arrow.triangle.branch", enabled: state.available,
                               identifier: "projectChangesAction-" + state.projectID) { model.showChanges(in: state.projectID) }
        }
        PiMenuEntry.button(state.expanded ? "Collapse Project" : "Expand Project", enabled: !state.filtering) {
            if let expand { expand(!state.expanded) } else { model.setProjectExpanded(state.projectID, expanded: !state.expanded) }
        }
        if !state.scratch {
            PiMenuEntry.divider
            PiMenuEntry.button(state.available ? "Manage Project…" : "Configure Projects…", systemImage: "folder.badge.gearshape") {
                if state.available { model.selectedWorkspaceID = state.projectID }
                model.showWorkspaceManager = true
            }
        }
    }
}

/// A topic's header: its disclosure with the chat count, a new-chat button,
/// its actions menu and right-click menu; tinted while chats are dragged over the topic.
@MainActor final class TopicHeaderView: NSView {
    private let model: WorkspaceModel
    private(set) var state: TopicHeaderState
    private let disclosure: SidebarDisclosureButton
    private let newChat = PiKit.IconButton(symbol: "plus", label: "", size: 22)
    private let face = SidebarMenuFace()
    private var menuControl: PiKit.MenuControl!
    private let highlight = CALayer(), outline = CALayer()
    var setExpanded: ((Bool) -> Void)?
    /// Opens the group's own "Remove this topic?" question.
    var confirmRemove: (() -> Void)?

    init(model: WorkspaceModel, state: TopicHeaderState) {
        self.model = model; self.state = state
        disclosure = SidebarDisclosureButton(Self.face(state))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(highlight); layer?.addSublayer(outline)
        for layer in [highlight, outline] { layer.cornerRadius = PiRadius.sm }
        outline.borderWidth = 1
        menuControl = PiKit.MenuControl(label: "", face: face, onHover: { [weak face] in face?.hovering = $0 }) { [weak self] in
            guard let self else { return [] }
            return Self.entries(model: self.model, state: self.state, confirmRemove: { [weak self] in self?.confirmRemove?() })
        }
        for view in [disclosure, newChat, menuControl!] as [NSView] { addSubview(view) }
        disclosure.onPress = { [weak self] in guard let self else { return }; self.setExpanded?(!self.state.expanded) }
        newChat.onPress = { [weak self] in guard let self else { return }; self.model.newChat(in: self.state.projectID, topicID: self.state.topicID) }
        apply()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    private static func face(_ state: TopicHeaderState) -> SidebarDisclosureButton.Face {
        SidebarDisclosureButton.Face(chevronSize: 8, chevronWeight: 0, icon: state.expanded ? "folder" : "folder.fill", iconSize: 11, title: state.title,
                                     titleWeight: .medium, ink: .piInkSecondary, spacing: 6, expanded: state.expanded,
                                     dot: !state.expanded && state.hasUnread, count: "\(state.chats)", middle: false)
    }
    func update(_ new: TopicHeaderState) {
        guard new != state else { return }
        state = new
        apply()
    }
    private func apply() {
        disclosure.faceState = Self.face(state)
        disclosure.isEnabled = !state.filtering
        disclosure.setAccessibilityLabel((state.expanded ? "Collapse topic " : "Expand topic ") + state.title + ", " + WorkspaceLabel.chats(state.chats))
        disclosure.setAccessibilityIdentifier("topicDisclosure-" + state.topicID)
        newChat.label = "New chat in topic " + state.title
        newChat.setAccessibilityIdentifier("newTopicChat-" + state.topicID)
        newChat.isEnabled = state.trusted
        menuControl.setAccessibilityLabel("Topic actions for " + state.title)
        menuControl.setAccessibilityIdentifier("topicActions-" + state.topicID)
        menuControl.toolTip = "Topic actions for " + state.title
        toolTip = "Drop chats here to group them in “" + state.title + "”. Saved side chats move with their parent."
        needsLayout = true
        updateLayer()
    }
    @MainActor @PiMenuBuilder static func entries(model: WorkspaceModel, state: TopicHeaderState, confirmRemove: @escaping @MainActor () -> Void) -> [PiMenuEntry] {
        PiMenuEntry.button("New Chat", systemImage: "square.and.pencil", enabled: state.trusted) { model.newChat(in: state.projectID, topicID: state.topicID) }
        PiMenuEntry.button("New Topic…", systemImage: "folder.badge.plus") { model.presentNewTopic(in: state.projectID) }
        PiMenuEntry.divider
        PiMenuEntry.button("Rename Topic…", systemImage: "pencil") { model.presentRenameTopic(state.topicID) }
        PiMenuEntry.button("Remove Topic…", systemImage: "folder.badge.minus", destructive: true, help: "Keep all chats and move them back to the project",
                           action: confirmRemove)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        PiMenus.menu(Self.entries(model: model, state: state, confirmRemove: { [weak self] in self?.confirmRemove?() }))
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        highlight.backgroundColor = state.dropTargeted ? piCGColor(.piAccentSoft) : CGColor.clear
        outline.borderColor = state.dropTargeted ? piCGColor(.piAccent) : CGColor.clear
    }
    static let height: CGFloat = 26
    /// The row's height: its tallest piece and `.padding(.vertical, 2)`.
    var preferredHeight: CGFloat { max(disclosure.intrinsicContentSize.height, 22, SidebarMenuFace.size.height) + 4 }
    override func layout() {
        super.layout()
        // `.padding(.leading, 21).padding(.trailing, 7).padding(.vertical, 2)`.
        var right = bounds.width - 7
        menuControl.frame = CGRect(x: right - SidebarMenuFace.size.width, y: PiKit.round((bounds.height - SidebarMenuFace.size.height) / 2, piScale),
                                   width: SidebarMenuFace.size.width, height: SidebarMenuFace.size.height)
        right -= SidebarMenuFace.size.width + 4
        newChat.frame = CGRect(x: right - 22, y: PiKit.round((bounds.height - 22) / 2, piScale), width: 22, height: 22)
        right -= 22 + 4
        let height = disclosure.intrinsicContentSize.height
        disclosure.frame = CGRect(x: 21, y: PiKit.round((bounds.height - height) / 2, piScale), width: max(0, right + 4 - 21 - 4), height: height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        highlight.frame = bounds
        outline.frame = bounds.insetBy(dx: -0.5, dy: -0.5); outline.cornerRadius = PiRadius.sm + 0.5
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateLayer() }
}
