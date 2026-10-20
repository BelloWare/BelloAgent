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

## Round 7 — capture the renderer's inputs

Reviewed against `16791d347fd92ca673149aa7b0f9291b59b39586` on
`dev/a130-transcript`. Both review findings are **confirmed and fixed**.
The implementation keeps source/export search separate from transcript Find.
All new data is a value snapshot taken on the main actor; search does not fetch
arguments, open a host, change disclosure, or touch the journal. Navigation alone
opens matching folds, using the documents the conversation has already fetched.

### Findings and failing-first evidence

All logs below are text files in
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript/validation`.
Tests are in `TranscriptBugRegressionTests`.

| Finding | Regression / evidence before its fix | Resolution |
| --- | --- | --- |
| **R7-1: attributed first task outside the page** | `testUnloadedFirstAgentTaskMatchesItsNativeCard`: `"Check visible task."` versus `"Parent → Sub-agent 3 · First task label · turn 1\nTask\nCheck visible task."`; searches for task label, parent/number and turn returned `[]`. With an events envelope even the task prose was absent. | The legacy fallback now requires absent delivery metadata and a non-agent kind. Normalization uses a captured `AgentTranscriptPresentation`, the same implementation used by `SessionDisplay`, including child numbers. |
| **R7-1 nearby entry helper** | `testManagedAttributedEntryKeepsItsNativeAgentCard`: rendered body alone differed from both the attributed card and the invalid-attribution notice. | Apply the same guard to the single-entry projection. Invalid attributed rows retain the card's unavailable-attribution notice. |
| **R7-2: fetched full arguments omitted** | `testFetchedArgumentsMatchNativeCardsInEverySearchPath`: preview JSON containing `"preview" : "short"` differed from the native card's complete document; `fetched needle` returned `[]`. | Capture `TranscriptToolInputs` with the messages; pass the occurrence's exact `ToolInputDocument` through the normalized plan into `TranscriptToolRow.card`, including receipt-owned output selection. |
| **Nearby: an arriving document leaves Find stale** | `testFindRefreshesWhenFetchedArgumentsArriveWithoutNavigation`: matches remained `[]` after the native card acquired the full document. | Refresh on changes to the captured documents, retaining the existing selection/focus policy. A newly found match does not create focus; explicit Next highlights it. |
| **Nearby: a refresh cancels an earlier reader action** | `testFetchedRefreshKeepsNavigationAlreadyInFlight`: the held Next reveal returned `Task.isCancelled == true`. | Refresh cancels only the old search. A new query still cancels navigation; a same-query refresh preserves the reader's pending reveal and its identity checks. |
| **Nearby: closed cards lose cached full arguments** | `testFetchedInputsKeepTheirOccurrenceWhenCardsAreClosed`: both `first` and `second` returned no hit despite separately cached documents for their reused call ID. After fixing capture, an end-to-end extension failed with `Visible match for fetched first`. | Capture cached documents for folded cards too; Find opens those cards with the same occurrence-scoped document. The reveal predicate now receives that document rather than inspecting the inline preview alone. |
| **Nearby: fetched edit cannot expand to its match** | `testFindExpandsFetchedEditTextBeyondItsPreview`: search found the record but timed out with `Visible match for fetched middle change`. | Expansion reads the action row's actual stored card model, including its fetched document, before counting/rendering the middle lines. |
| **Nearby: linked I/O fallback omits its file header** | `testFindKeepsTheFileHeaderOfAnIOFallbackCard`: JSON alone differed from `fallback.txt\n` followed by that same JSON. | Use the production conversation pane's file-opener policy when selecting the card; retain the I/O card's displayed path header. |
| **Nearby: distant agent-tool input loses its number** | `testUnloadedAgentToolKeepsItsNumberAcrossDecodeRuns`: `Sub-agent · Task body` differed from `Sub-agent 3 · Task body`; the number query returned `[]`. | Apply the captured agent presentation before deriving an input-only projection from a distant receipt. |

Failing-first runs (pass/fail/skip, each exit 65):

- `round7-failing-first.log`: **0/4/0**, both findings, the entry-helper variant,
  and document-arrival refresh, before any production change.
- `round7-sweep-first.log`: **0/2/0**, closed cached documents and navigation
  already in flight, before their fixes.
- `round7-header-first.log`: **0/1/0**, I/O file header.
- `round7-fetched-edit-first.log`: **0/1/0**, long fetched edit expansion.
- `round7-agent-peer-first.log`: **1/2/0**. The distant-agent test failed on
  missing attribution. The other failure was a test setup error in the new
  native-row comparison: timeline cards keep their tool in `block.replies`, not
  `block.tools`. The attributed-first-task test passed. The setup error is not
  counted as product evidence; the original fetched-document failure above is.
- `round7-closed-reveal-first.log`: **0/1/0**, Find's closed-card reveal.

`round7-fixed-initial.log` passed the initial four tests. Two intermediate full
runs are retained rather than discarded: `round7-fixed-all.log` was **75/1/0**
(the older card oracle hard-coded `linked: false` for an empty-result read), and
`round7-fixed-complete.log` was **76/1/0** (the page-split oracle removed an output
by clearing the tool, accidentally changing a native read card into an I/O
fallback and inventing another path occurrence). The oracle now enables the
same file opener as the production pane and filters actual native output text
units without changing the card's input/model/type. After those corrections,
`round7-fixed-verified.log` passed **77/0/0**.

### Renderer-input audit

The searchable surface remains the conversation's content, including foldable
bodies that Find opens, displayed source mode, and existing file/agent identities.
Fixed button labels, status/metric chrome, line-number gutters and accounting
controls are not additional message occurrences (the same boundary recorded in
rounds 3–4). This audit distinguishes those inputs from content inputs; it does
not claim that a text projection reproduces controls or geometry.

| Shared renderer input | Rendered value and search value |
| --- | --- |
| `TranscriptRowInputs.item` | Both use `TaskTranscriptPlan.rows` over the same presented messages. Captured rows retain their exact `TranscriptMessage`/`ToolView` values; unloaded rows use `HistoryReader.displayedMessage`, receipt resolution, and the captured agent presentation before planning. Planner ledger/checkpoint suppression and call ownership are retained. |
| `fresh`, `width`, `workListHeight`, `workListMeasured`, `foldInMotion` | Arrival/motion/measurement only; not inputs to content strings. Search builds no views or layout state. |
| `actions`, `toggle` | Control handlers, not text. The content-affecting exception is file-opener availability: `ConversationPaneBridges.showTranscript` always provides `openFile` and sets `opensFiles = true`; the I/O fallback now follows that policy. |
| `environment.colorScheme`, `increasedContrast`, `layoutDirection`, `locale` | Styling, wrapping, direction and metric/gutter formatting. Markdown content uses the same `MarkdownTextBuilder`; row width does not rewrite its content. These values are not substituted into message text. |
| `environment.isEnabled`, `forks`, `managedChild`, `sessionID` | Enabled controls, fork/edit permissions and historical-agent controls/chrome. Managed-task/agent content uses the display's captured session ID and state via `AgentTranscriptPresentation`; the original journal and permission decisions stay unchanged. |
| `disclosure.raw` | Captured `rawReplies`, interpreted through the same `ReplySource.shows` and the individual timeline segment's completion state. |
| `disclosure.work`, `openTools`, `openReasoning`, `compaction`, `responseFolded`, `responseLine`, `foldedAway`, `turnFoldOpen` | Fold visibility. Find searches the body it will reveal, preserving the existing folded-body behavior; it does not add the fold/control labels as duplicate content. |
| `disclosure.toolInputs` | Native rows and Find use the same `TranscriptToolInputs.snapshot`/`document` store. Documents remain keyed by reply plus call. Find captures closed cards' cached documents because opening those cards uses them too; ambiguous unscoped IDs never borrow a document. |
| Planner `lifecycle`, turn completion/display mode | Adds task/response accounting lines and end-of-turn folds, not different body content. Search consumes normalized `rows` without those control/metric additions. The native corpus opens those folds before comparing body strings. |

Every production row renderer selected by `TranscriptRowRenderer.content` was
checked. Content fields are listed explicitly below; the shared inputs above
also apply to each row.

| Renderer | Content inputs / projection use | Non-content inputs checked |
| --- | --- | --- |
| `TranscriptNativeAgentRow` | Whole planner message: `nativeAgentDelivery`, `kind`, envelope/body `text`, `agentNumbers`; shared `AgentMessagePresentation` supplies event author/child/turn/task/kind/text, title, label, optional note and unavailable notice. | Event IDs/reply-to/source references select actions and stable view identities. |
| `TranscriptNativeUserRow` | Literal `message.text`, already projected from display override, text blocks or image-only label. | Skills, versions, failed-end chip, truncation notice, accounting and hover/edit/copy controls do not change that text. |
| `TranscriptNativeReplyRow` | Message text, role, tools/empty-body condition, streaming state and raw disclosure; shared `ReplySource` and Markdown builder. | Identity/headings configure copy/file links; quote/fold menus, early-end/truncation chips and waiting dots are chrome. |
| `TranscriptNativeFailureRow` | `message.text`, optional `detail`, joined in reading order. | `failureCode`, ID, environment and actions select title/tint/Retry/Resume/limit controls. |
| `TranscriptNativeNoticeRow` | Literal `message.text`. | Spinner, rules and status accessibility prefix. |
| `TranscriptNativeBranchRow` | `message.detail ?? message.text`. | Edit marker and source actions. |
| `TranscriptNativeStatusRow` | Literal `message.text`. | Status heading, failure/truncation chips, accounting and hover actions. |
| `TranscriptNativeVersionBannerRow` | `message.text` and optional `detail`. | Version/back actions and decoration. |
| `TranscriptNativeCompactionRow` | `message.text` with shared `.summary` Markdown style, including `TranscriptMessage.compactionText`'s displayed prefix. | Compaction title/detail counts, accounting and disclosure controls. |
| `TranscriptNativeRequestInfoRow` | `message.detail` and `TranscriptActivity.earlyEnd(message.stopReason)`. | Request accounting and fold state. |
| `TranscriptNativeToolResultRow` | Standalone receipt `message.text` through `.prose` Markdown; paired receipts instead own their native card output. | Receipt caption/disclosure control. |
| `TranscriptNativeTurnSummaryRow`, `TranscriptNativeTurnFoldRow`, `TranscriptNativeResponseRow` | No separate message payload; the planner's source bodies are searched once. | Turn/task/response summary, model, status, timing/cost/token figures, fold state and actions. |
| `TranscriptNativePartRow` / `TranscriptNativePartView` | Planner segment and normalized message, including individual completion state; prose/refusal, reasoning/opaque/correction Markdown, literal arguments/status, or the planner-selected tool. Tool document uses the same scoped key as the row. | Work title/state/summary, fold closures, warning/control labels, streaming dots. |
| `TranscriptNativeExecutionRow` | `detail ?? text`, supported timeline segments, terminal state and the same missing-completion notice. Its part views have no tool-card override. | Compaction-style fold and execution icon. |
| `TranscriptNativeLegacyRow` / reply work | Planner `block.activity` replies, thinking plus streaming state, ordered tools, scoped cached documents; body replies use the reply path above. | Work summaries, accounting, request timing and action buttons. |
| `TranscriptNativeEmptyRow` | No text; production planners do not route content here. | Test-only reference renderer remains a test seam, not a production input. |

| Card renderer / builder input | Exact source and use |
| --- | --- |
| All cards: `tool`, `fetched`, `model`, `linked` | The planner's captured/resolved `ToolView`; the exact stored `ToolInputDocument` (`input`, `truncated`, `bytes`; streaming documents are not cached by the existing store); `TranscriptToolRow.model(of: tool)` from the original tool, as in `TranscriptNativeActionRow`; production file-link availability for the I/O branch. Other card branches do not read `linked`. No tool type is inferred independently by search. |
| `ToolView` fields used by card selection/content | ID/name/state/input/output, input-truncation flag/byte count, result truncation, path, added/removed counts, and native/live sub-agent metadata all travel with that same value. Durations and model state remain available for native row chrome; search never replaces captured tool state with a newer disk state. |
| `TranscriptNativeIOCard` | Card `path`, formatted `input`, optional literal `output`; `failed` affects color and `note` is the existing bounded-input/result notice. Path now matches the native linked fallback header. |
| `TranscriptNativeTerminalCard` | Decoded command from the fetched-or-inline document, literal tool output, failed state. The command is input; capped result text is output. Prompt and tint are chrome. |
| `TranscriptNativeReadCard` | Exact output plus `TranscriptReadCardText.window` lines/note, fetched input's `firstLine`, original model's path and failed state. `firstLine` numbers the native gutter; search retains the body and path. |
| `TranscriptNativeDiffCard` | The shared `EditRequest` built from fetched-or-inline arguments: mode, complete/bounded status, before/after, rows and too-large state; path/outcome/added/removed are the same builder values. Search uses rows or full before/after for a too-large diff; explicit navigation expands the native middle/source bodies. Receipt transport text is not invented as diff output. |
| `TranscriptNativeSubagentCard` | Original work-line heading plus shared `SubagentToolView` from the same requested tool: task/result/error content, summary/number/effort/status/cost/delivery/held/original-availability/target metadata. Markdown task/result use the shared builder. Summary/accounting/status fields and historical controls retain their existing chrome boundary. |
| Agent display overlay | A single `AgentTranscriptPresentation` captures session ID, managed-child/busy/family-waiting flags, child numbers/efforts/costs, original availability, coordination entries, child summaries and held-child IDs. Both `SessionDisplay` and unloaded/contextual search call its same presentation functions. |
| Fetched outputs | Native cards have no independent full-output fetch/cache parameter. They receive `ToolView.output`, optionally resolved from retained receipts when constructing an unloaded page. Find receives that same value; full-argument capture never substitutes a journal output for a captured card. |
| Native card update inputs | `link`, `environment`, actions and local expansion/scroll state affect controls, painting or what portion is open. Find's expansion predicate now reads the already-built card model (`action.searchText`), rather than rebuilding it without fetched arguments. |

The fetched corpus covers **48 configurations**: eight tools (generic, terminal,
edit, write, read, start/send/report), retained/live-unsaved/no-journal search,
and timeline/legacy work rows. Each compares the projection with a real card and
compares that card with the actual planner-selected row renderer using
`TranscriptRowDisclosure.of`. The first-task corpus covers initial metadata with
and without an events envelope, numbered/unnumbered attribution, loaded/paged-out
rows, and a history caller without a live display snapshot. Invalid metadata,
reused call IDs, closed/reopened cards and a middle-of-edit highlight are separate
checks. Existing Markdown/raw, other-row, recovery and every-page-split corpora
remain in the regression class.

### Round-7 adversarial self-review

Re-read the production branch diff from
`141666ca479184d10a9791754d4c91df456599d8`, including copy source offsets,
CR/CRLF handling, heading-control placement, complete/truncated edit parsing,
shared Markdown strings, row normalization, SQLite peer indexing, search snapshot
validation, raw disclosure, output ownership, Find reconciliation/navigation,
and this round's capture/reveal/expansion changes.

The input audit deliberately checked paths beyond the two reported examples:
the single-entry managed fallback, numbered cold agent rows, distant receipts,
legacy and timeline tools, unjournaled rows, same-ID calls in distinct replies,
closed cached cards, input arrival during an outstanding reader navigation, and
native content beyond a preview. The additional failures and fixes are recorded
above. The shared agent value preserves the existing rendering function's body;
it does not add a new agent policy or alter the immutable source receipt.

Captured tools still win over a later journal state. Receipt ownership is joined
against the active branch; standalone receipt presentation, superseded ledgers,
abandoned branches and page boundaries retain the prior protections. Fetched
arguments do not change the recorded outcome or grant a permission. Dictionary
snapshots share immutable Swift values with the display and stay scoped to one
conversation; no mutable AppKit view or layout object crosses the actor boundary.
The search byte windows, cancellation checks and captured-prefix validation are
unchanged.

Navigation refresh keeps the newest occurrence identity and does not install
focus after nil. It now also leaves an already-running reader reveal intact;
new query, Next/Previous replacement, close, reader interruption and session
retirement still cancel the old navigation through their existing paths. Native
expansion uses the actual card model, and opening a closed cached card uses the
same document lookup/key as the row disclosure.

No helper package or wire protocol was changed, so helper and external
wire/concurrent/acceptance suites are not required for this app-only revision.
The affected app wire/decode tests are included below. No owner decision or
unfinished production path was introduced. No files were added or removed, so
no project regeneration was needed for this round.

The last adversarial comparison found one further instance of the same input
mismatch: a sub-agent's **work-line heading remains based on the original tool
model**, while its open task body reads the fetched document. Search had used
the fetched card's accessibility title as though it were that visible heading.
`testFetchedAgentTaskKeepsTheDisplayedRowHeading` failed first in
`round7-agent-heading-first.log` (**0/1/0**, exit 65):

```text
"Sub-agent · Fetched label\nFull task body"
    != "Sub-agent · Inline label\nFull task body"
