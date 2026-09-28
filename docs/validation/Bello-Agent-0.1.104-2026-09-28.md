# Bello Agent 0.1.104 — no compaction strip in the input box

Status: publicly released and verified at 2026-09-28 07:50:17 UTC.
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
- **Live compaction test, fixture mode, on the release helper:** 3 of 3
  scenarios passed (mid-run recalled 10 of 10 markers); reported cost $0.83 of
  the fixture's $5.00 cap (synthetic).
- Installation and updater rehearsals are excluded by the owner's standing
  instruction.

## Publication

- Release source: `9fddcf39b8e5235d8f31b8c4d25f4da6ce15786f`, pushed to GitHub `main`; annotated tag
  `v0.1.104` is pushed and resolves to that commit.
- Website publication: `2062cfc084a401371d139086afd978ba390ce7cb`, pushed to `BelloWare/belloware.com` `main`.
- Signed/notarized Bello Agent 0.1.104, build 108. App notarization
  `3ea92c1d-72cd-46d1-8941-1cc1599afc0c` and DMG notarization `1973156b-bebe-4858-a4d7-10ea439c48ad` were accepted. Stapling,
  signature, Gatekeeper and artifact validation passed.
- `BelloAgent-0.1.104.dmg`: **10,845,266 bytes (10.34 MiB)**; SHA-256
  `0404e870c6ae60462eda4f91ce2576e0c3ec536f299a32aad29aabbbd9fc14e7`.
- At 2026-09-28 07:50:17 UTC, the public product page linked to 0.1.104.
  `scripts/verify-published.py` downloaded the public archive, verified its
  SHA-256 and Ed25519 signature, and confirmed that both public update feeds
  match the intended release and are byte-identical.
- No install or updater rehearsal was performed, at the owner's standing
  instruction.
