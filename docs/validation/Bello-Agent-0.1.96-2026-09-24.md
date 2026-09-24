# Bello Agent 0.1.96 validation

Date: 2026-09-24. Version 0.1.96, build 100, arm64 macOS 14+.

## Changes

- **Raw views.**
  - User messages show exactly as typed: no markdown, one selectable text. A TextKit leaf draws them from 2 KiB up.
  - A finished reply switches between rendered and its markdown source ("View raw" / "View rendered": a hover pill, the reply menu and an accessibility action).
  - The rendered surface is parked while the source shows.
  - A fix that came along: a reply's accessibility actions no longer rebuild its surface when it settles in a chat that can fork.
- **Slash list.**
  - The root cause of the flicker: the "inside a code span" check was cached on the draft revision, which every key bumps. So each key hid the list and an async check showed it again, and Return or Tab in that gap skipped the list.
  - The check is now cached on the text before the slash.
  - The list floats above the composer (the composer no longer resizes: 96 → 303 → 183 pt before) and uses Pi popover chrome. Gallery scene 17e.
- **Sending.**
  - Model requests reuse one keep-alive `URLSession` per endpoint and connection identity, instead of one per request. Tested: the second request reports a reused connection.
  - A connect waiting on a stopping helper resumes from its exit instead of polling.
  - A just-sent message is taken off the page only for a paused queue.
  - The composer's queue hints count drawn sending rows.
  - `session.open` accepts a capture mode (unused by the app after the revert below).
- **Side chats reuse the main chat's cache.**
  - A side's requests carry its parent's tool list and prompt-cache key (`prompt_cache_key`, `session_id`, `x-client-request-id`), so its first request extends the parent's last. `x-session-id`, metadata and the attempt log stay the side's own.
  - Write, edit and bash are refused at execution in a side.
  - A hidden user note after the shared history says the side is read-only.
  - The per-message skill selection moved from the system prompt into the message that selects it, so instructions are byte-stable.
  - Documented in `docs/Swift-Feature-Parity.md` (deviations from pi).
- **Session Inspector.**
  - Every "Show all" expands in place (read and laid out off the main thread; over 1M characters it shows in steps, and says so); the separate panel is gone.
  - It follows its chat's current display, and a cancelled read no longer clears a newer read's handle.
  - The narrow header uses icons, and the summary instruction has no inner scrollbar.
- **Flicker.**
  - A revisited chat keeps its rows while its fresh page loads; a first read shows the cover only after 150 ms.
  - A sidebar row keeps one form for a whole run.
  - The live turn bar and the model chip no longer re-create themselves.
  - The Projects sheet crosses its panes in one stack.
  - The run clock ticks from the turn's start.
- **Sprint fixes (18:12–18:55).**
  - Per-token regrouping at 300 rows went from 4.3 to 2.3 ms, and the 80-row streaming frame from 11.0 to 7.7 ms (Debug).
  - Pages that fit are not copied.
  - History rows are measured while a reply streams (the deferral is capped at 0.5 s).
  - The metrics snapshot no longer carries every message ID: 34.7 KB → 3.8 KB at 1,000 IDs.
  - Messages sent during `/compact` are delivered, and Stop cancels a pending `/compact`.
  - The host no longer hops to the session actor per token.
  - Typing no longer republishes the footer per key: 1.975 → 0.025 publishes per key.
  - "Fork from here" works without a display and doesn't pull a reader who moved on.
  - Fixes: the side-close race, the composer hints, the sidebar recency label, and the terminal's bracketed-paste escape.
  - Conversation shortcuts (⌘↩, ⌘., ⌘F) stand down behind sheets and other windows.
- **Reverted before release:** `d6ae446`, which started the helper alongside the credential read. It kept a left chat's display alive (`ConversationPaneRetentionTests`, bisected over the integration merges) and showed no measurable gain.

## Evidence

- **Full gate** (`scripts/verify-release.sh`) on the integration head `2a60bad`:
  - serial lane: 192 tests, 7 skipped, 0 failures;
  - parallel lane: 1,417 passed, 13 skipped, 2 failed:
    - `TranscriptStreamingScrollTests.testStreamingWhileScrollingStaysWithinTheDisplaysFrame`: fixed by its test-only commit `2bbc0fd`, merged after that build;
    - `ConversationPaneRetentionTests.testSelectingChatsWithOnlyThePaneOnScreenReleasesThem`: fixed by the revert;
  - gallery: 112 screenshots;
  - helper: 433 tests;
  - scripts: wire 32, concurrent 3, acceptance 2, Python 65;
  - 10 min 44 s.
- **After the fix and the revert**, the affected classes passed: 79 tests, 0 failures, 1 skipped. They were `ConversationPaneRetentionTests`, `TranscriptStreamingScrollTests`, `SendLatencyTests`, `SendImmediacyTests`, `WorkspaceConcurrencyTests`, `HostSupervisorTests`, `WorkspaceRefreshLifecycleTests`, `WorkspaceFailureTests`, `FreshPresentationTests` and `ComposerSubmissionTests`.
- **Earlier full gate on the sprint merge** (`fb28db3`): 0 failures. That was serial 140, parallel 1,433, gallery 100, helper 426, wire 31, concurrent 3, acceptance 2 and Python 65.
- **Live compaction test, fixture mode, on the release helper:** 3 of 3 scenarios passed; in the mid-run scenario, 10 of 10 markers were recalled.
- The sprint's unfixed findings (about 100) are kept for the next round.

## Release provenance

- **Source:** tag `v0.1.96`. From this release on, history is not squashed: `release/0.1.96` was merged into main with `--no-ff` (45 commits since 0.1.95), followed by one release commit.
  - The DMG was built from a tree-identical local candidate, `9629d10`. The release commit before these docs, `4a594b1`, has native tree `5a16e6523ddbb5bd3123308205019d091750f9ed` and helper tree `03c5e32879ec91bb3b1d4197ae476f7c98fa997f`.
  - Only release-provenance documentation changed after the candidate build.
- **Website publication:** `ea3c6879612225e8e4dd88e2a10472827d242808`.
- **Build and notarization:** the optimized build, helper smoke, Developer ID signing, app and DMG notarization, stapling, Gatekeeper and Sparkle validation passed. Accepted notarizations: app `eddf1fb9-35ac-48c3-9571-3272c4e5f93c`; DMG `a3fd5d41-363f-42f7-8139-b3602df4fabd`.
- **Public verification** at **2026-09-24 12:04:07 UTC**: the product page advertises 0.1.96, the canonical and legacy feeds are byte-identical, and the downloaded installer passes SHA-256 and Ed25519 verification.
- **DMG:** **10,830,210 bytes (10.33 MiB)**; SHA-256 `716cae0c0392941189f37601220183a41e3d6159753dbfb70f29b415e249acf6`.
- **Download:** [Bello Agent 0.1.96](https://belloware.com/assets/BelloAgent-0.1.96.dmg). Fresh-install and updater/relaunch rehearsals remain omitted at the owner's request.
