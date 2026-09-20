# Bello Agent 0.1.70/build 74 acceptance — 2026-09-21

Release preparation; publication verification will be recorded after deployment.

## Change

Tasks now announce successful completion with the native macOS Tink sound
(0.564 seconds on the validation machine), at 80% application sound volume.
The app follows the system's output device and volume. Settings → Notifications
contains a saved completion-sound toggle, enabled by default, and Preview.
Older vaults decode without migration or replacement; both preference-only and
connection saves preserve the choice, including a concurrent-settings merge.

The bounded command receipts already returned in session snapshots identify
task completion. Neither streamed text nor individual completed HTTP requests
drive the cue. Each open establishes a silent baseline before any submission,
including fast responses; repeated polls and reopened history cannot repeat a
cue. Runtime replacement establishes a fresh baseline. Queued follow-ups can
announce a completed predecessor even while the next task starts. Steering
belongs to its surrounding task. Tool rounds, compaction, title generation,
connection checks, failed/cancelled/removed commands and archived chats stay
quiet. Muted completions are consumed immediately, never played later.

The player is shared across sessions, lazily loads one native sound, and
coalesces completions within one second. It creates no timers, deferred playback
queue, notification permission prompt, transcript reads or new helper requests.
The detector keeps at most the helper's last 128 command states per loaded chat.

## Executed validation

**48 focused native Debug tests passed with actor data-race checks**, zero
failures/skips, 5.335 seconds of test execution:

- Eight completion-sound tests cover history baselines, fast replies, duplicate
  snapshots, runtime replacement, tool rounds, failures/stops/removals,
  successful retry, steering, queued follow-ups, malformed/missing receipts,
  muting, archive/restore, background panes, shutdown and saved preferences.
- A deterministic local gateway validates actual requests from the packaged
  native helper. A three-request/two-file-tool task emits one cue; a fast JSON
  reply emits one more. Both hidden chats are closed/reopened with no new cue.
- Twenty simultaneous playback requests share one cue. The selected native
  sound exists and lasts less than one second. Playback is injected in tests,
  so this does not claim an acoustic measurement of the user's audio hardware.
- Existing Settings save/connection flows, read state and follow-up/compaction
  presentation checks pass unchanged (40 tests).

Evidence: session `tmp/completion-sound/completion-debug.log` and
`completion-debug.xcresult`. The preceding 0.1.69 release's unchanged helper,
capture, concurrency and popup validation remain applicable.

Installation and actual Sparkle-update rehearsals are omitted under the owner's
standing release policy. Signing, notarization, packaged smoke and public
archive/feed verification remain release gates.
