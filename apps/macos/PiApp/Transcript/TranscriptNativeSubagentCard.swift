import AppKit

/// The parent's compact account of a delegated task. The complete transcript
/// and capture remain in the child; these viewports only bound screen space.
@MainActor final class TranscriptNativeSubagentCard: TranscriptNativeCard {
    var actions = TranscriptActions()
    private var value: SubagentToolView?
    private let information = TranscriptPlainTextView()
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("subagent-card")
        for view in [information, task, result, resultNote, buttons] as [NSView] { addSubview(view) }
        task.isToolInput = true
        task.changed = { [weak self] in self?.invalidatePlans() }
        result.changed = { [weak self] in self?.invalidatePlans() }
        open.setAccessibilityIdentifier("open-subagent")
        inspect.setAccessibilityIdentifier("inspect-subagent")
        stop.setAccessibilityIdentifier("stop-subagent")
        open.onPress = { [weak self] in guard let self, !self.historical, self.open.isEnabled else { return }
            if self.value?.operation == "subagent_report", let reference = self.value?.messageReference { self.actions.openAgentSource?(reference) }
            else if let target = self.value?.target { self.actions.openSubagent?(target) } }
        inspect.onPress = { [weak self] in guard let self, !self.historical, self.inspect.isEnabled, let target = self.value?.target else { return }; self.actions.inspectSubagent?(target) }
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
        if historical { lines.append(SubagentToolView.historicalNotice) }
        if value.heldByUser, !historical { lines.append("Held until a new parent task or explicit Resume.") }
        if let summary = value.summary {
            if let count = summary.pendingMessages, count > 0, !historical { lines.append("\(count) pending " + (count == 1 ? "message" : "messages")) }
            lines.append("Model: " + summary.model + (value.effort.map { " · " + $0 } ?? ""))
            if let tools = summary.tools { lines.append(tools.isEmpty ? "Tools: none" : "Tools: " + tools.joined(separator: ", ")) }
            if let progress = summary.progress {
                lines.append("\(progress.requests) requests · \(progress.tools) tools completed · " + TranscriptActivity.formatDuration(progress.elapsedMs))
                lines.append("Reported " + compactGatewayUSD(progress.usd) + " · \(progress.reported) reported" + (progress.unreported > 0 ? " · \(progress.unreported) cost unknown" : ""))
                lines.append("Tokens: " + (progress.inputTokens.map(String.init) ?? "unknown") + " input · " + (progress.outputTokens.map(String.init) ?? "unknown") + " output")
                if !progress.preview.isEmpty, !value.status.terminal, !historical { lines.append(progress.preview) }
            }
        }
        information.update(text: lines.joined(separator: "\n"), face: TranscriptCardFaces.note, environment: environment, swiftUILines: true, color: TranscriptNSPalette.muted)
        task.title = value.operation == "subagent_report" ? value.messageKind?.capitalized ?? "Message" : value.operation == "subagent_send" ? "Message" : "Task"
        task.update(value.task, environment: environment, actions: actions)
        hasResult = !value.result.isEmpty; result.isHidden = !hasResult
        result.update(value.result, environment: environment, actions: actions)
        let truncation = historical ? "Result truncated. Open the source chat to view the complete saved reply." : "Result truncated. Open the sub-agent for the complete saved reply."
        let note = [value.error, value.truncated ? truncation : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        hasResultNote = !note.isEmpty; resultNote.isHidden = !hasResultNote
        resultNote.update(text: note, face: TranscriptCardFaces.note, environment: environment, swiftUILines: true, color: TranscriptNSPalette.muted)
        open.title = historical ? "History" : value.operation == "subagent_report" ? "Parent" : "Open"
        if historical { open.toolTip = SubagentToolView.historicalNotice; open.setAccessibilityLabel(open.toolTip) }
        open.isEnabled = !historical && environment.isEnabled && (value.target != nil || value.operation == "subagent_report" && value.messageReference != nil)
        inspect.isEnabled = !historical && environment.isEnabled && value.target != nil
        stop.isHidden = value.status.terminal || value.heldByUser || value.target?.ownerID != environment.sessionID || value.operation == "subagent_report"
        stop.isEnabled = environment.isEnabled && value.status != .stopping
        buttons.invalidateIntrinsicContentSize(); buttons.needsLayout = true
    }
    override func plan(width: CGFloat) -> Plan {
        let inner = max(1, width - 32)
        var y: CGFloat = 12, frames: [(NSView, CGRect)] = []
        func place(_ view: NSView, _ height: CGFloat) {
            frames.append((view, CGRect(x: 16, y: y, width: inner, height: ceil(height))))
            y += ceil(height) + 10
        }
        place(information, information.exactHeight(width: inner))
        place(task, task.height(width: inner))
        if hasResult { place(result, result.height(width: inner)) }
        if hasResultNote { place(resultNote, resultNote.exactHeight(width: inner)) }
        place(buttons, buttons.height(forWidth: inner))
        return Plan(frames: frames, height: y + 2)
    }
}
