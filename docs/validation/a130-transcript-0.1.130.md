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
