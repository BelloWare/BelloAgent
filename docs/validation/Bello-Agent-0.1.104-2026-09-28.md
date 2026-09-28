# Bello Agent 0.1.104 — no compaction strip in the input box

Status: candidate; publication pending.
Starting main: `0fe4368804350494f47b05df1c352246502f31a7` (0.1.103's verified record).

## Change

At the owner's request ("no need to display context compaction info in input
box"), the strip inside the composer is removed (`14874ac`). It showed
"Compacting context…" with the phase while a compaction ran, then "Context
compacted · …" with Dismiss. Both repeated what the chat already shows: the run
line under the composer names the phase ("Summarizing earlier work…"), as it
does for any run, and the transcript's "Context compacted" row shows the result
and the summary kept. The notice state behind the strip, used by nothing else,
is removed with it; the phase text stays for the run line.

## Validation

- **Full gate** (`scripts/verify-release.sh`) on `14874ac`: serial lane 210
  passed, 7 skipped; parallel lane 1,422 passed, 16 skipped, 0 failed; gallery
  114 screenshots, 0 failures; helper 458; wire 32; concurrent 4; acceptance 2;
  Python 66; 12 min 3 s.
- The pane test now checks that a compaction leaves the input box alone: the
  composer keeps its height while one runs and after, the field keeps its
  height, and the run line names the phase.
- Installation and updater rehearsals are excluded by the owner's standing
  instruction.

## Publication

(pending)
