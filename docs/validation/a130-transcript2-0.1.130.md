# Transcript fixes, round 2, for 0.1.130

Workstream: `dev/a130-transcript2`, based on `f80e83cbb61866b6d222cc45e9b111aa96037d45` (`dev/next`).
Worktree: `/Users/admin/Library/Caches/BelloSwiftWork/wt-a130-transcript2`.
Build root: `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript2`;
text logs are in its `validation/` directory. All data is generated: journals are
written by the tests, workspace fixtures use isolated state and
`MemoryVaultStorage`, and no helper, provider, installed app, real chat, real
preference or Keychain item is used. No release, tag or `main`/`dev/next` write.
Every serial-lane, focus or gallery run held the shared full-lane lock for that
run only and released it on exit. Counts below are test methods.

Both reported traces were confirmed in code and by tests that fail on the base
commit (`failing-first.log`: 5 executed, 5 failed, 22 assertion failures).

## TRANSCRIPT-1 — confirmed and fixed

**Trace.** `NativeTranscriptPane.applyFind` restarted an open query only when
`disclosure.rawReplies` or `toolInputs.snapshot()` changed. A streamed token
changes `SessionDisplay.messages`; `publishTranscript` sends
`presentationChanges`, the page publishes a snapshot and the pane refreshes, but
neither Find input differs, so the completed search keeps its old results. The
row's text storage edit independently resets `TranscriptTextMatches` and the
row is marked again, which is why the new word is highlighted while the bar says
“No matches”. `TranscriptFindController.reconcile` only runs for a resolved
focus and needs an existing match for the message, so a zero-hit search has no
path back. The baseline test passed its “streamed word is marked” wait and then
timed out on the count, reproducing exactly that state.

**Fix.** The pane subscribes to its chat's `presentationChanges` (its rows and
its task presentation, which also moves while rows are appended beyond a browsed
window) and, while the find bar is open, tells the controller `contentChanged()`.
That only records the time (0.35 µs per change in Debug, below); no search
starts per token. The controller refreshes the query through the existing
`setQuery(_, restarting: true)` path once the conversation has been quiet for
0.5 s — or, while the chat runs, for four times as long as its last whole search
took, if that is longer. A pending refresh rechecks at least every 0.5 s, so a
run that stops is searched again promptly. In addition:

- A search under way is never cancelled for a content change; it finishes, and
  one refresh follows once quiet if rows changed meanwhile.
- A search retired for another reader's navigation is not restarted by content;
  `resumeReaderNavigation` searches the conversation as it is then.
- Typing a query, the raw/fetched-input restart, closing the bar and resuming
  all supersede a pending content refresh.
- A presentation re-sent unchanged (`WorkspaceHistory` does this once history
  positions arrive for an opened chat) also counts as a change; with the bar
  open that costs at most one extra refresh. Comparing inputs again in the sink
  would cost a full row comparison per token, which `publishTranscript` already
  pays once.
- The refresh path is unchanged: it keeps the chosen match by identity, never
  creates a navigation focus, never moves the reader and never touches the first
  responder. A zero-hit search that gains a match becomes “1 of 1” with
  Next/Previous enabled, and Next lands on it.

A continuous stream therefore causes no search until it settles, and a running
long chat that changes in bursts spends at most about a fifth of its run
searching again. A first version waited four times the last search even when
the chat was idle; the Debug probe below showed why that was wrong (a 2,000-turn
search takes 25 s in Debug, so the count would have lagged by minutes), and the
proportional wait now applies only while the chat runs.

**Regressions** (`TranscriptBugRegressionTests`):

- `testStreamedMatchRefreshesACompletedZeroHitFind` — the hunt's scenario in the
  real pane: zero-hit search, matching text streamed into the reply without
  changing disclosure or fetched inputs, stream finished; one match, “1 of 1”,
  both buttons enabled, no focus created, explicit Next focuses and highlights
  `zebra`. Baseline: `failed - Find counts the streamed word`.
