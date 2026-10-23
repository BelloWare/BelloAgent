import AppKit
import Combine

/// Settings → Chats & notifications → Chat briefs (`WorkspaceChatBriefs.swift`):
/// the switch, saved with the rest of Settings; what brief requests came to
/// today and over the last 30 days, from the request archive; and Write
/// Briefs for the chats without one, one at a time, with how far it got,
/// what it spent, and Stop.
@MainActor final class ChatBriefSettingsCard: NSView, PiKit.WidthSizing, PiKit.SizeObserver {
    static let footer = "A brief is kept with the app's list of chats: nothing is added to the chat, its history or what its model is sent. "
        + "A chat's text goes only to its own connection's mini model; a chat whose connection has none gets no brief. "
        + "Each request is listed under Background requests and counted in Usage."
    /// How long after a request ends its cost is read again: the archive
    /// records it a moment later.
    nonisolated static let settleDelay: Duration = .seconds(2)

    private let model: WorkspaceModel
    private let get: () -> ChatBriefSettings
    private let set: (ChatBriefSettings) -> Void
    private let enabled: EnabledState?
    private let card: SettingsCard
    private var shape: Shape?
    private struct Shape: Equatable {
        var today: String, month: String, todayNote: String?, monthNote: String?, detail: String, action: String, running: Bool, actionEnabled: Bool
    }
    private(set) var today = ChatBriefUsage()
    private(set) var month = ChatBriefUsage()
    /// What the current or last batch spent.
    private(set) var batchSpend = ChatBriefUsage()
    private var usageTask: Task<Void, Never>?
    private var watches: [AnyCancellable] = []

    private lazy var toggle: PiKit.Switch = {
        let toggle = PiKit.Switch(isOn: get().enabled) { [weak self] on in self?.edit { $0.enabled = on } }
        toggle.setAccessibilityLabel("Write chat briefs")
        toggle.setAccessibilityIdentifier("settings-chat-briefs")
        return toggle
    }()
    private lazy var todayText = Self.figure("settings-chat-briefs-today")
    private lazy var monthText = Self.figure("settings-chat-briefs-month")
    private(set) lazy var batchButton: PiKit.Button = {
        let button = PiKit.Button("Write Briefs", symbol: "text.magnifyingglass", style: .secondary, compact: true) { [weak self] in self?.pressBatch() }
        button.setAccessibilityIdentifier("settings-chat-briefs-batch")
        return button
    }()

    init(model: WorkspaceModel, get: @escaping () -> ChatBriefSettings, set: @escaping (ChatBriefSettings) -> Void, enabled: EnabledState? = nil) {
        self.model = model; self.get = get; self.set = set; self.enabled = enabled
        card = SettingsCard(title: "Chat briefs", footer: Self.footer)
        super.init(frame: .zero)
        addSubview(card)
        let briefs = model.chatBriefs
        // A brief written or a batch's step: the figures and the progress again.
        watches.append(briefs.$batch.removeDuplicates().dropFirst().sink { [weak self] _ in MainActor.assumeIsolated { self?.update(); self?.readUsage() } })
        watches.append(briefs.$writing.removeDuplicates().dropFirst().sink { [weak self] _ in MainActor.assumeIsolated { self?.readUsage() } })
        update()
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var isFlipped: Bool { true }
    func contentSizeChanged() { needsLayout = true; PiKit.sizeChanged(self) }
    func height(forWidth width: CGFloat) -> CGFloat { card.height(forWidth: width) }
    override func layout() { super.layout(); card.frame = bounds }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { readUsage() } else { usageTask?.cancel(); usageTask = nil }
    }

    private static func figure(_ identifier: String) -> PiKit.TextLine {
        let text = PiKit.TextLine(PiKit.Line("…", font: PiKit.Font.body, color: .piInkSecondary))
        text.setAccessibilityIdentifier(identifier)
        return text
    }
    private func edit(_ change: (inout ChatBriefSettings) -> Void) { var settings = get(); change(&settings); set(settings) }

    // MARK: What it shows

