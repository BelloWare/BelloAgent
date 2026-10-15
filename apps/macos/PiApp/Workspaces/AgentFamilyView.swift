import AppKit
import Combine

/// A dedicated row in the conversation column, never a transcript overlay
/// or a window-toolbar item. Embedded child tabs suppress this row.
@MainActor final class AgentFamilyHeaderView: NSView {
    let button = PiKit.Button("Agents", symbol: "person.crop.rectangle.stack", style: .secondary, compact: true)
    let popover = PiPopoverPresenter()
    private let spinner = PiSpinnerView(frame: NSRect(x: 0, y: 0, width: 11, height: 11))
    private weak var model: WorkspaceModel?
    private var sessionID = ""
    private var family: SubagentFamily?
    private var request: AnyCancellable?
    private var enabled = true
    override init(frame: NSRect) {
        super.init(frame: frame); addSubview(button); addSubview(spinner)
        button.setAccessibilityIdentifier("agent-family-pill")
        button.onPress = { [weak self] in self?.open() }
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func update(model: WorkspaceModel, sessionID: String, enabled: Bool) {
        if self.model !== model {
            self.model = model
            request = model.agentFamilyRequests.sink { [weak self] owner in
                MainActor.assumeIsolated {
                    guard let self, self.family?.ownerID == owner, !self.isHiddenOrHasHiddenAncestor,
                          self.window?.isKeyWindow == true else { return }
                    self.open()
                }
            }
        }
        self.sessionID = sessionID; self.enabled = enabled; button.isEnabled = enabled
        let next = model.subagentFamily(sessionID)
        guard next != family else { return }
        family = next; isHidden = next.members.isEmpty
        let running = next.runningCount
        button.title = "Agents \(next.members.count)" + (running > 0 ? " · \(running) running" : "")
        let label = "\(next.members.count) sub-agents" + (running > 0 ? ", \(running) sub-agents running" : "")
        button.toolTip = label + ". Open sub-agents and inspect this family."
        button.setAccessibilityLabel(button.toolTip)
        spinner.isHidden = running == 0
        spinner.configure(lineWidth: 1.6, turning: running > 0 && !PiKit.Motion.reduced)
        needsLayout = true
        if next.members.isEmpty { popover.close() }
    }
    func open() {
        guard enabled, !isHidden, let model, window != nil else { return }
        let width = min(400, max(280, (window?.contentView?.bounds.width ?? 400) - 48))
        popover.toggle(from: button, width: width, maximumHeight: 480, animates: !PiKit.Motion.reduced) { [weak self, weak model] in
            guard let self, let model else { return NSView() }
            return AgentFamilyPopoverView(model: model, sessionID: self.sessionID, close: { [weak self] in self?.popover.close() }, ownerWindow: self.window)
        }
    }
    override func layout() {
        super.layout()
        let width = min(max(0, bounds.width - 32), button.intrinsicContentSize.width)
        button.frame = CGRect(x: bounds.width - 16 - width, y: 5, width: width, height: 24)
        spinner.frame = CGRect(x: max(0, button.frame.minX - 18), y: 11, width: 11, height: 11)
    }
}

@MainActor final class AgentFamilyPopoverView: NSView, PiKit.WidthSizing {
    private let model: WorkspaceModel
    private let sessionID: String
    private let close: () -> Void
    private weak var ownerWindow: NSWindow?
    private var stack: ShellStack?
    private var observer: ShellObserver?
    private var family: SubagentFamily?
    private var openButtons: [PiKit.Button] = []
    private var controls: [PiKit.Button] = []
    private var selectedIndex = 0
    init(model: WorkspaceModel, sessionID: String, close: @escaping () -> Void, ownerWindow: NSWindow?) {
        self.model = model; self.sessionID = sessionID; self.close = close; self.ownerWindow = ownerWindow
        super.init(frame: .zero)
        let observer = ShellObserver { [weak self] in self?.refresh() }; observer.observe(model); self.observer = observer
        setAccessibilityIdentifier("agent-family-popover"); refresh()
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    func refresh() {
        let value = model.subagentFamily(sessionID)
        guard value != family else { return }; family = value
        let hadFocus = window?.firstResponder as? NSView
        let restoreFocus = hadFocus.map { $0 === self || $0.isDescendant(of: self) } ?? false
        stack?.removeFromSuperview(); openButtons = []; controls = []
        var rows: [NSView] = []
        let title = shellLine("Sub-agents", font: PiKit.Font.body, color: .piInk)
        rows.append(title)
        for member in value.members {
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
        stopAll.isEnabled = value.runningCount > 0
        stopAll.setAccessibilityLabel("Stop all \(value.runningCount) running or queued sub-agents")
        stopAll.onPress = { [weak self] in self?.confirmStopAll() }
        let inspect = PiKit.Button("Inspect Family", symbol: "info.circle", style: .ghost, compact: true)
        inspect.onPress = { [weak model, close] in close(); model?.inspect(value.ownerID) }
        controls.append(contentsOf: [stopAll, inspect])
        rows.append(ShellStack(.horizontal, spacing: 8, [.view(stopAll), .spacer(0), .view(inspect)]))
        let stack = ShellStack(.vertical, spacing: 8, padding: NSEdgeInsets(top: 16, left: 16, bottom: 12, right: 16), rows.map { .view($0, .fill) })
        self.stack = stack; addSubview(stack)
        for (index, button) in controls.enumerated() { button.nextKeyView = controls[(index + 1) % controls.count] }
        selectedIndex = min(selectedIndex, max(0, openButtons.count - 1))
        needsLayout = true
        if restoreFocus { window?.makeFirstResponder(self) }
    }
    private func confirmStopAll() {
        guard let family, family.runningCount > 0, let ownerWindow else { return }
        let ownerID = family.ownerID
        let targets = family.members.filter(\.active).compactMap { $0.chat.delegation }.map { link in
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

/// Small passive Pi badge on the parent's sidebar row, absent at zero.
@MainActor final class AgentRunningBadge: NSView {
    private let badge = PiKit.Badge(text: "")
    private var spinner: PiSpinnerView?
    override init(frame: NSRect) {
        super.init(frame: frame); addSubview(badge); badge.compact = true; isHidden = true
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { nil }
    func update(_ count: Int) {
        isHidden = count == 0
        badge.text = "\(count) agent\(count == 1 ? "" : "s")"
        toolTip = "\(count) sub-agent\(count == 1 ? "" : "s") running"
        setAccessibilityLabel(toolTip)
        if count > 0 {
            if spinner == nil {
                let view = PiSpinnerView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
                addSubview(view); spinner = view
            }
            spinner?.configure(lineWidth: 1.5, turning: !PiKit.Motion.reduced)
        } else {
            spinner?.removeFromSuperview(); spinner = nil
        }
        invalidateIntrinsicContentSize(); needsLayout = true
    }
    override var intrinsicContentSize: NSSize { NSSize(width: badge.intrinsicContentSize.width + 15, height: 18) }
    override func layout() { super.layout(); spinner?.frame = CGRect(x: 0, y: 4, width: 10, height: 10); badge.frame = CGRect(x: 15, y: 0, width: bounds.width - 15, height: bounds.height) }
}
