# Restored sidebar run state

Source baseline: BelloAgent Swift main `6319e368c6ddb7c3ef18605e78f23b1a5b69e63a`.
`WorkspaceRunHolds.swift:18–41,47–64,120–157` restores unloaded rows and gives known
live displays precedence. `HistoryReader.swift:80–94,108–116,906–943` distinguishes
interrupted active work, paused queued/stopped work, failures and unknown reads.

This Rust slice uses the existing durable checkpoint and generation-scoped journal
as truth. It does not introduce another persisted run-hold schema or bootstrap
marker. An unloaded row initially says **Unavailable**, then one background
`SessionInspectionLease` validates its identity, schema and complete journal.
Active saved work displays **Interrupted**; paused, queue-paused (including no work),
queued and held-edit work displays **Paused**; failure displays **Failed**; validated
idle displays **Ready**. Missing, busy, malformed, incomplete or replaced storage
stays **Unavailable**. No idle-admission predicate is used to classify Ready.

The app inspects sequentially, holding at most one parsed session. Each history and
lease is dropped immediately after projection. Existing core limits (256 MiB
checkpoint and 512 MiB journal, with bounded records) apply. Every candidate,
including an unsuccessful read, is attempted once per view scope, rather than
repeatedly on redraw. This is a point-in-time saved-state observation, not continuous
filesystem monitoring, proof of durability or a permission to act. Switching chat
selection, reloading the selected chat, or rebinding the window starts a fresh
scope; thus a released writer or externally changed file can be inspected again
without opening that saved chat. There is no automatic timer or retry loop.

Project path, workspace object, window binding, navigation and selected load
generation fence the scope. Exact catalog records fence row identity and path.
Rebinding/reloading/navigation invalidates observations; a loaded controller always
wins and removes its saved observation. Shutdown or known catalog uncertainty
invalidates saved observations. Stale completion cannot restore them. Metadata
identity (including inode on supported Unix targets) is checked around inspection;
same-length replacement observed at the final background check is unknown. External writes after
the final read remain outside the point-in-time guarantee.

No controller is created, no queue is resumed, no provider/tool is invoked, no
credential is read, and no recovery/checkpoint/journal/catalog write occurs. Native
vault, trust and tool capability gates are unchanged. Unread marks, activity ordering,
draft markers, content indexing, and Swift's immediate persisted-summary startup
optimization are outside this slice.

## Verification

`sidebar_run_state_tests` covers source state projection, paused-without-work,
held/queued work, active journal preservation, held writer, unknown/missing/foreign
identity, incomplete/damaged tail, legacy byte preservation, same-length/inode
replacement, sequential restore without controllers, bounded unknown attempts,
stale lifecycle/identity completion and loaded-controller precedence.

Integrated on published Rust base `e2a67c855442a22a24d71a26707df425c5fe277f`.
The 12 focused tests pass, including a fresh `AgentView` constructed over a saved
catalog containing Paused, Interrupted, Ready and writer-held unavailable rows.
No saved controller is loaded or storage changed by that startup test.

Validation so far:
- Full default core: 485 unit + 127 integration tests passed.
- Full all-features core: 670 unit + 127 integration tests passed.
- Final default app: 519 passed, 1 pre-existing ignored.
- Final app with `native-authority,synthetic-authority`: 656 passed, 3 pre-existing ignored.
- Default workspace strict all-target Clippy, core all-feature strict all-target
  Clippy, combined-feature app strict all-target Clippy, and default workspace
  build passed.
- Exact final app `--all-features`: 663 passed, 3 pre-existing ignored;
  strict `--all-targets --all-features` Clippy passed.

The earlier full default workspace run also passed; after its test-only addition,
the full app was rerun. No native macOS UI acceptance is claimed.

Review identified a pre-existing read-only journal stat/open FIFO race. The narrow
core hardening routes read-only journal opens through the same metadata-taking,
nonblocking regular-file opener as inspection checkpoints and locks; writable
replay/recovery is unchanged. A subprocess regression substitutes a FIFO after the
exact production pre-open stat and enforces a deadline. Additional tests reject
same-length/mtime inode replacement and symlink substitution, and preserve regular
journal bytes/metadata. These new core tests and the negative control removing
O_NONBLOCK were executed: all five focused tests passed; deleting only the
nonblocking flag in an isolated source/target made the FIFO regression fail at its
5-second deadline, and restoring the exact helper hash returned all five to pass.
The shared target was never mutated. No general timeout/cancellation guarantee is
claimed for regular-file filesystem IO.
