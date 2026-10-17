# Transcript fixes for 0.1.130

Workstream: `dev/a130-transcript`, based on `141666ca479184d10a9791754d4c91df456599d8`.
Worktree: `/Users/admin/Library/Caches/BelloSwiftWork/wt-a130-transcript`.
Build root: `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript`.
Text evidence is in its `validation/` directory. All data is generated; workspace
fixtures use isolated state and `MemoryVaultStorage`. No installed app, real chat,
real preferences, Keychain or paid provider is used. No release, tag or
`main`/`dev/next` write is performed. The shared full-lane lock is acquired for
each native run and released by a shell trap or `finally`, including expected
failures. Results below count test methods, not assertion failures.

## TRANSCRIPT-1 — confirmed and fixed

`TranscriptCopy` independently scanned headings and lost list-container context.
`NativeMarkdownContainer` indexed only top-level parsed headings. Copying Real
therefore selected the scanner's earlier Nested target. Section targets now use
`TranscriptMarkdown.locatedBlocks`, including its exact UTF-8 source offsets.
Hierarchy boundaries and the existing source-byte slices remain intact; code
copying and the 64 KiB bound are unchanged.

Regression: `TranscriptBugRegressionTests.testHeadingCopyUsesTheRenderedTopLevelHeading`.
It mounts a completed native reply, hovers Real, activates its accessibility Copy
control and checks the actual pasteboard and top-level targets. Baseline excerpt:

```text
XCTAssertEqual failed: ("Optional(\"Copy Nested as Markdown\")") is not equal to ("Optional(\"Copy Real as Markdown\")")
XCTAssertEqual failed: ("Optional(\"  ## Nested\n\n  nested text\n\n\")") is not equal to ("Optional(\"# Real\n\nreal text.\")")
```

Nearby confirmed instances, covered separately in
`testSectionCopyMatchesParsedContainersAndMultilineSetextSource`:

- An ordered-list continuation's Setext heading also consumed a top-level index.
- A heading inside an HTML comment consumed a top-level index despite being hidden.
- A multiline Setext heading copied only its final title line. The regression
  preserves its complete source with Unicode before it and CRLF endings.

All failed before the fix. A quoted heading is a passing control. Restoring the
original scanner (`mutation-heading.log`) fails exactly these two methods:
7 passed, 2 failed, 7 assertion failures. The fixed implementation passes both.

## TRANSCRIPT-2 — confirmed and fixed

`computeEditRequest` treated any marker-shaped text as truncation metadata.
Marker removal now requires `inputTruncated == true`; complete inputs, including
older inputs with an absent flag, retain every character. JSON completeness and
the existing preview bounds still determine whether the card is complete.

Regression: `testCompleteEditKeepsLiteralTruncationMarkerAndChangedTails`, through
`TranscriptToolRow.card`, checks completeness, exact before/after strings, marker
context and the removed/added tails, for both false and absent truncation flags.
Baseline excerpt (`failing-first.log`):

```text
testCompleteEditKeepsLiteralTruncationMarkerAndChangedTails : XCTAssertTrue failed
XCTAssertEqual failed: ("header\n") is not equal to ("header\n…[truncated, 12 more bytes]\nold tail")
```

Nearby confirmed instance: complete `write` content took the same destructive
path. `testCompleteWriteKeepsLiteralTruncationMarker` fails before the fix and
checks exact content/rows afterward. `testExplicitlyTruncatedEditStillSeparatesTheLegacyMarker`
passes before and after, preserving the explicitly truncated compatibility path.
Restoring unconditional marker removal (`mutation-edit.log`) fails exactly the
edit and write regressions: 7 passed, 2 failed, 15 assertion failures.

## TRANSCRIPT-3 — confirmed and fixed

The production Find bridge requests a display projection, but ordinary saved and
live assistant prose stayed raw Markdown. Both paths now use the renderer's
cached plain-text projection. Saved timeline text and ordinary prose alongside
tool calls use it too. Projection is off the main actor in the history reader.
Retained-source search and Copy Conversation keep their default source behavior;
ordinary user text and tool argument evidence remain literal. Already-rendered
agent prose is never parsed a second time.

Regressions: `testFindMatchesFormattedOrdinaryLiveReply` and
`testFindMatchesFormattedOrdinaryReopenedReply`. Both use a generated journal,
the real workspace/pane bridge and Find controller, then check one match, the
selected rendered range and its intersection with the visible viewport. The live
case overlays source absent from disk; the saved case opens a fresh history reader.
Both failed before the fix:

```text
XCTAssertEqual failed: ("[]") is not equal to ("[\"reply\"]")
```

Nearby confirmed instances, with failing-first coverage:

- `testSavedFindProjectsAssistantTextAlongsideToolCalls`: ordinary assistant text
  adjacent to regular or agent tool calls had zero occurrences of the visible phrase.
- `testSavedFindProjectsTimelineProseAndKeepsSourceEvidence`: saved timeline prose
  also had zero occurrences. Raw tool arguments, user content and source-copy output
  are preservation controls.

Restoring the original projection (`mutation-find.log`) fails exactly the four
Find regressions: 5 passed, 4 failed, 5 assertion failures. The restored fixes
pass all nine original methods (`regression-restored.log`).

### Nearby reasoning search and disclosure

The same raw projection also affected exposed assistant reasoning, including
saved `thinking` blocks and `reasoningText`/`reasoningSummary` timeline segments.
Added `testFindMatchesFormattedLiveReasoning` and
`testFindMatchesFormattedReopenedReasoning`, plus both timeline kinds in the
existing timeline regression. Before extending the projection,
`reasoning-first.log` records 8 passed / 3 failed (4 assertions): both panes had
`[]` instead of `["reply"]`, and both timeline kinds had zero occurrences.

Fixing projection alone then reproduced a second missing step:
`TranscriptPage.revealContent` checked raw text before opening reasoning.
`reasoning-disclosure-first.log` records 9 passed / 2 failed: matches existed,
but both waits for a visible highlighted range timed out. The four reported
failures include the two thrown `EventuallyTimedOut` errors, not a crash.
The existing disclosure path now checks the cached rendered reasoning as well.
`reasoning-fixed.log` passes all 11 methods. The final tests also check the
TextKit background highlight attribute, not just the Find count.

The independent mutations reproduce each step: restoring the pre-reasoning
projection (`mutation-reasoning-projection.log`) gives 8 passed / 3 failed;
restoring the original disclosure checks (`mutation-reasoning-disclosure.log`)
gives 9 passed / 2 failed, with both expected highlight timeouts. Every mutation
restores its fixed source in `finally`. `regression-final.log` then passes all
11 methods, including the background-color assertions.

## Initial commands and results

`xcodegen generate --quiet` regenerated the checked-in project for the new test
files and passed the final regeneration check. `git diff --check` passed. These
are the exact final focused commands, each under the shared lock. The regression
command is also the failing-first/mutation command; test additions explain its
increase from 9 to 11 methods.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript

scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests

scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptMarkdownTests \
  -only-testing:PiAppTests/MarkdownTextSurfaceTests \
  -only-testing:PiAppTests/NativeMarkdownSizingTests \
  -only-testing:PiAppTests/NativeMarkdownSurfaceStreamingTests \
  -only-testing:PiAppTests/TranscriptActivityTests \
  -only-testing:PiAppTests/TranscriptWorkRowTests \
  -only-testing:PiAppTests/TranscriptPageStressTests \
  -only-testing:PiAppTests/TranscriptFindTests \
  -only-testing:PiAppTests/ContentSearchTests \
  -only-testing:PiAppTests/TranscriptNativeWorkBehaviourTests \
  -only-testing:PiAppTests/StableToolPresentationTests \
  -only-testing:PiAppTests/TranscriptRevealTests \
  -only-testing:PiAppTests/TranscriptDisclosureTests \
  -only-testing:PiAppTests/HistoryReaderCheckpointTests \
  -only-testing:PiAppTests/HistoryIndexFilesTests \
  -only-testing:PiAppTests/StorageTruthTests \
  -only-testing:PiAppTests/WorkspaceTests \
  -only-testing:PiAppTests/HardeningTests

scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentMarkdownTests

scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentReaderTests

scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptFindProbeTests

TEST_RUNNER_PI_TRANSCRIPT_BUG_GALLERY="$PI_BUILD_ROOT/validation/gallery-final" \
  scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugGalleryTests
```

Final text logs: `regression-final.log`, `affected-final.log`,
`agent-markdown-final.log`, `agent-reader-final.log`, `find-probe.log` and
`gallery-final.log`. All exited 0. Results by class:

| Class | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| `TranscriptBugRegressionTests` | 11 | 0 | 0 |
| `ContentSearchTests` | 7 | 0 | 0 |
| `HardeningTests` | 12 | 0 | 0 |
| `HistoryIndexFilesTests` | 3 | 0 | 1 |
| `HistoryReaderCheckpointTests` | 7 | 0 | 0 |
| `MarkdownTextSurfaceTests` | 6 | 0 | 3 |
| `NativeMarkdownSizingTests` | 4 | 0 | 0 |
| `NativeMarkdownSurfaceStreamingTests` | 4 | 0 | 0 |
| `StableToolPresentationTests` | 10 | 0 | 0 |
| `StorageTruthTests` | 11 | 0 | 0 |
| `TranscriptActivityTests` | 11 | 0 | 0 |
| `TranscriptDisclosureTests` | 15 | 0 | 0 |
| `TranscriptFindTests` | 11 | 0 | 0 |
| `TranscriptMarkdownTests` | 9 | 0 | 0 |
| `TranscriptNativeWorkBehaviourTests` | 21 | 0 | 0 |
| `TranscriptPageStressTests` | 24 | 0 | 0 |
| `TranscriptRevealTests` | 10 | 0 | 0 |
| `TranscriptWorkRowTests` | 15 | 0 | 0 |
| `WorkspaceTests` | 17 | 0 | 0 |
| `SubagentMarkdownTests` | 19 | 0 | 0 |
| `SubagentReaderTests` | 55 | 0 | 0 |
| `TranscriptFindProbeTests` | 0 | 0 | 1 |
| `TranscriptBugGalleryTests` | 1 | 0 | 0 |

**Totals:** focused native behavior/storage/navigation tests: 282 passed, 0 failed,
5 skipped; gallery: 1 passed, 0 failed, 3 PNGs. The skips are the optional long
history index measurement (`PI_PERF_HISTORY_JOURNAL`), two Markdown measurements
and its old sample capture (`PI_MARKDOWN_SNAPSHOT_DIR`), and the long Find timing
probe (`PI_LONG_PROBE`). The new bug gallery was enabled and did not skip.

The initial `failing-first.log` records 1 passed / 8 failed (27 assertions), exit
65, before any production fix. `fixed.log`, `fixed-final.log` and
`regression-restored.log` each pass the original 9 methods. The earlier
`affected.log` passes 122 with 3 skips, and `agent-markdown.log` passes 19; final
runs above supersede those counts. There were no unrelated test failures.
No named result bundle was supplied. One DerivedData root was used, and no clone
directories were left by these serial focused runs.

## Initial gallery and follow-up layout finding

Viewed all three generated images in `validation/gallery-final/`:
`transcript-light.png` and `transcript-dark.png` at 760×800 points, and
`transcript-narrow.png` at 360×800. Each shows the literal marker as unchanged
context, red `old tail`, green `new tail`, a complete “Requested edit” banner,
the Real heading action and the highlighted rendered “alpha beta” phrase.
The first gallery fixture left Work closed; it was corrected to open the work
row and assert a mounted diff card before taking the final images.

**Initially outside the assigned defects, now fixed in the follow-up below:** at 360 points, the heading Copy
control is clipped on its right. `apps/macos/PiApp/Transcript/NativeMarkdownSurface.swift:981`
adds 30 points beyond the available width when positioning that control
(frame assignment at line 982). The formula is identical in the baseline and
initial branch; the initial narrow capture shows the crop. The owner explicitly
assigned this layout bug in the follow-up review.

## Initial review and limits

All three assigned findings are confirmed and fixed; none were rejected.
Nearby same-pattern fixes are itemized above. No product decision was needed
for these corrections, and permission, capture, tool, vault and data boundaries
are unchanged. No helper or wire implementation changes are included, so their
full suites are not required for this workstream. The lead owns the separate
review, full merged gate and merge. This branch does not merge or release.

## Follow-up review of 74ee5969 — 2026-10-18

The two review findings and the newly assigned narrow-layout bug are confirmed
and fixed. None was rejected. The following tests were added before production
changes, against `74ee5969e608410fd84604617c51d9d0acfb0204`.
`review-failing-first.log` records **13 passed, 7 failed**, with 18 assertion
failures and exit 65. `review-fixed.log` then records **20 passed, 0 failed**.

### REVIEW-1: Find follows View Raw — confirmed and fixed

Find previously projected every ordinary reply as rendered Markdown regardless
of `.source(replyID)`. It now snapshots the disclosure's raw reply IDs on the
main actor and carries that plain set through saved-history, unsaved-row and
journal-free search. Only the reply's text uses its raw source; reasoning and
agent-card prose retain their rendered projection. A remembered raw choice is
ignored while the reply streams, matching `ReplySource.shows`.

`testFindMatchesViewRawInSavedReply` mounts a real pane over a generated journal,
uses the row's source toggle, searches the visible `example.test` link destination,
and checks one match, the native highlight and unchanged source. Before the fix:

```text
testFindMatchesViewRawInSavedReply : XCTAssertEqual failed: ("[]") is not equal to ("[\"reply\"]")
```

Nearby instances found and fixed:

- Unsaved completed replies over a journal used the same rendered-only projection:
  `testFindMatchesViewRawInUnsavedReply` failed with `[]` instead of `["unsaved-reply"]`.
- Chats without a journal also lost raw-only text:
  `testFindMatchesViewRawWithoutJournal` failed with `[]` instead of `["reply"]`.
- Switching View Raw while Find was already open left the old search result:
  `testViewRawRefreshesAnActiveFind` failed with `[]` instead of `["reply"]`.
  A source-choice change now restarts the active query without requesting a
  navigation jump. All four tests also switch back and require raw-only matches
  to disappear. Ordinary disclosure changes do not restart Find.

Passing controls before and after: `testRememberedViewRawKeepsStreamingFindRendered`
and `testViewRawKeepsReasoningFindRendered`. Existing saved/live formatted prose,
reasoning, timeline and agent-tool projection regressions still pass.

### REVIEW-2: CR source offsets — confirmed and fixed

The renderer's source-line table counted only LF bytes, although Foundation
parses bare CR as a line break. The shared table now counts CR and LF and treats
CRLF as one ending, keeping offsets in the original UTF-8 bytes.
`testSectionCopyPreservesCRLFAndMixedLineEndings` checks the introduction and
both exact section strings with CR, CRLF and LF, plus a multiline Setext title
with mixed endings and preceding Unicode. Before the fix, the CR fixture copied:

```text
actual:   ["", "Intro 🌍\r\r# One\rbody\r\r# Two\rmore"]
expected: ["Intro 🌍\r\r", "# One\rbody\r\r", "# Two\rmore"]
```

Nearby instance: `liveBlocksWithItems` uses the same table for block and list-item
starts. `testLiveMarkdownOffsetsRespectCRLFAndMixedLineEndings` failed before the
fix (for example, block offsets `[0, 12, 12, 12]` instead of `[0, 13, 31, 38]`).
It now checks all exact offsets, including Unicode and mixed endings. The sweep
found no second LF-only source-line table in the transcript; the code-copy line
scanner already handles CR, LF and CRLF.

### Heading Copy layout — confirmed and fixed

`testHeadingCopyControlStaysInsideNarrowReplyRows` mounts real reply rows at
320, 360, 620 and 760 points, hovers the heading, and checks that the complete
control frame lies inside both the Markdown surface and the row. Before the fix:

```text
360.0-point surface: (326.0, 7.5, 64.0, 23.0) outside (0.0, 0.0, 360.0, 60.0)
360.0-point row clips heading Copy
```

The 30-point gutter allowance now sits inside the width clamp. Wide rows retain
their previous gutter position; narrow and uncapped surfaces stay within their
bounds. The nearby table-action positioning already clamps to the available
width, and no other instance of this added-after-clamp pattern was found.
The gallery now asserts both surface and viewport containment before capture.

### Follow-up mutation evidence

Each mutation ran the complete `TranscriptBugRegressionTests` class in its own
process, then restored the fixed file in `finally`. All four commands exited 65
for the expected regression failures. No mutation was left in the final tree.

| Log | Deliberately broken fix | Passed | Failed | Assertion failures |
| --- | --- | ---: | ---: | ---: |
| `review-mutation-raw-find.log` | Pass an empty raw-reply set from `WorkspaceContent` | 16 | 4 | 4 |
| `review-mutation-source-refresh.log` | Remove active-query restart on source-choice change | 16 | 4 | 4 |
| `review-mutation-cr.log` | Restore the LF-only source-offset loop | 18 | 2 | 8 |
| `review-mutation-copy-frame.log` | Restore `+ 30` after the width clamp | 19 | 1 | 6 |

The Find mutations break the four raw-view tests listed above. The CR mutation
breaks section copying and live block/list offsets. The frame mutation breaks
containment at 320, 360 and 620 points; 760 points remains a passing control.
After restoring all fixes, `review-regression-final.log` records **20 passed,
0 failed**, exit 0.

### Follow-up validation commands and results

Each command below ran from this worktree under the shared full-lane lock.
The pasteboard/focus serial classes ran alone. The affected parallel-lane
classes were grouped with parallel testing disabled. The failing-first, fixed
and four mutation runs used the same first command below.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript

# review-regression-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests

# review-affected-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ContentSearchTests \
  -only-testing:PiAppTests/HardeningTests \
  -only-testing:PiAppTests/HistoryIndexFilesTests \
  -only-testing:PiAppTests/HistoryReaderCheckpointTests \
  -only-testing:PiAppTests/MarkdownTextSurfaceTests \
  -only-testing:PiAppTests/NativeMarkdownSizingTests \
  -only-testing:PiAppTests/NativeMarkdownSurfaceStreamingTests \
  -only-testing:PiAppTests/StableToolPresentationTests \
  -only-testing:PiAppTests/StorageTruthTests \
  -only-testing:PiAppTests/TranscriptActivityTests \
  -only-testing:PiAppTests/TranscriptDisclosureTests \
  -only-testing:PiAppTests/TranscriptFindTests \
  -only-testing:PiAppTests/TranscriptMarkdownTests \
  -only-testing:PiAppTests/TranscriptNativeWorkBehaviourTests \
  -only-testing:PiAppTests/TranscriptPageStressTests \
  -only-testing:PiAppTests/TranscriptRevealTests \
  -only-testing:PiAppTests/TranscriptWorkRowTests \
  -only-testing:PiAppTests/WorkspaceTests \
  -only-testing:PiAppTests/ReplySourceTests \
  -only-testing:PiAppTests/MarkdownSourceReconciliationTests \
  -only-testing:PiAppTests/TranscriptNativePaneBehaviourTests \
  -only-testing:PiAppTests/TranscriptSwitchFirstFrameTests \
  -only-testing:PiAppTests/NativeTranscriptTests \
  -only-testing:PiAppTests/MarkdownStreamingCorrectnessTests \
  -only-testing:PiAppTests/MarkdownStreamingTests \
  -only-testing:PiAppTests/NativeMarkdownViewportTests

# review-agent-markdown-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentMarkdownTests

# review-agent-reader-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentReaderTests

# review-gallery-final.log
TEST_RUNNER_PI_TRANSCRIPT_BUG_GALLERY="$PI_BUILD_ROOT/validation/gallery-review" \
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugGalleryTests
```

