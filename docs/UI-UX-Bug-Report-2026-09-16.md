# Bello Agent: UI, UX and bug report

Date: 2026-09-16. Reviewed at `1cc50bc` (0.1.17) with the 0.1.18 catalog work in progress in the tree. Read-only: no source was modified and nothing was committed. Security findings are deliberately excluded from this report; they live in `Code-Review-2026-09-16.md`.

The tree builds. A fresh light and dark screenshot gallery was captured from it and reviewed screen by screen.

## Status after the fix pass (2026-09-17)

Fixed on master in eight commits, each verified with the host suite (132 tests), the app unit suite (380 tests), the transcript suite (139 tests) and a light and dark gallery capture:

- 1.1, 1.2 host: failed queued messages are kept; bash timeouts return an error result. The mutation ledger evicts instead of refusing work.
- 1.3, 1.4, 1.6 through 1.10: quit flushes drafts; a side that fails to open is unwound and its question returned; a lost side's draft moves to the parent composer; failed history paging, rejected compaction, Send and Import with no store, notice overwriting, repeated draft-save alerts and one bad chat row are all handled.
- 2.1 through 2.6: error boundary and reload, content-process termination reload, rejected snapshots honoured, tolerant marker kinds, jump-pill fix, cheaper per-frame work.
- 3.1, 3.2, 3.4, 3.5: token caption per side, reasoning wording, retention disclosure, no false empty state.
- 4.1, 4.2, 4.5, 4.7, 4.10: user markdown, banner instead of modal, dated axis labels, neutral capture pill, interruption notices kept. Inspector attempts show their time (4.4, partial).
- 5: export to Markdown, sidebar title filter, next and previous chat shortcuts, image paste and drop, Dock badge and bounce.
- 6: a finished reply is announced to screen readers.
- The failing Python test.

Still open: 1.5 by design (unkept side drafts deliberately never touch SQLite; the parent carry-over covers host loss but not quit), 1.11, 1.12, 2.7, 3.3, 3.6, 3.7, the remaining jargon in 4.4, 4.3 needs a manual check, 4.6, 4.8, 4.9, cross-chat content search, spend controls, per-model report grouping, error drill-down, storage visibility, text scaling and the sidebar selected trait.

## Tags

- **[V]** verified in the code during this review, with file and line.
- **[S]** observed directly in the fresh screenshots.
- **[R]** reported by an earlier subsystem sweep with file and line, not independently re-read.

## Since the last review

Two earlier findings are fixed and are not repeated here: tool call disclosures no longer collapse while you read them, and failed responses now persist as a visible banner in the chat. Everything else below was re-checked against the current tree and still holds.

Still broken at review time:

- **[V]** `scripts/tests/test_build_dependencies.py:61` fails on every Mac. The expected temp path is unresolved while the implementation resolves symlinks. Committed in `d40e00e`.
- **[V]** `package.json` says 0.1.6 while `project.yml` says 0.1.18.

---

## 1. Bugs that lose data or wedge the interface

### 1.1 [V] A failed queued message is destroyed

`packages/swift-host/Sources/PiAgentCore/Sessions.swift:407` and `:413`. Both the steering and follow-up drains remove the submission, then on failure mark it failed and rethrow without restoring it. Only the id and status survive. A revoked skill or an image moved between queueing and dispatch silently deletes the text the user typed.

### 1.2 [V] A tool timeout is treated as a user cancellation

`Tools.swift:44` has the timeout task call the same `cancel()` used for an external stop, and `:66` resumes with `CancellationError`. The session cannot tell the difference, so a 120 second `npm ci` aborts the whole turn, cancels remaining calls and pauses every queued follow-up. The model never learns the tool timed out.

### 1.3 [V] One undecodable chat row empties the sidebar with no retry

`Storage/MetadataStore.swift:55` decodes each row inside the loop with no per-row skip. `WorkspaceModel.swift:234` sets a private `loading` flag that is never reset, so `restore()` cannot run again in that launch. Adding a defaulted property to `ChatRecord` triggers this on upgrade, because synthesized `Decodable` still requires the key. `WorkspaceRecord` hand-writes `init(from:)` for exactly this reason; the other record types do not.

### 1.4 [V] Quitting does not flush drafts

