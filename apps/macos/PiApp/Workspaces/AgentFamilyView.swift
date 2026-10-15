import AppKit
import Combine

/// A dedicated row in the conversation column, never a transcript overlay
/// or a window-toolbar item. Embedded child tabs suppress this row.
@MainActor final class AgentFamilyHeaderView: NSView {
    let button = FamilyPillButton()
    let popover = PiPopoverPresenter()
    private weak var model: WorkspaceModel?
    private var sessionID = ""
    private var family: ConversationFamily?
    private var request: AnyCancellable?
    private var activityObserver: ShellObserver?
    private var enabled = true
    private var allowsDisplay = true
    override init(frame: NSRect) {
        super.init(frame: frame); addSubview(button)
        button.setAccessibilityIdentifier("agent-family-pill")
        button.onPress = { [weak self] in self?.open() }
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func update(model: WorkspaceModel, sessionID: String, enabled: Bool, allowsDisplay: Bool = true) {
        if self.model !== model {
            self.model = model
            let observer = ShellObserver { [weak self] in
                guard let self, let model = self.model else { return }
                self.update(model: model, sessionID: self.sessionID, enabled: self.enabled, allowsDisplay: self.allowsDisplay)
            }
            observer.observe(model); observer.observe(publisher: model.activityChanged); activityObserver = observer
            request = model.agentFamilyRequests.sink { [weak self] owner in
                MainActor.assumeIsolated {
                    guard let self, self.family?.ownerID == owner, !self.isHiddenOrHasHiddenAncestor,
                          self.window?.isKeyWindow == true else { return }
                    self.open()
                }
            }
        }
        self.sessionID = sessionID; self.enabled = enabled; self.allowsDisplay = allowsDisplay; button.isEnabled = enabled
        let next = model.conversationFamily(sessionID)
        let hidden = !allowsDisplay || next.isEmpty
        if isHidden != hidden { isHidden = hidden; superview?.needsLayout = true }
        if hidden { popover.close() }
        guard next != family else { return }
        family = next
        button.title = next.title
        let label = [next.title, next.activity.label].filter { !$0.isEmpty }.joined(separator: ", ")
        button.toolTip = label + ". Open sides and sub-agents."
        button.setAccessibilityLabel(button.toolTip)
        button.working = next.activity.active > 0
        needsLayout = true
        if next.isEmpty { popover.close() }
    }
    func open() {
        guard enabled, !isHidden, let model, window != nil else { return }
        let width = min(400, max(280, (window?.contentView?.bounds.width ?? 400) - 48))
        popover.toggle(from: button, width: width, maximumHeight: 480, animates: !PiKit.Motion.reduced, withinWindow: true) { [weak self, weak model] in
            guard let self, let model else { return NSView() }
            return AgentFamilyPopoverView(model: model, sessionID: self.sessionID, close: { [weak self] in self?.popover.close() }, ownerWindow: self.window)
        }
    }
    override func layout() {
        super.layout()
        let width = min(max(0, bounds.width - 32), button.intrinsicContentSize.width)
        button.frame = CGRect(x: bounds.width - 16 - width, y: 5, width: width, height: 24)
    }
}

/// A two-line Pi action row; its trailing Stop keeps its own hit target and
/// accessibility action. Text always starts at the same inset, including New Side.
@MainActor final class FamilyPickerRow: PiKit.ButtonBase, PiKit.WidthSizing {
    let primary: String
    let secondary: String?
    let current: Bool
    var leadingSymbol: String?
    var stop: PiKit.IconButton?
    var navigate: ((NSEvent) -> Void)?
    var focused: (() -> Void)?
    init(_ primary: String, secondary: String? = nil, current: Bool = false) {
        self.primary = primary; self.secondary = secondary; self.current = current
        super.init(frame: .zero); title = primary
    }
    required init?(coder: NSCoder) { nil }
    func height(forWidth width: CGFloat) -> CGFloat { secondary == nil ? 32 : 46 }
    override var intrinsicContentSize: NSSize { .init(width: NSView.noIntrinsicMetric, height: height(forWidth: 400)) }
    override func cornerRadius(for size: CGSize) -> CGFloat { PiRadius.sm }
    override func layout() { super.layout(); stop?.frame = CGRect(x: max(0, bounds.width - 32), y: (bounds.height - 24) / 2, width: 24, height: 24) }
    override func drawContent(in rect: CGRect) {
        let inset: CGFloat = 30
        let width = max(0, rect.width - inset - (stop == nil ? 10 : 36))
        if let symbol = leadingSymbol ?? (current ? "checkmark" : nil) {
            PiKit.Symbol(symbol, size: 12).drawPlaced(centredIn: CGRect(x: 10, y: 0, width: 12, height: rect.height), color: .piAccent, scale: piScale)
        }
        PiKit.Line(primary, font: PiKit.Font.body, color: current || leadingSymbol != nil ? .piAccent : .piInk)
            .draw(in: CGRect(x: inset, y: secondary == nil ? 7 : 5, width: width, height: 20), truncation: .end, scale: piScale)
        if let secondary {
            PiKit.Line(secondary, font: PiKit.Font.caption, color: .piInkSecondary)
                .draw(in: CGRect(x: inset, y: 25, width: width, height: 16), truncation: .end, scale: piScale)
        }
    }
    override func styleFace() {
        fill.backgroundColor = piCGColor(current ? .piAccentSoft : hovering || isPressedDown ? .piFill : .clear)
        stroke.borderColor = CGColor.clear; shadowLayer.shadowOpacity = 0
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point), hit === stop { return hit }
        return frame.contains(point) ? self : nil
    }
    override func accessibilityChildren() -> [Any]? { stop.map { [$0] } }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder(); if accepted { focused?() }; return accepted
    }
    override func keyDown(with event: NSEvent) {
        if [125, 126, 53].contains(event.keyCode) { navigate?(event) }
        else if [36, 76].contains(event.keyCode), isEnabled { onPress?() }
        else { super.keyDown(with: event) }
    }
}