Inline label: [] != ["reply"]
Fetched label: ["reply"] != []
```

The projection now carries the original model's heading separately from the
fetched body. The native expansion string takes the actual work line's heading
and actual card model. The fetched corpus also reads the planner-selected
native action row's `line.content`, so it can no longer hide this distinction by
manufacturing a heading from the fetched card. This adds a tenth regression
method to this round (**78 total**).

A final coverage control, `testFetchedCardKeepsOutputOwnershipAcrossAPartialPage`,
also compares a captured generic/write card against its unloaded receipt, using
both native and wire-roundtripped page values. Fetched write arguments turn its
I/O preview into a diff; the transport result must then stay absent, while a
generic card keeps exactly one output occurrence. The control passed **1/0/0**
in `round7-receipt-control.log` and required no further production change. This
brings the round to **11 new regression methods, 79 total**.

### Round-7 mutation checks

Each mutation was applied alone, compiled, ran the named regression to an
assertion failure (exit 65), and was restored in `finally`. All **14** checks
failed as intended; no compilation failure is counted as mutation evidence.

| Log / reversed behavior | Failing test | Passed | Failed | Skipped |
| --- | --- | ---: | ---: | ---: |
| `round7-mutation-agent-capture.log` | `testUnloadedFirstAgentTaskMatchesItsNativeCard` | 0 | 1 | 0 |
| `round7-mutation-agent-heading.log` | `testFetchedAgentTaskKeepsTheDisplayedRowHeading` | 0 | 1 | 0 |
| `round7-mutation-arrival-refresh.log` | `testFindRefreshesWhenFetchedArgumentsArriveWithoutNavigation` | 0 | 1 | 0 |
| `round7-mutation-closed-inputs.log` | `testFetchedInputsKeepTheirOccurrenceWhenCardsAreClosed` | 0 | 1 | 0 |
| `round7-mutation-distant-agent.log` | `testUnloadedAgentToolKeepsItsNumberAcrossDecodeRuns` | 0 | 1 | 0 |
| `round7-mutation-entry-attribution.log` | `testManagedAttributedEntryKeepsItsNativeAgentCard` | 0 | 1 | 0 |
| `round7-mutation-fetched-capture.log` | `testFetchedArgumentsMatchNativeCardsInEverySearchPath` | 0 | 1 | 0 |
| `round7-mutation-fetched-card.log` | `testFetchedArgumentsMatchNativeCardsInEverySearchPath` | 0 | 1 | 0 |
| `round7-mutation-fetched-expansion.log` | `testFindExpandsFetchedEditTextBeyondItsPreview` | 0 | 1 | 0 |
| `round7-mutation-fetched-reveal.log` | `testFetchedInputsKeepTheirOccurrenceWhenCardsAreClosed` | 0 | 1 | 0 |
| `round7-mutation-fetched-receipt.log` | `testFetchedCardKeepsOutputOwnershipAcrossAPartialPage` | 0 | 1 | 0 |
| `round7-mutation-history-attribution.log` | `testUnloadedFirstAgentTaskMatchesItsNativeCard` | 0 | 1 | 0 |
| `round7-mutation-io-header.log` | `testFindKeepsTheFileHeaderOfAnIOFallbackCard` | 0 | 1 | 0 |
| `round7-mutation-reader-navigation.log` | `testFetchedRefreshKeepsNavigationAlreadyInFlight` | 0 | 1 | 0 |

The corresponding reversals remove: the two attribution guards; the display
agent snapshot; distant-tool normalization; fetched-document capture; the
card builder's fetched parameter; closed-document capture; arrival refresh;
navigation preservation; fetched expansion; fetched reveal; the I/O header;
the original sub-agent heading; and the receipt card's fetched document. The
last mutation produced `"fixture.txt\nfetched needle\noutputneedle"` instead of
the native diff's `"fixture.txt\nfetched needle"`, and counted one output hit
instead of zero, in both page representations. The restored 79-test regression
class passed after this final mutation; the other final suites used the same
production fix.

Exact focused commands for these mutation runs (each under the shared lock):

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript

# round7-mutation-agent-capture.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testUnloadedFirstAgentTaskMatchesItsNativeCard

# round7-mutation-agent-heading.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testFetchedAgentTaskKeepsTheDisplayedRowHeading

# round7-mutation-arrival-refresh.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testFindRefreshesWhenFetchedArgumentsArriveWithoutNavigation

# round7-mutation-closed-inputs.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testFetchedInputsKeepTheirOccurrenceWhenCardsAreClosed

# round7-mutation-distant-agent.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testUnloadedAgentToolKeepsItsNumberAcrossDecodeRuns

# round7-mutation-entry-attribution.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testManagedAttributedEntryKeepsItsNativeAgentCard

# round7-mutation-fetched-capture.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testFetchedArgumentsMatchNativeCardsInEverySearchPath

# round7-mutation-fetched-card.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testFetchedArgumentsMatchNativeCardsInEverySearchPath

# round7-mutation-fetched-expansion.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testFindExpandsFetchedEditTextBeyondItsPreview

# round7-mutation-fetched-reveal.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testFetchedInputsKeepTheirOccurrenceWhenCardsAreClosed

# round7-mutation-fetched-receipt.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testFetchedCardKeepsOutputOwnershipAcrossAPartialPage

# round7-mutation-history-attribution.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testUnloadedFirstAgentTaskMatchesItsNativeCard

# round7-mutation-io-header.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testFindKeepsTheFileHeaderOfAnIOFallbackCard

# round7-mutation-reader-navigation.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testFetchedRefreshKeepsNavigationAlreadyInFlight
```

### Round-7 final validation

The final runs cover **84 distinct classes: 916 passed, 0 failed, 8 skipped**.
Counts below are test methods, not individual assertions. The restored regression
run replaces the earlier 78-test final run in this total; focused controls and
mutation runs are not double-counted. Every run used this worktree/build root and
the shared full-lane lock; serial lanes ran alone.

| Log | Suite | Passed | Failed | Skipped |
| --- | --- | ---: | ---: | ---: |
| `round7-regression-restored.log` | TranscriptBugRegressionTests | 79 | 0 | 0 |
| `round7-affected-final.log` | 64 affected app classes (selectors below) | 617 | 0 | 7 |
| `round7-timeline-final.log` | TranscriptNativeTimelineBehaviourTests | 30 | 0 | 0 |
| `round7-agent-markdown-final.log` | SubagentMarkdownTests | 19 | 0 | 0 |
| `round7-agent-reader-final.log` | SubagentReaderTests | 55 | 0 | 0 |
| `round7-wire-page-final.log` | TranscriptWirePageTests | 4 | 0 | 0 |
| `round7-history-edge-timing-final.log` | HistoryEdgeTimingTests | 2 | 0 | 0 |
| `round7-history-edit-final.log` | HistoryEditTests | 3 | 0 | 0 |
| `round7-inline-timing-final.log` | InlineSkillPillTimingTests | 1 | 0 | 0 |
| `round7-streaming-serial-final.log` | TranscriptStreamingSerialTests | 1 | 0 | 1 |
| `round7-agent-inputs-final.log` | 6 agent input/navigation classes | 47 | 0 | 0 |
| `round7-agent-adjacent-final.log` | 4 family/metadata/panel/discovery classes | 55 | 0 | 0 |
| `round7-gallery-final.log` | TranscriptBugGalleryTests | 3 | 0 | 0 |

Seven affected-suite skips are explicit opt-ins: long-journal indexing/open
measurements, skill-pill captures, Markdown line-pitch/token-cost measurements,
Markdown sample capture, and the 70-turn wire performance measurement. The
separate serial skip is
`TranscriptStreamingSerialTests.testAReplyCountsAsReadOnlyOnceItsEndHasBeenOnScreen`:
`A receipt needs this app's own key, unoccluded window; this desktop cannot provide one.`
That desktop-dependent behavior is **unverified**, not a pass; the lead's merged
gate must supply its window prerequisite. No test failure was discarded.

Exact final commands (run from the worktree; the lock wrapper releases only its
own lock in `finally`):

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript

# round7-regression-restored.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests

# round7-affected-final.log
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

# round7-timeline-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptNativeTimelineBehaviourTests

# round7-agent-markdown-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentMarkdownTests

# round7-agent-reader-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentReaderTests

# round7-wire-page-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptWirePageTests

# round7-history-edge-timing-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/HistoryEdgeTimingTests

# round7-history-edit-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/HistoryEditTests

# round7-inline-timing-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/InlineSkillPillTimingTests

# round7-streaming-serial-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptStreamingSerialTests

# round7-agent-inputs-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentNavigationTests \
  -only-testing:PiAppTests/SubagentEffortTests \
  -only-testing:PiAppTests/InheritedSubagentReaderTests \
  -only-testing:PiAppTests/SubagentCostTests \
  -only-testing:PiAppTests/SubagentDisplayTests \
  -only-testing:PiAppTests/SubagentMetadataTests

# round7-agent-adjacent-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ConversationFamilyTests \
  -only-testing:PiAppTests/MetadataDurabilityTests \
  -only-testing:PiAppTests/SubagentPanelTests \
  -only-testing:PiAppTests/SubagentDiscoveryTests

# round7-gallery-final.log
TEST_RUNNER_PI_TRANSCRIPT_BUG_GALLERY="$PI_BUILD_ROOT/validation/gallery-round7" \
  scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugGalleryTests
```

The gallery regenerated and I opened all nine images in
`$PI_BUILD_ROOT/validation/gallery-round7`: `transcript-{light,dark,narrow}.png`,
`rows-{light,dark,narrow}.png`, and `recovery-{light,dark,narrow}.png`. The
360-point heading Copy control remains inside its row, the edit's literal marker
and both changed tails are visible, and list/user/recovered-prose highlights
remain aligned. Summary, agent and recovery content wraps as before; narrow
metadata retains its existing ellipsis. No new clipping was found.

Exact failing-first/intermediate/control commands are retained here alongside
the earlier evidence, so the test setup corrections are reproducible too:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript

# round7-failing-first.log: 0/4/0 pass/fail/skip, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testManagedAttributedEntryKeepsItsNativeAgentCard \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testUnloadedFirstAgentTaskMatchesItsNativeCard \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFetchedArgumentsMatchNativeCardsInEverySearchPath \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFindRefreshesWhenFetchedArgumentsArriveWithoutNavigation

# round7-sweep-first.log: 0/2/0 pass/fail/skip, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFetchedInputsKeepTheirOccurrenceWhenCardsAreClosed \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFetchedRefreshKeepsNavigationAlreadyInFlight

# round7-header-first.log: 0/1/0 pass/fail/skip, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFindKeepsTheFileHeaderOfAnIOFallbackCard

# round7-fetched-edit-first.log: 0/1/0 pass/fail/skip, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFindExpandsFetchedEditTextBeyondItsPreview

# round7-agent-peer-first.log: 1/2/0 pass/fail/skip, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testUnloadedAgentToolKeepsItsNumberAcrossDecodeRuns \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFetchedArgumentsMatchNativeCardsInEverySearchPath \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testUnloadedFirstAgentTaskMatchesItsNativeCard

# round7-closed-reveal-first.log: 0/1/0 pass/fail/skip, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFetchedInputsKeepTheirOccurrenceWhenCardsAreClosed

# round7-agent-heading-first.log: 0/1/0 pass/fail/skip, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFetchedAgentTaskKeepsTheDisplayedRowHeading

# round7-fixed-initial.log: 4/0/0 pass/fail/skip, exit 0
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testManagedAttributedEntryKeepsItsNativeAgentCard \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testUnloadedFirstAgentTaskMatchesItsNativeCard \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFetchedArgumentsMatchNativeCardsInEverySearchPath \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFindRefreshesWhenFetchedArgumentsArriveWithoutNavigation

# round7-fixed-all.log: 75/1/0 pass/fail/skip, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests

# round7-fixed-complete.log: 76/1/0 pass/fail/skip, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests

# round7-fixed-verified.log: 77/0/0 pass/fail/skip, exit 0
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests

# round7-agent-heading-fixed.log: 2/0/0 pass/fail/skip, exit 0
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFetchedAgentTaskKeepsTheDisplayedRowHeading \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFetchedArgumentsMatchNativeCardsInEverySearchPath

# round7-regression-final.log: 78/0/0 pass/fail/skip, exit 0
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests

# round7-receipt-control.log: 1/0/0 pass/fail/skip, exit 0
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFetchedCardKeepsOutputOwnershipAcrossAPartialPage
```

