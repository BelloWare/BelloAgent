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

@MainActor final class AgentFamilyPopoverView: NSView, PiKit.WidthSizing {
    private let model: WorkspaceModel
    private let sessionID: String
    private let close: () -> Void
    private weak var ownerWindow: NSWindow?
    private var stack: ShellStack?
    private var observer: ShellObserver?
    private var family: ConversationFamily?
    private var openButtons: [PiKit.Button] = []
    private var controls: [PiKit.Button] = []
    private var selectedIndex = 0
    init(model: WorkspaceModel, sessionID: String, close: @escaping () -> Void, ownerWindow: NSWindow?) {
        self.model = model; self.sessionID = sessionID; self.close = close; self.ownerWindow = ownerWindow
        super.init(frame: .zero)
        let observer = ShellObserver { [weak self] in self?.refresh() }; observer.observe(model); observer.observe(publisher: model.activityChanged); self.observer = observer
        setAccessibilityIdentifier("agent-family-popover"); refresh()
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    func refresh() {
        let value = model.conversationFamily(sessionID)
        guard value != family else { return }; family = value
        let hadFocus = window?.firstResponder as? NSView
        let restoreFocus = hadFocus.map { $0 === self || $0.isDescendant(of: self) } ?? false
        stack?.removeFromSuperview(); openButtons = []; controls = []
        var rows: [NSView] = []
        if !value.sides.isEmpty || value.canAddSide {
            rows.append(shellLine("Sides", font: PiKit.Font.body, color: .piInk))
            for side in value.sides {
                let title = shellLine(side.title + (side.open ? " · Open" : ""), font: PiKit.Font.body, color: side.open ? .piAccent : .piInk)
                title.truncation = .end; title.toolTip = side.title
                let detail = [side.status, side.spend.map { "Reported " + compactGatewayUSD($0) }].compactMap { $0 }.joined(separator: " · ")
                let status = shellLine(detail, font: PiKit.Font.caption, color: .piInkSecondary)
                let open = PiKit.Button("Open", style: .secondary, compact: true)
                open.setAccessibilityIdentifier("open-side-" + side.id)
                open.setAccessibilityLabel("Open side " + side.title + ", " + detail)
                open.toolTip = "Open " + side.title + " beside the parent chat"
                open.onPress = { [weak model, close] in close(); Task { await model?.openFamilySide(side.id) } }
                openButtons.append(open); controls.append(open)
                rows.append(ShellStack(.vertical, spacing: 6, padding: NSEdgeInsets(top: 6, left: 0, bottom: 8, right: 0),
                    [.view(title, .fill), .view(status, .fill), .view(ShellStack(.horizontal, spacing: 0, [.view(open)]), .fill)]))
            }
            let newSide = PiKit.Button("New Side", symbol: "plus", style: .ghost, compact: true)
            newSide.isEnabled = value.canAddSide
            newSide.onPress = { [weak model, close] in close(); model?.openNewFamilySide(value.ownerID) }
            controls.append(newSide)
            rows.append(ShellStack(.horizontal, spacing: 0, [.view(newSide)]))
        }
        if !value.agents.members.isEmpty {
            rows.append(shellLine("Sub-agents", font: PiKit.Font.body, color: .piInk))
            let activity = FamilyActivity(runningAgents: value.agents.runningCount, queuedAgents: value.agents.queuedCount, stoppingAgents: value.agents.stoppingCount)
            if activity.active > 0 { rows.append(shellLine(activity.label, font: PiKit.Font.caption, color: .piInkSecondary)) }
        }
        for member in value.agents.members {
            let current = member.chat.id == sessionID
            let name = shellLine(member.label + (current ? " · Current" : ""), font: PiKit.Font.body, color: current ? .piAccent : .piInk)
            name.truncation = .end; name.toolTip = member.chat.displayTitle
            let spend = member.spend.map { "Reported " + compactGatewayUSD($0) }
            let detail = [member.statusLabel, member.model, spend].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            let status = shellLine(detail, font: PiKit.Font.caption, color: .piInkSecondary)
            status.truncation = .middle; status.toolTip = detail
            let open = PiKit.Button("Open", style: .secondary, compact: true)
            open.setAccessibilityIdentifier("open-agent-" + member.chat.id)
            open.setAccessibilityLabel("Open " + member.chat.displayTitle + ", " + detail)
            open.toolTip = "Open " + member.chat.displayTitle + " beside the parent chat"
            open.onPress = { [weak model, close] in close(); Task { await model?.openSubagentTab(member.chat.id) } }
            openButtons.append(open); controls.append(open)
            var actions: [ShellItem] = [.view(open)]
            if member.status == .running, let link = member.chat.delegation {
                let stop = PiKit.Button("Stop", style: .ghost, compact: true)
                stop.setAccessibilityLabel("Stop " + member.chat.displayTitle); stop.toolTip = stop.accessibilityLabel()
                stop.onPress = { [weak model] in model?.stopSubagent(SubagentTarget(link), from: value.ownerID) }
                controls.append(stop); actions.append(.view(stop))
            }
            let labels = ShellStack(.vertical, spacing: 4, [.view(name, .fill), .view(status, .fill)])
            let buttons = ShellStack(.horizontal, spacing: 6, actions)
            rows.append(ShellStack(.vertical, spacing: 7, padding: NSEdgeInsets(top: 6, left: 0, bottom: 8, right: 0), [.view(labels, .fill), .view(buttons, .fill)]))
        }
        let stopAll = PiKit.Button("Stop All…", style: .ghost, compact: true)
        stopAll.isEnabled = value.agents.activeCount > 0
        stopAll.setAccessibilityLabel("Stop all \(value.agents.activeCount) running or queued sub-agents")
        stopAll.onPress = { [weak self] in self?.confirmStopAll() }
        let inspect = PiKit.Button("Inspect Family", symbol: "info.circle", style: .ghost, compact: true)
        inspect.onPress = { [weak model, close] in close(); model?.inspect(value.ownerID) }
        if !value.agents.members.isEmpty { controls.append(contentsOf: [stopAll, inspect]); rows.append(ShellStack(.horizontal, spacing: 8, [.view(stopAll), .spacer(0), .view(inspect)])) }
        let stack = ShellStack(.vertical, spacing: 8, padding: NSEdgeInsets(top: 16, left: 16, bottom: 12, right: 16), rows.map { .view($0, .fill) })
        self.stack = stack; addSubview(stack)
        for (index, button) in controls.enumerated() { button.nextKeyView = controls[(index + 1) % controls.count] }
        selectedIndex = min(selectedIndex, max(0, openButtons.count - 1))
        needsLayout = true
        if restoreFocus { window?.makeFirstResponder(self) }
    }
    private func confirmStopAll() {
        guard let family, family.agents.activeCount > 0, let ownerWindow else { return }
        let ownerID = family.ownerID
        let targets = family.agents.members.filter(\.active).compactMap { $0.chat.delegation }.map { link in
            var target = SubagentTarget(link); target.turn = model.subagentSummaries[link.childSessionID]?.turn
            return target
        }
        close()
        _ = model.questions.askSheet(over: ownerWindow, make: { answer in
            AgentStopAllSheet(count: targets.count, answer: answer)
        }, answered: { [weak model] accepted in
            guard accepted, let model else { return }
            for target in targets where model.record(target.sessionID)?.delegation.map(target.matchesOrigin) == true && model.subagentSummaries[target.sessionID]?.status.terminal == false && model.subagentSummaries[target.sessionID]?.turn == target.turn {
                model.stopSubagent(target, from: ownerID)
            }
        })
    }
    func height(forWidth width: CGFloat) -> CGFloat { stack?.height(forWidth: width) ?? 0 }
    override func layout() { super.layout(); stack?.frame = bounds }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { window?.makeFirstResponder(self) } }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: close()
        case 125, 126:
            guard !openButtons.isEmpty else { return }
            selectedIndex = (selectedIndex + (event.keyCode == 125 ? 1 : openButtons.count - 1)) % openButtons.count
            let button = openButtons[selectedIndex]; window?.makeFirstResponder(button); scrollToVisible(button.convert(button.bounds, to: self))
        case 36, 76: if !openButtons.isEmpty { openButtons[selectedIndex].onPress?() }
        case 48: if let first = controls.first { window?.makeFirstResponder(first) }
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