| Final log | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| `review-regression-final.log` | 20 | 0 | 0 |
| `review-affected-final.log` | 253 | 0 | 4 |
| `review-agent-markdown-final.log` | 19 | 0 | 0 |
| `review-agent-reader-final.log` | 55 | 0 | 0 |
| `review-gallery-final.log` | 1 | 0 | 0 |

| Class | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| `ContentSearchTests` | 7 | 0 | 0 |
| `HardeningTests` | 12 | 0 | 0 |
| `HistoryIndexFilesTests` | 3 | 0 | 1 |
| `HistoryReaderCheckpointTests` | 7 | 0 | 0 |
| `MarkdownSourceReconciliationTests` | 7 | 0 | 0 |
| `MarkdownStreamingCorrectnessTests` | 9 | 0 | 0 |
| `MarkdownStreamingTests` | 2 | 0 | 0 |
| `MarkdownTextSurfaceTests` | 6 | 0 | 3 |
| `NativeMarkdownSizingTests` | 4 | 0 | 0 |
| `NativeMarkdownSurfaceStreamingTests` | 4 | 0 | 0 |
| `NativeMarkdownViewportTests` | 4 | 0 | 0 |
| `NativeTranscriptTests` | 5 | 0 | 0 |
| `ReplySourceTests` | 12 | 0 | 0 |
| `StableToolPresentationTests` | 10 | 0 | 0 |
| `StorageTruthTests` | 11 | 0 | 0 |
| `SubagentMarkdownTests` | 19 | 0 | 0 |
| `SubagentReaderTests` | 55 | 0 | 0 |
| `TranscriptActivityTests` | 11 | 0 | 0 |
| `TranscriptBugGalleryTests` | 1 | 0 | 0 |
| `TranscriptBugRegressionTests` | 20 | 0 | 0 |
| `TranscriptDisclosureTests` | 15 | 0 | 0 |
| `TranscriptFindTests` | 11 | 0 | 0 |
| `TranscriptMarkdownTests` | 9 | 0 | 0 |
| `TranscriptNativePaneBehaviourTests` | 16 | 0 | 0 |
| `TranscriptNativeWorkBehaviourTests` | 21 | 0 | 0 |
| `TranscriptPageStressTests` | 24 | 0 | 0 |
| `TranscriptRevealTests` | 10 | 0 | 0 |
| `TranscriptSwitchFirstFrameTests` | 1 | 0 | 0 |
| `TranscriptWorkRowTests` | 15 | 0 | 0 |
| `WorkspaceTests` | 17 | 0 | 0 |

**Follow-up totals:** 347 focused behavior/storage/navigation tests passed,
0 failed, 4 skipped; gallery: 1 passed, 0 failed, 3 PNGs. The skips are the
optional history-index measurement and the three opt-in Markdown
measurement/sample-capture tests. There were no unrelated failures.

Inspected `validation/gallery-review/transcript-light.png`, `transcript-dark.png`
(760×800 points), and `transcript-narrow.png` (360×800). The narrow image now
shows the complete Copy icon and label beside Real, with space to the viewport
edge. Both wide themes preserve the existing gutter placement. The literal
marker diff, changed tails and formatted Find highlight remain visible.

One existing build root was reused; no clone directories remained and no
named result bundle was supplied. No helper or wire behavior changed, so
helper/wire suites were not required. All assigned review issues are resolved;
no owner decision is pending. The lead retains the separate review, merged
full gate and merge.

## Round 2: Find display projection and refresh (2026-10-18)

Reviewed base: `fa0d63566a64f18481f153f68652520edb66cd2f`. All three findings
are confirmed and fixed. The first run added six tests before any production
change: `round2-failing-first.log` records **20 passed, 6 failed**, 94 assertion
failures, exit 65. Two sweep tests were then added and run against the same
unfixed code: `round2-nearby-first.log` records **0 passed, 2 failed**, five
assertion failures, exit 65. Logs remain under the build root's `validation/`.

### R2-1: refreshing Find moves the reader — confirmed and fixed

`testSourceRefreshKeepsTheReaderAwayFromTheCurrentFindHit` mounts a real pane,
searches a reply, scrolls to another loaded reply without the query, and changes
that reply to View Raw. Before the fix:

```text
XCTAssertEqual failed: ("nil") is not equal to ("Optional(0)") - Keep the selected match while refreshing
XCTAssertEqualWithAccuracy failed: ("0.0") is not equal to ("750.0") +/- ("1.0") - Refreshing cannot scroll back to the old hit
```

A refresh now buffers replacement results while retaining the selected match
and existing highlights. It cancels pending navigation and never constructs a
new focus. If the selected occurrence still exists, it remains selected after
the refresh. Only an explicit Find step creates navigation focus. The final
regression chooses the second of two hits before leaving it behind, so restoring
the first match cannot accidentally pass. `testViewRawRefreshesAnActiveFind`
also asserts that a refresh gaining its first result has no focus/pending reveal
before an explicit step. Restoring the old Find controller kills both tests
(`round2-mutation-navigation.log`: 26 passed, 2 failed, exit 65).

### R2-2: raw completed timeline segments — confirmed and fixed

`testFindUsesRawCompletedSegmentWhileAnotherSegmentStreams` mounts two arrival
segments under a streaming parent: the completed link is shown raw and the
later formatted segment remains rendered. Searching `example.test` failed first:

```text
XCTAssertEqual failed: ("[]") is not equal to ("["reply"]")
```

The shared saved/live projection now visits the same arrival-ordered segments
as the transcript and obtains each segment's state from
`TranscriptTimelinePart.source`. `ReplySource.shows` makes the raw/rendered
choice for text and refusal rows; reasoning and other prose keep their rendered
presentation. The passing pane test requires a visible highlight on the URL.
Replacing the segment state with the parent's state kills this test and the
timeline equality corpus (`round2-mutation-segment.log`: 26 passed, 2 failed,
exit 65).

### R2-3: visible list numbers missing from Find — confirmed and fixed

`testFindIncludesVisibleOrderedMarkersInSavedReply` and
`testFindIncludesVisibleOrderedMarkersInLiveReply` mount `1. alpha\n2. beta`
and search `2.`. Both failed first with `[] != ["reply"]`. Both now require
one matching reply and a native text highlight on the number.

`TranscriptMarkdown.renderedText` uses `MarkdownTextBuilder.paragraphs`, the
same builder as the native surface, and the assembler's paragraph separator.
It preserves actual displayed list numbering, tabs, headings, code/newlines,
link labels, table cells and bounded-table preview notices. Streaming text
uses the renderer's streaming preview parse. Completed projections are cached
with bounded `NSCache` storage. Each background search owns a separate local
builder; no view, mutable text, or layout-manager instance crosses actors.
The existing font cache remains locked. Source search, export/copy and helper
boundaries are unchanged.

Replacing this function with the former marker-free block projection kills
six tests: the saved/live list searches, both equality corpora, the agent
preview predicate and timeline prose reveal (`round2-mutation-rendered-text.log`:
22 passed, 6 failed, exit 65).

### Shared-renderer corpus and nearby instances

`testFindProjectionEqualsNativeReplyTextAcrossMarkdownCorpus` compares the
projection to the actual selectable `NSTextView.string` in mounted reply rows.
Its 14 sources cover inline formatting, ATX/Setext headings, ordered/nested
lists and renderer-renumbered items, list-opening fences, quotes, empty and
multiline code fences, links/reference links, images, hidden HTML, empty table
cells, a 45-row preview, and incomplete emphasis/link/list input. Each is checked
complete and streaming, rendered and raw, plus both saved complete modes:
**84 exact-string comparisons**.

`testTimelineProjectionEqualsEachNativeSegmentInBothModes` builds text, refusal,
reasoning text/summary, opaque and a final streaming text segment. It compares
the actual segment views against the live and saved projection in both modes:
**six additional exact-string comparisons**, for **90 total**. Canonical message
text intentionally differs from its timeline, proving that the displayed
arrival-ordered rows determine Find's text. These corpora failed before the fix
on lost markers, extra export/newline text, timeline selection, table text and
unfinished streaming markup.

Two same-pattern instances were separately reproduced and fixed:

- `TranscriptAgentMarkdown.swift`, `AgentMarkdownReading.make`: its search
  predicate still used marker-free text. `testAgentMarkdownSearchIncludesItsNativeListMarkers`
  mounts `7. first\n29. second`, verifies that the renderer shows `8.`, and failed
  first because `contains("8.")` returned false. Search now uses the shared
  rendered projection; the existing character budget for incremental adoption
  is unchanged.
