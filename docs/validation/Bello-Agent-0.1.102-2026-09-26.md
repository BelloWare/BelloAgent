# Bello Agent 0.1.102 — long session journals

Status: validated; signing and publication pending.
Starting main: `ab921695a6c59949cc821cbab1b81209b4ff6783`.

## Root cause and changes

`SessionJournal.append` rejected a journal once its total exceeded 128 MiB,
using the same error as an oversized individual record. Reopening, forking,
recovery, portable handoff, and the app's history browser had matching whole-file
ceilings. Removing only the append check would have left long chats unreadable.

- Remove the aggregate journal-size ceiling from those paths. Existing JSONL
  files retain their format, record identities and complete history.
- Validate/replay native journals through a bounded record cursor. Opening no
  longer retains a full raw file plus a second array of parsed journal records.
- Stream fork copies and recovery; flush a fork before publishing its completed
  file. Preserve unknown metadata and original history, and never replay queued
  commands when forking.
- Hash portable-handoff provenance incrementally, with the same SHA-256 result
  on the accelerated and portable implementations.
- Let the app's SQLite offset index browse long files; scan newline boundaries
  in Foundation rather than looping over each byte in Swift. Remove the leftover
  100,000-ID limit when reading a complete indexed timeline.
- Recovery streams past even an oversized unfinished last record; a complete
  oversized record is still refused rather than silently dropped.
- Release validation also exposed a request-inspector race: an empty in-progress
  capture could remain cached after its final body arrived. Refresh the visible
  request on descriptor changes and key cached documents by the bytes actually
  read. Stale cancelled readers cannot clear a newer body task.
- Keep single-writer locks, branch/identity validation, incomplete-tail refusal,
  recovery-copy publication and the 32 MiB individual-record protection. The
  latter now reports a record-specific error without telling users to start a
  new chat. Physical storage and the runtime's retained semantic history still
  consume resources; this is not a claim of constant total memory at any length.

## Validation

- Focused helper checks: 45 passed, 0 failures, 13.023 seconds.
- `LongJournalTests` creates a real journal over 129 MiB by appending across the
  former limit. It continues a turn, reopens with the same context, forks both
  the whole history and an earlier reply, exports a portable preview, then
  recovers an incomplete tail while preserving the original. Cursor chunk/UTF-8
  boundaries, original-byte hashing, file changes, truncated tails and oversized
  individual records also pass.
- The app's `LongJournalHistoryTests` browses a real journal over 129 MiB and
  reads its first/latest messages through warm and cold readers. Identity and
  automatic-context eligibility remain valid. Passed in 1.220 seconds.
- Full release gate: native serial lane 201 passed / 7 optional skips; parallel
  lane 1,417 passed / 16 optional skips; no native failures. All 453 original
  helper tests, 32 wire tests, 3 concurrency tests, 2 acceptance tests and 66
  Python tests passed. The gallery generated 112 screenshots, with one failure
  in the compaction request preview (the empty-capture race above).
- After the final recovery adjustment: all 454 helper tests passed, 70.413 seconds.
- Final rebuilt inspector/history selection: 46 passed, 0 failures, 20.238
  seconds. The new partial-capture test also caught a cancelled read entering
  its loading state after cancellation; body tasks now check their generation
  before starting. Cache-revision, tab visibility, stale-read, navigation and
  performance checks pass.
- The exact previously failing compaction gallery scene passed in light and
  dark appearances: 1 test, 0 failures, 11.423 seconds. The unchanged remaining
  gallery scenes retain their full-gate evidence.
- Rebuilt production helper transport checks: 32 wire tests (32.116 seconds),
  3 concurrency tests (13.207 seconds), and 2 acceptance tests (2.598 seconds),
  all passed. No pending failed check remains.
- Live gateway requests are not exercised: the required live-test environment
  variables are not configured. This change concerns persistence and browsing;
  provider generation and compaction policy are unchanged.
- Installation and updater rehearsals are excluded by the owner's standing
  instruction.

## Publication

Pending signing, notarization, source/tag publication,
website deployment, and public download hash/signature verification.
