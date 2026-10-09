# Long-chat scrolling (0.1.122)

The owner reported that scrolling a very long chat felt bad: odd loading,
jumps, and no way to reach the start of the thread, which lost its place.
This record covers what DeepSeek Harness does, what was wrong here, what
changed, and the numbers before and after.

The numbers come from Release build-for-testing runs on the owner's VM
(macOS 14.8, Apple Silicon). `dev/next` at `5f93527e` is the baseline;
`dev/scroll` is the change. The baseline ran at a one-minute load of 4–10
(other agents were building); the change ran at 2–4.

## DeepSeek Harness (`@deepseek-ai/dsh`, MIT)

- **No virtualization.** Its web chat renders every loaded row.
- **Paged history.** A page is at least 50 messages and 2 turns (at most
  500), keyed by the first loaded event, and fetched with a manual
  "Load earlier" button. Nothing is evicted.
- **Anchoring.** Before a prepend it records the first row's key and its
  offset from the top. It re-applies that after every commit and every
  resize, until the reader scrolls.
- **Reaching an unloaded turn.** `loadThrough` reads 200-message pages
  until the turn is covered, then publishes them as one prepend.
- **Find.** It has no in-chat find of its own; the browser's find covers
  only the loaded pages.

Bello Agent keeps its virtualized native document, and paging under a
resident window (500 rows / 4 MB). It follows DSH where DSH applies:
- an anchor keyed by row that survives prepends and evictions;
- reading a target page directly instead of scrolling to it.

It adds prefetch in the direction of travel, as the owner asked.

## What was wrong (reproduced with `LongChatScrollProbeTests`, 200 turns)

1. **The reader's row jumped by a page.** In Release at baseline, it jumped
   18 times scrolling up and 28 times scrolling down, each by 6,000–8,500 pt.
   - The reading anchor was the text surface inside the reading row.
   - The pass that adds an earlier page pushed that row out of the view
     tree, and its surface went with it. `restore()` then found "source no
     longer retained", dropped the anchor, and corrected nothing.
   - Rows evicted above the reader on the way down failed the same way.
   - Fast flings also held nothing: the reading row was not mounted yet,
     and the top row of the window was replaced when its turn joined the
     page above it.
2. **Waiting at the edge.** Pages were requested 240 pt from the edge, so a
   400 pt/frame fling stalled 39–60 frames there in Release, and a gesture
   scrolling down stalled 32–39.
3. **No way to the start.** Home went to the top of the rows held: 34
   presses (29 s) to reach the first message of a 200-turn chat.
4. **Bottom-follow lagged a frame.** A page following its newest row
   re-landed a run-loop turn after rows above it re-measured, so one frame
   showed the rows pushed down.

## What changed

- `TranscriptReadingCoordinator`:
  - a text anchor keeps its row and falls back to it;
  - a correction still owed when the reader moves is paid first;
  - a row only a little of which shows gives way to the first row
    starting on screen;
  - a replaced row is found again by its messages, bottom-aligned;
  - an unmounted reading row is held by its place in the document.
- `TranscriptPage`:
  - reads three screenfuls (at least 2,400 pt) ahead, in the direction of
    travel only;
  - asks again after each page lands;
  - a page following its newest row stays pinned within the same pass.
- `loadHistoryPage(automatic:)`:
  - a page read ahead never lets go of rows on screen; its far end waits;
  - it does not pin the trailing reported anchor, and waits quietly
    instead of raising a selection error.
- Home and ⌘↑ read the chat's first page (whole index; helper
  `session.history` `edge: "start"`). End and ⌘↓ go to the latest.
- Cheaper passes and long replies:
  - rows post no frame or bounds notifications;
  - `rowFrame` does one dictionary update;
  - a reply's top inset no longer makes TextKit lay out the whole reply
    while it is built. A 51 KB forty-section reply now measures in 70 ms
    instead of 100 ms.
- `revealInTranscript`, ⌘F find and the sidebar adapter are described in
  `docs/transcript-reveal-api.md`; their tests are in
  `docs/Swift-Test-Handoff.md`.

## Long-chat probe (Release, two rounds each)