- `TranscriptPage.swift`, `revealContent`: the fold-opening predicate also
  discarded rendered markers, and only considered rendered text for two
  reasoning kinds. `testFindOpensTimelineProseForItsRenderedListMarker` covers
  reasoning text, reasoning summary, opaque and correction parts; each must
  open and highlight its renderer-generated `8.`. The before-fix run missed
  all four. The predicate now uses the shared streaming-aware projection for
  every prose kind the part view renders, preserving literal tool/status rows.

The sweep also removes the assistant display path's export-only headings and
retained-event metadata by sharing the live message projection with saved
messages. The export function retains its source representation. Existing
reasoning, raw/streaming controls, agent tool receipts, ordinary tool arguments,
and source-evidence tests remain in the regression class.

### Round-2 mutation evidence

Each mutation ran all 28 regression tests in a fresh test process. Every run
failed only its expected methods, exited 65, and restored the fixed file in
`finally`. The final regression run after restoration passed all 28 tests.

| Log | Deliberately broken fix | Passed | Failed | Assertion failures |
| --- | --- | ---: | ---: | ---: |
| `round2-mutation-navigation.log` | Restore the pre-review Find controller | 26 | 2 | 6 |
| `round2-mutation-segment.log` | Use parent state for timeline text/refusal | 26 | 2 | 2 |
| `round2-mutation-rendered-text.log` | Use marker-free block text instead of the native builder | 22 | 6 | 41 |
| `round2-mutation-prose-disclosure.log` | Limit rendered fold matching to reasoning kinds | 27 | 1 | 2 |
| `round2-mutation-agent-markers.log` | Restore marker-free agent preview search | 27 | 1 | 1 |

The disclosure mutation prevents opaque/correction matches from receiving a
visible highlight; the agent mutation makes the native `8.` unsearchable in
the preview predicate. Together with the failing-first runs, these isolate the
nearby fixes from the common projection change.

### Round-2 validation commands and results

All commands ran from this worktree with the shared full-lane lock held only
for each run and released in `finally`. Serial-lane classes ran alone. Tests
used generated journals, an in-memory vault and isolated test-host windows.
No installed app, live provider, real preferences, chats or Keychain was used.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript

# round2-failing-first.log, round2-fixed.log, round2-fixed-final.log,
# all five round2-mutation-*.log files, and round2-regression-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests

# round2-nearby-first.log (before any production change)
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFindOpensTimelineProseForItsRenderedListMarker \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testAgentMarkdownSearchIncludesItsNativeListMarkers

# round2-affected-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ContentSearchTests \
  -only-testing:PiAppTests/HardeningTests \
  -only-testing:PiAppTests/HistoryIndexFilesTests \
  -only-testing:PiAppTests/HistoryReaderCheckpointTests \
  -only-testing:PiAppTests/MarkdownTextSurfaceTests \
  -only-testing:PiAppTests/NativeMarkdownSizingTests \
  -only-testing:PiAppTests/NativeMarkdownSurfaceStreamingTests \
  -only-testing:PiAppTests/StableToolPresentationTests \
  -only-testing:PiAppTests/StorageTruthTests \
  -only-testing:PiAppTests/TranscriptActivityTests \
  -only-testing:PiAppTests/TranscriptDisclosureTests \
  -only-testing:PiAppTests/TranscriptFindTests \
  -only-testing:PiAppTests/TranscriptMarkdownTests \
  -only-testing:PiAppTests/TranscriptNativeWorkBehaviourTests \
  -only-testing:PiAppTests/TranscriptPageStressTests \
  -only-testing:PiAppTests/TranscriptRevealTests \
  -only-testing:PiAppTests/TranscriptWorkRowTests \
  -only-testing:PiAppTests/WorkspaceTests \
  -only-testing:PiAppTests/ReplySourceTests \
  -only-testing:PiAppTests/MarkdownSourceReconciliationTests \
  -only-testing:PiAppTests/TranscriptNativePaneBehaviourTests \
  -only-testing:PiAppTests/TranscriptSwitchFirstFrameTests \
  -only-testing:PiAppTests/NativeTranscriptTests \
  -only-testing:PiAppTests/MarkdownStreamingCorrectnessTests \
  -only-testing:PiAppTests/MarkdownStreamingTests \
  -only-testing:PiAppTests/NativeMarkdownViewportTests \
  -only-testing:PiAppTests/NativeTranscriptDocumentTests \
  -only-testing:PiAppTests/NativeTranscriptSafetyTests \
  -only-testing:PiAppTests/ResponseTimelinePresentationTests \
  -only-testing:PiAppTests/TimelineStreamingFastPathTests

# round2-timeline-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptNativeTimelineBehaviourTests

# round2-agent-markdown-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentMarkdownTests

# round2-agent-reader-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentReaderTests

# round2-gallery-final.log
TEST_RUNNER_PI_TRANSCRIPT_BUG_GALLERY="$PI_BUILD_ROOT/validation/gallery-round2" \
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugGalleryTests
```

| Final log | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| `round2-regression-final.log` | 28 | 0 | 0 |
| `round2-affected-final.log` | 283 | 0 | 4 |
| `round2-timeline-final.log` | 30 | 0 | 0 |
| `round2-agent-markdown-final.log` | 19 | 0 | 0 |
| `round2-agent-reader-final.log` | 55 | 0 | 0 |
| `round2-gallery-final.log` | 1 | 0 | 0 |

| Class | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| `ContentSearchTests` | 7 | 0 | 0 |
| `HardeningTests` | 12 | 0 | 0 |
| `HistoryIndexFilesTests` | 3 | 0 | 1 |
| `HistoryReaderCheckpointTests` | 7 | 0 | 0 |
| `MarkdownSourceReconciliationTests` | 7 | 0 | 0 |
| `MarkdownStreamingCorrectnessTests` | 9 | 0 | 0 |
| `MarkdownStreamingTests` | 2 | 0 | 0 |
| `MarkdownTextSurfaceTests` | 6 | 0 | 3 |
| `NativeMarkdownSizingTests` | 4 | 0 | 0 |
| `NativeMarkdownSurfaceStreamingTests` | 4 | 0 | 0 |
| `NativeMarkdownViewportTests` | 4 | 0 | 0 |
| `NativeTranscriptDocumentTests` | 10 | 0 | 0 |
| `NativeTranscriptSafetyTests` | 5 | 0 | 0 |
| `NativeTranscriptTests` | 5 | 0 | 0 |
| `ReplySourceTests` | 12 | 0 | 0 |
| `ResponseTimelinePresentationTests` | 13 | 0 | 0 |
| `StableToolPresentationTests` | 10 | 0 | 0 |
| `StorageTruthTests` | 11 | 0 | 0 |
| `SubagentMarkdownTests` | 19 | 0 | 0 |
| `SubagentReaderTests` | 55 | 0 | 0 |
| `TimelineStreamingFastPathTests` | 2 | 0 | 0 |
| `TranscriptActivityTests` | 11 | 0 | 0 |
| `TranscriptBugGalleryTests` | 1 | 0 | 0 |
| `TranscriptBugRegressionTests` | 28 | 0 | 0 |
| `TranscriptDisclosureTests` | 15 | 0 | 0 |
| `TranscriptFindTests` | 11 | 0 | 0 |
| `TranscriptMarkdownTests` | 9 | 0 | 0 |
| `TranscriptNativePaneBehaviourTests` | 16 | 0 | 0 |
| `TranscriptNativeTimelineBehaviourTests` | 30 | 0 | 0 |
| `TranscriptNativeWorkBehaviourTests` | 21 | 0 | 0 |
| `TranscriptPageStressTests` | 24 | 0 | 0 |
| `TranscriptRevealTests` | 10 | 0 | 0 |
| `TranscriptSwitchFirstFrameTests` | 1 | 0 | 0 |
| `TranscriptWorkRowTests` | 15 | 0 | 0 |
| `WorkspaceTests` | 17 | 0 | 0 |

**Round-2 totals:** 415 focused behavior/storage/navigation tests passed,
0 failed, 4 skipped; gallery: 1 passed, 0 failed, 3 PNGs. Every final command
exited 0. The four skips are the optional history-index measurement and three
opt-in Markdown measurements/sample captures. There were no unrelated failures.

Regenerated and visually inspected all three images under
`validation/gallery-round2/`: `transcript-light.png`, `transcript-dark.png`
(760×800 points) and `transcript-narrow.png` (360×800). The visible ordered-list
marker `2.` is highlighted in every image. Real's heading Copy control remains
fully inside the narrow viewport, and the literal marker diff retains both
changed tails. No new layout defect was observed in these scenes.

The existing build root was reused; no clone directories remained, no named
result bundle was requested, and the owned lane lock was released. No helper
or wire behavior changed, so helper/wire suites were not required.
`git diff --check` passed. No assigned issue or owner decision remains unresolved. The
lead retains separate review, the merged full gate and merge.

## Round 3: newer Find navigation and tool-card text (2026-10-18)

Reviewed base: `d42dc9194a6f080b0f6ddaa42ac193b8c252cd72`. Both reported
findings are confirmed. `round3-failing-first.log` ran before production edits:
**28 passed, 3 failed**, 46 assertion failures, exit 65. The tool corpus was
then corrected to preserve the existing searchable agent identity and actual
file-path labels around the selectable payload, and a capped-edit case was
added. `round3-corpus-failing-first.log`, still before production edits, records
**28 passed, 4 failed**, 38 assertion failures, exit 65. The preceding
`round3-corpus-first.log` was a test compilation failure (a missing `where:`
label on `contains`), corrected before this valid failing-first run.

### R3-1: Next/Previous during refresh — confirmed and fixed

`testFindRefreshKeepsNewerNextAndPreviousSelections` holds the real search
response with a continuation after toggling View Raw. It presses Next, then
in a separate refresh Previous, and requires the current selection, focus
identity, text view and highlighted range to survive completion. Before the fix:

```text
XCTAssertEqual failed: ("Optional(0)") is not equal to ("Optional(1)") - The newer 1 step wins
XCTAssertEqual failed: ("Optional(0)") is not equal to ("Optional(2)") - The newer -1 step wins
```

The controller now captures the current `Match` immediately before replacing
the result array, on the main actor with no intervening await. It keeps the
existing no-new-focus refresh behavior while allowing intervening reader steps
to win. The earlier stationary-reader and first-result-without-focus tests
remain passing controls.

### R3-2: saved generic JSON — confirmed and fixed

`testFindMatchesDisplayedToolJSONInSavedAndLiveReplies` copies the key/value
line from the mounted generic card's formatted JSON and searches it through
a real pane, both from a generated journal and through its streaming overlay.
Both searches failed before the fix:

```text
XCTAssertEqual failed: ("[]") is not equal to ("["reply"]")
```

Find now obtains tool payloads from `TranscriptToolRow.card`, the same
presentation model the native card uses. Ordinary I/O cards therefore use
`TranscriptActivity.argumentsText` formatting and bounded-input recovery.
The card-opening predicate uses that same projection, so a hit on formatted
JSON opens its card and receives a native text highlight.

`testToolSearchProjectionEqualsNativeCardPayloadsSavedAndLive` mounts native
cards for custom, MCP, find, grep, ls, bash, read, edit, write, subagent start,
send and report calls. It compares their actual text views and virtualized
card-line payloads with the saved/live projection; paths and the existing
searchable agent row identity stay included. The first corpus covers saved,
running and completed states (**36 comparisons**). It keeps raw JSON escapes
for generic cards, decoded strings for commands/diffs, literal tool output,
formatted agent prose, Unicode, nested objects/arrays and read-window notes.

### Nearby tool instances

The same corpus confirmed that terminal commands and edit/write payloads were
searched as escaped JSON rather than their displayed strings, and read cards
searched the input envelope plus bracketed source note instead of their
displayed result/window note. These are handled by the native card-model
projection in the same function. Generic/MCP/search/list cards share the JSON
fix. The agent branch is a passing control: its searchable identity, rendered
task/result and error handling are retained.

`testFindOpensDecodedEditTextBeyondItsPreview` adds a quoted changed line in
the middle of a 180-line edit. Before the fix it found no message. An initial
fix run (`round3-fixed.log`: 31 passed, 1 failed) found the message but did not
finish highlighting it; this intermediate failure remains recorded rather
than counted as a successful run.

The adversarial probes then isolated two additional handoffs in the functions
being changed (`round3-adversarial-first.log`: **0 passed, 2 failed**, exit 65):

- `TranscriptFind.swift`, the awaited reveal in `publish`: the old guard compared
  `current` to the integer index captured before the await. The new
  `testFindRefreshKeepsPendingNavigationWhenMatchIndexesChange` holds both search
  and reveal, presses Next, lets refresh insert a hit before the selected one,
  then supplies the missing page with a folded matching thought. Even with the
  primary selection fix, it failed: `The original Next action opens and
  highlights the loaded thought`. The guard now compares the selected `Match`
  identity, retaining cancellation checks, so that pending reader action can
  finish despite index changes.
- `TranscriptHighlights.swift`, `expandCardsForFocus`: the quoted-edit probe
  showed `cards=[(true, ...)]`, `pending=false`, `text=nil`. Expansion had switched
  the diff's data from head/tail lines to its scrolling body, but layout had not
  exposed that body when Find counted matches. The function now lays out the
  changed action subtree before counting; the raw-text fast path remains, and
  displayed-text matching uses the shared card projection. This keeps a newly
  opened body from being mistaken for a message with no drawable match.

After both corrections, `round3-fixed-complete.log` records **33 passed,
0 failed**, exit 0. The final corpus adds held, failed and unknown outcomes
plus three bounded partial-JSON inputs: **75 exact tool-card comparisons**,
alongside the retained **90 Markdown/timeline comparisons**. Gutter controls
and nonselectable action chrome are not tool payload; the test uses the native
Find text units for virtualized card lines and native text views for payloads.

### Adversarial self-review of the whole branch

Reviewed the full diff from `141666ca479184d10a9791754d4c91df456599d8`, including
the original fixes and both prior review rounds, then the final round-3 changes:

- Reader ownership: delayed Next and Previous, an inserted earlier hit during
  a pending reveal, stationary-reader refresh, gaining the first result without
  focus, canceled queries/reveals, and missing selections. Publication remains
  cancellation-guarded; only explicit navigation creates new focus.
- Projection: saved/unsaved/streaming paths, each timeline segment's raw state,
  literal JSON versus decoded special-card strings, partial argument recovery,
  file/agent labels, bounded table previews and formatted prose. Tool-result
  records keep their separate identities; retained-source search/copy still
  uses `ConversationContent.text`.
- Source fidelity: parsed top-level heading indexes, nested lists/quotes and
  hidden HTML, multiline Setext headings, Unicode byte offsets, CR/CRLF/mixed
  endings, and code-copy scanning. No clipboard-source reconstruction was added.
- Truncation and layout: complete literal marker text versus explicitly
  truncated inputs, edit/write tails, narrow heading controls, folded card
  matching, and the diff body switch exposed by the new probe.
- Boundaries and cost: no helper/wire/model-facing changes, new network loads,
  provider calls, preference or vault changes. History search remains off the main
  actor; shared caches are bounded/thread-safe and builders remain local.
  Card expansion short-circuits on existing raw matches, and the added subtree
  layout runs only when the card changes from collapsed to expanded.

The two additional confirmed handoff defects above were fixed in the functions
already under repair. The generated project changes remain only the original
two test-file registrations. No further actionable introduced defect was found
in this self-review; this does not replace the lead's independent review/full gate.

### Round-3 mutation evidence

Each mutation ran the full 33-test regression class in a fresh process, failed
only the expected methods, exited 65 and restored the fixed file in `finally`.
`round3-regression-final.log` then passed all 33 tests, exit 0.

| Log | Deliberately broken fix | Passed | Failed | Assertion failures |
| --- | --- | ---: | ---: | ---: |
| `round3-mutation-selection.log` | Capture the selection before awaiting refresh | 31 | 2 | 11 |
| `round3-mutation-match-identity.log` | Compare an awaited reveal's old integer index | 32 | 1 | 2 |
| `round3-mutation-card-text.log` | Search ordinary tools' raw input/output envelopes | 30 | 3 | 60 |
| `round3-mutation-card-disclosure.log` | Remove displayed-text matching when opening cards | 31 | 2 | 4 |
| `round3-mutation-expansion-text.log` | Expand capped cards only for raw source matches | 32 | 1 | 2 |
| `round3-mutation-expansion-layout.log` | Count matches before exposing the expanded body | 32 | 1 | 2 |

The selection mutation kills both new navigation tests. The identity mutation
isolates the delayed-reveal test. Raw-card projection kills JSON Find, quoted
edit Find and the corpus; disclosure kills both pane-level tool searches.
The final two mutations independently kill the capped quoted-edit test.

### Round-3 validation commands and results

Commands ran from this worktree with the shared lane lock held for each run
and released in `finally`. Serial-lane classes ran alone. Fixtures used generated
journals, an in-memory vault and isolated test-host windows. No installed app,
live provider, real preferences, chats or Keychain was used. Text logs are under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript/validation`.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript

