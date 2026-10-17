import AppKit

/// The parent's compact account of a delegated task. The complete transcript
/// and capture remain in the child; these viewports only bound screen space.
@MainActor final class TranscriptNativeSubagentCard: TranscriptNativeCard {
    var actions = TranscriptActions()
    private var value: SubagentToolView?
    private let information = TranscriptPlainTextView()
    private let details = ShellStack(.vertical, spacing: 4)
    private struct Detail: Equatable { var label: String, value: String; var note: String? = nil }
    private var detailValues: [Detail] = []
    private let task = TranscriptAgentMarkdown(label: "Task", identity: "task")
    private let result = TranscriptAgentMarkdown(label: "Result", identity: "result")
    private let resultNote = TranscriptPlainTextView()
    private let open = PiKit.Button("Open", symbol: "arrow.up.right", style: .secondary, compact: true)
    private let inspect = PiKit.Button("Inspect Requests", style: .secondary, compact: true)
    private let stop = PiKit.Button("Stop", symbol: "stop.fill", style: .danger, compact: true)
    private lazy var buttons: PiKit.FlowView = {
        let flow = PiKit.FlowView(); flow.spacing = 8; flow.rowSpacing = 8
        for button in [open, inspect, stop] { flow.addSubview(button) }
        return flow
    }()
    private var hasResult = false
    private var hasResultNote = false
    private var historical = false
    private var hasInformation = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("subagent-card")
        for view in [information, details, task, result, resultNote, buttons] as [NSView] { addSubview(view) }
        details.setAccessibilityIdentifier("subagent-details")
        details.setAccessibilityRole(.group); details.setAccessibilityLabel("Sub-agent details")
        task.isToolInput = true
        task.changed = { [weak self] in self?.invalidatePlans() }
        result.changed = { [weak self] in self?.invalidatePlans() }
        open.setAccessibilityIdentifier("open-subagent")
        inspect.setAccessibilityIdentifier("inspect-subagent")
        stop.setAccessibilityIdentifier("stop-subagent")
        open.onPress = { [weak self] in guard let self, self.open.isEnabled else { return }
            if self.value?.operation == "subagent_report", let reference = self.value?.messageReference { self.actions.openAgentSource?(reference) }
            else if let target = self.value?.target { self.actions.openSubagent?(target) } }
        inspect.onPress = { [weak self] in guard let self, self.inspect.isEnabled, let target = self.value?.target else { return }; self.actions.inspectSubagent?(target) }
        stop.onPress = { [weak self] in guard let self, !self.historical, !self.stop.isHidden, self.stop.isEnabled, let target = self.value?.target else { return }; self.actions.stopSubagent?(target) }
    }
    required init?(coder: NSCoder) { nil }
    override func configure(_ card: TranscriptToolRow.Card) {
        guard case .subagent(let value) = card else { return }
        self.value = value
        setAccessibilityLabel(value.title + " · " + value.label)
        toolTip = value.title + " · " + value.label
        open.toolTip = value.operation == "subagent_report" ? "Open parent of " + value.title : "Open " + value.title
        open.setAccessibilityLabel(open.toolTip)
        inspect.toolTip = "Inspect requests for " + value.title; inspect.setAccessibilityLabel(inspect.toolTip)
        stop.toolTip = "Stop " + value.title; stop.setAccessibilityLabel(stop.toolTip)
        historical = value.target?.isHistorical(in:environment.sessionID) == true
        var lines: [String] = []
        if historical { lines.append(value.originalAvailability?.label ?? SubagentToolView.historicalNotice); if let reason = value.originalAvailability?.reason { lines.append(reason) } }
        if value.heldByUser, !historical { lines.append("Held until a new parent task or explicit Resume.") }
        var fields: [Detail] = []
        if let summary = value.summary {
            if let count = summary.pendingMessages, count > 0, !historical { lines.append("\(count) pending " + (count == 1 ? "message" : "messages")) }
            fields.append(.init(label: "Model", value: summary.model))
        }
        if let effort = value.effort { fields.append(.init(label: "Effort", value: effort)) }
        if let summary = value.summary {
            var tools = summary.tools.map { $0.isEmpty ? "None" : $0.joined(separator: ", ") }
            if let progress = summary.progress { tools = [tools, "\(progress.tools) completed"].compactMap { $0 }.joined(separator: " · ") }
            if let tools { fields.append(.init(label: "Tools", value: tools)) }
            if let progress = summary.progress {
                fields.append(.init(label: "Requests", value: String(progress.requests)))
                fields.append(.init(label: "Time", value: TranscriptActivity.formatDuration(progress.elapsedMs)))
                let unknown = value.cost?.unreportedRequests ?? progress.unreported
                let note = unknown > 0 ? "\(unknown) " + (unknown == 1 ? "request's" : "requests'") + " cost unknown" : nil
                fields.append(.init(label: "Cost", value: compactGatewayUSD(value.cost?.spentUSD ?? progress.usd), note: [note, value.cost?.costAttribution ?? (historical ? "Counts toward original parent chat" : "Counts toward parent chat")].compactMap { $0 }.joined(separator: " · ")))
                fields.append(.init(label: "Tokens", value: (progress.inputTokens.map(String.init) ?? "Unknown") + " input · " + (progress.outputTokens.map(String.init) ?? "unknown") + " output"))
                if !progress.preview.isEmpty, !value.status.terminal, !historical { lines.append(progress.preview) }
            }
        }
        if value.summary?.progress == nil, let cost = value.cost, let spent = cost.spentUSD {
            fields.append(.init(label:"Cost",value:compactGatewayUSD(spent),note:[cost.unreportedNote,cost.costAttribution ?? "Counts toward parent chat"].compactMap { $0 }.joined(separator:" · ")))
        }
        updateDetails(fields)
        hasInformation = !lines.isEmpty; information.isHidden = !hasInformation
        information.update(text: lines.joined(separator: "\n"), face: TranscriptCardFaces.note, environment: environment, swiftUILines: true, color: TranscriptNSPalette.muted)
        task.title = value.operation == "subagent_report" ? value.messageKind?.capitalized ?? "Message" : value.operation == "subagent_send" ? "Message" : "Task"
        task.update(value.task, environment: environment, actions: actions)
        hasResult = !value.result.isEmpty; result.isHidden = !hasResult
        result.update(value.result, environment: environment, actions: actions)
        let truncation = historical ? "Result truncated. Open the source chat to view the complete saved reply." : "Result truncated. Open the sub-agent for the complete saved reply."
        let note = [value.error, value.truncated ? truncation : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        hasResultNote = !note.isEmpty; resultNote.isHidden = !hasResultNote
        resultNote.update(text: note, face: TranscriptCardFaces.note, environment: environment, swiftUILines: true, color: TranscriptNSPalette.muted)
        open.title = value.operation == "subagent_report" ? "Parent" : "Open"
        if historical { open.toolTip = value.originalAvailability?.reason ?? value.originalAvailability?.label ?? SubagentToolView.historicalNotice; open.setAccessibilityLabel(open.toolTip) }
        let available = !historical || (value.originalAvailability != nil && value.originalAvailability?.reason == nil)
        open.isEnabled = available && environment.isEnabled && (value.target != nil || value.operation == "subagent_report" && value.messageReference != nil)
        inspect.isEnabled = available && environment.isEnabled && value.target != nil
        // A turn held at the cost limit is not running: nothing to stop until Resume.
        stop.isHidden = value.status.terminal || value.heldByUser || value.summary?.pausedAtCostLimit == true || value.target?.ownerID != environment.sessionID || value.operation == "subagent_report"
        stop.isEnabled = environment.isEnabled && value.status != .stopping
        buttons.invalidateIntrinsicContentSize(); buttons.needsLayout = true
    }
    /// Seven small metadata fields, rebuilt only when their values change.
    /// Transcript prose and its Markdown caches are independent of this grid.
    private func updateDetails(_ fields: [Detail]) {
        details.isHidden = fields.isEmpty
        guard fields != detailValues else { return }
        detailValues = fields
        details.items = fields.map { field in
            .view(SubagentDetailRow(key: field.label, value: field.value, note: field.note), .fill)
        }
    }
    override func plan(width: CGFloat) -> Plan {
        let inner = max(1, width - 32)
        var y: CGFloat = 12, frames: [(NSView, CGRect)] = []
        func place(_ view: NSView, _ height: CGFloat) {
            frames.append((view, CGRect(x: 16, y: y, width: inner, height: ceil(height))))
            y += ceil(height) + 10
        }
        if hasInformation { place(information, information.exactHeight(width: inner)) }
        if !detailValues.isEmpty { place(details, details.height(forWidth: inner)) }
        place(task, task.height(width: inner))
        if hasResult { place(result, result.height(width: inner)) }
        if hasResultNote { place(resultNote, resultNote.exactHeight(width: inner)) }
        place(buttons, buttons.height(forWidth: inner))
        return Plan(frames: frames, height: y + 2)
    }
}

