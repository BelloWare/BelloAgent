# Bello Agent code review

Date: 2026-09-16. Reviewed at `e2d0b6e` ("Record verified Bello Agent 0.1.12 public release") with the working tree as it stood during the review. Read-only: no source was modified and nothing was committed.

Scope: `apps/macos/PiApp`, `packages/swift-host`, `packages/transcript`, `scripts`, and the root build configuration. Four parallel subsystem sweeps plus an independent cross-cutting pass.

## How to read this

Every finding is tagged:

- **[V]** verified directly in the code during this review, with the file and line quoted.
- **[R]** reported by a subsystem sweep with a specific file and line, not independently re-read. These are credible and specific, but confirm before acting.

Findings are grouped by theme and ordered by severity within each group.

## Baseline

| Check | Result |
| --- | --- |
| Swift host tests | 108 passed |
| Python tooling tests | 62 ran, 1 failed |
| macOS app tests | could not run, tree did not compile |
| Continuous integration | none configured |
| TODO / FIXME / HACK markers | 0 |

Two items were broken at review time:

- **[V] The working tree did not compile.** `apps/macos/PiAppTests/SessionTimingTests.swift:131` and `:136` fail Swift 6 sendability on the `save(model.traces, ...)` helper. The test method is `@MainActor` and the helper is not, so `self` crosses isolation. Marking the helper `@MainActor` or making it static resolves it. This was untracked work in progress, not shipped code.
- **[V] A committed test fails on every Mac.** `scripts/tests/test_build_dependencies.py:61` expects an unresolved temp path while the implementation resolves symlinks, so `/var` becomes `/private/var` and the assertion never matches. It landed in commit `d40e00e`.

---

## 1. Security

This is the most important section. The first two findings are architectural, not bugs.

### 1.1 [V] Critical: file tools have no workspace boundary

`packages/swift-host/Sources/PiAgentCore/Tools.swift:99-107`

```swift
if text.hasPrefix("/") || text.hasPrefix("~") { return canonical(text) }
```

Any absolute or tilde path is returned as-is. `canonical` at `Support.swift:95` expands the tilde and resolves symlinks, so the path is made *more* usable, not validated. The `within` helper at `Support.swift:96` exists and guards session journals at `Sessions.swift:156`, but is never applied to tool paths. Workspace roots are used only as a fallback for resolving relative names at `Tools.swift:104-106`, never as a boundary.

`read {"path": "~/.ssh/id_rsa"}` succeeds. So does `../../../etc/passwd`. In editing sessions, `write` can replace `~/.zshrc` or a file under `~/Library/LaunchAgents`.

### 1.2 [V] Critical: read-only sessions are not read-only for reading

`Tools.swift:84-89` adds `read`, `ls`, `find` and `grep` unconditionally, before the `if !readOnly` branch. A session created with `toolMode: "read-only"` therefore has full unrestricted filesystem read access.

This matters because it is reachable without the user doing anything wrong. Repository files, dependency readmes, `AGENTS.md` and MCP tool results all enter the model context as untrusted text. A single injected instruction in any of them can move credentials into context and out to the gateway on the next request.

### 1.3 [V] Critical: no tool approval model

`Tools.swift:119-122` executes a model-supplied string through `/bin/bash -c` with the real `HOME`, `PATH` and `TMPDIR`. There is no allowlist, no confirmation, and no round trip to the app. The handshake capability list at `HostService.swift:46` advertises no permission capability, so the app cannot gate it either.

Combined with 1.1, a successful prompt injection into an editing session is arbitrary local code execution. This is the largest single gap against what users of a coding agent expect.

### 1.4 [V] Response bodies are captured with no credential redaction

`Transport.swift:174-178` appends raw response bytes and, in persist mode, ships them to the app. Only the request body passes through `CaptureCredentials.requestBody` at `Transport.swift:133`.

A gateway that echoes a presented token in a 401 body writes that key durably into the inspector store, while the request-side copy of the same key was correctly fingerprinted. Running the same redaction over response bytes would close this cheaply.

