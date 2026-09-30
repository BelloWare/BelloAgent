import AppKit

/// What a row can ask the pane to do.
struct TranscriptActions {
    var inspect: (String) -> Void = { _ in }
    var edit: (String) -> Void = { _ in }
    var copyMessage: (String) -> Void = { _ in }
    var stop: () -> Void = {}
    /// Runs the failed turn again from where it stopped.
    var retry: () -> Void = {}
    /// Nil for panes that cannot create a child conversation. Rows never
    /// call it; the page's selection controller does (`forwarding`).
    var quoteReply: ((TranscriptQuote) -> Void)? = nil
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
    /// Which of the optional actions are offered. A pane makes its actions
    /// afresh each time it is drawn, and every one of them reaches the chat
    /// through the model and the session it was made for; what can differ
    /// between two sets made for the same session is only which are offered.
    var offered: [Bool] {
        [quoteReply != nil, inspectTurn != nil, skillPressed != nil, skillHovered != nil, costLimit != nil,
         fork != nil, switchVersion != nil, latestVersion != nil, openFile != nil]
    }
}

extension TranscriptActions {
    /// Actions that each call whatever `source` holds when they run. A row
    /// is handed these once and keeps them, so the pane can hand it newer
    /// actions without its SwiftUI tree being built again: the document's
    /// relay forwards to the pane's actions (`TranscriptActionRelay`), and
    /// each row's tree forwards to what the row was last handed.
    ///
    /// Every action is forwarded but `quoteReply`, which the selection
    /// controller takes from the pane's own actions. An optional action is
    /// forwarded even where the source has none, and then does nothing: a
    /// row decides what it offers from its message and the environment
    /// (`transcriptForks`), never from which of these are nil.
    ///
    /// An action added to `TranscriptActions` must be forwarded here too, or
    /// a row's calls to it go nowhere (`TranscriptActionsForwardingTests`).
    @MainActor static func forwarding(to source: @escaping @MainActor () -> TranscriptActions?) -> TranscriptActions {
        TranscriptActions(
            inspect: { source()?.inspect($0) },
            edit: { source()?.edit($0) },
            copyMessage: { source()?.copyMessage($0) },
            stop: { source()?.stop() },
            retry: { source()?.retry() },
            inspectTurn: { source()?.inspectTurn?($0) },
            skillPressed: { source()?.skillPressed?($0, $1, $2) },
            skillHovered: { source()?.skillHovered?($0, $1, $2, $3) },
            costLimit: { source()?.costLimit?($0, $1) },
            fork: { source()?.fork?($0) },
            switchVersion: { source()?.switchVersion?($0, $1) },
            latestVersion: { source()?.latestVersion?() },
            openFile: { source()?.openFile?($0, $1) }
        )
    }
}
