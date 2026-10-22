# PERF-1: replies laid out once beside the session card — 0.1.131

Workstream `dev/a131-layout`, based on `dev/next` `a9f34673`.
Build root `/Users/admin/Library/Caches/BelloSwiftWork/build-a131-layout`; the
text logs below are in its `evidence/` directory, the soaks in `ab-base4/` and
`ab-new/` (with `load.log` traces). All chats are generated fixtures (workspace fixtures with
`MemoryVaultStorage`, the synthetic gateway for the soak); no installed app,
real chat, preference, Keychain item, provider or live capture is used. No
release, tag or `main`/`dev/next` write. The soaks, the serial-lane runs and the
gallery held the shared full-lane lock for the run only.

## Cause

The 0.1.130 soak profiles (`build-lead/ab-129`, `ab-130`, 120 s at 1 ms) put
TextKit layout (`_fillLayoutHoleForCharacterRange`, main thread) at 1,178 →
1,983 samples:

| Caller | 0.1.129 | 0.1.130 |
| --- | ---: | ---: |
| `TranscriptNativePartView.update` → `addSubview(reply)` | 1,165 | 1,094 |
| `NativeMarkdownContainer.measure` (`TranscriptNativeReplyRow.plan`) | 0 | 848 |
| other | 13 | 41 |

