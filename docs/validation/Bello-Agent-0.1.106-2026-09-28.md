# Bello Agent 0.1.106 — a running request counted once

Status: publicly released and verified at 2026-09-28 10:10:50 UTC.
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
- **Live compaction test, fixture mode, on the release helper:** 3 of 3
  scenarios passed (mid-run recalled 10 of 10 markers); reported cost $0.83 of
  the fixture's $5.00 cap (synthetic).
- Installation and updater rehearsals are excluded by the owner's standing
  instruction.

## Publication

- Release source: `41ef3bc62b49d79e17e512e39f73a1483ff1563e`, pushed to GitHub `main`; annotated tag
  `v0.1.106` is pushed and resolves to that commit.
- Website publication: `ea1dfbc6098af1b7560bd71823cc268d4cdbfd37`, pushed to `BelloWare/belloware.com` `main`.
- Signed/notarized Bello Agent 0.1.106, build 110. App notarization
  `db8d85f1-a906-41c1-9f03-a805661c6ece` and DMG notarization `16b11e02-afb2-4e55-9b30-77389a9e8a7c` were accepted. Stapling,
  signature, Gatekeeper and artifact validation passed.
- `BelloAgent-0.1.106.dmg`: **10,938,427 bytes (10.43 MiB)**; SHA-256
  `5ce2e4dd55c274c042d1af2f82e45d72bfccdfaca7ff9c63099b34521dbe205e`.
- At 2026-09-28 10:10:50 UTC, the public product page linked to 0.1.106.
  `scripts/verify-published.py` downloaded the public archive, verified its
  SHA-256 and Ed25519 signature, and confirmed that both public update feeds
  match the intended release and are byte-identical.
- No install or updater rehearsal was performed, at the owner's standing
  instruction.