@MainActor final class AgentFamilyPopoverView: NSView, PiKit.WidthSizing {
    private let model: WorkspaceModel
    private let sessionID: String
    private let close: () -> Void
    private weak var ownerWindow: NSWindow?
    private var stack: ShellStack?
    private var observer: ShellObserver?
    private var family: ConversationFamily?
    private var openButtons: [FamilyPickerRow] = []
    private var controls: [PiKit.ButtonBase] = []
    private var selectedID: String?
    init(model: WorkspaceModel, sessionID: String, close: @escaping () -> Void, ownerWindow: NSWindow?) {
        self.model = model; self.sessionID = sessionID; self.close = close; self.ownerWindow = ownerWindow
        super.init(frame: .zero)
        let observer = ShellObserver { [weak self] in self?.refresh() }; observer.observe(model); observer.observe(publisher: model.activityChanged); self.observer = observer
        setAccessibilityIdentifier("agent-family-popover"); refresh()
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private func row(_ title: String, detail: String? = nil, id: String, label: String, current: Bool = false, action: @escaping () -> Void) -> FamilyPickerRow {
        let row = FamilyPickerRow(title, secondary: detail, current: current)
        row.setAccessibilityIdentifier(id); row.setAccessibilityLabel(label)
        row.toolTip = label + (detail == nil ? "" : ". Spend includes reported usage only.")
        row.onPress = action
        row.navigate = { [weak self] event in self?.keyDown(with: event) }
        row.focused = { [weak self] in self?.selectedID = id }
        openButtons.append(row); controls.append(row)
        return row
    }
    private func heading(_ title: String) -> NSView {
        ShellStack(.vertical, spacing: 0, padding: NSEdgeInsets(top: 5, left: 30, bottom: 3, right: 10),
            [.view(PiKit.TextLine(PiKit.Line(title, font: PiKit.Font.micro, color: .piInkTertiary, tracking: 0.5, uppercased: true)), .fill)])
    }
    func refresh() {
        let value = model.conversationFamily(sessionID)
        guard value != family else { return }; family = value
        let hadFocus = window?.firstResponder as? NSView
        let restoreFocus = hadFocus.map { $0 === self || $0.isDescendant(of: self) } ?? false
        let focusID = hadFocus?.accessibilityIdentifier()
        stack?.removeFromSuperview(); openButtons = []; controls = []
        var rows: [NSView] = []
        if !value.sides.isEmpty || value.canAddSide {
            rows.append(heading("Sides"))
            for side in value.sides {
                let detail = [side.status, side.spend.map(CostLimit.dollars)].compactMap { $0 }.joined(separator: " · ")
                rows.append(row(side.title, detail: detail, id: "open-side-" + side.id, label: "Open side " + side.title + ", " + detail, current: side.open) { [weak model, close] in
                    close(); Task { await model?.openFamilySide(side.id) }
                })
            }
            let newSide = row("New Side", id: "new-family-side", label: "New side beside the parent chat") { [weak model, close] in
                close(); model?.openNewFamilySide(value.ownerID)
            }
            newSide.leadingSymbol = "plus"; newSide.isEnabled = value.canAddSide; rows.append(newSide)
        }
        for group in value.agentFamilies where !group.members.isEmpty {
            let ownerTitle = model.record(group.ownerID)?.title ?? "Unavailable parent"
            rows.append(heading(group.ownerID == value.ownerID ? "Sub-agents" : "Sub-agents in " + ownerTitle))
            for member in group.members {
                let detail = [member.statusLabel, member.model, member.effort, member.spend.map(CostLimit.dollars)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                let row = row(member.label, detail: detail, id: "open-agent-" + member.chat.id,
                    label: "Open " + member.chat.displayTitle + " in " + ownerTitle + ", " + detail, current: member.chat.id == sessionID) { [weak model, close] in
                    close(); Task { await model?.openSubagentTab(member.chat.id) }
                }
                if member.status == .running, let link = member.chat.delegation {
                    let stop = PiKit.IconButton(symbol: "stop.fill", label: "Stop " + member.chat.displayTitle + " in " + ownerTitle, size: 24)
                    stop.setAccessibilityIdentifier("stop-agent-" + member.chat.id)
                    stop.onPress = { [weak model] in model?.stopSubagent(SubagentTarget(link), from: group.ownerID) }
                    row.stop = stop; row.addSubview(stop); controls.append(stop)
                }
                rows.append(row)
            }
            if group.ownerID != value.ownerID {
                let inspect = PiKit.Button("Inspect " + ownerTitle, symbol: "info.circle", style: .ghost, compact: true)
                inspect.onPress = { [weak model, close] in close(); model?.inspect(group.ownerID) }
                controls.append(inspect); rows.append(ShellStack(.horizontal, spacing: 0, [.view(inspect)]))
            }
        }
        let active = value.activity.runningAgents + value.activity.queuedAgents + value.activity.stoppingAgents
        let stopAll = PiKit.Button("Stop All…", style: .ghost, compact: true)
        stopAll.isEnabled = active > 0
        stopAll.setAccessibilityIdentifier("stop-all-agents")
        stopAll.setAccessibilityLabel("Stop all \(active) running or queued sub-agents")
        stopAll.onPress = { [weak self] in self?.confirmStopAll() }
        let inspect = PiKit.Button("Inspect Family", symbol: "info.circle", style: .ghost, compact: true)
        inspect.setAccessibilityIdentifier("inspect-agent-family")
        inspect.onPress = { [weak model, close] in close(); model?.inspect(value.ownerID) }
        if value.agentCount > 0 { controls.append(contentsOf: [stopAll, inspect]); rows.append(ShellStack(.horizontal, spacing: 8, [.view(stopAll), .spacer(0), .view(inspect)])) }
        let stack = ShellStack(.vertical, spacing: 2, padding: NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 6), rows.map { .view($0, .fill) })
        self.stack = stack; addSubview(stack)
        let enabled = controls.filter(\.isEnabled)
        for (index, control) in enabled.enumerated() { control.nextKeyView = enabled[(index + 1) % enabled.count] }
        if !openButtons.contains(where: { $0.accessibilityIdentifier() == selectedID && $0.isEnabled }) { selectedID = openButtons.first(where: \.isEnabled)?.accessibilityIdentifier() }
        needsLayout = true
        PiKit.sizeChanged(self)
        if restoreFocus { window?.makeFirstResponder(enabled.first { $0.accessibilityIdentifier() == focusID } ?? self) }
    }
    private func confirmStopAll() {
        guard let family, let ownerWindow else { return }
        let targets = family.agentFamilies.flatMap(\.members).filter(\.active).compactMap { $0.chat.delegation }.map { link in
            var target = SubagentTarget(link); target.turn = model.subagentSummaries[link.childSessionID]?.turn
            return target
        }
        guard !targets.isEmpty else { return }
        close()
        _ = model.questions.askSheet(over: ownerWindow, make: { answer in
            AgentStopAllSheet(count: targets.count, answer: answer)
        }, answered: { [weak model] accepted in
            guard accepted, let model else { return }
            for target in targets where model.record(target.sessionID)?.delegation.map(target.matchesOrigin) == true && model.subagentSummaries[target.sessionID]?.status.terminal == false && model.subagentSummaries[target.sessionID]?.turn == target.turn {
                model.stopSubagent(target, from: target.ownerID)
            }
        })
    }
    func height(forWidth width: CGFloat) -> CGFloat { stack?.height(forWidth: width) ?? 0 }
    override func layout() { super.layout(); stack?.frame = bounds }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { window?.makeFirstResponder(self) } }
    override func keyDown(with event: NSEvent) {
        let enabled = openButtons.filter(\.isEnabled)
        if let responder = window?.firstResponder as? NSView,
           let row = enabled.first(where: { responder === $0 || responder.isDescendant(of: $0) }) { selectedID = row.accessibilityIdentifier() }
        switch event.keyCode {
        case 53: close()
        case 125, 126:
            guard !enabled.isEmpty else { return }
            let current = enabled.firstIndex { $0.accessibilityIdentifier() == selectedID } ?? 0
            let index = (current + (event.keyCode == 125 ? 1 : enabled.count - 1)) % enabled.count
            let row = enabled[index]; selectedID = row.accessibilityIdentifier()
            window?.makeFirstResponder(row); row.scrollToVisible(row.bounds)
        case 36, 76: enabled.first { $0.accessibilityIdentifier() == selectedID }?.onPress?()
        case 48: if let first = controls.first(where: \.isEnabled) { window?.makeFirstResponder(first) }
        default: super.keyDown(with: event)
        }
    }
}

