# M4 validation — independent side conversations

Validated 2026-09-14 with Node 24.21.0, Pi 0.85.1, macOS 14.8 arm64.
The full host gate passed 101 tests, followed by all 15 side cases including
two additional cancellation/instruction cases: 103 distinct host tests.
The complete native suite passed 21 tests. M5 remains the release gate.

## Host evidence

- Both real Pi API adapters stream main and side independently. Cancel main
  while side completes, and cancel side while main continues. Requests retain
  exact fixture bytes; attempts carry immutable parent/cutoff/context provenance.
- Completed Pi entries produce an immutable safe boundary, excluding interrupted
  assistants and incomplete tool groups. A complete user is eligible. A 32 MiB /
  20,000-entry ceiling fails visibly. Nested compaction context is checked against
  Pi's public context builder rather than reconstructed from transcript text.
- Both APIs compact, snapshot, continue the side, fail Keep against a non-directory,
  successfully publish a validated independent file, reject overwrite, and append
  another read-only turn after reopening. Parent file bytes stay unchanged.
- Actual model-emitted read calls access live fixture files. Actual write and
  bash calls fail without creating the target. Historical explicit-skill prose
  remains history with no active grants; current automatic discovery stays filtered.
- Side initial instructions match the cached parent boundary despite intervening
  edits. The next side turn refreshes them and reports that change.
- The service deduplicates side open, rejects nested sides and parent retirement,
  pins unkept runtimes, rejects persistent side tracing, defers explicit Keep until
  idle, and removes captures on discard. Saved sides can opt into persistence.

Public SDK seam differences are recorded in [Compatibility.md](Compatibility.md).

## Native evidence

`/side question` creates the right-hand pane and submits to its own session.
Main and side use the same bounded React transcript and native composer, with
independent focus, Send/Queue, Steer, Stop, images, skill selection, metrics and
inspectors. The resource picker checks dependencies against its target's tool set.

Unkept sides write no draft, anchor, command intent, conversation index or trace
to disk. Keep alone writes a small recovery intent, then atomically registers the
host's validated Pi file and draft in SQLite. Tests simulate a lost Keep reply:
restart registers the already-published file without launching Node or replaying
anything. Invalid identity leaves the file and intent available for review.

The UI was exercised against a loopback fixture using the bundled host and
read-only imported synthetic profile. It visibly demonstrated:

1. Main and side streaming together, each with its own native composer.
2. Side Stop produced an aborted/paused side while main continued streaming.
3. An edited summary inserted below an existing main draft without another
   request. Native Undo restored the original draft and Redo restored the insertion.
4. Keep added a separate sidebar chat labeled Saved side / Read-only. Closing
   its panel and reopening it retained context and read-only tools.
5. Main Pi file remained byte-identical after closing/reopening the kept side,
   and contained neither side questions nor the unsent brought-back draft.

Synthetic parent `36ED3035-061E-4104-9220-91F1294FB223`: 7,712 bytes,
SHA-256 `a1faa1cf6b8d81a4c10a6aebbbebdc55e4373e7bd6744f44f4c59966a8387c94`.
Kept side `43E43C5B-DC9C-4DA7-915C-A18899563A6C`: 9,017 bytes,
SHA-256 `19bbb8e4a9dd7112a16c6acfe58cf6586d6b87d0cc9687205b1a301fdc25a7b8`.
Four HTTP requests covered the two main turns and two side turns; handoff and
Keep did not send any additional model call.

## Remaining M5 work

Release performance/stress measurements, accessibility and security review,
final idle update barrier, signed/notarized release and public upgrade proof.
M4 tool policy is not an OS filesystem sandbox. Unkept sides intentionally
disappear on host/app termination; Quit discloses that loss.
