import AppKit

@MainActor final class InspectorSubagentPage: DashView {
    let inspector: SessionInspectorModel
    var delegationID: String { didSet { if delegationID != oldValue { refresh() } } }
    private let column = ShellStack(.vertical, spacing: 16)
    private let requestsView = LazyStackView()
    private lazy var observer = ShellObserver { [weak self] in self?.refresh() }
    init(inspector: SessionInspectorModel, delegationID: String) {
        self.inspector = inspector; self.delegationID = delegationID
        super.init(frame: .zero); shellAdd([column, requestsView])
        setAccessibilityIdentifier("inspector-subagent-page"); observer.observe(inspector); refresh()
    }
    required init?(coder: NSCoder) { nil }
    func refresh() {
        let focus = InspectorButtonFocus(in: self); defer { focus?.restore(in: self) }
        guard let group = inspector.groups.first(where: { $0.id == delegationID }) else { return }
        let link = group.summary.link
        var actions: [NSView] = [PiKit.Button("Open sub-agent", symbol: "text.bubble", style: .ghost) { [weak inspector] in inspector?.showInChat() }]
        if let parent = link.parentAttemptID {
            actions.append(PiKit.Button("Parent request", symbol: "arrow.turn.up.left", style: .ghost) { [weak inspector] in inspector?.focus(.request(parent)) })
        }
        actions.append(PiKit.Button("Originating tool", symbol: "arrow.up.left", style: .ghost) { [weak inspector] in
            inspector?.showSubagentParent(link)
        })
        var views: [NSView] = [InspectorPageHeader(group.title, subtitle: group.summary.model, badges: [PiKit.Badge(text: group.summary.presentationLabel, tone: group.summary.status == .completed ? .success : .neutral)], actions: []),
                               inspectorText(group.detail, color: .piInkSecondary), inspectorRow(actions.map { .view($0) }, spacing: 8)]
        let entries = inspector.coordination.filter { $0.childID == link.childSessionID }
        if !entries.isEmpty { views.append(inspector.coordinationMenu(entries)) }
        let requests = inspector.index.requests.filter { $0.delegationID == delegationID }.sorted { ($0.wall,$0.id) < ($1.wall,$1.id) }
        if requests.isEmpty {
            views.append(InspectorBanner(symbol: "clock", text: group.requests == 0 ? "This task has no captured requests. Queued or cancelled tasks can finish without dispatching one." : "This task’s requests are outside the current navigator window. Select this sub-agent in the filter to read its newest requests.", tone: .neutral))
        }
        column.items = views.map { .view($0, .fill) }
        let turns = Set(requests.map { $0.childTurn ?? 1 } + entries.map(\.turn)).sorted()
        let rows: [(turn: Int, request: InspectorRequestRow?)] = turns.flatMap { turn in
            [(turn, nil)] + requests.filter { ($0.childTurn ?? 1) == turn }.map { (turn, $0) }
        }
        requestsView.update(LazyStackView.Source(count: rows.count, key: { rows[$0].request?.id ?? "turn-\(rows[$0].turn)" }, height: { offset, _ in rows[offset].request == nil ? 40 : 32 }, view: { [weak inspector] offset, _ in
            let item = rows[offset]
            guard let request = item.request else {
                let title = inspectorText("Turn \(item.turn)", color: .piInkSecondary)
                let messages = entries.filter { $0.turn == item.turn }
                var items: [ShellItem] = [.view(title), .spacer(0)]
                if let inspector, !messages.isEmpty { items.append(.view(inspector.coordinationMenu(messages))) }
                return ShellStack(.horizontal, spacing: 8, items)
            }
            let button = PiKit.Button("\(inspector?.index.kind(of: request.id) ?? request.purpose) · \(request.route.label)", symbol: "arrow.up.arrow.down", style: .ghost) { [weak inspector] in inspector?.select(.request(request.id)) }
            button.setAccessibilityIdentifier("inspector-subagent-request-" + request.id)
            return ShellStack(.horizontal, spacing: 8, [.view(button), .spacer(0)])
        }))
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 48), height = column.height(forWidth: width)
        column.frame = CGRect(x: 24, y: 20, width: width, height: height)
        requestsView.frame = CGRect(x: 24, y: column.frame.maxY + 12, width: width, height: max(0, bounds.height - column.frame.maxY - 32))
    }
}