`git diff --check` passes. All round-7 production mutations were restored before
committing. No clone folders remain under this build root (15.76 GiB free at the
last check); all locks owned by this workstream were released. The shared lock
was subsequently held by another workstream and was left untouched. Evidence is
text logs plus the generated gallery PNGs; no named result bundle was created.
No helper/package/protocol change, live user data, installed app, real preference,
Keychain, paid provider or live capture was involved. The only outstanding validation
limit is the explicit desktop prerequisite above; there is no unresolved owner
decision for these fixes.

## Round 8 — bounded Find dependencies and second-hunt transcript fixes

Baseline: `3bd0daf3bb836a485dad6a374ebdf9b81d96982e`, on
`dev/a130-transcript`. The second hunt ran without this branch; its numbered-fence
heading bug is already fixed here. The performance, read-card and reordered-table
findings are confirmed. All fixtures are generated; no helper, provider or real
conversation is involved.

### Findings and failing-first evidence

Evidence remains text under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript/validation`.
All named regressions below are in `TranscriptBugRegressionTests`.

| Finding | Result and regression | Failing-first evidence / change |
| --- | --- | --- |
| **R8 dependency lookup** | Confirmed + fixed; `testReusedToolDependenciesStayWithinPagingBudget` | 5,000 pairs sharing one provider call ID, all 5,000 call lookups checked for the correct receipt: **19.313107 s**, failing the 1 s bound. The same fixture after the fix took **0.296897 s** (subsequent full-class run **0.314506 s**). Links now carry nullable active-branch positions and use `(kind,value,n)` range seeks for the next call, latest receipt, previous issuer and first operation. No per-lookup join/sort of the reuse set remains. |
| **R8 paging during Find** | Confirmed + fixed; `testPagingCanFinishWhileFindScansReusedCalls` | A warm page waited **25.293904 s**, failing the 0.5 s bound; completion order was `[search, page]`. With the same 5,000-pair generated journal, paging took **0.016705 s**, order `[page, search]` (full-class run **0.013921 s**). Search yields its actor between bounded runs, keeping its own file handle and immutable branch snapshot. |
| **Second-hunt TRANSCRIPT-1** | Confirmed + fixed; `testExpandedReadAndDiffSurviveHostEviction` | The remounted read was collapsed; cached height **1,588 pt** versus fitting height **268 pt**. The test waits for validation, releases the real host, checks that it was released, rebuilds at the same width and compares cached/fitting geometry. Expansion now lives in `TranscriptDisclosure.toolLines`, keyed by reply + call, and is restored before card measurement. |
| **Nearby diff expansion** | Confirmed + fixed by the same state path and test | The diff also remounted collapsed, **339 pt** cached versus **295 pt** fitting in the initial timeline case. The final corpus includes read and diff cards in timeline rows, single-card legacy work and eight-card virtual work lists. It also asserts that expanding changes the work-list height, so matching two stale outer heights cannot hide an undersized body. |
| **Second-hunt TRANSCRIPT-2** | Already fixed on the baseline; `testNumberedFenceKeepsHeadingCopyBoundaries` | The exact numbered `sh` fence fixture passes before any round-8 production edit. The real Done heading control copies `# Done\nFinished.`; targets are Setup/Done only, and Setup retains the complete fenced list. No new Copy implementation change is needed. The earlier canonical-heading fix, not a new scanner special case, covers this shape. |
| **Second-hunt TRANSCRIPT-3** | Confirmed + fixed; `testReorderedFullTableCellDetailsCopyTheVisibleColumn` | After moving B before A, the real first grid cell reads **B1**, but the selection callback displays **A1**, and copying the selected detail also returns **A1**. Resolve the visual column's `NSTableColumn.identifier` before indexing the source row. Missing-column/keyboard whole-row fallback and full-table TSV copying retain their prior behavior. |
| **Nearby Find cancellation** | Confirmed + fixed; paging regression extended | Cancelling the superseded query discarded the warm index: **0 bytes** retained instead of **4,784,128**. Cancellation now leaves it intact. Failure cleanup checks the captured stamp so an old search cannot remove a newer page/query snapshot after an actor yield. |

`round8-failing-first.log` is **1 passed / 4 failed / 0 skipped**, exit 65.
The numbered-fence control passed; the timing, paging and read/diff assertions
failed as above. Its table failure was a synthetic-click setup failure, not bug
evidence. Two focused attempts (`round8-table-first.log` and
`round8-table-click-first.log`, each **0/1/0**) also failed to deliver a native
click; the desktop reported the test app inactive. Those outputs are retained.

The table's action now delegates its row/visual-column arguments to `showCell`,
with the original selection body preserved until the valid failing-first run.
The fixture obtains both indexes from the real cell rectangle, verifies the
native cell's B1 text, invokes that same selection handler and copies through
its actual NSTextView. It does not pretend an undelivered mouse event is a
successful click. An intermediate selector-overload compilation failure is
recorded in `round8-selection-cancellation-first.log` (**0 tests**, exit 65),
then the helper was named distinctly. Neither setup nor compile failure counts
as product or mutation evidence.

`round8-core-fixed-table-first.log` was **4/1/0**: dependency/index, paging and
all six expansion configurations passed, while the synthetic table event still
missed. The valid `round8-selection-cancellation-first-compiled.log` is
**0/2/0**, exit 65: it fails on **A1 versus B1** in both the visible detail and
pasteboard, and on the discarded index after cancellation. Only then were those
two behaviors fixed. `round8-regression-fixed.log` passes **85/0/0**.

### Input, geometry and branch audit

The round-7 renderer-input table still applies. The additional state follows
these paths explicitly:

| Input/state | Renderer / cache / search |
| --- | --- |
| Inner read/diff expansion | `TranscriptDisclosure.toolLines(ToolOccurrence.key(reply,call))` → `TranscriptRowDisclosure.expandedTools` → timeline part or legacy activity → action row → native card, before its model is configured and its geometry reused. The virtual work-list item carries the same value; its toggle relay writes the same occurrence. |
| Work-list geometry | Its cache key now includes `expandedTools`; local expansion can no longer reuse the previous collapsed work-list height. Shared immutable geometry continues to exclude tool-card rows. |
| Disclosure lifetime | Native-host eviction retains the conversation value. Message-level pruning recognizes scoped tool occurrences as block-level pruning already did. No source journal or persisted preference is changed. |
| Find payload | Search still covers the same complete foldable body it reveals. More/fewer controls add no content occurrence; expansion from Find uses the native card's existing `setExpanded` path and therefore records the same disclosure. |
| Active dependency positions | Inserted refs start unselected; append supplies their position; metadata replacement preserves it; branch pruning clears abandoned links; timeline selection clears/reassigns positions; final dense compaction remaps them. `testDependencyPositionsFollowSelectionAndMetadata` covers an abandoned issuer with a retained receipt, metadata replacement, reordered selection and compaction. Existing literal-NUL and every-page-boundary tests remain in the full regression class. |
| Table selection | The action receives the same clicked row and visual column as before. The helper resolves the current table column's original numeric identifier, matching the grid data source's lookup. |

No new source files were added or removed, so no project regeneration is needed.
No helper package or wire protocol changed; helper and Python wire/concurrent/
acceptance suites are not required. The affected app wire tests are rerun below.

### Round-8 adversarial self-review

Reviewed the complete production diff since `3bd0daf3`, checking the indexed
lookup against both directions of reused calls, branch holes, retained receipts
whose issuer was abandoned, metadata replacement, reordered timelines, final
position compaction, and literal IDs. Every neighbour query uses the same index;
there is no remaining `links`/`visible` sort in a lookup. The index is a private,
rebuildable database; source journals and their byte offsets are unchanged.

Actor reentrancy keeps each search's file handle, branch and presentation values
local. Source-prefix validation still fences replacement/truncation/rewrite;
append-only growth retains its established behavior. Cancellation keeps the warm
index, while an actual failure invalidates only caches at the captured stamp.
The old search cannot clear a newer page's index. Existing search cancellation,
100-hit/5,000-record limits and bounded decode runs remain in place.

Checked expansion through timeline rows, legacy activity, the eight-card virtual
list, disclosure pruning, the row/work-list caches and Find's expansion calls.
Both read and diff used the same discarded local boolean, so both now use the
same saved occurrence state. A new native card receives that state before its
model/height are built; standalone test/reference cards retain their existing
optional local-state behavior. The new field affects geometry, not stored tool
arguments, output ownership, permissions or capture.

This review caught an unintended UX change in the initial implementation:
recording the more-lines state through the generic disclosure callback started
an outer fold animation. `testMoreLinesKeepsItsExistingResizeBehavior` failed
first in `round8-motion-first.log` (**0/1/0**, exit 65), with
`Saving inner-card state must not add a new outer fold animation`.
Inner-card changes now use the existing height-invalidation path. This preserves
the former resize behavior instead of adding an animation policy. The final
regression class therefore contains **86 methods** (seven added this round).

For the table, the grid already resolved stable column identifiers; only its
detail-selection path indexed visual positions. No other `clickedColumn` or
`selectedColumn` source indexing remains in Transcript. The exact numbered-fence
fixture and the old-scanner mutation also verify that the earlier canonical
heading fix covers the second hunt without another parser or scanner change.
No owner decision is needed for these behavior-preserving repairs.

### Round-8 mutation checks

All **10** mutations compiled and failed their intended assertion (exit 65),
then restored the production file in `finally`. No setup or compiler failure
counts as a caught mutation. The motion control passed **2/0/0** before its
mutation; the complete restored class then passed **86/0/0**.

| Log / mutation | Failing test | Passed | Failed | Skipped |
| --- | --- | ---: | ---: | ---: |
| `round8-mutation-lookup.log`: Restore the reuse-set join/sort | `testReusedToolDependenciesStayWithinPagingBudget` | 0 | 1 | 0 |
| `round8-mutation-yield.log`: Remove the actor yield | `testPagingCanFinishWhileFindScansReusedCalls` | 0 | 1 | 0 |
| `round8-mutation-cancel.log`: Discard the index on cancellation | `testPagingCanFinishWhileFindScansReusedCalls` | 0 | 1 | 0 |
| `round8-mutation-position.log`: Omit the final dense-position remap | `testDependencyPositionsFollowSelectionAndMetadata` | 0 | 1 | 0 |
| `round8-mutation-branch.log`: Keep abandoned link positions | `testDependencyPositionsFollowSelectionAndMetadata` | 0 | 1 | 0 |
| `round8-mutation-expansion-save.log`: Disconnect saving expansion | `testExpandedReadAndDiffSurviveHostEviction` | 0 | 1 | 0 |
| `round8-mutation-expansion-restore.log`: Omit restoring expansion | `testExpandedReadAndDiffSurviveHostEviction` | 0 | 1 | 0 |
| `round8-mutation-column.log`: Index by visual position | `testReorderedFullTableCellDetailsCopyTheVisibleColumn` | 0 | 1 | 0 |
| `round8-mutation-numbered-fence.log`: Restore the pre-branch scanner | `testNumberedFenceKeepsHeadingCopyBoundaries` | 0 | 1 | 0 |
| `round8-mutation-motion.log`: Route more-lines through the outer fold animation | `testMoreLinesKeepsItsExistingResizeBehavior` | 0 | 1 | 0 |

The lookup reversal took **18.675256 s**; removing the yield delayed the warm
page **1.089727 s** and reversed completion to `[search, page]`. The table
mutation returned A1 in both the details and pasteboard. Restoring the entire
old scanner from `141666ca` broke the new numbered-fence fixture, confirming
that the existing canonical-heading implementation is the relevant fix.

Exact failing-first, control and mutation commands (each run under the shared
lock, in this worktree, with text redirected to its named log):

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript

# round8-failing-first.log — 1/4/0, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testReusedToolDependenciesStayWithinPagingBudget -only-testing:PiAppTests/TranscriptBugRegressionTests/testPagingCanFinishWhileFindScansReusedCalls -only-testing:PiAppTests/TranscriptBugRegressionTests/testExpandedReadAndDiffSurviveHostEviction -only-testing:PiAppTests/TranscriptBugRegressionTests/testReorderedFullTableCellDetailsCopyTheVisibleColumn -only-testing:PiAppTests/TranscriptBugRegressionTests/testNumberedFenceKeepsHeadingCopyBoundaries

# round8-table-first.log — 0/1/0, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testReorderedFullTableCellDetailsCopyTheVisibleColumn

# round8-table-click-first.log — 0/1/0, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testReorderedFullTableCellDetailsCopyTheVisibleColumn

# round8-core-fixed-table-first.log — 4/1/0, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testReusedToolDependenciesStayWithinPagingBudget -only-testing:PiAppTests/TranscriptBugRegressionTests/testPagingCanFinishWhileFindScansReusedCalls -only-testing:PiAppTests/TranscriptBugRegressionTests/testExpandedReadAndDiffSurviveHostEviction -only-testing:PiAppTests/TranscriptBugRegressionTests/testReorderedFullTableCellDetailsCopyTheVisibleColumn -only-testing:PiAppTests/TranscriptBugRegressionTests/testDependencyPositionsFollowSelectionAndMetadata

# round8-selection-cancellation-first.log — 0/0/0, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testReorderedFullTableCellDetailsCopyTheVisibleColumn -only-testing:PiAppTests/TranscriptBugRegressionTests/testPagingCanFinishWhileFindScansReusedCalls

# round8-selection-cancellation-first-compiled.log — 0/2/0, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testReorderedFullTableCellDetailsCopyTheVisibleColumn -only-testing:PiAppTests/TranscriptBugRegressionTests/testPagingCanFinishWhileFindScansReusedCalls

# round8-regression-fixed.log — 85/0/0, exit 0
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests

# round8-motion-first.log — 0/1/0, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testMoreLinesKeepsItsExistingResizeBehavior

# round8-motion-fixed.log — 2/0/0, exit 0
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testMoreLinesKeepsItsExistingResizeBehavior -only-testing:PiAppTests/TranscriptBugRegressionTests/testExpandedReadAndDiffSurviveHostEviction