1. **A reply's words were laid out twice.** A new reply row's text view joins
   the page, AppKit marks every view of the joining tree for display
   (`-[NSView _setSuperview:]` → `_recursivelyInvalidateCachedContentStyle` →
   `-[NSTextView setNeedsDisplayInRect:avoidAdditionalLayout:NO]`), and a text
   view marked lays out what it would draw: its whole text, at the 840 pt its
   container starts at (`NativeMarkdownSurface.swift:89`), before it is in a
   window and while its frame is still zero. The row then measures the reply
   at the column's width, which changes the container's width and lays the
   text out again. In 0.1.129 the column in the soak's window was the full
   page width, so the measurement found the layout done; beside the card
   (`SessionPanelLayout.transcript(in:)`) it is about 620 pt. A standalone
   AppKit check reproduced it outside the app: adding a 43,000-character text
   view to a view not in any window laid out all of it at 840 pt; forcing
   `avoidAdditionalLayout` left it unlaid until measured, once, at 600 pt.
   The part path (a timeline reply's words) hits it on every build; a reply's
   own body row hits it when its tree is built as the row mounts (heights
   borrowed from the page's cache, or a row whose tree was let go).
2. **The card.** 578 main-thread samples in 0.1.130 against 3 in 0.1.129
   (outermost frames in the card's classes): switching chats discarded
   the card's Agents list (`scroll.documentView = nil; agents = nil`) and built
   a new `AgentFamilyPopoverView`, with its rows and two buttons (Stop All…,
   Inspect Family) it then dropped for a family without agents; every refresh
   set the folder menu's label, which redrew the pill and made its two
   symbol images anew (215 samples, `PiKit.Symbol.draw`), although the menu is
   hidden on the Agents tab — Core Animation still displays a hidden layer
   marked for display (checked standalone); `Tabs.items` was set on every
   refresh.

## Fix

- `MarkdownTextView.setNeedsDisplay(_:avoidAdditionalLayout:)` avoids layout
  unless the text view is in a window at its own width; drawing still lays out
  what it draws, and a laid-out view in a window behaves as before.
- `NativeMarkdownContainer.prepare(width:)` sizes a surface not yet placed from
  the width its row knows (`TranscriptRowInputs.width`), so whatever lays the
  text out first — the measurement, or the caret of a reply still arriving —
  does it there. `TranscriptNativeReplyRow` calls it before setting its text;
  timeline parts pass their row's width to their words
  (`TranscriptNativePartView.Model.width`).
- Evidence counters: `NativeMarkdownContainer.textLayouts`/`textLayoutWidth`
  (TextKit layout completed to the end, via the layout manager's delegate) and
  `TranscriptLayoutClock.markdownTextLayouts`.
- The card keeps its Agents list while it is on screen and the chat changes
  (`AgentFamilyPopoverView.show(sessionID:)`: focus in the list is let go and
  the list scrolls to its top, as a new list's did). A family that reads the
  same — no sides and no agents, only its owner differs — keeps its rows; New
  Side reads the owner when pressed. Stop All… and Inspect Family are built
  only for a family with agents. `Tabs.items` is set only when the tabs change.
- `PillFaceButton` (and `MenuButton`'s accessibility label and tooltip) skip a
  label, icon or width set to what the pill already shows.

Row heights are unchanged (the measurement is the same call at the same
width), as are selection, Find highlights (temporary attributes on laid-out
text in the window), streaming (a token's append path never lays out on
joining) and live resize (very long replies still defer their width).

## Tests

New: `NativeMarkdownSizingTests.testTextJoiningThePageIsLaidOutOnlyAtItsMeasuredWidth`,
`NativeMarkdownSizingTests.testAReplyIsLaidOutAtItsRowsWidthBeforeItIsPlaced`,
`SessionCardSwitchTests.testRepliesBesideTheCardAreLaidOutOnceAtTheColumnWidth`
(a `ConversationPaneView` with the card, 1,000 pt wide: three chats of three
turns, timeline replies and a reply's own row; opening, switching, coming back
with heights borrowed from the page's cache, and trees built again as rows
mount) and `SessionCardSwitchTests.testSwitchingChatsKeepsTheCardsRowsAndPills`.

**Failing first** (`failing-first.log`; `a9f34673` with only the counters):
8 executed, 4 failed, 31 assertions — every timeline reply laid out twice in
every step (also the body reply when its tree was built on mounting), the
caret laying a streaming reply out at 840 pt, joining a window laying text out,
the Agents list and its New Side row replaced on each of 4 switches, the hidden
folder menu drawn 6 times, and the row built for the first chat not opening a
side of the chat shown. With the fix (`fixed-new.log`): 8/8.

**Mutation checks** (`mutation-*.log`, each restored after):

| Broken | Failed |
| --- | --- |
| join guard (`setNeedsDisplay` passes the flag through) + pill guard | both sizing tests (layout on joining); card test (folder drawn 7 times) |
| `prepare(width:)` call + `readsTheSame` | caret test (840 pt, 2 layouts); card test (rows rebuilt) |
| both layout parts + New Side reading the owner when built | both sizing tests; column test (timeline replies laid out twice in every step); card test (no side of the chat shown) |
| list kept across switches | card test (list and rows replaced; no side of the chat shown) |

The column-width test fixes the transcript's scroller to the overlay style:
with legacy scrollers the first chat's column narrowed by 15 pt when its
scroller appeared, and every row was rightly laid out again at the new width.

## Validation

Debug, `PI_BUILD_ROOT=<build root> scripts/test-macos.sh -only-testing:PiAppTests/<Class>…`,
the new tests and the classes covering the changed code only (owner,
2026-10-22); no full lanes, helper or wire suites.

- **Parallel lane** (`affected-parallel.log`): `NativeMarkdownSizingTests`,
  `SessionCardSwitchTests`, `ConversationFamilyTests`, `SubagentPanelTests`,
  `SubagentEffortTests`, `TranscriptNativeRowBehaviourTests`,
  `TranscriptNativeRowParityTests`, `TranscriptTextCalibrationTests`,
  `ResponseTimelinePresentationTests`, `DraftConcurrencyTests`: **154 executed,
  12 skipped, 0 failed**.
- **Serial lane**, under the lock (`affected-serial.log`):
  `MarkdownTextSurfaceTests`, `NativeMarkdownSurfaceStreamingTests`,
  `NativeMarkdownViewportTests`, `StreamingMarkdownStabilityTests`,
  `TranscriptFindTests`, `TranscriptQuoteSelectionTests`, `StableReadingTests`,
  `TranscriptStreamingScrollTests`, `ChatOpenPlacementTests`,
  `LongChatScrollTests`, `TranscriptNativeTimelineBehaviourTests`,
  `TimelineStreamingFastPathTests`, `ReplySourceTests`, `SessionPanelTests`,
  `PiKitControlTests`, `PiKitParityTests`: **199 executed, 4 skipped, 0
  failed** — row heights, reading position, selection, Find and quoting,
  streaming, the reply's source view, the card and the pill faces.
- **Gallery** (`SessionPanelGalleryTests`, `TEST_RUNNER_PI_SESSION_PANEL_GALLERY`,
  `gallery-session-panel.log`): 1/1, 22 images; the card's Agents list with
  sides and agents (Stop All… and Inspect Family), the empty family (neither),
  Files, Diff and the narrow window's pill read as before in light and dark.

## Soak A/B

One 900 s run per version, seed 1790822043708, `PI_SOAK_SWITCHES=1`, every
main-thread answer over 50 ms recorded with its action, and a 120 s `sample`
(1 ms) of the test host from 760 s (the lead's `ab-soak.sh`; copies in the build
root profile the run's own test host and log the load every 10 s). Before: the
lead's Release build-for-testing of `66ddf9e3` (`build-lead/perf`, the product
code of `a9f34673`; used read-only through a copied `.xctestrun` with its own
test home). After: Release build-for-testing of `ebb2e952`. Answers by action
are the lead's `ab-analyze.py` (before 755 s, the profile window left out); the
profile figures are main-thread samples (`evidence/ab-report.txt`).

| | Before | After |
| --- | ---: | ---: |
| 1-minute load, start / max in run (10 s samples) | 2.89 / 3.74 | 2.39 / 2.87 |
| Main-thread busy, 120 s profile | 23.2 s | **21.6 s** (−7%) |
| TextKit layout samples | 2,079 | **1,081** (−48%) |
| — as a reply joins the page | 1,128 | **0** |
| — measuring at the column's width | 888 | 1,006 |
| Session card samples | 569 | **106** (−81%) |
| Answers over 50 / 75 / 100 / 150 ms | 619 / 244 / 24 / 1 | 556 / **59** / **5** / 0 |
| Opening a chat (select): median / p90 / max | 68 / 88 / 98 ms | **60 / 71 / 78 ms** |
| — the largest chat | 88 / 102 / 111 ms | **73 / 80 / 94 ms** |
| Two chats opened within 50 ms: median / p90 / max | 68 / 85 / 94 ms | **60 / 68 / 72 ms** |
| — the largest chat | 86 / 101 / 103 ms | **69 / 77 / 82 ms** |
| Launch | 73 / 92 / 98 ms | 64 / 74 / 76 ms |
| Whole run: answers over 100 / 150 / 200 ms | 55 / 1 / 0 | **7 / 0 / 0** |
| Sidebar listed after launch, median | 275 ms | 260 ms |
| Row jumps of an idle chat | 0 | 0 |
| Footprint per launch | 3.80 MB | 3.74 MB |

The lead's 0.1.129 run (no card) had opening a chat at 60 / 72 ms, the largest
chat at 75 / 81 ms and switching at 59 / 71 ms, so opening and switching beside
the card are back at 0.1.129's level. The card's remaining 106 samples are
mostly once per launch (building the pane, first draws, moving to the window)
plus 24 in `PiKit.Tabs.intrinsicContentSize` (the card's layout asks the tabs
their size on every pass).

Three earlier "before" runs were discarded under the quiet-machine rule (1-minute
load above 4: 5.85, 20.73 and 5.58, from other workstreams' Release compiles).
Their profiles agree with the one kept: TextKit 2,067 / 2,050 / 2,058 samples
(1,118–1,122 as replies joined the page), the card 585 / 586 / 662. The kept
run's end line reads 4.60, 30 s after the soak's last action, during
`xcodebuild`'s teardown; its in-run maximum was 3.74.

## Notes

- **Found, not fixed** (outside the assignment): `PiKit.ButtonBase.layout()`
  marks the face's content for display on every layout pass
  (`PiKitButtons.swift:194`), so a pill or icon button that is laid out again
  is drawn again even when nothing in it changed. In both versions' profiles the
  composer's pills and icon buttons draw for about 1,200 main-thread samples per
  two minutes of switching (`ComposerPillButton`, `PiKit.IconButton`), about
  twice what the card cost in 0.1.130.
- **Seen in the tests:** with legacy scroll bars the transcript's scroller
  appears after a chat's first layout and narrows the column by 15 pt, and every
  row is measured again at the new width.
- Other markdown surfaces (reasoning in an opened work row, sub-agent markdown,
  compaction summaries) do not call `prepare(width:)`; the join guard covers
  them, but a reasoning text still arriving in an opened work row lays its words
  out once at 840 pt for its caret before its measurement.
- The profiles attribute a few samples through identical-code-folded thunks
  (for example a closure of `AgentFamilyPopoverView.refresh` under
  `DashboardReader.run`); those are left out of the card's figures.
- `replayd` (Codex Computer Use's screen capture) used about 75% of a core
  throughout; killed once as the owner authorized, it restarted at once.