    /// What the chats-without-a-brief row says, and its button.
    var batchDetail: String { shapeNow.detail }
    private var shapeNow: Shape {
        let briefs = model.chatBriefs
        // Written only while briefs are on as shown and as saved.
        let on = get().enabled, saved = model.briefSettings.enabled
        let waiting = on && saved ? briefs.chatsWithoutBrief().count : 0
        let chats = { (count: Int) in count == 1 ? "1 chat" : "\(count) chats" }
        var detail: String, action = waiting > 0 ? "Write Briefs for " + (waiting == 1 ? "1 Chat" : "\(waiting) Chats") : "Write Briefs"
        var actionEnabled = waiting > 0
        if let batch = briefs.batch, !batch.finished {
            detail = "\(batch.done) of \(chats(batch.total)) · \(batch.written) written"
                + (batch.failed > 0 ? " · \(batch.failed) failed" : "") + " · " + ChatBriefUsage.dollars(batchSpend.costUSD) + " so far"
            action = "Stop"; actionEnabled = true
        } else if !on {
            detail = "Chat briefs are off."
        } else if !saved {
            detail = "Save to turn chat briefs on, then write them here."
        } else if let batch = briefs.batch {
            detail = "Wrote \(batch.written == 1 ? "1 brief" : "\(batch.written) briefs") for \(chats(batch.total)) · " + ChatBriefUsage.dollars(batchSpend.costUSD)
                + (batch.failed > 0 ? " · \(batch.failed) failed" : "")
            if let stopped = batch.stopped { detail += ". " + stopped }
            if waiting > 0 { detail += waiting == 1 ? " 1 chat still has none." : " \(waiting) chats still have none." }
        } else if waiting > 0 {
            detail = "\(waiting == 1 ? "1 chat has" : "\(waiting) chats have") no brief yet. Each is asked for one in turn, newest first, on its own connection."
        } else {
            detail = "Every chat has a brief."
        }
        return Shape(today: today.label, month: month.label, todayNote: today.note, monthNote: month.note, detail: detail, action: action,
                     running: briefs.batchRunning, actionEnabled: actionEnabled)
    }

    /// Shows the setting and the figures as they are now.
    func update() {
        let next = shapeNow
        toggle.isOn = get().enabled
        guard next != shape else { applyEnabled(next); return }
        let rows = shape == nil || shape?.detail != next.detail || shape?.todayNote != next.todayNote || shape?.monthNote != next.monthNote
        shape = next
        todayText.line = PiKit.Line(next.today, font: PiKit.Font.body, color: .piInkSecondary)
        monthText.line = PiKit.Line(next.month, font: PiKit.Font.body, color: .piInkSecondary)
        batchButton.title = next.action
        batchButton.symbol = next.running ? "stop.circle" : "text.magnifyingglass"
        applyEnabled(next)
        if rows { arrange(next) }
        for view in [todayText, monthText, batchButton] as [NSView] { view.invalidateIntrinsicContentSize() }
        card.needsLayout = true; needsLayout = true
        PiKit.sizeChanged(card)
    }
    private func applyEnabled(_ shape: Shape) {
        // Now, and on the page's next pass: the form's state and the row's.
        enabled?.set(batchButton, shape.actionEnabled)
        batchButton.isEnabled = (enabled?.formEnabled ?? true) && shape.actionEnabled
    }
    private func arrange(_ shape: Shape) {
        // The rows the controls sat in are let go of first; the controls move to the new ones.
        for row in card.rows { if let row = row as? SettingsRow { row.control?.removeFromSuperview() } }
        card.setRows([
            SettingsRow(label: "Write chat briefs", detail: "At the end of every run, the chat's connection's mini model sums it up in a sentence or two, with a few keywords. "
                        + "Sidebar search finds chats by them, and resting the pointer on a chat shows them.", control: toggle),
            SettingsRow(label: "Brief requests today", detail: shape.todayNote, control: todayText),
            SettingsRow(label: "Brief requests in the last 30 days", detail: shape.monthNote, control: monthText),
            SettingsRow(label: "Chats without a brief", detail: shape.detail, last: true, control: batchButton),
        ])
    }

    private func pressBatch() {
        let briefs = model.chatBriefs
        if briefs.batchRunning { briefs.stopBatch() } else { batchSpend = ChatBriefUsage(); briefs.startBatch() }
        update()
    }

    /// The figures from the archive now, and once more when the last
    /// request's cost has had time to be recorded.
    private func readUsage() {
        usageTask?.cancel()
        usageTask = Task { [weak self] in
            for pass in 0..<2 {
                if pass > 0 { do { try await Task.sleep(for: Self.settleDelay) } catch { return } }
                guard let self, !Task.isCancelled else { return }
                let now = Date()
                let today = await self.model.briefUsage(since: Calendar.current.startOfDay(for: now))
                let month = await self.model.briefUsage(since: now.addingTimeInterval(-30 * 86_400))
                var spent = ChatBriefUsage()
                if let batch = self.model.chatBriefs.batch { spent = await self.model.briefUsage(since: batch.startedAt, for: Set(batch.chats)) }
                guard !Task.isCancelled else { return }
                self.today = today; self.month = month; self.batchSpend = spent
                self.update()
            }
        }
    }
}