# round8-mutation-lookup.log — 0/1/0, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testReusedToolDependenciesStayWithinPagingBudget

# round8-mutation-yield.log — 0/1/0, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testPagingCanFinishWhileFindScansReusedCalls

# round8-mutation-cancel.log — 0/1/0, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testPagingCanFinishWhileFindScansReusedCalls

# round8-mutation-position.log — 0/1/0, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testDependencyPositionsFollowSelectionAndMetadata

# round8-mutation-branch.log — 0/1/0, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testDependencyPositionsFollowSelectionAndMetadata

# round8-mutation-expansion-save.log — 0/1/0, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testExpandedReadAndDiffSurviveHostEviction

# round8-mutation-expansion-restore.log — 0/1/0, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testExpandedReadAndDiffSurviveHostEviction

# round8-mutation-column.log — 0/1/0, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testReorderedFullTableCellDetailsCopyTheVisibleColumn

# round8-mutation-numbered-fence.log — 0/1/0, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testNumberedFenceKeepsHeadingCopyBoundaries

# round8-mutation-motion.log — 0/1/0, exit 65
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testMoreLinesKeepsItsExistingResizeBehavior
```

### Round-8 final validation

After restoring all mutations: **1,004 passed, 0 failed, 12 skipped** across
**92 distinct classes**. Counts are test methods. The final gallery rerun replaces
its initial successful run in these totals; controls and mutations are not
double-counted. Every native/focus run used this worktree, its own build root,
and the shared full-lane lock. Serial lanes ran alone.

| Final text log | Suite | Passed | Failed | Skipped |
| --- | --- | ---: | ---: | ---: |
| `round8-regression-final.log` | TranscriptBugRegressionTests | 86 | 0 | 0 |
| `round8-affected-final.log` | 64 affected app classes | 617 | 0 | 7 |
| `round8-timeline-final.log` | TranscriptNativeTimelineBehaviourTests | 30 | 0 | 0 |
| `round8-agent-markdown-final.log` | SubagentMarkdownTests | 19 | 0 | 0 |
| `round8-agent-reader-final.log` | SubagentReaderTests | 55 | 0 | 0 |
| `round8-wire-page-final.log` | TranscriptWirePageTests | 4 | 0 | 0 |
| `round8-history-edge-timing-final.log` | HistoryEdgeTimingTests | 2 | 0 | 0 |
| `round8-history-edit-final.log` | HistoryEditTests | 3 | 0 | 0 |
| `round8-inline-timing-final.log` | InlineSkillPillTimingTests | 1 | 0 | 0 |
| `round8-streaming-serial-final.log` | TranscriptStreamingSerialTests | 1 | 0 | 1 |
| `round8-agent-inputs-final.log` | 6 agent input/navigation classes | 47 | 0 | 0 |
| `round8-agent-adjacent-final.log` | 4 family/metadata/panel/discovery classes | 55 | 0 | 0 |
| `round8-disclosure-final.log` | 6 disclosure/geometry/work/chrome classes | 61 | 0 | 3 |
| `round8-chrome-parity-final.log` | TranscriptNativeChromeParityTests | 5 | 0 | 1 |
| `round8-agent-opening-final.log` | SubagentOpeningTests | 13 | 0 | 0 |
| `round8-gallery-opaque-final.log` | TranscriptBugGalleryTests | 5 | 0 | 0 |

The seven affected-suite skips are the existing opt-in long-history/index
measurements, skill-pill capture, Markdown line-pitch/token-cost measurements,
Markdown sample capture and 70-turn wire measurement. The additional parity
skips are `testProbeDisclosure`, `testProbeWorkSymbols`,
`testSweepWorkSymbolOffsets`, and `testSweepChromeSymbolOffsets` (calibration
probes/sweeps, not behavior tests). The remaining skip is
`TranscriptStreamingSerialTests.testAReplyCountsAsReadOnlyOnceItsEndHasBeenOnScreen`:
`A receipt needs this app's own key, unoccluded window; this desktop cannot provide one.`
That behavior remains **unverified** for the lead's merged gate with the window
prerequisite. No failing test was discarded.

An extra filename-based selector, `MessageVersionTests`, selected zero methods
(`round8-versions-final.log`, **0/0/0**, exit 0), so it contributes no coverage
or class to the totals. The file actually defines `MessageVersionTranscriptTests`
(**8/0/0**) and `ForkFromReplyTests` (**5/0/0**), both already present in the
64-class affected run. `SubagentOpeningTests` then ran alone (**13/0/0**).

Final measured results are **0.328565 s** for all 5,000 dependency lookups and
**0.017038 s** for the concurrent warm page, completion order `[page, search]`.
The production regression also checks every returned receipt. A supplementary
in-memory SQLite `EXPLAIN QUERY PLAN` of the new schema and four lookup shapes
(`round8-query-plan.log`) uses `link_values (kind,value,n)` range searches in
every case, with no temporary ordering B-tree.

Exact final commands (from the worktree, each inside the shared lock wrapper):

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript

# round8-regression-final.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests

# round8-affected-final.log
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

# round8-timeline-final.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptNativeTimelineBehaviourTests

# round8-agent-markdown-final.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentMarkdownTests

# round8-agent-reader-final.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentReaderTests

# round8-wire-page-final.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptWirePageTests

# round8-history-edge-timing-final.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/HistoryEdgeTimingTests

# round8-history-edit-final.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/HistoryEditTests

# round8-inline-timing-final.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/InlineSkillPillTimingTests

# round8-streaming-serial-final.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptStreamingSerialTests

# round8-agent-inputs-final.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentNavigationTests -only-testing:PiAppTests/SubagentEffortTests -only-testing:PiAppTests/InheritedSubagentReaderTests -only-testing:PiAppTests/SubagentCostTests -only-testing:PiAppTests/SubagentDisplayTests -only-testing:PiAppTests/SubagentMetadataTests

# round8-agent-adjacent-final.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/ConversationFamilyTests -only-testing:PiAppTests/MetadataDurabilityTests -only-testing:PiAppTests/SubagentPanelTests -only-testing:PiAppTests/SubagentDiscoveryTests

# round8-disclosure-final.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/NativeWorkListViewportTests -only-testing:PiAppTests/TranscriptTurnFoldTests -only-testing:PiAppTests/TranscriptGeometryCacheTests -only-testing:PiAppTests/TranscriptKeptRowsTests -only-testing:PiAppTests/TranscriptNativeChromeBehaviourTests -only-testing:PiAppTests/TranscriptNativeWorkParityTests

# round8-chrome-parity-final.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptNativeChromeParityTests

# round8-agent-opening-final.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/SubagentOpeningTests

# round8-gallery-opaque-final.log
TEST_RUNNER_PI_TRANSCRIPT_BUG_GALLERY=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript/validation/gallery-round8 scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugGalleryTests

# round8-versions-final.log — selector setup only; zero methods
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/MessageVersionTests
```

### Round-8 visual inspection

Regenerated and inspected **15 PNGs** in `validation/gallery-round8` beneath
this build root: all five scenes in light, dark and narrow presentations.

- `expanded-read-{light,dark,narrow}.png`: after real host eviction/remount,
  lines 68–100 and “Show fewer lines” remain visible; the following reply starts
  directly after the card/footer, with no stale expanded-height gap. The narrow
  capture is **360 pt** wide. The initial successful gallery used a transparent
  scroll backdrop; removed that fixture setting, reran the full gallery class
  (**5/0/0**) and inspected the opaque captures for legibility.
- `reordered-table-{light,dark,narrow}.png`: B is the left column, B1 is selected
  and the detail pane reads B1, in all three appearances/widths. Narrow is the
  existing table window's **440 pt** minimum; the separate regression verifies
  selecting/copying the real detail NSTextView yields B1.
- `transcript-{light,dark,narrow}.png`: heading Copy stays within the 360 pt
  viewport; literal marker diff retains both changed tails, and the ordered
  marker `2.` is highlighted.
- `rows-{light,dark,narrow}.png` and `recovery-{light,dark,narrow}.png`: user
  focus, summary/list text, notice/sub-agent cards and recovered-response phrase
  highlights remain visible. These 12 unaffected-scene files are byte-identical
  to their already-inspected captures after the backdrop-only gallery rerun.

The final diff passed `git diff --check`. No clone directories remain under this
workstream's build root; the final disk check showed **12.62 GiB free**. All locks
owned by this workstream were released. The current lock belongs to another
workstream and was left untouched. Evidence is the text logs and gallery PNGs;
no named result bundle was requested. No installed app, real chats/preferences,
Keychain, paid provider or live capture was used. There is no unresolved product
or owner decision; the desktop-dependent receipt test remains the validation
limit described above.

## Round 9 — shared search decode budget and once-per-record projections

**Confirmed and fixed.** Baseline: `28e1092beb13297d3d8a843b16abc1f74ac40dc3`.
Work remained on `dev/a130-transcript` in this worktree and used only
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript` for builds and
evidence. The new fixtures are generated JSONL with opaque generated provider
metadata; they contain no captured provider traffic or user data.

### Failing-first evidence

Added a search-only observer immediately before each journal JSON decode and at
actual batch yields. It counts record offsets, source bytes, and the largest
sum of bytes between yields; paging's separate reads do not enter these counts.
The original three search read paths were instrumented before changing behavior.

`round9-failing-first.log`: **0 passed / 2 failed**, exit 65.

- `testWideToolSearchDecodesEachRecordOnceAndYieldsItsWholeBudget`: one 8 MiB
  issuer, 40 intervening records and 64 receipts; four receipts also carry 4 MiB
  of generated metadata. A **25,190,196-byte** file decoded **579,221,824 bytes**,
  including the issuer **65 times**. The largest batch decoded **516,265,016
  bytes**, against the **16,777,216-byte** budget. Output counts were correct;
  the work/budget assertions failed.
- `testCapturedWideToolPagesShareTheSearchDecodeBudget`: issuer-only,
  receipts-only, and fully captured pages all violated the budget. The
  receipts-only case decoded **579,221,824 bytes**, with **554,031,779 bytes**
  before yielding. Fully captured rows decoded **33,581,126 bytes**, including
  duplicate receipt reads.

Strengthened the paging part to keep requesting pages until search completed,
so a fast initial page cannot hide a later stalled batch.
`round9-paging-first.log`: **0 passed / 1 failed**, exit 65:

```text
WIDE-SEARCH sourceBytes=25190196 decodedBytes=579221824
peakBatch=516265016 issuerDecodes=65 pageSeconds=1.0875807499978691
XCTAssertEqual failed: Optional(65) is not equal to Optional(1)
XCTAssertLessThanOrEqual failed: 516265016 is greater than 16777216
XCTAssertLessThan failed: 1.0875807499978691 is not less than 0.75
```

### Implementation and dependency sweep

A `SearchPass` now owns the captured snapshot, planner presentation, input
values, query, budget and match cache. All journal record decoding goes through
`searchRecord`: yield before the next record would exceed 16 MiB, after reaching
that limit, or after 32 records. A single oversized record runs alone. Traversal
also yields every 32 primary positions, including cache hits. The source/export
search uses the same decoder and budget, preserving its existing source text.

An issuer and its latest receipts are projected together, one peer at a time.
The cache retains only match count/preview, drawing/omission metadata and small
card-ownership facts, keyed by **record offset** (and call ID within that offset).
It retains no decoded record or full body. Receipts and tool-start dependencies
reuse the completed issuer result, including when the search cursor starts
inside a round. Reused provider IDs cannot alias separate issuer offsets. A
superseded receipt uses the issuer's cached planner ownership without rereading
its discarded body.

The cache uses unique tables in the existing private, mode-0600, rebuildable
index file and its bounded SQLite pager. Tables are dropped on completion,
early return, cancellation or failure. Freed pages remain reusable until the
index's existing eviction/quit cleanup removes the file. No journal is changed.
This avoids both an unbounded dictionary of large projections and an LRU that
would reread an evicted issuer. A pass is one captured `searchContent` page;
a later page captures its own display/revision as required by the existing
append-safe search contract.

Separate same-pattern findings confirmed in the sweep:

| Pattern | Before-fix evidence | Resolution / coverage |
| --- | --- | --- |
| Captured call/receipt overlay separately reread peers | 579.2 MB decoded from the 25.2 MB fixture; fully captured receipts read twice | Shares the pass cache/budget; issuer-only, receipt-only and complete overlays |
| Many tool-start records reread one large issuer | `testManyToolStartsReuseTheirLargeIssuersProjection`: 1,133,285,925 bytes decoded; issuer **129** times | Cached planner card ownership; both beginning-of-history and inside-round cursors |
| Shared operation IDs reread the first large operation body | `testRecoveryPresenceDependenciesDoNotDecodeLargePeerBodies`: 302,060,159 bytes from 16,840,353 bytes; largest repeat **35**, largest batch 285,226,782 bytes | Only a checkpoint needs its operation's presence; indexed synthetic planner anchor, no peer-body read |
| Reused wide issuer IDs and orphan ledgers repeat dependencies | `testReusedWideIssuersAndOrphanLedgersShareOnceOnlyDecodes`: repeat/byte/batch failures for saved and partial/full captured pages | Two 32-call rounds reuse all call IDs; assistant and orphan-ledger variants; 4 overlays × 3 start positions each |
| Page boundaries revisit source or receipt | Byte/offset checks added to `testEveryPageSplitKeepsReusedCallsAndLatestReceiptsSeparate` fail on the original implementation | Every contiguous page of the reused-ID/stale-receipt fixture, preserving existing native occurrence comparisons |

For these expanded fixtures, restored the instrumented pre-fix reader and ran
`round9-shapes-baseline.log`: **0 passed / 4 failed**, exit 65. Restored the fix
before continuing. Presence-only presentation-source links already avoided
reading their bodies; the new implementation preserves that property. The
recovery fixture includes 63 suppressed ledgers plus one genuinely orphaned
ledger, whose displayed prose remains searchable.

### Adversarial review and cache pressure

The first cache design used SQLite TEMP tables with a 512 KiB cache request.
A direct probe of the Mac's actual SQLite library showed that TEMP pages remained
resident. Strengthened `testSearchMatchCachesStayIsolatedAndReleaseAfterUse`
from 5,000 to **50,000** 240-character summaries before fixing that design:
`round9-cache-memory-first.log`, **0 passed / 1 failed**:

```text
SEARCH-CACHE summaries=50000 residentBytes=13750016
XCTAssertLessThan failed: 13750016 is not less than 2097152
```