# round3-failing-first.log, round3-corpus-first.log,
# round3-corpus-failing-first.log, round3-fixed.log,
# round3-fixed-complete.log, all six round3-mutation-*.log files,
# round3-regression-final.log and round3-regression-visible-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests

# round3-adversarial-first.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFindRefreshKeepsPendingNavigationWhenMatchIndexesChange \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFindOpensDecodedEditTextBeyondItsPreview

# round3-affected-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ContentSearchTests \
  -only-testing:PiAppTests/HardeningTests \
  -only-testing:PiAppTests/HistoryIndexFilesTests \
  -only-testing:PiAppTests/HistoryReaderCheckpointTests \
  -only-testing:PiAppTests/MarkdownTextSurfaceTests \
  -only-testing:PiAppTests/NativeMarkdownSizingTests \
  -only-testing:PiAppTests/NativeMarkdownSurfaceStreamingTests \
  -only-testing:PiAppTests/StableToolPresentationTests \
  -only-testing:PiAppTests/StorageTruthTests \
  -only-testing:PiAppTests/TranscriptActivityTests \
  -only-testing:PiAppTests/TranscriptDisclosureTests \
  -only-testing:PiAppTests/TranscriptFindTests \
  -only-testing:PiAppTests/TranscriptMarkdownTests \
  -only-testing:PiAppTests/TranscriptNativeWorkBehaviourTests \
  -only-testing:PiAppTests/TranscriptPageStressTests \
  -only-testing:PiAppTests/TranscriptRevealTests \
  -only-testing:PiAppTests/TranscriptWorkRowTests \
  -only-testing:PiAppTests/WorkspaceTests \
  -only-testing:PiAppTests/ReplySourceTests \
  -only-testing:PiAppTests/MarkdownSourceReconciliationTests \
  -only-testing:PiAppTests/TranscriptNativePaneBehaviourTests \
  -only-testing:PiAppTests/TranscriptSwitchFirstFrameTests \
  -only-testing:PiAppTests/NativeTranscriptTests \
  -only-testing:PiAppTests/MarkdownStreamingCorrectnessTests \
  -only-testing:PiAppTests/MarkdownStreamingTests \
  -only-testing:PiAppTests/NativeMarkdownViewportTests \
  -only-testing:PiAppTests/NativeTranscriptDocumentTests \
  -only-testing:PiAppTests/NativeTranscriptSafetyTests \
  -only-testing:PiAppTests/ResponseTimelinePresentationTests \
  -only-testing:PiAppTests/TimelineStreamingFastPathTests

# round3-timeline-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptNativeTimelineBehaviourTests

# round3-agent-markdown-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentMarkdownTests

# round3-agent-reader-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentReaderTests

# round3-gallery-final.log
TEST_RUNNER_PI_TRANSCRIPT_BUG_GALLERY="$PI_BUILD_ROOT/validation/gallery-round3" \
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugGalleryTests
```

| Final log | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| `round3-regression-visible-final.log` | 33 | 0 | 0 |
| `round3-affected-final.log` | 283 | 0 | 4 |
| `round3-timeline-final.log` | 30 | 0 | 0 |
| `round3-agent-markdown-final.log` | 19 | 0 | 0 |
| `round3-agent-reader-final.log` | 55 | 0 | 0 |
| `round3-gallery-final.log` | 1 | 0 | 0 |

**Round-3 totals:** 420 behavior/storage/navigation tests passed, 0 failed,
4 skipped; gallery: 1 passed, 0 failed, 3 PNGs. All final commands exited 0.
Class counts match the Round-2 table above except the regression class now has
33 passing tests. The four skips remain the optional history-index measurement
and three opt-in Markdown measurements/sample captures. No unrelated test failed.

The last regression run strengthens the shared native Find assertion: the
highlight's glyph rectangle must be inside both the transcript viewport and
any inner card scroll area. All 33 tests passed again with these assertions;
production files were unchanged after the full final runs. The corpus covers
75 tool-card and 90 Markdown/timeline comparisons, **165 exact comparisons**.

Regenerated and visually inspected all three `validation/gallery-round3/`
images: `transcript-light.png`, `transcript-dark.png` (760×800 points) and
`transcript-narrow.png` (360×800). The ordered-list marker `2.` is highlighted
in each; Real's heading Copy control fits inside the narrow viewport; the edit
preview retains the literal marker and both changed tails. No new layout
defect was observed in these scenes.

The existing build root was reused, no clone directories remained and no named
result bundle was requested. The owned lane lock was released. No helper or
wire behavior changed, so helper/wire suites were not required. `git diff --check`
passed. No assigned issue or owner decision remains unresolved. The lead retains
independent review, the merged full gate and merge.

## Round 4: clamped Find focus and remaining row projections (2026-10-18)

Reviewed base: `3d717e40bbae7a70325434b130ac418a305e7c3f`. The reported focus
loss and saved-user projection mismatch are both confirmed and fixed.
`round4-failing-first.log` ran against that commit's production code:
**33 passed, 5 failed**, 64 assertion failures, exit 65. All existing regressions
passed; the five new tests failed.

### R4-1: reconciliation drops the selected highlight — confirmed and fixed

`testSavedUserFindCountsOnlyDisplayedTextAndKeepsPreviousHighlight` creates two
saved user messages, each containing `user` once, searches and presses Previous.
Before either fix, it counted three matches after reconciling the first row
instead of two and failed to highlight the second user message. The extra
occurrence came from the invisible export heading.

`testReconciliationAdoptsClampedFocusWithoutNewNavigation` independently supplies
overcounts, so fixing the projection cannot mask the focus regression. It
selects occurrence 1, reconciles to one displayed occurrence and requires the
existing focus to adopt occurrence 0 with the same serial, no pending reveal,
the same viewport origin and the correct native highlight. Failing-first excerpt:

```text
XCTAssertEqual failed: ("nil") is not equal to ("Optional(0)")
XCTAssertEqual failed: ("nil") is not equal to ("Optional(2)") - Count adoption creates no navigation request
XCTAssertEqual failed: ("nil") is not equal to ("Optional("user 2")")
```

Only reconciliation of the selected record permits occurrence adoption. The
publication still requires an existing Find focus with the same query and
record; it keeps its serial. A control clears that focus before another count
change and verifies that reconciliation cannot create one. Refresh, Next/Previous
races and reader-position controls from prior rounds remain in the regression class.

### R4-2: saved user text includes an export heading — confirmed and fixed

Saved user/system/notice rows now use `TranscriptMessage.project`, the same
display projection used when reopening them, instead of `ConversationContent.text`.
This retains literal Markdown, native display overrides, joined text blocks and
image-only labels. The saved-source/export function remains unchanged.

`testUserStatusAndSummaryProjectionEqualsNativeRowsSavedAndLive` compares actual
native row text for six sources across user, system, notice, summary and unknown
kind rows, plus image-only, multi-block and native-display cases: **67 comparisons**.
The first failing run includes the unwanted `## user`/`## system` envelopes.
`testSidePaneProjectionEqualsItsSavedAndLiveUserRows` mounts an actual `SidePaneView`
and adds **five comparisons** of its saved/live user rows; it passed once the
common projection was fixed, requiring no side-specific production change.

The intermediate `round4-fixed.log` records **37 passed, 1 failed**. Its only
failure was the old test equating user Find text with export text. That assertion
was updated to require literal user text and separately verify the exact unchanged
`## user` export. It is not recorded as an unrelated failure or hidden by a skip.

### Nearby row instances confirmed by the expanded corpus

All fixes below affect Find's projection/disclosure; they preserve journal bytes,
source export and the native row's existing rendering policy.

- **Compactions:** the old projection searched `## Compaction` plus raw Markdown,
  whereas the actual saved row renders `Conversation summary:` plus the summary.
  `testSavedCompactionFindUsesTheNativeSummaryAndOpensIt` compares the history
  reader's row with the projection, searches `alpha beta` across emphasis and
  requires a visible highlight. Initially there were no hits. A shared
  `TranscriptMessage.compactionText` keeps the saved display prefix identical;
  Find renders with the native summary style and opens the matching summary.
- **Agent deliveries:** `testAgentDeliveryProjectionEqualsNativeCardsSavedAndLive`
  compares actual headings, badges and Markdown bodies for seven parent/child
  delivery kinds plus an unsaved delegated task (**15 comparisons**). It exposed
  a spurious trailing newline for absent notes; empty pieces are now omitted.
- **Managed tasks versus ordinary user messages:**
  `testSavedManagedRowsKeepTheirDisplayedAgentAndUserText` found that saved search
  omitted the visible `Parent → Sub-agent 3` identity and stripped Markdown from
  a later ordinary user row. `round4-managed-first.log`: **1 passed, 1 failed**,
  three assertions, exit 65. The history index identifies the first user only;
  loaded agent rows keep their display-only attribution overlay. The test covers
  both presented and unloaded later user rows, plus the first task's rendered prose.
- **Unavailable agent attribution:**
  `testAgentDeliveryNotesAndUnavailableAttributionMatchTheCard` compares valid
  result/error notes and two unavailable-attribution cases (**six comparisons**).
  `round4-agent-fallback-first.log`: **0 passed, 1 failed**, four assertions,
  exit 65: search returned `hidden delivery transport` or nothing while the row
  displayed its attribution notice. The native card and projection now share
  that existing notice string; attribution checks remain intact.
- **Metadata and execution rows:**
  `testRemainingRowKindsProjectTheirNativeContent` compares saved/live failure,
  branch, version, request-info, execution and tool-result bodies (**12 comparisons**).
  It caught missing visible details, hidden canonical text and unrendered execution
  parts. `testBranchSearchUsesItsDisplayedDetailWithoutAnExportHeading` separately
  exercises a real branch record and checks that source export still has `## Edit`.
  `round4-other-rows-first.log`: **0 passed, 2 failed**, 11 assertions, exit 65.
  Projection now follows each row's displayed body/detail fields; the branch
  search no longer adds the export heading.
- **Execution disclosure:** `testExecutionFindUsesAndOpensItsRenderedTimeline`
  initially found no `alpha beta` hit in a formatted execution part
  (`round4-execution-first.log`: **0 passed, 1 failed**, exit 65). Find now uses
  the existing per-segment projection and opens the execution body for the hit.
  A further adversarial check caught an omission in that initial fix: the
  execution's visible caption was missing, including when there was no timeline
  body. `testExecutionCaptionsStaySearchableWithAndWithoutTimelineBodies` compares
  explicit/fallback captions, with/without a body, saved/live (**eight comparisons**).
  `round4-caption-first.log`: **0 passed, 1 failed**, eight assertions, exit 65:
  `""` differed from `"Fallback caption"`, and `"Body alpha beta"` omitted the
  native caption above it. The projection now includes the actual caption and
  preserves it for bodyless executions. This self-review correction was made
  before the final suites; their runner waited outside the shared lane lock.
