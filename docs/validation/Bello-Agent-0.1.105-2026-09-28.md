# Bello Agent 0.1.105 — a webhook when a chat finishes

Status: publicly released and verified at 2026-09-28 09:40:58 UTC.
Starting main: `9b3e2978484c01587519ab26016a2b40edc80fb4` (0.1.104's verified record).

## Changes

1. **A webhook when a chat finishes** (`0e912ce`), at the owner's request:
   "when a chat finishes (AI stop and pending for me), it can send a webhook
   to configured address, and it support parameters, so the mini model can set
   the title. Also, I can disable the webhook for a given chat … And I can
   preview for a given chat … And the prompt to mini model should be title + my
   last request + ai output + custom prompt as the context, and it produced
   structured input."
   - Settings → Webhook: on/off, address, POST/GET, headers JSON, body, the
     mini model's parameters (JSON of name → what to write; `title` and
     `summary` by default) and the user's own instructions. Saved in the
     Keychain vault; a webhook that is on must have an http(s) address and valid
     JSON before Settings saves.
   - It fires when a message's run completed or failed and nothing else of the
     chat is queued, read from the helper's command receipts. A run the user
     stops, tool rounds, a follow-up that starts at once, manual compaction,
     utility requests, connection tests, imported, archived and unsaved side
     chats send nothing, and reopening a chat sends nothing for runs that ended
     before.
   - The chat connection's mini model gets the chat's title, the outcome, the
     last request and the assistant's output (each a JSON string, start and end
     kept past 12,000 characters) and the user's instructions, and returns a JSON
     object with exactly the configured keys. The helper runs it as a utility
     task like a title: no tools, no project instructions, its own short system
     prompt, purpose `webhook` in the request log, in a throwaway session removed
     afterwards. A missing parameter falls back to the chat's title (`title`) or
     empty, and the webhook is still sent.
   - Placeholders are escaped for where they land: percent-encoded in the
     address, one line in a header, JSON-escaped in a JSON body. One ephemeral
     request, 20 s, no retry; a failure shows in the chat's footer and the
     window banner.
   - Each chat's ⋯ menu has a checked "Send Webhook When Done" (saved with the
     chat) and "Preview Webhook…", which builds the exact request from the chat
     as it is, shows what the mini model was asked and wrote, and can send it.
2. **A message sent while the queue is paused joins it** (`4338e1b`), the
   owner's choice (2a): after Stop or a failure, Return adds the message after
   the paused ones and Resume sends them in order. A chat at its cost limit
   still refuses a new message. With no run going, the input box no longer
   offers ⌘↩ Steer.
3. **The sidebar's rate slot is empty when no rate was measured**
   (`d1ae24a`), owner: "fix it". Chat rows no longer say "Usage unavailable" or
   "Awaiting usage"; they show "Latest 234 tok/s" only when a rate was measured.
4. **Settings from the app menu keeps its header the height of its title**
   (`c10904c`), owner: "setting page opened from top left MacOS menu looks very
   ugly, fix it". The window's drag area took 362 points of spare height beside
   the title; it now lies behind the header.

## Validation

- **Full gate** (`scripts/verify-release.sh`) on `0e912ce`: serial lane 211
  executed, 7 skipped, 0 failures; parallel lane 1,431 passed, 16 skipped,
  1 failed; helper 459; wire 32; concurrent 4; acceptance 2; Python 66;
  9 min 15 s. Two failures, both followed up:
  - The gallery stopped at 05b's second pass: SwiftUI keeps a closed Settings
    window and shows the same one again, and the scene looked for a new window.
    The harness now takes the window that became visible (`9c505df`, test only);
    the full gallery then passed, **122 screenshots, 0 failures** (114 before,
    plus 05b in both appearances and the six webhook scenes).
  - `ConversationPaneRetentionTests.testSelectingChatsWithOnlyThePaneOnScreenReleasesThem`
    failed in the parallel lane and passed 2 of 3 alone: the pre-existing flake
    recorded since 0.1.102 (a hold in SwiftUI/AppKit view teardown), which this
    release does not touch.
- **WebhookTests** (9 tests): settings from an older vault, parameter order,
  validation, placeholder escaping for address/headers/JSON and text bodies,
  the mini model's prompt and clipping, reading replies (bare, fenced, typed,
  none), the mini model's route sizing, the exchange read from a chat's rows,
  the moment a chat finishes (follow-ups, failures, stops, compaction, receipts
  before idle, a new helper epoch), and end to end: a chat's run on the
  synthetic gateway sends the webhook to a local address with the mini model's
  parameters in the body and headers; the mini model's request has no tools, the
  webhook's system prompt and the chat's title, request, output and
  instructions; the throwaway session is removed; the preview builds the same
  body; a chat with its webhook off sends nothing.
- **Helper:** `TitleTaskTests` opens a `webhook` utility session: mini model,
  no tools or project instructions, its own system prompt, purpose `webhook`.
- **Gallery:** 19 (Settings at the webhook group), 19a (its end) and 19b (the
  preview with the mini model's parameters), light and dark.
- **Live compaction test, fixture mode, on the release helper:** 3 of 3
  scenarios passed (mid-run recalled 10 of 10 markers); reported cost $0.83 of
  the fixture's $5.00 cap (synthetic).
- Installation and updater rehearsals are excluded by the owner's standing
  instruction.

## Publication

- Release source: `572bc3b85520f6577517fd4dfd3b13987c83389c`, pushed to GitHub `main`; annotated tag
  `v0.1.105` is pushed and resolves to that commit.
- Website publication: `7933bb16d75a506a832fb07417db156404b3fa47`, pushed to `BelloWare/belloware.com` `main`.
- Signed/notarized Bello Agent 0.1.105, build 109. App notarization
  `967e215d-c6a3-4b6f-ae32-df945d9cd7d0` and DMG notarization `b7397e0f-63de-4dd0-baaa-13133fbd3ad8` were accepted. Stapling,
  signature, Gatekeeper and artifact validation passed.
- `BelloAgent-0.1.105.dmg`: **10,937,390 bytes (10.43 MiB)**; SHA-256
  `e691255ea799cab98b8e7d60a0928a9f11448baa752b2a7670fde9f92c4bab9b`.
- At 2026-09-28 09:40:58 UTC, the public product page linked to 0.1.105.
  `scripts/verify-published.py` downloaded the public archive, verified its
  SHA-256 and Ed25519 signature, and confirmed that both public update feeds
  match the intended release and are byte-identical.
- No install or updater rehearsal was performed, at the owner's standing
  instruction.
