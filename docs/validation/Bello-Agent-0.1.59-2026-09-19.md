# Bello Agent 0.1.59/build 63 acceptance — 2026-09-19

**Public release verified at 2026-09-19 09:00:47 UTC.**
Release source: `f24e92d0649ceba066ad62e0a9ba439a0e07aacc` (local `main` commit under the owner's source-push
policy). Website: `25f67c4a683c0927981df5940388b4f3f1759fa6`. Later
documentation commits do not change the packaged source.

## Changes

Version 0.1.59 fixes the two things the owner reported after 0.1.58.

Folding and unfolding a turn's work went wrong on long turns: a click on a
turn with dozens of tool calls was slow, rows painted over their neighbours
while the height caught up, and a fold sometimes did not take. The open or
closed state of a turn's work, a tool card, exposed reasoning or a compaction
note was SwiftUI view state inside a row, so the AppKit document that owns row
heights learned about a click only when the hosting view happened to
invalidate its intrinsic size, one or two run-loop turns later; in between the
row kept its old frame and its content drew outside it. The state was keyed by
a block's latest row id, which changes as a turn grows, so a fold could reopen
on the next delta, and a 220 ms height animation kept the whole tree
re-measuring for its duration. Now that state lives with the conversation
(`TranscriptDisclosure`), keyed by the turn's stable key, each row reads its
own slice as a plain value and compares it like content, and a click records
the change, rebuilds that one row, drops its measurements and lays the whole
document out in the same pass; rows clip to their frames; the shared geometry
cache is keyed by the disclosure value so a height measured open is never
reused closed; the fold does not animate; and a folded turn keeps its list in
the tree at zero height and clipped instead of tearing sixty rows down and
building them again on the next click.

Dragging a chat in the sidebar never started: SwiftUI's `.onDrag` sat on a
row inside a `Button`, which claims the press on macOS, so nothing followed
the pointer. Each draggable row now carries a transparent AppKit surface that
takes only a plain left press, begins a real dragging session past four
points with a "N chats" image, and hands any other press (Control-click, the
row's own archive and side-chevron buttons, hover, scrolling) straight back to
the row; a press that ends without travelling is the click the row always
handled. Drop zones are the whole project and topic groups, not their header
strips. The first audit pass then found that the surface's tracking loop
could park the main thread for the rest of the session if a press never got
its release (window closed under it, a sheet taking the event stream); the
loop now polls and gives up when the button is no longer down, the row has
left its window, or a minute of silence passes.

The owner then asked for the bugs nobody had found. Six agents drove the real
views in real windows, area by area, and fixed what they confirmed; every
fix keeps its reproduction as a test.

Helper. A reply with many parallel tool calls produced a display snapshot
nine times over the helper's frame limit, and the helper exited mid-turn;
streamed tool cards are now projected in arrival order, capped at 32, with
constant memory beyond the cap. Every edit over about 4 KB showed raw JSON
instead of "Requested edit" because the arguments document was cut at a byte
offset; long string values are now cut individually with an explicit marker,
every card's input parses, `inputTruncated`/`inputBytes` say when it is
partial, and `session.tool.input` returns the full document (64 KiB for
edit-style tools) on demand. Editing a queued message longer than 1 KB saved
back its 1 KB preview; `queue.read` returns the whole text. Live tool cards
retired in lexicographic order (a running card could be dropped while a
finished one stayed) and had no memory bound; they now retire oldest-first
within 1 MiB.

Core. Every chat lookup was a scan of the whole list, called several times
per sidebar row per redraw, so the sidebar was O(chats²): 22.8 ms per redraw
over 400 chats, now 2.1 ms through an id index. The app's own idle stop of a
project helper made the next message fail with "Project host is stopping";
connect now waits for the previous helper to exit and starts a fresh one.
Quitting with text in a never-sent chat threw the text away for good. One
unreadable chat record disabled every topic move and topic deletion in every
project. Closing the last window or quitting during a run ran a blocking
modal alert inside AppKit's own decision (both new tests hang against the old
code); both now ask in a sheet. Capture was priced against the size of the
whole archive on every request (a full retention sweep per finished request,
a sum of every chunk per published chunk); the request inspector threw away
"Older Attempts" one second later; a local migration failure disabled
Settings permanently. The second pass fixed journal paging that decoded the
record once per 16 KiB page, id-less imported records that could never be
opened, a topic drop that decoded every chat in the database, SQLite opened
synchronously on the main actor during the first body, storage errors that
said "could not be saved" for read failures and "damaged" for a merely long
conversation, a stalled Keychain call that disabled credentials for the
session, an N+1 attempt listing polled at 1 Hz, a retention sweep that
committed once per row, a captured body decoded inside a view body on every
render, a connection switch that dropped the chat's model whenever the target
catalog had not been listed yet, a Settings sheet that stayed live during a
save, silent failed saves, a conflict retry that reverted another writer's
preferences, and a catalog fetch whose 8 s budget counted the whole transfer.