- **Standalone versus paired tool results:**
  `testStandaloneToolResultsMatchTheirNativeRowsSavedAndLive` compares native
  generic/agent receipt rows and requires visible formatted-phrase highlights
  in saved and no-journal readers (**four comparisons**). The native row planner
  determines which presented receipts stand alone as Markdown; paired receipts
  retain their card representation and record identity.
  `testPairedToolResultsKeepTheirLiteralCardText` is a passing control: its generic
  I/O card matches `**alpha** beta` and rejects the invisible contiguous `alpha beta`.
  `round4-result-rows-first.log`: **1 passed, 1 failed**, exit 65. The standalone
  projection and its fold-opening predicate were both corrected.

`round4-fixed-complete.log` passed the first **44 tests**; after adding the result-row
cases, `round4-fixed-all.log` passed **46 tests**, zero failures. The complete
corpus initially had 277 exact native/projection comparisons; the execution-caption
check brings it to **285**: the previous 165 plus 120 for remaining rows and
containers. It compares message bodies, displayed
details/notes and existing searchable file/agent identities; action buttons and
accounting chrome are not message payloads.

### Round-4 adversarial self-review

Re-read the whole branch's production diff from
`141666ca479184d10a9791754d4c91df456599d8`, including previous copy, truncation,
raw-mode, Markdown-builder and navigation changes. The expanded probes above
were added before their corresponding nearby fixes.

Checked focus publication against nil/external focus, stale queries, count growth
and reduction, an unchanged serial, newer reader steps during refresh, pending
reveals and changed result indexes. Occurrence adoption is explicitly confined
to reconciliation, so a refresh cannot adopt an unrelated selection or create
navigation focus. Checked saved/source separation, native display overrides,
image-only labels, ordinary-side mounting, delegated-task identity, invalid agent
metadata, receipt pairing and folded summary/execution/result text. The planner
runs only over the supplied presented rows and only when they contain receipts;
search snapshot, byte/window bounds, cancellation and index ownership stay intact.

Rechecked parsed heading/source indexes, nested containers, CR/CRLF/Unicode
offsets, complete versus explicitly truncated edit arguments, native list markers,
per-segment raw state, bounded parsing caches and local Markdown builders. No
helper/wire changes, new network calls, credentials, preferences or vault writes
were introduced. The compaction prefix and unavailable-attribution note were
shared without changing their visible strings. Separate lead review and the
merged full gate remain required.

### Round-4 mutation evidence

Each mutation ran the named regression methods in a fresh native test process,
exited 65, failed only its expected methods and restored the fixed file in
`finally`. The two result-row runs also kept their paired-card control passing.

| Log | Deliberately broken fix | Passed | Failed | Assertion failures |
| --- | --- | ---: | ---: | ---: |
| `round4-mutation-focus-adoption.log` | Disable selected-occurrence adoption | 0 | 1 | 5 |
| `round4-mutation-user-projection.log` | Restore exported user/status text | 0 | 3 | 37 |
| `round4-mutation-summary-projection.log` | Restore raw/exported summaries | 0 | 2 | 10 |
| `round4-mutation-summary-disclosure.log` | Leave matching summaries folded | 0 | 1 | 3 |
| `round4-mutation-metadata-rows.log` | Omit native detail fields | 0 | 1 | 8 |
| `round4-mutation-branch-heading.log` | Restore the branch export heading | 0 | 1 | 1 |
| `round4-mutation-execution-projection.log` | Ignore execution timeline parts | 0 | 2 | 3 |
| `round4-mutation-execution-disclosure.log` | Leave matching executions folded | 0 | 1 | 3 |
| `round4-mutation-agent-separator.log` | Add the absent-note newline | 0 | 1 | 15 |
| `round4-mutation-agent-fallback.log` | Search hidden/unavailable agent content | 0 | 1 | 4 |
| `round4-mutation-agent-overlay.log` | Drop completed agent display overlays | 0 | 1 | 1 |
| `round4-mutation-managed-user-mode.log` | Render every managed user message | 0 | 1 | 2 |
| `round4-mutation-result-row-context.log` | Ignore standalone-result presentation | 1 | 1 | 7 |
| `round4-mutation-result-disclosure.log` | Match standalone folds against raw Markdown only | 1 | 1 | 3 |
| `round4-mutation-execution-caption.log` | Drop the execution caption with/without a timeline body | 1 | 2 | 10 |

The source/display mutation is distinct from the focus mutation: the latter
uses controlled overcounts and still fails with the saved-user projection fixed.
Projection and disclosure mutations independently kill the summary, execution
and standalone-result pane regressions.

All **15 mutations** were detected. After the last caption correction,
`round4-caption-fixed.log` passed its three selected methods; the caption mutation
failed two and kept the execution-body Find control passing. The fixed source
was restored before every final run below.

### Round-4 final validation

All seven final commands exited **0**, with **613 passed, 0 failed and 5 skipped**.
The skips are existing opt-in measurements/captures, listed below; no unrelated
failure occurred. Logs and companion command/count JSON records are under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript/validation/`.

| Suite | Passed | Failed | Skipped | Text log |
| --- | ---: | ---: | ---: | --- |
| Regression class | 47 | 0 | 0 | `round4-regression-final.log` |
| 46 affected classes | 456 | 0 | 5 | `round4-affected-final.log` |
| Timeline behavior | 30 | 0 | 0 | `round4-timeline-final.log` |
| Subagent Markdown | 19 | 0 | 0 | `round4-agent-markdown-final.log` |
| Subagent reader | 55 | 0 | 0 | `round4-agent-reader-final.log` |
| App wire/page projection | 4 | 0 | 0 | `round4-wire-page-final.log` |
| Gallery | 2 | 0 | 0 | `round4-gallery-final.log` |

The five skips in `round4-affected-final.log`:

- `HistoryIndexFilesTests.testTheIndexOfALongChat`: requires `PI_PERF_HISTORY_JOURNAL`.
- `InlineSkillPillTests.testCaptureSkillPillLooks`: requires `PI_APP_UI_SCREENSHOT_ROOT`.
- `MarkdownTextSurfaceTests.testMeasureLinePitches` and `testMeasureTokenCostOnOpenLists`: run-on-request measurements.
- `MarkdownTextSurfaceTests.testRenderSampleForReview`: requires `PI_MARKDOWN_SNAPSHOT_DIR`.

Class counts within the combined affected run (pass/fail/skip):

| Class | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| `ChatFileLinkTests` | 7 | 0 | 0 |
| `ContentSearchTests` | 7 | 0 | 0 |
| `FullDisplayTests` | 4 | 0 | 0 |
| `HardeningTests` | 12 | 0 | 0 |
| `HistoryExtentTests` | 25 | 0 | 0 |
| `HistoryIndexFilesTests` | 3 | 0 | 1 |
| `HistoryReaderCheckpointTests` | 7 | 0 | 0 |
| `HistoryReaderStateTailTests` | 4 | 0 | 0 |
| `InlineSkillPillTests` | 14 | 0 | 1 |
| `MarkdownSourceReconciliationTests` | 7 | 0 | 0 |
| `MarkdownStreamingCorrectnessTests` | 9 | 0 | 0 |
| `MarkdownStreamingTests` | 2 | 0 | 0 |
| `MarkdownTextSurfaceTests` | 6 | 0 | 3 |
| `MessageDetailTests` | 9 | 0 | 0 |
| `NativeMarkdownSizingTests` | 4 | 0 | 0 |
| `NativeMarkdownSurfaceStreamingTests` | 4 | 0 | 0 |
| `NativeMarkdownViewportTests` | 4 | 0 | 0 |
| `NativeTranscriptDocumentTests` | 10 | 0 | 0 |
| `NativeTranscriptSafetyTests` | 5 | 0 | 0 |
| `NativeTranscriptTests` | 5 | 0 | 0 |
| `ReplySourceTests` | 12 | 0 | 0 |
| `ResponseChronologyTests` | 14 | 0 | 0 |
| `ResponseTimelinePresentationTests` | 13 | 0 | 0 |
| `SendImmediacyTests` | 14 | 0 | 0 |
| `SideRowPresentationTests` | 1 | 0 | 0 |
| `StableToolPresentationTests` | 10 | 0 | 0 |
| `StorageTruthTests` | 11 | 0 | 0 |
| `SubagentSteeringPresentationTests` | 10 | 0 | 0 |
| `SubagentTranscriptTests` | 11 | 0 | 0 |
| `TimelineStreamingFastPathTests` | 2 | 0 | 0 |
| `ToolCallSummaryTests` | 4 | 0 | 0 |
| `TranscriptActivityTests` | 11 | 0 | 0 |
| `TranscriptDisclosureTests` | 15 | 0 | 0 |
| `TranscriptFindTests` | 11 | 0 | 0 |
| `TranscriptMarkdownTests` | 9 | 0 | 0 |
| `TranscriptNativeMessageKindBehaviourTests` | 18 | 0 | 0 |
| `TranscriptNativePaneBehaviourTests` | 16 | 0 | 0 |
| `TranscriptNativeRowBehaviourTests` | 19 | 0 | 0 |
| `TranscriptNativeWorkBehaviourTests` | 21 | 0 | 0 |
| `TranscriptPageStressTests` | 24 | 0 | 0 |
| `TranscriptPagingTests` | 6 | 0 | 0 |
| `TranscriptRevealTests` | 10 | 0 | 0 |
| `TranscriptSwitchFirstFrameTests` | 1 | 0 | 0 |
| `TranscriptWorkRowTests` | 15 | 0 | 0 |
| `TurnAccountingTests` | 13 | 0 | 0 |
| `WorkspaceTests` | 17 | 0 | 0 |

Exact final test commands (run from this worktree):

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript

# round4-regression-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests

# round4-affected-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ContentSearchTests \
  -only-testing:PiAppTests/HardeningTests \
  -only-testing:PiAppTests/HistoryIndexFilesTests \
  -only-testing:PiAppTests/HistoryReaderCheckpointTests \
  -only-testing:PiAppTests/MarkdownTextSurfaceTests \
  -only-testing:PiAppTests/NativeMarkdownSizingTests \
  -only-testing:PiAppTests/NativeMarkdownSurfaceStreamingTests \
  -only-testing:PiAppTests/StableToolPresentationTests \
  -only-testing:PiAppTests/StorageTruthTests \
  -only-testing:PiAppTests/TranscriptActivityTests \
  -only-testing:PiAppTests/TranscriptDisclosureTests \
  -only-testing:PiAppTests/TranscriptFindTests \
  -only-testing:PiAppTests/TranscriptMarkdownTests \
  -only-testing:PiAppTests/TranscriptNativeWorkBehaviourTests \
  -only-testing:PiAppTests/TranscriptPageStressTests \
  -only-testing:PiAppTests/TranscriptRevealTests \
  -only-testing:PiAppTests/TranscriptWorkRowTests \
  -only-testing:PiAppTests/WorkspaceTests \
  -only-testing:PiAppTests/ReplySourceTests \
  -only-testing:PiAppTests/MarkdownSourceReconciliationTests \
  -only-testing:PiAppTests/TranscriptNativePaneBehaviourTests \
  -only-testing:PiAppTests/TranscriptSwitchFirstFrameTests \
  -only-testing:PiAppTests/NativeTranscriptTests \
  -only-testing:PiAppTests/MarkdownStreamingCorrectnessTests \
  -only-testing:PiAppTests/MarkdownStreamingTests \
  -only-testing:PiAppTests/NativeMarkdownViewportTests \
  -only-testing:PiAppTests/NativeTranscriptDocumentTests \
  -only-testing:PiAppTests/NativeTranscriptSafetyTests \
  -only-testing:PiAppTests/ResponseTimelinePresentationTests \
  -only-testing:PiAppTests/TimelineStreamingFastPathTests \
  -only-testing:PiAppTests/HistoryReaderStateTailTests \
  -only-testing:PiAppTests/HistoryExtentTests \
  -only-testing:PiAppTests/TranscriptNativeRowBehaviourTests \
  -only-testing:PiAppTests/TranscriptNativeMessageKindBehaviourTests \
  -only-testing:PiAppTests/ResponseChronologyTests \
  -only-testing:PiAppTests/SendImmediacyTests \
  -only-testing:PiAppTests/ToolCallSummaryTests \
  -only-testing:PiAppTests/FullDisplayTests \
  -only-testing:PiAppTests/TurnAccountingTests \
  -only-testing:PiAppTests/InlineSkillPillTests \
  -only-testing:PiAppTests/ChatFileLinkTests \
  -only-testing:PiAppTests/TranscriptPagingTests \
  -only-testing:PiAppTests/MessageDetailTests \
  -only-testing:PiAppTests/SubagentTranscriptTests \
  -only-testing:PiAppTests/SubagentSteeringPresentationTests \
  -only-testing:PiAppTests/SideRowPresentationTests

# round4-timeline-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptNativeTimelineBehaviourTests

# round4-agent-markdown-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentMarkdownTests

# round4-agent-reader-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentReaderTests

# round4-wire-page-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptWirePageTests

# round4-gallery-final.log
TEST_RUNNER_PI_TRANSCRIPT_BUG_GALLERY="$PI_BUILD_ROOT/validation/gallery-round4" \
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugGalleryTests
```

Each native run acquired the shared `full-lane.lock` with an owner containing
`a130-transcript`, its PID and timestamp, and released only that owned lock in
`finally`, including intentional failures. Serial-lane classes ran alone; no
`LifecycleHelperTests` mixing, extra DerivedData root or named result bundle was
used. Only generated journals, in-memory fixture vaults and isolated test-host
windows were used. `scripts/test-macos.sh` regenerated the project on each run;
no files or project registrations were added.

Exact earlier commands are below, with identical invocations grouped by log
name. They use the same exported `PI_BUILD_ROOT` and lock wrapper. Each mutation
was applied only for its named run and restored in `finally`.