### 1.5 [R] Model-authored links open with no destination disclosure

`packages/transcript/src/safe-markdown.tsx:22` renders anchors with no `title`, and the WebView shows no status bar. `TranscriptView.swift:228-229` passes any http or https URL straight to `NSWorkspace.shared.open`.

The rest of the sanitization chain was examined and found sound: `skipHtml`, `urlTransform`, the protocol and credential checks in `safeURL`, escaped highlight output, plain-text rendering of user and tool bodies, and the meta CSP. `connect-src 'none'` blocks automatic exfiltration and `img-src 'none'` blocks the image beacon, which leaves the click as the one remaining channel. Showing the real host would close it.

---

## 2. Data loss and stuck states

### 2.1 [V] A failed queued message is destroyed

`Sessions.swift:401` and `:409`

```swift
let next = queue.removeFirst()
do { try await deliver(next) } catch { commandState(next, "failed"); throw error }
```

The submission is removed, then on failure marked failed and rethrown, never restored. The shrunken queue is persisted afterwards, and only the command id, turn id and status survive. The user's text is gone.

Reachable through a revoked skill or an image attachment moved between queueing and dispatch.

### 2.2 [V] A tool timeout is reported as a user cancellation

`Tools.swift:42-45` has the timeout task call the same `cancel()` used for external cancellation, and `completeIfReady` at `:66` resumes with `CancellationError`. At `Sessions.swift:452` that is indistinguishable from a user stop, so the session records "Tool interrupted", cancels every remaining call, aborts the turn and pauses the queue.

A 120 second `npm ci` therefore ends the turn and pauses all follow-ups, and the model never learns it timed out. A distinct timeout outcome that returns an error result and lets the turn continue is the fix.

### 2.3 [V] One undecodable row empties the sidebar with no retry

`MetadataStore.swift:45-66` decodes rows inside the loop with no per-row skip, and there is no schema version or migration record in the file. `WorkspaceModel.swift:205` sets a private `loading` flag that is never reset, so `restore()` cannot run again in that launch.

Adding a property with a default value to `ChatRecord`, `DraftRecord`, `CommandIntent`, `SessionReadState`, `ProjectSidebarState` or `CapturePreference` triggers this, because synthesized `Decodable` still requires the key to be present. `WorkspaceRecord` already hand-writes `init(from:)` with `decodeIfPresent` for exactly this reason; the others do not.

### 2.4 [R] A stuck side conversation blocks quit and all updates

`WorkspaceSides.swift:70-79` only unwinds state when the error is `HostError.rejected`. A 30 second ack timeout, a `HostError.failure`, or the identity mismatch at `:59` leaves the side present and unkept while the host never registered it. Recovery then fails in both directions because close and keep both address a session the host does not know.

`hasActiveWork` at `WorkspaceModel.swift:190` is then permanently true, which refuses to close the last window, prompts on every quit, and makes `acquireUpdateBarrier` return false so Sparkle can never install an update for the rest of the process lifetime.

### 2.5 [R] Side drafts are never persisted

`WorkspaceModel.swift:326-327` drops every keystroke for ephemeral sessions. The only saves are the initial record at `WorkspaceSides.swift:56` and one after a successful close at `:155`. On host loss, `discardLostSides` removes the display outright and the text is unrecoverable.

### 2.6 [R] Quitting does not flush drafts

`prepareForInstall` at `WorkspaceModel.swift:769-772` explicitly cancels draft tasks and writes each draft and anchor, acknowledging that the 150 ms debounce is not enough. `shutdown()` does neither, and `applicationShouldTerminate` awaits only read state and sidebar state. A draft typed immediately before Command-Q can be lost.

### 2.7 [R] Writes are silently dropped when a revision is not newer

`MetadataStore.swift:33` upserts with `WHERE excluded.revision >= records.revision`, and `sqlite3_changes` is never checked, so a zero-row upsert is indistinguishable from success. Callers using the default timestamp revision include chats, drafts, anchors, handoffs, side keeps and pending intents.