Sidebar. A Shift range under an active filter marked, and archived, chats the
filter had hidden. Folding a chat's side chats was forgotten whenever the
group was rebuilt, as was "Show 10 more"; both now live in the model and
travel in the existing project-sidebar record, so they survive a relaunch.
One unread dot or one selection cost three frames of main-thread work over
540 chats (44 and 41 ms); a sidebar index answers every group's lookup once
per change and the same events now cost 12 and 15 ms. The marked-rows bar
broke "Archive" across three lines at the sidebar's minimum width; project
names truncated in the middle ("be…ent") and the header kept three buttons
below 240 pt; Escape could not leave the rename sheet, or nine other sheets,
which `PiSheet` now handles for all of them; a chat deleted while a bulk
action ran was reported as a failure. The cursor pushed by a hovered row was
stranded app-wide when the window closed under it. The metrics line under a
chat laid out four candidate forms per row on every pass to find the one
that fits; it now measures its figures once and builds only the form that
fits (a 600-case oracle against the old view agrees everywhere), which took
3.9 ms off a frame on a workspace where every chat has run.

Git and terminal. "Stage all", "Discard All" and Commit on a repository with
thousands of changed files crashed the app: one argv held every path and
Foundation raised past 4,096 arguments; paths now go in batches and a commit
uses a pathspec file. A handful of git reads stalled every other task in the
app for seconds because the waits ran on Swift's cooperative pool; they run
on their own queue, at most eight processes at a time. A 20,000-line patch
took 23 s to open unified and three and a half minutes side by side (every
row built eagerly, every line walked, the split rows re-paired per redraw);
it opens in 85 ms and 143 ms. A commit touching 3,000 files froze the panel
for fifty seconds (one chip per file in a non-lazy layout); files list 200 at
a time. CRLF files showed their whole diff as one row (Swift reads "
" as
one Character); a renamed file showed as entirely added; clicking down the
file list left one `git diff` process per file; unticking every file was
undone by the next refresh; "Show the whole diff" followed the reader to the
next file. The panel now notices the working tree changing through FSEvents
(a saved file appears in about 300 ms, a burst of writes costs one refresh,
git's own writes cause none) and an automatic refresh never moves the reader.
In the terminal, scrolling back lost the reader's place as output arrived;
one streaming command cost 22,000 hops to the main thread (now 222); `cat`
on a binary file rang the system alert thousands of times; switching
projects stacked terminals in the panel and left the keyboard nowhere; a
shell per project lived for the app's whole life; the scrollback had no
memory ceiling (a 2,000-column window could hold 610 MB) and is now text and
style runs: four terminals of 10,000 dense lines cost the process 236 MB
before and 11 MB after.

Composer and run lifecycle. Typing into a long draft cost about 11 ms per
keystroke (the coordinator compared the whole document against the editor's
string on every edit, the footer re-rendered on every keystroke through an
observer it never read, `canSend` copied the draft to trim it); a keystroke
in a 200 KB draft is now 3 ms, most of it TextKit's own insert. The composer
bar stacked "Steer run" one letter per line in a 460-point pane. After the
helper died mid-turn the live bar and its Stop button stayed up for ever and
Stop did nothing; interrupted rows are now settled, the bar leaves, and the
next send starts a fresh helper. Stray typing walked the whole window's view
tree per keystroke to find the composer. Rewriting a queued follow-up clipped
the panel; editing a queued message over 1 KB saved its 1 KB preview back
(`queue.read` now supplies the whole text and the field waits for it);
pasting a 4000×3000 screenshot froze the window for 115 ms (PNG bytes now go
through untouched, other formats convert off the main thread); a long
gateway error was cut off with no way to read it (the strip opens, scrolls
and copies). "Previous command outcome is uncertain", "Delete this chat?",
the skill-arguments prompt, the image chooser, the connection test, keeping
a side and enabling editing all ran an application-modal loop that froze
every other chat's stream; each is now a sheet on the window showing that
chat, one at a time, with the work continuing in the completion.

Transcript. A turn folded while it ran sprang open when its reply settled
(blocks were keyed by the reply's provisional stream id, so the settled row
was a different row). A settled turn kept its "just arrived" accent for ever.
Every row was laid out natively three times per reflow, and every row built
three hover-only action pills and a copy control that only a pointer can
reveal: opening a 300-row chat to exact geometry took 2.3 s, now 1.2 s;
folding a 60-tool turn 30 ms, now 14. Dragging a pane's edge over a long
chat cost 729 ms a frame: resolving the reading anchor walked the whole page
for every row's frame (O(rows²)), and every row was re-measured on every
frame of the drag. The anchor is resolved once, and during a live resize the
document measures only from the top of the page to the bottom of the
viewport the reader will see, leaving the rows below standing at their old
height and out of the view tree, then measures everything when the drag
ends: 9 ms a frame over 500 rows, with a full read of the document after
the drag proving every row exact. The edit diff ran its O(n²) algorithm
inside a SwiftUI body on every redraw of an open card; it runs once per call
and refuses past 4,000 lines. The reasoning and compaction disclosures were
stock `DisclosureGroup`s and are now the transcript's own header. A run that
started as the pane opened never showed its live bar (the task wrote the
state captured when the view was built). A card whose arguments were cut
showed the raw fragment; it shows what arrived, fetches the whole document
through `session.tool.input` when opened, and a chat read from disk builds
the same card as a live one.

## Validation

**833 native tests pass with 14 skipped**, all of them opt-in (capture
viewers, interactive pointer checks, the gallery and acceptance classes that
need their root variable, a large-history launch measurement), and the
screenshot gallery and terminal capture classes pass with 42 light/dark
captures. The Swift helper package's 205 tests pass (up from 195:
`ToolInputDisplayTests` and `QueuedTextReadTests`), its 24 black-box wire
tests pass against the release helper, and the Python fixture tests (52)
pass. Local HTTP/SSE fixtures, throwaway git repositories, real ptys and a
real `NSWindow` back every check; no deployed gateway and no personal
repository were used.

