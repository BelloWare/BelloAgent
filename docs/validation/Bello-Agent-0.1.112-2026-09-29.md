# Bello Agent 0.1.112 — a chat's rows drawn once, at their final height

Status: candidate; publication pending.
Starting main: `0d98fa80fbfcbbdebd165aa5da0c764ee57d7d9d` (0.1.111's verified record).

## Changes

The owner reported text shifting when chats load, and asked for consistent
rendering that keeps all current detail. Both causes were measured with a new
window probe that samples every 4 ms (`d82ede1`).

1. **Each reply's cost and usage line is drawn with the reply.** A chat's
   replies were drawn without it: the line was read from the request log once
   the chat was ready, and each reply then grew from 20 to 33 pt, moving every
   visible row 13–26 pt. A chat opened again lost the lines and grew them back.
   `WorkspaceModel.withAccounting` now reads the request log for a page's rows
   before they are shown, waiting at most 150 ms (`accountingBeforeShowing`);
   otherwise it keeps the figures the chat already had. It covers opening a
   chat (`select`), a side (`loadSideDisplay`), a reload (`reloadHistory`), a
   search hit (`revealConversationHit`), a revealed message (`revealMessage`)
   and pages read in while scrolling (`loadHistoryPage`).
2. **Rows read from a journal match the helper's.** Rows read from a journal
   (`TranscriptMessage.project`) differed from the helper's rows for the same
   messages, so every row was drawn again when the helper's snapshot merged: a
   row's state was its stop reason instead of "complete"; tool inputs were
   pretty-printed instead of the helper's compact encoding with `inputBytes`
   and `inputTruncated` false; a tool result's detail lacked " · <outcome>".
   Journal rows now carry what the helper's carry.
   `TranscriptActivity.argumentsText` lays out complete inputs for reading
   whichever encoding arrives, so generic tool cards look the same either way.
   The failure label (`TranscriptRows`) and the unfinished-reply checks for
   titles and webhooks use `failedEnd` and `endedUnfinished`, which read the
   stop reason as well as the state, so what they show or skip is unchanged.

## Validation

- **Full gate** (`scripts/verify-release.sh`) on `5f0ff44`, dev/next's tip:
  serial lane 214 executed, 7 skipped, 0 failures (`ChatLoadStabilityTests`
  among them, 17.3 s); parallel lane 1,457 passed, 17 skipped, 0 failures (the
  three updated tests among them); gallery **128 screenshots, 0 failures**;
  helper 486, 2 skipped (the opt-in timings); wire 32; concurrent 4;
  acceptance 2; Python 66; all passed in 12 min 50 s. The gallery log's 2,948
  "AttributeGraph: cycle detected" lines are not new: 0.1.111's gallery log had
  2,932.
- `5f0ff44` merges main (`0d98fa8`) into dev/next, so the merge into main adds
  nothing else: the merged tree equals the gated tree. It changes app files
  only, and lists the new test in the project; `packages/swift-host`,
  `scripts`, `fixtures` and `docs` are unchanged since 0.1.111.
- **Development evidence** (before the gate): on `d82ede1`, the serial lane ran
  214, 7 skipped, 0 failures; the parallel lane 1,453 passed with 3 failures,
  which were the three tests then updated for the helper-matching rows; the
  gallery 128 screenshots. On `5f0ff44`, `ChatLoadStabilityTests` and the three
  updated tests pass.
- `ChatLoadStabilityTests.testOpeningAChatShowsItsRowsOnceAndDoesNotMoveThem`
  (new, serial lane, about 17 s): with the packaged helper and the synthetic
  gateway, it opens a chat with a tool call, long answers and cost after a
  relaunch, samples the window every 4 ms, and checks that no row changes or
  moves once shown, including when the helper's rows arrive, and that the usage
  lines are there from the first frame. It fails with the usage read turned
  off.
- Updated for the helper-matching rows (the input byte count, state
  "complete", and a truncation flag of false rather than none):
  `HardeningTests.testArchiveProjectionKeepsEveryCardAndEveryCharacterOfAReply`,
  `TranscriptActivityTests.testAReplyStoppedAtTheOutputBudgetCarriesItsReason`
  and
  `TranscriptPageStressTests.testATwentyKilobyteEditReadFromAJournalShowsAPartialDiff`.
- Installation and updater rehearsals are excluded by the owner's standing
  instruction.

## Publication

Pending.