The private index's file-backed pager uses **667,904 resident bytes** for the
same 50,000 summaries (`round9-cache-memory-control.log`, **3/0/0**). The test
also verifies independent simultaneous caches, exact embedded-NUL/Unicode
previews and call IDs, offset-scoped ownership, and table disposal. Temporary
tables are deliberately not used for these match summaries.

Reviewed the new search paths against the earlier renderer-input table and
projection corpus. No separate Markdown/card presentation was introduced:

| Search/dependency input | Projection / decoding rule |
| --- | --- |
| Unloaded primary row | One `searchRecord` call, then the existing `displayedMessage` and normalized planner |
| Issuer reached through a receipt or start record | Same offset cache as primary traversal; projected once, then reused |
| Latest receipt, including a captured receipt | One `searchRecord` call for its recorded result metadata; captured row and captured tool values remain authoritative |
| Ordinary captured row | Captured planner rows, raw disclosure and fetched arguments; no journal body decode |
| Captured completed card with an off-page receipt | Same joined planner and native `toolPayload`; input stays with issuer, output with receipt, drawing metadata still points to the loaded card |
| Superseded receipt | Cached issuer ownership; standalone captured receipts retain their displayed Markdown |
| Tool-start execution | Own primary decode plus cached issuer card-presence fact; no issuer reread |
| Ledger's accepted source | Indexed active-branch presence only; captured orphan presentation remains the captured planner's decision |
| Compaction's operation | Indexed operation presence only, preserving the planner's suppression rule |
| Shared-operation execution | Its own displayed row; no unrelated operation-body dependency |
| Fetched inputs / agent state | Same captured occurrence-keyed documents and agent presentation; captured tool values are not re-normalized over the display's values |
| Source/export search | Same byte-budgeted decoder, original `ConversationContent.text` projection |

Reviewed cache lifetime across actor yields, simultaneous searches, cancellation,
index replacement, snapshot validation and early pagination. File handles and
immutable branches remain pass-owned. Existing append/rewrite/truncation checks,
abandoned-row handling, source-copy guards, Find focus and reader navigation are
unchanged. Matched previews remain limited to the existing 240-character
representation; full issuer/receipt bodies never enter the match cache.

Added an oversized-record test (three 20 MiB records, source and rendered search)
and byte/once-only checks to the existing **5,000 reused-ID pairs** paging test.
Single-record decoding remains indivisible: the bound is 16 MiB or that one
larger record, never that record plus a neighbour. Index construction and the
existing snapshot hash are separate from journal payload decoding.

### Mutation checks

All six mutations were applied separately, run against the compiled test host,
and restored before the final runs. Each returned **0 passed / 1 failed**, exit
65, with assertion failures (not build failures).

| Log | Mutation | Failing assertion |
| --- | --- | --- |
| `round9-mutation-memo.log` | Remove completed-offset cache returns | Issuer 65 times; 1,637,027,293 decoded bytes exceeds the 25,190,196-byte file |
| `round9-mutation-receipt.log` | Do not memoize receipt match results | 0 output hits instead of 64 |
| `round9-mutation-budget.log` | Remove the pre-decode byte-budget check | Peak 16,783,448 exceeds 16,777,216 bytes |
| `round9-mutation-yield.log` | Remove `await Task.yield()` | Search completes before the queued page; only one page served |
| `round9-mutation-memory.log` | Return summaries to SQLite TEMP tables | 13,750,016 resident bytes exceeds the generous 2 MiB assertion |
| `round9-mutation-cache-dispose.log` | Remove cache-table disposal | 6 retained tables instead of 3; then 9 instead of 6 |

The no-yield mutation retains correct byte accounting, but still fails the
actual paging-order assertions. Thus the regression does not merely trust a
reported budget event as proof that the reader was served.

All commands below run in the worktree, with the shared full-lane lock held by
`validation/run-round3-case.py`, which records its owner/PID and releases only
its own lock in `finally`. `run-round9-mutations.py` restores source files in
`finally`; `run-round9-completion.py` also restores the memory mutation. Logs
are under the build root's `validation` directory. Exact native commands:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript

# round9-failing-first.log — instrumented original reader, 0/2
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testWideToolSearchDecodesEachRecordOnceAndYieldsItsWholeBudget \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testCapturedWideToolPagesShareTheSearchDecodeBudget

# round9-paging-first.log — original reader with repeated paging, 0/1
# Also the exact command for mutation-{memo,receipt,budget,yield}, each 0/1
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testWideToolSearchDecodesEachRecordOnceAndYieldsItsWholeBudget

# round9-shapes-baseline.log — original reader restored, 0/4
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testReusedWideIssuersAndOrphanLedgersShareOnceOnlyDecodes \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testRecoveryPresenceDependenciesDoNotDecodeLargePeerBodies \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testManyToolStartsReuseTheirLargeIssuersProjection \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testEveryPageSplitKeepsReusedCallsAndLatestReceiptsSeparate

# round9-cache-memory-first.log and mutation-{memory,cache-dispose}, each 0/1
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testSearchMatchCachesStayIsolatedAndReleaseAfterUse

# round9-cache-memory-control.log — final file-backed cache, 3/0
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testSearchMatchCachesStayIsolatedAndReleaseAfterUse \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testWideToolSearchDecodesEachRecordOnceAndYieldsItsWholeBudget \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testPagingCanFinishWhileFindScansReusedCalls
```

### Final sweep: large agent arguments in sibling joins

The initial broad run passed **870/0/7**, but the final code audit found another
same-function instance: `searchIssuer` normalized the issuer's entire tool list
for each receipt. `AgentTranscriptPresentation.presentAgentState` constructs
`SubagentToolView` for every control tool, parsing its input/output JSON. Thus
journal memoization alone did not bound repeated sibling argument processing.

`testWideAgentArgumentsDoNotRepeatAcrossNeighbourProjections` uses 64 agent calls,
one with a generated large extra argument member and a short displayed task.
The first 16 MiB experiment passed the generous 750 ms paging bound at 655 ms,
so it is not failing-first evidence. A 32 MiB member plus its record envelope
exceeded the existing reader record limit: the fixture was rejected as
`unreadableRecord` during setup (`round9-agent-work-first-large.log`, 0/1). No
production limit was raised. A **valid 28 MiB** member reproduced the stall:

```text
# round9-agent-work-first-bounded.log — 0 passed / 1 failed, exit 65
AGENT-DEPENDENCIES decodedBytes=46161557 pageSeconds=1.0019883333006874 pages=8
XCTAssertLessThan failed: 1.0019883333006874 is not less than 0.75
```

The receipt join now supplies only that receipt's own `ToolView` to agent
normalization. Its values are identical to the native card's inputs; sibling
cards are irrelevant to the join. The complete source still uses its full
canonical planner rows, with the individually computed card payloads. Captured
rows still restore the exact captured values. The control passes at **216 ms**
(`round9-agent-work-control.log`, **1/0/0**) with identical occurrence and source
byte counts. This fixes the repeated sibling processing without changing any
card presentation.

Mutation `round9-mutation-agent-siblings.log` restores the full sibling list in
that join. The same test fails its actual paging bound again. This is the
**seventh** independent mutation; the six cache/budget mutations above remain
applicable. Exact command for failing-first, control and mutation:

```sh
PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript \
  scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testWideAgentArgumentsDoNotRepeatAcrossNeighbourProjections
```

Reran all affected classes after this final source change. The earlier broad
logs are retained as `round9-*-before-agent.log`; final totals below count only
the last run of each class, not repeated controls or expected failures.

### Final validation

**871 passed / 0 failed / 7 skipped across 77 classes.** All seven mutations failed as expected. No unexpected failure remains in the final runs.

| Text log | Class/suite | Passed | Failed | Skipped |
| --- | --- | ---: | ---: | ---: |
| `round9-regression-final.log` | TranscriptBugRegressionTests | 94 | 0 | 0 |
| `round9-affected-final.log` | 64 affected history/Find/rendering/workspace classes | 617 | 0 | 7 |
| `round9-timeline-final.log` | TranscriptNativeTimelineBehaviourTests | 30 | 0 | 0 |
| `round9-agent-markdown-final.log` | SubagentMarkdownTests | 19 | 0 | 0 |
| `round9-agent-reader-final.log` | SubagentReaderTests | 55 | 0 | 0 |
| `round9-wire-page-final.log` | TranscriptWirePageTests | 4 | 0 | 0 |
| `round9-history-edge-timing-final.log` | HistoryEdgeTimingTests | 2 | 0 | 0 |
| `round9-history-edit-final.log` | HistoryEditTests | 3 | 0 | 0 |
| `round9-agent-inputs-final.log` | 6 agent input/navigation classes | 47 | 0 | 0 |

Final measurements from `round9-regression-final.log`:

```text
CAPTURED-WIDE rows=1 sourceBytes=25190196 decodedBytes=16795651 peakBatch=12583581
CAPTURED-WIDE rows=64 sourceBytes=25190196 decodedBytes=25190045 peakBatch=12589588
CAPTURED-WIDE rows=105 sourceBytes=25190196 decodedBytes=16790563 peakBatch=12583581
FIND-PAGING pairs=5000 page-seconds=0.010944916633889079 order=["page", "search"]
REUSED-DEPENDENCIES pairs=5000 lookups=5000 seconds=0.31084991665557027
SEARCH-CACHE summaries=50000 residentBytes=667904
AGENT-DEPENDENCIES decodedBytes=46161557 pageSeconds=0.2109563749982044 pages=8
WIDE-SEARCH sourceBytes=25190196 decodedBytes=25190045 peakBatch=12589588 issuerDecodes=1 pageSeconds=0.09787470835726708 order=["page", "page", "page", "page", "page", "page", "search", "page"]
```

The seven skips are existing opt-in measurements/captures; none is an ordinary failing assertion:

- `HistoryIndexFilesTests.testTheIndexOfALongChat`: Set PI_PERF_HISTORY_JOURNAL to measure a long chat's index.
- `HistoryReaderOpenPerformanceTests.testIndexingAKeptJournal`: Set PI_PERF_OPEN_JOURNAL to measure indexing a long chat.
- `InlineSkillPillTests.testCaptureSkillPillLooks`: Set PI_APP_UI_SCREENSHOT_ROOT to render the skill pill captures.
- `MarkdownTextSurfaceTests.testMeasureLinePitches`: A measurement, run on request
- `MarkdownTextSurfaceTests.testMeasureTokenCostOnOpenLists`: A measurement, run on request
- `MarkdownTextSurfaceTests.testRenderSampleForReview`: Set PI_MARKDOWN_SNAPSHOT_DIR to render
- `WireContractTests.testPerTokenSnapshotWithSeventyFinishedTurns`: Set PI_PERF_WIRE=1 to measure the per-token snapshot with 70 finished turns

Exact final commands, each run inside the same shared-lock wrapper:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript

# round9-regression-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests

# round9-affected-final.log
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

# round9-timeline-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptNativeTimelineBehaviourTests

# round9-agent-markdown-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentMarkdownTests

# round9-agent-reader-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentReaderTests

# round9-wire-page-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptWirePageTests

# round9-history-edge-timing-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/HistoryEdgeTimingTests

# round9-history-edit-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/HistoryEditTests

# round9-agent-inputs-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentNavigationTests \
  -only-testing:PiAppTests/SubagentEffortTests \
  -only-testing:PiAppTests/InheritedSubagentReaderTests \
  -only-testing:PiAppTests/SubagentCostTests \
  -only-testing:PiAppTests/SubagentDisplayTests \
  -only-testing:PiAppTests/SubagentMetadataTests
```

No helper or wire implementation changed; the full helper and Python wire/concurrent/acceptance gates were not required for this app-only fix. No UI layout or appearance changed in round 9; the inspected round-8 galleries remain the UI evidence. No source files were added or removed, so project regeneration was unnecessary. There is no unresolved product decision or unfixed round-9 finding.

The final `git diff --check` passed. No clone folders remain under this build root, and no shared lock remains owned by this workstream. The rejected oversized experiment fixture was removed; 12.01 GiB remained free. Evidence is in text logs; no named result bundle was requested. No installed app, real preferences/chats, Keychain, live capture or paid provider was used. `scripts/test-lanes.py list` classifies `TranscriptBugRegressionTests` as serial (pasteboard, timing), so the new timing assertions also run alone in the lead’s full gate.

## Round 10 — continuation summaries, bounded issuer payloads, failed cards

The three review findings are **confirmed and fixed**. This round changes the
app's Find projection/cache only; it does not change helper wire behavior,
permissions, capture, credentials, saved source, or native card presentation.
All fixtures are generated under the test's temporary directory. The installed
app was not launched. Native runs use this workstream's build root and hold the
shared full-lane lock, including the pasteboard/timing regression class.

### Failing-first evidence

`round10-failing-first-tests.log`: **0 passed / 3 failed**, exit 65, before any
production fix. The earlier `round10-failing-first.log` is a test-compilation
failure (Swift 6 isolation on the native test helper), not reproduction evidence;
the helper was made static and the same three cases rerun.

| Finding | Regression | Original failure |
| --- | --- | --- |
| Failed edit/write work-line summaries disappear | `testFailedToolSummariesEqualDisplayedCardsSavedAndLive` | `Permission denied` returned `[]` instead of receipt `result`; native card/row comparison lacked that displayed line. Bash is the control: its output already displays the full error. |
| An unsupported timeline retains all receipt bodies | `testWideLegacyIssuerRetainsOnlyBoundedMatchState` | 32 × 256 KiB receipts retained **8,390,038 bytes** of accumulated projected card text. The original 128 KiB assertion failed. |
| Continuations recreate dependency projections | `testFindContinuationsDecodeDependenciesOnceAcrossTenPages` | **10,050 decodes**, **3,029,378 decoded bytes** for a **308,604-byte** generated journal across ten pages; expected every record at most once. The test took **310.189 s**. |

```text
CONTINUATION-COST pages=10 decodes=10050 bytes=3029378 source=308604
RETAINED-SEARCH bytes=8390038 source=8403230
XCTAssertEqual failed: ("[]") is not equal to ("[\"result\"]") - write
```

The memory case was subsequently strengthened to **64 × 1 MiB receipts** and a
2 MiB bound that includes the SQLite pager, retained projection fragments,
matcher boundary/snippet, and the current replay fragment. This measures the
search's retained projection state, not the test host's RSS or the fixture
builder's source arrays. Source decoding continues to obey the existing shared
16 MiB/32-record budget, with one oversized source record alone. A single native
card's transient decode/render remains necessary; the search no longer retains
the sum of those cards or joins all their bodies into a second large string.

