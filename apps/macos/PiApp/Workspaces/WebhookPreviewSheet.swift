import AppKit

/// Chat ⋯ ▸ Preview Webhook…: the request this chat sends when it finishes,
/// made now from the chat as it is, the mini model's parameters included.
/// Send Now tries it against the address.
@MainActor final class WebhookPreviewSheetView: NSView, PiKit.SizeObserver, InheritsEnabled {
    static let size = NSSize(width: 640, height: 660)
    let model: WorkspaceModel
    let chatID: String
    private let dismiss: () -> Void
    private let scroll = NSScrollView()
    private let document = FlippedDocument()
    private let column = ShellStack(.vertical, spacing: PiSpacing.lg, padding: NSEdgeInsets(top: PiSpacing.xl, left: PiSpacing.xl, bottom: PiSpacing.xl, right: PiSpacing.xl))
    let close = PiKit.Button("Close", style: .secondary)
    let askAgain = PiKit.Button("Ask Again", symbol: "arrow.clockwise", style: .secondary, compact: true)
    let send = PiKit.Button("Send Now", style: .primary)
    private let sheet: PiKit.Sheet
    private let footer: SheetFooterRow
    private var preparation: WebhookPreparation?
    private var preparing = false
    private var sending = false
    private var showsPrompt = false
    private var notice = ""
    private var tone: PiTone = .neutral
    /// The mini model's request belongs to the sheet: closing it ends the request.
    private var requested: Task<Void, Never>?
    /// The window's disabled state, from the SwiftUI sheet around it.
    var inheritedEnabled = true { didSet { if oldValue != inheritedEnabled { rebuild() } } }
    /// The request's views, made once per preparation: the prompt's toggle
    /// keeps its place (and the keys) as it opens and closes the prompt.
    private var requestViews: [ShellItem] = []
    private var promptToggle: PiKit.Button?
    private var promptInset: NSView?
    private var observer: ShellObserver!
    private var watched: [String]?

    private var chat: ChatRecord? { model.chatRecord(chatID) }
    private var settings: WebhookSettings? { model.activeWebhook }

