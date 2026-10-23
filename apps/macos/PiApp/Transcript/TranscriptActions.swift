import AppKit

/// What a row can ask the pane to do.
struct TranscriptActions {
    var inspect: (String) -> Void = { _ in }
    var edit: (String) -> Void = { _ in }
    var copyMessage: (String) -> Void = { _ in }
    var stop: () -> Void = {}
    /// Runs the failed turn again from where it stopped.
    var retry: () -> Void = {}
    /// Goes on with a run that stopped before it finished (`run.continue`).
    var resume: () -> Void = {}
    /// Nil for panes that cannot create a child conversation. Rows never
    /// call it; the page's selection controller does (`forwarding`).
    var quoteReply: ((TranscriptQuote) -> Void)? {
        get { inputActions?.quote }
        set {
            let image = inputActions?.image
            inputActions = newValue == nil && image == nil ? nil : InputActions(quote: newValue, image: image)
        }
    }
    /// The turn report's info button: the Session Inspector at that turn.
    var inspectTurn: ((TurnSummary) -> Void)? = nil
    /// A skill pill in a sent message (the message's id, the skill, the pill)
    /// was pressed; nil where no popover can open.
    var skillPressed: ((String, TranscriptSkillUse, NSView) -> Void)? = nil
    /// The pointer entered or left a sent message's skill pill.
    var skillHovered: ((String, TranscriptSkillUse, NSView, Bool) -> Void)? = nil
    /// The cost-limit notice: raise the limit (the editor opens over the
    /// button it passes), or continue a run stopped there.
    var costLimit: ((CostLimitNoticeAction, NSView?) -> Void)? = nil
    /// "Fork from here" on a reply: a new chat that ends at it. The rows
    /// offer it where the pane's `transcriptForks` says the chat can fork.
    var fork: ((String) -> Void)? = nil
    /// An edited message's switcher: the version this many steps away (‹ −1, › +1).
    var switchVersion: ((String, Int) -> Void)? = nil
    /// The earlier-version banner's Back to latest.
    var latestVersion: (() -> Void)? = nil
    /// A file tool's path: the file opens in a tab, at the lines (from 1)
    /// read or changed. Nil where files cannot be opened.
    var openFile: ((String, ClosedRange<Int>?) -> Void)? = nil
    var resolveReplyFile: (@MainActor (String) async -> ReplyFileLocation?)? = nil
    var openSubagent: ((SubagentTarget) -> Void)? = nil
    var inspectSubagent: ((SubagentTarget) -> Void)? = nil
    var stopSubagent: ((SubagentTarget) -> Void)? = nil
    var openAgentSource: ((AgentMessageReference) -> Void)? = nil
    var loadImage: (@MainActor (TranscriptMessage, Int, Int) async throws -> TranscriptImageBitmap)? {
        get { inputActions?.image }
        set {
            let quote = inputActions?.quote
            inputActions = quote == nil && newValue == nil ? nil : InputActions(quote: quote, image: newValue)
        }
    }
    /// Rows never quote; only image rows need the image callback. Sharing
    /// this slot keeps every plain row's actions within their old size.
    private var inputActions: InputActions?
    private final class InputActions {
        let quote: ((TranscriptQuote) -> Void)?
        let image: (@MainActor (TranscriptMessage, Int, Int) async throws -> TranscriptImageBitmap)?
        init(quote: ((TranscriptQuote) -> Void)?, image: (@MainActor (TranscriptMessage, Int, Int) async throws -> TranscriptImageBitmap)?) {
            self.quote = quote; self.image = image
        }
    }
    init(inspect: @escaping (String) -> Void = { _ in }, edit: @escaping (String) -> Void = { _ in },
         copyMessage: @escaping (String) -> Void = { _ in }, stop: @escaping () -> Void = {}, retry: @escaping () -> Void = {}, resume: @escaping () -> Void = {},
         quoteReply: ((TranscriptQuote) -> Void)? = nil, inspectTurn: ((TurnSummary) -> Void)? = nil,
         skillPressed: ((String, TranscriptSkillUse, NSView) -> Void)? = nil, skillHovered: ((String, TranscriptSkillUse, NSView, Bool) -> Void)? = nil,
         costLimit: ((CostLimitNoticeAction, NSView?) -> Void)? = nil, fork: ((String) -> Void)? = nil,
         switchVersion: ((String, Int) -> Void)? = nil, latestVersion: (() -> Void)? = nil, openFile: ((String, ClosedRange<Int>?) -> Void)? = nil,
         resolveReplyFile: (@MainActor (String) async -> ReplyFileLocation?)? = nil, openSubagent: ((SubagentTarget) -> Void)? = nil,
         inspectSubagent: ((SubagentTarget) -> Void)? = nil, stopSubagent: ((SubagentTarget) -> Void)? = nil, openAgentSource: ((AgentMessageReference) -> Void)? = nil,
         loadImage: (@MainActor (TranscriptMessage, Int, Int) async throws -> TranscriptImageBitmap)? = nil) {
        self.inspect = inspect; self.edit = edit; self.copyMessage = copyMessage; self.stop = stop; self.retry = retry; self.resume = resume
        self.inspectTurn = inspectTurn; self.skillPressed = skillPressed; self.skillHovered = skillHovered; self.costLimit = costLimit; self.fork = fork
        self.switchVersion = switchVersion; self.latestVersion = latestVersion; self.openFile = openFile; self.resolveReplyFile = resolveReplyFile
        self.openSubagent = openSubagent; self.inspectSubagent = inspectSubagent; self.stopSubagent = stopSubagent; self.openAgentSource = openAgentSource
        if quoteReply != nil || loadImage != nil { inputActions = InputActions(quote: quoteReply, image: loadImage) }
    }
    /// Which of the optional actions are offered. A pane makes its actions
    /// afresh each time it is drawn, and every one of them reaches the chat
    /// through the model and the session it was made for; what can differ
    /// between two sets made for the same session is only which are offered.
    var offered: [Bool] {
        [quoteReply != nil, inspectTurn != nil, skillPressed != nil, skillHovered != nil, costLimit != nil,
         fork != nil, switchVersion != nil, latestVersion != nil, openFile != nil, resolveReplyFile != nil, openSubagent != nil, inspectSubagent != nil, stopSubagent != nil, openAgentSource != nil, loadImage != nil]
    }
}