The legacy planner displays both its cards and standalone receipt rows. The
expected total is therefore **128 displayed occurrences**, not 64. Paired
supported timelines continue to own each output only once, in their receipt.

### Implementation and presentation inputs

- The round-7 input table treated work-line summaries as chrome. Failed edit/write
  summaries are an exception: they are the only visible error text.
  Failed `.diff` cards use the actual `TranscriptToolRow.Model.summary` when
  failure output exists. This is precisely the work row's first displayed error
  line. Hidden later edit/write error lines remain unsearchable; bash keeps its
  displayed full output. Failed cards without output do not duplicate the path.
  Both native action-row search and history use this same summary input.
- `ConversationContent.Presentation.parts` exposes the canonical planner's
  ordered text/card fragments. The existing whole-text projection uses the same
  fragments. History consumes them incrementally, preserving interleaving,
  repeated card positions, multiline queries, case folding and source mode.
- Per-issuer card fragments spill after 64 KiB to an atomically created
  mode-0600 scratch descriptor (`mkstemp`).
  The file is **unlinked immediately after opening, before payload writes**;
  completion, cancellation and process exit close it without leaving a payload
  copy. It is never retained by a continuation. Only source offsets, match
  counts, bounded displayed snippets and ownership facts survive in the existing
  private index file's bounded SQLite pager. Replaying an ordered/repeated card
  reads the scratch fragment, not the journal or JSON decoder again.
- One continuation cache is retained. Its scope includes the journal path/stamp,
  query, rendered/source mode, managed-child mode and a digest of all captured
  display inputs. It is reused only at the expected next cursor. Exhaustion,
  replacement, cancellation/failure, index eviction or reader shutdown releases
  it. A generation guard prevents an older search from replacing a newer lease.
  Captured payloads are hashed, not retained by this lease.

| Renderer/search input | Scope evidence and value used |
| --- | --- |
| Planner rows, source text, timeline state, tool state/input/output and native delivery metadata | The captured `TranscriptMessage` values; their complete encoded values enter the display digest. The active branch and journal stamp scope unloaded rows. |
| View Raw | Sorted `rawReplies`; each timeline part still uses its own completion state through the shared projection. |
| Fetched arguments | Occurrence key plus full input, truncation flag, byte count and streaming flag; the same document reaches the card model. |
| Agent display | ID, managed-child/busy/family-waiting flags, child numbers, efforts, costs, availability, coordination entries, child summaries and held-child set all enter the digest. Unloaded rows use that captured presentation. |
| App-only tool fields excluded from wire coding | Original availability title/reason and all subagent cost-presentation fields are added explicitly to the digest. |
| Failed work-row text | The original model's summary, outcome and nonempty failure output; fetched arguments replace the body but not that work line. |
| Receipt ownership and recovery context | Active-branch issuer/latest-receipt links, captured standalone rows, and source/operation presence remain the planner's inputs. Unsupported timelines retain their unsupported status. |

### Same-function sweep and adversarial checks

The 1,000-call baseline also exposed redundant planning of all sibling timeline
segments for each individual receipt. `round10-timeline-first.log` is **1 passed /
1 failed**: scope-invalidation checks passed; the new in-flight paging probe took
**0.910916 s**, failing its 0.75 s bound. The join now receives only its own call's
segments from a precomputed grouping, including after a captured-row overlay.
The full issuer still projects its complete canonical plan. Unsupported timelines
are not filtered into apparently supported ones. The first control reduced the
paging probe to **0.051105 s** and ten-page search to **3.745 s**.

A summary byte-bound test found another instance of the retention pattern:
240 graphemes can be many kilobytes. In `round10-regression-control.log`,
`testSearchSummarySnippetsBoundLongGraphemesAndKeepTheMatch` failed at **16,416**
and **16,399 bytes** against 4,096. Snippets now have both the existing character
limit and a 4 KiB UTF-8 limit; an oversized leading grapheme cannot displace the
matched text. The transcript text and occurrence counts are unchanged.

The incremental matcher was checked against Foundation's whole-string search,
including Unicode folding, decomposed characters, NUL, overlapping needles,
multiline boundaries and CR/LF. The first extracted-code probe found **70/2,200**
differences (`round10-fragment-fuzz-first.log`): a CR at a fragment end must wait
for the joining LF, and snippet continuation must preserve whole-character
context. Both were corrected before committing. The control and native corpus
now compare all 2,200 cases. The standalone probe compiled the exact extracted
`SearchText` code with Foundation using the workstream's module cache; it did
not substitute a separate implementation.

Additional coverage checks query/display/journal/restart invalidation, cache
release, cancellation while spilling, anonymous scratch lifetime, reordered and
repeated timeline cards, exact cross-card newline matching, full fetched inputs,
all earlier page splits/reused IDs/orphan ledgers, and saved/live native card
payloads. Navigation code is unchanged: refreshing results still does not create
focus or override reader navigation. No new owner decision is required.

### Projection and unanswered-call batching

The stronger 64 MiB receipt fixture exposed a separate same-function gap even
with retained memory bounded: `round10-payload-paging-first.log` failed at
**4.351594 s** paging delay, while retaining **1,159,773 bytes**. Decoding had a
budget, but rendering all receipts within that budget was still synchronous.
Each receipt projection now yields as well. A scratch fragment replay already
yields independently of source decoding.

The no-receipt path also bypassed the source-read budget entirely. With an
explicit unsupported timeline and 10,000 unanswered calls,
`round10-unanswered-legacy-first.log` failed at **5.755939 s**, against baseline
paging **0.000455 s + 0.75 s**. The metadata/ownership loop and default fragment
projection loop now yield every 32 items, including when no receipt exists.
These are changes in the same dependency function, with separate regressions
and mutations. No tool is executed by either fixture.

### Separate existing issue recorded, not changed

`packages/swift-host/Sources/PiAgentCore/ResponseTimeline.swift:125`: an older
assistant record without `nativeResponseTimeline`, containing thousands of
canonical parts, goes through `canonical` → `consume(.replace)` for every part.
Each consume scans preceding segments repeatedly and rebuilds their part keys.
This helper file is identical to `dev/next` (`git diff dev/next --` that file is
empty). It is outside this workstream's assigned files/functions, so it is
recorded for separate work under the scope rule.

The initial 5,000-call no-receipt fixture hit this existing constructor as well
as Find's loops: `round10-unanswered-first.log` failed with **36.312958 s** paging
delay. An extracted, otherwise unchanged copy of that helper source confirms
quadratic construction independently (`round10-legacy-canonical.log`):

```text
LEGACY-CANONICAL parts=1000 seconds=1.1148662082850933 segments=1000
LEGACY-CANONICAL parts=2000 seconds=4.631572958431207 segments=2000
```

Command: `swift -module-cache-path
/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript/swift-probe-cache
/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript/validation/round10-legacy-canonical.swift`.
The generated probe copies `ResponseTimeline.swift` and appends two calls to
`canonical` over generated `toolArguments` tuples, measuring monotonic time.
The committed unanswered-call regression supplies a valid explicit unsupported
timeline so it isolates the new Find batching failure instead of timing this
separate constructor. The 1,000-call continuation test still exercises ordinary
legacy canonicalization and bounds its total time generously.

### Mutation and final validation

All **10/10 mutation probes** failed their behavioral regression, and the production sources were restored before the final runs. Each mutation ran only its named method in `TranscriptBugRegressionTests` under the shared lock.

| Mutation (log `round10-mutation-<name>.log`) | Regression | Result |
| --- | --- | --- |
| `failure-summary` | `testFailedToolSummariesEqualDisplayedCardsSavedAndLive` | 0 passed / 1 failed; exit 65 |
| `retained-payloads` | `testWideLegacyIssuerRetainsOnlyBoundedMatchState` | 0 passed / 1 failed; exit 65 |
| `continuations` | `testFindContinuationsDecodeDependenciesOnceAcrossTenPages` | 0 passed / 1 failed; exit 65 |
| `scope` | `testContinuationSummariesInvalidateForQueryDisplayAndJournalChanges` | 0 passed / 1 failed; exit 65 |
| `timeline-neighbours` | `testFindContinuationsDecodeDependenciesOnceAcrossTenPages` | 0 passed / 1 failed; exit 65 |
| `snippet-bytes` | `testSearchSummarySnippetsBoundLongGraphemesAndKeepTheMatch` | 0 passed / 1 failed; exit 65 |
| `fragment-crlf` | `testFragmentSearchMatchesFoundationAcrossUnicodeAndLineEndings` | 0 passed / 1 failed; exit 65 |
| `anonymous-spill` | `testSpilledCardsKeepPlannerOrderWithoutDecodingRepeatedParts` | 0 passed / 1 failed; exit 65 |
| `receipt-yield` | `testWideLegacyIssuerRetainsOnlyBoundedMatchState` | 0 passed / 1 failed; exit 65 |
| `unanswered-yield` | `testWideUnansweredIssuerYieldsWithoutReceiptDecodes` | 0 passed / 1 failed; exit 65 |

Selected behavioral mutation evidence:

```text
failure-summary: XCTAssertEqual failed: ("nil") is not equal to ("Optional(1)")
retained-payloads: XCTAssertLessThan failed: ("68271443") is not less than ("2097152") - An issuer must retain summaries, never its accumulated receipt payloads
continuations: XCTAssertLessThanOrEqual failed: ("3029378") is greater than ("308604") - ten continuation pages
scope: XCTAssertTrue failed - journal
timeline-neighbours: XCTAssertLessThan failed: ("31.031710083247162") is not less than ("12.0") - Wide dependency planning must remain linear
snippet-bytes: XCTAssertLessThanOrEqual failed: ("16399") is greater than ("4096")
fragment-crlf: XCTAssertEqual failed: ("45") is not equal to ("0")
anonymous-spill: XCTAssertTrue failed - Spilled payloads must have no surviving pathname
receipt-yield: XCTAssertLessThan failed: ("4.4646690000081435") is not less than ("0.75") - Receipt projection work must yield as well as its source reads
unanswered-yield: XCTAssertLessThan failed: ("5.387331666657701") is not less than ("0.750345041626133") - Metadata-only and unmatched-card projection loops must also yield
```

The initial `failure-summary-compile` and `retained-payloads-compile` mutation attempts failed compilation (unused binding and a provably unreachable branch). They are retained as logs but **not counted as mutation proof**. The probes were adjusted to compile, then failed the assertions above. `round10-budget-controls-compile.log` likewise records a deprecated Swift initializer caught by warnings-as-errors before the corrected four-control run passed.

Final focused native runs: **882 passed / 0 failed / 7 opt-in skips**, across **77 classes**. Serial classes ran alone with parallel execution disabled; the remaining classes were grouped. Every run used the workstream build root and held/released its own full-lane lock.

| Text log | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| `round10-regression-final.log` | 105 | 0 | 0 |
| `round10-affected-final.log` | 617 | 0 | 7 |
| `round10-timeline-final.log` | 30 | 0 | 0 |
| `round10-agent-markdown-final.log` | 19 | 0 | 0 |
| `round10-agent-reader-final.log` | 55 | 0 | 0 |
| `round10-wire-page-final.log` | 4 | 0 | 0 |
| `round10-history-edge-timing-final.log` | 2 | 0 | 0 |
| `round10-history-edit-final.log` | 3 | 0 | 0 |
| `round10-agent-navigation-final.log` | 7 | 0 | 0 |
| `round10-inherited-agent-reader-final.log` | 7 | 0 | 0 |
| `round10-agent-inputs-final.log` | 33 | 0 | 0 |

Final stress measurements and decode evidence (`round10-regression-final.log`):

```text
CONTINUATION-COST pages=10 decodes=1041 bytes=307517 source=308604
DEPENDENCY-COST ten continuation pages sourceBytes=308604 decodedBytes=307517 peakBatch=90871 largestRepeat=1
FRAGMENT-FUZZ comparisons=2200 failures=0
WIDE-PAYLOAD pageSeconds=0.42220612498931587
RETAINED-SEARCH bytes=1159773 source=67132798
DEPENDENCY-COST wide legacy receipts sourceBytes=67132798 decodedBytes=67132647 peakBatch=1048777 largestRepeat=1
WIDE-TIMELINE pageSeconds=0.004112750058993697
UNANSWERED-WIDE pageSeconds=0.4506480833515525 baseline=0.00037804164458066225
```

The seven skips are the existing opt-in long-journal/open-performance fixtures, InlineSkillPill capture, three MarkdownTextSurface captures, and WireContract per-token measurement; the final logs include their skip reasons. No unrelated native test failed. The regression log contains eight existing SQLite fixture-cleanup warnings (temporary directories removed before their readers deinitialize), also eight in `round9-regression-final.log`; these are not new production failures. Every new round-10 journal fixture explicitly releases its reader indexes before directory removal.

Exact final commands (run from this worktree; the lock wrapper records each argument array in the corresponding JSON):

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript

# round10-regression-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests

# round10-affected-final.log
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

# round10-timeline-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptNativeTimelineBehaviourTests

# round10-agent-markdown-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentMarkdownTests

# round10-agent-reader-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentReaderTests

# round10-wire-page-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptWirePageTests

# round10-history-edge-timing-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/HistoryEdgeTimingTests

# round10-history-edit-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/HistoryEditTests

# round10-agent-navigation-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentNavigationTests

# round10-inherited-agent-reader-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/InheritedSubagentReaderTests

# round10-agent-inputs-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentEffortTests \
  -only-testing:PiAppTests/SubagentCostTests \
  -only-testing:PiAppTests/SubagentDisplayTests \
  -only-testing:PiAppTests/SubagentMetadataTests
```

Exact failing-first and mutation commands use the same environment and lock:

```sh
# round10-failing-first-tests.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFindContinuationsDecodeDependenciesOnceAcrossTenPages \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testWideLegacyIssuerRetainsOnlyBoundedMatchState \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFailedToolSummariesEqualDisplayedCardsSavedAndLive

# round10-mutation-failure-summary.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testFailedToolSummariesEqualDisplayedCardsSavedAndLive

# round10-mutation-retained-payloads.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testWideLegacyIssuerRetainsOnlyBoundedMatchState

# round10-mutation-continuations.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testFindContinuationsDecodeDependenciesOnceAcrossTenPages

# round10-mutation-scope.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testContinuationSummariesInvalidateForQueryDisplayAndJournalChanges

# round10-mutation-timeline-neighbours.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testFindContinuationsDecodeDependenciesOnceAcrossTenPages

# round10-mutation-snippet-bytes.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testSearchSummarySnippetsBoundLongGraphemesAndKeepTheMatch

