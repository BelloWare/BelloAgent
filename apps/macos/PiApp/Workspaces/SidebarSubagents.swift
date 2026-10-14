import AppKit

struct SubagentGroupState: Equatable {
    var parentID: String
    var count: Int, active: Int, queued: Int
    var expanded: Bool
    var indent: CGFloat
    var pending = 0
    var label: String {
        "\(count) sub-agent\(count == 1 ? "" : "s")" + (active > 0 ? " · \(active) running" : "") + (queued > 0 ? " · \(queued) queued" : "") + (pending > 0 ? " · \(pending) pending" : "")
    }
}

extension WorkspaceModel {
    func subagentChildren(of parentID: String) -> [ChatRecord] { sidebarIndex.subagents(of: parentID, in: chats) }
    func subagentGroupExpanded(_ parentID: String) -> Bool {
        guard let parent = record(parentID) else { return false }
        // Reveal the open child without replacing the reader's saved fold.
        if let id = focusedSessionID ?? selectedID, let child = record(id),
           child.workspaceID == parent.workspaceID, child.delegation?.budgetOwnerSessionID == parentID { return true }
        return projectSidebarStates[parent.workspaceID]?.expandedSubagents?.contains(parentID) == true
    }
    func setSubagentGroupExpanded(_ parentID: String, expanded: Bool) {
        guard let parent = record(parentID) else { return }
        var value = projectSidebarStates[parent.workspaceID] ?? ProjectSidebarState(id: parent.workspaceID)
        var ids = Set(value.expandedSubagents ?? [])
        if expanded { ids.insert(parentID) } else { ids.remove(parentID) }
        value.expandedSubagents = ids.isEmpty ? nil : ids.sorted()
        saveProjectSidebarState(value)
    }
    func subagentGroupState(parent: ChatRecord, indent: CGFloat, filtering: Bool) -> SubagentGroupState? {
        let children = subagentChildren(of: parent.id).filter { $0.workspaceID == parent.workspaceID && $0.isArchived == parent.isArchived }
        guard !children.isEmpty else { return nil }
        let states = children.compactMap { subagentSummaries[$0.id]?.status }
        return SubagentGroupState(parentID: parent.id, count: children.count,
            active: states.filter { $0 == .running || $0 == .stopping }.count, queued: states.filter { $0 == .queued }.count,
            expanded: filtering || subagentGroupExpanded(parent.id), indent: indent,
            pending: children.reduce(0) { $0 + (subagentSummaries[$1.id]?.pendingMessages ?? 0) })
    }
}

@MainActor final class SidebarSubagentGroupView: NSView, SidebarEntryView {
    private let button = PiKit.Button("", style: .ghost, compact: true)
    private let model: WorkspaceModel
    private var state: SubagentGroupState
    init(model: WorkspaceModel, state: SubagentGroupState) {
        self.model = model; self.state = state
        super.init(frame: .zero); addSubview(button)
        button.onPress = { [weak self] in guard let self else { return }; self.model.setSubagentGroupExpanded(self.state.parentID, expanded: !self.state.expanded) }
        update(state)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func update(_ state: SubagentGroupState) {
        self.state = state
        button.title = state.label
        button.symbol = state.expanded ? "chevron.down" : "chevron.right"
        button.toolTip = state.label
        button.setAccessibilityIdentifier("subagent-group-" + state.parentID)
        button.setAccessibilityLabel(state.label + (state.expanded ? ", expanded" : ", collapsed"))
        needsLayout = true
    }
    func entryHeight(width: CGFloat) -> CGFloat { 28 }
    override func layout() {
        super.layout()
        let available = max(0, bounds.width - state.indent)
        // Size the centered Pi face to its contents so the chevron stays at
        // the same indent when counts/status change. Keep the whole face in
        // bounds; full counts remain in the tooltip and AX label.
        let noun = state.count == 1 ? "sub-agent" : "sub-agents"
        let compact = state.count.formatted(.number.notation(.compactName))
        for title in [state.label, "\(state.count) \(noun)", "\(compact) \(noun)", compact] {
            button.title = title
            if button.intrinsicContentSize.width <= available { break }
        }
        button.frame = CGRect(x: state.indent, y: 0, width: min(available, button.intrinsicContentSize.width), height: 28)
    }
}