A row written while the clock was wrong makes every later write to that chat a silent no-op. Renames and archive changes appear to work and revert on relaunch.

### 2.8 [R] Several flows create chats that exist only in memory

`newChat` and `createConnectionTestChat` fail cleanly when the store is unavailable, but `importChat`, `continueCopy`, `portableHandoff` and `enableEditing` use `try await store?.put(...)`, which optional-chains to nothing. The chat appears in the sidebar and is gone after relaunch. `enableEditing` silently reverts a tool-mode consent.

Separately, `send` has the store as the last clause of an eight-condition guard at `WorkspaceModel.swift:427`, so pressing Send does nothing at all with no message and no disabled state.

### 2.9 [R] A failed history load freezes the live transcript

`loadEarlier` and `revealConversationHit` set `browsingHistory = true` before awaiting, and never reset it on throw. Subsequent refreshes then skip message application for the rest of the session's life. The composer still works, so the transcript simply stops updating.

### 2.10 [R] Other stuck-state paths

- A side keep-registration failure aborts the whole snapshot handler at `WorkspaceModel.swift:479`, freezing that session's transcript permanently.
- A rejected `context.compact` leaves a phantom pending intent, so the session shows "outcome uncertain" and raises the repeat-effects modal for a compaction that never ran.
- `KeychainWorker.busy` at `SecretStore.swift:19-34` is cleared only when the blocking Security call returns, so one hung keychain prompt locks out every vault read and write until relaunch.
- Concurrent vault updates throw a conflict with no retry and no reload affordance anywhere in the UI.

---

## 3. Capture archive

### 3.1 [V] A hard lifetime ceiling of 100,000 attempts

No statement anywhere deletes rows from `attempts`. Expiry only tombstones them at `PayloadArchive.swift:470-486`, while `begin()` at `:107` gates new captures on `SELECT COUNT(*) FROM attempts` being under 100,000, which counts tombstones.

At that point capture fails permanently with a quota error, even with a short retention and an almost empty report. There is no prune path, no vacuum and nothing in the UI that explains it. `statistics()` at `:536` exposes the relevant counts and is called only from tests.

### 3.2 [V] A legacy encrypted archive can refuse to open forever

`PayloadArchive.swift:37-44` requires an `archive_info` row named `key-check` whenever any AES-GCM chunk or body exists. That row is read at `:42` and written nowhere in the codebase.

A legacy archive holding one encrypted chunk without it fails `configure()` on every launch, taking down the plaintext metrics, the report and all new capture with it. There is no way to quarantine the legacy ciphertext.

### 3.3 [R] A full maintenance sweep runs on every read query

`reconcile()` is called unconditionally at the top of `dashboard()`, `sessionSummaries()`, each `distinct()`, `usageMetrics()`, `list()` and `gatewayAccounting()`. Its first query scans every chunk reference in the archive, and `collectGarbage()` then scans the chunks table twice.

`refreshChatStats()` loops over every chat calling `gatewayAccounting`, so one filter change on the report can trigger hundreds of full sweeps on the archive actor, which also serializes live capture writes.

### 3.4 [R] A projection version bump cannot resume

`DashboardQuery.swift:146-191` deletes the progress marker before the work and writes it only after the loop completes, despite a comment claiming it resumes. A large archive decodes every retained metadata blob synchronously inside `open()`; quitting partway restarts from the beginning next launch.

### 3.5 [R] One unrecognised row bricks the archive

The migration transaction throws on any decode failure or unknown identity status, and the throw propagates out of `configure()`. There is no skip or quarantine path, so a single bad row disables the report, the inspector, the menu bar metrics and all new capture.

### 3.6 [R] Other archive issues