@MainActor final class AgentStopAllSheet: NSView {
    private let sheet: PiKit.Sheet
    private let answer: (Bool) -> Void
    init(count: Int, answer: @escaping (Bool) -> Void) {
        self.answer = answer
        let cancel = PiKit.Button("Cancel"); cancel.keyEquivalent = "\r"; cancel.onPress = { answer(false) }
        let stop = PiKit.Button("Stop All", style: .danger); stop.onPress = { answer(true) }
        cancel.nextKeyView = stop; stop.nextKeyView = cancel
        let detail = shellLine("Stop \(count) running or queued sub-agents?", font: PiKit.Font.body, color: .piInk)
        let body = ShellStack(.vertical, spacing: 0, padding: NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24), [.view(detail, .fill)])
        let footer = ShellStack(.horizontal, spacing: 8, padding: NSEdgeInsets(top: 12, left: 24, bottom: 12, right: 24), [.spacer(0), .view(cancel), .view(stop)])
        sheet = PiKit.Sheet("Stop all sub-agents?", content: body, footer: footer)
        sheet.width = 380; sheet.onCancel = { answer(false) }
        super.init(frame: .zero); addSubview(sheet)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { sheet.intrinsicContentSize }
    override func layout() { super.layout(); sheet.frame = bounds }
    override func cancelOperation(_ sender: Any?) { answer(false) }
}