```sh

# round4-failing-first.log, round4-fixed.log, round4-fixed-complete.log, round4-fixed-all.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests

# round4-managed-first.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testSavedManagedRowsKeepTheirDisplayedAgentAndUserText \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testSidePaneProjectionEqualsItsSavedAndLiveUserRows

# round4-agent-fallback-first.log, round4-mutation-agent-fallback.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testAgentDeliveryNotesAndUnavailableAttributionMatchTheCard

# round4-other-rows-first.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testRemainingRowKindsProjectTheirNativeContent \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testBranchSearchUsesItsDisplayedDetailWithoutAnExportHeading

# round4-execution-first.log, round4-mutation-execution-disclosure.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testExecutionFindUsesAndOpensItsRenderedTimeline

# round4-result-rows-first.log, round4-mutation-result-disclosure.log, round4-mutation-result-row-context.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testStandaloneToolResultsMatchTheirNativeRowsSavedAndLive \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testPairedToolResultsKeepTheirLiteralCardText

# round4-caption-first.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testExecutionCaptionsStaySearchableWithAndWithoutTimelineBodies

# round4-caption-fixed.log, round4-mutation-execution-caption.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testExecutionCaptionsStaySearchableWithAndWithoutTimelineBodies \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testRemainingRowKindsProjectTheirNativeContent \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testExecutionFindUsesAndOpensItsRenderedTimeline

# round4-mutation-agent-overlay.log, round4-mutation-managed-user-mode.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testSavedManagedRowsKeepTheirDisplayedAgentAndUserText

# round4-mutation-agent-separator.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testAgentDeliveryProjectionEqualsNativeCardsSavedAndLive

# round4-mutation-branch-heading.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testBranchSearchUsesItsDisplayedDetailWithoutAnExportHeading

# round4-mutation-execution-projection.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testRemainingRowKindsProjectTheirNativeContent \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testExecutionFindUsesAndOpensItsRenderedTimeline

# round4-mutation-focus-adoption.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testReconciliationAdoptsClampedFocusWithoutNewNavigation

# round4-mutation-metadata-rows.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testRemainingRowKindsProjectTheirNativeContent

# round4-mutation-summary-disclosure.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testSavedCompactionFindUsesTheNativeSummaryAndOpensIt

# round4-mutation-summary-projection.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testSavedCompactionFindUsesTheNativeSummaryAndOpensIt \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testUserStatusAndSummaryProjectionEqualsNativeRowsSavedAndLive

# round4-mutation-user-projection.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testSavedUserFindCountsOnlyDisplayedTextAndKeepsPreviousHighlight \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testUserStatusAndSummaryProjectionEqualsNativeRowsSavedAndLive \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testSidePaneProjectionEqualsItsSavedAndLiveUserRows
```

`TranscriptBugGalleryTests` regenerated six images under
`$PI_BUILD_ROOT/validation/gallery-round4`: `transcript-light.png`,
`transcript-dark.png`, `transcript-narrow.png`, `rows-light.png`, `rows-dark.png`,
and `rows-narrow.png`. All six were opened and visually inspected. The new scene
shows the selected second user occurrence, rendered expanded summary, notice and
agent delivery. Highlights remain visible in both appearances and at 360 points;
body text and controls fit, with the existing compact metadata ellipsis at narrow
width. The prior scene still shows both edit tails, list-marker highlight and an
unclipped heading Copy control.

`git diff --check` passed. No clone directories remain under this build root.
No helper or wire behavior changed, so the full helper and Python wire/concurrent/
acceptance lanes were not rerun; `TranscriptWirePageTests` covers the app model
projection touched here. No assigned issue or owner decision remains unresolved.
The lead retains independent review, the merged full gate and merge.


## Round 5: planner-owned recovery presentation (2026-10-18)

Base: `51f6b9d2e6eedf32b041b641b805e9bb9ff185dd`. Work remains on
`dev/a130-transcript` in its assigned worktree and build root. The review finding
is confirmed and fixed. The projection now consumes actual
`TaskTranscriptPlan.rows` output, indexed by retained message identity, for
saved, captured and unsaved messages. It does not independently promote a
persisted system request ledger to an assistant response.

### R5-1: orphan request-ledger text and reasoning — confirmed and fixed

`testOrphanLedgerProjectionEqualsPlannedNativeRowsSavedAndLive` compares the
projection with mounted native planned rows for missing/completed/interrupted
terminals, timeline/legacy content and rendered/raw modes, both saved and live:
24 exact comparisons. Against the Round-4 production code,
`round5-failing-first-corpus.log` reports **0 passed, 1 failed**, with 24 failing
assertions. Representative excerpt:

```text
XCTAssertEqual failed: ("") is not equal to ("alpha beta
Visible gamma delta and site")
```

`testFindSearchesOrphanLedgerTextAndReasoningAfterRecovery` exercises the real
pane, reopening a generated journal and then using its no-journal live path.
It finds and visibly highlights formatted reasoning, formatted answer text and
the raw link destination. Its six missing-hit assertions failed before the fix
in `round5-failing-first.log`. The original first corpus helper also reported
six missing legacy-block keys; the helper was corrected, then the unchanged
production code was rerun to obtain the independent 24-assertion failure above.
The planner-bypass mutation makes both tests fail again.

### Nearby instances and boundary checks

- **Hidden recovery rows:** `testRecoverySearchFollowsPlannerSuppressionAndDiscardedRevisions`
  covers superseded ledgers and cleared presentation updates in live, saved
  captured and cold search. A first attempt that planned each record separately
  failed three assertions (`round5-planner-first-fixed.log`: 49 passed, 1 failed).
  The projection now plans rows together, as the transcript does.
- **Recovery captions, terminal notices and checkpoints:**
  `testRecoveryPlannerCorpusMatchesSavedAndLiveSearch` adds 18 exact native
  comparisons for unfinished/adopted executions, suppressed duplicate checkpoints
  and unsupported legacy ledgers. `round5-recovery-context-first-valid.log`
  failed 13 assertions (0 passed, 1 failed), including a missing `Completion not
  recorded`, a missing ` · no terminal receipt`, and a visible adopted caption
  replaced by its old caption. Search and page decoding now share
  `displayedMessage`; the existing terminal-note literal is shared with the
  native view. The earlier `round5-recovery-context-first.log` also exposed an
  invalid checkpoint fixture; its v2 source/protected/kept IDs were corrected
  before the valid failing-first rerun. No production fix was made between
  those two fixture runs.
- **Paired tool receipts:** `testPlannedPairedToolPayloadsMatchSavedAndLiveSearch`
  compares actual native generic, bash, read, edit and subagent cards, adjacent
  and separated by 40 notices, against live/saved-captured/cold search (30 exact
  comparisons). `round5-paired-corpus-first.log` failed 11 assertions in the
  initial adjacent corpus: duplicated output, different saved card formatting,
  and an edit transport receipt absent from the card. Card payloads now come
  from the native card model; the issuing source owns the input and its retained
  receipt owns displayed output. The planner determines whether a receipt is
  part of a card or a separate row.
- **Decoding-window context:** `testColdPlannerContextCrossesDecodeRuns` failed
  twice in `round5-cross-run-first.log` (0 passed, 1 failed): a hidden distant
  ledger was found, and a literal distant receipt was missed. The private,
  rebuildable history offset index now retains call/result/operation links.
  Search reads exact active-branch peers when they are outside the bounded
  decoding run, then uses the same planner. It preserves receipt IDs and search
  positions. `testPlannerDependencyIndexKeepsReusedCallsAndActiveBranchesSeparate`
  verifies reused call IDs, operation links and abandoned-branch exclusion.
- **Literal provider call IDs:** self-review of that new link index found SQLite
  binding stopped at embedded NULs. `testPlannerDependencyIndexKeepsLiteralCallIDs`
  failed once before the fix (`round5-call-id-first.log`), selecting
  `["second-result", "second"]` instead of `["first"]`. Explicit UTF-8 byte
  lengths preserve the complete call ID. This is a correction to the new index,
  not a change to the journal format.
- **Unsupported tool timelines:** self-review found the initial distant-receipt
  optimization always removed output from the issuer. For an unsupported
  timeline the native planner shows both the legacy card and a separate receipt.
  `testUnsupportedToolTimelineKeepsBothNativeRecoveryRowsAcrossRuns` failed the
  cold issuer comparison (`round5-legacy-context-first.log`: 1 passed, 1 failed).
  It now adds six exact native comparisons; the optimization consults the actual
  paired plan before omitting output.
- **Older operation identities:** `testColdCompactionContextUsesBothRetainedOperationIdentityForms`
  tests top-level and nested compaction operation IDs across 40 intervening rows.
  The nested cold case failed (`round5-operation-id-first.log`: 1 passed,
  1 failed, `nested=true, presented=false`). New index metadata now uses the same
  nested-ID fallback as `TranscriptMessage.project`; existing adoption behavior
  is unchanged.
- **Captured reader state:** `testSearchKeepsCapturedOrphanPresentationWhenFinalReplyIsAppended`
  appends a final reply after the display snapshot. The current pane retains its
  visible orphan content; a reopened snapshot suppresses it. This is a control
  for the new complete-row snapshot overlay, with a mutation below.

The corpus gains 78 native payload comparisons, for **363 total** across the
branch's Markdown/raw, tool, user/status, summary, agent and recovery cases.
The new tests are generated fixtures with no live provider or real user data.

### Adversarial self-review

Reviewed the whole production branch diff against
`141666ca479184d10a9791754d4c91df456599d8`, including parsed heading offsets and
CR/CRLF handling, narrow Copy geometry, literal truncation markers, shared
Markdown rendering, source disclosure, refresh/navigation focus identity,
reconciliation, native tool disclosure and all row projections. Round-5 review
specifically exercised active versus abandoned branches, repeated/literal call
IDs, legacy/future timelines, overwritten presentation receipts, distant
operation identities and a saved journal growing after the reader snapshot.
The confirmed issues from this review are listed above and fixed.

The search keeps its existing 5,000-source window, 100-hit page and bounded
primary decoding runs. Extra context is obtained from indexed retained peers,
not an unbounded body scan. Distant tool outputs are processed one at a time
rather than retained across a wide tool round. Cancellation and captured-prefix
checks remain in place; source search/copy and journal schema are unchanged.

An intermediate implementation combined planning and collecting large enum rows
in one initializer and exhausted the Debug cooperative-worker stack. This was
not an unrelated test failure: `round5-context-fixed.log` exited 65 with 47 passed
and five crashed methods; an attempted metrics shortcut still exited 65 with
48 passed and four crashes (`round5-context-fixed-metrics.log`). Test-host crash
stacks showed `TaskTranscriptPlan.rows`/`TranscriptBlock.init`/`___chkstk_darwin`
under `ConversationContent.Presentation.init`. The shortcut was discarded.
Separating the planner invocation from collecting its large row values fixed
those failures without changing the planner; `round5-context-fixed-stack.log`
passed all 52 tests then present, followed by 53, 55 and finally 58 passing
regression methods as the corpus grew. The text-log parser counts XCTest
assertion failures only, so its zero `failed` for those two crashed runs must
not be mistaken for success; their exit status and crashed methods are recorded
here explicitly.

The first crashed run named `testFindMatchesFormattedLiveReasoning`,
`testFindMatchesViewRawInUnsavedReply`,
`testPlannedPairedToolPayloadsMatchSavedAndLiveSearch`,
`testRecoveryPlannerCorpusMatchesSavedAndLiveSearch` and
`testRecoverySearchFollowsPlannerSuppressionAndDiscardedRevisions`. The metrics
attempt crashed the same set except formatted live reasoning. All five pass in
the final regression run.


### Round-5 mutation evidence

Each mutation was applied independently and restored in `finally` before the
next run. All named results below require a running XCTest assertion failure,
not just a nonzero build exit. The first legacy-tool mutation left an unused
local and was rejected by the warnings-as-errors build
(`round5-mutation-legacy-tool.log`); it is **not** counted. The corrected
`legacy-tool-pairing` mutation changes the pairing decision while leaving valid
code and fails the intended native comparison.

| Mutation (log suffix) | Regression method(s) | Passed / failed |
| --- | --- | --- |
| `planner` | `testFindSearchesOrphanLedgerTextAndReasoningAfterRecovery`, `testOrphanLedgerProjectionEqualsPlannedNativeRowsSavedAndLive` | 0 / 2 |
| `plan-context` | `testRecoveryPlannerCorpusMatchesSavedAndLiveSearch`, `testRecoverySearchFollowsPlannerSuppressionAndDiscardedRevisions` | 0 / 2 |
| `saved-presentation` | `testRecoveryPlannerCorpusMatchesSavedAndLiveSearch` | 0 / 1 |
| `terminal-notice` | `testRecoveryPlannerCorpusMatchesSavedAndLiveSearch` | 0 / 1 |
| `paired-output` | `testPlannedPairedToolPayloadsMatchSavedAndLiveSearch` | 0 / 1 |
| `cross-run` | `testColdPlannerContextCrossesDecodeRuns`, `testPlannedPairedToolPayloadsMatchSavedAndLiveSearch` | 0 / 2 |
| `literal-call-id` | `testPlannerDependencyIndexKeepsLiteralCallIDs` | 0 / 1 |
| `legacy-tool-pairing` | `testUnsupportedToolTimelineKeepsBothNativeRecoveryRowsAcrossRuns` | 0 / 1 |
| `nested-operation-id` | `testColdCompactionContextUsesBothRetainedOperationIdentityForms` | 0 / 1 |
| `captured-presentation` | `testSearchKeepsCapturedOrphanPresentationWhenFinalReplyIsAppended` | 0 / 1 |

All ten semantic mutations were caught (13 failing test invocations).


### Round-5 exact commands

All runs use this workstream's build root and the shared full-lane lock, acquired
with an owner token and released in `finally`, including failing tests and
mutations. No named xcresult bundle was requested; the text logs below are the
evidence. The native script regenerates the project and removes old automatic
result bundles. The installed app was never launched.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript
```

The following commands are the exact native invocations for failing-first,
intermediate and mutation runs. Log names share
`$PI_BUILD_ROOT/validation/` and the `.log` extension.

```sh
# round5-adversarial-fixed.log
# round5-context-boundaries-fixed.log
# round5-context-fixed-metrics.log
# round5-context-fixed-stack.log
# round5-context-fixed.log
# round5-planner-first-fixed.log
# round5-regression-fixed.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests

