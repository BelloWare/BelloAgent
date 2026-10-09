# Transcript reveal API (0.1.122)

Brings a message of a chat into view in its open transcript, marks a place in
it, and opens the finished turn that folded it away. Used by the ⌘F find bar,
Home (first message) and, for the sidebar search, `SidebarSearchReveal`.

Source: `apps/macos/PiApp/Workspaces/TranscriptReveal.swift`.

## Calls

```swift
// Message `messageID` of chat `sessionID`, landed 24 pt below the viewport top.
@discardableResult
func revealInTranscript(sessionID: String, messageID: String,
                        mark: TranscriptReveal.Mark? = nil,
                        fromFind: Bool = false) async -> Bool

// The chat's first message, at the very top (Home / ⌘↑).
@discardableResult
func revealStartOfChat(sessionID: String) async -> Bool
```

Both are `WorkspaceModel` methods on the main actor. They return `false` when
the chat or the page cannot be shown: the chat is gone, the read failed (the
error shows at the transcript's earlier edge, with Retry), the reveal was
superseded, or the chat is no longer the one shown.

### Marks

```swift
enum TranscriptReveal.Mark {
    case range(NSRange)                         // UTF-16 range of TranscriptMessage.text
    case excerpt(String, highlight: NSRange)    // a search result's one-line excerpt and the match in it
}
```

The transcript marks text as it is drawn, which is not always the message's
source text (Markdown is rendered), so a mark is resolved to a needle and its
occurrence:

- `.range`: the needle is the text in the range; the occurrence is the number
  of case-insensitive occurrences of it in the message before the range.
- `.excerpt`: the needle is the excerpt's highlighted text. It is resolved
  in the message's prose first, then in each tool's output, then in each
  tool's input. The first that holds the needle with the excerpt's
  surrounding words wins, and an output or input match is scoped to that
  call's card. Up to 24 characters each side are compared, after
  flattening whitespace and dropping the excerpt's "…". Whitespace in the
  needle matches any run of whitespace.
- On screen, the excerpt's surrounding words also pick the drawn
  occurrence. Each occurrence in every row of the message is scored by how
  much of that context agrees with it (letters and digits only). The best
  wins, once every row of the message has been looked at. The ordinal is
  the fallback. This is how JSON-argument context matches a drawn diff.

The needle's occurrences are counted in reading order across every row that
draws the message. A timeline response has several rows: header, parts and
answer. The marked occurrence gets a strong highlight (`piWarning`, 42 %
alpha) and is scrolled to a third of the way down the viewport, unless it is
already well inside it. When the drawn text does not show the needle (it is
inside a folded tool card), the message's row is shown without a mark.

## What happens

1. `view.reveal` is set: `TranscriptReveal(messageID:mark:serial:)`.
2. If the message is in the transcript's window, the page lands on it as an
   explicit destination (`scrollAnchor` + `viewportRequest`). Otherwise the
   page around the message is read (`readConversationWindow(around:)`, from
   the helper or the journal) and replaces the window in place, with no
   loading cover. The window then grows in both directions as the reader
   scrolls (prefetch).
3. The pane (`NativeTranscriptPane.applyFind`) waits until the page holds the
   message. It then opens the finished turn that folded it away
   (`TranscriptPage.unfoldTurn(containing:)`), resolves the mark and hands it
   to the document (`TranscriptHighlights.focus`).
4. Once the page has landed and the row is mounted, the document scrolls the
   mark into view and holds that row, so measuring around it does not move it
   (`revealFocusIfPending`). The page stops following the newest row.

The mark stays until the next find or reveal, or a switch to another chat. A
reveal without a mark clears the previous mark, unless the find bar made it
(`fromFind: true`), because the find bar marks its own match.

## Ordering and cancellation

- The newest request wins. Each reveal that has to read a page takes a serial
  (`view.revealRead`). A read is dropped if, before it lands, any of these
  happened: a newer reveal, a Home/End key, Back to bottom, `latest()`, any
  scroll of the reader's own, report navigation, or a switch to another
  chat. A read that fails sets `view.revealFailure`; the find bar then says
  "Couldn’t open match".
- Cancelling the calling `Task` also drops it: the read checks
  `Task.isCancelled` before adopting.
- The chat must be the selected one, or the side shown beside it. Select the
  chat first; a reveal into a chat nobody is showing does nothing.

## Sidebar search adapter (switched on dev/scroll)

`SidebarSearchReveal` in `Workspaces/SidebarSearch.swift` now calls this API.
It passes the hit's excerpt, so the match is marked:

```swift
static func reveal(_ model: WorkspaceModel, chatID: String, messageID: String,
                   mark: TranscriptReveal.Mark? = nil) async {
    if let override { await override(chatID, messageID); return }
    await model.revealInTranscript(sessionID: chatID, messageID: messageID, mark: mark)
}
// caller: SidebarSearchReveal.reveal(self, chatID: chatID, messageID: hit.messageID,
//                                    mark: .excerpt(hit.excerpt, highlight: hit.highlight))
```

The test seam (`override`) is unchanged. `ChatSearchHit.messageID` names the
row for a tool output: the reply whose card shows it. That reply is landed on.
Its card opens, and the excerpt is marked if the drawn text shows it.

## Tests

`LongChatScrollTests` (serial lane) covers Home to the first message and End
back to the latest. `TranscriptRevealTests` covers:

- revealing a loaded message, and an unloaded one from a 200-turn journal;
- an excerpt mark resolved to the right occurrence;
- the newest of two quick reveals winning;
- a match inside a folded finished turn unfolding it.

## Known limits

- A phrase split across separate lines of a card (each line is its own text,
  as a browser's find does not match across separate elements) is not
  matched there.
- Diff content too large for preview rows (behind "View full content") is
  not opened by a reveal.
- Find counts each occurrence as an entry. A query that occurs very many
  times (a single common letter) holds one entry per occurrence.
