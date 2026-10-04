import AppKit

/// Settings → Webhook: the request a chat sends when it finishes and waits
/// for its user. Saved with the rest of Settings; each chat's ⋯ menu turns it
/// off for that chat and previews it.
@MainActor final class WebhookSettingsCard: NSView, PiKit.WidthSizing, PiKit.SizeObserver {
    static let footer = "Sent when a chat finishes and waits for you: its run completed or failed and nothing else is queued. A run you stop sends nothing. "
        + "Placeholders: " + WebhookSettings.builtIns.map { "{{\($0)}}" }.joined(separator: ", ")
        + ", and each mini model parameter. In a JSON body they are escaped as JSON strings. "
        + "The chat's connection's mini model reads the chat's title, your last request, the assistant's output and your instructions, and writes the parameters as JSON. "
        + "A chat can turn the webhook off in its ⋯ menu, and preview it there."

    private let get: () -> WebhookSettings
    private let set: (WebhookSettings) -> Void
    /// Sends the webhook as typed, with a sample chat; returns the HTTP status.
    private let test: ((WebhookSettings) async throws -> Int)?
    /// The form's enabled state, which the test button also answers to.
    private let enabled: EnabledState?
    private let card: SettingsCard
    private var shape: Shape?
    private var testing = false
    private var testResult = ""
    private var testTone: PiTone = .neutral
    private struct Shape: Equatable { var enabled: Bool, post: Bool, result: String, tone: PiTone }

    // The rows, made once and kept: a change shows or hides them, and an
    // editor keeps its text, selection and keys.
    private lazy var toggle: PiKit.Switch = {
        let toggle = PiKit.Switch(isOn: get().enabled) { [weak self] on in self?.edit { $0.enabled = on } }
        toggle.setAccessibilityLabel("Send a webhook when a chat finishes")
        toggle.setAccessibilityIdentifier("settings-webhook")
        return toggle
    }()
    private lazy var url: PiKit.TextField = {
        let url = PiKit.TextField(placeholder: "https://example.com/hook", text: get().url, mono: true) { [weak self] text in self?.edit { $0.url = text } }
        url.field.setAccessibilityIdentifier("settings-webhook-url")
        return url
    }()
    private lazy var method: PiKit.Dropdown<String> = PiKit.Dropdown(selection: get().method, items: WebhookSettings.methods.map { ($0, $0) }, compact: true,
                                                                        accessibilityName: "Webhook method") { [weak self] value in self?.edit { $0.method = value } }
    private lazy var headers = editorRow("Headers JSON", detail: "Optional, for example {\"Authorization\": \"Bearer …\"}. Values may use placeholders.", height: 52,
                                         get: { $0.headers }, set: { $0.headers = $1 })
    private lazy var body = editorRow("Body", detail: "Sent as JSON when it is JSON, as plain text otherwise.", height: 120, get: { $0.body }, set: { $0.body = $1 })
    private lazy var parameters = editorRow("Mini model parameters", detail: "JSON: each name → what the mini model writes for it. Leave empty to send without asking it.", height: 100,
                                            get: { $0.parameters }, set: { $0.parameters = $1 })
    private lazy var prompt = editorRow("Instructions for the mini model", detail: "Optional: tone, language, what to point out.", height: 52, last: test == nil,
                                        get: { $0.prompt }, set: { $0.prompt = $1 })
    private let sendSpinner = PiKit.spinner(controlSize: .small)
    private lazy var send: PiKit.Button = {
        let send = PiKit.Button("Send Test", symbol: "paperplane", style: .secondary, compact: true) { [weak self] in
            guard let self, let test = self.test, !self.testing else { return }
            Task { @MainActor in await self.run(test) }
        }
        send.setAccessibilityIdentifier("settings-webhook-test")
        return send
    }()
    private lazy var sendRow: HStackView = {
        let row = HStackView(spacing: PiSpacing.sm, views: [sendSpinner, send])
        row.items = { [weak self] in
            guard let self else { return [] }
            return (self.sendSpinner.isHidden ? [] : [.fixed(self.sendSpinner)]) + [.fixed(self.send)]
        }
        return row
    }()