# round5-call-id-first.log
# round5-mutation-literal-call-id.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testPlannerDependencyIndexKeepsLiteralCallIDs

# round5-cross-run-first.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testColdPlannerContextCrossesDecodeRuns

# round5-failing-first-corpus.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testOrphanLedgerProjectionEqualsPlannedNativeRowsSavedAndLive

# round5-failing-first.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testOrphanLedgerProjectionEqualsPlannedNativeRowsSavedAndLive \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFindSearchesOrphanLedgerTextAndReasoningAfterRecovery \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testRecoverySearchFollowsPlannerSuppressionAndDiscardedRevisions

# round5-legacy-context-first.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testUnsupportedToolTimelineKeepsBothNativeRecoveryRowsAcrossRuns \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testPlannerDependencyIndexKeepsLiteralCallIDs

# round5-mutation-captured-presentation.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testSearchKeepsCapturedOrphanPresentationWhenFinalReplyIsAppended

# round5-mutation-cross-run.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testColdPlannerContextCrossesDecodeRuns \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testPlannedPairedToolPayloadsMatchSavedAndLiveSearch

# round5-mutation-legacy-tool-pairing.log
# round5-mutation-legacy-tool.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testUnsupportedToolTimelineKeepsBothNativeRecoveryRowsAcrossRuns

# round5-mutation-nested-operation-id.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testColdCompactionContextUsesBothRetainedOperationIdentityForms

# round5-mutation-paired-output.log
# round5-paired-corpus-first.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testPlannedPairedToolPayloadsMatchSavedAndLiveSearch

# round5-mutation-plan-context.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testRecoverySearchFollowsPlannerSuppressionAndDiscardedRevisions \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testRecoveryPlannerCorpusMatchesSavedAndLiveSearch

# round5-mutation-planner.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testOrphanLedgerProjectionEqualsPlannedNativeRowsSavedAndLive \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFindSearchesOrphanLedgerTextAndReasoningAfterRecovery

# round5-mutation-saved-presentation.log
# round5-mutation-terminal-notice.log
# round5-recovery-context-first-valid.log
# round5-recovery-context-first.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testRecoveryPlannerCorpusMatchesSavedAndLiveSearch

# round5-operation-id-first.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testColdCompactionContextUsesBothRetainedOperationIdentityForms \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testUnsupportedToolTimelineKeepsBothNativeRecoveryRowsAcrossRuns

```


### Round-5 final validation

After every mutation was restored: **793 passed, 0 failed, 8 skipped** across
74 focused classes. Serial classes ran alone. There were no unexplained final
failures. The merged full release gate remains the lead's responsibility.

| Final text log | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| `round5-regression-final.log` | 58 | 0 | 0 |
| `round5-affected-final.log` | 617 | 0 | 7 |
| `round5-timeline-final.log` | 30 | 0 | 0 |
| `round5-agent-markdown-final.log` | 19 | 0 | 0 |
| `round5-agent-reader-final.log` | 55 | 0 | 0 |
| `round5-wire-page-final.log` | 4 | 0 | 0 |
| `round5-history-edge-timing-final.log` | 2 | 0 | 0 |
| `round5-history-edit-final.log` | 3 | 0 | 0 |
| `round5-inline-timing-final.log` | 1 | 0 | 0 |
| `round5-streaming-serial-final.log` | 1 | 0 | 1 |
| `round5-gallery-final.log` | 3 | 0 | 0 |

Seven skips are explicit opt-in checks: retained-journal index/open measurements,
skill-pill captures, Markdown line-pitch/token-cost measurements, Markdown sample
capture and the 70-turn wire performance probe. The eighth is
`TranscriptStreamingSerialTests.testAReplyCountsAsReadOnlyOnceItsEndHasBeenOnScreen`:
“A receipt needs this app's own key, unoccluded window; this desktop cannot
provide one.” That environment-dependent check remains unverified here; it is
not counted as a pass. Its class's other test passed. All requested recovery,
projection and Find regressions executed and passed.

Exact final commands (same build root and lock ownership wrapper as above):

```sh
# round5-regression-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests

# round5-affected-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ContentSearchTests \
  -only-testing:PiAppTests/HardeningTests \
  -only-testing:PiAppTests/HistoryIndexFilesTests \
  -only-testing:PiAppTests/HistoryReaderCheckpointTests \
  -only-testing:PiAppTests/MarkdownTextSurfaceTests \
  -only-testing:PiAppTests/NativeMarkdownSizingTests \
  -only-testing:PiAppTests/NativeMarkdownSurfaceStreamingTests \
  -only-testing:PiAppTests/StableToolPresentationTests \
  -only-testing:PiAppTests/StorageTruthTests \
  -only-testing:PiAppTests/TranscriptActivityTests \
  -only-testing:PiAppTests/TranscriptDisclosureTests \
  -only-testing:PiAppTests/TranscriptFindTests \
  -only-testing:PiAppTests/TranscriptMarkdownTests \
  -only-testing:PiAppTests/TranscriptNativeWorkBehaviourTests \
  -only-testing:PiAppTests/TranscriptPageStressTests \
  -only-testing:PiAppTests/TranscriptRevealTests \
  -only-testing:PiAppTests/TranscriptWorkRowTests \
  -only-testing:PiAppTests/WorkspaceTests \
  -only-testing:PiAppTests/ReplySourceTests \
  -only-testing:PiAppTests/MarkdownSourceReconciliationTests \
  -only-testing:PiAppTests/TranscriptNativePaneBehaviourTests \
  -only-testing:PiAppTests/TranscriptSwitchFirstFrameTests \
  -only-testing:PiAppTests/NativeTranscriptTests \
  -only-testing:PiAppTests/MarkdownStreamingCorrectnessTests \
  -only-testing:PiAppTests/MarkdownStreamingTests \
  -only-testing:PiAppTests/NativeMarkdownViewportTests \
  -only-testing:PiAppTests/NativeTranscriptDocumentTests \
  -only-testing:PiAppTests/NativeTranscriptSafetyTests \
  -only-testing:PiAppTests/ResponseTimelinePresentationTests \
  -only-testing:PiAppTests/TimelineStreamingFastPathTests \
  -only-testing:PiAppTests/HistoryReaderStateTailTests \
  -only-testing:PiAppTests/HistoryExtentTests \
  -only-testing:PiAppTests/TranscriptNativeRowBehaviourTests \
  -only-testing:PiAppTests/TranscriptNativeMessageKindBehaviourTests \
  -only-testing:PiAppTests/ResponseChronologyTests \
  -only-testing:PiAppTests/SendImmediacyTests \
  -only-testing:PiAppTests/ToolCallSummaryTests \
  -only-testing:PiAppTests/FullDisplayTests \
  -only-testing:PiAppTests/TurnAccountingTests \
  -only-testing:PiAppTests/InlineSkillPillTests \
  -only-testing:PiAppTests/ChatFileLinkTests \
  -only-testing:PiAppTests/TranscriptPagingTests \
  -only-testing:PiAppTests/MessageDetailTests \
  -only-testing:PiAppTests/SubagentTranscriptTests \
  -only-testing:PiAppTests/SubagentSteeringPresentationTests \
  -only-testing:PiAppTests/SideRowPresentationTests \
  -only-testing:PiAppTests/AutomaticContextTests \
  -only-testing:PiAppTests/ForkCloneReaderTests \
  -only-testing:PiAppTests/FreshPresentationTests \
  -only-testing:PiAppTests/HistoricalEditingTests \
  -only-testing:PiAppTests/JournalCommandAcceptanceTests \
  -only-testing:PiAppTests/LaunchSelectionTests \
  -only-testing:PiAppTests/LongJournalHistoryTests \
  -only-testing:PiAppTests/RunHoldTests \
  -only-testing:PiAppTests/SubagentSteeringWorkspaceTests \
  -only-testing:PiAppTests/TranscriptStreamingStressTests \
  -only-testing:PiAppTests/WireContractTests \
  -only-testing:PiAppTests/WorkspaceFailureTests \
  -only-testing:PiAppTests/WorkspaceLoadingTests \
  -only-testing:PiAppTests/TranscriptWidthChangeTests \
  -only-testing:PiAppTests/HistoryReaderOpenPerformanceTests \
  -only-testing:PiAppTests/MessageVersionTranscriptTests \
  -only-testing:PiAppTests/ForkFromReplyTests \
  -only-testing:PiAppTests/HistoryEdgeTests

# round5-timeline-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptNativeTimelineBehaviourTests

# round5-agent-markdown-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentMarkdownTests

# round5-agent-reader-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentReaderTests

# round5-wire-page-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptWirePageTests

# round5-history-edge-timing-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/HistoryEdgeTimingTests

# round5-history-edit-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/HistoryEditTests

# round5-inline-timing-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/InlineSkillPillTimingTests

# round5-streaming-serial-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptStreamingSerialTests

# round5-gallery-final.log
TEST_RUNNER_PI_TRANSCRIPT_BUG_GALLERY="$PI_BUILD_ROOT/validation/gallery-round5" \
  scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugGalleryTests

