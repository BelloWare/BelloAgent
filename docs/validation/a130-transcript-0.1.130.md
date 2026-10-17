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

## Commands and results

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

## Gallery and out-of-scope finding

Viewed all three generated images in `validation/gallery-final/`:
`transcript-light.png` and `transcript-dark.png` at 760×800 points, and
`transcript-narrow.png` at 360×800. Each shows the literal marker as unchanged
context, red `old tail`, green `new tail`, a complete “Requested edit” banner,
the Real heading action and the highlighted rendered “alpha beta” phrase.
The first gallery fixture left Work closed; it was corrected to open the work
row and assert a mounted diff card before taking the final images.

**Unresolved, outside the assigned defects:** at 360 points, the heading Copy
control is clipped on its right. `apps/macos/PiApp/Transcript/NativeMarkdownSurface.swift:981`
adds 30 points beyond the available width when positioning that control
(frame assignment at line 982). The formula is identical in the baseline and
this branch; the final narrow capture shows the crop. This separate layout bug
is recorded for the lead under the scope rule and is not changed here.

## Review and limits

All three assigned findings are confirmed and fixed; none were rejected.
Nearby same-pattern fixes are itemized above. No product decision was needed
for these corrections, and permission, capture, tool, vault and data boundaries
are unchanged. No helper or wire implementation changes are included, so their
full suites are not required for this workstream. The lead owns the separate
review, full merged gate and merge. This branch does not merge or release.