- `list()` decodes up to 128 full metadata blobs per call, and the inspector calls it once per second while open.
- Quota eviction re-runs a full `SUM(bytes)` scan per publish and loads an unbounded candidate list.
- `outcome` is written unvalidated, so an unknown value counts in the totals but appears in no status breakdown.
- `wall` has no sanity bound, so a millisecond-scaled timestamp creates rows that match no window and never expire, while still counting toward the cap in 3.1.
- `update()` at `PayloadArchive.swift:217` lacks the `metrics_retained=1` guard that both statements below it carry, which could resurrect a tombstoned blob. No live path to this was found.

---

## 4. Transcript

### 4.1 [V] A single render exception wedges the transcript permanently

There is no React error boundary anywhere in `packages/transcript/src`. `main.tsx:54-55` posts `committed` before the animation frame runs, so native clears its in-flight flag; if the render then throws, the post-paint notification never fires.

`TranscriptView.swift:209` refuses further snapshots once two are unpainted, and the two second watchdog at `:223` only cleans up when the in-flight flag is still set. The transcript is blank or stale until the app restarts, while the status string still reads as verified.

### 4.2 [V] No WebView content-process termination handling

`TranscriptView.swift` implements `WKNavigationDelegate` but not `webViewWebContentProcessDidTerminate`, `didFailProvisionalNavigation` or `didFail`. If the content process is killed the view goes blank, every later JavaScript call fails, and nothing reloads the page. Switching sessions does not help because it never touches the web view.

### 4.3 [V] A rejected snapshot looks like success

`main.tsx:27-50` returns `false` for any validation failure, and the rejection is all-or-nothing for the whole snapshot. `TranscriptView.swift:220` inspects only `case .failure` and discards the returned boolean.

One row carrying an unknown `kind` makes every snapshot containing it fail silently. The same applies to any future field the Swift side adds before the web validator learns it.

### 4.4 [V] Per-frame full serialization, twice

`main.tsx:51` stringifies and UTF-8 encodes every message on every apply, including every streaming delta. `message-row.tsx:63` uses `JSON.stringify` on both sides of the memo comparator, evaluated for all rows on every snapshot. That is roughly a megabyte of transient string allocation per frame on the main thread, immediately before a synchronous render.

### 4.5 [V] The lazy highlight.js import is not lazy

`scripts/build-assets.mjs:8-10` builds a single IIFE with `bundle: true` and no splitting, so the dynamic import in `safe-markdown.tsx:12` resolves to an already-bundled module. The built output is one 449 KB `transcript.js` with no second chunk, so highlight.js and its grammars are parsed at page load even for conversations with no code.

### 4.6 [V] Interrupting the jump-to-latest scroll strands the reader

This is a bug in code added during this session. `main.tsx:69-72` sets a `jumping` flag, and `:86-88` clears it only when the view returns to the bottom. If the reader clicks the pill and immediately scrolls up, the browser cancels the smooth scroll, following is off, and the pill never reappears because the detached state is skipped while `jumping` is true. Resetting the flag on any user-initiated scroll fixes it.

### 4.7 [R] Other transcript issues

- Scroll anchoring has no fallback when the anchored message leaves the host window, so the viewport jumps mid-read and a session switch can render at the previous conversation's offset.
- The scroll and resize handlers query every article and read its rect on every event, uncoalesced.
- `role="log"` is paired with `aria-live="off"`, so screen readers are never told a reply arrived. The jump pill unmounts on activation, losing keyboard focus. A long transcript is 200 or more tab stops with no skip mechanism.
- Every message carries a paragraph-length `aria-label` and `title` built from the full accounting explanation.
- A tool disclosure collapses out from under the reader when the tool finishes, because `open` is driven from state rather than being uncontrolled after first render.
- `addMarkdownCopyTargets` re-encodes the entire source once per copy target per parse.

---

## 5. Reporting accuracy

### 5.1 [R] Token totals mix three sample sets under one caption

`GatewayAccounting.swift:189-191` produces independent aggregates for input, output and total, and SQL skips a row entirely when either side is null. The report renders the input and output sums with the both-reported count as the caption, and the session usage window renders the both-reported total with the same caption.

Two screens can therefore disagree by a factor of two on the same data, and neither figure matches its own caption.