```

`TranscriptBugGalleryTests` regenerated nine images under
`$PI_BUILD_ROOT/validation/gallery-round5`; all nine were opened and visually
inspected: `transcript-{light,dark,narrow}.png`, `rows-{light,dark,narrow}.png`,
and `recovery-{light,dark,narrow}.png`. The recovered reasoning and answer draw
correctly; the formatted `gamma delta` hit remains visible in both appearances
and at 360 points. The unfinished operation caption and completion notice fit.
The previous scenes retain the user highlight, summary and agent content, both
edit tails, ordered-list marker highlight and unclipped heading Copy button.
Narrow metadata uses the existing ellipsis; no new clipping was observed.

No helper or wire behavior changed, so the full helper and Python wire/concurrent/
acceptance suites were not rerun. The focused app wire tests are included above.
`git diff --check` passes. No clone folders remain under this workstream's build
root; its full-lane lock was released after every run. No installed app, real
preferences, chats, credentials or Keychain were used. No assigned product issue
or owner decision remains unresolved; the one desktop prerequisite skip is
recorded above for the lead's full gate.


## Round 6: captured tool ownership at page boundaries (2026-10-18)

Base: `95978a21d61843b45836f265b40748a0772052a7`. The review finding is
**confirmed and fixed**. A captured completed call formerly owned its output
while the unloaded receipt independently owned the same output. Search now
joins indexed peers on the active branch and adopts the planner's output
ownership, preserving the captured card's payload and state. Each call is
joined separately; unrelated captured rows retain their actual presentation.
The retained receipt remains the stable Find identity. A drawing hint lets Find
open/highlight its already-loaded card without fetching the off-page receipt.

### Failing first and corrected native oracle

`testCapturedCallDoesNotDuplicateItsUnloadedReceipt` first failed on unchanged
base production (`round6-failing-first.log`):

```text
XCTAssertEqual failed: (["reply", "result"]) is not equal to (["result"])
XCTAssertEqual failed: ("2") is not equal to ("1")
```

The final corpus was rerun against all three restored base production files
(`round6-verified-first.log`): **1 passed, 3 failed, 91 failing assertions**.
The primary case failed 4 assertions, the reused-call corpus 27, and the
saved/live corpus 60. The standalone-receipt control passed. Files were restored
in `finally`; no base source or mutation remains in the change.

```text
custom_fixture, live=false, raw=false, page=0..<1, query=outputneedle: 2 != 1
custom_fixture, live=false, raw=false, page=0..<1, query=sharedneedle: 4 != 3
page=0..<1, query=firstoutput: ["first-reply", "first-result"] != ["first-result"]
```

The initial corpus assumed the full group's presentation on every partial
page. That was wrong for an uncaptured streaming reply and for a receipt drawn
as a standalone Markdown row. Consequently, the 149 initial assertions, 112
in the first corpus rerun, and 51 in the first adversarial run are **not all
product failures**. Receipt-only searches must retain that visible row's
rendered Markdown, including hidden link destinations. The final independent
oracle mounts native planner rows for the captured page, uses retained state
for uncaptured rows, and gives explicitly paired payloads one owner. It also
preserves a visible old receipt instead of assuming all old receipts are hidden.

That corrected oracle caught a flaw in the first implementation before commit:
it had overwritten captured standalone-receipt text with off-page card text.
`round6-captured-view-first.log` reports **0 passed, 3 failed**; for example,
`testCapturedStandaloneReceiptKeepsItsRenderedText` found 0 versus 1 for
`alpha beta`, and 1 versus 0 for `receipt.test`. A captured recorded card also
lost `capturedliteral` when resolving disk receipts advanced its state. The
final join preserves standalone rows and restores captured tool states after
resolving unloaded peers. `round6-captured-view-fixed.log`: **66 passed, 0 failed**.

### Coverage and same-pattern sweep

- `testFindCountsEveryCallReceiptReplyPageSplitSavedAndLive` covers all ten
  contiguous slices of call/receipt/reply, including every empty placement,
  call-only, receipt-only, prefixes, suffixes and the full group. Generic, bash,
  read, edit and subagent cards run with saved/live helper-wire rows and both
  rendered/raw replies: **200 page cases, 1,800 native occurrence comparisons**.
  Nine queries cover input/output/reply, repeated text, literal markup, visible
  phrases and links, and transport text absent from special cards.
- `testEveryPageSplitKeepsReusedCallsAndLatestReceiptsSeparate`: two groups
  reuse a call ID; the first includes an older receipt. All 36 contiguous
  slices preserve output identity and the actual standalone-row presentation:
  **180 comparisons**.
- `testEveryLegacyPageSplitKeepsBothDisplayedOutputRows`: an unsupported
  timeline intentionally displays both a legacy card and a standalone result.
  All ten slices preserve both occurrences: **40 comparisons**.
- `testCompletedWireCardOwnsOneOutputAcrossThePageByteLimit`: generated output
  makes a completed helper-wire call fit the 256 KiB envelope while call plus
  receipt exceed it. The partial overlay still produces one receipt-owned hit.
- `testCapturedCardKeepsItsDisplayedOutputWhenReceiptIsUnloaded`: captured
  output wins over different disk output, once, under the retained receipt ID.
- `testCapturedOutputWithoutARetainedReceiptStaysOnItsCall`: a live completed
  card with no receipt keeps its own output, with and without a journal.
- `testCapturedStandaloneReceiptKeepsItsRenderedText`: 12 additional native
  comparisons cover receipt-only, recorded-call/receipt and recorded-call
  carrying a captured output. This is a control for existing behavior and a
  regression for the first implementation's error above.

Totals: **246 page cases and 2,020 native occurrence comparisons**, plus those
12 standalone comparisons and the branch's prior 363 exact-text comparisons.

The navigation sweep also confirmed that merely transferring identity could
send Find to the unloaded receipt instead of the loaded card.
`testFindRevealsCapturedOutputWithoutLoadingItsReceipt` failed first
(`round6-navigation-first.log`, **0 passed, 1 failed**, three assertions):

```text
focus.messageID: Optional("result") != Optional("reply")
focus.scopeCall: nil != Optional("call")
The output is already loaded; revealing its receipt can replace literal card text with standalone Markdown
```

It now checks the sole receipt-owned match, loaded-card focus and call scope,
no page read, and a visible highlight on the card's literal `receipt.test`.
`round6-navigation-fixed.log`: **2 passed, 0 failed**, including the original
native pane test with Next/Previous. Drawing metadata does not change match
identity and survives count reconciliation; it is used only while that card
is still loaded. Refresh still creates no navigation focus.

Intermediate harness errors are retained in the evidence: a hardcoded expected
`reply` ID caused the only failure in `round6-regression-fixed.log` (64 passed,
1 failed; its highlight checks passed). The assertion helper now accepts an
expected record ID. A first edit changed the wrong assertion and failed to
compile (`round6-pane-fixed.log`, no tests executed); the scoped correction
passed (`round6-pane-fixed-valid.log`, 1 passed).

### R6 navigation reconciliation: shared input/output query

The native navigation sweep found another instance of duplicate ownership:
`testFindKeepsCallInputAndReceiptOutputSeparateWhenReconciling` searches a word
shared by call input, output and the following reply, then steps from input to
output with partial and complete pages. Its failing-first run
(`round6-input-output-first.log`, **0 passed, 1 failed**) reported:

```text
["reply", "reply", "result", "answer"] != ["reply", "result", "answer"]
focus.record: Optional("reply") != Optional("result")
```

The search count was correct, but native reconciliation counted the card's
receipt-owned output again under its call. The projection now carries the
omitted-output call IDs into native counting. Input hits count their input and
prose; receipt hits retain their scoped output. Cards without a displayed
output, including edit diffs, require no omission. Reconciliation preserves the
match's ownership metadata without changing its identity or navigation serial.

### Mutation checks and final validation

All **12 valid mutations were caught**: 13 failing test invocations, zero passing tests. Each source was restored in `finally`. The first recorded-card mutation left an unused `var` and failed compilation (`round6-verified-mutation-recorded-card.log`, 0 tests); changing that mutated binding to `let` produced the valid assertion failure below. The earlier seven mutations also failed, but the final results use the corrected native oracle.

| Reversal (`round6-verified-mutation-*.log`) | Passed | Failed | Mutation |
| --- | ---: | ---: | --- |
| `joined-plan` | 0 | 2 | Skip the active-branch join |
| `output-owner` | 0 | 1 | Keep output on the captured call |
| `receipt-payload` | 0 | 1 | Remove adopted receipt payload |
| `unloaded-receipt` | 0 | 1 | Leave the receipt outside the overlay |
| `captured-state` | 0 | 1 | Ignore captured card values |
| `receipt-order` | 0 | 1 | Reverse peer ordering |
| `legacy-row` | 0 | 1 | Hide the independently displayed legacy result |
| `standalone-row` | 0 | 1 | Replace captured standalone receipt presentation |
| `recorded-card-valid` | 0 | 1 | Advance a captured recorded card from its disk receipt |
| `drawing-owner` | 0 | 1 | Drop the loaded-card drawing hint |
| `omitted-owner` | 0 | 1 | Drop receipt-owned output exclusions |
| `native-omission` | 0 | 1 | Count excluded output again during native reconciliation |

Each mutation used the command recorded in its matching `.json` and text log:

```sh
# joined-plan
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testCapturedCallDoesNotDuplicateItsUnloadedReceipt -only-testing:PiAppTests/TranscriptBugRegressionTests/testFindCountsEveryCallReceiptReplyPageSplitSavedAndLive
# output-owner
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testCapturedCallDoesNotDuplicateItsUnloadedReceipt
# receipt-payload
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testCapturedCallDoesNotDuplicateItsUnloadedReceipt
# unloaded-receipt
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testCapturedCardKeepsItsDisplayedOutputWhenReceiptIsUnloaded
# captured-state
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testCapturedCardKeepsItsDisplayedOutputWhenReceiptIsUnloaded
# receipt-order
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testEveryPageSplitKeepsReusedCallsAndLatestReceiptsSeparate
# legacy-row
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testEveryLegacyPageSplitKeepsBothDisplayedOutputRows
# standalone-row
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testCapturedStandaloneReceiptKeepsItsRenderedText
# recorded-card-valid
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testCapturedStandaloneReceiptKeepsItsRenderedText
# drawing-owner
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testFindRevealsCapturedOutputWithoutLoadingItsReceipt
# omitted-owner
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testFindKeepsCallInputAndReceiptOutputSeparateWhenReconciling
# native-omission
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testFindKeepsCallInputAndReceiptOutputSeparateWhenReconciling
```

The final regression and affected-class runs were repeated after the native input/output reconciliation fix. Their earlier green runs (67 and 617 passes) remain as `round6-regression-before-reconciliation.log` and `round6-affected-before-reconciliation.log`. `round6-input-output-fixed.log` passed all three selected native checks before the last two mutations.

After restoring every mutation: **803 passed, 0 failed, 8 skipped** across 74 focused classes. Serial classes ran alone.

| Final text log | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| `round6-regression-final.log` | 68 | 0 | 0 |
| `round6-affected-final.log` | 617 | 0 | 7 |
| `round6-timeline-final.log` | 30 | 0 | 0 |
| `round6-agent-markdown-final.log` | 19 | 0 | 0 |
| `round6-agent-reader-final.log` | 55 | 0 | 0 |
| `round6-wire-page-final.log` | 4 | 0 | 0 |
| `round6-history-edge-timing-final.log` | 2 | 0 | 0 |
| `round6-history-edit-final.log` | 3 | 0 | 0 |
| `round6-inline-timing-final.log` | 1 | 0 | 0 |
| `round6-streaming-serial-final.log` | 1 | 0 | 1 |
| `round6-gallery-final.log` | 3 | 0 | 0 |

Seven skips are the opt-in history index/open measurements, skill-pill captures,
Markdown line-pitch/token-cost measurements and sample capture, and the 70-turn
wire performance probe. The remaining skip is
`TranscriptStreamingSerialTests.testAReplyCountsAsReadOnlyOnceItsEndHasBeenOnScreen`:
“A receipt needs this app's own key, unoccluded window; this desktop cannot
provide one.” That desktop-dependent check remains unverified and is recorded
for the lead's merged gate; it is not counted as passing.

Exact final commands, each run under the shared full-lane lock:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript

# round6-regression-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests

# round6-affected-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ContentSearchTests \
  -only-testing:PiAppTests/HardeningTests \
  -only-testing:PiAppTests/HistoryIndexFilesTests \
  -only-testing:PiAppTests/HistoryReaderCheckpointTests \
  -only-testing:PiAppTests/MarkdownTextSurfaceTests \
  -only-testing:PiAppTests/NativeMarkdownSizingTests \
  -only-testing:PiAppTests/NativeMarkdownSurfaceStreamingTests \
  -only-testing:PiAppTests/StableToolPresentationTests \
  -only-testing:PiAppTests/StorageTruthTests \
  -only-testing:PiAppTests/TranscriptActivityTests \
  -only-testing:PiAppTests/TranscriptDisclosureTests \
  -only-testing:PiAppTests/TranscriptFindTests \
  -only-testing:PiAppTests/TranscriptMarkdownTests \
  -only-testing:PiAppTests/TranscriptNativeWorkBehaviourTests \
  -only-testing:PiAppTests/TranscriptPageStressTests \
  -only-testing:PiAppTests/TranscriptRevealTests \
  -only-testing:PiAppTests/TranscriptWorkRowTests \
  -only-testing:PiAppTests/WorkspaceTests \
  -only-testing:PiAppTests/ReplySourceTests \
  -only-testing:PiAppTests/MarkdownSourceReconciliationTests \
  -only-testing:PiAppTests/TranscriptNativePaneBehaviourTests \
  -only-testing:PiAppTests/TranscriptSwitchFirstFrameTests \
  -only-testing:PiAppTests/NativeTranscriptTests \
  -only-testing:PiAppTests/MarkdownStreamingCorrectnessTests \
  -only-testing:PiAppTests/MarkdownStreamingTests \
  -only-testing:PiAppTests/NativeMarkdownViewportTests \
  -only-testing:PiAppTests/NativeTranscriptDocumentTests \
  -only-testing:PiAppTests/NativeTranscriptSafetyTests \
  -only-testing:PiAppTests/ResponseTimelinePresentationTests \
  -only-testing:PiAppTests/TimelineStreamingFastPathTests \
  -only-testing:PiAppTests/HistoryReaderStateTailTests \
  -only-testing:PiAppTests/HistoryExtentTests \
  -only-testing:PiAppTests/TranscriptNativeRowBehaviourTests \
  -only-testing:PiAppTests/TranscriptNativeMessageKindBehaviourTests \
  -only-testing:PiAppTests/ResponseChronologyTests \
  -only-testing:PiAppTests/SendImmediacyTests \
  -only-testing:PiAppTests/ToolCallSummaryTests \
  -only-testing:PiAppTests/FullDisplayTests \
  -only-testing:PiAppTests/TurnAccountingTests \
  -only-testing:PiAppTests/InlineSkillPillTests \
  -only-testing:PiAppTests/ChatFileLinkTests \
  -only-testing:PiAppTests/TranscriptPagingTests \
  -only-testing:PiAppTests/MessageDetailTests \
  -only-testing:PiAppTests/SubagentTranscriptTests \
  -only-testing:PiAppTests/SubagentSteeringPresentationTests \
  -only-testing:PiAppTests/SideRowPresentationTests \
  -only-testing:PiAppTests/AutomaticContextTests \
  -only-testing:PiAppTests/ForkCloneReaderTests \
  -only-testing:PiAppTests/FreshPresentationTests \
  -only-testing:PiAppTests/HistoricalEditingTests \
  -only-testing:PiAppTests/JournalCommandAcceptanceTests \
  -only-testing:PiAppTests/LaunchSelectionTests \
  -only-testing:PiAppTests/LongJournalHistoryTests \
  -only-testing:PiAppTests/RunHoldTests \
  -only-testing:PiAppTests/SubagentSteeringWorkspaceTests \
  -only-testing:PiAppTests/TranscriptStreamingStressTests \
  -only-testing:PiAppTests/WireContractTests \
  -only-testing:PiAppTests/WorkspaceFailureTests \
  -only-testing:PiAppTests/WorkspaceLoadingTests \
  -only-testing:PiAppTests/TranscriptWidthChangeTests \
  -only-testing:PiAppTests/HistoryReaderOpenPerformanceTests \
  -only-testing:PiAppTests/MessageVersionTranscriptTests \
  -only-testing:PiAppTests/ForkFromReplyTests \
  -only-testing:PiAppTests/HistoryEdgeTests

# round6-timeline-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptNativeTimelineBehaviourTests

# round6-agent-markdown-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentMarkdownTests

# round6-agent-reader-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentReaderTests

# round6-wire-page-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptWirePageTests

# round6-history-edge-timing-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/HistoryEdgeTimingTests

# round6-history-edit-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/HistoryEditTests

# round6-inline-timing-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/InlineSkillPillTimingTests

# round6-streaming-serial-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptStreamingSerialTests

# round6-gallery-final.log
TEST_RUNNER_PI_TRANSCRIPT_BUG_GALLERY="$PI_BUILD_ROOT/validation/gallery-round6" \
  scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugGalleryTests
```

The gallery regenerated nine PNGs in `$PI_BUILD_ROOT/validation/gallery-round6`:
`transcript-{light,dark,narrow}.png`, `rows-{light,dark,narrow}.png`, and
`recovery-{light,dark,narrow}.png`. All nine were opened and visually inspected.
The 360-point heading Copy control remains inside the row; both edit tails,
ordered-list highlight, user highlight, summary/agent content, recovered
reasoning, formatted phrase highlight and unfinished-operation notice remain
visible. Narrow metadata uses its existing ellipsis; no new clipping was found.

No helper or wire behavior changed, so the full helper and Python wire,
concurrent and acceptance suites were not rerun. Focused app wire tests passed
above. `git diff --check` passes. No clone folders remain under this build root,
and every owned full-lane lock was released. The lead still runs the merged full
gate. No assigned product issue or owner decision remains unresolved beyond the
explicit desktop prerequisite skip above.

All evidence is text under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript/validation`.
The shared full-lane lock is held for each native run and released in `finally`.

### Adversarial self-review

Reviewed the whole production branch diff against
`141666ca479184d10a9791754d4c91df456599d8`, including exact heading source
ranges/CR handling, literal truncation markers, shared Markdown construction,
raw/streaming segment states, generic/special tools, user/system/agent rows,
planner recovery normalization, active-branch dependency joins, snapshot-prefix
validation, and refresh/reconciliation focus preservation. This round's review
specifically challenged every page edge, reused calls, old receipts, captured
versus retained state, legacy duplicate rows, and the loaded-card navigation
case. The concrete issues found during implementation are tested and fixed
above. Ordinary prose causes no new peer reads; search cancellation, bounded
source runs, 100-hit pagination, and branch validation remain in place.

Retained-source Copy/search and helper behavior are unchanged. No production
app, real conversation, preference, credential, capture or provider was used.
Fixtures use temporary journals, MemoryVaultStorage and the test host. No
owner decision is needed for this fix.