`Application/ApplicationLifecycle.swift:19-24` calls `shutdown()` and then awaits only read state and sidebar state. `shutdown()` at `WorkspaceModel.swift:844` never touches drafts. The update path in `prepareForInstall` explicitly cancels the draft tasks and writes each draft, acknowledging that the 150 ms debounce is not enough. A draft typed just before Command-Q can be lost.

### 1.5 [V] Side conversation drafts are never persisted

`WorkspaceModel.swift:373` drops every keystroke for an ephemeral session. On host loss the display is discarded outright and the text is unrecoverable.

### 1.6 [V] A stuck side conversation blocks quit and all updates

`Workspaces/WorkspaceSides.swift:72-76` unwinds side state only when the error is `HostError.rejected`. A 30 second ack timeout or any other failure leaves the side present and unkept while the host never registered it, so close and keep both fail. `hasActiveWork` is then permanently true, which refuses to close the last window, prompts on every quit, and makes `acquireUpdateBarrier` return false so Sparkle can never install an update for the rest of the process.

### 1.7 [V] A failed "Earlier messages" load freezes the live transcript

`WorkspaceModel.swift:641` and `:646` set `browsingHistory = true` before awaiting, and the catch at `:654` only sets the global error. Only the "Latest messages" action at `:655` clears the flag. After one failed page load the composer keeps working but the transcript never updates again.

### 1.8 [V] A rejected "Compact now" leaves a phantom pending intent

`WorkspaceModel.swift:617-629` writes the intent before dispatch; the catch only sets the global error and never removes it. The next selection of that chat shows "Outcome uncertain for a previous command", and the next Send raises the repeat-effects modal, for a compaction that provably never ran.

### 1.9 [V] Pressing Send can do nothing at all

`WorkspaceModel.swift:489` has the store as the last clause of an eight-condition guard. When the metadata store is unavailable, Send returns silently: no message, no disabled state, no explanation.

### 1.10 [V] Some flows create chats that exist only in memory

`WorkspaceModel.swift:673` in `importChat` uses `try await store?.put(...)`, which optional-chains to nothing when the store is nil. The chat appears in the sidebar and is gone on relaunch, leaving an orphaned journal.

### 1.11 [V] A write with a stale revision is silently dropped

`Storage/MetadataStore.swift:33` upserts with `WHERE excluded.revision>=records.revision` and never checks `sqlite3_changes`. A chat written while the clock was wrong makes every later rename, pin or archive of that chat appear to succeed and revert on relaunch.

### 1.12 [R] Other stuck states

- A side keep-registration failure aborts the whole snapshot handler at the first `try`, freezing that session's transcript permanently.
- `KeychainWorker.busy` is cleared only when the blocking Security call returns; one hung keychain prompt locks out every vault read and write until relaunch.
- Concurrent vault updates throw a conflict with no retry and no reload affordance in the UI.

---

## 2. Transcript bugs

### 2.1 [V] A single render exception wedges the transcript permanently

There is no React error boundary in `packages/transcript/src`. `main.tsx:54-55` acknowledges the snapshot before the frame renders, so native clears its in-flight flag; if the render throws, the paint notification never arrives. `TranscriptView.swift:209` refuses further snapshots once two are unpainted and the watchdog at `:223` only cleans up while in-flight is set. Result: a blank or stale transcript until restart, while the status still reads as verified.

### 2.2 [V] No WebView content-process termination handling

`TranscriptView.swift` implements no `webViewWebContentProcessDidTerminate`, `didFailProvisionalNavigation` or `didFail`. If WebKit kills the content process, the view goes blank and nothing reloads it. Switching sessions does not help.

### 2.3 [V] A rejected snapshot looks like success

`main.tsx:27-50` returns `false` for any validation failure, all-or-nothing for the whole snapshot. `TranscriptView.swift:221` inspects only `case .failure` and discards the boolean. One row with an unknown `kind` silently stops every later update.

### 2.4 [V] The jump-to-latest pill strands the reader

`main.tsx:70` sets a `jumping` flag and `:87-88` clears it only when the view reaches the bottom. Click the pill, then scroll up before the smooth scroll lands: following is now off, and the pill never reappears. This was introduced in the current session and is mine.

### 2.5 [V] Heavy work on every streaming frame

`main.tsx:51` stringifies and encodes every message on every apply, and `message-row.tsx:71` compares messages by `JSON.stringify` in the memo. Roughly a megabyte of transient string work per frame during streaming, on the main thread, immediately before a synchronous render.

### 2.6 [V] The lazy highlighter is not lazy

