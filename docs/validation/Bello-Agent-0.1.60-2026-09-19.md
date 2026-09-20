# Bello Agent 0.1.60/build 64 acceptance — 2026-09-19

**Public release verified at 2026-09-19 23:24:08 UTC.**
Release source: `ce252bcabe542efc58d87774f16bbe09b4a646d8` (local `main` commit under the owner's source-push
policy). Website: `4ceb9e8773b605931d15eceaf04b0e4947f6f2c7`. Later
documentation commits do not change the packaged source.

## Changes

Version 0.1.60 is the pass the owner asked for after 0.1.59: performance,
a smooth experience, an intuitive UI and good code, each driven by an agent
that measured before and after in a Release build and kept its measurement as
a test.

Streaming. A streamed token cost the helper a quadratic preview rebuild
(74 µs per token on a 4,000-token reply, now 0.6 µs), put the whole 250 KB
display page on the wire (now the changed rows and the appended text, about
3 KB), and made the app decode, re-encode and re-decode that page three times
per token; the app now applies row updates to the page it holds, reusing
untouched rows by identity, so a token reaches the transcript in 0.7 ms
instead of 4.9 and the first token of a reply lands inside one frame. The
footer's figures travel only when the app will show them, the journal is
flushed once per settled run instead of once per record, and the helper's
event ring no longer shifts 4,096 entries per event. A 0.1.59 helper and a
0.1.60 app still understand each other: the row-update form is opt-in and
any out-of-step read is a whole page.

UI and UX. A review of every screen, in both appearances and at narrow and
wide sizes, is in `docs/UX-Review-2026-09-19-0.1.60.md`. From it: run states
are words a reader knows ("Paused", "Waiting to send · 1", never the wire
word); a marked sidebar row is outlined rather than wearing the open chat's
highlight; the composer keeps the model's name and drops the effort label
first when the pane narrows; the sidebar's rate abbreviates ("Latest 123k
tok/s") instead of being cut mid-number; the footer's notice can say its
whole sentence; Settings no longer shouts its destructive action; fetch,
pull and push are named, and a disabled Commit says what is missing; skill
policies, request attempts and offsets read as words; the report's headline
cost is a readable figure with the exact one in the caption; tab labels
never wrap inside their pill; and the terminal's surface reads as a terminal
in both appearances.