# round10-mutation-fragment-crlf.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testFragmentSearchMatchesFoundationAcrossUnicodeAndLineEndings

# round10-mutation-anonymous-spill.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testSpilledCardsKeepPlannerOrderWithoutDecodingRepeatedParts

# round10-mutation-receipt-yield.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testWideLegacyIssuerRetainsOnlyBoundedMatchState

# round10-mutation-unanswered-yield.log
scripts/test-macos.sh -parallel-testing-enabled NO -only-testing:PiAppTests/TranscriptBugRegressionTests/testWideUnansweredIssuerYieldsWithoutReceiptDecodes
```

Adversarial review compared the new diff with `2c0c59843dacaa6b5314ead656ae4d95ac91ee3f`: checked every dependency decode route, cache/statement lifetime under actor reentrancy, generation and snapshot guards, input-digest parity, output ownership, unsupported/repeated planner fragments, and cleanup on success/cancellation. The same-function gaps found during this review have failing-first and mutation evidence above. The separately recorded legacy `ResponseTimeline.canonical` slowdown is unchanged and remains for its owning workstream.

No helper or wire implementation changed, so full helper and Python wire/concurrent/acceptance runs were not required. No UI layout/appearance changed; existing inspected gallery evidence still applies. No files were added or removed. No new owner decision is required.

Final `git diff --check` passed. No clone folders remain under this workstream's build root; all locks owned by this workstream were released. About 12 GiB remained free after validation. Evidence is in text logs under `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript/validation`; no named result bundle was requested. No installed app, real preferences/chats, Keychain, live capture or paid provider was used.


## Round 11 — focusable diff inputs and shared card expansion

Reviewed against pushed commit `bca9e23921373e63204cff1b47ca3ea3d0a56faa` on 2026-10-20. Both reported findings are confirmed. The five new tests were added and run before changing production code: **0 passed / 5 failed / 0 skipped**, exit 65, `round11-failing-first.log`.

| Finding | Regression and failing-first evidence | Change |
| --- | --- | --- |
| **Confirmed + fixed:** failed edit/write inputs filtered as receipt-owned output | `testFailedEditInputsRemainFocusableWithCapturedReply`, `testFailedWriteInputsRemainFocusableWithCapturedReply`, `testFailedMultiEditInputsRemainFocusableWithCapturedReply`: search returned the expected input counts, then `Failed edit input occurrence 0 is focusable` (and write/multi-edit equivalents) timed out. Native classification also returned `false` for `old input` / `new input`. | Classify native diff lines and Before/After source views as requested input before applying receipt-output ownership. Status banners and counters remain outside the input payload. |
| **Confirmed + fixed:** repeated timeline cards disagree about expansion | `testRepeatedReadCardsShareExpansion`, `testRepeatedDiffCardsShareExpansion`: `[true, false, false]` instead of `[true, false, true]`, followed by `An expand action must never toggle an already-true stored value`. | Cards emit the expanded value they display; the occurrence disclosure stores that value and republishes all sibling rows in the same pass. Inner expansion keeps its existing immediate resize rather than starting an outer fold animation. |

The navigation corpus mounts failed edit, write and two-edit-call replies with either just their captured issuer or the complete saved group. Every reported `inputneedle` occurrence must retain its ordinal and resolve to native text with a focused highlight. It asserts the receipt-owned output exclusions are present, so passing cannot result from accidentally searching those outputs twice. “Multi-edit” here means two distinct `edit` calls in one response, matching the supported tool schema.

The expansion corpus renders A/B/A argument segments for both read and diff cards. It checks synchronous sibling updates, isolation of B, collapse through the second card, a stale expand action while the stored value is already true, direct disclosure changes, refresh, host eviction/remount and exact cached-versus-fitting heights. It also navigates all three Find occurrences through the same expansion path.

### Display semantics and state audit

| Displayed content/state | Native classification or source of truth |
| --- | --- |
| Generic I/O input / output | The native `Tool input` section is input; the output section remains receipt-owned. |
| Terminal command / output | The command is input; the capped terminal output remains output. |
| Read body and note | Output; this change does not reassign their receipt ownership. |
| Diff rows, including the expanded scrolling body | Input (`TranscriptCardLines` in a diff card). |
| Full Before/After fallback | Input (`TranscriptCardSource`); regression checks both actual source text views. |
| Diff status banner and counters | Presentation chrome, not requested diff input; the classification fixture rejects treating the whole card as input. |
| Sub-agent task / result | Existing `TranscriptAgentMarkdown.isToolInput` marks the task and keeps result/error output separate. |
| Inner read/diff expansion | `TranscriptDisclosure.toolLines(ToolOccurrence.key(reply, call))` is authoritative. Timeline, small legacy activity and virtual legacy work lists all pass its value into the card and send an explicit Boolean back. `.toolLines` republishes sibling rows without a new fold animation. |

Nearby pattern sweep: updated both legacy activity paths (ordinary and virtual work lists) to pass explicit expansion values, as well as timeline cards. Find-driven expansion uses those same callbacks. Before/After source views are covered alongside ordinary and capped diff lines. No blind `.toolLines` toggle remains in a card callback.

### Positive controls and mutation evidence

The first positive-control build (`round11-fixed.log`) caught an omitted `setOpen` parameter in the inner legacy work adapter; no tests ran. After wiring that adapter, `round11-fixed-native.log` passed **7 / 0 / 0**: the five new regressions plus `testExpandedReadAndDiffSurviveHostEviction` and `testMoreLinesKeepsItsExistingResizeBehavior`.

Each mutation compiled, ran its target tests and failed with exit 65. The script restored the fixed source after each run, including on failure.

| Log | Mutation | Passed / failed / skipped |
| --- | --- | --- |
| `round11-mutation-diff-input.log` | Remove diff-line input classification | 0 / 3 / 0 |
| `round11-mutation-diff-source.log` | Remove Before/After input classification | 0 / 1 / 0 |
| `round11-mutation-diff-chrome.log` | Treat every diff descendant, including status text, as input | 0 / 1 / 0 |
| `round11-mutation-siblings.log` | Remove `.toolLines` from spanning disclosure changes | 0 / 2 / 0 |
| `round11-mutation-explicit-expansion.log` | Blindly toggle the store instead of setting the displayed value | 0 / 2 / 0 |

`TranscriptBugGalleryTests` passed **6 / 0 / 0**, regenerating 21 images in `build-a130-transcript/validation/round11-gallery`. Inspected `repeated-read-{light,dark,narrow}.png`, `repeated-edit-{light,dark,narrow}.png` and `expanded-read-{light,dark,narrow}.png`. The second A card is expanded, B remains capped, controls remain inside the 360-point rows, the expanded diff keeps its scrolling body, and the remounted read is immediately followed by the next reply without a stale-height gap. The gallery run held the shared lock.

Adversarial self-review of the diff from `bca9e239` checked both ownership filters in `resolveFocus`, the native text-unit types for ordinary/scrolled/Before/After diffs, all expansion emitters and callback adapters, occurrence scoping, idempotent stale actions, sibling invalidation, retained row/work-list measurements, and the non-animated resize path. The display classification check deliberately rejects treating banners as requested input. The mounted navigation checks require a visible focused range inside both the transcript and any inner card scroll. No additional production change or owner decision was needed.

The full regression class passed **110 / 0 / 0**. Its seven `vnode unlinked while in use` SQLite warnings came from the previously recorded generated wide-search fixture cleanup: the same older cases emitted eight warnings in `round10-regression-final.log`. No new case emitted that warning, and none caused a test failure. The separately recorded helper `ResponseTimeline.canonical` slowdown remains unchanged and outside this workstream.

### Final focused validation

Native focused runs: **952 passed / 0 failed / 7 skipped** across 84 classes. Gallery: **6 passed / 0 failed / 0 skipped**. All final runs used the fixed source.

| Text log | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| `round11-regression-final.log` | 110 | 0 | 0 |
| `round11-affected-final.log` | 672 | 0 | 7 |
| `round11-timeline-final.log` | 30 | 0 | 0 |
| `round11-agent-markdown-final.log` | 19 | 0 | 0 |
| `round11-agent-reader-final.log` | 55 | 0 | 0 |
| `round11-wire-page-final.log` | 4 | 0 | 0 |
| `round11-history-edge-timing-final.log` | 2 | 0 | 0 |
| `round11-history-edit-final.log` | 3 | 0 | 0 |
| `round11-agent-navigation-final.log` | 7 | 0 | 0 |
| `round11-inherited-agent-reader-final.log` | 7 | 0 | 0 |
| `round11-agent-inputs-final.log` | 33 | 0 | 0 |
| `round11-plain-copy-final.log` | 3 | 0 | 0 |
| `round11-view-update-final.log` | 7 | 0 | 0 |
| `round11-gallery-final.log` | 6 | 0 | 0 |

The seven skips are existing opt-in journal benchmarks (`PI_PERF_HISTORY_JOURNAL`, `PI_PERF_OPEN_JOURNAL`), skill-pill and Markdown captures (`PI_APP_UI_SCREENSHOT_ROOT`, `PI_MARKDOWN_SNAPSHOT_DIR`), two on-request Markdown measurements and `PI_PERF_WIRE`. The changed gallery class ran with its environment variable set and had no skips.

All commands below ran from this worktree, with `PI_BUILD_ROOT` set as shown. `run-round11-case.py` acquired the shared full-lane lock before each native run and released only its own lock in `finally`; serial classes ran alone. Evidence is text logs and their parsed JSON counts in the build root's `validation` folder. No named result bundle was requested.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript

# round11-failing-first.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFailedEditInputsRemainFocusableWithCapturedReply \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFailedWriteInputsRemainFocusableWithCapturedReply \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFailedMultiEditInputsRemainFocusableWithCapturedReply \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testRepeatedReadCardsShareExpansion \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testRepeatedDiffCardsShareExpansion

# round11-fixed-native.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFailedEditInputsRemainFocusableWithCapturedReply \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFailedWriteInputsRemainFocusableWithCapturedReply \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFailedMultiEditInputsRemainFocusableWithCapturedReply \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testRepeatedReadCardsShareExpansion \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testRepeatedDiffCardsShareExpansion \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testExpandedReadAndDiffSurviveHostEviction \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testMoreLinesKeepsItsExistingResizeBehavior

# round11-mutation-diff-input.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFailedEditInputsRemainFocusableWithCapturedReply \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFailedWriteInputsRemainFocusableWithCapturedReply \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFailedMultiEditInputsRemainFocusableWithCapturedReply

# round11-mutation-diff-source.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFailedEditInputsRemainFocusableWithCapturedReply

# round11-mutation-diff-chrome.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testFailedEditInputsRemainFocusableWithCapturedReply

# round11-mutation-siblings.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testRepeatedReadCardsShareExpansion \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testRepeatedDiffCardsShareExpansion

# round11-mutation-explicit-expansion.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testRepeatedReadCardsShareExpansion \
  -only-testing:PiAppTests/TranscriptBugRegressionTests/testRepeatedDiffCardsShareExpansion

# round11-regression-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests

# round11-affected-final.log
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
  -only-testing:PiAppTests/HistoryEdgeTests \
  -only-testing:PiAppTests/NativeWorkListViewportTests \
  -only-testing:PiAppTests/TranscriptTurnFoldTests \
  -only-testing:PiAppTests/TranscriptFrameBudgetTests \
  -only-testing:PiAppTests/TranscriptGeometryCacheTests \
  -only-testing:PiAppTests/TranscriptKeptRowsTests

# round11-timeline-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptNativeTimelineBehaviourTests

# round11-agent-markdown-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentMarkdownTests

# round11-agent-reader-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentReaderTests

# round11-wire-page-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptWirePageTests

# round11-history-edge-timing-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/HistoryEdgeTimingTests

# round11-history-edit-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/HistoryEditTests

# round11-agent-navigation-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentNavigationTests

# round11-inherited-agent-reader-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/InheritedSubagentReaderTests

# round11-agent-inputs-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentEffortTests \
  -only-testing:PiAppTests/SubagentCostTests \
  -only-testing:PiAppTests/SubagentDisplayTests \
  -only-testing:PiAppTests/SubagentMetadataTests

# round11-plain-copy-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/PlainTextCopyTests

# round11-view-update-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ViewUpdateSideEffectTests

# round11-gallery-final.log
TEST_RUNNER_PI_TRANSCRIPT_BUG_GALLERY="$PI_BUILD_ROOT/validation/round11-gallery" \
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugGalleryTests
```

No helper or wire implementation changed, so the full helper and Python wire/concurrent/acceptance suites were not required. No files were added or removed. Only generated fixtures, isolated test-host windows and the in-memory vault were used; no installed app, real preferences/chats, Keychain, live capture or paid provider was used. There is no new owner decision or unresolved assigned finding.

Final `git diff --check` passed after removing a generated trailing blank line. No clone directories remain under this workstream’s build root; its native runs released their locks. Approximately 13 GiB remained free after validation.

## Round 12 — selection-copy Find projection (2026-10-20)

Review finding **confirmed**. The previous `MarkdownTextBuilder.string` joined raw
paragraph strings, retaining `\t1.\talpha`; selection copy emits `1. alpha`.
The same split also affected block separators, table-cell separators and large-table
preview chrome. The existing rendered-string corpus did not enforce copy semantics.

The shared `MarkdownCopyText` projection now owns selection-copy normalization and
UTF-16 mapping back to the native string. Search assembles the builder's paragraphs
with the same attributes, without a text view or layout manager, then uses that projection. Highlight
matching searches its normalized string and maps each result back to rendered
coordinates. Literal source whitespace remains literal, including raw views and
code. The match cache also tracks copy-mark changes while retaining matches through
syntax-colour-only edits. No Find navigation/focus ownership logic changed.

### Normalization/input sweep

| Builder input / rendered construct | Copy and Find rule | Highlight mapping |
| --- | --- | --- |
| `.piListMarker`: leading/trailing layout tabs, ordered number or bullet, nested indentation | Copy's marker value (`1. `, `- `, indented nested marker) | Marker body remains individually addressable; indentation/trailing space map to layout tabs |
| `.piBlockBreak`: paragraphs/headings/quotes/list items | Copy's declared break (two newlines between blocks, one between items) | One or more projected break characters map to the original line break |
| Table cells, including empty and aligned cells | Copy's tab between cells and newline between rows | Copied tabs map to rendered cell-ending newlines |
| `.piChrome`: large-table preview notice and its break | Omitted from selection copy and Find | No match range is produced for omitted chrome |
| Inline formatting, links, images, hidden HTML | Native builder's text; image note is literal text; hidden HTML has no rendered payload | UTF-16 identity outside marked layout substitutions |
| Code, raw source, literal alignment spaces/tabs, emoji joiners and literal U+FFFC | Preserved verbatim; no blanket whitespace or Unicode removal | UTF-16 identity, including surrogate pairs and combining text |
| Other renderer inputs | Existing planner, delivery metadata, fetched documents and per-segment display-state paths retained | Tool/receipt scope and reader navigation unchanged |

