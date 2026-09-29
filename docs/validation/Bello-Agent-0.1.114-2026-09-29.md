# Bello Agent 0.1.114 — faster redraws, chats drawn once, a native Changes diff, sheets that let go

Status: publicly released and verified at 2026-09-29 11:35:46 UTC.
Starting main: `bbeec62ad4070f3cfd2bde1b5d6df8ab6047de80` (0.1.113's verified record).

## Scope

The owner asked for a release "without this side change". The side-switcher
mock-ups and the sidebar side-click fix (`874315c`, `f6f9863`) are on
`dev/sides`, which is not merged; `023812b` contains neither.

## Changes

Timings are the developer's, from Release builds unless noted.

1. **Faster redraws** (`5f40c96`, `8c96017`). A change anywhere in the app no
   longer redraws the transcript, its live bar and the footer's figures: 5.8 →
   3.2 ms per change. Switching back to one of the last three chats a pane
   showed reattaches its kept rows: 122 → 67 ms to ready, with no rows rebuilt.
2. **Chats drawn once, where they stay** (`e47287d`, `6b00308`, `97f705d`,
   `c8e1e02`, `6a79272`). Opening a chat no longer jumps after it is drawn
   (jumps of up to thousands of points on first opens, and "question, then
   jump to the end" on revisits). An idle chat whose last turn is taller than
   the window opens at that turn's question again, the 0.1.40 rule the owner
   confirmed. Switching away from a running chat no longer leaves its live bar
   or rows behind for a moment (16–134 pt shifts); a reply's figures that
   arrive after the reader left go on the chat's kept rows instead of moving
   rows; a chat left mid-reply whose reply finished in the background opens as
   it is now.
3. **Helper memory with long chats** (`f03c679`). Older rows are read from the
   journal where they are instead of being held: after paging or searching the
   helper held 46–139 MB more, now 6–12 MB. The first older page is about 10%
   slower. `docs/Journal-Metadata-File.md` is updated.
4. **History index files** (`582caa1`). The app's temporary history index files
   are removed at quit, and stale ones at launch, only those no running process
   holds.
5. **The Changes sheet** (`6561bbe`, `4c24602`, `a82270e`, `6c62425`,
   `d1cb35a`; Debug timings). It opens with no layout cycles (44–46 per open →
   0; the gallery's total fell from 122 to 14). The diff is a native table:
   whole diff to side by side 209–230 → 24–35 ms, jumping deep 122–132 → 5–6
   ms, a 400-file commit 192–204 → 11–12 ms, all 3,000 file chips about 50 s →
   68 ms. Text selection works across diff lines, with Copy, Select All and
   Copy Path in the context menu. The panel redraws only what changed: a
   keystroke in the commit message 20–44 → 5 ms.
6. **Every sheet in a window the app owns** (`775c32f`, `6c62425`). A closed
   sheet no longer keeps its views: Settings 7.4 → 1.3 MB per close, Resources
   7.3 → 0.8 MB, Changes about 20–40 MB → about nothing beyond a plain window.
7. **The Session Inspector** (`6561bbe`) opens with less work: Overview 771 →
   614 ms (Debug); the ledger builds rows as they scroll in; a 5 MB request's
   tabs load about twice as fast.
8. **Archive** (`5be2568`). One global switch, in the sidebar footer and in
   View ▸ Show/Hide Archived Chats. Archived chats are listed after each
   project's and topic's active chats, under "Archived · N". The switch is
   remembered, and opening an archived chat turns it on. The per-project
   "Archive · N" views are gone. `docs/Sidebar-Archive.md` describes it.
9. **Background requests** (`8b41974`, `f355f76`). Chat-title generation,
   title suggestions and webhook notifications are on one page, opened from
   the sidebar footer button, View ▸ Background Requests (⇧⌘B) or the menu
   bar's running requests: filters, status, results, cost, and details with
   the prompt and reply, plus Open Source Chat and Inspect Requests.
   Background chats no longer appear in the sidebar, and the eye toggle is
   gone. Records are kept; ones cut short by a quit are marked Interrupted.
   The owner declined a Clear action and any cap. `docs/Background-Requests.md`
   describes it.
10. **Fixes.** A title-suggestion or webhook request right after a Settings
    save could go out without the catalog's output limit, a model-catalog join
    race (`6a00e76`). A fork or kept side opened just as its file was renamed
    could stay on "Preparing…", a path-spelling race under /private/tmp or a
    symlinked state root (`dede69b`).
11. **Internal.** An opt-in soak test that hunts stalls and jumps (`SoakTests`,
    `0a8b6cb`, `2ea5745`; `docs/Soak-Test.md`, `scripts/soak-symbolicate.py`),
    an opt-in redraw cost probe (`RedrawCostProbeTests`), and a gallery that
    names every capture on standard error, popover captures included
    (`1f7f4af`), which 0.1.113's record noted were missing.

## Validation

- **Full gate** (`scripts/verify-release.sh`) on `023812b`, dev/next's tip,
  started once no other test run was on the machine: serial lane 244
  executed, 14 skipped (the opt-in soak and probe tests among them), 0
  failures; parallel lane 1,502 passed, 18 skipped, 0 failures; gallery **138
  screenshots, 0 failures**, with a `GALLERY-CAPTURE` line for each of the 138
  and no "AttributeGraph: cycle detected" line (122 in 0.1.113's gate; the
  developer's runs counted 14); helper 500, 4 skipped (the opt-in timings);
  wire 32; concurrent 4; acceptance 2; Python 66; all passed in 17 min 50 s.
  `ChangesSheetFrameTests.testAClosedSheetLetsGoOfWhatItRead` passed (13.0 s).
- `023812b` contains main (`bbeec62`), so the merge into main adds nothing
  else: the merged tree equals the gated tree.
- **Development evidence** (before the gate): the pre-handoff checks on
  `db1c0a4`, whose helper `023812b` keeps unchanged, passed: helper suite 500
  tests, 4 skipped, 0 failures; the wire, concurrent and acceptance scripts 32,
  4 and 2 on a Release helper. A full gallery passed on `dede69b` with 138
  captures, 19b in sequence, and the focused classes passed on every merge.
- `ChangesSheetFrameTests.testAClosedSheetLetsGoOfWhatItRead` failed once in
  development, at load 12 with another agent's test app running, and passed 8
  of 8 otherwise; its agent is investigating it for the next release.
- **Live compaction test, fixture mode, on the release helper:** 3 of 3
  scenarios passed (mid-run recalled 10 of 10 markers); reported cost $0.82 of
  the fixture's $5.00 cap (synthetic).
- The helper's Release build printed two compiler warnings, for follow-up:
  `SessionOlderRows.swift:114` (new in this release) captures a non-Sendable
  `UnsafeMutableBufferPointer` in a `@Sendable` closure, which Swift 6 mode
  would reject; each lane writes only its own indices (`at += lanes`), so the
  writes do not overlap. `JournalSlimming.swift:83` (since 0.1.113) writes
  `copyJournal` without reading it.
- Installation and updater rehearsals are excluded by the owner's standing
  instruction.

## Publication

- Release source: `0ef6ff75e348ac7eaf935b435c8b71cb9d0f4977`, pushed to GitHub `main`; annotated tag
  `v0.1.114` is pushed and resolves to that commit.
- Website publication: `dee17af66c5e7f44d61f8adf8d056884519f5aef`, pushed to `BelloWare/belloware.com` `main`.
- Signed/notarized Bello Agent 0.1.114, build 118. App notarization
  `44f503fc-ab5b-456d-a121-a095ba28a703` and DMG notarization `d19b2eec-cf03-480b-9d8c-0856faa47965` were accepted. Stapling,
  signature, Gatekeeper and artifact validation passed.
- `BelloAgent-0.1.114.dmg`: **11,442,935 bytes (10.91 MiB)**; SHA-256
  `ef234e46c5e394f338bf2fb8366f3d983acc3b2645494f264b1f2292ff67c2be`.
- At 2026-09-29 11:35:46 UTC, the public product page linked to 0.1.114.
  `scripts/verify-published.py` downloaded the public archive, verified its
  SHA-256 and Ed25519 signature, and confirmed that both public update feeds
  match the intended release and are byte-identical.
- No install or updater rehearsal was performed, at the owner's standing
  instruction.