| Scenario | Measure | Before | After |
|---|---|---|---|
| Gesture up, 120 pt/frame, to the first message | jumps | 18 / 18 | 0 / 0 |
| | stall frames | 0 / 0 | 0 / 0 |
| | frame p95 / p99 / max (ms) | 37.4 / 63.3 / 185.3, 37.4 / 62.3 / 172.0 | 29.7 / 53.9 / 131.9, 30.1 / 54.8 / 125.0 |
| | frames over 50 ms | 66 of 2,742; 79 of 2,857 | 52 of 3,942; 57 of 3,942 |
| Gesture down, back to the newest | jumps | 28 / 28 | 0 / 0 |
| | stall frames | 39 / 32 | 0 / 0 |
| | frame p95 / p99 / max (ms) | 21.7 / 43.1 / 122.4, 21.7 / 42.9 / 156.6 | 20.7 / 38.8 / 119.4, 20.5 / 39.1 / 129.8 |
| Wheel fling up, 400 pt/frame | stall frames | 60 / 39 | 0 / 0 |
| | frame p95 / p99 / max (ms) | 58.7 / 82.5 / 164.1, 60.3 / 81.2 / 151.5 | 47.5 / 68.1 / 125.2, 47.7 / 80.8 / 118.1 |
| | frames over 50 ms | 73 of 784; 80 of 934 | 49 of 1,190; 51 of 1,188 |
| | wheel jumps | 0 / 0 (the jumps above were in gestures) | 0 in 3 runs after the final anchoring change |
| Scroller held at the top | time to the first message | 7.9 / 8.3 s | 6.0 / 6.1 s |
| Home | to the first message | 34 presses, 28.7 s | 1 press, 0.6 s |

The gesture run takes more frames after the change because it no longer
skips content by jumping ahead a page. Before the change, a fling or a
gesture down waited at the edge for each page.

## Transcript performance groups (`scripts/perf-transcript.sh`, two rounds)

| Measure | Before | After |
|---|---|---|
| Chat switch, main thread per switch, median (max) | 56.6 (72.9), 51.3 (83.0) ms | 50.5 (80.8), 53.1 (69.0) ms |
| Switch to another 300-row chat, cold, first paint | 33, 28 ms | 29, 28 ms |
| Switch back to a 300-row chat already read | 22, 21 ms | 16, 17 ms |
| Open 300 rows: first paint / fully settled | 40 / 706, 39 / 624 ms | 33 / 609, 35 / 611 ms |
| Streaming a 10 KB reply: main thread busy | 2.09, 2.02 s (17%) | 1.95, 1.91 s (16%) |
| Streaming delta into 300 rows, mean | 5.4, 5.2 ms | 5.2, 5.2 ms |
| Scrolling 300 rich rows p50 / p95 / p99 | 1.29 / 12.3 / 27.4, 1.24 / 10.9 / 24.5 ms | 1.19 / 9.3 / 23.2, 0.87 / 8.6 / 22.4 ms |
| Scrolling one 88 KB answer p50 / p95 / p99 | 0.16 / 0.35 / 0.57, 0.15 / 0.24 / 0.44 ms | 0.17 / 0.34 / 0.63, 0.18 / 0.32 / 0.88 ms |
| Scrolling 400 rows, 2,462 steps: mean / worst | 0.78 / 8.8, 0.81 / 7.3 ms | 0.78 / 9.2, 0.76 / 7.9 ms |
| Folding / unfolding a 60-tool turn | 8.9 / 5.3, 8.7 / 5.0 ms | 7.7 / 4.3, 8.6 / 4.8 ms |
| Typing per key, median / p90 / max | 1.9 / 2.3 / 10.6, 1.9 / 2.4 / 9.4 ms | 1.9 / 2.4 / 10.3, 1.9 / 2.2 / 10.4 ms |
| Begin editing the first of 300 rows | 43.8, 34.3 ms | 33.5, 37.5 ms |
| 122 s switch-aimed soak, answers over 100 / 150 / 200 ms | 3 / 0 / 0 in each of three | 1 / 0 / 0, 2 / 0 / 0, 1 / 0 / 0 |
| Soak, longest main-thread answer | 130, 120, 113 ms | 124, 127, 118 ms |
| Soak stalls over 250 ms; idle chat row jumps | 0; 0 | 0; 0 |

No measure got slower beyond run-to-run noise. The 88 KB answer's p99 moved
by a quarter of a millisecond, well within a frame.

## What remains

- **Long frames in Release.** About 1–4% of frames still take 50–130 ms:
  - a page of earlier rows landing: about 50 ms of publishing, updating and
    placing the page again;
  - the first build of a very long reply: a 51 KB, forty-section reply
    takes about 70 ms, about half of it TextKit laying out 800 lines, on the
    main thread.

  Removing this needs the text measured off the main thread, or
  incrementally. That is the next step and was not attempted here.
  `LongChatScrollTests` holds the frames to:
  - p95 ≤ 50 ms;
  - p99 ≤ 100 ms;
  - max ≤ 150 ms;
  - at most 5% of frames over 50 ms.
- **The wheel overshoot is fixed.** A 400 pt/frame fling used to move the
  reader's row back 6–77 pt in about half the Release runs. It had two
  causes:
  - a wheel step AppKit delivered between a geometry change and its
    correction dropped the correction;
  - a row reaching only a little into the screen from above was held by
    its unseen top while that part re-measured.

  Now `readerMoved` pays the owed correction first, and the first row
  starting on screen is held when less than a third of the covering row
  shows. Release afterwards: the fling passed 6 of 6, the 200-turn wheel
  and gesture probes had zero jumps in 3 runs each, and
  `LongChatScrollTests` passed twice with its budgets.
