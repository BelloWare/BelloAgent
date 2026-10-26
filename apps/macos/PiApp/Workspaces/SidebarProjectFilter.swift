import AppKit

// Flat's project filter (0.1.131): a row of chips under the search field,
// All and each project with chats, narrows the combined list to one
// project; a row's project tag picks that project's chip. The narrowed list
// keeps Flat's order, pins, archive section, paging and row states. A search
// looks across every project, so the chips give its scope their place while
// it is on, and the chosen one comes back with them. The choice lasts while
// the app runs; Topics has no chips.

/// One project's chip: what it reads, its full name for help and VoiceOver,
/// and the newest activity among its listed chats, which orders the chips.
struct SidebarProjectChip: Equatable {
    var projectID: String
    var title: String
    var fullName: String
    var activity: Int64
    var scratch = false
    /// What the bar draws, without the activity that only orders it.
    var face: [String] { [projectID, title, fullName] }
}

extension WorkspaceModel {
    /// The project Flat lists while it is narrowed: the chosen one, while the
    /// sidebar is Flat and the project is still listed. Nil lists every project.
    var sidebarFlatProject: String? {
        guard sidebarListsFlat, let id = sidebarProjectFilter, sidebarProjects.contains(where: { $0.id == id }) else { return nil }
        return id
    }
    /// The project the combined list is narrowed to for `query`: a search
    /// looks across every project.
    func sidebarFlatScope(query: String) -> String? { query.isEmpty ? sidebarFlatProject : nil }

    /// Narrows Flat to `id`, or lists every project again with nil.
    func setSidebarProjectFilter(_ id: String?) {
        if sidebarProjectFilter != id { sidebarProjectFilter = id }
    }
    /// `chat` is being shown from outside the list: Flat narrowed to another
    /// project lists every project again, so the chat's row is there.
    func listSidebarProject(of chat: ChatRecord) {
        if let chosen = sidebarProjectFilter, chosen != chat.workspaceID { sidebarProjectFilter = nil }
    }

    /// The chips: every project Flat lists chats of (archived ones while the
    /// archive is shown), newest activity first, as its rows are ordered. The
    /// chosen project keeps its chip while it has none.
    var sidebarProjectChips: [SidebarProjectChip] { sidebarIndex.chips { buildSidebarProjectChips() } }
    /// Whether the bar has anything to choose between.
    var sidebarProjectFilterOffersChoice: Bool { sidebarProjectChips.count > 1 || sidebarFlatProject != nil }

    private func buildSidebarProjectChips() -> [SidebarProjectChip] {
        let projects = sidebarProjects, archive = sidebarShowsArchived
        let listed = Set(projects.map(\.id))
        var newest: [String: Int64] = [:]
        for chat in chats where !chat.isBackgroundTask && (archive || !chat.isArchived) && listed.contains(chat.workspaceID) {
            newest[chat.workspaceID] = max(newest[chat.workspaceID] ?? .min, sidebarActivity(chat))
        }
        let chosen = sidebarFlatProject
        // One retained group reads as its rows' tag; several keep their ids apart.
        let retained = projects.reduce(0) { $0 + ($1.available ? 0 : 1) }
        let chips = projects.enumerated().compactMap { position, project -> (Int, SidebarProjectChip)? in
            guard let activity = newest[project.id] ?? (project.id == chosen ? .min : nil) else { return nil }
            let title = project.available || retained > 1 ? project.name : "Retained chats"
            let fullName = project.available ? project.name : "Retained chats · " + project.id
            return (position, SidebarProjectChip(projectID: project.id, title: title, fullName: fullName, activity: activity,
                                                 scratch: project.record.isScratch))
        }
        return chips.sorted { $0.1.activity != $1.1.activity ? $0.1.activity > $1.1.activity : $0.0 < $1.0 }.map(\.1)
    }
}

