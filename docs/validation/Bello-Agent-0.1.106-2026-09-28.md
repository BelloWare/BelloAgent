# Bello Agent 0.1.106 — a running request counted once

Status: candidate; publication pending.
Starting main: `750ad799e051a94c2ac00cd9d5a4456c10db08bb` (0.1.105's verified record).

## Change

The owner asked: "I see 3/5 reported, and one missing because it's ongoing
request, but why there is another one? I see only four requests in the log…."
The request still running was counted twice (`fef2a4a`). The gallery showed it
too: one streaming request read "input and output from 0 of 2 requests; 2 did
not report usage (2 still running)".

- **Cause.** From dispatch on, the helper links a request to its hidden ledger
  row (`requestLedger`) as output, and publishes that link with the footer's
  figures a few times a second. The log's attribution lets a streaming answer
  claim its turn's requests only while no output link exists, so the ledger's
  link sent the running request to the user's row; the answer, owning nothing,
  then added its own stand-in for the same request.
- **Fix.** An answer row claims a request through the ledger that stands for it
  (`presentationSourceID`), streaming or done, and a reply's record reads the
  ledger's link as its own. Nothing changes in the helper or the log's data.

## Validation

- **Full gate** (`scripts/verify-release.sh`) on `0f0be6a`: serial lane 212
  executed, 7 skipped, 0 failures; parallel lane 1,432 passed, 16 skipped,
  1 failed; gallery **122 screenshots, 0 failures**; helper 459; wire 32;
  concurrent 4; acceptance 2; Python 66; 11 min 43 s. The one failure is the
  pre-existing flake
  `ConversationPaneRetentionTests.testSelectingChatsWithOnlyThePaneOnScreenReleasesThem`
  (a hold in SwiftUI/AppKit view teardown, recorded since 0.1.102; it also failed
  in 0.1.105's gate), which this release does not touch.
- **Gallery 13 and 13a** (a reply streaming) now read "input and output from 0
  of 1 requests; 1 did not report usage (1 still running)", where 0.1.105's gate
  showed "0 of 2 … (2 still running)"; the running request's route label sits on
  the streaming answer, not under the user's message.
- `GatewayAccountingTests.testALedgerLinkLeavesTheRequestWithTheAnswerItStandsFor`:
  a running request linked to its ledger belongs to the streaming answer, not
  the user's row, and the turn counts one request, one running; finished, it
  stays with the answer.
- `ConversationPaneTests.testARequestStillStreamingIsCountedOnce`, against the
  packaged helper: while a slow reply streams and the log holds the ledger's
  link, the answer owns its request, the user's row has none, and the turn
  counts one request, one running.
- Both fail without the fix (the archive test counts 2 requests and 2 running,
  exactly the report), and pass with it. The 115 tests of the accounting
  classes (archive, attribution, turn accounting, compact reports, live
  accounting, stats, scale, concurrency) pass.
- Installation and updater rehearsals are excluded by the owner's standing
  instruction.

## Publication

Pending.
