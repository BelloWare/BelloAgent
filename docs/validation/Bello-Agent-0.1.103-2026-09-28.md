# Bello Agent 0.1.103 — a request log without caps, and queued edits in the composer

Status: publicly released and verified at 2026-09-28 06:05:16 UTC.
Starting main: `9669b56b1190e034c78c57c29b18065ccda3e12f`.

## Root cause

The owner saw a compaction report "7/68", requests with no bodies ("The request
log never had this request"), and a compaction whose event list was
`"total": 0`, after an interrupted compaction. The investigation, before any
change, found:

- `CaptureDelivery` had a one-way breaker: one capture acknowledgment slower
  than 3 s set `failed` for good, and every later packet of every chat on that
  helper was refused. A large compaction request is written to the log page by
  page while the app is busy, so it could trip the breaker; from then on the
  log missed everything until the helper restarted.
- The request pages were sent, and acknowledged, before the request was
  dispatched, and the stream consumer awaited each page: a slow log slowed the
  chat as well.
- The archive refused every new request once 100,000 attempt rows existed, and
  rows are never deleted. It also capped event indices at 4,096 per request and
  100,000 in total (hence `"total": 0`), bodies at 32/64 MiB, writers at 128,
  metadata at 256 KiB and links at 10,000.
- A wire probe confirmed an interrupted compaction alone does not break
  capture; a slow acknowledgment does.

## Changes

Approved by the owner ("no cap on anything"; "okay, as long as data is saved";
"add unlimited option as well").

- **Helper, delivery** (`7da6bc2`): every capture packet goes into one ordered
  outbox with a single sender. A request is dispatched, and its stream parsed,
  without waiting for any acknowledgment. `CaptureDelivery` keeps one page in
  flight with no deadline and no off switch; shutdown still refuses the page in
  flight and every later one at once. A refused page stops only that request's
  kind of page.
- **Helper, memory**: every byte and SSE event index is kept (the former
  8 MiB/body, 128 MiB/host, 4,096-event and memory-trim rules are gone). A
  persisted chat's bodies and events are released only after the app confirmed
  every page of that request (`savedToLog`; `debug.body` answers
  `capture_saved`, and the inspector reads the log). A request with a refused
  page keeps its complete copy in the helper. A session-memory chat keeps
  everything. A saved request's record leaves the helper once a later request
  of the same chat is saved.
- **HTTP stream**: pause at 1 MiB pending and resume at 512 KiB; a response is
  never failed for its size (the 32 MiB ingress budget and 64 MiB response
  limit are gone).
- **Page joining** (`eee1824`): a stream used to wait for each page's
  acknowledgment, so a busy app received the chunks that arrived meanwhile as
  one page. Now that nothing waits, a page that continues a request's page
  still queued joins it, up to 32 KiB, unless something else of that request
  was queued after it (a masking notice or an event page), so no request's
  packets are reordered. Twenty streams on one helper behind a recorder that
  takes 10 ms per page caught up in 6.8 s instead of 19.4 s (1.8 s instead of
  4.8 s across four helpers).
- **Archive**: no attempt-count, writer, chunk-count, event, body-size,
  metadata, link, visible-id or offset cap. Counts and offsets must be exact
  JSON integers (at most 2^53): larger values are refused as damage before any
  arithmetic, which a first run caught (a trap converting 1e30).
- **Settings**: the payload quota has an Unlimited choice; saved settings keep
  their limit, and the limit is kept for switching back.
- **Inspector**: body reads, copies and exports have no size limit.
- **Output queue** (`52b9e6c`): the second gate caught the helper stopping
  itself under load (exit 70, "Native host output backpressure limit
  reached"). Streams used to pause while the app was slow to acknowledge
  capture pages, which also paused their change notices; now twenty streaming
  chats kept emitting a notice every 16 ms each through a brief read stall and
  filled the writer's 64 slots. The writer now keeps at most one change notice
  per chat, carrying the latest sequence number (the app's inbox already keeps
  only the latest); other frames keep the bound. With a reader pausing 150 ms
  every 40 frames, the 0.1.102 helper passed, the unfixed one exited, and the
  fixed one passes even with 1 s pauses; the concurrency suite now includes
  that case.
- **Queued messages** (`73c3668`), at the owner's request ("when modifying the
  queued message, try to show it in the normal chat input, otherwise styling
  looks strange"): the pencil opens the message in the chat's composer under a
  banner in the look of the earlier-message edit, with the draft set aside.
  Return saves it in its place (`queue.update`), Cancel or Esc leaves it as it
  was, and either brings the draft back. A previewed message is read whole
  first. If it is sent before the rewrite is saved, an untouched rewrite gives
  the draft back and a changed one stays in the composer ahead of it.

Kept, as validity bounds rather than capture caps: ids of at most 128 bytes,
32 KiB pages, 1 MiB frames, the 2^53 bound, the combined-response sparse-index
guards, the 1 GiB budget of exports without a destination, and retention.
Not changed, outside the approved list: the 32 MiB journal record limit and the
8 MiB SSE event limit of the parser.

## Validation

- **First full gate** (on `73c3668`): serial lane 210 passed (7 skipped);
  parallel lane 1,422 passed, 1 failed; gallery 1 failure (112 screenshots);
  helper 456; the wire and concurrent scripts failed; acceptance 2; Python 66.
  - `ManualCompactionTests` compared bodies as soon as the log listed three
    requests. The log now trails the chat, so it waits for their final records,
    as `StableToolPresentationTests` and `TitleGenerationTests` now do.
  - The wire and concurrent scripts read saved persisted bodies back from the
    helper, or counted the log before it drained. They now read the recorded
    log packets and wait for final records.
  - The gallery's new 13c scene waited while the fixture turn ended and sent
    the follow-up; it is now photographed after Stop, with the follow-up paused.
- **Second full gate** (on `57fcd82`): parallel lane 1,422 passed, 1 failed:
  the twenty-chat capture test, whose helper stopped itself (exit 70); fixed
  in `52b9e6c` (Output queue, above). Everything else passed: serial 210,
  gallery 114, helper 458, wire 32, concurrent 3, acceptance 2, Python 66.
- **Third full gate** (on `52b9e6c`, the release tree): serial lane 210 passed,
  7 skipped; parallel lane 1,421 passed, 16 skipped, 2 failed; gallery 114
  screenshots, 0 failures; helper 458; wire 32; concurrent 4 (with the new
  busy-reader case); acceptance 2; Python 66; 11 min 15 s. The twenty-chat
  capture test passed. Both failures predate this release:
  - `WireContractTests.testAHeldTerminalEventDilutesNeitherTheSessionPillNorTheSidebarNorSessionInfo`,
    the load-sensitive stream-span bracket (see 0.1.99): 5 of 5 passed alone.
  - `ConversationPaneRetentionTests.testSelectingChatsWithOnlyThePaneOnScreenReleasesThem`:
    run alone, it fails 11 of 20 on 0.1.102 and 8 of 20 on 0.1.103 (builds
    alternated). A probe found none of the app's task registries holding the
    left chat for six seconds; the hold is in view teardown, unrelated to these
    changes, and is left for a separate fix.
- **Wire probe** against the release helper: with one capture acknowledgment
  held for 3.5 s (the former deadline was 3 s), the compaction request and the
  next turn went out without waiting, and afterwards every packet of all three
  requests arrived, with no persistence error. A compaction stopped while its
  request was held, or while its pages were in flight, also left a complete log.
- **New helper tests:** a slow recorder delays packets but never switches
  capture off; twenty captures queue behind an unanswered recorder and arrive
  exactly; every byte is kept until the log saved it, and a session-memory chat
  keeps everything; 5,000 event indices; the helper keeps what the log refused;
  small chunks join pages without reordering; a busy reader never stops the
  helper (concurrency script).
- **New app tests:** the archive keeps what used to be capped; Unlimited storage
  never evicts while a limit still does; counts past 2^53 are refused; the
  Unlimited setting is saved; the queued rewrite happens in the composer (pane
  tests, and a live test through the packaged helper); gallery scene 13c in
  light and dark.
- **Live compaction test, fixture mode, on the release helper:** 3 of 3
  scenarios passed. Compact-now and mid-run each compacted in one summary
  request (mid-run recalled 10 of 10 markers), and a history too large for one
  request was refused with `compaction_too_large` before anything was sent.
  Reported cost $0.83 of the fixture's $5.00 cap (synthetic).
- Installation and updater rehearsals are excluded by the owner's standing
  instruction.

## Publication

- Release source: `c6204f9da61ff8849ff2d34534beba34c0d245f0`, pushed to GitHub `main`; annotated tag
  `v0.1.103` is pushed and resolves to that commit.
- Website publication: `0d7c0229c8dd4324b8cafb35907068edf3f5aaa7`, pushed to `BelloWare/belloware.com` `main`.
- Signed/notarized Bello Agent 0.1.103, build 107. App notarization
  `f7199a81-1dab-4fc5-ba6e-965d6004f5bb` and DMG notarization `14f3c271-c9ce-4262-88dd-4c71f967e911` were accepted. Stapling,
  signature, Gatekeeper and artifact validation passed.
- `BelloAgent-0.1.103.dmg`: **10,852,266 bytes (10.35 MiB)**; SHA-256
  `0c653a515ea2f73b5c2def660dd37c5417bdc9c54f0ad96a9073b21b928cf5fd`.
- At 2026-09-28 06:05:16 UTC, the public product page linked to 0.1.103.
  `scripts/verify-published.py` downloaded the public archive, verified its
  SHA-256 and Ed25519 signature, and confirmed that both public update feeds
  match the intended release and are byte-identical.
- No install or updater rehearsal was performed, at the owner's standing
  instruction.
