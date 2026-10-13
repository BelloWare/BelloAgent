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
        var views: [NSView] = [InspectorPageHeader(group.title, subtitle: group.summary.model, badges: [PiKit.Badge(text: group.summary.status.label, tone: group.summary.status == .completed ? .success : .neutral)], actions: []),
                               inspectorText(group.detail, color: .piInkSecondary), inspectorRow(actions.map { .view($0) }, spacing: 8)]
        let requests = inspector.index.requests.filter { $0.delegationID == delegationID }.sorted { ($0.wall,$0.id) < ($1.wall,$1.id) }
        if requests.isEmpty {
            views.append(InspectorBanner(symbol: "clock", text: group.requests == 0 ? "This task has no captured requests. Queued or cancelled tasks can finish without dispatching one." : "This task’s requests are outside the current navigator window. Select this sub-agent in the filter to read its newest requests.", tone: .neutral))
        }
        column.items = views.map { .view($0, .fill) }
        requestsView.update(LazyStackView.Source(count: requests.count, key: { requests[$0].id }, height: { _, _ in 32 }, view: { [weak inspector] offset, _ in
            let request = requests[offset]
            let button = PiKit.Button("\(offset + 1). \(inspector?.index.kind(of: request.id) ?? request.purpose) · \(request.route.label)", symbol: "arrow.up.arrow.down", style: .ghost) { [weak inspector] in inspector?.select(.request(request.id)) }
            button.setAccessibilityIdentifier("inspector-subagent-request-" + request.id)
            return button
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