- `testStreamingRepliesAreSearchedOnceTheySettle` — 12 deltas 250 ms apart
  (slower than the 150 ms typing pause, faster than the settle), then finish:
  all 13 occurrences counted with at most 3 searches, the current match and the
  focus serial unchanged. Baseline: `failed - The settled reply is counted`.
- `testChangingRowsWaitForTheSearchUnderWayAndForResume` — a held search is not
  cancelled by changes and one refresh follows; a retired search is not
  restarted by changes and resumes exactly once. Baseline: `failed - The search
  finishes, then one refresh follows`.
- `testStreamingRefreshKeepsTheReaderAndTheirChosenMatch` — the reader chose the
  second hit and scrolled 750 points away; a streamed third hit is counted
  (“2 of 3”) with the same focus, the same scroll origin and the same first
  responder. Baseline: `failed - The refresh counts the streamed needle`.
- `testARunningChatWaitsInProportionToItsLastSearch` — with a one-second
  search, five bursts 0.8 s apart while the chat runs cause no search; once the
  run stops, one search starts within 2 s. (Added with the run-state refinement,
  after the baseline run; the mutations below cover it.)

With the fix all six pass (`fixed.log`: 6 executed, 0 failures); the settled
stream test printed `FIND-STREAM deltas=12 searches-during=0 searches-total=1`.

**Mutations** (`mutations.sh` in the session scratchpad: each edit is applied to
the committed fix, the guarding tests run, and the file is restored with `git
checkout`, under one lock hold):

| Mutation | Log | Result |
|---|---|---|
| Pane forwards nothing, and the decoder ignores `nativeDisplayText` | `mutation-wiring-and-decoder.log` | 6 executed, 6 failed (24 assertion failures) |
| The naive fix: restart the query on every content change | `mutation-per-change.log` | 5 executed, 3 failed: `searches-during=12 searches-total=13`, `("2") is not equal to ("1") - Changes wait for the search under way`, `("6") is not equal to ("1") - Bursts 0.8 s apart …` |
| A content refresh no longer waits for a search under way | `mutation-preempt.log` | 5 executed, 1 failed: `Changes wait for the search under way` |
| Content changes restart a search retired for navigation | `mutation-retire.log` | 1 executed, 1 failed: `("4") is not equal to ("3") - A retired search is not restarted by changing rows` |
| No proportional wait while the chat runs | `mutation-no-proportional-wait.log` | 1 executed, 1 failed: 4 searches during the bursts instead of 1 |
| The proportional wait also once the run stops | `mutation-proportional-when-idle.log` | 1 executed, 1 failed: `("3.35…") is not less than ("2.0") - Once the run stops …` |
| No quiet period at all (still never over a search under way) | `mutation-no-settle.log` | 5 executed, 2 failed: `searches-during=12 searches-total=13`, `("5") is not equal to ("1") - Bursts 0.8 s apart …` |

Every mutation fails at least one regression, and each restored file matched
the commit (`git diff --quiet -- apps`) before the next step. The first
`no-settle` attempt did not compile (an `Int` literal); its rerun is the
result above.