/// One activity indicator in the pill, replacing its quiet family symbol.
@MainActor final class FamilyPillButton: PiKit.ButtonBase {
    private var spinner: PiSpinnerView?
    override var title: String { didSet { invalidateIntrinsicContentSize(); needsLayout = true; redrawContent() } }
    var working = false { didSet {
        guard oldValue != working else { return }
        if working {
            let view = PiSpinnerView(frame: .zero); view.configure(lineWidth: 1.5, turning: !PiKit.Motion.reduced)
            addSubview(view); spinner = view
        } else { spinner?.removeFromSuperview(); spinner = nil }
        needsLayout = true; redrawContent()
    } }
    private var line: PiKit.Line { .init(title, font: .systemFont(ofSize: 12, weight: .medium), color: .piInk) }
    override var intrinsicContentSize: NSSize { .init(width: line.size(scale: piScale).width + 42, height: 24) }
    override func layout() { super.layout(); spinner?.frame = CGRect(x: 11, y: (bounds.height - 11) / 2, width: 11, height: 11) }
    override func drawContent(in rect: CGRect) {
        if !working { PiKit.Symbol("rectangle.on.rectangle", size: 11).drawPlaced(centredIn: CGRect(x: 10, y: 0, width: 12, height: rect.height), color: .piInkSecondary, scale: piScale) }
        let size = line.size(scale: piScale)
        line.draw(in: CGRect(x: 30, y: (rect.height - size.height) / 2, width: max(0, rect.width - 40), height: size.height), truncation: .end, scale: piScale)
    }
    override func styleFace() {
        fill.backgroundColor = piCGColor(isPressedDown || hovering ? .piFillStrong : .piFill)
        stroke.borderColor = piCGColor(.piHairline); shadowLayer.shadowOpacity = 0
    }
}

/// The row's leading spinner is its sole activity indicator; the badge adds counts.
@MainActor final class AgentRunningBadge: NSView {
    private let badge = PiKit.Badge(text: "")
    override init(frame: NSRect) {
        super.init(frame: frame); addSubview(badge); badge.compact = true; isHidden = true
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { nil }
    func update(_ activity: FamilyActivity) {
        isHidden = activity.active == 0
        badge.text = activity.badge; toolTip = activity.label; setAccessibilityLabel(toolTip)
        invalidateIntrinsicContentSize(); needsLayout = true
    }
    override var intrinsicContentSize: NSSize { NSSize(width: badge.intrinsicContentSize.width, height: 18) }
    override func layout() { super.layout(); badge.frame = bounds }
}