/// Which chips fit beside All: every one when they all do; else the project
/// chips in their order while they fit whole next to "+N" for the rest, only
/// a first chip with no room to be whole cut short. The chosen chip is always
/// shown, in the place of the last chip that fits (first, when only one does).
enum SidebarChipFit {
    struct Placement: Equatable {
        /// Indexes into the chips, in the order shown, and each one's width.
        var shown: [Int] = []
        var widths: [CGFloat] = []
        /// The others, in their own order: the "+N" menu.
        var hidden: [Int] = []
    }
    /// `natural`: each chip's own width. `leading`: All and the gap after it.
    /// `more`: the width of "+N" for N hidden chips.
    static func place(natural: [CGFloat], chosen: Int?, available: CGFloat, leading: CGFloat, spacing: CGFloat,
                      minimum: CGFloat, more: (Int) -> CGFloat) -> Placement {
        let order = Array(natural.indices)
        // The menu is for chips that do not fit: room kept for "+N" must not
        // push out a last chip narrower than it.
        if leading + natural.reduce(0, +) + spacing * CGFloat(max(0, natural.count - 1)) <= available + 0.5 {
            return Placement(shown: order, widths: natural, hidden: [])
        }
        func fit(_ order: [Int], forcingFirst: Bool = false) -> Placement {
            var placement = Placement(), x = leading
            for (position, index) in order.enumerated() {
                let after = order.count - position - 1
                let room = available - x - (after > 0 ? spacing + more(after) : 0)
                if natural[index] <= room + 0.5 {
                    placement.shown.append(index); placement.widths.append(natural[index]); x += natural[index] + spacing
                } else if position == 0 && (room >= min(minimum, natural[index]) || forcingFirst) {
                    placement.shown.append(index)
                    placement.widths.append(max(min(natural[index], minimum), min(natural[index], room)))
                    break
                } else { break }
            }
            placement.hidden = natural.indices.filter { !placement.shown.contains($0) }
            return placement
        }
        let plain = fit(order)
        guard let chosen, natural.indices.contains(chosen), !plain.shown.contains(chosen) else { return plain }
        var promoted = order.filter { $0 != chosen }
        promoted.insert(chosen, at: max(0, plain.shown.count - 1))
        let swapped = fit(promoted)
        if swapped.shown.contains(chosen) { return swapped }
        return fit([chosen] + order.filter { $0 != chosen }, forcingFirst: true)
    }
}

/// The row of project chips over the Flat list: All, then each project with
/// chats, newest activity first, and "+N" opening a menu of those that do
/// not fit. A chip does not move under the pointer: the order the bar had
/// when the pointer came over it holds until the pointer leaves.
@MainActor final class SidebarProjectFilterBar: NSView {
    /// A chip was pressed or chosen from the menu: a project, nil for All.
    var onChoose: ((String?) -> Void)?
    private(set) var chips: [SidebarProjectChip] = []
    private(set) var chosen: String?
    var offersChoice: Bool { chips.count > 1 || chosen != nil }
    let all = Chip(title: "All", projectID: nil)
    let more = MoreButton()
    private(set) var buttons: [String: Chip] = [:]
    private(set) var placement = SidebarChipFit.Placement()
    /// The chips in the order the bar laid them out last: what `placement` indexes.
    private(set) var laidOut: [SidebarProjectChip] = []
    private var heldOrder: [String]?
    private var tracking: NSTrackingArea?
    static let spacing: CGFloat = 4
    /// The widest a project chip is drawn, and the narrowest it is cut to.
    static let maximumChipWidth: CGFloat = 132
    static let minimumChipWidth: CGFloat = 52