The app shell. Every sidebar group and row observed the whole workspace
model, so one unread dot or one click rebuilt every visible row's press
surface, context menu and drag overlay: the rows and headers now compare the
values they draw, a selection change rebuilds two rows of the fifteen on
screen and a streamed delta rebuilds none, and the same change over 540 chats
costs 6 ms instead of 14. The composer's text view captured its coordinator
strongly, so every chat the reader had opened stayed in memory with its whole
transcript until quit (50 of 50 pages alive after visiting 50 chats; now the
model's own eight). At launch the sidebar painted every chat under a
"Retained chats" placeholder until the Keychain answered; the vault and the
chat list load together, the rest of configuration finishes after the first
paint, and the first sidebar row paints at about 110 ms with 400 chats.
Opening a chat made three database round-trips before its history read;
they are one, and the composer takes focus before the transcript finishes
loading. Polls that ran for views nobody could see (the inspector over a
minimised window, Session info while occluded) stop, and identical snapshots
are no longer republished at 1 Hz. The status panel counts on change rather
than once a second; draft writes and accounting rows clean up after
themselves; Settings builds only the groups that fit; asking whether a
draft is a command no longer copies the draft; and the bundled catalog is
read off the main actor.

The transcript. Opening a 300-row chat laid every row out before the reader
saw a word: 3.8 s frozen, 7,658 views attached. The document now measures
the rows the reader can see (plus what the anchor will show), estimates the
rest from their typography for the scroll bar, keeps estimated rows out of
the view tree, and measures the remainder in idle slices that never move the
row being read: first paint in about 180 ms with five rows mounted and 139
views, and a return to a chat already read measures nothing (300 heights
come from the shared cache). A row was measured twice per delta; once now.
Folding a long turn kept re-measuring its sixty tool rows; the measured
height lives on the row container, keyed as strictly as the geometry cache,
so a fold is a frame change. Scrolling a 2,000-row page stays inside a
120 Hz frame on all but two of 11,908 wheel steps. Visiting fifty long chats
does not grow the process. A row builds its SwiftUI tree when the reader
reaches it and gives it back when they are pages away, and the conversation
pane is kept across chats instead of thrown away on every sidebar click:
returning to a 300-row chat takes about 90 ms and switching to one not yet
read about 160 ms, with ten trees built instead of 300. A turn's tool calls
draw through a viewport-culled native surface (a closed card is one line
high whatever it says, checked, never trusted), so folding a 60-tool turn
costs 2 ms and unfolding 8. Page Up and Down, Home and End page the
conversation from the composer, and the reading position no longer slides
when the conversation leaves the titlebar's inset.

Smoothness. The three draggable boundaries (sidebar edge, terminal top,
the chat/side split) had no visible affordance and the split could not be
dragged at all; each now carries a grip that strengthens under the pointer,
and the split remembers its fraction. Every pointer-only action has a
keyboard path: sidebar width, Archive, Pin, Move to Topic and Mark as Read
on the focused chat, and folding the turn the reader is on. The error strip
took its room from the conversation's column instead of floating over the
sidebar and the first lines, in both appearances at full strength, with
Dismiss reading as a control. A chat switch arrives settled in one drawn
frame; the reading position holds through the composer growing, the
follow-up panel, the strip, the terminal, the side pane and window and
sidebar resizes; a wheel move holds through streamed deltas; hover answers
from the pointer's own frame with no workspace publication; Reduce Motion
goes through one decision for every animated surface. Closing the request
inspector aborted the app (a state write from inside SwiftUI's teardown) and
does not now. The composer bar laid out nine candidate forms on every pass
(three pill forms inside three run-control forms); it measures its labels
once and builds the one form that fits (3.1 ms to 0.12 ms a pass, an oracle
of 2,725 cases against the trial layouts agreeing to within two points).
Across the shell, a project or topic unfolds its rows out from under its
header, "Show more" rows arrive with them, a chat moving up on activity
slides past its neighbours, the marked-rows strip pushes the list, the
follow-up panel and the terminal slide up and down, the error strip comes
down over the column, and the composer's pills cross-fade between forms,
each under 2 ms a frame, each holding the reader's line; a cross-fade of a
chat switch was built, measured at a second of extra latency, and left out.

Code quality, behaviour-preserving. In the helper, the 1,311-line session
file is thirteen extension files named for what they hold (journal,
persistence, branching, queue, run loop, streaming, tools, display,
compaction, context, reads, test seams); `Support.swift` is six files; every
force unwrap, `try!` and crash on a path a request can reach now reports an
error with a message instead; every `@unchecked Sendable` carries the
invariant that makes it safe and every `Task {}` says who owns it; the test
seams are grouped and documented; dead state and two unreachable branches
are gone; a queued-message test that failed on every Release run was a race
in the test and is deterministic.

Motion. The owner asked for transitions that feel as good as the app is
fast: "it's fast, but it doesn't feel right." The 0.1.59 rule against
animating a row's height came from SwiftUI re-measuring the tree every
frame; the rule now is that motion is driven by the document from geometry
measured once. A fold or unfold measures its target exactly, rewinds to the
old geometry and eases the changed row's height over 220 ms while every row
below shifts by the same amount, the document's height and scroll bar
follow each tick, the folding list slides out under its clip and fades on
its native layer, the chevron turns on the same curve, a second click
carries on from where the motion is, streaming lands after it, and Reduce
Motion snaps as before: 0.11 ms of document work per tick over 300 rows,
rows contiguous at every sampled point. A tool card, exposed reasoning and
the compaction summary move on the same curve, with the region the two
states do not share masked and faded on the row's layer; the live turn bar
slides up into its slot when a run starts and down when it settles, the
slot itself changing the conversation's height exactly once. A row is sized
once per measurement instead of twice, and a side pane opening measures the
rows the reader can see (12 ms over 120 rows, from 450) and lets the rest
stand until the slices reach them. The kept pane retained the chat the
reader left; rebinding now releases everything the previous chat owned,
and visiting fifty chats keeps exactly the eight pages the model caches.

Code quality in the app. Nine files over 800 lines (the workspace view and
model, the Git panel, the terminal emulator, the design system, the report
page and three test files) are forty-two files named for what they hold,
moved verbatim and verified statement by statement; three sheet-question
mechanisms are one (`PiQuestion`), two text-measurement caches are one
(`PiTextWidth`), the environment reader, the release-budget seam and the
scratch-root helper live in one `TestSeams.swift`; dead code, dead branches
(the two on a `keepError` the helper never sends) and every force unwrap on
a reachable path are gone; every unchecked `Sendable` names its invariant;
and the rendered UI before and after differs by less than the gallery's own
run-to-run noise.

## Validation

**905 native tests pass with 14 skipped**, all opt-in (the full run held
one assertion that measured cache fill in Debug rather than the code; it was
made the Release claim it is and the three memory classes were re-run green,
27 tests, before the release build), and the screenshot
gallery and terminal capture classes pass with 58 light/dark captures
(the gallery grew seven scenes this version: turns open and folded, a running
turn with a follow-up, the sidebar with a topic and marks and at 200 points,
the error strip, and the window narrow and wide). The Swift helper package's
211 tests pass (up from 205: `StreamingCostTests`, `MessageDeltaTests`
and the split of `CoreTests` into eleven named classes), its 24 black-box
wire tests pass against the release helper, and the Python fixture tests
(52) pass. Local fixtures, throwaway repositories, real ptys and a real
`NSWindow` back every check; no deployed gateway and no personal repository
were used.

Every performance claim below comes from a test that stays in the suite and
prints its measurement; absolute frame budgets are asserted only in the
Release configuration (`PI_RELEASE_TESTS`), and the shape assertions beside
them hold in Debug. Release, this Mac (Apple silicon, macOS 14.8), before
the pass and at its end:

| Measurement (Release) | 0.1.59 | 0.1.60 |
| --- | ---: | ---: |
| Open a 300-row chat: first paint | 3,884 ms, 300 rows mounted | 180–250 ms, 5 rows mounted, 11 trees built |
| Views in the hosted transcript for 300 rows | 7,658 | 139 |
| Chat switch, 300-row chats: return to a read chat / cold | 341 / 418 ms in the transcript | 92–165 / 164–293 ms (0 rows measured on return) |
| Fold / unfold a 60-tool turn, click to relaid-out rows | 15 / 25 ms | 2–6 / 8–28 ms (the motion's click included) |
| Disclosure motion: document work per tick over 300 rows | (no motion) | 0.06–0.11 ms |
| One-shot width change over 120 rows (a side pane opening) | 450 ms | 12 ms |
| Scrolling a 2,000-row page at 120 Hz | unmeasured | 2 of 11,908 steps over budget |
| Streaming delta, layout + display, 300-row chat | 47.8 ms | 27–36 ms (two SwiftUI passes of the arriving row are the floor) |
| Helper CPU per streamed token (4,000-token reply) | 74 µs | 0.6 µs |
| Bytes on the wire per streamed token | 251,844 | 2,271 |
| Reply on the transport to page published | 4.9 ms | 0.7 ms |
| Whole 300-row page into rows | 4.2 ms | 0.24 ms |
| Journal fsyncs for a two-tool turn | 12 | 3 |
| Sidebar, 540 chats: one selection / unread change | 13.9 / 13.5 ms | 5.4–7.8 / 4.5–6.6 ms |
| Sidebar rows rebuilt per selection change / per streamed delta | all visible / all visible | 2 of 15 / 0 |
| Launch to first sidebar row, 400 chats | unmeasured (placeholder group first) | 110–180 ms |
| Composer bar: build and lay out per pass | 3.1 ms (nine forms) | 0.12 ms (one form) |
| Settings sheet: first open / reopened | 93–103 ms | 63–101 / 53–80 ms (the form is the floor) |
| Transcript pages alive after visiting 50 chats | 50 of 50 | 8 (the model's cache) |
| Shell transitions: worst frame (panel, strip, terminal) | (no motion) | 1.8 ms |

Numbers are one machine's, taken while other builds ran; the deterministic
counts (rows mounted, rows rebuilt, bytes, fsyncs, views) are exact and the
timings are given as the range between each agent's quiet run and the final
verification run (`perf-0.1.60.log`). Targets not met and
recorded honestly: a streamed delta into a 300-row chat is 27 ms end to end
against a 16 ms target (the arriving row is laid out by SwiftUI twice, once
to learn its height and once at its frame), and a first read through a long
chat still puts about 4 % of 10-point scroll steps over a 120 Hz frame
because a row reached for the first time draws from a tree with no cached
backing (drawing ahead was tried and made it worse).

Fresh-install and actual Sparkle update/relaunch rehearsals remain skipped by
owner instruction. What no test process can do stays unverified: how the
motions look and feel (they are pinned by geometry, cost and contiguity at
sampled ticks, not by eye), physical 120 Hz smoothness, a real pointer drag
and real clicks on SwiftUI buttons, Tab order and focus rings, VoiceOver, and
Reduce Motion as the system reports it (the decision is pinned through an
override).

## Distribution

- Product: [Bello Agent](https://belloware.com/bello-agent.html).
- Download: [BelloAgent-0.1.60.dmg](https://belloware.com/assets/BelloAgent-0.1.60.dmg).
- Size: **7,824,296 bytes (7.46 MiB)**.
- SHA-256: `0cf92ca649e56a4293a404fa98a9d8fcbe547d2ee9a97222a04be124e1cc81c7`.
- App notarization: `9dbdc502-e3df-4b62-a1f5-6c37cabdc2ea` (accepted).
- DMG notarization: `df42b57b-c2a9-4bb6-93c5-516a852a6f06` (accepted).

Developer ID signing, hardened runtime, notarization, stapling, Gatekeeper,
packaged helper/catalog smoke, version/build validation and local Sparkle
Ed25519 checks pass. Source `ce252bcabe542efc58d87774f16bbe09b4a646d8` remains local under the owner's source-push
policy. Website publication commit `4ceb9e8773b605931d15eceaf04b0e4947f6f2c7` was pushed and the live site served
it. Public verification at **2026-09-19 23:24:08 UTC** confirms identical
canonical/legacy feed bytes, the downloaded DMG SHA-256 and its Sparkle
signature, and the product page's 0.1.60 download link. Fresh-install and
Sparkle update/relaunch rehearsals remain skipped under the standing owner
policy.

Signing and notarization work: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build/release.Dl1c8c`.
Immutable artifacts, signed app and retained app/helper dSYMs: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build/releases/0.1.60`.

## Evidence

Scratch: `/private/tmp/claude-501/-Users-admin-projects-pi-app/d41bbd9f-7500-418b-8b22-588f8b1a9a07/scratchpad/build`.

- Native suite: `verify-0.1.60.log`; gallery and terminal captures:
  `gallery-0.1.60.log` with captures under `scratchpad/gallery59/screenshots`.
- Helper package: `helper-0.1.60.log`; black-box wire tests:
  `host-blackbox-0.1.60.log`. Python fixtures: `python-0.1.60.log`.
- Release measurements: `perf-0.1.60.log` (build `perf-build-0.1.60.log`).
  Helper staging: `bundle-0.1.60.log`.
- Each agent's report, with its own before/after numbers and its list of
  what it could not verify, is in the session transcript; the tests named
  above are the durable record.
- Signing and publication: `release-0.1.60-sign.log`, `publish-0.1.60.log`,
  `public-0.1.60.log`.

Historical [0.1.59 evidence](Bello-Agent-0.1.59-2026-09-19.md) remains unchanged.
