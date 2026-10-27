import AppKit

/// Provider input roles do not convey human authorship. Each event in a
/// delivery batch keeps its own author, child and turn, including mixed batches.
struct AgentMessagePresentation: Equatable {
    static let unavailable = "Agent message attribution is unavailable. Inspect the saved row for details."
    struct Event: Equatable {
        var childID: String, turn: Int, author: String, kind: String, task: String, text: String
        var eventID: String?, replyTo: String?
        var number: Int? = nil
        var note: String? = nil
        var taskName: String? = nil
        var sender: String? = nil
        var recipient: String? = nil
        var initialTask = false
        var childName: String { SubagentLabel.name(number, taskName: taskName) }
        var title: String {
            if let sender, let recipient {
                let from = SubagentLabel.task(sender) ?? sender, to = SubagentLabel.task(recipient) ?? recipient
                let route = kind == "FINAL_ANSWER" && recipient == "/root" || initialTask ? from : from + " → " + to
                return route + " · " + label
            }
            let name = author == "parent" ? "Parent → " + childName : childName
            return name + (task.isEmpty ? "" : " · " + task) + " · turn \(turn)"
        }
        var label: String {
            switch kind {
            case "NEW_TASK": "New task"
            case "MESSAGE": "Message"
            case "FINAL_ANSWER": "Final answer"
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
        if metadata["version"]?.number == 2 {
            guard message.codexAgents == true else { events = []; return }
            events = (metadata["events"]?.array ?? []).compactMap { raw in
                guard let row = raw.object, let kind = row["type"]?.string,
                      ["NEW_TASK", "MESSAGE", "FINAL_ANSWER"].contains(kind),
                      let sender = row["sender"]?.string, SubagentLabel.task(sender) != nil,
                      let recipient = row["recipient"]?.string, SubagentLabel.task(recipient) != nil,
                      let turn = row["turn"]?.nonnegativeInteger, turn > 0,
                      let text = row["text"]?.string else { return nil }
                let child = recipient == "/root" ? row["sender_child_id"]?.string : row["recipient_child_id"]?.string
                let childID = child ?? ""
                return Event(childID: childID, turn: turn, author: sender == "/root" ? "parent" : "subagent", kind: kind,
                    task: "", text: text, eventID: row["event_id"]?.string, replyTo: nil,
                    taskName: recipient == "/root" ? sender : recipient, sender: sender, recipient: recipient,
                    initialTask: kind == "NEW_TASK" && sender == "/root" && turn == 1 && row["event_id"]?.string == message.id)
            }
            return
        }
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
                         note: notes.isEmpty ? nil : notes.joined(separator: "\n\n"), taskName: message.agentNames?[child])
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
            let sourceName = event.sender.flatMap(SubagentLabel.task) ?? (event.author == "parent" ? "parent" : event.childName)
            let source = PiKit.Button("Source in " + sourceName, symbol: "arrow.up.right", style: .ghost, compact: true) {
                actions.openAgentSource?(.init(childID: event.childID, turn: event.turn, eventID: event.eventID))
            }
            source.isEnabled = !event.childID.isEmpty && inputs.environment.isEnabled
            source.setAccessibilityIdentifier("agent-message-source")
            source.toolTip = "Source of " + event.title; source.setAccessibilityLabel(source.toolTip)
            inspect.toolTip = "Inspect delivery for " + event.title; inspect.setAccessibilityLabel(inspect.toolTip)
            let buttons = PiKit.FlowView(); buttons.spacing = 8
            buttons.addSubview(source); buttons.addSubview(inspect)
            var content: [ShellItem] = [.view(heading, .fill)]
            if event.sender == nil { content.append(.view(badge)) }
            content.append(.view(words, .fill))
            if let note = event.note { content.append(.view(PiKit.Note(note, tone: .neutral), .fill)) }
            content.append(.view(buttons, .fill))
            let body = ShellStack(.vertical, spacing: 8, content)
            items.append(.view(PiKit.card(body, padding: 12, sunken: true), .fill))
        }
        if items.isEmpty { items = [.view(PiKit.Note(AgentMessagePresentation.unavailable, tone: .neutral), .fill)] }
        column.items = items
        prose = retained
        setAccessibilityLabel(presentation.events.map { $0.sender == nil ? $0.title + " · " + $0.label : $0.title }.joined(separator: "; "))
        toolTip = accessibilityLabel()
    }
    override func contentHeight(width: CGFloat) -> CGFloat { column.height(forWidth: max(1, width - 16)) }
    override func place(in rect: CGRect) { column.frame = CGRect(x: rect.minX + 8, y: rect.minY, width: max(1, rect.width - 16), height: rect.height) }
}