**Measurements.** `TranscriptFindProbeTests.testProbeFindWhileALongReplyStreams`
(opt-in, `PI_LONG_PROBE=1`) opens a generated `LongChatScroll` journal in the
real conversation pane, opens ⌘F on `zebra` (absent), then streams a reply at
the live end: 300 deltas 30 ms apart, each presented at once (the page's 30 Hz
pacing off, so every delta's main-thread cost is measured), `zebra` arriving at
delta 150, then finishes it. Debug build on a shared machine (load averages
4–30 from other workstreams' builds). Baseline = `f80e83cb` product files with
the same probe.

| 400 turns (2,000 records, ~5 MiB) | Baseline (5 runs) | Fix (5 runs) |
|---|---|---|
| Searches while streaming | 0 | 0 |
| Searches after the stream | 0 | 1 (2.3–3.0 s) |
| Stream end → counted | never (30 s) | 2.9–3.6 s |
| Delta main thread, mean | 3.18, 3.32, 3.30, 3.30, 3.32 ms | 3.39, 3.41, 3.36, 3.33, 3.45 ms |
| Delta main thread, p95 | 4.49, 4.52, 4.52, 4.42, 4.52 ms | 4.66, 4.69, 4.61, 4.57, 5.01 ms |
| Delta main thread, max | 4.85, 5.31, 4.84, 5.10, 4.96 ms | 5.58, 8.62, 8.49, 4.98, 12.44 ms |
| CPU during the 10.7 s stream | 1,408–1,490 ms | 1,517–1,726 ms |

| 2,000 turns (10,000 records, ~28 MiB) | Baseline | Fix |
|---|---|---|
| Searches while streaming | 0 | 0 |
| Searches after the stream | 0 | 1 (three page calls, 22.4 s) |
| Stream end → counted | never (30 s) | 23.0 s |
| Delta main thread, mean / p95 / max | 3.21 / 4.43 / 7.66 ms | 3.31 / 4.65 / 5.03 ms |
| CPU during the stream | 1,669 ms | 1,746 ms |

Logs: `probe-before-{400,2000}.log`, `probe-after-{400,2000}.log`, and the
interleaved pairs `probe-ab{1,2}-{before,after}-400.log` (baseline first) and
`probe-ab{3,4}-{after,before}-400.log` (fix first). The fix adds no search while
a reply streams and exactly one whole search once it settles — the same search
⌘F runs when the query is typed, and the cost of the count being right. The
per-delta differences (≈0.1 ms mean, single-delta maxima during load spikes) are
not the fix's own work: a throwaway microbenchmark of the new path (removed
afterwards, `sink-cost.log`) measured `contentChanged` at 0.39 µs, and a
`presentationChanges` emission at 0.59 µs with the pane's sink against 0.24 µs
without it — about 0.1 ms over the whole 300-delta stream. The first, typed
search is unchanged code (4.9–6.5 s at 400 turns and 25–27 s at 2,000 turns in
Debug, on both sides).

## TRANSCRIPT-2 — confirmed and fixed

**Trace.** For an image result the helper writes `content` with the image blocks
(no text block when the tool returned none) and records the card text as
`displayText`, persisted as `nativeDisplayText`
(`SessionTools`: `[image/png result, 3000 bytes]`, after any text); the live
card shows `displayText ?? text`. The app's `ToolResultRecord.of` read only
`content` text, so `HistoryReader.decodePage` installed an empty output (or the
text alone for text-and-image results) in the call's card and marked it
completed; `TaskTranscriptPlan` then counts the card as showing the result and
drops the receipt row, whose own projection did read `nativeDisplayText`. Find's
`searchIssuer` joins receipts through the same decoder and treats the receipt as
paired, so `image/png` had no hit. Baseline excerpt:

```text
XCTAssertEqual failed: ("") is not equal to ("[image/png result, 3000 bytes]") - image only: the reopened card shows what the live card did
XCTAssertEqual failed: ("Rendered chart") is not equal to ("Rendered chart
[image/png result, 3000 bytes]")
XCTAssertEqual failed: ("[]") is not equal to ("["result"]") - image only, presented=false
```

**Fix.** `ToolResultRecord.of` prefers `nativeDisplayText`, falling back to the
content text exactly as before — the helper's own `displayText ?? text`.

**Other app-side decoders of tool results:**

| Decoder | Used by | Reads | Result |
|---|---|---|---|
| `ToolResultRecord.of` | `decodePage` cards, Find issuer/receipt joins | content text only | fixed |
| `TranscriptMessage.project` | standalone receipt rows, saved Find text | `nativeDisplayText ?? text` | already right |
| `HistoryReader.projection(field: "text")` | message text paging, details | `nativeDisplayText ?? text` | already right |
| `ConversationContent.transcriptText(entry)` | Find over saved rows | via `project` | already right |
| `TranscriptMessage.page` / wire rows | live and helper-read pages | the helper's card `output` (`displayText ?? text`) | already right |
| `ConversationContent.text` → `RetainedConversation.message` | Copy Conversation, export, source search, row fingerprints | content blocks; an image is `[Image attachment omitted]` | unchanged on purpose |

The copy/export formatter has no gap: it never drops the result, it states the
omitted image. It is the formatter the helper shares
(`ChatMessage.retainedConversationText` also ignores `displayText`), and the
disk/live copy handoff verifies row fingerprints of exactly this text, so reading
display text on the app side alone would make saved and live copies disagree and
reject valid selections. Copy and Find therefore stay as documented: Find and
message text use what the transcript shows; Copy Conversation uses the shared
source text. The regression asserts the saved copy text is identical with and
without `nativeDisplayText`.

**Regression:** `testReopenedImageResultsKeepTheirRecordedDescription` reads
generated journals (assistant call plus receipt on one page) through the real
workspace, history reader, planner and pane for four receipts: image only and
text-and-image (both with `nativeDisplayText`), legacy text and legacy image only
(without). It checks the completed card's output, that the planner keeps one
card and no receipt row, the drawn card payload, history search with and without
captured rows (one occurrence, on the receipt), rendered Find through the pane
(focus and visible highlight inside the card), and the copy text. Legacy
receipts keep their content text (`""` for a legacy image alone, as the helper
reconstructs it).

Mutation: the decoder reading content text only again (in
`mutation-wiring-and-decoder.log`) fails this test with the baseline's
assertions (`("") is not equal to ("[image/png result, 3000 bytes]")`, no
`image/png` hit with or without captured rows).

**Gallery.** `TranscriptBugGalleryTests.testReopenedImageResultCardsGallery`
reads a generated journal (one reply calling an MCP-style tool twice: an image
alone, and text with an image) through `HistoryReader`, opens both cards and
puts Find's focus on the first `image/png`. `image-results-{light,dark,narrow}.png`
in `validation/gallery/` show each card's OUT section with the recorded
description (`[image/png result, 3000 bytes]`, and `Sales by month` above it),
the focused and the plain match marks, and clean wrapping at 360 points. Before
the fix these cards had no OUT section at all (`.io` drops an empty output).
TRANSCRIPT-1 changes no layout or strings: the bar's existing count text
updates, so it has no gallery scene.

## Commands and results

All runs used `PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript2`
and `scripts/test-macos.sh -parallel-testing-enabled NO`; serial-lane classes
ran apart from parallel-lane ones, and every serial, probe, mutation and gallery
run held the full-lane lock for that run.

```sh
# Failing first (base product files), then fixed; -only-testing of the new methods
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testStreamedMatchRefreshesACompletedZeroHitFind  # …and the other new methods

# Serial lane (serial-final.log)
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests -only-testing:PiAppTests/TranscriptFindTests \
  -only-testing:PiAppTests/TranscriptRevealTests -only-testing:PiAppTests/SubagentMarkdownTests \
  -only-testing:PiAppTests/SubagentReaderTests -only-testing:PiAppTests/WireContractTests \
  -only-testing:PiAppTests/ChatFileLinkTests -only-testing:PiAppTests/ResponseChronologyTests \
  -only-testing:PiAppTests/ContentSearchTests -only-testing:PiAppTests/TranscriptUpdateIsolationTests \
  -only-testing:PiAppTests/TranscriptFindProbeTests

# Gallery (gallery-final.log)
TEST_RUNNER_PI_TRANSCRIPT_BUG_GALLERY="$PI_BUILD_ROOT/validation/gallery" \
  scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugGalleryTests

# Parallel lane (parallel-final.log)
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/HistoryIndexFilesTests -only-testing:PiAppTests/HistoryReaderCheckpointTests \
  -only-testing:PiAppTests/HistoryReaderStateTailTests -only-testing:PiAppTests/LongJournalHistoryTests \
  -only-testing:PiAppTests/ConversationSearchPagingTests -only-testing:PiAppTests/TranscriptPagingTests \
  -only-testing:PiAppTests/SubagentTranscriptTests -only-testing:PiAppTests/WorkspaceLoadingTests \
  -only-testing:PiAppTests/NativeTranscriptTests -only-testing:PiAppTests/TranscriptNativePaneBehaviourTests \
  -only-testing:PiAppTests/TranscriptActivityTests

# Probe (probe-*.log), base and fix
TEST_RUNNER_PI_LONG_PROBE=1 TEST_RUNNER_PI_LONG_TURNS=400 scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptFindProbeTests/testProbeFindWhileALongReplyStreams   # and PI_LONG_TURNS=2000
```

| Run | Executed | Passed | Failed | Skipped |
|---|---:|---:|---:|---:|
| `failing-first.log` (base product files) | 5 | 0 | 5 | 0 |
| `fixed.log` (new methods) | 6 | 6 | 0 | 0 |
| `serial-final.log` | 276 | 273 | 0 | 3 |
| `gallery-final.log` | 8 | 8 | 0 | 0 |
| `parallel-final.log` | 82 | 81 | 0 | 1 |

Serial classes: `TranscriptBugRegressionTests` 122, `SubagentReaderTests` 57,
`SubagentMarkdownTests` 19, `ContentSearchTests` 17, `ResponseChronologyTests` 14,
`TranscriptFindTests` 11, `TranscriptRevealTests` 11, `WireContractTests` 10
(+1 skipped, `PI_PERF_WIRE`), `ChatFileLinkTests` 7,
`TranscriptUpdateIsolationTests` 5, `TranscriptFindProbeTests` 2 skipped
(`PI_LONG_PROBE`; run separately above). Parallel classes:
`TranscriptNativePaneBehaviourTests` 16, `WorkspaceLoadingTests` 13,
`SubagentTranscriptTests` 11, `TranscriptActivityTests` 11,
`HistoryReaderCheckpointTests` 7, `HistoryIndexFilesTests` 6 (+1 skipped,
`PI_PERF_HISTORY_JOURNAL`), `TranscriptPagingTests` 6, `NativeTranscriptTests` 5,
`HistoryReaderStateTailTests` 4, `ConversationSearchPagingTests` 1,
`LongJournalHistoryTests` 1. No unrelated failures. `ConversationCopyTests` was
not run: the copy formatter is unchanged (the regression above asserts it).
The comment above `contentChanged()` was reworded after these runs (no code
change; `swiftc -parse` checked).

No named result bundle was created; `scripts/test-macos.sh` keeps only its
newest unnamed bundle, deleted after the runs. One DerivedData root was used,
and no parallel clones were made (`-parallel-testing-enabled NO`).

## Not done / notes

- Release-configuration numbers were not taken (one DerivedData root, tight
  disk); the probe comparisons above are Debug against Debug.
- With Find open during a long agent run, a refresh after the run settles costs
  one whole search of the chat, as typing the query does; in Debug that is
  2–3 s at 400 turns and ~22 s at 2,000 turns. Making repeated searches of an
  unchanged journal prefix incremental would cut that further; it is outside
  this fix.

## Round 2 — review of 2f65aa99

A read-only review found two P2 issues in the automatic refresh. Both were
confirmed by tests that fail on 2f65aa99 (`r2-failing-first.log`: 5 executed,
5 failed, 12 assertion failures).

### Recounts took back other readers' marks

**Trace.** A refresh is `setQuery(_, restarting: true)`, whose
`publish(focus: false)` rebuilt the highlights from the query and carried over
only a focus Find had made (`fromFind`). A sidebar Full chats hit
(`SidebarSearchReveal.reveal` → `revealInTranscript`) installs a mark with
`fromFind == false`; opened off the page it reads a new window, which changes
what the chat presents, so the automatic recount 0.5 s later replaced the
highlights: the mark disappeared, and `focusPending` was cleared, cancelling a
landing still under way. Inspector, transcript and chat-link reveals install the
same kind of mark, and the View Raw / fetched-input restarts and
`resumeReaderNavigation` take the same path.

**Fix.** `publish` takes `keepingMarks`, which every refreshing call site passes
(start, pages, completion and failure of a recount). A recount keeps any focus
Find did not make, so the highlights stay equal: no new request, `focusPending`
untouched, the count still updates. A newly typed query and Next/Previous
behave as before (Find's own focus replaces the mark).

### Retiring a reader at rest left its refreshes running

**Trace.** `retireReaderNavigation` suspended work only when a search was
running (`needsResume`). `SubagentTab.didHide` → `renewNavigation` retires a
hidden child tab's Find with no search running, so a queued content refresh
survived, later changes queued more, and whole-journal searches ran for a tab
nobody sees (hidden tabs keep their panes).

**Fix.** Retiring a reader whose query is active (`retired`) cancels the queued
refresh and keeps only the fact that rows changed; changes while retired queue
nothing. `resumeReaderNavigation` — which `resumeVisibleReaders` calls for every
reader that shows again — clears it and runs one coalesced refresh (or, as
before, the full search a retirement interrupted). `clear()` resets it.

**Other hide paths checked:**

| Path | Before | Now |
|---|---|---|
| Main pane switching chats | `applyFind` closes the old chat's bar (`clear`) | unchanged, no gap |
| Child tab hidden behind another tab (`didHide`) | retired, but refreshes kept running | suspended until resumed |
| Child tab closed | `TabHost.close` unregisters the tab before `willClose`, so `renewNavigation` does not retire; a pane still alive kept searching | its transcript has left the window: the visibility gate below |
| Popped-out window: tab switch / close | the same `SubagentTab` paths | as above |
| Popped-out window minimized or ordered out | not retired | visibility gate |
| Reports page over the chats | a page change bumps `messageNavigationRevision`, retiring the chat's Find, but nothing resumes it until Chats returns; a queued refresh still ran | suspended until resumed; its scroll view is also hidden (`ConversationPageVisibilityView`), so the gate holds too |
| Side covered by a pane tab | not retired; its scroll view hidden | visibility gate |

The visibility gate: a queued refresh starts only while its transcript is in a
visible window and not hidden (`NativeTranscriptPane.showsTranscript`);
otherwise it waits, checking again every 0.5 s, and runs once when the
transcript shows again — one search for everything that arrived. Typed queries
and Next/Previous are not gated.

The reveal flow itself passes through retire/resume cycles (each advancing
navigation, including automatic history jumps, bumps the revision and resumes
the visible readers a turn later), so a change recorded while retired is
searched only because `resumeReaderNavigation` schedules it: removing that
step fails the sidebar regression as well as the hidden-tab one (below).

**Regressions:**

- `TranscriptRevealTests.testASidebarMatchKeepsItsMarkThroughFindsRecount` — the
  review's scenario through the real sidebar reveal: a zero-hit query, a Full
  chats hit 30 turns above the window opened with its excerpt mark, then a reply
  with the query lands in the journal past that page and the chat's
  presentation moves. After the recount the bar reads “1 of 1”, the focus is
  the sidebar's (same serial), still drawn on screen in the focus colour, and
  the mark stands where it did in the viewport. Base (`r2-failing-first-sidebar.log`):
  `("nil") is not equal to (…a30b…)`, `The mark stays drawn, on screen`, and its
  place gone. (A first version appended the reply to the browsed window
  itself, which the app never does; the window's history room then changed
  identically with and without the fix, so the test now writes the journal
  and compares the mark's place in the viewport, not the absolute origin.)
- `TranscriptBugRegressionTests.testFindRecountKeepsAnotherReadersPendingMark` —
  another reader's mark is installed and a recount starts before it lands: the
  mark and `focusPending` survive, the place lands, and Next is Find's focus
  again. Base: the mark is `nil` at once and never lands.
- `TranscriptBugRegressionTests.testACoveredTranscriptIsSearchedOnceItShowsAgain`
  — the transcript's scroll view hidden (as under the Reports page), then its
  window ordered out: 4 deltas each, zero searches while covered, exactly one
  after it shows again, 9 matches at the end. Base: `("1") is not equal to ("0")`
  and `("2") is not equal to ("1")`.
- `SubagentReaderTests.testAHiddenChildTabsFindIsSearchedOnceWhenShownAgain` —
  the review's scenario: a child tab's query finishes, another tab hides it,
  three needles stream into it; zero searches while hidden, exactly one after
  `activate`, 3 matches. Base: `("2") is not equal to ("1") - Nothing is searched
  for a hidden reader`.
- `SubagentReaderTests.testAClosedChildTabsFindSearchesNothingMore` — the real
  pane of a popped-out child tab, Find open, tab closed, rows arrive: no search.
  Base: `("2") is not equal to ("1")`.

**Mutations** (`r2-final.sh` in the session scratchpad, one lock hold; each
edit is restored with `git checkout HEAD` and checked with `git diff --quiet
HEAD -- apps` before the next step):

| Mutation | Log | Result (5 new tests) |
|---|---|---|
| A recount drops marks again (`keepingMarks` line removed) | `r2-mutation-keeping-marks.log` | 2 failed: the sidebar and pending-mark tests |
| Retiring a reader at rest no longer suspends it | `r2-mutation-retire-at-rest.log` | 1 failed: `("2") is not equal to ("1") - Nothing is searched for a hidden reader` |
| Resume no longer searches what changed while retired | `r2-mutation-resume-owed.log` | 2 failed: `Shown again, the child is searched once`, `Find never counted again` |
| No visibility gate | `r2-mutation-visibility.log` | 2 failed: covered transcript (`("1") is not equal to ("0")`, `("2") is not equal to ("1")`) and closed tab (`("2") is not equal to ("1")`) |

**Runs.** The same commands as above, with the new methods:

| Run | Executed | Passed | Failed | Skipped |
|---|---:|---:|---:|---:|
| `r2-failing-first.log` (new tests, 2f65aa99 product code) | 5 | 0 | 5 | 0 |
| `r2-failing-first-sidebar.log` (final sidebar test, 2f65aa99 controller) | 1 | 0 | 1 | 0 |
| `r2-fixed.log` (new tests and round-1 regressions, first sidebar version) | 11 | 10 | 1 | 0 |
| `r2-fixed-final.log` (new tests, final) | 5 | 5 | 0 | 0 |
| `r2-serial-final.log` | 281 | 278 | 0 | 3 |
| `r2-parallel-final.log` | 82 | 81 | 0 | 1 |

`r2-fixed.log`'s one failure is the first sidebar version's absolute-origin
check, which moved identically with and without the fix (see above); every
other method passed, including the six round-1 regressions. Serial classes:
`TranscriptBugRegressionTests` 124, `SubagentReaderTests` 59,
`SubagentMarkdownTests` 19, `ContentSearchTests` 17, `ResponseChronologyTests` 14,
`TranscriptRevealTests` 12, `TranscriptFindTests` 11, `WireContractTests` 10
(+1 `PI_PERF_WIRE` skip), `ChatFileLinkTests` 7, `TranscriptUpdateIsolationTests` 5,
`TranscriptFindProbeTests` 2 skipped (`PI_LONG_PROBE`). Parallel classes as in
round 1 (81 passed, `HistoryIndexFilesTests` +1 `PI_PERF_HISTORY_JOURNAL` skip).
No unrelated failures. Round 2 changes no layout or strings, so no gallery scene
was regenerated. The app and tests were compiled with `xcodebuild
build-for-testing` (same DerivedData) before each locked run.