    init(model: WorkspaceModel, chatID: String, dismiss: @escaping () -> Void) {
        self.model = model; self.chatID = chatID; self.dismiss = dismiss
        footer = SheetFooterRow(leading: [askAgain], trailing: [send])
        scroll.drawsBackground = false; scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.documentView = document
        document.addSubview(column)
        sheet = PiKit.Sheet("Webhook preview", subtitle: model.chatRecord(chatID)?.title, symbol: "paperplane",
                            content: scroll, actions: [close], footer: footer)
        sheet.width = Self.size.width; sheet.height = Self.size.height
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        addSubview(sheet)
        close.onPress = { [weak self] in self?.dismiss() }
        sheet.dismiss = { [weak self] in self?.dismiss() }
        askAgain.toolTip = "Ask the mini model again and rebuild the request"
        askAgain.onPress = { [weak self] in
            guard let self else { return }
            self.requested?.cancel()
            self.requested = Task { [weak self] in await self?.prepare() }
        }
        send.toolTip = "Send this request to the webhook's address now"
        send.setAccessibilityIdentifier("webhook-preview-send")
        send.onPress = { [weak self] in Task { [weak self] in await self?.deliver() } }
        rebuild()
        requested = Task { [weak self] in await self?.prepare() }
        // The webhook turned on or off elsewhere (Settings), or this chat's own switch.
        watched = watchedState
        observer = ShellObserver { [weak self] in
            guard let self, self.watchedState != self.watched else { return }
            self.watched = self.watchedState; self.rebuild()
        }
        observer.observe(model)
    }
    private var watchedState: [String] { [settings == nil ? "off" : "on", chat?.webhookOff == true ? "chat-off" : "chat-on"] }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    deinit { requested?.cancel() }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { Self.size }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { requested?.cancel() } }
    func contentSizeChanged() { needsLayout = true }
    override func layout() {
        super.layout()
        sheet.frame = bounds
        sheet.layoutSubtreeIfNeeded()
        // The clip's own width: a legacy scroller takes its share of it, and
        // comes or goes with the column's height; settled in a pass or two.
        var width = scroll.contentSize.width
        for _ in 0..<3 {
            let height = column.height(forWidth: width)
            document.frame = CGRect(x: 0, y: 0, width: width, height: max(height, scroll.contentSize.height))
            column.frame = CGRect(x: 0, y: 0, width: width, height: height)
            scroll.tile()
            if scroll.contentSize.width == width { break }
            width = scroll.contentSize.width
        }
    }

    // MARK: What it shows

    private func rebuild() {
        var items: [ShellItem] = []
        if settings == nil {
            items.append(.view(ShellNote("The webhook is off. Turn it on in Settings → Chats & notifications.", tone: .warning), .fill))
        } else if chat?.webhookOff == true {
            items.append(.view(ShellNote("This chat sends no webhook when it finishes; its ⋯ menu turns it back on. Send Now still sends this one.", tone: .warning), .fill))
        }
        if preparing {
            let words = PiKit.TextLine(PiKit.Line("Asking the mini model…", font: PiKit.Font.caption, color: .piInkSecondary))
            items.append(.view(ShellStack(.horizontal, spacing: PiSpacing.sm, [.view(PiKit.spinner(controlSize: .small)), .view(words)]), .natural))
        }
        if preparation != nil { items += requestViews }
        if !notice.isEmpty { items.append(.view(ShellNote(notice, tone: tone), .fill)) }
        column.items = items
        let enabled = inheritedEnabled
        askAgain.isEnabled = !(preparing || sending || settings == nil) && enabled
        send.title = sending ? "Sending…" : "Send Now"
        send.isEnabled = !(preparation == nil || preparing || sending) && enabled
        close.isEnabled = !sending && enabled
        promptToggle?.isEnabled = enabled
        sheet.cancelDisabled = sending || !enabled
        footer.needsLayout = true
        needsLayout = true
    }

    private func mono(_ text: String, color: NSColor = .piInk, identifier: String? = nil) -> NSView {
        let view = ShellSelectableText(text, font: PiKit.Font.mono, color: color)
        if let identifier { view.setAccessibilityIdentifier(identifier) }
        return view
    }
    /// A titled part (`VStack(spacing: 8)`): its heading over its content in a sunken inset.
    private func section(_ title: String, _ content: NSView) -> ShellItem {
        let heading = PiKit.TextLine(PiKit.Line(title, font: PiKit.Font.micro, color: .piInkTertiary, tracking: 0.4, uppercased: true))
        let inset = PiKit.Box(fill: .piSurfaceSunken, stroke: .piHairline, cornerRadius: PiRadius.md,
                              padding: NSEdgeInsets(top: PiSpacing.md, left: PiSpacing.md, bottom: PiSpacing.md, right: PiSpacing.md), content: content)
        inset.clipsContent = true
        return .view(ShellStack(.vertical, spacing: PiSpacing.sm, [.view(heading, .natural), .view(inset, .fill)]), .fill)
    }

    private func request(_ preparation: WebhookPreparation) -> [ShellItem] {
        var items: [ShellItem] = []
        let request = preparation.request
        items.append(section("Request", mono(request.method + " " + request.url.absoluteString, identifier: "webhook-preview-address")))
        if !request.headers.isEmpty {
            items.append(section("Headers", ShellStack(.vertical, spacing: 4, request.headers.map { .view(mono($0.name + ": " + $0.value), .fill) })))
        }
        if request.body != nil { items.append(section("Body", mono(request.bodyText, identifier: "webhook-preview-body"))) }
        if !request.unknown.isEmpty {
            items.append(.view(ShellNote("Nothing fills " + request.unknown.map { "{{\($0)}}" }.joined(separator: ", ") + "; sent empty.", tone: .warning), .fill))
        }
        if !preparation.parameters.isEmpty {
            var rows: [ShellItem] = preparation.parameters.map { parameter in
                let name = ShellText(parameter.name, font: PiKit.Font.mono, color: .piInkSecondary)
                let value = ShellSelectableText(parameter.value.isEmpty ? "—" : parameter.value, font: PiKit.Font.caption, color: .piInk)
                return .view(ShellStack(.horizontal, spacing: PiSpacing.md, alignment: .firstBaseline,
                                        [.view(name, .fixed(120)), .view(value, .flexible), .spacer(0)]), .fill)
            }
            if let note = preparation.modelNote {
                rows.append(.view(ShellNote(note + " The chat's title stands in for title; other parameters are sent empty.", tone: .warning), .fill))
            } else if !preparation.missing.isEmpty {
                rows.append(.view(ShellNote("The mini model left out " + preparation.missing.joined(separator: ", ") + "; the chat's title stands in for title, and the rest are sent empty.", tone: .warning), .fill))
            }
            if let prompt = preparation.prompt {
                let toggle = PiKit.Button("", style: .ghost)
                toggle.onPress = { [weak self] in self?.togglePrompt() }
                rows.append(.view(toggle, .natural))
                let text = mono(prompt + (preparation.reply.map { "\n\n— Reply —\n" + $0 } ?? ""), color: .piInkSecondary)
                let inset = PiKit.Box(fill: .piSurfaceSunken, stroke: .piHairline, cornerRadius: PiRadius.md,
                                      padding: NSEdgeInsets(top: PiSpacing.md, left: PiSpacing.md, bottom: PiSpacing.md, right: PiSpacing.md), content: text)
                inset.clipsContent = true
                rows.append(.view(inset, .fill))
                promptToggle = toggle; promptInset = inset
                applyPrompt()
            }
            items.append(section(preparation.model.map { "Written by the mini model · " + $0 } ?? "Written by the mini model",
                                 ShellStack(.vertical, spacing: 6, rows)))
        }
        return items
    }

    /// The prompt shown or hidden in place, its toggle kept (`withAnimation(.quick)`).
    private func togglePrompt() {
        showsPrompt.toggle()
        applyPrompt()
        if showsPrompt, window != nil, let promptInset { PiKit.arrive(promptInset) }
        column.relayoutAll()
        needsLayout = true
    }
    private func applyPrompt() {
        promptToggle?.title = showsPrompt ? "Hide what the mini model was asked" : "Show what the mini model was asked"
        promptToggle?.symbol = showsPrompt ? "chevron.down" : "chevron.right"
        promptInset?.isHidden = !showsPrompt
    }

    // MARK: Asking and sending

    private func prepare() async {
        guard let settings, !preparing else { return }
        preparing = true; notice = ""; rebuild()
        defer { preparing = false; rebuild() }
        do {
            let made = try await model.prepareWebhook(for: chatID, settings: settings)
            preparation = made
            promptToggle = nil; promptInset = nil
            requestViews = request(made)
        }
        catch is CancellationError {}
        catch { notice = error.localizedDescription; tone = .danger }
    }
    private func deliver() async {
        guard let request = preparation?.request, !sending else { return }
        sending = true; notice = ""; rebuild()
        defer { sending = false; rebuild() }
        do {
            let status = try await model.deliverWebhook(request)
            notice = "Sent. \(request.url.host ?? "The address") answered HTTP \(status)."; tone = .success
        } catch {
            notice = "Not sent: " + error.localizedDescription; tone = .danger
        }
    }
}