    var isEnabled = true {
        didSet {
            guard oldValue != isEnabled else { return }
            var controls: [PiKit.ButtonBase] = [all, more]
            controls += buttons.values.map { $0 as PiKit.ButtonBase }
            for control in controls { control.isEnabled = isEnabled }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Project filter")
        setAccessibilityIdentifier("sidebarProjectFilter")
        all.setAccessibilityIdentifier("sidebarProjectFilter-all")
        all.toolTip = "Chats from every project"
        all.setAccessibilityLabel("All projects")
        all.onPress = { [weak self] in self?.onChoose?(nil) }
        more.setAccessibilityIdentifier("sidebarProjectFilterMore")
        more.entries = { [weak self] in self?.menuEntries() ?? [] }
        addSubview(all); addSubview(more)
        more.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }

    /// Takes the chips and the chosen project; lays out again only when what
    /// it draws changed, not for each new activity that keeps the order.
    func update(chips new: [SidebarProjectChip], chosen newChosen: String?) {
        let changed = new.map(\.face) != chips.map(\.face) || newChosen != chosen
        chips = new; chosen = newChosen
        guard changed else { return }
        var kept: [String: Chip] = [:]
        for chip in new {
            let button = buttons[chip.projectID] ?? {
                let button = Chip(title: chip.title, projectID: chip.projectID)
                button.setAccessibilityIdentifier("sidebarProjectFilter-" + chip.projectID)
                button.onPress = { [weak self] in self?.onChoose?(chip.projectID) }
                button.isEnabled = isEnabled
                addSubview(button)
                return button
            }()
            button.label = chip.title
            button.toolTip = chip.fullName
            button.chosen = chip.projectID == newChosen
            kept[chip.projectID] = button
        }
        for (id, button) in buttons where kept[id] == nil { button.removeFromSuperview() }
        buttons = kept
        all.chosen = newChosen == nil
        needsLayout = true
    }

    /// The chips in the order they are shown: their own, or the one held while the pointer is over the bar.
    private var ordered: [SidebarProjectChip] {
        guard let heldOrder else { return chips }
        let rank = Dictionary(heldOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return chips.enumerated().sorted { lhs, rhs in
            let a = rank[lhs.element.projectID] ?? heldOrder.count + lhs.offset, b = rank[rhs.element.projectID] ?? heldOrder.count + rhs.offset
            return a < b
        }.map(\.element)
    }

    override func layout() {
        super.layout()
        let chips = ordered
        let height = all.intrinsicContentSize.height
        let y = PiKit.round((bounds.height - height) / 2, piScale)
        let allWidth = all.intrinsicContentSize.width
        all.frame = CGRect(x: 0, y: y, width: allWidth, height: height)
        let natural = chips.map { min(buttons[$0.projectID]?.naturalWidth ?? 0, Self.maximumChipWidth) }
        placement = SidebarChipFit.place(natural: natural, chosen: chips.firstIndex { $0.projectID == chosen },
                                         available: bounds.width, leading: allWidth + Self.spacing, spacing: Self.spacing,
                                         minimum: Self.minimumChipWidth, more: { MoreButton.width(count: $0) })
        var x = allWidth + Self.spacing
        for (index, width) in zip(placement.shown, placement.widths) {
            guard let button = buttons[chips[index].projectID] else { continue }
            button.isHidden = false
            button.frame = CGRect(x: x, y: y, width: width, height: height)
            x += width + Self.spacing
        }
        for index in placement.hidden { buttons[chips[index].projectID]?.isHidden = true }
        more.count = placement.hidden.count
        more.isHidden = placement.hidden.isEmpty
        more.frame = CGRect(x: x, y: y, width: MoreButton.width(count: more.count), height: height)
        laidOut = chips
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: all.intrinsicContentSize.height) }

    /// The projects behind "+N", newest activity first.
    func menuEntries() -> [PiMenuEntry] {
        let chips = laidOut
        return placement.hidden.filter { chips.indices.contains($0) }.map { index in
            let chip = chips[index]
            return PiMenuEntry.button(chip.title, systemImage: chip.scratch ? "tray" : "folder",
                                      identifier: "sidebarProjectFilterMenu-" + chip.projectID, help: chip.fullName) { [weak self] in
                self?.onChoose?(chip.projectID)
            }
        }
    }

    // MARK: Holding the order under the pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { holdOrder(true) }
    override func mouseExited(with event: NSEvent) { holdOrder(false) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { holdOrder(false) } }
    /// While held, the chips keep the order they were last laid out in.
    func holdOrder(_ held: Bool) {
        if held { heldOrder = laidOut.map(\.projectID) } else if heldOrder != nil { heldOrder = nil; needsLayout = true }
    }

    // MARK: Chips

    /// A chip: its label in a capsule that the pointer shades; the chosen
    /// one on a white capsule in a hairline, as a pill's face.
    @MainActor final class Chip: PiKit.ButtonBase {
        let projectID: String?
        var label: String { didSet { guard oldValue != label else { return }; invalidateIntrinsicContentSize(); redrawContent(); setAccessibilityLabel(label) } }
        var chosen = false { didSet { guard oldValue != chosen else { return }; refreshFace(); redrawContent() } }
        static var font: NSFont { .systemFont(ofSize: 12, weight: .medium) }
        static let padding: CGFloat = 9
        init(title: String, projectID: String?) {
            self.projectID = projectID; label = title
            super.init(frame: .zero)
            pressScales = false
            setAccessibilityLabel(title)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        var line: PiKit.Line { PiKit.Line(label, font: Self.font, color: chosen ? .piInk : .piInkSecondary) }
        /// Its width with the whole label.
        var naturalWidth: CGFloat { line.size(scale: piScale).width + Self.padding * 2 }
        override var intrinsicContentSize: NSSize { NSSize(width: naturalWidth, height: line.lineHeight + 10) }
        override func isAccessibilitySelected() -> Bool { chosen }
        override func styleFace() {
            let shade: NSColor = chosen ? .piSurface : isPressedDown && isEffectivelyEnabled ? .piFillStrong : hovering && isEffectivelyEnabled ? .piFill : .clear
            fill.backgroundColor = piCGColor(shade)
            stroke.borderColor = chosen ? piCGColor(.piHairlineStrong) : CGColor.clear
        }
        override func drawContent(in rect: CGRect) {
            let size = line.size(scale: piScale)
            let y = PiKit.round((rect.height - size.height) / 2, piScale)
            line.draw(in: CGRect(x: Self.padding, y: y, width: max(0, rect.width - Self.padding * 2), height: size.height), truncation: .end, scale: piScale)
        }
    }

    /// "+N" and a chevron: the projects that do not fit, in a menu.
    @MainActor final class MoreButton: PiKit.ButtonBase {
        var count = 0 {
            didSet {
                guard oldValue != count else { return }
                invalidateIntrinsicContentSize(); redrawContent()
                setAccessibilityValue(count == 1 ? "1 more project" : "\(count) more projects")
            }
        }
        var entries: (() -> [PiMenuEntry])?
        static var chevron: PiKit.Symbol { PiKit.Symbol("chevron.down", size: 9, weight: .semibold) }
        static func line(_ count: Int) -> PiKit.Line { PiKit.Line("+\(count)", font: Chip.font, color: .piInkSecondary) }
        static func width(count: Int) -> CGFloat {
            line(count).size().width + 4 + chevron.layoutSize.width + Chip.padding * 2
        }
        override init(frame: NSRect) {
            super.init(frame: frame)
            pressScales = false
            setAccessibilityRole(.menuButton)
            setAccessibilityLabel("More projects")
            toolTip = "More projects"
            onPress = { [weak self] in guard let self else { return }; PiMenus.popUp(self.entries?() ?? [], below: self) }
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        override var intrinsicContentSize: NSSize { NSSize(width: Self.width(count: count), height: Self.line(count).lineHeight + 10) }
        override func styleFace() {
            fill.backgroundColor = piCGColor(isPressedDown && isEffectivelyEnabled ? .piFillStrong : hovering && isEffectivelyEnabled ? .piFill : .clear)
            stroke.borderColor = CGColor.clear
        }
        override func drawContent(in rect: CGRect) {
            let line = Self.line(count), size = line.size(scale: piScale)
            line.draw(at: CGPoint(x: Chip.padding, y: PiKit.round((rect.height - size.height) / 2, piScale)), scale: piScale)
            let box = Self.chevron.layoutSize
            Self.chevron.draw(centredIn: CGRect(x: Chip.padding + size.width + 4, y: 0, width: box.width, height: rect.height),
                              color: .piInkTertiary, scale: piScale)
        }
    }
}

/// A Flat row's project tag: the compact badge it always was and, while the
/// list shows every project, a button that narrows it to this one. Not
/// pressable, it takes no clicks: they open the row.
@MainActor final class SidebarProjectTag: PiKit.ButtonBase {
    var text = "" { didSet { guard oldValue != text else { return }; invalidateIntrinsicContentSize(); redrawContent() } }
    /// The widest it asks to be; longer text is cut short with an ellipsis.
    var maximumWidth: CGFloat = .greatestFiniteMagnitude {
        didSet { guard oldValue != maximumWidth else { return }; invalidateIntrinsicContentSize(); redrawContent() }
    }
    var pressable = false {
        didSet {
            guard oldValue != pressable else { return }
            setAccessibilityElement(pressable)
            window?.invalidateCursorRects(for: self)
            refreshFace()
        }
    }
    static let horizontalPadding: CGFloat = 6
    static let verticalInset: CGFloat = 1.5
    private var line: PiKit.Line { PiKit.Line(text, font: PiKit.Font.micro, color: .piInkSecondary) }
    /// Its width with every word shown, whatever `maximumWidth` allows.
    var naturalWidth: CGFloat { (text.isEmpty ? 0 : line.size(scale: piScale).width) + Self.horizontalPadding * 2 }
    override var intrinsicContentSize: NSSize {
        NSSize(width: min(naturalWidth, maximumWidth), height: (text.isEmpty ? 0 : line.lineHeight) + Self.verticalInset * 2)
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        pressScales = false
        setAccessibilityElement(false)
        setAccessibilityHelp("Show only this project's chats")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override func styleFace() {
        fill.backgroundColor = piCGColor(pressable && isEffectivelyEnabled && (hovering || isPressedDown) ? .piFillStrong : .piFill)
        stroke.borderColor = CGColor.clear
    }
    override func drawContent(in rect: CGRect) {
        guard !text.isEmpty else { return }
        let size = line.size(scale: piScale), x = Self.horizontalPadding
        let inner = CGRect(x: 0, y: Self.verticalInset, width: rect.width, height: rect.height - Self.verticalInset * 2)
        let y = inner.minY + PiKit.round((inner.height - size.height) / 2, piScale)
        // Cut short to the room it was given, rather than clipped.
        if x + size.width > rect.width - Self.horizontalPadding + 0.5 {
            line.draw(in: CGRect(x: x, y: y, width: max(0, rect.width - Self.horizontalPadding - x), height: size.height), truncation: .end, scale: piScale)
        } else {
            line.draw(at: CGPoint(x: x, y: y), scale: piScale)
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { pressable ? super.hitTest(point) : nil }
    override func resetCursorRects() { if pressable { super.resetCursorRects() } }
    override var acceptsFirstResponder: Bool { pressable && super.acceptsFirstResponder }
    override var canBecomeKeyView: Bool { pressable && super.canBecomeKeyView }
}