### 5.2 [R] Reasoning cost claims to be included in a total it can exceed

Reasoning cost is summed over its own sample set while the help text states it is included in the total cost. When the gateway reports a reasoning breakdown without a total, the help can show a figure several times larger than the total it claims to be part of.

### 5.3 [R] Other reporting issues

- `uncachedInputTokens` is all-or-nothing while `cacheReadTokens` is an unconditional sum, so one unreported request renders "cached 412k, uncached dash".
- Metric retention is never disclosed on the report, so a short retention silently shows a fraction of actual spend for a long window.
- The empty state appears when every request lacks an observed dispatch, hiding the summary, chart and table even though the details panel would explain it.
- Per-message accounting omits the session constraint on one branch, so a sibling session's attempt can be attributed to a message in this transcript, making visible per-message costs exceed the session total.
- The alias, model and purpose pickers truncate alphabetically at 256 entries with no indication.

---

## 6. Dead code and dead state machines

- **[V] `sideParents` is read in eight places and assigned in none.** `HostService.swift:28` declares it; the only mutations are removals. The nested-side guard, the side dedup branch, the capacity pin and the busy guards on forget and close are therefore all no-ops. Nested sides are creatable, repeated opens create unbounded sides, and a live side can be silently unloaded.
- **[V] `mutationHashes` has no eviction.** `HostService.swift:61-62` caps it at 4096 and never prunes, while sibling ledgers are trimmed to 512. After 4096 mutations every submit fails until the workspace host restarts.
- **[V] The `capture-preference` record kind is written nowhere.** `WorkspaceModel.swift:667` deletes it on chat deletion; it is the only occurrence in the codebase. The real per-session capture settings live in the 2 MiB vault, are never pruned, and eventually make every configuration write fail.
- **[V] Gateway model discovery is unreachable.** Nothing calls `GatewayModelDiscovery.models` except its own test file. Roughly 110 lines of production code and 120 lines of tests cover a path no user can reach.
- **[R] Side keep and ephemeral handling is dead.** `side.open` preserves immediately, so sides are never ephemeral, which makes the keep-when-finished path, the keep-requested and keep-failed events and the retry all unreachable.

---

## 7. Missing features

### 7.1 Model discovery

The picker resolves a catalog URL first and otherwise falls back to a bundled file of six models. Users cannot list their own gateway's aliases anywhere in the UI. A gateway whose aliases differ from the shipped list leaves every picker entry wrong, and because fallbacks are now disabled those become hard failures rather than silent substitutions. An explicit action to list the gateway's models would close this without breaking the never-implicit rule.

Related: disabling fallbacks sends a body field that a strict non-LiteLLM endpoint may reject outright. The escape hatch is labelled "Allow fallback models", which nobody debugging a 400 would find.

### 7.2 User-facing gaps

- **No notifications.** No notification centre usage, no dock badge, no attention request. For an agent whose turns run for minutes this is the most valuable missing feature.
- **No paste or drag to attach an image.** `Attachments.swift:33` opens a file panel and that is the only route. Screenshot to clipboard and drag from Finder both do nothing.
- **No search across chats.** Search covers one conversation. Finding an old chat means scrolling every project group.
- **No conversation export.** Only clipboard copy, capped at 8 MiB. No Markdown, JSON or text file.
- **No spend controls.** Cost is tracked per request with no budget, threshold or alert.
- **No per-model cost breakdown on the report.** The menu bar already computes one; the report offers only requests and sessions grouping.
- **No error drill-down.** No HTTP status or failure reason is projected, so a failed filter yields rows with no reason.
- **No storage visibility.** Nothing shows how close the archive is to its byte quota or the row cap in 3.1.
- **No keyboard navigation between chats**, no next or previous, no Command-digit, no sidebar focus. Rows are buttons in a scroll view, so arrow keys do nothing.
- **Multi-window is effectively single-window.** One model instance is shared, so a second window shows the same chat.

### 7.3 Accessibility