extension TranscriptActions {
    /// Actions that each call whatever `source` holds when they run. A row
    /// is handed these once and keeps them, so the pane can hand it newer
    /// actions without its SwiftUI tree being built again: the document's
    /// relay forwards to the pane's actions (`TranscriptActionRelay`), and
    /// each row's tree forwards to what the row was last handed.
    ///
    /// The selection controller takes `quoteReply` from the pane's own
    /// actions. Image rows opt into their image callback; plain rows keep
    /// none. The other optional actions are forwarded even where the source
    /// has none, and then do nothing: a row offers them from its message and
    /// environment (`transcriptForks`), rather than which are nil.
    ///
    /// An action added to `TranscriptActions` must be forwarded here too, or
    /// a row's calls to it go nowhere (`TranscriptActionsForwardingTests`).
    @MainActor static func forwarding(images: Bool = true, to source: @escaping @MainActor () -> TranscriptActions?) -> TranscriptActions {
        var actions = TranscriptActions(
            inspect: { source()?.inspect($0) },
            edit: { source()?.edit($0) },
            copyMessage: { source()?.copyMessage($0) },
            stop: { source()?.stop() },
            retry: { source()?.retry() },
            resume: { source()?.resume() },
            inspectTurn: { source()?.inspectTurn?($0) },
            skillPressed: { source()?.skillPressed?($0, $1, $2) },
            skillHovered: { source()?.skillHovered?($0, $1, $2, $3) },
            costLimit: { source()?.costLimit?($0, $1) },
            fork: { source()?.fork?($0) },
            switchVersion: { source()?.switchVersion?($0, $1) },
            latestVersion: { source()?.latestVersion?() },
            openFile: { source()?.openFile?($0, $1) },
            resolveReplyFile: { await source()?.resolveReplyFile?($0) },
            openSubagent: { source()?.openSubagent?($0) },
            inspectSubagent: { source()?.inspectSubagent?($0) },
            stopSubagent: { source()?.stopSubagent?($0) },
            openAgentSource: { source()?.openAgentSource?($0) }
        )
        if images {
            actions.loadImage = { message, index, pixels in
                guard let load = source()?.loadImage else { throw HostError.failure("This image is unavailable.") }
                return try await load(message, index, pixels)
            }
        }
        return actions
    }
}