New coverage, all of it driving real views in real windows: the transcript
(`TranscriptDisclosureTests`, `TranscriptStreamingStressTests`: a streaming
turn with the reader parked, folding mid-stream, cards through width,
appearance, scrolling and chat switches, a pane-edge drag over 240 rows with
no mounted row ever standing at an old height, the edit diff computed once,
a cut tool call fetched on demand, a 20 KB edit read from a journal); the
sidebar (`SidebarRowDragTests`, `SidebarDropZoneTests`,
`SidebarInteractionTests`: a press whose release never arrives, a row torn
down while held, a balanced cursor on window close, Shift ranges under a
filter, `SidebarScalePerformanceTests` over 540 chats,
`SidebarAppearanceTests` at 200 and 300 points in both appearances,
`SidebarMetricsLayoutTests` with a 600-case oracle, `PiSheetCancelTests`);
the composer (`ConversationPaneTests`: real keystrokes through the responder
path at four draft sizes, the bar at five widths, a helper killed mid-turn
against the packaged helper and the synthetic gateway, every chat question
as a real sheet with real return codes, the queue editor, a private-pasteboard
paste); the core (`WorkspaceLookupScaleTests`, `WindowLifecycleTests`,
`WorkspaceDisplayMemoryTests`, `InspectorAttemptListTests`,
`StorageTruthTests`, extended `HostTransportTests`/`HostSupervisorTests`
against the real packaged helper, `PayloadArchiveTests` pinned by SQLite's
own scan, statement and commit counters); git and terminal
(`GitPanelAuditTests`: 5,000 changed files staged, committed and discarded,
a 20,000-line patch at two widths in both layouts, the working-tree watch
with a burst, git's own writes, a moved repository and a linked worktree, a
real sheet for discard; `TerminalPanelAuditTests`: a real zsh on a real pty
streaming, resizing, scrolling back, the alternate screen, wide characters
and emoji copied, a killed shell, four terminals of history;
`BlockingAlertTests`, which reads the converted sources and fails on a new
modal loop); and the helper (`ToolInputDisplayTests`,
`QueuedTextReadTests`, with the per-delta snapshot size pinned).