The builder creates no attachment placeholders or zero-width joiners. It replaces
images with a visible note and carries table alignment in paragraph styles, not
padding spaces. `.piCellBreak` is declared but not emitted; actual table separators
use `.piBlockBreak`, shared with copy. The corpus now compares selection-copy text
for ordinary, timeline, recovery, user/status/agent and tool-card rows, rather than
raw TextKit strings.

### Failing first

`round12-failing-first-clean.log`: **0 passed, 5 failed, 0 skipped**, exit 65,
with unchanged production code. Representative assertions:

- `testFindProjectionEqualsNativeReplyTextAcrossMarkdownCorpus`: `("\t1.\talpha\n\t2.\tbeta") is not equal to ("1. alpha\n2. beta")`.
- `testCopiedMarkdownFindsAndFocusesSavedReplies` and `...LiveReplies`:
  `XCTAssertEqual failed: ("[]") is not equal to ("[\"reply\"]")`, source `1. alpha`.
- `testCopiedMarkdownRangesMapBackToRenderedText`: `("0") is not equal to ("1")`, copied list, heading, table and nested constructs.
- `testCopiedMarkdownMatchCacheTracksLayoutAttributes`: no match after installing marker/block-break metadata on unchanged characters.

The initial harness attempt did not compile because a main-actor method reference
was passed directly to `map`; explicit closures corrected it. A preliminary runtime
run then exposed test-only temporary-window release and over-limit query issues.
The final failing-first run sets non-releasing windows and copies at most 120 UTF-16
units for navigation, inside Find's existing 256-character query limit. All five
failures above are ordinary XCTest assertions, with no crash or build failure.

The first positive control (`round12-positive-control.log`) passed **8/8**.
Self-review expanded the corpus to **22 constructs**, including adjacent empty
cells, empty fences and multi-paragraph list items. Find now uses the full native
paragraph assembler, retaining its attribute boundaries as well as its copy marks;
it creates no view or layout manager. The expanded control
(`round12-expanded-positive.log`) passed **6/6**, including an independent golden
copy assertion and exact literal-whitespace checks. The ordinary projection test
covers saved, live, streaming and raw states; the pane tests type copied selections
for all 22 constructs in both disclosure settings, saved and live (**88 queries**).

The initially queued mutation job was cancelled while it was still waiting for
another workstream's lock, before building or taking that lock, to run the expanded
positive control first. Its `finally` restored production. The mutation sequence
was then restarted against the positively validated implementation.

### Nearby run-boundary case — confirmed and fixed

Self-review found that `copyText`'s `piece == "\n"` check depended on unrelated
attribute boundaries: two adjacent marked breaks could be enumerated together,
then separately after a colour change. That could change copied text while leaving
Find's copy-metadata cache valid. The shared function now applies the declared
separator to **each** marked newline, independent of colour/font runs.

`testCopiedBreaksDoNotDependOnColourRunBoundaries` failed before this change:
`round12-break-runs-failing-runtime.log`, **0 passed, 1 failed**, exit 65. It
copied `alpha\n\nbeta` instead of `alpha\n\n\n\nbeta`, and the cached ranges
were `[]` instead of `[{0, 11}]`. The initial fixture draft omitted the required
text-container initializer; the corrected fixture uses `NativeMarkdownContainer`
and produced ordinary assertion failures, not a compilation failure or crash.

The final corpus has **24 constructs**, adding hard/soft breaks, autolinks,
escaped Markdown and entities. End-to-end pane coverage includes saved,
streaming-unsaved and completed-unsaved replies, each under both disclosure
settings (**144 copied-selection queries**). The direct rendered/copy projection
matrix covers the same constructs; raw mode remains unavailable for an arriving
segment as before.

The complete positive control (`round12-complete-positive.log`) passed **7/7**, including all 144 pane queries and the run-boundary regression.

### Mutation checks

Every accepted mutation compiled, exited 65 with ordinary assertion failures, and was
restored in `finally` before the next run. Logs are under this workstream's
`build-a130-transcript/validation` directory.

| Log suffix (`round12-mutation-…`) | Deliberate break | Failed test methods |
| --- | --- | --- |
| `projection` | Return the assembled raw string instead of selection-copy text | `testFindProjectionEqualsNativeReplyTextAcrossMarkdownCorpus` (1) |
| `highlight-normalization` | Match against raw TextKit text | `testCopiedMarkdownRangesMapBackToRenderedText` (1) |
| `range-mapping` | Return projected offsets directly as rendered offsets | `testCopiedMarkdownRangesMapBackToRenderedText`, `testCopiedMarkdownMatchCacheTracksLayoutAttributes` (2) |
| `copy-metadata` | Invalidate only character edits, ignoring copy-mark changes | `testCopiedMarkdownMatchCacheTracksLayoutAttributes` (1) |
| `shared-copy-rule` | Remove block/table-break normalization from the shared function | `testCopyNormalizationKeepsLiteralWhitespaceAndSelectionSemantics` (1) |
| `break-runs` | Restore the single-newline-run check | `testCopiedBreaksDoNotDependOnColourRunBoundaries` (1) |

**6/6 mutations detected, 7 expected failed test cases, no crashes or compiler failures in the accepted mutation runs.** The golden assertion makes a shared copy/Find mistake fail
independently of the projection-vs-copy comparison. The initial revised
`shared-copy-rule` mutation left its binding unused and was rejected at compilation
(`round12-mutation-shared-copy-rule-compile-attempt.log`, zero executed tests).
The driver restored production and released its lock; that attempt is **not**
counted as mutation evidence. A corrected, binding-preserving mutation compiled
and failed its golden-copy assertion. All six accepted results use the final
production implementation.

### Adversarial self-review

Reviewed the complete new production diff and its existing Find/copy callers:

- Kept exact matching for unmarked text; no blanket tab/space/Unicode replacement
  and no relaxed-whitespace fallback was introduced. Raw views and literal tool
  payloads retain their previous representation.
- Checked marker substrings, nested indentation, table cells, omitted preview
  chrome, empty cells/fences, surrogate pairs and combining characters. Mapped
  intervals use UTF-16, with binary lookup in merged spans rather than rescanning
  the document for each occurrence.
- Checked copy of disjoint selections and partial markers against independent
  expected strings. Source/heading/code-button Copy paths are unchanged.
- Checked cache lifetime and invalidation: one normalized projection per resident
  text storage, at most two query-range entries, invalidation on character or
  copy-mark changes, and no range invalidation on syntax-colour changes.
- The assembler now also runs for the search's privately owned builder/paragraphs;
  no view or layout manager crosses actors. Its paragraph styles/table blocks are
  locally built. The font cache retains its existing lock.
- Rechecked ordinary and per-segment source disclosure, agent/fetched-tool inputs,
  planner recovery rows, receipt ownership, continuation budgets and reader focus
  adoption. This round changes no history dependency or navigation state code.
- The shared-layout/copy changes stay within this finding and nearby instances;
  no helper, permission, capture, vault or persisted-data path changed.

### Final validation

Every native run used the shared full-lane lock, releasing only its own lock even
on failure. Serial-lane classes ran separately; no LifecycleHelper class was mixed
in. Text logs and JSON counts live under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript/validation`.

| Log | Classes | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: | ---: |
| `round12-regression-final.log` | 1 | 116 | 0 | 0 |
| `round12-affected-final.log` | 69 | 672 | 0 | 7 |
| `round12-timeline-final.log` | 1 | 30 | 0 | 0 |
| `round12-agent-markdown-final.log` | 1 | 19 | 0 | 0 |
| `round12-agent-reader-final.log` | 1 | 55 | 0 | 0 |
| `round12-wire-page-final.log` | 1 | 4 | 0 | 0 |
| `round12-history-edge-timing-final.log` | 1 | 2 | 0 | 0 |
| `round12-history-edit-final.log` | 1 | 3 | 0 | 0 |
| `round12-agent-navigation-final.log` | 1 | 7 | 0 | 0 |
| `round12-inherited-agent-reader-final.log` | 1 | 7 | 0 | 0 |
| `round12-agent-inputs-final.log` | 4 | 33 | 0 | 0 |
| `round12-plain-copy-final.log` | 1 | 3 | 0 | 0 |
| `round12-view-update-final.log` | 1 | 7 | 0 | 0 |
| `round12-copy-callers-final.log` | 9 | 82 | 0 | 3 |
| `round12-stable-reading-final.log` | 1 | 6 | 0 | 0 |
| `round12-native-turn-final.log` | 1 | 11 | 0 | 0 |
| `round12-transcript-performance-final.log` | 1 | 7 | 0 | 2 |
| `round12-window-presentation-final.log` | 1 | 9 | 0 | 0 |
| `round12-gallery-final.log` | 1 | 7 | 0 | 0 |

Native total: **1073 passed, 0 failed, 12 skipped**.
Gallery total: **7 passed, 0 failed, 0 skipped**.
**1080 passed across 98 classes**, excluding the earlier
positive controls and expected mutation failures from this unique total.

Exact final commands (the build-root export applies to every command):

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-transcript

# round12-regression-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugRegressionTests

# round12-affected-final.log
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
  -only-testing:PiAppTests/HistoryEdgeTests \
  -only-testing:PiAppTests/NativeWorkListViewportTests \
  -only-testing:PiAppTests/TranscriptTurnFoldTests \
  -only-testing:PiAppTests/TranscriptFrameBudgetTests \
  -only-testing:PiAppTests/TranscriptGeometryCacheTests \
  -only-testing:PiAppTests/TranscriptKeptRowsTests

# round12-timeline-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptNativeTimelineBehaviourTests

# round12-agent-markdown-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentMarkdownTests

# round12-agent-reader-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentReaderTests

# round12-wire-page-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptWirePageTests

# round12-history-edge-timing-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/HistoryEdgeTimingTests

# round12-history-edit-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/HistoryEditTests

# round12-agent-navigation-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentNavigationTests

# round12-inherited-agent-reader-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/InheritedSubagentReaderTests

# round12-agent-inputs-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/SubagentEffortTests \
  -only-testing:PiAppTests/SubagentCostTests \
  -only-testing:PiAppTests/SubagentDisplayTests \
  -only-testing:PiAppTests/SubagentMetadataTests

# round12-plain-copy-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/PlainTextCopyTests

# round12-view-update-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ViewUpdateSideEffectTests

# round12-copy-callers-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/CompactTurnReportTests \
  -only-testing:PiAppTests/InspectorExpandInPlaceTests \
  -only-testing:PiAppTests/NestedFenceIdentityTests \
  -only-testing:PiAppTests/StreamingMarkdownStabilityTests \
  -only-testing:PiAppTests/TerminalMarkdownMatchingTests \
  -only-testing:PiAppTests/TranscriptNativeRowParityTests \
  -only-testing:PiAppTests/TranscriptQuoteSelectionTests \
  -only-testing:PiAppTests/TurnDurationClockTests \
  -only-testing:PiAppTests/TurnInfoTests

# round12-stable-reading-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/StableReadingTests

# round12-native-turn-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptNativeTurnBehaviourTests

# round12-transcript-performance-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptPerformanceRegressionTests

# round12-window-presentation-final.log
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/WindowPresentationTests

# round12-gallery-final.log
TEST_RUNNER_PI_TRANSCRIPT_BUG_GALLERY="$PI_BUILD_ROOT/validation/round12-gallery" \
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/TranscriptBugGalleryTests
```

Regenerated and inspected all **24 PNGs** under
`build-a130-transcript/validation/round12-gallery`: `copied-list`, `transcript`,
`recovery`, `rows`, `expanded-read`, `reordered-table`, `repeated-read` and
`repeated-edit`, each in light, dark and narrow variants. The new copied-list
scene highlights the whole `1. alpha beta` phrase, including its marker and
bold text; literal code tabs/spaces and table/nested-list alignment remain intact.
The 360-point transcript still keeps heading Copy inside the row. Recovery and
user-row focus, reordered B1 details, remounted expansion and repeated-card
expansion also remain correct.

The **12 skips** are explicit existing opt-in/manual checks: long-journal
measurements (`HistoryIndexFilesTests.testTheIndexOfALongChat`,
`HistoryReaderOpenPerformanceTests.testIndexingAKeptJournal`); skill-pill and
Markdown snapshots; Markdown line-pitch/token-cost measurements; the 70-turn
wire timing probe; the compact-report gallery; two row glyph calibration sweeps;
and two interactive-pointer cases in `TranscriptPerformanceRegressionTests`.
No new regression or requested gallery case skipped.

The logs retain **95 SQLite fixture-cleanup warnings** (`vnode unlinked while in
use`), all referring to generated temporary history/app-state databases. This is
the already-recorded test-cleanup warning pattern; the affected test methods all
passed. Counts and locations are retained explicitly rather than suppressed:

| Log | Warnings | Example lines |
| --- | ---: | --- |
| `round12-regression-final.log` | 8 | 767, 1073, 1102, 1134, 1148, 1177, 1206, 1219 |
| `round12-affected-final.log` | 62 | 958–1019 (skill-pill fixtures), 1161–1234, 1497–1500, 1627–1629, 2392–2440 |
| `round12-agent-reader-final.log` | 3 | 724, 726, 727 |
| `round12-agent-navigation-final.log` | 6 | 633–636, 651–655 |
| `round12-view-update-final.log` | 16 | 634–683 |

`round12-final-summary.json` records every warning with its log, line, current
test and full message, plus all skip names. The earlier out-of-scope helper
canonical-timeline slowdown at
`packages/swift-host/Sources/PiAgentCore/ResponseTimeline.swift:125` remains
recorded above; this round changes no helper or wire behavior, so the full
helper/Python wire/concurrent/acceptance suites were not required.

No repository files were added or removed. Only generated fixtures, isolated
native test-host windows and the in-memory vault were used. No installed app,
real preferences/chats, Keychain, live capture or paid provider was used. There
is no unresolved assigned finding or new owner decision. Final `git diff --check`
passed. No clone directories remain under this workstream's build root; all its
native runs released their own locks. Approximately **12 GiB** remained free
after validation.
