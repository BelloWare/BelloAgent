import AppKit

/// The rows of the chats a pane showed last, kept whole while the reader is
/// in another chat, so that coming back to one attaches its rows again
/// instead of building every row's tree anew. Building and laying out the
/// rows' SwiftUI trees was most of what a chat switch cost: about 140 ms of
/// the 160 ms it took to go back to a chat with a tool call and a long
/// answer (Release).
///
/// Kept rows are out of the view tree and nothing in them is live. A chat is
/// kept only when every row has settled — no reply arriving, no call
/// running, no live turn, nothing being sent — so no timer ticks, nothing
/// animates and nothing observes while its rows wait. A chat that is still
/// running is let go of as before and built again when the reader returns.
/// The rows are kept with the chat's own stores (what the reader opened in
/// them, the argument documents they fetched) and handed back only to those
/// same stores: a chat whose display was let go of and made again reads its
/// rows afresh. Kept rows hold no text selection; a chat comes back as a
/// revisit always has, with nothing selected.
///
/// A pane keeps the last `chatLimit` chats it showed, and lets go first of
/// the one the reader left longest ago. The workspace lets go of a chat's
/// rows as soon as its display goes, or it is archived or deleted
/// (`forgetEverywhere`).
@MainActor final class TranscriptKeptRows {
    struct Entry {
        let sessionID: String
        let rows: [TranscriptRowContainer]
        let disclosure: ObjectIdentifier?
        let toolInputs: ObjectIdentifier?
    }
    /// Three chats besides the one on screen: going back and forth between
    /// two or three chats is what a switch is for, and each kept chat holds
    /// about a screenful of row trees. The workspace keeps up to eight
    /// displays; rows are kept for fewer. A test sets it to 0 to measure the
    /// pane that keeps nothing.
    static var chatLimit = 3
    /// Least recently left first.
    private(set) var entries: [Entry] = []
    var sessionIDs: [String] { entries.map(\.sessionID) }
    var rowCount: Int { entries.reduce(0) { $0 + $1.rows.count } }

    init() { Self.keepers.append(WeakKeeper(self)) }

    /// Whether the workspace wants a chat's rows kept while the reader is
    /// away (`WorkspaceModel.keepsTranscriptRows`): not a chat that is
    /// archived, deleted or has no display.
    static var admits: @MainActor (String) -> Bool = { _ in true }

    /// Whether a chat's rows may wait out of sight: nothing on its page is
    /// arriving, running, being sent or live.
    static func keeps(_ snapshot: TranscriptPage.Snapshot, rows: [TranscriptRowContainer]) -> Bool {
        guard chatLimit > 0, !rows.isEmpty, snapshot.lifecycle?.active == nil, snapshot.liveTurn == nil, !snapshot.sending,
              admits(snapshot.sessionID) else { return false }
        return rows.allSatisfy { !$0.isInDisclosureMotion && settled($0.contentItem) }
    }
    static func settled(_ item: TranscriptItem) -> Bool {
        let running: Set<String> = ["running", "preparing", "prepared"]
        func quiet(_ message: TranscriptMessage) -> Bool {
            !message.isStreaming && !message.isSending && !(message.tools ?? []).contains { running.contains($0.state) }
        }
        switch item {
        case .message(let message): return quiet(message)
        case .block(let block):
            guard !block.live, block.turn?.live != true, block.taskSummary?.live != true, block.part?.state != "streaming" else { return false }
            return block.replies.allSatisfy { quiet($0) } && !block.tools.contains { running.contains($0.state) }
        }
    }

    /// Keeps a chat's rows, which have already left the view tree.
    func keep(_ rows: [TranscriptRowContainer], sessionID: String, disclosure: TranscriptDisclosure?, toolInputs: TranscriptToolInputs?) {
        entries.removeAll { $0.sessionID == sessionID }
        guard Self.chatLimit > 0 else { return }
        entries.append(Entry(sessionID: sessionID, rows: rows, disclosure: disclosure.map(ObjectIdentifier.init),
                             toolInputs: toolInputs.map(ObjectIdentifier.init)))
        while entries.count > Self.chatLimit { entries.removeFirst() }
    }

    /// The chat's kept rows, if it has any made with these same stores. They
    /// are no longer kept either way.
    func take(_ sessionID: String, disclosure: TranscriptDisclosure?, toolInputs: TranscriptToolInputs?) -> [TranscriptRowContainer]? {
        guard let index = entries.firstIndex(where: { $0.sessionID == sessionID }) else { return nil }
        let entry = entries.remove(at: index)
        guard entry.disclosure == disclosure.map(ObjectIdentifier.init), entry.toolInputs == toolInputs.map(ObjectIdentifier.init) else { return nil }
        return entry.rows
    }

    func forget(_ shouldForget: (Entry) -> Bool) { entries.removeAll(where: shouldForget) }

    // MARK: Every pane's

    private final class WeakKeeper { weak var keeper: TranscriptKeptRows?; init(_ keeper: TranscriptKeptRows) { self.keeper = keeper } }
    private static var keepers: [WeakKeeper] = []
    /// Lets go of kept rows in every pane: a chat whose display went or was
    /// made again, or that was archived or deleted, keeps nothing.
    static func forgetEverywhere(_ shouldForget: (Entry) -> Bool) {
        keepers.removeAll { $0.keeper == nil }
        for box in keepers { box.keeper?.forget(shouldForget) }
    }
    /// Every pane's kept chats, for checks that a chat keeps nothing.
    static var keptSessionIDs: [String] {
        keepers.compactMap(\.keeper).flatMap(\.sessionIDs)
    }
}