Measured in a Release build on this Mac (Apple silicon, macOS 14.8), before
and after, from the tests that pin them:

| Measurement (Release) | before | 0.1.59 |
| --- | ---: | ---: |
| Sidebar, 540 chats: one unread change | 44.0 ms | 15.1 ms |
| Sidebar, 540 chats: one selection change | 40.6 ms | 15.2 ms |
| Sidebar, 540 chats: selection change with every row showing metrics | 18.9 ms (after the index) | 16.1 ms |
| Chat lookups for one sidebar pass over 400 chats | 22.8 ms | 2.1 ms |
| Composer: one keystroke in a 200 KB draft, 120-row chat | 6.6 ms of comparison alone | 3.0 ms end to end |
| Composer: pasting a 4000×3000 screenshot, main thread | 115.3 ms | 0.27 ms |
| Transcript: fold a 60-tool turn, click to relaid-out rows | 30.4 ms | 14.9 ms |
| Transcript: unfold the same turn | 34.9 ms | 25.2 ms |
| Transcript: open a 300-row chat to exact geometry | 2,289 ms | 1,191 ms |
| Transcript: one pane-edge drag step over 500 rows | 728.9 ms | 9.0 ms |
| Transcript: streaming delta into a 302-row page | 4.3 ms | 3.5 ms |
| Git: 20,000-line patch, unified, build + layout | 23,540 ms | 54 + 18 ms |
| Git: the same patch side by side | 219,469 ms | 118 + 22 ms |
| Git: commit touching 3,000 files, first files shown | 50,419 ms | 335 ms (200 files) |
| Git: unrelated task's first progress while 24 reads are in flight | 3,017 ms | 0 ms |
| Terminal: main-thread deliveries for `yes | head -100000` | 22,076 | 45 |
| Terminal: process growth for four terminals × 10,000 lines of history | 236.4 MB | 3.6 MB |
| Terminal: emulator cost per MB of output (the price of the smaller history) | 16.5–18.2 ms | 21.6 ms |
| Capture: rows scanned to publish a 512 KiB body into 832 chunks | 4,155 | 0 |
| Helper: snapshot frame with 400 streamed tool calls (limit 1 MiB) | 9,877,317 B | 138,128 B |

"Before" is the agent's own Release measurement of the code at the audit's
baseline with the same test; "0.1.59" is the final `perf-0.1.59.log` on the
merged tree. Two `PerformanceBaselineTests` lines whose definition changed in
0.1.5x (opening 300 rows through actual row layout, and a streaming delta's
layout plus display in a 300-row chat) are compared against the audit
baseline below rather than against an older record.