`scripts/build-assets.mjs:9` builds one IIFE with no splitting, so the dynamic import of highlight.js is inlined. The built transcript is a single 449 KB file and every grammar is parsed at page load even for conversations without code.

### 2.7 [R] Scroll anchoring has no fallback

When the anchored message leaves the host's 60-message window the viewport jumps forward mid-read, and a session switch can render at the previous conversation's scroll offset.

---

## 3. Numbers and labels the UI gets wrong

### 3.1 [V] Token totals mix three sample sets under one caption

`Dashboard/GatewayAccounting.swift:190-191` produces separate counts for input, output and both-reported. `ReportPage.swift:232` renders the input and output sums with the both-reported count as the "n/n reported" caption. Two screens can disagree by a factor of two on the same data and neither matches its own caption.

### 3.2 [V] Reasoning cost claims to be included in a total it can exceed

`ReportPage.swift:515` and `Inspector/MessageDetailView.swift:156` state the reasoning cost is included in the total cost. It is summed over its own sample set. When the gateway reports a breakdown without a total, the help text can show a reasoning figure larger than the total it claims to be part of.

### 3.3 [V] "cached 412k, uncached dash"

`DashboardQuery.swift:121-125` makes `uncachedInputTokens` all-or-nothing, while the cached sum beside it is unconditional. One unreported request turns half of the same phrase into a dash.

### 3.4 [V] The report never mentions metric retention

`ReportPage.swift` contains no reference to retention. A user with a 7 day retention who selects 30 days sees a fraction of their real spend with no indication that rows were dropped.

### 3.5 [V] Empty state hides a populated report

`ReportPage.swift:31` shows "No requests in this range" whenever no request has an observed dispatch, even when the window contains dozens of rows recorded under an older timing contract.

### 3.6 [V] Filter pickers truncate silently

`DashboardQuery.swift:354` caps distinct aliases, models and purposes at 256, alphabetically, with no indication. A router with 300 aliases cannot reach the last 44 from the dropdown.

### 3.7 [R] Per-message accounting can attribute another session's attempt

One branch of the per-message query omits the session constraint, so a sibling session that re-links the same message id lands its cost on this transcript's message. Summing the visible per-message costs can then exceed the session total shown beneath them.

---

## 4. UX friction in the current screens

These come from reading the fresh captures, not the code.

### 4.1 [S] The user's own messages show raw markdown next to a rendered reply

In the main transcript the user bubble shows `**exponential backoff with jitter**` and backtick-wrapped `5` as literal characters, while the assistant's reply of the same content is rendered with bold and inline code directly beneath it. The user's message looks broken by comparison. Either render user markdown or at least treat inline code and emphasis.

### 4.2 [S] Every error is a modal alert

`WorkspaceView.swift:65` renders the single global error string as an alert, and 39 sites feed it. A background failure to save sidebar preferences interrupts typing with the same weight as a failed send, the text is gone once dismissed, and a full disk raises a new alert on every 150 ms draft tick. Failed responses were moved to a persistent banner in 0.1.16; the same treatment is needed for the rest.

### 4.3 [S] Unread count stays on the chat being read

In the capture, the selected and fully scrolled chat still shows an unread badge of 3. Read detection at `TranscriptView.swift:273` requires the app to be active and the window key, which the harness may not satisfy, so confirm this by hand. If it reproduces in normal use it is the most visible bug on the main screen.

### 4.4 [S] Raw identifiers and jargon in user-facing chrome

- The side pane subtitle reads "Snapshot through D777821D… · Initial instruction snapshot".
- The inspector's attempt list shows "Turn 59ED3A40-337D-4EAD" and two identical "attempt 0" rows with the same turn id and no timestamp, so they cannot be told apart.
- The inspector lands on the Overview tab, which is a full-height raw JSON dump, with an "Offset 0 of 0 bytes" pager that has nothing to page.
- The inspector footer reads "Durable request metadata · new payloads stored unencrypted · retained storage format and expiry remain inspectable."
- The skills sheet pages by "Source · UTF-16 offset 0".
- The search sheet is titled "Search and copy conversation", shows "6 matches on this page" with no query entered, has an empty numbered row, and offers "Start at Selection" and "End at Selection" with no explanation.
- The projects sheet says "Changes reopen the host on the next message."

### 4.5 [S] Chart axis labels lost their date