    init(get: @escaping () -> WebhookSettings, set: @escaping (WebhookSettings) -> Void, test: ((WebhookSettings) async throws -> Int)? = nil, enabled: EnabledState? = nil) {
        self.get = get; self.set = set; self.test = test; self.enabled = enabled
        card = SettingsCard(title: "Webhook", footer: Self.footer)
        super.init(frame: .zero)
        addSubview(card)
        update()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func contentSizeChanged() { needsLayout = true; PiKit.sizeChanged(self) }
    func height(forWidth width: CGFloat) -> CGFloat { card.height(forWidth: width) }
    override func layout() { super.layout(); card.frame = bounds }

    /// Shows the settings as they are now: which rows there are changes only
    /// with the switch, the method and the test's outcome.
    func update() {
        let settings = get()
        let next = Shape(enabled: settings.enabled, post: settings.method == "POST", result: testResult, tone: testTone)
        if next != shape { shape = next; arrange(settings) }
        toggle.isOn = settings.enabled
        url.text = settings.url
        method.selection = settings.method
        for row in [headers, body, parameters, prompt] { row.refresh(settings) }
        send.title = testing ? "Sending…" : "Send Test"
        sendSpinner.isHidden = !testing
        // Now, and on the page's next pass: the form's state and the test's.
        enabled?.set(send, !testing)
        send.isEnabled = (enabled?.formEnabled ?? true) && !testing
        sendRow.invalidateIntrinsicContentSize(); sendRow.needsLayout = true
    }
    private func edit(_ change: (inout WebhookSettings) -> Void) { var settings = get(); change(&settings); set(settings) }

    private func arrange(_ settings: WebhookSettings) {
        // The rows the controls sat in are let go of first; the controls move to the new ones.
        for row in card.rows { if let row = row as? SettingsRow { row.control?.removeFromSuperview() } }
        var rows: [NSView] = [SettingsRow(label: "Send a webhook when a chat finishes", detail: "Plain http:// works for local addresses; anything else needs https://.",
                                          last: !settings.enabled, control: toggle)]
        if settings.enabled {
            rows.append(SettingsRow(label: "Address", control: url))
            rows.append(SettingsRow(label: "Method", control: method))
            rows.append(headers)
            if settings.method == "POST" { rows.append(body) }
            rows.append(parameters)
            rows.append(prompt)
            if test != nil {
                rows.append(SettingsRow(label: "Try it", detail: "Sends the webhook as typed, before you save, filled from a sample chat. The parameters get sample words: no mini model is asked.",
                                        last: true, control: sendRow))
                if !testResult.isEmpty {
                    let note = PiKit.Note(testResult, tone: testTone)
                    identify(note, "settings-webhook-test-result")
                    rows.append(InsetView(note, insets: NSEdgeInsets(top: 0, left: PiSpacing.lg, bottom: 10, right: PiSpacing.lg)))
                }
            }
        }
        card.setRows(rows)
    }

    /// A labelled multi-line field in the group, as wide as the group.
    private func editorRow(_ label: String, detail: String?, height: CGFloat, last: Bool = false,
                           get read: @escaping (WebhookSettings) -> String, set write: @escaping (inout WebhookSettings, String) -> Void) -> WebhookEditorRow {
        let row = WebhookEditorRow(label: label, detail: detail, height: height, last: last)
        row.editor.text = read(get())
        row.editor.onChange = { [weak self] text in self?.edit { write(&$0, text) } }
        row.read = read
        return row
    }

    private func run(_ test: (WebhookSettings) async throws -> Int) async {
        guard !testing else { return }
        testing = true; testResult = ""; update()
        defer { testing = false; update() }
        let settings = get()
        do {
            let status = try await test(settings)
            testResult = "Sent. \(WebhookRequest.address(settings.url, values: [:])?.host ?? "The address") answered HTTP \(status)."; testTone = .success
        } catch {
            testResult = "Not sent: " + error.localizedDescription; testTone = .danger
        }
    }
}

/// A labelled multi-line field in a settings group, as wide as the group:
/// the label, a quieter detail, the editor on a sunken inset, 6 apart, inside
/// 16 by 10 points, and a hairline under it unless it is the last.
@MainActor final class WebhookEditorRow: NSView, PiKit.WidthSizing {
    private let label: PiKit.TextLine
    private let detail: TextBlock?
    let editor: CodeEditorView
    /// What the row shows of the settings.
    var read: ((WebhookSettings) -> String)?
    func refresh(_ settings: WebhookSettings) { if let read { editor.text = read(settings) } }
    private let box: PiKit.Box
    private let editorHeight: CGFloat
    private let rule: HairlineView?
    init(label: String, detail: String?, height: CGFloat, last: Bool) {
        self.label = PiKit.TextLine(PiKit.Line(label, font: PiKit.Font.body, color: .piInk))
        self.detail = detail.map { TextBlock($0, font: PiKit.Font.caption, color: .piInkSecondary) }
        editor = CodeEditorView(accessibilityLabel: label)
        box = PiKit.inset(editor, sunken: true)
        editorHeight = height
        rule = last ? nil : HairlineView()
        super.init(frame: .zero)
        for view in [self.label, self.detail, box, rule].compactMap({ $0 }) as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    private func inner(_ width: CGFloat) -> CGFloat { max(0, width - PiSpacing.lg * 2) }
    func height(forWidth width: CGFloat) -> CGFloat {
        var height = 10 + label.intrinsicContentSize.height + 6
        if let detail { height += detail.height(forWidth: inner(width)) + 6 }
        return height + editorHeight + 10 + (rule == nil ? 0 : 1)
    }
    override func layout() {
        super.layout()
        let width = inner(bounds.width)
        var y: CGFloat = 10
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: PiSpacing.lg, y: y, width: min(size.width, width), height: size.height); y += size.height + 6
        if let detail {
            let height = detail.height(forWidth: width)
            detail.frame = CGRect(x: PiSpacing.lg, y: y, width: width, height: height); y += height + 6
        }
        box.frame = CGRect(x: PiSpacing.lg, y: y, width: width, height: editorHeight); y += editorHeight + 10
        rule?.frame = CGRect(x: PiSpacing.lg, y: y, width: bounds.width - PiSpacing.lg, height: 1)
    }
}
