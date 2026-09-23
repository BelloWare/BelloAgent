# Bello Agent 0.1.85 validation

Date: 2026-09-23. Version 0.1.85, build 89, arm64 macOS 14+.

This release comes from an audit of 0.1.84 rather than a feature plan. Read-only finders covered the
transcript, the streaming and scroll paths, the workspace model, the reports and inspectors, the Git panel
and terminal, and the Swift helper. The orchestrator verified each finding. Fixers then worked in separate
worktrees, one owner per file, and each fix has a test that failed before the change. There are 87
commits over 0.1.84: 97 source files (+5,127 −1,366) and 71 test files (+7,406 −146).

## Changes

### Reading and streaming

- **Mouse-wheel scrolls during a reply stay put.** The wheel's movement lands a frame after the event.
  A layout pass in that gap captured a reading anchor at the old position, and the page put the reader
  back. Any movement the scroll ledger attributes to the reader now drops that anchor. A 700 pt scroll
  used to end 8–13 pt from the bottom and follow every token; it now holds 709–711 pt from the end.
  Scroller drags, keys and trackpad momentum behave as before.
- **Folds and cards hold still.**
  - Folding a turn moves every row in the click's own pass; before, rows stood blank for a frame.
  - A card opened at the reader's line opens downward; before, its header moved up by 124 pt.
  - A long streaming reply's row stays as tall as its text (186–534 pt off before).
  - A retargeted fold keeps every row within 1 pt.
  - An earlier page lands with the reader's row in the same pass; before, one frame showed rows 2,099 pt
    away.
  - Back to latest reaches the end, and an idle chat no longer snaps back to its last question.
  - Retry and failure rows show at a full 500-row window.
  - Read receipts and saved positions use the row the reader actually saw.
- **Streamed Markdown matches the finished reply.**
  - A closing fence still arriving is never drawn as a code line.
  - Blank lines after a fence never flash.
  - An open list or table past 8 KB stays formatted.
  - Numbered steps after a code block stay one list.
- **A steered task no longer freezes the chat.** Two turn folds shared one id, so the page rejected every
  later update with "conflicting row identities". Folds are now keyed by the message that opened each
  display turn, which also keeps folds without turn ids open. A plain answer gets no fold, and a turn
  ending in tool work never folds behind its narration.

### Performance

Debug figures unless marked Release; each comes from a test that stays in the suite.

- **Streaming in the app:**
  - Timeline replies take the streaming fast path: 47 rebuilds per 48 tokens → 0. Far from the reader, a
    frame costs 6–12 ms, down from 19–21.
  - A token touches only the blocks it changed: frame on a 1,157-block reply 15.3 → 2.0 ms, flat with a
    127-block reply.
  - Long lists draw in 16-item segments: frame on a 7.6 KB open list 17.3 → 4.6 ms.
  - An open list or table parses only the entry still arriving: 47 → 0.13 ms at 7.8 KB.
  - A 2,000-line open fence: 15.5 → 0.05 ms. Colouring an append: 13.6 → 0.13 ms.
- **Streaming in the helper:**
  - Snapshot CPU per token late in a 184 KB reply: 80 → 0.7 ms.
  - Per-token frame with 70 finished turns: median 53 KB → 1.9 KB, because receipts and task records now
    travel only when they change.
  - Streaming tool arguments arrive as appends: 79 whole-row resends → 0.
  - Opening a 12,000-message chat no longer blocks other chats' snapshots (4.8 s → 0).
  - Replies kept for retry: 1.25 MB → 2.9 KB.
