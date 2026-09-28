# Bello Agent 0.1.107 — a stopped turn said once, rounded times, Settings in sections

Status: candidate; publication pending.
Starting main: `9588621cfba1762a546baa54f6b3e9ebe3da8fd7` (0.1.106's verified record).

## Changes

The owner approved three proposals ("1. sure 2. sure 3. sure").

1. **A stopped turn says so once.** After Stop the chat said it four times: a
   "● Stopped" chip under the reply, the "Turn · Stopped" card, an amber line
   under it ("Run cancelled. Pending messages are paused; inspect tool effects
   before retrying.") and the paused queue with Resume; the card also said
   "1 failed before it finished" for a request the user stopped.
   - The chip under the reply is removed.
   - The host's advice moves into the card's note, without the "Run
     cancelled." the header already says (`TurnInfoPresentation.cardNote`); a
     failed turn keeps its notice under the card unless the failure card says it.
   - A request the user stopped counts as *stopped*: the request log's
     `cancelled` outcome has its own count (`missing_stopped`, beside the packed
     running/failed/no-usage sums), its reply's record reads `stopped`, the
     Inspector's turn table says "stopped", and a reply cut off in a stopped turn
     with no row in the log counts as stopped too. Accounting kept from before
     reads with none stopped.
2. **A finished turn's times are rounded** (`MetricFormat.turnDuration`):
   "92 ms · AI 88 ms", "19.7s", "1m 05s", "1h 02m 03s", where the card said
   "92.466 ms · AI 87.551 ms" and "19.695s". The live clock counts whole seconds
   as before; the Session Inspector keeps each request's exact time.
3. **Settings in four sections**, listed down its left side: Connections
   (the connection tabs, gateway, keys, models, reasoning, contracts, routing,
   capabilities), Usage & capture (capture, dashboard, spending), Chats &
   notifications (transcript, completion sound, webhook) and App (runtime,
   updates). Each shows only its own groups and opens at its top; Delete,
   Discard and Test Connection show in Connections; one Save saves every
   section. Settings reopens at the section last used. The sheet and the window
   are 880 points wide to hold the list.
4. Settings says the mini model writes the webhook's parameters as well as
   chat titles (`0866d9c`).

## Validation

- **Full gate** (`scripts/verify-release.sh`) on `f8f05e8`: serial lane 213
  executed, 7 skipped, 0 failures; parallel lane 1,437 passed, 16 skipped,
  1 failed; gallery **128 screenshots, 0 failures** (122 before, plus 05c for
  the three other Settings sections in both appearances); helper 459; wire 32;
  concurrent 4; acceptance 2; Python 66; 12 min 6 s. The one failure is the
  pre-existing flake
  `ConversationPaneRetentionTests.testSelectingChatsWithOnlyThePaneOnScreenReleasesThem`
  (a hold in SwiftUI/AppKit view teardown, recorded since 0.1.102; it also failed
  in the 0.1.105 and 0.1.106 gates), which passed 2 of 3 alone and which this
  release does not touch.
- `StoppedTurnPresentationTests` (4): a stopped turn's note keeps the advice
  without "Run cancelled.", counts "1 stopped", and puts nothing under the card;
  a failed turn keeps its notice under the card; a reply cut off in a stopped
  turn counts as stopped; accounting from before reads with none stopped.
- `GatewayAccountingTests.testAStoppedRequestIsCountedAsStoppedNotFailed`: the
  log counts a `cancelled` request as stopped and a `failed` one as failed; the
  reply's record reads `stopped`.
- `ConversationPaneTests.testAStoppedTurnSaysSoOnce`, against the packaged
  helper: Stop during a slow reply leaves a card that says Stopped, counts one
  request, stopped, none failed, and keeps the advice in its note.
- `TurnDurationClockTests`: settled times read `12.3s`, `92 ms`, `19.7s`,
  `12s`, `1s` (from 999.6 ms), `1m 00s` (from 59.96 s), `1m 05s`, `1h 02m 03s`,
  `0s`, `<1 ms` and `—`.
- **Gallery:** 05 and 05b (Connections), 05c (Usage & capture, Chats &
  notifications, App), 18d (Usage & capture), 19/19a (Chats & notifications at
  the webhook), and 15 (a stopped turn with no chip and its advice in the card).
- Installation and updater rehearsals are excluded by the owner's standing
  instruction.

## Publication

Pending.
