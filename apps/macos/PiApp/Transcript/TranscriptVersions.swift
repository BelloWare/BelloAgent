import AppKit
final class VersionSwitcherMarkerView: NSView {
    var messageID = ""
    var mark: MessageVersionMark?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
final class VersionBannerMarkerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A reply's right-click commands, built when the menu opens.
enum ReplyMenu {
    /// "Fork from Here" is offered on a finished reply of a chat that can fork.
    static func forks(_ message: TranscriptMessage, enabled: Bool) -> Bool {
        enabled && message.role == "assistant" && message.kind == nil && !message.isStreaming && !message.isSending
            && message.stopReason != "interrupted"
    }
    /// `source` is the row's switch between the reply rendered and its
    /// markdown source, where the row offers one (`ReplySource.offered`).
    @MainActor static func entries(_ message: TranscriptMessage, actions: TranscriptActions, forks: Bool, fold: (title: String, perform: () -> Void)? = nil,
                                   source: ReplySourceToggle? = nil) -> [PiMenuEntry] {
        var entries: [PiMenuEntry] = []
        if let fold { entries.append(.button(fold.title) { fold.perform() }); entries.append(.divider) }
        entries.append(.button("Copy Reply", identifier: "reply-copy") { actions.copyMessage(message.id) })
        if let source {
            entries.append(.button(ReplySource.menuTitle(raw: source.raw), identifier: ReplySource.menuIdentifier,
                                   help: source.raw ? "Show this reply rendered again" : "Show this reply's Markdown exactly as it arrived") { source.toggle() })
        }
        entries.append(.button("Request Details", identifier: "reply-details") { actions.inspect(message.id) })
        if Self.forks(message, enabled: forks), let fork = actions.fork {
            entries.append(.divider)
            entries.append(.button("Fork from Here", systemImage: "arrow.triangle.branch", identifier: "reply-fork",
                                   help: "A new chat that ends at this reply") { fork(message.id) })
        }
        return entries
    }
}
