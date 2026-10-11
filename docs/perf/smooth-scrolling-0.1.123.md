# Smooth scrolling in long chats, and Find deep in history (0.1.123)

The owner, on scrolling a long chat: "it's like loading a bounded area,
which doesn't feel smooth if I want to scroll all the way down because it
just keeps loading." This record covers what was wrong, the design that
replaces it, and the numbers before and after.

All numbers are Release build-for-testing runs on the owner's VM (macOS
14.8, Apple Silicon, 10 vCPU), synthetic journals only
(`LongChatScroll.journal`: questions, two tool calls with output, long
Markdown replies with code; five rows a turn). Baseline is `dev/next` at
`18750a9b`; the change is `dev/smooth-scroll`. Both were run from the same
probe sources. One-minute load was 4–8 (other agents were building).

## What was wrong

- **The scroller was the window's, not the chat's.** The transcript holds a
  bounded window of the chat (`TranscriptPaging`, at most 500 rows / 4 MB)
  read three turns at a time, and the document was exactly the rows it
  held. The knob's size and place described that window: it shrank and
  jumped every time a page landed (34 resizes over 5% scrolling up a
  400-turn chat), dragging it to the middle showed a turn near the end,
  and dragging it to the top only reached the top of the rows read so far.
- **Reaching the start meant waiting for every page in between.** Holding
  the knob at the top of a 400-turn chat read 119 pages over 14 s, with 355
  frames stalled at the edge; a 2,000-turn chat had only reached turn 755
  after a minute.
- **Find spent nearly all its time in Swift's `range(of:)`.** Typing a query
  whose only match is half way up a 400-turn chat took 1.17 s to the mark;
  920 ms of it was the search, and a `sample` put 81% of that in
  `StringProtocol.range(of:options:)` with `.caseInsensitive`, which steps
  through each record's text a `Character` at a time. Decoding the records
  was most of the rest; the reveal's read was 10 ms.

## The design: the whole chat is one document

- **History pages say where they stand.** The journal reader returns the
  page's `start` among the timeline's `total` rows (it already returned
  `total`); the helper's `session.history` already sent `start`/`total`.
  `ConversationHistoryPage` keeps both.
- **The display knows where its window is** (`HistoryPositions`, one per
  chat display, never saved): the positions of the rows the pages named,
  and the total. Rows a run adds take their places from the window, so it
  stays placed after every row a page named has left it.
- **The document keeps room for the rest** (`TranscriptNativeDocument`):
  above the first row, the rows before the window; below the last, the
  rows after it — each at this chat's average row height, measured from the
  rows laid out (when the chat opens, then each time the window holds twice
  the rows it was measured over, never while the reader is moving). The
  scroller is therefore the whole chat's from the moment it opens. A chat
  too long for 8 M points of room keeps its proportions in less (layer
  positions are single precision past the app).
- **Pages land in the room they stood in.** A page read at an edge takes the
  place of its rows' room; the reader's line is held exactly as before
  (`TranscriptReadingCoordinator`), and when the room above the reader
  changes size the clip moves with it in the same pass, before anything is
  mounted or drawn where they were. Reads ahead are measured from the
  window's rows, not the document's ends.
- **Landing in room reads the page there.** Where the reader is in room no
  edge read can reach — a drag of the knob, a fling past the window — the
  page that starts at that row is read (`readConversationWindow(position:)`;
  the journal reader and the helper both take a position) and replaces the
  window where the room put it, so the reader stays where they are and the
  rows appear around them. One such read runs at a time and the newest wish
  is read next, so a drag ends on where the hand stopped. A reveal, Back to
  bottom, Latest, or the reader's return to the window's rows drops a read
  still under way.
- **A short window fills the screen.** Room above a window too short to fill
  the screen would show; such a window reads earlier rows until it does not,
  instead of offering "Load earlier messages".
- **The room is measured again only while the reader stands still.** A wheel
  AppKit is still applying lands on the old geometry; measured under it,
  the room's change was paid twice (the wheel probe's one jump of ~3,200 pt
  per run). The clip's move with the room also moves the place the reading
  anchor expects its line, so a movement of the reader's landing before the
  next correction does not pay it again.
- Home, End, ⌘↑/⌘↓, Find, reveal, folding, unread and following the newest
  reply work as before (their tests pass unchanged, apart from the two
  history-edge tests whose "top" and "bottom" are now the window's rows'
  and the short-page test above).