/// A fixed label column aligned with the value's first text baseline, even
/// when that value wraps or a cost note follows it. Uses only Pi text leaves.
@MainActor private final class SubagentDetailRow: NSView, PiKit.WidthSizing {
    private let key: PiKit.TextLine
    private let value: PiKit.SelectableText
    private let note: PiKit.WrappedText?
    private let valueX: CGFloat = 72
    init(key: String, value: String, note: String?) {
        self.key = PiKit.TextLine(.init(key, font: PiKit.Font.caption, color: .piInkSecondary))
        self.value = PiKit.SelectableText(value, font: PiKit.Font.caption, color: .piInk)
        self.note = note.map { PiKit.WrappedText($0, font: PiKit.Font.caption, color: .piInkSecondary) }
        super.init(frame: .zero)
        self.value.setAccessibilityLabel(key); self.value.toolTip = value
        if key == "Cost" { self.value.toolTip = "Reported cost for this sub-agent" + (note.map { ". " + $0 } ?? "") }
        addSubview(self.key); addSubview(self.value)
        if let note = self.note { addSubview(note) }
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    private var baseline: CGFloat { max(key.line.baseline(scale: piScale), value.firstBaselineOffsetFromTop) }
    private var keyY: CGFloat { baseline - key.line.baseline(scale: piScale) }
    private var valueY: CGFloat { baseline - value.firstBaselineOffsetFromTop }
    private func valueWidth(_ width: CGFloat) -> CGFloat { max(1, width - valueX) }
    private func bodyHeight(_ width: CGFloat) -> CGFloat {
        max(keyY + key.intrinsicContentSize.height, valueY + value.height(forWidth: valueWidth(width)))
    }
    func height(forWidth width: CGFloat) -> CGFloat {
        bodyHeight(width) + (note.map { 2 + $0.height(forWidth: max(1, valueWidth(width) - PiKit.fieldInset)) } ?? 0)
    }
    override func layout() {
        super.layout()
        let width = valueWidth(bounds.width)
        key.frame = .init(x: 0, y: keyY, width: 60, height: key.intrinsicContentSize.height)
        value.frame = .init(x: valueX, y: valueY, width: width, height: value.height(forWidth: width))
        if let note {
            note.frame = .init(x: valueX + PiKit.fieldInset, y: bodyHeight(bounds.width) + 2,
                               width: max(1, width - PiKit.fieldInset), height: note.height(forWidth: max(1, width - PiKit.fieldInset)))
        }
    }
}