- **Elsewhere in the app:**
  - Whole-conversation republishes per streamed token: 3 → 0.
  - Store reads per snapshot: 2 → 0 while nothing changes.
  - Task presentation decodes once per change, off the main actor: 50 decodes → 1 over 50 snapshots.
  - Fold menu evaluation at 350 rows: 230 → 0.05 ms.
  - A streaming write card: 50 → 0.3 ms per delta.
  - Idle measuring of 750 rows: 729 → about 100 layout passes.
  - Disclosure reads per token with a card open: 603 → 1.
  - A Reports round trip re-measures 0 rows, not 216.
  - Capture writes: 69 → 23 directory fsyncs per 8 packets.
  - An unchanged metadata poll: 40 decodes → 0.
  - Chart hover rebuilds no marks.
  - Seven usage queries drop a dead aggregate: a 1M-row summary takes 2.40 → 1.89 s.
- **Release, alternating runs against 0.1.84 on the same machine:** one drag step over 750 rows averages
  16–20 ms, down from 23–25.

### Tools, runs and the helper

- **A shell command whose background child keeps the output open returns.** It returns 1.5 s after bash
  exits (it used to hang forever). Stop returns within about 0.5 s and frees the workspace edit gate.
- **Tool calls say what happened to them.**
  - A call stopped mid-run reads "Stopped running · outcome unknown", live and after reopening. It used to
    read "Ran" and later "Failed".
  - A skipped call reads "Skipped running", never "Ran".
  - Crash-recovered results are recorded as unknown.
- **Failures and retries:**
  - LiteLLM's bare `{"error":…}` stream frame is reported and retried, and so is a stream cut before its
    terminal event.
  - Stop clears the retry notice.
  - A content-filter ending says so, and "Output limit reached" is reserved for the length limit.
  - A reply's model time excludes back-off sleeps.
- **MCP:** a request the server refused without processing it no longer quarantines the workspace. Dead
  stdio and HTTP connections reconnect, and the tool catalog is cached per connection.
- **Follow-ups and steering:** an auto-started follow-up starts its own turn clock and model/tool split.
  Steering delivered while no task runs starts its own task.
- **One tokens-per-second figure:**
  - It is output tokens, hidden reasoning included, over decode time from the first generated item to
    completion.
  - A reply delivered in one burst (decode under 250 ms) contributes no rate.
  - The menu bar, timing popover, report headline, Session info caption and sidebar all agree.
  - The round-trip rate is gone from the app.

### Workspace, Git, reports

- **Workspace:**
  - An unsent new chat keeps its draft while other chats are read.
  - Generate Title works after the first title.
  - Streaming no longer resets an in-flight Load earlier.
  - The idle helper stop keeps an unsent side and the context meter.
  - A steer that loses the race with the end of a run leaves the chat idle.
  - A draft side's first message is sent once, and a failed one leaves the side a draft.
  - Page keys in a side composer scroll the side.
  - Pasting text or a file that also carries an image pastes the text.
  - The chat being read never flashes unread.
  - Failure marks can be cleared and show on collapsed topics.
  - The Rename sheet stops its suggestion request when it closes.
  - ⌘. on an idle chat does nothing.
  - Switching chats writes no draft back.
- **Git and terminal:**
  - Renames commit and discard under both names.
  - Rows added or renamed and then deleted commit as they read.
  - A failed action keeps its message on screen.
  - A replaced refresh never blanks the branch list or stash count, and watcher refreshes show no
    spinner.
  - The terminal's shell no longer inherits the app's descriptors, so a stopped helper sees end of file
    at once.
- **Reports and inspectors:**
  - A refresh keeps the routing map, cost card and lists until their replacements land.
  - Zooming inside a zoom keeps its selection, and choosing a route narrows to exactly that route.
  - Turn details stay still while a response streams: one read instead of one every 2 s.
  - Payload search keeps its results while refining.
  - Session info neither jumps nor repaints on hover, and paging the Models table keeps the window.
  - The cost card ranks by cost, older attempts never repeat, and search pages its own query.
  - The wide layout keeps chart state.