Find's search: a record whose text is ASCII alone and does not hold an ASCII
query is ruled out by a byte scan, which agrees with `range(of:)` exactly
over ASCII (case folding of ASCII is ASCII); every other record, and every
candidate, still goes through `range(of:)` (`ContentSearchTests` holds the
hits, order and counts to `range(of:)` over every record, Kelvin sign,
sharp s and emoji among them). Records are read in order and decoded a run
at a time on every core, a run bounded to 16 MiB.

## Numbers

### Dragging the scroller (400 turns, `testProbeScrollerDragAcrossTheChat`)

| Measure | Before | After |
|---|---|---|
| Document height on opening | 4,870 pt (the newest 15 rows) | 679,284 pt (the whole chat) |
| Knob dragged bottom → top over 3 s: where the reader ends | turn 382 of 400 | turn 5 (knob 0.015) |
| Knob dragged to the middle: where the reader ends | turn 390 | turn 193 |
| Rows on screen after the hand stops | 0 ms (the window's own rows) | 3 ms |
| Frames during a drag that showed room, not rows | 0 (it never left the window) | nearly all: the rows of a place come 3 ms after the hand stops there |

### Holding the knob at the top, then the bottom (`testProbeScrollerDragToTop`)

| Chat | Before | After |
|---|---|---|
| 400 turns, to the first message | 14.2 s, 119 pages, 355 stalled frames | immediate (one read, < 0.1 s) |
| 400 turns, back to the newest | 17.5 s, 100 pages | immediate |
| 2,000 turns, to the first message | not reached in 60 s (turn 755) | immediate |
| 2,000 turns, document height | 7.3k → 266k pt, 80 resizes over 5% | 5.06 M pt, none |

### Scrolling through (400 turns, 120 pt a frame; wheel 400 pt a frame)

| Measure | Before | After |
|---|---|---|
| Gesture up to the first message: time / pages / jumps | 147.2 s / 80 / 0 | 147.4 s / 68 / 0 |
| Gesture up: frame p95 / p99 / max | 32.2 / 57.4 / 125.1 ms | 32.0 / 61.0 / 138.1 ms |
| Gesture up: knob resizes over 5% | 34 | 0 |
| Gesture down to the newest: jumps / stalls | 0 / 0 | 0 / 0 |
| Wheel fling up: time / frame p95 / max | 53.9 s / 52.7 / 130.1 ms | 54.2–55.0 s / 52.9–54.4 / 137–145 ms (three runs) |
| Wheel fling up: jumps | 0 | 0 in three runs (one per run before the room's move was paid with the anchor, see below) |
| Home to the first message | 1 press | 1 press |

Frame times are unchanged within this machine's noise: the long frames are
still where a page lands or a long reply is first measured (see
`long-chat-scrolling.md`, "What remains").

### Find deep in history (400 turns, the only match half way up; `TranscriptFindProbeTests`, 5 runs)

| Measure | Before | After |
|---|---|---|
| Query typed → match marked on screen, p50 (min–max) | 1,171 (1,146–1,235) ms | 477 (456–490) ms |
| of which the search | 915–952 ms | 219–258 ms |
| of which the debounce | 150 ms | 150 ms |
| of which the reveal's read | 10–19 ms | 4–6 ms |

The Swift-vs-Rust record measured 528 ms for Swift and 260 ms for Rust on a
smaller chat (2.1 MB, no tool output) with a different harness; this
fixture is several times larger. What is left is the 150 ms the find bar
waits for typing to settle, decoding every record's JSON, and the landing.

## What remains

- **A drag shows room until the hand stops.** Each place's page arrives in
  tens of milliseconds, but a drag across a long chat moves faster than
  that, so the reader sees the room (the background) while dragging and the
  rows 3 ms after stopping. Showing rows during a fast drag needs the page
  read and laid out within a frame, or a cheap stand-in drawn in the room.
- **The average row height is an estimate.** It is measured from the rows
  read; where a chat's history is very unlike its newest turns, the knob's
  place drifts by the difference as pages land (the rows on screen never
  move). Sizes from the journal's record lengths would be closer.
- **Long frames where a page lands** are unchanged (see above).

## What to try by hand

Open a very long chat (hundreds of turns). Drag the scroller's knob slowly
from the bottom to the top and back; drag it to a quarter, the middle,
three quarters, and let go; flick the trackpad up hard; press Home and End
(⌘↑ / ⌘↓); ⌘F a word from early in the chat. The knob should stay the
same size, a place on it should be the same place in the chat, and the rows
should be there as soon as the hand stops.