| `PerformanceBaselineTests` (Release) | audit baseline | 0.1.59 |
| --- | ---: | ---: |
| Open 300 rows through actual row layout | 5,495 ms | 3,425 ms |
| Streaming delta, layout + display, 11 KB reply in a 300-row chat | 86.8 ms | 47.8 ms |
| Open 61 rows through actual row layout | 875 ms | 712 ms |
| Streaming delta, layout + display, in a 61-row chat | 31.9 ms | 24.3 ms |
| Terminal feed, 3,515 KB | 78.8 ms | 97.1 ms |

The audit baseline is the same test run against the tree before the six
agents' branches were merged (a Release build of that commit on the same
Mac, back to back with the final run). Nothing the audit changed made any
of these slower except the terminal feed, which is the accepted price of a
history that costs a twentieth of the memory; the 300-row streaming delta
is the display of a fully mounted 300-row host in this test's shape, not
the document's own relayout, which the stress test pins at 3.5 ms.

One test hazard was found and removed during this verification: the
helper-crash test found its helper with `pgrep -f`, which also matched the
shell running the verification chain and would match the owner's own running
app's helper. It now kills only the helper its own model started.

Fresh-install and actual Sparkle update/relaunch rehearsals remain skipped by
owner instruction. What no test process can do stays unverified and is listed
in each agent's report: a real pointer drag (AppKit's drag loop cannot run in
a test), a real click on a SwiftUI button (the test host never becomes the
active app), VoiceOver, a gateway 4xx/5xx mid-stream, Escape against a
presented sheet, hover feel, and a backing-scale change.

## Distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.59.dmg](https://belloware.com/assets/BelloAgent-0.1.59.dmg).
- Size: **7,658,997 bytes (7.30 MiB)**.
- SHA-256: `27f4680d1e1181880309f17250328f8b93c39cb6a7db09407e2fae9f01d668ab`.
- App notarization: `1ffac71b-6ee7-4b61-987b-28ac62ca8881` (accepted).
- DMG notarization: `ec692f25-1b74-4995-a01c-2202d6b06dfa` (accepted).

Developer ID signing, hardened runtime, notarization, stapling, Gatekeeper,
packaged helper/catalog smoke, version/build validation and local Sparkle
Ed25519 checks pass. Source `f24e92d0649ceba066ad62e0a9ba439a0e07aacc` remains local under the owner's source-push
policy. Website publication commit `25f67c4a683c0927981df5940388b4f3f1759fa6` was pushed and the live site served
it. Public verification at **2026-09-19 09:00:47 UTC** confirms identical
canonical/legacy feed bytes, the downloaded DMG SHA-256 and its Sparkle
signature, and the product page's 0.1.59 download link. Fresh-install and
Sparkle update/relaunch rehearsals remain skipped under the standing owner
policy.

Signing and notarization work: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build/release.g8FewJ`.
Immutable artifacts, signed app and retained app/helper dSYMs: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build/releases/0.1.59`.

## Evidence

Scratch: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.

- Native suite: `verify-0.1.59.log`; gallery and terminal captures:
  `gallery-0.1.59.log` with captures under `scratchpad/gallery59/screenshots`.
- Helper package: `helper-0.1.59.log`; black-box wire tests:
  `host-blackbox-0.1.59.log`. Python fixtures: `python-0.1.59.log`.
- Release measurements: `perf-0.1.59.log` (build `perf-build-0.1.59.log`).
  Helper staging: `bundle-0.1.59.log`.
- Each agent's report, with its own before/after numbers and its list of
  what it could not verify, is in the session transcript; the tests named
  above are the durable record.
- Signing and publication: `release-0.1.59-sign.log`, `publish-0.1.59.log`,
  `public-0.1.59.log`.

Historical [0.1.58 evidence](Bello-Agent-0.1.58-2026-09-19.md) remains unchanged.
