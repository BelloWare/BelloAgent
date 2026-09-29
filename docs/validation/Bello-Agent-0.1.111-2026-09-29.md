# Bello Agent 0.1.111 — only the changed command receipts in each run-state record

Status: publicly released and verified at 2026-09-29 00:42:44 UTC.
Starting main: `4be51d5f1fa880ddaec996fdd72e23f4a587d720` (0.1.110's verified record).

## Changes

1. **A run-state record saves only the command receipts that changed**
   (`e837c8a`). A chat's run state is saved several times a turn, and every
   record repeated the receipts of the last 128 commands, although usually one
   had changed; in a 1,000-turn synthetic chat those copies were 53 MB of
   71 MB.
   - A run-state record (`pi-app.native.state.v1`) now carries in `commands`
     only the receipts added or changed since the record before it, marked
     `data.commandsDelta`. The whole list is written in the first record after
     an open, after a failed write, whenever the changes would not rebuild it
     exactly, and at least every 64 records. An edit's `nativeState` and a kept
     side's new journal hold whole lists. Every other field stays whole in
     every record.
   - A replay keeps the newest whole list and the change records after it, and
     rebuilds the list once at the end (`CommandReceipts.swift`).
   - The metadata file's helper JSON carries `commands`, the whole list at its
     checkpoint. A file without it over a record of changes is not used: the
     journal is replayed in full and the file written again.
   - Journals written before are read as they were and never rewritten. A
     version before 0.1.111 reads a record's `commands` as the whole list: it
     still reads the queue, the run and the newest receipts, and lacks only
     older commands' receipts, which it needs just to recognise one of those
     commands sent again.
   - `docs/Journal-Command-Receipts.md` describes the format;
     `docs/Journal-Metadata-File.md` and `docs/Implementation-Status.md` are
     updated.

Measured by the developer on the 1,000-turn synthetic chat (Release): the file
is 18.8 MB instead of 71.0 MB, its run state 5.2 MB instead of 57.4 MB
(receipts 1.0 MB instead of 53.3 MB); a full replay takes about 420 ms instead
of about 600 ms; with a compaction every 100 turns, an open from the metadata
file still takes about 5 ms.

## Validation

- **Full gate** (`scripts/verify-release.sh`) on `e837c8a`, dev/next's tip:
  serial lane 213 executed, 7 skipped, 0 failures (`LifecycleHelperTests` 5 of
  5 among them); parallel lane 1,457 passed, 17 skipped, 0 failures; gallery
  **128 screenshots, 0 failures**; helper 486, 2 skipped (the opt-in timings),
  `CommandReceiptsTests` 6 of 6 among them; wire 32; concurrent 4; acceptance
  2; Python 66; all passed in 12 min 58 s.
- dev/next is main (`4be51d5`) plus this one commit, so the merged tree equals
  the gated tree. It changes the helper and docs only: `apps/macos`,
  `scripts`, `fixtures` and the project files are unchanged since 0.1.110.
- **Development evidence** (before the gate): the helper suite (Debug) ran
  486 tests, 2 skipped, 0 failures; the wire, concurrent and acceptance
  scripts passed 32, 4 and 2 on a Release helper. The app (Debug, with the new
  bundled helper) passed `HistoryReaderCheckpointTests`,
  `HistoryReaderStateTailTests`, `WorkspaceFailureTests`,
  `AutomaticContextTests`, `SideTests`, `SideRelaunchTests` and
  `ConversationRunTests`, and `LifecycleHelperTests` 5 of 5 alone.
  `HistoryReaderOpenPerformanceTests` indexed a new-format 1,000-turn journal
  (5,020 rows) in about 1.1 s in Debug without a metadata file.
- `CommandReceiptsTests` (6, helper): changes are written only when they
  rebuild the list exactly; a long chat writes changes, and every open, in
  full or from the metadata file, rebuilds the same receipts; a reopened chat
  starts with the whole list and keeps its receipts; a failed write is
  followed by the whole list; records written before this format open as
  before; run-state records stay small once the list is full. They fail if the
  rebuild ignores change records.
- **Live compaction test, fixture mode, on the release helper:** 3 of 3
  scenarios passed (mid-run recalled 10 of 10 markers); reported cost $0.82 of
  the fixture's $5.00 cap (synthetic). Its seeded histories come from the
  repository's own text, so they differ from 0.1.110's (for example 92 seeded
  messages mid-run instead of 60, for the same 46% of the window); the
  requests, the compaction point and the checks are as before.
- Installation and updater rehearsals are excluded by the owner's standing
  instruction.

## Publication

- Release source: `f668eb0c66a2f922f60ea29c54e1d19284bd4fd7`, pushed to GitHub `main`; annotated tag
  `v0.1.111` is pushed and resolves to that commit.
- Website publication: `85eaf150554eb82057659040d2dff7e946bbc9de`, pushed to `BelloWare/belloware.com` `main`.
- Signed/notarized Bello Agent 0.1.111, build 115. App notarization
  `bfc0feb4-7a9d-4415-97fb-6b38662f4118` and DMG notarization `fc78a68a-74fd-438b-9f47-219bf82acc3a` were accepted. Stapling,
  signature, Gatekeeper and artifact validation passed.
- `BelloAgent-0.1.111.dmg`: **11,144,051 bytes (10.63 MiB)**; SHA-256
  `3dbf3918ac4fcda94680a846a985eb14d13a49d8d4b56532372c0b151f4de446`.
- At 2026-09-29 00:42:44 UTC, the public product page linked to 0.1.111.
  `scripts/verify-published.py` downloaded the public archive, verified its
  SHA-256 and Ed25519 signature, and confirmed that both public update feeds
  match the intended release and are byte-identical.
- No install or updater rehearsal was performed, at the owner's standing
  instruction.