- **Numbers:**
  - Rounding carries into the next unit ("1M", "1m 0s", "1s").
  - A small cache hit reads "<1%", and the cache hit counts only requests that reported both counters.
  - Turn-report totals say how many requests they cover.
  - A failed turn's error is said once.
  - Read cards number from their offset, and the live clock counts whole seconds at one width.
- **Product page:** belloware.com/bello-agent.html is redesigned in the site's family, with an HTML/CSS
  window of the app, in light and dark, from 320 to 1440 pt.

## Evidence

- **Debug whole suite** (Xcode 16.1, Swift 6 strict concurrency) on the candidate: **1,387 tests, 18 skipped, 0 failures**.
  - On 0.1.84 the suite had 1,250 tests and 7 assertion failures in 2 tests; both of those now pass.
  - The follow-up drag test failed intermittently in class order. The cause was the test sending before
    the app had taken the previous message; 0.1.84 has the same race. The test now forces that
    interleaving and passes 5 of 5 class runs.
- **Screenshot gallery:** `UIScreenshotTests` against the loopback gateway passed, with 64 screenshots in
  light and dark.
- **Helper:**
  - `swift test`: 342 tests. Two absolute CPU budgets in a debug build became shape assertions, with the
    absolute figures kept for optimized builds.
  - Wire tests 27/27 and acceptance 2/2 against the release helper.
- **Python script tests:** 53/53.
- **Release budgets:** 13 classes, 215 tests.
  - Five absolute budgets were missed: per-token delivery 1.5 vs 1.0 ms, worst frame while streaming and
    scrolling 34 vs 30 ms, worst frame in a wheel gesture 21–28 vs 20 ms, drag step 16.3–20 vs 16 ms,
    and one width change 25.4 vs 25 ms.
  - In alternating runs on the same machine, 0.1.84 misses the same budgets by as much or more (per-token
    delivery 1.6–1.85 ms; streaming and scrolling 35–42 ms; wheel 24 ms; drag 23–25 ms). This release
    does not cause them, and they are the next performance targets.
- **Not fixed in this release:**
  - The helper still rewrites all command receipts at each state checkpoint; that needs a journal format
    change.
  - Context links are still sent per attempt, not as new ids only; that needs an app archive change.
  - Per-token frames still carry the quarter-second metrics refresh.
  - Per-token regrouping costs about 1.3 ms at 300 rows (Release).
  - While scrolling far from a streaming reply, frames at an estimate average about 19 ms.

## Release provenance

- Source: tag `v0.1.85`, one release commit on GitHub. Native tree `73bb0fe8a5272238fb7cfdc793a5abbb367d9eb9`
  and helper tree `c0fcdca3c1adbe25be134a2fd0dfc236279c0b0b`, identical to the local candidate `bf81372` the
  DMG was built from. Only release-provenance documentation changed after the candidate build.
- Website publication: `4f99754e17e68d10fed56efffa0a08356acf91cb`, pushed; Cloudflare deploys from it. Its
  deployment check was not read, because the site repository's checks need GitHub authentication here; the
  live verification below is the evidence.
- Optimized native build, packaged helper smoke, Developer ID signing, app and DMG notarization, stapling,
  Gatekeeper and Sparkle artifact validation passed. Accepted notarizations: app `652b8902-0507-48a8-8d3c-f6437771a827`; DMG
  `b4e8627c-46ca-427f-9fdf-e4693911fc50`.
- Public verification at **2026-09-23 04:47:31 UTC**: the product page advertises 0.1.85, the canonical and legacy
  feeds are byte-identical, and the downloaded installer passes SHA-256 and Ed25519 verification.
- DMG: **9,703,299 bytes (9.25 MiB)**; SHA-256 `01bfcce84f218920a9b6199d9420c6cb15dd0bedb6d20334e2fce680096b9436`.
- Download: [Bello Agent 0.1.85](https://belloware.com/assets/BelloAgent-0.1.85.dmg). Fresh-install and
  updater/relaunch rehearsals remain omitted at the owner's request.
