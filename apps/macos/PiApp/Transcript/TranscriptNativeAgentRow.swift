import AppKit

/// Provider input roles do not convey human authorship. Each event in a
/// delivery batch keeps its own author, child and turn, including mixed batches.
struct AgentMessagePresentation: Equatable {
    struct Event: Equatable {
        var childID: String, turn: Int, author: String, kind: String, task: String, text: String
        var eventID: String?, replyTo: String?
        var number: Int? = nil
        var note: String? = nil
        var childName: String { SubagentLabel.name(number) }
        var title: String {
            let name = author == "parent" ? "Parent → " + childName : childName
            return name + (task.isEmpty ? "" : " · " + task) + " · turn \(turn)"
        }
        var label: String {
            switch kind {
            case "task": "Task"
            case "follow_up": "Follow-up"
            case "steer": "Steering"
            case "question": "Question"
            case "blocker": "Blocker"
            case "result": "Result"
            case "not_delivered_interrupted": "Not delivered"
            default: "Note"
            }
        }
    }
    var events: [Event]
    init(_ message: TranscriptMessage) {
        let metadata = message.nativeAgentDelivery?.object ?? [:]
        let envelope = message.text.data(using: .utf8).flatMap { try? JSONDecoder().decode(WireValue.self, from: $0) }?.object
        let batch = metadata["events"]?.array ?? envelope?["events"]?.array
        let fallbackKind = (metadata["turn"]?.nonnegativeInteger ?? 1) > 1 ? "follow_up" : "task"
        events = (batch ?? [.object(["text":.string(message.text), "kind":.string(fallbackKind)])]).compactMap { raw in
            guard let row = raw.object,
                  let author = row["author"]?.string ?? metadata["author"]?.string, ["parent", "subagent"].contains(author),
                  let child = row["child_id"]?.string ?? metadata["childId"]?.string,
                  let turn = row["turn"]?.nonnegativeInteger ?? metadata["turn"]?.nonnegativeInteger, turn > 0 else { return nil }
            let text = row["text"]?.string ?? ""
            let result = row["result"]?.object
            var notes: [String] = []
            if result?["text_truncated"]?.bool == true || result?["result_truncated"]?.bool == true { notes.append("Excerpt — open the sub-agent for the saved response.") }
            if let error = result?["error"]?.object?["message"]?.string { notes.append(error) }
            return Event(childID: child, turn: turn, author: author, kind: row["kind"]?.string ?? "note",
                         task: row["task"]?.string ?? metadata["task"]?.string ?? "", text: text,
                         eventID: row["event_id"]?.string ?? metadata["eventIds"]?.array?.first?.string,
                         replyTo: row["reply_to"]?.string ?? metadata["replyTo"]?.string, number: message.agentNumbers?[child],
                         note: notes.isEmpty ? nil : notes.joined(separator: "\n\n"))
        }
    }
}

@MainActor final class TranscriptNativeAgentRow: TranscriptNativeMessageRow {
    private let column = ShellStack(.vertical, spacing: 10)
    private var prose: [String: TranscriptAgentMarkdown] = [:]
    override class func message(of item: TranscriptItem) -> TranscriptMessage? {
        guard case .message(let row) = item, row.kind == "agent_message" || row.nativeAgentDelivery != nil else { return nil }
        return row
    }
    override init(inputs: TranscriptRowInputs) {
        super.init(inputs: inputs); addSubview(column)
        setAccessibilityIdentifier("agent-message-row"); apply(inputs)
    }
    required init?(coder: NSCoder) { nil }
    override func configure() {
        let presentation = AgentMessagePresentation(message), actions = inputs.actions, id = message.id
        var items: [ShellItem] = []
        var retained: [String: TranscriptAgentMarkdown] = [:]
        for (index, event) in presentation.events.enumerated() {
            let heading = PiKit.WrappedText(event.title, font: PiKit.Font.caption, color: .piInkSecondary)
            heading.toolTip = event.title
            let key = event.eventID ?? "\(event.childID):\(event.turn):\(event.kind):\(index)"
            let words = prose[key] ?? TranscriptAgentMarkdown(label: "", identity: key)
            words.accessibilityName = event.label + " from " + event.title
            words.changed = { [weak self] in self?.column.invalidateIntrinsicContentSize(); self?.column.needsLayout = true; self?.owner?.contentSizeChanged() }
            words.update(event.text, environment: inputs.environment, actions: actions)
            words.markdown.textView.setAccessibilityLabel(words.accessibilityName)
            retained[key] = words
            let badge = PiKit.Badge(text: event.label, tone: event.kind == "blocker" ? .danger : .neutral)
            let inspect = PiKit.Button("Inspect delivery", style: .ghost, compact: true) { actions.inspect(id) }
            let source = PiKit.Button(event.author == "parent" ? "Source in parent" : "Source in " + event.childName, symbol: "arrow.up.right", style: .ghost, compact: true) {
                actions.openAgentSource?(.init(childID: event.childID, turn: event.turn, eventID: event.eventID))
            }
            source.setAccessibilityIdentifier("agent-message-source")
            source.toolTip = "Source of " + event.title; source.setAccessibilityLabel(source.toolTip)
            inspect.toolTip = "Inspect delivery for " + event.title; inspect.setAccessibilityLabel(inspect.toolTip)
            let buttons = PiKit.FlowView(); buttons.spacing = 8
            buttons.addSubview(source); buttons.addSubview(inspect)
            var content: [ShellItem] = [.view(heading, .fill), .view(badge), .view(words, .fill)]
            if let note = event.note { content.append(.view(PiKit.Note(note, tone: .neutral), .fill)) }
            content.append(.view(buttons, .fill))
            let body = ShellStack(.vertical, spacing: 8, content)
            items.append(.view(PiKit.card(body, padding: 12, sunken: true), .fill))
        }
        if items.isEmpty { items = [.view(PiKit.Note("Agent message attribution is unavailable. Inspect the saved row for details.", tone: .neutral), .fill)] }
        column.items = items
        prose = retained
        setAccessibilityLabel(presentation.events.map { $0.title + " · " + $0.label }.joined(separator: "; "))
        toolTip = accessibilityLabel()
    }
    override func contentHeight(width: CGFloat) -> CGFloat { column.height(forWidth: max(1, width - 16)) }
    override func place(in rect: CGRect) { column.frame = CGRect(x: rect.minX + 8, y: rect.minY, width: max(1, rect.width - 16), height: rect.height) }
}