Font sizes are hardcoded at 84 call sites against one scaling-aware usage, and the transcript stylesheet uses fixed pixels. There is no text-size control. Sidebar rows carry no selected trait, so selection is invisible to assistive technology.

---

## 8. Architecture and process

- **`WorkspaceModel` is a god object.** It holds 114 stored properties, 60 of them published, is extended across 16 files, and is observed by 33 views. Per-session state was correctly split into separate observable objects, which protects the streaming hot path, but any change to the chat list still invalidates the report page and the composer.
- **All errors funnel into one modal alert.** 37 sites assign a single published string that `WorkspaceView.swift:65` renders as an alert. A background failure to save sidebar preferences interrupts typing with the same weight as a failed send, the text is lost on dismissal, and a repeated failure such as a full disk raises an alert on every debounce tick.
- **No database health story.** No integrity check, no backup, no vacuum. When the metadata store fails to open at `WorkspaceModel.swift:201` the app disables sending for the whole launch with no retry or repair.
- **No continuous integration.** No workflow configuration exists. Every check is manual and recorded by hand in the docs, which is how the failing Python test reached master.
- **`release.sh` runs no tests.** It goes from bundling to `xcodebuild` without typecheck, host tests, Swift tests or the macOS suite. The packaged smoke test never asserts the transcript assets exist and are non-empty, so an empty bundle directory can sign, notarize, staple and pass gatekeeper with every conversation view blank.
- **Version metadata has drifted.** `package.json` says 0.1.6 while `project.yml` says 0.1.13. The manifest's engine version and behaviour reference are string literals never checked against the artifact.
- **The transcript is typechecked as Node code.** One config covers the host and the WebView bundle with Node types, so Node-only globals typecheck cleanly in code that runs in WKWebView. `main.tsx` cannot be imported by a test, so the untrusted-input validator and all the scroll and anchor logic have no coverage while every pure module around them is well covered.

### The largest risk is one already documented

No real LiteLLM deployment has ever been exercised. All confidence rests on a 214-line hand-written contract fixture that encodes assumptions about header names, usage fields and fallback semantics. If production differs, no test in this repository can detect it.

---

## 9. Suggested order

1. Path confinement on all file tools, and remove read tools from read-only sessions or confine them.
2. A tool approval gate with an app round trip, advertised in the handshake.
3. The queued-message loss and the tool-timeout-as-cancellation bugs.
4. The two archive time bombs: the 100,000 row cap and the unwritten key check.
5. The transcript error boundary and content-process termination handling.
6. Continuous integration, and tests wired into the release script.

Everything after that is real but none of it loses data or leaks credentials.

---

## Appendix: examined and found correct

Recorded so these are not re-investigated.

**Host:** the async gate cancel and release races; SSE carriage-return and line-feed splitting with UTF-8 validation; tool history index alignment across append and replay; branch replay and kept-id subset validation; cancellation reaching a stalled session; managed child process-group isolation and signal escalation; request-body credential replacement including the JSON-escaped form; endpoint normalisation; the compaction cut guard, which is correctly protected by a minimum user-position count.

**App:** the dirty and in-flight snapshot handshake; the display eviction loop; the three explicit metadata transactions, which do roll back correctly; history pagination boundaries; the transcript clipboard and message-handler validation, which checks origin, frame, view id, sequence and exact source match.

**Dashboard:** nearest-rank percentile arithmetic, confirmed against SQLite integer division; bucket percentiles computed from raw samples rather than averaged; cache hit ratio excluding unreported and conflicting rows on both sides; all filters parameterised; deterministic session paging; per-message row-number attribution preventing double counting within a page; the quota-mid-write path marking a body partial rather than complete.

**Transcript:** the dual-validated copy path including surrogate boundaries and exact source equality; the postMessage gauntlet; read-receipt sequence matching; memory bounds at every layer; the CSP and sanitization chain, with no injection path found.

**Storage:** SQLite is configured with write-ahead logging, full synchronous mode, a busy timeout and foreign keys, on both databases.
