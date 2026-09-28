# Bello Agent 0.1.109 — a chat opens from its journal's metadata file

Status: candidate; publication pending.
Starting main: `f93981d2849f18792bf232f5d69abc33a6c95493` (0.1.108's verified record).

## Changes

1. **Superseded run state is skipped when reading a journal** (`172958f`). A
   long chat's journal is mostly run-state snapshots, written several times a
   turn with up to 128 command receipts each, and only the newest is used (81%
   of a synthetic 1,000-turn journal, 93% of that the receipts).
   - The helper's chain check reads a state record's id and parent from the end
     of its line; the replay already parsed only the newest. The app's history
     index does the same, and decodes only the newest state record, re-read by
     its offset after the scan.
   - Both find line ends with `memchr`; `Data.range(of:)` set up a Boyer-Moore
     search per line and was the largest single cost.
   - A 1,000-turn (71 MB) chat opens in the helper in about 0.46 s instead of
     0.6 s (Release). Damage inside a superseded state record is passed over by
     both readers alike; damage in the newest is still reported.
2. **A chat opens from its journal's metadata file** (`2ae1eb7`). Each chat
   journal gets a plain JSON file beside it, `<journal>.meta`, written by the
   helper after a compaction, an edit or a full open. It records where the
   model context starts after the latest of those (the rows shown from there
   on, and where each one is in the journal) and what the records before that
   point add up to (reply count, versions, spend, task records, the newest run
   state's record).
   - Opening a chat reads the rows it names and replays only the records after
     it; the app's history reader indexes the journal the same way. Older rows
     load from the journal when something reaches for them: a page past the
     loaded rows, a message read, search, versions, an edit or a fork.
   - The journal stays the only record. The file names the records it relies
     on (session header, native marker, the record it follows, the newest
     state) with the SHA-256 of their bytes. A file that is missing or
     unreadable, no longer matches, or has an edit after its checkpoint is
     ignored: the journal is replayed in full and the file written again. The
     first open of an existing chat after updating is such a full replay.
   - The app's page-cursor fingerprint hashes the journal's length and its
     first and last 64 KiB instead of the whole file; journals only grow.
3. **The file is documented and measured at scale** (`51b3750`).
   `docs/Journal-Metadata-File.md` describes it. The opt-in open benchmark can
   compact every so many turns (`PI_PERF_COMPACT_EVERY`), opens a kept journal
   where it is, and moves rather than copies the journal it keeps.
4. **An edited message's hidden versions are read after opening from the
   file** (`c8a78aa`). A chat opened from its metadata file loaded the shown
   rows from the checkpoint on, and the rest only when shown rows came before
   them. The rows an edit hid (a message's earlier versions) are never shown,
   so after an edit whose checkpoint starts at the first row, asking for the
   original message's versions answered "Message is not retained". The first
   0.1.109 gate caught it.
   - Helper: "opened from the file, not yet loaded in full" is its own flag
     (`partialHistory`); versions, message and tool-input reads by id, edits
     and forks load the whole journal whenever it is set. Search and copy,
     which read shown rows, load it when shown rows come before the loaded
     ones.
   - App: an index built from the file says so, and search, copy, an edit's
     timeline and a record's role index the whole journal.
5. **The gallery's slow turn has room to be stopped** (`140f9a8`, test only).
   The gallery stops its slow turn (13) about 20 s in, after four captures;
   the fixture's slow turn lasted about 20 s, so under a loaded gate it could
   end first, and its queued follow-up then ran instead of waiting.
   `PI_APP_UI_FIXTURE_SLOW_WORDS` lengthens it: the gallery asks for 200 words,
   about 45 s, and every other test keeps 80.

Measured by the developer on a 226 MB synthetic chat (3,000 turns, a compaction
every 100): the helper opens it from the file in 5 ms (Release), against 1.46 s
for a full replay; the app indexes it in about 25 ms (Debug), against 3.6 s
without the file.

## Validation

- **First gate** (`scripts/verify-release.sh`) on `51b3750`, 14 min 10 s:
  serial lane 213 executed, 7 skipped, 0 failures; parallel lane 1,451 passed,
  17 skipped, 0 failures; helper 478, 2 skipped; concurrent 4; acceptance 2;
  Python 66; but two checks failed, and nothing was released from it.
  - Wire, 31 of 32:
    `test_message_versions_list_and_page_an_earlier_version_over_the_wire`
    asked for an edited message's versions after a reopen and got "Message is
    not retained". It failed 2 of 2 alone on that helper and passed on the
    published 0.1.108 helper: a regression from `2ae1eb7`, fixed by `c8a78aa`.
  - Gallery, 126 screenshots: 13c found no queued follow-up after Stop, because
    the slow turn had ended first. Alone, the gallery passed with 128. Fixed by
    `140f9a8`.
- **Full gate** on `140f9a8`, dev/next's tip after the fixes: serial lane 213
  executed, 7 skipped, 0 failures; parallel lane 1,452 passed, 17 skipped,
  0 failures; gallery **128 screenshots, 0 failures**, 13b and 13c included;
  helper 480, 2 skipped (the opt-in timings); wire 32; concurrent 4;
  acceptance 2; Python 66; all passed in 13 min 22 s.
- dev/next contains main (`f93981d`), so the merge into main adds nothing else:
  the merged tree equals the gated tree.
- **Development evidence on `140f9a8`**, before the gate: the helper suite
  (Debug) ran 480 tests, 0 failures; the wire, concurrent and acceptance
  scripts passed 32, 4 and 2 against a Release helper built by
  `build-bundle.py`; `HistoryReaderCheckpointTests` passed 5 of 5 and
  `HistoryReaderStateTailTests` 4 of 4; the full gallery passed with all 128
  screenshots, 13b and 13c included. On `51b3750`, before the fixes, the helper
  suite ran 478 tests and the app's history reader classes 182, 0 failures;
  `CompactionGatewayTests` needed one test-only change (load the full history
  before comparing after a reopen).
- `JournalCheckpointTests` (6, helper): a chat opens from its metadata file as a
  full replay would; an edit moves the file, and a file an edit missed is
  replayed in full; older rows load when something reaches for them; a file
  that does not match its journal is written again; an edited message's
  versions are read after reopening; a hidden version is read when no shown
  row is older (the wire test's case, which failed with the old condition).
- `JSONParseTests` (2 more, helper): a state record's tail is read as the
  parser reads it; a line that does not end as the journal writes one is left
  to the scan.
- `HistoryReaderCheckpointTests` (5): a chat is indexed from its checkpoint; the
  selection path pages past the checkpoint; a file the journal does not match
  is not used; an edit after the checkpoint is indexed from the start; the
  whole-chat readers index the whole journal.
- `HistoryReaderStateTailTests` (4, plus an opt-in timing): the tail of a state
  line is its id and parent; the newest run state says what is unfinished; a
  newest failure is read and an older one is not; damage is reported only where
  the state is read.
- The timings (`HistoryReaderStateTailTests.testIndexingAKeptJournal`,
  `SessionOpenPerformanceTests.testOpeningAKeptJournal` and
  `testOpeningALongChat`) are opt-in, so the gate skips them.
- Installation and updater rehearsals are excluded by the owner's standing
  instruction.

## Publication

Pending.
