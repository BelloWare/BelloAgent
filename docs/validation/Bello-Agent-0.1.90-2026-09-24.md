# Bello Agent 0.1.90 validation

Date: 2026-09-24. Version 0.1.90, build 94, arm64 macOS 14+.

## Changes

- **No freeze when compacting.**
  - The owner's hang report showed the main thread held inside one SwiftUI update.
  - Its likely cause was live pop-up menus (SwiftUI `Menu`) in the sidebar and chat header. They were re-synced and resized on every update, which scheduled another layout pass, through compaction's burst of updates.
  - Menus are now plain values built into an `NSMenu` when pressed (`PiMenu`), and the sidebar spinner runs on Core Animation.
  - Four state changes made inside a SwiftUI update now happen after it.
  - A terminal whose exit event came before its child could be reaped now reports the exit.
  - Guards: `LazyListAppKitControlTests`, `ViewUpdateSideEffectTests`, and `CompactionResponsivenessTests`, which compacts in the real window with a main-thread watchdog.
- **A cost limit per chat.**
  - The Settings default is $25; it can be changed or turned off, and any chat can have its own limit.
  - The helper checks reported spend before every request, including retries, recovery and summary requests, and stops at the limit with `cost_limit`. Queued messages stay paused.
  - Spend persists in the journal (`pi-app.cost.v1`). Chats from before this change take the app's recorded spend once.
  - The app shows a stop notice with "Raise limit…" and a "$spent of $limit" figure. A stop reads "Stopped · cost limit": a failed task's error code travels in its terminal record.
  - A context recovery stopped at the limit now reports `cost_limit` instead of the gateway's overflow.
- **Session Inspector.**
  - One window per chat: an overview with its charts and the cost limit, the turns and their requests, and for each request Conversation (with what is new since the previous request), Response and Raw.
  - It replaces the Turn Info popover, the message details and request inspector sheets, the chart popovers, the footer panel, the sidebar rate popover, the context sheet and Session info.
  - The chat's receipts and turn cards stay and open it.
  - Bodies are parsed off the main thread, only while their tab shows. A 30 MB body's longest main-thread step is 14.6 ms in Release.
- **Pi 0.85.1 parity in the helper.**
  - **Summaries:** the cap is `min(0.8 × reserve, model.maxTokens or ∞)` at the session's thinking level, and compaction requests use no cache. Before this, an unknown model ceiling fell back to the chat's 4,096-token budget.
  - **Compaction:** pi's cut point, split turns, tokensBefore and file lists, and pi's summary framing.
  - **Requests:** the system prompt as input[0] (developer or system role); user text and images, with images resized to 2000 px / 4.5 MB as pi resizes them; tool results and orphan calls; assistant replay; tool definitions, reasoning and the cache key, as pi builds them.
  - **Replies:** pi's stream handling. A reply ended early for a reason other than its length limit fails the run with pi's message.
  - **Errors and retries:** pi's overflow and retry classification, with 3 retries at 2/4/8 s.
  - **Turns:** overflow Cases 1–3, and no request limit per turn.
  - **Tool calls:** arguments prepared as pi prepares them; a reply's calls run together (edits keep their order in one chain); the read tool returns image files as images.
  - **Manual compaction:** `/compact` takes a focus ("Additional focus") and stops a running turn first.
  - **Deviations the owner reviewed and kept:**
    - the queue pauses after a failed run;
    - behaviour for context windows under 32k, where pi cannot compact;
    - chained summaries where pi would fail;
    - rejected empty summaries;
    - history_read references in summaries;
    - the gateway's overflow codes, and the LiteLLM request fields;
    - the auto-router replay policy;
    - our own tool set and system prompt.
- **Faster release gate.**
  - `scripts/verify-release.sh` runs the native suite in two lanes, chosen per class by `scripts/test-lanes.py`: a serial lane for classes that need window focus, shared defaults, the pasteboard or live timing assertions, and an eight-clone parallel lane for the rest.
  - The gallery and the helper checks run side by side. Four slow tests were made cheaper and one redundant test was removed.
  - The whole gate took 9 min 50 s, where the 0.1.88 gate took 31.5 min.

## Evidence

- **Release gate** (`scripts/verify-release.sh` on the release candidate, before the version bump):
  - Serial lane: 139 tests, 7 skipped, 0 failures, in 160.7 s.
  - Parallel lane: 1,405 passed, 13 skipped, 0 failures.
  - Gallery: 94 screenshots in light and dark.
  - Helper `swift test` 409/409, wire 29, concurrent 3, acceptance 2, Python script tests 55.
- **Failing first:**
  - Each change was covered by tests that failed against the code before it.
  - The new `ParallelToolCallTests`, `PiReadImageTests` and `CompactionPiTests` focus and stop-first cases, and `CostLimitTests.testCompactionAndRecoveryRequestsCountAndAreStopped`, all failed before their changes.
  - Tests that encoded one-call-at-a-time batches or old formats were restated.

## Release provenance

- **Source:** tag `v0.1.90`, one release commit on GitHub. The DMG was built from the local candidate `f00868d`, with native tree `3fa63e5002e07e9c871a84fd53b445067b3a079f` and helper tree `65ee719f89121c9d223a2cf9e11eede1b946d98a`. Only release-provenance documentation changed after the candidate build.
- **Website publication:** `6b6fef3897b452150875080030dbf7f89ff8e9b5`.
- **Build and notarization:** the optimized build, helper smoke, Developer ID signing, app and DMG notarization, stapling, Gatekeeper and Sparkle validation passed. Accepted notarizations: app `4ef72963-81a7-46b3-aa52-6a96d1711d4d`; DMG `5aee7a0b-5885-41b8-a2e9-a0938b5d0207`.
- **Public verification** at **2026-09-24 00:09:53 UTC**: the product page advertises 0.1.90, the canonical and legacy feeds are byte-identical, and the downloaded installer passes SHA-256 and Ed25519 verification.
- **DMG:** **10,565,738 bytes (10.08 MiB)**; SHA-256 `702fec6de8d9a806a41fd921c6515829923eef3341867042b6d0fdc2e618a815`.
- **Download:** [Bello Agent 0.1.90](https://belloware.com/assets/BelloAgent-0.1.90.dmg). Fresh-install and updater/relaunch rehearsals remain omitted at the owner's request.