The activity chart's x-axis now shows bare "05", "11", "17", "23" for a 24 hour window. `ReportPage.swift:291` uses a default `AxisValueLabel()` with no format. Earlier builds showed "Sep 15 at 18". A bare number reads as a day of the month, and the last label is clipped in the compact layout.

### 4.6 [S] Icon-only chrome with weak discoverability

The header carries three unlabeled glyphs: a clock, a down-arrow and an ellipsis. The sidebar footer carries four: chart, bug, book and an eye-slash that toggles background sessions. All have tooltips, none has a label, and nothing hints at what "background sessions" are before you hover.

### 4.7 [S] The "Persist locally" pill reads as a warning

It is rendered in the accent colour in the footer of every chat. It is a status, not an action or an alert, and it draws the eye on every screen.

### 4.8 [S] A project with chats cannot be removed

The projects sheet says "Delete its 4 chats first". There is no bulk delete or archive-all, so removing a project with many chats is one confirmation dialog per chat.

### 4.9 [S] Dark mode user bubble contrast

In dark mode the user bubble is dark grey on a near-black ground. It is distinguishable but only just, and much less than in light mode.

### 4.10 [V] Interruption notices are overwritten on the next snapshot

`WorkspaceModel.swift:578-579` recompute a static notice on every accepted snapshot and assign it. The "Host interrupted. Outcome uncertain." message set at `:415` is replaced by "Editing tools · Trusted project" as soon as one snapshot arrives, while the uncertain flag survives, so the next Send raises the repeat-effects modal with no visible reason. Failed responses now persist separately; interruptions do not.

---

## 5. Missing features users will expect

- **[V] No notification when a run finishes.** No notification centre usage, no dock badge, no attention request anywhere in the app. For turns that run for minutes, this is the most valuable gap.
- **[V] No paste or drag to attach an image.** `Composer/Attachments.swift` opens a file panel and that is the only route; there is no drop target and no pasteboard image handling. Screenshot to clipboard and drag from Finder both do nothing.
- **[V] No search across chats.** `WorkspaceContent.swift:5` searches one conversation. Finding an old chat means scrolling every project group. The sidebar has no filter field and the chat list is capped at 10,000 rows with no notice.
- **[V] No conversation export.** Only clipboard copy, capped at 8 MiB. No Markdown, JSON or text file.
- **[V] No spend controls.** Cost is tracked to the request with no budget, threshold or alert.
- **[V] No per-model breakdown on the report.** The menu bar already computes one; the report offers only requests and sessions grouping.
- **[V] No error drill-down on the report.** Failed rows show only an outcome badge; each one needs an individual inspector sheet to learn why.
- **[V] No keyboard navigation between chats.** Seven shortcuts exist: new, open, report, inspector, send, stop, find. Nothing for next or previous chat, Command-digit, or focusing the sidebar. Rows are buttons in a scroll view, so arrow keys do nothing.
- **[V] No storage visibility.** Nothing shows how close the capture archive is to its byte quota or its row cap. Capture stops permanently at 100,000 lifetime attempts because rows are never deleted and tombstones count, and the only symptom is a quota error.

---

## 6. Accessibility

- **[V] Text does not scale.** 85 hardcoded font sizes against one scaling-aware usage, fixed pixels in the transcript stylesheet, and no text-size control. The design leans on 10.5 and 11.5 point text.
- **[V] Sidebar selection is invisible to VoiceOver.** `PiSelectableRow` sets no selected trait.
- **[V] Screen readers are never told a reply arrived.** `main.tsx:119` pairs `role="log"` with `aria-live="off"`.
- **[R] A long transcript is 200 or more tab stops** with no skip mechanism, and the jump pill unmounts on activation so keyboard focus falls to the body.
- **[R] Every message carries a paragraph-length `aria-label`** built from the full accounting explanation.

---

## 7. Suggested order

1. The three data-loss bugs: queued message destroyed, drafts not flushed on quit, side drafts never saved.
2. The stuck-side bug, because it blocks updates for the rest of the process.
3. Transcript resilience: an error boundary, process-termination reload, and honouring the rejected-snapshot boolean.
4. Tool timeout as a distinct outcome so a slow build does not abort the turn.
5. Replace the global modal with a dismissible banner plus a log, and stop overwriting interruption notices.
6. Render user markdown, restore dated chart labels, and trim raw identifiers from subtitles.
7. Notifications, paste and drag attachments, cross-chat search, export.
8. Report accuracy: consistent token captions, the reasoning cost claim, retention disclosure.
