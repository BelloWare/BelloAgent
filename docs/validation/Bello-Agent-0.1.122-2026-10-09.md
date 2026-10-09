# Bello Agent 0.1.122 — long-chat scrolling, search inside chats, sidebar states

Status: **publicly released and verified** at [belloware.com](https://belloware.com/bello-agent.html), marketing version 0.1.122, build 126. Public verification completed at **2026-10-09 00:59:08 UTC**. Tagged source: **`3d2d854e`**, `v0.1.122`. Website: **`c128c3b`**. Previous public release: 0.1.121/build 125.

## Owner request

On 2026-10-08 the owner asked for: Mark as Unread; paused chats still paused after a restart; the sidebar ordered by last update; search inside threads; and a release. Choices offered and taken: search **both** ways (sidebar search over message text, and ⌘F in the open chat); order **always by last activity** (manual ordering removed, pinned on top). Then, for the same release: smooth scrolling in very long chats, following DeepSeek Harness's approach where it applies, with end-to-end tests and a reliable way to the start of the thread; a tint for recently opened chats (by order of opening, not time); and a marker for chats with an unsent draft.

## Scope

- **Long-chat scrolling** (`dev/scroll`): the reader's place is held through earlier pages landing and rows being let go; pages are read three screens ahead in the direction of travel; Home/⌘↑ read the chat's first page directly, End/⌘↓ go to the latest; cheaper layout passes and long-reply measuring. DeepSeek Harness study: it draws every loaded row, pages earlier history only on "Load earlier" and never evicts; we kept virtualization and took its key-based anchor and direct page reads. Record: `docs/perf/long-chat-scrolling.md`.
- **Search inside chats** (`dev/search`, `dev/scroll`): a trigram FTS5 index beside the desktop database (0600/0700, secure_delete) matches message text; each sidebar hit shows a snippet and opens at the message through `revealInTranscript` (reads the page in, unfolds the turn or card, highlights). ⌘F find bar over the transcript counts matches across the whole chat; ⌘G/⇧⌘G, Return/⇧Return, Escape. Search and Copy Conversation moves to ⌥⌘F. ⇧⌘G is Find Previous only while the focused chat's find bar is open; otherwise it stays Changes and History.
- **Sidebar** (`dev/sidebar`): Mark as Unread (row, side-row and marked-rows menus, File menu; counts in the Dock badge); paused chats still show paused after a restart (`run-hold` records; the journal reader keeps a stop with nothing queued as paused); every group ordered by last activity with pinned on top, rows held still while the pointer is over the list, a row menu is open or a row is dragged; recency tint over the open chat and the four opened before it; a pencil for chats with an unsent draft.
- **Fixes:** typing a commit message measures only the message (the Changes panel's typing budget had been failing intermittently since 0.1.121); the queue header's "Paused · 1" no longer wraps mid-word in a narrow pane.
- **From the final whole-change review:** a tool-output hit opens at its own result (a large earlier result could push it off the page read for the reply); deleting a chat's index rows empties the search index's write-ahead log with a verified TRUNCATE checkpoint (retried while a reader holds a snapshot, and on every opening); the ⇧⌘G collision; a find match near the end of a short chat was never brought into view (the page counted as landing while holding the reader's opening place).

## Validation

Toolchain: macOS 14.8 on Apple Silicon, Xcode 16.1, XcodeGen 2.44.1.

- Full gate (`verify-release.sh`) on `065d288b`: **all passed in 41 min 30 s** — native serial lane 642 (28 skipped), parallel lane 2,013 passed (34 skipped), helper 614 (6 skipped), helper streaming cost 5, gallery 206 screenshots. The earlier gate on `5cec4206` had two parallel failures (a Mark as Unread menu test, and the known `WorkspaceFollowupTests` scratch-chat flake); both pass in this gate.
- Every new test was mutation-checked by reverting its fix; the four final-review fixes and the queue header: 4 of 4 caught.
- Long-chat scrolling, Release, 200-turn fixture: jumps up/down 18/28 → 0/0; frames stalled at an edge 39–60 → 0; Home to the first message 34 presses (28.7 s) → 1 press (0.6 s); gesture-up frame max 172–185 → 106–132 ms. `LongChatScrollTests` budgets (Release): p95 ≤ 50 ms, p99 ≤ 100 ms, max ≤ 150 ms, ≤ 5% of frames over 50 ms. Known: 1–4% of Release frames still take 50–130 ms when a page lands or a very long reply is first measured.
- Gallery reviewed in light and dark: sidebar states together (unread, paused, draft, recency tint), search results and an opened hit.
- Codex (gpt-6.1-sol, xhigh, read-only): every workstream reviewed to no findings; final whole-change double-check from `f4f80ddd` found three issues (tool-output hits, search-log residue, ⇧⌘G), all fixed and re-reviewed to no findings. Its advice: run the full gate and an actual hour soak; check real sidebar-to-transcript navigation with large tool results, deletion during querying, a 0.1.121 upgrade with paused runs and old manual ranks, and find while streaming; keep the occasional long scrolling frames in the risk statement.
- **Hour soak**, Release build of `065d288b`, seed **1790822043708**, no other builds: **passed**. 3,609 s, 182 launches (sidebar median 285 ms, max 450 ms), **0 stalls over 250 ms**, 0 row jumps, 0 slow or missing launches, test passed. Main-thread answers over 100/150/200 ms: 28/2/1; longest **203 ms** (0.1.121: 464/5/1, longest 207 ms). Footprint 96 → 1,057 MB, 5.31 MB per launch (0.1.121: 4.06) with all 182 windows alive, the test runner's documented window retention, and seven recent models (cycles 176–182); the higher per-launch growth is not attributed further.
- Not done: the owner's VoiceOver and real-gateway checks (deferred, as for previous releases); install/update rehearsals skipped under standing policy.

## Publication

Packaged from **`3d2d854e`** (`main` merged with `dev/next` at `065d288b`, plus the version bump, notes and this record) with `scripts/release.sh`: Release build, stripped binaries with retained dSYMs, Developer ID signing, packaged-helper offline smoke, app and DMG notarization and stapling, Gatekeeper validation, signed appcast and Ed25519 verification.

- App notarization: **`4e908729-94cf-4c93-b7b2-995d4a352650`**, Accepted.
- DMG notarization: **`75665a06-4adb-454d-954f-ee8550718905`**, Accepted.
- Installer: **12,795,319 bytes (12.20 MiB)**.
- SHA-256: **`f0e0fd4a2c41b9b02a26035a4ea88a398e7283968d00f48a38a47c4436948ae1`**.
- `validate-release.py --previous-build 125` passed; both local feeds byte-identical.

Source pushed atomically to `main` and `dev/next` at `3d2d854e`; `publish-release.sh 0.1.122` pushed website `c128c3b`; `verify-published.py` passed at 2026-10-09 00:59:08 UTC: identical canonical and legacy feeds, public DMG SHA-256 match and Ed25519 signature.
